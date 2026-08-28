using Kadath.Editor.Workspace;
using Kadath.Editor.Protocol;
using System.Buffers.Binary;

namespace Kadath.Editor.Workspace.ContractVerifier;

internal static class TilemapImportVerifier
{
    internal static async Task<string> EmitRuntimeFixtureAsync(string packageRoot)
    {
        if (Directory.Exists(packageRoot) && Directory.EnumerateFileSystemEntries(packageRoot).Any())
            throw new InvalidOperationException("Runtime fixture output directory must be empty.");

        var projectDirectory = Path.Combine(packageRoot, "bin", "projects", "map-demo");
        var rendererAssets = Path.Combine(packageRoot, "bin", "assets", "renderer2d");
        Directory.CreateDirectory(projectDirectory);
        Directory.CreateDirectory(rendererAssets);
        File.WriteAllBytes(Path.Combine(packageRoot, VerifierPlatform.RuntimeRelativePath), [0]);

        // 两张小图同时承担跨语言格式验证和肉眼可辨的 atlas 采样验证。
        File.WriteAllBytes(Path.Combine(rendererAssets, "ground.texture"), BuildTextureArtifact(2, 2,
        [
            255, 0, 0, 255,   0, 255, 0, 255,
            0, 0, 255, 255,   255, 255, 0, 255
        ]));
        File.WriteAllBytes(Path.Combine(rendererAssets, "decor.texture"), BuildTextureArtifact(2, 1,
        [
            255, 0, 255, 255,  0, 255, 255, 255
        ]));

        var scenePath = Path.Combine(projectDirectory, "scene.json");
        var scriptPath = Path.Combine(projectDirectory, "script.json");
        var previewPath = Path.Combine(projectDirectory, "preview.json");
        File.WriteAllText(scenePath,
            """
            {"schemaVersion":9,"textures":[
              {"textureId":1,"artifact":"assets/renderer2d/ground.texture","samplingProfile":"smooth_mipmap_anisotropic"},
              {"textureId":2,"artifact":"assets/renderer2d/decor.texture","samplingProfile":"smooth_mipmap_anisotropic"}],
             "objects":[{"objectId":"sentinel","kind":"sprite","transform":{"position":[1000,1000]},
               "sprite":{"size":[1,1],"color":[1,1,1,1],"textureId":1},"behaviors":[]}],
             "prototypes":[],"tilemaps":[],"camera":{"origin":[-2,-2],"zoom":8}}
            """);
        File.WriteAllText(scriptPath,
            """{"schemaVersion":1,"instructions":[{"hook":"on_start","op":"set_goal_position","value":[0,0]},{"hook":"fixed_update","op":"move_goal_velocity","value":[0,0]}]}""");
        File.WriteAllText(previewPath,
            $$$"""{"schemaVersion":1,"runtime":{"executable":"{{{VerifierPlatform.RuntimeRelativePath}}}","workingDirectory":"bin","arguments":["--scene","projects/map-demo/scene.json","--script","projects/map-demo/script.json"]}}""");

        var project = new ProjectSessionInfo(packageRoot, "map-demo", projectDirectory, scenePath, scriptPath, previewPath, 1);
        var snapshot = await new WorkspaceReadModel().ReadProjectAsync(project, default);
        var mapPath = Path.GetFullPath("tools/fixtures/tilemap-chunked-layers-02/world.tmj");
        var result = await new WorkspaceTilemapImportModel().ImportAsync(project, new TilemapImportParameters(
            null, snapshot.AuthoringRevision, mapPath, "world", "world", [1, 2]), default);
        if (result.State != "succeeded") throw new InvalidOperationException("Runtime Tilemap fixture import did not succeed.");

        var runtimeScenePath = Path.Combine(projectDirectory, "runtime.scene");
        File.WriteAllBytes(runtimeScenePath, WorkspaceSceneCodec.EncodeSource(File.ReadAllBytes(scenePath)));
        return runtimeScenePath;
    }

