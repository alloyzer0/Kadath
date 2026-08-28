using System.Text.Json;

namespace Kadath.Editor.Workspace;

/// <summary>LDtk 1.5.3 Adapter；负责 Level 选择、top-first 逆序与 Tile stack 展开。</summary>
internal static class LdtkMapImportAdapter
{
    internal static WorkspaceMapImportResult Import(string sourcePath, WorkspaceMapImportRequest request)
    {
        var warnings = new List<WorkspaceMapImportDiagnostic>();
        var documents = new HashSet<string>(StringComparer.Ordinal) { sourcePath };
        try
        {
            using var projectDocument = Parse(sourcePath);
            var root = projectDocument.RootElement;
            RequireObject(root, sourcePath, "$");
            var version = RequireString(root, "jsonVersion", sourcePath, "$");
            if (version != "1.5.3") throw Error("LDTK_UNSUPPORTED_VERSION", $"仅支持 LDtk JSON 1.5.3，实际为 {version}。", sourcePath, "$.jsonVersion");
            if (root.TryGetProperty("worlds", out var worlds) && worlds.ValueKind == JsonValueKind.Array && worlds.GetArrayLength() != 0)
                throw Error("LDTK_UNSUPPORTED_MULTI_WORLD", "首版不支持 LDtk MultiWorld。", sourcePath, "$.worlds");

            var levels = RequireArray(root, "levels", sourcePath, "$");
            var selected = SelectLevel(levels, request.LevelIid, sourcePath);
            JsonDocument? external = null;
            var levelPath = sourcePath;
            JsonElement level = selected;
            if (!selected.TryGetProperty("layerInstances", out var layerInstances) || layerInstances.ValueKind == JsonValueKind.Null)
            {
                var relative = RequireString(selected, "externalRelPath", sourcePath, "$.levels[]");
                levelPath = WorkspaceMapImport.ResolveReference(Path.GetDirectoryName(sourcePath)!, sourcePath, relative, ".ldtkl", ".json");
                documents.Add(levelPath);
                external = Parse(levelPath);
                level = external.RootElement;
                RequireObject(level, levelPath, "$");
                if (RequireString(level, "iid", levelPath, "$") != RequireString(selected, "iid", sourcePath, "$.levels[]"))
                    throw Error("IMPORT_INVALID_EXTERNAL_REFERENCE", "外部 LDTKL 的 Level IID 与 Project 占位项不一致。", levelPath, "$.iid");
                layerInstances = RequireArray(level, "layerInstances", levelPath, "$");
            }
            else if (layerInstances.ValueKind != JsonValueKind.Array)
            {
                throw Error("LDTK_INVALID_DATA", "layerInstances 必须是数组或 null。", sourcePath, "$.levels[].layerInstances");
            }

            try
            {
                WarnWorldPlacement(level, levelPath, warnings);
                var usedUids = layerInstances.EnumerateArray()
                    .Where(IsVisualLayer)
                    .Select(layerValue => RequireNullableInt(layerValue, "__tilesetDefUid", levelPath, "$.layerInstances[]"))
                    .Where(value => value is not null)
                    .Select(value => value!.Value)
                    .Distinct()
                    .ToHashSet();
                if (usedUids.Count == 0) throw Error("LDTK_NO_VISUAL_LAYER", "选中 Level 没有可导入的 Tiles/AutoLayer。", levelPath, "$.layerInstances");
                var defs = RequireObjectProperty(root, "defs", sourcePath, "$");
                WarnDefinitions(defs, sourcePath, warnings);
                var tileDefs = RequireArray(defs, "tilesets", sourcePath, "$.defs");
                var selectedDefs = tileDefs.EnumerateArray()
                    .Where(value => usedUids.Contains(RequireInt(value, "uid", sourcePath, "$.defs.tilesets[]")))
                    .ToArray();
                if (selectedDefs.Length != usedUids.Count)
                    throw Error("LDTK_INVALID_TILESET", "视觉 Layer 引用了未知 Tileset UID。", sourcePath, "$.defs.tilesets");
                if (request.TextureIds.Count != selectedDefs.Length || request.TextureIds.Any(value => value == 0))
                    throw Error("IMPORT_TEXTURE_BINDING_MISMATCH", "TextureIds 必须按被使用的 LDtk Tileset 定义顺序一一绑定。", sourcePath, "$.defs.tilesets");

                var sources = new List<WorkspaceTileSource>();
                var sourceIndexByUid = new Dictionary<int, ushort>();
                for (var index = 0; index < selectedDefs.Length; index++)
                {
                    var definition = selectedDefs[index];
                    var path = $"$.defs.tilesets[{index}]";
                    var uid = RequireInt(definition, "uid", sourcePath, path);
                    var identifier = RequireString(definition, "identifier", sourcePath, path);
                    if (definition.TryGetProperty("embedAtlas", out var embedded) && embedded.ValueKind != JsonValueKind.Null)
                        throw Error("LDTK_UNSUPPORTED_TILESET_SOURCE", "内嵌 LDtk atlas 不受支持。", sourcePath, $"{path}.embedAtlas");
                    var relPath = RequireString(definition, "relPath", sourcePath, path);
                    _ = WorkspaceMapImport.ResolveReference(Path.GetDirectoryName(sourcePath)!, sourcePath, relPath, ".png", ".ppm");
                    var grid = RequirePositiveInt(definition, "tileGridSize", sourcePath, path);
                    var padding = GetNonNegativeInt(definition, "padding", 0, sourcePath, path);
                    var spacing = GetNonNegativeInt(definition, "spacing", 0, sourcePath, path);
                    var imageWidth = RequirePositiveInt(definition, "pxWid", sourcePath, path);
                    var imageHeight = RequirePositiveInt(definition, "pxHei", sourcePath, path);
                    var columns = GetPositiveIntAlternative(definition, "__cWid", "cWid", sourcePath, path)
                        ?? checked((imageWidth - padding * 2 + spacing) / (grid + spacing));
                    var rows = GetPositiveIntAlternative(definition, "__cHei", "cHei", sourcePath, path)
                        ?? checked((imageHeight - padding * 2 + spacing) / (grid + spacing));
                    if (columns <= 0 || rows <= 0) throw Error("LDTK_INVALID_TILESET", "Tileset 网格尺寸无效。", sourcePath, path);
                    if (definition.TryGetProperty("customData", out var customData) && customData.ValueKind == JsonValueKind.Array && customData.GetArrayLength() != 0)
                        warnings.Add(Warning("LDTK_TILE_METADATA_NOT_CONSUMED", sourcePath, $"{path}.customData", "Tileset customData 未消费。"));
                    if (definition.TryGetProperty("enumTags", out var enumTags) && enumTags.ValueKind == JsonValueKind.Array && enumTags.GetArrayLength() != 0)
                        warnings.Add(Warning("LDTK_TILE_METADATA_NOT_CONSUMED", sourcePath, $"{path}.enumTags", "Tileset enumTags 未消费。"));
                    sourceIndexByUid.Add(uid, checked((ushort)sources.Count));
                    sources.Add(new WorkspaceTileSource(
                        WorkspaceMapImport.StableId("ldtk-set", $"{uid}-{identifier}"),
                        request.TextureIds[index],
                        grid,
                        grid,
                        imageWidth,
                        imageHeight,
                        columns,
                        rows,
                        padding,
                        spacing));
                }

                var outputLayers = new List<WorkspaceTileLayer>();
                var layerValues = layerInstances.EnumerateArray().Reverse().ToArray();
                for (var sourceLayerIndex = 0; sourceLayerIndex < layerValues.Length; sourceLayerIndex++)
                {
                    var layerValue = layerValues[sourceLayerIndex];
                    var path = $"$.layerInstances[{layerValues.Length - sourceLayerIndex - 1}]";
                    var type = RequireString(layerValue, "__type", levelPath, path);
                    switch (type)
                    {
                        case "Tiles":
                            AppendVisualLayers(layerValue, "gridTiles", levelPath, path, sourceIndexByUid, sources, outputLayers);
                            break;
                        case "AutoLayer":
                            AppendVisualLayers(layerValue, "autoLayerTiles", levelPath, path, sourceIndexByUid, sources, outputLayers);
                            break;
                        case "IntGrid":
                            ValidateIntGrid(layerValue, levelPath, path);
                            warnings.Add(Warning("LDTK_INTGRID_NOT_CONSUMED", levelPath, path, "IntGrid 已校验但未 Bake 到 Runtime Core。"));
                            break;
                        case "Entities":
                            var entities = RequireArray(layerValue, "entityInstances", levelPath, path);
                            warnings.Add(Warning("LDTK_ENTITIES_NOT_IMPORTED", levelPath, path, $"{entities.GetArrayLength()} 个 Entity 未映射为 Runtime Object。"));
                            break;
                        default:
                            throw Error("LDTK_INVALID_DATA", $"未知 LDtk Layer 类型：{type}。", levelPath, $"{path}.__type");
                    }
                }
                if (outputLayers.Count is < 1 or > WorkspaceTilemapAssetCodec.MaxLayers)
                    throw Error("IMPORT_LAYER_BUDGET_EXCEEDED", $"导入后的视觉 Layer 数必须为 1..{WorkspaceTilemapAssetCodec.MaxLayers}。", levelPath, "$.layerInstances");
                return new WorkspaceMapImportResult(
                    "ldtk",
                    version,
                    documents.OrderBy(value => value, StringComparer.Ordinal).ToArray(),
                    new WorkspaceTilemapAsset(sources.ToArray(), outputLayers.ToArray()),
                    warnings.ToArray());
            }
            finally
            {
                external?.Dispose();
            }
        }
        catch (WorkspaceMapImportException) { throw; }
        catch (JsonException exception)
        {
            throw Error("IMPORT_INVALID_JSON", $"LDtk JSON 无效：{exception.Message}", sourcePath, "$", exception);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or OverflowException or InvalidDataException)
        {
            throw Error("LDTK_INVALID_DATA", exception.Message, sourcePath, "$", exception);
        }
    }

