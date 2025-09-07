const std = @import("std");
const uefi = std.os.uefi;

const paging = @import("./paging.zig");
const bootboot = @import("./bootboot.zig");

/// Interface for allocating physical pages (1 at a time)
/// TODO: Extend interface to allocate chunks of physical pages
pub const PageAllocator = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const Error = error{OutOfMemory};

    pub const VTable = struct {
        alloc: *const fn (*anyopaque) ?paging.PageNum,
        free: *const fn (*anyopaque, page: paging.PageNum) void,
    };

    pub fn alloc(self: PageAllocator) !paging.PageNum {
        return self.vtable.alloc(self.context) orelse return Error.OutOfMemory;
    }

    pub fn free(self: PageAllocator, page: paging.PageNum) void {
        return self.vtable.free(self.context, page);
    }

    pub fn noFree(context: *anyopaque, page: paging.PageNum) void {
        _ = context;
        _ = page;
        return;
    }
};

const Alignment = std.mem.Alignment;

pub const PageBitmap = struct {
    // TODO: Force page alignment to allow some bit-math optimizations?
    // TODO: View with larger integers (or even vector instructions?)
    data: []u8,
    page_count: usize,
    hint: paging.PageNum = 0,

    const Self = @This();

    /// Initialize the bitmap using the allocated data buffer.
    /// All pages are marked as free to start.
    pub fn init(data: []u8, page_count: usize) Self {
        std.debug.assert(page_count <= data.len * @bitSizeOf(@TypeOf(data[0])));
        @memset(data, 0);
        return Self{ .data = data, .page_count = page_count };
    }

    fn chunkCount(self: *const Self) usize {
        return std.math.divCeil(
            usize,
            self.page_count,
            @bitSizeOf(@TypeOf(self.data[0])),
        ) catch unreachable;
    }

    pub fn isUsed(self: *const Self, page: paging.PageNum) bool {
        if (page > self.page_count) {
            return true;
        }
        return self.data[chunkIndex(page)] & bitMask(page) != 0;
    }

    pub fn markUsed(self: *Self, page: paging.PageNum) void {
        // Allow marking non-tracked pages
        // TODO: This may disguise issues later on...
        if (page > self.page_count) {
            return;
        }
        self.data[chunkIndex(page)] |= bitMask(page);
    }

    pub fn markUnused(self: *Self, page: paging.PageNum) void {
        self.data[chunkIndex(page)] &= ~bitMask(page);
    }

    pub fn markRangeUsed(self: *Self, start: paging.PageNum, n: usize) void {
        // TODO: Use smarter logic to update many bits at once
        for (0..n) |offset| {
            if (start + offset > self.page_count) {
                break;
            }
            self.markUsed(@intCast(start + offset));
        }
    }

    pub fn markRangeUnused(self: *Self, start: paging.PageNum, n: usize) void {
        // TODO: Use smarter logic to update many bits at once
        for (0..n) |offset| {
            self.markUnused(@intCast(start + offset));
        }
    }

    pub fn allocator(self: *Self) PageAllocator {
        return .{
            .context = self,
            .vtable = &.{
                .alloc = alloc,
                .free = free,
            },
        };
    }

    /// Allocate a single page
    pub fn alloc(context: *anyopaque) ?paging.PageNum {
        const self: *Self = @ptrCast(@alignCast(context));
        const res = self.findUnusedPage() orelse return null;
        std.debug.assert(!self.isUsed(res));
        self.markUsed(res);
        self.hint = res + 1;
        return res;
    }

    /// Free a single page
    pub fn free(context: *anyopaque, page: paging.PageNum) void {
        const self: *Self = @ptrCast(@alignCast(context));
        std.debug.assert(self.isUsed(page));
        self.markUnused(page);
    }

    fn chunkIndex(page: paging.PageNum) usize {
        return @intCast(page >> 3);
    }

    fn bitMask(page: paging.PageNum) u8 {
        const bit: u3 = @truncate(page);
        return @as(u8, 1) << bit;
    }

    fn pageFromIndex(byte: usize, bit: usize) paging.PageNum {
        return @intCast(byte * 8 + bit);
    }

    fn findUnusedPageInRange(self: *const Self, start: usize, end: usize) ?paging.PageNum {
        var byte_index = start;
        while (byte_index < end) : (byte_index += 1) {
            if (self.data[byte_index] != std.math.maxInt(u8)) {
                for (0..8) |bit_index| {
                    const b: u3 = @intCast(bit_index);
                    if (self.data[byte_index] & (@as(u8, 1) << b) == 0) {
                        return pageFromIndex(byte_index, bit_index);
                    }
                }
            }
        }
        return null;
    }

    fn findUnusedPage(self: *const Self) ?paging.PageNum {
        if (self.hint < self.page_count and !self.isUsed(self.hint)) {
            return self.hint;
        }

        const hint_index = chunkIndex(self.hint);
        const res = self.findUnusedPageInRange(hint_index, self.chunkCount()) orelse
            self.findUnusedPageInRange(0, hint_index) orelse
            return null;

        // Final bounds check for when page_count isn't perfectly alinged with
        // the chunk size (it's easier to check here than in the search function)
        if (@as(usize, @intCast(res)) < self.page_count) {
            return res;
        } else {
            return null;
        }
    }
};

