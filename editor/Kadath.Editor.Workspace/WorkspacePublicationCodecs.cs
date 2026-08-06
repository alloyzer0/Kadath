using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Kadath.Editor.Workspace;

internal sealed record WorkspaceArtifactInfo(string Sha256, long Bytes, string Format, int ImporterVersion, int BakerVersion);

internal static class WorkspaceSceneCodec
{
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    internal const string Format = "KSCN-SCENE-V4";
    internal const int ImporterVersion = 4;
    internal const int BakerVersion = 4;
    private const int HeaderBytes = 16;
    private const int MaxArtifactBytes = 1024 * 1024;

    internal static byte[] EncodeSource(byte[] source)
    {
        var scene = WorkspaceSceneDocumentCodec.Parse(source);
        var textures = scene.Textures.Select(value => new TextureEntry(value.TextureId, StrictUtf8.GetBytes(value.Artifact))).ToArray();
        var objects = scene.Objects.Select(value => new ObjectEntry(value, StrictUtf8.GetBytes(value.ObjectId))).ToArray();
        var payloadBytes = sizeof(uint)
            + textures.Sum(value => 2 * sizeof(uint) + value.Artifact.Length)
            + sizeof(uint)
            + objects.Sum(value => sizeof(uint) + value.EntryBytes);
        var artifact = new byte[HeaderBytes + payloadBytes];
        Encoding.ASCII.GetBytes("KSCN").CopyTo(artifact, 0);
        WriteUInt32(artifact, 4, 4);
        WriteUInt32(artifact, 8, 4);
        WriteUInt32(artifact, 12, checked((uint)payloadBytes));
        var offset = HeaderBytes;
        WriteUInt32(artifact, offset, checked((uint)textures.Length));
        offset += sizeof(uint);
        foreach (var texture in textures)
        {
            WriteUInt32(artifact, offset, texture.TextureId);
            WriteUInt32(artifact, offset + sizeof(uint), checked((uint)texture.Artifact.Length));
            offset += 2 * sizeof(uint);
            texture.Artifact.CopyTo(artifact, offset);
            offset += texture.Artifact.Length;
        }
        WriteUInt32(artifact, offset, checked((uint)objects.Length));
        offset += sizeof(uint);
        foreach (var entry in objects)
        {
            WriteUInt32(artifact, offset, checked((uint)entry.EntryBytes));
            WriteUInt32(artifact, offset + 4, KindValue(entry.Value.Kind));
            WriteUInt32(artifact, offset + 8, checked((uint)entry.ObjectId.Length));
            offset += 12;
            entry.ObjectId.CopyTo(artifact, offset);
            offset += entry.ObjectId.Length;
            foreach (var value in entry.Value.Position.Concat(entry.Value.Size).Concat(entry.Value.Color))
            {
                WriteSingle(artifact, offset, (float)value);
                offset += sizeof(float);
            }
            WriteUInt32(artifact, offset, entry.Value.TextureId);
            offset += sizeof(uint);
            if (entry.Value.Kind == WorkspaceSceneDocumentCodec.PlayerKind)
            {
                WriteSingle(artifact, offset, (float)entry.Value.MoveSpeed!.Value);
                offset += sizeof(float);
            }
            else if (entry.Value.Kind == WorkspaceSceneDocumentCodec.PatrolHazardKind)
            {
                WriteSingle(artifact, offset, (float)entry.Value.PatrolMinY!.Value);
                WriteSingle(artifact, offset + 4, (float)entry.Value.PatrolMaxY!.Value);
                WriteSingle(artifact, offset + 8, (float)entry.Value.PatrolSpeed!.Value);
                offset += 12;
            }
        }
        if (offset != artifact.Length) throw new InvalidOperationException("Internal KSCN length mismatch.");
        _ = ValidateArtifact(artifact);
        return artifact;
    }

