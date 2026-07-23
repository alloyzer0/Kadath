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
    private long _sequence;
    private bool _helloAccepted;
    private bool _shutdownRequested;

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
            switch (request.Method)
            {
                case "get_capabilities":
                    await WriteResponseAsync(request.Id, true, _session.GetCapabilities(), null);
                    break;
                case "project_open":
                    await WriteResponseAsync(request.Id, true, await _session.OpenProjectAsync(DeserializeParams<ProjectOpenParameters>(request), request.Id), null);
                    break;
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
                case "publication_snapshot":
                    await WriteResponseAsync(request.Id, true, await _session.GetPublicationSnapshotAsync(DeserializeParams<PublicationSnapshotQueryParameters>(request), request.Id), null);
                    break;
                case "authoring_apply":
                    await WriteResponseAsync(request.Id, true, await _session.ApplyAuthoringAsync(DeserializeParams<AuthoringApplyParameters>(request), request.Id), null);
                    break;
                case "authoring_undo":
                    await WriteResponseAsync(request.Id, true, await _session.UndoAuthoringAsync(DeserializeParams<AuthoringUndoParameters>(request), request.Id), null);
                    break;
                case "bake_start":
                    await WriteResponseAsync(request.Id, true, await _session.BakeAsync(DeserializeParams<BakeStartParameters>(request), request.Id), null);
                    break;
                case "watch_start":
                    await WriteResponseAsync(request.Id, true, await _session.StartWatchAsync(DeserializeParams<WatchStartParameters>(request), request.Id), null);
                    break;
                case "watch_stop":
                    await WriteResponseAsync(request.Id, true, await _session.StopWatchAsync(request.Id), null);
                    break;
                case "preview_start":
                    var start = _session.ResolvePreviewStart(DeserializeParams<PreviewStartParameters>(request));
                    await WriteResponseAsync(request.Id, true, await _preview.StartAsync(start), null);
                    break;
                case "preview_stop":
                    await WriteResponseAsync(request.Id, true, await _preview.StopAsync(), null);
                    break;
                case "shutdown":
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

    private static T DeserializeParams<T>(EditorRpcRequest request)
    {
        if (request.Params is not { } value) { throw new InvalidOperationException($"Request {request.Method} requires params."); }
        return JsonSerializer.Deserialize<T>(value.GetRawText(), EditorProtocol.JsonOptions)
            ?? throw new InvalidOperationException($"Request {request.Method} params were empty.");
    }

    private Task PublishPreviewEventAsync(string eventName, JsonElement? data) => PublishEventAsync(eventName, null, data);
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
}

