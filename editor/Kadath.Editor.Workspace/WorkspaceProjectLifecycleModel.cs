using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Kadath.Editor.Protocol;

namespace Kadath.Editor.Workspace;

public enum WorkspaceProjectLifecycleFailureKind
{
    InvalidProjectName,
    PackageNotFound,
    PathEscape,
    ProjectFileMissing,
    AlreadyExists,
    Validation,
    Create,
    Invariant
}

public sealed class WorkspaceProjectLifecycleException : Exception
{
    public WorkspaceProjectLifecycleException(WorkspaceProjectLifecycleFailureKind kind, string message, Exception? innerException = null)
        : base(message, innerException) => Kind = kind;

    public WorkspaceProjectLifecycleFailureKind Kind { get; }
}

internal enum WorkspaceProjectCreatePhase
{
    BeforeOwnership,
    AfterClaim,
    AfterScene,
    AfterScript,
    AfterPreview,
    BeforeValidation,
    BeforeCommit
}

internal enum WorkspaceProjectCleanupPhase
{
    BeforeOwnedFileQuarantine,
    BeforeClaimQuarantine
}

public sealed class WorkspaceProjectLifecycleModel
{
    private const string ClaimFileName = ".kadath-create-claim";
    private static readonly JsonSerializerOptions PreviewJsonOptions = new(EditorProtocol.JsonOptions) { WriteIndented = true };
    private readonly Action<WorkspaceProjectCreatePhase>? _createPhase;
    private readonly Action<WorkspaceProjectCleanupPhase, string>? _cleanupPhase;

    public WorkspaceProjectLifecycleModel() { }

    internal WorkspaceProjectLifecycleModel(Action<WorkspaceProjectCreatePhase>? createPhase)
        : this(createPhase, null) { }

    internal WorkspaceProjectLifecycleModel(
        Action<WorkspaceProjectCreatePhase>? createPhase,
        Action<WorkspaceProjectCleanupPhase, string>? cleanupPhase)
    {
        _createPhase = createPhase;
        _cleanupPhase = cleanupPhase;
    }

    public Task<ProjectSessionInfo> OpenAsync(ProjectOpenParameters parameters, CancellationToken cancellationToken) =>
        Task.FromResult(ExecuteOpen(() => OpenCore(parameters, cancellationToken), cancellationToken));

    public Task<ProjectSessionInfo> CreateAsync(ProjectCreateParameters parameters, CancellationToken cancellationToken) =>
        Task.FromResult(ExecuteCreate(() => CreateCore(parameters, cancellationToken), cancellationToken));

    public Task<ProjectValidateResult> ValidateAsync(ProjectSessionInfo project, CancellationToken cancellationToken) =>
        Task.FromResult(ExecuteValidate(() => ValidateCore(project, cancellationToken), cancellationToken));

    private static ProjectSessionInfo OpenCore(ProjectOpenParameters parameters, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        WorkspaceProjectValidator.ValidateProjectName(parameters.ProjectName);
        var paths = WorkspaceProjectValidator.ResolvePaths(parameters.PackageRoot, parameters.ProjectName, requireProjectsDirectory: true);
        var project = Session(paths, parameters.ProjectName);
        _ = WorkspaceProjectValidator.ReadAndValidate(project, cancellationToken);
        return project;
    }

