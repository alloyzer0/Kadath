using Kadath.Editor.Core;
using Kadath.Editor.Protocol;
using Kadath.Editor.Workspace;

namespace Kadath.Editor.Service;

/// <summary>
/// 把原生 Workspace Module 与仍待迁移的 Preview 兼容路径收进 Backend，RPC/UI 不感知实现细节。
/// </summary>
internal sealed class PowerShellEditorBackend : IEditorSessionBackend
{
    private readonly WorkspaceProjectLifecycleModel _projectLifecycleModel;
    private readonly WorkspaceReadModel _readModel;
    private readonly WorkspaceAuthoringModel _authoringModel;
    private readonly WorkspacePublicationModel _publicationModel;
    private readonly SemaphoreSlim _bakeGate = new(1, 1);
    private readonly SemaphoreSlim _watchGate = new(1, 1);
    private readonly SemaphoreSlim _authoringGate = new(1, 1);
    private readonly List<AuthoringUndoRecord> _authoringHistory = [];
    private const int MaxAuthoringHistory = 32;
    private LiveBakeWatchController? _watch;
    private string _watchProjectName = string.Empty;
    private string _watchTarget = "Both";
    private string _watchProfile = "debug";

    public PowerShellEditorBackend(
        WorkspaceProjectLifecycleModel projectLifecycleModel,
        WorkspaceReadModel readModel,
        WorkspaceAuthoringModel authoringModel,
        WorkspacePublicationModel publicationModel)
    {
        _projectLifecycleModel = projectLifecycleModel;
        _readModel = readModel;
        _authoringModel = authoringModel;
        _publicationModel = publicationModel;
    }

    public event Func<EditorSessionNotification, Task>? Notification;

    public async Task<ProjectSessionInfo> OpenProjectAsync(ProjectOpenParameters parameters, CancellationToken cancellationToken)
    {
        var project = await ExecuteProjectLifecycleAsync(() => _projectLifecycleModel.OpenAsync(parameters, cancellationToken));
        _authoringHistory.Clear();
        return project;
    }

