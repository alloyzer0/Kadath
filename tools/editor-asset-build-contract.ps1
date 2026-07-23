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

function Resolve-BuildContractCandidate([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "Candidate root does not exist: $Path" }
    $candidate = (Resolve-Path -LiteralPath $Path).Path
    $info = Get-Item -LiteralPath $candidate
    if (($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Candidate root cannot be a reparse point' }
    if ($candidate -match '(?i)[\\/]bin[\\/]assets([\\/]|$)') { throw 'Candidate root must be the candidate parent, not bin/assets' }
    return $candidate
}

function Resolve-BuildContractDirectory([string]$Path, [string]$Candidate) {
    $contract = [IO.Path]::GetFullPath($Path)
    if ([string]::IsNullOrWhiteSpace($contract) -or $contract -eq [IO.Path]::GetPathRoot($contract)) { throw "Invalid contract directory: $Path" }
    $candidatePrefix = $Candidate.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $contractPrefix = $contract.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if ($contract.Equals($Candidate, [StringComparison]::OrdinalIgnoreCase) -or $contract.StartsWith($candidatePrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Contract directory must not be inside candidate: $contract" }
    if ($Candidate.StartsWith($contractPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Contract directory must not contain candidate: $contract" }
    if ($contract -match '(?i)[\\/]bin[\\/]assets([\\/]|$)') { throw 'Contract directory must not be package/bin/assets' }
    if (Test-Path -LiteralPath $contract) { throw "Refusing to overwrite existing contract directory: $contract" }
    $existingParent = Split-Path -Parent $contract
    while (-not (Test-Path -LiteralPath $existingParent -PathType Container)) {
        $nextParent = Split-Path -Parent $existingParent
        if ([string]::IsNullOrWhiteSpace($nextParent) -or $nextParent -eq $existingParent) { throw "Cannot resolve contract parent: $contract" }
        $existingParent = $nextParent
    }
    $parentInfo = Get-Item -LiteralPath $existingParent
    if (($parentInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Contract parent cannot be a reparse point' }
    return $contract
}

function Get-BuildArtifactType([string]$Category, [string]$Extension, [string]$RelativePath) {
    switch ($Category) {
        'Texture' { if ($Extension -eq 'texture') { return 'RuntimeTextureArtifactV1' }; return 'RuntimeTextureSourceV1' }
        'Audio' { if ($RelativePath.EndsWith('.audio.wav', [StringComparison]::OrdinalIgnoreCase)) { return 'RuntimeAudioArtifactV1' }; return 'RuntimeAudioSourceV1' }
        'Scene' { if ($Extension -eq 'scene') { return 'RuntimeSceneArtifactV1' }; return 'RuntimeSceneDocumentV1' }
        'Script' { if ($Extension -eq 'script') { return 'RuntimeScriptArtifactV1' }; return 'RuntimeScriptDocumentV1' }
        default { return 'RuntimeBinarySourceV1' }
    }
}

function Read-BuildContractCandidate([string]$Candidate, [string]$Profile) {
    $promotionPath = Join-Path $Candidate 'bin\asset-promotion.manifest.json'
    if (-not (Test-Path -LiteralPath $promotionPath -PathType Leaf)) { throw "Promotion manifest does not exist: $promotionPath" }
    try { $promotion = Get-Content -LiteralPath $promotionPath -Raw -Encoding utf8 | ConvertFrom-Json } catch { throw "Failed to parse promotion manifest: $($_.Exception.Message)" }
    if ([int]$promotion.PromotionVersion -ne 1 -or [int]$promotion.CommandVersion -ne 1) { throw 'Build Contract requires Promotion Manifest v1 / Command v1' }
    if ([string]$promotion.CandidateKind -cne 'asset-payload-v1' -or [string]$promotion.Processing -cne 'passthrough-v1') { throw 'Unsupported candidate processing contract' }
    if ([string]$promotion.Profile -cne $Profile) { throw "Candidate profile does not match requested profile: expected=$Profile actual=$($promotion.Profile)" }
    $items = @($promotion.Items)
    if ([int]$promotion.ItemCount -ne $items.Count -or $items.Count -eq 0) { throw 'Candidate ItemCount is invalid' }
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $items) {
        $inputPath = [string]$item.DestinationPath
        if ([IO.Path]::IsPathRooted($inputPath) -or -not $inputPath.StartsWith('bin/assets/', [StringComparison]::Ordinal)) { throw "Invalid candidate artifact path: $inputPath" }
        if (-not $seen.Add($inputPath)) { throw "Duplicate candidate artifact path: $inputPath" }
        $filePath = Join-Path $Candidate $inputPath.Replace('/', [IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) { throw "Candidate artifact does not exist: $inputPath" }
        $file = Get-Item -LiteralPath $filePath
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Candidate artifact cannot be a reparse point: $inputPath" }
        if ([long]$item.SizeBytes -ne [long]$file.Length) { throw "Candidate artifact size mismatch: $inputPath" }
        $hash = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($hash -cne [string]$item.Sha256) { throw "Candidate artifact hash mismatch: $inputPath" }
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
    $inputArtifactType = Get-BuildArtifactType ([string]$_.Category) ([string]$_.Extension) $inputPath
    $isSceneSource = [string]$_.Category -ceq 'Scene' -and $inputPath.EndsWith('.scene.json', [StringComparison]::OrdinalIgnoreCase)
    $isScriptSource = [string]$_.Category -ceq 'Script' -and $inputPath.EndsWith('.script.json', [StringComparison]::OrdinalIgnoreCase)
    # 关键契约：candidate 仍保存可编辑 JSON，build 输出稳定的 KSCN/KSCP Runtime artifact。
    $outputPath = if ($isSceneSource -or $isScriptSource) { $inputPath.Substring(0, $inputPath.Length - '.json'.Length) } else { $inputPath }
    [ordered]@{
        AssetId = $_.AssetId
        InputPath = $inputPath
        OutputPath = $outputPath
        InputArtifactType = $inputArtifactType
        ArtifactType = if ($isSceneSource) { 'RuntimeSceneArtifactV1' } elseif ($isScriptSource) { 'RuntimeScriptArtifactV1' } else { $inputArtifactType }
        ImporterStatus = if ($isSceneSource -or $isScriptSource) { 'implemented-v1' } else { 'not-defined' }
        BakerStatus = if ($isSceneSource -or $isScriptSource) { 'implemented-v1' } else { 'not-defined' }
        Transform = if ($isSceneSource) { 'scene-json-to-kscn-f32-v1' } elseif ($isScriptSource) { 'script-json-to-kscp-v1' } else { 'passthrough-v1' }
        SizeBytes = $_.SizeBytes
        Sha256 = $_.Sha256
    }
})

# Candidate 本身保持不可变；profile 语义只描述安装阶段会执行的确定性派生变换。
$profileSemantics = [ordered]@{
    debug = 'candidate payload unchanged; Texture PPM -> KDAT Texture Artifact v1 base-only; Scene JSON -> KSCN Scene Artifact v1; Script JSON -> KSCP Script Artifact v1; other importer/baker not defined'
    release = 'candidate payload unchanged; Texture PPM -> KDAT Texture Artifact v2 mipmap chain; Scene JSON -> KSCN Scene Artifact v1; Script JSON -> KSCP Script Artifact v1; other importer/baker not defined'
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
