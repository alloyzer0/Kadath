using Kadath.Editor.Core;
using Kadath.Editor.Protocol;
using Kadath.Editor.Workspace;

namespace Kadath.Editor.Service;

internal sealed class WorkspaceEditorBackend : IEditorSessionBackend
{
    private readonly WorkspaceProjectLifecycleModel _projectLifecycleModel;
    private readonly WorkspaceReadModel _readModel;
    private readonly WorkspaceAuthoringModel _authoringModel;
    private readonly WorkspacePublicationModel _publicationModel;
    private readonly WorkspaceTextureImportModel _textureImportModel;
    private readonly WorkspaceScriptSourceAuthoringModel _scriptSourceAuthoringModel;
    private readonly WorkspaceScriptAssetLifecycleModel _scriptAssetLifecycleModel;
    private readonly WorkspaceScriptDiagnosticsModel _scriptDiagnosticsModel;
    private readonly WorkspaceBehaviorContractModel _behaviorContractModel;
    private readonly SemaphoreSlim _bakeGate = new(1, 1);
    private readonly SemaphoreSlim _watchGate = new(1, 1);
    private readonly SemaphoreSlim _authoringGate = new(1, 1);
    private readonly SemaphoreSlim _scriptAnalysisGate = new(1, 1);
    private readonly List<AuthoringUndoRecord> _authoringHistory = [];
    private readonly List<AuthoringUndoRecord> _authoringRedoHistory = [];
    private readonly List<ScriptSourceUndoRecord> _scriptSourceHistory = [];
    private readonly List<ScriptAssetUndoRecord> _scriptAssetHistory = [];
    private const int MaxAuthoringHistory = 32;
    private LiveBakeWatchController? _watch;
    private string _watchProjectName = string.Empty;
    private string _watchTarget = "Both";
    private string _watchProfile = "debug";

    public WorkspaceEditorBackend(
        WorkspaceProjectLifecycleModel projectLifecycleModel,
        WorkspaceReadModel readModel,
        WorkspaceAuthoringModel authoringModel,
        WorkspacePublicationModel publicationModel,
        WorkspaceTextureImportModel textureImportModel,
        WorkspaceScriptSourceAuthoringModel? scriptSourceAuthoringModel = null,
        WorkspaceScriptAssetLifecycleModel? scriptAssetLifecycleModel = null,
        WorkspaceScriptDiagnosticsModel? scriptDiagnosticsModel = null,
        WorkspaceBehaviorContractModel? behaviorContractModel = null)
    {
        _projectLifecycleModel = projectLifecycleModel;
        _readModel = readModel;
        _authoringModel = authoringModel;
        _publicationModel = publicationModel;
        _textureImportModel = textureImportModel;
        _scriptSourceAuthoringModel = scriptSourceAuthoringModel ?? new WorkspaceScriptSourceAuthoringModel();
        _scriptAssetLifecycleModel = scriptAssetLifecycleModel ?? new WorkspaceScriptAssetLifecycleModel();
        _scriptDiagnosticsModel = scriptDiagnosticsModel ?? new WorkspaceScriptDiagnosticsModel();
        _behaviorContractModel = behaviorContractModel ?? new WorkspaceBehaviorContractModel();
    }

    public event Func<EditorSessionNotification, Task>? Notification;

    public async Task<ProjectSessionInfo> OpenProjectAsync(ProjectOpenParameters parameters, CancellationToken cancellationToken)
    {
        var project = await ExecuteProjectLifecycleAsync(() => _projectLifecycleModel.OpenAsync(parameters, cancellationToken));
        _authoringHistory.Clear();
        _authoringRedoHistory.Clear();
        _scriptSourceHistory.Clear();
        _scriptAssetHistory.Clear();
        return project;
    }

    public async Task<ProjectSessionInfo> CreateProjectAsync(ProjectCreateParameters parameters, CancellationToken cancellationToken)
    {
        var project = await ExecuteProjectLifecycleAsync(() => _projectLifecycleModel.CreateAsync(parameters, cancellationToken));
        _authoringHistory.Clear();
        _authoringRedoHistory.Clear();
        _scriptSourceHistory.Clear();
        _scriptAssetHistory.Clear();
        return project;
    }

    public Task<ProjectValidateResult> ValidateProjectAsync(ProjectSessionInfo project, CancellationToken cancellationToken) =>
        ExecuteProjectLifecycleAsync(() => _projectLifecycleModel.ValidateAsync(project, cancellationToken));

    private static async Task<T> ExecuteProjectLifecycleAsync<T>(Func<Task<T>> operation)
    {
        try { return await operation(); }
        catch (WorkspaceProjectLifecycleException exception)
        {
            var code = exception.Kind switch
            {
                WorkspaceProjectLifecycleFailureKind.InvalidProjectName => "invalid_project_name",
                WorkspaceProjectLifecycleFailureKind.PackageNotFound => "package_not_found",
                WorkspaceProjectLifecycleFailureKind.PathEscape => "project_path_escape",
                WorkspaceProjectLifecycleFailureKind.ProjectFileMissing => "project_file_missing",
                WorkspaceProjectLifecycleFailureKind.AlreadyExists => "project_already_exists",
                WorkspaceProjectLifecycleFailureKind.Create => "project_create_failed",
                WorkspaceProjectLifecycleFailureKind.Validation or WorkspaceProjectLifecycleFailureKind.Invariant => "project_validation_failed",
                _ => "project_validation_failed"
            };
            throw new EditorOperationException(code, exception.Message);
        }
    }

    public Task<ProjectModelSnapshot> GetProjectSnapshotAsync(ProjectSessionInfo project, CancellationToken cancellationToken) =>
        ReadWorkspaceSnapshotAsync(() => _readModel.ReadProjectAsync(project, cancellationToken), project, false);

    public async Task<ScriptSourceDocument> GetScriptSourceAsync(ProjectSessionInfo project, ScriptSourceQueryParameters parameters, CancellationToken cancellationToken)
    {
        if (parameters.ScriptId == 0) throw new EditorOperationException("invalid_script_source", "ScriptId must be non-zero.");
        try
        {
            var document = await _scriptSourceAuthoringModel.ReadAsync(project, parameters.ScriptId, cancellationToken);
            return new ScriptSourceDocument(document.ProjectName, document.ScriptId, document.SourcePath, document.Source, document.AuthoringRevision);
        }
        catch (WorkspaceAuthoringException exception) { throw MapScriptSourceError(exception); }
    }

    public async Task<ScriptSourceAnalysisResult> AnalyzeScriptSourceAsync(
        ProjectSessionInfo project,
        ScriptSourceAnalyzeParameters parameters,
        CancellationToken cancellationToken)
    {
        if (!await _scriptAnalysisGate.WaitAsync(0, cancellationToken))
            throw new EditorOperationException("script_source_analysis_busy", "A Script source analysis is already running.");
        try
        {
            try { return await _scriptDiagnosticsModel.AnalyzeAsync(project, parameters, cancellationToken); }
            catch (WorkspaceScriptDiagnosticsException exception) { throw MapScriptDiagnosticsFailure(exception); }
        }
        finally { _scriptAnalysisGate.Release(); }
    }

