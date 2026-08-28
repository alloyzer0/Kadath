using System.Buffers;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Kadath.Editor.Protocol;

namespace Kadath.Editor.Workspace;

internal sealed record WorkspaceSceneTexture(
    uint TextureId,
    string Artifact,
    string SamplingProfile = WorkspaceSceneDocumentCodec.SmoothMipmapAnisotropicProfile);

internal sealed record WorkspaceSceneBehaviorParameter(string Name, double Value);

internal sealed record WorkspaceSceneBehaviorBinding(
    uint ScriptId,
    WorkspaceSceneBehaviorParameter[] Parameters);

internal sealed record WorkspaceSceneGameplay(string Profile, double TimeLimitSeconds)
{
    internal bool IsEnabled => Profile != WorkspaceSceneDocumentCodec.NoGameplayProfile;
}

internal sealed record WorkspaceScenePrototype(
    string PrototypeId,
    string Kind,
    double[] Size,
    double[] Color,
    uint TextureId,
    WorkspaceSceneBehaviorBinding[] Behaviors)
{
    internal ProjectModelScenePrototype ToProjectModel() => new(
        PrototypeId,
        Kind,
        Size.ToArray(),
        Color.ToArray(),
        TextureId,
        Behaviors.Select(binding => new ProjectModelSceneBehaviorBinding(
            binding.ScriptId,
            binding.Parameters.Select(parameter => new ProjectModelSceneBehaviorParameter(
                parameter.Name,
                parameter.Value)).ToArray())).ToArray());

    internal ScenePrototypeDefinition ToDefinition() => new(
        PrototypeId,
        Kind,
        Size.ToArray(),
        Color.ToArray(),
        TextureId,
        Behaviors.Select(binding => new SceneBehaviorBindingDefinition(
            binding.ScriptId,
            binding.Parameters.ToDictionary(
                parameter => parameter.Name,
                parameter => parameter.Value,
                StringComparer.Ordinal))).ToArray());
}

internal sealed record WorkspaceSceneTilemap(
    string TilemapId,
    double[] Origin,
    double[] TileSize,
    int Columns,
    int Rows,
    uint TextureId,
    int AtlasColumns,
    int AtlasRows,
    int[] Cells)
{
    internal ProjectModelSceneTilemap ToProjectModel() => new(
        TilemapId,
        Origin.ToArray(),
        TileSize.ToArray(),
        Columns,
        Rows,
        TextureId,
        AtlasColumns,
        AtlasRows,
        Cells.ToArray());

    internal SceneTilemapDefinition ToDefinition() => new(
        TilemapId,
        Origin.ToArray(),
        TileSize.ToArray(),
        Columns,
        Rows,
        TextureId,
        AtlasColumns,
        AtlasRows,
        Cells.ToArray());
}

internal sealed record WorkspaceSceneCamera(double[] Origin, double Zoom)
{
    internal ProjectModelSceneCamera ToProjectModel() => new(Origin.ToArray(), Zoom);
}

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
    double? PatrolSpeed = null,
    WorkspaceSceneBehaviorBinding[]? Behaviors = null)
{
    internal ProjectModelSceneObject ToProjectModel() => new(
        ObjectId, Kind, Position.ToArray(), Size.ToArray(), Color.ToArray(), TextureId,
        MoveSpeed, PatrolMinY, PatrolMaxY, PatrolSpeed,
        Behaviors?.Select(binding => new ProjectModelSceneBehaviorBinding(
            binding.ScriptId,
            binding.Parameters.Select(parameter => new ProjectModelSceneBehaviorParameter(parameter.Name, parameter.Value)).ToArray())).ToArray());

    internal SceneObjectDefinition ToDefinition() => new(
        ObjectId, Kind, Position.ToArray(), Size.ToArray(), Color.ToArray(), TextureId,
        MoveSpeed, PatrolMinY, PatrolMaxY, PatrolSpeed,
        Behaviors?.Select(binding => new SceneBehaviorBindingDefinition(
            binding.ScriptId,
            binding.Parameters.ToDictionary(parameter => parameter.Name, parameter => parameter.Value, StringComparer.Ordinal))).ToArray());
}

internal sealed record WorkspaceSceneDocument(
    int SourceSchemaVersion,
    WorkspaceSceneTexture[] Textures,
    WorkspaceSceneObject[] Objects,
    WorkspaceScenePrototype[] Prototypes,
    WorkspaceSceneGameplay Gameplay,
    WorkspaceSceneTilemap[] Tilemaps,
    WorkspaceSceneCamera Camera)
{
    internal WorkspaceSceneObject? Player => Objects.SingleOrDefault(value => value.Kind == WorkspaceSceneDocumentCodec.PlayerKind);
    internal WorkspaceSceneObject? Goal => Objects.SingleOrDefault(value => value.Kind == WorkspaceSceneDocumentCodec.GoalKind);
    internal WorkspaceSceneObject? PrimaryHazard => Objects.FirstOrDefault(value => value.Kind == WorkspaceSceneDocumentCodec.PatrolHazardKind);
}

