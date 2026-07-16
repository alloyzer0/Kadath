const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const platform_mod = b.createModule(.{
        .root_source_file = b.path("modules/platform/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const rhi_mod = b.createModule(.{
        .root_source_file = b.path("modules/rhi/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("app/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("platform", platform_mod);
    exe_mod.addImport("rhi", rhi_mod);

    if (target.result.os.tag == .windows) {
        platform_mod.linkSystemLibrary("user32", .{});
        platform_mod.linkSystemLibrary("gdi32", .{});

        // Work around Zig 0.16 translating unused MinGW fortified wchar wrappers in ReleaseSafe.
        platform_mod.addCMacro("_FORTIFY_SOURCE", "0");
        rhi_mod.addCMacro("_FORTIFY_SOURCE", "0");

        const sdk_root = b.option([]const u8, "vulkan-sdk", "Vulkan SDK root") orelse
            (b.graph.environ_map.get("VULKAN_SDK") orelse
                @panic("VULKAN_SDK is required for the Windows Vulkan backend"));
        const include_path = b.pathJoin(&.{ sdk_root, "Include" });
        const library_path = b.pathJoin(&.{ sdk_root, "Lib" });

        rhi_mod.addIncludePath(.{ .cwd_relative = include_path });
        rhi_mod.addLibraryPath(.{ .cwd_relative = library_path });
        rhi_mod.linkSystemLibrary("vulkan-1", .{});
    }

    const exe = b.addExecutable(.{
        .name = "kadath",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the Kadath host");
    run_step.dependOn(&run_cmd.step);
}