    internal static EditorOperationException MapScriptDiagnosticsFailure(WorkspaceScriptDiagnosticsException exception)
    {
        var code = exception.Kind switch
        {
            WorkspaceScriptDiagnosticsFailureKind.Input => "invalid_script_source_analysis_request",
            WorkspaceScriptDiagnosticsFailureKind.Unavailable => "script_source_analyzer_unavailable",
            WorkspaceScriptDiagnosticsFailureKind.Timeout => "script_source_analysis_timeout",
            WorkspaceScriptDiagnosticsFailureKind.Cleanup => "script_source_analysis_cleanup_failed",
            WorkspaceScriptDiagnosticsFailureKind.Protocol => "script_source_analysis_protocol_error",
            _ => "script_source_analysis_protocol_error"
        };
        return new EditorOperationException(code, exception.Message);
    }

    public Task<HierarchySnapshot> GetHierarchySnapshotAsync(ProjectSessionInfo project, CancellationToken cancellationToken) =>
        ReadWorkspaceSnapshotAsync(() => _readModel.ReadHierarchyAsync(project, cancellationToken), project, false);

    public Task<BehaviorContractSnapshotResult> GetBehaviorContractSnapshotAsync(
        ProjectSessionInfo project,
        BehaviorContractSnapshotParameters parameters,
        CancellationToken cancellationToken) =>
        _behaviorContractModel.ReadAsync(project, cancellationToken);

    public Task<AssetCatalogSnapshot> GetAssetCatalogSnapshotAsync(ProjectSessionInfo project, CancellationToken cancellationToken) =>
        ReadWorkspaceSnapshotAsync(() => _readModel.ReadAssetsAsync(project, cancellationToken), project, false);

    public Task<PublicationSnapshot> GetPublicationSnapshotAsync(ProjectSessionInfo project, PublicationSnapshotQueryParameters parameters, CancellationToken cancellationToken) =>
        ReadWorkspaceSnapshotAsync(() => _readModel.ReadPublicationAsync(project, NormalizeProfile(parameters.Profile), cancellationToken), project, true);

    public async Task<TextureImportResult> ImportTextureAsync(ProjectSessionInfo project, TextureImportParameters parameters, CancellationToken cancellationToken)
    {
        try
        {
            var result = await _textureImportModel.ImportAsync(project, parameters, cancellationToken);
            ValidateSnapshot(project, result.AssetCatalog);
            return result;
        }
        catch (WorkspaceTextureImportException exception)
        {
            var code = exception.Kind switch
            {
                WorkspaceTextureImportFailureKind.InvalidSource => "invalid_texture_source",
                WorkspaceTextureImportFailureKind.InvalidAssetName => "invalid_texture_asset_name",
                WorkspaceTextureImportFailureKind.InvalidProfile => "invalid_texture_import_profile",
                WorkspaceTextureImportFailureKind.Conflict => "texture_asset_conflict",
                WorkspaceTextureImportFailureKind.Validation => "texture_import_validation_failed",
                WorkspaceTextureImportFailureKind.Promote => "texture_import_promote_failed",
                WorkspaceTextureImportFailureKind.Invariant => "texture_import_protocol_error",
                _ => "texture_import_failed"
            };
            throw new EditorOperationException(code, exception.Message);
        }
    }

    public async Task<AuthoringMutationResult> ApplyAuthoringAsync(ProjectSessionInfo project, AuthoringApplyParameters parameters, CancellationToken cancellationToken)
    {
        await _authoringGate.WaitAsync(cancellationToken);
        try
        {
            var commit = await ApplyWorkspaceAuthoringAsync(project, parameters.ExpectedRevision, parameters.Patch, cancellationToken);
            if (commit.State == "unchanged")
            {
                return new AuthoringMutationResult("apply", "unchanged", project.ProjectName, commit.PreviousRevision, commit.Revision,
                    [], _authoringHistory.Count, commit.ProjectSnapshot, commit.HierarchySnapshot, _authoringRedoHistory.Count);
            }

            if (commit.UndoToken is null) { throw new EditorOperationException("authoring_protocol_error", "Native authoring commit emitted no undo token."); }
            _authoringHistory.Add(new AuthoringUndoRecord(project.ProjectName, commit.Revision, commit.ChangedFields, commit.UndoToken));
            if (_authoringHistory.Count > MaxAuthoringHistory) { _authoringHistory.RemoveAt(0); }
            _authoringRedoHistory.Clear();
            return new AuthoringMutationResult("apply", "succeeded", project.ProjectName, commit.PreviousRevision, commit.Revision,
                commit.ChangedFields, _authoringHistory.Count, commit.ProjectSnapshot, commit.HierarchySnapshot, 0);
        }
        finally { _authoringGate.Release(); }
    }

    public async Task<AuthoringMutationResult> UndoAuthoringAsync(ProjectSessionInfo project, AuthoringUndoParameters parameters, CancellationToken cancellationToken)
    {
        await _authoringGate.WaitAsync(cancellationToken);
        try
        {
            var current = await GetProjectSnapshotAsync(project, cancellationToken);
            ValidateExpectedRevision(parameters.ExpectedRevision, current.AuthoringRevision);
            if (_authoringHistory.Count == 0) { throw new EditorOperationException("authoring_undo_empty", "There is no authoring mutation to undo."); }
            var record = _authoringHistory[^1];
            if (!string.Equals(record.ProjectName, project.ProjectName, StringComparison.OrdinalIgnoreCase)
                || !string.Equals(record.RevisionAfter, current.AuthoringRevision, StringComparison.OrdinalIgnoreCase))
            {
                throw new EditorOperationException("authoring_history_diverged", "Authoring history no longer matches the current revision.");
            }

            var commit = await UndoWorkspaceAuthoringAsync(project, parameters.ExpectedRevision, record.Token, cancellationToken);
            if (commit.State != "succeeded") { throw new EditorOperationException("authoring_protocol_error", "Native authoring undo did not restore a changed state."); }
            if (commit.UndoToken is null) { throw new EditorOperationException("authoring_protocol_error", "Native authoring undo emitted no redo token."); }
            _authoringHistory.RemoveAt(_authoringHistory.Count - 1);
            _authoringRedoHistory.Add(new AuthoringUndoRecord(project.ProjectName, commit.Revision, record.ChangedFields, commit.UndoToken));
            if (_authoringRedoHistory.Count > MaxAuthoringHistory) { _authoringRedoHistory.RemoveAt(0); }
            return new AuthoringMutationResult("undo", "succeeded", project.ProjectName, commit.PreviousRevision, commit.Revision,
                record.ChangedFields, _authoringHistory.Count, commit.ProjectSnapshot, commit.HierarchySnapshot, _authoringRedoHistory.Count);
        }
        finally { _authoringGate.Release(); }
    }

