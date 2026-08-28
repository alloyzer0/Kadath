using System.Text.Json;

namespace Kadath.Editor.Workspace;

/// <summary>Tiled JSON 1.12 Adapter；所有 GID 语义在进入规范资产前完成拆解。</summary>
internal static class TiledMapImportAdapter
{
    private const uint FlipHorizontal = 0x8000_0000;
    private const uint FlipVertical = 0x4000_0000;
    private const uint FlipDiagonal = 0x2000_0000;
    private const uint RotateHex120 = 0x1000_0000;
    private const uint GidMask = 0x0FFF_FFFF;

    internal static WorkspaceMapImportResult Import(string sourcePath, WorkspaceMapImportRequest request)
    {
        var warnings = new List<WorkspaceMapImportDiagnostic>();
        var documents = new HashSet<string>(StringComparer.Ordinal) { sourcePath };
        try
        {
            using var document = JsonDocument.Parse(WorkspaceMapImport.ReadSource(sourcePath), new JsonDocumentOptions
            {
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow,
                MaxDepth = 64
            });
            var root = document.RootElement;
            RequireObject(root, sourcePath, "$");
            if (RequireString(root, "type", sourcePath, "$") != "map")
                throw Error("TILED_INVALID_ROOT", "Tiled 根对象 type 必须是 map。", sourcePath, "$.type");
            var version = RequireString(root, "version", sourcePath, "$");
            if (version != "1.12") throw Error("TILED_UNSUPPORTED_VERSION", $"仅支持 Tiled JSON format 1.12，实际为 {version}。", sourcePath, "$.version");
            if (RequireString(root, "orientation", sourcePath, "$") != "orthogonal")
                throw Error("TILED_UNSUPPORTED_ORIENTATION", "首版只支持 orthogonal Tiled 地图。", sourcePath, "$.orientation");
            if (GetString(root, "renderorder", "right-down", sourcePath, "$") != "right-down")
                throw Error("TILED_UNSUPPORTED_RENDER_ORDER", "首版只支持 right-down renderorder。", sourcePath, "$.renderorder");
            var tileWidth = RequirePositiveInt(root, "tilewidth", sourcePath, "$");
            var tileHeight = RequirePositiveInt(root, "tileheight", sourcePath, "$");
            WarnProperties(root, sourcePath, "$", warnings, "TILED_PROPERTIES_NOT_CONSUMED");

            var rootDirectory = Path.GetDirectoryName(sourcePath)!;
            var tilesetArray = RequireArray(root, "tilesets", sourcePath, "$");
            if (tilesetArray.GetArrayLength() is < 1 or > WorkspaceTilemapAssetCodec.MaxTileSources)
                throw Error("IMPORT_TILE_SOURCE_BUDGET", $"Tiled Tileset 数必须为 1..{WorkspaceTilemapAssetCodec.MaxTileSources}。", sourcePath, "$.tilesets");
            if (request.TextureIds.Count != tilesetArray.GetArrayLength() || request.TextureIds.Any(value => value == 0))
                throw Error("IMPORT_TEXTURE_BINDING_MISMATCH", "TextureIds 必须按 Tiled Tileset 顺序提供一一对应的非零 TextureId。", sourcePath, "$.tilesets");

            var tilesets = new List<TiledTileset>();
            var ordinal = 0;
            foreach (var reference in tilesetArray.EnumerateArray())
            {
                var path = $"$.tilesets[{ordinal}]";
                RequireObject(reference, sourcePath, path);
                var firstGid = RequirePositiveUInt(reference, "firstgid", sourcePath, path);
                if (tilesets.Count != 0 && firstGid <= tilesets[^1].FirstGid)
                    throw Error("TILED_INVALID_TILESET_RANGE", "Tiled firstgid 必须严格递增。", sourcePath, $"{path}.firstgid");
                JsonDocument? external = null;
                var tilesetDocument = sourcePath;
                JsonElement definition;
                if (reference.TryGetProperty("source", out var sourceValue))
                {
                    if (sourceValue.ValueKind != JsonValueKind.String || sourceValue.GetString() is not { Length: > 0 } relative)
                        throw Error("IMPORT_INVALID_EXTERNAL_REFERENCE", "Tiled Tileset source 必须是非空字符串。", sourcePath, $"{path}.source");
                    tilesetDocument = WorkspaceMapImport.ResolveReference(rootDirectory, sourcePath, relative, ".tsj", ".json");
                    documents.Add(tilesetDocument);
                    external = JsonDocument.Parse(WorkspaceMapImport.ReadSource(tilesetDocument), new JsonDocumentOptions
                    {
                        AllowTrailingCommas = false,
                        CommentHandling = JsonCommentHandling.Disallow,
                        MaxDepth = 64
                    });
                    definition = external.RootElement;
                    RequireObject(definition, tilesetDocument, "$");
                    if (RequireString(definition, "type", tilesetDocument, "$") != "tileset")
                        throw Error("TILED_INVALID_TILESET", "外部 TSJ type 必须是 tileset。", tilesetDocument, "$.type");
                }
                else
                {
                    definition = reference;
                }

                try
                {
                    var name = RequireString(definition, "name", tilesetDocument, "$");
                    var sourceTileWidth = RequirePositiveInt(definition, "tilewidth", tilesetDocument, "$");
                    var sourceTileHeight = RequirePositiveInt(definition, "tileheight", tilesetDocument, "$");
                    if (sourceTileWidth != tileWidth || sourceTileHeight != tileHeight)
                        throw Error("TILED_UNSUPPORTED_TILE_GEOMETRY", "Tileset Tile 尺寸必须与 Map 网格一致。", tilesetDocument, "$");
                    var tileCount = RequirePositiveInt(definition, "tilecount", tilesetDocument, "$");
                    var columns = RequirePositiveInt(definition, "columns", tilesetDocument, "$");
                    var rows = checked((tileCount + columns - 1) / columns);
                    var margin = GetNonNegativeInt(definition, "margin", 0, tilesetDocument, "$");
                    var spacing = GetNonNegativeInt(definition, "spacing", 0, tilesetDocument, "$");
                    if (definition.TryGetProperty("tiles", out var tileDefinitions) && tileDefinitions.ValueKind != JsonValueKind.Array)
                        throw Error("TILED_INVALID_TILESET", "Tileset tiles 必须是数组。", tilesetDocument, "$.tiles");
                    if (!definition.TryGetProperty("image", out var imageValue) || imageValue.ValueKind != JsonValueKind.String || imageValue.GetString() is not { Length: > 0 } image)
                        throw Error("TILED_UNSUPPORTED_IMAGE_COLLECTION", "首版只支持单 atlas image Tileset。", tilesetDocument, "$.image");
                    _ = WorkspaceMapImport.ResolveReference(rootDirectory, tilesetDocument, image, ".png", ".ppm");
                    var imageWidth = RequirePositiveInt(definition, "imagewidth", tilesetDocument, "$");
                    var imageHeight = RequirePositiveInt(definition, "imageheight", tilesetDocument, "$");
                    RejectTileGeometryOptions(definition, tilesetDocument);
                    WarnProperties(definition, tilesetDocument, "$", warnings, "TILED_PROPERTIES_NOT_CONSUMED");
                    if (definition.TryGetProperty("wangsets", out var wangsets) && wangsets.ValueKind == JsonValueKind.Array && wangsets.GetArrayLength() != 0)
                        warnings.Add(Warning("TILED_AUTHORING_METADATA_NOT_CONSUMED", tilesetDocument, "$.wangsets", "Terrain/Wang 编辑元数据未导入。"));

                    var animated = new HashSet<uint>();
                    if (definition.TryGetProperty("tiles", out tileDefinitions))
                    {
                        var tileOrdinal = 0;
                        foreach (var tile in tileDefinitions.EnumerateArray())
                        {
                            var tilePath = $"$.tiles[{tileOrdinal}]";
                            var id = RequireUInt(tile, "id", tilesetDocument, tilePath);
                            if (id >= tileCount) throw Error("TILED_INVALID_TILESET", "Tile definition ID 超过 tilecount。", tilesetDocument, $"{tilePath}.id");
                            if (tile.TryGetProperty("image", out _))
                                throw Error("TILED_UNSUPPORTED_IMAGE_COLLECTION", "Tile 独立 image 不受支持。", tilesetDocument, $"{tilePath}.image");
                            if (tile.TryGetProperty("animation", out var animation) && animation.ValueKind == JsonValueKind.Array && animation.GetArrayLength() != 0)
                                animated.Add(id);
                            if (tile.TryGetProperty("objectgroup", out var collision) && collision.ValueKind == JsonValueKind.Object)
                                warnings.Add(Warning("TILED_COLLISION_NOT_BAKED", tilesetDocument, $"{tilePath}.objectgroup", "Tile collision 未 Bake 到 Runtime Core。"));
                            WarnProperties(tile, tilesetDocument, tilePath, warnings, "TILED_PROPERTIES_NOT_CONSUMED");
                            tileOrdinal++;
                        }
                    }
                    tilesets.Add(new TiledTileset(
                        firstGid,
                        checked((uint)tileCount),
                        animated,
                        new WorkspaceTileSource(
                            WorkspaceMapImport.StableId("tiled-set", $"{ordinal}-{name}"),
                            request.TextureIds[ordinal],
                            tileWidth,
                            tileHeight,
                            imageWidth,
                            imageHeight,
                            columns,
                            rows,
                            margin,
                            spacing)));
                }
                finally
                {
                    external?.Dispose();
                }
                ordinal++;
            }

            var layers = new List<WorkspaceTileLayer>();
            var layerIds = new HashSet<string>(StringComparer.Ordinal);
            var rootLayers = RequireArray(root, "layers", sourcePath, "$");
            FlattenLayers(rootLayers, sourcePath, tilesets, warnings, layers, layerIds, new LayerState(true, 1, 0, 0), "$.layers");
            if (layers.Count is < 1 or > WorkspaceTilemapAssetCodec.MaxLayers)
                throw Error("IMPORT_LAYER_BUDGET_EXCEEDED", $"导入后的视觉 Layer 数必须为 1..{WorkspaceTilemapAssetCodec.MaxLayers}。", sourcePath, "$.layers");
            return new WorkspaceMapImportResult(
                "tiled",
                version,
                documents.OrderBy(value => value, StringComparer.Ordinal).ToArray(),
                new WorkspaceTilemapAsset(tilesets.Select(value => value.Source).ToArray(), layers.ToArray()),
                warnings.ToArray());
        }
        catch (WorkspaceMapImportException) { throw; }
        catch (JsonException exception)
        {
            throw Error("IMPORT_INVALID_JSON", $"Tiled JSON 无效：{exception.Message}", sourcePath, "$", exception);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or OverflowException or InvalidDataException)
        {
            throw Error("TILED_INVALID_DATA", exception.Message, sourcePath, "$", exception);
        }
    }