internal static partial class WorkspaceSceneDocumentCodec
{
    internal const int LegacySchemaVersion = 4;
    internal const int BehaviorSchemaVersion = 5;
    internal const int PrototypeSchemaVersion = 6;
    internal const int GameplaySchemaVersion = 7;
    internal const int TilemapSchemaVersion = 8;
    internal const int CurrentSchemaVersion = 9;
    internal const int MinNeutralObjectCount = 1;
    internal const int MinObjectCount = 3;
    internal const int MaxObjectCount = 64;
    internal const int MaxBehaviorBindingsPerObject = 4;
    internal const int MaxBehaviorBindingCount = 256;
    internal const int MaxBehaviorParameterCount = 16;
    internal const int MaxBehaviorParameterNameBytes = 63;
    internal const int MaxPrototypeCount = 32;
    internal const int MaxPrototypeBehaviorBindingCount = 128;
    internal const int MaxTilemapCount = 1;
    internal const int MaxTilemapColumns = 32;
    internal const int MaxTilemapRows = 32;
    internal const int MaxTilemapCells = MaxTilemapColumns * MaxTilemapRows;
    internal const int MaxTilemapAtlasDimension = 256;
    internal const int MaxTilemapAtlasTiles = ushort.MaxValue;
    internal const string SpriteKind = "sprite";
    internal const string PlayerKind = "player";
    internal const string GoalKind = "goal";
    internal const string PatrolHazardKind = "patrol_hazard";
    internal const string NoGameplayProfile = "none";
    internal const string GoalHazardGameplayProfile = "goal_hazard_v1";
    internal const string PixelArtProfile = "pixel_art";
    internal const string SmoothLinearProfile = "smooth_linear";
    internal const string SmoothMipmapProfile = "smooth_mipmap";
    internal const string SmoothMipmapAnisotropicProfile = "smooth_mipmap_anisotropic";

