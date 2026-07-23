using System.Globalization;
using System.Text.Json;
using System.Threading.Channels;
using Avalonia;
using Kadath.Editor.Avalonia.Client;
using Kadath.Editor.Avalonia.ViewModels;
using Kadath.Editor.Avalonia.Views;
using Kadath.Editor.Client;
using Kadath.Editor.Protocol;
using Kadath.Editor.ViewModels;

namespace Kadath.Editor.Avalonia;

internal static class Program
{
    [STAThread]
    public static void Main(string[] args)
    {
        if (args.Contains("--headless-smoke", StringComparer.Ordinal))
        {
            HeadlessSmokeAsync().GetAwaiter().GetResult();
            return;
        }
        if (args.Length >= 4 && string.Equals(args[0], "--workflow-smoke", StringComparison.Ordinal))
        {
            WorkflowSmokeAsync(args[1], args[2], args[3]).GetAwaiter().GetResult();
            return;
        }


        BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
    }

    public static AppBuilder BuildAvaloniaApp() =>
        AppBuilder.Configure<App>()
            .UsePlatformDetect()
            .LogToTrace();
    private static async Task WorkflowSmokeAsync(string kadathRootArgument, string packageRootArgument, string projectName)
    {
        var kadathRoot = Path.GetFullPath(kadathRootArgument);
        var packageRoot = Path.GetFullPath(packageRootArgument);
        var editorRoot = Path.Combine(kadathRoot, "editor");
        var serviceDll = Path.Combine(editorRoot, "Kadath.Editor.Service", "bin", "Debug", "net8.0", "Kadath.Editor.Service.dll");
        if (!File.Exists(serviceDll)) { throw new FileNotFoundException("Editor Service 尚未构建。", serviceDll); }

        var transport = new StdioEditorRpcTransport(new EditorRpcProcessOptions(
            "dotnet",
            [serviceDll, "--kadath-root", kadathRoot],
            kadathRoot));
        await using var client = new EditorRpcClient(transport, "kadath-editor-avalonia-workflow", "1");
        await using var workspace = new EditorWorkspaceViewModel(client, new InlineEditorViewDispatcher());
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(90));
        var cancellationToken = timeout.Token;

        await workspace.ConnectAsync(cancellationToken);
        Require(workspace.ConnectionState == EditorConnectionState.Ready, "workspace did not reach Ready");
        Console.WriteLine("workflow_connect=ok");

        var opened = await workspace.OpenProjectAsync(new ProjectOpenParameters(packageRoot, projectName), cancellationToken);
        Require(opened.ProjectName == projectName && workspace.Project.Session is not null, "project_open state mismatch");
        var avaloniaViewModel = new AvaloniaEditorViewModel(workspace, new InlineEditorViewDispatcher(), packageRoot);
        avaloniaViewModel.ProjectName = projectName;
        await avaloniaViewModel.RefreshSnapshotsForCurrentProjectAsync(cancellationToken);
        Require(avaloniaViewModel.HierarchyItems.Count == 8 && avaloniaViewModel.AssetItems.Count == 10, "Avalonia should project real snapshot collections.");
        Require(avaloniaViewModel.InspectorText.Contains("scene.goal", StringComparison.Ordinal), "Avalonia hierarchy inspector did not use snapshot data");
        Console.WriteLine("workflow_snapshot_projection=ok");
        Require(workspace.Publication.State == EditorPublicationState.Missing, "fresh project should expose missing publication artifacts");
        Console.WriteLine("workflow_publication_missing=ok");

        // 工作流 smoke 覆盖真实 authoring transaction：Apply 更新文件并建立撤销记录，Undo 恢复原值。
        var originalSceneGoalX = avaloniaViewModel.SceneGoalX;
        var originalSceneGoal = double.Parse(originalSceneGoalX, CultureInfo.InvariantCulture);
        avaloniaViewModel.SceneGoalX = (originalSceneGoal + 11d).ToString("R", CultureInfo.InvariantCulture);
        var appliedAuthoring = await avaloniaViewModel.ApplyAuthoringForCurrentProjectAsync(cancellationToken);
        Require(string.Equals(appliedAuthoring.State, "succeeded", StringComparison.OrdinalIgnoreCase)
            && workspace.Authoring.UndoDepth == 1, "authoring apply did not create a successful undo record");
        Console.WriteLine("workflow_authoring_apply=ok");

        var undoneAuthoring = await avaloniaViewModel.UndoAuthoringForCurrentProjectAsync(cancellationToken);
        Require(string.Equals(undoneAuthoring.Operation, "undo", StringComparison.OrdinalIgnoreCase)
            && workspace.Authoring.UndoDepth == 0
            && avaloniaViewModel.SceneGoalX == originalSceneGoalX, "authoring undo did not restore the prior value");
        Console.WriteLine("workflow_authoring_undo=ok");
        Console.WriteLine("workflow_project_open=ok");

        var validation = await workspace.ValidateProjectAsync(projectName, cancellationToken);
        Require(string.Equals(validation.State, "valid", StringComparison.OrdinalIgnoreCase), "project_validate was not valid");
        Console.WriteLine("workflow_project_validate=ok");

