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

    const resource_mod = b.createModule(.{
        .root_source_file = b.path("modules/resource/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const audio_mod = b.createModule(.{
        .root_source_file = b.path("modules/audio/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const world_mod = b.createModule(.{
        .root_source_file = b.path("modules/world/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    world_mod.addIncludePath(b.path("abi"));

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
    exe_mod.addImport("resource", resource_mod);
    exe_mod.addImport("audio", audio_mod);
    exe_mod.addImport("renderer2d", renderer2d_mod);
    exe_mod.addImport("world", world_mod);

    if (target.result.os.tag == .windows) {
        platform_mod.linkSystemLibrary("user32", .{});
        platform_mod.linkSystemLibrary("gdi32", .{});
        audio_mod.linkSystemLibrary("winmm", .{});

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

    if (target.result.os.tag == .windows) {
        const rust_target = switch (target.result.cpu.arch) {
            .x86_64 => "x86_64-pc-windows-gnu",
            else => @panic("P2-M0-05 currently supports only x86_64 Windows Rust linking"),
        };
        const cargo_target_dir = b.pathFromRoot(".zig-cache/cargo");
        const cargo_build = b.addSystemCommand(&.{
            "cargo",
            "build",
            "--manifest-path",
            b.pathFromRoot("Cargo.toml"),
            "--target",
            rust_target,
            "--target-dir",
            cargo_target_dir,
        });
        if (optimize != .Debug) cargo_build.addArg("--release");

        // Cargo 产物必须先生成，再由 Zig 的 GNU 链接器合入同一可执行文件。
        exe.step.dependOn(&cargo_build.step);
        const rust_profile = if (optimize == .Debug) "debug" else "release";
        exe.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ cargo_target_dir, rust_target, rust_profile }) });
        const gcc_runtime_dir = b.option([]const u8, "mingw-gcc-runtime-dir", "Directory containing libgcc_eh.a for Rust panic unwinding") orelse
            "C:\\ProgramTools\\mingw64\\lib\\gcc\\x86_64-w64-mingw32\\14.2.0";
        exe.root_module.addLibraryPath(.{ .cwd_relative = gcc_runtime_dir });
        exe.root_module.linkSystemLibrary("kadath_world", .{ .preferred_link_mode = .static });
        exe.root_module.linkSystemLibrary("gcc_eh", .{ .preferred_link_mode = .static });
        exe.root_module.linkSystemLibrary("kernel32", .{});
        exe.root_module.linkSystemLibrary("dbghelp", .{});
        exe.root_module.linkSystemLibrary("advapi32", .{});
        exe.root_module.linkSystemLibrary("bcrypt", .{});
        exe.root_module.linkSystemLibrary("ntdll", .{});
        exe.root_module.linkSystemLibrary("userenv", .{});
        exe.root_module.linkSystemLibrary("ws2_32", .{});
    }
    b.installArtifact(exe);

    // 分发目录以 bin 为运行工作目录，资产必须与 exe 保持稳定的相对位置。
    const install_assets = b.addInstallDirectory(.{
        .source_dir = b.path("assets"),
        .install_dir = .bin,
        .install_subdir = "assets",
    });
    b.getInstallStep().dependOn(&install_assets.step);
    const install_package_readme = b.addInstallFile(
        b.path("packaging/README.txt"),
        "README.txt",
    );
    b.getInstallStep().dependOn(&install_package_readme.step);

    const package_step = b.step("package", "Build the distributable runtime directory");
    package_step.dependOn(b.getInstallStep());

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the Kadath host");
    run_step.dependOn(&run_cmd.step);
}
