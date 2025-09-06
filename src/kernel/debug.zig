const std = @import("std");
const builtin = @import("builtin");
const ozlib = @import("ozlib");

pub fn halt() noreturn {
    while (true) {
        asm volatile ("hlt");
    }
}

var panic_allocator_buf: [128 * 1024]u8 = undefined;
var panic_allocator_state = std.heap.FixedBufferAllocator.init(panic_allocator_buf[0..]);
const panic_allocator = panic_allocator_state.allocator();

pub fn panic(msg: []const u8, return_addr: ?usize) noreturn {
    defer halt();

    const stderr = ozlib.io.debugConsoleWriter;
    if (return_addr) |ret| {
        stderr.print("panic@{x:016}: {s}\n", .{ ret, msg }) catch {};
        // TODO: Figure out how to get debug symbols in the binary
        // if (builtin.strip_debug_info and false) {
        //     stderr.print("Unable to dump stack trace: debug info stripped\n", .{}) catch {};
        //     return;
        // }
        // var debug_info = getSelfDebugInfo(panic_allocator) catch |err| {
        //     stderr.print("Unable to dump stack trace: Unable to open debug info: {s}\n", .{@errorName(err)}) catch {};
        //     return;
        // };
        // // TODO: Cache in memory like std.debug.getSelfDebugInfo()?
        // defer debug_info.deinit(panic_allocator);

        // // TODO: Use escape codes?
        // const tty_config = std.io.tty.Config.no_color;

        // var it = std.debug.StackIterator.init(ret, null);
        // defer it.deinit();

        // while (it.next()) |return_address| {
        //     // TODO: Why isn't this pub?
        //     // std.debug.printLastUnwindError(&it, &debug_info, stderr, tty_config);

        //     // On arm64 macOS, the address of the last frame is 0x0 rather than 0x1 as on x86_64 macOS,
        //     // therefore, we do a check for `return_address == 0` before subtracting 1 from it to avoid
        //     // an overflow. We do not need to signal `StackIterator` as it will correctly detect this
        //     // condition on the subsequent iteration and return `null` thus terminating the loop.
        //     // same behaviour for x86-windows-msvc
        //     const address = return_address -| 1;
        //     try printSourceAtAddress(panic_allocator, &debug_info, stderr, address, tty_config);
        // } // else std.debug.printLastUnwindError(&it, &debug_info, stderr, tty_config);
    } else {
        stderr.print("panic: {s}\n", .{msg}) catch {};
    }
}

var _kernel_eh_frame_start: u8 = 0;
var _kernel_eh_frame_end: u8 = 0;
var _kernel_eh_frame_hdr_start: u8 = 0;
var _kernel_eh_frame_hdr_end: u8 = 0;

// extern var _kernel_debug_info_start: u8;
// extern var _kernel_debug_info_end: u8;
// extern var _kernel_debug_abbrev_start: u8;
// extern var _kernel_debug_abbrev_end: u8;
// extern var _kernel_debug_str_start: u8;
// extern var _kernel_debug_str_end: u8;
// extern var _kernel_debug_line_start: u8;
// extern var _kernel_debug_line_end: u8;
// extern var _kernel_debug_ranges_start: u8;
// extern var _kernel_debug_ranges_end: u8;

fn initSection(start: *u8, end: *u8) std.debug.Dwarf.Section {
    const ptr: [*]u8 = @ptrCast(start);
    const len = @intFromPtr(end) - @intFromPtr(start);
    return .{
        .data = ptr[0..len],
        .owned = false,
    };
}

