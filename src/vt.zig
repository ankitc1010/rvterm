//! A small VT100/xterm-subset terminal: parses the guest's output into a cell grid.
//! The renderer reads `screen` directly; `dirty` marks rows to redraw and `scroll_pending`
//! counts full-screen scrolls so it can shift pixels instead of redrawing every row.

const std = @import("std");

pub const max_cols = 160;
pub const max_rows = 60;

/// ch == 0 means an empty cell, so a zeroed grid is a blank screen.
pub const Cell = extern struct { ch: u32, fg: u8, bg: u8, attr: u8, _pad: u8 };

pub const attr_bold: u8 = 1;
pub const attr_dim: u8 = 2;
pub const attr_underline: u8 = 4;
pub const attr_reverse: u8 = 8;
pub const attr_fg_set: u8 = 16; // fg holds a palette index; otherwise the default colour
pub const attr_bg_set: u8 = 32;

pub const mode_cursor_visible: u32 = 1;
pub const mode_autowrap: u32 = 2;
pub const mode_app_cursor: u32 = 4;
pub const mode_insert: u32 = 8;
pub const mode_alt_screen: u32 = 16;

const State = enum(u32) { ground, esc, csi, string, string_esc, skip_one };
const max_params = 16;

const Saved = extern struct { x: u32, y: u32, pen: Cell };

