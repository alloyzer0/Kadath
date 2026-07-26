[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackageRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ProjectAlreadyExistsExitCode = 17
$ConcurrentAttemptLimit = 12
$SceneTemplatePaddingBytes = 48 * 1024
$fixturePrefix = 'verify-editor-project-create-'
$packageParent = (Resolve-Path -LiteralPath $PackageRoot).Path
if (-not (Test-Path -LiteralPath $packageParent -PathType Container)) {
    throw "PackageRoot must be an existing directory: $PackageRoot"
}

$fixtureName = $fixturePrefix + [Guid]::NewGuid().ToString('N')
$fixtureRoot = [IO.Path]::GetFullPath((Join-Path $packageParent $fixtureName))
$parentFull = [IO.Path]::GetFullPath($packageParent).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
$fixtureParent = [IO.Path]::GetDirectoryName($fixtureRoot)
if (-not [string]::Equals($fixtureParent, $parentFull, [StringComparison]::OrdinalIgnoreCase) -or
    -not [IO.Path]::GetFileName($fixtureRoot).StartsWith($fixturePrefix, [StringComparison]::Ordinal)) {
    throw "Verifier fixture escaped PackageRoot: $fixtureRoot"
}

$author = Join-Path $PSScriptRoot 'editor-author.ps1'
if (-not (Test-Path -LiteralPath $author -PathType Leaf)) {
    throw "Editor author Adapter does not exist: $author"
}

function Get-TreeIdentity([string]$Root) {
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return @('MISSING|.')
    }

    $entries = [Collections.Generic.List[string]]::new()
    $entries.Add('D|.')
    foreach ($item in @(Get-ChildItem -LiteralPath $Root -Force -Recurse | Sort-Object FullName)) {
        $relative = [IO.Path]::GetRelativePath($Root, $item.FullName).Replace('\', '/')
        if ($item.PSIsContainer) {
            $entries.Add("D|$relative")
        }
        else {
            $hash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
            $entries.Add("F|$relative|$($item.Length)|$hash")
        }
    }
    return @($entries)
}

function Start-SynchronizedCreateWorker(
    [string]$ReadyPath,
    [string]$GatePath,
    [string]$AdapterPath,
    [string]$FixturePath,
    [string]$ProjectName
) {
    $workerCommand = @'
$ErrorActionPreference = 'Stop'
[IO.File]::WriteAllText($env:KADATH_CREATE_READY, 'ready', [Text.UTF8Encoding]::new($false))
$deadline = [DateTime]::UtcNow.AddSeconds(20)
while (-not [IO.File]::Exists($env:KADATH_CREATE_GATE)) {
    if ([DateTime]::UtcNow -ge $deadline) {
        [Console]::Error.WriteLine('Timed out waiting for the verifier release gate.')
        exit 98
    }
    [Threading.Thread]::Sleep(2)
}
try {
    & $env:KADATH_CREATE_AUTHOR -Action Create -PackageRoot $env:KADATH_CREATE_PACKAGE -ProjectName $env:KADATH_CREATE_PROJECT
    exit $LASTEXITCODE
}
catch {
    [Console]::Error.WriteLine($_.ToString())
    exit 1
}
'@

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = (Get-Command pwsh -ErrorAction Stop).Source
    $startInfo.WorkingDirectory = $PSScriptRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.ArgumentList.Add('-NoProfile')
    $startInfo.ArgumentList.Add('-NonInteractive')
    $startInfo.ArgumentList.Add('-Command')
    $startInfo.ArgumentList.Add($workerCommand)
    $startInfo.Environment['KADATH_CREATE_READY'] = $ReadyPath
    $startInfo.Environment['KADATH_CREATE_GATE'] = $GatePath
    $startInfo.Environment['KADATH_CREATE_AUTHOR'] = $AdapterPath
    $startInfo.Environment['KADATH_CREATE_PACKAGE'] = $FixturePath
    $startInfo.Environment['KADATH_CREATE_PROJECT'] = $ProjectName

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw 'Failed to start synchronized project_create worker.' }
    return $process
}

function Wait-SynchronizedWorkersReady([Diagnostics.Process[]]$Workers, [string[]]$ReadyPaths) {
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while (@($ReadyPaths | Where-Object { -not [IO.File]::Exists($_) }).Count -ne 0) {
        foreach ($worker in $Workers) {
            if ($worker.HasExited) { throw "project_create worker exited before release gate: $($worker.ExitCode)" }
        }
        if ([DateTime]::UtcNow -ge $deadline) { throw 'Timed out waiting for synchronized project_create workers.' }
        [Threading.Thread]::Sleep(5)
    }
}

function Receive-CreateWorker([Diagnostics.Process]$Worker) {
    if (-not $Worker.WaitForExit(60000)) {
        $Worker.Kill($true)
        [void]$Worker.WaitForExit(5000)
        throw 'Timed out waiting for project_create worker completion.'
    }
    $Worker.WaitForExit()
    return [pscustomobject]@{
        ExitCode = $Worker.ExitCode
        Stdout = $Worker.StandardOutput.ReadToEnd()
        Stderr = $Worker.StandardError.ReadToEnd()
    }
}

function Send-RpcJson([Diagnostics.Process]$Process, [object]$Value) {
    $Process.StandardInput.WriteLine(($Value | ConvertTo-Json -Compress -Depth 12))
    $Process.StandardInput.Flush()
}

function Read-RpcMessage([Diagnostics.Process]$Process, [int]$TimeoutMs = 15000) {
    $readTask = $Process.StandardOutput.ReadLineAsync()
    if (-not $readTask.Wait($TimeoutMs)) {
        throw "Editor Service JSONL timeout: stage=$($script:rpcStage) exited=$($Process.HasExited)"
    }
    $line = $readTask.GetAwaiter().GetResult()
    if ($null -eq $line) { throw "Editor Service closed stdout: stage=$($script:rpcStage)" }
    $message = $line | ConvertFrom-Json
    $script:rpcMessages.Add($message)
    if ([string]$message.type -eq 'event') {
        if ([int64]$message.sequence -le $script:rpcSequence) { throw 'Editor Service event sequence is not strictly increasing.' }
        $script:rpcSequence = [int64]$message.sequence
    }
    return $message
}

function Test-PreviewTelemetryEvent([object]$Message) {
    return [string]$Message.type -eq 'event' -and [string]$Message.event -in @('preview_log', 'preview_status')
}

function Read-PreviewStartExchange(
    [Diagnostics.Process]$Process,
    [string]$RequestId,
    [bool]$ExpectUnrequestedStop,
    [int]$MaxMessages = 16
) {
    $response = $null
    $surface = $null
    $unrequestedStop = $null
    for ($index = 0; $index -lt $MaxMessages; $index++) {
        $message = Read-RpcMessage $Process
        if (Test-PreviewTelemetryEvent $message) { continue }

        if ([string]$message.type -eq 'response') {
            if ([string]$message.id -ne $RequestId -or $null -ne $response) {
                throw "Unexpected Preview start response: $($message | ConvertTo-Json -Compress -Depth 6)"
            }
            $response = $message
        }
        elseif ([string]$message.type -eq 'event' -and [string]$message.event -eq 'preview_surface_created') {
            if ($null -ne $surface) { throw 'Preview start emitted duplicate preview_surface_created.' }
            $surface = $message
        }
        elseif ([string]$message.type -eq 'event' -and [string]$message.event -eq 'preview_stopped') {
            $requestedProperty = $message.data.PSObject.Properties['requested']
            if ($null -eq $requestedProperty -or [bool]$message.data.requested) {
                throw "Preview start emitted an unexpected requested stop: $($message | ConvertTo-Json -Compress -Depth 6)"
            }
            if ($null -ne $unrequestedStop) { throw 'Preview start emitted duplicate unrequested preview_stopped.' }
            $unrequestedStop = $message
        }
        else {
            throw "Unexpected envelope during Preview start: $($message | ConvertTo-Json -Compress -Depth 6)"
        }

        $hasExpectedStop = -not $ExpectUnrequestedStop -or $null -ne $unrequestedStop
        if ($null -ne $response -and $null -ne $surface -and $hasExpectedStop) {
            if (-not $ExpectUnrequestedStop -and $null -ne $unrequestedStop) {
                throw 'Running Preview exited before preview_start completed.'
            }
            return [pscustomobject]@{ Response = $response; Surface = $surface; UnrequestedStop = $unrequestedStop }
        }
    }
    throw "Preview start exchange exceeded $MaxMessages envelopes: requestId=$RequestId"
}