        var baked = await workspace.BakeAsync(new BakeStartParameters("Both", "debug"), cancellationToken);
        Require(string.Equals(baked.State, "succeeded", StringComparison.OrdinalIgnoreCase), "bake did not succeed");
        Console.WriteLine("workflow_bake=ok");
        Require(workspace.Publication.State == EditorPublicationState.Current, "full bake did not publish a current snapshot");
        avaloniaViewModel.SceneGoalX = (double.Parse(avaloniaViewModel.SceneGoalX, CultureInfo.InvariantCulture) + 5d).ToString("R", CultureInfo.InvariantCulture);
        var changedAfterPublish = await avaloniaViewModel.ApplyAuthoringForCurrentProjectAsync(cancellationToken);
        Require(string.Equals(changedAfterPublish.State, "succeeded", StringComparison.OrdinalIgnoreCase) && workspace.Publication.State == EditorPublicationState.SourceDirty, "published source edit did not become dirty");
        Console.WriteLine("workflow_publication_dirty=ok");
        var incremental = await workspace.BakeChangesAsync("debug", cancellationToken);
        Require(incremental?.Target == "Scene" && workspace.Publication.State == EditorPublicationState.Current, "Bake Changes did not choose Scene after source edit");
        Console.WriteLine("workflow_bake_changes=ok");

        var watched = await workspace.StartWatchAsync(new WatchStartParameters("Scene", "debug", 50, 100), cancellationToken);
        Require(string.Equals(watched.State, "watching", StringComparison.OrdinalIgnoreCase), "watch did not start");
        await WaitUntilAsync(() => workspace.Watch.State == EditorWatchState.Watching, cancellationToken, "watching state");
        Console.WriteLine("workflow_watch_start=ok");

        var stoppedWatch = await workspace.StopWatchAsync(cancellationToken);
        Require(string.Equals(stoppedWatch.State, "stopped", StringComparison.OrdinalIgnoreCase), "watch did not stop");
        await WaitUntilAsync(() => workspace.Watch.State == EditorWatchState.Stopped, cancellationToken, "watch stopped state");
        Console.WriteLine("workflow_watch_stop=ok");

        // Preview 仍使用独立 native window；27A 额外跨越 live bake/watch 验证 Runtime 实际确认 revision。
        var preview = await workspace.StartPreviewAsync(new PreviewStartParameters(
            ProjectName: projectName,
            WatchChanges: true,
            PollIntervalMilliseconds: 50,
            DebounceMilliseconds: 100,
            LiveBake: true,
            BakeProfile: "debug"), cancellationToken);
        Require(string.Equals(preview.SurfaceMode, PreviewSurfaceModes.ExternalWindow, StringComparison.Ordinal), "preview surface mode mismatch");
        await WaitUntilAsync(() => workspace.Preview.Surface is not null && workspace.Preview.RuntimeProcessId is not null, cancellationToken, "preview surface/runtime pid");
        Console.WriteLine("workflow_preview_start=ok");
        await WaitUntilAsync(() => workspace.Preview.Runtime.State == EditorPreviewRuntimeState.Loaded, cancellationToken, "preview initial loaded identity");
        Require(workspace.Preview.Runtime.Scene.ArtifactRevision is { Length: 64 }
            && workspace.Preview.Runtime.Scene.ArtifactBytes is > 0
            && workspace.Preview.Runtime.Script.ArtifactRevision is { Length: 64 }
            && workspace.Preview.Runtime.Script.ArtifactBytes is > 0,
            "Avalonia did not project the atomic Runtime initial identity");
        Console.WriteLine("workflow_preview_initial_loaded=ok");

        avaloniaViewModel.SceneGoalX = (double.Parse(avaloniaViewModel.SceneGoalX, CultureInfo.InvariantCulture) + 3d).ToString("R", CultureInfo.InvariantCulture);
        var liveEdited = await avaloniaViewModel.ApplyAuthoringForCurrentProjectAsync(cancellationToken);
        Require(string.Equals(liveEdited.State, "succeeded", StringComparison.OrdinalIgnoreCase), "live Preview authoring update failed");
        await WaitUntilAsync(() => workspace.Preview.Reload.Scene.State == EditorPreviewReloadState.Acknowledged, cancellationToken, "Scene Runtime reload acknowledgement");
        Require(workspace.Preview.Reload.Scene.AcknowledgedSourceRevision is { Length: 64 }
            && workspace.Preview.Reload.Scene.AcknowledgedArtifactRevision is { Length: 64 }
            && avaloniaViewModel.RuntimeSyncStatus.Contains("Scene loaded", StringComparison.Ordinal),
            "Avalonia did not project the acknowledged Scene revision");
        Console.WriteLine("workflow_preview_reload_ack=ok");

        var stoppedPreview = await workspace.StopPreviewAsync(cancellationToken);
        Require(string.Equals(stoppedPreview.State, "stopped", StringComparison.OrdinalIgnoreCase), "preview_stop response mismatch");
        await WaitUntilAsync(() => workspace.Preview.State == EditorPreviewState.Stopped, cancellationToken, "preview stopped event");
        Console.WriteLine("workflow_preview_stop=ok");