    public async Task<AuthoringMutationResult> RedoAuthoringAsync(ProjectSessionInfo project, AuthoringRedoParameters parameters, CancellationToken cancellationToken)
    {
        await _authoringGate.WaitAsync(cancellationToken);
        try
        {
            var current = await GetProjectSnapshotAsync(project, cancellationToken);
            ValidateExpectedRevision(parameters.ExpectedRevision, current.AuthoringRevision);
            if (_authoringRedoHistory.Count == 0) { throw new EditorOperationException("authoring_redo_empty", "There is no authoring mutation to redo."); }
            var record = _authoringRedoHistory[^1];
            if (!string.Equals(record.ProjectName, project.ProjectName, StringComparison.OrdinalIgnoreCase)
                || !string.Equals(record.RevisionAfter, current.AuthoringRevision, StringComparison.OrdinalIgnoreCase))
            {
                throw new EditorOperationException("authoring_history_diverged", "Authoring redo history no longer matches the current revision.");
            }

            var commit = await UndoWorkspaceAuthoringAsync(project, parameters.ExpectedRevision, record.Token, cancellationToken);
            if (commit.State != "succeeded" || commit.UndoToken is null)
                throw new EditorOperationException("authoring_protocol_error", "Native authoring redo did not emit a reverse token.");
            _authoringRedoHistory.RemoveAt(_authoringRedoHistory.Count - 1);
            _authoringHistory.Add(new AuthoringUndoRecord(project.ProjectName, commit.Revision, record.ChangedFields, commit.UndoToken));
            if (_authoringHistory.Count > MaxAuthoringHistory) { _authoringHistory.RemoveAt(0); }
            return new AuthoringMutationResult("redo", "succeeded", project.ProjectName, commit.PreviousRevision, commit.Revision,
                record.ChangedFields, _authoringHistory.Count, commit.ProjectSnapshot, commit.HierarchySnapshot, _authoringRedoHistory.Count);
        }
        finally { _authoringGate.Release(); }
    }

    public async Task<ScriptSourceMutationResult> EditScriptSourceAsync(ProjectSessionInfo project, ScriptSourceEditParameters parameters, CancellationToken cancellationToken)
    {
        await _authoringGate.WaitAsync(cancellationToken);
        try
        {
            try
            {
                var commit = await _scriptSourceAuthoringModel.ApplyAsync(project, parameters.ExpectedRevision, parameters.ScriptId, parameters.Source, cancellationToken);
                if (commit.State == "unchanged")
                    return await CreateScriptSourceResultAsync("edit", project, parameters.ScriptId, commit, _scriptSourceHistory.Count, cancellationToken);
                if (commit.UndoToken is null) throw new EditorOperationException("script_source_protocol_error", "Script source commit emitted no undo token.");
                _scriptSourceHistory.Add(new ScriptSourceUndoRecord(project.ProjectName, commit.Revision, commit.ChangedFields, commit.UndoToken));
                if (_scriptSourceHistory.Count > MaxAuthoringHistory) _scriptSourceHistory.RemoveAt(0);
                return await CreateScriptSourceResultAsync("edit", project, parameters.ScriptId, commit, _scriptSourceHistory.Count, cancellationToken);
            }
            catch (WorkspaceAuthoringException exception) { throw MapScriptSourceError(exception); }
        }
        finally { _authoringGate.Release(); }
    }

    public async Task<ScriptSourceMutationResult> UndoScriptSourceAsync(ProjectSessionInfo project, ScriptSourceUndoParameters parameters, CancellationToken cancellationToken)
    {
        await _authoringGate.WaitAsync(cancellationToken);
        try
        {
            try
            {
                var current = await GetProjectSnapshotAsync(project, cancellationToken);
                ValidateExpectedRevision(parameters.ExpectedRevision, current.AuthoringRevision, "script_source_revision_conflict");
                if (_scriptSourceHistory.Count == 0) throw new EditorOperationException("script_source_undo_empty", "There is no script source mutation to undo.");
                var record = _scriptSourceHistory[^1];
                if (!string.Equals(record.ProjectName, project.ProjectName, StringComparison.OrdinalIgnoreCase)
                    || !string.Equals(record.RevisionAfter, current.AuthoringRevision, StringComparison.OrdinalIgnoreCase))
                    throw new EditorOperationException("script_source_history_diverged", "Script source history no longer matches the current revision.");
                var commit = await _scriptSourceAuthoringModel.UndoAsync(project, parameters.ExpectedRevision, record.Token, cancellationToken);
                if (commit.State != "succeeded") throw new EditorOperationException("script_source_protocol_error", "Script source undo did not restore a changed state.");
                _scriptSourceHistory.RemoveAt(_scriptSourceHistory.Count - 1);
                return await CreateScriptSourceResultAsync("undo", project, record.Token.ScriptId, commit, _scriptSourceHistory.Count, cancellationToken);
            }
            catch (WorkspaceAuthoringException exception) { throw MapScriptSourceError(exception); }
        }
        finally { _authoringGate.Release(); }
    }

    public Task<ScriptAssetMutationResult> CreateScriptAssetAsync(
        ProjectSessionInfo project,
        ScriptAssetCreateParameters parameters,
        CancellationToken cancellationToken) =>
        MutateScriptAssetAsync(project, "create", parameters.ExpectedRevision,
            token => _scriptAssetLifecycleModel.CreateAsync(project, parameters.ExpectedRevision, parameters.SourcePath, token), cancellationToken);

    public Task<ScriptAssetMutationResult> RenameScriptAssetAsync(
        ProjectSessionInfo project,
        ScriptAssetRenameParameters parameters,
        CancellationToken cancellationToken) =>
        MutateScriptAssetAsync(project, "rename", parameters.ExpectedRevision,
            token => _scriptAssetLifecycleModel.RenameAsync(project, parameters.ExpectedRevision, parameters.ScriptId, parameters.SourcePath, token), cancellationToken);

    public Task<ScriptAssetMutationResult> DeleteScriptAssetAsync(
        ProjectSessionInfo project,
        ScriptAssetDeleteParameters parameters,
        CancellationToken cancellationToken) =>
        MutateScriptAssetAsync(project, "delete", parameters.ExpectedRevision,
            token => _scriptAssetLifecycleModel.DeleteAsync(project, parameters.ExpectedRevision, parameters.ScriptId, token), cancellationToken);

