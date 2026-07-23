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
}

