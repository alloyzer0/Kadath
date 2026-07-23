using System.ComponentModel;
using Kadath.Editor.Protocol;

namespace Kadath.Editor.ViewModels;

public enum EditorPreviewReloadState { Idle, Requested, Acknowledged, Failed }

/// <summary>
/// 一个 Runtime reload target 的 retained state。旧 request 的终态只计数，不允许倒退当前 revision。
/// </summary>
public sealed class EditorPreviewReloadTargetViewModel : ObservableObject
{
    private readonly string _target;
    private EditorPreviewReloadState _state;
    private ulong _latestRequestId;
    private string? _source;
    private string? _requestedSourceRevision;
    private string? _requestedArtifactRevision;
    private long? _requestedArtifactBytes;
    private string? _acknowledgedSourceRevision;
    private string? _acknowledgedArtifactRevision;
    private string? _failedSourceRevision;
    private string? _result;
    private string? _errorCode;
    private string? _errorMessage;
    private int _staleResponseCount;
    private ulong? _lastStaleRequestId;

    internal EditorPreviewReloadTargetViewModel(string target) => _target = target;

    public string Target => _target;
    public EditorPreviewReloadState State { get => _state; private set => SetProperty(ref _state, value); }
    public ulong LatestRequestId { get => _latestRequestId; private set => SetProperty(ref _latestRequestId, value); }
    public string? Source { get => _source; private set => SetProperty(ref _source, value); }
    public string? RequestedSourceRevision { get => _requestedSourceRevision; private set => SetProperty(ref _requestedSourceRevision, value); }
    public string? RequestedArtifactRevision { get => _requestedArtifactRevision; private set => SetProperty(ref _requestedArtifactRevision, value); }
    public long? RequestedArtifactBytes { get => _requestedArtifactBytes; private set => SetProperty(ref _requestedArtifactBytes, value); }
    public string? AcknowledgedSourceRevision { get => _acknowledgedSourceRevision; private set => SetProperty(ref _acknowledgedSourceRevision, value); }
    public string? AcknowledgedArtifactRevision { get => _acknowledgedArtifactRevision; private set => SetProperty(ref _acknowledgedArtifactRevision, value); }
    public string? FailedSourceRevision { get => _failedSourceRevision; private set => SetProperty(ref _failedSourceRevision, value); }
    public string? Result { get => _result; private set => SetProperty(ref _result, value); }
    public string? ErrorCode { get => _errorCode; private set => SetProperty(ref _errorCode, value); }
    public string? ErrorMessage { get => _errorMessage; private set => SetProperty(ref _errorMessage, value); }
    public int StaleResponseCount { get => _staleResponseCount; private set => SetProperty(ref _staleResponseCount, value); }
    public ulong? LastStaleRequestId { get => _lastStaleRequestId; private set => SetProperty(ref _lastStaleRequestId, value); }

    internal void Reset()
    {
        State = EditorPreviewReloadState.Idle;
        LatestRequestId = 0;
        Source = null;
        RequestedSourceRevision = null;
        RequestedArtifactRevision = null;
        RequestedArtifactBytes = null;
        AcknowledgedSourceRevision = null;
        AcknowledgedArtifactRevision = null;
        FailedSourceRevision = null;
        Result = null;
        ErrorCode = null;
        ErrorMessage = null;
        StaleResponseCount = 0;
        LastStaleRequestId = null;
    }

