using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using Kadath.Editor.Toolchain;

namespace Kadath.Editor.Toolchain.ContractVerifier;

internal static class RuntimeArchiveContract
{
    internal static async Task VerifyAsync(ContractSandbox sandbox, string kadathRoot)
    {
        var fixture = RuntimePackageFixture.Create(sandbox.NewCase("runtime-package-base"), kadathRoot);
        VerifyReproducibleExactV2(sandbox, fixture);
        VerifyPrewriteFailures(sandbox, fixture);
        VerifyReparseRejected(sandbox, fixture);
        VerifyPreexistingOutputRetained(sandbox, fixture);
        VerifyOwnedCleanupRejectsForeignEntryBeforeClaim(sandbox, fixture);
        VerifyOwnedCleanupRejectsDirectoryReplacement(sandbox, fixture);
        VerifyOwnedCleanupRejectsFileReplacement(sandbox, fixture);
        VerifyOwnedCleanupRejectsJunctionReplacement(sandbox, fixture);
        await VerifyRetainedHandleMutationAsync(sandbox, fixture).ConfigureAwait(false);
    }

    private static void VerifyOwnedCleanupRejectsForeignEntryBeforeClaim(
        ContractSandbox sandbox,
        RuntimePackageFixture fixture)
    {
        if (!OperatingSystem.IsWindows()) return;

        var root = sandbox.NewCase("archive-owned-cleanup-before-claim");
        var output = Path.Combine(root, "output");
        var extract = Path.Combine(root, "extract");
        string? stagingRoot = null;
        string? foreignSentinel = null;
        Exception? failure = null;
        try
        {
            var request = fixture.Request(
                fixture.PackageRoot,
                output,
                extract,
                afterPackageSnapshotCreatedForTesting: staging =>
                {
                    stagingRoot = staging;
                    foreignSentinel = Path.Combine(staging, "foreign-before-claim.sentinel");
                    File.WriteAllText(foreignSentinel, "foreign entry must never become owned", Encoding.UTF8);
                });
            _ = ToolchainRuntimeArchive.Execute(request);
        }
        catch (Exception exception)
        {
            failure = exception;
        }

        try
        {
            ContractAssert.Require(foreignSentinel is not null, "archive before-claim injection seam was not reached");
            ContractAssert.Require(File.Exists(foreignSentinel),
                "archive cleanup deleted a foreign entry inserted before ownership claim");
            ContractAssert.Require(failure is ToolchainRuntimeArchiveException,
                "archive accepted a foreign entry inserted before ownership claim");
            ContractAssert.Require(!Directory.Exists(output) && !Directory.Exists(extract),
                "archive before-claim failure advanced output/extract identity");
        }
        finally { DeleteVerifiedArchiveStagingRoot(stagingRoot); }
    }

    private static void VerifyReproducibleExactV2(ContractSandbox sandbox, RuntimePackageFixture fixture)
    {
        var firstRoot = sandbox.NewCase("archive-repro-first");
        var secondRoot = sandbox.NewCase("archive-repro-second");
        var first = ToolchainRuntimeArchive.Execute(fixture.Request(
            fixture.PackageRoot,
            Path.Combine(firstRoot, "output"),
            Path.Combine(firstRoot, "extract")));
        var second = ToolchainRuntimeArchive.Execute(fixture.Request(
            fixture.PackageRoot,
            Path.Combine(secondRoot, "output"),
            Path.Combine(secondRoot, "extract")));

        ContractAssert.Require(first.FileCount == 18 && second.FileCount == 18, "KSCP v2 archive file count mismatch");
        ContractAssert.Require(first.ArchiveSha256 == second.ArchiveSha256 &&
            first.ArchiveSha256 == ContractAssert.Sha256(first.ArchivePath) &&
            second.ArchiveSha256 == ContractAssert.Sha256(second.ArchivePath),
            "two independent KSCP v2 archives are not reproducible");
        ContractAssert.Require(File.ReadAllBytes(first.ManifestPath).AsSpan().SequenceEqual(File.ReadAllBytes(second.ManifestPath)),
            "two independent archive manifests differ");
        AssertDeliveryIdentity(fixture.PackageRoot, first);
        AssertDeliveryIdentity(fixture.PackageRoot, second);
    }

