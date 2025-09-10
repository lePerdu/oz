const std = @import("std");

const port_io = @import("port_io.zig");

pub fn enableInterrupts() void {
    asm volatile ("sti");
}

pub fn disableInterrupts() void {
    asm volatile ("cli");
}

pub fn setInterrupts(enabled: bool) void {
    if (enabled) {
        enableInterrupts();
    } else {
        disableInterrupts();
    }
}

pub const DescriptorTableRegister = packed struct {
    limit: u16,
    base: u64,
};

pub fn getGdtr() DescriptorTableRegister {
    var reg: DescriptorTableRegister = undefined;
    asm ("sgdt %[reg]"
        : [reg] "=m" (reg),
    );
    return reg;
}

pub fn setGdtr(base: u64, limit: u16) void {
    var reg = DescriptorTableRegister{ .base = base, .limit = limit };
    asm volatile ("lgdt %[reg]"
        // Specifying `reg` as an input/output parameter is the only way I've found that generates the correct assembly
        // TODO: Figure out the "proper" way to specify this
        : [reg] "=&m" (reg),
    );
}

pub fn getIdtr() DescriptorTableRegister {
    var reg: DescriptorTableRegister = undefined;
    asm ("sidt %[reg]"
        : [reg] "=m" (reg),
    );
    return reg;
}

pub fn setIdtr(base: u64, limit: u16) void {
    var reg = DescriptorTableRegister{ .base = base, .limit = limit };
    asm volatile ("lidt %[reg]"
        // Specifying `reg` as an input/output parameter is the only way I've found that generates the correct assembly
        // TODO: Figure out the "proper" way to specify this
        : [reg] "=&m" (reg),
    );
}

pub const DataSegmentRegister = enum {
    ds,
    es,
    fs,
    gs,
    ss,

    pub fn name(self: @This()) []const u8 {
        return @tagName(self);
    }
};

pub fn setDataSegmentRegister(comptime reg: DataSegmentRegister, selector: SegmentSelector) void {
    asm volatile (std.fmt.comptimePrint("mov %[selector], %%{s}", .{reg.name()})
        :
        : [selector] "{ax}" (@as(u16, @bitCast(selector))),
        : .{ .memory = true });
}

extern fn _setCodeSegmentRegister(selector: u16) void;

pub fn setCodeSegmentRegister(selector: SegmentSelector) void {
    _setCodeSegmentRegister(@bitCast(selector));
}

