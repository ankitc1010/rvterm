//! RV64GC hart: RV64IMAFDC with Zicsr, Zifencei and Sstc; machine, supervisor and user modes;
//! Sv39 paging with hardware A/D updates. With `sbi` set, ecalls from S-mode are answered by a
//! built-in SBI, so a Linux kernel can start in S-mode without any M-mode firmware.
//!
//! Devices are reached through `bus` (anytype):
//!   mmioLoad(pa: u64, size: u8) ?u64        null means an access fault
//!   mmioStore(pa: u64, size: u8, v: u64) bool
//!   externalIrq() u64                       MEIP/SEIP bits from the interrupt controller
//!   sbiPutchar(c: u8) void, sbiGetchar() i64

const std = @import("std");

pub const ram_base: u64 = 0x8000_0000;

pub const Exit = enum(u32) { budget = 0, idle = 1, poweroff = 2, reboot = 3 };

/// Plain data only, so the hart can be snapshotted as bytes.
pub const Hart = extern struct {
    x: [32]u64,
    f: [32]u64,
    pc: u64,
    priv: u64,
    mstatus: u64,
    medeleg: u64,
    mideleg: u64,
    mie: u64,
    mip: u64,
    mtvec: u64,
    mscratch: u64,
    mepc: u64,
    mcause: u64,
    mtval: u64,
    mcounteren: u64,
    menvcfg: u64,
    stvec: u64,
    sscratch: u64,
    sepc: u64,
    scause: u64,
    stval: u64,
    satp: u64,
    scounteren: u64,
    senvcfg: u64,
    stimecmp: u64,
    fcsr: u64,
    time: u64,
    instret: u64,
    reservation: u64,
    reservation_valid: u64,
    wfi: u64,
    sbi: u64,
    pmpaddr: [16]u64,
    pmpcfg: [8]u64,

    pub fn reset(h: *Hart, entry: u64) void {
        h.* = std.mem.zeroes(Hart);
        h.pc = entry;
        h.priv = 3;
        h.mstatus = xl64;
        h.stimecmp = std.math.maxInt(u64);
        flushTlb();
    }

    /// Enters a supervisor-mode kernel directly, as firmware would after setting up delegation.
    pub fn bootSupervisor(h: *Hart, entry: u64, dtb: u64) void {
        h.reset(entry);
        h.priv = 1;
        h.sbi = 1;
        h.x[10] = 0; // hart id
        h.x[11] = dtb;
        h.medeleg = medeleg_mask & ~@as(u64, 1 << 9); // everything but ecalls from S, which are SBI calls
        h.mideleg = 0x222;
        h.mcounteren = 0xffff_ffff;
        h.menvcfg = menvcfg_stce;
    }
};

// mstatus fields
const SIE: u64 = 1 << 1;
const MIE: u64 = 1 << 3;
const SPIE: u64 = 1 << 5;
const MPIE: u64 = 1 << 7;
const SPP: u64 = 1 << 8;
const MPP: u64 = 3 << 11;
const FS: u64 = 3 << 13;
const MPRV: u64 = 1 << 17;
const SUM: u64 = 1 << 18;
const MXR: u64 = 1 << 19;
const TVM: u64 = 1 << 20;
const TW: u64 = 1 << 21;
const TSR: u64 = 1 << 22;
const xl64: u64 = (2 << 32) | (2 << 34); // UXL = SXL = 64-bit
const SD: u64 = 1 << 63;
const mstatus_wmask = SIE | MIE | SPIE | MPIE | SPP | MPP | FS | MPRV | SUM | MXR | TVM | TW | TSR;
const sstatus_rmask = SIE | SPIE | SPP | FS | SUM | MXR | (3 << 32) | SD;
const sstatus_wmask = SIE | SPIE | SPP | FS | SUM | MXR;

// interrupt bits
const SSIP: u64 = 1 << 1;
const MSIP: u64 = 1 << 3;
const STIP: u64 = 1 << 5;
const MTIP: u64 = 1 << 7;
const SEIP: u64 = 1 << 9;
const MEIP: u64 = 1 << 11;

const medeleg_mask: u64 = 0xb3ff; // exceptions 0-9, 12, 13, 15
const menvcfg_stce: u64 = 1 << 63;
const misa: u64 = (2 << 62) | 0x14112d; // RV64 A C D F I M S U
const ppn_mask: u64 = (1 << 44) - 1;

pub const canonical_nan32: u32 = 0x7fc0_0000;
pub const canonical_nan64: u64 = 0x7ff8_0000_0000_0000;

// Exception causes
const cause_misaligned_fetch = 0;
const cause_fetch_access = 1;
const cause_illegal = 2;
const cause_breakpoint = 3;
const cause_misaligned_load = 4;
const cause_load_access = 5;
const cause_misaligned_store = 6;
const cause_store_access = 7;
const cause_ecall_u = 8;
const cause_fetch_page = 12;
const cause_load_page = 13;
const cause_store_page = 15;

const Access = enum(u2) { fetch = 0, load = 1, store = 2 };
const MemError = error{ PageFault, AccessFault, Misaligned };

fn faultCause(acc: Access, e: MemError) u64 {
    return switch (e) {
        error.PageFault => switch (acc) {
            .fetch => cause_fetch_page,
            .load => cause_load_page,
            .store => cause_store_page,
        },
        error.AccessFault => switch (acc) {
            .fetch => cause_fetch_access,
            .load => cause_load_access,
            .store => cause_store_access,
        },
        error.Misaligned => switch (acc) {
            .fetch => cause_misaligned_fetch,
            .load => cause_misaligned_load,
            .store => cause_misaligned_store,
        },
    };
}

// ---------------------------------------------------------------------------
// Translation cache: one direct-mapped table per access type, tagged with the virtual page and
// the "mode key" (effective privilege, SUM, MXR), so privilege switches need no flush. An entry
// exists only once the page is accessible that way with A (and, for stores, D) already set.

const tlb_len = 256;
const TlbEntry = struct { tag: u64 = 0, ppage: u64 = 0 };
var tlb: [3][tlb_len]TlbEntry = @splat(@splat(.{}));

pub fn flushTlb() void {
    for (&tlb) |*t| @memset(t, .{});
}

inline fn effectivePriv(h: *const Hart, comptime acc: Access) u64 {
    if (acc != .fetch and h.priv == 3 and h.mstatus & MPRV != 0) return (h.mstatus >> 11) & 3;
    return h.priv;
}

inline fn tlbTag(va: u64, priv: u64, mstatus: u64) u64 {
    const key = priv | ((mstatus >> 17) & 6); // SUM -> bit 1, MXR -> bit 2
    return ((va >> 12) << 3 | key) + 1;
}

fn translate(h: *Hart, ram: []u8, bus: anytype, va: u64, comptime acc: Access) MemError!u64 {
    const priv = effectivePriv(h, acc);
    if (priv == 3 or h.satp >> 60 == 0) return va;
    const tag = tlbTag(va, priv, h.mstatus);
    const slot = &tlb[@intFromEnum(acc)][@intCast((va >> 12) % tlb_len)];
    if (slot.tag == tag) return slot.ppage | (va & 0xfff);
    return walk(h, ram, bus, va, acc, priv, tag, slot);
}

