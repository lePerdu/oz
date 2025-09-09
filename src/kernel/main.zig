const std = @import("std");
const builtin = @import("builtin");

// const zigimg = @import("zigimg");

const ozlib = @import("ozlib");
const paging = ozlib.paging;
const int = ozlib.interrupt;

const kdebug = @import("./debug.zig");

pub const std_options = std.Options{
    .log_level = .debug,
    .logFn = ozlib.io.debugConsoleLog,
    .page_size_min = paging.page_size,
    .page_size_max = paging.page_size,
    .queryPageSize = queryPageSize,
};

extern var bootboot: ozlib.bootboot.Bootboot;
extern var fb: anyopaque;

extern const _kernel_start: u8;
extern const _kernel_end: u8;

fn getKernelSize() usize {
    return @intFromPtr(&_kernel_end) - @intFromPtr(&_kernel_start);
}

fn queryPageSize() usize {
    return paging.page_size;
}

pub const panic = std.debug.FullPanic(kdebug.panic);

pub const os = struct {
    pub const heap = struct {
        const page_allocator = kernel_heap_state.allocator();
    };
};

/// All kernel heap allocator state packaged up for easier returning/storing.
/// TODO: Figure out a way to make this non-global
var kernel_heap_state: struct {
    page_bitmap: ozlib.alloc.PageBitmap = undefined,
    heap_region: ozlib.alloc.PagedHeapRegion = undefined,

    pub fn allocator(self: *@This()) std.mem.Allocator {
        // Just takes the self parameter to make the function easier to call
        _ = self;
        return .{
            .ptr = undefined,
            .vtable = &std.heap.SbrkAllocator(kernel_heap_sbrk).vtable,
        };
    }

    fn kernel_heap_sbrk(n: usize) usize {
        return kernel_heap_state.heap_region.extend(n);
    }
} = .{};

fn ioWait() void {
    ozlib.port_io.outbComptimePort(0x80, 0);
}

