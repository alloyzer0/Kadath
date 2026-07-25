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
    [IO.File]::WriteAllText((Join-Path $fakeToolsRoot 'editor-preview.ps1'), "param()`r`n", [Text.UTF8Encoding]::new($false))
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

        Send-RpcJson $rollbackService ([ordered]@{ schemaVersion = 1; type = 'request'; id = 'rollback-shutdown-1'; method = 'shutdown'; params = $null })
        [void](Read-RpcMessage $rollbackService)
        [void](Read-RpcMessage $rollbackService)
        if (-not $rollbackService.WaitForExit(10000)) { throw 'Rollback Service did not exit after shutdown.' }

        Write-Output 'rpc_project_create_validation_rollback=ok'
        Write-Output 'rpc_project_create_failure_preserves_session=ok'
        Write-Output 'rpc_project_create_foreign_claim_preserved=ok'
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
