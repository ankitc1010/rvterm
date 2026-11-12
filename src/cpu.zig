//! RV32IMA hart plus the minimal machine that no-MMU Linux expects.
//!
//! Memory map (matches mini-rv32ima, so its prebuilt kernel and DTB boot unchanged):
//!   0x10000000  8250-style UART (THR/RBR at +0, LSR at +5)
//!   0x11004000  CLINT mtimecmp (lo, hi)
//!   0x1100bff8  CLINT mtime (lo, hi), 1 MHz
//!   0x11100000  syscon: write 0x5555 to power off, 0x7777 to reboot
//!   0x80000000  RAM
//!
//! Only machine and user mode exist; the kernel runs in M-mode and user programs in U-mode.

const std = @import("std");

pub const ram_base: u32 = 0x8000_0000;
pub const ram_size: u32 = 64 * 1024 * 1024;
pub const Ram = [ram_size]u8;
/// Where the device tree goes; the 64 MB DTB reports exactly the RAM below this as usable.
pub const dtb_offset: u32 = 0x3ffc000;

pub const Exit = enum(u32) { budget = 0, idle = 1, poweroff = 2, reboot = 3 };

/// Every field is plain data so the whole hart can be snapshotted as bytes.
pub const Hart = extern struct {
    x: [32]u32,
    pc: u32,
    priv: u32,
    mstatus: u32,
    mscratch: u32,
    mtvec: u32,
    mie: u32,
    mip: u32,
    mepc: u32,
    mtval: u32,
    mcause: u32,
    wfi: u32,
    reservation: u32,
    reservation_valid: u32,
    uart_lcr: u32,
    timer: u64,
    timer_match: u64,
    instret: u64,

    pub fn reset(h: *Hart, dtb_addr: u32) void {
        h.* = std.mem.zeroes(Hart);
        h.pc = ram_base;
        h.priv = 3;
        h.x[11] = dtb_addr; // a0 = hart id 0, a1 = device tree
    }
};

const mstatus_mie: u32 = 1 << 3;
const mstatus_mpie: u32 = 1 << 7;
const mstatus_mpp: u32 = 3 << 11;
const mip_mtip: u32 = 1 << 7;
const irq_timer: u32 = 0x8000_0007;

// Interrupts are only checked between chunks; a few thousand instructions of latency is invisible to Linux.
const chunk_len: u32 = 4096;

const Step = struct { count: u32, exit: Exit };

/// Runs up to `budget` instructions after advancing the timer by `elapsed_us`.
/// `bus` provides uartAvailable() bool, uartRead() u8 and uartWrite(u8).
pub fn run(h: *Hart, ram: *Ram, bus: anytype, budget: u32, elapsed_us: u32) Exit {
    h.timer +%= elapsed_us;
    updateTimer(h);
    if (h.wfi != 0) {
        if (h.mip & h.mie == 0) return .idle;
        h.wfi = 0;
    }
    var left = budget;
    while (left > 0) {
        if (interruptReady(h)) h.pc = trap(h, irq_timer, h.pc, 0);
        const r = execute(h, ram, bus, @min(left, chunk_len));
        left -= r.count;
        if (r.exit != .budget) return r.exit;
    }
    return .budget;
}

/// Microseconds until the timer interrupt fires; used to sleep while the guest idles.
pub fn idleMicros(h: *const Hart) u64 {
    if (h.timer_match == 0) return std.math.maxInt(u32);
    return h.timer_match -| h.timer;
}

fn updateTimer(h: *Hart) void {
    if (h.timer_match != 0 and h.timer >= h.timer_match) h.mip |= mip_mtip else h.mip &= ~mip_mtip;
}

fn interruptReady(h: *const Hart) bool {
    return h.mip & h.mie != 0 and (h.priv < 3 or h.mstatus & mstatus_mie != 0);
}

/// Enters the M-mode trap handler and returns the new pc.
fn trap(h: *Hart, cause: u32, epc: u32, tval: u32) u32 {
    h.mcause = cause;
    h.mtval = tval;
    h.mepc = epc;
    h.mstatus = (h.mstatus & ~(mstatus_mie | mstatus_mpie | mstatus_mpp)) |
        ((h.mstatus & mstatus_mie) << 4) | (h.priv << 11);
    h.priv = 3;
    h.reservation_valid = 0;
    const base = h.mtvec & ~@as(u32, 3);
    if (cause & 0x8000_0000 != 0 and h.mtvec & 1 != 0) return base +% 4 *% (cause & 0x7fff_ffff);
    return base;
}