    private static JsonDocument Parse(string path) => JsonDocument.Parse(WorkspaceMapImport.ReadSource(path), new JsonDocumentOptions
    {
        AllowTrailingCommas = false,
        CommentHandling = JsonCommentHandling.Disallow,
        MaxDepth = 96
    });

    private static JsonElement SelectLevel(JsonElement levels, string? levelIid, string sourcePath)
    {
        var values = levels.EnumerateArray().ToArray();
        if (string.IsNullOrWhiteSpace(levelIid))
        {
            if (values.Length != 1) throw Error("LDTK_AMBIGUOUS_LEVEL", "多 Level LDtk 导入必须显式提供 LevelIid。", sourcePath, "$.levels");
            return values[0];
        }
        var matches = values.Where(value => RequireString(value, "iid", sourcePath, "$.levels[]") == levelIid).ToArray();
        if (matches.Length != 1) throw Error("LDTK_AMBIGUOUS_LEVEL", "LevelIid 不存在或重复。", sourcePath, "$.levels");
        return matches[0];
    }

    private static bool IsVisualLayer(JsonElement layer)
    {
        if (!layer.TryGetProperty("__type", out var value) || value.ValueKind != JsonValueKind.String) return false;
        return value.GetString() is "Tiles" or "AutoLayer";
    }

