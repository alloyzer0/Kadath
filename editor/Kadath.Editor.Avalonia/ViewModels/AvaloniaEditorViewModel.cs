using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Text.Json;
using System.Windows.Input;
using Kadath.Editor.Avalonia.Client;
using Kadath.Editor.Client;
using Kadath.Editor.Protocol;
using Kadath.Editor.ViewModels;

namespace Kadath.Editor.Avalonia.ViewModels;

/// <summary>
/// Avalonia 只做展示层组合：领域状态由共享 EditorWorkspaceViewModel 持有，
/// 本适配器负责将其转为按钮、选择框和日志列表需要的绑定属性。
/// </summary>
public sealed class AvaloniaEditorViewModel : ObservableObject, IAsyncDisposable
{
    private readonly EditorWorkspaceViewModel _workspace;
    private readonly IEditorViewDispatcher _dispatcher;
    private readonly List<AsyncUiCommand> _commands = [];
    private readonly Dictionary<string, HierarchyNode> _hierarchyItemsByLabel = new(StringComparer.Ordinal);
    private readonly Dictionary<string, AssetCatalogItem> _assetItemsByLabel = new(StringComparer.Ordinal);
    private readonly CancellationTokenSource _lifetime = new();
    private int _disposed;
    private readonly TimeSpan _connectionTimeout;
    private string _packageRoot;
    private string _projectName = "preview";
    private string _bakeTarget = "Both";
    private string _bakeProfile = "debug";
    private bool _liveBakeEnabled;
    private bool _watchChanges;
    private string? _selectedHierarchyItem;
    private string? _selectedAssetItem;
    private string _inspectorText = "选择项目、场景或资产查看其会话信息。";
    private string _sceneGoalX = string.Empty;
    private string _sceneGoalY = string.Empty;
    private string _scriptGoalX = string.Empty;
    private string _scriptGoalY = string.Empty;
    private string _scriptVelocityX = string.Empty;
    private string _scriptVelocityY = string.Empty;

    public AvaloniaEditorViewModel(EditorWorkspaceViewModel workspace, IEditorViewDispatcher dispatcher, string defaultPackageRoot, TimeSpan? connectionTimeout = null)
    {
        _workspace = workspace ?? throw new ArgumentNullException(nameof(workspace));
        _dispatcher = dispatcher ?? throw new ArgumentNullException(nameof(dispatcher));
        _packageRoot = defaultPackageRoot;
        _connectionTimeout = connectionTimeout ?? TimeSpan.FromSeconds(10);
        _workspace.PropertyChanged += OnWorkspacePropertyChanged;
        _workspace.Project.PropertyChanged += OnNestedPropertyChanged;
        _workspace.ProjectSnapshot.PropertyChanged += OnNestedPropertyChanged;
        _workspace.HierarchySnapshot.PropertyChanged += OnNestedPropertyChanged;
        _workspace.AssetCatalogSnapshot.PropertyChanged += OnNestedPropertyChanged;
        _workspace.Authoring.PropertyChanged += OnNestedPropertyChanged;
        _workspace.Bake.PropertyChanged += OnNestedPropertyChanged;
        _workspace.Watch.PropertyChanged += OnNestedPropertyChanged;
        _workspace.Preview.PropertyChanged += OnNestedPropertyChanged;
        _workspace.Client.EventReceived += OnEditorEventAsync;

        ConnectCommand = AddCommand(new AsyncUiCommand(InitializeAsync, () => !IsBusy, HandleCommandError));
        OpenProjectCommand = AddCommand(new AsyncUiCommand(OpenProjectAsync, () => CanProjectCommand && !IsBusy, HandleCommandError));
        ValidateProjectCommand = AddCommand(new AsyncUiCommand(ValidateProjectAsync, () => IsProjectOpen && !IsBusy, HandleCommandError));
        RefreshSnapshotsCommand = AddCommand(new AsyncUiCommand(RefreshSnapshotsAsync, () => CanRefreshSnapshots && !IsBusy, HandleCommandError));
        ApplyAuthoringCommand = AddCommand(new AsyncUiCommand(ApplyAuthoringAsync, () => CanApplyAuthoring && !IsBusy, HandleCommandError));
        UndoAuthoringCommand = AddCommand(new AsyncUiCommand(UndoAuthoringAsync, () => CanUndoAuthoring && !IsBusy, HandleCommandError));
        BakeCommand = AddCommand(new AsyncUiCommand(BakeAsync, () => IsProjectOpen && CanBake && !IsBusy, HandleCommandError));
        StartWatchCommand = AddCommand(new AsyncUiCommand(StartWatchAsync, () => IsProjectOpen && CanStartWatch && !IsWatching && !IsBusy, HandleCommandError));
        StopWatchCommand = AddCommand(new AsyncUiCommand(StopWatchAsync, () => IsWatching && !IsBusy, HandleCommandError));
        StartPreviewCommand = AddCommand(new AsyncUiCommand(StartPreviewAsync, () => IsProjectOpen && CanStartPreview && !IsPreviewRunning && !IsBusy, HandleCommandError));
        StopPreviewCommand = AddCommand(new AsyncUiCommand(StopPreviewAsync, () => CanStopPreview && IsPreviewRunning && !IsBusy, HandleCommandError));
        ClearEventLogCommand = new DelegateUiCommand(() => EventLog.Clear());
    }