inline fn ld(comptime T: type, ram: *Ram, off: u32) T {
    return std.mem.readInt(T, ram[off..][0..@sizeOf(T)], .little);
}

inline fn st(comptime T: type, ram: *Ram, off: u32, v: T) void {
    std.mem.writeInt(T, ram[off..][0..@sizeOf(T)], v, .little);
}

/// RAM offset for an access of `size` bytes, or null when the address is outside RAM.
inline fn ramOffset(addr: u32, comptime size: u32) ?u32 {
    const off = addr -% ram_base;
    return if (off <= ram_size - size) off else null;
}

inline fn isMmio(addr: u32) bool {
    return addr >= 0x1000_0000 and addr < 0x1200_0000;
}

fn mmioLoad(h: *Hart, bus: anytype, addr: u32) u32 {
    return switch (addr) {
        0x1000_0000 => if (bus.uartAvailable()) bus.uartRead() else 0,
        0x1000_0003 => h.uart_lcr,
        0x1000_0005 => 0x60 | @as(u32, @intFromBool(bus.uartAvailable())),
        0x1100_4000 => @truncate(h.timer_match),
        0x1100_4004 => @truncate(h.timer_match >> 32),
        0x1100_bff8 => @truncate(h.timer),
        0x1100_bffc => @truncate(h.timer >> 32),
        else => 0,
    };
}

fn mmioStore(h: *Hart, bus: anytype, addr: u32, v: u32) Exit {
    switch (addr) {
        // With LCR.DLAB set, offset 0 is the baud divisor, not data.
        0x1000_0000 => if (h.uart_lcr & 0x80 == 0) bus.uartWrite(@truncate(v)),
        0x1000_0003 => h.uart_lcr = v & 0xff,
        0x1100_4000 => h.timer_match = (h.timer_match & 0xffff_ffff_0000_0000) | v,
        0x1100_4004 => h.timer_match = (h.timer_match & 0xffff_ffff) | (@as(u64, v) << 32),
        0x1100_bff8 => h.timer = (h.timer & 0xffff_ffff_0000_0000) | v,
        0x1100_bffc => h.timer = (h.timer & 0xffff_ffff) | (@as(u64, v) << 32),
        0x1110_0000 => return switch (v) {
            0x5555 => .poweroff,
            0x7777 => .reboot,
            else => .budget,
        },
        else => {},
    }
    updateTimer(h);
    return .budget;
}

fn csrRead(h: *const Hart, csr: u32) u32 {
    return switch (csr) {
        0x300 => h.mstatus,
        0x301 => 0x4000_1101, // RV32 with I, M, A
        0x304 => h.mie,
        0x305 => h.mtvec,
        0x340 => h.mscratch,
        0x341 => h.mepc,
        0x342 => h.mcause,
        0x343 => h.mtval,
        0x344 => h.mip,
        0xc00, 0xc02, 0xb00, 0xb02 => @truncate(h.instret),
        0xc80, 0xc82, 0xb80, 0xb82 => @truncate(h.instret >> 32),
        0xc01 => @truncate(h.timer),
        0xc81 => @truncate(h.timer >> 32),
        else => 0, // mhartid, mvendorid, PMP and anything unimplemented read as zero
    };
}

fn csrWrite(h: *Hart, csr: u32, v: u32) void {
    switch (csr) {
        0x300 => h.mstatus = v,
        0x304 => h.mie = v,
        0x305 => h.mtvec = v,
        0x340 => h.mscratch = v,
        0x341 => h.mepc = v,
        0x342 => h.mcause = v,
        0x343 => h.mtval = v,
        else => {}, // mip is driven by the timer; other writes are ignored
    }
}

inline fn sext(v: u32, comptime bits: u5) u32 {
    const shift: u5 = 31 - (bits - 1);
    return @bitCast(@as(i32, @bitCast(v << shift)) >> shift);
}

