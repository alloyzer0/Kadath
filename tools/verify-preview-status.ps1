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
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "$Name does not exist: $Path" }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Resolve-PackageFile([string]$Root, [string]$RelativePath, [string]$Name) {
    if ([IO.Path]::IsPathRooted($RelativePath)) { throw "$Name must be relative to package root" }
    $fullPath = [IO.Path]::GetFullPath((Join-Path $Root $RelativePath))
    $prefix = $Root.TrimEnd('\') + '\'
    # 关键安全边界：协议 smoke 只允许修改隔离分发包内的 Scene/Script。
    if (-not $fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "$Name escapes package root" }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "$Name does not exist: $RelativePath" }
    return $fullPath
}

function Write-JsonDocument([object]$Document, [string]$Path) {
    [IO.File]::WriteAllText($Path, ($Document | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $PSScriptRoot 'editor-preview.authoring.example.json' }
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path $env:TEMP ("kadath-m4-08-status-" + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
if (Test-Path -LiteralPath $OutputDirectory) { throw "Output directory already exists: $OutputDirectory" }

$package = Resolve-ExistingDirectory $PackageRoot 'Package root'
$config = (Resolve-Path -LiteralPath $ConfigPath).Path
$scene = Resolve-PackageFile $package 'bin/assets/scenes/preview.scene.json' 'Scene document'
$script = Resolve-PackageFile $package 'bin/assets/scripts/preview.script.json' 'Script document'
$output = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $output -Force | Out-Null
$stdoutPath = Join-Path $output 'preview.stdout.jsonl'
$stderrPath = Join-Path $output 'preview.stderr.log'
$previewScript = Join-Path $PSScriptRoot 'editor-preview.ps1'
$originalScene = [IO.File]::ReadAllText($scene)
$originalScript = [IO.File]::ReadAllText($script)
$process = $null

try {
    $arguments = @('-NoProfile', '-File', $previewScript, '-ConfigPath', $config, '-PackageRoot', $package, '-StructuredStatus', '-WatchChanges', '-PollIntervalMilliseconds', '50', '-DebounceMilliseconds', '200', '-StopAfterMilliseconds', '12000')
    $process = Start-Process -FilePath 'pwsh' -ArgumentList $arguments -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
    Start-Sleep -Milliseconds 3500
    if ($process.HasExited) { throw 'Preview exited before protocol edits started' }

    $sceneDocument = $originalScene | ConvertFrom-Json
    $sceneDocument.goal.position = @(617.0, 217.0)
    Write-JsonDocument $sceneDocument $scene
    Start-Sleep -Milliseconds 900
    $invalidScene = $sceneDocument | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $invalidScene.schemaVersion = 2
    Write-JsonDocument $invalidScene $scene
    Start-Sleep -Milliseconds 900

    $scriptDocument = $originalScript | ConvertFrom-Json
    $scriptDocument.instructions[0].value = @(617.0, 217.0)
    Write-JsonDocument $scriptDocument $script
    Start-Sleep -Milliseconds 900
    $invalidScript = $scriptDocument | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $invalidScript.schemaVersion = 2
    Write-JsonDocument $invalidScript $script

    if (-not $process.WaitForExit(15000)) { throw 'Preview did not exit after StopAfterMilliseconds' }
    $lines = @(Get-Content -LiteralPath $stdoutPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $events = @($lines | ForEach-Object { try { $_ | ConvertFrom-Json } catch { throw "Invalid JSONL output: $_" } })
    $responses = @($events | Where-Object { $_.event -eq 'command_response' })
    $requested = @($events | Where-Object { $_.event -eq 'command_requested' })
    $runtimeReady = @($events | Where-Object { $_.event -eq 'runtime_ready' })
    $runtimeStopping = @($events | Where-Object { $_.event -eq 'runtime_stopping' })
    if ($runtimeReady.Count -ne 1) { throw "Expected one runtime_ready event, got $($runtimeReady.Count)" }
    if ($runtimeStopping.Count -ne 1) { throw "Expected one runtime_stopping event, got $($runtimeStopping.Count)" }
    if ($requested.Count -ne 4 -or $responses.Count -ne 4) { throw "Expected four requested/responses, got $($requested.Count)/$($responses.Count)" }
    if (($responses | Where-Object { $_.result -eq 'succeeded' }).Count -ne 2) { throw 'Expected two successful reload responses' }
    if (($responses | Where-Object { $_.result -eq 'rejected' }).Count -ne 2) { throw 'Expected two rejected reload responses' }
    if (($responses | Where-Object { $null -ne $_.PSObject.Properties['errorCode'] -and $_.errorCode -eq 'UnsupportedSceneSchema' }).Count -ne 1) { throw 'Scene schema rejection evidence missing' }
    if (($responses | Where-Object { $null -ne $_.PSObject.Properties['errorCode'] -and $_.errorCode -eq 'UnsupportedScriptSchema' }).Count -ne 1) { throw 'Script schema rejection evidence missing' }
    $requestIds = @($requested | ForEach-Object { [uint64]$_.requestId })
    foreach ($response in $responses) {
        if ($requestIds -notcontains ([uint64]$response.requestId)) { throw "Response requestId was not requested: $($response.requestId)" }
    }
    $launcherEvents = @($events | Where-Object { $null -ne $_.PSObject.Properties['origin'] -and $_.origin -eq 'launcher' })
    $launcherSequences = @($launcherEvents | ForEach-Object { [uint64]$_.sequence })
    if (($launcherSequences | Sort-Object -Unique).Count -ne $launcherSequences.Count) { throw 'Launcher sequence was not unique' }
    if ($process.ExitCode -ne 0) { throw "Runtime exited with code $($process.ExitCode)" }

    Write-Output "output_directory=$output"
    Write-Output "runtime_exit_code=$($process.ExitCode)"
    Write-Output "requested=$($requested.Count)"
    Write-Output "responses=$($responses.Count)"
    Write-Output "succeeded=$(($responses | Where-Object { $_.result -eq 'succeeded' }).Count)"
    Write-Output "rejected=$(($responses | Where-Object { $_.result -eq 'rejected' }).Count)"
    Write-Output 'request_id_correlation=ok'
    Write-Output 'jsonl=ok'
    Write-Output 'verification=ok'
} finally {
    # 无论验证成功或失败，都恢复被模拟编辑的输入文件。
    [IO.File]::WriteAllText($scene, $originalScene, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($script, $originalScript, [Text.UTF8Encoding]::new($false))
    if ($null -ne $process -and -not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
}