    private static void FlattenLayers(
        JsonElement layerArray,
        string sourcePath,
        IReadOnlyList<TiledTileset> tilesets,
        List<WorkspaceMapImportDiagnostic> warnings,
        List<WorkspaceTileLayer> output,
        HashSet<string> layerIds,
        LayerState inherited,
        string arrayPath)
    {
        var ordinal = 0;
        foreach (var layer in layerArray.EnumerateArray())
        {
            var path = $"{arrayPath}[{ordinal}]";
            RequireObject(layer, sourcePath, path);
            var type = RequireString(layer, "type", sourcePath, path);
            var state = ApplyLayerState(layer, inherited, sourcePath, path);
            WarnProperties(layer, sourcePath, path, warnings, "TILED_PROPERTIES_NOT_CONSUMED");
            switch (type)
            {
                case "group":
                    FlattenLayers(RequireArray(layer, "layers", sourcePath, path), sourcePath, tilesets, warnings, output, layerIds, state, $"{path}.layers");
                    break;
                case "tilelayer":
                {
                    var id = WorkspaceMapImport.StableId("tiled", RequirePositiveInt(layer, "id", sourcePath, path).ToString(System.Globalization.CultureInfo.InvariantCulture));
                    if (!layerIds.Add(id)) throw Error("TILED_DUPLICATE_LAYER_ID", "Tiled Layer ID 重复。", sourcePath, $"{path}.id");
                    var cells = ParseTileLayer(layer, sourcePath, path, tilesets, warnings);
                    output.Add(new WorkspaceTileLayer(
                        id,
                        state.Visible,
                        checked((float)state.Opacity),
                        tilesets[0].Source.TileWidth,
                        tilesets[0].Source.TileHeight,
                        checked((float)state.OffsetX),
                        checked((float)state.OffsetY),
                        BuildChunks(cells)));
                    break;
                }
                case "objectgroup":
                    warnings.Add(Warning("TILED_LAYER_NOT_IMPORTED", sourcePath, path, "Object Layer 未映射为 Runtime Object。"));
                    break;
                case "imagelayer":
                    warnings.Add(Warning("TILED_LAYER_NOT_IMPORTED", sourcePath, path, "Image Layer 未导入。"));
                    break;
                default:
                    throw Error("TILED_UNSUPPORTED_LAYER", $"不支持 Tiled Layer 类型：{type}。", sourcePath, $"{path}.type");
            }
            ordinal++;
        }
    }

