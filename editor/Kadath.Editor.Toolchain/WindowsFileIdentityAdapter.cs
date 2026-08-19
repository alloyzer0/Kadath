using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Kadath.Editor.Toolchain;

internal readonly record struct WindowsFileIdentity(
    uint Attributes,
    uint VolumeSerialNumber,
    ulong FileIndex,
    long Length)
{
    internal bool IsDirectory => (Attributes & WindowsFileIdentityAdapter.FileAttributeDirectory) != 0;
    internal bool IsReparsePoint => (Attributes & WindowsFileIdentityAdapter.FileAttributeReparsePoint) != 0;

    internal bool IsSameObject(WindowsFileIdentity other) =>
        VolumeSerialNumber == other.VolumeSerialNumber && FileIndex == other.FileIndex;
}

internal sealed class WindowsOwnedFile : IDisposable
{
    private FileStream? _stream;
    private SafeFileHandle? _identityLease;

    internal WindowsOwnedFile(
        string path,
        FileStream stream,
        WindowsFileIdentity identity,
        SafeFileHandle? identityLease = null)
    {
        Path = path;
        _stream = stream;
        _identityLease = identityLease;
        Identity = identity;
    }

    internal string Path { get; }
    internal WindowsFileIdentity Identity { get; }
    internal FileStream Stream => _stream ?? throw new InvalidOperationException("Owned file stream is unavailable.");

    internal void CloseStream()
    {
        _stream?.Dispose();
        _stream = null;
    }

    internal void VerifyIdentityLease()
    {
        var lease = _identityLease;
        if (lease is null || lease.IsInvalid || lease.IsClosed)
            throw new InvalidOperationException("Owned file identity lease is unavailable.");
        var actual = WindowsFileIdentityAdapter.GetIdentity(lease);
        if (actual.IsDirectory || actual.IsReparsePoint || !Identity.IsSameObject(actual))
            throw new InvalidOperationException($"Owned file identity lease changed: {Path}");
    }

    internal void DeleteThroughIdentityLease()
    {
        CloseStream();
        VerifyIdentityLease();
        var lease = _identityLease!;
        WindowsFileIdentityAdapter.MarkDeleteOnClose(lease);
        lease.Dispose();
        _identityLease = null;
    }

    internal void ReleaseIdentityLease()
    {
        CloseStream();
        _identityLease?.Dispose();
        _identityLease = null;
    }

    public void Dispose() => CloseStream();
}

internal sealed class WindowsOwnedDirectory : IDisposable
{
    private SafeFileHandle? _handle;
    private readonly SortedDictionary<string, WindowsFileIdentity> _claimedTree =
        new(StringComparer.OrdinalIgnoreCase);
    private readonly SortedDictionary<string, WindowsOwnedDirectory> _ownedDirectories =
        new(StringComparer.OrdinalIgnoreCase);
    private readonly SortedDictionary<string, WindowsOwnedFile> _ownedFiles =
        new(StringComparer.OrdinalIgnoreCase);

    internal WindowsOwnedDirectory(string path, SafeFileHandle handle, WindowsFileIdentity identity)
    {
        Path = path;
        _handle = handle;
        Identity = identity;
    }

    internal string Path { get; }
    internal WindowsFileIdentity Identity { get; }

    internal void VerifyPath()
    {
        var handle = _handle;
        if (handle is null || handle.IsInvalid || handle.IsClosed)
            throw new InvalidOperationException("Owned directory handle is unavailable.");

        using var pathHandle = WindowsFileIdentityAdapter.OpenDirectoryForIdentity(Path);
        AssertLiveIdentity(WindowsFileIdentityAdapter.GetIdentity(pathHandle));
        AssertLiveIdentity(WindowsFileIdentityAdapter.GetIdentity(handle));
    }

    internal void DeleteEmpty()
    {
        VerifyPath();
        var handle = _handle ?? throw new InvalidOperationException("Owned directory handle is unavailable.");
        WindowsFileIdentityAdapter.MarkDeleteOnClose(handle);
        handle.Dispose();
        _handle = null;
    }

    internal WindowsOwnedFile CreateFile(string relativePath)
    {
        VerifyPath();
        var relative = NormalizeRelativePath(relativePath);
        if (_claimedTree.ContainsKey(relative))
            throw new IOException($"Owned directory entry was already created: {relative}");

        var parent = System.IO.Path.GetDirectoryName(relative);
        if (!string.IsNullOrEmpty(parent)) EnsureDirectory(parent);
        var fullPath = System.IO.Path.Combine(Path, relative);
        var owned = WindowsFileIdentityAdapter.CreateOwnedFile(fullPath, retainIdentityLease: true);
        try
        {
            // 文件只能在 CreateNew 原始句柄仍存活时进入所有权集合，禁止事后按路径认领。
            _claimedTree.Add(relative, owned.Identity);
            _ownedFiles.Add(relative, owned);
            return owned;
        }
        catch
        {
            owned.DeleteThroughIdentityLease();
            throw;
        }
    }

