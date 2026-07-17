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

    const renderer2d_mod = b.createModule(.{
        .root_source_file = b.path("modules/renderer2d/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    renderer2d_mod.addImport("rhi", rhi_mod);
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("app/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("platform", platform_mod);
    exe_mod.addImport("rhi", rhi_mod);
    exe_mod.addImport("renderer2d", renderer2d_mod);

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

        const glslc_path = b.pathJoin(&.{ sdk_root, "Bin", "glslc.exe" });

        const vertex_shader_cmd = b.addSystemCommand(&.{glslc_path});
        vertex_shader_cmd.addArgs(&.{ "-c", "--target-env=vulkan1.0", "-O", "-mfmt=c", "-fshader-stage=vert" });
        vertex_shader_cmd.addFileArg(b.path("shaders/renderer2d/quad.vert.glsl"));
        vertex_shader_cmd.addArg("-o");
        const vertex_shader_inc = vertex_shader_cmd.addOutputFileArg("renderer2d_quad.vert.inc");

        const fragment_shader_cmd = b.addSystemCommand(&.{glslc_path});
        fragment_shader_cmd.addArgs(&.{ "-c", "--target-env=vulkan1.0", "-O", "-mfmt=c", "-fshader-stage=frag" });
        fragment_shader_cmd.addFileArg(b.path("shaders/renderer2d/quad.frag.glsl"));
        fragment_shader_cmd.addArg("-o");
        const fragment_shader_inc = fragment_shader_cmd.addOutputFileArg("renderer2d_quad.frag.inc");

        renderer2d_mod.addIncludePath(vertex_shader_inc.dirname());
        renderer2d_mod.addIncludePath(fragment_shader_inc.dirname());
        renderer2d_mod.addCSourceFile(.{
            .file = b.path("shaders/renderer2d/embed_vert.c"),
        });
        renderer2d_mod.addCSourceFile(.{
            .file = b.path("shaders/renderer2d/embed_frag.c"),
        });

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
