using System.Text.Json;
using Kadath.Editor.Client;
using Kadath.Editor.Protocol;

namespace Kadath.Editor.ViewModels;

public enum EditorConnectionState { Disconnected, Connecting, Ready, Stopping, Faulted }

/// <summary>
/// UI 的单一工作区状态入口。它把 RPC 事件转为可绑定状态，并在同一处执行 capability gating。
/// </summary>
public sealed class EditorWorkspaceViewModel : ObservableObject, IAsyncDisposable
{
    private readonly IEditorViewDispatcher _dispatcher;
    private EditorConnectionState _connectionState;
    private string? _lastErrorCode;
    private string? _lastErrorMessage;
    private string? _lastEventName;
    private long _lastEventSequence;
    private EditorRpcConnectionClosed? _lastConnectionClosed;

    public EditorWorkspaceViewModel(IEditorRpcClient client, IEditorViewDispatcher? dispatcher = null)
    {
        Client = client ?? throw new ArgumentNullException(nameof(client));
        _dispatcher = dispatcher ?? new InlineEditorViewDispatcher();
        Client.EventReceived += HandleEventAsync;
        Client.ConnectionClosed += HandleConnectionClosedAsync;
    }

    public IEditorRpcClient Client { get; }
    public EditorConnectionState ConnectionState { get => _connectionState; private set => SetProperty(ref _connectionState, value); }
    public EditorCapabilitiesViewModel Capabilities { get; } = new();
    public EditorProjectViewModel Project { get; } = new();
    public EditorSnapshotViewModel<ProjectModelSnapshot> ProjectSnapshot { get; } = new();
    public EditorSnapshotViewModel<HierarchySnapshot> HierarchySnapshot { get; } = new();
    public EditorSnapshotViewModel<AssetCatalogSnapshot> AssetCatalogSnapshot { get; } = new();
    public EditorPublicationViewModel Publication { get; } = new();
    public EditorAuthoringViewModel Authoring { get; } = new();
    public EditorBakeViewModel Bake { get; } = new();
    public EditorWatchViewModel Watch { get; } = new();
    public EditorPreviewViewModel Preview { get; } = new();
    public string? LastErrorCode { get => _lastErrorCode; private set => SetProperty(ref _lastErrorCode, value); }
    public string? LastErrorMessage { get => _lastErrorMessage; private set => SetProperty(ref _lastErrorMessage, value); }
    public string? LastEventName { get => _lastEventName; private set => SetProperty(ref _lastEventName, value); }
    public long LastEventSequence { get => _lastEventSequence; private set => SetProperty(ref _lastEventSequence, value); }
    public EditorRpcConnectionClosed? LastConnectionClosed { get => _lastConnectionClosed; private set => SetProperty(ref _lastConnectionClosed, value); }

    public async Task ConnectAsync(CancellationToken cancellationToken = default)
    {
        await _dispatcher.InvokeAsync(() =>
        {
            ConnectionState = EditorConnectionState.Connecting;
            ClearError();
        }).ConfigureAwait(false);
        try
        {
            await Client.ConnectAsync(cancellationToken).ConfigureAwait(false);
            var capabilities = await Client.GetCapabilitiesAsync(cancellationToken).ConfigureAwait(false);
            await _dispatcher.InvokeAsync(() =>
            {
                Capabilities.Apply(capabilities);
                ConnectionState = EditorConnectionState.Ready;
            }).ConfigureAwait(false);
        }
        catch (Exception exception)
        {
            await ApplyExceptionAsync(exception, "connect_failed").ConfigureAwait(false);
            throw;
        }
    }

    public async Task<ProjectSessionInfo> OpenProjectAsync(ProjectOpenParameters parameters, CancellationToken cancellationToken = default)
    {
        EnsureCommand(Capabilities.CanOpenProject, "project_open");
        await _dispatcher.InvokeAsync(Project.BeginOpen).ConfigureAwait(false);
        try
        {
            var result = await Client.OpenProjectAsync(parameters, cancellationToken).ConfigureAwait(false);
            await _dispatcher.InvokeAsync(() => Project.ApplyOpened(result)).ConfigureAwait(false);
            return result;
        }
        catch (Exception exception)
        {
            await ApplyProjectExceptionAsync(exception).ConfigureAwait(false);
            throw;
        }
    }

