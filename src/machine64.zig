//! The 64-bit machine around rv64.zig: RAM, a 16550 UART with interrupts, a PLIC, and the device
//! tree that describes them to Linux. Shared by the native runner and the wasm build.
//!
//!   0x0c000000  PLIC (context 0 = hart 0 M-mode, context 1 = hart 0 S-mode)
//!   0x10000000  16550 UART, PLIC source 10
//!   0x10001000  VM generation ID (microsoft,vmgenid), PLIC source 11: a new ID after a snapshot
//!               restore makes Linux reseed its random number generator
//!   0x80000000  RAM (256 MB by default; its size is the length of the slice the caller passes);
//!               the kernel Image goes at +2 MB, the initrd and device tree near the top

const std = @import("std");
const rv = @import("rv64.zig");

pub const default_ram_size: usize = 256 << 20;
pub const kernel_offset: u64 = 0x20_0000; // the Image header's text_offset
pub const timebase_hz: u64 = 1_000_000; // the hart's time counter ticks in microseconds

const plic_base: u64 = 0x0c00_0000;
const plic_size: u64 = 0x0400_0000;
const uart_base: u64 = 0x1000_0000;
const uart_irq = 10;
const genid_base: u64 = 0x1000_1000;
const genid_irq = 11;
const ring_len = 4096;

/// Device state; plain data so it can be snapshotted with the hart.
pub const Devices = extern struct {
    // UART
    ier: u8,
    lcr: u8,
    mcr: u8,
    scr: u8,
    fcr: u8,
    dll: u8,
    dlm: u8,
    thre_pending: u8,
    in_head: u32,
    in_tail: u32,
    in_ring: [ring_len]u8,
    // PLIC
    priority: [32]u32,
    pending: u32,
    claimed: u32,
    enable: [2]u32,
    threshold: [2]u32,
    // VM generation ID, and its edge interrupt (raised once per new ID, cleared by the claim)
    genid: [16]u8,
    genid_pulse: u32,

    /// Gives the machine a new generation ID, as after it was restored from a snapshot.
    pub fn newGeneration(d: *Devices, id: [16]u8) void {
        d.genid = id;
        d.genid_pulse = 1;
    }

    fn genidLoad(d: *const Devices, off: u64, size: u8) u64 {
        var v: u64 = 0;
        for (0..size) |i| {
            if (off + i < d.genid.len) v |= @as(u64, d.genid[@intCast(off + i)]) << @intCast(i * 8);
        }
        return v;
    }

    pub fn inputAvailable(d: *const Devices) bool {
        return d.in_head != d.in_tail;
    }

    pub fn inputFree(d: *const Devices) u32 {
        return ring_len - (d.in_head -% d.in_tail);
    }

    pub fn pushInput(d: *Devices, c: u8) void {
        if (d.inputFree() == 0) return;
        d.in_ring[d.in_head % ring_len] = c;
        d.in_head +%= 1;
    }

    pub fn popInput(d: *Devices) u8 {
        if (!d.inputAvailable()) return 0;
        const c = d.in_ring[d.in_tail % ring_len];
        d.in_tail +%= 1;
        return c;
    }

    fn uartRxIrq(d: *const Devices) bool {
        return d.ier & 1 != 0 and d.inputAvailable();
    }

    fn uartTxIrq(d: *const Devices) bool {
        return d.ier & 2 != 0 and d.thre_pending != 0;
    }

    fn uartLoad(d: *Devices, reg: u64) u8 {
        const dlab = d.lcr & 0x80 != 0;
        return switch (reg) {
            0 => if (dlab) d.dll else d.popInput(),
            1 => if (dlab) d.dlm else d.ier,
            2 => blk: { // IIR; reading it clears a pending THR-empty interrupt
                const fifo: u8 = if (d.fcr & 1 != 0) 0xc0 else 0;
                if (d.uartRxIrq()) break :blk fifo | 0x04;
                if (d.uartTxIrq()) {
                    d.thre_pending = 0;
                    break :blk fifo | 0x02;
                }
                break :blk fifo | 0x01;
            },
            3 => d.lcr,
            4 => d.mcr,
            5 => 0x60 | @as(u8, @intFromBool(d.inputAvailable())), // THR empty, transmitter idle
            6 => 0xb0, // DCD, DSR, CTS
            7 => d.scr,
            else => 0,
        };
    }

    fn uartStore(d: *Devices, reg: u64, v: u8, out: anytype) void {
        const dlab = d.lcr & 0x80 != 0;
        switch (reg) {
            0 => if (dlab) {
                d.dll = v;
            } else {
                out.put(v);
                d.thre_pending = 1; // transmission is instant: THR is empty again
            },
            1 => if (dlab) {
                d.dlm = v;
            } else {
                if (v & 2 != 0 and d.ier & 2 == 0) d.thre_pending = 1;
                d.ier = v & 0x0f;
            },
            2 => d.fcr = v,
            3 => d.lcr = v,
            4 => d.mcr = v,
            7 => d.scr = v,
            else => {},
        }
    }

    /// Level-triggered sources feed the PLIC gateways; a claimed source stays out until completed.
    fn plicUpdate(d: *Devices) void {
        var lines: u32 = 0;
        if (d.uartRxIrq() or d.uartTxIrq()) lines |= 1 << uart_irq;
        if (d.genid_pulse != 0) lines |= 1 << genid_irq;
        d.pending = lines & ~d.claimed;
    }

    fn plicBest(d: *const Devices, ctx: usize) u32 {
        var best: u32 = 0;
        var best_prio: u32 = d.threshold[ctx];
        const ready = d.pending & d.enable[ctx];
        for (1..32) |i| {
            if ((ready >> @intCast(i)) & 1 != 0 and d.priority[i] > best_prio) {
                best = @intCast(i);
                best_prio = d.priority[i];
            }
        }
        return best;
    }

    fn plicLoad(d: *Devices, off: u64) u32 {
        d.plicUpdate();
        if (off < 0x1000) return d.priority[@intCast((off / 4) % 32)];
        if (off == 0x1000) return d.pending;
        if (off >= 0x2000 and off < 0x2100 and off % 0x80 == 0) return d.enable[@intCast((off - 0x2000) / 0x80)];
        if (off >= 0x20_0000 and off < 0x20_2000) {
            const ctx: usize = @intCast((off - 0x20_0000) / 0x1000);
            if (off % 0x1000 == 0) return d.threshold[ctx];
            if (off % 0x1000 == 4) { // claim
                const id = d.plicBest(ctx);
                if (id != 0) {
                    d.pending &= ~(@as(u32, 1) << @intCast(id));
                    d.claimed |= @as(u32, 1) << @intCast(id);
                }
                if (id == genid_irq) d.genid_pulse = 0;
                return id;
            }
        }
        return 0;
    }

    fn plicStore(d: *Devices, off: u64, v: u32) void {
        if (off < 0x1000) {
            d.priority[@intCast((off / 4) % 32)] = v & 7;
        } else if (off >= 0x2000 and off < 0x2100 and off % 0x80 == 0) {
            d.enable[@intCast((off - 0x2000) / 0x80)] = v & ~@as(u32, 1);
        } else if (off >= 0x20_0000 and off < 0x20_2000) {
            const ctx: usize = @intCast((off - 0x20_0000) / 0x1000);
            if (off % 0x1000 == 0) d.threshold[ctx] = v & 7;
            if (off % 0x1000 == 4 and v < 32) d.claimed &= ~(@as(u32, 1) << @intCast(v)); // complete
        }
        d.plicUpdate();
    }
};