    private ProjectSessionInfo CreateCore(ProjectCreateParameters parameters, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        WorkspaceProjectValidator.ValidateProjectName(parameters.ProjectName);
        var paths = WorkspaceProjectValidator.ResolvePaths(parameters.PackageRoot, parameters.ProjectName, requireProjectsDirectory: false);
        var sceneTemplatePath = WorkspaceProjectValidator.ResolveRequiredFile(paths.PackageRoot, "bin/assets/scenes/preview.scene.json", "Scene template");
        var scriptTemplatePath = WorkspaceProjectValidator.ResolveRequiredFile(paths.PackageRoot, "bin/assets/scripts/preview.script.json", "Script template");
        var sceneBytes = WorkspaceProjectValidator.ReadDocument(sceneTemplatePath, "Scene template", cancellationToken);
        var scriptBytes = WorkspaceProjectValidator.ReadDocument(scriptTemplatePath, "Script template", cancellationToken);
        var previewBytes = CreatePreview(parameters.ProjectName);
        WorkspaceProjectValidator.ValidateCreateInputs(sceneBytes, scriptBytes, previewBytes, paths, cancellationToken);

        if (Directory.Exists(paths.ProjectDirectory) || File.Exists(paths.ProjectDirectory)) throw Failure(WorkspaceProjectLifecycleFailureKind.AlreadyExists, $"Project already exists: {parameters.ProjectName}.");
        Directory.CreateDirectory(paths.ProjectsDirectory);
        WorkspaceProjectValidator.RejectReparsePoint(paths.ProjectsDirectory, "Projects directory");
        cancellationToken.ThrowIfCancellationRequested();

        var token = Guid.NewGuid().ToString("N");
        var claimPath = Path.Combine(paths.ProjectDirectory, ClaimFileName);
        var createdFiles = new List<CreatedFile>();
        FileStream? claimStream = null;
        CreatedFile? claimFile = null;
        try
        {
            InvokePhase(WorkspaceProjectCreatePhase.BeforeOwnership, cancellationToken);
            try
            {
                Directory.CreateDirectory(paths.ProjectDirectory);
            }
            catch (IOException exception)
            {
                throw ClassifyOwnershipFailure(paths.ProjectDirectory, parameters.ProjectName, exception);
            }

            WorkspaceProjectValidator.RejectReparsePoint(paths.ProjectDirectory, "Project directory");
            try
            {
                claimStream = new FileStream(claimPath, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None);
            }
            catch (IOException exception)
            {
                throw ClassifyOwnershipFailure(claimPath, parameters.ProjectName, exception);
            }

            var tokenBytes = Encoding.UTF8.GetBytes(token);
            claimStream.Write(tokenBytes);
            claimStream.Flush(flushToDisk: true);
            claimFile = new CreatedFile(claimPath, tokenBytes.LongLength, Hash(tokenBytes));
            InvokePhase(WorkspaceProjectCreatePhase.AfterClaim, cancellationToken);

            createdFiles.Add(CreateFile(paths.ScenePath, sceneBytes));
            InvokePhase(WorkspaceProjectCreatePhase.AfterScene, cancellationToken);
            createdFiles.Add(CreateFile(paths.ScriptPath, scriptBytes));
            InvokePhase(WorkspaceProjectCreatePhase.AfterScript, cancellationToken);
            createdFiles.Add(CreateFile(paths.PreviewPath, previewBytes));
            InvokePhase(WorkspaceProjectCreatePhase.AfterPreview, cancellationToken);
            InvokePhase(WorkspaceProjectCreatePhase.BeforeValidation, cancellationToken);

            var project = Session(paths, parameters.ProjectName);
            _ = WorkspaceProjectValidator.ReadAndValidate(project, cancellationToken);
            foreach (var createdFile in createdFiles) RequireIdentity(createdFile);
            InvokePhase(WorkspaceProjectCreatePhase.BeforeCommit, cancellationToken);

            claimStream.Dispose();
            claimStream = null;
            if (!TryRemoveOwnedFile(claimFile, WorkspaceProjectCleanupPhase.BeforeClaimQuarantine))
            {
                throw Failure(WorkspaceProjectLifecycleFailureKind.Invariant, "Project create ownership claim does not match this invocation.");
            }
            return project;
        }
        catch
        {
            claimStream?.Dispose();
            Cleanup(paths.ProjectDirectory, claimFile, createdFiles);
            throw;
        }
    }

    private static ProjectValidateResult ValidateCore(ProjectSessionInfo project, CancellationToken cancellationToken)
    {
        var bytes = WorkspaceProjectValidator.ReadAndValidate(project, cancellationToken);
        return new ProjectValidateResult("valid", project.ProjectName,
        [
            "validation_engine=native",
            $"project_directory={bytes.ProjectDirectory}",
            "validation=ok"
        ]);
    }

    private void InvokePhase(WorkspaceProjectCreatePhase phase, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        _createPhase?.Invoke(phase);
        cancellationToken.ThrowIfCancellationRequested();
    }