    private static void AssertDeliveryIdentity(string packageRoot, ToolchainRuntimeArchiveResult result)
    {
        var packageIdentity = RuntimePackageFixture.TreeIdentity(packageRoot);
        var extractIdentity = RuntimePackageFixture.TreeIdentity(result.ExtractDirectory);
        var manifestIdentity = ReadManifest(result.ManifestPath);
        var zipIdentity = ReadZip(result.ArchivePath);
        ContractAssert.Require(packageIdentity.Count == 18 &&
            packageIdentity.Keys.SequenceEqual(RuntimePackageFixture.ExactV2Files, StringComparer.Ordinal),
            "source package is not independent exact-18");
        ContractAssert.Require(packageIdentity.SequenceEqual(extractIdentity), "manifest/extract identity differs from source package");
        ContractAssert.Require(packageIdentity.SequenceEqual(manifestIdentity), "manifest identity differs from source package");
        ContractAssert.Require(packageIdentity.SequenceEqual(zipIdentity), "ZIP entry identity differs from source package");
        var outputFiles = Directory.EnumerateFiles(Path.GetDirectoryName(result.ArchivePath)!, "*", SearchOption.AllDirectories)
            .Select(Path.GetFileName)
            .OrderBy(value => value, StringComparer.Ordinal)
            .ToArray();
        ContractAssert.Require(outputFiles.SequenceEqual(new[] { "kadath-runtime-win-x64.zip", "manifest.sha256" }, StringComparer.Ordinal),
            "archive output directory contains an unexpected artifact");
        ContractAssert.Require(!packageIdentity.ContainsKey("bin/kadath.pdb"), "PDB leaked into KSCP v2 delivery identity");
    }

    private static void VerifyPrewriteFailures(ContractSandbox sandbox, RuntimePackageFixture fixture)
    {
        VerifyPrewriteFailure(sandbox, fixture, "archive-missing", package =>
            File.Delete(Path.Combine(package, "bin", "assets", "audio", "lost.wav")));
        VerifyPrewriteFailure(sandbox, fixture, "archive-extra-pdb", package =>
            File.WriteAllBytes(Path.Combine(package, "bin", "kadath.pdb"), [1, 2, 3]));
        VerifyPrewriteFailure(sandbox, fixture, "archive-profile-tamper", package =>
            File.AppendAllText(Path.Combine(package, "bin", "assets", "renderer2d", "goal.texture"), "tampered", Encoding.UTF8));
        VerifyPrewriteFailure(sandbox, fixture, "archive-script-policy", package =>
            File.WriteAllBytes(Path.Combine(package, "bin", "assets", "scripts", "preview.script"), RuntimePackageFixture.BuildLegacyScriptV1()));
    }

    private static void VerifyPrewriteFailure(
        ContractSandbox sandbox,
        RuntimePackageFixture fixture,
        string name,
        Action<string> mutate)
    {
        var root = sandbox.NewCase(name);
        var package = fixture.ClonePackage(root);
        var output = Path.Combine(root, "output");
        var extract = Path.Combine(root, "extract");
        mutate(package);
        var exception = ContractAssert.Throws<ToolchainRuntimeArchiveException>(() =>
            ToolchainRuntimeArchive.Execute(fixture.Request(package, output, extract)));
        // 关键安全断言：任何 allowlist/profile/script gate 失败都发生在 staging 首次写入之前。
        ContractAssert.Require(!exception.ArchiveWriteStarted, $"{name} advanced archive_write_started");
        ContractAssert.Require(!File.Exists(output) && !Directory.Exists(output) &&
            !File.Exists(extract) && !Directory.Exists(extract),
            $"{name} advanced output/extract identity");
    }

