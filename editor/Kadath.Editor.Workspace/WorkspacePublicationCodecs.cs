using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Kadath.Editor.Workspace;

internal sealed record WorkspaceArtifactInfo(string Sha256, long Bytes, string Format, int ImporterVersion, int BakerVersion);

internal static class WorkspaceSceneCodec
{
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    internal const string Format = "KSCN-SCENE-V3";
    internal const int ImporterVersion = 3;
    internal const int BakerVersion = 3;
    private const int HeaderBytes = 16;
    private const int FieldCount = 28;
    private const int FixedPayloadBytes = (FieldCount + 3) * sizeof(uint);

    internal static byte[] EncodeSource(byte[] source)
    {
        WorkspaceProjectValidator.ValidateSceneSource(source);
        using var document = Parse(source);
        var root = document.RootElement;
        var fields = new List<float>(FieldCount);
        var player = root.GetProperty("player");
        var goal = root.GetProperty("goal");
        var hazard = root.GetProperty("hazard");
        AddSprite(fields, player, hasMoveSpeed: true);
        AddSprite(fields, goal, hasMoveSpeed: false);
        AddVector(fields, hazard.GetProperty("position"));
        AddVector(fields, hazard.GetProperty("size"));
        AddVector(fields, hazard.GetProperty("color"));
        fields.Add((float)hazard.GetProperty("patrolMinY").GetDouble());
        fields.Add((float)hazard.GetProperty("patrolMaxY").GetDouble());
        fields.Add((float)hazard.GetProperty("patrolSpeed").GetDouble());
        if (fields.Count != FieldCount) throw new InvalidOperationException($"Internal Scene field count mismatch: {fields.Count}.");

        var textureIds = new[]
        {
            player.GetProperty("textureId").GetUInt32(),
            goal.GetProperty("textureId").GetUInt32(),
            hazard.GetProperty("textureId").GetUInt32()
        };
        var textures = root.GetProperty("textures").EnumerateArray().Select(value =>
            new TextureEntry(value.GetProperty("textureId").GetUInt32(), Encoding.UTF8.GetBytes(value.GetProperty("artifact").GetString()!))).ToArray();
        var payloadBytes = FixedPayloadBytes + sizeof(uint) + textures.Sum(value => 2 * sizeof(uint) + value.Artifact.Length);
        var artifact = new byte[HeaderBytes + payloadBytes];
        Encoding.ASCII.GetBytes("KSCN").CopyTo(artifact, 0);
        WriteUInt32(artifact, 4, 3);
        WriteUInt32(artifact, 8, 3);
        WriteUInt32(artifact, 12, checked((uint)payloadBytes));
        var offset = HeaderBytes;
        foreach (var field in fields) { WriteSingle(artifact, offset, field); offset += sizeof(float); }
        foreach (var textureId in textureIds) { WriteUInt32(artifact, offset, textureId); offset += sizeof(uint); }
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
        if (offset != artifact.Length) throw new InvalidOperationException("Internal KSCN length mismatch.");
        _ = ValidateArtifact(artifact);
        return artifact;
    }

