[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$PackageRoot,
    [Parameter(Mandatory = $true)] [string]$SceneSourcePath,
    [Parameter(Mandatory = $true)] [string]$ScriptSourcePath,
    [Parameter(Mandatory = $true)] [string]$SceneArtifactPath,
    [Parameter(Mandatory = $true)] [string]$ScriptArtifactPath,
    [Parameter(Mandatory = $true)] [string]$ManifestPath,
    [ValidateSet('Scene', 'Script', 'Both')] [string]$Target = 'Both',
    [ValidateSet('debug', 'release')] [string]$Profile = 'debug'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:AdapterVersion = 1
$script:Staged = @()
$script:Promoted = @()
$script:ManifestCommit = $null

function Get-Hash([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Resolve-Root([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "Package root does not exist: $Path" }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Assert-InRoot([string]$Root, [string]$Path, [string]$Name, [bool]$RequireLeaf) {
    $full = [IO.Path]::GetFullPath($Path)
    $prefix = $Root.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not ($full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or $full -eq $Root)) { throw "$Name escapes package root: $Path" }
    if ($RequireLeaf) {
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "$Name does not exist: $Path" }
        if (((Get-Item -LiteralPath $full).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Name cannot be a reparse point: $Path" }
    }
    return $full
}

function Assert-Source([string]$Root, [string]$Path, [string]$Extension, [string]$Name) {
    $full = Assert-InRoot $Root $Path $Name $true
    $alternate = if ($Extension -eq '.scene.json') { 'scene.json' } else { 'script.json' }
    if (-not $full.EndsWith($Extension, [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($full) -ine $alternate) { throw "$Name must use $Extension or project-local $alternate`: $Path" }
    return $full
}
function Assert-Destination([string]$Root, [string]$Path, [string]$Extension, [string]$Name) {
    $full = Assert-InRoot $Root $Path $Name $false
    # source 可以来自 package 模板；只有派生输出必须与不可变 Runtime assets 隔离。
    if ($full -match '(?i)[\\/]bin[\\/]assets([\\/]|$)') { throw "$Name must not be inside package/bin/assets: $Path" }
    if (-not $full.EndsWith($Extension, [StringComparison]::OrdinalIgnoreCase)) { throw "$Name must use ${Extension}: $Path" }
    $parent = Split-Path -Parent $full
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    if (((Get-Item -LiteralPath $parent).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Name parent cannot be a reparse point: $parent" }
    return $full
}

function Get-RelativePath([string]$Root, [string]$Path) {
    return ([IO.Path]::GetRelativePath($Root, $Path)).Replace([IO.Path]::DirectorySeparatorChar, '/')
}

function Get-ArtifactInfo([string]$Path, [ValidateSet('Scene', 'Script')][string]$Kind) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Kind artifact does not exist: $Path" }
    [byte[]]$bytes = [IO.File]::ReadAllBytes($Path)
    if ($Kind -eq 'Scene') {
        if ($bytes.Length -lt 144 -or [Text.Encoding]::ASCII.GetString($bytes, 0, 4) -cne 'KSCN') { throw 'Scene artifact layout mismatch' }
        if ([BitConverter]::ToUInt32($bytes, 4) -ne 3 -or [BitConverter]::ToUInt32($bytes, 8) -ne 3 -or [BitConverter]::ToUInt32($bytes, 12) -ne ($bytes.Length - 16)) { throw 'Scene artifact header mismatch' }
    } else {
        if ($bytes.Length -lt 16 -or [Text.Encoding]::ASCII.GetString($bytes, 0, 4) -cne 'KSCP') { throw 'Script artifact layout mismatch' }
        $count = [BitConverter]::ToUInt32($bytes, 12)
        if ([BitConverter]::ToUInt32($bytes, 4) -ne 1 -or [BitConverter]::ToUInt32($bytes, 8) -ne 1 -or $count -gt 16 -or $bytes.Length -ne (16 + ($count * 16))) { throw 'Script artifact header mismatch' }
    }
    return [ordered]@{ sha256 = Get-Hash $Path; bytes = $bytes.Length }
}

function Invoke-Importer([string]$ScriptPath, [string]$SourcePath, [string]$DestinationPath, [string]$Kind) {
    $snapshotExtension = if ($Kind -eq 'Scene') { '.scene.json' } else { '.script.json' }
    $snapshot = "$DestinationPath.source$snapshotExtension"
    # Importer 保持严格扩展名契约；live adapter 对项目内 scene.json/script.json 创建只读快照。
    [IO.File]::Copy($SourcePath, $snapshot)
    $script:Staged += $snapshot
    $output = @(& pwsh -NoProfile -File $ScriptPath -SourcePath $snapshot -DestinationPath $DestinationPath -Profile $Profile 2>&1 | ForEach-Object { $_.ToString() })
    if ($LASTEXITCODE -ne 0) { throw "$Kind importer failed: $($output -join ' | ')" }
    if (-not (Test-Path -LiteralPath $DestinationPath -PathType Leaf)) { throw "$Kind importer produced no artifact" }
}
function New-StagePath([string]$DestinationPath) {
    $directory = Split-Path -Parent $DestinationPath
    $name = [IO.Path]::GetFileNameWithoutExtension($DestinationPath)
    $extension = [IO.Path]::GetExtension($DestinationPath)
    return Join-Path $directory "$name.live.$PID.$([guid]::NewGuid().ToString('N'))$extension"
}
function Promote-File([string]$Stage, [string]$Destination, [string]$Label) {
    $backup = $null
    $hadExisting = Test-Path -LiteralPath $Destination -PathType Leaf
    if ($hadExisting) {
        $backup = "$Destination.live-backup.$PID.$([guid]::NewGuid().ToString('N')).tmp"
        # 关键提交边界：File.Replace 原子替换当前 artifact，并保留旧版本供 pair transaction 回滚。
        [IO.File]::Replace($Stage, $Destination, $backup, $true)
    } else {
        [IO.File]::Move($Stage, $Destination)
    }
    $record = [pscustomobject]@{ Destination = $Destination; Backup = $backup; HadExisting = $hadExisting; Label = $Label }
    $script:Promoted += $record
}

function Restore-PromotedFiles {
    foreach ($record in @($script:Promoted | Sort-Object -Property Label -Descending)) {
        try {
            if ($record.HadExisting -and (Test-Path -LiteralPath $record.Backup -PathType Leaf)) {
                if (Test-Path -LiteralPath $record.Destination -PathType Leaf) { Remove-Item -LiteralPath $record.Destination -Force }
                [IO.File]::Move($record.Backup, $record.Destination)
            } elseif (Test-Path -LiteralPath $record.Destination -PathType Leaf) {
                Remove-Item -LiteralPath $record.Destination -Force
            }
        } catch { }
    }
    $script:Promoted = @()
}

function Write-Manifest([object]$Manifest, [string]$Path) {
    $temporary = "$Path.live.$PID.$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($temporary, ($Manifest | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $backup = "$Path.live-backup.$PID.$([guid]::NewGuid().ToString('N')).tmp"
            # manifest 与 artifact 共享事务边界，写 manifest 失败时恢复所有旧文件。
            [IO.File]::Replace($temporary, $Path, $backup, $true)
            $script:ManifestCommit = [pscustomobject]@{ Path = $Path; Backup = $backup; HadExisting = $true }
        } else {
            [IO.File]::Move($temporary, $Path)
            $script:ManifestCommit = [pscustomobject]@{ Path = $Path; Backup = $null; HadExisting = $false }
        }
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Restore-Manifest {
    if ($null -eq $script:ManifestCommit) { return }
    try {
        if ($script:ManifestCommit.HadExisting -and (Test-Path -LiteralPath $script:ManifestCommit.Backup -PathType Leaf)) {
            if (Test-Path -LiteralPath $script:ManifestCommit.Path -PathType Leaf) { Remove-Item -LiteralPath $script:ManifestCommit.Path -Force }
            [IO.File]::Move($script:ManifestCommit.Backup, $script:ManifestCommit.Path)
        } elseif (Test-Path -LiteralPath $script:ManifestCommit.Path -PathType Leaf) {
            Remove-Item -LiteralPath $script:ManifestCommit.Path -Force
        }
    } catch { }
    $script:ManifestCommit = $null
}

function Read-Manifest([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $value = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
    if ([int]$value.schemaVersion -ne 1) { throw 'Unsupported live-bake manifest schema' }
    return $value
}

function New-Entry([string]$Source, [string]$Artifact, [object]$Info, [string]$Kind) {
    return [ordered]@{
        kind = $Kind
        sourcePath = Get-RelativePath $root $Source
        sourceSha256 = Get-Hash $Source
        artifactPath = Get-RelativePath $root $Artifact
        artifactSha256 = $Info.sha256
        artifactBytes = $Info.bytes
        artifactFormat = if ($Kind -eq 'Scene') { 'KSCN-SCENE-V3' } else { 'KSCP-SCRIPT-V1' }
        importerVersion = if ($Kind -eq 'Scene') { 3 } else { 1 }
        bakerVersion = if ($Kind -eq 'Scene') { 3 } else { 1 }
    }
}

function Write-Result([string]$Result, [string]$ErrorCode, [string]$Message, [object[]]$Entries) {
    $sourceRevisions = [ordered]@{}
    $artifactRevisions = [ordered]@{}
    $artifactBytes = [ordered]@{}
    foreach ($entry in @($Entries)) {
        if ($null -eq $entry) { continue }
        $key = ([string]$entry.kind).ToLowerInvariant()
        $sourceRevisions[$key] = [string]$entry.sourceSha256
        $artifactRevisions[$key] = [string]$entry.artifactSha256
        $artifactBytes[$key] = [int]$entry.artifactBytes
    }
    $event = [ordered]@{ schemaVersion = 1; event = 'live_bake_result'; result = $Result; target = $Target; profile = $Profile; adapterVersion = $script:AdapterVersion; sourceRevision = $sourceRevisions; artifactRevision = $artifactRevisions; artifactBytes = $artifactBytes; entries = @($Entries) }
    if (-not [string]::IsNullOrWhiteSpace($ErrorCode)) { $event.errorCode = $ErrorCode }
    if (-not [string]::IsNullOrWhiteSpace($Message)) { $event.message = $Message }
    Write-Output ($event | ConvertTo-Json -Compress -Depth 12)
}
$root = $null
try {
    $root = Resolve-Root $PackageRoot
    $sceneSource = Assert-Source $root $SceneSourcePath '.scene.json' 'Scene source'
    $scriptSource = Assert-Source $root $ScriptSourcePath '.script.json' 'Script source'
    $sceneArtifact = Assert-Destination $root $SceneArtifactPath '.scene' 'Scene artifact'
    $scriptArtifact = Assert-Destination $root $ScriptArtifactPath '.script' 'Script artifact'
    $manifestPathResolved = Assert-Destination $root $ManifestPath '.json' 'Live-bake manifest'
    $manifestBefore = Read-Manifest $manifestPathResolved
    $entries = @()

    if ($Target -in @('Scene', 'Both')) {
        $sourceRevision = Get-Hash $sceneSource
        $stage = New-StagePath $sceneArtifact; $script:Staged += $stage
        Invoke-Importer (Join-Path $PSScriptRoot 'editor-scene-importer.ps1') $sceneSource $stage 'Scene'
        if ((Get-Hash $sceneSource) -cne $sourceRevision) { throw 'Scene source changed during bake' }
        [void](Get-ArtifactInfo $stage 'Scene')
        Promote-File $stage $sceneArtifact 'Scene'
        $entries += New-Entry $sceneSource $sceneArtifact (Get-ArtifactInfo $sceneArtifact 'Scene') 'Scene'
    } elseif ($null -ne $manifestBefore -and $null -ne $manifestBefore.scene -and (Test-Path -LiteralPath $sceneArtifact -PathType Leaf)) {
        $entries += $manifestBefore.scene
    }

    if ($Target -in @('Script', 'Both')) {
        $sourceRevision = Get-Hash $scriptSource
        $stage = New-StagePath $scriptArtifact; $script:Staged += $stage
        Invoke-Importer (Join-Path $PSScriptRoot 'editor-script-importer.ps1') $scriptSource $stage 'Script'
        if ((Get-Hash $scriptSource) -cne $sourceRevision) { throw 'Script source changed during bake' }
        [void](Get-ArtifactInfo $stage 'Script')
        Promote-File $stage $scriptArtifact 'Script'
        $entries += New-Entry $scriptSource $scriptArtifact (Get-ArtifactInfo $scriptArtifact 'Script') 'Script'
    } elseif ($null -ne $manifestBefore -and $null -ne $manifestBefore.script -and (Test-Path -LiteralPath $scriptArtifact -PathType Leaf)) {
        $entries += $manifestBefore.script
    }

    if (@($entries).Count -ne 2) { throw 'Live-bake manifest requires valid Scene and Script entries' }
    $newManifest = [ordered]@{ schemaVersion = 1; profile = $Profile; adapterVersion = $script:AdapterVersion; scene = @($entries | Where-Object { $_.kind -eq 'Scene' })[0]; script = @($entries | Where-Object { $_.kind -eq 'Script' })[0] }
    Write-Manifest $newManifest $manifestPathResolved
    foreach ($record in @($script:Promoted)) { if ($null -ne $record.Backup -and (Test-Path -LiteralPath $record.Backup -PathType Leaf)) { Remove-Item -LiteralPath $record.Backup -Force } }
    if ($null -ne $script:ManifestCommit.Backup -and (Test-Path -LiteralPath $script:ManifestCommit.Backup -PathType Leaf)) { Remove-Item -LiteralPath $script:ManifestCommit.Backup -Force }
    $script:Promoted = @(); $script:ManifestCommit = $null
    Write-Result 'succeeded' '' '' @($newManifest.scene, $newManifest.script)
    exit 0
} catch {
    Restore-Manifest
    Restore-PromotedFiles
    $code = if ($_.Exception.Message -match '(?i)source changed') { 'source_changed_during_bake' } elseif ($_.Exception.Message -match '(?i)importer|parse|schema|artifact') { 'bake_validation_failed' } elseif ($_.Exception.Message -match '(?i)promot|replace') { 'artifact_promote_failed' } else { 'live_bake_failed' }
    Write-Result 'failed' $code $_.Exception.Message @()
    exit 1
} finally {
    foreach ($stage in @($script:Staged)) { if (Test-Path -LiteralPath $stage -PathType Leaf) { Remove-Item -LiteralPath $stage -Force -ErrorAction SilentlyContinue } }
}