    public async Task<ProjectValidateResult> ValidateProjectAsync(string? projectName = null, CancellationToken cancellationToken = default)
    {
        EnsureCommand(Capabilities.CanValidateProject, "project_validate");
        await _dispatcher.InvokeAsync(Project.BeginValidate).ConfigureAwait(false);
        try
        {
            var result = await Client.ValidateProjectAsync(new ProjectValidateParameters(projectName), cancellationToken).ConfigureAwait(false);
            await _dispatcher.InvokeAsync(() => Project.ApplyValidation(result)).ConfigureAwait(false);
            return result;
        }
        catch (Exception exception)
        {
            await ApplyProjectExceptionAsync(exception).ConfigureAwait(false);
            throw;
        }
    }

    public async Task RefreshSnapshotsAsync(string? projectName = null, CancellationToken cancellationToken = default)
    {
        // 先验证全部 capability，避免旧 Service 上只刷新一半快照。
        EnsureCommand(Capabilities.CanReadProjectSnapshot, "project_snapshot");
        EnsureCommand(Capabilities.CanReadHierarchySnapshot, "hierarchy_snapshot");
        EnsureCommand(Capabilities.CanReadAssetCatalogSnapshot, "asset_catalog_snapshot");
        await RefreshProjectSnapshotAsync(projectName, cancellationToken).ConfigureAwait(false);
        await RefreshHierarchySnapshotAsync(projectName, cancellationToken).ConfigureAwait(false);
        await RefreshAssetCatalogSnapshotAsync(projectName, cancellationToken).ConfigureAwait(false);
        if (Capabilities.CanReadPublicationSnapshot)
        {
            await RefreshPublicationAsync(projectName, cancellationToken: cancellationToken).ConfigureAwait(false);
        }
    }

    public async Task<ProjectModelSnapshot> RefreshProjectSnapshotAsync(string? projectName = null, CancellationToken cancellationToken = default)
    {
        EnsureCommand(Capabilities.CanReadProjectSnapshot, "project_snapshot");
        await _dispatcher.InvokeAsync(ProjectSnapshot.Begin).ConfigureAwait(false);
        try
        {
            var result = await Client.GetProjectSnapshotAsync(new SnapshotQueryParameters(projectName), cancellationToken).ConfigureAwait(false);
            await _dispatcher.InvokeAsync(() => ProjectSnapshot.Apply(result)).ConfigureAwait(false);
            return result;
        }
        catch (Exception exception)
        {
            await ApplySnapshotExceptionAsync(ProjectSnapshot, exception).ConfigureAwait(false);
            throw;
        }
    }

    public async Task<HierarchySnapshot> RefreshHierarchySnapshotAsync(string? projectName = null, CancellationToken cancellationToken = default)
    {
        EnsureCommand(Capabilities.CanReadHierarchySnapshot, "hierarchy_snapshot");
        await _dispatcher.InvokeAsync(HierarchySnapshot.Begin).ConfigureAwait(false);
        try
        {
            var result = await Client.GetHierarchySnapshotAsync(new SnapshotQueryParameters(projectName), cancellationToken).ConfigureAwait(false);
            await _dispatcher.InvokeAsync(() => HierarchySnapshot.Apply(result)).ConfigureAwait(false);
            return result;
        }
        catch (Exception exception)
        {
            await ApplySnapshotExceptionAsync(HierarchySnapshot, exception).ConfigureAwait(false);
            throw;
        }
    }