    public async Task<ScriptAssetMutationResult> UndoScriptAssetAsync(
        ProjectSessionInfo project,
        ScriptAssetUndoParameters parameters,
        CancellationToken cancellationToken)
    {
        await _authoringGate.WaitAsync(cancellationToken);
        try
        {
            if (_scriptAssetHistory.Count == 0)
                throw new EditorOperationException("script_asset_history_empty", "There is no Script Asset lifecycle mutation to undo.");
            var current = await GetProjectSnapshotAsync(project, cancellationToken);
            ValidateExpectedRevision(parameters.ExpectedRevision, current.AuthoringRevision, "script_asset_revision_conflict");
            var record = _scriptAssetHistory[^1];
            if (!record.ProjectName.Equals(project.ProjectName, StringComparison.OrdinalIgnoreCase)
                || !record.RevisionAfter.Equals(current.AuthoringRevision, StringComparison.OrdinalIgnoreCase))
            {
                throw new EditorOperationException("script_asset_history_diverged", "Script Asset lifecycle history no longer matches the current revision.");
            }
            try
            {
                var assets = await GetAssetCatalogSnapshotAsync(project, cancellationToken);
                var commit = await _scriptAssetLifecycleModel.UndoAsync(project, parameters.ExpectedRevision, record.Token, cancellationToken);
                _scriptAssetHistory.RemoveAt(_scriptAssetHistory.Count - 1);
                return CreateScriptAssetResult("undo", project, commit, _scriptAssetHistory.Count, assets);
            }
            catch (WorkspaceScriptAssetLifecycleException exception) { throw MapScriptAssetError(exception); }
        }
        finally { _authoringGate.Release(); }
    }

    private async Task<ScriptAssetMutationResult> MutateScriptAssetAsync(
        ProjectSessionInfo project,
        string operation,
        string expectedRevision,
        Func<CancellationToken, Task<WorkspaceScriptAssetLifecycleCommit>> mutation,
        CancellationToken cancellationToken)
    {
        await _authoringGate.WaitAsync(cancellationToken);
        try
        {
            try
            {
                var assets = await GetAssetCatalogSnapshotAsync(project, cancellationToken);
                var commit = await mutation(cancellationToken);
                if (commit.State == "unchanged")
                    return CreateScriptAssetResult(operation, project, commit, _scriptAssetHistory.Count, assets);
                if (commit.UndoToken is null)
                    throw new EditorOperationException("script_asset_protocol_error", "Script Asset lifecycle commit emitted no undo token.");
                _scriptAssetHistory.Add(new ScriptAssetUndoRecord(project.ProjectName, commit.Revision, commit.UndoToken));
                if (_scriptAssetHistory.Count > MaxAuthoringHistory) _scriptAssetHistory.RemoveAt(0);
                return CreateScriptAssetResult(operation, project, commit, _scriptAssetHistory.Count, assets);
            }
            catch (WorkspaceScriptAssetLifecycleException exception) { throw MapScriptAssetError(exception); }
        }
        finally { _authoringGate.Release(); }
    }

    private static ScriptAssetMutationResult CreateScriptAssetResult(
        string operation,
        ProjectSessionInfo project,
        WorkspaceScriptAssetLifecycleCommit commit,
        int undoDepth,
        AssetCatalogSnapshot assets)
    {
        ValidateSnapshot(project, commit.ProjectSnapshot);
        ValidateSnapshot(project, commit.HierarchySnapshot);
        ValidateSnapshot(project, assets);
        var source = commit.SourceDocument is null ? null : new ScriptSourceDocument(
            commit.SourceDocument.ProjectName,
            commit.SourceDocument.ScriptId,
            commit.SourceDocument.SourcePath,
            commit.SourceDocument.Source,
            commit.SourceDocument.AuthoringRevision);
        return new ScriptAssetMutationResult(
            operation,
            commit.State,
            project.ProjectName,
            commit.PreviousRevision,
            commit.Revision,
            commit.ChangedFields,
            undoDepth,
            new ScriptAssetIdentity(commit.Asset.ScriptId, commit.Asset.SourcePath),
            source,
            commit.ProjectSnapshot,
            commit.HierarchySnapshot,
            assets);
    }

    internal static EditorOperationException MapScriptAssetError(WorkspaceScriptAssetLifecycleException exception) =>
        new(exception.Kind switch
        {
            WorkspaceScriptAssetLifecycleFailureKind.InvalidExpectedRevision => "invalid_expected_revision",
            WorkspaceScriptAssetLifecycleFailureKind.Unsupported => "script_asset_unsupported",
            WorkspaceScriptAssetLifecycleFailureKind.InvalidPath => "invalid_script_asset_path",
            WorkspaceScriptAssetLifecycleFailureKind.NotFound => "script_asset_not_found",
            WorkspaceScriptAssetLifecycleFailureKind.Conflict => "script_asset_conflict",
            WorkspaceScriptAssetLifecycleFailureKind.LimitReached => "script_asset_limit_reached",
            WorkspaceScriptAssetLifecycleFailureKind.LastDependency => "script_asset_last_dependency",
            WorkspaceScriptAssetLifecycleFailureKind.InUse => "script_asset_in_use",
            WorkspaceScriptAssetLifecycleFailureKind.RevisionConflict => "script_asset_revision_conflict",
            WorkspaceScriptAssetLifecycleFailureKind.HistoryDiverged => "script_asset_history_diverged",
            WorkspaceScriptAssetLifecycleFailureKind.Commit => "script_asset_commit_failed",
            WorkspaceScriptAssetLifecycleFailureKind.Invariant => "script_asset_protocol_error",
            WorkspaceScriptAssetLifecycleFailureKind.Input => "script_asset_commit_failed",
            _ => "script_asset_protocol_error"
        }, exception.Message);
    public async Task<EditorBakeResult> BakeAsync(ProjectSessionInfo project, BakeStartParameters parameters, CancellationToken cancellationToken)
    {
        await _bakeGate.WaitAsync(cancellationToken);
        try
        {
            try { return await _publicationModel.BakeAsync(project, parameters, cancellationToken); }
            catch (WorkspacePublicationException exception)
            {
                var code = exception.Kind switch
                {
                    WorkspacePublicationFailureKind.InvalidTarget => "invalid_bake_target",
                    WorkspacePublicationFailureKind.InvalidProfile => "invalid_bake_profile",
                    WorkspacePublicationFailureKind.Validation => "bake_validation_failed",
                    WorkspacePublicationFailureKind.SourceChanged => "source_changed_during_bake",
                    WorkspacePublicationFailureKind.Promote => "artifact_promote_failed",
                    WorkspacePublicationFailureKind.Invariant => "live_bake_failed",
                    _ => "live_bake_failed"
                };
                throw new EditorOperationException(code, exception.Message);
            }
        }
        finally { _bakeGate.Release(); }
    }

