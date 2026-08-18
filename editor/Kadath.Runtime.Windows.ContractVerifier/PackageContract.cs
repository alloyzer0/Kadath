using System.Buffers.Binary;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;

namespace Kadath.Runtime.Windows.ContractVerifier;

internal sealed class PackageContract
{
    private static readonly string[] RequiredFiles =
    [
        "bin/kadath.exe",
        "bin/kadath-runtime-build-profile.json",
        "bin/assets/scenes/preview.scene",
        "bin/assets/scenes/preview.scene.json",
        "bin/assets/scripts/preview.script",
        "bin/assets/scripts/preview.script.json",
        "bin/assets/scripts/patrol.luau",
        "bin/assets/scripts/player_controller.luau",
        "bin/assets/renderer2d/test.png",
        "bin/assets/renderer2d/test.texture",
        "bin/assets/renderer2d/goal.png",
        "bin/assets/renderer2d/goal.texture",
        "bin/assets/audio/won.wav",
        "bin/assets/audio/lost.wav",
        "bin/assets/audio/won.audio.wav",
        "bin/assets/audio/lost.audio.wav",
        "behavior-tools/kadath-behavior-tool.exe",
        "README.txt"
    ];

    private readonly Dictionary<string, string> _paths;

    private PackageContract(
        string root,
        Dictionary<string, string> paths,
        Dictionary<string, FileIdentity> identityBefore,
        BuildProfileEvidence buildProfile)
    {
        Root = root;
        _paths = paths;
        IdentityBefore = identityBefore;
        Optimize = buildProfile.Optimize;
        BuildPreflightSidecarSha256 = buildProfile.BuildPreflightSidecarSha256;
    }

    public string Root { get; }
    public string Optimize { get; }
    public string? BuildPreflightSidecarSha256 { get; }
    public string RuntimePath => _paths["bin/kadath.exe"];
    public string WorkingDirectory => Path.GetDirectoryName(RuntimePath)!;
    public string SceneArtifactPath => _paths["bin/assets/scenes/preview.scene"];
    public string ScriptArtifactPath => _paths["bin/assets/scripts/preview.script"];
    public IReadOnlyDictionary<string, FileIdentity> IdentityBefore { get; }

    public static PackageContract Load(string requestedRoot)
    {
        try
        {
            var root = PathSafety.RequireExistingDirectory(requestedRoot, "PackageRoot");
            ValidateExactTree(root);
            var paths = RequiredFiles.ToDictionary(
                relative => relative,
                relative => PathSafety.ResolveRequiredFile(root, relative, $"Package file '{relative}'"),
                StringComparer.Ordinal);

            ValidateSceneContract(paths["bin/assets/scenes/preview.scene.json"]);
            ValidateScriptContract(
                paths["bin/assets/scripts/preview.script.json"],
                paths["bin/assets/scripts/player_controller.luau"]);
            ValidateArtifactHeader(paths["bin/assets/scenes/preview.scene"], "KSCN", 5, 5, "Scene artifact");
            ValidateBehaviorArtifactHeader(paths["bin/assets/scripts/preview.script"]);
            ValidateFrozenTextures(paths);
            ValidateCanonicalAudio(paths, "won", "Won audio");
            ValidateCanonicalAudio(paths, "lost", "Lost audio");

            var identities = CaptureIdentities(paths);
            var buildProfile = ValidateBuildProfile(paths, identities);
            return new PackageContract(root, paths, identities, buildProfile);
        }
        catch (VerifierFailure) { throw; }
        catch (Exception exception)
        {
            throw Product($"Package contract validation failed: {exception.Message}", exception);
        }
    }

    public string RuntimeRelativeArgument(string artifactPath) =>
        Path.GetRelativePath(WorkingDirectory, artifactPath).Replace('\\', '/');

    public Dictionary<string, FileIdentity> CaptureCurrentIdentities()
    {
        try
        {
            // 关键终态边界：先重验 exact-18/no-reparse，再捕获已知文件身份；否则运行中新增文件会被静默忽略。
            ValidateExactTree(Root);
            return CaptureIdentities(_paths);
        }
        catch (Exception exception)
        {
            // 初始加载仍报告 package_preflight；这里只把运行后的树/身份变化归入 identity_after。
            throw new VerifierFailure(
                FailureClassification.PackageIdentity,
                "identity_after",
                $"Cannot capture the final exact package identity: {exception.Message}",
                exception);
        }
    }

