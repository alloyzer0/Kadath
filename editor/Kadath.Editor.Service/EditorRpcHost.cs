using System.Text.Json;
using Kadath.Editor.Core;
using Kadath.Editor.Protocol;

namespace Kadath.Editor.Service;

internal sealed class EditorRpcHost
{
    private readonly IEditorSession _session;
    private readonly PreviewProcessController _preview;
    private readonly TextReader _input;
    private readonly TextWriter _output;
    private readonly SemaphoreSlim _writeGate = new(1, 1);
    private readonly SemaphoreSlim _lifecycleGate = new(1, 1);
    private readonly object _lifecycleStateGate = new();
    private readonly object _analysisStateGate = new();
    private LifecycleState _watchState = LifecycleState.Stopped;
    private LifecycleState _previewState = LifecycleState.Stopped;
    private long _sequence;
    private bool _helloAccepted;
    private bool _shutdownRequested;
    private Task? _analysisTask;
    private CancellationTokenSource? _analysisCancellation;

    public EditorRpcHost(IEditorSession session, PreviewProcessController preview, TextReader input, TextWriter output)
    {
        _session = session;
        _preview = preview;
        _input = input;
        _output = output;
        _preview.Notification += PublishPreviewEventAsync;
        _session.Notification += PublishSessionEventAsync;
    }

    public async Task<int> RunAsync()
    {
        await WriteAsync(new EditorHello(
            EditorProtocol.SchemaVersion,
            "hello",
            EditorProtocol.ProtocolName,
            EditorProtocol.SchemaVersion,
            [EditorProtocol.TransportName],
            ["rpc", "project-session", "live-bake", "preview-surface"]));

        try
        {
            while (!_shutdownRequested && await _input.ReadLineAsync() is { } line)
            {
                if (string.IsNullOrWhiteSpace(line)) { continue; }
                await HandleLineAsync(line);
            }
            return 0;
        }
        finally
        {
            await CancelAnalysisAsync();
            try { await _session.StopWatchAsync(null); } catch { }
            await _preview.StopAsync();
        }
    }

    private async Task HandleLineAsync(string line)
    {
        try
        {
            using var document = JsonDocument.Parse(line);
            var root = document.RootElement;
            var type = root.TryGetProperty("type", out var typeValue) ? typeValue.GetString() : null;
            if (type == "hello_ack")
            {
                var ack = JsonSerializer.Deserialize<EditorHelloAck>(line, EditorProtocol.JsonOptions);
                if (ack is null || ack.SchemaVersion != EditorProtocol.SchemaVersion)
                {
                    throw new EditorOperationException("invalid_handshake", "hello_ack schemaVersion mismatch.");
                }
                _helloAccepted = true;
                return;
            }
            if (type != "request")
            {
                await WriteResponseAsync("", false, null, new EditorRpcError("invalid_message", "Expected hello_ack or request."));
                return;
            }

            var request = JsonSerializer.Deserialize<EditorRpcRequest>(line, EditorProtocol.JsonOptions)
                ?? throw new InvalidOperationException("Request payload was empty.");
            if (!_helloAccepted)
            {
                await WriteResponseAsync(request.Id, false, null, new EditorRpcError("handshake_required", "Send hello_ack before requests."));
                return;
            }
            await HandleRequestAsync(request);
        }
        catch (JsonException exception)
        {
            await WriteResponseAsync("", false, null, new EditorRpcError("invalid_json", exception.Message));
        }
        catch (EditorOperationException exception)
        {
            await WriteResponseAsync("", false, null, new EditorRpcError(exception.Code, exception.Message));
        }
        catch (Exception exception)
        {
            await WriteResponseAsync("", false, null, new EditorRpcError("host_error", exception.Message));
        }
    }

