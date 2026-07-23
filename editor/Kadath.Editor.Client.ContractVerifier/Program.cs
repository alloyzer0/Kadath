using System.Collections.Concurrent;
using System.Text.Json;
using System.Threading.Channels;
using Kadath.Editor.Client;
using Kadath.Editor.Protocol;
using Kadath.Editor.ViewModels;

namespace Kadath.Editor.Client.ContractVerifier;

internal static class Program
{
    public static async Task<int> Main(string[] args)
    {
        try
        {
            await VerifyClientAndViewModelsAsync();
            await VerifyUnexpectedEofProjectionAsync();
            await VerifyExpectedShutdownProjectionAsync();
            if (args.Length == 4)
            {
                await VerifyRealServiceAsync(args[0], args[1], args[2], args[3]);
                Console.WriteLine("real_service_smoke=ok");
            }
            else if (args.Length != 0) { throw new ArgumentException("Usage: <serviceDll> <kadathRoot> <packageRoot> <projectName>"); }
            Console.WriteLine("editor_rpc_client=ok");
            Console.WriteLine("request_correlation=ok");
            Console.WriteLine("event_ordering=ok");
            Console.WriteLine("cancellation_late_response=ok");
            Console.WriteLine("connection_closed_projection=ok");
            Console.WriteLine("snapshot_state=ok");
            Console.WriteLine("capability_gating=ok");
            Console.WriteLine("viewmodel_state=ok");
            Console.WriteLine("verification=ok");
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine($"verification=failed: {exception}");
            return 1;
        }
    }

    private static async Task VerifyRealServiceAsync(string serviceDll, string kadathRoot, string packageRoot, string projectName)
    {
        serviceDll = Path.GetFullPath(serviceDll);
        kadathRoot = Path.GetFullPath(kadathRoot);
        packageRoot = Path.GetFullPath(packageRoot);
        if (!File.Exists(serviceDll)) { throw new FileNotFoundException("Editor Service DLL was not found.", serviceDll); }

        await using var transport = new StdioEditorRpcTransport(new EditorRpcProcessOptions(
            "dotnet",
            [serviceDll, "--kadath-root", kadathRoot],
            Path.GetDirectoryName(serviceDll)));
        await using var client = new EditorRpcClient(transport, "real-service-smoke", "1");
        await client.ConnectAsync().ConfigureAwait(false);
        var capabilities = await client.GetCapabilitiesAsync().ConfigureAwait(false);
        Assert(capabilities.Commands.Contains("project_open"), "real service did not advertise project_open");
        Assert(capabilities.Commands.Contains("project_validate"), "real service did not advertise project_validate");
        var project = await client.OpenProjectAsync(new ProjectOpenParameters(packageRoot, projectName)).ConfigureAwait(false);
        Assert(project.ProjectName == projectName, "real service project_open mismatch");
        var validation = await client.ValidateProjectAsync(new ProjectValidateParameters()).ConfigureAwait(false);
        Assert(string.Equals(validation.State, "valid", StringComparison.OrdinalIgnoreCase), "real service project_validate failed");
        var projectSnapshot = await client.GetProjectSnapshotAsync(new SnapshotQueryParameters(projectName)).ConfigureAwait(false);
        var hierarchySnapshot = await client.GetHierarchySnapshotAsync(new SnapshotQueryParameters(projectName)).ConfigureAwait(false);
        var assetSnapshot = await client.GetAssetCatalogSnapshotAsync(new SnapshotQueryParameters(projectName)).ConfigureAwait(false);
        Assert(projectSnapshot.ModelVersion == 1 && hierarchySnapshot.SnapshotVersion == 1, "real service snapshot version mismatch");
        Assert(hierarchySnapshot.Nodes.Length == 8, "real service hierarchy snapshot count mismatch");
        Assert(assetSnapshot.CatalogVersion == 1 && assetSnapshot.ItemCount == assetSnapshot.Items.Length, "real service asset snapshot mismatch");
        Assert(projectSnapshot.AuthoringRevision.Length == 64, "real service authoring revision mismatch");
        Console.WriteLine("snapshot_service_smoke=ok");
        Assert(capabilities.Commands.Contains("authoring_apply") && capabilities.Commands.Contains("authoring_undo"), "real service did not advertise authoring commands");

        try
        {
            _ = await client.ApplyAuthoringAsync(new AuthoringApplyParameters(projectName, projectSnapshot.AuthoringRevision, new AuthoringPatch(SceneGoalPosition: [1d]))).ConfigureAwait(false);
            throw new InvalidOperationException("invalid authoring patch unexpectedly succeeded");
        }
        catch (EditorRpcException exception) when (exception.Code == "invalid_authoring_patch") { }

        var unchanged = await client.ApplyAuthoringAsync(new AuthoringApplyParameters(projectName, projectSnapshot.AuthoringRevision,
            new AuthoringPatch(SceneGoalPosition: projectSnapshot.Scene.GoalPosition))).ConfigureAwait(false);
        Assert(unchanged.State == "unchanged" && unchanged.UndoDepth == 0, "real service authoring no-op mismatch");

        var updatedGoal = new[] { projectSnapshot.Scene.GoalPosition[0] + 1d, projectSnapshot.Scene.GoalPosition[1] + 1d };
        var applied = await client.ApplyAuthoringAsync(new AuthoringApplyParameters(projectName, projectSnapshot.AuthoringRevision,
            new AuthoringPatch(SceneGoalPosition: updatedGoal))).ConfigureAwait(false);
        Assert(applied.State == "succeeded" && applied.ChangedFields.Contains("scene.goal.position"), "real service authoring apply failed");
        try
        {
            _ = await client.ApplyAuthoringAsync(new AuthoringApplyParameters(projectName, projectSnapshot.AuthoringRevision,
                new AuthoringPatch(SceneGoalPosition: [9d, 9d]))).ConfigureAwait(false);
            throw new InvalidOperationException("stale authoring revision unexpectedly succeeded");
        }
        catch (EditorRpcException exception) when (exception.Code == "authoring_revision_conflict") { }

        var undone = await client.UndoAuthoringAsync(new AuthoringUndoParameters(projectName, applied.Revision)).ConfigureAwait(false);
        Assert(undone.Operation == "undo" && undone.UndoDepth == 0, "real service authoring undo failed");
        try
        {
            _ = await client.UndoAuthoringAsync(new AuthoringUndoParameters(projectName, undone.Revision)).ConfigureAwait(false);
            throw new InvalidOperationException("empty authoring undo unexpectedly succeeded");
        }
        catch (EditorRpcException exception) when (exception.Code == "authoring_undo_empty") { }
        Console.WriteLine("authoring_service_smoke=ok");
        await client.ShutdownAsync().ConfigureAwait(false);
    }

