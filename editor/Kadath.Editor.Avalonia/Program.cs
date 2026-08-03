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
        if (args.Length >= 5 && string.Equals(args[0], "--workflow-smoke", StringComparison.Ordinal))
        {
            WorkflowSmokeAsync(args[1], args[2], args[3], args[4]).GetAwaiter().GetResult();
            return;
        }


        BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
    }

    public static AppBuilder BuildAvaloniaApp() =>
        AppBuilder.Configure<App>()
            .UsePlatformDetect()
            .LogToTrace();
    private static async Task WorkflowSmokeAsync(
        string kadathRootArgument,
        string packageRootArgument,
        string openProjectName,
        string createdProjectName)
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

        var opened = await workspace.OpenProjectAsync(new ProjectOpenParameters(packageRoot, openProjectName), cancellationToken);
        Require(opened.ProjectName == openProjectName && workspace.Project.Session is not null, "project_open state mismatch");
        var avaloniaViewModel = new AvaloniaEditorViewModel(workspace, new InlineEditorViewDispatcher(), packageRoot);
        avaloniaViewModel.ProjectName = openProjectName;
        await avaloniaViewModel.RefreshSnapshotsForCurrentProjectAsync(cancellationToken);
        var expectedAssetCount = Directory.EnumerateFiles(Path.Combine(packageRoot, "bin", "assets"), "*", SearchOption.AllDirectories).Count();
        Require(avaloniaViewModel.HierarchyItems.Count == 11 && expectedAssetCount > 0 && avaloniaViewModel.AssetItems.Count == expectedAssetCount,
            "Avalonia should project every asset from the current product package.");
        Require(avaloniaViewModel.InspectorText.Contains("scene.goal", StringComparison.Ordinal), "Avalonia hierarchy inspector did not use snapshot data");
        Console.WriteLine("workflow_snapshot_projection=ok");
        Console.WriteLine("workflow_project_open=ok");

        var oldHierarchyLabel = avaloniaViewModel.HierarchyItems[0];
        var oldAssetLabel = avaloniaViewModel.AssetItems[0];
        avaloniaViewModel.SelectedHierarchyItem = oldHierarchyLabel;
        avaloniaViewModel.SelectedAssetItem = oldAssetLabel;
        var observedAtomicCacheClear = false;
        void ObserveCreatedSession(object? _, System.ComponentModel.PropertyChangedEventArgs args)
        {
            if (args.PropertyName != nameof(EditorProjectViewModel.Session)
                || workspace.Project.Session?.ProjectName != createdProjectName) { return; }
            Require(avaloniaViewModel.HierarchyItems.Count == 0
                && avaloniaViewModel.AssetItems.Count == 0
                && avaloniaViewModel.SelectedHierarchyItem is null
                && avaloniaViewModel.SelectedAssetItem is null
                && avaloniaViewModel.InspectorText.Length == 0
                && avaloniaViewModel.SceneGoalX.Length == 0
                && avaloniaViewModel.SceneGoalY.Length == 0
                && avaloniaViewModel.ScriptGoalX.Length == 0
                && avaloniaViewModel.ScriptGoalY.Length == 0
                && avaloniaViewModel.ScriptVelocityX.Length == 0
                && avaloniaViewModel.ScriptVelocityY.Length == 0,
                "Avalonia retained old UI projection when the Workspace Session identity changed");

            // 通过公开选择属性探测字典；旧 label 不得再恢复旧 Inspector。
            avaloniaViewModel.SelectedHierarchyItem = oldHierarchyLabel;
            avaloniaViewModel.SelectedAssetItem = oldAssetLabel;
            Require(avaloniaViewModel.InspectorText.Length == 0,
                "Avalonia retained a stale hierarchy/asset lookup after Session switch");
            avaloniaViewModel.SelectedHierarchyItem = null;
            avaloniaViewModel.SelectedAssetItem = null;
            observedAtomicCacheClear = true;
        }

        workspace.Project.PropertyChanged += ObserveCreatedSession;
        ProjectSessionInfo created;
        try
        {
            avaloniaViewModel.ProjectName = createdProjectName;
            created = await avaloniaViewModel.CreateProjectForCurrentInputAsync(cancellationToken);
        }
        finally { workspace.Project.PropertyChanged -= ObserveCreatedSession; }

        Require(observedAtomicCacheClear
            && created.ProjectName == createdProjectName
            && workspace.ProjectSnapshot.Value?.ProjectName == createdProjectName
            && workspace.HierarchySnapshot.Value?.ProjectName == createdProjectName
            && avaloniaViewModel.HierarchyItems.Count == 11
            && avaloniaViewModel.AssetItems.Count == expectedAssetCount
            && avaloniaViewModel.InspectorText.Contains("scene.goal", StringComparison.Ordinal),
            "Avalonia public Create did not project the new Session snapshots after atomic cache invalidation");
        Console.WriteLine("workflow_project_create=ok");
        Require(workspace.Publication.State == EditorPublicationState.Missing, "fresh project should expose missing publication artifacts");
        Console.WriteLine("workflow_publication_missing=ok");

        // 工作流 smoke 覆盖真实 authoring transaction：Apply 更新文件并建立撤销记录，Undo 恢复原值。
        var originalSceneGoalX = avaloniaViewModel.SceneGoalX;
        var originalPlayerTextureId = avaloniaViewModel.ScenePlayerTextureId;
        var originalSceneGoal = double.Parse(originalSceneGoalX, CultureInfo.InvariantCulture);
        avaloniaViewModel.SceneGoalX = (originalSceneGoal + 11d).ToString("R", CultureInfo.InvariantCulture);
        avaloniaViewModel.ScenePlayerTextureId = originalPlayerTextureId == "1" ? "2" : "1";
        var appliedAuthoring = await avaloniaViewModel.ApplyAuthoringForCurrentProjectAsync(cancellationToken);
        Require(string.Equals(appliedAuthoring.State, "succeeded", StringComparison.OrdinalIgnoreCase)
            && workspace.Authoring.UndoDepth == 1
            && appliedAuthoring.ChangedFields.Contains("scene.player.textureId"), "authoring apply did not create a successful texture-aware undo record");
        Console.WriteLine("workflow_authoring_apply=ok");

        var undoneAuthoring = await avaloniaViewModel.UndoAuthoringForCurrentProjectAsync(cancellationToken);
        Require(string.Equals(undoneAuthoring.Operation, "undo", StringComparison.OrdinalIgnoreCase)
            && workspace.Authoring.UndoDepth == 0
            && avaloniaViewModel.SceneGoalX == originalSceneGoalX
            && avaloniaViewModel.ScenePlayerTextureId == originalPlayerTextureId, "authoring undo did not restore the prior values");
        Console.WriteLine("workflow_authoring_undo=ok");

        var validation = await workspace.ValidateProjectAsync(createdProjectName, cancellationToken);
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
            ProjectName: createdProjectName,
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

        Require(viewModel.CanCreateProject && viewModel.CreateProjectCommand.CanExecute(null),
            "project_create capability did not enable the Avalonia command while both lifecycles were stopped");
        viewModel.PackageRoot = "C:/smoke-package";
        viewModel.ProjectName = "smoke_created";
        transport.DelayNextCreateResponse();
        using var createTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        var createTask = viewModel.CreateProjectForCurrentInputAsync(createTimeout.Token);
        await WaitUntilAsync(() => transport.DelayedCreatePending, createTimeout.Token, "headless project_create request");
        Require(viewModel.IsBusy
            && workspace.Project.State == EditorProjectState.Creating
            && !viewModel.CanCreateProject
            && !viewModel.CreateProjectCommand.CanExecute(null),
            "Project.Creating did not disable the Avalonia Create command");
        await transport.ReleaseDelayedCreateAsync();
        var created = await createTask.WaitAsync(createTimeout.Token);
        Require(created.ProjectName == "smoke_created"
            && viewModel.HierarchyItems.Count == 1
            && viewModel.AssetItems.Count == 1,
            "public Avalonia Create workflow did not project the created snapshots");

        var retainedSceneGoalX = viewModel.SceneGoalX;
        await transport.EmitProjectCreatedAsync(created with
        {
            PackageRoot = "c:\\smoke-package\\.",
            ProjectName = "SMOKE_CREATED"
        });
        await transport.EmitReplayBarrierAsync();
        await WaitUntilAsync(
            () => viewModel.EventLog.LastOrDefault()?.Event == "headless_project_replay_barrier",
            createTimeout.Token,
            "same-identity project_created replay");
        Require(viewModel.HierarchyItems.Count == 1
            && viewModel.AssetItems.Count == 1
            && viewModel.SceneGoalX == retainedSceneGoalX,
            "normalized same-identity project_created replay cleared the Avalonia projection");

        var createEnvelope = transport.LastProjectCreateRequest
            ?? throw new InvalidOperationException("Avalonia Create did not cross the typed Client transport seam");
        var createParameters = createEnvelope.GetProperty("params");
        var createParameterNames = createParameters.EnumerateObject()
            .Select(property => property.Name)
            .OrderBy(name => name, StringComparer.Ordinal)
            .ToArray();
        Require(createParameterNames.SequenceEqual(["packageRoot", "projectName"])
            && createParameters.GetProperty("packageRoot").GetString() == "C:/smoke-package"
            && createParameters.GetProperty("projectName").GetString() == "smoke_created",
            "Avalonia Create added parameters outside PackageRoot/ProjectName");
        Console.WriteLine("project_create_gating=ok");

        transport.FailNextWatchStart();
        try
        {
            _ = await workspace.StartWatchAsync(new WatchStartParameters("Scene", "debug"), createTimeout.Token);
            throw new InvalidOperationException("injected watch_start failure unexpectedly succeeded");
        }
        catch (EditorRpcException exception) when (exception.Code == "watch_start_failed") { }
        Require(workspace.Watch.State == EditorWatchState.Failed
            && !viewModel.CanCreateProject
            && viewModel.CanRequestWatchStop
            && viewModel.StopWatchCommand.CanExecute(null),
            "Watch Failed did not keep Stop enabled while Create stayed disabled");
        viewModel.StopWatchCommand.Execute(null);
        await WaitUntilAsync(() => workspace.Watch.State == EditorWatchState.Stopped, createTimeout.Token, "failed watch recovery");
        Require(viewModel.CanCreateProject, "Create did not recover after Watch returned to Stopped");

        transport.FailNextPreviewStart();
        try
        {
            _ = await workspace.StartPreviewAsync(new PreviewStartParameters(ProjectName: "smoke_created"), createTimeout.Token);
            throw new InvalidOperationException("injected preview_start failure unexpectedly succeeded");
        }
        catch (EditorRpcException exception) when (exception.Code == "preview_start_failed") { }
        Require(workspace.Preview.State == EditorPreviewState.Failed
            && !viewModel.CanCreateProject
            && viewModel.CanRequestPreviewStop
            && viewModel.StopPreviewCommand.CanExecute(null),
            "Preview Failed did not keep Stop enabled while Create stayed disabled");
        viewModel.StopPreviewCommand.Execute(null);
        await WaitUntilAsync(() => workspace.Preview.State == EditorPreviewState.Stopped, createTimeout.Token, "failed preview recovery");
        Require(viewModel.CanCreateProject,
            "Create did not recover after both Watch and Preview returned to Stopped");
        Console.WriteLine("failed_lifecycle_stop_recovery=ok");

        await using var noCreateTransport = new SmokeTransport(advertiseProjectCreate: false);
        await using var noCreateClient = new EditorRpcClient(noCreateTransport, "avalonia-no-create-smoke", "1");
        await using var noCreateWorkspace = new EditorWorkspaceViewModel(noCreateClient, new InlineEditorViewDispatcher());
        var noCreateViewModel = new AvaloniaEditorViewModel(noCreateWorkspace, new InlineEditorViewDispatcher(), Environment.CurrentDirectory);
        await noCreateWorkspace.ConnectAsync(createTimeout.Token);
        Require(!noCreateViewModel.CanCreateProject
            && !noCreateViewModel.CreateProjectCommand.CanExecute(null),
            "Avalonia enabled Create without the negotiated project_create capability");
        Console.WriteLine("project_create_capability_absence=ok");

        Console.WriteLine("shared_workspace_injection=ok");
        Console.WriteLine("capability_gating=ok");
        Console.WriteLine("verification=ok");
    }

    private sealed class SmokeTransport : IEditorRpcTransport
    {
        private readonly Channel<string> _lines = Channel.CreateUnbounded<string>();
        private long _sequence;
        private string _activePackageRoot = "C:/smoke-package";
        private string _activeProjectName = "smoke_created";
        private bool _delayNextCreate;
        private bool _failNextWatchStart;
        private bool _failNextPreviewStart;
        private readonly bool _advertiseProjectCreate;
        private TaskCompletionSource<bool>? _delayedCreateRelease;
        private TaskCompletionSource<bool>? _delayedCreateCompleted;
        public bool IsOpen { get; private set; }
        public bool DelayedCreatePending => _delayedCreateRelease is not null;
        public JsonElement? LastProjectCreateRequest { get; private set; }

        public SmokeTransport(bool advertiseProjectCreate = true) =>
            _advertiseProjectCreate = advertiseProjectCreate;

        public Task StartAsync(CancellationToken cancellationToken = default)
        {
            IsOpen = true;
            var hello = new EditorHello(EditorProtocol.SchemaVersion, "hello", EditorProtocol.ProtocolName, EditorProtocol.SchemaVersion, [EditorProtocol.TransportName], ["rpc", "preview-surface"]);
            _lines.Writer.TryWrite(JsonSerializer.Serialize(hello, EditorProtocol.JsonOptions));
            return Task.CompletedTask;
        }

        public async Task SendLineAsync(string line, CancellationToken cancellationToken = default)
        {
            using var document = JsonDocument.Parse(line);
            var root = document.RootElement;
            if (!root.TryGetProperty("method", out var methodElement)) { return; }
            var method = methodElement.GetString();
            var id = root.GetProperty("id").GetString()!;
            switch (method)
            {
                case "get_capabilities":
                    await SendResponseAsync(id, new EditorCapabilities(
                        CreateCommands(),
                        [EditorProtocol.TransportName],
                        [
                            new PreviewSurfaceCapability(PreviewSurfaceModes.ExternalWindow, "native-window", true),
                            new PreviewSurfaceCapability(PreviewSurfaceModes.SharedTexture, "gpu-shared-resource", false),
                            new PreviewSurfaceCapability(PreviewSurfaceModes.FrameStream, "encoded-frame-stream", false)
                        ])).ConfigureAwait(false);
                    break;
                case "project_create":
                    LastProjectCreateRequest = root.Clone();
                    var parameters = root.GetProperty("params");
                    var packageRoot = parameters.GetProperty("packageRoot").GetString()!;
                    var projectName = parameters.GetProperty("projectName").GetString()!;
                    var session = NewSession(packageRoot, projectName);
                    if (_delayNextCreate)
                    {
                        _delayNextCreate = false;
                        _delayedCreateRelease = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
                        _delayedCreateCompleted = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
                        _ = CompleteDelayedCreateAsync(id, session, _delayedCreateRelease.Task, _delayedCreateCompleted);
                        break;
                    }
                    await CompleteCreateAsync(id, session).ConfigureAwait(false);
                    break;
                case "project_snapshot":
                    var project = NewProjectSnapshot();
                    await EmitEventAsync("project_snapshot_created", project, id).ConfigureAwait(false);
                    await SendResponseAsync(id, project).ConfigureAwait(false);
                    break;
                case "hierarchy_snapshot":
                    var hierarchy = NewHierarchySnapshot();
                    await EmitEventAsync("hierarchy_snapshot_created", hierarchy, id).ConfigureAwait(false);
                    await SendResponseAsync(id, hierarchy).ConfigureAwait(false);
                    break;
                case "asset_catalog_snapshot":
                    var assets = NewAssetCatalogSnapshot();
                    await EmitEventAsync("asset_catalog_snapshot_created", assets, id).ConfigureAwait(false);
                    await SendResponseAsync(id, assets).ConfigureAwait(false);
                    break;
                case "watch_start":
                    if (_failNextWatchStart)
                    {
                        _failNextWatchStart = false;
                        await SendErrorAsync(id, "watch_start_failed", "injected watch start failure").ConfigureAwait(false);
                        break;
                    }
                    var watched = new EditorWatchResult("watching", _activeProjectName, "Scene", "debug", null);
                    await EmitEventAsync("watch_started", watched, id).ConfigureAwait(false);
                    await SendResponseAsync(id, watched).ConfigureAwait(false);
                    break;
                case "watch_stop":
                    var stoppedWatch = new EditorWatchResult("stopped", _activeProjectName, "Scene", "debug", null);
                    await EmitEventAsync("watch_stopped", stoppedWatch, id).ConfigureAwait(false);
                    await SendResponseAsync(id, stoppedWatch).ConfigureAwait(false);
                    break;
                case "preview_start":
                    if (_failNextPreviewStart)
                    {
                        _failNextPreviewStart = false;
                        await SendErrorAsync(id, "preview_start_failed", "injected preview start failure").ConfigureAwait(false);
                        break;
                    }
                    await SendResponseAsync(id, new PreviewStartResult("starting", PreviewSurfaceModes.ExternalWindow)).ConfigureAwait(false);
                    break;
                case "preview_stop":
                    await EmitEventAsync("preview_stopped", new { exitCode = 0, requested = true }, id).ConfigureAwait(false);
                    await SendResponseAsync(id, new PreviewStopResult("stopped")).ConfigureAwait(false);
                    break;
            }
        }

        public void DelayNextCreateResponse() => _delayNextCreate = true;

        public void FailNextWatchStart() => _failNextWatchStart = true;

        public void FailNextPreviewStart() => _failNextPreviewStart = true;

        public Task EmitProjectCreatedAsync(ProjectSessionInfo session) =>
            EmitEventAsync("project_created", session);

        public Task EmitReplayBarrierAsync() =>
            EmitEventAsync("headless_project_replay_barrier", new { });

        private string[] CreateCommands()
        {
            var commands = new List<string>
            {
                "get_capabilities", "project_open", "project_validate", "project_snapshot", "hierarchy_snapshot",
                "asset_catalog_snapshot", "bake_start", "watch_start", "watch_stop", "preview_start", "preview_stop", "shutdown"
            };
            if (_advertiseProjectCreate) { commands.Insert(2, "project_create"); }
            return commands.ToArray();
        }

        public async Task ReleaseDelayedCreateAsync()
        {
            var release = _delayedCreateRelease ?? throw new InvalidOperationException("No delayed project_create is pending.");
            var completed = _delayedCreateCompleted ?? throw new InvalidOperationException("Delayed project_create completion is missing.");
            release.TrySetResult(true);
            await completed.Task.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
            _delayedCreateRelease = null;
            _delayedCreateCompleted = null;
        }

        private async Task CompleteDelayedCreateAsync(
            string id,
            ProjectSessionInfo session,
            Task release,
            TaskCompletionSource<bool> completed)
        {
            try
            {
                await release.ConfigureAwait(false);
                await CompleteCreateAsync(id, session).ConfigureAwait(false);
            }
            finally { completed.TrySetResult(true); }
        }

        private async Task CompleteCreateAsync(string id, ProjectSessionInfo session)
        {
            _activePackageRoot = session.PackageRoot;
            _activeProjectName = session.ProjectName;
            await EmitEventAsync("project_created", session, id).ConfigureAwait(false);
            await SendResponseAsync(id, session).ConfigureAwait(false);
        }

        private static ProjectSessionInfo NewSession(string packageRoot, string projectName)
        {
            var directory = $"{packageRoot}/bin/projects/{projectName}";
            return new ProjectSessionInfo(
                packageRoot,
                projectName,
                directory,
                $"{directory}/scene.json",
                $"{directory}/script.json",
                $"{directory}/preview.json",
                1);
        }

        private ProjectModelSnapshot NewProjectSnapshot() => new(
            1,
            _activeProjectName,
            new string('1', 64),
            new ProjectModelFiles(
                $"{_activePackageRoot}/bin/projects/{_activeProjectName}",
                $"{_activePackageRoot}/bin/projects/{_activeProjectName}/scene.json",
                $"{_activePackageRoot}/bin/projects/{_activeProjectName}/script.json",
                $"{_activePackageRoot}/bin/projects/{_activeProjectName}/preview.json"),
            new ProjectModelScene(3, [3d, 4d], 1, 2, 3, [new ProjectModelTexture(1, "assets/renderer2d/test.texture"), new ProjectModelTexture(2, "assets/renderer2d/goal.texture"), new ProjectModelTexture(3, "assets/renderer2d/goal.texture")]),
            new ProjectModelScript(1, [3d, 4d], [1d, 0d]),
            new ProjectModelPreview(1));

        private HierarchySnapshot NewHierarchySnapshot() => new(
            1,
            1,
            _activeProjectName,
            [new HierarchyNode("scene.goal", null, "Goal", "Sprite", [])]);

        private static AssetCatalogSnapshot NewAssetCatalogSnapshot() => new(
            1,
            "bin/assets",
            1,
            [new AssetCatalogItem("asset://scenes/smoke.scene", "smoke.scene", "assets/scenes/smoke.scene", "Scene", "scene", 64, [])]);

        private Task EmitEventAsync(string eventName, object data, string? requestId = null) =>
            WriteAsync(new EditorEvent(
                EditorProtocol.SchemaVersion,
                "event",
                Interlocked.Increment(ref _sequence),
                eventName,
                requestId,
                JsonSerializer.SerializeToElement(data, EditorProtocol.JsonOptions)));

        private Task SendResponseAsync<T>(string id, T result) =>
            WriteAsync(new EditorRpcResponse(
                EditorProtocol.SchemaVersion,
                "response",
                id,
                true,
                JsonSerializer.SerializeToElement(result, EditorProtocol.JsonOptions),
                null));

        private Task SendErrorAsync(string id, string code, string message) =>
            WriteAsync(new EditorRpcResponse(
                EditorProtocol.SchemaVersion,
                "response",
                id,
                false,
                null,
                new EditorRpcError(code, message)));

        private Task WriteAsync<T>(T value) =>
            _lines.Writer.WriteAsync(JsonSerializer.Serialize(value, EditorProtocol.JsonOptions)).AsTask();

        public async Task<string?> ReadLineAsync(CancellationToken cancellationToken = default) => await _lines.Reader.ReadAsync(cancellationToken);
        public ValueTask DisposeAsync() { IsOpen = false; _lines.Writer.TryComplete(); return ValueTask.CompletedTask; }
    }
}
