[CmdletBinding()]
param(
    [string]$EditorRoot = (Join-Path $PSScriptRoot '..\editor')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$project = Join-Path $EditorRoot 'Kadath.Editor.Avalonia\Kadath.Editor.Avalonia.csproj'
if (-not (Test-Path -LiteralPath $project -PathType Leaf)) { throw "Avalonia project does not exist: $project" }

# 受限环境中不依赖漏洞 feed；项目本身也关闭了 NuGetAudit，联网 CI 可覆盖该开关。
& dotnet build $project --no-restore -m:1 -p:NuGetAudit=false
if ($LASTEXITCODE -ne 0) { throw 'Avalonia project build failed.' }

$output = @(& dotnet run --project $project --no-build -- --headless-smoke 2>&1)
if ($LASTEXITCODE -ne 0) { throw "Avalonia headless smoke failed: $($output -join ' | ')" }
foreach ($expected in @('avalonia_compiled_xaml=ok', 'shared_workspace_injection=ok', 'live_bake_opt_in=ok', 'scene_object_draft_commands=ok', 'texture_import_controls=ok', 'texture_import_projection=ok', 'capability_gating=ok', 'verification=ok'))
{
    if ($output -notcontains $expected) { throw "Avalonia smoke output is missing: $expected" }
}

Write-Output 'avalonia_build=ok'
Write-Output 'avalonia_compiled_xaml=ok'
Write-Output 'shared_workspace_injection=ok'
Write-Output 'live_bake_opt_in=ok'
Write-Output 'scene_object_draft_commands=ok'
Write-Output 'texture_import_controls=ok'
Write-Output 'texture_import_projection=ok'
Write-Output 'capability_gating=ok'
Write-Output 'verification=ok'
