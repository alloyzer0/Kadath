using System.ComponentModel;
using Kadath.Editor.Protocol;

namespace Kadath.Editor.ViewModels;

public enum EditorPreviewRuntimeState { Unknown, Loaded, Failed }
public enum EditorPreviewRuntimeOrigin { None, Initial, Reload }
public enum EditorPreviewRuntimeConsistency { Unknown, Current, SourceDirty, ArtifactMismatch, PublicationUnavailable }

/// <summary>
/// 单个 Runtime target 的权威 loaded identity；publication 只参与对账，不能覆盖这些字段。
/// </summary>
public sealed class EditorPreviewRuntimeTargetViewModel : ObservableObject
{
    private readonly string _target;
    private string? _kind;
    private string? _sourceRevision;
    private string? _artifactRevision;
    private ulong? _artifactBytes;
    private string? _correlation;
    private EditorPreviewRuntimeOrigin _origin;
    private EditorPreviewRuntimeConsistency _consistency;

    internal EditorPreviewRuntimeTargetViewModel(string target) => _target = target;

    public string Target => _target;
    public string? Kind { get => _kind; private set => SetProperty(ref _kind, value); }
    public string? SourceRevision { get => _sourceRevision; private set => SetProperty(ref _sourceRevision, value); }
    public string? ArtifactRevision { get => _artifactRevision; private set => SetProperty(ref _artifactRevision, value); }
    public ulong? ArtifactBytes { get => _artifactBytes; private set => SetProperty(ref _artifactBytes, value); }
    public string? Correlation { get => _correlation; private set => SetProperty(ref _correlation, value); }
    public EditorPreviewRuntimeOrigin Origin { get => _origin; private set => SetProperty(ref _origin, value); }
    public EditorPreviewRuntimeConsistency Consistency { get => _consistency; private set => SetProperty(ref _consistency, value); }

    internal void Reset()
    {
        Kind = null;
        SourceRevision = null;
        ArtifactRevision = null;
        ArtifactBytes = null;
        Correlation = null;
        Origin = EditorPreviewRuntimeOrigin.None;
        Consistency = EditorPreviewRuntimeConsistency.Unknown;
    }

    internal void ApplyInitial(PreviewLoadedTargetIdentity identity)
    {
        Kind = identity.Kind;
        SourceRevision = identity.SourceRevision;
        ArtifactRevision = identity.ArtifactRevision;
        ArtifactBytes = identity.ArtifactBytes;
        Correlation = identity.Correlation;
        Origin = EditorPreviewRuntimeOrigin.Initial;
    }

    internal bool ApplyReload(PreviewReloadNotification notification)
    {
        if (!string.Equals(notification.State, "acknowledged", StringComparison.Ordinal)) { return false; }
        var source = notification.AcknowledgedSourceRevision ?? notification.SourceRevision;
        var artifact = notification.AcknowledgedArtifactRevision ?? notification.ArtifactRevision;
        if (source is null && artifact is null) { return false; }

        Kind = artifact is null ? "source_document" : "artifact";
        SourceRevision = source;
        ArtifactRevision = artifact;
        ArtifactBytes = notification.ArtifactBytes is > 0 ? checked((ulong)notification.ArtifactBytes.Value) : null;
        Correlation = "reload_acknowledged";
        Origin = EditorPreviewRuntimeOrigin.Reload;
        return true;
    }

    internal void Reconcile(PublicationTargetSnapshot? publication)
    {
        if (Origin == EditorPreviewRuntimeOrigin.None || Kind == "built_in")
        {
            Consistency = EditorPreviewRuntimeConsistency.Unknown;
            return;
        }
        if (publication is null)
        {
            Consistency = EditorPreviewRuntimeConsistency.PublicationUnavailable;
            return;
        }
        if (Kind == "source_document")
        {
            Consistency = publication.SourceRevision is null
                ? EditorPreviewRuntimeConsistency.PublicationUnavailable
                : Same(SourceRevision, publication.SourceRevision)
                    ? EditorPreviewRuntimeConsistency.Current
                    : EditorPreviewRuntimeConsistency.SourceDirty;
            return;
        }
        if (Kind != "artifact" || ArtifactRevision is null || publication.ArtifactRevision is null)
        {
            Consistency = EditorPreviewRuntimeConsistency.PublicationUnavailable;
            return;
        }
        if (Correlation == "artifact_mismatch" || !Same(ArtifactRevision, publication.ArtifactRevision))
        {
            Consistency = EditorPreviewRuntimeConsistency.ArtifactMismatch;
            return;
        }
        if (SourceRevision is not null
            && publication.BakedSourceRevision is not null
            && !Same(SourceRevision, publication.BakedSourceRevision))
        {
            Consistency = EditorPreviewRuntimeConsistency.ArtifactMismatch;
            return;
        }
        Consistency = SourceRevision is not null
            && publication.SourceRevision is not null
            && !Same(SourceRevision, publication.SourceRevision)
                ? EditorPreviewRuntimeConsistency.SourceDirty
                : EditorPreviewRuntimeConsistency.Current;
    }

