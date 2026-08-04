using System.Security.Cryptography;
using System.Text.Json;
using Kadath.Editor.Protocol;

namespace Kadath.Editor.Workspace;

public enum WorkspacePublicationFailureKind
{
    InvalidTarget,
    InvalidProfile,
    Validation,
    SourceChanged,
    Promote,
    Invariant
}

public sealed class WorkspacePublicationException : Exception
{
    public WorkspacePublicationException(WorkspacePublicationFailureKind kind, string message, Exception? innerException = null)
        : base(message, innerException) => Kind = kind;

    public WorkspacePublicationFailureKind Kind { get; }
}

internal enum WorkspacePublicationPhase
{
    AfterStaging,
    BeforeScenePromote,
    BeforeScriptPromote,
    BeforeManifestPromote,
    BeforeRollback
}

public sealed class WorkspacePublicationModel
{
    private static readonly JsonSerializerOptions ManifestJsonOptions = new(EditorProtocol.JsonOptions) { WriteIndented = true };
    private static readonly StringComparison PathComparison = OperatingSystem.IsWindows()
        ? StringComparison.OrdinalIgnoreCase
        : StringComparison.Ordinal;
    private readonly Action<WorkspacePublicationPhase>? _phase;

    public WorkspacePublicationModel() { }

    internal WorkspacePublicationModel(Action<WorkspacePublicationPhase>? phase) => _phase = phase;

    public Task<EditorBakeResult> BakeAsync(
        ProjectSessionInfo project,
        BakeStartParameters parameters,
        CancellationToken cancellationToken) =>
        Task.FromResult(Execute(() => BakeCore(project, parameters, cancellationToken), cancellationToken));

    private EditorBakeResult BakeCore(ProjectSessionInfo project, BakeStartParameters parameters, CancellationToken cancellationToken)
    {
        var target = NormalizeTarget(parameters.Target);
        var profile = NormalizeProfile(parameters.Profile);
        var paths = WorkspaceProjectValidator.ResolveOpenPaths(project);
        var kadathDirectory = Path.Combine(paths.ProjectDirectory, ".kadath");
        var derivedDirectory = Path.Combine(kadathDirectory, "derived");
        ValidateOutputDirectory(kadathDirectory, "Project metadata directory");
        ValidateOutputDirectory(derivedDirectory, "Derived directory");
        var sceneArtifactPath = Path.Combine(derivedDirectory, "scene.scene");
        var scriptArtifactPath = Path.Combine(derivedDirectory, "script.script");
        var manifestPath = Path.Combine(derivedDirectory, ".live-bake.manifest.json");

        var bakeScene = target is "Scene" or "Both";
        var bakeScript = target is "Script" or "Both";
        byte[]? sceneSource = null;
        byte[]? scriptSource = null;
        byte[]? sceneArtifact = null;
        byte[]? scriptArtifact = null;
        ManifestEntry sceneEntry;
        ManifestEntry scriptEntry;

        if (bakeScene)
        {
            sceneSource = WorkspaceProjectValidator.ReadDocument(paths.ScenePath, "Scene", cancellationToken);
            sceneArtifact = WorkspaceSceneCodec.EncodeSource(sceneSource);
            var info = WorkspaceSceneCodec.ValidateArtifact(sceneArtifact);
            sceneEntry = Entry("Scene", paths.PackageRoot, paths.ScenePath, sceneSource, sceneArtifactPath, info);
        }
        else
        {
            sceneEntry = ReadRetainedEntry(manifestPath, "scene", "Scene", paths.PackageRoot, paths.ScenePath, sceneArtifactPath);
        }

        if (bakeScript)
        {
            scriptSource = WorkspaceProjectValidator.ReadDocument(paths.ScriptPath, "Script", cancellationToken);
            scriptArtifact = WorkspaceScriptCodec.EncodeSource(scriptSource);
            var info = WorkspaceScriptCodec.ValidateArtifact(scriptArtifact);
            scriptEntry = Entry("Script", paths.PackageRoot, paths.ScriptPath, scriptSource, scriptArtifactPath, info);
        }
        else
        {
            scriptEntry = ReadRetainedEntry(manifestPath, "script", "Script", paths.PackageRoot, paths.ScriptPath, scriptArtifactPath);
        }

        EnsureOutputDirectory(kadathDirectory, "Project metadata directory");
        EnsureOutputDirectory(derivedDirectory, "Derived directory");
        var manifestBytes = JsonSerializer.SerializeToUtf8Bytes(new ManifestDocument(1, profile, 1, sceneEntry, scriptEntry), ManifestJsonOptions);
        var transactions = new List<TransactionEntry>();
        try
        {
            if (bakeScene) transactions.Add(Stage(sceneArtifactPath, sceneArtifact!, WorkspacePublicationPhase.BeforeScenePromote));
            if (bakeScript) transactions.Add(Stage(scriptArtifactPath, scriptArtifact!, WorkspacePublicationPhase.BeforeScriptPromote));
            transactions.Add(Stage(manifestPath, manifestBytes, WorkspacePublicationPhase.BeforeManifestPromote));
            _phase?.Invoke(WorkspacePublicationPhase.AfterStaging);
            cancellationToken.ThrowIfCancellationRequested();
            if (bakeScene && !Sha256(sceneSource!).Equals(Sha256(WorkspaceProjectValidator.ReadDocument(paths.ScenePath, "Scene", cancellationToken)), StringComparison.Ordinal))
                throw Failure(WorkspacePublicationFailureKind.SourceChanged, "Scene source changed during bake.");
            if (bakeScript && !Sha256(scriptSource!).Equals(Sha256(WorkspaceProjectValidator.ReadDocument(paths.ScriptPath, "Script", cancellationToken)), StringComparison.Ordinal))
                throw Failure(WorkspacePublicationFailureKind.SourceChanged, "Script source changed during bake.");
            cancellationToken.ThrowIfCancellationRequested();
            Commit(transactions);
        }
        finally
        {
            foreach (var transaction in transactions)
            {
                DeleteTemporary(transaction.StagedPath);
                if (transaction.RecoveryPath is not null) DeleteTemporary(transaction.RecoveryPath);
            }
        }

        return new EditorBakeResult(
            "succeeded",
            target,
            profile,
            derivedDirectory,
            manifestPath,
            sceneEntry.SourceSha256,
            scriptEntry.SourceSha256,
            sceneEntry.ArtifactSha256,
            scriptEntry.ArtifactSha256,
            checked((int)sceneEntry.ArtifactBytes),
            checked((int)scriptEntry.ArtifactBytes));
    }

