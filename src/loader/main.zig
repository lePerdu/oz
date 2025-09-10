const std = @import("std");
const uefi = std.os.uefi;
const W = std.unicode.utf8ToUtf16LeStringLiteral;

const ozlib = @import("ozlib");
const paging = ozlib.paging;

pub const std_options = std.Options{
    .log_level = .debug,
    .logFn = ozlib.io.debugConsoleLog,
};

/// Structure to keep track of bootloader allocations so that they can be marked
/// as not-free in the memory map
/// TODO: Make non-global?
/// TODO: Use a custom "MemoryType" in UEFI allocations instead?
var alloc_state: struct {
    bootboot: ?*anyopaque = null,
    kernel: ?*anyopaque = null,
    page_tables_and_stack: ?*anyopaque = null,
} = .{};

fn loadKernelFile() !*uefi.protocol.File {
    const log = std.log.scoped(.loadKernelFile);
    log.debug("start", .{});
    const boot_services = uefi.system_table.boot_services.?;

    const loaded_image_proto = (try boot_services.openProtocol(
        uefi.protocol.LoadedImage,
        uefi.handle,
        .{ .by_handle_protocol = .{ .agent = uefi.handle } },
    )).?;

    const fs_device = loaded_image_proto.device_handle.?;

    const file_system_proto = (try boot_services.openProtocol(
        uefi.protocol.SimpleFileSystem,
        fs_device,
        .{ .by_handle_protocol = .{ .agent = uefi.handle } },
    )).?;

    const File = uefi.protocol.File;

    const fs_root: *File = try file_system_proto.openVolume();

    const kernel_file: *File = try fs_root.open(W("ozkernel"), .read, .{});
    log.debug("found file: {*}", .{kernel_file});
    return kernel_file;
}

fn allocKernelPages(kernel_size: usize) ![]align(paging.page_size) u8 {
    const log = std.log.scoped(.allocKernelPages);
    const kernel_page_count = paging.pagesRequired(kernel_size);
    log.debug("start: {} bytes, {} pages", .{ kernel_size, kernel_page_count });

    const kernel_pages = try uefi.system_table.boot_services.?.allocatePages(
        .any,
        // TODO: custom type?
        .loader_data,
        kernel_page_count,
    );
    alloc_state.kernel = kernel_pages.ptr;

    // TODO: Allow non-contiguous pages
    log.debug("end", .{});
    return std.mem.sliceAsBytes(kernel_pages);
}

/// Allocate pages for the kernel and load it into memory
fn loadKernel() ![]align(4096) u8 {
    const log = std.log.scoped(.loadKernel);
    log.debug("start", .{});
    const kernel_file = try loadKernelFile();
    // const info_size = try kernel_file.getInfoSize(.file);
    // TODO: Find a good way to dynamically allocate this or statically ensure it's big enough
    var info_buf: [@sizeOf(uefi.protocol.File.Info.File) + 64]u8 align(@alignOf(uefi.protocol.File.Info.File)) = undefined;
    const file_info = try kernel_file.getInfo(.file, &info_buf);
    const kernel_size = file_info.file_size;
    const kernel_pages = try allocKernelPages(kernel_size);

    log.debug("reading kernel into memory: [{}]{*}", .{ kernel_pages.len, kernel_pages.ptr });
    const read_size = try kernel_file.read(kernel_pages);
    log.debug("read kernel into memory: {} bytes", .{read_size});
    std.debug.assert(read_size == kernel_size);
    return kernel_pages;
}

/// Wrapper around `allocatePages` that iterates over the allocated pages
/// individually.
/// This nicely groups related functions and the allows for non-contiguous pages.
const UefiPageTableAllocator = struct {
    allocated_group: []paging.PageTable,
    next_page_index: usize = 0,
    total_pages: usize,

    const Self = @This();

    pub fn init(total_pages: usize) !Self {
        const allocated =
            try uefi.system_table.boot_services.?.allocatePages(
                .any,
                // TODO: Use custom type to make it easier to distinguish later?
                .loader_data,
                total_pages,
            );
        // TODO: Fallback to allocating pages in smaller chunks, since they don't actually need to be contiguous
        @memset(std.mem.sliceAsBytes(allocated), 0);

        return .{
            .allocated_group = @as([*]paging.PageTable, @ptrCast(allocated))[0..total_pages],
            .total_pages = total_pages,
        };
    }

    pub fn next(self: *Self) ?*paging.PageTable {
        if (self.next_page_index >= self.allocated_group.len) {
            return null;
        }
        const page = &self.allocated_group[self.next_page_index];
        self.next_page_index += 1;
        return page;
    }

    pub fn nextRaw(self: *Self) ?paging.PageNum {
        return paging.pointerToPageNum(self.next() orelse return null);
    }

    pub fn makeSuballocator(self: *Self, page_count: usize) ?Self {
        if (self.next_page_index + page_count >= self.allocated_group.len) {
            return null;
        }

        const subgroup = self.allocated_group[self.next_page_index .. self.next_page_index + page_count];
        self.next_page_index += page_count;

        return Self{
            .allocated_group = subgroup,
            .total_pages = page_count,
        };
    }
};

