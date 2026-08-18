using System.IO.Compression;
using System.Text;

namespace Kadath.Editor.Workspace;

internal sealed record WorkspaceTexturePixels(int Width, int Height, byte[] Pixels, string SourceFormat);

internal static class WorkspaceTexturePngCodec
{
    private const int SourceLimit = 8 * 1024 * 1024;
    private const int PixelLimit = 1024 * 1024;
    private const int DimensionLimit = 8192;
    private const int ChunkLimit = 128;
    private static readonly uint[] CrcTable = BuildCrcTable();

    internal static WorkspaceTexturePixels DecodeFile(string path, Action? afterSnapshotLength = null)
    {
        byte[] source;
        // 关键快照边界：长度和内容始终从同一个 retained handle 读取；读取完成前禁止写入和删除。
        using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 4096, FileOptions.SequentialScan))
        {
            var length = stream.Length;
            if (length <= 0 || length >= SourceLimit)
                throw new InvalidDataException("PNG source must be non-empty and strictly smaller than 8 MiB.");
            afterSnapshotLength?.Invoke();
            source = new byte[(int)length];
            var offset = 0;
            while (offset < source.Length)
            {
                var read = stream.Read(source, offset, source.Length - offset);
                if (read == 0) throw new InvalidDataException("PNG source changed or ended during snapshot read.");
                offset += read;
            }
            if (stream.ReadByte() != -1) throw new InvalidDataException("PNG source grew during snapshot read.");
        }
        return Decode(source);
    }

    private static WorkspaceTexturePixels Decode(byte[] source)
    {
        ReadOnlySpan<byte> signature = [137, 80, 78, 71, 13, 10, 26, 10];
        if (source.Length < signature.Length) throw new InvalidDataException("PNG signature is truncated.");
        if (!source.AsSpan(0, signature.Length).SequenceEqual(signature)) throw new InvalidDataException("PNG signature is invalid.");

        var offset = signature.Length;
        var chunkCount = 0;
        var seenHeader = false;
        var seenData = false;
        var dataRunEnded = false;
        var seenEnd = false;
        var seenIccp = false;
        var seenSrgb = false;
        var width = 0;
        var height = 0;
        var channels = 0;
        string? sourceFormat = null;
        long idatLength = 0;
        var idatSegments = new List<ArraySegment<byte>>();
        var singletonAncillary = new HashSet<string>(StringComparer.Ordinal);

        while (offset < source.Length)
        {
            if (source.Length - offset < 12) throw new InvalidDataException("PNG chunk is truncated.");
            var lengthValue = ReadUInt32(source, offset);
            if (lengthValue > int.MaxValue) throw new InvalidDataException("PNG chunk length is unsupported.");
            var length = (int)lengthValue;
            var typeOffset = offset + 4;
            var dataOffset = offset + 8;
            var nextOffsetLong = (long)dataOffset + length + 4;
            if (nextOffsetLong > source.Length) throw new InvalidDataException("PNG chunk exceeds the source snapshot.");
            var nextOffset = (int)nextOffsetLong;
            chunkCount++;
            if (chunkCount > ChunkLimit) throw new InvalidDataException("PNG exceeds the 128 chunk limit.");

            for (var index = 0; index < 4; index++)
            {
                var value = source[typeOffset + index];
                if (!IsAsciiLetter(value)) throw new InvalidDataException("PNG chunk type must contain only ASCII letters.");
            }
            if (!IsUpperAscii(source[typeOffset + 2])) throw new InvalidDataException("PNG chunk reserved bit must be uppercase.");
            var type = Encoding.ASCII.GetString(source, typeOffset, 4);
            var expectedCrc = ReadUInt32(source, dataOffset + length);
            var actualCrc = ComputeCrc(source, typeOffset, 4 + length);
            if (actualCrc != expectedCrc) throw new InvalidDataException("PNG chunk CRC mismatch: " + type);

            if (!seenHeader && type != "IHDR") throw new InvalidDataException("IHDR must be the first PNG chunk.");
            if (type == "IHDR")
            {
                if (seenHeader || chunkCount != 1 || length != 13) throw new InvalidDataException("PNG must contain one 13-byte IHDR first.");
                var widthValue = ReadUInt32(source, dataOffset);
                var heightValue = ReadUInt32(source, dataOffset + 4);
                if (widthValue == 0 || heightValue == 0 || widthValue > DimensionLimit || heightValue > DimensionLimit)
                    throw new InvalidDataException("PNG dimensions must be in [1, 8192].");
                var pixels = (long)widthValue * heightValue;
                if (pixels > PixelLimit) throw new InvalidDataException("PNG exceeds the pixel limit.");
                var bitDepth = source[dataOffset + 8];
                var colorType = source[dataOffset + 9];
                if (bitDepth != 8 || colorType is not (2 or 6))
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
                if (type is "PLTE" or "tRNS") throw new InvalidDataException("PNG palette/transparency chunks are unsupported.");
                if (type is "acTL" or "fcTL" or "fdAT") throw new InvalidDataException("APNG chunks are unsupported.");
                var ancillary = (source[typeOffset] & 0x20) != 0;
                if (!ancillary) throw new InvalidDataException("Unknown critical PNG chunk: " + type);
                ValidateAncillary(type, length, seenData, singletonAncillary, ref seenIccp, ref seenSrgb);
            }

            offset = nextOffset;
            if (seenEnd) break;
        }

        if (!seenHeader || !seenData || !seenEnd || offset != source.Length)
            throw new InvalidDataException("PNG is missing required IHDR, IDAT, or IEND chunks.");
        if (idatLength > int.MaxValue) throw new InvalidDataException("PNG compressed payload is too large.");
        var zlib = new byte[(int)idatLength];
        var zlibOffset = 0;
        foreach (var segment in idatSegments)
        {
            Buffer.BlockCopy(segment.Array!, segment.Offset, zlib, zlibOffset, segment.Count);
            zlibOffset += segment.Count;
        }

        var rowBytesLong = checked((long)width * channels);
        var expectedInflatedLong = checked((long)height * (1L + rowBytesLong));
        var rgbaBytesLong = checked((long)width * height * 4L);
        if (rgbaBytesLong > 4L * 1024 * 1024 || expectedInflatedLong > int.MaxValue)
            throw new InvalidDataException("PNG decoded payload exceeds the RGBA8 budget.");
        var inflated = InflateZlibExact(zlib, (int)expectedInflatedLong);
        var rgba = Unfilter(inflated, width, height, channels);
        return new WorkspaceTexturePixels(width, height, rgba, sourceFormat!);
    }

    private static byte[] InflateZlibExact(byte[] zlib, int expectedLength)
    {
        if (zlib.Length < 7) throw new InvalidDataException("PNG zlib stream is truncated.");
        var cmf = zlib[0];
        var flg = zlib[1];
        if ((cmf & 15) != 8 || (cmf >> 4) > 7 || (((cmf << 8) | flg) % 31) != 0 || (flg & 32) != 0)
            throw new InvalidDataException("PNG zlib header is invalid or uses FDICT.");

        var bodyLength = zlib.Length - 6;
        if (bodyLength <= 0) throw new InvalidDataException("PNG raw deflate body is missing.");
        var body = new byte[bodyLength];
        Buffer.BlockCopy(zlib, 2, body, 0, bodyLength);
        var expectedAdler = ReadUInt32(zlib, zlib.Length - 4);
        var output = new byte[expectedLength];
        var input = new OneByteInputStream(body);
        try
        {
            using var inflater = new DeflateStream(input, CompressionMode.Decompress, true);
            var offset = 0;
            while (offset < output.Length)
            {
                var read = inflater.Read(output, offset, output.Length - offset);
                if (read == 0) throw new InvalidDataException("PNG inflated payload is truncated.");
                offset += read;
            }
            if (inflater.ReadByte() != -1) throw new InvalidDataException("PNG inflated payload exceeds the exact scanline size.");
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
        var encodedRowBytes = checked(width * channels);
        var stride = checked(encodedRowBytes + 1);
        var rgba = new byte[checked(width * height * 4)];
        for (var y = 0; y < height; y++)
        {
            var rowStart = y * stride;
            var dataStart = rowStart + 1;
            var previousStart = rowStart - stride + 1;
            var filter = inflated[rowStart];
            if (filter > 4) throw new InvalidDataException("PNG scanline filter is unsupported.");
            for (var index = 0; index < encodedRowBytes; index++)
            {
                var left = index >= channels ? inflated[dataStart + index - channels] : 0;
                var up = y > 0 ? inflated[previousStart + index] : 0;
                var upperLeft = y > 0 && index >= channels ? inflated[previousStart + index - channels] : 0;
                var predictor = filter switch
                {
                    0 => 0,
                    1 => left,
                    2 => up,
                    3 => (left + up) / 2,
                    _ => Paeth(left, up, upperLeft)
                };
                inflated[dataStart + index] = unchecked((byte)(inflated[dataStart + index] + predictor));
            }
            for (var x = 0; x < width; x++)
            {
                var sourceOffset = dataStart + x * channels;
                var destinationOffset = (y * width + x) * 4;
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
        var estimate = left + up - upperLeft;
        var distanceLeft = Math.Abs(estimate - left);
        var distanceUp = Math.Abs(estimate - up);
        var distanceUpperLeft = Math.Abs(estimate - upperLeft);
        if (distanceLeft <= distanceUp && distanceLeft <= distanceUpperLeft) return left;
        return distanceUp <= distanceUpperLeft ? up : upperLeft;
    }

    private static void ValidateAncillary(
        string type,
        int length,
        bool seenData,
        HashSet<string> singletons,
        ref bool seenIccp,
        ref bool seenSrgb)
    {
        var beforeDataOnly = type is "cHRM" or "gAMA" or "iCCP" or "sRGB" or "pHYs" or "eXIf";
        var singleton = beforeDataOnly || type == "tIME";
        if (beforeDataOnly && seenData) throw new InvalidDataException("PNG ancillary chunk appears after IDAT: " + type);
        if (singleton && !singletons.Add(type)) throw new InvalidDataException("PNG ancillary singleton is duplicated: " + type);
        if (type == "iCCP")
        {
            if (seenSrgb) throw new InvalidDataException("PNG iCCP and sRGB cannot coexist.");
            seenIccp = true;
        }
        if (type == "sRGB")
        {
            if (seenIccp) throw new InvalidDataException("PNG iCCP and sRGB cannot coexist.");
            seenSrgb = true;
        }
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
        foreach (var value in bytes)
        {
            first = (first + value) % modulus;
            second = (second + first) % modulus;
        }
        return (second << 16) | first;
    }

    private static bool IsAsciiLetter(byte value) =>
        value is >= (byte)'A' and <= (byte)'Z' or >= (byte)'a' and <= (byte)'z';

    private static bool IsUpperAscii(byte value) => value is >= (byte)'A' and <= (byte)'Z';

    private static uint ReadUInt32(byte[] bytes, int offset) =>
        ((uint)bytes[offset] << 24) | ((uint)bytes[offset + 1] << 16) |
        ((uint)bytes[offset + 2] << 8) | bytes[offset + 3];

    private static uint ComputeCrc(byte[] bytes, int offset, int count)
    {
        uint crc = 0xffffffff;
        for (var index = 0; index < count; index++) crc = CrcTable[(crc ^ bytes[offset + index]) & 0xff] ^ (crc >> 8);
        return crc ^ 0xffffffff;
    }

    private static uint[] BuildCrcTable()
    {
        var table = new uint[256];
        for (uint index = 0; index < table.Length; index++)
        {
            var value = index;
            for (var bit = 0; bit < 8; bit++) value = (value & 1) != 0 ? 0xedb88320 ^ (value >> 1) : value >> 1;
            table[index] = value;
        }
        return table;
    }

    private sealed class EndOfDeflateBodyException : IOException
    {
        internal EndOfDeflateBodyException() : base("Deflate decoder read beyond the declared raw body.") { }
    }

    private sealed class OneByteInputStream(byte[] bytes) : Stream
    {
        private int _offset;

        internal int Consumed => _offset;
        internal bool EndSentinelRaised { get; private set; }
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => _offset; set => throw new NotSupportedException(); }

        public override int Read(byte[] buffer, int bufferOffset, int count)
        {
            if (count == 0) return 0;
            if (_offset >= bytes.Length)
            {
                EndSentinelRaised = true;
                throw new EndOfDeflateBodyException();
            }
            buffer[bufferOffset] = bytes[_offset++];
            return 1;
        }

        public override int ReadByte()
        {
            if (_offset >= bytes.Length)
            {
                EndSentinelRaised = true;
                throw new EndOfDeflateBodyException();
            }
            return bytes[_offset++];
        }

        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}
