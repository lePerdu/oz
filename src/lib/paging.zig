const std = @import("std");

// TODO: Pull from std.options, std.mem, std.heap, etc.
pub const page_offset_bits = 12;
pub const page_size = 1 << page_offset_bits;
pub const page_alignment = std.mem.Alignment.fromByteUnits(page_size);

/// Type alias used for indicating that an address that may not be mapped in the
/// current address space. Normally, these addresses can't be directly
/// dereferenced, so the type is not defined as a pointer.
pub const Address = u64;
/// Type alias indicating that an address is interpreted as physical
pub const PhysicalAddress = Address;
/// Type alias indicating that an address is interpreted as virtual
pub const VirtualAddress = Address;
pub const PageNum = u28;
pub const PageTableIndex = u12;

pub const PageTable = extern struct {
    pub const ENTRY_COUNT = 512;

    entries: [ENTRY_COUNT]PageTableEntry align(page_size),

    const Self = @This();

    comptime {
        std.debug.assert(@alignOf(Self) == page_size);
        std.debug.assert(@sizeOf(Self) == page_size);
    }

    pub fn clear(self: *Self) void {
        @memset(&self.entries, PageTableEntry.EMPTY);
    }

    pub fn setupRecursiveMap(self: *Self, page_num: PageNum) void {
        // TODO: global? execute_disable?
        self.entries[ENTRY_COUNT - 1] = PageTableEntry.init(page_num, .{ .writable = true });
    }
};

// TODO: Separate structs for PML4, PDPT, and PD entries since some fields
// are not used in those tables?
pub const PageTableEntry = packed struct {
    present: bool,
    writable: bool,
    user_access: bool,
    write_through: bool,
    cache_disabled: bool,
    accessed: bool = false,
    dirty: bool = false,
    huge_page: bool = false,
    global: bool,
    available_2: u3 = undefined,
    physical_page_number: PageNum,
    reserved: u12 = 0,
    available_1: u11 = undefined,
    execute_disabled: bool,

    /// Page table entry that is "empty", i.e. not present
    /// This is conveniently just all zeros
    pub const EMPTY = std.mem.zeroes(Self);

    const Self = @This();

    /// Initialize with some sane defaults, overridable via `flags`.
    /// .present and .physical_page_number are set regardless of `flags`.
    pub fn init(page_num: PageNum, flags: anytype) Self {
        var ent = std.mem.zeroInit(Self, flags);
        ent.present = true;
        ent.physical_page_number = page_num;
        return ent;
    }

    pub fn withPageNum(self: Self, page_num: PageNum) Self {
        var ent = self;
        ent.physical_page_number = page_num;
        return ent;
    }

    pub inline fn physicalAddress(self: Self) PhysicalAddress {
        // TODO: Verify that this compiles to a bitmask
        return pageNumToAddress(self.physical_page_number);
    }

    pub inline fn physicalPtr(self: Self) *align(page_size) anyopaque {
        return @alignCast(@as(*anyopaque, @ptrFromInt(self.physicalAddress())));
    }

    pub inline fn physicalPtrAs(self: Self, comptime T: type) *align(page_size) T {
        return @ptrCast(self.physicalPtr());
    }

    /// Set the physical address bits, verifying that the address is properly aligned
    pub inline fn setPhysicalAddress(self: *Self, address: PhysicalAddress) void {
        self.physical_page_number = addressToPageNum(address);
    }

    comptime {
        std.debug.assert(@bitSizeOf(Self) == 64);
        std.debug.assert(@bitOffsetOf(Self, "physical_page_number") == 12);

        std.debug.assert(!EMPTY.present);
    }
};

pub fn getRootPageTable() PhysicalAddress {
    const cr3 = asm ("mov %cr3, %[ret]"
        : [ret] "=r" (-> PhysicalAddress),
    );
    return cr3;
}

pub fn setRootPageTable(addr: PhysicalAddress) void {
    asm volatile ("mov %[addr], %cr3"
        :
        : [addr] "r" (addr),
        : .{ .memory = true });
}

pub inline fn invalidatePage(comptime addr: *anyopaque) void {
    asm volatile ("invlpg (%[addr])"
        :
        : [addr] "r" (addr),
        : .{ .memory = true });
}

