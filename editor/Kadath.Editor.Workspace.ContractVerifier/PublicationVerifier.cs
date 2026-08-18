using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Kadath.Editor.Protocol;
using Kadath.Editor.Workspace;

namespace Kadath.Editor.Workspace.ContractVerifier;

internal static class PublicationVerifier
{
    private const string ExpectedSceneArtifactSha256 = "cf8a7088b33e2cdcddc9881dc7cc3c9874bccb108cf932a146c9f85099b1718f";
    private const string ExpectedScriptArtifactSha256 = "754f688cfd3bc473bf4fcbe8bd330580dae3bd70729de747d863368ad6224887";

    internal static async Task VerifyAsync()
    {
        var root = Path.Combine(Path.GetTempPath(), $"kadath-publication-{Guid.NewGuid():N}");
        try
        {
            var project = CreateProject(root);
            var packageSentinelPath = Path.Combine(root, "bin", "assets", "publication-sentinel.keep");
            var packageSentinelIdentity = HashFile(packageSentinelPath);
            var model = new WorkspacePublicationModel();
            VerifySceneCodecVariants();
            var both = await model.BakeAsync(project, new BakeStartParameters("Both", "debug"), default);
            Require(both.State == "succeeded" && both.Target == "Both" && both.Profile == "debug", "Both publication result mismatch.");
            Require(both.SceneArtifactBytes == 314 && both.ScriptArtifactBytes == 48, "Publication artifact byte count mismatch.");
            Require(both.SceneArtifactRevision == ExpectedSceneArtifactSha256, "Native KSCN output differs from the frozen byte oracle.");
            Require(both.ScriptArtifactRevision == ExpectedScriptArtifactSha256, "Native KSCP output differs from the frozen byte oracle.");
            Require(HashFile(Path.Combine(both.DerivedDirectory, "scene.scene")) == ExpectedSceneArtifactSha256, "Committed KSCN identity mismatch.");
            Require(HashFile(Path.Combine(both.DerivedDirectory, "script.script")) == ExpectedScriptArtifactSha256, "Committed KSCP identity mismatch.");
            Require(HashFile(packageSentinelPath) == packageSentinelIdentity, "Publication changed package assets outside the derived boundary.");
            RequireNoTemporaries(both.DerivedDirectory);

            using (var manifest = JsonDocument.Parse(File.ReadAllBytes(both.ManifestPath)))
            {
                var rootElement = manifest.RootElement;
                Require(rootElement.GetProperty("schemaVersion").GetInt32() == 1 && rootElement.GetProperty("adapterVersion").GetInt32() == 1, "Manifest version mismatch.");
                Require(rootElement.GetProperty("scene").GetProperty("artifactFormat").GetString() == "KSCN-SCENE-V4", "Manifest Scene format mismatch.");
                Require(rootElement.GetProperty("script").GetProperty("artifactFormat").GetString() == "KSCP-SCRIPT-V1", "Manifest Script format mismatch.");
            }

            var snapshot = await new WorkspaceReadModel().ReadPublicationAsync(project, "debug", default);
            Require(snapshot.State == "current" && snapshot.Scene.ArtifactBytes == 314 && snapshot.Script.ArtifactBytes == 48, "Native publication snapshot mismatch.");

            var scriptArtifactPath = Path.Combine(both.DerivedDirectory, "script.script");
            var retainedScript = File.ReadAllBytes(scriptArtifactPath);
            File.WriteAllText(project.ScenePath, SceneJson.Replace("700.0", "710.0", StringComparison.Ordinal), Encoding.UTF8);
            File.WriteAllText(project.ScriptPath, ScriptJson.Replace("-12.0", "-14.0", StringComparison.Ordinal), Encoding.UTF8);
            var sceneOnly = await model.BakeAsync(project, new BakeStartParameters("scene", "release"), default);
            Require(sceneOnly.Target == "Scene" && sceneOnly.Profile == "release", "Scene-only normalization mismatch.");
            Require(File.ReadAllBytes(scriptArtifactPath).AsSpan().SequenceEqual(retainedScript), "Scene-only publication changed the retained Script artifact.");
            Require(sceneOnly.ScriptRevision == both.ScriptRevision, "Scene-only publication rewrote the retained Script source identity.");
            var retainedDirty = await new WorkspaceReadModel().ReadPublicationAsync(project, "release", default);
            Require(retainedDirty.State == "source_dirty" && retainedDirty.Script.State == "source_dirty", "Scene-only publication did not preserve a dirty retained Script side.");
            RequireNoTemporaries(sceneOnly.DerivedDirectory);

            var scriptOnly = await model.BakeAsync(project, new BakeStartParameters("SCRIPT", "DEBUG"), default);
            Require(scriptOnly.Target == "Script" && scriptOnly.Profile == "debug", "Script-only normalization mismatch.");

            await ExpectFailureAsync(() => model.BakeAsync(project, new BakeStartParameters("Texture", "debug"), default), WorkspacePublicationFailureKind.InvalidTarget);
            await ExpectFailureAsync(() => model.BakeAsync(project, new BakeStartParameters("Both", "shipping"), default), WorkspacePublicationFailureKind.InvalidProfile);
            await ExpectFailureAsync(() => model.BakeAsync(project, new BakeStartParameters(null!, "debug"), default), WorkspacePublicationFailureKind.InvalidTarget);
            await ExpectFailureAsync(() => model.BakeAsync(project, new BakeStartParameters("Both", null!), default), WorkspacePublicationFailureKind.InvalidProfile);

            var initialOnlyRoot = root + "-initial-only";
            var initialOnly = CreateProject(initialOnlyRoot);
            await ExpectFailureAsync(() => model.BakeAsync(initialOnly, new BakeStartParameters("Scene", "debug"), default), WorkspacePublicationFailureKind.Validation);
            RequireNoPublishedFiles(initialOnly);

            var changedRoot = root + "-changed";
            var changedProject = CreateProject(changedRoot);
            var changedModel = new WorkspacePublicationModel(phase =>
            {
                if (phase == WorkspacePublicationPhase.AfterStaging) File.AppendAllText(changedProject.ScenePath, "\n", Encoding.UTF8);
            });
            await ExpectFailureAsync(() => changedModel.BakeAsync(changedProject, new BakeStartParameters("Both", "debug"), default), WorkspacePublicationFailureKind.SourceChanged);
            RequireNoPublishedFiles(changedProject);

            await VerifyRollbackAtEachPromoteAsync(root, model);
            await VerifyForeignReplacementAsync(root, model);
            await VerifyForeignReplacementAfterCommitAsync(root, model);
            await VerifyRollbackInvariantAsync(root, model);

            var cancelRoot = root + "-cancel";
            var cancelProject = CreateProject(cancelRoot);
            using var stop = new CancellationTokenSource();
            var cancelModel = new WorkspacePublicationModel(phase =>
            {
                if (phase == WorkspacePublicationPhase.AfterStaging) stop.Cancel();
            });
            await ExpectAsync<OperationCanceledException>(() => cancelModel.BakeAsync(cancelProject, new BakeStartParameters("Both", "debug"), stop.Token));
            RequireNoPublishedFiles(cancelProject);

            var commitCancelRoot = root + "-commit-cancel";
            var commitCancelProject = CreateProject(commitCancelRoot);
            using var commitStop = new CancellationTokenSource();
            var commitCancelModel = new WorkspacePublicationModel(phase =>
            {
                if (phase == WorkspacePublicationPhase.BeforeScriptPromote) commitStop.Cancel();
            });
            var commitCancelResult = await commitCancelModel.BakeAsync(commitCancelProject, new BakeStartParameters("Both", "debug"), commitStop.Token);
            Require(commitCancelResult.State == "succeeded", "Cancellation interrupted an in-progress publication commit.");
            RequireNoTemporaries(commitCancelResult.DerivedDirectory);

            var reparseRoot = root + "-reparse";
            var reparseProject = CreateProject(reparseRoot);
            var externalDirectory = root + "-reparse-external";
            Directory.CreateDirectory(externalDirectory);
            await VerifierReparseFixture.WithDirectoryAliasAsync(
                Path.Combine(reparseProject.ProjectDirectory, ".kadath"),
                externalDirectory,
                () => ExpectFailureAsync(
                    () => model.BakeAsync(reparseProject, new BakeStartParameters("Both", "debug"), default),
                    WorkspacePublicationFailureKind.Validation));
            Require(!Directory.EnumerateFileSystemEntries(externalDirectory).Any(), "Publication followed a derived-directory reparse point.");

            if (!OperatingSystem.IsWindows())
            {
                var caseRoot = root + "-case";
                var caseProject = CreateProject(caseRoot);
                var mismatchedProject = caseProject with { ProjectDirectory = Path.Combine(caseRoot, "bin", "projects", "DEMO") };
                await ExpectFailureAsync(() => model.BakeAsync(mismatchedProject, new BakeStartParameters("Both", "debug"), default), WorkspacePublicationFailureKind.Validation);
                RequireNoPublishedFiles(caseProject);
            }

            var overflowRoot = root + "-overflow";
            var overflowProject = CreateProject(overflowRoot);
            File.WriteAllText(overflowProject.ScenePath, SceneJson.Replace("180.0", "1e100", StringComparison.Ordinal), Encoding.UTF8);
            await ExpectFailureAsync(() => model.BakeAsync(overflowProject, new BakeStartParameters("Both", "debug"), default), WorkspacePublicationFailureKind.Validation);
        }
        finally
        {
            foreach (var path in Directory.GetDirectories(Path.GetDirectoryName(root)!, Path.GetFileName(root) + "*"))
            {
                try { Directory.Delete(path, recursive: true); }
                catch { }
            }
        }
    }

