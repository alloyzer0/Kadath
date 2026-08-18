using System.Text;
using Kadath.Editor.Toolchain;

namespace Kadath.Editor.Toolchain.ContractVerifier;

internal static class ImportPublicationContract
{
    private static readonly byte[] ForeignReplacement = "foreign replacement must survive"u8.ToArray();

    internal static void Verify(ContractSandbox sandbox, string kadathRoot)
    {
        VerifyForeignSamePathReplacementIsRetained(sandbox.NewCase("import-foreign-replacement"));
        VerifyForeignReplacementCannotBePublished(sandbox.NewCase("import-foreign-before-move"));
        VerifyReparseParentRejected(sandbox.NewCase("import-reparse-parent"));
        VerifyReparseSourceRejected(sandbox.NewCase("import-reparse-source"));
        VerifyDeviceAndUncPathsRejected(sandbox.NewCase("import-device-paths"));
        VerifyExistingDestinationRetained(sandbox.NewCase("import-existing-destination"));
        VerifyEveryImportKindUsesPublisher(sandbox.NewCase("import-all-kinds"), kadathRoot);
    }

    private static void VerifyForeignReplacementCannotBePublished(string root)
    {
        var source = Path.Combine(root, "source.ppm");
        var destination = Path.Combine(root, "generated", "source.texture");
        File.WriteAllText(source, "P3\n1 1\n255\n11 23 43\n", new UTF8Encoding(false));
        string? replacementPath = null;

        _ = ContractAssert.Throws<Exception>(() => ToolchainImport.Execute(
            new ToolchainImportRequest(
                "texture",
                source,
                destination,
                "debug",
                temporary =>
                {
                    // 不抛错：publisher 必须依赖 owning handle，而不能把当前同名 foreign 对象移动到目标。
                    File.Delete(temporary);
                    File.WriteAllBytes(temporary, ForeignReplacement);
                    replacementPath = temporary;
                })));

        ContractAssert.Require(replacementPath is not null && File.Exists(replacementPath),
            "import publisher moved or deleted the foreign replacement path");
        ContractAssert.Require(File.ReadAllBytes(replacementPath!).AsSpan().SequenceEqual(ForeignReplacement),
            "import publisher altered the foreign replacement bytes");
        ContractAssert.Require(!File.Exists(destination),
            "import publisher advanced a foreign replacement to the destination");
    }

    private static void VerifyReparseSourceRejected(string root)
    {
        var target = Path.Combine(root, "source-target");
        var alias = Path.Combine(root, "source-alias");
        Directory.CreateDirectory(target);
        File.WriteAllText(Path.Combine(target, "source.ppm"), "P3\n1 1\n255\n17 31 53\n", new UTF8Encoding(false));

        VerifierJunction.WithDirectoryAlias(alias, target, () =>
        {
            var destination = Path.Combine(root, "source.texture");
            _ = ContractAssert.Throws<IOException>(() => ToolchainImport.Execute(
                new ToolchainImportRequest("texture", Path.Combine(alias, "source.ppm"), destination, "debug")), "reparse");
            ContractAssert.Require(!File.Exists(destination), "reparse-backed source advanced an import artifact");
        });
    }

    private static void VerifyDeviceAndUncPathsRejected(string root)
    {
        var source = Path.Combine(root, "source.ppm");
        File.WriteAllText(source, "P3\n1 1\n255\n19 37 59\n", new UTF8Encoding(false));
        var driveRoot = Path.GetPathRoot(root) ?? throw new IOException("verifier root has no drive");
        var deviceDestination = $@"\\?\{driveRoot}kadath-import-device-{Guid.NewGuid():N}.texture";
        foreach (var destination in new[]
                 {
                     $@"\\kadath-invalid-{Guid.NewGuid():N}\share\artifact.texture",
                     deviceDestination,
                     Path.Combine(root, "CON.texture"),
                     Path.Combine(root, "artifact.texture:foreign")
                 })
        {
            _ = ContractAssert.Throws<IOException>(() => ToolchainImport.Execute(
                new ToolchainImportRequest("texture", source, destination, "debug")), "device");
        }
        ContractAssert.Require(Directory.EnumerateFiles(root).Count() == 1,
            "device/UNC rejection created an unexpected file");
    }

