[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackageRoot,

    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory,

    [Parameter(Mandatory = $true)]
    [string]$ExtractDirectory
)

$ErrorActionPreference = "Stop"

if ($null -eq ('Kadath.RuntimeArchive.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Kadath.RuntimeArchive
{
    public struct FileIdentity
    {
        public uint FileAttributes;
        public uint VolumeSerialNumber;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    public sealed class OwnedDirectory : IDisposable
    {
        private SafeFileHandle handle;
        public string Path { get; private set; }
        public uint VolumeSerialNumber { get; private set; }
        public uint FileIndexHigh { get; private set; }
        public uint FileIndexLow { get; private set; }

        internal OwnedDirectory(string path, SafeFileHandle ownedHandle, FileIdentity identity)
        {
            Path = path;
            handle = ownedHandle;
            VolumeSerialNumber = identity.VolumeSerialNumber;
            FileIndexHigh = identity.FileIndexHigh;
            FileIndexLow = identity.FileIndexLow;
        }

        private void AssertLiveIdentity(FileIdentity identity)
        {
            if ((identity.FileAttributes & Native.FileAttributeDirectory) == 0 ||
                (identity.FileAttributes & Native.FileAttributeReparsePoint) != 0 ||
                identity.VolumeSerialNumber != VolumeSerialNumber ||
                identity.FileIndexHigh != FileIndexHigh ||
                identity.FileIndexLow != FileIndexLow)
                throw new InvalidOperationException("Owned directory identity changed or became reparse-backed.");
        }

        public void VerifyPath()
        {
            if (handle == null || handle.IsInvalid || handle.IsClosed)
                throw new InvalidOperationException("Owned directory handle is unavailable.");
            using (SafeFileHandle pathHandle = Native.OpenDirectoryForIdentity(Path))
                AssertLiveIdentity(Native.GetFileIdentity(pathHandle));
            AssertLiveIdentity(Native.GetFileIdentity(handle));
        }

        public void DeleteEmpty()
        {
            VerifyPath();
            Native.MarkDeleteOnClose(handle);
            handle.Dispose();
        }

        public void Release()
        {
            if (handle != null && !handle.IsClosed) handle.Dispose();
        }

        public void Dispose() { Release(); }
    }

    public static class Native
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct ByHandleFileInformation
        {
            public uint FileAttributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
            public uint VolumeSerialNumber;
            public uint FileSizeHigh;
            public uint FileSizeLow;
            public uint NumberOfLinks;
            public uint FileIndexHigh;
            public uint FileIndexLow;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct FileDispositionInformation
        {
            [MarshalAs(UnmanagedType.U1)]
            public bool DeleteFile;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct UnicodeString
        {
            public ushort Length;
            public ushort MaximumLength;
            public IntPtr Buffer;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ObjectAttributes
        {
            public int Length;
            public IntPtr RootDirectory;
            public IntPtr ObjectName;
            public uint Attributes;
            public IntPtr SecurityDescriptor;
            public IntPtr SecurityQualityOfService;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct IoStatusBlock
        {
            public IntPtr Status;
            public IntPtr Information;
        }

        private enum FileInformationByHandleClass
        {
            FileDispositionInfo = 4,
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFile(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out ByHandleFileInformation information);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetFileInformationByHandle(
            SafeFileHandle handle,
            FileInformationByHandleClass fileInformationClass,
            ref FileDispositionInformation fileInformation,
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

        internal const uint FileAttributeDirectory = 0x00000010;
        internal const uint FileAttributeReparsePoint = 0x00000400;
        private const uint DeleteAccess = 0x00010000;
        private const uint FileReadAttributesAccess = 0x00000080;
        private const uint FileListDirectoryAccess = 0x00000001;
        private const uint SynchronizeAccess = 0x00100000;
        private const uint FileShareRead = 0x00000001;
        private const uint FileShareWrite = 0x00000002;
        private const uint FileShareDelete = 0x00000004;
        private const uint OpenExisting = 3;
        private const uint FileFlagBackupSemantics = 0x02000000;
        private const uint FileFlagOpenReparsePoint = 0x00200000;
        private const uint ObjectCaseInsensitive = 0x00000040;
        private const uint FileCreate = 2;
        private const uint FileDirectoryFile = 0x00000001;
        private const uint FileSynchronousIoNonAlert = 0x00000020;
        private const uint FileOpenReparsePoint = 0x00200000;

        public static FileIdentity GetFileIdentity(SafeFileHandle handle)
        {
            if (handle == null || handle.IsInvalid || handle.IsClosed)
                throw new InvalidOperationException("File identity handle is unavailable.");
            if (!GetFileInformationByHandle(handle, out ByHandleFileInformation information))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "GetFileInformationByHandle failed.");
            return new FileIdentity
            {
                FileAttributes = information.FileAttributes,
                VolumeSerialNumber = information.VolumeSerialNumber,
                FileIndexHigh = information.FileIndexHigh,
                FileIndexLow = information.FileIndexLow
            };
        }

        internal static SafeFileHandle OpenDirectoryForIdentity(string path)
        {
            SafeFileHandle handle = CreateFile(
                path,
                FileReadAttributesAccess,
                FileShareRead | FileShareWrite | FileShareDelete,
                IntPtr.Zero,
                OpenExisting,
                FileFlagBackupSemantics | FileFlagOpenReparsePoint,
                IntPtr.Zero);
            if (handle.IsInvalid)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Opening owned directory identity failed.");
            return handle;
        }

        public static OwnedDirectory CreateOwnedDirectory(string path)
        {
            int conversionStatus = RtlDosPathNameToNtPathName_U_WithStatus(path, out UnicodeString ntPath, IntPtr.Zero, IntPtr.Zero);
            if (conversionStatus < 0)
                throw new Win32Exception((int)RtlNtStatusToDosError(conversionStatus), "Converting owned directory path failed.");
            IntPtr ntPathPointer = IntPtr.Zero;
            try
            {
                ntPathPointer = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(UnicodeString)));
                Marshal.StructureToPtr(ntPath, ntPathPointer, false);
                ObjectAttributes attributes = new ObjectAttributes
                {
                    Length = Marshal.SizeOf(typeof(ObjectAttributes)),
                    RootDirectory = IntPtr.Zero,
                    ObjectName = ntPathPointer,
                    Attributes = ObjectCaseInsensitive,
                    SecurityDescriptor = IntPtr.Zero,
                    SecurityQualityOfService = IntPtr.Zero
                };
                int createStatus = NtCreateFile(
                    out SafeFileHandle handle,
                    DeleteAccess | FileReadAttributesAccess | FileListDirectoryAccess | SynchronizeAccess,
                    ref attributes,
                    out IoStatusBlock _,
                    IntPtr.Zero,
                    0,
                    FileShareRead | FileShareWrite,
                    FileCreate,
                    FileDirectoryFile | FileSynchronousIoNonAlert | FileOpenReparsePoint,
                    IntPtr.Zero,
                    0);
                if (createStatus < 0)
                {
                    handle.Dispose();
                    throw new Win32Exception((int)RtlNtStatusToDosError(createStatus), "Atomically creating owned directory failed.");
                }
                try
                {
                    FileIdentity identity = GetFileIdentity(handle);
                    if ((identity.FileAttributes & FileAttributeDirectory) == 0 ||
                        (identity.FileAttributes & FileAttributeReparsePoint) != 0)
                        throw new InvalidOperationException("Owned directory must be a regular, non-reparse directory.");
                    return new OwnedDirectory(path, handle, identity);
                }
                catch
                {
                    // 原子创建已返回 owning handle；初始化失败也只通过该句柄回收对象。
                    try { MarkDeleteOnClose(handle); } catch { }
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

        internal static void MarkDeleteOnClose(SafeFileHandle handle)
        {
            FileDispositionInformation disposition = new FileDispositionInformation { DeleteFile = true };
            if (!SetFileInformationByHandle(
                handle,
                FileInformationByHandleClass.FileDispositionInfo,
                ref disposition,
                (uint)Marshal.SizeOf(typeof(FileDispositionInformation))))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Deleting owned empty directory by handle failed.");
        }
    }
}
'@
}

function Resolve-ExistingDirectory([string]$Path, [string]$Name) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "$Name does not exist: $Path"
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Normalize-RelativePath([string]$Root, [string]$Path) {
    return [IO.Path]::GetRelativePath($Root, $Path).Replace('\', '/')
}

function Assert-NoWin32DevicePath([string]$Path, [string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw "$Name cannot be empty" }
    $windowsSpelling = $Path.Replace('/', '\')
    if ($windowsSpelling.StartsWith('\\', [StringComparison]::Ordinal) -or
        $windowsSpelling.StartsWith('\??\', [StringComparison]::Ordinal)) {
        throw "$Name cannot use a UNC, Win32 device, or extended path: $Path"
    }
}

function Assert-NoReparsePointInExistingPath([string]$Path, [string]$Name) {
    Assert-NoWin32DevicePath $Path $Name
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    $relative = [IO.Path]::GetRelativePath($root, $full)
    $current = $root
    if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "$Name root cannot be a reparse point: $current" }
    foreach ($segment in $relative.Split([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar), [StringSplitOptions]::RemoveEmptyEntries)) {
        $current = Join-Path $current $segment
        if (-not (Test-Path -LiteralPath $current)) { break }
        $info = Get-Item -LiteralPath $current -Force
        if (($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Name cannot traverse a reparse point: $current" }
    }
}

function Test-DirectoryContains([string]$Parent, [string]$Candidate) {
    $normalizedParent = $Parent.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $normalizedCandidate = $Candidate.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if ($normalizedParent.Equals($normalizedCandidate, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $normalizedCandidate.StartsWith($normalizedParent + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-DisjointDirectories([string]$Left, [string]$LeftName, [string]$Right, [string]$RightName) {
    if ((Test-DirectoryContains $Left $Right) -or (Test-DirectoryContains $Right $Left)) {
        throw "$LeftName and $RightName must be disjoint directories: $Left <> $Right"
    }
}

function Assert-RequiredPackageFiles([string]$Root, [string[]]$RequiredFiles) {
    foreach ($relative in $RequiredFiles) {
        $path = Join-Path $Root ($relative.Replace('/', '\'))
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Package is missing required file: $relative"
        }
    }
}

function Get-StableFileIdentityFromHandle([IO.FileStream]$Stream) {
    $nativeIdentity = [Kadath.RuntimeArchive.Native]::GetFileIdentity($Stream.SafeFileHandle)
    if (($nativeIdentity.FileAttributes -band [uint32][IO.FileAttributes]::Directory) -ne 0 -or
        ($nativeIdentity.FileAttributes -band [uint32][IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Package snapshot source handle must identify a regular, non-reparse file'
    }
    $Stream.Position = 0
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $sha256 = [Convert]::ToHexString($algorithm.ComputeHash($Stream)).ToLowerInvariant()
    } finally {
        $algorithm.Dispose()
    }
    $length = $Stream.Length
    $Stream.Position = 0
    return [pscustomobject][ordered]@{
        Length = [int64]$length
        Sha256 = $sha256
        VolumeSerialNumber = [uint32]$nativeIdentity.VolumeSerialNumber
        FileIndexHigh = [uint32]$nativeIdentity.FileIndexHigh
        FileIndexLow = [uint32]$nativeIdentity.FileIndexLow
    }
}

function Test-StableFileIdentityEqual([object]$Left, [object]$Right) {
    return [int64]$Left.Length -eq [int64]$Right.Length -and
        [string]$Left.Sha256 -ceq [string]$Right.Sha256 -and
        [uint32]$Left.VolumeSerialNumber -eq [uint32]$Right.VolumeSerialNumber -and
        [uint32]$Left.FileIndexHigh -eq [uint32]$Right.FileIndexHigh -and
        [uint32]$Left.FileIndexLow -eq [uint32]$Right.FileIndexLow
}

function Get-PackageFileSet([string]$Root) {
    Assert-NoReparsePointInExistingPath $Root 'Package snapshot source root'
    $items = @(Get-ChildItem -LiteralPath $Root -Force -Recurse)
    $reparseEntries = @($items | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })
    if ($reparseEntries.Count -ne 0) {
        throw "Package tree cannot contain a reparse point: $($reparseEntries[0].FullName)"
    }

    $entries = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $items) {
        if ($item.PSIsContainer) { continue }
        $relative = Normalize-RelativePath $Root $item.FullName
        if ([IO.Path]::IsPathFullyQualified($relative) -or
            $relative -eq '..' -or
            $relative.StartsWith('../', [StringComparison]::Ordinal)) {
            throw "Package snapshot path escapes the package root: $relative"
        }
        if (-not $seen.Add($relative)) { throw "Package snapshot contains a duplicate relative path: $relative" }
        $entries.Add([pscustomobject][ordered]@{ RelativePath = $relative; FullPath = $item.FullName })
    }
    if ($entries.Count -eq 0) { throw "Package root contains no files: $Root" }
    return @($entries | Sort-Object RelativePath -CaseSensitive)
}

function Open-PackageSourceSnapshot([string]$SourceRoot) {
    $preFiles = @(Get-PackageFileSet $SourceRoot)
    $preIdentity = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $preFiles) {
        Assert-NoReparsePointInExistingPath $file.FullPath 'Package pre-identity file'
        $stream = $null
        try {
            $stream = [IO.File]::Open($file.FullPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            $preIdentity.Add($file.RelativePath, (Get-StableFileIdentityFromHandle $stream))
        } finally {
            if ($stream) { $stream.Dispose() }
        }
    }

    $retainedStreams = [Collections.Generic.List[IO.FileStream]]::new()
    $retainedByRelative = [Collections.Generic.Dictionary[string,IO.FileStream]]::new([StringComparer]::OrdinalIgnoreCase)
    try {
        # 全集合冻结：门禁、staging 复制都复用这些 retained handle，首次写入前不再回到 live path 取关键字节。
        foreach ($file in $preFiles) {
            Assert-NoReparsePointInExistingPath $file.FullPath 'Package retained source file'
            $stream = [IO.File]::Open($file.FullPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            $retainedStreams.Add($stream)
            $retainedIdentity = Get-StableFileIdentityFromHandle $stream
            if (-not (Test-StableFileIdentityEqual $preIdentity[$file.RelativePath] $retainedIdentity)) {
                throw "Package file changed while acquiring the whole-package freeze: $($file.RelativePath)"
            }
            $retainedByRelative.Add($file.RelativePath, $stream)
        }

        # 全部句柄到位后再次核对文件集合；新增、删除或重命名均 fail-closed。
        $postFiles = @(Get-PackageFileSet $SourceRoot)
        if ($postFiles.Count -ne $preFiles.Count) { throw 'Package file set changed while acquiring the whole-package freeze' }
        foreach ($file in $postFiles) {
            if (-not $preIdentity.ContainsKey($file.RelativePath)) {
                throw "Package file set changed while acquiring the whole-package freeze: $($file.RelativePath)"
            }
        }

        return [pscustomobject][ordered]@{
            Files = $preFiles
            IdentityByRelative = $preIdentity
            Streams = $retainedStreams
            StreamByRelative = $retainedByRelative
        }
    } catch {
        # 获取冻结集合中途失败时，也必须释放此前已经打开的所有 source handle。
        $disposeErrors = [Collections.Generic.List[Exception]]::new()
        foreach ($stream in $retainedStreams) {
            try { $stream.Dispose() } catch { $disposeErrors.Add($_.Exception) }
        }
        if ($disposeErrors.Count -ne 0) {
            [Exception[]]$failures = @($_.Exception) + @($disposeErrors)
            throw [AggregateException]::new('Package snapshot acquisition failed and retained handles could not all be released', $failures)
        }
        throw
    }
}

function Close-PackageSourceSnapshot([object]$Snapshot) {
    if (-not $Snapshot) { return }
    $disposeErrors = [Collections.Generic.List[Exception]]::new()
    foreach ($stream in $Snapshot.Streams) {
        try { $stream.Dispose() } catch { $disposeErrors.Add($_.Exception) }
    }
    if ($disposeErrors.Count -eq 1) { throw $disposeErrors[0] }
    if ($disposeErrors.Count -gt 1) { throw [AggregateException]::new('Package retained handle release failures', $disposeErrors) }
}

function Read-PackageSnapshotBytes([object]$Snapshot, [string]$RelativePath) {
    if (-not $Snapshot.StreamByRelative.ContainsKey($RelativePath)) {
        throw "Package snapshot is missing required file: $RelativePath"
    }
    $stream = $Snapshot.StreamByRelative[$RelativePath]
    $stream.Position = 0
    $memory = [IO.MemoryStream]::new()
    try {
        $stream.CopyTo($memory)
        return $memory.ToArray()
    } finally {
        $memory.Dispose()
        $stream.Position = 0
    }
}

function Copy-PackageToOwnedSnapshot([object]$SourceSnapshot, [string]$SnapshotRoot) {
    foreach ($file in $SourceSnapshot.Files) {
        $destination = Join-Path $SnapshotRoot ($file.RelativePath.Replace('/', '\'))
        $destinationParent = Split-Path -Parent $destination
        [IO.Directory]::CreateDirectory($destinationParent) | Out-Null
        $destinationStream = $null
        try {
            $sourceStream = $SourceSnapshot.StreamByRelative[$file.RelativePath]
            $sourceStream.Position = 0
            $destinationStream = [IO.FileStream]::new(
                $destination,
                [IO.FileMode]::CreateNew,
                [IO.FileAccess]::Write,
                [IO.FileShare]::None,
                1MB,
                [IO.FileOptions]::WriteThrough)
            $sourceStream.CopyTo($destinationStream)
            $destinationStream.Flush($true)
            $sourceStream.Position = 0
        } finally {
            if ($destinationStream) { $destinationStream.Dispose() }
        }
    }

    Assert-NoReparsePointInExistingPath $SnapshotRoot 'Package snapshot'
    $snapshotReparseEntries = @(Get-ChildItem -LiteralPath $SnapshotRoot -Force -Recurse | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })
    if ($snapshotReparseEntries.Count -ne 0) {
        throw "Package snapshot cannot contain a reparse point: $($snapshotReparseEntries[0].FullName)"
    }
}

function Assert-ReleasePackageMarkerIdentity(
    [byte[]]$ProfileMarkerBytes,
    [string]$RuntimeSha256,
    [string]$TextureSourceSha256,
    [string]$TextureArtifactSha256
) {
    if ($profileMarkerBytes.Length -eq 0 -or $profileMarkerBytes.Length -gt 65536) {
        throw 'Runtime build profile marker must contain 1..65536 bytes'
    }

    try {
        $profileMarkerJson = [Text.UTF8Encoding]::new($false, $true).GetString($profileMarkerBytes)
        $profileMarkerJsonDocument = [System.Text.Json.JsonDocument]::Parse($profileMarkerJson)
        try {
            $rootElement = $profileMarkerJsonDocument.RootElement
            if ($rootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { throw 'root must be an object' }
            $expectedProfileFields = [string[]]@('Version', 'Optimize', 'TextureProfile', 'RuntimeExeSha256', 'TextureSourceSha256', 'TextureArtifactSha256', 'VertexShaderSourceSha256', 'FragmentShaderSourceSha256', 'BuildPreflightSidecarSha256')
            $actualProfileFields = @($rootElement.EnumerateObject() | ForEach-Object { $_.Name })
            $uniqueProfileFields = @($actualProfileFields | Sort-Object -Unique -CaseSensitive)
            if ($actualProfileFields.Count -ne 9 -or $uniqueProfileFields.Count -ne 9 -or
                @(Compare-Object -ReferenceObject ($expectedProfileFields | Sort-Object) -DifferenceObject ($actualProfileFields | Sort-Object) -CaseSensitive).Count -ne 0) {
                throw 'properties must be unique and exactly match the nine schema v1 names'
            }
            $versionElement = $rootElement.GetProperty('Version')
            if ($versionElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Number -or $versionElement.GetInt32() -ne 1) { throw 'Version must be the JSON number 1' }
            $stringFields = $expectedProfileFields | Where-Object { $_ -cne 'Version' }
            foreach ($field in $stringFields) {
                if ($rootElement.GetProperty($field).ValueKind -ne [System.Text.Json.JsonValueKind]::String) { throw "$field must be a JSON string" }
            }
            $profileMarker = [pscustomobject][ordered]@{
                Version = 1
                Optimize = $rootElement.GetProperty('Optimize').GetString()
                TextureProfile = $rootElement.GetProperty('TextureProfile').GetString()
                RuntimeExeSha256 = $rootElement.GetProperty('RuntimeExeSha256').GetString()
                TextureSourceSha256 = $rootElement.GetProperty('TextureSourceSha256').GetString()
                TextureArtifactSha256 = $rootElement.GetProperty('TextureArtifactSha256').GetString()
                VertexShaderSourceSha256 = $rootElement.GetProperty('VertexShaderSourceSha256').GetString()
                FragmentShaderSourceSha256 = $rootElement.GetProperty('FragmentShaderSourceSha256').GetString()
                BuildPreflightSidecarSha256 = $rootElement.GetProperty('BuildPreflightSidecarSha256').GetString()
            }
        } finally {
            $profileMarkerJsonDocument.Dispose()
        }
    } catch {
        throw "Runtime build profile marker is not strict UTF-8 exact-nine JSON schema v1: $($_.Exception.Message)"
    }

    if ([int]$profileMarker.Version -ne 1 -or
        [string]$profileMarker.Optimize -cne 'ReleaseSafe' -or
        [string]$profileMarker.TextureProfile -cne 'release' -or
        [string]$profileMarker.RuntimeExeSha256 -cne $runtimeSha256 -or
        [string]$profileMarker.TextureSourceSha256 -cne $textureSourceSha256 -or
        [string]$profileMarker.TextureArtifactSha256 -cne $textureArtifactSha256 -or
        [string]$profileMarker.VertexShaderSourceSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        [string]$profileMarker.FragmentShaderSourceSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        [string]$profileMarker.BuildPreflightSidecarSha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'Runtime archive requires a sidecar-bound ReleaseSafe marker matching the package executable, PNG, and KDAT identities'
    }
}

function Assert-ReleasePackageIdentity([string]$Root, [string[]]$RequiredFiles) {
    Assert-RequiredPackageFiles $Root $RequiredFiles
    $runtimePath = Join-Path $Root 'bin\kadath.exe'
    $textureSourcePath = Join-Path $Root 'bin\assets\renderer2d\test.png'
    $textureArtifactPath = Join-Path $Root 'bin\assets\renderer2d\test.texture'
    $profileMarkerPath = Join-Path $Root 'bin\kadath-runtime-build-profile.json'
    Assert-ReleasePackageMarkerIdentity `
        ([IO.File]::ReadAllBytes($profileMarkerPath)) `
        ((Get-FileHash -LiteralPath $runtimePath -Algorithm SHA256).Hash.ToLowerInvariant()) `
        ((Get-FileHash -LiteralPath $textureSourcePath -Algorithm SHA256).Hash.ToLowerInvariant()) `
        ((Get-FileHash -LiteralPath $textureArtifactPath -Algorithm SHA256).Hash.ToLowerInvariant())
}

function Assert-ReleasePackageSnapshotIdentity([object]$Snapshot, [string[]]$RequiredFiles) {
    foreach ($relative in $RequiredFiles) {
        if (-not $Snapshot.StreamByRelative.ContainsKey($relative)) {
            throw "Package snapshot is missing required file: $relative"
        }
    }

    # 关键身份全部来自仍持有的同一组 source handles；通过前不会创建任何归档目录或 byte。
    Assert-ReleasePackageMarkerIdentity `
        (Read-PackageSnapshotBytes $Snapshot 'bin/kadath-runtime-build-profile.json') `
        ([string]$Snapshot.IdentityByRelative['bin/kadath.exe'].Sha256) `
        ([string]$Snapshot.IdentityByRelative['bin/assets/renderer2d/test.png'].Sha256) `
        ([string]$Snapshot.IdentityByRelative['bin/assets/renderer2d/test.texture'].Sha256)
}

function New-OwnedDirectoryRoot(
    [string]$Path,
    [string]$Name,
    [bool]$MarksArchiveWriteStart = $false
) {
    $parent = Split-Path -Parent $Path
    Assert-NoReparsePointInExistingPath $parent "$Name parent before create"
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "$Name parent must exist before the owned directory is created: $parent"
    }
    $parent = Resolve-ExistingDirectory $parent "$Name parent after create"
    Assert-NoReparsePointInExistingPath $parent "$Name parent after create"
    if (Test-Path -LiteralPath $Path) { throw "$Name appeared before owned create: $Path" }

    $owner = $null
    try {
        # 所有路径门禁已完成；NtCreateFile 在一次调用中原子创建目录并返回禁止 delete/rename share 的 owning handle。
        if ($MarksArchiveWriteStart) {
            $script:archiveWriteStarted = $true
        }
        $owner = [Kadath.RuntimeArchive.Native]::CreateOwnedDirectory($Path)
        $owner.VerifyPath()
        return $owner
    } catch {
        if ($owner) { $owner.Release() }
        throw
    }
}

function Remove-OwnedDirectory([Kadath.RuntimeArchive.OwnedDirectory]$Owner, [string]$Name) {
    if (-not $Owner) { return }
    $Owner.VerifyPath()
    $path = $Owner.Path
    $items = @(Get-ChildItem -LiteralPath $path -Force -Recurse)
    $reparseEntries = @($items | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })
    if ($reparseEntries.Count -ne 0) {
        throw "$Name contains a reparse point; refusing cleanup and retaining the owned root: $($reparseEntries[0].FullName)"
    }

    # live root handle 阻止根目录被 rename/delete；先清空子项，再由同一 handle 标记空目录删除。
    foreach ($child in @(Get-ChildItem -LiteralPath $path -Force)) {
        Remove-Item -LiteralPath $child.FullName -Recurse -Force
    }
    $Owner.VerifyPath()
    $remaining = @(Get-ChildItem -LiteralPath $path -Force)
    if ($remaining.Count -ne 0) {
        throw "$Name changed while clearing; refusing handle deletion and retaining the root: $path"
    }
    $Owner.DeleteEmpty()
    if (Test-Path -LiteralPath $path) {
        throw "$Name path reappeared after handle deletion; refusing to delete the replacement: $path"
    }
}

$archiveWriteStarted = $false
$staging = $null
$stagingRootOwner = $null
$outputRootOwner = $null
$extractRootOwner = $null
$packageSourceSnapshot = $null
$archiveCompleted = $false
try {

Assert-NoWin32DevicePath $PackageRoot 'Package root'
Assert-NoWin32DevicePath $OutputDirectory 'Output directory'
Assert-NoWin32DevicePath $ExtractDirectory 'Extract directory'
if (-not [IO.Path]::IsPathFullyQualified($PackageRoot) -or
    -not [IO.Path]::IsPathFullyQualified($OutputDirectory) -or
    -not [IO.Path]::IsPathFullyQualified($ExtractDirectory)) {
    throw 'PackageRoot, OutputDirectory, and ExtractDirectory must be fully qualified local paths'
}
$packageInput = [IO.Path]::GetFullPath($PackageRoot)
$output = [IO.Path]::GetFullPath($OutputDirectory)
$extract = [IO.Path]::GetFullPath($ExtractDirectory)

# 关键事务前置：所有路径关系和现存 ancestor 在首次写入前完成校验。
Assert-NoReparsePointInExistingPath $packageInput 'Package root'
Assert-NoReparsePointInExistingPath $output 'Output directory'
Assert-NoReparsePointInExistingPath $extract 'Extract directory'
$package = Resolve-ExistingDirectory $packageInput "Package root"
Assert-DisjointDirectories $package 'Package root' $output 'Output directory'
Assert-DisjointDirectories $package 'Package root' $extract 'Extract directory'
Assert-DisjointDirectories $output 'Output directory' $extract 'Extract directory'

if (Test-Path -LiteralPath $output) {
    throw "Output directory already exists; refusing to overwrite: $output"
}
if (Test-Path -LiteralPath $extract) {
    throw "Extract directory already exists; refusing to overwrite: $extract"
}
foreach ($parentRequirement in @(
    [pscustomobject]@{ Path = (Split-Path -Parent $output); Name = 'Output directory parent' },
    [pscustomobject]@{ Path = (Split-Path -Parent $extract); Name = 'Extract directory parent' }
)) {
    Assert-NoReparsePointInExistingPath $parentRequirement.Path $parentRequirement.Name
    if (-not (Test-Path -LiteralPath $parentRequirement.Path -PathType Container)) {
        throw "$($parentRequirement.Name) must exist before archive writing: $($parentRequirement.Path)"
    }
}

$reparseEntries = @(Get-ChildItem -LiteralPath $package -Force -Recurse | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })
if ($reparseEntries.Count -ne 0) { throw "Package tree cannot contain a reparse point: $($reparseEntries[0].FullName)" }

$requiredFiles = @(
    'bin/kadath.exe',
    'bin/kadath-runtime-build-profile.json',
    'bin/assets/renderer2d/test.png',
    'bin/assets/renderer2d/test.texture',
    'bin/assets/audio/won.wav',
    'bin/assets/audio/lost.wav',
    'bin/assets/audio/won.audio.wav',
    'bin/assets/audio/lost.audio.wav',
    'bin/assets/scenes/preview.scene',
    'bin/assets/scenes/preview.scene.json',
    'bin/assets/scripts/preview.script',
    'bin/assets/scripts/preview.script.json',
    'README.txt'
)
Assert-RequiredPackageFiles $package $requiredFiles

$stagingParentInput = [IO.Path]::GetTempPath()
Assert-NoWin32DevicePath $stagingParentInput 'Package snapshot parent'
if (-not [IO.Path]::IsPathFullyQualified($stagingParentInput)) {
    throw "Package snapshot parent must be a fully qualified local path: $stagingParentInput"
}
Assert-NoReparsePointInExistingPath $stagingParentInput 'Package snapshot parent'
$stagingParent = Resolve-ExistingDirectory $stagingParentInput 'Package snapshot parent'
$staging = [IO.Path]::GetFullPath((Join-Path $stagingParent ("kadath-runtime-archive-{0}" -f [Guid]::NewGuid().ToString('N'))))
Assert-NoReparsePointInExistingPath $staging 'Package snapshot'
Assert-DisjointDirectories $package 'Package root' $staging 'Package snapshot'
Assert-DisjointDirectories $output 'Output directory' $staging 'Package snapshot'
Assert-DisjointDirectories $extract 'Extract directory' $staging 'Package snapshot'

# retained file set 与 strict marker gate 都发生在首次写入前；失败必须报告 archive_write_started=false。
$packageSourceSnapshot = Open-PackageSourceSnapshot $package
Assert-ReleasePackageSnapshotIdentity $packageSourceSnapshot $requiredFiles

$transactionFailure = $null
try {
    # staging 是本事务的首次写入；源包从这里开始仅作为一次性快照输入。
    $stagingRootOwner = New-OwnedDirectoryRoot $staging 'Package snapshot' -MarksArchiveWriteStart $true

    $copyFailure = $null
    try {
        Copy-PackageToOwnedSnapshot $packageSourceSnapshot $staging
    } catch {
        $copyFailure = $_.Exception
    }
    $sourceCloseFailure = $null
    try {
        Close-PackageSourceSnapshot $packageSourceSnapshot
    } catch {
        $sourceCloseFailure = $_.Exception
    } finally {
        $packageSourceSnapshot = $null
    }
    if ($copyFailure -and $sourceCloseFailure) {
        throw [AggregateException]::new(
            'Package snapshot copy failed and retained source handles could not all be released',
            [Exception[]]@($copyFailure, $sourceCloseFailure))
    }
    if ($copyFailure) { throw $copyFailure }
    if ($sourceCloseFailure) { throw $sourceCloseFailure }

    $packageSnapshot = Resolve-ExistingDirectory $staging 'Package snapshot'

    # 关键身份门禁：marker 和三项 payload 只在 owned snapshot 内重新解析与重算。
    Assert-ReleasePackageIdentity $packageSnapshot $requiredFiles

    $outputRootOwner = New-OwnedDirectoryRoot $output 'Output directory'
    $archivePath = Join-Path $output 'kadath-runtime-win-x64.zip'
    $manifestPath = Join-Path $output 'manifest.sha256'

$files = @(Get-ChildItem -LiteralPath $packageSnapshot -File -Recurse | Sort-Object FullName)
if ($files.Count -eq 0) { throw "Package snapshot contains no files: $packageSnapshot" }

$manifestLines = foreach ($file in $files) {
    $relative = Normalize-RelativePath $packageSnapshot $file.FullName
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    "{0}  {1}" -f $hash, $relative
}

# 关键可复现性：manifest 按相对路径排序，归档传递后可逐项比较而不依赖绝对路径。
$manifestLines = @($manifestLines | Sort-Object { ($_ -split '  ', 2)[1] })
Set-Content -LiteralPath $manifestPath -Value $manifestLines -Encoding utf8NoBOM

# 固定条目顺序和时间戳，避免 Compress-Archive 的文件时间元数据造成归档哈希漂移。
Add-Type -AssemblyName System.IO.Compression
$archiveStream = $null
$zip = $null
try {
    $archiveStream = [IO.File]::Open($archivePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $zip = [IO.Compression.ZipArchive]::new($archiveStream, [IO.Compression.ZipArchiveMode]::Create, $false)
    foreach ($file in $files) {
        $relative = Normalize-RelativePath $packageSnapshot $file.FullName
        $entry = $zip.CreateEntry($relative, [IO.Compression.CompressionLevel]::Optimal)
        $entry.LastWriteTime = [DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
        $input = $null
        $entryOutput = $null
        try {
            $input = [IO.File]::Open($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            $entryOutput = $entry.Open()
            $input.CopyTo($entryOutput)
        } finally {
            try {
                if ($entryOutput) { $entryOutput.Dispose() }
            } finally {
                if ($input) { $input.Dispose() }
            }
        }
    }
} finally {
    try {
        if ($zip) { $zip.Dispose() }
    } finally {
        if ($archiveStream) { $archiveStream.Dispose() }
    }
}
if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
    throw "Archive was not created: $archivePath"
}

$extractRootOwner = New-OwnedDirectoryRoot $extract 'Extract directory'
Expand-Archive -LiteralPath $archivePath -DestinationPath $extract -Force
$extractedFiles = @(Get-ChildItem -LiteralPath $extract -File -Recurse | Sort-Object FullName)
$extractedMap = @{}
foreach ($file in $extractedFiles) {
    $relative = Normalize-RelativePath $extract $file.FullName
    $extractedMap[$relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
}

$expectedMap = @{}
foreach ($line in Get-Content -LiteralPath $manifestPath) {
    $parts = $line -split '  ', 2
    if ($parts.Count -ne 2 -or $parts[0].Length -ne 64) { throw "Invalid manifest line: $line" }
    $expectedMap[$parts[1]] = $parts[0].ToLowerInvariant()
}

if ($expectedMap.Count -ne $extractedMap.Count) {
    throw "Archive file count mismatch: expected=$($expectedMap.Count), extracted=$($extractedMap.Count)"
}
foreach ($relative in $expectedMap.Keys) {
    if (-not $extractedMap.ContainsKey($relative)) { throw "Archive is missing file: $relative" }
    if ($extractedMap[$relative] -ne $expectedMap[$relative]) { throw "Archive hash mismatch: $relative" }
}

# 防御性终验：即使归档写入链路被修改，解压后的 marker 仍必须绑定解压后的关键 payload。
Assert-NoReparsePointInExistingPath $extract 'Extract directory'
$extractReparseEntries = @(Get-ChildItem -LiteralPath $extract -Force -Recurse | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })
if ($extractReparseEntries.Count -ne 0) { throw "Extracted archive cannot contain a reparse point: $($extractReparseEntries[0].FullName)" }
Assert-ReleasePackageIdentity $extract $requiredFiles

$archiveSha256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
} catch {
    $transactionFailure = $_.Exception
}

$stagingCleanupFailure = $null
if ($stagingRootOwner) {
    try {
        # staging 无论成功或失败都不属于交付物；live directory handle 保护清空与最终删除。
        Remove-OwnedDirectory $stagingRootOwner 'Package snapshot'
        $stagingRootOwner = $null
    } catch {
        $stagingCleanupFailure = $_.Exception
    }
}
if ($transactionFailure -and $stagingCleanupFailure) {
    throw [AggregateException]::new(
        'Archive transaction failed and package snapshot cleanup also failed',
        [Exception[]]@($transactionFailure, $stagingCleanupFailure))
}
if ($transactionFailure) { throw $transactionFailure }
if ($stagingCleanupFailure) { throw $stagingCleanupFailure }

# 成功交付的 output/extract 保留内容，只释放禁止 rename/delete 的对象见证句柄。
if ($outputRootOwner) { $outputRootOwner.Release(); $outputRootOwner = $null }
if ($extractRootOwner) { $extractRootOwner.Release(); $extractRootOwner = $null }
$archiveCompleted = $true
Write-Output "archive=$archivePath"
Write-Output "manifest=$manifestPath"
Write-Output "extract=$extract"
Write-Output "files=$($expectedMap.Count)"
Write-Output "archive_sha256=$archiveSha256"
Write-Output "verification=ok"
} catch {
    $archiveFailure = $_.Exception
    if (-not $archiveWriteStarted) { [Console]::Error.WriteLine('archive_write_started=false') }

    if (-not $archiveCompleted) {
        # 清理全部本调用 owned 根；一个清理失败不得跳过其余根。
        $cleanupErrors = [Collections.Generic.List[Exception]]::new()
        if ($packageSourceSnapshot) {
            try {
                Close-PackageSourceSnapshot $packageSourceSnapshot
                $packageSourceSnapshot = $null
            } catch {
                $cleanupErrors.Add($_.Exception)
            }
        }
        $cleanupTargets = @(
            [pscustomobject]@{ Owner = $extractRootOwner; Name = 'Extract directory' },
            [pscustomobject]@{ Owner = $outputRootOwner; Name = 'Output directory' },
            [pscustomobject]@{ Owner = $stagingRootOwner; Name = 'Package snapshot' }
        )
        foreach ($target in $cleanupTargets) {
            if (-not $target.Owner) { continue }
            try {
                Remove-OwnedDirectory $target.Owner $target.Name
            } catch {
                $cleanupErrors.Add($_.Exception)
            } finally {
                try { $target.Owner.Release() } catch { $cleanupErrors.Add($_.Exception) }
            }
        }
        if ($cleanupErrors.Count -ne 0) {
            [Exception[]]$failures = @($archiveFailure) + @($cleanupErrors)
            throw [AggregateException]::new('Archive failed and one or more owned roots could not be cleaned', $failures)
        }
    }
    throw
}