    private async Task HandleRequestAsync(EditorRpcRequest request)
    {
        try
        {
            if (request.Method == "script_source_analyze")
            {
                await StartAnalysisAsync(request);
                return;
            }
            switch (request.Method)
            {
                case "get_capabilities":
                    await WriteResponseAsync(request.Id, true, _session.GetCapabilities(), null);
                    break;
                case "project_open":
                    await WriteResponseAsync(request.Id, true, await _session.OpenProjectAsync(DeserializeParams<ProjectOpenParameters>(request), request.Id), null);
                    break;
                case "project_create":
                {
                    var result = await CreateProjectWithLifecycleAsync(DeserializeParams<ProjectCreateParameters>(request), request.Id);
                    await WriteResponseAsync(request.Id, true, result, null);
                    break;
                }
                case "project_validate":
                    await WriteResponseAsync(request.Id, true, await _session.ValidateProjectAsync(DeserializeParams<ProjectValidateParameters>(request), request.Id), null);
                    break;
                case "project_snapshot":
                    await WriteResponseAsync(request.Id, true, await _session.GetProjectSnapshotAsync(DeserializeParams<SnapshotQueryParameters>(request), request.Id), null);
                    break;
                case "hierarchy_snapshot":
                    await WriteResponseAsync(request.Id, true, await _session.GetHierarchySnapshotAsync(DeserializeParams<SnapshotQueryParameters>(request), request.Id), null);
                    break;
                case "asset_catalog_snapshot":
                    await WriteResponseAsync(request.Id, true, await _session.GetAssetCatalogSnapshotAsync(DeserializeParams<SnapshotQueryParameters>(request), request.Id), null);
                    break;
                case "behavior_contract_snapshot":
                    await WriteResponseAsync(request.Id, true, await _session.GetBehaviorContractSnapshotAsync(DeserializeParams<BehaviorContractSnapshotParameters>(request), request.Id), null);
                    break;
                case "publication_snapshot":
                    await WriteResponseAsync(request.Id, true, await _session.GetPublicationSnapshotAsync(DeserializeParams<PublicationSnapshotQueryParameters>(request), request.Id), null);
                    break;
                case "texture_import":
                    await WriteResponseAsync(request.Id, true, await _session.ImportTextureAsync(DeserializeParams<TextureImportParameters>(request), request.Id), null);
                    break;
                case "script_source_read":
                    await WriteResponseAsync(request.Id, true, await _session.GetScriptSourceAsync(DeserializeParams<ScriptSourceQueryParameters>(request), request.Id), null);
                    break;
                case "script_source_edit":
                    await WriteResponseAsync(request.Id, true, await _session.EditScriptSourceAsync(DeserializeParams<ScriptSourceEditParameters>(request), request.Id), null);
                    break;
                case "script_source_undo":
                    await WriteResponseAsync(request.Id, true, await _session.UndoScriptSourceAsync(DeserializeParams<ScriptSourceUndoParameters>(request), request.Id), null);
                    break;
                case "script_asset_create":
                    await WriteResponseAsync(request.Id, true, await _session.CreateScriptAssetAsync(DeserializeParams<ScriptAssetCreateParameters>(request), request.Id), null);
                    break;
                case "script_asset_rename":
                    await WriteResponseAsync(request.Id, true, await _session.RenameScriptAssetAsync(DeserializeParams<ScriptAssetRenameParameters>(request), request.Id), null);
                    break;
                case "script_asset_delete":
                    await WriteResponseAsync(request.Id, true, await _session.DeleteScriptAssetAsync(DeserializeParams<ScriptAssetDeleteParameters>(request), request.Id), null);
                    break;
                case "script_asset_undo":
                    await WriteResponseAsync(request.Id, true, await _session.UndoScriptAssetAsync(DeserializeParams<ScriptAssetUndoParameters>(request), request.Id), null);
                    break;
                case "authoring_apply":
                    await WriteResponseAsync(request.Id, true, await _session.ApplyAuthoringAsync(DeserializeParams<AuthoringApplyParameters>(request), request.Id), null);
                    break;
                case "authoring_undo":
                    await WriteResponseAsync(request.Id, true, await _session.UndoAuthoringAsync(DeserializeParams<AuthoringUndoParameters>(request), request.Id), null);
                    break;
                case "authoring_redo":
                    await WriteResponseAsync(request.Id, true, await _session.RedoAuthoringAsync(DeserializeParams<AuthoringRedoParameters>(request), request.Id), null);
                    break;
                case "bake_start":
                    await WriteResponseAsync(request.Id, true, await _session.BakeAsync(DeserializeParams<BakeStartParameters>(request), request.Id), null);
                    break;
                case "watch_start":
                {
                    var result = await StartWatchWithLifecycleAsync(DeserializeParams<WatchStartParameters>(request), request.Id);
                    await WriteResponseAsync(request.Id, true, result, null);
                    break;
                }
                case "watch_stop":
                {
                    var result = await StopWatchWithLifecycleAsync(request.Id);
                    await WriteResponseAsync(request.Id, true, result, null);
                    break;
                }
                case "preview_start":
                {
                    var result = await StartPreviewWithLifecycleAsync(DeserializeParams<PreviewStartParameters>(request));
                    await WriteResponseAsync(request.Id, true, result, null);
                    break;
                }
                case "preview_stop":
                {
                    var result = await StopPreviewWithLifecycleAsync();
                    await WriteResponseAsync(request.Id, true, result, null);
                    break;
                }
                case "shutdown":
                    await CancelAnalysisAsync();
                    await WriteResponseAsync(request.Id, true, new { state = "stopping" }, null);
                    _shutdownRequested = true;
                    await PublishEventAsync("service_stopping", request.Id, JsonSerializer.SerializeToElement(new { }, EditorProtocol.JsonOptions));
                    break;
                default:
                    await WriteResponseAsync(request.Id, false, null, new EditorRpcError("unknown_method", $"Unknown editor method: {request.Method}"));
                    break;
            }
        }
        catch (EditorOperationException exception)
        {
            await WriteResponseAsync(request.Id, false, null, new EditorRpcError(exception.Code, exception.Message));
        }
        catch (Exception exception)
        {
            await WriteResponseAsync(request.Id, false, null, new EditorRpcError("command_failed", exception.Message));
        }
    }

