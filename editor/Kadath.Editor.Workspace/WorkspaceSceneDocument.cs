using System.Buffers;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Kadath.Editor.Protocol;

namespace Kadath.Editor.Workspace;

internal sealed record WorkspaceSceneTexture(uint TextureId, string Artifact);

internal sealed record WorkspaceSceneObject(
    string ObjectId,
    string Kind,
    double[] Position,
    double[] Size,
    double[] Color,
    uint TextureId,
    double? MoveSpeed = null,
    double? PatrolMinY = null,
    double? PatrolMaxY = null,
    double? PatrolSpeed = null)
{
    internal ProjectModelSceneObject ToProjectModel() => new(
        ObjectId, Kind, Position.ToArray(), Size.ToArray(), Color.ToArray(), TextureId,
        MoveSpeed, PatrolMinY, PatrolMaxY, PatrolSpeed);

    internal SceneObjectDefinition ToDefinition() => new(
        ObjectId, Kind, Position.ToArray(), Size.ToArray(), Color.ToArray(), TextureId,
        MoveSpeed, PatrolMinY, PatrolMaxY, PatrolSpeed);
}

internal sealed record WorkspaceSceneDocument(
    int SourceSchemaVersion,
    WorkspaceSceneTexture[] Textures,
    WorkspaceSceneObject[] Objects)
{
    internal WorkspaceSceneObject Player => Objects.Single(value => value.Kind == WorkspaceSceneDocumentCodec.PlayerKind);
    internal WorkspaceSceneObject Goal => Objects.Single(value => value.Kind == WorkspaceSceneDocumentCodec.GoalKind);
    internal WorkspaceSceneObject PrimaryHazard => Objects.First(value => value.Kind == WorkspaceSceneDocumentCodec.PatrolHazardKind);
}

internal static partial class WorkspaceSceneDocumentCodec
{
    internal const int CurrentSchemaVersion = 4;
    internal const int MinObjectCount = 3;
    internal const int MaxObjectCount = 64;
    internal const string SpriteKind = "sprite";
    internal const string PlayerKind = "player";
    internal const string GoalKind = "goal";
    internal const string PatrolHazardKind = "patrol_hazard";

    private static readonly UTF8Encoding StrictUtf8 = new(false, true);

    [GeneratedRegex("^[a-z][a-z0-9_-]{0,62}$", RegexOptions.CultureInvariant)]
    private static partial Regex ObjectIdPattern();

    internal static WorkspaceSceneDocument Parse(byte[] source)
    {
        if (source.Length > WorkspaceProjectValidator.MaxDocumentBytes) throw Failure("Scene exceeds the 64 KiB Runtime document budget.");
        try
        {
            var offset = source.AsSpan().StartsWith(Encoding.UTF8.Preamble) ? Encoding.UTF8.Preamble.Length : 0;
            using var document = JsonDocument.Parse(source.AsMemory(offset), new JsonDocumentOptions
            {
                CommentHandling = JsonCommentHandling.Disallow,
                AllowTrailingCommas = false,
                MaxDepth = 32
            });
            var root = document.RootElement;
            RequireObject(root, "Scene");
            var schemaVersion = RequireInt32(root, "schemaVersion", "Scene");
            var properties = schemaVersion switch
            {
                3 => ReadProperties(root, ["schemaVersion", "textures", "player", "goal", "hazard"], [], "Scene"),
                CurrentSchemaVersion => ReadProperties(root, ["schemaVersion", "textures", "objects"], [], "Scene"),
                _ => throw Failure("Unsupported Scene schemaVersion.")
            };
            var textures = ReadTextures(properties["textures"]);
            var objects = schemaVersion == 3 ? ReadLegacyObjects(properties) : ReadObjects(properties["objects"]);
            Validate(textures, objects);
            return new WorkspaceSceneDocument(schemaVersion, textures, objects);
        }
        catch (JsonException exception)
        {
            throw Failure($"Failed to parse Scene: {exception.Message}", exception);
        }
        catch (DecoderFallbackException exception)
        {
            throw Failure("Scene must contain valid UTF-8.", exception);
        }
    }

