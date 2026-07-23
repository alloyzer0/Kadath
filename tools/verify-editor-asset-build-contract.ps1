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

function Assert-BuildContract([string]$ContractDirectory, [string]$ExpectedProfile) {
    $manifestPath = Join-Path $ContractDirectory 'asset-build.contract.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Build contract manifest missing: $manifestPath" }
    $contract = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json
    if ([int]$contract.ContractVersion -ne 1 -or [int]$contract.CommandVersion -ne 1 -or [string]$contract.ToolVersion -cne 'kadath-asset-contract/1') { throw 'Unexpected Build Contract version/tool' }
    if ([string]$contract.Action -cne 'build-contract' -or [string]$contract.Profile -cne $ExpectedProfile) { throw "Unexpected build contract action/profile: $($contract.Action)/$($contract.Profile)" }
    if ([string]$contract.InputCandidateKind -cne 'asset-payload-v1' -or [string]$contract.OutputKind -cne 'runtime-source-payload-v1') { throw 'Unexpected build contract input/output kind' }
    if ([string]$contract.TransformPolicy -cne 'passthrough-v1' -or [string]$contract.ImporterStatus -cne 'not-defined' -or [string]$contract.BakerStatus -cne 'not-defined') { throw 'Build contract must explicitly mark importer/baker as not-defined' }
    if ([string]$contract.ProfileSemantics.debug -notlike '*KDAT Texture Artifact v1 base-only*' -or [string]$contract.ProfileSemantics.release -notlike '*KDAT Texture Artifact v2 mipmap chain*' -or [string]$contract.ProfileSemantics.debug -notlike '*KSCN Scene Artifact v1*' -or [string]$contract.ProfileSemantics.release -notlike '*KSCN Scene Artifact v1*' -or [string]$contract.ProfileSemantics.debug -notlike '*KSCP Script Artifact v1*' -or [string]$contract.ProfileSemantics.release -notlike '*KSCP Script Artifact v1*') { throw 'Build Contract profile semantics do not describe texture/scene/script transforms' }
    if (-not [bool]$contract.PromotionRequired -or [string]$contract.InputAssetRoot -cne 'bin/assets' -or [string]$contract.OutputAssetRoot -cne 'bin/assets') { throw 'Build contract promotion/root boundary is invalid' }
    if ([int]$contract.ItemCount -ne 5 -or @($contract.Items).Count -ne 5) { throw "Expected 5 contract items, got $($contract.ItemCount)" }
    $expectedContracts = @{
        'bin/assets/audio/lost.wav' = @{ OutputPath = 'bin/assets/audio/lost.wav'; InputArtifactType = 'RuntimeAudioSourceV1'; ArtifactType = 'RuntimeAudioSourceV1'; Transform = 'passthrough-v1'; ImporterStatus = 'not-defined'; BakerStatus = 'not-defined' }
        'bin/assets/audio/won.wav' = @{ OutputPath = 'bin/assets/audio/won.wav'; InputArtifactType = 'RuntimeAudioSourceV1'; ArtifactType = 'RuntimeAudioSourceV1'; Transform = 'passthrough-v1'; ImporterStatus = 'not-defined'; BakerStatus = 'not-defined' }
        'bin/assets/renderer2d/test.ppm' = @{ OutputPath = 'bin/assets/renderer2d/test.ppm'; InputArtifactType = 'RuntimeTextureSourceV1'; ArtifactType = 'RuntimeTextureSourceV1'; Transform = 'passthrough-v1'; ImporterStatus = 'not-defined'; BakerStatus = 'not-defined' }
        'bin/assets/scenes/preview.scene.json' = @{ OutputPath = 'bin/assets/scenes/preview.scene'; InputArtifactType = 'RuntimeSceneDocumentV1'; ArtifactType = 'RuntimeSceneArtifactV1'; Transform = 'scene-json-to-kscn-f32-v1'; ImporterStatus = 'implemented-v1'; BakerStatus = 'implemented-v1' }
        'bin/assets/scripts/preview.script.json' = @{ OutputPath = 'bin/assets/scripts/preview.script'; InputArtifactType = 'RuntimeScriptDocumentV1'; ArtifactType = 'RuntimeScriptArtifactV1'; Transform = 'script-json-to-kscp-v1'; ImporterStatus = 'implemented-v1'; BakerStatus = 'implemented-v1' }
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
try {
    [void](Invoke-Tool $assetTool @('-Action', 'Import', '-SourceRoot', $source, '-StagingDirectory', $staging))
    [void](Invoke-Tool $promoteTool @('-StagingDirectory', $staging, '-DestinationRoot', $candidate, '-Profile', 'debug'))
    [void](Invoke-Tool $promoteTool @('-StagingDirectory', $staging, '-DestinationRoot', $releaseCandidate, '-Profile', 'release'))
    $candidateHashesBefore = Get-TreeHashes $candidate
    $releaseCandidateHashesBefore = Get-TreeHashes $releaseCandidate

    $dry = Invoke-Tool $contractTool @('-CandidateRoot', $candidate, '-ContractDirectory', $dryContract, '-Profile', 'debug', '-DryRun')
    $plan = $dry.Output[-1] | ConvertFrom-Json
    if ([int]$plan.CommandVersion -ne 1 -or [int]$plan.ContractVersion -ne 1 -or [string]$plan.ToolVersion -cne 'kadath-asset-contract/1' -or [string]$plan.Profile -cne 'debug' -or -not [bool]$plan.DryRun) { throw 'Invalid Build Contract dry-run plan' }
    if ([int]$plan.ItemCount -ne 5 -or (Test-Path -LiteralPath $dryContract)) { throw 'Build Contract dry-run must not create output' }
    if ([string]$plan.ProfileSemantics.debug -notlike '*KDAT Texture Artifact v1 base-only*' -or [string]$plan.ProfileSemantics.release -notlike '*KDAT Texture Artifact v2 mipmap chain*' -or [string]$plan.ProfileSemantics.debug -notlike '*KSCN Scene Artifact v1*' -or [string]$plan.ProfileSemantics.release -notlike '*KSCN Scene Artifact v1*' -or [string]$plan.ProfileSemantics.debug -notlike '*KSCP Script Artifact v1*' -or [string]$plan.ProfileSemantics.release -notlike '*KSCP Script Artifact v1*') { throw 'Build Contract dry-run profile semantics are invalid' }

    [void](Invoke-Tool $contractTool @('-CandidateRoot', $candidate, '-ContractDirectory', $debugContract, '-Profile', 'debug'))
    $debugManifest = Assert-BuildContract $debugContract 'debug'
    [void](Invoke-Tool $contractTool @('-CandidateRoot', $releaseCandidate, '-ContractDirectory', $releaseContract, '-Profile', 'release'))
    $releaseManifest = Assert-BuildContract $releaseContract 'release'
    if (($debugManifest.Items | ConvertTo-Json -Depth 8 -Compress) -cne ($releaseManifest.Items | ConvertTo-Json -Depth 8 -Compress)) { throw 'Debug and release contract items must be equivalent' }

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
    Write-Output 'verification=ok'
} finally {
    if (Test-Path -LiteralPath $output) {
        # verifier 只清理自己创建的隔离输出根。
        Remove-Item -LiteralPath $output -Recurse -Force
    }
}