    private void Commit(IReadOnlyList<TransactionEntry> transactions)
    {
        var committedCount = 0;
        var attemptedIndex = -1;
        try
        {
            for (var index = 0; index < transactions.Count; index++)
            {
                attemptedIndex = index;
                _phase?.Invoke(transactions[index].Phase);
                if (!MatchesOriginal(transactions[index])) throw new IOException($"Publication target changed while staged: {transactions[index].TargetPath}.");
                File.Move(transactions[index].StagedPath, transactions[index].TargetPath, true);
                committedCount++;
            }
        }
        catch (Exception commitException)
        {
            var rollbackFailures = new List<Exception>();
            try { _phase?.Invoke(WorkspacePublicationPhase.BeforeRollback); }
            catch (Exception exception) { rollbackFailures.Add(exception); }
            rollbackFailures.AddRange(Rollback(transactions, committedCount, attemptedIndex));
            if (rollbackFailures.Count > 0)
            {
                throw Failure(WorkspacePublicationFailureKind.Invariant,
                    $"Publication commit failed: {commitException.Message}; rollback failed: {string.Join(" | ", rollbackFailures.Select(value => value.Message))}",
                    new AggregateException(new[] { commitException }.Concat(rollbackFailures)));
            }
            throw Failure(WorkspacePublicationFailureKind.Promote,
                $"Publication commit failed and the previous artifacts were restored: {commitException.Message}", commitException);
        }
    }

    private static List<Exception> Rollback(IReadOnlyList<TransactionEntry> transactions, int committedCount, int attemptedIndex)
    {
        var failures = new List<Exception>();
        for (var index = transactions.Count - 1; index >= 0; index--)
        {
            var transaction = transactions[index];
            var committed = index < committedCount;
            var needsRestore = false;
            if (committed)
            {
                try
                {
                    if (!File.Exists(transaction.TargetPath))
                    {
                        if (transaction.OriginalExists) failures.Add(new IOException($"Committed publication target disappeared before rollback: {transaction.TargetPath}."));
                        continue;
                    }
                    WorkspaceProjectValidator.RejectReparsePoint(transaction.TargetPath, "Publication rollback target");
                    if (!File.ReadAllBytes(transaction.TargetPath).AsSpan().SequenceEqual(transaction.Intended))
                    {
                        failures.Add(new IOException($"Committed publication target changed ownership before rollback: {transaction.TargetPath}."));
                        continue;
                    }
                    needsRestore = true;
                }
                catch (Exception exception) { failures.Add(exception); continue; }
            }
            else if (index == attemptedIndex)
            {
                try { needsRestore = File.Exists(transaction.TargetPath) && File.ReadAllBytes(transaction.TargetPath).AsSpan().SequenceEqual(transaction.Intended); }
                catch (Exception exception) { failures.Add(exception); continue; }
            }
            if (!needsRestore) continue;
            try
            {
                if (transaction.OriginalExists) File.Move(transaction.RecoveryPath!, transaction.TargetPath, true);
                else if (File.Exists(transaction.TargetPath)) File.Delete(transaction.TargetPath);
            }
            catch (Exception exception) { failures.Add(exception); }
        }
        return failures;
    }

