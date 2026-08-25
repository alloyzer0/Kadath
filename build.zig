const std = @import("std");

const BehaviorScriptGraph = struct {
    native_step: *std.Build.Step,
    artifact_module: *std.Build.Module,
    manifest_module: *std.Build.Module,
    package_builder_module: *std.Build.Module,
    runtime_module: *std.Build.Module,
    scene_binding_module: *std.Build.Module,
    tooling_module: *std.Build.Module,
    tool: *std.Build.Step.Compile,
    tool_install_step: *std.Build.Step,
    tool_binary: std.Build.LazyPath,
};

fn addBehaviorScriptGraph(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    exe: *std.Build.Step.Compile,
    exe_module: *std.Build.Module,
) BehaviorScriptGraph {
    const behavior_build_type = if (optimize == .Debug) "Debug" else "Release";
    const behavior_build_dir = b.pathFromRoot(b.fmt(
        ".zig-cache/behavior-script-{s}-{s}",
        .{ @tagName(target.result.os.tag), @tagName(optimize) },
    ));
    const cmake_zig_exe = if (target.result.os.tag == .windows)
        std.mem.replaceOwned(u8, b.allocator, b.graph.zig_exe, "\\", "/") catch @panic("OOM")
    else
        b.graph.zig_exe;
    const behavior_configure = b.addSystemCommand(&.{
        "cmake",
        "-G",
        "Ninja",
        "-S",
        b.pathFromRoot("modules/behavior_script/native"),
        "-B",
        behavior_build_dir,
        b.fmt("-DCMAKE_BUILD_TYPE={s}", .{behavior_build_type}),
        b.fmt("-DCMAKE_C_COMPILER={s}", .{cmake_zig_exe}),
        "-DCMAKE_C_COMPILER_ARG1=cc",
        b.fmt("-DCMAKE_CXX_COMPILER={s}", .{cmake_zig_exe}),
        "-DCMAKE_CXX_COMPILER_ARG1=c++",
        "-DLUAU_BUILD_CLI=OFF",
        "-DLUAU_BUILD_TESTS=OFF",
        "-DLUAU_BUILD_WEB=OFF",
    });
    const behavior_native_build = b.addSystemCommand(&.{
        "cmake",
        "--build",
        behavior_build_dir,
        "--parallel",
        "8",
        "--target",
        "kadath_luau_runtime",
        "kadath_luau_tooling",
    });
    behavior_native_build.step.dependOn(&behavior_configure.step);

    const common_module = b.createModule(.{
        .root_source_file = b.path("modules/behavior_script/src/common.zig"),
        .target = target,
        .optimize = optimize,
    });
    const artifact_module = b.createModule(.{
        .root_source_file = b.path("modules/behavior_script/src/artifact.zig"),
        .target = target,
        .optimize = optimize,
    });
    artifact_module.addImport("behavior_common", common_module);
    const manifest_module = b.createModule(.{
        .root_source_file = b.path("modules/behavior_script/src/manifest.zig"),
        .target = target,
        .optimize = optimize,
    });
    manifest_module.addImport("behavior_common", common_module);

    const runtime_module = b.createModule(.{
        .root_source_file = b.path("modules/behavior_script/src/runtime.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    runtime_module.addIncludePath(b.path("modules/behavior_script/native"));
    runtime_module.addIncludePath(b.path("abi"));
    runtime_module.addImport("behavior_common", common_module);
    runtime_module.addImport("behavior_artifact", artifact_module);
    runtime_module.addLibraryPath(.{ .cwd_relative = behavior_build_dir });
    runtime_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ behavior_build_dir, "luau" }) });
    runtime_module.linkSystemLibrary("kadath_luau_runtime", .{ .preferred_link_mode = .static });
    runtime_module.linkSystemLibrary("Luau.VM", .{ .preferred_link_mode = .static });
    runtime_module.linkSystemLibrary("Luau.Common", .{ .preferred_link_mode = .static });

    const scene_binding_module = b.createModule(.{
        .root_source_file = b.path("modules/behavior_script/src/scene_binding.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    scene_binding_module.addImport("behavior_common", common_module);
    scene_binding_module.addImport("behavior_artifact", artifact_module);
    scene_binding_module.addImport("behavior_runtime", runtime_module);

    const tooling_module = b.createModule(.{
        .root_source_file = b.path("modules/behavior_script/src/tooling.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    tooling_module.addIncludePath(b.path("modules/behavior_script/native"));
    tooling_module.addIncludePath(b.path("abi"));
    tooling_module.addImport("behavior_common", common_module);
    tooling_module.addLibraryPath(.{ .cwd_relative = behavior_build_dir });
    tooling_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ behavior_build_dir, "luau" }) });
    tooling_module.linkSystemLibrary("kadath_luau_tooling", .{ .preferred_link_mode = .static });
    tooling_module.linkSystemLibrary("Luau.Analysis", .{ .preferred_link_mode = .static });
    tooling_module.linkSystemLibrary("Luau.Config", .{ .preferred_link_mode = .static });
    tooling_module.linkSystemLibrary("Luau.Compiler", .{ .preferred_link_mode = .static });
    tooling_module.linkSystemLibrary("Luau.Ast", .{ .preferred_link_mode = .static });
    tooling_module.linkSystemLibrary("Luau.Bytecode", .{ .preferred_link_mode = .static });
    tooling_module.linkSystemLibrary("Luau.VM", .{ .preferred_link_mode = .static });
    tooling_module.linkSystemLibrary("Luau.Common", .{ .preferred_link_mode = .static });

    const package_builder_module = b.createModule(.{
        .root_source_file = b.path("modules/behavior_script/src/package_builder.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    package_builder_module.addImport("behavior_common", common_module);
    package_builder_module.addImport("behavior_artifact", artifact_module);
    package_builder_module.addImport("behavior_manifest", manifest_module);
    package_builder_module.addImport("behavior_tooling", tooling_module);

    const behavior_tool_module = b.createModule(.{
        .root_source_file = b.path("tools/behavior-script-tool.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    behavior_tool_module.addImport("behavior_manifest", manifest_module);
    behavior_tool_module.addImport("behavior_package_builder", package_builder_module);
    behavior_tool_module.addImport("behavior_tooling", tooling_module);
    const behavior_tool = b.addExecutable(.{
        .name = "kadath-behavior-tool",
        .root_module = behavior_tool_module,
    });
    behavior_tool.step.dependOn(&behavior_native_build.step);
    const behavior_tool_build_step = b.step("build-behavior-script-tool", "Build the native Luau behavior Publication adapter");
    behavior_tool_build_step.dependOn(&behavior_tool.step);
    const behavior_tool_install = b.addInstallArtifact(behavior_tool, .{
        .dest_dir = .{ .override = .prefix },
        .dest_sub_path = if (target.result.os.tag == .windows)
            "behavior-tools/kadath-behavior-tool.exe"
        else
            "behavior-tools/kadath-behavior-tool",
        .pdb_dir = .disabled,
    });
    const behavior_tool_install_step = b.step("install-behavior-script-tool", "Install the native Luau behavior Publication adapter");
    behavior_tool_install_step.dependOn(&behavior_tool_install.step);

    // Host、Package Builder 与 Editor Adapter 共用同一组 Luau native 产物和 ABI module。
    exe_module.addImport("behavior_artifact", artifact_module);
    exe_module.addImport("behavior_runtime", runtime_module);
    exe_module.addImport("behavior_scene_binding", scene_binding_module);
    exe.step.dependOn(&behavior_native_build.step);

    return .{
        .native_step = &behavior_native_build.step,
        .artifact_module = artifact_module,
        .manifest_module = manifest_module,
        .package_builder_module = package_builder_module,
        .runtime_module = runtime_module,
        .scene_binding_module = scene_binding_module,
        .tooling_module = tooling_module,
        .tool = behavior_tool,
        .tool_install_step = &behavior_tool_install.step,
        .tool_binary = behavior_tool.getEmittedBin(),
    };
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const linux_package_supported = target.query.isNative() and
        target.result.cpu.arch == .x86_64 and
        target.result.os.tag == .linux and
        target.result.abi == .gnu;
    const configured_glslc = b.option([]const u8, "glslc", "Absolute path to the glslc executable");
    const configured_alsa_include_dir = b.option([]const u8, "alsa-include-dir", "Directory containing alsa/asoundlib.h");
    const configured_alsa_library_dir = b.option([]const u8, "alsa-library-dir", "Directory containing libasound.so");
    const phase_quality_evidence = b.option(bool, "phase-quality-evidence", "Build Runtime Core with non-production Phase allocation counters") orelse false;
    const phase_quality_behavior_filter = b.option([]const u8, "phase-quality-behavior-filter", "Run only matching Behavior Host contracts for Phase coverage evidence");
    const phase_quality_emit_dir = b.option([]const u8, "phase-quality-emit-dir", "Install Phase evidence executables into this directory without running them");
    const gameplay_quality_evidence = b.option(bool, "gameplay-quality-evidence", "Build Runtime Core with non-production Gameplay allocation counters") orelse false;
    const gameplay_quality_emit_dir = b.option([]const u8, "gameplay-quality-emit-dir", "Install Gameplay evidence executables into this directory without running them");
    const quality_evidence_enabled = phase_quality_evidence or gameplay_quality_evidence;
    const quality_emit_dir = gameplay_quality_emit_dir orelse phase_quality_emit_dir;
    var linux_platform_contract_binary: ?std.Build.LazyPath = null;
    var linux_window_verifier_binary: ?std.Build.LazyPath = null;
    const mingw_gcc_runtime_dir: ?[]const u8 = if (target.result.os.tag == .windows)
        b.option([]const u8, "mingw-gcc-runtime-dir", "Directory containing libgcc_eh.a for Rust panic unwinding") orelse
            "C:\\ProgramTools\\mingw64\\lib\\gcc\\x86_64-w64-mingw32\\14.2.0"
    else
        null;
    const native_surface_mod = b.createModule(.{
        .root_source_file = b.path("modules/platform/src/native_surface.zig"),
        .target = target,
        .optimize = optimize,
    });
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
    platform_mod.addImport("native_surface", native_surface_mod);
    rhi_mod.addImport("native_surface", native_surface_mod);

    const resource_mod = b.createModule(.{
        .root_source_file = b.path("modules/resource/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const scheduler_mod = b.createModule(.{
        .root_source_file = b.path("modules/scheduler/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    scheduler_mod.addIncludePath(b.path("abi"));
    resource_mod.addImport("scheduler", scheduler_mod);
    const audio_mod = b.createModule(.{
        .root_source_file = b.path("modules/audio/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = target.result.os.tag == .linux,
    });
    const preview_status_mod = b.createModule(.{
        .root_source_file = b.path("app/preview_status.zig"),
        .target = target,
        .optimize = optimize,
    });
    const preview_control_mod = b.createModule(.{
        .root_source_file = b.path("app/preview_control.zig"),
        .target = target,
        .optimize = optimize,
    });
    const runtime_options_mod = b.createModule(.{
        .root_source_file = b.path("app/runtime_options.zig"),
        .target = target,
        .optimize = optimize,
    });

    const runtime_core_mod = b.createModule(.{
        .root_source_file = b.path("modules/runtime_core/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    runtime_core_mod.addIncludePath(b.path("abi"));

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
    exe_mod.addImport("runtime_core", runtime_core_mod);
    exe_mod.addImport("preview_status", preview_status_mod);

    var glslc_path = configured_glslc orelse "glslc";
    switch (target.result.os.tag) {
        .windows => {
            platform_mod.linkSystemLibrary("user32", .{});
            platform_mod.linkSystemLibrary("gdi32", .{});
            audio_mod.linkSystemLibrary("winmm", .{});

            // Work around Zig 0.16 translating unused MinGW fortified wchar wrappers in ReleaseSafe.
            platform_mod.addCMacro("_FORTIFY_SOURCE", "0");
            rhi_mod.addCMacro("_FORTIFY_SOURCE", "0");

            var sdk_root: ?[]const u8 = b.option([]const u8, "vulkan-sdk", "Vulkan SDK root");
            if (sdk_root == null) sdk_root = b.graph.environ_map.get("VULKAN_SDK");
            if (sdk_root) |root| {
                rhi_mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ root, "Include" }) });
                rhi_mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ root, "Lib" }) });
                if (configured_glslc == null) glslc_path = b.pathJoin(&.{ root, "Bin", "glslc.exe" });
            }
            rhi_mod.linkSystemLibrary("vulkan-1", .{});
        },
        .linux => {
            platform_mod.linkSystemLibrary("xcb", .{});
            rhi_mod.linkSystemLibrary("vulkan", .{});
            audio_mod.addCMacro("_FORTIFY_SOURCE", "0");
            if (configured_alsa_include_dir) |include_dir| {
                audio_mod.addIncludePath(.{ .cwd_relative = include_dir });
            }
            if (configured_alsa_library_dir) |library_dir| {
                audio_mod.addLibraryPath(.{ .cwd_relative = library_dir });
            }
            audio_mod.linkSystemLibrary("asound", .{});
        },
        else => {},
    }

    if (target.result.os.tag == .windows or target.result.os.tag == .linux) {
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
    }

    const exe = b.addExecutable(.{
        .name = "kadath",
        .root_module = exe_mod,
    });
    const runtime_build_step = b.step("build-runtime", "Build the production runtime without packaging");
    runtime_build_step.dependOn(&exe.step);

    var async_texture_test_step: ?*std.Build.Step = null;
    var runtime_core_cargo_step: ?*std.Build.Step = null;
    var runtime_core_library_path: ?[]const u8 = null;
    var behavior_native_step: ?*std.Build.Step = null;
    var behavior_artifact_mod: ?*std.Build.Module = null;
    var behavior_manifest_mod: ?*std.Build.Module = null;
    var behavior_package_builder_mod: ?*std.Build.Module = null;
    var behavior_runtime_mod: ?*std.Build.Module = null;
    var behavior_scene_binding_mod: ?*std.Build.Module = null;
    var behavior_tooling_mod: ?*std.Build.Module = null;
    var behavior_tool_install_artifact_step: ?*std.Build.Step = null;
    var behavior_tool_executable: ?*std.Build.Step.Compile = null;
    var behavior_tool_binary: ?std.Build.LazyPath = null;
    const behavior_supported = target.query.isNative() and
        target.result.cpu.arch == .x86_64 and
        (target.result.os.tag == .windows or target.result.os.tag == .linux);
    if (behavior_supported) {
        const behavior = addBehaviorScriptGraph(b, target, optimize, exe, exe_mod);
        behavior_native_step = behavior.native_step;
        behavior_artifact_mod = behavior.artifact_module;
        behavior_manifest_mod = behavior.manifest_module;
        behavior_package_builder_mod = behavior.package_builder_module;
        behavior_runtime_mod = behavior.runtime_module;
        behavior_scene_binding_mod = behavior.scene_binding_module;
        behavior_tooling_mod = behavior.tooling_module;
        behavior_tool_executable = behavior.tool;
        behavior_tool_install_artifact_step = behavior.tool_install_step;
        behavior_tool_binary = behavior.tool_binary;
    }
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
        if (quality_evidence_enabled) cargo_build.addArgs(&.{ "--features", "phase-quality-evidence" });

        // Cargo 产物必须先生成，再由 Zig 的 GNU 链接器合入同一可执行文件。
        exe.step.dependOn(&cargo_build.step);
        const rust_profile = if (optimize == .Debug) "debug" else "release";
        const rust_library_path = b.pathJoin(&.{ cargo_target_dir, rust_target, rust_profile });
        runtime_core_cargo_step = &cargo_build.step;
        runtime_core_library_path = rust_library_path;
        exe.root_module.addLibraryPath(.{ .cwd_relative = rust_library_path });
        const gcc_runtime_dir = mingw_gcc_runtime_dir.?;
        exe.root_module.addLibraryPath(.{ .cwd_relative = gcc_runtime_dir });
        exe.root_module.linkSystemLibrary("kadath_runtime_core", .{ .preferred_link_mode = .static });
        exe.root_module.linkSystemLibrary("kadath_scheduler", .{ .preferred_link_mode = .static });
        exe.root_module.linkSystemLibrary("gcc_eh", .{ .preferred_link_mode = .static });
        exe.root_module.linkSystemLibrary("kernel32", .{});
        exe.root_module.linkSystemLibrary("dbghelp", .{});
        exe.root_module.linkSystemLibrary("advapi32", .{});
        exe.root_module.linkSystemLibrary("bcrypt", .{});
        exe.root_module.linkSystemLibrary("ntdll", .{});
        exe.root_module.linkSystemLibrary("userenv", .{});
        exe.root_module.linkSystemLibrary("ws2_32", .{});

        const async_texture_test_mod = b.createModule(.{
            .root_source_file = b.path("modules/resource/tests/async_texture_integration.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        async_texture_test_mod.addImport("resource", resource_mod);
        const async_texture_tests = b.addTest(.{ .root_module = async_texture_test_mod });
        const async_texture_test_run = b.addRunArtifact(async_texture_tests);
        const windows_async_texture_test_step = b.step("test-resource-async", "Run Resource-owned async texture tests without GPU");
        windows_async_texture_test_step.dependOn(&async_texture_test_run.step);
        async_texture_test_step = windows_async_texture_test_step;
        // 直接约束测试编译节点，确保冷缓存时先生成 Scheduler staticlib，再解析 -l 链接输入。
        async_texture_tests.step.dependOn(&cargo_build.step);
        // 该测试与最终 Host 共用同一 Scheduler staticlib，避免“测试拼 bytes”假集成。
        async_texture_test_mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ cargo_target_dir, rust_target, rust_profile }) });
        async_texture_test_mod.addLibraryPath(.{ .cwd_relative = gcc_runtime_dir });
        async_texture_test_mod.linkSystemLibrary("kadath_scheduler", .{ .preferred_link_mode = .static });
        async_texture_test_mod.linkSystemLibrary("gcc_eh", .{ .preferred_link_mode = .static });
        async_texture_test_mod.linkSystemLibrary("kernel32", .{});
        async_texture_test_mod.linkSystemLibrary("dbghelp", .{});
        async_texture_test_mod.linkSystemLibrary("advapi32", .{});
        async_texture_test_mod.linkSystemLibrary("bcrypt", .{});
        async_texture_test_mod.linkSystemLibrary("ntdll", .{});
        async_texture_test_mod.linkSystemLibrary("userenv", .{});
        async_texture_test_mod.linkSystemLibrary("ws2_32", .{});
    } else if (target.result.os.tag == .linux and target.result.cpu.arch == .x86_64) {
        exe.each_lib_rpath = false;
        const rust_target = switch (target.result.cpu.arch) {
            .x86_64 => "x86_64-unknown-linux-gnu",
            else => @panic("P2-Linux-Window-01 supports only x86_64 Linux Rust linking"),
        };
        const cargo_target_dir = b.pathFromRoot(".zig-cache/cargo");
        const cargo_build = b.addSystemCommand(&.{
            "cargo",
            "build",
            "--locked",
            "--manifest-path",
            b.pathFromRoot("Cargo.toml"),
            "--target",
            rust_target,
            "--target-dir",
            cargo_target_dir,
        });
        if (optimize != .Debug) cargo_build.addArg("--release");
        if (quality_evidence_enabled) cargo_build.addArgs(&.{ "--features", "phase-quality-evidence" });

        exe.step.dependOn(&cargo_build.step);
        const rust_profile = if (optimize == .Debug) "debug" else "release";
        const rust_library_path = b.pathJoin(&.{ cargo_target_dir, rust_target, rust_profile });
        runtime_core_cargo_step = &cargo_build.step;
        runtime_core_library_path = rust_library_path;
        exe.root_module.addLibraryPath(.{ .cwd_relative = rust_library_path });
        exe.root_module.linkSystemLibrary("kadath_runtime_core", .{ .preferred_link_mode = .static });
        exe.root_module.linkSystemLibrary("kadath_scheduler", .{ .preferred_link_mode = .static });
        exe.root_module.linkSystemLibrary("gcc_s", .{});
        exe.root_module.linkSystemLibrary("util", .{});
        exe.root_module.linkSystemLibrary("rt", .{});
        exe.root_module.linkSystemLibrary("pthread", .{});
        exe.root_module.linkSystemLibrary("m", .{});
        exe.root_module.linkSystemLibrary("dl", .{});
    }
    const install_exe = b.addInstallArtifact(exe, .{ .pdb_dir = .disabled });
    b.getInstallStep().dependOn(&install_exe.step);
    const preview_status_tests = b.addTest(.{
        .root_module = preview_status_mod,
    });
    const preview_status_test_run = b.addRunArtifact(preview_status_tests);
    const preview_control_tests = b.addTest(.{
        .root_module = preview_control_mod,
    });
    const preview_control_test_run = b.addRunArtifact(preview_control_tests);
    const runtime_options_tests = b.addTest(.{
        .root_module = runtime_options_mod,
    });
    const runtime_options_test_run = b.addRunArtifact(runtime_options_tests);
    const test_step = b.step("test", "Run Preview protocol unit tests");
    test_step.dependOn(&preview_status_test_run.step);
    test_step.dependOn(&preview_control_test_run.step);
    test_step.dependOn(&runtime_options_test_run.step);
    const player_movement_ownership_mod = b.createModule(.{
        .root_source_file = b.path("app/player_movement_ownership.zig"),
        .target = target,
        .optimize = optimize,
    });
    const player_movement_ownership_tests = b.addTest(.{ .root_module = player_movement_ownership_mod });
    const player_movement_ownership_test_run = b.addRunArtifact(player_movement_ownership_tests);
    const player_movement_ownership_test_step = b.step("test-player-movement-ownership", "Run Player movement ownership contracts");
    player_movement_ownership_test_step.dependOn(&player_movement_ownership_test_run.step);
    test_step.dependOn(player_movement_ownership_test_step);

    if (behavior_native_step) |native_step| {
        const behavior_contract_test_mod = b.createModule(.{
            .root_source_file = b.path("modules/behavior_script/tests/native_contract.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        });
        behavior_contract_test_mod.addIncludePath(b.path("modules/behavior_script/native"));
        behavior_contract_test_mod.addIncludePath(b.path("abi"));
        behavior_contract_test_mod.addImport("behavior_runtime", behavior_runtime_mod.?);
        behavior_contract_test_mod.addImport("behavior_tooling", behavior_tooling_mod.?);
        const behavior_contract_tests = b.addTest(.{ .root_module = behavior_contract_test_mod });
        behavior_contract_tests.step.dependOn(native_step);
        const behavior_contract_test_run = b.addRunArtifact(behavior_contract_tests);
        const behavior_artifact_test_mod = b.createModule(.{
            .root_source_file = b.path("modules/behavior_script/tests/artifact_contract.zig"),
            .target = target,
            .optimize = optimize,
        });
        behavior_artifact_test_mod.addImport("behavior_artifact", behavior_artifact_mod.?);
        const behavior_artifact_tests = b.addTest(.{ .root_module = behavior_artifact_test_mod });
        const behavior_artifact_test_run = b.addRunArtifact(behavior_artifact_tests);
        const behavior_manifest_test_mod = b.createModule(.{
            .root_source_file = b.path("modules/behavior_script/tests/manifest_contract.zig"),
            .target = target,
            .optimize = optimize,
        });
        behavior_manifest_test_mod.addImport("behavior_manifest", behavior_manifest_mod.?);
        const behavior_manifest_tests = b.addTest(.{ .root_module = behavior_manifest_test_mod });
        const behavior_manifest_test_run = b.addRunArtifact(behavior_manifest_tests);
        const behavior_package_builder_test_mod = b.createModule(.{
            .root_source_file = b.path("modules/behavior_script/tests/package_builder_contract.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        });
        behavior_package_builder_test_mod.addImport("behavior_artifact", behavior_artifact_mod.?);
        behavior_package_builder_test_mod.addImport("behavior_manifest", behavior_manifest_mod.?);
        behavior_package_builder_test_mod.addImport("behavior_package_builder", behavior_package_builder_mod.?);
        behavior_package_builder_test_mod.addImport("behavior_tooling", behavior_tooling_mod.?);
        const behavior_package_builder_tests = b.addTest(.{ .root_module = behavior_package_builder_test_mod });
        behavior_package_builder_tests.step.dependOn(native_step);
        const behavior_package_builder_test_run = b.addRunArtifact(behavior_package_builder_tests);
        const behavior_runtime_package_test_mod = b.createModule(.{
            .root_source_file = b.path("modules/behavior_script/tests/runtime_package_contract.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        });
        behavior_runtime_package_test_mod.addImport("behavior_package_builder", behavior_package_builder_mod.?);
        behavior_runtime_package_test_mod.addImport("behavior_manifest", behavior_manifest_mod.?);
        behavior_runtime_package_test_mod.addImport("behavior_runtime", behavior_runtime_mod.?);
        const behavior_runtime_package_tests = b.addTest(.{ .root_module = behavior_runtime_package_test_mod });
        behavior_runtime_package_tests.step.dependOn(native_step);
        const behavior_runtime_package_test_run = b.addRunArtifact(behavior_runtime_package_tests);
        const behavior_scene_binding_test_mod = b.createModule(.{
            .root_source_file = b.path("modules/behavior_script/tests/scene_binding_contract.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        });
        behavior_scene_binding_test_mod.addImport("behavior_artifact", behavior_artifact_mod.?);
        behavior_scene_binding_test_mod.addImport("behavior_manifest", behavior_manifest_mod.?);
        behavior_scene_binding_test_mod.addImport("behavior_package_builder", behavior_package_builder_mod.?);
        behavior_scene_binding_test_mod.addImport("behavior_runtime", behavior_runtime_mod.?);
        behavior_scene_binding_test_mod.addImport("behavior_scene_binding", behavior_scene_binding_mod.?);
        const behavior_scene_binding_tests = b.addTest(.{ .root_module = behavior_scene_binding_test_mod });
        behavior_scene_binding_tests.step.dependOn(native_step);
        const behavior_scene_binding_test_run = b.addRunArtifact(behavior_scene_binding_tests);
        const behavior_scene_adapter_test_mod = b.createModule(.{
            .root_source_file = b.path("app/behavior_scene_adapter.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        });
        behavior_scene_adapter_test_mod.addImport("behavior_artifact", behavior_artifact_mod.?);
        behavior_scene_adapter_test_mod.addImport("behavior_scene_binding", behavior_scene_binding_mod.?);
        const behavior_scene_adapter_tests = b.addTest(.{ .root_module = behavior_scene_adapter_test_mod });
        behavior_scene_adapter_tests.step.dependOn(native_step);
        const behavior_scene_adapter_test_run = b.addRunArtifact(behavior_scene_adapter_tests);
        const behavior_host_test_mod = b.createModule(.{
            .root_source_file = b.path("app/behavior_host_contract.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        });
        behavior_host_test_mod.addImport("behavior_artifact", behavior_artifact_mod.?);
        behavior_host_test_mod.addImport("behavior_manifest", behavior_manifest_mod.?);
        behavior_host_test_mod.addImport("behavior_package_builder", behavior_package_builder_mod.?);
        behavior_host_test_mod.addImport("behavior_runtime", behavior_runtime_mod.?);
        behavior_host_test_mod.addImport("behavior_scene_binding", behavior_scene_binding_mod.?);
        behavior_host_test_mod.addImport("platform", platform_mod);
        behavior_host_test_mod.addImport("runtime_core", runtime_core_mod);
        const behavior_host_tests = b.addTest(.{
            .root_module = behavior_host_test_mod,
            .filters = if (phase_quality_behavior_filter) |filter| &.{filter} else &.{},
            // kcov can consume Zig's LLVM DWARF v5 line tables, while the
            // self-hosted backend currently leaves the Phase evidence seam
            // without an auditable Zig source denominator.
            .use_llvm = if (quality_emit_dir != null) true else null,
        });
        behavior_host_tests.step.dependOn(native_step);
        if (runtime_core_library_path) |library_path| {
            behavior_host_tests.step.dependOn(runtime_core_cargo_step.?);
            behavior_host_test_mod.addLibraryPath(.{ .cwd_relative = library_path });
            behavior_host_test_mod.linkSystemLibrary("kadath_runtime_core", .{ .preferred_link_mode = .static });
            if (target.result.os.tag == .windows) {
                behavior_host_test_mod.addLibraryPath(.{ .cwd_relative = mingw_gcc_runtime_dir.? });
                behavior_host_test_mod.linkSystemLibrary("gcc_eh", .{ .preferred_link_mode = .static });
                behavior_host_test_mod.linkSystemLibrary("kernel32", .{});
                behavior_host_test_mod.linkSystemLibrary("dbghelp", .{});
                behavior_host_test_mod.linkSystemLibrary("advapi32", .{});
                behavior_host_test_mod.linkSystemLibrary("bcrypt", .{});
                behavior_host_test_mod.linkSystemLibrary("ntdll", .{});
                behavior_host_test_mod.linkSystemLibrary("userenv", .{});
                behavior_host_test_mod.linkSystemLibrary("ws2_32", .{});
            } else if (target.result.os.tag == .linux) {
                behavior_host_test_mod.linkSystemLibrary("gcc_s", .{});
                behavior_host_test_mod.linkSystemLibrary("util", .{});
                behavior_host_test_mod.linkSystemLibrary("rt", .{});
                behavior_host_test_mod.linkSystemLibrary("pthread", .{});
                behavior_host_test_mod.linkSystemLibrary("m", .{});
                behavior_host_test_mod.linkSystemLibrary("dl", .{});
            }
        }
        const behavior_host_test_run = b.addRunArtifact(behavior_host_tests);
        if (quality_emit_dir) |emit_dir| {
            const install_behavior_host_evidence = b.addInstallArtifact(behavior_host_tests, .{
                .dest_dir = .{ .override = .{ .custom = emit_dir } },
                .dest_sub_path = "behavior-host-contract",
            });
            const emit_behavior_host_evidence = b.step("emit-phase-behavior-contract", "Emit the Behavior Host Phase contract without running it");
            emit_behavior_host_evidence.dependOn(&install_behavior_host_evidence.step);
        }
        const behavior_tool_test_mod = b.createModule(.{
            .root_source_file = b.path("tools/behavior-script-tool.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        });
        behavior_tool_test_mod.addImport("behavior_manifest", behavior_manifest_mod.?);
        behavior_tool_test_mod.addImport("behavior_package_builder", behavior_package_builder_mod.?);
        behavior_tool_test_mod.addImport("behavior_tooling", behavior_tooling_mod.?);
        const behavior_tool_tests = b.addTest(.{ .root_module = behavior_tool_test_mod });
        behavior_tool_tests.step.dependOn(native_step);
        const behavior_tool_test_run = b.addRunArtifact(behavior_tool_tests);
        const behavior_contract_test_step = b.step("test-behavior-script", "Run native Luau behavior contract tests");
        behavior_contract_test_step.dependOn(&behavior_contract_test_run.step);
        behavior_contract_test_step.dependOn(&behavior_artifact_test_run.step);
        behavior_contract_test_step.dependOn(&behavior_manifest_test_run.step);
        behavior_contract_test_step.dependOn(&behavior_package_builder_test_run.step);
        behavior_contract_test_step.dependOn(&behavior_tool_test_run.step);
        behavior_contract_test_step.dependOn(&behavior_runtime_package_test_run.step);
        behavior_contract_test_step.dependOn(&behavior_scene_binding_test_run.step);
        behavior_contract_test_step.dependOn(&behavior_scene_adapter_test_run.step);
        behavior_contract_test_step.dependOn(&behavior_host_test_run.step);
        test_step.dependOn(&behavior_contract_test_run.step);
        test_step.dependOn(&behavior_artifact_test_run.step);
        test_step.dependOn(&behavior_manifest_test_run.step);
        test_step.dependOn(&behavior_package_builder_test_run.step);
        test_step.dependOn(&behavior_tool_test_run.step);
        test_step.dependOn(&behavior_runtime_package_test_run.step);
        test_step.dependOn(&behavior_scene_binding_test_run.step);
        test_step.dependOn(&behavior_scene_adapter_test_run.step);
        test_step.dependOn(&behavior_host_test_run.step);
    }

    if (runtime_core_library_path) |library_path| {
        const runtime_core_contract_mod = b.createModule(.{
            .root_source_file = b.path("modules/runtime_core/tests/runtime_core_contract.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        runtime_core_contract_mod.addImport("runtime_core", runtime_core_mod);
        runtime_core_contract_mod.addLibraryPath(.{ .cwd_relative = library_path });
        runtime_core_contract_mod.linkSystemLibrary("kadath_runtime_core", .{ .preferred_link_mode = .static });
        if (target.result.os.tag == .windows) {
            runtime_core_contract_mod.addLibraryPath(.{ .cwd_relative = mingw_gcc_runtime_dir.? });
            runtime_core_contract_mod.linkSystemLibrary("gcc_eh", .{ .preferred_link_mode = .static });
            runtime_core_contract_mod.linkSystemLibrary("kernel32", .{});
            runtime_core_contract_mod.linkSystemLibrary("dbghelp", .{});
            runtime_core_contract_mod.linkSystemLibrary("advapi32", .{});
            runtime_core_contract_mod.linkSystemLibrary("bcrypt", .{});
            runtime_core_contract_mod.linkSystemLibrary("ntdll", .{});
            runtime_core_contract_mod.linkSystemLibrary("userenv", .{});
            runtime_core_contract_mod.linkSystemLibrary("ws2_32", .{});
        } else if (target.result.os.tag == .linux) {
            runtime_core_contract_mod.linkSystemLibrary("gcc_s", .{});
            runtime_core_contract_mod.linkSystemLibrary("util", .{});
            runtime_core_contract_mod.linkSystemLibrary("rt", .{});
            runtime_core_contract_mod.linkSystemLibrary("pthread", .{});
            runtime_core_contract_mod.linkSystemLibrary("m", .{});
            runtime_core_contract_mod.linkSystemLibrary("dl", .{});
        }
        const runtime_core_contract_tests = b.addTest(.{
            .root_module = runtime_core_contract_mod,
            .use_llvm = if (quality_emit_dir != null) true else null,
        });
        runtime_core_contract_tests.step.dependOn(runtime_core_cargo_step.?);
        const runtime_core_contract_run = b.addRunArtifact(runtime_core_contract_tests);
        if (quality_emit_dir) |emit_dir| {
            const install_runtime_core_evidence = b.addInstallArtifact(runtime_core_contract_tests, .{
                .dest_dir = .{ .override = .{ .custom = emit_dir } },
                .dest_sub_path = "runtime-core-contract",
            });
            const emit_runtime_core_evidence = b.step("emit-phase-runtime-core-contract", "Emit the Runtime Core Phase contract without running it");
            emit_runtime_core_evidence.dependOn(&install_runtime_core_evidence.step);
        }
        const runtime_core_contract_step = b.step("test-runtime-core", "Run Runtime Core public Zig Adapter contracts");
        runtime_core_contract_step.dependOn(&runtime_core_contract_run.step);
        test_step.dependOn(runtime_core_contract_step);

        if (target.result.os.tag == .linux) {
            const runtime_core_bench_mod = b.createModule(.{
                .root_source_file = b.path("tools/runtime-core-phase-bench.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            });
            runtime_core_bench_mod.addIncludePath(b.path("abi"));
            runtime_core_bench_mod.addImport("runtime_core", runtime_core_mod);
            runtime_core_bench_mod.addLibraryPath(.{ .cwd_relative = library_path });
            runtime_core_bench_mod.linkSystemLibrary("kadath_runtime_core", .{ .preferred_link_mode = .static });
            runtime_core_bench_mod.linkSystemLibrary("gcc_s", .{});
            runtime_core_bench_mod.linkSystemLibrary("util", .{});
            runtime_core_bench_mod.linkSystemLibrary("rt", .{});
            runtime_core_bench_mod.linkSystemLibrary("pthread", .{});
            runtime_core_bench_mod.linkSystemLibrary("m", .{});
            runtime_core_bench_mod.linkSystemLibrary("dl", .{});
            const runtime_core_bench = b.addExecutable(.{
                .name = "runtime-core-phase-bench",
                .root_module = runtime_core_bench_mod,
            });
            runtime_core_bench.step.dependOn(runtime_core_cargo_step.?);
            const runtime_core_bench_run = b.addRunArtifact(runtime_core_bench);
            const runtime_core_bench_step = b.step("bench-runtime-core-phase", "Run the 10,000-batch Runtime Core Phase baseline");
            runtime_core_bench_step.dependOn(&runtime_core_bench_run.step);
            if (quality_emit_dir) |emit_dir| {
                const install_runtime_core_bench = b.addInstallArtifact(runtime_core_bench, .{
                    .dest_dir = .{ .override = .{ .custom = emit_dir } },
                    .dest_sub_path = "runtime-core-phase-bench",
                });
                const emit_runtime_core_bench = b.step("emit-phase-runtime-core-bench", "Emit the Runtime Core Phase benchmark without running it");
                emit_runtime_core_bench.dependOn(&install_runtime_core_bench.step);
            }

            if (gameplay_quality_evidence) {
                const gameplay_bench_mod = b.createModule(.{
                    .root_source_file = b.path("tools/runtime-core-gameplay-bench.zig"),
                    .target = target,
                    .optimize = optimize,
                    .link_libc = true,
                });
                gameplay_bench_mod.addIncludePath(b.path("abi"));
                gameplay_bench_mod.addImport("runtime_core", runtime_core_mod);
                gameplay_bench_mod.addLibraryPath(.{ .cwd_relative = library_path });
                gameplay_bench_mod.linkSystemLibrary("kadath_runtime_core", .{ .preferred_link_mode = .static });
                gameplay_bench_mod.linkSystemLibrary("gcc_s", .{});
                gameplay_bench_mod.linkSystemLibrary("util", .{});
                gameplay_bench_mod.linkSystemLibrary("rt", .{});
                gameplay_bench_mod.linkSystemLibrary("pthread", .{});
                gameplay_bench_mod.linkSystemLibrary("m", .{});
                gameplay_bench_mod.linkSystemLibrary("dl", .{});
                const gameplay_bench = b.addExecutable(.{
                    .name = "runtime-core-gameplay-bench",
                    .root_module = gameplay_bench_mod,
                });
                gameplay_bench.step.dependOn(runtime_core_cargo_step.?);
                const gameplay_bench_run = b.addRunArtifact(gameplay_bench);
                const gameplay_bench_step = b.step("bench-runtime-core-gameplay", "Run the 10,000-step Runtime Core Gameplay benchmark");
                gameplay_bench_step.dependOn(&gameplay_bench_run.step);
                if (gameplay_quality_emit_dir) |emit_dir| {
                    const install_gameplay_bench = b.addInstallArtifact(gameplay_bench, .{
                        .dest_dir = .{ .override = .{ .custom = emit_dir } },
                        .dest_sub_path = "runtime-core-gameplay-bench",
                    });
                    const emit_gameplay_bench = b.step("emit-runtime-core-gameplay-bench", "Emit the Runtime Core Gameplay benchmark without running it");
                    emit_gameplay_bench.dependOn(&install_gameplay_bench.step);
                }
            }

            const gameplay_oracle_mod = b.createModule(.{
                .root_source_file = b.path("tools/runtime-gameplay-oracle-bench.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            });
            gameplay_oracle_mod.addIncludePath(b.path("abi"));
            const gameplay_oracle = b.addExecutable(.{
                .name = "runtime-gameplay-oracle-bench",
                .root_module = gameplay_oracle_mod,
            });
            const gameplay_oracle_run = b.addRunArtifact(gameplay_oracle);
            const gameplay_oracle_step = b.step("bench-runtime-gameplay-oracle", "Run the 10,000-step frozen Zig Gameplay oracle benchmark");
            gameplay_oracle_step.dependOn(&gameplay_oracle_run.step);
            if (gameplay_quality_emit_dir) |emit_dir| {
                const install_gameplay_oracle = b.addInstallArtifact(gameplay_oracle, .{
                    .dest_dir = .{ .override = .{ .custom = emit_dir } },
                    .dest_sub_path = "runtime-gameplay-oracle-bench",
                });
                const emit_gameplay_oracle = b.step("emit-runtime-gameplay-oracle-bench", "Emit the frozen Zig Gameplay oracle benchmark without running it");
                emit_gameplay_oracle.dependOn(&install_gameplay_oracle.step);
            }
        }

        const contract_rust_target = if (target.result.os.tag == .windows)
            "x86_64-pc-windows-gnu"
        else
            "x86_64-unknown-linux-gnu";
        const contract_cargo_target_dir = b.pathFromRoot(".zig-cache/cargo-runtime-core-contract");
        const contract_cargo_build = b.addSystemCommand(&.{
            "cargo",
            "build",
            "--locked",
            "--manifest-path",
            b.pathFromRoot("Cargo.toml"),
            "--package",
            "kadath_runtime_core",
            "--features",
            "contract-test-hooks",
            "--target",
            contract_rust_target,
            "--target-dir",
            contract_cargo_target_dir,
        });
        if (optimize != .Debug) contract_cargo_build.addArg("--release");
        const contract_profile = if (optimize == .Debug) "debug" else "release";
        const contract_library_path = b.pathJoin(&.{ contract_cargo_target_dir, contract_rust_target, contract_profile });
        const runtime_core_public_c_mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        runtime_core_public_c_mod.addIncludePath(b.path("abi"));
        runtime_core_public_c_mod.addIncludePath(b.path("modules/runtime_core/tests"));
        runtime_core_public_c_mod.addCSourceFile(.{
            .file = b.path("modules/runtime_core/tests/public_contract.c"),
            .flags = &.{ "-std=c17", "-Wall", "-Wextra", "-Werror", "-pedantic" },
        });
        runtime_core_public_c_mod.addLibraryPath(.{ .cwd_relative = contract_library_path });
        runtime_core_public_c_mod.linkSystemLibrary("kadath_runtime_core", .{ .preferred_link_mode = .static });
        if (target.result.os.tag == .windows) {
            runtime_core_public_c_mod.addLibraryPath(.{ .cwd_relative = mingw_gcc_runtime_dir.? });
            runtime_core_public_c_mod.linkSystemLibrary("gcc_eh", .{ .preferred_link_mode = .static });
            runtime_core_public_c_mod.linkSystemLibrary("kernel32", .{});
            runtime_core_public_c_mod.linkSystemLibrary("dbghelp", .{});
            runtime_core_public_c_mod.linkSystemLibrary("advapi32", .{});
            runtime_core_public_c_mod.linkSystemLibrary("bcrypt", .{});
            runtime_core_public_c_mod.linkSystemLibrary("ntdll", .{});
            runtime_core_public_c_mod.linkSystemLibrary("userenv", .{});
            runtime_core_public_c_mod.linkSystemLibrary("ws2_32", .{});
        } else {
            runtime_core_public_c_mod.linkSystemLibrary("gcc_s", .{});
            runtime_core_public_c_mod.linkSystemLibrary("util", .{});
            runtime_core_public_c_mod.linkSystemLibrary("rt", .{});
            runtime_core_public_c_mod.linkSystemLibrary("pthread", .{});
            runtime_core_public_c_mod.linkSystemLibrary("m", .{});
            runtime_core_public_c_mod.linkSystemLibrary("dl", .{});
        }
        const runtime_core_public_c = b.addExecutable(.{
            .name = "runtime-core-public-contract",
            .root_module = runtime_core_public_c_mod,
        });
        runtime_core_public_c.step.dependOn(&contract_cargo_build.step);
        const runtime_core_public_c_run = b.addRunArtifact(runtime_core_public_c);
        if (quality_emit_dir) |emit_dir| {
            const install_runtime_core_public_c_evidence = b.addInstallArtifact(runtime_core_public_c, .{
                .dest_dir = .{ .override = .{ .custom = emit_dir } },
                .dest_sub_path = "runtime-core-public-contract",
            });
            const emit_runtime_core_public_c_evidence = b.step("emit-phase-public-c-contract", "Emit the Runtime Core public C17 contract without running it");
            emit_runtime_core_public_c_evidence.dependOn(&install_runtime_core_public_c_evidence.step);
        }
        const runtime_core_public_c_step = b.step("test-runtime-core-public-c", "Run Runtime Core public C17 contracts and fault hooks");
        runtime_core_public_c_step.dependOn(&runtime_core_public_c_run.step);
        test_step.dependOn(runtime_core_public_c_step);

        const scene_generation_test_mod = b.createModule(.{
            .root_source_file = b.path("app/scene_generation.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        scene_generation_test_mod.addImport("platform", platform_mod);
        scene_generation_test_mod.addImport("runtime_core", runtime_core_mod);
        scene_generation_test_mod.addLibraryPath(.{ .cwd_relative = library_path });
        scene_generation_test_mod.linkSystemLibrary("kadath_runtime_core", .{ .preferred_link_mode = .static });
        if (target.result.os.tag == .windows) {
            scene_generation_test_mod.addLibraryPath(.{ .cwd_relative = mingw_gcc_runtime_dir.? });
            scene_generation_test_mod.linkSystemLibrary("gcc_eh", .{ .preferred_link_mode = .static });
            scene_generation_test_mod.linkSystemLibrary("kernel32", .{});
            scene_generation_test_mod.linkSystemLibrary("dbghelp", .{});
            scene_generation_test_mod.linkSystemLibrary("advapi32", .{});
            scene_generation_test_mod.linkSystemLibrary("bcrypt", .{});
            scene_generation_test_mod.linkSystemLibrary("ntdll", .{});
            scene_generation_test_mod.linkSystemLibrary("userenv", .{});
            scene_generation_test_mod.linkSystemLibrary("ws2_32", .{});
        } else if (target.result.os.tag == .linux) {
            scene_generation_test_mod.linkSystemLibrary("gcc_s", .{});
            scene_generation_test_mod.linkSystemLibrary("util", .{});
            scene_generation_test_mod.linkSystemLibrary("rt", .{});
            scene_generation_test_mod.linkSystemLibrary("pthread", .{});
            scene_generation_test_mod.linkSystemLibrary("m", .{});
            scene_generation_test_mod.linkSystemLibrary("dl", .{});
        }
        const scene_generation_tests = b.addTest(.{ .root_module = scene_generation_test_mod });
        scene_generation_tests.step.dependOn(runtime_core_cargo_step.?);
        const scene_generation_test_run = b.addRunArtifact(scene_generation_tests);
        const scene_generation_test_step = b.step("test-scene-generation", "Run Scene object generation contracts against Runtime Core");
        scene_generation_test_step.dependOn(&scene_generation_test_run.step);
        test_step.dependOn(scene_generation_test_step);
    }

    const null_rhi_mod = b.createModule(.{
        .root_source_file = b.path("modules/rhi/src/null.zig"),
        .target = target,
        .optimize = optimize,
    });
    const null_renderer2d_mod = b.createModule(.{
        .root_source_file = b.path("modules/renderer2d/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    null_renderer2d_mod.addImport("rhi", null_rhi_mod);

    const renderer2d_null_contract_mod = b.createModule(.{
        .root_source_file = b.path("modules/renderer2d/tests/null_contract.zig"),
        .target = target,
        .optimize = optimize,
    });
    renderer2d_null_contract_mod.addImport("rhi", null_rhi_mod);
    renderer2d_null_contract_mod.addImport("renderer2d", null_renderer2d_mod);
    const renderer2d_null_contract_tests = b.addTest(.{ .root_module = renderer2d_null_contract_mod });
    const renderer2d_null_contract_run = b.addRunArtifact(renderer2d_null_contract_tests);

    const renderer2d_remap_mod = b.createModule(.{
        .root_source_file = b.path("modules/rhi/tests/renderer2d_remap.zig"),
        .target = target,
        .optimize = optimize,
    });
    renderer2d_remap_mod.addImport("rhi", null_rhi_mod);
    renderer2d_remap_mod.addImport("renderer2d", null_renderer2d_mod);
    const renderer2d_remap_tests = b.addTest(.{ .root_module = renderer2d_remap_mod });
    const renderer2d_remap_run = b.addRunArtifact(renderer2d_remap_tests);

    const renderer2d_null_test_step = b.step("test-renderer2d-null", "Run Renderer2D contracts against the Null RHI");
    renderer2d_null_test_step.dependOn(&renderer2d_null_contract_run.step);
    renderer2d_null_test_step.dependOn(&renderer2d_remap_run.step);
    test_step.dependOn(renderer2d_null_test_step);

    const audio_test_mod = b.createModule(.{
        .root_source_file = b.path("modules/audio/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = target.result.os.tag == .linux,
    });
    if (target.result.os.tag == .windows) {
        audio_test_mod.linkSystemLibrary("winmm", .{});
    } else if (target.result.os.tag == .linux) {
        audio_test_mod.addCMacro("_FORTIFY_SOURCE", "0");
        if (configured_alsa_include_dir) |include_dir| {
            audio_test_mod.addIncludePath(.{ .cwd_relative = include_dir });
        }
        if (configured_alsa_library_dir) |library_dir| {
            audio_test_mod.addLibraryPath(.{ .cwd_relative = library_dir });
        }
        audio_test_mod.linkSystemLibrary("asound", .{});
    }
    const audio_tests = b.addTest(.{ .root_module = audio_test_mod });
    const audio_test_run = b.addRunArtifact(audio_tests);
    const audio_test_step = b.step("test-audio", "Run Audio module and platform Adapter tests");
    audio_test_step.dependOn(&audio_test_run.step);
    test_step.dependOn(audio_test_step);

    const runtime_texture_registry_test_mod = b.createModule(.{
        .root_source_file = b.path("app/runtime_texture_registry.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    runtime_texture_registry_test_mod.addImport("resource", resource_mod);
    runtime_texture_registry_test_mod.addImport("renderer2d", null_renderer2d_mod);
    runtime_texture_registry_test_mod.addImport("rhi", null_rhi_mod);
    runtime_texture_registry_test_mod.addImport("runtime_core", runtime_core_mod);
    const runtime_texture_registry_tests = b.addTest(.{ .root_module = runtime_texture_registry_test_mod });
    const registry_cargo_target_dir = b.pathFromRoot(".zig-cache/cargo-registry-tests");
    const registry_cargo_build = b.addSystemCommand(&.{
        "cargo",
        "build",
        "--locked",
        "--manifest-path",
        b.pathFromRoot("Cargo.toml"),
        "--package",
        "kadath_scheduler",
        "--target-dir",
        registry_cargo_target_dir,
    });
    const registry_rust_target = if (target.result.os.tag == .windows) switch (target.result.cpu.arch) {
        .x86_64 => "x86_64-pc-windows-gnu",
        else => @panic("P2-Multi-Texture-01 registry tests support only x86_64 Windows"),
    } else null;
    if (registry_rust_target) |rust_target| {
        registry_cargo_build.addArgs(&.{ "--target", rust_target });
    }
    if (optimize != .Debug) registry_cargo_build.addArg("--release");
    runtime_texture_registry_tests.step.dependOn(&registry_cargo_build.step);
    const registry_rust_profile = if (optimize == .Debug) "debug" else "release";
    const registry_library_path = if (registry_rust_target) |rust_target|
        b.pathJoin(&.{ registry_cargo_target_dir, rust_target, registry_rust_profile })
    else
        b.pathJoin(&.{ registry_cargo_target_dir, registry_rust_profile });
    runtime_texture_registry_test_mod.addLibraryPath(.{ .cwd_relative = registry_library_path });
    runtime_texture_registry_test_mod.linkSystemLibrary("kadath_scheduler", .{ .preferred_link_mode = .static });
    if (target.result.os.tag == .windows) {
        runtime_texture_registry_test_mod.addLibraryPath(.{ .cwd_relative = mingw_gcc_runtime_dir.? });
        runtime_texture_registry_test_mod.linkSystemLibrary("gcc_eh", .{ .preferred_link_mode = .static });
        runtime_texture_registry_test_mod.linkSystemLibrary("kernel32", .{});
        runtime_texture_registry_test_mod.linkSystemLibrary("dbghelp", .{});
        runtime_texture_registry_test_mod.linkSystemLibrary("advapi32", .{});
        runtime_texture_registry_test_mod.linkSystemLibrary("bcrypt", .{});
        runtime_texture_registry_test_mod.linkSystemLibrary("ntdll", .{});
        runtime_texture_registry_test_mod.linkSystemLibrary("userenv", .{});
        runtime_texture_registry_test_mod.linkSystemLibrary("ws2_32", .{});
    } else if (target.result.os.tag == .linux) {
        runtime_texture_registry_test_mod.linkSystemLibrary("gcc_s", .{});
        runtime_texture_registry_test_mod.linkSystemLibrary("util", .{});
        runtime_texture_registry_test_mod.linkSystemLibrary("rt", .{});
        runtime_texture_registry_test_mod.linkSystemLibrary("pthread", .{});
        runtime_texture_registry_test_mod.linkSystemLibrary("m", .{});
        runtime_texture_registry_test_mod.linkSystemLibrary("dl", .{});
    }

    if (target.result.os.tag != .windows) {
        const native_async_texture_test_mod = b.createModule(.{
            .root_source_file = b.path("modules/resource/tests/async_texture_integration.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        native_async_texture_test_mod.addImport("resource", resource_mod);
        native_async_texture_test_mod.addLibraryPath(.{ .cwd_relative = registry_library_path });
        native_async_texture_test_mod.linkSystemLibrary("kadath_scheduler", .{ .preferred_link_mode = .static });
        if (target.result.os.tag == .linux) {
            native_async_texture_test_mod.linkSystemLibrary("gcc_s", .{});
            native_async_texture_test_mod.linkSystemLibrary("util", .{});
            native_async_texture_test_mod.linkSystemLibrary("rt", .{});
            native_async_texture_test_mod.linkSystemLibrary("pthread", .{});
            native_async_texture_test_mod.linkSystemLibrary("m", .{});
            native_async_texture_test_mod.linkSystemLibrary("dl", .{});
        }
        const native_async_texture_tests = b.addTest(.{ .root_module = native_async_texture_test_mod });
        native_async_texture_tests.step.dependOn(&registry_cargo_build.step);
        const native_async_texture_test_run = b.addRunArtifact(native_async_texture_tests);
        const native_async_texture_test_step = b.step("test-resource-async", "Run Resource-owned async texture tests without GPU");
        native_async_texture_test_step.dependOn(&native_async_texture_test_run.step);
        async_texture_test_step = native_async_texture_test_step;
    }
    const runtime_texture_registry_run = b.addRunArtifact(runtime_texture_registry_tests);
    const runtime_texture_registry_test_step = b.step("test-runtime-texture-registry", "Run fixed Runtime texture registry contracts against the Null RHI");
    runtime_texture_registry_test_step.dependOn(&runtime_texture_registry_run.step);
    test_step.dependOn(runtime_texture_registry_test_step);
    if (async_texture_test_step) |step| test_step.dependOn(step);

    if (linux_package_supported) {
        const platform_contract_mod = b.createModule(.{
            .root_source_file = b.path("modules/platform/tests/xcb_contract.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        platform_contract_mod.addImport("platform", platform_mod);
        const platform_contract_tests = b.addTest(.{ .root_module = platform_contract_mod });
        linux_platform_contract_binary = platform_contract_tests.getEmittedBin();
        const platform_contract_run = b.addRunArtifact(platform_contract_tests);
        const platform_contract_step = b.step("test-platform-xcb", "Run XCB Platform contracts on the current DISPLAY");
        platform_contract_step.dependOn(&platform_contract_run.step);

        const linux_verifier_mod = b.createModule(.{
            .root_source_file = b.path("tools/verify-linux-window.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        linux_verifier_mod.linkSystemLibrary("xcb", .{});
        const linux_verifier = b.addExecutable(.{
            .name = "verify-linux-window",
            .root_module = linux_verifier_mod,
        });
        linux_window_verifier_binary = linux_verifier.getEmittedBin();
        const linux_verifier_test_mod = b.createModule(.{
            .root_source_file = b.path("tools/verify-linux-window.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        linux_verifier_test_mod.linkSystemLibrary("xcb", .{});
        const linux_verifier_tests = b.addTest(.{ .root_module = linux_verifier_test_mod });
        const linux_verifier_test_run = b.addRunArtifact(linux_verifier_tests);
        const linux_verifier_test_step = b.step(
            "test-linux-window-verifier",
            "Run Xvfb ownership and bounded cleanup failure-path tests",
        );
        linux_verifier_test_step.dependOn(&linux_verifier_test_run.step);
        const linux_verifier_run = b.addRunArtifact(linux_verifier);
        linux_verifier_run.addFileArg(platform_contract_tests.getEmittedBin());
        linux_verifier_run.addFileArg(exe.getEmittedBin());
        linux_verifier_run.addArg(@tagName(optimize));
        const linux_verifier_step = b.step("verify-linux-window", "Verify Linux XCB, Lavapipe, validation, Runtime pixels, and shutdown");
        linux_verifier_step.dependOn(&linux_verifier_test_run.step);
        linux_verifier_step.dependOn(&linux_verifier_run.step);
    }

    // 分发目录以 bin 为运行工作目录，资产必须与 exe 保持稳定的相对位置。
    // Editor Toolchain 的 publish 输出由 Zig cache 拥有；snapshot/import/profile 共用同一原生 .NET 入口。
    const editor_toolchain_build = b.addSystemCommand(&.{ "dotnet", "publish" });
    // dotnet 会读取 ProjectReference 的传递源码；Run 的目录参数不会递归进入 cache manifest，因此必须每次发布。
    editor_toolchain_build.has_side_effects = true;
    editor_toolchain_build.addFileArg(b.path("editor/Kadath.Editor.Toolchain/Kadath.Editor.Toolchain.csproj"));
    editor_toolchain_build.addArgs(&.{ "-c", "Release", "--no-self-contained", "-p:NuGetAudit=false", "--nologo" });
    editor_toolchain_build.addPrefixedDirectoryArg("-p:KadathToolchainSourceRoot=", b.path("editor/Kadath.Editor.Toolchain"));
    editor_toolchain_build.addPrefixedDirectoryArg("-p:KadathWorkspaceSourceRoot=", b.path("editor/Kadath.Editor.Workspace"));
    editor_toolchain_build.addPrefixedDirectoryArg("-p:KadathProtocolSourceRoot=", b.path("editor/Kadath.Editor.Protocol"));
    editor_toolchain_build.addFileInput(b.path("editor/Directory.Build.props"));
    editor_toolchain_build.addArg("-o");
    const editor_toolchain_output = editor_toolchain_build.addOutputDirectoryArg("editor-toolchain");
    const editor_toolchain_dll = editor_toolchain_output.path(b, "Kadath.Editor.Toolchain.dll");

    const texture_source_snapshot_test_barrier = b.option(
        []const u8,
        "texture-source-snapshot-test-barrier",
        "Verifier-only absolute empty directory used to pause after the PNG source snapshot",
    );
    // 源快照由 Toolchain 持有源句柄并以 CreateNew + durable no-replace 方式提交。
    const texture_source_snapshot_command = b.addSystemCommand(&.{"dotnet"});
    texture_source_snapshot_command.step.dependOn(&editor_toolchain_build.step);
    texture_source_snapshot_command.addFileArg(editor_toolchain_dll);
    texture_source_snapshot_command.addArg("snapshot");
    texture_source_snapshot_command.addFileArg(b.path("assets/renderer2d/test.png"));
    const texture_source_snapshot = texture_source_snapshot_command.addOutputFileArg("test.png");
    texture_source_snapshot_command.addArg("--barrier");
    if (texture_source_snapshot_test_barrier) |barrier_path| {
        texture_source_snapshot_command.addArg(barrier_path);
    } else {
        texture_source_snapshot_command.addArg("-");
    }
    const texture_source_snapshot_test_fault = b.option(
        []const u8,
        "texture-source-snapshot-test-fault",
        "Verifier-only snapshot fault injection for pre-return, partial-write cleanup, or same-byte replacement refusal",
    );
    texture_source_snapshot_command.addArg("--fault");
    if (texture_source_snapshot_test_fault) |fault_mode| {
        texture_source_snapshot_command.addArg(fault_mode);
    } else {
        texture_source_snapshot_command.addArg("-");
    }
    texture_source_snapshot_command.addArg("--no-overwrite");

    const secondary_texture_source_snapshot_test_barrier = b.option(
        []const u8,
        "secondary-texture-source-snapshot-test-barrier",
        "Verifier-only absolute empty directory used to pause after the secondary PNG source snapshot",
    );
    const secondary_texture_source_snapshot_command = b.addSystemCommand(&.{"dotnet"});
    secondary_texture_source_snapshot_command.step.dependOn(&editor_toolchain_build.step);
    secondary_texture_source_snapshot_command.addFileArg(editor_toolchain_dll);
    secondary_texture_source_snapshot_command.addArg("snapshot");
    secondary_texture_source_snapshot_command.addFileArg(b.path("assets/renderer2d/goal.png"));
    const secondary_texture_source_snapshot = secondary_texture_source_snapshot_command.addOutputFileArg("goal.png");
    secondary_texture_source_snapshot_command.addArg("--barrier");
    if (secondary_texture_source_snapshot_test_barrier) |barrier_path| {
        secondary_texture_source_snapshot_command.addArg(barrier_path);
    } else {
        secondary_texture_source_snapshot_command.addArg("-");
    }
    const secondary_texture_source_snapshot_test_fault = b.option(
        []const u8,
        "secondary-texture-source-snapshot-test-fault",
        "Verifier-only secondary snapshot fault injection for pre-return, partial-write cleanup, or same-byte replacement refusal",
    );
    secondary_texture_source_snapshot_command.addArg("--fault");
    if (secondary_texture_source_snapshot_test_fault) |fault_mode| {
        secondary_texture_source_snapshot_command.addArg(fault_mode);
    } else {
        secondary_texture_source_snapshot_command.addArg("-");
    }
    secondary_texture_source_snapshot_command.addArg("--no-overwrite");

    const install_assets = b.addInstallDirectory(.{
        .source_dir = b.path("assets"),
        .install_dir = .bin,
        .install_subdir = "assets",
    });
    if (target.result.os.tag == .windows) b.getInstallStep().dependOn(&install_assets.step);
    // install_assets 仍提供完整资产树；两个 snapshot install 是对应 PNG 的唯一有序 final writer。
    const install_texture_source_snapshot = b.addInstallFile(texture_source_snapshot, "bin/assets/renderer2d/test.png");
    install_texture_source_snapshot.step.dependOn(&install_assets.step);
    if (target.result.os.tag == .windows) b.getInstallStep().dependOn(&install_texture_source_snapshot.step);
    const install_secondary_texture_source_snapshot = b.addInstallFile(secondary_texture_source_snapshot, "bin/assets/renderer2d/goal.png");
    install_secondary_texture_source_snapshot.step.dependOn(&install_assets.step);
    if (target.result.os.tag == .windows) b.getInstallStep().dependOn(&install_secondary_texture_source_snapshot.step);
    // Importer/Baker 在安装阶段从 PNG 源生成确定性 KDAT；Zig optimize 不改变 release texture profile。
    const texture_import = b.addSystemCommand(&.{"dotnet"});
    texture_import.step.dependOn(&editor_toolchain_build.step);
    texture_import.addFileArg(editor_toolchain_dll);
    texture_import.addArgs(&.{ "import", "texture" });
    texture_import.addFileArg(texture_source_snapshot);
    const texture_artifact = texture_import.addOutputFileArg("test.texture");
    texture_import.addArgs(&.{ "--profile", "release", "--no-overwrite" });
    const install_texture_artifact = b.addInstallFile(texture_artifact, "bin/assets/renderer2d/test.texture");
    if (target.result.os.tag == .windows) b.getInstallStep().dependOn(&install_texture_artifact.step);
    const secondary_texture_import = b.addSystemCommand(&.{"dotnet"});
    secondary_texture_import.step.dependOn(&editor_toolchain_build.step);
    secondary_texture_import.addFileArg(editor_toolchain_dll);
    secondary_texture_import.addArgs(&.{ "import", "texture" });
    secondary_texture_import.addFileArg(secondary_texture_source_snapshot);
    const secondary_texture_artifact = secondary_texture_import.addOutputFileArg("goal.texture");
    secondary_texture_import.addArgs(&.{ "--profile", "release", "--no-overwrite" });
    const install_secondary_texture_artifact = b.addInstallFile(secondary_texture_artifact, "bin/assets/renderer2d/goal.texture");
    if (target.result.os.tag == .windows) b.getInstallStep().dependOn(&install_secondary_texture_artifact.step);
    // 两个音频 artifact 独立构建，任一失败都会阻止 install/package 完成。
    const audio_import_won = b.addSystemCommand(&.{"dotnet"});
    audio_import_won.step.dependOn(&editor_toolchain_build.step);
    audio_import_won.addFileArg(editor_toolchain_dll);
    audio_import_won.addArgs(&.{ "import", "audio" });
    audio_import_won.addFileArg(b.path("assets/audio/won.wav"));
    const won_audio_artifact = audio_import_won.addOutputFileArg("won.audio.wav");
    audio_import_won.addArgs(&.{ "--profile", "release", "--no-overwrite" });
    const install_won_audio_artifact = b.addInstallFile(won_audio_artifact, "bin/assets/audio/won.audio.wav");
    if (target.result.os.tag == .windows) b.getInstallStep().dependOn(&install_won_audio_artifact.step);

    const audio_import_lost = b.addSystemCommand(&.{"dotnet"});
    audio_import_lost.step.dependOn(&editor_toolchain_build.step);
    audio_import_lost.addFileArg(editor_toolchain_dll);
    audio_import_lost.addArgs(&.{ "import", "audio" });
    audio_import_lost.addFileArg(b.path("assets/audio/lost.wav"));
    const lost_audio_artifact = audio_import_lost.addOutputFileArg("lost.audio.wav");
    audio_import_lost.addArgs(&.{ "--profile", "release", "--no-overwrite" });
    const install_lost_audio_artifact = b.addInstallFile(lost_audio_artifact, "bin/assets/audio/lost.audio.wav");
    if (target.result.os.tag == .windows) b.getInstallStep().dependOn(&install_lost_audio_artifact.step);

    const product_scene_source = if (behavior_supported)
        b.path("packaging/runtime-assets/preview.scene.json")
    else
        b.path("assets/scenes/preview.scene.json");
    const install_scene_source_template = b.addInstallFile(product_scene_source, "bin/assets/scenes/preview.scene.json");
    if (target.result.os.tag == .windows) install_scene_source_template.step.dependOn(&install_assets.step);
    b.getInstallStep().dependOn(&install_scene_source_template.step);

    // Scene 源 JSON 作为 Editor Create 模板保留；安装包同时生成 Runtime 消费的 KSCN artifact。
    const scene_import = b.addSystemCommand(&.{"dotnet"});
    scene_import.step.dependOn(&editor_toolchain_build.step);
    scene_import.addFileArg(editor_toolchain_dll);
    scene_import.addArgs(&.{ "import", "scene" });
    scene_import.addFileArg(product_scene_source);
    const scene_artifact = scene_import.addOutputFileArg("preview.scene");
    scene_import.addArgs(&.{ "--profile", "release", "--no-overwrite" });
    const install_scene_artifact = b.addInstallFile(scene_artifact, "bin/assets/scenes/preview.scene");
    if (target.result.os.tag == .windows) b.getInstallStep().dependOn(&install_scene_artifact.step);

    const product_script_source = if (behavior_supported)
        b.path("packaging/runtime-assets/script.json")
    else
        b.path("assets/scripts/preview.script.json");
    const install_script_source_template = b.addInstallFile(product_script_source, "bin/assets/scripts/preview.script.json");
    if (target.result.os.tag == .windows) install_script_source_template.step.dependOn(&install_assets.step);
    b.getInstallStep().dependOn(&install_script_source_template.step);

    // 支持 Behavior 的原生平台由同一个 Luau Tooling/Package Builder 生成 KSCP v2；旧平台保留 v1 兼容输入。
    const script_artifact = if (behavior_supported) artifact: {
        const behavior_script_import = b.addRunArtifact(behavior_tool_executable.?);
        behavior_script_import.addArg("--project-root");
        behavior_script_import.addDirectoryArg(b.path("packaging/runtime-assets"));
        behavior_script_import.addArgs(&.{ "--manifest", "script.json", "--output" });
        break :artifact behavior_script_import.addOutputFileArg("preview.script");
    } else artifact: {
        const legacy_script_import = b.addSystemCommand(&.{"dotnet"});
        legacy_script_import.step.dependOn(&editor_toolchain_build.step);
        legacy_script_import.addFileArg(editor_toolchain_dll);
        legacy_script_import.addArgs(&.{ "import", "script" });
        legacy_script_import.addFileArg(product_script_source);
        const output = legacy_script_import.addOutputFileArg("preview.script");
        legacy_script_import.addArgs(&.{ "--profile", "release", "--no-overwrite" });
        break :artifact output;
    };
    const install_script_artifact = b.addInstallFile(script_artifact, "bin/assets/scripts/preview.script");
    if (target.result.os.tag == .windows) b.getInstallStep().dependOn(&install_script_artifact.step);

    if (target.result.os.tag == .windows and behavior_supported) {
        const install_patrol_behavior_source = b.addInstallFile(
            b.path("packaging/runtime-assets/scripts/patrol.luau"),
            "bin/assets/scripts/patrol.luau",
        );
        const install_player_behavior_source = b.addInstallFile(
            b.path("packaging/runtime-assets/scripts/player_controller.luau"),
            "bin/assets/scripts/player_controller.luau",
        );
        b.getInstallStep().dependOn(&install_patrol_behavior_source.step);
        b.getInstallStep().dependOn(&install_player_behavior_source.step);
        b.getInstallStep().dependOn(behavior_tool_install_artifact_step.?);
    }

    const install_package_readme = b.addInstallFile(
        b.path("packaging/README.txt"),
        "README.txt",
    );
    if (target.result.os.tag == .windows) b.getInstallStep().dependOn(&install_package_readme.step);

    // 关键包身份必须绑定当次链接产物；addFileArg 同时建立 exe/source 的依赖与 cache key。
    const runtime_preflight_sidecar = b.option(
        []const u8,
        "runtime-preflight-sidecar",
        "Absolute path to the operator-created PNG Runtime pre-build witness",
    );
    // Build profile 由 Toolchain 生成严格 exact-eleven v2 JSON，并保持 sidecar 身份门禁。
    const runtime_build_profile_command = b.addSystemCommand(&.{"dotnet"});
    runtime_build_profile_command.step.dependOn(&install_exe.step);
    runtime_build_profile_command.step.dependOn(&editor_toolchain_build.step);
    runtime_build_profile_command.addFileArg(editor_toolchain_dll);
    runtime_build_profile_command.addArg("build-profile");
    runtime_build_profile_command.addFileArg(exe.getEmittedBin());
    runtime_build_profile_command.addFileArg(texture_source_snapshot);
    runtime_build_profile_command.addFileArg(texture_artifact);
    runtime_build_profile_command.addFileArg(secondary_texture_source_snapshot);
    runtime_build_profile_command.addFileArg(secondary_texture_artifact);
    runtime_build_profile_command.addFileArg(b.path("shaders/renderer2d/quad.vert.glsl"));
    runtime_build_profile_command.addFileArg(b.path("shaders/renderer2d/quad.frag.glsl"));
    runtime_build_profile_command.addArg(@tagName(optimize));
    runtime_build_profile_command.addArg(b.install_path);
    runtime_build_profile_command.addArg(b.cache_root.path orelse ".");
    runtime_build_profile_command.addArg(b.graph.global_cache_root.path orelse ".");
    if (runtime_preflight_sidecar) |preflight_path| {
        runtime_build_profile_command.addFileArg(.{ .cwd_relative = preflight_path });
    } else {
        runtime_build_profile_command.addArg("-");
    }
    const runtime_build_profile = runtime_build_profile_command.addOutputFileArg("kadath-runtime-build-profile.json");
    runtime_build_profile_command.addArg("--no-overwrite");
    const install_runtime_build_profile = b.addInstallFile(runtime_build_profile, "bin/kadath-runtime-build-profile.json");
    if (target.result.os.tag == .windows) b.getInstallStep().dependOn(&install_runtime_build_profile.step);
    if (linux_package_supported) {
        const package_support_mod = b.createModule(.{
            .root_source_file = b.path("linux_package_support.zig"),
            .target = target,
            .optimize = optimize,
        });
        const package_assets_mod = b.createModule(.{
            .root_source_file = b.path("tools/build-linux-runtime-assets.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        });
        package_assets_mod.addImport("package_support", package_support_mod);
        package_assets_mod.addImport("behavior_manifest", behavior_manifest_mod.?);
        package_assets_mod.addImport("behavior_package_builder", behavior_package_builder_mod.?);
        package_assets_mod.addCMacro("_FORTIFY_SOURCE", "0");
        package_assets_mod.linkSystemLibrary("png", .{});
        const package_assets = b.addExecutable(.{
            .name = "build-linux-runtime-assets",
            .root_module = package_assets_mod,
        });
        package_assets.step.dependOn(behavior_native_step.?);
        const package_assets_run = b.addRunArtifact(package_assets);
        package_assets_run.addFileInput(b.path("packaging/runtime-assets/scripts/patrol.luau"));
        package_assets_run.addFileInput(b.path("packaging/runtime-assets/scripts/player_controller.luau"));
        const linux_texture_artifact = package_assets_run.addOutputFileArg("test.texture");
        const linux_secondary_texture_artifact = package_assets_run.addOutputFileArg("goal.texture");
        const linux_won_audio_artifact = package_assets_run.addOutputFileArg("won.audio.wav");
        const linux_lost_audio_artifact = package_assets_run.addOutputFileArg("lost.audio.wav");
        const linux_scene_artifact = package_assets_run.addOutputFileArg("preview.scene");
        const linux_script_artifact = package_assets_run.addOutputFileArg("preview.script");

        const package_assets_test_mod = b.createModule(.{
            .root_source_file = b.path("tools/build-linux-runtime-assets.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        });
        package_assets_test_mod.addImport("package_support", package_support_mod);
        package_assets_test_mod.addImport("behavior_manifest", behavior_manifest_mod.?);
        package_assets_test_mod.addImport("behavior_package_builder", behavior_package_builder_mod.?);
        package_assets_test_mod.addCMacro("_FORTIFY_SOURCE", "0");
        package_assets_test_mod.linkSystemLibrary("png", .{});
        const package_assets_tests = b.addTest(.{ .root_module = package_assets_test_mod });
        package_assets_tests.step.dependOn(behavior_native_step.?);
        const package_assets_test_run = b.addRunArtifact(package_assets_tests);
        const package_assets_test_step = b.step("test-linux-package-assets", "Run Linux Runtime package asset builder tests");
        package_assets_test_step.dependOn(&package_assets_test_run.step);
        test_step.dependOn(package_assets_test_step);

        const install_linux_texture_artifact = b.addInstallFile(linux_texture_artifact, "bin/assets/renderer2d/test.texture");
        const install_linux_secondary_texture_artifact = b.addInstallFile(linux_secondary_texture_artifact, "bin/assets/renderer2d/goal.texture");
        const install_linux_won_audio_artifact = b.addInstallFile(linux_won_audio_artifact, "bin/assets/audio/won.audio.wav");
        const install_linux_lost_audio_artifact = b.addInstallFile(linux_lost_audio_artifact, "bin/assets/audio/lost.audio.wav");
        const install_linux_scene_artifact = b.addInstallFile(linux_scene_artifact, "bin/assets/scenes/preview.scene");
        const install_linux_script_artifact = b.addInstallFile(linux_script_artifact, "bin/assets/scripts/preview.script");
        const install_linux_behavior_source = b.addInstallFile(
            b.path("packaging/runtime-assets/scripts/patrol.luau"),
            "bin/assets/scripts/patrol.luau",
        );
        const install_linux_player_behavior_source = b.addInstallFile(
            b.path("packaging/runtime-assets/scripts/player_controller.luau"),
            "bin/assets/scripts/player_controller.luau",
        );
        const install_linux_package_readme = b.addInstallFile(b.path("packaging/README-linux.txt"), "README.txt");
        b.getInstallStep().dependOn(&install_linux_texture_artifact.step);
        b.getInstallStep().dependOn(&install_linux_secondary_texture_artifact.step);
        b.getInstallStep().dependOn(&install_linux_won_audio_artifact.step);
        b.getInstallStep().dependOn(&install_linux_lost_audio_artifact.step);
        b.getInstallStep().dependOn(&install_linux_scene_artifact.step);
        b.getInstallStep().dependOn(&install_linux_script_artifact.step);
        b.getInstallStep().dependOn(&install_linux_behavior_source.step);
        b.getInstallStep().dependOn(&install_linux_player_behavior_source.step);
        b.getInstallStep().dependOn(&install_linux_package_readme.step);
        b.getInstallStep().dependOn(behavior_tool_install_artifact_step.?);

        const package_manifest_command = b.addSystemCommand(&.{"sh"});
        package_manifest_command.addFileArg(b.path("packaging/finalize-linux-runtime.sh"));
        package_manifest_command.addArg(b.install_path);
        const package_manifest = package_manifest_command.addOutputFileArg("SHA256SUMS");
        package_manifest_command.addFileInput(exe.getEmittedBin());
        package_manifest_command.addFileInput(linux_texture_artifact);
        package_manifest_command.addFileInput(linux_secondary_texture_artifact);
        package_manifest_command.addFileInput(linux_won_audio_artifact);
        package_manifest_command.addFileInput(linux_lost_audio_artifact);
        package_manifest_command.addFileInput(linux_scene_artifact);
        package_manifest_command.addFileInput(linux_script_artifact);
        package_manifest_command.addFileInput(product_scene_source);
        package_manifest_command.addFileInput(product_script_source);
        package_manifest_command.addFileInput(b.path("packaging/runtime-assets/scripts/patrol.luau"));
        package_manifest_command.addFileInput(b.path("packaging/runtime-assets/scripts/player_controller.luau"));
        package_manifest_command.addFileInput(b.path("packaging/README-linux.txt"));
        package_manifest_command.addFileInput(behavior_tool_binary.?);
        package_manifest_command.step.dependOn(&install_exe.step);
        package_manifest_command.step.dependOn(&install_linux_texture_artifact.step);
        package_manifest_command.step.dependOn(&install_linux_secondary_texture_artifact.step);
        package_manifest_command.step.dependOn(&install_linux_won_audio_artifact.step);
        package_manifest_command.step.dependOn(&install_linux_lost_audio_artifact.step);
        package_manifest_command.step.dependOn(&install_linux_scene_artifact.step);
        package_manifest_command.step.dependOn(&install_linux_script_artifact.step);
        package_manifest_command.step.dependOn(&install_scene_source_template.step);
        package_manifest_command.step.dependOn(&install_script_source_template.step);
        package_manifest_command.step.dependOn(&install_linux_behavior_source.step);
        package_manifest_command.step.dependOn(&install_linux_player_behavior_source.step);
        package_manifest_command.step.dependOn(&install_linux_package_readme.step);
        package_manifest_command.step.dependOn(behavior_tool_install_artifact_step.?);
        const install_package_manifest = b.addInstallFile(package_manifest, "SHA256SUMS");
        b.getInstallStep().dependOn(&install_package_manifest.step);

        const package_scripts_test_command = b.addSystemCommand(&.{"sh"});
        package_scripts_test_command.addFileArg(b.path("tools/test-linux-package-scripts.sh"));
        package_scripts_test_command.addArg(b.install_path);
        package_scripts_test_command.addFileArg(b.path("packaging/finalize-linux-runtime.sh"));
        package_scripts_test_command.addFileArg(b.path("packaging/archive-runtime-linux.sh"));
        package_scripts_test_command.addFileArg(b.path("tools/verify-linux-package.sh"));
        package_scripts_test_command.step.dependOn(&install_package_manifest.step);
        const package_scripts_test_step = b.step("test-linux-package-tools", "Run Linux package archive and failure-path tests");
        package_scripts_test_step.dependOn(&package_scripts_test_command.step);
        test_step.dependOn(package_scripts_test_step);

        const archive_linux_command = b.addSystemCommand(&.{"sh"});
        archive_linux_command.addFileArg(b.path("packaging/archive-runtime-linux.sh"));
        archive_linux_command.addArg(b.install_path);
        archive_linux_command.addArg(b.pathFromRoot("zig-out/dist/kadath-linux-x86_64.tar.gz"));
        archive_linux_command.step.dependOn(&install_package_manifest.step);
        const archive_linux_step = b.step("archive-linux-runtime", "Create the deterministic Linux x86_64 Runtime archive");
        archive_linux_step.dependOn(&archive_linux_command.step);

        const verify_linux_package_command = b.addSystemCommand(&.{"sh"});
        verify_linux_package_command.addFileArg(b.path("tools/verify-linux-package.sh"));
        verify_linux_package_command.addArg(b.pathFromRoot("zig-out/dist/kadath-linux-x86_64.tar.gz"));
        verify_linux_package_command.addFileArg(linux_window_verifier_binary.?);
        verify_linux_package_command.addFileArg(linux_platform_contract_binary.?);
        verify_linux_package_command.addArg(@tagName(optimize));
        verify_linux_package_command.addArg(b.pathFromRoot(".zig-cache/linux-package-evidence"));
        verify_linux_package_command.step.dependOn(&archive_linux_command.step);
        const verify_linux_package_step = b.step("verify-linux-package", "Verify the clean-extracted Linux Runtime archive");
        verify_linux_package_step.dependOn(&verify_linux_package_command.step);
    }

    const package_step = b.step("package", "Build the distributable runtime directory");
    if (target.result.os.tag == .linux and !linux_package_supported) {
        const unsupported_linux_package = b.addFail("Unsupported: Linux Runtime package requires the native x86_64-linux-gnu target");
        package_step.dependOn(&unsupported_linux_package.step);
        const archive_linux_step = b.step("archive-linux-runtime", "Create the deterministic Linux x86_64 Runtime archive");
        archive_linux_step.dependOn(&unsupported_linux_package.step);
        const verify_linux_package_step = b.step("verify-linux-package", "Verify the clean-extracted Linux Runtime archive");
        verify_linux_package_step.dependOn(&unsupported_linux_package.step);
    } else {
        package_step.dependOn(b.getInstallStep());
    }

    if (target.query.isNative() and target.result.cpu.arch == .x86_64 and target.result.os.tag == .windows) {
        const archive_output_dir = b.option(
            []const u8,
            "runtime-archive-output-dir",
            "Absolute new directory for the Windows Runtime ZIP and manifest",
        ) orelse b.pathFromRoot(".kadath-runtime-archive");
        const archive_extract_dir = b.option(
            []const u8,
            "runtime-archive-extract-dir",
            "Absolute new directory for the verified Windows Runtime extraction",
        ) orelse b.pathFromRoot(".kadath-runtime-extract");
        const archive_barrier = b.option(
            []const u8,
            "runtime-archive-test-barrier",
            "Verifier-only absolute empty directory used to pause a retained package snapshot",
        );
        const archive_windows_command = b.addSystemCommand(&.{"dotnet"});
        archive_windows_command.step.dependOn(package_step);
        archive_windows_command.step.dependOn(&editor_toolchain_build.step);
        archive_windows_command.addFileArg(editor_toolchain_dll);
        archive_windows_command.addArgs(&.{ "archive", b.install_path, archive_output_dir, archive_extract_dir });
        archive_windows_command.addDirectoryArg(b.path("."));
        archive_windows_command.addArgs(&.{ "--policy", "kscp-v2", "--barrier" });
        if (archive_barrier) |barrier| archive_windows_command.addArg(barrier) else archive_windows_command.addArg("-");
        archive_windows_command.addArg("--no-overwrite");
        const archive_windows_step = b.step(
            "archive-windows-runtime",
            "Create and verify the sidecar-bound ReleaseSafe Windows Runtime archive",
        );
        archive_windows_step.dependOn(&archive_windows_command.step);

        const runtime_window_evidence = b.option(
            []const u8,
            "windows-runtime-evidence-dir",
            "Absolute new directory for Windows HWND/Vulkan product evidence",
        ) orelse b.pathFromRoot(".kadath-windows-runtime-evidence");
        const verify_windows_runtime_command = b.addSystemCommand(&.{ "dotnet", "run", "--project" });
        // verifier 依赖 Win32 与当前 package，显式 step 不参与普通 test/package 的 headless 路径。
        verify_windows_runtime_command.has_side_effects = true;
        verify_windows_runtime_command.addFileArg(b.path(
            "editor/Kadath.Runtime.Windows.ContractVerifier/Kadath.Runtime.Windows.ContractVerifier.csproj",
        ));
        verify_windows_runtime_command.addArgs(&.{ "-c", "Release", "--", b.install_path, runtime_window_evidence });
        verify_windows_runtime_command.step.dependOn(package_step);
        const verify_windows_runtime_step = b.step(
            "verify-windows-runtime",
            "Verify real Windows HWND/Vulkan pixels, input, audio, and bounded cleanup",
        );
        verify_windows_runtime_step.dependOn(&verify_windows_runtime_command.step);
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the Kadath host");
    run_step.dependOn(&run_cmd.step);
}
