using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Kadath.Editor.Protocol;

namespace Kadath.Editor.Workspace;

internal enum WorkspaceProjectValidationFailureKind
{
    InvalidProjectName,
    PackageNotFound,
    PathEscape,
    ProjectFileMissing,
    Validation
}

internal sealed class WorkspaceProjectValidationException : Exception
{
    public WorkspaceProjectValidationException(WorkspaceProjectValidationFailureKind kind, string message, Exception? innerException = null)
        : base(message, innerException) => Kind = kind;

    public WorkspaceProjectValidationFailureKind Kind { get; }
}

internal sealed record WorkspaceProjectPaths(
    string PackageRoot,
    string BinDirectory,
    string ProjectsDirectory,
    string ProjectDirectory,
    string ScenePath,
    string ScriptPath,
    string PreviewPath);

internal sealed record WorkspacePreviewConfig(
    string Executable,
    string WorkingDirectory,
    string[] Arguments);

internal static class WorkspaceProjectValidator
{
    internal const int MaxDocumentBytes = 64 * 1024;
    private static readonly Regex ProjectNamePattern = new("^[A-Za-z0-9][A-Za-z0-9_-]{0,47}$", RegexOptions.CultureInvariant);
    private static readonly StringComparison PathComparison = OperatingSystem.IsWindows()
        ? StringComparison.OrdinalIgnoreCase
        : StringComparison.Ordinal;

    internal static void ValidateProjectName(string projectName)
    {
        if (string.IsNullOrEmpty(projectName) || !ProjectNamePattern.IsMatch(projectName))
        {
            throw Failure(WorkspaceProjectValidationFailureKind.InvalidProjectName, "ProjectName must start with a letter or digit and contain at most 48 safe characters.");
        }
    }

    internal static WorkspaceProjectPaths ResolveOpenPaths(ProjectSessionInfo project)
    {
        ValidateProjectName(project.ProjectName);
        var paths = ResolvePaths(project.PackageRoot, project.ProjectName, requireProjectsDirectory: true);
        RequireExpectedPath(project.ProjectDirectory, paths.ProjectDirectory, "Project directory");
        RequireExpectedPath(project.ScenePath, paths.ScenePath, "Scene source");
        RequireExpectedPath(project.ScriptPath, paths.ScriptPath, "Script source");
        RequireExpectedPath(project.PreviewPath, paths.PreviewPath, "Preview config");
        RequireDirectory(paths.ProjectDirectory, "Project directory");
        RequireFile(paths.ScenePath, "Scene source", WorkspaceProjectValidationFailureKind.ProjectFileMissing);
        RequireFile(paths.ScriptPath, "Script source", WorkspaceProjectValidationFailureKind.ProjectFileMissing);
        RequireFile(paths.PreviewPath, "Preview config", WorkspaceProjectValidationFailureKind.ProjectFileMissing);
        return paths;
    }

    internal static WorkspaceProjectPaths ResolvePaths(string packageRoot, string projectName, bool requireProjectsDirectory)
    {
        ValidateProjectName(projectName);
        var normalizedPackageRoot = Path.GetFullPath(packageRoot);
        RequireDirectory(normalizedPackageRoot, "Package root", WorkspaceProjectValidationFailureKind.PackageNotFound);
        var binDirectory = EnsureInside(normalizedPackageRoot, Path.Combine(normalizedPackageRoot, "bin"), "Package bin directory", WorkspaceProjectValidationFailureKind.PathEscape);
        RequireDirectory(binDirectory, "Package bin directory");
        var projectsDirectory = EnsureInside(normalizedPackageRoot, Path.Combine(binDirectory, "projects"), "Projects directory", WorkspaceProjectValidationFailureKind.PathEscape);
        if (requireProjectsDirectory) RequireDirectory(projectsDirectory, "Projects directory");
        else if (Directory.Exists(projectsDirectory)) RejectReparsePoint(projectsDirectory, "Projects directory");
        var projectDirectory = EnsureInside(projectsDirectory, Path.Combine(projectsDirectory, projectName), "Project directory", WorkspaceProjectValidationFailureKind.PathEscape);
        return new WorkspaceProjectPaths(
            normalizedPackageRoot,
            binDirectory,
            projectsDirectory,
            projectDirectory,
            Path.Combine(projectDirectory, "scene.json"),
            Path.Combine(projectDirectory, "script.json"),
            Path.Combine(projectDirectory, "preview.json"));
    }

