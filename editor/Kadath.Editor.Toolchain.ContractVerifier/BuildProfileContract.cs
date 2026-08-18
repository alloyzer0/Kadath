using System.Text;
using System.Text.Json;
using Kadath.Editor.Toolchain;

namespace Kadath.Editor.Toolchain.ContractVerifier;

internal static class BuildProfileContract
{
    private static readonly string[] ExactEleven =
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

    internal static void Verify(ContractSandbox sandbox)
    {
        VerifyExactElevenAndIdentity(sandbox.NewCase("profile-success"));
        VerifyInvalidPreflightSchemaRejected(sandbox.NewCase("profile-invalid-preflight"));
    }

    private static void VerifyExactElevenAndIdentity(string root)
    {
        var fixture = CreateFixture(root, invalidPreflightSchema: false);
        var result = ToolchainBuildProfile.Execute(fixture.Request);
        var bytes = File.ReadAllBytes(result.DestinationPath);
        ContractAssert.Require(!bytes.AsSpan().StartsWith(Encoding.UTF8.Preamble) &&
            bytes[^1] == (byte)'\n' && !bytes[..^1].Contains((byte)'\n') && !bytes.Contains((byte)'\r'),
            "build profile must be one-line UTF-8 no BOM with one trailing newline");
        using var document = JsonDocument.Parse(bytes);
        var rootElement = document.RootElement;
        var names = rootElement.EnumerateObject().Select(property => property.Name).ToArray();
        ContractAssert.Require(names.Length == 11 && names.Distinct(StringComparer.Ordinal).Count() == 11 &&
            new HashSet<string>(names, StringComparer.Ordinal).SetEquals(ExactEleven),
            "build profile exact-eleven schema mismatch");
        ContractAssert.Require(rootElement.GetProperty("Version").ValueKind == JsonValueKind.Number &&
            rootElement.GetProperty("Version").GetInt32() == 2 &&
            rootElement.GetProperty("Optimize").GetString() == "ReleaseSafe" &&
            rootElement.GetProperty("TextureProfile").GetString() == "release",
            "build profile fixed fields mismatch");
        ContractAssert.Require(rootElement.GetProperty("RuntimeExeSha256").GetString() == ContractAssert.Sha256(fixture.Runtime) &&
            rootElement.GetProperty("TextureSourceSha256").GetString() == ContractAssert.Sha256(fixture.TextureSource) &&
            rootElement.GetProperty("TextureArtifactSha256").GetString() == ContractAssert.Sha256(fixture.TextureArtifact) &&
            rootElement.GetProperty("SecondaryTextureSourceSha256").GetString() == ContractAssert.Sha256(fixture.SecondaryTextureSource) &&
            rootElement.GetProperty("SecondaryTextureArtifactSha256").GetString() == ContractAssert.Sha256(fixture.SecondaryTextureArtifact) &&
            rootElement.GetProperty("VertexShaderSourceSha256").GetString() == ContractAssert.Sha256(fixture.VertexShader) &&
            rootElement.GetProperty("FragmentShaderSourceSha256").GetString() == ContractAssert.Sha256(fixture.FragmentShader) &&
            rootElement.GetProperty("BuildPreflightSidecarSha256").GetString() == ContractAssert.Sha256(fixture.Preflight),
            "build profile identity fields mismatch");

        File.AppendAllText(fixture.Runtime, "tampered", Encoding.UTF8);
        ContractAssert.Throws<InvalidDataException>(() => ToolchainBuildProfile.AssertReleaseIdentity(
            bytes,
            ContractAssert.Sha256(fixture.Runtime),
            ContractAssert.Sha256(fixture.TextureSource),
            ContractAssert.Sha256(fixture.TextureArtifact),
            ContractAssert.Sha256(fixture.SecondaryTextureSource),
            ContractAssert.Sha256(fixture.SecondaryTextureArtifact),
            ContractAssert.Sha256(fixture.VertexShader),
            ContractAssert.Sha256(fixture.FragmentShader)),
            "sidecar-bound ReleaseSafe marker");
    }