    private static void VerifyReparseRejected(ContractSandbox sandbox, RuntimePackageFixture fixture)
    {
        var root = sandbox.NewCase("archive-reparse");
        var package = fixture.ClonePackage(root);
        var external = Path.Combine(root, "external-target");
        Directory.CreateDirectory(external);
        File.WriteAllText(Path.Combine(external, "outside.txt"), "outside", Encoding.UTF8);
        var link = Path.Combine(package, "bin", "assets", "reparse-fixture");
        var output = Path.Combine(root, "output");
        var extract = Path.Combine(root, "extract");
        ToolchainRuntimeArchiveException? failure = null;
        VerifierJunction.WithDirectoryAlias(link, external, () =>
        {
            failure = ContractAssert.Throws<ToolchainRuntimeArchiveException>(() =>
                ToolchainRuntimeArchive.Execute(fixture.Request(package, output, extract)));
        });
        ContractAssert.Require(failure is { ArchiveWriteStarted: false }, "reparse rejection happened after archive writing started");
        ContractAssert.Require(!Directory.Exists(output) && !Directory.Exists(extract), "reparse rejection advanced output/extract");
        ContractAssert.Require(File.Exists(Path.Combine(external, "outside.txt")), "reparse rejection altered the external target");
    }

    private static void VerifyPreexistingOutputRetained(ContractSandbox sandbox, RuntimePackageFixture fixture)
    {
        var root = sandbox.NewCase("archive-preexisting-output");
        var package = fixture.ClonePackage(root);
        var output = Path.Combine(root, "output");
        var extract = Path.Combine(root, "extract");
        Directory.CreateDirectory(output);
        var sentinel = Path.Combine(output, "sentinel.bin");
        var sentinelBytes = new byte[] { 9, 8, 7, 6 };
        File.WriteAllBytes(sentinel, sentinelBytes);
        var failure = ContractAssert.Throws<ToolchainRuntimeArchiveException>(() =>
            ToolchainRuntimeArchive.Execute(fixture.Request(package, output, extract)));
        ContractAssert.Require(!failure.ArchiveWriteStarted, "preexisting output rejection happened after archive writing started");
        ContractAssert.Require(Directory.EnumerateFiles(output, "*", SearchOption.AllDirectories).SequenceEqual(new[] { sentinel }) &&
            File.ReadAllBytes(sentinel).AsSpan().SequenceEqual(sentinelBytes),
            "preexisting output rejection altered its sentinel");
        ContractAssert.Require(!Directory.Exists(extract), "preexisting output rejection advanced extract identity");
    }