    private static void VerifyExistingDestinationRetained(string root)
    {
        var source = Path.Combine(root, "source.ppm");
        var destination = Path.Combine(root, "artifact.texture");
        var sentinel = "existing artifact"u8.ToArray();
        File.WriteAllText(source, "P3\n1 1\n255\n23 41 61\n", new UTF8Encoding(false));
        File.WriteAllBytes(destination, sentinel);
        _ = ContractAssert.Throws<IOException>(() => ToolchainImport.Execute(
            new ToolchainImportRequest("texture", source, destination, "release")), "overwrite");
        ContractAssert.Require(File.ReadAllBytes(destination).AsSpan().SequenceEqual(sentinel),
            "no-replace import changed an existing destination");
    }

    private static void VerifyEveryImportKindUsesPublisher(string root, string kadathRoot)
    {
        var fixtures = new[]
        {
            (Kind: "texture", Source: Path.Combine(root, "source.ppm"), Destination: Path.Combine(root, "texture.out")),
            (Kind: "audio", Source: Path.Combine(root, "source.wav"), Destination: Path.Combine(root, "audio.out")),
            (Kind: "scene", Source: Path.Combine(root, "source.scene.json"), Destination: Path.Combine(root, "scene.out")),
            (Kind: "script", Source: Path.Combine(root, "source.script.json"), Destination: Path.Combine(root, "script.out"))
        };
        File.WriteAllText(fixtures[0].Source, "P3\n1 1\n255\n29 43 67\n", new UTF8Encoding(false));
        File.Copy(Path.Combine(kadathRoot, "assets", "audio", "won.wav"), fixtures[1].Source);
        File.Copy(Path.Combine(kadathRoot, "assets", "scenes", "preview.scene.json"), fixtures[2].Source);
        File.Copy(Path.Combine(kadathRoot, "assets", "scripts", "preview.script.json"), fixtures[3].Source);

        foreach (var fixture in fixtures)
        {
            var result = ToolchainImport.Execute(new ToolchainImportRequest(
                fixture.Kind,
                fixture.Source,
                fixture.Destination,
                "release"));
            ContractAssert.Require(result.Kind == fixture.Kind && result.Profile == "release" &&
                                   result.DestinationPath == fixture.Destination && result.ArtifactBytes > 0,
                $"{fixture.Kind} import result mismatch");
            ContractAssert.Require(result.Sha256 == ContractAssert.Sha256(fixture.Destination),
                $"{fixture.Kind} import result hash mismatch");
        }
        ContractAssert.Require(!Directory.EnumerateFiles(root, ".*.tmp").Any(),
            "successful imports left an owned temporary file");
    }

    private static void VerifyReparseParentRejected(string root)
    {
        var source = Path.Combine(root, "source.ppm");
        var target = Path.Combine(root, "foreign-target");
        var alias = Path.Combine(root, "reparse-parent");
        File.WriteAllText(source, "P3\n1 1\n255\n17 31 53\n", new UTF8Encoding(false));
        Directory.CreateDirectory(target);

        VerifierJunction.WithDirectoryAlias(alias, target, () =>
        {
            var destination = Path.Combine(alias, "source.texture");
            _ = ContractAssert.Throws<IOException>(() => ToolchainImport.Execute(
                new ToolchainImportRequest("texture", source, destination, "debug")), "reparse");
        });
        ContractAssert.Require(!Directory.EnumerateFileSystemEntries(target).Any(),
            "reparse-backed import wrote into the foreign target");
    }

    private static void VerifyForeignSamePathReplacementIsRetained(string root)
    {
        var source = Path.Combine(root, "source.ppm");
        var destination = Path.Combine(root, "generated", "source.texture");
        File.WriteAllText(source, "P3\n1 1\n255\n13 29 47\n", new UTF8Encoding(false));
        string? replacementPath = null;

        _ = ContractAssert.Throws<Exception>(() => ToolchainImport.Execute(
            new ToolchainImportRequest(
                "texture",
                source,
                destination,
                "debug",
                temporary =>
                {
                    // 模拟 publisher 关闭 owning handle 后，foreign actor 用同一路径替换对象。
                    File.Delete(temporary);
                    File.WriteAllBytes(temporary, ForeignReplacement);
                    replacementPath = temporary;
                    throw new InvalidOperationException("Injected import publication failure after replacement.");
                })));

        ContractAssert.Require(replacementPath is not null && File.Exists(replacementPath),
            "import failure deleted a foreign same-path replacement");
        ContractAssert.Require(File.ReadAllBytes(replacementPath!).AsSpan().SequenceEqual(ForeignReplacement),
            "import failure altered the foreign same-path replacement");
        ContractAssert.Require(!File.Exists(destination), "failed import advanced the destination");
    }
}
