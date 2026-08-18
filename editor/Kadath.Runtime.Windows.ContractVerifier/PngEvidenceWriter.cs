using System.Buffers.Binary;
using System.IO.Compression;
using System.Text;

namespace Kadath.Runtime.Windows.ContractVerifier;

internal static class PngEvidenceWriter
{
    public static void Write(string path, PixelCapture capture)
    {
        // verifier 自己编码 PNG，不依赖 System.Drawing，也不复用产品 PNG decoder。
        var stride = checked(capture.Width * 4);
        var rows = new byte[checked(capture.Height * (stride + 1))];
        for (var y = 0; y < capture.Height; y++)
        {
            var row = y * (stride + 1);
            var source = y * stride;
            rows[row] = 0;
            for (var x = 0; x < capture.Width; x++)
            {
                var input = source + x * 4;
                var output = row + 1 + x * 4;
                rows[output] = capture.Bgra[input + 2];
                rows[output + 1] = capture.Bgra[input + 1];
                rows[output + 2] = capture.Bgra[input];
                rows[output + 3] = 255;
            }
        }

        byte[] compressed;
        using (var buffer = new MemoryStream())
        {
            using (var zlib = new ZLibStream(buffer, CompressionLevel.Optimal, leaveOpen: true)) zlib.Write(rows);
            compressed = buffer.ToArray();
        }

        using var file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        file.Write([137, 80, 78, 71, 13, 10, 26, 10]);
        Span<byte> header = stackalloc byte[13];
        BinaryPrimitives.WriteUInt32BigEndian(header[..4], (uint)capture.Width);
        BinaryPrimitives.WriteUInt32BigEndian(header[4..8], (uint)capture.Height);
        header[8] = 8;
        header[9] = 6;
        WriteChunk(file, "IHDR", header);
        WriteChunk(file, "IDAT", compressed);
        WriteChunk(file, "IEND", []);
        file.Flush(flushToDisk: true);
    }

    private static void WriteChunk(Stream output, string type, ReadOnlySpan<byte> data)
    {
        Span<byte> length = stackalloc byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(length, (uint)data.Length);
        output.Write(length);
        var typeBytes = Encoding.ASCII.GetBytes(type);
        output.Write(typeBytes);
        output.Write(data);
        Span<byte> crcBytes = stackalloc byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(crcBytes, Crc32(typeBytes, data));
        output.Write(crcBytes);
    }

    private static uint Crc32(ReadOnlySpan<byte> type, ReadOnlySpan<byte> data)
    {
        var crc = 0xffffffffu;
        foreach (var value in type) crc = CrcStep(crc, value);
        foreach (var value in data) crc = CrcStep(crc, value);
        return crc ^ 0xffffffffu;
    }

    private static uint CrcStep(uint crc, byte value)
    {
        crc ^= value;
        for (var bit = 0; bit < 8; bit++) crc = (crc & 1) != 0 ? 0xedb88320u ^ (crc >> 1) : crc >> 1;
        return crc;
    }
}