    internal void EnsureDirectory(string relativePath)
    {
        VerifyPath();
        var relative = NormalizeRelativePath(relativePath);
        var current = string.Empty;
        foreach (var segment in relative.Split(System.IO.Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries))
        {
            current = string.IsNullOrEmpty(current)
                ? segment
                : System.IO.Path.Combine(current, segment);
            if (_claimedTree.TryGetValue(current, out var existing))
            {
                if (!existing.IsDirectory || !_ownedDirectories.ContainsKey(current))
                    throw new IOException($"Owned directory path conflicts with an existing file: {current}");
                continue;
            }

            var fullPath = System.IO.Path.Combine(Path, current);
            var owned = WindowsFileIdentityAdapter.CreateOwnedDirectory(fullPath);
            try
            {
                // 目录的拒绝 delete-sharing 句柄保留到事务结束，父链在创建后不能被替换。
                _claimedTree.Add(current, owned.Identity);
                _ownedDirectories.Add(current, owned);
            }
            catch
            {
                owned.DeleteEmpty();
                throw;
            }
        }
    }

    internal void DeleteClaimedTree(Action<string>? afterEntryClassifiedForTesting = null)
    {
        VerifyClaimedTree();
        // 先删除最深层文件，再通过从创建时持续持有的目录句柄删除空目录；全程不按路径猜测所有权。
        foreach (var entry in _claimedTree
                     .OrderByDescending(pair => PathDepth(pair.Key))
                     .ThenBy(pair => pair.Key, StringComparer.OrdinalIgnoreCase))
        {
            var fullPath = System.IO.Path.Combine(Path, entry.Key);
            afterEntryClassifiedForTesting?.Invoke(fullPath);
            if (entry.Value.IsDirectory)
            {
                var owned = _ownedDirectories[entry.Key];
                owned.VerifyPath();
                if (Directory.EnumerateFileSystemEntries(fullPath).Any())
                    throw new IOException($"Owned child directory is not empty after claimed descendants were removed: {fullPath}");
                owned.DeleteEmpty();
            }
            else
            {
                var owned = _ownedFiles[entry.Key];
                owned.VerifyIdentityLease();
                owned.DeleteThroughIdentityLease();
            }
        }
        _ownedDirectories.Clear();
        _ownedFiles.Clear();
        VerifyPath();
        if (Directory.EnumerateFileSystemEntries(Path).Any())
            throw new IOException($"Owned directory changed while clearing; retaining root: {Path}");
        DeleteEmpty();
    }

    internal void VerifyClaimedTree()
    {
        VerifyPath();
        WindowsFileIdentityAdapter.AssertRegularTreeMatches(Path, _claimedTree);
    }

    internal IEnumerable<string> EnumerateOwnedDirectoryPaths()
    {
        yield return Path;
        foreach (var relativePath in _ownedDirectories.Keys)
            yield return System.IO.Path.Combine(Path, relativePath);
    }

    internal void Release()
    {
        foreach (var file in _ownedFiles.Values) file.ReleaseIdentityLease();
        _ownedFiles.Clear();
        foreach (var directory in _ownedDirectories
                     .OrderByDescending(pair => PathDepth(pair.Key))
                     .Select(pair => pair.Value))
            directory.Release();
        _ownedDirectories.Clear();
        _handle?.Dispose();
        _handle = null;
    }

    public void Dispose() => Release();

    private void AssertLiveIdentity(WindowsFileIdentity identity)
    {
        if (!identity.IsDirectory || identity.IsReparsePoint || !Identity.IsSameObject(identity))
            throw new InvalidOperationException("Owned directory identity changed or became reparse-backed.");
    }

    private static int PathDepth(string relativePath) =>
        relativePath.Count(character => character is '\\' or '/') + 1;

    private static string NormalizeRelativePath(string relativePath)
    {
        if (string.IsNullOrWhiteSpace(relativePath) || System.IO.Path.IsPathRooted(relativePath))
            throw new IOException($"Owned entry path must be a non-empty relative path: {relativePath}");
        var normalized = relativePath.Replace(System.IO.Path.AltDirectorySeparatorChar, System.IO.Path.DirectorySeparatorChar);
        if (normalized.Split(System.IO.Path.DirectorySeparatorChar).Any(segment =>
                segment.Length == 0 || segment is "." or ".."))
            throw new IOException($"Owned entry path contains an invalid segment: {relativePath}");
        return normalized;
    }
}

internal sealed class WindowsDirectoryMutationGuardSet : IDisposable
{
    private const uint FsctlRequestOplock = 0x00090240;
    private const uint OplockLevelCacheRead = 0x00000001;
    private const uint RequestOplockInputFlagRequest = 0x00000001;
    private const uint FileReadAttributesAccess = 0x00000080;
    private const uint GenericReadAccess = 0x80000000;
    private const uint FileShareRead = 0x00000001;
    private const uint FileShareWrite = 0x00000002;
    private const uint FileShareDelete = 0x00000004;
    private const uint OpenExisting = 3;
    private const uint FileFlagBackupSemantics = 0x02000000;
    private const uint FileFlagOpenReparsePoint = 0x00200000;
    private const uint FileFlagOverlapped = 0x40000000;
    private const int ErrorIoPending = 997;
    private const int ErrorNotFound = 1168;
    private const uint WaitObject0 = 0;
    private const uint WaitTimeout = 258;
    private const uint WaitFailed = 0xffffffff;
    private const uint OplockCancelTimeoutMilliseconds = 10_000;
    private readonly List<Guard> _guards;
    private bool _disposed;