    public async Task<EditorWatchResult> StartWatchAsync(ProjectSessionInfo project, WatchStartParameters parameters, CancellationToken cancellationToken)
    {
        var target = NormalizeTarget(parameters.Target);
        var profile = NormalizeProfile(parameters.Profile);
        if (parameters.PollIntervalMilliseconds is < 25 or > 2000) { throw new EditorOperationException("invalid_poll_interval", "Poll interval must be between 25 and 2000 ms."); }
        if (parameters.DebounceMilliseconds is < 50 or > 5000) { throw new EditorOperationException("invalid_debounce", "Debounce must be between 50 and 5000 ms."); }

        await _watchGate.WaitAsync(cancellationToken);
        try
        {
            if (_watch is { IsRunning: true }) { throw new EditorOperationException("watch_already_running", "Live bake watch is already running."); }
            var initial = await BakeAsync(project, new BakeStartParameters(target, profile), cancellationToken);
            _watch = new LiveBakeWatchController(
                project,
                new WatchStartParameters(target, profile, parameters.PollIntervalMilliseconds, parameters.DebounceMilliseconds),
                (nextTarget, token) => BakeAsync(project, new BakeStartParameters(nextTarget, profile), token),
                PublishWatchNotificationAsync);
            _watchProjectName = project.ProjectName;
            _watchTarget = target;
            _watchProfile = profile;
            _watch.Start();
            return new EditorWatchResult("watching", project.ProjectName, target, profile, initial);
        }
        finally { _watchGate.Release(); }
    }

    public async Task<EditorWatchResult> StopWatchAsync(CancellationToken cancellationToken)
    {
        await _watchGate.WaitAsync(cancellationToken);
        try
        {
            if (_watch is not null) { await _watch.StopAsync(); await _watch.DisposeAsync(); _watch = null; }
            return new EditorWatchResult("stopped", _watchProjectName, _watchTarget, _watchProfile, null);
        }
        finally { _watchGate.Release(); }
    }

    private async Task PublishWatchNotificationAsync(EditorSessionNotification notification)
    {
        var handler = Notification;
        if (handler is not null) { await handler(notification); }
    }

    private static async Task<T> ReadWorkspaceSnapshotAsync<T>(Func<Task<T>> read, ProjectSessionInfo project, bool publication)
    {
        try
        {
            var snapshot = await read();
            ValidateSnapshot(project, snapshot);
            return snapshot;
        }
        catch (WorkspaceReadException exception)
        {
            var code = exception.Kind == WorkspaceReadFailureKind.Invariant
                ? publication ? "publication_snapshot_protocol_error" : "snapshot_protocol_error"
                : publication ? "publication_snapshot_failed" : "snapshot_failed";
            throw new EditorOperationException(code, exception.Message);
        }
    }

    private async Task<WorkspaceAuthoringCommit> ApplyWorkspaceAuthoringAsync(
        ProjectSessionInfo project,
        string expectedRevision,
        AuthoringPatch? patch,
        CancellationToken cancellationToken)
    {
        try { return await _authoringModel.ApplyAsync(project, expectedRevision, patch, cancellationToken); }
        catch (WorkspaceAuthoringException exception)
        {
            var code = exception.Kind switch
            {
                WorkspaceAuthoringFailureKind.InvalidExpectedRevision => "invalid_expected_revision",
                WorkspaceAuthoringFailureKind.RevisionConflict => "authoring_revision_conflict",
                WorkspaceAuthoringFailureKind.InvalidPatch => "invalid_authoring_patch",
                WorkspaceAuthoringFailureKind.Input or WorkspaceAuthoringFailureKind.Commit => "authoring_update_failed",
                WorkspaceAuthoringFailureKind.Invariant => "authoring_protocol_error",
                _ => "authoring_update_failed"
            };
            throw new EditorOperationException(code, exception.Message);
        }
    }

    private async Task<ScriptSourceMutationResult> CreateScriptSourceResultAsync(
        string operation,
        ProjectSessionInfo project,
        uint scriptId,
        WorkspaceScriptSourceAuthoringCommit commit,
        int undoDepth,
        CancellationToken cancellationToken)
    {
        var document = await GetScriptSourceAsync(project, new ScriptSourceQueryParameters(project.ProjectName, scriptId), cancellationToken);
        return new ScriptSourceMutationResult(operation, commit.State, project.ProjectName, commit.PreviousRevision, commit.Revision,
            commit.ChangedFields, undoDepth, document, commit.ProjectSnapshot, commit.HierarchySnapshot);
    }

    private static EditorOperationException MapScriptSourceError(WorkspaceAuthoringException exception) =>
        new(exception.Kind switch
        {
            WorkspaceAuthoringFailureKind.InvalidExpectedRevision => "invalid_expected_revision",
            WorkspaceAuthoringFailureKind.RevisionConflict => "script_source_revision_conflict",
            WorkspaceAuthoringFailureKind.InvalidPatch => "invalid_script_source",
            WorkspaceAuthoringFailureKind.Input => "script_source_read_failed",
            WorkspaceAuthoringFailureKind.Commit => "script_source_commit_failed",
            WorkspaceAuthoringFailureKind.Invariant => "script_source_protocol_error",
            _ => "script_source_failed"
        }, exception.Message);

    private async Task<WorkspaceAuthoringCommit> UndoWorkspaceAuthoringAsync(
        ProjectSessionInfo project,
        string expectedRevision,
        WorkspaceAuthoringUndoToken token,
        CancellationToken cancellationToken)
    {
        try { return await _authoringModel.UndoAsync(project, expectedRevision, token, cancellationToken); }
        catch (WorkspaceAuthoringException exception)
        {
            var code = exception.Kind switch
            {
                WorkspaceAuthoringFailureKind.InvalidExpectedRevision => "invalid_expected_revision",
                WorkspaceAuthoringFailureKind.RevisionConflict => "authoring_revision_conflict",
                WorkspaceAuthoringFailureKind.Input or WorkspaceAuthoringFailureKind.Commit => "authoring_update_failed",
                WorkspaceAuthoringFailureKind.InvalidPatch or WorkspaceAuthoringFailureKind.Invariant => "authoring_protocol_error",
                _ => "authoring_protocol_error"
            };
            throw new EditorOperationException(code, exception.Message);
        }
    }