export fn main() callconv(.{
    .x86_64_sysv = .{
        // Normal stack alignment is 16 bytes before a `call` instruction. Since
        // code entering here isn't _called_, there is no return address on the
        // stack, which behaves like the stack was only 8-byte aligned before
        // calling this function.
        // TODO: Fix this by providing a return address instead?
        .incoming_stack_alignment = 8,
    },
}) noreturn {
    std.log.info("Hello, kernel!", .{});
    std.log.info("Kernel size: {} B ({} KiB)", .{ getKernelSize(), getKernelSize() / 1024 });

    const pml4: *paging.PageTable = @ptrFromInt(paging.getRootPageTable());

    setupKernelHeap(pml4, bootboot.mmapEntries()) catch |err| {
        std.log.err("failed setting up heap: {}", .{err});
        kdebug.halt();
    };

    setupInterrupts() catch |err| {
        std.log.err("failed to setup GDT and IDT: {}", .{err});
        kdebug.halt();
    };
    asm volatile ("int $0x32" ::: .{ .memory = true });

    // Test out fault handler
    // const ptr: *u8 = @ptrFromInt(0xFF12_0013_9942_FDEE);
    // const b = ptr.*;
    // std.log.info("bogus value: {}", .{b});

    const out = ozlib.port_io.outbComptimePort;
    const in = ozlib.port_io.inbComptimePort;
    const k = ozlib.keyboard;

    // https://wiki.osdev.org/I8042_PS/2_Controller#Initialising_the_PS/2_Controller

    // Disable
    out(k.COMMAND_PORT, 0xAD);
    out(k.COMMAND_PORT, 0xA7);

    // Flush input buffer
    while (in(k.COMMAND_PORT) & 1 != 0) {
        _ = in(k.DATA_PORT);
    }

    // Update config:
    // - Port 1 clock enabled, but interrupts and translation disabled
    // - Port 2 fully disabled
    out(k.COMMAND_PORT, 0x20);
    while (in(k.COMMAND_PORT) & 1 == 0) {
        // Spin
    }
    var config = in(k.DATA_PORT);
    config &= 0b0000_0100;
    config |= 0b0010_0000;
    out(k.COMMAND_PORT, 0x60);
    while (in(k.COMMAND_PORT) & 2 == 1) {
        // Spin
    }
    out(k.DATA_PORT, config);

    // Self test
    out(k.COMMAND_PORT, 0xAA);
    while (in(k.COMMAND_PORT) & 1 == 0) {
        // Spin
    }
    const self_test_result = in(k.DATA_PORT);
    std.log.info("PS/2 controller self test: 0x{x}", .{self_test_result});

    // Reset config after self test in case it was reset
    out(k.COMMAND_PORT, 0x60);
    while (in(k.COMMAND_PORT) & 2 == 1) {
        // Spin
    }
    out(k.DATA_PORT, config);

    // TODO: Determine if both ports are available

    // Test port 1
    out(k.COMMAND_PORT, 0xAB);
    while (in(k.COMMAND_PORT) & 1 == 0) {
        // Spin
    }
    const port1_test = in(k.DATA_PORT);
    std.log.info("PS/2 controller port1 test: 0x{x}", .{port1_test});

    // Enable
    out(k.COMMAND_PORT, 0xAE);

    // Enable IRQ1
    config |= 0b0000_0001;
    out(k.COMMAND_PORT, 0x60);
    while (in(k.COMMAND_PORT) & 2 == 1) {
        // Spin
    }
    out(k.DATA_PORT, config);

    k.sendData(.reset);
    ioWait();
    const res1 = in(k.DATA_PORT);
    ioWait();
    const res2 = in(k.DATA_PORT);
    std.log.info("reset res: 0x{x} 0x{x}", .{ res1, res2 });

    // TODO: Detect device type before configuring

    ioWait();
    k.sendData(.scan_code_sets);
    ioWait();
    out(k.DATA_PORT, 2);
    ioWait();
    const scan_code_set_res = in(k.DATA_PORT);
    std.log.info("scan code set res: 0x{x}", .{scan_code_set_res});

    ioWait();
    ozlib.keyboard.sendData(.enable_scanning);
    ioWait();
    const enable_scan_res = in(k.DATA_PORT);
    std.log.info("enable scan res: 0x{x}", .{enable_scan_res});

    // Configure and remap PIC

    const ICW1_ICW4 = 0x01;
    // const ICW1_SINGLE = 0x02;
    // const ICW1_INTERVAL4 = 0x04;
    // const ICW1_LEVEL = 0x08;
    const ICW1_INIT = 0x10;

    const ICW4_8086 = 0x10;
    // const ICW4_AUTO = 0x02;
    // const ICW4_BUF_SLAVE = 0x08;
    // const ICW4_BUF_MASTER = 0x0C;
    // const ICW4_SFNM = 0x10;

    const CASCADE_IRQ = 2;

    const master_offset = 0x20;
    const slave_offset = master_offset + 8;
    out(int.PIC_MASTER_COMMAND_PORT, ICW1_INIT | ICW1_ICW4);
    ioWait();
    out(int.PIC_SLAVE_COMMAND_PORT, ICW1_INIT | ICW1_ICW4);
    ioWait();
    out(int.PIC_MASTER_DATA_PORT, master_offset);
    ioWait();
    out(int.PIC_SLAVE_DATA_PORT, slave_offset);
    ioWait();
    out(int.PIC_MASTER_DATA_PORT, 1 << CASCADE_IRQ);
    ioWait();
    out(int.PIC_SLAVE_DATA_PORT, CASCADE_IRQ);
    ioWait();

    out(int.PIC_MASTER_DATA_PORT, ICW4_8086);
    ioWait();
    out(int.PIC_SLAVE_DATA_PORT, ICW4_8086);
    ioWait();

    // Unmask keyboard and slave
    out(int.PIC_MASTER_DATA_PORT, 0b1111_1001);
    out(int.PIC_SLAVE_DATA_PORT, 0xFF);

    // Dummy reads to clear buffer after enabling interrupts
    // _ = in(k.DATA_PORT);
    // _ = in(k.DATA_PORT);
    // _ = in(k.DATA_PORT);
    // _ = in(k.DATA_PORT);

    var video_fb = ozlib.FrameBuffer{
        .raw = @ptrCast(&fb),
        .width = bootboot.fb_width,
        .height = bootboot.fb_height,
        .pixels_per_row = bootboot.fb_scanline,
    };
    std.log.info("Frame buffer: width={} height={}", .{ video_fb.width, video_fb.height });
    renderGradient(&video_fb, 0, 0);
    // var x_offset: i32 = 0;
    // const y_offset: i32 = 0;
    // while (true) {
    //     renderGradient(&video_fb, x_offset, y_offset);
    //     x_offset +%= 1;
    // }

    // switch (kallocator.deinit()) {
    //     .ok => {},
    //     .leak => {
    //         std.log.warn("leak detected", .{});
    //     },
    // }

    std.log.info("done", .{});
    while (true) {
        ioWait();
    }
    kdebug.halt();
}

