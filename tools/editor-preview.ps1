[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $true)]
    [string]$PackageRoot,

    [ValidateRange(0, 300000)]
    [int]$StopAfterMilliseconds = 0,

    [ValidateRange(0, 300000)]
    [int]$ReloadScriptAfterMilliseconds = 0,

    [switch]$WatchChanges,

    [ValidateRange(25, 2000)]
    [int]$PollIntervalMilliseconds = 100,

    [ValidateRange(50, 5000)]
    [int]$DebounceMilliseconds = 250,

    [switch]$StructuredStatus,

    # Live Bake v1 显式开启，保持旧 JSON watcher/Runtime reload 工作流兼容。
    [switch]$LiveBake,

    [ValidateSet('debug', 'release')]
    [string]$BakeProfile = 'debug',

    [string]$DerivedDirectory = ''
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class KadathPreviewNative {
    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int GetClassName(IntPtr hWnd, StringBuilder className, int maxCount);

    public static IntPtr FindRuntimeWindow(int processId) {
        IntPtr result = IntPtr.Zero;
        EnumWindows(delegate(IntPtr window, IntPtr _) {
            uint owner;
            GetWindowThreadProcessId(window, out owner);
            if (owner != (uint)processId) return true;
            StringBuilder className = new StringBuilder(256);
            if (GetClassName(window, className, className.Capacity) > 0 &&
                className.ToString() == "KadathRuntimeWindow") {
                result = window;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return result;
    }
}
"@

$script:structuredStatus = [bool]$StructuredStatus
$script:runtimeStdoutTask = $null
$script:runtimeStderrTask = $null
$script:pendingRequests = @{}
# 每个 target 独立维护 latest/acknowledged，避免 Scene 与 Script 的响应互相污染。
$script:reloadTargets = @{
    Scene = [pscustomobject]@{
        LatestRequestId = [uint64]0
        LatestRequestedSourceRevision = $null
        AcknowledgedSourceRevision = $null
        AcknowledgedArtifactRevision = $null
        FailedSourceRevision = $null
    }
    Script = [pscustomobject]@{
        LatestRequestId = [uint64]0
        LatestRequestedSourceRevision = $null
        AcknowledgedSourceRevision = $null
        AcknowledgedArtifactRevision = $null
        FailedSourceRevision = $null
    }
}
$script:nextRequestId = [uint64]1
$script:launcherSequence = [uint64]0
$script:liveBakeEnabled = [bool]$LiveBake
$script:liveBakeScript = Join-Path $PSScriptRoot 'editor-live-bake.ps1'
$script:liveBakeSources = @{}
$script:liveBakeArtifacts = @{}
$script:liveBakeManifest = $null
$script:initialLoadTerminalEmitted = $false

function Write-StructuredEvent([object]$Event) {
    $script:launcherSequence++
    $Event['schemaVersion'] = 1
    $Event['origin'] = 'launcher'
    $Event['sequence'] = $script:launcherSequence
    Write-Output ($Event | ConvertTo-Json -Compress -Depth 10)
}

function Write-PreviewOutput([string]$Line) {
    if (-not $script:structuredStatus) { Write-Output $Line; return }
    $parts = $Line -split '=', 2
    if ($parts.Count -eq 2) {
        Write-StructuredEvent ([ordered]@{ event = 'launcher_status'; name = $parts[0]; value = $parts[1] })
    } else {
        Write-StructuredEvent ([ordered]@{ event = 'launcher_log'; message = $Line })
    }
}

function Get-NextRequestId {
    $id = $script:nextRequestId
    $script:nextRequestId++
    return $id
}

function Start-RuntimeProcess([string]$Executable, [string]$WorkingDirectory, [string[]]$Arguments) {
    if (-not $script:structuredStatus) {
        return Start-Process -FilePath $Executable -WorkingDirectory $WorkingDirectory -ArgumentList $Arguments -PassThru
    }
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Executable
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) { [void]$startInfo.ArgumentList.Add([string]$argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw 'Failed to start Runtime process in structured mode' }
    # 主循环轮询异步 ReadLine Task，避免线程池回调缺少 PowerShell Runspace。
    $script:runtimeStdoutTask = $process.StandardOutput.ReadLineAsync()
    $script:runtimeStderrTask = $process.StandardError.ReadLineAsync()
    return $process
}

function Get-RuntimeReloadTarget([string]$Command) {
    if ($Command -eq 'reload_scene') { return 'Scene' }
    if ($Command -eq 'reload_script') { return 'Script' }
    return $null
}

function New-RuntimeReloadEvent(
    [string]$EventName,
    [string]$State,
    [object]$Pending,
    [uint64]$RequestId,
    [object]$TargetState,
    [string]$Result,
    [string]$ErrorCode,
    [bool]$Ignored
) {
    $event = [ordered]@{
        event = $EventName
        reloadVersion = 1
        state = $State
        target = [string]$Pending.target
        requestId = $RequestId
        source = [string]$Pending.source
    }
    if ($null -ne $Pending.revision) { $event['sourceRevision'] = [string]$Pending.revision }
    if ($null -ne $Pending.artifactRevision) { $event['artifactRevision'] = [string]$Pending.artifactRevision }
    if ($null -ne $Pending.artifactBytes -and [int64]$Pending.artifactBytes -gt 0) { $event['artifactBytes'] = [int64]$Pending.artifactBytes }
    if ($null -ne $TargetState.LatestRequestedSourceRevision) { $event['latestRequestedSourceRevision'] = [string]$TargetState.LatestRequestedSourceRevision }
    if ($null -ne $TargetState.AcknowledgedSourceRevision) { $event['acknowledgedSourceRevision'] = [string]$TargetState.AcknowledgedSourceRevision }
    if ($null -ne $TargetState.AcknowledgedArtifactRevision) { $event['acknowledgedArtifactRevision'] = [string]$TargetState.AcknowledgedArtifactRevision }
    # failedSourceRevision 只描述当前失败候选；stale/ack/requested 不得泄漏另一个 request 的失败身份。
    if ($State -eq 'failed' -and $null -ne $TargetState.FailedSourceRevision) { $event['failedSourceRevision'] = [string]$TargetState.FailedSourceRevision }
    if (-not [string]::IsNullOrWhiteSpace($Result)) { $event['result'] = $Result }
    if (-not [string]::IsNullOrWhiteSpace($ErrorCode)) { $event['errorCode'] = $ErrorCode }
    if ($Ignored) { $event['ignored'] = $true }
    return $event
}

function Write-RuntimeReloadRequested([object]$Pending, [uint64]$RequestId) {
    $targetState = $script:reloadTargets[[string]$Pending.target]
    $targetState.LatestRequestId = $RequestId
    $targetState.LatestRequestedSourceRevision = $Pending.revision
    $targetState.FailedSourceRevision = $null
    Write-StructuredEvent (New-RuntimeReloadEvent 'runtime_reload_requested' 'requested' $Pending $RequestId $targetState '' '' $false)
}

function Complete-RuntimeReload([object]$Pending, [uint64]$RequestId, [string]$Result, [string]$ErrorCode) {
    if ($null -eq $Pending -or $null -eq $Pending.target) { return }
    $targetState = $script:reloadTargets[[string]$Pending.target]
    # 关键过期保护：同一 target 的旧 request completion 只能生成 stale 证据，不能覆盖新 revision。
    if ([uint64]$targetState.LatestRequestId -ne $RequestId) {
        Write-StructuredEvent (New-RuntimeReloadEvent 'runtime_reload_stale' 'stale' $Pending $RequestId $targetState $Result $ErrorCode $true)
        return
    }
    if ($Result -eq 'succeeded') {
        if ($null -ne $Pending.revision) { $targetState.AcknowledgedSourceRevision = $Pending.revision }
        if ($null -ne $Pending.artifactRevision) { $targetState.AcknowledgedArtifactRevision = $Pending.artifactRevision }
        $targetState.FailedSourceRevision = $null
        Write-StructuredEvent (New-RuntimeReloadEvent 'runtime_reload_acknowledged' 'acknowledged' $Pending $RequestId $targetState $Result '' $false)
        return
    }
    $targetState.FailedSourceRevision = $Pending.revision
    Write-StructuredEvent (New-RuntimeReloadEvent 'runtime_reload_failed' 'failed' $Pending $RequestId $targetState $Result $ErrorCode $false)
}

function Test-LowerHex64([object]$Value) {
    return $null -ne $Value -and [string]$Value -cmatch '^[0-9a-f]{64}$'
}

function Convert-RuntimeInitialTarget([string]$TargetName, [object]$RuntimeTarget) {
    if ($null -eq $RuntimeTarget) { throw "Runtime initialLoaded is missing $TargetName" }
    $kind = [string](Get-RequiredProperty $RuntimeTarget 'kind' "Runtime initialLoaded.$TargetName")
    $result = [ordered]@{ target = $TargetName; kind = $kind; correlation = 'runtime_only' }
    if ($kind -eq 'built_in') {
        $result.correlation = 'built_in'
        return $result
    }
    if ($kind -notin @('source_document', 'artifact')) { throw "Runtime initialLoaded.$TargetName has unsupported kind: $kind" }

    $sha256 = [string](Get-RequiredProperty $RuntimeTarget 'sha256' "Runtime initialLoaded.$TargetName")
    if (-not (Test-LowerHex64 $sha256)) { throw "Runtime initialLoaded.$TargetName sha256 must be lowercase 64-hex" }
    try { $bytes = [uint64](Get-RequiredProperty $RuntimeTarget 'bytes' "Runtime initialLoaded.$TargetName") } catch { throw "Runtime initialLoaded.$TargetName bytes must be uint64" }
    if ($bytes -eq 0) { throw "Runtime initialLoaded.$TargetName bytes must be positive" }

    if ($kind -eq 'source_document') {
        # Source document digest 直接来自 Runtime 实际解析 buffer；Launcher 不再读取文件猜测身份。
        $result.sourceRevision = $sha256
        $result.correlation = 'runtime_source'
        return $result
    }

    $result.artifactRevision = $sha256
    $result.artifactBytes = $bytes
    if (-not $script:liveBakeEnabled) { return $result }

    $manifest = Read-LiveBakeManifest $script:liveBakeManifest
    $entryName = $TargetName.ToLowerInvariant()
    $entryProperty = if ($null -ne $manifest) { $manifest.PSObject.Properties[$entryName] } else { $null }
    if ($null -eq $entryProperty -or $null -eq $entryProperty.Value) {
        $result.correlation = 'manifest_missing'
        return $result
    }
    $entry = $entryProperty.Value
    try { $manifestBytes = [uint64]$entry.artifactBytes } catch { $result.correlation = 'artifact_mismatch'; return $result }
    # 只有 Runtime 权威 digest 与 manifest hash/bytes 同时匹配，manifest 才能补充 source revision。
    if ([string]$entry.artifactSha256 -cne $sha256 -or $manifestBytes -ne $bytes) {
        $result.correlation = 'artifact_mismatch'
        return $result
    }
    if (-not (Test-LowerHex64 $entry.sourceSha256)) {
        $result.correlation = 'artifact_mismatch'
        return $result
    }
    $result.sourceRevision = [string]$entry.sourceSha256
    $result.correlation = 'manifest_matched'
    return $result
}

function Write-RuntimeInitialLoadFailed([string]$ErrorCode, [string]$Message) {
    if ($script:initialLoadTerminalEmitted) { return }
    $script:initialLoadTerminalEmitted = $true
    $event = [ordered]@{ event = 'runtime_initial_load_failed'; loadVersion = 1; state = 'failed'; errorCode = $ErrorCode }
    if (-not [string]::IsNullOrWhiteSpace($Message)) { $event.message = $Message }
    Write-StructuredEvent $event
}

function Publish-RuntimeInitialLoaded([object]$RuntimeEvent) {
    if ($script:initialLoadTerminalEmitted) { return }
    $property = $RuntimeEvent.PSObject.Properties['initialLoaded']
    if ($null -eq $property -or $null -eq $property.Value) {
        # 旧 Runtime 的 runtime_ready 没有 data；保持 ready 兼容，但绝不推测 loaded identity。
        return
    }
    try {
        $scene = Convert-RuntimeInitialTarget 'Scene' $property.Value.scene
        $scriptTarget = Convert-RuntimeInitialTarget 'Script' $property.Value.script
        $script:initialLoadTerminalEmitted = $true
        $event = [ordered]@{
            event = 'runtime_initial_loaded'
            loadVersion = 1
            state = 'loaded'
            scene = $scene
            script = $scriptTarget
        }
        if ($script:liveBakeEnabled) { $event.profile = $BakeProfile }
        Write-StructuredEvent $event
    } catch {
        Write-RuntimeInitialLoadFailed 'runtime_initial_identity_invalid' $_.Exception.Message
    }
}

function Handle-RuntimeOutputLine([object]$Item) {
    if ($Item.stream -eq 'stderr') {
        Write-StructuredEvent ([ordered]@{ event = 'runtime_log'; stream = 'stderr'; message = $Item.line })
        return
    }
    try { $runtimeEvent = $Item.line | ConvertFrom-Json } catch {
        Write-StructuredEvent ([ordered]@{ event = 'protocol_error'; message = 'Runtime emitted invalid JSONL' })
        return
    }
    Write-Output $Item.line
    if ($runtimeEvent.event -eq 'runtime_ready') {
        Publish-RuntimeInitialLoaded $runtimeEvent
        return
    }
    if ($runtimeEvent.event -eq 'runtime_failed' -and [string]$runtimeEvent.phase -eq 'startup') {
        Write-RuntimeInitialLoadFailed ([string]$runtimeEvent.errorCode) 'Runtime startup failed before initial content became ready.'
        return
    }
    if ($runtimeEvent.event -ne 'command_completed' -or $null -eq $runtimeEvent.PSObject.Properties['requestId']) { return }
    $requestId = [uint64]$runtimeEvent.requestId
    $pending = $script:pendingRequests[[string]$requestId]
    $response = [ordered]@{ event = 'command_response'; requestId = $requestId; command = [string]$runtimeEvent.command; result = [string]$runtimeEvent.result }
    if ($null -ne $pending) {
        $response['source'] = $pending.source
        if ($null -ne $pending.revision) { $response['revision'] = $pending.revision }
        if ($null -ne $pending.artifactRevision) { $response['artifactRevision'] = $pending.artifactRevision }
        if ($null -ne $pending.artifactBytes -and [int64]$pending.artifactBytes -gt 0) { $response['artifactBytes'] = [int64]$pending.artifactBytes }
        $script:pendingRequests.Remove([string]$requestId)
    }
    $errorCode = ''
    if ($null -ne $runtimeEvent.PSObject.Properties['errorCode']) {
        $errorCode = [string]$runtimeEvent.errorCode
        $response['errorCode'] = $errorCode
    }
    # 先发旧 command_response，再发新 reload 终态，保持旧 CLI/GUI 的事件消费顺序兼容。
    Write-StructuredEvent $response
    Complete-RuntimeReload $pending $requestId ([string]$runtimeEvent.result) $errorCode
}

function Drain-RuntimeOutput([switch]$WaitForEnd) {
    if (-not $script:structuredStatus) { return }
    do {
        $madeProgress = $false
        while ($null -ne $script:runtimeStdoutTask -and $script:runtimeStdoutTask.IsCompleted) {
            $line = $script:runtimeStdoutTask.GetAwaiter().GetResult()
            if ($null -eq $line) { $script:runtimeStdoutTask = $null; break }
            Handle-RuntimeOutputLine ([pscustomobject]@{ stream = 'stdout'; line = $line })
            $script:runtimeStdoutTask = $process.StandardOutput.ReadLineAsync()
            $madeProgress = $true
        }
        while ($null -ne $script:runtimeStderrTask -and $script:runtimeStderrTask.IsCompleted) {
            $line = $script:runtimeStderrTask.GetAwaiter().GetResult()
            if ($null -eq $line) { $script:runtimeStderrTask = $null; break }
            Handle-RuntimeOutputLine ([pscustomobject]@{ stream = 'stderr'; line = $line })
            $script:runtimeStderrTask = $process.StandardError.ReadLineAsync()
            $madeProgress = $true
        }
        if ($WaitForEnd -and -not $madeProgress -and ($null -ne $script:runtimeStdoutTask -or $null -ne $script:runtimeStderrTask)) { Start-Sleep -Milliseconds 10 }
    } while ($WaitForEnd -and ($null -ne $script:runtimeStdoutTask -or $null -ne $script:runtimeStderrTask))
}

function Expire-PendingRequests {
    if (-not $script:structuredStatus) { return }
    foreach ($key in @($script:pendingRequests.Keys)) {
        $pending = $script:pendingRequests[$key]
        if (([DateTime]::UtcNow - $pending.sentAt).TotalSeconds -ge 10) {
            $requestId = [uint64]$key
            $response = [ordered]@{ event = 'command_response'; requestId = $requestId; command = $pending.command; result = 'timeout'; source = $pending.source }
            if ($null -ne $pending.revision) { $response['revision'] = $pending.revision }
            if ($null -ne $pending.artifactRevision) { $response['artifactRevision'] = $pending.artifactRevision }
            if ($null -ne $pending.artifactBytes -and [int64]$pending.artifactBytes -gt 0) { $response['artifactBytes'] = [int64]$pending.artifactBytes }
            Write-StructuredEvent $response
            $script:pendingRequests.Remove($key)
            Complete-RuntimeReload $pending $requestId 'timeout' 'runtime_reload_timeout'
        }
    }
}
function Resolve-ExistingDirectory([string]$Path, [string]$Name) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "$Name does not exist: $Path"
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Get-RequiredProperty([object]$Object, [string]$Name, [string]$Owner) {
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        throw "$Owner is missing required property: $Name"
    }
    return $property.Value
}

function Resolve-PackagePath(
    [string]$Root,
    [string]$RelativePath,
    [string]$Name,
    [bool]$RequireDirectory
) {
    if ([IO.Path]::IsPathRooted($RelativePath)) {
        throw "$Name must be relative to the package root: $RelativePath"
    }

    $fullPath = [IO.Path]::GetFullPath((Join-Path $Root $RelativePath))
    $rootPrefix = $Root.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar

    # 关键边界：Editor 配置不能借由绝对路径或 .. 跳出已验证的 Runtime package。
    if (-not $fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Name escapes the package root: $RelativePath"
    }

    $pathType = if ($RequireDirectory) { 'Container' } else { 'Leaf' }
    if (-not (Test-Path -LiteralPath $fullPath -PathType $pathType)) {
        throw "$Name does not exist in the package: $RelativePath"
    }
    return $fullPath
}

function Get-RuntimeWindow([Diagnostics.Process]$Process, [string]$Operation) {
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while ([DateTime]::UtcNow -lt $deadline -and -not $Process.HasExited) {
        # MainWindowHandle 可能被显卡/UAC overlay 抢占；按 PID + Kadath 窗口类名解析真实 Runtime 窗口。
        $window = [KadathPreviewNative]::FindRuntimeWindow($Process.Id)
        if ($window -ne [IntPtr]::Zero) { return $window }
        Start-Sleep -Milliseconds 100
    }
    if ($Process.HasExited) { return [IntPtr]::Zero }
    throw "Runtime window was not ready before the $Operation timeout"
}
function Request-RuntimeClose([Diagnostics.Process]$Process) {
    if ($Process.HasExited) { return }
    $windowHandle = Get-RuntimeWindow $Process "close"
    if ($windowHandle -eq [IntPtr]::Zero) { return }

    # 关键生命周期约束：优先请求宿主正常关闭，让 Runtime 自己完成 GPU/音频资源清理。
    if (-not [KadathPreviewNative]::PostMessage($windowHandle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)) {
        throw "Failed to post WM_CLOSE to Runtime process"
    }
}

function Request-RuntimeStructuredReload(
    [Diagnostics.Process]$Process,
    [string]$Command,
    [string]$Source,
    [string]$Revision,
    [string]$ArtifactRevision = '',
    [int64]$ArtifactBytes = 0
) {
    if ($Process.HasExited) { return }
    $target = Get-RuntimeReloadTarget $Command
    if ($null -eq $target) { throw "Unsupported structured reload command: $Command" }
    $windowHandle = Get-RuntimeWindow $Process "$Command command"
    if ($windowHandle -eq [IntPtr]::Zero) { return }
    $requestId = Get-NextRequestId
    $message = if ($Command -eq 'reload_scene') { 0x84D0 } else { 0x84D1 }
    $script:pendingRequests[[string]$requestId] = [pscustomobject]@{
        command = $Command
        target = $target
        source = $Source
        revision = if ([string]::IsNullOrWhiteSpace($Revision)) { $null } else { $Revision }
        artifactRevision = if ([string]::IsNullOrWhiteSpace($ArtifactRevision)) { $null } else { $ArtifactRevision }
        artifactBytes = if ($ArtifactBytes -gt 0) { $ArtifactBytes } else { $null }
        sentAt = [DateTime]::UtcNow
    }
    # 关键关联边界：requestId 通过 WM_APP 进入 Runtime，并在 JSONL 终态响应中原样返回。
    if (-not [KadathPreviewNative]::PostMessage($windowHandle, $message, [IntPtr][long]$requestId, [IntPtr]::Zero)) {
        $script:pendingRequests.Remove([string]$requestId)
        throw "Failed to post structured $Command command"
    }
    $event = [ordered]@{ event = 'command_requested'; requestId = $requestId; command = $Command; source = $Source }
    if (-not [string]::IsNullOrWhiteSpace($Revision)) { $event['revision'] = $Revision }
    if (-not [string]::IsNullOrWhiteSpace($ArtifactRevision)) { $event['artifactRevision'] = $ArtifactRevision }
    if ($ArtifactBytes -gt 0) { $event['artifactBytes'] = $ArtifactBytes }
    Write-StructuredEvent $event
    Write-RuntimeReloadRequested $script:pendingRequests[[string]$requestId] $requestId
}

function Request-RuntimeSceneReload(
    [Diagnostics.Process]$Process,
    [string]$Source = 'explicit',
    [string]$Revision = '',
    [string]$ArtifactRevision = '',
    [int64]$ArtifactBytes = 0
) {
    if ($script:structuredStatus) {
        Request-RuntimeStructuredReload $Process 'reload_scene' $Source $Revision $ArtifactRevision $ArtifactBytes
        return
    }
    Request-RuntimeKey $Process 0x74 'scene reload'
}

function Request-RuntimeScriptReload(
    [Diagnostics.Process]$Process,
    [string]$Source = 'explicit',
    [string]$Revision = '',
    [string]$ArtifactRevision = '',
    [int64]$ArtifactBytes = 0
) {
    if ($script:structuredStatus) {
        Request-RuntimeStructuredReload $Process 'reload_script' $Source $Revision $ArtifactRevision $ArtifactBytes
        return
    }
    if ($Process.HasExited) { return }
    $windowHandle = Get-RuntimeWindow $Process 'script reload'
    if ($windowHandle -eq [IntPtr]::Zero) { return }
    # 兼容路径仍使用 F6，只有 structured mode 使用带 requestId 的 WM_APP。
    if (-not [KadathPreviewNative]::PostMessage($windowHandle, 0x0100, [IntPtr]0x75, [IntPtr]::Zero)) { throw 'Failed to post F6 key-down to Runtime process' }
    Start-Sleep -Milliseconds 50
    if (-not [KadathPreviewNative]::PostMessage($windowHandle, 0x0101, [IntPtr]0x75, [IntPtr]::Zero)) { throw 'Failed to post F6 key-up to Runtime process' }
}
function Get-RuntimeDocumentArgument([string[]]$Arguments, [string]$Option) {
    $matches = @()
    for ($index = 0; $index -lt $Arguments.Count; $index++) {
        if ($Arguments[$index] -eq $Option) {
            if ($index + 1 -ge $Arguments.Count) { throw "Runtime arguments are missing a path after $Option" }
            $matches += [string]$Arguments[$index + 1]
        }
    }
    if ($matches.Count -ne 1) { throw "Runtime arguments must contain exactly one $Option path when file watching is enabled" }
    return $matches[0]
}

function Resolve-WorkingDirectoryDocument([string]$Root, [string]$RelativePath, [string]$Name) {
    if ([IO.Path]::IsPathRooted($RelativePath)) { throw "$Name must be relative to the Runtime working directory: $RelativePath" }
    $fullPath = [IO.Path]::GetFullPath((Join-Path $Root $RelativePath))
    $rootPrefix = $Root.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    # 关键安全边界：自动监听只能观察 Preview 已验证 working directory 内的文档。
    if (-not $fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "$Name escapes the Runtime working directory: $RelativePath" }
    return $fullPath
}

function Get-FileRevision([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 'missing' }
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $digest = $sha.ComputeHash([IO.File]::ReadAllBytes($Path)) } finally { $sha.Dispose() }
        return [BitConverter]::ToString($digest).Replace('-', '')
    } catch {
        # 写入者可能正处于原子替换或分段写入；稳定性判断会等待下一轮再提交。
        return "unreadable:$($_.Exception.GetType().Name)"
    }
}

