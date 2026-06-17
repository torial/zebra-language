const std = @import("std");
pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zz_dep = b.dependency("zigzag", .{
        .target   = target,
        .optimize = optimize,
    });
    const app_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target           = target,
        .optimize         = optimize,
    });
    app_mod.addImport("zigzag", zz_dep.module("zigzag"));
    const exe = b.addExecutable(.{
        .name        = "app",
        .root_module = app_mod,
    });
    b.installArtifact(exe);
    const run_step = b.addRunArtifact(exe);
    b.step("run", "Run the app").dependOn(&run_step.step);
}