fn renderGradient(video_fb: *ozlib.FrameBuffer, x_offset: i32, y_offset: i32) void {
    for (0..video_fb.height) |y| {
        const y_: i32 = @intCast(y);
        for (0..video_fb.width) |x| {
            const x_: i32 = @intCast(x);
            video_fb.set(x, y, .{
                .r = 0,
                .g = @intCast((y_ + y_offset) & 0xFF),
                .b = @intCast((x_ + x_offset) & 0xFF),
            });
        }
    }
}

pub const kernel_heap_vma_start: paging.VirtualAddress = 0xFFFF_C000_0000_0000;
pub const kernel_heap_vma_end: paging.VirtualAddress = ozlib.bootboot.mmio_start;
pub const kernel_heap_vma_len: usize = kernel_heap_vma_end - kernel_heap_vma_start;

fn setupKernelHeap(pml4: *paging.PageTable, mem_map: []const ozlib.bootboot.MMapEnt) !void {
    const log = std.log.scoped(.setupKernelHeap);
    log.info("start", .{});

    var bootstrap_page_alloc = ozlib.alloc.BootbootMMapPageAllocator.init(mem_map);
    kernel_heap_state.heap_region = .init(
        pml4,
        bootstrap_page_alloc.allocator(),
        kernel_heap_vma_start,
        kernel_heap_vma_len,
    );
    const bootstrap_allocator = kernel_heap_state.allocator();

    const page_count = calcAvailableMemoryPages(mem_map);
    log.debug("allocating bitmap data", .{});
    const bitmap_data = try bootstrap_allocator.alignedAlloc(u8, .fromByteUnits(paging.page_size), page_count);
    log.debug("allocated bitmap data: {*}", .{bitmap_data});
    var bitmap = ozlib.alloc.PageBitmap.init(bitmap_data, page_count);
    // Mark space used for bitmap allocations
    log.debug("marking bootstrap allocator allocations as used", .{});
    bitmap.markRangeUsed(0, bootstrap_page_alloc.getNextUnallocatedPage());
    log.debug("marking pages from memory map as used", .{});
    markInitialUsedPages(&bitmap, mem_map);
    log.debug("done", .{});

    kernel_heap_state.page_bitmap = bitmap;
    // Can't use the local variable since .allocator() takes a reference
    kernel_heap_state.heap_region.page_alloc = kernel_heap_state.page_bitmap.allocator();
}

