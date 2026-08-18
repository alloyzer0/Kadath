using System.Globalization;
using System.Runtime.ExceptionServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Kadath.Editor.Toolchain;

internal sealed record ToolchainBuildProfileRequest(
    string RuntimeExecutablePath,
    string TextureSourcePath,
    string TextureArtifactPath,
    string SecondaryTextureSourcePath,
    string SecondaryTextureArtifactPath,
    string VertexShaderSourcePath,
    string FragmentShaderSourcePath,
    string Optimize,
    string PackageRoot,
    string TaskLocalCacheDirectory,
    string GlobalCacheDirectory,
    string? PreflightSidecarPath,
    string DestinationPath);

internal sealed record ToolchainBuildProfileResult(
    string DestinationPath,
    string Sha256,
    string? PreflightSidecarSha256);

internal sealed record ToolchainBuildProfileDocument(
    int Version,
    string Optimize,
    string TextureProfile,
    string RuntimeExeSha256,
    string TextureSourceSha256,
    string TextureArtifactSha256,
    string SecondaryTextureSourceSha256,
    string SecondaryTextureArtifactSha256,
    string VertexShaderSourceSha256,
    string FragmentShaderSourceSha256,
    string BuildPreflightSidecarSha256);

internal static class ToolchainBuildProfile
{
    private const int MaximumJsonBytes = 65536;
    private static readonly UTF8Encoding StrictUtf8 = new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);
    private static readonly string[] PreflightFields =
    [
        "Version",
        "GeneratedAtUtc",
        "PackageRoot",
        "TaskLocalCacheDirectory",
        "GlobalCacheDirectory",
        "PackageRootAbsentBefore",
        "TaskLocalCacheAbsentBefore",
        "GlobalCacheAbsentBefore"
    ];
    private static readonly string[] ProfileFields =
    [
        "Version",
        "Optimize",
        "TextureProfile",
        "RuntimeExeSha256",
        "TextureSourceSha256",
        "TextureArtifactSha256",
        "SecondaryTextureSourceSha256",
        "SecondaryTextureArtifactSha256",
        "VertexShaderSourceSha256",
        "FragmentShaderSourceSha256",
        "BuildPreflightSidecarSha256"
    ];

    internal static ToolchainBuildProfileResult Execute(ToolchainBuildProfileRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (string.IsNullOrWhiteSpace(request.Optimize)) throw new ArgumentException("Optimize cannot be empty.", nameof(request));

        var runtime = ToolchainPathPolicy.ResolveExistingFile(request.RuntimeExecutablePath, "Runtime executable");
        var textureSource = ToolchainPathPolicy.ResolveExistingFile(request.TextureSourcePath, "Primary texture source snapshot");
        var textureArtifact = ToolchainPathPolicy.ResolveExistingFile(request.TextureArtifactPath, "Primary texture artifact");
        var secondaryTextureSource = ToolchainPathPolicy.ResolveExistingFile(request.SecondaryTextureSourcePath, "Secondary texture source snapshot");
        var secondaryTextureArtifact = ToolchainPathPolicy.ResolveExistingFile(request.SecondaryTextureArtifactPath, "Secondary texture artifact");
        var vertexShader = ToolchainPathPolicy.ResolveExistingFile(request.VertexShaderSourcePath, "Vertex shader source");
        var fragmentShader = ToolchainPathPolicy.ResolveExistingFile(request.FragmentShaderSourcePath, "Fragment shader source");

        string? preflightSha256 = null;
        if (!string.IsNullOrWhiteSpace(request.PreflightSidecarPath) && !request.PreflightSidecarPath.Equals("-", StringComparison.Ordinal))
            preflightSha256 = ValidatePreflight(request);

        var profileBytes = SerializeProfile(
            request.Optimize,
            HashFile(runtime),
            HashFile(textureSource),
            HashFile(textureArtifact),
            HashFile(secondaryTextureSource),
            HashFile(secondaryTextureArtifact),
            HashFile(vertexShader),
            HashFile(fragmentShader),
            preflightSha256);
        var destination = ToolchainPathPolicy.CanonicalAbsoluteLocalPath(
            request.DestinationPath,
            "Runtime build profile destination",
            requireCanonicalSpelling: false);
        ToolchainDurableFile.WriteAtomicNoReplace(destination, profileBytes, ".kadath-runtime-build-profile");
        return new ToolchainBuildProfileResult(destination, Sha256(profileBytes), preflightSha256);
    }

    internal static ToolchainBuildProfileDocument ParseStrictExactEleven(byte[] bytes)
    {
        if (bytes.Length is 0 or > MaximumJsonBytes)
            throw new InvalidDataException("Runtime build profile marker must contain 1..65536 bytes.");

        try
        {
            var json = StrictUtf8.GetString(bytes);
            using var document = JsonDocument.Parse(json, new JsonDocumentOptions
            {
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow
            });
            var root = document.RootElement;
            AssertExactObject(root, ProfileFields, "Runtime build profile marker");
            var version = root.GetProperty("Version");
            if (version.ValueKind != JsonValueKind.Number || version.GetInt32() != 2)
                throw new InvalidDataException("Version must be the JSON number 2.");
            foreach (var field in ProfileFields.Skip(1))
            {
                if (root.GetProperty(field).ValueKind != JsonValueKind.String)
                    throw new InvalidDataException($"{field} must be a JSON string.");
            }

            return new ToolchainBuildProfileDocument(
                2,
                RequireString(root, "Optimize"),
                RequireString(root, "TextureProfile"),
                RequireString(root, "RuntimeExeSha256"),
                RequireString(root, "TextureSourceSha256"),
                RequireString(root, "TextureArtifactSha256"),
                RequireString(root, "SecondaryTextureSourceSha256"),
                RequireString(root, "SecondaryTextureArtifactSha256"),
                RequireString(root, "VertexShaderSourceSha256"),
                RequireString(root, "FragmentShaderSourceSha256"),
                RequireString(root, "BuildPreflightSidecarSha256"));
        }
        catch (Exception exception) when (exception is DecoderFallbackException or JsonException or InvalidDataException or FormatException or OverflowException)
        {
            throw new InvalidDataException(
                $"Runtime build profile marker is not strict UTF-8 exact-eleven JSON schema v2: {exception.Message}",
                exception);
        }
    }

    internal static void AssertReleaseIdentity(
        byte[] profileBytes,
        string runtimeSha256,
        string textureSourceSha256,
        string textureArtifactSha256,
        string secondaryTextureSourceSha256,
        string secondaryTextureArtifactSha256,
        string vertexShaderSourceSha256,
        string fragmentShaderSourceSha256)
    {
        var profile = ParseStrictExactEleven(profileBytes);
        if (profile.Optimize != "ReleaseSafe" || profile.TextureProfile != "release" ||
            profile.RuntimeExeSha256 != runtimeSha256 ||
            profile.TextureSourceSha256 != textureSourceSha256 ||
            profile.TextureArtifactSha256 != textureArtifactSha256 ||
            profile.SecondaryTextureSourceSha256 != secondaryTextureSourceSha256 ||
            profile.SecondaryTextureArtifactSha256 != secondaryTextureArtifactSha256 ||
            profile.VertexShaderSourceSha256 != vertexShaderSourceSha256 ||
            profile.FragmentShaderSourceSha256 != fragmentShaderSourceSha256 ||
            !IsLowerSha256(profile.BuildPreflightSidecarSha256))
            throw new InvalidDataException(
                "Runtime archive requires a sidecar-bound ReleaseSafe marker matching the executable, both PNG/KDAT pairs, and clean shader identities.");
    }

    private static string ValidatePreflight(ToolchainBuildProfileRequest request)
    {
        var preflightPath = ToolchainPathPolicy.ResolveExistingFile(request.PreflightSidecarPath!, "Runtime preflight sidecar");
        byte[] bytes;
        using (var stream = WindowsFileIdentityAdapter.OpenFrozenRead(preflightPath))
        {
            if (stream.Length is <= 0 or > MaximumJsonBytes)
                throw new InvalidDataException("Runtime preflight sidecar must contain 1..65536 bytes.");
            bytes = GC.AllocateUninitializedArray<byte>(checked((int)stream.Length));
            stream.ReadExactly(bytes);
            if (stream.ReadByte() != -1) throw new InvalidDataException("Runtime preflight sidecar grew during read.");
        }

        JsonElement root;
        try
        {
            var json = StrictUtf8.GetString(bytes);
            using var document = JsonDocument.Parse(json, new JsonDocumentOptions
            {
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow
            });
            root = document.RootElement.Clone();
        }
        catch (Exception exception) when (exception is DecoderFallbackException or JsonException)
        {
            throw new InvalidDataException($"Runtime preflight sidecar is not strict UTF-8 JSON: {exception.Message}", exception);
        }

        AssertExactObject(root, PreflightFields, "Runtime preflight sidecar");
        var version = root.GetProperty("Version");
        if (version.ValueKind != JsonValueKind.Number || version.GetInt32() != 1)
            throw new InvalidDataException("Runtime preflight sidecar Version must be the JSON number 1.");
        var generatedAtText = RequireString(root, "GeneratedAtUtc");
        if (!DateTimeOffset.TryParseExact(
                generatedAtText,
                "O",
                CultureInfo.InvariantCulture,
                DateTimeStyles.None,
                out var generatedAt) || generatedAt.Offset != TimeSpan.Zero)
            throw new InvalidDataException("Runtime preflight sidecar has an invalid v1 GeneratedAtUtc.");

        foreach (var field in new[] { "PackageRootAbsentBefore", "TaskLocalCacheAbsentBefore", "GlobalCacheAbsentBefore" })
        {
            var value = root.GetProperty(field);
            if (value.ValueKind != JsonValueKind.True)
                throw new InvalidDataException("Runtime preflight sidecar must witness all roots absent before build.");
        }

        ValidateClaimedRoot(root, "PackageRoot", request.PackageRoot);
        ValidateClaimedRoot(root, "TaskLocalCacheDirectory", request.TaskLocalCacheDirectory);
        ValidateClaimedRoot(root, "GlobalCacheDirectory", request.GlobalCacheDirectory);

        var sidecarLastWriteUtc = File.GetLastWriteTimeUtc(preflightPath);
        var tolerance = TimeSpan.FromSeconds(2);
        if (Math.Abs((generatedAt.UtcDateTime - sidecarLastWriteUtc).TotalSeconds) > tolerance.TotalSeconds)
            throw new InvalidDataException("Runtime preflight GeneratedAtUtc and sidecar LastWriteTimeUtc differ by more than 2 seconds.");

        foreach (var (path, name) in new[]
                 {
                     (request.PackageRoot, "PackageRoot"),
                     (request.TaskLocalCacheDirectory, "TaskLocalCacheDirectory"),
                     (request.GlobalCacheDirectory, "GlobalCacheDirectory")
                 })
        {
            var rootPath = ToolchainPathPolicy.ResolveExistingDirectory(path, $"Build {name}");
            var latestWitnessTime = Directory.GetCreationTimeUtc(rootPath) + tolerance;
            if (generatedAt.UtcDateTime > latestWitnessTime || sidecarLastWriteUtc > latestWitnessTime)
                throw new InvalidDataException($"Runtime preflight witness is newer than a build graph root: {rootPath}");
        }
        return Sha256(bytes);
    }

    private static void ValidateClaimedRoot(JsonElement root, string propertyName, string actualPath)
    {
        var claimed = RequireString(root, propertyName);
        var claimedCanonical = ToolchainPathPolicy.CanonicalPreflightPath(claimed, $"Preflight {propertyName}");
        var actualCanonical = ToolchainPathPolicy.CanonicalPreflightPath(actualPath, $"Build {propertyName}");
        if (!claimed.Equals(claimedCanonical, StringComparison.OrdinalIgnoreCase) || claimedCanonical != actualCanonical)
            throw new InvalidDataException($"Runtime preflight {propertyName} does not match the Zig build graph.");
    }

    private static byte[] SerializeProfile(
        string optimize,
        string runtimeSha256,
        string textureSourceSha256,
        string textureArtifactSha256,
        string secondaryTextureSourceSha256,
        string secondaryTextureArtifactSha256,
        string vertexShaderSha256,
        string fragmentShaderSha256,
        string? preflightSha256)
    {
        using var memory = new MemoryStream();
        using (var writer = new Utf8JsonWriter(memory))
        {
            writer.WriteStartObject();
            writer.WriteNumber("Version", 2);
            writer.WriteString("Optimize", optimize);
            writer.WriteString("TextureProfile", "release");
            writer.WriteString("RuntimeExeSha256", runtimeSha256);
            writer.WriteString("TextureSourceSha256", textureSourceSha256);
            writer.WriteString("TextureArtifactSha256", textureArtifactSha256);
            writer.WriteString("SecondaryTextureSourceSha256", secondaryTextureSourceSha256);
            writer.WriteString("SecondaryTextureArtifactSha256", secondaryTextureArtifactSha256);
            writer.WriteString("VertexShaderSourceSha256", vertexShaderSha256);
            writer.WriteString("FragmentShaderSourceSha256", fragmentShaderSha256);
            if (preflightSha256 is null) writer.WriteNull("BuildPreflightSidecarSha256");
            else writer.WriteString("BuildPreflightSidecarSha256", preflightSha256);
            writer.WriteEndObject();
        }
        memory.WriteByte((byte)'\n');
        return memory.ToArray();
    }

    private static string HashFile(string path)
    {
        using var stream = WindowsFileIdentityAdapter.OpenFrozenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
    }

    private static void AssertExactObject(JsonElement root, IReadOnlyCollection<string> expectedFields, string name)
    {
        if (root.ValueKind != JsonValueKind.Object) throw new InvalidDataException($"{name} root must be an object.");
        var actual = root.EnumerateObject().Select(property => property.Name).ToArray();
        if (actual.Length != expectedFields.Count || actual.Distinct(StringComparer.Ordinal).Count() != expectedFields.Count ||
            !new HashSet<string>(actual, StringComparer.Ordinal).SetEquals(expectedFields))
            throw new InvalidDataException($"{name} properties must be unique and exactly match its schema names.");
    }

    private static string RequireString(JsonElement root, string propertyName)
    {
        var value = root.GetProperty(propertyName);
        if (value.ValueKind != JsonValueKind.String || value.GetString() is not { } text)
            throw new InvalidDataException($"{propertyName} must be a JSON string.");
        return text;
    }

    private static bool IsLowerSha256(string value) =>
        value.Length == 64 && value.All(character => character is >= '0' and <= '9' or >= 'a' and <= 'f');

    private static string Sha256(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
}

