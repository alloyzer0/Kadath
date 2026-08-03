[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ServiceDll,

    [Parameter(Mandatory = $true)]
    [string]$PackageRoot,

    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [string]$KadathRoot = (Join-Path $PSScriptRoot '..')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Send-Json([Diagnostics.Process]$Process, [object]$Value) {
    $Process.StandardInput.WriteLine(($Value | ConvertTo-Json -Compress -Depth 12))
    $Process.StandardInput.Flush()
}

function Read-Message([Diagnostics.Process]$Process) {
    $readTask = $Process.StandardOutput.ReadLineAsync()
    if (-not $readTask.Wait(20000)) { throw 'Timed out waiting for Editor Service output' }
    $line = $readTask.GetAwaiter().GetResult()
    if ($null -eq $line) {
        throw "Editor Service output ended unexpectedly with exit state $($Process.HasExited)"
    }
    $message = $line | ConvertFrom-Json
    Write-Verbose $line
    return $message
}

$service = $null
try {
    $servicePath = (Resolve-Path -LiteralPath $ServiceDll).Path
    $package = (Resolve-Path -LiteralPath $PackageRoot).Path
    $config = (Resolve-Path -LiteralPath $ConfigPath).Path
    $root = (Resolve-Path -LiteralPath $KadathRoot).Path

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'dotnet'
    $startInfo.WorkingDirectory = $root
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    [void]$startInfo.ArgumentList.Add($servicePath)
    [void]$startInfo.ArgumentList.Add('--kadath-root')
    [void]$startInfo.ArgumentList.Add($root)
    $service = [Diagnostics.Process]::new()
    $service.StartInfo = $startInfo
    if (-not $service.Start()) { throw 'Failed to start Editor Service' }

    $hello = Read-Message $service
    if ([string]$hello.type -cne 'hello' -or [string]$hello.protocol -cne 'kadath-editor-rpc') { throw 'Editor Service hello mismatch' }
    Send-Json $service ([ordered]@{ schemaVersion = 1; type = 'hello_ack'; client = 'verify-preview-control-transport'; clientVersion = '1' })

    Send-Json $service ([ordered]@{
        schemaVersion = 1
        type = 'request'
        id = 'preview-start-1'
        method = 'preview_start'
        params = [ordered]@{ configPath = $config; packageRoot = $package; pollIntervalMilliseconds = 50 }
    })

    $startResponse = $null
    $runtimeReady = $false
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while (($null -eq $startResponse -or -not $runtimeReady) -and [DateTime]::UtcNow -lt $deadline) {
        $message = Read-Message $service
        if ([string]$message.type -eq 'response' -and [string]$message.id -eq 'preview-start-1') { $startResponse = $message }
        if ([string]$message.type -eq 'event' -and [string]$message.event -eq 'preview_status' -and [string]$message.data.event -eq 'runtime_ready') { $runtimeReady = $true }
    }
    if ($null -eq $startResponse -or -not [bool]$startResponse.ok -or [string]$startResponse.result.state -cne 'starting') { throw 'preview_start response mismatch' }
    if (-not $runtimeReady) { throw 'Runtime did not publish runtime_ready through Editor Service' }

    Send-Json $service ([ordered]@{ schemaVersion = 1; type = 'request'; id = 'preview-stop-1'; method = 'preview_stop'; params = $null })
    $stopResponse = $null
    $stoppedEvent = $null
    $shutdownCompleted = $false
    $controlStopping = $false
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while (($null -eq $stopResponse -or $null -eq $stoppedEvent -or -not $shutdownCompleted -or -not $controlStopping) -and [DateTime]::UtcNow -lt $deadline) {
        $message = Read-Message $service
        if ([string]$message.type -eq 'response' -and [string]$message.id -eq 'preview-stop-1') { $stopResponse = $message }
        if ([string]$message.type -eq 'event' -and [string]$message.event -eq 'preview_stopped') { $stoppedEvent = $message }
        if ([string]$message.type -eq 'event' -and [string]$message.event -eq 'preview_status') {
            if ([string]$message.data.event -eq 'command_completed' -and [string]$message.data.command -eq 'shutdown' -and [string]$message.data.result -eq 'succeeded') { $shutdownCompleted = $true }
            if ([string]$message.data.event -eq 'runtime_stopping' -and [string]$message.data.reason -eq 'control_shutdown') { $controlStopping = $true }
        }
    }
    if ($null -eq $stopResponse -or -not [bool]$stopResponse.ok -or [string]$stopResponse.result.state -cne 'stopped') { throw 'preview_stop response mismatch' }
    if ($null -eq $stoppedEvent -or -not [bool]$stoppedEvent.data.requested -or [int]$stoppedEvent.data.exitCode -ne 0) { throw 'preview_stopped lifecycle mismatch' }
    if (-not $shutdownCompleted -or -not $controlStopping) { throw 'Runtime structured shutdown evidence missing' }

    Send-Json $service ([ordered]@{ schemaVersion = 1; type = 'request'; id = 'shutdown-1'; method = 'shutdown'; params = $null })
    $shutdownResponse = $null
    while ($null -eq $shutdownResponse) {
        $message = Read-Message $service
        if ([string]$message.type -eq 'response' -and [string]$message.id -eq 'shutdown-1') { $shutdownResponse = $message }
    }
    if (-not [bool]$shutdownResponse.ok) { throw 'Editor Service shutdown failed' }
    $service.StandardInput.Close()
    if (-not $service.WaitForExit(10000) -or $service.ExitCode -ne 0) { throw 'Editor Service did not exit cleanly' }

    Write-Output 'runtime_ready=ok'
    Write-Output 'service_preview_stop=ok'
    Write-Output 'runtime_shutdown_completion=ok'
    Write-Output 'runtime_stopping_reason=control_shutdown'
    Write-Output 'runtime_exit_code=0'
    Write-Output 'verification=ok'
} finally {
    if ($null -ne $service -and -not $service.HasExited) {
        try { $service.Kill($true); $service.WaitForExit() } catch { }
    }
    if ($null -ne $service) { $service.Dispose() }
}
