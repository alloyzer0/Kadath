using Kadath.Editor.Protocol;

namespace Kadath.Editor.Workspace;

public sealed record WorkspacePreviewPlan(
    string PackageRoot,
    string ConfigPath,
    string ExecutablePath,
    string WorkingDirectory,
    string[] RuntimeArguments,
    string SceneInputPath,
    string ScriptInputPath,
    string? SceneSourcePath,
    string? ScriptSourcePath,
    string? DerivedDirectory,
    string? ManifestPath,
    string? BakeProfile,
    EditorBakeResult? InitialBake);

public sealed class WorkspacePreviewModel
{
    private static readonly StringComparison PathComparison = OperatingSystem.IsWindows()
        ? StringComparison.OrdinalIgnoreCase
        : StringComparison.Ordinal;
    private readonly WorkspacePublicationModel _publicationModel;

    public WorkspacePreviewModel(WorkspacePublicationModel publicationModel) => _publicationModel = publicationModel;

    public Task<WorkspacePreviewPlan> PrepareAsync(PreviewStartParameters parameters, CancellationToken cancellationToken) =>
        Task.FromResult(Prepare(parameters, cancellationToken));

    public Task<EditorBakeResult> BakeAsync(WorkspacePreviewPlan plan, string target, CancellationToken cancellationToken)
    {
        if (plan.SceneSourcePath is null || plan.ScriptSourcePath is null || plan.DerivedDirectory is null || plan.BakeProfile is null)
            throw new WorkspacePublicationException(WorkspacePublicationFailureKind.Validation, "Preview plan is not configured for Live Bake.");
        return Task.FromResult(_publicationModel.BakeResolvedCore(
            plan.PackageRoot,
            plan.SceneSourcePath,
            plan.ScriptSourcePath,
            plan.DerivedDirectory,
            new BakeStartParameters(target, plan.BakeProfile),
            cancellationToken));
    }

    private WorkspacePreviewPlan Prepare(PreviewStartParameters parameters, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        ValidateParameters(parameters);
        if (string.IsNullOrWhiteSpace(parameters.ConfigPath) || string.IsNullOrWhiteSpace(parameters.PackageRoot))
            throw new WorkspaceProjectValidationException(WorkspaceProjectValidationFailureKind.Validation, "Preview config path and package root must both be resolved.");

        var packageRoot = RequireDirectory(parameters.PackageRoot, "Package root");
        var configPath = RequireFileInside(packageRoot, parameters.ConfigPath, "Preview config");
        var configBytes = WorkspaceProjectValidator.ReadDocument(configPath, "Preview config", cancellationToken);
        var config = WorkspaceProjectValidator.ParsePreviewConfig(configBytes);
        var executablePath = RequireFileInside(packageRoot, ResolveRelative(packageRoot, config.Executable, "Preview executable"), "Preview executable");
        var workingDirectory = RequireDirectoryInside(packageRoot, ResolveRelative(packageRoot, config.WorkingDirectory, "Preview working directory"), "Preview working directory");
        var arguments = config.Arguments.ToList();
        if (arguments.Contains("--preview-status", StringComparer.Ordinal) || arguments.Contains("--preview-control", StringComparer.Ordinal))
            throw Validation("Preview config must not provide --preview-status or --preview-control.");
        var sceneIndex = FindDocumentArgument(arguments, "--scene");
        var scriptIndex = FindDocumentArgument(arguments, "--script");
        var sceneInput = ResolveInput(packageRoot, workingDirectory, arguments[sceneIndex + 1], "Scene input");
        var scriptInput = ResolveInput(packageRoot, workingDirectory, arguments[scriptIndex + 1], "Script input");

        string? sceneSource = null;
        string? scriptSource = null;
        string? derived = null;
        string? manifest = null;
        EditorBakeResult? initialBake = null;
        if (parameters.LiveBake)
        {
            sceneSource = RequireFileInside(packageRoot, sceneInput, "Scene source");
            scriptSource = RequireFileInside(packageRoot, scriptInput, "Script source");
            derived = ResolveDerivedDirectory(packageRoot, configPath, workingDirectory, parameters.DerivedDirectory);
            initialBake = _publicationModel.BakeResolvedCore(
                packageRoot,
                sceneSource,
                scriptSource,
                derived,
                new BakeStartParameters("Both", parameters.BakeProfile),
                cancellationToken);
            manifest = initialBake.ManifestPath;
            arguments[sceneIndex + 1] = Path.GetRelativePath(workingDirectory, Path.Combine(derived, "scene.scene")).Replace('\\', '/');
            arguments[scriptIndex + 1] = Path.GetRelativePath(workingDirectory, Path.Combine(derived, "script.script")).Replace('\\', '/');
        }
        else
        {
            _ = RequireFileInside(packageRoot, sceneInput, "Scene input");
            _ = RequireFileInside(packageRoot, scriptInput, "Script input");
        }

        arguments.Add("--preview-status");
        arguments.Add("jsonl-v1");
        arguments.Add("--preview-control");
        arguments.Add("jsonl-v1");
        return new WorkspacePreviewPlan(
            packageRoot,
            configPath,
            executablePath,
            workingDirectory,
            arguments.ToArray(),
            sceneInput,
            scriptInput,
            sceneSource,
            scriptSource,
            derived,
            manifest,
            parameters.LiveBake ? parameters.BakeProfile.ToLowerInvariant() : null,
            initialBake);
    }

