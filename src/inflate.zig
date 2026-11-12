//! Minimal gzip/DEFLATE decoder (RFC 1951/1952) after zlib's puff.c: a few KB of wasm instead of
//! ~45 KB for std.compress.flate. Decodes in one call, pushing output through a 32 KB history
//! window to `sink.write(bytes)`, so the caller never needs the whole decompressed file in memory.

const std = @import("std");

pub const Error = error{ Truncated, Corrupt };

const max_bits = 15;
const window_len = 32768;

const Huffman = struct {
    count: [max_bits + 1]u16 = @splat(0),
    symbol: [288]u16 = @splat(0),

    /// Builds canonical codes from per-symbol bit lengths; incomplete codes are allowed.
    fn init(h: *Huffman, lengths: []const u8) Error!void {
        h.count = @splat(0);
        for (lengths) |l| h.count[l] += 1;
        var left: i32 = 1;
        for (1..max_bits + 1) |len| {
            left = (left << 1) - h.count[len];
            if (left < 0) return error.Corrupt; // over-subscribed
        }
        var offs: [max_bits + 1]u16 = undefined;
        offs[1] = 0;
        for (1..max_bits) |len| offs[len + 1] = offs[len] + h.count[len];
        for (lengths, 0..) |l, sym| {
            if (l == 0) continue;
            h.symbol[offs[l]] = @intCast(sym);
            offs[l] += 1;
        }
    }
};

const len_base = [29]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
const len_extra = [29]u5{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
const dist_base = [30]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
const dist_extra = [30]u5{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };

/// Decompresses a whole gzip member, calling `sink.write([]const u8) !void` with the output in
/// order. `window` must be 32 KB; it holds the back-reference history.
pub fn gunzip(input: []const u8, window: *[window_len]u8, sink: anytype) !void {
    var s = State(@TypeOf(sink)){ .in = input, .window = window, .sink = sink };
    try s.gzipHeader();
    while (true) {
        const last = try s.bits(1);
        switch (try s.bits(2)) {
            0 => try s.stored(),
            1 => try s.codes(&fixed.lit, &fixed.dist),
            2 => try s.dynamic(),
            else => return error.Corrupt,
        }
        if (last == 1) break;
    }
    try s.flush();
    // The trailer's ISIZE is the output length mod 2^32: a cheap check that nothing was lost.
    s.bitcnt = 0;
    if (s.pos + 8 > s.in.len) return error.Truncated;
    if (std.mem.readInt(u32, s.in[s.pos + 4 ..][0..4], .little) != @as(u32, @truncate(s.total))) return error.Corrupt;
}

const fixed = struct {
    var lit: Huffman = .{};
    var dist: Huffman = .{};
    var built = false;
};

fn State(comptime Sink: type) type {
    return struct {
        in: []const u8,
        pos: usize = 0,
        bitbuf: u32 = 0,
        bitcnt: u6 = 0,
        window: *[window_len]u8,
        wpos: usize = 0, // next write position in the window
        flushed: usize = 0, // window bytes already given to the sink
        total: usize = 0,
        sink: Sink,

        const Self = @This();

        fn bits(s: *Self, n: u5) Error!u32 {
            while (s.bitcnt < n) {
                if (s.pos >= s.in.len) return error.Truncated;
                s.bitbuf |= @as(u32, s.in[s.pos]) << @intCast(s.bitcnt);
                s.pos += 1;
                s.bitcnt += 8;
            }
            const v = s.bitbuf & ((@as(u32, 1) << n) - 1);
            s.bitbuf >>= n;
            s.bitcnt -= n;
            return v;
        }

        fn byte(s: *Self) Error!u8 {
            if (s.pos >= s.in.len) return error.Truncated;
            s.pos += 1;
            return s.in[s.pos - 1];
        }

        fn gzipHeader(s: *Self) Error!void {
            if (s.in.len < 10 or s.in[0] != 0x1f or s.in[1] != 0x8b or s.in[2] != 8) return error.Corrupt;
            const flags = s.in[3];
            s.pos = 10;
            if (flags & 4 != 0) { // FEXTRA
                const xlen = @as(usize, try s.byte()) | @as(usize, try s.byte()) << 8;
                s.pos += xlen;
            }
            if (flags & 8 != 0) while (try s.byte() != 0) {}; // FNAME
            if (flags & 16 != 0) while (try s.byte() != 0) {}; // FCOMMENT
            if (flags & 2 != 0) s.pos += 2; // FHCRC
        }

        fn put(s: *Self, b: u8) !void {
            s.window[s.wpos] = b;
            s.wpos += 1;
            s.total += 1;
            if (s.wpos == window_len) {
                try s.flush();
                s.wpos = 0;
                s.flushed = 0;
            }
        }

        fn flush(s: *Self) !void {
            if (s.wpos > s.flushed) try s.sink.write(s.window[s.flushed..s.wpos]);
            s.flushed = s.wpos;
        }

        fn stored(s: *Self) !void {
            s.bitbuf = 0; // stored blocks start on a byte boundary
            s.bitcnt = 0;
            if (s.pos + 4 > s.in.len) return error.Truncated;
            const len = std.mem.readInt(u16, s.in[s.pos..][0..2], .little);
            const nlen = std.mem.readInt(u16, s.in[s.pos + 2 ..][0..2], .little);
            if (len != ~nlen) return error.Corrupt;
            s.pos += 4;
            if (s.pos + len > s.in.len) return error.Truncated;
            for (s.in[s.pos..][0..len]) |b| try s.put(b);
            s.pos += len;
        }

        fn decode(s: *Self, h: *const Huffman) Error!u16 {
            var code: u32 = 0;
            var first: u32 = 0;
            var index: u32 = 0;
            for (1..max_bits + 1) |len| {
                code |= try s.bits(1);
                const count = h.count[len];
                if (code < first + count) return h.symbol[index + code - first];
                index += count;
                first = (first + count) << 1;
                code <<= 1;
            }
            return error.Corrupt;
        }

        fn codes(s: *Self, lit: *const Huffman, dist: *const Huffman) !void {
            while (true) {
                const sym = try s.decode(lit);
                if (sym < 256) {
                    try s.put(@intCast(sym));
                } else if (sym == 256) {
                    return;
                } else {
                    const li = sym - 257;
                    if (li >= len_base.len) return error.Corrupt;
                    const len = len_base[li] + try s.bits(len_extra[li]);
                    const di = try s.decode(dist);
                    if (di >= dist_base.len) return error.Corrupt;
                    const d = dist_base[di] + try s.bits(dist_extra[di]);
                    if (d > s.total) return error.Corrupt;
                    for (0..len) |_| try s.put(s.window[(s.wpos + window_len - d) % window_len]);
                }
            }
        }

        fn dynamic(s: *Self) !void {
            const nlen = try s.bits(5) + 257;
            const ndist = try s.bits(5) + 1;
            const ncode = try s.bits(4) + 4;
            if (nlen > 286 or ndist > 30) return error.Corrupt;
            const order = [19]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };
            var lengths: [320]u8 = @splat(0);
            for (order[0..ncode]) |o| lengths[o] = @intCast(try s.bits(3));
            var lencode: Huffman = .{};
            try lencode.init(lengths[0..19]);

            var i: usize = 0;
            while (i < nlen + ndist) {
                const sym = try s.decode(&lencode);
                if (sym < 16) {
                    lengths[i] = @intCast(sym);
                    i += 1;
                    continue;
                }
                var repeat: u32 = undefined;
                var value: u8 = 0;
                switch (sym) {
                    16 => {
                        if (i == 0) return error.Corrupt;
                        value = lengths[i - 1];
                        repeat = 3 + try s.bits(2);
                    },
                    17 => repeat = 3 + try s.bits(3),
                    else => repeat = 11 + try s.bits(7),
                }
                if (i + repeat > nlen + ndist) return error.Corrupt;
                @memset(lengths[i..][0..repeat], value);
                i += repeat;
            }
            if (lengths[256] == 0) return error.Corrupt; // no end-of-block code
            var lit: Huffman = .{};
            var dist: Huffman = .{};
            try lit.init(lengths[0..nlen]);
            try dist.init(lengths[nlen..][0..ndist]);
            try s.codes(&lit, &dist);
        }
    };
}

