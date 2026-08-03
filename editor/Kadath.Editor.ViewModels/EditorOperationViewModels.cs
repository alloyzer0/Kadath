using Kadath.Editor.Protocol;

namespace Kadath.Editor.ViewModels;

public enum EditorProjectState { Closed, Opening, Opened, Validating, Valid, Invalid, Failed, Creating, OutcomeUnknown }
public enum EditorBakeState { Idle, Running, Succeeded, Failed }
public enum EditorWatchState { Stopped, Starting, Watching, Stopping, Failed }
public enum EditorPreviewState { Stopped, Starting, Running, Stopping, Failed }

public sealed class EditorProjectIdentity
{
    private EditorProjectIdentity(string packageRoot, string projectName)
    {
        PackageRoot = packageRoot;
        ProjectName = projectName;
    }

    public string PackageRoot { get; }
    public string ProjectName { get; }

    public static EditorProjectIdentity? From(ProjectSessionInfo? session) => session is null
        ? null
        : new EditorProjectIdentity(
            NormalizePackageRoot(session.PackageRoot),
            session.ProjectName);

    public static bool Matches(ProjectSessionInfo? left, ProjectSessionInfo? right) =>
        Matches(From(left), From(right));

    public static bool Matches(ProjectSessionInfo? left, string packageRoot, string projectName) =>
        Matches(From(left), new EditorProjectIdentity(
            NormalizePackageRoot(packageRoot),
            projectName));

    public static bool Matches(EditorProjectIdentity? left, EditorProjectIdentity? right)
    {
        if (ReferenceEquals(left, right)) { return true; }
        if (left is null || right is null) { return false; }
        // Windows package identity 不区分路径大小写；项目名沿用现有 v1 session 的兼容规则。
        return string.Equals(left.PackageRoot, right.PackageRoot, StringComparison.OrdinalIgnoreCase)
            && string.Equals(left.ProjectName, right.ProjectName, StringComparison.OrdinalIgnoreCase);
    }

    private static string NormalizePackageRoot(string packageRoot)
    {
        if (packageRoot.Length >= 3
            && char.IsAsciiLetter(packageRoot[0])
            && packageRoot[1] == ':'
            && packageRoot[2] is '/' or '\\')
        {
            var segments = new List<string>();
            foreach (var segment in packageRoot[3..].Split(['/', '\\'], StringSplitOptions.RemoveEmptyEntries))
            {
                if (segment == ".") continue;
                if (segment == "..")
                {
                    if (segments.Count > 0) segments.RemoveAt(segments.Count - 1);
                    continue;
                }
                segments.Add(segment);
            }
            var drive = char.ToUpperInvariant(packageRoot[0]);
            return segments.Count == 0 ? $"{drive}:/" : $"{drive}:/{string.Join('/', segments)}";
        }
        return Path.TrimEndingDirectorySeparator(Path.GetFullPath(packageRoot));
    }
}

public sealed class EditorProjectViewModel : ObservableObject
{
    private EditorProjectState _state = EditorProjectState.Closed;
    private ProjectSessionInfo? _session;
    private IReadOnlyList<string> _diagnostics = Array.Empty<string>();
    private string? _errorCode;
    private string? _errorMessage;

    public EditorProjectState State { get => _state; private set => SetProperty(ref _state, value); }
    public ProjectSessionInfo? Session { get => _session; private set => SetProperty(ref _session, value); }
    public string? ProjectName => Session?.ProjectName;
    public string? PackageRoot => Session?.PackageRoot;
    public string? ProjectDirectory => Session?.ProjectDirectory;
    public string? ScenePath => Session?.ScenePath;
    public string? ScriptPath => Session?.ScriptPath;
    public string? PreviewPath => Session?.PreviewPath;
    public IReadOnlyList<string> Diagnostics { get => _diagnostics; private set => SetProperty(ref _diagnostics, value); }
    public string? ErrorCode { get => _errorCode; private set => SetProperty(ref _errorCode, value); }
    public string? ErrorMessage { get => _errorMessage; private set => SetProperty(ref _errorMessage, value); }

    internal void BeginCreate()
    {
        // Create 提交前保留最近确认的 Session；只有成功事件/响应才能替换它。
        State = EditorProjectState.Creating;
        ClearError();
    }