    private static async Task VerifyClientAndViewModelsAsync()
    {
        await using var transport = new ScriptedTransport();
        await using var client = new EditorRpcClient(transport, "contract-verifier", "1");
        var events = new ConcurrentQueue<EditorEvent>();
        client.EventReceived += notification =>
        {
            events.Enqueue(notification);
            return Task.CompletedTask;
        };

        var workspace = new EditorWorkspaceViewModel(client);
        await workspace.ConnectAsync().ConfigureAwait(false);
        Assert(workspace.ConnectionState == EditorConnectionState.Ready, "workspace did not become ready");
        Assert(workspace.Capabilities.CanBake, "bake capability was not exposed");
        Assert(workspace.Capabilities.CanStartPreview, "external-window preview capability was not exposed");
        Assert(!workspace.Capabilities.CanUseSharedTexture, "unimplemented shared texture capability was enabled");
        Assert(!workspace.Capabilities.CanUseFrameStream, "unimplemented frame stream capability was enabled");

        var project = await workspace.OpenProjectAsync(new ProjectOpenParameters("C:/package", "demo"));
        await workspace.RefreshSnapshotsAsync("demo");
        Assert(workspace.ProjectSnapshot.State == EditorSnapshotState.Ready && workspace.ProjectSnapshot.Value?.ModelVersion == 1, "project snapshot state mismatch");
        Assert(workspace.HierarchySnapshot.Value?.Nodes.Length == 8, "hierarchy snapshot count mismatch");
        Assert(workspace.AssetCatalogSnapshot.Value?.ItemCount == 10, "asset catalog snapshot count mismatch");
        var scriptedRevision = workspace.ProjectSnapshot.Value?.AuthoringRevision ?? throw new InvalidOperationException("scripted revision missing");
        var scriptedApplied = await workspace.ApplyAuthoringAsync(new AuthoringApplyParameters("demo", scriptedRevision, new AuthoringPatch(SceneGoalPosition: [8d, 9d])));
        Assert(workspace.Authoring.State == EditorAuthoringState.Succeeded && scriptedApplied.UndoDepth == 1, "authoring apply state mismatch");
        var scriptedUndone = await workspace.UndoAuthoringAsync(new AuthoringUndoParameters("demo", scriptedApplied.Revision));
        Assert(workspace.Authoring.State == EditorAuthoringState.Succeeded && scriptedUndone.Operation == "undo", "authoring undo state mismatch");
        Assert(workspace.Project.State == EditorProjectState.Opened, "project state was not opened");
        Assert(project.ProjectName == "demo", "project response correlation failed");

        var validation = await workspace.ValidateProjectAsync();
        Assert(validation.State == "valid" && workspace.Project.State == EditorProjectState.Valid, "project validation state mismatch");

        // 请求取消后服务仍可能送达迟到 response；客户端应丢弃它并继续处理后续请求。
        transport.DelayNextValidationResponse();
        using (var cancellation = new CancellationTokenSource(TimeSpan.FromMilliseconds(100)))
        {
            var canceledRequest = client.ValidateProjectAsync(new ProjectValidateParameters(), cancellation.Token);
            await WaitUntilAsync(() => transport.DelayedValidationPending);
            cancellation.Cancel();
            try { await canceledRequest; throw new InvalidOperationException("cancelled request unexpectedly completed"); }
            catch (OperationCanceledException) { }
        }
        await transport.ReleaseDelayedValidationAsync();
        await Task.Delay(50).ConfigureAwait(false);
        Assert(client.IsConnected, "late response disconnected the RPC client");
        _ = await client.GetCapabilitiesAsync();

        var baked = await workspace.BakeAsync(new BakeStartParameters("Both", "debug"));
        Assert(baked.State == "succeeded" && workspace.Bake.State == EditorBakeState.Succeeded, "bake state mismatch");
        Assert(workspace.Bake.SceneArtifactBytes == 128, "scene artifact bytes were not retained");
        var lastSuccessfulRevision = workspace.Bake.SceneArtifactRevision;

        var watched = await workspace.StartWatchAsync(new WatchStartParameters("Scene", "debug", 50, 100));
        Assert(watched.State == "watching" && workspace.Watch.State == EditorWatchState.Watching, "watch state mismatch");
        await transport.EmitEventAsync("source_change_detected", new { target = "scene", revision = "ABC" });
        await WaitUntilAsync(() => workspace.Watch.LastSourceRevision == "ABC");

        await transport.EmitEventAsync("bake_failed", new { target = "scene", errorCode = "bake_validation_failed", message = "invalid json", retainedArtifact = true });
        await WaitUntilAsync(() => workspace.Bake.State == EditorBakeState.Failed);
        Assert(workspace.Bake.RetainedPreviousArtifact, "failed bake did not advertise retained artifact");
        Assert(workspace.Bake.LastSuccessfulResult?.SceneArtifactRevision == lastSuccessfulRevision, "failed bake discarded last successful artifact");

        var preview = await workspace.StartPreviewAsync(new PreviewStartParameters(ProjectName: "demo"));
        Assert(preview.SurfaceMode == PreviewSurfaceModes.ExternalWindow, "preview result surface mode mismatch");
        await WaitUntilAsync(() => workspace.Preview.State == EditorPreviewState.Running);
        Assert(workspace.Preview.Surface?.WindowClass == "KadathRuntimeWindow", "preview surface descriptor mismatch");
        Assert(workspace.Preview.RuntimeProcessId == 1234, "runtime PID status was not parsed");

        await workspace.StopPreviewAsync();
        Assert(workspace.Preview.State == EditorPreviewState.Stopped, "preview did not stop");
        await workspace.StopWatchAsync();
        Assert(workspace.Watch.State == EditorWatchState.Stopped, "watch did not stop");

        // 故意注入重复 sequence，验证客户端在协议破坏时停止接受事件，而不是静默重排。
        var lastSequence = client.LastEventSequence;
        await transport.EmitRawEventAsync(lastSequence);
        await WaitUntilAsync(() => !client.IsConnected);
        Assert(client.LastEventSequence == lastSequence, "event sequence guard advanced on duplicate event");
        await workspace.DisposeAsync();
    }