fn printPageMapping(pml4: *const paging.PageTable, ptr: *const anyopaque) void {
    const log = std.log.scoped(.printPageMapping);

    const addr: u64 = @intFromPtr(ptr);
    const pml4_index = paging.getPml4Index(addr);
    const pdpt_index = paging.getPdptIndex(addr);
    const pd_index = paging.getPdIndex(addr);
    const pt_index = paging.getPtIndex(addr);
    const indices = .{ pml4_index, pdpt_index, pd_index, pt_index, paging.getPageOffset(addr) };
    log.debug("{*}: [{}][{}][{}][{}][{}]", .{ptr} ++ indices);

    const pdpt = pml4.entries[pml4_index].physicalPtrAs(paging.PageTable);
    if (!pdpt.entries[pdpt_index].present) {
        log.debug("PDPT missing", .{});
        return;
    }
    if (pdpt.entries[pdpt_index].huge_page) {
        log.debug("1GiB page: {}", .{pdpt.entries[pdpt_index]});
        return;
    }
    const pd = pdpt.entries[pdpt_index].physicalPtrAs(paging.PageTable);
    if (!pd.entries[pd_index].present) {
        log.debug("PD missing", .{});
        return;
    }
    if (pd.entries[pd_index].huge_page) {
        log.debug("2MiB page: {}", .{pd.entries[pd_index]});
        return;
    }
    const pt = pd.entries[pt_index].physicalPtrAs(paging.PageTable);
    if (!pt.entries[pt_index].present) {
        log.debug("PT missing", .{});
        return;
    } else {
        log.debug("1KiB page: {}", .{pt.entries[pt_index]});
        return;
    }
}

// fn printPageTables(pml4: *const paging.PageTable) void {
//     const log = std.log.scoped(.printPageTables);
//     log.debug("pml4: {*}", .{pml4});

//     for (pml4.entries, 0..) |pml4_ent, pml4_idx| {
//         log.info("[{}]: {}", .{ pml4_idx, pml4_ent });
//         if (pml4_ent.present) {
//             const pdpt = pml4_ent.physicalPtrAs(paging.PageTable);
//             for (pdpt.entries, 0..) |pdpt_ent, pdpt_idx| {
//                 log.info("[{}][{}]: {}", .{ pml4_idx, pdpt_idx, pdpt_ent });
//                 if (pdpt_ent.present and !pdpt_ent.huge_page) {
//                     const pd = pdpt_ent.physicalPtrAs(paging.PageTable);
//                     for (pd.entries, 0..) |pd_ent, pd_idx| {
//                         log.info("[{}][{}][{}]: {}", .{ pml4_idx, pdpt_idx, pd_idx, pd_ent });
//                         if (pd_ent.present and !pd_ent.huge_page) {
//                             const pt = pd_ent.physicalPtrAs(paging.PageTable);
//                             for (pt.entries, 0..) |pt_ent, pt_idx| {
//                                 log.info("[{}][{}][{}][{}]: {}", .{ pml4_idx, pdpt_idx, pd_idx, pt_idx, pt_ent });
//                             }
//                         }
//                     }
//                 }
//             }
//         }
//     }
// }

// Helpers for creating page entries with basic configuration:
// - writable
// - executable
// - not user-accessible
// - no write-through
// - cache-enabled
// - non-global

fn initSmallPage(page_num: paging.PageNum) paging.PageTableEntry {
    return paging.PageTableEntry.init(page_num, .{ .writable = true });
}

fn initLargePage(page_num: paging.PageNum) paging.PageTableEntry {
    return paging.PageTableEntry.init(page_num, .{ .writable = true, .huge_page = true });
}