    private static TransactionEntry Stage(string targetPath, byte[] intended, WorkspacePublicationPhase phase)
    {
        var token = Guid.NewGuid().ToString("N");
        var stagedPath = $"{targetPath}.publication.{token}.stage";
        var recoveryPath = $"{targetPath}.publication.{token}.recovery";
        var originalExists = File.Exists(targetPath);
        byte[]? original = null;
        try
        {
            if (Directory.Exists(targetPath)) throw new IOException($"Publication target is a directory: {targetPath}.");
            if (originalExists)
            {
                WorkspaceProjectValidator.RejectReparsePoint(targetPath, "Publication target");
                original = File.ReadAllBytes(targetPath);
                WriteNewFile(recoveryPath, original);
            }
            WriteNewFile(stagedPath, intended);
            return new TransactionEntry(targetPath, stagedPath, originalExists ? recoveryPath : null, originalExists, original, intended, phase);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            DeleteTemporary(stagedPath);
            DeleteTemporary(recoveryPath);
            throw Failure(WorkspacePublicationFailureKind.Promote, $"Failed to stage publication target {targetPath}: {exception.Message}", exception);
        }
    }

    private static ManifestEntry ReadRetainedEntry(
        string manifestPath,
        string propertyName,
        string kind,
        string packageRoot,
        string sourcePath,
        string artifactPath)
    {
        if (!File.Exists(manifestPath)) throw Failure(WorkspacePublicationFailureKind.Validation, $"{kind} retained publication requires an existing manifest.");
        WorkspaceProjectValidator.RejectReparsePoint(manifestPath, "Live-bake manifest");
        using var document = JsonDocument.Parse(File.ReadAllBytes(manifestPath));
        var root = document.RootElement;
        if (root.GetProperty("schemaVersion").GetInt32() != 1) throw new InvalidDataException("Unsupported live-bake manifest schema.");
        if (root.GetProperty("adapterVersion").GetInt32() != 1) throw new InvalidDataException("Unsupported live-bake manifest adapter version.");
        if (root.GetProperty("profile").GetString() is not ("debug" or "release")) throw new InvalidDataException("Unsupported live-bake manifest profile.");
        var value = root.GetProperty(propertyName);
        var entry = new ManifestEntry(
            value.GetProperty("kind").GetString()!,
            value.GetProperty("sourcePath").GetString()!,
            value.GetProperty("sourceSha256").GetString()!,
            value.GetProperty("artifactPath").GetString()!,
            value.GetProperty("artifactSha256").GetString()!,
            value.GetProperty("artifactBytes").GetInt64(),
            value.GetProperty("artifactFormat").GetString()!,
            value.GetProperty("importerVersion").GetInt32(),
            value.GetProperty("bakerVersion").GetInt32());
        var expectedSourcePath = Relative(packageRoot, sourcePath);
        var expectedArtifactPath = Relative(packageRoot, artifactPath);
        if (!entry.Kind.Equals(kind, StringComparison.Ordinal) || !entry.SourcePath.Equals(expectedSourcePath, PathComparison)
            || !entry.ArtifactPath.Equals(expectedArtifactPath, PathComparison) || !IsSha256(entry.SourceSha256) || !IsSha256(entry.ArtifactSha256))
            throw new InvalidDataException($"{kind} retained manifest entry does not match the current project.");
        if (!File.Exists(artifactPath)) throw new InvalidDataException($"{kind} retained artifact does not exist.");
        WorkspaceProjectValidator.RejectReparsePoint(artifactPath, $"{kind} retained artifact");
        var bytes = File.ReadAllBytes(artifactPath);
        var info = kind == "Scene" ? WorkspaceSceneCodec.ValidateArtifact(bytes) : WorkspaceScriptCodec.ValidateArtifact(bytes);
        if (!entry.ArtifactSha256.Equals(info.Sha256, StringComparison.OrdinalIgnoreCase) || entry.ArtifactBytes != info.Bytes
            || entry.ArtifactFormat != info.Format || entry.ImporterVersion != info.ImporterVersion || entry.BakerVersion != info.BakerVersion)
            throw new InvalidDataException($"{kind} retained artifact identity does not match the manifest.");
        return entry;
    }