/// The rv64 bus for a machine whose UART output goes to `Out` (anything with put(u8)).
pub fn Bus(comptime Out: type) type {
    return struct {
        dev: *Devices,
        out: Out,

        const Self = @This();

        pub fn mmioLoad(b: Self, pa: u64, size: u8) ?u64 {
            if (pa >= uart_base and pa < uart_base + 0x100) return b.dev.uartLoad(pa - uart_base);
            if (pa >= plic_base and pa < plic_base + plic_size and size == 4) return b.dev.plicLoad(pa - plic_base);
            if (pa >= genid_base and pa < genid_base + 0x1000) return b.dev.genidLoad(pa - genid_base, size);
            return null;
        }

        pub fn mmioStore(b: Self, pa: u64, size: u8, v: u64) bool {
            if (pa >= uart_base and pa < uart_base + 0x100) {
                b.dev.uartStore(pa - uart_base, @truncate(v), b.out);
                return true;
            }
            if (pa >= plic_base and pa < plic_base + plic_size and size == 4) {
                b.dev.plicStore(pa - plic_base, @truncate(v));
                return true;
            }
            return false;
        }

        pub fn externalIrq(b: Self) u64 {
            b.dev.plicUpdate();
            var bits: u64 = 0;
            if (b.dev.plicBest(0) != 0) bits |= 1 << 11; // MEIP
            if (b.dev.plicBest(1) != 0) bits |= 1 << 9; // SEIP
            return bits;
        }

        pub fn sbiPutchar(b: Self, c: u8) void {
            b.out.put(c);
        }

        pub fn sbiGetchar(b: Self) i64 {
            return if (b.dev.inputAvailable()) b.dev.popInput() else -1;
        }
    };
}