fn markInitialUsedPages(bitmap: *ozlib.alloc.PageBitmap, mem_map: []const ozlib.bootboot.MMapEnt) void {
    // Track the end of the previous entry to detect and handle gaps in the memory map
    // The memory map is assumed to be sorted
    var previous_end: paging.PhysicalAddress = 0;
    for (mem_map) |region| {
        if (region.ptr > previous_end) {
            // Gaps are always considered "used"
            const base = paging.addressToPageNum(previous_end);
            const len = paging.addressToPageNum(region.ptr - previous_end);
            bitmap.markRangeUsed(base, len);
        }
        if (!region.isFree()) {
            const base = paging.addressToPageNum(region.ptr);
            bitmap.markRangeUsed(base, region.getSizePages());
        }
        previous_end = region.ptr + region.getSizeBytes();
    }
}

fn printPT(context: *anyopaque, level: paging.PageLevel, table: *paging.PageTable) error{Break}!void {
    _ = context;
    std.log.debug("{}: {*}", .{ level, table });
}

fn printPageTables(pml4: *paging.PageTable) void {
    paging.visitPageTables(pml4, undefined, printPT);
}

fn calcAvailableMemoryPages(mem_map: []const ozlib.bootboot.MMapEnt) usize {
    var last_useable_addr: u64 = 0;
    for (mem_map) |ent| {
        if (ent.isFree()) {
            last_useable_addr = ent.ptr + ent.getSizeBytes();
        }
    }
    return last_useable_addr / paging.page_size;
}

