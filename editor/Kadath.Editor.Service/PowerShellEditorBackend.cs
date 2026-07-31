using System.Diagnostics;
using System.Text.Json;
using System.Text.RegularExpressions;
using Kadath.Editor.Core;
using Kadath.Editor.Protocol;

namespace Kadath.Editor.Service;

/// <summary>
/// 把现有 PowerShell authoring/importer 工具收进深模块 Adapter，RPC/UI 不感知脚本参数与派生路径。
/// </summary>
internal sealed class PowerShellEditorBackend : IEditorSessionBackend
{
    private readonly string _kadathRoot;
    private readonly SemaphoreSlim _bakeGate = new(1, 1);
    private readonly SemaphoreSlim _watchGate = new(1, 1);
    private readonly SemaphoreSlim _authoringGate = new(1, 1);
    private readonly List<AuthoringUndoRecord> _authoringHistory = [];
    private const int ProjectAlreadyExistsExitCode = 17;
    private const string ProjectCreateClaimFileName = ".kadath-create-claim";
    private const int MaxAuthoringHistory = 32;
    private LiveBakeWatchController? _watch;
    private string _watchProjectName = string.Empty;
    private string _watchTarget = "Both";
    private string _watchProfile = "debug";

    public PowerShellEditorBackend(string kadathRoot) => _kadathRoot = kadathRoot;

    public event Func<EditorSessionNotification, Task>? Notification;

    public async Task<ProjectSessionInfo> OpenProjectAsync(ProjectOpenParameters parameters, CancellationToken cancellationToken)
    {
        if (!Regex.IsMatch(parameters.ProjectName, "^[A-Za-z0-9][A-Za-z0-9_-]{0,47}$", RegexOptions.CultureInvariant))
        {
            throw new EditorOperationException("invalid_project_name", "Project name contains unsupported characters.");
        }

        var packageRoot = Path.GetFullPath(parameters.PackageRoot);
        if (!Directory.Exists(packageRoot)) { throw new EditorOperationException("package_not_found", $"Package root does not exist: {packageRoot}"); }
        var projectsRoot = Path.GetFullPath(Path.Combine(packageRoot, "bin", "projects"));
        var projectDirectory = Path.GetFullPath(Path.Combine(projectsRoot, parameters.ProjectName));
        var prefix = projectsRoot.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;
        if (!projectDirectory.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) { throw new EditorOperationException("project_path_escape", "Project path escapes package/bin/projects."); }

        var scenePath = Path.Combine(projectDirectory, "scene.json");
        var scriptPath = Path.Combine(projectDirectory, "script.json");
        var previewPath = Path.Combine(projectDirectory, "preview.json");
        foreach (var path in new[] { scenePath, scriptPath, previewPath })
        {
            if (!File.Exists(path)) { throw new EditorOperationException("project_file_missing", $"Project file does not exist: {path}"); }
        }

        var project = new ProjectSessionInfo(packageRoot, parameters.ProjectName, projectDirectory, scenePath, scriptPath, previewPath, 1);
        await ValidateProjectAsync(project, cancellationToken);
        _authoringHistory.Clear();
        return project;
    }

