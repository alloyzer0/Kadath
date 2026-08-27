using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Kadath.Editor.Protocol;

namespace Kadath.Editor.Workspace;

public enum WorkspaceReadFailureKind { Input, Invariant }

public sealed class WorkspaceReadException : Exception
{
    public WorkspaceReadException(WorkspaceReadFailureKind kind, string message, Exception? innerException = null)
        : base(message, innerException) => Kind = kind;

    public WorkspaceReadFailureKind Kind { get; }
}

internal sealed record WorkspaceProjectBytes(
    string PackageRoot,
    string ProjectDirectory,
    string ScenePath,
    string ScriptPath,
    string PreviewPath,
    byte[] Scene,
    byte[] Script,
    byte[] Preview);

internal sealed record WorkspaceProjectProjection(ProjectModelSnapshot Project, HierarchySnapshot Hierarchy);

public sealed class WorkspaceReadModel
{
    private static readonly StringComparison PathComparison = OperatingSystem.IsWindows()
        ? StringComparison.OrdinalIgnoreCase
        : StringComparison.Ordinal;
    private const int MaxAssetItems = 4096;
    private const int MaxHierarchyNodes = 4096;
    private static readonly Regex ProjectNamePattern = new("^[A-Za-z0-9][A-Za-z0-9_-]{0,47}$", RegexOptions.CultureInvariant);

    public Task<ProjectModelSnapshot> ReadProjectAsync(ProjectSessionInfo project, CancellationToken cancellationToken) =>
        Task.FromResult(Execute(() => ReadProjectCore(project, cancellationToken), cancellationToken));

    public Task<HierarchySnapshot> ReadHierarchyAsync(ProjectSessionInfo project, CancellationToken cancellationToken) =>
        Task.FromResult(Execute(() => ReadHierarchyCore(project, cancellationToken), cancellationToken));

    public Task<AssetCatalogSnapshot> ReadAssetsAsync(ProjectSessionInfo project, CancellationToken cancellationToken) =>
        Task.FromResult(Execute(() => ReadAssetsCore(project, cancellationToken), cancellationToken));

    public Task<PublicationSnapshot> ReadPublicationAsync(ProjectSessionInfo project, string profile, CancellationToken cancellationToken) =>
        Task.FromResult(Execute(() => ReadPublicationCore(project, profile, cancellationToken), cancellationToken));

    private static T Execute<T>(Func<T> operation, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        try { return operation(); }
        catch (OperationCanceledException) { throw; }
        catch (WorkspaceReadException) { throw; }
        catch (WorkspaceProjectValidationException exception)
        {
            throw new WorkspaceReadException(WorkspaceReadFailureKind.Input, exception.Message, exception);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException or FormatException or OverflowException)
        {
            throw new WorkspaceReadException(WorkspaceReadFailureKind.Input, exception.Message, exception);
        }
    }

    private static ProjectModelSnapshot ReadProjectCore(ProjectSessionInfo project, CancellationToken cancellationToken)
    {
        var bytes = ReadProjectBytes(project, cancellationToken);
        return ProjectSnapshotFromBytes(project, bytes);
    }

    private static HierarchySnapshot ReadHierarchyCore(ProjectSessionInfo project, CancellationToken cancellationToken)
    {
        var bytes = ReadProjectBytes(project, cancellationToken);
        return ProjectSnapshotsFromBytes(project, bytes).Hierarchy;
    }