fn setupInterrupts() !void {
    // TODO: This doesn't actually allocate full pages. Is that ok?
    const page_allocator = os.heap.page_allocator;
    const region = try page_allocator.alloc(u8, @sizeOf(int.InterruptDescriptorTable) + 4096);
    @memset(region, 0);
    var offset: usize = 0;

    const idt: *int.InterruptDescriptorTable = @ptrCast(@alignCast(&region[offset]));
    offset += @sizeOf(int.InterruptDescriptorTable);

    const tss: *int.TaskStateSegment = @ptrCast(@alignCast(&region[offset]));
    // TODO: Save pointer and fill in data
    offset += @sizeOf(@TypeOf(tss.*));

    offset = std.mem.alignForward(usize, offset, @alignOf(int.SegmentDescriptor));
    const gdt = std.mem.bytesAsSlice(u64, region[offset..]);
    gdt[0] = @bitCast(int.SegmentDescriptor.null_descriptor);

    // Kernel code
    const kernel_code_index = 1;
    gdt[1] = @bitCast(int.SegmentDescriptor.initCode(
        0,
        0xFFFFF,
        .{ .privilege_level = 0, .allow_lower = false, .readable = true },
        .{ .granularity = .pages, .protected_mode_32_bit = false, .long_mode = true },
    ));
    // Kernel data
    const kernel_data_index = 2;
    gdt[2] = @bitCast(int.SegmentDescriptor.initData(
        0,
        0xFFFFF,
        .{ .privilege_level = 0, .writeable = true },
        .{ .granularity = .pages, .protected_mode_32_bit = true, .long_mode = false },
    ));
    // User code
    // const user_code_index = 3;
    gdt[3] = @bitCast(int.SegmentDescriptor.initCode(
        0,
        0xFFFFF,
        .{ .privilege_level = 3, .allow_lower = true, .readable = true },
        .{ .granularity = .pages, .protected_mode_32_bit = false, .long_mode = true },
    ));
    // User data
    // const user_data_index = 4;
    gdt[4] = @bitCast(int.SegmentDescriptor.initData(
        0,
        0xFFFFF,
        .{ .privilege_level = 3, .writeable = true },
        .{ .granularity = .pages, .protected_mode_32_bit = true, .long_mode = false },
    ));

    const tss_entry: *int.LongModeSegmentDescriptor = @ptrCast(@alignCast(&gdt[5]));
    // TSS
    // TODO: Figure out what this is for
    tss_entry.* = @bitCast(int.LongModeSegmentDescriptor.init(
        @intFromPtr(tss),
        @sizeOf(@TypeOf(tss.*)),
        .{ .privilege_level = 0, .system_type = .tss_64_available },
        .{ .granularity = .bytes, .protected_mode_32_bit = false, .long_mode = false },
    ));

    const gdt_size = 5 * 8 + 1 * 16;
    offset += 7 * 8;

    const int_selector = int.SegmentSelector{ .privilege_level = 0, .table = .gdt, .index = kernel_code_index };
    // Setup handlers that take an error code
    idt[0x00] = makeExceptionHandler(int_selector, "divide error", 0x00, .trap);
    idt[0x01] = makeExceptionHandler(int_selector, "debug exception", 0x01, .trap);
    idt[0x02] = makeExceptionHandler(int_selector, "nmi", 0x02, .int);
    idt[0x03] = makeExceptionHandler(int_selector, "breakpoint", 0x03, .trap);
    idt[0x04] = makeExceptionHandler(int_selector, "overflow", 0x04, .trap);
    idt[0x05] = makeExceptionHandler(int_selector, "bound range exceeded", 0x05, .trap);
    idt[0x06] = makeExceptionHandler(int_selector, "invalid opcode", 0x06, .trap);
    idt[0x07] = makeExceptionHandler(int_selector, "coprocessor not available", 0x07, .trap);
    idt[0x08] = makeExceptionHandlerWithCode(int_selector, "double fault", 0x08, .trap);
    idt[0x09] = makeExceptionHandler(int_selector, "coprocessor segment overrun", 0x09, .trap);
    idt[0x0A] = makeExceptionHandlerWithCode(int_selector, "invalid TSS", 0x0A, .trap);
    idt[0x0B] = makeExceptionHandlerWithCode(int_selector, "segment not present", 0x0B, .trap);
    idt[0x0C] = makeExceptionHandlerWithCode(int_selector, "stack segment fault", 0x0C, .trap);
    idt[0x0D] = makeExceptionHandlerWithCode(int_selector, "general protection fault", 0x0D, .trap);
    idt[0x0E] = makeExceptionHandlerWithCode(int_selector, "page fault", 0x0E, .trap);
    // 0x0F reserved
    idt[0x10] = makeExceptionHandler(int_selector, "math fault", 0x10, .trap);
    idt[0x11] = makeExceptionHandlerWithCode(int_selector, "alignment check", 0x11, .trap);
    idt[0x12] = makeExceptionHandler(int_selector, "machine check", 0x12, .trap);
    idt[0x13] = makeExceptionHandler(int_selector, "SIMD floating-point exception", 0x13, .trap);
    idt[0x14] = makeExceptionHandler(int_selector, "virtualization exception", 0x14, .trap);
    idt[0x15] = makeExceptionHandlerWithCode(int_selector, "control protection fault", 0x15, .trap);
    // 0x16-0x1f reserved

    // Add in fallback handlers that send EoI to the PIC to avoid lock-ups
    inline for (0x20..0x30, 0..) |vector, irq| {
        idt[vector] = makeFallbackPicHandler(int_selector, vector, irq);
    }

    // Custom handlers
    idt[0x20 + ozlib.keyboard.IRQ] = int.InterruptDescriptor.init(@intFromPtr(&keyboardHandler), int_selector, 0, .int, 0);
    idt[0x32] = int.InterruptDescriptor.init(@intFromPtr(&int32Handler), int_selector, 0, .int, 0);

    int.disableInterrupts();
    std.log.info("interrupts disabled", .{});

    std.log.info("setup GDT: offset={*} limit={}", .{ gdt.ptr, gdt_size - 1 });
    int.setGdtr(@intFromPtr(gdt.ptr), gdt_size - 1);

    std.log.info("setup IDT: offset={*} limit={}", .{ idt, @sizeOf(@TypeOf(idt.*)) - 1 });
    int.setIdtr(@intFromPtr(idt), @sizeOf(@TypeOf(idt.*)) - 1);

    const kernel_data_selector = int.SegmentSelector{ .table = .gdt, .privilege_level = 0, .index = kernel_data_index };
    int.setDataSegmentRegister(.ds, kernel_data_selector);
    int.setDataSegmentRegister(.es, kernel_data_selector);
    int.setDataSegmentRegister(.fs, kernel_data_selector);
    int.setDataSegmentRegister(.gs, kernel_data_selector);
    int.setDataSegmentRegister(.ss, kernel_data_selector);

    int.setCodeSegmentRegister(int.SegmentSelector{ .table = .gdt, .privilege_level = 0, .index = kernel_code_index });

    int.nmiEnable();

    int.enableInterrupts();
    std.log.info("interrupts enabled", .{});
}