test "PageBitmap: all free after init" {
    var data: [32]u8 = undefined;
    data[0] = 1;
    data[10] = 0x81;
    data[23] = 0xFA;
    const bitmap = PageBitmap.init(&data, 256);
    for (0..bitmap.page_count) |p| {
        try std.testing.expect(!bitmap.isUsed(@intCast(p)));
    }
}

test "PageBitmap: isUsed() after markUsed()" {
    var data: [32]u8 = undefined;
    var bitmap = PageBitmap.init(&data, 256);
    bitmap.markUsed(15);
    for (0..bitmap.page_count) |p| {
        if (p == 15) {
            try std.testing.expect(bitmap.isUsed(@intCast(p)));
        } else {
            try std.testing.expect(!bitmap.isUsed(@intCast(p)));
        }
    }
}

test "PageBitmap: isUsed() after alloc()" {
    var data: [32]u8 = undefined;
    var bitmap = PageBitmap.init(&data, 256);
    const allocated = try bitmap.alloc();
    for (0..bitmap.page_count) |p| {
        if (p == allocated) {
            try std.testing.expect(bitmap.isUsed(@intCast(p)));
        } else {
            try std.testing.expect(!bitmap.isUsed(@intCast(p)));
        }
    }
}

test "PageBitmap: isUsed() after free()" {
    var data: [32]u8 = undefined;
    var bitmap = PageBitmap.init(&data, 256);
    const freed = try bitmap.alloc();
    const allocated = try bitmap.alloc();
    bitmap.free(freed);
    for (0..bitmap.page_count) |p| {
        if (p == allocated) {
            try std.testing.expect(bitmap.isUsed(@intCast(p)));
        } else {
            try std.testing.expect(!bitmap.isUsed(@intCast(p)));
        }
    }
}

test "PageBitmap: sequential alloc() does not return same page" {
    var data: [32]u8 = undefined;
    var bitmap = PageBitmap.init(&data, 256);
    const a1 = try bitmap.alloc();
    const a2 = try bitmap.alloc();
    try std.testing.expect(a1 != a2);
}

test "PageBitmap: alloc() can allocate page_count pages" {
    var data: [32]u8 = undefined;
    var bitmap = PageBitmap.init(&data, 256);
    for (0..bitmap.page_count) |_| {
        _ = try bitmap.alloc();
    }

    try std.testing.expectError(error.OutOfMemory, bitmap.alloc());
}

test "PageBitmap: alloc() can allocate page_count pages when page_count < data buffer size" {
    var data: [32]u8 = undefined;
    var bitmap = PageBitmap.init(&data, 240);
    try std.testing.expectEqual(240, bitmap.page_count);
    for (0..bitmap.page_count) |_| {
        _ = try bitmap.alloc();
    }

    try std.testing.expectError(error.OutOfMemory, bitmap.alloc());
}

test "PageBitmap: alloc() can allocate page_count pages when page_count not a multiple of chunk size" {
    var data: [32]u8 = undefined;
    var bitmap = PageBitmap.init(&data, 211);
    try std.testing.expectEqual(211, bitmap.page_count);
    for (0..bitmap.page_count) |_| {
        _ = try bitmap.alloc();
    }

    try std.testing.expectError(error.OutOfMemory, bitmap.alloc());
}

