using Kadath.Editor.Toolchain;

namespace Kadath.Editor.Toolchain.ContractVerifier;

internal static class SourceSnapshotContract
{
    internal static void Verify(ContractSandbox sandbox)
    {
        VerifySuccess(sandbox.NewCase("snapshot-success"));
        VerifyOverwriteRejected(sandbox.NewCase("snapshot-overwrite"));
        VerifyCleanFault(sandbox.NewCase("snapshot-file-id-fault"), ToolchainSourceSnapshot.FileIdBeforeReturnFault);
        VerifyCleanFault(sandbox.NewCase("snapshot-partial-write-fault"), ToolchainSourceSnapshot.PartialWriteBeforeFlushFault);
        VerifyReplacementRefusesWrongObjectCleanup(sandbox.NewCase("snapshot-replacement-fault"));
    }

    private static void VerifySuccess(string root)
    {
        var source = Path.Combine(root, "source.png");
        var destination = Path.Combine(root, "out", "snapshot.png");
        var expected = new byte[] { 1, 3, 5, 7, 9 };
        File.WriteAllBytes(source, expected);
        var result = ToolchainSourceSnapshot.Execute(new ToolchainSourceSnapshotRequest(source, destination));
        ContractAssert.Require(result.DestinationPath == destination && result.Length == expected.LongLength,
            "snapshot success result mismatch");
        ContractAssert.Require(File.ReadAllBytes(destination).AsSpan().SequenceEqual(expected), "snapshot bytes mismatch");
        ContractAssert.Require(result.Sha256 == ContractAssert.Sha256(source), "snapshot SHA-256 mismatch");
        AssertNoOwnedTemporary(Path.GetDirectoryName(destination)!);
    }

    private static void VerifyOverwriteRejected(string root)
    {
        var source = Path.Combine(root, "source.png");
        var destination = Path.Combine(root, "snapshot.png");
        File.WriteAllBytes(source, [1, 2, 3]);
        var sentinel = new byte[] { 9, 8, 7 };
        File.WriteAllBytes(destination, sentinel);
        ContractAssert.Throws<IOException>(() => ToolchainSourceSnapshot.Execute(
            new ToolchainSourceSnapshotRequest(source, destination)), "destination already exists");
        ContractAssert.Require(File.ReadAllBytes(destination).AsSpan().SequenceEqual(sentinel),
            "snapshot overwrite rejection changed the existing destination");
        AssertNoOwnedTemporary(root);
    }

    private static void VerifyCleanFault(string root, string faultMode)
    {
        var source = Path.Combine(root, "source.png");
        var destination = Path.Combine(root, "snapshot.png");
        File.WriteAllBytes(source, [2, 4, 6, 8]);
        _ = ContractAssert.Throws<Exception>(() => ToolchainSourceSnapshot.Execute(
            new ToolchainSourceSnapshotRequest(source, destination, FaultMode: faultMode)));
        ContractAssert.Require(!File.Exists(destination) && !Directory.Exists(destination),
            $"{faultMode} advanced the snapshot destination");
        AssertNoOwnedTemporary(root);
    }

    private static void VerifyReplacementRefusesWrongObjectCleanup(string root)
    {
        var source = Path.Combine(root, "source.png");
        var destination = Path.Combine(root, "snapshot.png");
        var bytes = new byte[] { 4, 3, 2, 1 };
        File.WriteAllBytes(source, bytes);
        _ = ContractAssert.Throws<Exception>(() => ToolchainSourceSnapshot.Execute(
            new ToolchainSourceSnapshotRequest(
                source,
                destination,
                FaultMode: ToolchainSourceSnapshot.ReplaceBeforeCleanupFault)),
            "Refusing to delete a replaced snapshot object.");

        ContractAssert.Require(!File.Exists(destination), "replacement fault advanced the final snapshot destination");
        var retained = Directory.EnumerateFiles(root, ".kadath-texture-source-snapshot-*.tmp").ToArray();
        // 关键安全断言：同字节 replacement 必须被保留，证明 cleanup 没有按 path/hash 猜测所有权。
        ContractAssert.Require(retained.Length == 1 && File.ReadAllBytes(retained[0]).AsSpan().SequenceEqual(bytes),
            "replacement fault deleted or altered the unowned replacement object");
        ContractAssert.Require(!Directory.EnumerateFiles(root, ".kadath-texture-source-replacement-*.tmp").Any(),
            "replacement move left an obsolete source path");
    }

    private static void AssertNoOwnedTemporary(string root)
    {
        if (!Directory.Exists(root)) return;
        ContractAssert.Require(
            !Directory.EnumerateFiles(root, ".kadath-texture-source-*.tmp", SearchOption.TopDirectoryOnly).Any(),
            "snapshot failure left an owned temporary file");
    }
}