    internal void ApplyCreateOutcomeUnknown()
    {
        // project_created 可能先于本地取消 catch 到达，已确认的 Opened 状态不得倒退。
        if (State != EditorProjectState.Creating) { return; }
        ErrorCode = "project_create_outcome_unknown";
        ErrorMessage = "The local project_create wait was cancelled; the remote outcome is still unknown.";
        State = EditorProjectState.OutcomeUnknown;
    }

    internal void BeginOpen()
    {
        State = EditorProjectState.Opening;
        ClearError();
    }

    internal void ApplyOpened(ProjectSessionInfo session)
    {
        StageOpened(session);
        PublishStagedOpened();
    }

    internal void StageOpened(ProjectSessionInfo session)
    {
        // Workspace 原子 session 切换先直接提交 backing state，再统一发布可观察通知。
        _session = session;
        _state = EditorProjectState.Opened;
        _diagnostics = Array.Empty<string>();
        _errorCode = null;
        _errorMessage = null;
    }

    internal void PublishStagedOpened()
    {
        RaisePropertyChanged(nameof(Session));
        RaisePropertyChanged(nameof(State));
        RaisePropertyChanged(nameof(Diagnostics));
        RaisePropertyChanged(nameof(ErrorCode));
        RaisePropertyChanged(nameof(ErrorMessage));
        RaiseSessionProperties();
    }

    internal void BeginValidate()
    {
        State = EditorProjectState.Validating;
        ClearError();
    }

    internal void ApplyValidation(ProjectValidateResult result)
    {
        Diagnostics = result.Diagnostics;
        State = string.Equals(result.State, "valid", StringComparison.OrdinalIgnoreCase)
            ? EditorProjectState.Valid
            : EditorProjectState.Invalid;
        ClearError();
    }

    internal void ApplyFailure(string code, string message)
    {
        ErrorCode = code;
        ErrorMessage = message;
        State = EditorProjectState.Failed;
    }

    private void ClearError()
    {
        ErrorCode = null;
        ErrorMessage = null;
    }

    private void RaiseSessionProperties()
    {
        RaisePropertyChanged(nameof(ProjectName));
        RaisePropertyChanged(nameof(PackageRoot));
        RaisePropertyChanged(nameof(ProjectDirectory));
        RaisePropertyChanged(nameof(ScenePath));
        RaisePropertyChanged(nameof(ScriptPath));
        RaisePropertyChanged(nameof(PreviewPath));
    }
}

public sealed class EditorBakeViewModel : ObservableObject
{
    private EditorBakeState _state;
    private string _target = "Both";
    private string _profile = "debug";
    private string? _sourceRevision;
    private EditorBakeResult? _lastSuccessfulResult;
    private string? _errorCode;
    private string? _errorMessage;
    private bool _retainedPreviousArtifact;

    public EditorBakeState State { get => _state; private set => SetProperty(ref _state, value); }
    public string Target { get => _target; private set => SetProperty(ref _target, value); }
    public string Profile { get => _profile; private set => SetProperty(ref _profile, value); }
    public string? SourceRevision { get => _sourceRevision; private set => SetProperty(ref _sourceRevision, value); }
    public EditorBakeResult? LastSuccessfulResult { get => _lastSuccessfulResult; private set => SetProperty(ref _lastSuccessfulResult, value); }
    public string? SceneArtifactRevision => LastSuccessfulResult?.SceneArtifactRevision;
    public string? ScriptArtifactRevision => LastSuccessfulResult?.ScriptArtifactRevision;
    public int? SceneArtifactBytes => LastSuccessfulResult?.SceneArtifactBytes;
    public int? ScriptArtifactBytes => LastSuccessfulResult?.ScriptArtifactBytes;
    public string? ErrorCode { get => _errorCode; private set => SetProperty(ref _errorCode, value); }
    public string? ErrorMessage { get => _errorMessage; private set => SetProperty(ref _errorMessage, value); }
    public bool RetainedPreviousArtifact { get => _retainedPreviousArtifact; private set => SetProperty(ref _retainedPreviousArtifact, value); }