    public EditorWorkspaceViewModel Workspace => _workspace;
    public ObservableCollection<string> HierarchyItems { get; } = [];
    public ObservableCollection<string> AssetItems { get; } = [];
    public ObservableCollection<EditorEventLogItem> EventLog { get; } = [];
    public IReadOnlyList<string> BakeTargets { get; } = ["Both", "Scene", "Script"];
    public IReadOnlyList<string> BakeProfiles { get; } = ["debug", "release"];

    public ICommand ConnectCommand { get; }
    public ICommand OpenProjectCommand { get; }
    public ICommand ValidateProjectCommand { get; }
    public ICommand RefreshSnapshotsCommand { get; }
    public ICommand ApplyAuthoringCommand { get; }
    public ICommand UndoAuthoringCommand { get; }
    public ICommand BakeCommand { get; }
    public ICommand StartWatchCommand { get; }
    public ICommand StopWatchCommand { get; }
    public ICommand StartPreviewCommand { get; }
    public ICommand StopPreviewCommand { get; }
    public ICommand ClearEventLogCommand { get; }

    public string PackageRoot { get => _packageRoot; set => SetProperty(ref _packageRoot, value); }
    public string ProjectName { get => _projectName; set => SetProperty(ref _projectName, value); }
    public string BakeTarget { get => _bakeTarget; set => SetProperty(ref _bakeTarget, value); }
    public string BakeProfile { get => _bakeProfile; set => SetProperty(ref _bakeProfile, value); }
    public bool LiveBakeEnabled { get => _liveBakeEnabled; set => SetProperty(ref _liveBakeEnabled, value); }
    public bool WatchChanges { get => _watchChanges; set => SetProperty(ref _watchChanges, value); }
    public string? SelectedHierarchyItem { get => _selectedHierarchyItem; set { if (SetProperty(ref _selectedHierarchyItem, value) && value is not null && _hierarchyItemsByLabel.TryGetValue(value, out var node)) { InspectorText = FormatHierarchyInspector(node); } } }
    public string? SelectedAssetItem { get => _selectedAssetItem; set { if (SetProperty(ref _selectedAssetItem, value) && value is not null && _assetItemsByLabel.TryGetValue(value, out var item)) { InspectorText = FormatAssetInspector(item); } } }
    public string InspectorText { get => _inspectorText; private set => SetProperty(ref _inspectorText, value); }    public string SceneGoalX { get => _sceneGoalX; set => SetProperty(ref _sceneGoalX, value); }
    public string SceneGoalY { get => _sceneGoalY; set => SetProperty(ref _sceneGoalY, value); }
    public string ScriptGoalX { get => _scriptGoalX; set => SetProperty(ref _scriptGoalX, value); }
    public string ScriptGoalY { get => _scriptGoalY; set => SetProperty(ref _scriptGoalY, value); }
    public string ScriptVelocityX { get => _scriptVelocityX; set => SetProperty(ref _scriptVelocityX, value); }
    public string ScriptVelocityY { get => _scriptVelocityY; set => SetProperty(ref _scriptVelocityY, value); }

