using System.Text;
using Kadath.Editor.Protocol;

namespace Kadath.Editor.Workspace;

public enum WorkspaceScriptAssetLifecycleFailureKind
{
    InvalidExpectedRevision,
    Unsupported,
    InvalidPath,
    NotFound,
    Conflict,
    LimitReached,
    LastDependency,
    InUse,
    RevisionConflict,
    HistoryDiverged,
    Commit,
    Invariant,
    Input
}

public sealed class WorkspaceScriptAssetLifecycleException : Exception
{
    public WorkspaceScriptAssetLifecycleException(
        WorkspaceScriptAssetLifecycleFailureKind kind,
        string message,
        Exception? innerException = null)
        : base(message, innerException) => Kind = kind;

    public WorkspaceScriptAssetLifecycleFailureKind Kind { get; }
}

public sealed record WorkspaceScriptAssetIdentity(uint ScriptId, string SourcePath);

public sealed record WorkspaceScriptAssetLifecycleCommit(
    string State,
    string PreviousRevision,
    string Revision,
    string[] ChangedFields,
    WorkspaceScriptAssetLifecycleUndoToken? UndoToken,
    WorkspaceScriptAssetIdentity Asset,
    WorkspaceScriptSourceDocument? SourceDocument,
    ProjectModelSnapshot ProjectSnapshot,
    HierarchySnapshot HierarchySnapshot);

public sealed class WorkspaceScriptAssetLifecycleUndoToken
{
    internal WorkspaceScriptAssetLifecycleUndoToken(
        string projectName,
        string revisionAfter,
        string operation,
        uint scriptId,
        string? sourcePathBefore,
        string? sourcePathAfter,
        byte[] manifestBefore,
        byte[] manifestAfter,
        byte[] source)
    {
        ProjectName = projectName;
        RevisionAfter = revisionAfter;
        Operation = operation;
        ScriptId = scriptId;
        SourcePathBefore = sourcePathBefore;
        SourcePathAfter = sourcePathAfter;
        ManifestBefore = manifestBefore.ToArray();
        ManifestAfter = manifestAfter.ToArray();
        Source = source.ToArray();
    }

    internal string ProjectName { get; }
    internal string RevisionAfter { get; }
    internal string Operation { get; }
    internal uint ScriptId { get; }
    internal string? SourcePathBefore { get; }
    internal string? SourcePathAfter { get; }
    internal byte[] ManifestBefore { get; }
    internal byte[] ManifestAfter { get; }
    internal byte[] Source { get; }
}

internal enum WorkspaceScriptAssetLifecyclePhase
{
    CreateBeforeSourcePublish,
    CreateAfterSourcePublish,
    CreateAfterManifestPublish,
    RenameBeforeTargetPublish,
    RenameAfterTargetPublish,
    RenameAfterManifestPublish,
    RenameAfterOldSourceDelete,
    DeleteBeforeManifestPublish,
    DeleteAfterManifestPublish,
    DeleteAfterSourceDelete
}

public sealed class WorkspaceScriptAssetLifecycleModel
{
    private static readonly UTF8Encoding Utf8 = new(false, true);
    private static readonly byte[] DefaultSource = Utf8.GetBytes("""
        --!strict

        return {
            fixed_update = function(_self: Kadath.Object, _dt: number)
            end,
        }
        """);
    private readonly Action<WorkspaceScriptAssetLifecyclePhase>? _phase;

    public WorkspaceScriptAssetLifecycleModel() { }

    internal WorkspaceScriptAssetLifecycleModel(Action<WorkspaceScriptAssetLifecyclePhase>? phase) => _phase = phase;