    private static Dictionary<(int X, int Y), WorkspaceTileCell> ParseTileLayer(
        JsonElement layer,
        string sourcePath,
        string path,
        IReadOnlyList<TiledTileset> tilesets,
        List<WorkspaceMapImportDiagnostic> warnings)
    {
        var result = new Dictionary<(int X, int Y), WorkspaceTileCell>();
        if (layer.TryGetProperty("encoding", out var encoding) && encoding.ValueKind != JsonValueKind.Null
            && (encoding.ValueKind != JsonValueKind.String || encoding.GetString() is not (null or "csv")))
            throw Error("TILED_UNSUPPORTED_DATA_ENCODING", "首版只支持原生 JSON/csv GID 数组。", sourcePath, $"{path}.encoding");
        if (layer.TryGetProperty("compression", out var compression) && compression.ValueKind == JsonValueKind.String && !string.IsNullOrEmpty(compression.GetString()))
            throw Error("TILED_UNSUPPORTED_DATA_ENCODING", "首版不支持 base64/gzip/zlib/zstd Layer 数据。", sourcePath, $"{path}.compression");

        if (layer.TryGetProperty("chunks", out var chunks))
        {
            if (chunks.ValueKind != JsonValueKind.Array) throw Error("TILED_INVALID_DATA", "Layer chunks 必须是数组。", sourcePath, $"{path}.chunks");
            var chunkOrdinal = 0;
            foreach (var chunk in chunks.EnumerateArray())
            {
                var chunkPath = $"{path}.chunks[{chunkOrdinal}]";
                var x = RequireInt(chunk, "x", sourcePath, chunkPath);
                var y = RequireInt(chunk, "y", sourcePath, chunkPath);
                var width = RequirePositiveInt(chunk, "width", sourcePath, chunkPath);
                var height = RequirePositiveInt(chunk, "height", sourcePath, chunkPath);
                ReadGids(RequireArray(chunk, "data", sourcePath, chunkPath), width, height, x, y, sourcePath, $"{chunkPath}.data", tilesets, warnings, result);
                chunkOrdinal++;
            }
        }
        else
        {
            var width = RequirePositiveInt(layer, "width", sourcePath, path);
            var height = RequirePositiveInt(layer, "height", sourcePath, path);
            var x = GetInt(layer, "x", 0, sourcePath, path);
            var y = GetInt(layer, "y", 0, sourcePath, path);
            ReadGids(RequireArray(layer, "data", sourcePath, path), width, height, x, y, sourcePath, $"{path}.data", tilesets, warnings, result);
        }
        return result;
    }

