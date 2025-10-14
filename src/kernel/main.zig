const std = @import("std");
const builtin = @import("builtin");

// const zigimg = @import("zigimg");

const ozlib = @import("ozlib");
const paging = ozlib.paging;
const int = ozlib.interrupt;
const keyboard = ozlib.ps2.keyboard;
const mouse = ozlib.ps2.mouse;

const kdebug = @import("./debug.zig");

pub const std_options = std.Options{
    .log_level = .debug,
    .logFn = ozlib.io.debugConsoleLog,
    .page_size_min = paging.page_size,
    .page_size_max = paging.page_size,
    .queryPageSize = queryPageSize,
};

extern var bootinfo: ozlib.boot.Info;
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

var global_keyboard_controller = keyboard.Controller{};
var global_mouse_controller = mouse.Controller{};
var global_font = ozlib.font.Psf1Font.empty;
const font_data align(2) = @embedFile("assets/Lat15-Terminus16.psf").*;

var empty_fb = [0]ozlib.fb.Pixel{};
var global_video_fb = ozlib.FrameBuffer{
    .height = 0,
    .width = 0,
    .pixels_per_row = 0,
    .raw = &empty_fb,
};

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

    // TODO: Figure out why interruts are coming in while configuring the PS/2 devices
    setupInterrupts() catch |err| {
        std.log.err("failed to setup GDT and IDT: {}", .{err});
        kdebug.halt();
    };
    asm volatile ("int $0x32" ::: .{ .memory = true });

    int.pic.configure();
    int.pic.setMask(0xFFFF);

    const pml4: *paging.PageTable = @ptrFromInt(paging.getRootPageTable());

    setupKernelHeap(pml4, bootinfo.mmapEntries()) catch |err| {
        std.log.err("failed setting up heap: {}", .{err});
        kdebug.halt();
    };

    startupAps() catch |err| {
        std.log.err("failed to start APs: {}", .{err});
    };

    global_font = ozlib.font.Psf1Font.parse(os.heap.page_allocator, &font_data) catch |err| {
        std.log.err("failed to load font: {}", .{err});
        // TODO: Just continue on?
        kdebug.halt();
    };

    const ps2_port_config = ozlib.ps2.controller.configure() catch |err| {
        std.log.err("failed to configure PS/2 controller: {}", .{err});
        kdebug.halt();
    };
    var keyboard_enabled = false;
    var mouse_enabled = false;

    if (ps2_port_config.port1 == .keyboard) {
        keyboard_enabled = true;
        keyboard.configure() catch |err| {
            std.log.err("failed to configure PS/2 keyboard: {}", .{err});
            keyboard_enabled = false;
        };
    } else {
        std.log.warn("PS/2 keyboard not found on port 1", .{});
    }

    if (ps2_port_config.port2 == .mouse) {
        mouse_enabled = true;
        global_mouse_controller = mouse.Controller.configure() catch |err| mouse: {
            std.log.err("failed to configure PS/2 mouse: {}", .{err});
            mouse_enabled = false;
            break :mouse .{};
        };
    } else {
        std.log.warn("PS/2 mouse not found on port 2", .{});
    }

    keyboard.enable() catch |err| {
        std.log.err("failed to enable keyboard: {}", .{err});
        keyboard_enabled = false;
    };
    mouse.enable() catch |err| {
        std.log.err("failed to enable mouse: {}", .{err});
        mouse_enabled = false;
    };

    std.log.debug("enabling keyboard/mouse interrupts", .{});
    // TODO: Is there a "preferred" order for these?
    // Do this as a single atomic operations so that controller commands aren't interleaved with keyboard/mouse input
    ozlib.ps2.controller.enableInterrupts(keyboard_enabled, mouse_enabled) catch |err| {
        std.log.err("failed to enable PS/2 interrupts: {}", .{err});
        keyboard_enabled = false;
        mouse_enabled = false;
    };
    int.pic.setEnabled(.{ .keyboard = keyboard_enabled, .mouse = mouse_enabled });

    global_video_fb = ozlib.FrameBuffer{
        .raw = @ptrCast(&fb),
        .width = bootinfo.fb_width,
        .height = bootinfo.fb_height,
        .pixels_per_row = bootinfo.fb_scanline,
    };
    std.log.info("Frame buffer: width={} height={}", .{ global_video_fb.width, global_video_fb.height });
    global_video_fb.fill(.fromRgb(0, 0, 0), .fromSize(global_video_fb.width, global_video_fb.height));
    // var x_offset: i32 = 0;
    // const y_offset: i32 = 0;
    // while (true) {
    //     renderGradient(&global_video_fb, x_offset, y_offset);
    //     x_offset +%= 1;
    // }

    // switch (kallocator.deinit()) {
    //     .ok => {},
    //     .leak => {
    //         std.log.warn("leak detected", .{});
    //     },
    // }

    std.log.info("done", .{});
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
pub const kernel_heap_vma_end: paging.VirtualAddress = ozlib.boot.mmio_start;
pub const kernel_heap_vma_len: usize = kernel_heap_vma_end - kernel_heap_vma_start;

