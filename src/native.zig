//! Native runner: boots the kernel in this terminal, for debugging the emulator and measuring speed.
//! Usage: rvterm-native <kernel Image> <dtb>     (Ctrl-] quits when stdin is a terminal)

const std = @import("std");
const linux = std.os.linux;
const cpu = @import("cpu.zig");

var in_buf: [4096]u8 = undefined;
var in_len: usize = 0;
var in_pos: usize = 0;
var in_eof = false;
var quit = false;
var out_buf: [4096]u8 = undefined;
var out_len: usize = 0;

const Bus = struct {
    pub fn uartAvailable(_: Bus) bool {
        return in_pos < in_len;
    }
    pub fn uartRead(_: Bus) u8 {
        in_pos += 1;
        return in_buf[in_pos - 1];
    }
    pub fn uartWrite(_: Bus, c: u8) void {
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

/// Waits up to `timeout_ms` for stdin, unless unread input is still queued.
fn pollInput(timeout_ms: i32) void {
    if (in_pos < in_len) return;
    if (in_eof) {
        if (timeout_ms > 0) {
            const ts = linux.timespec{ .sec = 0, .nsec = @as(isize, timeout_ms) * 1_000_000 };
            _ = linux.nanosleep(&ts, null);
        }
        return;
    }
    var fds = [_]linux.pollfd{.{ .fd = 0, .events = linux.POLL.IN }};
    const rc = linux.poll(&fds, 1, timeout_ms);
    if (linux.errno(rc) != .SUCCESS or rc == 0) return;
    const n = linux.read(0, &in_buf, in_buf.len);
    if (linux.errno(n) != .SUCCESS or n == 0) {
        in_eof = true;
        return;
    }
    in_len = n;
    in_pos = 0;
    if (std.mem.indexOfScalar(u8, in_buf[0..n], 0x1d) != null) quit = true; // Ctrl-]
}

fn readFile(path: [*:0]const u8, dest: []u8) !usize {
    const fd_rc = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(fd_rc) != .SUCCESS) return error.OpenFailed;
    const fd: i32 = @intCast(fd_rc);
    defer _ = linux.close(fd);
    var total: usize = 0;
    while (total < dest.len) {
        const n = linux.read(fd, dest[total..].ptr, dest.len - total);
        if (linux.errno(n) != .SUCCESS) return error.ReadFailed;
        if (n == 0) return total;
        total += n;
    }
    return error.FileTooLarge;
}

fn eprint(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = linux.write(2, s.ptr, s.len);
}

pub fn main(init: std.process.Init.Minimal) !u8 {
    const argv = init.args.vector;
    if (argv.len < 3) {
        eprint("usage: {s} <kernel Image> <dtb>\n", .{argv[0]});
        return 2;
    }
    const mem = try std.heap.page_allocator.alloc(u8, cpu.ram_size); // fresh pages are zeroed
    const ram: *cpu.Ram = mem[0..cpu.ram_size];
    _ = try readFile(argv[1], ram[0..cpu.dtb_offset]);
    _ = try readFile(argv[2], ram[cpu.dtb_offset..]);

    var hart: cpu.Hart = undefined;
    hart.reset(cpu.ram_base + cpu.dtb_offset);

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
    var result: cpu.Exit = .budget;
    var busy_us: u64 = 0;
    var busy_instr: u64 = 0;
    while (!quit) {
        const now = nowMicros();
        const elapsed: u32 = @intCast(@min(now - last, 100_000));
        last = now;
        const before = hart.instret;
        result = cpu.run(&hart, ram, Bus{}, 200_000, elapsed);
        if (result == .budget) {
            busy_us += nowMicros() - now;
            busy_instr += hart.instret - before;
        }
        flush();
        switch (result) {
            .poweroff, .reboot => break,
            .idle => pollInput(@intCast(@min(cpu.idleMicros(&hart) / 1000 + 1, 100))),
            .budget => pollInput(0),
        }
    }
    const secs = @as(f64, @floatFromInt(nowMicros() - start)) / 1e6;
    eprint("\n[rvterm] {s}: {d} instructions in {d:.2}s; {d:.0} MIPS while busy\n", .{
        @tagName(result), hart.instret, secs, @as(f64, @floatFromInt(busy_instr)) / @as(f64, @floatFromInt(@max(busy_us, 1))),
    });
    return 0;
}
