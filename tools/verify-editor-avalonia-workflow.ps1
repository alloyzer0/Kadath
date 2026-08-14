[CmdletBinding()]
param(
    [string]$KadathRoot = (Join-Path $PSScriptRoot '..'),
    [string]$PackageRoot = '',
    [string]$ProjectName = "codex_avalonia_workflow_$PID",
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Debug'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$kadath = (Resolve-Path -LiteralPath $KadathRoot).Path
if ([string]::IsNullOrWhiteSpace($PackageRoot)) { $PackageRoot = Join-Path $kadath 'zig-out' }
$package = (Resolve-Path -LiteralPath $PackageRoot).Path
$project = Join-Path $kadath 'editor\Kadath.Editor.Avalonia\Kadath.Editor.Avalonia.csproj'
$projectsRoot = [IO.Path]::GetFullPath((Join-Path $package 'bin\projects'))
$projectsPrefix = $projectsRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
$openProjectName = "${ProjectName}_open_fixture"
$createdProjectName = "${ProjectName}_created"
$openProjectDirectory = [IO.Path]::GetFullPath((Join-Path $projectsRoot $openProjectName))
$createdProjectDirectory = [IO.Path]::GetFullPath((Join-Path $projectsRoot $createdProjectName))
$projectDirectories = @($openProjectDirectory, $createdProjectDirectory)
foreach ($projectDirectory in $projectDirectories) {
    if (-not $projectDirectory.StartsWith($projectsPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Workflow project path escapes package/bin/projects.' }
    if (Test-Path -LiteralPath $projectDirectory) { throw "Workflow project already exists: $projectDirectory" }
}

function New-OpenFixture {
    $sceneTemplate = Join-Path $package 'bin/assets/scenes/preview.scene.json'
    $scriptTemplate = Join-Path $package 'bin/assets/scripts/preview.script.json'
    foreach ($template in @($sceneTemplate, $scriptTemplate)) {
        if (-not (Test-Path -LiteralPath $template -PathType Leaf)) { throw "Workflow template does not exist: $template" }
    }

    New-Item -ItemType Directory -Path $openProjectDirectory | Out-Null
    [IO.File]::Copy($sceneTemplate, (Join-Path $openProjectDirectory 'scene.json'))
    [IO.File]::Copy($scriptTemplate, (Join-Path $openProjectDirectory 'script.json'))

    $scriptManifest = Get-Content -LiteralPath $scriptTemplate -Raw | ConvertFrom-Json
    $scriptSchemaVersion = [int]$scriptManifest.schemaVersion
    if ($scriptSchemaVersion -notin @(1, 2)) { throw "Unsupported workflow Script schema version: $scriptSchemaVersion" }
    if ($scriptSchemaVersion -eq 2) {
        $assetRoot = Join-Path $package 'bin/assets'
        foreach ($entry in @($scriptManifest.scripts)) {
            $source = [string]$entry.source
            $unsafeSource = ($source -notmatch '^scripts/[^/]+(?:/[^/]+)*\.luau$') -or
                $source.Contains('..') -or
                $source.Contains('\') -or
                [IO.Path]::IsPathRooted($source)
            if ($unsafeSource) {
                throw "Workflow fixture received an unsafe script source path: $source"
            }
            $sourcePath = [IO.Path]::GetFullPath((Join-Path $assetRoot $source))
            $destinationPath = [IO.Path]::GetFullPath((Join-Path $openProjectDirectory $source))
            $assetPrefix = $assetRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
            $projectPrefix = $openProjectDirectory.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
            $escapesRoot = -not $sourcePath.StartsWith($assetPrefix, [StringComparison]::OrdinalIgnoreCase) -or
                -not $destinationPath.StartsWith($projectPrefix, [StringComparison]::OrdinalIgnoreCase)
            if ($escapesRoot) {
                throw "Workflow fixture dependency path escaped its controlled root: $source"
            }
            $destinationDirectory = Split-Path -Parent $destinationPath
            if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) {
                New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
            }
            if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
                throw "Workflow fixture script dependency does not exist: $source"
            }
            [IO.File]::Copy($sourcePath, $destinationPath)
        }
    }

    $executable = if ($IsWindows) { 'bin/kadath.exe' } else { 'bin/kadath' }
    $preview = [ordered]@{
        schemaVersion = 1
        runtime = [ordered]@{
            executable = $executable
            workingDirectory = 'bin'
            arguments = @('--scene', "projects/$openProjectName/scene.json", '--script', "projects/$openProjectName/script.json")
        }
    }
    [IO.File]::WriteAllText(
        (Join-Path $openProjectDirectory 'preview.json'),
        ($preview | ConvertTo-Json -Depth 8),
        [Text.UTF8Encoding]::new($false))
}

try {
    & dotnet build $project -c $Configuration --no-restore -m:1 -p:NuGetAudit=false
    if ($LASTEXITCODE -ne 0) { throw 'Avalonia workflow project build failed.' }

    # Open fixture 只复制 package 内受控模板；第二个项目必须由 Avalonia public Create 入口经 typed Client 创建。
    New-OpenFixture

    $output = @(& dotnet run --project $project -c $Configuration --no-build -- --workflow-smoke $kadath $package $openProjectName $createdProjectName 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Avalonia shared-Workspace workflow failed: $($output -join ' | ')" }

    $expected = @(
        'workflow_connect=ok',
        'workflow_project_open=ok',
        'workflow_snapshot_projection=ok',
        'workflow_behavior_preservation=ok',
        'workflow_behavior_binding_authoring=ok',
        'workflow_script_source_authoring=ok',
        'workflow_script_asset_lifecycle=ok',
        'workflow_script_asset_runtime_execution=ok',
        'workflow_project_create=ok',
        'workflow_publication_missing=ok',
        'workflow_authoring_apply=ok',
        'workflow_authoring_undo=ok',
        'workflow_project_validate=ok',
        'workflow_bake=ok',
        'workflow_publication_dirty=ok',
        'workflow_bake_changes=ok',
        'workflow_watch_start=ok',
        'workflow_watch_stop=ok',
        'workflow_preview_start=ok',
        'workflow_preview_initial_loaded=ok',
        'workflow_script_diagnostics_publication=ok',
        'workflow_preview_reload_ack=ok',
        'workflow_preview_stop=ok',
        'workflow_texture_import=ok',
        'workflow_shutdown=ok',
        'verification=ok'
    )
    foreach ($line in $expected) {
        if ($output -notcontains $line) { throw "Avalonia workflow output is missing: $line" }
    }

    $output | Where-Object { $_ -in $expected }
}
finally {
    foreach ($projectDirectory in $projectDirectories) {
        if (Test-Path -LiteralPath $projectDirectory) {
            $resolved = (Resolve-Path -LiteralPath $projectDirectory).Path
            # 关键清理边界：只允许移除本次明确命名、且位于 package/bin/projects 下的两个目录。
            if (-not $resolved.StartsWith($projectsPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing to clean a project outside package/bin/projects.' }
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}
