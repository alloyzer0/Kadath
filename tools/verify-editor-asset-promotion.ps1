[CmdletBinding()]
param(
    [string]$SourceRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'assets'),
    [string]$OutputDirectory = (Join-Path $env:TEMP ("kadath-asset-promotion-" + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')))
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$assetTool = Join-Path $PSScriptRoot 'editor-asset-tool.ps1'
$promoteTool = Join-Path $PSScriptRoot 'editor-asset-promote.ps1'
if (-not (Test-Path -LiteralPath $assetTool -PathType Leaf)) { throw "Asset Tool does not exist: $assetTool" }
if (-not (Test-Path -LiteralPath $promoteTool -PathType Leaf)) { throw "Promotion Tool does not exist: $promoteTool" }
$source = (Resolve-Path -LiteralPath $SourceRoot).Path
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $output) { throw "Output directory already exists: $output" }

function Invoke-Tool([string]$ScriptPath, [string[]]$Arguments, [bool]$ExpectSuccess = $true) {
    $result = @(& pwsh -NoProfile -File $ScriptPath @Arguments 2>&1 | ForEach-Object { $_.ToString() })
    $exitCode = $LASTEXITCODE
    if ($ExpectSuccess -and $exitCode -ne 0) { throw "Tool failed with code $exitCode`: $($result -join ' | ')" }
    if (-not $ExpectSuccess -and $exitCode -eq 0) { throw 'Tool unexpectedly accepted an invalid promotion request' }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $result }
}

function Get-TreeHashes([string]$Root) {
    $hashes = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -File -Recurse -Force)) {
        $relative = [IO.Path]::GetRelativePath($Root, $file.FullName).Replace('\', '/')
        $hashes[$relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    return $hashes
}

function Assert-Candidate([string]$Candidate, [string]$ExpectedProfile, [hashtable]$StagingHashes) {
    $manifestPath = Join-Path $Candidate 'bin\asset-promotion.manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Promotion manifest missing: $manifestPath" }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json
    if ([int]$manifest.PromotionVersion -ne 1 -or [int]$manifest.CommandVersion -ne 1) { throw 'Unexpected promotion manifest version' }
    if ([string]$manifest.Action -cne 'promote' -or [string]$manifest.Profile -cne $ExpectedProfile) { throw "Unexpected candidate action/profile: $($manifest.Action)/$($manifest.Profile)" }
    if ([string]$manifest.CandidateKind -cne 'asset-payload-v1' -or [string]$manifest.Processing -cne 'passthrough-v1') { throw 'Unexpected candidate processing contract' }
    if ([int]$manifest.ItemCount -ne 6 -or @($manifest.Items).Count -ne 6) { throw "Expected 6 candidate items, got $($manifest.ItemCount)" }
    if (Test-Path -LiteralPath (Join-Path $Candidate 'bin\kadath.exe')) { throw 'Candidate asset payload must not contain Runtime executable' }
    foreach ($item in @($manifest.Items)) {
        $destinationPath = [string]$item.DestinationPath
        if (-not $destinationPath.StartsWith('bin/assets/', [StringComparison]::Ordinal) -or [IO.Path]::IsPathRooted($destinationPath)) { throw "Invalid candidate destination path: $destinationPath" }
        $relativeStaging = [string]$item.StagedPath
        if (-not $StagingHashes.ContainsKey($relativeStaging)) { throw "Candidate references unknown staging asset: $relativeStaging" }
        $candidateFile = Join-Path $Candidate $destinationPath.Replace('/', [IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $candidateFile -PathType Leaf)) { throw "Candidate asset missing: $destinationPath" }
        $hash = (Get-FileHash -LiteralPath $candidateFile -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($hash -cne [string]$item.Sha256 -or $hash -cne [string]$StagingHashes[$relativeStaging]) { throw "Candidate hash mismatch: $destinationPath" }
    }
    return $manifest
}

$staging = Join-Path $output 'staging'
$dryCandidate = Join-Path $output 'candidate-dry-run'
$debugCandidate = Join-Path $output 'candidate-debug'
$releaseCandidate = Join-Path $output 'candidate-release'
try {
    [void](Invoke-Tool $assetTool @('-Action', 'Import', '-SourceRoot', $source, '-StagingDirectory', $staging))
    $stagingHashesBefore = Get-TreeHashes $staging

    $dry = Invoke-Tool $promoteTool @('-StagingDirectory', $staging, '-DestinationRoot', $dryCandidate, '-Profile', 'debug', '-DryRun')
    $plan = $dry.Output[-1] | ConvertFrom-Json
    if ([int]$plan.CommandVersion -ne 1 -or [int]$plan.PromotionVersion -ne 1 -or [string]$plan.Action -cne 'promote' -or [string]$plan.Profile -cne 'debug' -or -not [bool]$plan.DryRun) { throw 'Invalid promotion dry-run plan' }
    if ([int]$plan.ItemCount -ne 6 -or (Test-Path -LiteralPath $dryCandidate)) { throw 'Promotion dry-run must not create candidate output' }

    [void](Invoke-Tool $promoteTool @('-StagingDirectory', $staging, '-DestinationRoot', $debugCandidate, '-Profile', 'debug'))
    $debugManifest = Assert-Candidate $debugCandidate 'debug' $stagingHashesBefore
    [void](Invoke-Tool $promoteTool @('-StagingDirectory', $staging, '-DestinationRoot', $releaseCandidate, '-Profile', 'release'))
    $releaseManifest = Assert-Candidate $releaseCandidate 'release' $stagingHashesBefore
    if (($debugManifest.Items | ConvertTo-Json -Depth 8 -Compress) -cne ($releaseManifest.Items | ConvertTo-Json -Depth 8 -Compress)) { throw 'Debug and release candidate items must be equivalent' }

    $insideStaging = Join-Path $staging 'candidate-inside'
    [void](Invoke-Tool $promoteTool @('-StagingDirectory', $staging, '-DestinationRoot', $insideStaging, '-DryRun') $false)
    if (Test-Path -LiteralPath $insideStaging) { throw 'Invalid staging-contained candidate was created' }
    $runtimeAssets = Join-Path (Split-Path -Parent $output) 'bin\assets'
    [void](Invoke-Tool $promoteTool @('-StagingDirectory', $staging, '-DestinationRoot', $runtimeAssets, '-DryRun') $false)
    $stagingHashesAfter = Get-TreeHashes $staging
    if ($stagingHashesBefore.Count -ne $stagingHashesAfter.Count) { throw 'Staging file count changed during promotion' }
    foreach ($key in $stagingHashesBefore.Keys) {
        if (-not $stagingHashesAfter.ContainsKey($key) -or $stagingHashesBefore[$key] -cne $stagingHashesAfter[$key]) { throw "Staging changed during promotion: $key" }
    }

    Write-Output 'asset_promotion_command_version=1'
    Write-Output 'asset_promotion_manifest_version=1'
    Write-Output 'promotion_dry_run=ok'
    Write-Output 'candidate_debug=ok'
    Write-Output 'candidate_release=ok'
    Write-Output 'candidate_hashes=ok'
    Write-Output 'staging_immutable=ok'
    Write-Output 'runtime_package_immutable=ok'
    Write-Output 'verification=ok'
} finally {
    if (Test-Path -LiteralPath $output) {
        # verifier 只清理自己创建的隔离输出根。
        Remove-Item -LiteralPath $output -Recurse -Force
    }
}