    internal static void ValidateSnapshot<T>(ProjectSessionInfo project, T snapshot)
    {
        switch (snapshot)
        {
            case ProjectModelSnapshot model:
                var sceneModel = model.Scene;
                var textures = sceneModel?.Textures;
                var objects = sceneModel?.Objects;
                var scriptDependencies = model.Script?.Dependencies;
                var gameplayEnabled = sceneModel?.GameplayProfile == "goal_hazard_v1";
                var gameplayContractValid = sceneModel is not null && sceneModel.GameplayProfile switch
                {
                    "none" => SceneSchemaHasExplicitGameplay(sceneModel.SchemaVersion) && sceneModel.GameplayTimeLimitSeconds is null,
                    "goal_hazard_v1" => (sceneModel.SchemaVersion <= 6 && sceneModel.GameplayTimeLimitSeconds is null)
                        || (sceneModel.GameplayTimeLimitSeconds is double limit && limit > 0 && double.IsFinite(limit)),
                    _ => false
                };
                var textureSetValid = sceneModel is not null && textures is { Count: >= 1 and <= 4 }
                    && textures.All(texture => texture.TextureId != 0
                        && IsTextureArtifactPath(texture.Artifact)
                        && (sceneModel.SchemaVersion < 8
                            ? texture.SamplingProfile == "smooth_mipmap_anisotropic"
                            : IsTextureSamplingProfile(texture.SamplingProfile)))
                    && textures.Select(texture => texture.TextureId).Distinct().Count() == textures.Count
                    && (!gameplayEnabled
                        || textures.Any(texture => texture.TextureId == sceneModel.PlayerTextureId)
                        && textures.Any(texture => texture.TextureId == sceneModel.GoalTextureId)
                        && textures.Any(texture => texture.TextureId == sceneModel.HazardTextureId));
                var behaviorDependencySetValid = model.Script?.SchemaVersion == 2
                    && scriptDependencies is { Count: >= 1 and <= 16 }
                    && scriptDependencies.All(dependency => dependency.ScriptId != 0 && IsScriptSourcePath(dependency.Source))
                    && scriptDependencies.Select(dependency => dependency.ScriptId).Distinct().Count() == scriptDependencies.Count
                    && scriptDependencies.Select(dependency => dependency.Source).Distinct(StringComparer.Ordinal).Count() == scriptDependencies.Count;
                if (model is null || model.Files is null || model.Scene is null || model.Script is null || model.Preview is null
                    || model.Scene.GoalPosition is null || model.Script.GoalPosition is null || model.Script.GoalVelocity is null
                    // Revision 是 authoring transaction 的并发令牌，非法值必须在跨越 backend seam 前被拒绝。
                    || string.IsNullOrWhiteSpace(model.AuthoringRevision)
                    || model.AuthoringRevision.Length != 64
                    || model.AuthoringRevision.Any(value => !Uri.IsHexDigit(value))
                    || model.ModelVersion != EditorSnapshotVersions.ProjectModel
                    || !IsSupportedSceneSchema(model.Scene.SchemaVersion)
                    || !gameplayContractValid
                    || !textureSetValid
                    || !ValidateSceneObjects(objects, textures!, sceneModel!, behaviorDependencySetValid ? scriptDependencies!.Select(dependency => dependency.ScriptId).ToHashSet() : null)
                    || !ValidateSceneTilemaps(sceneModel!.Tilemaps, textures!, sceneModel.SchemaVersion)
                    || !ValidateSceneCamera(sceneModel.Camera, sceneModel.SchemaVersion)
                    || model.Script.SchemaVersion is not (1 or 2)
                    || model.Preview.SchemaVersion != 1
                    || !string.Equals(model.ProjectName, project.ProjectName, StringComparison.OrdinalIgnoreCase)
                    || model.Scene.GoalPosition.Length != (gameplayEnabled ? 2 : 0)
                    || model.Script.SchemaVersion == 1 && (model.Script.GoalPosition.Length != 2 || model.Script.GoalVelocity.Length != 2)
                    || model.Script.SchemaVersion == 2 && (!behaviorDependencySetValid || model.Script.GoalPosition.Length != 0 || model.Script.GoalVelocity.Length != 0)
                    || !model.Scene.GoalPosition.Concat(model.Script.GoalPosition).Concat(model.Script.GoalVelocity).All(double.IsFinite))
                {
                    throw new EditorOperationException("snapshot_protocol_error", "Project snapshot version, project name, or vector shape is invalid.");
                }
                break;
            case HierarchySnapshot hierarchy:
                if (hierarchy is null || hierarchy.Nodes is null
                    || hierarchy.SnapshotVersion != EditorSnapshotVersions.Hierarchy
                    || hierarchy.ProjectModelVersion != EditorSnapshotVersions.ProjectModel
                    || !string.Equals(hierarchy.ProjectName, project.ProjectName, StringComparison.OrdinalIgnoreCase)
                    || hierarchy.Nodes.Length > 4096)
                {
                    throw new EditorOperationException("snapshot_protocol_error", "Hierarchy snapshot version or size is invalid.");
                }
                var ids = new HashSet<string>(StringComparer.Ordinal);
                foreach (var node in hierarchy.Nodes)
                {
                    if (node is null || string.IsNullOrWhiteSpace(node.Id) || !ids.Add(node.Id)
                        || (node.ParentId is not null && !ids.Contains(node.ParentId)))
                    {
                        throw new EditorOperationException("snapshot_protocol_error", "Hierarchy node identity/order is invalid.");
                    }
                }
                break;
            case AssetCatalogSnapshot assets:
                if (assets is null || assets.Items is null
                    || assets.CatalogVersion != EditorSnapshotVersions.AssetCatalog
                    || !string.Equals(assets.Root.Replace('\\', '/'), "bin/assets", StringComparison.Ordinal)
                    || assets.ItemCount != assets.Items.Length
                    || assets.Items.Length > 4096)
                {
                    throw new EditorOperationException("snapshot_protocol_error", "Asset catalog version, root, or count is invalid.");
                }
                foreach (var item in assets.Items)
                {
                    var relative = item.RelativePath.Replace('\\', '/');
                    if (!relative.StartsWith("assets/", StringComparison.Ordinal)
                        || Path.IsPathRooted(relative)
                        || relative.Split('/').Any(part => part == ".."))
                    {
                        throw new EditorOperationException("snapshot_protocol_error", "Asset catalog path escapes bin/assets.");
                    }
                }
                break;
            case PublicationSnapshot publication:
                if (publication is null
                    || publication.SnapshotVersion != EditorSnapshotVersions.Publication
                    || !string.Equals(publication.ProjectName, project.ProjectName, StringComparison.OrdinalIgnoreCase)
                    || publication.Profile is not ("debug" or "release")
                    || (publication.ManifestProfile is not null && publication.ManifestProfile is not ("debug" or "release")))
                {
                    throw new EditorOperationException("publication_snapshot_protocol_error", "Publication snapshot identity or profile is invalid.");
                }
                ValidatePublicationPath(project.ProjectDirectory, publication.DerivedDirectory, "derived directory");
                ValidatePublicationPath(project.ProjectDirectory, publication.ManifestPath, "manifest path");
                ValidatePublicationTarget(publication.Scene, "Scene");
                ValidatePublicationTarget(publication.Script, "Script");
                var publicationStates = new[] { publication.Scene.State, publication.Script.State };
                var expectedPublicationState = publicationStates.Contains("artifact_invalid", StringComparer.Ordinal) ? "artifact_invalid"
                    : publicationStates.Contains("missing", StringComparer.Ordinal) ? "missing"
                    : publicationStates.Contains("profile_mismatch", StringComparer.Ordinal) ? "profile_mismatch"
                    : publicationStates.Contains("source_dirty", StringComparer.Ordinal) ? "source_dirty"
                    : "current";
                if (!string.Equals(publication.State, expectedPublicationState, StringComparison.Ordinal))
                {
                    throw new EditorOperationException("publication_snapshot_protocol_error", "Publication aggregate state does not match target states.");
                }
                break;
            default:
                throw new EditorOperationException("snapshot_protocol_error", "Unknown snapshot DTO.");
        }
    }