function Request-RuntimeKey([Diagnostics.Process]$Process, [int]$VirtualKey, [string]$Operation) {
    if ($Process.HasExited) { return }
    $windowHandle = Get-RuntimeWindow $Process $Operation
    if ($windowHandle -eq [IntPtr]::Zero) { return }
    if (-not [KadathPreviewNative]::PostMessage($windowHandle, 0x0100, [IntPtr]$VirtualKey, [IntPtr]::Zero)) { throw "Failed to post key-down for $Operation" }
    Start-Sleep -Milliseconds 50
    if (-not [KadathPreviewNative]::PostMessage($windowHandle, 0x0101, [IntPtr]$VirtualKey, [IntPtr]::Zero)) { throw "Failed to post key-up for $Operation" }
}

function Get-RelativePackagePath([string]$Root, [string]$Path) {
    return ([IO.Path]::GetRelativePath($Root, $Path)).Replace([IO.Path]::DirectorySeparatorChar, '/')
}

function Resolve-LiveBakeDirectory([string]$Root, [string]$WorkingDirectory, [string]$ConfigFile, [string]$Override) {
    $candidate = if ([string]::IsNullOrWhiteSpace($Override)) { Join-Path (Split-Path -Parent $ConfigFile) '.kadath\derived' } elseif ([IO.Path]::IsPathRooted($Override)) { $Override } else { Join-Path $Root $Override }
    $full = [IO.Path]::GetFullPath($candidate)
    $rootPrefix = $Root.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $workingPrefix = $WorkingDirectory.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase) -or -not $full.StartsWith($workingPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "DerivedDirectory must remain inside package working directory: $full" }
    if ($full -match '(?i)[\\/]bin[\\/]assets([\\/]|$)') { throw "DerivedDirectory must not be package/bin/assets: $full" }
    New-Item -ItemType Directory -Path $full -Force | Out-Null
    return $full
}