pub const pic = struct {
    pub const MASTER_OFFSET = 0x20;
    pub const SLAVE_OFFSET = MASTER_OFFSET + 8;

    const MASTER_COMMAND_PORT = 0x20;
    const MASTER_DATA_PORT = 0x21;
    const SLAVE_COMMAND_PORT = 0xA0;
    const SLAVE_DATA_PORT = 0xA1;

    const EOI: u8 = 0x20;

    const out = port_io.outbComptimePort;
    const in = port_io.inbComptimePort;

    pub fn setMasterMask(mask: u8) void {
        out(MASTER_DATA_PORT, mask);
    }

    pub fn setSlaveMask(mask: u8) void {
        out(SLAVE_DATA_PORT, mask);
    }

    pub fn setMask(mask: u16) void {
        setMasterMask(@truncate(mask));
        setSlaveMask(@truncate(mask >> 8));
    }

    pub const EnableSet = packed struct(u16) {
        timer: bool = false,
        keyboard: bool = false,
        // This is enabled by default for convenience
        cascade: bool = true,
        com1: bool = false,
        com2: bool = false,
        lpt2: bool = false,
        floppy: bool = false,
        lpt1: bool = false,
        cmos_rtc: bool = false,
        free1: bool = false,
        free2: bool = false,
        free3: bool = false,
        mouse: bool = false,
        fpu: bool = false,
        primary_ata: bool = false,
        secondary_ata: bool = false,
    };

    pub fn setEnabled(mask: EnableSet) void {
        const enabled: u16 = @bitCast(mask);
        setMask(~enabled);
    }

    pub fn sendMasterEoi() void {
        out(MASTER_COMMAND_PORT, EOI);
    }

    pub fn sendSlaveEoi() void {
        out(SLAVE_COMMAND_PORT, EOI);
    }

    pub fn sendBothEoi() void {
        sendSlaveEoi();
        sendMasterEoi();
    }

    pub fn sedndEoi(irq: u4) void {
        if (irq >= 8) {
            sendSlaveEoi();
        }
        sendMasterEoi();
    }

    /// https://wiki.osdev.org/Inline_Assembly/Examples#IO_WAIT
    fn ioWait() void {
        out(0x80, 0);
    }

    /// Configure and map the PIC controllers
    /// Leaves all interrupts masked
    /// https://wiki.osdev.org/8259_PIC#Initialisation
    pub fn configure() void {
        // TODO: Figure out what all these other flags do
        const ICW1_ICW4 = 0x01;
        // const ICW1_SINGLE = 0x02;
        // const ICW1_INTERVAL4 = 0x04;
        // const ICW1_LEVEL = 0x08;
        const ICW1_INIT = 0x10;

        const ICW4_8086 = 0x10;
        // const ICW4_AUTO = 0x02;
        // const ICW4_BUF_SLAVE = 0x08;
        // const ICW4_BUF_MASTER = 0x0C;
        // const ICW4_SFNM = 0x10;

        const CASCADE_IRQ = 2;

        // Disable before configuring
        setMask(0xFFFF);

        out(MASTER_COMMAND_PORT, ICW1_INIT | ICW1_ICW4);
        ioWait();
        out(SLAVE_COMMAND_PORT, ICW1_INIT | ICW1_ICW4);
        ioWait();
        out(MASTER_DATA_PORT, MASTER_OFFSET);
        ioWait();
        out(SLAVE_DATA_PORT, SLAVE_OFFSET);
        ioWait();
        out(MASTER_DATA_PORT, 1 << CASCADE_IRQ);
        ioWait();
        out(SLAVE_DATA_PORT, CASCADE_IRQ);
        ioWait();

        out(MASTER_DATA_PORT, ICW4_8086);
        ioWait();
        out(SLAVE_DATA_PORT, ICW4_8086);
        ioWait();
    }
};

pub fn nmiEnable() void {
    port_io.outbComptimePort(0x70, port_io.inbComptimePort(0x70) & 0x7F);
    _ = port_io.inbComptimePort(0x71);
}

pub fn nmiDisable() void {
    port_io.outbComptimePort(0x70, port_io.inbComptimePort(0x70) | 0x80);
    _ = port_io.inbComptimePort(0x71);
}