    internal static WorkspaceProjectBytes ReadAndValidate(ProjectSessionInfo project, CancellationToken cancellationToken)
    {
        var paths = ResolveOpenPaths(project);
        var bytes = new WorkspaceProjectBytes(
            paths.PackageRoot,
            paths.ProjectDirectory,
            paths.ScenePath,
            paths.ScriptPath,
            paths.PreviewPath,
            ReadDocument(paths.ScenePath, "Scene", cancellationToken, WorkspaceProjectValidationFailureKind.ProjectFileMissing),
            ReadDocument(paths.ScriptPath, "Script", cancellationToken, WorkspaceProjectValidationFailureKind.ProjectFileMissing),
            ReadDocument(paths.PreviewPath, "Preview config", cancellationToken, WorkspaceProjectValidationFailureKind.ProjectFileMissing));
        ValidateBytes(project, bytes, cancellationToken);
        return bytes;
    }

    internal static void ValidateBytes(ProjectSessionInfo project, WorkspaceProjectBytes bytes, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        ValidateSceneSource(bytes.Scene);
        ValidateScriptSource(bytes.Script);
        _ = WorkspaceScriptSourceModel.Read(bytes.ScriptPath, cancellationToken);
        ValidatePreview(bytes.Preview, bytes.PackageRoot, bytes.ScenePath, bytes.ScriptPath, allowMissingProjectSources: false);
        cancellationToken.ThrowIfCancellationRequested();
    }

    internal static void ValidateCreateInputs(
        byte[] scene,
        byte[] script,
        byte[] preview,
        WorkspaceProjectPaths paths,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        ValidateDocumentBudget(scene, "Scene template");
        ValidateDocumentBudget(script, "Script template");
        ValidateDocumentBudget(preview, "Preview config");
        ValidateSceneSource(scene);
        ValidateScriptSource(script);
        ValidatePreview(preview, paths.PackageRoot, paths.ScenePath, paths.ScriptPath, allowMissingProjectSources: true);
        cancellationToken.ThrowIfCancellationRequested();
    }

    internal static byte[] ReadDocument(
        string path,
        string name,
        CancellationToken cancellationToken,
        WorkspaceProjectValidationFailureKind missingKind = WorkspaceProjectValidationFailureKind.Validation)
    {
        cancellationToken.ThrowIfCancellationRequested();
        RequireFile(path, name, missingKind);
        var information = new FileInfo(path);
        if (information.Length > MaxDocumentBytes) throw Failure($"{name} exceeds the 64 KiB Runtime document budget: {path}.");
        var bytes = File.ReadAllBytes(path);
        cancellationToken.ThrowIfCancellationRequested();
        return bytes;
    }

    internal static string ResolveRequiredFile(string packageRoot, string relativePath, string name)
    {
        var path = ResolvePackagePath(packageRoot, relativePath, name);
        RequireFile(path, name);
        return path;
    }

    internal static void ValidateSceneSource(byte[] bytes)
    {
        ValidateDocumentBudget(bytes, "Scene");
        _ = WorkspaceSceneDocumentCodec.Parse(bytes);
    }

    internal static void ValidateScriptSource(byte[] bytes)
    {
        WorkspaceScriptSourceModel.ValidateManifest(bytes);
    }

