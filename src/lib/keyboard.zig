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

/// Key codes based on rows/columns of 104-key US layout
pub const KeyCode = enum(u8) {
    // multi-media keys are very un-standard, so just pick an order
    power = make(0, 1), // Start at 1 to leave 0 for ?KeyCode optimization
    sleep,
    wake,

    stop,
    previous_track,
    play_pause,
    next_track,
    mute,
    volume_down,
    volume_up,
    mic_mute,

    brightness_down,
    brightness_up,

    apps,
    email,
    calculator,
    my_computer,

    www_search,
    www_home,
    www_stop,
    www_back,
    www_forward,
    www_refresh,
    www_favorites,

    esc = make(1, 0),
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    print_screen,
    scroll_lock,
    pause_break,

    backtick = make(2, 0),
    num1,
    num2,
    num3,
    num4,
    num5,
    num6,
    num7,
    num8,
    num9,
    num0,
    dash,
    equals,
    backspace,
    insert,
    home,
    page_up,
    num_lock,
    kp_slash,
    kp_asterisk,
    kp_dash,

    tab = make(3, 0),
    q,
    w,
    e,
    r,
    t,
    y,
    u,
    i,
    o,
    p,
    l_square,
    r_square,
    backslash,
    delete,
    end,
    page_down,
    kp_7,
    kp_8,
    kp_9,
    kp_plus,

    caps_lock = make(4, 0),
    a,
    s,
    d,
    f,
    g,
    h,
    j,
    k,
    l,
    semicolon,
    apostrophe,
    enter,
    kp_4,
    kp_5,
    kp_6,

    l_shift = make(5, 0),
    z,
    x,
    c,
    v,
    b,
    n,
    m,
    comma,
    dot,
    slash,
    r_shift,
    up,
    kp_1,
    kp_2,
    kp_3,
    kp_enter,

    l_ctrl = make(6, 0),
    l_gui,
    l_alt,
    space,
    r_alt,
    r_gui,
    menu,
    r_ctrl,
    left,
    down,
    right,
    kp_0,
    kp_dot,

    fn make(row: u3, col: u5) u8 {
        return @as(u8, row) << 5 | @as(u8, col);
    }

    pub fn toAscii(self: @This()) ?u21 {
        return switch (self) {
            .a => 'a',
            .b => 'b',
            .c => 'c',
            .d => 'd',
            .e => 'e',
            .f => 'f',
            .g => 'g',
            .h => 'h',
            .i => 'i',
            .j => 'j',
            .k => 'k',
            .l => 'l',
            .m => 'm',
            .n => 'n',
            .o => 'o',
            .p => 'p',
            .q => 'q',
            .r => 'r',
            .s => 's',
            .t => 't',
            .u => 'u',
            .v => 'v',
            .w => 'w',
            .x => 'x',
            .y => 'y',
            .z => 'z',
            .num1 => '1',
            .num2 => '2',
            .num3 => '3',
            .num4 => '4',
            .num5 => '5',
            .num6 => '6',
            .num7 => '7',
            .num8 => '8',
            .num9 => '9',
            .num0 => '0',
            else => null,
        };
    }
};

pub const Event = struct {
    code: KeyCode,
    pressed: bool,
};

