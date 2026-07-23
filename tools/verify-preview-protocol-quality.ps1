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
    if (-not $fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "$Name escapes package root" }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "$Name does not exist: $RelativePath" }
    return $fullPath
}

function Write-JsonDocument([object]$Document, [string]$Path) {
    [IO.File]::WriteAllText($Path, ($Document | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
}

function Assert-Property([object]$Document, [string]$Name, [string]$Context) {
    if ($null -eq $Document.PSObject.Properties[$Name]) { throw "$Context is missing $Name" }
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $PSScriptRoot 'editor-preview.authoring.example.json' }
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path $env:TEMP ("kadath-p3-preview-protocol-" + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
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
    # 关键质量门：等待 Runtime ready 后串行注入成功/拒绝变更，保证生命周期证据可归因。
    $arguments = @('-NoProfile', '-File', $previewScript, '-ConfigPath', $config, '-PackageRoot', $package, '-StructuredStatus', '-WatchChanges', '-PollIntervalMilliseconds', '50', '-DebounceMilliseconds', '200', '-StopAfterMilliseconds', '12000')
    $process = Start-Process -FilePath 'pwsh' -ArgumentList $arguments -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
    Start-Sleep -Milliseconds 3500
    if ($process.HasExited) { throw 'Preview exited before protocol quality edits started' }

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
    $runtimeEvents = @($events | Where-Object { $null -eq $_.PSObject.Properties['origin'] -or $_.origin -ne 'launcher' })
    $runtimeReady = @($runtimeEvents | Where-Object { $_.event -eq 'runtime_ready' })
    $runtimeStopping = @($runtimeEvents | Where-Object { $_.event -eq 'runtime_stopping' })
    $received = @($runtimeEvents | Where-Object { $_.event -eq 'command_received' })
    $completed = @($runtimeEvents | Where-Object { $_.event -eq 'command_completed' })
    $responses = @($events | Where-Object { $_.event -eq 'command_response' })
    if ($runtimeReady.Count -ne 1) { throw "Expected one runtime_ready, got $($runtimeReady.Count)" }
    if ($runtimeStopping.Count -ne 1) { throw "Expected one runtime_stopping, got $($runtimeStopping.Count)" }
    if ($received.Count -ne 4 -or $completed.Count -ne 4 -or $responses.Count -ne 4) { throw "Expected 4 received/completed/responses, got $($received.Count)/$($completed.Count)/$($responses.Count)" }

    $lastSequence = [uint64]0
    foreach ($event in $runtimeEvents) {
        Assert-Property $event 'schemaVersion' 'Runtime event'
        Assert-Property $event 'sequence' 'Runtime event'
        if ([uint64]$event.schemaVersion -ne 1) { throw "Unexpected schemaVersion: $($event.schemaVersion)" }
        $sequence = [uint64]$event.sequence
        if ($sequence -le $lastSequence) { throw "Runtime sequence is not strictly increasing: $sequence after $lastSequence" }
        $lastSequence = $sequence
    }
    if ([uint64]$runtimeReady[0].sequence -ge [uint64]$received[0].sequence) { throw 'runtime_ready must precede command_received' }
    if ([uint64]$runtimeStopping[0].sequence -le [uint64]$completed[-1].sequence) { throw 'runtime_stopping must follow command_completed' }

    $receivedById = @{}
    foreach ($event in $received) {
        Assert-Property $event 'requestId' 'command_received'
        $id = [uint64]$event.requestId
        if ($id -eq 0 -or $receivedById.ContainsKey([string]$id)) { throw "requestId must be positive and unique: $id" }
        $receivedById[[string]$id] = $event
    }
    foreach ($event in $completed) {
        Assert-Property $event 'requestId' 'command_completed'
        $id = [uint64]$event.requestId
        if (-not $receivedById.ContainsKey([string]$id)) { throw "Completion has no received requestId: $id" }
        if ([string]$receivedById[[string]$id].command -ne [string]$event.command) { throw "Command changed for requestId: $id" }
        if (@($completed | Where-Object { [uint64]$_.requestId -eq $id }).Count -ne 1) { throw "Request completed more than once: $id" }
        if ([string]$event.result -eq 'rejected') { Assert-Property $event 'errorCode' 'Rejected command' }
    }
    foreach ($response in $responses) {
        $responseId = [uint64]$response.requestId
        if (-not $receivedById.ContainsKey([string]$responseId)) { throw "Launcher response has no requestId: $responseId" }
    }
    if (@($completed | Where-Object { $_.result -eq 'succeeded' }).Count -ne 2) { throw 'Expected two succeeded completions' }
    if (@($completed | Where-Object { $_.result -eq 'rejected' }).Count -ne 2) { throw 'Expected two rejected completions' }
    if (@($completed | Where-Object { $null -ne $_.PSObject.Properties['errorCode'] -and $_.errorCode -eq 'UnsupportedSceneSchema' }).Count -ne 1) { throw 'Scene rejection error code missing' }
    if (@($completed | Where-Object { $null -ne $_.PSObject.Properties['errorCode'] -and $_.errorCode -eq 'UnsupportedScriptSchema' }).Count -ne 1) { throw 'Script rejection error code missing' }
    if ($process.ExitCode -ne 0) { throw "Runtime exited with code $($process.ExitCode)" }

    Write-Output "output_directory=$output"
    Write-Output "runtime_exit_code=$($process.ExitCode)"
    Write-Output "runtime_events=$($runtimeEvents.Count)"
    Write-Output "received=$($received.Count)"
    Write-Output "completed=$($completed.Count)"
    Write-Output 'sequence=strictly_increasing'
    Write-Output 'lifecycle=exactly_once'
    Write-Output 'mutation_rejection=ok'
    Write-Output 'verification=ok'
} finally {
    [IO.File]::WriteAllText($scene, $originalScene, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($script, $originalScript, [Text.UTF8Encoding]::new($false))
    if ($null -ne $process -and -not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
}
