using System.Buffers.Binary;
using System.Text;
using Kadath.Editor.Toolchain;

namespace Kadath.Editor.Toolchain.ContractVerifier;

internal static class AudioImportContract
{
    private const int MaximumArtifactBytes = 4 * 1024 * 1024;
    private const string ExpectedCanonicalSha256 = "7c44ffdcfa390c37bbe014bb9473d572dad575ec6aa03941c071172ca63095b0";
    private static readonly byte[] Samples = [0x00, 0x00, 0xff, 0x7f, 0x00, 0x80, 0x34, 0x12];
    private static readonly byte[] ExpectedCanonical = Convert.FromHexString(
        "524946462c00000057415645666d742010000000010001002256000044ac00000200100064617461080000000000ff7f00803412");

    internal static void Verify(ContractSandbox sandbox)
    {
        VerifyOverflowFailureIsNormalized(sandbox.NewCase("audio-chunk-overflow"));
        VerifyCanonicalMetadataAndOrdering(sandbox.NewCase("audio-canonical"));
        VerifyChunkCardinality(sandbox.NewCase("audio-chunks"));
        VerifyLengthAndPaddingFailures(sandbox.NewCase("audio-lengths"));
        VerifyPcmConstraints(sandbox.NewCase("audio-pcm"));
        VerifyBudgetAndSourceKind(sandbox.NewCase("audio-budget"));
        VerifyPublisherFailureBoundaries(sandbox.NewCase("audio-publisher"));
    }