// ---------------------------------------------------------------------------
// Device tree (FDT) for Linux: memory, one hart, the PLIC, the UART and the generation ID.

const Fdt = struct {
    buf: []u8,
    len: usize = 0,
    strings: [512]u8 = undefined,
    strings_len: usize = 0,

    fn u32be(f: *Fdt, v: u32) void {
        std.mem.writeInt(u32, f.buf[f.len..][0..4], v, .big);
        f.len += 4;
    }

    fn bytes(f: *Fdt, b: []const u8) void {
        @memcpy(f.buf[f.len..][0..b.len], b);
        f.len += b.len;
        while (f.len % 4 != 0) : (f.len += 1) f.buf[f.len] = 0;
    }

    fn begin(f: *Fdt, name: []const u8) void {
        f.u32be(1);
        @memcpy(f.buf[f.len..][0..name.len], name);
        f.buf[f.len + name.len] = 0;
        f.len += name.len + 1;
        while (f.len % 4 != 0) : (f.len += 1) f.buf[f.len] = 0;
    }

    fn end(f: *Fdt) void {
        f.u32be(2);
    }

    fn nameOffset(f: *Fdt, name: []const u8) u32 {
        var i: usize = 0;
        while (i < f.strings_len) {
            const s = std.mem.sliceTo(f.strings[i..f.strings_len], 0);
            if (std.mem.eql(u8, s, name)) return @intCast(i);
            i += s.len + 1;
        }
        @memcpy(f.strings[f.strings_len..][0..name.len], name);
        f.strings[f.strings_len + name.len] = 0;
        f.strings_len += name.len + 1;
        return @intCast(i);
    }

    fn prop(f: *Fdt, name: []const u8, value: []const u8) void {
        f.u32be(3);
        f.u32be(@intCast(value.len));
        f.u32be(f.nameOffset(name));
        f.bytes(value);
    }

    fn propEmpty(f: *Fdt, name: []const u8) void {
        f.prop(name, &.{});
    }

    fn propStr(f: *Fdt, name: []const u8, comptime value: []const u8) void {
        f.prop(name, value ++ "\x00");
    }

    fn propCells(f: *Fdt, name: []const u8, cells: []const u32) void {
        var tmp: [16]u8 = undefined;
        for (cells, 0..) |c, i| std.mem.writeInt(u32, tmp[i * 4 ..][0..4], c, .big);
        f.prop(name, tmp[0 .. cells.len * 4]);
    }
};

/// Random bytes from the host: the device tree's rng-seed, which Linux credits as entropy so its
/// random number generator is ready at boot (otherwise getrandom() blocks: this machine has no
/// entropy source), then the first generation ID.
pub const Entropy = [64]u8;