fn createPageTables(
    info: *ozlib.bootboot.Bootboot,
    kernel_pages: []align(4096) u8,
) !*paging.PageTable {
    const log = std.log.scoped(.createPageTables);
    log.debug("start", .{});

    // PML4
    // Identity map (16G): 2M pages
    // - 1 PDPT
    //   - 16 PD
    // Kernel space:
    // - 1 PDPT
    //   Framebuffer: 4K pages
    //   - 1 PD
    //     - < 32 PT (fb_size /^ 2M)
    //   Boot data + Kernel code/data + kernel stack:
    //   - 1 PD
    //     - 1 PT
    //       - 1 + (kernel_size /^ 4K) + 1 pages

    const root_pml4s = 1;

    const ident_pdpts = 1;
    const ident_pds = 16;

    const kernel_pdpts = 1;
    const kernel_pds = 1;
    const fb_pages = paging.pagesRequired(info.fb_size);
    const fb_pts = paging.pageEntriesRequired(fb_pages);
    std.debug.assert(paging.pageEntriesRequired(fb_pts) == 1);
    const kernel_data_pts = 1;
    // Not used as a page table, but it's conventient to use the same page frame
    // allocator
    const kernel_stack_pages = ozlib.bootboot.kernel_stack_pages;

    const total_pages =
        root_pml4s +
        ident_pdpts + ident_pds +
        kernel_pdpts + kernel_pds + fb_pts + kernel_data_pts +
        kernel_stack_pages;

    log.debug("pages required: {}", .{.{
        .ident_pdpts = ident_pdpts,
        .ident_pds = ident_pds,
        .kernel_pds = kernel_pds,
        .fb_pts = fb_pts,
        .kernel_data_pts = kernel_data_pts,
        .total = total_pages,

        .stack_pages = kernel_stack_pages,
        .fb_pages = fb_pages,
    }});

    var alloc = try UefiPageTableAllocator.init(total_pages);
    alloc_state.page_tables_and_stack = alloc.allocated_group.ptr;

    const ptr2Page = paging.pointerToPageNum;

    const pml4 = alloc.next().?;

    {
        // Identity-map first 16GiB
        log.debug("creating identity tables", .{});
        defer log.debug("done creating identity tables", .{});

        const pdpt = alloc.next().?;
        pml4.entries[0] = initSmallPage(ptr2Page(pdpt));
        for (0..ident_pds) |pdpt_index| {
            const pd = alloc.next().?;
            pdpt.entries[pdpt_index] = initSmallPage(ptr2Page(pd));

            for (0..512) |pd_index| {
                const phys_addr = paging.build2MVirtAddr(0, pdpt_index, pd_index);
                pd.entries[pd_index] = initLargePage(paging.addressToPageNum(phys_addr));
            }
        }
    }

    const kernel_pdpt = alloc.next().?;
    comptime std.debug.assert(paging.getPml4Index(ozlib.bootboot.fb_start) == 511);
    pml4.entries[511] = initSmallPage(ptr2Page(kernel_pdpt));

    const kernel_pd = alloc.next().?;
    comptime std.debug.assert(paging.getPdptIndex(ozlib.bootboot.fb_start) == 511);
    kernel_pdpt.entries[511] = initSmallPage(ptr2Page(kernel_pd));

    fb: {
        // Offset-map framebuffer
        log.debug("creating fb tables", .{});
        defer log.debug("done creating fb tables", .{});

        comptime std.debug.assert(paging.getPtIndex(ozlib.bootboot.fb_start) == 0);
        const pd_start_index = paging.getPdIndex(ozlib.bootboot.fb_start);
        for (0..fb_pts, pd_start_index..) |pd_offset, pd_index| {
            const pt = alloc.next().?;
            kernel_pd.entries[pd_index] = initSmallPage(ptr2Page(pt));

            for (0..512) |pt_index| {
                const fb_offset = paging.build4KVirtAddr(0, 0, pd_offset, pt_index);
                if (fb_offset > info.fb_size) {
                    break :fb;
                }
                const page = paging.addressToPageNum(info.fb_ptr + fb_offset);
                pt.entries[pt_index] = initSmallPage(page);
            }
        }
    }

    log.debug("creating kernel tables", .{});

    comptime std.debug.assert(paging.getPdIndex(ozlib.bootboot.bootboot_start) == 511);
    const kernel_data_pt = alloc.next().?;
    kernel_pd.entries[511] = initSmallPage(ptr2Page(kernel_data_pt));

    comptime std.debug.assert(paging.getPtIndex(ozlib.bootboot.bootboot_start) == 0);
    kernel_data_pt.entries[0] = initSmallPage(ptr2Page(info));

    comptime std.debug.assert(paging.getPtIndex(ozlib.bootboot.kernel_start) == 2);
    const base_kernel_page = paging.pointerToPageNum(kernel_pages.ptr);
    const kernel_page_count = paging.pagesRequired(kernel_pages.len);
    for (0..kernel_page_count, 2.., base_kernel_page..) |_, pt_index, page| {
        kernel_data_pt.entries[pt_index] = initSmallPage(@intCast(page));
    }

    // comptime std.debug.assert(paging.getPtIndex(ozlib.bootboot.kernel_stack_start) == 508);
    // const kernel_stack_page = alloc.nextRaw().?;
    // kernel_data_pt.entries[511] = initSmallPage(alloc.nextRaw().?);
    comptime std.debug.assert(paging.getPtIndex(ozlib.bootboot.kernel_stack_start) == 512 - kernel_stack_pages);
    for (512 - kernel_stack_pages..512) |pt_index| {
        kernel_data_pt.entries[pt_index] = initSmallPage(alloc.nextRaw().?);
    }

    std.debug.assert(alloc.next() == null);

    log.debug("done", .{});
    return pml4;
}