fn setupKernelHeap(pml4: *paging.PageTable, mem_map: []const ozlib.boot.MMapEnt) !void {
    const log = std.log.scoped(.setupKernelHeap);
    log.info("start", .{});

    var bootstrap_page_alloc = ozlib.alloc.BootinfoMMapPageAllocator.init(mem_map);
    // Reserve low memory pages for e.g. AP trampoline code
    // TODO: Figure out a better way to do this. Maybe start bootinfo allocator from some offset?
    _ = bootstrap_page_alloc.allocPages(256);
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

fn markInitialUsedPages(bitmap: *ozlib.alloc.PageBitmap, mem_map: []const ozlib.boot.MMapEnt) void {
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

fn calcAvailableMemoryPages(mem_map: []const ozlib.boot.MMapEnt) usize {
    var last_useable_addr: u64 = 0;
    for (mem_map) |ent| {
        if (ent.isFree()) {
            last_useable_addr = ent.ptr + ent.getSizeBytes();
        }
    }
    return last_useable_addr / paging.page_size;
}

const kernel_code_seg = 0x08;
const kernel_data_seg = 0x10;
const user_code_seg = 0x18;
const user_data_seg = 0x20;
const tss_seg = 0x28;
var gdt: [7]u64 = undefined;

var tss: int.TaskStateSegment = undefined;
var idt = [_]int.InterruptDescriptor{.empty} ** 256;

fn setupInterrupts() !void {
    gdt[0] = @bitCast(int.SegmentDescriptor.null_descriptor);

    gdt[kernel_code_seg / 8] = @bitCast(int.SegmentDescriptor.initCode(
        0,
        0xFFFFF,
        .{ .privilege_level = 0, .allow_lower = false, .readable = true },
        .{ .granularity = .pages, .protected_mode_32_bit = false, .long_mode = true },
    ));
    gdt[kernel_data_seg / 8] = @bitCast(int.SegmentDescriptor.initData(
        0,
        0xFFFFF,
        .{ .privilege_level = 0, .writeable = true },
        .{ .granularity = .pages, .protected_mode_32_bit = false, .long_mode = true },
    ));
    gdt[user_code_seg / 8] = @bitCast(int.SegmentDescriptor.initCode(
        0,
        0xFFFFF,
        .{ .privilege_level = 3, .allow_lower = true, .readable = true },
        .{ .granularity = .pages, .protected_mode_32_bit = false, .long_mode = true },
    ));
    gdt[user_data_seg / 8] = @bitCast(int.SegmentDescriptor.initData(
        0,
        0xFFFFF,
        .{ .privilege_level = 3, .writeable = true },
        .{ .granularity = .pages, .protected_mode_32_bit = false, .long_mode = false },
    ));

    const tss_entry: *int.LongModeSegmentDescriptor = @ptrCast(@alignCast(&gdt[tss_seg / 8]));
    // TSS
    // TODO: Figure out what this is for
    tss_entry.* = @bitCast(int.LongModeSegmentDescriptor.init(
        @intFromPtr(&tss),
        @sizeOf(@TypeOf(tss)),
        .{ .privilege_level = 0, .system_type = .tss_64_available },
        .{ .granularity = .bytes, .protected_mode_32_bit = false, .long_mode = false },
    ));

    // Max offset so that it's invalid
    tss.iopb = 0xFFFF;

    const int_selector = int.SegmentSelector{ .privilege_level = 0, .table = .gdt, .index = kernel_code_seg / 8 };
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
    inline for (0..15, int.pic.IRQ_OFFSET..) |pic_irq, vector| {
        idt[vector] = makeFallbackPicHandler(int_selector, vector, pic_irq);
    }

    // Custom handlers
    idt[int.pic.IRQ_OFFSET + keyboard.IRQ] = int.InterruptDescriptor.init(@intFromPtr(&keyboardHandler), int_selector, 0, .int, 0);
    idt[int.pic.IRQ_OFFSET + mouse.IRQ] = int.InterruptDescriptor.init(@intFromPtr(&mouseHandler), int_selector, 0, .int, 0);
    idt[0x32] = int.InterruptDescriptor.init(@intFromPtr(&int32Handler), int_selector, 0, .int, 0);

    int.disableInterrupts();
    std.log.info("interrupts disabled", .{});

    const gdt_limit = gdt.len * @sizeOf(@TypeOf(gdt[0])) - 1;
    std.log.info("setup GDT: offset={*} limit={}", .{ &gdt, gdt_limit });
    int.setGdtr(@intFromPtr(&gdt), gdt_limit);

    const idt_limit = @sizeOf(@TypeOf(idt)) - 1;
    std.log.info("setup IDT: offset={*} limit={}", .{ &idt, idt_limit });
    int.setIdtr(@intFromPtr(&idt), idt_limit);

    const kernel_data_selector = int.SegmentSelector{ .table = .gdt, .privilege_level = 0, .index = kernel_data_seg / 8 };
    int.setDataSegmentRegister(.ds, kernel_data_selector);
    int.setDataSegmentRegister(.es, kernel_data_selector);
    int.setDataSegmentRegister(.fs, kernel_data_selector);
    int.setDataSegmentRegister(.gs, kernel_data_selector);
    int.setDataSegmentRegister(.ss, kernel_data_selector);

    int.setCodeSegmentRegister(int.SegmentSelector{ .table = .gdt, .privilege_level = 0, .index = kernel_code_seg / 8 });

    int.nmiEnable();

    int.enableInterrupts();
    std.log.info("interrupts enabled", .{});
}

fn int32Handler() callconv(.{ .x86_64_interrupt = .{} }) void {
    std.log.info("int 0x32!", .{});
}

var cursor_x: usize = 0;
var cursor_y: usize = 0;
const empty_glyph = std.mem.zeroes([64]u8);
var layout_controller = keyboard.LayoutController{ .layout = &keyboard.us_layout };

fn keyboardHandler() callconv(.{ .x86_64_interrupt = .{} }) void {
    defer int.pic.sendMasterEoi();
    const raw_event = global_keyboard_controller.handleInterrupt() orelse return;
    std.log.debug("raw event={}", .{raw_event});
    const event = layout_controller.input(raw_event) orelse return;
    std.log.debug("mapped event={}", .{event});
    if (!event.pressed) return;
    switch (event.sym) {
        .up => {
            if (cursor_y > 0) cursor_y -= 1;
        },
        .left => {
            if (cursor_x > 0) cursor_x -= 1;
        },
        .down => {
            cursor_y += 1;
        },
        .right => {
            cursor_x += 1;
        },
        .space => {
            const x = cursor_x * (global_font.width + 1);
            const y = cursor_y * (global_font.height);
            ozlib.fb.renderBitmap(&global_video_fb, x, y, &empty_glyph, .{
                .fg = .fromRgb(255, 255, 255),
                .bg = .fromRgb(0, 0, 0),
                .width = global_font.width,
                .height = global_font.height,
                .padding = 1,
            });
            cursor_x += 1;
        },
        .backspace => {
            if (cursor_x == 0) return;
            cursor_x -= 1;
            const x = cursor_x * (global_font.width + 1);
            const y = cursor_y * (global_font.height);
            ozlib.fb.renderBitmap(&global_video_fb, x, y, &empty_glyph, .{
                .fg = .fromRgb(255, 255, 255),
                .bg = .fromRgb(0, 0, 0),
                .width = global_font.width,
                .height = global_font.height,
                .padding = 1,
            });
        },
        .enter => {
            cursor_x = 0;
            cursor_y += 1;
        },
        else => {
            const codepoint = event.sym.asCodepoint() orelse return;
            const glyph = global_font.getGlyphBitmap(codepoint) orelse return;
            const x = cursor_x * (global_font.width + 1);
            const y = cursor_y * (global_font.height);
            ozlib.fb.renderBitmap(&global_video_fb, x, y, glyph, .{
                .fg = .fromRgb(255, 255, 255),
                .bg = .fromRgb(0, 0, 0),
                .width = global_font.width,
                .height = global_font.height,
                .padding = 1,
            });
            cursor_x += 1;
        },
    }
}

fn mouseHandler() callconv(.{ .x86_64_interrupt = .{} }) void {
    defer int.pic.sendSlaveEoi();
    const event = global_mouse_controller.handleInterrupt() orelse return;
    std.log.info("mouse event: {}", .{event});
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

fn makeFallbackPicHandler(comptime selector: int.SegmentSelector, comptime vector: u8, comptime irq: u4) int.InterruptDescriptor {
    const S = struct {
        fn handler(frame: *int.InterruptFrame) callconv(.{ .x86_64_interrupt = .{} }) void {
            _ = frame;
            std.log.info("int v=0x{x:02}: IRQ{}", .{ vector, irq });
            int.pic.sendEoi(irq);
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

export fn apMain() callconv(.{
    .x86_64_sysv = .{
        // Normal stack alignment is 16 bytes before a `call` instruction. Since
        // code entering here isn't _called_, there is no return address on the
        // stack, which behaves like the stack was only 8-byte aligned before
        // calling this function.
        // TODO: Fix this by providing a return address instead?
        .incoming_stack_alignment = 8,
    },
}) void {
    apReady.store(true, .release);
    std.log.info("AP started!", .{});
    halt();
}

fn halt() noreturn {
    while (true) {
        asm volatile ("hlt");
    }
}
inline fn pause() void {
    asm volatile ("pause" ::: .{ .memory = true });
}

const pit = struct {
    const freq_hz = 1_193_182;
    pub const max_period_microseconds = std.math.maxInt(u16) * 1_000_000 / freq_hz;

    const CHANNEL0_PORT = 0x40;
    const CHANNEL1_PORT = 0x41;
    const CHANNEL2_PORT = 0x42;
    const CONTORL_PORT = 0x43;

    const inb = ozlib.port_io.inbComptimePort;
    const outb = ozlib.port_io.outbComptimePort;

    fn ticksFromMicroseconds(microseconds: u16) u16 {
        std.debug.assert(microseconds <= max_period_microseconds);
        // TODO: Always round up?
        // TODO: 0 actually means 65536
        return @intCast(freq_hz * @as(u64, microseconds) / 1_000_000);
    }

    pub fn configureOneshot(microseconds: u16) void {
        const reset = ticksFromMicroseconds(microseconds);
        outb(CONTORL_PORT, @bitCast(Control{ .mode = .oneshot, .rw = .lsb_msb, .index = 0 }));
        outb(CHANNEL0_PORT, @truncate(reset));
        outb(CHANNEL0_PORT, @truncate(reset >> 8));
    }

    fn readStatus() ReadBackStatus {
        outb(CONTORL_PORT, @bitCast(ReadBackCommand{
            .counter0 = true,
            .status_latch_disable = false,
        }));
        const status: ReadBackStatus = @bitCast(inb(CHANNEL0_PORT));
        return status;
    }

    pub fn isDone() bool {
        return readStatus().output;
    }

    const Control = packed struct(u8) {
        bcd: bool = false,
        mode: Mode,
        rw: RwMode,
        index: u2,
    };
    const Mode = enum(u3) {
        oneshot = 0b000,
        hw_oneshot = 0b001,
        rate = 0b010,
        rate_alt = 0b110,
        square = 0b011,
        square_alt = 0b111,
        strobe = 0b100,
        hw_strobe = 0b101,
    };
    const RwMode = enum(u2) {
        latch = 0,
        lsb_only = 1,
        msb_only = 2,
        lsb_msb = 3,
    };

    const ReadBackCommand = packed struct(u8) {
        _reserved1: u1 = 0,
        counter0: bool = false,
        counter1: bool = false,
        counter2: bool = false,
        status_latch_disable: bool = true,
        counter_latch_disable: bool = true,
        // Has to be 11
        _fixed_index: u2 = 0b11,
    };
    const ReadBackStatus = packed struct(u8) {
        bcd: bool,
        mode: Mode,
        rw: RwMode,
        null_count: bool,
        output: bool,
    };
};

fn shortSleep(micros: u16) void {
    pit.configureOneshot(micros);
    while (!pit.isDone()) {
        pause();
    }
}

fn sleep(micros: usize) void {
    var remaining = micros;
    while (remaining > pit.max_period_microseconds) {
        shortSleep(pit.max_period_microseconds);
        remaining -= pit.max_period_microseconds;
    }
    shortSleep(@intCast(remaining));
}

var apReady: std.atomic.Value(bool) = .init(false);
var bspDone: std.atomic.Value(bool) = .init(false);

extern const _ap_trampoline: u8;
extern const _ap_trampoline_end: u8;

/// CR3 has to have a 32-bit address
extern var _ap_arg_cr3: u32;
extern var _ap_arg_gdtr: int.DescriptorTableRegister;
extern var _ap_arg_sp: u64;

const ap_trampoline_load_addr = 0x8000;

const LocalApic = ozlib.interrupt.apic.Local;
// Initialize with default address, can be overridden later
var local_apic: *volatile LocalApic = @ptrFromInt(0xFEE0_0000);

fn startupAps() !void {
    var proc_infos: [255]?*align(1) const ozlib.acpi.Madt.LocalApic = .{null} ** 255;

    const rsdp: *const ozlib.acpi.Rsdp = @ptrFromInt(bootinfo.acpi_ptr);

    if (!rsdp.valid()) {
        std.log.warn("RSDP invalid: {}", .{rsdp});
        return;
    }

    const xsdt = rsdp.xsdtPtr();
    if (!xsdt.header.valid(ozlib.acpi.Xsdt.SIGNATURE)) {
        std.log.warn("XSDT invalid: {}", .{xsdt});
        return;
    }

    const madt: *const ozlib.acpi.Madt = xsdt.findTypedTable(ozlib.acpi.Madt) orelse return;
    // Can use this directly since pages are identity-mapped
    local_apic = @ptrFromInt(madt.local_controller_addr);
    var madt_iter = madt.iterator();
    var numcores: usize = 0;
    while (madt_iter.next()) |controller| {
        std.log.debug("found controller: {}", .{controller});
        switch (controller) {
            .local_apic => |local| {
                std.log.debug("found LAPIC: {*}={}", .{ local, local.* });
                proc_infos[numcores] = local;
                numcores += 1;
            },
            .local_apic_address_override => |override| {
                local_apic = @ptrFromInt(override.addr);
            },
            else => {},
        }
    }

    // 1 page for each AP
    // TODO: Is more required?
    // TODO: Map these stacks to sepcial locations?
    // TODO: Map each stack to the same location and provide each AP with a different page table?
    // TODO: Don't allocate stack page for BSP?
    const ap_stack_pages = try os.heap.page_allocator.alignedAlloc([4096]u8, .fromByteUnits(4096), numcores);

    // TODO: Check mem map to make sure this is free (or dynamically allocate it)
    const ap_trampoline_page: *[4096]u8 align(4096) = @ptrFromInt(ap_trampoline_load_addr);
    std.log.debug("ap_load_addr: {*}", .{ap_trampoline_page});
    const ap_trampoline_len = @intFromPtr(&_ap_trampoline_end) - @intFromPtr(&_ap_trampoline);
    @memcpy(ap_trampoline_page[0..ap_trampoline_len], @as([*]const u8, @ptrCast(&_ap_trampoline)));

    const pml4_addr = ozlib.paging.getRootPageTable();
    // TODO: Ensure this when allocating
    std.debug.assert(pml4_addr <= std.math.maxInt(u32));
    _ap_arg_cr3 = @truncate(pml4_addr);
    _ap_arg_gdtr = int.getGdtr();

    local_apic.set(.local_dest, LocalApic.Destination{ .target = 1 });
    local_apic.set(.dest_fmt, LocalApic.DestinationFormat{ .model = .flat });
    local_apic.set(.spurious, LocalApic.SpuriousVector{ .vector = 0xFF, .enable = true });
    local_apic.set(.tpr, 0);
    const bsp_apic_id = local_apic.getId();
    std.log.info("BSP LAPIC ID: {}", .{bsp_apic_id});

    // TODO: For APS
    //
    // enable Local APIC
    // *((volatile uint32_t*)(lapic_addr + 0x0F0)) = *((volatile uint32_t*)(lapic_addr + 0x0F0)) | 0x100;
    // core_num = lapic_ids[*((volatile uint32_t*)(lapic_addr + 0x20)) >> 24];

    std.log.info("starting {} APs", .{numcores - 1});
    var successfulStarted: u8 = 0;
    for (0..numcores) |proc_index| {
        const info = proc_infos[proc_index] orelse continue;
        const lapic_id = info.id;
        const proc_uid = info.processor_uid;
        if (lapic_id == bsp_apic_id) continue;

        const stack_page = &ap_stack_pages[proc_index];
        _ap_arg_sp = @intFromPtr(stack_page) + stack_page.len;

        apReady.store(false, .release);
        std.log.info("starting AP: LAPIC={} UID={}", .{ lapic_id, proc_uid });

        std.log.debug("sending INIT IPI", .{});
        local_apic.sendIpi(lapic_id, .{ .vector = 0, .delivery_mode = .init });
        // TOOD: Poll more frequently
        sleep(LocalApic.ipi_delivery_timeout_us);
        if (local_apic.ipiPending()) {
            std.log.err("failed to send INIT IPI: {}", .{local_apic.getErrorStatus()});
            continue;
        }
        std.log.debug("sent INIT IPI", .{});
        sleep(1);

        std.log.debug("sending INIT IPI de-assert", .{});
        local_apic.sendIpi(lapic_id, .{ .vector = 0, .delivery_mode = .init, .level_assert = false, .level_triggered = true });
        // TOOD: Poll more frequently
        sleep(LocalApic.ipi_delivery_timeout_us);
        if (local_apic.ipiPending()) {
            std.log.err("failed to send INIT de-assert IPI: {}", .{local_apic.getErrorStatus()});
            continue;
        }
        std.log.debug("sent INIT IPI de-assert", .{});
        sleep(10_000);

        std.log.debug("sending STARTUP IPI 1", .{});
        const startupVector: u8 = @intCast(ap_trampoline_load_addr / 4096);
        local_apic.sendIpi(lapic_id, .{ .vector = startupVector, .delivery_mode = .startup });
        // TOOD: Poll more frequently
        sleep(LocalApic.ipi_delivery_timeout_us);
        if (local_apic.ipiPending()) {
            std.log.err("failed to send STARTUP IPI 1: {}", .{local_apic.getErrorStatus()});
            continue;
        }
        std.log.debug("sent STARTUP IPI 1", .{});
        // sleep(200);
        sleep(1000);

        std.log.debug("checking apDone", .{});
        if (!apReady.load(.acquire)) {
            std.log.debug("sending STARTUP IPI 2", .{});
            local_apic.sendIpi(lapic_id, .{ .vector = startupVector, .delivery_mode = .startup });
            // TOOD: Poll more frequently
            sleep(LocalApic.ipi_delivery_timeout_us);
            if (local_apic.ipiPending()) {
                std.log.err("failed to send STARTUP IPI 2: {}", .{local_apic.getErrorStatus()});
                continue;
            }
            std.log.debug("sent STARTUP IPI 2", .{});
            // sleep(200);

            sleep(1_000_000);
            std.log.debug("checking apDone", .{});
            if (!apReady.load(.acquire)) {
                std.log.err("failed to start AP: LAPIC={} UID={}", .{ lapic_id, proc_uid });
                continue;
            }
        }

        std.log.debug("started AP: LAPIC={} UID={}", .{ lapic_id, proc_uid });
        successfulStarted += 1;
    }
    std.log.debug("successfully started {} APs", .{successfulStarted});
}