fn walk(h: *Hart, ram: []u8, bus: anytype, va: u64, comptime acc: Access, priv: u64, tag: u64, slot: *TlbEntry) MemError!u64 {
    // Sv39: bits 63..39 must all equal bit 38.
    const top = @as(i64, @bitCast(va)) >> 38;
    if (top != 0 and top != -1) return error.PageFault;
    var table = (h.satp & ppn_mask) << 12;
    var level: u6 = 2;
    var pte: u64 = undefined;
    var pte_addr: u64 = undefined;
    while (true) : (level -= 1) {
        pte_addr = table + ((va >> (12 + 9 * @as(u6, level))) & 0x1ff) * 8;
        pte = physLoad(ram, bus, pte_addr, u64) orelse return error.AccessFault;
        if (pte & 1 == 0 or (pte & 2 == 0 and pte & 4 != 0)) return error.PageFault;
        if (pte & 0xa != 0) break; // R or X: a leaf
        if (level == 0) return error.PageFault;
        table = ((pte >> 10) & ppn_mask) << 12;
    }
    if (pte >> 54 != 0) return error.PageFault; // reserved, PBMT and N bits: none supported
    const r = pte & 2 != 0;
    const w = pte & 4 != 0;
    const x = pte & 8 != 0;
    const u = pte & 16 != 0;
    if (priv == 0 and !u) return error.PageFault;
    if (priv == 1 and u and (acc == .fetch or h.mstatus & SUM == 0)) return error.PageFault;
    switch (acc) {
        .fetch => if (!x) return error.PageFault,
        .load => if (!(r or (x and h.mstatus & MXR != 0))) return error.PageFault,
        .store => if (!w) return error.PageFault,
    }
    const ppn = (pte >> 10) & ppn_mask;
    const span: u6 = 9 * @as(u6, level);
    if (ppn & ((@as(u64, 1) << span) - 1) != 0) return error.PageFault; // misaligned superpage
    const need: u64 = if (acc == .store) 0xc0 else 0x40; // A, and D for stores
    if (pte & need != need) {
        if (!physStore(ram, bus, pte_addr, u64, pte | need)) return error.AccessFault;
    }
    const pa = (ppn << 12) | (va & ((@as(u64, 1) << (12 + span)) - 1));
    slot.* = .{ .tag = tag, .ppage = pa & ~@as(u64, 0xfff) };
    return pa;
}

inline fn physLoad(ram: []u8, bus: anytype, pa: u64, comptime T: type) ?T {
    const off = pa -% ram_base;
    if (off < ram.len and ram.len - off >= @sizeOf(T)) return std.mem.readInt(T, ram[@intCast(off)..][0..@sizeOf(T)], .little);
    const v = bus.mmioLoad(pa, @sizeOf(T)) orelse return null;
    return @truncate(v);
}

inline fn physStore(ram: []u8, bus: anytype, pa: u64, comptime T: type, v: T) bool {
    const off = pa -% ram_base;
    if (off < ram.len and ram.len - off >= @sizeOf(T)) {
        std.mem.writeInt(T, ram[@intCast(off)..][0..@sizeOf(T)], v, .little);
        return true;
    }
    return bus.mmioStore(pa, @sizeOf(T), v);
}

fn load(h: *Hart, ram: []u8, bus: anytype, va: u64, comptime T: type) MemError!T {
    if ((va & 0xfff) + @sizeOf(T) > 4096) {
        // Crosses a page: assemble it byte by byte so each page is translated.
        var v: T = 0;
        inline for (0..@sizeOf(T)) |i| {
            const pa = try translate(h, ram, bus, va +% i, .load);
            v |= @as(T, physLoad(ram, bus, pa, u8) orelse return error.AccessFault) << (8 * i);
        }
        return v;
    }
    const pa = try translate(h, ram, bus, va, .load);
    return physLoad(ram, bus, pa, T) orelse error.AccessFault;
}

fn store(h: *Hart, ram: []u8, bus: anytype, va: u64, comptime T: type, v: T) MemError!void {
    if ((va & 0xfff) + @sizeOf(T) > 4096) {
        inline for (0..@sizeOf(T)) |i| _ = try translate(h, ram, bus, va +% i, .store);
        inline for (0..@sizeOf(T)) |i| {
            const pa = try translate(h, ram, bus, va +% i, .store);
            if (!physStore(ram, bus, pa, u8, @truncate(v >> (8 * i)))) return error.AccessFault;
        }
        return;
    }
    const pa = try translate(h, ram, bus, va, .store);
    if (!physStore(ram, bus, pa, T, v)) return error.AccessFault;
}

/// Returns the instruction at pc (16 or 32 bits) and its length. On a fault, `fault_va` is the
/// address that faulted: pc + 2 when a 32-bit instruction's second half is on an unmapped page.
fn fetch(h: *Hart, ram: []u8, bus: anytype, pc: u64, fault_va: *u64) MemError!struct { ir: u32, len: u64 } {
    fault_va.* = pc;
    const pa = try translate(h, ram, bus, pc, .fetch);
    const lo = physLoad(ram, bus, pa, u16) orelse return error.AccessFault;
    if (lo & 3 != 3) return .{ .ir = lo, .len = 2 };
    fault_va.* = pc + 2;
    const hi_pa = if (pc & 0xfff != 0xffe) pa + 2 else try translate(h, ram, bus, pc + 2, .fetch);
    const hi = physLoad(ram, bus, hi_pa, u16) orelse return error.AccessFault;
    return .{ .ir = @as(u32, hi) << 16 | lo, .len = 4 };
}

// ---------------------------------------------------------------------------
// Traps and interrupts

fn trap(h: *Hart, cause: u64, tval: u64) void {
    const interrupt = cause >> 63 != 0;
    const code: u6 = @truncate(cause);
    const deleg = if (interrupt) h.mideleg else h.medeleg;
    h.reservation_valid = 0;
    h.wfi = 0;
    if (h.priv <= 1 and (deleg >> code) & 1 != 0) {
        h.scause = cause;
        h.sepc = h.pc;
        h.stval = tval;
        var s = h.mstatus & ~(SPIE | SIE | SPP);
        if (h.mstatus & SIE != 0) s |= SPIE;
        if (h.priv == 1) s |= SPP;
        h.mstatus = s;
        h.priv = 1;
        h.pc = vector(h.stvec, interrupt, code);
    } else {
        h.mcause = cause;
        h.mepc = h.pc;
        h.mtval = tval;
        var s = h.mstatus & ~(MPIE | MIE | MPP);
        if (h.mstatus & MIE != 0) s |= MPIE;
        s |= h.priv << 11;
        h.mstatus = s;
        h.priv = 3;
        h.pc = vector(h.mtvec, interrupt, code);
    }
}

fn vector(tvec: u64, interrupt: bool, code: u6) u64 {
    const base = tvec & ~@as(u64, 3);
    return if (interrupt and tvec & 1 != 0) base + 4 * @as(u64, code) else base;
}

/// The interrupt to take now, if any, in priority order.
fn pendingInterrupt(h: *const Hart) ?u6 {
    const pending = h.mip & h.mie;
    if (pending == 0) return null;
    const m = pending & ~h.mideleg;
    const s = pending & h.mideleg;
    var take: u64 = 0;
    if (m != 0 and (h.priv < 3 or h.mstatus & MIE != 0)) {
        take = m;
    } else if (s != 0 and (h.priv == 0 or (h.priv == 1 and h.mstatus & SIE != 0))) {
        take = s;
    } else return null;
    for ([_]u6{ 11, 3, 7, 9, 1, 5 }) |bit| if ((take >> bit) & 1 != 0) return bit;
    return null;
}

fn updateTimer(h: *Hart) void {
    if (h.sbi == 0 and h.menvcfg & menvcfg_stce == 0) return;
    if (h.time >= h.stimecmp) h.mip |= STIP else h.mip &= ~STIP;
}

/// Microseconds until the supervisor timer fires; lets the host sleep while the guest idles.
pub fn idleMicros(h: *const Hart) u64 {
    return h.stimecmp -| h.time;
}

// ---------------------------------------------------------------------------
// Run loop

const chunk_len: u32 = 1024;

pub fn run(h: *Hart, ram: []u8, bus: anytype, budget: u32, elapsed_us: u32) Exit {
    h.time +%= elapsed_us;
    updateTimer(h);
    h.mip = (h.mip & ~(SEIP | MEIP)) | (bus.externalIrq() & (SEIP | MEIP));
    if (h.wfi != 0) {
        if (h.mip & h.mie == 0) return .idle;
        h.wfi = 0;
    }
    var left = budget;
    while (left > 0) {
        if (pendingInterrupt(h)) |bit| trap(h, (1 << 63) | @as(u64, bit), 0);
        const n = @min(left, chunk_len);
        const exit = execute(h, ram, bus, n);
        left -= n;
        h.mip = (h.mip & ~(SEIP | MEIP)) | (bus.externalIrq() & (SEIP | MEIP));
        if (exit != .budget) return exit;
    }
    return .budget;
}