    private static bool IsTextureArtifactPath(string artifact)
    {
        if (string.IsNullOrEmpty(artifact) || System.Text.Encoding.UTF8.GetByteCount(artifact) > 255
            || !artifact.StartsWith("assets/renderer2d/", StringComparison.Ordinal)
            || !artifact.EndsWith(".texture", StringComparison.Ordinal)
            || artifact.Contains('\\'))
        {
            return false;
        }
        return artifact.Split('/').All(segment => segment.Length > 0 && segment is not "." and not "..");
    }

    private static bool IsTextureSamplingProfile(string value) => value is
        "pixel_art" or "smooth_linear" or "smooth_mipmap" or "smooth_mipmap_anisotropic";

    private static bool IsSupportedSceneSchema(int schemaVersion) => schemaVersion is >= 3 and <= 9;
    private static bool SceneSchemaHasExplicitGameplay(int schemaVersion) => schemaVersion is >= 7 and <= 9;
    private static bool SceneSchemaHasBehaviorBindings(int schemaVersion) => schemaVersion is >= 5 and <= 9;

    private static bool ValidateSceneTilemaps(
        IReadOnlyList<ProjectModelSceneTilemap>? tilemaps,
        IReadOnlyList<ProjectModelTexture> textures,
        int schemaVersion)
    {
        if (tilemaps is null) return false;
        if (schemaVersion < 8) return tilemaps.Count == 0;
        if (tilemaps.Count > 1) return false;
        var textureProfiles = textures.ToDictionary(value => value.TextureId, value => value.SamplingProfile);
        foreach (var tilemap in tilemaps)
        {
            if (!IsObjectId(tilemap.TilemapId)
                || tilemap.Origin is not { Length: 2 }
                || tilemap.TileSize is not { Length: 2 }
                || !tilemap.Origin.Concat(tilemap.TileSize).All(number => double.IsFinite(number) && float.IsFinite((float)number))
                || tilemap.TileSize.Any(number => number <= 0)
                || tilemap.Columns is < 1 or > 32 || tilemap.Rows is < 1 or > 32
                || tilemap.AtlasColumns is < 1 or > 256 || tilemap.AtlasRows is < 1 or > 256
                || tilemap.AtlasColumns * tilemap.AtlasRows > ushort.MaxValue
                || tilemap.Cells is null || tilemap.Cells.Count != tilemap.Columns * tilemap.Rows
                || tilemap.Cells.Any(value => value < 0 || value > tilemap.AtlasColumns * tilemap.AtlasRows)
                || !textureProfiles.TryGetValue(tilemap.TextureId, out var samplingProfile)
                || samplingProfile != "pixel_art") return false;
        }
        return true;
    }

    private static bool ValidateSceneCamera(ProjectModelSceneCamera? camera, int schemaVersion)
    {
        // 旧协议调用方可省略 Camera；在 v3-v8 中它等价于恒等视图。
        if (camera is null) return schemaVersion < 9;
        if (camera.Origin is not { Length: 2 }
            || !camera.Origin.All(number => double.IsFinite(number) && float.IsFinite((float)number))
            || !double.IsFinite(camera.Zoom) || !float.IsFinite((float)camera.Zoom)
            || camera.Zoom is < 0.125 or > 8) return false;
        return schemaVersion == 9
            || camera.Origin.SequenceEqual([0d, 0d]) && camera.Zoom == 1;
    }

    private static bool IsScriptSourcePath(string source)
    {
        if (string.IsNullOrEmpty(source) || System.Text.Encoding.UTF8.GetByteCount(source) > 1024
            || !source.StartsWith("scripts/", StringComparison.Ordinal)
            || !source.EndsWith(".luau", StringComparison.Ordinal)
            || source.Contains('\\') || source.Contains('\0'))
        {
            return false;
        }
        return source.Split('/').All(segment => segment.Length > 0 && segment is not "." and not "..");
    }

    private static bool ValidateSceneObjects(
        IReadOnlyList<ProjectModelSceneObject>? objects,
        IReadOnlyList<ProjectModelTexture> textures,
        ProjectModelScene scene,
        IReadOnlySet<uint>? behaviorScriptIds)
    {
        var gameplayEnabled = scene.GameplayProfile == "goal_hazard_v1";
        var minimumObjectCount = SceneSchemaHasExplicitGameplay(scene.SchemaVersion) && !gameplayEnabled ? 1 : 3;
        if (objects is null || objects.Count < minimumObjectCount || objects.Count > 64) return false;
        var textureIds = textures.Select(value => value.TextureId).ToHashSet();
        var objectIds = new HashSet<string>(StringComparer.Ordinal);
        var players = objects.Where(value => value.Kind == "player").ToArray();
        var goals = objects.Where(value => value.Kind == "goal").ToArray();
        var hazards = objects.Where(value => value.Kind == "patrol_hazard").ToArray();
        if (gameplayEnabled && (players.Length != 1 || goals.Length != 1 || hazards.Length < 1)) return false;
        foreach (var value in objects)
        {
            if (!IsObjectId(value.ObjectId) || !objectIds.Add(value.ObjectId)
                || value.Kind is not ("sprite" or "player" or "goal" or "patrol_hazard")
                || value.Position is not { Length: 2 } || value.Size is not { Length: 2 } || value.Color is not { Length: 4 }
                || !value.Position.Concat(value.Size).Concat(value.Color).All(number => double.IsFinite(number) && float.IsFinite((float)number))
                || value.Size.Any(number => number <= 0) || value.Color.Any(number => number is < 0 or > 1)
                || value.TextureId == 0 || !textureIds.Contains(value.TextureId))
            {
                return false;
            }
            if (value.Kind == "player")
            {
                if (value.MoveSpeed is null || value.MoveSpeed < 0 || !double.IsFinite(value.MoveSpeed.Value)
                    || value.PatrolMinY is not null || value.PatrolMaxY is not null || value.PatrolSpeed is not null) return false;
            }
            if (SceneSchemaHasBehaviorBindings(scene.SchemaVersion))
            {
                if (value.PatrolMinY is not null || value.PatrolMaxY is not null || value.PatrolSpeed is not null
                    || value.Behaviors is null || value.Behaviors.Count > 4)
                {
                    return false;
                }
                var bindingIds = new HashSet<uint>();
                foreach (var binding in value.Behaviors)
                {
                    if (behaviorScriptIds is null || binding.ScriptId == 0 || !behaviorScriptIds.Contains(binding.ScriptId)
                        || !bindingIds.Add(binding.ScriptId)
                        || binding.Parameters is not { Count: <= 16 }) return false;
                    var parameterNames = new HashSet<string>(StringComparer.Ordinal);
                    foreach (var parameter in binding.Parameters)
                    {
                        if (!IsBehaviorParameterName(parameter.Name) || !parameterNames.Add(parameter.Name)
                            || !double.IsFinite(parameter.Value) || !float.IsFinite((float)parameter.Value)) return false;
                    }
                }
                if (gameplayEnabled && value.Kind == "patrol_hazard" && value.Behaviors.Count == 0) return false;
            }
            else
            {
                if (value.Behaviors is { Count: > 0 }) return false;
                if (value.Kind == "patrol_hazard")
                {
                    if (value.MoveSpeed is not null || value.PatrolMinY is null || value.PatrolMaxY is null || value.PatrolSpeed is null
                        || !double.IsFinite(value.PatrolMinY.Value) || !double.IsFinite(value.PatrolMaxY.Value) || !double.IsFinite(value.PatrolSpeed.Value)
                        || value.PatrolMinY >= value.PatrolMaxY || value.PatrolSpeed < 0
                        || value.Position[1] < value.PatrolMinY || value.Position[1] > value.PatrolMaxY) return false;
                }
                else if (value.Kind != "player" && (value.MoveSpeed is not null || value.PatrolMinY is not null || value.PatrolMaxY is not null || value.PatrolSpeed is not null))
                {
                    return false;
                }
            }
        }
        return !gameplayEnabled
            || scene.PlayerTextureId == players[0].TextureId
            && scene.GoalTextureId == goals[0].TextureId
            && scene.HazardTextureId == hazards[0].TextureId
            && scene.GoalPosition.SequenceEqual(goals[0].Position);
    }

