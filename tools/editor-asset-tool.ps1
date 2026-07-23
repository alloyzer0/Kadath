[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Import', 'Rebuild')]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [string]$SourceRoot,

    [Parameter(Mandatory = $true)]
    [string]$StagingDirectory,

    # DryRun 只输出版本化计划 JSON，绝不创建 staging 或 manifest 文件。
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:AssetToolCommandVersion = 1
$script:AssetToolManifestVersion = 1
$script:AssetToolMaxItems = 4096
$catalogAdapter = Join-Path $PSScriptRoot 'editor-asset-catalog.ps1'
if (-not (Test-Path -LiteralPath $catalogAdapter -PathType Leaf)) { throw ('Asset Catalog adapter does not exist: ' + $catalogAdapter) }
. $catalogAdapter

function Resolve-AssetToolSourceRoot([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Asset source root does not exist: $Path"
    }
    $root = (Resolve-Path -LiteralPath $Path).Path
    $info = Get-Item -LiteralPath $root
    if (($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Asset source root cannot be a reparse point'
    }
    # 关键边界：Asset Tool 面向源资产，禁止把已生成的 package/bin/assets 当作输入产物再次导入。
    if ($root -match '(?i)[\\/]bin[\\/]assets([\\/]|$)') {
        throw 'Asset source root must not be package/bin/assets'
    }
    return $root
}

function Resolve-AssetToolStagingRoot([string]$Path, [string]$SourceRoot) {
    $staging = [IO.Path]::GetFullPath($Path)
    if ([string]::IsNullOrWhiteSpace($staging) -or $staging -eq [IO.Path]::GetPathRoot($staging)) {
        throw "Invalid staging directory: $Path"
    }
    $sourcePrefix = $SourceRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $stagingPrefix = $staging.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if ($staging.Equals($SourceRoot, [StringComparison]::OrdinalIgnoreCase) -or $staging.StartsWith($sourcePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Staging directory must not be inside source root: $staging"
    }
    if ($SourceRoot.StartsWith($stagingPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Staging directory must not contain source root: $staging"
    }
    # 关键不可变性边界：命令模型不能覆盖 Runtime 正在使用的 bin/assets。
    if ($staging -match '(?i)[\\/]bin[\\/]assets([\\/]|$)') {
        throw "Staging directory must not be package/bin/assets: $staging"
    }
    if (Test-Path -LiteralPath $staging) {
        $info = Get-Item -LiteralPath $staging
        if (-not $info.PSIsContainer) { throw "Staging path is not a directory: $staging" }
        if (($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Staging directory cannot be a reparse point' }
        throw "Refusing to reuse existing staging directory: $staging"
    }
    $existingParent = Split-Path -Parent $staging
    while (-not (Test-Path -LiteralPath $existingParent -PathType Container)) {
        $nextParent = Split-Path -Parent $existingParent
        if ([string]::IsNullOrWhiteSpace($nextParent) -or $nextParent -eq $existingParent) { throw "Cannot resolve staging parent: $staging" }
        $existingParent = $nextParent
    }
    $parentInfo = Get-Item -LiteralPath $existingParent
    if (($parentInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Staging parent cannot be a reparse point' }
    return $staging
}

function Get-AssetToolPlan([string]$SourceRoot) {
    $directories = @(Get-ChildItem -LiteralPath $SourceRoot -Directory -Recurse -Force)
    foreach ($directory in $directories) {
        if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Asset source does not follow reparse points: $($directory.FullName)"
        }
    }
    $files = @(Get-ChildItem -LiteralPath $SourceRoot -File -Recurse -Force)
    if ($files.Count -gt $script:AssetToolMaxItems) {
        throw "Asset source exceeds item limit: $($files.Count) > $script:AssetToolMaxItems"
    }
    [string[]]$relativePaths = @($files | ForEach-Object { [IO.Path]::GetRelativePath($SourceRoot, $_.FullName).Replace('\', '/') })
    [Array]::Sort($relativePaths, [StringComparer]::OrdinalIgnoreCase)
    $sourcePrefix = $SourceRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($relativePath in $relativePaths) {
        $sourcePath = [IO.Path]::GetFullPath((Join-Path $SourceRoot $relativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)))
        if (-not $sourcePath.StartsWith($sourcePrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Asset source path escapes source root: $relativePath" }
        $file = Get-Item -LiteralPath $sourcePath
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Asset source file cannot be a reparse point: $relativePath" }
        $sha256 = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $catalogPath = 'assets/' + $relativePath
        $items.Add([pscustomobject]@{
            AssetId = 'asset://' + $relativePath
            SourcePath = $catalogPath
            StagedPath = $catalogPath
            DisplayName = $file.Name
            Category = Get-EditorAssetCategory $catalogPath
            Extension = $file.Extension.TrimStart('.').ToLowerInvariant()
            SizeBytes = [long]$file.Length
            Sha256 = $sha256
        })
    }
    return @($items)
}

function Write-AssetToolJsonAtomic([object]$Document, [string]$Path) {
    $temporary = "$Path.tmp.$PID"
    try {
        $json = $Document | ConvertTo-Json -Depth 12
        [IO.File]::WriteAllText($temporary, $json, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $Path
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Copy-AssetToolFileAtomic([string]$SourcePath, [string]$DestinationPath) {
    $temporary = "$DestinationPath.tmp.$PID"
    try {
        Copy-Item -LiteralPath $SourcePath -Destination $temporary -Force:$false
        Move-Item -LiteralPath $temporary -Destination $DestinationPath
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

$source = Resolve-AssetToolSourceRoot $SourceRoot
$planItems = @(Get-AssetToolPlan $source)
$staging = Resolve-AssetToolStagingRoot $StagingDirectory $source
if ($DryRun) {
    # Dry-run 输出不携带绝对路径，便于 CI/GUI 以稳定 JSON 消费而不泄露本机布局。
    $plan = [ordered]@{
        CommandVersion = $script:AssetToolCommandVersion
        Action = $Action.ToLowerInvariant()
        DryRun = $true
        SourceRoot = 'assets'
        StagingRoot = 'staging'
        ManifestPath = 'asset-tool.manifest.json'
        ItemCount = $planItems.Count
        Items = @($planItems)
    }
    Write-Output ($plan | ConvertTo-Json -Depth 12 -Compress)
    exit 0
}

$createdStaging = $false
try {
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    $createdStaging = $true
    foreach ($item in $planItems) {
        $destination = Join-Path $staging $item.StagedPath.Replace('/', [IO.Path]::DirectorySeparatorChar)
        $destinationDirectory = Split-Path -Parent $destination
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
        $sourceFile = Join-Path $source $item.SourcePath.Substring('assets/'.Length).Replace('/', [IO.Path]::DirectorySeparatorChar)
        Copy-AssetToolFileAtomic $sourceFile $destination
    }
    $manifest = [ordered]@{
        ManifestVersion = $script:AssetToolManifestVersion
        CommandVersion = $script:AssetToolCommandVersion
        Action = $Action.ToLowerInvariant()
        Processing = 'passthrough-v1'
        SourceRoot = 'assets'
        StagingRoot = 'staging'
        ItemCount = $planItems.Count
        Items = @($planItems | ForEach-Object {
            [ordered]@{
                AssetId = $_.AssetId
                SourcePath = $_.SourcePath
                StagedPath = $_.StagedPath
                Category = $_.Category
                Extension = $_.Extension
                SizeBytes = $_.SizeBytes
                Sha256 = $_.Sha256
            }
        })
    }
    $manifestPath = Join-Path $staging 'asset-tool.manifest.json'
    Write-AssetToolJsonAtomic $manifest $manifestPath
    Write-Output 'asset_tool_command_version=1'
    Write-Output "action=$($Action.ToLowerInvariant())"
    Write-Output 'dry_run=false'
    Write-Output "staging_directory=$staging"
    Write-Output "manifest=$manifestPath"
    Write-Output "item_count=$($planItems.Count)"
    Write-Output 'verification=ok'
} catch {
    if ($createdStaging -and (Test-Path -LiteralPath $staging)) {
        # 失败只清理本次新建且已通过边界检查的 staging，绝不触碰源资产或 package。
        Remove-Item -LiteralPath $staging -Recurse -Force
    }
    throw
}
