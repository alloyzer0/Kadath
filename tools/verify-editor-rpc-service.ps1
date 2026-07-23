[CmdletBinding()]
param(
    [string]$EditorRoot = (Join-Path $PSScriptRoot '..\editor')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$editor = (Resolve-Path -LiteralPath $EditorRoot).Path
$serviceDll = Join-Path $editor 'Kadath.Editor.Service\bin\Debug\net8.0\Kadath.Editor.Service.dll'
$kadathRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
if (-not (Test-Path -LiteralPath $serviceDll -PathType Leaf)) { throw "Editor Service is not built: $serviceDll" }

$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = 'dotnet'
$startInfo.WorkingDirectory = $editor
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.RedirectStandardInput = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
[void]$startInfo.ArgumentList.Add($serviceDll)
[void]$startInfo.ArgumentList.Add('--kadath-root')
[void]$startInfo.ArgumentList.Add($kadathRoot)
$process = [Diagnostics.Process]::new()
$process.StartInfo = $startInfo

function Read-LineWithTimeout([Diagnostics.Process]$Process, [int]$TimeoutMs = 5000) {
    $task = $Process.StandardOutput.ReadLineAsync()
    if (-not $task.Wait($TimeoutMs)) { throw 'Editor Service did not emit a JSONL line before timeout' }
    $line = $task.GetAwaiter().GetResult()
    if ($null -eq $line) { throw 'Editor Service closed stdout unexpectedly' }
    return ($line | ConvertFrom-Json)
}

function Send-Json([Diagnostics.Process]$Process, [object]$Value) {
    $Process.StandardInput.WriteLine(($Value | ConvertTo-Json -Compress -Depth 12))
    $Process.StandardInput.Flush()
}

try {
    if (-not $process.Start()) { throw 'Failed to start Editor Service' }
    $hello = Read-LineWithTimeout $process
    if ([int]$hello.schemaVersion -ne 1 -or [string]$hello.type -ne 'hello' -or [string]$hello.protocol -ne 'kadath-editor-rpc') { throw 'Editor Service hello contract mismatch' }
    if (@($hello.transports) -notcontains 'stdio-jsonl') { throw 'Editor Service did not advertise stdio-jsonl' }

    Send-Json $process ([ordered]@{ schemaVersion = 1; type = 'hello_ack'; client = 'verify-editor-rpc-service'; clientVersion = '1' })
    Send-Json $process ([ordered]@{ schemaVersion = 1; type = 'request'; id = 'capabilities-1'; method = 'get_capabilities'; params = $null })
    $capabilities = Read-LineWithTimeout $process
    if ([string]$capabilities.type -ne 'response' -or -not [bool]$capabilities.ok -or [string]$capabilities.id -ne 'capabilities-1') { throw 'Capabilities response correlation failed' }
    $surfaces = @($capabilities.result.previewSurfaces)
    $external = @($surfaces | Where-Object { $_.mode -eq 'external-window' })
    $shared = @($surfaces | Where-Object { $_.mode -eq 'shared-texture' })
    $stream = @($surfaces | Where-Object { $_.mode -eq 'frame-stream' })
    if ($external.Count -ne 1 -or -not [bool]$external[0].implemented) { throw 'External-window surface was not advertised as implemented' }
    if ($shared.Count -ne 1 -or [bool]$shared[0].implemented -or $stream.Count -ne 1 -or [bool]$stream[0].implemented) { throw 'Unimplemented pixel transports were advertised as active' }

    Send-Json $process ([ordered]@{ schemaVersion = 1; type = 'request'; id = 'unknown-1'; method = 'not_a_command'; params = $null })
    $unknown = Read-LineWithTimeout $process
    if ([bool]$unknown.ok -or [string]$unknown.error.code -ne 'unknown_method') { throw 'Unknown method error contract mismatch' }

    Send-Json $process ([ordered]@{ schemaVersion = 1; type = 'request'; id = 'shutdown-1'; method = 'shutdown'; params = $null })
    $shutdown = Read-LineWithTimeout $process
    if (-not [bool]$shutdown.ok -or [string]$shutdown.id -ne 'shutdown-1') { throw 'Shutdown response contract mismatch' }
    $stopping = Read-LineWithTimeout $process
    if ([string]$stopping.event -ne 'service_stopping' -or [string]$stopping.type -ne 'event') { throw 'Service stopping event contract mismatch' }
    $process.WaitForExit(5000) | Out-Null
    if (-not $process.HasExited) { throw 'Editor Service did not exit after shutdown' }

    Write-Output 'editor_rpc_protocol=ok'
    Write-Output 'stdio_transport=ok'
    Write-Output 'external_window_surface=ok'
    Write-Output 'pixel_frames_not_sent_over_rpc=ok'
    Write-Output 'future_surface_capabilities=ok'
    Write-Output 'shutdown=ok'
    Write-Output 'verification=ok'
} finally {
    if ($null -ne $process -and -not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
    if ($null -ne $process) { $process.Dispose() }
}