/// Plain data only, so it can be snapshotted as bytes.
pub const Vt = extern struct {
    cols: u32,
    rows: u32,
    x: u32,
    y: u32,
    wrap_pending: u32,
    top: u32,
    bottom: u32,
    modes: u32,
    pen: Cell,
    saved: Saved,
    state: State,
    params: [max_params]u32,
    nparams: u32,
    private: u32,
    utf8_cp: u32,
    utf8_left: u32,
    scroll_pending: u32,
    resp_len: u32,
    resp: [64]u8,
    dirty: [max_rows]u8,
    screen: [max_rows * max_cols]Cell,
    other: [max_rows * max_cols]Cell, // the inactive main/alternate screen

    pub fn init(vt: *Vt, cols: u32, rows: u32) void {
        @memset(std.mem.asBytes(vt), 0); // in place: the struct is larger than the wasm stack
        vt.cols = @min(cols, max_cols);
        vt.rows = @min(rows, max_rows);
        vt.bottom = vt.rows - 1;
        vt.modes = mode_cursor_visible | mode_autowrap;
        vt.markAll();
    }

    pub fn feed(vt: *Vt, b: u8) void {
        // C0 controls act immediately, even in the middle of an escape sequence.
        if (b < 0x20 and vt.state != .string and vt.state != .string_esc) {
            if (vt.utf8_left != 0) {
                vt.utf8_left = 0;
                vt.print(0xfffd);
            }
            switch (b) {
                0x1b => vt.state = .esc,
                0x18, 0x1a => vt.state = .ground,
                else => vt.control(b),
            }
            return;
        }
        switch (vt.state) {
            .ground => vt.ground(b),
            .esc => vt.escape(b),
            .csi => vt.csiByte(b),
            .string => switch (b) {
                0x07 => vt.state = .ground,
                0x1b => vt.state = .string_esc,
                else => {},
            },
            .string_esc => vt.state = if (b == '\\') .ground else .string,
            .skip_one => vt.state = .ground,
        }
    }

    fn ground(vt: *Vt, b: u8) void {
        if (vt.utf8_left != 0) {
            if (b & 0xc0 == 0x80) {
                vt.utf8_cp = (vt.utf8_cp << 6) | (b & 0x3f);
                vt.utf8_left -= 1;
                if (vt.utf8_left == 0) vt.print(vt.utf8_cp);
                return;
            }
            vt.utf8_left = 0;
            vt.print(0xfffd);
        }
        switch (b) {
            0x20...0x7e => vt.print(b),
            0x7f => {},
            0xc2...0xdf => vt.startUtf8(b & 0x1f, 1),
            0xe0...0xef => vt.startUtf8(b & 0x0f, 2),
            0xf0...0xf4 => vt.startUtf8(b & 0x07, 3),
            else => vt.print(0xfffd),
        }
    }

    fn startUtf8(vt: *Vt, bits: u32, left: u32) void {
        vt.utf8_cp = bits;
        vt.utf8_left = left;
    }

    fn control(vt: *Vt, b: u8) void {
        switch (b) {
            0x08 => if (vt.x > 0) vt.moveTo(vt.x - 1, vt.y),
            0x09 => vt.moveTo(@min((vt.x / 8 + 1) * 8, vt.cols - 1), vt.y),
            0x0a, 0x0b, 0x0c => vt.lineFeed(),
            0x0d => vt.moveTo(0, vt.y),
            else => {}, // BEL, SO/SI and the rest are ignored
        }
    }

    fn escape(vt: *Vt, b: u8) void {
        vt.state = .ground;
        switch (b) {
            '[' => {
                vt.state = .csi;
                vt.params = @splat(0);
                vt.nparams = 0;
                vt.private = 0;
            },
            ']', 'P', 'X', '^', '_' => vt.state = .string, // OSC, DCS, ...: content ignored
            '(', ')', '*', '+', '-', '.', '/', '#', '%' => vt.state = .skip_one, // charsets, DECALN
            '7' => vt.saveCursor(),
            '8' => vt.restoreCursor(),
            'D' => vt.lineFeed(),
            'E' => {
                vt.moveTo(0, vt.y);
                vt.lineFeed();
            },
            'M' => vt.reverseIndex(),
            'c' => vt.init(vt.cols, vt.rows),
            else => {}, // keypad modes and anything unsupported
        }
    }

    fn csiByte(vt: *Vt, b: u8) void {
        switch (b) {
            '0'...'9' => {
                if (vt.nparams == 0) vt.nparams = 1;
                const p = &vt.params[vt.nparams - 1];
                p.* = @min(p.* * 10 + (b - '0'), 65535);
            },
            ';', ':' => {
                if (vt.nparams == 0) vt.nparams = 1;
                if (vt.nparams < max_params) vt.nparams += 1;
            },
            '<'...'?' => vt.private = b,
            0x20...0x2f => {}, // intermediates
            0x40...0x7e => {
                vt.state = .ground;
                if (vt.private == 0) vt.dispatch(b) else vt.dispatchPrivate(b);
            },
            else => vt.state = .ground,
        }
    }

    fn param(vt: *const Vt, i: usize, default: u32) u32 {
        return if (i < vt.nparams and vt.params[i] != 0) vt.params[i] else default;
    }

    fn dispatch(vt: *Vt, final: u8) void {
        const n = vt.param(0, 1);
        switch (final) {
            'A' => vt.moveTo(vt.x, @max(vt.y -| n, if (vt.y >= vt.top) vt.top else 0)),
            'B' => vt.moveTo(vt.x, @min(vt.y + n, if (vt.y <= vt.bottom) vt.bottom else vt.rows - 1)),
            'C' => vt.moveTo(vt.x + n, vt.y),
            'D' => vt.moveTo(vt.x -| n, vt.y),
            'E' => vt.moveTo(0, @min(vt.y + n, vt.rows - 1)),
            'F' => vt.moveTo(0, vt.y -| n),
            'G', '`' => vt.moveTo(n - 1, vt.y),
            'H', 'f' => vt.moveTo(vt.param(1, 1) - 1, n - 1),
            'd' => vt.moveTo(vt.x, n - 1),
            'J' => switch (vt.param(0, 0)) {
                0 => {
                    vt.eraseCells(vt.y, vt.x, vt.cols);
                    vt.eraseRows(vt.y + 1, vt.rows);
                },
                1 => {
                    vt.eraseRows(0, vt.y);
                    vt.eraseCells(vt.y, 0, vt.x + 1);
                },
                else => vt.eraseRows(0, vt.rows),
            },
            'K' => switch (vt.param(0, 0)) {
                0 => vt.eraseCells(vt.y, vt.x, vt.cols),
                1 => vt.eraseCells(vt.y, 0, vt.x + 1),
                else => vt.eraseCells(vt.y, 0, vt.cols),
            },
            '@' => vt.insertCells(n),
            'P' => vt.deleteCells(n),
            'X' => vt.eraseCells(vt.y, vt.x, @min(vt.x + n, vt.cols)),
            'L' => if (vt.y >= vt.top and vt.y <= vt.bottom) vt.scrollDown(vt.y, n),
            'M' => if (vt.y >= vt.top and vt.y <= vt.bottom) vt.scrollUp(vt.y, n),
            'S' => vt.scrollUp(vt.top, n),
            'T' => vt.scrollDown(vt.top, n),
            'm' => vt.sgr(),
            'r' => {
                const top = vt.param(0, 1) - 1;
                const bottom = @min(vt.param(1, vt.rows), vt.rows) - 1;
                if (top < bottom) {
                    vt.top = top;
                    vt.bottom = bottom;
                    vt.moveTo(0, 0);
                }
            },
            's' => vt.saveCursor(),
            'u' => vt.restoreCursor(),
            'h', 'l' => if (vt.param(0, 0) == 4) vt.setMode(mode_insert, final == 'h'),
            'n' => switch (vt.param(0, 0)) {
                5 => vt.respond("\x1b[0n"),
                6 => {
                    vt.respond("\x1b[");
                    vt.respondNumber(vt.y + 1);
                    vt.respond(";");
                    vt.respondNumber(vt.x + 1);
                    vt.respond("R");
                },
                else => {},
            },
            'c' => vt.respond("\x1b[?1;2c"), // a VT100 with advanced video
            else => {},
        }
    }

    fn dispatchPrivate(vt: *Vt, final: u8) void {
        if (vt.private != '?' or (final != 'h' and final != 'l')) return;
        const on = final == 'h';
        for (0..@max(vt.nparams, 1)) |i| {
            switch (vt.params[i]) {
                1 => vt.setMode(mode_app_cursor, on),
                7 => vt.setMode(mode_autowrap, on),
                25 => {
                    vt.setMode(mode_cursor_visible, on);
                    vt.dirty[vt.y] = 1;
                },
                47, 1047, 1049 => vt.altScreen(on),
                else => {},
            }
        }
    }

    fn setMode(vt: *Vt, mode: u32, on: bool) void {
        if (on) vt.modes |= mode else vt.modes &= ~mode;
    }

    fn sgr(vt: *Vt) void {
        var i: usize = 0;
        const count = @max(vt.nparams, 1);
        while (i < count) : (i += 1) {
            const p = vt.params[i];
            switch (p) {
                0 => vt.pen = std.mem.zeroes(Cell),
                1 => vt.pen.attr |= attr_bold,
                2 => vt.pen.attr |= attr_dim,
                4 => vt.pen.attr |= attr_underline,
                7 => vt.pen.attr |= attr_reverse,
                22 => vt.pen.attr &= ~(attr_bold | attr_dim),
                24 => vt.pen.attr &= ~attr_underline,
                27 => vt.pen.attr &= ~attr_reverse,
                30...37 => vt.setFg(@intCast(p - 30)),
                90...97 => vt.setFg(@intCast(p - 90 + 8)),
                39 => vt.pen.attr &= ~attr_fg_set,
                40...47 => vt.setBg(@intCast(p - 40)),
                100...107 => vt.setBg(@intCast(p - 100 + 8)),
                49 => vt.pen.attr &= ~attr_bg_set,
                38, 48 => {
                    // 38;5;n (256 colours) or 38;2;r;g;b (mapped onto the 6x6x6 cube)
                    var colour: ?u8 = null;
                    if (i + 2 < count and vt.params[i + 1] == 5) {
                        colour = @truncate(vt.params[i + 2]);
                        i += 2;
                    } else if (i + 4 < count and vt.params[i + 1] == 2) {
                        const r = vt.params[i + 2] * 6 / 256;
                        const g = vt.params[i + 3] * 6 / 256;
                        const b = vt.params[i + 4] * 6 / 256;
                        colour = @intCast(16 + 36 * r + 6 * g + b);
                        i += 4;
                    }
                    if (colour) |c| if (p == 38) vt.setFg(c) else vt.setBg(c);
                },
                else => {},
            }
        }
    }

    fn setFg(vt: *Vt, c: u8) void {
        vt.pen.fg = c;
        vt.pen.attr |= attr_fg_set;
    }

    fn setBg(vt: *Vt, c: u8) void {
        vt.pen.bg = c;
        vt.pen.attr |= attr_bg_set;
    }

    /// Queues bytes for the guest's input, e.g. replies to cursor position queries.
    fn respond(vt: *Vt, s: []const u8) void {
        if (vt.resp_len + s.len > vt.resp.len) return;
        @memcpy(vt.resp[vt.resp_len..][0..s.len], s);
        vt.resp_len += @intCast(s.len);
    }

    fn respondNumber(vt: *Vt, v: u32) void {
        var digits: [10]u8 = undefined;
        var i: usize = digits.len;
        var rest = v;
        while (true) {
            i -= 1;
            digits[i] = @intCast('0' + rest % 10);
            rest /= 10;
            if (rest == 0) break;
        }
        vt.respond(digits[i..]);
    }

    fn print(vt: *Vt, cp: u32) void {
        if (vt.wrap_pending != 0) {
            vt.moveTo(0, vt.y);
            vt.lineFeed();
        }
        if (vt.modes & mode_insert != 0) vt.insertCells(1);
        const row = vt.rowSlice(vt.y);
        row[vt.x] = .{ .ch = cp, .fg = vt.pen.fg, .bg = vt.pen.bg, .attr = vt.pen.attr, ._pad = 0 };
        vt.dirty[vt.y] = 1;
        if (vt.x + 1 < vt.cols) {
            vt.x += 1;
        } else if (vt.modes & mode_autowrap != 0) {
            vt.wrap_pending = 1;
        }
    }

    fn moveTo(vt: *Vt, x: u32, y: u32) void {
        vt.dirty[vt.y] = 1; // the old cursor position needs repainting
        vt.x = @min(x, vt.cols - 1);
        vt.y = @min(y, vt.rows - 1);
        vt.wrap_pending = 0;
        vt.dirty[vt.y] = 1;
    }

    fn lineFeed(vt: *Vt) void {
        if (vt.y == vt.bottom) {
            vt.scrollUp(vt.top, 1);
            vt.wrap_pending = 0;
        } else {
            vt.moveTo(vt.x, vt.y + 1);
        }
    }

    fn reverseIndex(vt: *Vt) void {
        if (vt.y == vt.top) vt.scrollDown(vt.top, 1) else vt.moveTo(vt.x, vt.y -| 1);
    }

    fn rowSlice(vt: *Vt, y: u32) []Cell {
        return vt.screen[y * max_cols ..][0..vt.cols];
    }

    fn blank(vt: *const Vt) Cell {
        // Erased cells keep the current background colour, like xterm.
        return .{ .ch = 0, .fg = 0, .bg = vt.pen.bg, .attr = vt.pen.attr & attr_bg_set, ._pad = 0 };
    }

    fn eraseCells(vt: *Vt, y: u32, from: u32, to: u32) void {
        if (from >= to) return;
        @memset(vt.rowSlice(y)[from..to], vt.blank());
        vt.dirty[y] = 1;
    }

    fn eraseRows(vt: *Vt, from: u32, to: u32) void {
        var y = from;
        while (y < to) : (y += 1) vt.eraseCells(y, 0, vt.cols);
    }

    fn insertCells(vt: *Vt, n: u32) void {
        const row = vt.rowSlice(vt.y);
        const k = @min(n, vt.cols - vt.x);
        std.mem.copyBackwards(Cell, row[vt.x + k ..], row[vt.x .. vt.cols - k]);
        @memset(row[vt.x..][0..k], vt.blank());
        vt.dirty[vt.y] = 1;
    }

    fn deleteCells(vt: *Vt, n: u32) void {
        const row = vt.rowSlice(vt.y);
        const k = @min(n, vt.cols - vt.x);
        std.mem.copyForwards(Cell, row[vt.x .. vt.cols - k], row[vt.x + k ..]);
        @memset(row[vt.cols - k ..], vt.blank());
        vt.dirty[vt.y] = 1;
    }

    /// Scrolls rows [from, bottom] up by n, blanking the bottom n rows.
    fn scrollUp(vt: *Vt, from: u32, n: u32) void {
        const k = @min(n, vt.bottom + 1 - from);
        var y = from;
        while (y + k <= vt.bottom) : (y += 1) @memcpy(vt.rowSlice(y), vt.rowSlice(y + k));
        const full = from == 0 and vt.bottom == vt.rows - 1;
        if (full) {
            // Let the renderer shift pixels: move the dirty flags with the content.
            vt.scroll_pending += k;
            std.mem.copyForwards(u8, vt.dirty[0 .. vt.rows - k], vt.dirty[k..vt.rows]);
        }
        vt.eraseRows(vt.bottom + 1 - k, vt.bottom + 1);
        if (!full) @memset(vt.dirty[from .. vt.bottom + 1], 1);
    }

    /// Scrolls rows [from, bottom] down by n, blanking n rows at `from`.
    fn scrollDown(vt: *Vt, from: u32, n: u32) void {
        const k = @min(n, vt.bottom + 1 - from);
        var y = vt.bottom;
        while (y >= from + k) : (y -= 1) @memcpy(vt.rowSlice(y), vt.rowSlice(y - k));
        vt.eraseRows(from, from + k);
        @memset(vt.dirty[from .. vt.bottom + 1], 1);
    }

    fn saveCursor(vt: *Vt) void {
        vt.saved = .{ .x = vt.x, .y = vt.y, .pen = vt.pen };
    }

    fn restoreCursor(vt: *Vt) void {
        vt.pen = vt.saved.pen;
        vt.moveTo(vt.saved.x, vt.saved.y);
    }

    fn altScreen(vt: *Vt, on: bool) void {
        if (on == (vt.modes & mode_alt_screen != 0)) return;
        if (on) vt.saveCursor();
        for (&vt.screen, &vt.other) |*a, *b| std.mem.swap(Cell, a, b);
        vt.setMode(mode_alt_screen, on);
        if (on) vt.eraseRows(0, vt.rows) else vt.restoreCursor();
        vt.markAll();
    }

    fn markAll(vt: *Vt) void {
        @memset(vt.dirty[0..vt.rows], 1);
    }
};

