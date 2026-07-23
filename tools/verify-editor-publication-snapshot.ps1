[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$PackageRoot,
    [string]$ProjectName = "publication_verify_$PID"
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = (Resolve-Path -LiteralPath $PackageRoot).Path
$adapter = Join-Path $PSScriptRoot 'editor-publication-snapshot.ps1'
$author = Join-Path $PSScriptRoot 'editor-author.ps1'
$liveBake = Join-Path $PSScriptRoot 'editor-live-bake.ps1'
$projectsRoot = [IO.Path]::GetFullPath((Join-Path $root 'bin\projects'))
$project = [IO.Path]::GetFullPath((Join-Path $projectsRoot $ProjectName))
$prefix = $projectsRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if (-not $project.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe publication verifier project path.' }
if (Test-Path -LiteralPath $project) { throw "Publication verifier project already exists: $project" }

function Invoke-Publication([string]$Profile = 'debug') {
    $output = @(& pwsh -NoProfile -File $adapter -PackageRoot $root -ProjectName $ProjectName -Profile $Profile 2>&1 | ForEach-Object { $_.ToString() })
    if ($LASTEXITCODE -ne 0 -or $output.Count -ne 1) {
        throw "Publication snapshot failed: $($output -join ' | ')"
    }
    return $output[0] | ConvertFrom-Json
}

function Invoke-Bake([string]$Target, [string]$Profile = 'debug') {
    $derived = Join-Path $project '.kadath\derived'
    $output = @(& pwsh -NoProfile -File $liveBake -PackageRoot $root -SceneSourcePath (Join-Path $project 'scene.json') -ScriptSourcePath (Join-Path $project 'script.json') -SceneArtifactPath (Join-Path $derived 'scene.scene') -ScriptArtifactPath (Join-Path $derived 'script.script') -ManifestPath (Join-Path $derived '.live-bake.manifest.json') -Target $Target -Profile $Profile 2>&1 | ForEach-Object { $_.ToString() })
    if ($LASTEXITCODE -ne 0) { throw "Live bake failed: $($output -join ' | ')" }
}

function Get-AssetDigest {
    $assets = Join-Path $root 'bin\assets'
    $entries = Get-ChildItem -LiteralPath $assets -File -Recurse | Sort-Object FullName | ForEach-Object {
        "$(($_.FullName.Substring($assets.Length)).Replace('\', '/')):$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)"
    }
    return ($entries -join [Environment]::NewLine)
}

try {
    & pwsh -NoProfile -File $author -Action Create -PackageRoot $root -ProjectName $ProjectName | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to create isolated publication verifier project.' }
    $assetDigestBefore = Get-AssetDigest

    $missing = Invoke-Publication
    if ($missing.state -ne 'missing' -or $missing.manifestPresent -or $missing.scene.state -ne 'missing' -or $missing.script.state -ne 'missing') {
        throw 'Initial publication state must be missing.'
    }

    Invoke-Bake 'Both'
    $current = Invoke-Publication
    if ($current.state -ne 'current' -or $current.scene.state -ne 'current' -or $current.script.state -ne 'current' -or
        [int64]$current.scene.artifactBytes -ne 128 -or [int64]$current.script.artifactBytes -lt 16) {
        throw 'Publication snapshot did not validate the baked pair.'
    }

    # manifest 的 artifactBytes 类型错误必须降级为 artifact_invalid，而不是让 adapter 直接退出。
    $manifestPath = Join-Path $project '.kadath\derived\.live-bake.manifest.json'
    [byte[]]$manifestBeforeTypeCheck = [IO.File]::ReadAllBytes($manifestPath)
    $manifestWithInvalidBytes = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json
    $manifestWithInvalidBytes.scene.artifactBytes = 'not-a-number'
    $manifestWithInvalidBytes | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -Encoding utf8
    $invalidManifestType = Invoke-Publication
    if ($invalidManifestType.state -ne 'artifact_invalid') {
        throw 'Manifest artifactBytes type error was not projected as artifact_invalid.'
    }
    [IO.File]::WriteAllBytes($manifestPath, $manifestBeforeTypeCheck)

    [byte[]]$manifestBefore = [IO.File]::ReadAllBytes((Join-Path $project '.kadath\derived\.live-bake.manifest.json'))
    $manifestValue = Get-Content -LiteralPath (Join-Path $project '.kadath\derived\.live-bake.manifest.json') -Raw -Encoding utf8 | ConvertFrom-Json
    $manifestValue.scene.sourcePath = '../escape.json'
    $manifestValue | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $project '.kadath\derived\.live-bake.manifest.json') -Encoding utf8
    $pathInvalid = Invoke-Publication
    if ($pathInvalid.state -ne 'artifact_invalid') { throw 'Manifest path escape was not rejected.' }
    [IO.File]::WriteAllBytes((Join-Path $project '.kadath\derived\.live-bake.manifest.json'), $manifestBefore)

    & pwsh -NoProfile -File $author -Action Update -PackageRoot $root -ProjectName $ProjectName -SceneGoalX 9 -SceneGoalY 8 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to mutate Scene authoring source.' }
    $dirty = Invoke-Publication
    if ($dirty.state -ne 'source_dirty' -or $dirty.scene.state -ne 'source_dirty' -or $dirty.script.state -ne 'current') {
        throw 'Scene-only source change did not produce per-target dirty state.'
    }

    # 即使 source 同时 dirty，已损坏的 derived artifact 仍必须优先报告 artifact_invalid。
    $sceneArtifact = Join-Path $project '.kadath\derived\scene.scene'
    [byte[]]$sceneArtifactBeforePriorityCheck = [IO.File]::ReadAllBytes($sceneArtifact)
    [byte[]]$sceneArtifactCorruptedForPriority = [byte[]]$sceneArtifactBeforePriorityCheck.Clone()
    $sceneArtifactCorruptedForPriority[0] = 0
    [IO.File]::WriteAllBytes($sceneArtifact, $sceneArtifactCorruptedForPriority)
    $dirtyAndInvalid = Invoke-Publication
    if ($dirtyAndInvalid.state -ne 'artifact_invalid' -or $dirtyAndInvalid.scene.state -ne 'artifact_invalid') {
        throw 'Artifact-invalid priority was masked by source_dirty.'
    }
    [IO.File]::WriteAllBytes($sceneArtifact, $sceneArtifactBeforePriorityCheck)

    Invoke-Bake 'Scene'
    $rebaked = Invoke-Publication
    if ($rebaked.state -ne 'current') { throw 'Scene incremental bake did not restore current state.' }

    $profileMismatch = Invoke-Publication 'release'
    if ($profileMismatch.state -ne 'profile_mismatch' -or
        $profileMismatch.scene.state -ne 'profile_mismatch' -or
        $profileMismatch.script.state -ne 'profile_mismatch') {
        throw 'Profile mismatch was not projected for the complete pair.'
    }

    [byte[]]$artifactBefore = [IO.File]::ReadAllBytes($sceneArtifact)
    [byte[]]$corrupted = [byte[]]$artifactBefore.Clone()
    $corrupted[0] = 0
    [IO.File]::WriteAllBytes($sceneArtifact, $corrupted)
    $invalid = Invoke-Publication
    if ($invalid.state -ne 'artifact_invalid' -or $invalid.scene.state -ne 'artifact_invalid') {
        throw 'Corrupted artifact was not rejected.'
    }
    [IO.File]::WriteAllBytes($sceneArtifact, $artifactBefore)

    $manifest = Join-Path $project '.kadath\derived\.live-bake.manifest.json'
    $hashesBefore = @(
        (Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash,
        (Get-FileHash -LiteralPath $sceneArtifact -Algorithm SHA256).Hash,
        (Get-FileHash -LiteralPath (Join-Path $project '.kadath\derived\script.script') -Algorithm SHA256).Hash)
    [void](Invoke-Publication)
    $hashesAfter = @(
        (Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash,
        (Get-FileHash -LiteralPath $sceneArtifact -Algorithm SHA256).Hash,
        (Get-FileHash -LiteralPath (Join-Path $project '.kadath\derived\script.script') -Algorithm SHA256).Hash)
    if (($hashesBefore -join '|') -ne ($hashesAfter -join '|')) { throw 'Publication snapshot modified derived files.' }
    if ((Get-AssetDigest) -ne $assetDigestBefore) { throw 'Publication snapshot changed package assets.' }

    Write-Output 'publication_missing=ok'
    Write-Output 'publication_current=ok'
    Write-Output 'publication_source_dirty=ok'
    Write-Output 'publication_target_selection=ok'
    Write-Output 'publication_profile_mismatch=ok'
    Write-Output 'publication_artifact_invalid=ok'
    Write-Output 'publication_manifest_type_rejection=ok'
    Write-Output 'publication_artifact_invalid_priority=ok'
    Write-Output 'publication_read_only=ok'
    Write-Output 'package_assets_immutable=ok'
    Write-Output 'verification=ok'
}
finally {
    if (Test-Path -LiteralPath $project) {
        $resolved = (Resolve-Path -LiteralPath $project).Path
        # 只清理 verifier 自己创建且仍位于 bin/projects 下的隔离目录。
        if (-not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing unsafe publication verifier cleanup.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
