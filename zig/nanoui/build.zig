const std = @import("std");

const examples = [_][]const u8{ "hello", "counter", "gallery" };
const frameworks = [_][]const u8{ "AppKit", "WebKit", "Metal", "QuartzCore", "CoreText", "CoreGraphics", "CoreFoundation", "Foundation", "ImageIO", "UniformTypeIdentifiers" };

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
    }
    // Elsewhere GTK is loaded when the app starts (dlopen): nothing to link.

    for (examples) |name| {
        // Pages (the hello example) need a webview: macOS for now.
        if (os != .macos and std.mem.eql(u8, name, "hello")) continue;
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
