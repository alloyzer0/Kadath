using System.Buffers.Binary;
using System.Text.Json;
using System.Text.Json.Nodes;
using Kadath.Editor.Verification;
using Kadath.Runtime.Windows.ContractVerifier;

namespace Kadath.Runtime.Windows.ContractVerifier.ContractVerifier;

internal static class Program
{
    private static int Main(string[] args)
    {
        if (args.Length != 1)
        {
            Console.Error.WriteLine("Usage: <exact-18-package-root>");
            return 2;
        }

        var sandbox = Path.Combine(Path.GetTempPath(), $"kadath-runtime-contract-{Guid.NewGuid():N}");
        Directory.CreateDirectory(sandbox);
        try
        {
            VerifyPackageContract(Path.GetFullPath(args[0]), sandbox);
            Console.WriteLine("package_contract=ok");
            VerifyStatusClassification();
            Console.WriteLine("status_protocol_contract=ok");
            Console.WriteLine("verification=ok");
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine($"verification=failed: {exception}");
            return 1;
        }
        finally
        {
            if (Directory.Exists(sandbox)) Directory.Delete(sandbox, recursive: true);
        }
    }

    private static void VerifyPackageContract(string packageRoot, string sandbox)
    {
        _ = PackageContract.Load(packageRoot);

        ExpectPackageRejection(packageRoot, sandbox, "missing-readme", root =>
            File.Delete(Path.Combine(root, "README.txt")));
        ExpectPackageRejection(packageRoot, sandbox, "missing-behavior-tool", root =>
            File.Delete(Path.Combine(root, "behavior-tools", "kadath-behavior-tool.exe")));
        ExpectPackageRejection(packageRoot, sandbox, "unknown-extra", root =>
            File.WriteAllText(Path.Combine(root, "bin", "unknown.extra"), "foreign"));
        ExpectPackageRejection(packageRoot, sandbox, "pdb-extra", root =>
            File.WriteAllText(Path.Combine(root, "bin", "kadath.pdb"), "symbols"));
        ExpectPackageRejection(packageRoot, sandbox, "host-v1", root =>
        {
            var path = Path.Combine(root, "bin", "assets", "scripts", "preview.script");
            var bytes = File.ReadAllBytes(path);
            BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(12, 4), 1);
            File.WriteAllBytes(path, bytes);
        });
        ExpectPackageRejection(packageRoot, sandbox, "release-without-sidecar", root =>
        {
            var path = Path.Combine(root, "bin", "kadath-runtime-build-profile.json");
            var document = JsonNode.Parse(File.ReadAllBytes(path))?.AsObject()
                ?? throw new InvalidDataException("Build profile fixture is not an object.");
            document["Optimize"] = "ReleaseSafe";
            document["BuildPreflightSidecarSha256"] = null;
            File.WriteAllText(path, document.ToJsonString(new JsonSerializerOptions { WriteIndented = false }));
        });

