const std = @import("std");
const port_io = @import("../port_io.zig");

const DATA_PORT = 0x60;
const COMMAND_PORT = 0x64;

pub const PORT1_IRQ = 1;
pub const PORT2_IRQ = 12;

pub const Status = packed struct(u8) {
    output_buffer_full: bool,
    input_buffer_full: bool,
    system_flag: bool,
    // Whether data in input buffer is for the device or controller
    controller_command: bool,
    _unknown0: u1,
    _unknown1: u1,
    timeout_error: bool,
    parity_error: bool,
};

pub const Command = enum(u8) {
    read_config = 0x20,
    read_byte_n = 0x21,
    write_config = 0x60,
    write_byte_n = 0x61,

    disable_port_2 = 0xA7,
    enable_port_2 = 0xA8,
    test_port_2 = 0xA9,

    self_test = 0xAA,

    test_port_1 = 0xAB,
    diagnostic_dump = 0xAC,
    disable_port_1 = 0xAD,
    enable_port_1 = 0xAE,

    read_input = 0xC0,
    copy_bits_03_to_status_47 = 0xC1,
    copy_bits_47_to_status_47 = 0xC2,
    read_output = 0xD0,
    write_output = 0xD1,
    write_port_1_output = 0xD2,
    write_port_2_output = 0xD3,
    write_port_2_input = 0xD4,

    pub const SelfTestResponse = enum(u8) {
        passed = 0x55,
        failed = 0xFC,
        _,
    };

    pub const TestPortResponse = enum(u8) {
        passed = 0x00,
        clock_line_stuck_low = 0x01,
        clock_line_stuck_high = 0x02,
        data_line_stuck_low = 0x03,
        data_line_stuck_high = 0x04,
        _,
    };
};

pub const Config = packed struct(u8) {
    port_1_int_enable: bool,
    port_2_int_enable: bool,
    system_flag: bool,
    _reserved_0: u1,
    port_1_clock_disable: bool,
    port_2_clock_disable: bool,
    port_1_translation: bool,
    _reserved_1: u1,
};

pub fn readStatus() Status {
    return @bitCast(port_io.inbComptimePort(COMMAND_PORT));
}

pub fn writeCommand(cmd: Command) void {
    port_io.outbComptimePort(COMMAND_PORT, @intFromEnum(cmd));
}

pub fn readData() u8 {
    return port_io.inbComptimePort(DATA_PORT);
}

pub fn writeData(data: u8) void {
    port_io.outbComptimePort(DATA_PORT, data);
}

// TODO: Use better timer
fn readCycleCounter() u64 {
    var high: u32 = 0;
    var low: u32 = 0;
    asm ("rdtsc"
        : [high] "={edx}" (high),
          [low] "={eax}" (low),
    );
    return @as(u64, high) << 32 | @as(u64, low);
}

// TODO: What is reasonable?
const TIMEOUT_MS = 10;
const CYCLES_PER_SEC = 1_000_000_000;
const TIMEOUT_CYCLES = CYCLES_PER_SEC * TIMEOUT_MS / 1000;

pub fn flushReadBuffer() void {
    while (readStatus().input_buffer_full) {
        _ = readData();
        // TODO: Include delay between iterations?
    }
}

pub fn waitReadData() error{ReadTimeout}!u8 {
    const endTime = readCycleCounter() +% TIMEOUT_CYCLES;
    while (readCycleCounter() < endTime) {
        // TODO: Better busy wait?
        if (readStatus().output_buffer_full) {
            return readData();
        } else {
            asm volatile ("pause");
        }
    }
    return error.ReadTimeout;
}

pub fn waitWriteData(data: u8) error{WriteTimeout}!void {
    const endTime = readCycleCounter() +% TIMEOUT_CYCLES;
    while (readCycleCounter() < endTime) {
        if (!readStatus().input_buffer_full) {
            writeData(data);
            return;
        } else {
            asm volatile ("pause");
        }
    }
    return error.WriteTimeout;
}

pub const DeviceType = enum {
    keyboard,
    mouse,
};

