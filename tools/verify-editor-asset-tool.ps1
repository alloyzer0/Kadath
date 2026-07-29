[CmdletBinding()]
param(
    [string]$SourceRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'assets'),
    [string]$OutputDirectory = (Join-Path $env:TEMP ("kadath-asset-tool-" + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')))
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$tool = Join-Path $PSScriptRoot 'editor-asset-tool.ps1'
if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) { throw "Asset Tool does not exist: $tool" }
if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) { throw "Asset source root does not exist: $SourceRoot" }
$source = (Resolve-Path -LiteralPath $SourceRoot).Path
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $output) { throw "Output directory already exists: $output" }

function Invoke-AssetTool([string[]]$Arguments, [bool]$ExpectSuccess = $true) {
    $result = @(& pwsh -NoProfile -File $tool @Arguments 2>&1 | ForEach-Object { $_.ToString() })
    $exitCode = $LASTEXITCODE
    if ($ExpectSuccess -and $exitCode -ne 0) { throw "Asset Tool failed with code $exitCode`: $($result -join ' | ')" }
    if (-not $ExpectSuccess -and $exitCode -eq 0) { throw 'Asset Tool unexpectedly accepted an invalid command' }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $result }
}

function Get-SourceHashes([string]$Root) {
    $hashes = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -File -Recurse -Force)) {
        $relative = [IO.Path]::GetRelativePath($Root, $file.FullName).Replace('\', '/')
        $hashes[$relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    return $hashes
}

function Assert-StagingManifest([string]$StagingRoot, [string]$ExpectedAction, [hashtable]$SourceHashes) {
    $manifestPath = Join-Path $StagingRoot 'asset-tool.manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Manifest does not exist: $manifestPath" }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json
    if ([int]$manifest.ManifestVersion -ne 1 -or [int]$manifest.CommandVersion -ne 1) { throw 'Unexpected Asset Tool manifest version' }
    if ([string]$manifest.Action -cne $ExpectedAction -or [string]$manifest.Processing -cne 'passthrough-v1') { throw "Unexpected manifest action/processing: $($manifest.Action)/$($manifest.Processing)" }
    if ([string]$manifest.SourceRoot -cne 'assets' -or [string]$manifest.StagingRoot -cne 'staging') { throw 'Manifest roots must be portable logical paths' }
    if ([int]$manifest.ItemCount -ne 6 -or @($manifest.Items).Count -ne 6) { throw "Expected 6 manifest items, got $($manifest.ItemCount)" }
    foreach ($item in @($manifest.Items)) {
        $sourcePath = [string]$item.SourcePath
        $stagedPath = [string]$item.StagedPath
        if (-not $sourcePath.StartsWith('assets/', [StringComparison]::Ordinal) -or $sourcePath -cne $stagedPath) { throw "Invalid manifest item paths: $sourcePath / $stagedPath" }
        if ([IO.Path]::IsPathRooted($sourcePath) -or [IO.Path]::IsPathRooted($stagedPath)) { throw 'Manifest item paths must be relative' }
        $relative = $sourcePath.Substring('assets/'.Length)
        if (-not $SourceHashes.ContainsKey($relative)) { throw "Manifest references unknown source: $sourcePath" }
        $stagedFile = Join-Path $StagingRoot $stagedPath.Replace('/', [IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $stagedFile -PathType Leaf)) { throw "Staged asset does not exist: $stagedPath" }
        $stagedHash = (Get-FileHash -LiteralPath $stagedFile -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($stagedHash -cne [string]$item.Sha256 -or $stagedHash -cne [string]$SourceHashes[$relative]) { throw "Staged asset hash mismatch: $stagedPath" }
        if ($item.PSObject.Properties['PhysicalPath']) { throw 'Manifest must not contain PhysicalPath' }
    }
    return $manifest
}

$beforeHashes = Get-SourceHashes $source
$dryRunStaging = Join-Path $output 'dry-run'
$importStaging = Join-Path $output 'import'
$rebuildStaging = Join-Path $output 'rebuild'
try {
    $dryRun = Invoke-AssetTool @('-Action', 'Import', '-SourceRoot', $source, '-StagingDirectory', $dryRunStaging, '-DryRun')
    $plan = $dryRun.Output[-1] | ConvertFrom-Json
    if ([int]$plan.CommandVersion -ne 1 -or [string]$plan.Action -cne 'import' -or -not [bool]$plan.DryRun) { throw 'Invalid Asset Tool dry-run plan header' }
    if ([int]$plan.ItemCount -ne 6 -or @($plan.Items).Count -ne 6) { throw "Expected 6 dry-run items, got $($plan.ItemCount)" }
    if (Test-Path -LiteralPath $dryRunStaging) { throw 'Dry-run must not create staging output' }

    [void](Invoke-AssetTool @('-Action', 'Import', '-SourceRoot', $source, '-StagingDirectory', $importStaging))
    $importManifest = Assert-StagingManifest $importStaging 'import' $beforeHashes

    [void](Invoke-AssetTool @('-Action', 'Rebuild', '-SourceRoot', $source, '-StagingDirectory', $rebuildStaging))
    $rebuildManifest = Assert-StagingManifest $rebuildStaging 'rebuild' $beforeHashes
    $importItems = $importManifest.Items | ConvertTo-Json -Depth 8 -Compress
    $rebuildItems = $rebuildManifest.Items | ConvertTo-Json -Depth 8 -Compress
    if ($importItems -cne $rebuildItems) { throw 'Import and rebuild manifests must describe identical passthrough artifacts' }

    $invalidInsideSource = Join-Path $source '.asset-tool-invalid'
    [void](Invoke-AssetTool @('-Action', 'Import', '-SourceRoot', $source, '-StagingDirectory', $invalidInsideSource, '-DryRun') $false)
    if (Test-Path -LiteralPath $invalidInsideSource) { throw 'Invalid source-contained staging path was created' }
    $invalidPackageAssets = Join-Path (Split-Path -Parent $output) 'bin\assets\asset-tool-invalid'
    [void](Invoke-AssetTool @('-Action', 'Rebuild', '-SourceRoot', $source, '-StagingDirectory', $invalidPackageAssets, '-DryRun') $false)
    if (Test-Path -LiteralPath $invalidPackageAssets) { throw 'Invalid package asset staging path was created' }

    $afterHashes = Get-SourceHashes $source
    if ($beforeHashes.Count -ne $afterHashes.Count) { throw 'Source asset count changed during Asset Tool verification' }
    foreach ($key in $beforeHashes.Keys) {
        if (-not $afterHashes.ContainsKey($key) -or $beforeHashes[$key] -cne $afterHashes[$key]) { throw "Source asset changed during verification: $key" }
    }

    Write-Output 'asset_tool_command_version=1'
    Write-Output 'asset_tool_manifest_version=1'
    Write-Output 'dry_run=ok'
    Write-Output 'import_staging=ok'
    Write-Output 'rebuild_staging=ok'
    Write-Output 'manifest_hashes=ok'
    Write-Output 'source_immutable=ok'
    Write-Output 'staging_boundary=ok'
    Write-Output 'verification=ok'
} finally {
    if (Test-Path -LiteralPath $output) {
        # verifier 只清理自己创建的隔离输出根。
        Remove-Item -LiteralPath $output -Recurse -Force
    }
}
