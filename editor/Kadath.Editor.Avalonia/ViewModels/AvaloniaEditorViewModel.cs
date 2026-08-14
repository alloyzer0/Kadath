using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
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
    private const int MaxScriptSourceBytes = 64 * 1024;
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    private readonly EditorWorkspaceViewModel _workspace;
    private readonly IEditorViewDispatcher _dispatcher;
    private readonly List<AsyncUiCommand> _commands = [];
    private readonly List<DelegateUiCommand> _localCommands = [];
    private readonly Dictionary<string, HierarchyNode> _hierarchyItemsByLabel = new(StringComparer.Ordinal);
    private readonly Dictionary<string, AssetCatalogItem> _assetItemsByLabel = new(StringComparer.Ordinal);
    private readonly Dictionary<string, string> _assetLabelsByRelativePath = new(StringComparer.Ordinal);
    private readonly CancellationTokenSource _lifetime = new();
    private EditorProjectIdentity? _projectIdentity;
    private int _disposed;
    private readonly TimeSpan _connectionTimeout;
    private string _packageRoot;
    private string _projectName = "preview";
    private string _bakeTarget = "Both";
    private string _bakeProfile = "debug";
    private bool _liveBakeEnabled;
    private bool _watchChanges;
    private string _textureImportSourcePath = string.Empty;
    private string _textureImportAssetName = "imported";
    private string _textureImportProfile = "debug";
    private string? _selectedHierarchyItem;
    private string? _selectedAssetItem;
    private SceneObjectDraftViewModel? _selectedSceneObject;
    private string _inspectorText = "选择项目、场景或资产查看其会话信息。";
    private string _sceneGoalX = string.Empty;
    private string _sceneGoalY = string.Empty;
    private string _scenePlayerTextureId = "1";
    private string _sceneGoalTextureId = "2";
    private string _sceneHazardTextureId = "1";
    private string _scriptGoalX = string.Empty;
    private string _scriptGoalY = string.Empty;
    private string _scriptVelocityX = string.Empty;
    private string _scriptVelocityY = string.Empty;
    private ScriptSourceDocument? _scriptSourceDocument;
    private string _scriptSourceText = string.Empty;
    private int _scriptSourceCaretIndex;
    private EditorScriptDiagnosticItem? _selectedScriptDiagnostic;
    private string? _scriptSourceHierarchyItem;
    private bool _allowScriptSourceSelectionChange;
    private int _scriptSourceSelectionVersion;
    public ObservableCollection<TextureAssignmentSlotViewModel> SceneTextureAssignments { get; } = [
        new TextureAssignmentSlotViewModel("Texture 1"),
        new TextureAssignmentSlotViewModel("Texture 2"),
        new TextureAssignmentSlotViewModel("Texture 3"),
        new TextureAssignmentSlotViewModel("Texture 4")
    ];
    public ObservableCollection<string> SceneTextureIds { get; } = [];
    public ObservableCollection<SceneObjectDraftViewModel> SceneObjectDrafts { get; } = [];

    public AvaloniaEditorViewModel(EditorWorkspaceViewModel workspace, IEditorViewDispatcher dispatcher, string defaultPackageRoot, TimeSpan? connectionTimeout = null)
    {
        _workspace = workspace ?? throw new ArgumentNullException(nameof(workspace));
        _dispatcher = dispatcher ?? throw new ArgumentNullException(nameof(dispatcher));
        _packageRoot = defaultPackageRoot;
        _projectIdentity = EditorProjectIdentity.From(_workspace.Project.Session);
        _connectionTimeout = connectionTimeout ?? TimeSpan.FromSeconds(10);
        _workspace.PropertyChanged += OnWorkspacePropertyChanged;
        _workspace.Project.PropertyChanged += OnProjectPropertyChanged;
        _workspace.ProjectSnapshot.PropertyChanged += OnNestedPropertyChanged;
        _workspace.HierarchySnapshot.PropertyChanged += OnNestedPropertyChanged;
        _workspace.AssetCatalogSnapshot.PropertyChanged += OnNestedPropertyChanged;
        _workspace.Publication.PropertyChanged += OnNestedPropertyChanged;
        _workspace.Authoring.PropertyChanged += OnNestedPropertyChanged;
        _workspace.ScriptSource.PropertyChanged += OnNestedPropertyChanged;
        _workspace.ScriptDiagnostics.PropertyChanged += OnNestedPropertyChanged;
        _workspace.Bake.PropertyChanged += OnNestedPropertyChanged;
        _workspace.Watch.PropertyChanged += OnNestedPropertyChanged;
        _workspace.Preview.PropertyChanged += OnNestedPropertyChanged;
        _workspace.Client.EventReceived += OnEditorEventAsync;
        foreach (var slot in SceneTextureAssignments)
        {
            slot.AssetItems = AssetItems;
            slot.PropertyChanged += OnTextureAssignmentPropertyChanged;
        }

        ConnectCommand = AddCommand(new AsyncUiCommand(InitializeAsync, () => !IsBusy, HandleCommandError));
        OpenProjectCommand = AddCommand(new AsyncUiCommand(OpenProjectAsync, () => CanProjectCommand && !IsBusy, HandleCommandError));
        CreateProjectCommand = AddCommand(new AsyncUiCommand(CreateProjectAsync, () => CanCreateProject, HandleCommandError));
        ValidateProjectCommand = AddCommand(new AsyncUiCommand(ValidateProjectAsync, () => IsProjectOpen && !IsBusy, HandleCommandError));
        RefreshSnapshotsCommand = AddCommand(new AsyncUiCommand(RefreshSnapshotsAsync, () => CanRefreshSnapshots && !IsBusy, HandleCommandError));
        ApplyAuthoringCommand = AddCommand(new AsyncUiCommand(ApplyAuthoringAsync, () => CanApplyAuthoring && !IsBusy, HandleCommandError));
        UndoAuthoringCommand = AddCommand(new AsyncUiCommand(UndoAuthoringAsync, () => CanUndoAuthoring && !IsBusy, HandleCommandError));
        SaveScriptSourceCommand = AddCommand(new AsyncUiCommand(SaveScriptSourceAsync, () => CanSaveScriptSource, HandleCommandError));
        UndoScriptSourceCommand = AddCommand(new AsyncUiCommand(UndoScriptSourceAsync, () => CanUndoScriptSource, HandleCommandError));
        ReloadScriptSourceCommand = AddCommand(new AsyncUiCommand(ReloadScriptSourceAsync, () => CanReloadScriptSource, HandleCommandError));
        BakeCommand = AddCommand(new AsyncUiCommand(BakeAsync, () => IsProjectOpen && CanBake && !IsWatching && !IsPreviewAutoSync && !IsBusy, HandleCommandError));
        BakeChangesCommand = AddCommand(new AsyncUiCommand(BakeChangesAsync, () => CanBakeChanges, HandleCommandError));
        StartWatchCommand = AddCommand(new AsyncUiCommand(StartWatchAsync, () => IsProjectOpen && CanStartWatch && !IsWatching && !IsBusy, HandleCommandError));
        StopWatchCommand = AddCommand(new AsyncUiCommand(StopWatchAsync, () => CanRequestWatchStop && !IsBusy, HandleCommandError));
        StartPreviewCommand = AddCommand(new AsyncUiCommand(StartPreviewAsync, () => IsProjectOpen && CanStartPreview && !IsPreviewRunning && !IsBusy, HandleCommandError));
        StopPreviewCommand = AddCommand(new AsyncUiCommand(StopPreviewAsync, () => CanRequestPreviewStop && !IsBusy, HandleCommandError));
        ImportTextureCommand = AddCommand(new AsyncUiCommand(ImportTextureAsync, () => CanImportTexture, HandleCommandError));
        AddDecorativeSpriteCommand = AddCommand(new DelegateUiCommand(AddDecorativeSpriteDraft, () => CanAddSceneObject));
        AddPatrolHazardCommand = AddCommand(new DelegateUiCommand(AddPatrolHazardDraft, () => CanAddPatrolHazard));
        DeleteSceneObjectCommand = AddCommand(new DelegateUiCommand(DeleteSelectedSceneObjectDraft, () => CanDeleteSelectedSceneObject));
        MoveSceneObjectUpCommand = AddCommand(new DelegateUiCommand(MoveSelectedSceneObjectUp, () => CanMoveSelectedSceneObjectUp));
        MoveSceneObjectDownCommand = AddCommand(new DelegateUiCommand(MoveSelectedSceneObjectDown, () => CanMoveSelectedSceneObjectDown));
        DiscardScriptSourceChangesCommand = AddCommand(new DelegateUiCommand(DiscardScriptSourceChanges, () => CanDiscardScriptSourceChanges));
        ReanalyzeScriptSourceCommand = AddCommand(new DelegateUiCommand(
            () => _workspace.ReanalyzeScriptSource(),
            () => _workspace.ScriptDiagnostics.CanReanalyze));
        ClearEventLogCommand = new DelegateUiCommand(() => EventLog.Clear());
    }

    public EditorWorkspaceViewModel Workspace => _workspace;
    public ObservableCollection<string> HierarchyItems { get; } = [];
    public ObservableCollection<string> AssetItems { get; } = [];
    public ObservableCollection<EditorEventLogItem> EventLog { get; } = [];
    public IReadOnlyList<string> BakeTargets { get; } = ["Both", "Scene", "Script"];
    public IReadOnlyList<string> BakeProfiles { get; } = ["debug", "release"];
    public IReadOnlyList<string> TextureImportProfiles { get; } = ["debug", "release"];

    public ICommand ConnectCommand { get; }
    public ICommand OpenProjectCommand { get; }
    public ICommand CreateProjectCommand { get; }
    public ICommand ValidateProjectCommand { get; }
    public ICommand RefreshSnapshotsCommand { get; }
    public ICommand ApplyAuthoringCommand { get; }
    public ICommand UndoAuthoringCommand { get; }
    public ICommand SaveScriptSourceCommand { get; }
    public ICommand UndoScriptSourceCommand { get; }
    public ICommand ReloadScriptSourceCommand { get; }
    public ICommand BakeCommand { get; }
    public ICommand BakeChangesCommand { get; }
    public ICommand StartWatchCommand { get; }
    public ICommand StopWatchCommand { get; }
    public ICommand StartPreviewCommand { get; }
    public ICommand StopPreviewCommand { get; }
    public ICommand ImportTextureCommand { get; }
    public ICommand AddDecorativeSpriteCommand { get; }
    public ICommand AddPatrolHazardCommand { get; }
    public ICommand DeleteSceneObjectCommand { get; }
    public ICommand MoveSceneObjectUpCommand { get; }
    public ICommand MoveSceneObjectDownCommand { get; }
    public ICommand DiscardScriptSourceChangesCommand { get; }
    public ICommand ReanalyzeScriptSourceCommand { get; }
    public ICommand ClearEventLogCommand { get; }

    public string PackageRoot { get => _packageRoot; set => SetProperty(ref _packageRoot, value); }
    public string ProjectName { get => _projectName; set => SetProperty(ref _projectName, value); }
    public string BakeTarget { get => _bakeTarget; set => SetProperty(ref _bakeTarget, value); }
    public string BakeProfile { get => _bakeProfile; set => SetProperty(ref _bakeProfile, value); }
    public bool LiveBakeEnabled { get => _liveBakeEnabled; set { if (SetProperty(ref _liveBakeEnabled, value)) { RaiseAll(); } } }
    public bool WatchChanges { get => _watchChanges; set { if (SetProperty(ref _watchChanges, value)) { RaiseAll(); } } }
    public string TextureImportSourcePath { get => _textureImportSourcePath; set { if (SetProperty(ref _textureImportSourcePath, value)) { RaiseAll(); } } }
    public string TextureImportAssetName { get => _textureImportAssetName; set { if (SetProperty(ref _textureImportAssetName, value)) { RaiseAll(); } } }
    public string TextureImportProfile { get => _textureImportProfile; set { if (SetProperty(ref _textureImportProfile, value)) { RaiseAll(); } } }
    public string? SelectedHierarchyItem
    {
        get => _selectedHierarchyItem;
        set
        {
            if (!_allowScriptSourceSelectionChange
                && IsScriptSourceDirty
                && !string.Equals(value, _scriptSourceHierarchyItem, StringComparison.Ordinal))
            {
                AddLog("script_source_switch_blocked", "请先保存或放弃当前脚本的未保存内容。", null, 0);
                RaisePropertyChanged(nameof(SelectedHierarchyItem));
                return;
            }
            if (!SetProperty(ref _selectedHierarchyItem, value)) { return; }
            if (value is not null && _hierarchyItemsByLabel.TryGetValue(value, out var node))
            {
                InspectorText = FormatHierarchyInspector(node);
                SelectedSceneObject = node.Kind == "SceneObject"
                    ? SceneObjectDrafts.FirstOrDefault(draft => draft.OriginalObjectId == node.DisplayName || draft.ObjectId == node.DisplayName)
                    : null;
                if (TryGetScriptId(node, out var scriptId))
                {
                    _scriptSourceHierarchyItem = value;
                    if (SelectedScriptSourceId != scriptId)
                    {
                        _workspace.ScriptDiagnostics.Reset(!_workspace.Capabilities.CanAnalyzeScriptSource);
                        _ = LoadScriptSourceFromSelectionAsync(scriptId);
                    }
                }
                else
                {
                    _scriptSourceHierarchyItem = null;
                    Interlocked.Increment(ref _scriptSourceSelectionVersion);
                    _workspace.ScriptDiagnostics.Reset(!_workspace.Capabilities.CanAnalyzeScriptSource);
                }
            }
            else
            {
                _scriptSourceHierarchyItem = null;
                Interlocked.Increment(ref _scriptSourceSelectionVersion);
                _workspace.ScriptDiagnostics.Reset(!_workspace.Capabilities.CanAnalyzeScriptSource);
                SelectedSceneObject = null;
            }
        }
    }
    public string? SelectedAssetItem { get => _selectedAssetItem; set { if (SetProperty(ref _selectedAssetItem, value) && value is not null && _assetItemsByLabel.TryGetValue(value, out var item)) { InspectorText = FormatAssetInspector(item); } } }
    public SceneObjectDraftViewModel? SelectedSceneObject
    {
        get => _selectedSceneObject;
        set
        {
            if (!SetProperty(ref _selectedSceneObject, value)) { return; }
            RaiseAll();
        }
    }
    public string InspectorText { get => _inspectorText; private set => SetProperty(ref _inspectorText, value); }
    public string SceneGoalX { get => _sceneGoalX; set => SetProperty(ref _sceneGoalX, value); }
    public string SceneGoalY { get => _sceneGoalY; set => SetProperty(ref _sceneGoalY, value); }
    public string ScenePlayerTextureId { get => _scenePlayerTextureId; set => SetProperty(ref _scenePlayerTextureId, value); }
    public string SceneGoalTextureId { get => _sceneGoalTextureId; set => SetProperty(ref _sceneGoalTextureId, value); }
    public string SceneHazardTextureId { get => _sceneHazardTextureId; set => SetProperty(ref _sceneHazardTextureId, value); }
    public string ScriptGoalX { get => _scriptGoalX; set => SetProperty(ref _scriptGoalX, value); }
    public string ScriptGoalY { get => _scriptGoalY; set => SetProperty(ref _scriptGoalY, value); }
    public string ScriptVelocityX { get => _scriptVelocityX; set => SetProperty(ref _scriptVelocityX, value); }
    public string ScriptVelocityY { get => _scriptVelocityY; set => SetProperty(ref _scriptVelocityY, value); }
    public string ScriptSourceText
    {
        get => _scriptSourceText;
        set
        {
            if (!SetProperty(ref _scriptSourceText, value)) { return; }
            ObserveScriptSourceBuffer();
            RaiseAll();
        }
    }
    public int ScriptSourceCaretIndex
    {
        get => _scriptSourceCaretIndex;
        set => SetProperty(ref _scriptSourceCaretIndex, Math.Clamp(value, 0, ScriptSourceText.Length));
    }
    public EditorScriptDiagnosticItem? SelectedScriptDiagnostic
    {
        get => _selectedScriptDiagnostic;
        set
        {
            if (!SetProperty(ref _selectedScriptDiagnostic, value) || value?.CaretIndex is not { } caretIndex) return;
            ScriptSourceCaretIndex = caretIndex;
        }
    }
    public IReadOnlyList<EditorScriptDiagnosticItem> ScriptDiagnostics => _workspace.ScriptDiagnostics.Items;
    public bool HasScriptDiagnostics => ScriptDiagnostics.Count > 0;
    public string ScriptDiagnosticsStatus => _workspace.ScriptDiagnostics.State switch
    {
        EditorScriptDiagnosticsState.Unsupported => "当前 Service 不支持即时诊断。",
        EditorScriptDiagnosticsState.Idle => "等待加载行为脚本源码。",
        EditorScriptDiagnosticsState.Debouncing => "等待输入结束…",
        EditorScriptDiagnosticsState.Analyzing => "正在分析当前未保存缓冲区…",
        EditorScriptDiagnosticsState.Valid => "未发现问题。",
        EditorScriptDiagnosticsState.Invalid => $"发现 {ScriptDiagnostics.Count} 个错误。",
        EditorScriptDiagnosticsState.Failed when _workspace.ScriptDiagnostics.Result is not null =>
            $"分析器失败 · {_workspace.ScriptDiagnostics.ErrorCode} · 保留当前缓冲区最近诊断",
        EditorScriptDiagnosticsState.Failed => $"分析器失败 · {_workspace.ScriptDiagnostics.ErrorCode}",
        _ => "等待输入。"
    };
    public uint? SelectedScriptSourceId => _scriptSourceDocument?.ScriptId;
    public uint? SelectedScriptDependencyId => TryGetSelectedScriptDependency(out var scriptId, out _) ? scriptId : null;
    public bool HasSelectedScriptDependency => SelectedScriptDependencyId is not null;
    public bool IsScriptSourceSelection => SelectedScriptDependencyId is { } scriptId
        && _scriptSourceDocument?.ScriptId == scriptId;
    public string ScriptSourcePath => IsScriptSourceSelection && _scriptSourceDocument is not null
        ? _scriptSourceDocument.SourcePath
        : TryGetSelectedScriptDependency(out _, out var sourcePath)
            ? sourcePath
            : "请选择 Hierarchy 中的 ScriptDependency。";
    public string ScriptSourceRevisionStatus => _scriptSourceDocument is { AuthoringRevision.Length: >= 12 } document
        ? $"revision={document.AuthoringRevision[..12]}… · undo={_workspace.ScriptSource.UndoDepth}"
        : "revision=—";
    public bool HasScriptSourceDocument => _scriptSourceDocument is not null;
    public bool IsScriptSourceDirty => _scriptSourceDocument is { } document && !string.Equals(ScriptSourceText, document.Source, StringComparison.Ordinal);
    public int ScriptSourceUtf8Bytes
    {
        get
        {
            try { return StrictUtf8.GetByteCount(ScriptSourceText); }
            catch (EncoderFallbackException) { return -1; }
        }
    }
    public bool IsScriptSourceStrictUtf8 => ScriptSourceUtf8Bytes >= 0;
    public string ScriptSourceStatus => _workspace.ScriptSource.State switch
    {
        EditorScriptSourceState.Loading => "正在读取行为脚本源码…",
        EditorScriptSourceState.Saving => "正在保存行为脚本源码…",
        EditorScriptSourceState.Undoing => "正在撤销最近一次脚本源码提交…",
        EditorScriptSourceState.Failed when IsScriptSourceDirty => $"脚本源码操作失败 · {_workspace.ScriptSource.ErrorCode} · 未保存内容已保留",
        EditorScriptSourceState.Failed => $"脚本源码操作失败 · {_workspace.ScriptSource.ErrorCode}",
        _ when !IsScriptSourceSelection => "从 Hierarchy 选择 ScriptDependency 以加载源码。",
        _ when !IsScriptSourceStrictUtf8 => "源码包含无法编码为严格 UTF-8 的字符。",
        _ when IsScriptSourceDirty => $"有未保存修改 · UTF-8 {ScriptSourceUtf8Bytes}/{MaxScriptSourceBytes} 字节",
        _ when HasScriptSourceDocument => $"已加载 · UTF-8 {ScriptSourceUtf8Bytes}/{MaxScriptSourceBytes} 字节",
        _ => "从 Hierarchy 选择 ScriptDependency 以加载源码。"
    };

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
    public string PublicationStatus => _workspace.Publication.State switch
    {
        EditorPublicationState.Loading => "publication loading…",
        EditorPublicationState.Current => $"current · scene={ShortRevision(_workspace.Publication.Scene?.ArtifactRevision)} · script={ShortRevision(_workspace.Publication.Script?.ArtifactRevision)}",
        EditorPublicationState.SourceDirty => $"source dirty · next={_workspace.Publication.RecommendedBakeTarget}",
        EditorPublicationState.Missing => $"artifact missing · next={_workspace.Publication.RecommendedBakeTarget}",
        EditorPublicationState.ArtifactInvalid => $"artifact invalid · next={_workspace.Publication.RecommendedBakeTarget}",
        EditorPublicationState.ProfileMismatch => $"profile mismatch · next={_workspace.Publication.RecommendedBakeTarget}",
        EditorPublicationState.Failed => $"publication failed · {_workspace.Publication.ErrorCode}",
        _ => "publication 未加载"
    };
    public string PreviewStatus => _workspace.Preview.State.ToString();
    public string RuntimeSyncStatus
    {
        get
        {
            var runtime = _workspace.Preview.Runtime;
            if (runtime.State == EditorPreviewRuntimeState.Failed) { return $"Runtime initial load failed · {runtime.ErrorCode}"; }
            var loaded = runtime.Last;
            var reload = _workspace.Preview.Reload.Last;
            var stale = reload is { StaleResponseCount: > 0 } ? $" · stale={reload.StaleResponseCount}" : string.Empty;
            if (reload?.State == EditorPreviewReloadState.Requested)
            {
                return $"{reload.Target} reload pending · retained={ShortRevision(loaded?.ArtifactRevision ?? loaded?.SourceRevision)}{stale}";
            }
            if (reload?.State == EditorPreviewReloadState.Failed)
            {
                return $"{reload.Target} reload failed · {reload.ErrorCode} · retained={ShortRevision(loaded?.ArtifactRevision ?? loaded?.SourceRevision)}{stale}";
            }
            if (loaded is null) { return "Runtime loaded identity 尚不可用。"; }
            return $"{loaded.Target} loaded · source={ShortRevision(loaded.SourceRevision)} · artifact={ShortRevision(loaded.ArtifactRevision)} · sync={loaded.Consistency}{stale}";
        }
    }
    public string TextureImportStatus => _workspace.TextureImport.State switch
    {
        EditorTextureImportState.Running => "纹理导入中…",
        EditorTextureImportState.Succeeded => $"纹理导入成功 · {_workspace.TextureImport.RelativePath ?? "unknown"}",
        EditorTextureImportState.Failed => $"纹理导入失败 · {_workspace.TextureImport.ErrorCode ?? "unknown"}",
        _ => "纹理导入空闲"
    };
    public string TextureImportDetails
    {
        get
        {
            var result = _workspace.TextureImport.LastSuccessfulResult;
            if (_workspace.TextureImport.State == EditorTextureImportState.Succeeded && result is not null)
            {
                return $"source={result.SourcePath}; asset={result.AssetId}; format={result.ArtifactFormat}; bytes={result.ArtifactBytes}";
            }

            if (_workspace.TextureImport.State == EditorTextureImportState.Failed)
            {
                return _workspace.TextureImport.ErrorMessage ?? "导入失败";
            }

            return "从 Assets 面板导入外部纹理文件。";
        }
    }
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
                return $"project v1 · hierarchy v{hierarchy.SnapshotVersion}={hierarchy.Nodes.Length} · assets={assets.ItemCount}";
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
    public bool IsBusy => _workspace.Project.State is EditorProjectState.Creating or EditorProjectState.Opening or EditorProjectState.Validating
        || _workspace.ProjectSnapshot.State == EditorSnapshotState.Loading
        || _workspace.HierarchySnapshot.State == EditorSnapshotState.Loading
        || _workspace.AssetCatalogSnapshot.State == EditorSnapshotState.Loading
        || _workspace.Publication.State == EditorPublicationState.Loading
        || _workspace.TextureImport.State == EditorTextureImportState.Running
        || _workspace.Authoring.State is EditorAuthoringState.Applying or EditorAuthoringState.Undoing
        || _workspace.ScriptSource.State is EditorScriptSourceState.Loading or EditorScriptSourceState.Saving or EditorScriptSourceState.Undoing
        || _workspace.Bake.State == EditorBakeState.Running
        || _workspace.Watch.State is EditorWatchState.Starting or EditorWatchState.Stopping
        || _workspace.Preview.State is EditorPreviewState.Starting or EditorPreviewState.Stopping;
    public bool IsConnected => _workspace.ConnectionState == EditorConnectionState.Ready && _workspace.Client.IsConnected;
    public bool IsProjectOpen => _workspace.Project.Session is not null;
    public bool IsWatching => _workspace.Watch.State == EditorWatchState.Watching;
    public bool IsPreviewRunning => _workspace.Preview.State is EditorPreviewState.Starting or EditorPreviewState.Running;
    public bool IsPreviewAutoSync => _workspace.Preview.OwnsPublicationSync;
    public bool CanProjectCommand => _workspace.Capabilities.CanOpenProject && IsConnected && !IsScriptSourceDirty;
    public bool CanCreateProject => IsConnected
        && _workspace.Capabilities.CanCreateProject
        && _workspace.Watch.State == EditorWatchState.Stopped
        && _workspace.Preview.State == EditorPreviewState.Stopped
        && !IsScriptSourceDirty
        && !IsBusy;
    public bool CanApplyAuthoring => IsProjectOpen && _workspace.Capabilities.CanApplyAuthoring && !IsScriptSourceDirty;
    public bool CanUndoAuthoring => IsProjectOpen && _workspace.Capabilities.CanUndoAuthoring && _workspace.Authoring.UndoDepth > 0 && !IsScriptSourceDirty;
    public bool SupportsScriptSourceAuthoring => IsProjectOpen
        && _workspace.ProjectSnapshot.Value?.Script.SchemaVersion == 2
        && _workspace.Capabilities.CanReadScriptSource;
    public bool UsesHookScriptAuthoring => IsProjectOpen && _workspace.ProjectSnapshot.Value?.Script.SchemaVersion == 1;
    public bool CanSaveScriptSource => SupportsScriptSourceAuthoring
        && IsScriptSourceSelection
        && _workspace.Capabilities.CanEditScriptSource
        && HasScriptSourceDocument
        && IsScriptSourceDirty
        && IsScriptSourceStrictUtf8
        && ScriptSourceUtf8Bytes <= MaxScriptSourceBytes
        && !IsBusy;
    public bool CanUndoScriptSource => SupportsScriptSourceAuthoring
        && IsScriptSourceSelection
        && _workspace.Capabilities.CanUndoScriptSource
        && HasScriptSourceDocument
        && _workspace.ScriptSource.UndoDepth > 0
        && !IsScriptSourceDirty
        && !IsBusy;
    public bool CanReloadScriptSource => SupportsScriptSourceAuthoring && HasSelectedScriptDependency && !IsScriptSourceDirty && !IsBusy;
    public bool CanDiscardScriptSourceChanges => IsScriptSourceDirty && !IsBusy;
    public bool CanEditScriptSourceBuffer => IsScriptSourceSelection
        && HasScriptSourceDocument
        && _workspace.Capabilities.CanEditScriptSource
        && _workspace.ScriptSource.State is not (EditorScriptSourceState.Loading or EditorScriptSourceState.Saving or EditorScriptSourceState.Undoing);
    public bool HasSelectedSceneObject => SelectedSceneObject is not null;
    public bool CanAddSceneObject => CanApplyAuthoring && SceneObjectDrafts.Count < 64 && SceneTextureIds.Count > 0 && !IsBusy;
    public bool CanAddPatrolHazard => CanAddSceneObject
        && _workspace.ProjectSnapshot.Value is { } project
        && project.Scene.SchemaVersion != 5;
    public bool CanDeleteSelectedSceneObject => SelectedSceneObject is { } selected
        && !IsBusy
        && (selected.Kind == "sprite" || selected.Kind == "patrol_hazard" && SceneObjectDrafts.Count(draft => draft.Kind == "patrol_hazard") > 1);
    public bool CanMoveSelectedSceneObjectUp => SelectedSceneObject is { } selected && !IsBusy && SceneObjectDrafts.IndexOf(selected) > 0;
    public bool CanMoveSelectedSceneObjectDown => SelectedSceneObject is { } selected && !IsBusy
        && SceneObjectDrafts.IndexOf(selected) is var index && index >= 0 && index < SceneObjectDrafts.Count - 1;
    public string SceneObjectCountStatus => $"对象 {SceneObjectDrafts.Count}/64 · Hazard {SceneObjectDrafts.Count(draft => draft.Kind == "patrol_hazard")}";
    public bool CanRefreshSnapshots => IsProjectOpen
        && _workspace.Capabilities.CanReadProjectSnapshot
        && _workspace.Capabilities.CanReadHierarchySnapshot
        && _workspace.Capabilities.CanReadAssetCatalogSnapshot;
    public bool CanBake => _workspace.Capabilities.CanBake;
    public bool CanImportTexture => IsProjectOpen
        && _workspace.Capabilities.CanImportTexture
        && !IsBusy
        && !string.IsNullOrWhiteSpace(TextureImportSourcePath)
        && !string.IsNullOrWhiteSpace(TextureImportAssetName);
    public bool CanBakeChanges => IsProjectOpen && CanBake && _workspace.Capabilities.CanReadPublicationSnapshot && _workspace.Publication.RecommendedBakeTarget is not null && !IsWatching && !IsPreviewAutoSync && !IsBusy;
    public bool CanStartWatch => _workspace.Capabilities.CanStartWatch && !IsPreviewAutoSync;
    public bool CanStopWatch => _workspace.Capabilities.CanStopWatch;
    public bool CanRequestWatchStop => CanStopWatch
        && (_workspace.Watch.State is EditorWatchState.Watching or EditorWatchState.Failed);
    public bool CanStopPreview => _workspace.Capabilities.CanStopPreview;
    public bool CanRequestPreviewStop => CanStopPreview && (IsPreviewRunning || _workspace.Preview.State == EditorPreviewState.Failed);
    public bool CanStartPreview => _workspace.Capabilities.CanStartPreview && !IsPreviewAutoSync && !(LiveBakeEnabled && WatchChanges && IsWatching);
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

    private async Task CreateProjectAsync()
    {
        _ = await CreateProjectForCurrentInputAsync(_lifetime.Token);
    }

    // UI command 与真实 workflow 共用此公开入口，避免出现绕过 typed Workspace Client 的第二条创建路径。
    public async Task<ProjectSessionInfo> CreateProjectForCurrentInputAsync(CancellationToken cancellationToken = default)
    {
        await EnsureConnectedAsync();
        if (IsScriptSourceDirty) { throw new EditorRpcException("script_source_dirty", "请先保存或放弃行为脚本源码的未保存内容。"); }
        var effectiveToken = cancellationToken == default ? _lifetime.Token : cancellationToken;
        var session = await _workspace.CreateProjectAsync(
            new ProjectCreateParameters(PackageRoot, ProjectName),
            effectiveToken);
        if (_workspace.ProjectSnapshot.Value is not null
            && _workspace.HierarchySnapshot.Value is not null
            && _workspace.AssetCatalogSnapshot.Value is not null)
        {
            ApplySnapshotProjection(session);
        }
        RaiseAll();
        return session;
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
        if (IsScriptSourceDirty) { throw new EditorRpcException("script_source_dirty", "请先保存或放弃行为脚本源码的未保存内容。"); }
        var session = _workspace.Project.Session ?? throw new EditorRpcException("project_not_open", "请先打开项目。");
        var project = _workspace.ProjectSnapshot.Value ?? throw new EditorRpcException("snapshot_missing", "Project snapshot is not loaded.");
        var sceneTextures = ParseSceneTextureAssignments();
        var allowedTextureIds = sceneTextures?.Select(texture => texture.TextureId).ToHashSet()
            ?? (project.Scene.Textures ?? []).Select(texture => texture.TextureId).ToHashSet();
        var editsHookScript = project.Script.SchemaVersion == 1;
        var patch = new AuthoringPatch(
            ScriptGoalPosition: editsHookScript ? ParseVector(ScriptGoalX, ScriptGoalY, "script.goal.position") : null,
            ScriptGoalVelocity: editsHookScript ? ParseVector(ScriptVelocityX, ScriptVelocityY, "script.goal.velocity") : null,
            SceneTextures: sceneTextures,
            SceneObjects: ParseSceneObjectDrafts(allowedTextureIds));
        try
        {
            var result = await _workspace.ApplyAuthoringAsync(new AuthoringApplyParameters(session.ProjectName, project.AuthoringRevision, patch), cancellationToken == default ? _lifetime.Token : cancellationToken);
            ReconcileScriptSourceDocument();
            ApplySnapshotProjection(session);
            RaiseAll();
            return result;
        }
        catch (EditorRpcException exception) when (exception.Code == "authoring_revision_conflict")
        {
            await _workspace.RefreshSnapshotsAsync(session.ProjectName, cancellationToken == default ? _lifetime.Token : cancellationToken);
            ApplySnapshotProjection(session);
            RaiseAll();
            throw;
        }
    }

    private async Task UndoAuthoringAsync()
    {
        await UndoAuthoringForCurrentProjectAsync(_lifetime.Token);
    }

    public async Task<AuthoringMutationResult> UndoAuthoringForCurrentProjectAsync(CancellationToken cancellationToken = default)
    {
        await EnsureConnectedAsync();
        if (IsScriptSourceDirty) { throw new EditorRpcException("script_source_dirty", "请先保存或放弃行为脚本源码的未保存内容。"); }
        var session = _workspace.Project.Session ?? throw new EditorRpcException("project_not_open", "请先打开项目。");
        var project = _workspace.ProjectSnapshot.Value ?? throw new EditorRpcException("snapshot_missing", "Project snapshot is not loaded.");
        var result = await _workspace.UndoAuthoringAsync(new AuthoringUndoParameters(session.ProjectName, project.AuthoringRevision), cancellationToken == default ? _lifetime.Token : cancellationToken);
        ReconcileScriptSourceDocument();
        ApplySnapshotProjection(session);
        RaiseAll();
        return result;
    }

    public async Task<TextureImportResult> ImportTextureForCurrentProjectAsync(CancellationToken cancellationToken = default)
    {
        await EnsureConnectedAsync();
        var session = _workspace.Project.Session ?? throw new EditorRpcException("project_not_open", "请先打开项目。");
        var result = await _workspace.ImportTextureAsync(new TextureImportParameters(session.ProjectName, TextureImportSourcePath, TextureImportAssetName, TextureImportProfile), cancellationToken == default ? _lifetime.Token : cancellationToken);
        RefreshAssetProjection();
        if (_assetLabelsByRelativePath.TryGetValue(result.RelativePath, out var label))
        {
            SelectedAssetItem = label;
        }
        AddLog("texture_import", $"{result.RelativePath}; profile={result.Profile}; format={result.ArtifactFormat}", null, 0);
        RaiseAll();
        return result;
    }

    public async Task<ScriptSourceDocument> LoadScriptSourceForCurrentProjectAsync(uint scriptId, CancellationToken cancellationToken = default)
    {
        if (IsScriptSourceDirty) { throw new EditorRpcException("script_source_dirty", "请先保存或放弃当前未保存内容。"); }
        var selectionVersion = Interlocked.Increment(ref _scriptSourceSelectionVersion);
        var result = await ReadScriptSourceForCurrentProjectAsync(scriptId, cancellationToken);
        if (selectionVersion != Volatile.Read(ref _scriptSourceSelectionVersion)) { return result; }
        ApplyScriptSourceDocument(result);
        return result;
    }

    public async Task<ScriptSourceMutationResult> SaveScriptSourceForCurrentProjectAsync(CancellationToken cancellationToken = default)
    {
        await EnsureConnectedAsync();
        var session = _workspace.Project.Session ?? throw new EditorRpcException("project_not_open", "请先打开项目。");
        var document = _scriptSourceDocument ?? throw new EditorRpcException("script_source_not_loaded", "请先选择并加载行为脚本源码。");
        if (!IsScriptSourceDirty) { throw new EditorRpcException("script_source_unchanged", "脚本源码没有未保存修改。"); }
        if (!IsScriptSourceStrictUtf8)
        {
            throw new EditorRpcException("invalid_script_source", "脚本源码包含无法编码为严格 UTF-8 的字符。");
        }
        if (ScriptSourceUtf8Bytes > MaxScriptSourceBytes)
        {
            throw new EditorRpcException("script_source_too_large", $"脚本源码超过 {MaxScriptSourceBytes} 字节限制。");
        }
        var result = await _workspace.EditScriptSourceAsync(
            new ScriptSourceEditParameters(session.ProjectName, document.AuthoringRevision, document.ScriptId, ScriptSourceText),
            cancellationToken == default ? _lifetime.Token : cancellationToken);
        ApplyScriptSourceMutationProjection(session, result);
        return result;
    }

    private async Task SaveScriptSourceAsync() => await SaveScriptSourceForCurrentProjectAsync(_lifetime.Token);

    private async Task UndoScriptSourceAsync() => await UndoScriptSourceForCurrentProjectAsync(_lifetime.Token);

    private async Task ReloadScriptSourceAsync()
    {
        var scriptId = SelectedScriptDependencyId ?? throw new EditorRpcException("script_source_not_selected", "请先选择行为脚本依赖。");
        await LoadScriptSourceForCurrentProjectAsync(scriptId, _lifetime.Token);
    }

    private void DiscardScriptSourceChanges()
    {
        if (_scriptSourceDocument is null) { return; }
        ScriptSourceText = _scriptSourceDocument.Source;
        AddLog("script_source_discarded", $"已放弃 {_scriptSourceDocument.SourcePath} 的未保存内容。", null, 0);
    }

    private async Task<ScriptSourceDocument> ReadScriptSourceForCurrentProjectAsync(uint scriptId, CancellationToken cancellationToken)
    {
        await EnsureConnectedAsync();
        var session = _workspace.Project.Session ?? throw new EditorRpcException("project_not_open", "请先打开项目。");
        if (_workspace.ProjectSnapshot.Value?.Script.SchemaVersion != 2)
        {
            throw new EditorRpcException("invalid_script_source", "行为脚本源码编辑只支持 Script v2 项目。");
        }
        return await _workspace.ReadScriptSourceAsync(
            new ScriptSourceQueryParameters(session.ProjectName, scriptId),
            cancellationToken == default ? _lifetime.Token : cancellationToken);
    }

    private async Task LoadScriptSourceFromSelectionAsync(uint scriptId)
    {
        var selectionVersion = Interlocked.Increment(ref _scriptSourceSelectionVersion);
        var hierarchyItem = _scriptSourceHierarchyItem;
        try
        {
            var result = await ReadScriptSourceForCurrentProjectAsync(scriptId, _lifetime.Token);
            await _dispatcher.InvokeAsync(() =>
            {
                if (selectionVersion != Volatile.Read(ref _scriptSourceSelectionVersion)
                    || !string.Equals(hierarchyItem, _scriptSourceHierarchyItem, StringComparison.Ordinal)
                    || !string.Equals(hierarchyItem, SelectedHierarchyItem, StringComparison.Ordinal))
                {
                    return;
                }
                ApplyScriptSourceDocument(result);
            });
        }
        catch (OperationCanceledException) when (_lifetime.IsCancellationRequested) { }
        catch (Exception exception)
        {
            if (selectionVersion == Volatile.Read(ref _scriptSourceSelectionVersion)) { HandleCommandError(exception); }
        }
    }

    private void ApplyScriptSourceDocument(ScriptSourceDocument document)
    {
        _scriptSourceDocument = document;
        _scriptSourceText = document.Source;
        ScriptSourceCaretIndex = Math.Min(ScriptSourceCaretIndex, document.Source.Length);
        SelectedScriptDiagnostic = null;
        ObserveScriptSourceBuffer();
        RaiseAll();
    }

    private void ApplyScriptSourceMutationProjection(ProjectSessionInfo session, ScriptSourceMutationResult result)
    {
        ApplyScriptSourceDocument(result.SourceDocument);
        ApplySnapshotProjection(session, $"script.dependencies[{result.SourceDocument.ScriptId}]");
        RaiseAll();
    }

    private void ReconcileScriptSourceDocument()
    {
        if (_scriptSourceDocument is null || _workspace.ScriptSource.Document is not { } document) { return; }
        if (_scriptSourceDocument.ScriptId == document.ScriptId) { ApplyScriptSourceDocument(document); }
    }

    private void ClearScriptSourceProjection()
    {
        Interlocked.Increment(ref _scriptSourceSelectionVersion);
        _scriptSourceDocument = null;
        _scriptSourceText = string.Empty;
        _scriptSourceHierarchyItem = null;
        ScriptSourceCaretIndex = 0;
        SelectedScriptDiagnostic = null;
        _workspace.ScriptDiagnostics.Reset(!_workspace.Capabilities.CanAnalyzeScriptSource);
    }

    private void ObserveScriptSourceBuffer() => _workspace.ObserveScriptSourceBuffer(
        _scriptSourceDocument,
        _scriptSourceText,
        IsScriptSourceSelection
            && _workspace.ProjectSnapshot.Value?.Script.SchemaVersion == 2
            && _workspace.Capabilities.CanAnalyzeScriptSource);

    private static bool TryGetScriptId(HierarchyNode node, out uint scriptId)
    {
        scriptId = 0;
        if (!string.Equals(node.Kind, "ScriptDependency", StringComparison.Ordinal)
            || !node.Properties.TryGetValue("ScriptId", out var value))
        {
            return false;
        }
        if (value.ValueKind == JsonValueKind.Number && value.TryGetUInt32(out scriptId)) { return scriptId != 0; }
        return value.ValueKind == JsonValueKind.String
            && uint.TryParse(value.GetString(), System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out scriptId)
            && scriptId != 0;
    }

    private bool TryGetSelectedScriptDependency(out uint scriptId, out string sourcePath)
    {
        scriptId = 0;
        sourcePath = "正在读取行为脚本源码…";
        if (SelectedHierarchyItem is null
            || !_hierarchyItemsByLabel.TryGetValue(SelectedHierarchyItem, out var node)
            || !TryGetScriptId(node, out scriptId))
        {
            return false;
        }
        if (node.Properties.TryGetValue("Source", out var value) && value.ValueKind == JsonValueKind.String)
        {
            sourcePath = value.GetString() ?? sourcePath;
        }
        return true;
    }

    public async Task<ScriptSourceMutationResult> UndoScriptSourceForCurrentProjectAsync(CancellationToken cancellationToken = default)
    {
        await EnsureConnectedAsync();
        var session = _workspace.Project.Session ?? throw new EditorRpcException("project_not_open", "请先打开项目。");
        var document = _scriptSourceDocument ?? throw new EditorRpcException("script_source_not_loaded", "请先选择并加载行为脚本源码。");
        if (IsScriptSourceDirty) { throw new EditorRpcException("script_source_dirty", "撤销前请先保存或放弃当前未保存内容。"); }
        var result = await _workspace.UndoScriptSourceAsync(
            new ScriptSourceUndoParameters(session.ProjectName, document.AuthoringRevision),
            cancellationToken == default ? _lifetime.Token : cancellationToken);
        ApplyScriptSourceMutationProjection(session, result);
        return result;
    }

    private static uint ParseTextureId(string value, string field)
    {
        if (!uint.TryParse(value, System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out var textureId) || textureId == 0)
        {
            throw new EditorRpcException("invalid_authoring_patch", $"{field} 必须为非零 TextureId。");
        }
        return textureId;
    }

    private static double[] ParseVector(string x, string y, string field)
        => [ParseFiniteNumber(x, $"{field}[0]"), ParseFiniteNumber(y, $"{field}[1]")];

    private IReadOnlyList<SceneTextureAssignment>? ParseSceneTextureAssignments()
    {
        var assignments = new List<SceneTextureAssignment>();
        if (SceneTextureAssignments.All(slot => slot.IsEmpty)) { return null; }
        if (SceneTextureAssignments[0].IsEmpty)
        {
            throw new EditorRpcException("invalid_authoring_patch", "Scene texture assignments must begin with the first slot.");
        }

        for (var index = 0; index < SceneTextureAssignments.Count; index++)
        {
            var slot = SceneTextureAssignments[index];
            var textureIdText = slot.TextureIdText.Trim();
            var selectedAssetItem = slot.SelectedAssetItem?.Trim();
            var hasTextureId = textureIdText.Length > 0;
            var hasAsset = !string.IsNullOrWhiteSpace(selectedAssetItem);
            if (!hasTextureId && !hasAsset)
            {
                if (assignments.Count > 0)
                {
                    for (var trailing = index + 1; trailing < SceneTextureAssignments.Count; trailing++)
                    {
                        if (!SceneTextureAssignments[trailing].IsEmpty)
                        {
                            throw new EditorRpcException("invalid_authoring_patch", "Scene texture assignments must remain contiguous from the first slot.");
                        }
                    }
                    break;
                }
                continue;
            }

            if (!hasTextureId || !hasAsset)
            {
                throw new EditorRpcException("invalid_authoring_patch", $"scene.textures[{index + 1}] requires both TextureId and Asset selection.");
            }
            if (!_assetItemsByLabel.TryGetValue(selectedAssetItem!, out var asset))
            {
                throw new EditorRpcException("invalid_authoring_patch", $"scene.textures[{index + 1}] must select an asset from the current catalog.");
            }
            assignments.Add(new SceneTextureAssignment(ParseTextureId(textureIdText, $"scene.textures[{index + 1}].textureId"), asset.AssetId));
        }

        return assignments.Count == 0 ? null : assignments;
    }

    private IReadOnlyList<SceneObjectDefinition> ParseSceneObjectDrafts(IReadOnlySet<uint> allowedTextureIds)
    {
        if (SceneObjectDrafts.Count is < 3 or > 64)
        {
            throw new EditorRpcException("invalid_authoring_patch", "scene.objects 必须包含 3 到 64 个对象。");
        }
        if (allowedTextureIds.Count is < 1 or > 4)
        {
            throw new EditorRpcException("invalid_authoring_patch", "Scene texture set 必须包含 1 到 4 个 TextureId。");
        }

        var objectIds = new HashSet<string>(StringComparer.Ordinal);
        var definitions = new List<SceneObjectDefinition>(SceneObjectDrafts.Count);
        var playerCount = 0;
        var goalCount = 0;
        var hazardCount = 0;
        foreach (var draft in SceneObjectDrafts)
        {
            var objectId = draft.ObjectId.Trim();
            if (!Regex.IsMatch(objectId, "^[a-z][a-z0-9_-]{0,62}$", RegexOptions.CultureInvariant))
            {
                throw new EditorRpcException("invalid_authoring_patch", $"无效 ObjectId：{objectId}。");
            }
            if (!objectIds.Add(objectId))
            {
                throw new EditorRpcException("invalid_authoring_patch", $"ObjectId 重复：{objectId}。");
            }

            var position = ParseVector(draft.PositionX, draft.PositionY, $"scene.objects[{objectId}].position");
            var size = ParseVector(draft.SizeX, draft.SizeY, $"scene.objects[{objectId}].size");
            if (size.Any(value => value <= 0))
            {
                throw new EditorRpcException("invalid_authoring_patch", $"scene.objects[{objectId}].size 必须大于零。");
            }
            var color = new[]
            {
                ParseFiniteNumber(draft.ColorR, $"scene.objects[{objectId}].color[0]"),
                ParseFiniteNumber(draft.ColorG, $"scene.objects[{objectId}].color[1]"),
                ParseFiniteNumber(draft.ColorB, $"scene.objects[{objectId}].color[2]"),
                ParseFiniteNumber(draft.ColorA, $"scene.objects[{objectId}].color[3]")
            };
            if (color.Any(value => value is < 0 or > 1))
            {
                throw new EditorRpcException("invalid_authoring_patch", $"scene.objects[{objectId}].color 必须位于 [0, 1]。");
            }
            var textureId = ParseTextureId(draft.TextureIdText, $"scene.objects[{objectId}].textureId");
            if (!allowedTextureIds.Contains(textureId))
            {
                throw new EditorRpcException("invalid_authoring_patch", $"scene.objects[{objectId}].textureId 不在当前 Scene texture set 中。");
            }

            double? moveSpeed = null;
            double? patrolMinY = null;
            double? patrolMaxY = null;
            double? patrolSpeed = null;
            var behaviors = draft.CreateBehaviorDefinitions();
            switch (draft.Kind)
            {
                case "sprite":
                    break;
                case "player":
                    playerCount++;
                    moveSpeed = ParseNonNegativeNumber(draft.MoveSpeed, $"scene.objects[{objectId}].moveSpeed");
                    break;
                case "goal":
                    goalCount++;
                    break;
                case "patrol_hazard":
                    hazardCount++;
                    if (draft.UsesNativePatrol)
                    {
                        patrolMinY = ParseFiniteNumber(draft.PatrolMinY, $"scene.objects[{objectId}].patrol.minY");
                        patrolMaxY = ParseFiniteNumber(draft.PatrolMaxY, $"scene.objects[{objectId}].patrol.maxY");
                        patrolSpeed = ParseNonNegativeNumber(draft.PatrolSpeed, $"scene.objects[{objectId}].patrol.speed");
                        if (patrolMinY >= patrolMaxY || position[1] < patrolMinY || position[1] > patrolMaxY)
                        {
                            throw new EditorRpcException("invalid_authoring_patch", $"scene.objects[{objectId}] 的 Patrol 范围或初始 Y 无效。");
                        }
                    }
                    break;
                default:
                    throw new EditorRpcException("invalid_authoring_patch", $"不支持的 Object Kind：{draft.Kind}。");
            }

            definitions.Add(new SceneObjectDefinition(
                objectId,
                draft.Kind,
                position,
                size,
                color,
                textureId,
                moveSpeed,
                patrolMinY,
                patrolMaxY,
                patrolSpeed,
                behaviors));
        }
        if (playerCount != 1 || goalCount != 1 || hazardCount < 1)
        {
            throw new EditorRpcException("invalid_authoring_patch", "scene.objects 必须恰好包含一个 Player、一个 Goal，并至少包含一个 Patrol Hazard。");
        }
        return definitions;
    }

    public void AddDecorativeSpriteDraft()
    {
        if (!CanAddSceneObject) { return; }
        AddSceneObjectDraft(SceneObjectDraftViewModel.NewSprite(NextObjectId("decoration"), SceneTextureIds[0], SceneTextureIds));
    }

    public void AddPatrolHazardDraft()
    {
        if (!CanAddPatrolHazard) { return; }
        AddSceneObjectDraft(SceneObjectDraftViewModel.NewPatrolHazard(NextObjectId("hazard"), SceneTextureIds[0], SceneTextureIds));
    }

    public void DeleteSelectedSceneObjectDraft()
    {
        if (!CanDeleteSelectedSceneObject || SelectedSceneObject is not { } selected) { return; }
        var index = SceneObjectDrafts.IndexOf(selected);
        selected.PropertyChanged -= OnSceneObjectDraftPropertyChanged;
        SceneObjectDrafts.RemoveAt(index);
        SelectedSceneObject = SceneObjectDrafts.Count == 0 ? null : SceneObjectDrafts[Math.Min(index, SceneObjectDrafts.Count - 1)];
        RaiseAll();
    }

    public void MoveSelectedSceneObjectUp()
    {
        if (!CanMoveSelectedSceneObjectUp || SelectedSceneObject is not { } selected) { return; }
        var index = SceneObjectDrafts.IndexOf(selected);
        SceneObjectDrafts.Move(index, index - 1);
        RaiseAll();
    }

    public void MoveSelectedSceneObjectDown()
    {
        if (!CanMoveSelectedSceneObjectDown || SelectedSceneObject is not { } selected) { return; }
        var index = SceneObjectDrafts.IndexOf(selected);
        SceneObjectDrafts.Move(index, index + 1);
        RaiseAll();
    }

    private void AddSceneObjectDraft(SceneObjectDraftViewModel draft)
    {
        draft.PropertyChanged += OnSceneObjectDraftPropertyChanged;
        SceneObjectDrafts.Add(draft);
        SelectedSceneObject = draft;
        RaiseAll();
    }

    private string NextObjectId(string prefix)
    {
        var existing = SceneObjectDrafts.Select(draft => draft.ObjectId).ToHashSet(StringComparer.Ordinal);
        for (var suffix = 1; suffix < 10000; suffix++)
        {
            var candidate = $"{prefix}-{suffix}";
            if (!existing.Contains(candidate)) { return candidate; }
        }
        throw new InvalidOperationException($"无法为 {prefix} 分配新的 ObjectId。");
    }

    private static double ParseFiniteNumber(string value, string field)
    {
        if (!double.TryParse(value, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var parsed)
            || !double.IsFinite(parsed) || !float.IsFinite((float)parsed))
        {
            throw new EditorRpcException("invalid_authoring_patch", $"{field} 必须是有限 f32 数值。");
        }
        return parsed;
    }

    private static double ParseNonNegativeNumber(string value, string field)
    {
        var parsed = ParseFiniteNumber(value, field);
        if (parsed < 0) { throw new EditorRpcException("invalid_authoring_patch", $"{field} 不能为负数。"); }
        return parsed;
    }

    private void ApplySnapshotProjection(ProjectSessionInfo session, string? preferredHierarchyNodeId = null)
    {
        var project = _workspace.ProjectSnapshot.Value ?? throw new InvalidOperationException("Project snapshot is missing.");
        var hierarchy = _workspace.HierarchySnapshot.Value ?? throw new InvalidOperationException("Hierarchy snapshot is missing.");
        var assets = _workspace.AssetCatalogSnapshot.Value ?? throw new InvalidOperationException("Asset Catalog snapshot is missing.");
        if (hierarchy.SnapshotVersion != EditorSnapshotVersions.Hierarchy)
        {
            throw new InvalidOperationException($"Unsupported Hierarchy Snapshot version: {hierarchy.SnapshotVersion}.");
        }
        if (project.Scene.Objects is null)
        {
            throw new InvalidOperationException("Project snapshot does not expose Scene Objects.");
        }

        if (preferredHierarchyNodeId is null
            && SelectedHierarchyItem is not null
            && _hierarchyItemsByLabel.TryGetValue(SelectedHierarchyItem, out var selectedNode))
        {
            preferredHierarchyNodeId = selectedNode.Id;
        }

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

        PopulateAssetProjection(assets);

        _allowScriptSourceSelectionChange = true;
        try
        {
            SelectedHierarchyItem = null;
            SelectedAssetItem = null;
            InspectorText = $"Project\n{project.ProjectName}\n\nModelVersion: {project.ModelVersion}\nPackage root: {session.PackageRoot}";
            SetAuthoringFields(project);
            if (project.Script.SchemaVersion != 2 || !_workspace.Capabilities.CanReadScriptSource) { ClearScriptSourceProjection(); }
            var defaultHierarchy = _hierarchyItemsByLabel.FirstOrDefault(pair => pair.Value.Id == preferredHierarchyNodeId).Key
                ?? _hierarchyItemsByLabel.FirstOrDefault(pair => pair.Value.Id == "scene.objects[goal]").Key
                ?? _hierarchyItemsByLabel.Keys.FirstOrDefault();
            if (defaultHierarchy is not null) { SelectedHierarchyItem = defaultHierarchy; }
        }
        finally { _allowScriptSourceSelectionChange = false; }
    }

    private void InvalidateProjectProjection()
    {
        // Workspace 已先切换权威 Session；Avalonia 必须同步丢弃所有旧 identity 的复制缓存。
        HierarchyItems.Clear();
        _hierarchyItemsByLabel.Clear();
        AssetItems.Clear();
        _assetItemsByLabel.Clear();
        _assetLabelsByRelativePath.Clear();
        _allowScriptSourceSelectionChange = true;
        try { SelectedHierarchyItem = null; }
        finally { _allowScriptSourceSelectionChange = false; }
        SelectedAssetItem = null;
        ClearSceneObjectDrafts();
        SceneTextureIds.Clear();
        InspectorText = string.Empty;
        SceneGoalX = string.Empty;
        SceneGoalY = string.Empty;
        ScriptGoalX = string.Empty;
        ScriptGoalY = string.Empty;
        ScriptVelocityX = string.Empty;
        ScriptVelocityY = string.Empty;
        ClearScriptSourceProjection();
        ClearSceneTextureAssignments();
    }

    private void ReconcileProjectIdentity()
    {
        var next = EditorProjectIdentity.From(_workspace.Project.Session);
        if (EditorProjectIdentity.Matches(_projectIdentity, next)) { return; }
        _projectIdentity = next;
        InvalidateProjectProjection();
    }

    private void SetAuthoringFields(ProjectModelSnapshot project)
    {
        SceneGoalX = project.Scene.GoalPosition[0].ToString("0.###", System.Globalization.CultureInfo.InvariantCulture);
        SceneGoalY = project.Scene.GoalPosition[1].ToString("0.###", System.Globalization.CultureInfo.InvariantCulture);
        ScenePlayerTextureId = project.Scene.PlayerTextureId.ToString(System.Globalization.CultureInfo.InvariantCulture);
        SceneGoalTextureId = project.Scene.GoalTextureId.ToString(System.Globalization.CultureInfo.InvariantCulture);
        SceneHazardTextureId = project.Scene.HazardTextureId.ToString(System.Globalization.CultureInfo.InvariantCulture);
        if (project.Script.SchemaVersion == 1)
        {
            ScriptGoalX = project.Script.GoalPosition[0].ToString("0.###", System.Globalization.CultureInfo.InvariantCulture);
            ScriptGoalY = project.Script.GoalPosition[1].ToString("0.###", System.Globalization.CultureInfo.InvariantCulture);
            ScriptVelocityX = project.Script.GoalVelocity[0].ToString("0.###", System.Globalization.CultureInfo.InvariantCulture);
            ScriptVelocityY = project.Script.GoalVelocity[1].ToString("0.###", System.Globalization.CultureInfo.InvariantCulture);
        }
        else
        {
            ScriptGoalX = string.Empty;
            ScriptGoalY = string.Empty;
            ScriptVelocityX = string.Empty;
            ScriptVelocityY = string.Empty;
        }
        SetSceneTextureAssignments(project);
        SetSceneObjectDrafts(project.Scene.Objects ?? throw new InvalidOperationException("Project snapshot does not expose Scene Objects."));
    }
    private void ApplySessionProjection(ProjectSessionInfo session)
    {
        // 兼容旧 Service；26C+ Service 会走真实 snapshot 分支，26D mutation 仍需要独立 capability。
        HierarchyItems.Clear();
        _hierarchyItemsByLabel.Clear();
        HierarchyItems.Add($"Project / {session.ProjectName}");
        AssetItems.Clear();
        _assetItemsByLabel.Clear();
        _assetLabelsByRelativePath.Clear();
        AssetItems.Add(Path.GetFileName(session.ScenePath));
        AssetItems.Add(Path.GetFileName(session.ScriptPath));
        AssetItems.Add(Path.GetFileName(session.PreviewPath));
        InspectorText = $"Project\n{session.ProjectName}\n\nSnapshot commands unavailable.";
        ClearScriptSourceProjection();
        ClearSceneObjectDrafts();
        SceneTextureIds.Clear();
        ClearSceneTextureAssignments();
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
    private async Task BakeChangesAsync()
    {
        var result = await _workspace.BakeChangesAsync(BakeProfile, _lifetime.Token);
        AddLog("bake_changes", result is null ? "derived artifacts already current" : $"target={result.Target}; profile={result.Profile}", null, 0);
        RaiseAll();
    }
    private async Task StartWatchAsync() { await _workspace.StartWatchAsync(new WatchStartParameters(BakeTarget, BakeProfile), _lifetime.Token); RaiseAll(); }
    private async Task StopWatchAsync() { await _workspace.StopWatchAsync(_lifetime.Token); RaiseAll(); }
    private async Task StartPreviewAsync()
    {
        await _workspace.StartPreviewAsync(new PreviewStartParameters(ProjectName: ProjectName, WatchChanges: WatchChanges, LiveBake: LiveBakeEnabled, BakeProfile: BakeProfile), _lifetime.Token);
        RaiseAll();
    }
    private async Task StopPreviewAsync() { await _workspace.StopPreviewAsync(_lifetime.Token); RaiseAll(); }
    private async Task ImportTextureAsync() { await ImportTextureForCurrentProjectAsync(_lifetime.Token); }

    private static string ShortRevision(string? revision) => revision is { Length: >= 12 } ? $"{revision[..12]}…" : "—";

    private void SetSceneTextureAssignments(ProjectModelSnapshot project)
    {
        var textures = project.Scene.Textures ?? [];
        for (var index = 0; index < SceneTextureAssignments.Count; index++)
        {
            if (index < textures.Count)
            {
                var texture = textures[index];
                _assetLabelsByRelativePath.TryGetValue(texture.Artifact, out var label);
                SceneTextureAssignments[index].SetValue(texture.TextureId.ToString(System.Globalization.CultureInfo.InvariantCulture), label);
            }
            else
            {
                SceneTextureAssignments[index].Clear();
            }
        }
        RefreshSceneTextureChoicesFromSlots();
    }

    private void ClearSceneTextureAssignments()
    {
        foreach (var slot in SceneTextureAssignments) { slot.Clear(); }
        SceneTextureIds.Clear();
    }

    private void SetSceneObjectDrafts(IReadOnlyList<ProjectModelSceneObject> objects)
    {
        ClearSceneObjectDrafts();
        foreach (var sceneObject in objects)
        {
            var draft = SceneObjectDraftViewModel.FromSnapshot(sceneObject, SceneTextureIds);
            draft.PropertyChanged += OnSceneObjectDraftPropertyChanged;
            SceneObjectDrafts.Add(draft);
        }
        SelectedSceneObject = null;
        RaiseAll();
    }

    private void ClearSceneObjectDrafts()
    {
        foreach (var draft in SceneObjectDrafts) { draft.PropertyChanged -= OnSceneObjectDraftPropertyChanged; }
        SceneObjectDrafts.Clear();
        SelectedSceneObject = null;
    }

    private void RefreshSceneTextureChoicesFromSlots()
    {
        var values = new List<string>();
        foreach (var slot in SceneTextureAssignments)
        {
            var value = slot.TextureIdText.Trim();
            if (uint.TryParse(value, System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out var textureId)
                && textureId != 0)
            {
                var normalized = textureId.ToString(System.Globalization.CultureInfo.InvariantCulture);
                if (!values.Contains(normalized, StringComparer.Ordinal)) { values.Add(normalized); }
            }
        }
        SceneTextureIds.Clear();
        foreach (var value in values) { SceneTextureIds.Add(value); }
        RaiseAll();
    }

    private void RefreshAssetProjection()
    {
        var assets = _workspace.AssetCatalogSnapshot.Value;
        if (assets is null) { return; }
        PopulateAssetProjection(assets);
        if (SelectedAssetItem is not null && !_assetItemsByLabel.ContainsKey(SelectedAssetItem))
        {
            SelectedAssetItem = null;
        }
    }

    private void PopulateAssetProjection(AssetCatalogSnapshot assets)
    {
        AssetItems.Clear();
        _assetItemsByLabel.Clear();
        _assetLabelsByRelativePath.Clear();
        foreach (var item in assets.Items)
        {
            var label = $"{item.Category} · {item.RelativePath}";
            AssetItems.Add(label);
            _assetItemsByLabel.Add(label, item);
            _assetLabelsByRelativePath[item.RelativePath] = label;
        }
    }

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
            var eventName = notification.Event;
            if (notification.Event == "preview_status"
                && notification.Data is { ValueKind: JsonValueKind.Object } previewStatus
                && previewStatus.TryGetProperty("event", out var nestedEvent)
                && nestedEvent.ValueKind == JsonValueKind.String
                && !string.IsNullOrWhiteSpace(nestedEvent.GetString()))
            {
                eventName = nestedEvent.GetString()!;
            }
            AddLog(eventName, summary.Length <= 240 ? summary : summary[..237] + "…", notification.RequestId, notification.Sequence);
            RaiseAll();
        });
    }

    private void OnWorkspacePropertyChanged(object? sender, PropertyChangedEventArgs e) { RaiseAll(); }
    private void OnTextureAssignmentPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(TextureAssignmentSlotViewModel.TextureIdText)) { RefreshSceneTextureChoicesFromSlots(); }
    }
    private void OnSceneObjectDraftPropertyChanged(object? sender, PropertyChangedEventArgs e) { RaiseAll(); }
    private void OnProjectPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(EditorProjectViewModel.Session)) { ReconcileProjectIdentity(); }
        RaiseAll();
    }
    private void OnNestedPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (ReferenceEquals(sender, _workspace.ScriptDiagnostics)
            && e.PropertyName == nameof(EditorScriptDiagnosticsViewModel.Items))
        {
            SelectedScriptDiagnostic = null;
        }
        RaiseAll();
    }
    private void HandleCommandError(Exception exception) => _ = _dispatcher.InvokeAsync(() => AddLog("command_failed", exception.Message, null, 0));
    private void AddLog(string eventName, string summary, string? requestId, long sequence) { EventLog.Add(new EditorEventLogItem(sequence, eventName, summary, requestId, DateTimeOffset.Now)); while (EventLog.Count > 200) { EventLog.RemoveAt(0); } }
    private AsyncUiCommand AddCommand(AsyncUiCommand command) { _commands.Add(command); return command; }
    private DelegateUiCommand AddCommand(DelegateUiCommand command) { _localCommands.Add(command); return command; }
    private void OnPropertyChanged(string propertyName) => RaisePropertyChanged(propertyName);
    private void RaiseAll()
    {
        foreach (var command in _commands) { command.RaiseCanExecuteChanged(); }
        foreach (var command in _localCommands) { command.RaiseCanExecuteChanged(); }
        OnPropertyChanged(nameof(ConnectionStatus));
        OnPropertyChanged(nameof(ValidationStatus));
        OnPropertyChanged(nameof(ValidationDiagnostics));
        OnPropertyChanged(nameof(BakeStatus));
        OnPropertyChanged(nameof(PublicationStatus));
        OnPropertyChanged(nameof(PreviewStatus));
        OnPropertyChanged(nameof(RuntimeSyncStatus));
        OnPropertyChanged(nameof(TextureImportStatus));
        OnPropertyChanged(nameof(TextureImportDetails));
        OnPropertyChanged(nameof(SurfaceMode));
        OnPropertyChanged(nameof(SurfaceDetails));
        OnPropertyChanged(nameof(SnapshotStatus));
        OnPropertyChanged(nameof(AuthoringStatus));
        OnPropertyChanged(nameof(AuthoringRevisionStatus));
        OnPropertyChanged(nameof(CapabilitySummary));
        OnPropertyChanged(nameof(SceneObjectCountStatus));
        OnPropertyChanged(nameof(HasSelectedSceneObject));
        OnPropertyChanged(nameof(IsBusy));
        OnPropertyChanged(nameof(IsConnected));
        OnPropertyChanged(nameof(IsProjectOpen));
        OnPropertyChanged(nameof(IsWatching));
        OnPropertyChanged(nameof(IsPreviewRunning));
        OnPropertyChanged(nameof(IsPreviewAutoSync));
        OnPropertyChanged(nameof(CanProjectCommand));
        OnPropertyChanged(nameof(CanCreateProject));
        OnPropertyChanged(nameof(CanApplyAuthoring));
        OnPropertyChanged(nameof(CanUndoAuthoring));
        OnPropertyChanged(nameof(SupportsScriptSourceAuthoring));
        OnPropertyChanged(nameof(UsesHookScriptAuthoring));
        OnPropertyChanged(nameof(CanSaveScriptSource));
        OnPropertyChanged(nameof(CanUndoScriptSource));
        OnPropertyChanged(nameof(CanReloadScriptSource));
        OnPropertyChanged(nameof(CanDiscardScriptSourceChanges));
        OnPropertyChanged(nameof(CanEditScriptSourceBuffer));
        OnPropertyChanged(nameof(ScriptSourceText));
        OnPropertyChanged(nameof(SelectedScriptSourceId));
        OnPropertyChanged(nameof(SelectedScriptDependencyId));
        OnPropertyChanged(nameof(HasSelectedScriptDependency));
        OnPropertyChanged(nameof(IsScriptSourceSelection));
        OnPropertyChanged(nameof(ScriptSourcePath));
        OnPropertyChanged(nameof(ScriptSourceRevisionStatus));
        OnPropertyChanged(nameof(HasScriptSourceDocument));
        OnPropertyChanged(nameof(IsScriptSourceDirty));
        OnPropertyChanged(nameof(ScriptSourceUtf8Bytes));
        OnPropertyChanged(nameof(IsScriptSourceStrictUtf8));
        OnPropertyChanged(nameof(ScriptSourceStatus));
        OnPropertyChanged(nameof(ScriptSourceCaretIndex));
        OnPropertyChanged(nameof(SelectedScriptDiagnostic));
        OnPropertyChanged(nameof(ScriptDiagnostics));
        OnPropertyChanged(nameof(HasScriptDiagnostics));
        OnPropertyChanged(nameof(ScriptDiagnosticsStatus));
        OnPropertyChanged(nameof(CanAddSceneObject));
        OnPropertyChanged(nameof(CanAddPatrolHazard));
        OnPropertyChanged(nameof(CanDeleteSelectedSceneObject));
        OnPropertyChanged(nameof(CanMoveSelectedSceneObjectUp));
        OnPropertyChanged(nameof(CanMoveSelectedSceneObjectDown));
        OnPropertyChanged(nameof(CanRefreshSnapshots));
        OnPropertyChanged(nameof(CanBake));
        OnPropertyChanged(nameof(CanImportTexture));
        OnPropertyChanged(nameof(CanBakeChanges));
        OnPropertyChanged(nameof(CanStartWatch));
        OnPropertyChanged(nameof(CanStopWatch));
        OnPropertyChanged(nameof(CanRequestWatchStop));
        OnPropertyChanged(nameof(CanStopPreview));
        OnPropertyChanged(nameof(CanRequestPreviewStop));
        OnPropertyChanged(nameof(CanStartPreview));
        OnPropertyChanged(nameof(SupportsExternalWindow));
        OnPropertyChanged(nameof(SupportsSharedTexture));
        OnPropertyChanged(nameof(SupportsFrameStream));
    }

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

