[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$PackageRoot,
    [Parameter(Mandatory = $true)] [string]$ProjectName,
    [ValidateSet('debug', 'release')] [string]$Profile = 'debug'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:DiagnosticCode = $null
$script:DiagnosticMessage = $null

function Set-Diagnostic([string]$Code, [string]$Message) {
    if ([string]::IsNullOrWhiteSpace($script:DiagnosticCode)) {
        $script:DiagnosticCode = $Code
        $script:DiagnosticMessage = $Message
    }
}

function Resolve-Root([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Package root does not exist: $Path"
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Assert-InRoot([string]$Root, [string]$Path, [string]$Name, [bool]$RequireLeaf) {
    # 所有读取路径都必须留在 package root 内，并拒绝 reparse point，防止快照越界读取外部文件。
    $full = [IO.Path]::GetFullPath($Path)
    $prefix = $Root.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not ($full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or $full -eq $Root)) {
        throw "$Name escapes package root: $Path"
    }
    if ($RequireLeaf -and -not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw "$Name does not exist: $Path"
    }
    if (Test-Path -LiteralPath $full) {
        $item = Get-Item -LiteralPath $full -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Name cannot be a reparse point: $Path"
        }
    }
    return $full
}

function Get-RelativePath([string]$Root, [string]$Path) {
    return ([IO.Path]::GetRelativePath($Root, $Path)).Replace([IO.Path]::DirectorySeparatorChar, '/')
}

function Get-Hash([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-Hex64([object]$Value) {
    return $null -ne $Value -and ([string]$Value -match '^[0-9a-fA-F]{64}$')
}

function Get-ArtifactInfo([string]$Path, [ValidateSet('Scene', 'Script')][string]$Kind) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Kind artifact cannot be a reparse point: $Path"
    }
    # 这里仅验证 magic/version/布局并计算摘要，不对 artifact 做任何写入。
    [byte[]]$bytes = [IO.File]::ReadAllBytes($Path)
    if ($Kind -eq 'Scene') {
        if ($bytes.Length -ne 140 -or [Text.Encoding]::ASCII.GetString($bytes, 0, 4) -cne 'KSCN') {
            throw 'Scene artifact layout mismatch'
        }
        if ([BitConverter]::ToUInt32($bytes, 4) -ne 2 -or [BitConverter]::ToUInt32($bytes, 8) -ne 2 -or [BitConverter]::ToUInt32($bytes, 12) -ne 124) {
            throw 'Scene artifact header mismatch'
        }
    }
    else {
        if ($bytes.Length -lt 16 -or [Text.Encoding]::ASCII.GetString($bytes, 0, 4) -cne 'KSCP') {
            throw 'Script artifact layout mismatch'
        }
        $count = [BitConverter]::ToUInt32($bytes, 12)
        if ([BitConverter]::ToUInt32($bytes, 4) -ne 1 -or [BitConverter]::ToUInt32($bytes, 8) -ne 1 -or $count -gt 16 -or $bytes.Length -ne (16 + ($count * 16))) {
            throw 'Script artifact header mismatch'
        }
    }
    return [ordered]@{ sha256 = Get-Hash $Path; bytes = [int64]$bytes.Length }
}

function Read-Manifest([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Present = $false; Valid = $false; Value = $null }
    }
    try {
        $item = Get-Item -LiteralPath $Path -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Manifest cannot be a reparse point.'
        }
        $value = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
        if ([string]$value.schemaVersion -ne '1') { throw 'Unsupported live-bake manifest schema.' }
        if ([string]$value.profile -notin @('debug', 'release')) { throw 'Unsupported live-bake manifest profile.' }
        foreach ($property in @('scene', 'script')) {
            $entry = $value.PSObject.Properties[$property].Value
            if ($null -eq $entry) { throw "Manifest is missing $property entry." }
            # 先严格验证 manifest 证据，避免坏类型在后续 [int64] 转换时直接终止查询。
            foreach ($field in @('sourcePath', 'sourceSha256', 'artifactPath', 'artifactSha256', 'artifactBytes')) {
                if ($null -eq $entry.PSObject.Properties[$field] -or [string]::IsNullOrWhiteSpace([string]$entry.PSObject.Properties[$field].Value)) {
                    throw "Manifest $property entry is missing $field."
                }
            }
            if (-not (Test-Hex64 $entry.sourceSha256) -or -not (Test-Hex64 $entry.artifactSha256)) {
                throw "Manifest $property entry has an invalid SHA-256 revision."
            }
            if ([string]$entry.artifactBytes -notmatch '^[1-9][0-9]*$') {
                throw "Manifest $property entry has an invalid artifact byte count."
            }
        }
        return [pscustomobject]@{ Present = $true; Valid = $true; Value = $value }
    }
    catch {
        Set-Diagnostic 'manifest_invalid' $_.Exception.Message
        return [pscustomobject]@{ Present = $true; Valid = $false; Value = $null }
    }
}

