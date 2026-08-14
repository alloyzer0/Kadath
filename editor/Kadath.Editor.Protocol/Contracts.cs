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

public sealed record ProjectCreateParameters(string PackageRoot, string ProjectName);

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

public sealed record ScriptSourceQueryParameters(
    string? ProjectName,
    uint ScriptId);

public sealed record ScriptSourceEditParameters(
    string? ProjectName,
    string ExpectedRevision,
    uint ScriptId,
    string Source);

public sealed record ScriptSourceDocument(
    string ProjectName,
    uint ScriptId,
    string SourcePath,
    string Source,
    string AuthoringRevision);

public sealed record ScriptSourceMutationResult(
    string Operation,
    string State,
    string ProjectName,
    string PreviousRevision,
    string Revision,
    string[] ChangedFields,
    int UndoDepth,
    ScriptSourceDocument SourceDocument,
    ProjectModelSnapshot ProjectSnapshot,
    HierarchySnapshot HierarchySnapshot);

public sealed record ScriptSourceUndoParameters(
    string? ProjectName,
    string ExpectedRevision);

public sealed record ScriptAssetCreateParameters(
    string? ProjectName,
    string ExpectedRevision,
    string SourcePath);

public sealed record ScriptAssetRenameParameters(
    string? ProjectName,
    string ExpectedRevision,
    uint ScriptId,
    string SourcePath);

public sealed record ScriptAssetDeleteParameters(
    string? ProjectName,
    string ExpectedRevision,
    uint ScriptId);

public sealed record ScriptAssetUndoParameters(
    string? ProjectName,
    string ExpectedRevision);

public sealed record ScriptAssetIdentity(uint ScriptId, string SourcePath);

public sealed record ScriptAssetMutationResult(
    string Operation,
    string State,
    string ProjectName,
    string PreviousRevision,
    string Revision,
    string[] ChangedFields,
    int UndoDepth,
    ScriptAssetIdentity Asset,
    ScriptSourceDocument? SourceDocument,
    ProjectModelSnapshot ProjectSnapshot,
    HierarchySnapshot HierarchySnapshot,
    AssetCatalogSnapshot AssetCatalogSnapshot);

public sealed record ScriptSourceAnalyzeParameters(
    string? ProjectName,
    uint ScriptId,
    string Source,
    string SourceHash);

public sealed record ScriptSourcePosition(int Line, int Column);

public sealed record ScriptSourceRange(
    ScriptSourcePosition Start,
    ScriptSourcePosition End);

public sealed record ScriptSourceDiagnostic(
    string Severity,
    string Stage,
    string Code,
    string Message,
    string SourcePath,
    ScriptSourceRange? Range);

public sealed record ScriptSourceAnalysisResult(
    string State,
    string ProjectName,
    uint ScriptId,
    string SourcePath,
    string SourceHash,
    string AuthoringRevision,
    string ToolchainIdentity,
    ScriptSourceDiagnostic[] Diagnostics);

public sealed record BehaviorContractSnapshotParameters(string? ProjectName = null);

public sealed record BehaviorParameterSchema(
    string Name,
    string Type,
    double DefaultValue,
    double Minimum,
    double Maximum);

public sealed record BehaviorContractEntry(
    uint ScriptId,
    string SourcePath,
    string SourceHash,
    BehaviorParameterSchema[] Parameters);

public sealed record BehaviorContractSnapshotResult(
    string State,
    string ProjectName,
    string AuthoringRevision,
    string ScriptSourceRevision,
    string ToolchainIdentity,
    BehaviorContractEntry[] Entries,
    string? ErrorCode = null);

public static class EditorSnapshotVersions
{
    public const int ProjectModel = 1;
    public const int Hierarchy = 2;
    public const int AssetCatalog = 1;
    // Publication 快照使用独立版本，避免与其它只读 snapshot 的演进互相耦合。
    public const int Publication = 1;
}

public sealed record ProjectModelFiles(
    string Directory,
    string Scene,
    string Script,
    string Preview);

public sealed record ProjectModelScene(
    int SchemaVersion,
    double[] GoalPosition,
    uint PlayerTextureId,
    uint GoalTextureId,
    uint HazardTextureId,
    IReadOnlyList<ProjectModelTexture>? Textures = null,
    IReadOnlyList<ProjectModelSceneObject>? Objects = null);

public sealed record ProjectModelTexture(uint TextureId, string Artifact);

public sealed record ProjectModelSceneBehaviorParameter(string Name, double Value);

public sealed record ProjectModelSceneBehaviorBinding(
    uint ScriptId,
    IReadOnlyList<ProjectModelSceneBehaviorParameter>? Parameters = null);

public sealed record ProjectModelSceneObject(
    string ObjectId,
    string Kind,
    double[] Position,
    double[] Size,
    double[] Color,
    uint TextureId,
    double? MoveSpeed = null,
    double? PatrolMinY = null,
    double? PatrolMaxY = null,
    double? PatrolSpeed = null,
    IReadOnlyList<ProjectModelSceneBehaviorBinding>? Behaviors = null);

