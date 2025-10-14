const std = @import("std");

pub fn computeChecksum(bytes: []const u8) u8 {
    var sum: u8 = 0;
    for (bytes) |b| sum +%= b;
    return sum;
}

pub fn computeChecksumSizeOf(fixed_sized_struct_ptr: *const anyopaque) u8 {
    return computeChecksum(std.mem.asBytes(fixed_sized_struct_ptr));
}

pub fn computeChecksumWithLength(dynamic_sized_struct_ptr: *const anyopaque, length: usize) u8 {
    const bytes_ptr: [*]const u8 = @ptrCast(dynamic_sized_struct_ptr);
    return computeChecksum(bytes_ptr[0..length]);
}

pub const Rsdp = extern struct {
    pub const SIGNATURE = "RSD PTR ".*;

    signature: [8]u8,
    checksum: u8,
    oemid: [6]u8,
    revision: u8,
    rsdt_addr: u32,

    length: u32,
    // TODO: ACPI spec says the table should be found on 16-byte boundaries,
    // but the structure is only 4-byte aligned in QEMU
    xsdt_addr: u64 align(4),
    extended_checksum: u8,
    _reserved: [3]u8 = .{ 0, 0, 0 },

    const Self = @This();

    pub fn rsdtPtr(self: *const Self) *const Rsdt {
        comptime std.debug.assert(@sizeOf(*anyopaque) == 32);
        return @ptrFromInt(self.rsdt_addr);
    }

    pub fn xsdtPtr(self: *const Self) *const Xsdt {
        return @ptrFromInt(self.xsdt_addr);
    }

    pub fn valid(self: *const @This()) bool {
        return self.signatureValid() and self.versionValid() and self.checksumValid();
    }

    pub fn signatureValid(self: *const @This()) bool {
        return std.mem.eql(u8, &self.signature, &SIGNATURE);
    }

    pub fn versionValid(self: *const @This()) bool {
        return self.revision >= 2;
    }

    pub fn checksumValid(self: *const @This()) bool {
        const base_checksum = computeChecksumWithLength(self, 20);
        if (base_checksum != 0) return false;
        const extended_checksum = computeChecksumWithLength(self, self.length);
        return extended_checksum == 0;
    }
};

pub const DescriptionHeader = extern struct {
    signature: [4]u8,
    length: u32,
    revision: u8,
    checksum: u8,
    oemid: [6]u8,
    oem_table_id: u64 align(4),
    oem_revision: u32,
    creator_id: u32,
    creator_revision: u32,

    pub fn valid(self: *const @This(), expected_signature: [4]u8) bool {
        return self.hasSignature(expected_signature) and self.checksumValid();
    }

    pub fn hasSignature(self: *const @This(), other: [4]u8) bool {
        return std.mem.eql(u8, &self.signature, &other);
    }

    pub fn checksumValid(self: *const @This()) bool {
        return computeChecksumWithLength(self, self.length) == 0;
    }
};

pub const Rsdt = extern struct {
    pub const SIGNATURE = "RSDT".*;
    header: DescriptionHeader,
    _entries: [0]u32,

    pub fn entries(self: *const @This()) []const *const DescriptionHeader {
        comptime std.debug.assert(@sizeOf(*anyopaque) == @sizeOf(@TypeOf(self._entries[0])));
        const raw_ptr: [*]const u8 = @ptrCast(&self._entries);
        const raw_len = self.header.length - @sizeOf(@This());
        return std.mem.bytesAsSlice(*const DescriptionHeader, raw_ptr[0..raw_len]);
    }
};

pub const Xsdt = extern struct {
    pub const SIGNATURE = "XSDT".*;
    header: DescriptionHeader,
    _entries: [0]u64 align(4),

    pub fn entries(self: *const @This()) []align(4) const *const DescriptionHeader {
        const entryElem = std.meta.Elem(@TypeOf(self._entries));
        comptime std.debug.assert(@sizeOf(*anyopaque) == @sizeOf(entryElem));
        const raw_ptr: [*]align(4) const u8 = @ptrCast(&self._entries);
        // const raw_ptr: [*]align(4) const u8 = @ptrFromInt(@intFromPtr(self) + @sizeOf(@This()));
        const raw_len = self.header.length - @sizeOf(@This());
        return std.mem.bytesAsSlice(*const DescriptionHeader, raw_ptr[0..raw_len]);
    }

    pub fn findTypedTable(self: *const @This(), table_type: type) ?*const table_type {
        if (!@hasDecl(table_type, "SIGNATURE")) {
            @compileError("Xsdt.findTable: table type must have decl: `SIGNATURE: [4]u8`");
        }
        const signature: [4]u8 = @field(table_type, "SIGNATURE");

        const header_ptr = self.findTable(signature) orelse return null;
        return @ptrCast(header_ptr);
    }

    pub fn findTable(self: *const @This(), signature: [4]u8) ?*const DescriptionHeader {
        for (self.entries()) |entry| {
            if (entry.valid(signature)) {
                return entry;
            }
        }
        return null;
    }
};