fn execute(h: *Hart, ram: *Ram, bus: anytype, count: u32) Step {
    var pc = h.pc;
    var n: u32 = 0;
    var exit: Exit = .budget;
    while (n < count) : (n += 1) {
        const fetch_off = ramOffset(pc, 4) orelse {
            pc = trap(h, 1, pc, pc);
            continue;
        };
        const ir = ld(u32, ram, fetch_off);
        const rd = (ir >> 7) & 31;
        const rs1 = h.x[(ir >> 15) & 31];
        const rs2 = h.x[(ir >> 20) & 31];
        const funct3 = (ir >> 12) & 7;
        var val: u32 = 0;
        var write_rd = true;
        var next = pc +% 4;

        switch (ir & 0x7f) {
            0x37 => val = ir & 0xffff_f000, // LUI
            0x17 => val = pc +% (ir & 0xffff_f000), // AUIPC
            0x6f => { // JAL
                const imm = sext(((ir >> 11) & 0x10_0000) | (ir & 0xf_f000) | ((ir >> 9) & 0x800) | ((ir >> 20) & 0x7fe), 21);
                val = next;
                next = pc +% imm;
            },
            0x67 => { // JALR
                val = next;
                next = (rs1 +% sext(ir >> 20, 12)) & ~@as(u32, 1);
            },
            0x63 => { // BRANCH
                write_rd = false;
                const taken = switch (funct3) {
                    0 => rs1 == rs2,
                    1 => rs1 != rs2,
                    4 => @as(i32, @bitCast(rs1)) < @as(i32, @bitCast(rs2)),
                    5 => @as(i32, @bitCast(rs1)) >= @as(i32, @bitCast(rs2)),
                    6 => rs1 < rs2,
                    7 => rs1 >= rs2,
                    else => {
                        pc = trap(h, 2, pc, ir);
                        continue;
                    },
                };
                if (taken) next = pc +% sext(((ir >> 19) & 0x1000) | ((ir << 4) & 0x800) | ((ir >> 20) & 0x7e0) | ((ir >> 7) & 0x1e), 13);
            },
            0x03 => { // LOAD
                const addr = rs1 +% sext(ir >> 20, 12);
                if (ramOffset(addr, 4)) |off| {
                    val = switch (funct3) {
                        0 => sext(ram[off], 8),
                        1 => sext(ld(u16, ram, off), 16),
                        2 => ld(u32, ram, off),
                        4 => ram[off],
                        5 => ld(u16, ram, off),
                        else => {
                            pc = trap(h, 2, pc, ir);
                            continue;
                        },
                    };
                } else if (ramOffset(addr, 1) != null) {
                    // Within the last 3 bytes of RAM: only byte loads fit.
                    const off = addr -% ram_base;
                    val = switch (funct3) {
                        0 => sext(ram[off], 8),
                        4 => ram[off],
                        else => {
                            pc = trap(h, 5, pc, addr);
                            continue;
                        },
                    };
                } else if (isMmio(addr)) {
                    const raw = mmioLoad(h, bus, addr);
                    val = switch (funct3) {
                        0 => sext(raw & 0xff, 8),
                        1 => sext(raw & 0xffff, 16),
                        4 => raw & 0xff,
                        5 => raw & 0xffff,
                        else => raw,
                    };
                } else {
                    pc = trap(h, 5, pc, addr);
                    continue;
                }
            },
            0x23 => { // STORE
                write_rd = false;
                const addr = rs1 +% sext(((ir >> 20) & 0xfe0) | ((ir >> 7) & 0x1f), 12);
                const fits = switch (funct3) {
                    0 => ramOffset(addr, 1),
                    1 => ramOffset(addr, 2),
                    2 => ramOffset(addr, 4),
                    else => {
                        pc = trap(h, 2, pc, ir);
                        continue;
                    },
                };
                if (fits) |off| {
                    switch (funct3) {
                        0 => ram[off] = @truncate(rs2),
                        1 => st(u16, ram, off, @truncate(rs2)),
                        else => st(u32, ram, off, rs2),
                    }
                } else if (isMmio(addr)) {
                    exit = mmioStore(h, bus, addr, rs2);
                    if (exit != .budget) {
                        pc = next;
                        n += 1;
                        break;
                    }
                } else {
                    pc = trap(h, 7, pc, addr);
                    continue;
                }
            },
            0x13, 0x33 => { // OP-IMM, OP
                const is_reg = ir & 0x20 != 0;
                const b = if (is_reg) rs2 else sext(ir >> 20, 12);
                const sh: u5 = @truncate(b);
                if (is_reg and ir >> 25 == 1) {
                    val = mulDiv(funct3, rs1, rs2);
                } else {
                    const alt = ir & 0x4000_0000 != 0;
                    val = switch (funct3) {
                        0 => if (is_reg and alt) rs1 -% b else rs1 +% b,
                        1 => rs1 << sh,
                        2 => @intFromBool(@as(i32, @bitCast(rs1)) < @as(i32, @bitCast(b))),
                        3 => @intFromBool(rs1 < b),
                        4 => rs1 ^ b,
                        5 => if (alt) @bitCast(@as(i32, @bitCast(rs1)) >> sh) else rs1 >> sh,
                        6 => rs1 | b,
                        else => rs1 & b,
                    };
                }
            },
            0x0f => write_rd = false, // FENCE, FENCE.I
            0x73 => { // SYSTEM
                if (funct3 == 0) {
                    write_rd = false;
                    switch (ir) {
                        0x0000_0073 => { // ECALL
                            pc = trap(h, if (h.priv == 3) 11 else 8, pc, 0);
                            continue;
                        },
                        0x0010_0073 => { // EBREAK
                            pc = trap(h, 3, pc, pc);
                            continue;
                        },
                        0x3020_0073 => { // MRET
                            if (h.priv != 3) {
                                pc = trap(h, 2, pc, ir);
                                continue;
                            }
                            const mpp = (h.mstatus >> 11) & 3;
                            const mpie = (h.mstatus >> 7) & 1;
                            h.mstatus = (h.mstatus & ~(mstatus_mie | mstatus_mpp)) | (mpie << 3) | mstatus_mpie;
                            h.priv = if (mpp == 3) 3 else 0;
                            next = h.mepc;
                        },
                        0x1050_0073 => { // WFI
                            if (h.mip & h.mie == 0) {
                                h.wfi = 1;
                                pc = next;
                                n += 1;
                                exit = .idle;
                                break;
                            }
                        },
                        else => if (ir >> 25 != 0x09) { // SFENCE.VMA is a no-op without an MMU
                            pc = trap(h, 2, pc, ir);
                            continue;
                        },
                    }
                } else {
                    const csr = ir >> 20;
                    // U-mode may only read the user counters (csr[9:8] == 0).
                    if (funct3 == 4 or (h.priv == 0 and (csr >> 8) & 3 != 0)) {
                        pc = trap(h, 2, pc, ir);
                        continue;
                    }
                    const src = if (funct3 & 4 != 0) (ir >> 15) & 31 else rs1;
                    const old = csrRead(h, csr);
                    switch (funct3 & 3) {
                        1 => csrWrite(h, csr, src),
                        2 => if ((ir >> 15) & 31 != 0) csrWrite(h, csr, old | src),
                        else => if ((ir >> 15) & 31 != 0) csrWrite(h, csr, old & ~src),
                    }
                    val = old;
                }
            },
            0x2f => { // AMO
                const off = (if (funct3 == 2) ramOffset(rs1, 4) else null) orelse {
                    pc = trap(h, if (funct3 == 2) 7 else 2, pc, if (funct3 == 2) rs1 else ir);
                    continue;
                };
                const old = ld(u32, ram, off);
                const funct5 = ir >> 27;
                switch (funct5) {
                    0x02 => { // LR.W
                        h.reservation = rs1;
                        h.reservation_valid = 1;
                        val = old;
                    },
                    0x03 => { // SC.W
                        const ok = h.reservation_valid != 0 and h.reservation == rs1;
                        if (ok) st(u32, ram, off, rs2);
                        h.reservation_valid = 0;
                        val = @intFromBool(!ok);
                    },
                    else => {
                        const new: u32 = switch (funct5) {
                            0x01 => rs2,
                            0x00 => old +% rs2,
                            0x04 => old ^ rs2,
                            0x0c => old & rs2,
                            0x08 => old | rs2,
                            0x10 => if (@as(i32, @bitCast(old)) < @as(i32, @bitCast(rs2))) old else rs2,
                            0x14 => if (@as(i32, @bitCast(old)) > @as(i32, @bitCast(rs2))) old else rs2,
                            0x18 => @min(old, rs2),
                            0x1c => @max(old, rs2),
                            else => {
                                pc = trap(h, 2, pc, ir);
                                continue;
                            },
                        };
                        st(u32, ram, off, new);
                        val = old;
                    },
                }
            },
            else => {
                pc = trap(h, 2, pc, ir);
                continue;
            },
        }

        if (write_rd and rd != 0) h.x[rd] = val;
        pc = next;
    }
    h.pc = pc;
    h.instret +%= n;
    return .{ .count = n, .exit = exit };
}