    private WindowsDirectoryMutationGuardSet(List<Guard> guards) => _guards = guards;

    internal static WindowsDirectoryMutationGuardSet Acquire(IEnumerable<string> directoryPaths)
    {
        var paths = directoryPaths.Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        if (paths.Length is 0 or > 64)
            throw new IOException($"Final directory mutation guard requires 1..64 directories, got {paths.Length}.");

        var guards = new List<Guard>(paths.Length);
        try
        {
            foreach (var path in paths) guards.Add(Guard.Acquire(path));
            return new WindowsDirectoryMutationGuardSet(guards);
        }
        catch
        {
            foreach (var guard in guards) guard.Dispose();
            throw;
        }
    }

    internal void AssertUnbrokenAtCommitPoint()
    {
        if (_disposed) throw new InvalidOperationException("Directory mutation guard set is unavailable.");
        var events = _guards.Select(guard => guard.EventHandle).ToArray();
        // WAIT_ANY 的零超时检查提供一个同时观察全部目录 oplock 的提交线性化点。
        var wait = WaitForMultipleObjects((uint)events.Length, events, waitAll: false, milliseconds: 0);
        if (wait == WaitTimeout) return;
        if (wait == WaitFailed)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Checking final directory mutation guards failed.");
        if (wait >= WaitObject0 && wait < WaitObject0 + events.Length)
            throw new IOException($"Final owned directory contents changed during verification: {_guards[(int)(wait - WaitObject0)].Path}");
        throw new IOException($"Unexpected final directory mutation guard wait result: {wait}.");
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        foreach (var guard in _guards) guard.Dispose();
        _guards.Clear();
    }

    private sealed class Guard : IDisposable
    {
        private SafeFileHandle? _directoryHandle;
        private SafeWaitHandle? _eventHandle;
        private IntPtr _inputBuffer;
        private IntPtr _outputBuffer;
        private IntPtr _overlappedBuffer;
        private bool _disposed;

        private Guard(
            string path,
            SafeFileHandle directoryHandle,
            SafeWaitHandle eventHandle,
            IntPtr inputBuffer,
            IntPtr outputBuffer,
            IntPtr overlappedBuffer)
        {
            Path = path;
            _directoryHandle = directoryHandle;
            _eventHandle = eventHandle;
            _inputBuffer = inputBuffer;
            _outputBuffer = outputBuffer;
            _overlappedBuffer = overlappedBuffer;
        }

        internal string Path { get; }
        internal IntPtr EventHandle => _eventHandle?.DangerousGetHandle()
            ?? throw new InvalidOperationException("Directory mutation event is unavailable.");