    internal void Begin(string target, string profile, string? sourceRevision = null)
    {
        Target = target;
        Profile = profile;
        SourceRevision = sourceRevision;
        ErrorCode = null;
        ErrorMessage = null;
        RetainedPreviousArtifact = false;
        State = EditorBakeState.Running;
    }

    internal void ApplyCompleted(EditorBakeResult result)
    {
        Target = result.Target;
        Profile = result.Profile;
        LastSuccessfulResult = result;
        ErrorCode = null;
        ErrorMessage = null;
        RetainedPreviousArtifact = false;
        State = EditorBakeState.Succeeded;
        RaiseArtifactProperties();
    }

    internal void ApplyFailed(string code, string message, bool retainedPreviousArtifact)
    {
        ErrorCode = code;
        ErrorMessage = message;
        RetainedPreviousArtifact = retainedPreviousArtifact;
        State = EditorBakeState.Failed;
        // LastSuccessfulResult 故意不清空：失败语义是继续使用最近一次成功 artifact。
    }

    private void RaiseArtifactProperties()
    {
        RaisePropertyChanged(nameof(SceneArtifactRevision));
        RaisePropertyChanged(nameof(ScriptArtifactRevision));
        RaisePropertyChanged(nameof(SceneArtifactBytes));
        RaisePropertyChanged(nameof(ScriptArtifactBytes));
    }
}

public sealed class EditorWatchViewModel : ObservableObject
{
    private EditorWatchState _state;
    private string _target = "Both";
    private string _profile = "debug";
    private string? _lastSourceTarget;
    private string? _lastSourceRevision;
    private string? _errorCode;
    private string? _errorMessage;

    public EditorWatchState State { get => _state; private set => SetProperty(ref _state, value); }
    public string Target { get => _target; private set => SetProperty(ref _target, value); }
    public string Profile { get => _profile; private set => SetProperty(ref _profile, value); }
    public string? LastSourceTarget { get => _lastSourceTarget; private set => SetProperty(ref _lastSourceTarget, value); }
    public string? LastSourceRevision { get => _lastSourceRevision; private set => SetProperty(ref _lastSourceRevision, value); }
    public string? ErrorCode { get => _errorCode; private set => SetProperty(ref _errorCode, value); }
    public string? ErrorMessage { get => _errorMessage; private set => SetProperty(ref _errorMessage, value); }

    internal void BeginStart(string target, string profile)
    {
        Target = target;
        Profile = profile;
        ErrorCode = null;
        ErrorMessage = null;
        State = EditorWatchState.Starting;
    }

    internal void ApplyStarted(EditorWatchResult result)
    {
        Target = result.Target;
        Profile = result.Profile;
        ErrorCode = null;
        ErrorMessage = null;
        State = EditorWatchState.Watching;
    }

    internal void BeginStop() => State = EditorWatchState.Stopping;

    internal void ApplyStopped()
    {
        ErrorCode = null;
        ErrorMessage = null;
        State = EditorWatchState.Stopped;
    }

    internal void ApplySourceChange(string? target, string? revision)
    {
        LastSourceTarget = target;
        LastSourceRevision = revision;
    }

    internal void ApplyFailure(string code, string message)
    {
        ErrorCode = code;
        ErrorMessage = message;
        State = EditorWatchState.Failed;
    }
}

public sealed class EditorPreviewViewModel : ObservableObject
{
    public EditorPreviewViewModel()
    {
        Reload.PropertyChanged += (_, _) => RaisePropertyChanged(nameof(Reload));
        Runtime.PropertyChanged += (_, _) => RaisePropertyChanged(nameof(Runtime));
    }

    public EditorPreviewReloadViewModel Reload { get; } = new();
    public EditorPreviewRuntimeStateViewModel Runtime { get; } = new();
    private EditorPreviewState _state;
    private string? _surfaceMode;
    private PreviewSurfaceDescriptor? _surface;
    private int? _runtimeProcessId;
    private string? _lastStatusName;
    private string? _lastStatusValue;
    private int? _exitCode;
    private string? _errorCode;
    private string? _errorMessage;
    private bool _liveBakeEnabled;
    private bool _watchChanges;
    private string _bakeProfile = "debug";
    private bool _ownsPublicationSync;

