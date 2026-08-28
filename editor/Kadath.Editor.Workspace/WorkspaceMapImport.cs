using System.Security.Cryptography;
using System.Text;

namespace Kadath.Editor.Workspace;

internal enum WorkspaceMapImportSeverity { Warning, Error }

internal sealed record WorkspaceMapImportDiagnostic(
    WorkspaceMapImportSeverity Severity,
    string Code,
    string SourcePath,
    string JsonPath,
    string Message);

internal sealed record WorkspaceMapImportRequest(
    string SourcePath,
    IReadOnlyList<uint> TextureIds,
    string? LevelIid = null,
    bool Strict = false);

internal sealed record WorkspaceMapImportResult(
    string SourceKind,
    string SourceVersion,
    string[] SourceDocuments,
    WorkspaceTilemapAsset Asset,
    WorkspaceMapImportDiagnostic[] Diagnostics);

internal sealed class WorkspaceMapImportException : Exception
{
    internal WorkspaceMapImportException(string code, string message, string sourcePath, string jsonPath, Exception? inner = null)
        : base(message, inner)
    {
        Code = code;
        SourcePath = sourcePath;
        JsonPath = jsonPath;
    }

    internal string Code { get; }
    internal string SourcePath { get; }
    internal string JsonPath { get; }
}

/// <summary>
/// 外部地图导入的唯一 Interface。调用方只看到规范资产和结构化诊断；
/// Tiled/LDtk 的版本、路径和字段差异由两个 Adapter 封装。
/// </summary>
internal static class WorkspaceMapImport
{
    internal const int MaxSourceBytes = 64 * 1024 * 1024;

    internal static WorkspaceMapImportResult Import(WorkspaceMapImportRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        var source = ResolveRootSource(request.SourcePath);
        var extension = Path.GetExtension(source).ToLowerInvariant();
        var result = extension switch
        {
            ".tmj" or ".json" => TiledMapImportAdapter.Import(source, request),
            ".ldtk" => LdtkMapImportAdapter.Import(source, request),
            _ => throw Error("IMPORT_UNSUPPORTED_FORMAT", "外部地图仅支持 .tmj/.json 或 .ldtk。", source, "$")
        };
        var diagnostics = result.Diagnostics
            .OrderBy(value => value.SourcePath, StringComparer.Ordinal)
            .ThenBy(value => value.JsonPath, StringComparer.Ordinal)
            .ThenBy(value => value.Code, StringComparer.Ordinal)
            .ToArray();
        if (request.Strict && diagnostics.Any(value => value.Severity == WorkspaceMapImportSeverity.Warning))
        {
            var first = diagnostics.First(value => value.Severity == WorkspaceMapImportSeverity.Warning);
            throw Error("IMPORT_STRICT_WARNING", $"严格导入拒绝未消费语义：{first.Code}。", first.SourcePath, first.JsonPath);
        }
        WorkspaceTilemapAssetCodec.Validate(result.Asset);
        return result with { Diagnostics = diagnostics };
    }

    internal static int FloorDiv(int value, int divisor)
    {
        if (divisor <= 0) throw new ArgumentOutOfRangeException(nameof(divisor));
        var quotient = value / divisor;
        var remainder = value % divisor;
        return remainder < 0 ? checked(quotient - 1) : quotient;
    }

    internal static string StableId(string prefix, string sourceIdentity)
    {
        var normalized = new string(sourceIdentity.ToLowerInvariant()
            .Select(character => character is >= 'a' and <= 'z' or >= '0' and <= '9' or '_' or '-' ? character : '-')
            .ToArray()).Trim('-');
        if (normalized.Length == 0) normalized = "item";
        var candidate = $"{prefix}-{normalized}";
        if (Encoding.UTF8.GetByteCount(candidate) <= 63) return candidate;
        var digest = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(sourceIdentity))).ToLowerInvariant()[..16];
        var available = Math.Max(1, 63 - prefix.Length - digest.Length - 2);
        return $"{prefix}-{normalized[..Math.Min(available, normalized.Length)]}-{digest}";
    }

    internal static string ResolveReference(string importRoot, string declaringDocument, string relativePath, params string[] allowedExtensions)
    {
        if (string.IsNullOrWhiteSpace(relativePath) || Path.IsPathRooted(relativePath)
            || relativePath.Contains('\0'))
            throw Error("IMPORT_INVALID_EXTERNAL_REFERENCE", "外部引用必须是非空相对路径。", declaringDocument, "$");
        var root = Path.GetFullPath(importRoot).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var candidate = Path.GetFullPath(Path.Combine(Path.GetDirectoryName(declaringDocument)!, relativePath));
        var comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        if (!candidate.StartsWith(root + Path.DirectorySeparatorChar, comparison) && !candidate.Equals(root, comparison))
            throw Error("IMPORT_INVALID_EXTERNAL_REFERENCE", $"外部引用逃逸导入根目录：{relativePath}。", declaringDocument, "$");
        if (!File.Exists(candidate))
            throw Error("IMPORT_INVALID_EXTERNAL_REFERENCE", $"外部引用不存在：{relativePath}。", declaringDocument, "$");
        if (allowedExtensions.Length != 0 && !allowedExtensions.Contains(Path.GetExtension(candidate), StringComparer.OrdinalIgnoreCase))
            throw Error("IMPORT_INVALID_EXTERNAL_REFERENCE", $"外部引用扩展名不受支持：{relativePath}。", declaringDocument, "$");
        RejectReparseChain(root, candidate);
        return candidate;
    }

    internal static byte[] ReadSource(string path)
    {
        var length = new FileInfo(path).Length;
        if (length is <= 0 or > MaxSourceBytes)
            throw Error("IMPORT_SOURCE_BUDGET", $"外部地图文档必须包含 1..{MaxSourceBytes} 字节。", path, "$");
        return File.ReadAllBytes(path);
    }

    internal static WorkspaceMapImportException Error(string code, string message, string sourcePath, string jsonPath, Exception? inner = null) =>
        new(code, message, sourcePath, jsonPath, inner);

    private static string ResolveRootSource(string sourcePath)
    {
        if (string.IsNullOrWhiteSpace(sourcePath)) throw Error("IMPORT_SOURCE_REQUIRED", "外部地图路径不能为空。", string.Empty, "$");
        var path = Path.GetFullPath(sourcePath);
        if (!File.Exists(path)) throw Error("IMPORT_SOURCE_NOT_FOUND", $"外部地图不存在：{path}。", path, "$");
        var root = Path.GetDirectoryName(path)!;
        RejectReparseChain(root, path);
        return path;
    }

    private static void RejectReparseChain(string root, string path)
    {
        WorkspaceProjectValidator.RejectReparsePoint(root, "Map import root");
        var current = root;
        foreach (var segment in Path.GetRelativePath(root, path).Split(
                     [Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar],
                     StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, segment);
            WorkspaceProjectValidator.RejectReparsePoint(current, "Map import reference");
        }
    }
}