function Set-RuntimeDocumentArgument([string[]]$Arguments, [string]$Option, [string]$Value) {
    $result = @($Arguments)
    $found = $false
    for ($index = 0; $index -lt $result.Count; $index++) {
        if ($result[$index] -eq $Option) {
            if ($found -or $index + 1 -ge $result.Count) { throw "Runtime arguments must contain exactly one $Option path" }
            $result[$index + 1] = $Value
            $found = $true
        }
    }
    if (-not $found) { throw "Runtime arguments are missing $Option" }
    return ,$result
}

function Write-LiveBakeEvent([string]$EventName, [object]$Result, [string]$TargetName) {
    $entries = @()
    if ($null -ne $Result -and $null -ne $Result.PSObject.Properties['entries']) { $entries = @($Result.entries) }
    $event = [ordered]@{ event = $EventName; target = $TargetName; profile = $BakeProfile; entries = $entries }
    if ($null -ne $Result -and $null -ne $Result.PSObject.Properties['errorCode']) { $event['errorCode'] = [string]$Result.errorCode }
    if ($null -ne $Result -and $null -ne $Result.PSObject.Properties['message']) { $event['message'] = [string]$Result.message }
    if ($null -ne $Result -and $null -ne $Result.PSObject.Properties['adapterVersion']) { $event['adapterVersion'] = [int]$Result.adapterVersion }
    # 直接写 stdout，避免事件对象混入 Invoke-LiveBake 的返回值；GUI 仍按 JSONL 消费。
    if ($script:structuredStatus) {
        $script:launcherSequence++
        $event['schemaVersion'] = 1
        $event['origin'] = 'launcher'
        $event['sequence'] = $script:launcherSequence
        [Console]::WriteLine(($event | ConvertTo-Json -Compress -Depth 10))
    } else {
        [Console]::WriteLine(("live_bake_{0}=1" -f $EventName.Replace('live_bake_', '')))
    }
}
function Read-LiveBakeManifest([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $manifest = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
        if ([int]$manifest.schemaVersion -ne 1) { return $null }
        return $manifest
    } catch { return $null }
}

