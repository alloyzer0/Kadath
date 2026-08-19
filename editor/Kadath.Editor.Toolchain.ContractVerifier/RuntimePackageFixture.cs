using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using Kadath.Editor.Toolchain;

namespace Kadath.Editor.Toolchain.ContractVerifier;

internal sealed class RuntimePackageFixture
{
    internal static readonly string[] ExactV2Files =
    [
        "README.txt",
        "behavior-tools/kadath-behavior-tool.exe",
        "bin/assets/audio/lost.audio.wav",
        "bin/assets/audio/lost.wav",
        "bin/assets/audio/won.audio.wav",
        "bin/assets/audio/won.wav",
        "bin/assets/renderer2d/goal.png",
        "bin/assets/renderer2d/goal.texture",
        "bin/assets/renderer2d/test.png",
        "bin/assets/renderer2d/test.texture",
        "bin/assets/scenes/preview.scene",
        "bin/assets/scenes/preview.scene.json",
        "bin/assets/scripts/patrol.luau",
        "bin/assets/scripts/player_controller.luau",
        "bin/assets/scripts/preview.script",
        "bin/assets/scripts/preview.script.json",
        "bin/kadath-runtime-build-profile.json",
        "bin/kadath.exe"
    ];

    private RuntimePackageFixture(string root, string packageRoot, string kadathRoot)
    {
        Root = root;
        PackageRoot = packageRoot;
        KadathRoot = kadathRoot;
    }

    internal string Root { get; }
    internal string PackageRoot { get; }
    internal string KadathRoot { get; }

    internal static RuntimePackageFixture Create(string root, string kadathRoot)
    {
        var package = Path.Combine(root, "package");
        var localCache = Path.Combine(root, "local-cache");
        var globalCache = Path.Combine(root, "global-cache");
        var preflight = Path.Combine(root, "evidence", "preflight.json");
        _ = ToolchainPreflight.Execute(new ToolchainPreflightRequest(package, localCache, globalCache, preflight));
        Directory.CreateDirectory(package);
        Directory.CreateDirectory(localCache);
        Directory.CreateDirectory(globalCache);

        Write(package, "README.txt", Encoding.UTF8.GetBytes("Kadath Runtime fixture\n"));
        Write(package, "behavior-tools/kadath-behavior-tool.exe", [0x4d, 0x5a, 0x90, 0x00]);
        Write(package, "bin/kadath.exe", [0x4d, 0x5a, 0x01, 0x02]);
        Write(package, "bin/assets/renderer2d/test.png", [1, 2, 3, 4]);
        Write(package, "bin/assets/renderer2d/test.texture", [5, 6, 7, 8]);
        Write(package, "bin/assets/renderer2d/goal.png", [9, 10, 11, 12]);
        Write(package, "bin/assets/renderer2d/goal.texture", [13, 14, 15, 16]);
        Write(package, "bin/assets/audio/won.wav", Encoding.ASCII.GetBytes("RIFFwon"));
        Write(package, "bin/assets/audio/lost.wav", Encoding.ASCII.GetBytes("RIFFlost"));
        Write(package, "bin/assets/audio/won.audio.wav", Encoding.ASCII.GetBytes("RIFFwon-derived"));
        Write(package, "bin/assets/audio/lost.audio.wav", Encoding.ASCII.GetBytes("RIFFlost-derived"));
        Write(package, "bin/assets/scenes/preview.scene", Encoding.ASCII.GetBytes("KSCN-fixture"));
        Write(package, "bin/assets/scenes/preview.scene.json", Encoding.UTF8.GetBytes("{\"schemaVersion\":5}\n"));
        Write(package, "bin/assets/scripts/preview.script", BuildBehaviorScriptV2());
        Write(package, "bin/assets/scripts/preview.script.json", Encoding.UTF8.GetBytes("{\"schemaVersion\":2}\n"));
        Write(package, "bin/assets/scripts/patrol.luau", Encoding.UTF8.GetBytes("return function() end\n"));
        Write(package, "bin/assets/scripts/player_controller.luau", Encoding.UTF8.GetBytes("return function() end\n"));

        var vertexShader = Path.Combine(kadathRoot, "shaders", "renderer2d", "quad.vert.glsl");
        var fragmentShader = Path.Combine(kadathRoot, "shaders", "renderer2d", "quad.frag.glsl");
        ContractAssert.Require(File.Exists(Path.Combine(kadathRoot, "build.zig")) && File.Exists(vertexShader) && File.Exists(fragmentShader),
            "Kadath root is missing real shader/build identity files");
        _ = ToolchainBuildProfile.Execute(new ToolchainBuildProfileRequest(
            Path.Combine(package, "bin", "kadath.exe"),
            Path.Combine(package, "bin", "assets", "renderer2d", "test.png"),
            Path.Combine(package, "bin", "assets", "renderer2d", "test.texture"),
            Path.Combine(package, "bin", "assets", "renderer2d", "goal.png"),
            Path.Combine(package, "bin", "assets", "renderer2d", "goal.texture"),
            vertexShader,
            fragmentShader,
            "ReleaseSafe",
            package,
            localCache,
            globalCache,
            preflight,
            Path.Combine(package, "bin", "kadath-runtime-build-profile.json")));

        var actual = TreeIdentity(package).Keys.OrderBy(path => path, StringComparer.Ordinal).ToArray();
        ContractAssert.Require(actual.SequenceEqual(ExactV2Files, StringComparer.Ordinal),
            $"synthetic Runtime package is not independent exact-18: {string.Join(",", actual)}");
        return new RuntimePackageFixture(root, package, kadathRoot);
    }