    public async Task<ProjectSessionInfo> CreateProjectAsync(ProjectCreateParameters parameters, CancellationToken cancellationToken)
    {
        if (!Regex.IsMatch(parameters.ProjectName, "^[A-Za-z0-9][A-Za-z0-9_-]{0,47}$", RegexOptions.CultureInvariant))
        {
            throw new EditorOperationException("invalid_project_name", "Project name contains unsupported characters.");
        }

        var packageRoot = Path.GetFullPath(parameters.PackageRoot);
        if (!Directory.Exists(packageRoot)) { throw new EditorOperationException("package_not_found", $"Package root does not exist: {packageRoot}"); }
        var projectsRoot = Path.GetFullPath(Path.Combine(packageRoot, "bin", "projects"));
        var projectDirectory = Path.GetFullPath(Path.Combine(projectsRoot, parameters.ProjectName));
        var prefix = projectsRoot.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;
        if (!projectDirectory.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) { throw new EditorOperationException("project_path_escape", "Project path escapes package/bin/projects."); }

        foreach (var template in new[]
        {
            Path.Combine(packageRoot, "bin", "assets", "scenes", "preview.scene.json"),
            Path.Combine(packageRoot, "bin", "assets", "scripts", "preview.script.json")
        })
        {
            if (!File.Exists(template)) { throw new EditorOperationException("project_template_missing", $"Project template does not exist: {template}"); }
        }

        var ownershipToken = Guid.NewGuid().ToString("N");
        var project = new ProjectSessionInfo(
            packageRoot,
            parameters.ProjectName,
            projectDirectory,
            Path.Combine(projectDirectory, "scene.json"),
            Path.Combine(projectDirectory, "script.json"),
            Path.Combine(projectDirectory, "preview.json"),
            1);
        var output = await RunPowerShellAsync(
            Path.Combine(_kadathRoot, "tools", "editor-author.ps1"),
            ["-Action", "Create", "-PackageRoot", packageRoot, "-ProjectName", parameters.ProjectName, "-OwnershipToken", ownershipToken],
            cancellationToken);
        // 关键错误映射：业务分支只读取精确退出码；Adapter stdout/stderr 永远只是诊断文本。
        if (output.ExitCode == ProjectAlreadyExistsExitCode)
        {
            throw new EditorOperationException("project_already_exists", JoinDiagnostics(output));
        }
        if (output.ExitCode != 0)
        {
            // Adapter 已可能取得 ownership 后失败；Service 只凭相同 token 做兜底清理，绝不触碰竞争方目录。
            CleanupCreatedProjectIfOwned(project, ownershipToken);
            throw new EditorOperationException("project_create_failed", JoinDiagnostics(output));
        }

        try
        {
            _ = ValidateProjectCreateOwnership(project, ownershipToken);
            foreach (var path in new[] { project.ScenePath, project.ScriptPath, project.PreviewPath })
            {
                if (!File.Exists(path)) { throw new EditorOperationException("project_validation_failed", $"Project file does not exist: {path}"); }
            }
            await ValidateProjectAsync(project, cancellationToken);

            // 关键提交前检查：Validate 期间 ownership 可能被替换；只有再次匹配才移除 claim 并移交给 Core。
            var claimPath = ValidateProjectCreateOwnership(project, ownershipToken);
            File.Delete(claimPath);
        }
        catch (Exception exception)
        {
            CleanupCreatedProjectIfOwned(project, ownershipToken);
            throw new EditorOperationException("project_validation_failed", exception.Message);
        }

        _authoringHistory.Clear();
        return project;
    }

    private static string ValidateProjectCreateOwnership(ProjectSessionInfo project, string ownershipToken)
    {
        var expectedDirectory = Path.GetFullPath(project.ProjectDirectory);
        var directory = new DirectoryInfo(expectedDirectory);
        if (!directory.Exists
            || !Path.GetFullPath(directory.FullName).Equals(expectedDirectory, StringComparison.OrdinalIgnoreCase)
            || (directory.Attributes & FileAttributes.ReparsePoint) != 0)
        {
            throw new EditorOperationException("project_validation_failed", "Created project directory is missing, replaced, or a reparse point.");
        }

        var claimPath = Path.GetFullPath(Path.Combine(expectedDirectory, ProjectCreateClaimFileName));
        var directoryPrefix = expectedDirectory.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;
        if (!claimPath.StartsWith(directoryPrefix, StringComparison.OrdinalIgnoreCase) || !File.Exists(claimPath))
        {
            throw new EditorOperationException("project_validation_failed", "Project create ownership claim is missing or outside the expected directory.");
        }

        var claim = new FileInfo(claimPath);
        if ((claim.Attributes & FileAttributes.ReparsePoint) != 0
            || claim.Length != ownershipToken.Length
            || !File.ReadAllText(claimPath).Equals(ownershipToken, StringComparison.Ordinal))
        {
            throw new EditorOperationException("project_validation_failed", "Project create ownership claim does not match this request.");
        }
        return claimPath;
    }

    private static void CleanupCreatedProjectIfOwned(ProjectSessionInfo project, string ownershipToken)
    {
        try
        {
            // 关键回滚边界：删除前复用完整 ownership 校验；缺失、不匹配或 reparse 时宁可保留也绝不误删。
            _ = ValidateProjectCreateOwnership(project, ownershipToken);
            Directory.Delete(project.ProjectDirectory, recursive: true);
        }
        catch
        {
            // 原始失败仍统一映射为 project_validation_failed；安全拒绝清理不能降级成无 token 的递归删除。
        }
    }

