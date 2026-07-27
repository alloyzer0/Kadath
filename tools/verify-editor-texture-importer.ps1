[CmdletBinding()]
param(
    [string]$SourcePath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'assets\renderer2d\test.png'),
    [string]$GeneratedArtifact = (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'zig-out') 'bin\assets\renderer2d\test.texture'),
    [string]$OutputDirectory = (Join-Path $env:TEMP ("kadath-texture-importer-" + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')))
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not ('KadathPngFixturePrimitives' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Threading;

public static class KadathPngFixturePrimitives
{
    public static byte[] EncodeRows(byte[] pixels, int width, int height, int channels, int[] filters)
    {
        if (pixels == null || pixels.Length != checked(width * height * channels)) throw new ArgumentException("fixture pixel length mismatch");
        if (filters == null || filters.Length != height) throw new ArgumentException("fixture filter count mismatch");
        int stride = checked(width * channels);
        byte[] encoded = new byte[checked(height * (stride + 1))];
        for (int y = 0; y < height; y++)
        {
            int filter = filters[y];
            if (filter < 0 || filter > 4) throw new ArgumentOutOfRangeException(nameof(filters));
            int row = y * stride;
            int encodedRow = y * (stride + 1);
            encoded[encodedRow] = (byte)filter;
            for (int x = 0; x < stride; x++)
            {
                int value = pixels[row + x];
                int left = x >= channels ? pixels[row + x - channels] : 0;
                int up = y > 0 ? pixels[row - stride + x] : 0;
                int upperLeft = y > 0 && x >= channels ? pixels[row - stride + x - channels] : 0;
                int predictor = filter switch
                {
                    0 => 0,
                    1 => left,
                    2 => up,
                    3 => (left + up) / 2,
                    4 => Paeth(left, up, upperLeft),
                    _ => throw new InvalidOperationException()
                };
                encoded[encodedRow + 1 + x] = (byte)((value - predictor) & 0xff);
            }
        }
        return encoded;
    }

    public static byte[] CompressZlib(byte[] bytes)
    {
        return CompressZlib(bytes, CompressionLevel.Optimal);
    }

    public static byte[] CompressZlib(byte[] bytes, CompressionLevel level)
    {
        using MemoryStream output = new MemoryStream();
        using (ZLibStream compressor = new ZLibStream(output, level, true)) compressor.Write(bytes, 0, bytes.Length);
        return output.ToArray();
    }

    public static uint Crc32(byte[] type, byte[] data)
    {
        uint crc = 0xffffffffu;
        foreach (byte value in type) crc = Step(crc, value);
        foreach (byte value in data) crc = Step(crc, value);
        return crc ^ 0xffffffffu;
    }

    public static uint Adler32(byte[] data)
    {
        const uint Mod = 65521;
        uint a = 1, b = 0;
        foreach (byte value in data) { a = (a + value) % Mod; b = (b + a) % Mod; }
        return (b << 16) | a;
    }

    public static byte[] CreatePattern(int length)
    {
        // 固定 xorshift 序列只用于测试负载，保证 1M pixel fixture 可复现且近似不可压缩。
        byte[] result = new byte[length];
        uint state = 0x6d2b79f5u;
        for (int index = 0; index < result.Length; index++)
        {
            state ^= state << 13; state ^= state >> 17; state ^= state << 5;
            result[index] = (byte)state;
        }
        return result;
    }

    public static bool ObserveReadOnlySnapshot(string path, int processId, int timeoutMilliseconds)
    {
        // PowerShell 轮询不足以观察毫秒级 handle；在独立 C# 热循环中探测 writer sharing violation。
        using Process process = Process.GetProcessById(processId);
        Stopwatch stopwatch = Stopwatch.StartNew();
        while (!process.HasExited && stopwatch.ElapsedMilliseconds < timeoutMilliseconds)
        {
            try
            {
                using FileStream probe = File.Open(path, FileMode.Open, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
            }
            catch (IOException)
            {
                return true;
            }
            Thread.Yield();
        }
        return false;
    }

    private static int Paeth(int left, int up, int upperLeft)
    {
        int p = left + up - upperLeft;
        int pa = Math.Abs(p - left), pb = Math.Abs(p - up), pc = Math.Abs(p - upperLeft);
        return pa <= pb && pa <= pc ? left : pb <= pc ? up : upperLeft;
    }

    private static uint Step(uint crc, byte value)
    {
        crc ^= value;
        for (int bit = 0; bit < 8; bit++) crc = (crc & 1u) != 0 ? 0xedb88320u ^ (crc >> 1) : crc >> 1;
        return crc;
    }
}
'@
}

$tool = Join-Path $PSScriptRoot 'editor-texture-importer.ps1'
if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) { throw "Texture importer does not exist: $tool" }
$source = (Resolve-Path -LiteralPath $SourcePath).Path
$generated = (Resolve-Path -LiteralPath $GeneratedArtifact).Path
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $output) { throw "Output directory already exists: $output" }

function Invoke-TextureTool([string[]]$Arguments, [switch]$ExpectFailure) {
    $result = @(& pwsh -NoProfile -File $tool @Arguments 2>&1 | ForEach-Object { $_.ToString() })
    $exitCode = $LASTEXITCODE
    if (-not $ExpectFailure -and $exitCode -ne 0) { throw "Texture importer failed with code $exitCode`: $($result -join ' | ')" }
    if ($ExpectFailure -and $exitCode -eq 0) { throw 'Texture importer unexpectedly accepted invalid input' }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $result }
}

