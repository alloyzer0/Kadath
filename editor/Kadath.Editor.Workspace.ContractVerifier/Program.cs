using System.Security.Cryptography;
using System.Buffers.Binary;
using System.IO.Compression;
using System.Text;
using System.Text.Json;
using Kadath.Editor.Protocol;
using Kadath.Editor.Workspace;

namespace Kadath.Editor.Workspace.ContractVerifier;

internal static class Program
{
    public static async Task<int> Main()
    {
        var root = Path.Combine(Path.GetTempPath(), $"kadath-workspace-read-model-{Guid.NewGuid():N}");
        try
        {
            var project = CreateFixture(root);
            var readModel = new WorkspaceReadModel();
            var before = TreeIdentity(root);

            var model = await readModel.ReadProjectAsync(project, default);
            Require(model.ModelVersion == 1 && model.Scene.SchemaVersion == 3 && model.Scene.Textures?.Count == 3 && model.Scene.Objects?.Count == 3, "project snapshot mismatch");
            Require(model.Scene.PlayerTextureId == 1 && model.Scene.GoalTextureId == 2 && model.Scene.HazardTextureId == 3, "texture bindings mismatch");
            Require(model.AuthoringRevision == ExpectedAuthoringRevision(project.ScenePath, project.ScriptPath), "authoring revision mismatch");

            var hierarchy = await readModel.ReadHierarchyAsync(project, default);
            Require(hierarchy.SnapshotVersion == 2 && hierarchy.Nodes.Length == 11 && hierarchy.Nodes[0].Id == "scene"
                && hierarchy.Nodes[1].Id == "scene.textures[1]" && hierarchy.Nodes[4].Id == "scene.objects[player]", "hierarchy ordering mismatch");
            Require(hierarchy.Nodes.Count(node => node.ParentId is null) == 3, "hierarchy roots mismatch");

            var assets = await readModel.ReadAssetsAsync(project, default);
            Require(assets.Root == "bin/assets" && assets.ItemCount == 4, "asset catalog mismatch");
            Require(assets.Items.Select(item => item.RelativePath).SequenceEqual(assets.Items.Select(item => item.RelativePath).OrderBy(value => value, StringComparer.OrdinalIgnoreCase).ThenBy(value => value, StringComparer.Ordinal)), "asset ordering mismatch");
            Require(assets.Items.Any(item => item.AssetId == "asset://renderer2d/test.texture" && item.Category == "Texture"), "texture catalog item missing");

            await VerifyAuthoringAsync(project, readModel);
            await ProjectLifecycleVerifier.VerifyAsync();
            await PublicationVerifier.VerifyAsync();
            await BehaviorPublicationVerifier.VerifyAsync();
            await VerifyPreviewModelAsync(project);

            var missing = await readModel.ReadPublicationAsync(project, "debug", default);
            Require(missing.State == "missing" && !missing.ManifestPresent && missing.Scene.State == "missing" && missing.Script.State == "missing", "publication missing mismatch");

            WriteArtifactsAndManifest(project);
            var current = await readModel.ReadPublicationAsync(project, "debug", default);
            Require(current.State == "current" && current.ManifestPresent
                && current.Scene.ArtifactBytes == WorkspaceSceneCodec.EncodeSource(File.ReadAllBytes(project.ScenePath)).Length
                && current.Script.ArtifactBytes == 48, "publication current mismatch");

            var originalScene = File.ReadAllBytes(project.ScenePath);
            var manifestPath = Path.Combine(project.ProjectDirectory, ".kadath", "derived", ".live-bake.manifest.json");
            var originalManifest = File.ReadAllBytes(manifestPath);
            File.AppendAllText(project.ScenePath, "\n", Encoding.UTF8);
            var dirty = await readModel.ReadPublicationAsync(project, "debug", default);
            Require(dirty.State == "source_dirty" && dirty.Scene.State == "source_dirty" && dirty.Script.State == "current", "publication dirty mismatch");
            var profileMismatch = await readModel.ReadPublicationAsync(project, "release", default);
            Require(profileMismatch.State == "profile_mismatch" && profileMismatch.Script.State == "profile_mismatch", "profile mismatch projection failed");

            var sceneArtifact = Path.Combine(project.ProjectDirectory, ".kadath", "derived", "scene.scene");
            var originalArtifact = File.ReadAllBytes(sceneArtifact);
            var corrupted = originalArtifact.ToArray();
            corrupted[0] = 0;
            File.WriteAllBytes(sceneArtifact, corrupted);
            var invalid = await readModel.ReadPublicationAsync(project, "debug", default);
            Require(invalid.State == "artifact_invalid" && invalid.Scene.State == "artifact_invalid", "artifact invalid priority mismatch");
            File.WriteAllBytes(sceneArtifact, originalArtifact);
            File.WriteAllBytes(project.ScenePath, originalScene);

            File.WriteAllText(project.ScenePath, Encoding.UTF8.GetString(originalScene).Replace("\"schemaVersion\":3", "\"schemaVersion\":4", StringComparison.Ordinal), Encoding.UTF8);
            await ExpectWorkspaceFailureAsync(() => readModel.ReadProjectAsync(project, default), WorkspaceReadFailureKind.Input);
            File.WriteAllBytes(project.ScenePath, originalScene);

            File.WriteAllText(project.ScenePath, "{", Encoding.UTF8);
            await ExpectWorkspaceFailureAsync(() => readModel.ReadProjectAsync(project, default), WorkspaceReadFailureKind.Input);
            File.WriteAllBytes(project.ScenePath, originalScene);

            var missingPreview = project.PreviewPath + ".missing";
            File.Move(project.PreviewPath, missingPreview);
            await ExpectWorkspaceFailureAsync(() => readModel.ReadProjectAsync(project, default), WorkspaceReadFailureKind.Input);
            File.Move(missingPreview, project.PreviewPath);

            var escapedManifest = Encoding.UTF8.GetString(originalManifest).Replace(".kadath/derived/scene.scene", "../escape.scene", StringComparison.Ordinal);
            File.WriteAllText(manifestPath, escapedManifest, Encoding.UTF8);
            var escaped = await readModel.ReadPublicationAsync(project, "debug", default);
            Require(escaped.State == "artifact_invalid" && escaped.Scene.State == "artifact_invalid", "manifest path boundary mismatch");
            File.WriteAllBytes(manifestPath, originalManifest);

            var invalidManifestType = Encoding.UTF8.GetString(originalManifest).Replace("\"artifactBytes\":258", "\"artifactBytes\":\"258\"", StringComparison.Ordinal);
            File.WriteAllText(manifestPath, invalidManifestType, Encoding.UTF8);
            var invalidManifest = await readModel.ReadPublicationAsync(project, "debug", default);
            Require(invalidManifest.State == "artifact_invalid" && invalidManifest.ManifestPresent, "manifest type validation mismatch");
            File.WriteAllBytes(manifestPath, originalManifest);

            var derived = Path.Combine(project.ProjectDirectory, ".kadath", "derived");
            var realDerived = Path.Combine(project.ProjectDirectory, ".kadath", "derived-real");
            Directory.Move(derived, realDerived);
            Directory.CreateSymbolicLink(derived, realDerived);
            await ExpectWorkspaceFailureAsync(() => readModel.ReadPublicationAsync(project, "debug", default), WorkspaceReadFailureKind.Input);
            Directory.Delete(derived);
            Directory.Move(realDerived, derived);

            var assetRoot = Path.Combine(root, "bin", "assets");
            var externalAsset = Path.Combine(root, "external.asset");
            var linkedAsset = Path.Combine(assetRoot, "linked.asset");
            File.WriteAllText(externalAsset, "external", Encoding.UTF8);
            File.CreateSymbolicLink(linkedAsset, externalAsset);
            await ExpectWorkspaceFailureAsync(() => readModel.ReadAssetsAsync(project, default), WorkspaceReadFailureKind.Input);
            File.Delete(linkedAsset);
            File.Delete(externalAsset);

            var overflowAssets = Path.Combine(assetRoot, "overflow");
            Directory.CreateDirectory(overflowAssets);
            for (var index = 0; index < 4093; index++) File.WriteAllBytes(Path.Combine(overflowAssets, $"{index:D4}.asset"), []);
            await ExpectWorkspaceFailureAsync(() => readModel.ReadAssetsAsync(project, default), WorkspaceReadFailureKind.Input);
            Directory.Delete(overflowAssets, true);

            using var cancelled = new CancellationTokenSource();
            cancelled.Cancel();
            await ExpectAsync<OperationCanceledException>(() => readModel.ReadProjectAsync(project, cancelled.Token));

            Require(before == TreeIdentity(root, ignoreDerived: true), "read model modified source assets");
            await VerifyTextureImportAsync(project);
            Console.WriteLine("project_snapshot=ok");
            Console.WriteLine("hierarchy_snapshot=ok");
            Console.WriteLine("asset_catalog_snapshot=ok");
            Console.WriteLine("publication_state_machine=ok");
            Console.WriteLine("behavior_publication_v2=ok");
            Console.WriteLine("authoring_transaction=ok");
            Console.WriteLine("texture_import=ok");
            Console.WriteLine("native_publication=ok");
            Console.WriteLine("project_lifecycle=ok");
            Console.WriteLine("failure_boundaries=ok");
            Console.WriteLine("read_only=ok");
            Console.WriteLine("pwsh_dependency=none");
            Console.WriteLine("verification=ok");
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine($"verification=failed: {exception}");
            return 1;
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }

    private static async Task VerifyAuthoringAsync(ProjectSessionInfo project, WorkspaceReadModel readModel)
    {
        var originalScene = File.ReadAllBytes(project.ScenePath);
        var originalScript = File.ReadAllBytes(project.ScriptPath);
        var originalPreview = File.ReadAllBytes(project.PreviewPath);
        var assetsRoot = Path.Combine(project.PackageRoot, "bin", "assets");
        var assetsIdentity = TreeIdentity(assetsRoot);
        var derived = Path.Combine(project.ProjectDirectory, ".kadath", "derived");
        Directory.CreateDirectory(derived);
        File.WriteAllBytes(Path.Combine(derived, "authoring-sentinel.bin"), [9, 8, 7]);
        var derivedIdentity = TreeIdentity(derived);
        var initial = await readModel.ReadProjectAsync(project, default);
        var authoring = new WorkspaceAuthoringModel();
        var strictScene = AddRootProperty(File.ReadAllText(project.ScenePath, Encoding.UTF8), "\"extension\":true");
        File.WriteAllText(project.ScenePath, strictScene, Encoding.UTF8);
        await ExpectAuthoringFailureAsync(
            () => authoring.ApplyAsync(project, initial.AuthoringRevision, new AuthoringPatch(SceneGoalPosition: [705, 205]), default),
            WorkspaceAuthoringFailureKind.Input);
        File.WriteAllBytes(project.ScenePath, originalScene);
        var patch = new AuthoringPatch([710, 210], [690, 210], [2, -2], 2, 3, 1);
        var commit = await authoring.ApplyAsync(project, initial.AuthoringRevision, patch, default);
        var expectedFields = new[]
        {
            "scene.goal.position", "script.goal.position", "script.goal.velocity",
            "scene.player.textureId", "scene.goal.textureId", "scene.hazard.textureId"
        };
        Require(commit.State == "succeeded" && commit.PreviousRevision == initial.AuthoringRevision && commit.Revision != initial.AuthoringRevision, "authoring commit identity mismatch");
        Require(commit.ChangedFields.SequenceEqual(expectedFields), "authoring changed fields ordering mismatch");
        Require(commit.ProjectSnapshot.AuthoringRevision == commit.Revision && commit.HierarchySnapshot.ProjectName == project.ProjectName, "authoring committed snapshots mismatch");
        Require(commit.UndoToken is not null, "authoring undo token missing");
        var committedScene = File.ReadAllBytes(project.ScenePath);
        var committedScript = File.ReadAllBytes(project.ScriptPath);
        var noOp = await authoring.ApplyAsync(project, commit.Revision, patch, default);
        Require(noOp.State == "unchanged" && noOp.Revision == commit.Revision && noOp.ChangedFields.Length == 0 && noOp.UndoToken is null, "authoring no-op mismatch");
        Require(committedScene.AsSpan().SequenceEqual(File.ReadAllBytes(project.ScenePath)) && committedScript.AsSpan().SequenceEqual(File.ReadAllBytes(project.ScriptPath)), "authoring no-op wrote sources");

        await ExpectAuthoringFailureAsync(() => authoring.ApplyAsync(project, initial.AuthoringRevision, new AuthoringPatch([711, 211]), default), WorkspaceAuthoringFailureKind.RevisionConflict);
        await ExpectAuthoringFailureAsync(() => authoring.ApplyAsync(project, "bad", new AuthoringPatch([711, 211]), default), WorkspaceAuthoringFailureKind.InvalidExpectedRevision);
        await ExpectAuthoringFailureAsync(() => authoring.ApplyAsync(project, commit.Revision, new AuthoringPatch(), default), WorkspaceAuthoringFailureKind.InvalidPatch);
        await ExpectAuthoringFailureAsync(() => authoring.ApplyAsync(project, commit.Revision, new AuthoringPatch(SceneGoalPosition: [double.NaN, 1]), default), WorkspaceAuthoringFailureKind.InvalidPatch);
        await ExpectAuthoringFailureAsync(() => authoring.ApplyAsync(project, commit.Revision, new AuthoringPatch(ScenePlayerTextureId: 0), default), WorkspaceAuthoringFailureKind.InvalidPatch);
        await ExpectAuthoringFailureAsync(() => authoring.ApplyAsync(project, commit.Revision, new AuthoringPatch(ScenePlayerTextureId: 4), default), WorkspaceAuthoringFailureKind.InvalidPatch);
        Require(committedScene.AsSpan().SequenceEqual(File.ReadAllBytes(project.ScenePath)) && committedScript.AsSpan().SequenceEqual(File.ReadAllBytes(project.ScriptPath)), "authoring rejection changed sources");

        var racedScript = File.ReadAllBytes(project.ScriptPath);
        var racing = new WorkspaceAuthoringModel(() => File.AppendAllText(project.ScriptPath, "\n", Encoding.UTF8), null);
        await ExpectAuthoringFailureAsync(() => racing.ApplyAsync(project, commit.Revision, new AuthoringPatch(SceneGoalPosition: [712, 212]), default), WorkspaceAuthoringFailureKind.RevisionConflict);
        Require(committedScene.AsSpan().SequenceEqual(File.ReadAllBytes(project.ScenePath)), "authoring TOCTOU conflict changed Scene");
        File.WriteAllBytes(project.ScriptPath, racedScript);

        var rollbackScene = File.ReadAllBytes(project.ScenePath);
        var rollbackScript = File.ReadAllBytes(project.ScriptPath);
        var failing = new WorkspaceAuthoringModel(null, index => { if (index == 1) throw new IOException("injected second replace failure"); });
        await ExpectAuthoringFailureAsync(() => failing.ApplyAsync(project, commit.Revision,
            new AuthoringPatch(SceneGoalPosition: [713, 213], ScriptGoalVelocity: [3, -3]), default), WorkspaceAuthoringFailureKind.Commit);
        Require(rollbackScene.AsSpan().SequenceEqual(File.ReadAllBytes(project.ScenePath)) && rollbackScript.AsSpan().SequenceEqual(File.ReadAllBytes(project.ScriptPath)), "authoring rollback did not restore the pair");
        Require(!Directory.EnumerateFiles(project.ProjectDirectory, "*.authoring.*", SearchOption.AllDirectories).Any(), "authoring temporary files remain after rollback");

        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        await ExpectAsync<OperationCanceledException>(() => authoring.ApplyAsync(project, commit.Revision, new AuthoringPatch(SceneGoalPosition: [714, 214]), cancelled.Token));

        File.WriteAllText(project.ScenePath, "{", Encoding.UTF8);
        await ExpectAuthoringFailureAsync(() => authoring.ApplyAsync(project, commit.Revision, new AuthoringPatch(SceneGoalPosition: [715, 215]), default), WorkspaceAuthoringFailureKind.Input);
        File.WriteAllBytes(project.ScenePath, committedScene);

        var missingScript = project.ScriptPath + ".missing";
        File.Move(project.ScriptPath, missingScript);
        await ExpectAuthoringFailureAsync(() => authoring.ApplyAsync(project, commit.Revision, new AuthoringPatch(SceneGoalPosition: [716, 216]), default), WorkspaceAuthoringFailureKind.Input);
        File.Move(missingScript, project.ScriptPath);

        var realScene = project.ScenePath + ".real";
        File.Move(project.ScenePath, realScene);
        File.CreateSymbolicLink(project.ScenePath, realScene);
        await ExpectAuthoringFailureAsync(() => authoring.ApplyAsync(project, commit.Revision, new AuthoringPatch(SceneGoalPosition: [717, 217]), default), WorkspaceAuthoringFailureKind.Input);
        File.Delete(project.ScenePath);
        File.Move(realScene, project.ScenePath);

        var undone = await authoring.UndoAsync(project, commit.Revision, commit.UndoToken!, default);
        Require(undone.State == "succeeded"
            && undone.ProjectSnapshot.Scene.GoalPosition.SequenceEqual(initial.Scene.GoalPosition)
            && undone.ProjectSnapshot.Script.GoalPosition.SequenceEqual(initial.Script.GoalPosition)
            && undone.ProjectSnapshot.Script.GoalVelocity.SequenceEqual(initial.Script.GoalVelocity)
            && originalScene.AsSpan().SequenceEqual(File.ReadAllBytes(project.ScenePath))
            && originalScript.AsSpan().SequenceEqual(File.ReadAllBytes(project.ScriptPath)), "authoring exact undo mismatch");

        var initialObjects = initial.Scene.Objects ?? throw new InvalidOperationException("initial Scene object snapshot missing");
        var objectPatch = new AuthoringPatch(SceneObjects: initialObjects.Select(value => new SceneObjectDefinition(
            value.ObjectId, value.Kind, value.Position, value.Size, value.Color, value.TextureId,
            value.MoveSpeed, value.PatrolMinY, value.PatrolMaxY, value.PatrolSpeed)).Concat([
                new SceneObjectDefinition("decoration-1", "sprite", [100, 420], [80, 80], [0.45, 0.65, 1, 0.8], 2),
                new SceneObjectDefinition("hazard-2", "patrol_hazard", [500, 360], [72, 72], [1, 0.35, 0.2, 1], 3,
                    PatrolMinY: 260, PatrolMaxY: 460, PatrolSpeed: 55)
            ]).ToArray());
        var objectCommit = await authoring.ApplyAsync(project, undone.Revision, objectPatch, default);
        Require(objectCommit.ChangedFields.SequenceEqual(new[] { "scene.objects" })
            && objectCommit.ProjectSnapshot.Scene.SchemaVersion == 4
            && objectCommit.ProjectSnapshot.Scene.Objects?.Count == 5,
            "scene object replacement did not upgrade v3 to v4");
        var objectUndone = await authoring.UndoAsync(project, objectCommit.Revision, objectCommit.UndoToken!, default);
        Require(objectUndone.ProjectSnapshot.Scene.SchemaVersion == 3
            && originalScene.AsSpan().SequenceEqual(File.ReadAllBytes(project.ScenePath)), "scene object undo did not restore exact v3 bytes");

        var texturePatch = new AuthoringPatch(SceneTextures: [
            new SceneTextureAssignment(1, "asset://renderer2d/goal.texture"),
            new SceneTextureAssignment(2, "asset://renderer2d/goal.texture"),
            new SceneTextureAssignment(3, "asset://renderer2d/test.texture")
        ]);
        var textureCommit = await authoring.ApplyAsync(project, objectUndone.Revision, texturePatch, default);
        Require(textureCommit.ChangedFields.SequenceEqual(new[] { "scene.textures" }), "scene texture change did not report the expected field");
        var committedTextures = textureCommit.ProjectSnapshot.Scene.Textures ?? throw new InvalidOperationException("scene texture assignment snapshot missing");
        Require(committedTextures.Count == 3
            && committedTextures[0].Artifact == "assets/renderer2d/goal.texture"
            && committedTextures[2].Artifact == "assets/renderer2d/test.texture",
            "scene texture assignment commit mismatch");
        var textureUndone = await authoring.UndoAsync(project, textureCommit.Revision, textureCommit.UndoToken!, default);
        var undoneTextures = textureUndone.ProjectSnapshot.Scene.Textures ?? throw new InvalidOperationException("scene texture undo snapshot missing");
        Require(undoneTextures.Count == 3
            && undoneTextures[0].Artifact == initial.Scene.Textures![0].Artifact,
            "scene texture assignment undo mismatch");

        var combinedPatch = new AuthoringPatch(
            ScriptGoalPosition: [701, 211],
            ScriptGoalVelocity: [3, -1],
            SceneTextures: texturePatch.SceneTextures,
            SceneObjects: objectPatch.SceneObjects);
        var combinedCommit = await authoring.ApplyAsync(project, textureUndone.Revision, combinedPatch, default);
        Require(combinedCommit.ChangedFields.SequenceEqual(new[]
            {
                "script.goal.position", "script.goal.velocity", "scene.textures", "scene.objects"
            })
            && combinedCommit.ProjectSnapshot.Scene.SchemaVersion == 4
            && combinedCommit.ProjectSnapshot.Scene.Objects?.Count == 5
            && combinedCommit.ProjectSnapshot.Scene.Textures?[0].Artifact == "assets/renderer2d/goal.texture"
            && combinedCommit.ProjectSnapshot.Script.GoalPosition.SequenceEqual(new[] { 701d, 211d })
            && combinedCommit.ProjectSnapshot.Script.GoalVelocity.SequenceEqual(new[] { 3d, -1d }),
            "combined scene objects, textures, and Script transaction mismatch");
        var combinedUndone = await authoring.UndoAsync(project, combinedCommit.Revision, combinedCommit.UndoToken!, default);
        Require(combinedUndone.ProjectSnapshot.Scene.SchemaVersion == 3
            && originalScene.AsSpan().SequenceEqual(File.ReadAllBytes(project.ScenePath))
            && originalScript.AsSpan().SequenceEqual(File.ReadAllBytes(project.ScriptPath)),
            "combined authoring undo did not restore exact source bytes");

        File.WriteAllBytes(project.ScenePath, originalScene);
        File.WriteAllBytes(project.ScriptPath, originalScript);
        Require(originalPreview.AsSpan().SequenceEqual(File.ReadAllBytes(project.PreviewPath)), "authoring modified preview config");
        Require(assetsIdentity == TreeIdentity(assetsRoot), "authoring modified package assets");
        Require(derivedIdentity == TreeIdentity(derived), "authoring modified derived artifacts");
        Require(!Directory.EnumerateFiles(project.ProjectDirectory, "*.authoring.*", SearchOption.AllDirectories).Any(), "authoring temporary files remain");
        Directory.Delete(Path.Combine(project.ProjectDirectory, ".kadath"), true);
    }

    private static ProjectSessionInfo CreateFixture(string root)
    {
        var assets = Path.Combine(root, "bin", "assets");
        var projectDirectory = Path.Combine(root, "bin", "projects", "demo");
        Directory.CreateDirectory(Path.Combine(assets, "renderer2d"));
        Directory.CreateDirectory(Path.Combine(assets, "audio"));
        Directory.CreateDirectory(projectDirectory);
        File.WriteAllBytes(Path.Combine(root, "bin", OperatingSystem.IsWindows() ? "kadath.exe" : "kadath"), [0]);
        File.WriteAllBytes(Path.Combine(assets, "renderer2d", "test.texture"), [1, 2, 3]);
        File.WriteAllBytes(Path.Combine(assets, "renderer2d", "goal.texture"), [4, 5]);
        File.WriteAllBytes(Path.Combine(assets, "audio", "lost.wav"), [6]);
        File.WriteAllBytes(Path.Combine(assets, "audio", "won.wav"), [7]);
        var scenePath = Path.Combine(projectDirectory, "scene.json");
        var scriptPath = Path.Combine(projectDirectory, "script.json");
        var previewPath = Path.Combine(projectDirectory, "preview.json");
        File.WriteAllText(scenePath, """
        {"schemaVersion":3,"textures":[{"textureId":1,"artifact":"assets/renderer2d/test.texture"},{"textureId":2,"artifact":"assets/renderer2d/goal.texture"},{"textureId":3,"artifact":"assets/renderer2d/goal.texture"}],"player":{"position":[312,130],"size":[320,240],"color":[1,1,1,1],"moveSpeed":180,"textureId":1},"goal":{"position":[700,200],"size":[96,96],"color":[1,0.75,0.1,1],"textureId":2},"hazard":{"position":[650,280],"size":[96,96],"color":[0.95,0.2,0.2,1],"patrolMinY":245,"patrolMaxY":330,"patrolSpeed":80,"textureId":3}}
        """, Encoding.UTF8);
        File.WriteAllText(scriptPath, """
        {"schemaVersion":1,"instructions":[{"hook":"on_start","op":"set_goal_position","value":[680,200]},{"hook":"fixed_update","op":"move_goal_velocity","value":[-12,0]}]}
        """, Encoding.UTF8);
        File.WriteAllText(previewPath, """
        {"schemaVersion":1,"runtime":{"executable":"bin/kadath","workingDirectory":"bin","arguments":["--scene","projects/demo/scene.json","--script","projects/demo/script.json"]}}
        """, Encoding.UTF8);
        return new ProjectSessionInfo(root, "demo", projectDirectory, scenePath, scriptPath, previewPath, 1);
    }

    private static async Task VerifyPreviewModelAsync(ProjectSessionInfo project)
    {
        var model = new WorkspacePreviewModel(new WorkspacePublicationModel());
        var direct = await model.PrepareAsync(new PreviewStartParameters(project.PreviewPath, project.PackageRoot), default);
        Require(direct.ExecutablePath == Path.Combine(project.PackageRoot, "bin", OperatingSystem.IsWindows() ? "kadath.exe" : "kadath"), "preview executable mismatch");
        Require(direct.RuntimeArguments[^4..].SequenceEqual(["--preview-status", "jsonl-v1", "--preview-control", "jsonl-v1"]), "preview protocol arguments mismatch");
        Require(direct.SceneInputPath == project.ScenePath && direct.ScriptInputPath == project.ScriptPath && direct.InitialBake is null, "direct preview inputs mismatch");

        var live = await model.PrepareAsync(new PreviewStartParameters(
            project.PreviewPath,
            project.PackageRoot,
            LiveBake: true,
            DerivedDirectory: "bin/projects/demo/.kadath/preview-derived"), default);
        Require(live.InitialBake is { State: "succeeded", Target: "Both" }, "preview initial publication mismatch");
        var derivedDirectory = live.DerivedDirectory ?? throw new InvalidOperationException("preview derived directory missing");
        var manifestPath = live.ManifestPath ?? throw new InvalidOperationException("preview manifest path missing");
        Require(derivedDirectory == Path.Combine(project.PackageRoot, "bin", "projects", "demo", ".kadath", "preview-derived"), "relative preview derived directory mismatch");
        Require(File.Exists(Path.Combine(derivedDirectory, "scene.scene"))
            && File.Exists(Path.Combine(derivedDirectory, "script.script"))
            && File.Exists(manifestPath), "preview derived artifacts missing");
        Require(live.RuntimeArguments.Contains("projects/demo/.kadath/preview-derived/scene.scene", StringComparer.Ordinal)
            && live.RuntimeArguments.Contains("projects/demo/.kadath/preview-derived/script.script", StringComparer.Ordinal), "preview live arguments mismatch");

        await ExpectAsync<WorkspaceProjectValidationException>(() => model.PrepareAsync(new PreviewStartParameters(
            project.PreviewPath,
            project.PackageRoot,
            LiveBake: true,
            DerivedDirectory: "bin/assets"), default));
        await ExpectAsync<WorkspaceProjectValidationException>(() => model.PrepareAsync(new PreviewStartParameters(
            project.PreviewPath,
            project.PackageRoot,
            LiveBake: true,
            DerivedDirectory: ".kadath/derived"), default));

        var original = File.ReadAllText(project.PreviewPath, Encoding.UTF8);
        try
        {
            File.WriteAllText(project.PreviewPath, AddRootProperty(original, "\"unknown\":true"), Encoding.UTF8);
            await ExpectAsync<WorkspaceProjectValidationException>(() => model.PrepareAsync(new PreviewStartParameters(project.PreviewPath, project.PackageRoot), default));
            File.WriteAllText(project.PreviewPath, original.Replace("\"--script\"", "\"--scene\",\"projects/demo/scene.json\",\"--script\"", StringComparison.Ordinal), Encoding.UTF8);
            await ExpectAsync<WorkspaceProjectValidationException>(() => model.PrepareAsync(new PreviewStartParameters(project.PreviewPath, project.PackageRoot), default));
        }
        finally { File.WriteAllText(project.PreviewPath, original, Encoding.UTF8); }
    }

    private static async Task VerifyTextureImportAsync(ProjectSessionInfo project)
    {
        var importer = new WorkspaceTextureImportModel();
        var assetsRoot = Path.Combine(project.PackageRoot, "bin", "assets");
        var before = TreeIdentity(assetsRoot);
        var source = Path.Combine(project.PackageRoot, "external-source.ppm");
        File.WriteAllText(source, """
        P3
        # comment line
        2 1
        255
        255 0 16   0 128 255
        """, Encoding.UTF8);

        var imported = await importer.ImportAsync(project, new TextureImportParameters(null, source, "imported", "debug"), default);
        var importedPath = Path.Combine(project.PackageRoot, "bin", "assets", "renderer2d", "imported.texture");
        Require(imported.State == "succeeded"
            && imported.AssetId == "asset://renderer2d/imported.texture"
            && imported.RelativePath == "assets/renderer2d/imported.texture"
            && imported.SourceFormat == "P3-PPM"
            && imported.ArtifactFormat == "KDAT-TEXTURE-V1"
            && imported.Width == 2
            && imported.Height == 1
            && imported.MipLevelCount == 1
            && imported.ArtifactBytes == 28
            && imported.AssetCatalog.Items.Any(item => item.AssetId == "asset://renderer2d/imported.texture" && item.Category == "Texture"),
            "texture import result mismatch");
        var bytes = File.ReadAllBytes(importedPath);
        Require(Encoding.ASCII.GetString(bytes, 0, 4) == "KDAT"
            && BitConverter.ToUInt32(bytes, 4) == 1
            && bytes.AsSpan(20).SequenceEqual(new byte[] { 255, 0, 16, 255, 0, 128, 255, 255 }),
            "texture import artifact payload mismatch");

        var pngSource = Path.Combine(project.PackageRoot, "external-source.png");
        WritePngRgbaFixture(pngSource, [9, 8, 7, 255]);
        var pngImported = await importer.ImportAsync(project, new TextureImportParameters(null, pngSource, "imported-png", "debug"), default);
        Require(pngImported.SourceFormat == "PNG-RGBA8"
            && pngImported.ArtifactBytes == 24
            && File.ReadAllBytes(Path.Combine(project.PackageRoot, "bin", "assets", "renderer2d", "imported-png.texture")).AsSpan(20).SequenceEqual(new byte[] { 9, 8, 7, 255 }),
            "texture import PNG fixture mismatch");

        await ExpectTextureImportFailureAsync(
            () => importer.ImportAsync(project, new TextureImportParameters(null, source, "imported", "debug"), default),
            WorkspaceTextureImportFailureKind.Conflict);

        var afterConflict = TreeIdentity(assetsRoot);
        await ExpectTextureImportFailureAsync(
            () => importer.ImportAsync(project, new TextureImportParameters(null, source, "../escape", "debug"), default),
            WorkspaceTextureImportFailureKind.InvalidAssetName);
        await ExpectTextureImportFailureAsync(
            () => importer.ImportAsync(project, new TextureImportParameters(null, source + ".missing", "missing-source", "debug"), default),
            WorkspaceTextureImportFailureKind.InvalidSource);
        await ExpectTextureImportFailureAsync(
            () => importer.ImportAsync(project, new TextureImportParameters(null, source, "bad-profile", "shipping"), default),
            WorkspaceTextureImportFailureKind.InvalidProfile);
        Require(afterConflict == TreeIdentity(assetsRoot), "texture import failure modified package assets");

        var foreignPath = Path.Combine(project.PackageRoot, "bin", "assets", "renderer2d", "foreign.texture");
        var racing = new WorkspaceTextureImportModel(phase =>
        {
            if (phase == WorkspaceTextureImportPhase.BeforePromote) File.WriteAllBytes(foreignPath, [9, 9, 9]);
        });
        await ExpectTextureImportFailureAsync(
            () => racing.ImportAsync(project, new TextureImportParameters(null, source, "foreign", "debug"), default),
            WorkspaceTextureImportFailureKind.Conflict);
        Require(File.ReadAllBytes(foreignPath).AsSpan().SequenceEqual(new byte[] { 9, 9, 9 })
            && !Directory.EnumerateFiles(Path.GetDirectoryName(foreignPath)!, ".kadath-texture-import-*.tmp").Any(),
            "texture import ownership race overwrote foreign asset or leaked temp");

        var release = await importer.ImportAsync(project, new TextureImportParameters(null, source, "imported-release", "release"), default);
        Require(release.ArtifactFormat == "KDAT-TEXTURE-V2-MIPMAP"
            && release.MipLevelCount == 2
            && release.ArtifactBytes == 36,
            "texture import release profile mismatch");
    }

    private static void WritePngRgbaFixture(string path, byte[] rgba)
    {
        using var output = new MemoryStream();
        output.Write([137, 80, 78, 71, 13, 10, 26, 10]);
        WritePngChunk(output, "IHDR", BuildIhdr(1, 1));
        using var compressed = new MemoryStream();
        using (var zlib = new ZLibStream(compressed, CompressionLevel.Optimal, leaveOpen: true))
        {
            zlib.WriteByte(0);
            zlib.Write(rgba);
        }
        WritePngChunk(output, "IDAT", compressed.ToArray());
        WritePngChunk(output, "IEND", []);
        File.WriteAllBytes(path, output.ToArray());
    }

    private static byte[] BuildIhdr(int width, int height)
    {
        var data = new byte[13];
        BinaryPrimitives.WriteUInt32BigEndian(data.AsSpan(0, 4), (uint)width);
        BinaryPrimitives.WriteUInt32BigEndian(data.AsSpan(4, 4), (uint)height);
        data[8] = 8;
        data[9] = 6;
        return data;
    }

    private static void WritePngChunk(Stream output, string type, byte[] data)
    {
        Span<byte> length = stackalloc byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(length, (uint)data.Length);
        output.Write(length);
        output.Write(Encoding.ASCII.GetBytes(type));
        output.Write(data);
        output.Write(new byte[4]);
    }

    private static void WriteArtifactsAndManifest(ProjectSessionInfo project)
    {
        var derived = Path.Combine(project.ProjectDirectory, ".kadath", "derived");
        Directory.CreateDirectory(derived);
        var sceneArtifact = WorkspaceSceneCodec.EncodeSource(File.ReadAllBytes(project.ScenePath));
        var scriptArtifact = WorkspaceScriptCodec.EncodeSource(File.ReadAllBytes(project.ScriptPath));
        var sceneArtifactPath = Path.Combine(derived, "scene.scene");
        var scriptArtifactPath = Path.Combine(derived, "script.script");
        File.WriteAllBytes(sceneArtifactPath, sceneArtifact);
        File.WriteAllBytes(scriptArtifactPath, scriptArtifact);
        var manifest = new
        {
            schemaVersion = 1,
            profile = "debug",
            scene = Entry(project, project.ScenePath, sceneArtifactPath),
            script = Entry(project, project.ScriptPath, scriptArtifactPath)
        };
        File.WriteAllText(Path.Combine(derived, ".live-bake.manifest.json"), JsonSerializer.Serialize(manifest, EditorProtocol.JsonOptions), Encoding.UTF8);
    }

    private static object Entry(ProjectSessionInfo project, string source, string artifact) => new
    {
        sourcePath = Path.GetRelativePath(project.PackageRoot, source).Replace('\\', '/'),
        sourceSha256 = Hash(File.ReadAllBytes(source)),
        artifactPath = Path.GetRelativePath(project.PackageRoot, artifact).Replace('\\', '/'),
        artifactSha256 = Hash(File.ReadAllBytes(artifact)),
        artifactBytes = new FileInfo(artifact).Length
    };

    private static string ExpectedAuthoringRevision(string scene, string script)
    {
        var identity = $"kadath-authoring-v1\nscene:{Hash(File.ReadAllBytes(scene))}\nscript:{Hash(File.ReadAllBytes(script))}";
        return Hash(Encoding.UTF8.GetBytes(identity));
    }

    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
    private static string AddRootProperty(string json, string property)
    {
        var end = json.LastIndexOf('}');
        if (end < 0) throw new InvalidOperationException("JSON fixture has no root closing brace.");
        return json.Insert(end, $",{property}");
    }
    private static string TreeIdentity(string root, bool ignoreDerived = false)
    {
        var files = Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories)
            .Where(path => !ignoreDerived || !path.Contains($"{Path.DirectorySeparatorChar}.kadath{Path.DirectorySeparatorChar}", StringComparison.Ordinal))
            .OrderBy(path => path, StringComparer.Ordinal)
            .Select(path => $"{Path.GetRelativePath(root, path).Replace('\\', '/')}:{Hash(File.ReadAllBytes(path))}");
        return string.Join("\n", files);
    }

    private static async Task ExpectAsync<T>(Func<Task> action) where T : Exception
    {
        try { await action(); }
        catch (T) { return; }
        throw new InvalidOperationException($"Expected {typeof(T).Name}.");
    }

    private static async Task ExpectWorkspaceFailureAsync(Func<Task> action, WorkspaceReadFailureKind kind)
    {
        try { await action(); }
        catch (WorkspaceReadException exception) when (exception.Kind == kind) { return; }
        throw new InvalidOperationException($"Expected WorkspaceReadException with kind {kind}.");
    }

    private static async Task ExpectAuthoringFailureAsync(Func<Task> action, WorkspaceAuthoringFailureKind kind)
    {
        try { await action(); }
        catch (WorkspaceAuthoringException exception) when (exception.Kind == kind) { return; }
        throw new InvalidOperationException($"Expected WorkspaceAuthoringException with kind {kind}.");
    }

    private static async Task ExpectTextureImportFailureAsync(Func<Task> action, WorkspaceTextureImportFailureKind kind)
    {
        try { await action(); }
        catch (WorkspaceTextureImportException exception) when (exception.Kind == kind) { return; }
        throw new InvalidOperationException($"Expected WorkspaceTextureImportException with kind {kind}.");
    }

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