pub const GenericDeviceCommand = enum(u8) {
    identify = 0xF2,
    enable_scanning = 0xF4,
    disable_scanning = 0xF5,
    set_defaults = 0xF6,
    resend = 0xFE,
    reset = 0xFF,
};

pub const GenericDeviceResponse = enum(u8) {
    self_test_passed = 0xAA,
    echo = 0xEE,
    ack = 0xFA,
    self_test_failed_1 = 0xFC,
    self_test_failed_2 = 0xFD,
    resend = 0xFE,
    _,
};

pub const port1Read = readData;
pub const port1WaitRead = waitReadData;
pub const port1Write = writeData;
pub const port1WaitWrite = waitWriteData;

/// Write a keyboard command and wait for ACK.
/// Resends a few times before failing.
/// TODO: Type checking/switching for cmd and args
pub fn port1WriteDeviceCommand(cmd: anytype, args: anytype) !GenericDeviceResponse {
    while (true) {
        try port1WaitWrite(@intFromEnum(cmd));
        inline for (args) |arg| {
            try port1WaitWrite(arg);
        }

        const res: GenericDeviceResponse = @enumFromInt(try port1WaitRead());
        if (res == .resend) {
            continue;
        } else {
            return res;
        }
    }
}

pub fn port1WriteDeviceCommandWithAck(cmd: anytype, args: anytype) !void {
    const res = try port1WriteDeviceCommand(cmd, args);
    if (res != .ack) return error.ExpectedAck;
}

pub const port2Read = readData;
pub const port2WaitRead = waitReadData;

pub fn port2Write(data: u8) void {
    writeCommand(.write_port_2_input);
    writeData(data);
}

pub fn port2WaitWrite(data: u8) !void {
    writeCommand(.write_port_2_input);
    return waitWriteData(data);
}

pub fn port2WriteDeviceCommand(cmd: anytype, args: anytype) !GenericDeviceResponse {
    while (true) {
        try port2WaitWrite(@intFromEnum(cmd));
        inline for (args) |arg| {
            try port2WaitWrite(arg);
        }

        const res: GenericDeviceResponse = @enumFromInt(try port2WaitRead());
        if (res == .resend) {
            continue;
        } else {
            return res;
        }
    }
}

pub fn port2WriteDeviceCommandWithAck(cmd: anytype, args: anytype) !void {
    const res = try port2WriteDeviceCommand(cmd, args);
    if (res != .ack) return error.ExpectedAck;
}

/// Configure the PS/2 controller
///
/// https://wiki.osdev.org/I8042_PS/2_Controller#Initialising_the_PS/2_Controller
pub fn configure() !struct { port1: ?DeviceType, port2: ?DeviceType } {
    // TODO:
    // Step 1: Initialise USB Controllers
    // Step 2: Determine if the PS/2 Controller Exists (ACPI)

    // Disable
    writeCommand(.disable_port_1);
    writeCommand(.disable_port_2);

    flushReadBuffer();

    // Update config:
    // - Port 1 clock enabled, but interrupts and translation disabled
    // - Port 2 fully disabled
    writeCommand(.read_config);
    var config: Config = @bitCast(try waitReadData());
    config.port_1_clock_disable = false;
    config.port_1_int_enable = false;
    config.port_1_translation = false;
    config.port_2_clock_disable = true;
    config.port_2_int_enable = false;
    writeCommand(.write_config);
    try waitWriteData(@bitCast(config));

    writeCommand(.self_test);
    const controller_test_res = try waitReadData();
    switch (@as(Command.SelfTestResponse, @enumFromInt(controller_test_res))) {
        .passed => {
            std.log.debug("PS/2 controller self test: passed", .{});
        },
        .failed => {
            std.log.debug("PS/2 controller self test: failed", .{});
            return error.SelfTestFailed;
        },
        else => {
            std.log.err("PS/2 controller self test: invalid: {}", .{controller_test_res});
            return error.SelfTestFailed;
        },
    }

    // Reset config after self test in case it was reset
    writeCommand(.write_config);
    try waitWriteData(@bitCast(config));

    // Check if second port is available
    writeCommand(.enable_port_2);
    writeCommand(.read_config);
    config = @bitCast(try waitReadData());
    const port2_available = !config.port_2_clock_disable;
    // Disable again until ready to configure port 2
    writeCommand(.disable_port_2);

    const port1_type = checkPort1() catch null;
    const port2_type = if (port2_available) (checkPort2() catch null) else null;
    return .{ .port1 = port1_type, .port2 = port2_type };
}