    internal static WorkspaceSceneObject[] NormalizeDefinitions(IReadOnlyList<SceneObjectDefinition> definitions, IReadOnlyList<WorkspaceSceneTexture> textures)
    {
        if (definitions.Count is < MinObjectCount or > MaxObjectCount) throw Failure($"Scene.objects must contain {MinObjectCount} to {MaxObjectCount} entries.");
        var objects = definitions.Select(value => new WorkspaceSceneObject(
            value.ObjectId,
            value.Kind,
            CopyVector(value.Position, 2, $"Scene.objects[{value.ObjectId}].position"),
            CopyVector(value.Size, 2, $"Scene.objects[{value.ObjectId}].size"),
            CopyVector(value.Color, 4, $"Scene.objects[{value.ObjectId}].color"),
            value.TextureId,
            value.MoveSpeed,
            value.PatrolMinY,
            value.PatrolMaxY,
            value.PatrolSpeed)).ToArray();
        Validate(textures, objects);
        return objects;
    }

    internal static void ValidateNormalized(IReadOnlyList<WorkspaceSceneTexture> textures, IReadOnlyList<WorkspaceSceneObject> objects) =>
        Validate(textures, objects);

    internal static byte[] SerializeV4(IReadOnlyList<WorkspaceSceneTexture> textures, IReadOnlyList<WorkspaceSceneObject> objects)
    {
        Validate(textures, objects);
        var buffer = new ArrayBufferWriter<byte>();
        using (var writer = new Utf8JsonWriter(buffer, new JsonWriterOptions { Indented = true }))
        {
            writer.WriteStartObject();
            writer.WriteNumber("schemaVersion", CurrentSchemaVersion);
            writer.WritePropertyName("textures");
            writer.WriteStartArray();
            foreach (var texture in textures)
            {
                writer.WriteStartObject();
                writer.WriteNumber("textureId", texture.TextureId);
                writer.WriteString("artifact", texture.Artifact);
                writer.WriteEndObject();
            }
            writer.WriteEndArray();
            writer.WritePropertyName("objects");
            writer.WriteStartArray();
            foreach (var sceneObject in objects)
            {
                writer.WriteStartObject();
                writer.WriteString("objectId", sceneObject.ObjectId);
                writer.WriteString("kind", sceneObject.Kind);
                writer.WritePropertyName("transform");
                writer.WriteStartObject();
                WriteVector(writer, "position", sceneObject.Position);
                writer.WriteEndObject();
                writer.WritePropertyName("sprite");
                writer.WriteStartObject();
                WriteVector(writer, "size", sceneObject.Size);
                WriteVector(writer, "color", sceneObject.Color);
                writer.WriteNumber("textureId", sceneObject.TextureId);
                writer.WriteEndObject();
                if (sceneObject.Kind == PlayerKind)
                {
                    writer.WritePropertyName("player");
                    writer.WriteStartObject();
                    writer.WriteNumber("moveSpeed", sceneObject.MoveSpeed!.Value);
                    writer.WriteEndObject();
                }
                else if (sceneObject.Kind == PatrolHazardKind)
                {
                    writer.WritePropertyName("patrol");
                    writer.WriteStartObject();
                    writer.WriteNumber("minY", sceneObject.PatrolMinY!.Value);
                    writer.WriteNumber("maxY", sceneObject.PatrolMaxY!.Value);
                    writer.WriteNumber("speed", sceneObject.PatrolSpeed!.Value);
                    writer.WriteEndObject();
                }
                writer.WriteEndObject();
            }
            writer.WriteEndArray();
            writer.WriteEndObject();
        }
        var bytes = new byte[buffer.WrittenCount + 1];
        buffer.WrittenSpan.CopyTo(bytes);
        bytes[^1] = (byte)'\n';
        if (bytes.Length > WorkspaceProjectValidator.MaxDocumentBytes) throw Failure("Scene exceeds the 64 KiB Runtime document budget.");
        return bytes;
    }

    private static WorkspaceSceneTexture[] ReadTextures(JsonElement value)
    {
        RequireArray(value, "Scene.textures");
        if (value.GetArrayLength() is < 1 or > 4) throw Failure("Scene.textures must contain 1 to 4 entries.");
        var textures = new List<WorkspaceSceneTexture>();
        foreach (var element in value.EnumerateArray())
        {
            var properties = ReadProperties(element, ["textureId", "artifact"], [], "Scene.textures[]");
            textures.Add(new WorkspaceSceneTexture(
                RequireUInt32(properties["textureId"], "Scene.textures[].textureId"),
                RequireString(properties["artifact"], "Scene.textures[].artifact")));
        }
        return textures.ToArray();
    }

