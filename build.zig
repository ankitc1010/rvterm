const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const web_dir: std.Build.InstallDir = .{ .custom = "web" };
    b.installDirectory(.{ .source_dir = b.path("web"), .install_dir = web_dir, .install_subdir = "" });

    // The browser machine: rvterm64.wasm (RV64GC with Sv39) and snapshot64.bin.gz, that machine
    // booted to a shell prompt in Alpine Linux with Node.js (linux64/, from tools/fetch-alpine.sh).
    const wasm = addWasm(b, "rvterm64");
    b.getInstallStep().dependOn(&b.addInstallArtifact(wasm, .{ .dest_dir = .{ .override = web_dir } }).step);

    // The snapshot is made by booting Linux in Node with the same wasm the page uses, so it is
    // rebuilt whenever the wasm, kernel, initramfs, guest files or tool change (it is tied to the
    // layout).
    const snap = b.addSystemCommand(&.{"node"});
    snap.addFileArg(b.path("tools/mksnapshot64.mjs"));
    snap.addArtifactArg(wasm);
    snap.addFileArg(b.path("linux64/Image"));
    snap.addFileArg(b.path("linux64/initrd.cpio.gz"));
    const snap_file = snap.addOutputFileArg("snapshot64.bin.gz");
    snap.addFileArg(b.path("guest/curl"));
    snap.addFileInput(b.path("tools/snapshot.mjs"));
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(snap_file, web_dir, "snapshot64.bin.gz").step);

    // Native runner: boots the machine in this terminal. And the riscv-tests runner for the core.
    const native = addNative(b, "rvterm64-native", "src/native64.zig", target, optimize);
    const run_native = b.addRunArtifact(native);
    run_native.addArgs(&.{ "linux64/Image", "linux64/initrd.cpio.gz" });
    b.step("run", "Boot Alpine Linux in this terminal").dependOn(&run_native.step);

    _ = addNative(b, "rvtest64", "src/rvtest.zig", target, optimize);

    const tests = b.step("test", "Run unit tests");
    for ([_][]const u8{ "src/vt.zig", "src/inflate.zig" }) |path| {
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        }) });
        tests.dependOn(&b.addRunArtifact(t).step);
    }
}

/// The browser build: always optimized and stripped, and built for the WebAssembly MVP, because
/// Zig's default wasm CPU enables post-MVP features (multivalue, sign-ext, bulk memory,
/// extended-const, ...) that 2019-2021 TV engines (Chromium 63-85) reject.
fn addWasm(b: *std.Build, name: []const u8) *std.Build.Step.Compile {
    const wasm = b.addExecutable(.{ .name = name, .root_module = b.createModule(.{
        .root_source_file = b.path("src/wasm.zig"),
        .target = b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .os_tag = .freestanding,
            .cpu_model = .{ .explicit = &std.Target.wasm.cpu.mvp },
        }),
        .optimize = .ReleaseFast,
        .strip = true,
        .single_threaded = true,
    }) });
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
