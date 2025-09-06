const std = @import("std");
const uefi = std.os.uefi;

const paging = @import("./paging.zig");

pub const MemoryMap = struct {
    key: usize,
    /// Total buffer allocated for the map
    buffer: []align(@alignOf(Desc)) u8,
    /// Used sized of the buffer
    entry_count: usize,
    descriptor_size: usize,

    const Self = @This();
    const Desc = uefi.tables.MemoryDescriptor;

    /// Simpler constructor when a Zig slice is available
    pub fn fromSlice(key: usize, slice: []Desc) Self {
        const size = @sizeOf(Desc) * slice.len;
        const bytes_ptr: [*]align(@alignOf(Desc)) u8 = @ptrCast(slice.ptr);
        return fromByteBuffer(key, bytes_ptr[0..size], size, @sizeOf(Desc));
    }

    /// Constructor taking a raw memory region, with a runtime-known descriptor size
    pub fn fromByteBuffer(key: usize, buffer: []align(@alignOf(Desc)) u8, used_size: usize, descriptor_size: usize) Self {
        return Self{
            .key = key,
            .buffer = buffer,
            .entry_count = used_size / descriptor_size,
            .descriptor_size = descriptor_size,
        };
    }

    pub fn deinit(self: *const Self, buffer_allocator: std.mem.Allocator) void {
        buffer_allocator.free(self.buffer);
    }

    pub fn iterator(self: *const Self) Iterator {
        return .{
            .map = self,
            .current = @ptrCast(self.buffer.ptr),
        };
    }

    fn uefiTypeUseable(typ: uefi.tables.MemoryType) bool {
        return switch (typ) {
            .unusable_memory,
            .reserved_memory_type,
            => false,
            else => true,
        };
    }

    pub fn calculateTotalMemoryPages(self: *const Self) usize {
        var last_useable_addr: u64 = 0;
        var iter = self.iterator();
        while (iter.next()) |next| {
            if (uefiTypeUseable(next.type)) {
                last_useable_addr = next.physical_start + next.number_of_pages * 4096;
            }
        }
        return paging.addressToPageNum(last_useable_addr);
    }

    pub fn calculateRuntimeMemoryPages(self: *const Self) u64 {
        var total: u64 = 0;
        var iter = self.iterator();
        while (iter.next()) |next| {
            if (next.attribute.memory_runtime) {
                total += next.number_of_pages;
            }
        }
        return total;
    }

    fn descriptorsCompactable(a: *const Desc, b: *const Desc) bool {
        return (a.type == .conventional_memory and b.type == .conventional_memory and
            a.attribute == b.attribute and
            a.physical_start + a.number_of_pages * 4096 == b.physical_start and
            a.virtual_start + a.number_of_pages * 4096 == b.virtual_start);
    }

    /// Compact adjacent free regions into a single region
    pub fn compact(self: *Self) void {
        var read_iter = self.iterator();
        var write_iter = self.iterator();

        _ = read_iter.next() orelse return;
        var write_head = write_iter.next() orelse return;
        while (read_iter.next()) |read_head| {
            std.debug.assert(@intFromPtr(read_head) > @intFromPtr(write_head));
            if (descriptorsCompactable(write_head, read_head)) {
                write_head.number_of_pages += read_head.number_of_pages;
            } else {
                write_head = write_iter.next() orelse @panic("no more space in memory map");
                if (read_head != write_head) {
                    write_head.* = read_head.*;
                }
            }
        }

        self.entry_count = write_iter.pos();
    }
};

pub const Iterator = struct {
    map: *const MemoryMap,
    current: *Desc,

    const Self = @This();
    const Desc = MemoryMap.Desc;

    pub fn next(self: *Self) ?*Desc {
        const next_item = self.peek();
        self.current = @ptrFromInt(@intFromPtr(self.current) + self.map.descriptor_size);
        return next_item;
    }

    /// Return the next item, without advancing the iterator
    pub fn peek(self: *const Self) ?*Desc {
        const buffer_end: usize = @intFromPtr(self.map.buffer.ptr) +
            self.map.entry_count * self.map.descriptor_size;
        if (@intFromPtr(self.current) >= buffer_end) {
            return null;
        }

        return self.current;
    }

    fn pos(self: *const Self) usize {
        return (@intFromPtr(self.current) - @intFromPtr(self.map.buffer.ptr)) / self.map.descriptor_size;
    }
};