    public string ConnectionStatus => _workspace.ConnectionState switch
    {
        EditorConnectionState.Ready => "已连接（stdio JSONL v1）",
        EditorConnectionState.Connecting => "正在连接 Editor Service…",
        EditorConnectionState.Stopping => "正在关闭…",
        EditorConnectionState.Faulted => $"失败：{_workspace.LastErrorCode ?? "unknown"}",
        _ => "未连接"
    };
    public string ValidationStatus => _workspace.Project.State.ToString();
    public string ValidationDiagnostics => _workspace.Project.Diagnostics.Count == 0
        ? (_workspace.Project.ErrorMessage ?? "打开项目后执行校验。")
        : string.Join(Environment.NewLine, _workspace.Project.Diagnostics);
    public string BakeStatus => _workspace.Bake.State switch
    {
        EditorBakeState.Running => "baking…",
        EditorBakeState.Succeeded => $"succeeded · {_workspace.Bake.Target}/{_workspace.Bake.Profile}",
        EditorBakeState.Failed => _workspace.Bake.RetainedPreviousArtifact ? $"failed · 保留旧 artifact（{_workspace.Bake.ErrorCode}）" : $"failed · {_workspace.Bake.ErrorCode}",
        _ => "空闲"
    };
    public string PreviewStatus => _workspace.Preview.State.ToString();
    public string SurfaceMode => _workspace.Preview.SurfaceMode ?? "external-window（独立 Runtime 窗口）";
    public string SurfaceDetails => _workspace.Preview.Surface is { } surface
        ? $"class={surface.WindowClass}; pid={surface.ProcessId?.ToString() ?? "pending"}"
        : (_workspace.Preview.LastStatusName is { } name ? $"{name}={_workspace.Preview.LastStatusValue}" : "未创建 Preview surface。");
    public string SnapshotStatus
    {
        get
        {
            var states = new[] { _workspace.ProjectSnapshot.State, _workspace.HierarchySnapshot.State, _workspace.AssetCatalogSnapshot.State };
            if (states.Any(state => state == EditorSnapshotState.Loading)) { return "snapshot loading…"; }
            var failed = new[] { _workspace.ProjectSnapshot.ErrorCode, _workspace.HierarchySnapshot.ErrorCode, _workspace.AssetCatalogSnapshot.ErrorCode }.FirstOrDefault(value => value is not null);
            if (failed is not null) { return $"snapshot failed · {failed}"; }
            if (_workspace.HierarchySnapshot.Value is { } hierarchy && _workspace.AssetCatalogSnapshot.Value is { } assets)
            {
                return $"snapshot v1 · hierarchy={hierarchy.Nodes.Length} · assets={assets.ItemCount}";
            }
            return "snapshot 未加载";
        }
    }
    public string AuthoringStatus => _workspace.Authoring.State switch
    {
        EditorAuthoringState.Applying => "authoring applying…",
        EditorAuthoringState.Undoing => "authoring undoing…",
        EditorAuthoringState.Succeeded => $"{_workspace.Authoring.Operation} succeeded · undo={_workspace.Authoring.UndoDepth}",
        EditorAuthoringState.Failed => $"authoring failed · {_workspace.Authoring.ErrorCode} · current content retained",
        _ => "authoring idle"
    };
    public string AuthoringRevisionStatus => _workspace.Authoring.Revision is { Length: >= 12 } revision ? $"revision={revision[..12]}…" : "revision=—";
    public string CapabilitySummary => _workspace.Capabilities.IsLoaded
        ? $"commands={_workspace.Capabilities.Commands.Count}; transport=stdio-jsonl"
        : "能力尚未协商";
    public bool IsBusy => _workspace.Project.State is EditorProjectState.Opening or EditorProjectState.Validating
        || _workspace.ProjectSnapshot.State == EditorSnapshotState.Loading
        || _workspace.HierarchySnapshot.State == EditorSnapshotState.Loading
        || _workspace.AssetCatalogSnapshot.State == EditorSnapshotState.Loading
        || _workspace.Authoring.State is EditorAuthoringState.Applying or EditorAuthoringState.Undoing
        || _workspace.Bake.State == EditorBakeState.Running
        || _workspace.Watch.State is EditorWatchState.Starting or EditorWatchState.Stopping
        || _workspace.Preview.State is EditorPreviewState.Starting or EditorPreviewState.Stopping;
    public bool IsConnected => _workspace.ConnectionState == EditorConnectionState.Ready && _workspace.Client.IsConnected;
    public bool IsProjectOpen => _workspace.Project.Session is not null;
    public bool IsWatching => _workspace.Watch.State == EditorWatchState.Watching;
    public bool IsPreviewRunning => _workspace.Preview.State is EditorPreviewState.Starting or EditorPreviewState.Running;
    public bool CanProjectCommand => _workspace.Capabilities.CanOpenProject && IsConnected;
    public bool CanApplyAuthoring => IsProjectOpen && _workspace.Capabilities.CanApplyAuthoring;
    public bool CanUndoAuthoring => IsProjectOpen && _workspace.Capabilities.CanUndoAuthoring && _workspace.Authoring.UndoDepth > 0;
    public bool CanRefreshSnapshots => IsProjectOpen
        && _workspace.Capabilities.CanReadProjectSnapshot
        && _workspace.Capabilities.CanReadHierarchySnapshot
        && _workspace.Capabilities.CanReadAssetCatalogSnapshot;
    public bool CanBake => _workspace.Capabilities.CanBake;
    public bool CanStartWatch => _workspace.Capabilities.CanStartWatch;
    public bool CanStopPreview => _workspace.Capabilities.CanStopPreview;
    public bool CanStartPreview => _workspace.Capabilities.CanStartPreview;
    public bool SupportsExternalWindow => _workspace.Capabilities.CanUseExternalWindow;
    public bool SupportsSharedTexture => _workspace.Capabilities.CanUseSharedTexture;
    public bool SupportsFrameStream => _workspace.Capabilities.CanUseFrameStream;