    public async Task<ProjectValidateResult> ValidateProjectAsync(ProjectSessionInfo project, CancellationToken cancellationToken)
    {
        var result = await RunPowerShellAsync(
            Path.Combine(_kadathRoot, "tools", "editor-author.ps1"),
            ["-Action", "Validate", "-PackageRoot", project.PackageRoot, "-ProjectName", project.ProjectName],
            cancellationToken);
        if (result.ExitCode != 0)
        {
            throw new EditorOperationException("project_validation_failed", JoinDiagnostics(result));
        }
        return new ProjectValidateResult("valid", project.ProjectName, result.Stdout);
    }

    public Task<ProjectModelSnapshot> GetProjectSnapshotAsync(ProjectSessionInfo project, CancellationToken cancellationToken) =>
        ReadSnapshotAsync<ProjectModelSnapshot>(project, "Project", cancellationToken);

    public Task<HierarchySnapshot> GetHierarchySnapshotAsync(ProjectSessionInfo project, CancellationToken cancellationToken) =>
        ReadSnapshotAsync<HierarchySnapshot>(project, "Hierarchy", cancellationToken);

    public Task<AssetCatalogSnapshot> GetAssetCatalogSnapshotAsync(ProjectSessionInfo project, CancellationToken cancellationToken) =>
        ReadSnapshotAsync<AssetCatalogSnapshot>(project, "Assets", cancellationToken);

    public async Task<PublicationSnapshot> GetPublicationSnapshotAsync(ProjectSessionInfo project, PublicationSnapshotQueryParameters parameters, CancellationToken cancellationToken)
    {
        var profile = NormalizeProfile(parameters.Profile);
        var output = await RunPowerShellAsync(
            Path.Combine(_kadathRoot, "tools", "editor-publication-snapshot.ps1"),
            ["-PackageRoot", project.PackageRoot, "-ProjectName", project.ProjectName, "-Profile", profile],
            cancellationToken);
        if (output.ExitCode != 0)
        {
            throw new EditorOperationException("publication_snapshot_failed", JoinDiagnostics(output));
        }

        var line = output.Stdout.LastOrDefault(value => !string.IsNullOrWhiteSpace(value));
        if (line is null)
        {
            throw new EditorOperationException("publication_snapshot_protocol_error", "Publication snapshot adapter emitted no JSON result.");
        }
        try
        {
            var snapshot = JsonSerializer.Deserialize<PublicationSnapshot>(line, EditorProtocol.JsonOptions)
                ?? throw new EditorOperationException("publication_snapshot_protocol_error", "Publication snapshot adapter emitted an empty result.");
            ValidateSnapshot(project, snapshot);
            return snapshot;
        }
        catch (JsonException exception)
        {
            throw new EditorOperationException("publication_snapshot_protocol_error", $"Publication snapshot JSON is invalid: {exception.Message}");
        }
    }
    public async Task<AuthoringMutationResult> ApplyAuthoringAsync(ProjectSessionInfo project, AuthoringApplyParameters parameters, CancellationToken cancellationToken)
    {
        await _authoringGate.WaitAsync(cancellationToken);
        try
        {
            var current = await ReadSnapshotAsync<ProjectModelSnapshot>(project, "Project", cancellationToken);
            ValidateExpectedRevision(parameters.ExpectedRevision, current.AuthoringRevision);
            var patch = NormalizePatch(current, parameters.Patch);
            var changedFields = GetChangedFields(patch);
            if (changedFields.Length == 0)
            {
                var unchangedHierarchy = await ReadSnapshotAsync<HierarchySnapshot>(project, "Hierarchy", cancellationToken);
                return new AuthoringMutationResult("apply", "unchanged", project.ProjectName, current.AuthoringRevision, current.AuthoringRevision, [], _authoringHistory.Count, current, unchangedHierarchy);
            }

            await InvokeAuthoringAdapterAsync(project, parameters.ExpectedRevision, patch, cancellationToken);
            var next = await ReadSnapshotAsync<ProjectModelSnapshot>(project, "Project", cancellationToken);
            var hierarchy = await ReadSnapshotAsync<HierarchySnapshot>(project, "Hierarchy", cancellationToken);
            if (_authoringHistory.Count > 0 && !string.Equals(_authoringHistory[^1].RevisionAfter, current.AuthoringRevision, StringComparison.OrdinalIgnoreCase))
            {
                // 外部编辑使旧 undo 链失去连续性；清理而不是把不相关内容覆盖回来。
                _authoringHistory.Clear();
            }
            _authoringHistory.Add(new AuthoringUndoRecord(project.ProjectName, next.AuthoringRevision, changedFields,
                patch.SceneGoalPosition is null ? null : current.Scene.GoalPosition,
                patch.ScriptGoalPosition is null ? null : current.Script.GoalPosition,
                patch.ScriptGoalVelocity is null ? null : current.Script.GoalVelocity,
                patch.ScenePlayerTextureId is null ? null : current.Scene.PlayerTextureId,
                patch.SceneGoalTextureId is null ? null : current.Scene.GoalTextureId,
                patch.SceneHazardTextureId is null ? null : current.Scene.HazardTextureId));
            if (_authoringHistory.Count > MaxAuthoringHistory) { _authoringHistory.RemoveAt(0); }
            return new AuthoringMutationResult("apply", "succeeded", project.ProjectName, current.AuthoringRevision, next.AuthoringRevision, changedFields, _authoringHistory.Count, next, hierarchy);
        }
        finally { _authoringGate.Release(); }
    }