fn int32Handler() callconv(.{ .x86_64_interrupt = .{} }) void {
    std.log.info("int 0x32!", .{});
}

fn keyboardHandler() callconv(.{ .x86_64_interrupt = .{} }) void {
    const b = ozlib.keyboard.readData();
    std.log.info("keyboard interrupt: 0x{x:02}", .{b});
    int.picMasterEoi();
}

fn makeExceptionHandler(comptime selector: int.SegmentSelector, comptime name: []const u8, comptime vector: u8, comptime gate_type: int.GateType) int.InterruptDescriptor {
    const S = struct {
        fn handler(frame: *int.InterruptFrame) callconv(.{ .x86_64_interrupt = .{} }) void {
            _ = frame;
            std.log.info("int v=0x{x:02}: {s}", .{ vector, name });
            kdebug.halt();
        }
    };
    return int.InterruptDescriptor.init(@intFromPtr(&S.handler), selector, 0, gate_type, 0);
}

fn makeExceptionHandlerWithCode(comptime selector: int.SegmentSelector, comptime name: []const u8, comptime vector: u8, comptime gate_type: int.GateType) int.InterruptDescriptor {
    const S = struct {
        fn handler(frame: *int.InterruptFrame, code: usize) callconv(.{ .x86_64_interrupt = .{} }) void {
            _ = frame;
            std.log.info("int v=0x{x:02} e=0x{x:04}: {s}", .{ vector, code, name });
            kdebug.halt();
        }
    };
    return int.InterruptDescriptor.init(@intFromPtr(&S.handler), selector, 0, gate_type, 0);
}

fn makeFallbackPicHandler(comptime selector: int.SegmentSelector, comptime vector: u8, comptime irq: u8) int.InterruptDescriptor {
    const S = struct {
        fn handler(frame: *int.InterruptFrame) callconv(.{ .x86_64_interrupt = .{} }) void {
            _ = frame;
            std.log.info("int v=0x{x:02}: IRQ{}", .{ vector, irq });
            int.picEoi(irq);
        }
    };
    return int.InterruptDescriptor.init(@intFromPtr(&S.handler), selector, 0, .int, 0);
}

// const IMAGE_JPEG = @embedFile("./assets/shrimp.jpeg");

// fn renderImage(video_fb: *ozlib.FrameBuffer) !void {
//     // Allocate image before the UEFI allocator goes away
//     var image = try zigimg.Image.fromMemory(os.heap.page_allocator, IMAGE_JPEG);
//     // Can't free after exiting boot services
//     // defer image.deinit();
//     // alpha channel is unused, but needs to be there for alignment
//     try image.convert(.bgra32);
//     std.log.info("JPEG: pixel format: {}", .{image.pixelFormat()});
//     std.log.info("JPEG: size: {}x{}", .{ image.width, image.height });

//     const image_buf = ozlib.FrameBuffer.init(
//         @ptrCast(image.pixels.bgra32),
//         @intCast(image.width),
//         @intCast(image.height),
//     );

//     const color = ozlib.fb.Pixel{ .b = 24, .g = 255, .r = 94 };
//     video_fb.fill(
//         color,
//         .{
//             .base = .{ .x = 5, .y = 5 },
//             .size = .{
//                 .x = video_fb.width - 10,
//                 .y = video_fb.height - 10,
//             },
//         },
//     );

//     video_fb.blt(
//         &image_buf,
//         .{
//             .size = .{
//                 .x = image_buf.width,
//                 .y = image_buf.height,
//             },
//         },
//         .{},
//     );
// }