    private static WorkspaceSceneObject[] ReadObjects(JsonElement value)
    {
        RequireArray(value, "Scene.objects");
        if (value.GetArrayLength() is < MinObjectCount or > MaxObjectCount) throw Failure($"Scene.objects must contain {MinObjectCount} to {MaxObjectCount} entries.");
        var objects = new List<WorkspaceSceneObject>();
        var index = 0;
        foreach (var element in value.EnumerateArray())
        {
            var owner = $"Scene.objects[{index}]";
            var properties = ReadProperties(element, ["objectId", "kind", "transform", "sprite"], ["player", "patrol"], owner);
            var objectId = RequireString(properties["objectId"], $"{owner}.objectId");
            var kind = RequireString(properties["kind"], $"{owner}.kind");
            var transform = ReadProperties(properties["transform"], ["position"], [], $"{owner}.transform");
            var sprite = ReadProperties(properties["sprite"], ["size", "color", "textureId"], [], $"{owner}.sprite");
            double? moveSpeed = null;
            double? patrolMinY = null;
            double? patrolMaxY = null;
            double? patrolSpeed = null;
            switch (kind)
            {
                case SpriteKind:
                case GoalKind:
                    if (properties.ContainsKey("player") || properties.ContainsKey("patrol")) throw Failure($"{owner} has an invalid kind payload.");
                    break;
                case PlayerKind:
                    if (!properties.TryGetValue("player", out var player) || properties.ContainsKey("patrol")) throw Failure($"{owner} must contain only player payload.");
                    var playerProperties = ReadProperties(player, ["moveSpeed"], [], $"{owner}.player");
                    moveSpeed = RequireFiniteDouble(playerProperties["moveSpeed"], $"{owner}.player.moveSpeed");
                    break;
                case PatrolHazardKind:
                    if (!properties.TryGetValue("patrol", out var patrol) || properties.ContainsKey("player")) throw Failure($"{owner} must contain only patrol payload.");
                    var patrolProperties = ReadProperties(patrol, ["minY", "maxY", "speed"], [], $"{owner}.patrol");
                    patrolMinY = RequireFiniteDouble(patrolProperties["minY"], $"{owner}.patrol.minY");
                    patrolMaxY = RequireFiniteDouble(patrolProperties["maxY"], $"{owner}.patrol.maxY");
                    patrolSpeed = RequireFiniteDouble(patrolProperties["speed"], $"{owner}.patrol.speed");
                    break;
                default:
                    throw Failure($"{owner}.kind is unsupported: {kind}.");
            }
            objects.Add(new WorkspaceSceneObject(
                objectId,
                kind,
                RequireVector(transform["position"], 2, $"{owner}.transform.position"),
                RequireVector(sprite["size"], 2, $"{owner}.sprite.size"),
                RequireVector(sprite["color"], 4, $"{owner}.sprite.color"),
                RequireUInt32(sprite["textureId"], $"{owner}.sprite.textureId"),
                moveSpeed,
                patrolMinY,
                patrolMaxY,
                patrolSpeed));
            index++;
        }
        return objects.ToArray();
    }

    private static WorkspaceSceneObject[] ReadLegacyObjects(IReadOnlyDictionary<string, JsonElement> properties)
    {
        var playerProperties = ReadProperties(properties["player"], ["position", "size", "color", "moveSpeed", "textureId"], [], "Scene.player");
        var goalProperties = ReadProperties(properties["goal"], ["position", "size", "color", "textureId"], [], "Scene.goal");
        var hazardProperties = ReadProperties(properties["hazard"], ["position", "size", "color", "patrolMinY", "patrolMaxY", "patrolSpeed", "textureId"], [], "Scene.hazard");
        return
        [
            new WorkspaceSceneObject(
                "player", PlayerKind,
                RequireVector(playerProperties["position"], 2, "Scene.player.position"),
                RequireVector(playerProperties["size"], 2, "Scene.player.size"),
                RequireVector(playerProperties["color"], 4, "Scene.player.color"),
                RequireUInt32(playerProperties["textureId"], "Scene.player.textureId"),
                RequireFiniteDouble(playerProperties["moveSpeed"], "Scene.player.moveSpeed")),
            new WorkspaceSceneObject(
                "goal", GoalKind,
                RequireVector(goalProperties["position"], 2, "Scene.goal.position"),
                RequireVector(goalProperties["size"], 2, "Scene.goal.size"),
                RequireVector(goalProperties["color"], 4, "Scene.goal.color"),
                RequireUInt32(goalProperties["textureId"], "Scene.goal.textureId")),
            new WorkspaceSceneObject(
                "hazard", PatrolHazardKind,
                RequireVector(hazardProperties["position"], 2, "Scene.hazard.position"),
                RequireVector(hazardProperties["size"], 2, "Scene.hazard.size"),
                RequireVector(hazardProperties["color"], 4, "Scene.hazard.color"),
                RequireUInt32(hazardProperties["textureId"], "Scene.hazard.textureId"),
                PatrolMinY: RequireFiniteDouble(hazardProperties["patrolMinY"], "Scene.hazard.patrolMinY"),
                PatrolMaxY: RequireFiniteDouble(hazardProperties["patrolMaxY"], "Scene.hazard.patrolMaxY"),
                PatrolSpeed: RequireFiniteDouble(hazardProperties["patrolSpeed"], "Scene.hazard.patrolSpeed"))
        ];
    }

