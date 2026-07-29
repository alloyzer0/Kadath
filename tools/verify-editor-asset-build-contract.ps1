[CmdletBinding()]
param(
    [string]$SourceRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'assets'),
    [string]$OutputDirectory = (Join-Path $env:TEMP ("kadath-asset-contract-" + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')))
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$assetTool = Join-Path $PSScriptRoot 'editor-asset-tool.ps1'
$promoteTool = Join-Path $PSScriptRoot 'editor-asset-promote.ps1'
$contractTool = Join-Path $PSScriptRoot 'editor-asset-build-contract.ps1'
foreach ($scriptPath in @($assetTool, $promoteTool, $contractTool)) {
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { throw "Required Asset Tool script does not exist: $scriptPath" }
}
$source = (Resolve-Path -LiteralPath $SourceRoot).Path
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $output) { throw "Output directory already exists: $output" }

function Invoke-Tool([string]$ScriptPath, [string[]]$Arguments, [switch]$ExpectFailure) {
    $result = @(& pwsh -NoProfile -File $ScriptPath @Arguments 2>&1 | ForEach-Object { $_.ToString() })
    $exitCode = $LASTEXITCODE
    if (-not $ExpectFailure -and $exitCode -ne 0) { throw "Tool failed with code $exitCode`: $($result -join ' | ')" }
    if ($ExpectFailure -and $exitCode -eq 0) { throw 'Tool unexpectedly accepted an invalid build contract request' }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $result }
}