    private static void VerifySceneCodecVariants()
    {
        var defaultV4Artifact = WorkspaceSceneCodec.EncodeSource(Encoding.UTF8.GetBytes(DefaultV4SceneJson));
        Require(defaultV4Artifact.Length == 444
            && Convert.ToHexString(SHA256.HashData(defaultV4Artifact)).ToLowerInvariant() == "988183e0a3b3d7f06f1f0fef3ab67634cdcc185aee7cd0cf92a4978a114058af",
            "Native Scene v4 output differs from the shared frozen byte oracle.");
        var invalidTextureLength = defaultV4Artifact.ToArray();
        BinaryPrimitives.WriteUInt32LittleEndian(invalidTextureLength.AsSpan(24, 4), uint.MaxValue);
        Expect<InvalidDataException>(() => WorkspaceSceneCodec.ValidateArtifact(invalidTextureLength));
        var invalidEntryLength = defaultV4Artifact.ToArray();
        BinaryPrimitives.WriteUInt32LittleEndian(invalidEntryLength.AsSpan(FirstObjectEntryLengthOffset(invalidEntryLength), 4), uint.MaxValue);
        Expect<InvalidDataException>(() => WorkspaceSceneCodec.ValidateArtifact(invalidEntryLength));

        var lengths = new List<int>();
        for (var textureCount = 1; textureCount <= 4; textureCount++)
        {
            var source = BuildSceneSource(textureCount);
            var artifact = WorkspaceSceneCodec.EncodeSource(source);
            _ = WorkspaceSceneCodec.ValidateArtifact(artifact);
            lengths.Add(artifact.Length);
        }
        Require(lengths.Distinct().Count() == 4, "KSCN texture set did not produce variable artifact lengths.");

        var longPath = "assets/renderer2d/" + new string('a', 229) + ".texture";
        Require(Encoding.UTF8.GetByteCount(longPath) == 255, "KSCN path-length fixture is not 255 UTF-8 bytes.");
        var longArtifact = WorkspaceSceneCodec.EncodeSource(BuildSceneSource(1, longPath));
        _ = WorkspaceSceneCodec.ValidateArtifact(longArtifact);
        var pathOffset = FindSequence(longArtifact, Encoding.UTF8.GetBytes(longPath));
        Require(pathOffset >= 0, "KSCN path fixture was not encoded.");
        longArtifact[pathOffset + "assets/renderer2d/".Length] = 0xff;
        Expect<InvalidDataException>(() => WorkspaceSceneCodec.ValidateArtifact(longArtifact));
    }