test "MemoryMap.iterator" {
    const attr = std.mem.zeroes(uefi.tables.MemoryDescriptorAttribute);
    var descriptor_array = [_]MemoryMap.Desc{
        .{ .type = .boot_services_code, .attribute = attr, .number_of_pages = 2, .physical_start = 0x0, .virtual_start = 0x0 },
        .{ .type = .boot_services_data, .attribute = attr, .number_of_pages = 1, .physical_start = 0x2000, .virtual_start = 0x2000 },
        .{ .type = .conventional_memory, .attribute = attr, .number_of_pages = 16, .physical_start = 0x3000, .virtual_start = 0x3000 },
        .{ .type = .loader_code, .attribute = attr, .number_of_pages = 5, .physical_start = 0x12000, .virtual_start = 0x1000_0000 },
    };
    const map = MemoryMap.fromSlice(1234, &descriptor_array);

    var iter = map.iterator();
    try std.testing.expectEqual(&descriptor_array[0], iter.next());
    try std.testing.expectEqual(&descriptor_array[1], iter.next());
    try std.testing.expectEqual(&descriptor_array[2], iter.next());
    try std.testing.expectEqual(&descriptor_array[3], iter.next());
    try std.testing.expectEqual(null, iter.next());
}

test "MemoryMap.iterator with extra space in byte buffer" {
    const attr = std.mem.zeroes(uefi.tables.MemoryDescriptorAttribute);
    const padding = MemoryMap.Desc{
        .type = @enumFromInt(0x8000_0001),
        .attribute = attr,
        .number_of_pages = std.math.maxInt(u64),
        .physical_start = 0x5555_5555,
        .virtual_start = 0xAAAA_AAAA,
    };
    var descriptor_array = [_]MemoryMap.Desc{
        .{ .type = .boot_services_code, .attribute = attr, .number_of_pages = 2, .physical_start = 0x0, .virtual_start = 0x0 },
        .{ .type = .boot_services_data, .attribute = attr, .number_of_pages = 1, .physical_start = 0x2000, .virtual_start = 0x2000 },
        .{ .type = .conventional_memory, .attribute = attr, .number_of_pages = 16, .physical_start = 0x3000, .virtual_start = 0x3000 },
        .{ .type = .loader_code, .attribute = attr, .number_of_pages = 5, .physical_start = 0x12000, .virtual_start = 0x1000_0000 },
        padding,
        padding,
        padding,
    };
    const bytes_ptr: [*]align(@alignOf(MemoryMap.Desc)) u8 = @ptrCast(&descriptor_array);
    const bytes_len = @sizeOf(@TypeOf(descriptor_array));
    const used_len = @sizeOf(MemoryMap.Desc) * 4;
    const map = MemoryMap.fromByteBuffer(1234, bytes_ptr[0..bytes_len], used_len, @sizeOf(MemoryMap.Desc));

    var iter = map.iterator();
    try std.testing.expectEqual(&descriptor_array[0], iter.next());
    try std.testing.expectEqual(&descriptor_array[1], iter.next());
    try std.testing.expectEqual(&descriptor_array[2], iter.next());
    try std.testing.expectEqual(&descriptor_array[3], iter.next());
    try std.testing.expectEqual(null, iter.next());
}

test "MemoryMap.iterator with custom `descriptor_size`" {
    const attr = std.mem.zeroes(uefi.tables.MemoryDescriptorAttribute);
    const padding = MemoryMap.Desc{
        .type = @enumFromInt(0x8000_0001),
        .attribute = attr,
        .number_of_pages = std.math.maxInt(u64),
        .physical_start = 0x5555_5555,
        .virtual_start = 0xAAAA_AAAA,
    };
    var descriptor_array = [_]MemoryMap.Desc{
        .{ .type = .boot_services_code, .attribute = attr, .number_of_pages = 2, .physical_start = 0x0, .virtual_start = 0x0 },
        padding,
        .{ .type = .boot_services_data, .attribute = attr, .number_of_pages = 1, .physical_start = 0x2000, .virtual_start = 0x2000 },
        padding,
        .{ .type = .conventional_memory, .attribute = attr, .number_of_pages = 16, .physical_start = 0x3000, .virtual_start = 0x3000 },
        padding,
        .{ .type = .loader_code, .attribute = attr, .number_of_pages = 5, .physical_start = 0x12000, .virtual_start = 0x1000_0000 },
        padding,
    };
    const bytes_ptr: [*]align(@alignOf(MemoryMap.Desc)) u8 = @ptrCast(&descriptor_array);
    const bytes_len = @sizeOf(@TypeOf(descriptor_array));
    const map = MemoryMap.fromByteBuffer(1234, bytes_ptr[0..bytes_len], bytes_len, @sizeOf(MemoryMap.Desc) * 2);

    var iter = map.iterator();
    try std.testing.expectEqual(&descriptor_array[0], iter.next());
    try std.testing.expectEqual(&descriptor_array[2], iter.next());
    try std.testing.expectEqual(&descriptor_array[4], iter.next());
    try std.testing.expectEqual(&descriptor_array[6], iter.next());
    try std.testing.expectEqual(null, iter.next());
}