    internal static WorkspaceArtifactInfo ValidateArtifact(byte[] artifact)
    {
        if (artifact.Length is < HeaderBytes or > MaxArtifactBytes || Encoding.ASCII.GetString(artifact, 0, 4) != "KSCN")
            throw new InvalidDataException("Scene artifact layout mismatch.");
        if (ReadUInt32(artifact, 4) != 4 || ReadUInt32(artifact, 8) != 4 || ReadUInt32(artifact, 12) != artifact.Length - HeaderBytes)
            throw new InvalidDataException("Scene artifact header mismatch.");
        var offset = HeaderBytes;
        var textureCount = ReadRequiredUInt32(artifact, ref offset);
        if (textureCount is < 1 or > 4) throw new InvalidDataException("Scene artifact texture count mismatch.");
        var textures = new List<WorkspaceSceneTexture>();
        for (var index = 0; index < textureCount; index++)
        {
            var textureId = ReadRequiredUInt32(artifact, ref offset);
            var pathBytes = ReadRequiredUInt32(artifact, ref offset);
            var path = DecodeStrictUtf8(ReadRequiredBytes(artifact, ref offset, pathBytes));
            textures.Add(new WorkspaceSceneTexture(textureId, path));
        }
        var objectCount = ReadRequiredUInt32(artifact, ref offset);
        if (objectCount is < WorkspaceSceneDocumentCodec.MinObjectCount or > WorkspaceSceneDocumentCodec.MaxObjectCount)
            throw new InvalidDataException("Scene artifact object count mismatch.");
        var objects = new List<WorkspaceSceneObject>();
        for (var index = 0; index < objectCount; index++)
        {
            var entryBytes = ReadRequiredUInt32(artifact, ref offset);
            if (entryBytes > int.MaxValue || entryBytes > artifact.Length - offset)
                throw new InvalidDataException("Scene artifact object entry is truncated.");
            var entryEnd = offset + (int)entryBytes;
            var kind = KindName(ReadRequiredUInt32(artifact, ref offset));
            var objectIdBytes = ReadRequiredUInt32(artifact, ref offset);
            var objectId = DecodeStrictUtf8(ReadRequiredBytes(artifact, ref offset, objectIdBytes));
            var position = ReadVector(artifact, ref offset, 2);
            var size = ReadVector(artifact, ref offset, 2);
            var color = ReadVector(artifact, ref offset, 4);
            var textureId = ReadRequiredUInt32(artifact, ref offset);
            double? moveSpeed = null;
            double? patrolMinY = null;
            double? patrolMaxY = null;
            double? patrolSpeed = null;
            if (kind == WorkspaceSceneDocumentCodec.PlayerKind)
            {
                moveSpeed = ReadRequiredSingle(artifact, ref offset);
            }
            else if (kind == WorkspaceSceneDocumentCodec.PatrolHazardKind)
            {
                patrolMinY = ReadRequiredSingle(artifact, ref offset);
                patrolMaxY = ReadRequiredSingle(artifact, ref offset);
                patrolSpeed = ReadRequiredSingle(artifact, ref offset);
            }
            if (offset != entryEnd) throw new InvalidDataException("Scene artifact object entry length mismatch.");
            objects.Add(new WorkspaceSceneObject(objectId, kind, position, size, color, textureId, moveSpeed, patrolMinY, patrolMaxY, patrolSpeed));
        }
        if (offset != artifact.Length) throw new InvalidDataException("Scene artifact contains trailing bytes.");
        try { WorkspaceSceneDocumentCodec.ValidateNormalized(textures, objects); }
        catch (WorkspaceProjectValidationException exception) { throw new InvalidDataException(exception.Message, exception); }
        return new WorkspaceArtifactInfo(Convert.ToHexString(SHA256.HashData(artifact)).ToLowerInvariant(), artifact.LongLength, Format, ImporterVersion, BakerVersion);
    }

