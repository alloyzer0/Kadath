using System.Diagnostics;
using System.Runtime.ExceptionServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Kadath.Editor.Toolchain;

internal sealed record ToolchainSourceSnapshotRequest(
    string SourcePath,
    string DestinationPath,
    string? VerificationBarrierDirectory = null,
    string FaultMode = "-");

internal sealed record ToolchainSourceSnapshotResult(
    string DestinationPath,
    long Length,
    string Sha256);

internal static class ToolchainSourceSnapshot
{
    internal const string FileIdBeforeReturnFault = "snapshot-file-id-before-return";
    internal const string PartialWriteBeforeFlushFault = "snapshot-partial-write-before-flush";
    internal const string ReplaceBeforeCleanupFault = "snapshot-replace-before-cleanup";

    private const int MaximumSourceBytesExclusive = 8 * 1024 * 1024;
    private static readonly TimeSpan BarrierTimeout = TimeSpan.FromSeconds(30);

    internal static ToolchainSourceSnapshotResult Execute(ToolchainSourceSnapshotRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        ValidateFaultMode(request.FaultMode);
        var barrier = ResolveBarrier(request.VerificationBarrierDirectory);
        var source = ToolchainPathPolicy.ResolveExistingFile(request.SourcePath, "Texture source", requireCanonicalSpelling: true);

        byte[] sourceBytes;
        using (var sourceStream = WindowsFileIdentityAdapter.OpenFrozenRead(source))
        {
            var sourceLength = sourceStream.Length;
            if (sourceLength <= 0 || sourceLength >= MaximumSourceBytesExclusive)
                throw new InvalidDataException("Texture source snapshot must contain 1..(8 MiB - 1) bytes.");
            sourceBytes = GC.AllocateUninitializedArray<byte>(checked((int)sourceLength));
            sourceStream.ReadExactly(sourceBytes);
            if (sourceStream.ReadByte() != -1)
                throw new InvalidDataException("Texture source grew during snapshot read.");
        }

        var sourceHash = Sha256(sourceBytes);
        var destination = ToolchainPathPolicy.CanonicalAbsoluteLocalPath(
            request.DestinationPath,
            "Texture source snapshot destination",
            requireCanonicalSpelling: true);
        var destinationParent = Path.GetDirectoryName(destination)
            ?? throw new IOException("Texture source snapshot destination has no parent directory.");
        ToolchainPathPolicy.RejectReparsePointInExistingPath(destinationParent, "Texture source snapshot output parent before create");
        Directory.CreateDirectory(destinationParent);
        destinationParent = ToolchainPathPolicy.ResolveExistingDirectory(
            destinationParent,
            "Texture source snapshot output parent after create");
        if (File.Exists(destination) || Directory.Exists(destination))
            throw new IOException($"Texture source snapshot destination already exists: {destination}");

        var snapshotTemporary = Path.Combine(destinationParent, $".kadath-texture-source-snapshot-{Guid.NewGuid():N}.tmp");
        WindowsOwnedFile? snapshotOwner = null;
        WindowsOwnedFile? replacementOwner = null;
        WindowsOwnedFile? readyOwner = null;
        string? replacementTemporary = null;
        string? readyTemporary = null;
        WindowsFileIdentity? committedIdentity = null;
        var destinationCommitted = false;
        var snapshotSucceeded = false;
        Exception? primaryFailure = null;
        ToolchainSourceSnapshotResult? result = null;

        try
        {
            snapshotOwner = WindowsFileIdentityAdapter.CreateOwnedFile(
                snapshotTemporary,
                request.FaultMode.Equals(FileIdBeforeReturnFault, StringComparison.Ordinal));
            WriteOwnedFileDurable(snapshotOwner, sourceBytes, request.FaultMode);

            if (request.FaultMode.Equals(ReplaceBeforeCleanupFault, StringComparison.Ordinal))
            {
                // 同字节 replacement 验证 cleanup 只能相信 File ID，不能退化为 path/length/hash。
                replacementTemporary = Path.Combine(destinationParent, $".kadath-texture-source-replacement-{Guid.NewGuid():N}.tmp");
                replacementOwner = WindowsFileIdentityAdapter.CreateOwnedFile(replacementTemporary);
                WriteOwnedFileDurable(replacementOwner, sourceBytes, "-");
                File.Replace(replacementTemporary, snapshotTemporary, null, ignoreMetadataErrors: true);
                throw new InvalidOperationException("Injected snapshot replace-before-cleanup failure.");
            }

            AssertFileContent(snapshotTemporary, sourceBytes.LongLength, sourceHash, "Durable texture source snapshot");
            var moveParent = ToolchainPathPolicy.ResolveExistingDirectory(
                destinationParent,
                "Texture source snapshot output parent before move");
            if (!moveParent.Equals(destinationParent, StringComparison.OrdinalIgnoreCase) || File.Exists(destination) || Directory.Exists(destination))
                throw new IOException("Texture source snapshot destination changed before no-replace move.");

            File.Move(snapshotTemporary, destination, overwrite: false);
            destinationCommitted = true;
            committedIdentity = snapshotOwner.Identity;
            var committedDestination = ToolchainPathPolicy.ResolveExistingFile(destination, "Committed texture source snapshot");
            AssertFileContent(committedDestination, sourceBytes.LongLength, sourceHash, "Committed texture source snapshot");
            using (var committedHandle = WindowsFileIdentityAdapter.OpenFrozenRead(committedDestination))
            {
                var actualIdentity = WindowsFileIdentityAdapter.GetIdentity(committedHandle.SafeFileHandle);
                if (!snapshotOwner.Identity.IsSameObject(actualIdentity))
                    throw new IOException("Committed texture source snapshot File ID mismatch.");
            }

            if (barrier is not null)
            {
                var readyPath = Path.Combine(barrier, "ready.json");
                var releasePath = Path.Combine(barrier, "release");
                if (File.Exists(readyPath) || Directory.Exists(readyPath) || File.Exists(releasePath) || Directory.Exists(releasePath))
                    throw new IOException("Snapshot test barrier contains a pre-existing control path.");

                var readyBytes = BuildReadyDocument(sourceBytes.LongLength, sourceHash);
                readyTemporary = Path.Combine(barrier, $".ready-{Guid.NewGuid():N}.tmp");
                readyOwner = WindowsFileIdentityAdapter.CreateOwnedFile(readyTemporary);
                WriteOwnedFileDurable(readyOwner, readyBytes, "-");
                File.Move(readyTemporary, readyPath, overwrite: false);
                WaitForRelease(barrier, releasePath);
            }

            snapshotSucceeded = true;
            result = new ToolchainSourceSnapshotResult(destination, sourceBytes.LongLength, sourceHash);
        }
        catch (Exception exception)
        {
            primaryFailure = exception;
        }

        var cleanupFailures = new List<Exception>();
        if (destinationCommitted && !snapshotSucceeded && committedIdentity is { } identity)
            TryCleanup(destination, identity, cleanupFailures);
        if (snapshotOwner is not null)
            TryCleanup(snapshotTemporary, snapshotOwner.Identity, cleanupFailures);
        if (replacementOwner is not null && replacementTemporary is not null)
            TryCleanup(replacementTemporary, replacementOwner.Identity, cleanupFailures);
        if (readyOwner is not null && readyTemporary is not null)
            TryCleanup(readyTemporary, readyOwner.Identity, cleanupFailures);

        if (primaryFailure is not null)
        {
            if (cleanupFailures.Count != 0)
                throw new AggregateException(
                    "Texture source snapshot failed and owned cleanup also failed.",
                    new[] { primaryFailure }.Concat(cleanupFailures));
            ExceptionDispatchInfo.Capture(primaryFailure).Throw();
        }
        if (cleanupFailures.Count == 1) ExceptionDispatchInfo.Capture(cleanupFailures[0]).Throw();
        if (cleanupFailures.Count > 1) throw new AggregateException("Texture source snapshot cleanup failures.", cleanupFailures);
        return result ?? throw new InvalidOperationException("Texture source snapshot produced no result.");
    }

