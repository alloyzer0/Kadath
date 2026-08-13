using Kadath.Editor.Protocol;

namespace Kadath.Editor.ViewModels;

public enum EditorScriptSourceState
{
    Empty,
    Loading,
    Ready,
    Saving,
    Undoing,
    Succeeded,
    Failed
}

public sealed class EditorScriptSourceViewModel : ObservableObject
{
    private EditorScriptSourceState _state;
    private ScriptSourceDocument? _document;
    private string? _operation;
    private string? _errorCode;
    private string? _errorMessage;
    private int _undoDepth;

    public EditorScriptSourceState State { get => _state; private set => SetProperty(ref _state, value); }
    public ScriptSourceDocument? Document { get => _document; private set => SetProperty(ref _document, value); }
    public string? Operation { get => _operation; private set => SetProperty(ref _operation, value); }
    public string? ErrorCode { get => _errorCode; private set => SetProperty(ref _errorCode, value); }
    public string? ErrorMessage { get => _errorMessage; private set => SetProperty(ref _errorMessage, value); }
    public int UndoDepth { get => _undoDepth; private set => SetProperty(ref _undoDepth, value); }
    public bool HasDocument => Document is not null;

    internal void BeginRead()
    {
        Operation = "read";
        ErrorCode = null;
        ErrorMessage = null;
        State = EditorScriptSourceState.Loading;
    }

    internal void BeginEdit()
    {
        Operation = "edit";
        ErrorCode = null;
        ErrorMessage = null;
        State = EditorScriptSourceState.Saving;
    }

    internal void BeginUndo()
    {
        Operation = "undo";
        ErrorCode = null;
        ErrorMessage = null;
        State = EditorScriptSourceState.Undoing;
    }

    internal void ApplyRead(ScriptSourceDocument document)
    {
        if (Document is not null
            && !string.Equals(Document.AuthoringRevision, document.AuthoringRevision, StringComparison.OrdinalIgnoreCase))
        {
            UndoDepth = 0;
        }
        Document = document;
        Operation = "read";
        ErrorCode = null;
        ErrorMessage = null;
        State = EditorScriptSourceState.Ready;
        RaisePropertyChanged(nameof(HasDocument));
    }

    internal void ApplyMutation(ScriptSourceMutationResult result)
    {
        Document = result.SourceDocument;
        Operation = result.Operation;
        UndoDepth = result.UndoDepth;
        ErrorCode = null;
        ErrorMessage = null;
        State = EditorScriptSourceState.Succeeded;
        RaisePropertyChanged(nameof(HasDocument));
    }

    internal void ApplyAuthoringRevision(string previousRevision, string revision)
    {
        if (string.Equals(previousRevision, revision, StringComparison.OrdinalIgnoreCase)) { return; }
        UndoDepth = 0;
        if (Document is not null
            && string.Equals(Document.AuthoringRevision, previousRevision, StringComparison.OrdinalIgnoreCase))
        {
            Document = Document with { AuthoringRevision = revision };
        }
    }

    internal void ApplyFailure(string code, string message)
    {
        if (code is "script_source_history_diverged" or "script_source_revision_conflict" or "authoring_revision_conflict") { UndoDepth = 0; }
        ErrorCode = code;
        ErrorMessage = message;
        State = EditorScriptSourceState.Failed;
    }

    internal void InvalidateHistory() => UndoDepth = 0;

    internal void Reset()
    {
        State = EditorScriptSourceState.Empty;
        Document = null;
        Operation = null;
        ErrorCode = null;
        ErrorMessage = null;
        UndoDepth = 0;
        RaisePropertyChanged(nameof(HasDocument));
    }
}