    private static int FirstObjectEntryLengthOffset(byte[] artifact)
    {
        var offset = 16;
        var textureCount = BinaryPrimitives.ReadUInt32LittleEndian(artifact.AsSpan(offset, 4));
        offset += 4;
        for (var index = 0; index < textureCount; index++)
        {
            var pathBytes = BinaryPrimitives.ReadUInt32LittleEndian(artifact.AsSpan(offset + 4, 4));
            offset += 8 + checked((int)pathBytes);
        }
        offset += 4;
        return offset;
    }

    private static byte[] BuildSceneSource(int textureCount, string? firstArtifact = null)
    {
        var root = JsonNode.Parse(SceneJson)!.AsObject();
        var textures = new JsonArray();
        for (var textureId = 1; textureId <= textureCount; textureId++)
        {
            textures.Add(new JsonObject
            {
                ["textureId"] = textureId,
                ["artifact"] = textureId == 1 && firstArtifact is not null ? firstArtifact : $"assets/renderer2d/texture-{textureId}.texture"
            });
        }
        root["textures"] = textures;
        root["player"]!["textureId"] = 1;
        root["goal"]!["textureId"] = Math.Min(2, textureCount);
        root["hazard"]!["textureId"] = Math.Min(3, textureCount);
        return Encoding.UTF8.GetBytes(root.ToJsonString());
    }

