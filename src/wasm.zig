//! WebAssembly entry points, for either machine (chosen at build time by `machine64`):
//!   32-bit: cpu.zig, RV32IMA without an MMU, running a no-MMU Linux + BusyBox (the small one)
//!   64-bit: rv64.zig + machine64.zig, RV64GC with Sv39, running Alpine Linux
//! The emulator, its UART input queue and the terminal grid all live in linear memory: guest output
//! goes straight into the terminal without crossing into JS. The page writes key bytes into
//! `input`, calls run(), then redraws the rows marked dirty.

const std = @import("std");
const options = @import("build_options");
const is64 = options.machine64;
const cpu = if (is64) @import("rv64.zig") else @import("cpu.zig");
const m64 = @import("machine64.zig");
const vt_mod = @import("vt.zig");
const inflate = @import("inflate.zig");

pub const panic = std.debug.no_panic;

const ram_size: u32 = if (is64) @as(u32, options.ram_mb) << 20 else cpu.ram_size;
const ring_len = 4096;

/// The 32-bit machine's UART is just an input queue; the 64-bit one has full device state.
const Ring32 = extern struct {
    in_head: u32,
    in_tail: u32,
    in_ring: [ring_len]u8,

    fn inputAvailable(d: *const Ring32) bool {
        return d.in_head != d.in_tail;
    }
    fn inputFree(d: *const Ring32) u32 {
        return ring_len - (d.in_head -% d.in_tail);
    }
    fn pushInput(d: *Ring32, c: u8) void {
        if (d.inputFree() == 0) return;
        d.in_ring[d.in_head % ring_len] = c;
        d.in_head +%= 1;
    }
    fn popInput(d: *Ring32) u8 {
        const c = d.in_ring[d.in_tail % ring_len];
        d.in_tail +%= 1;
        return c;
    }
};

/// Everything except RAM; snapshots save this struct as raw bytes.
const Machine = extern struct {
    hart: cpu.Hart,
    dev: if (is64) m64.Devices else Ring32,
    out_count: u32, // bytes the guest has written, wrapping
    log_len: u32,
    log: [8192]u8, // raw guest output, read by the snapshot tool
    vt: vt_mod.Vt,
};

var ram: [ram_size]u8 align(16) = undefined;
var machine: Machine = undefined;
var input: [256]u8 = undefined;

/// Guest console output: curl frames to the page, everything else to the terminal.
fn output(c: u8) void {
    machine.out_count +%= 1;
    hostFilter(c);
    if (machine.log_len < machine.log.len) {
        machine.log[machine.log_len] = c;
        machine.log_len += 1;
    }
}

const Out = struct {
    pub inline fn put(_: Out, c: u8) void {
        output(c);
    }
};

const Bus32 = struct {
    pub inline fn uartAvailable(_: Bus32) bool {
        return machine.dev.inputAvailable();
    }
    pub inline fn uartRead(_: Bus32) u8 {
        return machine.dev.popInput();
    }
    pub inline fn uartWrite(_: Bus32, c: u8) void {
        output(c);
    }
};

fn bus() if (is64) m64.Bus(Out) else Bus32 {
    return if (is64) .{ .dev = &machine.dev, .out = .{} } else .{};
}

// Host requests. The guest has no network card, so programs like curl write a frame
// ESC ] 7777 ; <base64> BEL to the console. It is kept out of the terminal and handed to the page,
// which performs the request with the browser's fetch() and types the reply back.
const host_prefix = "\x1b]7777;";
var host_match: usize = 0; // bytes of host_prefix seen so far (held back from the terminal)
var host_capturing = false;
var host_ready = false;
var host_len: u32 = 0;
var host_buf: [1 << 20]u8 = undefined;

fn hostFilter(c: u8) void {
    if (host_capturing) {
        if (c == 0x07) {
            host_capturing = false;
            host_ready = true;
        } else if (host_len < host_buf.len) {
            host_buf[host_len] = c;
            host_len += 1;
        }
        return;
    }
    if (c == host_prefix[host_match]) {
        host_match += 1;
        if (host_match == host_prefix.len) {
            host_match = 0;
            host_capturing = true;
            host_ready = false;
            host_len = 0;
        }
        return;
    }
    // Not a host frame after all: the terminal gets what was held back.
    for (host_prefix[0..host_match]) |p| machine.vt.feed(p);
    host_match = 0;
    if (c == host_prefix[0]) {
        host_match = 1;
        return;
    }
    machine.vt.feed(c);
}

/// Length of a complete host request, or 0 if none is waiting.
export fn host_request_len() u32 {
    return if (host_ready) host_len else 0;
}
export fn host_request_ptr() [*]u8 {
    return &host_buf;
}
export fn host_request_done() void {
    host_ready = false;
    host_len = 0;
}