fn execute(h: *Hart, ram: []u8, bus: anytype, count: u32) Exit {
    var n: u32 = 0;
    while (n < count) : (n += 1) {
        var fault_va: u64 = undefined;
        const f = fetch(h, ram, bus, h.pc, &fault_va) catch |e| {
            trap(h, faultCause(.fetch, e), fault_va);
            continue;
        };
        const ir = if (f.len == 2) expand(f.ir) else f.ir;
        if (ir == 0) {
            trap(h, cause_illegal, f.ir);
            continue;
        }
        switch (step(h, ram, bus, ir, f.len)) {
            .next => |pc| {
                h.pc = pc;
                h.instret +%= 1;
            },
            .trap => |t| trap(h, t.cause, if (t.cause == cause_illegal) f.ir else t.tval),
            .exit => |e| return e,
        }
    }
    return .budget;
}

const Outcome = union(enum) {
    next: u64,
    trap: struct { cause: u64, tval: u64 },
    exit: Exit,
};

inline fn illegal() Outcome {
    return .{ .trap = .{ .cause = cause_illegal, .tval = 0 } };
}

inline fn memFault(acc: Access, e: MemError, va: u64) Outcome {
    return .{ .trap = .{ .cause = faultCause(acc, e), .tval = va } };
}

inline fn sext(v: u64, comptime bits: u7) u64 {
    const shift: u6 = @intCast(64 - bits);
    return @bitCast(@as(i64, @bitCast(v << shift)) >> shift);
}

inline fn sext32(v: u64) u64 {
    return @bitCast(@as(i64, @as(i32, @bitCast(@as(u32, @truncate(v))))));
}

fn step(h: *Hart, ram: []u8, bus: anytype, ir: u32, len: u64) Outcome {
    const pc = h.pc;
    const rd: u5 = @truncate(ir >> 7);
    const rs1v = h.x[(ir >> 15) & 31];
    const rs2v = h.x[(ir >> 20) & 31];
    const funct3 = (ir >> 12) & 7;
    const funct7 = ir >> 25;
    const imm_i = sext(ir >> 20, 12);
    var next = pc +% len;
    var val: u64 = 0;
    var write = true;

    switch (ir & 0x7f) {
        0x37 => val = sext(ir & 0xffff_f000, 32), // LUI
        0x17 => val = pc +% sext(ir & 0xffff_f000, 32), // AUIPC
        0x6f => { // JAL
            const imm = sext(((ir >> 11) & 0x10_0000) | (ir & 0xf_f000) | ((ir >> 9) & 0x800) | ((ir >> 20) & 0x7fe), 21);
            val = next;
            next = pc +% imm;
        },
        0x67 => { // JALR
            if (funct3 != 0) return illegal();
            val = next;
            next = (rs1v +% imm_i) & ~@as(u64, 1);
        },
        0x63 => { // BRANCH
            write = false;
            const a: i64 = @bitCast(rs1v);
            const b: i64 = @bitCast(rs2v);
            const taken = switch (funct3) {
                0 => rs1v == rs2v,
                1 => rs1v != rs2v,
                4 => a < b,
                5 => a >= b,
                6 => rs1v < rs2v,
                7 => rs1v >= rs2v,
                else => return illegal(),
            };
            if (taken) next = pc +% sext(((ir >> 19) & 0x1000) | ((ir << 4) & 0x800) | ((ir >> 20) & 0x7e0) | ((ir >> 7) & 0x1e), 13);
        },
        0x03 => { // LOAD
            const va = rs1v +% imm_i;
            val = switch (funct3) {
                0 => sext(load(h, ram, bus, va, u8) catch |e| return memFault(.load, e, va), 8),
                1 => sext(load(h, ram, bus, va, u16) catch |e| return memFault(.load, e, va), 16),
                2 => sext32(load(h, ram, bus, va, u32) catch |e| return memFault(.load, e, va)),
                3 => load(h, ram, bus, va, u64) catch |e| return memFault(.load, e, va),
                4 => load(h, ram, bus, va, u8) catch |e| return memFault(.load, e, va),
                5 => load(h, ram, bus, va, u16) catch |e| return memFault(.load, e, va),
                6 => load(h, ram, bus, va, u32) catch |e| return memFault(.load, e, va),
                else => return illegal(),
            };
        },
        0x23 => { // STORE
            write = false;
            const va = rs1v +% sext(((ir >> 20) & 0xfe0) | ((ir >> 7) & 0x1f), 12);
            (switch (funct3) {
                0 => store(h, ram, bus, va, u8, @truncate(rs2v)),
                1 => store(h, ram, bus, va, u16, @truncate(rs2v)),
                2 => store(h, ram, bus, va, u32, @truncate(rs2v)),
                3 => store(h, ram, bus, va, u64, rs2v),
                else => return illegal(),
            }) catch |e| return memFault(.store, e, va);
            if (h.reservation_valid != 0 and (h.reservation >> 3) == (va >> 3)) h.reservation_valid = 0;
        },
        0x13 => { // OP-IMM
            const sh: u6 = @truncate(imm_i);
            val = switch (funct3) {
                0 => rs1v +% imm_i,
                1 => if (ir >> 26 == 0) rs1v << sh else return illegal(),
                2 => @intFromBool(@as(i64, @bitCast(rs1v)) < @as(i64, @bitCast(imm_i))),
                3 => @intFromBool(rs1v < imm_i),
                4 => rs1v ^ imm_i,
                5 => switch (ir >> 26) {
                    0 => rs1v >> sh,
                    0x10 => @bitCast(@as(i64, @bitCast(rs1v)) >> sh),
                    else => return illegal(),
                },
                6 => rs1v | imm_i,
                else => rs1v & imm_i,
            };
        },
        0x1b => { // OP-IMM-32
            const sh: u5 = @truncate(imm_i);
            const a: u32 = @truncate(rs1v);
            val = switch (funct3) {
                0 => sext32(rs1v +% imm_i),
                1 => if (funct7 == 0) sext32(a << sh) else return illegal(),
                5 => switch (funct7) {
                    0 => sext32(a >> sh),
                    0x20 => sext32(@as(u32, @bitCast(@as(i32, @bitCast(a)) >> sh))),
                    else => return illegal(),
                },
                else => return illegal(),
            };
        },
        0x33 => { // OP
            const sh: u6 = @truncate(rs2v);
            val = switch (funct7) {
                0 => switch (funct3) {
                    0 => rs1v +% rs2v,
                    1 => rs1v << sh,
                    2 => @intFromBool(@as(i64, @bitCast(rs1v)) < @as(i64, @bitCast(rs2v))),
                    3 => @intFromBool(rs1v < rs2v),
                    4 => rs1v ^ rs2v,
                    5 => rs1v >> sh,
                    6 => rs1v | rs2v,
                    else => rs1v & rs2v,
                },
                0x20 => switch (funct3) {
                    0 => rs1v -% rs2v,
                    5 => @bitCast(@as(i64, @bitCast(rs1v)) >> sh),
                    else => return illegal(),
                },
                1 => mulDiv(funct3, rs1v, rs2v),
                else => return illegal(),
            };
        },
        0x3b => { // OP-32
            const a: u32 = @truncate(rs1v);
            const b: u32 = @truncate(rs2v);
            const sh: u5 = @truncate(rs2v);
            val = switch (funct7) {
                0 => switch (funct3) {
                    0 => sext32(a +% b),
                    1 => sext32(a << sh),
                    5 => sext32(a >> sh),
                    else => return illegal(),
                },
                0x20 => switch (funct3) {
                    0 => sext32(a -% b),
                    5 => sext32(@as(u32, @bitCast(@as(i32, @bitCast(a)) >> sh))),
                    else => return illegal(),
                },
                1 => switch (funct3) {
                    0, 4, 5, 6, 7 => sext32(mulDiv32(funct3, a, b)),
                    else => return illegal(),
                },
                else => return illegal(),
            };
        },
        0x0f => { // MISC-MEM: FENCE, FENCE.I
            if (funct3 > 1) return illegal();
            write = false;
        },
        0x73 => return system(h, bus, ir, rd, rs1v, funct3, next),
        0x2f => return amo(h, ram, bus, ir, rd, rs1v, rs2v, funct3, next),
        0x07, 0x27, 0x43, 0x47, 0x4b, 0x4f, 0x53 => return fp(h, ram, bus, ir, next),
        else => return illegal(),
    }
    if (write and rd != 0) h.x[rd] = val;
    return .{ .next = next };
}

