using System.Collections.Concurrent;
using System.Text.Json;
using Kadath.Editor.Protocol;

namespace Kadath.Editor.Client;

public sealed class EditorRpcException : Exception
{
    public EditorRpcException(string code, string message, string? requestId = null, Exception? innerException = null)
        : base(message, innerException)
    {
        Code = code;
        RequestId = requestId;
    }

    public string Code { get; }
    public string? RequestId { get; }
}

public enum EditorRpcConnectionCloseReason
{
    EndOfStream,
    ProtocolError,
    TransportError,
    Shutdown,
    Disposed
}

/// <summary>
/// Source-level 连接生命周期通知；它不属于 wire Protocol DTO，也不会写入 JSONL。
/// </summary>
public sealed record EditorRpcConnectionClosed(
    EditorRpcConnectionCloseReason Reason,
    bool Expected,
    string? ErrorCode,
    string? Message);

/// <summary>
/// Avalonia ViewModel 与测试共用的强类型 RPC seam。
/// 请求关联、握手、JSONL 解析和事件顺序都封装在实现内部。
/// </summary>
public interface IEditorRpcClient : IAsyncDisposable
{
    bool IsConnected { get; }
    EditorHello? Hello { get; }
    long LastEventSequence { get; }
    EditorRpcConnectionClosed? LastConnectionClosed { get; }
    event Func<EditorEvent, Task>? EventReceived;
    event Func<EditorRpcConnectionClosed, Task>? ConnectionClosed;

    Task ConnectAsync(CancellationToken cancellationToken = default);
    Task<EditorCapabilities> GetCapabilitiesAsync(CancellationToken cancellationToken = default);
    Task<ProjectSessionInfo> OpenProjectAsync(ProjectOpenParameters parameters, CancellationToken cancellationToken = default);
    Task<ProjectValidateResult> ValidateProjectAsync(ProjectValidateParameters parameters, CancellationToken cancellationToken = default);
    Task<ProjectModelSnapshot> GetProjectSnapshotAsync(SnapshotQueryParameters parameters, CancellationToken cancellationToken = default);
    Task<HierarchySnapshot> GetHierarchySnapshotAsync(SnapshotQueryParameters parameters, CancellationToken cancellationToken = default);
    Task<AssetCatalogSnapshot> GetAssetCatalogSnapshotAsync(SnapshotQueryParameters parameters, CancellationToken cancellationToken = default);
    Task<PublicationSnapshot> GetPublicationSnapshotAsync(PublicationSnapshotQueryParameters parameters, CancellationToken cancellationToken = default);
    Task<AuthoringMutationResult> ApplyAuthoringAsync(AuthoringApplyParameters parameters, CancellationToken cancellationToken = default);
    Task<AuthoringMutationResult> UndoAuthoringAsync(AuthoringUndoParameters parameters, CancellationToken cancellationToken = default);
    Task<EditorBakeResult> StartBakeAsync(BakeStartParameters parameters, CancellationToken cancellationToken = default);
    Task<EditorWatchResult> StartWatchAsync(WatchStartParameters parameters, CancellationToken cancellationToken = default);
    Task<EditorWatchResult> StopWatchAsync(CancellationToken cancellationToken = default);
    Task<PreviewStartResult> StartPreviewAsync(PreviewStartParameters parameters, CancellationToken cancellationToken = default);
    Task<PreviewStopResult> StopPreviewAsync(CancellationToken cancellationToken = default);
    Task ShutdownAsync(CancellationToken cancellationToken = default);
}

public sealed class EditorRpcClient : IEditorRpcClient
{
    private readonly IEditorRpcTransport _transport;
    private readonly string _clientName;
    private readonly string _clientVersion;
    private readonly ConcurrentDictionary<string, TaskCompletionSource<EditorRpcResponse>> _pending = new();
    private readonly TaskCompletionSource<EditorHello> _helloCompletion = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly CancellationTokenSource _lifetime = new();
    private Task? _readLoop;
    private long _requestSequence;
    private long _lastEventSequence;
    private int _connectStarted;
    private int _disposed;
    private int _shutdownRequested;
    private int _connectionClosedPublished;

    public EditorRpcClient(IEditorRpcTransport transport, string clientName, string clientVersion)
    {
        _transport = transport;
        _clientName = string.IsNullOrWhiteSpace(clientName) ? throw new ArgumentException("Client name is required.", nameof(clientName)) : clientName;
        _clientVersion = string.IsNullOrWhiteSpace(clientVersion) ? throw new ArgumentException("Client version is required.", nameof(clientVersion)) : clientVersion;
    }

