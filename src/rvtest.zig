//! Runs riscv-tests ELF binaries (the "p" environment) on the RV64 core and prints PASS or FAIL
//! for each. A test reports through its `tohost` word: 1 means pass, (n << 1) | 1 means test n failed;
//! the "v" environment also prints through it (HTIF console writes, which the host must clear).
//! Usage: rvtest64 <elf>...

const std = @import("std");
const linux = std.os.linux;
const rv = @import("rv64.zig");

const ram_size = 16 << 20;

const Bus = struct {
    pub fn mmioLoad(_: Bus, _: u64, _: u8) ?u64 {
        return null;
    }
    pub fn mmioStore(_: Bus, _: u64, _: u8, _: u64) bool {
        return false;
    }
    pub fn externalIrq(_: Bus) u64 {
        return 0;
    }
    pub fn sbiPutchar(_: Bus, _: u8) void {}
    pub fn sbiGetchar(_: Bus) i64 {
        return -1;
    }
};

fn readFile(path: [*:0]const u8, dest: []u8) ![]u8 {
    const fd_rc = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(fd_rc) != .SUCCESS) return error.OpenFailed;
    const fd: i32 = @intCast(fd_rc);
    defer _ = linux.close(fd);
    var total: usize = 0;
    while (total < dest.len) {
        const n = linux.read(fd, dest[total..].ptr, dest.len - total);
        if (linux.errno(n) != .SUCCESS) return error.ReadFailed;
        if (n == 0) break;
        total += n;
    }
    return dest[0..total];
}

fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = linux.write(1, s.ptr, s.len);
}

fn rd(comptime T: type, elf: []const u8, off: u64) T {
    return std.mem.readInt(T, elf[@intCast(off)..][0..@sizeOf(T)], .little);
}

const Loaded = struct { entry: u64, tohost: u64 };

/// Copies the ELF's loadable segments into RAM and finds the `tohost` symbol.
fn loadElf(elf: []const u8, ram: []u8) !Loaded {
    if (!std.mem.eql(u8, elf[0..4], "\x7fELF") or elf[4] != 2) return error.NotElf64;
    const phoff = rd(u64, elf, 0x20);
    const shoff = rd(u64, elf, 0x28);
    const phnum = rd(u16, elf, 0x38);
    const shnum = rd(u16, elf, 0x3c);
    @memset(ram, 0);
    for (0..phnum) |i| {
        const ph = phoff + i * 56;
        if (rd(u32, elf, ph) != 1) continue; // PT_LOAD
        const off = rd(u64, elf, ph + 8);
        const paddr = rd(u64, elf, ph + 24);
        const filesz = rd(u64, elf, ph + 32);
        const dst = paddr - rv.ram_base;
        @memcpy(ram[@intCast(dst)..][0..@intCast(filesz)], elf[@intCast(off)..][0..@intCast(filesz)]);
    }
    var tohost: u64 = 0;
    for (0..shnum) |i| {
        const sh = shoff + i * 64;
        if (rd(u32, elf, sh + 4) != 2) continue; // SHT_SYMTAB
        const sym_off = rd(u64, elf, sh + 24);
        const sym_size = rd(u64, elf, sh + 32);
        const strtab = shoff + @as(u64, rd(u32, elf, sh + 40)) * 64;
        const str_off = rd(u64, elf, strtab + 24);
        var s: u64 = 0;
        while (s < sym_size) : (s += 24) {
            const name_off = str_off + rd(u32, elf, sym_off + s);
            const name = std.mem.sliceTo(elf[@intCast(name_off)..], 0);
            if (std.mem.eql(u8, name, "tohost")) tohost = rd(u64, elf, sym_off + s + 8);
        }
    }
    if (tohost == 0) return error.NoTohost;
    return .{ .entry = rd(u64, elf, 0x18), .tohost = tohost };
}

pub fn main(init: std.process.Init.Minimal) !u8 {
    const argv = init.args.vector;
    const ram = try std.heap.page_allocator.alloc(u8, ram_size);
    const file_buf = try std.heap.page_allocator.alloc(u8, 8 << 20);
    var hart: rv.Hart = undefined;
    var failed: u32 = 0;
    for (argv[1..]) |path| {
        const name = std.mem.sliceTo(path, 0);
        const elf = readFile(path, file_buf) catch {
            print("ERROR {s}: cannot read\n", .{name});
            failed += 1;
            continue;
        };
        const loaded = loadElf(elf, ram) catch |e| {
            print("ERROR {s}: {t}\n", .{ name, e });
            failed += 1;
            continue;
        };
        hart.reset(loaded.entry);
        const tohost_off: usize = @intCast(loaded.tohost - rv.ram_base);
        var result: u64 = 0;
        var rounds: u32 = 0;
        while (rounds < 4000) : (rounds += 1) {
            _ = rv.run(&hart, ram, Bus{}, 50_000, 10);
            result = std.mem.readInt(u64, ram[tohost_off..][0..8], .little);
            if (result >> 48 == 0x0101) { // HTIF console: device 1, command 1, low byte is a character
                _ = linux.write(1, &[_]u8{@truncate(result)}, 1);
                std.mem.writeInt(u64, ram[tohost_off..][0..8], 0, .little);
                result = 0;
                continue;
            }
            if (result != 0) break;
        }
        const base = if (std.mem.lastIndexOfScalar(u8, name, '/')) |i| name[i + 1 ..] else name;
        if (result == 1) {
            print("PASS {s}\n", .{base});
        } else {
            failed += 1;
            if (result == 0) {
                print("FAIL {s}: timed out at pc {x}\n", .{ base, hart.pc });
            } else {
                print("FAIL {s}: test {d}\n", .{ base, result >> 1 });
            }
        }
    }
    return if (failed == 0) 0 else 1;
}