    public async Task<AssetCatalogSnapshot> RefreshAssetCatalogSnapshotAsync(string? projectName = null, CancellationToken cancellationToken = default)
    {
        EnsureCommand(Capabilities.CanReadAssetCatalogSnapshot, "asset_catalog_snapshot");
        await _dispatcher.InvokeAsync(AssetCatalogSnapshot.Begin).ConfigureAwait(false);
        try
        {
            var result = await Client.GetAssetCatalogSnapshotAsync(new SnapshotQueryParameters(projectName), cancellationToken).ConfigureAwait(false);
            await _dispatcher.InvokeAsync(() => AssetCatalogSnapshot.Apply(result)).ConfigureAwait(false);
            return result;
        }
        catch (Exception exception)
        {
            await ApplySnapshotExceptionAsync(AssetCatalogSnapshot, exception).ConfigureAwait(false);
            throw;
        }
    }
    public async Task<PublicationSnapshot> RefreshPublicationAsync(string? projectName = null, string profile = "debug", CancellationToken cancellationToken = default)
    {
        EnsureCommand(Capabilities.CanReadPublicationSnapshot, "publication_snapshot");
        await _dispatcher.InvokeAsync(() => Publication.Begin(profile)).ConfigureAwait(false);
        try
        {
            var result = await Client.GetPublicationSnapshotAsync(new PublicationSnapshotQueryParameters(projectName, profile), cancellationToken).ConfigureAwait(false);
            await _dispatcher.InvokeAsync(() => Publication.Apply(result)).ConfigureAwait(false);
            return result;
        }
        catch (Exception exception)
        {
            await ApplyPublicationExceptionAsync(exception).ConfigureAwait(false);
            throw;
        }
    }

    public async Task<EditorBakeResult?> BakeChangesAsync(string profile = "debug", CancellationToken cancellationToken = default)
    {
        EnsureCommand(Capabilities.CanBake, "bake_start");
        EnsureCommand(Capabilities.CanReadPublicationSnapshot, "publication_snapshot");
        EnsureManualBakeAllowed();
        var projectName = Project.Session?.ProjectName;
        await RefreshPublicationAsync(projectName, profile, cancellationToken).ConfigureAwait(false);
        var target = Publication.RecommendedBakeTarget;
        if (target is null) { return null; }
        return await BakeAsync(new BakeStartParameters(target, profile), cancellationToken).ConfigureAwait(false);
    }

    public async Task<AuthoringMutationResult> ApplyAuthoringAsync(AuthoringApplyParameters parameters, CancellationToken cancellationToken = default)
    {
        EnsureCommand(Capabilities.CanApplyAuthoring, "authoring_apply");
        await _dispatcher.InvokeAsync(() => Authoring.Begin("apply")).ConfigureAwait(false);
        try
        {
            var result = await Client.ApplyAuthoringAsync(parameters, cancellationToken).ConfigureAwait(false);
            await _dispatcher.InvokeAsync(() => ApplyAuthoringResult(result)).ConfigureAwait(false);
            await RefreshPublicationAfterOperationAsync(result.ProjectName, Publication.Profile, cancellationToken).ConfigureAwait(false);
            return result;
        }
        catch (Exception exception)
        {
            await ApplyAuthoringExceptionAsync(exception).ConfigureAwait(false);
            throw;
        }
    }

    public async Task<AuthoringMutationResult> UndoAuthoringAsync(AuthoringUndoParameters parameters, CancellationToken cancellationToken = default)
    {
        EnsureCommand(Capabilities.CanUndoAuthoring, "authoring_undo");
        await _dispatcher.InvokeAsync(() => Authoring.Begin("undo")).ConfigureAwait(false);
        try
        {
            var result = await Client.UndoAuthoringAsync(parameters, cancellationToken).ConfigureAwait(false);
            await _dispatcher.InvokeAsync(() => ApplyAuthoringResult(result)).ConfigureAwait(false);
            await RefreshPublicationAfterOperationAsync(result.ProjectName, Publication.Profile, cancellationToken).ConfigureAwait(false);
            return result;
        }
        catch (Exception exception)
        {
            await ApplyAuthoringExceptionAsync(exception).ConfigureAwait(false);
            throw;
        }
    }

