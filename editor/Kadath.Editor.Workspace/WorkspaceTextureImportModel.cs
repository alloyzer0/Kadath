using System.Buffers.Binary;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using Kadath.Editor.Protocol;

namespace Kadath.Editor.Workspace;

public enum WorkspaceTextureImportFailureKind
{
    InvalidSource,
    InvalidAssetName,
    InvalidProfile,
    Conflict,
    Validation,
    Promote,
    Invariant
}

public sealed class WorkspaceTextureImportException : Exception
{
    public WorkspaceTextureImportException(WorkspaceTextureImportFailureKind kind, string message, Exception? innerException = null)
        : base(message, innerException) => Kind = kind;

    public WorkspaceTextureImportFailureKind Kind { get; }
}

internal enum WorkspaceTextureImportPhase
{
    AfterSourceLengthCaptured,
    BeforePromote
}

public sealed class WorkspaceTextureImportModel
{
    private const int TextureArtifactVersionBase = 1;
    private const int TextureArtifactVersionMipmap = 2;
    private const int TextureArtifactHeaderBytesBase = 20;
    private const int TextureArtifactHeaderBytesMipmap = 24;
    private const int TextureArtifactMaxPixels = 1024 * 1024;
    private const int TextureArtifactMaxBytes = 8 * 1024 * 1024;
    private const int TextureSourceMaxBytes = 16 * 1024 * 1024;
    private const int MaxAssetItems = 4096;
    private static readonly Regex AssetNamePattern = new("^[A-Za-z0-9][A-Za-z0-9_-]{0,47}(\\.texture)?$", RegexOptions.CultureInvariant);
    private static readonly StringComparison PathComparison = OperatingSystem.IsWindows()
        ? StringComparison.OrdinalIgnoreCase
        : StringComparison.Ordinal;
    private readonly Action<WorkspaceTextureImportPhase>? _phase;

    public WorkspaceTextureImportModel() { }

    internal WorkspaceTextureImportModel(Action<WorkspaceTextureImportPhase>? phase) => _phase = phase;

    internal static byte[] EncodeSourceFile(string sourcePath, string profile) => Execute(() =>
    {
        // 构建工具与 Editor 导入共用同一个 codec seam，避免两套 PNG/KDAT 规则再次漂移。
        var normalizedProfile = NormalizeProfile(profile);
        var source = ResolveSource(sourcePath);
        var texture = DecodeSource(source);
        var levels = BuildLevels(texture, normalizedProfile);
        return BuildArtifact(texture, levels, normalizedProfile);
    }, CancellationToken.None);

    public Task<TextureImportResult> ImportAsync(
        ProjectSessionInfo project,
        TextureImportParameters parameters,
        CancellationToken cancellationToken) =>
        Task.FromResult(Execute(() => ImportCore(project, parameters, cancellationToken), cancellationToken));