// ---------------------------------------------------------------------------

fn testVt() !*Vt {
    const vt = try std.testing.allocator.create(Vt);
    vt.init(10, 4);
    return vt;
}

fn feedAll(vt: *Vt, s: []const u8) void {
    for (s) |b| vt.feed(b);
}

fn rowText(vt: *Vt, y: u32, buf: []u8) []const u8 {
    var len: usize = 0;
    for (vt.rowSlice(y)) |c| {
        len += std.unicode.utf8Encode(@intCast(if (c.ch == 0) ' ' else c.ch), buf[len..]) catch unreachable;
    }
    return std.mem.trimEnd(u8, buf[0..len], " ");
}

test "printing, wrapping and scrolling" {
    const vt = try testVt();
    defer std.testing.allocator.destroy(vt);
    var buf: [64]u8 = undefined;
    feedAll(vt, "0123456789AB\r\nline2\r\nline3\r\nline4\r\nline5");
    try std.testing.expectEqualStrings("line2", rowText(vt, 0, &buf));
    try std.testing.expectEqualStrings("line5", rowText(vt, 3, &buf));
    try std.testing.expectEqual(@as(u32, 2), vt.scroll_pending);
}

test "cursor movement, erase and colours" {
    const vt = try testVt();
    defer std.testing.allocator.destroy(vt);
    var buf: [64]u8 = undefined;
    feedAll(vt, "hello\x1b[1;3H\x1b[K\x1b[31mX\x1b[0m");
    try std.testing.expectEqualStrings("heX", rowText(vt, 0, &buf));
    const cell = vt.rowSlice(0)[2];
    try std.testing.expectEqual(@as(u8, 1), cell.fg);
    try std.testing.expect(cell.attr & attr_fg_set != 0);
    feedAll(vt, "\x1b[2J\x1b[4;10Hz\x1b[6n");
    try std.testing.expectEqualStrings("         z", rowText(vt, 3, &buf));
    try std.testing.expectEqualStrings("\x1b[4;10R", vt.resp[0..vt.resp_len]);
}