    private void ApplyAuthoringResult(AuthoringMutationResult result)
    {
        Authoring.Apply(result);
        ProjectSnapshot.Apply(result.ProjectSnapshot);
        HierarchySnapshot.Apply(result.HierarchySnapshot);
    }
    public async Task<EditorBakeResult> BakeAsync(BakeStartParameters parameters, CancellationToken cancellationToken = default)
    {
        EnsureCommand(Capabilities.CanBake, "bake_start");
        EnsureManualBakeAllowed();
        await _dispatcher.InvokeAsync(() => Bake.Begin(parameters.Target, parameters.Profile)).ConfigureAwait(false);
        try
        {
            var result = await Client.StartBakeAsync(parameters, cancellationToken).ConfigureAwait(false);
            await _dispatcher.InvokeAsync(() => Bake.ApplyCompleted(result)).ConfigureAwait(false);
            await _dispatcher.InvokeAsync(() => Publication.ApplyBakeResult(result)).ConfigureAwait(false);
            await RefreshPublicationAfterOperationAsync(Project.Session?.ProjectName, parameters.Profile, cancellationToken).ConfigureAwait(false);
            return result;
        }
        catch (Exception exception)
        {
            await ApplyBakeExceptionAsync(exception).ConfigureAwait(false);
            throw;
        }
    }

    public async Task<EditorWatchResult> StartWatchAsync(WatchStartParameters parameters, CancellationToken cancellationToken = default)
    {
        EnsureCommand(Capabilities.CanStartWatch, "watch_start");
        if (Preview.OwnsPublicationSync)
        {
            throw new EditorRpcException("publication_preview_owns_bake", "Preview live-bake/watch is already responsible for derived artifacts.");
        }
        await _dispatcher.InvokeAsync(() => Watch.BeginStart(parameters.Target, parameters.Profile)).ConfigureAwait(false);
        try
        {
            var result = await Client.StartWatchAsync(parameters, cancellationToken).ConfigureAwait(false);
            await _dispatcher.InvokeAsync(() =>
            {
                Watch.ApplyStarted(result);
                if (result.InitialBake is not null)
                {
                    Bake.ApplyCompleted(result.InitialBake);
                    Publication.ApplyBakeResult(result.InitialBake);
                }
            }).ConfigureAwait(false);
            await RefreshPublicationAfterOperationAsync(result.ProjectName, parameters.Profile, cancellationToken).ConfigureAwait(false);
            return result;
        }
        catch (Exception exception)
        {
            await ApplyWatchExceptionAsync(exception).ConfigureAwait(false);
            throw;
        }
    }

    public async Task<EditorWatchResult> StopWatchAsync(CancellationToken cancellationToken = default)
    {
        EnsureCommand(Capabilities.CanStopWatch, "watch_stop");
        await _dispatcher.InvokeAsync(Watch.BeginStop).ConfigureAwait(false);
        try
        {
            var result = await Client.StopWatchAsync(cancellationToken).ConfigureAwait(false);
            await _dispatcher.InvokeAsync(Watch.ApplyStopped).ConfigureAwait(false);
            return result;
        }
        catch (Exception exception)
        {
            await ApplyWatchExceptionAsync(exception).ConfigureAwait(false);
            throw;
        }
    }

    public async Task<PreviewStartResult> StartPreviewAsync(PreviewStartParameters parameters, CancellationToken cancellationToken = default)
    {
        EnsureCommand(Capabilities.CanStartPreview, "preview_start");
        if (Preview.OwnsPublicationSync)
        {
            throw new EditorRpcException("publication_preview_owns_bake", "Confirm the previous Preview has stopped before starting another publication writer.");
        }
        if (parameters.LiveBake && parameters.WatchChanges && Watch.State is EditorWatchState.Starting or EditorWatchState.Watching or EditorWatchState.Stopping)
        {
            throw new EditorRpcException("publication_watch_owns_bake", "Stop the Service watch before starting Preview live-bake/watch.");
        }
        await _dispatcher.InvokeAsync(() => Preview.BeginStart(parameters)).ConfigureAwait(false);
        try
        {
            var result = await Client.StartPreviewAsync(parameters, cancellationToken).ConfigureAwait(false);
            await _dispatcher.InvokeAsync(() => Preview.ApplyStarted(result)).ConfigureAwait(false);
            return result;
        }
        catch (Exception exception)
        {
            await ApplyPreviewExceptionAsync(exception).ConfigureAwait(false);
            throw;
        }
    }