        VerifyFinalPackageContract(packageRoot, sandbox);
    }

    private static void VerifyFinalPackageContract(string packageRoot, string sandbox)
    {
        ExpectFinalPackageRejection(
            packageRoot,
            sandbox,
            "final-missing-readme",
            root => File.Delete(Path.Combine(root, "README.txt")),
            FailureClassification.PackageIdentity,
            "identity_after");
        ExpectFinalPackageRejection(
            packageRoot,
            sandbox,
            "final-unknown-extra",
            root => File.WriteAllText(Path.Combine(root, "bin", "unknown.extra"), "foreign"),
            FailureClassification.PackageIdentity,
            "identity_after");
        ExpectFinalPackageRejection(
            packageRoot,
            sandbox,
            "final-pdb-extra",
            root => File.WriteAllText(Path.Combine(root, "bin", "kadath.pdb"), "symbols"),
            FailureClassification.PackageIdentity,
            "identity_after");
        ExpectFinalPackageRejection(
            packageRoot,
            sandbox,
            "final-host-v1",
            root =>
            {
                var path = Path.Combine(root, "bin", "assets", "scripts", "preview.script");
                var bytes = File.ReadAllBytes(path);
                BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(12, 4), 1);
                File.WriteAllBytes(path, bytes);
            },
            FailureClassification.PackageIdentity,
            "identity_after");
        ExpectFinalPackageRejection(
            packageRoot,
            sandbox,
            "final-profile-change",
            root =>
            {
                var path = Path.Combine(root, "bin", "kadath-runtime-build-profile.json");
                var document = JsonNode.Parse(File.ReadAllBytes(path))?.AsObject()
                    ?? throw new InvalidDataException("Build profile fixture is not an object.");
                document["TextureProfile"] = "mutated";
                File.WriteAllText(path, document.ToJsonString(new JsonSerializerOptions { WriteIndented = false }));
            },
            FailureClassification.PackageIdentity,
            "identity_after");

        var reparseCandidate = CreateCandidate(packageRoot, sandbox, "final-directory-reparse");
        var reparseContract = PackageContract.Load(reparseCandidate);
        // 关键负向夹具：运行期间把已验证目录替换成 junction，最终契约必须 no-follow 拒绝。
        VerifierWindowsDirectoryLink.WithDirectoryReplacement(
            Path.Combine(reparseCandidate, "behavior-tools"),
            () => ExpectFinalContractFailure(
                reparseContract,
                "final-directory-reparse",
                FailureClassification.PackageIdentity,
                "identity_after"));
    }

    private static void ExpectPackageRejection(
        string packageRoot,
        string sandbox,
        string caseName,
        Action<string> mutate)
    {
        var candidate = Path.Combine(sandbox, caseName);
        CopyTree(packageRoot, candidate);
        mutate(candidate);
        ExpectProductFailure(() => _ = PackageContract.Load(candidate), caseName);
    }

    private static void ExpectFinalPackageRejection(
        string packageRoot,
        string sandbox,
        string caseName,
        Action<string> mutate,
        FailureClassification expectedClassification,
        string expectedStage)
    {
        var candidate = CreateCandidate(packageRoot, sandbox, caseName);
        var contract = PackageContract.Load(candidate);
        mutate(candidate);
        ExpectFinalContractFailure(contract, caseName, expectedClassification, expectedStage);
    }

    private static string CreateCandidate(string packageRoot, string sandbox, string caseName)
    {
        var candidate = Path.Combine(sandbox, caseName);
        CopyTree(packageRoot, candidate);
        return candidate;
    }

    private static void ExpectFinalContractFailure(
        PackageContract contract,
        string caseName,
        FailureClassification expectedClassification,
        string expectedStage)
    {
        try
        {
            var after = contract.CaptureCurrentIdentities();
            PackageContract.AssertIdentityUnchanged(contract.IdentityBefore, after);
        }
        catch (VerifierFailure failure)
        {
            if (failure.Classification != expectedClassification || failure.Stage != expectedStage)
            {
                throw new InvalidOperationException(
                    $"{caseName} reported {failure.Classification}/{failure.Stage} instead of {expectedClassification}/{expectedStage}.",
                    failure);
            }
            return;
        }
        catch (Exception exception)
        {
            throw new InvalidOperationException($"{caseName} returned a non-contract failure.", exception);
        }
        throw new InvalidOperationException($"{caseName} was incorrectly accepted after initial package validation.");
    }

    private static void VerifyStatusClassification()
    {
        var expected = new FileIdentity(4, new string('a', 64), 1, 1);
        ExpectProductFailure(
            () => RuntimeStatusProtocol.ParseInitialLoaded(
                "{\"sequence\":1,\"event\":\"runtime_ready\"}", expected, expected),
            "missing schemaVersion");
        ExpectProductFailure(
            () => RuntimeStatusProtocol.ParseInitialLoaded(
                "{\"schemaVersion\":1,\"sequence\":1}", expected, expected),
            "missing event");
        ExpectProductFailure(
            () => RuntimeStatusProtocol.ParseInitialLoaded(
                "{\"schemaVersion\":1,\"sequence\":1,\"event\":\"runtime_ready\",\"initialLoaded\":{\"scene\":{},\"script\":{}}}",
                expected,
                expected),
            "missing target fields");
        ExpectProductFailure(
            () => RuntimeStatusProtocol.AssertWindowClose(
                "{\"schemaVersion\":1,\"sequence\":1,\"event\":\"runtime_ready\"}",
                "final_contract"),
            "missing runtime_stopping",
            "final_contract");
    }

    private static void ExpectProductFailure(Action action, string caseName, string? expectedStage = null)
    {
        try
        {
            action();
        }
        catch (VerifierFailure failure) when (failure.Classification == FailureClassification.ProductContract)
        {
            if (expectedStage is not null && failure.Stage != expectedStage)
                throw new InvalidOperationException(
                    $"{caseName} reported stage '{failure.Stage}' instead of '{expectedStage}'.",
                    failure);
            return;
        }
        catch (Exception exception)
        {
            throw new InvalidOperationException($"{caseName} returned the wrong failure classification.", exception);
        }
        throw new InvalidOperationException($"{caseName} was incorrectly accepted.");
    }

    private static void CopyTree(string source, string destination)
    {
        if (!Directory.Exists(source)) throw new DirectoryNotFoundException(source);
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
