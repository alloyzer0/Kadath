using Kadath.Editor.Workspace;

namespace Kadath.Editor.Workspace.ContractVerifier;

internal static class TilemapImportVerifier
{
    internal static Task VerifyAsync()
    {
        VerifyArtifactCodec();
        VerifyFloorDivision();
        var root = Path.Combine(Path.GetTempPath(), $"kadath-map-import-{Guid.NewGuid():N}");
        Directory.CreateDirectory(root);
        try
        {
            VerifyTiled(root);
            VerifyLdtk(root);
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
        return Task.CompletedTask;
    }

    private static void VerifyArtifactCodec()
    {
        var asset = new WorkspaceTilemapAsset(
        [
            new("ground", 1, 16, 16, 70, 36, 4, 2, 1, 1),
            new("decor", 2, 16, 16, 32, 16, 2, 1, 0, 0)
        ],
        [
            new("background", true, 1, 16, 16, -4, 8,
            [
                new(-1, -1,
                [
                    new(0, 0, 0, WorkspaceTileTransform.None),
                    new(1023, 1, 1, WorkspaceTileTransform.FlipHorizontal | WorkspaceTileTransform.FlipDiagonal)
                ]),
                new(0, 0, [new(33, 0, 7, WorkspaceTileTransform.FlipVertical)])
            ]),
            new("foreground", false, 0.5f, 16, 16, 0, 0, [])
        ]);

        var first = WorkspaceTilemapAssetCodec.Encode(asset);
        var second = WorkspaceTilemapAssetCodec.Encode(asset);
        Require(first.AsSpan().SequenceEqual(second), "Tilemap artifact encoding is not deterministic");
        var decoded = WorkspaceTilemapAssetCodec.Decode(first);
        Require(decoded.TileSources.Length == 2 && decoded.Layers.Length == 2, "Tilemap artifact summary mismatch");
        Require(decoded.Layers[0].Chunks[0].X == -1 && decoded.Layers[0].Chunks[0].Y == -1, "negative Chunk coordinate did not round-trip");
        Require(decoded.Layers[0].Chunks[0].Cells[1].Transform == (WorkspaceTileTransform.FlipHorizontal | WorkspaceTileTransform.FlipDiagonal),
            "Tile transform did not round-trip");

        ExpectInvalid(() => WorkspaceTilemapAssetCodec.Decode(first[..^1]), "truncated Tilemap artifact was accepted");
        ExpectInvalid(() => WorkspaceTilemapAssetCodec.Decode([.. first, 0]), "Tilemap artifact trailing byte was accepted");
        var badMagic = first.ToArray();
        badMagic[0] = (byte)'X';
        ExpectInvalid(() => WorkspaceTilemapAssetCodec.Decode(badMagic), "invalid Tilemap artifact magic was accepted");
        var unordered = asset with
        {
            Layers =
            [
                asset.Layers[0] with { Chunks = [asset.Layers[0].Chunks[1], asset.Layers[0].Chunks[0]] },
                asset.Layers[1]
            ]
        };
        ExpectInvalid(() => WorkspaceTilemapAssetCodec.Encode(unordered), "unordered Tilemap chunks were accepted");
    }

    private static void VerifyFloorDivision()
    {
        Require(WorkspaceMapImport.FloorDiv(-1, 32) == -1, "floorDiv(-1) mismatch");
        Require(WorkspaceMapImport.FloorDiv(-32, 32) == -1, "floorDiv(-32) mismatch");
        Require(WorkspaceMapImport.FloorDiv(-33, 32) == -2, "floorDiv(-33) mismatch");
        Require(WorkspaceMapImport.FloorDiv(32, 32) == 1, "floorDiv(32) mismatch");
    }

    private static void VerifyTiled(string root)
    {
        File.WriteAllBytes(Path.Combine(root, "ground.png"), [0]);
        File.WriteAllBytes(Path.Combine(root, "decor.png"), [0]);
        File.WriteAllText(Path.Combine(root, "ground.tsj"),
            """
            {"type":"tileset","version":"1.12","name":"Ground","tilewidth":16,"tileheight":16,
             "tilecount":4,"columns":2,"image":"ground.png","imagewidth":34,"imageheight":34,"margin":0,"spacing":2,
             "properties":[{"name":"kind","type":"string","value":"ground"}]}
            """);
        File.WriteAllText(Path.Combine(root, "decor.tsj"),
            """
            {"type":"tileset","version":"1.12","name":"Decor","tilewidth":16,"tileheight":16,
             "tilecount":2,"columns":2,"image":"decor.png","imagewidth":32,"imageheight":16}
            """);
        var mapPath = Path.Combine(root, "world.tmj");
        File.WriteAllText(mapPath,
            """
            {"type":"map","version":"1.12","tiledversion":"1.12.2","orientation":"orthogonal","renderorder":"right-down",
             "tilewidth":16,"tileheight":16,"infinite":true,
             "tilesets":[{"firstgid":1,"source":"ground.tsj"},{"firstgid":5,"source":"decor.tsj"}],
             "layers":[
               {"id":10,"type":"group","visible":true,"opacity":0.5,"offsetx":4,"offsety":8,"layers":[
                 {"id":11,"type":"tilelayer","visible":true,"opacity":0.5,"offsetx":2,"offsety":-2,
                  "chunks":[{"x":-33,"y":-1,"width":4,"height":2,
                  "data":[2147483649,1073741829,536870914,3758096389,1,5,0,2]}]}
               ]},
               {"id":12,"type":"objectgroup","objects":[{"id":1,"x":0,"y":0}]}
             ]}
            """);

        var imported = WorkspaceMapImport.Import(new WorkspaceMapImportRequest(mapPath, [1, 2]));
        Require(imported.SourceKind == "tiled" && imported.SourceVersion == "1.12", "Tiled format identity mismatch");
        Require(imported.Asset.TileSources.Length == 2 && imported.Asset.Layers.Length == 1, "Tiled source/layer count mismatch");
        Require(imported.Asset.Layers[0].Opacity == 0.25f && imported.Asset.Layers[0].OffsetX == 6 && imported.Asset.Layers[0].OffsetY == 6,
            "Tiled Group display state did not compose");
        Require(imported.Asset.Layers[0].Chunks.Any(chunk => chunk.X == -2 && chunk.Y == -1), "Tiled negative coordinates were not re-chunked with floor division");
        Require(imported.Asset.Layers[0].Chunks.SelectMany(chunk => chunk.Cells).Any(cell => cell.TileSourceIndex == 1), "Tiled mixed Tileset layer was not preserved");
        Require(imported.Diagnostics.Any(value => value.Code == "TILED_LAYER_NOT_IMPORTED")
            && imported.Diagnostics.Any(value => value.Code == "TILED_PROPERTIES_NOT_CONSUMED"), "Tiled unconsumed semantics were not diagnosed");
        var first = WorkspaceTilemapAssetCodec.Encode(imported.Asset);
        var repeated = WorkspaceMapImport.Import(new WorkspaceMapImportRequest(mapPath, [1, 2]));
        var second = WorkspaceTilemapAssetCodec.Encode(repeated.Asset);
        Require(first.AsSpan().SequenceEqual(second), "Tiled import is not deterministic");
        Require(imported.Diagnostics.SequenceEqual(repeated.Diagnostics), "Tiled diagnostics are not deterministic");
        ExpectImport("IMPORT_STRICT_WARNING", () => WorkspaceMapImport.Import(new WorkspaceMapImportRequest(mapPath, [1, 2], Strict: true)));

        var invalid = File.ReadAllText(mapPath).Replace("\"orthogonal\"", "\"isometric\"", StringComparison.Ordinal);
        var invalidPath = Path.Combine(root, "invalid.tmj");
        File.WriteAllText(invalidPath, invalid);
        ExpectImport("TILED_UNSUPPORTED_ORIENTATION", () => WorkspaceMapImport.Import(new WorkspaceMapImportRequest(invalidPath, [1, 2])));
    }

    private static void VerifyLdtk(string root)
    {
        File.WriteAllBytes(Path.Combine(root, "ldtk.png"), [0]);
        var path = Path.Combine(root, "world.ldtk");
        File.WriteAllText(path,
            """
            {"jsonVersion":"1.5.3","worlds":[],
             "defs":{"tilesets":[{"uid":1,"identifier":"World","relPath":"ldtk.png","tileGridSize":16,
               "padding":0,"spacing":0,"pxWid":32,"pxHei":32,"__cWid":2,"__cHei":2}],
               "enums":[{"identifier":"Biome"}],"externalEnums":[]},
             "levels":[{"identifier":"Level_0","iid":"level-iid","worldX":32,"worldY":64,"worldDepth":0,"externalRelPath":null,
               "layerInstances":[
                 {"__identifier":"Top","iid":"top-iid","__type":"Tiles","__gridSize":16,"__tilesetDefUid":1,
                  "__opacity":1,"__pxTotalOffsetX":0,"__pxTotalOffsetY":0,"visible":true,
                  "gridTiles":[{"px":[16,0],"src":[16,0],"t":1,"a":1,"f":3}]},
                 {"__identifier":"Bottom","iid":"bottom-iid","__type":"AutoLayer","__gridSize":16,"__tilesetDefUid":1,
                  "__opacity":0.5,"__pxTotalOffsetX":-16,"__pxTotalOffsetY":8,"visible":true,
                  "autoLayerTiles":[{"px":[0,0],"src":[0,0],"t":0,"a":1,"f":0}]},
                 {"__identifier":"Collision","iid":"int-iid","__type":"IntGrid","__gridSize":16,"__tilesetDefUid":null,
                  "__cWid":2,"__cHei":1,"intGridCsv":[1,0]},
                 {"__identifier":"Entities","iid":"entity-iid","__type":"Entities","__gridSize":16,"__tilesetDefUid":null,
                  "entityInstances":[{"__identifier":"Spawn","iid":"spawn-iid"}]}
               ]}]}
            """);

        var imported = WorkspaceMapImport.Import(new WorkspaceMapImportRequest(path, [1], "level-iid"));
        Require(imported.SourceKind == "ldtk" && imported.SourceVersion == "1.5.3", "LDtk format identity mismatch");
        Require(imported.Asset.Layers.Length == 2, "LDtk visual Layer count mismatch");
        Require(imported.Asset.Layers[0].LayerId.Contains("bottom-iid", StringComparison.Ordinal)
            && imported.Asset.Layers[1].LayerId.Contains("top-iid", StringComparison.Ordinal), "LDtk top-first Layer order was not reversed");
        Require(imported.Asset.Layers[0].OffsetX == -16 && imported.Asset.Layers[0].OffsetY == 8, "LDtk total offset mismatch");
        Require(imported.Asset.Layers[1].Chunks[0].Cells[0].Transform == (WorkspaceTileTransform.FlipHorizontal | WorkspaceTileTransform.FlipVertical),
            "LDtk flip flags mismatch");
        Require(imported.Diagnostics.Any(value => value.Code == "LDTK_INTGRID_NOT_CONSUMED")
            && imported.Diagnostics.Any(value => value.Code == "LDTK_ENTITIES_NOT_IMPORTED")
            && imported.Diagnostics.Any(value => value.Code == "LDTK_ENUMS_NOT_CONSUMED"), "LDtk unconsumed semantics were not diagnosed");
        var first = WorkspaceTilemapAssetCodec.Encode(imported.Asset);
        var second = WorkspaceTilemapAssetCodec.Encode(WorkspaceMapImport.Import(new WorkspaceMapImportRequest(path, [1], "level-iid")).Asset);
        Require(first.AsSpan().SequenceEqual(second), "LDtk import is not deterministic");
        ExpectImport("IMPORT_STRICT_WARNING", () => WorkspaceMapImport.Import(new WorkspaceMapImportRequest(path, [1], "level-iid", true)));
        ExpectImport("LDTK_AMBIGUOUS_LEVEL", () => WorkspaceMapImport.Import(new WorkspaceMapImportRequest(path, [1], "missing")));
    }

    private static void ExpectImport(string code, Action operation)
    {
        try { operation(); }
        catch (WorkspaceMapImportException exception) when (exception.Code == code) { return; }
        throw new InvalidOperationException($"Expected map import error {code}.");
    }

    private static void ExpectInvalid(Action operation, string message)
    {
        try { operation(); }
        catch (InvalidDataException) { return; }
        throw new InvalidOperationException(message);
    }

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
