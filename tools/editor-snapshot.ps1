[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackageRoot,

    [Parameter(Mandatory = $true)]
    [string]$ProjectName,

    [ValidateSet('Project', 'Hierarchy', 'Assets')]
    [string]$Target = 'Project'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# 这个 adapter 只组合既有只读 snapshot 函数，不创建第二套 Project/Hierarchy/Asset 规则。
. (Join-Path $PSScriptRoot 'editor-project-model.ps1')
. (Join-Path $PSScriptRoot 'editor-asset-catalog.ps1')
function Assert-EditorSnapshotProjectBoundary([string]$Root, [string]$Name) {
    $package = (Resolve-Path -LiteralPath $Root).Path
    $files = Get-EditorProjectFiles $package $Name
    $projects = Join-Path $package 'bin\projects'

    # 关键路径边界：快照查询不能借 junction/symlink 越过当前 package 的项目目录。
    foreach ($path in @($projects, $files.Directory, $files.Scene, $files.Script, $files.Preview)) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $item = Get-Item -LiteralPath $path -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Snapshot project path cannot be a reparse point: $path"
        }
    }
}

function Assert-EditorSnapshotModelVersion([object]$Model) {
    if ([int]$Model.ModelVersion -ne 1 -or
        [int]$Model.Scene.SchemaVersion -ne 1 -or
        [int]$Model.Script.SchemaVersion -ne 1 -or
        [int]$Model.Preview.SchemaVersion -ne 1) {
        throw 'Snapshot project/model schema version is unsupported'
    }
    if (@($Model.Scene.GoalPosition).Count -ne 2 -or
        @($Model.Script.GoalPosition).Count -ne 2 -or
        @($Model.Script.GoalVelocity).Count -ne 2) {
        throw 'Snapshot project vectors must contain exactly two values'
    }
}

switch ($Target) {
    'Project' {
        Assert-EditorSnapshotProjectBoundary $PackageRoot $ProjectName
        $snapshot = Read-EditorProjectModel $PackageRoot $ProjectName
        Assert-EditorSnapshotModelVersion $snapshot
    }
    'Hierarchy' {
        Assert-EditorSnapshotProjectBoundary $PackageRoot $ProjectName
        $model = Read-EditorProjectModel $PackageRoot $ProjectName
        Assert-EditorSnapshotModelVersion $model
        $snapshot = Get-EditorHierarchySnapshot $model
    }
    'Assets' {
        $snapshot = Get-EditorAssetCatalogSnapshot $PackageRoot
    }
}

# stdout 只写一条压缩 JSON；Service 负责把它转换成稳定 Protocol DTO。
$snapshot | ConvertTo-Json -Depth 16 -Compress