    internal void Apply(PreviewReloadNotification notification)
    {
        if (!string.Equals(notification.Target, Target, StringComparison.Ordinal)) { return; }

        // 关键 UI 一致性边界：迟到终态只增加审计计数，绝不覆盖较新的 requested/ack/failed 状态。
        if (notification.Ignored
            || string.Equals(notification.State, "stale", StringComparison.Ordinal)
            || (LatestRequestId > 0 && notification.RequestId < LatestRequestId))
        {
            StaleResponseCount++;
            LastStaleRequestId = notification.RequestId;
            return;
        }

        if (notification.RequestId > LatestRequestId) { LatestRequestId = notification.RequestId; }
        Source = notification.Source;
        ApplyAcknowledgedIdentity(notification);

        switch (notification.State)
        {
            case "requested":
                RequestedSourceRevision = notification.SourceRevision;
                RequestedArtifactRevision = notification.ArtifactRevision;
                RequestedArtifactBytes = notification.ArtifactBytes;
                FailedSourceRevision = null;
                Result = null;
                ErrorCode = null;
                ErrorMessage = null;
                State = EditorPreviewReloadState.Requested;
                break;
            case "acknowledged":
                RequestedSourceRevision = notification.SourceRevision ?? RequestedSourceRevision;
                RequestedArtifactRevision = notification.ArtifactRevision ?? RequestedArtifactRevision;
                RequestedArtifactBytes = notification.ArtifactBytes ?? RequestedArtifactBytes;
                AcknowledgedSourceRevision = notification.AcknowledgedSourceRevision ?? notification.SourceRevision ?? AcknowledgedSourceRevision;
                AcknowledgedArtifactRevision = notification.AcknowledgedArtifactRevision ?? notification.ArtifactRevision ?? AcknowledgedArtifactRevision;
                FailedSourceRevision = null;
                Result = notification.Result;
                ErrorCode = null;
                ErrorMessage = null;
                State = EditorPreviewReloadState.Acknowledged;
                break;
            case "failed":
                RequestedSourceRevision = notification.SourceRevision ?? RequestedSourceRevision;
                RequestedArtifactRevision = notification.ArtifactRevision ?? RequestedArtifactRevision;
                RequestedArtifactBytes = notification.ArtifactBytes ?? RequestedArtifactBytes;
                FailedSourceRevision = notification.FailedSourceRevision ?? notification.SourceRevision;
                Result = notification.Result;
                ErrorCode = notification.ErrorCode ?? "runtime_reload_failed";
                ErrorMessage = notification.Message;
                State = EditorPreviewReloadState.Failed;
                break;
        }
    }

    private void ApplyAcknowledgedIdentity(PreviewReloadNotification notification)
    {
        // failed/stale 事件可携带 retained identity；只在值存在时刷新，缺失不等于清空。
        if (notification.AcknowledgedSourceRevision is not null)
        {
            AcknowledgedSourceRevision = notification.AcknowledgedSourceRevision;
        }
        if (notification.AcknowledgedArtifactRevision is not null)
        {
            AcknowledgedArtifactRevision = notification.AcknowledgedArtifactRevision;
        }
    }
}

public sealed class EditorPreviewReloadViewModel : ObservableObject
{
    private string? _lastTarget;

    public EditorPreviewReloadViewModel()
    {
        Scene.PropertyChanged += OnTargetPropertyChanged;
        Script.PropertyChanged += OnTargetPropertyChanged;
    }

    public EditorPreviewReloadTargetViewModel Scene { get; } = new("Scene");
    public EditorPreviewReloadTargetViewModel Script { get; } = new("Script");
    public string? LastTarget { get => _lastTarget; private set => SetProperty(ref _lastTarget, value); }
    public EditorPreviewReloadTargetViewModel? Last =>
        LastTarget == "Scene" ? Scene : LastTarget == "Script" ? Script : null;

    internal void Reset()
    {
        LastTarget = null;
        Scene.Reset();
        Script.Reset();
        RaisePropertyChanged(nameof(Last));
    }

    internal void Apply(PreviewReloadNotification notification)
    {
        LastTarget = notification.Target;
        (notification.Target == "Scene" ? Scene : Script).Apply(notification);
        RaisePropertyChanged(nameof(Last));
    }

    private void OnTargetPropertyChanged(object? sender, PropertyChangedEventArgs eventArgs)
    {
        RaisePropertyChanged(sender == Scene ? nameof(Scene) : nameof(Script));
        if (sender is EditorPreviewReloadTargetViewModel target
            && string.Equals(target.Target, LastTarget, StringComparison.Ordinal))
        {
            RaisePropertyChanged(nameof(Last));
        }
    }
}