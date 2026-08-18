using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;

namespace Kadath.Editor.Workspace;

internal sealed record WorkspaceAudioArtifact(byte[] Bytes, string Sha256, int Channels, int SampleRate, int BitsPerSample, int SampleBytes);

internal static class WorkspaceAudioCodec
{
    private const int MaxArtifactBytes = 4 * 1024 * 1024;

    internal static WorkspaceAudioArtifact EncodeSourceFile(string sourcePath)
    {
        var fullPath = Path.GetFullPath(sourcePath);
        if (!File.Exists(fullPath)) throw new FileNotFoundException("Audio source does not exist.", fullPath);
        var info = new FileInfo(fullPath);
        if ((info.Attributes & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException("Audio source cannot be a reparse point.");
        if (!info.Extension.Equals(".wav", StringComparison.OrdinalIgnoreCase) || info.Name.EndsWith(".audio.wav", StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Audio source must be a non-derived .wav file.");
        if (info.Length > MaxArtifactBytes) throw new InvalidDataException("WAV exceeds the artifact size limit.");

        var source = File.ReadAllBytes(fullPath);
        ParsedAudio parsed;
        try { parsed = Parse(source); }
        catch (OverflowException exception)
        {
            // 外部 RIFF 长度永远归一为数据错误，不能把算术实现细节泄漏为不稳定失败类型。
            throw new InvalidDataException("WAV chunk length exceeds the supported range.", exception);
        }
        var artifact = EncodeCanonical(parsed);
        return new WorkspaceAudioArtifact(
            artifact,
            Convert.ToHexString(SHA256.HashData(artifact)).ToLowerInvariant(),
            parsed.Channels,
            parsed.SampleRate,
            parsed.BitsPerSample,
            parsed.Samples.Length);
    }

    private static ParsedAudio Parse(byte[] bytes)
    {
        if (bytes.Length < 44 || !bytes.AsSpan(0, 4).SequenceEqual("RIFF"u8) || !bytes.AsSpan(8, 4).SequenceEqual("WAVE"u8))
            throw new InvalidDataException("Audio source must use RIFF/WAVE format.");
        if (ReadUInt32(bytes, 4) + 8L != bytes.Length) throw new InvalidDataException("RIFF size does not match file length.");

        ParsedFormat? format = null;
        byte[]? samples = null;
        var offset = 12;
        while (offset < bytes.Length)
        {
            if (offset > bytes.Length - 8) throw new InvalidDataException("WAV contains a truncated chunk header.");
            var chunk = Encoding.ASCII.GetString(bytes, offset, 4);
            var chunkBytes = checked((int)ReadUInt32(bytes, offset + 4));
            var payload = checked(offset + 8);
            var payloadEnd = checked(payload + chunkBytes);
            if (payloadEnd > bytes.Length) throw new InvalidDataException($"WAV chunk exceeds file length: {chunk}.");

            if (chunk == "fmt ")
            {
                if (format is not null || chunkBytes < 16) throw new InvalidDataException("WAV fmt chunk is missing, duplicated, or too short.");
                format = new ParsedFormat(
                    ReadUInt16(bytes, payload),
                    ReadUInt16(bytes, payload + 2),
                    checked((int)ReadUInt32(bytes, payload + 4)),
                    checked((int)ReadUInt32(bytes, payload + 8)),
                    ReadUInt16(bytes, payload + 12),
                    ReadUInt16(bytes, payload + 14));
            }
            else if (chunk == "data")
            {
                if (samples is not null || chunkBytes > MaxArtifactBytes) throw new InvalidDataException("WAV data chunk is duplicated or too large.");
                samples = bytes.AsSpan(payload, chunkBytes).ToArray();
            }

            offset = checked(payloadEnd + (chunkBytes & 1));
        }

        if (offset != bytes.Length || format is null || samples is null) throw new InvalidDataException("WAV requires one fmt chunk and one data chunk.");
        if (format.AudioFormat != 1 || format.Channels != 1 || format.BitsPerSample != 16)
            throw new InvalidDataException("Audio codec supports only mono 16-bit PCM WAV.");
        if (format.SampleRate is < 8000 or > 48000) throw new InvalidDataException("PCM sample rate must be in [8000, 48000] Hz.");
        var blockAlign = checked(format.Channels * (format.BitsPerSample / 8));
        var byteRate = checked(format.SampleRate * blockAlign);
        if (format.BlockAlign != blockAlign || format.ByteRate != byteRate || samples.Length == 0 || samples.Length % blockAlign != 0)
            throw new InvalidDataException("PCM byte rate, block alignment, or sample payload is invalid.");
        return new ParsedAudio(format.Channels, format.SampleRate, format.BitsPerSample, blockAlign, byteRate, samples);
    }

    private static byte[] EncodeCanonical(ParsedAudio audio)
    {
        // 固定 chunk 顺序和长度，确保构建产物不携带源文件元数据或时间信息。
        var artifact = new byte[checked(44 + audio.Samples.Length)];
        "RIFF"u8.CopyTo(artifact);
        WriteUInt32(artifact, 4, checked((uint)(artifact.Length - 8)));
        "WAVEfmt "u8.CopyTo(artifact.AsSpan(8));
        WriteUInt32(artifact, 16, 16);
        WriteUInt16(artifact, 20, 1);
        WriteUInt16(artifact, 22, checked((ushort)audio.Channels));
        WriteUInt32(artifact, 24, checked((uint)audio.SampleRate));
        WriteUInt32(artifact, 28, checked((uint)audio.ByteRate));
        WriteUInt16(artifact, 32, checked((ushort)audio.BlockAlign));
        WriteUInt16(artifact, 34, checked((ushort)audio.BitsPerSample));
        "data"u8.CopyTo(artifact.AsSpan(36));
        WriteUInt32(artifact, 40, checked((uint)audio.Samples.Length));
        audio.Samples.CopyTo(artifact, 44);
        return artifact;
    }

    private static ushort ReadUInt16(byte[] bytes, int offset) => BinaryPrimitives.ReadUInt16LittleEndian(bytes.AsSpan(offset, 2));
    private static uint ReadUInt32(byte[] bytes, int offset) => BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(offset, 4));
    private static void WriteUInt16(byte[] bytes, int offset, ushort value) => BinaryPrimitives.WriteUInt16LittleEndian(bytes.AsSpan(offset, 2), value);
    private static void WriteUInt32(byte[] bytes, int offset, uint value) => BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(offset, 4), value);
    private sealed record ParsedFormat(int AudioFormat, int Channels, int SampleRate, int ByteRate, int BlockAlign, int BitsPerSample);
    private sealed record ParsedAudio(int Channels, int SampleRate, int BitsPerSample, int BlockAlign, int ByteRate, byte[] Samples);
}