    private static void AppendVisualLayers(
        JsonElement layer,
        string tileArrayName,
        string sourcePath,
        string path,
        IReadOnlyDictionary<int, ushort> sourceIndexByUid,
        IReadOnlyList<WorkspaceTileSource> sources,
        List<WorkspaceTileLayer> output)
    {
        var iid = RequireString(layer, "iid", sourcePath, path);
        var grid = RequirePositiveInt(layer, "__gridSize", sourcePath, path);
        var tileSourceUid = RequireNullableInt(layer, "__tilesetDefUid", sourcePath, path)
            ?? throw Error("LDTK_INVALID_TILESET", "视觉 Layer 缺少 __tilesetDefUid。", sourcePath, $"{path}.__tilesetDefUid");
        if (!sourceIndexByUid.TryGetValue(tileSourceUid, out var sourceIndex))
            throw Error("LDTK_INVALID_TILESET", "视觉 Layer 引用了未知 Tileset。", sourcePath, $"{path}.__tilesetDefUid");
        var source = sources[sourceIndex];
        if (source.TileWidth != grid || source.TileHeight != grid)
            throw Error("LDTK_INVALID_TILE_GEOMETRY", "Tileset tileGridSize 必须等于 Layer __gridSize。", sourcePath, path);
        var opacity = GetUnitFloat(layer, "__opacity", 1, sourcePath, path);
        var visible = GetBool(layer, "visible", true, sourcePath, path);
        var offsetX = RequireFiniteFloat(layer, "__pxTotalOffsetX", sourcePath, path);
        var offsetY = RequireFiniteFloat(layer, "__pxTotalOffsetY", sourcePath, path);
        var tiles = RequireArray(layer, tileArrayName, sourcePath, path);

        var stackByCoordinate = new Dictionary<(int X, int Y), int>();
        var slotCells = new List<Dictionary<(int X, int Y), WorkspaceTileCell>>();
        var tileOrdinal = 0;
        foreach (var tile in tiles.EnumerateArray())
        {
            var tilePath = $"{path}.{tileArrayName}[{tileOrdinal}]";
            var px = RequireIntPair(tile, "px", sourcePath, tilePath);
            if (px[0] % grid != 0 || px[1] % grid != 0)
                throw Error("LDTK_INVALID_TILE_GEOMETRY", "Tile px 必须按 __gridSize 对齐。", sourcePath, $"{tilePath}.px");
            var x = px[0] / grid;
            var y = px[1] / grid;
            var localId = RequireNonNegativeInt(tile, "t", sourcePath, tilePath);
            if ((uint)localId >= checked((uint)(source.Columns * source.Rows)))
                throw Error("LDTK_INVALID_TILE_GEOMETRY", "Tile local ID 超过 Tileset。", sourcePath, $"{tilePath}.t");
            var src = RequireIntPair(tile, "src", sourcePath, tilePath);
            var expectedX = source.Margin + localId % source.Columns * (source.TileWidth + source.Spacing);
            var expectedY = source.Margin + localId / source.Columns * (source.TileHeight + source.Spacing);
            if (src[0] != expectedX || src[1] != expectedY)
                throw Error("LDTK_INVALID_TILE_GEOMETRY", "Tile src 与 local ID/Tileset 几何不一致。", sourcePath, $"{tilePath}.src");
            var alpha = GetUnitFloat(tile, "a", 1, sourcePath, tilePath);
            if (alpha != 1) throw Error("LDTK_UNSUPPORTED_TILE_ALPHA", "首版不支持 per-Tile alpha。", sourcePath, $"{tilePath}.a");
            var flip = GetInt(tile, "f", 0, sourcePath, tilePath);
            if (flip is < 0 or > 3) throw Error("LDTK_INVALID_FLIP_BITS", "LDtk Tile.f 只能使用 X/Y 两位。", sourcePath, $"{tilePath}.f");
            var transform = WorkspaceTileTransform.None;
            if ((flip & 1) != 0) transform |= WorkspaceTileTransform.FlipHorizontal;
            if ((flip & 2) != 0) transform |= WorkspaceTileTransform.FlipVertical;
            var coordinate = (x, y);
            var slot = stackByCoordinate.GetValueOrDefault(coordinate);
            stackByCoordinate[coordinate] = slot + 1;
            while (slotCells.Count <= slot) slotCells.Add([]);
            slotCells[slot].Add(coordinate, new WorkspaceTileCell(0, sourceIndex, checked((uint)localId), transform));
            tileOrdinal++;
        }

        // LDtk 同格 Tile 的数组顺序就是从底到顶；按 stack slot 展开才能保持视觉语义。
        if (slotCells.Count == 0) slotCells.Add([]);
        for (var slot = 0; slot < slotCells.Count; slot++)
        {
            output.Add(new WorkspaceTileLayer(
                WorkspaceMapImport.StableId("ldtk", $"{iid}-{slot}"),
                visible,
                opacity,
                grid,
                grid,
                offsetX,
                offsetY,
                BuildChunks(slotCells[slot])));
        }
    }

