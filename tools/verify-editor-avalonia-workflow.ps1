[CmdletBinding()]
param(
    [string]$KadathRoot = (Join-Path $PSScriptRoot '..'),
    [string]$PackageRoot = '',
    [string]$ProjectName = "codex_avalonia_workflow_$PID"
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$kadath = (Resolve-Path -LiteralPath $KadathRoot).Path
if ([string]::IsNullOrWhiteSpace($PackageRoot)) { $PackageRoot = Join-Path $kadath 'zig-out' }
$package = (Resolve-Path -LiteralPath $PackageRoot).Path
$author = Join-Path $kadath 'tools\editor-author.ps1'
$project = Join-Path $kadath 'editor\Kadath.Editor.Avalonia\Kadath.Editor.Avalonia.csproj'
$projectsRoot = [IO.Path]::GetFullPath((Join-Path $package 'bin\projects'))
$projectDirectory = [IO.Path]::GetFullPath((Join-Path $projectsRoot $ProjectName))
$projectsPrefix = $projectsRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if (-not $projectDirectory.StartsWith($projectsPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Workflow project path escapes package/bin/projects.' }
if (Test-Path -LiteralPath $projectDirectory) { throw "Workflow project already exists: $projectDirectory" }

try {
    & dotnet build $project --no-restore -m:1 -p:NuGetAudit=false
    if ($LASTEXITCODE -ne 0) { throw 'Avalonia workflow project build failed.' }

    # 使用正式 package 模板创建隔离项目；finally 只删除通过边界检查的本次项目目录。
    & pwsh -NoProfile -File $author -Action Create -PackageRoot $package -ProjectName $ProjectName | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to create isolated Avalonia workflow project.' }

    $output = @(& dotnet run --project $project --no-build -- --workflow-smoke $kadath $package $ProjectName 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Avalonia shared-Workspace workflow failed: $($output -join ' | ')" }

    $expected = @(
        'workflow_connect=ok',
        'workflow_project_open=ok',
        'workflow_snapshot_projection=ok',
        'workflow_authoring_apply=ok',
        'workflow_authoring_undo=ok',
        'workflow_project_validate=ok',
        'workflow_bake=ok',
        'workflow_watch_start=ok',
        'workflow_watch_stop=ok',
        'workflow_preview_start=ok',
        'workflow_preview_stop=ok',
        'workflow_shutdown=ok',
        'verification=ok'
    )
    foreach ($line in $expected) {
        if ($output -notcontains $line) { throw "Avalonia workflow output is missing: $line" }
    }

    $output | Where-Object { $_ -in $expected }
}
finally {
    if (Test-Path -LiteralPath $projectDirectory) {
        $resolved = (Resolve-Path -LiteralPath $projectDirectory).Path
        # 关键清理边界：只允许移除 package/bin/projects 下的当前随机项目。
        if (-not $resolved.StartsWith($projectsPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing to clean a project outside package/bin/projects.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