fn mulDiv(funct3: u32, a: u64, b: u64) u64 {
    const sa: i64 = @bitCast(a);
    const sb: i64 = @bitCast(b);
    return switch (funct3) {
        0 => a *% b,
        1 => @truncate(@as(u128, @bitCast(@as(i128, sa) * @as(i128, sb))) >> 64),
        2 => @truncate(@as(u128, @bitCast(@as(i128, sa) * @as(i128, b))) >> 64),
        3 => @truncate((@as(u128, a) * @as(u128, b)) >> 64),
        4 => if (b == 0) std.math.maxInt(u64) else if (sa == std.math.minInt(i64) and sb == -1) a else @bitCast(@divTrunc(sa, sb)),
        5 => if (b == 0) std.math.maxInt(u64) else a / b,
        6 => if (b == 0) a else if (sa == std.math.minInt(i64) and sb == -1) 0 else @bitCast(@rem(sa, sb)),
        else => if (b == 0) a else a % b,
    };
}

fn mulDiv32(funct3: u32, a: u32, b: u32) u32 {
    const sa: i32 = @bitCast(a);
    const sb: i32 = @bitCast(b);
    return switch (funct3) {
        0 => a *% b,
        4 => if (b == 0) std.math.maxInt(u32) else if (sa == std.math.minInt(i32) and sb == -1) a else @bitCast(@divTrunc(sa, sb)),
        5 => if (b == 0) std.math.maxInt(u32) else a / b,
        6 => if (b == 0) a else if (sa == std.math.minInt(i32) and sb == -1) 0 else @bitCast(@rem(sa, sb)),
        else => if (b == 0) a else a % b,
    };
}

fn amo(h: *Hart, ram: []u8, bus: anytype, ir: u32, rd: u5, va: u64, rs2v: u64, funct3: u32, next: u64) Outcome {
    if (funct3 != 2 and funct3 != 3) return illegal();
    const wide = funct3 == 3;
    const size: u64 = if (wide) 8 else 4;
    const funct5 = ir >> 27;
    const is_lr = funct5 == 0x02;
    // AMOs must be naturally aligned, and must not touch devices.
    if (va & (size - 1) != 0) return memFault(if (is_lr) .load else .store, error.Misaligned, va);
    if (is_lr) {
        const v: u64 = if (wide)
            (load(h, ram, bus, va, u64) catch |e| return memFault(.load, e, va))
        else
            sext32(load(h, ram, bus, va, u32) catch |e| return memFault(.load, e, va));
        h.reservation = va;
        h.reservation_valid = 1;
        if (rd != 0) h.x[rd] = v;
        return .{ .next = next };
    }
    if (funct5 == 0x03) { // SC
        const ok = h.reservation_valid != 0 and h.reservation == va;
        h.reservation_valid = 0;
        if (ok) {
            (if (wide) store(h, ram, bus, va, u64, rs2v) else store(h, ram, bus, va, u32, @truncate(rs2v))) catch |e| return memFault(.store, e, va);
        }
        if (rd != 0) h.x[rd] = @intFromBool(!ok);
        return .{ .next = next };
    }
    // Translate for a store first: a read-modify-write needs write permission and sets D.
    const pa = translate(h, ram, bus, va, .store) catch |e| return memFault(.store, e, va);
    const off = pa -% ram_base;
    if (off >= ram.len or ram.len - off < size) return memFault(.store, error.AccessFault, va);
    const bytes = ram[@intCast(off)..];
    const old: u64 = if (wide) std.mem.readInt(u64, bytes[0..8], .little) else sext32(std.mem.readInt(u32, bytes[0..4], .little));
    const b = if (wide) rs2v else sext32(rs2v);
    const new: u64 = switch (funct5) {
        0x01 => b,
        0x00 => old +% b,
        0x04 => old ^ b,
        0x0c => old & b,
        0x08 => old | b,
        0x10 => if (@as(i64, @bitCast(old)) < @as(i64, @bitCast(b))) old else b,
        0x14 => if (@as(i64, @bitCast(old)) > @as(i64, @bitCast(b))) old else b,
        0x18 => if (wide) @min(old, b) else if (@as(u32, @truncate(old)) < @as(u32, @truncate(b))) old else b,
        0x1c => if (wide) @max(old, b) else if (@as(u32, @truncate(old)) > @as(u32, @truncate(b))) old else b,
        else => return illegal(),
    };
    if (wide) std.mem.writeInt(u64, bytes[0..8], new, .little) else std.mem.writeInt(u32, bytes[0..4], @truncate(new), .little);
    if (h.reservation_valid != 0 and h.reservation == va) h.reservation_valid = 0;
    if (rd != 0) h.x[rd] = old;
    return .{ .next = next };
}

// ---------------------------------------------------------------------------
// SYSTEM: privileged instructions, CSRs and the built-in SBI

fn system(h: *Hart, bus: anytype, ir: u32, rd: u5, rs1v: u64, funct3: u32, next: u64) Outcome {
    if (funct3 == 0) {
        if (rd != 0) return illegal();
        if (ir >> 25 == 0x09) { // SFENCE.VMA
            if (h.priv == 0 or (h.priv == 1 and h.mstatus & TVM != 0)) return illegal();
            flushTlb();
            return .{ .next = next };
        }
        switch (ir) {
            0x0000_0073 => { // ECALL
                if (h.priv == 1 and h.sbi != 0) {
                    if (sbiCall(h, bus)) |exit| return .{ .exit = exit };
                    return .{ .next = next };
                }
                return .{ .trap = .{ .cause = cause_ecall_u + h.priv, .tval = 0 } };
            },
            0x0010_0073 => return .{ .trap = .{ .cause = cause_breakpoint, .tval = h.pc } }, // EBREAK
            0x1020_0073 => { // SRET
                if (h.priv == 0 or (h.priv == 1 and h.mstatus & TSR != 0)) return illegal();
                const spp = (h.mstatus >> 8) & 1;
                var s = h.mstatus & ~(SIE | SPP);
                if (h.mstatus & SPIE != 0) s |= SIE;
                s |= SPIE;
                s &= ~MPRV; // returning below M
                h.mstatus = s;
                h.priv = spp;
                h.reservation_valid = 0;
                return .{ .next = h.sepc };
            },
            0x3020_0073 => { // MRET
                if (h.priv != 3) return illegal();
                const mpp = (h.mstatus >> 11) & 3;
                var s = h.mstatus & ~(MIE | MPP);
                if (h.mstatus & MPIE != 0) s |= MIE;
                s |= MPIE;
                if (mpp != 3) s &= ~MPRV;
                h.mstatus = s;
                h.priv = mpp;
                h.reservation_valid = 0;
                return .{ .next = h.mepc };
            },
            0x1050_0073 => { // WFI
                if (h.priv == 0 or (h.priv == 1 and h.mstatus & TW != 0)) return illegal();
                if (h.mip & h.mie == 0) {
                    h.wfi = 1;
                    h.pc = next;
                    return .{ .exit = .idle };
                }
                return .{ .next = next };
            },
            else => return illegal(),
        }
    }
    if (funct3 == 4) return illegal();
    const csr: u12 = @truncate(ir >> 20);
    const uimm = (ir >> 15) & 31;
    const src = if (funct3 >= 5) uimm else rs1v;
    const op = funct3 & 3; // 1 = write, 2 = set, 3 = clear
    const writes = op == 1 or uimm != 0; // rs1 = x0 / zimm = 0 makes set/clear read-only
    if (h.priv < ((csr >> 8) & 3)) return illegal();
    if (writes and csr >> 10 == 3) return illegal();
    const old = csrRead(h, csr) orelse return illegal();
    if (writes) {
        const new = switch (op) {
            1 => src,
            2 => old | src,
            else => old & ~src,
        };
        if (!csrWrite(h, csr, new)) return illegal();
    }
    if (rd != 0) h.x[rd] = old;
    return .{ .next = next };
}

fn counterAllowed(h: *const Hart, csr: u12) bool {
    const bit = @as(u64, 1) << @as(u6, @truncate(csr & 31));
    if (h.priv < 3 and h.mcounteren & bit == 0) return false;
    if (h.priv == 0 and h.scounteren & bit == 0) return false;
    return true;
}