function Test-LiveBakeReuse([string]$ManifestPath, [string]$SceneSourcePath, [string]$ScriptSourcePath, [string]$SceneArtifactPath, [string]$ScriptArtifactPath) {
    $manifest = Read-LiveBakeManifest $ManifestPath
    if ($null -eq $manifest -or [string]$manifest.profile -cne $BakeProfile) { return $null }
    foreach ($entry in @([pscustomobject]@{ Source = $SceneSourcePath; Artifact = $SceneArtifactPath; Data = $manifest.scene }, [pscustomobject]@{ Source = $ScriptSourcePath; Artifact = $ScriptArtifactPath; Data = $manifest.script })) {
        if ($null -eq $entry.Data -or [string]$entry.Data.sourceSha256 -ine (Get-FileRevision $entry.Source) -or -not (Test-Path -LiteralPath $entry.Artifact -PathType Leaf) -or [string]$entry.Data.artifactSha256 -ine (Get-FileRevision $entry.Artifact)) { return $null }
    }
    return $manifest
}

function Invoke-LiveBake([string]$TargetName, [bool]$Initial) {
    $eventTarget = if ($Initial) { 'Both' } else { $TargetName }
    Write-LiveBakeEvent 'live_bake_started' $null $eventTarget
    $arguments = @(
        '-NoProfile', '-File', $script:liveBakeScript,
        '-PackageRoot', $package,
        '-SceneSourcePath', $script:liveBakeSources.Scene,
        '-ScriptSourcePath', $script:liveBakeSources.Script,
        '-SceneArtifactPath', $script:liveBakeArtifacts.Scene,
        '-ScriptArtifactPath', $script:liveBakeArtifacts.Script,
        '-ManifestPath', $script:liveBakeManifest,
        '-Target', $eventTarget,
        '-Profile', $BakeProfile
    )
    $lines = @(& pwsh @arguments 2>&1 | ForEach-Object { $_.ToString() })
    $exitCode = $LASTEXITCODE
    $result = $null
    for ($lineIndex = $lines.Count - 1; $lineIndex -ge 0; $lineIndex--) {
        try { $candidate = $lines[$lineIndex] | ConvertFrom-Json; if ([string]$candidate.event -eq 'live_bake_result') { $result = $candidate; break } } catch { }
    }
    if ($null -eq $result) { $result = [pscustomobject]@{ result = 'failed'; errorCode = 'adapter_protocol_error'; message = ($lines -join ' | '); entries = @() } }
    if ($exitCode -ne 0 -or [string]$result.result -ne 'succeeded') {
        Write-LiveBakeEvent 'live_bake_failed' $result $eventTarget
        return $result
    }
    Write-LiveBakeEvent 'live_bake_completed' $result $eventTarget
    return $result
}
function Ensure-LiveBakeInitial {
    $reused = Test-LiveBakeReuse $script:liveBakeManifest $script:liveBakeSources.Scene $script:liveBakeSources.Script $script:liveBakeArtifacts.Scene $script:liveBakeArtifacts.Script
    if ($null -ne $reused) {
        Write-LiveBakeEvent 'live_bake_reused' ([pscustomobject]@{ entries = @($reused.scene, $reused.script); adapterVersion = 1 }) 'Both'
        return
    }
    $result = Invoke-LiveBake '' $true
    if ([string]$result.result -ne 'succeeded') { throw "Initial live bake failed: $([string]$result.message)" }
}

