using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Kadath.Editor.Workspace;

internal sealed record WorkspaceArtifactInfo(string Sha256, long Bytes, string Format, int ImporterVersion, int BakerVersion);

internal static class WorkspaceSceneCodec
{
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    internal const string LegacyFormat = "KSCN-SCENE-V4";
    internal const string BehaviorFormat = "KSCN-SCENE-V5";
    internal const string PrototypeFormat = "KSCN-SCENE-V6";
    private const int LegacyVersion = 4;
    private const int BehaviorVersion = 5;
    private const int PrototypeVersion = 6;
    private const int HeaderBytes = 16;
    private const int MaxArtifactBytes = 1024 * 1024;

    internal static byte[] EncodeSource(byte[] source)
    {
        var scene = WorkspaceSceneDocumentCodec.Parse(source);
        var artifactVersion = scene.SourceSchemaVersion switch
        {
            WorkspaceSceneDocumentCodec.CurrentSchemaVersion => PrototypeVersion,
            WorkspaceSceneDocumentCodec.BehaviorSchemaVersion => BehaviorVersion,
            _ => LegacyVersion
        };
        var textures = scene.Textures.Select(value => new TextureEntry(value.TextureId, StrictUtf8.GetBytes(value.Artifact))).ToArray();
        var objects = scene.Objects.Select(value => new ObjectEntry(value, StrictUtf8.GetBytes(value.ObjectId))).ToArray();
        var prototypes = scene.Prototypes.Select(value => new PrototypeEntry(value, StrictUtf8.GetBytes(value.PrototypeId))).ToArray();
        var payloadBytes = sizeof(uint)
            + textures.Sum(value => 2 * sizeof(uint) + value.Artifact.Length)
            + sizeof(uint)
            + objects.Sum(value => sizeof(uint) + value.EntryBytes(artifactVersion))
            + (artifactVersion == PrototypeVersion ? sizeof(uint) + prototypes.Sum(value => sizeof(uint) + value.EntryBytes()) : 0);
        var artifact = new byte[HeaderBytes + payloadBytes];
        Encoding.ASCII.GetBytes("KSCN").CopyTo(artifact, 0);
        WriteUInt32(artifact, 4, checked((uint)artifactVersion));
        WriteUInt32(artifact, 8, checked((uint)artifactVersion));
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
            WriteUInt32(artifact, offset, checked((uint)entry.EntryBytes(artifactVersion)));
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
            else if (artifactVersion == LegacyVersion && entry.Value.Kind == WorkspaceSceneDocumentCodec.PatrolHazardKind)
            {
                WriteSingle(artifact, offset, (float)entry.Value.PatrolMinY!.Value);
                WriteSingle(artifact, offset + 4, (float)entry.Value.PatrolMaxY!.Value);
                WriteSingle(artifact, offset + 8, (float)entry.Value.PatrolSpeed!.Value);
                offset += 12;
            }
            if (artifactVersion >= BehaviorVersion)
            {
                WriteBindings(artifact, ref offset, entry.Value.Behaviors ?? Array.Empty<WorkspaceSceneBehaviorBinding>());
            }
        }
        if (artifactVersion == PrototypeVersion)
        {
            WriteUInt32(artifact, offset, checked((uint)prototypes.Length));
            offset += sizeof(uint);
            foreach (var entry in prototypes)
            {
                WriteUInt32(artifact, offset, checked((uint)entry.EntryBytes()));
                WriteUInt32(artifact, offset + 4, KindValue(entry.Value.Kind));
                WriteUInt32(artifact, offset + 8, checked((uint)entry.PrototypeId.Length));
                offset += 12;
                entry.PrototypeId.CopyTo(artifact, offset);
                offset += entry.PrototypeId.Length;
                foreach (var value in entry.Value.Size.Concat(entry.Value.Color))
                {
                    WriteSingle(artifact, offset, (float)value);
                    offset += sizeof(float);
                }
                WriteUInt32(artifact, offset, entry.Value.TextureId);
                offset += sizeof(uint);
                WriteBindings(artifact, ref offset, entry.Value.Behaviors);
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
        var artifactVersion = ReadUInt32(artifact, 4);
        var schemaVersion = ReadUInt32(artifact, 8);
        if (artifactVersion != schemaVersion
            || artifactVersion is not (LegacyVersion or BehaviorVersion or PrototypeVersion)
            || ReadUInt32(artifact, 12) != artifact.Length - HeaderBytes)
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
            WorkspaceSceneBehaviorBinding[] behaviors = [];
            if (kind == WorkspaceSceneDocumentCodec.PlayerKind)
            {
                moveSpeed = ReadRequiredSingle(artifact, ref offset);
            }
            else if (artifactVersion == LegacyVersion && kind == WorkspaceSceneDocumentCodec.PatrolHazardKind)
            {
                patrolMinY = ReadRequiredSingle(artifact, ref offset);
                patrolMaxY = ReadRequiredSingle(artifact, ref offset);
                patrolSpeed = ReadRequiredSingle(artifact, ref offset);
            }
            if (artifactVersion >= BehaviorVersion)
            {
                var behaviorCount = ReadRequiredUInt32(artifact, ref offset);
                if (behaviorCount > WorkspaceSceneDocumentCodec.MaxBehaviorBindingsPerObject)
                    throw new InvalidDataException("Scene artifact behavior binding count mismatch.");
                behaviors = new WorkspaceSceneBehaviorBinding[behaviorCount];
                for (var behaviorIndex = 0; behaviorIndex < behaviorCount; behaviorIndex++)
                {
                    var scriptId = ReadRequiredUInt32(artifact, ref offset);
                    var parameterCount = ReadRequiredUInt32(artifact, ref offset);
                    if (parameterCount > WorkspaceSceneDocumentCodec.MaxBehaviorParameterCount)
                        throw new InvalidDataException("Scene artifact behavior parameter count mismatch.");
                    var parameters = new WorkspaceSceneBehaviorParameter[parameterCount];
                    for (var parameterIndex = 0; parameterIndex < parameterCount; parameterIndex++)
                    {
                        var nameBytes = ReadRequiredUInt32(artifact, ref offset);
                        if (nameBytes is < 1 or > WorkspaceSceneDocumentCodec.MaxBehaviorParameterNameBytes)
                            throw new InvalidDataException("Scene artifact behavior parameter name mismatch.");
                        var name = DecodeStrictUtf8(ReadRequiredBytes(artifact, ref offset, nameBytes));
                        parameters[parameterIndex] = new WorkspaceSceneBehaviorParameter(name, ReadRequiredDouble(artifact, ref offset));
                    }
                    behaviors[behaviorIndex] = new WorkspaceSceneBehaviorBinding(scriptId, parameters);
                }
            }
            if (offset != entryEnd) throw new InvalidDataException("Scene artifact object entry length mismatch.");
            objects.Add(new WorkspaceSceneObject(objectId, kind, position, size, color, textureId, moveSpeed, patrolMinY, patrolMaxY, patrolSpeed, behaviors));
        }
        var prototypes = new List<WorkspaceScenePrototype>();
        if (artifactVersion == PrototypeVersion)
        {
            var prototypeCount = ReadRequiredUInt32(artifact, ref offset);
            if (prototypeCount > WorkspaceSceneDocumentCodec.MaxPrototypeCount) throw new InvalidDataException("Scene artifact prototype count mismatch.");
            for (var index = 0; index < prototypeCount; index++)
            {
                var entryBytes = ReadRequiredUInt32(artifact, ref offset);
                if (entryBytes > int.MaxValue || entryBytes > artifact.Length - offset) throw new InvalidDataException("Scene artifact prototype entry is truncated.");
                var entryEnd = offset + (int)entryBytes;
                var kind = KindName(ReadRequiredUInt32(artifact, ref offset));
                var prototypeIdBytes = ReadRequiredUInt32(artifact, ref offset);
                var prototypeId = DecodeStrictUtf8(ReadRequiredBytes(artifact, ref offset, prototypeIdBytes));
                var size = ReadVector(artifact, ref offset, 2);
                var color = ReadVector(artifact, ref offset, 4);
                var textureId = ReadRequiredUInt32(artifact, ref offset);
                var behaviors = ReadBindings(artifact, ref offset);
                if (offset != entryEnd) throw new InvalidDataException("Scene artifact prototype entry length mismatch.");
                prototypes.Add(new WorkspaceScenePrototype(prototypeId, kind, size, color, textureId, behaviors));
            }
        }
        if (offset != artifact.Length) throw new InvalidDataException("Scene artifact contains trailing bytes.");
        try { WorkspaceSceneDocumentCodec.ValidateNormalized(textures, objects, prototypes, checked((int)schemaVersion)); }
        catch (WorkspaceProjectValidationException exception) { throw new InvalidDataException(exception.Message, exception); }
        var format = artifactVersion switch { PrototypeVersion => PrototypeFormat, BehaviorVersion => BehaviorFormat, _ => LegacyFormat };
        return new WorkspaceArtifactInfo(Convert.ToHexString(SHA256.HashData(artifact)).ToLowerInvariant(), artifact.LongLength, format, checked((int)artifactVersion), checked((int)artifactVersion));
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

    private static double ReadRequiredDouble(byte[] bytes, ref int offset)
    {
        if (offset > bytes.Length - sizeof(double)) throw new InvalidDataException("Scene artifact is truncated.");
        var value = BitConverter.Int64BitsToDouble(BinaryPrimitives.ReadInt64LittleEndian(bytes.AsSpan(offset, sizeof(double))));
        offset += sizeof(double);
        if (!double.IsFinite(value)) throw new InvalidDataException("Scene artifact contains a non-finite value.");
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

    private static void WriteBindings(byte[] artifact, ref int offset, IReadOnlyList<WorkspaceSceneBehaviorBinding> behaviors)
    {
        WriteUInt32(artifact, offset, checked((uint)behaviors.Count));
        offset += sizeof(uint);
        foreach (var binding in behaviors)
        {
            WriteUInt32(artifact, offset, binding.ScriptId);
            WriteUInt32(artifact, offset + sizeof(uint), checked((uint)binding.Parameters.Length));
            offset += 2 * sizeof(uint);
            foreach (var parameter in binding.Parameters)
            {
                var name = StrictUtf8.GetBytes(parameter.Name);
                WriteUInt32(artifact, offset, checked((uint)name.Length));
                offset += sizeof(uint);
                name.CopyTo(artifact, offset);
                offset += name.Length;
                WriteDouble(artifact, offset, parameter.Value);
                offset += sizeof(double);
            }
        }
    }

    private static WorkspaceSceneBehaviorBinding[] ReadBindings(byte[] artifact, ref int offset)
    {
        var behaviorCount = ReadRequiredUInt32(artifact, ref offset);
        if (behaviorCount > WorkspaceSceneDocumentCodec.MaxBehaviorBindingsPerObject) throw new InvalidDataException("Scene artifact behavior binding count mismatch.");
        var behaviors = new WorkspaceSceneBehaviorBinding[behaviorCount];
        for (var behaviorIndex = 0; behaviorIndex < behaviorCount; behaviorIndex++)
        {
            var scriptId = ReadRequiredUInt32(artifact, ref offset);
            var parameterCount = ReadRequiredUInt32(artifact, ref offset);
            if (parameterCount > WorkspaceSceneDocumentCodec.MaxBehaviorParameterCount) throw new InvalidDataException("Scene artifact behavior parameter count mismatch.");
            var parameters = new WorkspaceSceneBehaviorParameter[parameterCount];
            for (var parameterIndex = 0; parameterIndex < parameterCount; parameterIndex++)
            {
                var nameBytes = ReadRequiredUInt32(artifact, ref offset);
                if (nameBytes is < 1 or > WorkspaceSceneDocumentCodec.MaxBehaviorParameterNameBytes) throw new InvalidDataException("Scene artifact behavior parameter name mismatch.");
                var name = DecodeStrictUtf8(ReadRequiredBytes(artifact, ref offset, nameBytes));
                parameters[parameterIndex] = new WorkspaceSceneBehaviorParameter(name, ReadRequiredDouble(artifact, ref offset));
            }
            behaviors[behaviorIndex] = new WorkspaceSceneBehaviorBinding(scriptId, parameters);
        }
        return behaviors;
    }

    private static uint ReadUInt32(byte[] bytes, int offset) => BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(offset, 4));
    private static float ReadSingle(byte[] bytes, int offset) => BitConverter.Int32BitsToSingle(BinaryPrimitives.ReadInt32LittleEndian(bytes.AsSpan(offset, 4)));
    private static void WriteUInt32(byte[] bytes, int offset, uint value) => BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(offset, 4), value);
    private static void WriteSingle(byte[] bytes, int offset, float value) => BinaryPrimitives.WriteInt32LittleEndian(bytes.AsSpan(offset, 4), BitConverter.SingleToInt32Bits(value));
    private static void WriteDouble(byte[] bytes, int offset, double value) => BinaryPrimitives.WriteInt64LittleEndian(bytes.AsSpan(offset, 8), BitConverter.DoubleToInt64Bits(value));
    private sealed record TextureEntry(uint TextureId, byte[] Artifact);
    private sealed record ObjectEntry(WorkspaceSceneObject Value, byte[] ObjectId)
    {
        internal int EntryBytes(int artifactVersion)
        {
            var bytes = 44 + ObjectId.Length + (Value.Kind switch
            {
                WorkspaceSceneDocumentCodec.PlayerKind => 4,
                WorkspaceSceneDocumentCodec.PatrolHazardKind when artifactVersion == LegacyVersion => 12,
                _ => 0
            });
            if (artifactVersion < BehaviorVersion) return bytes;
            bytes = checked(bytes + sizeof(uint));
            foreach (var binding in Value.Behaviors ?? Array.Empty<WorkspaceSceneBehaviorBinding>())
            {
                bytes = checked(bytes + 2 * sizeof(uint));
                foreach (var parameter in binding.Parameters)
                {
                    bytes = checked(bytes + sizeof(uint) + StrictUtf8.GetByteCount(parameter.Name) + sizeof(double));
                }
            }
            return bytes;
        }
    }
    private sealed record PrototypeEntry(WorkspaceScenePrototype Value, byte[] PrototypeId)
    {
        internal int EntryBytes()
        {
            var bytes = 4 + 4 + PrototypeId.Length + 6 * sizeof(float) + sizeof(uint) + sizeof(uint);
            foreach (var binding in Value.Behaviors)
            {
                bytes = checked(bytes + 2 * sizeof(uint));
                foreach (var parameter in binding.Parameters)
                    bytes = checked(bytes + sizeof(uint) + StrictUtf8.GetByteCount(parameter.Name) + sizeof(double));
            }
            return bytes;
        }
    }
}