test "PageBitmap: alloc() can re-use page after free()" {
    var data: [32]u8 = undefined;
    var bitmap = PageBitmap.init(&data, 256);
    // Fill up allocator
    for (0..bitmap.page_count) |_| {
        _ = try bitmap.alloc();
    }

    bitmap.free(5);
    bitmap.free(10);
    bitmap.free(15);
    bitmap.free(11);

    _ = try bitmap.alloc();
    _ = try bitmap.alloc();
    _ = try bitmap.alloc();
    _ = try bitmap.alloc();

    try std.testing.expectError(error.OutOfMemory, bitmap.alloc());
}

/// Simple whole-page allocator that only relies on the memory map and a pointer
/// for bump-style allocation. Does not have the ability to free memory.
///
/// This is only used to bootstrap the real page allocator.
pub const BootbootMMapPageAllocator = struct {
    mem_map: []const bootboot.MMapEnt,
    index: usize = 0,
    /// Track position in the "current" chunk, reset when advancing the iterator
    chunk_offset: usize = 0,

    const Self = @This();

    pub fn init(mem_map: []const bootboot.MMapEnt) Self {
        return Self{ .mem_map = mem_map };
    }

    /// Get the internal "offset" tracked by the allocator. This page is not
    /// part of any allocations, although it may not necessarily be free in the
    /// memory map.
    pub fn getNextUnallocatedPage(self: *const Self) paging.PageNum {
        // TODO: Handle when all pages in mem_map are allocated? Shouldn't ever
        // happen, but may as well have the code be theoretically correct
        return @intCast(paging.addressToPageNum(self.mem_map[self.index].ptr) + self.chunk_offset);
    }

    pub fn allocPages(self: *Self, num_pages: usize) ?paging.PageNum {
        while (self.index < self.mem_map.len) : ({
            self.index += 1;
            self.chunk_offset = 0;
        }) {
            const chunk = &self.mem_map[self.index];
            if (!chunk.isFree()) {
                continue;
            }
            const chunk_start_page = paging.addressToPageNum(chunk.ptr);
            const chunk_end_page = chunk_start_page + chunk.getSizePages();
            const alloc_start_page = chunk_start_page + self.chunk_offset;
            if (alloc_start_page + num_pages < chunk_end_page) {
                self.chunk_offset += num_pages;
                return @intCast(alloc_start_page);
            }
        }
        return null;
    }

    pub fn allocator(self: *Self) PageAllocator {
        return .{
            .context = self,
            .vtable = &.{
                .alloc = alloc,
                .free = PageAllocator.noFree,
            },
        };
    }

    fn alloc(context: *anyopaque) ?paging.PageNum {
        const self: *Self = @ptrCast(@alignCast(context));
        return self.allocPages(1);
    }
};

test BootbootMMapPageAllocator {
    const Entry = bootboot.MMapEnt;

    const map = [_]Entry{
        Entry.init(0, 0x2000, .used),
        Entry.init(0x2000, 0x1000, .mmio),
        Entry.init(0x3000, 0x10000, .free),
        Entry.init(0x13000, 0x5000, .acpi),
        Entry.init(0x18000, 0x4000, .free),
    };

    var alloc = BootbootMMapPageAllocator.init(&map);
    try std.testing.expectEqual(0x3, alloc.allocPages(1));
    try std.testing.expectEqual(0x4, alloc.allocPages(5));
    try std.testing.expectEqual(0x9, alloc.allocPages(4));
    try std.testing.expectEqual(0xD, alloc.allocPages(3));
    // Skips to next descriptor
    try std.testing.expectEqual(0x18, alloc.allocPages(3));
    // Only space for 1 more page
    try std.testing.expectError(error.OutOfMemory, alloc.allocPages(2));
    // Doesn't look for un-used space after OOM
    try std.testing.expectError(error.OutOfMemory, alloc.allocPages(1));
}