    private async Task StartAnalysisAsync(EditorRpcRequest request)
    {
        ScriptSourceAnalyzeParameters parameters;
        try { parameters = DeserializeParams<ScriptSourceAnalyzeParameters>(request); }
        catch (Exception exception)
        {
            await WriteResponseAsync(request.Id, false, null, new EditorRpcError("invalid_script_source_analysis_request", exception.Message));
            return;
        }

        CancellationTokenSource? cancellation = null;
        lock (_analysisStateGate)
        {
            if (_analysisTask is null)
            {
                cancellation = new CancellationTokenSource();
                _analysisCancellation = cancellation;
                Task<ScriptSourceAnalysisResult> operation;
                try
                {
                    // 调用 async Interface 会在返回 Task 前同步捕获当前 Project Session；
                    // 后续 project_open 不得把本请求改指向新项目。
                    operation = _session.AnalyzeScriptSourceAsync(parameters, request.Id, cancellation.Token);
                }
                catch (Exception exception)
                {
                    operation = Task.FromException<ScriptSourceAnalysisResult>(exception);
                }
                _analysisTask = RunAnalysisAsync(request.Id, operation, cancellation);
            }
        }
        if (cancellation is null)
        {
            await WriteResponseAsync(request.Id, false, null, new EditorRpcError(
                "script_source_analysis_busy",
                "A Script source analysis is already running."));
        }
    }