    private static async Task VerifyUnexpectedEofProjectionAsync()
    {
        var transport = new ScriptedTransport();
        var client = new EditorRpcClient(transport, "eof-contract-verifier", "1");
        var workspace = new EditorWorkspaceViewModel(client);
        await workspace.ConnectAsync().ConfigureAwait(false);

        // 模拟 Service 没有发送 service_stopping 就关闭 stdout；Workspace 必须显式进入 Faulted。
        transport.CompleteServerOutput();
        await WaitUntilAsync(() => workspace.ConnectionState == EditorConnectionState.Faulted
            && workspace.LastConnectionClosed?.Reason == EditorRpcConnectionCloseReason.EndOfStream).ConfigureAwait(false);
        Assert(workspace.LastConnectionClosed is { Expected: false, ErrorCode: "connection_eof" }, "unexpected EOF was not projected as a fault");
        await workspace.DisposeAsync().ConfigureAwait(false);
    }

    private static async Task VerifyExpectedShutdownProjectionAsync()
    {
        var transport = new ScriptedTransport();
        var client = new EditorRpcClient(transport, "shutdown-contract-verifier", "1");
        var workspace = new EditorWorkspaceViewModel(client);
        await workspace.ConnectAsync().ConfigureAwait(false);
        await workspace.ShutdownAsync().ConfigureAwait(false);

        // shutdown response 完成后由 Service 关闭输出；这是预期关闭，不应显示为故障。
        transport.CompleteServerOutput();
        await WaitUntilAsync(() => workspace.ConnectionState == EditorConnectionState.Disconnected
            && workspace.LastConnectionClosed?.Reason == EditorRpcConnectionCloseReason.Shutdown).ConfigureAwait(false);
        Assert(workspace.LastConnectionClosed is { Expected: true }, "expected shutdown was not projected as disconnected");
        await workspace.DisposeAsync().ConfigureAwait(false);
    }