function Update-WatchTarget([object]$Target, [Diagnostics.Process]$Process, [DateTime]$Now, [int]$DebounceMs) {
    $path = if ($script:liveBakeEnabled) { $Target.SourcePath } else { $Target.Path }
    $revision = Get-FileRevision $path
    if ($revision -ne $Target.ObservedRevision) {
        $Target.ObservedRevision = $revision
        $Target.PendingRevision = $revision
        $Target.PendingSince = $Now
        Write-PreviewOutput "$($Target.Name)_change_detected=1"
    }
    if ($null -eq $Target.PendingRevision -or $revision -ne $Target.PendingRevision) { return }
    if (($Now - $Target.PendingSince).TotalMilliseconds -lt $DebounceMs) { return }

    if ($script:liveBakeEnabled) {
        if ($revision -eq $Target.LastSuccessfulRevision -or $revision -eq $Target.FailedRevision) {
            $Target.PendingRevision = $null; $Target.PendingSince = $null
            return
        }
        $bakeTarget = if ($Target.Name -eq 'scene') { 'Scene' } else { 'Script' }
        $result = Invoke-LiveBake $bakeTarget $false
        if ([string]$result.result -ne 'succeeded') {
            # 同一失败 revision 只报告一次，保留 Runtime 正在使用的最近成功 artifact。
            $Target.FailedRevision = $revision
            $Target.PendingRevision = $null; $Target.PendingSince = $null
            return
        }
        if ((Get-FileRevision $Target.SourcePath) -cne $revision) {
            $Target.PendingRevision = $null; $Target.PendingSince = $null
            return
        }
        $Target.LastSuccessfulRevision = $revision
        $Target.FailedRevision = $null
        # 将 bake result 的 artifact hash/bytes 随 reload request 传入确认事件，区分 source 与实际派生文件。
        $expectedKind = if ($Target.Name -eq 'scene') { 'Scene' } else { 'Script' }
        $bakedEntry = @($result.entries | Where-Object { [string]$_.kind -ieq $expectedKind })[0]
        $artifactRevision = if ($null -ne $bakedEntry) { [string]$bakedEntry.artifactSha256 } else { '' }
        $artifactBytes = if ($null -ne $bakedEntry) { [int64]$bakedEntry.artifactBytes } else { 0 }
        if ($Target.Name -eq 'scene') { Request-RuntimeSceneReload $Process 'live_bake' $revision $artifactRevision $artifactBytes } else { Request-RuntimeScriptReload $Process 'live_bake' $revision $artifactRevision $artifactBytes }
        $Target.PendingRevision = $null; $Target.PendingSince = $null
        Write-PreviewOutput "$($Target.Name)_reload_requested=auto"
        return
    }

    if ($revision -eq $Target.LastRequestedRevision) {
        $Target.PendingRevision = $null; $Target.PendingSince = $null
        return
    }
    # 非 live 模式继续直接 reload JSON，保持 P2-M4-07 的既有兼容行为。
    if ($Target.Name -eq 'scene') { Request-RuntimeSceneReload $Process 'file_change' $revision } else { Request-RuntimeScriptReload $Process 'file_change' $revision }
    $Target.LastRequestedRevision = $revision
    $Target.PendingRevision = $null; $Target.PendingSince = $null
    Write-PreviewOutput "$($Target.Name)_reload_requested=auto"
}
$configFile = if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
    (Resolve-Path -LiteralPath $ConfigPath).Path
} else {
    throw "Config file does not exist: $ConfigPath"
}
$package = Resolve-ExistingDirectory $PackageRoot "Package root"
$config = Get-Content -LiteralPath $configFile -Raw -Encoding utf8 | ConvertFrom-Json

