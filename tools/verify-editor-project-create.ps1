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

function Assert-PreviewBlocksProjectCreate(
    [Diagnostics.Process]$Process,
    [string]$RequestId,
    [string]$PackageRoot,
    [string]$ProjectName,
    [string]$ProjectDirectory,
    [string]$Context
) {
    Send-RpcJson $Process ([ordered]@{
        schemaVersion = 1; type = 'request'; id = $RequestId; method = 'project_create'
        params = [ordered]@{ packageRoot = $PackageRoot; projectName = $ProjectName }
    })
    $exchange = Read-RpcResponseWithPreviewInterleaving $Process $RequestId
    if ([bool]$exchange.Response.ok -or [string]$exchange.Response.error.code -ne 'project_create_busy') {
        throw "$Context project_create_busy response mismatch: $($exchange.Response | ConvertTo-Json -Compress -Depth 6)"
    }
    $createdEvents = @($script:rpcMessages | Where-Object {
        [string]$_.type -eq 'event' -and [string]$_.event -eq 'project_created' -and [string]$_.requestId -eq $RequestId
    })
    if ($createdEvents.Count -ne 0 -or (Test-Path -LiteralPath $ProjectDirectory)) {
        throw "$Context allowed project_created or created its target directory."
    }
}

function Assert-PreviewCreateAfterStop(
    [Diagnostics.Process]$Process,
    [string]$RequestId,
    [string]$PackageRoot,
    [string]$ProjectName,
    [string]$ProjectDirectory,
    [string]$Context
) {
    # 两个 Preview 终态共用同一成功协议：project_created 必须先于 response，且 DTO identity 完整一致。
    Send-RpcJson $Process ([ordered]@{
        schemaVersion = 1; type = 'request'; id = $RequestId; method = 'project_create'
        params = [ordered]@{ packageRoot = $PackageRoot; projectName = $ProjectName }
    })
    $exchange = Read-ProjectCreateSuccessWithPreviewInterleaving $Process $RequestId
    if (-not [bool]$exchange.Response.ok -or -not (Test-Path -LiteralPath $ProjectDirectory -PathType Container)) {
        throw "$Context Create-after-stop mismatch: $($exchange.Response | ConvertTo-Json -Compress -Depth 6)"
    }
    Assert-ProjectSessionInfo $exchange.Event.data $PackageRoot $ProjectName
    Assert-ProjectSessionInfo $exchange.Response.result $PackageRoot $ProjectName
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
  "schemaVersion": 3,
  "textures": [
    { "textureId": 1, "artifact": "assets/renderer2d/test.texture" },
    { "textureId": 2, "artifact": "assets/renderer2d/goal.texture" },
    { "textureId": 3, "artifact": "assets/renderer2d/goal.texture" }
  ],
  "player": { "position": [312.0, 130.0], "size": [320.0, 240.0], "color": [1.0, 1.0, 1.0, 1.0], "moveSpeed": 180.0, "textureId": 1 },
  "goal": { "position": [700.0, 200.0], "size": [96.0, 96.0], "color": [1.0, 0.75, 0.1, 1.0], "textureId": 2 },
  "hazard": { "position": [650.0, 280.0], "size": [96.0, 96.0], "color": [0.95, 0.2, 0.2, 1.0], "patrolMinY": 245.0, "patrolMaxY": 330.0, "patrolSpeed": 80.0, "textureId": 3 }
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
    $runtimeName = if ($IsWindows) { 'kadath.exe' } else { 'kadath' }
    [IO.File]::WriteAllText((Join-Path $fixtureRoot "bin/$runtimeName"), 'verifier runtime placeholder', [Text.UTF8Encoding]::new($false))

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
            new ProjectModelScene(1, new[] { 0d, 0d }, 1, 2, 1),
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

        $rpcProjectDirectory = Join-Path $fixtureRoot "bin/projects/$rpcProjectName"
        $rpcScenePath = Join-Path $rpcProjectDirectory 'scene.json'
        $rpcPreviewPath = Join-Path $rpcProjectDirectory 'preview.json'
        $rpcSceneBytes = [IO.File]::ReadAllBytes($rpcScenePath)
        [IO.File]::Delete($rpcScenePath)
        $script:rpcStage = 'project_validate_missing_source_error'
        Send-RpcJson $serviceProcess ([ordered]@{ schemaVersion = 1; type = 'request'; id = 'validate-missing-source-1'; method = 'project_validate'; params = [ordered]@{} })
        $missingSourceResponse = Read-RpcMessage $serviceProcess
        [IO.File]::WriteAllBytes($rpcScenePath, $rpcSceneBytes)
        if ([string]$missingSourceResponse.type -ne 'response' -or [string]$missingSourceResponse.id -ne 'validate-missing-source-1' -or
            [bool]$missingSourceResponse.ok -or [string]$missingSourceResponse.error.code -ne 'project_validation_failed') {
            throw "Missing source Validate error mapping mismatch: $($missingSourceResponse | ConvertTo-Json -Compress -Depth 6)"
        }

        $rpcPreviewBytes = [IO.File]::ReadAllBytes($rpcPreviewPath)
        $rpcPreviewText = [Text.Encoding]::UTF8.GetString($rpcPreviewBytes)
        $expectedSceneArgument = "projects/$rpcProjectName/scene.json"
        $invalidPreviewText = $rpcPreviewText.Replace($expectedSceneArgument, '../../outside.json')
        if ($invalidPreviewText -eq $rpcPreviewText) { throw 'RPC Preview fixture did not contain the expected Scene argument.' }
        [IO.File]::WriteAllText($rpcPreviewPath, $invalidPreviewText, [Text.UTF8Encoding]::new($false))
        $script:rpcStage = 'project_validate_preview_escape_error'
        Send-RpcJson $serviceProcess ([ordered]@{ schemaVersion = 1; type = 'request'; id = 'validate-preview-escape-1'; method = 'project_validate'; params = [ordered]@{} })
        $previewEscapeResponse = Read-RpcMessage $serviceProcess
        [IO.File]::WriteAllBytes($rpcPreviewPath, $rpcPreviewBytes)
        if ([string]$previewEscapeResponse.type -ne 'response' -or [string]$previewEscapeResponse.id -ne 'validate-preview-escape-1' -or
            [bool]$previewEscapeResponse.ok -or [string]$previewEscapeResponse.error.code -ne 'project_validation_failed') {
            throw "Preview escape Validate error mapping mismatch: $($previewEscapeResponse | ConvertTo-Json -Compress -Depth 6)"
        }

        $script:rpcStage = 'failed_create_preserves_session'
        Send-RpcJson $serviceProcess ([ordered]@{
            schemaVersion = 1
            type = 'request'
            id = 'create-invalid-name-1'
            method = 'project_create'
            params = [ordered]@{ packageRoot = $fixtureRoot; projectName = '../invalid' }
        })
        $failedCreate = Read-RpcMessage $serviceProcess
        if ([string]$failedCreate.type -ne 'response' -or [string]$failedCreate.id -ne 'create-invalid-name-1' -or
            [bool]$failedCreate.ok -or [string]$failedCreate.error.code -ne 'invalid_project_name') {
            throw "Failed Create error mapping mismatch: $($failedCreate | ConvertTo-Json -Compress -Depth 6)"
        }

        Send-RpcJson $serviceProcess ([ordered]@{ schemaVersion = 1; type = 'request'; id = 'validate-after-failed-create-1'; method = 'project_validate'; params = [ordered]@{} })
        $validatedAfterFailureEvent = Read-RpcMessage $serviceProcess
        $validatedAfterFailureResponse = Read-RpcMessage $serviceProcess
        if ([string]$validatedAfterFailureEvent.event -ne 'project_validated' -or
            [string]$validatedAfterFailureEvent.data.projectName -ne $rpcProjectName -or
            -not [bool]$validatedAfterFailureResponse.ok -or
            [string]$validatedAfterFailureResponse.result.projectName -ne $rpcProjectName) {
            throw 'Failed Create replaced the current Service session.'
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
        Write-Output 'rpc_project_validate_error_mapping=ok'
        Write-Output 'rpc_project_create_failure_preserves_session=ok'
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

    Write-Output 'native_project_lifecycle_workspace_verifier=ok'

    # CLI oracle、真实 RPC 与原生 Workspace verifier 通过后，最后执行 Core mutation serialization tracer。
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
