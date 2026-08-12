using System.Text.Json;
using Kadath.Editor.Protocol;

namespace Kadath.Editor.Workspace;

public sealed record WorkspaceScriptSourceAuthoringCommit(
    string State,
    string PreviousRevision,
    string Revision,
    string[] ChangedFields,
    WorkspaceScriptSourceUndoToken? UndoToken,
    ProjectModelSnapshot ProjectSnapshot,
    HierarchySnapshot HierarchySnapshot);

public sealed record WorkspaceScriptSourceDocument(
    string ProjectName,
    uint ScriptId,
    string SourcePath,
    string Source,
    string AuthoringRevision);

public sealed class WorkspaceScriptSourceUndoToken
{
    internal WorkspaceScriptSourceUndoToken(
        string projectName,
        string revisionAfter,
        string scriptPath,
        uint scriptId,
        byte[] sourceBefore,
        byte[] sourceAfter)
    {
        ProjectName = projectName;
        RevisionAfter = revisionAfter;
        ScriptPath = scriptPath;
        ScriptId = scriptId;
        SourceBefore = sourceBefore.ToArray();
        SourceAfter = sourceAfter.ToArray();
    }

    internal string ProjectName { get; }
    internal string RevisionAfter { get; }
    internal string ScriptPath { get; }
    public uint ScriptId { get; }
    internal byte[] SourceBefore { get; }
    internal byte[] SourceAfter { get; }
}