/// Create page tables identity-mapping the first `page_count` of memory
fn createIdentityPageTables(page_count: usize) !*paging.PageTable {
    const log = std.log.scoped(.setupIdentityMap);
    log.info("setting up identity memory mapping for {} pages", .{page_count});

    // TODO: Use 1GiB pages? Maybe not worth the complexity of checking compatibility
    const page_tables_required = ident: {
        const large_page_count = paging.pageEntriesRequired(page_count);
        const page_dirs = paging.pageEntriesRequired(large_page_count);
        const page_dir_pointers = paging.pageEntriesRequired(page_dirs);
        const page_map_level_4s = paging.pageEntriesRequired(page_dir_pointers);
        std.debug.assert(page_map_level_4s == 1);

        break :ident page_dirs + page_dir_pointers + page_map_level_4s;
    };

    log.debug("page tables required: {}", .{page_tables_required});

    var allocator = try UefiPageTableAllocator.init(page_tables_required);

    const ptr2Page = paging.pointerToPageNum;

    const pml4 = allocator.next().?;
    init_loop: for (0..511) |pml4_index| {
        // Only iterate to 511 since the last entry in PML4 is recursive
        // (Doesn't really matter anyway since no compute has that much RAM)
        const pdpt = allocator.next().?;
        pml4.entries[pml4_index] = initSmallPage(ptr2Page(pdpt));

        for (0..512) |pdpt_index| {
            const pd = allocator.next().?;
            pdpt.entries[pdpt_index] = initSmallPage(ptr2Page(pd));

            for (0..512) |pd_index| {
                // TODO: This potentially maps pages that aren't in physical RAM
                // That's probably okay, but could be improved by leaving "dangling"
                // entries cleared
                const page_num = paging.build2MPageNum(pml4_index, pdpt_index, pd_index);
                if (page_num > page_count) {
                    // All pages after this can be left empty
                    break :init_loop;
                }
                pd.entries[pd_index] = initLargePage(page_num);
            }
        }
    }

    // Make sure all allocated pages were used
    std.debug.assert(allocator.next() == null);

    log.debug("end", .{});
    return pml4;
}

fn queryMemMap() !uefi.tables.MemoryMapSlice {
    const log = std.log.scoped(.queryMemMap);
    const boot_services = uefi.system_table.boot_services.?;

    log.debug("querying memory map size", .{});

    // Call once to find the table size
    var mem_map_info = try boot_services.getMemoryMapInfo();
    log.info("memory map requires size: {}", .{mem_map_info.len});

    if (mem_map_info.len == 0) {
        log.err("could not retrieve memory map size", .{});
        return error.FailedInit;
    }
    const default_descriptor_size = @sizeOf(uefi.tables.MemoryDescriptor);
    if (mem_map_info.descriptor_size < default_descriptor_size) {
        log.warn("invalid memory descriptor size: {}; using default: {}", .{ mem_map_info.descriptor_size, default_descriptor_size });
        mem_map_info.descriptor_size = default_descriptor_size;
    }

    // Add some size so the table can expand after the allocation
    const buf_len = (mem_map_info.len + 2) * mem_map_info.descriptor_size;
    log.info("allocating {} bytes for memory map", .{buf_len});

    // Use poll_allocator here since this doesn't need to be passed onto the OS
    // NOTE: This is not explicitly freed; it is just not marked as special in the memory map given to the OS
    // TODO: Use custom memory descriptor type?
    const mem_map_buf = try uefi.pool_allocator.alignedAlloc(
        u8,
        .of(uefi.tables.MemoryDescriptor),
        buf_len,
    );

    log.debug("querying memory map", .{});
    const mem_map = boot_services.getMemoryMap(mem_map_buf) catch |err| switch (err) {
        error.BufferTooSmall => {
            log.err("memory map didn't fit in size: {}", .{mem_map_buf.len});
            return err;
        },
        else => {
            log.err("error: {}", .{err});
            return err;
        },
    };

    log.debug("queried memory map: key={}, ptr={*}", .{ mem_map.info.key, mem_map.ptr });
    return mem_map;
}

