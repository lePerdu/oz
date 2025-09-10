const std = @import("std");
const int = @import("interrupt.zig");
const port_io = @import("port_io.zig");
const pic = @import("interrupt.zig").pic;

pub const IRQ: u8 = 1;

const DATA_PORT = 0x60;
const COMMAND_PORT = 0x64;

const PS2Status = packed struct(u8) {
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

const PS2Command = enum(u8) {
    read_config = 0x20,
    read_byte_n = 0x21,
    write_config = 0x60,
    write_byte_n = 0x61,

    disable_port_2 = 0xA7,
    enable_port_2 = 0xA8,
    test_port_2 = 0xA9,

    test_controller = 0xAA,

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
};

const PS2Config = packed struct(u8) {
    port_1_int_enable: bool,
    port_2_int_enable: bool,
    system_flag: bool,
    _reserved_0: u1,
    port_1_clock_disable: bool,
    port_2_clock_disable: bool,
    port_1_translation: bool,
    _reserved_1: u1,
};

const KeyboardCommand = enum(u8) {
    set_leds = 0xED,
    echo = 0xEE,
    scan_code_sets = 0xF0,
    identify = 0xF2,
    set_typematic = 0xF3,
    enable_scanning = 0xF4,
    disable_scanning = 0xF5,
    set_defaults = 0xF6,

    set_all_autorepeat = 0xF7,
    set_all_make_release = 0xF8,
    set_all_make_only = 0xF9,
    set_all_autorepeat_make_release = 0xFA,

    set_key_autorepeat = 0xFB,
    set_key_make_release = 0xFC,
    set_key_make_only = 0xFD,

    resend = 0xFE,
    reset = 0xFF,
};

const KeyboardResponse = enum(u8) {
    self_test_passed = 0xAA,
    echo = 0xEE,
    ack = 0xFA,
    self_test_failed_1 = 0xFC,
    self_test_failed_2 = 0xFD,
    resend = 0xFE,
    // Catchall for scancodes
    _,
};

// TODO: Extract this into a data file
// TODO: Handle multi-key codes
const scan_code_set_2 = struct {
    pub const RELEASED = 0xF0;

    pub const ScanCode = enum(u8) {
        tab = 0x0D,
        backtick = 0x0E,
        left_alt = 0x11,
        left_shift = 0x12,
        left_control = 0x14,
        q = 0x15,
        _1 = 0x16,
        z = 0x1A,
        s = 0x1B,
        a = 0x1C,
        w = 0x1D,
        _2 = 0x1E,
        c = 0x21,
        x = 0x22,
        d = 0x23,
        e = 0x24,
        _4 = 0x25,
        _3 = 0x26,
        space = 0x29,
        v = 0x2A,
        f = 0x2B,
        t = 0x2C,
        r = 0x2D,
        _5 = 0x2E,
        n = 0x31,
        b = 0x32,
        h = 0x33,
        g = 0x34,
        y = 0x35,
        _6 = 0x36,
        m = 0x3A,
        j = 0x3B,
        u = 0x3C,
        _7 = 0x3D,
        _8 = 0x3E,
        comma = 0x41,
        k = 0x42,
        i = 0x43,
        o = 0x44,
        _0 = 0x45,
        _9 = 0x46,
        dot = 0x49,
        slash = 0x4A,
        l = 0x4B,
        semicolon = 0x4C,
        p = 0x4D,
        hyphen = 0x4E,
        apostrophe = 0x52,
        left_square = 0x54,
        equals = 0x55,
        caps_lock = 0x58,
        right_shift = 0x59,
        enter = 0x5A,
        right_square = 0x5B,
        bash_slash = 0x5D,
        backspace = 0x66,
    };
};

const LedStates = packed struct(u8) {
    scroll_lock: bool,
    num_lock: bool,
    caps_lock: bool,
    _reserved: u5 = 0,
};

const out = port_io.outbComptimePort;
const in = port_io.inbComptimePort;

pub fn readData() u8 {
    return port_io.inbComptimePort(DATA_PORT);
}

fn writeData(data: u8) void {
    port_io.outbComptimePort(DATA_PORT, data);
}

fn writeKeyboardCommand(cmd: KeyboardCommand) void {
    waitWriteData(@intFromEnum(cmd));
}

fn readStatus() PS2Status {
    return @bitCast(port_io.inbComptimePort(COMMAND_PORT));
}

fn writeCommand(cmd: PS2Command) void {
    port_io.outbComptimePort(COMMAND_PORT, @intFromEnum(cmd));
}

fn waitReadData() u8 {
    while (!readStatus().output_buffer_full) {}
    return readData();
}

fn waitWriteData(data: u8) void {
    while (readStatus().input_buffer_full) {}
    writeData(data);
}

/// Configure the PS/2 controller
///
/// https://wiki.osdev.org/I8042_PS/2_Controller#Initialising_the_PS/2_Controller
pub fn configure() void {

    // Disable
    writeCommand(.disable_port_1);
    writeCommand(.disable_port_2);

    // Flush input buffer
    while (readStatus().input_buffer_full) {
        _ = readData();
    }

    // Update config:
    // - Port 1 clock enabled, but interrupts and translation disabled
    // - Port 2 fully disabled
    writeCommand(.read_config);
    var config: PS2Config = @bitCast(waitReadData());
    config.port_1_clock_disable = false;
    config.port_1_int_enable = false;
    config.port_1_translation = false;
    config.port_2_clock_disable = false;
    config.port_2_int_enable = false;
    writeCommand(.write_config);
    waitWriteData(@bitCast(config));

    writeCommand(.test_controller);
    const controller_test_res = waitReadData();
    std.log.info("PS/2 controller self test: 0x{x}", .{controller_test_res});

    // Reset config after self test in case it was reset
    writeCommand(.write_config);
    waitWriteData(@bitCast(config));

    // TODO: Determine if both ports are available

    writeCommand(.test_port_1);
    const port1_test = waitReadData();
    std.log.info("PS/2 controller port1 test: 0x{x}", .{port1_test});

    writeCommand(.enable_port_1);
    writeKeyboardCommand(.reset);
    {
        const kbd_ack = waitReadData();
        const reset_res = waitReadData();
        std.log.info("reset res: 0x{x} 0x{x}", .{ kbd_ack, reset_res });
    }

    // TODO: Detect device type before configuring
    writeKeyboardCommand(.scan_code_sets);
    waitWriteData(2);
    {
        const scan_code_set_res = waitReadData();
        std.log.info("scan code set res: 0x{x}", .{scan_code_set_res});
    }

    writeKeyboardCommand(.enable_scanning);
    {
        const enable_scan_res = waitReadData();
        std.log.info("enable scan res: 0x{x}", .{enable_scan_res});
    }

    config.port_1_int_enable = true;
    writeCommand(.write_config);
    waitWriteData(@bitCast(config));
}

pub fn handleInterrupt() void {
    const b = readData();
    if (b == scan_code_set_2.RELEASED) {
        std.log.info("keyboard: release", .{});
        // TODO: Can I read the next byte immediately?
    } else if (std.enums.fromInt(scan_code_set_2.ScanCode, b)) |key_code| {
        std.log.info("keyboard: {}", .{key_code});
    } else {
        std.log.info("keyboard: unknown: 0x{x:02}", .{b});
    }

    pic.sendMasterEoi();
}
