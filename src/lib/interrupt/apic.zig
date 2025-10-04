const std = @import("std");

// TOOD: Move these
pub inline fn getMsr(addr: u32) u64 {
    var high: u32 = undefined;
    var low: u32 = undefined;
    asm ("rdmsr"
        : [high] "{edx}" (high),
          [low] "{eax}" (low),
        : [addr] "{ecx}" (addr),
    );
    return @as(u64, high) << 32 | low;
}

pub inline fn setMsr(addr: u32, value: u64) void {
    const high: u32 = @truncate(value >> 32);
    const low: u32 = @truncate(value);
    asm volatile ("wrmsr"
        :
        : [addr] "{ecx}" (addr),
          [high] "{edx}" (high),
          [low] "{eax}" (low),
    );
}

fn checkMsrType(comptime T: type) void {
    // TODO: Support 32-bit types, just ignoring the upper word
    if (@sizeOf(T) != 64) {
        @compileError(std.fmt.comptimePrint("getTypedMsr({}): invalid size: {}", .{ T, @sizeOf(T) }));
    }
    if (!@hasDecl(T, "addr")) {
        @compileError(std.fmt.comptimePrint("getTypedMsr({}): must have `addr` decl", .{T}));
    }
    if (std.math.cast(u32, T.addr) == null) {
        @compileError(std.fmt.comptimePrint("getTypedMsr({}): `addr` decl must be u32", .{T}));
    }
}

pub inline fn getTypedMsr(comptime T: type) T {
    checkMsrType(T);
    return @bitCast(getMsr(T.addr));
}

pub inline fn setTypedMsr(value: anytype) void {
    const T = @TypeOf(value);
    checkMsrType(T);
    // TODO: Support enums as well?
    setMsr(T.addr, @bitCast(value));
}

pub const ApicBaseMsr = packed struct(u64) {
    pub const addr = 0x1B;

    _reserved1: u8,
    bsp: bool,
    _reserved2: u2,
    global_enable: bool,
    base_addr: u24,
    _reserved3: u28,
};

// TODO: Function to check presence

pub inline fn isBsp() bool {
    return getTypedMsr(ApicBaseMsr).bsp;
}

pub inline fn globalEnabled() bool {
    return getTypedMsr(ApicBaseMsr).global_enable;
}

pub inline fn setGlobalEnable(enable: bool) void {
    var apic_base = getTypedMsr(ApicBaseMsr);
    apic_base.global_enable = enable;
    setTypedMsr(apic_base);
}

/// Delivery mode shared between Local anad I/O APIC registers
pub const DeliveryMode = enum(u3) {
    fixed = 0b000,
    low_prio = 0b001,
    smi = 0b010,
    _reserved = 0b011,
    nmi = 0b100,
    init = 0b101,
    startup = 0b110,
    ext_init = 0b111,
};