    private static bool Same(string? left, string? right) =>
        string.Equals(left, right, StringComparison.OrdinalIgnoreCase);
}

public sealed class EditorPreviewRuntimeStateViewModel : ObservableObject
{
    private EditorPreviewRuntimeState _state;
    private string? _lastTarget;
    private string? _errorCode;
    private string? _errorMessage;
    private bool _initialTerminalApplied;
    private PublicationSnapshot? _publication;

    public EditorPreviewRuntimeStateViewModel()
    {
        Scene.PropertyChanged += OnTargetPropertyChanged;
        Script.PropertyChanged += OnTargetPropertyChanged;
    }

    public EditorPreviewRuntimeTargetViewModel Scene { get; } = new("Scene");
    public EditorPreviewRuntimeTargetViewModel Script { get; } = new("Script");
    public EditorPreviewRuntimeState State { get => _state; private set => SetProperty(ref _state, value); }
    public string? LastTarget { get => _lastTarget; private set => SetProperty(ref _lastTarget, value); }
    public EditorPreviewRuntimeTargetViewModel? Last => LastTarget == "Scene" ? Scene : LastTarget == "Script" ? Script : null;
    public string? ErrorCode { get => _errorCode; private set => SetProperty(ref _errorCode, value); }
    public string? ErrorMessage { get => _errorMessage; private set => SetProperty(ref _errorMessage, value); }

    internal void Reset()
    {
        _initialTerminalApplied = false;
        // Publication 属于 workspace/project 生命周期；Preview restart 只清空 Runtime identity，保留对账基准。
        State = EditorPreviewRuntimeState.Unknown;
        LastTarget = null;
        ErrorCode = null;
        ErrorMessage = null;
        Scene.Reset();
        Script.Reset();
        RaisePropertyChanged(nameof(Last));
    }

    internal void ApplyInitial(PreviewInitialLoadedNotification notification)
    {
        // 每个 Preview 生命周期只接受一次原子 initial；reload 已推进后迟到 initial 也不能倒退身份。
        if (_initialTerminalApplied || Scene.Origin == EditorPreviewRuntimeOrigin.Reload || Script.Origin == EditorPreviewRuntimeOrigin.Reload) { return; }
        _initialTerminalApplied = true;
        Scene.ApplyInitial(notification.Scene);
        Script.ApplyInitial(notification.Script);
        ErrorCode = null;
        ErrorMessage = null;
        LastTarget = "Script";
        Reconcile(_publication);
        State = EditorPreviewRuntimeState.Loaded;
        RaisePropertyChanged(nameof(Last));
    }

    internal void ApplyFailure(PreviewInitialLoadFailedNotification notification)
    {
        // initial 成功/失败共享一次性终态；迟到失败也不能把 reload ack 推进后的 loaded 状态倒退。
        if (_initialTerminalApplied || Scene.Origin == EditorPreviewRuntimeOrigin.Reload || Script.Origin == EditorPreviewRuntimeOrigin.Reload) { return; }
        _initialTerminalApplied = true;
        ErrorCode = notification.ErrorCode;
        ErrorMessage = notification.Message;
        State = EditorPreviewRuntimeState.Failed;
    }

    internal void ApplyReload(PreviewReloadNotification notification)
    {
        var target = notification.Target == "Scene" ? Scene : Script;
        if (!target.ApplyReload(notification)) { return; }
        LastTarget = notification.Target;
        target.Reconcile(notification.Target == "Scene" ? _publication?.Scene : _publication?.Script);
        State = EditorPreviewRuntimeState.Loaded;
        RaisePropertyChanged(nameof(Last));
    }

    internal void Reconcile(PublicationSnapshot? publication)
    {
        _publication = publication;
        Scene.Reconcile(publication?.Scene);
        Script.Reconcile(publication?.Script);
    }

    private void OnTargetPropertyChanged(object? sender, PropertyChangedEventArgs eventArgs)
    {
        RaisePropertyChanged(sender == Scene ? nameof(Scene) : nameof(Script));
        if (sender is EditorPreviewRuntimeTargetViewModel target && target.Target == LastTarget) { RaisePropertyChanged(nameof(Last)); }
    }
}