function Get-TargetSnapshot(
    [string]$Kind,
    [string]$SourcePath,
    [string]$ArtifactPath,
    [object]$Manifest,
    [bool]$ManifestPresent,
    [bool]$ManifestValid,
    [string]$RequestedProfile,
    [string]$Root) {
    $sourceRevision = Get-Hash $SourcePath
    $artifactInfo = $null
    $artifactFailure = $false
    try { $artifactInfo = Get-ArtifactInfo $ArtifactPath $Kind }
    catch {
        $artifactFailure = $true
        Set-Diagnostic 'artifact_invalid' $_.Exception.Message
    }

    $entry = $null
    if ($ManifestValid -and $null -ne $Manifest) {
        $entry = $Manifest.PSObject.Properties[$Kind.ToLowerInvariant()].Value
    }

    $bakedSourceRevision = if ($null -ne $entry) { [string]$entry.sourceSha256 } else { $null }
    $manifestArtifactRevision = if ($null -ne $entry) { [string]$entry.artifactSha256 } else { $null }
    $manifestArtifactBytes = if ($null -ne $entry) { [int64]$entry.artifactBytes } else { $null }
    $artifactRevision = if ($null -ne $artifactInfo) { [string]$artifactInfo.sha256 } else { $null }
    $artifactBytes = if ($null -ne $artifactInfo) { [int64]$artifactInfo.bytes } else { $null }
    $expectedSourcePath = Get-RelativePath $Root $SourcePath
    $expectedArtifactPath = Get-RelativePath $Root $ArtifactPath
    $pathMismatch = $ManifestValid -and $null -ne $entry -and ([string]$entry.sourcePath -ne $expectedSourcePath -or [string]$entry.artifactPath -ne $expectedArtifactPath)
    if ($pathMismatch) { Set-Diagnostic 'manifest_invalid' "$Kind manifest paths do not match the current project." }
    $state = 'current'

    $artifactIdentityInvalid = $false
    if ($null -ne $artifactInfo -and $null -ne $entry) {
        $artifactIdentityInvalid = -not (Test-Hex64 $manifestArtifactRevision) -or
            -not [string]::Equals($artifactRevision, $manifestArtifactRevision, [StringComparison]::OrdinalIgnoreCase) -or
            $artifactBytes -ne $manifestArtifactBytes
        if ($artifactIdentityInvalid) {
            Set-Diagnostic 'artifact_invalid' "$Kind artifact hash or byte count does not match the manifest."
        }
    }

    $manifestEvidenceInvalid = $ManifestPresent -and (-not $ManifestValid -or $null -eq $entry -or $pathMismatch)
    # 严格遵守 artifact_invalid > missing > profile_mismatch > source_dirty 优先级；缺失 manifest 本身仍属于 missing。
    if ($manifestEvidenceInvalid -or $artifactFailure -or $artifactIdentityInvalid) {
        $state = 'artifact_invalid'
    }
    elseif (-not $ManifestPresent -or $null -eq $artifactInfo) {
        $state = 'missing'
    }
    elseif ([string]$Manifest.profile -cne $RequestedProfile) {
        $state = 'profile_mismatch'
    }
    elseif (-not (Test-Hex64 $bakedSourceRevision) -or -not [string]::Equals($sourceRevision, $bakedSourceRevision, [StringComparison]::OrdinalIgnoreCase)) {
        $state = 'source_dirty'
    }
    return [ordered]@{
        target = $Kind
        state = $state
        sourceRevision = $sourceRevision
        bakedSourceRevision = $bakedSourceRevision
        artifactRevision = $artifactRevision
        manifestArtifactRevision = $manifestArtifactRevision
        artifactBytes = $artifactBytes
        manifestArtifactBytes = $manifestArtifactBytes
    }
}