pub fn enableInterrupts(port1: bool, port2: bool) !void {
    writeCommand(.read_config);
    var config: Config = @bitCast(try waitReadData());
    config.port_1_int_enable = port1;
    config.port_2_int_enable = port2;
    writeCommand(.write_config);
    try waitWriteData(@bitCast(config));
}

fn checkPort1() !DeviceType {
    const log = std.log.scoped(.check_port1);
    writeCommand(.test_port_1);
    const test_res = try waitReadData();
    switch (@as(Command.TestPortResponse, @enumFromInt(test_res))) {
        .passed => {
            log.debug("port test: passed", .{});
        },
        .clock_line_stuck_low, .clock_line_stuck_high, .data_line_stuck_low, .data_line_stuck_high => |res| {
            log.debug("port test: failed: {}", .{res});
            return error.SelfTestFailed;
        },
        else => {
            log.err("port test: invalid: {}", .{test_res});
            return error.SelfTestFailed;
        },
    }

    writeCommand(.enable_port_1);

    try port1WriteDeviceCommandWithAck(GenericDeviceCommand.reset, .{});
    const reset_res = try port1WaitRead();
    if (reset_res != @intFromEnum(GenericDeviceResponse.self_test_passed)) {
        log.err("device reset failed: {}", .{reset_res});
        return error.SelfTestFailed;
    }
    const reset_identify = port1WaitRead() catch null;
    // Disable so that key data doesn't come in while identifying
    try port1WriteDeviceCommandWithAck(GenericDeviceCommand.disable_scanning, .{});
    try port1WriteDeviceCommandWithAck(GenericDeviceCommand.identify, .{});
    // Both bytes are optional
    const ident1 = port1WaitRead() catch null;
    const ident2 = port1WaitRead() catch null;
    // TODO: Make sure it's actually a keyboard
    log.info("identify: {?} {?}", .{ ident1, ident2 });

    // TODO: Better identify checking
    if (reset_identify == 0) {
        return .mouse;
    } else {
        return .keyboard;
    }
}

fn checkPort2() !DeviceType {
    const log = std.log.scoped(.check_port2);
    writeCommand(.test_port_2);
    const test_res = try waitReadData();
    switch (@as(Command.TestPortResponse, @enumFromInt(test_res))) {
        .passed => {
            log.debug("port test: passed", .{});
        },
        .clock_line_stuck_low, .clock_line_stuck_high, .data_line_stuck_low, .data_line_stuck_high => |res| {
            log.debug("port test: failed: {}", .{res});
            return error.SelfTestFailed;
        },
        else => {
            log.err("port test: invalid: {}", .{test_res});
            return error.SelfTestFailed;
        },
    }

    writeCommand(.enable_port_2);

    try port2WriteDeviceCommandWithAck(GenericDeviceCommand.reset, .{});
    const reset_res = try port2WaitRead();
    if (reset_res != @intFromEnum(GenericDeviceResponse.self_test_passed)) {
        log.err("device reset failed: {}", .{reset_res});
        return error.SelfTestFailed;
    }
    // Some devices (just mice?) send their identify code after reset
    const reset_identify = port2WaitRead() catch null;
    // Disable so that key data doesn't come in while identifying
    try port2WriteDeviceCommandWithAck(GenericDeviceCommand.disable_scanning, .{});
    try port2WriteDeviceCommandWithAck(GenericDeviceCommand.identify, .{});
    // Both bytes are optional
    const ident1 = port2WaitRead() catch null;
    const ident2 = port2WaitRead() catch null;
    log.info("identify: {?} {?}", .{ ident1, ident2 });

    // TODO: Better identify checking
    if (reset_identify == 0) {
        return .mouse;
    } else {
        return .keyboard;
    }
}