    public bool IsConnected { get; private set; }
    public EditorHello? Hello { get; private set; }
    public long LastEventSequence => Interlocked.Read(ref _lastEventSequence);
    public EditorRpcConnectionClosed? LastConnectionClosed { get; private set; }
    public event Func<EditorEvent, Task>? EventReceived;
    public event Func<EditorRpcConnectionClosed, Task>? ConnectionClosed;

    public async Task ConnectAsync(CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(_disposed != 0, this);
        if (Interlocked.Exchange(ref _connectStarted, 1) != 0) { throw new InvalidOperationException("The RPC client can only connect once."); }

        await _transport.StartAsync(cancellationToken).ConfigureAwait(false);
        _readLoop = Task.Run(() => ReadLoopAsync(_lifetime.Token), CancellationToken.None);
        try
        {
            Hello = await _helloCompletion.Task.WaitAsync(cancellationToken).ConfigureAwait(false);
            IsConnected = true;
        }
        catch
        {
            _lifetime.Cancel();
            throw;
        }
    }

    public Task<EditorCapabilities> GetCapabilitiesAsync(CancellationToken cancellationToken = default) =>
        RequestAsync<object?, EditorCapabilities>("get_capabilities", null, cancellationToken);

    public Task<ProjectSessionInfo> OpenProjectAsync(ProjectOpenParameters parameters, CancellationToken cancellationToken = default) =>
        RequestAsync<ProjectOpenParameters, ProjectSessionInfo>("project_open", parameters, cancellationToken);

    public Task<ProjectValidateResult> ValidateProjectAsync(ProjectValidateParameters parameters, CancellationToken cancellationToken = default) =>
        RequestAsync<ProjectValidateParameters, ProjectValidateResult>("project_validate", parameters, cancellationToken);

    public Task<ProjectModelSnapshot> GetProjectSnapshotAsync(SnapshotQueryParameters parameters, CancellationToken cancellationToken = default) =>
        RequestAsync<SnapshotQueryParameters, ProjectModelSnapshot>("project_snapshot", parameters, cancellationToken);

    public Task<HierarchySnapshot> GetHierarchySnapshotAsync(SnapshotQueryParameters parameters, CancellationToken cancellationToken = default) =>
        RequestAsync<SnapshotQueryParameters, HierarchySnapshot>("hierarchy_snapshot", parameters, cancellationToken);

    public Task<AssetCatalogSnapshot> GetAssetCatalogSnapshotAsync(SnapshotQueryParameters parameters, CancellationToken cancellationToken = default) =>
        RequestAsync<SnapshotQueryParameters, AssetCatalogSnapshot>("asset_catalog_snapshot", parameters, cancellationToken);

    public Task<PublicationSnapshot> GetPublicationSnapshotAsync(PublicationSnapshotQueryParameters parameters, CancellationToken cancellationToken = default) =>
        RequestAsync<PublicationSnapshotQueryParameters, PublicationSnapshot>("publication_snapshot", parameters, cancellationToken);

    public Task<AuthoringMutationResult> ApplyAuthoringAsync(AuthoringApplyParameters parameters, CancellationToken cancellationToken = default) =>
        RequestAsync<AuthoringApplyParameters, AuthoringMutationResult>("authoring_apply", parameters, cancellationToken);

    public Task<AuthoringMutationResult> UndoAuthoringAsync(AuthoringUndoParameters parameters, CancellationToken cancellationToken = default) =>
        RequestAsync<AuthoringUndoParameters, AuthoringMutationResult>("authoring_undo", parameters, cancellationToken);
    public Task<EditorBakeResult> StartBakeAsync(BakeStartParameters parameters, CancellationToken cancellationToken = default) =>
        RequestAsync<BakeStartParameters, EditorBakeResult>("bake_start", parameters, cancellationToken);

    public Task<EditorWatchResult> StartWatchAsync(WatchStartParameters parameters, CancellationToken cancellationToken = default) =>
        RequestAsync<WatchStartParameters, EditorWatchResult>("watch_start", parameters, cancellationToken);

    public Task<EditorWatchResult> StopWatchAsync(CancellationToken cancellationToken = default) =>
        RequestAsync<object?, EditorWatchResult>("watch_stop", null, cancellationToken);

    public Task<PreviewStartResult> StartPreviewAsync(PreviewStartParameters parameters, CancellationToken cancellationToken = default) =>
        RequestAsync<PreviewStartParameters, PreviewStartResult>("preview_start", parameters, cancellationToken);

    public Task<PreviewStopResult> StopPreviewAsync(CancellationToken cancellationToken = default) =>
        RequestAsync<object?, PreviewStopResult>("preview_stop", null, cancellationToken);

