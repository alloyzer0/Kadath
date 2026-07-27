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
        const async_texture_test_step = b.step("test-resource-async", "Run Resource-owned async texture tests without GPU");
        async_texture_test_step.dependOn(&async_texture_test_run.step);
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
    }
    const install_exe = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install_exe.step);
    const preview_status_tests = b.addTest(.{
        .root_module = preview_status_mod,
    });
    const preview_status_test_run = b.addRunArtifact(preview_status_tests);
    const test_step = b.step("test", "Run Preview protocol unit tests");
    test_step.dependOn(&preview_status_test_run.step);

    // 分发目录以 bin 为运行工作目录，资产必须与 exe 保持稳定的相对位置。
    const install_assets = b.addInstallDirectory(.{
        .source_dir = b.path("assets"),
        .install_dir = .bin,
        .install_subdir = "assets",
    });
    b.getInstallStep().dependOn(&install_assets.step);
    // Importer/Baker 在安装阶段从 PNG 源生成确定性 KDAT；Zig optimize 不改变 release texture profile。
    const texture_import = b.addSystemCommand(&.{ "pwsh", "-NoProfile", "-File" });
    texture_import.addFileArg(b.path("tools/editor-texture-importer.ps1"));
    texture_import.addArg("-SourcePath");
    texture_import.addFileArg(b.path("assets/renderer2d/test.png"));
    texture_import.addArgs(&.{ "-Profile", "release", "-DestinationPath" });
    const texture_artifact = texture_import.addOutputFileArg("test.texture");
    const install_texture_artifact = b.addInstallFile(texture_artifact, "bin/assets/renderer2d/test.texture");
    b.getInstallStep().dependOn(&install_texture_artifact.step);
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
        \\$runtimePath, $texturePath, $textureArtifactPath, $vertexPath, $fragmentPath, $optimize, $packageRoot, $localCacheRoot, $globalCacheRoot, $preflightPath, $destination = $args
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
        \\    Version = 1
        \\    Optimize = $optimize
        \\    TextureProfile = 'release'
        \\    RuntimeExeSha256 = (Get-FileHash -LiteralPath $runtimePath -Algorithm SHA256).Hash.ToLowerInvariant()
        \\    TextureSourceSha256 = (Get-FileHash -LiteralPath $texturePath -Algorithm SHA256).Hash.ToLowerInvariant()
        \\    TextureArtifactSha256 = (Get-FileHash -LiteralPath $textureArtifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
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
    runtime_build_profile_command.addFileArg(b.path("assets/renderer2d/test.png"));
    runtime_build_profile_command.addFileArg(texture_artifact);
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