    private static void ReadGids(
        JsonElement data,
        int width,
        int height,
        int originX,
        int originY,
        string sourcePath,
        string path,
        IReadOnlyList<TiledTileset> tilesets,
        List<WorkspaceMapImportDiagnostic> warnings,
        Dictionary<(int X, int Y), WorkspaceTileCell> output)
    {
        var expected = checked(width * height);
        if (data.GetArrayLength() != expected) throw Error("TILED_INVALID_DATA", "GID 数组长度与 width*height 不一致。", sourcePath, path);
        var index = 0;
        foreach (var value in data.EnumerateArray())
        {
            if (value.ValueKind != JsonValueKind.Number || !value.TryGetUInt32(out var gid))
                throw Error("TILED_INVALID_GID", "Tiled GID 必须是 u32。", sourcePath, $"{path}[{index}]");
            var x = checked(originX + index % width);
            var y = checked(originY + index / width);
            if (gid != 0)
            {
                var flags = gid & ~GidMask;
                var baseGid = gid & GidMask;
                if ((flags & RotateHex120) != 0)
                    warnings.Add(Warning("TILED_STALE_HEX_FLAG_CLEARED", sourcePath, $"{path}[{index}]", "正交地图中的 hex rotation flag 已清除。"));
                if (baseGid == 0) throw Error("TILED_INVALID_GID", "非零变换标志不能引用空 GID。", sourcePath, $"{path}[{index}]");
                var sourceIndex = -1;
                for (var candidate = tilesets.Count - 1; candidate >= 0; candidate--)
                {
                    if (baseGid >= tilesets[candidate].FirstGid) { sourceIndex = candidate; break; }
                }
                if (sourceIndex < 0) throw Error("TILED_INVALID_GID", "GID 无法解析到 Tileset。", sourcePath, $"{path}[{index}]");
                var tile = tilesets[sourceIndex];
                var localId = baseGid - tile.FirstGid;
                if (localId >= tile.TileCount) throw Error("TILED_INVALID_GID", "GID local Tile ID 超过 Tileset 范围。", sourcePath, $"{path}[{index}]");
                if (tile.Animated.Contains(localId))
                    throw Error("TILED_UNSUPPORTED_ANIMATED_TILE", "首版不能把正在使用的动画 Tile 静态化。", sourcePath, $"{path}[{index}]");
                var transform = WorkspaceTileTransform.None;
                if ((flags & FlipHorizontal) != 0) transform |= WorkspaceTileTransform.FlipHorizontal;
                if ((flags & FlipVertical) != 0) transform |= WorkspaceTileTransform.FlipVertical;
                if ((flags & FlipDiagonal) != 0) transform |= WorkspaceTileTransform.FlipDiagonal;
                if (!output.TryAdd((x, y), new WorkspaceTileCell(0, checked((ushort)sourceIndex), localId, transform)))
                    throw Error("TILED_OVERLAPPING_CHUNKS", "来源 Chunk 重叠声明同一 Cell。", sourcePath, $"{path}[{index}]");
            }
            index++;
        }
    }