    public async Task<PreviewStopResult> StopPreviewAsync(CancellationToken cancellationToken = default)
    {
        EnsureCommand(Capabilities.CanStopPreview, "preview_stop");
        await _dispatcher.InvokeAsync(Preview.BeginStop).ConfigureAwait(false);
        try
        {
            var result = await Client.StopPreviewAsync(cancellationToken).ConfigureAwait(false);
            await _dispatcher.InvokeAsync(() => Preview.ApplyStopped(null)).ConfigureAwait(false);
            return result;
        }
        catch (Exception exception)
        {
            await ApplyPreviewExceptionAsync(exception).ConfigureAwait(false);
            throw;
        }
    }

    public async Task ShutdownAsync(CancellationToken cancellationToken = default)
    {
        if (!Capabilities.SupportsCommand("shutdown")) { throw new EditorRpcException("unsupported_command", "Editor Service does not support shutdown."); }
        await _dispatcher.InvokeAsync(() => ConnectionState = EditorConnectionState.Stopping).ConfigureAwait(false);
        try { await Client.ShutdownAsync(cancellationToken).ConfigureAwait(false); }
        catch (Exception exception)
        {
            await ApplyExceptionAsync(exception, "shutdown_failed").ConfigureAwait(false);
            throw;
        }
    }

    private async Task HandleConnectionClosedAsync(EditorRpcConnectionClosed notification)
    {
        await _dispatcher.InvokeAsync(() =>
        {
            LastConnectionClosed = notification;
            LastEventName = "connection_closed";
            if (notification.Expected)
            {
                // Shutdown 请求阶段先显示 Stopping；底层真正关闭后进入稳定的 Disconnected。
                LastErrorCode = null;
                LastErrorMessage = null;
                ConnectionState = EditorConnectionState.Disconnected;
            }
            else
            {
                LastErrorCode = notification.ErrorCode ?? "connection_closed";
                LastErrorMessage = notification.Message;
                ConnectionState = EditorConnectionState.Faulted;
            }
        }).ConfigureAwait(false);
    }

    private async Task HandleEventAsync(EditorEvent notification)
    {
        await _dispatcher.InvokeAsync(() =>
        {
            LastEventName = notification.Event;
            LastEventSequence = notification.Sequence;
            ApplyEvent(notification);
        }).ConfigureAwait(false);
    }

