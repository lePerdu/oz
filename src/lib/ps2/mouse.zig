const std = @import("std");
const ps2 = @import("./controller.zig");

pub const IRQ = ps2.PORT2_IRQ;

const Command = enum(u8) {
    set_scaling_1_1 = 0xE6,
    set_scaling_2_1 = 0xE7,
    set_resolution = 0xE8,
    status_request = 0xE9,
    set_stream_mode = 0xEA,
    read_data = 0xEB,
    reset_wrap_mode = 0xEC,
    set_wrap_mode = 0xEE,
    set_remote_mode = 0xF0,
    set_sample_rate = 0xF3,
    set_defaults = 0xF6,
};

/// Also used to enable extensions, like Z-axis and buttons 4/5
fn setSampleRate(rate: u8) !void {
    return ps2.port2WriteDeviceCommandWithAck(Command.set_sample_rate, .{rate});
}

const Mode = enum(u8) {
    default = 0,
    z_axis = 3,
    z_axis_and_buttons = 4,
};

pub const Event = packed struct {
    delta_x: i16,
    delta_y: i16,
    delta_z: i16,
    button_l_pressed: bool,
    button_m_pressed: bool,
    button_r_pressed: bool,
    button_4_pressed: bool,
    button_5_pressed: bool,
};

const Packet = extern struct {
    flags: Flags,
    x_move8: u8,
    y_move8: u8,
    zflags: ZFlags,

    const Self = @This();

    pub fn fromBytes(bytes: [4]u8) Self {
        // Just a transmute
        return .{
            .flags = @bitCast(bytes[0]),
            .x_move8 = bytes[1],
            .y_move8 = bytes[2],
            .zflags = @bitCast(bytes[3]),
        };
    }

    pub fn deltaX(self: Self) i16 {
        // TODO: Handle overflow?
        return @as(i16, self.x_move8) - @as(i16, if (self.flags.x_sign == 1) 0x100 else 0);
    }

    pub fn deltaY(self: Self) i16 {
        // TODO: Handle overflow?
        return @as(i16, self.y_move8) - @as(i16, if (self.flags.y_sign == 1) 0x100 else 0);
    }

    pub fn deltaZ(self: Self) i16 {
        return self.zflags.delta_z;
    }

    const Flags = packed struct(u8) {
        button_left: bool,
        button_right: bool,
        button_middle: bool,
        _always_one: u1 = 1,
        x_sign: u1,
        y_sign: u1,
        x_overflow: bool,
        y_overflow: bool,
    };

    const ZFlags = packed struct(u8) {
        delta_z: u4,
        button_4: bool,
        button_5: bool,
        _reserved: u2 = 0,
    };
};

fn event_from_bytes(buffer: [4]u8) Event {
    const packet = Packet.fromBytes(buffer);
    return .{
        .delta_x = packet.deltaX(),
        .delta_y = packet.deltaY(),
        .delta_z = packet.deltaZ(),
        .button_l_pressed = packet.flags.button_left,
        .button_m_pressed = packet.flags.button_middle,
        .button_r_pressed = packet.flags.button_right,
        .button_4_pressed = packet.zflags.button_4,
        .button_5_pressed = packet.zflags.button_5,
    };
}

pub fn enable() !void {
    std.log.debug("enabling PS/2 mouse", .{});
    // TODO: It is possible for the keyboard to send a byte during this "enable scanning"
    // that would conflict with the ACK?
    // Is there a way around it? Maybe disabling port1 while sending this?
    try ps2.port2WriteDeviceCommandWithAck(ps2.GenericDeviceCommand.enable_scanning, .{});
}

pub const Controller = struct {
    buffer: [4]u8 = .{ 0, 0, 0, 0 },
    packet_index: u32 = 0,
    packet_len: u32 = 3,
    // TODO: Buffer events so that they don't have to be processed in the interrupt handler
    // TODO: Also track when keys are held down? PS/2 keyboard does auto-repeat, so it's not necessary for event-based handling

    const Self = @This();

    pub fn configure() !Self {
        std.log.debug("configuring PS/2 mouse", .{});
        var mouse_mode = Mode.default;
        // TODO: Figure out why this isn't working
        // Try upgrade to z-axis
        {
            try setSampleRate(200);
            try setSampleRate(100);
            try setSampleRate(80);
            try ps2.port2WriteDeviceCommandWithAck(ps2.GenericDeviceCommand.identify, .{});
            // TODO: Figure out why 3 extra ACKs are sent here
            _ = ps2.port2WaitRead() catch {};
            _ = ps2.port2WaitRead() catch {};
            _ = ps2.port2WaitRead() catch {};
            const ident1 = ps2.port2WaitRead() catch null;
            const ident2 = ps2.port2WaitRead() catch null;
            if (ident1 == @intFromEnum(Mode.z_axis) and ident2 == null) {
                std.log.debug("PS/2 mouse in z-axis mode", .{});
                mouse_mode = .z_axis;
            }
        }

        // // Try upgrade to buttons 4&5
        if (mouse_mode == .z_axis) {
            try setSampleRate(200);
            try setSampleRate(200);
            try setSampleRate(80);
            try ps2.port2WriteDeviceCommandWithAck(ps2.GenericDeviceCommand.identify, .{});
            _ = ps2.port2WaitRead() catch {};
            _ = ps2.port2WaitRead() catch {};
            _ = ps2.port2WaitRead() catch {};
            const ident1 = ps2.port2WaitRead() catch null;
            const ident2 = ps2.port2WaitRead() catch null;
            if (ident1 == @intFromEnum(Mode.z_axis_and_buttons) and ident2 == null) {
                std.log.debug("PS/2 mouse in z-axis + 5-button mode", .{});
                mouse_mode = .z_axis_and_buttons;
            }
        }

        return .{
            .packet_len = if (mouse_mode == .default) 3 else 4,
        };
    }

    pub fn handleInterrupt(self: *Self) ?Event {
        self.buffer[self.packet_index] = ps2.port2Read();
        self.packet_index += 1;
        if (self.packet_index == self.packet_len) {
            self.packet_index = 0;
            return event_from_bytes(self.buffer);
        } else {
            return null;
        }
    }
};