fn csrRead(h: *Hart, csr: u12) ?u64 {
    return switch (csr) {
        0x001 => if (h.mstatus & FS == 0) null else h.fcsr & 0x1f,
        0x002 => if (h.mstatus & FS == 0) null else (h.fcsr >> 5) & 7,
        0x003 => if (h.mstatus & FS == 0) null else h.fcsr & 0xff,
        0xc00, 0xc02 => if (counterAllowed(h, csr)) h.instret else null,
        0xc01 => if (counterAllowed(h, csr)) h.time else null,
        0xc03...0xc1f => if (counterAllowed(h, csr)) 0 else null,
        0x100 => withSd(h.mstatus) & sstatus_rmask,
        0x104 => h.mie & h.mideleg,
        0x105 => h.stvec,
        0x106 => h.scounteren,
        0x10a => h.senvcfg,
        0x140 => h.sscratch,
        0x141 => h.sepc,
        0x142 => h.scause,
        0x143 => h.stval,
        0x144 => h.mip & h.mideleg,
        0x14d => if (h.priv == 1 and (h.menvcfg & menvcfg_stce == 0 or h.mcounteren & 2 == 0)) null else h.stimecmp,
        0x180 => if (h.priv == 1 and h.mstatus & TVM != 0) null else h.satp,
        0x300 => withSd(h.mstatus),
        0x301 => misa,
        0x302 => h.medeleg,
        0x303 => h.mideleg,
        0x304 => h.mie,
        0x305 => h.mtvec,
        0x306 => h.mcounteren,
        0x30a => h.menvcfg,
        0x320 => 0, // mcountinhibit
        0x323...0x33f => 0, // mhpmevent
        0x340 => h.mscratch,
        0x341 => h.mepc,
        0x342 => h.mcause,
        0x343 => h.mtval,
        0x344 => h.mip,
        0x3a0...0x3af => if (csr & 1 == 0) h.pmpcfg[(csr & 0xf) / 2] else null, // odd pmpcfg are RV32-only
        0x3b0...0x3bf => h.pmpaddr[csr & 0xf], // stored but not enforced
        0x3c0...0x3ef => 0,
        0x7a0...0x7a3 => 0, // debug triggers: none
        0xb00, 0xb02 => h.instret,
        0xb03...0xb1f => 0,
        0xf11...0xf15 => 0, // vendor, arch, impl, hart id, config pointer
        else => null,
    };
}

fn withSd(mstatus: u64) u64 {
    return if (mstatus & FS == FS) mstatus | SD else mstatus & ~SD;
}

fn csrWrite(h: *Hart, csr: u12, v: u64) bool {
    switch (csr) {
        0x001, 0x002, 0x003 => {
            if (h.mstatus & FS == 0) return false;
            h.fcsr = switch (csr) {
                0x001 => (h.fcsr & ~@as(u64, 0x1f)) | (v & 0x1f),
                0x002 => (h.fcsr & 0x1f) | ((v & 7) << 5),
                else => v & 0xff,
            };
            h.mstatus |= FS;
        },
        0x100 => h.mstatus = (h.mstatus & ~sstatus_wmask) | (v & sstatus_wmask),
        0x104 => h.mie = (h.mie & ~h.mideleg) | (v & h.mideleg & 0x222),
        0x105 => h.stvec = v & ~@as(u64, 2),
        0x106 => h.scounteren = v & 0xffff_ffff,
        0x10a => h.senvcfg = v & 1,
        0x140 => h.sscratch = v,
        0x141 => h.sepc = v & ~@as(u64, 1),
        0x142 => h.scause = v,
        0x143 => h.stval = v,
        0x144 => h.mip = (h.mip & ~(SSIP & h.mideleg)) | (v & SSIP & h.mideleg),
        0x14d => {
            h.stimecmp = v;
            updateTimer(h);
        },
        0x180 => {
            // Only bare and Sv39 exist; any other mode leaves satp unchanged (WARL), which is how
            // Linux discovers that Sv48/Sv57 are unsupported. No ASID bits are implemented.
            switch (v >> 60) {
                0 => h.satp = 0,
                8 => h.satp = (8 << 60) | (v & ppn_mask),
                else => {},
            }
            flushTlb();
        },
        0x300 => {
            var s = (h.mstatus & ~mstatus_wmask) | (v & mstatus_wmask);
            if ((s >> 11) & 3 == 2) s &= ~MPP; // MPP=2 (H) does not exist
            h.mstatus = s;
        },
        0x301 => {}, // misa is fixed
        0x302 => h.medeleg = v & medeleg_mask,
        0x303 => h.mideleg = v & 0x222,
        0x304 => h.mie = v & 0xaaa,
        0x305 => h.mtvec = v & ~@as(u64, 2),
        0x306 => h.mcounteren = v & 0xffff_ffff,
        0x30a => h.menvcfg = v & (menvcfg_stce | 1),
        0x320, 0x323...0x33f, 0x3c0...0x3ef, 0x7a0...0x7a3, 0xb03...0xb1f => {},
        0x340 => h.mscratch = v,
        0x341 => h.mepc = v & ~@as(u64, 1),
        0x342 => h.mcause = v,
        0x343 => h.mtval = v,
        0x344 => {
            const writable = if (h.menvcfg & menvcfg_stce != 0) SSIP else SSIP | STIP;
            h.mip = (h.mip & ~writable) | (v & writable);
        },
        0xb00, 0xb02 => h.instret = v -% 1, // the writing instruction's own retirement brings it to v
        0x3a0...0x3af => if (csr & 1 == 0) {
            h.pmpcfg[(csr & 0xf) / 2] = v;
        },
        0x3b0...0x3bf => h.pmpaddr[csr & 0xf] = v & ((1 << 54) - 1),
        else => return false,
    }
    return true;
}

// SBI v2.0 subset: base, legacy console/timer/shutdown, TIME, IPI, RFENCE, HSM, SRST.
const sbi_not_supported: u64 = @bitCast(@as(i64, -2));
const sbi_invalid_param: u64 = @bitCast(@as(i64, -3));
const sbi_already_available: u64 = @bitCast(@as(i64, -6));

const sbi_base = 0x10;
const sbi_time = 0x54494d45;
const sbi_ipi = 0x735049;
const sbi_rfence = 0x52464e43;
const sbi_hsm = 0x48534d;
const sbi_srst = 0x53525354;

/// Handles an ecall from S-mode. Returns an exit for power off or reboot.
fn sbiCall(h: *Hart, bus: anytype) ?Exit {
    const ext = h.x[17];
    const fid = h.x[16];
    const a0 = h.x[10];
    var err: u64 = 0;
    var value: u64 = 0;
    switch (ext) {
        0x00 => { // legacy set_timer
            h.stimecmp = a0;
            updateTimer(h);
            h.x[10] = 0;
            return null;
        },
        0x01 => { // legacy console_putchar
            bus.sbiPutchar(@truncate(a0));
            h.x[10] = 0;
            return null;
        },
        0x02 => { // legacy console_getchar
            h.x[10] = @bitCast(bus.sbiGetchar());
            return null;
        },
        0x08 => return .poweroff, // legacy shutdown
        sbi_base => switch (fid) {
            0 => value = 2 << 24, // spec version 2.0
            1 => value = 0x7276, // implementation id: "rv"
            2 => value = 1,
            3 => value = @intFromBool(switch (a0) {
                0x00, 0x01, 0x02, 0x08, sbi_time, sbi_ipi, sbi_rfence, sbi_hsm, sbi_srst => true,
                else => false,
            }),
            4, 5, 6 => value = 0, // mvendorid, marchid, mimpid
            else => err = sbi_not_supported,
        },
        sbi_time => {
            if (fid == 0) {
                h.stimecmp = a0;
                updateTimer(h);
            } else err = sbi_not_supported;
        },
        sbi_ipi => {
            // send_ipi(hart_mask, hart_mask_base): only hart 0 exists.
            const base = h.x[11];
            if (fid != 0) err = sbi_not_supported else if (base == std.math.maxInt(u64) or (base == 0 and a0 & 1 != 0)) h.mip |= SSIP;
        },
        sbi_rfence => {
            if (fid <= 2) flushTlb() else err = sbi_not_supported;
        },
        sbi_hsm => switch (fid) {
            0 => err = sbi_already_available, // hart_start: hart 0 is running
            2 => if (a0 == 0) {
                value = 0; // STARTED
            } else {
                err = sbi_invalid_param;
            },
            else => err = sbi_not_supported,
        },
        sbi_srst => {
            if (fid == 0 and a0 == 0) return .poweroff;
            if (fid == 0 and a0 <= 2) return .reboot;
            err = sbi_invalid_param;
        },
        else => err = sbi_not_supported,
    }
    h.x[10] = err;
    h.x[11] = value;
    return null;
}

