$script:EditorAssetCatalogVersion = 1
$script:EditorAssetCatalogMaxItems = 4096

function Resolve-EditorAssetCatalogRoot([string]$PackageRoot) {
    if (-not (Test-Path -LiteralPath $PackageRoot -PathType Container)) {
        throw "Package root does not exist: $PackageRoot"
    }
    $package = (Resolve-Path -LiteralPath $PackageRoot).Path
    $bin = Join-Path $package 'bin'
    $assets = Join-Path $bin 'assets'
    if (-not (Test-Path -LiteralPath $assets -PathType Container)) {
        throw "Package asset root does not exist: $assets"
    }
    $assetRoot = (Resolve-Path -LiteralPath $assets).Path
    $packagePrefix = $package.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    # 关键安全边界：Catalog 只能枚举 package/bin/assets，不接受 package 外目录。
    if (-not $assetRoot.StartsWith($packagePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Package asset root escapes package: $assetRoot"
    }
    return [pscustomobject]@{
        PackageRoot = $package
        BinRoot = (Resolve-Path -LiteralPath $bin).Path
        AssetRoot = $assetRoot
    }
}

function Get-EditorAssetCategory([string]$RelativePath) {
    $normalized = $RelativePath.Replace('\', '/').ToLowerInvariant()
    if ($normalized.StartsWith('assets/audio/')) { return 'Audio' }
    if ($normalized.StartsWith('assets/renderer2d/')) { return 'Texture' }
    if ($normalized.StartsWith('assets/scenes/')) { return 'Scene' }
    if ($normalized.StartsWith('assets/scripts/')) { return 'Script' }
    return 'Other'
}

function New-EditorAssetCatalogItem(
    [string]$AssetId,
    [string]$DisplayName,
    [string]$RelativePath,
    [string]$Category,
    [string]$Extension,
    [long]$SizeBytes
) {
    return [pscustomobject]@{
        AssetId = $AssetId
        DisplayName = $DisplayName
        RelativePath = $RelativePath
        Category = $Category
        Extension = $Extension
        SizeBytes = $SizeBytes
        Properties = [ordered]@{
            AssetId = $AssetId
            RelativePath = $RelativePath
            Category = $Category
            Extension = $Extension
            SizeBytes = $SizeBytes
        }
    }
}

function Get-EditorAssetCatalogSnapshot([string]$PackageRoot) {
    $roots = Resolve-EditorAssetCatalogRoot $PackageRoot
    $rootInfo = Get-Item -LiteralPath $roots.AssetRoot
    if (($rootInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Package asset root cannot be a reparse point'
    }

    $directories = @(Get-ChildItem -LiteralPath $roots.AssetRoot -Directory -Recurse -Force)
    foreach ($directory in $directories) {
        if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Asset catalog does not follow reparse points: $($directory.FullName)"
        }
    }

    $files = @(Get-ChildItem -LiteralPath $roots.AssetRoot -File -Recurse -Force)
    if ($files.Count -gt $script:EditorAssetCatalogMaxItems) {
        throw "Asset catalog exceeds item limit: $($files.Count) > $script:EditorAssetCatalogMaxItems"
    }
    [string[]]$paths = @($files | ForEach-Object { $_.FullName })
    [Array]::Sort($paths, [StringComparer]::OrdinalIgnoreCase)

    $assetPrefix = $roots.AssetRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($path in $paths) {
        $file = Get-Item -LiteralPath $path
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Asset catalog does not include reparse points: $path"
        }
        $fullPath = [IO.Path]::GetFullPath($file.FullName)
        if (-not $fullPath.StartsWith($assetPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Asset path escapes package asset root: $fullPath"
        }
        $relativePath = [IO.Path]::GetRelativePath($roots.BinRoot, $fullPath).Replace('\', '/')
        if ([IO.Path]::IsPathRooted($relativePath) -or $relativePath.StartsWith('../', [StringComparison]::Ordinal)) {
            throw "Asset relative path is invalid: $relativePath"
        }
        $assetId = 'asset://' + $relativePath.Substring('assets/'.Length)
        $category = Get-EditorAssetCategory $relativePath
        $extension = $file.Extension.TrimStart('.').ToLowerInvariant()
        $items.Add((New-EditorAssetCatalogItem $assetId $file.Name $relativePath $category $extension $file.Length))
    }

    # Snapshot 不包含时间戳或绝对路径，保证同一分发包的只读投影稳定、可移植。
    return [pscustomobject]@{
        CatalogVersion = $script:EditorAssetCatalogVersion
        Root = 'bin/assets'
        ItemCount = $items.Count
        Items = @($items)
    }
}