    private static WorkspaceTileChunk[] BuildChunks(Dictionary<(int X, int Y), WorkspaceTileCell> cells)
    {
        var chunks = new Dictionary<(int X, int Y), List<WorkspaceTileCell>>();
        foreach (var (coordinate, cell) in cells)
        {
            var chunkX = WorkspaceMapImport.FloorDiv(coordinate.X, WorkspaceTilemapAssetCodec.ChunkEdge);
            var chunkY = WorkspaceMapImport.FloorDiv(coordinate.Y, WorkspaceTilemapAssetCodec.ChunkEdge);
            var localX = coordinate.X - chunkX * WorkspaceTilemapAssetCodec.ChunkEdge;
            var localY = coordinate.Y - chunkY * WorkspaceTilemapAssetCodec.ChunkEdge;
            var localIndex = checked((ushort)(localY * WorkspaceTilemapAssetCodec.ChunkEdge + localX));
            if (!chunks.TryGetValue((chunkX, chunkY), out var values)) chunks[(chunkX, chunkY)] = values = [];
            values.Add(cell with { LocalIndex = localIndex });
        }
        return chunks.OrderBy(value => value.Key.Y).ThenBy(value => value.Key.X)
            .Select(value => new WorkspaceTileChunk(value.Key.X, value.Key.Y, value.Value.OrderBy(cell => cell.LocalIndex).ToArray()))
            .ToArray();
    }