fn pushByte(c: u8) void {
    machine.dev.pushInput(c);
}

/// Clears RAM and the machine; the caller then loads a kernel or copies in a snapshot.
export fn reset(cols: u32, rows: u32) void {
    @memset(&ram, 0);
    @memset(std.mem.asBytes(&machine), 0);
    machine.hart.reset(if (is64) cpu.ram_base else cpu.ram_base + cpu.dtb_offset);
    machine.vt.init(cols, rows);
}

/// 64-bit only: where the snapshot tool copies the kernel and an initrd of `len` bytes, and the
/// call that then builds the device tree and starts the kernel.
export fn kernel_offset() u32 {
    return if (is64) m64.kernel_offset else 0;
}
export fn initrd_offset(len: u32) u32 {
    return if (is64) @intCast(m64.initrdOffset(ram_size, len)) else 0;
}
export fn boot_linux(initrd_len: u32) void {
    if (is64) m64.bootPlaced(&machine.hart, &machine.dev, &ram, initrd_len, "console=ttyS0 rdinit=/init quiet", &entropy);
}

/// 64-bit only: the page fills this with random bytes (crypto.getRandomValues) before each
/// boot_linux() and restore_snapshot(). Booting seeds Linux's random number generator with it; a
/// restore hands the guest a new VM generation ID, so every copy of a snapshot reseeds instead of
/// replaying the same "random" numbers.
var entropy: m64.Entropy = @splat(0);
export fn entropy_ptr() [*]u8 {
    return &entropy;
}

// Snapshot restore, done here with the small decoder in inflate.zig rather than in JS, so it
// works on engines without DecompressionStream (Chromium < 80).
// Format (gzipped), written by tools/mksnapshot.mjs:
//   "RVSNAP03", u32 machine_len, u32 ram_len, u32 unique_count, u32 map_count, the machine bytes,
//   map_count records of (u32 page index, u32 unique page) sorted by unique page, then the unique
//   4 KB pages in order. The map comes first so each page inflates straight into RAM.
const page_len = 4096;
const max_pages = ram_size / page_len;

var snapshot: []u8 = &.{}; // the compressed snapshot, kept for reboots
var page_map: [max_pages][2]u32 = undefined;
var window: [32768]u8 = undefined;

/// Grows linear memory to hold a compressed snapshot of `len` bytes; the page copies it there.
export fn snapshot_buffer(len: u32) ?[*]u8 {
    if (len > snapshot.len) {
        const old_pages = @wasmMemoryGrow(0, (len + 65535) / 65536);
        if (old_pages < 0) return null;
        snapshot = @as([*]u8, @ptrFromInt(@as(usize, @intCast(old_pages)) * 65536))[0..len];
    }
    snapshot.len = len;
    return snapshot.ptr;
}

/// Returns 0 on success, 1 for a damaged snapshot, 2 when it was made by a different build.
export fn restore_snapshot() u32 {
    restore() catch |err| return switch (err) {
        error.WrongBuild => 2,
        else => 1,
    };
    return 0;
}

fn restore() !void {
    @memset(&ram, 0);
    inflate.init();
    var r: Restorer = .{};
    try inflate.gunzip(snapshot, &window, &r);
    if (!r.complete()) return error.Damaged;
    if (is64) {
        cpu.flushTlb(); // cached translations belong to whatever ran before
        machine.dev.newGeneration(entropy[48..64].*);
    }
}

fn ramPage(index: u32) !*[page_len]u8 {
    if (index >= max_pages) return error.Damaged;
    return ram[index * page_len ..][0..page_len];
}