    private static void WriteOwnedFileDurable(WindowsOwnedFile owner, byte[] bytes, string faultMode)
    {
        Exception? primaryFailure = null;
        try
        {
            if (faultMode.Equals(PartialWriteBeforeFlushFault, StringComparison.Ordinal))
            {
                var partialLength = Math.Max(1, Math.Min(bytes.Length - 1, 7));
                owner.Stream.Write(bytes, 0, partialLength);
                throw new InvalidOperationException("Injected snapshot partial-write-before-flush failure.");
            }
            owner.Stream.Write(bytes);
            owner.Stream.Flush(flushToDisk: true);
        }
        catch (Exception exception)
        {
            primaryFailure = exception;
        }

        try { owner.CloseStream(); }
        catch (Exception cleanup) when (primaryFailure is not null)
        {
            throw new AggregateException("Owned file write and close both failed.", primaryFailure, cleanup);
        }
        if (primaryFailure is not null) ExceptionDispatchInfo.Capture(primaryFailure).Throw();
    }

    private static string? ResolveBarrier(string? barrierDirectory)
    {
        if (string.IsNullOrWhiteSpace(barrierDirectory) || barrierDirectory.Equals("-", StringComparison.Ordinal)) return null;
        var barrier = ToolchainPathPolicy.CanonicalAbsoluteLocalPath(
            barrierDirectory,
            "Snapshot test barrier",
            requireCanonicalSpelling: true);
        var temporaryRoot = ToolchainPathPolicy.ResolveExistingDirectory(
            Path.GetFullPath(Path.GetTempPath()).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
            "System temporary root");
        if (!ToolchainPathPolicy.Contains(temporaryRoot, barrier) || temporaryRoot.Equals(barrier, StringComparison.OrdinalIgnoreCase))
            throw new IOException("Snapshot test barrier must be below the system temporary root.");
        barrier = ToolchainPathPolicy.ResolveExistingDirectory(barrier, "Snapshot test barrier");
        if (Directory.EnumerateFileSystemEntries(barrier).Any())
            throw new IOException("Snapshot test barrier must start empty.");
        return barrier;
    }

