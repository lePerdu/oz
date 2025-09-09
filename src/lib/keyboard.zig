const int = @import("interrupt.zig");
const port_io = @import("port_io.zig");

pub const IRQ: u8 = 1;

pub const DATA_PORT = 0x60;
pub const COMMAND_PORT = 0x64;

pub const Command = enum(u8) {
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

const Response = enum(u8) {
    self_test_passed = 0xAA,
    echo = 0xEE,
    ack = 0xFA,
    self_test_failed_1 = 0xFC,
    self_test_failed_2 = 0xFD,
    resend = 0xFE,
    // Catchall for scancodes
    _,
};

const LedStates = packed struct(u8) {
    scroll_lock: bool,
    num_lock: bool,
    caps_lock: bool,
    _reserved: u5 = 0,
};

pub fn sendData(cmd: Command) void {
    port_io.outbComptimePort(DATA_PORT, @intFromEnum(cmd));
}

pub fn readData() u8 {
    return port_io.inbComptimePort(DATA_PORT);
}