    public async Task<ProjectSessionInfo> CreateProjectAsync(ProjectCreateParameters parameters, CancellationToken cancellationToken)
    {
        var project = await ExecuteProjectLifecycleAsync(() => _projectLifecycleModel.CreateAsync(parameters, cancellationToken));
        _authoringHistory.Clear();
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

    public Task<HierarchySnapshot> GetHierarchySnapshotAsync(ProjectSessionInfo project, CancellationToken cancellationToken) =>
        ReadWorkspaceSnapshotAsync(() => _readModel.ReadHierarchyAsync(project, cancellationToken), project, false);

    public Task<AssetCatalogSnapshot> GetAssetCatalogSnapshotAsync(ProjectSessionInfo project, CancellationToken cancellationToken) =>
        ReadWorkspaceSnapshotAsync(() => _readModel.ReadAssetsAsync(project, cancellationToken), project, false);

    public Task<PublicationSnapshot> GetPublicationSnapshotAsync(ProjectSessionInfo project, PublicationSnapshotQueryParameters parameters, CancellationToken cancellationToken) =>
        ReadWorkspaceSnapshotAsync(() => _readModel.ReadPublicationAsync(project, NormalizeProfile(parameters.Profile), cancellationToken), project, true);
    public async Task<AuthoringMutationResult> ApplyAuthoringAsync(ProjectSessionInfo project, AuthoringApplyParameters parameters, CancellationToken cancellationToken)
    {
        await _authoringGate.WaitAsync(cancellationToken);
        try
        {
            var commit = await ApplyWorkspaceAuthoringAsync(project, parameters.ExpectedRevision, parameters.Patch, cancellationToken);
            if (commit.State == "unchanged")
            {
                return new AuthoringMutationResult("apply", "unchanged", project.ProjectName, commit.PreviousRevision, commit.Revision,
                    [], _authoringHistory.Count, commit.ProjectSnapshot, commit.HierarchySnapshot);
            }

            if (commit.InversePatch is null) { throw new EditorOperationException("authoring_protocol_error", "Native authoring commit emitted no inverse patch."); }
            if (_authoringHistory.Count > 0 && !string.Equals(_authoringHistory[^1].RevisionAfter, commit.PreviousRevision, StringComparison.OrdinalIgnoreCase))
            {
                // 外部编辑使旧 undo 链失去连续性；清理而不是把不相关内容覆盖回来。
                _authoringHistory.Clear();
            }
            _authoringHistory.Add(new AuthoringUndoRecord(project.ProjectName, commit.Revision, commit.ChangedFields, commit.InversePatch));
            if (_authoringHistory.Count > MaxAuthoringHistory) { _authoringHistory.RemoveAt(0); }
            return new AuthoringMutationResult("apply", "succeeded", project.ProjectName, commit.PreviousRevision, commit.Revision,
                commit.ChangedFields, _authoringHistory.Count, commit.ProjectSnapshot, commit.HierarchySnapshot);
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

            var commit = await ApplyWorkspaceAuthoringAsync(project, parameters.ExpectedRevision, record.InversePatch, cancellationToken);
            if (commit.State != "succeeded") { throw new EditorOperationException("authoring_protocol_error", "Native authoring undo did not restore a changed state."); }
            _authoringHistory.RemoveAt(_authoringHistory.Count - 1);
            return new AuthoringMutationResult("undo", "succeeded", project.ProjectName, commit.PreviousRevision, commit.Revision,
                record.ChangedFields, _authoringHistory.Count, commit.ProjectSnapshot, commit.HierarchySnapshot);
        }
        finally { _authoringGate.Release(); }
    }
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

    private static void ValidateSnapshot<T>(ProjectSessionInfo project, T snapshot)
    {
        switch (snapshot)
        {
            case ProjectModelSnapshot model:
                var sceneModel = model.Scene;
                var textures = sceneModel?.Textures;
                var textureSetValid = sceneModel is not null && textures is { Count: >= 1 and <= 4 }
                    && textures.All(texture => texture.TextureId != 0 && IsTextureArtifactPath(texture.Artifact))
                    && textures.Select(texture => texture.TextureId).Distinct().Count() == textures.Count
                    && textures.Any(texture => texture.TextureId == sceneModel.PlayerTextureId)
                    && textures.Any(texture => texture.TextureId == sceneModel.GoalTextureId)
                    && textures.Any(texture => texture.TextureId == sceneModel.HazardTextureId);
                if (model is null || model.Files is null || model.Scene is null || model.Script is null || model.Preview is null
                    || model.Scene.GoalPosition is null || model.Script.GoalPosition is null || model.Script.GoalVelocity is null
                    // Revision 是 authoring transaction 的并发令牌，非法值必须在跨越 backend seam 前被拒绝。
                    || string.IsNullOrWhiteSpace(model.AuthoringRevision)
                    || model.AuthoringRevision.Length != 64
                    || model.AuthoringRevision.Any(value => !Uri.IsHexDigit(value))
                    || model.ModelVersion != EditorSnapshotVersions.ProjectModel
                    || model.Scene.SchemaVersion != 3
                    || !textureSetValid
                    || model.Script.SchemaVersion != 1
                    || model.Preview.SchemaVersion != 1
                    || !string.Equals(model.ProjectName, project.ProjectName, StringComparison.OrdinalIgnoreCase)
                    || model.Scene.GoalPosition.Length != 2
                    || model.Script.GoalPosition.Length != 2
                    || model.Script.GoalVelocity.Length != 2
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
    private static void ValidateExpectedRevision(string expected, string current)
    {
        if (string.IsNullOrWhiteSpace(expected) || expected.Length != 64 || expected.Any(value => !Uri.IsHexDigit(value)))
        {
            throw new EditorOperationException("invalid_expected_revision", "ExpectedRevision must be a SHA-256 hex value.");
        }
        if (!expected.Equals(current, StringComparison.OrdinalIgnoreCase))
        {
            throw new EditorOperationException("authoring_revision_conflict", $"Expected {expected} but current revision is {current}.");
        }
    }

    private sealed record AuthoringUndoRecord(
        string ProjectName,
        string RevisionAfter,
        string[] ChangedFields,
        AuthoringPatch InversePatch);
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
    }

}