    internal static WorkspaceArtifactInfo ValidateArtifact(byte[] artifact)
    {
        if (artifact.Length < 144 || Encoding.ASCII.GetString(artifact, 0, 4) != "KSCN") throw new InvalidDataException("Scene artifact layout mismatch.");
        if (ReadUInt32(artifact, 4) != 3 || ReadUInt32(artifact, 8) != 3 || ReadUInt32(artifact, 12) != artifact.Length - HeaderBytes)
            throw new InvalidDataException("Scene artifact header mismatch.");
        var fields = new float[FieldCount];
        var offset = HeaderBytes;
        for (var index = 0; index < fields.Length; index++)
        {
            fields[index] = ReadSingle(artifact, offset);
            if (!float.IsFinite(fields[index])) throw new InvalidDataException("Scene artifact contains a non-finite field.");
            offset += sizeof(float);
        }
        ValidateSceneFields(fields);
        var spriteTextureIds = new[] { ReadUInt32(artifact, offset), ReadUInt32(artifact, offset + 4), ReadUInt32(artifact, offset + 8) };
        offset += 12;
        var textureCount = ReadUInt32(artifact, offset);
        offset += 4;
        if (textureCount is < 1 or > 4) throw new InvalidDataException("Scene artifact texture count mismatch.");
        var declared = new HashSet<uint>();
        for (var index = 0; index < textureCount; index++)
        {
            if (offset + 8 > artifact.Length) throw new InvalidDataException("Scene artifact texture entry is truncated.");
            var textureId = ReadUInt32(artifact, offset);
            var pathBytes = ReadUInt32(artifact, offset + 4);
            offset += 8;
            if (textureId == 0 || !declared.Add(textureId) || pathBytes is 0 or > 255 || offset + pathBytes > artifact.Length)
                throw new InvalidDataException("Scene artifact texture entry is invalid.");
            string path;
            try { path = StrictUtf8.GetString(artifact, offset, checked((int)pathBytes)); }
            catch (DecoderFallbackException exception) { throw new InvalidDataException("Scene artifact texture path is not valid UTF-8.", exception); }
            if (!WorkspaceProjectValidator.IsTextureArtifactPath(path)) throw new InvalidDataException("Scene artifact texture path is invalid.");
            offset += checked((int)pathBytes);
        }
        if (offset != artifact.Length || spriteTextureIds.Any(value => !declared.Contains(value))) throw new InvalidDataException("Scene artifact texture binding mismatch.");
        return Info(artifact, Format, ImporterVersion, BakerVersion);
    }

    private static void ValidateSceneFields(float[] fields)
    {
        if (fields[2] <= 0 || fields[3] <= 0 || fields[11] <= 0 || fields[12] <= 0 || fields[19] <= 0 || fields[20] <= 0)
            throw new InvalidDataException("Scene artifact contains a non-positive sprite size.");
        foreach (var index in new[] { 4, 5, 6, 7, 13, 14, 15, 16, 21, 22, 23, 24 })
            if (fields[index] is < 0 or > 1) throw new InvalidDataException("Scene artifact color is outside [0, 1].");
        if (fields[8] < 0 || fields[27] < 0 || fields[25] >= fields[26] || fields[18] < fields[25] || fields[18] > fields[26])
            throw new InvalidDataException("Scene artifact movement fields are invalid.");
    }

    private static void AddSprite(List<float> fields, JsonElement sprite, bool hasMoveSpeed)
    {
        AddVector(fields, sprite.GetProperty("position"));
        AddVector(fields, sprite.GetProperty("size"));
        AddVector(fields, sprite.GetProperty("color"));
        if (hasMoveSpeed) fields.Add((float)sprite.GetProperty("moveSpeed").GetDouble());
    }

    private static void AddVector(List<float> fields, JsonElement value)
    {
        foreach (var element in value.EnumerateArray()) fields.Add((float)element.GetDouble());
    }

    private static JsonDocument Parse(byte[] source)
    {
        var offset = source.AsSpan().StartsWith(Encoding.UTF8.Preamble) ? Encoding.UTF8.Preamble.Length : 0;
        return JsonDocument.Parse(source.AsMemory(offset));
    }

    private static WorkspaceArtifactInfo Info(byte[] bytes, string format, int importerVersion, int bakerVersion) =>
        new(Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant(), bytes.LongLength, format, importerVersion, bakerVersion);
    private static uint ReadUInt32(byte[] bytes, int offset) => BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(offset, 4));
    private static float ReadSingle(byte[] bytes, int offset) => BitConverter.Int32BitsToSingle(BinaryPrimitives.ReadInt32LittleEndian(bytes.AsSpan(offset, 4)));
    private static void WriteUInt32(byte[] bytes, int offset, uint value) => BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(offset, 4), value);
    private static void WriteSingle(byte[] bytes, int offset, float value) => BinaryPrimitives.WriteInt32LittleEndian(bytes.AsSpan(offset, 4), BitConverter.SingleToInt32Bits(value));
    private sealed record TextureEntry(uint TextureId, byte[] Artifact);
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