    public async Task InitializeAsync()
    {
        if (IsConnected) { return; }
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(_lifetime.Token);
        timeout.CancelAfter(_connectionTimeout);
        try { await _workspace.ConnectAsync(timeout.Token); AddLog("connected", CapabilitySummary, null, 0); }
        catch (Exception exception) { AddLog("connect_failed", exception.Message, null, 0); }
        RaiseAll();
    }

    private async Task OpenProjectAsync()
    {
        await EnsureConnectedAsync();
        var session = await _workspace.OpenProjectAsync(new ProjectOpenParameters(PackageRoot, ProjectName), _lifetime.Token);
        if (CanRefreshSnapshots)
        {
            await _workspace.RefreshSnapshotsAsync(session.ProjectName, _lifetime.Token);
            ApplySnapshotProjection(session);
        }
        else
        {
            ApplySessionProjection(session);
        }
        RaiseAll();
    }

    private async Task RefreshSnapshotsAsync()
    {
        await RefreshSnapshotsForCurrentProjectAsync(_lifetime.Token);
    }

    // 暴露可等待的刷新入口，工作流/宿主可以观察真实异常；UI 命令仍通过同一实现。
    public async Task RefreshSnapshotsForCurrentProjectAsync(CancellationToken cancellationToken = default)
    {
        await EnsureConnectedAsync();
        var session = _workspace.Project.Session ?? throw new EditorRpcException("project_not_open", "请先打开项目。");
        await _workspace.RefreshSnapshotsAsync(session.ProjectName, cancellationToken == default ? _lifetime.Token : cancellationToken);
        ApplySnapshotProjection(session);
        RaiseAll();
    }

    private async Task ApplyAuthoringAsync()
    {
        await ApplyAuthoringForCurrentProjectAsync(_lifetime.Token);
    }

    // 宿主/工作流可等待该入口；UI 命令只负责调用同一深 module。
    public async Task<AuthoringMutationResult> ApplyAuthoringForCurrentProjectAsync(CancellationToken cancellationToken = default)
    {
        await EnsureConnectedAsync();
        var session = _workspace.Project.Session ?? throw new EditorRpcException("project_not_open", "请先打开项目。");
        var project = _workspace.ProjectSnapshot.Value ?? throw new EditorRpcException("snapshot_missing", "Project snapshot is not loaded.");
        var patch = new AuthoringPatch(
            ParseVector(SceneGoalX, SceneGoalY, "scene.goal.position"),
            ParseVector(ScriptGoalX, ScriptGoalY, "script.goal.position"),
            ParseVector(ScriptVelocityX, ScriptVelocityY, "script.goal.velocity"));
        var result = await _workspace.ApplyAuthoringAsync(new AuthoringApplyParameters(session.ProjectName, project.AuthoringRevision, patch), cancellationToken == default ? _lifetime.Token : cancellationToken);
        ApplySnapshotProjection(session);
        RaiseAll();
        return result;
    }