    private static LayerState ApplyLayerState(JsonElement layer, LayerState inherited, string sourcePath, string path)
    {
        RejectLayerEffects(layer, sourcePath, path);
        var visible = inherited.Visible && GetBool(layer, "visible", true, sourcePath, path);
        var opacity = inherited.Opacity * GetUnitDouble(layer, "opacity", 1, sourcePath, path);
        var offsetX = inherited.OffsetX + GetFiniteDouble(layer, "offsetx", 0, sourcePath, path);
        var offsetY = inherited.OffsetY + GetFiniteDouble(layer, "offsety", 0, sourcePath, path);
        return new LayerState(visible, opacity, offsetX, offsetY);
    }

    private static void RejectLayerEffects(JsonElement layer, string sourcePath, string path)
    {
        if (GetString(layer, "blendmode", "normal", sourcePath, path) != "normal"
            || GetFiniteDouble(layer, "parallaxx", 1, sourcePath, path) != 1
            || GetFiniteDouble(layer, "parallaxy", 1, sourcePath, path) != 1
            || layer.TryGetProperty("tintcolor", out var tint) && tint.ValueKind == JsonValueKind.String
                && tint.GetString() is not ("#ffffff" or "#ffffffff" or "#FFFFFFFF" or "#FFFFFF"))
            throw Error("TILED_UNSUPPORTED_LAYER_EFFECT", "首版不支持非默认 blend/tint/parallax。", sourcePath, path);
    }

    private static void RejectTileGeometryOptions(JsonElement definition, string sourcePath)
    {
        if (definition.TryGetProperty("tileoffset", out var offset) && offset.ValueKind == JsonValueKind.Object
            && (GetInt(offset, "x", 0, sourcePath, "$.tileoffset") != 0 || GetInt(offset, "y", 0, sourcePath, "$.tileoffset") != 0))
            throw Error("TILED_UNSUPPORTED_TILE_GEOMETRY", "非零 tileoffset 不受支持。", sourcePath, "$.tileoffset");
        if (GetString(definition, "tilerendersize", "tile", sourcePath, "$") != "tile"
            || GetString(definition, "fillmode", "stretch", sourcePath, "$") != "stretch")
            throw Error("TILED_UNSUPPORTED_TILE_GEOMETRY", "非默认 tilerendersize/fillmode 不受支持。", sourcePath, "$");
    }

    private static void WarnProperties(JsonElement owner, string sourcePath, string path, List<WorkspaceMapImportDiagnostic> warnings, string code)
    {
        if (owner.TryGetProperty("properties", out var properties) && properties.ValueKind == JsonValueKind.Array && properties.GetArrayLength() != 0)
            warnings.Add(Warning(code, sourcePath, $"{path}.properties", $"{properties.GetArrayLength()} 个 Custom Properties 未消费。"));
    }

    private static WorkspaceMapImportDiagnostic Warning(string code, string sourcePath, string path, string message) =>
        new(WorkspaceMapImportSeverity.Warning, code, sourcePath, path, message);

    private static WorkspaceMapImportException Error(string code, string message, string sourcePath, string path, Exception? inner = null) =>
        WorkspaceMapImport.Error(code, message, sourcePath, path, inner);

    private static void RequireObject(JsonElement value, string sourcePath, string path)
    {
        if (value.ValueKind != JsonValueKind.Object) throw Error("TILED_INVALID_DATA", "值必须是 JSON object。", sourcePath, path);
    }

    private static JsonElement RequireArray(JsonElement owner, string name, string sourcePath, string path)
    {
        if (!owner.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.Array)
            throw Error("TILED_INVALID_DATA", $"{name} 必须是数组。", sourcePath, $"{path}.{name}");
        return value;
    }