    private static void ValidateParameters(PreviewStartParameters parameters)
    {
        if (parameters.StopAfterMilliseconds is < 0 or > 300000) throw Validation("StopAfterMilliseconds must be in 0..300000.");
        if (parameters.ReloadScriptAfterMilliseconds is < 0 or > 300000) throw Validation("ReloadScriptAfterMilliseconds must be in 0..300000.");
        if (parameters.ReloadScriptAfterMilliseconds > 0 && parameters.StopAfterMilliseconds > 0
            && parameters.ReloadScriptAfterMilliseconds >= parameters.StopAfterMilliseconds)
            throw Validation("ReloadScriptAfterMilliseconds must be less than StopAfterMilliseconds.");
        if (parameters.PollIntervalMilliseconds is < 25 or > 2000) throw Validation("PollIntervalMilliseconds must be in 25..2000.");
        if (parameters.DebounceMilliseconds is < 50 or > 5000) throw Validation("DebounceMilliseconds must be in 50..5000.");
        if (parameters.BakeProfile?.ToLowerInvariant() is not ("debug" or "release")) throw Validation("BakeProfile must be debug or release.");
    }

    private static int FindDocumentArgument(IReadOnlyList<string> arguments, string option)
    {
        var index = -1;
        for (var current = 0; current < arguments.Count; current++)
        {
            if (arguments[current] != option) continue;
            if (index >= 0) throw Validation($"Preview config contains duplicate {option}.");
            if (current + 1 >= arguments.Count || string.IsNullOrWhiteSpace(arguments[current + 1])) throw Validation($"Preview {option} requires a following path.");
            index = current;
            current++;
        }
        if (index < 0) throw Validation($"Preview config is missing {option}.");
        return index;
    }

    private static string ResolveInput(string packageRoot, string workingDirectory, string value, string name)
    {
        if (Path.IsPathRooted(value)) throw Validation($"{name} must be relative to the Runtime working directory.");
        return EnsureInside(packageRoot, Path.Combine(workingDirectory, value), name);
    }

    private static string ResolveDerivedDirectory(string packageRoot, string configPath, string workingDirectory, string? value)
    {
        var path = string.IsNullOrWhiteSpace(value)
            ? Path.Combine(Path.GetDirectoryName(configPath)!, ".kadath", "derived")
            : Path.IsPathRooted(value) ? value : Path.Combine(packageRoot, value);
        var fullPath = EnsureInside(packageRoot, path, "Preview derived directory");
        _ = EnsureInside(workingDirectory, fullPath, "Preview derived directory");
        if (IsSameOrInside(Path.Combine(packageRoot, "bin", "assets"), fullPath))
            throw Validation($"Preview derived directory must not be package/bin/assets: {fullPath}.");
        RejectExistingChain(packageRoot, fullPath, "Preview derived directory");
        return fullPath;
    }

    private static string ResolveRelative(string packageRoot, string value, string name)
    {
        if (Path.IsPathRooted(value)) throw Validation($"{name} must be relative to the package root.");
        return EnsureInside(packageRoot, Path.Combine(packageRoot, value), name);
    }

    private static string RequireFileInside(string packageRoot, string path, string name)
    {
        var fullPath = EnsureInside(packageRoot, path, name);
        RejectExistingChain(packageRoot, fullPath, name);
        if (!File.Exists(fullPath)) throw Validation($"{name} does not exist: {fullPath}.");
        WorkspaceProjectValidator.RejectReparsePoint(fullPath, name);
        return fullPath;
    }

    private static string RequireDirectoryInside(string packageRoot, string path, string name)
    {
        var fullPath = EnsureInside(packageRoot, path, name);
        RejectExistingChain(packageRoot, fullPath, name);
        if (!Directory.Exists(fullPath)) throw Validation($"{name} does not exist: {fullPath}.");
        WorkspaceProjectValidator.RejectReparsePoint(fullPath, name);
        return fullPath;
    }

    private static string RequireDirectory(string path, string name)
    {
        var fullPath = Path.GetFullPath(path);
        if (!Directory.Exists(fullPath)) throw Validation($"{name} does not exist: {fullPath}.");
        WorkspaceProjectValidator.RejectReparsePoint(fullPath, name);
        return fullPath;
    }

    private static string EnsureInside(string root, string path, string name)
    {
        var fullRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var fullPath = Path.GetFullPath(path);
        if (!IsSameOrInside(fullRoot, fullPath)) throw Validation($"{name} escapes package root: {path}.");
        return fullPath;
    }

    private static bool IsSameOrInside(string root, string path)
    {
        var fullRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var fullPath = Path.GetFullPath(path);
        return fullPath.Equals(fullRoot, PathComparison)
            || fullPath.StartsWith(fullRoot + Path.DirectorySeparatorChar, PathComparison);
    }

    private static void RejectExistingChain(string root, string path, string name)
    {
        WorkspaceProjectValidator.RejectReparsePoint(root, "Package root");
        var current = Path.GetFullPath(root);
        foreach (var segment in Path.GetRelativePath(root, path).Split([Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar], StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, segment);
            if (Directory.Exists(current) || File.Exists(current)) WorkspaceProjectValidator.RejectReparsePoint(current, name);
            else break;
        }
    }

    private static WorkspaceProjectValidationException Validation(string message, Exception? inner = null) =>
        new(WorkspaceProjectValidationFailureKind.Validation, message, inner);
}