    private static void ValidateIntGrid(JsonElement layer, string sourcePath, string path)
    {
        var width = RequirePositiveInt(layer, "__cWid", sourcePath, path);
        var height = RequirePositiveInt(layer, "__cHei", sourcePath, path);
        var values = RequireArray(layer, "intGridCsv", sourcePath, path);
        if (values.GetArrayLength() != checked(width * height))
            throw Error("LDTK_INVALID_DATA", "intGridCsv 长度与 __cWid*__cHei 不一致。", sourcePath, $"{path}.intGridCsv");
        var index = 0;
        foreach (var value in values.EnumerateArray())
        {
            if (value.ValueKind != JsonValueKind.Number || !value.TryGetInt32(out var parsed) || parsed < 0)
                throw Error("LDTK_INVALID_DATA", "intGridCsv 值必须是非负 i32。", sourcePath, $"{path}.intGridCsv[{index}]");
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

    private static void WarnDefinitions(JsonElement defs, string sourcePath, List<WorkspaceMapImportDiagnostic> warnings)
    {
        foreach (var name in new[] { "enums", "externalEnums" })
        {
            if (defs.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Array && value.GetArrayLength() != 0)
                warnings.Add(Warning("LDTK_ENUMS_NOT_CONSUMED", sourcePath, $"$.defs.{name}", $"{value.GetArrayLength()} 个 Enum 定义未消费。"));
        }
    }

    private static void WarnWorldPlacement(JsonElement level, string sourcePath, List<WorkspaceMapImportDiagnostic> warnings)
    {
        if (level.TryGetProperty("worldX", out _) || level.TryGetProperty("worldY", out _) || level.TryGetProperty("worldDepth", out _))
            warnings.Add(Warning("LDTK_WORLD_PLACEMENT_NOT_APPLIED", sourcePath, "$", "首版按 Level-local 坐标导入，未应用 world placement。"));
    }

    private static WorkspaceMapImportDiagnostic Warning(string code, string sourcePath, string path, string message) =>
        new(WorkspaceMapImportSeverity.Warning, code, sourcePath, path, message);

    private static WorkspaceMapImportException Error(string code, string message, string sourcePath, string path, Exception? inner = null) =>
        WorkspaceMapImport.Error(code, message, sourcePath, path, inner);

    private static void RequireObject(JsonElement value, string sourcePath, string path)
    {
        if (value.ValueKind != JsonValueKind.Object) throw Error("LDTK_INVALID_DATA", "值必须是 JSON object。", sourcePath, path);
    }

    private static JsonElement RequireObjectProperty(JsonElement owner, string name, string sourcePath, string path)
    {
        if (!owner.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.Object)
            throw Error("LDTK_INVALID_DATA", $"{name} 必须是 object。", sourcePath, $"{path}.{name}");
        return value;
    }

    private static JsonElement RequireArray(JsonElement owner, string name, string sourcePath, string path)
    {
        if (!owner.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.Array)
            throw Error("LDTK_INVALID_DATA", $"{name} 必须是数组。", sourcePath, $"{path}.{name}");
        return value;
    }

    private static string RequireString(JsonElement owner, string name, string sourcePath, string path)
    {
        if (!owner.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.String || value.GetString() is not { Length: > 0 } result)
            throw Error("LDTK_INVALID_DATA", $"{name} 必须是非空字符串。", sourcePath, $"{path}.{name}");
        return result;
    }

    private static int RequireInt(JsonElement owner, string name, string sourcePath, string path)
    {
        if (!owner.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.Number || !value.TryGetInt32(out var result))
            throw Error("LDTK_INVALID_DATA", $"{name} 必须是 i32。", sourcePath, $"{path}.{name}");
        return result;
    }

    private static int RequirePositiveInt(JsonElement owner, string name, string sourcePath, string path)
    {
        var value = RequireInt(owner, name, sourcePath, path);
        if (value <= 0) throw Error("LDTK_INVALID_DATA", $"{name} 必须为正数。", sourcePath, $"{path}.{name}");
        return value;
    }

    private static int RequireNonNegativeInt(JsonElement owner, string name, string sourcePath, string path)
    {
        var value = RequireInt(owner, name, sourcePath, path);
        if (value < 0) throw Error("LDTK_INVALID_DATA", $"{name} 不能为负数。", sourcePath, $"{path}.{name}");
        return value;
    }

    private static int? RequireNullableInt(JsonElement owner, string name, string sourcePath, string path)
    {
        if (!owner.TryGetProperty(name, out var value)) throw Error("LDTK_INVALID_DATA", $"缺少 {name}。", sourcePath, $"{path}.{name}");
        if (value.ValueKind == JsonValueKind.Null) return null;
        if (value.ValueKind != JsonValueKind.Number || !value.TryGetInt32(out var result))
            throw Error("LDTK_INVALID_DATA", $"{name} 必须是 i32 或 null。", sourcePath, $"{path}.{name}");
        return result;
    }

    private static int[] RequireIntPair(JsonElement owner, string name, string sourcePath, string path)
    {
        var value = RequireArray(owner, name, sourcePath, path);
        if (value.GetArrayLength() != 2) throw Error("LDTK_INVALID_DATA", $"{name} 必须包含两个 i32。", sourcePath, $"{path}.{name}");
        var result = new int[2];
        var index = 0;
        foreach (var item in value.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.Number || !item.TryGetInt32(out result[index]))
                throw Error("LDTK_INVALID_DATA", $"{name} 必须包含两个 i32。", sourcePath, $"{path}.{name}[{index}]");
            index++;
        }
        return result;
    }

    private static int GetInt(JsonElement owner, string name, int fallback, string sourcePath, string path)
    {
        if (!owner.TryGetProperty(name, out var value)) return fallback;
        if (value.ValueKind != JsonValueKind.Number || !value.TryGetInt32(out var result))
            throw Error("LDTK_INVALID_DATA", $"{name} 必须是 i32。", sourcePath, $"{path}.{name}");
        return result;
    }

    private static int GetNonNegativeInt(JsonElement owner, string name, int fallback, string sourcePath, string path)
    {
        var value = GetInt(owner, name, fallback, sourcePath, path);
        if (value < 0) throw Error("LDTK_INVALID_DATA", $"{name} 不能为负数。", sourcePath, $"{path}.{name}");
        return value;
    }

    private static int? GetPositiveIntAlternative(JsonElement owner, string primary, string secondary, string sourcePath, string path)
    {
        foreach (var name in new[] { primary, secondary })
        {
            if (!owner.TryGetProperty(name, out var value)) continue;
            if (value.ValueKind != JsonValueKind.Number || !value.TryGetInt32(out var result) || result <= 0)
                throw Error("LDTK_INVALID_DATA", $"{name} 必须为正 i32。", sourcePath, $"{path}.{name}");
            return result;
        }
        return null;
    }

    private static bool GetBool(JsonElement owner, string name, bool fallback, string sourcePath, string path)
    {
        if (!owner.TryGetProperty(name, out var value)) return fallback;
        if (value.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
            throw Error("LDTK_INVALID_DATA", $"{name} 必须是 bool。", sourcePath, $"{path}.{name}");
        return value.GetBoolean();
    }

    private static float GetUnitFloat(JsonElement owner, string name, float fallback, string sourcePath, string path)
    {
        if (!owner.TryGetProperty(name, out var value)) return fallback;
        if (value.ValueKind != JsonValueKind.Number || !value.TryGetSingle(out var result) || !float.IsFinite(result) || result is < 0 or > 1)
            throw Error("LDTK_INVALID_DATA", $"{name} 必须是 [0,1] 内有限 f32。", sourcePath, $"{path}.{name}");
        return result;
    }

    private static float RequireFiniteFloat(JsonElement owner, string name, string sourcePath, string path)
    {
        if (!owner.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.Number || !value.TryGetSingle(out var result) || !float.IsFinite(result))
            throw Error("LDTK_INVALID_DATA", $"{name} 必须是有限 f32。", sourcePath, $"{path}.{name}");
        return result;
    }
}