public sealed record ProjectModelScriptDependency(uint ScriptId, string Source);

public sealed record ProjectModelScript(
    int SchemaVersion,
    double[] GoalPosition,
    double[] GoalVelocity,
    IReadOnlyList<ProjectModelScriptDependency>? Dependencies = null);

public sealed record ProjectModelPreview(int SchemaVersion);

public sealed record ProjectModelSnapshot(
    int ModelVersion,
    string ProjectName,
    string AuthoringRevision,
    ProjectModelFiles Files,
    ProjectModelScene Scene,
    ProjectModelScript Script,
    ProjectModelPreview Preview);

/// <summary>
/// Publication Snapshot 把 source/derived 状态收敛在只读边界后。
/// 前端只消费该 DTO，不直接读取 manifest 或 artifact。
/// </summary>
public sealed record PublicationSnapshotQueryParameters(
    string? ProjectName = null,
    string Profile = "debug");

public sealed record PublicationTargetSnapshot(
    string Target,
    string State,
    string? SourceRevision,
    string? BakedSourceRevision,
    string? ArtifactRevision,
    string? ManifestArtifactRevision,
    long? ArtifactBytes,
    long? ManifestArtifactBytes);

public sealed record PublicationSnapshot(
    int SnapshotVersion,
    string ProjectName,
    string Profile,
    string? ManifestProfile,
    string DerivedDirectory,
    string ManifestPath,
    string State,
    bool ManifestPresent,
    PublicationTargetSnapshot Scene,
    PublicationTargetSnapshot Script,
    string? DiagnosticCode = null,
    string? DiagnosticMessage = null);

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

public sealed record TextureImportParameters(
    string? ProjectName,
    string SourcePath,
    string AssetName,
    string Profile = "debug");

public sealed record TextureImportResult(
    string State,
    string ProjectName,
    string SourcePath,
    string AssetId,
    string RelativePath,
    string Profile,
    string SourceFormat,
    string ArtifactFormat,
    int Width,
    int Height,
    int MipLevelCount,
    string Transform,
    int ArtifactBytes,
    string Sha256,
    AssetCatalogSnapshot AssetCatalog);

public sealed record SceneTextureAssignment(
    uint TextureId,
    string AssetId);

public sealed record SceneObjectDefinition(
    string ObjectId,
    string Kind,
    double[] Position,
    double[] Size,
    double[] Color,
    uint TextureId,
    double? MoveSpeed = null,
    double? PatrolMinY = null,
    double? PatrolMaxY = null,
    double? PatrolSpeed = null,
    IReadOnlyList<SceneBehaviorBindingDefinition>? Behaviors = null);

public sealed record SceneBehaviorBindingDefinition(
    uint ScriptId,
    IReadOnlyDictionary<string, double>? Parameters = null);

public sealed record AuthoringPatch(
    double[]? SceneGoalPosition = null,
    double[]? ScriptGoalPosition = null,
    double[]? ScriptGoalVelocity = null,
    uint? ScenePlayerTextureId = null,
    uint? SceneGoalTextureId = null,
    uint? SceneHazardTextureId = null,
    IReadOnlyList<SceneTextureAssignment>? SceneTextures = null,
    IReadOnlyList<SceneObjectDefinition>? SceneObjects = null);

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

/// <summary>
/// Runtime 初始内容身份。artifact 的 sourceRevision 只有在 Launcher 验证 manifest hash/bytes 后才存在。
/// </summary>
public sealed record PreviewLoadedTargetIdentity(
    string Target,
    string Kind,
    string Correlation,
    string? SourceRevision = null,
    string? ArtifactRevision = null,
    ulong? ArtifactBytes = null);

public sealed record PreviewInitialLoadedNotification(
    int LoadVersion,
    string State,
    PreviewLoadedTargetIdentity Scene,
    PreviewLoadedTargetIdentity Script,
    string? Profile = null);

public sealed record PreviewInitialLoadFailedNotification(
    int LoadVersion,
    string State,
    string ErrorCode,
    string? Message = null);

/// <summary>
/// Service 归一化后的 Runtime reload 确认。它携带内容身份，不暴露 Launcher sequence 或 WM_APP。
/// </summary>
public sealed record PreviewReloadNotification(
    int ReloadVersion,
    string State,
    string Target,
    ulong RequestId,
    string Source,
    string? SourceRevision = null,
    string? ArtifactRevision = null,
    long? ArtifactBytes = null,
    string? LatestRequestedSourceRevision = null,
    string? AcknowledgedSourceRevision = null,
    string? AcknowledgedArtifactRevision = null,
    string? FailedSourceRevision = null,
    string? Result = null,
    string? ErrorCode = null,
    string? Message = null,
    bool Ignored = false);