test "utf-8, insert/delete and alternate screen" {
    const vt = try testVt();
    defer std.testing.allocator.destroy(vt);
    var buf: [64]u8 = undefined;
    feedAll(vt, "a\xc3\xa9b\xe2\x94\x80\r\x1b[2@");
    try std.testing.expectEqualStrings("  aéb─", rowText(vt, 0, &buf));
    feedAll(vt, "\x1b[3P");
    try std.testing.expectEqualStrings("éb─", rowText(vt, 0, &buf));
    feedAll(vt, "\x1b[?1049hALT");
    try std.testing.expectEqualStrings("ALT", rowText(vt, 0, &buf));
    feedAll(vt, "\x1b[?1049l");
    try std.testing.expectEqualStrings("éb─", rowText(vt, 0, &buf));
}

test "scroll region with insert and delete lines" {
    const vt = try testVt();
    defer std.testing.allocator.destroy(vt);
    var buf: [64]u8 = undefined;
    feedAll(vt, "r0\r\nr1\r\nr2\r\nr3\x1b[2;3r\x1b[2;1H\x1b[L");
    try std.testing.expectEqualStrings("r0", rowText(vt, 0, &buf));
    try std.testing.expectEqualStrings("", rowText(vt, 1, &buf));
    try std.testing.expectEqualStrings("r1", rowText(vt, 2, &buf));
    try std.testing.expectEqualStrings("r3", rowText(vt, 3, &buf));
    feedAll(vt, "\x1b[M\x1b[M");
    try std.testing.expectEqualStrings("", rowText(vt, 2, &buf));
    try std.testing.expectEqualStrings("r3", rowText(vt, 3, &buf));
    try std.testing.expectEqual(@as(u32, 0), vt.scroll_pending);
}
