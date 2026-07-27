[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,

    [Parameter(Mandatory = $true)]
    [string]$DestinationPath,

    [ValidateSet('debug', 'release')]
    [string]$Profile = 'debug',

    # DryRun 仍完整解析/校验 source 并计算 profile，但不创建任何产物。
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:TextureArtifactMagic = 'KDAT'
$script:TextureArtifactVersionBase = 1
$script:TextureArtifactVersionMipmap = 2
$script:TextureArtifactHeaderBytesBase = 20
$script:TextureArtifactHeaderBytesMipmap = 24
$script:TextureArtifactMaxPixels = 1024 * 1024
$script:TextureArtifactMaxBytes = 8 * 1024 * 1024

# PNG 解码仍是 Importer Module 的私有 Implementation。C# 只用于有界字节热路与
# DeflateStream 的 exact-consumption Stream Adapter，不引入 NuGet、native codec 或新公共 Interface。
if ($null -eq ('Kadath.TexturePng.Decoder' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;

namespace Kadath.TexturePng
{
    public sealed class DecodedTexture
    {
        public int Width { get; private set; }
        public int Height { get; private set; }
        public byte[] Pixels { get; private set; }
        public string SourceFormat { get; private set; }

        public DecodedTexture(int width, int height, byte[] pixels, string sourceFormat)
        {
            Width = width;
            Height = height;
            Pixels = pixels;
            SourceFormat = sourceFormat;
        }
    }

    internal sealed class EndOfDeflateBodyException : IOException
    {
        internal EndOfDeflateBodyException() : base("Deflate decoder read beyond the declared raw body.") { }
    }

    internal sealed class OneByteInputStream : Stream
    {
        private readonly byte[] bytes;
        private int offset;

        internal OneByteInputStream(byte[] bytes)
        {
            this.bytes = bytes;
        }

        internal int Consumed { get { return offset; } }
        internal bool EndSentinelRaised { get; private set; }
        public override bool CanRead { get { return true; } }
        public override bool CanSeek { get { return false; } }
        public override bool CanWrite { get { return false; } }
        public override long Length { get { throw new NotSupportedException(); } }
        public override long Position { get { return offset; } set { throw new NotSupportedException(); } }

        public override int Read(byte[] buffer, int bufferOffset, int count)
        {
            if (count == 0) return 0;
            if (offset >= bytes.Length)
            {
                EndSentinelRaised = true;
                throw new EndOfDeflateBodyException();
            }
            buffer[bufferOffset] = bytes[offset++];
            return 1;
        }

        public override int ReadByte()
        {
            if (offset >= bytes.Length)
            {
                EndSentinelRaised = true;
                throw new EndOfDeflateBodyException();
            }
            return bytes[offset++];
        }

        public override void Flush() { }
        public override long Seek(long offsetValue, SeekOrigin origin) { throw new NotSupportedException(); }
        public override void SetLength(long value) { throw new NotSupportedException(); }
        public override void Write(byte[] buffer, int offsetValue, int count) { throw new NotSupportedException(); }
    }

    public static class Decoder
    {
        private const int SourceLimit = 8 * 1024 * 1024;
        private const int PixelLimit = 1024 * 1024;
        private const int DimensionLimit = 8192;
        private const int ChunkLimit = 128;
        private static readonly uint[] CrcTable = BuildCrcTable();

        public static DecodedTexture DecodeFile(string path)
        {
            byte[] source;
            // 关键快照边界：先用唯一 handle 校验长度，再精确分配和读取。
            using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 4096, FileOptions.SequentialScan))
            {
                long length = stream.Length;
                if (length <= 0 || length >= SourceLimit)
                    throw new InvalidDataException("PNG source must be non-empty and strictly smaller than 8 MiB.");
                source = new byte[(int)length];
                int offset = 0;
                while (offset < source.Length)
                {
                    int read = stream.Read(source, offset, source.Length - offset);
                    if (read == 0) throw new InvalidDataException("PNG source changed or ended during snapshot read.");
                    offset += read;
                }
                if (stream.ReadByte() != -1) throw new InvalidDataException("PNG source grew during snapshot read.");
            }
            return Decode(source);
        }

        private static DecodedTexture Decode(byte[] source)
        {
            byte[] signature = new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 };
            if (source.Length < signature.Length) throw new InvalidDataException("PNG signature is truncated.");
            for (int index = 0; index < signature.Length; index++)
                if (source[index] != signature[index]) throw new InvalidDataException("PNG signature is invalid.");

            int offset = signature.Length;
            int chunkCount = 0;
            bool seenHeader = false;
            bool seenData = false;
            bool dataRunEnded = false;
            bool seenEnd = false;
            bool seenIccp = false;
            bool seenSrgb = false;
            int width = 0;
            int height = 0;
            int channels = 0;
            string sourceFormat = null;
            long idatLength = 0;
            List<ArraySegment<byte>> idatSegments = new List<ArraySegment<byte>>();
            HashSet<string> singletonAncillary = new HashSet<string>(StringComparer.Ordinal);

            while (offset < source.Length)
            {
                if (source.Length - offset < 12) throw new InvalidDataException("PNG chunk is truncated.");
                uint lengthValue = ReadUInt32(source, offset);
                if (lengthValue > Int32.MaxValue) throw new InvalidDataException("PNG chunk length is unsupported.");
                int length = (int)lengthValue;
                int typeOffset = offset + 4;
                int dataOffset = offset + 8;
                long nextOffsetLong = (long)dataOffset + length + 4;
                if (nextOffsetLong > source.Length) throw new InvalidDataException("PNG chunk exceeds the source snapshot.");
                int nextOffset = (int)nextOffsetLong;
                chunkCount++;
                if (chunkCount > ChunkLimit) throw new InvalidDataException("PNG exceeds the 128 chunk limit.");

                for (int index = 0; index < 4; index++)
                {
                    byte value = source[typeOffset + index];
                    if (!IsAsciiLetter(value)) throw new InvalidDataException("PNG chunk type must contain only ASCII letters.");
                }
                if (!IsUpperAscii(source[typeOffset + 2])) throw new InvalidDataException("PNG chunk reserved bit must be uppercase.");
                string type = System.Text.Encoding.ASCII.GetString(source, typeOffset, 4);
                uint expectedCrc = ReadUInt32(source, dataOffset + length);
                uint actualCrc = ComputeCrc(source, typeOffset, 4 + length);
                if (actualCrc != expectedCrc) throw new InvalidDataException("PNG chunk CRC mismatch: " + type);

                if (!seenHeader && type != "IHDR") throw new InvalidDataException("IHDR must be the first PNG chunk.");
                if (type == "IHDR")
                {
                    if (seenHeader || chunkCount != 1 || length != 13) throw new InvalidDataException("PNG must contain one 13-byte IHDR first.");
                    uint widthValue = ReadUInt32(source, dataOffset);
                    uint heightValue = ReadUInt32(source, dataOffset + 4);
                    if (widthValue == 0 || heightValue == 0 || widthValue > DimensionLimit || heightValue > DimensionLimit)
                        throw new InvalidDataException("PNG dimensions must be in [1, 8192].");
                    long pixels = (long)widthValue * heightValue;
                    if (pixels > PixelLimit) throw new InvalidDataException("PNG exceeds the pixel limit.");
                    byte bitDepth = source[dataOffset + 8];
                    byte colorType = source[dataOffset + 9];
                    if (bitDepth != 8 || (colorType != 2 && colorType != 6))
                        throw new InvalidDataException("PNG v1 accepts only 8-bit RGB or RGBA.");
                    if (source[dataOffset + 10] != 0 || source[dataOffset + 11] != 0 || source[dataOffset + 12] != 0)
                        throw new InvalidDataException("PNG compression, filter, and interlace methods must be zero.");
                    width = (int)widthValue;
                    height = (int)heightValue;
                    channels = colorType == 2 ? 3 : 4;
                    sourceFormat = colorType == 2 ? "PNG-RGB8" : "PNG-RGBA8";
                    seenHeader = true;
                }
                else if (type == "IDAT")
                {
                    if (!seenHeader || seenEnd || dataRunEnded) throw new InvalidDataException("PNG IDAT chunks must be consecutive and ordered.");
                    idatLength = checked(idatLength + length);
                    if (idatLength >= SourceLimit) throw new InvalidDataException("PNG IDAT payload must be strictly smaller than 8 MiB.");
                    idatSegments.Add(new ArraySegment<byte>(source, dataOffset, length));
                    seenData = true;
                }
                else if (type == "IEND")
                {
                    if (!seenData || seenEnd || length != 0) throw new InvalidDataException("PNG must end with one empty IEND after IDAT.");
                    seenEnd = true;
                    dataRunEnded = true;
                    if (nextOffset != source.Length) throw new InvalidDataException("PNG contains bytes after IEND.");
                }
                else
                {
                    if (seenData) dataRunEnded = true;
                    if (type == "PLTE" || type == "tRNS") throw new InvalidDataException("PNG palette/transparency chunks are unsupported.");
                    if (type == "acTL" || type == "fcTL" || type == "fdAT") throw new InvalidDataException("APNG chunks are unsupported.");
                    bool ancillary = (source[typeOffset] & 0x20) != 0;
                    if (!ancillary) throw new InvalidDataException("Unknown critical PNG chunk: " + type);
                    ValidateAncillary(type, length, seenData, singletonAncillary, ref seenIccp, ref seenSrgb);
                }

                offset = nextOffset;
                if (seenEnd) break;
            }

            if (!seenHeader || !seenData || !seenEnd || offset != source.Length)
                throw new InvalidDataException("PNG is missing required IHDR, IDAT, or IEND chunks.");
            if (idatLength > Int32.MaxValue) throw new InvalidDataException("PNG compressed payload is too large.");
            byte[] zlib = new byte[(int)idatLength];
            int zlibOffset = 0;
            foreach (ArraySegment<byte> segment in idatSegments)
            {
                Buffer.BlockCopy(segment.Array, segment.Offset, zlib, zlibOffset, segment.Count);
                zlibOffset += segment.Count;
            }

            long rowBytesLong = checked((long)width * channels);
            long expectedInflatedLong = checked((long)height * (1L + rowBytesLong));
            long rgbaBytesLong = checked((long)width * height * 4L);
            if (rgbaBytesLong > 4L * 1024 * 1024 || expectedInflatedLong > Int32.MaxValue)
                throw new InvalidDataException("PNG decoded payload exceeds the RGBA8 budget.");
            byte[] inflated = InflateZlibExact(zlib, (int)expectedInflatedLong);
            byte[] rgba = Unfilter(inflated, width, height, channels);
            return new DecodedTexture(width, height, rgba, sourceFormat);
        }

        private static byte[] InflateZlibExact(byte[] zlib, int expectedLength)
        {
            if (zlib.Length < 7) throw new InvalidDataException("PNG zlib stream is truncated.");
            int cmf = zlib[0];
            int flg = zlib[1];
            if ((cmf & 15) != 8 || (cmf >> 4) > 7 || (((cmf << 8) | flg) % 31) != 0 || (flg & 32) != 0)
                throw new InvalidDataException("PNG zlib header is invalid or uses FDICT.");

            int bodyLength = zlib.Length - 6;
            if (bodyLength <= 0) throw new InvalidDataException("PNG raw deflate body is missing.");
            byte[] body = new byte[bodyLength];
            Buffer.BlockCopy(zlib, 2, body, 0, bodyLength);
            uint expectedAdler = ReadUInt32(zlib, zlib.Length - 4);
            byte[] output = new byte[expectedLength];
            OneByteInputStream input = new OneByteInputStream(body);
            try
            {
                using (DeflateStream inflater = new DeflateStream(input, CompressionMode.Decompress, true))
                {
                    int offset = 0;
                    while (offset < output.Length)
                    {
                        int read = inflater.Read(output, offset, output.Length - offset);
                        if (read == 0) throw new InvalidDataException("PNG inflated payload is truncated.");
                        offset += read;
                    }
                    if (inflater.ReadByte() != -1) throw new InvalidDataException("PNG inflated payload exceeds the exact scanline size.");
                }
            }
            catch (EndOfDeflateBodyException exception)
            {
                throw new InvalidDataException("PNG raw deflate body ended before a complete final block.", exception);
            }
            if (input.EndSentinelRaised || input.Consumed != body.Length)
                throw new InvalidDataException("PNG raw deflate body was not consumed exactly.");
            if (ComputeAdler32(output) != expectedAdler) throw new InvalidDataException("PNG Adler-32 mismatch.");
            return output;
        }

        private static byte[] Unfilter(byte[] inflated, int width, int height, int channels)
        {
            int encodedRowBytes = checked(width * channels);
            int stride = checked(encodedRowBytes + 1);
            byte[] rgba = new byte[checked(width * height * 4)];
            for (int y = 0; y < height; y++)
            {
                int rowStart = y * stride;
                int dataStart = rowStart + 1;
                int previousStart = rowStart - stride + 1;
                int filter = inflated[rowStart];
                if (filter < 0 || filter > 4) throw new InvalidDataException("PNG scanline filter is unsupported.");
                for (int index = 0; index < encodedRowBytes; index++)
                {
                    int left = index >= channels ? inflated[dataStart + index - channels] : 0;
                    int up = y > 0 ? inflated[previousStart + index] : 0;
                    int upperLeft = y > 0 && index >= channels ? inflated[previousStart + index - channels] : 0;
                    int predictor;
                    switch (filter)
                    {
                        case 0: predictor = 0; break;
                        case 1: predictor = left; break;
                        case 2: predictor = up; break;
                        case 3: predictor = (left + up) / 2; break;
                        default: predictor = Paeth(left, up, upperLeft); break;
                    }
                    inflated[dataStart + index] = (byte)((inflated[dataStart + index] + predictor) & 255);
                }
                for (int x = 0; x < width; x++)
                {
                    int sourceOffset = dataStart + x * channels;
                    int destinationOffset = (y * width + x) * 4;
                    rgba[destinationOffset] = inflated[sourceOffset];
                    rgba[destinationOffset + 1] = inflated[sourceOffset + 1];
                    rgba[destinationOffset + 2] = inflated[sourceOffset + 2];
                    rgba[destinationOffset + 3] = channels == 4 ? inflated[sourceOffset + 3] : (byte)255;
                }
            }
            return rgba;
        }

        private static int Paeth(int left, int up, int upperLeft)
        {
            int estimate = left + up - upperLeft;
            int distanceLeft = Math.Abs(estimate - left);
            int distanceUp = Math.Abs(estimate - up);
            int distanceUpperLeft = Math.Abs(estimate - upperLeft);
            if (distanceLeft <= distanceUp && distanceLeft <= distanceUpperLeft) return left;
            if (distanceUp <= distanceUpperLeft) return up;
            return upperLeft;
        }

        private static void ValidateAncillary(string type, int length, bool seenData, HashSet<string> singletons, ref bool seenIccp, ref bool seenSrgb)
        {
            bool beforeDataOnly = type == "cHRM" || type == "gAMA" || type == "iCCP" || type == "sRGB" || type == "pHYs" || type == "eXIf";
            bool singleton = beforeDataOnly || type == "tIME";
            if (beforeDataOnly && seenData) throw new InvalidDataException("PNG ancillary chunk appears after IDAT: " + type);
            if (singleton && !singletons.Add(type)) throw new InvalidDataException("PNG ancillary singleton is duplicated: " + type);
            if (type == "iCCP") { if (seenSrgb) throw new InvalidDataException("PNG iCCP and sRGB cannot coexist."); seenIccp = true; }
            if (type == "sRGB") { if (seenIccp) throw new InvalidDataException("PNG iCCP and sRGB cannot coexist."); seenSrgb = true; }
            if ((type == "cHRM" && length != 32) || (type == "gAMA" && length != 4) ||
                (type == "sRGB" && length != 1) || (type == "pHYs" && length != 9) ||
                (type == "tIME" && length != 7) || (type == "iCCP" && length < 3) ||
                (type == "eXIf" && length < 4) || (type == "tEXt" && length < 2) ||
                (type == "zTXt" && length < 3) || (type == "iTXt" && length < 6))
                throw new InvalidDataException("PNG ancillary chunk length is invalid: " + type);
        }

        private static uint ComputeAdler32(byte[] bytes)
        {
            const uint modulus = 65521;
            uint first = 1;
            uint second = 0;
            for (int index = 0; index < bytes.Length; index++)
            {
                first = (first + bytes[index]) % modulus;
                second = (second + first) % modulus;
            }
            return (second << 16) | first;
        }

        private static bool IsAsciiLetter(byte value)
        {
            return (value >= (byte)'A' && value <= (byte)'Z') || (value >= (byte)'a' && value <= (byte)'z');
        }

        private static bool IsUpperAscii(byte value)
        {
            return value >= (byte)'A' && value <= (byte)'Z';
        }

        private static uint ReadUInt32(byte[] bytes, int offset)
        {
            return ((uint)bytes[offset] << 24) | ((uint)bytes[offset + 1] << 16) |
                   ((uint)bytes[offset + 2] << 8) | bytes[offset + 3];
        }

        private static uint ComputeCrc(byte[] bytes, int offset, int count)
        {
            uint crc = 0xffffffffU;
            for (int index = 0; index < count; index++)
                crc = CrcTable[(crc ^ bytes[offset + index]) & 0xff] ^ (crc >> 8);
            return crc ^ 0xffffffffU;
        }

        private static uint[] BuildCrcTable()
        {
            uint[] table = new uint[256];
            for (uint index = 0; index < table.Length; index++)
            {
                uint value = index;
                for (int bit = 0; bit < 8; bit++) value = (value & 1) != 0 ? 0xedb88320U ^ (value >> 1) : value >> 1;
                table[index] = value;
            }
            return table;
        }
    }
}
'@
}

