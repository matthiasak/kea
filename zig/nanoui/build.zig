const std = @import("std");
/// iOS app bundles, for nanoui's examples and for apps:
/// `@import("nanoui").ios.app(b, exe, .{ .name = "Notes", .id = "com.example.notes" })`.
pub const ios = @import("tools/ios/bundle.zig");

const examples = [_][]const u8{ "hello", "counter", "gallery" };
const frameworks = [_][]const u8{ "AppKit", "WebKit", "Metal", "QuartzCore", "CoreText", "CoreGraphics", "CoreFoundation", "Foundation", "ImageIO", "UniformTypeIdentifiers", "CoreVideo" };
const ios_frameworks = [_][]const u8{ "UIKit", "Metal", "QuartzCore", "CoreText", "CoreGraphics", "CoreFoundation", "Foundation", "ImageIO", "UniformTypeIdentifiers", "CoreVideo" };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const portable = b.option(bool, "portable", "Use nanoui's own text and CPU renderer on macOS too (to test that path)") orelse false;
    const options = b.addOptions();
    options.addOption(bool, "portable", portable);
    // The one place the version is kept: build.zig.zon (tools/version.sh).
    options.addOption([]const u8, "version", @import("build.zig.zon").version);

    const nanoui = b.addModule("nanoui", .{
        .root_source_file = b.path("src/nanoui.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    nanoui.addOptions("build_options", options);
    const os = target.result.os.tag;
    if (os == .macos) {
        // A target other than this Mac's (an older macOS for a release,
        // `-Dtarget=aarch64-macos.13.0`) gets no SDK from Zig: use Xcode's.
        if (!target.query.isNative()) {
            if (std.zig.system.darwin.getSdk(b.allocator, b.graph.io, &target.result)) |sdk| {
                nanoui.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
                nanoui.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
            }
        }
        for (frameworks) |f| nanoui.linkFramework(f, .{});
        nanoui.linkSystemLibrary("objc", .{});
    } else if (os == .ios) {
        // Never this machine: the SDK is Xcode's, the device's or the
        // Simulator's (`-Dtarget=aarch64-ios`, `aarch64-ios-simulator`).
        if (std.zig.system.darwin.getSdk(b.allocator, b.graph.io, &target.result)) |sdk| {
            nanoui.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
            nanoui.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
        }
        for (ios_frameworks) |f| nanoui.linkFramework(f, .{});
        nanoui.linkSystemLibrary("objc", .{});
    }
    // Elsewhere GTK is loaded when the app starts (dlopen): nothing to link.
    // HTTP there is http-zig's (nanoui.http), fetched only for those targets.
    if (os != .macos and os != .ios) {
        if (b.lazyDependency("http_zig", .{ .target = target, .optimize = optimize })) |d| nanoui.addImport("http_zig", d.module("http_zig"));
    }

    // nui: the command that makes and checks apps (tools/nui).
    const nui_options = b.addOptions();
    nui_options.addOption([]const u8, "version", @import("build.zig.zon").version);
    const nui = b.addExecutable(.{ .name = "nui", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/nui/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "build_options", .module = nui_options.createModule() }},
    }) });
    // A command for desktops: not part of an iOS build.
    if (os != .ios) b.installArtifact(nui);
    b.step("nui", "Build zig-out/bin/nui").dependOn(&b.addInstallArtifact(nui, .{}).step);
    const nui_tests = b.addTest(.{ .root_module = nui.root_module });
    b.step("test-nui", "Test nui").dependOn(&b.addRunArtifact(nui_tests).step);

    for (examples) |name| {
        // Pages (the hello example) need a webview: macOS for now.
        if (os != .macos and std.mem.eql(u8, name, "hello")) continue;
        if (os == .ios) {
            addIosExample(b, name, target, optimize, nanoui);
            continue;
        }
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}/main.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "nanoui", .module = nanoui }},
            }),
        });
        b.installArtifact(exe);
        const run = b.addRunArtifact(exe);
        run.addPassthruArgs();
        b.step(b.fmt("run-{s}", .{name}), b.fmt("Run the {s} example", .{name})).dependOn(&run.step);

        if (std.mem.eql(u8, name, "hello")) {
            const gen = b.addRunArtifact(exe);
            gen.addArg("--nanoui-generate=examples/hello/frontend");
            b.step("gen", "Write the hello example's generated client").dependOn(&gen.step);
        }
    }

    // The 30-second reel of ui.motion (tools/reel.sh adds the sound).
    const reel = b.addExecutable(.{
        .name = "nanoui-reel",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/reel/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "nanoui", .module = nanoui }},
        }),
    });
    b.step("reel", "Build the motion reel (zig-out/bin/nanoui-reel)").dependOn(&b.addInstallArtifact(reel, .{}).step);

    const tests = b.addTest(.{ .root_module = nanoui });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
    // The tests as a program, for another machine (Linux in a container).
    const test_bin = b.addInstallArtifact(tests, .{ .dest_sub_path = if (os == .windows) "nanoui-tests.exe" else "nanoui-tests" });
    b.step("test-bin", "Install the unit tests as zig-out/bin/nanoui-tests").dependOn(&test_bin.step);

    const lines = b.addExecutable(.{
        .name = "lines",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/lines.zig"),
            .target = b.graph.host,
        }),
    });
    const check = b.addRunArtifact(lines);
    check.setCwd(b.path("."));
    b.step("lines", "Check that every file is at most 600 lines").dependOn(&check.step);
}

/// An example as an iOS app: `zig-out/ios/<Name>.app`, and `run-<name>`
/// in the booted Simulator (a device installs it signed, from Xcode or
/// `xcrun devicectl`).
fn addIosExample(b: *std.Build, name: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, nanoui: *std.Build.Module) void {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}/main.zig", .{name})),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "nanoui", .module = nanoui }},
        }),
    });
    const title = b.fmt("{c}{s}", .{ std.ascii.toUpper(name[0]), name[1..] });
    const opts: ios.Options = .{ .name = title, .id = b.fmt("dev.nanoui.{s}", .{name}) };
    const bundle = ios.app(b, exe, opts);
    b.getInstallStep().dependOn(&b.addInstallDirectory(.{ .source_dir = bundle, .install_dir = .prefix, .install_subdir = b.fmt("ios/{s}.app", .{title}) }).step);
    const step = b.step(b.fmt("run-{s}", .{name}), b.fmt("Run the {s} example in the booted Simulator", .{name}));
    if (target.result.abi == .simulator) {
        const run = ios.runInSimulator(b, bundle, opts, b.path("."));
        run.addPassthruArgs();
        step.dependOn(&run.step);
    } else step.dependOn(&b.addFail("run-* runs in the Simulator (-Dtarget=aarch64-ios-simulator); install on a device from Xcode or with xcrun devicectl").step);
}
