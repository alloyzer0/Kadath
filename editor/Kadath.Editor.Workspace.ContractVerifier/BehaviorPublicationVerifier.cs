using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Kadath.Editor.Protocol;
using Kadath.Editor.Workspace;

namespace Kadath.Editor.Workspace.ContractVerifier;

internal static class BehaviorPublicationVerifier
{
    internal static async Task VerifyAsync()
    {
        if (!OperatingSystem.IsLinux()) return;
        var toolPath = ResolveBehaviorTool();
        var previousToolPath = Environment.GetEnvironmentVariable("KADATH_BEHAVIOR_TOOL");
        var root = Path.Combine(Path.GetTempPath(), $"kadath-behavior-publication-{Guid.NewGuid():N}");
        Environment.SetEnvironmentVariable("KADATH_BEHAVIOR_TOOL", toolPath);
        try
        {
            var project = CreateProject(root);
            var model = new WorkspacePublicationModel();
            var initialSourceRevision = WorkspaceScriptDependencySet.ComputeRevision(project.ScriptPath);
            Require(IsSha256(initialSourceRevision), "Script v2 dependency revision is not SHA-256.");

            var initial = await model.BakeAsync(project, new BakeStartParameters("Both", "debug"), default);
            Require(initial.ScriptRevision == initialSourceRevision, "Publication did not persist the complete Script dependency revision.");
            var artifactPath = Path.Combine(initial.DerivedDirectory, "script.script");
            var artifact = File.ReadAllBytes(artifactPath);
            Require(BinaryPrimitives.ReadUInt32LittleEndian(artifact.AsSpan(4, 4)) == 2, "Publication did not produce KSCP v2.");
            var artifactInfo = WorkspaceScriptCodec.ValidateArtifact(artifact);
            Require(artifactInfo.Format == "KSCP-SCRIPT-V2" && artifactInfo.ImporterVersion == 2 && artifactInfo.BakerVersion == 2,
                "KSCP v2 identity mismatch.");
            using (var manifest = JsonDocument.Parse(File.ReadAllBytes(initial.ManifestPath)))
            {
                var script = manifest.RootElement.GetProperty("script");
                Require(script.GetProperty("sourceSha256").GetString() == initialSourceRevision
                    && script.GetProperty("artifactFormat").GetString() == "KSCP-SCRIPT-V2"
                    && script.GetProperty("importerVersion").GetInt32() == 2
                    && script.GetProperty("bakerVersion").GetInt32() == 2,
                    "Live-bake manifest did not record the KSCP v2 contract.");
            }

            var readModel = new WorkspaceReadModel();
            var current = await readModel.ReadPublicationAsync(project, "debug", default);
            Require(current.State == "current" && current.Script.State == "current", "KSCP v2 publication was not projected as current.");

            var sourcePath = Path.Combine(project.ProjectDirectory, "scripts", "patrol.luau");
            File.WriteAllText(sourcePath, ChangedLuau, new UTF8Encoding(false));
            var changedSourceRevision = WorkspaceScriptDependencySet.ComputeRevision(project.ScriptPath);
            Require(changedSourceRevision != initialSourceRevision, "Changing only a .luau dependency did not change Script source revision.");
            var dirty = await readModel.ReadPublicationAsync(project, "debug", default);
            Require(dirty.State == "source_dirty" && dirty.Script.State == "source_dirty"
                && dirty.Script.SourceRevision == changedSourceRevision,
                "Publication state ignored a changed .luau dependency.");

            var changed = await model.BakeAsync(project, new BakeStartParameters("Script", "debug"), default);
            Require(changed.ScriptRevision == changedSourceRevision && changed.ScriptArtifactRevision != initial.ScriptArtifactRevision,
                "Script-only KSCP v2 publication did not promote the changed dependency set.");
            var retainedArtifact = File.ReadAllBytes(artifactPath);
            var retainedManifest = File.ReadAllBytes(initial.ManifestPath);

            File.WriteAllText(sourcePath, InvalidLuau, new UTF8Encoding(false));
            await ExpectFailureAsync(
                () => model.BakeAsync(project, new BakeStartParameters("Script", "debug"), default),
                WorkspacePublicationFailureKind.Validation);
            Require(File.ReadAllBytes(artifactPath).AsSpan().SequenceEqual(retainedArtifact)
                && File.ReadAllBytes(initial.ManifestPath).AsSpan().SequenceEqual(retainedManifest),
                "Invalid Luau publication replaced the active artifact or manifest.");
            RequireNoTemporaries(initial.DerivedDirectory);

            var corrupted = retainedArtifact.ToArray();
            corrupted[^1] ^= 0x01;
            Expect<InvalidDataException>(() => WorkspaceScriptCodec.ValidateArtifact(corrupted));

            VerifyInvalidManifestRetainsDependencyWatch(project.ScriptPath, sourcePath);
            await VerifyDependencySourceRecheckAsync(root + "-source-recheck");
        }
        finally
        {
            Environment.SetEnvironmentVariable("KADATH_BEHAVIOR_TOOL", previousToolPath);
            foreach (var path in Directory.GetDirectories(Path.GetDirectoryName(root)!, Path.GetFileName(root) + "*"))
            {
                try { Directory.Delete(path, recursive: true); }
                catch { }
            }
        }
    }

