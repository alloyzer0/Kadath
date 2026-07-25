[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackageRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ProjectAlreadyExistsExitCode = 17
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
