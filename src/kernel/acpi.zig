const std = @import("std");

pub fn computeChecksum(bytes: []u8) u8 {
    var sum: u8 = 0;
    for (bytes) |b| sum +%= b;
    return sum;
}

pub fn computeChecksumSizeOf(fixed_sized_struct_ptr: *const anyopaque) u8 {
    return computeChecksum(std.mem.asBytes(fixed_sized_struct_ptr));
}

pub fn computeChecksumWithLength(dynamic_sized_struct_ptr: *const anyopaque, length: usize) u8 {
    const bytes_ptr: [*]u8 = @ptrCast(dynamic_sized_struct_ptr);
    return computeChecksum(bytes_ptr[0..length]);
}

pub const Rsdp = extern struct {
    pub const SIGNATURE = "RSD PTR ";

    signature: [8]u8,
    checksum: u8,
    oemid: [6]u8,
    revision: u8,
    rsdt_addr: u32,
    length: u32,

    xsdt_addr: u64,
    extended_checksum: u64,

    _reserved: [3]u8 = 0,

    const Self = @This();

    comptime {
        std.debug.assert(@offsetOf(Self, "length"), 20);
        std.debug.assert(@sizeOf(Self) == 36);
    }

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
        return std.mem.eql(u8, &self.signature, SIGNATURE);
    }

    pub fn versionValid(self: *const @This()) bool {
        return self.revision >= 2;
    }

    pub fn checksumValid(self: *const @This()) bool {
        const base = computeChecksumWithLength(self, 20);
        if (base != self.checksum) return false;
        const extended = computeChecksumWithLength(self, self.length);
        return extended == self.extended_checksum;
    }
};

pub const DescriptionHeader = extern struct {
    signature: [4]u8,
    length: u32,
    revision: u8,
    checksum: u8,
    oemid: [6]u8,
    oem_table_id: u64,
    oem_revision: u32,
    creator_id: u32,
    creator_revision: u32,

    pub fn valid(self: *const @This(), expected_signature: []u8) bool {
        return self.hasSignature(expected_signature) and self.checksumValid();
    }

    pub fn hasSignature(self: *const @This(), other: []const u8) bool {
        return std.mem.eql(u8, &self.signature, other);
    }

    pub fn checksumValid(self: *const @This()) bool {
        return computeChecksumWithLength(self, self.length) == self.checksum;
    }
};

pub const Rsdt = extern struct {
    pub const SIGNATURE = "RSDT";
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
    pub const SIGNATURE = "XSDT";
    header: DescriptionHeader,
    _entries: [0]u64,

    pub fn entries(self: *const @This()) []const *const DescriptionHeader {
        comptime std.debug.assert(@sizeOf(*anyopaque) == @sizeOf(@TypeOf(self._entries[0])));
        const raw_ptr: [*]const u8 = @ptrCast(&self._entries);
        const raw_len = self.header.length - @sizeOf(@This());
        return std.mem.bytesAsSlice(*const DescriptionHeader, raw_ptr[0..raw_len]);
    }
};

pub const Fadt = extern struct {
    pub const SIGNATURE = "FADT";
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
    pub const SIGNATURE = "DSDT";
    header: DescriptionHeader,
    _definition_block: [0]u8,
};

pub const Ssdt = extern struct {
    pub const SIGNATURE = "SSDT";
    header: DescriptionHeader,
    _definition_block: [0]u8,
};

pub const Madt = extern struct {
    pub const SIGNATURE = "MADT";

    header: DescriptionHeader,
    local_controller_addr: u32,
    flags: Flags,
    _controllers: [0]void,

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

    pub const Unknown = extern struct {
        _type: InterruptControllerType,
        length: u8,
    };

    pub const LocalApic = extern struct {
        _type: InterruptControllerType = .local_apic,
        length: u8 = @sizeOf(@This()),
        processor_uid: u8,
        id: u8,
        flags: LocalApicFlags,

        pub const LocalApicFlags = packed struct(u32) {
            enabled: bool,
            online_capable: bool,
            _reserved: u32 = 0,
        };
    };

    pub const IoApic = extern struct {
        _type: InterruptControllerType = .io_apic,
        length: u8 = @sizeOf(@This()),
        id: u8,
        _reserved: u1 = 0,
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
        _type: InterruptControllerType = .interrupt_source_override,
        length: u8 = @sizeOf(@This()),
        bus: u8 = 0,
        source_irq: u8,
        interrupt: u8,
        flags: MpsIntiFlags,
    };

    pub const NmiSource = extern struct {
        _type: InterruptControllerType = .nmi_source,
        length: u8 = @sizeOf(@This()),
        flags: MpsIntiFlags,
        interrupt: u32,
    };

    pub const LocalApicNmi = extern struct {
        _type: InterruptControllerType = .local_apic_nmi,
        length: u8 = @sizeOf(@This()),
        processor_uid: u8,
        flags: MpsIntiFlags,
        lintn: u8,

        comptime {
            std.debug.assert(@sizeOf(@This()) == 6);
        }
    };

    pub const LocalApicAddressOverride = extern struct {
        _type: InterruptControllerType = .local_apic_address_override,
        length: u8 = @sizeOf(@This()),
        _reserved: u16 = 0,
        addr: u64,
    };

    pub const IoSApic = extern struct {
        _type: InterruptControllerType = .io_sapic,
        length: u8 = @sizeOf(@This()),
        id: u8,
        _reserved: u8 = 0,
        interrupt_base: u32,
        addr: u64,
    };

    pub const LocalSApic = extern struct {
        _type: InterruptControllerType = .local_sapic,
        length: u8,
        processor_uid: u8,
        id: u8,
        eid: u8,
        _reserved: [3]u8 = .{ 0, 0, 0 },
        flags: LocalApic.LocalApicFlags,
        processor_uid_value: u32,
        _processor_uid_string_start: [1]u8,
    };

    pub const PlatformInterruptSource = extern struct {
        _type: InterruptControllerType = .platform_interrupt_source,
        length: u8 = @sizeOf(@This()),
        flags: MpsIntiFlags,
        interrupt_type: InterruptType,
        processor_uid: u8,
        id: u8,
        eid: u8,
        io_sapic_vector: u8,
        interrupt: u32,
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
        _type: InterruptControllerType = .local_x2apic,
        length: u8 = @sizeOf(@This()),
        _reserved: u16 = 0,
        id: u32,
        flags: LocalApic.LocalApicFlags,
        processor_uid: u32,
    };

    pub const LocalX2ApicNmi = extern struct {
        _type: InterruptControllerType = .local_x2apic_nmi,
        length: u8 = @sizeOf(@This()),
        flags: MpsIntiFlags,
        processor_uid: u32,
        lintn: u1,
        _reserved: [3]u8 = .{ 0, 0, 0 },
    };
};