    private static HierarchySnapshot BuildHierarchySnapshot(ProjectSessionInfo project, LoadedProject loaded, ProjectModelSnapshot model)
    {
        var nodes = new List<HierarchyNode>();
        var scene = WorkspaceSceneDocumentCodec.Parse(loaded.SceneBytes);
        var script = loaded.Script.RootElement;
        var scriptSource = WorkspaceScriptSourceModel.Read(loaded.Bytes.ScriptPath, default);
        var preview = loaded.Preview.RootElement;

        nodes.Add(Node("scene", null, "Scene", "SceneDocument", Properties(
            ("SchemaVersion", model.Scene.SchemaVersion), ("TextureCount", scene.Textures.Length), ("ObjectCount", scene.Objects.Length), ("File", model.Files.Scene))));
        foreach (var texture in scene.Textures)
        {
            nodes.Add(Node($"scene.textures[{texture.TextureId}]", "scene", $"Texture {texture.TextureId}", "TextureReference", Properties(
                ("TextureId", texture.TextureId), ("Artifact", texture.Artifact))));
        }
        foreach (var sceneObject in scene.Objects)
        {
            var properties = new List<(string Name, object? Value)>
            {
                ("objectKind", sceneObject.Kind),
                ("position", FormatVector(sceneObject.Position)),
                ("size", FormatVector(sceneObject.Size)),
                ("color", FormatVector(sceneObject.Color)),
                ("textureId", sceneObject.TextureId)
            };
            if (sceneObject.MoveSpeed is not null) properties.Add(("moveSpeed", FormatNumber(sceneObject.MoveSpeed.Value)));
            if (sceneObject.PatrolMinY is not null)
            {
                properties.Add(("patrolMinY", FormatNumber(sceneObject.PatrolMinY.Value)));
                properties.Add(("patrolMaxY", FormatNumber(sceneObject.PatrolMaxY!.Value)));
                properties.Add(("patrolSpeed", FormatNumber(sceneObject.PatrolSpeed!.Value)));
            }
            var objectNodeId = $"scene.objects[{sceneObject.ObjectId}]";
            nodes.Add(Node(objectNodeId, "scene", sceneObject.ObjectId, "SceneObject", Properties(properties.ToArray())));
            if (sceneObject.Behaviors is not null)
            {
                foreach (var behavior in sceneObject.Behaviors)
                {
                    var behaviorNodeId = $"{objectNodeId}.behaviors[{behavior.ScriptId}]";
                    nodes.Add(Node(behaviorNodeId, objectNodeId, $"Behavior {behavior.ScriptId}", "SceneBehavior", Properties(
                        ("ScriptId", behavior.ScriptId), ("ParameterCount", behavior.Parameters.Length))));
                    for (var parameterIndex = 0; parameterIndex < behavior.Parameters.Length; parameterIndex++)
                    {
                        var parameter = behavior.Parameters[parameterIndex];
                        nodes.Add(Node($"{behaviorNodeId}.parameters[{parameterIndex}]", behaviorNodeId, parameter.Name, "BehaviorParameter", Properties(
                            ("Name", parameter.Name), ("Value", FormatNumber(parameter.Value)))));
                    }
                }
            }
        }

        if (scriptSource.IsBehaviorPackage)
        {
            nodes.Add(Node("script", null, "Script", "ScriptDocument", Properties(
                ("SchemaVersion", model.Script.SchemaVersion), ("DependencyCount", scriptSource.Dependencies.Count), ("File", model.Files.Script))));
            foreach (var dependency in scriptSource.Dependencies)
            {
                nodes.Add(Node($"script.dependencies[{dependency.ScriptId}]", "script", dependency.SourceName, "ScriptDependency", Properties(
                    ("ScriptId", dependency.ScriptId), ("Source", dependency.SourceName), ("Sha256", dependency.Sha256))));
            }
        }
        else
        {
            var instructions = RequireArray(script, "instructions", "Script");
            nodes.Add(Node("script", null, "Script", "ScriptDocument", Properties(
                ("SchemaVersion", model.Script.SchemaVersion), ("InstructionCount", instructions.GetArrayLength()), ("File", model.Files.Script))));
            var instructionIndex = 0;
            foreach (var instruction in instructions.EnumerateArray())
            {
                nodes.Add(Node($"script.instructions[{instructionIndex}]", "script", $"Instruction {instructionIndex}", "HookInstruction", Properties(
                    ("Hook", RequireString(instruction, "hook", "Script.instructions[]")),
                    ("Operation", RequireString(instruction, "op", "Script.instructions[]")),
                    ("Value", FormatVector(RequireVector(instruction, "value", 2, "Script.instructions[]"))))));
                instructionIndex++;
            }
        }

        var runtime = RequireObject(preview, "runtime", "Preview");
        var arguments = RequireArray(runtime, "arguments", "Preview.runtime");
        nodes.Add(Node("preview", null, "Preview Config", "PreviewConfig", Properties(
            ("SchemaVersion", model.Preview.SchemaVersion),
            ("Executable", RequireString(runtime, "executable", "Preview.runtime")),
            ("WorkingDirectory", RequireString(runtime, "workingDirectory", "Preview.runtime")),
            ("ArgumentCount", arguments.GetArrayLength()),
            ("File", model.Files.Preview))));

        if (nodes.Count > MaxHierarchyNodes) throw Invariant($"Hierarchy exceeds node limit: {nodes.Count}.");
        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var node in nodes)
        {
            if (!ids.Add(node.Id) || (node.ParentId is not null && !ids.Contains(node.ParentId))) throw Invariant("Hierarchy node identity/order is invalid.");
        }
        return new HierarchySnapshot(EditorSnapshotVersions.Hierarchy, EditorSnapshotVersions.ProjectModel, project.ProjectName, nodes.ToArray());
    }

    internal static AssetCatalogSnapshot ReadAssetsCore(ProjectSessionInfo project, CancellationToken cancellationToken)
    {
        var packageRoot = ResolveExistingDirectory(project.PackageRoot, "Package root");
        var binRoot = EnsureInside(packageRoot, Path.Combine(packageRoot, "bin"), "Bin root");
        var assetRoot = ResolveExistingDirectory(EnsureInside(packageRoot, Path.Combine(binRoot, "assets"), "Package asset root"), "Package asset root");
        RejectReparsePoint(assetRoot, "Package asset root");

        var files = new List<string>();
        var pending = new Stack<string>();
        pending.Push(assetRoot);
        while (pending.Count > 0)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var directory = pending.Pop();
            foreach (var entry in Directory.EnumerateFileSystemEntries(directory))
            {
                cancellationToken.ThrowIfCancellationRequested();
                RejectReparsePoint(entry, "Asset catalog entry");
                var attributes = File.GetAttributes(entry);
                if ((attributes & FileAttributes.Directory) != 0) pending.Push(entry);
                else
                {
                    files.Add(Path.GetFullPath(entry));
                    if (files.Count > MaxAssetItems) throw Input($"Asset catalog exceeds item limit: {files.Count} > {MaxAssetItems}.");
                }
            }
        }
        files.Sort((left, right) =>
        {
            var insensitive = StringComparer.OrdinalIgnoreCase.Compare(left, right);
            return insensitive != 0 ? insensitive : StringComparer.Ordinal.Compare(left, right);
        });

        var items = new List<AssetCatalogItem>(files.Count);
        foreach (var path in files)
        {
            var fullPath = EnsureInside(assetRoot, path, "Asset path");
            var relativePath = Path.GetRelativePath(binRoot, fullPath).Replace('\\', '/');
            if (Path.IsPathRooted(relativePath) || !relativePath.StartsWith("assets/", StringComparison.Ordinal) || relativePath.Split('/').Any(part => part == ".."))
                throw Input($"Asset relative path is invalid: {relativePath}.");
            var assetId = "asset://" + relativePath["assets/".Length..];
            var category = AssetCategory(relativePath);
            var extension = Path.GetExtension(fullPath).TrimStart('.').ToLowerInvariant();
            var size = new FileInfo(fullPath).Length;
            items.Add(new AssetCatalogItem(assetId, Path.GetFileName(fullPath), relativePath, category, extension, size,
                Properties(("AssetId", assetId), ("RelativePath", relativePath), ("Category", category), ("Extension", extension), ("SizeBytes", size))));
        }
        return new AssetCatalogSnapshot(EditorSnapshotVersions.AssetCatalog, "bin/assets", items.Count, items.ToArray());
    }

    private static PublicationSnapshot ReadPublicationCore(ProjectSessionInfo project, string profile, CancellationToken cancellationToken)
    {
        if (profile is not ("debug" or "release")) throw Input($"Unsupported publication profile: {profile}.");
        var paths = ResolveProjectPaths(project);
        var sceneBytes = ReadFileSnapshot(paths.Scene, "Scene source", cancellationToken);
        var scriptSource = WorkspaceScriptSourceModel.Read(paths.Script, cancellationToken);
        var derived = EnsureInside(paths.ProjectDirectory, Path.Combine(paths.ProjectDirectory, ".kadath", "derived"), "Derived directory");
        if (Directory.Exists(derived)) RejectReparsePoint(derived, "Derived directory");
        var manifestPath = EnsureInside(paths.ProjectDirectory, Path.Combine(derived, ".live-bake.manifest.json"), "Manifest path");
        var sceneArtifact = EnsureInside(paths.ProjectDirectory, Path.Combine(derived, "scene.scene"), "Scene artifact");
        var scriptArtifact = EnsureInside(paths.ProjectDirectory, Path.Combine(derived, "script.script"), "Script artifact");
        string? diagnosticCode = null;
        string? diagnosticMessage = null;
        void SetDiagnostic(string code, string message)
        {
            if (diagnosticCode is null) { diagnosticCode = code; diagnosticMessage = message; }
        }

        var manifest = ReadManifest(manifestPath, cancellationToken, SetDiagnostic);
        var scene = ReadPublicationTarget("Scene", paths.Scene, Sha256(sceneBytes), sceneArtifact, manifest, profile, paths.PackageRoot, cancellationToken, SetDiagnostic);
        var script = ReadPublicationTarget("Script", paths.Script, scriptSource.Revision, scriptArtifact, manifest, profile, paths.PackageRoot, cancellationToken, SetDiagnostic);
        var state = AggregatePublicationState(scene.State, script.State);
        return new PublicationSnapshot(EditorSnapshotVersions.Publication, project.ProjectName, profile,
            manifest.Valid ? manifest.Profile : null, derived, manifestPath, state, manifest.Present, scene, script, diagnosticCode, diagnosticMessage);
    }

    private static ProjectModelSnapshot BuildProjectSnapshot(ProjectSessionInfo project, LoadedProject loaded)
    {
        var scene = WorkspaceSceneDocumentCodec.Parse(loaded.SceneBytes);
        var script = loaded.Script.RootElement;
        var preview = loaded.Preview.RootElement;
        var scriptVersion = RequireInt32(script, "schemaVersion", "Script");
        var previewVersion = RequireInt32(preview, "schemaVersion", "Preview");
        if (scriptVersion is not (1 or 2) || previewVersion != 1) throw Input("Snapshot project/model schema version is unsupported.");
        var textures = scene.Textures.Select(value => new ProjectModelTexture(value.TextureId, value.Artifact, value.SamplingProfile)).ToArray();
        var objects = scene.Objects.Select(value => value.ToProjectModel()).ToArray();
        var player = scene.Player;
        var goal = scene.Goal;
        var hazard = scene.PrimaryHazard;

        var scriptSource = WorkspaceScriptSourceModel.Read(loaded.Bytes.ScriptPath, default);
        var scriptGoal = Array.Empty<double>();
        var scriptVelocity = Array.Empty<double>();
        IReadOnlyList<ProjectModelScriptDependency>? dependencies = null;
        if (scriptVersion == 1)
        {
            var instructions = RequireArray(script, "instructions", "Script").EnumerateArray().ToArray();
            var onStart = instructions.Where(value => OptionalString(value, "hook") == "on_start" && OptionalString(value, "op") == "set_goal_position").ToArray();
            var fixedUpdate = instructions.Where(value => OptionalString(value, "hook") == "fixed_update" && OptionalString(value, "op") == "move_goal_velocity").ToArray();
            if (onStart.Length != 1 || fixedUpdate.Length != 1) throw Input("Project script does not contain the editable Hook v1 instructions.");
            scriptGoal = RequireVector(onStart[0], "value", 2, "Script on_start instruction");
            scriptVelocity = RequireVector(fixedUpdate[0], "value", 2, "Script fixed_update instruction");
        }
        else
        {
            dependencies = scriptSource.Dependencies
                .Select(dependency => new ProjectModelScriptDependency(dependency.ScriptId, dependency.SourceName))
                .ToArray();
        }
        var authoringRevision = scriptVersion == 1
            ? AuthoringRevision(loaded.SceneBytes, loaded.ScriptBytes)
            : AuthoringRevision(loaded.SceneBytes, scriptSource.Revision);
        return new ProjectModelSnapshot(EditorSnapshotVersions.ProjectModel, project.ProjectName,
            authoringRevision,
            new ProjectModelFiles(loaded.Bytes.ProjectDirectory, loaded.Bytes.ScenePath, loaded.Bytes.ScriptPath, loaded.Bytes.PreviewPath),
            new ProjectModelScene(
                scene.SourceSchemaVersion,
                goal?.Position.ToArray() ?? [],
                player?.TextureId ?? 0,
                goal?.TextureId ?? 0,
                hazard?.TextureId ?? 0,
                textures,
                objects,
                scene.Gameplay.Profile,
                scene.Gameplay.IsEnabled ? scene.Gameplay.TimeLimitSeconds : null,
                scene.Prototypes.Select(prototype => prototype.ToProjectModel()).ToArray(),
                scene.Tilemaps.Select(tilemap => tilemap.ToProjectModel()).ToArray()),
            new ProjectModelScript(scriptVersion, scriptGoal, scriptVelocity, dependencies), new ProjectModelPreview(previewVersion));
    }

    internal static WorkspaceProjectBytes ReadProjectBytes(ProjectSessionInfo project, CancellationToken cancellationToken)
    {
        var paths = ResolveProjectPaths(project);
        var sceneBytes = ReadFileSnapshot(paths.Scene, "Scene", cancellationToken);
        var scriptBytes = ReadFileSnapshot(paths.Script, "Script", cancellationToken);
        var previewBytes = ReadFileSnapshot(paths.Preview, "Preview config", cancellationToken);
        return new WorkspaceProjectBytes(paths.PackageRoot, paths.ProjectDirectory, paths.Scene, paths.Script, paths.Preview, sceneBytes, scriptBytes, previewBytes);
    }

    internal static WorkspaceProjectProjection ProjectSnapshotsFromBytes(ProjectSessionInfo project, WorkspaceProjectBytes bytes)
    {
        try
        {
            using var loaded = new LoadedProject(bytes, ParseJson(bytes.Scene), ParseJson(bytes.Script), ParseJson(bytes.Preview));
            var model = BuildProjectSnapshot(project, loaded);
            return new WorkspaceProjectProjection(model, BuildHierarchySnapshot(project, loaded, model));
        }
        catch (JsonException exception) { throw Input($"Failed to parse project JSON: {exception.Message}", exception); }
    }

    private static ProjectModelSnapshot ProjectSnapshotFromBytes(ProjectSessionInfo project, WorkspaceProjectBytes bytes)
    {
        try
        {
            using var loaded = new LoadedProject(bytes, ParseJson(bytes.Scene), ParseJson(bytes.Script), ParseJson(bytes.Preview));
            return BuildProjectSnapshot(project, loaded);
        }
        catch (JsonException exception) { throw Input($"Failed to parse project JSON: {exception.Message}", exception); }
    }

    private static ProjectPaths ResolveProjectPaths(ProjectSessionInfo project)
    {
        if (!ProjectNamePattern.IsMatch(project.ProjectName)) throw Input("ProjectName must start with a letter or digit and contain at most 48 safe characters.");
        var packageRoot = ResolveExistingDirectory(project.PackageRoot, "Package root");
        var projectsRoot = EnsureInside(packageRoot, Path.Combine(packageRoot, "bin", "projects"), "Projects root");
        if (Directory.Exists(projectsRoot)) RejectReparsePoint(projectsRoot, "Projects root");
        var projectDirectory = EnsureInside(projectsRoot, Path.Combine(projectsRoot, project.ProjectName), "Project directory");
        if (!Directory.Exists(projectDirectory)) throw Input($"Project directory does not exist: {projectDirectory}.");
        RejectReparsePoint(projectDirectory, "Project directory");
        return new ProjectPaths(packageRoot, projectDirectory,
            EnsureInside(projectDirectory, Path.Combine(projectDirectory, "scene.json"), "Scene source"),
            EnsureInside(projectDirectory, Path.Combine(projectDirectory, "script.json"), "Script source"),
            EnsureInside(projectDirectory, Path.Combine(projectDirectory, "preview.json"), "Preview config"));
    }

    private static ManifestSnapshot ReadManifest(string path, CancellationToken cancellationToken, Action<string, string> diagnostic)
    {
        if (!File.Exists(path)) return ManifestSnapshot.Missing;
        try
        {
            var bytes = ReadFileSnapshot(path, "Manifest", cancellationToken);
            using var document = ParseJson(bytes);
            var root = document.RootElement;
            if (RequireInt32(root, "schemaVersion", "Manifest") != 1) throw Input("Unsupported live-bake manifest schema.");
            var profile = RequireString(root, "profile", "Manifest");
            if (profile is not ("debug" or "release")) throw Input("Unsupported live-bake manifest profile.");
            var scene = ReadManifestEntry(root, "scene");
            var script = ReadManifestEntry(root, "script");
            return new ManifestSnapshot(true, true, profile, scene, script);
        }
        catch (Exception exception) when (exception is not OperationCanceledException)
        {
            diagnostic("manifest_invalid", exception.Message);
            return new ManifestSnapshot(true, false, null, null, null);
        }
    }

    private static ManifestEntry ReadManifestEntry(JsonElement root, string name)
    {
        var value = RequireObject(root, name, "Manifest");
        var sourcePath = RequireString(value, "sourcePath", $"Manifest.{name}");
        var sourceHash = RequireString(value, "sourceSha256", $"Manifest.{name}");
        var artifactPath = RequireString(value, "artifactPath", $"Manifest.{name}");
        var artifactHash = RequireString(value, "artifactSha256", $"Manifest.{name}");
        if (!IsHex64(sourceHash) || !IsHex64(artifactHash)) throw Input($"Manifest {name} entry has an invalid SHA-256 revision.");
        if (!value.TryGetProperty("artifactBytes", out var bytesElement) || bytesElement.ValueKind != JsonValueKind.Number || !bytesElement.TryGetInt64(out var artifactBytes) || artifactBytes <= 0)
            throw Input($"Manifest {name} entry has an invalid artifact byte count.");
        return new ManifestEntry(sourcePath, sourceHash, artifactPath, artifactHash, artifactBytes);
    }

    private static PublicationTargetSnapshot ReadPublicationTarget(string kind, string sourcePath, string sourceRevision, string artifactPath,
        ManifestSnapshot manifest, string requestedProfile, string packageRoot, CancellationToken cancellationToken, Action<string, string> diagnostic)
    {
        ArtifactInfo? artifact = null;
        var artifactFailure = false;
        try { artifact = ReadArtifactInfo(artifactPath, kind, cancellationToken); }
        catch (Exception exception) when (exception is not OperationCanceledException)
        {
            artifactFailure = true;
            diagnostic("artifact_invalid", exception.Message);
        }
        var entry = manifest.Valid ? (kind == "Scene" ? manifest.Scene : manifest.Script) : null;
        var expectedSourcePath = Path.GetRelativePath(packageRoot, sourcePath).Replace('\\', '/');
        var expectedArtifactPath = Path.GetRelativePath(packageRoot, artifactPath).Replace('\\', '/');
        var pathMismatch = entry is not null && (entry.SourcePath != expectedSourcePath || entry.ArtifactPath != expectedArtifactPath);
        if (pathMismatch) diagnostic("manifest_invalid", $"{kind} manifest paths do not match the current project.");
        var identityInvalid = artifact is not null && entry is not null &&
            (!string.Equals(artifact.Sha256, entry.ArtifactSha256, StringComparison.OrdinalIgnoreCase) || artifact.Bytes != entry.ArtifactBytes);
        if (identityInvalid) diagnostic("artifact_invalid", $"{kind} artifact hash or byte count does not match the manifest.");
        var manifestEvidenceInvalid = manifest.Present && (!manifest.Valid || entry is null || pathMismatch);
        var state = manifestEvidenceInvalid || artifactFailure || identityInvalid ? "artifact_invalid"
            : !manifest.Present || artifact is null ? "missing"
            : manifest.Profile != requestedProfile ? "profile_mismatch"
            : entry is null || !string.Equals(sourceRevision, entry.SourceSha256, StringComparison.OrdinalIgnoreCase) ? "source_dirty"
            : "current";
        return new PublicationTargetSnapshot(kind, state, sourceRevision, entry?.SourceSha256, artifact?.Sha256, entry?.ArtifactSha256, artifact?.Bytes, entry?.ArtifactBytes);
    }

    private static ArtifactInfo? ReadArtifactInfo(string path, string kind, CancellationToken cancellationToken)
    {
        if (!File.Exists(path)) return null;
        var bytes = ReadFileSnapshot(path, $"{kind} artifact", cancellationToken);
        if (kind == "Scene")
        {
            _ = WorkspaceSceneCodec.ValidateArtifact(bytes);
        }
        else
        {
            _ = WorkspaceScriptCodec.ValidateArtifact(bytes);
        }
        return new ArtifactInfo(Sha256(bytes), bytes.LongLength);
    }

    private static byte[] ReadFileSnapshot(string path, string name, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!File.Exists(path)) throw Input($"{name} does not exist: {path}.");
        RejectReparsePoint(path, name);
        var bytes = File.ReadAllBytes(path);
        cancellationToken.ThrowIfCancellationRequested();
        return bytes;
    }

    private static string ResolveExistingDirectory(string path, string name)
    {
        var full = Path.GetFullPath(path);
        if (!Directory.Exists(full)) throw Input($"{name} does not exist: {path}.");
        return full;
    }

    private static string EnsureInside(string root, string path, string name)
    {
        var fullRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var full = Path.GetFullPath(path);
        var prefix = fullRoot + Path.DirectorySeparatorChar;
        if (!full.Equals(fullRoot, PathComparison) && !full.StartsWith(prefix, PathComparison))
            throw Input($"{name} escapes root: {path}.");
        return full;
    }

    private static void RejectReparsePoint(string path, string name)
    {
        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) throw Input($"{name} cannot be a reparse point: {path}.");
    }

    private static JsonElement RequireObject(JsonElement owner, string name, string context)
    {
        if (!owner.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.Object) throw Input($"{context}.{name} must be an object.");
        return value;
    }

    private static JsonElement RequireArray(JsonElement owner, string name, string context)
    {
        if (!owner.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.Array) throw Input($"{context}.{name} must be an array.");
        return value;
    }

    private static string RequireString(JsonElement owner, string name, string context)
    {
        if (!owner.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.String || string.IsNullOrEmpty(value.GetString())) throw Input($"{context}.{name} must be a non-empty string.");
        return value.GetString()!;
    }

    private static string? OptionalString(JsonElement owner, string name) =>
        owner.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    private static int RequireInt32(JsonElement owner, string name, string context)
    {
        if (!owner.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.Number || !value.TryGetInt32(out var result)) throw Input($"{context}.{name} must be an integer.");
        return result;
    }

    private static uint RequireUInt32(JsonElement owner, string name, string context)
    {
        if (!owner.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.Number || !value.TryGetUInt32(out var result)) throw Input($"{context}.{name} must be a u32.");
        return result;
    }

    private static double RequireFiniteDouble(JsonElement owner, string name, string context)
    {
        if (!owner.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.Number || !value.TryGetDouble(out var result) || !double.IsFinite(result))
            throw Input($"{context}.{name} must be finite.");
        return result;
    }

    private static double[] RequireVector(JsonElement owner, string name, int length, string context)
    {
        var array = RequireArray(owner, name, context);
        if (array.GetArrayLength() != length) throw Input($"{context}.{name} must contain exactly {length} values.");
        var result = new double[length];
        var index = 0;
        foreach (var value in array.EnumerateArray())
        {
            if (value.ValueKind != JsonValueKind.Number || !value.TryGetDouble(out result[index]) || !double.IsFinite(result[index])) throw Input($"{context}.{name}[{index}] must be finite.");
            index++;
        }
        return result;
    }

    internal static string AuthoringRevision(byte[] scene, byte[] script)
    {
        var identity = $"kadath-authoring-v1\nscene:{Sha256(scene)}\nscript:{Sha256(script)}";
        return Sha256(Encoding.UTF8.GetBytes(identity));
    }

    internal static string AuthoringRevision(byte[] scene, string scriptRevision)
    {
        var identity = $"kadath-authoring-v2\nscene:{Sha256(scene)}\nscript:{scriptRevision}";
        return Sha256(Encoding.UTF8.GetBytes(identity));
    }

    private static string Sha256(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
    private static JsonDocument ParseJson(byte[] bytes)
    {
        var offset = bytes.AsSpan().StartsWith(Encoding.UTF8.Preamble) ? Encoding.UTF8.Preamble.Length : 0;
        return JsonDocument.Parse(bytes.AsMemory(offset));
    }
    private static bool IsHex64(string? value) => value is { Length: 64 } && value.All(Uri.IsHexDigit);
    private static string FormatNumber(double value) => value.ToString("0.###", CultureInfo.InvariantCulture);
    private static string FormatVector(IEnumerable<double> values) => string.Join(", ", values.Select(FormatNumber));
    private static string AggregatePublicationState(params string[] states) => states.Contains("artifact_invalid", StringComparer.Ordinal) ? "artifact_invalid"
        : states.Contains("missing", StringComparer.Ordinal) ? "missing"
        : states.Contains("profile_mismatch", StringComparer.Ordinal) ? "profile_mismatch"
        : states.Contains("source_dirty", StringComparer.Ordinal) ? "source_dirty" : "current";
    private static string AssetCategory(string relativePath) => relativePath.ToLowerInvariant() switch
    {
        var value when value.StartsWith("assets/audio/") => "Audio",
        var value when value.StartsWith("assets/renderer2d/") => "Texture",
        var value when value.StartsWith("assets/scenes/") => "Scene",
        var value when value.StartsWith("assets/scripts/") => "Script",
        _ => "Other"
    };
    private static bool IsTextureArtifactPath(string artifact) => Encoding.UTF8.GetByteCount(artifact) <= 255
        && artifact.StartsWith("assets/renderer2d/", StringComparison.Ordinal) && artifact.EndsWith(".texture", StringComparison.Ordinal)
        && !artifact.Contains('\\') && artifact.Split('/').All(segment => segment.Length > 0 && segment is not "." and not "..");
    private static HierarchyNode Node(string id, string? parentId, string displayName, string kind, Dictionary<string, JsonElement> properties) =>
        new(id, parentId, displayName, kind, properties);
    private static Dictionary<string, JsonElement> Properties(params (string Name, object? Value)[] values) =>
        values.ToDictionary(value => value.Name, value => JsonSerializer.SerializeToElement(value.Value, EditorProtocol.JsonOptions), StringComparer.Ordinal);
    private static WorkspaceReadException Input(string message, Exception? inner = null) => new(WorkspaceReadFailureKind.Input, message, inner);
    private static WorkspaceReadException Invariant(string message) => new(WorkspaceReadFailureKind.Invariant, message);

    private sealed record ProjectPaths(string PackageRoot, string ProjectDirectory, string Scene, string Script, string Preview);
    private sealed record ArtifactInfo(string Sha256, long Bytes);
    private sealed record ManifestEntry(string SourcePath, string SourceSha256, string ArtifactPath, string ArtifactSha256, long ArtifactBytes);
    private sealed record ManifestSnapshot(bool Present, bool Valid, string? Profile, ManifestEntry? Scene, ManifestEntry? Script)
    {
        public static readonly ManifestSnapshot Missing = new(false, false, null, null, null);
    }

    private sealed class LoadedProject : IDisposable
    {
        public LoadedProject(WorkspaceProjectBytes bytes, JsonDocument scene, JsonDocument script, JsonDocument preview)
        { Bytes = bytes; Scene = scene; Script = script; Preview = preview; }
        public WorkspaceProjectBytes Bytes { get; }
        public byte[] SceneBytes => Bytes.Scene;
        public byte[] ScriptBytes => Bytes.Script;
        public JsonDocument Scene { get; }
        public JsonDocument Script { get; }
        public JsonDocument Preview { get; }
        public void Dispose() { Scene.Dispose(); Script.Dispose(); Preview.Dispose(); }
    }
}