    private static uint KindValue(string kind) => kind switch
    {
        WorkspaceSceneDocumentCodec.SpriteKind => 1,
        WorkspaceSceneDocumentCodec.PlayerKind => 2,
        WorkspaceSceneDocumentCodec.GoalKind => 3,
        WorkspaceSceneDocumentCodec.PatrolHazardKind => 4,
        _ => throw new InvalidOperationException($"Unsupported Scene object kind: {kind}.")
    };

    private static string KindName(uint kind) => kind switch
    {
        1 => WorkspaceSceneDocumentCodec.SpriteKind,
        2 => WorkspaceSceneDocumentCodec.PlayerKind,
        3 => WorkspaceSceneDocumentCodec.GoalKind,
        4 => WorkspaceSceneDocumentCodec.PatrolHazardKind,
        _ => throw new InvalidDataException($"Scene artifact contains unsupported object kind: {kind}.")
    };

    private static uint ReadRequiredUInt32(byte[] bytes, ref int offset)
    {
        if (offset > bytes.Length - sizeof(uint)) throw new InvalidDataException("Scene artifact is truncated.");
        var value = ReadUInt32(bytes, offset);
        offset += sizeof(uint);
        return value;
    }

    private static float ReadRequiredSingle(byte[] bytes, ref int offset)
    {
        if (offset > bytes.Length - sizeof(float)) throw new InvalidDataException("Scene artifact is truncated.");
        var value = ReadSingle(bytes, offset);
        offset += sizeof(float);
        if (!float.IsFinite(value)) throw new InvalidDataException("Scene artifact contains a non-finite value.");
        return value;
    }

    private static double[] ReadVector(byte[] bytes, ref int offset, int count)
    {
        var values = new double[count];
        for (var index = 0; index < count; index++) values[index] = ReadRequiredSingle(bytes, ref offset);
        return values;
    }

    private static ReadOnlySpan<byte> ReadRequiredBytes(byte[] bytes, ref int offset, uint count)
    {
        if (count > int.MaxValue) throw new InvalidDataException("Scene artifact is truncated.");
        var length = (int)count;
        if (offset > bytes.Length - length) throw new InvalidDataException("Scene artifact is truncated.");
        var value = bytes.AsSpan(offset, length);
        offset += length;
        return value;
    }

    private static string DecodeStrictUtf8(ReadOnlySpan<byte> bytes)
    {
        try { return StrictUtf8.GetString(bytes); }
        catch (DecoderFallbackException exception) { throw new InvalidDataException("Scene artifact contains invalid UTF-8.", exception); }
    }

    private static uint ReadUInt32(byte[] bytes, int offset) => BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(offset, 4));
    private static float ReadSingle(byte[] bytes, int offset) => BitConverter.Int32BitsToSingle(BinaryPrimitives.ReadInt32LittleEndian(bytes.AsSpan(offset, 4)));
    private static void WriteUInt32(byte[] bytes, int offset, uint value) => BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(offset, 4), value);
    private static void WriteSingle(byte[] bytes, int offset, float value) => BinaryPrimitives.WriteInt32LittleEndian(bytes.AsSpan(offset, 4), BitConverter.SingleToInt32Bits(value));
    private sealed record TextureEntry(uint TextureId, byte[] Artifact);
    private sealed record ObjectEntry(WorkspaceSceneObject Value, byte[] ObjectId)
    {
        internal int EntryBytes => 44 + ObjectId.Length + (Value.Kind switch
        {
            WorkspaceSceneDocumentCodec.PlayerKind => 4,
            WorkspaceSceneDocumentCodec.PatrolHazardKind => 12,
            _ => 0
        });
    }
}

internal static class WorkspaceScriptCodec
{
    internal const string Format = "KSCP-SCRIPT-V1";
    internal const int ImporterVersion = 1;
    internal const int BakerVersion = 1;

