const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "gameboy_zig",
        .root_module = exe_mod,
    });

    exe.addIncludePath(b.path("vendor"));
    exe.addIncludePath(b.path("vendor/glad/include"));
    exe.addCSourceFile(.{ .file = b.path("vendor/glad/src/gl.c") });
    exe.addCSourceFile(.{ .file = b.path("vendor/miniaudio.c"), .flags = &.{ "-fno-sanitize=undefined", "-Wno-incompatible-function-pointer-types" } });

    exe.linkSystemLibrary("glfw3");

    switch (target.result.os.tag) {
        .macos => {
            exe.linkFramework("OpenGL");
            exe.linkFramework("Cocoa");
            exe.linkFramework("IOKit");
            exe.linkFramework("CoreAudio");
            exe.linkFramework("AudioToolbox");
        },
        .windows => {
            exe.linkSystemLibrary("opengl32");
            exe.linkSystemLibrary("gdi32");
        },
        else => {
            exe.linkSystemLibrary("GL");
            exe.linkSystemLibrary("X11");
        },
    }

    exe.linkSystemLibrary("c");

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