    private static async Task VerifyRollbackAtEachPromoteAsync(string root, WorkspacePublicationModel model)
    {
        foreach (var failurePhase in new[]
                 {
                     WorkspacePublicationPhase.BeforeScenePromote,
                     WorkspacePublicationPhase.BeforeScriptPromote,
                     WorkspacePublicationPhase.BeforeManifestPromote
                 })
        {
            var rollbackProject = CreateProject($"{root}-rollback-{failurePhase}");
            var baseline = await model.BakeAsync(rollbackProject, new BakeStartParameters("Both", "debug"), default);
            var baselineIdentity = TreeIdentity(baseline.DerivedDirectory);
            File.WriteAllText(rollbackProject.ScenePath, SceneJson.Replace("700.0", "720.0", StringComparison.Ordinal), Encoding.UTF8);
            File.WriteAllText(rollbackProject.ScriptPath, ScriptJson.Replace("-12.0", "-16.0", StringComparison.Ordinal), Encoding.UTF8);
            var rollbackModel = new WorkspacePublicationModel(phase =>
            {
                if (phase == failurePhase) throw new IOException($"injected {failurePhase} failure");
            });
            await ExpectFailureAsync(() => rollbackModel.BakeAsync(rollbackProject, new BakeStartParameters("Both", "debug"), default), WorkspacePublicationFailureKind.Promote);
            Require(TreeIdentity(baseline.DerivedDirectory) == baselineIdentity, $"{failurePhase} did not restore the previous publication pair.");
            RequireNoTemporaries(baseline.DerivedDirectory);
        }
    }

    private static async Task VerifyForeignReplacementAsync(string root, WorkspacePublicationModel model)
    {
        var foreignProject = CreateProject(root + "-foreign");
        var baseline = await model.BakeAsync(foreignProject, new BakeStartParameters("Both", "debug"), default);
        var sceneArtifactPath = Path.Combine(baseline.DerivedDirectory, "scene.scene");
        var foreignBytes = Encoding.UTF8.GetBytes("foreign-publication-owner");
        File.WriteAllText(foreignProject.ScenePath, SceneJson.Replace("700.0", "730.0", StringComparison.Ordinal), Encoding.UTF8);
        var foreignModel = new WorkspacePublicationModel(phase =>
        {
            if (phase == WorkspacePublicationPhase.BeforeScenePromote) File.WriteAllBytes(sceneArtifactPath, foreignBytes);
        });
        await ExpectFailureAsync(() => foreignModel.BakeAsync(foreignProject, new BakeStartParameters("Both", "debug"), default), WorkspacePublicationFailureKind.Promote);
        Require(File.ReadAllBytes(sceneArtifactPath).AsSpan().SequenceEqual(foreignBytes), "Publication overwrote a target replaced by another owner.");
        RequireNoTemporaries(baseline.DerivedDirectory);
    }

    private static async Task VerifyForeignReplacementAfterCommitAsync(string root, WorkspacePublicationModel model)
    {
        var foreignProject = CreateProject(root + "-foreign-after-commit");
        var baseline = await model.BakeAsync(foreignProject, new BakeStartParameters("Both", "debug"), default);
        var sceneArtifactPath = Path.Combine(baseline.DerivedDirectory, "scene.scene");
        var foreignBytes = Encoding.UTF8.GetBytes("foreign-owner-after-publication-commit");
        File.WriteAllText(foreignProject.ScenePath, SceneJson.Replace("700.0", "735.0", StringComparison.Ordinal), Encoding.UTF8);
        File.WriteAllText(foreignProject.ScriptPath, ScriptJson.Replace("-12.0", "-17.0", StringComparison.Ordinal), Encoding.UTF8);
        var foreignModel = new WorkspacePublicationModel(phase =>
        {
            if (phase != WorkspacePublicationPhase.BeforeScriptPromote) return;
            File.WriteAllBytes(sceneArtifactPath, foreignBytes);
            throw new IOException("injected failure after foreign replacement");
        });
        await ExpectFailureAsync(() => foreignModel.BakeAsync(foreignProject, new BakeStartParameters("Both", "debug"), default), WorkspacePublicationFailureKind.Invariant);
        Require(File.ReadAllBytes(sceneArtifactPath).AsSpan().SequenceEqual(foreignBytes), "Rollback overwrote a committed target replaced by another owner.");
    }