    internal static async Task VerifyAsync()
    {
        VerifyArtifactCodec();
        VerifyFloorDivision();
        var root = Path.Combine(Path.GetTempPath(), $"kadath-map-import-{Guid.NewGuid():N}");
        Directory.CreateDirectory(root);
        try
        {
            VerifyTiled(root);
            VerifyLdtk(root);
            VerifyRepositoryFixtures();
            await VerifyWorkspaceImportAsync(root);
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
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

    private static async Task VerifyWorkspaceImportAsync(string root)
    {
        var packageRoot = Path.Combine(root, "package");
        var projectDirectory = Path.Combine(packageRoot, "bin", "projects", "map-demo");
        var rendererAssets = Path.Combine(packageRoot, "bin", "assets", "renderer2d");
        Directory.CreateDirectory(projectDirectory);
        Directory.CreateDirectory(rendererAssets);
        File.WriteAllBytes(Path.Combine(packageRoot, VerifierPlatform.RuntimeRelativePath), [0]);
        File.WriteAllBytes(Path.Combine(rendererAssets, "ground.texture"), [1]);
        File.WriteAllBytes(Path.Combine(rendererAssets, "decor.texture"), [2]);
        var scenePath = Path.Combine(projectDirectory, "scene.json");
        var scriptPath = Path.Combine(projectDirectory, "script.json");
        var previewPath = Path.Combine(projectDirectory, "preview.json");
        File.WriteAllText(scenePath,
            """
            {"schemaVersion":9,"textures":[
              {"textureId":1,"artifact":"assets/renderer2d/ground.texture","samplingProfile":"smooth_mipmap_anisotropic"},
              {"textureId":2,"artifact":"assets/renderer2d/decor.texture","samplingProfile":"smooth_mipmap_anisotropic"}],
             "objects":[{"objectId":"decor","kind":"sprite","transform":{"position":[0,0]},
               "sprite":{"size":[16,16],"color":[1,1,1,1],"textureId":1},"behaviors":[]}],
             "prototypes":[],"tilemaps":[],"camera":{"origin":[0,0],"zoom":1}}
            """);
        File.WriteAllText(scriptPath,
            """{"schemaVersion":1,"instructions":[{"hook":"on_start","op":"set_goal_position","value":[0,0]},{"hook":"fixed_update","op":"move_goal_velocity","value":[0,0]}]}""");
        File.WriteAllText(previewPath,
            $$$"""{"schemaVersion":1,"runtime":{"executable":"{{{VerifierPlatform.RuntimeRelativePath}}}","workingDirectory":"bin","arguments":["--scene","projects/map-demo/scene.json","--script","projects/map-demo/script.json"]}}""");
        var project = new ProjectSessionInfo(packageRoot, "map-demo", projectDirectory, scenePath, scriptPath, previewPath, 1);
        var readModel = new WorkspaceReadModel();
        var before = await readModel.ReadProjectAsync(project, default);
        var importer = new WorkspaceTilemapImportModel();
        var result = await importer.ImportAsync(project, new TilemapImportParameters(
            null,
            before.AuthoringRevision,
            Path.Combine(root, "world.tmj"),
            "world",
            "world",
            [1, 2]), default);
        Require(result.State == "succeeded" && result.SourceKind == "tiled" && result.LayerCount == 1 && result.CellCount == 7,
            "Workspace Tilemap import summary mismatch");
        Require(File.Exists(Path.Combine(packageRoot, "bin", result.RelativePath.Replace('/', Path.DirectorySeparatorChar))),
            "Workspace Tilemap artifact was not published");
        Require(result.ProjectSnapshot.Scene.SchemaVersion == 10
            && result.ProjectSnapshot.Scene.ChunkedTilemaps is { Count: 1 }
            && result.ProjectSnapshot.Scene.Tilemaps is { Count: 0 }, "Workspace Tilemap import did not upgrade Scene v10");
        Require(result.ProjectSnapshot.Scene.Textures!.Where(texture => texture.TextureId is 1 or 2)
            .All(texture => texture.SamplingProfile == "pixel_art"), "Workspace Tilemap import did not atomically set pixel_art profiles");
        var encodedScene = WorkspaceSceneCodec.EncodeSource(File.ReadAllBytes(scenePath));
        Require(encodedScene.AsSpan(0, 4).SequenceEqual("KSCN"u8), "Workspace Scene v10 did not Bake to KSCN");

        await ExpectTilemapImportAsync("tilemap_import_revision_conflict", () => importer.ImportAsync(project, new TilemapImportParameters(
            null,
            new string('0', 64),
            Path.Combine(root, "world.tmj"),
            "conflict",
            "other",
            [1, 2]), default));
        var tilemapDirectory = Path.Combine(packageRoot, "bin", "assets", "tilemaps");
        Require(!Directory.EnumerateFiles(tilemapDirectory, "conflict-*.tilemap").Any(), "revision-conflicted Tilemap import left an owned artifact");
    }

    private static void VerifyRepositoryFixtures()
    {
        var root = Path.GetFullPath("tools/fixtures/tilemap-chunked-layers-02");
        var tiled = WorkspaceMapImport.Import(new WorkspaceMapImportRequest(Path.Combine(root, "world.tmj"), [1, 2]));
        Require(tiled.Asset.Layers.Length == 2 && tiled.Diagnostics.Any(value => value.Code == "TILED_LAYER_NOT_IMPORTED"),
            "repository Tiled fixture did not cover Layers and diagnostics");
        var ldtk = WorkspaceMapImport.Import(new WorkspaceMapImportRequest(Path.Combine(root, "world.ldtk"), [1], "level-0-iid"));
        Require(ldtk.SourceDocuments.Any(path => path.EndsWith("Level_0.ldtkl", StringComparison.Ordinal))
            && ldtk.Asset.Layers.Length == 2
            && ldtk.Diagnostics.Any(value => value.Code == "LDTK_INTGRID_NOT_CONSUMED"),
            "repository LDtk external Level fixture did not cover Layers and diagnostics");
    }

    private static byte[] BuildTextureArtifact(int width, int height, byte[] basePixels)
    {
        if (basePixels.Length != checked(width * height * 4)) throw new ArgumentException("RGBA payload mismatch.");
        var levels = new List<byte[]> { basePixels };
        var levelWidth = width;
        var levelHeight = height;
        var previous = basePixels;
        while (levelWidth > 1 || levelHeight > 1)
        {
            var nextWidth = Math.Max(1, levelWidth / 2);
            var nextHeight = Math.Max(1, levelHeight / 2);
            var next = new byte[checked(nextWidth * nextHeight * 4)];
            for (var y = 0; y < nextHeight; y++)
            for (var x = 0; x < nextWidth; x++)
            for (var channel = 0; channel < 4; channel++)
            {
                var sum = 0;
                for (var dy = 0; dy < 2; dy++)
                for (var dx = 0; dx < 2; dx++)
                {
                    var sourceX = Math.Min(levelWidth - 1, x * 2 + dx);
                    var sourceY = Math.Min(levelHeight - 1, y * 2 + dy);
                    sum += previous[(sourceY * levelWidth + sourceX) * 4 + channel];
                }
                next[(y * nextWidth + x) * 4 + channel] = (byte)(sum / 4);
            }
            levels.Add(next);
            previous = next;
            levelWidth = nextWidth;
            levelHeight = nextHeight;
        }

        var pixelBytes = levels.Sum(level => level.Length);
        var artifact = new byte[24 + pixelBytes];
        "KDAT"u8.CopyTo(artifact);
        BinaryPrimitives.WriteUInt32LittleEndian(artifact.AsSpan(4, 4), 2);
        BinaryPrimitives.WriteUInt32LittleEndian(artifact.AsSpan(8, 4), (uint)width);
        BinaryPrimitives.WriteUInt32LittleEndian(artifact.AsSpan(12, 4), (uint)height);
        BinaryPrimitives.WriteUInt32LittleEndian(artifact.AsSpan(16, 4), (uint)levels.Count);
        BinaryPrimitives.WriteUInt32LittleEndian(artifact.AsSpan(20, 4), (uint)pixelBytes);
        var offset = 24;
        foreach (var level in levels)
        {
            level.CopyTo(artifact, offset);
            offset += level.Length;
        }
        return artifact;
    }

    private static async Task ExpectTilemapImportAsync(string code, Func<Task<TilemapImportResult>> operation)
    {
        try { _ = await operation(); }
        catch (WorkspaceTilemapImportException exception) when (exception.Code == code) { return; }
        throw new InvalidOperationException($"Expected Workspace Tilemap import error {code}.");
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
