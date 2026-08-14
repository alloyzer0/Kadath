using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Kadath.Editor.Workspace;

public static class WorkspaceScriptDependencySet
{
    public static string ComputeRevision(string scriptPath) => WorkspaceScriptSourceModel.ComputeRevision(scriptPath);

    public static WorkspaceScriptDependencyRevisionTracker CreateRevisionTracker(string scriptPath) => new(scriptPath);
}

public sealed class WorkspaceScriptDependencyRevisionTracker
{
    private readonly string _scriptPath;
    private IReadOnlyList<string> _lastValidatedDependencies = Array.Empty<string>();

    internal WorkspaceScriptDependencyRevisionTracker(string scriptPath) => _scriptPath = Path.GetFullPath(scriptPath);

    public string ComputeRevision()
    {
        lock (this)
        {
            try
            {
                var dependencies = WorkspaceScriptSourceModel.ResolveDependencyPaths(_scriptPath);
                _lastValidatedDependencies = dependencies;
                return WorkspaceScriptSourceModel.Observe(_scriptPath).Revision;
            }
            catch (Exception exception)
            {
                return WorkspaceScriptSourceModel.ComputeInvalidRevision(_scriptPath, _lastValidatedDependencies, exception);
            }
        }
    }
}

internal sealed record WorkspaceScriptDependency(
    uint ScriptId,
    string SourceName,
    string FullPath,
    byte[] Source,
    string Sha256);

internal sealed record WorkspaceScriptTemplateDependency(
    string SourceName,
    byte[] Source);

internal sealed record WorkspaceScriptSourceSnapshot(
    int SchemaVersion,
    byte[] ManifestSource,
    string Revision,
    IReadOnlyList<WorkspaceScriptDependency> Dependencies)
{
    internal bool IsBehaviorPackage => SchemaVersion == 2;

    internal void VerifyUnchanged(string scriptPath, CancellationToken cancellationToken)
    {
        var current = WorkspaceScriptSourceModel.Read(scriptPath, cancellationToken);
        if (!Revision.Equals(current.Revision, StringComparison.Ordinal))
            throw new WorkspacePublicationException(WorkspacePublicationFailureKind.SourceChanged, "Script dependency set changed during bake.");
    }
}

internal static class WorkspaceScriptSourceModel
{
    internal const int MaxScriptCount = 16;
    private const int MaxSourceNameBytes = 1024;
    private const int MaxSourceBytes = 64 * 1024;
    private const int MaxAggregateSourceBytes = 512 * 1024;
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    private static readonly StringComparison PathComparison = OperatingSystem.IsWindows()
        ? StringComparison.OrdinalIgnoreCase
        : StringComparison.Ordinal;

    internal static WorkspaceScriptSourceSnapshot Read(string scriptPath, CancellationToken cancellationToken) =>
        ReadCore(scriptPath, cancellationToken, requireSources: true);

    internal static WorkspaceScriptSourceSnapshot Observe(string scriptPath) =>
        ReadCore(scriptPath, default, requireSources: false);

    internal static string ComputeRevision(string scriptPath)
    {
        try { return Observe(scriptPath).Revision; }
        catch (Exception exception) { return ComputeInvalidRevision(scriptPath, Array.Empty<string>(), exception); }
    }

    internal static IReadOnlyList<string> ResolveDependencyPaths(string scriptPath)
    {
        var manifestSource = WorkspaceProjectValidator.ReadDocument(scriptPath, "Script", default);
        var schemaVersion = ReadSchemaVersion(manifestSource);
        if (schemaVersion == 1)
        {
            WorkspaceProjectValidator.ValidateLegacyScriptSource(manifestSource);
            return Array.Empty<string>();
        }
        var projectDirectory = Path.GetDirectoryName(Path.GetFullPath(scriptPath))
            ?? throw Failure("Script source has no project directory.");
        WorkspaceProjectValidator.RejectReparsePoint(projectDirectory, "Project directory");
        return ParseBehaviorManifest(manifestSource)
            .Select(entry => ResolveSourcePath(projectDirectory, entry.SourceName, entry.SourceName))
            .ToArray();
    }

