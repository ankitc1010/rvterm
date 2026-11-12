//! Native runner for the 64-bit machine: boots a Linux Image with an initrd in this terminal.
//! Usage: rvterm64-native <kernel Image> <initrd.cpio.gz>     (Ctrl-] quits when stdin is a terminal)

const std = @import("std");
const linux = std.os.linux;
const rv = @import("rv64.zig");
const m64 = @import("machine64.zig");

var out_buf: [4096]u8 = undefined;
var out_len: usize = 0;
var quit = false;
var in_eof = false;

const Out = struct {
    pub fn put(_: Out, c: u8) void {
        out_buf[out_len] = c;
        out_len += 1;
        if (out_len == out_buf.len) flush();
    }
};

fn flush() void {
    var off: usize = 0;
    while (off < out_len) {
        const rc = linux.write(1, out_buf[off..].ptr, out_len - off);
        if (linux.errno(rc) != .SUCCESS) break;
        off += rc;
    }
    out_len = 0;
}

fn nowMicros() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000 + @as(u64, @intCast(ts.nsec)) / 1000;
}

/// Moves whatever stdin has into the UART, waiting up to `timeout_ms` for it.
fn pollInput(dev: *m64.Devices, timeout_ms: i32) void {
    if (in_eof) {
        if (timeout_ms > 0) {
            const ts = linux.timespec{ .sec = 0, .nsec = @as(isize, timeout_ms) * 1_000_000 };
            _ = linux.nanosleep(&ts, null);
        }
        return;
    }
    if (dev.inputFree() < 512) return;
    var fds = [_]linux.pollfd{.{ .fd = 0, .events = linux.POLL.IN }};
    const rc = linux.poll(&fds, 1, timeout_ms);
    if (linux.errno(rc) != .SUCCESS or rc == 0) return;
    var buf: [512]u8 = undefined;
    const n = linux.read(0, &buf, buf.len);
    if (linux.errno(n) != .SUCCESS or n == 0) {
        in_eof = true;
        return;
    }
    for (buf[0..n]) |c| {
        if (c == 0x1d) quit = true; // Ctrl-]
        dev.pushInput(c);
    }
}

fn readFile(path: [*:0]const u8) ![]u8 {
    const fd_rc = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(fd_rc) != .SUCCESS) return error.OpenFailed;
    const fd: i32 = @intCast(fd_rc);
    defer _ = linux.close(fd);
    const size = linux.lseek(fd, 0, linux.SEEK.END);
    if (linux.errno(size) != .SUCCESS or linux.errno(linux.lseek(fd, 0, linux.SEEK.SET)) != .SUCCESS) return error.SeekFailed;
    const buf = try std.heap.page_allocator.alloc(u8, size);
    var total: usize = 0;
    while (total < buf.len) {
        const n = linux.read(fd, buf[total..].ptr, buf.len - total);
        if (linux.errno(n) != .SUCCESS or n == 0) return error.ReadFailed;
        total += n;
    }
    return buf;
}

fn eprint(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = linux.write(2, s.ptr, s.len);
}

pub fn main(init: std.process.Init.Minimal) !u8 {
    const argv = init.args.vector;
    if (argv.len < 3) {
        eprint("usage: {s} <kernel Image> <initrd.cpio.gz> [RAM in MB, default 256]\n", .{argv[0]});
        return 2;
    }
    const ram_mb = if (argv.len > 3) try std.fmt.parseInt(usize, std.mem.span(argv[3]), 10) else m64.default_ram_size >> 20;
    const ram = try std.heap.page_allocator.alloc(u8, ram_mb << 20); // fresh pages are zeroed
    const kernel = try readFile(argv[1]);
    const initrd = try readFile(argv[2]);
    var hart: rv.Hart = undefined;
    var dev = std.mem.zeroes(m64.Devices);
    var entropy: m64.Entropy = undefined;
    if (linux.getrandom(&entropy, entropy.len, 0) != entropy.len) return error.NoEntropy;
    m64.boot(&hart, &dev, ram, kernel, initrd, m64.default_bootargs, &entropy);
    const bus = m64.Bus(Out){ .dev = &dev, .out = .{} };

    var saved: linux.termios = undefined;
    const is_tty = linux.tcgetattr(0, &saved) == 0;
    if (is_tty) {
        var raw = saved;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        _ = linux.tcsetattr(0, .NOW, &raw);
    }
    defer if (is_tty) {
        _ = linux.tcsetattr(0, .NOW, &saved);
    };

    const start = nowMicros();
    var last = start;
    var busy_us: u64 = 0;
    var busy_instr: u64 = 0;
    var result: rv.Exit = .budget;
    while (!quit) {
        const now = nowMicros();
        const elapsed: u32 = @intCast(@min(now - last, 100_000));
        last = now;
        const before = hart.instret;
        result = rv.run(&hart, ram, bus, 200_000, elapsed);
        if (result == .budget) {
            busy_us += nowMicros() - now;
            busy_instr += hart.instret - before;
        }
        flush();
        switch (result) {
            .poweroff, .reboot => break,
            .idle => pollInput(&dev, @intCast(@min(rv.idleMicros(&hart) / 1000 + 1, 100))),
            .budget => pollInput(&dev, 0),
        }
    }
    const secs = @as(f64, @floatFromInt(nowMicros() - start)) / 1e6;
    eprint("\n[rvterm64] {s}: {d} instructions in {d:.2}s; {d:.0} MIPS while busy; pc {x}\n", .{
        @tagName(result), hart.instret, secs, @as(f64, @floatFromInt(busy_instr)) / @as(f64, @floatFromInt(@max(busy_us, 1))), hart.pc,
    });
    return 0;
}