pub fn build4KVirtAddr(pml4_index: usize, pdpt_index: usize, pd_index: usize, pt_index: usize) VirtualAddress {
    // TODO: Use u12 to avoid asserts here?
    std.debug.assert(pml4_index < 512);
    std.debug.assert(pdpt_index < 512);
    std.debug.assert(pd_index < 512);
    std.debug.assert(pt_index < 512);
    const addr: u64 = @intCast(((((((pml4_index << 9) + pdpt_index) << 9) + pd_index) << 9) + pt_index) << 12);
    return addCanonicalUpperBits(addr);
}

test build4KVirtAddr {
    try std.testing.expectEqual(0, build4KVirtAddr(0, 0, 0, 0));
    try std.testing.expectEqual(0x1000, build4KVirtAddr(0, 0, 0, 1));
    try std.testing.expectEqual(0x0000_3AE8_3DD1_C000, build4KVirtAddr(117, 416, 494, 284));
    try std.testing.expectEqual(0xFFFF_FFFF_8000_0000, build4KVirtAddr(511, 510, 0, 0));
    try std.testing.expectEqual(0xFFFF_FFFF_FFFF_F000, build4KVirtAddr(511, 511, 511, 511));
}

pub fn build2MVirtAddr(pml4_index: usize, pdpt_index: usize, pd_index: usize) VirtualAddress {
    return build4KVirtAddr(pml4_index, pdpt_index, pd_index, 0);
}

pub fn build1GVirtAddr(pml4_index: usize, pdpt_index: usize) VirtualAddress {
    return build4KVirtAddr(pml4_index, pdpt_index, 0, 0);
}

pub fn pagesRequired(bytes: usize) usize {
    return std.math.divCeil(usize, bytes, page_size) catch unreachable;
}

pub fn pageEntriesRequired(subpage_count: usize) usize {
    return std.math.divCeil(usize, subpage_count, 512) catch unreachable;
}

const table_index_bits = 9;
const table_index_mask = (1 << table_index_bits) - 1;

const page_offset_mask = (1 << page_offset_bits) - 1;

const canonical_upper_bit_mask: usize = 0xFFFF_8000_0000_0000;

pub fn addressIsCanonical(address: Address) bool {
    const upper_bits = address & canonical_upper_bit_mask;
    return upper_bits == 0 or upper_bits == canonical_upper_bit_mask;
}

test addressIsCanonical {
    try std.testing.expect(addressIsCanonical(0xFFFF_8000_F00D_F00D));
    try std.testing.expect(addressIsCanonical(0x0000_0000_DEAD_BEEF));
    try std.testing.expect(!addressIsCanonical(0xFAFF_8000_1234_5678));
}

pub fn assertCanonical(address: Address) void {
    if (!addressIsCanonical(address)) {
        std.debug.panic("non-canonical address: 0x{x:016}", .{address});
    }
}

fn stripUpperBits(address: Address) u64 {
    assertCanonical(address);
    return address & 0xFFFF_FFFF_FFFF;
}

pub fn addCanonicalUpperBits(addr: u64) Address {
    if (addr < 0x0000_8000_0000_0000) {
        return addr;
    } else {
        return canonical_upper_bit_mask | addr;
    }
}

pub inline fn pageNumToAddress(page_num: PageNum) PhysicalAddress {
    return @as(u64, page_num) << page_offset_bits;
}

test pageNumToAddress {
    try std.testing.expectEqual(0, pageNumToAddress(0));
    try std.testing.expectEqual(0x1000, pageNumToAddress(1));
    try std.testing.expectEqual(0xFF_FFFF_F000, pageNumToAddress(std.math.maxInt(PageNum)));
}

pub inline fn pageNumToPtr(comptime T: type, page_num: PageNum) *align(4096) T {
    return @ptrFromInt(pageNumToAddress(page_num));
}

pub inline fn addressToPageNum(address: PhysicalAddress) PageNum {
    // TODO: Return error instead?
    std.debug.assert(std.mem.isAligned(address, page_size));
    const real_addr = stripUpperBits(address);
    // Mask out upper bits since they are ignored not included in the page number
    // TODO: This can easily fail if an invalid address is given
    return @intCast(real_addr >> page_offset_bits);
}

