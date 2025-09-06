const std = @import("std");
const uefi = std.os.uefi;
const W = std.unicode.utf8ToUtf16LeStringLiteral;

pub const Ascii = u8;

pub fn asciiToUtf16(ascii: Ascii) u16 {
    return @intCast(ascii);
}

pub const XO = enum(Ascii) {
    x = 'X',
    o = 'O',

    pub fn ascii(self: @This()) Ascii {
        return @intFromEnum(self);
    }
};

pub const Cell = enum(Ascii) {
    none = ' ',
    x = 'X',
    o = 'O',

    pub fn ascii(self: @This()) Ascii {
        return @intFromEnum(self);
    }

    pub fn fromXo(xo: XO) @This() {
        return @enumFromInt(@intFromEnum(xo));
    }
};

pub const Result = enum(Ascii) {
    x = 'X',
    o = 'O',
    tie = 'T',

    pub fn ascii(self: @This()) Ascii {
        return @intFromEnum(self);
    }

    pub fn tryFromXoCell(cell: Cell) ?@This() {
        return switch (cell) {
            .x => .x,
            .o => .o,
            .none => null,
        };
    }
};

pub const Coord = struct {
    row: u8,
    col: u8,

    const Self = @This();

    pub fn eql(a: Self, b: Self) bool {
        return a.row == b.row and a.col == b.col;
    }
};

pub const Direction = enum {
    up,
    down,
    left,
    right,
};

pub const Board = struct {
    grid: [3][3]Cell = EMPTY_GRID,

    const EMPTY_GRID = [_][3]Cell{[_]Cell{.none} ** 3} ** 3;

    const Self = @This();

    pub fn get_mark(self: *const Self, cell: Coord) Cell {
        return self.grid[cell.row][cell.col];
    }

    pub fn set_mark(self: *Self, cell: Coord, typ: XO) void {
        self.grid[cell.row][cell.col] = Cell.fromXo(typ);
    }

    pub fn check_finished(self: *const Self) ?Result {
        for (0..3) |row| {
            const res = Result.tryFromXoCell(self.grid[row][0]);
            if (res != null and self.grid[row][0] == self.grid[row][1] and self.grid[row][1] == self.grid[row][2]) {
                return res;
            }
        }

        for (0..3) |col| {
            const res = Result.tryFromXoCell(self.grid[0][col]);
            if (res != null and self.grid[0][col] == self.grid[1][col] and self.grid[1][col] == self.grid[2][col]) {
                return res;
            }
        }

        diag: {
            // Check middle cell since it covers both diagonals
            const res = Result.tryFromXoCell(self.grid[1][1]);
            if (res == null) {
                break :diag;
            }

            if (self.grid[0][0] == self.grid[1][1] and self.grid[1][1] == self.grid[2][2]) {
                return res;
            }
            if (self.grid[0][2] == self.grid[1][1] and self.grid[1][1] == self.grid[2][0]) {
                return res;
            }
        }

        // Empty space means not over yet
        for (0..3) |row| {
            for (0..3) |col| {
                if (self.grid[row][col] == .none) {
                    return null;
                }
            }
        }

        return .tie;
    }
};

pub const Game = struct {
    board: Board = Board{},
    cursor: Coord = Coord{ .row = 1, .col = 1 },
    turn: XO = .x,

    const Self = @This();

    pub fn move_cursor(self: *Self, dir: Direction) void {
        switch (dir) {
            .up => if (self.cursor.row > 0) {
                self.cursor.row -= 1;
            },
            .down => if (self.cursor.row < 2) {
                self.cursor.row += 1;
            },
            .left => if (self.cursor.col > 0) {
                self.cursor.col -= 1;
            },
            .right => if (self.cursor.col < 2) {
                self.cursor.col += 1;
            },
        }
    }

    pub fn mark(self: *Self) !?Result {
        if (self.board.get_mark(self.cursor) != .none) {
            return error.AlreadyMarked;
        }
        self.board.set_mark(self.cursor, self.turn);
        if (self.board.check_finished()) |result| {
            return result;
        }

        self.turn = if (self.turn == .x) .o else .x;
        // Not done yet
        return null;
    }
};