    internal static void ValidateLegacyScriptSource(byte[] bytes)
    {
        ValidateDocumentBudget(bytes, "Script");
        using var document = Parse(bytes, "Script");
        var script = RequireRootObject(document.RootElement, "Script");
        AssertProperties(script, ["schemaVersion", "instructions"], "Script");
        if (RequireInt32(script, "schemaVersion", "Script") != 1) throw Failure("Unsupported Script schemaVersion.");
        var instructions = RequireArray(script, "instructions", "Script");
        if (instructions.GetArrayLength() > 16) throw Failure("Script instruction budget exceeded: maximum is 16.");

        var editableOnStart = 0;
        var editableFixedUpdate = 0;
        var index = 0;
        foreach (var instruction in instructions.EnumerateArray())
        {
            var owner = $"Script.instructions[{index}]";
            RequireObjectValue(instruction, owner);
            AssertProperties(instruction, ["hook", "op", "value"], owner);
            var hook = RequireString(instruction, "hook", owner);
            var operation = RequireString(instruction, "op", owner);
            var value = RequireVector(instruction, "value", 2, owner);
            if (hook == "on_start")
            {
                if (operation != "set_goal_position") throw Failure($"{owner} has an invalid on_start operation: {operation}.");
                editableOnStart++;
            }
            else if (hook == "fixed_update")
            {
                if (operation != "move_goal_velocity") throw Failure($"{owner} has an invalid fixed_update operation: {operation}.");
                if (Math.Abs(value[0]) > 1000 || Math.Abs(value[1]) > 1000) throw Failure($"{owner} velocity exceeds the 1000 units/second limit.");
                editableFixedUpdate++;
            }
            else
            {
                throw Failure($"{owner} has an unsupported hook: {hook}.");
            }
            index++;
        }
        if (editableOnStart != 1 || editableFixedUpdate != 1) throw Failure("Script must contain exactly one editable on_start and fixed_update instruction.");
    }

    private static void ValidatePreview(byte[] bytes, string packageRoot, string scenePath, string scriptPath, bool allowMissingProjectSources)
    {
        var config = ParsePreviewConfig(bytes);
        var executablePath = ResolvePackagePath(packageRoot, config.Executable, "Preview executable");
        var workingDirectoryPath = ResolvePackagePath(packageRoot, config.WorkingDirectory, "Preview working directory");
        RequireFile(executablePath, "Preview executable");
        RequireDirectory(workingDirectoryPath, "Preview working directory");

        var sceneArgumentCount = 0;
        var scriptArgumentCount = 0;
        for (var index = 0; index < config.Arguments.Length; index++)
        {
            var argument = config.Arguments[index];
            if (argument is not ("--scene" or "--script")) continue;
            if (index + 1 >= config.Arguments.Length) throw Failure($"Preview {argument} requires a following path.");
            var relativePath = config.Arguments[++index];
            if (string.IsNullOrWhiteSpace(relativePath) || Path.IsPathRooted(relativePath)) throw Failure($"Preview {argument} path must be relative to workingDirectory.");
            var resolved = EnsureInside(packageRoot, Path.Combine(workingDirectoryPath, relativePath), $"Preview {argument} path");
            RejectExistingPathChain(packageRoot, resolved, $"Preview {argument} path");
            var expected = argument == "--scene" ? scenePath : scriptPath;
            if (!allowMissingProjectSources || !PathEquals(resolved, expected)) RequireFile(resolved, $"Preview {argument} path");
            if (argument == "--scene") sceneArgumentCount++;
            else scriptArgumentCount++;
        }
        if (sceneArgumentCount != 1 || scriptArgumentCount != 1) throw Failure("Preview config must contain exactly one --scene and one --script argument.");
    }

    internal static WorkspacePreviewConfig ParsePreviewConfig(byte[] bytes)
    {
        ValidateDocumentBudget(bytes, "Preview config");
        using var document = Parse(bytes, "Preview config");
        var config = RequireRootObject(document.RootElement, "Preview config");
        AssertProperties(config, ["schemaVersion", "runtime"], "Preview config");
        if (RequireInt32(config, "schemaVersion", "Preview config") != 1) throw Failure("Unsupported Preview config schemaVersion.");
        var runtime = RequireObject(config, "runtime", "Preview config");
        AssertProperties(runtime, ["executable", "workingDirectory", "arguments"], "Preview config.runtime");
        var arguments = RequireArray(runtime, "arguments", "Preview config.runtime")
            .EnumerateArray()
            .Select(value => value.ValueKind == JsonValueKind.String
                ? value.GetString()!
                : throw Failure("Preview config.runtime.arguments must contain only strings."))
            .ToArray();
        return new WorkspacePreviewConfig(
            RequireString(runtime, "executable", "Preview config.runtime"),
            RequireString(runtime, "workingDirectory", "Preview config.runtime"),
            arguments);
    }

