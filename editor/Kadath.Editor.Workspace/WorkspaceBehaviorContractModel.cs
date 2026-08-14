using System.ComponentModel;
using Kadath.Editor.Protocol;

namespace Kadath.Editor.Workspace;

internal sealed record WorkspaceBehaviorParameterSchema(
    string Name,
    string Type,
    double DefaultValue,
    double Minimum,
    double Maximum);

internal sealed record WorkspaceBehaviorContractEntry(
    uint ScriptId,
    string SourcePath,
    string SourceHash,
    WorkspaceBehaviorParameterSchema[] Parameters);

internal sealed record WorkspaceBehaviorContractCatalog(
    string ToolchainIdentity,
    WorkspaceBehaviorContractEntry[] Entries);

public sealed class WorkspaceBehaviorContractException : Exception
{
    internal WorkspaceBehaviorContractException(string code, string message, Exception? innerException = null)
        : base(message, innerException) => Code = code;

    public string Code { get; }
}

public sealed class WorkspaceBehaviorContractModel
{
    public Task<BehaviorContractSnapshotResult> ReadAsync(
        ProjectSessionInfo project,
        CancellationToken cancellationToken)
    {
        try
        {
            return Task.FromResult(ToProtocol(project, Read(project, cancellationToken)));
        }
        catch (WorkspaceBehaviorContractException exception)
        {
            var sourceRevision = string.Empty;
            var authoringRevision = string.Empty;
            try
            {
                var paths = WorkspaceProjectValidator.ResolveOpenPaths(project);
                sourceRevision = WorkspaceScriptSourceModel.Read(paths.ScriptPath, cancellationToken).Revision;
                authoringRevision = WorkspaceReadModel.ProjectSnapshotsFromBytes(
                    project,
                    WorkspaceReadModel.ReadProjectBytes(project, cancellationToken)).Project.AuthoringRevision;
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
            catch { }
            return Task.FromResult(new BehaviorContractSnapshotResult(
                "unavailable",
                project.ProjectName,
                authoringRevision,
                sourceRevision,
                string.Empty,
                [],
                exception.Code));
        }
    }

    internal static WorkspaceBehaviorContractObservation Read(
        ProjectSessionInfo project,
        CancellationToken cancellationToken)
    {
        try
        {
            var paths = WorkspaceProjectValidator.ResolveOpenPaths(project);
            var snapshot = WorkspaceScriptSourceModel.Read(paths.ScriptPath, cancellationToken);
            if (!snapshot.IsBehaviorPackage)
                throw new WorkspaceBehaviorContractException("behavior_contract_unsupported", "Behavior contracts require Script schema v2.");

            var artifact = WorkspaceBehaviorTool.Build(paths.PackageRoot, paths.ScriptPath, snapshot, cancellationToken);
            var catalog = WorkspaceScriptCodec.ReadBehaviorContractCatalog(artifact);
            if (catalog.Entries.Length != snapshot.Dependencies.Count
                || catalog.Entries.Zip(snapshot.Dependencies).Any(pair =>
                    pair.First.ScriptId != pair.Second.ScriptId
                    || !pair.First.SourcePath.Equals(pair.Second.SourceName, StringComparison.Ordinal)
                    || !pair.First.SourceHash.Equals(pair.Second.Sha256, StringComparison.Ordinal)))
            {
                throw new WorkspaceBehaviorToolException("Behavior Tool artifact does not match the captured Script dependency set.");
            }
            var current = WorkspaceScriptSourceModel.Read(paths.ScriptPath, cancellationToken);
            if (!snapshot.Revision.Equals(current.Revision, StringComparison.Ordinal))
                throw new WorkspaceBehaviorContractException("behavior_contract_source_changed", "Script dependencies changed while reading behavior contracts.");
            var projection = WorkspaceReadModel.ProjectSnapshotsFromBytes(project, WorkspaceReadModel.ReadProjectBytes(project, cancellationToken));
            var verified = WorkspaceScriptSourceModel.Read(paths.ScriptPath, cancellationToken);
            if (!snapshot.Revision.Equals(verified.Revision, StringComparison.Ordinal))
                throw new WorkspaceBehaviorContractException("behavior_contract_source_changed", "Script dependencies changed while reading behavior contracts.");
            return new WorkspaceBehaviorContractObservation(projection.Project.AuthoringRevision, snapshot.Revision, catalog);
        }
        catch (WorkspaceBehaviorContractException)
        {
            throw;
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (WorkspaceBehaviorToolException exception)
        {
            throw new WorkspaceBehaviorContractException("behavior_contract_tool_failure", exception.Message, exception);
        }
        catch (InvalidDataException exception)
        {
            throw new WorkspaceBehaviorContractException("behavior_contract_invalid_source", exception.Message, exception);
        }
        catch (WorkspaceProjectValidationException exception)
        {
            throw new WorkspaceBehaviorContractException("behavior_contract_invalid_source", exception.Message, exception);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or Win32Exception)
        {
            throw new WorkspaceBehaviorContractException("behavior_contract_tool_failure", exception.Message, exception);
        }
    }

    private static BehaviorContractSnapshotResult ToProtocol(
        ProjectSessionInfo project,
        WorkspaceBehaviorContractObservation observation) =>
        new(
            "ready",
            project.ProjectName,
            observation.AuthoringRevision,
            observation.ScriptSourceRevision,
            observation.Catalog.ToolchainIdentity,
            observation.Catalog.Entries.Select(entry => new BehaviorContractEntry(
                entry.ScriptId,
                entry.SourcePath,
                entry.SourceHash,
                entry.Parameters.Select(parameter => new BehaviorParameterSchema(
                    parameter.Name,
                    parameter.Type,
                    parameter.DefaultValue,
                    parameter.Minimum,
                    parameter.Maximum)).ToArray())).ToArray());
}

internal sealed record WorkspaceBehaviorContractObservation(
    string AuthoringRevision,
    string ScriptSourceRevision,
    WorkspaceBehaviorContractCatalog Catalog);