    private static async Task VerifyRollbackInvariantAsync(string root, WorkspacePublicationModel model)
    {
        var invariantProject = CreateProject(root + "-invariant");
        var baseline = await model.BakeAsync(invariantProject, new BakeStartParameters("Both", "debug"), default);
        File.WriteAllText(invariantProject.ScenePath, SceneJson.Replace("700.0", "740.0", StringComparison.Ordinal), Encoding.UTF8);
        File.WriteAllText(invariantProject.ScriptPath, ScriptJson.Replace("-12.0", "-18.0", StringComparison.Ordinal), Encoding.UTF8);
        var invariantModel = new WorkspacePublicationModel(phase =>
        {
            if (phase == WorkspacePublicationPhase.BeforeScriptPromote) throw new IOException("injected commit failure");
            if (phase != WorkspacePublicationPhase.BeforeRollback) return;
            var recoveryPath = Directory.EnumerateFiles(baseline.DerivedDirectory, "scene.scene.publication.*.recovery").Single();
            File.Delete(recoveryPath);
            Directory.CreateDirectory(recoveryPath);
        });
        var failure = await ExpectFailureAsync(
            () => invariantModel.BakeAsync(invariantProject, new BakeStartParameters("Both", "debug"), default),
            WorkspacePublicationFailureKind.Invariant);
        Require(failure.Message.Contains("commit failed", StringComparison.OrdinalIgnoreCase)
            && failure.Message.Contains("rollback failed", StringComparison.OrdinalIgnoreCase), "Invariant failure omitted commit or rollback diagnostics.");
    }

    private static ProjectSessionInfo CreateProject(string root)
    {
        var projectDirectory = Path.Combine(root, "bin", "projects", "demo");
        Directory.CreateDirectory(projectDirectory);
        File.WriteAllText(Path.Combine(projectDirectory, "scene.json"), SceneJson, Encoding.UTF8);
        File.WriteAllText(Path.Combine(projectDirectory, "script.json"), ScriptJson, Encoding.UTF8);
        File.WriteAllText(Path.Combine(projectDirectory, "preview.json"), $$$"""
        {"schemaVersion":1,"runtime":{"executable":"{{{VerifierPlatform.RuntimeRelativePath}}}","workingDirectory":"bin","arguments":["--scene","projects/demo/scene.json","--script","projects/demo/script.json"]}}
        """, Encoding.UTF8);
        File.WriteAllBytes(Path.Combine(root, VerifierPlatform.RuntimeRelativePath), [0]);
        Directory.CreateDirectory(Path.Combine(root, "bin", "assets"));
        File.WriteAllText(Path.Combine(root, "bin", "assets", "publication-sentinel.keep"), "package-content", Encoding.UTF8);
        return new ProjectSessionInfo(root, "demo", projectDirectory,
            Path.Combine(projectDirectory, "scene.json"),
            Path.Combine(projectDirectory, "script.json"),
            Path.Combine(projectDirectory, "preview.json"), 1);
    }

    private static void RequireNoPublishedFiles(ProjectSessionInfo project)
    {
        var derived = Path.Combine(project.ProjectDirectory, ".kadath", "derived");
        if (!Directory.Exists(derived)) return;
        Require(!Directory.EnumerateFiles(derived).Any(path => path.EndsWith(".scene", StringComparison.Ordinal)
            || path.EndsWith(".script", StringComparison.Ordinal) || Path.GetFileName(path) == ".live-bake.manifest.json"), "Failed publication exposed committed files.");
        RequireNoTemporaries(derived);
    }