    private static void ValidateSprite(JsonElement sprite, string name, HashSet<uint> textureIds)
    {
        _ = RequireVector(sprite, "position", 2, name);
        var size = RequireVector(sprite, "size", 2, name);
        if (size.Any(value => value <= 0)) throw Failure($"{name}.size values must be greater than zero.");
        var color = RequireVector(sprite, "color", 4, name);
        if (color.Any(value => value is < 0 or > 1)) throw Failure($"{name}.color values must be in the range [0, 1].");
        var textureId = RequireUInt32(sprite, "textureId", name);
        if (textureId == 0) throw Failure($"{name}.textureId must be a non-zero u32.");
        if (!textureIds.Contains(textureId)) throw Failure("Scene sprite textureId is not declared by Scene.textures.");
    }

    private static JsonDocument Parse(byte[] bytes, string name)
    {
        try
        {
            var offset = bytes.AsSpan().StartsWith(Encoding.UTF8.Preamble) ? Encoding.UTF8.Preamble.Length : 0;
            return JsonDocument.Parse(bytes.AsMemory(offset), new JsonDocumentOptions { CommentHandling = JsonCommentHandling.Disallow, AllowTrailingCommas = false });
        }
        catch (JsonException exception)
        {
            throw Failure($"Failed to parse {name}: {exception.Message}", exception);
        }
    }

    private static JsonElement RequireRootObject(JsonElement value, string name)
    {
        RequireObjectValue(value, name);
        return value;
    }

    private static void RequireObjectValue(JsonElement value, string name)
    {
        if (value.ValueKind != JsonValueKind.Object) throw Failure($"{name} must be an object.");
    }

    private static JsonElement RequireObject(JsonElement owner, string name, string context)
    {
        if (!owner.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.Object) throw Failure($"{context}.{name} must be an object.");
        return value;
    }

    private static JsonElement RequireArray(JsonElement owner, string name, string context)
    {
        if (!owner.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.Array) throw Failure($"{context}.{name} must be an array.");
        return value;
    }

    private static string RequireString(JsonElement owner, string name, string context)
    {
        if (!owner.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.String || string.IsNullOrEmpty(value.GetString())) throw Failure($"{context}.{name} must be a non-empty string.");
        return value.GetString()!;
    }

    private static int RequireInt32(JsonElement owner, string name, string context)
    {
        if (!owner.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.Number || !value.TryGetInt32(out var result)) throw Failure($"{context}.{name} must be an integer.");
        return result;
    }

    private static uint RequireUInt32(JsonElement owner, string name, string context)
    {
        if (!owner.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.Number || !value.TryGetUInt32(out var result)) throw Failure($"{context}.{name} must be a u32.");
        return result;
    }

    private static double RequireFiniteDouble(JsonElement owner, string name, string context)
    {
        if (!owner.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.Number || !value.TryGetDouble(out var result)
            || !double.IsFinite(result) || !float.IsFinite((float)result)) throw Failure($"{context}.{name} must fit the finite f32 range.");
        return result;
    }

    private static double[] RequireVector(JsonElement owner, string name, int length, string context)
    {
        var values = RequireArray(owner, name, context);
        if (values.GetArrayLength() != length) throw Failure($"{context}.{name} must contain exactly {length} numbers.");
        var result = new double[length];
        var index = 0;
        foreach (var value in values.EnumerateArray())
        {
            if (value.ValueKind != JsonValueKind.Number || !value.TryGetDouble(out result[index]) || !double.IsFinite(result[index])
                || !float.IsFinite((float)result[index])) throw Failure($"{context}.{name}[{index}] must fit the finite f32 range.");
            index++;
        }
        return result;
    }