    private TextureImportResult ImportCore(ProjectSessionInfo project, TextureImportParameters parameters, CancellationToken cancellationToken)
    {
        var paths = WorkspaceProjectValidator.ResolveOpenPaths(project);
        var profile = NormalizeProfile(parameters.Profile);
        var source = ResolveSource(parameters.SourcePath);
        var assetName = NormalizeAssetName(parameters.AssetName);
        var binAssets = EnsureInside(paths.PackageRoot, Path.Combine(paths.BinDirectory, "assets"), "Package asset root");
        var rendererAssets = EnsureInside(binAssets, Path.Combine(binAssets, "renderer2d"), "Renderer2D asset directory");
        var destination = EnsureInside(rendererAssets, Path.Combine(rendererAssets, assetName), "Texture import destination");
        var relativePath = Path.GetRelativePath(paths.BinDirectory, destination).Replace('\\', '/');
        if (!WorkspaceProjectValidator.IsTextureArtifactPath(relativePath)) throw Failure(WorkspaceTextureImportFailureKind.InvalidAssetName, "Texture import destination must stay under assets/renderer2d/*.texture.");
        RejectExistingPathChain(paths.PackageRoot, destination, "Texture import destination");
        if (File.Exists(destination) || Directory.Exists(destination) || HasCaseInsensitiveSibling(destination))
        {
            throw Failure(WorkspaceTextureImportFailureKind.Conflict, $"Texture asset already exists: {relativePath}.");
        }
        var catalogBefore = WorkspaceReadModel.ReadAssetsCore(project, cancellationToken);
        if (catalogBefore.ItemCount >= MaxAssetItems)
        {
            throw Failure(WorkspaceTextureImportFailureKind.Validation, $"Asset Catalog is full: {catalogBefore.ItemCount} >= {MaxAssetItems}.");
        }

        cancellationToken.ThrowIfCancellationRequested();
        var texture = DecodeSource(source, () => _phase?.Invoke(WorkspaceTextureImportPhase.AfterSourceLengthCaptured));
        var levels = BuildLevels(texture, profile);
        var artifact = BuildArtifact(texture, levels, profile);
        var sha256 = Sha256(artifact);
        EnsureOutputDirectory(binAssets, "Package asset root");
        EnsureOutputDirectory(rendererAssets, "Renderer2D asset directory");
        Promote(destination, artifact, cancellationToken);
        AssetCatalogSnapshot catalog;
        var assetId = "asset://" + relativePath["assets/".Length..];
        try
        {
            catalog = WorkspaceReadModel.ReadAssetsCore(project, cancellationToken);
            if (!catalog.Items.Any(item => item.AssetId == assetId && item.Category == "Texture"))
            {
                throw Failure(WorkspaceTextureImportFailureKind.Invariant, "Imported texture was not visible in the refreshed Asset Catalog.");
            }
        }
        catch
        {
            RollbackImportedArtifact(destination, artifact);
            throw;
        }
        return new TextureImportResult(
            "succeeded",
            project.ProjectName,
            source.Path,
            assetId,
            relativePath,
            profile,
            texture.SourceFormat,
            profile == "release" ? "KDAT-TEXTURE-V2-MIPMAP" : "KDAT-TEXTURE-V1",
            texture.Width,
            texture.Height,
            levels.Count,
            $"{source.Extension[1..]}-to-rgba8-{(profile == "release" ? "mipmap-artifact-v2" : "artifact-v1")}",
            artifact.Length,
            sha256,
            catalog);
    }