test "MemoryMap.compact" {
    const attr = std.mem.zeroes(uefi.tables.MemoryDescriptorAttribute);
    var descriptor_array = [_]MemoryMap.Desc{
        .{ .type = .boot_services_code, .attribute = attr, .number_of_pages = 2, .physical_start = 0x0, .virtual_start = 0x0 },
        .{ .type = .conventional_memory, .attribute = attr, .number_of_pages = 1, .physical_start = 0x2000, .virtual_start = 0x2000 },
        .{ .type = .conventional_memory, .attribute = attr, .number_of_pages = 16, .physical_start = 0x3000, .virtual_start = 0x3000 },
        .{ .type = .loader_code, .attribute = attr, .number_of_pages = 5, .physical_start = 0x12000, .virtual_start = 0x100_0000 },
    };
    var map = MemoryMap.fromSlice(1234, &descriptor_array);

    map.compact();
    try std.testing.expectEqual(3, map.entry_count);

    var iter = map.iterator();
    try std.testing.expectEqual(
        MemoryMap.Desc{ .type = .boot_services_code, .attribute = attr, .number_of_pages = 2, .physical_start = 0x0, .virtual_start = 0x0 },
        iter.next().?.*,
    );
    try std.testing.expectEqual(
        MemoryMap.Desc{ .type = .conventional_memory, .attribute = attr, .number_of_pages = 17, .physical_start = 0x2000, .virtual_start = 0x2000 },
        iter.next().?.*,
    );
    try std.testing.expectEqual(
        MemoryMap.Desc{ .type = .loader_code, .attribute = attr, .number_of_pages = 5, .physical_start = 0x12000, .virtual_start = 0x100_0000 },
        iter.next().?.*,
    );
    try std.testing.expectEqual(null, iter.next());
}

test "MemoryMap.compact incompactible" {
    const attr = std.mem.zeroes(uefi.tables.MemoryDescriptorAttribute);
    var descriptor_array = [_]MemoryMap.Desc{
        .{ .type = .boot_services_code, .attribute = attr, .number_of_pages = 2, .physical_start = 0x0, .virtual_start = 0x0 },
        .{ .type = .conventional_memory, .attribute = attr, .number_of_pages = 1, .physical_start = 0x2000, .virtual_start = 0x2000 },
        .{ .type = .conventional_memory, .attribute = attr, .number_of_pages = 16, .physical_start = 0x3000, .virtual_start = 0x10000 },
        .{ .type = .loader_code, .attribute = attr, .number_of_pages = 5, .physical_start = 0x12000, .virtual_start = 0x100_0000 },
    };
    var map = MemoryMap.fromSlice(1234, &descriptor_array);

    map.compact();
    try std.testing.expectEqual(4, map.entry_count);

    var iter = map.iterator();
    try std.testing.expectEqual(
        MemoryMap.Desc{ .type = .boot_services_code, .attribute = attr, .number_of_pages = 2, .physical_start = 0x0, .virtual_start = 0x0 },
        iter.next().?.*,
    );
    try std.testing.expectEqual(
        MemoryMap.Desc{ .type = .conventional_memory, .attribute = attr, .number_of_pages = 1, .physical_start = 0x2000, .virtual_start = 0x2000 },
        iter.next().?.*,
    );
    try std.testing.expectEqual(
        MemoryMap.Desc{ .type = .conventional_memory, .attribute = attr, .number_of_pages = 16, .physical_start = 0x3000, .virtual_start = 0x10000 },
        iter.next().?.*,
    );
    try std.testing.expectEqual(
        MemoryMap.Desc{ .type = .loader_code, .attribute = attr, .number_of_pages = 5, .physical_start = 0x12000, .virtual_start = 0x100_0000 },
        iter.next().?.*,
    );
    try std.testing.expectEqual(null, iter.next());
}