$schemaVersion = Get-RequiredProperty $config "schemaVersion" "Preview config"
if ($schemaVersion -isnot [long] -and $schemaVersion -isnot [int]) {
    throw "Preview config schemaVersion must be an integer"
}
if ([int]$schemaVersion -ne 1) {
    throw "Unsupported preview config schemaVersion: $schemaVersion"
}

$runtime = Get-RequiredProperty $config "runtime" "Preview config"
$executableRelative = [string](Get-RequiredProperty $runtime "executable" "runtime")
$workingDirectoryRelative = [string](Get-RequiredProperty $runtime "workingDirectory" "runtime")
$executable = Resolve-PackagePath $package $executableRelative "Runtime executable" $false
$workingDirectory = Resolve-PackagePath $package $workingDirectoryRelative "Runtime working directory" $true

$arguments = @()
$argumentsProperty = $runtime.PSObject.Properties["arguments"]
if ($null -ne $argumentsProperty -and $null -ne $argumentsProperty.Value) {
    foreach ($argument in @($argumentsProperty.Value)) {
        if ($argument -isnot [string]) { throw "runtime.arguments must contain only strings" }
        $arguments += $argument
    }
}

$sceneSourceArgument = $null
$scriptSourceArgument = $null
if ($LiveBake) {
    if (-not (Test-Path -LiteralPath $script:liveBakeScript -PathType Leaf)) { throw "Live-bake adapter does not exist: $script:liveBakeScript" }
    $sceneSourceArgument = Get-RuntimeDocumentArgument $arguments '--scene'
    $scriptSourceArgument = Get-RuntimeDocumentArgument $arguments '--script'
    $sceneSourcePath = Resolve-WorkingDirectoryDocument $workingDirectory $sceneSourceArgument 'Scene source'
    $scriptSourcePath = Resolve-WorkingDirectoryDocument $workingDirectory $scriptSourceArgument 'Script source'
    $derived = Resolve-LiveBakeDirectory $package $workingDirectory $configFile $DerivedDirectory
    $script:liveBakeSources = @{ Scene = $sceneSourcePath; Script = $scriptSourcePath }
    $script:liveBakeArtifacts = @{ Scene = Join-Path $derived 'scene.scene'; Script = Join-Path $derived 'script.script' }
    $script:liveBakeManifest = Join-Path $derived '.live-bake.manifest.json'
    Ensure-LiveBakeInitial
    # Runtime 参数只在内存中切换到派生 artifact，项目 preview.json 保持 authoring source 路径。
    $arguments = Set-RuntimeDocumentArgument $arguments '--scene' (Get-RelativePackagePath $workingDirectory $script:liveBakeArtifacts.Scene)
    $arguments = Set-RuntimeDocumentArgument $arguments '--script' (Get-RelativePackagePath $workingDirectory $script:liveBakeArtifacts.Script)
}