    private void ApplyEvent(EditorEvent notification)
    {
        switch (notification.Event)
        {
            case "project_opened":
                if (TryRead(notification.Data, out ProjectSessionInfo? session) && session is not null) { Project.ApplyOpened(session); Authoring.Reset(); Publication.Reset(); }
                break;
            case "project_validated":
                if (TryRead(notification.Data, out ProjectValidateResult? validation) && validation is not null) { Project.ApplyValidation(validation); }
                break;
            case "project_snapshot_created":
                if (TryRead(notification.Data, out ProjectModelSnapshot? projectSnapshot) && projectSnapshot is not null) { ProjectSnapshot.Apply(projectSnapshot); }
                break;
            case "hierarchy_snapshot_created":
                if (TryRead(notification.Data, out HierarchySnapshot? hierarchySnapshot) && hierarchySnapshot is not null) { HierarchySnapshot.Apply(hierarchySnapshot); }
                break;
            case "asset_catalog_snapshot_created":
                if (TryRead(notification.Data, out AssetCatalogSnapshot? assetSnapshot) && assetSnapshot is not null) { AssetCatalogSnapshot.Apply(assetSnapshot); }
                break;
            case "publication_snapshot_created":
                if (TryRead(notification.Data, out PublicationSnapshot? publicationSnapshot) && publicationSnapshot is not null) { Publication.Apply(publicationSnapshot); }
                break;
            case "authoring_apply_started":
                Authoring.Begin("apply");
                break;
            case "authoring_undo_started":
                Authoring.Begin("undo");
                break;
            case "authoring_apply_completed":
            case "authoring_undo_completed":
                if (TryRead(notification.Data, out AuthoringMutationResult? mutation) && mutation is not null) { ApplyAuthoringResult(mutation); }
                break;
            case "authoring_apply_failed":
            case "authoring_undo_failed":
                Authoring.ApplyFailure(
                    ReadString(notification.Data, "errorCode") ?? "authoring_failed",
                    ReadString(notification.Data, "message") ?? "Authoring operation failed.");
                break;            case "bake_started":
                Bake.Begin(
                    ReadString(notification.Data, "target") ?? "Both",
                    ReadString(notification.Data, "profile") ?? "debug",
                    ReadString(notification.Data, "revision"));
                break;
            case "bake_completed":
                if (TryRead(notification.Data, out EditorBakeResult? baked) && baked is not null) { Bake.ApplyCompleted(baked); Publication.ApplyBakeResult(baked); }
                break;
            case "bake_failed":
                Bake.ApplyFailed(
                    ReadString(notification.Data, "errorCode") ?? "bake_failed",
                    ReadString(notification.Data, "message") ?? "Bake failed.",
                    ReadBool(notification.Data, "retainedArtifact") ?? true);
                break;
            case "watch_started":
                if (TryRead(notification.Data, out EditorWatchResult? started) && started is not null) { Watch.ApplyStarted(started); }
                break;
            case "watch_stopped":
                Watch.ApplyStopped();
                break;
            case "source_change_detected":
                Watch.ApplySourceChange(ReadString(notification.Data, "target"), ReadString(notification.Data, "revision"));
                break;
            case "preview_surface_created":
                if (TryRead(notification.Data, out PreviewSurfaceDescriptor? surface) && surface is not null) { Preview.ApplySurface(surface); }
                break;
            case "preview_status":
                ApplyPreviewStatus(notification.Data);
                break;
            case "preview_reload_requested":
            case "preview_reload_acknowledged":
            case "preview_reload_failed":
            case "preview_reload_stale":
                if (TryRead(notification.Data, out PreviewReloadNotification? reload) && reload is not null)
                {
                    Preview.ApplyReload(reload);
                }
                break;
            case "preview_stopped":
                Preview.ApplyStopped(ReadInt(notification.Data, "exitCode"));
                break;
            case "service_stopping":
                ConnectionState = EditorConnectionState.Stopping;
                break;
        }
    }

    private void ApplyPreviewStatus(JsonElement? data)
    {
        var name = ReadString(data, "name");
        var value = ReadValueAsString(data, "value");
        var processId = string.Equals(name, "runtime_pid", StringComparison.OrdinalIgnoreCase) && int.TryParse(value, out var parsed)
            ? parsed
            : (int?)null;
        Preview.ApplyStatus(name, value, processId);
    }

    private static bool TryRead<T>(JsonElement? data, out T? value)
    {
        if (data is { } element)
        {
            try
            {
                value = JsonSerializer.Deserialize<T>(element.GetRawText(), EditorProtocol.JsonOptions);
                return value is not null;
            }
            catch (JsonException) { }
        }
        value = default;
        return false;
    }

    private static string? ReadString(JsonElement? data, string property)
    {
        if (data is not { } element || !element.TryGetProperty(property, out var value)) { return null; }
        return value.ValueKind switch
        {
            JsonValueKind.String => value.GetString(),
            JsonValueKind.Number or JsonValueKind.True or JsonValueKind.False => value.ToString(),
            _ => null
        };
    }

    private static string? ReadValueAsString(JsonElement? data, string property) => ReadString(data, property);