public sealed class WorkspaceScriptSourceAuthoringModel
{
    public Task<WorkspaceScriptSourceAuthoringCommit> ApplyAsync(
        ProjectSessionInfo project,
        string expectedRevision,
        uint scriptId,
        string source,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(Execute(() => ApplyCore(project, expectedRevision, scriptId, source, cancellationToken), cancellationToken));

    public Task<WorkspaceScriptSourceDocument> ReadAsync(
        ProjectSessionInfo project,
        uint scriptId,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(Execute(() => ReadCore(project, scriptId, cancellationToken), cancellationToken));

    public Task<WorkspaceScriptSourceAuthoringCommit> UndoAsync(
        ProjectSessionInfo project,
        string expectedRevision,
        WorkspaceScriptSourceUndoToken token,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(Execute(() => UndoCore(project, expectedRevision, token, cancellationToken), cancellationToken));

    private static WorkspaceScriptSourceAuthoringCommit ApplyCore(
        ProjectSessionInfo project,
        string expectedRevision,
        uint scriptId,
        string source,
        CancellationToken cancellationToken)
    {
        ValidateExpectedRevision(expectedRevision);
        if (scriptId == 0) throw Failure(WorkspaceAuthoringFailureKind.InvalidPatch, "ScriptId must be non-zero.");
        var bytes = WorkspaceReadModel.ReadProjectBytes(project, cancellationToken);
        var projection = WorkspaceReadModel.ProjectSnapshotsFromBytes(project, bytes);
        var current = WorkspaceScriptSourceModel.Read(bytes.ScriptPath, cancellationToken);
        if (!current.IsBehaviorPackage) throw Failure(WorkspaceAuthoringFailureKind.InvalidPatch, "Script source authoring requires Script schema v2.");
        RequireRevision(expectedRevision, projection.Project.AuthoringRevision);
        var dependency = current.Dependencies.SingleOrDefault(value => value.ScriptId == scriptId)
            ?? throw Failure(WorkspaceAuthoringFailureKind.InvalidPatch, $"ScriptId {scriptId} is not declared by script.json.");
        var edited = WorkspaceScriptSourceModel.EncodeEditedSource(dependency.SourceName, source);
        if (edited.AsSpan().SequenceEqual(dependency.Source))
        {
            return new WorkspaceScriptSourceAuthoringCommit("unchanged", projection.Project.AuthoringRevision, projection.Project.AuthoringRevision,
                [], null, projection.Project, projection.Hierarchy);
        }

        Replace(project, dependency.FullPath, dependency.Source, edited, projection.Project.AuthoringRevision, cancellationToken);
        try
        {
            var committedBytes = WorkspaceReadModel.ReadProjectBytes(project, cancellationToken);
            var committed = WorkspaceReadModel.ProjectSnapshotsFromBytes(project, committedBytes);
            var token = new WorkspaceScriptSourceUndoToken(
                project.ProjectName, committed.Project.AuthoringRevision, dependency.FullPath, dependency.ScriptId, dependency.Source, edited);
            return new WorkspaceScriptSourceAuthoringCommit("succeeded", projection.Project.AuthoringRevision, committed.Project.AuthoringRevision,
                [$"script.sources[{scriptId}]"], token, committed.Project, committed.Hierarchy);
        }
        catch
        {
            RestoreOwned(dependency.FullPath, edited, dependency.Source);
            throw;
        }
    }

    private static WorkspaceScriptSourceAuthoringCommit UndoCore(
        ProjectSessionInfo project,
        string expectedRevision,
        WorkspaceScriptSourceUndoToken token,
        CancellationToken cancellationToken)
    {
        ValidateExpectedRevision(expectedRevision);
        ArgumentNullException.ThrowIfNull(token);
        if (!string.Equals(token.ProjectName, project.ProjectName, StringComparison.OrdinalIgnoreCase))
            throw Failure(WorkspaceAuthoringFailureKind.Invariant, "Script source undo token project does not match.");
        var bytes = WorkspaceReadModel.ReadProjectBytes(project, cancellationToken);
        var current = WorkspaceReadModel.ProjectSnapshotsFromBytes(project, bytes);
        RequireRevision(expectedRevision, current.Project.AuthoringRevision);
        if (!token.RevisionAfter.Equals(current.Project.AuthoringRevision, StringComparison.OrdinalIgnoreCase))
            throw Failure(WorkspaceAuthoringFailureKind.RevisionConflict, "Script source undo token does not match the current revision.");
        if (!File.Exists(token.ScriptPath) || !File.ReadAllBytes(token.ScriptPath).AsSpan().SequenceEqual(token.SourceAfter))
            throw Failure(WorkspaceAuthoringFailureKind.RevisionConflict, "Script source changed after the authoring commit.");
        Replace(project, token.ScriptPath, token.SourceAfter, token.SourceBefore, current.Project.AuthoringRevision, cancellationToken);
        try
        {
            var restoredBytes = WorkspaceReadModel.ReadProjectBytes(project, cancellationToken);
            var restored = WorkspaceReadModel.ProjectSnapshotsFromBytes(project, restoredBytes);
            return new WorkspaceScriptSourceAuthoringCommit("succeeded", current.Project.AuthoringRevision, restored.Project.AuthoringRevision,
                ["script.sources.undo"], null, restored.Project, restored.Hierarchy);
        }
        catch
        {
            RestoreOwned(token.ScriptPath, token.SourceBefore, token.SourceAfter);
            throw;
        }
    }

    private static WorkspaceScriptSourceDocument ReadCore(
        ProjectSessionInfo project,
        uint scriptId,
        CancellationToken cancellationToken)
    {
        if (scriptId == 0) throw Failure(WorkspaceAuthoringFailureKind.InvalidPatch, "ScriptId must be non-zero.");
        var bytes = WorkspaceReadModel.ReadProjectBytes(project, cancellationToken);
        var projection = WorkspaceReadModel.ProjectSnapshotsFromBytes(project, bytes);
        var snapshot = WorkspaceScriptSourceModel.Read(bytes.ScriptPath, cancellationToken);
        if (!snapshot.IsBehaviorPackage) throw Failure(WorkspaceAuthoringFailureKind.InvalidPatch, "Script source authoring requires Script schema v2.");
        var dependency = snapshot.Dependencies.SingleOrDefault(value => value.ScriptId == scriptId)
            ?? throw Failure(WorkspaceAuthoringFailureKind.InvalidPatch, $"ScriptId {scriptId} is not declared by script.json.");
        return new WorkspaceScriptSourceDocument(
            project.ProjectName,
            dependency.ScriptId,
            dependency.SourceName,
            new System.Text.UTF8Encoding(false, true).GetString(dependency.Source),
            projection.Project.AuthoringRevision);
    }

    private static void Replace(
        ProjectSessionInfo project,
        string targetPath,
        byte[] original,
        byte[] intended,
        string expectedRevision,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        WorkspaceProjectValidator.RejectReparsePoint(targetPath, "Script source");
        if (!File.ReadAllBytes(targetPath).AsSpan().SequenceEqual(original))
            throw Failure(WorkspaceAuthoringFailureKind.RevisionConflict, "Script source changed while the transaction was prepared.");
        var stagePath = $"{targetPath}.authoring.{Guid.NewGuid():N}.stage";
        try
        {
            WriteNew(stagePath, intended);
            var latestBytes = WorkspaceReadModel.ReadProjectBytes(project, cancellationToken);
            var latest = WorkspaceReadModel.ProjectSnapshotsFromBytes(project, latestBytes);
            RequireRevision(expectedRevision, latest.Project.AuthoringRevision);
            if (!File.ReadAllBytes(targetPath).AsSpan().SequenceEqual(original))
                throw Failure(WorkspaceAuthoringFailureKind.RevisionConflict, "Script source changed while the transaction was staged.");
            File.Move(stagePath, targetPath, true);
        }
        catch (Exception exception) when (exception is not OperationCanceledException && exception is not WorkspaceAuthoringException)
        {
            throw Failure(WorkspaceAuthoringFailureKind.Commit, $"Script source commit failed: {exception.Message}", exception);
        }
        finally
        {
            TryDelete(stagePath);
        }
    }

    private static T Execute<T>(Func<T> operation, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        try { return operation(); }
        catch (OperationCanceledException) { throw; }
        catch (WorkspaceAuthoringException) { throw; }
        catch (WorkspaceProjectValidationException exception) { throw Failure(WorkspaceAuthoringFailureKind.Input, exception.Message, exception); }
        catch (WorkspaceReadException exception) { throw Failure(WorkspaceAuthoringFailureKind.Input, exception.Message, exception); }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException or FormatException or OverflowException)
        {
            throw Failure(WorkspaceAuthoringFailureKind.Input, exception.Message, exception);
        }
    }

    private static void ValidateExpectedRevision(string value)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Length != 64 || value.Any(character => !Uri.IsHexDigit(character)))
            throw Failure(WorkspaceAuthoringFailureKind.InvalidExpectedRevision, "ExpectedRevision must be a SHA-256 hex value.");
    }