test addressToPageNum {
    try std.testing.expectEqual(0, addressToPageNum(0));
    try std.testing.expectEqual(1, addressToPageNum(0x1000));
    try std.testing.expectEqual(24680, addressToPageNum(0x6068000));
    try std.testing.expectEqual(std.math.maxInt(PageNum), addressToPageNum(0xFF_FFFF_F000));
}

pub inline fn pointerToPageNum(ptr: *const anyopaque) PageNum {
    return addressToPageNum(@intFromPtr(ptr));
}

pub fn getPml4Index(addr: VirtualAddress) usize {
    assertCanonical(addr);
    return (addr >> (page_offset_bits + table_index_bits * 3)) & table_index_mask;
}

test getPml4Index {
    try std.testing.expectEqual(36, getPml4Index(0x1234_5678_ABCD));
}

pub fn getPdptIndex(addr: VirtualAddress) usize {
    assertCanonical(addr);
    return (addr >> (page_offset_bits + table_index_bits * 2)) & table_index_mask;
}

test getPdptIndex {
    try std.testing.expectEqual(209, getPdptIndex(0x1234_5678_ABCD));
}

pub fn getPdIndex(addr: VirtualAddress) usize {
    assertCanonical(addr);
    return (addr >> (page_offset_bits + table_index_bits)) & table_index_mask;
}

test getPdIndex {
    try std.testing.expectEqual(179, getPdIndex(0x1234_5678_ABCD));
}

pub fn getPtIndex(addr: VirtualAddress) usize {
    assertCanonical(addr);
    return (addr >> page_offset_bits) & table_index_mask;
}

test getPtIndex {
    try std.testing.expectEqual(394, getPtIndex(0x1234_5678_ABCD));
}

pub fn getPageOffset(addr: VirtualAddress) usize {
    assertCanonical(addr);
    return addr & page_offset_mask;
}

test getPageOffset {
    try std.testing.expectEqual(0xBCD, getPageOffset(0x1234_5678_ABCD));
}

pub const PageMappingSize = enum {
    size_4k,
    size_2m,
    size_1g,
};

pub const PageMapping = struct {
    entry: *PageTableEntry,
    virtual_addr: VirtualAddress,
    size: PageMappingSize,
};

pub const PageLevel = enum { pml4, pdpt, pd, pt };

pub const PageTableVisitor = fn (context: *anyopaque, level: PageLevel, table: *PageTable) error{Break}!void;

pub fn visitPageTables(pml4: *PageTable, context: *anyopaque, visit: PageTableVisitor) void {
    visit(context, .pml4, pml4) catch return;
    for (0..512) |pml4_index| {
        if (!pml4.entries[pml4_index].present) {
            continue;
        }

        const pdpt = pml4.entries[pml4_index].physicalPtrAs(PageTable);
        visit(context, .pdpt, pdpt) catch return;
        for (0..512) |pdpt_index| {
            if (!pdpt.entries[pdpt_index].present or pdpt.entries[pdpt_index].huge_page) {
                continue;
            }

            const pd = pdpt.entries[pdpt_index].physicalPtrAs(PageTable);
            visit(context, .pd, pd) catch return;
            for (0..512) |pd_index| {
                if (!pd.entries[pd_index].present or pd.entries[pd_index].huge_page) {
                    continue;
                }
                const pt = pd.entries[pd_index].physicalPtrAs(PageTable);
                visit(context, .pt, pt) catch return;
            }
        }
    }
}