    private static string RequireString(JsonElement owner, string name, string sourcePath, string path)
    {
        if (!owner.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.String || value.GetString() is not { Length: > 0 } result)
            throw Error("TILED_INVALID_DATA", $"{name} 必须是非空字符串。", sourcePath, $"{path}.{name}");
        return result;
    }

    private static string GetString(JsonElement owner, string name, string fallback, string sourcePath, string path)
    {
        if (!owner.TryGetProperty(name, out var value)) return fallback;
        if (value.ValueKind != JsonValueKind.String || value.GetString() is not { } result)
            throw Error("TILED_INVALID_DATA", $"{name} 必须是字符串。", sourcePath, $"{path}.{name}");
        return result;
    }

    private static int RequirePositiveInt(JsonElement owner, string name, string sourcePath, string path)
    {
        var value = RequireInt(owner, name, sourcePath, path);
        if (value <= 0) throw Error("TILED_INVALID_DATA", $"{name} 必须为正整数。", sourcePath, $"{path}.{name}");
        return value;
    }

    private static uint RequirePositiveUInt(JsonElement owner, string name, string sourcePath, string path)
    {
        var value = RequireUInt(owner, name, sourcePath, path);
        if (value == 0) throw Error("TILED_INVALID_DATA", $"{name} 必须为正整数。", sourcePath, $"{path}.{name}");
        return value;
    }

    private static uint RequireUInt(JsonElement owner, string name, string sourcePath, string path)
    {
        if (!owner.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.Number || !value.TryGetUInt32(out var result))
            throw Error("TILED_INVALID_DATA", $"{name} 必须是 u32。", sourcePath, $"{path}.{name}");
        return result;
    }

    private static int RequireInt(JsonElement owner, string name, string sourcePath, string path)
    {
        if (!owner.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.Number || !value.TryGetInt32(out var result))
            throw Error("TILED_INVALID_DATA", $"{name} 必须是 i32。", sourcePath, $"{path}.{name}");
        return result;
    }

    private static int GetInt(JsonElement owner, string name, int fallback, string sourcePath, string path)
    {
        if (!owner.TryGetProperty(name, out var value)) return fallback;
        if (value.ValueKind != JsonValueKind.Number || !value.TryGetInt32(out var result))
            throw Error("TILED_INVALID_DATA", $"{name} 必须是 i32。", sourcePath, $"{path}.{name}");
        return result;
    }

    private static int GetNonNegativeInt(JsonElement owner, string name, int fallback, string sourcePath, string path)
    {
        var value = GetInt(owner, name, fallback, sourcePath, path);
        if (value < 0) throw Error("TILED_INVALID_DATA", $"{name} 不能为负数。", sourcePath, $"{path}.{name}");
        return value;
    }

    private static bool GetBool(JsonElement owner, string name, bool fallback, string sourcePath, string path)
    {
        if (!owner.TryGetProperty(name, out var value)) return fallback;
        if (value.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
            throw Error("TILED_INVALID_DATA", $"{name} 必须是 bool。", sourcePath, $"{path}.{name}");
        return value.GetBoolean();
    }

    private static double GetUnitDouble(JsonElement owner, string name, double fallback, string sourcePath, string path)
    {
        var result = GetFiniteDouble(owner, name, fallback, sourcePath, path);
        if (result is < 0 or > 1) throw Error("TILED_INVALID_DATA", $"{name} 必须在 [0,1]。", sourcePath, $"{path}.{name}");
        return result;
    }

    private static double GetFiniteDouble(JsonElement owner, string name, double fallback, string sourcePath, string path)
    {
        if (!owner.TryGetProperty(name, out var value)) return fallback;
        if (value.ValueKind != JsonValueKind.Number || !value.TryGetDouble(out var result) || !double.IsFinite(result) || !float.IsFinite((float)result))
            throw Error("TILED_INVALID_DATA", $"{name} 必须是有限 f32。", sourcePath, $"{path}.{name}");
        return result;
    }

    private sealed record TiledTileset(uint FirstGid, uint TileCount, HashSet<uint> Animated, WorkspaceTileSource Source);
    private sealed record LayerState(bool Visible, double Opacity, double OffsetX, double OffsetY);
}
