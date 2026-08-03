using System.Security.Cryptography;
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
            Require(model.ModelVersion == 1 && model.Scene.SchemaVersion == 3 && model.Scene.Textures?.Count == 3, "project snapshot mismatch");
            Require(model.Scene.PlayerTextureId == 1 && model.Scene.GoalTextureId == 2 && model.Scene.HazardTextureId == 3, "texture bindings mismatch");
            Require(model.AuthoringRevision == ExpectedAuthoringRevision(project.ScenePath, project.ScriptPath), "authoring revision mismatch");

            var hierarchy = await readModel.ReadHierarchyAsync(project, default);
            Require(hierarchy.Nodes.Length == 11 && hierarchy.Nodes[0].Id == "scene" && hierarchy.Nodes[1].Id == "scene.textures[1]", "hierarchy ordering mismatch");
            Require(hierarchy.Nodes.Count(node => node.ParentId is null) == 3, "hierarchy roots mismatch");

            var assets = await readModel.ReadAssetsAsync(project, default);
            Require(assets.Root == "bin/assets" && assets.ItemCount == 4, "asset catalog mismatch");
            Require(assets.Items.Select(item => item.RelativePath).SequenceEqual(assets.Items.Select(item => item.RelativePath).OrderBy(value => value, StringComparer.OrdinalIgnoreCase).ThenBy(value => value, StringComparer.Ordinal)), "asset ordering mismatch");
            Require(assets.Items.Any(item => item.AssetId == "asset://renderer2d/test.png" && item.Category == "Texture"), "texture catalog item missing");

            var missing = await readModel.ReadPublicationAsync(project, "debug", default);
            Require(missing.State == "missing" && !missing.ManifestPresent && missing.Scene.State == "missing" && missing.Script.State == "missing", "publication missing mismatch");

            WriteArtifactsAndManifest(project);
            var current = await readModel.ReadPublicationAsync(project, "debug", default);
            Require(current.State == "current" && current.ManifestPresent && current.Scene.ArtifactBytes == 144 && current.Script.ArtifactBytes == 48, "publication current mismatch");

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

            var invalidManifestType = Encoding.UTF8.GetString(originalManifest).Replace("\"artifactBytes\":144", "\"artifactBytes\":\"144\"", StringComparison.Ordinal);
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
            Console.WriteLine("project_snapshot=ok");
            Console.WriteLine("hierarchy_snapshot=ok");
            Console.WriteLine("asset_catalog_snapshot=ok");
            Console.WriteLine("publication_state_machine=ok");
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

    private static ProjectSessionInfo CreateFixture(string root)
    {
        var assets = Path.Combine(root, "bin", "assets");
        var projectDirectory = Path.Combine(root, "bin", "projects", "demo");
        Directory.CreateDirectory(Path.Combine(assets, "renderer2d"));
        Directory.CreateDirectory(Path.Combine(assets, "audio"));
        Directory.CreateDirectory(projectDirectory);
        File.WriteAllBytes(Path.Combine(assets, "renderer2d", "test.png"), [1, 2, 3]);
        File.WriteAllBytes(Path.Combine(assets, "renderer2d", "goal.png"), [4, 5]);
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
        {"schemaVersion":1,"runtime":{"executable":"bin/kadath","workingDirectory":"bin","arguments":["--scene","assets/scenes/preview.scene","--script","assets/scripts/preview.script"]}}
        """, Encoding.UTF8);
        return new ProjectSessionInfo(root, "demo", projectDirectory, scenePath, scriptPath, previewPath, 1);
    }

    private static void WriteArtifactsAndManifest(ProjectSessionInfo project)
    {
        var derived = Path.Combine(project.ProjectDirectory, ".kadath", "derived");
        Directory.CreateDirectory(derived);
        var sceneArtifact = new byte[144];
        Encoding.ASCII.GetBytes("KSCN").CopyTo(sceneArtifact, 0);
        BitConverter.GetBytes(3u).CopyTo(sceneArtifact, 4);
        BitConverter.GetBytes(3u).CopyTo(sceneArtifact, 8);
        BitConverter.GetBytes(128u).CopyTo(sceneArtifact, 12);
        var scriptArtifact = new byte[48];
        Encoding.ASCII.GetBytes("KSCP").CopyTo(scriptArtifact, 0);
        BitConverter.GetBytes(1u).CopyTo(scriptArtifact, 4);
        BitConverter.GetBytes(1u).CopyTo(scriptArtifact, 8);
        BitConverter.GetBytes(2u).CopyTo(scriptArtifact, 12);
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

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