/// Builds the fixed Huffman tables of RFC 1951 section 3.2.6; call before gunzip.
pub fn init() void {
    if (fixed.built) return;
    var lengths: [288]u8 = undefined;
    @memset(lengths[0..144], 8);
    @memset(lengths[144..256], 9);
    @memset(lengths[256..280], 7);
    @memset(lengths[280..288], 8);
    fixed.lit.init(&lengths) catch unreachable;
    @memset(lengths[0..30], 5);
    fixed.dist.init(lengths[0..30]) catch unreachable;
    fixed.built = true;
}

// ---------------------------------------------------------------------------
// Test vectors made with Python's zlib/gzip; each one exercises a different block type.

const Collect = struct {
    out: *std.ArrayList(u8),
    pub fn write(c: Collect, bytes: []const u8) !void {
        try c.out.appendSlice(std.testing.allocator, bytes);
    }
};

fn expectGunzip(gz: []const u8, expected: []const u8) !void {
    init();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    var window: [window_len]u8 = undefined;
    try gunzip(gz, &window, Collect{ .out = &out });
    try std.testing.expectEqualSlices(u8, expected, out.items);
}

test "stored block" {
    try expectGunzip("\x1f\x8b\x08\x00\x00\x00\x00\x00\x04\x03\x01\x3c\x00\xc3\xff\x54\x68\x65\x20\x71\x75\x69\x63\x6b\x20\x62\x72\x6f\x77\x6e\x20\x66\x6f\x78\x20\x6a\x75\x6d\x70\x73\x20\x6f\x76\x65\x72\x20\x74\x68\x65\x20\x6c\x61\x7a\x79\x20\x64\x6f\x67\x2e\x20\x4c\x69\x6e\x75\x78\x20\x6f\x6e\x20\x61\x20\x54\x56\x21\x0a\xe7\xd1\x62\xec\x3c\x00\x00\x00", "The quick brown fox jumps over the lazy dog. Linux on a TV!\n");
}