fn memDescContains(desc: *uefi.tables.MemoryDescriptor, ptr: ?*anyopaque) bool {
    const addr: paging.PhysicalAddress = @intFromPtr(ptr);
    return desc.physical_start <= addr and desc.physical_start + desc.number_of_pages * 4096 < addr;
}

fn getMemEntType(desc: *uefi.tables.MemoryDescriptor) ozlib.bootboot.MMapType {
    if (memDescContains(desc, alloc_state.bootboot) or
        memDescContains(desc, alloc_state.kernel) or
        memDescContains(desc, alloc_state.page_tables_and_stack))
    {
        return .used;
    }
    return switch (desc.type) {
        .loader_code,
        .loader_data,
        .boot_services_code,
        .boot_services_data,
        .conventional_memory,
        => .free,
        .acpi_memory_nvs, .acpi_reclaim_memory => .acpi,
        .memory_mapped_io, .memory_mapped_io_port_space => .mmio,
        else => .used,
    };
}

fn parseMemMap(
    bootinfo: *ozlib.bootboot.Bootboot,
    mem_map: uefi.tables.MemoryMapSlice,
) !void {
    var dst_buf = bootinfo.mmapEntriesBuf();
    var dst_index: usize = 0;

    const MMapEnt = ozlib.bootboot.MMapEnt;

    var iter = mem_map.iterator();
    while (iter.next()) |entry| {
        std.log.debug("UEFI mem map entry: {}", .{entry});
        if (dst_index >= ozlib.bootboot.Bootboot.max_mmap_entries) {
            return error.TooManyMemoryMapEntries;
        }

        const typ: ozlib.bootboot.MMapType = getMemEntType(entry);
        const new_entry = MMapEnt.init(
            entry.physical_start,
            entry.number_of_pages * paging.page_size,
            typ,
        );

        if (dst_index == 0) {
            dst_buf[dst_index] = new_entry;
            dst_index += 1;
        } else if (dst_buf[dst_index - 1].tryMerge(&new_entry)) |merged| {
            dst_buf[dst_index - 1] = merged;
        } else {
            dst_buf[dst_index] = new_entry;
            dst_index += 1;
        }
    }
    // TODO: Don't assume sorted?

    bootinfo.setMMapEntriesLen(dst_index);

    for (bootinfo.mmapEntries()) |entry| {
        std.log.debug("Bootboot mem map entry: {}", .{.{ .ptr = entry.ptr, .size = entry.getSizeBytes(), .type = entry.getType() }});
    }
}

fn getBspid() u16 {
    var cpuid_ebx: u32 = undefined;
    asm volatile (
        \\mov $1, %%eax
        \\cpuid
        : [bspid] "={ebx}" (cpuid_ebx),
        :
        : .{ .eax = true, .ecx = true, .edx = true });
    return @intCast(cpuid_ebx >> 24);
}

