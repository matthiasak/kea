const std = @import("std");

const frameworks = [_][]const u8{
    "AppKit",
    "WebKit",
    "Metal",
    "QuartzCore",
    "CoreText",
    "CoreGraphics",
    "CoreFoundation",
    "Foundation",
    "ImageIO",
    "UniformTypeIdentifiers",
    "Security",
};

fn linkMacFrameworks(mod: *std.Build.Module, b: *std.Build, target: std.Build.ResolvedTarget) void {
    if (target.result.os.tag != .macos) return;
    if (!target.query.isNative()) {
        if (std.zig.system.darwin.getSdk(b.allocator, b.graph.io, &target.result)) |sdk| {
            mod.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
            mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
        }
    }
    for (frameworks) |f| mod.linkFramework(f, .{});
    mod.linkSystemLibrary("objc", .{});
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const nanoui_dep = b.dependency("nanoui", .{
        .target = target,
        .optimize = optimize,
    });
    const nanoui = nanoui_dep.module("nanoui");

    // 1. Standalone KeaZig executable (KeaZig.app/Contents/MacOS/KeaZig)
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "nanoui", .module = nanoui }},
    });
    linkMacFrameworks(exe_mod, b, target);
    const exe = b.addExecutable(.{
        .name = "KeaZig",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    run_exe.addPassthruArgs();
    b.step("run", "Run KeaZig").dependOn(&run_exe.step);

    // 2. Phase 0 Drag & Compositor Benchmark (zig build bench-drag)
    const drag_mod = b.createModule(.{
        .root_source_file = b.path("src/bench_drag.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
        .imports = &.{.{ .name = "nanoui", .module = nanoui }},
    });
    linkMacFrameworks(drag_mod, b, target);
    const drag_exe = b.addExecutable(.{
        .name = "kea-bench-drag",
        .root_module = drag_mod,
    });
    b.installArtifact(drag_exe);
    const run_drag = b.addRunArtifact(drag_exe);
    b.step("bench-drag", "Run the Phase 0 80-step, 40-tab drag benchmark").dependOn(&run_drag.step);

    // 3. Phase 2 C-ABI Static Library (libkea_nanoui.a)
    const c_mod = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "nanoui", .module = nanoui }},
    });
    linkMacFrameworks(c_mod, b, target);
    const c_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "kea_nanoui",
        .root_module = c_mod,
    });
    b.installArtifact(c_lib);

    // 4. Unit & HistoryRegression tests (zig build test)
    const tests = b.addTest(.{ .root_module = exe_mod });
    b.step("test", "Run KeaZig unit and HistoryRegression tests").dependOn(&b.addRunArtifact(tests).step);

    // 5. Line limit check (<= 600 lines per file across zig/src and zig/nanoui)
    const lines = b.addExecutable(.{
        .name = "lines",
        .root_module = b.createModule(.{
            .root_source_file = b.path("nanoui/tools/lines.zig"),
            .target = b.graph.host,
        }),
    });
    const check = b.addRunArtifact(lines);
    check.setCwd(b.path("."));
    b.step("lines", "Check that every Zig file is at most 600 lines").dependOn(&check.step);
}
