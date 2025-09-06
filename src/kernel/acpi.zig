const std = @import("std");
const assert = std.debug.assert;
const uefi = std.os.uefi;

const io = @import("./io.zig");

fn u8sum(obj: anytype) u8 {
    // TODO: Also support slices
    const bytes: [*]u8 = @ptrCast(&obj);
    var sum: u8 = 0;
    for (bytes[0..@sizeOf(obj)]) |byte| {
        sum = @addWithOverflow(sum, byte)[0];
    }
    return sum;
}

fn checksum(args: anytype) u8 {
    var sum: u8 = 0;
    inline for (args) |arg| {
        sum = @addWithOverflow(sum, u8sum(arg))[0];
    }
    return @addWithOverflow(0xff - sum, 1)[0];
}

pub const Rsdp = extern struct {
    pub const SIGNATURE: [8]u8 = "RSD PTR ".*;

    signature: [8]u8 = SIGNATURE,
    checksum: u8,
    oemid: [6]u8,
    revision: u8,
    rsdt_address: u32,
    length: u32,

    xsdt_address: u64,
    extended_checksum: u64,

    _reserved: [3]u8,

    const Self = @This();

    comptime {
        assert(@sizeOf(Self) == 36);
    }

    pub fn rsdtPtr(self: *const Self) *anyopaque {
        comptime assert(@sizeOf(*anyopaque) == 32);
        return @ptrFromInt(self.rsdt_address);
    }

    pub fn xsdtPtr(self: *const Self) *anyopaque {
        return @ptrFromInt(self.xsdt_address);
    }

    pub fn computeChecksum(self: *const Self) u8 {
        return checksum(.{
            self.signature,
            self.oemid,
            self.revision,
            self.rsdt_address,
        });
    }

    pub fn computeExtendedChecksum(self: *const Self) u8 {
        return checksum(.{
            self.signature,
            // Includes the old checksum
            self.checksum,
            self.oemid,
            self.revision,
            self.rsdt_address,
            self.length,
            self.xsdt_address,
        });
    }
};

fn findConfTable(guid: uefi.Guid) ?*anyopaque {
    const conf_table = uefi.system_table.configuration_table[0..uefi.system_table.number_of_table_entries];
    for (conf_table) |*conf_entry| {
        if (conf_entry.vendor_guid.eql(guid)) {
            return conf_entry.vendor_table;
        }
    }

    return null;
}

pub fn showAcpiTables() !void {
    // const con_in = uefi.system_table.con_in.?;
    const con_out = uefi.system_table.con_out.?;
    const stdout = io.ConsoleWriter.init(con_out).writer();

    if (findConfTable(uefi.tables.ConfigurationTable.acpi_20_table_guid)) |opaque_rsdp| {
        const rsdp: *Rsdp = @ptrCast(@alignCast(opaque_rsdp));
        try stdout.print("found ACPI 2.0 table: {*}: {}\r\n", .{ rsdp, rsdp.* });
    } else if (findConfTable(uefi.tables.ConfigurationTable.acpi_10_table_guid)) |rsdpv1| {
        try stdout.print("found ACPI 1.0 table: {*}\r\n", .{rsdpv1});
        return;
    } else {
        try stdout.print("no acpi table found\r\n", .{});
        return;
    }
}