    private static void Validate(IReadOnlyList<WorkspaceSceneTexture> textures, IReadOnlyList<WorkspaceSceneObject> objects)
    {
        if (textures.Count is < 1 or > 4) throw Failure("Scene.textures must contain 1 to 4 entries.");
        var textureIds = new HashSet<uint>();
        foreach (var texture in textures)
        {
            if (texture.TextureId == 0 || !textureIds.Add(texture.TextureId)) throw Failure("Scene.textures textureId must be unique non-zero u32.");
            if (!WorkspaceProjectValidator.IsTextureArtifactPath(texture.Artifact)) throw Failure("Scene.textures artifact path is invalid.");
        }
        if (objects.Count is < MinObjectCount or > MaxObjectCount) throw Failure($"Scene.objects must contain {MinObjectCount} to {MaxObjectCount} entries.");
        var objectIds = new HashSet<string>(StringComparer.Ordinal);
        var playerCount = 0;
        var goalCount = 0;
        var hazardCount = 0;
        foreach (var sceneObject in objects)
        {
            if (!IsObjectId(sceneObject.ObjectId) || !objectIds.Add(sceneObject.ObjectId)) throw Failure("Scene ObjectId must be unique and match [a-z][a-z0-9_-]{0,62}.");
            ValidateVector(sceneObject.Position, 2, $"Scene.objects[{sceneObject.ObjectId}].position", positive: false, color: false);
            ValidateVector(sceneObject.Size, 2, $"Scene.objects[{sceneObject.ObjectId}].size", positive: true, color: false);
            ValidateVector(sceneObject.Color, 4, $"Scene.objects[{sceneObject.ObjectId}].color", positive: false, color: true);
            if (sceneObject.TextureId == 0 || !textureIds.Contains(sceneObject.TextureId)) throw Failure($"Scene.objects[{sceneObject.ObjectId}].textureId is not declared by Scene.textures.");
            switch (sceneObject.Kind)
            {
                case SpriteKind:
                case GoalKind:
                    if (sceneObject.MoveSpeed is not null || sceneObject.PatrolMinY is not null || sceneObject.PatrolMaxY is not null || sceneObject.PatrolSpeed is not null)
                        throw Failure($"Scene.objects[{sceneObject.ObjectId}] has an invalid kind payload.");
                    if (sceneObject.Kind == GoalKind) goalCount++;
                    break;
                case PlayerKind:
                    playerCount++;
                    if (sceneObject.MoveSpeed is null || !IsFiniteF32(sceneObject.MoveSpeed.Value) || sceneObject.MoveSpeed < 0
                        || sceneObject.PatrolMinY is not null || sceneObject.PatrolMaxY is not null || sceneObject.PatrolSpeed is not null)
                        throw Failure($"Scene.objects[{sceneObject.ObjectId}].player payload is invalid.");
                    break;
                case PatrolHazardKind:
                    hazardCount++;
                    if (sceneObject.MoveSpeed is not null || sceneObject.PatrolMinY is null || sceneObject.PatrolMaxY is null || sceneObject.PatrolSpeed is null
                        || !IsFiniteF32(sceneObject.PatrolMinY.Value) || !IsFiniteF32(sceneObject.PatrolMaxY.Value) || !IsFiniteF32(sceneObject.PatrolSpeed.Value)
                        || sceneObject.PatrolMinY >= sceneObject.PatrolMaxY || sceneObject.PatrolSpeed < 0
                        || sceneObject.Position[1] < sceneObject.PatrolMinY || sceneObject.Position[1] > sceneObject.PatrolMaxY)
                        throw Failure($"Scene.objects[{sceneObject.ObjectId}].patrol payload is invalid.");
                    break;
                default:
                    throw Failure($"Scene.objects[{sceneObject.ObjectId}].kind is unsupported: {sceneObject.Kind}.");
            }
        }
        if (playerCount != 1 || goalCount != 1 || hazardCount < 1) throw Failure("Scene must contain exactly one player, exactly one goal, and at least one patrol_hazard.");
    }