    private static void VerifyOverflowFailureIsNormalized(string root)
    {
        var source = Path.Combine(root, "overflow.wav");
        var destination = Path.Combine(root, "overflow.audio.wav");
        var bytes = new byte[44];
        "RIFF"u8.CopyTo(bytes);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(4, 4), 36);
        "WAVEJUNK"u8.CopyTo(bytes.AsSpan(8));
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(16, 4), uint.MaxValue);
        File.WriteAllBytes(source, bytes);

        _ = ContractAssert.Throws<InvalidDataException>(() => ToolchainImport.Execute(
            new ToolchainImportRequest("audio", source, destination, "debug")));
        ContractAssert.Require(!File.Exists(destination),
            "overflowing WAV chunk length advanced an audio artifact");
    }

    private static void VerifyCanonicalMetadataAndOrdering(string root)
    {
        var format = FormatChunk();
        var metadataSource = BuildWave(
            new WaveChunk("JUNK", [0x41, 0x42, 0x43], Padding: 0xa5),
            new WaveChunk("fmt ", format),
            new WaveChunk("LIST", [1, 2, 3, 4, 5], Padding: 0x7f),
            new WaveChunk("data", Samples),
            new WaveChunk("INFO", [9, 8]));
        var reorderedSource = BuildWave(
            new WaveChunk("data", Samples),
            new WaveChunk("JUNK", [0x6b], Padding: 0x55),
            new WaveChunk("fmt ", format));
        var canonicalSource = BuildWave(new WaveChunk("fmt ", format), new WaveChunk("data", Samples));

        foreach (var (name, source, profile) in new[]
                 {
                     ("metadata-debug", metadataSource, "debug"),
                     ("metadata-release", metadataSource, "release"),
                     ("reordered-release", reorderedSource, "release"),
                     ("canonical-release", canonicalSource, "release")
                 })
        {
            var sourcePath = Path.Combine(root, $"{name}.wav");
            var destination = Path.Combine(root, "out", $"{name}.audio.wav");
            File.WriteAllBytes(sourcePath, source);
            var sourceHash = ContractAssert.Sha256(sourcePath);
            var result = ToolchainImport.Execute(new ToolchainImportRequest("audio", sourcePath, destination, profile));
            ContractAssert.Require(File.ReadAllBytes(destination).AsSpan().SequenceEqual(ExpectedCanonical),
                $"{name} did not produce the fixed canonical WAV bytes");
            ContractAssert.Require(result.Sha256 == ExpectedCanonicalSha256 && result.ArtifactBytes == ExpectedCanonical.Length,
                $"{name} canonical identity mismatch");
            ContractAssert.Require(ContractAssert.Sha256(sourcePath) == sourceHash,
                $"{name} audio source changed during import");
        }
    }

    private static void VerifyChunkCardinality(string root)
    {
        var format = new WaveChunk("fmt ", FormatChunk());
        var data = new WaveChunk("data", Samples);
        AssertRejected(root, "duplicate-fmt", BuildWave(format, format, data));
        AssertRejected(root, "duplicate-data", BuildWave(format, data, data));
        AssertRejected(root, "missing-fmt", BuildWave(data));
        AssertRejected(root, "missing-data", BuildWave(format));
        AssertRejected(root, "short-fmt", BuildWave(new WaveChunk("fmt ", new byte[15]), data));
    }

    private static void VerifyLengthAndPaddingFailures(string root)
    {
        var canonical = BuildWave(new WaveChunk("fmt ", FormatChunk()), new WaveChunk("data", Samples));
        var badRiffSize = canonical.ToArray();
        BinaryPrimitives.WriteUInt32LittleEndian(badRiffSize.AsSpan(4, 4), checked((uint)(canonical.Length - 9)));
        AssertRejected(root, "riff-size", badRiffSize);

        var truncatedPayload = canonical.ToArray();
        BinaryPrimitives.WriteUInt32LittleEndian(truncatedPayload.AsSpan(40, 4), checked((uint)(Samples.Length + 2)));
        AssertRejected(root, "truncated-payload", truncatedPayload);

        var trailingHeader = new byte[canonical.Length + 4];
        canonical.CopyTo(trailingHeader, 0);
        BinaryPrimitives.WriteUInt32LittleEndian(trailingHeader.AsSpan(4, 4), checked((uint)(trailingHeader.Length - 8)));
        AssertRejected(root, "truncated-header", trailingHeader);

        var missingOddPadding = BuildWave(
            new WaveChunk("JUNK", [1, 2, 3], IncludePadding: false),
            new WaveChunk("fmt ", FormatChunk()),
            new WaveChunk("data", Samples));
        AssertRejected(root, "missing-odd-padding", missingOddPadding);
    }

    private static void VerifyPcmConstraints(string root)
    {
        AssertPcmRejected(root, "float-format", FormatChunk(audioFormat: 3), Samples);
        AssertPcmRejected(root, "stereo", FormatChunk(channels: 2), Samples);
        AssertPcmRejected(root, "eight-bit", FormatChunk(bitsPerSample: 8), Samples);
        AssertPcmRejected(root, "rate-low", FormatChunk(sampleRate: 7_999), Samples);
        AssertPcmRejected(root, "rate-high", FormatChunk(sampleRate: 48_001), Samples);
        AssertPcmRejected(root, "byte-rate", FormatChunk(byteRate: 1), Samples);
        AssertPcmRejected(root, "block-align", FormatChunk(blockAlign: 4), Samples);
        AssertPcmRejected(root, "empty-data", FormatChunk(), []);
        AssertPcmRejected(root, "unaligned-data", FormatChunk(), [0x01]);
    }

    private static void VerifyBudgetAndSourceKind(string root)
    {
        var oversized = Path.Combine(root, "oversized.wav");
        var destination = Path.Combine(root, "oversized.audio.wav");
        File.WriteAllBytes(oversized, new byte[MaximumArtifactBytes + 1]);
        _ = ContractAssert.Throws<InvalidDataException>(() => ToolchainImport.Execute(
            new ToolchainImportRequest("audio", oversized, destination, "release")), "size limit");
        ContractAssert.Require(!File.Exists(destination), "oversized audio source advanced an artifact");

        var derived = Path.Combine(root, "derived.audio.wav");
        File.WriteAllBytes(derived, ExpectedCanonical);
        _ = ContractAssert.Throws<InvalidDataException>(() => ToolchainImport.Execute(
            new ToolchainImportRequest("audio", derived, Path.Combine(root, "derived.out"), "debug")), "non-derived");
    }

    private static void VerifyPublisherFailureBoundaries(string root)
    {
        var source = Path.Combine(root, "source.wav");
        File.WriteAllBytes(source, ExpectedCanonical);

        var existing = Path.Combine(root, "existing.audio.wav");
        var sentinel = "existing audio artifact"u8.ToArray();
        File.WriteAllBytes(existing, sentinel);
        _ = ContractAssert.Throws<IOException>(() => ToolchainImport.Execute(
            new ToolchainImportRequest("audio", source, existing, "release")), "overwrite");
        ContractAssert.Require(File.ReadAllBytes(existing).AsSpan().SequenceEqual(sentinel),
            "audio no-replace failure changed the existing artifact");

        var failed = Path.Combine(root, "out", "failed.audio.wav");
        _ = ContractAssert.Throws<InvalidOperationException>(() => ToolchainImport.Execute(
            new ToolchainImportRequest(
                "audio",
                source,
                failed,
                "debug",
                _ => throw new InvalidOperationException("Injected audio publisher failure."))),
            "Injected audio publisher failure");
        ContractAssert.Require(!File.Exists(failed), "audio publisher failure advanced an artifact");
        ContractAssert.Require(!Directory.EnumerateFiles(root, ".*.tmp", SearchOption.AllDirectories).Any(),
            "audio publisher failure left an owned temporary file");
    }

    private static void AssertPcmRejected(string root, string name, byte[] format, byte[] samples) =>
        AssertRejected(root, name, BuildWave(new WaveChunk("fmt ", format), new WaveChunk("data", samples)));

    private static void AssertRejected(string root, string name, byte[] sourceBytes)
    {
        var source = Path.Combine(root, $"{name}.wav");
        var destination = Path.Combine(root, "invalid", $"{name}.audio.wav");
        File.WriteAllBytes(source, sourceBytes);
        _ = ContractAssert.Throws<InvalidDataException>(() => ToolchainImport.Execute(
            new ToolchainImportRequest("audio", source, destination, "debug")));
        ContractAssert.Require(!File.Exists(destination), $"{name} invalid WAV advanced an artifact");
    }

    private static byte[] FormatChunk(
        ushort audioFormat = 1,
        ushort channels = 1,
        uint sampleRate = 22_050,
        uint? byteRate = null,
        ushort? blockAlign = null,
        ushort bitsPerSample = 16)
    {
        var bytes = new byte[16];
        var calculatedBlockAlign = checked((ushort)(channels * (bitsPerSample / 8)));
        BinaryPrimitives.WriteUInt16LittleEndian(bytes.AsSpan(0, 2), audioFormat);
        BinaryPrimitives.WriteUInt16LittleEndian(bytes.AsSpan(2, 2), channels);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(4, 4), sampleRate);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(8, 4), byteRate ?? checked(sampleRate * calculatedBlockAlign));
        BinaryPrimitives.WriteUInt16LittleEndian(bytes.AsSpan(12, 2), blockAlign ?? calculatedBlockAlign);
        BinaryPrimitives.WriteUInt16LittleEndian(bytes.AsSpan(14, 2), bitsPerSample);
        return bytes;
    }

    private static byte[] BuildWave(params WaveChunk[] chunks)
    {
        using var memory = new MemoryStream();
        using (var writer = new BinaryWriter(memory, Encoding.ASCII, leaveOpen: true))
        {
            writer.Write("RIFF"u8);
            writer.Write(0u);
            writer.Write("WAVE"u8);
            foreach (var chunk in chunks)
            {
                if (chunk.Id.Length != 4 || chunk.Id.Any(character => character > 0x7f))
                    throw new InvalidOperationException($"Invalid verifier chunk ID: {chunk.Id}");
                writer.Write(Encoding.ASCII.GetBytes(chunk.Id));
                writer.Write(checked((uint)chunk.Payload.Length));
                writer.Write(chunk.Payload);
                if ((chunk.Payload.Length & 1) != 0 && chunk.IncludePadding) writer.Write(chunk.Padding);
            }
        }
        var bytes = memory.ToArray();
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(4, 4), checked((uint)(bytes.Length - 8)));
        return bytes;
    }

    private sealed record WaveChunk(string Id, byte[] Payload, bool IncludePadding = true, byte Padding = 0);
}
