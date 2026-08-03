[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CandidateRoot,

    [Parameter(Mandatory = $true)]
    [string]$ContractDirectory,

    [ValidateSet('debug', 'release')]
    [string]$Profile = 'debug',

    # DryRun 只输出 Contract v1 计划，不创建 contract directory 或 manifest。
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:AssetBuildContractVersion = 1
$script:AssetBuildCommandVersion = 1
$script:AssetBuildToolVersion = 'kadath-asset-contract/1'

function Resolve-SafeLocalBuildPath([string]$Path, [string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw "$Name cannot be empty" }
    # 关键 identity 边界：UNC/device/drive-relative alias 不得形成第二套候选或输出根名称。
    if ($Path.StartsWith('\\', [StringComparison]::Ordinal) -or
        ([IO.Path]::IsPathRooted($Path) -and -not [IO.Path]::IsPathFullyQualified($Path))) {
        throw "$Name must use a local fully-qualified or ordinary relative path"
    }
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrWhiteSpace($root) -or $root.StartsWith('\\', [StringComparison]::Ordinal)) {
        throw "$Name must not use a UNC or device path"
    }
    if ($full.Substring($root.Length).Contains(':')) { throw "$Name must not use an alternate data stream" }
    return $full
}

function Assert-NoBuildReparsePointInExistingPath([string]$Path, [string]$Name) {
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    $relative = [IO.Path]::GetRelativePath($root, $full)
    $current = $root
    if ((((Get-Item -LiteralPath $current -Force).Attributes) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Name root cannot be a reparse point: $current"
    }
    foreach ($segment in $relative.Split([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar), [StringSplitOptions]::RemoveEmptyEntries)) {
        $current = Join-Path $current $segment
        if (-not (Test-Path -LiteralPath $current)) { break }
        if ((((Get-Item -LiteralPath $current -Force).Attributes) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Name cannot traverse a reparse point: $current"
        }
    }
}

function Resolve-BuildCandidateRelativePath([string]$Candidate, [string]$RelativePath, [string]$Name, [switch]$RequireLeaf) {
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or [IO.Path]::IsPathRooted($RelativePath) -or $RelativePath.Contains('\')) {
        throw "$Name must be a portable relative path: $RelativePath"
    }
    $segments = @($RelativePath.Split('/'))
    if ($segments.Count -lt 3 -or $segments[0] -cne 'bin' -or $segments[1] -cne 'assets') {
        throw "$Name must stay below bin/assets: $RelativePath"
    }
    foreach ($segment in $segments) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq '.' -or $segment -eq '..' -or
            $segment.TrimEnd([char[]]@(' ', '.')) -cne $segment -or
            $segment.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
            throw "$Name contains an unsafe path segment: $RelativePath"
        }
    }

    $assetRoot = [IO.Path]::GetFullPath((Join-Path $Candidate 'bin\assets'))
    $assetPrefix = $assetRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $full = [IO.Path]::GetFullPath((Join-Path $Candidate $RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)))
    if (-not $full.StartsWith($assetPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Name escapes Candidate/bin/assets: $RelativePath"
    }
    Assert-NoBuildReparsePointInExistingPath $full $Name
    if ($RequireLeaf -and -not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "$Name does not exist: $RelativePath" }
    $canonicalRelative = [IO.Path]::GetRelativePath($Candidate, $full).Replace('\', '/')
    return [pscustomobject]@{ FullPath = $full; RelativePath = $canonicalRelative }
}

function Resolve-BuildContractCandidate([string]$Path) {
    $full = Resolve-SafeLocalBuildPath $Path 'Candidate root'
    if (-not (Test-Path -LiteralPath $full -PathType Container)) { throw "Candidate root does not exist: $Path" }
    Assert-NoBuildReparsePointInExistingPath $full 'Candidate root'
    $candidate = (Resolve-Path -LiteralPath $full).Path
    $info = Get-Item -LiteralPath $candidate
    if (($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Candidate root cannot be a reparse point' }
    if ($candidate -match '(?i)[\\/]bin[\\/]assets([\\/]|$)') { throw 'Candidate root must be the candidate parent, not bin/assets' }
    return $candidate
}

function Resolve-BuildContractDirectory([string]$Path, [string]$Candidate) {
    $contract = Resolve-SafeLocalBuildPath $Path 'Contract directory'
    if ([string]::IsNullOrWhiteSpace($contract) -or $contract -eq [IO.Path]::GetPathRoot($contract)) { throw "Invalid contract directory: $Path" }
    $candidatePrefix = $Candidate.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $contractPrefix = $contract.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if ($contract.Equals($Candidate, [StringComparison]::OrdinalIgnoreCase) -or $contract.StartsWith($candidatePrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Contract directory must not be inside candidate: $contract" }
    if ($Candidate.StartsWith($contractPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Contract directory must not contain candidate: $contract" }
    if ($contract -match '(?i)[\\/]bin[\\/]assets([\\/]|$)') { throw 'Contract directory must not be package/bin/assets' }
    if (Test-Path -LiteralPath $contract) { throw "Refusing to overwrite existing contract directory: $contract" }
    Assert-NoBuildReparsePointInExistingPath $contract 'Contract directory'
    return $contract
}

function Get-BuildArtifactType([string]$Category, [string]$Extension, [string]$RelativePath) {
    switch ($Category) {
        'Texture' { if ($Extension -eq 'texture') { return 'RuntimeTextureArtifactV1' }; return 'RuntimeTextureSourceV1' }
        'Audio' { if ($RelativePath.EndsWith('.audio.wav', [StringComparison]::OrdinalIgnoreCase)) { return 'RuntimeAudioArtifactV1' }; return 'RuntimeAudioSourceV1' }
        'Scene' { if ($Extension -eq 'scene') { return 'RuntimeSceneArtifactV3' }; return 'RuntimeSceneDocumentV3' }
        'Script' { if ($Extension -eq 'script') { return 'RuntimeScriptArtifactV1' }; return 'RuntimeScriptDocumentV1' }
        default { return 'RuntimeBinarySourceV1' }
    }
}

function Read-BuildContractCandidate([string]$Candidate, [string]$Profile) {
    $promotionPath = Join-Path $Candidate 'bin\asset-promotion.manifest.json'
    if (-not (Test-Path -LiteralPath $promotionPath -PathType Leaf)) { throw "Promotion manifest does not exist: $promotionPath" }
    Assert-NoBuildReparsePointInExistingPath $promotionPath 'Promotion manifest'
    try { $promotion = Get-Content -LiteralPath $promotionPath -Raw -Encoding utf8 | ConvertFrom-Json } catch { throw "Failed to parse promotion manifest: $($_.Exception.Message)" }
    if ([int]$promotion.PromotionVersion -ne 1 -or [int]$promotion.CommandVersion -ne 1) { throw 'Build Contract requires Promotion Manifest v1 / Command v1' }
    if ([string]$promotion.CandidateKind -cne 'asset-payload-v1' -or [string]$promotion.Processing -cne 'passthrough-v1') { throw 'Unsupported candidate processing contract' }
    if ([string]$promotion.Profile -cne $Profile) { throw "Candidate profile does not match requested profile: expected=$Profile actual=$($promotion.Profile)" }
    $items = @($promotion.Items)
    if ([int]$promotion.ItemCount -ne $items.Count -or $items.Count -eq 0) { throw 'Candidate ItemCount is invalid' }
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $items) {
        $candidatePath = Resolve-BuildCandidateRelativePath $Candidate ([string]$item.DestinationPath) 'Candidate artifact' -RequireLeaf
        $inputPath = $candidatePath.RelativePath
        if (-not $seen.Add($inputPath)) { throw "Duplicate candidate artifact path: $inputPath" }
        $filePath = $candidatePath.FullPath
        $file = Get-Item -LiteralPath $filePath
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Candidate artifact cannot be a reparse point: $inputPath" }
        $normalizedExtension = ([string]$item.Extension).TrimStart('.').ToLowerInvariant()
        $actualExtension = [IO.Path]::GetExtension($filePath).TrimStart('.').ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($normalizedExtension) -or $normalizedExtension -cne $actualExtension) {
            throw "Candidate artifact extension metadata mismatch: $inputPath"
        }
        if ([long]$item.SizeBytes -ne [long]$file.Length) { throw "Candidate artifact size mismatch: $inputPath" }
        $hash = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($hash -cne [string]$item.Sha256) { throw "Candidate artifact hash mismatch: $inputPath" }
        # 后续 per-item 映射只消费已经 canonicalize 的相对路径和扩展名。
        $item.DestinationPath = $inputPath
        $item.Extension = $normalizedExtension
    }
    return $promotion
}

function Write-BuildContractJsonAtomic([object]$Document, [string]$Path) {
    $temporary = "$Path.tmp.$PID"
    try {
        [IO.File]::WriteAllText($temporary, ($Document | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $Path
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

$candidate = Resolve-BuildContractCandidate $CandidateRoot
$contract = Resolve-BuildContractDirectory $ContractDirectory $candidate
$promotion = Read-BuildContractCandidate $candidate $Profile
$contractItems = @($promotion.Items | ForEach-Object {
    $inputPath = [string]$_.DestinationPath
    $normalizedExtension = ([string]$_.Extension).ToLowerInvariant()
    $inputArtifactType = Get-BuildArtifactType ([string]$_.Category) ([string]$_.Extension) $inputPath
    $isSceneSource = [string]$_.Category -ceq 'Scene' -and $inputPath.EndsWith('.scene.json', [StringComparison]::OrdinalIgnoreCase)
    $isScriptSource = [string]$_.Category -ceq 'Script' -and $inputPath.EndsWith('.script.json', [StringComparison]::OrdinalIgnoreCase)
    $isTextureSource = [string]$_.Category -ceq 'Texture' -and ($normalizedExtension -eq 'ppm' -or $normalizedExtension -eq 'png')
    # 关键契约：candidate 仍保存 authoring source，per-item 则描述 build/install 产生的 Runtime artifact。
    $outputPath = if ($isSceneSource -or $isScriptSource) {
        $inputPath.Substring(0, $inputPath.Length - '.json'.Length)
    } elseif ($isTextureSource) {
        $inputPath.Substring(0, $inputPath.Length - ($normalizedExtension.Length + 1)) + '.texture'
    } else {
        $inputPath
    }
    $textureTransform = if ($isTextureSource) {
        $sourcePrefix = if ($normalizedExtension -eq 'png') { 'png' } else { 'ppm' }
        if ($Profile -eq 'release') { "$sourcePrefix-to-rgba8-mipmap-artifact-v2" } else { "$sourcePrefix-to-rgba8-artifact-v1" }
    } else {
        $null
    }
    [ordered]@{
        AssetId = $_.AssetId
        InputPath = $inputPath
        OutputPath = $outputPath
        InputArtifactType = $inputArtifactType
        ArtifactType = if ($isSceneSource) { 'RuntimeSceneArtifactV3' } elseif ($isScriptSource) { 'RuntimeScriptArtifactV1' } elseif ($isTextureSource) { 'RuntimeTextureArtifactV1' } else { $inputArtifactType }
        ImporterStatus = if ($isSceneSource) { 'implemented-v3' } elseif ($isScriptSource -or $isTextureSource) { 'implemented-v1' } else { 'not-defined' }
        BakerStatus = if ($isSceneSource) { 'implemented-v3' } elseif ($isScriptSource -or $isTextureSource) { 'implemented-v1' } else { 'not-defined' }
        Transform = if ($isSceneSource) { 'scene-json-to-kscn-v3' } elseif ($isScriptSource) { 'script-json-to-kscp-v1' } elseif ($isTextureSource) { $textureTransform } else { 'passthrough-v1' }
        SizeBytes = $_.SizeBytes
        Sha256 = $_.Sha256
    }
})

# 输出 identity 属于整份 contract；任两个 source/artifact 映射到同一大小写无关路径时，必须在创建目录前整单拒绝。
$seenOutputs = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($item in $contractItems) {
    $normalizedOutput = ([string]$item.OutputPath).Replace('\', '/')
    $canonicalOutput = Resolve-BuildCandidateRelativePath $candidate $normalizedOutput 'Build Contract output'
    $item.OutputPath = $canonicalOutput.RelativePath
    if (-not $seenOutputs.Add($canonicalOutput.RelativePath)) { throw "Duplicate Build Contract output path: $($canonicalOutput.RelativePath)" }
}

# Candidate 本身保持不可变；profile 语义只描述安装阶段会执行的确定性派生变换。
$profileSemantics = [ordered]@{
    debug = 'candidate payload unchanged; Texture PPM/PNG -> KDAT Texture Artifact v1 base-only; Scene JSON -> KSCN Scene Artifact v3; Script JSON -> KSCP Script Artifact v1; other importer/baker not defined'
    release = 'candidate payload unchanged; Texture PPM/PNG -> KDAT Texture Artifact v2 mipmap chain; Scene JSON -> KSCN Scene Artifact v3; Script JSON -> KSCP Script Artifact v1; other importer/baker not defined'
}
if ($DryRun) {
    $plan = [ordered]@{
        CommandVersion = $script:AssetBuildCommandVersion
        ContractVersion = $script:AssetBuildContractVersion
        ToolVersion = $script:AssetBuildToolVersion
        Action = 'build-contract'
        Profile = $Profile
        DryRun = $true
        InputCandidateKind = 'asset-payload-v1'
        OutputKind = 'runtime-source-payload-v1'
        TransformPolicy = 'passthrough-v1'
        PromotionRequired = $true
        ItemCount = $contractItems.Count
        ProfileSemantics = $profileSemantics
        Items = $contractItems
    }
    Write-Output ($plan | ConvertTo-Json -Depth 12 -Compress)
    exit 0
}

$createdContract = $false
try {
    New-Item -ItemType Directory -Path $contract -Force | Out-Null
    $createdContract = $true
    $document = [ordered]@{
        ContractVersion = $script:AssetBuildContractVersion
        CommandVersion = $script:AssetBuildCommandVersion
        ToolVersion = $script:AssetBuildToolVersion
        Action = 'build-contract'
        Profile = $Profile
        InputCandidateKind = 'asset-payload-v1'
        InputPromotionManifest = 'bin/asset-promotion.manifest.json'
        InputAssetRoot = 'bin/assets'
        OutputKind = 'runtime-source-payload-v1'
        OutputAssetRoot = 'bin/assets'
        TransformPolicy = 'passthrough-v1'
        ProfileSemantics = $profileSemantics
        ImporterStatus = 'not-defined'
        BakerStatus = 'not-defined'
        PromotionRequired = $true
        ItemCount = $contractItems.Count
        Items = $contractItems
    }
    $manifestPath = Join-Path $contract 'asset-build.contract.json'
    Write-BuildContractJsonAtomic $document $manifestPath
    Write-Output 'asset_build_command_version=1'
    Write-Output 'asset_build_contract_version=1'
    Write-Output "tool_version=$($script:AssetBuildToolVersion)"
    Write-Output "profile=$Profile"
    Write-Output 'dry_run=false'
    Write-Output "contract_directory=$contract"
    Write-Output "contract_manifest=$manifestPath"
    Write-Output "item_count=$($contractItems.Count)"
    Write-Output 'verification=ok'
} catch {
    if ($createdContract -and (Test-Path -LiteralPath $contract)) {
        # 失败只清理本次新建的 contract 目录，不触碰 candidate 或 Runtime package。
        Remove-Item -LiteralPath $contract -Recurse -Force
    }
    throw
}