    private static IReadOnlyDictionary<string, JsonElement> ReadProperties(JsonElement value, string[] required, string[] optional, string owner)
    {
        RequireObject(value, owner);
        var allowed = required.Concat(optional).ToHashSet(StringComparer.Ordinal);
        var properties = new Dictionary<string, JsonElement>(StringComparer.Ordinal);
        foreach (var property in value.EnumerateObject())
        {
            if (!allowed.Contains(property.Name)) throw Failure($"{owner} contains an unsupported property: {property.Name}.");
            if (!properties.TryAdd(property.Name, property.Value)) throw Failure($"{owner} contains a duplicate property: {property.Name}.");
        }
        foreach (var name in required)
        {
            if (!properties.ContainsKey(name)) throw Failure($"{owner} is missing required property: {name}.");
        }
        return properties;
    }

    private static void RequireObject(JsonElement value, string owner)
    {
        if (value.ValueKind != JsonValueKind.Object) throw Failure($"{owner} must be an object.");
    }

    private static void RequireArray(JsonElement value, string owner)
    {
        if (value.ValueKind != JsonValueKind.Array) throw Failure($"{owner} must be an array.");
    }

    private static string RequireString(JsonElement value, string owner)
    {
        if (value.ValueKind != JsonValueKind.String || value.GetString() is not { Length: > 0 } result) throw Failure($"{owner} must be a non-empty string.");
        _ = StrictUtf8.GetBytes(result);
        return result;
    }

    private static int RequireInt32(JsonElement owner, string name, string context)
    {
        if (!owner.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.Number || !value.TryGetInt32(out var result)) throw Failure($"{context}.{name} must be an integer.");
        return result;
    }

    private static uint RequireUInt32(JsonElement value, string owner)
    {
        if (value.ValueKind != JsonValueKind.Number || !value.TryGetUInt32(out var result)) throw Failure($"{owner} must be a u32.");
        return result;
    }

    private static double RequireFiniteDouble(JsonElement value, string owner)
    {
        if (value.ValueKind != JsonValueKind.Number || !value.TryGetDouble(out var result) || !IsFiniteF32(result)) throw Failure($"{owner} must fit the finite f32 range.");
        return result;
    }

    private static double[] RequireVector(JsonElement value, int length, string owner)
    {
        RequireArray(value, owner);
        if (value.GetArrayLength() != length) throw Failure($"{owner} must contain exactly {length} numbers.");
        return value.EnumerateArray().Select((item, index) => RequireFiniteDouble(item, $"{owner}[{index}]")).ToArray();
    }

    private static double[] CopyVector(IReadOnlyList<double>? value, int length, string owner)
    {
        if (value is null || value.Count != length) throw Failure($"{owner} must contain exactly {length} numbers.");
        return value.ToArray();
    }

    private static void ValidateVector(IReadOnlyList<double> values, int length, string owner, bool positive, bool color)
    {
        if (values.Count != length || values.Any(value => !IsFiniteF32(value))) throw Failure($"{owner} must contain {length} finite f32 values.");
        if (positive && values.Any(value => value <= 0)) throw Failure($"{owner} values must be greater than zero.");
        if (color && values.Any(value => value is < 0 or > 1)) throw Failure($"{owner} values must be in the range [0, 1].");
    }

    private static bool IsObjectId(string value) => StrictUtf8.GetByteCount(value) is >= 1 and <= 63 && ObjectIdPattern().IsMatch(value);

    private static bool IsFiniteF32(double value) => double.IsFinite(value) && float.IsFinite((float)value);

    private static void WriteVector(Utf8JsonWriter writer, string name, IReadOnlyList<double> values)
    {
        writer.WritePropertyName(name);
        writer.WriteStartArray();
        foreach (var value in values) writer.WriteNumberValue(value);
        writer.WriteEndArray();
    }

    private static WorkspaceProjectValidationException Failure(string message, Exception? inner = null) =>
        new(WorkspaceProjectValidationFailureKind.Validation, message, inner);
}