    public Task<WorkspaceScriptAssetLifecycleCommit> CreateAsync(
        ProjectSessionInfo project,
        string expectedRevision,
        string sourcePath,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(Execute(() => CreateCore(project, expectedRevision, sourcePath, cancellationToken), cancellationToken));

    public Task<WorkspaceScriptAssetLifecycleCommit> RenameAsync(
        ProjectSessionInfo project,
        string expectedRevision,
        uint scriptId,
        string sourcePath,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(Execute(() => RenameCore(project, expectedRevision, scriptId, sourcePath, cancellationToken), cancellationToken));

    public Task<WorkspaceScriptAssetLifecycleCommit> DeleteAsync(
        ProjectSessionInfo project,
        string expectedRevision,
        uint scriptId,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(Execute(() => DeleteCore(project, expectedRevision, scriptId, cancellationToken), cancellationToken));

    public Task<WorkspaceScriptAssetLifecycleCommit> UndoAsync(
        ProjectSessionInfo project,
        string expectedRevision,
        WorkspaceScriptAssetLifecycleUndoToken token,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(Execute(() => UndoCore(project, expectedRevision, token, cancellationToken), cancellationToken));

    private WorkspaceScriptAssetLifecycleCommit CreateCore(
        ProjectSessionInfo project,
        string expectedRevision,
        string sourcePath,
        CancellationToken cancellationToken)
    {
        ValidateExpectedRevision(expectedRevision);
        var bytes = WorkspaceReadModel.ReadProjectBytes(project, cancellationToken);
        var projection = WorkspaceReadModel.ProjectSnapshotsFromBytes(project, bytes);
        var current = WorkspaceScriptSourceModel.Read(bytes.ScriptPath, cancellationToken);
        if (!current.IsBehaviorPackage) throw Failure(WorkspaceScriptAssetLifecycleFailureKind.Unsupported, "Script Asset lifecycle requires Script schema v2.");
        RequireRevision(expectedRevision, projection.Project.AuthoringRevision);
        if (current.Dependencies.Count >= WorkspaceScriptSourceModel.MaxScriptCount)
            throw Failure(WorkspaceScriptAssetLifecycleFailureKind.LimitReached, "Script Asset limit reached.");

        string targetPath;
        try { targetPath = WorkspaceScriptSourceModel.ResolveLifecycleSourcePath(bytes.ScriptPath, sourcePath); }
        catch (WorkspaceProjectValidationException exception)
        {
            throw Failure(WorkspaceScriptAssetLifecycleFailureKind.InvalidPath, exception.Message, exception);
        }
        if (current.Dependencies.Any(value => value.SourceName.Equals(sourcePath, StringComparison.OrdinalIgnoreCase))
            || HasPortablePathConflict(bytes.ScriptPath, sourcePath))
        {
            throw Failure(WorkspaceScriptAssetLifecycleFailureKind.Conflict, $"Script Asset source path already exists: {sourcePath}.");
        }

        var usedIds = current.Dependencies.Select(value => value.ScriptId).ToHashSet();
        uint scriptId = 1;
        while (usedIds.Contains(scriptId)) scriptId = checked(scriptId + 1);
        var manifest = WorkspaceScriptSourceModel.EncodeBehaviorManifest(
            current.Dependencies.Select(value => (value.ScriptId, value.SourceName)).Append((scriptId, sourcePath)));
        var sourceDirectory = Path.GetDirectoryName(targetPath)!;
        if (!Directory.Exists(sourceDirectory)) Directory.CreateDirectory(sourceDirectory);
        var sourceStage = $"{targetPath}.authoring.{Guid.NewGuid():N}.stage";
        var manifestStage = $"{bytes.ScriptPath}.authoring.{Guid.NewGuid():N}.stage";
        var sourcePublished = false;
        var manifestPublished = false;
        try
        {
            WriteNew(sourceStage, DefaultSource);
            WriteNew(manifestStage, manifest);
            RequireUnchanged(project, expectedRevision, current.Revision, cancellationToken);
            cancellationToken.ThrowIfCancellationRequested();
            _phase?.Invoke(WorkspaceScriptAssetLifecyclePhase.CreateBeforeSourcePublish);
            File.Move(sourceStage, targetPath, false);
            sourcePublished = true;
            _phase?.Invoke(WorkspaceScriptAssetLifecyclePhase.CreateAfterSourcePublish);
            File.Move(manifestStage, bytes.ScriptPath, true);
            manifestPublished = true;
            _phase?.Invoke(WorkspaceScriptAssetLifecyclePhase.CreateAfterManifestPublish);

            var committedBytes = WorkspaceReadModel.ReadProjectBytes(project, default);
            var committed = WorkspaceReadModel.ProjectSnapshotsFromBytes(project, committedBytes);
            RequireCommittedBytes(committedBytes.Script, manifest, "Manifest");
            var created = WorkspaceScriptSourceModel.Read(committedBytes.ScriptPath, default).Dependencies.Single(value => value.ScriptId == scriptId);
            RequireCommittedBytes(created.Source, DefaultSource, "source");
            var token = new WorkspaceScriptAssetLifecycleUndoToken(
                project.ProjectName,
                committed.Project.AuthoringRevision,
                "create",
                scriptId,
                null,
                sourcePath,
                bytes.Script,
                manifest,
                DefaultSource);
            return new WorkspaceScriptAssetLifecycleCommit(
                "succeeded",
                projection.Project.AuthoringRevision,
                committed.Project.AuthoringRevision,
                [$"script.assets[{scriptId}]"],
                token,
                new WorkspaceScriptAssetIdentity(scriptId, sourcePath),
                Document(project, created, committed.Project.AuthoringRevision),
                committed.Project,
                committed.Hierarchy);
        }
        catch
        {
            Compensate(
                () => { if (manifestPublished) RestoreOwned(bytes.ScriptPath, manifest, bytes.Script); },
                () => { if (sourcePublished) DeleteOwned(targetPath, DefaultSource); });
            throw;
        }
        finally
        {
            TryDelete(sourceStage);
            TryDelete(manifestStage);
        }
    }

    private WorkspaceScriptAssetLifecycleCommit RenameCore(
        ProjectSessionInfo project,
        string expectedRevision,
        uint scriptId,
        string sourcePath,
        CancellationToken cancellationToken)
    {
        ValidateExpectedRevision(expectedRevision);
        if (scriptId == 0) throw Failure(WorkspaceScriptAssetLifecycleFailureKind.NotFound, "ScriptId must be non-zero.");
        var bytes = WorkspaceReadModel.ReadProjectBytes(project, cancellationToken);
        var projection = WorkspaceReadModel.ProjectSnapshotsFromBytes(project, bytes);
        var current = WorkspaceScriptSourceModel.Read(bytes.ScriptPath, cancellationToken);
        if (!current.IsBehaviorPackage) throw Failure(WorkspaceScriptAssetLifecycleFailureKind.Unsupported, "Script Asset lifecycle requires Script schema v2.");
        RequireRevision(expectedRevision, projection.Project.AuthoringRevision);
        var dependency = current.Dependencies.SingleOrDefault(value => value.ScriptId == scriptId)
            ?? throw Failure(WorkspaceScriptAssetLifecycleFailureKind.NotFound, $"Script Asset {scriptId} does not exist.");
        if (dependency.SourceName.Equals(sourcePath, StringComparison.Ordinal))
        {
            return new WorkspaceScriptAssetLifecycleCommit(
                "unchanged",
                projection.Project.AuthoringRevision,
                projection.Project.AuthoringRevision,
                [],
                null,
                new WorkspaceScriptAssetIdentity(scriptId, sourcePath),
                Document(project, dependency, projection.Project.AuthoringRevision),
                projection.Project,
                projection.Hierarchy);
        }

        string targetPath;
        try { targetPath = WorkspaceScriptSourceModel.ResolveLifecycleSourcePath(bytes.ScriptPath, sourcePath); }
        catch (WorkspaceProjectValidationException exception)
        {
            throw Failure(WorkspaceScriptAssetLifecycleFailureKind.InvalidPath, exception.Message, exception);
        }
        if (dependency.SourceName.Equals(sourcePath, StringComparison.OrdinalIgnoreCase)
            || current.Dependencies.Any(value => value.ScriptId != scriptId && value.SourceName.Equals(sourcePath, StringComparison.OrdinalIgnoreCase))
            || HasPortablePathConflict(bytes.ScriptPath, sourcePath))
        {
            throw Failure(WorkspaceScriptAssetLifecycleFailureKind.Conflict, $"Script Asset source path already exists: {sourcePath}.");
        }

        var manifest = WorkspaceScriptSourceModel.EncodeBehaviorManifest(current.Dependencies.Select(value =>
            value.ScriptId == scriptId ? (value.ScriptId, sourcePath) : (value.ScriptId, value.SourceName)));
        var sourceDirectory = Path.GetDirectoryName(targetPath)!;
        if (!Directory.Exists(sourceDirectory)) Directory.CreateDirectory(sourceDirectory);
        var sourceStage = $"{targetPath}.authoring.{Guid.NewGuid():N}.stage";
        var manifestStage = $"{bytes.ScriptPath}.authoring.{Guid.NewGuid():N}.stage";
        var targetPublished = false;
        var manifestPublished = false;
        var oldDeleted = false;
        try
        {
            WriteNew(sourceStage, dependency.Source);
            WriteNew(manifestStage, manifest);
            RequireUnchanged(project, expectedRevision, current.Revision, cancellationToken);
            cancellationToken.ThrowIfCancellationRequested();
            _phase?.Invoke(WorkspaceScriptAssetLifecyclePhase.RenameBeforeTargetPublish);
            File.Move(sourceStage, targetPath, false);
            targetPublished = true;
            _phase?.Invoke(WorkspaceScriptAssetLifecyclePhase.RenameAfterTargetPublish);
            File.Move(manifestStage, bytes.ScriptPath, true);
            manifestPublished = true;
            _phase?.Invoke(WorkspaceScriptAssetLifecyclePhase.RenameAfterManifestPublish);
            DeleteOwned(dependency.FullPath, dependency.Source);
            oldDeleted = true;
            _phase?.Invoke(WorkspaceScriptAssetLifecyclePhase.RenameAfterOldSourceDelete);

            var committedBytes = WorkspaceReadModel.ReadProjectBytes(project, default);
            var committed = WorkspaceReadModel.ProjectSnapshotsFromBytes(project, committedBytes);
            RequireCommittedBytes(committedBytes.Script, manifest, "Manifest");
            var renamed = WorkspaceScriptSourceModel.Read(committedBytes.ScriptPath, default).Dependencies.Single(value => value.ScriptId == scriptId);
            RequireCommittedBytes(renamed.Source, dependency.Source, "source");
            RequireCommittedMissing(dependency.FullPath, "old source");
            var token = new WorkspaceScriptAssetLifecycleUndoToken(
                project.ProjectName,
                committed.Project.AuthoringRevision,
                "rename",
                scriptId,
                dependency.SourceName,
                sourcePath,
                bytes.Script,
                manifest,
                dependency.Source);
            return new WorkspaceScriptAssetLifecycleCommit(
                "succeeded",
                projection.Project.AuthoringRevision,
                committed.Project.AuthoringRevision,
                [$"script.assets[{scriptId}].source"],
                token,
                new WorkspaceScriptAssetIdentity(scriptId, sourcePath),
                Document(project, renamed, committed.Project.AuthoringRevision),
                committed.Project,
                committed.Hierarchy);
        }
        catch
        {
            Compensate(
                () => { if (oldDeleted) RestoreMissing(dependency.FullPath, dependency.Source); },
                () => { if (manifestPublished) RestoreOwned(bytes.ScriptPath, manifest, bytes.Script); },
                () => { if (targetPublished) DeleteOwned(targetPath, dependency.Source); });
            throw;
        }
        finally
        {
            TryDelete(sourceStage);
            TryDelete(manifestStage);
        }
    }

    private WorkspaceScriptAssetLifecycleCommit DeleteCore(
        ProjectSessionInfo project,
        string expectedRevision,
        uint scriptId,
        CancellationToken cancellationToken)
    {
        ValidateExpectedRevision(expectedRevision);
        if (scriptId == 0) throw Failure(WorkspaceScriptAssetLifecycleFailureKind.NotFound, "ScriptId must be non-zero.");
        var bytes = WorkspaceReadModel.ReadProjectBytes(project, cancellationToken);
        var projection = WorkspaceReadModel.ProjectSnapshotsFromBytes(project, bytes);
        var current = WorkspaceScriptSourceModel.Read(bytes.ScriptPath, cancellationToken);
        if (!current.IsBehaviorPackage) throw Failure(WorkspaceScriptAssetLifecycleFailureKind.Unsupported, "Script Asset lifecycle requires Script schema v2.");
        RequireRevision(expectedRevision, projection.Project.AuthoringRevision);
        var dependency = current.Dependencies.SingleOrDefault(value => value.ScriptId == scriptId)
            ?? throw Failure(WorkspaceScriptAssetLifecycleFailureKind.NotFound, $"Script Asset {scriptId} does not exist.");
        if (current.Dependencies.Count == 1)
            throw Failure(WorkspaceScriptAssetLifecycleFailureKind.LastDependency, "The last Script Asset cannot be deleted from Script schema v2.");
        var objectReferences = projection.Project.Scene.Objects?
            .Where(value => value.Behaviors?.Any(binding => binding.ScriptId == scriptId) == true)
            .Select(value => $"object:{value.ObjectId}")
            .ToArray() ?? [];
        var prototypeReferences = projection.Project.Scene.Prototypes?
            .Where(value => value.Behaviors?.Any(binding => binding.ScriptId == scriptId) == true)
            .Select(value => $"prototype:{value.PrototypeId}")
            .ToArray() ?? [];
        // Prototype Binding 与 Object Binding 同为 Scene source 的强引用；删除资产前必须统一裁决。
        var references = objectReferences.Concat(prototypeReferences).Take(4).ToArray();
        if (references.Length != 0)
            throw Failure(WorkspaceScriptAssetLifecycleFailureKind.InUse,
                $"Script Asset {scriptId} is referenced by Scene authoring: {string.Join(", ", references)}.");

        var manifest = WorkspaceScriptSourceModel.EncodeBehaviorManifest(
            current.Dependencies.Where(value => value.ScriptId != scriptId).Select(value => (value.ScriptId, value.SourceName)));
        var manifestStage = $"{bytes.ScriptPath}.authoring.{Guid.NewGuid():N}.stage";
        var manifestPublished = false;
        var sourceDeleted = false;
        try
        {
            WriteNew(manifestStage, manifest);
            RequireUnchanged(project, expectedRevision, current.Revision, cancellationToken);
            cancellationToken.ThrowIfCancellationRequested();
            _phase?.Invoke(WorkspaceScriptAssetLifecyclePhase.DeleteBeforeManifestPublish);
            File.Move(manifestStage, bytes.ScriptPath, true);
            manifestPublished = true;
            _phase?.Invoke(WorkspaceScriptAssetLifecyclePhase.DeleteAfterManifestPublish);
            DeleteOwned(dependency.FullPath, dependency.Source);
            sourceDeleted = true;
            _phase?.Invoke(WorkspaceScriptAssetLifecyclePhase.DeleteAfterSourceDelete);

            var committedBytes = WorkspaceReadModel.ReadProjectBytes(project, default);
            var committed = WorkspaceReadModel.ProjectSnapshotsFromBytes(project, committedBytes);
            RequireCommittedBytes(committedBytes.Script, manifest, "Manifest");
            RequireCommittedMissing(dependency.FullPath, "deleted source");
            var token = new WorkspaceScriptAssetLifecycleUndoToken(
                project.ProjectName,
                committed.Project.AuthoringRevision,
                "delete",
                scriptId,
                dependency.SourceName,
                null,
                bytes.Script,
                manifest,
                dependency.Source);
            return new WorkspaceScriptAssetLifecycleCommit(
                "succeeded",
                projection.Project.AuthoringRevision,
                committed.Project.AuthoringRevision,
                [$"script.assets[{scriptId}]"],
                token,
                new WorkspaceScriptAssetIdentity(scriptId, dependency.SourceName),
                null,
                committed.Project,
                committed.Hierarchy);
        }
        catch
        {
            Compensate(
                () => { if (sourceDeleted) RestoreMissing(dependency.FullPath, dependency.Source); },
                () => { if (manifestPublished) RestoreOwned(bytes.ScriptPath, manifest, bytes.Script); });
            throw;
        }
        finally { TryDelete(manifestStage); }
    }

    private static WorkspaceScriptAssetLifecycleCommit UndoCore(
        ProjectSessionInfo project,
        string expectedRevision,
        WorkspaceScriptAssetLifecycleUndoToken token,
        CancellationToken cancellationToken)
    {
        ValidateExpectedRevision(expectedRevision);
        ArgumentNullException.ThrowIfNull(token);
        if (!token.ProjectName.Equals(project.ProjectName, StringComparison.OrdinalIgnoreCase))
            throw Failure(WorkspaceScriptAssetLifecycleFailureKind.HistoryDiverged, "Script Asset history belongs to a different project.");
        var bytes = WorkspaceReadModel.ReadProjectBytes(project, cancellationToken);
        var projection = WorkspaceReadModel.ProjectSnapshotsFromBytes(project, bytes);
        RequireRevision(expectedRevision, projection.Project.AuthoringRevision);
        if (!token.RevisionAfter.Equals(projection.Project.AuthoringRevision, StringComparison.OrdinalIgnoreCase)
            || !bytes.Script.AsSpan().SequenceEqual(token.ManifestAfter))
        {
            throw Failure(WorkspaceScriptAssetLifecycleFailureKind.HistoryDiverged, "Script Asset history no longer matches the current revision.");
        }

        return token.Operation switch
        {
            "create" => UndoCreate(project, projection, bytes, token, cancellationToken),
            "rename" => UndoRename(project, projection, bytes, token, cancellationToken),
            "delete" => UndoDelete(project, projection, bytes, token, cancellationToken),
            _ => throw Failure(WorkspaceScriptAssetLifecycleFailureKind.Invariant, "Script Asset history contains an unsupported operation.")
        };
    }

    private static WorkspaceScriptAssetLifecycleCommit UndoCreate(
        ProjectSessionInfo project,
        WorkspaceProjectProjection projection,
        WorkspaceProjectBytes bytes,
        WorkspaceScriptAssetLifecycleUndoToken token,
        CancellationToken cancellationToken)
    {
        var sourcePath = WorkspaceScriptSourceModel.ResolveLifecycleSourcePath(bytes.ScriptPath, token.SourcePathAfter!);
        RequireOwned(sourcePath, token.Source);
        var manifestStage = $"{bytes.ScriptPath}.authoring.{Guid.NewGuid():N}.stage";
        var manifestPublished = false;
        var sourceDeleted = false;
        try
        {
            WriteNew(manifestStage, token.ManifestBefore);
            RequireRevision(projection.Project.AuthoringRevision, WorkspaceReadModel.ProjectSnapshotsFromBytes(project, WorkspaceReadModel.ReadProjectBytes(project, cancellationToken)).Project.AuthoringRevision);
            File.Move(manifestStage, bytes.ScriptPath, true);
            manifestPublished = true;
            DeleteOwned(sourcePath, token.Source);
            sourceDeleted = true;
            RequireCommittedBytes(File.ReadAllBytes(bytes.ScriptPath), token.ManifestBefore, "Manifest");
            RequireCommittedMissing(sourcePath, "created source");
            return UndoResult(project, projection, token, new WorkspaceScriptAssetIdentity(token.ScriptId, token.SourcePathAfter!), null);
        }
        catch
        {
            Compensate(
                () => { if (sourceDeleted) RestoreMissing(sourcePath, token.Source); },
                () => { if (manifestPublished) RestoreOwned(bytes.ScriptPath, token.ManifestBefore, token.ManifestAfter); });
            throw;
        }
        finally { TryDelete(manifestStage); }
    }

    private static WorkspaceScriptAssetLifecycleCommit UndoRename(
        ProjectSessionInfo project,
        WorkspaceProjectProjection projection,
        WorkspaceProjectBytes bytes,
        WorkspaceScriptAssetLifecycleUndoToken token,
        CancellationToken cancellationToken)
    {
        var oldPath = WorkspaceScriptSourceModel.ResolveLifecycleSourcePath(bytes.ScriptPath, token.SourcePathBefore!);
        var newPath = WorkspaceScriptSourceModel.ResolveLifecycleSourcePath(bytes.ScriptPath, token.SourcePathAfter!);
        if (File.Exists(oldPath) || Directory.Exists(oldPath))
            throw Failure(WorkspaceScriptAssetLifecycleFailureKind.HistoryDiverged, "The previous Script Asset path is occupied.");
        RequireOwned(newPath, token.Source);
        var sourceStage = $"{oldPath}.authoring.{Guid.NewGuid():N}.stage";
        var manifestStage = $"{bytes.ScriptPath}.authoring.{Guid.NewGuid():N}.stage";
        var oldPublished = false;
        var manifestPublished = false;
        var newDeleted = false;
        try
        {
            WriteNew(sourceStage, token.Source);
            WriteNew(manifestStage, token.ManifestBefore);
            RequireRevision(projection.Project.AuthoringRevision, WorkspaceReadModel.ProjectSnapshotsFromBytes(project, WorkspaceReadModel.ReadProjectBytes(project, cancellationToken)).Project.AuthoringRevision);
            File.Move(sourceStage, oldPath, false);
            oldPublished = true;
            File.Move(manifestStage, bytes.ScriptPath, true);
            manifestPublished = true;
            DeleteOwned(newPath, token.Source);
            newDeleted = true;
            RequireCommittedBytes(File.ReadAllBytes(bytes.ScriptPath), token.ManifestBefore, "Manifest");
            RequireCommittedBytes(File.ReadAllBytes(oldPath), token.Source, "restored source");
            RequireCommittedMissing(newPath, "renamed source");
            return UndoResult(project, projection, token, new WorkspaceScriptAssetIdentity(token.ScriptId, token.SourcePathBefore!), token.SourcePathBefore);
        }
        catch
        {
            Compensate(
                () => { if (newDeleted) RestoreMissing(newPath, token.Source); },
                () => { if (manifestPublished) RestoreOwned(bytes.ScriptPath, token.ManifestBefore, token.ManifestAfter); },
                () => { if (oldPublished) DeleteOwned(oldPath, token.Source); });
            throw;
        }
        finally
        {
            TryDelete(sourceStage);
            TryDelete(manifestStage);
        }
    }

    private static WorkspaceScriptAssetLifecycleCommit UndoDelete(
        ProjectSessionInfo project,
        WorkspaceProjectProjection projection,
        WorkspaceProjectBytes bytes,
        WorkspaceScriptAssetLifecycleUndoToken token,
        CancellationToken cancellationToken)
    {
        var sourcePath = WorkspaceScriptSourceModel.ResolveLifecycleSourcePath(bytes.ScriptPath, token.SourcePathBefore!);
        if (File.Exists(sourcePath) || Directory.Exists(sourcePath))
            throw Failure(WorkspaceScriptAssetLifecycleFailureKind.HistoryDiverged, "The deleted Script Asset path is occupied.");
        var sourceStage = $"{sourcePath}.authoring.{Guid.NewGuid():N}.stage";
        var manifestStage = $"{bytes.ScriptPath}.authoring.{Guid.NewGuid():N}.stage";
        var sourcePublished = false;
        var manifestPublished = false;
        try
        {
            WriteNew(sourceStage, token.Source);
            WriteNew(manifestStage, token.ManifestBefore);
            RequireRevision(projection.Project.AuthoringRevision, WorkspaceReadModel.ProjectSnapshotsFromBytes(project, WorkspaceReadModel.ReadProjectBytes(project, cancellationToken)).Project.AuthoringRevision);
            File.Move(sourceStage, sourcePath, false);
            sourcePublished = true;
            File.Move(manifestStage, bytes.ScriptPath, true);
            manifestPublished = true;
            RequireCommittedBytes(File.ReadAllBytes(bytes.ScriptPath), token.ManifestBefore, "Manifest");
            RequireCommittedBytes(File.ReadAllBytes(sourcePath), token.Source, "restored source");
            return UndoResult(project, projection, token, new WorkspaceScriptAssetIdentity(token.ScriptId, token.SourcePathBefore!), token.SourcePathBefore);
        }
        catch
        {
            Compensate(
                () => { if (manifestPublished) RestoreOwned(bytes.ScriptPath, token.ManifestBefore, token.ManifestAfter); },
                () => { if (sourcePublished) DeleteOwned(sourcePath, token.Source); });
            throw;
        }
        finally
        {
            TryDelete(sourceStage);
            TryDelete(manifestStage);
        }
    }

    private static WorkspaceScriptAssetLifecycleCommit UndoResult(
        ProjectSessionInfo project,
        WorkspaceProjectProjection previous,
        WorkspaceScriptAssetLifecycleUndoToken token,
        WorkspaceScriptAssetIdentity identity,
        string? sourcePath)
    {
        var committedBytes = WorkspaceReadModel.ReadProjectBytes(project, default);
        var committed = WorkspaceReadModel.ProjectSnapshotsFromBytes(project, committedBytes);
        WorkspaceScriptSourceDocument? document = null;
        if (sourcePath is not null)
        {
            var dependency = WorkspaceScriptSourceModel.Read(committedBytes.ScriptPath, default).Dependencies.Single(value => value.ScriptId == token.ScriptId);
            document = Document(project, dependency, committed.Project.AuthoringRevision);
        }
        return new WorkspaceScriptAssetLifecycleCommit(
            "succeeded",
            previous.Project.AuthoringRevision,
            committed.Project.AuthoringRevision,
            ["script.assets.undo"],
            null,
            identity,
            document,
            committed.Project,
            committed.Hierarchy);
    }

    private static void RequireUnchanged(
        ProjectSessionInfo project,
        string expectedRevision,
        string scriptRevision,
        CancellationToken cancellationToken)
    {
        var latestBytes = WorkspaceReadModel.ReadProjectBytes(project, cancellationToken);
        var latest = WorkspaceReadModel.ProjectSnapshotsFromBytes(project, latestBytes);
        RequireRevision(expectedRevision, latest.Project.AuthoringRevision);
        var latestScript = WorkspaceScriptSourceModel.Read(latestBytes.ScriptPath, cancellationToken);
        if (!scriptRevision.Equals(latestScript.Revision, StringComparison.Ordinal))
            throw Failure(WorkspaceScriptAssetLifecycleFailureKind.RevisionConflict, "Script dependency set changed while the transaction was prepared.");
    }

    private static T Execute<T>(Func<T> operation, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        try { return operation(); }
        catch (OperationCanceledException) { throw; }
        catch (WorkspaceScriptAssetLifecycleException) { throw; }
        catch (WorkspaceProjectValidationException exception)
        {
            throw Failure(WorkspaceScriptAssetLifecycleFailureKind.Input, exception.Message, exception);
        }
        catch (WorkspaceReadException exception)
        {
            throw Failure(WorkspaceScriptAssetLifecycleFailureKind.Input, exception.Message, exception);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or OverflowException)
        {
            throw Failure(WorkspaceScriptAssetLifecycleFailureKind.Commit, exception.Message, exception);
        }
    }

    private static void ValidateExpectedRevision(string value)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Length != 64 || value.Any(character => !Uri.IsHexDigit(character)))
            throw Failure(WorkspaceScriptAssetLifecycleFailureKind.InvalidExpectedRevision, "ExpectedRevision must be a SHA-256 hex value.");
    }

    private static void RequireRevision(string expected, string actual)
    {
        if (!expected.Equals(actual, StringComparison.OrdinalIgnoreCase))
            throw Failure(WorkspaceScriptAssetLifecycleFailureKind.RevisionConflict, $"Expected {expected} but current revision is {actual}.");
    }

    private static void WriteNew(string path, byte[] bytes)
    {
        using var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough);
        stream.Write(bytes);
        stream.Flush(true);
    }

    private static WorkspaceScriptSourceDocument Document(
        ProjectSessionInfo project,
        WorkspaceScriptDependency dependency,
        string revision) => new(
            project.ProjectName,
            dependency.ScriptId,
            dependency.SourceName,
            Utf8.GetString(dependency.Source),
            revision);

    private static void RequireOwned(string path, byte[] owned)
    {
        if (!File.Exists(path) || !File.ReadAllBytes(path).AsSpan().SequenceEqual(owned))
            throw Failure(WorkspaceScriptAssetLifecycleFailureKind.HistoryDiverged, "Script Asset source identity changed after the lifecycle commit.");
    }

    private static void RestoreMissing(string path, byte[] source)
    {
        if (File.Exists(path) || Directory.Exists(path))
            throw Failure(WorkspaceScriptAssetLifecycleFailureKind.Invariant, "Script Asset rollback target is occupied.");
        WriteNew(path, source);
    }

    private static void RestoreOwned(string path, byte[] owned, byte[] replacement)
    {
        if (!File.Exists(path) || !File.ReadAllBytes(path).AsSpan().SequenceEqual(owned))
            throw Failure(WorkspaceScriptAssetLifecycleFailureKind.Invariant, "Script Asset rollback lost Manifest ownership.");
        var stage = $"{path}.authoring.{Guid.NewGuid():N}.rollback";
        try
        {
            WriteNew(stage, replacement);
            File.Move(stage, path, true);
        }
        finally { TryDelete(stage); }
    }

    private static void DeleteOwned(string path, byte[] owned)
    {
        if (!File.Exists(path) || !File.ReadAllBytes(path).AsSpan().SequenceEqual(owned))
            throw Failure(WorkspaceScriptAssetLifecycleFailureKind.Invariant, "Script Asset rollback lost source ownership.");
        File.Delete(path);
    }

    private static bool HasPortablePathConflict(string scriptPath, string sourceName)
    {
        var current = Path.GetDirectoryName(Path.GetFullPath(scriptPath))!;
        var segments = sourceName.Split('/');
        for (var index = 0; index < segments.Length; index++)
        {
            if (!Directory.Exists(current)) return false;
            var match = Directory.EnumerateFileSystemEntries(current)
                .FirstOrDefault(path => Path.GetFileName(path).Equals(segments[index], StringComparison.OrdinalIgnoreCase));
            if (match is null) return false;
            if (!Path.GetFileName(match).Equals(segments[index], StringComparison.Ordinal)) return true;
            if (index < segments.Length - 1 && !Directory.Exists(match)) return true;
            current = match;
        }
        return true;
    }

    private static void RequireCommittedBytes(byte[] actual, byte[] expected, string label)
    {
        if (!actual.AsSpan().SequenceEqual(expected))
            throw Failure(WorkspaceScriptAssetLifecycleFailureKind.Invariant, $"Committed Script Asset {label} identity changed before terminal projection.");
    }

    private static void RequireCommittedMissing(string path, string label)
    {
        if (File.Exists(path) || Directory.Exists(path))
            throw Failure(WorkspaceScriptAssetLifecycleFailureKind.Invariant, $"Committed Script Asset {label} reappeared before terminal projection.");
    }

    private static void Compensate(params Action[] actions)
    {
        List<Exception>? failures = null;
        foreach (var action in actions)
        {
            try { action(); }
            catch (Exception exception) { (failures ??= []).Add(exception); }
        }
        if (failures is not null)
        {
            throw Failure(
                WorkspaceScriptAssetLifecycleFailureKind.Invariant,
                "Script Asset rollback could not restore every owned path.",
                new AggregateException(failures));
        }
    }

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); }
        catch { }
    }

    private static WorkspaceScriptAssetLifecycleException Failure(
        WorkspaceScriptAssetLifecycleFailureKind kind,
        string message,
        Exception? inner = null) => new(kind, message, inner);
}