pub const Local = extern struct {
    /// All accesses must be done on 128-bit-aligned 32-bit words.
    /// Using an array instead of individual fields makes this explicit to the compiler
    cells: [0x40]Cell,
    const Cell = extern struct {
        v: u32 align(16),
    };

    pub const Register = enum(usize) {
        // 020h  LAPIC ID Register  Read/Write
        id = 0x20,
        // 030h  LAPIC Version Register  Read only
        version = 0x30,
        // 040h - 070h  Reserved
        // 080h  Task Priority Register (TPR)  Read/Write
        tpr = 0x80,
        // 090h  Arbitration Priority Register (APR)  Read only
        // 0A0h  Processor Priority Register (PPR)  Read only
        // 0B0h  EOI register  Write only
        eoi = 0xB0,
        // 0C0h  Remote Read Register (RRD)  Read only
        // 0D0h  Logical Destination Register  Read/Write
        local_dest = 0xD0,
        // 0E0h  Destination Format Register  Read/Write
        dest_fmt = 0xE0,
        // 0F0h  Spurious Interrupt Vector Register  Read/Write
        spurious = 0xF0,
        // 100h - 170h  In-Service Register (ISR)  Read only
        // 180h - 1F0h  Trigger Mode Register (TMR)  Read only
        // 200h - 270h  Interrupt Request Register (IRR)  Read only
        // 280h  Error Status Register  Read only
        err = 0x280,
        // 290h - 2E0h  Reserved
        // 2F0h  LVT Corrected Machine Check Interrupt (CMCI) Register  Read/Write
        // 300h - 310h  Interrupt Command Register (ICR)  Read/Write
        icr_command = 0x300,
        icr_target = 0x310,
        // 320h  LVT Timer Register  Read/Write
        lvt_timer = 0x320,
        // 330h  LVT Thermal Sensor Register  Read/Write
        lvt_thermal = 0x330,
        // 340h  LVT Performance Monitoring Counters Register  Read/Write
        lvt_perf_counters = 0x340,
        // 350h  LVT LINT0 Register  Read/Write
        lvt_lint0 = 0x350,
        // 360h  LVT LINT1 Register  Read/Write
        lvt_lint1 = 0x360,
        // 370h  LVT Error Register  Read/Write
        lvt_err = 0x370,
        // 380h  Initial Count Register (for Timer)  Read/Write
        lvt_timer_initial = 0x380,
        // 390h  Current Count Register (for Timer)  Read only
        lvt_timer_current = 0x390,
        // 3A0h - 3D0h  Reserved
        // 3E0h  Divide Configuration Register (for Timer)  Read/Write
        timer_divide = 0x3E0,
        // 3F0h  Reserved
    };

    pub const Id = packed struct(u32) {
        _reserved: u24,
        id: u8,
    };
    pub const Version = packed struct(u32) {
        version: u8,
        _reserved1: u8,
        max_lvt_entry: u7,
        eoi_broadcast_suppression: bool,
        _reserved2: u8,

        pub fn isDiscrete(self: Version) bool {
            return self.version < 0x10;
        }
    };
    pub const SpuriousVector = packed struct(u32) {
        vector: u8,
        enable: bool,
        focus_processor_checking_disabled: bool = false,
        _reserved1: u2 = 0,
        eoi_broadcast_suppressed: bool = false,
        _reserved2: u19 = 0,
    };
    pub const ErrorStatus = packed struct(u32) {
        send_checksum_err: bool,
        receive_checksum_err: bool,
        send_accept_err: bool,
        receive_accept_err: bool,
        redirectable_ipi: bool,
        send_illegal_vector: bool,
        receive_illegal_vector: bool,
        illegal_register_addr: bool,
        _reserved: u24,
    };

    pub const Destination = packed struct(u32) {
        _reserved1: u24 = 0,
        target: u8,
    };
    pub const DestinationFormat = packed struct(u32) {
        _reserved: u28 = std.math.maxInt(u28),
        model: Model,

        pub const Model = enum(u4) {
            cluster = 0b0000,
            flat = 0b1111,
            _,
        };
    };
    pub const IcrDestination = Destination;
    pub const IcrCommand = packed struct(u32) {
        vector: u8,
        delivery_mode: DeliveryMode,
        destination_logical: bool = false,
        pending: bool = false,
        _reserved1: u1 = 0,
        level_assert: bool = true,
        level_triggered: bool = false,
        _reserved2: u2 = 0,
        destination_shorthand: DestinationShorthand = .none,
        _reserved3: u12 = 0,
    };
    pub const DestinationShorthand = enum(u2) {
        none = 0b00,
        self = 0b01,
        all = 0b10,
        all_others = 0b11,
    };

    pub const LvtReg = packed struct(u32) {
        vector: u8,
        delivery_mode: DeliveryMode,
        _reserved1: u1 = 0,
        pending: bool = 0,
        active_low: bool = false,
        remote_irr: bool = false,
        level_triggered: bool = false,
        masked: bool = false,
        timer_mode: TimerMode = .one_shot,
        _reserved2: u13 = 0,
    };
    pub const TimerMode = enum(u2) {
        one_shot = 0b00,
        periodic = 0b01,
        tsc = 0b10,
        _reserved = 0b11,
    };

    pub const DivideReg = packed struct(u32) {
        value: DivideValue,
        _reserved: u28 = 0,
    };
    pub const DivideValue = enum(u4) {
        div2 = 0b0000,
        div4 = 0b0001,
        div8 = 0b0010,
        div16 = 0b0011,
        div32 = 0b1000,
        div64 = 0b1001,
        div128 = 0b1010,
        div1 = 0b1011,
    };

    const Self = @This();
    const ReadOnly = *const volatile Self;
    const ReadWrite = *volatile Self;

    pub fn getRaw(self: ReadOnly, reg: Register) u32 {
        return self.cells[@intFromEnum(reg) / @sizeOf(Cell)].v;
    }

    //TODO: Some type magic to auto-cast based on the register
    pub fn get(self: ReadOnly, reg: Register, comptime T: type) T {
        const raw = self.getRaw(reg);
        return switch (@typeInfo(T)) {
            .int => raw,
            .@"struct" => @bitCast(raw),
            else => @compileError(std.fmt.comptimePrint("get: invalid APIC register type: {}", .{T})),
        };
    }

    pub fn set(self: ReadWrite, reg: Register, val: anytype) void {
        const raw: u32 = switch (@typeInfo(@TypeOf(val))) {
            .int, .comptime_int => val,
            .@"struct" => @bitCast(val),
            else => @compileError(std.fmt.comptimePrint("set: invalid APIC register type: {}", .{@TypeOf(val)})),
        };
        self.setRaw(reg, raw);
    }

    pub fn setRaw(self: ReadWrite, reg: Register, val: u32) void {
        self.cells[@intFromEnum(reg) / @sizeOf(Cell)].v = val;
    }

    pub fn getId(self: ReadOnly) u8 {
        return self.get(.id, Id).id;
    }

    pub fn getVersion(self: ReadOnly) Version {
        return self.get(.version, Version);
    }

    pub fn enable(self: ReadWrite) void {
        var reg = self.get(.spurious, SpuriousVector);
        reg.enable = true;
        self.set(.spurious, reg);
    }

    pub fn sendEoi(self: ReadWrite) void {
        self.set(.eoi, 0);
    }

    pub fn sendIpi(self: ReadWrite, target: u8, command: IcrCommand) void {
        self.set(.icr_target, IcrDestination{ .target = target });
        self.set(.icr_command, command);
    }

    pub const ipi_delivery_timeout_us = 20;

    pub fn ipiPending(self: ReadOnly) bool {
        return self.get(.icr_command, IcrCommand).pending;
    }

    pub fn getErrorStatus(self: ReadOnly) ErrorStatus {
        return self.get(.err, ErrorStatus);
    }

    comptime {
        if (@sizeOf(@This()) != 0x400)
            @compileError(std.fmt.comptimePrint("LocalApic: invalid size: {}", .{@sizeOf(@This())}));
    }
};

