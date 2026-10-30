const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });
    const exe = b.addExecutable(.{
        .name = "direnv",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize != .debug,
        }),
    });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.argv.append(b.allocator, .passthru) catch @panic("OOM");
    b.step("run", "Run direnv").dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/config.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    b.step("test", "Run parser tests").dependOn(&b.addRunArtifact(tests).step);
}