    private static byte[] CreatePreview(string projectName)
    {
        var executable = OperatingSystem.IsWindows() ? "bin/kadath.exe" : "bin/kadath";
        var preview = new
        {
            schemaVersion = 1,
            runtime = new
            {
                executable,
                workingDirectory = "bin",
                arguments = new[] { "--scene", $"projects/{projectName}/scene.json", "--script", $"projects/{projectName}/script.json" }
            }
        };
        return JsonSerializer.SerializeToUtf8Bytes(preview, PreviewJsonOptions);
    }

    private static CreatedFile CreateFile(string path, byte[] bytes)
    {
        using var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        stream.Write(bytes);
        stream.Flush(flushToDisk: true);
        return new CreatedFile(path, bytes.LongLength, Hash(bytes));
    }

    private static void RequireIdentity(CreatedFile file)
    {
        if (!MatchesIdentity(file)) throw Failure(WorkspaceProjectLifecycleFailureKind.Invariant, $"Created project file identity changed: {file.Path}.");
    }

    private static bool MatchesIdentity(CreatedFile file)
    {
        try
        {
            if (!File.Exists(file.Path)) return false;
            WorkspaceProjectValidator.RejectReparsePoint(file.Path, "Created project file");
            var bytes = File.ReadAllBytes(file.Path);
            return bytes.LongLength == file.Length && Hash(bytes).Equals(file.Sha256, StringComparison.Ordinal);
        }
        catch
        {
            return false;
        }
    }

    private FileStream? TryOpenMatchingClaim(CreatedFile claimFile)
    {
        try
        {
            if (!MatchesIdentity(claimFile)) return null;
            var stream = new FileStream(claimFile.Path, FileMode.Open, FileAccess.Read, FileShare.Read);
            try
            {
                var bytes = new byte[claimFile.Length];
                var offset = 0;
                while (offset < bytes.Length)
                {
                    var read = stream.Read(bytes, offset, bytes.Length - offset);
                    if (read == 0) break;
                    offset += read;
                }
                if (offset != bytes.Length || stream.ReadByte() != -1 || !Hash(bytes).Equals(claimFile.Sha256, StringComparison.Ordinal))
                {
                    stream.Dispose();
                    return null;
                }
                return stream;
            }
            catch
            {
                stream.Dispose();
                return null;
            }
        }
        catch
        {
            return null;
        }
    }

    private void Cleanup(string projectDirectory, CreatedFile? claimFile, IEnumerable<CreatedFile> createdFiles)
    {
        if (claimFile is null) return;

        using (var claimStream = TryOpenMatchingClaim(claimFile))
        {
            if (claimStream is null) return;
            foreach (var file in createdFiles.Reverse())
            {
                if (!MatchesIdentity(claimFile)) return;
                _ = TryRemoveOwnedFile(file, WorkspaceProjectCleanupPhase.BeforeOwnedFileQuarantine);
                if (!MatchesIdentity(claimFile)) return;
            }
        }

        if (!TryRemoveOwnedFile(claimFile, WorkspaceProjectCleanupPhase.BeforeClaimQuarantine)) return;

        try
        {
            if (Directory.Exists(projectDirectory))
            {
                WorkspaceProjectValidator.RejectReparsePoint(projectDirectory, "Project directory");
                if (!Directory.EnumerateFileSystemEntries(projectDirectory).Any()) Directory.Delete(projectDirectory, recursive: false);
            }
        }
        catch { }
    }

    private static WorkspaceProjectLifecycleException ClassifyOwnershipFailure(string collisionPath, string projectName, IOException exception)
    {
        if (Directory.Exists(collisionPath) || File.Exists(collisionPath))
        {
            return Failure(WorkspaceProjectLifecycleFailureKind.AlreadyExists, $"Project create ownership was lost: {projectName}.", exception);
        }
        return Failure(WorkspaceProjectLifecycleFailureKind.Create, $"Project create ownership could not be acquired: {projectName}.", exception);
    }