        await workspace.ShutdownAsync(cancellationToken);
        await avaloniaViewModel.DisposeAsync();
        Console.WriteLine("workflow_shutdown=ok");
        Console.WriteLine("verification=ok");
    }

    private static async Task WaitUntilAsync(Func<bool> predicate, CancellationToken cancellationToken, string description)
    {
        while (!predicate())
        {
            await Task.Delay(50, cancellationToken);
        }

        // 保持描述参数用于调用点自解释；条件已满足时不产生额外输出，输出协议保持稳定。
        _ = description;
    }

    private static void Require(bool condition, string message)
    {
        if (!condition) { throw new InvalidOperationException(message); }
    }

    private static async Task HeadlessSmokeAsync()
    {
        // 无窗口 smoke 检查编译后的 Avalonia resource，避免平台 backend 启动消息循环。
        var assembly = typeof(MainWindow).Assembly;
        if (!assembly.GetManifestResourceNames().Contains("!AvaloniaResources", StringComparer.Ordinal)
            || !assembly.GetTypes().Any(type => type.FullName?.Contains("Views/MainWindow.axaml", StringComparison.Ordinal) == true))
        {
            throw new InvalidOperationException("Compiled MainWindow XAML resource is missing.");
        }
        Console.WriteLine("avalonia_compiled_xaml=ok");

        await using var transport = new SmokeTransport();
        await using var client = new EditorRpcClient(transport, "avalonia-smoke", "1");
        await using var workspace = new EditorWorkspaceViewModel(client, new InlineEditorViewDispatcher());
        var viewModel = new AvaloniaEditorViewModel(workspace, new InlineEditorViewDispatcher(), Environment.CurrentDirectory);
        await workspace.ConnectAsync();
        if (!ReferenceEquals(viewModel.Workspace, workspace)) { throw new InvalidOperationException("Avalonia ViewModel did not retain injected Workspace."); }
        // Live Bake/Watch 保持 opt-in，打开编辑器本身不能隐式启动派生构建。
        if (viewModel.LiveBakeEnabled || viewModel.WatchChanges) { throw new InvalidOperationException("Live Bake/Watch must be disabled by default."); }
        Console.WriteLine("live_bake_opt_in=ok");
        if (!viewModel.SupportsExternalWindow || viewModel.SupportsSharedTexture || viewModel.SupportsFrameStream)
        {
            throw new InvalidOperationException("Preview capability gating does not match the v1 external-window contract.");
        }

        Console.WriteLine("shared_workspace_injection=ok");
        Console.WriteLine("capability_gating=ok");
        Console.WriteLine("verification=ok");
    }

    private sealed class SmokeTransport : IEditorRpcTransport
    {
        private readonly Channel<string> _lines = Channel.CreateUnbounded<string>();
        public bool IsOpen { get; private set; }

        public Task StartAsync(CancellationToken cancellationToken = default)
        {
            IsOpen = true;
            var hello = new EditorHello(EditorProtocol.SchemaVersion, "hello", EditorProtocol.ProtocolName, EditorProtocol.SchemaVersion, [EditorProtocol.TransportName], ["rpc", "preview-surface"]);
            _lines.Writer.TryWrite(JsonSerializer.Serialize(hello, EditorProtocol.JsonOptions));
            return Task.CompletedTask;
        }

        public Task SendLineAsync(string line, CancellationToken cancellationToken = default)
        {
            using var document = JsonDocument.Parse(line);
            var root = document.RootElement;
            if (root.TryGetProperty("method", out var method) && method.GetString() == "get_capabilities")
            {
                var capabilities = new EditorCapabilities(
                    ["get_capabilities", "project_open", "project_validate", "bake_start", "watch_start", "watch_stop", "preview_start", "preview_stop", "shutdown"],
                    [EditorProtocol.TransportName],
                    [
                        new PreviewSurfaceCapability(PreviewSurfaceModes.ExternalWindow, "native-window", true),
                        new PreviewSurfaceCapability(PreviewSurfaceModes.SharedTexture, "gpu-shared-resource", false),
                        new PreviewSurfaceCapability(PreviewSurfaceModes.FrameStream, "encoded-frame-stream", false)
                    ]);
                var result = JsonSerializer.SerializeToElement(capabilities, EditorProtocol.JsonOptions);
                var response = new EditorRpcResponse(EditorProtocol.SchemaVersion, "response", root.GetProperty("id").GetString()!, true, result, null);
                _lines.Writer.TryWrite(JsonSerializer.Serialize(response, EditorProtocol.JsonOptions));
            }

            return Task.CompletedTask;
        }

        public async Task<string?> ReadLineAsync(CancellationToken cancellationToken = default) => await _lines.Reader.ReadAsync(cancellationToken);
        public ValueTask DisposeAsync() { IsOpen = false; _lines.Writer.TryComplete(); return ValueTask.CompletedTask; }
    }
}


