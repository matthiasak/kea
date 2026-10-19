const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Benchmarks measure release code unless told otherwise.
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode (default fast)") orelse .fast;

    const nanoui = b.dependency("nanoui", .{ .target = target, .optimize = optimize }).module("nanoui");
    const exe = b.addExecutable(.{
        .name = "hillclimb",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "nanoui", .module = nanoui }},
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.setCwd(b.path("."));
    run.addPassthruArgs();
    b.step("run", "Run the hill-climb benchmarks (headless)").dependOn(&run.step);
}