// TODO: Extract this into a data file
// TODO: Handle multi-key codes
const scan_code_set_2 = struct {
    const EXTENDED = 0xE0;
    const EXTENDED_LONG = 0xE1;
    const RELEASE = 0xF0;

    const SimpleCode = enum(u8) {
        a = 0x1C,
        b = 0x32,
        c = 0x21,
        d = 0x23,
        e = 0x24,
        f = 0x2B,
        g = 0x34,
        h = 0x33,
        i = 0x43,
        j = 0x3B,
        k = 0x42,
        l = 0x4B,
        m = 0x3A,
        n = 0x31,
        o = 0x44,
        p = 0x4D,
        q = 0x15,
        r = 0x2D,
        s = 0x1B,
        t = 0x2C,
        u = 0x3C,
        v = 0x2A,
        w = 0x1D,
        x = 0x22,
        y = 0x35,
        z = 0x1A,
        num0 = 0x45,
        num1 = 0x16,
        num2 = 0x1E,
        num3 = 0x26,
        num4 = 0x25,
        num5 = 0x2E,
        num6 = 0x36,
        dot = 0x49,
        num7 = 0x3D,
        num8 = 0x3E,
        slash = 0x4A,
        scroll_lock = 0x7E,
        num9 = 0x46,
        l_square = 0x54,
        backtick = 0x0E,
        dash = 0x4E,
        equals = 0x55,
        backslash = 0x5D,
        backspace = 0x66,
        space = 0x29,
        tab = 0x0D,
        caps_lock = 0x58,
        l_shift = 0x12,
        l_ctrl = 0x14,
        num_lock = 0x77,
        l_alt = 0x11,
        r_shift = 0x59,
        kp_asterisk = 0x7C,
        kp_dash = 0x7B,
        kp_plus = 0x79,
        kp_dot = 0x71,
        enter = 0x5A,
        kp_0 = 0x70,
        esc = 0x76,
        kp_1 = 0x69,
        f1 = 0x05,
        kp_2 = 0x72,
        f2 = 0x06,
        kp_3 = 0x7A,
        f3 = 0x04,
        kp_4 = 0x6B,
        f4 = 0x0C,
        kp_5 = 0x73,
        f5 = 0x03,
        kp_6 = 0x74,
        f6 = 0x0B,
        kp_7 = 0x6C,
        f7 = 0x83,
        kp_8 = 0x75,
        f8 = 0x0A,
        kp_9 = 0x7D,
        f9 = 0x01,
        r_square = 0x5B,
        f10 = 0x09,
        semicolon = 0x4C,
        f11 = 0x78,
        apostrophe = 0x52,
        f12 = 0x07,
        comma = 0x41,

        const Self = @This();

        // Generate a mapping table based on enum field names matching those in KeyCode
        // TODO: Extract this to share with ExtendedCode
        const to_key_code = init: {
            // Setting to undefined is safe since the indices will only ever be enum values
            var array: [std.enums.directEnumArrayLen(@This(), 256)]KeyCode = undefined;
            const info = @typeInfo(Self).@"enum";
            for (info.fields) |field| {
                array[field.value] = @field(KeyCode, field.name);
            }
            break :init array;
        };

        pub fn toKeyCode(self: Self) KeyCode {
            return to_key_code[@intFromEnum(self)];
        }
    };

    const ExtendedCode = enum(u8) {
        insert = 0x70,
        home = 0x6C,
        page_up = 0x7D,
        delete = 0x71,
        end = 0x69,
        page_down = 0x7A,
        up = 0x75,
        left = 0x6B,
        down = 0x72,
        right = 0x74,
        l_gui = 0x1F,
        kp_slash = 0x4A,
        r_ctrl = 0x14,
        r_gui = 0x27,
        r_alt = 0x11,
        kp_enter = 0x5A,
        apps = 0x2F,
        power = 0x37,
        sleep = 0x3F,
        wake = 0x5E,
        next_track = 0x4D,
        previous_track = 0x15,
        stop = 0x3B,
        play_pause = 0x34,
        mute = 0x23,
        volume_up = 0x32,
        volume_down = 0x21,
        mic_mute = 0x50, // ?
        email = 0x48,
        calculator = 0x2B,
        my_computer = 0x40,
        www_search = 0x10,
        www_home = 0x3A,
        www_back = 0x38,
        www_forward = 0x30,
        www_stop = 0x28,
        www_refresh = 0x20,
        www_favorites = 0x18,

        const Self = @This();

        // Generate a mapping table based on enum field names matching those in KeyCode
        const to_key_code = init: {
            var array: [std.enums.directEnumArrayLen(@This(), 256)]KeyCode = undefined;
            const info = @typeInfo(Self).@"enum";
            for (info.fields) |field| {
                array[field.value] = @field(KeyCode, field.name);
            }
            break :init array;
        };

        pub fn toKeyCode(self: Self) KeyCode {
            return to_key_code[@intFromEnum(self)];
        }
    };

    // These are special cases for some reason

    // make/release codes after the initial E0 / E0,F0
    const print_screen_make = [_]u8{ 0x12, 0xE0, 0x7C };
    const print_screen_release = [_]u8{ 0x7C, 0xE0, 0xF0, 0x12 };
    // after initial E1
    const pause_break_make = [_]u8{ 0x14, 0x77 };
    // Release has to come immediately after "make"
    const pause_break_release = [_]u8{ 0xE1, 0xF0, 0x14, 0xF0, 0x77 };

    pub const StateMachine = struct {
        const State = enum {
            init,
            release,
            extended,
            release_extended,

            print_screen_make,
            print_screen_release,
            pause_break_make,
            pause_break_release,
        };

        state: State = .init,
        special_index: u8 = 0,

        const Self = @This();

        pub fn input(self: *Self, byte: u8) ?Event {
            switch (self.state) {
                .init => {
                    switch (byte) {
                        RELEASE => {
                            self.state = .release;
                            return null;
                        },
                        EXTENDED => {
                            self.state = .extended;
                            return null;
                        },
                        EXTENDED_LONG => {
                            self.state = .pause_break_make;
                            self.special_index = 0;
                            return null;
                        },
                        else => {
                            if (std.enums.fromInt(SimpleCode, byte)) |simple| {
                                return Event{ .code = simple.toKeyCode(), .pressed = true };
                            } else {
                                std.log.warn("unknown scan code: 0x{x:02}", .{byte});
                                return null;
                            }
                        },
                    }
                },
                .extended => {
                    if (byte == RELEASE) {
                        self.state = .release_extended;
                        return null;
                    } else if (std.enums.fromInt(ExtendedCode, byte)) |extended| {
                        self.state = .init;
                        return Event{ .code = extended.toKeyCode(), .pressed = true };
                    } else if (byte == print_screen_make[0]) {
                        self.state = .print_screen_make;
                        self.special_index = 1;
                        return null;
                    } else {
                        self.state = .init;
                        std.log.warn("unknown extended scan code: 0x{x:02}", .{byte});
                        return null;
                    }
                },
                .release => {
                    if (std.enums.fromInt(SimpleCode, byte)) |simple| {
                        self.state = .init;
                        return Event{ .code = simple.toKeyCode(), .pressed = false };
                    } else {
                        self.state = .init;
                        std.log.warn("unknown release scan code: 0x{x:02}", .{byte});
                        return null;
                    }
                },
                .release_extended => {
                    if (std.enums.fromInt(ExtendedCode, byte)) |extended| {
                        self.state = .init;
                        return Event{ .code = extended.toKeyCode(), .pressed = false };
                    } else if (byte == print_screen_release[0]) {
                        self.state = .print_screen_release;
                        // Already checked the first byte
                        self.special_index = 1;
                        return null;
                    } else {
                        self.state = .init;
                        std.log.warn("unknown extended release scan code: 0x{x:02}", .{byte});
                        return null;
                    }
                },

                .print_screen_make => {
                    if (byte == print_screen_make[self.special_index]) {
                        self.special_index += 1;
                        if (self.special_index == print_screen_make.len) {
                            self.state = .init;
                            return Event{ .code = .print_screen, .pressed = true };
                        } else {
                            return null;
                        }
                    } else {
                        self.state = .init;
                        std.log.warn("unexpected scan code in print screen make sequence: 0x{x:02}", .{byte});
                        return null;
                    }
                },
                .print_screen_release => {
                    if (byte == print_screen_release[self.special_index]) {
                        self.special_index += 1;
                        if (self.special_index == print_screen_release.len) {
                            self.state = .init;
                            return Event{ .code = .print_screen, .pressed = false };
                        } else {
                            return null;
                        }
                    } else {
                        self.state = .init;
                        std.log.warn("unexpected scan code in print screen release sequence: 0x{x:02}", .{byte});
                        return null;
                    }
                },
                .pause_break_make => {
                    if (byte == pause_break_make[self.special_index]) {
                        self.special_index += 1;
                        if (self.special_index == pause_break_make.len) {
                            // release always has to come afterwards for this key
                            self.state = .pause_break_release;
                            self.special_index = 0;
                            return Event{ .code = .pause_break, .pressed = true };
                        } else {
                            return null;
                        }
                    } else {
                        self.state = .init;
                        std.log.warn("unexpected scan code in print screen make sequence: 0x{x:02}", .{byte});
                        return null;
                    }
                },
                .pause_break_release => {
                    if (byte == pause_break_release[self.special_index]) {
                        self.special_index += 1;
                        if (self.special_index == pause_break_release.len) {
                            self.state = .init;
                            return Event{ .code = .pause_break, .pressed = false };
                        } else {
                            return null;
                        }
                    } else {
                        self.state = .init;
                        std.log.warn("unexpected scan code in print screen release sequence: 0x{x:02}", .{byte});
                        return null;
                    }
                },
            }
        }
    };

    const testing = std.testing;

    test "StateMachine: simple press/release" {
        var sm = StateMachine{};
        try testing.expectEqual(Event{ .code = .k, .pressed = true }, sm.input(0x42));
        try testing.expectEqual(.init, sm.state);
        try testing.expectEqual(null, sm.input(0xF0));
        try testing.expectEqual(Event{ .code = .k, .pressed = false }, sm.input(0x42));
        try testing.expectEqual(.init, sm.state);
    }

    test "StateMachine: simple press/repeat" {
        var sm = StateMachine{};
        try testing.expectEqual(Event{ .code = .k, .pressed = true }, sm.input(0x42));
        try testing.expectEqual(Event{ .code = .k, .pressed = true }, sm.input(0x42));
        try testing.expectEqual(Event{ .code = .k, .pressed = true }, sm.input(0x42));
        try testing.expectEqual(Event{ .code = .k, .pressed = true }, sm.input(0x42));
        try testing.expectEqual(.init, sm.state);
    }

    test "StateMachine: extended press/release" {
        var sm = StateMachine{};
        try testing.expectEqual(null, sm.input(0xE0));
        try testing.expectEqual(Event{ .code = .left, .pressed = true }, sm.input(0x6B));
        try testing.expectEqual(.init, sm.state);
        try testing.expectEqual(null, sm.input(0xE0));
        try testing.expectEqual(null, sm.input(0xF0));
        try testing.expectEqual(Event{ .code = .left, .pressed = false }, sm.input(0x6B));
        try testing.expectEqual(.init, sm.state);
    }

    test "StateMachine: print screen press/release" {
        var sm = StateMachine{};
        try testing.expectEqual(null, sm.input(0xE0));
        try testing.expectEqual(null, sm.input(0x12));
        try testing.expectEqual(null, sm.input(0xE0));
        try testing.expectEqual(Event{ .code = .print_screen, .pressed = true }, sm.input(0x7C));
        try testing.expectEqual(.init, sm.state);
        try testing.expectEqual(null, sm.input(0xE0));
        try testing.expectEqual(null, sm.input(0xF0));
        try testing.expectEqual(null, sm.input(0x7C));
        try testing.expectEqual(null, sm.input(0xE0));
        try testing.expectEqual(null, sm.input(0xF0));
        try testing.expectEqual(Event{ .code = .print_screen, .pressed = false }, sm.input(0x12));
        try testing.expectEqual(.init, sm.state);
    }

    test "StateMachine: pause break press/release" {
        var sm = StateMachine{};
        try testing.expectEqual(null, sm.input(0xE1));
        try testing.expectEqual(null, sm.input(0x14));
        try testing.expectEqual(Event{ .code = .pause_break, .pressed = true }, sm.input(0x77));
        // Can't send another key here
        try testing.expect(sm.state != .init);
        try testing.expectEqual(null, sm.input(0xE1));
        try testing.expectEqual(null, sm.input(0xF0));
        try testing.expectEqual(null, sm.input(0x14));
        try testing.expectEqual(null, sm.input(0xF0));
        try testing.expectEqual(Event{ .code = .pause_break, .pressed = false }, sm.input(0x77));
        try testing.expectEqual(.init, sm.state);
    }

    test "StateMachine: unknown simple code ignored" {
        var sm = StateMachine{};
        try testing.expectEqual(null, sm.input(0x51));
        try testing.expectEqual(.init, sm.state);
    }

    test "StateMachine: unknown extended code ignored" {
        var sm = StateMachine{};
        try testing.expectEqual(null, sm.input(0xE0));
        try testing.expectEqual(null, sm.input(0x51));
        try testing.expectEqual(.init, sm.state);
    }

    test "StateMachine: unknown long (pause/break) extended code ignored" {
        var sm = StateMachine{};
        try testing.expectEqual(null, sm.input(0xE1));
        try testing.expectEqual(null, sm.input(0x14));
        try testing.expectEqual(null, sm.input(0x42));
        try testing.expectEqual(.init, sm.state);
        try testing.expectEqual(null, sm.input(0xE1));
        try testing.expectEqual(null, sm.input(0xF0));
        try testing.expectEqual(null, sm.input(0x15));
        try testing.expectEqual(null, sm.input(0xF0));
        try testing.expectEqual(null, sm.input(0x57));
        try testing.expectEqual(.init, sm.state);
    }

    test "StateMachine: unknown double (print screen) extended code ignored" {
        var sm = StateMachine{};
        // Start like print screen
        try testing.expectEqual(null, sm.input(0xE0));
        try testing.expectEqual(null, sm.input(print_screen_make[0]));
        try testing.expectEqual(null, sm.input(0xE0));
        // Expected 7C
        try testing.expectEqual(null, sm.input(0x51));
        try testing.expectEqual(.init, sm.state);

        try testing.expectEqual(null, sm.input(0xE0));
        try testing.expectEqual(null, sm.input(0xF0));
        try testing.expectEqual(null, sm.input(print_screen_release[0]));
        try testing.expectEqual(null, sm.input(0xE0));
        try testing.expectEqual(null, sm.input(0xF0));
        try testing.expectEqual(null, sm.input(@intFromEnum(ExtendedCode.delete)));
        try testing.expectEqual(.init, sm.state);
    }
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

pub const Controller = struct {
    scan_code_sm: scan_code_set_2.StateMachine = .{},
    // TODO: Buffer events so that they don't have to be processed in the interrupt handler
    // TODO: Also track when keys are held down? PS/2 keyboard does auto-repeat, so it's not necessary for event-based handling

    const Self = @This();

    pub fn handleInterrupt(self: *Self) ?Event {
        defer pic.sendMasterEoi();
        return self.scan_code_sm.input(readData());
    }
};

test {
    std.testing.refAllDeclsRecursive(@This());
}
