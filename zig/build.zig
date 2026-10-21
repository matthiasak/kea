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
    "SecurityInterface",
    "UserNotifications",
    "SystemConfiguration",
    "AuthenticationServices",
    "LocalAuthentication",
    "IOKit",
    "AVFoundation",
    "NaturalLanguage",
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
    mod.linkSystemLibrary("sqlite3", .{});
}

fn appModule(b: *std.Build, root: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, imports: []const std.Build.Module.Import) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = imports,
    });
    linkMacFrameworks(mod, b, target);
    return mod;
}

/// A test harness's root module: imports `nanoui` and `kea` (src/root.zig).
fn harness(b: *std.Build, root: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const nanoui = b.dependency("nanoui", .{ .target = target, .optimize = optimize }).module("nanoui");
    const kea = appModule(b, "src/root.zig", target, optimize, &.{.{ .name = "nanoui", .module = nanoui }});
    return appModule(b, root, target, optimize, &.{
        .{ .name = "nanoui", .module = nanoui },
        .{ .name = "kea", .module = kea },
    });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const nanoui = b.dependency("nanoui", .{ .target = target, .optimize = optimize }).module("nanoui");

    // Kea executable (Kea.app/Contents/MacOS/Kea)
    const exe_mod = appModule(b, "src/main.zig", target, optimize, &.{.{ .name = "nanoui", .module = nanoui }});
    const exe = b.addExecutable(.{ .name = "Kea", .root_module = exe_mod });
    b.installArtifact(exe);
    const run_exe = b.addRunArtifact(exe);
    run_exe.addPassthruArgs();
    b.step("run", "Run Kea").dependOn(&run_exe.step);

    // Unit and HistoryRegression tests. `-Dtest-root=src/<file>.zig` tests one
    // module tree in isolation (parallel work on separate modules).
    const test_root = b.option([]const u8, "test-root", "Root file for `zig build test` (default src/main.zig)");
    const test_mod = if (test_root) |r| appModule(b, r, target, optimize, &.{.{ .name = "nanoui", .module = nanoui }}) else exe_mod;
    const tests = b.addTest(.{ .root_module = test_mod });
    b.step("test", "Run Kea unit and HistoryRegression tests").dependOn(&b.addRunArtifact(tests).step);

    // Headless chrome suites on ui.Tester
    const ui_tests = b.addTest(.{ .root_module = harness(b, "src/tests/ui/root.zig", target, optimize) });
    b.step("ui-test", "Run the headless chrome suites (ui.Tester)").dependOn(&b.addRunArtifact(ui_tests).step);

    // Frame-time gate while the sidebar edge is dragged
    const perf = b.addExecutable(.{ .name = "kea-perf", .root_module = harness(b, "src/tests/perf.zig", target, .ReleaseFast) });
    const run_perf = b.addRunArtifact(perf);
    run_perf.has_side_effects = true;
    b.step("perf", "Measure frame times dragging the sidebar edge (fails at CPU p90 >= 4 ms)").dependOn(&run_perf.step);

    // WebKit end to end, in process, windows hidden
    const e2e = b.addExecutable(.{ .name = "kea-e2e", .root_module = harness(b, "src/tests/e2e/main.zig", target, .Debug) });
    // The app's scripting dictionary, which the bundle ships (scripting case).
    e2e.root_module.addAnonymousImport("kea_sdef", .{ .root_source_file = b.path("../Kea.sdef") });
    const run_e2e = b.addRunArtifact(e2e);
    run_e2e.addArg("--nanoui-hidden");
    run_e2e.has_side_effects = true;
    b.step("e2e", "Run the in-process WebKit end-to-end cases").dependOn(&run_e2e.step);
    // The same binary in zig-out/bin, to run under `leaks --atExit --`.
    b.step("e2e-bin", "Install kea-e2e into zig-out/bin").dependOn(&b.addInstallArtifact(e2e, .{}).step);
    const smooth = b.addExecutable(.{ .name = "kea-smooth", .root_module = harness(b, "src/tests/e2e/main.zig", target, .ReleaseFast) });
    smooth.root_module.addAnonymousImport("kea_sdef", .{ .root_source_file = b.path("../Kea.sdef") });
    const run_smooth = b.addRunArtifact(smooth);
    run_smooth.addArg("--onscreen");
    run_smooth.has_side_effects = true;
    b.step("smooth", "Run on-screen smoothness scenarios S1-S16").dependOn(&run_smooth.step);

    // Chrome states rendered to PNGs ($KEA_SNAPSHOTS or $TMPDIR/kea-snapshots)
    const snaps = b.addExecutable(.{ .name = "kea-snapshots", .root_module = harness(b, "src/tests/snapshots.zig", target, optimize) });
    const run_snaps = b.addRunArtifact(snaps);
    run_snaps.has_side_effects = true;
    b.step("snapshots", "Render named chrome states to PNG").dependOn(&run_snaps.step);
    // Line limit check (<= 600 lines per file across zig/src)
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