    public static void AssertIdentityUnchanged(
        IReadOnlyDictionary<string, FileIdentity> before,
        IReadOnlyDictionary<string, FileIdentity> after)
    {
        if (before.Count != after.Count)
            throw new VerifierFailure(FailureClassification.PackageIdentity, "identity_after", "Package identity set changed during verification.");
        foreach (var (name, expected) in before)
        {
            if (!after.TryGetValue(name, out var actual) || actual != expected)
            {
                throw new VerifierFailure(
                    FailureClassification.PackageIdentity,
                    "identity_after",
                    $"Package file identity changed during verification: {name}");
            }
        }
    }

    private static void ValidateExactTree(string root)
    {
        var actual = new List<string>();
        var pending = new Stack<DirectoryInfo>();
        pending.Push(new DirectoryInfo(root));
        while (pending.TryPop(out var directory))
        {
            foreach (var entry in directory.EnumerateFileSystemInfos())
            {
                entry.Refresh();
                if ((entry.Attributes & FileAttributes.ReparsePoint) != 0 || entry.LinkTarget is not null)
                    throw Product($"Package tree cannot contain a reparse point: {entry.FullName}");
                if (entry is DirectoryInfo child)
                {
                    pending.Push(child);
                    continue;
                }
                actual.Add(Path.GetRelativePath(root, entry.FullName).Replace('\\', '/'));
            }
        }

        var expected = RequiredFiles.Order(StringComparer.Ordinal).ToArray();
        actual.Sort(StringComparer.Ordinal);
        if (!actual.SequenceEqual(expected, StringComparer.Ordinal))
            throw Product($"Windows Runtime package must contain the exact {RequiredFiles.Length}-file policy set.");
    }

    private static void ValidateSceneContract(string path)
    {
        using var document = ParseStrictJson(path, "Scene source");
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object
            || !root.TryGetProperty("schemaVersion", out var schema)
            || schema.GetInt32() != 5
            || !root.TryGetProperty("objects", out var objects)
            || objects.ValueKind != JsonValueKind.Array)
        {
            throw Product("Scene source must be schema v5 with an objects array.");
        }

