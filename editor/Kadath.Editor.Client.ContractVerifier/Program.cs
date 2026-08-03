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
            if (args.Length == 5 && args[0] == "--real-service-only")
            {
                await VerifyRealServiceAsync(args[1], args[2], args[3], args[4]);
                Console.WriteLine("real_service_smoke=ok");
                Console.WriteLine("verification=ok");
                return 0;
            }
            await VerifyProjectCreateClientContractAsync();
            await VerifyProjectCreateCapabilityProjectionAsync();
            await VerifyProjectCreateWorkspaceProjectionAsync();
            await VerifyClientAndViewModelsAsync();
            await VerifyUnexpectedEofProjectionAsync();
            await VerifyExpectedShutdownProjectionAsync();
            if (args.Length == 4)
            {
                await VerifyRealServiceAsync(args[0], args[1], args[2], args[3]);
                Console.WriteLine("real_service_smoke=ok");
            }
            else if (args.Length != 0) { throw new ArgumentException("Usage: [--real-service-only] <serviceDll> <kadathRoot> <packageRoot> <projectName>"); }
            Console.WriteLine("editor_rpc_client=ok");
            Console.WriteLine("request_correlation=ok");
            Console.WriteLine("event_ordering=ok");
            Console.WriteLine("cancellation_late_response=ok");
            Console.WriteLine("connection_closed_projection=ok");
            Console.WriteLine("snapshot_state=ok");
            Console.WriteLine("publication_state=ok");
            Console.WriteLine("preview_initial_loaded_state=ok");
            Console.WriteLine("preview_reload_ack_state=ok");
            Console.WriteLine("bake_changes=ok");
            Console.WriteLine("capability_gating=ok");
            Console.WriteLine("project_create_client=ok");
            Console.WriteLine("project_create_capability=ok");
            Console.WriteLine("project_create_workspace=ok");
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

    private static async Task VerifyProjectCreateClientContractAsync()
    {
        var transport = new ScriptedTransport();
        await using var client = new EditorRpcClient(transport, "project-create-contract-verifier", "1");
        await client.ConnectAsync().ConfigureAwait(false);

        var created = await client.CreateProjectAsync(new ProjectCreateParameters("C:/package", "fresh_project")).ConfigureAwait(false);
        var expected = new ProjectSessionInfo(
            "C:/package",
            "fresh_project",
            "C:/package/bin/projects/fresh_project",
            "C:/package/bin/projects/fresh_project/scene.json",
            "C:/package/bin/projects/fresh_project/script.json",
            "C:/package/bin/projects/fresh_project/preview.json",
            1);
        Assert(created == expected, "project_create result was not mapped to ProjectSessionInfo");

        var request = transport.LastProjectCreateRequest ?? throw new InvalidOperationException("project_create request was not observed by the transport Adapter");
        Assert(request.GetProperty("method").GetString() == "project_create", "typed Create used the wrong RPC method");
        var parameters = request.GetProperty("params");
        var parameterNames = parameters.EnumerateObject().Select(property => property.Name).OrderBy(name => name, StringComparer.Ordinal).ToArray();
        Assert(parameterNames.SequenceEqual(["packageRoot", "projectName"]), $"project_create params mismatch: {string.Join(',', parameterNames)}");
        Assert(parameters.GetProperty("packageRoot").GetString() == "C:/package"
            && parameters.GetProperty("projectName").GetString() == "fresh_project",
            "project_create params did not preserve the typed input");
    }

    private static async Task VerifyProjectCreateCapabilityProjectionAsync()
    {
        await VerifyProjectCreateCapabilityProjectionAsync(advertiseProjectCreate: true, expected: true).ConfigureAwait(false);
        await VerifyProjectCreateCapabilityProjectionAsync(advertiseProjectCreate: false, expected: false).ConfigureAwait(false);
    }

    private static async Task VerifyProjectCreateCapabilityProjectionAsync(bool advertiseProjectCreate, bool expected)
    {
        var transport = new ScriptedTransport(advertiseProjectCreate);
        var client = new EditorRpcClient(transport, "project-create-capability-verifier", "1");
        await using var workspace = new EditorWorkspaceViewModel(client);
        var changedProperties = new List<string?>();
        workspace.Capabilities.PropertyChanged += (_, args) => changedProperties.Add(args.PropertyName);

        await workspace.ConnectAsync().ConfigureAwait(false);

        Assert(workspace.Capabilities.CanCreateProject == expected,
            $"project_create capability projection mismatch: advertised={advertiseProjectCreate}");
        Assert(changedProperties.Contains(nameof(EditorCapabilitiesViewModel.CanCreateProject), StringComparer.Ordinal),
            "CanCreateProject did not publish a property-change notification");
    }

    private static async Task VerifyProjectCreateWorkspaceProjectionAsync()
    {
        await VerifyProjectCreateCapabilityGateAsync().ConfigureAwait(false);
        await VerifyProjectCreateActivityGateAsync().ConfigureAwait(false);
        await VerifyProjectCreateIdentityProjectionAsync().ConfigureAwait(false);
        await VerifyProjectCreateBusinessFailureAsync().ConfigureAwait(false);
        await VerifyProjectCreateConfirmedConnectionFailuresAsync().ConfigureAwait(false);
        await VerifyProjectCreateCancellationAsync().ConfigureAwait(false);
        await VerifyProjectCreateSnapshotRecoveryAsync().ConfigureAwait(false);
    }

    private static async Task VerifyProjectCreateActivityGateAsync()
    {
        await VerifyProjectCreateWatchGateAsync().ConfigureAwait(false);
        await VerifyProjectCreatePreviewGateAsync().ConfigureAwait(false);
    }

    private static async Task VerifyProjectCreateWatchGateAsync()
    {
        var transport = new ScriptedTransport();
        var client = new EditorRpcClient(transport, "project-create-watch-gate-verifier", "1");
        await using var workspace = new EditorWorkspaceViewModel(client);
        await PrepareOpenedWorkspaceAsync(workspace).ConfigureAwait(false);

        transport.DelayNextOperationResponse("watch_start");
        var startTask = workspace.StartWatchAsync(new WatchStartParameters("Scene", "debug", 50, 100));
        await WaitUntilAsync(() => transport.DelayedOperationPending
            && workspace.Watch.State == EditorWatchState.Starting).ConfigureAwait(false);
        await AssertCreateBusyAsync(workspace, transport, "Watch.Starting").ConfigureAwait(false);

        await transport.ReleaseDelayedOperationAsync().ConfigureAwait(false);
        _ = await startTask.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
        Assert(workspace.Watch.State == EditorWatchState.Watching, "delayed watch_start did not reach Watching");
        await AssertCreateBusyAsync(workspace, transport, "Watch.Watching").ConfigureAwait(false);

        transport.DelayNextOperationResponse("watch_stop");
        var stopTask = workspace.StopWatchAsync();
        await WaitUntilAsync(() => transport.DelayedOperationPending
            && workspace.Watch.State == EditorWatchState.Stopping).ConfigureAwait(false);
        await AssertCreateBusyAsync(workspace, transport, "Watch.Stopping").ConfigureAwait(false);
        await transport.ReleaseDelayedOperationAsync().ConfigureAwait(false);
        _ = await stopTask.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);

        transport.FailNextRequest("watch_start", "watch_start_failed", "injected watch start failure");
        try
        {
            _ = await workspace.StartWatchAsync(new WatchStartParameters("Scene", "debug", 50, 100)).ConfigureAwait(false);
            throw new InvalidOperationException("injected watch_start failure unexpectedly succeeded");
        }
        catch (EditorRpcException exception) when (exception.Code == "watch_start_failed") { }
        Assert(workspace.Watch.State == EditorWatchState.Failed, "watch_start failure did not reach Failed");
        await AssertCreateBusyAsync(workspace, transport, "Watch.Failed").ConfigureAwait(false);

        // Stop 的成功 response 是重新开放 Create 的唯一 watch 侧证据。
        _ = await workspace.StopWatchAsync().ConfigureAwait(false);
        Assert(workspace.Watch.State == EditorWatchState.Stopped, "confirmed watch_stop did not restore Stopped");
        var created = await workspace.CreateProjectAsync(
            new ProjectCreateParameters("C:/package", "watch_stopped_project")).ConfigureAwait(false);
        Assert(created.ProjectName == "watch_stopped_project" && transport.LastProjectCreateRequest is not null,
            "confirmed watch_stop did not restore project_create");
    }

    private static async Task VerifyProjectCreatePreviewGateAsync()
    {
        var transport = new ScriptedTransport();
        var client = new EditorRpcClient(transport, "project-create-preview-gate-verifier", "1");
        await using var workspace = new EditorWorkspaceViewModel(client);
        await PrepareOpenedWorkspaceAsync(workspace).ConfigureAwait(false);

        transport.DelayNextOperationResponse("preview_start");
        var startTask = workspace.StartPreviewAsync(new PreviewStartParameters(ProjectName: "demo"));
        await WaitUntilAsync(() => transport.DelayedOperationPending
            && workspace.Preview.State == EditorPreviewState.Starting).ConfigureAwait(false);
        await AssertCreateBusyAsync(workspace, transport, "Preview.Starting").ConfigureAwait(false);

        await transport.ReleaseDelayedOperationAsync().ConfigureAwait(false);
        _ = await startTask.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
        await WaitUntilAsync(() => workspace.Preview.State == EditorPreviewState.Running).ConfigureAwait(false);
        await AssertCreateBusyAsync(workspace, transport, "Preview.Running").ConfigureAwait(false);

        transport.DelayNextOperationResponse("preview_stop");
        var stopTask = workspace.StopPreviewAsync();
        await WaitUntilAsync(() => transport.DelayedOperationPending
            && workspace.Preview.State == EditorPreviewState.Stopping).ConfigureAwait(false);
        await AssertCreateBusyAsync(workspace, transport, "Preview.Stopping").ConfigureAwait(false);
        await transport.ReleaseDelayedOperationAsync().ConfigureAwait(false);
        _ = await stopTask.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);

        _ = await workspace.StartPreviewAsync(new PreviewStartParameters(ProjectName: "demo")).ConfigureAwait(false);
        await WaitUntilAsync(() => workspace.Preview.State == EditorPreviewState.Running).ConfigureAwait(false);
        transport.FailNextPreviewStop();
        try
        {
            _ = await workspace.StopPreviewAsync().ConfigureAwait(false);
            throw new InvalidOperationException("injected preview_stop failure unexpectedly succeeded");
        }
        catch (EditorRpcException exception) when (exception.Code == "preview_stop_failed") { }
        Assert(workspace.Preview.State == EditorPreviewState.Failed, "preview_stop failure did not reach Failed");
        await AssertCreateBusyAsync(workspace, transport, "Preview.Failed").ConfigureAwait(false);

        // Failed 也必须等待明确 Stop 成功，不能把未知 Runtime 状态当作空闲。
        _ = await workspace.StopPreviewAsync().ConfigureAwait(false);
        Assert(workspace.Preview.State == EditorPreviewState.Stopped, "confirmed preview_stop did not restore Stopped");
        var created = await workspace.CreateProjectAsync(
            new ProjectCreateParameters("C:/package", "preview_stopped_project")).ConfigureAwait(false);
        Assert(created.ProjectName == "preview_stopped_project" && transport.LastProjectCreateRequest is not null,
            "confirmed preview_stop did not restore project_create");
    }

    private static async Task AssertCreateBusyAsync(
        EditorWorkspaceViewModel workspace,
        ScriptedTransport transport,
        string stateName)
    {
        try
        {
            _ = await workspace.CreateProjectAsync(
                new ProjectCreateParameters("C:/package", $"blocked_{stateName.Replace('.', '_').ToLowerInvariant()}")).ConfigureAwait(false);
            throw new InvalidOperationException($"project_create unexpectedly ran while {stateName}");
        }
        catch (EditorRpcException exception) when (exception.Code == "project_create_busy") { }

        Assert(transport.LastProjectCreateRequest is null,
            $"project_create crossed the transport boundary while {stateName}");
    }

    private static async Task VerifyProjectCreateCapabilityGateAsync()
    {
        var transport = new ScriptedTransport(advertiseProjectCreate: false);
        var client = new EditorRpcClient(transport, "project-create-gate-verifier", "1");
        await using var workspace = new EditorWorkspaceViewModel(client);
        await workspace.ConnectAsync().ConfigureAwait(false);

        try
        {
            _ = await workspace.CreateProjectAsync(new ProjectCreateParameters("C:/package", "fresh_project")).ConfigureAwait(false);
            throw new InvalidOperationException("Workspace project_create unexpectedly bypassed the capability gate");
        }
        catch (EditorRpcException exception) when (exception.Code == "unsupported_command") { }

        Assert(transport.LastProjectCreateRequest is null,
            "unsupported Workspace project_create crossed the transport boundary");
    }

    private static async Task VerifyProjectCreateIdentityProjectionAsync()
    {
        var transport = new ScriptedTransport();
        var client = new EditorRpcClient(transport, "project-create-identity-verifier", "1");
        await using var workspace = new EditorWorkspaceViewModel(client);
        await PrepareOpenedWorkspaceAsync(workspace).ConfigureAwait(false);

        var observedSessionSwitch = false;
        var snapshotsWereEmptyBeforeSession = false;
        var sessionSwitchObservation = "not-observed";
        workspace.Project.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName != nameof(EditorProjectViewModel.Session)
                || workspace.Project.Session?.ProjectName != "fresh_project") { return; }
            observedSessionSwitch = true;
            // Session 通知是同步的；观察者必须先看到旧项目的三组 snapshot 已失效。
            snapshotsWereEmptyBeforeSession = workspace.ProjectSnapshot.Value is null
                && workspace.HierarchySnapshot.Value is null
                && workspace.AssetCatalogSnapshot.Value is null;
            sessionSwitchObservation = $"project={workspace.ProjectSnapshot.Value?.ProjectName ?? "null"};hierarchy={workspace.HierarchySnapshot.Value?.ProjectName ?? "null"};assets={(workspace.AssetCatalogSnapshot.Value is null ? "null" : "set")}";
        };

        var invalidationCount = 0;
        var snapshotObserversSawAtomicCommit = true;
        void CountInvalidation(object? sender, System.ComponentModel.PropertyChangedEventArgs args)
        {
            if (args.PropertyName != nameof(EditorSnapshotViewModel<ProjectModelSnapshot>.Value)) { return; }
            var valueIsNull = sender switch
            {
                EditorSnapshotViewModel<ProjectModelSnapshot> snapshot => snapshot.Value is null,
                EditorSnapshotViewModel<HierarchySnapshot> snapshot => snapshot.Value is null,
                EditorSnapshotViewModel<AssetCatalogSnapshot> snapshot => snapshot.Value is null,
                _ => false
            };
            if (valueIsNull)
            {
                invalidationCount++;
                // 任一 holder 的通知到达时，权威 Session 与整组 holder 都必须已完成状态提交。
                snapshotObserversSawAtomicCommit &= workspace.Project.Session?.ProjectName == "fresh_project"
                    && workspace.ProjectSnapshot.Value is null
                    && workspace.HierarchySnapshot.Value is null
                    && workspace.AssetCatalogSnapshot.Value is null;
            }
        }
        workspace.ProjectSnapshot.PropertyChanged += CountInvalidation;
        workspace.HierarchySnapshot.PropertyChanged += CountInvalidation;
        workspace.AssetCatalogSnapshot.PropertyChanged += CountInvalidation;

        transport.DelayNextCreateResponse(emitEventBeforeRelease: true);
        var createTask = workspace.CreateProjectAsync(new ProjectCreateParameters("C:/package", "fresh_project"));
        await WaitUntilAsync(() => transport.DelayedCreatePending).ConfigureAwait(false);
        await WaitUntilAsync(() => observedSessionSwitch && invalidationCount == 3).ConfigureAwait(false);

        Assert(observedSessionSwitch && snapshotsWereEmptyBeforeSession,
            $"project_created did not invalidate all old snapshots before switching Session in one dispatcher action: {sessionSwitchObservation}");
        Assert(invalidationCount == 3, "different project identity did not invalidate each snapshot exactly once");
        Assert(snapshotObserversSawAtomicCommit,
            "snapshot observer saw a partial session/snapshot identity transition");

        // 在迟到的成功 response 前放入新 identity 的事件值；response 重放不得再次清空它们。
        await transport.EmitActiveSnapshotEventsAsync().ConfigureAwait(false);
        await WaitUntilAsync(() => workspace.ProjectSnapshot.Value?.ProjectName == "fresh_project"
            && workspace.HierarchySnapshot.Value?.ProjectName == "fresh_project"
            && workspace.AssetCatalogSnapshot.Value is not null).ConfigureAwait(false);
        var invalidationsBeforeResponse = invalidationCount;

        await transport.ReleaseDelayedCreateAsync().ConfigureAwait(false);
        var created = await createTask.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
        Assert(created.ProjectName == "fresh_project", "Workspace project_create returned the wrong Session");
        Assert(invalidationCount == invalidationsBeforeResponse,
            "same-identity success response invalidated snapshots a second time");

        await transport.EmitEventAsync("project_created", created with
        {
            PackageRoot = "c:\\package\\.",
            ProjectName = "FRESH_PROJECT"
        }).ConfigureAwait(false);
        // 后继事件是 read-loop barrier，确保重放 handler 已完整返回后再断言无副作用。
        await transport.EmitEventAsync("project_create_replay_barrier", new { }).ConfigureAwait(false);
        await WaitUntilAsync(() => workspace.LastEventName == "project_create_replay_barrier").ConfigureAwait(false);
        Assert(invalidationCount == invalidationsBeforeResponse
            && workspace.ProjectSnapshot.Value is not null
            && workspace.HierarchySnapshot.Value is not null
            && workspace.AssetCatalogSnapshot.Value is not null,
            "normalized same-identity project_created replay discarded current snapshots");
    }

    private static async Task VerifyProjectCreateBusinessFailureAsync()
    {
        var transport = new ScriptedTransport();
        var client = new EditorRpcClient(transport, "project-create-failure-verifier", "1");
        await using var workspace = new EditorWorkspaceViewModel(client);
        await PrepareOpenedWorkspaceAsync(workspace).ConfigureAwait(false);

        var oldSession = workspace.Project.Session;
        var oldProjectSnapshot = workspace.ProjectSnapshot.Value;
        var oldHierarchySnapshot = workspace.HierarchySnapshot.Value;
        var oldAssetSnapshot = workspace.AssetCatalogSnapshot.Value;
        transport.FailNextCreate("invalid_project_name", "injected create validation failure");

        try
        {
            _ = await workspace.CreateProjectAsync(new ProjectCreateParameters("C:/package", "bad/project")).ConfigureAwait(false);
            throw new InvalidOperationException("injected project_create business failure unexpectedly succeeded");
        }
        catch (EditorRpcException exception) when (exception.Code == "invalid_project_name") { }

        Assert(ReferenceEquals(workspace.Project.Session, oldSession)
            && ReferenceEquals(workspace.ProjectSnapshot.Value, oldProjectSnapshot)
            && ReferenceEquals(workspace.HierarchySnapshot.Value, oldHierarchySnapshot)
            && ReferenceEquals(workspace.AssetCatalogSnapshot.Value, oldAssetSnapshot),
            "pre-commit project_create failure discarded the previous confirmed Session or snapshots");
        Assert(workspace.Project.State == EditorProjectState.Failed
            && workspace.Project.ErrorCode == "invalid_project_name",
            "project_create business failure was not projected structurally");
    }

    private static async Task VerifyProjectCreateConfirmedConnectionFailuresAsync()
    {
        await VerifyProjectCreateConfirmedConnectionFailureAsync(
            "eof",
            "created_before_eof",
            exception => exception is EndOfStreamException).ConfigureAwait(false);
        await VerifyProjectCreateConfirmedConnectionFailureAsync(
            "protocol",
            "created_before_protocol_error",
            exception => exception is EditorRpcException { Code: "event_sequence_violation" }).ConfigureAwait(false);
        await VerifyProjectCreateConfirmedConnectionFailureAsync(
            "transport",
            "created_before_transport_error",
            exception => exception is IOException).ConfigureAwait(false);
    }

    private static async Task VerifyProjectCreateConfirmedConnectionFailureAsync(
        string failureKind,
        string projectName,
        Func<Exception, bool> isExpectedFailure)
    {
        var transport = new ScriptedTransport();
        var client = new EditorRpcClient(transport, $"project-create-{failureKind}-verifier", "1");
        await using var workspace = new EditorWorkspaceViewModel(client);
        await PrepareOpenedWorkspaceAsync(workspace).ConfigureAwait(false);

        var projectedFailure = false;
        workspace.Project.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName == nameof(EditorProjectViewModel.State)
                && workspace.Project.State == EditorProjectState.Failed)
            {
                projectedFailure = true;
            }
        };
        transport.FailNextCreateResponseAfterEvent(failureKind);

        Exception? observed = null;
        try
        {
            _ = await workspace.CreateProjectAsync(
                new ProjectCreateParameters("C:/package", projectName)).WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
        }
        catch (Exception exception) { observed = exception; }

        Assert(observed is not null && isExpectedFailure(observed),
            $"event-first project_create did not preserve the real {failureKind} exception: {observed?.GetType().Name ?? "none"}");
        Assert(workspace.Project.Session?.ProjectName == projectName
            && workspace.Project.State == EditorProjectState.Opened
            && workspace.Project.ErrorCode is null
            && !projectedFailure,
            $"event-first {failureKind} failure claimed the confirmed created Session was rolled back");
        Assert(transport.LastProjectCreateRequest is not null,
            $"event-first {failureKind} scenario did not cross the project_create transport seam");
    }

    private static async Task VerifyProjectCreateCancellationAsync()
    {
        var transport = new ScriptedTransport();
        var client = new EditorRpcClient(transport, "project-create-cancellation-verifier", "1");
        await using var workspace = new EditorWorkspaceViewModel(client);
        await PrepareOpenedWorkspaceAsync(workspace).ConfigureAwait(false);

        var oldSession = workspace.Project.Session;
        var oldProjectSnapshot = workspace.ProjectSnapshot.Value;
        var oldHierarchySnapshot = workspace.HierarchySnapshot.Value;
        var oldAssetSnapshot = workspace.AssetCatalogSnapshot.Value;
        transport.DelayNextCreateResponse(emitEventBeforeRelease: false);
        using var cancellation = new CancellationTokenSource();
        var createTask = workspace.CreateProjectAsync(
            new ProjectCreateParameters("C:/package", "fresh_project"), cancellation.Token);
        await WaitUntilAsync(() => transport.DelayedCreatePending).ConfigureAwait(false);
        cancellation.Cancel();

        try
        {
            _ = await createTask.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
            throw new InvalidOperationException("locally cancelled project_create unexpectedly completed");
        }
        catch (OperationCanceledException) { }

        Assert(workspace.Project.State == EditorProjectState.OutcomeUnknown
            && workspace.Project.ErrorCode == "project_create_outcome_unknown"
            && workspace.Project.ErrorCode != "cancelled",
            "local project_create cancellation was projected as a remote business failure");
        Assert(ReferenceEquals(workspace.Project.Session, oldSession)
            && ReferenceEquals(workspace.ProjectSnapshot.Value, oldProjectSnapshot)
            && ReferenceEquals(workspace.HierarchySnapshot.Value, oldHierarchySnapshot)
            && ReferenceEquals(workspace.AssetCatalogSnapshot.Value, oldAssetSnapshot),
            "outcome-unknown cancellation fabricated a remote Session conclusion");

        await transport.ReleaseDelayedCreateAsync().ConfigureAwait(false);
        await WaitUntilAsync(() => workspace.Project.Session?.ProjectName == "fresh_project"
            && workspace.Project.State == EditorProjectState.Opened).ConfigureAwait(false);
        Assert(workspace.Project.ErrorCode is null
            && workspace.ProjectSnapshot.Value is null
            && workspace.HierarchySnapshot.Value is null
            && workspace.AssetCatalogSnapshot.Value is null,
            "late project_created did not reconcile an outcome-unknown Create");
        _ = await client.GetCapabilitiesAsync().ConfigureAwait(false);

        // 反向竞态：事件先确认成功、随后本地取消 response 等待，不得把 Opened 倒退为 unknown。
        transport.DelayNextCreateResponse(emitEventBeforeRelease: true);
        using var cancellationAfterEvent = new CancellationTokenSource();
        var eventFirstTask = workspace.CreateProjectAsync(
            new ProjectCreateParameters("C:/package", "event_first_project"), cancellationAfterEvent.Token);
        await WaitUntilAsync(() => transport.DelayedCreatePending
            && workspace.Project.Session?.ProjectName == "event_first_project").ConfigureAwait(false);
        cancellationAfterEvent.Cancel();
        try
        {
            _ = await eventFirstTask.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
            throw new InvalidOperationException("event-first project_create cancellation unexpectedly completed");
        }
        catch (OperationCanceledException) { }
        Assert(workspace.Project.State == EditorProjectState.Opened
            && workspace.Project.ErrorCode is null,
            "local cancellation overwrote an already confirmed project_created event");
        await transport.ReleaseDelayedCreateAsync().ConfigureAwait(false);
    }

    private static async Task VerifyProjectCreateSnapshotRecoveryAsync()
    {
        var transport = new ScriptedTransport();
        var client = new EditorRpcClient(transport, "project-create-snapshot-verifier", "1");
        await using var workspace = new EditorWorkspaceViewModel(client);
        await PrepareOpenedWorkspaceAsync(workspace).ConfigureAwait(false);
        transport.FailNextHierarchySnapshot("snapshot_injected", "injected hierarchy refresh failure");

        var created = await workspace.CreateProjectAsync(
            new ProjectCreateParameters("C:/package", "fresh_project")).ConfigureAwait(false);

        Assert(created.ProjectName == "fresh_project"
            && workspace.Project.Session?.ProjectName == "fresh_project"
            && workspace.Project.State == EditorProjectState.Opened,
            "post-commit snapshot failure rolled back the confirmed created Session");
        Assert(workspace.Project.ErrorCode is null
            && workspace.Project.ErrorCode != "project_create_failed",
            "post-commit snapshot failure was projected as project_create failure");
        Assert(workspace.ProjectSnapshot.Value is null
            && workspace.HierarchySnapshot.Value is null
            && workspace.AssetCatalogSnapshot.Value is null,
            "snapshot-group refresh failure retained a mixed-project snapshot set");
        Assert(workspace.ProjectSnapshot.State == EditorSnapshotState.Empty
            && workspace.HierarchySnapshot.State == EditorSnapshotState.Failed
            && workspace.HierarchySnapshot.ErrorCode == "snapshot_injected"
            && workspace.AssetCatalogSnapshot.State == EditorSnapshotState.Empty,
            "snapshot-group refresh failure did not retain one structured failure marker");

        await workspace.RefreshSnapshotsAsync("fresh_project").ConfigureAwait(false);
        Assert(workspace.ProjectSnapshot is { State: EditorSnapshotState.Ready, Value.ProjectName: "fresh_project" }
            && workspace.HierarchySnapshot is { State: EditorSnapshotState.Ready, Value.ProjectName: "fresh_project" }
            && workspace.AssetCatalogSnapshot is { State: EditorSnapshotState.Ready, Value: not null },
            "a later snapshot retry did not recover the created Session projection");
    }

    private static async Task PrepareOpenedWorkspaceAsync(EditorWorkspaceViewModel workspace)
    {
        await workspace.ConnectAsync().ConfigureAwait(false);
        _ = await workspace.OpenProjectAsync(new ProjectOpenParameters("C:/package", "demo")).ConfigureAwait(false);
        await workspace.RefreshSnapshotsAsync("demo").ConfigureAwait(false);
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
        var publicationSnapshot = await client.GetPublicationSnapshotAsync(new PublicationSnapshotQueryParameters(projectName, "debug")).ConfigureAwait(false);
        Assert(projectSnapshot.ModelVersion == 1 && hierarchySnapshot.SnapshotVersion == 1, "real service snapshot version mismatch");
        Assert(projectSnapshot.Scene.SchemaVersion == 3
            && projectSnapshot.Scene.Textures is { Count: 3 }
            && projectSnapshot.Scene.Textures.Any(texture => texture.TextureId == 3)
            && projectSnapshot.Scene.HazardTextureId == 3, "real service scene texture snapshot mismatch");
        Assert(hierarchySnapshot.Nodes.Length == 11, "real service hierarchy snapshot count mismatch");
        Assert(assetSnapshot.CatalogVersion == 1 && assetSnapshot.ItemCount == assetSnapshot.Items.Length, "real service asset snapshot mismatch");
        Assert(projectSnapshot.AuthoringRevision.Length == 64, "real service authoring revision mismatch");
        Assert(publicationSnapshot.SnapshotVersion == EditorSnapshotVersions.Publication, "real service publication snapshot version mismatch");
        Assert(capabilities.Commands.Contains("publication_snapshot"), "real service did not advertise publication_snapshot");
        Console.WriteLine("publication_service_smoke=ok");
        Console.WriteLine("snapshot_service_smoke=ok");
        Assert(capabilities.Commands.Contains("authoring_apply") && capabilities.Commands.Contains("authoring_undo"), "real service did not advertise authoring commands");

        try
        {
            _ = await client.ApplyAuthoringAsync(new AuthoringApplyParameters(projectName, projectSnapshot.AuthoringRevision, new AuthoringPatch(SceneGoalPosition: [1d]))).ConfigureAwait(false);
            throw new InvalidOperationException("invalid authoring patch unexpectedly succeeded");
        }
        catch (EditorRpcException exception) when (exception.Code == "invalid_authoring_patch") { }
        try
        {
            _ = await client.ApplyAuthoringAsync(new AuthoringApplyParameters(projectName, projectSnapshot.AuthoringRevision,
                new AuthoringPatch(ScenePlayerTextureId: 4))).ConfigureAwait(false);
            throw new InvalidOperationException("invalid scene texture patch unexpectedly succeeded");
        }
        catch (EditorRpcException exception) when (exception.Code == "invalid_authoring_patch") { }

        var unchanged = await client.ApplyAuthoringAsync(new AuthoringApplyParameters(projectName, projectSnapshot.AuthoringRevision,
            new AuthoringPatch(SceneGoalPosition: projectSnapshot.Scene.GoalPosition))).ConfigureAwait(false);
        Assert(unchanged.State == "unchanged" && unchanged.UndoDepth == 0, "real service authoring no-op mismatch");

        var updatedGoal = new[] { projectSnapshot.Scene.GoalPosition[0] + 1d, projectSnapshot.Scene.GoalPosition[1] + 1d };
        var updatedPlayerTextureId = projectSnapshot.Scene.PlayerTextureId == 1 ? 2u : 1u;
        var applied = await client.ApplyAuthoringAsync(new AuthoringApplyParameters(projectName, projectSnapshot.AuthoringRevision,
            new AuthoringPatch(SceneGoalPosition: updatedGoal, ScenePlayerTextureId: updatedPlayerTextureId))).ConfigureAwait(false);
        Assert(applied.State == "succeeded"
            && applied.ChangedFields.Contains("scene.goal.position")
            && applied.ChangedFields.Contains("scene.player.textureId")
            && applied.ProjectSnapshot.Scene.PlayerTextureId == updatedPlayerTextureId, "real service authoring apply failed");
        try
        {
            _ = await client.ApplyAuthoringAsync(new AuthoringApplyParameters(projectName, projectSnapshot.AuthoringRevision,
                new AuthoringPatch(SceneGoalPosition: [9d, 9d]))).ConfigureAwait(false);
            throw new InvalidOperationException("stale authoring revision unexpectedly succeeded");
        }
        catch (EditorRpcException exception) when (exception.Code == "authoring_revision_conflict") { }

        var undone = await client.UndoAuthoringAsync(new AuthoringUndoParameters(projectName, applied.Revision)).ConfigureAwait(false);
        Assert(undone.Operation == "undo" && undone.UndoDepth == 0
            && undone.ProjectSnapshot.Scene.PlayerTextureId == projectSnapshot.Scene.PlayerTextureId, "real service authoring undo failed");
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
        Assert(workspace.AssetCatalogSnapshot.Value?.ItemCount == 12, "asset catalog snapshot count mismatch");
        Assert(workspace.Publication.State == EditorPublicationState.Current && workspace.Publication.RecommendedBakeTarget is null, "publication snapshot current state mismatch");

        // 任一侧缺失都代表 pair 不完整，前端必须选择 Both，避免只修复表面上 dirty 的一侧。
        var currentPublication = workspace.Publication.Snapshot ?? throw new InvalidOperationException("publication snapshot missing");
        var oneTargetMissing = currentPublication with
        {
            State = "missing",
            Script = currentPublication.Script with
            {
                State = "missing",
                BakedSourceRevision = null,
                ArtifactRevision = null,
                ManifestArtifactRevision = null,
                ArtifactBytes = null,
                ManifestArtifactBytes = null
            }
        };
        await transport.EmitEventAsync("publication_snapshot_created", oneTargetMissing).ConfigureAwait(false);
        await WaitUntilAsync(() => workspace.Publication.State == EditorPublicationState.Missing);
        Assert(workspace.Publication.RecommendedBakeTarget == "Both", "one missing publication target did not require Both bake");
        await transport.EmitEventAsync("publication_snapshot_created", currentPublication).ConfigureAwait(false);
        await WaitUntilAsync(() => workspace.Publication.State == EditorPublicationState.Current);

        var scriptedRevision = workspace.ProjectSnapshot.Value?.AuthoringRevision ?? throw new InvalidOperationException("scripted revision missing");
        var scriptedApplied = await workspace.ApplyAuthoringAsync(new AuthoringApplyParameters("demo", scriptedRevision, new AuthoringPatch(SceneGoalPosition: [8d, 9d])));
        Assert(workspace.Authoring.State == EditorAuthoringState.Succeeded && scriptedApplied.UndoDepth == 1, "authoring apply state mismatch");
        Assert(workspace.Publication.State == EditorPublicationState.SourceDirty && workspace.Publication.RecommendedBakeTarget == "Scene", "authoring apply did not expose Scene publication dirtiness");
        var incrementalBake = await workspace.BakeChangesAsync("debug");
        Assert(incrementalBake?.Target == "Scene" && workspace.Publication.State == EditorPublicationState.Current, "Bake Changes did not select the minimum Scene target");
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
        Assert(workspace.Bake.SceneArtifactBytes == 258, "scene artifact bytes were not retained");
        var lastSuccessfulRevision = workspace.Bake.SceneArtifactRevision;

        var watched = await workspace.StartWatchAsync(new WatchStartParameters("Scene", "debug", 50, 100));
        Assert(watched.State == "watching" && workspace.Watch.State == EditorWatchState.Watching, "watch state mismatch");
        await transport.EmitEventAsync("source_change_detected", new { target = "scene", revision = "ABC" });
        await WaitUntilAsync(() => workspace.Watch.LastSourceRevision == "ABC");
        try
        {
            _ = await workspace.BakeChangesAsync("debug");
            throw new InvalidOperationException("manual Bake Changes unexpectedly bypassed watch ownership");
        }
        catch (EditorRpcException exception) when (exception.Code == "publication_watch_owns_bake") { }

        await transport.EmitEventAsync("bake_failed", new { target = "scene", errorCode = "bake_validation_failed", message = "invalid json", retainedArtifact = true });
        await WaitUntilAsync(() => workspace.Bake.State == EditorBakeState.Failed);
        Assert(workspace.Bake.RetainedPreviousArtifact, "failed bake did not advertise retained artifact");
        Assert(workspace.Bake.LastSuccessfulResult?.SceneArtifactRevision == lastSuccessfulRevision, "failed bake discarded last successful artifact");

        // 先释放 Service watch，再验证 Preview live-bake/watch 成为唯一 derived writer。
        await workspace.StopWatchAsync();
        Assert(workspace.Watch.State == EditorWatchState.Stopped, "watch did not stop before live Preview ownership test");

        var preview = await workspace.StartPreviewAsync(new PreviewStartParameters(ProjectName: "demo"));
        Assert(preview.SurfaceMode == PreviewSurfaceModes.ExternalWindow, "preview result surface mode mismatch");
        await WaitUntilAsync(() => workspace.Preview.State == EditorPreviewState.Running);
        Assert(workspace.Preview.Surface?.WindowClass == "KadathRuntimeWindow", "preview surface descriptor mismatch");
        Assert(workspace.Preview.RuntimeProcessId == 1234, "runtime PID status was not parsed");

        var initialSceneSource = new string('a', 64);
        var initialSceneArtifact = new string('b', 64);
        var initialScriptSource = new string('c', 64);
        var initialScriptArtifact = new string('d', 64);
        var initialPublication = currentPublication with
        {
            State = "current",
            Scene = currentPublication.Scene with
            {
                State = "current",
                SourceRevision = initialSceneSource,
                BakedSourceRevision = initialSceneSource,
                ArtifactRevision = initialSceneArtifact,
                ManifestArtifactRevision = initialSceneArtifact,
                ArtifactBytes = 128,
                ManifestArtifactBytes = 128
            },
            Script = currentPublication.Script with
            {
                State = "current",
                SourceRevision = initialScriptSource,
                BakedSourceRevision = initialScriptSource,
                ArtifactRevision = initialScriptArtifact,
                ManifestArtifactRevision = initialScriptArtifact,
                ArtifactBytes = 48,
                ManifestArtifactBytes = 48
            }
        };
        await transport.EmitEventAsync("publication_snapshot_created", initialPublication).ConfigureAwait(false);
        await transport.EmitEventAsync("preview_initial_loaded", new PreviewInitialLoadedNotification(
            1, "loaded",
            new PreviewLoadedTargetIdentity("Scene", "artifact", "manifest_matched", initialSceneSource, initialSceneArtifact, 128),
            new PreviewLoadedTargetIdentity("Script", "artifact", "manifest_matched", initialScriptSource, initialScriptArtifact, 48),
            "debug")).ConfigureAwait(false);
        await WaitUntilAsync(() => workspace.Preview.Runtime.State == EditorPreviewRuntimeState.Loaded);
        Assert(workspace.Preview.Runtime.Scene.Origin == EditorPreviewRuntimeOrigin.Initial
            && workspace.Preview.Runtime.Scene.Consistency == EditorPreviewRuntimeConsistency.Current
            && workspace.Preview.Runtime.Script.Origin == EditorPreviewRuntimeOrigin.Initial
            && workspace.Preview.Runtime.Script.Consistency == EditorPreviewRuntimeConsistency.Current,
            "initial Runtime identity was not atomically projected against publication");

        // publication 只能对账，source 变脏不能覆盖 Runtime 已加载的权威身份。
        var dirtyPublication = initialPublication with
        {
            State = "source_dirty",
            Scene = initialPublication.Scene with { State = "source_dirty", SourceRevision = new string('e', 64) }
        };
        await transport.EmitEventAsync("publication_snapshot_created", dirtyPublication).ConfigureAwait(false);
        await WaitUntilAsync(() => workspace.Preview.Runtime.Scene.Consistency == EditorPreviewRuntimeConsistency.SourceDirty);
        Assert(workspace.Preview.Runtime.Scene.SourceRevision == initialSceneSource
            && workspace.Preview.Runtime.Scene.ArtifactRevision == initialSceneArtifact,
            "publication dirtiness overwrote Runtime loaded identity");
        await transport.EmitEventAsync("publication_snapshot_created", initialPublication).ConfigureAwait(false);
        await WaitUntilAsync(() => workspace.Preview.Runtime.Scene.Consistency == EditorPreviewRuntimeConsistency.Current);

        // 同一生命周期的重复 initial 必须忽略，避免迟到事件把 reload 或首次身份倒退。
        await transport.EmitEventAsync("preview_initial_loaded", new PreviewInitialLoadedNotification(
            1, "loaded",
            new PreviewLoadedTargetIdentity("Scene", "artifact", "artifact_mismatch", null, new string('f', 64), 128),
            new PreviewLoadedTargetIdentity("Script", "built_in", "built_in"))).ConfigureAwait(false);
        await Task.Delay(20).ConfigureAwait(false);
        Assert(workspace.Preview.Runtime.Scene.ArtifactRevision == initialSceneArtifact
            && workspace.Preview.Runtime.Script.ArtifactRevision == initialScriptArtifact,
            "duplicate initial event replaced authoritative Runtime identity");

        var sceneSourceA = new string('A', 64);
        var sceneArtifactA = new string('B', 64);
        var sceneSourceB = new string('C', 64);
        var sceneArtifactB = new string('D', 64);
        await transport.EmitEventAsync("preview_reload_requested", new PreviewReloadNotification(
            1, "requested", "Scene", 41, "live_bake",
            SourceRevision: sceneSourceA, ArtifactRevision: sceneArtifactA, ArtifactBytes: 128,
            LatestRequestedSourceRevision: sceneSourceA));
        await transport.EmitEventAsync("preview_reload_requested", new PreviewReloadNotification(
            1, "requested", "Scene", 42, "live_bake",
            SourceRevision: sceneSourceB, ArtifactRevision: sceneArtifactB, ArtifactBytes: 128,
            LatestRequestedSourceRevision: sceneSourceB));
        await transport.EmitEventAsync("preview_reload_stale", new PreviewReloadNotification(
            1, "stale", "Scene", 41, "live_bake",
            SourceRevision: sceneSourceA, ArtifactRevision: sceneArtifactA, ArtifactBytes: 128,
            LatestRequestedSourceRevision: sceneSourceB, Result: "succeeded", Ignored: true));
        await transport.EmitEventAsync("preview_reload_acknowledged", new PreviewReloadNotification(
            1, "acknowledged", "Scene", 42, "live_bake",
            SourceRevision: sceneSourceB, ArtifactRevision: sceneArtifactB, ArtifactBytes: 128,
            LatestRequestedSourceRevision: sceneSourceB,
            AcknowledgedSourceRevision: sceneSourceB,
            AcknowledgedArtifactRevision: sceneArtifactB,
            Result: "succeeded"));

        var retainedScriptSource = new string('E', 64);
        var failedScriptSource = new string('F', 64);
        await transport.EmitEventAsync("preview_reload_requested", new PreviewReloadNotification(
            1, "requested", "Script", 43, "file_change",
            SourceRevision: failedScriptSource,
            LatestRequestedSourceRevision: failedScriptSource,
            AcknowledgedSourceRevision: retainedScriptSource));
        await transport.EmitEventAsync("preview_reload_failed", new PreviewReloadNotification(
            1, "failed", "Script", 43, "file_change",
            SourceRevision: failedScriptSource,
            LatestRequestedSourceRevision: failedScriptSource,
            AcknowledgedSourceRevision: retainedScriptSource,
            FailedSourceRevision: failedScriptSource,
            Result: "rejected",
            ErrorCode: "UnsupportedScriptSchema"));
        await WaitUntilAsync(() => workspace.Preview.Reload.Scene.State == EditorPreviewReloadState.Acknowledged
            && workspace.Preview.Reload.Script.State == EditorPreviewReloadState.Failed);
        Assert(workspace.Preview.Reload.Scene.LatestRequestId == 42
            && workspace.Preview.Reload.Scene.AcknowledgedSourceRevision == sceneSourceB
            && workspace.Preview.Reload.Scene.AcknowledgedArtifactRevision == sceneArtifactB,
            "latest Scene reload acknowledgement was not retained.");
        Assert(workspace.Preview.Reload.Scene.StaleResponseCount == 1
            && workspace.Preview.Reload.Scene.LastStaleRequestId == 41,
            "stale Scene completion was not ignored.");
        Assert(workspace.Preview.Reload.Script.AcknowledgedSourceRevision == retainedScriptSource
            && workspace.Preview.Reload.Script.FailedSourceRevision == failedScriptSource
            && workspace.Preview.Reload.Script.ErrorCode == "UnsupportedScriptSchema",
            "failed Script reload did not retain the last acknowledged revision.");
        Assert(workspace.Preview.Runtime.Scene.Origin == EditorPreviewRuntimeOrigin.Reload
            && workspace.Preview.Runtime.Scene.SourceRevision == sceneSourceB
            && workspace.Preview.Runtime.Scene.ArtifactRevision == sceneArtifactB,
            "acknowledged Scene reload did not advance Runtime loaded identity");
        Assert(workspace.Preview.Runtime.Script.Origin == EditorPreviewRuntimeOrigin.Initial
            && workspace.Preview.Runtime.Script.SourceRevision == initialScriptSource
            && workspace.Preview.Runtime.Script.ArtifactRevision == initialScriptArtifact,
            "failed Script reload replaced the retained Runtime identity");
        await transport.EmitEventAsync("preview_initial_load_failed", new PreviewInitialLoadFailedNotification(
            1, "failed", "late_initial_failure", "must be ignored after reload ack")).ConfigureAwait(false);
        await Task.Delay(20).ConfigureAwait(false);
        Assert(workspace.Preview.Runtime.State == EditorPreviewRuntimeState.Loaded
            && workspace.Preview.Runtime.Scene.Origin == EditorPreviewRuntimeOrigin.Reload,
            "late initial failure rolled back acknowledged Runtime identity");

        await workspace.StopPreviewAsync();
        Assert(workspace.Preview.State == EditorPreviewState.Stopped, "preview did not stop");

        var livePreview = await workspace.StartPreviewAsync(new PreviewStartParameters(ProjectName: "demo", LiveBake: true, WatchChanges: true));
        Assert(livePreview.SurfaceMode == PreviewSurfaceModes.ExternalWindow && workspace.Preview.OwnsPublicationSync,
            "live Preview did not claim publication ownership");
        Assert(workspace.Preview.Runtime.State == EditorPreviewRuntimeState.Unknown
            && workspace.Preview.Runtime.Scene.Origin == EditorPreviewRuntimeOrigin.None
            && workspace.Preview.Runtime.Script.Origin == EditorPreviewRuntimeOrigin.None,
            "Preview restart did not reset Runtime loaded identity");
        await transport.EmitEventAsync("preview_initial_load_failed", new PreviewInitialLoadFailedNotification(
            1, "failed", "FileNotFound", "scene artifact missing")).ConfigureAwait(false);
        await WaitUntilAsync(() => workspace.Preview.Runtime.State == EditorPreviewRuntimeState.Failed);
        Assert(workspace.Preview.Runtime.ErrorCode == "FileNotFound"
            && workspace.Preview.Runtime.Scene.Origin == EditorPreviewRuntimeOrigin.None,
            "initial load failure did not retain the empty restart state");
        await transport.EmitEventAsync("preview_initial_loaded", new PreviewInitialLoadedNotification(
            1, "loaded",
            new PreviewLoadedTargetIdentity("Scene", "built_in", "built_in"),
            new PreviewLoadedTargetIdentity("Script", "built_in", "built_in"))).ConfigureAwait(false);
        await Task.Delay(20).ConfigureAwait(false);
        Assert(workspace.Preview.Runtime.State == EditorPreviewRuntimeState.Failed
            && workspace.Preview.Runtime.ErrorCode == "FileNotFound",
            "duplicate initial terminal event replaced the first failure");
        transport.FailNextPreviewStop();
        try
        {
            _ = await workspace.StopPreviewAsync();
            throw new InvalidOperationException("injected Preview stop failure unexpectedly succeeded");
        }
        catch (EditorRpcException exception) when (exception.Code == "preview_stop_failed") { }
        Assert(workspace.Preview.State == EditorPreviewState.Failed && workspace.Preview.OwnsPublicationSync,
            "Preview publication ownership was released after an unconfirmed stop");
        try
        {
            _ = await workspace.BakeChangesAsync("debug");
            throw new InvalidOperationException("manual bake bypassed failed Preview ownership");
        }
        catch (EditorRpcException exception) when (exception.Code == "publication_preview_owns_bake") { }
        await workspace.StopPreviewAsync();
        Assert(workspace.Preview.State == EditorPreviewState.Stopped && !workspace.Preview.OwnsPublicationSync,
            "Preview ownership was not released after confirmed stop");

        _ = await workspace.StartPreviewAsync(new PreviewStartParameters(ProjectName: "demo"));
        await transport.EmitEventAsync("preview_initial_loaded", new PreviewInitialLoadedNotification(
            1, "loaded",
            new PreviewLoadedTargetIdentity("Scene", "artifact", "manifest_matched", initialSceneSource, initialSceneArtifact, 128),
            new PreviewLoadedTargetIdentity("Script", "artifact", "manifest_matched", initialScriptSource, initialScriptArtifact, 48),
            "debug")).ConfigureAwait(false);
        await WaitUntilAsync(() => workspace.Preview.Runtime.State == EditorPreviewRuntimeState.Loaded);
        Assert(workspace.Preview.Runtime.Scene.Consistency == EditorPreviewRuntimeConsistency.Current
            && workspace.Preview.Runtime.Script.Consistency == EditorPreviewRuntimeConsistency.Current,
            "Preview restart lost the existing Publication snapshot before initial reconciliation");
        await workspace.StopPreviewAsync();

        _ = await workspace.StartPreviewAsync(new PreviewStartParameters(ProjectName: "demo"));
        var mismatchedArtifact = new string('9', 64);
        await transport.EmitEventAsync("preview_initial_loaded", new PreviewInitialLoadedNotification(
            1, "loaded",
            new PreviewLoadedTargetIdentity("Scene", "artifact", "artifact_mismatch", null, mismatchedArtifact, 128),
            new PreviewLoadedTargetIdentity("Script", "built_in", "built_in"))).ConfigureAwait(false);
        await WaitUntilAsync(() => workspace.Preview.Runtime.State == EditorPreviewRuntimeState.Loaded);
        Assert(workspace.Preview.Runtime.Scene.ArtifactRevision == mismatchedArtifact
            && workspace.Preview.Runtime.Scene.SourceRevision is null
            && workspace.Preview.Runtime.Scene.Consistency == EditorPreviewRuntimeConsistency.ArtifactMismatch,
            "manifest mismatch did not retain Runtime artifact facts and mismatch projection");
        Assert(workspace.Preview.Runtime.Script.Kind == "built_in"
            && workspace.Preview.Runtime.Script.ArtifactRevision is null
            && workspace.Preview.Runtime.Script.ArtifactBytes is null,
            "built-in target fabricated digest or byte identity");
        await workspace.StopPreviewAsync();

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
    private const string InjectedTransportFailureLine = "\0injected_transport_read_failure";
    private readonly Channel<string> _toClient = Channel.CreateUnbounded<string>();
    private readonly Channel<string> _toServer = Channel.CreateUnbounded<string>();
    private readonly CancellationTokenSource _stop = new();
    private long _sequence;
    private bool _started;
    private int _disposed;
    private bool _delayNextValidation;
    private bool _delayNextCreate;
    private string? _delayNextOperation;
    private string? _failNextMethod;
    private string _nextMethodErrorCode = "operation_failed";
    private string _nextMethodErrorMessage = "injected operation failure";
    private bool _emitCreateEventBeforeRelease;
    private bool _failNextCreate;
    private string? _nextCreateResponseFailure;
    private bool _failNextHierarchySnapshot;
    private string _nextCreateErrorCode = "project_create_failed";
    private string _nextCreateErrorMessage = "injected project create failure";
    private string _nextHierarchyErrorCode = "snapshot_failed";
    private string _nextHierarchyErrorMessage = "injected hierarchy snapshot failure";
    private string _activePackageRoot = "C:/package";
    private string _activeProjectName = "demo";
    private bool _publicationDirty;
    private bool _failNextPreviewStop;
    private readonly bool _advertiseProjectCreate;
    private TaskCompletionSource<bool>? _delayedValidationRelease;
    private TaskCompletionSource<bool>? _delayedValidationCompleted;
    private TaskCompletionSource<bool>? _delayedCreateRelease;
    private TaskCompletionSource<bool>? _delayedCreateCompleted;
    private TaskCompletionSource<bool>? _delayedOperationRelease;
    private TaskCompletionSource<bool>? _delayedOperationCompleted;

    public ScriptedTransport(bool advertiseProjectCreate = true) => _advertiseProjectCreate = advertiseProjectCreate;

    public bool IsOpen => _started && !_stop.IsCancellationRequested;
    public bool DelayedValidationPending => _delayedValidationRelease is not null;
    public bool DelayedCreatePending => _delayedCreateRelease is not null;
    public bool DelayedOperationPending => _delayedOperationRelease is not null;
    public JsonElement? LastProjectCreateRequest { get; private set; }

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
        try
        {
            var line = await _toClient.Reader.ReadAsync(cancellationToken).ConfigureAwait(false);
            if (line == InjectedTransportFailureLine)
            {
                throw new IOException("Injected scripted transport read failure.");
            }
            return line;
        }
        catch (ChannelClosedException) { return null; }
        catch (OperationCanceledException) { return null; }
    }

    private async Task RespondToRequestAsync(JsonElement request)
    {
        var id = request.GetProperty("id").GetString() ?? "";
        var method = request.GetProperty("method").GetString() ?? "";
        if (string.Equals(method, _failNextMethod, StringComparison.Ordinal))
        {
            _failNextMethod = null;
            await SendErrorAsync(id, _nextMethodErrorCode, _nextMethodErrorMessage).ConfigureAwait(false);
            return;
        }
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
                // 记录跨 transport seam 的原始 envelope，验证 typed Client 没有夹带额外参数。
                LastProjectCreateRequest = request.Clone();
                if (_failNextCreate)
                {
                    _failNextCreate = false;
                    await SendErrorAsync(id, _nextCreateErrorCode, _nextCreateErrorMessage).ConfigureAwait(false);
                    break;
                }
                var created = NewCreatedSession(request);
                if (_nextCreateResponseFailure is { } responseFailure)
                {
                    _nextCreateResponseFailure = null;
                    await CommitCreatedSessionAsync(created, id).ConfigureAwait(false);
                    // FIFO 保证 project_created handler 完整返回后，read loop 才观察终止异常。
                    await FailCreateResponseAsync(responseFailure).ConfigureAwait(false);
                    break;
                }
                if (_delayNextCreate)
                {
                    _delayNextCreate = false;
                    _delayedCreateRelease = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
                    _delayedCreateCompleted = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
                    _ = CompleteDelayedCreateAsync(
                        id,
                        created,
                        _emitCreateEventBeforeRelease,
                        _delayedCreateRelease.Task,
                        _delayedCreateCompleted);
                    break;
                }
                await CommitCreatedSessionAsync(created, id).ConfigureAwait(false);
                await SendResponseAsync(id, created).ConfigureAwait(false);
                break;
            case "project_open":
                var opened = new ProjectSessionInfo("C:/package", "demo", "C:/package/bin/projects/demo", "C:/package/bin/projects/demo/scene.json", "C:/package/bin/projects/demo/script.json", "C:/package/bin/projects/demo/preview.json", 1);
                _activePackageRoot = opened.PackageRoot;
                _activeProjectName = opened.ProjectName;
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
                var projectSnapshot = NewProjectSnapshot(_activeProjectName, _activePackageRoot);
                await EmitEventAsync("project_snapshot_created", projectSnapshot, id).ConfigureAwait(false);
                await SendResponseAsync(id, projectSnapshot).ConfigureAwait(false);
                break;
            case "hierarchy_snapshot":
                if (_failNextHierarchySnapshot)
                {
                    _failNextHierarchySnapshot = false;
                    await SendErrorAsync(id, _nextHierarchyErrorCode, _nextHierarchyErrorMessage).ConfigureAwait(false);
                    break;
                }
                var hierarchySnapshot = NewHierarchySnapshot(_activeProjectName);
                await EmitEventAsync("hierarchy_snapshot_created", hierarchySnapshot, id).ConfigureAwait(false);
                await SendResponseAsync(id, hierarchySnapshot).ConfigureAwait(false);
                break;
            case "asset_catalog_snapshot":
                var assetSnapshot = NewAssetCatalogSnapshot();
                await EmitEventAsync("asset_catalog_snapshot_created", assetSnapshot, id).ConfigureAwait(false);
                await SendResponseAsync(id, assetSnapshot).ConfigureAwait(false);
                break;
            case "authoring_apply":
                _publicationDirty = true;
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
                break;
            case "publication_snapshot":
                var publication = NewPublicationSnapshot(_publicationDirty, _activeProjectName, _activePackageRoot);
                await EmitEventAsync("publication_snapshot_created", publication, id).ConfigureAwait(false);
                await SendResponseAsync(id, publication).ConfigureAwait(false);
                break;
            case "bake_start":
                var bakeParameters = request.GetProperty("params");
                var bakeTarget = bakeParameters.GetProperty("target").GetString() ?? "Both";
                var bakeProfile = bakeParameters.GetProperty("profile").GetString() ?? "debug";
                await EmitEventAsync("bake_started", new { target = bakeTarget, profile = bakeProfile }, id).ConfigureAwait(false);
                _publicationDirty = false;
                var bake = NewBakeResult(bakeTarget, bakeProfile);
                await EmitEventAsync("bake_completed", bake, id).ConfigureAwait(false);
                await SendResponseAsync(id, bake).ConfigureAwait(false);
                break;
            case "watch_start":
                var watch = new EditorWatchResult("watching", "demo", "Scene", "debug", NewBakeResult());
                if (DelayOperationIfRequested(method, async () =>
                {
                    await EmitEventAsync("watch_started", watch, id).ConfigureAwait(false);
                    await SendResponseAsync(id, watch).ConfigureAwait(false);
                })) { break; }
                await EmitEventAsync("watch_started", watch, id).ConfigureAwait(false);
                await SendResponseAsync(id, watch).ConfigureAwait(false);
                break;
            case "watch_stop":
                var watchStopped = new EditorWatchResult("stopped", "demo", "Scene", "debug", null);
                if (DelayOperationIfRequested(method, async () =>
                {
                    await EmitEventAsync("watch_stopped", watchStopped, id).ConfigureAwait(false);
                    await SendResponseAsync(id, watchStopped).ConfigureAwait(false);
                })) { break; }
                await EmitEventAsync("watch_stopped", watchStopped, id).ConfigureAwait(false);
                await SendResponseAsync(id, watchStopped).ConfigureAwait(false);
                break;
            case "preview_start":
                var surface = new PreviewSurfaceDescriptor(PreviewSurfaceModes.ExternalWindow, "native-window", 1234, "KadathRuntimeWindow", null, null, null, null);
                if (DelayOperationIfRequested(method, async () =>
                {
                    await EmitEventAsync("preview_surface_created", surface).ConfigureAwait(false);
                    await EmitEventAsync("preview_status", new { @event = "launcher_status", name = "runtime_pid", value = 1234 }).ConfigureAwait(false);
                    await SendResponseAsync(id, new PreviewStartResult("starting", PreviewSurfaceModes.ExternalWindow)).ConfigureAwait(false);
                })) { break; }
                await EmitEventAsync("preview_surface_created", surface).ConfigureAwait(false);
                await EmitEventAsync("preview_status", new { @event = "launcher_status", name = "runtime_pid", value = 1234 }).ConfigureAwait(false);
                await SendResponseAsync(id, new PreviewStartResult("starting", PreviewSurfaceModes.ExternalWindow)).ConfigureAwait(false);
                break;
            case "preview_stop":
                if (_failNextPreviewStop)
                {
                    _failNextPreviewStop = false;
                    await SendErrorAsync(id, "preview_stop_failed", "injected preview stop failure").ConfigureAwait(false);
                    break;
                }
                if (DelayOperationIfRequested(method, async () =>
                {
                    await EmitEventAsync("preview_stopped", new { exitCode = 0, requested = true }).ConfigureAwait(false);
                    await SendResponseAsync(id, new PreviewStopResult("stopped")).ConfigureAwait(false);
                })) { break; }
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

    public void DelayNextOperationResponse(string method)
    {
        if (_delayNextOperation is not null || _delayedOperationRelease is not null)
        {
            throw new InvalidOperationException("A delayed operation is already configured.");
        }
        _delayNextOperation = method;
    }

    public void FailNextRequest(string method, string code, string message)
    {
        _failNextMethod = method;
        _nextMethodErrorCode = code;
        _nextMethodErrorMessage = message;
    }

    public void DelayNextCreateResponse(bool emitEventBeforeRelease)
    {
        _delayNextCreate = true;
        _emitCreateEventBeforeRelease = emitEventBeforeRelease;
    }

    public void FailNextCreate(string code, string message)
    {
        _failNextCreate = true;
        _nextCreateErrorCode = code;
        _nextCreateErrorMessage = message;
    }

    public void FailNextCreateResponseAfterEvent(string failureKind)
    {
        if (failureKind is not ("eof" or "protocol" or "transport"))
        {
            throw new ArgumentOutOfRangeException(nameof(failureKind), failureKind, "Unknown scripted create response failure.");
        }
        _nextCreateResponseFailure = failureKind;
    }

    public void FailNextHierarchySnapshot(string code, string message)
    {
        _failNextHierarchySnapshot = true;
        _nextHierarchyErrorCode = code;
        _nextHierarchyErrorMessage = message;
    }

    public void FailNextPreviewStop() => _failNextPreviewStop = true;

    private string[] CreateCommands()
    {
        var commands = new List<string>
        {
            "project_open", "project_validate", "project_snapshot", "hierarchy_snapshot", "asset_catalog_snapshot",
            "publication_snapshot", "authoring_apply", "authoring_undo", "bake_start", "watch_start", "watch_stop",
            "preview_start", "preview_stop", "shutdown"
        };
        if (_advertiseProjectCreate) { commands.Insert(1, "project_create"); }
        return commands.ToArray();
    }

    public async Task ReleaseDelayedValidationAsync()
    {
        var release = _delayedValidationRelease ?? throw new InvalidOperationException("No delayed validation is pending.");
        var completed = _delayedValidationCompleted ?? throw new InvalidOperationException("Delayed validation completion is missing.");
        release.TrySetResult(true);
        await completed.Task.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
        _delayedValidationRelease = null;
        _delayedValidationCompleted = null;
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

    public async Task ReleaseDelayedOperationAsync()
    {
        var release = _delayedOperationRelease ?? throw new InvalidOperationException("No delayed operation is pending.");
        var completed = _delayedOperationCompleted ?? throw new InvalidOperationException("Delayed operation completion is missing.");
        release.TrySetResult(true);
        await completed.Task.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
        _delayedOperationRelease = null;
        _delayedOperationCompleted = null;
    }

    public async Task EmitActiveSnapshotEventsAsync()
    {
        // 只经公开 event envelope 注入状态，避免 verifier 依赖 ViewModel 内部方法。
        await EmitEventAsync("project_snapshot_created", NewProjectSnapshot(_activeProjectName, _activePackageRoot)).ConfigureAwait(false);
        await EmitEventAsync("hierarchy_snapshot_created", NewHierarchySnapshot(_activeProjectName)).ConfigureAwait(false);
        await EmitEventAsync("asset_catalog_snapshot_created", NewAssetCatalogSnapshot()).ConfigureAwait(false);
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

    private bool DelayOperationIfRequested(string method, Func<Task> complete)
    {
        if (!string.Equals(_delayNextOperation, method, StringComparison.Ordinal)) { return false; }
        _delayNextOperation = null;
        _delayedOperationRelease = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        _delayedOperationCompleted = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        // SendLineAsync 必须及时返回；真实 Client 才能在 response 未到时观察 Starting/Stopping。
        _ = CompleteDelayedOperationAsync(complete, _delayedOperationRelease.Task, _delayedOperationCompleted);
        return true;
    }

    private static async Task CompleteDelayedOperationAsync(
        Func<Task> complete,
        Task release,
        TaskCompletionSource<bool> completed)
    {
        try
        {
            await release.ConfigureAwait(false);
            await complete().ConfigureAwait(false);
        }
        finally { completed.TrySetResult(true); }
    }

    private async Task CompleteDelayedCreateAsync(
        string id,
        ProjectSessionInfo session,
        bool emitEventBeforeRelease,
        Task release,
        TaskCompletionSource<bool> completed)
    {
        try
        {
            if (emitEventBeforeRelease)
            {
                await CommitCreatedSessionAsync(session, id).ConfigureAwait(false);
            }
            await release.ConfigureAwait(false);
            if (!emitEventBeforeRelease)
            {
                await CommitCreatedSessionAsync(session, id).ConfigureAwait(false);
            }
            await SendResponseAsync(id, session).ConfigureAwait(false);
        }
        finally { completed.TrySetResult(true); }
    }

    private async Task CommitCreatedSessionAsync(ProjectSessionInfo session, string? requestId)
    {
        _activePackageRoot = session.PackageRoot;
        _activeProjectName = session.ProjectName;
        await EmitEventAsync("project_created", session, requestId).ConfigureAwait(false);
    }

    private async Task FailCreateResponseAsync(string failureKind)
    {
        switch (failureKind)
        {
            case "eof":
                CompleteServerOutput();
                break;
            case "protocol":
                await EmitRawEventAsync(Interlocked.Read(ref _sequence)).ConfigureAwait(false);
                break;
            case "transport":
                await _toClient.Writer.WriteAsync(InjectedTransportFailureLine).ConfigureAwait(false);
                break;
        }
    }

    private static ProjectSessionInfo NewCreatedSession(JsonElement request)
    {
        var parameters = request.GetProperty("params");
        var packageRoot = (parameters.GetProperty("packageRoot").GetString() ?? "C:/package").TrimEnd('/', '\\');
        var projectName = parameters.GetProperty("projectName").GetString() ?? "fresh_project";
        var projectDirectory = $"{packageRoot}/bin/projects/{projectName}";
        return new ProjectSessionInfo(
            packageRoot,
            projectName,
            projectDirectory,
            $"{projectDirectory}/scene.json",
            $"{projectDirectory}/script.json",
            $"{projectDirectory}/preview.json",
            1);
    }

    private static ProjectModelSnapshot NewProjectSnapshot(string projectName = "demo", string packageRoot = "C:/package") => new(
        1,
        projectName,
        "0000000000000000000000000000000000000000000000000000000000000001",
        new ProjectModelFiles(
            $"{packageRoot}/bin/projects/{projectName}",
            $"{packageRoot}/bin/projects/{projectName}/scene.json",
            $"{packageRoot}/bin/projects/{projectName}/script.json",
            $"{packageRoot}/bin/projects/{projectName}/preview.json"),
        new ProjectModelScene(3, [3d, 4d], 1, 2, 3, [new ProjectModelTexture(1, "assets/renderer2d/test.texture"), new ProjectModelTexture(2, "assets/renderer2d/goal.texture"), new ProjectModelTexture(3, "assets/renderer2d/goal.texture")]),
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
    private static HierarchySnapshot NewHierarchySnapshot(string projectName = "demo") => new(
        1,
        1,
        projectName,
        [
            new HierarchyNode("scene", null, "Scene", "SceneDocument", Props(("SchemaVersion", 3), ("TextureCount", 3))),
            new HierarchyNode("scene.textures[1]", "scene", "Texture 1", "TextureReference", Props(("TextureId", 1), ("Artifact", "assets/renderer2d/test.texture"))),
            new HierarchyNode("scene.textures[2]", "scene", "Texture 2", "TextureReference", Props(("TextureId", 2), ("Artifact", "assets/renderer2d/goal.texture"))),
            new HierarchyNode("scene.textures[3]", "scene", "Texture 3", "TextureReference", Props(("TextureId", 3), ("Artifact", "assets/renderer2d/goal.texture"))),
            new HierarchyNode("scene.player", "scene", "Player", "Sprite", Props(("Position", "0, 0"), ("TextureId", 1))),
            new HierarchyNode("scene.goal", "scene", "Goal", "Sprite", Props(("Position", "3, 4"), ("TextureId", 2))),
            new HierarchyNode("scene.hazard", "scene", "Hazard", "Sprite", Props(("Position", "5, 6"), ("TextureId", 3))),
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
            "assets/renderer2d/goal.png", "assets/renderer2d/goal.texture",
            "assets/renderer2d/test.png", "assets/renderer2d/test.texture",
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

    private static PublicationSnapshot NewPublicationSnapshot(
        bool sourceDirty,
        string projectName = "demo",
        string packageRoot = "C:/package")
    {
        const string source = "0000000000000000000000000000000000000000000000000000000000000001";
        const string artifact = "0000000000000000000000000000000000000000000000000000000000000002";
        var scene = new PublicationTargetSnapshot("Scene", sourceDirty ? "source_dirty" : "current", sourceDirty ? new string('3', 64) : source, source, artifact, artifact, 128, 128);
        var script = new PublicationTargetSnapshot("Script", "current", source, source, artifact, artifact, 96, 96);
        return new PublicationSnapshot(
            EditorSnapshotVersions.Publication,
            projectName,
            "debug",
            "debug",
            $"{packageRoot}/bin/projects/{projectName}/.kadath/derived",
            $"{packageRoot}/bin/projects/{projectName}/.kadath/derived/.live-bake.manifest.json",
            sourceDirty ? "source_dirty" : "current",
            true,
            scene,
            script);
    }

    private static Dictionary<string, JsonElement> Props(params (string Key, object Value)[] values) =>
        values.ToDictionary(value => value.Key, value => JsonSerializer.SerializeToElement(value.Value, EditorProtocol.JsonOptions), StringComparer.Ordinal);
    private static EditorBakeResult NewBakeResult(string target = "Both", string profile = "debug") => new(
        "succeeded", target, profile, "C:/package/bin/projects/demo/.kadath/derived", "C:/package/bin/projects/demo/.kadath/derived/.live-bake.manifest.json",
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
