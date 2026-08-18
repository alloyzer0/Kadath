using System.Security.Cryptography;
using System.Runtime.ExceptionServices;
using Kadath.Editor.Workspace;

namespace Kadath.Editor.Toolchain;

internal sealed record ToolchainImportRequest(
    string Kind,
    string SourcePath,
    string DestinationPath,
    string Profile,
    Action<string>? VerificationBeforeMove = null);

internal sealed record ToolchainImportResult(
    string Kind,
    string Profile,
    int ArtifactBytes,
    string Sha256,
    string DestinationPath);

internal static class ToolchainImport
{
    internal static ToolchainImportResult Execute(ToolchainImportRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.Profile is not ("debug" or "release"))
            throw new ArgumentException($"Unsupported import profile: {request.Profile}.", nameof(request));
        var source = ToolchainPathPolicy.ResolveExistingFile(request.SourcePath, $"{request.Kind} import source");
        var artifact = request.Kind switch
        {
            "texture" => WorkspaceTextureImportModel.EncodeSourceFile(source, request.Profile),
            "audio" => WorkspaceAudioCodec.EncodeSourceFile(source).Bytes,
            "scene" => WorkspaceSceneCodec.EncodeSource(File.ReadAllBytes(source)),
            "script" => WorkspaceScriptCodec.EncodeSource(File.ReadAllBytes(source)),
            _ => throw new ArgumentException($"Unsupported import kind: {request.Kind}.")
        };
        PublishOwned(request.DestinationPath, artifact, request.VerificationBeforeMove);
        return new ToolchainImportResult(
            request.Kind,
            request.Profile,
            artifact.Length,
            Convert.ToHexString(SHA256.HashData(artifact)).ToLowerInvariant(),
            Path.GetFullPath(request.DestinationPath));
    }

    private static void PublishOwned(string destinationPath, byte[] bytes, Action<string>? verificationBeforeMove)
    {
        var destination = ToolchainPathPolicy.CanonicalAbsoluteLocalPath(
            destinationPath,
            "Import destination",
            requireCanonicalSpelling: false);
        if (File.Exists(destination) || Directory.Exists(destination))
            throw new IOException($"Refusing to overwrite toolchain output: {destination}.");
        var parent = Path.GetDirectoryName(destination) ?? throw new IOException("Toolchain destination has no parent directory.");
        ToolchainPathPolicy.RejectReparsePointInExistingPath(parent, "Import destination parent before create");
        Directory.CreateDirectory(parent);
        parent = ToolchainPathPolicy.ResolveExistingDirectory(parent, "Import destination parent after create");
        using var parentHandle = WindowsFileIdentityAdapter.OpenDirectoryForIdentity(parent);
        var parentIdentity = WindowsFileIdentityAdapter.GetIdentity(parentHandle);
        if (!parentIdentity.IsDirectory || parentIdentity.IsReparsePoint)
            throw new IOException("Import destination parent must be a regular, non-reparse directory.");
        var temporary = Path.Combine(parent, $".{Path.GetFileName(destination)}.{Guid.NewGuid():N}.tmp");
        WindowsOwnedFile? owner = null;
        var moved = false;
        var succeeded = false;
        Exception? primaryFailure = null;
        try
        {
            owner = WindowsFileIdentityAdapter.CreateOwnedFile(temporary, allowDeleteSharing: true);
            WriteDurable(owner, bytes);
            verificationBeforeMove?.Invoke(temporary);
            VerifyParentIdentity(parent, parentHandle, parentIdentity, "before import publication");
            if (File.Exists(destination) || Directory.Exists(destination))
                throw new IOException($"Import destination appeared before no-replace publication: {destination}.");
            WindowsFileIdentityAdapter.RenameOwnedFileNoReplace(owner.Stream.SafeFileHandle, destination);
            moved = true;
            owner.CloseStream();
            if (!File.Exists(destination))
                throw new IOException("Owned-handle rename did not create the import destination.");
            if (File.Exists(temporary) || Directory.Exists(temporary))
                throw new IOException("Import publication detected a foreign same-path replacement.");
            VerifyParentIdentity(parent, parentHandle, parentIdentity, "after import publication");
            using var committed = WindowsFileIdentityAdapter.OpenFrozenRead(destination);
            var committedIdentity = WindowsFileIdentityAdapter.GetIdentity(committed.SafeFileHandle);
            if (!owner.Identity.IsSameObject(committedIdentity) || committed.Length != bytes.LongLength ||
                !SHA256.HashData(committed).AsSpan().SequenceEqual(SHA256.HashData(bytes)))
                throw new IOException("Committed import artifact identity or durable bytes mismatch.");
            succeeded = true;
        }
        catch (Exception exception) { primaryFailure = exception; }

        try { owner?.CloseStream(); }
        catch (Exception closeFailure)
        {
            primaryFailure = primaryFailure is null
                ? closeFailure
                : new AggregateException("Import publication and owning handle close both failed.", primaryFailure, closeFailure);
        }

        Exception? cleanupFailure = null;
        if (!succeeded && owner is not null)
        {
            try
            {
                WindowsFileIdentityAdapter.DeleteOwnedFileIfPresent(moved ? destination : temporary, owner.Identity);
            }
            catch (Exception exception) { cleanupFailure = exception; }
        }
        if (primaryFailure is not null && cleanupFailure is not null)
            throw new AggregateException("Import publication and owned cleanup both failed.", primaryFailure, cleanupFailure);
        if (primaryFailure is not null) ExceptionDispatchInfo.Capture(primaryFailure).Throw();
        if (cleanupFailure is not null) ExceptionDispatchInfo.Capture(cleanupFailure).Throw();
    }

    private static void VerifyParentIdentity(
        string parent,
        Microsoft.Win32.SafeHandles.SafeFileHandle retainedHandle,
        WindowsFileIdentity expected,
        string phase)
    {
        ToolchainPathPolicy.RejectReparsePointInExistingPath(parent, $"Import destination parent {phase}");
        using var liveHandle = WindowsFileIdentityAdapter.OpenDirectoryForIdentity(parent);
        var retained = WindowsFileIdentityAdapter.GetIdentity(retainedHandle);
        var live = WindowsFileIdentityAdapter.GetIdentity(liveHandle);
        if (!expected.IsSameObject(retained) || !expected.IsSameObject(live) ||
            !retained.IsDirectory || retained.IsReparsePoint || !live.IsDirectory || live.IsReparsePoint)
            throw new IOException($"Import destination parent identity changed {phase}.");
    }

    private static void WriteDurable(WindowsOwnedFile owner, byte[] bytes)
    {
        Exception? primaryFailure = null;
        try
        {
            owner.Stream.Write(bytes);
            owner.Stream.Flush(flushToDisk: true);
        }
        catch (Exception exception) { primaryFailure = exception; }

        if (primaryFailure is not null) ExceptionDispatchInfo.Capture(primaryFailure).Throw();
    }
}