    private static async Task WaitUntilAsync(Func<bool> predicate)
    {
        for (var attempt = 0; attempt < 100; attempt++)
        {
            if (predicate()) { return; }
            await Task.Delay(20).ConfigureAwait(false);
        }
        throw new InvalidOperationException("Timed out waiting for contract state.");
    }

    private static void Assert(bool condition, string message)
    {
        if (!condition) { throw new InvalidOperationException(message); }
    }
}

/// <summary>
/// 进程 transport 的内存替身。它模拟服务端 hello、响应和事件，确保测试跨越真实 Client seam。
/// </summary>
internal sealed class ScriptedTransport : IEditorRpcTransport
{
    private readonly Channel<string> _toClient = Channel.CreateUnbounded<string>();
    private readonly Channel<string> _toServer = Channel.CreateUnbounded<string>();
    private readonly CancellationTokenSource _stop = new();
    private long _sequence;
    private bool _started;
    private int _disposed;
    private bool _delayNextValidation;
    private TaskCompletionSource<bool>? _delayedValidationRelease;
    private TaskCompletionSource<bool>? _delayedValidationCompleted;

    public bool IsOpen => _started && !_stop.IsCancellationRequested;
    public bool DelayedValidationPending => _delayedValidationRelease is not null;

    public async Task StartAsync(CancellationToken cancellationToken = default)
    {
        if (_started) { throw new InvalidOperationException("scripted transport already started"); }
        _started = true;
        await EmitLineAsync(new EditorHello(
            EditorProtocol.SchemaVersion,
            "hello",
            EditorProtocol.ProtocolName,
            EditorProtocol.SchemaVersion,
            [EditorProtocol.TransportName],
            ["rpc", "project-session", "live-bake", "preview-surface"]));
    }

    public async Task SendLineAsync(string line, CancellationToken cancellationToken = default)
    {
        await _toServer.Writer.WriteAsync(line, cancellationToken).ConfigureAwait(false);
        using var document = JsonDocument.Parse(line);
        var root = document.RootElement;
        var type = root.GetProperty("type").GetString();
        if (type == "hello_ack") { return; }
        if (type != "request") { return; }
        await RespondToRequestAsync(root).ConfigureAwait(false);
    }

