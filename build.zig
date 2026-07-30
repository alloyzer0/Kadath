const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const configured_glslc = b.option([]const u8, "glslc", "Absolute path to the glslc executable");
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
    });
    const preview_status_mod = b.createModule(.{
        .root_source_file = b.path("app/preview_status.zig"),
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
        const gcc_runtime_dir = mingw_gcc_runtime_dir.?;
        exe.root_module.addLibraryPath(.{ .cwd_relative = gcc_runtime_dir });
        exe.root_module.linkSystemLibrary("kadath_world", .{ .preferred_link_mode = .static });
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
    } else if (target.result.os.tag == .linux) {
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

        exe.step.dependOn(&cargo_build.step);
        const rust_profile = if (optimize == .Debug) "debug" else "release";
        exe.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ cargo_target_dir, rust_target, rust_profile }) });
        exe.root_module.linkSystemLibrary("kadath_world", .{ .preferred_link_mode = .static });
        exe.root_module.linkSystemLibrary("kadath_scheduler", .{ .preferred_link_mode = .static });
        exe.root_module.linkSystemLibrary("gcc_s", .{});
        exe.root_module.linkSystemLibrary("util", .{});
        exe.root_module.linkSystemLibrary("rt", .{});
        exe.root_module.linkSystemLibrary("pthread", .{});
        exe.root_module.linkSystemLibrary("m", .{});
        exe.root_module.linkSystemLibrary("dl", .{});
    }
    const install_exe = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install_exe.step);
    const preview_status_tests = b.addTest(.{
        .root_module = preview_status_mod,
    });
    const preview_status_test_run = b.addRunArtifact(preview_status_tests);
    const test_step = b.step("test", "Run Preview protocol unit tests");
    test_step.dependOn(&preview_status_test_run.step);

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

    const runtime_texture_registry_test_mod = b.createModule(.{
        .root_source_file = b.path("app/runtime_texture_registry.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    runtime_texture_registry_test_mod.addImport("resource", resource_mod);
    runtime_texture_registry_test_mod.addImport("renderer2d", null_renderer2d_mod);
    runtime_texture_registry_test_mod.addImport("rhi", null_rhi_mod);
    runtime_texture_registry_test_mod.addImport("world", world_mod);
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

    if (target.result.os.tag == .linux) {
        const platform_contract_mod = b.createModule(.{
            .root_source_file = b.path("modules/platform/tests/xcb_contract.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        platform_contract_mod.addImport("platform", platform_mod);
        const platform_contract_tests = b.addTest(.{ .root_module = platform_contract_mod });
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
    const texture_source_snapshot_test_barrier = b.option(
        []const u8,
        "texture-source-snapshot-test-barrier",
        "Verifier-only absolute empty directory used to pause after the PNG source snapshot",
    );
    const texture_source_snapshot_script =
        \\$sourcePath, $barrierPath, $faultMode, $destination = $args
        \\$ErrorActionPreference = 'Stop'
        \\Set-StrictMode -Version Latest
        \\if ($null -eq ('Kadath.TextureSourceSnapshot.Native' -as [type])) {
        \\    Add-Type -TypeDefinition @'
        \\using System;
        \\using System.ComponentModel;
        \\using System.IO;
        \\using System.Runtime.InteropServices;
        \\using Microsoft.Win32.SafeHandles;
        \\namespace Kadath.TextureSourceSnapshot
        \\{
        \\    public sealed class OwnedFile
        \\    {
        \\        public string Path { get; private set; }
        \\        public FileStream Stream { get; private set; }
        \\        public string VolumeFileId { get; private set; }
        \\        internal OwnedFile(string path, FileStream stream, string volumeFileId)
        \\        {
        \\            Path = path;
        \\            Stream = stream;
        \\            VolumeFileId = volumeFileId;
        \\        }
        \\        public void CloseStream()
        \\        {
        \\            if (Stream != null) {
        \\                Stream.Dispose();
        \\                Stream = null;
        \\            }
        \\        }
        \\    }
        \\    public static class Native
        \\    {
        \\        [StructLayout(LayoutKind.Sequential)]
        \\        private struct ByHandleFileInformation
        \\        {
        \\            public uint FileAttributes;
        \\            public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        \\            public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        \\            public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        \\            public uint VolumeSerialNumber;
        \\            public uint FileSizeHigh;
        \\            public uint FileSizeLow;
        \\            public uint NumberOfLinks;
        \\            public uint FileIndexHigh;
        \\            public uint FileIndexLow;
        \\        }
        \\        [DllImport("kernel32.dll", SetLastError = true)]
        \\        private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out ByHandleFileInformation information);
        \\        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        \\        private static extern SafeFileHandle CreateFile(
        \\            string fileName,
        \\            uint desiredAccess,
        \\            uint shareMode,
        \\            IntPtr securityAttributes,
        \\            uint creationDisposition,
        \\            uint flagsAndAttributes,
        \\            IntPtr templateFile);
        \\        [DllImport("kernel32.dll", SetLastError = true)]
        \\        private static extern bool SetFileInformationByHandle(
        \\            SafeFileHandle handle,
        \\            FileInformationByHandleClass fileInformationClass,
        \\            ref FileDispositionInformation fileInformation,
        \\            uint bufferSize);
        \\        private enum FileInformationByHandleClass
        \\        {
        \\            FileDispositionInfo = 4,
        \\        }
        \\        [StructLayout(LayoutKind.Sequential)]
        \\        private struct FileDispositionInformation
        \\        {
        \\            [MarshalAs(UnmanagedType.Bool)]
        \\            public bool DeleteFile;
        \\        }
        \\        private const uint DeleteAccess = 0x00010000;
        \\        private const uint FileReadAttributesAccess = 0x00000080;
        \\        private const uint GenericWriteAccess = 0x40000000;
        \\        private const uint CreateNew = 1;
        \\        private const uint OpenExisting = 3;
        \\        private const uint FileAttributeNormal = 0x00000080;
        \\        public static string GetVolumeFileId(SafeFileHandle handle)
        \\        {
        \\            if (handle == null || handle.IsInvalid) throw new InvalidOperationException("Owned temporary handle is invalid.");
        \\            ByHandleFileInformation information;
        \\            if (!GetFileInformationByHandle(handle, out information)) throw new Win32Exception(Marshal.GetLastWin32Error(), "GetFileInformationByHandle failed.");
        \\            ulong fileIndex = ((ulong)information.FileIndexHigh << 32) | information.FileIndexLow;
        \\            return information.VolumeSerialNumber.ToString("x8") + ":" + fileIndex.ToString("x16");
        \\        }
        \\        private static void MarkHandleForDelete(SafeFileHandle handle)
        \\        {
        \\            if (handle == null || handle.IsInvalid) throw new InvalidOperationException("Owned temporary handle is invalid.");
        \\            FileDispositionInformation disposition = new FileDispositionInformation { DeleteFile = true };
        \\            if (!SetFileInformationByHandle(
        \\                handle,
        \\                FileInformationByHandleClass.FileDispositionInfo,
        \\                ref disposition,
        \\                (uint)Marshal.SizeOf(typeof(FileDispositionInformation)))) {
        \\                throw new Win32Exception(Marshal.GetLastWin32Error(), "SetFileInformationByHandle(FileDispositionInfo) failed.");
        \\            }
        \\        }
        \\        public static OwnedFile CreateNewOwnedFile(string path, bool injectFileIdBeforeReturnFailure)
        \\        {
        \\            SafeFileHandle handle = null;
        \\            FileStream stream = null;
        \\            try
        \\            {
        \\                // 原 owning handle 从 CreateNew 起同时持有 WRITE 与 DELETE；异常路径绝不按 path 重新打开。
        \\                handle = CreateFile(
        \\                    path,
        \\                    GenericWriteAccess | DeleteAccess | FileReadAttributesAccess,
        \\                    0,
        \\                    IntPtr.Zero,
        \\                    CreateNew,
        \\                    FileAttributeNormal,
        \\                    IntPtr.Zero);
        \\                if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateFile(CreateNew) for owned snapshot failed.");
        \\                string volumeFileId = GetVolumeFileId(handle);
        \\                if (injectFileIdBeforeReturnFailure) throw new InvalidOperationException("Injected snapshot file-id-before-return failure.");
        \\                stream = new FileStream(handle, FileAccess.Write);
        \\                OwnedFile owned = new OwnedFile(path, stream, volumeFileId);
        \\                stream = null;
        \\                return owned;
        \\            }
        \\            catch (Exception primary)
        \\            {
        \\                Exception cleanupFailure = null;
        \\                try {
        \\                    if (handle != null && !handle.IsInvalid) MarkHandleForDelete(handle);
        \\                } catch (Exception cleanup) {
        \\                    cleanupFailure = cleanup;
        \\                }
        \\                try {
        \\                    if (stream != null) stream.Dispose();
        \\                    else if (handle != null) handle.Dispose();
        \\                } catch (Exception cleanup) {
        \\                    cleanupFailure = cleanupFailure == null ? cleanup : new AggregateException(cleanupFailure, cleanup);
        \\                }
        \\                if (cleanupFailure != null) throw new AggregateException("CreateNew owned snapshot cleanup failed.", primary, cleanupFailure);
        \\                throw;
        \\            }
        \\        }
        \\        public static void DeleteIfVolumeFileIdMatches(string path, string expectedVolumeFileId)
        \\        {
        \\            if (String.IsNullOrWhiteSpace(expectedVolumeFileId)) throw new ArgumentException("A recorded File ID is required.", "expectedVolumeFileId");
        \\            using (SafeFileHandle handle = CreateFile(
        \\                path,
        \\                DeleteAccess | FileReadAttributesAccess,
        \\                0,
        \\                IntPtr.Zero,
        \\                OpenExisting,
        \\                FileAttributeNormal,
        \\                IntPtr.Zero))
        \\            {
        \\                if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateFile for owned snapshot cleanup failed.");
        \\                if (!String.Equals(GetVolumeFileId(handle), expectedVolumeFileId, StringComparison.Ordinal)) {
        \\                    throw new InvalidOperationException("Refusing to delete a replaced snapshot object.");
        \\                }
        \\                MarkHandleForDelete(handle);
        \\            }
        \\        }
        \\    }
        \\}
        \\'@
        \\}
        \\function Assert-NoWin32DevicePath([string]$path, [string]$name) {
        \\    if ([string]::IsNullOrWhiteSpace($path)) { throw "$name cannot be empty" }
        \\    $windowsSpelling = $path.Replace('/', '\\')
        \\    if ($windowsSpelling.StartsWith('\\', [StringComparison]::Ordinal) -or $windowsSpelling.StartsWith('\??\', [StringComparison]::Ordinal)) { throw "$name cannot use UNC/device syntax: $path" }
        \\}
        \\function Assert-NoReparsePointInExistingPath([string]$path, [string]$name) {
        \\    Assert-NoWin32DevicePath $path $name
        \\    $full = [IO.Path]::GetFullPath($path)
        \\    $root = [IO.Path]::GetPathRoot($full)
        \\    $relative = [IO.Path]::GetRelativePath($root, $full)
        \\    $current = $root
        \\    if (((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$name root cannot be a reparse point: $current" }
        \\    foreach ($segment in $relative.Split([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar), [StringSplitOptions]::RemoveEmptyEntries)) {
        \\        $current = Join-Path $current $segment
        \\        if (-not (Test-Path -LiteralPath $current)) { break }
        \\        $item = Get-Item -LiteralPath $current -Force
        \\        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$name cannot traverse a reparse point: $current" }
        \\    }
        \\}
        \\function Get-CanonicalAbsolutePath([string]$path, [string]$name) {
        \\    Assert-NoWin32DevicePath $path $name
        \\    if (-not [IO.Path]::IsPathFullyQualified($path)) { throw "$name must be fully qualified: $path" }
        \\    $full = [IO.Path]::GetFullPath($path)
        \\    if (-not $path.Equals($full, [StringComparison]::OrdinalIgnoreCase)) { throw "$name must use its canonical absolute spelling: $path" }
        \\    Assert-NoReparsePointInExistingPath $full $name
        \\    return $full
        \\}
        \\function Resolve-CanonicalDirectory([string]$path, [string]$name) {
        \\    $full = Get-CanonicalAbsolutePath $path $name
        \\    if (-not (Test-Path -LiteralPath $full -PathType Container)) { throw "$name must be an existing directory: $full" }
        \\    $item = Get-Item -LiteralPath $full -Force
        \\    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$name cannot be a reparse point: $full" }
        \\    return (Resolve-Path -LiteralPath $full).Path
        \\}
        \\function Resolve-CanonicalFile([string]$path, [string]$name) {
        \\    $full = Get-CanonicalAbsolutePath $path $name
        \\    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "$name must be an existing regular file: $full" }
        \\    $item = Get-Item -LiteralPath $full -Force
        \\    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$name cannot be a reparse point: $full" }
        \\    return (Resolve-Path -LiteralPath $full).Path
        \\}
        \\function Test-DirectoryContains([string]$parent, [string]$candidate) {
        \\    $normalizedParent = $parent.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        \\    $normalizedCandidate = $candidate.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        \\    if ($normalizedParent.Equals($normalizedCandidate, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        \\    return $normalizedCandidate.StartsWith($normalizedParent + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
        \\}
        \\function Get-BytesHash([byte[]]$bytes) { return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant() }
        \\function New-OwnedFile([string]$path, [bool]$injectFileIdBeforeReturnFailure = $false) {
        \\    # C# helper 在原 CreateNew handle 仍打开时完成 File ID/对象分配；任何 return 前异常先 Delete disposition 再关闭。
        \\    return [Kadath.TextureSourceSnapshot.Native]::CreateNewOwnedFile($path, $injectFileIdBeforeReturnFailure)
        \\}
        \\function Write-OwnedFileDurable([object]$owned, [byte[]]$bytes, [string]$mode = '-') {
        \\    if ($null -eq $owned -or $null -eq $owned.Stream) { throw 'Owned temporary stream is unavailable' }
        \\    $stream = $owned.Stream
        \\    try {
        \\        if ($mode -ceq 'snapshot-partial-write-before-flush') {
        \\            # verifier 专用：留下部分 bytes 后在 Flush 前失败，回归覆盖不完整临时文件的 File ID cleanup。
        \\            $partialLength = [Math]::Max(1, [Math]::Min($bytes.Length - 1, 7))
        \\            $stream.Write($bytes, 0, $partialLength)
        \\            throw 'Injected snapshot partial-write-before-flush failure'
        \\        }
        \\        $stream.Write($bytes, 0, $bytes.Length)
        \\        $stream.Flush($true)
        \\    } finally {
        \\        $owned.CloseStream()
        \\    }
        \\}
        \\function Remove-OwnedTemporary([string]$path, [string]$expectedVolumeFileId) {
        \\    if (-not (Test-Path -LiteralPath $path)) { return }
        \\    if ([string]::IsNullOrWhiteSpace($expectedVolumeFileId)) { throw "Refusing to delete snapshot path without a recorded File ID: $path" }
        \\    Assert-NoReparsePointInExistingPath $path 'Owned snapshot file'
        \\    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Refusing to delete a non-file snapshot path: $path" }
        \\    # 身份比对与 FileDispositionInfo 删除标记固定在同一 DELETE 句柄上，关闭后才完成删除，避免路径二次解析竞态。
        \\    [Kadath.TextureSourceSnapshot.Native]::DeleteIfVolumeFileIdMatches($path, $expectedVolumeFileId)
        \\}
        \\$barrier = $null
        \\if ($faultMode -cne '-' -and $faultMode -cne 'snapshot-file-id-before-return' -and $faultMode -cne 'snapshot-partial-write-before-flush' -and $faultMode -cne 'snapshot-replace-before-cleanup') { throw "Unknown snapshot verifier fault mode: $faultMode" }
        \\if ($barrierPath -cne '-') {
        \\    Assert-NoWin32DevicePath $barrierPath 'Snapshot test barrier'
        \\    if (-not [IO.Path]::IsPathFullyQualified($barrierPath)) { throw 'Snapshot test barrier must be fully qualified' }
        \\    $barrier = [IO.Path]::GetFullPath($barrierPath)
        \\    if (-not $barrierPath.Equals($barrier, [StringComparison]::OrdinalIgnoreCase)) { throw 'Snapshot test barrier must use its canonical absolute spelling' }
        \\    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        \\    Assert-NoReparsePointInExistingPath $temporaryRoot 'System temporary root'
        \\    if (-not (Test-DirectoryContains $temporaryRoot $barrier) -or $temporaryRoot.Equals($barrier, [StringComparison]::OrdinalIgnoreCase)) { throw 'Snapshot test barrier must be below the system temporary root' }
        \\    Assert-NoReparsePointInExistingPath $barrier 'Snapshot test barrier'
        \\    if (-not (Test-Path -LiteralPath $barrier -PathType Container)) { throw 'Snapshot test barrier must be an existing directory' }
        \\    $barrierItem = Get-Item -LiteralPath $barrier -Force
        \\    if (($barrierItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Snapshot test barrier cannot be a reparse point' }
        \\    if (@(Get-ChildItem -LiteralPath $barrier -Force).Count -ne 0) { throw 'Snapshot test barrier must start empty' }
        \\}
        \\[byte[]]$sourceBytes = $null
        \\$sourceStream = $null
        \\try {
        \\    # 关键快照边界：打开 handle 前先锁定 canonical regular/non-reparse source。
        \\    $sourcePath = Resolve-CanonicalFile $sourcePath 'Texture source'
        \\    $sourceStream = [IO.File]::Open($sourcePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        \\    [long]$sourceLength = $sourceStream.Length
        \\    if ($sourceLength -le 0 -or $sourceLength -ge 8MB) { throw 'Texture source snapshot must contain 1..(8 MiB - 1) bytes' }
        \\    $sourceBytes = [byte[]]::new([int]$sourceLength)
        \\    $offset = 0
        \\    while ($offset -lt $sourceBytes.Length) {
        \\        $read = $sourceStream.Read($sourceBytes, $offset, $sourceBytes.Length - $offset)
        \\        if ($read -eq 0) { throw 'Texture source ended during snapshot read' }
        \\        $offset += $read
        \\    }
        \\    if ($sourceStream.ReadByte() -ne -1) { throw 'Texture source grew during snapshot read' }
        \\} finally {
        \\    if ($null -ne $sourceStream) { $sourceStream.Dispose() }
        \\}
        \\$sourceHash = Get-BytesHash $sourceBytes
        \\$destination = Get-CanonicalAbsolutePath $destination 'Texture source snapshot destination'
        \\$destinationParent = Split-Path -Parent $destination
        \\Assert-NoReparsePointInExistingPath $destinationParent 'Texture source snapshot output parent before create'
        \\if (-not (Test-Path -LiteralPath $destinationParent)) { New-Item -ItemType Directory -Path $destinationParent | Out-Null }
        \\$destinationParent = Resolve-CanonicalDirectory $destinationParent 'Texture source snapshot output parent after create'
        \\if (Test-Path -LiteralPath $destination) { throw "Texture source snapshot destination already exists: $destination" }
        \\$snapshotTemporary = Join-Path $destinationParent ('.kadath-texture-source-snapshot-{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
        \\$snapshotTemporaryOwned = $null
        \\$destinationVolumeFileId = $null
        \\$readyTemporary = $null
        \\$readyTemporaryOwned = $null
        \\$readyTemporaryBytes = $null
        \\$replacementTemporary = $null
        \\$replacementTemporaryOwned = $null
        \\$destinationCommitted = $false
        \\$snapshotSucceeded = $false
        \\try {
        \\    $snapshotTemporaryOwned = New-OwnedFile $snapshotTemporary ($faultMode -ceq 'snapshot-file-id-before-return')
        \\    Write-OwnedFileDurable $snapshotTemporaryOwned $sourceBytes $faultMode
        \\    if ($faultMode -ceq 'snapshot-replace-before-cleanup') {
        \\        # 同字节 replacement 专门证明 cleanup 不能退化为 length/hash/path：替换后 File ID 必须不同。
        \\        $replacementTemporary = Join-Path $destinationParent ('.kadath-texture-source-replacement-{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
        \\        $replacementTemporaryOwned = New-OwnedFile $replacementTemporary
        \\        Write-OwnedFileDurable $replacementTemporaryOwned $sourceBytes
        \\        [IO.File]::Replace($replacementTemporary, $snapshotTemporary, $null, $true)
        \\        throw 'Injected snapshot replace-before-cleanup failure'
        \\    }
        \\    if ((Get-FileHash -LiteralPath $snapshotTemporary -Algorithm SHA256).Hash.ToLowerInvariant() -cne $sourceHash) { throw 'Durable texture source snapshot hash mismatch' }
        \\    $moveParent = Resolve-CanonicalDirectory $destinationParent 'Texture source snapshot output parent before move'
        \\    if (-not $moveParent.Equals($destinationParent, [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $destination)) { throw 'Texture source snapshot destination changed before no-replace move' }
        \\    [IO.File]::Move($snapshotTemporary, $destination, $false)
        \\    $destinationCommitted = $true
        \\    $destinationVolumeFileId = $snapshotTemporaryOwned.VolumeFileId
        \\    $committedDestination = Resolve-CanonicalFile $destination 'Committed texture source snapshot'
        \\    if ((Get-Item -LiteralPath $committedDestination -Force).Length -ne $sourceBytes.Length -or (Get-FileHash -LiteralPath $committedDestination -Algorithm SHA256).Hash.ToLowerInvariant() -cne $sourceHash) { throw 'Committed texture source snapshot identity mismatch' }
        \\    if ($null -ne $barrier) {
        \\        Assert-NoReparsePointInExistingPath $barrier 'Snapshot test barrier before ready'
        \\        $readyPath = Join-Path $barrier 'ready.json'
        \\        $releasePath = Join-Path $barrier 'release'
        \\        if ((Test-Path -LiteralPath $readyPath) -or (Test-Path -LiteralPath $releasePath)) { throw 'Snapshot test barrier contains a pre-existing control path' }
        \\        $readyDocument = [ordered]@{ Version = 1; Length = [long]$sourceBytes.Length; Sha256 = $sourceHash }
        \\        $readyTemporaryBytes = [Text.UTF8Encoding]::new($false).GetBytes(($readyDocument | ConvertTo-Json -Compress) + "`n")
        \\        $readyTemporary = Join-Path $barrier ('.ready-{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
        \\        $readyTemporaryOwned = New-OwnedFile $readyTemporary
        \\        Write-OwnedFileDurable $readyTemporaryOwned $readyTemporaryBytes
        \\        [IO.File]::Move($readyTemporary, $readyPath, $false)
        \\        $wait = [Diagnostics.Stopwatch]::StartNew()
        \\        while ($true) {
        \\            if (Test-Path -LiteralPath $releasePath) {
        \\                Assert-NoReparsePointInExistingPath $barrier 'Snapshot test barrier before release'
        \\                if (-not (Test-Path -LiteralPath $releasePath -PathType Leaf)) { throw 'Snapshot test barrier release must be a regular file' }
        \\                $release = Get-Item -LiteralPath $releasePath -Force
        \\                if (($release.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $release.Length -ne 0) { throw 'Snapshot test barrier release must be zero-length and non-reparse' }
        \\                break
        \\            }
        \\            if ($wait.ElapsedMilliseconds -ge 30000) { throw 'Timed out waiting for snapshot test barrier release' }
        \\            Start-Sleep -Milliseconds 25
        \\        }
        \\    }
        \\    $snapshotSucceeded = $true
        \\} finally {
        \\    # cleanup 必须全部尝试：destination rollback 优先，单项失败不得短路其它 owned temp。
        \\    $cleanupErrors = [Collections.Generic.List[Exception]]::new()
        \\    try {
        \\        if ($destinationCommitted -and -not $snapshotSucceeded) { Remove-OwnedTemporary $destination $destinationVolumeFileId }
        \\    } catch { $cleanupErrors.Add($_.Exception) }
        \\    try {
        \\        if ($null -ne $snapshotTemporaryOwned) { Remove-OwnedTemporary $snapshotTemporary $snapshotTemporaryOwned.VolumeFileId }
        \\    } catch { $cleanupErrors.Add($_.Exception) }
        \\    try {
        \\        if ($null -ne $replacementTemporaryOwned) { Remove-OwnedTemporary $replacementTemporary $replacementTemporaryOwned.VolumeFileId }
        \\    } catch { $cleanupErrors.Add($_.Exception) }
        \\    try {
        \\        if ($null -ne $readyTemporaryOwned) { Remove-OwnedTemporary $readyTemporary $readyTemporaryOwned.VolumeFileId }
        \\    } catch { $cleanupErrors.Add($_.Exception) }
        \\    if ($cleanupErrors.Count -eq 1) { throw $cleanupErrors[0] }
        \\    if ($cleanupErrors.Count -gt 1) { throw [AggregateException]::new('Texture source snapshot cleanup failures', $cleanupErrors) }
        \\}
    ;
    const texture_source_snapshot_command = b.addSystemCommand(&.{ "pwsh", "-NoProfile", "-CommandWithArgs", texture_source_snapshot_script });
    texture_source_snapshot_command.addFileArg(b.path("assets/renderer2d/test.png"));
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
    if (texture_source_snapshot_test_fault) |fault_mode| {
        texture_source_snapshot_command.addArg(fault_mode);
    } else {
        texture_source_snapshot_command.addArg("-");
    }
    const texture_source_snapshot = texture_source_snapshot_command.addOutputFileArg("test.png");

    const secondary_texture_source_snapshot_test_barrier = b.option(
        []const u8,
        "secondary-texture-source-snapshot-test-barrier",
        "Verifier-only absolute empty directory used to pause after the secondary PNG source snapshot",
    );
    const secondary_texture_source_snapshot_command = b.addSystemCommand(&.{ "pwsh", "-NoProfile", "-CommandWithArgs", texture_source_snapshot_script });
    secondary_texture_source_snapshot_command.addFileArg(b.path("assets/renderer2d/goal.png"));
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
    if (secondary_texture_source_snapshot_test_fault) |fault_mode| {
        secondary_texture_source_snapshot_command.addArg(fault_mode);
    } else {
        secondary_texture_source_snapshot_command.addArg("-");
    }
    const secondary_texture_source_snapshot = secondary_texture_source_snapshot_command.addOutputFileArg("goal.png");

    const install_assets = b.addInstallDirectory(.{
        .source_dir = b.path("assets"),
        .install_dir = .bin,
        .install_subdir = "assets",
    });
    b.getInstallStep().dependOn(&install_assets.step);
    // install_assets 仍提供完整资产树；两个 snapshot install 是对应 PNG 的唯一有序 final writer。
    const install_texture_source_snapshot = b.addInstallFile(texture_source_snapshot, "bin/assets/renderer2d/test.png");
    install_texture_source_snapshot.step.dependOn(&install_assets.step);
    b.getInstallStep().dependOn(&install_texture_source_snapshot.step);
    const install_secondary_texture_source_snapshot = b.addInstallFile(secondary_texture_source_snapshot, "bin/assets/renderer2d/goal.png");
    install_secondary_texture_source_snapshot.step.dependOn(&install_assets.step);
    b.getInstallStep().dependOn(&install_secondary_texture_source_snapshot.step);
    // Importer/Baker 在安装阶段从 PNG 源生成确定性 KDAT；Zig optimize 不改变 release texture profile。
    const texture_import = b.addSystemCommand(&.{ "pwsh", "-NoProfile", "-File" });
    texture_import.addFileArg(b.path("tools/editor-texture-importer.ps1"));
    texture_import.addArg("-SourcePath");
    texture_import.addFileArg(texture_source_snapshot);
    texture_import.addArgs(&.{ "-Profile", "release", "-DestinationPath" });
    const texture_artifact = texture_import.addOutputFileArg("test.texture");
    const install_texture_artifact = b.addInstallFile(texture_artifact, "bin/assets/renderer2d/test.texture");
    b.getInstallStep().dependOn(&install_texture_artifact.step);
    const secondary_texture_import = b.addSystemCommand(&.{ "pwsh", "-NoProfile", "-File" });
    secondary_texture_import.addFileArg(b.path("tools/editor-texture-importer.ps1"));
    secondary_texture_import.addArg("-SourcePath");
    secondary_texture_import.addFileArg(secondary_texture_source_snapshot);
    secondary_texture_import.addArgs(&.{ "-Profile", "release", "-DestinationPath" });
    const secondary_texture_artifact = secondary_texture_import.addOutputFileArg("goal.texture");
    const install_secondary_texture_artifact = b.addInstallFile(secondary_texture_artifact, "bin/assets/renderer2d/goal.texture");
    b.getInstallStep().dependOn(&install_secondary_texture_artifact.step);
    // 两个音频 artifact 独立构建，任一失败都会阻止 install/package 完成。
    const audio_import_won = b.addSystemCommand(&.{ "pwsh", "-NoProfile", "-File" });
    audio_import_won.addFileArg(b.path("tools/editor-audio-importer.ps1"));
    audio_import_won.addArg("-SourcePath");
    audio_import_won.addFileArg(b.path("assets/audio/won.wav"));
    audio_import_won.addArgs(&.{ "-Profile", "release", "-DestinationPath" });
    const won_audio_artifact = audio_import_won.addOutputFileArg("won.audio.wav");
    const install_won_audio_artifact = b.addInstallFile(won_audio_artifact, "bin/assets/audio/won.audio.wav");
    b.getInstallStep().dependOn(&install_won_audio_artifact.step);

    const audio_import_lost = b.addSystemCommand(&.{ "pwsh", "-NoProfile", "-File" });
    audio_import_lost.addFileArg(b.path("tools/editor-audio-importer.ps1"));
    audio_import_lost.addArg("-SourcePath");
    audio_import_lost.addFileArg(b.path("assets/audio/lost.wav"));
    audio_import_lost.addArgs(&.{ "-Profile", "release", "-DestinationPath" });
    const lost_audio_artifact = audio_import_lost.addOutputFileArg("lost.audio.wav");
    const install_lost_audio_artifact = b.addInstallFile(lost_audio_artifact, "bin/assets/audio/lost.audio.wav");
    b.getInstallStep().dependOn(&install_lost_audio_artifact.step);

    // Scene 源 JSON 只保留给 Editor authoring；安装包同时生成 Runtime 消费的 KSCN v1 artifact。
    const scene_import = b.addSystemCommand(&.{ "pwsh", "-NoProfile", "-File" });
    scene_import.addFileArg(b.path("tools/editor-scene-importer.ps1"));
    scene_import.addArg("-SourcePath");
    scene_import.addFileArg(b.path("assets/scenes/preview.scene.json"));
    scene_import.addArgs(&.{ "-Profile", "release", "-DestinationPath" });
    const scene_artifact = scene_import.addOutputFileArg("preview.scene");
    const install_scene_artifact = b.addInstallFile(scene_artifact, "bin/assets/scenes/preview.scene");
    b.getInstallStep().dependOn(&install_scene_artifact.step);

    // Script 源 JSON 只保留给 Editor authoring；安装包同时生成 Runtime 消费的 KSCP v1 artifact。
    const script_import = b.addSystemCommand(&.{ "pwsh", "-NoProfile", "-File" });
    script_import.addFileArg(b.path("tools/editor-script-importer.ps1"));
    script_import.addArg("-SourcePath");
    script_import.addFileArg(b.path("assets/scripts/preview.script.json"));
    script_import.addArgs(&.{ "-Profile", "release", "-DestinationPath" });
    const script_artifact = script_import.addOutputFileArg("preview.script");
    const install_script_artifact = b.addInstallFile(script_artifact, "bin/assets/scripts/preview.script");
    b.getInstallStep().dependOn(&install_script_artifact.step);

    const install_package_readme = b.addInstallFile(
        b.path("packaging/README.txt"),
        "README.txt",
    );
    b.getInstallStep().dependOn(&install_package_readme.step);

    // 关键包身份必须绑定当次链接产物；addFileArg 同时建立 exe/source 的依赖与 cache key。
    const runtime_preflight_sidecar = b.option(
        []const u8,
        "runtime-preflight-sidecar",
        "Absolute path to the operator-created PNG Runtime pre-build witness",
    );
    const runtime_build_profile_script =
        \\$runtimePath, $texturePath, $textureArtifactPath, $secondaryTexturePath, $secondaryTextureArtifactPath, $vertexPath, $fragmentPath, $optimize, $packageRoot, $localCacheRoot, $globalCacheRoot, $preflightPath, $destination = $args
        \\$ErrorActionPreference = 'Stop'
        \\function Get-CanonicalLocalPath([string]$path, [string]$name) {
        \\    if ([string]::IsNullOrWhiteSpace($path) -or -not [IO.Path]::IsPathFullyQualified($path)) { throw "$name must be an absolute local path" }
        \\    $windowsSpelling = $path.Replace('/', '\\')
        \\    if ($windowsSpelling.StartsWith('\\\\', [StringComparison]::Ordinal) -or $windowsSpelling.StartsWith('\\??\\', [StringComparison]::Ordinal)) { throw "$name cannot use UNC/device syntax" }
        \\    return [IO.Path]::GetFullPath($windowsSpelling).TrimEnd('\\').ToLowerInvariant()
        \\}
        \\$preflightSha256 = $null
        \\if ($preflightPath -cne '-') {
        \\    [byte[]]$preflightBytes = [IO.File]::ReadAllBytes($preflightPath)
        \\    if ($preflightBytes.Length -eq 0 -or $preflightBytes.Length -gt 65536) { throw 'Runtime preflight sidecar must contain 1..65536 bytes' }
        \\    $preflightSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($preflightBytes)).ToLowerInvariant()
        \\    $preflightJson = [Text.UTF8Encoding]::new($false, $true).GetString($preflightBytes)
        \\    $preflight = $preflightJson | ConvertFrom-Json
        \\    $jsonDocument = [System.Text.Json.JsonDocument]::Parse($preflightJson)
        \\    try { $generatedAtText = $jsonDocument.RootElement.GetProperty('GeneratedAtUtc').GetString() } finally { $jsonDocument.Dispose() }
        \\    $generatedAt = [DateTimeOffset]::MinValue
        \\    if ([int]$preflight.Version -ne 1 -or [string]::IsNullOrWhiteSpace($generatedAtText) -or -not [DateTimeOffset]::TryParseExact($generatedAtText, 'O', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$generatedAt) -or $generatedAt.Offset -ne [TimeSpan]::Zero) { throw 'Runtime preflight sidecar has an invalid v1 GeneratedAtUtc' }
        \\    if (($preflight.PackageRootAbsentBefore -isnot [bool]) -or -not $preflight.PackageRootAbsentBefore -or ($preflight.TaskLocalCacheAbsentBefore -isnot [bool]) -or -not $preflight.TaskLocalCacheAbsentBefore -or ($preflight.GlobalCacheAbsentBefore -isnot [bool]) -or -not $preflight.GlobalCacheAbsentBefore) { throw 'Runtime preflight sidecar must witness all roots absent before build' }
        \\    $rootPairs = @(
        \\        @([string]$preflight.PackageRoot, $packageRoot, 'PackageRoot'),
        \\        @([string]$preflight.TaskLocalCacheDirectory, $localCacheRoot, 'TaskLocalCacheDirectory'),
        \\        @([string]$preflight.GlobalCacheDirectory, $globalCacheRoot, 'GlobalCacheDirectory')
        \\    )
        \\    foreach ($pair in $rootPairs) {
        \\        $claimed = Get-CanonicalLocalPath $pair[0] "Preflight $($pair[2])"
        \\        $actual = Get-CanonicalLocalPath $pair[1] "Build $($pair[2])"
        \\        if (-not $pair[0].Equals($claimed, [StringComparison]::OrdinalIgnoreCase) -or $claimed -cne $actual) { throw "Runtime preflight $($pair[2]) does not match the Zig build graph" }
        \\    }
        \\    $sidecarInfo = Get-Item -LiteralPath $preflightPath -Force
        \\    $timestampTolerance = [TimeSpan]::FromSeconds(2)
        \\    if ([math]::Abs(($generatedAt.UtcDateTime - $sidecarInfo.LastWriteTimeUtc).TotalSeconds) -gt $timestampTolerance.TotalSeconds) { throw 'Runtime preflight GeneratedAtUtc and sidecar LastWriteTimeUtc differ by more than 2 seconds' }
        \\    foreach ($rootPath in @($packageRoot, $localCacheRoot, $globalCacheRoot)) {
        \\        if (-not (Test-Path -LiteralPath $rootPath -PathType Container)) { throw "Zig build graph root does not exist before marker generation: $rootPath" }
        \\        $rootInfo = Get-Item -LiteralPath $rootPath -Force
        \\        $latestWitnessTime = $rootInfo.CreationTimeUtc + $timestampTolerance
        \\        if ($generatedAt.UtcDateTime -gt $latestWitnessTime -or $sidecarInfo.LastWriteTimeUtc -gt $latestWitnessTime) { throw "Runtime preflight witness is newer than a build graph root: $rootPath" }
        \\    }
        \\}
        \\$document = [ordered]@{
        \\    Version = 2
        \\    Optimize = $optimize
        \\    TextureProfile = 'release'
        \\    RuntimeExeSha256 = (Get-FileHash -LiteralPath $runtimePath -Algorithm SHA256).Hash.ToLowerInvariant()
        \\    TextureSourceSha256 = (Get-FileHash -LiteralPath $texturePath -Algorithm SHA256).Hash.ToLowerInvariant()
        \\    TextureArtifactSha256 = (Get-FileHash -LiteralPath $textureArtifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
        \\    SecondaryTextureSourceSha256 = (Get-FileHash -LiteralPath $secondaryTexturePath -Algorithm SHA256).Hash.ToLowerInvariant()
        \\    SecondaryTextureArtifactSha256 = (Get-FileHash -LiteralPath $secondaryTextureArtifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
        \\    VertexShaderSourceSha256 = (Get-FileHash -LiteralPath $vertexPath -Algorithm SHA256).Hash.ToLowerInvariant()
        \\    FragmentShaderSourceSha256 = (Get-FileHash -LiteralPath $fragmentPath -Algorithm SHA256).Hash.ToLowerInvariant()
        \\    BuildPreflightSidecarSha256 = $preflightSha256
        \\}
        \\$temporary = "$destination.tmp-$([Guid]::NewGuid().ToString('N'))"
        \\try {
        \\    $json = ($document | ConvertTo-Json -Compress) + "`n"
        \\    [IO.File]::WriteAllText($temporary, $json, [Text.UTF8Encoding]::new($false))
        \\    [IO.File]::Move($temporary, $destination, $false)
        \\} finally {
        \\    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
        \\}
    ;
    const runtime_build_profile_command = b.addSystemCommand(&.{ "pwsh", "-NoProfile", "-CommandWithArgs", runtime_build_profile_script });
    runtime_build_profile_command.step.dependOn(&install_exe.step);
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
    const install_runtime_build_profile = b.addInstallFile(runtime_build_profile, "bin/kadath-runtime-build-profile.json");
    b.getInstallStep().dependOn(&install_runtime_build_profile.step);

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