/// Writes the device tree into `out` and returns its length.
pub fn buildDtb(out: []u8, ram_size: usize, initrd_start: u64, initrd_end: u64, comptime bootargs: []const u8, seed: []const u8) usize {
    var f = Fdt{ .buf = out };
    f.len = 40 + 16; // header, then an empty memory reservation map
    @memset(out[0..f.len], 0);
    const struct_start = f.len;

    f.begin("");
    f.propCells("#address-cells", &.{2});
    f.propCells("#size-cells", &.{2});
    f.propStr("compatible", "rvterm,virt");
    f.propStr("model", "rvterm");

    f.begin("chosen");
    f.propStr("bootargs", bootargs);
    f.propStr("stdout-path", "/soc/serial@10000000");
    f.propCells("linux,initrd-start", &.{ @truncate(initrd_start >> 32), @truncate(initrd_start) });
    f.propCells("linux,initrd-end", &.{ @truncate(initrd_end >> 32), @truncate(initrd_end) });
    f.prop("rng-seed", seed);
    f.end();

    f.begin("memory@80000000");
    f.propStr("device_type", "memory");
    f.propCells("reg", &.{ 0, @truncate(rv.ram_base), 0, @truncate(ram_size) });
    f.end();

    f.begin("cpus");
    f.propCells("#address-cells", &.{1});
    f.propCells("#size-cells", &.{0});
    f.propCells("timebase-frequency", &.{@truncate(timebase_hz)});
    f.begin("cpu@0");
    f.propStr("device_type", "cpu");
    f.propCells("reg", &.{0});
    f.propStr("status", "okay");
    f.propStr("compatible", "riscv");
    f.propStr("riscv,isa", "rv64imafdc_zicntr_zicsr_zifencei_sstc");
    f.propStr("riscv,isa-base", "rv64i");
    f.prop("riscv,isa-extensions", "i\x00m\x00a\x00f\x00d\x00c\x00zicntr\x00zicsr\x00zifencei\x00sstc\x00");
    f.propStr("mmu-type", "riscv,sv39");
    f.begin("interrupt-controller");
    f.propCells("#interrupt-cells", &.{1});
    f.propEmpty("interrupt-controller");
    f.propStr("compatible", "riscv,cpu-intc");
    f.propCells("phandle", &.{1});
    f.end();
    f.end();
    f.end();

    f.begin("soc");
    f.propCells("#address-cells", &.{2});
    f.propCells("#size-cells", &.{2});
    f.propStr("compatible", "simple-bus");
    f.propEmpty("ranges");
    f.begin("interrupt-controller@c000000");
    f.prop("compatible", "sifive,plic-1.0.0\x00riscv,plic0\x00");
    f.propCells("reg", &.{ 0, @truncate(plic_base), 0, @truncate(plic_size) });
    f.propCells("#address-cells", &.{0});
    f.propCells("#interrupt-cells", &.{1});
    f.propEmpty("interrupt-controller");
    f.propCells("interrupts-extended", &.{ 1, 11, 1, 9 });
    f.propCells("riscv,ndev", &.{31});
    f.propCells("phandle", &.{2});
    f.end();
    f.begin("serial@10000000");
    f.propStr("compatible", "ns16550a");
    f.propCells("reg", &.{ 0, @truncate(uart_base), 0, 0x100 });
    f.propCells("clock-frequency", &.{3_686_400});
    f.propCells("interrupt-parent", &.{2});
    f.propCells("interrupts", &.{uart_irq});
    f.end();
    f.begin("vmgenid@10001000");
    f.propStr("compatible", "microsoft,vmgenid");
    f.propCells("reg", &.{ 0, @truncate(genid_base), 0, 0x1000 });
    f.propCells("interrupt-parent", &.{2});
    f.propCells("interrupts", &.{genid_irq});
    f.end();
    f.end();

    f.end();
    f.u32be(9); // FDT_END
    const struct_size = f.len - struct_start;
    const strings_off = f.len;
    @memcpy(out[f.len..][0..f.strings_len], f.strings[0..f.strings_len]);
    f.len += f.strings_len;

    const header = [_]u32{
        0xd00dfeed, @intCast(f.len), @intCast(struct_start), @intCast(strings_off), 40, 17, 16, 0,
        @intCast(f.strings_len), @intCast(struct_size),
    };
    for (header, 0..) |v, i| std.mem.writeInt(u32, out[i * 4 ..][0..4], v, .big);
    return f.len;
}

pub const default_bootargs = "console=ttyS0 earlycon=sbi rdinit=/init";

// The device tree lives in the last 64 KB of RAM, the initrd page-aligned just below it.
fn dtbOffset(ram_size: usize) usize {
    return ram_size - 0x1_0000;
}

/// Where an initrd of `len` bytes goes in RAM of `ram_size` bytes.
pub fn initrdOffset(ram_size: usize, len: usize) usize {
    return (dtbOffset(ram_size) - len) & ~@as(usize, 0xfff);
}

/// Starts the hart at a kernel already at kernel_offset with an initrd at initrdOffset(len).
pub fn bootPlaced(hart: *rv.Hart, dev: *Devices, ram: []u8, initrd_len: usize, comptime bootargs: []const u8, entropy: *const Entropy) void {
    const initrd_start = rv.ram_base + initrdOffset(ram.len, initrd_len);
    const dtb = dtbOffset(ram.len);
    _ = buildDtb(ram[dtb..], ram.len, initrd_start, initrd_start + initrd_len, bootargs, entropy[0..48]);
    dev.genid = entropy[48..64].*;
    hart.bootSupervisor(rv.ram_base + kernel_offset, rv.ram_base + dtb);
}

/// Copies the kernel and initrd into RAM and boots them.
pub fn boot(hart: *rv.Hart, dev: *Devices, ram: []u8, kernel: []const u8, initrd: []const u8, comptime bootargs: []const u8, entropy: *const Entropy) void {
    @memcpy(ram[@intCast(kernel_offset)..][0..kernel.len], kernel);
    @memcpy(ram[initrdOffset(ram.len, initrd.len)..][0..initrd.len], initrd);
    bootPlaced(hart, dev, ram, initrd.len, bootargs, entropy);
}