pub const Fadt = extern struct {
    pub const SIGNATURE = "FADT".*;
    header: DescriptionHeader,
    facs_addr: u32,
    dsdt_addr: u32,

    // This contains lots of values I don't care about (yet)
    _unused: [88]u8,

    x_facs_addr: u64,
    x_dsdt_addr: u64,

    const Self = @This();

    pub fn dsdtPtr(self: *const Self) *const Dsdt {
        if (comptime @sizeOf(*anyopaque) == 64) {
            if (self.x_dsdt_addr != 0) {
                return @ptrFromInt(self.x_dsdt_addr);
            } else {
                return @ptrFromInt(self.dsdt_addr);
            }
        } else {
            return @ptrFromInt(self.dsdt_addr);
        }
    }

    comptime {
        std.debug.assert(@offsetOf(Self, "x_facs_addr") == 132);
    }
};

pub const Dsdt = extern struct {
    pub const SIGNATURE = "DSDT".*;
    header: DescriptionHeader,
    _definition_block: [0]u8,
};

pub const Ssdt = extern struct {
    pub const SIGNATURE = "SSDT".*;
    header: DescriptionHeader,
    _definition_block: [0]u8,
};

pub const Madt = extern struct {
    pub const SIGNATURE = "APIC".*;

    header: DescriptionHeader,
    local_controller_addr: u32,
    flags: Flags,
    _controllers_data: [0]u8,

    pub const Flags = packed struct(u32) {
        pcat_compat: bool,
        _reserved: u31 = 0,
    };

    pub const InterruptControllerType = enum(u8) {
        local_apic = 0,
        io_apic = 1,
        interrupt_source_override = 2,
        nmi_source = 3,
        local_apic_nmi = 4,
        local_apic_address_override = 5,
        io_sapic = 7,
        local_sapic = 8,
        local_x2apic = 9,
        local_x2apic_nmi = 10,
        _,
    };

    pub const ControllerHeader = extern struct {
        _type: InterruptControllerType,
        length: u8,
    };

    pub const Controller = union(enum) {
        local_apic: *align(1) const LocalApic,
        io_apic: *align(1) const IoApic,
        interrupt_source_override: *align(1) const InterruptSourceOverride,
        nmi_source: *align(1) const NmiSource,
        local_apic_nmi: *align(1) const LocalApicNmi,
        local_apic_address_override: *align(1) const LocalApicAddressOverride,
        io_sapic: *align(1) const IoSApic,
        local_sapic: *align(1) const LocalSApic,
        local_x2apic: *align(1) const LocalX2Apic,
        local_x2apic_nmi: *align(1) const LocalX2ApicNmi,
        unknown: *const ControllerHeader,

        pub fn fromHeader(header: *const ControllerHeader) Controller {
            return switch (header._type) {
                .local_apic => .{ .local_apic = @ptrCast(header) },
                .io_apic => .{ .io_apic = @ptrCast(header) },
                .interrupt_source_override => .{ .interrupt_source_override = @ptrCast(header) },
                .nmi_source => .{ .nmi_source = @ptrCast(header) },
                .local_apic_nmi => .{ .local_apic_nmi = @ptrCast(header) },
                .local_apic_address_override => .{ .local_apic_address_override = @ptrCast(header) },
                .io_sapic => .{ .io_sapic = @ptrCast(header) },
                .local_sapic => .{ .local_sapic = @ptrCast(header) },
                .local_x2apic => .{ .local_x2apic = @ptrCast(header) },
                .local_x2apic_nmi => .{ .local_x2apic_nmi = @ptrCast(header) },
                else => .{ .unknown = header },
            };
        }
    };

    pub fn iterator(self: *const Madt) ControllerIterator {
        return .{ .madt = self };
    }

    fn controllerPtr(self: *const Madt, byte_offset: usize) *const ControllerHeader {
        std.debug.assert(byte_offset < self.controllersLenBytes());
        const controllers_data: [*]const u8 = @ptrCast(&self._controllers_data);
        const raw_ptr: *const u8 = &controllers_data[byte_offset];
        return @ptrCast(@alignCast(raw_ptr));
    }

    fn controllersLenBytes(self: *const Madt) usize {
        return self.header.length - @offsetOf(Madt, "_controllers_data");
    }

    pub const ControllerIterator = struct {
        madt: *const Madt,
        next_offset: usize = 0,

        pub fn next(self: *ControllerIterator) ?Controller {
            if (self.next_offset >= self.madt.controllersLenBytes()) return null;
            const header = self.madt.controllerPtr(self.next_offset);
            self.next_offset += header.length;
            return Controller.fromHeader(header);
        }
    };

    pub const LocalApic = extern struct {
        header: ControllerHeader,
        processor_uid: u8,
        id: u8,
        flags: LocalApicFlags,

        pub const LocalApicFlags = packed struct(u32) {
            enabled: bool,
            online_capable: bool,
            _reserved: u30 = 0,
        };
    };

    pub const IoApic = extern struct {
        header: ControllerHeader,
        id: u8,
        _reserved: u8 = 0,
        addr: u32,
        interrupt_base: u32,
    };

    // TODO: Move?
    pub const MpsIntiFlags = packed struct(u16) {
        polarity: Polarity,
        trigger_mode: TriggerMode,
        _reserved: u12 = 0,

        pub const Polarity = enum(u2) {
            bus_spec = 0,
            high = 1,
            _reserved = 2,
            low = 3,
        };

        pub const TriggerMode = enum(u2) {
            bus_spec = 0,
            edge = 1,
            _reserved = 2,
            level = 3,
        };
    };

    pub const InterruptSourceOverride = extern struct {
        header: ControllerHeader,
        bus: u8 = 0,
        source_irq: u8,
        gsi: u32,
        flags: MpsIntiFlags,
    };

    pub const NmiSource = extern struct {
        header: ControllerHeader,
        flags: MpsIntiFlags,
        gsi: u32,
    };

    pub const LocalApicNmi = extern struct {
        header: ControllerHeader,
        processor_uid: u8,
        flags: MpsIntiFlags align(1),
        lintn: u8,
    };

    pub const LocalApicAddressOverride = extern struct {
        header: ControllerHeader,
        _reserved: u16 = 0,
        addr: u64 align(4),
    };

    pub const IoSApic = extern struct {
        header: ControllerHeader,
        id: u8,
        _reserved: u8 = 0,
        interrupt_base: u32,
        addr: u64,
    };

    pub const LocalSApic = extern struct {
        header: ControllerHeader,
        processor_uid: u8,
        id: u8,
        eid: u8,
        _reserved: [3]u8 = .{ 0, 0, 0 },
        flags: LocalApic.LocalApicFlags,
        processor_uid_value: u32,
        _processor_uid_string_start: [1]u8,
    };

    pub const PlatformInterruptSource = extern struct {
        header: ControllerHeader,
        flags: MpsIntiFlags,
        interrupt_type: InterruptType,
        processor_id: u8,
        processor_eid: u8,
        io_sapic_vector: u8,
        gsi: u32,
        source_flags: SourceFlags,

        pub const InterruptType = enum(u8) {
            pmi = 1,
            init = 2,
            corrected_platform_error = 3,
            _,
        };

        pub const SourceFlags = packed struct(u32) {
            cpei_processor_override: bool,
            _reserved: u31 = 0,
        };
    };

    pub const LocalX2Apic = extern struct {
        header: ControllerHeader,
        _reserved: u16 = 0,
        id: u32,
        flags: LocalApic.LocalApicFlags,
        processor_uid: u32,
    };

    pub const LocalX2ApicNmi = extern struct {
        header: ControllerHeader,
        flags: MpsIntiFlags,
        processor_uid: u32,
        lintn: u8,
        _reserved: [3]u8 = .{ 0, 0, 0 },
    };
};