    private static void VerifyInvalidManifestRetainsDependencyWatch(string manifestPath, string sourcePath)
    {
        File.WriteAllText(sourcePath, ChangedLuau, new UTF8Encoding(false));
        var tracker = WorkspaceScriptDependencySet.CreateRevisionTracker(manifestPath);
        _ = tracker.ComputeRevision();
        var manifest = File.ReadAllBytes(manifestPath);
        File.WriteAllText(manifestPath, "{", new UTF8Encoding(false));
        var invalidManifestRevision = tracker.ComputeRevision();
        File.AppendAllText(sourcePath, "\n-- retained dependency changed\n", new UTF8Encoding(false));
        var invalidDependencyRevision = tracker.ComputeRevision();
        Require(invalidManifestRevision.StartsWith("invalid:", StringComparison.Ordinal)
            && invalidDependencyRevision.StartsWith("invalid:", StringComparison.Ordinal)
            && invalidDependencyRevision != invalidManifestRevision,
            "Invalid manifest observation discarded the last validated dependency watch set.");
        File.WriteAllBytes(manifestPath, manifest);
    }

    private static async Task VerifyDependencySourceRecheckAsync(string root)
    {
        var project = CreateProject(root);
        var sourcePath = Path.Combine(project.ProjectDirectory, "scripts", "patrol.luau");
        var model = new WorkspacePublicationModel(phase =>
        {
            if (phase == WorkspacePublicationPhase.AfterStaging)
                File.AppendAllText(sourcePath, "\n-- changed during publication\n", new UTF8Encoding(false));
        });
        await ExpectFailureAsync(
            () => model.BakeAsync(project, new BakeStartParameters("Both", "debug"), default),
            WorkspacePublicationFailureKind.SourceChanged);
        var derived = Path.Combine(project.ProjectDirectory, ".kadath", "derived");
        Require(!Directory.EnumerateFiles(derived).Any(path => path.EndsWith(".scene", StringComparison.Ordinal)
            || path.EndsWith(".script", StringComparison.Ordinal)
            || Path.GetFileName(path) == ".live-bake.manifest.json"),
            "Changed Luau source exposed a partially committed publication.");
        RequireNoTemporaries(derived);
    }

    private static ProjectSessionInfo CreateProject(string root)
    {
        var projectDirectory = Path.Combine(root, "bin", "projects", "demo");
        Directory.CreateDirectory(Path.Combine(projectDirectory, "scripts"));
        File.WriteAllText(Path.Combine(projectDirectory, "scene.json"), SceneJson, Encoding.UTF8);
        File.WriteAllText(Path.Combine(projectDirectory, "script.json"), ScriptManifestJson, Encoding.UTF8);
        File.WriteAllText(Path.Combine(projectDirectory, "scripts", "patrol.luau"), InitialLuau, new UTF8Encoding(false));
        File.WriteAllText(Path.Combine(projectDirectory, "preview.json"),
            """{"schemaVersion":1,"runtime":{"executable":"bin/kadath","workingDirectory":"bin","arguments":["--scene","projects/demo/scene.json","--script","projects/demo/script.json"]}}""",
            Encoding.UTF8);
        File.WriteAllBytes(Path.Combine(root, "bin", "kadath"), [0]);
        return new ProjectSessionInfo(root, "demo", projectDirectory,
            Path.Combine(projectDirectory, "scene.json"),
            Path.Combine(projectDirectory, "script.json"),
            Path.Combine(projectDirectory, "preview.json"), 1);
    }

    private static string ResolveBehaviorTool()
    {
        var overridePath = Environment.GetEnvironmentVariable("KADATH_BEHAVIOR_TOOL");
        if (!string.IsNullOrWhiteSpace(overridePath) && File.Exists(overridePath)) return Path.GetFullPath(overridePath);
        var executable = OperatingSystem.IsWindows() ? "kadath-behavior-tool.exe" : "kadath-behavior-tool";
        var candidate = Path.Combine(Directory.GetCurrentDirectory(), "zig-out", "behavior-tools", executable);
        if (File.Exists(candidate)) return candidate;
        throw new InvalidOperationException("Native Behavior Tool is missing; run zig build install-behavior-script-tool --prefix zig-out.");
    }

    private static async Task ExpectFailureAsync(Func<Task> action, WorkspacePublicationFailureKind kind)
    {
        try { await action(); }
        catch (WorkspacePublicationException exception) when (exception.Kind == kind) { return; }
        throw new InvalidOperationException($"Expected WorkspacePublicationException with kind {kind}.");
    }

    private static void RequireNoTemporaries(string derived) =>
        Require(!Directory.EnumerateFileSystemEntries(derived).Any(path => Path.GetFileName(path).Contains(".publication.", StringComparison.Ordinal)),
            "Publication left staging or recovery files.");

    private static void Expect<T>(Action action) where T : Exception
    {
        try { action(); }
        catch (T) { return; }
        throw new InvalidOperationException($"Expected {typeof(T).Name}.");
    }

    private static bool IsSha256(string value) => value.Length == 64 && value.All(Uri.IsHexDigit);
    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private const string ScriptManifestJson = """
    {
      "schemaVersion": 2,
      "scripts": [
        { "scriptId": 1, "source": "scripts/patrol.luau" }
      ]
    }
    """;

    private const string InitialLuau = """
    --!strict

    local speed = kadath.parameter.number("speed", {
        default = 80,
        min = 0,
        max = 1000,
    })

    return {
        fixed_update = function(self: Kadath.Object, dt: number)
            self:translate(speed * dt, 0)
        end,
    }
    """;

    private const string ChangedLuau = """
    --!strict

    local speed = kadath.parameter.number("speed", {
        default = 80,
        min = 0,
        max = 1000,
    })

    return {
        fixed_update = function(self: Kadath.Object, dt: number)
            self:translate(speed * dt * 0.5, 0)
        end,
    }
    """;

    private const string InvalidLuau = """
    --!strict
    return {
        fixed_update = function(
    }
    """;

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
}
