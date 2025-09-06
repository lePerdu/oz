const std = @import("std");

pub const mmio_start: u64 = 0xFFFF_FFFF_F800_0000;
pub const fb_start: u64 = 0xFFFF_FFFF_FC00_0000;
pub const bootboot_start: u64 = 0xFFFF_FFFF_FFE0_0000;
pub const environment_start: u64 = 0xFFFF_FFFF_FFE0_1000;
pub const kernel_start: u64 = 0xFFFF_FFFF_FFE0_2000;
pub const kernel_stack_pages: usize = 16;
pub const kernel_stack_start: u64 = 0xFFFF_FFFF_FFFF_FFFF - kernel_stack_pages * 4096 + 1;
pub const kernel_stack_init: u64 = 0;

pub const magic: [4]u8 = "BOOT".*;

pub const Bootboot = extern struct {
    magic: [4]u8 align(4096) = magic,
    /// Total size of the structure
    size: u32,
    protocol: Protocol,
    fb_type: FbType,
    numcores: u16 = 1,
    bspid: u16,
    timezone: i16,
    datetime: Datetime,
    initrd_ptr: u64,
    initrd_size: u64,
    fb_ptr: u64,
    fb_size: u32,
    fb_width: u32,
    fb_height: u32,
    fb_scanline: u32,
    platform: PlatformPointers,
    mmap: [0]MMapEnt,

    const Self = @This();

    /// Maximum number of memory map entries that can fit in the Bootboot structure
    /// on a single page
    pub const max_mmap_entries: usize = (4096 - @offsetOf(Self, "mmap")) / @sizeOf(MMapEnt);

    pub inline fn mmapEntriesPtr(self: *Self) [*]MMapEnt {
        return @ptrCast(&self.mmap);
    }

    pub fn mmapEntries(self: *Self) []MMapEnt {
        const n = (self.size - @offsetOf(Self, "mmap")) / 16;
        return self.mmapEntriesPtr()[0..n];
    }

    pub fn mmapEntriesBuf(self: *Self) []MMapEnt {
        return self.mmapEntriesPtr()[0..max_mmap_entries];
    }

    pub fn computeSize(mmap_entries: usize) u32 {
        return @intCast(@offsetOf(Self, "mmap") + mmap_entries * @sizeOf(MMapEnt));
    }

    pub fn setComputedSize(self: *Self, mmap_entries: usize) void {
        self.size = computeSize(mmap_entries);
    }

    comptime {
        std.debug.assert(@alignOf(Self) == 4096);
        std.debug.assert(@offsetOf(Self, "mmap") == 128);
    }
};

pub const Protocol = packed struct {
    level: ProtocolLevel,
    loader: Loader,
    big_endian: bool,

    comptime {
        std.debug.assert(@bitSizeOf(@This()) == 8);
    }
};

pub const ProtocolLevel = enum(u2) {
    minimal = 0,
    static = 1,
    dynamic = 2,
};

pub const Loader = enum(u5) {
    bios = 0,
    uefi = 1,
    rpi = 2,
    coreboot = 3,
};

pub const FbType = enum(u8) {
    argb = 0,
    rgba = 1,
    abgr = 2,
    bgra = 3,
    none = 4,
};

pub const Datetime = extern struct {
    bcd_year: [2]u8,
    bcd_month: u8,
    bcd_day: u8,
    bcd_hours: u8,
    bcd_minutes: u8,
    bcd_seconds: u8,
    bcd_centiseconds: u8,

    comptime {
        std.debug.assert(@sizeOf(@This()) == 8);
    }
};

pub const Bcd = extern struct {
    bits: u8,

    const Self = @This();

    pub fn fromInt(n: u8) ?Self {
        if (n > 99) {
            return null;
        }

        const upper = n / 10;
        const lower = n % 10;
        return upper * 16 + lower;
    }

    test fromInt {
        try std.testing.expectEqual(.{ .bits = 0 }, fromInt(0));
        try std.testing.expectEqual(.{ .bits = 0x78 }, fromInt(78));
        try std.testing.expectEqual(.{ .bits = 0x99 }, fromInt(99));
        try std.testing.expectEqual(null, fromInt(105));
    }

    pub fn toInt(self: Self) u8 {
        const upper = self.bits >> 4;
        const lower = self.bits & 0xF;
        std.debug.assert(upper < 10);
        std.debug.assert(lower < 10);
        return upper * 10 + lower;
    }

    test toInt {
        try std.testing.expectEqual(0, (Self{ .bits = 0 }).toInt());
        try std.testing.expectEqual(78, (Self{ .bits = 0x78 }).toInt());
        try std.testing.expectEqual(99, (Self{ .bits = 0x99 }).toInt());
    }

    test "toInt(fromInt(n))" {
        try std.testing.expectEqual(0, fromInt(0).toInt());
        try std.testing.expectEqual(6, fromInt(6).toInt());
        try std.testing.expectEqual(39, fromInt(39).toInt());
        try std.testing.expectEqual(99, fromInt(99).toInt());
    }

    comptime {
        std.debug.assert(@sizeOf(Self) == 1);
    }
};

pub const PlatformPointers = extern union {
    x64_64: extern struct {
        acpi_ptr: u64,
        smbi_ptr: u64,
        efi_ptr: u64,
        mp_ptr: u64,
        unused: [4]u64 = undefined,
    },
    aarch64: extern struct {
        acpi_ptr: u64,
        mmio_ptr: u64,
        efi_ptr: u64,
        unused: [5]u64 = undefined,
    },
};

pub const MMapEnt = extern struct {
    ptr: u64,
    size_type: u64,

    const Self = @This();

    pub inline fn init(ptr: u64, size: u64, typ: MMapType) Self {
        std.debug.assert(size & 0xF == 0);
        return .{
            .ptr = ptr,
            .size_type = size + @intFromEnum(typ),
        };
    }

    pub inline fn getSizeBytes(self: *const Self) u64 {
        return self.size_type & 0xFFFF_FFFF_FFFF_FFF0;
    }

    pub inline fn getSizePages(self: *const Self) u64 {
        return self.size_type >> 12;
    }

    pub inline fn getType(self: *const Self) MMapType {
        return @enumFromInt(@as(u4, @truncate(self.size_type)));
    }

    pub inline fn isFree(self: *const Self) bool {
        return self.getType() == .free;
    }

    pub fn tryMerge(self: *const Self, other: *const Self) ?Self {
        if (self.getType() == other.getType() and self.ptr + self.getSizeBytes() == other.ptr) {
            return init(self.ptr, self.getSizeBytes() + other.getSizeBytes(), self.getType());
        } else {
            return null;
        }
    }

    comptime {
        std.debug.assert(@sizeOf(Self) == 16);
    }
};

pub const MMapType = enum(u4) {
    used = 0,
    free = 1,
    acpi = 2,
    mmio = 3,
    _,
};
