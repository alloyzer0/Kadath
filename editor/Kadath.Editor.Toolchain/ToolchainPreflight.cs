using System.Text.Json;

namespace Kadath.Editor.Toolchain;

internal sealed record ToolchainPreflightRequest(
    string PackageRoot,
    string TaskLocalCacheDirectory,
    string GlobalCacheDirectory,
    string DestinationPath);

internal sealed record ToolchainPreflightResult(
    string DestinationPath,
    DateTimeOffset GeneratedAtUtc);

internal static class ToolchainPreflight
{
    internal static ToolchainPreflightResult Execute(ToolchainPreflightRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        var packageRoot = ToolchainPathPolicy.CanonicalPreflightPath(request.PackageRoot, "Package root");
        var localCache = ToolchainPathPolicy.CanonicalPreflightPath(request.TaskLocalCacheDirectory, "Task-local cache directory");
        var globalCache = ToolchainPathPolicy.CanonicalPreflightPath(request.GlobalCacheDirectory, "Global cache directory");
        AssertDisjointRoots(packageRoot, localCache, globalCache);
        AssertAbsent(packageRoot, "Package root");
        AssertAbsent(localCache, "Task-local cache directory");
        AssertAbsent(globalCache, "Global cache directory");

        var destination = ToolchainPathPolicy.CanonicalAbsoluteLocalPath(
            request.DestinationPath,
            "Runtime preflight sidecar destination",
            requireCanonicalSpelling: false);
        var destinationParent = Path.GetDirectoryName(destination)
            ?? throw new IOException("Runtime preflight sidecar destination has no parent directory.");
        Directory.CreateDirectory(destinationParent);
        ToolchainPathPolicy.ResolveExistingDirectory(destinationParent, "Runtime preflight sidecar parent");
        foreach (var root in new[] { packageRoot, localCache, globalCache })
            if (ToolchainPathPolicy.Contains(root, destination) || ToolchainPathPolicy.Contains(destination, root))
                throw new IOException("Runtime preflight sidecar and all witnessed roots must be disjoint.");

        var generatedAtUtc = DateTimeOffset.UtcNow;
        var bytes = Serialize(generatedAtUtc, packageRoot, localCache, globalCache);
        ToolchainDurableFile.WriteAtomicNoReplace(destination, bytes, ".kadath-runtime-preflight");
        // 时间戳属于 sidecar 公共契约；显式写回可避免不同 NTFS 精度影响后续两秒门禁。
        File.SetLastWriteTimeUtc(destination, generatedAtUtc.UtcDateTime);

        AssertAbsent(packageRoot, "Package root after sidecar publication");
        AssertAbsent(localCache, "Task-local cache directory after sidecar publication");
        AssertAbsent(globalCache, "Global cache directory after sidecar publication");
        return new ToolchainPreflightResult(destination, generatedAtUtc);
    }

    private static void AssertDisjointRoots(string packageRoot, string localCache, string globalCache)
    {
        ToolchainPathPolicy.EnsureDisjoint(packageRoot, "Package root", localCache, "Task-local cache directory");
        ToolchainPathPolicy.EnsureDisjoint(packageRoot, "Package root", globalCache, "Global cache directory");
        ToolchainPathPolicy.EnsureDisjoint(localCache, "Task-local cache directory", globalCache, "Global cache directory");
    }

    private static void AssertAbsent(string path, string name)
    {
        ToolchainPathPolicy.RejectReparsePointInExistingPath(path, name);
        if (File.Exists(path) || Directory.Exists(path))
            throw new IOException($"{name} must be absent before the cold build: {path}");
    }

    private static byte[] Serialize(
        DateTimeOffset generatedAtUtc,
        string packageRoot,
        string localCache,
        string globalCache)
    {
        using var memory = new MemoryStream();
        using (var writer = new Utf8JsonWriter(memory))
        {
            writer.WriteStartObject();
            writer.WriteNumber("Version", 1);
            writer.WriteString("GeneratedAtUtc", generatedAtUtc.ToString("O"));
            writer.WriteString("PackageRoot", packageRoot);
            writer.WriteString("TaskLocalCacheDirectory", localCache);
            writer.WriteString("GlobalCacheDirectory", globalCache);
            writer.WriteBoolean("PackageRootAbsentBefore", true);
            writer.WriteBoolean("TaskLocalCacheAbsentBefore", true);
            writer.WriteBoolean("GlobalCacheAbsentBefore", true);
            writer.WriteEndObject();
        }
        memory.WriteByte((byte)'\n');
        return memory.ToArray();
    }
}