    private static bool IsObjectId(string value)
    {
        if (string.IsNullOrEmpty(value) || System.Text.Encoding.UTF8.GetByteCount(value) is < 1 or > 63 || value[0] is < 'a' or > 'z') return false;
        return value.Skip(1).All(character => character is >= 'a' and <= 'z' or >= '0' and <= '9' or '_' or '-');
    }

    private static bool IsBehaviorParameterName(string value)
    {
        if (string.IsNullOrEmpty(value) || System.Text.Encoding.UTF8.GetByteCount(value) is < 1 or > 63
            || !IsIdentifierStart(value[0])) return false;
        return value.Skip(1).All(character => IsIdentifierStart(character) || character is >= '0' and <= '9');
    }

    private static bool IsIdentifierStart(char value) => value is >= 'A' and <= 'Z' or >= 'a' and <= 'z' or '_';

    private static void ValidatePublicationTarget(PublicationTargetSnapshot target, string expectedTarget)
    {
        if (target is null || !string.Equals(target.Target, expectedTarget, StringComparison.Ordinal)
            || target.State is not ("current" or "source_dirty" or "missing" or "artifact_invalid" or "profile_mismatch"))
        {
            throw new EditorOperationException("publication_snapshot_protocol_error", $"{expectedTarget} publication target is invalid.");
        }
        foreach (var revision in new[] { target.SourceRevision, target.BakedSourceRevision, target.ArtifactRevision, target.ManifestArtifactRevision })
        {
            if (revision is not null && (revision.Length != 64 || revision.Any(value => !Uri.IsHexDigit(value))))
            {
                throw new EditorOperationException("publication_snapshot_protocol_error", $"{expectedTarget} publication revision is invalid.");
            }
        }
        foreach (var bytes in new[] { target.ArtifactBytes, target.ManifestArtifactBytes })
        {
            if (bytes is < 0)
            {
                throw new EditorOperationException("publication_snapshot_protocol_error", $"{expectedTarget} publication byte count is invalid.");
            }
        }
        if (target.State == "current"
            && (target.SourceRevision is null || target.BakedSourceRevision is null
                || target.ArtifactRevision is null || target.ManifestArtifactRevision is null
                || target.ArtifactBytes is null || target.ManifestArtifactBytes is null
                || !string.Equals(target.SourceRevision, target.BakedSourceRevision, StringComparison.OrdinalIgnoreCase)
                || !string.Equals(target.ArtifactRevision, target.ManifestArtifactRevision, StringComparison.OrdinalIgnoreCase)
                || target.ArtifactBytes != target.ManifestArtifactBytes))
        {
            throw new EditorOperationException("publication_snapshot_protocol_error", $"{expectedTarget} current state lacks matching revision evidence.");
        }
    }

    private static void ValidatePublicationPath(string projectDirectory, string path, string label)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            throw new EditorOperationException("publication_snapshot_protocol_error", $"{label} is empty.");
        }
        var full = Path.GetFullPath(path);
        var prefix = projectDirectory.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;
        if (!full.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)
            || full.Contains($"{Path.DirectorySeparatorChar}bin{Path.DirectorySeparatorChar}assets{Path.DirectorySeparatorChar}", StringComparison.OrdinalIgnoreCase))
        {
            throw new EditorOperationException("publication_snapshot_protocol_error", $"{label} escapes the project derived directory.");
        }
    }
    private static void ValidateExpectedRevision(string expected, string current, string conflictCode = "authoring_revision_conflict")
    {
        if (string.IsNullOrWhiteSpace(expected) || expected.Length != 64 || expected.Any(value => !Uri.IsHexDigit(value)))
        {
            throw new EditorOperationException("invalid_expected_revision", "ExpectedRevision must be a SHA-256 hex value.");
        }
        if (!expected.Equals(current, StringComparison.OrdinalIgnoreCase))
        {
            throw new EditorOperationException(conflictCode, $"Expected {expected} but current revision is {current}.");
        }
    }

    private sealed record AuthoringUndoRecord(
        string ProjectName,
        string RevisionAfter,
        string[] ChangedFields,
        WorkspaceAuthoringUndoToken Token);

    private sealed record ScriptSourceUndoRecord(
        string ProjectName,
        string RevisionAfter,
        string[] ChangedFields,
        WorkspaceScriptSourceUndoToken Token);

    private sealed record ScriptAssetUndoRecord(
        string ProjectName,
        string RevisionAfter,
        WorkspaceScriptAssetLifecycleUndoToken Token);
    private static string NormalizeTarget(string target) => target.ToLowerInvariant() switch
    {
        "scene" => "Scene",
        "script" => "Script",
        "both" => "Both",
        _ => throw new EditorOperationException("invalid_bake_target", $"Unsupported bake target: {target}")
    };

    private static string NormalizeProfile(string profile) => profile.ToLowerInvariant() switch
    {
        "debug" => "debug",
        "release" => "release",
        _ => throw new EditorOperationException("invalid_bake_profile", $"Unsupported bake profile: {profile}")
    };

    public async ValueTask DisposeAsync()
    {
        await StopWatchAsync(CancellationToken.None);
        _bakeGate.Dispose();
        _watchGate.Dispose();
        _authoringGate.Dispose();
        _scriptAnalysisGate.Dispose();
    }

}