    public async Task ShutdownAsync(CancellationToken cancellationToken = default)
    {
        Interlocked.Exchange(ref _shutdownRequested, 1);
        _ = await RequestRawAsync<object?>("shutdown", null, cancellationToken).ConfigureAwait(false);
    }

    private async Task<TResponse> RequestAsync<TParameters, TResponse>(
        string method,
        TParameters parameters,
        CancellationToken cancellationToken)
    {
        var result = await RequestRawAsync(method, parameters, cancellationToken).ConfigureAwait(false);
        if (result is null) { throw new EditorRpcException("missing_result", $"RPC method {method} returned no result."); }
        return JsonSerializer.Deserialize<TResponse>(result.Value.GetRawText(), EditorProtocol.JsonOptions)
            ?? throw new EditorRpcException("invalid_result", $"RPC method {method} returned an empty result.");
    }

    private async Task<JsonElement?> RequestRawAsync<TParameters>(
        string method,
        TParameters parameters,
        CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(_disposed != 0, this);
        if (!IsConnected) { throw new InvalidOperationException("ConnectAsync must complete before sending requests."); }

        var id = $"ui-{Interlocked.Increment(ref _requestSequence)}";
        JsonElement? parameterElement = parameters is null
            ? null
            : JsonSerializer.SerializeToElement(parameters, EditorProtocol.JsonOptions);
        var request = new EditorRpcRequest(EditorProtocol.SchemaVersion, "request", id, method, parameterElement);
        var completion = new TaskCompletionSource<EditorRpcResponse>(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!_pending.TryAdd(id, completion)) { throw new InvalidOperationException($"Duplicate RPC request id: {id}"); }

        using var cancellationRegistration = cancellationToken.Register(() =>
        {
            if (_pending.TryRemove(id, out var removed)) { removed.TrySetCanceled(cancellationToken); }
        });

        try
        {
            await _transport.SendLineAsync(JsonSerializer.Serialize(request, EditorProtocol.JsonOptions), cancellationToken).ConfigureAwait(false);
            var response = await completion.Task.ConfigureAwait(false);
            if (!response.Ok)
            {
                throw new EditorRpcException(
                    response.Error?.Code ?? "rpc_failed",
                    response.Error?.Message ?? $"RPC method {method} failed.",
                    id);
            }
            return response.Result;
        }
        catch
        {
            _pending.TryRemove(id, out _);
            throw;
        }
    }