// ---------------------------------------------------------------------------
// Floating point (F and D). Results that are NaN are canonical; fflags follow IEEE 754 for the
// common cases. Arithmetic always rounds to nearest-even; conversions to integers honour rm.

const NX: u64 = 1;
const UF: u64 = 2;
const OF: u64 = 4;
const DZ: u64 = 8;
const NV: u64 = 16;

inline fn readS(h: *const Hart, r: u32) f32 {
    const v = h.f[r];
    return @bitCast(if (v >> 32 == 0xffff_ffff) @as(u32, @truncate(v)) else canonical_nan32);
}

inline fn readD(h: *const Hart, r: u32) f64 {
    return @bitCast(h.f[r]);
}

inline fn writeRaw(h: *Hart, r: u32, v: u64) void {
    h.f[r] = v;
    h.mstatus |= FS;
}

fn Bits(comptime T: type) type {
    return if (T == f32) u32 else u64;
}

fn writeF(h: *Hart, comptime T: type, r: u32, v: T) void {
    if (T == f32) {
        const bits: u32 = if (std.math.isNan(v)) canonical_nan32 else @bitCast(v);
        writeRaw(h, r, 0xffff_ffff_0000_0000 | @as(u64, bits));
    } else {
        writeRaw(h, r, if (std.math.isNan(v)) canonical_nan64 else @bitCast(v));
    }
}

fn readF(h: *const Hart, comptime T: type, r: u32) T {
    return if (T == f32) readS(h, r) else readD(h, r);
}

fn isSnan(comptime T: type, v: T) bool {
    const B = Bits(T);
    const bits: B = @bitCast(v);
    const quiet: B = if (T == f32) 1 << 22 else 1 << 51;
    return std.math.isNan(v) and bits & quiet == 0;
}

inline fn raise(h: *Hart, flags: u64) void {
    h.fcsr |= flags;
}

/// Flags for a rounded result r of an operation on finite inputs, given whether it was exact.
fn resultFlags(comptime T: type, r: T, exact: bool) u64 {
    var flags: u64 = 0;
    if (std.math.isInf(r)) return OF | NX;
    if (!exact) {
        flags |= NX;
        if (@abs(r) < std.math.floatMin(T)) flags |= UF;
    }
    return flags;
}

fn fpArith(h: *Hart, comptime T: type, op: u32, a: T, b: T) T {
    if (isSnan(T, a) or isSnan(T, b)) raise(h, NV);
    if (std.math.isNan(a) or std.math.isNan(b)) return std.math.nan(T);
    const W = if (T == f32) f64 else T;
    var r: T = undefined;
    var exact = true;
    switch (op) {
        0, 1 => { // add, sub
            const bb = if (op == 1) -b else b;
            r = a + bb;
            if (std.math.isNan(r)) {
                raise(h, NV);
                return r;
            }
            if (std.math.isInf(a) or std.math.isInf(bb)) return r;
            // TwoSum: the exact rounding error of a + bb.
            const bv = r - a;
            const err = (a - (r - bv)) + (bb - bv);
            exact = err == 0;
        },
        2 => { // mul
            r = a * b;
            if (std.math.isNan(r)) {
                raise(h, NV);
                return r;
            }
            if (std.math.isInf(a) or std.math.isInf(b)) return r;
            exact = if (T == f32) @as(W, r) == @as(W, a) * @as(W, b) else @mulAdd(T, a, b, -r) == 0;
        },
        3 => { // div
            if (b == 0 and !std.math.isNan(a) and a != 0 and !std.math.isInf(a)) {
                raise(h, DZ);
                return a / b;
            }
            r = a / b;
            if (std.math.isNan(r)) {
                raise(h, NV);
                return r;
            }
            if (std.math.isInf(a) or std.math.isInf(b) or b == 0) return r;
            exact = if (T == f32) @as(W, r) * @as(W, b) == @as(W, a) else @mulAdd(T, -r, b, a) == 0;
        },
        else => unreachable,
    }
    raise(h, resultFlags(T, r, exact));
    return r;
}

fn fpSqrt(h: *Hart, comptime T: type, a: T) T {
    if (isSnan(T, a)) raise(h, NV);
    if (std.math.isNan(a)) return a;
    if (a < 0) {
        raise(h, NV);
        return std.math.nan(T);
    }
    const r = @sqrt(a);
    if (std.math.isInf(a) or a == 0) return r;
    const W = if (T == f32) f64 else T;
    const exact = if (T == f32) @as(W, r) * @as(W, r) == @as(W, a) else @mulAdd(T, -r, r, a) == 0;
    if (!exact) raise(h, NX);
    return r;
}

fn fpFma(h: *Hart, comptime T: type, a: T, b: T, c: T) T {
    if (isSnan(T, a) or isSnan(T, b) or isSnan(T, c)) raise(h, NV);
    if ((std.math.isInf(a) and b == 0) or (a == 0 and std.math.isInf(b))) {
        raise(h, NV);
        return std.math.nan(T);
    }
    const r = @mulAdd(T, a, b, c);
    if (std.math.isNan(r)) {
        if (!std.math.isNan(a) and !std.math.isNan(b) and !std.math.isNan(c)) raise(h, NV);
        return r;
    }
    if (std.math.isInf(a) or std.math.isInf(b) or std.math.isInf(c)) return r;
    if (T == f32) {
        const wide = @mulAdd(f64, a, b, c);
        raise(h, resultFlags(T, r, @as(f64, r) == wide));
    } else {
        // a*b = p + e exactly (TwoProd), p + c = sum + t exactly (TwoSum); exact if r covers it all.
        const p = a * b;
        const e = @mulAdd(f64, a, b, -p);
        const sum = p + c;
        const bv = sum - p;
        const t = (p - (sum - bv)) + (c - bv);
        raise(h, resultFlags(T, r, (sum - r) + t + e == 0));
    }
    return r;
}

fn fpMinMax(h: *Hart, comptime T: type, a: T, b: T, is_max: bool) T {
    if (isSnan(T, a) or isSnan(T, b)) raise(h, NV);
    if (std.math.isNan(a) and std.math.isNan(b)) return std.math.nan(T);
    if (std.math.isNan(a)) return b;
    if (std.math.isNan(b)) return a;
    if (a == 0 and b == 0) {
        const a_neg = std.math.signbit(a);
        return if (is_max) (if (a_neg) b else a) else (if (a_neg) a else b);
    }
    return if (is_max) @max(a, b) else @min(a, b);
}

fn fpClass(comptime T: type, v: T) u64 {
    const neg = std.math.signbit(v);
    if (std.math.isNan(v)) return if (isSnan(T, v)) 1 << 8 else 1 << 9;
    if (std.math.isInf(v)) return if (neg) 1 << 0 else 1 << 7;
    if (v == 0) return if (neg) 1 << 3 else 1 << 4;
    if (@abs(v) < std.math.floatMin(T)) return if (neg) 1 << 2 else 1 << 5;
    return if (neg) 1 << 1 else 1 << 6;
}

fn roundTo(x: f64, rm: u64) f64 {
    return switch (rm) {
        1 => @trunc(x),
        2 => @floor(x),
        3 => @ceil(x),
        4 => @round(x), // ties away from zero
        else => blk: { // ties to even
            const fl = @floor(x);
            const diff = x - fl;
            if (diff > 0.5) break :blk fl + 1;
            if (diff < 0.5) break :blk fl;
            break :blk if (@mod(fl, 2) == 0) fl else fl + 1;
        },
    };
}

