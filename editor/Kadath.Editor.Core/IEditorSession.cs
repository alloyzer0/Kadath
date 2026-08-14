using System.Text.Json;
using Kadath.Editor.Protocol;

namespace Kadath.Editor.Core;

public sealed record EditorSessionNotification(string Event, JsonElement? Data, string? RequestId);

public sealed class EditorOperationException : Exception
{
    public EditorOperationException(string code, string message) : base(message) => Code = code;
    public string Code { get; }
}

public interface IEditorSessionBackend : IAsyncDisposable
{
    Task<ProjectSessionInfo> OpenProjectAsync(ProjectOpenParameters parameters, CancellationToken cancellationToken);
    Task<ProjectSessionInfo> CreateProjectAsync(ProjectCreateParameters parameters, CancellationToken cancellationToken);
    Task<ProjectValidateResult> ValidateProjectAsync(ProjectSessionInfo project, CancellationToken cancellationToken);
    Task<ProjectModelSnapshot> GetProjectSnapshotAsync(ProjectSessionInfo project, CancellationToken cancellationToken);
    Task<HierarchySnapshot> GetHierarchySnapshotAsync(ProjectSessionInfo project, CancellationToken cancellationToken);
    Task<AssetCatalogSnapshot> GetAssetCatalogSnapshotAsync(ProjectSessionInfo project, CancellationToken cancellationToken);
    Task<ScriptSourceDocument> GetScriptSourceAsync(ProjectSessionInfo project, ScriptSourceQueryParameters parameters, CancellationToken cancellationToken);
    Task<ScriptSourceAnalysisResult> AnalyzeScriptSourceAsync(ProjectSessionInfo project, ScriptSourceAnalyzeParameters parameters, CancellationToken cancellationToken);
    Task<PublicationSnapshot> GetPublicationSnapshotAsync(ProjectSessionInfo project, PublicationSnapshotQueryParameters parameters, CancellationToken cancellationToken);
    Task<TextureImportResult> ImportTextureAsync(ProjectSessionInfo project, TextureImportParameters parameters, CancellationToken cancellationToken);
    Task<AuthoringMutationResult> ApplyAuthoringAsync(ProjectSessionInfo project, AuthoringApplyParameters parameters, CancellationToken cancellationToken);
    Task<AuthoringMutationResult> UndoAuthoringAsync(ProjectSessionInfo project, AuthoringUndoParameters parameters, CancellationToken cancellationToken);
    Task<ScriptSourceMutationResult> EditScriptSourceAsync(ProjectSessionInfo project, ScriptSourceEditParameters parameters, CancellationToken cancellationToken);
    Task<ScriptSourceMutationResult> UndoScriptSourceAsync(ProjectSessionInfo project, ScriptSourceUndoParameters parameters, CancellationToken cancellationToken);
    Task<EditorBakeResult> BakeAsync(ProjectSessionInfo project, BakeStartParameters parameters, CancellationToken cancellationToken);
    Task<EditorWatchResult> StartWatchAsync(ProjectSessionInfo project, WatchStartParameters parameters, CancellationToken cancellationToken);
    Task<EditorWatchResult> StopWatchAsync(CancellationToken cancellationToken);
    event Func<EditorSessionNotification, Task>? Notification;
}

