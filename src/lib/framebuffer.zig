const std = @import("std");
const log = std.log;
const uefi = std.os.uefi;

pub const Pixel = extern struct {
    b: u8,
    g: u8,
    r: u8,
    _reserved: u8 = undefined,

    const Self = @This();

    pub fn fromRgb(r: u8, g: u8, b: u8) Self {
        return .{ .b = b, .g = g, .r = r };
    }
};

pub const Coord = struct {
    x: u32,
    y: u32,

    pub const zero = @This(){ .x = 0, .y = 0 };
};

pub const Rect = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,

    pub const empty = @This(){ .x = 0, .y = 0, .width = 0, .height = 0 };

    pub fn fromSize(width: u32, height: u32) @This() {
        return .{ .x = 0, .y = 0, .width = width, .height = height };
    }
};

/// Frame buffer from `EFI_GRAPHICS_OUTPUT_PROTOCOL`, but with a custom
/// implementation of `Blt` so that it can be used after exiting Boot Services.
pub const FrameBuffer = struct {
    // TODO: support different pixel formats
    raw: [*]Pixel,
    width: u32,
    height: u32,
    pixels_per_row: u32,

    const Self = @This();

    pub fn init(buffer: []Pixel, width: u32, height: u32) Self {
        std.debug.assert(buffer.len == width * height);
        return Self{ .raw = buffer.ptr, .width = width, .height = height, .pixels_per_row = width };
    }

    pub fn fromUefiGop(proto: *uefi.protocol.GraphicsOutput) Self {
        // TODO: Return error instead of assert?
        const grid_size = proto.mode.info.vertical_resolution * proto.mode.info.pixels_per_scan_line;
        std.debug.assert(proto.mode.frame_buffer_size == grid_size * @sizeOf(Pixel));
        return Self{
            .raw = @as([*]Pixel, @ptrFromInt(proto.mode.frame_buffer_base)),
            .width = proto.mode.info.horizontal_resolution,
            .height = proto.mode.info.vertical_resolution,
            .pixels_per_row = proto.mode.info.pixels_per_scan_line,
        };
    }

    pub fn sizePixels(self: *const Self) u32 {
        // TODO: Upcast to usize?
        return self.height * self.pixels_per_row;
    }

    pub fn sizeBytes(self: *const Self) u32 {
        return self.sizePixels() * @sizeOf(Pixel);
    }

    fn index(self: *const Self, x: usize, y: usize) usize {
        std.debug.assert(x < self.width);
        std.debug.assert(y < self.height);
        return y * self.pixels_per_row + x;
    }

    pub fn offsetConst(self: *const Self, x: usize, y: usize) [*]const Pixel {
        return @ptrCast(&self.raw[self.index(x, y)]);
    }

    pub fn offset(self: *const Self, x: usize, y: usize) [*]Pixel {
        return @ptrCast(&self.raw[self.index(x, y)]);
    }

    pub fn get(self: *const Self, x: usize, y: usize) Pixel {
        return self.raw[self.index(x, y)];
    }

    pub fn set(self: *const Self, x: usize, y: usize, p: Pixel) void {
        self.raw[self.index(x, y)] = p;
    }

    pub fn copy(self: *const Self, src: *const Self) void {
        std.debug.assert(self.width == src.width and self.height == src.height);
        var self_iter = self.iterRows();
        var src_iter = self.iterRows();
        while (self_iter.next()) |self_row| {
            @memcpy(self_row, src_iter.next().?);
        }
    }

    pub fn fill(self: *const Self, pixel: Pixel) void {
        var row_iter = self.iterRows();
        while (row_iter.next()) |row| {
            @memset(row, pixel);
        }
    }

    pub fn region(self: *const Self, rect: Rect) Self {
        std.debug.assert(rect.x + rect.width <= self.width);
        std.debug.assert(rect.y + rect.height <= self.height);
        return Self{
            .raw = @ptrCast(&self.raw[rect.y * self.pixels_per_row + rect.x]),
            .width = rect.width,
            .height = rect.height,
            .pixels_per_row = self.pixels_per_row,
        };
    }

    pub const RowIter = struct {
        fb: *const FrameBuffer,
        offset: usize = 0,

        pub fn next(self: *@This()) ?[]Pixel {
            if (self.offset >= self.fb.pixels_per_row * self.fb.height) {
                return null;
            }
            const row = self.fb.raw[self.offset..][0..self.fb.width];
            self.offset += self.fb.pixels_per_row;
            return row;
        }
    };

    pub fn iterRows(self: *const Self) RowIter {
        return .{ .fb = self };
    }
};

pub fn setupFrameBuffer() !FrameBuffer {
    var gop_proto: *uefi.protocol.GraphicsOutput = undefined;
    try uefi.system_table.boot_services.?.locateProtocol(
        &uefi.protocol.GraphicsOutput.guid,
        null,
        @ptrCast(&gop_proto),
    ).err();

    // for (0..gop_proto.mode.max_mode) |mode_num| {
    var info: *uefi.protocol.GraphicsOutput.Mode.Info = undefined;
    var info_size: usize = @sizeOf(@TypeOf(info.*));
    try gop_proto.queryMode(gop_proto.mode.mode, &info_size, &info).err();

    log.info("GOP: mode {}: {}", .{ gop_proto.mode.mode, info });
    // }

    return FrameBuffer.fromUefiGop(gop_proto);
}

pub const BitmapConfig = struct {
    fg: Pixel,
    bg: Pixel,
    width: u8,
    height: u8,
    padding: u8,
};

pub fn renderBitmap(fb: *FrameBuffer, x_base: usize, y_base: usize, bitmap: []const u8, config: BitmapConfig) void {
    const row_byte_len = std.math.divCeil(u8, config.width, 8) catch undefined;
    std.debug.assert(bitmap.len >= row_byte_len * config.height);

    for (0..config.height) |dy| {
        const y = y_base + dy;
        if (y >= fb.height) break;
        for (0..config.width) |dx| {
            const x = x_base + dx;
            if (x >= fb.width) break;
            // TODO: Shift progressively rather than re-shifting each iteration
            const byte = bitmap[dy * row_byte_len + dx / 8];
            const mask = @as(u8, 0x80) >> @truncate(dx % 8);
            if (byte & mask != 0) {
                // TODO: Alpha blending?
                fb.set(x, y, config.fg);
            } else {
                fb.set(x, y, config.bg);
            }
        }
        // TODO: Support RTL padding
        for (0..config.padding) |dx| {
            const x = x_base + config.width + dx;
            fb.set(x, y, config.bg);
        }
    }
}