function Resolve-SafeLocalTexturePath([string]$Path, [string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw "$Name cannot be empty" }
    # 关键路径边界：拒绝 UNC/device/drive-relative alias，避免同一 NTFS 对象出现两套字符串 identity。
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

function Assert-NoTextureReparsePointInExistingPath([string]$Path, [string]$Name) {
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    $relative = [IO.Path]::GetRelativePath($root, $full)
    $current = $root
    if (((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
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

function Resolve-TextureSource([string]$Path) {
    $full = Resolve-SafeLocalTexturePath $Path 'Texture source'
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Texture source does not exist: $Path" }
    Assert-NoTextureReparsePointInExistingPath $full 'Texture source'
    $source = (Resolve-Path -LiteralPath $full).Path
    $file = Get-Item -LiteralPath $source
    if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Texture source cannot be a reparse point' }
    $extension = [IO.Path]::GetExtension($source).ToLowerInvariant()
    if ($extension -ne '.ppm' -and $extension -ne '.png') { throw 'Texture importer expects a .ppm or .png source' }
    return [pscustomobject]@{ Path = $source; Extension = $extension }
}

function Resolve-TextureDestination([string]$Path) {
    $destination = Resolve-SafeLocalTexturePath $Path 'Texture artifact destination'
    if ([string]::IsNullOrWhiteSpace($destination) -or $destination -eq [IO.Path]::GetPathRoot($destination)) { throw "Invalid texture destination: $Path" }
    if ([IO.Path]::GetExtension($destination).ToLowerInvariant() -ne '.texture') { throw 'Texture artifact destination must use the .texture extension' }
    # 关键不可变性边界：Importer 生成源/派生目录，禁止直接覆盖已安装 package/bin/assets。
    if ($destination -match '(?i)[\\/]bin[\\/]assets([\\/]|$)') { throw 'Texture artifact destination must not be package/bin/assets' }
    if (Test-Path -LiteralPath $destination) { throw "Refusing to overwrite existing texture artifact: $destination" }
    Assert-NoTextureReparsePointInExistingPath $destination 'Texture artifact destination'
    return $destination
}

function Parse-Ppm3([string]$Path) {
    $contents = Get-Content -LiteralPath $Path -Raw -Encoding utf8
    # P3 允许行尾注释；删除注释后只按 ASCII 数字/空白解析，避免文化区域影响。
    $withoutComments = [regex]::Replace($contents, '(?m)#.*$', '')
    $tokens = @($withoutComments -split '\s+' | Where-Object { $_.Length -gt 0 })
    if ($tokens.Count -lt 4 -or [string]$tokens[0] -cne 'P3') { throw 'Texture source must use P3 PPM format' }
    $values = [int[]]::new(3)
    for ($index = 0; $index -lt 3; $index++) {
        $number = 0
        if (-not [int]::TryParse([string]$tokens[$index + 1], [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) { throw 'PPM dimensions/range must be integers' }
        $values[$index] = $number
    }
    $width = $values[0]
    $height = $values[1]
    $maxValue = $values[2]
    if ($width -le 0 -or $height -le 0 -or $maxValue -le 0 -or $maxValue -gt 255) { throw 'PPM dimensions must be positive and max value must be in [1, 255]' }
    $pixelCount = [long]$width * [long]$height
    if ($pixelCount -gt $script:TextureArtifactMaxPixels) { throw "PPM exceeds pixel limit: $pixelCount > $script:TextureArtifactMaxPixels" }
    $expectedTokens = 4 + ($pixelCount * 3)
    if ($tokens.Count -ne $expectedTokens) { throw "PPM pixel token count mismatch: expected=$($expectedTokens - 4) actual=$($tokens.Count - 4)" }
    [byte[]]$pixels = New-Object byte[] ([int]($pixelCount * 4))
    for ($pixel = 0; $pixel -lt $pixelCount; $pixel++) {
        for ($channel = 0; $channel -lt 3; $channel++) {
            $sample = 0
            $tokenIndex = 4 + ($pixel * 3) + $channel
            if (-not [int]::TryParse([string]$tokens[$tokenIndex], [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$sample)) { throw 'PPM samples must be integers' }
            if ($sample -lt 0 -or $sample -gt $maxValue) { throw 'PPM sample is outside max value range' }
            $pixels[($pixel * 4) + $channel] = [byte][math]::Floor(($sample * 255.0) / $maxValue)
        }
        $pixels[($pixel * 4) + 3] = 255
    }
    return [pscustomobject]@{ Width = $width; Height = $height; Pixels = $pixels; SourceFormat = 'P3-PPM' }
}

function Get-TextureLevels([object]$BaseTexture, [string]$Profile) {
    $levels = [System.Collections.Generic.List[object]]::new()
    $levels.Add([pscustomobject]@{ Width = $BaseTexture.Width; Height = $BaseTexture.Height; Pixels = [byte[]]$BaseTexture.Pixels }) | Out-Null
    if ($Profile -eq 'debug') { return @($levels.ToArray()) }

    # Release profile 的确定性变换：2x2 box filter，边缘 sample clamp，整数 floor 平均。
    $source = $levels[0]
    while ($source.Width -gt 1 -or $source.Height -gt 1) {
        $nextWidth = [math]::Max(1, [int][math]::Floor($source.Width / 2.0))
        $nextHeight = [math]::Max(1, [int][math]::Floor($source.Height / 2.0))
        [byte[]]$nextPixels = New-Object byte[] ($nextWidth * $nextHeight * 4)
        for ($nextY = 0; $nextY -lt $nextHeight; $nextY++) {
            for ($nextX = 0; $nextX -lt $nextWidth; $nextX++) {
                [int]$sumR = 0; [int]$sumG = 0; [int]$sumB = 0; [int]$sumA = 0
                for ($dy = 0; $dy -lt 2; $dy++) {
                    $sampleY = [math]::Min($source.Height - 1, ($nextY * 2) + $dy)
                    for ($dx = 0; $dx -lt 2; $dx++) {
                        $sampleX = [math]::Min($source.Width - 1, ($nextX * 2) + $dx)
                        $sampleOffset = (($sampleY * $source.Width) + $sampleX) * 4
                        $sumR += $source.Pixels[$sampleOffset + 0]
                        $sumG += $source.Pixels[$sampleOffset + 1]
                        $sumB += $source.Pixels[$sampleOffset + 2]
                        $sumA += $source.Pixels[$sampleOffset + 3]
                    }
                }
                $nextOffset = (($nextY * $nextWidth) + $nextX) * 4
                $nextPixels[$nextOffset + 0] = [byte][math]::Floor($sumR / 4.0)
                $nextPixels[$nextOffset + 1] = [byte][math]::Floor($sumG / 4.0)
                $nextPixels[$nextOffset + 2] = [byte][math]::Floor($sumB / 4.0)
                $nextPixels[$nextOffset + 3] = [byte][math]::Floor($sumA / 4.0)
            }
        }
        $next = [pscustomobject]@{ Width = $nextWidth; Height = $nextHeight; Pixels = $nextPixels }
        $levels.Add($next) | Out-Null
        $source = $next
    }
    return @($levels.ToArray())
}

function Write-TextureArtifactAtomic([object]$Texture, [object[]]$Levels, [string]$Profile, [string]$Path) {
    $destinationParent = Split-Path -Parent $Path
    # 关键 ownership 边界：temp 位于同卷同目录，名称不可预测，且只能由本调用 CreateNew。
    $temporary = Join-Path $destinationParent ('.kadath-texture-{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
    $ownsTemporary = $false
    $stream = $null
    $writer = $null
    $release = $Profile -eq 'release'
    $version = if ($release) { $script:TextureArtifactVersionMipmap } else { $script:TextureArtifactVersionBase }
    $headerBytes = if ($release) { $script:TextureArtifactHeaderBytesMipmap } else { $script:TextureArtifactHeaderBytesBase }
    [long]$pixelBytes = 0
    foreach ($level in @($Levels)) { $pixelBytes += $level.Pixels.Length }
    if ($headerBytes + $pixelBytes -ge $script:TextureArtifactMaxBytes) { throw "Texture artifact must be strictly smaller than $script:TextureArtifactMaxBytes bytes: $($headerBytes + $pixelBytes)" }
    try {
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $ownsTemporary = $true
        $writer = [IO.BinaryWriter]::new($stream, [Text.Encoding]::UTF8, $true)
        $writer.Write([Text.Encoding]::ASCII.GetBytes($script:TextureArtifactMagic))
        $writer.Write([uint32]$version)
        $writer.Write([uint32]$Texture.Width)
        $writer.Write([uint32]$Texture.Height)
        if ($release) { $writer.Write([uint32]$Levels.Count) }
        $writer.Write([uint32]$pixelBytes)
        foreach ($level in @($Levels)) { $writer.Write([byte[]]$level.Pixels) }
        $writer.Flush()
        $stream.Flush($true)
        $writer.Dispose(); $writer = $null
        $stream.Dispose(); $stream = $null
        # hash 在 commit 前完成；commit 后不再需要任何可能触发回滚的文件系统操作。
        $hash = (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash.ToLowerInvariant()
        [IO.File]::Move($temporary, $Path, $false)
        return $hash
    } finally {
        if ($null -ne $writer) { $writer.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
        # 失败时只清理本调用拥有的 temp，绝不删除 destination（它可能属于竞争 winner）。
        if ($ownsTemporary -and (Test-Path -LiteralPath $temporary)) { Remove-Item -LiteralPath $temporary -Force }
    }
}

$source = Resolve-TextureSource $SourcePath
$texture = if ($source.Extension -eq '.png') {
    [Kadath.TexturePng.Decoder]::DecodeFile($source.Path)
} else {
    Parse-Ppm3 $source.Path
}
$levels = @(Get-TextureLevels $texture $Profile)
$destination = Resolve-TextureDestination $DestinationPath
$release = $Profile -eq 'release'
$artifactVersion = if ($release) { $script:TextureArtifactVersionMipmap } else { $script:TextureArtifactVersionBase }
$artifactFormat = if ($release) { 'KDAT-TEXTURE-V2-MIPMAP' } else { 'KDAT-TEXTURE-V1' }
$sourceKind = if ($source.Extension -eq '.png') { 'png' } else { 'ppm' }
$transform = if ($release) { "$sourceKind-to-rgba8-mipmap-artifact-v2" } else { "$sourceKind-to-rgba8-artifact-v1" }
$headerBytes = if ($release) { $script:TextureArtifactHeaderBytesMipmap } else { $script:TextureArtifactHeaderBytesBase }
[long]$pixelBytes = 0
foreach ($level in @($levels)) { $pixelBytes += $level.Pixels.Length }
$artifactBytes = $headerBytes + $pixelBytes
if ($artifactBytes -ge $script:TextureArtifactMaxBytes) {
    throw "Texture artifact must be strictly smaller than $script:TextureArtifactMaxBytes bytes: $artifactBytes"
}
if ($DryRun) {
    $plan = [ordered]@{
        ImporterVersion = 1
        BakerVersion = 1
        ToolVersion = 'kadath-texture-importer/3'
        Action = 'texture-import-bake'
        Profile = $Profile
        DryRun = $true
        SourceFormat = $texture.SourceFormat
        ArtifactVersion = $artifactVersion
        ArtifactFormat = $artifactFormat
        Width = $texture.Width
        Height = $texture.Height
        PixelFormat = 'RGBA8'
        MipLevelCount = $levels.Count
        MipDimensions = @($levels | ForEach-Object { "$($_.Width)x$($_.Height)" })
        Transform = $transform
        ArtifactBytes = $artifactBytes
        Destination = 'generated-assets/renderer2d/test.texture'
    }
    Write-Output ($plan | ConvertTo-Json -Depth 8 -Compress)
    exit 0
}

New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
$hash = Write-TextureArtifactAtomic $texture $levels $Profile $destination
Write-Output 'texture_importer_version=1'
Write-Output 'texture_baker_version=1'
Write-Output 'tool_version=kadath-texture-importer/3'
Write-Output "profile=$Profile"
Write-Output "source_format=$($texture.SourceFormat)"
Write-Output "artifact_version=$artifactVersion"
Write-Output "artifact_format=$artifactFormat"
Write-Output "width=$($texture.Width)"
Write-Output "height=$($texture.Height)"
Write-Output 'pixel_format=RGBA8'
Write-Output "mip_level_count=$($levels.Count)"
Write-Output "transform=$transform"
Write-Output "artifact_bytes=$artifactBytes"
Write-Output "sha256=$hash"
Write-Output "artifact=$destination"
Write-Output 'verification=ok'
