using System.Buffers.Binary;
using System.Text;
using System.Text.Json;
using Kadath.Editor.Protocol;
using Kadath.Editor.Workspace;

namespace Kadath.Editor.Workspace.ContractVerifier;

internal static class NeutralSceneVerifier
{
    internal static async Task VerifyAsync()
    {
        var root = Path.Combine(Path.GetTempPath(), $"kadath-neutral-scene-{Guid.NewGuid():N}");
        try
        {
            var project = CreateProject(root);
            var readModel = new WorkspaceReadModel();
            var initial = await readModel.ReadProjectAsync(project, default);
            Require(initial.Scene.SchemaVersion == 7
                && initial.Scene.GameplayProfile == "none"
                && initial.Scene.GoalPosition.Length == 0
                && initial.Scene.Objects is [{ ObjectId: "decor" }],
                "Neutral Scene v7 projection mismatch.");
            Require(initial.Scene.Prototypes is [{ PrototypeId: "runtime-orb", Kind: "sprite", TextureId: 1 }]
                && initial.Scene.Prototypes[0].Size.SequenceEqual([8, 10])
                && initial.Scene.Prototypes[0].Color.SequenceEqual([0.25, 0.5, 0.75, 1])
                && initial.Scene.Prototypes[0].Behaviors is { Count: 0 },
                "Project Snapshot did not expose the ordered Spawn Prototype read model.");
            Require(initial.Scene.Tilemaps is { Count: 0 }
                && initial.Scene.Textures is [{ SamplingProfile: "smooth_mipmap_anisotropic" }],
                "Scene v7 compatibility did not project empty Tilemaps and legacy sampling.");
            var initialHierarchy = await readModel.ReadHierarchyAsync(project, default);
            Require(!initialHierarchy.Nodes.Any(node => node.Id.Contains("prototype", StringComparison.OrdinalIgnoreCase)
                    || node.Kind.Contains("prototype", StringComparison.OrdinalIgnoreCase)),
                "Spawn Prototype leaked into the Scene Hierarchy.");

            var originalScene = File.ReadAllBytes(project.ScenePath);
            var decor = initial.Scene.Objects![0];
            var authoring = new WorkspaceAuthoringModel();
            var tilemapCommit = await authoring.ApplyAsync(
                project,
                initial.AuthoringRevision,
                new AuthoringPatch(
                    SceneTextures:
                    [
                        new SceneTextureAssignment(1, "asset://renderer2d/test.texture", "pixel_art")
                    ],
                    SceneTilemaps:
                    [
                        new SceneTilemapDefinition(
                            "background",
                            [0, 0],
                            [32, 32],
                            2,
                            2,
                            1,
                            4,
                            4,
                            [1, 0, 6, 16])
                    ]),
                default);
            Require(tilemapCommit.ChangedFields.SequenceEqual(["scene.textures", "scene.tilemaps"])
                && tilemapCommit.ProjectSnapshot.Scene.SchemaVersion == 8
                && tilemapCommit.ProjectSnapshot.Scene.Tilemaps is [{ TilemapId: "background", TextureId: 1 }]
                && tilemapCommit.ProjectSnapshot.Scene.Tilemaps[0].Cells.SequenceEqual([1, 0, 6, 16]),
                "Tilemap v7 to v8 authoring commit mismatch.");
            var tilemapScene = File.ReadAllBytes(project.ScenePath);

            var identityCamera = await authoring.ApplyAsync(
                project,
                tilemapCommit.Revision,
                new AuthoringPatch(SceneCamera: new SceneCameraDefinition([0, 0], 1)),
                default);
            Require(identityCamera.State == "unchanged"
                && identityCamera.ProjectSnapshot.Scene.SchemaVersion == 8
                && identityCamera.ProjectSnapshot.Scene.Camera is { Origin: [0, 0], Zoom: 1 }
                && File.ReadAllBytes(project.ScenePath).AsSpan().SequenceEqual(tilemapScene),
                "Identity Camera patch must not upgrade Scene v8.");

            var cameraCommit = await authoring.ApplyAsync(
                project,
                tilemapCommit.Revision,
                new AuthoringPatch(SceneCamera: new SceneCameraDefinition([200, 120], 2)),
                default);
            Require(cameraCommit.ChangedFields.SequenceEqual(["scene.camera"])
                && cameraCommit.ProjectSnapshot.Scene.SchemaVersion == 9
                && cameraCommit.ProjectSnapshot.Scene.Camera is { Origin: [200, 120], Zoom: 2 },
                "Camera v8 to v9 authoring commit mismatch.");
            var cameraScene = File.ReadAllBytes(project.ScenePath);
            var cameraUndone = await authoring.UndoAsync(project, cameraCommit.Revision, cameraCommit.UndoToken!, default);
            Require(cameraUndone.ProjectSnapshot.Scene.SchemaVersion == 8
                && cameraUndone.ProjectSnapshot.Scene.Camera is { Origin: [0, 0], Zoom: 1 }
                && File.ReadAllBytes(project.ScenePath).AsSpan().SequenceEqual(tilemapScene),
                "Camera upgrade undo was not byte-exact.");
            var cameraRedone = await authoring.UndoAsync(project, cameraUndone.Revision, cameraUndone.UndoToken!, default);
            Require(cameraRedone.ProjectSnapshot.Scene.SchemaVersion == 9
                && File.ReadAllBytes(project.ScenePath).AsSpan().SequenceEqual(cameraScene),
                "Camera redo was not byte-exact.");
            var cameraRestored = await authoring.UndoAsync(project, cameraRedone.Revision, cameraRedone.UndoToken!, default);
            Require(cameraRestored.ProjectSnapshot.Scene.SchemaVersion == 8
                && File.ReadAllBytes(project.ScenePath).AsSpan().SequenceEqual(tilemapScene),
                "Camera redo cleanup did not restore Scene v8.");
            var tilemapUndone = await authoring.UndoAsync(
                project,
                tilemapCommit.Revision,
                tilemapCommit.UndoToken!,
                default);
            Require(tilemapUndone.ProjectSnapshot.Scene.SchemaVersion == 7
                && tilemapUndone.ProjectSnapshot.Scene.Tilemaps is { Count: 0 }
                && File.ReadAllBytes(project.ScenePath).AsSpan().SequenceEqual(originalScene),
                "Tilemap v7 to v8 upgrade undo was not byte-exact.");
            var tilemapRedone = await authoring.UndoAsync(
                project,
                tilemapUndone.Revision,
                tilemapUndone.UndoToken!,
                default);
            Require(tilemapRedone.ProjectSnapshot.Scene.SchemaVersion == 8
                && tilemapRedone.ProjectSnapshot.Scene.Tilemaps is [{ TilemapId: "background" }]
                && File.ReadAllBytes(project.ScenePath).AsSpan().SequenceEqual(tilemapScene),
                "Tilemap v8 redo was not byte-exact.");
            var tilemapRestored = await authoring.UndoAsync(
                project,
                tilemapRedone.Revision,
                tilemapRedone.UndoToken!,
                default);
            Require(tilemapRestored.ProjectSnapshot.Scene.SchemaVersion == 7
                && File.ReadAllBytes(project.ScenePath).AsSpan().SequenceEqual(originalScene),
                "Tilemap redo cleanup did not restore the original Scene.");
            var tilemapDefinition = new SceneTilemapDefinition(
                "background", [0, 0], [32, 32], 2, 2, 1, 4, 4, [1, 0, 6, 16]);
            await ExpectAuthoringFailureAsync(() => authoring.ApplyAsync(
                project,
                tilemapRestored.Revision,
                new AuthoringPatch(SceneTilemaps: [tilemapDefinition]),
                default));
            await ExpectAuthoringFailureAsync(() => authoring.ApplyAsync(
                project,
                tilemapRestored.Revision,
                new AuthoringPatch(
                    SceneTextures: [new SceneTextureAssignment(1, "asset://renderer2d/test.texture", "pixel_art")],
                    SceneTilemaps: [tilemapDefinition with { Cells = [1, 2, 3] }]),
                default));
            await ExpectAuthoringFailureAsync(() => authoring.ApplyAsync(
                project,
                tilemapRestored.Revision,
                new AuthoringPatch(
                    SceneTextures: [new SceneTextureAssignment(1, "asset://renderer2d/test.texture", "pixel_art")],
                    SceneTilemaps: [tilemapDefinition, tilemapDefinition with { TilemapId = "foreground" }]),
                default));
            Require(File.ReadAllBytes(project.ScenePath).AsSpan().SequenceEqual(originalScene),
                "Rejected Tilemap candidates changed Scene source bytes.");
            var prototypeCommit = await authoring.ApplyAsync(
                project,
                tilemapRestored.Revision,
                new AuthoringPatch(ScenePrototypes:
                [
                    new ScenePrototypeDefinition(
                        "runtime-orb",
                        "sprite",
                        [12, 14],
                        [0.8, 0.6, 0.4, 1],
                        1,
                        [])
                ]),
                default);
            Require(prototypeCommit.ChangedFields.SequenceEqual(["scene.prototypes"])
                && prototypeCommit.ProjectSnapshot.Scene.Prototypes is [{ PrototypeId: "runtime-orb" }]
                && prototypeCommit.ProjectSnapshot.Scene.Prototypes[0].Size.SequenceEqual([12, 14]),
                "Spawn Prototype authoring commit mismatch.");
            var editedPrototypeScene = File.ReadAllBytes(project.ScenePath);
            var prototypeUndone = await authoring.UndoAsync(
                project,
                prototypeCommit.Revision,
                prototypeCommit.UndoToken!,
                default);
            Require(prototypeUndone.ProjectSnapshot.Scene.Prototypes![0].Size.SequenceEqual([8, 10])
                && File.ReadAllBytes(project.ScenePath).AsSpan().SequenceEqual(originalScene),
                "Spawn Prototype authoring undo was not byte-exact.");
            var prototypeRedone = await authoring.UndoAsync(
                project,
                prototypeUndone.Revision,
                prototypeUndone.UndoToken!,
                default);
            Require(prototypeRedone.ProjectSnapshot.Scene.Prototypes![0].Size.SequenceEqual([12, 14])
                && File.ReadAllBytes(project.ScenePath).AsSpan().SequenceEqual(editedPrototypeScene),
                "Spawn Prototype authoring redo was not byte-exact.");
            var prototypeRestored = await authoring.UndoAsync(
                project,
                prototypeRedone.Revision,
                prototypeRedone.UndoToken!,
                default);
            Require(File.ReadAllBytes(project.ScenePath).AsSpan().SequenceEqual(originalScene),
                "Spawn Prototype second undo was not byte-exact.");

            var originalPrototype = initial.Scene.Prototypes![0];
            ScenePrototypeDefinition Definition(
                string id = "runtime-orb",
                string kind = "sprite",
                double[]? size = null,
                double[]? color = null,
                uint textureId = 1) => new(
                    id,
                    kind,
                    size ?? originalPrototype.Size,
                    color ?? originalPrototype.Color,
                    textureId,
                    []);
            var unchangedPrototype = await authoring.ApplyAsync(
                project,
                prototypeRestored.Revision,
                new AuthoringPatch(ScenePrototypes: [Definition()]),
                default);
            Require(unchangedPrototype.State == "unchanged" && unchangedPrototype.ChangedFields.Length == 0,
                "Equivalent Spawn Prototype candidate was not a no-op.");
            await ExpectAuthoringFailureAsync(() => authoring.ApplyAsync(project, prototypeRestored.Revision,
                new AuthoringPatch(ScenePrototypes: [Definition(id: "Runtime-Orb")]), default));
            await ExpectAuthoringFailureAsync(() => authoring.ApplyAsync(project, prototypeRestored.Revision,
                new AuthoringPatch(ScenePrototypes: [Definition(kind: "goal")]), default));
            await ExpectAuthoringFailureAsync(() => authoring.ApplyAsync(project, prototypeRestored.Revision,
                new AuthoringPatch(ScenePrototypes: [Definition(size: [0, 10])]), default));
            await ExpectAuthoringFailureAsync(() => authoring.ApplyAsync(project, prototypeRestored.Revision,
                new AuthoringPatch(ScenePrototypes: [Definition(color: [1.1, 0.5, 0.75, 1])]), default));
            await ExpectAuthoringFailureAsync(() => authoring.ApplyAsync(project, prototypeRestored.Revision,
                new AuthoringPatch(ScenePrototypes: [Definition(textureId: 99)]), default));
            await ExpectAuthoringFailureAsync(() => authoring.ApplyAsync(project, prototypeRestored.Revision,
                new AuthoringPatch(ScenePrototypes: Enumerable.Range(1, 33)
                    .Select(index => Definition(id: $"prototype-{index}"))
                    .ToArray()), default));
            Require(File.ReadAllBytes(project.ScenePath).AsSpan().SequenceEqual(originalScene),
                "Rejected Spawn Prototype candidate changed Scene source bytes.");

            var orderedPrototypes = await authoring.ApplyAsync(
                project,
                prototypeRestored.Revision,
                new AuthoringPatch(ScenePrototypes:
                [
                    Definition(id: "prototype-first"),
                    Definition()
                ]),
                default);
            Require(orderedPrototypes.ProjectSnapshot.Scene.Prototypes!
                    .Select(value => value.PrototypeId).SequenceEqual(["prototype-first", "runtime-orb"]),
                "Project Snapshot did not preserve Source Prototype Order.");
            using (var orderedSource = JsonDocument.Parse(File.ReadAllBytes(project.ScenePath)))
            {
                Require(orderedSource.RootElement.GetProperty("prototypes").EnumerateArray()
                        .Select(value => value.GetProperty("prototypeId").GetString())
                        .SequenceEqual(["prototype-first", "runtime-orb"]),
                    "Scene serialization did not preserve Source Prototype Order.");
            }
            prototypeRestored = await authoring.UndoAsync(
                project,
                orderedPrototypes.Revision,
                orderedPrototypes.UndoToken!,
                default);
            Require(File.ReadAllBytes(project.ScenePath).AsSpan().SequenceEqual(originalScene),
                "Source Prototype Order undo was not byte-exact.");

            var deletePrototypes = await authoring.ApplyAsync(
                project,
                prototypeRestored.Revision,
                new AuthoringPatch(ScenePrototypes: []),
                default);
            Require(deletePrototypes.ProjectSnapshot.Scene.Prototypes is { Count: 0 },
                "Empty Spawn Prototype candidate did not delete the collection.");
            var deleteUndone = await authoring.UndoAsync(
                project,
                deletePrototypes.Revision,
                deletePrototypes.UndoToken!,
                default);
            Require(deleteUndone.ProjectSnapshot.Scene.Prototypes is [{ PrototypeId: "runtime-orb" }]
                && File.ReadAllBytes(project.ScenePath).AsSpan().SequenceEqual(originalScene),
                "Spawn Prototype collection delete undo was not byte-exact.");

            var commit = await authoring.ApplyAsync(project, deleteUndone.Revision, new AuthoringPatch(SceneObjects:
            [
                new SceneObjectDefinition(
                    decor.ObjectId,
                    decor.Kind,
                    [30, 40],
                    decor.Size,
                    decor.Color,
                    decor.TextureId,
                    Behaviors: decor.Behaviors?.Select(binding => new SceneBehaviorBindingDefinition(
                        binding.ScriptId,
                        binding.Parameters?.ToDictionary(parameter => parameter.Name, parameter => parameter.Value, StringComparer.Ordinal))).ToArray())
            ]), default);
            Require(commit.ChangedFields.SequenceEqual(["scene.objects"])
                && commit.ProjectSnapshot.Scene.Objects![0].Position.SequenceEqual([30, 40]),
                "Neutral Scene authoring commit mismatch.");
            var editedScene = File.ReadAllBytes(project.ScenePath);
            var undone = await authoring.UndoAsync(project, commit.Revision, commit.UndoToken!, default);
            Require(undone.ProjectSnapshot.Scene.Objects![0].Position.SequenceEqual([10, 20])
                && File.ReadAllBytes(project.ScenePath).AsSpan().SequenceEqual(originalScene),
                "Neutral Scene authoring undo was not byte-exact.");
            var redone = await authoring.UndoAsync(project, undone.Revision, undone.UndoToken!, default);
            Require(redone.ProjectSnapshot.Scene.Objects![0].Position.SequenceEqual([30, 40])
                && File.ReadAllBytes(project.ScenePath).AsSpan().SequenceEqual(editedScene),
                "Neutral Scene authoring redo did not restore the edited state.");
            undone = await authoring.UndoAsync(project, redone.Revision, redone.UndoToken!, default);
            Require(File.ReadAllBytes(project.ScenePath).AsSpan().SequenceEqual(originalScene),
                "Neutral Scene second undo was not byte-exact.");

            var atomicCandidate = await authoring.ApplyAsync(
                project,
                undone.Revision,
                new AuthoringPatch(
                    SceneTextures:
                    [
                        new SceneTextureAssignment(2, "asset://renderer2d/alternate.texture")
                    ],
                    SceneObjects:
                    [
                        new SceneObjectDefinition(
                            decor.ObjectId,
                            decor.Kind,
                            decor.Position,
                            decor.Size,
                            decor.Color,
                            2,
                            Behaviors: [])
                    ],
                    ScenePrototypes:
                    [
                        new ScenePrototypeDefinition(
                            "runtime-orb",
                            "sprite",
                            originalPrototype.Size,
                            originalPrototype.Color,
                            2,
                            [])
                    ]),
                default);
            Require(atomicCandidate.ChangedFields.SequenceEqual(["scene.textures", "scene.objects", "scene.prototypes"])
                && atomicCandidate.ProjectSnapshot.Scene.Textures is [{ TextureId: 2 }]
                && atomicCandidate.ProjectSnapshot.Scene.Objects is [{ TextureId: 2 }]
                && atomicCandidate.ProjectSnapshot.Scene.Prototypes is [{ TextureId: 2 }],
                "Texture/Object/Prototype atomic candidate was not committed as one Scene state.");
            var atomicUndone = await authoring.UndoAsync(
                project,
                atomicCandidate.Revision,
                atomicCandidate.UndoToken!,
                default);
            Require(File.ReadAllBytes(project.ScenePath).AsSpan().SequenceEqual(originalScene),
                "Texture/Object/Prototype atomic candidate undo was not byte-exact.");
            undone = atomicUndone;

            var legacyProject = CreateBehaviorSchemaProject(root);
            var legacySnapshot = await readModel.ReadProjectAsync(legacyProject, default);
            Require(legacySnapshot.Scene.SchemaVersion == 5 && legacySnapshot.Scene.Prototypes is { Count: 0 },
                "Scene v5 compatibility snapshot mismatch.");
            await ExpectAuthoringFailureAsync(() => authoring.ApplyAsync(
                legacyProject,
                legacySnapshot.AuthoringRevision,
                new AuthoringPatch(ScenePrototypes: []),
                default));

            // Gameplay Profile 是 Scene v7 的可编辑能力边界；关闭后必须继续支持字节级 Undo/Redo。
            var gameplayProject = CreateGameplayProject(root);
            var gameplayInitial = await readModel.ReadProjectAsync(gameplayProject, default);
            var gameplayScene = File.ReadAllBytes(gameplayProject.ScenePath);
            var disableGameplay = await authoring.ApplyAsync(
                gameplayProject,
                gameplayInitial.AuthoringRevision,
                new AuthoringPatch(SceneGameplayProfile: "none"),
                default);
            Require(disableGameplay.ChangedFields.SequenceEqual(["scene.gameplay.profile"])
                && disableGameplay.ProjectSnapshot.Scene.GameplayProfile == "none"
                && disableGameplay.ProjectSnapshot.Scene.GameplayTimeLimitSeconds is null,
                "Gameplay Profile disable authoring mismatch.");
            var neutralGameplayScene = File.ReadAllBytes(gameplayProject.ScenePath);
            var gameplayRestored = await authoring.UndoAsync(
                gameplayProject,
                disableGameplay.Revision,
                disableGameplay.UndoToken!,
                default);
            Require(gameplayRestored.ProjectSnapshot.Scene.GameplayProfile == "goal_hazard_v1"
                && File.ReadAllBytes(gameplayProject.ScenePath).AsSpan().SequenceEqual(gameplayScene),
                "Gameplay Profile disable undo was not byte-exact.");
            var neutralGameplayRestored = await authoring.UndoAsync(
                gameplayProject,
                gameplayRestored.Revision,
                gameplayRestored.UndoToken!,
                default);
            Require(neutralGameplayRestored.ProjectSnapshot.Scene.GameplayProfile == "none"
                && File.ReadAllBytes(gameplayProject.ScenePath).AsSpan().SequenceEqual(neutralGameplayScene),
                "Gameplay Profile disable redo was not byte-exact.");

            var enableGameplay = await authoring.ApplyAsync(
                gameplayProject,
                neutralGameplayRestored.Revision,
                new AuthoringPatch(
                    SceneGameplayProfile: "goal_hazard_v1",
                    SceneGameplayTimeLimitSeconds: 4.25),
                default);
            Require(enableGameplay.ChangedFields.SequenceEqual([
                    "scene.gameplay.profile",
                    "scene.gameplay.timeLimitSeconds"
                ])
                && enableGameplay.ProjectSnapshot.Scene.GameplayProfile == "goal_hazard_v1"
                && enableGameplay.ProjectSnapshot.Scene.GameplayTimeLimitSeconds == 4.25,
                "Gameplay Profile enable and time limit authoring mismatch.");
            var enabledGameplayScene = File.ReadAllBytes(gameplayProject.ScenePath);
            var enableUndone = await authoring.UndoAsync(
                gameplayProject,
                enableGameplay.Revision,
                enableGameplay.UndoToken!,
                default);
            Require(enableUndone.ProjectSnapshot.Scene.GameplayProfile == "none"
                && File.ReadAllBytes(gameplayProject.ScenePath).AsSpan().SequenceEqual(neutralGameplayScene),
                "Gameplay Profile enable undo was not byte-exact.");
            var enableRedone = await authoring.UndoAsync(
                gameplayProject,
                enableUndone.Revision,
                enableUndone.UndoToken!,
                default);
            Require(enableRedone.ProjectSnapshot.Scene.GameplayTimeLimitSeconds == 4.25
                && File.ReadAllBytes(gameplayProject.ScenePath).AsSpan().SequenceEqual(enabledGameplayScene),
                "Gameplay Profile enable redo was not byte-exact.");

            var artifact = WorkspaceSceneCodec.EncodeSource(originalScene);
            var info = WorkspaceSceneCodec.ValidateArtifact(artifact);
            Require(BinaryPrimitives.ReadUInt32LittleEndian(artifact.AsSpan(4, 4)) == 7
                && info.Format == "KSCN-SCENE-V7",
                "Neutral Scene bake did not produce KSCN v7.");

            var preview = new WorkspacePreviewModel(new WorkspacePublicationModel());
            var plan = await preview.PrepareAsync(new PreviewStartParameters(
                ConfigPath: project.PreviewPath,
                PackageRoot: root,
                ProjectName: project.ProjectName,
                LiveBake: true), default);
            Require(plan.InitialBake is { State: "succeeded" }
                && plan.RuntimeArguments.Contains("projects/neutral/.kadath/derived/scene.scene", StringComparer.Ordinal)
                && File.Exists(Path.Combine(project.ProjectDirectory, ".kadath", "derived", "scene.scene")),
                "Neutral Scene Live Bake preview plan mismatch.");
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
    }

    private static ProjectSessionInfo CreateProject(string root)
    {
        var projectDirectory = Path.Combine(root, "bin", "projects", "neutral");
        Directory.CreateDirectory(projectDirectory);
        Directory.CreateDirectory(Path.Combine(root, "bin", "assets", "renderer2d"));
        File.WriteAllBytes(Path.Combine(root, "bin", "assets", "renderer2d", "test.texture"), [1]);
        File.WriteAllBytes(Path.Combine(root, "bin", "assets", "renderer2d", "alternate.texture"), [2]);
        File.WriteAllBytes(Path.Combine(root, VerifierPlatform.RuntimeRelativePath), [0]);
        File.WriteAllText(Path.Combine(projectDirectory, "scene.json"), SceneJson, new UTF8Encoding(false));
        File.WriteAllText(Path.Combine(projectDirectory, "script.json"), ScriptJson, new UTF8Encoding(false));
        File.WriteAllText(Path.Combine(projectDirectory, "preview.json"), $$$"""
        {"schemaVersion":1,"runtime":{"executable":"{{{VerifierPlatform.RuntimeRelativePath}}}","workingDirectory":"bin","arguments":["--scene","projects/neutral/scene.json","--script","projects/neutral/script.json"]}}
        """, new UTF8Encoding(false));
        return new ProjectSessionInfo(root, "neutral", projectDirectory,
            Path.Combine(projectDirectory, "scene.json"),
            Path.Combine(projectDirectory, "script.json"),
            Path.Combine(projectDirectory, "preview.json"), 1);
    }

    private static ProjectSessionInfo CreateGameplayProject(string root)
    {
        var projectDirectory = Path.Combine(root, "bin", "projects", "gameplay");
        Directory.CreateDirectory(Path.Combine(projectDirectory, "scripts"));
        File.WriteAllText(Path.Combine(projectDirectory, "scene.json"), GameplaySceneJson, new UTF8Encoding(false));
        File.WriteAllText(Path.Combine(projectDirectory, "script.json"), GameplayScriptJson, new UTF8Encoding(false));
        File.WriteAllText(Path.Combine(projectDirectory, "scripts", "patrol.luau"), GameplayLuau, new UTF8Encoding(false));
        File.WriteAllText(Path.Combine(projectDirectory, "preview.json"), $$$"""
        {"schemaVersion":1,"runtime":{"executable":"{{{VerifierPlatform.RuntimeRelativePath}}}","workingDirectory":"bin","arguments":["--scene","projects/gameplay/scene.json","--script","projects/gameplay/script.json"]}}
        """, new UTF8Encoding(false));
        return new ProjectSessionInfo(root, "gameplay", projectDirectory,
            Path.Combine(projectDirectory, "scene.json"),
            Path.Combine(projectDirectory, "script.json"),
            Path.Combine(projectDirectory, "preview.json"), 1);
    }

    private static ProjectSessionInfo CreateBehaviorSchemaProject(string root)
    {
        var projectDirectory = Path.Combine(root, "bin", "projects", "behavior-v5");
        Directory.CreateDirectory(Path.Combine(projectDirectory, "scripts"));
        File.WriteAllText(Path.Combine(projectDirectory, "scene.json"), BehaviorSchemaSceneJson, new UTF8Encoding(false));
        File.WriteAllText(Path.Combine(projectDirectory, "script.json"), GameplayScriptJson, new UTF8Encoding(false));
        File.WriteAllText(Path.Combine(projectDirectory, "scripts", "patrol.luau"), GameplayLuau, new UTF8Encoding(false));
        File.WriteAllText(Path.Combine(projectDirectory, "preview.json"), $$$"""
        {"schemaVersion":1,"runtime":{"executable":"{{{VerifierPlatform.RuntimeRelativePath}}}","workingDirectory":"bin","arguments":["--scene","projects/behavior-v5/scene.json","--script","projects/behavior-v5/script.json"]}}
        """, new UTF8Encoding(false));
        return new ProjectSessionInfo(root, "behavior-v5", projectDirectory,
            Path.Combine(projectDirectory, "scene.json"),
            Path.Combine(projectDirectory, "script.json"),
            Path.Combine(projectDirectory, "preview.json"), 1);
    }

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static async Task ExpectAuthoringFailureAsync(Func<Task<WorkspaceAuthoringCommit>> action)
    {
        try
        {
            await action();
            throw new InvalidOperationException("Expected Spawn Prototype authoring failure was not raised.");
        }
        catch (WorkspaceAuthoringException exception) when (exception.Kind == WorkspaceAuthoringFailureKind.InvalidPatch)
        {
        }
    }

    private const string SceneJson = """
    {
      "schemaVersion": 7,
      "textures": [
        { "textureId": 1, "artifact": "assets/renderer2d/test.texture" }
      ],
      "objects": [
        { "objectId": "decor", "kind": "sprite", "transform": { "position": [10, 20] }, "sprite": { "size": [16, 16], "color": [1, 1, 1, 1], "textureId": 1 }, "behaviors": [] }
      ],
      "prototypes": [
        { "prototypeId": "runtime-orb", "kind": "sprite", "sprite": { "size": [8, 10], "color": [0.25, 0.5, 0.75, 1], "textureId": 1 }, "behaviors": [] }
      ]
    }
    """;

    private const string ScriptJson = """
    {
      "schemaVersion": 1,
      "instructions": [
        { "hook": "on_start", "op": "set_goal_position", "value": [0, 0] },
        { "hook": "fixed_update", "op": "move_goal_velocity", "value": [0, 0] }
      ]
    }
    """;

    private const string GameplaySceneJson = """
    {
      "schemaVersion": 7,
      "textures": [
        { "textureId": 1, "artifact": "assets/renderer2d/test.texture" }
      ],
      "objects": [
        { "objectId": "player", "kind": "player", "transform": { "position": [100, 100] }, "sprite": { "size": [32, 32], "color": [1, 1, 1, 1], "textureId": 1 }, "player": { "moveSpeed": 100 }, "behaviors": [] },
        { "objectId": "goal", "kind": "goal", "transform": { "position": [300, 100] }, "sprite": { "size": [32, 32], "color": [1, 1, 0, 1], "textureId": 1 }, "behaviors": [] },
        { "objectId": "hazard", "kind": "patrol_hazard", "transform": { "position": [200, 200] }, "sprite": { "size": [32, 32], "color": [1, 0, 0, 1], "textureId": 1 }, "behaviors": [{ "scriptId": 1, "parameters": {} }] }
      ],
      "prototypes": [],
      "gameplay": { "profile": "goal_hazard_v1", "timeLimitSeconds": 3 }
    }
    """;

    private const string GameplayScriptJson = """
    {
      "schemaVersion": 2,
      "scripts": [
        { "scriptId": 1, "source": "scripts/patrol.luau" }
      ]
    }
    """;

    private const string BehaviorSchemaSceneJson = """
    {
      "schemaVersion": 5,
      "textures": [
        { "textureId": 1, "artifact": "assets/renderer2d/test.texture" }
      ],
      "objects": [
        { "objectId": "player", "kind": "player", "transform": { "position": [100, 100] }, "sprite": { "size": [32, 32], "color": [1, 1, 1, 1], "textureId": 1 }, "player": { "moveSpeed": 100 }, "behaviors": [] },
        { "objectId": "goal", "kind": "goal", "transform": { "position": [300, 100] }, "sprite": { "size": [32, 32], "color": [1, 1, 0, 1], "textureId": 1 }, "behaviors": [] },
        { "objectId": "hazard", "kind": "patrol_hazard", "transform": { "position": [200, 200] }, "sprite": { "size": [32, 32], "color": [1, 0, 0, 1], "textureId": 1 }, "behaviors": [{ "scriptId": 1, "parameters": {} }] }
      ]
    }
    """;

    private const string GameplayLuau = """
    --!strict
    return {
        fixed_update = function(self: Kadath.Object, dt: number)
            self:translate(0, dt)
        end,
    }
    """;
}