    private static void RequireNoTemporaries(string derived) =>
        Require(!Directory.EnumerateFileSystemEntries(derived).Any(path => Path.GetFileName(path).Contains(".publication.", StringComparison.Ordinal)), "Publication left staging or recovery files.");

    private static async Task<WorkspacePublicationException> ExpectFailureAsync(Func<Task> action, WorkspacePublicationFailureKind kind)
    {
        try { await action(); }
        catch (WorkspacePublicationException exception) when (exception.Kind == kind) { return exception; }
        throw new InvalidOperationException($"Expected WorkspacePublicationException with kind {kind}.");
    }

    private static async Task ExpectAsync<T>(Func<Task> action) where T : Exception
    {
        try { await action(); }
        catch (T) { return; }
        throw new InvalidOperationException($"Expected {typeof(T).Name}.");
    }

    private static string HashFile(string path) => Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path))).ToLowerInvariant();
    private static int FindSequence(byte[] source, byte[] sequence) => source.AsSpan().IndexOf(sequence);
    private static string TreeIdentity(string root) => string.Join("\n", Directory.EnumerateFiles(root).OrderBy(value => value, StringComparer.Ordinal)
        .Select(path => $"{Path.GetFileName(path)}:{HashFile(path)}"));

    private static void Expect<T>(Action action) where T : Exception
    {
        try { action(); }
        catch (T) { return; }
        throw new InvalidOperationException($"Expected {typeof(T).Name}.");
    }

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private const string SceneJson = """
    {
      "schemaVersion": 3,
      "textures": [
        { "textureId": 1, "artifact": "assets/renderer2d/test.texture" },
        { "textureId": 2, "artifact": "assets/renderer2d/goal.texture" },
        { "textureId": 3, "artifact": "assets/renderer2d/goal.texture" }
      ],
      "player": { "position": [312.0, 130.0], "size": [320.0, 240.0], "color": [1.0, 1.0, 1.0, 1.0], "moveSpeed": 180.0, "textureId": 1 },
      "goal": { "position": [700.0, 200.0], "size": [96.0, 96.0], "color": [1.0, 0.75, 0.1, 1.0], "textureId": 2 },
      "hazard": { "position": [650.0, 280.0], "size": [96.0, 96.0], "color": [0.95, 0.2, 0.2, 1.0], "patrolMinY": 245.0, "patrolMaxY": 330.0, "patrolSpeed": 80.0, "textureId": 3 }
    }
    """;

    private const string ScriptJson = """
    {
      "schemaVersion": 1,
      "instructions": [
        { "hook": "on_start", "op": "set_goal_position", "value": [680.0, 200.0] },
        { "hook": "fixed_update", "op": "move_goal_velocity", "value": [-12.0, 0.0] }
      ]
    }
    """;

    private const string DefaultV4SceneJson = """
    {
      "schemaVersion": 4,
      "textures": [
        { "textureId": 1, "artifact": "assets/renderer2d/test.texture" },
        { "textureId": 2, "artifact": "assets/renderer2d/goal.texture" },
        { "textureId": 3, "artifact": "assets/renderer2d/goal.texture" }
      ],
      "objects": [
        { "objectId": "decoration-1", "kind": "sprite", "transform": { "position": [100, 420] }, "sprite": { "size": [80, 80], "color": [0.45, 0.65, 1, 0.8], "textureId": 2 } },
        { "objectId": "goal", "kind": "goal", "transform": { "position": [700, 200] }, "sprite": { "size": [96, 96], "color": [1, 0.75, 0.1, 1], "textureId": 2 } },
        { "objectId": "hazard-1", "kind": "patrol_hazard", "transform": { "position": [650, 280] }, "sprite": { "size": [96, 96], "color": [0.95, 0.2, 0.2, 1], "textureId": 3 }, "patrol": { "minY": 245, "maxY": 330, "speed": 80 } },
        { "objectId": "hazard-2", "kind": "patrol_hazard", "transform": { "position": [500, 420] }, "sprite": { "size": [72, 72], "color": [1, 0.35, 0.2, 1], "textureId": 3 }, "patrol": { "minY": 380, "maxY": 460, "speed": 55 } },
        { "objectId": "player", "kind": "player", "transform": { "position": [312, 130] }, "sprite": { "size": [320, 240], "color": [1, 1, 1, 1], "textureId": 1 }, "player": { "moveSpeed": 180 } }
      ]
    }
    """;
}