if ($StructuredStatus) {
    if ($arguments -contains '--preview-status') { throw 'Preview config must not supply --preview-status when StructuredStatus is enabled' }
    $arguments += '--preview-status'
    $arguments += 'jsonl-v1'
}

$watchTargets = @()
if ($WatchChanges) {
    if ($LiveBake) {
        $watchTargets = @(
            [pscustomobject]@{ Name = 'scene'; SourcePath = $script:liveBakeSources.Scene; ArtifactPath = $script:liveBakeArtifacts.Scene; Path = $script:liveBakeSources.Scene; ObservedRevision = $null; PendingRevision = $null; PendingSince = $null; LastRequestedRevision = $null; LastSuccessfulRevision = $null; FailedRevision = $null },
            [pscustomobject]@{ Name = 'script'; SourcePath = $script:liveBakeSources.Script; ArtifactPath = $script:liveBakeArtifacts.Script; Path = $script:liveBakeSources.Script; ObservedRevision = $null; PendingRevision = $null; PendingSince = $null; LastRequestedRevision = $null; LastSuccessfulRevision = $null; FailedRevision = $null }
        )
    } else {
        $sceneArgument = Get-RuntimeDocumentArgument $arguments '--scene'
        $scriptArgument = Get-RuntimeDocumentArgument $arguments '--script'
        $watchTargets = @(
            [pscustomobject]@{ Name = 'scene'; Path = Resolve-WorkingDirectoryDocument $workingDirectory $sceneArgument 'Scene document'; ObservedRevision = $null; PendingRevision = $null; PendingSince = $null; LastRequestedRevision = $null },
            [pscustomobject]@{ Name = 'script'; Path = Resolve-WorkingDirectoryDocument $workingDirectory $scriptArgument 'Script document'; ObservedRevision = $null; PendingRevision = $null; PendingSince = $null; LastRequestedRevision = $null }
        )
    }
    foreach ($target in $watchTargets) {
        $initialRevision = Get-FileRevision $target.Path
        $target.ObservedRevision = $initialRevision
        if ($LiveBake) { $target.LastSuccessfulRevision = $initialRevision } else { $target.LastRequestedRevision = $initialRevision }
    }
}
if ($StopAfterMilliseconds -gt 0 -and
    $ReloadScriptAfterMilliseconds -ge $StopAfterMilliseconds)
{
    throw "ReloadScriptAfterMilliseconds must be less than StopAfterMilliseconds"
}