    internal static readonly WorkspaceSceneGameplay NeutralGameplay = new(NoGameplayProfile, 0);
    internal static readonly WorkspaceSceneGameplay LegacyGameplay = new(GoalHazardGameplayProfile, 3);
    internal static readonly WorkspaceSceneCamera IdentityCamera = new([0, 0], 1);

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
                LegacySchemaVersion => ReadProperties(root, ["schemaVersion", "textures", "objects"], [], "Scene"),
                BehaviorSchemaVersion => ReadProperties(root, ["schemaVersion", "textures", "objects"], [], "Scene"),
                PrototypeSchemaVersion => ReadProperties(root, ["schemaVersion", "textures", "objects", "prototypes"], [], "Scene"),
                GameplaySchemaVersion => ReadProperties(root, ["schemaVersion", "textures", "objects", "prototypes"], ["gameplay"], "Scene"),
                TilemapSchemaVersion => ReadProperties(root, ["schemaVersion", "textures", "objects", "prototypes", "tilemaps"], ["gameplay"], "Scene"),
                CurrentSchemaVersion => ReadProperties(root, ["schemaVersion", "textures", "objects", "prototypes", "tilemaps", "camera"], ["gameplay"], "Scene"),
                _ => throw Failure("Unsupported Scene schemaVersion.")
            };
            var textures = ReadTextures(properties["textures"], schemaVersion >= TilemapSchemaVersion);
            var objects = schemaVersion == 3 ? ReadLegacyObjects(properties) : ReadObjects(properties["objects"], schemaVersion);
            var prototypes = schemaVersion >= PrototypeSchemaVersion
                ? ReadPrototypes(properties["prototypes"])
                : Array.Empty<WorkspaceScenePrototype>();
            // v4-v6 wire 没有 profile；读取时统一归一为旧演示 Gameplay。
            var gameplay = schemaVersion >= GameplaySchemaVersion
                ? properties.TryGetValue("gameplay", out var gameplayValue) ? ReadGameplay(gameplayValue) : NeutralGameplay
                : LegacyGameplay;
            var tilemaps = schemaVersion >= TilemapSchemaVersion
                ? ReadTilemaps(properties["tilemaps"])
                : Array.Empty<WorkspaceSceneTilemap>();
            var camera = schemaVersion == CurrentSchemaVersion ? ReadCamera(properties["camera"]) : IdentityCamera;
            Validate(textures, objects, prototypes, schemaVersion == 3 ? LegacySchemaVersion : schemaVersion, gameplay, tilemaps, camera);
            return new WorkspaceSceneDocument(schemaVersion, textures, objects, prototypes, gameplay, tilemaps, camera);
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

    internal static WorkspaceSceneObject[] NormalizeDefinitions(IReadOnlyList<SceneObjectDefinition> definitions, IReadOnlyList<WorkspaceSceneTexture> textures) =>
        NormalizeDefinitions(definitions, textures, LegacySchemaVersion);

    internal static WorkspaceSceneObject[] NormalizeDefinitions(
        IReadOnlyList<SceneObjectDefinition> definitions,
        IReadOnlyList<WorkspaceSceneTexture> textures,
        int schemaVersion)
        => NormalizeDefinitions(definitions, textures, schemaVersion, GameplayForSchema(schemaVersion));

    internal static WorkspaceSceneObject[] NormalizeDefinitions(
        IReadOnlyList<SceneObjectDefinition> definitions,
        IReadOnlyList<WorkspaceSceneTexture> textures,
        int schemaVersion,
        WorkspaceSceneGameplay gameplay)
    {
        var minimum = MinimumObjectCount(schemaVersion, gameplay);
        if (definitions.Count < minimum || definitions.Count > MaxObjectCount) throw Failure($"Scene.objects must contain {minimum} to {MaxObjectCount} entries.");
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
            value.PatrolSpeed,
            value.Behaviors?.Select(binding => new WorkspaceSceneBehaviorBinding(
                binding.ScriptId,
                binding.Parameters?.Select(parameter => new WorkspaceSceneBehaviorParameter(parameter.Key, parameter.Value)).ToArray()
                    ?? Array.Empty<WorkspaceSceneBehaviorParameter>())).ToArray())).ToArray();
        Validate(textures, objects, Array.Empty<WorkspaceScenePrototype>(), schemaVersion, gameplay);
        return objects;
    }

    internal static WorkspaceScenePrototype[] NormalizePrototypeDefinitions(
        IReadOnlyList<ScenePrototypeDefinition> definitions)
    {
        // 最终合法性由完整 Scene candidate 一次校验；这里仅完成 defensive copy 与结构归一化。
        return definitions.Select(value => new WorkspaceScenePrototype(
            value.PrototypeId,
            value.Kind,
            CopyVector(value.Size, 2, $"Scene.prototypes[{value.PrototypeId}].size"),
            CopyVector(value.Color, 4, $"Scene.prototypes[{value.PrototypeId}].color"),
            value.TextureId,
            value.Behaviors?.Select(binding => new WorkspaceSceneBehaviorBinding(
                binding.ScriptId,
                binding.Parameters?.Select(parameter => new WorkspaceSceneBehaviorParameter(
                    parameter.Key,
                parameter.Value)).ToArray() ?? [])).ToArray() ?? [])).ToArray();
    }

    internal static WorkspaceSceneTilemap[] NormalizeTilemapDefinitions(
        IReadOnlyList<SceneTilemapDefinition> definitions) =>
        definitions.Select(value => new WorkspaceSceneTilemap(
            value.TilemapId,
            CopyVector(value.Origin, 2, $"Scene.tilemaps[{value.TilemapId}].origin"),
            CopyVector(value.TileSize, 2, $"Scene.tilemaps[{value.TilemapId}].tileSize"),
            value.Columns,
            value.Rows,
            value.TextureId,
            value.AtlasColumns,
            value.AtlasRows,
            value.Cells.ToArray())).ToArray();

    internal static WorkspaceSceneCamera NormalizeCameraDefinition(SceneCameraDefinition definition) => new(
        CopyVector(definition.Origin, 2, "Scene.camera.origin"),
        definition.Zoom);

    internal static void ValidateNormalized(IReadOnlyList<WorkspaceSceneTexture> textures, IReadOnlyList<WorkspaceSceneObject> objects) =>
        Validate(textures, objects, Array.Empty<WorkspaceScenePrototype>(), LegacySchemaVersion, LegacyGameplay);

    internal static void ValidateNormalized(
        IReadOnlyList<WorkspaceSceneTexture> textures,
        IReadOnlyList<WorkspaceSceneObject> objects,
        int schemaVersion) =>
        Validate(textures, objects, Array.Empty<WorkspaceScenePrototype>(), schemaVersion, GameplayForSchema(schemaVersion));

    internal static void ValidateNormalized(
        IReadOnlyList<WorkspaceSceneTexture> textures,
        IReadOnlyList<WorkspaceSceneObject> objects,
        IReadOnlyList<WorkspaceScenePrototype> prototypes,
        int schemaVersion) =>
        Validate(textures, objects, prototypes, schemaVersion, GameplayForSchema(schemaVersion));

    internal static void ValidateNormalized(
        IReadOnlyList<WorkspaceSceneTexture> textures,
        IReadOnlyList<WorkspaceSceneObject> objects,
        IReadOnlyList<WorkspaceScenePrototype> prototypes,
        int schemaVersion,
        WorkspaceSceneGameplay gameplay) =>
        Validate(textures, objects, prototypes, schemaVersion, gameplay);

    internal static void ValidateNormalized(
        IReadOnlyList<WorkspaceSceneTexture> textures,
        IReadOnlyList<WorkspaceSceneObject> objects,
        IReadOnlyList<WorkspaceScenePrototype> prototypes,
        int schemaVersion,
        WorkspaceSceneGameplay gameplay,
        IReadOnlyList<WorkspaceSceneTilemap> tilemaps) =>
        Validate(textures, objects, prototypes, schemaVersion, gameplay, tilemaps, IdentityCamera);

    internal static void ValidateNormalized(
        IReadOnlyList<WorkspaceSceneTexture> textures,
        IReadOnlyList<WorkspaceSceneObject> objects,
        IReadOnlyList<WorkspaceScenePrototype> prototypes,
        int schemaVersion,
        WorkspaceSceneGameplay gameplay,
        IReadOnlyList<WorkspaceSceneTilemap> tilemaps,
        WorkspaceSceneCamera camera) =>
        Validate(textures, objects, prototypes, schemaVersion, gameplay, tilemaps, camera);

    internal static byte[] SerializeV4(IReadOnlyList<WorkspaceSceneTexture> textures, IReadOnlyList<WorkspaceSceneObject> objects)
        => Serialize(LegacySchemaVersion, textures, objects, Array.Empty<WorkspaceScenePrototype>(), LegacyGameplay);

    internal static byte[] SerializeV5(IReadOnlyList<WorkspaceSceneTexture> textures, IReadOnlyList<WorkspaceSceneObject> objects)
        => Serialize(BehaviorSchemaVersion, textures, objects, Array.Empty<WorkspaceScenePrototype>(), LegacyGameplay);

    internal static byte[] SerializeV6(
        IReadOnlyList<WorkspaceSceneTexture> textures,
        IReadOnlyList<WorkspaceSceneObject> objects,
        IReadOnlyList<WorkspaceScenePrototype> prototypes)
        => Serialize(PrototypeSchemaVersion, textures, objects, prototypes, LegacyGameplay);

    internal static byte[] SerializeV7(
        IReadOnlyList<WorkspaceSceneTexture> textures,
        IReadOnlyList<WorkspaceSceneObject> objects,
        IReadOnlyList<WorkspaceScenePrototype> prototypes,
        WorkspaceSceneGameplay gameplay)
        => Serialize(GameplaySchemaVersion, textures, objects, prototypes, gameplay);

    internal static byte[] SerializeV8(
        IReadOnlyList<WorkspaceSceneTexture> textures,
        IReadOnlyList<WorkspaceSceneObject> objects,
        IReadOnlyList<WorkspaceScenePrototype> prototypes,
        WorkspaceSceneGameplay gameplay,
        IReadOnlyList<WorkspaceSceneTilemap> tilemaps)
        => Serialize(TilemapSchemaVersion, textures, objects, prototypes, gameplay, tilemaps, IdentityCamera);

    internal static byte[] SerializeV9(
        IReadOnlyList<WorkspaceSceneTexture> textures,
        IReadOnlyList<WorkspaceSceneObject> objects,
        IReadOnlyList<WorkspaceScenePrototype> prototypes,
        WorkspaceSceneGameplay gameplay,
        IReadOnlyList<WorkspaceSceneTilemap> tilemaps,
        WorkspaceSceneCamera camera)
        => Serialize(CurrentSchemaVersion, textures, objects, prototypes, gameplay, tilemaps, camera);

    private static byte[] Serialize(
        int schemaVersion,
        IReadOnlyList<WorkspaceSceneTexture> textures,
        IReadOnlyList<WorkspaceSceneObject> objects,
        IReadOnlyList<WorkspaceScenePrototype> prototypes,
        WorkspaceSceneGameplay gameplay,
        IReadOnlyList<WorkspaceSceneTilemap>? tilemaps = null,
        WorkspaceSceneCamera? camera = null)
    {
        tilemaps ??= Array.Empty<WorkspaceSceneTilemap>();
        camera ??= IdentityCamera;
        Validate(textures, objects, prototypes, schemaVersion, gameplay, tilemaps, camera);
        var buffer = new ArrayBufferWriter<byte>();
        using (var writer = new Utf8JsonWriter(buffer, new JsonWriterOptions { Indented = true }))
        {
            writer.WriteStartObject();
            writer.WriteNumber("schemaVersion", schemaVersion);
            writer.WritePropertyName("textures");
            writer.WriteStartArray();
            foreach (var texture in textures)
            {
                writer.WriteStartObject();
                writer.WriteNumber("textureId", texture.TextureId);
                writer.WriteString("artifact", texture.Artifact);
                if (schemaVersion >= TilemapSchemaVersion) writer.WriteString("samplingProfile", texture.SamplingProfile);
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
                else if (schemaVersion == LegacySchemaVersion && sceneObject.Kind == PatrolHazardKind)
                {
                    writer.WritePropertyName("patrol");
                    writer.WriteStartObject();
                    writer.WriteNumber("minY", sceneObject.PatrolMinY!.Value);
                    writer.WriteNumber("maxY", sceneObject.PatrolMaxY!.Value);
                    writer.WriteNumber("speed", sceneObject.PatrolSpeed!.Value);
                    writer.WriteEndObject();
                }
                if (SchemaHasBehaviorBindings(schemaVersion))
                {
                    writer.WritePropertyName("behaviors");
                    writer.WriteStartArray();
                    foreach (var behavior in sceneObject.Behaviors ?? Array.Empty<WorkspaceSceneBehaviorBinding>())
                    {
                        writer.WriteStartObject();
                        writer.WriteNumber("scriptId", behavior.ScriptId);
                        writer.WritePropertyName("parameters");
                        writer.WriteStartObject();
                        foreach (var parameter in behavior.Parameters)
                        {
                            writer.WriteNumber(parameter.Name, parameter.Value);
                        }
                        writer.WriteEndObject();
                        writer.WriteEndObject();
                    }
                    writer.WriteEndArray();
                }
                writer.WriteEndObject();
            }
            writer.WriteEndArray();
            if (SchemaHasPrototypes(schemaVersion))
            {
                writer.WritePropertyName("prototypes");
                writer.WriteStartArray();
                foreach (var prototype in prototypes)
                {
                    writer.WriteStartObject();
                    writer.WriteString("prototypeId", prototype.PrototypeId);
                    writer.WriteString("kind", prototype.Kind);
                    writer.WritePropertyName("sprite");
                    writer.WriteStartObject();
                    WriteVector(writer, "size", prototype.Size);
                    WriteVector(writer, "color", prototype.Color);
                    writer.WriteNumber("textureId", prototype.TextureId);
                    writer.WriteEndObject();
                    WriteBehaviorBindings(writer, prototype.Behaviors);
                    writer.WriteEndObject();
                }
                writer.WriteEndArray();
            }
            if (schemaVersion >= GameplaySchemaVersion && gameplay.IsEnabled)
            {
                writer.WritePropertyName("gameplay");
                writer.WriteStartObject();
                writer.WriteString("profile", gameplay.Profile);
                writer.WriteNumber("timeLimitSeconds", gameplay.TimeLimitSeconds);
                writer.WriteEndObject();
            }
            if (schemaVersion >= TilemapSchemaVersion)
            {
                writer.WritePropertyName("tilemaps");
                writer.WriteStartArray();
                foreach (var tilemap in tilemaps)
                {
                    writer.WriteStartObject();
                    writer.WriteString("tilemapId", tilemap.TilemapId);
                    WriteVector(writer, "origin", tilemap.Origin);
                    WriteVector(writer, "tileSize", tilemap.TileSize);
                    writer.WriteNumber("columns", tilemap.Columns);
                    writer.WriteNumber("rows", tilemap.Rows);
                    writer.WriteNumber("textureId", tilemap.TextureId);
                    writer.WriteNumber("atlasColumns", tilemap.AtlasColumns);
                    writer.WriteNumber("atlasRows", tilemap.AtlasRows);
                    writer.WritePropertyName("cells");
                    writer.WriteStartArray();
                    foreach (var cell in tilemap.Cells) writer.WriteNumberValue(cell);
                    writer.WriteEndArray();
                    writer.WriteEndObject();
                }
                writer.WriteEndArray();
            }
            if (schemaVersion == CurrentSchemaVersion)
            {
                // v9 把 Camera2D 固定放在 Tilemap 之后，保持规范化输出稳定。
                writer.WritePropertyName("camera");
                writer.WriteStartObject();
                WriteVector(writer, "origin", camera.Origin);
                writer.WriteNumber("zoom", camera.Zoom);
                writer.WriteEndObject();
            }
            writer.WriteEndObject();
        }
        var bytes = new byte[buffer.WrittenCount + 1];
        buffer.WrittenSpan.CopyTo(bytes);
        bytes[^1] = (byte)'\n';
        if (bytes.Length > WorkspaceProjectValidator.MaxDocumentBytes) throw Failure("Scene exceeds the 64 KiB Runtime document budget.");
        return bytes;
    }

    private static WorkspaceSceneTexture[] ReadTextures(JsonElement value, bool readSamplingProfile)
    {
        RequireArray(value, "Scene.textures");
        if (value.GetArrayLength() is < 1 or > 4) throw Failure("Scene.textures must contain 1 to 4 entries.");
        var textures = new List<WorkspaceSceneTexture>();
        foreach (var element in value.EnumerateArray())
        {
            var properties = ReadProperties(
                element,
                readSamplingProfile ? ["textureId", "artifact", "samplingProfile"] : ["textureId", "artifact"],
                [],
                "Scene.textures[]");
            textures.Add(new WorkspaceSceneTexture(
                RequireUInt32(properties["textureId"], "Scene.textures[].textureId"),
                RequireString(properties["artifact"], "Scene.textures[].artifact"),
                readSamplingProfile
                    ? RequireString(properties["samplingProfile"], "Scene.textures[].samplingProfile")
                    : SmoothMipmapAnisotropicProfile));
        }
        return textures.ToArray();
    }

    private static WorkspaceSceneObject[] ReadObjects(JsonElement value, int schemaVersion)
    {
        RequireArray(value, "Scene.objects");
        var minimum = schemaVersion >= GameplaySchemaVersion ? MinNeutralObjectCount : MinObjectCount;
        if (value.GetArrayLength() < minimum || value.GetArrayLength() > MaxObjectCount) throw Failure($"Scene.objects must contain {minimum} to {MaxObjectCount} entries.");
        var objects = new List<WorkspaceSceneObject>();
        var index = 0;
        foreach (var element in value.EnumerateArray())
        {
            var owner = $"Scene.objects[{index}]";
            var properties = SchemaHasBehaviorBindings(schemaVersion)
                ? ReadProperties(element, ["objectId", "kind", "transform", "sprite", "behaviors"], ["player"], owner)
                : ReadProperties(element, ["objectId", "kind", "transform", "sprite"], ["player", "patrol"], owner);
            var objectId = RequireString(properties["objectId"], $"{owner}.objectId");
            var kind = RequireString(properties["kind"], $"{owner}.kind");
            var transform = ReadProperties(properties["transform"], ["position"], [], $"{owner}.transform");
            var sprite = ReadProperties(properties["sprite"], ["size", "color", "textureId"], [], $"{owner}.sprite");
            double? moveSpeed = null;
            double? patrolMinY = null;
            double? patrolMaxY = null;
            double? patrolSpeed = null;
            var behaviors = SchemaHasBehaviorBindings(schemaVersion)
                ? ReadBehaviorBindings(properties["behaviors"], owner)
                : Array.Empty<WorkspaceSceneBehaviorBinding>();
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
                    if (properties.ContainsKey("player")) throw Failure($"{owner} has an invalid player payload.");
                    if (!SchemaHasBehaviorBindings(schemaVersion))
                    {
                        if (!properties.TryGetValue("patrol", out var patrol)) throw Failure($"{owner} must contain patrol payload.");
                        var patrolProperties = ReadProperties(patrol, ["minY", "maxY", "speed"], [], $"{owner}.patrol");
                        patrolMinY = RequireFiniteDouble(patrolProperties["minY"], $"{owner}.patrol.minY");
                        patrolMaxY = RequireFiniteDouble(patrolProperties["maxY"], $"{owner}.patrol.maxY");
                        patrolSpeed = RequireFiniteDouble(patrolProperties["speed"], $"{owner}.patrol.speed");
                    }
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
                patrolSpeed,
                behaviors));
            index++;
        }
        return objects.ToArray();
    }

    private static WorkspaceScenePrototype[] ReadPrototypes(JsonElement value)
    {
        RequireArray(value, "Scene.prototypes");
        if (value.GetArrayLength() > MaxPrototypeCount) throw Failure($"Scene.prototypes exceeds the {MaxPrototypeCount} prototype limit.");
        var prototypes = new List<WorkspaceScenePrototype>();
        var index = 0;
        foreach (var element in value.EnumerateArray())
        {
            var owner = $"Scene.prototypes[{index}]";
            var properties = ReadProperties(element, ["prototypeId", "kind", "sprite", "behaviors"], [], owner);
            var sprite = ReadProperties(properties["sprite"], ["size", "color", "textureId"], [], $"{owner}.sprite");
            prototypes.Add(new WorkspaceScenePrototype(
                RequireString(properties["prototypeId"], $"{owner}.prototypeId"),
                RequireString(properties["kind"], $"{owner}.kind"),
                RequireVector(sprite["size"], 2, $"{owner}.sprite.size"),
                RequireVector(sprite["color"], 4, $"{owner}.sprite.color"),
                RequireUInt32(sprite["textureId"], $"{owner}.sprite.textureId"),
                ReadBehaviorBindings(properties["behaviors"], owner)));
            index++;
        }
        return prototypes.ToArray();
    }

    private static WorkspaceSceneTilemap[] ReadTilemaps(JsonElement value)
    {
        RequireArray(value, "Scene.tilemaps");
        if (value.GetArrayLength() > MaxTilemapCount) throw Failure("Scene.tilemaps exceeds the single-layer limit.");
        var tilemaps = new List<WorkspaceSceneTilemap>();
        var index = 0;
        foreach (var element in value.EnumerateArray())
        {
            var owner = $"Scene.tilemaps[{index}]";
            var properties = ReadProperties(element,
                ["tilemapId", "origin", "tileSize", "columns", "rows", "textureId", "atlasColumns", "atlasRows", "cells"],
                [], owner);
            var cellsElement = properties["cells"];
            RequireArray(cellsElement, $"{owner}.cells");
            var cells = new List<int>();
            foreach (var cell in cellsElement.EnumerateArray())
            {
                if (cell.ValueKind != JsonValueKind.Number || !cell.TryGetInt32(out var cellValue))
                    throw Failure($"{owner}.cells must contain integer Tile indices.");
                cells.Add(cellValue);
            }
            tilemaps.Add(new WorkspaceSceneTilemap(
                RequireString(properties["tilemapId"], $"{owner}.tilemapId"),
                RequireVector(properties["origin"], 2, $"{owner}.origin"),
                RequireVector(properties["tileSize"], 2, $"{owner}.tileSize"),
                RequireInt32(element, "columns", owner),
                RequireInt32(element, "rows", owner),
                RequireUInt32(properties["textureId"], $"{owner}.textureId"),
                RequireInt32(element, "atlasColumns", owner),
                RequireInt32(element, "atlasRows", owner),
                cells.ToArray()));
            index++;
        }
        return tilemaps.ToArray();
    }

    private static WorkspaceSceneCamera ReadCamera(JsonElement value)
    {
        var properties = ReadProperties(value, ["origin", "zoom"], [], "Scene.camera");
        return new WorkspaceSceneCamera(
            RequireVector(properties["origin"], 2, "Scene.camera.origin"),
            RequireFiniteDouble(properties["zoom"], "Scene.camera.zoom"));
    }

    private static WorkspaceSceneGameplay ReadGameplay(JsonElement value)
    {
        var properties = ReadProperties(value, ["profile", "timeLimitSeconds"], [], "Scene.gameplay");
        return new WorkspaceSceneGameplay(
            RequireString(properties["profile"], "Scene.gameplay.profile"),
            RequireFiniteDouble(properties["timeLimitSeconds"], "Scene.gameplay.timeLimitSeconds"));
    }

    private static WorkspaceSceneBehaviorBinding[] ReadBehaviorBindings(JsonElement value, string owner)
    {
        RequireArray(value, $"{owner}.behaviors");
        if (value.GetArrayLength() > MaxBehaviorBindingsPerObject)
            throw Failure($"{owner}.behaviors exceeds the {MaxBehaviorBindingsPerObject} binding limit.");
        var bindings = new List<WorkspaceSceneBehaviorBinding>();
        var scriptIds = new HashSet<uint>();
        var index = 0;
        foreach (var element in value.EnumerateArray())
        {
            var bindingOwner = $"{owner}.behaviors[{index}]";
            var properties = ReadProperties(element, ["scriptId", "parameters"], [], bindingOwner);
            var scriptId = RequireUInt32(properties["scriptId"], $"{bindingOwner}.scriptId");
            if (scriptId == 0 || !scriptIds.Add(scriptId)) throw Failure($"{bindingOwner}.scriptId must be unique and non-zero.");
            RequireObject(properties["parameters"], $"{bindingOwner}.parameters");
            var parameters = new List<WorkspaceSceneBehaviorParameter>();
            foreach (var parameter in properties["parameters"].EnumerateObject())
            {
                if (parameters.Count >= MaxBehaviorParameterCount) throw Failure($"{bindingOwner}.parameters exceeds the {MaxBehaviorParameterCount} parameter limit.");
                if (!IsBehaviorParameterName(parameter.Name)) throw Failure($"{bindingOwner}.parameters contains an invalid parameter name: {parameter.Name}.");
                parameters.Add(new WorkspaceSceneBehaviorParameter(
                    parameter.Name,
                    RequireFiniteNumber(parameter.Value, $"{bindingOwner}.parameters.{parameter.Name}")));
            }
            bindings.Add(new WorkspaceSceneBehaviorBinding(scriptId, parameters.ToArray()));
            index++;
        }
        return bindings.ToArray();
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

    private static void Validate(
        IReadOnlyList<WorkspaceSceneTexture> textures,
        IReadOnlyList<WorkspaceSceneObject> objects,
        IReadOnlyList<WorkspaceScenePrototype> prototypes,
        int schemaVersion,
        WorkspaceSceneGameplay gameplay) =>
        Validate(textures, objects, prototypes, schemaVersion, gameplay, Array.Empty<WorkspaceSceneTilemap>(), IdentityCamera);

    private static void Validate(
        IReadOnlyList<WorkspaceSceneTexture> textures,
        IReadOnlyList<WorkspaceSceneObject> objects,
        IReadOnlyList<WorkspaceScenePrototype> prototypes,
        int schemaVersion,
        WorkspaceSceneGameplay gameplay,
        IReadOnlyList<WorkspaceSceneTilemap> tilemaps,
        WorkspaceSceneCamera camera)
    {
        if (schemaVersion is not (LegacySchemaVersion or BehaviorSchemaVersion or PrototypeSchemaVersion or GameplaySchemaVersion or TilemapSchemaVersion or CurrentSchemaVersion)) throw Failure("Unsupported Scene schemaVersion.");
        if (schemaVersion < GameplaySchemaVersion && gameplay.Profile != GoalHazardGameplayProfile)
            throw Failure("Scene v4-v6 must normalize to goal_hazard_v1 Gameplay.");
        if (gameplay.Profile == NoGameplayProfile)
        {
            if (gameplay.TimeLimitSeconds != 0) throw Failure("Scene.gameplay.timeLimitSeconds must be zero when Gameplay is disabled.");
        }
        else if (gameplay.Profile == GoalHazardGameplayProfile)
        {
            if (!IsFiniteF32(gameplay.TimeLimitSeconds) || gameplay.TimeLimitSeconds <= 0)
                throw Failure("Scene.gameplay.timeLimitSeconds must be a positive finite f32 value.");
        }
        else
        {
            throw Failure($"Scene.gameplay.profile is unsupported: {gameplay.Profile}.");
        }
        if (textures.Count is < 1 or > 4) throw Failure("Scene.textures must contain 1 to 4 entries.");
        var textureIds = new HashSet<uint>();
        foreach (var texture in textures)
        {
            if (texture.TextureId == 0 || !textureIds.Add(texture.TextureId)) throw Failure("Scene.textures textureId must be unique non-zero u32.");
            if (!WorkspaceProjectValidator.IsTextureArtifactPath(texture.Artifact)) throw Failure("Scene.textures artifact path is invalid.");
            if (!IsSamplingProfile(texture.SamplingProfile)) throw Failure("Scene.textures samplingProfile is invalid.");
            if (schemaVersion < TilemapSchemaVersion && texture.SamplingProfile != SmoothMipmapAnisotropicProfile)
                throw Failure("Scene v4-v7 textures must preserve the legacy sampling profile.");
        }
        var minimum = MinimumObjectCount(schemaVersion, gameplay);
        if (objects.Count < minimum || objects.Count > MaxObjectCount) throw Failure($"Scene.objects must contain {minimum} to {MaxObjectCount} entries.");
        var objectIds = new HashSet<string>(StringComparer.Ordinal);
        var playerCount = 0;
        var goalCount = 0;
        var hazardCount = 0;
        var behaviorBindingCount = 0;
        foreach (var sceneObject in objects)
        {
            if (!IsObjectId(sceneObject.ObjectId) || !objectIds.Add(sceneObject.ObjectId)) throw Failure("Scene ObjectId must be unique and match [a-z][a-z0-9_-]{0,62}.");
            ValidateVector(sceneObject.Position, 2, $"Scene.objects[{sceneObject.ObjectId}].position", positive: false, color: false);
            ValidateVector(sceneObject.Size, 2, $"Scene.objects[{sceneObject.ObjectId}].size", positive: true, color: false);
            ValidateVector(sceneObject.Color, 4, $"Scene.objects[{sceneObject.ObjectId}].color", positive: false, color: true);
            if (sceneObject.TextureId == 0 || !textureIds.Contains(sceneObject.TextureId)) throw Failure($"Scene.objects[{sceneObject.ObjectId}].textureId is not declared by Scene.textures.");
            var behaviors = sceneObject.Behaviors ?? Array.Empty<WorkspaceSceneBehaviorBinding>();
            if (schemaVersion == LegacySchemaVersion && behaviors.Length != 0)
                throw Failure($"Scene.objects[{sceneObject.ObjectId}] cannot contain behavior bindings in schema v4.");
            if (SchemaHasBehaviorBindings(schemaVersion))
            {
                ValidateBehaviorBindings(behaviors, sceneObject.ObjectId);
                behaviorBindingCount = checked(behaviorBindingCount + behaviors.Length);
                if (behaviorBindingCount > MaxBehaviorBindingCount) throw Failure("Scene behavior binding budget exceeded.");
            }
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
                    if (sceneObject.MoveSpeed is not null) throw Failure($"Scene.objects[{sceneObject.ObjectId}] has an invalid player payload.");
                    if (schemaVersion == LegacySchemaVersion)
                    {
                        if (sceneObject.PatrolMinY is null || sceneObject.PatrolMaxY is null || sceneObject.PatrolSpeed is null
                            || !IsFiniteF32(sceneObject.PatrolMinY.Value) || !IsFiniteF32(sceneObject.PatrolMaxY.Value) || !IsFiniteF32(sceneObject.PatrolSpeed.Value)
                            || sceneObject.PatrolMinY >= sceneObject.PatrolMaxY || sceneObject.PatrolSpeed < 0
                            || sceneObject.Position[1] < sceneObject.PatrolMinY || sceneObject.Position[1] > sceneObject.PatrolMaxY)
                            throw Failure($"Scene.objects[{sceneObject.ObjectId}].patrol payload is invalid.");
                    }
                    else if (sceneObject.PatrolMinY is not null || sceneObject.PatrolMaxY is not null || sceneObject.PatrolSpeed is not null
                        || gameplay.IsEnabled && behaviors.Length == 0)
                    {
                        throw Failure($"Scene.objects[{sceneObject.ObjectId}] must use behavior bindings instead of native patrol payload.");
                    }
                    break;
                default:
                    throw Failure($"Scene.objects[{sceneObject.ObjectId}].kind is unsupported: {sceneObject.Kind}.");
            }
        }
        if (gameplay.IsEnabled && (playerCount != 1 || goalCount != 1 || hazardCount < 1))
            throw Failure("Gameplay Scene must contain exactly one player, exactly one goal, and at least one patrol_hazard.");
        if (!SchemaHasPrototypes(schemaVersion) && prototypes.Count != 0) throw Failure("Scene prototypes require schema v6 or later.");
        if (prototypes.Count > MaxPrototypeCount) throw Failure("Scene prototype budget exceeded.");
        var prototypeIds = new HashSet<string>(StringComparer.Ordinal);
        var prototypeBehaviorCount = 0;
        foreach (var prototype in prototypes)
        {
            if (!IsObjectId(prototype.PrototypeId) || !prototypeIds.Add(prototype.PrototypeId)) throw Failure("Scene PrototypeId must be unique and valid.");
            if (prototype.Kind != SpriteKind) throw Failure($"Scene.prototypes[{prototype.PrototypeId}].kind must be sprite.");
            ValidateVector(prototype.Size, 2, $"Scene.prototypes[{prototype.PrototypeId}].size", positive: true, color: false);
            ValidateVector(prototype.Color, 4, $"Scene.prototypes[{prototype.PrototypeId}].color", positive: false, color: true);
            if (prototype.TextureId == 0 || !textureIds.Contains(prototype.TextureId)) throw Failure($"Scene.prototypes[{prototype.PrototypeId}].textureId is not declared by Scene.textures.");
            ValidateBehaviorBindings(prototype.Behaviors, prototype.PrototypeId);
            prototypeBehaviorCount = checked(prototypeBehaviorCount + prototype.Behaviors.Length);
            if (prototypeBehaviorCount > MaxPrototypeBehaviorBindingCount) throw Failure("Scene prototype behavior binding budget exceeded.");
        }
        if (schemaVersion < TilemapSchemaVersion && tilemaps.Count != 0) throw Failure("Scene tilemaps require schema v8 or later.");
        if (tilemaps.Count > MaxTilemapCount) throw Failure("Scene.tilemaps exceeds the single-layer limit.");
        var tilemapIds = new HashSet<string>(StringComparer.Ordinal);
        foreach (var tilemap in tilemaps)
        {
            var owner = $"Scene.tilemaps[{tilemap.TilemapId}]";
            if (!IsObjectId(tilemap.TilemapId) || !tilemapIds.Add(tilemap.TilemapId)) throw Failure("Scene TilemapId must be unique and valid.");
            ValidateVector(tilemap.Origin, 2, $"{owner}.origin", positive: false, color: false);
            ValidateVector(tilemap.TileSize, 2, $"{owner}.tileSize", positive: true, color: false);
            if (tilemap.Columns is < 1 or > MaxTilemapColumns || tilemap.Rows is < 1 or > MaxTilemapRows)
                throw Failure($"{owner} dimensions exceed the 32x32 limit.");
            if (tilemap.AtlasColumns is < 1 or > MaxTilemapAtlasDimension || tilemap.AtlasRows is < 1 or > MaxTilemapAtlasDimension)
                throw Failure($"{owner} Atlas dimensions are invalid.");
            var atlasTiles = checked(tilemap.AtlasColumns * tilemap.AtlasRows);
            if (atlasTiles > MaxTilemapAtlasTiles) throw Failure($"{owner} Atlas exceeds the u16 Tile index limit.");
            if (tilemap.Cells.Length != checked(tilemap.Columns * tilemap.Rows)) throw Failure($"{owner}.cells length does not match rows*columns.");
            if (tilemap.Cells.Any(cell => cell < 0 || cell > atlasTiles)) throw Failure($"{owner}.cells contains an invalid Atlas Tile index.");
            var texture = textures.SingleOrDefault(value => value.TextureId == tilemap.TextureId)
                ?? throw Failure($"{owner}.textureId is not declared by Scene.textures.");
            if (texture.SamplingProfile != PixelArtProfile) throw Failure($"{owner} Atlas texture must use pixel_art sampling.");
        }
        ValidateVector(camera.Origin, 2, "Scene.camera.origin", positive: false, color: false);
        if (!IsFiniteF32(camera.Zoom) || camera.Zoom is < 0.125 or > 8)
            throw Failure("Scene.camera.zoom must be a finite f32 value in [0.125, 8].");
        if (schemaVersion != CurrentSchemaVersion
            && (!camera.Origin.SequenceEqual(IdentityCamera.Origin) || camera.Zoom != IdentityCamera.Zoom))
            throw Failure("Non-identity Scene camera requires schema v9.");
    }

    private static WorkspaceSceneGameplay GameplayForSchema(int schemaVersion) =>
        schemaVersion >= GameplaySchemaVersion ? NeutralGameplay : LegacyGameplay;

    private static int MinimumObjectCount(int schemaVersion, WorkspaceSceneGameplay gameplay) =>
        schemaVersion >= GameplaySchemaVersion && !gameplay.IsEnabled ? MinNeutralObjectCount : MinObjectCount;

    private static bool SchemaHasBehaviorBindings(int schemaVersion) => schemaVersion >= BehaviorSchemaVersion;

    private static bool SchemaHasPrototypes(int schemaVersion) => schemaVersion >= PrototypeSchemaVersion;

    private static bool IsSamplingProfile(string profile) =>
        profile is PixelArtProfile or SmoothLinearProfile or SmoothMipmapProfile or SmoothMipmapAnisotropicProfile;

    private static void WriteBehaviorBindings(Utf8JsonWriter writer, IReadOnlyList<WorkspaceSceneBehaviorBinding> behaviors)
    {
        writer.WritePropertyName("behaviors");
        writer.WriteStartArray();
        foreach (var behavior in behaviors)
        {
            writer.WriteStartObject();
            writer.WriteNumber("scriptId", behavior.ScriptId);
            writer.WritePropertyName("parameters");
            writer.WriteStartObject();
            foreach (var parameter in behavior.Parameters) writer.WriteNumber(parameter.Name, parameter.Value);
            writer.WriteEndObject();
            writer.WriteEndObject();
        }
        writer.WriteEndArray();
    }

    private static void ValidateBehaviorBindings(IReadOnlyList<WorkspaceSceneBehaviorBinding> behaviors, string objectId)
    {
        if (behaviors.Count > MaxBehaviorBindingsPerObject) throw Failure($"Scene.objects[{objectId}].behaviors exceeds the binding limit.");
        var scriptIds = new HashSet<uint>();
        foreach (var binding in behaviors)
        {
            if (binding.ScriptId == 0 || !scriptIds.Add(binding.ScriptId)) throw Failure($"Scene.objects[{objectId}].behaviors scriptId must be unique and non-zero.");
            if (binding.Parameters.Length > MaxBehaviorParameterCount) throw Failure($"Scene.objects[{objectId}].behaviors parameter budget exceeded.");
            var parameterNames = new HashSet<string>(StringComparer.Ordinal);
            foreach (var parameter in binding.Parameters)
            {
                if (!IsBehaviorParameterName(parameter.Name) || !parameterNames.Add(parameter.Name) || !double.IsFinite(parameter.Value))
                    throw Failure($"Scene.objects[{objectId}].behaviors contains an invalid parameter.");
            }
        }
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

    private static double RequireFiniteNumber(JsonElement value, string owner)
    {
        if (value.ValueKind != JsonValueKind.Number || !value.TryGetDouble(out var result) || !double.IsFinite(result))
            throw Failure($"{owner} must be a finite number.");
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

    private static bool IsBehaviorParameterName(string value)
    {
        if (Encoding.UTF8.GetByteCount(value) is < 1 or > MaxBehaviorParameterNameBytes || !IsIdentifierStart(value[0])) return false;
        return value.Skip(1).All(character => IsIdentifierStart(character) || character is >= '0' and <= '9');
    }

    private static bool IsIdentifierStart(char value) => value is >= 'A' and <= 'Z' or >= 'a' and <= 'z' or '_';

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