    private async Task UndoAuthoringAsync()
    {
        await UndoAuthoringForCurrentProjectAsync(_lifetime.Token);
    }

    public async Task<AuthoringMutationResult> UndoAuthoringForCurrentProjectAsync(CancellationToken cancellationToken = default)
    {
        await EnsureConnectedAsync();
        var session = _workspace.Project.Session ?? throw new EditorRpcException("project_not_open", "请先打开项目。");
        var project = _workspace.ProjectSnapshot.Value ?? throw new EditorRpcException("snapshot_missing", "Project snapshot is not loaded.");
        var result = await _workspace.UndoAuthoringAsync(new AuthoringUndoParameters(session.ProjectName, project.AuthoringRevision), cancellationToken == default ? _lifetime.Token : cancellationToken);
        ApplySnapshotProjection(session);
        RaiseAll();
        return result;
    }

    private static double[] ParseVector(string x, string y, string field)
    {
        if (!double.TryParse(x, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var parsedX)
            || !double.TryParse(y, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var parsedY)
            || !double.IsFinite(parsedX) || !double.IsFinite(parsedY))
        {
            throw new EditorRpcException("invalid_authoring_patch", $"{field} requires two finite numbers.");
        }
        return [parsedX, parsedY];
    }
    private void ApplySnapshotProjection(ProjectSessionInfo session)
    {
        var project = _workspace.ProjectSnapshot.Value ?? throw new InvalidOperationException("Project snapshot is missing.");
        var hierarchy = _workspace.HierarchySnapshot.Value ?? throw new InvalidOperationException("Hierarchy snapshot is missing.");
        var assets = _workspace.AssetCatalogSnapshot.Value ?? throw new InvalidOperationException("Asset Catalog snapshot is missing.");

        HierarchyItems.Clear();
        _hierarchyItemsByLabel.Clear();
        var nodesById = hierarchy.Nodes.ToDictionary(node => node.Id, StringComparer.Ordinal);
        foreach (var node in hierarchy.Nodes)
        {
            var depth = GetHierarchyDepth(node, nodesById);
            var label = $"{new string(' ', depth * 2)}{node.DisplayName} [{node.Kind}] · {node.Id}";
            HierarchyItems.Add(label);
            _hierarchyItemsByLabel.Add(label, node);
        }

        AssetItems.Clear();
        _assetItemsByLabel.Clear();
        foreach (var item in assets.Items)
        {
            var label = $"{item.Category} · {item.RelativePath}";
            AssetItems.Add(label);
            _assetItemsByLabel.Add(label, item);
        }

        SelectedHierarchyItem = null;
        SelectedAssetItem = null;
        InspectorText = $"Project\n{project.ProjectName}\n\nModelVersion: {project.ModelVersion}\nPackage root: {session.PackageRoot}";
        SetAuthoringFields(project);
        var defaultHierarchy = _hierarchyItemsByLabel.FirstOrDefault(pair => pair.Value.Id == "scene.goal").Key
            ?? _hierarchyItemsByLabel.Keys.FirstOrDefault();
        if (defaultHierarchy is not null) { SelectedHierarchyItem = defaultHierarchy; }
    }

