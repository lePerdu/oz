const std = @import("std");
const uefi = std.os.uefi;

const port_io = @import("./port_io.zig");

pub const ConsoleWriter = struct {
    const Self = @This();
    const BUFFER_SIZE = 512;

    pub const Error = error{ InvalidUtf8, DeviceError, Unsupported, UnexpectedError };
    pub const Writer = std.io.GenericWriter(Self, Error, write);

    output_proto: *uefi.protocol.SimpleTextOutput,

    pub fn init(output_proto: *uefi.protocol.SimpleTextOutput) Self {
        return .{ .output_proto = output_proto };
    }

    pub fn write(self: Self, full_data: []const u8) Error!usize {
        // TODO: What to do for invalid UTF8?
        var buf: [BUFFER_SIZE + 1]u16 = undefined;

        var data = full_data;
        // If the whole input can't be written, just write what fits in the buffer.
        // This is fine since `write` isn't required to write all data anyway
        if (try std.unicode.checkUtf8ToUtf16LeOverflow(full_data, buf[0..BUFFER_SIZE])) {
            data = data[0..getEncodableLen(data, BUFFER_SIZE)];
        }

        // std.debug.assert(!try std.unicode.checkUtf8ToUtf16LeOverflow(data, buf[0..BUFFER_SIZE]));
        const utf16_len = try std.unicode.utf8ToUtf16Le(buf[0..BUFFER_SIZE], data);
        buf[utf16_len] = 0;
        const status = self.output_proto.outputString(@ptrCast(&buf));
        switch (status) {
            .success, .warn_unknown_glyph => return data.len,
            .device_error => return error.DeviceError,
            .unsupported => return error.Unsupported,
            else => return error.UnexpectedError,
        }
    }

    fn getEncodableLen(data: []const u8, utf16_buf_len: usize) usize {
        // Picking the buffer size is always a safe, conservative bet,
        // although it could do better by a factor of 2 if the input is
        // all ASCII
        // TODO: Find an algorithm that efficiently finds the largest
        // UTF8 prefix that will fit in the UTF16 buffer
        // TODO: Round down to nearest full codepoint
        _ = data;
        return utf16_buf_len;
    }

    pub fn writer(self: Self) Writer {
        return .{ .context = self };
    }
};

pub fn consoleWriter(proto: *uefi.protocol.SimpleTextOutput) ConsoleWriter.Writer {
    return ConsoleWriter.init(proto).writer();
}

pub const SerialIoWrapper = struct {
    pub const Error = error{ DeviceError, Timeout, UnexpectedError };
    pub const Reader = std.io.GenericReader(Self, Error, read);
    pub const Writer = std.io.GenericWriter(Self, Error, write);

    serial_io_proto: *uefi.protocol.SerialIo,

    const Self = @This();

    pub fn init(proto: *uefi.protocol.SerialIo) Self {
        return .{ .serial_io_proto = proto };
    }

    // TODO: Return read/written bytes in case of timeout errors?

    pub fn read(self: Self, data: []u8) Error!usize {
        var len = data.len;
        return switch (self.serial_io_proto.read(&len, data.ptr)) {
            .success => len,
            .device_error => error.DeviceError,
            .timeout => error.Timeout,
            else => error.UnexpectedError,
        };
    }

    pub fn reader(self: Self) Reader {
        return .{ .context = self };
    }

    pub fn write(self: Self, data: []const u8) Error!usize {
        var len = data.len;
        // The UEFI API doesn't use const, but the buffer is not modified by `write`
        return switch (self.serial_io_proto.write(&len, @constCast(data.ptr))) {
            .success => len,
            .device_error => error.DeviceError,
            .timeout => error.Timeout,
            else => error.UnexpectedError,
        };
    }

    pub fn writer(self: Self) Writer {
        return .{ .context = self };
    }
};

pub fn serialIoReader(proto: *uefi.protocol.SerialIo) SerialIoWrapper.Reader {
    return SerialIoWrapper.init(proto).reader();
}

pub fn serialIoWriter(proto: *uefi.protocol.SerialIo) SerialIoWrapper.Writer {
    return SerialIoWrapper.init(proto).writer();
}

var logging_serial_io_proto: ?*uefi.protocol.SerialIo = null;

pub fn serialIoLog(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (logging_serial_io_proto) |serial_proto| {
        const level_txt = comptime message_level.asText();
        const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
        const writer = serialIoWriter(serial_proto);
        // TODO: Use buffered writer?

        writer.print(level_txt ++ prefix2 ++ format ++ "\r\n", args) catch return;
    }
}

pub fn setupSerialLogger() void {
    // TODO: Pick a specific instance? Forward to all of them?
    uefi.system_table.boot_services.?.locateProtocol(&uefi.protocol.SerialIo.guid, null, @ptrCast(&logging_serial_io_proto)).err() catch {
        return;
    };

    std.log.info("configured logging", .{});
}

pub const DebugConsoleError = error{};

pub fn debugConsoleWrite(context: void, buf: []const u8) DebugConsoleError!usize {
    const DEBUG_PORT = 0xe9;
    _ = context;
    port_io.outsb(DEBUG_PORT, buf);
    return buf.len;
}

// TODO: Put a lock on this to prevent interleaving
pub const debugConsoleWriter = std.io.GenericWriter(void, DebugConsoleError, debugConsoleWrite){ .context = {} };

pub fn debugConsoleLog(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const level_txt = comptime message_level.asText();
    const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
    const writer = debugConsoleWriter;

    writer.print(level_txt ++ prefix2 ++ format ++ "\n", args) catch return;
}