    public async Task<AuthoringMutationResult> UndoAuthoringAsync(ProjectSessionInfo project, AuthoringUndoParameters parameters, CancellationToken cancellationToken)
    {
        await _authoringGate.WaitAsync(cancellationToken);
        try
        {
            var current = await ReadSnapshotAsync<ProjectModelSnapshot>(project, "Project", cancellationToken);
            ValidateExpectedRevision(parameters.ExpectedRevision, current.AuthoringRevision);
            if (_authoringHistory.Count == 0) { throw new EditorOperationException("authoring_undo_empty", "There is no authoring mutation to undo."); }
            var record = _authoringHistory[^1];
            if (!string.Equals(record.ProjectName, project.ProjectName, StringComparison.OrdinalIgnoreCase)
                || !string.Equals(record.RevisionAfter, current.AuthoringRevision, StringComparison.OrdinalIgnoreCase))
            {
                throw new EditorOperationException("authoring_history_diverged", "Authoring history no longer matches the current revision.");
            }

            await InvokeAuthoringAdapterAsync(project, parameters.ExpectedRevision,
                new AuthoringPatch(record.SceneGoalPosition, record.ScriptGoalPosition, record.ScriptGoalVelocity, record.ScenePlayerTextureId, record.SceneGoalTextureId, record.SceneHazardTextureId), cancellationToken);
            var next = await ReadSnapshotAsync<ProjectModelSnapshot>(project, "Project", cancellationToken);
            var hierarchy = await ReadSnapshotAsync<HierarchySnapshot>(project, "Hierarchy", cancellationToken);
            _authoringHistory.RemoveAt(_authoringHistory.Count - 1);
            return new AuthoringMutationResult("undo", "succeeded", project.ProjectName, current.AuthoringRevision, next.AuthoringRevision, record.ChangedFields, _authoringHistory.Count, next, hierarchy);
        }
        finally { _authoringGate.Release(); }
    }
    public async Task<EditorBakeResult> BakeAsync(ProjectSessionInfo project, BakeStartParameters parameters, CancellationToken cancellationToken)
    {
        var target = NormalizeTarget(parameters.Target);
        var profile = NormalizeProfile(parameters.Profile);
        await _bakeGate.WaitAsync(cancellationToken);
        try
        {
            var derived = Path.Combine(project.ProjectDirectory, ".kadath", "derived");
            var manifest = Path.Combine(derived, ".live-bake.manifest.json");
            var output = await RunPowerShellAsync(
                Path.Combine(_kadathRoot, "tools", "editor-live-bake.ps1"),
                [
                    "-PackageRoot", project.PackageRoot,
                    "-SceneSourcePath", project.ScenePath,
                    "-ScriptSourcePath", project.ScriptPath,
                    "-SceneArtifactPath", Path.Combine(derived, "scene.scene"),
                    "-ScriptArtifactPath", Path.Combine(derived, "script.script"),
                    "-ManifestPath", manifest,
                    "-Target", target,
                    "-Profile", profile
                ],
                cancellationToken);

            var terminal = ParseTerminalResult(output.Stdout);
            var state = terminal.TryGetProperty("result", out var resultValue) ? resultValue.GetString() : null;
            if (output.ExitCode != 0 || state != "succeeded")
            {
                var errorCode = terminal.TryGetProperty("errorCode", out var code) ? code.GetString() : "bake_failed";
                var message = terminal.TryGetProperty("message", out var text) ? text.GetString() : JoinDiagnostics(output);
                throw new EditorOperationException(errorCode ?? "bake_failed", message ?? "Live bake failed.");
            }

            var sourceRevision = terminal.GetProperty("sourceRevision");
            var artifactRevision = terminal.GetProperty("artifactRevision");
            var artifactBytes = terminal.GetProperty("artifactBytes");
            return new EditorBakeResult(
                "succeeded",
                target,
                profile,
                derived,
                manifest,
                TryGetString(sourceRevision, "scene"),
                TryGetString(sourceRevision, "script"),
                TryGetString(artifactRevision, "scene"),
                TryGetString(artifactRevision, "script"),
                TryGetInt32(artifactBytes, "scene"),
                TryGetInt32(artifactBytes, "script"));
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

    private async Task<T> ReadSnapshotAsync<T>(ProjectSessionInfo project, string target, CancellationToken cancellationToken)
    {
        var output = await RunPowerShellAsync(
            Path.Combine(_kadathRoot, "tools", "editor-snapshot.ps1"),
            ["-PackageRoot", project.PackageRoot, "-ProjectName", project.ProjectName, "-Target", target],
            cancellationToken);
        if (output.ExitCode != 0)
        {
            // Adapter 负责文件/reparse 边界；Service 再校验 DTO，避免不可信 JSON 穿透到前端。
            throw new EditorOperationException("snapshot_failed", JoinDiagnostics(output));
        }

        var line = output.Stdout.LastOrDefault(value => !string.IsNullOrWhiteSpace(value));
        if (line is null) { throw new EditorOperationException("snapshot_protocol_error", "Snapshot adapter emitted no JSON result."); }
        try
        {
            var snapshot = JsonSerializer.Deserialize<T>(line, EditorProtocol.JsonOptions)
                ?? throw new EditorOperationException("snapshot_protocol_error", "Snapshot adapter emitted an empty JSON result.");
            ValidateSnapshot(project, snapshot);
            return snapshot;
        }
        catch (JsonException exception)
        {
            throw new EditorOperationException("snapshot_protocol_error", $"Snapshot JSON is invalid: {exception.Message}");
        }
    }

    private static void ValidateSnapshot<T>(ProjectSessionInfo project, T snapshot)
    {
        switch (snapshot)
        {
            case ProjectModelSnapshot model:
                if (model is null || model.Files is null || model.Scene is null || model.Script is null || model.Preview is null
                    || model.Scene.GoalPosition is null || model.Script.GoalPosition is null || model.Script.GoalVelocity is null
                    // Revision 是 authoring transaction 的并发令牌，非法值必须在跨越 backend seam 前被拒绝。
                    || string.IsNullOrWhiteSpace(model.AuthoringRevision)
                    || model.AuthoringRevision.Length != 64
                    || model.AuthoringRevision.Any(value => !Uri.IsHexDigit(value))
                    || model.ModelVersion != EditorSnapshotVersions.ProjectModel
                    || model.Scene.SchemaVersion != 2
                    || model.Scene.PlayerTextureId is not 1 and not 2
                    || model.Scene.GoalTextureId is not 1 and not 2
                    || model.Scene.HazardTextureId is not 1 and not 2
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
    private async Task InvokeAuthoringAdapterAsync(ProjectSessionInfo project, string expectedRevision, AuthoringPatch patch, CancellationToken cancellationToken)
    {
        var arguments = new List<string>
        {
            "-Action", "Update",
            "-PackageRoot", project.PackageRoot,
            "-ProjectName", project.ProjectName,
            "-ExpectedRevision", expectedRevision
        };
        AppendVector(arguments, "SceneGoal", patch.SceneGoalPosition);
        AppendVector(arguments, "ScriptGoal", patch.ScriptGoalPosition);
        AppendVector(arguments, "ScriptVelocity", patch.ScriptGoalVelocity);
        AppendScalar(arguments, "ScenePlayerTextureId", patch.ScenePlayerTextureId);
        AppendScalar(arguments, "SceneGoalTextureId", patch.SceneGoalTextureId);
        AppendScalar(arguments, "SceneHazardTextureId", patch.SceneHazardTextureId);
        var output = await RunPowerShellAsync(Path.Combine(_kadathRoot, "tools", "editor-author.ps1"), arguments.ToArray(), cancellationToken);
        if (output.ExitCode != 0)
        {
            var diagnostics = JoinDiagnostics(output);
            var code = diagnostics.Contains("[authoring_revision_conflict]", StringComparison.Ordinal)
                ? "authoring_revision_conflict"
                : diagnostics.Contains("[invalid_expected_revision]", StringComparison.Ordinal)
                    ? "invalid_expected_revision"
                    : "authoring_update_failed";
            throw new EditorOperationException(code, diagnostics);
        }
        if (!output.Stdout.Any(line => line.StartsWith("authoring_revision=", StringComparison.Ordinal)))
        {
            throw new EditorOperationException("authoring_protocol_error", "Authoring adapter emitted no revision result.");
        }
    }

    private static void AppendVector(List<string> arguments, string prefix, double[]? vector)
    {
        if (vector is null) { return; }
        arguments.Add($"-{prefix}X");
        arguments.Add(vector[0].ToString("R", System.Globalization.CultureInfo.InvariantCulture));
        arguments.Add($"-{prefix}Y");
        arguments.Add(vector[1].ToString("R", System.Globalization.CultureInfo.InvariantCulture));
    }

    private static void AppendScalar(List<string> arguments, string name, uint? value)
    {
        if (value is null) { return; }
        arguments.Add($"-{name}");
        arguments.Add(value.Value.ToString(System.Globalization.CultureInfo.InvariantCulture));
    }

    private static AuthoringPatch NormalizePatch(ProjectModelSnapshot current, AuthoringPatch? patch)
    {
        if (patch is null) { throw new EditorOperationException("invalid_authoring_patch", "Authoring patch is required."); }
        ValidateVector(patch.SceneGoalPosition, "scene.goal.position");
        ValidateVector(patch.ScriptGoalPosition, "script.goal.position");
        ValidateVector(patch.ScriptGoalVelocity, "script.goal.velocity");
        ValidateTextureId(patch.ScenePlayerTextureId, "scene.player.textureId");
        ValidateTextureId(patch.SceneGoalTextureId, "scene.goal.textureId");
        ValidateTextureId(patch.SceneHazardTextureId, "scene.hazard.textureId");
        var scene = patch.SceneGoalPosition is not null && !patch.SceneGoalPosition.SequenceEqual(current.Scene.GoalPosition) ? patch.SceneGoalPosition : null;
        var scriptGoal = patch.ScriptGoalPosition is not null && !patch.ScriptGoalPosition.SequenceEqual(current.Script.GoalPosition) ? patch.ScriptGoalPosition : null;
        var velocity = patch.ScriptGoalVelocity is not null && !patch.ScriptGoalVelocity.SequenceEqual(current.Script.GoalVelocity) ? patch.ScriptGoalVelocity : null;
        var playerTexture = patch.ScenePlayerTextureId is not null && patch.ScenePlayerTextureId != current.Scene.PlayerTextureId ? patch.ScenePlayerTextureId : null;
        var goalTexture = patch.SceneGoalTextureId is not null && patch.SceneGoalTextureId != current.Scene.GoalTextureId ? patch.SceneGoalTextureId : null;
        var hazardTexture = patch.SceneHazardTextureId is not null && patch.SceneHazardTextureId != current.Scene.HazardTextureId ? patch.SceneHazardTextureId : null;
        if (scene is null && scriptGoal is null && velocity is null && playerTexture is null && goalTexture is null && hazardTexture is null
            && patch.SceneGoalPosition is null && patch.ScriptGoalPosition is null && patch.ScriptGoalVelocity is null
            && patch.ScenePlayerTextureId is null && patch.SceneGoalTextureId is null && patch.SceneHazardTextureId is null)
        {
            throw new EditorOperationException("invalid_authoring_patch", "At least one authoring field is required.");
        }
        return new AuthoringPatch(scene, scriptGoal, velocity, playerTexture, goalTexture, hazardTexture);
    }

    private static void ValidateVector(double[]? vector, string field)
    {
        if (vector is not null && (vector.Length != 2 || vector.Any(value => !double.IsFinite(value))))
        {
            throw new EditorOperationException("invalid_authoring_patch", $"{field} must contain two finite values.");
        }
    }

    private static void ValidateTextureId(uint? value, string field)
    {
        if (value is not null && value is not 1 and not 2) { throw new EditorOperationException("invalid_authoring_patch", $"{field} must be 1 or 2."); }
    }

    private static string[] GetChangedFields(AuthoringPatch patch)
    {
        var fields = new List<string>();
        if (patch.SceneGoalPosition is not null) { fields.Add("scene.goal.position"); }
        if (patch.ScriptGoalPosition is not null) { fields.Add("script.goal.position"); }
        if (patch.ScriptGoalVelocity is not null) { fields.Add("script.goal.velocity"); }
        if (patch.ScenePlayerTextureId is not null) { fields.Add("scene.player.textureId"); }
        if (patch.SceneGoalTextureId is not null) { fields.Add("scene.goal.textureId"); }
        if (patch.SceneHazardTextureId is not null) { fields.Add("scene.hazard.textureId"); }
        return fields.ToArray();
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
        double[]? SceneGoalPosition,
        double[]? ScriptGoalPosition,
        double[]? ScriptGoalVelocity,
        uint? ScenePlayerTextureId,
        uint? SceneGoalTextureId,
        uint? SceneHazardTextureId);
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

    private static JsonElement ParseTerminalResult(string[] lines)
    {
        for (var index = lines.Length - 1; index >= 0; index--)
        {
            try
            {
                using var document = JsonDocument.Parse(lines[index]);
                var root = document.RootElement;
                if (root.TryGetProperty("event", out var eventName) && eventName.GetString() == "live_bake_result") { return root.Clone(); }
            }
            catch (JsonException) { }
        }
        throw new EditorOperationException("adapter_protocol_error", "Live-bake adapter emitted no terminal JSONL result.");
    }

    private static string? TryGetString(JsonElement parent, string name) => parent.TryGetProperty(name, out var value) ? value.GetString() : null;
    private static int? TryGetInt32(JsonElement parent, string name) => parent.TryGetProperty(name, out var value) && value.TryGetInt32(out var number) ? number : null;

    private static string JoinDiagnostics(PowerShellResult result)
    {
        var lines = result.Stderr.Length > 0 ? result.Stderr : result.Stdout;
        return lines.Length == 0 ? $"PowerShell exited with code {result.ExitCode}." : string.Join(" | ", lines);
    }

    private static async Task<PowerShellResult> RunPowerShellAsync(string scriptPath, string[] arguments, CancellationToken cancellationToken)
    {
        if (!File.Exists(scriptPath)) { throw new EditorOperationException("adapter_missing", $"Editor adapter does not exist: {scriptPath}"); }
        var startInfo = new ProcessStartInfo
        {
            FileName = "pwsh",
            WorkingDirectory = Path.GetDirectoryName(scriptPath)!,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        startInfo.ArgumentList.Add("-NoProfile");
        startInfo.ArgumentList.Add("-File");
        startInfo.ArgumentList.Add(scriptPath);
        foreach (var argument in arguments) { startInfo.ArgumentList.Add(argument); }

        using var process = new Process { StartInfo = startInfo };
        try
        {
            if (!process.Start()) { throw new EditorOperationException("adapter_start_failed", $"Failed to start adapter: {scriptPath}"); }
        }
        catch (EditorOperationException) { throw; }
        catch (Exception exception)
        {
            // Process.Start 在可执行文件缺失等 Windows 错误上会抛异常；统一收敛为稳定 Adapter 错误码。
            throw new EditorOperationException("adapter_start_failed", $"Failed to start adapter: {scriptPath}; {exception.Message}");
        }
        var stdoutTask = process.StandardOutput.ReadToEndAsync(cancellationToken);
        var stderrTask = process.StandardError.ReadToEndAsync(cancellationToken);
        try { await process.WaitForExitAsync(cancellationToken); }
        catch (OperationCanceledException)
        {
            if (!process.HasExited) { process.Kill(entireProcessTree: true); }
            throw;
        }

        var stdout = (await stdoutTask).Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries);
        var stderr = (await stderrTask).Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries);
        return new PowerShellResult(process.ExitCode, stdout, stderr);
    }

    public async ValueTask DisposeAsync()
    {
        await StopWatchAsync(CancellationToken.None);
        _bakeGate.Dispose();
        _watchGate.Dispose();
        _authoringGate.Dispose();
    }

    private sealed record PowerShellResult(int ExitCode, string[] Stdout, string[] Stderr);
}