        JsonElement? player = null;
        var goalCount = 0;
        foreach (var value in objects.EnumerateArray())
        {
            if (!value.TryGetProperty("kind", out var kind) || kind.ValueKind != JsonValueKind.String) continue;
            if (kind.GetString() == "player") player = value;
            if (kind.GetString() == "goal") goalCount++;
        }
        if (player is null || goalCount != 1
            || !player.Value.TryGetProperty("behaviors", out var behaviors)
            || behaviors.ValueKind != JsonValueKind.Array
            || !behaviors.EnumerateArray().Any(value =>
                value.TryGetProperty("scriptId", out var scriptId) && scriptId.TryGetUInt32(out var id) && id == 2))
        {
            throw Product("Scene v5 must bind Player movement to behavior scriptId 2 and contain one Goal.");
        }
    }

    private static void ValidateScriptContract(string manifestPath, string playerSourcePath)
    {
        using var document = ParseStrictJson(manifestPath, "Script source");
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object
            || !root.TryGetProperty("schemaVersion", out var schema)
            || schema.GetInt32() != 2
            || !root.TryGetProperty("scripts", out var scripts)
            || scripts.ValueKind != JsonValueKind.Array)
        {
            throw Product("Script source must be schema v2 with a scripts array.");
        }

        var entries = scripts.EnumerateArray()
            .Select(value => (
                Id: value.GetProperty("scriptId").GetUInt32(),
                Source: value.GetProperty("source").GetString()))
            .ToArray();
        if (entries.Length != 2
            || !entries.Contains((1u, "scripts/patrol.luau"))
            || !entries.Contains((2u, "scripts/player_controller.luau")))
        {
            throw Product("Script v2 must contain the frozen Patrol and Player controller dependencies.");
        }

        var playerSource = File.ReadAllText(playerSourcePath, new UTF8Encoding(false, true));
        if (!playerSource.Contains("kadath.input.move_axis()", StringComparison.Ordinal)
            || !playerSource.Contains("self:translate", StringComparison.Ordinal))
        {
            throw Product("Player controller does not expose the input-owned movement contract.");
        }
    }

    private static void ValidateArtifactHeader(string path, string magic, uint version, uint? schemaVersion, string name)
    {
        Span<byte> header = stackalloc byte[12];
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (stream.Read(header) != header.Length
            || !header[..4].SequenceEqual(Encoding.ASCII.GetBytes(magic))
            || BinaryPrimitives.ReadUInt32LittleEndian(header[4..8]) != version
            || schemaVersion is not null && BinaryPrimitives.ReadUInt32LittleEndian(header[8..12]) != schemaVersion.Value)
        {
            throw Product($"{name} does not have the required {magic} v{version} header.");
        }
    }

    private static void ValidateBehaviorArtifactHeader(string path)
    {
        Span<byte> header = stackalloc byte[16];
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (stream.Read(header) != header.Length
            || !header[..4].SequenceEqual("KSCP"u8)
            || BinaryPrimitives.ReadUInt32LittleEndian(header[4..8]) != 2
            || BinaryPrimitives.ReadUInt32LittleEndian(header[12..16]) != 2)
        {
            throw Product("Behavior Script artifact must use KSCP v2 with Host Interface v2.");
        }
    }

    private static void ValidateFrozenTextures(IReadOnlyDictionary<string, string> paths)
    {
        ValidateTexture(
            paths["bin/assets/renderer2d/test.texture"],
            [255, 0, 0, 0, 0, 255, 0, 64, 0, 0, 255, 128, 255, 255, 255, 255],
            [127, 127, 127, 111],
            "9476b7ee373c3a821c6a03ddfcbb2f5e2f343d9c62f53920b5dba29402d9f128",
            "Primary texture");
        ValidateTexture(
            paths["bin/assets/renderer2d/goal.texture"],
            [255, 0, 255, 255, 0, 255, 255, 255, 0, 0, 0, 255, 255, 255, 255, 255],
            [127, 127, 191, 255],
            "555c2e554e2e5eb70e9de20e3e3182482d826dcfff230be45c54d321cd7e8c2c",
            "Goal texture");

        if (Hash(paths["bin/assets/renderer2d/test.png"]) != "a6fab23c053638849d8b64ba72e260c22efb6e60a6876e36c662ae43a42e1eff")
            throw Product("Primary PNG identity is not the frozen 2x2 RGBA asset.");
        if (Hash(paths["bin/assets/renderer2d/goal.png"]) != "e690b160c98c941210db92c5ae7a1637bc835529e0056e743a5d8eb209c4708f")
            throw Product("Goal PNG identity is not the frozen 2x2 RGBA asset.");
    }

    private static void ValidateTexture(
        string path,
        byte[] baseLevel,
        byte[] mipLevel,
        string expectedHash,
        string name)
    {
        var bytes = File.ReadAllBytes(path);
        if (bytes.Length != 44
            || !bytes.AsSpan(0, 4).SequenceEqual("KDAT"u8)
            || BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(4, 4)) != 2
            || BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(8, 4)) != 2
            || BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(12, 4)) != 2
            || BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(16, 4)) != 2
            || BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(20, 4)) != 20
            || !bytes.AsSpan(24, 16).SequenceEqual(baseLevel)
            || !bytes.AsSpan(40, 4).SequenceEqual(mipLevel)
            || Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant() != expectedHash)
        {
            throw Product($"{name} is not the frozen KDAT v2 2x2 mip chain.");
        }
    }

    private static void ValidateWave(string path, string name)
    {
        Span<byte> header = stackalloc byte[12];
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (stream.Read(header) != header.Length
            || !header[..4].SequenceEqual("RIFF"u8)
            || !header[8..12].SequenceEqual("WAVE"u8))
        {
            throw Product($"{name} is not a RIFF/WAVE file.");
        }
    }

    private static void ValidateCanonicalAudio(
        IReadOnlyDictionary<string, string> paths,
        string stem,
        string name)
    {
        var source = paths[$"bin/assets/audio/{stem}.wav"];
        var artifact = paths[$"bin/assets/audio/{stem}.audio.wav"];
        ValidateWave(source, $"{name} source");
        ValidateWave(artifact, $"{name} artifact");
        if (!Hash(source).Equals(Hash(artifact), StringComparison.Ordinal))
            throw Product($"{name} canonical artifact does not match its frozen source bytes.");
    }

    private static BuildProfileEvidence ValidateBuildProfile(
        IReadOnlyDictionary<string, string> paths,
        IReadOnlyDictionary<string, FileIdentity> identities)
    {
        using var document = ParseStrictJson(paths["bin/kadath-runtime-build-profile.json"], "Runtime build profile");
        var root = document.RootElement;
        var expectedProperties = new HashSet<string>(StringComparer.Ordinal)
        {
            "Version", "Optimize", "TextureProfile", "RuntimeExeSha256", "TextureSourceSha256",
            "TextureArtifactSha256", "SecondaryTextureSourceSha256", "SecondaryTextureArtifactSha256",
            "VertexShaderSourceSha256", "FragmentShaderSourceSha256", "BuildPreflightSidecarSha256"
        };
        var actualProperties = root.EnumerateObject().Select(property => property.Name).ToArray();
        if (root.ValueKind != JsonValueKind.Object
            || actualProperties.Length != expectedProperties.Count
            || actualProperties.Distinct(StringComparer.Ordinal).Count() != actualProperties.Length
            || actualProperties.Any(property => !expectedProperties.Contains(property)))
        {
            throw Product("Runtime build profile must contain exactly the frozen eleven case-sensitive properties.");
        }

        var optimize = root.GetProperty("Optimize").GetString();
        if (root.GetProperty("Version").GetInt32() != 2
            || optimize is not ("Debug" or "ReleaseSafe")
            || root.GetProperty("TextureProfile").GetString() != "release"
            || root.GetProperty("RuntimeExeSha256").GetString() != identities["bin/kadath.exe"].Sha256
            || root.GetProperty("TextureSourceSha256").GetString() != identities["bin/assets/renderer2d/test.png"].Sha256
            || root.GetProperty("TextureArtifactSha256").GetString() != identities["bin/assets/renderer2d/test.texture"].Sha256
            || root.GetProperty("SecondaryTextureSourceSha256").GetString() != identities["bin/assets/renderer2d/goal.png"].Sha256
            || root.GetProperty("SecondaryTextureArtifactSha256").GetString() != identities["bin/assets/renderer2d/goal.texture"].Sha256
            || !IsLowerHex64(root.GetProperty("VertexShaderSourceSha256"))
            || !IsLowerHex64(root.GetProperty("FragmentShaderSourceSha256"))
            || !IsNullOrLowerHex64(root.GetProperty("BuildPreflightSidecarSha256")))
        {
            throw Product("Runtime build profile does not bind this executable and frozen texture artifacts.");
        }
        var preflight = root.GetProperty("BuildPreflightSidecarSha256");
        if (optimize == "ReleaseSafe" && preflight.ValueKind == JsonValueKind.Null)
            throw Product("ReleaseSafe Runtime verification requires a build preflight sidecar identity.");
        return new BuildProfileEvidence(
            optimize,
            preflight.ValueKind == JsonValueKind.Null
                ? null
                : preflight.GetString());
    }

    private static bool IsLowerHex64(JsonElement value) =>
        value.ValueKind == JsonValueKind.String
        && value.GetString() is { Length: 64 } text
        && text.All(character => character is >= '0' and <= '9' or >= 'a' and <= 'f');

    private static bool IsNullOrLowerHex64(JsonElement value) =>
        value.ValueKind == JsonValueKind.Null || IsLowerHex64(value);

    private sealed record BuildProfileEvidence(string Optimize, string? BuildPreflightSidecarSha256);

    private static JsonDocument ParseStrictJson(string path, string name)
    {
        try
        {
            var bytes = File.ReadAllBytes(path);
            if (bytes.Length is 0 or > 256 * 1024) throw new InvalidDataException("document size is outside 1..262144 bytes");
            _ = new UTF8Encoding(false, true).GetString(bytes);
            if (bytes.AsSpan().StartsWith(Encoding.UTF8.Preamble)) throw new InvalidDataException("UTF-8 BOM is not allowed");
            return JsonDocument.Parse(bytes, new JsonDocumentOptions
            {
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow
            });
        }
        catch (Exception exception) when (exception is not VerifierFailure)
        {
            throw Product($"{name} is not strict UTF-8 JSON: {exception.Message}", exception);
        }
    }

    private static Dictionary<string, FileIdentity> CaptureIdentities(IReadOnlyDictionary<string, string> paths)
    {
        var result = new Dictionary<string, FileIdentity>(StringComparer.Ordinal);
        foreach (var (relative, path) in paths)
        {
            PathSafety.RejectReparsePointsInExistingChain(path, $"Package file '{relative}'");
            result.Add(relative, StableFileIdentity.Capture(path));
        }
        return result;
    }

    private static string Hash(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
    }

    private static VerifierFailure Product(string message, Exception? inner = null) =>
        new(FailureClassification.ProductContract, "package_preflight", message, inner);
}

internal static class StableFileIdentity
{
    [StructLayout(LayoutKind.Sequential)]
    private struct ByHandleFileInformation
    {
        public uint FileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(
        SafeFileHandle handle,
        out ByHandleFileInformation information);

    public static FileIdentity Capture(string path)
    {
        // 同一只读 handle 同时取得 File ID、长度与 hash，拒绝同字节替换伪装成未变化。
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 4096, FileOptions.SequentialScan);
        if (!GetFileInformationByHandle(stream.SafeFileHandle, out var information))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "GetFileInformationByHandle failed.");
        var length = stream.Length;
        var sha256 = Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
        var fileIndex = ((ulong)information.FileIndexHigh << 32) | information.FileIndexLow;
        return new FileIdentity(length, sha256, information.VolumeSerialNumber, fileIndex);
    }
}