    private async Task ReadLoopAsync(CancellationToken cancellationToken)
    {
        Exception? failure = null;
        try
        {
            while (!cancellationToken.IsCancellationRequested && await _transport.ReadLineAsync(cancellationToken).ConfigureAwait(false) is { } line)
            {
                if (string.IsNullOrWhiteSpace(line)) { continue; }
                await HandleLineAsync(line, cancellationToken).ConfigureAwait(false);
            }
            if (!cancellationToken.IsCancellationRequested) { failure = new EndOfStreamException("The Editor Service closed its JSONL output."); }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { }
        catch (Exception exception) { failure = exception; }
        finally
        {
            IsConnected = false;
            if (failure is not null)
            {
                _helloCompletion.TrySetException(failure);
                foreach (var entry in _pending)
                {
                    if (_pending.TryRemove(entry.Key, out var completion)) { completion.TrySetException(failure); }
                }
            }
            await PublishConnectionClosedAsync(ClassifyConnectionClosed(failure)).ConfigureAwait(false);
        }
    }

    private EditorRpcConnectionClosed ClassifyConnectionClosed(Exception? failure)
    {
        if (Volatile.Read(ref _disposed) != 0)
        {
            return new EditorRpcConnectionClosed(EditorRpcConnectionCloseReason.Disposed, true, null, "The RPC client was disposed.");
        }
        if (failure is EditorRpcException protocolFailure)
        {
            return new EditorRpcConnectionClosed(EditorRpcConnectionCloseReason.ProtocolError, false, protocolFailure.Code, protocolFailure.Message);
        }
        if (Volatile.Read(ref _shutdownRequested) != 0 && (failure is null || failure is EndOfStreamException))
        {
            return new EditorRpcConnectionClosed(EditorRpcConnectionCloseReason.Shutdown, true, null, "The Editor Service closed after shutdown.");
        }
        if (failure is EndOfStreamException endOfStream)
        {
            return new EditorRpcConnectionClosed(EditorRpcConnectionCloseReason.EndOfStream, false, "connection_eof", endOfStream.Message);
        }
        if (failure is not null)
        {
            return new EditorRpcConnectionClosed(EditorRpcConnectionCloseReason.TransportError, false, "transport_error", failure.Message);
        }
        return new EditorRpcConnectionClosed(
            EditorRpcConnectionCloseReason.TransportError,
            false,
            "connection_cancelled",
            "The Editor RPC read loop was cancelled unexpectedly.");
    }

    private async Task PublishConnectionClosedAsync(EditorRpcConnectionClosed notification)
    {
        if (Interlocked.Exchange(ref _connectionClosedPublished, 1) != 0) { return; }
        LastConnectionClosed = notification;
        var handler = ConnectionClosed;
        if (handler is null) { return; }
        // 关闭通知本身不能让 read loop 的 finally 再次失败；每个订阅者只收到一次。
        foreach (Func<EditorRpcConnectionClosed, Task> subscriber in handler.GetInvocationList())
        {
            try { await subscriber(notification).ConfigureAwait(false); }
            catch { }
        }
    }

    private async Task HandleLineAsync(string line, CancellationToken cancellationToken)
    {
        using var document = JsonDocument.Parse(line);
        var root = document.RootElement;
        var type = root.TryGetProperty("type", out var typeElement) ? typeElement.GetString() : null;
        switch (type)
        {
            case "hello":
                await AcceptHelloAsync(line, cancellationToken).ConfigureAwait(false);
                break;
            case "response":
                AcceptResponse(line);
                break;
            case "event":
                await AcceptEventAsync(line).ConfigureAwait(false);
                break;
            default:
                throw new EditorRpcException("invalid_message", $"Unknown Editor Service message type: {type ?? "<missing>"}");
        }
    }

    private async Task AcceptHelloAsync(string line, CancellationToken cancellationToken)
    {
        if (Hello is not null) { throw new EditorRpcException("duplicate_hello", "The Editor Service emitted more than one hello message."); }
        var hello = JsonSerializer.Deserialize<EditorHello>(line, EditorProtocol.JsonOptions)
            ?? throw new EditorRpcException("invalid_hello", "The Editor Service hello message was empty.");
        if (hello.SchemaVersion != EditorProtocol.SchemaVersion || hello.Protocol != EditorProtocol.ProtocolName)
        {
            throw new EditorRpcException("unsupported_protocol", $"Unsupported Editor RPC protocol {hello.Protocol} v{hello.SchemaVersion}.");
        }
        if (!hello.Transports.Contains(EditorProtocol.TransportName, StringComparer.Ordinal))
        {
            throw new EditorRpcException("unsupported_transport", $"Editor Service does not advertise {EditorProtocol.TransportName}.");
        }

        Hello = hello;
        var ack = new EditorHelloAck(EditorProtocol.SchemaVersion, "hello_ack", _clientName, _clientVersion);
        await _transport.SendLineAsync(JsonSerializer.Serialize(ack, EditorProtocol.JsonOptions), cancellationToken).ConfigureAwait(false);
        _helloCompletion.TrySetResult(hello);
    }

    private void AcceptResponse(string line)
    {
        var response = JsonSerializer.Deserialize<EditorRpcResponse>(line, EditorProtocol.JsonOptions)
            ?? throw new EditorRpcException("invalid_response", "The Editor Service response was empty.");
        if (!_pending.TryRemove(response.Id, out var completion))
        {
            // 请求可能已被 UI 取消等待；迟到 response 不应破坏整个 JSONL read loop。
            return;
        }
        completion.TrySetResult(response);
    }

    private async Task AcceptEventAsync(string line)
    {
        var notification = JsonSerializer.Deserialize<EditorEvent>(line, EditorProtocol.JsonOptions)
            ?? throw new EditorRpcException("invalid_event", "The Editor Service event was empty.");
        var previous = Interlocked.Read(ref _lastEventSequence);
        if (notification.Sequence <= previous)
        {
            throw new EditorRpcException(
                "event_sequence_violation",
                $"Editor event sequence must increase: previous={previous}, current={notification.Sequence}.");
        }
        Interlocked.Exchange(ref _lastEventSequence, notification.Sequence);

        var handler = EventReceived;
        if (handler is null) { return; }
        // 顺序事件必须串行分发，避免 UI 看见 bake_completed 先于 bake_started。
        foreach (Func<EditorEvent, Task> subscriber in handler.GetInvocationList())
        {
            await subscriber(notification).ConfigureAwait(false);
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0) { return; }
        IsConnected = false;
        _lifetime.Cancel();
        if (_readLoop is not null)
        {
            try { await _readLoop.ConfigureAwait(false); }
            catch (OperationCanceledException) { }
        }
        await PublishConnectionClosedAsync(ClassifyConnectionClosed(null)).ConfigureAwait(false);
        foreach (var entry in _pending)
        {
            if (_pending.TryRemove(entry.Key, out var completion)) { completion.TrySetCanceled(); }
        }
        await _transport.DisposeAsync().ConfigureAwait(false);
        _lifetime.Dispose();
    }
}
