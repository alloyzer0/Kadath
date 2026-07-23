[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackageRoot,

    [string]$ConfigPath,

    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest


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
    # 关键边界：自动 reload 验证只允许修改隔离 package 内的输入文档。
    if (-not $fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Name escapes the package root: $RelativePath"
    }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "$Name does not exist: $RelativePath"
    }
    return $fullPath
}


function Write-JsonDocument([object]$Document, [string]$Path) {
    # 直接写入只用于模拟编辑器保存；watcher 必须等待内容稳定后再发命令。
    $json = $Document | ConvertTo-Json -Depth 12
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $env:TEMP ("kadath-m4-07-auto-reload-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
if (Test-Path -LiteralPath $OutputDirectory) {
    throw "Output directory already exists; refusing to overwrite: $OutputDirectory"
}

$package = Resolve-ExistingDirectory $PackageRoot 'Package root'
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot 'editor-preview.authoring.example.json'
}
$config = (Resolve-Path -LiteralPath $ConfigPath).Path
$scene = Resolve-PackageFile $package 'bin/assets/scenes/preview.scene.json' 'Scene document'
$script = Resolve-PackageFile $package 'bin/assets/scripts/preview.script.json' 'Script document'
$output = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $output -Force | Out-Null
$stdoutPath = Join-Path $output 'launcher.stdout.log'
$stderrPath = Join-Path $output 'launcher.stderr.log'
$previewScript = Join-Path $PSScriptRoot 'editor-preview.ps1'
$originalScene = [IO.File]::ReadAllText($scene)
$originalScript = [IO.File]::ReadAllText($script)
$process = $null

try {
    $arguments = @(
        '-NoProfile', '-File', $previewScript,
        '-ConfigPath', $config,
        '-PackageRoot', $package,
        '-WatchChanges',
        '-PollIntervalMilliseconds', '50',
        '-DebounceMilliseconds', '250',
        '-StopAfterMilliseconds', '7000'
    )
    $process = Start-Process -FilePath 'pwsh' -ArgumentList $arguments -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
    Start-Sleep -Milliseconds 1200
    if ($process.HasExited) { throw 'Preview launcher exited before watcher verification started' }
    Start-Sleep -Milliseconds 1000

    $transientScene = $originalScene | ConvertFrom-Json
    $transientScene.goal.position = @(612.0, 212.0)
    Write-JsonDocument $transientScene $scene
    Start-Sleep -Milliseconds 80
    # debounce 窗口内恢复启动内容属于净零变化，不应产生自动 reload。
    [IO.File]::WriteAllText($scene, $originalScene, [Text.UTF8Encoding]::new($false))
    Start-Sleep -Milliseconds 500

    $sceneDocument = $originalScene | ConvertFrom-Json
    $sceneDocument.goal.position = @(611.0, 211.0)
    Write-JsonDocument $sceneDocument $scene
    Start-Sleep -Milliseconds 600

    $scriptDocument = $originalScript | ConvertFrom-Json
    $scriptDocument.instructions[0].value = @(611.0, 211.0)
    Write-JsonDocument $scriptDocument $script
    Start-Sleep -Milliseconds 80
    # 第二次保存发生在 debounce 窗口内，必须与第一次 Script 保存合并为一个 reload。
    $scriptDocument.instructions[1].value = @(21.0, 0.0)
    Write-JsonDocument $scriptDocument $script
    Start-Sleep -Milliseconds 700

    $invalidScript = $scriptDocument | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $invalidScript.schemaVersion = 2
    Write-JsonDocument $invalidScript $script
    if (-not $process.WaitForExit(12000)) {
        throw 'Preview process did not exit after StopAfterMilliseconds'
    }

    $log = [IO.File]::ReadAllText($stdoutPath)
    $sceneRequests = @($log -split "`r?`n" | Where-Object { $_ -eq 'scene_reload_requested=auto' }).Count
    $scriptRequests = @($log -split "`r?`n" | Where-Object { $_ -eq 'script_reload_requested=auto' }).Count
    $sceneChanges = @($log -split "`r?`n" | Where-Object { $_ -eq 'scene_change_detected=1' }).Count
    $scriptChanges = @($log -split "`r?`n" | Where-Object { $_ -eq 'script_change_detected=1' }).Count
    if ($sceneRequests -ne 1) { throw "Expected one automatic Scene reload, got $sceneRequests" }
    if ($scriptRequests -ne 2) { throw "Expected one debounced valid and one invalid Script reload, got $scriptRequests" }
    if ($sceneChanges -lt 1 -or $scriptChanges -lt 2) { throw 'Expected Scene and Script change evidence was missing' }
    if ($process.ExitCode -ne 0) { throw "Runtime exited with code $($process.ExitCode)" }

    Write-Output "output_directory=$output"
    Write-Output "runtime_exit_code=$($process.ExitCode)"
    Write-Output "scene_change_events=$sceneChanges"
    Write-Output "scene_auto_reload=$sceneRequests"
    Write-Output "script_change_events=$scriptChanges"
    Write-Output "script_auto_reload=$scriptRequests"
    Write-Output 'debounce=ok'
    Write-Output 'verification=ok'
} finally {
    # 关键恢复语义：无论 smoke 成功或失败，都恢复被模拟编辑的输入文件。
    [IO.File]::WriteAllText($scene, $originalScene, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($script, $originalScript, [Text.UTF8Encoding]::new($false))
    if ($null -ne $process -and -not $process.HasExited) {
        $process.Kill($true)
        $process.WaitForExit()
    }
}