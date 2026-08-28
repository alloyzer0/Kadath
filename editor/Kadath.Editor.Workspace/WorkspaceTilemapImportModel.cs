using System.Security.Cryptography;
using System.Text.RegularExpressions;
using Kadath.Editor.Protocol;

namespace Kadath.Editor.Workspace;

public enum WorkspaceTilemapImportFailureKind
{
    InvalidSource,
    InvalidParameters,
    RevisionConflict,
    Conflict,
    Commit,
    Invariant
}

public sealed class WorkspaceTilemapImportException : Exception
{
    public WorkspaceTilemapImportException(WorkspaceTilemapImportFailureKind kind, string code, string message, Exception? inner = null)
        : base(message, inner)
    {
        Kind = kind;
        Code = code;
    }

    public WorkspaceTilemapImportFailureKind Kind { get; }
    public string Code { get; }
}

public sealed record WorkspaceTilemapImportCommit(
    TilemapImportResult Result,
    WorkspaceAuthoringUndoToken UndoToken);

/// <summary>
/// 把纯 Map Import Module、内容寻址 Tilemap asset 和 Workspace 原子 Scene transaction 收敛为一个操作。
/// 外部 Adapter 不直接写项目文件，避免半个地图或半组纹理 profile 被发布。
/// </summary>
public sealed partial class WorkspaceTilemapImportModel
{
    private readonly WorkspaceAuthoringModel _authoring;

    [GeneratedRegex("^[a-z][a-z0-9_-]{0,47}$", RegexOptions.CultureInvariant)]
    private static partial Regex AssetNamePattern();

    public WorkspaceTilemapImportModel() : this(new WorkspaceAuthoringModel()) { }

    public WorkspaceTilemapImportModel(WorkspaceAuthoringModel authoring) => _authoring = authoring;

    public async Task<TilemapImportResult> ImportAsync(
        ProjectSessionInfo project,
        TilemapImportParameters parameters,
        CancellationToken cancellationToken) =>
        (await ImportWithUndoAsync(project, parameters, cancellationToken)).Result;