/// Iterator over all present page mappings in a specified region of virtual
/// address space
///
/// Preconditions:
/// - Memory containing page tables is identity-mapped
/// TODO: Allow some other scheme, like offset-mapping, or accept a page->addr function
pub const PageMappingIterator = struct {
    pml4: *PageTable,
    pml4_index: usize,
    pdpt_index: usize,
    pd_index: usize,
    pt_index: usize,
    end_addr: VirtualAddress,

    const Self = @This();

    pub fn init(pml4: *PageTable, start: VirtualAddress, end: VirtualAddress) Self {
        return Self{
            .pml4 = pml4,
            .pml4_index = getPml4Index(start),
            .pdpt_index = getPdptIndex(start),
            .pd_index = getPdIndex(start),
            .pt_index = getPtIndex(start),
            .end_addr = end,
        };
    }

    pub fn next(self: *Self) ?PageMapping {
        const pml4_end = @min(getPml4Index(self.end_addr) + 1, 512);
        while (self.pml4_index < pml4_end) : (self.pml4_index += 1) {
            const pml4_ent = &self.pml4.entries[self.pml4_index];
            if (!pml4_ent.present) {
                continue;
            }

            const pdpt = pml4_ent.physicalPtrAs(PageTable);
            const pdpt_end = @min(getPdptIndex(self.end_addr) + 1, 512);
            while (self.pdpt_index < pdpt_end) : (self.pdpt_index += 1) {
                const pdpt_ent = &pdpt.entries[self.pdpt_index];
                if (!pdpt_ent.present) {
                    continue;
                }
                if (pdpt_ent.huge_page) {
                    const res = PageMapping{
                        .entry = pdpt_ent,
                        .virtual_addr = build1GVirtAddr(self.pml4_index, self.pdpt_index),
                        .size = .size_1g,
                    };
                    self.pdpt_index += 1;
                    return res;
                }

                const pd = pdpt.entries[self.pdpt_index].physicalPtrAs(PageTable);
                const pd_end = @min(getPdIndex(self.end_addr) + 1, 512);
                while (self.pd_index < pd_end) : (self.pd_index += 1) {
                    const pd_ent = &pd.entries[self.pd_index];
                    if (!pd_ent.present) {
                        continue;
                    }
                    if (pd_ent.huge_page) {
                        const res = PageMapping{
                            .entry = pd_ent,
                            .virtual_addr = build2MVirtAddr(self.pml4_index, self.pdpt_index, self.pd_index),
                            .size = .size_2m,
                        };
                        self.pd_index += 1;
                        return res;
                    }

                    const pt = pd.entries[self.pd_index].physicalPtrAs(PageTable);
                    const pt_end = @min(getPtIndex(self.end_addr) + 1, 512);
                    while (self.pt_index < pt_end) : (self.pt_index += 1) {
                        const pt_ent = &pt.entries[self.pt_index];
                        if (!pt_ent.present) {
                            continue;
                        }
                        const res = PageMapping{
                            .entry = pt_ent,
                            .virtual_addr = build4KVirtAddr(
                                self.pml4_index,
                                self.pdpt_index,
                                self.pd_index,
                                self.pt_index,
                            ),
                            .size = .size_4k,
                        };
                        self.pt_index += 1;
                        return res;
                    }
                    self.pt_index = 0;
                }
                self.pd_index = 0;
            }
            self.pdpt_index = 0;
        }

        return null;
    }
};

pub const AddressResolver = struct {
    context: *const anyopaque,
    resolve_physical_addr: fn (context: *const anyopaque, phys_addr: PhysicalAddress) *anyopaque,

    pub fn resolve(self: *const AddressResolver, phys_addr: PhysicalAddress) *anyopaque {
        return self.resolve_physical_addr(self.context, phys_addr);
    }

    pub fn resolveAs(self: *const AddressResolver, comptime T: type, phys_addr: PhysicalAddress) *T {
        return @ptrCast(self.resolve(phys_addr));
    }

    pub fn resolvePage(self: *const AddressResolver, phys_page: PageNum) *anyopaque {
        return self.resolve(pageNumToAddress(phys_page));
    }

    pub fn resolvePageAs(self: *const AddressResolver, comptime T: type, phys_page: PageNum) *T {
        return self.resolveAs(T, pageNumToAddress(phys_page));
    }
};

pub const identityMapResolver = AddressResolver{
    .context = null,
    .resolve_physical_addr = resolveIdentityAddr,
};

fn resolveIdentityAddr(context: *anyopaque, phys_addr: PhysicalAddress) *anyopaque {
    _ = context;
    return @ptrFromInt(phys_addr);
}

pub const OffsetMapResolver = struct {
    // TODO: Handle negative offsets
    offset: Address,

    const Self = @This();

    pub fn resolver(self: *const Self) AddressResolver {
        return .{
            .context = self,
            .resolve_physical_addr = resolve,
        };
    }

    fn resolve(context: *anyopaque, phys_addr: PhysicalAddress) *anyopaque {
        const self: *const Self = @ptrCast(context);
        // TODO: Handle wrapping
        return phys_addr + self.offset;
    }
};