pub const Renderer = struct {
    output: *uefi.protocol.SimpleTextOutput,
    // origin: Coord,

    const Self = @This();
    const colors = uefi.protocol.SimpleTextOutput;

    pub fn renderInit(self: *const Self) void {
        _ = self.output.reset(true);
        _ = self.output.enableCursor(true);
        _ = self.output.setCursorPosition(0, 0);
        _ = self.output.setAttribute(colors.white | colors.background_black);
        _ = self.output.outputString(W(" | | \r\n-----\r\n | | \r\n-----\r\n | |"));
    }

    fn renderCell(self: *const Self, game: *const Game, pos: Coord) void {
        _ = self.output.setCursorPosition(
            @intCast(pos.col * 2),
            @intCast(pos.row * 2),
        );

        if (game.board.grid[pos.row][pos.col] == .none and Coord.eql(pos, game.cursor)) {
            _ = self.output.setAttribute(colors.cyan | colors.background_black);
            _ = self.output.outputString(&[_:0]u16{
                asciiToUtf16(game.turn.ascii()),
                0,
            });
        } else {
            _ = self.output.setAttribute(colors.white | colors.background_black);
            _ = self.output.outputString(&[_:0]u16{
                asciiToUtf16(game.board.grid[pos.row][pos.col].ascii()),
                0,
            });
        }
    }

    pub fn render(self: *const Self, game: *const Game) void {
        for (0..3) |row| {
            for (0..3) |col| {
                self.renderCell(game, .{ .row = @intCast(row), .col = @intCast(col) });
            }
        }
        _ = self.output.setCursorPosition(
            @intCast(game.cursor.col * 2),
            @intCast(game.cursor.row * 2),
        );
    }
};

const Command = enum {
    noop,
    exit,
    mark,
    up,
    down,
    left,
    right,
};

const Keyboard = struct {
    boot_services: *uefi.tables.BootServices,
    input: *uefi.protocol.SimpleTextInput,

    const Self = @This();
    const UefiKey = uefi.protocol.SimpleTextInput.Key;

    fn convertKey(key: UefiKey.Input) Command {
        const key_up = 0x01;
        const key_down = 0x02;
        const key_right = 0x03;
        const key_left = 0x04;
        const key_esc = 0x17;

        switch (key.unicode_char) {
            ' ', 0x000a, 0x000d => return .mark,
            else => {},
        }
        switch (key.scan_code) {
            key_esc => return .exit,
            key_up => return .up,
            key_down => return .down,
            key_left => return .left,
            key_right => return .right,
            else => return .noop,
        }
    }

    pub fn readCommand(self: *const Self) Command {
        var ev_index: usize = 0;
        _ = self.boot_services.waitForEvent(
            1,
            &[1]uefi.Event{self.input.wait_for_key},
            &ev_index,
        );

        var key: UefiKey.Input = undefined;
        switch (self.input.readKeyStroke(&key)) {
            .success => return convertKey(key),
            .not_ready => {
                // Unexpected?
                // TODO: Handle
            },
            .device_error => {
                // TODO: Handle this
            },
            .unsupported => {
                // TODO: Handle this
            },
            else => {
                // TODO: Handle this
            },
        }
        return .noop;
    }
};

pub fn play(
    boot_services: *uefi.tables.BootServices,
    con_in: *uefi.protocol.SimpleTextInput,
    con_out: *uefi.protocol.SimpleTextOutput,
) void {
    var game = Game{};
    const renderer = Renderer{ .output = con_out };
    const keyboard = Keyboard{ .boot_services = boot_services, .input = con_in };

    renderer.renderInit();
    renderer.render(&game);
    loop: while (true) {
        switch (keyboard.readCommand()) {
            .noop => continue :loop,
            .exit => break :loop,
            .mark => {
                const maybe_result = game.mark() catch continue :loop;
                if (maybe_result) |result| {
                    _ = renderer.output.reset(true);
                    if (result == .tie) {
                        _ = con_out.outputString(W("tie!\r\n"));
                        return;
                    }
                    _ = con_out.outputString(&[_:0]u16{
                        asciiToUtf16(result.ascii()),
                        0,
                    });
                    _ = con_out.outputString(W("'s won!\r\n"));
                    return;
                }
            },
            .up => game.move_cursor(.up),
            .down => game.move_cursor(.down),
            .left => game.move_cursor(.left),
            .right => game.move_cursor(.right),
        }
        renderer.render(&game);
    }

    _ = con_out.reset(true);
    _ = con_out.outputString(W("goodbye!\r\n"));
}