fn initBootboot(fb: *uefi.protocol.GraphicsOutput) !*ozlib.bootboot.Bootboot {
    const bootboot_pages = try uefi.system_table.boot_services.?.allocatePages(
        .any,
        // TODO: Custom type?
        .loader_data,
        1,
    );
    const ptr: *ozlib.bootboot.Bootboot = @ptrCast(bootboot_pages.ptr);
    alloc_state.bootboot = ptr;

    const fb_type: ozlib.bootboot.FbType = switch (fb.mode.info.pixel_format) {
        .red_green_blue_reserved_8_bit_per_color => .abgr,
        .blue_green_red_reserved_8_bit_per_color => .argb,
        // TODO: Parse this in case it's one of the valid types
        .bit_mask => .none,
        .blt_only => .none,
    };

    ptr.* = .{
        .magic = ozlib.bootboot.magic,
        .protocol = .{
            .big_endian = false,
            .level = .static,
            .loader = .uefi,
        },

        // TODO: Support SMP
        .numcores = 1,
        .bspid = getBspid(),
        // TODO: Support initrd
        .initrd_ptr = 0,
        .initrd_size = 0,

        .fb_ptr = fb.mode.frame_buffer_base,
        .fb_size = @intCast(fb.mode.frame_buffer_size),
        .fb_width = fb.mode.info.horizontal_resolution,
        .fb_height = fb.mode.info.vertical_resolution,
        .fb_scanline = fb.mode.info.pixels_per_scan_line,
        .fb_type = fb_type,

        // TODO: Fetch time/date info
        .timezone = 0,
        .datetime = std.mem.zeroes(ozlib.bootboot.Datetime),

        .platform = .{
            .x64_64 = .{
                .efi_ptr = @intFromPtr(uefi.system_table),
                // TODO: Fetch this info
                .acpi_ptr = 0,
                .mp_ptr = 0,
                .smbi_ptr = 0,
            },
        },

        .mmap = .{},
        .size = ozlib.bootboot.Bootboot.computeSize(0),
    };

    return ptr;
}

pub fn setupFrameBuffer() !*uefi.protocol.GraphicsOutput {
    const gop_proto = (try uefi.system_table.boot_services.?.locateProtocol(uefi.protocol.GraphicsOutput, null)).?;

    // TODO: Search for specific-sized mode?
    // for (0..gop_proto.mode.max_mode) |mode_num| {
    // var info: *uefi.protocol.GraphicsOutput.Mode.Info = undefined;
    // var info_size: usize = @sizeOf(@TypeOf(info.*));
    // try gop_proto.queryMode(gop_proto.mode.mode, &info_size, &info).err();
    // }

    std.log.info("GOP mode: {}", .{gop_proto.mode});
    return gop_proto;
}

fn zigMain() !void {
    const log = std.log.scoped(.loader);

    log.info("Hello, loader!", .{});

    const loaded_image = (try uefi.system_table.boot_services.?.handleProtocol(
        uefi.protocol.LoadedImage,
        uefi.handle,
    )).?;

    log.debug("initializing frame buffer", .{});
    const fb = try setupFrameBuffer();
    log.debug("initialized frame buffer: {x}", .{fb.mode.frame_buffer_base});

    log.debug("allocating bootboot structure", .{});
    const bootboot = try initBootboot(fb);
    log.debug("allocated bootboot structure: {*}", .{bootboot});

    const watch_ptr: *volatile u32 = @ptrFromInt(0x10000);
    const base_ptr: *volatile u64 = @ptrFromInt(0x10008);
    watch_ptr.* = 0xDEADBEEF;
    base_ptr.* = @intFromPtr(loaded_image.image_base);

    const kernel_pages = try loadKernel();

    const pml4 = try createPageTables(bootboot, kernel_pages);

    const mem_map = try queryMemMap();
    try parseMemMap(bootboot, mem_map);

    log.info("current GDT: base={x} limit={}", .{ ozlib.interrupt.getGdtr().base, ozlib.interrupt.getGdtr().limit });
    log.info("current IDT: base={x} limit={}", .{ ozlib.interrupt.getIdtr().base, ozlib.interrupt.getIdtr().limit });

    log.debug("exiting boot services", .{});
    uefi.system_table.boot_services.?.exitBootServices(uefi.handle, mem_map.info.key) catch |err| {
        std.log.err("failed to exit: {}", .{err});
        return err;
    };
    log.debug("exited boot services", .{});

    log.debug("setting up page table: {*}", .{pml4});
    paging.setRootPageTable(@intFromPtr(pml4));

    ozlib.interrupt.pic.setEnabled(.{});
    ozlib.interrupt.nmiDisable();

    log.debug("entering kernel: {x}", .{ozlib.bootboot.kernel_start});

    // xor trick when kernel stack starts at 0
    comptime std.debug.assert(ozlib.bootboot.kernel_stack_init == 0);
    asm volatile (
        \\xorq %%rsp, %%rsp
        \\pushq %[main]
        \\ret
        :
        : [main] "i" (ozlib.bootboot.kernel_start),
    );
}

pub fn main() uefi.Status {
    // io.setupSerialLogger();
    zigMain() catch |err| {
        std.log.err("error: {}", .{err});
        return .load_error;
    };
    return .success;
}
