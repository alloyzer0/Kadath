[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackageRoot,

    [string]$ProjectName = "snapshot_verify_$PID"
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = (Resolve-Path -LiteralPath $PackageRoot).Path
$adapter = Join-Path $PSScriptRoot 'editor-snapshot.ps1'
$author = Join-Path $PSScriptRoot 'editor-author.ps1'
$projectsRoot = [IO.Path]::GetFullPath((Join-Path $root 'bin\projects'))
$project = [IO.Path]::GetFullPath((Join-Path $projectsRoot $ProjectName))
$prefix = $projectsRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if (-not $project.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe snapshot verifier project path' }
if (Test-Path -LiteralPath $project) { throw "Snapshot verifier project already exists: $project" }

function Invoke-Snapshot([string]$Target, [switch]$ExpectFailure) {
    $output = @(& pwsh -NoProfile -File $adapter -PackageRoot $root -ProjectName $ProjectName -Target $Target 2>&1 | ForEach-Object { $_.ToString() })
    $exitCode = $LASTEXITCODE
    if ($ExpectFailure) {
        if ($exitCode -eq 0) { throw "Snapshot adapter unexpectedly accepted $Target" }
        return $null
    }
    if ($exitCode -ne 0 -or $output.Count -ne 1) { throw "Snapshot adapter failed $Target`: $($output -join ' | ')" }
    return $output[0] | ConvertFrom-Json
}

function Get-AssetDigest {
    $assets = Join-Path $root 'bin\assets'
    $entries = Get-ChildItem -LiteralPath $assets -File -Recurse | Sort-Object FullName | ForEach-Object {
        "$(($_.FullName.Substring($assets.Length)).Replace('\', '/')):$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)"
    }
    return ($entries -join "`n")
}

try {
    & pwsh -NoProfile -File $author -Action Create -PackageRoot $root -ProjectName $ProjectName | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to create isolated snapshot verifier project' }
    $assetDigestBefore = Get-AssetDigest

    $projectSnapshot = Invoke-Snapshot 'Project'
    if ([int]$projectSnapshot.ModelVersion -ne 1 -or [string]$projectSnapshot.ProjectName -ne $ProjectName) { throw 'Project snapshot contract mismatch' }
    if ([int]$projectSnapshot.Scene.SchemaVersion -ne 2 -or [uint32]$projectSnapshot.Scene.PlayerTextureId -ne 1 -or [uint32]$projectSnapshot.Scene.GoalTextureId -ne 2 -or [uint32]$projectSnapshot.Scene.HazardTextureId -ne 1) { throw 'Project snapshot texture binding mismatch' }

    $hierarchy = Invoke-Snapshot 'Hierarchy'
    if ([int]$hierarchy.SnapshotVersion -ne 1 -or @($hierarchy.Nodes).Count -ne 8) { throw 'Hierarchy snapshot contract mismatch' }
    if (@($hierarchy.Nodes | Where-Object { [string]::IsNullOrEmpty([string]$_.ParentId) }).Count -ne 3) { throw 'Hierarchy roots must use null parentId' }
    foreach ($expected in @(@('scene.player', 1), @('scene.goal', 2), @('scene.hazard', 1))) {
        $node = @($hierarchy.Nodes | Where-Object { [string]$_.Id -ceq [string]$expected[0] })
        if ($node.Count -ne 1 -or [uint32]$node[0].Properties.TextureId -ne [uint32]$expected[1]) { throw "Hierarchy texture binding mismatch: $($expected[0])" }
    }

    $assets = Invoke-Snapshot 'Assets'
    if ([int]$assets.CatalogVersion -ne 1 -or [int]$assets.ItemCount -ne @($assets.Items).Count -or [string]$assets.Root -ne 'bin/assets') { throw 'Asset Catalog snapshot contract mismatch' }
    if (@($assets.Items | Where-Object { [IO.Path]::IsPathRooted([string]$_.RelativePath) -or -not ([string]$_.RelativePath).StartsWith('assets/', [StringComparison]::Ordinal) }).Count -ne 0) { throw 'Asset Catalog emitted an unsafe relative path' }

    $scenePath = Join-Path $project 'scene.json'
    $scene = Get-Content -LiteralPath $scenePath -Raw -Encoding utf8 | ConvertFrom-Json
    $scene.schemaVersion = 3
    [IO.File]::WriteAllText($scenePath, ($scene | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    [void](Invoke-Snapshot 'Project' -ExpectFailure)
    [void](Invoke-Snapshot 'Hierarchy' -ExpectFailure)

    # 关键只读断言：查询成功或失败都不能改变正式 package assets。
    if ((Get-AssetDigest) -ne $assetDigestBefore) { throw 'Snapshot query changed package assets' }

    Write-Output 'project_snapshot=ok'
    Write-Output 'hierarchy_snapshot=ok'
    Write-Output 'asset_catalog_snapshot=ok'
    Write-Output 'schema_rejection=ok'
    Write-Output 'package_assets_immutable=ok'
    Write-Output 'verification=ok'
}
finally {
    if (Test-Path -LiteralPath $project) {
        $resolved = (Resolve-Path -LiteralPath $project).Path
        # 只清理本 verifier 创建且位于 package/bin/projects 下的隔离目录。
        if (-not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing unsafe snapshot verifier cleanup' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