    public EditorPreviewState State { get => _state; private set => SetProperty(ref _state, value); }
    public string? SurfaceMode { get => _surfaceMode; private set => SetProperty(ref _surfaceMode, value); }
    public PreviewSurfaceDescriptor? Surface { get => _surface; private set => SetProperty(ref _surface, value); }
    public int? RuntimeProcessId { get => _runtimeProcessId; private set => SetProperty(ref _runtimeProcessId, value); }
    public string? LastStatusName { get => _lastStatusName; private set => SetProperty(ref _lastStatusName, value); }
    public string? LastStatusValue { get => _lastStatusValue; private set => SetProperty(ref _lastStatusValue, value); }
    public int? ExitCode { get => _exitCode; private set => SetProperty(ref _exitCode, value); }
    public string? ErrorCode { get => _errorCode; private set => SetProperty(ref _errorCode, value); }
    public string? ErrorMessage { get => _errorMessage; private set => SetProperty(ref _errorMessage, value); }
    public bool LiveBakeEnabled { get => _liveBakeEnabled; private set => SetProperty(ref _liveBakeEnabled, value); }
    public bool WatchChanges { get => _watchChanges; private set => SetProperty(ref _watchChanges, value); }
    public string BakeProfile { get => _bakeProfile; private set => SetProperty(ref _bakeProfile, value); }
    public bool OwnsPublicationSync { get => _ownsPublicationSync; private set => SetProperty(ref _ownsPublicationSync, value); }

    internal void BeginStart(PreviewStartParameters parameters)
    {
        LiveBakeEnabled = parameters.LiveBake;
        WatchChanges = parameters.WatchChanges;
        OwnsPublicationSync = parameters.LiveBake && parameters.WatchChanges;
        Reload.Reset();
        Runtime.Reset();
        BakeProfile = parameters.BakeProfile;
        // Preview live-bake/watch 运行时拥有派生文件写入权，UI 据此禁用手动 Bake/Service Watch。
        ErrorCode = null;
        ErrorMessage = null;
        ExitCode = null;
        State = EditorPreviewState.Starting;
    }

    internal void ApplyStarted(PreviewStartResult result)
    {
        SurfaceMode = result.SurfaceMode;
        if (State != EditorPreviewState.Running) { State = EditorPreviewState.Starting; }
    }

    internal void ApplySurface(PreviewSurfaceDescriptor surface)
    {
        Surface = surface;
        SurfaceMode = surface.Mode;
        if (surface.ProcessId is { } processId) { RuntimeProcessId = processId; }
        State = EditorPreviewState.Running;
    }

    internal void ApplyStatus(string? name, string? value, int? runtimeProcessId)
    {
        LastStatusName = name;
        LastStatusValue = value;
        if (runtimeProcessId is { } processId) { RuntimeProcessId = processId; }
        if (State == EditorPreviewState.Starting && runtimeProcessId is not null) { State = EditorPreviewState.Running; }
    }

    internal void ApplyInitial(PreviewInitialLoadedNotification notification) => Runtime.ApplyInitial(notification);

    internal void ApplyInitialFailure(PreviewInitialLoadFailedNotification notification) => Runtime.ApplyFailure(notification);

    internal void ApplyReload(PreviewReloadNotification notification)
    {
        Reload.Apply(notification);
        // requested/failed/stale 只影响 reload 诊断；只有 acknowledged 能推进 Runtime loaded identity。
        Runtime.ApplyReload(notification);
    }

    internal void BeginStop() => State = EditorPreviewState.Stopping;

    internal void ApplyStopped(int? exitCode)
    {
        ExitCode = exitCode;
        RuntimeProcessId = null;
        // 只有确认 preview_stopped/stop response 后才释放 derived writer，失败或超时保持保守占用。
        OwnsPublicationSync = false;
        State = EditorPreviewState.Stopped;
    }

    internal void ApplyFailure(string code, string message)
    {
        ErrorCode = code;
        ErrorMessage = message;
        // 不在未知失败路径释放 ownership；Runtime/Launcher 可能仍存活并继续写 derived。
        State = EditorPreviewState.Failed;
    }
}