pub const PagedHeapRegion = struct {
    pml4: *paging.PageTable,
    page_alloc: PageAllocator,
    region_base: Addr,
    region_len: usize,
    /// Size of the region that is currently mapped
    mapped_len: usize,
    /// Previously reported limit
    limit: Addr,

    const Self = @This();
    const Addr = paging.VirtualAddress;

    pub fn init(pml4: *paging.PageTable, page_alloc: PageAllocator, region_base: Addr, region_len: usize) Self {
        // Due to the limitation of the sbrk() API, the region cannot start at 0
        std.debug.assert(region_base > 0);
        return .{
            .pml4 = pml4,
            .page_alloc = page_alloc,
            .region_base = region_base,
            .region_len = region_len,
            .mapped_len = 0,
            .limit = region_base,
        };
    }

    /// Increases the size of the heap by mapping new memory pages.
    ///
    /// Returns the previous extent of the heap, or 0 if the limit could not be extended
    pub fn extend(self: *Self, n: usize) Addr {
        // Previous limit is always returned
        const previous_limit = self.limit;
        const new_limit = self.limit + n;

        if (new_limit > self.region_base + self.region_len) {
            // No more address space
            return 0;
        }

        // Don't need to map more pages
        if (new_limit <= self.region_base + self.mapped_len) {
            self.limit = new_limit;
            return previous_limit;
        }

        const required_len = new_limit - (self.region_base + self.mapped_len);
        const page_count = paging.pagesRequired(required_len);
        const added_region_start = self.region_base + self.mapped_len;

        // Use while() to track state outside of the loop so that we can clean up in case of a failure.
        var page_offset: usize = 0;
        while (page_offset < page_count) : (page_offset += 1) {
            const page = self.page_alloc.alloc() catch {
                break;
            };
            const page_entry = paging.PageTableEntry.init(page, .{
                .writable = true,
                .execute_disabled = true,
            });
            const map_addr: Addr = added_region_start + page_offset * paging.page_size;
            // Returns a slice for the mapped region, which isn't important here
            _ = map4KPage(self.pml4, self.page_alloc, page_entry, map_addr) catch {
                break;
            };
        } else {
            // Loop finished, so everything worked
            self.mapped_len += page_count * paging.page_size;
            self.limit = new_limit;
            return previous_limit;
        }

        // TODO: Early loop exit means failure, so:
        // - free allocated pages
        // - free added page tables
        // - clear added page table entries
        @panic("unimplemented: clean up after failed allocation");
    }
};

fn map4KPage(
    pml4: *paging.PageTable,
    page_alloc: PageAllocator,
    page_entry: paging.PageTableEntry,
    virt_addr: paging.VirtualAddress,
) !*align(4096) anyopaque {
    const log = std.log.scoped(.map4kPage);
    log.debug("start: pml4={*} page={} vaddr={x:016}", .{ pml4, page_entry.physical_page_number, virt_addr });
    defer log.debug("done", .{});
    const pml4_index = paging.getPml4Index(virt_addr);
    if (!pml4.entries[pml4_index].present) {
        const pdpt_page = try page_alloc.alloc();
        const pdpt = paging.pageNumToPtr(paging.PageTable, pdpt_page);
        pdpt.clear();
        log.debug("allocated PDPT: {*}", .{pdpt});
        pml4.entries[pml4_index] = page_entry.withPageNum(pdpt_page);
    } else if (pml4.entries[pml4_index].huge_page) {
        return error.AlreadyMapped;
    }

    const pdpt = pml4.entries[pml4_index].physicalPtrAs(paging.PageTable);
    const pdpt_index = paging.getPdptIndex(virt_addr);
    if (!pdpt.entries[pdpt_index].present) {
        const pd_page = try page_alloc.alloc();
        const pd = paging.pageNumToPtr(paging.PageTable, pd_page);
        pd.clear();
        log.debug("allocated PD: {*}", .{pd});
        paging.pageNumToPtr(paging.PageTable, pd_page).clear();
        pdpt.entries[pdpt_index] = page_entry.withPageNum(pd_page);
    } else if (pdpt.entries[pdpt_index].huge_page) {
        return error.AlreadyMapped;
    }

    const pd = pdpt.entries[pdpt_index].physicalPtrAs(paging.PageTable);
    const pd_index = paging.getPdIndex(virt_addr);
    if (!pd.entries[pd_index].present) {
        const pt_page = try page_alloc.alloc();
        const pt = paging.pageNumToPtr(paging.PageTable, pt_page);
        pt.clear();
        log.debug("allocated PT: {*}", .{pt});
        paging.pageNumToPtr(paging.PageTable, pt_page).clear();
        pd.entries[pd_index] = page_entry.withPageNum(pt_page);
    } else if (pd.entries[pd_index].huge_page) {
        return error.AlreadyMapped;
    }

    const pt = pd.entries[pd_index].physicalPtrAs(paging.PageTable);
    const pt_index = paging.getPtIndex(virt_addr);
    if (pt.entries[pt_index].present) {
        return error.AlreadyMapped;
    }

    pt.entries[pt_index] = page_entry;
    return @ptrFromInt(virt_addr);
}