    public Task<string?> ReadLineAsync(CancellationToken cancellationToken = default) =>
        ReadLineCoreAsync(cancellationToken).AsTask();

    private async ValueTask<string?> ReadLineCoreAsync(CancellationToken cancellationToken)
    {
        try { return await _toClient.Reader.ReadAsync(cancellationToken).ConfigureAwait(false); }
        catch (ChannelClosedException) { return null; }
        catch (OperationCanceledException) { return null; }
    }

    private async Task RespondToRequestAsync(JsonElement request)
    {
        var id = request.GetProperty("id").GetString() ?? "";
        var method = request.GetProperty("method").GetString() ?? "";
        switch (method)
        {
            case "get_capabilities":
                await SendResponseAsync(id, new EditorCapabilities(
                    ["project_open", "project_validate", "project_snapshot", "hierarchy_snapshot", "asset_catalog_snapshot", "authoring_apply", "authoring_undo", "bake_start", "watch_start", "watch_stop", "preview_start", "preview_stop", "shutdown"],
                    [EditorProtocol.TransportName],
                    [
                        new PreviewSurfaceCapability(PreviewSurfaceModes.ExternalWindow, "native-window", true),
                        new PreviewSurfaceCapability(PreviewSurfaceModes.SharedTexture, "gpu-shared-resource", false),
                        new PreviewSurfaceCapability(PreviewSurfaceModes.FrameStream, "encoded-frame-stream", false)
                    ])).ConfigureAwait(false);
                break;
            case "project_open":
                var opened = new ProjectSessionInfo("C:/package", "demo", "C:/package/bin/projects/demo", "C:/package/bin/projects/demo/scene.json", "C:/package/bin/projects/demo/script.json", "C:/package/bin/projects/demo/preview.json", 1);
                await EmitEventAsync("project_opened", opened, id).ConfigureAwait(false);
                await SendResponseAsync(id, opened).ConfigureAwait(false);
                break;
            case "project_validate":
                if (_delayNextValidation)
                {
                    _delayNextValidation = false;
                    _delayedValidationRelease = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
                    _delayedValidationCompleted = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
                    _ = CompleteDelayedValidationAsync(id, _delayedValidationRelease.Task, _delayedValidationCompleted);
                    break;
                }
                var validation = new ProjectValidateResult("valid", "demo", []);
                await EmitEventAsync("project_validated", validation, id).ConfigureAwait(false);
                await SendResponseAsync(id, validation).ConfigureAwait(false);
                break;
            case "project_snapshot":
                var projectSnapshot = NewProjectSnapshot();
                await EmitEventAsync("project_snapshot_created", projectSnapshot, id).ConfigureAwait(false);
                await SendResponseAsync(id, projectSnapshot).ConfigureAwait(false);
                break;
            case "hierarchy_snapshot":
                var hierarchySnapshot = NewHierarchySnapshot();
                await EmitEventAsync("hierarchy_snapshot_created", hierarchySnapshot, id).ConfigureAwait(false);
                await SendResponseAsync(id, hierarchySnapshot).ConfigureAwait(false);
                break;
            case "asset_catalog_snapshot":
                var assetSnapshot = NewAssetCatalogSnapshot();
                await EmitEventAsync("asset_catalog_snapshot_created", assetSnapshot, id).ConfigureAwait(false);
                await SendResponseAsync(id, assetSnapshot).ConfigureAwait(false);
                break;
            case "authoring_apply":
                var applied = NewAuthoringMutationResult("apply", "0000000000000000000000000000000000000000000000000000000000000002", 1);
                await EmitEventAsync("authoring_apply_started", new { projectName = "demo" }, id).ConfigureAwait(false);
                await EmitEventAsync("authoring_apply_completed", applied, id).ConfigureAwait(false);
                await SendResponseAsync(id, applied).ConfigureAwait(false);
                break;
            case "authoring_undo":
                var undone = NewAuthoringMutationResult("undo", "0000000000000000000000000000000000000000000000000000000000000003", 0);
                await EmitEventAsync("authoring_undo_started", new { projectName = "demo" }, id).ConfigureAwait(false);
                await EmitEventAsync("authoring_undo_completed", undone, id).ConfigureAwait(false);
                await SendResponseAsync(id, undone).ConfigureAwait(false);
                break;            case "bake_start":
                await EmitEventAsync("bake_started", new { target = "Both", profile = "debug" }, id).ConfigureAwait(false);
                var bake = NewBakeResult();
                await EmitEventAsync("bake_completed", bake, id).ConfigureAwait(false);
                await SendResponseAsync(id, bake).ConfigureAwait(false);
                break;
            case "watch_start":
                var watch = new EditorWatchResult("watching", "demo", "Scene", "debug", NewBakeResult());
                await EmitEventAsync("watch_started", watch, id).ConfigureAwait(false);
                await SendResponseAsync(id, watch).ConfigureAwait(false);
                break;
            case "watch_stop":
                var watchStopped = new EditorWatchResult("stopped", "demo", "Scene", "debug", null);
                await EmitEventAsync("watch_stopped", watchStopped, id).ConfigureAwait(false);
                await SendResponseAsync(id, watchStopped).ConfigureAwait(false);
                break;
            case "preview_start":
                var surface = new PreviewSurfaceDescriptor(PreviewSurfaceModes.ExternalWindow, "native-window", 1234, "KadathRuntimeWindow", null, null, null, null);
                await EmitEventAsync("preview_surface_created", surface).ConfigureAwait(false);
                await EmitEventAsync("preview_status", new { @event = "launcher_status", name = "runtime_pid", value = 1234 }).ConfigureAwait(false);
                await SendResponseAsync(id, new PreviewStartResult("starting", PreviewSurfaceModes.ExternalWindow)).ConfigureAwait(false);
                break;
            case "preview_stop":
                await EmitEventAsync("preview_stopped", new { exitCode = 0, requested = true }).ConfigureAwait(false);
                await SendResponseAsync(id, new PreviewStopResult("stopped")).ConfigureAwait(false);
                break;
            case "shutdown":
                await SendResponseAsync(id, new { state = "stopping" }).ConfigureAwait(false);
                await EmitEventAsync("service_stopping", new { }, id).ConfigureAwait(false);
                break;
            default:
                await SendErrorAsync(id, "unknown_method", method).ConfigureAwait(false);
                break;
        }
    }