    internal string ClonePackage(string caseRoot)
    {
        var clone = Path.Combine(caseRoot, "package");
        CopyDirectory(PackageRoot, clone);
        return clone;
    }

    internal ToolchainRuntimeArchiveRequest Request(
        string packageRoot,
        string outputDirectory,
        string extractDirectory,
        string? barrier = null,
        Action<string>? afterOwnedCleanupEntryClassifiedForTesting = null,
        Action<string>? afterPackageSnapshotCreatedForTesting = null) =>
        new(
            packageRoot,
            outputDirectory,
            extractDirectory,
            KadathRoot,
            ToolchainRuntimePackagePolicy.KscpV2,
            barrier,
            afterOwnedCleanupEntryClassifiedForTesting,
            afterPackageSnapshotCreatedForTesting);

    internal static SortedDictionary<string, string> TreeIdentity(string root)
    {
        var identity = new SortedDictionary<string, string>(StringComparer.Ordinal);
        foreach (var path in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories))
        {
            var relative = Path.GetRelativePath(root, path).Replace('\\', '/');
            identity.Add(relative, ContractAssert.Sha256(path));
        }
        return identity;
    }

    internal static byte[] BuildLegacyScriptV1()
    {
        var artifact = new byte[48];
        Encoding.ASCII.GetBytes("KSCP").CopyTo(artifact, 0);
        BinaryPrimitives.WriteUInt32LittleEndian(artifact.AsSpan(4, 4), 1);
        BinaryPrimitives.WriteUInt32LittleEndian(artifact.AsSpan(8, 4), 1);
        BinaryPrimitives.WriteUInt32LittleEndian(artifact.AsSpan(12, 4), 2);
        WriteLegacyInstruction(artifact, 16, 0, 0, 1, 2);
        WriteLegacyInstruction(artifact, 32, 1, 1, 3, 4);
        return artifact;
    }

    private static byte[] BuildBehaviorScriptV2()
    {
        var toolchain = Encoding.UTF8.GetBytes("fixture-1");
        var sourceName = Encoding.UTF8.GetBytes("scripts/patrol.luau");
        var source = Encoding.UTF8.GetBytes("return function() end\n");
        var bytecode = new byte[] { 0x1b, 0x4c, 0x75, 0x61 };
        const int headerBytes = 60;
        const int entryHeaderBytes = 84;
        var entryBytes = checked(entryHeaderBytes + sourceName.Length + bytecode.Length);
        var payloadBytes = checked(toolchain.Length + entryBytes);
        var artifact = new byte[checked(headerBytes + payloadBytes)];
        Encoding.ASCII.GetBytes("KSCP").CopyTo(artifact, 0);
        BinaryPrimitives.WriteUInt32LittleEndian(artifact.AsSpan(4, 4), 2);
        BinaryPrimitives.WriteUInt32LittleEndian(artifact.AsSpan(8, 4), 2);
        BinaryPrimitives.WriteUInt32LittleEndian(artifact.AsSpan(12, 4), 2);
        BinaryPrimitives.WriteUInt32LittleEndian(artifact.AsSpan(16, 4), 1);
        BinaryPrimitives.WriteUInt32LittleEndian(artifact.AsSpan(20, 4), checked((uint)toolchain.Length));
        BinaryPrimitives.WriteUInt32LittleEndian(artifact.AsSpan(24, 4), checked((uint)payloadBytes));

        var offset = headerBytes;
        toolchain.CopyTo(artifact, offset);
        offset += toolchain.Length;
        BinaryPrimitives.WriteUInt32LittleEndian(artifact.AsSpan(offset, 4), checked((uint)entryBytes));
        offset += 4;
        BinaryPrimitives.WriteUInt32LittleEndian(artifact.AsSpan(offset, 4), 1);
        offset += 4;
        BinaryPrimitives.WriteUInt32LittleEndian(artifact.AsSpan(offset, 4), checked((uint)sourceName.Length));
        offset += 4;
        BinaryPrimitives.WriteUInt32LittleEndian(artifact.AsSpan(offset, 4), 0);
        offset += 4;
        BinaryPrimitives.WriteUInt32LittleEndian(artifact.AsSpan(offset, 4), checked((uint)bytecode.Length));
        offset += 4;
        SHA256.HashData(source).CopyTo(artifact, offset);
        offset += 32;
        SHA256.HashData(bytecode).CopyTo(artifact, offset);
        offset += 32;
        sourceName.CopyTo(artifact, offset);
        offset += sourceName.Length;
        bytecode.CopyTo(artifact, offset);
        offset += bytecode.Length;
        ContractAssert.Require(offset == artifact.Length, "synthetic KSCP v2 length mismatch");
        SHA256.HashData(artifact.AsSpan(headerBytes)).CopyTo(artifact, 28);
        return artifact;
    }

    private static void WriteLegacyInstruction(byte[] artifact, int offset, uint hook, uint operation, float x, float y)
    {
        BinaryPrimitives.WriteUInt32LittleEndian(artifact.AsSpan(offset, 4), hook);
        BinaryPrimitives.WriteUInt32LittleEndian(artifact.AsSpan(offset + 4, 4), operation);
        BinaryPrimitives.WriteInt32LittleEndian(artifact.AsSpan(offset + 8, 4), BitConverter.SingleToInt32Bits(x));
        BinaryPrimitives.WriteInt32LittleEndian(artifact.AsSpan(offset + 12, 4), BitConverter.SingleToInt32Bits(y));
    }

    private static void Write(string root, string relative, byte[] bytes)
    {
        var path = Path.Combine(root, relative.Replace('/', Path.DirectorySeparatorChar));
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllBytes(path, bytes);
    }

    private static void CopyDirectory(string source, string destination)
    {
        Directory.CreateDirectory(destination);
        foreach (var directory in Directory.EnumerateDirectories(source, "*", SearchOption.AllDirectories))
            Directory.CreateDirectory(Path.Combine(destination, Path.GetRelativePath(source, directory)));
        foreach (var file in Directory.EnumerateFiles(source, "*", SearchOption.AllDirectories))
        {
            var target = Path.Combine(destination, Path.GetRelativePath(source, file));
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            File.Copy(file, target, overwrite: false);
        }
    }
}
