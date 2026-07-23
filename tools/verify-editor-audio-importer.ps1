[CmdletBinding()]
param(
    [string]$SourceDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'assets\audio'),
    [string]$GeneratedDirectory = (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'zig-out') 'bin\assets\audio'),
    [string]$OutputDirectory = (Join-Path $env:TEMP ("kadath-audio-importer-" + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')))
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$tool = Join-Path $PSScriptRoot 'editor-audio-importer.ps1'
if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) { throw "Audio importer does not exist: $tool" }
$sourceRoot = (Resolve-Path -LiteralPath $SourceDirectory).Path
$generatedRoot = (Resolve-Path -LiteralPath $GeneratedDirectory).Path
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $output) { throw "Output directory already exists: $output" }

function Invoke-AudioTool([string[]]$Arguments, [switch]$ExpectFailure) {
    $result = @(& pwsh -NoProfile -File $tool @Arguments 2>&1 | ForEach-Object { $_.ToString() })
    $exitCode = $LASTEXITCODE
    if (-not $ExpectFailure -and $exitCode -ne 0) { throw "Audio importer failed with code $exitCode`: $($result -join ' | ')" }
    if ($ExpectFailure -and $exitCode -eq 0) { throw 'Audio importer unexpectedly accepted invalid input' }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $result }
}

function Get-Hash([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Read-U32Le([byte[]]$Bytes, [int]$Offset) {
    return [uint32]([uint32]$Bytes[$Offset] -bor ([uint32]$Bytes[$Offset + 1] -shl 8) -bor ([uint32]$Bytes[$Offset + 2] -shl 16) -bor ([uint32]$Bytes[$Offset + 3] -shl 24))
}

function Get-WavData([string]$Path) {
    [byte[]]$bytes = [IO.File]::ReadAllBytes($Path)
    $offset = 12
    while ($offset + 8 -le $bytes.Length) {
        $chunkId = [Text.Encoding]::ASCII.GetString($bytes, $offset, 4)
        [int]$chunkBytes = Read-U32Le $bytes ($offset + 4)
        $payloadOffset = $offset + 8
        if ($payloadOffset + $chunkBytes -gt $bytes.Length) { throw "Invalid WAV chunk in verifier: $chunkId" }
        if ($chunkId -ceq 'data') {
            [byte[]]$payload = [byte[]]::new($chunkBytes)
            if ($chunkBytes -gt 0) { [Buffer]::BlockCopy($bytes, $payloadOffset, $payload, 0, $chunkBytes) }
            return $payload
        }
        $offset = $payloadOffset + $chunkBytes + ($chunkBytes % 2)
    }
    throw "WAV data chunk missing: $Path"
}

function Assert-ByteEquivalent([byte[]]$Expected, [byte[]]$Actual, [string]$Context) {
    if ($Expected.Length -ne $Actual.Length) { throw "$Context byte length mismatch" }
    for ($index = 0; $index -lt $Expected.Length; $index++) {
        if ($Expected[$index] -ne $Actual[$index]) { throw "$Context byte mismatch at index $index" }
    }
}

function Assert-CanonicalArtifact([string]$Path, [string]$SourcePath) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Audio artifact missing: $Path" }
    [byte[]]$bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 46) { throw 'Canonical audio artifact is too short' }
    if ([Text.Encoding]::ASCII.GetString($bytes, 0, 4) -cne 'RIFF' -or [Text.Encoding]::ASCII.GetString($bytes, 8, 4) -cne 'WAVE') { throw 'Canonical audio artifact RIFF/WAVE header is invalid' }
    if ([Text.Encoding]::ASCII.GetString($bytes, 12, 4) -cne 'fmt ' -or (Read-U32Le $bytes 16) -ne 16) { throw 'Canonical audio artifact fmt chunk is invalid' }
    if ([BitConverter]::ToUInt16($bytes, 20) -ne 1 -or [BitConverter]::ToUInt16($bytes, 22) -ne 1 -or [BitConverter]::ToUInt32($bytes, 24) -ne 22050 -or [BitConverter]::ToUInt16($bytes, 34) -ne 16) { throw 'Canonical audio artifact PCM format is unexpected' }
    if ([Text.Encoding]::ASCII.GetString($bytes, 36, 4) -cne 'data') { throw 'Canonical audio artifact must contain data immediately after fmt' }
    if ([long](Read-U32Le $bytes 4) + 8L -ne $bytes.Length -or [long](Read-U32Le $bytes 40) + 44L -ne $bytes.Length) { throw 'Canonical audio artifact size fields are inconsistent' }
    # 关键语义：规范化只能删除非运行时 chunk，PCM sample payload 必须逐字节保持。
    Assert-ByteEquivalent (Get-WavData $SourcePath) (Get-WavData $Path) ([IO.Path]::GetFileName($Path))
    return Get-Hash $Path
}

$cueNames = @('lost', 'won')
$sourceHashes = @{}
foreach ($cue in $cueNames) {
    $sourcePath = Join-Path $sourceRoot "$cue.wav"
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw "Audio source missing: $sourcePath" }
    $sourceHashes[$cue] = Get-Hash $sourcePath
}