function Read-RpcResponseWithPreviewInterleaving(
    [Diagnostics.Process]$Process,
    [string]$RequestId,
    [bool]$AllowRequestedStop = $false,
    [int]$MaxMessages = 16
) {
    $requestedStop = $null
    for ($index = 0; $index -lt $MaxMessages; $index++) {
        $message = Read-RpcMessage $Process
        if (Test-PreviewTelemetryEvent $message) { continue }

        if ([string]$message.type -eq 'event' -and [string]$message.event -eq 'preview_stopped' -and $AllowRequestedStop) {
            $requestedProperty = $message.data.PSObject.Properties['requested']
            if ($null -eq $requestedProperty -or -not [bool]$message.data.requested -or $null -ne $requestedStop) {
                throw "Unexpected preview_stopped while awaiting response: $($message | ConvertTo-Json -Compress -Depth 6)"
            }
            $requestedStop = $message
            continue
        }
        if ([string]$message.type -eq 'response' -and [string]$message.id -eq $RequestId) {
            return [pscustomobject]@{ Response = $message; RequestedStop = $requestedStop }
        }
        throw "Unexpected envelope while awaiting response $RequestId`: $($message | ConvertTo-Json -Compress -Depth 6)"
    }
    throw "Response exceeded $MaxMessages envelopes: requestId=$RequestId"
}

function Read-ProjectCreateSuccessWithPreviewInterleaving(
    [Diagnostics.Process]$Process,
    [string]$RequestId,
    [int]$MaxMessages = 16
) {
    $created = $null
    for ($index = 0; $index -lt $MaxMessages; $index++) {
        $message = Read-RpcMessage $Process
        if (Test-PreviewTelemetryEvent $message) { continue }

        if ([string]$message.type -eq 'event' -and [string]$message.event -eq 'project_created' -and
            [string]$message.requestId -eq $RequestId) {
            if ($null -ne $created) { throw "Create emitted duplicate project_created: requestId=$RequestId" }
            $created = $message
            continue
        }
        if ([string]$message.type -eq 'response' -and [string]$message.id -eq $RequestId) {
            if ($null -eq $created) { throw "project_created must precede Create response: requestId=$RequestId" }
            return [pscustomobject]@{ Event = $created; Response = $message }
        }
        throw "Unexpected envelope during successful Create $RequestId`: $($message | ConvertTo-Json -Compress -Depth 6)"
    }
    throw "Successful Create exceeded $MaxMessages envelopes: requestId=$RequestId"
}