    private static ManifestEntry Entry(string kind, string packageRoot, string sourcePath, byte[] source, string artifactPath, WorkspaceArtifactInfo artifact) =>
        new(kind, Relative(packageRoot, sourcePath), Sha256(source), Relative(packageRoot, artifactPath), artifact.Sha256, artifact.Bytes,
            artifact.Format, artifact.ImporterVersion, artifact.BakerVersion);

    private static void EnsureOutputDirectory(string path, string name)
    {
        if (File.Exists(path)) throw Failure(WorkspacePublicationFailureKind.Validation, $"{name} is a file: {path}.");
        Directory.CreateDirectory(path);
        WorkspaceProjectValidator.RejectReparsePoint(path, name);
    }

    private static void ValidateOutputDirectory(string path, string name)
    {
        if (File.Exists(path)) throw Failure(WorkspacePublicationFailureKind.Validation, $"{name} is a file: {path}.");
        if (Directory.Exists(path)) WorkspaceProjectValidator.RejectReparsePoint(path, name);
    }

    private static string NormalizeTarget(string target) => target?.ToLowerInvariant() switch
    {
        "scene" => "Scene",
        "script" => "Script",
        "both" => "Both",
        _ => throw Failure(WorkspacePublicationFailureKind.InvalidTarget, $"Unsupported bake target: {target}.")
    };

    private static string NormalizeProfile(string profile) => profile?.ToLowerInvariant() switch
    {
        "debug" => "debug",
        "release" => "release",
        _ => throw Failure(WorkspacePublicationFailureKind.InvalidProfile, $"Unsupported bake profile: {profile}.")
    };

    private static T Execute<T>(Func<T> operation, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        try { return operation(); }
        catch (OperationCanceledException) { throw; }
        catch (WorkspacePublicationException) { throw; }
        catch (WorkspaceProjectValidationException exception) { throw Failure(WorkspacePublicationFailureKind.Validation, exception.Message, exception); }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException or InvalidDataException or FormatException or OverflowException or ArgumentException)
        {
            throw Failure(WorkspacePublicationFailureKind.Validation, exception.Message, exception);
        }
    }

    private static void WriteNewFile(string path, byte[] bytes)
    {
        using var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough);
        stream.Write(bytes);
        stream.Flush(true);
    }

    private static void DeleteTemporary(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); }
        catch { }
    }

    private static bool MatchesOriginal(TransactionEntry transaction)
    {
        try
        {
            if (!transaction.OriginalExists) return !File.Exists(transaction.TargetPath) && !Directory.Exists(transaction.TargetPath);
            if (!File.Exists(transaction.TargetPath)) return false;
            WorkspaceProjectValidator.RejectReparsePoint(transaction.TargetPath, "Publication target");
            return File.ReadAllBytes(transaction.TargetPath).AsSpan().SequenceEqual(transaction.Original);
        }
        catch { return false; }
    }

    private static string Sha256(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
    private static bool IsSha256(string value) => value.Length == 64 && value.All(Uri.IsHexDigit);
    private static string Relative(string root, string path) => Path.GetRelativePath(root, path).Replace('\\', '/');
    private static WorkspacePublicationException Failure(WorkspacePublicationFailureKind kind, string message, Exception? innerException = null) => new(kind, message, innerException);

    private sealed record ManifestDocument(int SchemaVersion, string Profile, int AdapterVersion, ManifestEntry Scene, ManifestEntry Script);
    private sealed record ManifestEntry(
        string Kind,
        string SourcePath,
        string SourceSha256,
        string ArtifactPath,
        string ArtifactSha256,
        long ArtifactBytes,
        string ArtifactFormat,
        int ImporterVersion,
        int BakerVersion);
    private sealed record TransactionEntry(
        string TargetPath,
        string StagedPath,
        string? RecoveryPath,
        bool OriginalExists,
        byte[]? Original,
        byte[] Intended,
        WorkspacePublicationPhase Phase);
}
