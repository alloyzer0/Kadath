[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$StagingDirectory,

    [Parameter(Mandatory = $true)]
    [string]$DestinationRoot,

    [ValidateSet('debug', 'release')]
    [string]$Profile = 'debug',

    # DryRun 只输出候选包计划，不创建 candidate 目录或 promotion manifest。
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:AssetPromotionCommandVersion = 1
$script:AssetPromotionManifestVersion = 1

function Resolve-AssetPromotionStaging([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "Staging directory does not exist: $Path" }
    $staging = (Resolve-Path -LiteralPath $Path).Path
    $info = Get-Item -LiteralPath $staging
    if (($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Staging directory cannot be a reparse point' }
    if ($staging -match '(?i)[\\/]bin[\\/]assets([\\/]|$)') { throw 'Promotion staging must not be package/bin/assets' }
    return $staging
}

function Resolve-AssetPromotionDestination([string]$Path, [string]$Staging) {
    $destination = [IO.Path]::GetFullPath($Path)
    if ([string]::IsNullOrWhiteSpace($destination) -or $destination -eq [IO.Path]::GetPathRoot($destination)) { throw "Invalid candidate destination: $Path" }
    $stagingPrefix = $Staging.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $destinationPrefix = $destination.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if ($destination.Equals($Staging, [StringComparison]::OrdinalIgnoreCase) -or $destination.StartsWith($stagingPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Candidate destination must not be inside staging: $destination" }
    if ($Staging.StartsWith($destinationPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Candidate destination must not contain staging: $destination" }
    # 关键不可变性边界：Promotion 只创建新 candidate，拒绝任何 Runtime package/assets 路径。
    if ($destination -match '(?i)[\\/]bin[\\/]assets([\\/]|$)') { throw "Candidate destination must not be package/bin/assets: $destination" }
    if (Test-Path -LiteralPath $destination) { throw "Refusing to overwrite existing candidate: $destination" }
    $existingParent = Split-Path -Parent $destination
    while (-not (Test-Path -LiteralPath $existingParent -PathType Container)) {
        $nextParent = Split-Path -Parent $existingParent
        if ([string]::IsNullOrWhiteSpace($nextParent) -or $nextParent -eq $existingParent) { throw "Cannot resolve candidate parent: $destination" }
        $existingParent = $nextParent
    }
    $parentInfo = Get-Item -LiteralPath $existingParent
    if (($parentInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Candidate parent cannot be a reparse point' }
    return $destination
}

function Read-AssetPromotionManifest([string]$Staging) {
    $path = Join-Path $Staging 'asset-tool.manifest.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Asset Tool manifest does not exist: $path" }
    try { $manifest = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json } catch { throw "Failed to parse Asset Tool manifest: $($_.Exception.Message)" }
    if ([int]$manifest.ManifestVersion -ne 1 -or [int]$manifest.CommandVersion -ne 1) { throw 'Promotion requires Asset Tool Manifest v1 / Command v1' }
    if ([string]$manifest.Processing -cne 'passthrough-v1') { throw "Unsupported staging processing: $($manifest.Processing)" }
    $items = @($manifest.Items)
    if ([int]$manifest.ItemCount -ne $items.Count) { throw 'Manifest ItemCount does not match Items' }
    if ($items.Count -eq 0) { throw 'Cannot promote an empty asset staging' }
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $items) {
        $stagedPath = [string]$item.StagedPath
        $sourcePath = [string]$item.SourcePath
        if ([IO.Path]::IsPathRooted($stagedPath) -or -not $stagedPath.StartsWith('assets/', [StringComparison]::Ordinal) -or $sourcePath -cne $stagedPath) { throw "Invalid manifest path: $sourcePath / $stagedPath" }
        if (-not $seen.Add($stagedPath)) { throw "Duplicate manifest path: $stagedPath" }
        $stagedFile = Join-Path $Staging $stagedPath.Replace('/', [IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $stagedFile -PathType Leaf)) { throw "Staged asset does not exist: $stagedPath" }
        $file = Get-Item -LiteralPath $stagedFile
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Staged asset cannot be a reparse point: $stagedPath" }
        if ([long]$item.SizeBytes -ne [long]$file.Length) { throw "Staged asset size mismatch: $stagedPath" }
        $hash = (Get-FileHash -LiteralPath $stagedFile -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($hash -cne [string]$item.Sha256) { throw "Staged asset hash mismatch: $stagedPath" }
    }
    return $manifest
}

function Write-AssetPromotionJsonAtomic([object]$Document, [string]$Path) {
    $temporary = "$Path.tmp.$PID"
    try {
        [IO.File]::WriteAllText($temporary, ($Document | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $Path
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Copy-AssetPromotionFileAtomic([string]$Source, [string]$Destination) {
    $temporary = "$Destination.tmp.$PID"
    try {
        Copy-Item -LiteralPath $Source -Destination $temporary -Force:$false
        Move-Item -LiteralPath $temporary -Destination $Destination
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

$staging = Resolve-AssetPromotionStaging $StagingDirectory
$manifest = Read-AssetPromotionManifest $staging
$destination = Resolve-AssetPromotionDestination $DestinationRoot $staging
$planItems = @($manifest.Items | ForEach-Object {
    [ordered]@{
        AssetId = $_.AssetId
        StagedPath = $_.StagedPath
        DestinationPath = ('bin/' + [string]$_.StagedPath)
        Category = $_.Category
        Extension = $_.Extension
        SizeBytes = $_.SizeBytes
        Sha256 = $_.Sha256
    }
})

if ($DryRun) {
    $plan = [ordered]@{
        CommandVersion = $script:AssetPromotionCommandVersion
        PromotionVersion = $script:AssetPromotionManifestVersion
        Action = 'promote'
        Profile = $Profile
        DryRun = $true
        InputManifest = 'asset-tool.manifest.json'
        CandidateRoot = 'candidate'
        ItemCount = $planItems.Count
        Items = $planItems
    }
    Write-Output ($plan | ConvertTo-Json -Depth 12 -Compress)
    exit 0
}

$createdDestination = $false
try {
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    $createdDestination = $true
    foreach ($item in $planItems) {
        $destinationFile = Join-Path $destination ([string]$item.DestinationPath).Replace('/', [IO.Path]::DirectorySeparatorChar)
        $destinationDirectory = Split-Path -Parent $destinationFile
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
        $sourceFile = Join-Path $staging ([string]$item.StagedPath).Replace('/', [IO.Path]::DirectorySeparatorChar)
        Copy-AssetPromotionFileAtomic $sourceFile $destinationFile
    }
    $promotionManifest = [ordered]@{
        PromotionVersion = $script:AssetPromotionManifestVersion
        CommandVersion = $script:AssetPromotionCommandVersion
        Action = 'promote'
        Profile = $Profile
        CandidateKind = 'asset-payload-v1'
        Processing = 'passthrough-v1'
        InputManifest = 'asset-tool.manifest.json'
        DestinationRoot = 'bin'
        AssetRoot = 'bin/assets'
        ItemCount = $planItems.Count
        Items = $planItems
    }
    $promotionManifestPath = Join-Path $destination 'bin\asset-promotion.manifest.json'
    Write-AssetPromotionJsonAtomic $promotionManifest $promotionManifestPath
    Write-Output 'asset_promotion_command_version=1'
    Write-Output "profile=$Profile"
    Write-Output 'dry_run=false'
    Write-Output "candidate_directory=$destination"
    Write-Output "promotion_manifest=$promotionManifestPath"
    Write-Output "item_count=$($planItems.Count)"
    Write-Output 'verification=ok'
} catch {
    if ($createdDestination -and (Test-Path -LiteralPath $destination)) {
        # 失败只清理本次创建的候选包目录，不触碰 staging、源资产或现有 Runtime package。
        Remove-Item -LiteralPath $destination -Recurse -Force
    }
    throw
}