/// Receives the decompressed snapshot in order and puts each part where it belongs.
const Restorer = struct {
    pos: usize = 0,
    header: [24]u8 = undefined,
    map_end: usize = 0, // where the page data starts
    unique_count: u32 = 0,
    map_count: u32 = 0,
    cursor: u32 = 0, // first map record of the unique page being received

    const machine_end = 24 + @sizeOf(Machine);

    pub fn write(r: *Restorer, bytes: []const u8) !void {
        var rest = bytes;
        while (rest.len > 0) {
            const n = try r.take(rest);
            r.pos += n;
            rest = rest[n..];
        }
    }

    fn take(r: *Restorer, bytes: []const u8) !usize {
        if (r.pos < 24) {
            const n = @min(bytes.len, 24 - r.pos);
            @memcpy(r.header[r.pos..][0..n], bytes[0..n]);
            if (r.pos + n == 24) try r.checkHeader();
            return n;
        }
        if (r.pos < machine_end) {
            const n = @min(bytes.len, machine_end - r.pos);
            @memcpy(std.mem.asBytes(&machine)[r.pos - 24 ..][0..n], bytes[0..n]);
            return n;
        }
        if (r.pos < r.map_end) {
            const n = @min(bytes.len, r.map_end - r.pos);
            @memcpy(std.mem.sliceAsBytes(page_map[0..r.map_count])[r.pos - machine_end ..][0..n], bytes[0..n]);
            return n;
        }
        // Unique pages arrive in order; each lands in its first map record's RAM page.
        const k = (r.pos - r.map_end) / page_len;
        const in_page = (r.pos - r.map_end) % page_len;
        if (k >= r.unique_count or r.cursor >= r.map_count or page_map[r.cursor][1] != k) return error.Damaged;
        const first = try ramPage(page_map[r.cursor][0]);
        const n = @min(bytes.len, page_len - in_page);
        @memcpy(first[in_page..][0..n], bytes[0..n]);
        if (in_page + n == page_len) {
            r.cursor += 1;
            while (r.cursor < r.map_count and page_map[r.cursor][1] == k) : (r.cursor += 1) {
                @memcpy(try ramPage(page_map[r.cursor][0]), first);
            }
        }
        return n;
    }

    fn field(r: *const Restorer, i: usize) u32 {
        return std.mem.readInt(u32, r.header[i..][0..4], .little);
    }

    fn checkHeader(r: *Restorer) !void {
        if (!std.mem.eql(u8, r.header[0..8], "RVSNAP03")) return error.Damaged;
        if (r.field(8) != @sizeOf(Machine) or r.field(12) != ram_size) return error.WrongBuild;
        r.unique_count = r.field(16);
        r.map_count = r.field(20);
        if (r.map_count > max_pages) return error.Damaged;
        r.map_end = machine_end + @as(usize, r.map_count) * 8;
    }

    fn complete(r: *const Restorer) bool {
        return r.map_end != 0 and r.cursor == r.map_count and r.pos == r.map_end + @as(usize, r.unique_count) * page_len;
    }
};

/// Returns 0 when the budget ran out, 1 when the guest is idle, 2 on power off, 3 on reboot.
export fn run(budget: u32, elapsed_us: u32) u32 {
    const exit = cpu.run(&machine.hart, &ram, bus(), budget, elapsed_us);
    // Replies to terminal queries (cursor position etc.) go back to the guest as input.
    const vt = &machine.vt;
    for (vt.resp[0..vt.resp_len]) |c| pushByte(c);
    vt.resp_len = 0;
    return @intFromEnum(exit);
}

export fn idle_us() u32 {
    return @intCast(@min(cpu.idleMicros(&machine.hart), std.math.maxInt(u32)));
}

export fn push_input(len: u32) void {
    for (input[0..@min(len, input.len)]) |c| pushByte(c);
}

/// Bytes the guest has not read from the UART yet.
export fn input_pending() u32 {
    return ring_len - machine.dev.inputFree();
}

export fn input_free() u32 {
    return machine.dev.inputFree();
}

export fn out_count() u32 {
    return machine.out_count;
}

export fn input_ptr() [*]u8 {
    return &input;
}
export fn ram_ptr() [*]u8 {
    return &ram;
}
export fn ram_len() u32 {
    return ram_size;
}
export fn dtb_offset() u32 {
    return if (is64) 0 else cpu.dtb_offset;
}
export fn machine_ptr() [*]u8 {
    return @ptrCast(&machine);
}
export fn machine_len() u32 {
    return @sizeOf(Machine);
}
export fn instret() f64 {
    return @floatFromInt(machine.hart.instret);
}
export fn log_ptr() [*]u8 {
    return &machine.log;
}
export fn log_len() u32 {
    return machine.log_len;
}
export fn log_clear() void {
    machine.log_len = 0;
}

export fn vt_cells() [*]u8 {
    return @ptrCast(&machine.vt.screen);
}
export fn vt_stride() u32 {
    return vt_mod.max_cols;
}
export fn vt_cols() u32 {
    return machine.vt.cols;
}
export fn vt_rows() u32 {
    return machine.vt.rows;
}
export fn vt_dirty() [*]u8 {
    return &machine.vt.dirty;
}
/// Cursor packed as x | y << 8 | visible << 16.
export fn vt_cursor() u32 {
    const vt = &machine.vt;
    return vt.x | (vt.y << 8) | (@as(u32, @intFromBool(vt.modes & vt_mod.mode_cursor_visible != 0)) << 16);
}
export fn vt_take_scroll() u32 {
    defer machine.vt.scroll_pending = 0;
    return machine.vt.scroll_pending;
}
export fn vt_app_cursor() u32 {
    return @intFromBool(machine.vt.modes & vt_mod.mode_app_cursor != 0);
}
