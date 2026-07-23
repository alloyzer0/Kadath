[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,

    [Parameter(Mandatory = $true)]
    [string]$DestinationPath,

    [ValidateSet('debug', 'release')]
    [string]$Profile = 'debug',

    # DryRun 会完整解析并校验 WAV，但不会创建目录或 artifact。
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:AudioImporterVersion = 1
$script:AudioBakerVersion = 1
$script:AudioArtifactMaxBytes = 4 * 1024 * 1024

function Resolve-AudioSource([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Audio source does not exist: $Path" }
    $source = (Resolve-Path -LiteralPath $Path).Path
    $file = Get-Item -LiteralPath $source
    if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Audio source cannot be a reparse point' }
    if ([IO.Path]::GetExtension($source).ToLowerInvariant() -ne '.wav') { throw 'Audio importer expects a .wav source' }
    if ($file.Name.EndsWith('.audio.wav', [StringComparison]::OrdinalIgnoreCase)) { throw 'Audio importer does not accept a derived .audio.wav artifact as source' }
    if ($file.Length -gt $script:AudioArtifactMaxBytes) { throw "WAV exceeds size limit: $($file.Length) > $script:AudioArtifactMaxBytes" }
    return $source
}

function Resolve-AudioDestination([string]$Path) {
    $destination = [IO.Path]::GetFullPath($Path)
    if ([string]::IsNullOrWhiteSpace($destination) -or $destination -eq [IO.Path]::GetPathRoot($destination)) { throw "Invalid audio destination: $Path" }
    if (-not [IO.Path]::GetFileName($destination).EndsWith('.audio.wav', [StringComparison]::OrdinalIgnoreCase)) { throw 'Audio artifact destination must use the .audio.wav suffix' }
    # 关键不可变性边界：Importer 只能写隔离生成目录，不能直接修改已安装 package。
    if ($destination -match '(?i)[\\/]bin[\\/]assets([\\/]|$)') { throw 'Audio artifact destination must not be package/bin/assets' }
    if (Test-Path -LiteralPath $destination) { throw "Refusing to overwrite existing audio artifact: $destination" }
    $existingParent = Split-Path -Parent $destination
    while (-not (Test-Path -LiteralPath $existingParent -PathType Container)) {
        $nextParent = Split-Path -Parent $existingParent
        if ([string]::IsNullOrWhiteSpace($nextParent) -or $nextParent -eq $existingParent) { throw "Cannot resolve audio artifact parent: $destination" }
        $existingParent = $nextParent
    }
    $parentInfo = Get-Item -LiteralPath $existingParent
    if (($parentInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Audio artifact parent cannot be a reparse point' }
    return $destination
}

function Read-U16Le([byte[]]$Bytes, [int]$Offset) {
    return [uint16]([uint16]$Bytes[$Offset] -bor ([uint16]$Bytes[$Offset + 1] -shl 8))
}

function Read-U32Le([byte[]]$Bytes, [int]$Offset) {
    return [uint32]([uint32]$Bytes[$Offset] -bor ([uint32]$Bytes[$Offset + 1] -shl 8) -bor ([uint32]$Bytes[$Offset + 2] -shl 16) -bor ([uint32]$Bytes[$Offset + 3] -shl 24))
}

function Parse-PcmWav([string]$Path) {
    [byte[]]$bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 44) { throw 'WAV is shorter than the canonical PCM header' }
    if ([Text.Encoding]::ASCII.GetString($bytes, 0, 4) -cne 'RIFF' -or [Text.Encoding]::ASCII.GetString($bytes, 8, 4) -cne 'WAVE') { throw 'Audio source must use RIFF/WAVE format' }
    if ([long](Read-U32Le $bytes 4) + 8L -ne $bytes.Length) { throw 'RIFF size does not match file length' }

    $format = $null
    [byte[]]$samples = $null
    $offset = 12
    while ($offset -lt $bytes.Length) {
        if ($offset + 8 -gt $bytes.Length) { throw 'WAV contains a truncated chunk header' }
        $chunkId = [Text.Encoding]::ASCII.GetString($bytes, $offset, 4)
        [long]$chunkBytes = Read-U32Le $bytes ($offset + 4)
        [long]$payloadOffset = $offset + 8
        [long]$payloadEnd = $payloadOffset + $chunkBytes
        if ($payloadEnd -gt $bytes.Length) { throw "WAV chunk exceeds file length: $chunkId" }

        if ($chunkId -ceq 'fmt ') {
            if ($null -ne $format) { throw 'WAV contains duplicate fmt chunks' }
            if ($chunkBytes -lt 16) { throw 'WAV fmt chunk is too short' }
            $format = [pscustomobject]@{
                AudioFormat = Read-U16Le $bytes ([int]$payloadOffset)
                Channels = Read-U16Le $bytes ([int]$payloadOffset + 2)
                SampleRate = Read-U32Le $bytes ([int]$payloadOffset + 4)
                ByteRate = Read-U32Le $bytes ([int]$payloadOffset + 8)
                BlockAlign = Read-U16Le $bytes ([int]$payloadOffset + 12)
                BitsPerSample = Read-U16Le $bytes ([int]$payloadOffset + 14)
            }
        } elseif ($chunkId -ceq 'data') {
            if ($null -ne $samples) { throw 'WAV contains duplicate data chunks' }
            if ($chunkBytes -gt $script:AudioArtifactMaxBytes) { throw 'WAV sample payload exceeds artifact limit' }
            $samples = [byte[]]::new([int]$chunkBytes)
            if ($chunkBytes -gt 0) { [Buffer]::BlockCopy($bytes, [int]$payloadOffset, $samples, 0, [int]$chunkBytes) }
        }

        $offset = [int]($payloadEnd + ($chunkBytes % 2))
    }
    if ($offset -ne $bytes.Length) { throw 'WAV chunk padding exceeds file length' }
    if ($null -eq $format -or $null -eq $samples) { throw 'WAV requires one fmt chunk and one data chunk' }
    if ([int]$format.AudioFormat -ne 1) { throw 'Audio importer supports only uncompressed PCM WAV' }
    if ([int]$format.Channels -ne 1) { throw 'Audio importer v1 supports only mono WAV' }
    if ([int]$format.BitsPerSample -ne 16) { throw 'Audio importer v1 supports only 16-bit PCM WAV' }
    if ([long]$format.SampleRate -lt 8000 -or [long]$format.SampleRate -gt 48000) { throw 'Audio importer v1 sample rate must be in [8000, 48000] Hz' }
    [int]$expectedBlockAlign = [int]$format.Channels * ([int]$format.BitsPerSample / 8)
    [long]$expectedByteRate = [long]$format.SampleRate * $expectedBlockAlign
    if ([int]$format.BlockAlign -ne $expectedBlockAlign -or [long]$format.ByteRate -ne $expectedByteRate) { throw 'WAV byte rate/block align is inconsistent with PCM format' }
    if ($samples.Length -eq 0 -or ($samples.Length % $expectedBlockAlign) -ne 0) { throw 'WAV sample payload is empty or not frame-aligned' }

    return [pscustomobject]@{
        Channels = [int]$format.Channels
        SampleRate = [int]$format.SampleRate
        BitsPerSample = [int]$format.BitsPerSample
        BlockAlign = $expectedBlockAlign
        ByteRate = $expectedByteRate
        Samples = $samples
    }
}

function Write-CanonicalWavAtomic([object]$Audio, [string]$Path) {
    $temporary = "$Path.tmp.$PID"
    $stream = $null
    $writer = $null
    try {
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $writer = [IO.BinaryWriter]::new($stream)
        # 关键确定性：只写固定顺序的 RIFF/WAVE、fmt、data，不携带源文件附加 chunk 或时间信息。
        $writer.Write([Text.Encoding]::ASCII.GetBytes('RIFF'))
        $writer.Write([uint32](36 + $Audio.Samples.Length))
        $writer.Write([Text.Encoding]::ASCII.GetBytes('WAVE'))
        $writer.Write([Text.Encoding]::ASCII.GetBytes('fmt '))
        $writer.Write([uint32]16)
        $writer.Write([uint16]1)
        $writer.Write([uint16]$Audio.Channels)
        $writer.Write([uint32]$Audio.SampleRate)
        $writer.Write([uint32]$Audio.ByteRate)
        $writer.Write([uint16]$Audio.BlockAlign)
        $writer.Write([uint16]$Audio.BitsPerSample)
        $writer.Write([Text.Encoding]::ASCII.GetBytes('data'))
        $writer.Write([uint32]$Audio.Samples.Length)
        $writer.Write([byte[]]$Audio.Samples)
        $writer.Flush()
        $writer.Dispose(); $writer = $null
        $stream.Dispose(); $stream = $null
        Move-Item -LiteralPath $temporary -Destination $Path
    } finally {
        if ($null -ne $writer) { $writer.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

$source = Resolve-AudioSource $SourcePath
$audio = Parse-PcmWav $source
$destination = Resolve-AudioDestination $DestinationPath
$artifactBytes = 44 + $audio.Samples.Length
if ($DryRun) {
    $sourceName = [IO.Path]::GetFileNameWithoutExtension($source)
    $plan = [ordered]@{
        ImporterVersion = $script:AudioImporterVersion
        BakerVersion = $script:AudioBakerVersion
        ToolVersion = 'kadath-audio-importer/1'
        Action = 'audio-import-bake'
        Profile = $Profile
        DryRun = $true
        SourceFormat = 'RIFF-PCM-WAV'
        ArtifactFormat = 'CANONICAL-PCM-WAV-V1'
        Channels = $audio.Channels
        SampleRate = $audio.SampleRate
        BitsPerSample = $audio.BitsPerSample
        SampleBytes = $audio.Samples.Length
        Transform = 'pcm-wav-to-canonical-wav-v1'
        ArtifactBytes = $artifactBytes
        Destination = "generated-assets/audio/$sourceName.audio.wav"
    }
    Write-Output ($plan | ConvertTo-Json -Depth 8 -Compress)
    exit 0
}

try {
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Write-CanonicalWavAtomic $audio $destination
    $hash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Output "audio_importer_version=$($script:AudioImporterVersion)"
    Write-Output "audio_baker_version=$($script:AudioBakerVersion)"
    Write-Output 'tool_version=kadath-audio-importer/1'
    Write-Output "profile=$Profile"
    Write-Output 'source_format=RIFF-PCM-WAV'
    Write-Output 'artifact_format=CANONICAL-PCM-WAV-V1'
    Write-Output "channels=$($audio.Channels)"
    Write-Output "sample_rate=$($audio.SampleRate)"
    Write-Output "bits_per_sample=$($audio.BitsPerSample)"
    Write-Output "sample_bytes=$($audio.Samples.Length)"
    Write-Output 'transform=pcm-wav-to-canonical-wav-v1'
    Write-Output "artifact_bytes=$artifactBytes"
    Write-Output "sha256=$hash"
    Write-Output "artifact=$destination"
    Write-Output 'verification=ok'
} catch {
    if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Force }
    throw
}