fn mulDiv(funct3: u32, a: u32, b: u32) u32 {
    const sa: i32 = @bitCast(a);
    const sb: i32 = @bitCast(b);
    return switch (funct3) {
        0 => a *% b,
        1 => @truncate(@as(u64, @bitCast(@as(i64, sa) * @as(i64, sb))) >> 32),
        2 => @truncate(@as(u64, @bitCast(@as(i64, sa) * @as(i64, b))) >> 32),
        3 => @truncate((@as(u64, a) * @as(u64, b)) >> 32),
        4 => if (b == 0) 0xffff_ffff else if (sa == std.math.minInt(i32) and sb == -1) a else @bitCast(@divTrunc(sa, sb)),
        5 => if (b == 0) 0xffff_ffff else a / b,
        6 => if (b == 0) a else if (sa == std.math.minInt(i32) and sb == -1) 0 else @bitCast(@rem(sa, sb)),
        else => if (b == 0) a else a % b,
    };
}

// ---------------------------------------------------------------------------
// Tests: tiny hand-assembled programs.

const TestBus = struct {
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    pub fn uartAvailable(_: TestBus) bool {
        return false;
    }
    pub fn uartRead(_: TestBus) u8 {
        return 0;
    }
    pub fn uartWrite(b: TestBus, c: u8) void {
        b.out.append(b.gpa, c) catch unreachable;
    }
};

