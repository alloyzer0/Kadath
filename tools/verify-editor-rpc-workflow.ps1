[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackageRoot,

    [string]$ProjectName = "codex_rpc_workflow_$PID"
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = (Resolve-Path -LiteralPath $PackageRoot).Path
$editorRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\editor')).Path
$serviceDll = Join-Path $editorRoot 'Kadath.Editor.Service\bin\Debug\net8.0\Kadath.Editor.Service.dll'
$author = Join-Path $PSScriptRoot 'editor-author.ps1'
if (-not (Test-Path -LiteralPath $serviceDll -PathType Leaf)) { throw "Editor Service is not built: $serviceDll" }

$projectDirectory = Join-Path $root "bin\projects\$ProjectName"
$scenePath = Join-Path $projectDirectory 'scene.json'
$sourceBeforeInvalid = $null
$process = $null
$sequence = 0L
$stage = 'startup'
$messages = [System.Collections.Generic.List[object]]::new()

function Send-Json([Diagnostics.Process]$Process, [object]$Value) {
    $Process.StandardInput.WriteLine(($Value | ConvertTo-Json -Compress -Depth 12))
    $Process.StandardInput.Flush()
}

function Read-Message([Diagnostics.Process]$Process, [int]$TimeoutMs = 15000) {
    $task = $Process.StandardOutput.ReadLineAsync()
    if (-not $task.Wait($TimeoutMs)) { $recent = ($script:messages | Select-Object -Last 8 | ConvertTo-Json -Compress -Depth 4); throw "Editor Service did not emit a JSONL message before timeout: stage=$script:stage exited=$($Process.HasExited) recent=$recent" }
    $line = $task.GetAwaiter().GetResult()
    if ($null -eq $line) { throw 'Editor Service closed stdout unexpectedly' }
    $message = $line | ConvertFrom-Json
    $script:messages.Add($message)
    if ($message.type -eq 'event') {
        if ([int64]$message.sequence -le $script:sequence) { throw 'Editor Service event sequence is not strictly increasing' }
        $script:sequence = [int64]$message.sequence
    }
    return $message
}

function Read-Response([Diagnostics.Process]$Process, [string]$Id) {
    while ($true) {
        $message = Read-Message $Process
        if ($message.type -eq 'response' -and [string]$message.id -eq $Id) { return $message }
    }
}

function Read-Event([Diagnostics.Process]$Process, [string]$Name) {
    while ($true) {
        $message = Read-Message $Process
        if ($message.type -eq 'event' -and [string]$message.event -eq $Name) { return $message }
    }
}

try {
    if (Test-Path -LiteralPath $projectDirectory) { throw "Verifier project already exists: $ProjectName" }
    & pwsh -NoProfile -File $author -Action Create -PackageRoot $root -ProjectName $ProjectName | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to create RPC workflow project' }
    $sourceBeforeInvalid = [IO.File]::ReadAllText($scenePath)

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'dotnet'
    $startInfo.WorkingDirectory = $editorRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    [void]$startInfo.ArgumentList.Add($serviceDll)
    [void]$startInfo.ArgumentList.Add('--kadath-root')
    [void]$startInfo.ArgumentList.Add((Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path)
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw 'Failed to start Editor Service' }

    $hello = Read-Message $process
    if ([string]$hello.type -ne 'hello' -or [string]$hello.protocol -ne 'kadath-editor-rpc') { throw 'RPC hello mismatch' }
    Send-Json $process ([ordered]@{ schemaVersion = 1; type = 'hello_ack'; client = 'verify-editor-rpc-workflow'; clientVersion = '1' })

    $script:stage = 'capabilities'
    Send-Json $process ([ordered]@{ schemaVersion = 1; type = 'request'; id = 'caps-1'; method = 'get_capabilities'; params = $null })
    $caps = Read-Response $process 'caps-1'
    foreach ($command in @('project_open', 'project_validate', 'bake_start', 'watch_start', 'watch_stop', 'preview_start', 'preview_stop')) {
        if (@($caps.result.commands) -notcontains $command) { throw "Capability command missing: $command" }
    }

    $script:stage = 'project_open'
    Send-Json $process ([ordered]@{ schemaVersion = 1; type = 'request'; id = 'open-1'; method = 'project_open'; params = [ordered]@{ packageRoot = $root; projectName = $ProjectName } })
    $openedEvent = Read-Event $process 'project_opened'
    if ([string]$openedEvent.requestId -ne 'open-1') { throw 'project_opened request correlation failed' }
    $opened = Read-Response $process 'open-1'
    if (-not [bool]$opened.ok -or [string]$opened.result.projectName -ne $ProjectName) { throw 'project_open response mismatch' }

    $script:stage = 'project_validate'
    Send-Json $process ([ordered]@{ schemaVersion = 1; type = 'request'; id = 'validate-1'; method = 'project_validate'; params = [ordered]@{} })
    $validatedEvent = Read-Event $process 'project_validated'
    $validated = Read-Response $process 'validate-1'
    if (-not [bool]$validated.ok -or [string]$validated.result.state -ne 'valid' -or [string]$validatedEvent.requestId -ne 'validate-1') { throw 'project_validate contract mismatch' }

    $script:stage = 'bake_start'
    Send-Json $process ([ordered]@{ schemaVersion = 1; type = 'request'; id = 'bake-1'; method = 'bake_start'; params = [ordered]@{ target = 'Both'; profile = 'debug' } })
    [void](Read-Event $process 'bake_started')
    [void](Read-Event $process 'bake_completed')
    $baked = Read-Response $process 'bake-1'
    if (-not [bool]$baked.ok -or [string]$baked.result.state -ne 'succeeded' -or [int]$baked.result.sceneArtifactBytes -ne 128) { throw 'bake_start contract mismatch' }

    $script:stage = 'watch_start'
    Send-Json $process ([ordered]@{ schemaVersion = 1; type = 'request'; id = 'watch-1'; method = 'watch_start'; params = [ordered]@{ target = 'Scene'; profile = 'debug'; pollIntervalMilliseconds = 50; debounceMilliseconds = 100 } })
    [void](Read-Event $process 'watch_started')
    $watch = Read-Response $process 'watch-1'
    if (-not [bool]$watch.ok -or [string]$watch.result.state -ne 'watching') { throw 'watch_start contract mismatch' }

    $script:stage = 'watch_update'
    & pwsh -NoProfile -File $author -Action Update -PackageRoot $root -ProjectName $ProjectName -SceneGoalX 641 -SceneGoalY 241 | Out-Null
    if($LASTEXITCODE -ne 0){ throw 'Failed to update Scene source for watch verification' }
    [void](Read-Event $process 'source_change_detected')
    [void](Read-Event $process 'bake_started')
    [void](Read-Event $process 'bake_completed')

    [IO.File]::WriteAllText($scenePath, '{', [Text.UTF8Encoding]::new($false))
    $failed = Read-Event $process 'bake_failed'
    if ([string]$failed.data.errorCode -ne 'bake_validation_failed' -or -not [bool]$failed.data.retainedArtifact) { throw 'watch failure retention contract mismatch' }
    [IO.File]::WriteAllText($scenePath, $sourceBeforeInvalid, [Text.UTF8Encoding]::new($false))
    [void](Read-Event $process 'source_change_detected')
    [void](Read-Event $process 'bake_started')
    [void](Read-Event $process 'bake_completed')

    $script:stage = 'watch_stop'
    Send-Json $process ([ordered]@{ schemaVersion = 1; type = 'request'; id = 'watch-stop-1'; method = 'watch_stop'; params = $null })
    $watchStopped = Read-Response $process 'watch-stop-1'
    if (-not [bool]$watchStopped.ok -or [string]$watchStopped.result.state -ne 'stopped') { throw 'watch_stop contract mismatch' }

    $script:stage = 'preview_start'
    Send-Json $process ([ordered]@{ schemaVersion = 1; type = 'request'; id = 'preview-1'; method = 'preview_start'; params = [ordered]@{ projectName = $ProjectName; liveBake = $true; stopAfterMilliseconds = 2500 } })
    $surface = Read-Event $process 'preview_surface_created'
    $preview = Read-Response $process 'preview-1'
    if (-not [bool]$preview.ok -or [string]$surface.data.mode -ne 'external-window' -or [string]$surface.data.windowClass -ne 'KadathRuntimeWindow') { throw 'preview external-window contract mismatch' }
    [void](Read-Event $process 'preview_stopped')

    $script:stage = 'shutdown'
    Send-Json $process ([ordered]@{ schemaVersion = 1; type = 'request'; id = 'shutdown-1'; method = 'shutdown'; params = $null })
    [void](Read-Response $process 'shutdown-1')
    [void](Read-Event $process 'service_stopping')
    $process.WaitForExit(10000) | Out-Null
    if (-not $process.HasExited) { throw 'Editor Service did not exit after shutdown' }

    Write-Output 'editor_rpc_workflow=ok'
    Write-Output 'project_open_validate=ok'
    Write-Output 'bake_start=ok'
    Write-Output 'watch_incremental_bake=ok'
    Write-Output 'watch_failure_retention=ok'
    Write-Output 'preview_external_window=ok'
    Write-Output 'verification=ok'
}
finally {
    if ($null -ne $process -and -not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
    if (Test-Path -LiteralPath $projectDirectory) { Remove-Item -LiteralPath $projectDirectory -Recurse -Force }
}