    public async Task<WorkspaceTilemapImportCommit> ImportWithUndoAsync(
        ProjectSessionInfo project,
        TilemapImportParameters parameters,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(project);
        ArgumentNullException.ThrowIfNull(parameters);
        cancellationToken.ThrowIfCancellationRequested();
        ValidateParameters(parameters);

        WorkspaceMapImportResult imported;
        try
        {
            imported = WorkspaceMapImport.Import(new WorkspaceMapImportRequest(
                parameters.SourcePath,
                parameters.TextureIds,
                parameters.LevelIid,
                parameters.Strict));
        }
        catch (WorkspaceMapImportException exception)
        {
            throw Failure(WorkspaceTilemapImportFailureKind.InvalidSource, exception.Code, exception.Message, exception);
        }

        var artifact = WorkspaceTilemapAssetCodec.Encode(imported.Asset);
        var revision = Convert.ToHexString(SHA256.HashData(artifact)).ToLowerInvariant();
        var paths = WorkspaceProjectValidator.ResolveOpenPaths(project);
        var relativePath = $"assets/tilemaps/{parameters.AssetName}-{revision}.tilemap";
        if (!WorkspaceSceneDocumentCodec.IsTilemapArtifactPath(relativePath))
            throw Failure(WorkspaceTilemapImportFailureKind.InvalidParameters, "TILEMAP_IMPORT_INVALID_ASSET_NAME", "Tilemap asset path is invalid.");
        var destination = Path.GetFullPath(Path.Combine(paths.BinDirectory, relativePath.Replace('/', Path.DirectorySeparatorChar)));
        var created = false;
        try
        {
            created = PublishContentAddressed(paths, destination, artifact);
            var readModel = new WorkspaceReadModel();
            var current = await readModel.ReadProjectAsync(project, cancellationToken);
            if (!current.AuthoringRevision.Equals(parameters.ExpectedRevision, StringComparison.OrdinalIgnoreCase))
                throw Failure(WorkspaceTilemapImportFailureKind.RevisionConflict, "tilemap_import_revision_conflict",
                    $"Expected {parameters.ExpectedRevision} but current revision is {current.AuthoringRevision}.");
            var textures = current.Scene.Textures ?? throw Failure(WorkspaceTilemapImportFailureKind.Invariant, "tilemap_import_protocol_error", "Scene texture snapshot is missing.");
            var textureIds = parameters.TextureIds.ToHashSet();
            if (textureIds.Count != parameters.TextureIds.Count || textureIds.Any(id => textures.All(texture => texture.TextureId != id)))
                throw Failure(WorkspaceTilemapImportFailureKind.InvalidParameters, "tilemap_import_texture_binding_invalid", "TextureIds must be unique existing Scene textures.");
            var assignments = textures.Select(texture => new SceneTextureAssignment(
                texture.TextureId,
                "asset://" + texture.Artifact["assets/".Length..],
                textureIds.Contains(texture.TextureId) ? WorkspaceSceneDocumentCodec.PixelArtProfile : texture.SamplingProfile)).ToArray();
            var existing = current.Scene.ChunkedTilemaps ?? Array.Empty<ProjectModelSceneChunkedTilemap>();
            if ((current.Scene.Tilemaps?.Count ?? 0) != 0)
                throw Failure(WorkspaceTilemapImportFailureKind.Conflict, "tilemap_import_legacy_conflict", "Remove or migrate the legacy inline Tilemap before importing a chunked Tilemap.");
            if (existing.Any(value => value.TilemapId == parameters.TilemapId))
                throw Failure(WorkspaceTilemapImportFailureKind.Conflict, "tilemap_import_id_conflict", $"TilemapId already exists: {parameters.TilemapId}.");
            var definitions = existing.Select(value => new SceneChunkedTilemapDefinition(
                    value.TilemapId,
                    value.Origin,
                    value.Artifact,
                    value.ArtifactRevision,
                    value.ArtifactBytes))
                .Append(new SceneChunkedTilemapDefinition(parameters.TilemapId, [0, 0], relativePath, revision, artifact.LongLength))
                .ToArray();

            WorkspaceAuthoringCommit commit;
            try
            {
                commit = await _authoring.ApplyAsync(project, parameters.ExpectedRevision,
                    new AuthoringPatch(SceneTextures: assignments, SceneChunkedTilemaps: definitions), cancellationToken);
            }
            catch (WorkspaceAuthoringException exception)
            {
                throw Failure(exception.Kind == WorkspaceAuthoringFailureKind.RevisionConflict
                        ? WorkspaceTilemapImportFailureKind.RevisionConflict
                        : WorkspaceTilemapImportFailureKind.Commit,
                    exception.Kind == WorkspaceAuthoringFailureKind.RevisionConflict ? "tilemap_import_revision_conflict" : "tilemap_import_commit_failed",
                    exception.Message,
                    exception);
            }

            var catalog = WorkspaceReadModel.ReadAssetsCore(project, cancellationToken);
            var assetId = "asset://" + relativePath["assets/".Length..];
            if (!catalog.Items.Any(item => item.AssetId == assetId && item.Category == "Tilemap"))
                throw Failure(WorkspaceTilemapImportFailureKind.Invariant, "tilemap_import_protocol_error", "Committed Tilemap asset is absent from Asset Catalog.");
            var result = new TilemapImportResult(
                "succeeded",
                project.ProjectName,
                commit.PreviousRevision,
                commit.Revision,
                imported.SourceKind,
                imported.SourceVersion,
                assetId,
                relativePath,
                revision,
                artifact.LongLength,
                imported.Asset.TileSources.Length,
                imported.Asset.Layers.Length,
                imported.Asset.Layers.Sum(layer => layer.Chunks.Length),
                imported.Asset.Layers.Sum(layer => layer.Chunks.Sum(chunk => chunk.Cells.Length)),
                imported.Diagnostics.Select(value => new TilemapImportDiagnostic(
                    value.Severity == WorkspaceMapImportSeverity.Warning ? "warning" : "error",
                    value.Code,
                    value.SourcePath,
                    value.JsonPath,
                    value.Message)).ToArray(),
                commit.ProjectSnapshot,
                commit.HierarchySnapshot,
                catalog);
            return new WorkspaceTilemapImportCommit(
                result,
                commit.UndoToken ?? throw Failure(WorkspaceTilemapImportFailureKind.Invariant, "tilemap_import_protocol_error", "Tilemap import commit emitted no undo token."));
        }
        catch
        {
            if (created) RollbackOwned(destination, artifact);
            throw;
        }
    }