    private static void RequireRevision(string expected, string actual)
    {
        if (!expected.Equals(actual, StringComparison.OrdinalIgnoreCase))
            throw Failure(WorkspaceAuthoringFailureKind.RevisionConflict, $"Expected {expected} but current revision is {actual}.");
    }

    private static void WriteNew(string path, byte[] bytes)
    {
        using var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough);
        stream.Write(bytes);
        stream.Flush(true);
    }

    private static void RestoreOwned(string path, byte[] owned, byte[] replacement)
    {
        try
        {
            if (!File.Exists(path) || !File.ReadAllBytes(path).AsSpan().SequenceEqual(owned))
                throw Failure(WorkspaceAuthoringFailureKind.Invariant, "Script source rollback lost ownership of the edited file.");
            var stagePath = $"{path}.authoring.{Guid.NewGuid():N}.rollback";
            try
            {
                WriteNew(stagePath, replacement);
                File.Move(stagePath, path, true);
            }
            finally { TryDelete(stagePath); }
        }
        catch (WorkspaceAuthoringException) { throw; }
        catch (Exception exception) { throw Failure(WorkspaceAuthoringFailureKind.Invariant, $"Script source rollback failed: {exception.Message}", exception); }
    }

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); }
        catch { }
    }

    private static WorkspaceAuthoringException Failure(WorkspaceAuthoringFailureKind kind, string message, Exception? inner = null) =>
        new(kind, message, inner);
}
