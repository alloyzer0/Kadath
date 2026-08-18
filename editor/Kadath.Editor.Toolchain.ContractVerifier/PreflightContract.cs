using System.Text;
using System.Text.Json;
using Kadath.Editor.Toolchain;

namespace Kadath.Editor.Toolchain.ContractVerifier;

internal static class PreflightContract
{
    private static readonly string[] ExpectedFields =
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

    internal static void Verify(ContractSandbox sandbox)
    {
        VerifySuccessAndOverwrite(sandbox.NewCase("preflight-success"));
        VerifyExistingRootRejected(sandbox.NewCase("preflight-existing-root"));
    }

    private static void VerifySuccessAndOverwrite(string root)
    {
        var package = Path.Combine(root, "package");
        var localCache = Path.Combine(root, "local-cache");
        var globalCache = Path.Combine(root, "global-cache");
        var destination = Path.Combine(root, "evidence", "preflight.json");
        var request = new ToolchainPreflightRequest(package, localCache, globalCache, destination);
        var result = ToolchainPreflight.Execute(request);

        ContractAssert.Require(result.DestinationPath == destination && File.Exists(destination), "preflight result path mismatch");
        var bytes = File.ReadAllBytes(destination);
        ContractAssert.Require(!bytes.AsSpan().StartsWith(Encoding.UTF8.Preamble) && bytes[^1] == (byte)'\n', "preflight must be UTF-8 no BOM with one trailing newline");
        using var document = JsonDocument.Parse(bytes);
        var properties = document.RootElement.EnumerateObject().ToArray();
        ContractAssert.Require(
            properties.Select(value => value.Name).OrderBy(value => value, StringComparer.Ordinal)
                .SequenceEqual(ExpectedFields.OrderBy(value => value, StringComparer.Ordinal), StringComparer.Ordinal),
            "preflight exact-eight schema mismatch");
        ContractAssert.Require(document.RootElement.GetProperty("Version").GetInt32() == 1 &&
            document.RootElement.GetProperty("PackageRootAbsentBefore").GetBoolean() &&
            document.RootElement.GetProperty("TaskLocalCacheAbsentBefore").GetBoolean() &&
            document.RootElement.GetProperty("GlobalCacheAbsentBefore").GetBoolean(),
            "preflight absent-before witness mismatch");
        ContractAssert.Require(!Directory.Exists(package) && !Directory.Exists(localCache) && !Directory.Exists(globalCache),
            "preflight advanced a witnessed cold root");

        var before = bytes.ToArray();
        ContractAssert.Throws<IOException>(() => ToolchainPreflight.Execute(request), "Refusing to overwrite toolchain output");
        ContractAssert.Require(File.ReadAllBytes(destination).AsSpan().SequenceEqual(before), "preflight overwrite changed the retained witness");
    }

    private static void VerifyExistingRootRejected(string root)
    {
        var package = Path.Combine(root, "package");
        var destination = Path.Combine(root, "preflight.json");
        Directory.CreateDirectory(package);
        ContractAssert.Throws<IOException>(() => ToolchainPreflight.Execute(new ToolchainPreflightRequest(
            package,
            Path.Combine(root, "local-cache"),
            Path.Combine(root, "global-cache"),
            destination)), "must be absent before the cold build");
        ContractAssert.Require(!File.Exists(destination), "existing-root rejection advanced the preflight sidecar");
    }
}