    private void SetAuthoringFields(ProjectModelSnapshot project)
    {
        SceneGoalX = project.Scene.GoalPosition[0].ToString("0.###", System.Globalization.CultureInfo.InvariantCulture);
        SceneGoalY = project.Scene.GoalPosition[1].ToString("0.###", System.Globalization.CultureInfo.InvariantCulture);
        ScriptGoalX = project.Script.GoalPosition[0].ToString("0.###", System.Globalization.CultureInfo.InvariantCulture);
        ScriptGoalY = project.Script.GoalPosition[1].ToString("0.###", System.Globalization.CultureInfo.InvariantCulture);
        ScriptVelocityX = project.Script.GoalVelocity[0].ToString("0.###", System.Globalization.CultureInfo.InvariantCulture);
        ScriptVelocityY = project.Script.GoalVelocity[1].ToString("0.###", System.Globalization.CultureInfo.InvariantCulture);
    }
    private void ApplySessionProjection(ProjectSessionInfo session)
    {
        // 兼容旧 Service；26C+ Service 会走真实 snapshot 分支，26D mutation 仍需要独立 capability。
        HierarchyItems.Clear();
        _hierarchyItemsByLabel.Clear();
        HierarchyItems.Add($"Project / {session.ProjectName}");
        AssetItems.Clear();
        _assetItemsByLabel.Clear();
        AssetItems.Add(Path.GetFileName(session.ScenePath));
        AssetItems.Add(Path.GetFileName(session.ScriptPath));
        AssetItems.Add(Path.GetFileName(session.PreviewPath));
        InspectorText = $"Project\n{session.ProjectName}\n\nSnapshot commands unavailable.";
    }

    private static int GetHierarchyDepth(HierarchyNode node, IReadOnlyDictionary<string, HierarchyNode> nodesById)
    {
        var depth = 0;
        var parentId = node.ParentId;
        while (parentId is not null && nodesById.TryGetValue(parentId, out var parent) && depth < 32)
        {
            depth++;
            parentId = parent.ParentId;
        }
        return depth;
    }

    private static string FormatHierarchyInspector(HierarchyNode node) =>
        $"Hierarchy\n{node.DisplayName}\n\nId: {node.Id}\nKind: {node.Kind}\nParent: {node.ParentId ?? "<root>"}\n{FormatProperties(node.Properties)}";

    private static string FormatAssetInspector(AssetCatalogItem item) =>
        $"Asset\n{item.DisplayName}\n\nAssetId: {item.AssetId}\nPath: {item.RelativePath}\nCategory: {item.Category}\nExtension: {item.Extension}\nBytes: {item.SizeBytes}\n{FormatProperties(item.Properties)}";
    private static string FormatProperties(IReadOnlyDictionary<string, JsonElement> properties)
    {
        if (properties.Count == 0) { return string.Empty; }
        return string.Join(Environment.NewLine, properties.Select(pair =>
            $"{pair.Key}: {(pair.Value.ValueKind == JsonValueKind.String ? pair.Value.GetString() : pair.Value.GetRawText())}"));
    }

    private async Task ValidateProjectAsync() { await _workspace.ValidateProjectAsync(ProjectName, _lifetime.Token); RaiseAll(); }
    private async Task BakeAsync() { await _workspace.BakeAsync(new BakeStartParameters(BakeTarget, BakeProfile), _lifetime.Token); RaiseAll(); }
    private async Task StartWatchAsync() { await _workspace.StartWatchAsync(new WatchStartParameters(BakeTarget, BakeProfile), _lifetime.Token); RaiseAll(); }
    private async Task StopWatchAsync() { await _workspace.StopWatchAsync(_lifetime.Token); RaiseAll(); }
    private async Task StartPreviewAsync()
    {
        await _workspace.StartPreviewAsync(new PreviewStartParameters(ProjectName: ProjectName, WatchChanges: WatchChanges, LiveBake: LiveBakeEnabled, BakeProfile: BakeProfile), _lifetime.Token);
        RaiseAll();
    }
    private async Task StopPreviewAsync() { await _workspace.StopPreviewAsync(_lifetime.Token); RaiseAll(); }

    private async Task EnsureConnectedAsync()
    {
        if (!IsConnected) { await InitializeAsync(); }
        if (!IsConnected) { throw new EditorRpcException("not_connected", "Editor Service 尚未连接。"); }
    }

    private async Task OnEditorEventAsync(EditorEvent notification)
    {
        await _dispatcher.InvokeAsync(() =>
        {
            var summary = notification.Data is { } data ? data.GetRawText() : string.Empty;
            AddLog(notification.Event, summary.Length <= 240 ? summary : summary[..237] + "…", notification.RequestId, notification.Sequence);
            RaiseAll();
        });
    }