function Get-Hash([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

function Write-PngDispatchTracer([string]$Path) {
    # 独立 tracer 使用冻结的 1x1 RGBA PNG 字节，不复用生产 decoder，避免测试按实现方式重算期望值。
    $png = [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mMQVDJ2AQABWQCrzHQ3uwAAAABJRU5ErkJggg==')
    [IO.File]::WriteAllBytes($Path, $png)
}

function Start-TextureToolProcess([string[]]$Arguments) {
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = (Get-Command pwsh -ErrorAction Stop).Source
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    [void]$startInfo.ArgumentList.Add('-NoProfile')
    [void]$startInfo.ArgumentList.Add('-File')
    [void]$startInfo.ArgumentList.Add($tool)
    foreach ($argument in $Arguments) { [void]$startInfo.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw 'Failed to start texture importer child process' }
    return $process
}

function Complete-TextureToolProcess([Diagnostics.Process]$Process, [int]$TimeoutMilliseconds = 30000) {
    if (-not $Process.WaitForExit($TimeoutMilliseconds)) {
        $Process.Kill($true)
        $Process.WaitForExit()
        throw "Texture importer child timed out: pid=$($Process.Id)"
    }
    $stdout = $Process.StandardOutput.ReadToEnd()
    $stderr = $Process.StandardError.ReadToEnd()
    return [pscustomobject]@{ ExitCode = $Process.ExitCode; Stdout = $stdout; Stderr = $stderr; ProcessId = $Process.Id }
}

function Assert-PerformanceTimeoutCleanup([string]$DestinationPath) {
    if (Test-Path -LiteralPath $DestinationPath) { throw "Timed-out worst-case import left a destination artifact: $DestinationPath" }
    $destinationParent = Split-Path -Parent $DestinationPath
    if (Test-Path -LiteralPath $destinationParent) {
        $leftovers = @(Get-ChildItem -LiteralPath $destinationParent -Force -File)
        if ($leftovers.Count -ne 0) { throw "Timed-out worst-case import left owned temporary files: $($leftovers.Name -join ', ')" }
    }
}

function Complete-TextureToolPerformance([Diagnostics.Process]$Process, [string]$DestinationPath, [int]$TimeoutMilliseconds = 60000) {
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    [long]$peakWorkingSet = 0
    while (-not $Process.HasExited -and $stopwatch.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
        $Process.Refresh()
        $peakWorkingSet = [math]::Max($peakWorkingSet, $Process.WorkingSet64)
        Start-Sleep -Milliseconds 50
    }
    if (-not $Process.HasExited) {
        $Process.Kill($true)
        $Process.WaitForExit()
        Assert-PerformanceTimeoutCleanup $DestinationPath
        throw "Worst-case PNG import exceeded $TimeoutMilliseconds ms: pid=$($Process.Id)"
    }
    $Process.WaitForExit()
    $Process.Refresh()
    $peakWorkingSet = [math]::Max($peakWorkingSet, $Process.PeakWorkingSet64)
    return [pscustomobject]@{
        ExitCode = $Process.ExitCode
        Stdout = $Process.StandardOutput.ReadToEnd()
        Stderr = $Process.StandardError.ReadToEnd()
        ProcessId = $Process.Id
        ElapsedMilliseconds = $stopwatch.ElapsedMilliseconds
        PeakWorkingSet64 = $peakWorkingSet
    }
}

function Start-PngSnapshotMutator([string]$Source, [string]$TemplateA, [string]$TemplateB, [string]$StopSignal) {
    $mutatorScript = @'
$ErrorActionPreference = 'Stop'
$Source = $env:KADATH_PNG_MUTATOR_SOURCE
$TemplateA = $env:KADATH_PNG_MUTATOR_TEMPLATE_A
$TemplateB = $env:KADATH_PNG_MUTATOR_TEMPLATE_B
$StopSignal = $env:KADATH_PNG_MUTATOR_STOP
$replaceAttempts = 0; $replaceSuccesses = 0
$growAttempts = 0; $growSuccesses = 0
$shrinkAttempts = 0; $shrinkSuccesses = 0
$sharingDenied = 0; $iteration = 0
while (-not [IO.File]::Exists($StopSignal)) {
    $template = if (($iteration % 2) -eq 0) { $TemplateA } else { $TemplateB }
    $next = "$Source.mutator-next"
    try {
        [IO.File]::Copy($template, $next, $true)
        $replaceAttempts++
        [IO.File]::Move($next, $Source, $true)
        $replaceSuccesses++
    } catch {
        # Windows 可把 sharing violation 包进 MethodInvocationException；只吞掉最内层的预期 I/O/拒绝访问竞态。
        $cause = $_.Exception
        while ($null -ne $cause.InnerException) { $cause = $cause.InnerException }
        if ($cause -is [IO.IOException] -or $cause -is [UnauthorizedAccessException]) { $sharingDenied++ } else { throw }
    }
    try {
        $growAttempts++
        $stream = [IO.File]::Open($Source, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        try { $stream.SetLength($stream.Length + 1) } finally { $stream.Dispose() }
        $growSuccesses++
    } catch {
        $cause = $_.Exception
        while ($null -ne $cause.InnerException) { $cause = $cause.InnerException }
        if ($cause -is [IO.IOException] -or $cause -is [UnauthorizedAccessException]) { $sharingDenied++ } else { throw }
    }
    try {
        $shrinkAttempts++
        $stream = [IO.File]::Open($Source, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        try { if ($stream.Length -gt 1) { $stream.SetLength($stream.Length - 1) } } finally { $stream.Dispose() }
        $shrinkSuccesses++
    } catch {
        $cause = $_.Exception
        while ($null -ne $cause.InnerException) { $cause = $cause.InnerException }
        if ($cause -is [IO.IOException] -or $cause -is [UnauthorizedAccessException]) { $sharingDenied++ } else { throw }
    }
    $iteration++
    Start-Sleep -Milliseconds 1
}

# 停止后恢复一份完整合法 source；import 子进程此时均已结束，因此不会与产品 handle 竞争。
$restore = "$Source.mutator-restore"
[IO.File]::Copy($TemplateA, $restore, $true)
$restored = $false
for ($attempt = 0; $attempt -lt 100 -and -not $restored; $attempt++) {
    try {
        [IO.File]::Move($restore, $Source, $true)
        $restored = $true
    } catch {
        $cause = $_.Exception
        while ($null -ne $cause.InnerException) { $cause = $cause.InnerException }
        if ($cause -isnot [IO.IOException] -and $cause -isnot [UnauthorizedAccessException]) { throw }
        Start-Sleep -Milliseconds 5
    }
}
if (-not $restored) { throw 'Could not restore the complete PNG source after bounded sharing-violation retries' }
[pscustomobject]@{
    replaceAttempts = $replaceAttempts
    replaceSuccesses = $replaceSuccesses
    growAttempts = $growAttempts
    growSuccesses = $growSuccesses
    shrinkAttempts = $shrinkAttempts
    shrinkSuccesses = $shrinkSuccesses
    sharingDenied = $sharingDenied
} | ConvertTo-Json -Compress
'@
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = (Get-Command pwsh -ErrorAction Stop).Source
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @('-NoProfile', '-Command', $mutatorScript)) { [void]$startInfo.ArgumentList.Add($argument) }
    $startInfo.Environment['KADATH_PNG_MUTATOR_SOURCE'] = $Source
    $startInfo.Environment['KADATH_PNG_MUTATOR_TEMPLATE_A'] = $TemplateA
    $startInfo.Environment['KADATH_PNG_MUTATOR_TEMPLATE_B'] = $TemplateB
    $startInfo.Environment['KADATH_PNG_MUTATOR_STOP'] = $StopSignal
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw 'Failed to start PNG source snapshot mutator' }
    return $process
}

function ConvertTo-BigEndianUInt32Bytes([uint32]$Value) {
    return [byte[]](@(
        [byte](($Value -shr 24) -band 0xff),
        [byte](($Value -shr 16) -band 0xff),
        [byte](($Value -shr 8) -band 0xff),
        [byte]($Value -band 0xff)
    ))
}

function Join-ByteArrays([object[]]$Arrays) {
    $stream = [IO.MemoryStream]::new()
    try {
        foreach ($array in $Arrays) {
            [byte[]]$bytes = $array
            $stream.Write($bytes, 0, $bytes.Length)
        }
        return $stream.ToArray()
    } finally {
        $stream.Dispose()
    }
}

function New-PngChunk([string]$Type, [byte[]]$Data, [switch]$CorruptCrc) {
    [byte[]]$typeBytes = [Text.Encoding]::ASCII.GetBytes($Type)
    if ($typeBytes.Length -ne 4) { throw "Fixture chunk type must contain four bytes: $Type" }
    $crc = [KadathPngFixturePrimitives]::Crc32($typeBytes, $Data)
    if ($CorruptCrc) { $crc = $crc -bxor 1 }
    return Join-ByteArrays @((ConvertTo-BigEndianUInt32Bytes $Data.Length), $typeBytes, $Data, (ConvertTo-BigEndianUInt32Bytes $crc))
}

function New-PngFixtureBytes {
    param(
        [int]$Width,
        [int]$Height,
        [byte[]]$Pixels,
        [int]$ColorType = 6,
        [int]$BitDepth = 8,
        [int]$Interlace = 0,
        [int[]]$Filters,
        [int]$IdatParts = 1,
        [object[]]$BeforeIdat = @(),
        [object[]]$AfterIdat = @(),
        [byte[]]$OverrideZlib,
        [switch]$OmitIdat,
        [switch]$OmitIend
    )
    $channels = if ($ColorType -eq 2) { 3 } else { 4 }
    if ($null -eq $Filters -or $Filters.Count -eq 0) { $Filters = @(0) * $Height }
    [byte[]]$zlib = if ($PSBoundParameters.ContainsKey('OverrideZlib')) {
        $OverrideZlib
    } else {
        $rows = [KadathPngFixturePrimitives]::EncodeRows($Pixels, $Width, $Height, $channels, $Filters)
        [KadathPngFixturePrimitives]::CompressZlib($rows)
    }
    [byte[]]$ihdr = Join-ByteArrays @(
        (ConvertTo-BigEndianUInt32Bytes $Width),
        (ConvertTo-BigEndianUInt32Bytes $Height),
        [byte[]]($BitDepth, $ColorType, 0, 0, $Interlace)
    )
    $parts = [Collections.Generic.List[byte[]]]::new()
    $parts.Add([byte[]](0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a))
    $parts.Add((New-PngChunk 'IHDR' $ihdr))
    foreach ($chunk in $BeforeIdat) {
        $corrupt = $null -ne $chunk.PSObject.Properties['CorruptCrc'] -and [bool]$chunk.CorruptCrc
        $parts.Add((New-PngChunk ([string]$chunk.Type) ([byte[]]$chunk.Data) -CorruptCrc:$corrupt))
    }
    if (-not $OmitIdat) {
        if ($IdatParts -lt 1) { throw 'IDAT fixture part count must be positive' }
        for ($part = 0; $part -lt $IdatParts; $part++) {
            $start = [int][math]::Floor(($zlib.Length * $part) / $IdatParts)
            $end = [int][math]::Floor(($zlib.Length * ($part + 1)) / $IdatParts)
            $length = $end - $start
            [byte[]]$slice = [byte[]]::new($length)
            if ($length -gt 0) { [Array]::Copy($zlib, $start, $slice, 0, $length) }
            $parts.Add((New-PngChunk 'IDAT' $slice))
        }
    }
    foreach ($chunk in $AfterIdat) {
        $corrupt = $null -ne $chunk.PSObject.Properties['CorruptCrc'] -and [bool]$chunk.CorruptCrc
        $parts.Add((New-PngChunk ([string]$chunk.Type) ([byte[]]$chunk.Data) -CorruptCrc:$corrupt))
    }
    if (-not $OmitIend) { $parts.Add((New-PngChunk 'IEND' ([byte[]]::new(0)))) }
    return Join-ByteArrays $parts.ToArray()
}

function Write-PngFixture([string]$Path, [hashtable]$Spec) {
    [byte[]]$bytes = New-PngFixtureBytes @Spec
    [IO.File]::WriteAllBytes($Path, $bytes)
}

function Assert-V1Pixels([string]$Path, [int]$Width, [int]$Height, [byte[]]$ExpectedPixels) {
    [byte[]]$bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ne (20 + $ExpectedPixels.Length) -or [Text.Encoding]::ASCII.GetString($bytes, 0, 4) -cne 'KDAT') { throw "Unexpected KDAT v1 fixture size/header: $Path" }
    if ([BitConverter]::ToUInt32($bytes, 4) -ne 1 -or [BitConverter]::ToUInt32($bytes, 8) -ne $Width -or [BitConverter]::ToUInt32($bytes, 12) -ne $Height -or [BitConverter]::ToUInt32($bytes, 16) -ne $ExpectedPixels.Length) { throw "Unexpected KDAT v1 fixture metadata: $Path" }
    for ($index = 0; $index -lt $ExpectedPixels.Length; $index++) {
        if ($bytes[20 + $index] -ne $ExpectedPixels[$index]) { throw "KDAT v1 fixture pixel mismatch at byte $index`: $Path" }
    }
    return Get-Hash $Path
}

function Assert-PngRejected([string]$Name, [byte[]]$Bytes, [string]$ExpectedPattern = '') {
    $sourcePath = Join-Path $fixtureRoot ("invalid-{0}.png" -f $Name)
    $destinationPath = Join-Path $output ("invalid-artifacts\{0}\test.texture" -f $Name)
    [IO.File]::WriteAllBytes($sourcePath, $Bytes)
    $sourceHash = Get-Hash $sourcePath
    $result = Invoke-TextureTool @('-SourcePath', $sourcePath, '-DestinationPath', $destinationPath, '-Profile', 'debug') -ExpectFailure
    if (-not [string]::IsNullOrEmpty($ExpectedPattern) -and ($result.Output -join "`n") -notmatch $ExpectedPattern) { throw "Rejected PNG '$Name' did not report category '$ExpectedPattern': $($result.Output -join ' | ')" }
    if (Test-Path -LiteralPath $destinationPath) { throw "Rejected PNG '$Name' created an artifact" }
    if ((Get-Hash $sourcePath) -cne $sourceHash) { throw "Rejected PNG '$Name' changed its source bytes" }
    $destinationParent = Split-Path -Parent $destinationPath
    if (Test-Path -LiteralPath $destinationParent) {
        $leftovers = @(Get-ChildItem -LiteralPath $destinationParent -Force)
        if ($leftovers.Count -ne 0) { throw "Rejected PNG '$Name' left temporary content: $($leftovers.Name -join ', ')" }
    }
}

function Assert-V1Artifact([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Texture artifact missing: $Path" }
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ne 36 -or [Text.Encoding]::ASCII.GetString($bytes[0..3]) -cne 'KDAT') { throw 'Unexpected KDAT v1 artifact header/size' }
    if ([BitConverter]::ToUInt32($bytes, 4) -ne 1 -or [BitConverter]::ToUInt32($bytes, 8) -ne 2 -or [BitConverter]::ToUInt32($bytes, 12) -ne 2 -or [BitConverter]::ToUInt32($bytes, 16) -ne 16) { throw 'Unexpected KDAT v1 dimensions/payload size' }
    $expectedPixels = [byte[]](255,40,40,255,40,255,40,255,40,40,255,255,255,230,40,255)
    for ($index = 0; $index -lt $expectedPixels.Length; $index++) { if ($bytes[20 + $index] -ne $expectedPixels[$index]) { throw "Unexpected v1 RGBA8 pixel at index $index" } }
    return Get-Hash $Path
}

function Assert-V2MipmapArtifact([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Texture artifact missing: $Path" }
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ne 44 -or [Text.Encoding]::ASCII.GetString($bytes[0..3]) -cne 'KDAT') { throw 'Unexpected KDAT v2 artifact header/size' }
    if ([BitConverter]::ToUInt32($bytes, 4) -ne 2 -or [BitConverter]::ToUInt32($bytes, 8) -ne 2 -or [BitConverter]::ToUInt32($bytes, 12) -ne 2 -or [BitConverter]::ToUInt32($bytes, 16) -ne 2 -or [BitConverter]::ToUInt32($bytes, 20) -ne 20) { throw 'Unexpected KDAT v2 dimensions/mip/payload size' }
    $expectedBase = [byte[]](255,40,40,255,40,255,40,255,40,40,255,255,255,230,40,255)
    for ($index = 0; $index -lt $expectedBase.Length; $index++) { if ($bytes[24 + $index] -ne $expectedBase[$index]) { throw "Unexpected v2 base RGBA8 pixel at index $index" } }
    $expectedMip = [byte[]](147,141,93,255)
    for ($index = 0; $index -lt $expectedMip.Length; $index++) { if ($bytes[40 + $index] -ne $expectedMip[$index]) { throw "Unexpected v2 mip pixel at index $index" } }
    return Get-Hash $Path
}

function Assert-CheckedPngV1Artifact([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Checked PNG KDAT v1 artifact missing: $Path" }
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ne 36 -or [Text.Encoding]::ASCII.GetString($bytes[0..3]) -cne 'KDAT') { throw 'Checked PNG produced an unexpected KDAT v1 header/size' }
    if ([BitConverter]::ToUInt32($bytes, 4) -ne 1 -or [BitConverter]::ToUInt32($bytes, 8) -ne 2 -or [BitConverter]::ToUInt32($bytes, 12) -ne 2 -or [BitConverter]::ToUInt32($bytes, 16) -ne 16) { throw 'Checked PNG produced unexpected KDAT v1 dimensions/payload size' }
    # 关键独立期望：透明像素的非零 RGB、两档半透明 alpha 与 opaque 像素都必须原样保留。
    $expectedPixels = [byte[]](255,0,0,0, 0,255,0,64, 0,0,255,128, 255,255,255,255)
    for ($index = 0; $index -lt $expectedPixels.Length; $index++) {
        if ($bytes[20 + $index] -ne $expectedPixels[$index]) { throw "Checked PNG KDAT v1 pixel mismatch at byte $index" }
    }
    return Get-Hash $Path
}

function Assert-CheckedPngV2Artifact([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Checked PNG KDAT v2 artifact missing: $Path" }
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ne 44 -or [Text.Encoding]::ASCII.GetString($bytes[0..3]) -cne 'KDAT') { throw 'Checked PNG produced an unexpected KDAT v2 header/size' }
    if ([BitConverter]::ToUInt32($bytes, 4) -ne 2 -or [BitConverter]::ToUInt32($bytes, 8) -ne 2 -or [BitConverter]::ToUInt32($bytes, 12) -ne 2 -or [BitConverter]::ToUInt32($bytes, 16) -ne 2 -or [BitConverter]::ToUInt32($bytes, 20) -ne 20) { throw 'Checked PNG produced unexpected KDAT v2 dimensions/mip payload' }
    $expectedBase = [byte[]](255,0,0,0, 0,255,0,64, 0,0,255,128, 255,255,255,255)
    for ($index = 0; $index -lt $expectedBase.Length; $index++) {
        if ($bytes[24 + $index] -ne $expectedBase[$index]) { throw "Checked PNG KDAT v2 base pixel mismatch at byte $index" }
    }
    $expectedMip = [byte[]](127,127,127,111)
    for ($index = 0; $index -lt $expectedMip.Length; $index++) {
        if ($bytes[40 + $index] -ne $expectedMip[$index]) { throw "Checked PNG KDAT v2 mip mismatch at byte $index" }
    }
    return Get-Hash $Path
}

$debugArtifact = Join-Path $output 'debug\test.texture'
$releaseArtifact = Join-Path $output 'release\test.texture'
$ppmSource = Join-Path $output 'compatibility.ppm'
$invalidSource = Join-Path $output 'invalid.ppm'
$invalidArtifact = Join-Path $output 'invalid\test.texture'
$invalidPackageArtifact = Join-Path (Split-Path -Parent $output) 'bin\assets\invalid.texture'
$pngTracerSource = Join-Path $output 'tracer.png'
$pngTracerArtifact = Join-Path $output 'tracer\test.texture'
$checkedPngSource = $source
$checkedPngDebug = Join-Path $output 'png-debug\test.texture'
$checkedPngRelease = Join-Path $output 'png-release\test.texture'
$raceRoot = Join-Path $output 'destination-races'
$fixtureRoot = Join-Path $output 'generated-fixtures'
$opaquePngSource = Join-Path $fixtureRoot 'ppm-equivalent-opaque.png'
$opaquePngDebug = Join-Path $output 'opaque-png-debug\test.texture'
$opaquePngRelease = Join-Path $output 'opaque-png-release\test.texture'
$pathSafetyRoot = Join-Path $output 'path-safety'
$performanceProcess = $null
$mutatorProcess = $null
try {
    New-Item -ItemType Directory -Path $output | Out-Null
    # checked-in PPM 已由 PNG 取代；动态 fixture 保留旧 Adapter 的兼容与 byte-identical KDAT 回归。
    [IO.File]::WriteAllText($ppmSource, "P3`n2 2`n255`n255 40 40`n40 255 40`n40 40 255`n255 230 40`n", [Text.UTF8Encoding]::new($false))
    $ppmSourceHashBefore = Get-Hash $ppmSource
    $checkedPngHashBefore = Get-Hash $checkedPngSource
    Write-PngDispatchTracer $pngTracerSource
    $pngTracer = Invoke-TextureTool @('-SourcePath', $pngTracerSource, '-DestinationPath', $pngTracerArtifact, '-Profile', 'debug', '-DryRun')
    $pngTracerPlan = $pngTracer.Output[-1] | ConvertFrom-Json
    if ([string]$pngTracerPlan.SourceFormat -cne 'PNG-RGBA8' -or [string]$pngTracerPlan.Transform -cne 'png-to-rgba8-artifact-v1' -or (Test-Path $pngTracerArtifact)) { throw 'PNG dispatch tracer failed' }

    if ((Get-Hash $checkedPngSource) -cne 'a6fab23c053638849d8b64ba72e260c22efb6e60a6876e36c662ae43a42e1eff') { throw 'Checked PNG source bytes changed' }
    $pngDryRelease = Invoke-TextureTool @('-SourcePath', $checkedPngSource, '-DestinationPath', $checkedPngRelease, '-Profile', 'release', '-DryRun')
    $pngPlan = $pngDryRelease.Output[-1] | ConvertFrom-Json
    if ([string]$pngPlan.SourceFormat -cne 'PNG-RGBA8' -or [string]$pngPlan.Transform -cne 'png-to-rgba8-mipmap-artifact-v2' -or [int]$pngPlan.Width -ne 2 -or [int]$pngPlan.Height -ne 2 -or [int]$pngPlan.MipLevelCount -ne 2 -or [int]$pngPlan.ArtifactBytes -ne 44 -or (Test-Path $checkedPngRelease)) { throw 'Checked PNG release dry-run plan is invalid' }
    [void](Invoke-TextureTool @('-SourcePath', $checkedPngSource, '-DestinationPath', $checkedPngDebug, '-Profile', 'debug'))
    [void](Invoke-TextureTool @('-SourcePath', $checkedPngSource, '-DestinationPath', $checkedPngRelease, '-Profile', 'release'))
    [void](Assert-CheckedPngV1Artifact $checkedPngDebug)
    $checkedPngReleaseHash = Assert-CheckedPngV2Artifact $checkedPngRelease

    # 路径边界通过公开 CLI 验证：device alias、UNC 与任一祖先 reparse point 都不能绕过 source/destination 约束。
    New-Item -ItemType Directory -Path $pathSafetyRoot | Out-Null
    $deviceSource = '\\?\' + $checkedPngSource
    $deviceSourceDestination = Join-Path $pathSafetyRoot 'device-source\test.texture'
    [void](Invoke-TextureTool @('-SourcePath', $deviceSource, '-DestinationPath', $deviceSourceDestination, '-Profile', 'debug') -ExpectFailure)
    if (Test-Path -LiteralPath $deviceSourceDestination) { throw 'Device-alias source created a texture artifact' }

    $deviceDestination = '\\?\' + (Join-Path $pathSafetyRoot 'device-destination\test.texture')
    [void](Invoke-TextureTool @('-SourcePath', $checkedPngSource, '-DestinationPath', $deviceDestination, '-Profile', 'debug') -ExpectFailure)
    if (Test-Path -LiteralPath (Join-Path $pathSafetyRoot 'device-destination\test.texture')) { throw 'Device-alias destination created a texture artifact' }

    $uncDestination = '\\invalid-kadath-host\texture-share\test.texture'
    [void](Invoke-TextureTool @('-SourcePath', $checkedPngSource, '-DestinationPath', $uncDestination, '-Profile', 'debug') -ExpectFailure)

    # target 刻意位于伪 package/bin/assets；alias 自身不含该字样，验证不能靠字符串 regex 绕过禁写边界。
    $reparseTarget = Join-Path $pathSafetyRoot 'foreign-package\bin\assets'
    $reparseAlias = Join-Path $pathSafetyRoot 'reparse-alias'
    $reparseTargetSourceDirectory = Join-Path $reparseTarget 'source'
    $reparseTargetDestinationDirectory = Join-Path $reparseTarget 'destination'
    New-Item -ItemType Directory -Path $reparseTargetSourceDirectory,$reparseTargetDestinationDirectory | Out-Null
    Copy-Item -LiteralPath $checkedPngSource -Destination (Join-Path $reparseTargetSourceDirectory 'test.png')
    $foreignSentinel = Join-Path $reparseTargetDestinationDirectory 'foreign.txt'
    [IO.File]::WriteAllText($foreignSentinel, 'foreign-destination-must-survive', [Text.UTF8Encoding]::new($false))
    $foreignSentinelHash = Get-Hash $foreignSentinel
    New-Item -ItemType Junction -Path $reparseAlias -Target $reparseTarget | Out-Null

    $reparseSourceDestination = Join-Path $pathSafetyRoot 'reparse-source-output\test.texture'
    [void](Invoke-TextureTool @('-SourcePath', (Join-Path $reparseAlias 'source\test.png'), '-DestinationPath', $reparseSourceDestination, '-Profile', 'debug') -ExpectFailure)
    if (Test-Path -LiteralPath $reparseSourceDestination) { throw 'Reparse-ancestor source created a texture artifact' }

    $reparseDestination = Join-Path $reparseAlias 'destination\derived\test.texture'
    [void](Invoke-TextureTool @('-SourcePath', $checkedPngSource, '-DestinationPath', $reparseDestination, '-Profile', 'debug') -ExpectFailure)
    if (Test-Path -LiteralPath (Join-Path $reparseTargetDestinationDirectory 'derived\test.texture')) { throw 'Reparse-ancestor destination wrote through its alias' }
    if ((Get-Hash $foreignSentinel) -cne $foreignSentinelHash) { throw 'Rejected reparse destination changed foreign content' }
    $pathSafetyTemps = @(Get-ChildItem -LiteralPath $pathSafetyRoot -Recurse -Force -File | Where-Object { $_.Name -like '.kadath-texture-*.tmp' })
    if ($pathSafetyTemps.Count -ne 0) { throw "Rejected path-safety cases left owned temp files: $($pathSafetyTemps.FullName -join ', ')" }

    New-Item -ItemType Directory -Path $raceRoot | Out-Null
    for ($round = 0; $round -lt 8; $round++) {
        $raceDestination = Join-Path $raceRoot ("round-{0}\test.texture" -f $round)
        $raceArguments = @('-SourcePath', $checkedPngSource, '-DestinationPath', $raceDestination, '-Profile', 'debug')
        # 两个独立进程竞争同一目标；恰好一个可以提交，失败方绝不能删除成功方 artifact。
        $raceA = Start-TextureToolProcess $raceArguments
        $raceB = Start-TextureToolProcess $raceArguments
        $raceResultA = Complete-TextureToolProcess $raceA
        $raceResultB = Complete-TextureToolProcess $raceB
        $successCount = @(@($raceResultA, $raceResultB) | Where-Object { $_.ExitCode -eq 0 }).Count
        if ($successCount -ne 1) { throw "Destination race round $round expected one winner: A=$($raceResultA.ExitCode) B=$($raceResultB.ExitCode)" }
        [void](Assert-CheckedPngV1Artifact $raceDestination)
        $ownedTemps = @(Get-ChildItem -LiteralPath (Split-Path -Parent $raceDestination) -Force -File | Where-Object { $_.Name -ne 'test.texture' })
        if ($ownedTemps.Count -ne 0) { throw "Destination race round $round left temporary files: $($ownedTemps.Name -join ', ')" }
    }

    New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
    $opaquePngPixels = [byte[]](255,40,40,255, 40,255,40,255, 40,40,255,255, 255,230,40,255)
    Write-PngFixture $opaquePngSource @{ Width = 2; Height = 2; Pixels = $opaquePngPixels; Filters = @(0,0) }
    $filterPixels = [byte[]](
        10,20,30,40, 50,60,70,80, 90,100,110,120,
        130,140,150,160, 170,180,190,200, 210,220,230,240
    )
    $referenceFilterHash = $null
    for ($filter = 0; $filter -le 4; $filter++) {
        $filterSource = Join-Path $fixtureRoot ("filter-{0}.png" -f $filter)
        $filterArtifact = Join-Path $output ("filter-artifacts\filter-{0}.texture" -f $filter)
        Write-PngFixture $filterSource @{ Width = 3; Height = 2; Pixels = $filterPixels; Filters = @($filter, $filter) }
        [void](Invoke-TextureTool @('-SourcePath', $filterSource, '-DestinationPath', $filterArtifact, '-Profile', 'debug'))
        $filterHash = Assert-V1Pixels $filterArtifact 3 2 $filterPixels
        if ($null -eq $referenceFilterHash) { $referenceFilterHash = $filterHash }
        elseif ($filterHash -cne $referenceFilterHash) { throw "PNG filter $filter changed decoded KDAT bytes" }
    }

    $splitIdatSource = Join-Path $fixtureRoot 'split-idat.PNG'
    $splitIdatArtifact = Join-Path $output 'filter-artifacts\split-idat.texture'
    Write-PngFixture $splitIdatSource @{ Width = 3; Height = 2; Pixels = $filterPixels; Filters = @(4, 4); IdatParts = 3 }
    [void](Invoke-TextureTool @('-SourcePath', $splitIdatSource, '-DestinationPath', $splitIdatArtifact, '-Profile', 'debug'))
    if ((Assert-V1Pixels $splitIdatArtifact 3 2 $filterPixels) -cne $referenceFilterHash) { throw 'Consecutive split IDAT changed decoded KDAT bytes' }

    # 同一 filtered rows 由 stored/optimal 两种独立 deflate 编码承载，decoder 输出必须收敛为同一 KDAT。
    [byte[]]$deflateRows = [KadathPngFixturePrimitives]::EncodeRows($filterPixels, 3, 2, 4, [int[]](4,4))
    [byte[]]$storedZlib = [KadathPngFixturePrimitives]::CompressZlib($deflateRows, [IO.Compression.CompressionLevel]::NoCompression)
    [byte[]]$optimalZlib = [KadathPngFixturePrimitives]::CompressZlib($deflateRows, [IO.Compression.CompressionLevel]::Optimal)
    if ([Convert]::ToBase64String($storedZlib) -ceq [Convert]::ToBase64String($optimalZlib)) { throw 'Independent stored/optimal deflate fixtures unexpectedly have identical source bytes' }
    $storedSource = Join-Path $fixtureRoot 'deflate-stored.png'
    $optimalSource = Join-Path $fixtureRoot 'deflate-optimal.png'
    $storedArtifact = Join-Path $output 'deflate-artifacts\stored.texture'
    $optimalArtifact = Join-Path $output 'deflate-artifacts\optimal.texture'
    [IO.File]::WriteAllBytes($storedSource, (New-PngFixtureBytes -Width 3 -Height 2 -Pixels $filterPixels -Filters @(4,4) -OverrideZlib $storedZlib))
    [IO.File]::WriteAllBytes($optimalSource, (New-PngFixtureBytes -Width 3 -Height 2 -Pixels $filterPixels -Filters @(4,4) -OverrideZlib $optimalZlib))
    [void](Invoke-TextureTool @('-SourcePath', $storedSource, '-DestinationPath', $storedArtifact, '-Profile', 'debug'))
    [void](Invoke-TextureTool @('-SourcePath', $optimalSource, '-DestinationPath', $optimalArtifact, '-Profile', 'debug'))
    $storedArtifactHash = Assert-V1Pixels $storedArtifact 3 2 $filterPixels
    $optimalArtifactHash = Assert-V1Pixels $optimalArtifact 3 2 $filterPixels
    if ($storedArtifactHash -cne $optimalArtifactHash) { throw 'Stored/optimal deflate encodings produced different KDAT bytes for identical pixels' }

    $rgbPixels = [byte[]](1,2,3, 254,253,252)
    $rgbExpected = [byte[]](1,2,3,255, 254,253,252,255)
    $rgbSource = Join-Path $fixtureRoot 'rgb.png'
    $rgbArtifact = Join-Path $output 'rgb-artifact\test.texture'
    Write-PngFixture $rgbSource @{ Width = 2; Height = 1; Pixels = $rgbPixels; ColorType = 2; Filters = @(4) }
    [void](Invoke-TextureTool @('-SourcePath', $rgbSource, '-DestinationPath', $rgbArtifact, '-Profile', 'debug'))
    [void](Assert-V1Pixels $rgbArtifact 2 1 $rgbExpected)

    $metadataBefore = @(
        [pscustomobject]@{ Type = 'cHRM'; Data = [byte[]]::new(32) },
        [pscustomobject]@{ Type = 'gAMA'; Data = [byte[]](0,0,177,143) },
        [pscustomobject]@{ Type = 'sRGB'; Data = [byte[]](0) },
        [pscustomobject]@{ Type = 'pHYs'; Data = [byte[]](0,0,0,1,0,0,0,1,0) },
        [pscustomobject]@{ Type = 'eXIf'; Data = [byte[]](0x49,0x49,0x2a,0) },
        [pscustomobject]@{ Type = 'vpAg'; Data = [byte[]](9,8,7,6) }
    )
    $metadataAfter = @(
        [pscustomobject]@{ Type = 'tEXt'; Data = [Text.Encoding]::ASCII.GetBytes("key`0value") },
        [pscustomobject]@{ Type = 'tIME'; Data = [byte[]](0x07,0xea,7,26,12,0,0) },
        [pscustomobject]@{ Type = 'vpAg'; Data = [byte[]](1,2,3) }
    )
    $metadataSource = Join-Path $fixtureRoot 'metadata.png'
    $metadataArtifact = Join-Path $output 'metadata-artifacts\metadata.texture'
    Write-PngFixture $metadataSource @{ Width = 3; Height = 2; Pixels = $filterPixels; Filters = @(4,4); BeforeIdat = $metadataBefore; AfterIdat = $metadataAfter }
    [void](Invoke-TextureTool @('-SourcePath', $metadataSource, '-DestinationPath', $metadataArtifact, '-Profile', 'debug'))
    if ((Assert-V1Pixels $metadataArtifact 3 2 $filterPixels) -cne $referenceFilterHash) { throw 'Ignored PNG metadata changed decoded KDAT bytes' }

    $iccSource = Join-Path $fixtureRoot 'icc-metadata.png'
    $iccArtifact = Join-Path $output 'metadata-artifacts\icc.texture'
    $iccChunk = @([pscustomobject]@{ Type = 'iCCP'; Data = [byte[]](0x70,0,0) })
    Write-PngFixture $iccSource @{ Width = 3; Height = 2; Pixels = $filterPixels; Filters = @(4,4); BeforeIdat = $iccChunk }
    [void](Invoke-TextureTool @('-SourcePath', $iccSource, '-DestinationPath', $iccArtifact, '-Profile', 'debug'))
    if ((Assert-V1Pixels $iccArtifact 3 2 $filterPixels) -cne $referenceFilterHash) { throw 'Ignored iCCP metadata changed decoded KDAT bytes' }

    [byte[]]$validFixture = New-PngFixtureBytes -Width 1 -Height 1 -Pixels ([byte[]](17,34,51,68)) -Filters @(0)
    [byte[]]$badSignature = $validFixture.Clone()
    $badSignature[0] = 0
    Assert-PngRejected 'signature' $badSignature 'signature'

    $corruptCrcChunk = @([pscustomobject]@{ Type = 'vpAg'; Data = [byte[]](1); CorruptCrc = $true })
    Assert-PngRejected 'crc' (New-PngFixtureBytes -Width 1 -Height 1 -Pixels ([byte[]](17,34,51,68)) -BeforeIdat $corruptCrcChunk) 'CRC'
    Assert-PngRejected 'chunk-type-character' (New-PngFixtureBytes -Width 1 -Height 1 -Pixels ([byte[]](17,34,51,68)) -BeforeIdat @([pscustomobject]@{ Type = 'ab1d'; Data = [byte[]]::new(0) })) 'ASCII letters'
    Assert-PngRejected 'chunk-reserved-bit' (New-PngFixtureBytes -Width 1 -Height 1 -Pixels ([byte[]](17,34,51,68)) -BeforeIdat @([pscustomobject]@{ Type = 'abcd'; Data = [byte[]]::new(0) })) 'reserved'
    Assert-PngRejected 'unknown-critical' (New-PngFixtureBytes -Width 1 -Height 1 -Pixels ([byte[]](17,34,51,68)) -BeforeIdat @([pscustomobject]@{ Type = 'ABCD'; Data = [byte[]]::new(0) })) 'critical'
    Assert-PngRejected 'plte' (New-PngFixtureBytes -Width 1 -Height 1 -Pixels ([byte[]](17,34,51,68)) -BeforeIdat @([pscustomobject]@{ Type = 'PLTE'; Data = [byte[]](0,0,0) })) 'unsupported'
    Assert-PngRejected 'trns' (New-PngFixtureBytes -Width 1 -Height 1 -Pixels ([byte[]](17,34,51,68)) -BeforeIdat @([pscustomobject]@{ Type = 'tRNS'; Data = [byte[]](0,0) })) 'unsupported'
    Assert-PngRejected 'apng' (New-PngFixtureBytes -Width 1 -Height 1 -Pixels ([byte[]](17,34,51,68)) -BeforeIdat @([pscustomobject]@{ Type = 'acTL'; Data = [byte[]]::new(8) })) 'APNG'
    Assert-PngRejected 'grayscale' (New-PngFixtureBytes -Width 1 -Height 1 -Pixels ([byte[]](17,34,51,68)) -ColorType 0) 'RGB or RGBA'
    Assert-PngRejected 'palette' (New-PngFixtureBytes -Width 1 -Height 1 -Pixels ([byte[]](17,34,51,68)) -ColorType 3) 'RGB or RGBA'
    Assert-PngRejected 'gray-alpha' (New-PngFixtureBytes -Width 1 -Height 1 -Pixels ([byte[]](17,34,51,68)) -ColorType 4) 'RGB or RGBA'
    Assert-PngRejected 'bit-depth-16' (New-PngFixtureBytes -Width 1 -Height 1 -Pixels ([byte[]](17,34,51,68)) -BitDepth 16) '8-bit'
    Assert-PngRejected 'adam7' (New-PngFixtureBytes -Width 1 -Height 1 -Pixels ([byte[]](17,34,51,68)) -Interlace 1) 'methods must be zero'
    # iTXt 固定字段至少需要 keyword NUL、compression flag/method、language-tag NUL、translated-keyword NUL，共 6 bytes。
    Assert-PngRejected 'itxt-fixed-fields-too-short' (New-PngFixtureBytes -Width 1 -Height 1 -Pixels ([byte[]](17,34,51,68)) -BeforeIdat @([pscustomobject]@{ Type = 'iTXt'; Data = [byte[]](0,0,0,0,0) })) 'ancillary chunk length is invalid'
    Assert-PngRejected 'metadata-after-idat' (New-PngFixtureBytes -Width 1 -Height 1 -Pixels ([byte[]](17,34,51,68)) -AfterIdat @([pscustomobject]@{ Type = 'gAMA'; Data = [byte[]](0,0,177,143) })) 'after IDAT'
    Assert-PngRejected 'metadata-duplicate' (New-PngFixtureBytes -Width 1 -Height 1 -Pixels ([byte[]](17,34,51,68)) -BeforeIdat @([pscustomobject]@{ Type = 'gAMA'; Data = [byte[]](0,0,177,143) }, [pscustomobject]@{ Type = 'gAMA'; Data = [byte[]](0,0,177,143) })) 'duplicated'
    Assert-PngRejected 'metadata-conflict' (New-PngFixtureBytes -Width 1 -Height 1 -Pixels ([byte[]](17,34,51,68)) -BeforeIdat @([pscustomobject]@{ Type = 'sRGB'; Data = [byte[]](0) }, [pscustomobject]@{ Type = 'iCCP'; Data = [byte[]](0x70,0,0) })) 'cannot coexist'
    Assert-PngRejected 'nonconsecutive-idat' (New-PngFixtureBytes -Width 1 -Height 1 -Pixels ([byte[]](17,34,51,68)) -AfterIdat @([pscustomobject]@{ Type = 'tEXt'; Data = [byte[]](0,1) }, [pscustomobject]@{ Type = 'IDAT'; Data = [byte[]](0) })) 'consecutive'
    Assert-PngRejected 'missing-idat' (New-PngFixtureBytes -Width 1 -Height 1 -Pixels ([byte[]](17,34,51,68)) -OmitIdat) 'IDAT'
    Assert-PngRejected 'missing-iend' (New-PngFixtureBytes -Width 1 -Height 1 -Pixels ([byte[]](17,34,51,68)) -OmitIend) 'missing|required'
    Assert-PngRejected 'nonempty-iend' (New-PngFixtureBytes -Width 1 -Height 1 -Pixels ([byte[]](17,34,51,68)) -AfterIdat @([pscustomobject]@{ Type = 'IEND'; Data = [byte[]](1) }) -OmitIend) 'IEND'
    [byte[]]$trailingBytes = Join-ByteArrays @($validFixture, [byte[]](1,2,3))
    Assert-PngRejected 'trailing-bytes' $trailingBytes 'after IEND'
    [byte[]]$missingIhdr = Join-ByteArrays @([byte[]]$validFixture[0..7], [byte[]]$validFixture[33..($validFixture.Length - 1)])
    Assert-PngRejected 'missing-ihdr' $missingIhdr 'IHDR'

    $wrongExtensionSource = Join-Path $fixtureRoot 'valid-png.bin'
    [IO.File]::WriteAllBytes($wrongExtensionSource, $validFixture)
    [void](Invoke-TextureTool @('-SourcePath', $wrongExtensionSource, '-DestinationPath', (Join-Path $output 'extension\bin.texture'), '-Profile', 'debug') -ExpectFailure)
    $pngNamedPpm = Join-Path $fixtureRoot 'png-content.ppm'
    [IO.File]::WriteAllBytes($pngNamedPpm, $validFixture)
    [void](Invoke-TextureTool @('-SourcePath', $pngNamedPpm, '-DestinationPath', (Join-Path $output 'extension\png-as-ppm.texture'), '-Profile', 'debug') -ExpectFailure)
    $ppmNamedPng = Join-Path $fixtureRoot 'ppm-content.png'
    [IO.File]::WriteAllText($ppmNamedPng, "P3`n1 1`n255`n1 2 3`n", [Text.UTF8Encoding]::new($false))
    [void](Invoke-TextureTool @('-SourcePath', $ppmNamedPng, '-DestinationPath', (Join-Path $output 'extension\ppm-as-png.texture'), '-Profile', 'debug') -ExpectFailure)

    $zlibPixels = [byte[]](17,34,51,68)
    [byte[]]$zlibRows = [KadathPngFixturePrimitives]::EncodeRows($zlibPixels, 1, 1, 4, [int[]](0))
    [byte[]]$validZlib = [KadathPngFixturePrimitives]::CompressZlib($zlibRows)
    [byte[]]$invalidCm = $validZlib.Clone()
    $invalidCm[0] = 0x79
    Assert-PngRejected 'zlib-cm' (New-PngFixtureBytes -Width 1 -Height 1 -Pixels $zlibPixels -OverrideZlib $invalidCm) 'zlib header'
    [byte[]]$invalidCheck = $validZlib.Clone()
    $invalidCheck[1] = $invalidCheck[1] -bxor 1
    Assert-PngRejected 'zlib-fcheck' (New-PngFixtureBytes -Width 1 -Height 1 -Pixels $zlibPixels -OverrideZlib $invalidCheck) 'zlib header'
    [byte[]]$fdict = $validZlib.Clone()
    $fdict[0] = 0x78; $fdict[1] = 0x20
    Assert-PngRejected 'zlib-fdict' (New-PngFixtureBytes -Width 1 -Height 1 -Pixels $zlibPixels -OverrideZlib $fdict) 'FDICT|zlib header'
    for ($truncatedBytes = 1; $truncatedBytes -le 4; $truncatedBytes++) {
        [byte[]]$truncatedAdler = $validZlib[0..($validZlib.Length - 1 - $truncatedBytes)]
        Assert-PngRejected ("zlib-adler-truncated-{0}" -f $truncatedBytes) (New-PngFixtureBytes -Width 1 -Height 1 -Pixels $zlibPixels -OverrideZlib $truncatedAdler) 'zlib|deflate|Adler|truncated'
    }
    [byte[]]$badAdler = $validZlib.Clone()
    $badAdler[$badAdler.Length - 1] = $badAdler[$badAdler.Length - 1] -bxor 1
    Assert-PngRejected 'zlib-adler-mismatch' (New-PngFixtureBytes -Width 1 -Height 1 -Pixels $zlibPixels -OverrideZlib $badAdler) 'Adler'

    [byte[]]$shortRows = $zlibRows[0..($zlibRows.Length - 2)]
    [byte[]]$shortZlib = [KadathPngFixturePrimitives]::CompressZlib($shortRows)
    Assert-PngRejected 'inflate-truncated' (New-PngFixtureBytes -Width 1 -Height 1 -Pixels $zlibPixels -OverrideZlib $shortZlib) 'truncated'
    [byte[]]$longRows = Join-ByteArrays @($zlibRows, [byte[]](99))
    [byte[]]$longZlib = [KadathPngFixturePrimitives]::CompressZlib($longRows)
    Assert-PngRejected 'inflate-overlong' (New-PngFixtureBytes -Width 1 -Height 1 -Pixels $zlibPixels -OverrideZlib $longZlib) 'exceeds|exact'
    [byte[]]$invalidFilterRows = $zlibRows.Clone()
    $invalidFilterRows[0] = 5
    [byte[]]$invalidFilterZlib = [KadathPngFixturePrimitives]::CompressZlib($invalidFilterRows)
    Assert-PngRejected 'invalid-filter' (New-PngFixtureBytes -Width 1 -Height 1 -Pixels $zlibPixels -OverrideZlib $invalidFilterZlib) 'filter'

    # raw body 后的 suffix 位于 Adler trailer 之前；严格 decoder 必须证明 DeflateStream 消费完整 body。
    [byte[]]$rawBodySuffix = Join-ByteArrays @(
        [byte[]]$validZlib[0..($validZlib.Length - 5)],
        [byte[]](0x13,0x37,0x42),
        [byte[]]$validZlib[($validZlib.Length - 4)..($validZlib.Length - 1)]
    )
    Assert-PngRejected 'raw-body-suffix' (New-PngFixtureBytes -Width 1 -Height 1 -Pixels $zlibPixels -OverrideZlib $rawBodySuffix) 'consumed exactly|deflate body'
    [byte[]]$concatenatedZlib = Join-ByteArrays @($validZlib, $validZlib)
    Assert-PngRejected 'concatenated-zlib' (New-PngFixtureBytes -Width 1 -Height 1 -Pixels $zlibPixels -OverrideZlib $concatenatedZlib) 'consumed exactly|deflate body'
    [byte[]]$zlibRandomSuffix = Join-ByteArrays @($validZlib, [byte[]](1,2,3,4))
    Assert-PngRejected 'zlib-random-suffix' (New-PngFixtureBytes -Width 1 -Height 1 -Pixels $zlibPixels -OverrideZlib $zlibRandomSuffix) 'consumed exactly|deflate|Adler'

    # 构造 BFINAL=0 的 stored block：可产出完整 scanline，却没有 final-block end，不能把底层 EOF 当成功。
    $storedLength = $zlibRows.Length
    $storedComplement = 0xffff - $storedLength
    [byte[]]$unfinishedBody = Join-ByteArrays @(
        [byte[]](0x00, [byte]($storedLength -band 0xff), [byte](($storedLength -shr 8) -band 0xff), [byte]($storedComplement -band 0xff), [byte](($storedComplement -shr 8) -band 0xff)),
        $zlibRows
    )
    $storedAdler = [KadathPngFixturePrimitives]::Adler32($zlibRows)
    [byte[]]$unfinishedZlib = Join-ByteArrays @([byte[]](0x78,0x01), $unfinishedBody, (ConvertTo-BigEndianUInt32Bytes $storedAdler))
    Assert-PngRejected 'deflate-missing-final-block' (New-PngFixtureBytes -Width 1 -Height 1 -Pixels $zlibPixels -OverrideZlib $unfinishedZlib) 'final block|deflate body'

    $dimensionPixels = [KadathPngFixturePrimitives]::CreatePattern(8192 * 4)
    $dimensionSource = Join-Path $fixtureRoot 'dimension-exact.png'
    $dimensionArtifact = Join-Path $output 'limits\dimension-exact.texture'
    Write-PngFixture $dimensionSource @{ Width = 8192; Height = 1; Pixels = $dimensionPixels; Filters = @(4) }
    [void](Invoke-TextureTool @('-SourcePath', $dimensionSource, '-DestinationPath', $dimensionArtifact, '-Profile', 'debug'))
    [void](Assert-V1Pixels $dimensionArtifact 8192 1 $dimensionPixels)
    Assert-PngRejected 'dimension-zero' (New-PngFixtureBytes -Width 0 -Height 1 -Pixels ([byte[]]::new(0)) -OverrideZlib $validZlib) 'dimensions'
    Assert-PngRejected 'dimension-over' (New-PngFixtureBytes -Width 8193 -Height 1 -Pixels ([byte[]]::new(0)) -OverrideZlib $validZlib) 'dimensions'
    Assert-PngRejected 'pixel-over' (New-PngFixtureBytes -Width 1025 -Height 1024 -Pixels ([byte[]]::new(0)) -OverrideZlib $validZlib) 'pixel limit'

    $chunkOverflow = [Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt 126; $index++) { $chunkOverflow.Add([pscustomobject]@{ Type = 'vpAg'; Data = [byte[]]::new(0) }) }
    Assert-PngRejected 'chunk-count-over' (New-PngFixtureBytes -Width 1 -Height 1 -Pixels $zlibPixels -BeforeIdat $chunkOverflow.ToArray()) '128 chunk'

    $dryNoParent = Join-Path $output 'dry-run-missing-parent\inner\test.texture'
    $dryResult = Invoke-TextureTool @('-SourcePath', $checkedPngSource, '-DestinationPath', $dryNoParent, '-Profile', 'release', '-DryRun')
    $dryPlan = $dryResult.Output[-1] | ConvertFrom-Json
    if ([int]$dryPlan.ArtifactVersion -ne 2 -or [string]$dryPlan.SourceFormat -cne 'PNG-RGBA8' -or (Test-Path -LiteralPath (Split-Path -Parent $dryNoParent))) { throw 'PNG DryRun created output state or returned an invalid full plan' }

    $existingDestination = Join-Path $output 'retention\test.texture'
    New-Item -ItemType Directory -Path (Split-Path -Parent $existingDestination) | Out-Null
    [byte[]]$foreignBytes = [Text.Encoding]::ASCII.GetBytes('foreign-artifact-must-survive')
    [IO.File]::WriteAllBytes($existingDestination, $foreignBytes)
    $foreignHash = Get-Hash $existingDestination
    [void](Invoke-TextureTool @('-SourcePath', $checkedPngSource, '-DestinationPath', $existingDestination, '-Profile', 'debug') -ExpectFailure)
    if ((Get-Hash $existingDestination) -cne $foreignHash) { throw 'Pre-existing destination changed after rejected import' }
    $retentionFiles = @(Get-ChildItem -LiteralPath (Split-Path -Parent $existingDestination) -Force -File)
    if ($retentionFiles.Count -ne 1 -or $retentionFiles[0].Name -cne 'test.texture') { throw 'Pre-existing destination rejection left owned temp files' }

    $reproSourceA = Join-Path $fixtureRoot 'repro-a\test.png'
    $reproSourceB = Join-Path $fixtureRoot 'repro-b\test.png'
    New-Item -ItemType Directory -Path (Split-Path -Parent $reproSourceA),(Split-Path -Parent $reproSourceB) | Out-Null
    [IO.File]::Copy($checkedPngSource, $reproSourceA)
    [IO.File]::Copy($checkedPngSource, $reproSourceB)
    $reproArtifactA = Join-Path $output 'repro-output-a\deep\test.texture'
    $reproArtifactB = Join-Path $output 'repro-output-b\other\test.texture'
    [void](Invoke-TextureTool @('-SourcePath', $reproSourceA, '-DestinationPath', $reproArtifactA, '-Profile', 'release'))
    [void](Invoke-TextureTool @('-SourcePath', $reproSourceB, '-DestinationPath', $reproArtifactB, '-Profile', 'release'))
    if ((Get-Hash $reproArtifactA) -cne (Get-Hash $reproArtifactB)) { throw 'Absolute source/output roots changed deterministic KDAT bytes' }
    if ((Get-Hash $reproSourceA) -cne (Get-Hash $reproSourceB)) { throw 'Reproducibility import changed a source file' }

    foreach ($oversizedLength in @(8MB, (8MB + 1))) {
        $oversizedSource = Join-Path $fixtureRoot ("source-limit-{0}.png" -f $oversizedLength)
        $oversizedStream = [IO.File]::Open($oversizedSource, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $oversizedStream.SetLength($oversizedLength) } finally { $oversizedStream.Dispose() }
        $oversizedDestination = Join-Path $output ("limits\source-{0}\test.texture" -f $oversizedLength)
        [void](Invoke-TextureTool @('-SourcePath', $oversizedSource, '-DestinationPath', $oversizedDestination, '-Profile', 'debug') -ExpectFailure)
        if (Test-Path -LiteralPath $oversizedDestination) { throw "Oversized source $oversizedLength created an artifact" }
    }

    $snapshotTargetLength = 8MB - 1
    [byte[]]$snapshotBaseA = New-PngFixtureBytes -Width 1 -Height 1 -Pixels ([byte[]](10,20,30,40))
    [byte[]]$snapshotBaseB = New-PngFixtureBytes -Width 1 -Height 1 -Pixels ([byte[]](210,220,230,240))
    $snapshotPaddingA = $snapshotTargetLength - $snapshotBaseA.Length - 12
    $snapshotPaddingB = $snapshotTargetLength - $snapshotBaseB.Length - 12
    $snapshotChunkA = @([pscustomobject]@{ Type = 'vpAg'; Data = [byte[]]::new($snapshotPaddingA) })
    $snapshotChunkB = @([pscustomobject]@{ Type = 'vpAg'; Data = [byte[]]::new($snapshotPaddingB) })
    [byte[]]$snapshotBytesA = New-PngFixtureBytes -Width 1 -Height 1 -Pixels ([byte[]](10,20,30,40)) -BeforeIdat $snapshotChunkA
    [byte[]]$snapshotBytesB = New-PngFixtureBytes -Width 1 -Height 1 -Pixels ([byte[]](210,220,230,240)) -BeforeIdat $snapshotChunkB
    if ($snapshotBytesA.Length -ne $snapshotTargetLength -or $snapshotBytesB.Length -ne $snapshotTargetLength) { throw 'Concurrent snapshot fixtures must have equal source-limit-minus-one lengths' }
    $snapshotTemplateA = Join-Path $fixtureRoot 'snapshot-template-a.png'
    $snapshotTemplateB = Join-Path $fixtureRoot 'snapshot-template-b.png'
    $snapshotSource = Join-Path $fixtureRoot 'snapshot-live.png'
    [IO.File]::WriteAllBytes($snapshotTemplateA, $snapshotBytesA)
    [IO.File]::WriteAllBytes($snapshotTemplateB, $snapshotBytesB)
    [IO.File]::WriteAllBytes($snapshotSource, $snapshotBytesA)
    $snapshotExpectedA = Join-Path $output 'snapshot-expected\a.texture'
    $snapshotExpectedB = Join-Path $output 'snapshot-expected\b.texture'
    [void](Invoke-TextureTool @('-SourcePath', $snapshotTemplateA, '-DestinationPath', $snapshotExpectedA, '-Profile', 'debug'))
    [void](Invoke-TextureTool @('-SourcePath', $snapshotTemplateB, '-DestinationPath', $snapshotExpectedB, '-Profile', 'debug'))
    $snapshotHashA = Get-Hash $snapshotExpectedA
    $snapshotHashB = Get-Hash $snapshotExpectedB
    if ($snapshotHashA -ceq $snapshotHashB) { throw 'Snapshot A/B fixtures did not produce distinct KDAT identities' }
    $snapshotStop = Join-Path $fixtureRoot 'snapshot-mutator.stop'
    $mutatorProcess = Start-PngSnapshotMutator $snapshotSource $snapshotTemplateA $snapshotTemplateB $snapshotStop
    $snapshotSuccesses = 0
    for ($round = 0; $round -lt 4; $round++) {
        $snapshotDestination = Join-Path $output ("snapshot-concurrent\round-{0}\test.texture" -f $round)
        $snapshotChild = Start-TextureToolProcess @('-SourcePath', $snapshotSource, '-DestinationPath', $snapshotDestination, '-Profile', 'debug')
        $snapshotOutcome = Complete-TextureToolProcess $snapshotChild 30000
        if ($snapshotOutcome.ExitCode -eq 0) {
            $snapshotSuccesses++
            $snapshotHash = Get-Hash $snapshotDestination
            if ($snapshotHash -cne $snapshotHashA -and $snapshotHash -cne $snapshotHashB) { throw "Concurrent source mutation produced a hybrid/unknown KDAT hash: $snapshotHash" }
        } elseif (Test-Path -LiteralPath $snapshotDestination) {
            throw "Failed concurrent snapshot import left an artifact: round=$round"
        }
        $snapshotParent = Split-Path -Parent $snapshotDestination
        if (Test-Path -LiteralPath $snapshotParent) {
            $snapshotTemps = @(Get-ChildItem -LiteralPath $snapshotParent -Force -File | Where-Object { $_.Name -ne 'test.texture' })
            if ($snapshotTemps.Count -ne 0) { throw "Concurrent snapshot import left owned temp files: round=$round" }
        }
    }
    [IO.File]::WriteAllText($snapshotStop, 'stop', [Text.UTF8Encoding]::new($false))
    if (-not $mutatorProcess.WaitForExit(30000)) { $mutatorProcess.Kill($true); $mutatorProcess.WaitForExit(); throw 'PNG snapshot mutator did not stop in time' }
    $mutatorStdout = $mutatorProcess.StandardOutput.ReadToEnd()
    $mutatorStderr = $mutatorProcess.StandardError.ReadToEnd()
    if ($mutatorProcess.ExitCode -ne 0) { throw "PNG snapshot mutator failed: $mutatorStderr" }
    $mutatorStats = ($mutatorStdout -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1) | ConvertFrom-Json
    if ([int]$mutatorStats.replaceAttempts -le 0 -or [int]$mutatorStats.growAttempts -le 0 -or [int]$mutatorStats.shrinkAttempts -le 0) { throw 'PNG snapshot mutator did not attempt replace/grow/shrink operations' }
    if ([int]$mutatorStats.replaceSuccesses -le 0 -or [int]$mutatorStats.growSuccesses -le 0 -or [int]$mutatorStats.shrinkSuccesses -le 0) { throw "PNG snapshot mutator never completed every mutation mode: $($mutatorStats | ConvertTo-Json -Compress)" }
    $snapshotFinalHash = Get-Hash $snapshotSource
    if ($snapshotFinalHash -cne (Get-Hash $snapshotTemplateA) -and $snapshotFinalHash -cne (Get-Hash $snapshotTemplateB)) { throw 'Concurrent snapshot source did not finish as complete fixture A or B' }

    $performancePixels = [KadathPngFixturePrimitives]::CreatePattern(1024 * 1024 * 4)
    $performanceFilters = [int[]](@(4) * 1024)
    [byte[]]$performanceRows = [KadathPngFixturePrimitives]::EncodeRows($performancePixels, 1024, 1024, 4, $performanceFilters)
    [byte[]]$performanceZlib = [KadathPngFixturePrimitives]::CompressZlib($performanceRows)
    $baseBytesWithEmptyAncillary = 8 + 25 + (12 + $performanceZlib.Length) + 12 + (125 * 12)
    $paddingLength = (8MB - 1) - $baseBytesWithEmptyAncillary
    if ($paddingLength -le 0) { throw "Performance fixture cannot fit below source limit: zlib=$($performanceZlib.Length)" }
    $performanceAncillary = [Collections.Generic.List[object]]::new()
    $performanceAncillary.Add([pscustomobject]@{ Type = 'vpAg'; Data = [byte[]]::new($paddingLength) })
    for ($index = 1; $index -lt 125; $index++) { $performanceAncillary.Add([pscustomobject]@{ Type = 'vpAg'; Data = [byte[]]::new(0) }) }
    $performanceSource = Join-Path $fixtureRoot 'performance-128-chunks.png'
    [byte[]]$performancePng = New-PngFixtureBytes -Width 1024 -Height 1024 -Pixels $performancePixels -Filters $performanceFilters -BeforeIdat $performanceAncillary.ToArray() -OverrideZlib $performanceZlib
    if ($performancePng.Length -ne (8MB - 1)) { throw "Performance fixture is not exactly source-limit minus one: $($performancePng.Length)" }
    [IO.File]::WriteAllBytes($performanceSource, $performancePng)
    $performanceSourceHash = Get-Hash $performanceSource
    $performanceDestination = Join-Path $output 'performance\test.texture'
    $performanceClock = [Diagnostics.Stopwatch]::StartNew()
    $performanceProcess = Start-TextureToolProcess @('-SourcePath', $performanceSource, '-DestinationPath', $performanceDestination, '-Profile', 'release')
    $remainingMilliseconds = 60000 - [int]$performanceClock.ElapsedMilliseconds
    if ($remainingMilliseconds -le 0) {
        $performanceProcess.Kill($true); $performanceProcess.WaitForExit()
        Assert-PerformanceTimeoutCleanup $performanceDestination
        throw 'Worst-case PNG import exceeded 60000 ms before snapshot checks completed'
    }
    $performance = Complete-TextureToolPerformance $performanceProcess $performanceDestination $remainingMilliseconds
    $performance.ElapsedMilliseconds = $performanceClock.ElapsedMilliseconds
    if ($performance.ExitCode -ne 0) { throw "Worst-case PNG import failed: $($performance.Stderr)" }
    if ($performance.PeakWorkingSet64 -gt 256MB) { throw "Worst-case PNG import peak working set exceeded 256 MiB: $($performance.PeakWorkingSet64)" }
    if ((Get-Hash $performanceSource) -cne $performanceSourceHash) { throw 'Worst-case import changed the source snapshot' }
    [byte[]]$performanceArtifact = [IO.File]::ReadAllBytes($performanceDestination)
    if ([BitConverter]::ToUInt32($performanceArtifact, 4) -ne 2 -or [BitConverter]::ToUInt32($performanceArtifact, 8) -ne 1024 -or [BitConverter]::ToUInt32($performanceArtifact, 12) -ne 1024 -or $performanceArtifact.Length -ge 8MB) { throw 'Worst-case import produced invalid KDAT v2 bounds' }
    $performanceTemps = @(Get-ChildItem -LiteralPath (Split-Path -Parent $performanceDestination) -Force -File | Where-Object { $_.Name -ne 'test.texture' })
    if ($performanceTemps.Count -ne 0) { throw 'Worst-case import left owned temp files' }

    $dryDebug = Invoke-TextureTool @('-SourcePath', $ppmSource, '-DestinationPath', $debugArtifact, '-Profile', 'debug', '-DryRun')
    $debugPlan = $dryDebug.Output[-1] | ConvertFrom-Json
    if ([int]$debugPlan.ImporterVersion -ne 1 -or [int]$debugPlan.BakerVersion -ne 1 -or [int]$debugPlan.ArtifactVersion -ne 1 -or [string]$debugPlan.ArtifactFormat -cne 'KDAT-TEXTURE-V1' -or [string]$debugPlan.Transform -cne 'ppm-to-rgba8-artifact-v1' -or [int]$debugPlan.MipLevelCount -ne 1 -or [int]$debugPlan.ArtifactBytes -ne 36 -or (Test-Path $debugArtifact)) { throw 'Texture debug profile dry-run failed' }
    $dryRelease = Invoke-TextureTool @('-SourcePath', $ppmSource, '-DestinationPath', $releaseArtifact, '-Profile', 'release', '-DryRun')
    $releasePlan = $dryRelease.Output[-1] | ConvertFrom-Json
    if ([int]$releasePlan.ArtifactVersion -ne 2 -or [string]$releasePlan.ArtifactFormat -cne 'KDAT-TEXTURE-V2-MIPMAP' -or [string]$releasePlan.Transform -cne 'ppm-to-rgba8-mipmap-artifact-v2' -or [int]$releasePlan.MipLevelCount -ne 2 -or [int]$releasePlan.ArtifactBytes -ne 44 -or (Test-Path $releaseArtifact)) { throw 'Texture release profile dry-run failed' }

    [void](Invoke-TextureTool @('-SourcePath', $ppmSource, '-DestinationPath', $debugArtifact, '-Profile', 'debug'))
    [void](Invoke-TextureTool @('-SourcePath', $ppmSource, '-DestinationPath', $releaseArtifact, '-Profile', 'release'))
    $debugHash = Assert-V1Artifact $debugArtifact
    $releaseHash = Assert-V2MipmapArtifact $releaseArtifact
    if ($debugHash -ceq $releaseHash) { throw 'Debug/release texture profiles must produce distinct artifacts' }
    [void](Invoke-TextureTool @('-SourcePath', $opaquePngSource, '-DestinationPath', $opaquePngDebug, '-Profile', 'debug'))
    [void](Invoke-TextureTool @('-SourcePath', $opaquePngSource, '-DestinationPath', $opaquePngRelease, '-Profile', 'release'))
    # 先用独立 RGBA 期望证明 PPM 与 opaque PNG 的像素相等，再比较整个 profile artifact 的 byte identity。
    $opaqueDebugHash = Assert-V1Artifact $opaquePngDebug
    $opaqueReleaseHash = Assert-V2MipmapArtifact $opaquePngRelease
    if ($opaqueDebugHash -cne $debugHash -or $opaqueReleaseHash -cne $releaseHash) { throw 'Equivalent dynamic PPM/opaque PNG pixels did not produce byte-identical debug/release KDAT artifacts' }
    $generatedHash = Assert-CheckedPngV2Artifact $generated
    if ($generatedHash -cne $checkedPngReleaseHash) { throw 'Generated release texture artifact does not match checked PNG importer output' }

    New-Item -ItemType Directory -Path (Split-Path -Parent $invalidSource) -Force | Out-Null
    [IO.File]::WriteAllText($invalidSource, "P3`n2 2`n255`n255 0 0`n", [Text.UTF8Encoding]::new($false))
    [void](Invoke-TextureTool @('-SourcePath', $invalidSource, '-DestinationPath', $invalidArtifact, '-DryRun') -ExpectFailure)
    if (Test-Path $invalidArtifact) { throw 'Invalid PPM created an artifact' }
    [void](Invoke-TextureTool @('-SourcePath', $checkedPngSource, '-DestinationPath', $invalidPackageArtifact, '-DryRun') -ExpectFailure)
    if (Test-Path $invalidPackageArtifact) { throw 'Package boundary violation created an artifact' }
    if ($ppmSourceHashBefore -cne (Get-Hash $ppmSource)) { throw 'Dynamic PPM source changed during texture import verification' }
    if ($checkedPngHashBefore -cne (Get-Hash $checkedPngSource)) { throw 'Checked PNG source changed during texture import verification' }

    Write-Output 'texture_importer_version=1'
    Write-Output 'texture_baker_version=1'
    Write-Output 'debug_artifact_format=KDAT-TEXTURE-V1'
    Write-Output 'release_artifact_format=KDAT-TEXTURE-V2-MIPMAP'
    Write-Output 'dry_run=ok'
    Write-Output 'debug_artifact=ok'
    Write-Output 'release_artifact=ok'
    Write-Output 'profile_transform=ok'
    Write-Output 'mipmap_pixels=ok'
    Write-Output 'artifact_reproducibility=ok'
    Write-Output 'invalid_ppm_rejected=ok'
    Write-Output 'package_boundary=ok'
    Write-Output 'generated_artifact=ok'
    Write-Output 'source_immutable=ok'
    Write-Output 'png_checked_source=ok'
    Write-Output 'png_rgba_alpha=ok'
    Write-Output 'png_debug_release=ok'
    Write-Output 'destination_race=ok'
    Write-Output 'png_rgb_alpha_expansion=ok'
    Write-Output 'png_filters=0,1,2,3,4'
    Write-Output 'png_consecutive_idat=ok'
    Write-Output 'png_deflate_encodings=stored,optimal'
    Write-Output 'ppm_png_opaque_equivalence=ok'
    Write-Output 'png_metadata_ignored=ok'
    Write-Output 'png_chunk_validation=ok'
    Write-Output 'png_unsupported_formats=ok'
    Write-Output 'png_extension_dispatch=ok'
    Write-Output 'png_rfc1950_validation=ok'
    Write-Output 'png_deflate_exact_consumption=ok'
    Write-Output 'png_adler32=ok'
    Write-Output 'png_limits=ok'
    Write-Output 'png_dry_run_no_state=ok'
    Write-Output 'destination_retention=ok'
    Write-Output 'path_safety=device,unc,reparse-ancestor,package-alias'
    Write-Output 'absolute_root_reproducibility=ok'
    Write-Output 'source_snapshot_consistency=ok'
    Write-Output "source_snapshot_successes=$snapshotSuccesses"
    Write-Output "source_snapshot_sharing_denied=$($mutatorStats.sharingDenied)"
    Write-Output "performance_elapsed_ms=$($performance.ElapsedMilliseconds)"
    Write-Output "performance_peak_working_set=$($performance.PeakWorkingSet64)"
    Write-Output 'performance_gate=ok'
    Write-Output 'verification=ok'
} finally {
    if ($null -ne $mutatorProcess -and -not $mutatorProcess.HasExited) {
        if (-not (Test-Path -LiteralPath (Join-Path $fixtureRoot 'snapshot-mutator.stop'))) { [IO.File]::WriteAllText((Join-Path $fixtureRoot 'snapshot-mutator.stop'), 'stop') }
        if (-not $mutatorProcess.WaitForExit(5000)) { $mutatorProcess.Kill($true); $mutatorProcess.WaitForExit() }
    }
    if ($null -ne $performanceProcess -and -not $performanceProcess.HasExited) {
        $performanceProcess.Kill($true)
        $performanceProcess.WaitForExit()
    }
    if (Test-Path -LiteralPath $output) { Remove-Item -LiteralPath $output -Recurse -Force }
}