function Assert-NormalizedPath([string]$Actual, [string]$Expected, [string]$Name) {
    $actualFull = [IO.Path]::GetFullPath($Actual)
    $expectedFull = [IO.Path]::GetFullPath($Expected)
    if (-not [string]::Equals($actualFull, $expectedFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Name path mismatch: expected=$expectedFull actual=$actualFull"
    }
}

function Assert-ProjectSessionInfo([object]$Value, [string]$ExpectedRoot, [string]$ExpectedName) {
    $expectedProperties = @('modelVersion', 'packageRoot', 'previewPath', 'projectDirectory', 'projectName', 'scenePath', 'scriptPath') | Sort-Object
    $actualProperties = @($Value.PSObject.Properties.Name | Sort-Object)
    if (($actualProperties -join '|') -ne ($expectedProperties -join '|')) {
        throw "ProjectSessionInfo properties mismatch: expected=$($expectedProperties -join ',') actual=$($actualProperties -join ',')"
    }

    $expectedDirectory = Join-Path $ExpectedRoot "bin/projects/$ExpectedName"
    if ([string]$Value.projectName -ne $ExpectedName -or [int]$Value.modelVersion -ne 1) {
        throw "ProjectSessionInfo identity mismatch: expected=$ExpectedName/1 actual=$($Value.projectName)/$($Value.modelVersion)"
    }
    Assert-NormalizedPath ([string]$Value.packageRoot) $ExpectedRoot 'packageRoot'
    Assert-NormalizedPath ([string]$Value.projectDirectory) $expectedDirectory 'projectDirectory'
    Assert-NormalizedPath ([string]$Value.scenePath) (Join-Path $expectedDirectory 'scene.json') 'scenePath'
    Assert-NormalizedPath ([string]$Value.scriptPath) (Join-Path $expectedDirectory 'script.json') 'scriptPath'
    Assert-NormalizedPath ([string]$Value.previewPath) (Join-Path $expectedDirectory 'preview.json') 'previewPath'
}

$ownsFixture = $false
$serviceProcess = $null
try {
    # 关键 ownership 前置：先排他创建 GUID 根，后续所有 fixture 写入和清理都限定在该根内。
    if (Test-Path -LiteralPath $fixtureRoot) { throw "Verifier fixture unexpectedly exists: $fixtureRoot" }
    New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
    $ownsFixture = $true

    $projectName = 'preexisting_project'
    $projectDirectory = Join-Path $fixtureRoot "bin/projects/$projectName"
    New-Item -ItemType Directory -Path $projectDirectory -Force | Out-Null
    $sentinelPath = Join-Path $projectDirectory 'ownership-sentinel.bin'
    [IO.File]::WriteAllBytes($sentinelPath, [byte[]](0x4b, 0x41, 0x44, 0x41, 0x54, 0x48, 0x2d, 0x43, 0x52, 0x45, 0x41, 0x54, 0x45))

    $treeBefore = @(Get-TreeIdentity $projectDirectory)
    $sentinelHashBefore = (Get-FileHash -LiteralPath $sentinelPath -Algorithm SHA256).Hash

    # 关键契约：业务结果只由退出码判定；stdout/stderr 仅在失败报告中作为诊断展示。
    $adapterDiagnostics = @(& pwsh -NoProfile -File $author -Action Create -PackageRoot $fixtureRoot -ProjectName $projectName 2>&1)
    $actualExitCode = $LASTEXITCODE

    $treeAfter = @(Get-TreeIdentity $projectDirectory)
    $sentinelHashAfter = if (Test-Path -LiteralPath $sentinelPath -PathType Leaf) {
        (Get-FileHash -LiteralPath $sentinelPath -Algorithm SHA256).Hash
    }
    else {
        '<missing>'
    }

    $failures = [Collections.Generic.List[string]]::new()
    if ($actualExitCode -ne $ProjectAlreadyExistsExitCode) {
        $failures.Add("exit_code expected=$ProjectAlreadyExistsExitCode actual=$actualExitCode")
    }
    if (@(Compare-Object -ReferenceObject $treeBefore -DifferenceObject $treeAfter).Count -ne 0) {
        $failures.Add('preexisting project directory/file set or byte hash changed')
    }
    if ($sentinelHashAfter -ne $sentinelHashBefore) {
        $failures.Add("sentinel hash changed expected=$sentinelHashBefore actual=$sentinelHashAfter")
    }

    if ($failures.Count -ne 0) {
        $diagnosticText = @($adapterDiagnostics | ForEach-Object { $_.ToString() }) -join ' | '
        throw "project_create preexisting contract failed: $($failures -join '; '); adapter_diagnostics=$diagnosticText"
    }

    Write-Output "preexisting_exit_code=$actualExitCode"
    Write-Output 'preexisting_project_immutable=ok'

    $sceneAssets = Join-Path $fixtureRoot 'bin/assets/scenes'
    $scriptAssets = Join-Path $fixtureRoot 'bin/assets/scripts'
    New-Item -ItemType Directory -Path $sceneAssets -Force | Out-Null
    New-Item -ItemType Directory -Path $scriptAssets -Force | Out-Null

    $sceneTemplate = @'
{
  "schemaVersion": 1,
  "player": { "position": [312.0, 130.0], "size": [320.0, 240.0], "color": [1.0, 1.0, 1.0, 1.0], "moveSpeed": 180.0 },
  "goal": { "position": [700.0, 200.0], "size": [96.0, 96.0], "color": [1.0, 0.75, 0.1, 1.0] },
  "hazard": { "position": [650.0, 280.0], "size": [96.0, 96.0], "color": [0.95, 0.2, 0.2, 1.0], "patrolMinY": 245.0, "patrolMaxY": 330.0, "patrolSpeed": 80.0 }
}
'@
    $scriptTemplate = @'
{
  "schemaVersion": 1,
  "instructions": [
    { "hook": "on_start", "op": "set_goal_position", "value": [680.0, 200.0] },
    { "hook": "fixed_update", "op": "move_goal_velocity", "value": [-12.0, 0.0] }
  ]
}
'@
    # 48 KiB whitespace 在放大并发写入窗口的同时，保证完整 Scene 仍低于 Runtime 文档的 64 KiB 预算。
    [IO.File]::WriteAllText((Join-Path $sceneAssets 'preview.scene.json'), $sceneTemplate + (' ' * $SceneTemplatePaddingBytes), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $scriptAssets 'preview.script.json'), $scriptTemplate, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'bin/kadath.exe'), 'verifier runtime placeholder', [Text.UTF8Encoding]::new($false))

    $projectsRoot = Join-Path $fixtureRoot 'bin/projects'
    for ($attempt = 1; $attempt -le $ConcurrentAttemptLimit; $attempt++) {
        $concurrentProjectName = "concurrent_$($attempt.ToString('00'))_$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
        $concurrentProject = Join-Path $projectsRoot $concurrentProjectName
        if (Test-Path -LiteralPath $concurrentProject) { throw "Concurrent verifier project unexpectedly exists: $concurrentProject" }
        $projectsBefore = @(Get-ChildItem -LiteralPath $projectsRoot -Force | ForEach-Object { $_.Name } | Sort-Object)

        $coordinationRoot = Join-Path $fixtureRoot "coordination/attempt-$($attempt.ToString('00'))"
        New-Item -ItemType Directory -Path $coordinationRoot -Force | Out-Null
        $gatePath = Join-Path $coordinationRoot 'release.gate'
        $readyPaths = @((Join-Path $coordinationRoot 'worker-a.ready'), (Join-Path $coordinationRoot 'worker-b.ready'))
        $workerA = $null
        $workerB = $null
        try {
            # 关键同步点：两个独立 pwsh 都写出 ready 后，父进程才以同一个 gate 同步释放。
            $workerA = Start-SynchronizedCreateWorker $readyPaths[0] $gatePath $author $fixtureRoot $concurrentProjectName
            $workerB = Start-SynchronizedCreateWorker $readyPaths[1] $gatePath $author $fixtureRoot $concurrentProjectName
            Wait-SynchronizedWorkersReady @($workerA, $workerB) $readyPaths
            [IO.File]::WriteAllText($gatePath, 'go', [Text.UTF8Encoding]::new($false))
            $resultA = Receive-CreateWorker $workerA
            $resultB = Receive-CreateWorker $workerB
        }
        finally {
            foreach ($worker in @($workerA, $workerB)) {
                if ($null -eq $worker) { continue }
                if (-not $worker.HasExited) {
                    $worker.Kill($true)
                    [void]$worker.WaitForExit(5000)
                }
                $worker.Dispose()
            }
        }

        $exitCodes = @($resultA.ExitCode, $resultB.ExitCode) | Sort-Object
        # Validate 也是公开 Adapter seam；其退出码和最终三文件是完整性的唯一判据。
        $validateDiagnostics = @(& pwsh -NoProfile -File $author -Action Validate -PackageRoot $fixtureRoot -ProjectName $concurrentProjectName 2>&1)
        $validateExitCode = $LASTEXITCODE

        $finalFiles = @()
        $finalDirectories = @()
        if (Test-Path -LiteralPath $concurrentProject -PathType Container) {
            $finalFiles = @(Get-ChildItem -LiteralPath $concurrentProject -Force -File -Recurse | ForEach-Object {
                [IO.Path]::GetRelativePath($concurrentProject, $_.FullName).Replace('\', '/')
            } | Sort-Object)
            $finalDirectories = @(Get-ChildItem -LiteralPath $concurrentProject -Force -Directory -Recurse)
        }
        $projectsAfter = @(Get-ChildItem -LiteralPath $projectsRoot -Force | ForEach-Object { $_.Name } | Sort-Object)
        $unexpectedProjectEntries = @($projectsAfter | Where-Object { $_ -notin $projectsBefore -and $_ -ne $concurrentProjectName })

        $raceFailures = [Collections.Generic.List[string]]::new()
        if ($exitCodes.Count -ne 2 -or $exitCodes[0] -ne 0 -or $exitCodes[1] -ne $ProjectAlreadyExistsExitCode) {
            $raceFailures.Add("exit_codes expected=0,$ProjectAlreadyExistsExitCode actual=$($exitCodes -join ',')")
        }
        if ($validateExitCode -ne 0) { $raceFailures.Add("validate_exit expected=0 actual=$validateExitCode") }
        if (($finalFiles -join '|') -ne 'preview.json|scene.json|script.json' -or $finalDirectories.Count -ne 0) {
            $raceFailures.Add("final_project expected=three-files actual=$($finalFiles -join ',') directories=$($finalDirectories.Count)")
        }
        if ($unexpectedProjectEntries.Count -ne 0) {
            $raceFailures.Add("staging_or_half_entries=$($unexpectedProjectEntries -join ',')")
        }

        Write-Output "concurrent_attempt=$attempt/$ConcurrentAttemptLimit exit_codes=$($exitCodes -join ',') validate_exit=$validateExitCode"
        if ($raceFailures.Count -ne 0) {
            $workerDiagnostics = @($resultA.Stderr, $resultB.Stderr, ($validateDiagnostics | ForEach-Object { $_.ToString() })) -join ' | '
            throw "project_create concurrent contract failed: $($raceFailures -join '; '); diagnostics=$workerDiagnostics"
        }

        # 每次通过后只删除本 verifier 所有 fixture 内的该项目，再使用新名字继续有限重试。
        Remove-Item -LiteralPath $concurrentProject -Recurse -Force
        Remove-Item -LiteralPath $coordinationRoot -Recurse -Force
    }

    Write-Output "concurrent_attempts=$ConcurrentAttemptLimit"
    Write-Output 'concurrent_create_atomic=ok'

    $worktreeRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
    $serviceDll = Join-Path $worktreeRoot 'editor/Kadath.Editor.Service/bin/Debug/net8.0/Kadath.Editor.Service.dll'
    if (-not (Test-Path -LiteralPath $serviceDll -PathType Leaf)) { throw "Editor Service is not built: $serviceDll" }

    # 关键 Core seam tracer：使用 net8 reference pack 编译内存 fake，不新增 csproj 或持久化测试程序集。
    $serviceBin = [IO.Path]::GetDirectoryName($serviceDll)
    $coreDll = Join-Path $serviceBin 'Kadath.Editor.Core.dll'
    $protocolDll = Join-Path $serviceBin 'Kadath.Editor.Protocol.dll'
    foreach ($assemblyPath in @($coreDll, $protocolDll)) {
        if (-not (Test-Path -LiteralPath $assemblyPath -PathType Leaf)) {
            throw "Core mutation-gate dependency is not built: $assemblyPath"
        }
    }

    $dotnetRoot = [IO.Path]::GetDirectoryName((Get-Command dotnet -ErrorAction Stop).Source)
    $net8Pack = Get-ChildItem -LiteralPath (Join-Path $dotnetRoot 'packs/Microsoft.NETCore.App.Ref') -Directory |
        Where-Object Name -Like '8.*' |
        Sort-Object { [version]$_.Name } -Descending |
        Select-Object -First 1
    if ($null -eq $net8Pack) { throw 'Microsoft.NETCore.App.Ref 8.x is required for the Core mutation-gate tracer.' }

    $referenceAssemblies = @(
        Get-ChildItem -LiteralPath (Join-Path $net8Pack.FullName 'ref/net8.0') -Filter '*.dll' |
            ForEach-Object { $_.FullName }
    ) + @($protocolDll, $coreDll)
    # 先加载 Protocol 再加载 Core，保证运行时解析顺序与项目依赖方向一致。
    [void][Reflection.Assembly]::LoadFrom($protocolDll)
    [void][Reflection.Assembly]::LoadFrom($coreDll)

    $projectMutationHarnessSource = @'
using System;
using System.Threading;
using System.Threading.Tasks;
using Kadath.Editor.Core;
using Kadath.Editor.Protocol;

namespace Kadath.Editor.Verification
{
    public sealed class BlockingProjectMutationBackend : IEditorSessionBackend
    {
        private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(5);
        private readonly TaskCompletionSource<bool> _applyEntered = NewSignal();
        private readonly TaskCompletionSource<bool> _createEntered = NewSignal();
        private readonly TaskCompletionSource<bool> _releaseApply = NewSignal();

        public Task ApplyEntered => _applyEntered.Task;
        public Task CreateEntered => _createEntered.Task;

        // 此 tracer 不产生 Backend notification；保留公开 Interface 的完整 event surface。
        public event Func<EditorSessionNotification, Task> Notification
        {
            add { }
            remove { }
        }

        public void ReleaseApply() => _releaseApply.TrySetResult(true);

        public Task<ProjectSessionInfo> OpenProjectAsync(ProjectOpenParameters parameters, CancellationToken cancellationToken) =>
            Task.FromResult(NewProject(parameters.PackageRoot, parameters.ProjectName));

        public Task<ProjectSessionInfo> CreateProjectAsync(ProjectCreateParameters parameters, CancellationToken cancellationToken)
        {
            _createEntered.TrySetResult(true);
            return Task.FromResult(NewProject(parameters.PackageRoot, parameters.ProjectName));
        }

        public async Task<AuthoringMutationResult> ApplyAuthoringAsync(
            ProjectSessionInfo project,
            AuthoringApplyParameters parameters,
            CancellationToken cancellationToken)
        {
            _applyEntered.TrySetResult(true);
            await _releaseApply.Task.WaitAsync(Timeout, cancellationToken).ConfigureAwait(false);
            return NewMutation("apply", project);
        }

        public Task<AuthoringMutationResult> UndoAuthoringAsync(
            ProjectSessionInfo project,
            AuthoringUndoParameters parameters,
            CancellationToken cancellationToken) =>
            Task.FromResult(NewMutation("undo", project));

        public Task<ProjectValidateResult> ValidateProjectAsync(ProjectSessionInfo project, CancellationToken cancellationToken) =>
            Task.FromResult(new ProjectValidateResult("valid", project.ProjectName, Array.Empty<string>()));

        public Task<ProjectModelSnapshot> GetProjectSnapshotAsync(ProjectSessionInfo project, CancellationToken cancellationToken) =>
            Task.FromResult(NewSnapshot(project));

        public Task<HierarchySnapshot> GetHierarchySnapshotAsync(ProjectSessionInfo project, CancellationToken cancellationToken) =>
            Task.FromResult(NewHierarchy(project));

        public Task<AssetCatalogSnapshot> GetAssetCatalogSnapshotAsync(ProjectSessionInfo project, CancellationToken cancellationToken) =>
            Task.FromResult(new AssetCatalogSnapshot(1, "bin/assets", 0, Array.Empty<AssetCatalogItem>()));

        public Task<PublicationSnapshot> GetPublicationSnapshotAsync(
            ProjectSessionInfo project,
            PublicationSnapshotQueryParameters parameters,
            CancellationToken cancellationToken) =>
            Task.FromException<PublicationSnapshot>(new NotSupportedException("Publication is outside this mutation-gate tracer."));

        public Task<EditorBakeResult> BakeAsync(
            ProjectSessionInfo project,
            BakeStartParameters parameters,
            CancellationToken cancellationToken) =>
            Task.FromException<EditorBakeResult>(new NotSupportedException("Bake is outside this mutation-gate tracer."));

        public Task<EditorWatchResult> StartWatchAsync(
            ProjectSessionInfo project,
            WatchStartParameters parameters,
            CancellationToken cancellationToken) =>
            Task.FromException<EditorWatchResult>(new NotSupportedException("Watch is outside this mutation-gate tracer."));

        public Task<EditorWatchResult> StopWatchAsync(CancellationToken cancellationToken) =>
            Task.FromResult(new EditorWatchResult("stopped", string.Empty, "Both", "debug", null));

        public ValueTask DisposeAsync()
        {
            ReleaseApply();
            return ValueTask.CompletedTask;
        }

        private static TaskCompletionSource<bool> NewSignal() =>
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        private static ProjectSessionInfo NewProject(string packageRoot, string projectName)
        {
            var directory = packageRoot.TrimEnd('/', '\\') + "/bin/projects/" + projectName;
            return new ProjectSessionInfo(
                packageRoot,
                projectName,
                directory,
                directory + "/scene.json",
                directory + "/script.json",
                directory + "/preview.json",
                1);
        }

        private static ProjectModelSnapshot NewSnapshot(ProjectSessionInfo project) => new(
            1,
            project.ProjectName,
            new string('1', 64),
            new ProjectModelFiles(project.ProjectDirectory, project.ScenePath, project.ScriptPath, project.PreviewPath),
            new ProjectModelScene(1, new[] { 0d, 0d }),
            new ProjectModelScript(1, new[] { 0d, 0d }, new[] { 0d, 0d }),
            new ProjectModelPreview(1));

        private static HierarchySnapshot NewHierarchy(ProjectSessionInfo project) =>
            new(1, 1, project.ProjectName, Array.Empty<HierarchyNode>());

        private static AuthoringMutationResult NewMutation(string operation, ProjectSessionInfo project) => new(
            operation,
            "succeeded",
            project.ProjectName,
            new string('1', 64),
            new string('2', 64),
            new[] { "scene.goal.position" },
            operation == "apply" ? 1 : 0,
            NewSnapshot(project),
            NewHierarchy(project));
    }

    public static class ProjectMutationGateHarness
    {
        private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(5);

        public static async Task VerifyApplyBeforeCreateAsync()
        {
            var backend = new BlockingProjectMutationBackend();
            await using var session = new EditorSession(backend);
            var opened = await session.OpenProjectAsync(
                    new ProjectOpenParameters("C:/package", "A"),
                    "open-A")
                .WaitAsync(Timeout)
                .ConfigureAwait(false);
            Require(
                opened.ProjectName == "A" &&
                session.CurrentProject != null &&
                session.CurrentProject.ProjectName == "A",
                "baseline session A was not committed");

            var events = new string[8];
            var eventCount = 0;
            session.Notification += notification =>
            {
                lock (events)
                {
                    if (eventCount >= events.Length) { throw new InvalidOperationException("event log overflow"); }
                    events[eventCount++] = notification.Event + ":" + notification.RequestId;
                }
                return Task.CompletedTask;
            };

            var applyTask = session.ApplyAuthoringAsync(
                new AuthoringApplyParameters(
                    "A",
                    new string('1', 64),
                    new AuthoringPatch(SceneGoalPosition: new[] { 1d, 2d })),
                "apply-A");
            await backend.ApplyEntered.WaitAsync(Timeout).ConfigureAwait(false);

            var createTask = session.CreateProjectAsync(
                new ProjectCreateParameters("C:/package", "B"),
                "create-B");
            var createEnteredTask = backend.CreateEntered;
            var observation = await Task.WhenAny(
                    createEnteredTask,
                    Task.Delay(TimeSpan.FromMilliseconds(250)))
                .ConfigureAwait(false);

            bool projectCreatedBeforeRelease;
            lock (events)
            {
                projectCreatedBeforeRelease = Contains(events, eventCount, "project_created:create-B");
            }
            var createEnteredBeforeRelease = ReferenceEquals(observation, createEnteredTask) && createEnteredTask.IsCompleted;
            var createCompletedBeforeRelease = createTask.IsCompleted;
            var currentProjectBeforeRelease = session.CurrentProject == null ? "<null>" : session.CurrentProject.ProjectName;

            // 先记录全部 pre-release 事实，再释放并回收任务；RED 也不能泄漏后台工作。
            backend.ReleaseApply();
            await Task.WhenAll(applyTask, createTask).WaitAsync(Timeout).ConfigureAwait(false);

            Require(!createEnteredBeforeRelease, "Create entered Backend while Apply(A) was blocked");
            Require(!createCompletedBeforeRelease, "Create completed while Apply(A) was blocked");
            Require(!projectCreatedBeforeRelease, "project_created was emitted while Apply(A) was blocked");
            Require(currentProjectBeforeRelease == "A", "CurrentProject changed before Apply(A) completed: " + currentProjectBeforeRelease);

            lock (events)
            {
                Require(
                    eventCount == 3 &&
                    events[0] == "authoring_apply_started:apply-A" &&
                    events[1] == "authoring_apply_completed:apply-A" &&
                    events[2] == "project_created:create-B",
                    "mutation event order mismatch: " + string.Join(",", events));
            }
            Require(session.CurrentProject != null && session.CurrentProject.ProjectName == "B", "Create(B) did not become the final session");
        }

        private static bool Contains(string[] values, int count, string expected)
        {
            for (var index = 0; index < count; index++)
            {
                if (values[index] == expected) { return true; }
            }
            return false;
        }

        private static void Require(bool condition, string message)
        {
            if (!condition) { throw new InvalidOperationException("project_mutation_gate=failed: " + message); }
        }
    }
}
'@

    $harnessTypes = @(
        Add-Type `
            -TypeDefinition $projectMutationHarnessSource `
            -Language CSharp `
            -ReferencedAssemblies $referenceAssemblies `
            -IgnoreWarnings `
            -WarningAction SilentlyContinue `
            -PassThru
    )
    $projectMutationHarnessType = $harnessTypes |
        Where-Object FullName -eq 'Kadath.Editor.Verification.ProjectMutationGateHarness'
    if ($null -eq $projectMutationHarnessType) { throw 'Project mutation-gate harness type was not compiled.' }

    $rpcProjectName = "rpc_create_$([Guid]::NewGuid().ToString('N').Substring(0, 12))"
    $rpcProjectDirectory = Join-Path $projectsRoot $rpcProjectName
    if (Test-Path -LiteralPath $rpcProjectDirectory) { throw "RPC verifier project unexpectedly exists: $rpcProjectDirectory" }

    $script:rpcMessages = [Collections.Generic.List[object]]::new()
    $script:rpcSequence = 0L
    $script:rpcStage = 'startup'
    $serviceShutdownComplete = $false
    try {
        $serviceStart = [Diagnostics.ProcessStartInfo]::new()
        $serviceStart.FileName = 'dotnet'
        $serviceStart.WorkingDirectory = Join-Path $worktreeRoot 'editor'
        $serviceStart.UseShellExecute = $false
        $serviceStart.CreateNoWindow = $true
        $serviceStart.RedirectStandardInput = $true
        $serviceStart.RedirectStandardOutput = $true
        $serviceStart.RedirectStandardError = $true
        $serviceStart.ArgumentList.Add($serviceDll)
        $serviceStart.ArgumentList.Add('--kadath-root')
        $serviceStart.ArgumentList.Add($worktreeRoot)
        $serviceProcess = [Diagnostics.Process]::new()
        $serviceProcess.StartInfo = $serviceStart
        if (-not $serviceProcess.Start()) { throw 'Failed to start Editor Service.' }

        $hello = Read-RpcMessage $serviceProcess
        if ([string]$hello.type -ne 'hello' -or [string]$hello.protocol -ne 'kadath-editor-rpc' -or [int]$hello.schemaVersion -ne 1) {
            throw "Editor Service hello mismatch: $($hello | ConvertTo-Json -Compress -Depth 4)"
        }
        Send-RpcJson $serviceProcess ([ordered]@{ schemaVersion = 1; type = 'hello_ack'; client = 'verify-editor-project-create'; clientVersion = '1' })

        $script:rpcStage = 'get_capabilities'
        Send-RpcJson $serviceProcess ([ordered]@{ schemaVersion = 1; type = 'request'; id = 'create-caps-1'; method = 'get_capabilities'; params = $null })
        $capabilities = Read-RpcMessage $serviceProcess
        if ([string]$capabilities.type -ne 'response' -or [string]$capabilities.id -ne 'create-caps-1' -or -not [bool]$capabilities.ok) {
            throw "get_capabilities response mismatch: $($capabilities | ConvertTo-Json -Compress -Depth 5)"
        }
        if (@($capabilities.result.commands) -notcontains 'project_create') {
            throw "project_create capability missing: commands=$(@($capabilities.result.commands) -join ',')"
        }

        $script:rpcStage = 'project_create'
        Send-RpcJson $serviceProcess ([ordered]@{
            schemaVersion = 1
            type = 'request'
            id = 'create-rpc-1'
            method = 'project_create'
            params = [ordered]@{ packageRoot = $fixtureRoot; projectName = $rpcProjectName }
        })

        # 关键 JSONL 顺序：不得用“读到目标为止”的循环吞掉提前到达的 response。
        $createdEvent = Read-RpcMessage $serviceProcess
        if ([string]$createdEvent.type -ne 'event' -or [string]$createdEvent.event -ne 'project_created' -or [string]$createdEvent.requestId -ne 'create-rpc-1') {
            throw "project_created must precede response: actual=$($createdEvent | ConvertTo-Json -Compress -Depth 6)"
        }
        $createdResponse = Read-RpcMessage $serviceProcess
        if ([string]$createdResponse.type -ne 'response' -or [string]$createdResponse.id -ne 'create-rpc-1' -or -not [bool]$createdResponse.ok) {
            throw "project_create response mismatch: $($createdResponse | ConvertTo-Json -Compress -Depth 6)"
        }

        Assert-ProjectSessionInfo $createdEvent.data $fixtureRoot $rpcProjectName
        Assert-ProjectSessionInfo $createdResponse.result $fixtureRoot $rpcProjectName
        foreach ($property in @('packageRoot', 'projectName', 'projectDirectory', 'scenePath', 'scriptPath', 'previewPath', 'modelVersion')) {
            if ([string]$createdEvent.data.$property -ne [string]$createdResponse.result.$property) {
                throw "project_created/result mismatch: property=$property event=$($createdEvent.data.$property) response=$($createdResponse.result.$property)"
            }
        }

        # 最终完整性仍从公开 Validate seam 观察，不读取 Service 或 Adapter 内部状态。
        $rpcValidateDiagnostics = @(& pwsh -NoProfile -File $author -Action Validate -PackageRoot $fixtureRoot -ProjectName $rpcProjectName 2>&1)
        $rpcValidateExitCode = $LASTEXITCODE
        if ($rpcValidateExitCode -ne 0) {
            throw "RPC-created project Validate failed: exit=$rpcValidateExitCode diagnostics=$(@($rpcValidateDiagnostics | ForEach-Object { $_.ToString() }) -join ' | ')"
        }

        $script:rpcStage = 'shutdown'
        Send-RpcJson $serviceProcess ([ordered]@{ schemaVersion = 1; type = 'request'; id = 'create-shutdown-1'; method = 'shutdown'; params = $null })
        $shutdownResponse = Read-RpcMessage $serviceProcess
        $shutdownEvent = Read-RpcMessage $serviceProcess
        if ([string]$shutdownResponse.type -ne 'response' -or [string]$shutdownResponse.id -ne 'create-shutdown-1' -or -not [bool]$shutdownResponse.ok -or
            [string]$shutdownEvent.type -ne 'event' -or [string]$shutdownEvent.event -ne 'service_stopping' -or [string]$shutdownEvent.requestId -ne 'create-shutdown-1') {
            throw 'Editor Service shutdown envelope mismatch.'
        }
        if (-not $serviceProcess.WaitForExit(10000)) { throw 'Editor Service did not exit after shutdown.' }
        $serviceShutdownComplete = $true

        Write-Output 'rpc_project_create_capability=ok'
        Write-Output 'rpc_project_created_before_response=ok'
        Write-Output 'rpc_project_session_info=ok'
        Write-Output 'rpc_project_create_validate=ok'
    }
    finally {
        if ($null -ne $serviceProcess) {
            if (-not $serviceProcess.HasExited) {
                if (-not $serviceShutdownComplete) {
                    try {
                        # 失败路径也先请求正常 shutdown；只有有界等待失败时才终止进程树。
                        Send-RpcJson $serviceProcess ([ordered]@{ schemaVersion = 1; type = 'request'; id = 'create-cleanup-shutdown'; method = 'shutdown'; params = $null })
                        $serviceProcess.StandardInput.Close()
                    }
                    catch { }
                }
                if (-not $serviceProcess.WaitForExit(5000)) {
                    $serviceProcess.Kill($true)
                    [void]$serviceProcess.WaitForExit(5000)
                }
            }
            $serviceProcess.Dispose()
            $serviceProcess = $null
        }
    }

    $fakeKadathRoot = Join-Path $fixtureRoot 'fake-kadath-root'
    $fakeToolsRoot = Join-Path $fakeKadathRoot 'tools'
    New-Item -ItemType Directory -Path $fakeToolsRoot | Out-Null
    $fakePreview = @'
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $true)]
    [string]$PackageRoot,

    [switch]$StructuredStatus,
    [int]$StopAfterMilliseconds = 0,
    [int]$ReloadScriptAfterMilliseconds = 0,
    [switch]$WatchChanges,
    [int]$PollIntervalMilliseconds = 100,
    [int]$DebounceMilliseconds = 250,
    [switch]$LiveBake,
    [string]$BakeProfile = 'debug',
    [string]$DerivedDirectory = ''
)

$fakeRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runMarker = Join-Path $fakeRoot 'preview-run.marker'
if (Test-Path -LiteralPath $runMarker -PathType Leaf) {
    # 运行模式只在显式 preview_stop 杀死 Launcher 后退出，并产生一条可交错的 preview_status。
    Write-Output '{"origin":"fake-preview","state":"running"}'
    while ($true) { Start-Sleep -Milliseconds 50 }
}

# 失败模式同时产生 stdout/status 与 stderr/log，随后立即以非零退出触发 requested=false。
Write-Output '{"origin":"fake-preview","state":"exiting"}'
[Console]::Error.WriteLine('injected unrequested Preview exit')
exit 23
'@
    [IO.File]::WriteAllText((Join-Path $fakeToolsRoot 'editor-preview.ps1'), $fakePreview, [Text.UTF8Encoding]::new($false))
    $previewRunMarker = Join-Path $fakeKadathRoot 'preview-run.marker'
    $missingLiveBakeAdapter = Join-Path $fakeToolsRoot 'editor-live-bake.ps1'
    if (Test-Path -LiteralPath $missingLiveBakeAdapter) {
        throw "Failed-watch fixture must omit the live-bake Adapter: $missingLiveBakeAdapter"
    }
    $fakeAuthor = @'
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Create', 'Validate')]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [string]$PackageRoot,

    [Parameter(Mandatory = $true)]
    [string]$ProjectName,

    [string]$OwnershipToken
)