$invalidSource = Join-Path $output 'invalid.wav'
$invalidArtifact = Join-Path $output 'invalid\invalid.audio.wav'
$invalidPackageArtifact = Join-Path (Split-Path -Parent $output) 'bin\assets\invalid.audio.wav'
try {
    $wonSource = Join-Path $sourceRoot 'won.wav'
    $dryArtifact = Join-Path $output 'dry\won.audio.wav'
    $dry = Invoke-AudioTool @('-SourcePath', $wonSource, '-DestinationPath', $dryArtifact, '-Profile', 'debug', '-DryRun')
    $plan = $dry.Output[-1] | ConvertFrom-Json
    if ([int]$plan.ImporterVersion -ne 1 -or [int]$plan.BakerVersion -ne 1 -or [string]$plan.ArtifactFormat -cne 'CANONICAL-PCM-WAV-V1' -or [string]$plan.Transform -cne 'pcm-wav-to-canonical-wav-v1' -or (Test-Path -LiteralPath $dryArtifact)) { throw 'Audio importer dry-run failed' }

    foreach ($cue in $cueNames) {
        $sourcePath = Join-Path $sourceRoot "$cue.wav"
        $debugArtifact = Join-Path $output "debug\$cue.audio.wav"
        $releaseArtifact = Join-Path $output "release\$cue.audio.wav"
        [void](Invoke-AudioTool @('-SourcePath', $sourcePath, '-DestinationPath', $debugArtifact, '-Profile', 'debug'))
        [void](Invoke-AudioTool @('-SourcePath', $sourcePath, '-DestinationPath', $releaseArtifact, '-Profile', 'release'))
        $debugHash = Assert-CanonicalArtifact $debugArtifact $sourcePath
        $releaseHash = Assert-CanonicalArtifact $releaseArtifact $sourcePath
        if ($debugHash -cne $releaseHash) { throw "Debug/release audio artifacts differ: $cue" }
        $generatedArtifact = Join-Path $generatedRoot "$cue.audio.wav"
        $generatedHash = Assert-CanonicalArtifact $generatedArtifact $sourcePath
        if ($generatedHash -cne $releaseHash) { throw "Generated package audio artifact does not match importer output: $cue" }
        if ($cue -ceq 'won') {
            [void](Invoke-AudioTool @('-SourcePath', $sourcePath, '-DestinationPath', $debugArtifact, '-DryRun') -ExpectFailure)
        }
    }

    # 构造带 JUNK metadata chunk 的合法输入，证明 baker 会规范化重写而不是直接复制源文件。
    $metadataSource = Join-Path $output 'metadata.wav'
    $metadataArtifact = Join-Path $output 'metadata\metadata.audio.wav'
    [byte[]]$canonicalBytes = [IO.File]::ReadAllBytes($wonSource)
    [byte[]]$metadataBytes = [byte[]]::new($canonicalBytes.Length + 10)
    [Buffer]::BlockCopy($canonicalBytes, 0, $metadataBytes, 0, 12)
    [Buffer]::BlockCopy([Text.Encoding]::ASCII.GetBytes('JUNK'), 0, $metadataBytes, 12, 4)
    [Buffer]::BlockCopy([BitConverter]::GetBytes([uint32]2), 0, $metadataBytes, 16, 4)
    $metadataBytes[20] = 0x4b
    $metadataBytes[21] = 0x44
    [Buffer]::BlockCopy($canonicalBytes, 12, $metadataBytes, 22, $canonicalBytes.Length - 12)
    [Buffer]::BlockCopy([BitConverter]::GetBytes([uint32]($metadataBytes.Length - 8)), 0, $metadataBytes, 4, 4)
    [IO.File]::WriteAllBytes($metadataSource, $metadataBytes)
    [void](Invoke-AudioTool @('-SourcePath', $metadataSource, '-DestinationPath', $metadataArtifact, '-Profile', 'release'))
    $metadataHash = Assert-CanonicalArtifact $metadataArtifact $metadataSource
    if ([IO.File]::ReadAllBytes($metadataArtifact).Length -ne $canonicalBytes.Length -or $metadataHash -cne (Get-Hash (Join-Path $output 'release\won.audio.wav'))) { throw 'Audio baker did not strip metadata into canonical bytes' }
    New-Item -ItemType Directory -Path (Split-Path -Parent $invalidSource) -Force | Out-Null
    [byte[]]$invalidBytes = [IO.File]::ReadAllBytes($wonSource)
    # 把 PCM format tag 改为 IEEE float，验证 importer 不会把不支持的编码冒充为 v1 artifact。
    $invalidBytes[20] = 3
    $invalidBytes[21] = 0
    [IO.File]::WriteAllBytes($invalidSource, $invalidBytes)
    [void](Invoke-AudioTool @('-SourcePath', $invalidSource, '-DestinationPath', $invalidArtifact, '-DryRun') -ExpectFailure)
    if (Test-Path -LiteralPath $invalidArtifact) { throw 'Invalid WAV created an artifact' }
    [void](Invoke-AudioTool @('-SourcePath', $wonSource, '-DestinationPath', $invalidPackageArtifact, '-DryRun') -ExpectFailure)
    if (Test-Path -LiteralPath $invalidPackageArtifact) { throw 'Package boundary violation created an artifact' }

    foreach ($cue in $cueNames) {
        if ($sourceHashes[$cue] -cne (Get-Hash (Join-Path $sourceRoot "$cue.wav"))) { throw "Source WAV changed during audio import verification: $cue" }
    }

    Write-Output 'audio_importer_version=1'
    Write-Output 'audio_baker_version=1'
    Write-Output 'artifact_format=CANONICAL-PCM-WAV-V1'
    Write-Output 'dry_run=ok'
    Write-Output 'debug_artifacts=ok'
    Write-Output 'release_artifacts=ok'
    Write-Output 'artifact_reproducibility=ok'
    Write-Output 'pcm_payload_preserved=ok'
    Write-Output 'metadata_chunk_stripped=ok'
    Write-Output 'overwrite_rejected=ok'
    Write-Output 'invalid_wav_rejected=ok'
    Write-Output 'package_boundary=ok'
    Write-Output 'generated_artifacts=ok'
    Write-Output 'sources_immutable=ok'
    Write-Output 'verification=ok'
} finally {
    if (Test-Path -LiteralPath $output) { Remove-Item -LiteralPath $output -Recurse -Force }
}
