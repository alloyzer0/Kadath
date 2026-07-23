using System.Text.Json;
using System.Text.Json.Serialization;

namespace Kadath.Editor.Protocol;

/// <summary>
/// Editor UI 与本地 Editor Host 共用的 JSONL RPC v1 契约。
/// 控制消息只描述命令和状态，不承载 Runtime 的像素帧。
/// </summary>
public static class EditorProtocol
{
    public const int SchemaVersion = 1;
    public const string ProtocolName = "kadath-editor-rpc";
    public const string TransportName = "stdio-jsonl";

    public static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        WriteIndented = false
    };
}

public sealed record EditorHello(
    int SchemaVersion,
    string Type,
    string Protocol,
    int ProtocolVersion,
    string[] Transports,
    string[] Capabilities);

public sealed record EditorHelloAck(
    int SchemaVersion,
    string Type,
    string Client,
    string ClientVersion);

public sealed record EditorRpcRequest(
    int SchemaVersion,
    string Type,
    string Id,
    string Method,
    JsonElement? Params);

public sealed record EditorRpcResponse(
    int SchemaVersion,
    string Type,
    string Id,
    bool Ok,
    JsonElement? Result,
    EditorRpcError? Error);

public sealed record EditorRpcError(string Code, string Message);

public sealed record EditorEvent(
    int SchemaVersion,
    string Type,
    long Sequence,
    string Event,
    string? RequestId,
    JsonElement? Data);

public sealed record EditorCapabilities(
    string[] Commands,
    string[] Transports,
    PreviewSurfaceCapability[] PreviewSurfaces);

/// <summary>
/// PreviewSurface 是控制通道与画面通道之间的显式 seam。
/// v1 只声明独立 Runtime 窗口；后续可增加 shared-texture 或 frame-stream，
/// 但不能把大块像素数据塞进 JSON-RPC。
/// </summary>
public sealed record PreviewSurfaceCapability(
    string Mode,
    string Plane,
    bool Implemented);

public static class PreviewSurfaceModes
{
    public const string ExternalWindow = "external-window";
    public const string SharedTexture = "shared-texture";
    public const string FrameStream = "frame-stream";
}

public sealed record PreviewSurfaceDescriptor(
    string Mode,
    string Plane,
    int? ProcessId,
    string WindowClass,
    string? NativeHandle,
    int? Width,
    int? Height,
    string? PixelFormat);

public sealed record ProjectOpenParameters(string PackageRoot, string ProjectName);

public sealed record ProjectSessionInfo(
    string PackageRoot,
    string ProjectName,
    string ProjectDirectory,
    string ScenePath,
    string ScriptPath,
    string PreviewPath,
    int ModelVersion);

/// <summary>
/// 三类只读 snapshot 命令共用的查询参数；ProjectName 缺失时使用当前 Service session。
/// </summary>
public sealed record SnapshotQueryParameters(string? ProjectName = null);

public static class EditorSnapshotVersions
{
    public const int ProjectModel = 1;
    public const int Hierarchy = 1;
    public const int AssetCatalog = 1;
}

public sealed record ProjectModelFiles(
    string Directory,
    string Scene,
    string Script,
    string Preview);

public sealed record ProjectModelScene(
    int SchemaVersion,
    double[] GoalPosition);

public sealed record ProjectModelScript(
    int SchemaVersion,
    double[] GoalPosition,
    double[] GoalVelocity);

public sealed record ProjectModelPreview(int SchemaVersion);

public sealed record ProjectModelSnapshot(
    int ModelVersion,
    string ProjectName,
    string AuthoringRevision,
    ProjectModelFiles Files,
    ProjectModelScene Scene,
    ProjectModelScript Script,
    ProjectModelPreview Preview);

public sealed record HierarchyNode(
    string Id,
    string? ParentId,
    string DisplayName,
    string Kind,
    Dictionary<string, JsonElement> Properties);

public sealed record HierarchySnapshot(
    int SnapshotVersion,
    int ProjectModelVersion,
    string ProjectName,
    HierarchyNode[] Nodes);

public sealed record AssetCatalogItem(
    string AssetId,
    string DisplayName,
    string RelativePath,
    string Category,
    string Extension,
    long SizeBytes,
    Dictionary<string, JsonElement> Properties);

public sealed record AssetCatalogSnapshot(
    int CatalogVersion,
    string Root,
    int ItemCount,
    AssetCatalogItem[] Items);

public sealed record AuthoringPatch(
    double[]? SceneGoalPosition = null,
    double[]? ScriptGoalPosition = null,
    double[]? ScriptGoalVelocity = null);

public sealed record AuthoringApplyParameters(
    string? ProjectName,
    string ExpectedRevision,
    AuthoringPatch Patch);

public sealed record AuthoringUndoParameters(
    string? ProjectName,
    string ExpectedRevision);

public sealed record AuthoringMutationResult(
    string Operation,
    string State,
    string ProjectName,
    string PreviousRevision,
    string Revision,
    string[] ChangedFields,
    int UndoDepth,
    ProjectModelSnapshot ProjectSnapshot,
    HierarchySnapshot HierarchySnapshot);
public sealed record ProjectValidateParameters(string? ProjectName = null);

public sealed record ProjectValidateResult(
    string State,
    string ProjectName,
    string[] Diagnostics);

public sealed record BakeStartParameters(
    string Target = "Both",
    string Profile = "debug");

public sealed record EditorBakeResult(
    string State,
    string Target,
    string Profile,
    string DerivedDirectory,
    string ManifestPath,
    string? SceneRevision,
    string? ScriptRevision,
    string? SceneArtifactRevision,
    string? ScriptArtifactRevision,
    int? SceneArtifactBytes,
    int? ScriptArtifactBytes);

public sealed record WatchStartParameters(
    string Target = "Both",
    string Profile = "debug",
    int PollIntervalMilliseconds = 100,
    int DebounceMilliseconds = 250);

public sealed record EditorWatchResult(
    string State,
    string ProjectName,
    string Target,
    string Profile,
    EditorBakeResult? InitialBake);

public sealed record PreviewStartParameters(
    string? ConfigPath = null,
    string? PackageRoot = null,
    string? ProjectName = null,
    int StopAfterMilliseconds = 0,
    int ReloadScriptAfterMilliseconds = 0,
    bool WatchChanges = false,
    int PollIntervalMilliseconds = 100,
    int DebounceMilliseconds = 250,
    bool LiveBake = false,
    string BakeProfile = "debug",
    string? DerivedDirectory = null);

public sealed record PreviewStartResult(string State, string SurfaceMode);
public sealed record PreviewStopResult(string State);