    private static void AssertProperties(JsonElement value, string[] expected, string owner)
    {
        var expectedSet = expected.ToHashSet(StringComparer.Ordinal);
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var property in value.EnumerateObject())
        {
            if (!expectedSet.Contains(property.Name)) throw Failure($"{owner} contains an unsupported property: {property.Name}.");
            if (!seen.Add(property.Name)) throw Failure($"{owner} contains a duplicate property: {property.Name}.");
        }
        foreach (var name in expected)
        {
            if (!seen.Contains(name)) throw Failure($"{owner} is missing required property: {name}.");
        }
    }

    private static string ResolvePackagePath(string packageRoot, string relativePath, string name)
    {
        if (string.IsNullOrWhiteSpace(relativePath) || Path.IsPathRooted(relativePath)) throw Failure($"{name} must be relative to the package root: {relativePath}.");
        var fullPath = EnsureInside(packageRoot, Path.Combine(packageRoot, relativePath), name);
        RejectExistingPathChain(packageRoot, fullPath, name);
        return fullPath;
    }

    private static string EnsureInside(
        string root,
        string path,
        string name,
        WorkspaceProjectValidationFailureKind failureKind = WorkspaceProjectValidationFailureKind.Validation)
    {
        var fullRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var fullPath = Path.GetFullPath(path);
        var prefix = fullRoot + Path.DirectorySeparatorChar;
        if (!fullPath.Equals(fullRoot, PathComparison) && !fullPath.StartsWith(prefix, PathComparison)) throw Failure(failureKind, $"{name} escapes root: {path}.");
        return fullPath;
    }

    private static void RequireExpectedPath(string actual, string expected, string name)
    {
        if (!PathEquals(actual, expected)) throw Failure(WorkspaceProjectValidationFailureKind.PathEscape, $"{name} does not match the current project identity.");
    }

    private static bool PathEquals(string left, string right) => Path.GetFullPath(left).Equals(Path.GetFullPath(right), PathComparison);

    private static void RequireDirectory(
        string path,
        string name,
        WorkspaceProjectValidationFailureKind missingKind = WorkspaceProjectValidationFailureKind.Validation)
    {
        if (!Directory.Exists(path)) throw Failure(missingKind, $"{name} does not exist: {path}.");
        RejectReparsePoint(path, name);
    }

    private static void RequireFile(
        string path,
        string name,
        WorkspaceProjectValidationFailureKind missingKind = WorkspaceProjectValidationFailureKind.Validation)
    {
        if (!File.Exists(path)) throw Failure(missingKind, $"{name} does not exist: {path}.");
        RejectReparsePoint(path, name);
    }

    private static void RejectExistingPathChain(string root, string path, string name)
    {
        RejectReparsePoint(root, "Package root");
        var relative = Path.GetRelativePath(root, path);
        var current = Path.GetFullPath(root);
        foreach (var segment in relative.Split([Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar], StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, segment);
            if (Directory.Exists(current) || File.Exists(current)) RejectReparsePoint(current, name);
            else break;
        }
    }

    internal static void RejectReparsePoint(string path, string name)
    {
        var information = Directory.Exists(path) ? (FileSystemInfo)new DirectoryInfo(path) : new FileInfo(path);
        information.Refresh();
        if ((information.Attributes & FileAttributes.ReparsePoint) != 0 || information.LinkTarget is not null) throw Failure($"{name} cannot be a reparse point: {path}.");
    }

    private static void ValidateDocumentBudget(byte[] bytes, string name)
    {
        if (bytes.Length > MaxDocumentBytes) throw Failure($"{name} exceeds the 64 KiB Runtime document budget.");
    }

    internal static bool IsTextureArtifactPath(string artifact) => Encoding.UTF8.GetByteCount(artifact) <= 255
        && artifact.StartsWith("assets/renderer2d/", StringComparison.Ordinal)
        && artifact.EndsWith(".texture", StringComparison.Ordinal)
        && !artifact.Contains('\\')
        && artifact.Split('/').All(segment => segment.Length > 0 && segment is not "." and not "..");

    private static WorkspaceProjectValidationException Failure(string message, Exception? innerException = null) =>
        Failure(WorkspaceProjectValidationFailureKind.Validation, message, innerException);

    private static WorkspaceProjectValidationException Failure(
        WorkspaceProjectValidationFailureKind kind,
        string message,
        Exception? innerException = null) => new(kind, message, innerException);
}