    private void OnWorkspacePropertyChanged(object? sender, PropertyChangedEventArgs e) { RaiseAll(); }
    private void OnNestedPropertyChanged(object? sender, PropertyChangedEventArgs e) { RaiseAll(); }
    private void HandleCommandError(Exception exception) => _ = _dispatcher.InvokeAsync(() => AddLog("command_failed", exception.Message, null, 0));
    private void AddLog(string eventName, string summary, string? requestId, long sequence) { EventLog.Add(new EditorEventLogItem(sequence, eventName, summary, requestId, DateTimeOffset.Now)); while (EventLog.Count > 200) { EventLog.RemoveAt(0); } }
    private AsyncUiCommand AddCommand(AsyncUiCommand command) { _commands.Add(command); return command; }
    private void OnPropertyChanged(string propertyName) => RaisePropertyChanged(propertyName);
    private void RaiseAll() { foreach (var command in _commands) { command.RaiseCanExecuteChanged(); } OnPropertyChanged(nameof(ConnectionStatus)); OnPropertyChanged(nameof(ValidationStatus)); OnPropertyChanged(nameof(ValidationDiagnostics)); OnPropertyChanged(nameof(BakeStatus)); OnPropertyChanged(nameof(PreviewStatus)); OnPropertyChanged(nameof(SurfaceMode)); OnPropertyChanged(nameof(SurfaceDetails)); OnPropertyChanged(nameof(SnapshotStatus)); OnPropertyChanged(nameof(AuthoringStatus)); OnPropertyChanged(nameof(AuthoringRevisionStatus)); OnPropertyChanged(nameof(CapabilitySummary)); OnPropertyChanged(nameof(IsBusy)); OnPropertyChanged(nameof(IsConnected)); OnPropertyChanged(nameof(IsProjectOpen)); OnPropertyChanged(nameof(IsWatching)); OnPropertyChanged(nameof(IsPreviewRunning)); OnPropertyChanged(nameof(CanProjectCommand)); OnPropertyChanged(nameof(CanApplyAuthoring)); OnPropertyChanged(nameof(CanUndoAuthoring)); OnPropertyChanged(nameof(CanRefreshSnapshots)); OnPropertyChanged(nameof(CanBake)); OnPropertyChanged(nameof(CanStartWatch)); OnPropertyChanged(nameof(CanStopPreview)); OnPropertyChanged(nameof(CanStartPreview)); OnPropertyChanged(nameof(SupportsExternalWindow)); OnPropertyChanged(nameof(SupportsSharedTexture)); OnPropertyChanged(nameof(SupportsFrameStream)); }

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0) { return; }
        _lifetime.Cancel();
        try
        {
            if (IsConnected && _workspace.Capabilities.SupportsCommand("shutdown")) { try { await _workspace.ShutdownAsync(CancellationToken.None); } catch { } }
        }
        finally { await _workspace.DisposeAsync(); _lifetime.Dispose(); }
    }
}

public sealed record EditorEventLogItem(long Sequence, string Event, string Summary, string? RequestId, DateTimeOffset Timestamp);

public sealed class AsyncUiCommand : ICommand
{
    private readonly Func<Task> _execute;
    private readonly Func<bool> _canExecute;
    private readonly Action<Exception> _onError;
    private bool _running;
    public AsyncUiCommand(Func<Task> execute, Func<bool> canExecute, Action<Exception> onError) { _execute = execute; _canExecute = canExecute; _onError = onError; }
    public event EventHandler? CanExecuteChanged;
    public bool CanExecute(object? parameter) => !_running && _canExecute();
    public async void Execute(object? parameter) { if (!CanExecute(parameter)) { return; } _running = true; CanExecuteChanged?.Invoke(this, EventArgs.Empty); try { await _execute(); } catch (Exception exception) { _onError(exception); } finally { _running = false; CanExecuteChanged?.Invoke(this, EventArgs.Empty); } }
    public void RaiseCanExecuteChanged() => CanExecuteChanged?.Invoke(this, EventArgs.Empty);
}

public sealed class DelegateUiCommand : ICommand
{
    private readonly Action _execute;
    public DelegateUiCommand(Action execute) => _execute = execute;
    public event EventHandler? CanExecuteChanged { add { } remove { } }
    public bool CanExecute(object? parameter) => true;
    public void Execute(object? parameter) => _execute();
}