    public void DelayNextValidationResponse() => _delayNextValidation = true;

    public async Task ReleaseDelayedValidationAsync()
    {
        var release = _delayedValidationRelease ?? throw new InvalidOperationException("No delayed validation is pending.");
        var completed = _delayedValidationCompleted ?? throw new InvalidOperationException("Delayed validation completion is missing.");
        release.TrySetResult(true);
        await completed.Task.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
        _delayedValidationRelease = null;
        _delayedValidationCompleted = null;
    }

    private async Task CompleteDelayedValidationAsync(string id, Task release, TaskCompletionSource<bool> completed)
    {
        try
        {
            await release.ConfigureAwait(false);
            var validation = new ProjectValidateResult("valid", "demo", []);
            await EmitEventAsync("project_validated", validation, id).ConfigureAwait(false);
            await SendResponseAsync(id, validation).ConfigureAwait(false);
        }
        finally { completed.TrySetResult(true); }
    }

    private static ProjectModelSnapshot NewProjectSnapshot() => new(
        1,
        "demo",
        "0000000000000000000000000000000000000000000000000000000000000001",
        new ProjectModelFiles("C:/package/bin/projects/demo", "C:/package/bin/projects/demo/scene.json", "C:/package/bin/projects/demo/script.json", "C:/package/bin/projects/demo/preview.json"),
        new ProjectModelScene(1, [3d, 4d]),
        new ProjectModelScript(1, [3d, 4d], [1d, 0d]),
        new ProjectModelPreview(1));

