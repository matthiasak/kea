const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Benchmarks measure release code unless told otherwise.
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode (default fast)") orelse .fast;

    const nanoui = b.dependency("nanoui", .{ .target = target, .optimize = optimize }).module("nanoui");
    // Clay (a C layout library), for its twin of the scenes: its header
    // translated for Zig, and compiled with its implementation.
    const clay = b.dependency("clay", .{});
    const clay_c = b.addTranslateC(.{ .root_source_file = clay.path("clay.h"), .target = target, .optimize = optimize });
    const exe = b.addExecutable(.{
        .name = "hillclimb",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "nanoui", .module = nanoui }, .{ .name = "clay", .module = clay_c.createModule() } },
            .link_libc = true,
        }),
    });
    exe.root_module.addCSourceFile(.{ .file = clay.path("clay.h"), .flags = &.{ "-DCLAY_IMPLEMENTATION", "-O3" }, .language = .c });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.setCwd(b.path("."));
    run.addPassthruArgs();
    b.step("run", "Run the hill-climb benchmarks (headless)").dependOn(&run.step);
}