        internal static Guard Acquire(string path)
        {
            var directory = CreateFileW(
                path,
                GenericReadAccess | FileReadAttributesAccess,
                FileShareRead | FileShareWrite | FileShareDelete,
                IntPtr.Zero,
                OpenExisting,
                FileFlagBackupSemantics | FileFlagOpenReparsePoint | FileFlagOverlapped,
                IntPtr.Zero);
            if (directory.IsInvalid)
            {
                var error = Marshal.GetLastWin32Error();
                directory.Dispose();
                throw new Win32Exception(error, $"Opening final directory mutation guard failed: {path}");
            }

            SafeWaitHandle? eventHandle = null;
            var inputBuffer = IntPtr.Zero;
            var outputBuffer = IntPtr.Zero;
            var overlappedBuffer = IntPtr.Zero;
            try
            {
                var identity = WindowsFileIdentityAdapter.GetIdentity(directory);
                if (!identity.IsDirectory || identity.IsReparsePoint)
                    throw new IOException($"Final mutation guard requires a regular directory: {path}");

                eventHandle = CreateEventW(IntPtr.Zero, manualReset: true, initialState: false, null);
                if (eventHandle.IsInvalid)
                    throw new Win32Exception(Marshal.GetLastWin32Error(), $"Creating final directory mutation event failed: {path}");

                var input = new RequestOplockInputBuffer
                {
                    StructureVersion = 1,
                    StructureLength = checked((ushort)Marshal.SizeOf<RequestOplockInputBuffer>()),
                    RequestedOplockLevel = OplockLevelCacheRead,
                    Flags = RequestOplockInputFlagRequest
                };
                inputBuffer = Marshal.AllocHGlobal(Marshal.SizeOf<RequestOplockInputBuffer>());
                Marshal.StructureToPtr(input, inputBuffer, fDeleteOld: false);
                var output = new RequestOplockOutputBuffer
                {
                    StructureVersion = 1,
                    StructureLength = checked((ushort)Marshal.SizeOf<RequestOplockOutputBuffer>())
                };
                outputBuffer = Marshal.AllocHGlobal(Marshal.SizeOf<RequestOplockOutputBuffer>());
                Marshal.StructureToPtr(output, outputBuffer, fDeleteOld: false);
                var overlapped = new OverlappedBuffer { EventHandle = eventHandle.DangerousGetHandle() };
                overlappedBuffer = Marshal.AllocHGlobal(Marshal.SizeOf<OverlappedBuffer>());
                Marshal.StructureToPtr(overlapped, overlappedBuffer, fDeleteOld: false);

                var started = DeviceIoControl(
                    directory,
                    FsctlRequestOplock,
                    inputBuffer,
                    (uint)Marshal.SizeOf<RequestOplockInputBuffer>(),
                    outputBuffer,
                    (uint)Marshal.SizeOf<RequestOplockOutputBuffer>(),
                    IntPtr.Zero,
                    overlappedBuffer);
                var startError = Marshal.GetLastWin32Error();
                if (started)
                    throw new IOException($"Final directory oplock completed before it could guard mutations: {path}");
                if (startError != ErrorIoPending)
                    throw new Win32Exception(startError, $"Requesting final directory oplock failed: {path}");

                return new Guard(path, directory, eventHandle, inputBuffer, outputBuffer, overlappedBuffer);
            }
            catch
            {
                directory.Dispose();
                eventHandle?.Dispose();
                if (inputBuffer != IntPtr.Zero) Marshal.FreeHGlobal(inputBuffer);
                if (outputBuffer != IntPtr.Zero) Marshal.FreeHGlobal(outputBuffer);
                if (overlappedBuffer != IntPtr.Zero) Marshal.FreeHGlobal(overlappedBuffer);
                throw;
            }
        }

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            var directory = _directoryHandle;
            var eventHandle = _eventHandle;
            if (directory is not null && !directory.IsClosed && _overlappedBuffer != IntPtr.Zero)
            {
                var cancelled = CancelIoEx(directory, _overlappedBuffer);
                var cancelError = cancelled ? 0 : Marshal.GetLastWin32Error();
                if (!cancelled && cancelError != ErrorNotFound)
                {
                    directory.Dispose();
                    _directoryHandle = null;
                }
                var wait = WaitForSingleObject(
                    eventHandle!.DangerousGetHandle(),
                    OplockCancelTimeoutMilliseconds);
                if (wait != WaitObject0)
                {
                    // 句柄关闭会继续取消请求；为避免异步内核写入已释放内存，超时时宁可保留小块缓冲区。
                    directory.Dispose();
                    _directoryHandle = null;
                    return;
                }
            }
            directory?.Dispose();
            eventHandle?.Dispose();
            if (_inputBuffer != IntPtr.Zero) Marshal.FreeHGlobal(_inputBuffer);
            if (_outputBuffer != IntPtr.Zero) Marshal.FreeHGlobal(_outputBuffer);
            if (_overlappedBuffer != IntPtr.Zero) Marshal.FreeHGlobal(_overlappedBuffer);
            _directoryHandle = null;
            _eventHandle = null;
            _inputBuffer = IntPtr.Zero;
            _outputBuffer = IntPtr.Zero;
            _overlappedBuffer = IntPtr.Zero;
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RequestOplockInputBuffer
    {
        internal ushort StructureVersion;
        internal ushort StructureLength;
        internal uint RequestedOplockLevel;
        internal uint Flags;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RequestOplockOutputBuffer
    {
        internal ushort StructureVersion;
        internal ushort StructureLength;
        internal uint OriginalOplockLevel;
        internal uint NewOplockLevel;
        internal uint Flags;
        internal uint AccessMode;
        internal ushort ShareMode;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct OverlappedBuffer
    {
        internal IntPtr Internal;
        internal IntPtr InternalHigh;
        internal uint Offset;
        internal uint OffsetHigh;
        internal IntPtr EventHandle;
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
        uint ioControlCode,
        IntPtr inputBuffer,
        uint inputBufferSize,
        IntPtr outputBuffer,
        uint outputBufferSize,
        IntPtr bytesReturned,
        IntPtr overlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern SafeWaitHandle CreateEventW(
        IntPtr eventAttributes,
        [MarshalAs(UnmanagedType.Bool)] bool manualReset,
        [MarshalAs(UnmanagedType.Bool)] bool initialState,
        string? name);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CancelIoEx(SafeFileHandle file, IntPtr overlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForMultipleObjects(
        uint count,
        [In] IntPtr[] handles,
        [MarshalAs(UnmanagedType.Bool)] bool waitAll,
        uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
}

internal static class WindowsFileIdentityAdapter
{
    internal const uint FileAttributeDirectory = 0x00000010;
    internal const uint FileAttributeReparsePoint = 0x00000400;

    private const uint DeleteAccess = 0x00010000;
    private const uint FileReadAttributesAccess = 0x00000080;
    private const uint FileListDirectoryAccess = 0x00000001;
    private const uint GenericReadAccess = 0x80000000;
    private const uint GenericWriteAccess = 0x40000000;
    private const uint SynchronizeAccess = 0x00100000;
    private const uint FileShareRead = 0x00000001;
    private const uint FileShareWrite = 0x00000002;
    private const uint FileShareDelete = 0x00000004;
    private const uint CreateNew = 1;
    private const uint OpenExisting = 3;
    private const uint FileAttributeNormal = 0x00000080;
    private const uint FileFlagBackupSemantics = 0x02000000;
    private const uint FileFlagOpenReparsePoint = 0x00200000;
    private const uint ObjectCaseInsensitive = 0x00000040;
    private const uint FileCreate = 2;
    private const uint FileDirectoryFile = 0x00000001;
    private const uint FileSynchronousIoNonAlert = 0x00000020;
    private const uint FileOpenReparsePoint = 0x00200000;
    private const int ErrorFileNotFound = 2;
    private const int ErrorPathNotFound = 3;

    internal static FileStream OpenFrozenRead(string path) => OpenFrozenRead(path, ownedIdentityLeasePresent: false);

    internal static FileStream OpenOwnedFrozenRead(string path) => OpenFrozenRead(path, ownedIdentityLeasePresent: true);

    private static FileStream OpenFrozenRead(string path, bool ownedIdentityLeasePresent)
    {
        EnsureWindows();
        var handle = CreateFileW(
            path,
            GenericReadAccess | FileReadAttributesAccess,
            ownedIdentityLeasePresent
                ? FileShareRead | FileShareWrite | FileShareDelete
                : FileShareRead,
            IntPtr.Zero,
            OpenExisting,
            FileAttributeNormal | FileFlagOpenReparsePoint,
            IntPtr.Zero);
        if (handle.IsInvalid)
        {
            var error = Marshal.GetLastWin32Error();
            handle.Dispose();
            throw new Win32Exception(error, $"Opening frozen file failed: {path}");
        }

        try
        {
            var identity = GetIdentity(handle);
            if (identity.IsDirectory || identity.IsReparsePoint)
                throw new InvalidDataException($"Frozen source must be a regular, non-reparse file: {path}");
            return new FileStream(handle, FileAccess.Read);
        }
        catch
        {
            handle.Dispose();
            throw;
        }
    }

    internal static WindowsOwnedFile CreateOwnedFile(
        string path,
        bool injectFileIdBeforeReturnFailure = false,
        bool allowDeleteSharing = false,
        bool retainIdentityLease = false)
    {
        EnsureWindows();
        SafeFileHandle? handle = null;
        FileStream? stream = null;
        try
        {
            // 关键所有权：CreateNew 的原始句柄同时持有 WRITE、DELETE 与身份读取权限。
            handle = CreateFileW(
                path,
                GenericWriteAccess | DeleteAccess | FileReadAttributesAccess,
                retainIdentityLease
                    ? FileShareRead
                    : allowDeleteSharing ? FileShareDelete : 0,
                IntPtr.Zero,
                CreateNew,
                FileAttributeNormal,
                IntPtr.Zero);
            if (handle.IsInvalid)
                throw new Win32Exception(Marshal.GetLastWin32Error(), $"CreateFile(CreateNew) failed: {path}");

            var identity = GetIdentity(handle);
            if (injectFileIdBeforeReturnFailure)
                throw new InvalidOperationException("Injected snapshot file-id-before-return failure.");

            SafeFileHandle? identityLease = null;
            if (retainIdentityLease)
            {
                // 写流关闭后仍由原始 CreateNew 句柄冻结对象；非 owning wrapper 只负责流式写入。
                identityLease = handle;
                var streamHandle = new SafeFileHandle(handle.DangerousGetHandle(), ownsHandle: false);
                stream = new FileStream(streamHandle, FileAccess.Write);
            }
            else
            {
                stream = new FileStream(handle, FileAccess.Write);
            }
            var owned = new WindowsOwnedFile(path, stream, identity, identityLease);
            stream = null;
            handle = null;
            return owned;
        }
        catch (Exception primary)
        {
            var cleanupFailures = new List<Exception>();
            if (handle is { IsInvalid: false, IsClosed: false })
            {
                try { MarkDeleteOnClose(handle); }
                catch (Exception cleanup) { cleanupFailures.Add(cleanup); }
            }
            try
            {
                if (stream is not null) stream.Dispose();
                else handle?.Dispose();
            }
            catch (Exception cleanup) { cleanupFailures.Add(cleanup); }

            if (cleanupFailures.Count != 0)
                throw new AggregateException("CreateNew owned file cleanup failed.", new[] { primary }.Concat(cleanupFailures));
            throw;
        }
    }

    internal static void DeleteOwnedFileIfPresent(string path, WindowsFileIdentity expectedIdentity)
    {
        EnsureWindows();
        using var handle = CreateFileW(
            path,
            DeleteAccess | FileReadAttributesAccess,
            0,
            IntPtr.Zero,
            OpenExisting,
            FileAttributeNormal | FileFlagOpenReparsePoint,
            IntPtr.Zero);
        if (handle.IsInvalid)
        {
            var error = Marshal.GetLastWin32Error();
            if (error is ErrorFileNotFound or ErrorPathNotFound) return;
            throw new Win32Exception(error, $"Opening owned file for cleanup failed: {path}");
        }

        var actualIdentity = GetIdentity(handle);
        if (!expectedIdentity.IsSameObject(actualIdentity))
            throw new InvalidOperationException("Refusing to delete a replaced snapshot object.");
        if (actualIdentity.IsDirectory || actualIdentity.IsReparsePoint)
            throw new InvalidOperationException($"Refusing to delete a non-regular owned file: {path}");
        MarkDeleteOnClose(handle);
    }

    internal static WindowsOwnedDirectory CreateOwnedDirectory(string path)
    {
        EnsureWindows();
        var conversionStatus = RtlDosPathNameToNtPathName_U_WithStatus(path, out var ntPath, IntPtr.Zero, IntPtr.Zero);
        if (conversionStatus < 0)
            throw new Win32Exception((int)RtlNtStatusToDosError(conversionStatus), $"Converting owned directory path failed: {path}");

        var ntPathPointer = IntPtr.Zero;
        try
        {
            ntPathPointer = Marshal.AllocHGlobal(Marshal.SizeOf<UnicodeString>());
            Marshal.StructureToPtr(ntPath, ntPathPointer, false);
            var attributes = new ObjectAttributes
            {
                Length = Marshal.SizeOf<ObjectAttributes>(),
                RootDirectory = IntPtr.Zero,
                ObjectName = ntPathPointer,
                Attributes = ObjectCaseInsensitive,
                SecurityDescriptor = IntPtr.Zero,
                SecurityQualityOfService = IntPtr.Zero
            };
            var createStatus = NtCreateFile(
                out var handle,
                DeleteAccess | FileReadAttributesAccess | FileListDirectoryAccess | SynchronizeAccess,
                ref attributes,
                out _,
                IntPtr.Zero,
                0,
                FileShareRead | FileShareWrite,
                FileCreate,
                FileDirectoryFile | FileSynchronousIoNonAlert | FileOpenReparsePoint,
                IntPtr.Zero,
                0);
            if (createStatus < 0)
            {
                handle?.Dispose();
                throw new Win32Exception((int)RtlNtStatusToDosError(createStatus), $"Atomically creating owned directory failed: {path}");
            }

            try
            {
                var identity = GetIdentity(handle);
                if (!identity.IsDirectory || identity.IsReparsePoint)
                    throw new InvalidOperationException("Owned directory must be a regular, non-reparse directory.");
                return new WindowsOwnedDirectory(path, handle, identity);
            }
            catch
            {
                // 初始化失败仍只通过原始 owning handle 回收，不能按 path 猜测所有权。
                try { MarkDeleteOnClose(handle); }
                catch { }
                handle.Dispose();
                throw;
            }
        }
        finally
        {
            if (ntPathPointer != IntPtr.Zero) Marshal.FreeHGlobal(ntPathPointer);
            RtlFreeUnicodeString(ref ntPath);
        }
    }

    internal static WindowsFileIdentity GetIdentity(SafeFileHandle handle)
    {
        if (handle.IsInvalid || handle.IsClosed)
            throw new InvalidOperationException("File identity handle is unavailable.");
        if (!GetFileInformationByHandle(handle, out var information))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "GetFileInformationByHandle failed.");
        var fileIndex = ((ulong)information.FileIndexHigh << 32) | information.FileIndexLow;
        var length = checked((long)(((ulong)information.FileSizeHigh << 32) | information.FileSizeLow));
        return new WindowsFileIdentity(information.FileAttributes, information.VolumeSerialNumber, fileIndex, length);
    }

    internal static SafeFileHandle OpenDirectoryForIdentity(string path)
    {
        var handle = CreateFileW(
            path,
            FileReadAttributesAccess,
            FileShareRead | FileShareWrite | FileShareDelete,
            IntPtr.Zero,
            OpenExisting,
            FileFlagBackupSemantics | FileFlagOpenReparsePoint,
            IntPtr.Zero);
        if (handle.IsInvalid)
        {
            var error = Marshal.GetLastWin32Error();
            handle.Dispose();
            throw new Win32Exception(error, $"Opening directory identity failed: {path}");
        }
        return handle;
    }

    internal static SortedDictionary<string, WindowsFileIdentity> CaptureRegularTree(string root)
    {
        EnsureWindows();
        var result = new SortedDictionary<string, WindowsFileIdentity>(StringComparer.OrdinalIgnoreCase);
        var pending = new Stack<string>();
        pending.Push(root);
        while (pending.TryPop(out var directory))
        {
            foreach (var path in Directory.EnumerateFileSystemEntries(directory))
            {
                using var handle = OpenPathForIdentity(path);
                var identity = GetIdentity(handle);
                if (identity.IsReparsePoint)
                    throw new IOException($"Owned directory tree cannot contain a reparse point: {path}");
                var relative = Path.GetRelativePath(root, path);
                result.Add(relative, identity);
                if (identity.IsDirectory) pending.Push(path);
            }
        }
        return result;
    }

    internal static void AssertRegularTreeMatches(
        string root,
        IReadOnlyDictionary<string, WindowsFileIdentity> expected)
    {
        var current = CaptureRegularTree(root);
        if (current.Count != expected.Count)
            throw new InvalidOperationException("Owned directory tree gained or lost an entry before cleanup.");
        foreach (var (relativePath, expectedIdentity) in expected)
        {
            if (!current.TryGetValue(relativePath, out var actualIdentity) ||
                !expectedIdentity.IsSameObject(actualIdentity) ||
                expectedIdentity.IsDirectory != actualIdentity.IsDirectory)
                throw new InvalidOperationException($"Owned directory entry was replaced before cleanup: {relativePath}");
        }
    }

    private static SafeFileHandle OpenPathForIdentity(string path)
    {
        var handle = CreateFileW(
            path,
            FileReadAttributesAccess,
            FileShareRead | FileShareWrite | FileShareDelete,
            IntPtr.Zero,
            OpenExisting,
            FileFlagBackupSemantics | FileFlagOpenReparsePoint,
            IntPtr.Zero);
        if (handle.IsInvalid)
        {
            var error = Marshal.GetLastWin32Error();
            handle.Dispose();
            throw new Win32Exception(error, $"Opening owned tree entry identity failed: {path}");
        }
        return handle;
    }

    internal static void MarkDeleteOnClose(SafeFileHandle handle)
    {
        var disposition = new FileDispositionInformation { DeleteFile = true };
        if (!SetFileInformationByHandle(
                handle,
                FileInformationByHandleClass.FileDispositionInfo,
                ref disposition,
                (uint)Marshal.SizeOf<FileDispositionInformation>()))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "SetFileInformationByHandle(FileDispositionInfo) failed.");
    }

    internal static void RenameOwnedFileNoReplace(SafeFileHandle handle, string destinationPath)
    {
        EnsureWindows();
        var destination = Path.GetFullPath(destinationPath);
        var nameBytes = System.Text.Encoding.Unicode.GetBytes(destination);
        var fileNameOffset = checked((int)Marshal.OffsetOf<FileRenameInformationHeader>(
            nameof(FileRenameInformationHeader.FileNameLength)) + sizeof(uint));
        // 尾部保留 UTF-16 NUL；FileNameLength 不含它，但部分 Win32 rename 路径仍会读取终止符。
        var bufferBytes = checked(fileNameOffset + nameBytes.Length + sizeof(char));
        var buffer = Marshal.AllocHGlobal(bufferBytes);
        try
        {
            // FILE_RENAME_INFO 的 ReplaceIfExists/Flags 保持 0，内核必须以 no-replace 语义提交 owning handle。
            Marshal.Copy(new byte[bufferBytes], 0, buffer, bufferBytes);
            Marshal.WriteIntPtr(buffer, checked((int)Marshal.OffsetOf<FileRenameInformationHeader>(
                nameof(FileRenameInformationHeader.RootDirectory))), IntPtr.Zero);
            Marshal.WriteInt32(buffer, checked((int)Marshal.OffsetOf<FileRenameInformationHeader>(
                nameof(FileRenameInformationHeader.FileNameLength))), nameBytes.Length);
            Marshal.Copy(nameBytes, 0, IntPtr.Add(buffer, fileNameOffset), nameBytes.Length);
            if (!SetFileInformationByHandle(
                    handle,
                    FileInformationByHandleClass.FileRenameInfo,
                    buffer,
                    checked((uint)bufferBytes)))
                throw new Win32Exception(Marshal.GetLastWin32Error(), $"Renaming owned file without replacement failed: {destination}");
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    private static void EnsureWindows()
    {
        if (!OperatingSystem.IsWindows())
            throw new PlatformNotSupportedException("Kadath Toolchain file identity requires native Windows.");
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

    [StructLayout(LayoutKind.Sequential)]
    private struct FileDispositionInformation
    {
        [MarshalAs(UnmanagedType.U1)]
        internal bool DeleteFile;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FileRenameInformationHeader
    {
        internal uint Flags;
        internal IntPtr RootDirectory;
        internal uint FileNameLength;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct UnicodeString
    {
        internal ushort Length;
        internal ushort MaximumLength;
        internal IntPtr Buffer;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ObjectAttributes
    {
        internal int Length;
        internal IntPtr RootDirectory;
        internal IntPtr ObjectName;
        internal uint Attributes;
        internal IntPtr SecurityDescriptor;
        internal IntPtr SecurityQualityOfService;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IoStatusBlock
    {
        internal IntPtr Status;
        internal IntPtr Information;
    }

    private enum FileInformationByHandleClass
    {
        FileRenameInfo = 3,
        FileDispositionInfo = 4
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
    private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out ByHandleFileInformation information);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetFileInformationByHandle(
        SafeFileHandle handle,
        FileInformationByHandleClass fileInformationClass,
        ref FileDispositionInformation fileInformation,
        uint bufferSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetFileInformationByHandle(
        SafeFileHandle handle,
        FileInformationByHandleClass fileInformationClass,
        IntPtr fileInformation,
        uint bufferSize);

    [DllImport("ntdll.dll")]
    private static extern int NtCreateFile(
        out SafeFileHandle fileHandle,
        uint desiredAccess,
        ref ObjectAttributes objectAttributes,
        out IoStatusBlock ioStatusBlock,
        IntPtr allocationSize,
        uint fileAttributes,
        uint shareAccess,
        uint createDisposition,
        uint createOptions,
        IntPtr eaBuffer,
        uint eaLength);

    [DllImport("ntdll.dll", CharSet = CharSet.Unicode)]
    private static extern int RtlDosPathNameToNtPathName_U_WithStatus(
        string dosFileName,
        out UnicodeString ntFileName,
        IntPtr filePart,
        IntPtr relativeName);

    [DllImport("ntdll.dll")]
    private static extern void RtlFreeUnicodeString(ref UnicodeString unicodeString);

    [DllImport("ntdll.dll")]
    private static extern uint RtlNtStatusToDosError(int status);
}

internal static class ToolchainPathPolicy
{
    private static readonly char[] Separators = [Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar];

    internal static string CanonicalAbsoluteLocalPath(string path, string name, bool requireCanonicalSpelling)
    {
        RejectDevicePath(path, name);
        if (!Path.IsPathFullyQualified(path)) throw new IOException($"{name} must be a fully qualified local path: {path}");
        var full = Path.GetFullPath(path);
        if (requireCanonicalSpelling && !path.Equals(full, StringComparison.OrdinalIgnoreCase))
            throw new IOException($"{name} must use its canonical absolute spelling: {path}");
        RejectReparsePointInExistingPath(full, name);
        return full;
    }

    internal static string ResolveExistingFile(string path, string name, bool requireCanonicalSpelling = false)
    {
        var full = CanonicalAbsoluteLocalPath(path, name, requireCanonicalSpelling);
        if (!File.Exists(full)) throw new FileNotFoundException($"{name} must be an existing regular file.", full);
        var attributes = File.GetAttributes(full);
        if ((attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
            throw new IOException($"{name} must be a regular, non-reparse file: {full}");
        return full;
    }

    internal static string ResolveExistingDirectory(string path, string name, bool requireCanonicalSpelling = false)
    {
        var full = CanonicalAbsoluteLocalPath(path, name, requireCanonicalSpelling);
        if (!Directory.Exists(full)) throw new DirectoryNotFoundException($"{name} must be an existing directory: {full}");
        var attributes = File.GetAttributes(full);
        if ((attributes & FileAttributes.ReparsePoint) != 0)
            throw new IOException($"{name} cannot be a reparse point: {full}");
        return full;
    }

    internal static void RejectDevicePath(string path, string name)
    {
        if (string.IsNullOrWhiteSpace(path)) throw new ArgumentException($"{name} cannot be empty.", nameof(path));
        var windowsSpelling = path.Replace('/', '\\');
        if (windowsSpelling.StartsWith(@"\\", StringComparison.Ordinal) ||
            windowsSpelling.StartsWith(@"\??\", StringComparison.Ordinal))
            throw new IOException($"{name} cannot use UNC, Win32 device, or extended syntax: {path}");

        var root = Path.GetPathRoot(windowsSpelling) ?? string.Empty;
        var relative = windowsSpelling[root.Length..];
        foreach (var component in relative.Split('\\', StringSplitOptions.RemoveEmptyEntries))
        {
            // Win32 会把这些拼写解析成设备或 alternate data stream，不能当作普通本地文件。
            var normalized = component.TrimEnd(' ', '.');
            var stem = normalized.Split('.', 2)[0];
            if (normalized.Contains(':') || IsDosDeviceName(stem))
                throw new IOException($"{name} cannot use a Win32 device component: {path}");
        }
    }

    private static bool IsDosDeviceName(string value) =>
        value.Equals("CON", StringComparison.OrdinalIgnoreCase) ||
        value.Equals("PRN", StringComparison.OrdinalIgnoreCase) ||
        value.Equals("AUX", StringComparison.OrdinalIgnoreCase) ||
        value.Equals("NUL", StringComparison.OrdinalIgnoreCase) ||
        value.Equals("CLOCK$", StringComparison.OrdinalIgnoreCase) ||
        value.Length == 4 && value[3] is >= '1' and <= '9' &&
        (value.StartsWith("COM", StringComparison.OrdinalIgnoreCase) ||
         value.StartsWith("LPT", StringComparison.OrdinalIgnoreCase));

    internal static void RejectReparsePointInExistingPath(string path, string name)
    {
        RejectDevicePath(path, name);
        var full = Path.GetFullPath(path);
        var root = Path.GetPathRoot(full) ?? throw new IOException($"{name} has no filesystem root: {path}");
        RejectExistingReparsePoint(root, name);
        var relative = Path.GetRelativePath(root, full);
        var current = root;
        foreach (var segment in relative.Split(Separators, StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, segment);
            try { RejectExistingReparsePoint(current, name); }
            catch (FileNotFoundException) { break; }
            catch (DirectoryNotFoundException) { break; }
        }
    }

    internal static string CanonicalPreflightPath(string path, string name)
    {
        RejectDevicePath(path, name);
        if (!Path.IsPathFullyQualified(path)) throw new IOException($"{name} must be an absolute local path.");
        return Path.GetFullPath(path.Replace('/', '\\')).TrimEnd('\\').ToLowerInvariant();
    }

    internal static void EnsureDisjoint(string left, string leftName, string right, string rightName)
    {
        if (Contains(left, right) || Contains(right, left))
            throw new IOException($"{leftName} and {rightName} must be disjoint directories: {left} <> {right}");
    }

    internal static bool Contains(string parent, string candidate)
    {
        var normalizedParent = parent.TrimEnd(Separators);
        var normalizedCandidate = candidate.TrimEnd(Separators);
        return normalizedParent.Equals(normalizedCandidate, StringComparison.OrdinalIgnoreCase) ||
               normalizedCandidate.StartsWith(normalizedParent + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
    }

    private static void RejectExistingReparsePoint(string path, string name)
    {
        var attributes = File.GetAttributes(path);
        if ((attributes & FileAttributes.ReparsePoint) != 0)
            throw new IOException($"{name} cannot traverse a reparse point: {path}");
    }
}
