using System.Buffers.Binary;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Kadath.Editor.Toolchain.ContractVerifier;

internal static class VerifierJunction
{
    internal static void WithDirectoryAlias(string linkPath, string targetPath, Action action)
    {
        Create(linkPath, targetPath);
        try { action(); }
        finally { Delete(linkPath); }
    }

    private static void Create(string linkPath, string targetPath)
    {
        var fullTarget = Path.GetFullPath(targetPath).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        if (fullTarget.StartsWith("\\\\", StringComparison.Ordinal))
            throw new InvalidOperationException("Verifier junction target must be local.");
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
            if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), $"Failed to open junction fixture: {linkPath}");
            var buffer = BuildMountPointBuffer(fullTarget);
            if (!DeviceIoControl(handle, FsctlSetReparsePoint, buffer, buffer.Length, IntPtr.Zero, 0, out _, IntPtr.Zero))
                throw new Win32Exception(Marshal.GetLastWin32Error(), $"Failed to set junction fixture: {linkPath}");
            ContractAssert.Require((File.GetAttributes(linkPath) & FileAttributes.ReparsePoint) != 0,
                "junction fixture did not expose ReparsePoint");
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
        // 关键安全 fixture：仅给空目录写 mount-point reparse buffer，不启动 shell 或依赖管理员 symlink privilege。
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

    private static void Delete(string path)
    {
        ContractAssert.Require((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0,
            $"refusing to delete a non-reparse fixture directory: {path}");
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