    private static AuthoringMutationResult NewAuthoringMutationResult(string operation, string revision, int undoDepth) => new(
        operation,
        "succeeded",
        "demo",
        "0000000000000000000000000000000000000000000000000000000000000001",
        revision,
        ["scene.goal.position"],
        undoDepth,
        NewProjectSnapshot(),
        NewHierarchySnapshot());
    private static HierarchySnapshot NewHierarchySnapshot() => new(
        1,
        1,
        "demo",
        [
            new HierarchyNode("scene", null, "Scene", "SceneDocument", Props(("SchemaVersion", 1))),
            new HierarchyNode("scene.player", "scene", "Player", "Sprite", Props(("Position", "0, 0"))),
            new HierarchyNode("scene.goal", "scene", "Goal", "Sprite", Props(("Position", "3, 4"))),
            new HierarchyNode("scene.hazard", "scene", "Hazard", "Sprite", Props(("Position", "5, 6"))),
            new HierarchyNode("script", null, "Script", "ScriptDocument", Props(("InstructionCount", 2))),
            new HierarchyNode("script.instructions[0]", "script", "Instruction 0", "HookInstruction", Props(("Hook", "on_start"))),
            new HierarchyNode("script.instructions[1]", "script", "Instruction 1", "HookInstruction", Props(("Hook", "fixed_update"))),
            new HierarchyNode("preview", null, "Preview Config", "PreviewConfig", Props(("SchemaVersion", 1)))
        ]);

    private static AssetCatalogSnapshot NewAssetCatalogSnapshot()
    {
        var paths = new[]
        {
            "assets/audio/lost.audio.wav", "assets/audio/lost.wav", "assets/audio/won.audio.wav", "assets/audio/won.wav",
            "assets/renderer2d/test.ppm", "assets/renderer2d/test.texture",
            "assets/scenes/preview.scene", "assets/scenes/preview.scene.json",
            "assets/scripts/preview.script", "assets/scripts/preview.script.json"
        };
        var items = paths.Select(path =>
        {
            var category = path.Contains("/audio/", StringComparison.Ordinal) ? "Audio"
                : path.Contains("/renderer2d/", StringComparison.Ordinal) ? "Texture"
                : path.Contains("/scenes/", StringComparison.Ordinal) ? "Scene"
                : "Script";
            var name = path[(path.LastIndexOf('/') + 1)..];
            return new AssetCatalogItem("asset://" + path["assets/".Length..], name, path, category, Path.GetExtension(path).TrimStart('.'), 64, Props(("Category", category), ("SizeBytes", 64)));
        }).ToArray();
        return new AssetCatalogSnapshot(1, "bin/assets", items.Length, items);
    }

    private static Dictionary<string, JsonElement> Props(params (string Key, object Value)[] values) =>
        values.ToDictionary(value => value.Key, value => JsonSerializer.SerializeToElement(value.Value, EditorProtocol.JsonOptions), StringComparer.Ordinal);
    private static EditorBakeResult NewBakeResult() => new(
        "succeeded", "Both", "debug", "C:/package/bin/projects/demo/.kadath/derived", "C:/package/bin/projects/demo/.kadath/derived/.live-bake.manifest.json",
        "SCENE-SOURCE", "SCRIPT-SOURCE", "SCENE-ARTIFACT", "SCRIPT-ARTIFACT", 128, 96);

    public Task EmitEventAsync(string eventName, object data, string? requestId = null) =>
        EmitLineAsync(new EditorEvent(EditorProtocol.SchemaVersion, "event", Interlocked.Increment(ref _sequence), eventName, requestId, JsonSerializer.SerializeToElement(data, EditorProtocol.JsonOptions)));

    public Task EmitRawEventAsync(long sequence) =>
        EmitLineAsync(new EditorEvent(EditorProtocol.SchemaVersion, "event", sequence, "synthetic_duplicate", null, JsonSerializer.SerializeToElement(new { }, EditorProtocol.JsonOptions)));

    public void CompleteServerOutput() => _toClient.Writer.TryComplete();

    private Task SendResponseAsync<T>(string id, T result) => EmitLineAsync(new EditorRpcResponse(EditorProtocol.SchemaVersion, "response", id, true, JsonSerializer.SerializeToElement(result, EditorProtocol.JsonOptions), null));

    private Task SendErrorAsync(string id, string code, string message) => EmitLineAsync(new EditorRpcResponse(EditorProtocol.SchemaVersion, "response", id, false, null, new EditorRpcError(code, message)));

    private Task EmitLineAsync<T>(T value) => _toClient.Writer.WriteAsync(JsonSerializer.Serialize(value, EditorProtocol.JsonOptions)).AsTask();

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0) { return; }
        _stop.Cancel();
        _toClient.Writer.TryComplete();
        _toServer.Writer.TryComplete();
        _stop.Dispose();
        await Task.CompletedTask;
    }
}