internal static class ToolchainDurableFile
{
    internal static void WriteAtomicNoReplace(string destinationPath, byte[] bytes, string temporaryPrefix)
    {
        var destination = ToolchainPathPolicy.CanonicalAbsoluteLocalPath(destinationPath, "Toolchain output", requireCanonicalSpelling: false);
        if (File.Exists(destination) || Directory.Exists(destination))
            throw new IOException($"Refusing to overwrite toolchain output: {destination}");
        var parent = Path.GetDirectoryName(destination) ?? throw new IOException("Toolchain output has no parent directory.");
        ToolchainPathPolicy.RejectReparsePointInExistingPath(parent, "Toolchain output parent before create");
        Directory.CreateDirectory(parent);
        parent = ToolchainPathPolicy.ResolveExistingDirectory(parent, "Toolchain output parent after create");
        var temporary = Path.Combine(parent, $"{temporaryPrefix}-{Guid.NewGuid():N}.tmp");
        WindowsOwnedFile? owner = null;
        var committed = false;
        Exception? primaryFailure = null;
        try
        {
            owner = WindowsFileIdentityAdapter.CreateOwnedFile(temporary);
            Exception? writeFailure = null;
            try
            {
                owner.Stream.Write(bytes);
                owner.Stream.Flush(flushToDisk: true);
            }
            catch (Exception exception) { writeFailure = exception; }
            try { owner.CloseStream(); }
            catch (Exception closeFailure)
            {
                writeFailure = writeFailure is null
                    ? closeFailure
                    : new AggregateException("Toolchain output write and close both failed.", writeFailure, closeFailure);
            }
            if (writeFailure is not null) ExceptionDispatchInfo.Capture(writeFailure).Throw();
            if (File.Exists(destination) || Directory.Exists(destination))
                throw new IOException($"Toolchain output appeared before no-replace publication: {destination}");
            File.Move(temporary, destination, overwrite: false);
            committed = true;
        }
        catch (Exception exception) { primaryFailure = exception; }

        Exception? cleanupFailure = null;
        if (!committed && owner is not null)
        {
            try { WindowsFileIdentityAdapter.DeleteOwnedFileIfPresent(temporary, owner.Identity); }
            catch (Exception exception) { cleanupFailure = exception; }
        }
        if (primaryFailure is not null && cleanupFailure is not null)
            throw new AggregateException("Toolchain output publication and owned cleanup both failed.", primaryFailure, cleanupFailure);
        if (primaryFailure is not null) ExceptionDispatchInfo.Capture(primaryFailure).Throw();
        if (cleanupFailure is not null) ExceptionDispatchInfo.Capture(cleanupFailure).Throw();
    }

    internal static void WriteNew(string path, ReadOnlySpan<byte> bytes)
    {
        using var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1024 * 1024, FileOptions.WriteThrough);
        stream.Write(bytes);
        stream.Flush(flushToDisk: true);
    }
}