fn testMachine(program: []const u32) !struct { h: Hart, ram: *Ram } {
    const ram = try std.testing.allocator.create(Ram);
    @memset(ram, 0);
    for (program, 0..) |word, i| st(u32, ram, @intCast(i * 4), word);
    var h: Hart = undefined;
    h.reset(0);
    return .{ .h = h, .ram = ram };
}

test "arithmetic, mul/div edge cases and branches" {
    // li a0,-7; li a1,2; div a2,a0,a1; rem a3,a0,a1; mulh a4,a0,a1; divu a5,a0,x0; blt a0,a1,+8; li a6,1; li a7,9; wfi
    var m = try testMachine(&.{ 0xff900513, 0x00200593, 0x02b54633, 0x02b566b3, 0x02b51733, 0x020557b3, 0x00b54463, 0x00100813, 0x00900893, 0x10500073 });
    defer std.testing.allocator.destroy(m.ram);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    const exit = run(&m.h, m.ram, TestBus{ .out = &out, .gpa = std.testing.allocator }, 100, 0);
    try std.testing.expectEqual(Exit.idle, exit);
    try std.testing.expectEqual(@as(u32, @bitCast(@as(i32, -3))), m.h.x[12]);
    try std.testing.expectEqual(@as(u32, @bitCast(@as(i32, -1))), m.h.x[13]);
    try std.testing.expectEqual(@as(u32, 0xffffffff), m.h.x[14]);
    try std.testing.expectEqual(@as(u32, 0xffffffff), m.h.x[15]);
    try std.testing.expectEqual(@as(u32, 0), m.h.x[16]); // skipped by the taken branch
    try std.testing.expectEqual(@as(u32, 9), m.h.x[17]);
}

test "uart output, timer interrupt and mret" {
    // 0x00: lui t0,0x10000; li t1,'A'; sb t1,0(t0)
    // 0x0c: la-ish: auipc t2,0; addi t2,t2,40 (handler at 0x34); csrw mtvec,t2
    // 0x18: lui t3,0x11004; li t4,5; sw t4,0(t3)  (mtimecmp = 5)
    // 0x24: li t5,128; csrw mie,t5; csrsi mstatus,8
    // 0x30: wfi
    // 0x34 handler: li t1,'T'; sb t1,0(t0); csrw mie,zero; wfi
    // (Encodings checked against `zig cc -target riscv32-freestanding`.)
    var m = try testMachine(&.{
        0x100002b7, 0x04100313, 0x00628023,
        0x00000397, 0x02838393, 0x30539073,
        0x11004e37, 0x00500e93, 0x01de2023,
        0x08000f13, 0x304f1073, 0x30046073,
        0x10500073,
        0x05400313, 0x00628023, 0x30401073,
        0x10500073,
    });
    defer std.testing.allocator.destroy(m.ram);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    const bus = TestBus{ .out = &out, .gpa = std.testing.allocator };
    try std.testing.expectEqual(Exit.idle, run(&m.h, m.ram, bus, 100, 0));
    try std.testing.expectEqualStrings("A", out.items);
    try std.testing.expectEqual(@as(u64, 5), idleMicros(&m.h));
    try std.testing.expectEqual(Exit.idle, run(&m.h, m.ram, bus, 100, 5));
    try std.testing.expectEqualStrings("AT", out.items);
    try std.testing.expectEqual(irq_timer, m.h.mcause);
    try std.testing.expectEqual(ram_base + 0x34, m.h.mepc); // the instruction after the first WFI
}