try {
    $root = Resolve-Root $PackageRoot
    if ($ProjectName -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,47}$') {
        throw 'Project name contains unsupported characters.'
    }
    $projectsRoot = Assert-InRoot $root (Join-Path $root 'bin\projects') 'Projects root' $false
    $projectDirectory = Assert-InRoot $root (Join-Path $projectsRoot $ProjectName) 'Project directory' $false
    if (-not (Test-Path -LiteralPath $projectDirectory -PathType Container)) { throw "Project directory does not exist: $projectDirectory" }
    $sceneSource = Assert-InRoot $root (Join-Path $projectDirectory 'scene.json') 'Scene source' $true
    $scriptSource = Assert-InRoot $root (Join-Path $projectDirectory 'script.json') 'Script source' $true
    $derivedDirectory = [IO.Path]::GetFullPath((Join-Path $projectDirectory '.kadath\derived'))
    if (-not $derivedDirectory.StartsWith($projectDirectory.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Derived directory escapes project directory.'
    }
    if (Test-Path -LiteralPath $derivedDirectory) {
        $derivedItem = Get-Item -LiteralPath $derivedDirectory -Force
        if (($derivedItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Derived directory cannot be a reparse point.' }
    }
    $manifestPath = Join-Path $derivedDirectory '.live-bake.manifest.json'
    $sceneArtifact = Join-Path $derivedDirectory 'scene.scene'
    $scriptArtifact = Join-Path $derivedDirectory 'script.script'
    $manifest = Read-Manifest $manifestPath
    $scene = Get-TargetSnapshot 'Scene' $sceneSource $sceneArtifact $manifest.Value $manifest.Present $manifest.Valid $Profile $root
    $script = Get-TargetSnapshot 'Script' $scriptSource $scriptArtifact $manifest.Value $manifest.Present $manifest.Valid $Profile $root

    # 聚合状态按最危险优先，UI 可据此决定是修复 artifact 还是只重 bake 单个 source。
    $states = @($scene.state, $script.state)
    $state = if ($states -contains 'artifact_invalid') { 'artifact_invalid' }
        elseif ($states -contains 'missing') { 'missing' }
        elseif ($states -contains 'profile_mismatch') { 'profile_mismatch' }
        elseif ($states -contains 'source_dirty') { 'source_dirty' }
        else { 'current' }

    [ordered]@{
        schemaVersion = 1
        snapshotVersion = 1
        event = 'publication_snapshot'
        projectName = $ProjectName
        profile = $Profile
        manifestProfile = if ($manifest.Valid) { [string]$manifest.Value.profile } else { $null }
        derivedDirectory = $derivedDirectory
        manifestPath = $manifestPath
        state = $state
        manifestPresent = [bool]$manifest.Present
        scene = $scene
        script = $script
        diagnosticCode = $script:DiagnosticCode
        diagnosticMessage = $script:DiagnosticMessage
    } | ConvertTo-Json -Compress -Depth 12
    exit 0
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
