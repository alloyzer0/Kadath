[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackageRoot,

    [string]$ProjectName = "gui_workflow_$PID"
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$guiScript = Join-Path $PSScriptRoot 'editor-gui.ps1'
if (-not (Test-Path -LiteralPath $guiScript -PathType Leaf)) { throw "GUI script does not exist: $guiScript" }

$headlessOutput = @(& pwsh -NoProfile -File $guiScript -PackageRoot $PackageRoot -ProjectName $ProjectName -Headless 2>&1)
if ($LASTEXITCODE -ne 0 -or @($headlessOutput | Where-Object { $_.ToString() -eq 'gui_optional_reload_fields=ok' }).Count -ne 1) {
    throw "GUI optional reload-field contract failed: $($headlessOutput -join ' | ')"
}

# 该 verifier 让 GUI 自己驱动真实按钮事件；它不是绕过 UI 的 CLI workflow。
$output = & pwsh -NoProfile -File $guiScript -PackageRoot $PackageRoot -ProjectName $ProjectName -WorkflowSmoke 2>&1
$exitCode = $LASTEXITCODE
foreach ($line in $output) { Write-Output ([string]$line) }
if ($exitCode -ne 0) { throw "GUI workflow smoke exited with code $exitCode" }
if (@($output | Where-Object { $_.ToString() -eq 'gui_workflow_smoke=ok' }).Count -ne 1) {
    throw 'GUI workflow smoke did not emit gui_workflow_smoke=ok'
}
if (@($output | Where-Object { $_.ToString() -eq 'workflow_reload_acknowledged=2' }).Count -ne 1) {
    throw 'GUI workflow smoke did not confirm both Runtime reload revisions'
}
Write-Output 'gui_optional_reload_fields=ok'
Write-Output 'verification=ok'