    internal static string ComputeInvalidRevision(
        string scriptPath,
        IReadOnlyList<string> dependencyPaths,
        Exception exception)
    {
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        Append(hash, "KADATH-SCRIPT-WATCH-INVALID-V1\0");
        AppendUtf8(hash, exception.GetType().Name);
        AppendUtf8(hash, Path.GetFullPath(scriptPath));
        AppendUtf8(hash, TryFileRevision(scriptPath));
        foreach (var dependencyPath in dependencyPaths)
        {
            AppendUtf8(hash, dependencyPath);
            AppendUtf8(hash, TryFileRevision(dependencyPath));
        }
        return $"invalid:{Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant()}";
    }

    internal static void ValidateManifest(byte[] source)
    {
        var schemaVersion = ReadSchemaVersion(source);
        if (schemaVersion == 1)
        {
            WorkspaceProjectValidator.ValidateLegacyScriptSource(source);
            return;
        }
        _ = ParseBehaviorManifest(source);
    }

    internal static byte[] EncodeEditedSource(string sourceName, string source)
    {
        if (!IsSourceName(sourceName)) throw Failure("Script source path must be a safe scripts/*.luau path.");
        ArgumentNullException.ThrowIfNull(source);
        byte[] bytes;
        try { bytes = StrictUtf8.GetBytes(source); }
        catch (EncoderFallbackException exception) { throw Failure($"Script source must contain valid UTF-8: {sourceName}.", exception); }
        if (bytes.Length > MaxSourceBytes) throw Failure($"Script source exceeds 64 KiB: {sourceName}.");
        return bytes;
    }

    internal static string ResolveLifecycleSourcePath(string scriptPath, string sourceName)
    {
        if (!IsSourceName(sourceName)) throw Failure("Script source path must be a safe scripts/*.luau path.");
        var projectDirectory = Path.GetDirectoryName(Path.GetFullPath(scriptPath))
            ?? throw Failure("Script source has no project directory.");
        WorkspaceProjectValidator.RejectReparsePoint(projectDirectory, "Project directory");
        return ResolveSourcePath(projectDirectory, sourceName, sourceName);
    }

