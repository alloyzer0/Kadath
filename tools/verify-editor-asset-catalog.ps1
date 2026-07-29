[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackageRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$adapter = Join-Path $PSScriptRoot 'editor-asset-catalog.ps1'
if (-not (Test-Path -LiteralPath $adapter -PathType Leaf)) { throw "Asset Catalog adapter does not exist: $adapter" }
. $adapter

$first = Get-EditorAssetCatalogSnapshot $PackageRoot
$second = Get-EditorAssetCatalogSnapshot $PackageRoot
if ([int]$first.CatalogVersion -ne 1) { throw "Unexpected Asset Catalog version: $($first.CatalogVersion)" }
if ([int]$first.ItemCount -ne 12 -or @($first.Items).Count -ne 12) { throw "Expected 12 package assets, got $($first.ItemCount)" }

$expectedPaths = @(
    'assets/audio/lost.audio.wav',
    'assets/audio/lost.wav',
    'assets/audio/won.audio.wav',
    'assets/audio/won.wav',
    'assets/renderer2d/goal.png',
    'assets/renderer2d/goal.texture',
    'assets/renderer2d/test.png',
    'assets/renderer2d/test.texture',
    'assets/scenes/preview.scene',
    'assets/scenes/preview.scene.json',
    'assets/scripts/preview.script',
    'assets/scripts/preview.script.json'
)
$actualPaths = @($first.Items | ForEach-Object { [string]$_.RelativePath })
if (($actualPaths -join "`n") -cne ($expectedPaths -join "`n")) {
    throw "Asset paths are missing or not ordinally sorted: $($actualPaths -join ', ')"
}
$ids = @($first.Items | ForEach-Object { [string]$_.AssetId })
if (@($ids | Select-Object -Unique).Count -ne $ids.Count) { throw 'Asset IDs must be unique' }
foreach ($item in $first.Items) {
    if (-not $item.RelativePath.StartsWith('assets/', [StringComparison]::Ordinal)) { throw "Invalid asset relative path: $($item.RelativePath)" }
    if (-not $item.AssetId.StartsWith('asset://', [StringComparison]::Ordinal)) { throw "Invalid asset ID: $($item.AssetId)" }
    if ($item.PSObject.Properties['PhysicalPath']) { throw 'Portable catalog item must not expose PhysicalPath' }
}

$firstJson = $first | ConvertTo-Json -Depth 8 -Compress
$secondJson = $second | ConvertTo-Json -Depth 8 -Compress
if ($firstJson -cne $secondJson) { throw 'Repeated Asset Catalog snapshots must be byte-equivalent JSON' }

$categorySummary = @($first.Items | Group-Object Category | Sort-Object Name | ForEach-Object { "$($_.Name):$($_.Count)" }) -join ','
if ($categorySummary -cne 'Audio:4,Scene:2,Script:2,Texture:4') { throw "Unexpected asset categories: $categorySummary" }

Write-Output "asset_catalog_version=$($first.CatalogVersion)"
Write-Output "asset_item_count=$($first.ItemCount)"
Write-Output "asset_categories=$categorySummary"
Write-Output 'asset_paths=strictly_sorted'
Write-Output 'asset_ids=unique'
Write-Output 'catalog_repeatability=ok'
Write-Output 'verification=ok'