    private async Task RunAnalysisAsync(
        string requestId,
        Task<ScriptSourceAnalysisResult> operation,
        CancellationTokenSource cancellation)
    {
        await Task.Yield();
        bool ok;
        object? result;
        EditorRpcError? error;
        try
        {
            result = await operation;
            ok = true;
            error = null;
        }
        catch (EditorOperationException exception)
        {
            ok = false;
            result = null;
            error = new EditorRpcError(exception.Code, exception.Message);
        }
        catch (OperationCanceledException)
        {
            ok = false;
            result = null;
            error = new EditorRpcError(
                "script_source_analysis_cancelled",
                "Script source analysis was cancelled.");
        }
        catch (Exception exception)
        {
            ok = false;
            result = null;
            error = new EditorRpcError("command_failed", exception.Message);
        }

        try
        {
            // EOF/dispose 后输出可能已不可用；terminal wire message 可丢失，
            // 但后台任务必须继续完成 Tool 子进程清理和 ownership 释放。
            try { await WriteResponseAsync(requestId, ok, result, error); }
            catch { }
        }
        finally
        {
            lock (_analysisStateGate)
            {
                if (ReferenceEquals(_analysisCancellation, cancellation))
                {
                    _analysisCancellation = null;
                    _analysisTask = null;
                }
            }
            cancellation.Dispose();
        }
    }

    private async Task CancelAnalysisAsync()
    {
        Task? task;
        CancellationTokenSource? cancellation;
        lock (_analysisStateGate)
        {
            task = _analysisTask;
            cancellation = _analysisCancellation;
        }
        if (task is null || cancellation is null) return;
        try { cancellation.Cancel(); }
        catch (ObjectDisposedException) { }
        await task;
    }

    private async Task<ProjectSessionInfo> CreateProjectWithLifecycleAsync(ProjectCreateParameters parameters, string? requestId)
    {
        await _lifecycleGate.WaitAsync();
        try
        {
            var (watchState, previewState) = ReadLifecycleStates();
            if (watchState != LifecycleState.Stopped || previewState != LifecycleState.Stopped)
            {
                throw new EditorOperationException(
                    "project_create_busy",
                    $"Project creation requires stopped watch and preview lifecycles; watch={watchState}, preview={previewState}.");
            }

            // 关键提交边界：Session 的 current project 提交与 project_created 发布都在生命周期门内完成；response 由调用方在释放门后写出。
            return await _session.CreateProjectAsync(parameters, requestId);
        }
        finally { _lifecycleGate.Release(); }
    }

    private async Task<EditorWatchResult> StartWatchWithLifecycleAsync(WatchStartParameters parameters, string? requestId)
    {
        await _lifecycleGate.WaitAsync();
        try
        {
            SetWatchState(LifecycleState.Starting);
            try
            {
                var result = await _session.StartWatchAsync(parameters, requestId);
                SetWatchState(LifecycleState.Running);
                return result;
            }
            catch
            {
                SetWatchState(LifecycleState.Failed);
                throw;
            }
        }
        finally { _lifecycleGate.Release(); }
    }

    private async Task<EditorWatchResult> StopWatchWithLifecycleAsync(string? requestId)
    {
        await _lifecycleGate.WaitAsync();
        try
        {
            // Failed/Starting 等未知状态也必须能经显式 Stop 收敛；只有 Backend 成功返回才可声明 Stopped。
            SetWatchState(LifecycleState.Stopping);
            try
            {
                var result = await _session.StopWatchAsync(requestId);
                SetWatchState(LifecycleState.Stopped);
                return result;
            }
            catch
            {
                SetWatchState(LifecycleState.Failed);
                throw;
            }
        }
        finally { _lifecycleGate.Release(); }
    }

    private async Task<PreviewStartResult> StartPreviewWithLifecycleAsync(PreviewStartParameters parameters)
    {
        await _lifecycleGate.WaitAsync();
        try
        {
            SetPreviewState(LifecycleState.Starting);
            try
            {
                var start = _session.ResolvePreviewStart(parameters);
                var result = await _preview.StartAsync(start);
                // 异步 preview_stopped(requested=false) 可能已把状态置为 Failed；Start 返回不得覆盖该终态。
                TransitionPreviewState(LifecycleState.Starting, LifecycleState.Running);
                return result;
            }
            catch
            {
                SetPreviewState(LifecycleState.Failed);
                throw;
            }
        }
        finally { _lifecycleGate.Release(); }
    }