/// <summary>
/// Editor Core 的深模块接口。UI、RPC 和测试都不应越过此 seam 了解脚本、文件监听或 WM_APP 细节。
/// </summary>
public interface IEditorSession : IAsyncDisposable
{
    EditorCapabilities GetCapabilities();
    ProjectSessionInfo? CurrentProject { get; }
    event Func<EditorSessionNotification, Task>? Notification;
    Task<ProjectSessionInfo> OpenProjectAsync(ProjectOpenParameters parameters, string? requestId, CancellationToken cancellationToken = default);
    Task<ProjectSessionInfo> CreateProjectAsync(ProjectCreateParameters parameters, string? requestId, CancellationToken cancellationToken = default);
    Task<ProjectValidateResult> ValidateProjectAsync(ProjectValidateParameters parameters, string? requestId, CancellationToken cancellationToken = default);
    Task<ProjectModelSnapshot> GetProjectSnapshotAsync(SnapshotQueryParameters parameters, string? requestId, CancellationToken cancellationToken = default);
    Task<HierarchySnapshot> GetHierarchySnapshotAsync(SnapshotQueryParameters parameters, string? requestId, CancellationToken cancellationToken = default);
    Task<AssetCatalogSnapshot> GetAssetCatalogSnapshotAsync(SnapshotQueryParameters parameters, string? requestId, CancellationToken cancellationToken = default);
    Task<ScriptSourceDocument> GetScriptSourceAsync(ScriptSourceQueryParameters parameters, string? requestId, CancellationToken cancellationToken = default);
    Task<ScriptSourceAnalysisResult> AnalyzeScriptSourceAsync(ScriptSourceAnalyzeParameters parameters, string? requestId, CancellationToken cancellationToken = default);
    Task<PublicationSnapshot> GetPublicationSnapshotAsync(PublicationSnapshotQueryParameters parameters, string? requestId, CancellationToken cancellationToken = default);
    Task<TextureImportResult> ImportTextureAsync(TextureImportParameters parameters, string? requestId, CancellationToken cancellationToken = default);
    Task<AuthoringMutationResult> ApplyAuthoringAsync(AuthoringApplyParameters parameters, string? requestId, CancellationToken cancellationToken = default);
    Task<AuthoringMutationResult> UndoAuthoringAsync(AuthoringUndoParameters parameters, string? requestId, CancellationToken cancellationToken = default);
    Task<ScriptSourceMutationResult> EditScriptSourceAsync(ScriptSourceEditParameters parameters, string? requestId, CancellationToken cancellationToken = default);
    Task<ScriptSourceMutationResult> UndoScriptSourceAsync(ScriptSourceUndoParameters parameters, string? requestId, CancellationToken cancellationToken = default);
    Task<EditorBakeResult> BakeAsync(BakeStartParameters parameters, string? requestId, CancellationToken cancellationToken = default);
    Task<EditorWatchResult> StartWatchAsync(WatchStartParameters parameters, string? requestId, CancellationToken cancellationToken = default);
    Task<EditorWatchResult> StopWatchAsync(string? requestId, CancellationToken cancellationToken = default);
    PreviewStartParameters ResolvePreviewStart(PreviewStartParameters parameters);
}

public sealed class EditorSession : IEditorSession
{
    private static readonly string[] Commands =
    [
        "get_capabilities",
        "project_open",
        "project_create",
        "project_validate",
        "project_snapshot",
        "hierarchy_snapshot",
        "asset_catalog_snapshot",
        "publication_snapshot",
        "script_source_read",
        "script_source_analyze",
        "texture_import",
        "authoring_apply",
        "authoring_undo",
        "script_source_edit",
        "script_source_undo",
        "bake_start",
        "watch_start",
        "watch_stop",
        "preview_start",
        "preview_stop",
        "shutdown"
    ];

    private readonly IEditorSessionBackend _backend;
    // 固定锁序：Core project mutation gate → Backend 内部 gate；仅会改变项目/session 状态的四类命令进入此门。
    private readonly SemaphoreSlim _projectMutationGate = new(1, 1);
    private ProjectSessionInfo? _currentProject;

    public EditorSession(IEditorSessionBackend backend)
    {
        _backend = backend;
        _backend.Notification += ForwardBackendNotificationAsync;
    }

    public ProjectSessionInfo? CurrentProject => _currentProject;
    public event Func<EditorSessionNotification, Task>? Notification;

    public EditorCapabilities GetCapabilities() => new(
        Commands,
        [EditorProtocol.TransportName],
        [
            new PreviewSurfaceCapability(PreviewSurfaceModes.ExternalWindow, "native-window", true),
            new PreviewSurfaceCapability(PreviewSurfaceModes.SharedTexture, "gpu-shared-resource", false),
            new PreviewSurfaceCapability(PreviewSurfaceModes.FrameStream, "encoded-frame-stream", false)
        ]);

    public async Task<ProjectSessionInfo> OpenProjectAsync(ProjectOpenParameters parameters, string? requestId, CancellationToken cancellationToken = default)
    {
        await _projectMutationGate.WaitAsync(cancellationToken);
        try
        {
            var project = await _backend.OpenProjectAsync(parameters, cancellationToken);
            _currentProject = project;
            await EmitAsync("project_opened", project, requestId);
            return project;
        }
        finally { _projectMutationGate.Release(); }
    }

