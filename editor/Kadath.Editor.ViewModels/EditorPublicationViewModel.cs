using Kadath.Editor.Protocol;

namespace Kadath.Editor.ViewModels;

public enum EditorPublicationState
{
    Unknown,
    Loading,
    Current,
    SourceDirty,
    Missing,
    ArtifactInvalid,
    ProfileMismatch,
    Failed
}

/// <summary>
/// Source/derived 发布关系的共享状态 module。
/// Avalonia、CLI adapter 和测试通过同一 interface 获得 dirty 状态与最小 Bake target。
/// </summary>
public sealed class EditorPublicationViewModel : ObservableObject
{
    private EditorPublicationState _state = EditorPublicationState.Unknown;
    private PublicationSnapshot? _snapshot;
    private string _profile = "debug";
    private string? _errorCode;
    private string? _errorMessage;

    public EditorPublicationState State { get => _state; private set => SetProperty(ref _state, value); }
    public PublicationSnapshot? Snapshot { get => _snapshot; private set => SetProperty(ref _snapshot, value); }
    public string Profile { get => _profile; private set => SetProperty(ref _profile, value); }
    public PublicationTargetSnapshot? Scene => Snapshot?.Scene;
    public PublicationTargetSnapshot? Script => Snapshot?.Script;
    public string? ManifestProfile => Snapshot?.ManifestProfile;
    public string? ErrorCode { get => _errorCode; private set => SetProperty(ref _errorCode, value); }
    public string? ErrorMessage { get => _errorMessage; private set => SetProperty(ref _errorMessage, value); }
    public bool IsCurrent => State == EditorPublicationState.Current;
    public bool HasPendingChanges => State is EditorPublicationState.SourceDirty
        or EditorPublicationState.Missing
        or EditorPublicationState.ArtifactInvalid
        or EditorPublicationState.ProfileMismatch;
    public string? RecommendedBakeTarget => SelectBakeTarget(Profile);

    internal void Reset()
    {
        State = EditorPublicationState.Unknown;
        Snapshot = null;
        Profile = "debug";
        ErrorCode = null;
        ErrorMessage = null;
        RaiseDerivedProperties();
    }

    internal void Begin(string profile)
    {
        Profile = NormalizeProfile(profile);
        State = EditorPublicationState.Loading;
        ErrorCode = null;
        ErrorMessage = null;
        RaiseDerivedProperties();
    }

    internal void Apply(PublicationSnapshot snapshot)
    {
        Snapshot = snapshot;
        Profile = NormalizeProfile(snapshot.Profile);
        State = snapshot.State switch
        {
            "current" => EditorPublicationState.Current,
            "source_dirty" => EditorPublicationState.SourceDirty,
            "missing" => EditorPublicationState.Missing,
            "artifact_invalid" => EditorPublicationState.ArtifactInvalid,
            "profile_mismatch" => EditorPublicationState.ProfileMismatch,
            _ => EditorPublicationState.Failed
        };
        ErrorCode = snapshot.DiagnosticCode;
        ErrorMessage = snapshot.DiagnosticMessage;
        RaiseDerivedProperties();
    }

    internal void ApplyFailure(string code, string message)
    {
        ErrorCode = code;
        ErrorMessage = message;
        State = EditorPublicationState.Failed;
        // 失败保留最近成功 snapshot，但禁止基于旧事实自动选择 Bake target。
        RaiseDerivedProperties();
    }

    internal void ApplyBakeResult(EditorBakeResult result)
    {
        var scene = NewPublishedTarget("Scene", result.SceneRevision, result.SceneArtifactRevision, result.SceneArtifactBytes, Snapshot?.Scene);
        var script = NewPublishedTarget("Script", result.ScriptRevision, result.ScriptArtifactRevision, result.ScriptArtifactBytes, Snapshot?.Script);
        var aggregate = scene.State == "current" && script.State == "current" ? "current"
            : scene.State == "missing" || script.State == "missing" ? "missing"
            : "source_dirty";
        Apply(new PublicationSnapshot(
            EditorSnapshotVersions.Publication,
            Snapshot?.ProjectName ?? string.Empty,
            result.Profile,
            result.Profile,
            result.DerivedDirectory,
            result.ManifestPath,
            aggregate,
            true,
            scene,
            script));
    }

    private static PublicationTargetSnapshot NewPublishedTarget(
        string target,
        string? sourceRevision,
        string? artifactRevision,
        int? artifactBytes,
        PublicationTargetSnapshot? previous)
    {
        if (sourceRevision is null || artifactRevision is null || artifactBytes is null)
        {
            return previous ?? new PublicationTargetSnapshot(target, "missing", sourceRevision, null, artifactRevision, null, artifactBytes, null);
        }
        return new PublicationTargetSnapshot(
            target,
            "current",
            sourceRevision,
            sourceRevision,
            artifactRevision,
            artifactRevision,
            artifactBytes,
            artifactBytes);
    }
    public string? SelectBakeTarget(string profile)
    {
        if (State is EditorPublicationState.Unknown or EditorPublicationState.Loading or EditorPublicationState.Failed || Snapshot is null)
        {
            return null;
        }
        var normalized = NormalizeProfile(profile);
        if (!Snapshot.ManifestPresent
            || !string.Equals(Snapshot.Profile, normalized, StringComparison.Ordinal)
            || !string.Equals(Snapshot.ManifestProfile, normalized, StringComparison.Ordinal)
            || Snapshot.DiagnosticCode is not null)
        {
            return "Both";
        }

        var sceneCurrent = string.Equals(Snapshot.Scene.State, "current", StringComparison.Ordinal);
        var scriptCurrent = string.Equals(Snapshot.Script.State, "current", StringComparison.Ordinal);
        // pair 不完整或 artifact 证据损坏时必须重建 Both，不能只修复看起来 dirty 的一侧。
        var pairIntegrityRequiresBoth = Snapshot.Scene.State is "missing" or "artifact_invalid"
            || Snapshot.Script.State is "missing" or "artifact_invalid";
        if (pairIntegrityRequiresBoth) { return "Both"; }
        if (sceneCurrent && scriptCurrent) { return null; }
        if (sceneCurrent) { return "Script"; }
        if (scriptCurrent) { return "Scene"; }
        return "Both";
    }

    private static string NormalizeProfile(string profile) => profile.ToLowerInvariant() switch
    {
        "debug" => "debug",
        "release" => "release",
        _ => throw new ArgumentOutOfRangeException(nameof(profile), profile, "Publication profile must be debug or release.")
    };

    private void RaiseDerivedProperties()
    {
        RaisePropertyChanged(nameof(Scene));
        RaisePropertyChanged(nameof(Script));
        RaisePropertyChanged(nameof(ManifestProfile));
        RaisePropertyChanged(nameof(IsCurrent));
        RaisePropertyChanged(nameof(HasPendingChanges));
        RaisePropertyChanged(nameof(RecommendedBakeTarget));
    }
}