    private static void WaitForRelease(string barrier, string releasePath)
    {
        var stopwatch = Stopwatch.StartNew();
        while (true)
        {
            if (File.Exists(releasePath))
            {
                ToolchainPathPolicy.RejectReparsePointInExistingPath(barrier, "Snapshot test barrier before release");
                var attributes = File.GetAttributes(releasePath);
                if ((attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0 || new FileInfo(releasePath).Length != 0)
                    throw new IOException("Snapshot test barrier release must be zero-length and non-reparse.");
                return;
            }
            if (Directory.Exists(releasePath))
                throw new IOException("Snapshot test barrier release must be a regular file.");
            if (stopwatch.Elapsed >= BarrierTimeout)
                throw new TimeoutException("Timed out waiting for snapshot test barrier release.");
            Thread.Sleep(25);
        }
    }

    private static byte[] BuildReadyDocument(long length, string sha256)
    {
        using var memory = new MemoryStream();
        using (var writer = new Utf8JsonWriter(memory))
        {
            writer.WriteStartObject();
            writer.WriteNumber("Version", 1);
            writer.WriteNumber("Length", length);
            writer.WriteString("Sha256", sha256);
            writer.WriteEndObject();
        }
        memory.WriteByte((byte)'\n');
        return memory.ToArray();
    }

    private static void AssertFileContent(string path, long expectedLength, string expectedSha256, string name)
    {
        using var stream = WindowsFileIdentityAdapter.OpenFrozenRead(path);
        if (stream.Length != expectedLength || !HashStream(stream).Equals(expectedSha256, StringComparison.Ordinal))
            throw new IOException($"{name} identity mismatch.");
    }

    private static string HashStream(Stream stream)
    {
        stream.Position = 0;
        var hash = Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
        stream.Position = 0;
        return hash;
    }

    private static string Sha256(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();

    private static void TryCleanup(string path, WindowsFileIdentity identity, List<Exception> failures)
    {
        try
        {
            ToolchainPathPolicy.RejectReparsePointInExistingPath(path, "Owned snapshot file");
            WindowsFileIdentityAdapter.DeleteOwnedFileIfPresent(path, identity);
        }
        catch (Exception exception) { failures.Add(exception); }
    }

    private static void ValidateFaultMode(string mode)
    {
        if (mode is not ("-" or FileIdBeforeReturnFault or PartialWriteBeforeFlushFault or ReplaceBeforeCleanupFault))
            throw new ArgumentException($"Unknown snapshot verifier fault mode: {mode}", nameof(mode));
    }
}
