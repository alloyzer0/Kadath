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
    Task<ProjectValidateResult> ValidateProjectAsync(ProjectSessionInfo project, CancellationToken cancellationToken);
    Task<ProjectModelSnapshot> GetProjectSnapshotAsync(ProjectSessionInfo project, CancellationToken cancellationToken);
    Task<HierarchySnapshot> GetHierarchySnapshotAsync(ProjectSessionInfo project, CancellationToken cancellationToken);
    Task<AssetCatalogSnapshot> GetAssetCatalogSnapshotAsync(ProjectSessionInfo project, CancellationToken cancellationToken);
    Task<PublicationSnapshot> GetPublicationSnapshotAsync(ProjectSessionInfo project, PublicationSnapshotQueryParameters parameters, CancellationToken cancellationToken);
    Task<AuthoringMutationResult> ApplyAuthoringAsync(ProjectSessionInfo project, AuthoringApplyParameters parameters, CancellationToken cancellationToken);
    Task<AuthoringMutationResult> UndoAuthoringAsync(ProjectSessionInfo project, AuthoringUndoParameters parameters, CancellationToken cancellationToken);
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
    Task<ProjectValidateResult> ValidateProjectAsync(ProjectValidateParameters parameters, string? requestId, CancellationToken cancellationToken = default);
    Task<ProjectModelSnapshot> GetProjectSnapshotAsync(SnapshotQueryParameters parameters, string? requestId, CancellationToken cancellationToken = default);
    Task<HierarchySnapshot> GetHierarchySnapshotAsync(SnapshotQueryParameters parameters, string? requestId, CancellationToken cancellationToken = default);
    Task<AssetCatalogSnapshot> GetAssetCatalogSnapshotAsync(SnapshotQueryParameters parameters, string? requestId, CancellationToken cancellationToken = default);
    Task<PublicationSnapshot> GetPublicationSnapshotAsync(PublicationSnapshotQueryParameters parameters, string? requestId, CancellationToken cancellationToken = default);
    Task<AuthoringMutationResult> ApplyAuthoringAsync(AuthoringApplyParameters parameters, string? requestId, CancellationToken cancellationToken = default);
    Task<AuthoringMutationResult> UndoAuthoringAsync(AuthoringUndoParameters parameters, string? requestId, CancellationToken cancellationToken = default);
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
        "project_validate",
        "project_snapshot",
        "hierarchy_snapshot",
        "asset_catalog_snapshot",
        "publication_snapshot",
        "authoring_apply",
        "authoring_undo",
        "bake_start",
        "watch_start",
        "watch_stop",
        "preview_start",
        "preview_stop",
        "shutdown"
    ];

    private readonly IEditorSessionBackend _backend;
    private readonly SemaphoreSlim _stateGate = new(1, 1);
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
        var project = await _backend.OpenProjectAsync(parameters, cancellationToken);
        _currentProject = project;
        await EmitAsync("project_opened", project, requestId);
        return project;
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

    public async Task<PublicationSnapshot> GetPublicationSnapshotAsync(PublicationSnapshotQueryParameters parameters, string? requestId, CancellationToken cancellationToken = default)
    {
        var project = RequireProject(parameters.ProjectName);
        var result = await _backend.GetPublicationSnapshotAsync(project, parameters, cancellationToken);
        await EmitAsync("publication_snapshot_created", result, requestId);
        return result;
    }

    public async Task<AuthoringMutationResult> ApplyAuthoringAsync(AuthoringApplyParameters parameters, string? requestId, CancellationToken cancellationToken = default)
    {
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

    public async Task<AuthoringMutationResult> UndoAuthoringAsync(AuthoringUndoParameters parameters, string? requestId, CancellationToken cancellationToken = default)
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
        await _stateGate.WaitAsync();
        try { await _backend.DisposeAsync(); }
        finally { _stateGate.Release(); _stateGate.Dispose(); }
    }
}
