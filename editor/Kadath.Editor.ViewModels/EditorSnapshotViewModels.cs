namespace Kadath.Editor.ViewModels;

public enum EditorSnapshotState
{
    Empty,
    Loading,
    Ready,
    Failed
}

/// <summary>
/// 三类只读 snapshot 共用的可绑定状态。失败时保留上一份成功值，避免 UI 瞬间清空。
/// </summary>
public sealed class EditorSnapshotViewModel<TSnapshot> : ObservableObject
    where TSnapshot : class
{
    private EditorSnapshotState _state;
    private TSnapshot? _value;
    private string? _errorCode;
    private string? _errorMessage;

    public EditorSnapshotState State { get => _state; private set => SetProperty(ref _state, value); }
    public TSnapshot? Value { get => _value; private set => SetProperty(ref _value, value); }
    public string? ErrorCode { get => _errorCode; private set => SetProperty(ref _errorCode, value); }
    public string? ErrorMessage { get => _errorMessage; private set => SetProperty(ref _errorMessage, value); }
    public bool HasValue => Value is not null;

    internal void Begin()
    {
        State = EditorSnapshotState.Loading;
        ErrorCode = null;
        ErrorMessage = null;
    }

    internal void Apply(TSnapshot value)
    {
        Value = value;
        State = EditorSnapshotState.Ready;
        ErrorCode = null;
        ErrorMessage = null;
        RaisePropertyChanged(nameof(HasValue));
    }

    internal void ApplyFailure(string code, string message)
    {
        // Value 故意保留最近成功 snapshot；错误只改变状态和诊断。
        State = EditorSnapshotState.Failed;
        ErrorCode = code;
        ErrorMessage = message;
        RaisePropertyChanged(nameof(HasValue));
    }

    internal void Invalidate()
    {
        StageInvalidation();
        PublishStagedInvalidation();
    }

    internal void StageInvalidation()
    {
        // Session identity 已改变时，先静默提交 backing state，避免观察者看到半组旧 snapshot。
        _value = null;
        _state = EditorSnapshotState.Empty;
        _errorCode = null;
        _errorMessage = null;
    }

    internal void PublishStagedInvalidation()
    {
        RaisePropertyChanged(nameof(Value));
        RaisePropertyChanged(nameof(State));
        RaisePropertyChanged(nameof(ErrorCode));
        RaisePropertyChanged(nameof(ErrorMessage));
        RaisePropertyChanged(nameof(HasValue));
    }

    internal void InvalidateFailure(string code, string message)
    {
        // Create 已提交但整组刷新失败：清值，同时保留实际失败位置的结构化诊断。
        Value = null;
        State = EditorSnapshotState.Failed;
        ErrorCode = code;
        ErrorMessage = message;
        RaisePropertyChanged(nameof(HasValue));
    }
}