    private static int? ReadInt(JsonElement? data, string property)
    {
        if (data is not { } element || !element.TryGetProperty(property, out var value)) { return null; }
        if (value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var number)) { return number; }
        return int.TryParse(value.ToString(), out var parsed) ? parsed : null;
    }

    private static bool? ReadBool(JsonElement? data, string property)
    {
        if (data is not { } element || !element.TryGetProperty(property, out var value)) { return null; }
        if (value.ValueKind is JsonValueKind.True or JsonValueKind.False) { return value.GetBoolean(); }
        return bool.TryParse(value.ToString(), out var parsed) ? parsed : null;
    }

    private void EnsureCommand(bool supported, string command)
    {
        if (!supported) { throw new EditorRpcException("unsupported_command", $"Editor Service capability is not available: {command}"); }
    }

    private async Task ApplyProjectExceptionAsync(Exception exception) =>
        await ApplyExceptionAsync(exception, "project_operation_failed", Project.ApplyFailure).ConfigureAwait(false);

    private async Task ApplySnapshotExceptionAsync<TSnapshot>(EditorSnapshotViewModel<TSnapshot> snapshot, Exception exception)
        where TSnapshot : class
    {
        var (code, message) = exception switch
        {
            EditorRpcException rpc => (rpc.Code, rpc.Message),
            OperationCanceledException => ("cancelled", "The snapshot request was cancelled."),
            _ => ("snapshot_failed", exception.Message)
        };
        await _dispatcher.InvokeAsync(() => snapshot.ApplyFailure(code, message)).ConfigureAwait(false);
    }
    private async Task ApplyAuthoringExceptionAsync(Exception exception)
    {
        var (code, message) = exception switch
        {
            EditorRpcException rpc => (rpc.Code, rpc.Message),
            OperationCanceledException => ("cancelled", "The authoring operation was cancelled."),
            _ => ("authoring_failed", exception.Message)
        };
        await _dispatcher.InvokeAsync(() => Authoring.ApplyFailure(code, message)).ConfigureAwait(false);
    }
    private async Task ApplyBakeExceptionAsync(Exception exception) =>
        await ApplyExceptionAsync(exception, "bake_failed", (code, message) => Bake.ApplyFailed(code, message, true)).ConfigureAwait(false);

    private async Task ApplyWatchExceptionAsync(Exception exception) =>
        await ApplyExceptionAsync(exception, "watch_failed", Watch.ApplyFailure).ConfigureAwait(false);

    private async Task ApplyPreviewExceptionAsync(Exception exception) =>
        await ApplyExceptionAsync(exception, "preview_failed", Preview.ApplyFailure).ConfigureAwait(false);

    private async Task ApplyExceptionAsync(Exception exception, string fallbackCode)
    {
        await ApplyExceptionAsync(exception, fallbackCode, (code, message) =>
        {
            LastErrorCode = code;
            LastErrorMessage = message;
            ConnectionState = EditorConnectionState.Faulted;
        }).ConfigureAwait(false);
    }

    private async Task ApplyExceptionAsync(Exception exception, string fallbackCode, Action<string, string> apply)
    {
        var (code, message) = exception switch
        {
            EditorRpcException rpc => (rpc.Code, rpc.Message),
            OperationCanceledException => ("cancelled", "The editor operation was cancelled."),
            _ => (fallbackCode, exception.Message)
        };
        await _dispatcher.InvokeAsync(() => apply(code, message)).ConfigureAwait(false);
    }

    private async Task ApplyPublicationExceptionAsync(Exception exception) =>
        await ApplyExceptionAsync(exception, "publication_snapshot_failed", Publication.ApplyFailure).ConfigureAwait(false);

    private async Task RefreshPublicationAfterOperationAsync(string? projectName, string profile, CancellationToken cancellationToken)
    {
        if (!Capabilities.CanReadPublicationSnapshot) { return; }
        try
        {
            await RefreshPublicationAsync(projectName, profile, cancellationToken).ConfigureAwait(false);
        }
        catch
        {
            // Authoring/Bake 已完成；发布快照失败只影响诊断，不伪装成源事务失败。
        }
    }

    private void EnsureManualBakeAllowed()
    {
        // 派生目录同一时刻只允许一个持续写入者，避免手动 bake 与 watcher 交错提交 manifest/artifact。
        if (Watch.State is EditorWatchState.Starting or EditorWatchState.Watching or EditorWatchState.Stopping)
        {
            throw new EditorRpcException("publication_watch_owns_bake", "Stop the Service watch before running a manual bake.");
        }
        if (Preview.OwnsPublicationSync)
        {
            throw new EditorRpcException("publication_preview_owns_bake", "Preview live-bake/watch already owns publication synchronization.");
        }
    }

    private void ClearError()
    {
        LastErrorCode = null;
        LastErrorMessage = null;
    }

    public async ValueTask DisposeAsync()
    {
        Client.EventReceived -= HandleEventAsync;
        try { await Client.DisposeAsync().ConfigureAwait(false); }
        finally { Client.ConnectionClosed -= HandleConnectionClosedAsync; }
    }
}
