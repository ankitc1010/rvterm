const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const web_dir: std.Build.InstallDir = .{ .custom = "web" };
    b.installDirectory(.{ .source_dir = b.path("web"), .install_dir = web_dir, .install_subdir = "" });

    // The two browser machines, each a wasm module plus a snapshot of it booted to a shell prompt:
    //   rvterm.wasm   + snapshot.bin.gz     32-bit, no MMU, BusyBox (small and fast; "?rv32")
    //   rvterm64.wasm + snapshot64.bin.gz   64-bit RV64GC with Sv39, Alpine Linux (the default)
    //   rvterm64.wasm + snapshot64-node.bin.gz   the same with Node.js ("?node", with -Dnode)
    //   rvterm64-1g.wasm + snapshot64-claude.bin.gz   1 GB of RAM, Node.js and Claude Code ("?claude",
    //                                                 with -Dclaude; too big for a TV)
    // The 32-bit machine gets a bash wrapper around hush; Alpine has real bash (tools/fetch-alpine.sh).
    const node = b.option(bool, "node", "Also build the Node.js snapshot (from linux64/initrd-node.cpio.gz)") orelse false;
    const claude = b.option(bool, "claude", "Also build the Claude Code snapshot (from linux64/initrd-claude.cpio.gz)") orelse false;
    const guest32 = [_][]const u8{ "guest/curl", "guest/bash" };
    const guest64 = [_][]const u8{"guest/curl"};
    const wasm32 = addWasm(b, "rvterm", false, 0);
    const wasm64 = addWasm(b, "rvterm64", true, 256);
    for ([_]*std.Build.Step.Compile{ wasm32, wasm64 }) |w| {
        b.getInstallStep().dependOn(&b.addInstallArtifact(w, .{ .dest_dir = .{ .override = web_dir } }).step);
    }

    // Each snapshot is made by booting Linux in Node with the same wasm the page uses, so it is
    // rebuilt whenever the wasm, kernel, guest files or tool change (it is tied to the layout).
    const snap32 = b.addSystemCommand(&.{"node"});
    snap32.addFileArg(b.path("tools/mksnapshot.mjs"));
    snap32.addArtifactArg(wasm32);
    snap32.addFileArg(b.path("linux/Image"));
    snap32.addFileArg(b.path("linux/64mb.dtb"));
    const snap32_file = snap32.addOutputFileArg("snapshot.bin.gz");
    for (guest32) |file| snap32.addFileArg(b.path(file));
    snap32.addFileInput(b.path("tools/snapshot.mjs"));
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(snap32_file, web_dir, "snapshot.bin.gz").step);

    addSnapshot64(b, wasm64, "linux64/initrd.cpio.gz", "snapshot64.bin.gz", &guest64);
    if (node) addSnapshot64(b, wasm64, "linux64/initrd-node.cpio.gz", "snapshot64-node.bin.gz", &guest64);
    if (claude) {
        const wasm1g = addWasm(b, "rvterm64-1g", true, 1024);
        b.getInstallStep().dependOn(&b.addInstallArtifact(wasm1g, .{ .dest_dir = .{ .override = web_dir } }).step);
        addSnapshot64(b, wasm1g, "linux64/initrd-claude.cpio.gz", "snapshot64-claude.bin.gz", &guest64);
    }

    // Native runners: boot either machine in this terminal, and the riscv-tests runner for rv64.
    const native = addNative(b, "rvterm-native", "src/native.zig", target, optimize);
    const run_native = b.addRunArtifact(native);
    run_native.addArgs(&.{ "linux/Image", "linux/64mb.dtb" });
    b.step("run", "Boot the 32-bit Linux in this terminal").dependOn(&run_native.step);

    const native64 = addNative(b, "rvterm64-native", "src/native64.zig", target, optimize);
    const run_native64 = b.addRunArtifact(native64);
    run_native64.addArgs(&.{ "linux64/Image", "linux64/initrd.cpio.gz" });
    b.step("run64", "Boot 64-bit Alpine Linux in this terminal").dependOn(&run_native64.step);

    _ = addNative(b, "rvtest64", "src/rvtest.zig", target, optimize);

    const tests = b.step("test", "Run unit tests");
    for ([_][]const u8{ "src/cpu.zig", "src/vt.zig", "src/inflate.zig" }) |path| {
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        }) });
        tests.dependOn(&b.addRunArtifact(t).step);
    }
}

fn addSnapshot64(b: *std.Build, wasm64: *std.Build.Step.Compile, initrd: []const u8, name: []const u8, guest: []const []const u8) void {
    const snap = b.addSystemCommand(&.{"node"});
    snap.addFileArg(b.path("tools/mksnapshot64.mjs"));
    snap.addArtifactArg(wasm64);
    snap.addFileArg(b.path("linux64/Image"));
    snap.addFileArg(b.path(initrd));
    const file = snap.addOutputFileArg(name);
    for (guest) |g| snap.addFileArg(b.path(g));
    snap.addFileInput(b.path("tools/snapshot.mjs"));
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(file, .{ .custom = "web" }, name).step);
}

/// A browser build: always optimized and stripped, and built for the WebAssembly MVP, because
/// Zig's default wasm CPU enables post-MVP features (multivalue, sign-ext, bulk memory,
/// extended-const, ...) that 2019-2021 TV engines (Chromium 63-85) reject.
fn addWasm(b: *std.Build, name: []const u8, machine64: bool, ram_mb: u32) *std.Build.Step.Compile {
    const options = b.addOptions();
    options.addOption(bool, "machine64", machine64);
    options.addOption(u32, "ram_mb", ram_mb); // 64-bit guest RAM; the 32-bit machine's is fixed
    const module = b.createModule(.{
        .root_source_file = b.path("src/wasm.zig"),
        .target = b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .os_tag = .freestanding,
            .cpu_model = .{ .explicit = &std.Target.wasm.cpu.mvp },
        }),
        .optimize = .ReleaseFast,
        .strip = true,
        .single_threaded = true,
    });
    module.addOptions("build_options", options);
    const wasm = b.addExecutable(.{ .name = name, .root_module = module });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    wasm.stack_size = 64 * 1024;
    return wasm;
}

fn addNative(b: *std.Build, name: []const u8, path: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);
    return exe;
}