    public async Task<ProjectSessionInfo> CreateProjectAsync(ProjectCreateParameters parameters, string? requestId, CancellationToken cancellationToken = default)
    {
        await _projectMutationGate.WaitAsync(cancellationToken);
        try
        {
            var project = await _backend.CreateProjectAsync(parameters, cancellationToken);
            // 关键提交点：Backend→current session→成功事件作为一个有序事务，不能与 Apply/Undo/Open 交错。
            _currentProject = project;
            await EmitAsync("project_created", project, requestId);
            return project;
        }
        finally { _projectMutationGate.Release(); }
    }

    public async Task<ProjectValidateResult> ValidateProjectAsync(ProjectValidateParameters parameters, string? requestId, CancellationToken cancellationToken = default)
    {
        var project = RequireProject(parameters.ProjectName);
        var result = await _backend.ValidateProjectAsync(project, cancellationToken);
        await EmitAsync("project_validated", result, requestId);
        return result;
    }

    public async Task<ProjectModelSnapshot> GetProjectSnapshotAsync(SnapshotQueryParameters parameters, string? requestId, CancellationToken cancellationToken = default)
    {
        var project = RequireProject(parameters.ProjectName);
        var result = await _backend.GetProjectSnapshotAsync(project, cancellationToken);
        await EmitAsync("project_snapshot_created", result, requestId);
        return result;
    }

    public async Task<HierarchySnapshot> GetHierarchySnapshotAsync(SnapshotQueryParameters parameters, string? requestId, CancellationToken cancellationToken = default)
    {
        var project = RequireProject(parameters.ProjectName);
        var result = await _backend.GetHierarchySnapshotAsync(project, cancellationToken);
        await EmitAsync("hierarchy_snapshot_created", result, requestId);
        return result;
    }

    public async Task<AssetCatalogSnapshot> GetAssetCatalogSnapshotAsync(SnapshotQueryParameters parameters, string? requestId, CancellationToken cancellationToken = default)
    {
        var project = RequireProject(parameters.ProjectName);
        var result = await _backend.GetAssetCatalogSnapshotAsync(project, cancellationToken);
        await EmitAsync("asset_catalog_snapshot_created", result, requestId);
        return result;
    }

    public async Task<ScriptSourceDocument> GetScriptSourceAsync(ScriptSourceQueryParameters parameters, string? requestId, CancellationToken cancellationToken = default)
    {
        var project = RequireProject(parameters.ProjectName);
        try
        {
            var result = await _backend.GetScriptSourceAsync(project, parameters, cancellationToken);
            await EmitAsync("script_source_read", result, requestId);
            return result;
        }
        catch (EditorOperationException exception)
        {
            await EmitAsync("script_source_read_failed", new { errorCode = exception.Code, message = exception.Message }, requestId);
            throw;
        }
    }

    public async Task<ScriptSourceAnalysisResult> AnalyzeScriptSourceAsync(
        ScriptSourceAnalyzeParameters parameters,
        string? requestId,
        CancellationToken cancellationToken = default)
    {
        var project = RequireProject(parameters.ProjectName);
        var identity = new
        {
            projectName = project.ProjectName,
            scriptId = parameters.ScriptId,
            sourceHash = parameters.SourceHash
        };
        await EmitAsync("script_source_analysis_started", identity, requestId);
        try
        {
            var result = await _backend.AnalyzeScriptSourceAsync(project, parameters, cancellationToken);
            await EmitAsync("script_source_analysis_completed", new
            {
                identity.projectName,
                identity.scriptId,
                identity.sourceHash,
                state = result.State,
                diagnosticCount = result.Diagnostics.Length,
                authoringRevision = result.AuthoringRevision,
                toolchainIdentity = result.ToolchainIdentity
            }, requestId);
            return result;
        }
        catch (EditorOperationException exception)
        {
            await EmitAsync("script_source_analysis_failed", new
            {
                identity.projectName,
                identity.scriptId,
                identity.sourceHash,
                errorCode = exception.Code,
                message = BoundedAnalysisMessage(exception.Message)
            }, requestId);
            throw;
        }
        catch (OperationCanceledException)
        {
            const string code = "script_source_analysis_cancelled";
            await EmitAsync("script_source_analysis_failed", new
            {
                identity.projectName,
                identity.scriptId,
                identity.sourceHash,
                errorCode = code,
                message = "Script source analysis was cancelled."
            }, requestId);
            throw new EditorOperationException(code, "Script source analysis was cancelled.");
        }
        catch (Exception exception)
        {
            const string code = "command_failed";
            await EmitAsync("script_source_analysis_failed", new
            {
                identity.projectName,
                identity.scriptId,
                identity.sourceHash,
                errorCode = code,
                message = BoundedAnalysisMessage(exception.Message)
            }, requestId);
            throw;
        }
    }

