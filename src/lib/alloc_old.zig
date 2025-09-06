/// Interface for allocating virtual address space This is almost identical to
/// std.mem.Allocator, but the methods on std.mem.Allocator initialize memory
/// with `undefined`, which won't work here since the allocated addresses are
/// not yet mapped.
pub const AddrAllocator = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const Addr = paging.VirtualAddress;
    const Self = @This();
    const Error = std.mem.Allocator.Error;

    pub const VTable = struct {
        // TODO: Include return addresses?
        alloc: *const fn (*anyopaque, len: usize, alignment: Alignment) ?Addr,
        resize: *const fn (*anyopaque, base: Addr, len: usize, alignment: Alignment, new_len: usize) bool,
        free: *const fn (*anyopaque, base: Addr, len: usize, alignment: Alignment) void,
    };

    // pub fn allocAlignedPages(
    //     self: Self,
    //     comptime alignment: ?u29,
    //     page_count: usize,
    // ) Error![]align(alignment orelse paging.page_size) u8 {
    //     comptime std.debug.assert(alignment >= paging.page_size);
    //     const len = page_count * paging.page_size;
    //     const ptr = self.rawAlloc(len, Alignment.fromByteUnits(paging.page_size)) orelse
    //         return Error.OutOfMemory;
    //     return @alignCast(ptr[0..len]);
    // }

    // pub fn resize(self: Self, memory: anytype, new_len: usize) bool {
    //     if (new_len == 0) {
    //         self.free(memory);
    //         return true;
    //     }
    //     if (memory.len == 0) {
    //         return false;
    //     }

    //     const Slice = @typeInfo(@TypeOf(memory)).pointer;
    //     // TODO: Allow non-u8?
    //     comptime std.debug.assert(Slice.child == u8);

    //     const old_bytes = std.mem.sliceAsBytes(memory);
    //     return self.rawResize(old_bytes, Alignment.fromByteUnits(Slice.alignment), new_len);
    // }

    // pub fn free(self: Self, memory: anytype) void {
    //     const Slice = @typeInfo(@TypeOf(memory)).pointer;
    //     // TODO: Allow non-u8?
    //     comptime std.debug.assert(Slice.child == u8);
    //     comptime std.debug.assert(Slice.sentinel() == null);
    //     // Cast to bytes to get len
    //     const bytes = std.mem.sliceAsBytes(memory);
    //     self.rawFree(self.context, bytes, Alignment.fromByteUnits(Slice.alignment));
    // }

    pub inline fn rawAlloc(self: Self, len: usize, alignment: Alignment) ?Addr {
        return self.vtable.alloc(self.context, len, alignment);
    }

    pub inline fn rawResize(self: Self, base: Addr, len: usize, alignment: Alignment, new_len: usize) bool {
        return self.vtable.resize(self.context, base, len, alignment, new_len);
    }

    pub inline fn rawFree(self: Self, base: Addr, len: usize, alignment: Alignment) void {
        self.vtable.free(self.context, base, len, alignment);
    }

    pub fn noResize(context: *anyopaque, base: Addr, len: usize, alignment: Alignment, new_len: usize) bool {
        _ = context;
        _ = base;
        _ = len;
        _ = alignment;
        _ = new_len;
        return false;
    }

    pub fn noFree(context: *anyopaque, base: Addr, len: usize, alignment: Alignment) void {
        _ = context;
        _ = base;
        _ = len;
        _ = alignment;
    }
};

/// Wrapper around `std.heap.FixedBufferAllocator` to implement `AddrAllocator`
pub const BumpAddrAllocator = struct {
    state: std.heap.FixedBufferAllocator,

    const Self = @This();
    const Addr = AddrAllocator.Addr;

    pub fn init(region: []u8) Self {
        return .{ .state = std.heap.FixedBufferAllocator.init(region) };
    }

    pub fn allocator(self: *Self) AddrAllocator {
        return .{
            .context = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
            },
        };
    }

    pub fn alloc(context: *anyopaque, len: usize, alignment: Alignment) ?Addr {
        const self: *Self = @ptrCast(@alignCast(context));
        const region = self.state.allocator().rawAlloc(len, alignment, 0) orelse return null;
        return @intFromPtr(region);
    }

    pub fn resize(context: *anyopaque, base: Addr, len: usize, alignment: Alignment, new_len: usize) bool {
        const self: *Self = @ptrCast(@alignCast(context));
        const memory = @as([*]u8, @ptrFromInt(base))[0..len];
        return self.state.allocator().rawResize(memory, alignment, new_len, 0);
    }

    pub fn free(context: *anyopaque, base: Addr, len: usize, alignment: Alignment) void {
        const self: *Self = @ptrCast(@alignCast(context));
        const memory = @as([*]u8, @ptrFromInt(base))[0..len];
        self.state.allocator().rawFree(memory, alignment, 0);
    }

    pub fn getNextUnallocatedAddr(self: *const Self) paging.VirtualAddress {
        return @intFromPtr(self.state.buffer) + self.state.end_index;
    }
};

/// Combines a `PageAllocator` and `AddrAllocator` to make a `std.mem.Allocator`
/// that allocates whole pages.
/// Only the last allocation can be freed or re-sized (like FixedBufferAllocator).
pub const KernelPagingAllocator = struct {
    pml4: *paging.PageTable,
    // TODO: Make these type generic instead of interfaces?
    page_alloc: PageAllocator,
    addr_alloc: AddrAllocator,

    const Self = @This();

    pub fn allocator(self: *Self) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = std.mem.Allocator.noResize,
                .remap = std.mem.Allocator.noRemap,
                .free = std.mem.Allocator.noFree,
            },
        };
    }

    pub fn alloc(ptr: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *Self = @ptrCast(@alignCast(ptr));
        const page_count = paging.pagesRequired(len);
        const alloc_len = page_count * paging.page_size;
        const region_start = self.addr_alloc.rawAlloc(alloc_len, alignment) orelse return null;

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
            const map_addr: paging.VirtualAddress = region_start + page_offset * paging.page_size;
            // Returns a slice for the mapped region, which isn't important here
            _ = map4KPage(self.pml4, self.page_alloc, page_entry, map_addr) catch {
                break;
            };
        } else {
            // Loop finished, so everything worked
            return @ptrFromInt(region_start);
        }

        // TODO: Early loop exit means failure, so cleanup:
        // - Allocated pages
        // - Added page tables
        // - Memory region
        @panic("unimplemented: clean up after failed allocation");
    }
};