$projectDirectory = Join-Path $PackageRoot "bin/projects/$ProjectName"
if ($Action -eq 'Create') {
    New-Item -ItemType Directory -Path $projectDirectory -ErrorAction Stop | Out-Null
    foreach ($name in @('scene.json', 'script.json', 'preview.json')) {
        [IO.File]::WriteAllText((Join-Path $projectDirectory $name), '{"schemaVersion":1}', [Text.UTF8Encoding]::new($false))
    }
    if (-not [string]::IsNullOrWhiteSpace($OwnershipToken)) {
        [IO.File]::WriteAllText((Join-Path $projectDirectory '.kadath-create-claim'), $OwnershipToken, [Text.UTF8Encoding]::new($false))
    }
    exit 0
}

if ($ProjectName -like 'foreign_claim_*') {
    # 关键敌对边界：模拟 Validate 期间 ownership 被另一方接管，并留下必须保留的外部内容。
    [IO.File]::WriteAllText((Join-Path $projectDirectory '.kadath-create-claim'), 'foreign-owner', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $projectDirectory 'foreign-owner-sentinel.txt'), 'preserve-foreign-owner', [Text.UTF8Encoding]::new($false))
    [Console]::Error.WriteLine('injected validation failure after ownership transfer')
    exit 1
}