    private void Promote(string destination, byte[] artifact, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var temporary = Path.Combine(Path.GetDirectoryName(destination) ?? throw Failure(WorkspaceTextureImportFailureKind.Validation, $"Texture destination has no parent: {destination}."),
            $".kadath-texture-import-{Guid.NewGuid():N}.tmp");
        var ownsTemporary = false;
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
            {
                ownsTemporary = true;
                stream.Write(artifact);
                stream.Flush(true);
            }
            _phase?.Invoke(WorkspaceTextureImportPhase.BeforePromote);
            cancellationToken.ThrowIfCancellationRequested();
            if (File.Exists(destination) || Directory.Exists(destination) || HasCaseInsensitiveSibling(destination))
            {
                throw Failure(WorkspaceTextureImportFailureKind.Conflict, $"Texture asset already exists: {destination}.");
            }
            File.Move(temporary, destination, false);
            ownsTemporary = false;
        }
        catch (WorkspaceTextureImportException) { throw; }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            throw Failure(WorkspaceTextureImportFailureKind.Promote, $"Failed to promote texture artifact {destination}: {exception.Message}", exception);
        }
        finally
        {
            if (ownsTemporary)
            {
                try { if (File.Exists(temporary)) File.Delete(temporary); }
                catch { }
            }
        }
    }

    private static WorkspaceTexturePixels DecodeSource(TextureSource source, Action? afterSnapshotLength = null) =>
        source.Extension == ".png"
            ? WorkspaceTexturePngCodec.DecodeFile(source.Path, afterSnapshotLength)
            : ParsePpm3(source.Path);

    private static WorkspaceTexturePixels ParsePpm3(string path)
    {
        RequireSourceBudget(path);
        var contents = File.ReadAllText(path, Encoding.UTF8);
        var tokens = Regex.Replace(contents, "(?m)#.*$", string.Empty)
            .Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        if (tokens.Length < 4 || tokens[0] != "P3") throw Failure(WorkspaceTextureImportFailureKind.InvalidSource, "Texture source must use P3 PPM format.");
        var width = ParsePositiveInt(tokens[1], "PPM width");
        var height = ParsePositiveInt(tokens[2], "PPM height");
        var maxValue = ParsePositiveInt(tokens[3], "PPM max value");
        if (maxValue > 255) throw Failure(WorkspaceTextureImportFailureKind.InvalidSource, "PPM max value must be in [1, 255].");
        var pixelCount = CheckedPixelCount(width, height, "PPM");
        var expected = checked(4 + pixelCount * 3);
        if (tokens.Length != expected) throw Failure(WorkspaceTextureImportFailureKind.InvalidSource, $"PPM pixel token count mismatch: expected={expected - 4} actual={tokens.Length - 4}.");
        var pixels = new byte[checked(pixelCount * 4)];
        for (var pixel = 0; pixel < pixelCount; pixel++)
        {
            for (var channel = 0; channel < 3; channel++)
            {
                var sample = ParseInt(tokens[4 + pixel * 3 + channel], "PPM sample");
                if (sample < 0 || sample > maxValue) throw Failure(WorkspaceTextureImportFailureKind.InvalidSource, "PPM sample is outside max value range.");
                pixels[pixel * 4 + channel] = (byte)Math.Floor(sample * 255.0 / maxValue);
            }
            pixels[pixel * 4 + 3] = 255;
        }
        return new WorkspaceTexturePixels(width, height, pixels, "P3-PPM");
    }

    private static List<TextureLevel> BuildLevels(WorkspaceTexturePixels texture, string profile)
    {
        var levels = new List<TextureLevel> { new(texture.Width, texture.Height, texture.Pixels) };
        if (profile == "debug") return levels;
        var source = levels[0];
        while (source.Width > 1 || source.Height > 1)
        {
            var nextWidth = Math.Max(1, source.Width / 2);
            var nextHeight = Math.Max(1, source.Height / 2);
            var pixels = new byte[checked(nextWidth * nextHeight * 4)];
            for (var y = 0; y < nextHeight; y++)
            {
                for (var x = 0; x < nextWidth; x++)
                {
                    var sums = new int[4];
                    for (var dy = 0; dy < 2; dy++)
                    {
                        var sampleY = Math.Min(source.Height - 1, y * 2 + dy);
                        for (var dx = 0; dx < 2; dx++)
                        {
                            var sampleX = Math.Min(source.Width - 1, x * 2 + dx);
                            var sampleOffset = ((sampleY * source.Width) + sampleX) * 4;
                            for (var channel = 0; channel < 4; channel++) sums[channel] += source.Pixels[sampleOffset + channel];
                        }
                    }
                    var offset = ((y * nextWidth) + x) * 4;
                    for (var channel = 0; channel < 4; channel++) pixels[offset + channel] = (byte)(sums[channel] / 4);
                }
            }
            source = new TextureLevel(nextWidth, nextHeight, pixels);
            levels.Add(source);
        }
        return levels;
    }

    private static byte[] BuildArtifact(WorkspaceTexturePixels texture, IReadOnlyList<TextureLevel> levels, string profile)
    {
        var release = profile == "release";
        var headerBytes = release ? TextureArtifactHeaderBytesMipmap : TextureArtifactHeaderBytesBase;
        var pixelBytes = checked(levels.Sum(level => level.Pixels.Length));
        var artifactBytes = checked(headerBytes + pixelBytes);
        if (artifactBytes >= TextureArtifactMaxBytes) throw Failure(WorkspaceTextureImportFailureKind.Validation, $"Texture artifact must be strictly smaller than {TextureArtifactMaxBytes} bytes: {artifactBytes}.");
        var artifact = new byte[artifactBytes];
        Encoding.ASCII.GetBytes("KDAT", 0, 4, artifact, 0);
        BinaryPrimitives.WriteUInt32LittleEndian(artifact.AsSpan(4, 4), (uint)(release ? TextureArtifactVersionMipmap : TextureArtifactVersionBase));
        BinaryPrimitives.WriteUInt32LittleEndian(artifact.AsSpan(8, 4), (uint)texture.Width);
        BinaryPrimitives.WriteUInt32LittleEndian(artifact.AsSpan(12, 4), (uint)texture.Height);
        if (release)
        {
            BinaryPrimitives.WriteUInt32LittleEndian(artifact.AsSpan(16, 4), (uint)levels.Count);
            BinaryPrimitives.WriteUInt32LittleEndian(artifact.AsSpan(20, 4), (uint)pixelBytes);
        }
        else
        {
            BinaryPrimitives.WriteUInt32LittleEndian(artifact.AsSpan(16, 4), (uint)pixelBytes);
        }
        var offset = headerBytes;
        foreach (var level in levels)
        {
            level.Pixels.CopyTo(artifact, offset);
            offset += level.Pixels.Length;
        }
        return artifact;
    }

    private static TextureSource ResolveSource(string sourcePath)
    {
        if (string.IsNullOrWhiteSpace(sourcePath)) throw Failure(WorkspaceTextureImportFailureKind.InvalidSource, "Texture source path is required.");
        var path = Path.GetFullPath(sourcePath);
        if (!File.Exists(path)) throw Failure(WorkspaceTextureImportFailureKind.InvalidSource, $"Texture source does not exist: {path}.");
        WorkspaceProjectValidator.RejectReparsePoint(path, "Texture source");
        var extension = Path.GetExtension(path).ToLowerInvariant();
        if (extension is not (".ppm" or ".png")) throw Failure(WorkspaceTextureImportFailureKind.InvalidSource, "Texture importer expects a .ppm or .png source.");
        return new TextureSource(path, extension);
    }

    private static void RequireSourceBudget(string path)
    {
        var length = new FileInfo(path).Length;
        if (length > TextureSourceMaxBytes)
        {
            throw Failure(WorkspaceTextureImportFailureKind.InvalidSource, $"Texture source exceeds the {TextureSourceMaxBytes} byte import budget: {length}.");
        }
    }

    private static string NormalizeAssetName(string assetName)
    {
        if (string.IsNullOrWhiteSpace(assetName) || !AssetNamePattern.IsMatch(assetName) || assetName.Contains('/') || assetName.Contains('\\'))
        {
            throw Failure(WorkspaceTextureImportFailureKind.InvalidAssetName, "AssetName must be a safe renderer2d texture filename.");
        }
        return assetName.EndsWith(".texture", StringComparison.Ordinal) ? assetName : $"{assetName}.texture";
    }

    private static string NormalizeProfile(string profile) => profile switch
    {
        "debug" => "debug",
        "release" => "release",
        _ => throw Failure(WorkspaceTextureImportFailureKind.InvalidProfile, $"Unsupported texture import profile: {profile}.")
    };

    private static int CheckedPixelCount(int width, int height, string name)
    {
        var pixelCount = checked(width * height);
        if (pixelCount > TextureArtifactMaxPixels) throw Failure(WorkspaceTextureImportFailureKind.InvalidSource, $"{name} exceeds pixel limit: {pixelCount} > {TextureArtifactMaxPixels}.");
        return pixelCount;
    }

    private static int ParsePositiveInt(string token, string name)
    {
        var value = ParseInt(token, name);
        if (value <= 0) throw Failure(WorkspaceTextureImportFailureKind.InvalidSource, $"{name} must be positive.");
        return value;
    }

    private static int ParseInt(string token, string name)
    {
        if (!int.TryParse(token, NumberStyles.Integer, CultureInfo.InvariantCulture, out var value))
            throw Failure(WorkspaceTextureImportFailureKind.InvalidSource, $"{name} must be an integer.");
        return value;
    }

    private static void EnsureOutputDirectory(string path, string name)
    {
        if (File.Exists(path)) throw Failure(WorkspaceTextureImportFailureKind.Validation, $"{name} is a file: {path}.");
        if (Directory.Exists(path)) WorkspaceProjectValidator.RejectReparsePoint(path, name);
        else Directory.CreateDirectory(path);
    }

    private static bool HasCaseInsensitiveSibling(string path)
    {
        var parent = Path.GetDirectoryName(path);
        if (parent is null || !Directory.Exists(parent)) return false;
        var name = Path.GetFileName(path);
        return Directory.EnumerateFileSystemEntries(parent).Any(entry => string.Equals(Path.GetFileName(entry), name, StringComparison.OrdinalIgnoreCase));
    }

    private static void RollbackImportedArtifact(string destination, byte[] artifact)
    {
        try
        {
            if (!File.Exists(destination)) return;
            WorkspaceProjectValidator.RejectReparsePoint(destination, "Texture import rollback target");
            if (File.ReadAllBytes(destination).AsSpan().SequenceEqual(artifact)) File.Delete(destination);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            throw Failure(WorkspaceTextureImportFailureKind.Invariant, $"Texture import catalog refresh failed and rollback failed: {exception.Message}", exception);
        }
    }

    private static string EnsureInside(string root, string path, string name)
    {
        var fullRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var fullPath = Path.GetFullPath(path);
        var prefix = fullRoot + Path.DirectorySeparatorChar;
        if (!fullPath.Equals(fullRoot, PathComparison) && !fullPath.StartsWith(prefix, PathComparison))
            throw Failure(WorkspaceTextureImportFailureKind.Validation, $"{name} escapes root: {path}.");
        return fullPath;
    }

    private static void RejectExistingPathChain(string root, string path, string name)
    {
        WorkspaceProjectValidator.RejectReparsePoint(root, "Package root");
        var relative = Path.GetRelativePath(root, path);
        var current = Path.GetFullPath(root);
        foreach (var segment in relative.Split([Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar], StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, segment);
            if (Directory.Exists(current) || File.Exists(current)) WorkspaceProjectValidator.RejectReparsePoint(current, name);
            else break;
        }
    }

    private static string Sha256(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();

    private static T Execute<T>(Func<T> operation, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        try { return operation(); }
        catch (OperationCanceledException) { throw; }
        catch (WorkspaceTextureImportException) { throw; }
        catch (WorkspaceProjectValidationException exception)
        {
            throw Failure(WorkspaceTextureImportFailureKind.Validation, exception.Message, exception);
        }
        catch (WorkspaceReadException exception)
        {
            throw Failure(exception.Kind == WorkspaceReadFailureKind.Invariant ? WorkspaceTextureImportFailureKind.Invariant : WorkspaceTextureImportFailureKind.Validation,
                exception.Message, exception);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or InvalidDataException or FormatException or OverflowException)
        {
            throw Failure(WorkspaceTextureImportFailureKind.InvalidSource, exception.Message, exception);
        }
    }

    private static WorkspaceTextureImportException Failure(WorkspaceTextureImportFailureKind kind, string message, Exception? innerException = null) =>
        new(kind, message, innerException);

    private sealed record TextureSource(string Path, string Extension);
    private sealed record TextureLevel(int Width, int Height, byte[] Pixels);
}