    public async Task<PublicationSnapshot> GetPublicationSnapshotAsync(PublicationSnapshotQueryParameters parameters, string? requestId, CancellationToken cancellationToken = default)
    {
        var project = RequireProject(parameters.ProjectName);
        var result = await _backend.GetPublicationSnapshotAsync(project, parameters, cancellationToken);
        await EmitAsync("publication_snapshot_created", result, requestId);
        return result;
    }

    public async Task<TextureImportResult> ImportTextureAsync(TextureImportParameters parameters, string? requestId, CancellationToken cancellationToken = default)
    {
        await _projectMutationGate.WaitAsync(cancellationToken);
        try
        {
            var project = RequireProject(parameters.ProjectName);
            await EmitAsync("texture_import_started", new { projectName = project.ProjectName, sourcePath = parameters.SourcePath, assetName = parameters.AssetName, profile = parameters.Profile }, requestId);
            try
            {
                var result = await _backend.ImportTextureAsync(project, parameters, cancellationToken);
                await EmitAsync("texture_import_completed", result, requestId);
                return result;
            }
            catch (EditorOperationException exception)
            {
                await EmitAsync("texture_import_failed", new { errorCode = exception.Code, message = exception.Message }, requestId);
                throw;
            }
        }
        finally { _projectMutationGate.Release(); }
    }

    public async Task<AuthoringMutationResult> ApplyAuthoringAsync(AuthoringApplyParameters parameters, string? requestId, CancellationToken cancellationToken = default)
    {
        await _projectMutationGate.WaitAsync(cancellationToken);
        try
        {
            // RequireProject 必须在 mutation gate 内读取，保证后续事件与 Backend 都绑定同一个已提交 session。
            var project = RequireProject(parameters.ProjectName);
            await EmitAsync("authoring_apply_started", new { projectName = project.ProjectName, expectedRevision = parameters.ExpectedRevision }, requestId);
            try
            {
                var result = await _backend.ApplyAuthoringAsync(project, parameters, cancellationToken);
                await EmitAsync("authoring_apply_completed", result, requestId);
                return result;
            }
            catch (EditorOperationException exception)
            {
                await EmitAsync("authoring_apply_failed", new { errorCode = exception.Code, message = exception.Message }, requestId);
                throw;
            }
        }
        finally { _projectMutationGate.Release(); }
    }

    public async Task<AuthoringMutationResult> UndoAuthoringAsync(AuthoringUndoParameters parameters, string? requestId, CancellationToken cancellationToken = default)
    {
        await _projectMutationGate.WaitAsync(cancellationToken);
        try
        {
            var project = RequireProject(parameters.ProjectName);
            await EmitAsync("authoring_undo_started", new { projectName = project.ProjectName, expectedRevision = parameters.ExpectedRevision }, requestId);
            try
            {
                var result = await _backend.UndoAuthoringAsync(project, parameters, cancellationToken);
                await EmitAsync("authoring_undo_completed", result, requestId);
                return result;
            }
            catch (EditorOperationException exception)
            {
                await EmitAsync("authoring_undo_failed", new { errorCode = exception.Code, message = exception.Message }, requestId);
                throw;
            }
        }
        finally { _projectMutationGate.Release(); }
    }

    public async Task<ScriptSourceMutationResult> EditScriptSourceAsync(ScriptSourceEditParameters parameters, string? requestId, CancellationToken cancellationToken = default)
    {
        await _projectMutationGate.WaitAsync(cancellationToken);
        try
        {
            var project = RequireProject(parameters.ProjectName);
            await EmitAsync("script_source_edit_started", new { projectName = project.ProjectName, scriptId = parameters.ScriptId, expectedRevision = parameters.ExpectedRevision }, requestId);
            try
            {
                var result = await _backend.EditScriptSourceAsync(project, parameters, cancellationToken);
                await EmitAsync("script_source_edit_completed", result, requestId);
                return result;
            }
            catch (EditorOperationException exception)
            {
                await EmitAsync("script_source_edit_failed", new { errorCode = exception.Code, message = exception.Message }, requestId);
                throw;
            }
        }
        finally { _projectMutationGate.Release(); }
    }