if ($ProjectName -like 'rollback_*') {
    [Console]::Error.WriteLine('injected post-create validation failure')
    exit 1
}
Write-Output 'validation=ok'
exit 0
'@
    [IO.File]::WriteAllText((Join-Path $fakeToolsRoot 'editor-author.ps1'), $fakeAuthor, [Text.UTF8Encoding]::new($false))

    $rollbackProjectName = "rollback_$([Guid]::NewGuid().ToString('N').Substring(0, 12))"
    $rollbackProjectDirectory = Join-Path $projectsRoot $rollbackProjectName
    $foreignProjectName = "foreign_claim_$([Guid]::NewGuid().ToString('N').Substring(0, 12))"
    $foreignProjectDirectory = Join-Path $projectsRoot $foreignProjectName
    $foreignClaimPath = Join-Path $foreignProjectDirectory '.kadath-create-claim'
    $foreignSentinelPath = Join-Path $foreignProjectDirectory 'foreign-owner-sentinel.txt'
    $failedWatchProjectName = "watch_failed_create_$([Guid]::NewGuid().ToString('N').Substring(0, 12))"
    $failedWatchProjectDirectory = Join-Path $projectsRoot $failedWatchProjectName
    $failedPreviewProjectName = "preview_failed_create_$([Guid]::NewGuid().ToString('N').Substring(0, 12))"
    $failedPreviewProjectDirectory = Join-Path $projectsRoot $failedPreviewProjectName
    $runningPreviewProjectName = "preview_running_create_$([Guid]::NewGuid().ToString('N').Substring(0, 12))"
    $runningPreviewProjectDirectory = Join-Path $projectsRoot $runningPreviewProjectName
    $rollbackService = $null
    try {
        # 关键 boundary fake：Create 成功但后续 Validate 失败，只观察真实 RPC 与最终文件系统回滚。
        $rollbackStart = [Diagnostics.ProcessStartInfo]::new()
        $rollbackStart.FileName = 'dotnet'
        $rollbackStart.WorkingDirectory = Join-Path $worktreeRoot 'editor'
        $rollbackStart.UseShellExecute = $false
        $rollbackStart.CreateNoWindow = $true
        $rollbackStart.RedirectStandardInput = $true
        $rollbackStart.RedirectStandardOutput = $true
        $rollbackStart.RedirectStandardError = $true
        $rollbackStart.ArgumentList.Add($serviceDll)
        $rollbackStart.ArgumentList.Add('--kadath-root')
        $rollbackStart.ArgumentList.Add($fakeKadathRoot)
        $rollbackService = [Diagnostics.Process]::new()
        $rollbackService.StartInfo = $rollbackStart
        if (-not $rollbackService.Start()) { throw 'Failed to start rollback Editor Service.' }

        $script:rpcMessages.Clear()
        $script:rpcSequence = 0L
        $script:rpcStage = 'rollback_hello'
        $rollbackHello = Read-RpcMessage $rollbackService
        if ([string]$rollbackHello.type -ne 'hello') { throw 'Rollback Service hello mismatch.' }
        Send-RpcJson $rollbackService ([ordered]@{ schemaVersion = 1; type = 'hello_ack'; client = 'verify-editor-project-create-rollback'; clientVersion = '1' })

        # 先建立已提交 session；失败 Create 后无参 Validate 必须仍指向该 session。
        $script:rpcStage = 'rollback_baseline_open'
        Send-RpcJson $rollbackService ([ordered]@{
            schemaVersion = 1; type = 'request'; id = 'rollback-open-1'; method = 'project_open'
            params = [ordered]@{ packageRoot = $fixtureRoot; projectName = $rpcProjectName }
        })
        $rollbackOpenedEvent = Read-RpcMessage $rollbackService
        $rollbackOpenedResponse = Read-RpcMessage $rollbackService
        if ([string]$rollbackOpenedEvent.event -ne 'project_opened' -or -not [bool]$rollbackOpenedResponse.ok) {
            throw 'Rollback baseline project_open failed.'
        }

        $script:rpcStage = 'rollback_project_create'
        Send-RpcJson $rollbackService ([ordered]@{
            schemaVersion = 1; type = 'request'; id = 'rollback-create-1'; method = 'project_create'
            params = [ordered]@{ packageRoot = $fixtureRoot; projectName = $rollbackProjectName }
        })
        $rollbackFailure = Read-RpcMessage $rollbackService
        if ([string]$rollbackFailure.type -ne 'response' -or [string]$rollbackFailure.id -ne 'rollback-create-1' -or
            [bool]$rollbackFailure.ok -or [string]$rollbackFailure.error.code -ne 'project_validation_failed') {
            throw "project_validation_failed response mismatch: $($rollbackFailure | ConvertTo-Json -Compress -Depth 6)"
        }
        if (Test-Path -LiteralPath $rollbackProjectDirectory) {
            throw "Service retained a post-validation-failure project directory: $rollbackProjectDirectory"
        }

        $script:rpcStage = 'rollback_session_validate'
        Send-RpcJson $rollbackService ([ordered]@{ schemaVersion = 1; type = 'request'; id = 'rollback-validate-1'; method = 'project_validate'; params = [ordered]@{} })
        $rollbackValidatedEvent = Read-RpcMessage $rollbackService
        $rollbackValidatedResponse = Read-RpcMessage $rollbackService
        if ([string]$rollbackValidatedEvent.event -ne 'project_validated' -or -not [bool]$rollbackValidatedResponse.ok -or
            [string]$rollbackValidatedResponse.result.projectName -ne $rpcProjectName) {
            throw 'Failed Create replaced the previously committed session.'
        }

        # 第二个 Create 模拟 claim 在 Validate 中转移；Service 只能报错，绝不能清理 foreign owner 的目录。
        $script:rpcStage = 'foreign_claim_project_create'
        Send-RpcJson $rollbackService ([ordered]@{
            schemaVersion = 1; type = 'request'; id = 'foreign-claim-create-1'; method = 'project_create'
            params = [ordered]@{ packageRoot = $fixtureRoot; projectName = $foreignProjectName }
        })
        $foreignFailure = Read-RpcMessage $rollbackService
        if ([string]$foreignFailure.type -ne 'response' -or [string]$foreignFailure.id -ne 'foreign-claim-create-1' -or
            [bool]$foreignFailure.ok -or [string]$foreignFailure.error.code -ne 'project_validation_failed') {
            throw "foreign-claim project_validation_failed response mismatch: $($foreignFailure | ConvertTo-Json -Compress -Depth 6)"
        }
        if (-not (Test-Path -LiteralPath $foreignProjectDirectory -PathType Container) -or
            -not (Test-Path -LiteralPath $foreignClaimPath -PathType Leaf) -or
            -not (Test-Path -LiteralPath $foreignSentinelPath -PathType Leaf)) {
            throw 'Service deleted foreign-owned project content after validation failure.'
        }
        $foreignClaim = [IO.File]::ReadAllText($foreignClaimPath, [Text.UTF8Encoding]::new($false))
        $foreignSentinel = [IO.File]::ReadAllText($foreignSentinelPath, [Text.UTF8Encoding]::new($false))
        if ($foreignClaim -ne 'foreign-owner' -or $foreignSentinel -ne 'preserve-foreign-owner') {
            throw "Service changed foreign-owned project content: claim=$foreignClaim sentinel=$foreignSentinel"
        }

        $script:rpcStage = 'foreign_claim_session_validate'
        Send-RpcJson $rollbackService ([ordered]@{ schemaVersion = 1; type = 'request'; id = 'foreign-claim-validate-1'; method = 'project_validate'; params = [ordered]@{} })
        $foreignValidatedEvent = Read-RpcMessage $rollbackService
        $foreignValidatedResponse = Read-RpcMessage $rollbackService
        if ([string]$foreignValidatedEvent.event -ne 'project_validated' -or -not [bool]$foreignValidatedResponse.ok -or
            [string]$foreignValidatedResponse.result.projectName -ne $rpcProjectName) {
            throw 'Foreign-claim Create failure replaced the previously committed session.'
        }
        $foreignCreatedEvents = @($script:rpcMessages | Where-Object {
            [string]$_.type -eq 'event' -and [string]$_.event -eq 'project_created' -and [string]$_.requestId -eq 'foreign-claim-create-1'
        })
        if ($foreignCreatedEvents.Count -ne 0) { throw 'Foreign-claim Create failure emitted project_created.' }

        # 关键 Failed/unknown 门禁：watch_start 在 Adapter 缺失后必须保持“未知是否仍占用”的忙状态，直到显式 watch_stop。
        $script:rpcStage = 'failed_watch_start'
        Send-RpcJson $rollbackService ([ordered]@{
            schemaVersion = 1; type = 'request'; id = 'failed-watch-start-1'; method = 'watch_start'
            params = [ordered]@{ target = 'Both'; profile = 'debug'; pollIntervalMilliseconds = 50; debounceMilliseconds = 100 }
        })
        $failedWatchStart = Read-RpcMessage $rollbackService
        if ([string]$failedWatchStart.type -ne 'response' -or [string]$failedWatchStart.id -ne 'failed-watch-start-1' -or
            [bool]$failedWatchStart.ok -or [string]$failedWatchStart.error.code -ne 'adapter_missing') {
            throw "Failed watch_start response mismatch: $($failedWatchStart | ConvertTo-Json -Compress -Depth 6)"
        }
        $failedWatchStartedEvents = @($script:rpcMessages | Where-Object {
            [string]$_.type -eq 'event' -and [string]$_.event -eq 'watch_started' -and [string]$_.requestId -eq 'failed-watch-start-1'
        })
        if ($failedWatchStartedEvents.Count -ne 0) { throw 'Failed watch_start emitted watch_started.' }

        $script:rpcStage = 'failed_watch_project_create_busy'
        Send-RpcJson $rollbackService ([ordered]@{
            schemaVersion = 1; type = 'request'; id = 'failed-watch-create-busy-1'; method = 'project_create'
            params = [ordered]@{ packageRoot = $fixtureRoot; projectName = $failedWatchProjectName }
        })
        $failedWatchBusy = Read-RpcMessage $rollbackService
        if ([string]$failedWatchBusy.type -eq 'event' -and [string]$failedWatchBusy.event -eq 'project_created' -and
            [string]$failedWatchBusy.requestId -eq 'failed-watch-create-busy-1') {
            # 当前产品缺口的稳定 RED：消费紧随其后的 response，避免把未读 envelope 误报成 verifier 协议错误。
            $unexpectedCreateResponse = Read-RpcMessage $rollbackService
            $unexpectedDirectoryExists = Test-Path -LiteralPath $failedWatchProjectDirectory
            throw "Watch Failed/unknown gate accepted project_create before watch_stop: response_ok=$([bool]$unexpectedCreateResponse.ok) directory_exists=$unexpectedDirectoryExists"
        }
        if ([string]$failedWatchBusy.type -ne 'response' -or [string]$failedWatchBusy.id -ne 'failed-watch-create-busy-1' -or
            [bool]$failedWatchBusy.ok -or [string]$failedWatchBusy.error.code -ne 'project_create_busy') {
            throw "Failed-watch project_create_busy response mismatch: $($failedWatchBusy | ConvertTo-Json -Compress -Depth 6)"
        }
        $failedWatchCreatedEvents = @($script:rpcMessages | Where-Object {
            [string]$_.type -eq 'event' -and [string]$_.event -eq 'project_created' -and [string]$_.requestId -eq 'failed-watch-create-busy-1'
        })
        if ($failedWatchCreatedEvents.Count -ne 0) { throw 'Failed-watch busy Create emitted project_created.' }
        if (Test-Path -LiteralPath $failedWatchProjectDirectory) { throw 'Failed-watch busy Create created its target directory.' }

        $script:rpcStage = 'failed_watch_stop'
        Send-RpcJson $rollbackService ([ordered]@{ schemaVersion = 1; type = 'request'; id = 'failed-watch-stop-1'; method = 'watch_stop'; params = $null })
        $failedWatchStoppedEvent = Read-RpcMessage $rollbackService
        $failedWatchStoppedResponse = Read-RpcMessage $rollbackService
        if ([string]$failedWatchStoppedEvent.type -ne 'event' -or [string]$failedWatchStoppedEvent.event -ne 'watch_stopped' -or
            [string]$failedWatchStoppedEvent.requestId -ne 'failed-watch-stop-1' -or [string]$failedWatchStoppedEvent.data.state -ne 'stopped') {
            throw "watch_stopped must precede response from Failed state: $($failedWatchStoppedEvent | ConvertTo-Json -Compress -Depth 6)"
        }
        if ([string]$failedWatchStoppedResponse.type -ne 'response' -or [string]$failedWatchStoppedResponse.id -ne 'failed-watch-stop-1' -or
            -not [bool]$failedWatchStoppedResponse.ok -or [string]$failedWatchStoppedResponse.result.state -ne 'stopped') {
            throw "Failed-state watch_stop response mismatch: $($failedWatchStoppedResponse | ConvertTo-Json -Compress -Depth 6)"
        }

        $script:rpcStage = 'failed_watch_project_create_retry'
        Send-RpcJson $rollbackService ([ordered]@{
            schemaVersion = 1; type = 'request'; id = 'failed-watch-create-retry-1'; method = 'project_create'
            params = [ordered]@{ packageRoot = $fixtureRoot; projectName = $failedWatchProjectName }
        })
        $failedWatchRetryEvent = Read-RpcMessage $rollbackService
        $failedWatchRetryResponse = Read-RpcMessage $rollbackService
        if ([string]$failedWatchRetryEvent.type -ne 'event' -or [string]$failedWatchRetryEvent.event -ne 'project_created' -or
            [string]$failedWatchRetryEvent.requestId -ne 'failed-watch-create-retry-1') {
            throw "Retry project_created must precede response: $($failedWatchRetryEvent | ConvertTo-Json -Compress -Depth 6)"
        }
        if ([string]$failedWatchRetryResponse.type -ne 'response' -or [string]$failedWatchRetryResponse.id -ne 'failed-watch-create-retry-1' -or
            -not [bool]$failedWatchRetryResponse.ok) {
            throw "Post-watch_stop project_create retry mismatch: $($failedWatchRetryResponse | ConvertTo-Json -Compress -Depth 6)"
        }
        Assert-ProjectSessionInfo $failedWatchRetryEvent.data $fixtureRoot $failedWatchProjectName
        Assert-ProjectSessionInfo $failedWatchRetryResponse.result $fixtureRoot $failedWatchProjectName

        # A：Launcher 非请求退出后 Preview lifecycle 必须保持 Failed，直到显式 Stop 确认收敛为 Stopped。
        $script:rpcStage = 'failed_preview_start'
        Send-RpcJson $rollbackService ([ordered]@{
            schemaVersion = 1; type = 'request'; id = 'failed-preview-start-1'; method = 'preview_start'
            params = [ordered]@{ projectName = $failedWatchProjectName; pollIntervalMilliseconds = 50; debounceMilliseconds = 100 }
        })
        $failedPreviewStart = Read-PreviewStartExchange $rollbackService 'failed-preview-start-1' $true
        if ([string]$failedPreviewStart.Response.type -ne 'response' -or -not [bool]$failedPreviewStart.Response.ok -or
            [string]$failedPreviewStart.Response.result.state -ne 'starting' -or
            [int]$failedPreviewStart.UnrequestedStop.data.exitCode -eq 0) {
            throw "Unrequested Preview failure exchange mismatch: $($failedPreviewStart | ConvertTo-Json -Compress -Depth 8)"
        }

        $script:rpcStage = 'failed_preview_project_create_busy'
        Send-RpcJson $rollbackService ([ordered]@{
            schemaVersion = 1; type = 'request'; id = 'failed-preview-create-busy-1'; method = 'project_create'
            params = [ordered]@{ packageRoot = $fixtureRoot; projectName = $failedPreviewProjectName }
        })
        $failedPreviewBusyExchange = Read-RpcResponseWithPreviewInterleaving $rollbackService 'failed-preview-create-busy-1'
        $failedPreviewBusy = $failedPreviewBusyExchange.Response
        if ([bool]$failedPreviewBusy.ok -or [string]$failedPreviewBusy.error.code -ne 'project_create_busy') {
            throw "Failed-preview project_create_busy response mismatch: $($failedPreviewBusy | ConvertTo-Json -Compress -Depth 6)"
        }
        $failedPreviewCreatedEvents = @($script:rpcMessages | Where-Object {
            [string]$_.type -eq 'event' -and [string]$_.event -eq 'project_created' -and [string]$_.requestId -eq 'failed-preview-create-busy-1'
        })
        if ($failedPreviewCreatedEvents.Count -ne 0 -or (Test-Path -LiteralPath $failedPreviewProjectDirectory)) {
            throw 'Failed Preview allowed project_created or created its target directory.'
        }

        $script:rpcStage = 'failed_preview_stop'
        Send-RpcJson $rollbackService ([ordered]@{ schemaVersion = 1; type = 'request'; id = 'failed-preview-stop-1'; method = 'preview_stop'; params = $null })
        $failedPreviewStop = Read-RpcResponseWithPreviewInterleaving $rollbackService 'failed-preview-stop-1' $true
        if (-not [bool]$failedPreviewStop.Response.ok -or [string]$failedPreviewStop.Response.result.state -ne 'stopped') {
            throw "Failed-state preview_stop response mismatch: $($failedPreviewStop.Response | ConvertTo-Json -Compress -Depth 6)"
        }

        $script:rpcStage = 'failed_preview_project_create_retry'
        Send-RpcJson $rollbackService ([ordered]@{
            schemaVersion = 1; type = 'request'; id = 'failed-preview-create-retry-1'; method = 'project_create'
            params = [ordered]@{ packageRoot = $fixtureRoot; projectName = $failedPreviewProjectName }
        })
        $failedPreviewRetry = Read-ProjectCreateSuccessWithPreviewInterleaving $rollbackService 'failed-preview-create-retry-1'
        if (-not [bool]$failedPreviewRetry.Response.ok -or -not (Test-Path -LiteralPath $failedPreviewProjectDirectory -PathType Container)) {
            throw "Post-failed-preview-stop Create mismatch: $($failedPreviewRetry.Response | ConvertTo-Json -Compress -Depth 6)"
        }
        Assert-ProjectSessionInfo $failedPreviewRetry.Event.data $fixtureRoot $failedPreviewProjectName
        Assert-ProjectSessionInfo $failedPreviewRetry.Response.result $fixtureRoot $failedPreviewProjectName

        # B：marker 让 Launcher 持续运行；Running 同样阻止 Create，Stop 的 requested=true 终态必须先于成功 response。
        if (Test-Path -LiteralPath $previewRunMarker) { throw "Preview run marker unexpectedly exists: $previewRunMarker" }
        [IO.File]::WriteAllText($previewRunMarker, 'run', [Text.UTF8Encoding]::new($false))
        try {
            $script:rpcStage = 'running_preview_start'
            Send-RpcJson $rollbackService ([ordered]@{
                schemaVersion = 1; type = 'request'; id = 'running-preview-start-1'; method = 'preview_start'
                params = [ordered]@{ projectName = $failedPreviewProjectName; pollIntervalMilliseconds = 50; debounceMilliseconds = 100 }
            })
            $runningPreviewStart = Read-PreviewStartExchange $rollbackService 'running-preview-start-1' $false
            if (-not [bool]$runningPreviewStart.Response.ok -or [string]$runningPreviewStart.Response.result.state -ne 'starting') {
                throw "Running Preview start mismatch: $($runningPreviewStart.Response | ConvertTo-Json -Compress -Depth 6)"
            }

            $script:rpcStage = 'running_preview_project_create_busy'
            Send-RpcJson $rollbackService ([ordered]@{
                schemaVersion = 1; type = 'request'; id = 'running-preview-create-busy-1'; method = 'project_create'
                params = [ordered]@{ packageRoot = $fixtureRoot; projectName = $runningPreviewProjectName }
            })
            $runningPreviewBusyExchange = Read-RpcResponseWithPreviewInterleaving $rollbackService 'running-preview-create-busy-1'
            $runningPreviewBusy = $runningPreviewBusyExchange.Response
            if ([bool]$runningPreviewBusy.ok -or [string]$runningPreviewBusy.error.code -ne 'project_create_busy') {
                throw "Running-preview project_create_busy response mismatch: $($runningPreviewBusy | ConvertTo-Json -Compress -Depth 6)"
            }
            $runningPreviewCreatedEvents = @($script:rpcMessages | Where-Object {
                [string]$_.type -eq 'event' -and [string]$_.event -eq 'project_created' -and [string]$_.requestId -eq 'running-preview-create-busy-1'
            })
            if ($runningPreviewCreatedEvents.Count -ne 0 -or (Test-Path -LiteralPath $runningPreviewProjectDirectory)) {
                throw 'Running Preview allowed project_created or created its target directory.'
            }

            $script:rpcStage = 'running_preview_stop'
            Send-RpcJson $rollbackService ([ordered]@{ schemaVersion = 1; type = 'request'; id = 'running-preview-stop-1'; method = 'preview_stop'; params = $null })
            $runningPreviewStop = Read-RpcResponseWithPreviewInterleaving $rollbackService 'running-preview-stop-1' $true
            if (-not [bool]$runningPreviewStop.Response.ok -or [string]$runningPreviewStop.Response.result.state -ne 'stopped' -or
                $null -eq $runningPreviewStop.RequestedStop) {
                throw "Running preview_stop did not confirm requested stop before response: $($runningPreviewStop | ConvertTo-Json -Compress -Depth 8)"
            }

            $script:rpcStage = 'running_preview_project_create_retry'
            Send-RpcJson $rollbackService ([ordered]@{
                schemaVersion = 1; type = 'request'; id = 'running-preview-create-retry-1'; method = 'project_create'
                params = [ordered]@{ packageRoot = $fixtureRoot; projectName = $runningPreviewProjectName }
            })
            $runningPreviewRetry = Read-ProjectCreateSuccessWithPreviewInterleaving $rollbackService 'running-preview-create-retry-1'
            if (-not [bool]$runningPreviewRetry.Response.ok -or -not (Test-Path -LiteralPath $runningPreviewProjectDirectory -PathType Container)) {
                throw "Post-running-preview-stop Create mismatch: $($runningPreviewRetry.Response | ConvertTo-Json -Compress -Depth 6)"
            }
            Assert-ProjectSessionInfo $runningPreviewRetry.Event.data $fixtureRoot $runningPreviewProjectName
            Assert-ProjectSessionInfo $runningPreviewRetry.Response.result $fixtureRoot $runningPreviewProjectName
        }
        finally {
            if (Test-Path -LiteralPath $previewRunMarker -PathType Leaf) { Remove-Item -LiteralPath $previewRunMarker -Force }
        }

        Send-RpcJson $rollbackService ([ordered]@{ schemaVersion = 1; type = 'request'; id = 'rollback-shutdown-1'; method = 'shutdown'; params = $null })
        [void](Read-RpcMessage $rollbackService)
        [void](Read-RpcMessage $rollbackService)
        if (-not $rollbackService.WaitForExit(10000)) { throw 'Rollback Service did not exit after shutdown.' }

        Write-Output 'rpc_project_create_validation_rollback=ok'
        Write-Output 'rpc_project_create_failure_preserves_session=ok'
        Write-Output 'rpc_project_create_foreign_claim_preserved=ok'
        Write-Output 'rpc_project_create_failed_watch_gate=ok'
        Write-Output 'rpc_project_create_after_failed_watch_stop=ok'
        Write-Output 'rpc_project_create_failed_preview_gate=ok'
        Write-Output 'rpc_project_create_after_failed_preview_stop=ok'
        Write-Output 'rpc_project_create_running_preview_gate=ok'
        Write-Output 'rpc_project_create_after_running_preview_stop=ok'
    }
    finally {
        if ($null -ne $rollbackService) {
            if (-not $rollbackService.HasExited) {
                try { Send-RpcJson $rollbackService ([ordered]@{ schemaVersion = 1; type = 'request'; id = 'rollback-cleanup'; method = 'shutdown'; params = $null }) } catch { }
                if (-not $rollbackService.WaitForExit(5000)) {
                    $rollbackService.Kill($true)
                    [void]$rollbackService.WaitForExit(5000)
                }
            }
            $rollbackService.Dispose()
        }
    }

    # 既有 Adapter/RPC/rollback 全部通过后，最后执行 Core mutation serialization tracer。
    try {
        [void]$projectMutationHarnessType::VerifyApplyBeforeCreateAsync().GetAwaiter().GetResult()
    }
    catch {
        $cause = $_.Exception
        while ($null -ne $cause.InnerException) { $cause = $cause.InnerException }
        throw $cause.Message
    }
    Write-Output 'core_project_mutation_gate=ok'

    Write-Output 'verification=ok'
}
finally {
    if ($null -ne $serviceProcess) {
        if (-not $serviceProcess.HasExited) {
            $serviceProcess.Kill($true)
            [void]$serviceProcess.WaitForExit(5000)
        }
        $serviceProcess.Dispose()
    }
    if ($ownsFixture -and (Test-Path -LiteralPath $fixtureRoot)) {
        $resolvedFixture = (Resolve-Path -LiteralPath $fixtureRoot).Path
        $fixtureItem = Get-Item -LiteralPath $resolvedFixture -Force
        # 关键清理边界：只删除本 verifier 排他创建的非 reparse GUID 根，绝不清理调用方 PackageRoot。
        if (-not [string]::Equals($resolvedFixture, $fixtureRoot, [StringComparison]::OrdinalIgnoreCase) -or
            ($fixtureItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Refusing unsafe verifier cleanup: $resolvedFixture"
        }
        Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
    }
}