/// FCVT to an integer of the given width and signedness, saturating with NV like the spec.
fn fpToInt(h: *Hart, x: f64, rm: u64, comptime signed: bool, comptime bits: u7) u64 {
    const max: f64 = comptime @floatFromInt(@as(u128, 1) << (if (signed) bits - 1 else bits)); // exclusive
    const min: f64 = if (signed) -max else 0;
    const all: u64 = if (bits == 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(bits)) - 1;
    const imax: u64 = if (signed) all >> 1 else all;
    const imin: u64 = if (signed) ~imax else 0;
    if (std.math.isNan(x)) {
        raise(h, NV);
        return if (bits == 32) sext32(imax) else imax;
    }
    const r = roundTo(x, rm);
    var out: u64 = undefined;
    if (r >= max) {
        raise(h, NV);
        out = imax;
    } else if (r < min) {
        raise(h, NV);
        out = imin;
    } else {
        if (r != x) raise(h, NX);
        out = if (signed) @bitCast(@as(i64, @intFromFloat(r))) else @intFromFloat(r);
    }
    return if (bits == 32) sext32(out) else out;
}

fn intToFp(h: *Hart, comptime T: type, v: u64, comptime signed: bool, comptime bits: u7) T {
    const r: T = if (signed)
        @floatFromInt(if (bits == 32) @as(i64, @as(i32, @bitCast(@as(u32, @truncate(v))))) else @as(i64, @bitCast(v)))
    else
        @floatFromInt(if (bits == 32) @as(u64, @as(u32, @truncate(v))) else v);
    const back_ok = if (signed) blk: {
        const want: i128 = if (bits == 32) @as(i32, @bitCast(@as(u32, @truncate(v)))) else @as(i64, @bitCast(v));
        break :blk @as(i128, @intFromFloat(r)) == want;
    } else blk: {
        const want: u128 = if (bits == 32) @as(u32, @truncate(v)) else v;
        break :blk @as(u128, @intFromFloat(r)) == want;
    };
    if (!back_ok) raise(h, NX);
    return r;
}

fn fp(h: *Hart, ram: []u8, bus: anytype, ir: u32, next: u64) Outcome {
    if (h.mstatus & FS == 0) return illegal();
    const opcode = ir & 0x7f;
    const rd = (ir >> 7) & 31;
    const rs1 = (ir >> 15) & 31;
    const rs2 = (ir >> 20) & 31;
    const funct3 = (ir >> 12) & 7;
    switch (opcode) {
        0x07 => { // FLW, FLD
            const va = h.x[rs1] +% sext(ir >> 20, 12);
            switch (funct3) {
                2 => writeRaw(h, rd, 0xffff_ffff_0000_0000 | @as(u64, load(h, ram, bus, va, u32) catch |e| return memFault(.load, e, va))),
                3 => writeRaw(h, rd, load(h, ram, bus, va, u64) catch |e| return memFault(.load, e, va)),
                else => return illegal(),
            }
            return .{ .next = next };
        },
        0x27 => { // FSW, FSD
            const va = h.x[rs1] +% sext(((ir >> 20) & 0xfe0) | ((ir >> 7) & 0x1f), 12);
            (switch (funct3) {
                2 => store(h, ram, bus, va, u32, @truncate(h.f[rs2])),
                3 => store(h, ram, bus, va, u64, h.f[rs2]),
                else => return illegal(),
            }) catch |e| return memFault(.store, e, va);
            return .{ .next = next };
        },
        else => {},
    }
    const fmt = (ir >> 25) & 3; // 0 = single, 1 = double
    var rm: u64 = funct3;
    if (rm == 7) rm = (h.fcsr >> 5) & 7;
    if (fmt > 1) return illegal();
    return if (fmt == 0) fpOp(h, f32, ir, opcode, rd, rs1, rs2, funct3, rm, next) else fpOp(h, f64, ir, opcode, rd, rs1, rs2, funct3, rm, next);
}

fn fpOp(h: *Hart, comptime T: type, ir: u32, opcode: u32, rd: u32, rs1: u32, rs2: u32, funct3: u32, rm: u64, next: u64) Outcome {
    const B = Bits(T);
    const sign: B = @as(B, 1) << (@bitSizeOf(B) - 1);
    const a = readF(h, T, rs1);
    const b = readF(h, T, rs2);
    const needs_rm = switch (opcode) {
        0x43, 0x47, 0x4b, 0x4f => true,
        else => switch (ir >> 27) {
            0x00, 0x01, 0x02, 0x03, 0x0b, 0x08, 0x18, 0x1a => true,
            else => false,
        },
    };
    if (needs_rm and rm > 4) return illegal();
    switch (opcode) {
        0x43, 0x47, 0x4b, 0x4f => { // FMADD, FMSUB, FNMSUB, FNMADD
            const c = readF(h, T, ir >> 27);
            const r = switch (opcode) {
                0x43 => fpFma(h, T, a, b, c),
                0x47 => fpFma(h, T, a, b, -c),
                0x4b => fpFma(h, T, -a, b, c),
                else => fpFma(h, T, -a, b, -c),
            };
            writeF(h, T, rd, r);
            return .{ .next = next };
        },
        else => {},
    }
    switch (ir >> 27) {
        0x00 => writeF(h, T, rd, fpArith(h, T, 0, a, b)),
        0x01 => writeF(h, T, rd, fpArith(h, T, 1, a, b)),
        0x02 => writeF(h, T, rd, fpArith(h, T, 2, a, b)),
        0x03 => writeF(h, T, rd, fpArith(h, T, 3, a, b)),
        0x0b => {
            if (rs2 != 0) return illegal();
            writeF(h, T, rd, fpSqrt(h, T, a));
        },
        0x04 => { // FSGNJ, FSGNJN, FSGNJX
            const ab: B = @bitCast(a);
            const bb: B = @bitCast(b);
            const s: B = switch (funct3) {
                0 => bb & sign,
                1 => ~bb & sign,
                2 => (ab ^ bb) & sign,
                else => return illegal(),
            };
            const r: B = (ab & ~sign) | s;
            if (T == f32) writeRaw(h, rd, 0xffff_ffff_0000_0000 | @as(u64, r)) else writeRaw(h, rd, r);
        },
        0x05 => switch (funct3) {
            0 => writeF(h, T, rd, fpMinMax(h, T, a, b, false)),
            1 => writeF(h, T, rd, fpMinMax(h, T, a, b, true)),
            else => return illegal(),
        },
        0x08 => { // FCVT.S.D / FCVT.D.S
            if (T == f32 and rs2 == 1) {
                const d = readD(h, rs1);
                if (isSnan(f64, d)) raise(h, NV);
                const r: f32 = @floatCast(d);
                if (!std.math.isNan(d) and !std.math.isInf(d)) raise(h, resultFlags(f32, r, @as(f64, r) == d));
                writeF(h, f32, rd, r);
            } else if (T == f64 and rs2 == 0) {
                const s = readS(h, rs1);
                if (isSnan(f32, s)) raise(h, NV);
                writeF(h, f64, rd, @floatCast(s));
            } else return illegal();
        },
        0x14 => { // FLE, FLT, FEQ
            const any_nan = std.math.isNan(a) or std.math.isNan(b);
            if (funct3 == 2) {
                if (isSnan(T, a) or isSnan(T, b)) raise(h, NV);
            } else if (any_nan) raise(h, NV);
            const r: bool = if (any_nan) false else switch (funct3) {
                0 => a <= b,
                1 => a < b,
                2 => a == b,
                else => return illegal(),
            };
            if (rd != 0) h.x[rd] = @intFromBool(r);
        },
        0x18 => { // FCVT.{W,WU,L,LU}.{S,D}
            const x: f64 = @floatCast(a);
            const r = switch (rs2) {
                0 => fpToInt(h, x, rm, true, 32),
                1 => fpToInt(h, x, rm, false, 32),
                2 => fpToInt(h, x, rm, true, 64),
                3 => fpToInt(h, x, rm, false, 64),
                else => return illegal(),
            };
            if (rd != 0) h.x[rd] = r;
        },
        0x1a => { // FCVT.{S,D}.{W,WU,L,LU}
            const v = h.x[rs1];
            writeF(h, T, rd, switch (rs2) {
                0 => intToFp(h, T, v, true, 32),
                1 => intToFp(h, T, v, false, 32),
                2 => intToFp(h, T, v, true, 64),
                3 => intToFp(h, T, v, false, 64),
                else => return illegal(),
            });
        },
        0x1c => { // FMV.X.{W,D}, FCLASS
            if (rs2 != 0) return illegal();
            const r: u64 = switch (funct3) {
                0 => if (T == f32) sext32(h.f[rs1]) else h.f[rs1],
                1 => fpClass(T, a),
                else => return illegal(),
            };
            if (rd != 0) h.x[rd] = r;
        },
        0x1e => { // FMV.{W,D}.X
            if (rs2 != 0 or funct3 != 0) return illegal();
            const v = h.x[rs1];
            writeRaw(h, rd, if (T == f32) 0xffff_ffff_0000_0000 | (v & 0xffff_ffff) else v);
        },
        else => return illegal(),
    }
    return .{ .next = next };
}