function Get-TreeHashes([string]$Root) {
    $hashes = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -File -Recurse -Force)) {
        $relative = [IO.Path]::GetRelativePath($Root, $file.FullName).Replace('\', '/')
        $hashes[$relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    return $hashes
}

function Add-PromotionManifestItem([string]$Candidate, [object]$Item) {
    $manifestPath = Join-Path $Candidate 'bin\asset-promotion.manifest.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json
    $items = [Collections.Generic.List[object]]::new()
    foreach ($existing in @($manifest.Items)) { $items.Add($existing) }
    $items.Add($Item)
    $manifest.Items = $items.ToArray()
    $manifest.ItemCount = $items.Count
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
}

function Assert-TreeHashesEqual([hashtable]$Before, [string]$Root, [string]$Name) {
    $after = Get-TreeHashes $Root
    if ($Before.Count -ne $after.Count) { throw "$Name changed the candidate file count" }
    foreach ($key in $Before.Keys) {
        if (-not $after.ContainsKey($key) -or $Before[$key] -cne $after[$key]) { throw "$Name changed candidate content: $key" }
    }
}

function Assert-BuildContract([string]$ContractDirectory, [string]$ExpectedProfile, [switch]$IncludeCompatibilityPpm) {
    $manifestPath = Join-Path $ContractDirectory 'asset-build.contract.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Build contract manifest missing: $manifestPath" }
    $contract = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json
    if ([int]$contract.ContractVersion -ne 1 -or [int]$contract.CommandVersion -ne 1 -or [string]$contract.ToolVersion -cne 'kadath-asset-contract/1') { throw 'Unexpected Build Contract version/tool' }
    if ([string]$contract.Action -cne 'build-contract' -or [string]$contract.Profile -cne $ExpectedProfile) { throw "Unexpected build contract action/profile: $($contract.Action)/$($contract.Profile)" }
    if ([string]$contract.InputCandidateKind -cne 'asset-payload-v1' -or [string]$contract.OutputKind -cne 'runtime-source-payload-v1') { throw 'Unexpected build contract input/output kind' }
    if ([string]$contract.TransformPolicy -cne 'passthrough-v1' -or [string]$contract.ImporterStatus -cne 'not-defined' -or [string]$contract.BakerStatus -cne 'not-defined') { throw 'Build contract must explicitly mark importer/baker as not-defined' }
    if ([string]$contract.ProfileSemantics.debug -notlike '*KDAT Texture Artifact v1 base-only*' -or [string]$contract.ProfileSemantics.release -notlike '*KDAT Texture Artifact v2 mipmap chain*' -or [string]$contract.ProfileSemantics.debug -notlike '*KSCN Scene Artifact v1*' -or [string]$contract.ProfileSemantics.release -notlike '*KSCN Scene Artifact v1*' -or [string]$contract.ProfileSemantics.debug -notlike '*KSCP Script Artifact v1*' -or [string]$contract.ProfileSemantics.release -notlike '*KSCP Script Artifact v1*') { throw 'Build Contract profile semantics do not describe texture/scene/script transforms' }
    if (-not [bool]$contract.PromotionRequired -or [string]$contract.InputAssetRoot -cne 'bin/assets' -or [string]$contract.OutputAssetRoot -cne 'bin/assets') { throw 'Build contract promotion/root boundary is invalid' }
    $expectedItemCount = if ($IncludeCompatibilityPpm) { 7 } else { 6 }
    if ([int]$contract.ItemCount -ne $expectedItemCount -or @($contract.Items).Count -ne $expectedItemCount) { throw "Expected $expectedItemCount contract items, got $($contract.ItemCount)" }
    $textureTransform = if ($ExpectedProfile -eq 'debug') { 'png-to-rgba8-artifact-v1' } else { 'png-to-rgba8-mipmap-artifact-v2' }
    $expectedContracts = @{
        'bin/assets/audio/lost.wav' = @{ OutputPath = 'bin/assets/audio/lost.wav'; InputArtifactType = 'RuntimeAudioSourceV1'; ArtifactType = 'RuntimeAudioSourceV1'; Transform = 'passthrough-v1'; ImporterStatus = 'not-defined'; BakerStatus = 'not-defined' }
        'bin/assets/audio/won.wav' = @{ OutputPath = 'bin/assets/audio/won.wav'; InputArtifactType = 'RuntimeAudioSourceV1'; ArtifactType = 'RuntimeAudioSourceV1'; Transform = 'passthrough-v1'; ImporterStatus = 'not-defined'; BakerStatus = 'not-defined' }
        # PNG source 仍是 candidate 输入；Build Contract 必须描述真正的离线 Texture bake，而不是伪装成 passthrough。
        'bin/assets/renderer2d/goal.png' = @{ OutputPath = 'bin/assets/renderer2d/goal.texture'; InputArtifactType = 'RuntimeTextureSourceV1'; ArtifactType = 'RuntimeTextureArtifactV1'; Transform = $textureTransform; ImporterStatus = 'implemented-v1'; BakerStatus = 'implemented-v1' }
        'bin/assets/renderer2d/test.png' = @{ OutputPath = 'bin/assets/renderer2d/test.texture'; InputArtifactType = 'RuntimeTextureSourceV1'; ArtifactType = 'RuntimeTextureArtifactV1'; Transform = $textureTransform; ImporterStatus = 'implemented-v1'; BakerStatus = 'implemented-v1' }
        'bin/assets/scenes/preview.scene.json' = @{ OutputPath = 'bin/assets/scenes/preview.scene'; InputArtifactType = 'RuntimeSceneDocumentV1'; ArtifactType = 'RuntimeSceneArtifactV1'; Transform = 'scene-json-to-kscn-f32-v1'; ImporterStatus = 'implemented-v1'; BakerStatus = 'implemented-v1' }
        'bin/assets/scripts/preview.script.json' = @{ OutputPath = 'bin/assets/scripts/preview.script'; InputArtifactType = 'RuntimeScriptDocumentV1'; ArtifactType = 'RuntimeScriptArtifactV1'; Transform = 'script-json-to-kscp-v1'; ImporterStatus = 'implemented-v1'; BakerStatus = 'implemented-v1' }
    }
    if ($IncludeCompatibilityPpm) {
        $ppmTransform = if ($ExpectedProfile -eq 'debug') { 'ppm-to-rgba8-artifact-v1' } else { 'ppm-to-rgba8-mipmap-artifact-v2' }
        $expectedContracts['bin/assets/renderer2d/compatibility.ppm'] = @{ OutputPath = 'bin/assets/renderer2d/compatibility.texture'; InputArtifactType = 'RuntimeTextureSourceV1'; ArtifactType = 'RuntimeTextureArtifactV1'; Transform = $ppmTransform; ImporterStatus = 'implemented-v1'; BakerStatus = 'implemented-v1' }
    }
    foreach ($item in @($contract.Items)) {
        $inputPath = [string]$item.InputPath
        if (-not $expectedContracts.ContainsKey($inputPath)) { throw "Unexpected contract path: $inputPath" }
        $expected = $expectedContracts[$inputPath]
        if ([IO.Path]::IsPathRooted($inputPath) -or [string]$item.OutputPath -cne $expected.OutputPath) { throw "Invalid contract path: $inputPath" }
        if ([string]$item.InputArtifactType -cne $expected.InputArtifactType -or [string]$item.ArtifactType -cne $expected.ArtifactType -or [string]$item.Transform -cne $expected.Transform) { throw "Invalid contract artifact mapping: $inputPath" }
        if ([string]$item.ImporterStatus -cne $expected.ImporterStatus -or [string]$item.BakerStatus -cne $expected.BakerStatus) { throw "Contract item importer/baker status is invalid: $inputPath" }
    }
    $files = @(Get-ChildItem -LiteralPath $ContractDirectory -File -Recurse)
    if ($files.Count -ne 1) { throw "Contract directory must contain only one manifest, got $($files.Count) files" }
    return $contract
}

$staging = Join-Path $output 'staging'
$candidate = Join-Path $output 'candidate-debug'
$releaseCandidate = Join-Path $output 'candidate-release'
$dryContract = Join-Path $output 'contract-dry-run'
$debugContract = Join-Path $output 'contract-debug'
$releaseContract = Join-Path $output 'contract-release'
$ppmSourceFixture = Join-Path $output 'source-fixture-ppm-success'
$ppmStaging = Join-Path $output 'staging-ppm-success'
$ppmDebugCandidate = Join-Path $output 'candidate-ppm-debug'
$ppmReleaseCandidate = Join-Path $output 'candidate-ppm-release'
$ppmDebugContract = Join-Path $output 'contract-ppm-debug'
$ppmReleaseContract = Join-Path $output 'contract-ppm-release'
$collisionCandidate = Join-Path $output 'candidate-output-collision'
$collisionContract = Join-Path $output 'contract-output-collision'
$sourceArtifactCollisionCandidate = Join-Path $output 'candidate-source-artifact-collision'
$sourceArtifactCollisionContract = Join-Path $output 'contract-source-artifact-collision'
$traversalCandidate = Join-Path $output 'candidate-path-traversal'
$traversalContract = Join-Path $output 'contract-path-traversal'
$canonicalCollisionCandidate = Join-Path $output 'candidate-canonical-collision'
$canonicalCollisionContract = Join-Path $output 'contract-canonical-collision'
$junctionCandidate = Join-Path $output 'candidate-junction'
$junctionContract = Join-Path $output 'contract-junction'
$junctionTarget = Join-Path $output 'candidate-junction-target'
$deviceCandidateContract = Join-Path $output 'contract-device-candidate'
$deviceContractActual = Join-Path $output 'contract-device-output'
$sourceFixture = Join-Path $output 'source-fixture'
try {
    # 复制 source fixture，避免 verifier 构造输出碰撞时触碰 checked-in assets。
    Copy-Item -LiteralPath $source -Destination $sourceFixture -Recurse
    [void](Invoke-Tool $assetTool @('-Action', 'Import', '-SourceRoot', $sourceFixture, '-StagingDirectory', $staging))
    [void](Invoke-Tool $promoteTool @('-StagingDirectory', $staging, '-DestinationRoot', $candidate, '-Profile', 'debug'))
    [void](Invoke-Tool $promoteTool @('-StagingDirectory', $staging, '-DestinationRoot', $releaseCandidate, '-Profile', 'release'))
    $candidateHashesBefore = Get-TreeHashes $candidate
    $releaseCandidateHashesBefore = Get-TreeHashes $releaseCandidate

    # 恶意 promotion manifest 仍必须经过 Build Contract 自己的 canonical path boundary，不能信任上游字符串。
    Copy-Item -LiteralPath $candidate -Destination $traversalCandidate -Recurse
    $escapedSource = Join-Path $traversalCandidate 'escaped.png'
    [IO.File]::WriteAllBytes($escapedSource, [byte[]](1,2,3,4))
    Add-PromotionManifestItem $traversalCandidate ([pscustomobject]@{
        AssetId = 'asset://../../escaped.png'
        StagedPath = 'assets/../../escaped.png'
        DestinationPath = 'bin/assets/../../escaped.png'
        Category = 'Texture'
        Extension = 'png'
        SizeBytes = 4
        Sha256 = (Get-FileHash -LiteralPath $escapedSource -Algorithm SHA256).Hash.ToLowerInvariant()
    })
    $traversalHashes = Get-TreeHashes $traversalCandidate
    [void](Invoke-Tool $contractTool @('-CandidateRoot', $traversalCandidate, '-ContractDirectory', $traversalContract, '-Profile', 'debug') -ExpectFailure)
    if (Test-Path -LiteralPath $traversalContract) { throw 'Traversal input created a partial Build Contract' }
    Assert-TreeHashesEqual $traversalHashes $traversalCandidate 'Traversal rejection'

    # `nested/../test.png` 与 canonical test.png 指向同一 source/output；不得以 raw string 绕过 collision identity。
    Copy-Item -LiteralPath $candidate -Destination $canonicalCollisionCandidate -Recurse
    New-Item -ItemType Directory -Path (Join-Path $canonicalCollisionCandidate 'bin\assets\renderer2d\nested') | Out-Null
    $canonicalSource = Join-Path $canonicalCollisionCandidate 'bin\assets\renderer2d\test.png'
    $canonicalSourceInfo = Get-Item -LiteralPath $canonicalSource
    Add-PromotionManifestItem $canonicalCollisionCandidate ([pscustomobject]@{
        AssetId = 'asset://renderer2d/nested/../test.png'
        StagedPath = 'assets/renderer2d/nested/../test.png'
        DestinationPath = 'bin/assets/renderer2d/nested/../test.png'
        Category = 'Texture'
        Extension = 'png'
        SizeBytes = $canonicalSourceInfo.Length
        Sha256 = (Get-FileHash -LiteralPath $canonicalSource -Algorithm SHA256).Hash.ToLowerInvariant()
    })
    $canonicalCollisionHashes = Get-TreeHashes $canonicalCollisionCandidate
    [void](Invoke-Tool $contractTool @('-CandidateRoot', $canonicalCollisionCandidate, '-ContractDirectory', $canonicalCollisionContract, '-Profile', 'debug') -ExpectFailure)
    if (Test-Path -LiteralPath $canonicalCollisionContract) { throw 'Canonical-equivalent collision created a partial Build Contract' }
    Assert-TreeHashesEqual $canonicalCollisionHashes $canonicalCollisionCandidate 'Canonical collision rejection'

    # leaf 自身不是 reparse point 仍不够：任一中间目录 junction 都必须在读取/输出投影前拒绝。
    Copy-Item -LiteralPath $candidate -Destination $junctionCandidate -Recurse
    New-Item -ItemType Directory -Path $junctionTarget | Out-Null
    $junctionSource = Join-Path $junctionTarget 'outside.png'
    [IO.File]::WriteAllBytes($junctionSource, [byte[]](9,8,7,6))
    New-Item -ItemType Junction -Path (Join-Path $junctionCandidate 'bin\assets\linked') -Target $junctionTarget | Out-Null
    Add-PromotionManifestItem $junctionCandidate ([pscustomobject]@{
        AssetId = 'asset://linked/outside.png'
        StagedPath = 'assets/linked/outside.png'
        DestinationPath = 'bin/assets/linked/outside.png'
        Category = 'Texture'
        Extension = 'png'
        SizeBytes = 4
        Sha256 = (Get-FileHash -LiteralPath $junctionSource -Algorithm SHA256).Hash.ToLowerInvariant()
    })
    $junctionManifestHash = (Get-FileHash -LiteralPath (Join-Path $junctionCandidate 'bin\asset-promotion.manifest.json') -Algorithm SHA256).Hash
    $junctionSourceHash = (Get-FileHash -LiteralPath $junctionSource -Algorithm SHA256).Hash
    [void](Invoke-Tool $contractTool @('-CandidateRoot', $junctionCandidate, '-ContractDirectory', $junctionContract, '-Profile', 'debug') -ExpectFailure)
    if (Test-Path -LiteralPath $junctionContract) { throw 'Junction input created a partial Build Contract' }
    if ((Get-FileHash -LiteralPath (Join-Path $junctionCandidate 'bin\asset-promotion.manifest.json') -Algorithm SHA256).Hash -cne $junctionManifestHash -or
        (Get-FileHash -LiteralPath $junctionSource -Algorithm SHA256).Hash -cne $junctionSourceHash) { throw 'Junction rejection changed candidate/foreign content' }

    $deviceCandidate = '\\?\' + $candidate
    [void](Invoke-Tool $contractTool @('-CandidateRoot', $deviceCandidate, '-ContractDirectory', $deviceCandidateContract, '-Profile', 'debug') -ExpectFailure)
    if (Test-Path -LiteralPath $deviceCandidateContract) { throw 'Device-alias candidate created a Build Contract' }
    $deviceContract = '\\?\' + $deviceContractActual
    [void](Invoke-Tool $contractTool @('-CandidateRoot', $candidate, '-ContractDirectory', $deviceContract, '-Profile', 'debug') -ExpectFailure)
    if (Test-Path -LiteralPath $deviceContractActual) { throw 'Device-alias contract destination created output' }
    [void](Invoke-Tool $contractTool @('-CandidateRoot', '\\invalid-kadath-host\asset-share', '-ContractDirectory', (Join-Path $output 'contract-unc-candidate'), '-Profile', 'debug') -ExpectFailure)

    $dry = Invoke-Tool $contractTool @('-CandidateRoot', $candidate, '-ContractDirectory', $dryContract, '-Profile', 'debug', '-DryRun')
    $plan = $dry.Output[-1] | ConvertFrom-Json
    if ([int]$plan.CommandVersion -ne 1 -or [int]$plan.ContractVersion -ne 1 -or [string]$plan.ToolVersion -cne 'kadath-asset-contract/1' -or [string]$plan.Profile -cne 'debug' -or -not [bool]$plan.DryRun) { throw 'Invalid Build Contract dry-run plan' }
    if ([int]$plan.ItemCount -ne 6 -or (Test-Path -LiteralPath $dryContract)) { throw 'Build Contract dry-run must not create output' }
    if ([string]$plan.ProfileSemantics.debug -notlike '*KDAT Texture Artifact v1 base-only*' -or [string]$plan.ProfileSemantics.release -notlike '*KDAT Texture Artifact v2 mipmap chain*' -or [string]$plan.ProfileSemantics.debug -notlike '*KSCN Scene Artifact v1*' -or [string]$plan.ProfileSemantics.release -notlike '*KSCN Scene Artifact v1*' -or [string]$plan.ProfileSemantics.debug -notlike '*KSCP Script Artifact v1*' -or [string]$plan.ProfileSemantics.release -notlike '*KSCP Script Artifact v1*') { throw 'Build Contract dry-run profile semantics are invalid' }

    [void](Invoke-Tool $contractTool @('-CandidateRoot', $candidate, '-ContractDirectory', $debugContract, '-Profile', 'debug'))
    $debugManifest = Assert-BuildContract $debugContract 'debug'
    [void](Invoke-Tool $contractTool @('-CandidateRoot', $releaseCandidate, '-ContractDirectory', $releaseContract, '-Profile', 'release'))
    $releaseManifest = Assert-BuildContract $releaseContract 'release'
    $debugTexture = @($debugManifest.Items | Where-Object { [string]$_.InputPath -ceq 'bin/assets/renderer2d/test.png' })
    $releaseTexture = @($releaseManifest.Items | Where-Object { [string]$_.InputPath -ceq 'bin/assets/renderer2d/test.png' })
    if ($debugTexture.Count -ne 1 -or $releaseTexture.Count -ne 1 -or [string]$debugTexture[0].Transform -cne 'png-to-rgba8-artifact-v1' -or [string]$releaseTexture[0].Transform -cne 'png-to-rgba8-mipmap-artifact-v2') { throw 'Build Contract did not project the profile-specific PNG transform' }
    $debugNonTexture = @($debugManifest.Items | Where-Object { [string]$_.InputPath -cne 'bin/assets/renderer2d/test.png' }) | ConvertTo-Json -Depth 8 -Compress
    $releaseNonTexture = @($releaseManifest.Items | Where-Object { [string]$_.InputPath -cne 'bin/assets/renderer2d/test.png' }) | ConvertTo-Json -Depth 8 -Compress
    if ($debugNonTexture -cne $releaseNonTexture) { throw 'Non-texture Build Contract items changed across profiles' }

    # 独立成功 candidate 证明 PPM 兼容 source 仍获得完整 per-item Runtime contract，而不只出现在失败 collision 中。
    Copy-Item -LiteralPath $source -Destination $ppmSourceFixture -Recurse
    $ppmCompatibilitySource = Join-Path $ppmSourceFixture 'renderer2d\compatibility.ppm'
    [IO.File]::WriteAllText($ppmCompatibilitySource, "P3`n1 1`n255`n1 2 3`n", [Text.UTF8Encoding]::new($false))
    [void](Invoke-Tool $assetTool @('-Action', 'Import', '-SourceRoot', $ppmSourceFixture, '-StagingDirectory', $ppmStaging))
    [void](Invoke-Tool $promoteTool @('-StagingDirectory', $ppmStaging, '-DestinationRoot', $ppmDebugCandidate, '-Profile', 'debug'))
    [void](Invoke-Tool $promoteTool @('-StagingDirectory', $ppmStaging, '-DestinationRoot', $ppmReleaseCandidate, '-Profile', 'release'))
    [void](Invoke-Tool $contractTool @('-CandidateRoot', $ppmDebugCandidate, '-ContractDirectory', $ppmDebugContract, '-Profile', 'debug'))
    [void](Invoke-Tool $contractTool @('-CandidateRoot', $ppmReleaseCandidate, '-ContractDirectory', $ppmReleaseContract, '-Profile', 'release'))
    $ppmDebugManifest = Assert-BuildContract $ppmDebugContract 'debug' -IncludeCompatibilityPpm
    $ppmReleaseManifest = Assert-BuildContract $ppmReleaseContract 'release' -IncludeCompatibilityPpm
    $ppmDebugItem = @($ppmDebugManifest.Items | Where-Object { [string]$_.InputPath -ceq 'bin/assets/renderer2d/compatibility.ppm' })
    $ppmReleaseItem = @($ppmReleaseManifest.Items | Where-Object { [string]$_.InputPath -ceq 'bin/assets/renderer2d/compatibility.ppm' })
    if ($ppmDebugItem.Count -ne 1 -or $ppmReleaseItem.Count -ne 1) { throw 'Independent PPM success candidate did not project exactly one per-item contract' }
    foreach ($item in @($ppmDebugItem[0], $ppmReleaseItem[0])) {
        if ([string]$item.OutputPath -cne 'bin/assets/renderer2d/compatibility.texture' -or [string]$item.InputArtifactType -cne 'RuntimeTextureSourceV1' -or [string]$item.ArtifactType -cne 'RuntimeTextureArtifactV1' -or [string]$item.ImporterStatus -cne 'implemented-v1' -or [string]$item.BakerStatus -cne 'implemented-v1') { throw 'Independent PPM per-item Runtime contract is invalid' }
    }
    if ([string]$ppmDebugItem[0].Transform -cne 'ppm-to-rgba8-artifact-v1' -or [string]$ppmReleaseItem[0].Transform -cne 'ppm-to-rgba8-mipmap-artifact-v2') { throw 'Independent PPM per-item profile transforms are invalid' }

    # 同 basename 的 PPM/PNG 会映射到同一个 .texture；整个 contract 必须在写入前拒绝。
    Copy-Item -LiteralPath $candidate -Destination $collisionCandidate -Recurse
    $collisionPng = Join-Path $collisionCandidate 'bin\assets\renderer2d\collision.png'
    $collisionPpm = Join-Path $collisionCandidate 'bin\assets\renderer2d\collision.ppm'
    [IO.File]::WriteAllBytes($collisionPng, [byte[]](1,2,3))
    [IO.File]::WriteAllText($collisionPpm, "P3`n1 1`n255`n1 2 3`n", [Text.UTF8Encoding]::new($false))
    $collisionManifestPath = Join-Path $collisionCandidate 'bin\asset-promotion.manifest.json'
    $collisionManifest = Get-Content -LiteralPath $collisionManifestPath -Raw -Encoding utf8 | ConvertFrom-Json
    $collisionItems = [Collections.Generic.List[object]]::new()
    foreach ($item in @($collisionManifest.Items)) { $collisionItems.Add($item) }
    foreach ($entry in @(
        [pscustomobject]@{ Path = $collisionPng; Extension = 'png' },
        [pscustomobject]@{ Path = $collisionPpm; Extension = 'ppm' }
    )) {
        $relative = "bin/assets/renderer2d/collision.$($entry.Extension)"
        $file = Get-Item -LiteralPath $entry.Path
        $collisionItems.Add([pscustomobject]@{
            AssetId = "asset://renderer2d/collision.$($entry.Extension)"
            StagedPath = "assets/renderer2d/collision.$($entry.Extension)"
            DestinationPath = $relative
            Category = 'Texture'
            Extension = $entry.Extension
            SizeBytes = $file.Length
            Sha256 = (Get-FileHash -LiteralPath $entry.Path -Algorithm SHA256).Hash.ToLowerInvariant()
        })
    }
    $collisionManifest.Items = $collisionItems.ToArray()
    $collisionManifest.ItemCount = $collisionItems.Count
    [IO.File]::WriteAllText($collisionManifestPath, ($collisionManifest | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    $sourceCollisionResult = Invoke-Tool $contractTool @('-CandidateRoot', $collisionCandidate, '-ContractDirectory', $collisionContract, '-Profile', 'debug') -ExpectFailure
    if (($sourceCollisionResult.Output -join "`n") -notmatch 'Duplicate Build Contract output path') { throw 'PPM/PNG output collision did not report the expected category' }
    if (Test-Path -LiteralPath $collisionContract) { throw 'Output collision created a partial Build Contract' }

    # PNG 派生 output 与既存 .texture passthrough 仅大小写不同；必须由 OrdinalIgnoreCase output identity 拒绝。
    Copy-Item -LiteralPath $candidate -Destination $sourceArtifactCollisionCandidate -Recurse
    $casePng = Join-Path $sourceArtifactCollisionCandidate 'bin\assets\renderer2d\ordinal-case.png'
    $caseTexture = Join-Path $sourceArtifactCollisionCandidate 'bin\assets\renderer2d\ORDINAL-CASE.TEXTURE'
    [IO.File]::WriteAllBytes($casePng, [byte[]](4,5,6))
    [IO.File]::WriteAllBytes($caseTexture, [byte[]](7,8,9))
    $sourceArtifactManifestPath = Join-Path $sourceArtifactCollisionCandidate 'bin\asset-promotion.manifest.json'
    $sourceArtifactManifest = Get-Content -LiteralPath $sourceArtifactManifestPath -Raw -Encoding utf8 | ConvertFrom-Json
    $sourceArtifactItems = [Collections.Generic.List[object]]::new()
    foreach ($item in @($sourceArtifactManifest.Items)) { $sourceArtifactItems.Add($item) }
    foreach ($entry in @(
        [pscustomobject]@{ Path = $casePng; AssetId = 'asset://renderer2d/ordinal-case.png'; StagedPath = 'assets/renderer2d/ordinal-case.png'; DestinationPath = 'bin/assets/renderer2d/ordinal-case.png'; Extension = 'png' },
        [pscustomobject]@{ Path = $caseTexture; AssetId = 'asset://renderer2d/ORDINAL-CASE.TEXTURE'; StagedPath = 'assets/renderer2d/ORDINAL-CASE.TEXTURE'; DestinationPath = 'bin/assets/renderer2d/ORDINAL-CASE.TEXTURE'; Extension = 'texture' }
    )) {
        $file = Get-Item -LiteralPath $entry.Path
        $sourceArtifactItems.Add([pscustomobject]@{
            AssetId = $entry.AssetId
            StagedPath = $entry.StagedPath
            DestinationPath = $entry.DestinationPath
            Category = 'Texture'
            Extension = $entry.Extension
            SizeBytes = $file.Length
            Sha256 = (Get-FileHash -LiteralPath $entry.Path -Algorithm SHA256).Hash.ToLowerInvariant()
        })
    }
    $sourceArtifactManifest.Items = $sourceArtifactItems.ToArray()
    $sourceArtifactManifest.ItemCount = $sourceArtifactItems.Count
    [IO.File]::WriteAllText($sourceArtifactManifestPath, ($sourceArtifactManifest | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    $sourceArtifactCollisionResult = Invoke-Tool $contractTool @('-CandidateRoot', $sourceArtifactCollisionCandidate, '-ContractDirectory', $sourceArtifactCollisionContract, '-Profile', 'debug') -ExpectFailure
    if (($sourceArtifactCollisionResult.Output -join "`n") -notmatch 'Duplicate Build Contract output path') { throw 'Source/existing texture case-insensitive collision did not report the expected category' }
    if (Test-Path -LiteralPath $sourceArtifactCollisionContract) { throw 'Source/existing texture collision created a partial Build Contract' }

    $invalidProfileContract = Join-Path $output 'contract-invalid-profile'
    $invalidOutput = @(& pwsh -NoProfile -File $contractTool -CandidateRoot $candidate -ContractDirectory $invalidProfileContract -Profile release -DryRun 2>&1 | ForEach-Object { $_.ToString() })
    if ($LASTEXITCODE -eq 0) { throw "Profile mismatch unexpectedly succeeded: $($invalidOutput -join ' | ')" }
    if (Test-Path -LiteralPath $invalidProfileContract) { throw 'Profile mismatch created a contract output' }
    $candidateHashesAfter = Get-TreeHashes $candidate
    $releaseCandidateHashesAfter = Get-TreeHashes $releaseCandidate
    if ($candidateHashesBefore.Count -ne $candidateHashesAfter.Count -or $releaseCandidateHashesBefore.Count -ne $releaseCandidateHashesAfter.Count) { throw 'Candidate changed during Build Contract generation' }
    foreach ($key in $candidateHashesBefore.Keys) {
        if (-not $candidateHashesAfter.ContainsKey($key) -or $candidateHashesBefore[$key] -cne $candidateHashesAfter[$key]) { throw "Candidate changed during contract generation: $key" }
    }
    foreach ($key in $releaseCandidateHashesBefore.Keys) {
        if (-not $releaseCandidateHashesAfter.ContainsKey($key) -or $releaseCandidateHashesBefore[$key] -cne $releaseCandidateHashesAfter[$key]) { throw "Release candidate changed during contract generation: $key" }
    }

    Write-Output 'asset_build_command_version=1'
    Write-Output 'asset_build_contract_version=1'
    Write-Output 'tool_version=kadath-asset-contract/1'
    Write-Output 'contract_dry_run=ok'
    Write-Output 'contract_debug=ok'
    Write-Output 'contract_release=ok'
    Write-Output 'artifact_types=ok'
    Write-Output 'scene_artifact_contract=ok'
    Write-Output 'script_artifact_contract=ok'
    Write-Output 'profile_semantics=ok'
    Write-Output 'candidate_immutable=ok'
    Write-Output 'profile_boundary=ok'
    Write-Output 'texture_png_transform=ok'
    Write-Output 'texture_ppm_transform=ok'
    Write-Output 'path_safety=traversal,canonical-collision,junction,device,unc'
    Write-Output 'output_collision_matrix=png-vs-ppm,source-vs-existing-texture-ordinal-ignore-case,canonical-equivalent'
    Write-Output 'verification=ok'
} finally {
    if (Test-Path -LiteralPath $output) {
        # verifier 只清理自己创建的隔离输出根。
        Remove-Item -LiteralPath $output -Recurse -Force
    }
}
