[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackageRoot,

    [string]$OutputDirectory,

    [string]$ExecutableRelativePath = 'bin/kadath.exe',

    [string]$SceneRelativePath = 'bin/assets/scenes/preview.scene.json',

    [string]$ScriptRelativePath = 'bin/assets/scripts/preview.script.json'
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class KadathWorkflowNative {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
}
"@

function Resolve-ExistingDirectory([string]$Path, [string]$Name) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "$Name does not exist: $Path"
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Resolve-PackageFile([string]$Root, [string]$RelativePath, [string]$Name) {
    if ([IO.Path]::IsPathRooted($RelativePath)) {
        throw "$Name must be relative to the package root: $RelativePath"
    }
    $fullPath = [IO.Path]::GetFullPath((Join-Path $Root $RelativePath))
    $rootPrefix = $Root.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    # 关键安全边界：工作流验证只能修改 package 内的 Scene/Script，不接受越界路径。
    if (-not $fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Name escapes the package root: $RelativePath"
    }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "$Name does not exist: $RelativePath"
    }
    return $fullPath
}

function Wait-RuntimeWindow([Diagnostics.Process]$Process) {
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while ([DateTime]::UtcNow -lt $deadline -and -not $Process.HasExited) {
        $Process.Refresh()
        if ($Process.MainWindowHandle -ne [IntPtr]::Zero) { return $Process.MainWindowHandle }
        Start-Sleep -Milliseconds 100
    }
    throw "Runtime window was not ready"
}

function Send-RuntimeKey([IntPtr]$Window, [int]$VirtualKey) {
    if (-not [KadathWorkflowNative]::PostMessage($Window, 0x0100, [IntPtr]$VirtualKey, [IntPtr]::Zero)) {
        throw "WM_KEYDOWN failed for virtual key: $VirtualKey"
    }
    Start-Sleep -Milliseconds 50
    if (-not [KadathWorkflowNative]::PostMessage($Window, 0x0101, [IntPtr]$VirtualKey, [IntPtr]::Zero)) {
        throw "WM_KEYUP failed for virtual key: $VirtualKey"
    }
}

function Write-JsonDocument([object]$Document, [string]$Path) {
    $json = $Document | ConvertTo-Json -Depth 12
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $env:TEMP ("kadath-m4-workflow-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
if (Test-Path -LiteralPath $OutputDirectory) {
    throw "Output directory already exists; refusing to overwrite: $OutputDirectory"
}

$package = Resolve-ExistingDirectory $PackageRoot "Package root"
$output = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $output -Force | Out-Null
$exe = Resolve-PackageFile $package $ExecutableRelativePath "Runtime executable"
$scene = Resolve-PackageFile $package $SceneRelativePath "Scene document"
$script = Resolve-PackageFile $package $ScriptRelativePath "Script document"
$workingDirectory = [IO.Path]::GetDirectoryName($exe)
$sceneArgument = [IO.Path]::GetRelativePath($workingDirectory, $scene).Replace('\', '/')
$scriptArgument = [IO.Path]::GetRelativePath($workingDirectory, $script).Replace('\', '/')
$stderrPath = Join-Path $output 'runtime.stderr.log'
$stdoutPath = Join-Path $output 'runtime.stdout.log'
$originalScene = [IO.File]::ReadAllText($scene)
$originalScript = [IO.File]::ReadAllText($script)
$process = $null

try {
    $process = Start-Process -FilePath $exe -WorkingDirectory $workingDirectory -ArgumentList @('--scene', $sceneArgument, '--script', $scriptArgument) -RedirectStandardError $stderrPath -RedirectStandardOutput $stdoutPath -PassThru
    $window = Wait-RuntimeWindow $process
    Start-Sleep -Milliseconds 400

    # 有效 Scene 编辑：修改 Goal 后通过 F5 提交。
    $validScene = $originalScene | ConvertFrom-Json
    $validScene.goal.position = @(620.0, 210.0)
    Write-JsonDocument $validScene $scene
    Send-RuntimeKey $window 0x74
    Start-Sleep -Milliseconds 350

    # 非法 Scene 编辑：schema 失败必须保留旧 World。
    $invalidScene = $validScene | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $invalidScene.schemaVersion = 2
    Write-JsonDocument $invalidScene $scene
    Send-RuntimeKey $window 0x74
    Start-Sleep -Milliseconds 250
    [IO.File]::WriteAllText($scene, $originalScene, [Text.UTF8Encoding]::new($false))

    # 有效 Script 编辑：修改 on_start 和 fixed_update 后通过 F6 提交。
    $validScript = $originalScript | ConvertFrom-Json
    $validScript.instructions[0].value = @(620.0, 210.0)
    $validScript.instructions[1].value = @(18.0, 0.0)
    Write-JsonDocument $validScript $script
    Send-RuntimeKey $window 0x75
    Start-Sleep -Milliseconds 350

    # 非法 Script 编辑：schema 失败必须保留旧 Program。
    $invalidScript = $validScript | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $invalidScript.schemaVersion = 2
    Write-JsonDocument $invalidScript $script
    Send-RuntimeKey $window 0x75
    Start-Sleep -Milliseconds 300

    [IO.File]::WriteAllText($scene, $originalScene, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($script, $originalScript, [Text.UTF8Encoding]::new($false))
    if (-not [KadathWorkflowNative]::PostMessage($window, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)) {
        throw "WM_CLOSE failed"
    }
    if (-not $process.WaitForExit(10000)) { throw "Runtime close timed out" }

    $log = [IO.File]::ReadAllText($stderrPath)
    $required = @(
        'Scene reloaded explicitly',
        'Scene reload rejected; keeping current scene: UnsupportedSceneSchema',
        'Script reloaded explicitly',
        'Script reload rejected; keeping current program: UnsupportedScriptSchema',
        'Kadath runtime shutdown complete'
    )
    foreach ($entry in $required) {
        if (-not $log.Contains($entry)) { throw "Workflow log evidence missing: $entry" }
    }
    $onStartCount = @($log -split "`r?`n" | Where-Object { $_ -match 'Script on_start hook applied' }).Count
    if ($onStartCount -lt 3) { throw "Expected at least three on_start hooks, got $onStartCount" }
    if ($process.ExitCode -ne 0) { throw "Runtime exited with code $($process.ExitCode)" }

    Write-Output "output_directory=$output"
    Write-Output "runtime_exit_code=$($process.ExitCode)"
    Write-Output "script_on_start_count=$onStartCount"
    Write-Output "scene_reload=ok"
    Write-Output "script_reload=ok"
    Write-Output "scene_rollback=ok"
    Write-Output "script_rollback=ok"
    Write-Output "verification=ok"
} finally {
    # 关键恢复语义：无论 smoke 成功或失败，都恢复被编辑的输入文件。
    [IO.File]::WriteAllText($scene, $originalScene, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($script, $originalScript, [Text.UTF8Encoding]::new($false))
    if ($null -ne $process -and -not $process.HasExited) {
        $process.Kill($true)
        $process.WaitForExit()
    }
}