    private async Task<PreviewStopResult> StopPreviewWithLifecycleAsync()
    {
        await _lifecycleGate.WaitAsync();
        try
        {
            SetPreviewState(LifecycleState.Stopping);
            try
            {
                var result = await _preview.StopAsync();
                SetPreviewState(LifecycleState.Stopped);
                return result;
            }
            catch
            {
                SetPreviewState(LifecycleState.Failed);
                throw;
            }
        }
        finally { _lifecycleGate.Release(); }
    }

    private (LifecycleState Watch, LifecycleState Preview) ReadLifecycleStates()
    {
        lock (_lifecycleStateGate) { return (_watchState, _previewState); }
    }

    private void SetWatchState(LifecycleState state)
    {
        lock (_lifecycleStateGate) { _watchState = state; }
    }

    private void SetPreviewState(LifecycleState state)
    {
        lock (_lifecycleStateGate) { _previewState = state; }
    }

    private void TransitionPreviewState(LifecycleState expected, LifecycleState next)
    {
        // 状态锁只保护一次短读写，绝不跨 await；异步事件因此不会与 lifecycle 操作形成锁反转。
        lock (_lifecycleStateGate)
        {
            if (_previewState == expected) { _previewState = next; }
        }
    }

    private static T DeserializeParams<T>(EditorRpcRequest request)
    {
        if (request.Params is not { } value) { throw new InvalidOperationException($"Request {request.Method} requires params."); }
        return JsonSerializer.Deserialize<T>(value.GetRawText(), EditorProtocol.JsonOptions)
            ?? throw new InvalidOperationException($"Request {request.Method} params were empty.");
    }

    private Task PublishPreviewEventAsync(string eventName, JsonElement? data)
    {
        if (string.Equals(eventName, "preview_surface_created", StringComparison.Ordinal))
        {
            TransitionPreviewState(LifecycleState.Starting, LifecycleState.Running);
        }
        else if (string.Equals(eventName, "preview_stopped", StringComparison.Ordinal) && IsUnrequestedPreviewStop(data))
        {
            SetPreviewState(LifecycleState.Failed);
        }
        return PublishEventAsync(eventName, null, data);
    }

    private static bool IsUnrequestedPreviewStop(JsonElement? data) =>
        data is JsonElement payload
        && payload.ValueKind == JsonValueKind.Object
        && payload.TryGetProperty("requested", out var requested)
        && requested.ValueKind == JsonValueKind.False;

    private Task PublishSessionEventAsync(EditorSessionNotification notification) => PublishEventAsync(notification.Event, notification.RequestId, notification.Data);

    private async Task PublishEventAsync(string eventName, string? requestId, JsonElement? data)
    {
        await _writeGate.WaitAsync();
        try
        {
            // sequence 分配必须与 JSONL 写入持有同一把锁，避免并发后台事件出现“编号先分配、输出后乱序”。
            var message = new EditorEvent(
                EditorProtocol.SchemaVersion,
                "event",
                ++_sequence,
                eventName,
                requestId,
                data);
            await _output.WriteLineAsync(JsonSerializer.Serialize(message, EditorProtocol.JsonOptions));
            await _output.FlushAsync();
        }
        finally { _writeGate.Release(); }
    }

    private async Task WriteResponseAsync(string id, bool ok, object? result, EditorRpcError? error)
    {
        JsonElement? resultElement = result is null ? null : JsonSerializer.SerializeToElement(result, EditorProtocol.JsonOptions);
        await WriteAsync(new EditorRpcResponse(EditorProtocol.SchemaVersion, "response", id, ok, resultElement, error));
    }

    private async Task WriteAsync<T>(T value)
    {
        await _writeGate.WaitAsync();
        try
        {
            await _output.WriteLineAsync(JsonSerializer.Serialize(value, EditorProtocol.JsonOptions));
            await _output.FlushAsync();
        }
        finally { _writeGate.Release(); }
    }

    private enum LifecycleState
    {
        Stopped,
        Starting,
        Running,
        Stopping,
        Failed
    }
}