// ---------------------------------------------------------------------------
// Compressed instructions: each one is expanded to its 32-bit equivalent; 0 means illegal.

inline fn encR(f7: u32, rs2: u32, rs1: u32, f3: u32, rd: u32, op: u32) u32 {
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op;
}
inline fn encI(imm: u32, rs1: u32, f3: u32, rd: u32, op: u32) u32 {
    return ((imm & 0xfff) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op;
}
inline fn encS(imm: u32, rs2: u32, rs1: u32, f3: u32, op: u32) u32 {
    return (((imm >> 5) & 0x7f) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((imm & 0x1f) << 7) | op;
}
inline fn encB(imm: u32, rs2: u32, rs1: u32, f3: u32) u32 {
    return (((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3f) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) |
        (((imm >> 1) & 0xf) << 8) | (((imm >> 11) & 1) << 7) | 0x63;
}
inline fn encJ(imm: u32, rd: u32) u32 {
    return (((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3ff) << 21) | (((imm >> 11) & 1) << 20) | (((imm >> 12) & 0xff) << 12) | (rd << 7) | 0x6f;
}
inline fn sextBits(v: u32, comptime bits: u6) u32 {
    const shift: u5 = 32 - bits;
    return @bitCast(@as(i32, @bitCast(v << shift)) >> shift);
}

pub fn expand(c: u32) u32 {
    const rd = (c >> 7) & 31;
    const rs2 = (c >> 2) & 31;
    const rdp = 8 + ((c >> 2) & 7); // rd' / rs2'
    const rs1p = 8 + ((c >> 7) & 7); // rs1' / rd'
    const imm6 = sextBits(((c >> 7) & 0x20) | ((c >> 2) & 0x1f), 6);
    const f3 = (c >> 13) & 7;
    switch (c & 3) {
        0 => {
            const ld_off = ((c >> 7) & 0x38) | ((c << 1) & 0xc0); // C.LD/C.SD/C.FLD/C.FSD: [5:3|7:6]
            const lw_off = ((c >> 7) & 0x38) | ((c >> 4) & 4) | ((c << 1) & 0x40); // C.LW/C.SW: [5:3|2|6]
            return switch (f3) {
                0 => blk: { // C.ADDI4SPN
                    const imm = ((c >> 7) & 0x30) | ((c >> 1) & 0x3c0) | ((c >> 4) & 4) | ((c >> 2) & 8);
                    break :blk if (imm == 0) 0 else encI(imm, 2, 0, rdp, 0x13);
                },
                1 => encI(ld_off, rs1p, 3, rdp, 0x07), // C.FLD
                2 => encI(lw_off, rs1p, 2, rdp, 0x03), // C.LW
                3 => encI(ld_off, rs1p, 3, rdp, 0x03), // C.LD
                5 => encS(ld_off, rdp, rs1p, 3, 0x27), // C.FSD
                6 => encS(lw_off, rdp, rs1p, 2, 0x23), // C.SW
                7 => encS(ld_off, rdp, rs1p, 3, 0x23), // C.SD
                else => 0,
            };
        },
        1 => return switch (f3) {
            0 => encI(imm6, rd, 0, rd, 0x13), // C.ADDI
            1 => if (rd == 0) 0 else encI(imm6, rd, 0, rd, 0x1b), // C.ADDIW
            2 => encI(imm6, 0, 0, rd, 0x13), // C.LI
            3 => blk: {
                if (rd == 2) { // C.ADDI16SP
                    const imm = sextBits(((c >> 3) & 0x200) | ((c >> 2) & 0x10) | ((c << 1) & 0x40) | ((c << 4) & 0x180) | ((c << 3) & 0x20), 10);
                    break :blk if (imm == 0) 0 else encI(imm, 2, 0, 2, 0x13);
                }
                const imm = sextBits(((c << 5) & 0x20000) | ((c << 10) & 0x1f000), 18); // C.LUI
                break :blk if (imm == 0) 0 else (imm & 0xffff_f000) | (rd << 7) | 0x37;
            },
            4 => switch ((c >> 10) & 3) {
                0, 1 => blk: { // C.SRLI, C.SRAI
                    const shamt = ((c >> 7) & 0x20) | ((c >> 2) & 0x1f);
                    break :blk encI(shamt | (if ((c >> 10) & 3 == 1) @as(u32, 0x400) else 0), rs1p, 5, rs1p, 0x13);
                },
                2 => encI(imm6, rs1p, 7, rs1p, 0x13), // C.ANDI
                else => switch (((c >> 10) & 4) | ((c >> 5) & 3)) {
                    0 => encR(0x20, rdp, rs1p, 0, rs1p, 0x33), // C.SUB
                    1 => encR(0, rdp, rs1p, 4, rs1p, 0x33), // C.XOR
                    2 => encR(0, rdp, rs1p, 6, rs1p, 0x33), // C.OR
                    3 => encR(0, rdp, rs1p, 7, rs1p, 0x33), // C.AND
                    4 => encR(0x20, rdp, rs1p, 0, rs1p, 0x3b), // C.SUBW
                    5 => encR(0, rdp, rs1p, 0, rs1p, 0x3b), // C.ADDW
                    else => 0,
                },
            },
            5 => encJ(sextBits(((c >> 1) & 0x800) | ((c >> 7) & 0x10) | ((c >> 1) & 0x300) | ((c << 2) & 0x400) |
                ((c >> 1) & 0x40) | ((c << 1) & 0x80) | ((c >> 2) & 0xe) | ((c << 3) & 0x20), 12), 0), // C.J
            else => encB(sextBits(((c >> 4) & 0x100) | ((c >> 7) & 0x18) | ((c << 1) & 0xc0) | ((c >> 2) & 6) | ((c << 3) & 0x20), 9), 0, rs1p, f3 - 6), // C.BEQZ, C.BNEZ
        },
        2 => {
            const ldsp_off = ((c >> 7) & 0x20) | ((c >> 2) & 0x18) | ((c << 4) & 0x1c0); // [5|4:3|8:6]
            const sdsp_off = ((c >> 7) & 0x38) | ((c >> 1) & 0x1c0); // [5:3|8:6]
            return switch (f3) {
                0 => encI(((c >> 7) & 0x20) | ((c >> 2) & 0x1f), rd, 1, rd, 0x13), // C.SLLI
                1 => encI(ldsp_off, 2, 3, rd, 0x07), // C.FLDSP
                2 => if (rd == 0) 0 else encI(((c >> 7) & 0x20) | ((c >> 2) & 0x1c) | ((c << 4) & 0xc0), 2, 2, rd, 0x03), // C.LWSP
                3 => if (rd == 0) 0 else encI(ldsp_off, 2, 3, rd, 0x03), // C.LDSP
                4 => if ((c >> 12) & 1 == 0)
                    (if (rs2 == 0) (if (rd == 0) 0 else encI(0, rd, 0, 0, 0x67)) else encR(0, rs2, 0, 0, rd, 0x33)) // C.JR, C.MV
                else if (rs2 == 0)
                    (if (rd == 0) @as(u32, 0x0010_0073) else encI(0, rd, 0, 1, 0x67)) // C.EBREAK, C.JALR
                else
                    encR(0, rs2, rd, 0, rd, 0x33), // C.ADD
                5 => encS(sdsp_off, rs2, 2, 3, 0x27), // C.FSDSP
                6 => encS(((c >> 7) & 0x3c) | ((c >> 1) & 0xc0), rs2, 2, 2, 0x23), // C.SWSP
                else => encS(sdsp_off, rs2, 2, 3, 0x23), // C.SDSP
            };
        },
        else => unreachable,
    }
}