    private static void VerifyInvalidPreflightSchemaRejected(string root)
    {
        var fixture = CreateFixture(root, invalidPreflightSchema: true);
        ContractAssert.Throws<InvalidDataException>(() => ToolchainBuildProfile.Execute(fixture.Request), "properties must be unique and exactly match");
        ContractAssert.Require(!File.Exists(fixture.Request.DestinationPath),
            "invalid preflight schema advanced the build profile output");
    }

    private static BuildProfileFixture CreateFixture(string root, bool invalidPreflightSchema)
    {
        var package = Path.Combine(root, "package");
        var localCache = Path.Combine(root, "local-cache");
        var globalCache = Path.Combine(root, "global-cache");
        var preflight = Path.Combine(root, "evidence", "preflight.json");
        if (invalidPreflightSchema)
            WriteInvalidPreflight(preflight, package, localCache, globalCache);
        else
            _ = ToolchainPreflight.Execute(new ToolchainPreflightRequest(package, localCache, globalCache, preflight));

        Directory.CreateDirectory(package);
        Directory.CreateDirectory(localCache);
        Directory.CreateDirectory(globalCache);
        var inputs = Path.Combine(root, "inputs");
        Directory.CreateDirectory(inputs);
        var runtime = WriteInput(inputs, "runtime.exe", [1, 2, 3]);
        var textureSource = WriteInput(inputs, "test.png", [4, 5]);
        var textureArtifact = WriteInput(inputs, "test.texture", [6, 7]);
        var secondaryTextureSource = WriteInput(inputs, "goal.png", [8, 9]);
        var secondaryTextureArtifact = WriteInput(inputs, "goal.texture", [10, 11]);
        var vertexShader = WriteInput(inputs, "quad.vert.glsl", Encoding.UTF8.GetBytes("vertex"));
        var fragmentShader = WriteInput(inputs, "quad.frag.glsl", Encoding.UTF8.GetBytes("fragment"));
        var destination = Path.Combine(package, "bin", "kadath-runtime-build-profile.json");
        var request = new ToolchainBuildProfileRequest(
            runtime,
            textureSource,
            textureArtifact,
            secondaryTextureSource,
            secondaryTextureArtifact,
            vertexShader,
            fragmentShader,
            "ReleaseSafe",
            package,
            localCache,
            globalCache,
            preflight,
            destination);
        return new BuildProfileFixture(
            request,
            runtime,
            textureSource,
            textureArtifact,
            secondaryTextureSource,
            secondaryTextureArtifact,
            vertexShader,
            fragmentShader,
            preflight);
    }

    private static string WriteInput(string root, string name, byte[] bytes)
    {
        var path = Path.Combine(root, name);
        File.WriteAllBytes(path, bytes);
        return path;
    }

    private static void WriteInvalidPreflight(
        string destination,
        string package,
        string localCache,
        string globalCache)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
        using var memory = new MemoryStream();
        using (var writer = new Utf8JsonWriter(memory))
        {
            writer.WriteStartObject();
            writer.WriteNumber("Version", 1);
            writer.WriteString("GeneratedAtUtc", DateTimeOffset.UtcNow.ToString("O"));
            writer.WriteString("PackageRoot", package);
            writer.WriteString("TaskLocalCacheDirectory", localCache);
            writer.WriteString("GlobalCacheDirectory", globalCache);
            writer.WriteBoolean("PackageRootAbsentBefore", true);
            writer.WriteBoolean("TaskLocalCacheAbsentBefore", true);
            writer.WriteBoolean("GlobalCacheAbsentBefore", true);
            writer.WriteBoolean("Unexpected", true);
            writer.WriteEndObject();
        }
        File.WriteAllBytes(destination, memory.ToArray());
    }

    private sealed record BuildProfileFixture(
        ToolchainBuildProfileRequest Request,
        string Runtime,
        string TextureSource,
        string TextureArtifact,
        string SecondaryTextureSource,
        string SecondaryTextureArtifact,
        string VertexShader,
        string FragmentShader,
        string Preflight);
}