    internal static byte[] EncodeBehaviorManifest(IEnumerable<(uint ScriptId, string SourceName)> entries)
    {
        var values = entries.ToArray();
        if (values.Length is < 1 or > MaxScriptCount) throw Failure("Script.scripts must contain 1 to 16 entries.");
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream, new JsonWriterOptions { Indented = true }))
        {
            writer.WriteStartObject();
            writer.WriteNumber("schemaVersion", 2);
            writer.WriteStartArray("scripts");
            foreach (var entry in values)
            {
                writer.WriteStartObject();
                writer.WriteNumber("scriptId", entry.ScriptId);
                writer.WriteString("source", entry.SourceName);
                writer.WriteEndObject();
            }
            writer.WriteEndArray();
            writer.WriteEndObject();
        }
        var encoded = stream.ToArray();
        _ = ParseBehaviorManifest(encoded);
        return encoded;
    }

    internal static IReadOnlyList<WorkspaceScriptTemplateDependency> ReadTemplateDependencies(
        string manifestPath,
        CancellationToken cancellationToken)
    {
        var manifestSource = WorkspaceProjectValidator.ReadDocument(manifestPath, "Script template", cancellationToken);
        var schemaVersion = ReadSchemaVersion(manifestSource);
        if (schemaVersion == 1)
        {
            WorkspaceProjectValidator.ValidateLegacyScriptSource(manifestSource);
            return Array.Empty<WorkspaceScriptTemplateDependency>();
        }
        var templateDirectory = Path.GetDirectoryName(Path.GetFullPath(manifestPath))
            ?? throw Failure("Script template has no directory.");
        WorkspaceProjectValidator.RejectReparsePoint(templateDirectory, "Script template directory");
        var dependencies = new List<WorkspaceScriptTemplateDependency>();
        var aggregateBytes = 0;
        foreach (var entry in ParseBehaviorManifest(manifestSource))
        {
            cancellationToken.ThrowIfCancellationRequested();
            var relativeTemplatePath = entry.SourceName["scripts/".Length..];
            var templatePath = ResolveSourcePath(templateDirectory, relativeTemplatePath, entry.SourceName);
            var source = ReadSource(templatePath, entry.SourceName, requireSource: true);
            aggregateBytes = checked(aggregateBytes + source.Length);
            if (aggregateBytes > MaxAggregateSourceBytes) throw Failure("Script template dependency set exceeds 512 KiB.");
            dependencies.Add(new WorkspaceScriptTemplateDependency(entry.SourceName, source));
        }
        return dependencies;
    }

    private static WorkspaceScriptSourceSnapshot ReadCore(string scriptPath, CancellationToken cancellationToken, bool requireSources)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var manifestSource = WorkspaceProjectValidator.ReadDocument(scriptPath, "Script", cancellationToken);
        var schemaVersion = ReadSchemaVersion(manifestSource);
        if (schemaVersion == 1)
        {
            WorkspaceProjectValidator.ValidateLegacyScriptSource(manifestSource);
            return new WorkspaceScriptSourceSnapshot(1, manifestSource, Hash(manifestSource), Array.Empty<WorkspaceScriptDependency>());
        }

        var entries = ParseBehaviorManifest(manifestSource);
        var projectDirectory = Path.GetDirectoryName(Path.GetFullPath(scriptPath))
            ?? throw Failure("Script source has no project directory.");
        WorkspaceProjectValidator.RejectReparsePoint(projectDirectory, "Project directory");
        var dependencies = new List<WorkspaceScriptDependency>(entries.Count);
        var aggregateBytes = 0;
        foreach (var entry in entries)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var fullPath = ResolveSourcePath(projectDirectory, entry.SourceName, entry.SourceName);
            var source = ReadSource(fullPath, entry.SourceName, requireSources);
            aggregateBytes = checked(aggregateBytes + source.Length);
            if (aggregateBytes > MaxAggregateSourceBytes) throw Failure("Script source dependency set exceeds 512 KiB.");
            dependencies.Add(new WorkspaceScriptDependency(entry.ScriptId, entry.SourceName, fullPath, source, Hash(source)));
        }
        cancellationToken.ThrowIfCancellationRequested();
        return new WorkspaceScriptSourceSnapshot(2, manifestSource, SourceRevision(entries, dependencies), dependencies);
    }

    private static int ReadSchemaVersion(byte[] source)
    {
        if (source.Length > WorkspaceProjectValidator.MaxDocumentBytes) throw Failure("Script exceeds the 64 KiB document budget.");
        try
        {
            var offset = source.AsSpan().StartsWith(Encoding.UTF8.Preamble) ? Encoding.UTF8.Preamble.Length : 0;
            using var document = JsonDocument.Parse(source.AsMemory(offset), new JsonDocumentOptions { CommentHandling = JsonCommentHandling.Disallow, AllowTrailingCommas = false });
            if (document.RootElement.ValueKind != JsonValueKind.Object
                || !document.RootElement.TryGetProperty("schemaVersion", out var schema)
                || schema.ValueKind != JsonValueKind.Number
                || !schema.TryGetInt32(out var value)
                || value is not (1 or 2))
            {
                throw Failure("Unsupported Script schemaVersion.");
            }
            return value;
        }
        catch (JsonException exception) { throw Failure($"Failed to parse Script: {exception.Message}", exception); }
    }

    private static IReadOnlyList<ManifestEntry> ParseBehaviorManifest(byte[] source)
    {
        try
        {
            var offset = source.AsSpan().StartsWith(Encoding.UTF8.Preamble) ? Encoding.UTF8.Preamble.Length : 0;
            using var document = JsonDocument.Parse(source.AsMemory(offset), new JsonDocumentOptions { CommentHandling = JsonCommentHandling.Disallow, AllowTrailingCommas = false });
            var root = document.RootElement;
            RequireObject(root, "Script");
            RequireProperties(root, ["schemaVersion", "scripts"], "Script");
            if (!root.GetProperty("schemaVersion").TryGetInt32(out var schemaVersion) || schemaVersion != 2)
                throw Failure("Unsupported Script schemaVersion.");
            var scripts = root.GetProperty("scripts");
            if (scripts.ValueKind != JsonValueKind.Array || scripts.GetArrayLength() is < 1 or > MaxScriptCount)
                throw Failure("Script.scripts must contain 1 to 16 entries.");
            var entries = new List<ManifestEntry>(scripts.GetArrayLength());
            var scriptIds = new HashSet<uint>();
            var sourceNames = new HashSet<string>(StringComparer.Ordinal);
            var index = 0;
            foreach (var value in scripts.EnumerateArray())
            {
                var owner = $"Script.scripts[{index}]";
                RequireObject(value, owner);
                RequireProperties(value, ["scriptId", "source"], owner);
                if (!value.GetProperty("scriptId").TryGetUInt32(out var scriptId) || scriptId == 0 || !scriptIds.Add(scriptId))
                    throw Failure($"{owner}.scriptId must be a unique non-zero u32.");
                var sourceValue = value.GetProperty("source");
                if (sourceValue.ValueKind != JsonValueKind.String)
                    throw Failure($"{owner}.source must be a string.");
                var sourceName = sourceValue.GetString();
                if (!IsSourceName(sourceName) || !sourceNames.Add(sourceName!))
                    throw Failure($"{owner}.source must be a unique safe scripts/*.luau path.");
                entries.Add(new ManifestEntry(scriptId, sourceName!));
                index++;
            }
            return entries;
        }
        catch (JsonException exception) { throw Failure($"Failed to parse Script manifest: {exception.Message}", exception); }
    }

    private static string ResolveSourcePath(string rootDirectory, string relativeName, string sourceName)
    {
        var relative = relativeName.Replace('/', Path.DirectorySeparatorChar);
        var fullRoot = Path.GetFullPath(rootDirectory).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var fullPath = Path.GetFullPath(Path.Combine(fullRoot, relative));
        var prefix = fullRoot + Path.DirectorySeparatorChar;
        if (!fullPath.StartsWith(prefix, PathComparison)) throw Failure($"Script source escapes project root: {sourceName}.");
        var current = fullRoot;
        foreach (var segment in relative.Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, segment);
            if (Directory.Exists(current) || File.Exists(current)) WorkspaceProjectValidator.RejectReparsePoint(current, $"Script source {sourceName}");
            else break;
        }
        return fullPath;
    }

    private static byte[] ReadSource(string fullPath, string sourceName, bool requireSource)
    {
        if (!File.Exists(fullPath))
        {
            if (requireSource) throw Failure($"Script source does not exist: {sourceName}.");
            return Encoding.UTF8.GetBytes("KADATH-MISSING-SCRIPT-SOURCE");
        }
        WorkspaceProjectValidator.RejectReparsePoint(fullPath, $"Script source {sourceName}");
        var information = new FileInfo(fullPath);
        if (information.Length > MaxSourceBytes) throw Failure($"Script source exceeds 64 KiB: {sourceName}.");
        var source = File.ReadAllBytes(fullPath);
        try { _ = StrictUtf8.GetString(source); }
        catch (DecoderFallbackException exception) { throw Failure($"Script source must contain valid UTF-8: {sourceName}.", exception); }
        return source;
    }

    private static bool IsSourceName(string? value)
    {
        if (string.IsNullOrEmpty(value) || Encoding.UTF8.GetByteCount(value) > MaxSourceNameBytes
            || !value.StartsWith("scripts/", StringComparison.Ordinal) || !value.EndsWith(".luau", StringComparison.Ordinal)
            || value.Contains('\\') || value.Contains('\0')) return false;
        return value.Split('/').All(segment => segment.Length > 0 && segment is not "." and not "..");
    }

    private static string SourceRevision(IReadOnlyList<ManifestEntry> entries, IReadOnlyList<WorkspaceScriptDependency> dependencies)
    {
        using var manifest = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        Append(manifest, "KADATH-SCRIPT-MANIFEST-V2\0");
        AppendUInt32(manifest, 2);
        AppendUInt32(manifest, checked((uint)entries.Count));
        foreach (var entry in entries)
        {
            AppendUInt32(manifest, entry.ScriptId);
            AppendUtf8(manifest, entry.SourceName);
        }
        var manifestRevision = manifest.GetHashAndReset();

        using var sourceSet = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        Append(sourceSet, "KADATH-SCRIPT-SOURCE-SET-V2\0");
        sourceSet.AppendData(manifestRevision);
        foreach (var dependency in dependencies)
        {
            AppendUInt32(sourceSet, dependency.ScriptId);
            AppendUtf8(sourceSet, dependency.SourceName);
            AppendUInt64(sourceSet, checked((ulong)dependency.Source.LongLength));
            sourceSet.AppendData(dependency.Source);
        }
        return Convert.ToHexString(sourceSet.GetHashAndReset()).ToLowerInvariant();
    }

    private static void AppendUtf8(IncrementalHash hash, string value)
    {
        var bytes = Encoding.UTF8.GetBytes(value);
        AppendUInt32(hash, checked((uint)bytes.Length));
        hash.AppendData(bytes);
    }

    private static void Append(IncrementalHash hash, string value) => hash.AppendData(Encoding.ASCII.GetBytes(value));

    private static void AppendUInt32(IncrementalHash hash, uint value)
    {
        Span<byte> bytes = stackalloc byte[sizeof(uint)];
        BinaryPrimitives.WriteUInt32LittleEndian(bytes, value);
        hash.AppendData(bytes);
    }

    private static void AppendUInt64(IncrementalHash hash, ulong value)
    {
        Span<byte> bytes = stackalloc byte[sizeof(ulong)];
        BinaryPrimitives.WriteUInt64LittleEndian(bytes, value);
        hash.AppendData(bytes);
    }

    private static void RequireObject(JsonElement value, string owner)
    {
        if (value.ValueKind != JsonValueKind.Object) throw Failure($"{owner} must be an object.");
    }

    private static void RequireProperties(JsonElement value, string[] expected, string owner)
    {
        var expectedSet = expected.ToHashSet(StringComparer.Ordinal);
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var property in value.EnumerateObject())
        {
            if (!expectedSet.Contains(property.Name)) throw Failure($"{owner} contains an unsupported property: {property.Name}.");
            if (!seen.Add(property.Name)) throw Failure($"{owner} contains a duplicate property: {property.Name}.");
        }
        foreach (var name in expected)
        {
            if (!seen.Contains(name)) throw Failure($"{owner} is missing required property: {name}.");
        }
    }

    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
    private static string TryFileRevision(string path)
    {
        if (!File.Exists(path)) return "missing";
        try { return Hash(File.ReadAllBytes(path)); }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return $"unreadable:{exception.GetType().Name}";
        }
    }

    private static WorkspaceProjectValidationException Failure(string message, Exception? innerException = null) =>
        new(WorkspaceProjectValidationFailureKind.Validation, message, innerException);
    private sealed record ManifestEntry(uint ScriptId, string SourceName);
}
