const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "worst_ever_image_viewer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{},
        }),
    });

    exe.addIncludePath(b.path("vendor/wayland"));
    exe.addIncludePath(b.path("vendor/wayland-protocols"));
    exe.addIncludePath(b.path("vendor/webp"));
    exe.addCSourceFile(.{
        .file = b.path("vendor/wayland-protocols/xdg-shell-client-protocol.c"),
        .flags = &.{},
    });
    exe.addCSourceFile(.{
        .file = b.path("vendor/wayland-protocols/xdg-decoration-unstable-v1-client-protocol.c"),
        .flags = &.{},
    });
    exe.addLibraryPath(b.path("lib"));
    exe.linkLibC();
    exe.linkSystemLibrary("wayland-client");
    exe.linkSystemLibrary("webp");

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
