using System.Diagnostics;
using System.IO.Compression;
using System.Runtime.ExceptionServices;
using System.Security.Cryptography;
using System.Text;
using Kadath.Editor.Workspace;

namespace Kadath.Editor.Toolchain;

internal enum ToolchainRuntimePackagePolicy
{
    KscpV1 = 1,
    KscpV2 = 2
}

internal sealed record ToolchainRuntimeArchiveRequest(
    string PackageRoot,
    string OutputDirectory,
    string ExtractDirectory,
    string KadathRoot,
    ToolchainRuntimePackagePolicy Policy,
    string? VerificationBarrierDirectory = null,
    Action<string>? AfterOwnedCleanupEntryClassifiedForTesting = null,
    Action<string>? AfterPackageSnapshotCreatedForTesting = null);

internal sealed record ToolchainRuntimeArchiveResult(
    string ArchivePath,
    string ManifestPath,
    string ExtractDirectory,
    int FileCount,
    string ArchiveSha256);

internal sealed class ToolchainRuntimeArchiveException : Exception
{
    internal ToolchainRuntimeArchiveException(bool archiveWriteStarted, Exception cause)
        : base(cause.Message, cause) => ArchiveWriteStarted = archiveWriteStarted;

    internal bool ArchiveWriteStarted { get; }
}