fn getSelfDebugInfo(allocator: std.mem.Allocator) !std.debug.Dwarf {
    const Dwarf = std.debug.Dwarf;
    const SecId = Dwarf.Section.Id;

    var dwarf_info = Dwarf{
        .endian = .little,
        .is_macho = false,
    };
    // These sections aren't relocated properly by the linker, so need to
    // use initSection()
    // dwarf_info.sections[@intFromEnum(SecId.debug_info)] =
    //     initSection(&_kernel_debug_info_section_start, &_kernel_debug_info_section_end);
    // dwarf_info.sections[@intFromEnum(SecId.debug_abbrev)] =
    //     initSection(&_kernel_debug_abbrev_section_start, &_kernel_debug_abbrev_section_end);
    // dwarf_info.sections[@intFromEnum(SecId.debug_str)] =
    //     initSection(&_kernel_debug_str_section_start, &_kernel_debug_str_section_end);
    // dwarf_info.sections[@intFromEnum(SecId.debug_line)] =
    //     initSection(&_kernel_debug_line_section_start, &_kernel_debug_line_section_end);
    // dwarf_info.sections[@intFromEnum(SecId.debug_ranges)] =
    //     initSection(&_kernel_debug_ranges_section_start, &_kernel_debug_ranges_section_end);

    // These pointers are "correct" and don't need the extra adjustments
    dwarf_info.sections[@intFromEnum(SecId.eh_frame)] =
        initSection(&_kernel_eh_frame_start, &_kernel_eh_frame_end);
    dwarf_info.sections[@intFromEnum(SecId.eh_frame_hdr)] =
        initSection(&_kernel_eh_frame_hdr_start, &_kernel_eh_frame_hdr_end);

    try Dwarf.open(&dwarf_info, allocator);
    return dwarf_info;
}

pub fn printSourceAtAddress(
    allocator: std.mem.Allocator,
    debug_info: *std.debug.Dwarf,
    out_stream: anytype,
    address: u64,
    tty_config: std.io.tty.Config,
) !void {
    const symbol_info = debug_info.getSymbol(allocator, address) catch |err| switch (err) {
        // TODO: Get module name from the build system?
        error.MissingDebugInfo, error.InvalidDebugInfo => return printUnknownSource(out_stream, null, address, tty_config),
        else => return err,
    };
    // TODO: Add deinit() to upstream to make it clear that `file_name` is allocated
    defer if (symbol_info.source_location) |sl| allocator.free(sl.file_name);

    return printLineInfo(
        out_stream,
        symbol_info.source_location,
        address,
        symbol_info.name,
        symbol_info.compile_unit_name,
        tty_config,
        // printLineFromFileAnyOs,
    );
}

fn printUnknownSource(
    out_stream: anytype,
    module_name: ?[]const u8,
    address: u64,
    tty_config: std.io.tty.Config,
) !void {
    return printLineInfo(
        out_stream,
        null,
        address,
        "???",
        module_name orelse "???",
        tty_config,
        // printLineFromFileAnyOs,
    );
}

fn printLineInfo(
    out_stream: anytype,
    source_location: ?std.debug.SourceLocation,
    address: usize,
    symbol_name: []const u8,
    compile_unit_name: []const u8,
    tty_config: std.io.tty.Config,
    // comptime printLineFromFile: anytype,
) !void {
    nosuspend {
        try tty_config.setColor(out_stream, .bold);

        if (source_location) |*sl| {
            try out_stream.print("{s}:{d}:{d}", .{ sl.file_name, sl.line, sl.column });
        } else {
            try out_stream.writeAll("???:?:?");
        }

        try tty_config.setColor(out_stream, .reset);
        try out_stream.writeAll(": ");
        try tty_config.setColor(out_stream, .dim);
        try out_stream.print("0x{x} in {s} ({s})", .{ address, symbol_name, compile_unit_name });
        try tty_config.setColor(out_stream, .reset);
        try out_stream.writeAll("\n");

        // Show the matching source code line if possible
        if (source_location) |sl| {
            if (printLineFromFile(out_stream, sl)) {
                if (sl.column > 0) {
                    // The caret already takes one char
                    const space_needed = @as(usize, @intCast(sl.column - 1));

                    try out_stream.writeByteNTimes(' ', space_needed);
                    try tty_config.setColor(out_stream, .green);
                    try out_stream.writeAll("^");
                    try tty_config.setColor(out_stream, .reset);
                }
                try out_stream.writeAll("\n");
            } else |err| switch (err) {
                error.EndOfFile, error.FileNotFound => {},
                error.BadPathName => {},
                error.AccessDenied => {},
                else => return err,
            }
        }
    }
}

fn printLineFromFile(out_stream: anytype, source_location: ?std.debug.SourceLocation) !void {
    _ = source_location;
    try out_stream.writeAll("TODO: print line from file\n");
}