    private static bool PublishContentAddressed(WorkspaceProjectPaths paths, string destination, byte[] bytes)
    {
        var root = Path.GetFullPath(paths.BinDirectory).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        if (!destination.StartsWith(root + Path.DirectorySeparatorChar, OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal))
            throw Failure(WorkspaceTilemapImportFailureKind.Invariant, "tilemap_import_path_escape", "Tilemap destination escapes bin root.");
        var parent = Path.GetDirectoryName(destination)!;
        Directory.CreateDirectory(parent);
        WorkspaceProjectValidator.RejectReparsePoint(parent, "Tilemap asset directory");
        if (File.Exists(destination))
        {
            WorkspaceProjectValidator.RejectReparsePoint(destination, "Tilemap asset");
            if (!File.ReadAllBytes(destination).AsSpan().SequenceEqual(bytes))
                throw Failure(WorkspaceTilemapImportFailureKind.Conflict, "tilemap_import_content_conflict", "Content-addressed Tilemap path contains different bytes.");
            return false;
        }
        var temporary = Path.Combine(parent, $".kadath-tilemap-import-{Guid.NewGuid():N}.tmp");
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1024 * 1024, FileOptions.WriteThrough))
            {
                stream.Write(bytes);
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporary, destination, overwrite: false);
            return true;
        }
        finally
        {
            try { if (File.Exists(temporary)) File.Delete(temporary); }
            catch { }
        }
    }

    private static void RollbackOwned(string destination, byte[] expected)
    {
        try
        {
            if (File.Exists(destination) && File.ReadAllBytes(destination).AsSpan().SequenceEqual(expected)) File.Delete(destination);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            throw Failure(WorkspaceTilemapImportFailureKind.Invariant, "tilemap_import_rollback_failed", exception.Message, exception);
        }
    }

    private static void ValidateParameters(TilemapImportParameters parameters)
    {
        if (string.IsNullOrWhiteSpace(parameters.ExpectedRevision) || parameters.ExpectedRevision.Length != 64 || parameters.ExpectedRevision.Any(value => !Uri.IsHexDigit(value)))
            throw Failure(WorkspaceTilemapImportFailureKind.InvalidParameters, "invalid_expected_revision", "ExpectedRevision must be SHA-256 hex.");
        if (!AssetNamePattern().IsMatch(parameters.AssetName))
            throw Failure(WorkspaceTilemapImportFailureKind.InvalidParameters, "TILEMAP_IMPORT_INVALID_ASSET_NAME", "AssetName must match [a-z][a-z0-9_-]{0,47}.");
        if (!AssetNamePattern().IsMatch(parameters.TilemapId) || System.Text.Encoding.UTF8.GetByteCount(parameters.TilemapId) > 63)
            throw Failure(WorkspaceTilemapImportFailureKind.InvalidParameters, "TILEMAP_IMPORT_INVALID_ID", "TilemapId must be a valid stable ID.");
        if (parameters.TextureIds is not { Count: > 0 and <= WorkspaceTilemapAssetCodec.MaxTileSources })
            throw Failure(WorkspaceTilemapImportFailureKind.InvalidParameters, "tilemap_import_texture_binding_invalid", "TextureIds count is outside the Tile source budget.");
    }

    private static WorkspaceTilemapImportException Failure(WorkspaceTilemapImportFailureKind kind, string code, string message, Exception? inner = null) =>
        new(kind, code, message, inner);
}
