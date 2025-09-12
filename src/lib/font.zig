const std = @import("std");

const psf1_magic = [2]u8{ 0x36, 0x04 };

const Psf1Header = extern struct {
    magic: [2]u8,
    mode: Psf1Mode,
    charsize: u8,
};

const Psf1Mode = packed struct(u8) {
    has_512: bool,
    has_table: bool,
    has_seq: bool,
    _unused: u5,
};

const psf1_start_seq: u16 = 0xFFFE;
const psf1_separator: u16 = 0xFFFF;

// TODO: Figure out proper datastructure for storing this so that it can handle multi-codepoint symbols
// Some sort of tiered tree structure?
const UnicodeTable = struct {
    unicode_to_index: [128]u16,
};

pub const Psf1Font = struct {
    width: u8,
    height: u8,
    bitmap: []const u8,
    // Heap-allocated unicode table
    unicode_table: ?*UnicodeTable,

    const Self = @This();

    pub const empty = Self{
        .width = 8,
        .height = 0,
        .bitmap = &.{},
        .unicode_table = null,
    };

    // TODO: Don't require alignment?
    // TODO: Allow passing in unicode_table buffer
    pub fn parse(allocator: std.mem.Allocator, file_data: []align(2) const u8) !Self {
        if (file_data.len < @sizeOf(Psf1Header)) {
            return error.FileTooSmall;
        }

        const header: *const Psf1Header = @ptrCast(file_data.ptr);
        if (!std.mem.eql(u8, &header.magic, &psf1_magic)) {
            std.log.err("invalid magic: {x}", .{header.magic});
            return error.InvalidMagic;
        }
        const char_count: usize = if (header.mode.has_512) 512 else 256;
        const bitmap_end = @sizeOf(Psf1Header) + char_count * header.charsize;
        if (file_data.len < bitmap_end) {
            return error.FileTooSmall;
        }
        const bitmap = file_data[@sizeOf(Psf1Header)..bitmap_end];

        var unicode_table: ?*UnicodeTable = null;
        // TODO: is there a difference between these flags?
        if (header.mode.has_table or header.mode.has_seq) {
            // Alignment is always 2 because char_count is always even
            const unicode_table_data: []const u16 = @alignCast(std.mem.bytesAsSlice(u16, file_data[bitmap_end..]));
            unicode_table = try buildUnicodeTable(allocator, unicode_table_data);
        }
        return .{ .width = 8, .height = header.charsize, .bitmap = bitmap, .unicode_table = unicode_table };
    }

    pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
        if (self.unicode_table) |t| allocator.destroy(t);
    }

    pub fn getGlyphBitmap(self: *const Self, codepoint: u21) ?[]const u8 {
        // TODO: Handle unicode sequencies
        const seq_len = std.unicode.utf16CodepointSequenceLength(codepoint) catch 0;
        if (seq_len != 1) return null;
        var index: usize = codepoint;
        if (self.unicode_table) |uni| {
            index = uni.unicode_to_index[codepoint];
        }
        return self.bitmap[index * self.height ..][0..self.height];
    }
};

fn buildUnicodeTable(allocator: std.mem.Allocator, table_data: []const u16) !*UnicodeTable {
    var table = try allocator.create(UnicodeTable);
    errdefer allocator.destroy(table);

    // Indicates "unmapped"
    @memset(&table.unicode_to_index, 0xFFFF);

    var glyph_index: u16 = 0;
    var i: usize = 0;
    while (i < table_data.len) {
        const glyph_line_len = std.mem.indexOfScalar(u16, table_data[i..], psf1_separator) orelse return error.MissingTerminator;
        const glyph_line = table_data[i .. i + glyph_line_len];
        for (glyph_line) |codepoint| {
            if (codepoint == psf1_start_seq) {
                // TODO: Handle multi-symbol sequences
                break;
            }
            if (codepoint > 0x7F) {
                // TODO: Handle non-ASCII
                break;
            }
            table.unicode_to_index[codepoint] = glyph_index;
        }

        i += glyph_line_len + 1;
        glyph_index += 1;
    }

    return table;
}

const testing = std.testing;

test "parse PSF1 font" {
    const font_data align(2) = @embedFile("assets/Lat15-Terminus16.psf").*;
    const font = try Psf1Font.parse(testing.allocator, &font_data);
    defer font.deinit(testing.allocator);
    try testing.expectEqual(16, font.height());
    try testing.expect(font.unicode_table != null);
    for ('a'..'z') |char| {
        try testing.expect(font.getGlyphBitmap(@intCast(char)) != null);
    }
}
