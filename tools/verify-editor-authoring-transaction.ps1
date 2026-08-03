[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackageRoot,

    [string]$ProjectName = ("authoring-tx-" + [Guid]::NewGuid().ToString('N').Substring(0, 20))
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$package = (Resolve-Path -LiteralPath $PackageRoot).Path
$author = Join-Path $PSScriptRoot 'editor-author.ps1'
$modelAdapter = Join-Path $PSScriptRoot 'editor-project-model.ps1'
. $modelAdapter

$projectDirectory = Join-Path $package "bin/projects/$ProjectName"
$projectsRoot = [IO.Path]::GetFullPath((Join-Path $package 'bin/projects'))
$projectFull = [IO.Path]::GetFullPath($projectDirectory)
if (-not $projectFull.StartsWith($projectsRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Verifier project escapes the isolated projects root: $projectFull"
}
if (Test-Path -LiteralPath $projectFull) { throw "Verifier project already exists: $projectFull" }

function Get-TreeIdentity([string]$Root) {
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $Root -File -Recurse | Sort-Object FullName | ForEach-Object {
        $relative = [IO.Path]::GetRelativePath($Root, $_.FullName).Replace('\', '/')
        "$relative|$($_.Length)|$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)"
    })
}

$assetsRoot = Join-Path $package 'bin/assets'
$assetsBefore = @(Get-TreeIdentity $assetsRoot)
$derivedBefore = @()

try {
    & pwsh -NoProfile -File $author -Action Create -PackageRoot $package -ProjectName $ProjectName | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to create isolated authoring transaction project.' }

    $before = Read-EditorProjectModel -PackageRoot $package -Name $ProjectName
    if ($before.AuthoringRevision -notmatch '^[0-9a-f]{64}$') { throw 'Initial authoring revision is not SHA-256.' }
    if (@($before.Scene.Textures).Count -ne 3 -or @($before.Scene.Textures | ForEach-Object { [uint32]$_.TextureId }) -notcontains 3) { throw 'Project Snapshot did not expose the Scene texture set.' }
    $sceneBefore = [IO.File]::ReadAllText($before.Files.Scene)
    $scriptBefore = [IO.File]::ReadAllText($before.Files.Script)
    $nextX = [double]$before.Scene.GoalPosition[0] + 7.0
    $nextY = [double]$before.Scene.GoalPosition[1] - 3.0
    $nextPlayerTextureId = [uint32]3
    $nextGoalTextureId = if ([uint32]$before.Scene.GoalTextureId -eq 1) { [uint32]2 } else { [uint32]1 }
    $nextHazardTextureId = if ([uint32]$before.Scene.HazardTextureId -eq 1) { [uint32]2 } else { [uint32]1 }

    $applyOutput = @(& pwsh -NoProfile -File $author -Action Update -PackageRoot $package -ProjectName $ProjectName `
        -ExpectedRevision $before.AuthoringRevision -SceneGoalX $nextX -SceneGoalY $nextY `
        -ScenePlayerTextureId $nextPlayerTextureId -SceneGoalTextureId $nextGoalTextureId -SceneHazardTextureId $nextHazardTextureId 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Authoring apply failed: $($applyOutput -join ' | ')" }
    $after = Read-EditorProjectModel -PackageRoot $package -Name $ProjectName
    if ($after.AuthoringRevision -eq $before.AuthoringRevision) { throw 'Authoring revision did not change after mutation.' }
    if ([double]$after.Scene.GoalPosition[0] -ne $nextX -or [double]$after.Scene.GoalPosition[1] -ne $nextY) {
        throw 'Authoring mutation was not reflected in Project Snapshot.'
    }
    if ([uint32]$after.Scene.PlayerTextureId -ne $nextPlayerTextureId -or [uint32]$after.Scene.GoalTextureId -ne $nextGoalTextureId -or [uint32]$after.Scene.HazardTextureId -ne $nextHazardTextureId) {
        throw 'Scene texture binding mutation was not reflected in Project Snapshot.'
    }
    if ($applyOutput -notcontains "previous_revision=$($before.AuthoringRevision)" -or $applyOutput -notcontains "authoring_revision=$($after.AuthoringRevision)") {
        throw 'Authoring adapter output is missing revision evidence.'
    }
    Write-Output 'revision_apply=ok'
    Write-Output 'scene_texture_binding_transaction=ok'
    Write-Output 'scene_texture_set_snapshot=ok'

    $sceneAfter = [IO.File]::ReadAllText($after.Files.Scene)
    $scriptAfter = [IO.File]::ReadAllText($after.Files.Script)
    $conflictOutput = @(& pwsh -NoProfile -File $author -Action Update -PackageRoot $package -ProjectName $ProjectName `
        -ExpectedRevision $before.AuthoringRevision -ScriptGoalX 9 -ScriptGoalY 10 2>&1)
    if ($LASTEXITCODE -eq 0) { throw 'Stale authoring revision unexpectedly succeeded.' }
    if (($conflictOutput -join "`n") -notmatch '\[authoring_revision_conflict\]') { throw 'Stale authoring revision did not report the stable conflict code.' }
    if ([IO.File]::ReadAllText($after.Files.Scene) -ne $sceneAfter -or [IO.File]::ReadAllText($after.Files.Script) -ne $scriptAfter) {
        throw 'Revision conflict changed an authoring source.'
    }
    Write-Output 'revision_conflict=ok'

    $invalidTextureOutput = @(& pwsh -NoProfile -File $author -Action Update -PackageRoot $package -ProjectName $ProjectName `
        -ExpectedRevision $after.AuthoringRevision -ScenePlayerTextureId 4 2>&1)
    if ($LASTEXITCODE -eq 0 -or ($invalidTextureOutput -join "`n") -notmatch 'not declared') { throw 'Undeclared Scene TextureId was not rejected.' }
    if ([IO.File]::ReadAllText($after.Files.Scene) -ne $sceneAfter) { throw 'Undeclared TextureId rejection changed the Scene source.' }
    Write-Output 'undeclared_scene_texture_rejected=ok'

    # 关键事务边界：使用当前 revision 同时改 Scene/Script，结果必须只暴露一个新的 pair revision。
    $pairOutput = @(& pwsh -NoProfile -File $author -Action Update -PackageRoot $package -ProjectName $ProjectName `
        -ExpectedRevision $after.AuthoringRevision -SceneGoalX ($nextX + 1) -SceneGoalY ($nextY + 1) `
        -ScriptVelocityX 2 -ScriptVelocityY -2 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Pair authoring transaction failed: $($pairOutput -join ' | ')" }
    $pair = Read-EditorProjectModel -PackageRoot $package -Name $ProjectName
    if ($pair.AuthoringRevision -eq $after.AuthoringRevision -or [double]$pair.Script.GoalVelocity[0] -ne 2 -or [double]$pair.Script.GoalVelocity[1] -ne -2) {
        throw 'Pair transaction did not commit a coherent Project Snapshot.'
    }
    Write-Output 'pair_transaction=ok'

    $assetsAfter = @(Get-TreeIdentity $assetsRoot)
    if (@(Compare-Object $assetsBefore $assetsAfter).Count -ne 0) { throw 'Authoring transaction modified bin/assets.' }
    $derivedAfter = @(Get-TreeIdentity (Join-Path $projectDirectory '.kadath'))
    if (@(Compare-Object $derivedBefore $derivedAfter).Count -ne 0) { throw 'Authoring transaction modified derived artifacts.' }
    Write-Output 'package_assets_immutable=ok'
    Write-Output 'derived_immutable=ok'
    Write-Output 'verification=ok'
}
finally {
    # 只删除已验证位于 bin/projects 下的本次隔离项目，绝不触碰正式资产目录。
    if (Test-Path -LiteralPath $projectFull) { Remove-Item -LiteralPath $projectFull -Recurse -Force }
}