test "fixed Huffman block" {
    try expectGunzip("\x1f\x8b\x08\x00\x00\x00\x00\x00\x04\x03\x0b\xc9\x48\x55\x28\x2c\xcd\x4c\xce\x56\x48\x2a\xca\x2f\xcf\x53\x48\xcb\xaf\x50\xc8\x2a\xcd\x2d\x28\x56\xc8\x2f\x4b\x2d\x52\x28\x01\x4a\xe7\x24\x56\x55\x2a\xa4\xe4\xa7\xeb\x29\xf8\x64\xe6\x95\x56\x28\xe4\xe7\x29\x24\x2a\x84\x84\x29\x72\x01\x00\xe7\xd1\x62\xec\x3c\x00\x00\x00", "The quick brown fox jumps over the lazy dog. Linux on a TV!\n");
}

test "dynamic Huffman block" {
    try expectGunzip("\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\x03\x0b\xc9\x48\x55\x28\x2c\xcd\x4c\xce\x56\x48\x2a\xca\x2f\xcf\x53\x48\xcb\xaf\x50\xc8\x2a\xcd\x2d\x28\x56\xc8\x2f\x4b\x2d\x52\x28\x01\x4a\xe7\x24\x56\x55\x2a\xa4\xe4\xa7\xeb\x29\xf8\x64\xe6\x95\x56\x28\xe4\xe7\x29\x24\x2a\x84\x84\x29\x72\x85\x0c\x41\xbd\x00\xc4\x9c\xeb\x3b\xf0\x00\x00\x00", "The quick brown fox jumps over the lazy dog. Linux on a TV!\nThe quick brown fox jumps over the lazy dog. Linux on a TV!\nThe quick brown fox jumps over the lazy dog. Linux on a TV!\nThe quick brown fox jumps over the lazy dog. Linux on a TV!\n");
}

test "gzip header with a file name" {
    try expectGunzip("\x1f\x8b\x08\x08\x00\x00\x00\x00\x02\xff\x6e\x6f\x74\x65\x73\x2e\x74\x78\x74\x00\x0b\xc9\x48\x55\x28\x2c\xcd\x4c\xce\x56\x48\x2a\xca\x2f\xcf\x53\x48\xcb\xaf\x50\xc8\x2a\xcd\x2d\x28\x56\xc8\x2f\x4b\x2d\x52\x28\x01\x4a\xe7\x24\x56\x55\x2a\xa4\xe4\xa7\xeb\x29\xf8\x64\xe6\x95\x56\x28\xe4\xe7\x29\x24\x2a\x84\x84\x29\x72\x01\x00\xe7\xd1\x62\xec\x3c\x00\x00\x00", "The quick brown fox jumps over the lazy dog. Linux on a TV!\n");
}

test "80 KB of output wraps the 32 KB window" {
    var expected: [80000]u8 = undefined;
    for (&expected, 0..) |*b, i| b.* = "abcdefgh"[i % 8];
    try expectGunzip("\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\x03\xed\xc5\x31\x01\x00\x20\x08\x00\xb0\xac\x08\x08\xfd\x13\xf8\x1a\x62\x7b\x16\x27\xab\xef\x6c\xd8\xb6\x6d\xdb\xb6\x6d\xdb\xb6\x6d\xdb\xb6\x6d\xdb\xb6\x6d\xdb\xb6\x6d\xdb\xb6\x6d\xdb\xb6\x6d\xdb\xb6\x6d\xdb\xb6\x6d\xdb\xb6\x6d\xdb\xb6\x6d\xdb\xb6\x6d\xdb\xb6\x6d\xdb\xb6\x6d\xdb\xb6\x6d\xdb\xb6\x6d\xdb\xb6\x6d\xdb\xb6\x6d\xdb\xb6\x6d\xdb\xb6\x6d\xdb\xb6\x6d\xdb\xb6\x6d\xdb\xb6\x6d\xdb\xb6\x6d\xdb\xb6\x6d\xdb\xb6\x6d\xdb\xb6\x6d\xdb\xb6\x6d\xdb\xb6\x6d\xdb\xb6\x6d\xdb\xb6\x6d\xdb\xb6\x6d\xdb\xb6\x6d\xdb\xb6\x6d\xdb\xb6\x6d\xdb\xb6\x6d\xdb\xb6\x6d\xdb\xb6\xfd\xfd\x00\xd3\xff\x03\xde\x80\x38\x01\x00", &expected);
}