pub const InterruptFrame = extern struct {
    ip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

pub const SegmentDescriptor = packed struct(u64) {
    _limit0: u16,
    _base0: u24,
    access_byte: u8,
    _limit16: u4,
    flags: SegmentFlags,
    _base24: u8,

    const Self = @This();

    pub const null_descriptor = std.mem.zeroes(Self);

    pub fn initData(base: u32, limit: u20, access: SegmentDataAccess, flags: SegmentFlags) Self {
        return .{
            ._base0 = @truncate(base),
            ._base24 = @truncate(base >> 24),
            ._limit0 = @truncate(limit),
            ._limit16 = @truncate(limit >> 16),
            .access_byte = @bitCast(access),
            .flags = flags,
        };
    }

    pub fn initCode(base: u32, limit: u20, access: SegmentCodeAccess, flags: SegmentFlags) Self {
        return .{
            ._base0 = @truncate(base),
            ._base24 = @truncate(base >> 24),
            ._limit0 = @truncate(limit),
            ._limit16 = @truncate(limit >> 16),
            .access_byte = @bitCast(access),
            .flags = flags,
        };
    }

    pub fn getBase(self: Self) u32 {
        return @as(u32, self._base0) | (@as(u32, self._base_16) << 16) | (@as(u32, self._base24) << 24);
    }

    pub fn getLimit(self: Self) u20 {
        return @as(u20, self._limit0) | (@as(u20, self._limit16) << 16);
    }

    comptime {
        std.debug.assert(@alignOf(Self) == 8);
    }
};

pub const LongModeSegmentDescriptor = extern struct {
    inner: SegmentDescriptor,
    _base32: u32,
    _reserved: u32 = 0,

    const Self = @This();

    pub fn init(base: u64, limit: u20, access: SegmentSystemAccess, flags: SegmentFlags) Self {
        return .{
            .inner = .{
                ._base0 = @truncate(base),
                ._base24 = @truncate(base >> 24),
                ._limit0 = @truncate(limit),
                ._limit16 = @truncate(limit >> 16),
                .access_byte = @bitCast(access),
                .flags = flags,
            },
            ._base32 = @truncate(base >> 32),
        };
    }

    pub fn getBase(self: Self) u64 {
        return @as(u64, self.inner.getBase()) | (@as(u64, self._base_32) << 32);
    }

    pub fn getLimit(self: Self) u20 {
        return self.inner.getLimit();
    }

    comptime {
        std.debug.assert(@sizeOf(Self) == 16);
        std.debug.assert(@alignOf(Self) == 8);
    }
};

// TODO: Split SegmentAccess into 2 structs for code/data segments since the meaning of some fields changes?
pub const SegmentCodeAccess = packed struct(u8) {
    accesssed: bool = false,
    readable: bool,
    allow_lower: bool,
    executable: bool = true,
    type: SegmentType = .code_data,
    privilege_level: PrivilegeLevel,
    present: bool = true,
};

pub const SegmentDataAccess = packed struct(u8) {
    accesssed: bool = false,
    writeable: bool,
    direction: Direction = .up,
    executable: bool = false,
    type: SegmentType = .code_data,
    privilege_level: PrivilegeLevel,
    present: bool = true,
};

pub const SegmentSystemAccess = packed struct(u8) {
    system_type: SystemSegmentType,
    type: SegmentType = .system,
    privilege_level: PrivilegeLevel,
    present: bool = true,
};

pub const SystemSegmentType = enum(u4) {
    // tss_16_available = 0x1,
    ldt = 0x2,
    // tss_16_busy = 0x3,
    // tss_32_available = 0x9,
    // tss_32_busy = 0xB,
    tss_64_available = 0x9,
    tss_64_busy = 0xB,
};

pub const PrivilegeLevel = u2;

pub const SegmentType = enum(u1) {
    system = 0,
    code_data = 1,
};

pub const Direction = enum(u1) {
    up = 0,
    down = 1,
};

pub const SegmentFlags = packed struct(u4) {
    _reserverd: u1 = 0,
    long_mode: bool,
    protected_mode_32_bit: bool,
    granularity: Granularity,
};

pub const Granularity = enum(u1) {
    bytes = 0,
    pages = 1,
};

pub const TaskStateSegment = extern struct {
    _reserved0: u32 align(4) = 0,
    rsp0: u64 align(4),
    rsp1: u64 align(4),
    rsp2: u64 align(4),
    _reserved1: u64 align(4) = 0,
    ist1: u64 align(4),
    ist2: u64 align(4),
    ist3: u64 align(4),
    ist4: u64 align(4),
    ist5: u64 align(4),
    ist6: u64 align(4),
    ist7: u64 align(4),
    _reserved2: u64 align(4) = 0,
    _reserved3: u16 align(2) = 0,
    iopb: u16 align(2),

    comptime {
        std.debug.assert(@sizeOf(@This()) == 0x68);
        std.debug.assert(@alignOf(@This()) == 4);
    }
};

pub const InterruptDescriptorTable = [256]InterruptDescriptor;

pub const InterruptDescriptor = packed struct(u128) {
    _offset0: u16,
    selector: SegmentSelector,
    ist: u3,
    _reserved0: u5 = 0,
    gate_type: GateType,
    _reserved1: u1 = 0,
    privilege_level: PrivilegeLevel,
    present: bool = true,
    _offset16: u48,
    _reserved2: u32 = 0,

    const Self = @This();

    pub fn init(offset: u64, selector: SegmentSelector, ist: u3, gate_type: GateType, level: PrivilegeLevel) Self {
        return .{
            ._offset0 = @truncate(offset),
            .selector = selector,
            .ist = ist,
            .gate_type = gate_type,
            .privilege_level = level,
            ._offset16 = @truncate(offset >> 16),
        };
    }
};

pub const SegmentSelector = packed struct(u16) {
    privilege_level: PrivilegeLevel,
    table: TableSelector,
    /// Index into GDT
    index: u13,
};

pub const TableSelector = enum(u1) {
    gdt = 0,
    ldt = 1,
};

pub const GateType = enum(u4) {
    int = 0xE,
    trap = 0xF,
};
