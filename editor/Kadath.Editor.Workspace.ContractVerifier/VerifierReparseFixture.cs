using System.Buffers.Binary;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Kadath.Editor.Workspace.ContractVerifier;

internal static class VerifierReparseFixture
{
    internal static async Task WithFileReplacementAsync(string path, Func<Task> action)
    {
        if (OperatingSystem.IsWindows())
        {
            // Windows 不能用 junction 直接替代文件；移动整个父目录后，原文件路径仍会穿过 junction。
            var parent = Path.GetDirectoryName(path) ?? throw new InvalidOperationException($"Fixture file has no parent: {path}.");
            await WithDirectoryReplacementAsync(parent, action);
            return;
        }

        var realPath = $"{path}.real-{Guid.NewGuid():N}";
        File.Move(path, realPath);
        File.CreateSymbolicLink(path, realPath);
        try
        {
            await action();
        }
        finally
        {
            File.Delete(path);
            File.Move(realPath, path);
        }
    }

    internal static async Task WithDirectoryReplacementAsync(string path, Func<Task> action)
    {
        var target = $"{path}.junction-target-{Guid.NewGuid():N}";
        Directory.Move(path, target);
        var linked = false;
        try
        {
            CreateDirectoryLink(path, target);
            linked = true;
            await action();
        }
        finally
        {
            if (linked) DeleteDirectoryLink(path);
            if (Directory.Exists(target)) Directory.Move(target, path);
        }
    }

    internal static async Task WithDirectoryAliasAsync(string linkPath, string targetPath, Func<Task> action)
    {
        CreateDirectoryLink(linkPath, targetPath);
        try
        {
            await action();
        }
        finally
        {
            DeleteDirectoryLink(linkPath);
            if (!Directory.Exists(targetPath)) throw new IOException($"Reparse fixture deleted its target: {targetPath}.");
        }
    }

    internal static async Task WithFileAliasAsync(string linkPath, string targetPath, Func<Task> action)
    {
        if (!OperatingSystem.IsWindows())
        {
            File.CreateSymbolicLink(linkPath, targetPath);
            try
            {
                await action();
            }
            finally
            {
                File.Delete(linkPath);
            }
            return;
        }

        // Windows 文件 fixture 使用“外部目录 + junction + 文件路径”，避免申请 symlink privilege。
        var externalDirectory = Path.Combine(
            Path.GetDirectoryName(targetPath) ?? throw new InvalidOperationException($"Fixture target has no parent: {targetPath}."),
            $".kadath-junction-file-{Guid.NewGuid():N}");
        var linkDirectory = $"{linkPath}.junction-{Guid.NewGuid():N}";
        Directory.CreateDirectory(externalDirectory);
        File.Copy(targetPath, Path.Combine(externalDirectory, Path.GetFileName(linkPath)));
        try
        {
            await WithDirectoryAliasAsync(linkDirectory, externalDirectory, action);
        }
        finally
        {
            if (Directory.Exists(externalDirectory)) Directory.Delete(externalDirectory, true);
        }
    }

    private static void CreateDirectoryLink(string linkPath, string targetPath)
    {
        if (OperatingSystem.IsWindows()) CreateWindowsJunction(linkPath, targetPath);
        else Directory.CreateSymbolicLink(linkPath, targetPath);
    }

    private static void CreateWindowsJunction(string linkPath, string targetPath)
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
            if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), $"Failed to open junction fixture: {linkPath}.");

            var buffer = BuildMountPointBuffer(fullTarget);
            if (!DeviceIoControl(handle, FsctlSetReparsePoint, buffer, buffer.Length, IntPtr.Zero, 0, out _, IntPtr.Zero))
                throw new Win32Exception(Marshal.GetLastWin32Error(), $"Failed to set junction fixture: {linkPath}.");
            if ((File.GetAttributes(linkPath) & FileAttributes.ReparsePoint) == 0)
                throw new IOException($"Junction fixture does not expose ReparsePoint: {linkPath}.");
        }
        catch
        {
            if (Directory.Exists(linkPath)) Directory.Delete(linkPath);
            throw;
        }
    }

    private static byte[] BuildMountPointBuffer(string targetPath)
    {
        var substitute = $@"\??\{targetPath}";
        var substituteBytes = Encoding.Unicode.GetBytes(substitute);
        var printBytes = Encoding.Unicode.GetBytes(targetPath);
        var pathBufferBytes = checked(substituteBytes.Length + sizeof(char) + printBytes.Length + sizeof(char));
        var reparseDataBytes = checked(8 + pathBufferBytes);
        var buffer = new byte[checked(8 + reparseDataBytes)];

        // Mount-point reparse buffer：前 8 字节是通用 header，随后是名称 offset/length 和 UTF-16 路径缓冲。
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

    private static void DeleteDirectoryLink(string path)
    {
        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) == 0)
            throw new IOException($"Refusing to delete a non-reparse fixture directory: {path}.");
        Directory.Delete(path);
    }

    private const uint GenericWrite = 0x40000000;
    private const uint FileShareRead = 0x00000001;
    private const uint FileShareWrite = 0x00000002;
    private const uint FileShareDelete = 0x00000004;
    private const uint OpenExisting = 3;
    private const uint FileFlagOpenReparsePoint = 0x00200000;
    private const uint FileFlagBackupSemantics = 0x02000000;
    private const uint FsctlSetReparsePoint = 0x000900A4;
    private const uint IoReparseTagMountPoint = 0xA0000003;

    // 关键 P/Invoke：以 reparse-point 自身打开空目录，再用 FSCTL_SET_REPARSE_POINT 写入 junction buffer。
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