    private static void VerifyOwnedCleanupRejectsDirectoryReplacement(
        ContractSandbox sandbox,
        RuntimePackageFixture fixture)
    {
        if (!OperatingSystem.IsWindows()) return;

        var root = sandbox.NewCase("archive-owned-cleanup-replacement");
        var output = Path.Combine(root, "output");
        var extract = Path.Combine(root, "extract");
        var foreign = Path.Combine(root, "foreign-replacement");
        var foreignSentinel = Path.Combine(foreign, "foreign.sentinel");
        var detachedOwned = Path.Combine(root, "detached-owned-child");
        Directory.CreateDirectory(foreign);
        File.WriteAllText(foreignSentinel, "foreign replacement must survive archive cleanup", Encoding.UTF8);

        string? replacedPath = null;
        string? stagingRoot = null;
        var injected = false;
        Exception? failure = null;
        try
        {
            var request = fixture.Request(
                fixture.PackageRoot,
                output,
                extract,
                afterOwnedCleanupEntryClassifiedForTesting: child =>
                {
                    if (injected || !Directory.Exists(child)) return;
                    injected = true;
                    replacedPath = child;
                    stagingRoot = FindArchiveStagingRoot(child);
                    Directory.Move(child, detachedOwned);
                    Directory.Move(foreign, child);
                });
            _ = ToolchainRuntimeArchive.Execute(request);
        }
        catch (Exception exception)
        {
            failure = exception;
        }
        finally
        {
            if (replacedPath is not null && Directory.Exists(replacedPath) && !Directory.Exists(foreign))
                Directory.Move(replacedPath, foreign);
            if (replacedPath is not null && Directory.Exists(detachedOwned))
            {
                if (stagingRoot is not null && Directory.Exists(stagingRoot))
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(replacedPath)!);
                    Directory.Move(detachedOwned, replacedPath);
                }
                else
                    Directory.Delete(detachedOwned, recursive: true);
            }
            DeleteVerifiedArchiveStagingRoot(stagingRoot);
        }

        ContractAssert.Require(injected, "archive cleanup replacement seam was not reached");
        ContractAssert.Require(File.Exists(foreignSentinel),
            "archive cleanup deleted a foreign replacement sentinel");
        ContractAssert.Require(failure is ToolchainRuntimeArchiveException,
            "archive cleanup accepted a same-path foreign directory replacement");
        ContractAssert.Require(!Directory.Exists(output) && !Directory.Exists(extract),
            "archive cleanup replacement failure advanced output/extract identity");
    }

    private static void VerifyOwnedCleanupRejectsFileReplacement(
        ContractSandbox sandbox,
        RuntimePackageFixture fixture)
    {
        if (!OperatingSystem.IsWindows()) return;

        var root = sandbox.NewCase("archive-owned-cleanup-file-replacement");
        var output = Path.Combine(root, "output");
        var extract = Path.Combine(root, "extract");
        var foreign = Path.Combine(root, "foreign-replacement.bin");
        var foreignBytes = new byte[] { 0xde, 0xad, 0xbe, 0xef };
        var detachedOwned = Path.Combine(root, "detached-owned-file");
        File.WriteAllBytes(foreign, foreignBytes);

        string? replacedPath = null;
        string? stagingRoot = null;
        var injected = false;
        Exception? failure = null;
        try
        {
            var request = fixture.Request(
                fixture.PackageRoot,
                output,
                extract,
                afterOwnedCleanupEntryClassifiedForTesting: child =>
                {
                    if (injected || !File.Exists(child)) return;
                    injected = true;
                    replacedPath = child;
                    stagingRoot = FindArchiveStagingRoot(child);
                    File.Move(child, detachedOwned);
                    File.Move(foreign, child);
                });
            _ = ToolchainRuntimeArchive.Execute(request);
        }
        catch (Exception exception)
        {
            failure = exception;
        }
        finally
        {
            if (replacedPath is not null && File.Exists(replacedPath) && !File.Exists(foreign))
                File.Move(replacedPath, foreign);
            if (replacedPath is not null && File.Exists(detachedOwned))
            {
                if (stagingRoot is not null && Directory.Exists(stagingRoot))
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(replacedPath)!);
                    File.Move(detachedOwned, replacedPath);
                }
                else
                    File.Delete(detachedOwned);
            }
            DeleteVerifiedArchiveStagingRoot(stagingRoot);
        }

        ContractAssert.Require(injected, "archive file cleanup replacement seam was not reached");
        ContractAssert.Require(File.Exists(foreign) && File.ReadAllBytes(foreign).AsSpan().SequenceEqual(foreignBytes),
            "archive cleanup deleted a foreign file replacement");
        ContractAssert.Require(failure is ToolchainRuntimeArchiveException,
            "archive cleanup accepted a same-path foreign file replacement");
        ContractAssert.Require(!Directory.Exists(output) && !Directory.Exists(extract),
            "archive file cleanup replacement failure advanced output/extract identity");
    }

    private static void VerifyOwnedCleanupRejectsJunctionReplacement(
        ContractSandbox sandbox,
        RuntimePackageFixture fixture)
    {
        if (!OperatingSystem.IsWindows()) return;

        var root = sandbox.NewCase("archive-owned-cleanup-junction-replacement");
        var output = Path.Combine(root, "output");
        var extract = Path.Combine(root, "extract");
        var external = Path.Combine(root, "external-target");
        var externalSentinel = Path.Combine(external, "external.sentinel");
        var detachedOwned = Path.Combine(root, "detached-owned-child");
        Directory.CreateDirectory(external);
        File.WriteAllText(externalSentinel, "junction target must survive archive cleanup", Encoding.UTF8);

        string? replacedPath = null;
        string? stagingRoot = null;
        IDisposable? junction = null;
        var injected = false;
        Exception? failure = null;
        try
        {
            var request = fixture.Request(
                fixture.PackageRoot,
                output,
                extract,
                afterOwnedCleanupEntryClassifiedForTesting: child =>
                {
                    if (injected || !Directory.Exists(child)) return;
                    injected = true;
                    replacedPath = child;
                    stagingRoot = FindArchiveStagingRoot(child);
                    Directory.Move(child, detachedOwned);
                    junction = VerifierJunction.CreateDirectoryAlias(child, external);
                });
            _ = ToolchainRuntimeArchive.Execute(request);
        }
        catch (Exception exception)
        {
            failure = exception;
        }
        finally
        {
            junction?.Dispose();
            if (replacedPath is not null && Directory.Exists(detachedOwned))
            {
                if (stagingRoot is not null && Directory.Exists(stagingRoot))
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(replacedPath)!);
                    Directory.Move(detachedOwned, replacedPath);
                }
                else
                    Directory.Delete(detachedOwned, recursive: true);
            }
            DeleteVerifiedArchiveStagingRoot(stagingRoot);
        }

        ContractAssert.Require(injected, "archive junction cleanup replacement seam was not reached");
        ContractAssert.Require(File.Exists(externalSentinel),
            "archive cleanup traversed a junction into an external target");
        ContractAssert.Require(failure is ToolchainRuntimeArchiveException,
            "archive cleanup accepted a junction replacement");
        ContractAssert.Require(!Directory.Exists(output) && !Directory.Exists(extract),
            "archive junction cleanup replacement failure advanced output/extract identity");
    }

    private static string FindArchiveStagingRoot(string path)
    {
        var expectedParent = Path.GetFullPath(Path.GetTempPath()).TrimEnd(Path.DirectorySeparatorChar);
        var current = new DirectoryInfo(Path.GetFullPath(path));
        while (current.Parent is not null)
        {
            if (current.Parent.FullName.TrimEnd(Path.DirectorySeparatorChar)
                    .Equals(expectedParent, StringComparison.OrdinalIgnoreCase) &&
                current.Name.StartsWith("kadath-runtime-archive-", StringComparison.Ordinal))
                return current.FullName;
            current = current.Parent;
        }
        throw new InvalidOperationException($"Archive cleanup fixture did not find a controlled staging root: {path}");
    }

    private static void DeleteVerifiedArchiveStagingRoot(string? stagingRoot)
    {
        if (stagingRoot is null || !Directory.Exists(stagingRoot)) return;
        var expectedParent = Path.GetFullPath(Path.GetTempPath()).TrimEnd(Path.DirectorySeparatorChar);
        var actualParent = Path.GetDirectoryName(stagingRoot)?.TrimEnd(Path.DirectorySeparatorChar);
        ContractAssert.Require(
            actualParent is not null && actualParent.Equals(expectedParent, StringComparison.OrdinalIgnoreCase) &&
            Path.GetFileName(stagingRoot).StartsWith("kadath-runtime-archive-", StringComparison.Ordinal),
            "archive cleanup fixture refused to remove an unexpected staging path");
        Directory.Delete(stagingRoot, recursive: true);
    }

    private static async Task VerifyRetainedHandleMutationAsync(ContractSandbox sandbox, RuntimePackageFixture fixture)
    {
        var root = sandbox.NewCase("archive-retained-mutation");
        var package = fixture.ClonePackage(root);
        var output = Path.Combine(root, "output");
        var extract = Path.Combine(root, "extract");
        var barrier = Path.Combine(root, "barrier");
        Directory.CreateDirectory(barrier);
        var request = fixture.Request(package, output, extract, barrier);
        var archiveTask = Task.Run(() => ToolchainRuntimeArchive.Execute(request));
        var ready = Path.Combine(barrier, "snapshot-ready");
        var release = Path.Combine(barrier, "continue");
        ToolchainRuntimeArchiveResult? result = null;
        Exception? failure = null;
        var mutationSucceeded = false;
        try
        {
            await WaitForReadyAsync(ready, archiveTask).ConfigureAwait(false);
            mutationSucceeded |= TryMutation(() =>
            {
                using var stream = new FileStream(
                    Path.Combine(package, "bin", "assets", "renderer2d", "goal.texture"),
                    FileMode.Open,
                    FileAccess.Write,
                    FileShare.ReadWrite | FileShare.Delete);
                stream.WriteByte(0xff);
                stream.Flush(flushToDisk: true);
            });
            mutationSucceeded |= TryMutation(() => File.Move(
                Path.Combine(package, "bin", "assets", "renderer2d", "test.texture"),
                Path.Combine(root, "renamed-test.texture")));
            var replacement = Path.Combine(root, "replacement-goal.png");
            File.WriteAllBytes(replacement, [0xde, 0xad, 0xbe, 0xef]);
            mutationSucceeded |= TryMutation(() => File.Move(
                replacement,
                Path.Combine(package, "bin", "assets", "renderer2d", "goal.png"),
                overwrite: true));
            if (File.Exists(replacement)) File.Delete(replacement);
        }
        finally
        {
            if (File.Exists(ready) && !File.Exists(release))
            {
                using var stream = new FileStream(release, FileMode.CreateNew, FileAccess.Write, FileShare.Read);
                stream.Flush(flushToDisk: true);
            }
            try { result = await archiveTask.WaitAsync(TimeSpan.FromSeconds(15)).ConfigureAwait(false); }
            catch (Exception exception) { failure = exception; }
        }

        if (mutationSucceeded)
        {
            ContractAssert.Require(failure is not null && !Directory.Exists(output) && !Directory.Exists(extract),
                "a successful retained-handle mutation was not caught with bounded rollback");
        }
        else
        {
            ContractAssert.Require(failure is null && result is { FileCount: 18 } && Directory.Exists(output) && Directory.Exists(extract),
                $"sharing-denied mutation path did not complete a valid archive: {failure}");
        }
    }

    private static async Task WaitForReadyAsync(string readyPath, Task archiveTask)
    {
        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(5);
        while (!File.Exists(readyPath))
        {
            if (archiveTask.IsCompleted)
            {
                await archiveTask.ConfigureAwait(false);
                throw new InvalidOperationException("archive completed without publishing its retained-handle barrier");
            }
            if (DateTime.UtcNow >= deadline) throw new TimeoutException("timed out waiting for retained-handle barrier");
            await Task.Delay(20).ConfigureAwait(false);
        }
    }

    private static bool TryMutation(Action action)
    {
        try
        {
            action();
            return true;
        }
        catch (IOException) { return false; }
        catch (UnauthorizedAccessException) { return false; }
    }

    private static SortedDictionary<string, string> ReadManifest(string path)
    {
        var map = new SortedDictionary<string, string>(StringComparer.Ordinal);
        foreach (var line in File.ReadAllLines(path, new UTF8Encoding(false, true)))
        {
            ContractAssert.Require(line.Length >= 67 && line[64..66] == "  ", $"invalid manifest line: {line}");
            var hash = line[..64];
            var relative = line[66..];
            ContractAssert.Require(hash.Length == 64 && hash.All(character => character is >= '0' and <= '9' or >= 'a' and <= 'f'),
                $"invalid manifest hash: {hash}");
            map.Add(relative, hash);
        }
        ContractAssert.Require(map.Keys.SequenceEqual(RuntimePackageFixture.ExactV2Files, StringComparer.Ordinal),
            "manifest paths are not strict exact-18");
        return map;
    }

    private static SortedDictionary<string, string> ReadZip(string path)
    {
        var map = new SortedDictionary<string, string>(StringComparer.Ordinal);
        using var archive = ZipFile.OpenRead(path);
        foreach (var entry in archive.Entries)
        {
            ContractAssert.Require(!string.IsNullOrEmpty(entry.Name), $"ZIP contains a directory entry: {entry.FullName}");
            using var stream = entry.Open();
            map.Add(entry.FullName.Replace('\\', '/'), Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant());
        }
        return map;
    }
}
