using Kadath.Editor.Protocol;

namespace Kadath.Editor.ViewModels;

public enum EditorAuthoringState
{
    Idle,
    Applying,
    Undoing,
    Redoing,
    Succeeded,
    Failed
}

/// <summary>
/// Authoring mutation 的 UI 状态。Undo/Redo depth 与 revision 一起保留，避免 View 自己维护历史。
/// </summary>
public sealed class EditorAuthoringViewModel : ObservableObject
{
    private EditorAuthoringState _state;
    private string? _operation;
    private string? _revision;
    private string? _errorCode;
    private string? _errorMessage;
    private int _undoDepth;
    private int _redoDepth;

    public EditorAuthoringState State { get => _state; private set => SetProperty(ref _state, value); }
    public string? Operation { get => _operation; private set => SetProperty(ref _operation, value); }
    public string? Revision { get => _revision; private set => SetProperty(ref _revision, value); }
    public string? ErrorCode { get => _errorCode; private set => SetProperty(ref _errorCode, value); }
    public string? ErrorMessage { get => _errorMessage; private set => SetProperty(ref _errorMessage, value); }
    public int UndoDepth { get => _undoDepth; private set => SetProperty(ref _undoDepth, value); }
    public int RedoDepth { get => _redoDepth; private set => SetProperty(ref _redoDepth, value); }

    internal void Begin(string operation)
    {
        Operation = operation;
        State = operation switch
        {
            "undo" => EditorAuthoringState.Undoing,
            "redo" => EditorAuthoringState.Redoing,
            _ => EditorAuthoringState.Applying
        };
        ErrorCode = null;
        ErrorMessage = null;
    }

    internal void Apply(AuthoringMutationResult result)
    {
        Operation = result.Operation;
        Revision = result.Revision;
        UndoDepth = result.UndoDepth;
        RedoDepth = result.RedoDepth;
        State = EditorAuthoringState.Succeeded;
        ErrorCode = null;
        ErrorMessage = null;
    }

    internal void ApplyFailure(string code, string message)
    {
        if (code is "authoring_revision_conflict" or "authoring_history_diverged") { UndoDepth = 0; RedoDepth = 0; }
        State = EditorAuthoringState.Failed;
        ErrorCode = code;
        ErrorMessage = message;
    }

    internal void InvalidateHistory() { UndoDepth = 0; RedoDepth = 0; }

    internal void InvalidateHistory(string revision)
    {
        if (string.Equals(Revision, revision, StringComparison.OrdinalIgnoreCase)) { return; }
        Revision = revision;
        UndoDepth = 0;
        RedoDepth = 0;
    }

    internal void Reset()
    {
        State = EditorAuthoringState.Idle;
        Operation = null;
        Revision = null;
        UndoDepth = 0;
        RedoDepth = 0;
        ErrorCode = null;
        ErrorMessage = null;
    }
}
