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

$ownsFixture = $false
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
    Write-Output 'verification=ok'
}
finally {
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