pub const Io = extern struct {
    select: Select align(16),
    window: u32 align(16),

    pub const Select = packed struct(u32) {
        reg: u8,
        _reserved: u24 = 0,
    };

    pub const Id = packed struct(u32) {
        _reserved1: u24,
        id: u4,
        _reserved2: u4,
    };
    pub const Version = packed struct(u32) {
        version: u8,
        _reserved1: u8,
        max_rediection_entry: u8,
        _reserved: u8,
    };
    pub const RedirectionEntry = packed struct(u64) {
        vector: u8,
        delivery_mode: DeliveryMode,
        destination_logical: bool = false,
        pending: bool = false,
        active_low: bool = false,
        remote_irr: bool = false,
        level_trigerred: bool = false,
        masked: bool = false,
        _reserved: u39 = 0,
        destination: u8,
    };

    const ReadOnly = *const volatile @This();
    const ReadWrite = *volatile @This();

    pub fn getRaw(self: ReadOnly, reg: u8) u32 {
        self.select = .{ .reg = reg };
        return self.window;
    }

    pub fn setRaw(self: ReadWrite, reg: u8, val: u32) void {
        self.select = .{ .reg = reg };
        self.window = val;
    }

    const reg_id = 0x00;
    const reg_version = 0x01;
    const reg_arb = 0x02;
    const redir_table_base = 0x10;

    pub fn getId(self: ReadOnly) u4 {
        const reg: Id = @bitCast(self.getRaw(reg_id));
        return reg.id;
    }

    pub fn getVersion(self: ReadOnly) Version {
        const reg: Version = @bitCast(self.getRaw(reg_version));
        return reg;
    }

    pub fn getArb(self: ReadOnly) u32 {
        return self.getRaw(reg_arb);
    }

    /// index must be in 0..version.max_redirection_entries
    pub fn getRedirectionEntry(self: ReadWrite, index: u8) RedirectionEntry {
        const low = self.getRaw(redir_table_base + 2 * index);
        const high = self.getRaw(redir_table_base + 2 * index + 1);
        return @bitCast(@as(u64, high) << 32 | low);
    }

    /// index must be in 0..version.max_redirection_entries
    pub fn setRedirectionEntry(self: ReadWrite, index: u8, entry: RedirectionEntry) void {
        const entry_bits: u64 = @bitCast(entry);
        self.setRaw(redir_table_base + 2 * index, @truncate(entry_bits));
        self.setRaw(redir_table_base + 2 * index + 1, @truncate(entry_bits >> 32));
    }
};