Write-PreviewOutput "preview_contract=1"
Write-PreviewOutput "runtime_executable=$executable"
Write-PreviewOutput "runtime_working_directory=$workingDirectory"
if ($LiveBake) {
    Write-PreviewOutput 'live_bake=1'
    Write-PreviewOutput "live_bake_profile=$BakeProfile"
    Write-PreviewOutput "live_bake_derived_directory=$derived"
}

$process = $null
try {
    $process = Start-RuntimeProcess $executable $workingDirectory $arguments
    Write-PreviewOutput "runtime_pid=$($process.Id)"

    $startedAt = [DateTime]::UtcNow
    $scriptReloadSent = $false
    $closeRequested = $false
    if ($WatchChanges) {
        Write-PreviewOutput "watch_changes=1"
        Write-PreviewOutput "watch_poll_interval_ms=$PollIntervalMilliseconds"
        Write-PreviewOutput "watch_debounce_ms=$DebounceMilliseconds"
    }
    while (-not $process.HasExited) {
        Drain-RuntimeOutput
        Expire-PendingRequests
        $now = [DateTime]::UtcNow
        $elapsedMilliseconds = [int]($now - $startedAt).TotalMilliseconds
        if ($ReloadScriptAfterMilliseconds -gt 0 -and -not $scriptReloadSent -and $elapsedMilliseconds -ge $ReloadScriptAfterMilliseconds) {
            Request-RuntimeScriptReload $process 'timer'
            $scriptReloadSent = $true
            Write-PreviewOutput "script_reload_requested=1"
        }
        if ($WatchChanges) {
            # 监听循环只负责产生粗粒度命令，候选状态校验和回滚仍由 Runtime 完成。
            foreach ($target in $watchTargets) { Update-WatchTarget $target $process $now $DebounceMilliseconds }
        }
        if ($StopAfterMilliseconds -gt 0 -and $elapsedMilliseconds -ge $StopAfterMilliseconds) {
            Request-RuntimeClose $process
            $closeRequested = $true
            break
        }
        if (-not $WatchChanges -and $StopAfterMilliseconds -eq 0 -and $ReloadScriptAfterMilliseconds -eq 0) {
            $process.WaitForExit()
            break
        }
        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    }
    if ($closeRequested -and -not $process.WaitForExit(10000)) { throw "Runtime did not exit within 10 seconds after the close request" }
    if ($StructuredStatus) {
        # 等待异步 stdout/stderr 读流排空，避免漏掉最终 runtime_stopping 事件。
        $process.WaitForExit()
        Drain-RuntimeOutput -WaitForEnd
    }
    if ($process.ExitCode -ne 0) {
        throw "Runtime exited with code $($process.ExitCode)"
    }

    Write-PreviewOutput "runtime_exit_code=$($process.ExitCode)"
    Write-PreviewOutput "preview=ok"
} finally {
    # 自动 smoke 失败时避免遗留孤儿进程；正常关闭路径不会进入强制终止。
    if ($null -ne $process -and -not $process.HasExited) {
        $process.Kill($true)
        $process.WaitForExit()
    }
}
