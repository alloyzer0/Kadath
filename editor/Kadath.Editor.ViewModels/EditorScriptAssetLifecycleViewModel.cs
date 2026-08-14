using Kadath.Editor.Protocol;

namespace Kadath.Editor.ViewModels;

public enum EditorScriptAssetLifecycleState
{
    Idle,
    Creating,
    Renaming,
    Deleting,
    Undoing,
    Succeeded,
    Failed
}

public sealed class EditorScriptAssetLifecycleViewModel : ObservableObject
{
    private EditorScriptAssetLifecycleState _state;
    private string? _operation;
    private string? _revision;
    private string? _errorCode;
    private string? _errorMessage;
    private int _undoDepth;
    private ScriptAssetIdentity? _asset;

    public EditorScriptAssetLifecycleState State { get => _state; private set => SetProperty(ref _state, value); }
    public string? Operation { get => _operation; private set => SetProperty(ref _operation, value); }
    public string? Revision { get => _revision; private set => SetProperty(ref _revision, value); }
    public string? ErrorCode { get => _errorCode; private set => SetProperty(ref _errorCode, value); }
    public string? ErrorMessage { get => _errorMessage; private set => SetProperty(ref _errorMessage, value); }
    public int UndoDepth { get => _undoDepth; private set => SetProperty(ref _undoDepth, value); }
    public ScriptAssetIdentity? Asset { get => _asset; private set => SetProperty(ref _asset, value); }
    public bool IsBusy => State is EditorScriptAssetLifecycleState.Creating
        or EditorScriptAssetLifecycleState.Renaming
        or EditorScriptAssetLifecycleState.Deleting
        or EditorScriptAssetLifecycleState.Undoing;

    internal void Begin(string operation)
    {
        Operation = operation;
        State = operation switch
        {
            "create" => EditorScriptAssetLifecycleState.Creating,
            "rename" => EditorScriptAssetLifecycleState.Renaming,
            "delete" => EditorScriptAssetLifecycleState.Deleting,
            "undo" => EditorScriptAssetLifecycleState.Undoing,
            _ => throw new ArgumentOutOfRangeException(nameof(operation), operation, "Unknown Script Asset lifecycle operation.")
        };
        ErrorCode = null;
        ErrorMessage = null;
        RaisePropertyChanged(nameof(IsBusy));
    }

    internal void Apply(ScriptAssetMutationResult result)
    {
        Operation = result.Operation;
        Revision = result.Revision;
        UndoDepth = result.UndoDepth;
        Asset = result.Asset;
        ErrorCode = null;
        ErrorMessage = null;
        State = EditorScriptAssetLifecycleState.Succeeded;
        RaisePropertyChanged(nameof(IsBusy));
    }

    internal void ApplyFailure(string code, string message)
    {
        ErrorCode = code;
        ErrorMessage = message;
        State = EditorScriptAssetLifecycleState.Failed;
        RaisePropertyChanged(nameof(IsBusy));
    }

    internal void Reset()
    {
        State = EditorScriptAssetLifecycleState.Idle;
        Operation = null;
        Revision = null;
        ErrorCode = null;
        ErrorMessage = null;
        UndoDepth = 0;
        Asset = null;
        RaisePropertyChanged(nameof(IsBusy));
    }
}