internal static class WorkspaceScriptCodec
{
    internal const string LegacyFormat = "KSCP-SCRIPT-V1";
    internal const string BehaviorFormat = "KSCP-SCRIPT-V2";
    private const int LegacyVersion = 1;
    private const int BehaviorVersion = 2;
    private const int BehaviorHostInterfaceVersion = 4;
    private const int BehaviorHeaderBytes = 60;
    private const int BehaviorEntryHeaderBytes = 84;
    private const int MaxBehaviorArtifactBytes = 16 * 1024 * 1024;
    private const int MaxBehaviorEntryCount = 16;
    private const int MaxToolchainIdentityBytes = 127;
    private const int MaxSourceNameBytes = 1024;
    private const int MaxParameterCount = 16;
    private const int MaxParameterNameBytes = 63;
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);

    internal static byte[] EncodeSource(
        string packageRoot,
        string scriptPath,
        WorkspaceScriptSourceSnapshot snapshot,
        CancellationToken cancellationToken) =>
        snapshot.IsBehaviorPackage
            ? WorkspaceBehaviorTool.Build(packageRoot, scriptPath, snapshot, cancellationToken)
            : EncodeSource(snapshot.ManifestSource);

    internal static byte[] EncodeSource(byte[] source)
    {
        WorkspaceProjectValidator.ValidateLegacyScriptSource(source);
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
        if (artifact.Length < 8 || Encoding.ASCII.GetString(artifact, 0, 4) != "KSCP") throw new InvalidDataException("Script artifact layout mismatch.");
        return ReadUInt32(artifact, 4) switch
        {
            LegacyVersion => ValidateLegacyArtifact(artifact),
            BehaviorVersion => ValidateBehaviorArtifact(artifact),
            _ => throw new InvalidDataException("Unsupported Script artifact version.")
        };
    }

    internal static WorkspaceBehaviorContractCatalog ReadBehaviorContractCatalog(byte[] artifact)
    {
        if (artifact.Length < 8 || Encoding.ASCII.GetString(artifact, 0, 4) != "KSCP")
            throw new InvalidDataException("Script artifact layout mismatch.");
        if (ReadUInt32(artifact, 4) != BehaviorVersion)
            throw new InvalidDataException("Behavior Script artifact version mismatch.");
        return ParseBehaviorArtifact(artifact).Catalog;
    }

    private static WorkspaceArtifactInfo ValidateLegacyArtifact(byte[] artifact)
    {
        if (artifact.Length < 16) throw new InvalidDataException("Script artifact layout mismatch.");
        var count = ReadUInt32(artifact, 12);
        if (ReadUInt32(artifact, 8) != LegacyVersion || count > 16 || artifact.Length != 16 + count * 16)
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
        return ArtifactInfo(artifact, LegacyFormat, LegacyVersion);
    }

    private static WorkspaceArtifactInfo ValidateBehaviorArtifact(byte[] artifact)
        => ParseBehaviorArtifact(artifact).Info;

    private static ParsedBehaviorArtifact ParseBehaviorArtifact(byte[] artifact)
    {
        if (artifact.Length is < BehaviorHeaderBytes or > MaxBehaviorArtifactBytes)
            throw new InvalidDataException("Behavior Script artifact layout mismatch.");
        if (ReadUInt32(artifact, 8) != BehaviorVersion || ReadUInt32(artifact, 12) != BehaviorHostInterfaceVersion)
            throw new InvalidDataException("Behavior Script artifact contract mismatch.");
        var entryCount = ReadUInt32(artifact, 16);
        var toolchainIdentityBytes = ReadUInt32(artifact, 20);
        var payloadBytes = ReadUInt32(artifact, 24);
        if (entryCount is < 1 or > MaxBehaviorEntryCount
            || toolchainIdentityBytes is < 1 or > MaxToolchainIdentityBytes
            || payloadBytes != checked((uint)(artifact.Length - BehaviorHeaderBytes)))
        {
            throw new InvalidDataException("Behavior Script artifact header mismatch.");
        }
        var actualPayloadSha256 = SHA256.HashData(artifact.AsSpan(BehaviorHeaderBytes));
        if (!artifact.AsSpan(28, 32).SequenceEqual(actualPayloadSha256))
            throw new InvalidDataException("Behavior Script artifact payload hash mismatch.");

        var offset = BehaviorHeaderBytes;
        var toolchainIdentity = ReadRequiredBytes(artifact, ref offset, toolchainIdentityBytes);
        if (!toolchainIdentity.All(IsToolchainIdentityByte))
            throw new InvalidDataException("Behavior Script artifact toolchain identity mismatch.");
        var toolchainIdentityText = DecodeStrictUtf8(toolchainIdentity);
        var scriptIds = new HashSet<uint>();
        var sourceNames = new HashSet<string>(StringComparer.Ordinal);
        var entries = new WorkspaceBehaviorContractEntry[entryCount];
        for (var index = 0; index < entryCount; index++)
        {
            var entryStart = offset;
            var encodedEntryBytes = ReadRequiredUInt32(artifact, ref offset);
            if (encodedEntryBytes < BehaviorEntryHeaderBytes || encodedEntryBytes > int.MaxValue)
                throw new InvalidDataException("Behavior Script artifact entry length mismatch.");
            var entryEnd = checked(entryStart + (int)encodedEntryBytes);
            if (entryEnd > artifact.Length) throw new InvalidDataException("Behavior Script artifact entry is truncated.");

            var scriptId = ReadRequiredUInt32(artifact, ref offset);
            var sourceNameBytes = ReadRequiredUInt32(artifact, ref offset);
            var parameterCount = ReadRequiredUInt32(artifact, ref offset);
            var bytecodeBytes = ReadRequiredUInt32(artifact, ref offset);
            if (scriptId == 0 || !scriptIds.Add(scriptId)
                || sourceNameBytes is < 1 or > MaxSourceNameBytes
                || parameterCount > MaxParameterCount
                || bytecodeBytes == 0)
            {
                throw new InvalidDataException("Behavior Script artifact entry header mismatch.");
            }
            var sourceHash = ReadRequiredBytes(artifact, ref offset, 32);
            var expectedBytecodeSha256 = ReadRequiredBytes(artifact, ref offset, 32);
            var sourceName = DecodeStrictUtf8(ReadRequiredBytes(artifact, ref offset, sourceNameBytes));
            if (!IsSourceName(sourceName) || !sourceNames.Add(sourceName))
                throw new InvalidDataException("Behavior Script artifact source identity mismatch.");

            var parameterNames = new HashSet<string>(StringComparer.Ordinal);
            var parameters = new WorkspaceBehaviorParameterSchema[parameterCount];
            for (var parameterIndex = 0; parameterIndex < parameterCount; parameterIndex++)
            {
                var parameterNameBytes = ReadRequiredUInt32(artifact, ref offset);
                if (parameterNameBytes is < 1 or > MaxParameterNameBytes)
                    throw new InvalidDataException("Behavior Script artifact parameter name length mismatch.");
                var defaultValue = ReadRequiredDouble(artifact, ref offset);
                var minimum = ReadRequiredDouble(artifact, ref offset);
                var maximum = ReadRequiredDouble(artifact, ref offset);
                var parameterName = DecodeStrictUtf8(ReadRequiredBytes(artifact, ref offset, parameterNameBytes));
                if (!IsParameterName(parameterName) || !parameterNames.Add(parameterName)
                    || !double.IsFinite(defaultValue) || !double.IsFinite(minimum) || !double.IsFinite(maximum)
                    || minimum > maximum || defaultValue < minimum || defaultValue > maximum)
                {
                    throw new InvalidDataException("Behavior Script artifact parameter schema mismatch.");
                }
                parameters[parameterIndex] = new WorkspaceBehaviorParameterSchema(
                    parameterName, "number", defaultValue, minimum, maximum);
            }

            var bytecode = ReadRequiredBytes(artifact, ref offset, bytecodeBytes);
            if (offset != entryEnd || !expectedBytecodeSha256.SequenceEqual(SHA256.HashData(bytecode)))
                throw new InvalidDataException("Behavior Script artifact bytecode identity mismatch.");
            entries[index] = new WorkspaceBehaviorContractEntry(
                scriptId,
                sourceName,
                Convert.ToHexString(sourceHash).ToLowerInvariant(),
                parameters);
        }
        if (offset != artifact.Length) throw new InvalidDataException("Behavior Script artifact has trailing bytes.");
        var info = ArtifactInfo(artifact, BehaviorFormat, BehaviorVersion);
        return new ParsedBehaviorArtifact(
            info,
            new WorkspaceBehaviorContractCatalog(toolchainIdentityText, entries));
    }

    private static JsonDocument Parse(byte[] source)
    {
        var offset = source.AsSpan().StartsWith(Encoding.UTF8.Preamble) ? Encoding.UTF8.Preamble.Length : 0;
        return JsonDocument.Parse(source.AsMemory(offset));
    }

    private static WorkspaceArtifactInfo ArtifactInfo(byte[] artifact, string format, int version) =>
        new(Convert.ToHexString(SHA256.HashData(artifact)).ToLowerInvariant(), artifact.LongLength, format, version, version);

    private static uint ReadRequiredUInt32(byte[] bytes, ref int offset)
    {
        var value = ReadUInt32(ReadRequiredBytes(bytes, ref offset, sizeof(uint)), 0);
        return value;
    }

    private static double ReadRequiredDouble(byte[] bytes, ref int offset)
    {
        var value = BinaryPrimitives.ReadInt64LittleEndian(ReadRequiredBytes(bytes, ref offset, sizeof(double)));
        return BitConverter.Int64BitsToDouble(value);
    }

    private static byte[] ReadRequiredBytes(byte[] bytes, ref int offset, uint count)
    {
        if (count > int.MaxValue || count > bytes.Length - offset) throw new InvalidDataException("Behavior Script artifact is truncated.");
        var value = bytes.AsSpan(offset, (int)count).ToArray();
        offset += (int)count;
        return value;
    }

    private static bool IsToolchainIdentityByte(byte value) =>
        value is >= (byte)'A' and <= (byte)'Z'
            or >= (byte)'a' and <= (byte)'z'
            or >= (byte)'0' and <= (byte)'9'
            or (byte)'.' or (byte)'-' or (byte)'_';

    private static bool IsSourceName(string value) =>
        value.StartsWith("scripts/", StringComparison.Ordinal)
        && value.EndsWith(".luau", StringComparison.Ordinal)
        && !value.Contains('\\')
        && !value.Contains('\0')
        && value.Split('/').All(segment => segment.Length > 0 && segment is not "." and not "..");

    private static bool IsParameterName(string value)
    {
        if (value.Length == 0 || !IsIdentifierStart(value[0])) return false;
        return value.Skip(1).All(character => IsIdentifierStart(character) || character is >= '0' and <= '9');
    }

    private static bool IsIdentifierStart(char value) => value is >= 'A' and <= 'Z' or >= 'a' and <= 'z' or '_';
    private static string DecodeStrictUtf8(byte[] bytes)
    {
        try { return StrictUtf8.GetString(bytes); }
        catch (DecoderFallbackException exception) { throw new InvalidDataException("Behavior Script artifact contains invalid UTF-8.", exception); }
    }

    private static uint ReadUInt32(byte[] bytes, int offset) => BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(offset, 4));
    private static float ReadSingle(byte[] bytes, int offset) => BitConverter.Int32BitsToSingle(BinaryPrimitives.ReadInt32LittleEndian(bytes.AsSpan(offset, 4)));
    private static void WriteUInt32(byte[] bytes, int offset, uint value) => BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(offset, 4), value);
    private static void WriteSingle(byte[] bytes, int offset, float value) => BinaryPrimitives.WriteInt32LittleEndian(bytes.AsSpan(offset, 4), BitConverter.SingleToInt32Bits(value));
    private sealed record Instruction(uint Hook, uint Operation, float X, float Y);
    private sealed record ParsedBehaviorArtifact(
        WorkspaceArtifactInfo Info,
        WorkspaceBehaviorContractCatalog Catalog);
}