internal static class ToolchainRuntimeArchive
{
    private static readonly UTF8Encoding StrictUtf8 = new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);
    private static readonly TimeSpan BarrierTimeout = TimeSpan.FromSeconds(10);
    private static readonly string[] KscpV1Files =
    [
        "bin/kadath.exe",
        "bin/kadath-runtime-build-profile.json",
        "bin/assets/renderer2d/goal.png",
        "bin/assets/renderer2d/goal.texture",
        "bin/assets/renderer2d/test.png",
        "bin/assets/renderer2d/test.texture",
        "bin/assets/audio/won.wav",
        "bin/assets/audio/lost.wav",
        "bin/assets/audio/won.audio.wav",
        "bin/assets/audio/lost.audio.wav",
        "bin/assets/scenes/preview.scene",
        "bin/assets/scenes/preview.scene.json",
        "bin/assets/scripts/preview.script",
        "bin/assets/scripts/preview.script.json",
        "README.txt"
    ];
    private static readonly string[] KscpV2AdditionalFiles =
    [
        "behavior-tools/kadath-behavior-tool.exe",
        "bin/assets/scripts/patrol.luau",
        "bin/assets/scripts/player_controller.luau"
    ];

    internal static ToolchainRuntimeArchiveResult Execute(ToolchainRuntimeArchiveRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        var archiveWriteStarted = false;
        WindowsOwnedDirectory? stagingOwner = null;
        WindowsOwnedDirectory? outputOwner = null;
        WindowsOwnedDirectory? extractOwner = null;
        RetainedPackageSnapshot? sourceSnapshot = null;

        try
        {
            var requiredFiles = GetRequiredFiles(request.Policy);
            var package = ToolchainPathPolicy.ResolveExistingDirectory(request.PackageRoot, "Package root");
            var output = ToolchainPathPolicy.CanonicalAbsoluteLocalPath(request.OutputDirectory, "Output directory", requireCanonicalSpelling: false);
            var extract = ToolchainPathPolicy.CanonicalAbsoluteLocalPath(request.ExtractDirectory, "Extract directory", requireCanonicalSpelling: false);
            var kadathRoot = ToolchainPathPolicy.ResolveExistingDirectory(request.KadathRoot, "Kadath root");
            var barrier = ResolveBarrier(request.VerificationBarrierDirectory);

            ValidateTransactionPaths(package, output, extract, kadathRoot, barrier);
            var buildDefinitionPath = ToolchainPathPolicy.ResolveExistingFile(Path.Combine(kadathRoot, "build.zig"), "Kadath build definition");
            _ = buildDefinitionPath;
            var vertexShaderPath = ToolchainPathPolicy.ResolveExistingFile(
                Path.Combine(kadathRoot, "shaders", "renderer2d", "quad.vert.glsl"),
                "Vertex shader source");
            var fragmentShaderPath = ToolchainPathPolicy.ResolveExistingFile(
                Path.Combine(kadathRoot, "shaders", "renderer2d", "quad.frag.glsl"),
                "Fragment shader source");
            var vertexShaderSha256 = HashFile(vertexShaderPath);
            var fragmentShaderSha256 = HashFile(fragmentShaderPath);

            var stagingParent = ToolchainPathPolicy.ResolveExistingDirectory(
                Path.GetFullPath(Path.GetTempPath()),
                "Package snapshot parent");
            var staging = Path.GetFullPath(Path.Combine(stagingParent, $"kadath-runtime-archive-{Guid.NewGuid():N}"));
            ToolchainPathPolicy.RejectReparsePointInExistingPath(staging, "Package snapshot");
            ToolchainPathPolicy.EnsureDisjoint(package, "Package root", staging, "Package snapshot");
            ToolchainPathPolicy.EnsureDisjoint(output, "Output directory", staging, "Package snapshot");
            ToolchainPathPolicy.EnsureDisjoint(extract, "Extract directory", staging, "Package snapshot");
            if (barrier is not null)
                ToolchainPathPolicy.EnsureDisjoint(barrier, "Verification barrier directory", staging, "Package snapshot");

            // 首次产品写入前冻结全文件集，并仅从 retained handles 读取 marker 与 payload。
            sourceSnapshot = RetainedPackageSnapshot.Open(package);
            AssertReleasePackageSnapshotIdentity(
                sourceSnapshot,
                requiredFiles,
                request.Policy,
                vertexShaderSha256,
                fragmentShaderSha256);
            if (barrier is not null) WaitAtBarrier(barrier, sourceSnapshot, package);

            stagingOwner = CreateOwnedRoot(staging, "Package snapshot", () => archiveWriteStarted = true);
            Exception? copyFailure = null;
            try { sourceSnapshot.CopyTo(stagingOwner); }
            catch (Exception exception) { copyFailure = exception; }
            Exception? closeFailure = null;
            try { sourceSnapshot.CloseStreams(); }
            catch (Exception exception) { closeFailure = exception; }
            if (copyFailure is not null && closeFailure is not null)
                throw new AggregateException(
                    "Package snapshot copy failed and retained source handles could not all be released.",
                    copyFailure,
                    closeFailure);
            if (copyFailure is not null) ExceptionDispatchInfo.Capture(copyFailure).Throw();
            if (closeFailure is not null) ExceptionDispatchInfo.Capture(closeFailure).Throw();
            request.AfterPackageSnapshotCreatedForTesting?.Invoke(staging);

            AssertReleasePackageDirectoryIdentity(
                staging,
                requiredFiles,
                request.Policy,
                vertexShaderSha256,
                fragmentShaderSha256);

            outputOwner = CreateOwnedRoot(output, "Output directory");
            var archivePath = Path.Combine(output, "kadath-runtime-win-x64.zip");
            var manifestPath = Path.Combine(output, "manifest.sha256");
            var stagingFiles = EnumeratePackageFileSet(staging);
            var manifest = BuildManifest(stagingFiles);
            WriteOwnedFile(outputOwner, "manifest.sha256", manifest.Bytes);
            WriteDeterministicArchive(outputOwner, "kadath-runtime-win-x64.zip", stagingFiles);
            ValidateArchiveEntries(archivePath, manifest.HashByRelativePath);

            extractOwner = CreateOwnedRoot(extract, "Extract directory");
            ExtractArchiveToOwnedDirectory(archivePath, extractOwner);
            ToolchainPathPolicy.RejectReparsePointInExistingPath(extract, "Extract directory");
            RejectReparseEntries(extract, "Extracted archive");
            var persistedManifest = ReadManifest(manifestPath);
            AssertExtractedIdentity(extract, persistedManifest);
            AssertReleasePackageDirectoryIdentity(
                extract,
                requiredFiles,
                request.Policy,
                vertexShaderSha256,
                fragmentShaderSha256);

            // 终验 live package 与 shader，证明归档事务未推进漂移后的身份。
            sourceSnapshot.AssertStable(package);
            if (HashFile(vertexShaderPath) != vertexShaderSha256 || HashFile(fragmentShaderPath) != fragmentShaderSha256)
                throw new InvalidDataException("Shader source identity changed during archive transaction.");
            AssertReleasePackageDirectoryIdentity(
                package,
                requiredFiles,
                request.Policy,
                vertexShaderSha256,
                fragmentShaderSha256);

            var archiveSha256 = HashFile(archivePath);
            RemoveOwnedDirectory(
                stagingOwner,
                "Package snapshot",
                request.AfterOwnedCleanupEntryClassifiedForTesting);
            stagingOwner = null;
            // 成功发布前固定最终树身份；未知 extra 或 replacement 不能被静默纳入产品结果。
            outputOwner.VerifyClaimedTree();
            extractOwner.VerifyClaimedTree();
            outputOwner.Release();
            outputOwner = null;
            extractOwner.Release();
            extractOwner = null;
            return new ToolchainRuntimeArchiveResult(
                archivePath,
                manifestPath,
                extract,
                persistedManifest.Count,
                archiveSha256);
        }
        catch (Exception primaryFailure)
        {
            var cleanupFailures = new List<Exception>();
            if (sourceSnapshot is not null)
            {
                try { sourceSnapshot.CloseStreams(); }
                catch (Exception cleanup) { cleanupFailures.Add(cleanup); }
            }
            CleanupOwnedRoot(extractOwner, "Extract directory", cleanupFailures);
            CleanupOwnedRoot(outputOwner, "Output directory", cleanupFailures);
            CleanupOwnedRoot(stagingOwner, "Package snapshot", cleanupFailures);
            var cause = cleanupFailures.Count == 0
                ? primaryFailure
                : new AggregateException(
                    "Archive failed and one or more owned roots could not be cleaned.",
                    new[] { primaryFailure }.Concat(cleanupFailures));
            throw new ToolchainRuntimeArchiveException(archiveWriteStarted, cause);
        }
    }

    internal static int Run(
        ToolchainRuntimeArchiveRequest request,
        TextWriter standardOutput,
        TextWriter standardError)
    {
        try
        {
            var result = Execute(request);
            standardOutput.WriteLine($"archive={result.ArchivePath}");
            standardOutput.WriteLine($"manifest={result.ManifestPath}");
            standardOutput.WriteLine($"extract={result.ExtractDirectory}");
            standardOutput.WriteLine($"files={result.FileCount}");
            standardOutput.WriteLine($"archive_sha256={result.ArchiveSha256}");
            standardOutput.WriteLine("verification=ok");
            return 0;
        }
        catch (ToolchainRuntimeArchiveException exception)
        {
            if (!exception.ArchiveWriteStarted) standardError.WriteLine("archive_write_started=false");
            standardError.WriteLine($"archive_error={exception.InnerException?.GetType().Name ?? exception.GetType().Name}: {exception.Message}");
            return 1;
        }
    }

    private static IReadOnlyList<string> GetRequiredFiles(ToolchainRuntimePackagePolicy policy)
    {
        IEnumerable<string> files = policy switch
        {
            ToolchainRuntimePackagePolicy.KscpV1 => KscpV1Files,
            ToolchainRuntimePackagePolicy.KscpV2 => KscpV1Files.Concat(KscpV2AdditionalFiles),
            _ => throw new ArgumentOutOfRangeException(nameof(policy), policy, "Unsupported KSCP runtime package policy.")
        };
        var result = files.OrderBy(path => path, StringComparer.Ordinal).ToArray();
        if (result.Distinct(StringComparer.OrdinalIgnoreCase).Count() != result.Length)
            throw new InvalidOperationException("Runtime package policy contains a duplicate path.");
        return result;
    }

    private static void ValidateTransactionPaths(
        string package,
        string output,
        string extract,
        string kadathRoot,
        string? barrier)
    {
        ToolchainPathPolicy.RejectReparsePointInExistingPath(output, "Output directory");
        ToolchainPathPolicy.RejectReparsePointInExistingPath(extract, "Extract directory");
        ToolchainPathPolicy.EnsureDisjoint(package, "Package root", output, "Output directory");
        ToolchainPathPolicy.EnsureDisjoint(package, "Package root", extract, "Extract directory");
        ToolchainPathPolicy.EnsureDisjoint(output, "Output directory", extract, "Extract directory");
        if (barrier is not null)
        {
            ToolchainPathPolicy.EnsureDisjoint(package, "Package root", barrier, "Verification barrier directory");
            ToolchainPathPolicy.EnsureDisjoint(output, "Output directory", barrier, "Verification barrier directory");
            ToolchainPathPolicy.EnsureDisjoint(extract, "Extract directory", barrier, "Verification barrier directory");
            ToolchainPathPolicy.EnsureDisjoint(kadathRoot, "Kadath root", barrier, "Verification barrier directory");
        }
        if (File.Exists(output) || Directory.Exists(output))
            throw new IOException($"Output directory already exists; refusing to overwrite: {output}");
        if (File.Exists(extract) || Directory.Exists(extract))
            throw new IOException($"Extract directory already exists; refusing to overwrite: {extract}");
        EnsureExistingParent(output, "Output directory parent");
        EnsureExistingParent(extract, "Extract directory parent");
        RejectReparseEntries(package, "Package tree");
    }

    private static string? ResolveBarrier(string? barrierDirectory)
    {
        if (string.IsNullOrWhiteSpace(barrierDirectory) || barrierDirectory.Equals("-", StringComparison.Ordinal)) return null;
        var barrier = ToolchainPathPolicy.ResolveExistingDirectory(barrierDirectory, "Verification barrier directory");
        if (Directory.EnumerateFileSystemEntries(barrier).Any())
            throw new IOException("Verification barrier directory must be empty.");
        return barrier;
    }

    private static void WaitAtBarrier(string barrier, RetainedPackageSnapshot snapshot, string packageRoot)
    {
        var readyPath = Path.Combine(barrier, "snapshot-ready");
        var continuePath = Path.Combine(barrier, "continue");
        if (File.Exists(readyPath) || Directory.Exists(readyPath) || File.Exists(continuePath) || Directory.Exists(continuePath))
            throw new IOException("Verification barrier contains a pre-existing control path.");
        ToolchainDurableFile.WriteNew(readyPath, ReadOnlySpan<byte>.Empty);
        var stopwatch = Stopwatch.StartNew();
        while (!File.Exists(continuePath))
        {
            if (Directory.Exists(continuePath))
                throw new IOException("Archive verification barrier continue signal must be a regular file.");
            if (stopwatch.Elapsed >= BarrierTimeout)
                throw new TimeoutException("Timed out waiting for archive verification barrier continue signal.");
            Thread.Sleep(25);
        }
        ToolchainPathPolicy.RejectReparsePointInExistingPath(barrier, "Verification barrier before continue");
        var attributes = File.GetAttributes(continuePath);
        if ((attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0 || new FileInfo(continuePath).Length != 0)
            throw new IOException("Archive verification barrier continue signal must be an empty non-reparse file.");
        snapshot.AssertStable(packageRoot);
    }

    private static WindowsOwnedDirectory CreateOwnedRoot(string path, string name, Action? beforeCreate = null)
    {
        var parent = Path.GetDirectoryName(path) ?? throw new IOException($"{name} has no parent directory.");
        ToolchainPathPolicy.ResolveExistingDirectory(parent, $"{name} parent");
        if (File.Exists(path) || Directory.Exists(path)) throw new IOException($"{name} appeared before owned create: {path}");
        beforeCreate?.Invoke();
        var owner = WindowsFileIdentityAdapter.CreateOwnedDirectory(path);
        try
        {
            owner.VerifyPath();
            return owner;
        }
        catch
        {
            owner.Release();
            throw;
        }
    }

    private static void AssertReleasePackageSnapshotIdentity(
        RetainedPackageSnapshot snapshot,
        IReadOnlyList<string> requiredFiles,
        ToolchainRuntimePackagePolicy policy,
        string vertexShaderSha256,
        string fragmentShaderSha256)
    {
        AssertExactFileSet(snapshot.Files.Select(file => file.RelativePath), requiredFiles, "Package snapshot");
        ToolchainBuildProfile.AssertReleaseIdentity(
            snapshot.ReadBytes("bin/kadath-runtime-build-profile.json"),
            snapshot.Identity("bin/kadath.exe").Sha256,
            snapshot.Identity("bin/assets/renderer2d/test.png").Sha256,
            snapshot.Identity("bin/assets/renderer2d/test.texture").Sha256,
            snapshot.Identity("bin/assets/renderer2d/goal.png").Sha256,
            snapshot.Identity("bin/assets/renderer2d/goal.texture").Sha256,
            vertexShaderSha256,
            fragmentShaderSha256);
        AssertScriptArtifactPolicy(snapshot.ReadBytes("bin/assets/scripts/preview.script"), policy);
    }

    private static void AssertReleasePackageDirectoryIdentity(
        string root,
        IReadOnlyList<string> requiredFiles,
        ToolchainRuntimePackagePolicy policy,
        string vertexShaderSha256,
        string fragmentShaderSha256)
    {
        var files = EnumeratePackageFileSet(root);
        AssertExactFileSet(files.Select(file => file.RelativePath), requiredFiles, "Runtime package");
        var byRelative = files.ToDictionary(file => file.RelativePath, StringComparer.OrdinalIgnoreCase);
        byte[] Read(string relative) => ReadFrozenBytes(byRelative[relative].FullPath);
        string Hash(string relative) => HashFile(byRelative[relative].FullPath);
        ToolchainBuildProfile.AssertReleaseIdentity(
            Read("bin/kadath-runtime-build-profile.json"),
            Hash("bin/kadath.exe"),
            Hash("bin/assets/renderer2d/test.png"),
            Hash("bin/assets/renderer2d/test.texture"),
            Hash("bin/assets/renderer2d/goal.png"),
            Hash("bin/assets/renderer2d/goal.texture"),
            vertexShaderSha256,
            fragmentShaderSha256);
        AssertScriptArtifactPolicy(Read("bin/assets/scripts/preview.script"), policy);
    }

    private static void AssertScriptArtifactPolicy(byte[] artifact, ToolchainRuntimePackagePolicy policy)
    {
        var info = WorkspaceScriptCodec.ValidateArtifact(artifact);
        var expectedFormat = policy switch
        {
            ToolchainRuntimePackagePolicy.KscpV1 => WorkspaceScriptCodec.LegacyFormat,
            ToolchainRuntimePackagePolicy.KscpV2 => WorkspaceScriptCodec.BehaviorFormat,
            _ => throw new ArgumentOutOfRangeException(nameof(policy), policy, "Unsupported KSCP runtime package policy.")
        };
        if (!info.Format.Equals(expectedFormat, StringComparison.Ordinal))
            throw new InvalidDataException($"Runtime package {policy} requires Script artifact format {expectedFormat}, got {info.Format}.");
    }

    private static void AssertExactFileSet(
        IEnumerable<string> actualPaths,
        IReadOnlyList<string> expectedPaths,
        string name)
    {
        var actual = actualPaths.OrderBy(path => path, StringComparer.Ordinal).ToArray();
        if (!actual.SequenceEqual(expectedPaths, StringComparer.Ordinal))
        {
            var expected = new HashSet<string>(expectedPaths, StringComparer.OrdinalIgnoreCase);
            var actualSet = new HashSet<string>(actual, StringComparer.OrdinalIgnoreCase);
            var missing = expected.Where(path => !actualSet.Contains(path)).OrderBy(path => path, StringComparer.Ordinal).ToArray();
            var extra = actualSet.Where(path => !expected.Contains(path)).OrderBy(path => path, StringComparer.Ordinal).ToArray();
            throw new InvalidDataException(
                $"{name} must contain exactly {expectedPaths.Count} policy files; missing=[{string.Join(",", missing)}], extra=[{string.Join(",", extra)}].");
        }
    }

    private static ManifestIdentity BuildManifest(IReadOnlyList<PackageFileEntry> files)
    {
        var map = new SortedDictionary<string, string>(StringComparer.Ordinal);
        foreach (var file in files) map.Add(file.RelativePath, HashFile(file.FullPath));
        var text = string.Concat(map.Select(entry => $"{entry.Value}  {entry.Key}\n"));
        return new ManifestIdentity(StrictUtf8.GetBytes(text), map);
    }

    private static void WriteOwnedFile(WindowsOwnedDirectory owner, string relativePath, ReadOnlySpan<byte> bytes)
    {
        using var file = owner.CreateFile(relativePath);
        file.Stream.Write(bytes);
        file.Stream.Flush(flushToDisk: true);
    }

    private static void WriteDeterministicArchive(
        WindowsOwnedDirectory owner,
        string relativePath,
        IReadOnlyList<PackageFileEntry> files)
    {
        using var ownedArchive = owner.CreateFile(relativePath);
        using (var archive = new ZipArchive(ownedArchive.Stream, ZipArchiveMode.Create, leaveOpen: true))
        {
            foreach (var file in files.OrderBy(file => file.RelativePath, StringComparer.Ordinal))
            {
                var entry = archive.CreateEntry(file.RelativePath, CompressionLevel.Optimal);
                entry.LastWriteTime = new DateTimeOffset(1980, 1, 1, 0, 0, 0, TimeSpan.Zero);
                using var input = WindowsFileIdentityAdapter.OpenFrozenRead(file.FullPath);
                using var output = entry.Open();
                input.CopyTo(output);
            }
        }
        ownedArchive.Stream.Flush(flushToDisk: true);
    }

    private static void ExtractArchiveToOwnedDirectory(string archivePath, WindowsOwnedDirectory owner)
    {
        using var archive = ZipFile.OpenRead(archivePath);
        foreach (var entry in archive.Entries)
        {
            if (string.IsNullOrEmpty(entry.Name))
                throw new InvalidDataException($"Archive contains a directory entry: {entry.FullName}");
            var relative = NormalizeArchiveRelativePath(entry.FullName);
            using var output = owner.CreateFile(relative);
            using var input = entry.Open();
            input.CopyTo(output.Stream);
            output.Stream.Flush(flushToDisk: true);
        }
    }

    private static void ValidateArchiveEntries(string archivePath, IReadOnlyDictionary<string, string> expected)
    {
        using var archive = ZipFile.OpenRead(archivePath);
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var actualOrder = new List<string>();
        foreach (var entry in archive.Entries)
        {
            if (string.IsNullOrEmpty(entry.Name)) throw new InvalidDataException($"Archive contains a directory entry: {entry.FullName}");
            var relative = NormalizeArchiveRelativePath(entry.FullName);
            if (!seen.Add(relative)) throw new InvalidDataException($"Archive contains a duplicate entry: {relative}");
            actualOrder.Add(relative);
            if (!expected.TryGetValue(relative, out var expectedHash))
                throw new InvalidDataException($"Archive contains an unexpected entry: {relative}");
            using var input = entry.Open();
            var actualHash = Convert.ToHexString(SHA256.HashData(input)).ToLowerInvariant();
            if (actualHash != expectedHash) throw new InvalidDataException($"Archive entry hash mismatch: {relative}");
        }
        if (!actualOrder.SequenceEqual(expected.Keys, StringComparer.Ordinal))
            throw new InvalidDataException("Archive entry order or file set does not match the manifest.");
    }

    private static IReadOnlyDictionary<string, string> ReadManifest(string manifestPath)
    {
        var bytes = ReadFrozenBytes(manifestPath);
        string text;
        try { text = StrictUtf8.GetString(bytes); }
        catch (DecoderFallbackException exception) { throw new InvalidDataException("Archive manifest is not strict UTF-8.", exception); }
        if (!text.EndsWith('\n')) throw new InvalidDataException("Archive manifest must end with a newline.");
        var lines = text[..^1].Split('\n', StringSplitOptions.None);
        var map = new SortedDictionary<string, string>(StringComparer.Ordinal);
        string? previous = null;
        foreach (var line in lines)
        {
            if (line.Length < 67 || line[64..66] != "  ") throw new InvalidDataException($"Invalid manifest line: {line}");
            var hash = line[..64];
            var relative = NormalizeArchiveRelativePath(line[66..]);
            if (!IsLowerSha256(hash)) throw new InvalidDataException($"Invalid manifest SHA-256: {hash}");
            if (previous is not null && StringComparer.Ordinal.Compare(previous, relative) >= 0)
                throw new InvalidDataException("Archive manifest paths must be unique and strictly sorted.");
            map.Add(relative, hash);
            previous = relative;
        }
        return map;
    }

    private static void AssertExtractedIdentity(string extractRoot, IReadOnlyDictionary<string, string> expected)
    {
        var files = EnumeratePackageFileSet(extractRoot);
        if (files.Count != expected.Count) throw new InvalidDataException($"Archive file count mismatch: expected={expected.Count}, extracted={files.Count}");
        foreach (var file in files)
        {
            if (!expected.TryGetValue(file.RelativePath, out var hash))
                throw new InvalidDataException($"Archive contains an unexpected extracted file: {file.RelativePath}");
            if (HashFile(file.FullPath) != hash)
                throw new InvalidDataException($"Archive hash mismatch: {file.RelativePath}");
        }
    }

    private static IReadOnlyList<PackageFileEntry> EnumeratePackageFileSet(string root)
    {
        ToolchainPathPolicy.RejectReparsePointInExistingPath(root, "Package file-set root");
        var files = new List<PackageFileEntry>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var pending = new Stack<string>();
        pending.Push(root);
        while (pending.Count != 0)
        {
            var directory = pending.Pop();
            foreach (var path in Directory.EnumerateFileSystemEntries(directory))
            {
                var attributes = File.GetAttributes(path);
                if ((attributes & FileAttributes.ReparsePoint) != 0)
                    throw new InvalidDataException($"Package tree cannot contain a reparse point: {path}");
                if ((attributes & FileAttributes.Directory) != 0)
                {
                    pending.Push(path);
                    continue;
                }
                var relative = NormalizeRelativePath(root, path);
                if (!seen.Add(relative)) throw new InvalidDataException($"Package snapshot contains a duplicate relative path: {relative}");
                files.Add(new PackageFileEntry(relative, path));
            }
        }
        if (files.Count == 0) throw new InvalidDataException($"Package root contains no files: {root}");
        return files.OrderBy(file => file.RelativePath, StringComparer.Ordinal).ToArray();
    }

    private static void RejectReparseEntries(string root, string name)
    {
        var pending = new Stack<string>();
        pending.Push(root);
        while (pending.Count != 0)
        {
            foreach (var path in Directory.EnumerateFileSystemEntries(pending.Pop()))
            {
                var attributes = File.GetAttributes(path);
                if ((attributes & FileAttributes.ReparsePoint) != 0)
                    throw new InvalidDataException($"{name} cannot contain a reparse point: {path}");
                if ((attributes & FileAttributes.Directory) != 0) pending.Push(path);
            }
        }
    }

    private static string NormalizeRelativePath(string root, string path)
    {
        var relative = Path.GetRelativePath(root, path).Replace('\\', '/');
        if (Path.IsPathFullyQualified(relative) || relative == ".." || relative.StartsWith("../", StringComparison.Ordinal))
            throw new InvalidDataException($"Package path escapes its root: {relative}");
        return relative;
    }

    private static string NormalizeArchiveRelativePath(string path)
    {
        var relative = path.Replace('\\', '/');
        if (string.IsNullOrWhiteSpace(relative) || Path.IsPathFullyQualified(relative) || relative.StartsWith("/", StringComparison.Ordinal) ||
            relative.Split('/').Any(segment => segment is "" or "." or ".."))
            throw new InvalidDataException($"Archive path escapes its root: {path}");
        return relative;
    }

    private static void RemoveOwnedDirectory(
        WindowsOwnedDirectory owner,
        string name,
        Action<string>? afterEntryClassifiedForTesting = null)
    {
        try { owner.DeleteClaimedTree(afterEntryClassifiedForTesting); }
        catch (Exception exception)
        {
            throw new IOException($"{name} cleanup refused to delete an unowned or changed object.", exception);
        }
    }

    private static void CleanupOwnedRoot(WindowsOwnedDirectory? owner, string name, List<Exception> failures)
    {
        if (owner is null) return;
        try { RemoveOwnedDirectory(owner, name); }
        catch (Exception exception) { failures.Add(exception); }
        finally
        {
            try { owner.Release(); }
            catch (Exception exception) { failures.Add(exception); }
        }
    }

    private static void EnsureExistingParent(string path, string name)
    {
        var parent = Path.GetDirectoryName(path) ?? throw new IOException($"{name} has no parent directory.");
        ToolchainPathPolicy.ResolveExistingDirectory(parent, name);
    }

    private static byte[] ReadFrozenBytes(string path)
    {
        using var stream = WindowsFileIdentityAdapter.OpenFrozenRead(path);
        if (stream.Length > int.MaxValue) throw new InvalidDataException($"Toolchain file is too large to buffer: {path}");
        var bytes = GC.AllocateUninitializedArray<byte>(checked((int)stream.Length));
        stream.ReadExactly(bytes);
        if (stream.ReadByte() != -1) throw new InvalidDataException($"Toolchain file grew during read: {path}");
        return bytes;
    }

    private static string HashFile(string path)
    {
        using var stream = WindowsFileIdentityAdapter.OpenFrozenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
    }

    private static bool IsLowerSha256(string value) =>
        value.Length == 64 && value.All(character => character is >= '0' and <= '9' or >= 'a' and <= 'f');

    private sealed record PackageFileEntry(string RelativePath, string FullPath);
    private sealed record StableFileIdentity(long Length, string Sha256, WindowsFileIdentity WindowsIdentity)
    {
        internal bool EqualsStable(StableFileIdentity other) =>
            Length == other.Length && Sha256 == other.Sha256 && WindowsIdentity.IsSameObject(other.WindowsIdentity);
    }
    private sealed record ManifestIdentity(byte[] Bytes, IReadOnlyDictionary<string, string> HashByRelativePath);

    private sealed class RetainedPackageSnapshot
    {
        private readonly Dictionary<string, StableFileIdentity> _identityByRelative;
        private readonly Dictionary<string, FileStream> _streamByRelative;
        private bool _streamsClosed;

        private RetainedPackageSnapshot(
            IReadOnlyList<PackageFileEntry> files,
            Dictionary<string, StableFileIdentity> identityByRelative,
            Dictionary<string, FileStream> streamByRelative)
        {
            Files = files;
            _identityByRelative = identityByRelative;
            _streamByRelative = streamByRelative;
        }

        internal IReadOnlyList<PackageFileEntry> Files { get; }

        internal static RetainedPackageSnapshot Open(string sourceRoot)
        {
            var preFiles = EnumeratePackageFileSet(sourceRoot);
            var preIdentity = new Dictionary<string, StableFileIdentity>(StringComparer.OrdinalIgnoreCase);
            foreach (var file in preFiles)
            {
                using var stream = WindowsFileIdentityAdapter.OpenFrozenRead(file.FullPath);
                preIdentity.Add(file.RelativePath, ReadStableIdentity(stream));
            }

            var streams = new Dictionary<string, FileStream>(StringComparer.OrdinalIgnoreCase);
            try
            {
                foreach (var file in preFiles)
                {
                    var stream = WindowsFileIdentityAdapter.OpenFrozenRead(file.FullPath);
                    streams.Add(file.RelativePath, stream);
                    var retainedIdentity = ReadStableIdentity(stream);
                    if (!preIdentity[file.RelativePath].EqualsStable(retainedIdentity))
                        throw new InvalidDataException($"Package file changed while acquiring the whole-package freeze: {file.RelativePath}");
                }

                var postFiles = EnumeratePackageFileSet(sourceRoot);
                if (!postFiles.Select(file => file.RelativePath).SequenceEqual(preFiles.Select(file => file.RelativePath), StringComparer.Ordinal))
                    throw new InvalidDataException("Package file set changed while acquiring the whole-package freeze.");
                return new RetainedPackageSnapshot(preFiles, preIdentity, streams);
            }
            catch (Exception primary)
            {
                var cleanupFailures = DisposeStreams(streams.Values);
                if (cleanupFailures.Count != 0)
                    throw new AggregateException(
                        "Package snapshot acquisition failed and retained handles could not all be released.",
                        new[] { primary }.Concat(cleanupFailures));
                throw;
            }
        }

        internal StableFileIdentity Identity(string relativePath) =>
            _identityByRelative.TryGetValue(relativePath, out var identity)
                ? identity
                : throw new InvalidDataException($"Package snapshot is missing required file: {relativePath}");

        internal byte[] ReadBytes(string relativePath)
        {
            if (!_streamByRelative.TryGetValue(relativePath, out var stream) || _streamsClosed)
                throw new InvalidOperationException($"Package retained stream is unavailable: {relativePath}");
            stream.Position = 0;
            if (stream.Length > int.MaxValue) throw new InvalidDataException($"Package file is too large to buffer: {relativePath}");
            var bytes = GC.AllocateUninitializedArray<byte>(checked((int)stream.Length));
            stream.ReadExactly(bytes);
            if (stream.ReadByte() != -1) throw new InvalidDataException($"Package retained source grew during read: {relativePath}");
            stream.Position = 0;
            return bytes;
        }

        internal void CopyTo(WindowsOwnedDirectory snapshotOwner)
        {
            if (_streamsClosed) throw new InvalidOperationException("Package retained streams are already closed.");
            foreach (var file in Files)
            {
                var source = _streamByRelative[file.RelativePath];
                source.Position = 0;
                using var output = snapshotOwner.CreateFile(file.RelativePath);
                source.CopyTo(output.Stream);
                output.Stream.Flush(flushToDisk: true);
                var copiedIdentity = ReadStableIdentity(source);
                if (!_identityByRelative[file.RelativePath].EqualsStable(copiedIdentity))
                    throw new InvalidDataException($"Package retained source changed while copying to the owned snapshot: {file.RelativePath}");
            }
        }

        internal void AssertStable(string sourceRoot)
        {
            var currentFiles = EnumeratePackageFileSet(sourceRoot);
            if (!currentFiles.Select(file => file.RelativePath).SequenceEqual(Files.Select(file => file.RelativePath), StringComparer.Ordinal))
                throw new InvalidDataException("Package file set changed after the retained snapshot was acquired.");
            foreach (var file in currentFiles)
            {
                using var stream = WindowsFileIdentityAdapter.OpenFrozenRead(file.FullPath);
                var currentIdentity = ReadStableIdentity(stream);
                if (!_identityByRelative[file.RelativePath].EqualsStable(currentIdentity))
                    throw new InvalidDataException($"Package file identity changed after the retained snapshot was acquired: {file.RelativePath}");
            }
        }

        internal void CloseStreams()
        {
            if (_streamsClosed) return;
            var failures = DisposeStreams(_streamByRelative.Values);
            _streamsClosed = true;
            if (failures.Count == 1) ExceptionDispatchInfo.Capture(failures[0]).Throw();
            if (failures.Count > 1) throw new AggregateException("Package retained handle release failures.", failures);
        }

        private static StableFileIdentity ReadStableIdentity(FileStream stream)
        {
            var windowsIdentity = WindowsFileIdentityAdapter.GetIdentity(stream.SafeFileHandle);
            if (windowsIdentity.IsDirectory || windowsIdentity.IsReparsePoint)
                throw new InvalidDataException("Package snapshot source handle must identify a regular, non-reparse file.");
            stream.Position = 0;
            var hash = Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
            var length = stream.Length;
            stream.Position = 0;
            return new StableFileIdentity(length, hash, windowsIdentity);
        }

        private static List<Exception> DisposeStreams(IEnumerable<FileStream> streams)
        {
            var failures = new List<Exception>();
            foreach (var stream in streams)
            {
                try { stream.Dispose(); }
                catch (Exception exception) { failures.Add(exception); }
            }
            return failures;
        }
    }
}