    internal static byte[] EncodeSource(byte[] source)
    {
        WorkspaceProjectValidator.ValidateScriptSource(source);
        using var document = Parse(source);
        var instructions = document.RootElement.GetProperty("instructions").EnumerateArray().Select(value =>
        {
            var hook = value.GetProperty("hook").GetString() == "on_start" ? 0u : 1u;
            var operation = value.GetProperty("op").GetString() == "set_goal_position" ? 0u : 1u;
            var vector = value.GetProperty("value").EnumerateArray().Select(item => (float)item.GetDouble()).ToArray();
            return new Instruction(hook, operation, vector[0], vector[1]);
        }).ToArray();
        var artifact = new byte[16 + instructions.Length * 16];
        Encoding.ASCII.GetBytes("KSCP").CopyTo(artifact, 0);
        WriteUInt32(artifact, 4, 1);
        WriteUInt32(artifact, 8, 1);
        WriteUInt32(artifact, 12, checked((uint)instructions.Length));
        var offset = 16;
        foreach (var instruction in instructions)
        {
            WriteUInt32(artifact, offset, instruction.Hook);
            WriteUInt32(artifact, offset + 4, instruction.Operation);
            WriteSingle(artifact, offset + 8, instruction.X);
            WriteSingle(artifact, offset + 12, instruction.Y);
            offset += 16;
        }
        _ = ValidateArtifact(artifact);
        return artifact;
    }

    internal static WorkspaceArtifactInfo ValidateArtifact(byte[] artifact)
    {
        if (artifact.Length < 16 || Encoding.ASCII.GetString(artifact, 0, 4) != "KSCP") throw new InvalidDataException("Script artifact layout mismatch.");
        var count = ReadUInt32(artifact, 12);
        if (ReadUInt32(artifact, 4) != 1 || ReadUInt32(artifact, 8) != 1 || count > 16 || artifact.Length != 16 + count * 16)
            throw new InvalidDataException("Script artifact header mismatch.");
        var editableOnStart = 0;
        var editableFixedUpdate = 0;
        for (var index = 0; index < count; index++)
        {
            var offset = 16 + index * 16;
            var hook = ReadUInt32(artifact, offset);
            var operation = ReadUInt32(artifact, offset + 4);
            var x = ReadSingle(artifact, offset + 8);
            var y = ReadSingle(artifact, offset + 12);
            if (!float.IsFinite(x) || !float.IsFinite(y)) throw new InvalidDataException("Script artifact contains a non-finite value.");
            if (hook == 0 && operation == 0) editableOnStart++;
            else if (hook == 1 && operation == 1)
            {
                if (Math.Abs(x) > 1000 || Math.Abs(y) > 1000) throw new InvalidDataException("Script artifact velocity exceeds the limit.");
                editableFixedUpdate++;
            }
            else throw new InvalidDataException("Script artifact contains an unsupported hook/op pair.");
        }
        if (editableOnStart != 1 || editableFixedUpdate != 1) throw new InvalidDataException("Script artifact editable instruction set mismatch.");
        return new WorkspaceArtifactInfo(Convert.ToHexString(SHA256.HashData(artifact)).ToLowerInvariant(), artifact.LongLength, Format, ImporterVersion, BakerVersion);
    }

    private static JsonDocument Parse(byte[] source)
    {
        var offset = source.AsSpan().StartsWith(Encoding.UTF8.Preamble) ? Encoding.UTF8.Preamble.Length : 0;
        return JsonDocument.Parse(source.AsMemory(offset));
    }

    private static uint ReadUInt32(byte[] bytes, int offset) => BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(offset, 4));
    private static float ReadSingle(byte[] bytes, int offset) => BitConverter.Int32BitsToSingle(BinaryPrimitives.ReadInt32LittleEndian(bytes.AsSpan(offset, 4)));
    private static void WriteUInt32(byte[] bytes, int offset, uint value) => BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(offset, 4), value);
    private static void WriteSingle(byte[] bytes, int offset, float value) => BinaryPrimitives.WriteInt32LittleEndian(bytes.AsSpan(offset, 4), BitConverter.SingleToInt32Bits(value));
    private sealed record Instruction(uint Hook, uint Operation, float X, float Y);
}