public sealed class TextureAssignmentSlotViewModel : ObservableObject
{
    private ObservableCollection<string> _assetItems = [];
    private string _textureIdText = string.Empty;
    private string? _selectedAssetItem;

    public TextureAssignmentSlotViewModel(string slotLabel) => SlotLabel = slotLabel;

    public string SlotLabel { get; }
    public ObservableCollection<string> AssetItems { get => _assetItems; set => SetProperty(ref _assetItems, value); }
    public string TextureIdText
    {
        get => _textureIdText;
        set
        {
            if (SetProperty(ref _textureIdText, value)) { RaisePropertyChanged(nameof(IsEmpty)); }
        }
    }
    public string? SelectedAssetItem
    {
        get => _selectedAssetItem;
        set
        {
            if (SetProperty(ref _selectedAssetItem, value)) { RaisePropertyChanged(nameof(IsEmpty)); }
        }
    }
    public bool IsEmpty => string.IsNullOrWhiteSpace(TextureIdText) && string.IsNullOrWhiteSpace(SelectedAssetItem);

    public void SetValue(string textureIdText, string? selectedAssetItem)
    {
        TextureIdText = textureIdText;
        SelectedAssetItem = selectedAssetItem;
    }

    public void Clear()
    {
        TextureIdText = string.Empty;
        SelectedAssetItem = null;
    }
}

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
    private readonly Func<bool> _canExecute;
    public DelegateUiCommand(Action execute, Func<bool>? canExecute = null)
    {
        _execute = execute;
        _canExecute = canExecute ?? (() => true);
    }
    public event EventHandler? CanExecuteChanged;
    public bool CanExecute(object? parameter) => _canExecute();
    public void Execute(object? parameter) { if (CanExecute(parameter)) { _execute(); } }
    public void RaiseCanExecuteChanged() => CanExecuteChanged?.Invoke(this, EventArgs.Empty);
}
