using System.Buffers.Binary;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Kadath.Editor.Verification;

/// <summary>
/// verifier-only 的 Windows 目录对象身份；它不属于 Workspace/Protocol 产品契约。
/// </summary>
internal readonly record struct VerifierWindowsDirectoryIdentity(uint VolumeSerialNumber, ulong FileIndex)
{
    private const uint FileReadAttributes = 0x00000080;
    private const uint DeleteAccess = 0x00010000;
    private const uint FileShareRead = 0x00000001;
    private const uint FileShareWrite = 0x00000002;
    private const uint FileShareDelete = 0x00000004;
    private const uint OpenExisting = 3;
    private const uint FileFlagOpenReparsePoint = 0x00200000;
    private const uint FileFlagBackupSemantics = 0x02000000;
    private const uint FileAttributeDirectory = 0x00000010;
    private const uint FileAttributeReparsePoint = 0x00000400;

    internal static VerifierWindowsDirectoryIdentity Capture(string path)
    {
        if (TryCaptureRegularDirectory(path, out var identity)) return identity;
        throw new IOException($"Verifier-owned path is not a regular non-reparse directory: {path}");
    }

    internal static bool TryCaptureRegularDirectory(
        string path,
        out VerifierWindowsDirectoryIdentity identity)
    {
        EnsureWindows();
        using var handle = OpenNoFollow(path);
        if (!GetFileInformationByHandle(handle, out var information))
            throw new Win32Exception(Marshal.GetLastWin32Error(),
                $"Reading verifier-owned filesystem entry identity failed: {path}");
        if ((information.FileAttributes & FileAttributeReparsePoint) != 0)
            throw new IOException($"Verifier-owned path cannot be a reparse point: {path}");
        if ((information.FileAttributes & FileAttributeDirectory) == 0)
        {
            identity = default;
            return false;
        }

        identity = CreateIdentity(information);
        return true;
    }

    internal VerifierWindowsDirectoryDeletionLease AcquireDeletionLease(string path)
    {
        EnsureWindows();
        // 关键边界：拒绝 FILE_SHARE_DELETE，并在同一 handle 上同时取得 DELETE 权限。
        // 因而身份复验成功后，路径不能在 lease 存续期间被删除、重命名或替换。
        var handle = OpenNoFollow(path, denyDeleteSharing: true);
        try
        {
            var current = ReadRegularDirectoryIdentity(handle, path);
            if (current != this)
                throw new IOException($"Refusing to clean a replaced verifier-owned directory: {path}");
            return new VerifierWindowsDirectoryDeletionLease(handle, path);
        }
        catch
        {
            handle.Dispose();
            throw;
        }
    }

    private static SafeFileHandle OpenNoFollow(string path, bool denyDeleteSharing = false)
    {
        var handle = CreateFileW(
            path,
            FileReadAttributes | (denyDeleteSharing ? DeleteAccess : 0),
            FileShareRead | FileShareWrite | (denyDeleteSharing ? 0 : FileShareDelete),
            IntPtr.Zero,
            OpenExisting,
            FileFlagOpenReparsePoint | FileFlagBackupSemantics,
            IntPtr.Zero);
        if (handle.IsInvalid)
        {
            var error = Marshal.GetLastWin32Error();
            handle.Dispose();
            throw new Win32Exception(error, $"Opening verifier-owned directory identity failed: {path}");
        }
        return handle;
    }

    private static VerifierWindowsDirectoryIdentity ReadRegularDirectoryIdentity(SafeFileHandle handle, string path)
    {
        if (!GetFileInformationByHandle(handle, out var information))
            throw new Win32Exception(Marshal.GetLastWin32Error(), $"Reading verifier-owned directory identity failed: {path}");
        if ((information.FileAttributes & FileAttributeDirectory) == 0
            || (information.FileAttributes & FileAttributeReparsePoint) != 0)
            throw new IOException($"Verifier-owned path is not a regular non-reparse directory: {path}");

        return CreateIdentity(information);
    }

    private static VerifierWindowsDirectoryIdentity CreateIdentity(ByHandleFileInformation information) =>
        new(
            information.VolumeSerialNumber,
            ((ulong)information.FileIndexHigh << 32) | information.FileIndexLow);

    private static void EnsureWindows()
    {
        if (!OperatingSystem.IsWindows())
            throw new PlatformNotSupportedException("Windows directory identity is only used by native Windows verifier workflows.");
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ByHandleFileInformation
    {
        internal uint FileAttributes;
        internal System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        internal System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        internal System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        internal uint VolumeSerialNumber;
        internal uint FileSizeHigh;
        internal uint FileSizeLow;
        internal uint NumberOfLinks;
        internal uint FileIndexHigh;
        internal uint FileIndexLow;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(
        string fileName,
        uint desiredAccess,
        uint shareMode,
        IntPtr securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(
        SafeFileHandle handle,
        out ByHandleFileInformation information);
}

/// <summary>
/// 已复验 File ID 的 verifier-only 目录删除 lease；关闭前始终拒绝路径被替换。
/// </summary>
internal sealed class VerifierWindowsDirectoryDeletionLease : IDisposable
{
    private const int FileDispositionInfo = 4;
    private readonly SafeFileHandle _handle;
    private readonly string _path;
    private bool _deleteRequested;

    internal VerifierWindowsDirectoryDeletionLease(SafeFileHandle handle, string path)
    {
        _handle = handle;
        _path = path;
    }

    internal void DeleteEmptyDirectory()
    {
        ObjectDisposedException.ThrowIf(_handle.IsClosed, this);
        if (_deleteRequested)
            throw new InvalidOperationException($"Verifier-owned directory deletion was already requested: {_path}");

        var disposition = new FileDispositionInformation { DeleteFile = 1 };
        if (!SetFileInformationByHandle(
                _handle,
                FileDispositionInfo,
                ref disposition,
                (uint)Marshal.SizeOf<FileDispositionInformation>()))
            throw new Win32Exception(Marshal.GetLastWin32Error(),
                $"Deleting empty verifier-owned directory by retained handle failed: {_path}");
        _deleteRequested = true;
    }

    internal void DeleteOwnedDirectoryTree(Action<string>? afterDirectoryAttributesBeforeChildLeaseForTesting = null)
    {
        ObjectDisposedException.ThrowIf(_handle.IsClosed, this);

        // 每层目录都由自己的拒绝 delete-sharing handle 锁定；这里只枚举当前 lease 的直属子项。
        foreach (var entry in Directory.EnumerateFileSystemEntries(_path).ToArray())
            DeleteRegularEntry(entry, afterDirectoryAttributesBeforeChildLeaseForTesting);
        DeleteEmptyDirectory();
    }

    public void Dispose() => _handle.Dispose();

    private static void DeleteRegularEntry(
        string path,
        Action<string>? afterDirectoryAttributesBeforeChildLeaseForTesting)
    {
        // no-follow handle 在一次读取中同时给出类型、reparse 状态与 File ID，
        // 不留下“先按路径读属性、再取得预期身份”的普通目录替换窗口。
        if (!VerifierWindowsDirectoryIdentity.TryCaptureRegularDirectory(path, out var childIdentity))
        {
            File.Delete(path);
            return;
        }

        // 已冻结当前子目录 File ID；测试 seam 随后精确注入属性检查后的替换。
        // AcquireDeletionLease 会用 no-follow 独占 handle 再次复验，普通替换与 junction 都会 fail-closed。
        afterDirectoryAttributesBeforeChildLeaseForTesting?.Invoke(path);
        using var childLease = childIdentity.AcquireDeletionLease(path);
        childLease.DeleteOwnedDirectoryTree(afterDirectoryAttributesBeforeChildLeaseForTesting);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FileDispositionInformation
    {
        internal int DeleteFile;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetFileInformationByHandle(
        SafeFileHandle fileHandle,
        int fileInformationClass,
        ref FileDispositionInformation fileInformation,
        uint bufferSize);
}

/// <summary>为 ownership contract 构造无需 symlink privilege 的本地 Windows junction。</summary>
internal static class VerifierWindowsDirectoryLink
{
    private const uint GenericWrite = 0x40000000;
    private const uint FileShareRead = 0x00000001;
    private const uint FileShareWrite = 0x00000002;
    private const uint FileShareDelete = 0x00000004;
    private const uint OpenExisting = 3;
    private const uint FileFlagOpenReparsePoint = 0x00200000;
    private const uint FileFlagBackupSemantics = 0x02000000;
    private const uint FsctlSetReparsePoint = 0x000900A4;
    private const uint IoReparseTagMountPoint = 0xA0000003;

    internal static void WithDirectoryReplacement(string path, Action action)
    {
        if (!OperatingSystem.IsWindows())
            throw new PlatformNotSupportedException("Windows junction fixture requires native Windows.");

        var target = $"{path}.junction-target-{Guid.NewGuid():N}";
        Directory.Move(path, target);
        var linked = false;
        try
        {
            CreateJunction(path, target);
            linked = true;
            action();
        }
        finally
        {
            if (linked && Directory.Exists(path)) DeleteJunction(path);
            if (Directory.Exists(target)) Directory.Move(target, path);
        }
    }

    internal static IDisposable ReplaceDirectoryWithJunction(string path, string targetPath) =>
        new ForeignJunctionReplacement(path, targetPath);

    private sealed class ForeignJunctionReplacement : IDisposable
    {
        private readonly string _path;
        private readonly string _detachedPath;
        private bool _disposed;

        internal ForeignJunctionReplacement(string path, string targetPath)
        {
            if (!OperatingSystem.IsWindows())
                throw new PlatformNotSupportedException("Windows junction fixture requires native Windows.");
            _path = Path.GetFullPath(path);
            var target = Path.GetFullPath(targetPath);
            _detachedPath = $"{_path}.detached-{Guid.NewGuid():N}";
            Directory.Move(_path, _detachedPath);
            try
            {
                CreateJunction(_path, target);
            }
            catch
            {
                Directory.Move(_detachedPath, _path);
                throw;
            }
        }

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            // 被测缺陷可能已删掉 junction；无论哪条路径，都只恢复原 owned 子目录。
            if (Directory.Exists(_path)) DeleteJunction(_path);
            if (Directory.Exists(_detachedPath)) Directory.Move(_detachedPath, _path);
        }
    }

    private static void CreateJunction(string linkPath, string targetPath)
    {
        var fullTarget = Path.GetFullPath(targetPath).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        if (fullTarget.StartsWith("\\\\", StringComparison.Ordinal))
            throw new InvalidOperationException("Verifier junction target must be a local path.");

        Directory.CreateDirectory(linkPath);
        try
        {
            using var handle = CreateFileW(
                linkPath,
                GenericWrite,
                FileShareRead | FileShareWrite | FileShareDelete,
                IntPtr.Zero,
                OpenExisting,
                FileFlagOpenReparsePoint | FileFlagBackupSemantics,
                IntPtr.Zero);
            if (handle.IsInvalid)
                throw new Win32Exception(Marshal.GetLastWin32Error(), $"Opening junction fixture failed: {linkPath}");

            var buffer = BuildMountPointBuffer(fullTarget);
            if (!DeviceIoControl(handle, FsctlSetReparsePoint, buffer, buffer.Length, IntPtr.Zero, 0, out _, IntPtr.Zero))
                throw new Win32Exception(Marshal.GetLastWin32Error(), $"Creating junction fixture failed: {linkPath}");
            if ((File.GetAttributes(linkPath) & FileAttributes.ReparsePoint) == 0)
                throw new IOException($"Junction fixture does not expose ReparsePoint: {linkPath}");
        }
        catch
        {
            if (Directory.Exists(linkPath)) Directory.Delete(linkPath);
            throw;
        }
    }

    private static byte[] BuildMountPointBuffer(string targetPath)
    {
        var substituteBytes = Encoding.Unicode.GetBytes($@"\??\{targetPath}");
        var printBytes = Encoding.Unicode.GetBytes(targetPath);
        var pathBufferBytes = checked(substituteBytes.Length + sizeof(char) + printBytes.Length + sizeof(char));
        var reparseDataBytes = checked(8 + pathBufferBytes);
        var buffer = new byte[checked(8 + reparseDataBytes)];

        // Mount-point buffer 的通用 header 后紧跟四个名称 offset/length 与 UTF-16 路径。
        BinaryPrimitives.WriteUInt32LittleEndian(buffer.AsSpan(0, 4), IoReparseTagMountPoint);
        BinaryPrimitives.WriteUInt16LittleEndian(buffer.AsSpan(4, 2), checked((ushort)reparseDataBytes));
        BinaryPrimitives.WriteUInt16LittleEndian(buffer.AsSpan(8, 2), 0);
        BinaryPrimitives.WriteUInt16LittleEndian(buffer.AsSpan(10, 2), checked((ushort)substituteBytes.Length));
        BinaryPrimitives.WriteUInt16LittleEndian(buffer.AsSpan(12, 2), checked((ushort)(substituteBytes.Length + sizeof(char))));
        BinaryPrimitives.WriteUInt16LittleEndian(buffer.AsSpan(14, 2), checked((ushort)printBytes.Length));
        substituteBytes.CopyTo(buffer, 16);
        printBytes.CopyTo(buffer, 16 + substituteBytes.Length + sizeof(char));
        return buffer;
    }

    private static void DeleteJunction(string path)
    {
        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) == 0)
            throw new IOException($"Refusing to delete a non-reparse fixture directory: {path}");
        Directory.Delete(path);
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(
        string fileName,
        uint desiredAccess,
        uint shareMode,
        IntPtr securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DeviceIoControl(
        SafeFileHandle device,
        uint controlCode,
        byte[] input,
        int inputBytes,
        IntPtr output,
        int outputBytes,
        out int bytesReturned,
        IntPtr overlapped);
}