    private bool TryRemoveOwnedFile(CreatedFile file, WorkspaceProjectCleanupPhase phase)
    {
        if (!MatchesIdentity(file)) return false;
        try
        {
            _cleanupPhase?.Invoke(phase, file.Path);
        }
        catch
        {
            return false;
        }

        var quarantinePath = $"{file.Path}.kadath-delete.{Guid.NewGuid():N}";
        try
        {
            File.Move(file.Path, quarantinePath);
        }
        catch
        {
            return false;
        }

        var quarantinedFile = file with { Path = quarantinePath };
        if (!MatchesIdentity(quarantinedFile))
        {
            TryRestoreQuarantinedFile(quarantinePath, file.Path);
            return false;
        }

        try
        {
            File.Delete(quarantinePath);
            return true;
        }
        catch
        {
            return false;
        }
    }

    private static void TryRestoreQuarantinedFile(string quarantinePath, string originalPath)
    {
        try
        {
            if (!File.Exists(originalPath) && !Directory.Exists(originalPath)) File.Move(quarantinePath, originalPath);
        }
        catch { }
    }

    private static ProjectSessionInfo Session(WorkspaceProjectPaths paths, string projectName) =>
        new(paths.PackageRoot, projectName, paths.ProjectDirectory, paths.ScenePath, paths.ScriptPath, paths.PreviewPath, 1);

    private static T ExecuteOpen<T>(Func<T> operation, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        try { return operation(); }
        catch (OperationCanceledException) { throw; }
        catch (WorkspaceProjectLifecycleException) { throw; }
        catch (WorkspaceProjectValidationException exception) { throw ClassifyValidation(exception); }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException or FormatException or OverflowException or ArgumentException)
        {
            throw Failure(WorkspaceProjectLifecycleFailureKind.Validation, exception.Message, exception);
        }
    }

    private static T ExecuteCreate<T>(Func<T> operation, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        try { return operation(); }
        catch (OperationCanceledException) { throw; }
        catch (WorkspaceProjectLifecycleException) { throw; }
        catch (WorkspaceProjectValidationException exception) { throw ClassifyValidation(exception); }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException or FormatException or OverflowException or ArgumentException)
        {
            throw Failure(WorkspaceProjectLifecycleFailureKind.Create, exception.Message, exception);
        }
    }

    private static T ExecuteValidate<T>(Func<T> operation, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        try { return operation(); }
        catch (OperationCanceledException) { throw; }
        catch (WorkspaceProjectLifecycleException exception)
        {
            throw exception.Kind == WorkspaceProjectLifecycleFailureKind.Validation
                ? exception
                : Failure(WorkspaceProjectLifecycleFailureKind.Validation, exception.Message, exception);
        }
        catch (WorkspaceProjectValidationException exception)
        {
            throw Failure(WorkspaceProjectLifecycleFailureKind.Validation, exception.Message, exception);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException or FormatException or OverflowException or ArgumentException)
        {
            throw Failure(WorkspaceProjectLifecycleFailureKind.Validation, exception.Message, exception);
        }
    }

    private static WorkspaceProjectLifecycleException ClassifyValidation(WorkspaceProjectValidationException exception)
    {
        var kind = exception.Kind switch
        {
            WorkspaceProjectValidationFailureKind.InvalidProjectName => WorkspaceProjectLifecycleFailureKind.InvalidProjectName,
            WorkspaceProjectValidationFailureKind.PackageNotFound => WorkspaceProjectLifecycleFailureKind.PackageNotFound,
            WorkspaceProjectValidationFailureKind.PathEscape => WorkspaceProjectLifecycleFailureKind.PathEscape,
            WorkspaceProjectValidationFailureKind.ProjectFileMissing => WorkspaceProjectLifecycleFailureKind.ProjectFileMissing,
            WorkspaceProjectValidationFailureKind.Validation => WorkspaceProjectLifecycleFailureKind.Validation,
            _ => WorkspaceProjectLifecycleFailureKind.Validation
        };
        return Failure(kind, exception.Message, exception);
    }

    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
    private static WorkspaceProjectLifecycleException Failure(WorkspaceProjectLifecycleFailureKind kind, string message, Exception? innerException = null) => new(kind, message, innerException);
    private sealed record CreatedFile(string Path, long Length, string Sha256);
}