    public async Task<ScriptSourceMutationResult> UndoScriptSourceAsync(ScriptSourceUndoParameters parameters, string? requestId, CancellationToken cancellationToken = default)
    {
        await _projectMutationGate.WaitAsync(cancellationToken);
        try
        {
            var project = RequireProject(parameters.ProjectName);
            await EmitAsync("script_source_undo_started", new { projectName = project.ProjectName, expectedRevision = parameters.ExpectedRevision }, requestId);
            try
            {
                var result = await _backend.UndoScriptSourceAsync(project, parameters, cancellationToken);
                await EmitAsync("script_source_undo_completed", result, requestId);
                return result;
            }
            catch (EditorOperationException exception)
            {
                await EmitAsync("script_source_undo_failed", new { errorCode = exception.Code, message = exception.Message }, requestId);
                throw;
            }
        }
        finally { _projectMutationGate.Release(); }
    }
    public async Task<EditorBakeResult> BakeAsync(BakeStartParameters parameters, string? requestId, CancellationToken cancellationToken = default)
    {
        var project = RequireProject(null);
        await EmitAsync("bake_started", new { target = parameters.Target, profile = parameters.Profile }, requestId);
        try
        {
            var result = await _backend.BakeAsync(project, parameters, cancellationToken);
            await EmitAsync("bake_completed", result, requestId);
            return result;
        }
        catch (EditorOperationException exception)
        {
            await EmitAsync("bake_failed", new { errorCode = exception.Code, message = exception.Message }, requestId);
            throw;
        }
    }

    public async Task<EditorWatchResult> StartWatchAsync(WatchStartParameters parameters, string? requestId, CancellationToken cancellationToken = default)
    {
        var project = RequireProject(null);
        var result = await _backend.StartWatchAsync(project, parameters, cancellationToken);
        await EmitAsync("watch_started", result, requestId);
        return result;
    }

    public async Task<EditorWatchResult> StopWatchAsync(string? requestId, CancellationToken cancellationToken = default)
    {
        var result = await _backend.StopWatchAsync(cancellationToken);
        await EmitAsync("watch_stopped", result, requestId);
        return result;
    }

    public PreviewStartParameters ResolvePreviewStart(PreviewStartParameters parameters)
    {
        if (!string.IsNullOrWhiteSpace(parameters.ProjectName))
        {
            if (_currentProject is null || !string.Equals(_currentProject.ProjectName, parameters.ProjectName, StringComparison.OrdinalIgnoreCase))
            {
                throw new EditorOperationException("project_not_open", $"Project is not open: {parameters.ProjectName}");
            }
        }

        if (!string.IsNullOrWhiteSpace(parameters.ConfigPath) && !string.IsNullOrWhiteSpace(parameters.PackageRoot)) { return parameters; }
        if (_currentProject is null) { throw new EditorOperationException("project_not_open", "Open a project before starting Preview without explicit paths."); }
        return parameters with
        {
            ConfigPath = _currentProject.PreviewPath,
            PackageRoot = _currentProject.PackageRoot,
            ProjectName = _currentProject.ProjectName
        };
    }

    private ProjectSessionInfo RequireProject(string? requestedName)
    {
        if (_currentProject is null) { throw new EditorOperationException("project_not_open", "Open a project before issuing this command."); }
        if (!string.IsNullOrWhiteSpace(requestedName) && !string.Equals(requestedName, _currentProject.ProjectName, StringComparison.OrdinalIgnoreCase))
        {
            throw new EditorOperationException("project_mismatch", $"Current project is {_currentProject.ProjectName}, not {requestedName}.");
        }
        return _currentProject;
    }

    private static string BoundedAnalysisMessage(string value)
    {
        if (value.Length <= 1024) return value;
        var length = 1024;
        if (char.IsHighSurrogate(value[length - 1]) && char.IsLowSurrogate(value[length])) length -= 1;
        return value[..length];
    }

    private async Task EmitAsync(string eventName, object data, string? requestId)
    {
        var handler = Notification;
        if (handler is null) { return; }
        await handler(new EditorSessionNotification(eventName, JsonSerializer.SerializeToElement(data, EditorProtocol.JsonOptions), requestId));
    }

    private async Task ForwardBackendNotificationAsync(EditorSessionNotification notification)
    {
        var handler = Notification;
        if (handler is not null) { await handler(notification); }
    }

    public async ValueTask DisposeAsync()
    {
        await _projectMutationGate.WaitAsync();
        try { await _backend.DisposeAsync(); }
        finally
        {
            _projectMutationGate.Release();
            _projectMutationGate.Dispose();
        }
    }
}
