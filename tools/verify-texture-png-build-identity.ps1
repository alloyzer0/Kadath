[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$KadathRoot,

    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# 测试输入 B 由独立 fixture writer 生成；它不复用生产 PNG decoder/importer。
if ($null -eq ('KadathPngBuildIdentityFixture' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.IO.Compression;
using System.Text;

public static class KadathPngBuildIdentityFixture
{
    public static byte[] CreateVariantB()
    {
        using MemoryStream output = new MemoryStream();
        output.Write(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 });

        byte[] header = new byte[13];
        WriteUInt32(header, 0, 1);
        WriteUInt32(header, 4, 1);
        header[8] = 8;
        header[9] = 6;
        WriteChunk(output, "IHDR", header);

        byte[] scanline = new byte[] { 0, 9, 18, 27, 36 };
        using MemoryStream compressed = new MemoryStream();
        using (ZLibStream zlib = new ZLibStream(compressed, CompressionLevel.Optimal, true))
        {
            zlib.Write(scanline, 0, scanline.Length);
        }
        WriteChunk(output, "IDAT", compressed.ToArray());
        WriteChunk(output, "IEND", Array.Empty<byte>());
        return output.ToArray();
    }

    private static void WriteChunk(Stream output, string type, byte[] data)
    {
        byte[] length = new byte[4];
        byte[] typeBytes = Encoding.ASCII.GetBytes(type);
        byte[] crcBytes = new byte[4];
        WriteUInt32(length, 0, (uint)data.Length);
        output.Write(length, 0, length.Length);
        output.Write(typeBytes, 0, typeBytes.Length);
        output.Write(data, 0, data.Length);
        WriteUInt32(crcBytes, 0, Crc32(typeBytes, data));
        output.Write(crcBytes, 0, crcBytes.Length);
    }

    private static void WriteUInt32(byte[] output, int offset, uint value)
    {
        output[offset] = (byte)(value >> 24);
        output[offset + 1] = (byte)(value >> 16);
        output[offset + 2] = (byte)(value >> 8);
        output[offset + 3] = (byte)value;
    }

    private static uint Crc32(byte[] type, byte[] data)
    {
        uint crc = 0xffffffffu;
        foreach (byte value in type) crc = CrcStep(crc, value);
        foreach (byte value in data) crc = CrcStep(crc, value);
        return crc ^ 0xffffffffu;
    }

    private static uint CrcStep(uint crc, byte value)
    {
        crc ^= value;
        for (int bit = 0; bit < 8; bit++)
            crc = (crc & 1u) != 0 ? 0xedb88320u ^ (crc >> 1) : crc >> 1;
        return crc;
    }
}
'@
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
    if (((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Name root cannot be a reparse point: $current"
    }
    foreach ($segment in $relative.Split([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar), [StringSplitOptions]::RemoveEmptyEntries)) {
        $current = Join-Path $current $segment
        if (-not (Test-Path -LiteralPath $current)) { break }
        $info = Get-Item -LiteralPath $current -Force
        if (($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Name cannot traverse a reparse point: $current"
        }
    }
}

function Get-CanonicalAbsolutePath([string]$Path, [string]$Name) {
    Assert-NoWin32DevicePath $Path $Name
    if (-not [IO.Path]::IsPathFullyQualified($Path)) { throw "$Name must be a fully qualified local path: $Path" }
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $Path.Equals($full, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Name must use its canonical absolute spelling: $Path"
    }
    Assert-NoReparsePointInExistingPath $full $Name
    return $full
}

function Resolve-CanonicalDirectory([string]$Path, [string]$Name) {
    $full = Get-CanonicalAbsolutePath $Path $Name
    if (-not (Test-Path -LiteralPath $full -PathType Container)) { throw "$Name does not exist: $full" }
    $item = Get-Item -LiteralPath $full -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Name cannot be a reparse point: $full" }
    return (Resolve-Path -LiteralPath $full).Path
}

function Resolve-CanonicalFile([string]$Path, [string]$Name) {
    $full = Get-CanonicalAbsolutePath $Path $Name
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "$Name does not exist or is not a regular file: $full" }
    $item = Get-Item -LiteralPath $full -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Name cannot be a reparse point: $full" }
    return (Resolve-Path -LiteralPath $full).Path
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

function Assert-DirectChild([string]$Parent, [string]$Child, [string]$Name) {
    $actualParent = [IO.Path]::GetDirectoryName($Child.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
    if (-not $actualParent.Equals($Parent.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Name must be a direct child of OutputDirectory: $Child"
    }
}

function Invoke-GitLines([string]$Root, [string[]]$Arguments, [string]$Name) {
    $output = @(& git -C $Root @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "$Name failed: $($output -join [Environment]::NewLine)" }
    return @($output | ForEach-Object { [string]$_ })
}

function Assert-CleanWorktree([string]$Root, [string]$ExpectedHead = '') {
    $headLines = @(Invoke-GitLines $Root @('rev-parse', 'HEAD') 'git rev-parse HEAD')
    $topLevelLines = @(Invoke-GitLines $Root @('rev-parse', '--show-toplevel') 'git rev-parse --show-toplevel')
    $head = $headLines[0].Trim()
    $topLevel = $topLevelLines[0].Trim()
    $canonicalTopLevel = [IO.Path]::GetFullPath($topLevel)
    if (-not $canonicalTopLevel.Equals($Root, [StringComparison]::OrdinalIgnoreCase)) {
        throw "KadathRoot is not the exact worktree root: root=$Root git=$canonicalTopLevel"
    }
    $status = @(Invoke-GitLines $Root @('status', '--porcelain=v1', '--untracked-files=all') 'git status')
    if ($status.Count -ne 0) { throw "KadathRoot must be clean: $($status -join ' | ')" }
    if (-not [string]::IsNullOrEmpty($ExpectedHead) -and $head -cne $ExpectedHead) {
        throw "KadathRoot HEAD changed during verification: expected=$ExpectedHead actual=$head"
    }
    return $head
}

function Get-Hash([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-BytesHash([byte[]]$Bytes) {
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Test-ByteArraysEqual([byte[]]$Left, [byte[]]$Right) {
    if ($Left.Length -ne $Right.Length) { return $false }
    return [System.Linq.Enumerable]::SequenceEqual[byte]($Left, $Right)
}

function Write-OwnedFileDurable([string]$Path, [byte[]]$Bytes) {
    $stream = $null
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $stream.Write($Bytes, 0, $Bytes.Length)
        $stream.Flush($true)
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Assert-OwnedRegularFile([string]$Path, [string]$Name, [long]$ExpectedLength, [string]$ExpectedHash) {
    $canonical = Resolve-CanonicalFile $Path $Name
    $item = Get-Item -LiteralPath $canonical -Force
    if ($item.Length -ne $ExpectedLength -or (Get-Hash $canonical) -cne $ExpectedHash) {
        throw "$Name identity changed: path=$canonical expected_length=$ExpectedLength actual_length=$($item.Length)"
    }
    return $canonical
}

function Remove-OwnedTemporary([string]$Path, [long]$ExpectedLength, [string]$ExpectedHash) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    [void](Assert-OwnedRegularFile $Path 'Verifier-owned temporary' $ExpectedLength $ExpectedHash)
    Remove-Item -LiteralPath $Path -Force
}

function Start-CapturedProcess([string]$Executable, [string[]]$Arguments, [string]$WorkingDirectory) {
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Executable
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) { [void]$startInfo.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw "Failed to start process: $Executable" }
    return [pscustomobject]@{
        Process = $process
        StdoutTask = $process.StandardOutput.ReadToEndAsync()
        StderrTask = $process.StandardError.ReadToEndAsync()
    }
}

function Complete-CapturedProcess([object]$Capture, [int]$TimeoutMilliseconds, [string]$Name) {
    if (-not $Capture.Process.WaitForExit($TimeoutMilliseconds)) {
        $Capture.Process.Kill($true)
        $Capture.Process.WaitForExit()
        throw "$Name timed out after $TimeoutMilliseconds ms"
    }
    $stdout = $Capture.StdoutTask.GetAwaiter().GetResult()
    $stderr = $Capture.StderrTask.GetAwaiter().GetResult()
    return [pscustomobject]@{ ExitCode = $Capture.Process.ExitCode; Stdout = $stdout; Stderr = $stderr }
}

function Stop-CapturedProcess([object]$Capture) {
    if ($null -eq $Capture) { return }
    if (-not $Capture.Process.HasExited) {
        $Capture.Process.Kill($true)
        $Capture.Process.WaitForExit()
    }
}

function Read-StrictJsonObject([string]$Path, [string[]]$ExpectedFields, [string]$Name) {
    $canonical = Resolve-CanonicalFile $Path $Name
    [byte[]]$bytes = [IO.File]::ReadAllBytes($canonical)
    if ($bytes.Length -eq 0 -or $bytes.Length -gt 65536) { throw "$Name must contain 1..65536 bytes" }
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    $document = [System.Text.Json.JsonDocument]::Parse($text)
    if ($document.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
        $document.Dispose()
        throw "$Name root must be an object"
    }
    $actualFields = @($document.RootElement.EnumerateObject() | ForEach-Object { $_.Name })
    $uniqueFields = @($actualFields | Sort-Object -Unique -CaseSensitive)
    if ($actualFields.Count -ne $ExpectedFields.Count -or $uniqueFields.Count -ne $ExpectedFields.Count -or
        @(Compare-Object -ReferenceObject ($ExpectedFields | Sort-Object) -DifferenceObject ($actualFields | Sort-Object) -CaseSensitive).Count -ne 0) {
        $document.Dispose()
        throw "$Name fields do not match the strict schema"
    }
    return $document
}

function Read-ReadyIdentity([string]$Path) {
    $document = Read-StrictJsonObject $Path ([string[]]@('Version', 'Length', 'Sha256')) 'Snapshot ready.json'
    try {
        $root = $document.RootElement
        if ($root.GetProperty('Version').ValueKind -ne [System.Text.Json.JsonValueKind]::Number -or
            $root.GetProperty('Length').ValueKind -ne [System.Text.Json.JsonValueKind]::Number -or
            $root.GetProperty('Sha256').ValueKind -ne [System.Text.Json.JsonValueKind]::String) {
            throw 'Snapshot ready.json has invalid value kinds'
        }
        $version = $root.GetProperty('Version').GetInt32()
        $length = $root.GetProperty('Length').GetInt64()
        $sha256 = $root.GetProperty('Sha256').GetString()
        if ($version -ne 1 -or $length -le 0 -or $length -ge 8MB -or $sha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw 'Snapshot ready.json has invalid v1 values'
        }
        return [pscustomobject]@{ Version = $version; Length = $length; Sha256 = $sha256 }
    } finally {
        $document.Dispose()
    }
}

function Read-BuildMarker([string]$Path) {
    $fields = [string[]]@('Version', 'Optimize', 'TextureProfile', 'RuntimeExeSha256', 'TextureSourceSha256', 'TextureArtifactSha256', 'VertexShaderSourceSha256', 'FragmentShaderSourceSha256', 'BuildPreflightSidecarSha256')
    $document = Read-StrictJsonObject $Path $fields 'Runtime build profile marker'
    try {
        $root = $document.RootElement
        if ($root.GetProperty('Version').ValueKind -ne [System.Text.Json.JsonValueKind]::Number) { throw 'Marker Version must be a number' }
        foreach ($field in $fields[1..($fields.Count - 1)]) {
            $kind = $root.GetProperty($field).ValueKind
            if ($field -eq 'BuildPreflightSidecarSha256') {
                if ($kind -ne [System.Text.Json.JsonValueKind]::Null -and $kind -ne [System.Text.Json.JsonValueKind]::String) { throw "Marker $field has an invalid value kind" }
            } elseif ($kind -ne [System.Text.Json.JsonValueKind]::String) {
                throw "Marker $field must be a string"
            }
        }
        return [pscustomobject]@{
            Version = $root.GetProperty('Version').GetInt32()
            Optimize = $root.GetProperty('Optimize').GetString()
            TextureProfile = $root.GetProperty('TextureProfile').GetString()
            TextureSourceSha256 = $root.GetProperty('TextureSourceSha256').GetString()
            TextureArtifactSha256 = $root.GetProperty('TextureArtifactSha256').GetString()
        }
    } finally {
        $document.Dispose()
    }
}

function Invoke-Importer([string]$PowerShellPath, [string]$ImporterPath, [string]$SourcePath, [string]$DestinationPath, [string]$WorkingDirectory) {
    $capture = Start-CapturedProcess $PowerShellPath @('-NoProfile', '-File', $ImporterPath, '-SourcePath', $SourcePath, '-Profile', 'release', '-DestinationPath', $DestinationPath) $WorkingDirectory
    $result = Complete-CapturedProcess $capture 120000 'Production texture importer'
    if ($result.ExitCode -ne 0) { throw "Production texture importer failed: $($result.Stdout) $($result.Stderr)" }
}

$buildCapture = $null
$sourcePublishedAsB = $false
$sourceTarget = $null
$sourceABytes = $null
$sourceAHash = $null
$sourceBBytes = $null
$sourceBHash = $null
$publishTemporary = $null
$publishBackupTemporary = $null
$restoreTemporary = $null
$restoreBackupTemporary = $null
$releaseTemporary = $null
$primaryError = $null
$restoreError = $null
$root = $null
$output = $null
$buildRoots = $null
$faultPrefix = $null
$faultLocalCache = $null
$faultGlobalCache = $null
$fileIdFaultPrefix = $null
$fileIdFaultLocalCache = $null
$fileIdFaultGlobalCache = $null
$replacementFaultPrefix = $null
$replacementFaultLocalCache = $null
$replacementFaultGlobalCache = $null

try {
    $root = Resolve-CanonicalDirectory $KadathRoot 'KadathRoot'
    $headBefore = Assert-CleanWorktree $root

    $output = Get-CanonicalAbsolutePath $OutputDirectory 'OutputDirectory'
    if (Test-Path -LiteralPath $output) { throw "OutputDirectory must not exist: $output" }
    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    Assert-NoReparsePointInExistingPath $temporaryRoot 'System temporary root'
    if (-not (Test-DirectoryContains $temporaryRoot $output) -or $temporaryRoot.Equals($output, [StringComparison]::OrdinalIgnoreCase)) {
        throw "OutputDirectory must be below the system temporary root: output=$output temp=$temporaryRoot"
    }
    Assert-DisjointDirectories $root 'KadathRoot' $output 'OutputDirectory'

    $package = Join-Path $output 'package'
    $localCache = Join-Path $output 'local-cache'
    $globalCache = Join-Path $output 'global-cache'
    $barrier = Join-Path $output 'barrier'
    $buildRoots = [ordered]@{ Package = $package; LocalCache = $localCache; GlobalCache = $globalCache; Barrier = $barrier }
    foreach ($entry in $buildRoots.GetEnumerator()) {
        Assert-DirectChild $output $entry.Value $entry.Key
        Assert-NoReparsePointInExistingPath $entry.Value $entry.Key
        if (Test-Path -LiteralPath $entry.Value) { throw "$($entry.Key) must not exist before verification: $($entry.Value)" }
    }
    $rootNames = @($buildRoots.Keys)
    for ($left = 0; $left -lt $rootNames.Count; $left++) {
        for ($right = $left + 1; $right -lt $rootNames.Count; $right++) {
            Assert-DisjointDirectories $buildRoots[$rootNames[$left]] $rootNames[$left] $buildRoots[$rootNames[$right]] $rootNames[$right]
        }
    }

    # 首次写入只发生在全部 canonical/no-reparse/containment 前置完成之后。
    New-Item -ItemType Directory -Path $output | Out-Null
    $createdOutput = Resolve-CanonicalDirectory $output 'OutputDirectory immediately after create'
    if (-not $createdOutput.Equals($output, [StringComparison]::OrdinalIgnoreCase)) { throw 'OutputDirectory identity changed during create' }
    Assert-DisjointDirectories $root 'KadathRoot' $createdOutput 'OutputDirectory'
    foreach ($entry in $buildRoots.GetEnumerator()) {
        Assert-DirectChild $createdOutput $entry.Value $entry.Key
        Assert-NoReparsePointInExistingPath $entry.Value "$($entry.Key) before barrier create"
        if (Test-Path -LiteralPath $entry.Value) { throw "$($entry.Key) appeared during OutputDirectory creation" }
    }
    New-Item -ItemType Directory -Path $barrier | Out-Null
    $createdBarrier = Resolve-CanonicalDirectory $barrier 'Barrier immediately after create'
    if (-not $createdBarrier.Equals($barrier, [StringComparison]::OrdinalIgnoreCase)) { throw 'Barrier identity changed during create' }
    Assert-DirectChild $createdOutput $createdBarrier 'Barrier'
    if (@(Get-ChildItem -LiteralPath $createdBarrier -Force).Count -ne 0) { throw 'Barrier must start empty' }
    foreach ($entry in $buildRoots.GetEnumerator()) {
        Assert-DirectChild $createdOutput $entry.Value $entry.Key
        Assert-NoReparsePointInExistingPath $entry.Value "$($entry.Key) after barrier create"
        if ($entry.Key -eq 'Barrier') {
            [void](Resolve-CanonicalDirectory $entry.Value 'Barrier after create')
        } elseif (Test-Path -LiteralPath $entry.Value) {
            throw "$($entry.Key) appeared before build start"
        }
    }

    $sourceTarget = Resolve-CanonicalFile (Join-Path $root 'assets\renderer2d\test.png') 'Tracked PNG source'
    $sourceABytes = [IO.File]::ReadAllBytes($sourceTarget)
    $sourceAHash = Get-BytesHash $sourceABytes
    $sourceBBytes = [KadathPngBuildIdentityFixture]::CreateVariantB()
    $sourceBHash = Get-BytesHash $sourceBBytes
    if ($sourceAHash -ceq $sourceBHash) { throw 'Fixture B must have a different source identity from fixture A' }

    $zig = (Get-Command zig -CommandType Application -ErrorAction Stop).Source
    $pwsh = (Get-Command pwsh -CommandType Application -ErrorAction Stop).Source
    $buildArguments = [string[]]@(
        'build', 'package', '-Doptimize=ReleaseSafe',
        '--prefix', $package,
        '--cache-dir', $localCache,
        '--global-cache-dir', $globalCache,
        "-Dtexture-source-snapshot-test-barrier=$barrier"
    )
    $buildCapture = Start-CapturedProcess $zig $buildArguments $root

    $readyPath = Join-Path $barrier 'ready.json'
    $releasePath = Join-Path $barrier 'release'
    $readyDeadline = [DateTime]::UtcNow.AddSeconds(120)
    while (-not (Test-Path -LiteralPath $readyPath)) {
        if ($buildCapture.Process.HasExited) {
            $early = Complete-CapturedProcess $buildCapture 1000 'Barrier package build'
            throw "Build exited before snapshot ready.json: exit=$($early.ExitCode) stdout=$($early.Stdout) stderr=$($early.Stderr)"
        }
        if ([DateTime]::UtcNow -ge $readyDeadline) { throw 'Timed out waiting for snapshot ready.json' }
        Start-Sleep -Milliseconds 25
    }

    Assert-NoReparsePointInExistingPath $barrier 'Barrier before source mutation'
    if (Test-Path -LiteralPath $releasePath) { throw 'Barrier release must not exist before verifier publishes it' }
    $ready = Read-ReadyIdentity $readyPath
    if ($ready.Length -ne $sourceABytes.Length -or $ready.Sha256 -cne $sourceAHash) {
        throw "Snapshot ready identity does not match source A: ready=$($ready.Sha256) A=$sourceAHash"
    }

    # 关键 race：ready 后才以 owned temp + same-volume replace 发布 B。
    [void](Assert-OwnedRegularFile $sourceTarget 'Tracked PNG source before B publish' $sourceABytes.Length $sourceAHash)
    $publishTemporary = Join-Path $root ('.kadath-texture-source-b-{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
    $publishBackupTemporary = Join-Path $root ('.kadath-texture-source-a-backup-{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
    if (Test-Path -LiteralPath $publishBackupTemporary) { throw 'Verifier-owned A backup path must be fresh' }
    Write-OwnedFileDurable $publishTemporary $sourceBBytes
    [void](Assert-OwnedRegularFile $publishTemporary 'Verifier-owned B temporary' $sourceBBytes.Length $sourceBHash)
    # Windows File.Replace 要求非空 backup path；fresh owned backup 同时保存被替换的 A 身份。
    [IO.File]::Replace($publishTemporary, $sourceTarget, $publishBackupTemporary, $true)
    $sourcePublishedAsB = $true
    [void](Assert-OwnedRegularFile $sourceTarget 'Tracked PNG source B' $sourceBBytes.Length $sourceBHash)
    [void](Assert-OwnedRegularFile $publishBackupTemporary 'Verifier-owned source A backup' $sourceABytes.Length $sourceAHash)

    $releaseTemporary = Join-Path $barrier ('.release-{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
    Write-OwnedFileDurable $releaseTemporary ([byte[]]::new(0))
    [IO.File]::Move($releaseTemporary, $releasePath, $false)
    $release = Resolve-CanonicalFile $releasePath 'Barrier release'
    if ((Get-Item -LiteralPath $release -Force).Length -ne 0) { throw 'Barrier release must be zero length' }

    $buildResult = Complete-CapturedProcess $buildCapture 300000 'Barrier package build'
    if ($buildResult.ExitCode -ne 0) {
        throw "Barrier package build failed: stdout=$($buildResult.Stdout) stderr=$($buildResult.Stderr)"
    }
} catch {
    $primaryError = $_
} finally {
    try { Stop-CapturedProcess $buildCapture } catch { if ($null -eq $primaryError) { $primaryError = $_ } }
    if ($sourcePublishedAsB) {
        try {
            # 恢复 A 前重新证明 target 仍是本轮 B；未知外部状态必须 fail-closed 保留。
            [void](Assert-OwnedRegularFile $sourceTarget 'Tracked PNG source before restoring A' $sourceBBytes.Length $sourceBHash)
            $rootForRestore = [IO.Path]::GetFullPath($KadathRoot)
            $restoreTemporary = Join-Path $rootForRestore ('.kadath-texture-source-a-{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
            $restoreBackupTemporary = Join-Path $rootForRestore ('.kadath-texture-source-b-backup-{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
            if (Test-Path -LiteralPath $restoreBackupTemporary) { throw 'Verifier-owned B backup path must be fresh' }
            Write-OwnedFileDurable $restoreTemporary $sourceABytes
            [void](Assert-OwnedRegularFile $restoreTemporary 'Verifier-owned A temporary' $sourceABytes.Length $sourceAHash)
            [void](Assert-OwnedRegularFile $sourceTarget 'Tracked PNG source immediately before restoring A' $sourceBBytes.Length $sourceBHash)
            # 恢复同样使用非空 owned backup；若 target 已未知，前置检查会拒绝覆盖。
            [IO.File]::Replace($restoreTemporary, $sourceTarget, $restoreBackupTemporary, $true)
            $sourcePublishedAsB = $false
            [void](Assert-OwnedRegularFile $sourceTarget 'Restored tracked PNG source A' $sourceABytes.Length $sourceAHash)
            [void](Assert-OwnedRegularFile $restoreBackupTemporary 'Verifier-owned source B backup' $sourceBBytes.Length $sourceBHash)
        } catch {
            $restoreError = [InvalidOperationException]::new("未恢复 A：tracked source 不再属于本轮 B，已保留未知外部状态。$($_.Exception.Message)", $_.Exception)
        }
    }
    $cleanupRootsSafe = $true
    try {
        # 不清理 evidence roots；任何 owned temp cleanup 前仍重新证明 root layout 未被替换。
        if ($null -ne $output -and (Test-Path -LiteralPath $output)) {
            $cleanupOutput = Resolve-CanonicalDirectory $output 'OutputDirectory before cleanup'
            if (-not $cleanupOutput.Equals($output, [StringComparison]::OrdinalIgnoreCase)) { throw 'OutputDirectory changed before cleanup' }
            Assert-DisjointDirectories $root 'KadathRoot' $cleanupOutput 'OutputDirectory'
            if ($null -ne $buildRoots) {
                foreach ($entry in $buildRoots.GetEnumerator()) {
                    Assert-DirectChild $cleanupOutput $entry.Value $entry.Key
                    Assert-NoReparsePointInExistingPath $entry.Value "$($entry.Key) before cleanup"
                    if (Test-Path -LiteralPath $entry.Value) {
                        [void](Resolve-CanonicalDirectory $entry.Value "$($entry.Key) before cleanup")
                    }
                }
            }
        }
    } catch {
        $cleanupRootsSafe = $false
        if ($null -eq $restoreError) { $restoreError = $_.Exception }
    }
    if ($cleanupRootsSafe) {
        # 五个 owned temporary/backup 必须全部尝试；单个异常不能短路后续安全清理。
        $ownedCleanupErrors = [Collections.Generic.List[Exception]]::new()
        try {
            # 正式 release 永久保留；只回收仍存在且精确属于本轮的 zero-byte publish temporary。
            if ($null -ne $releaseTemporary) { Remove-OwnedTemporary $releaseTemporary 0 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' }
        } catch { $ownedCleanupErrors.Add($_.Exception) }
        try {
            if ($null -ne $publishTemporary) { Remove-OwnedTemporary $publishTemporary $sourceBBytes.Length $sourceBHash }
        } catch { $ownedCleanupErrors.Add($_.Exception) }
        try {
            if ($null -ne $restoreTemporary) { Remove-OwnedTemporary $restoreTemporary $sourceABytes.Length $sourceAHash }
        } catch { $ownedCleanupErrors.Add($_.Exception) }
        try {
            if ($null -ne $publishBackupTemporary) { Remove-OwnedTemporary $publishBackupTemporary $sourceABytes.Length $sourceAHash }
        } catch { $ownedCleanupErrors.Add($_.Exception) }
        try {
            if ($null -ne $restoreBackupTemporary) { Remove-OwnedTemporary $restoreBackupTemporary $sourceBBytes.Length $sourceBHash }
        } catch { $ownedCleanupErrors.Add($_.Exception) }
        if ($null -eq $restoreError -and $ownedCleanupErrors.Count -eq 1) {
            $restoreError = $ownedCleanupErrors[0]
        } elseif ($null -eq $restoreError -and $ownedCleanupErrors.Count -gt 1) {
            $restoreError = [AggregateException]::new('Verifier-owned temporary cleanup failures', $ownedCleanupErrors)
        }
    }
}

if ($null -ne $restoreError) { throw $restoreError }
if ($null -ne $primaryError) { throw $primaryError }

# 使用全新的前缀与缓存运行 build 私有故障开关，避免正常 barrier 构建缓存掩盖快照写入路径。
$faultPrefix = Join-Path $output 'fault-package'
$faultLocalCache = Join-Path $output 'fault-local-cache'
$faultGlobalCache = Join-Path $output 'fault-global-cache'
$faultRoots = [ordered]@{ FaultPackage = $faultPrefix; FaultLocalCache = $faultLocalCache; FaultGlobalCache = $faultGlobalCache }
foreach ($entry in $faultRoots.GetEnumerator()) {
    Assert-DirectChild $output $entry.Value $entry.Key
    Assert-NoReparsePointInExistingPath $entry.Value $entry.Key
    if (Test-Path -LiteralPath $entry.Value) { throw "$($entry.Key) must not exist before partial-write fault verification: $($entry.Value)" }
}

$zig = (Get-Command zig -CommandType Application -ErrorAction Stop).Source
$faultArguments = [string[]]@(
    'build', 'package', '-Doptimize=ReleaseSafe',
    '--prefix', $faultPrefix,
    '--cache-dir', $faultLocalCache,
    '--global-cache-dir', $faultGlobalCache,
    '-Dtexture-source-snapshot-test-fault=snapshot-partial-write-before-flush'
)
$faultCapture = Start-CapturedProcess $zig $faultArguments $root
$faultResult = Complete-CapturedProcess $faultCapture 300000 'Partial-write fault package build'
$faultOutput = $faultResult.Stdout + [Environment]::NewLine + $faultResult.Stderr
if ($faultResult.ExitCode -eq 0) { throw 'Partial-write fault package build unexpectedly succeeded.' }
if ($faultOutput -notmatch [regex]::Escape('Injected snapshot partial-write-before-flush failure')) {
    throw "Partial-write fault package build failed without the injected cleanup oracle. stdout=$($faultResult.Stdout) stderr=$($faultResult.Stderr)"
}

# 故障发生在 Flush 之前；残片若仍依赖完整 length/hash 才能清理，将在任一隔离 root 中被检出。
foreach ($entry in $faultRoots.GetEnumerator()) {
    if (-not (Test-Path -LiteralPath $entry.Value)) { continue }
    $canonicalFaultRoot = Resolve-CanonicalDirectory $entry.Value "$($entry.Key) after partial-write fault"
    Assert-DirectChild $output $canonicalFaultRoot $entry.Key
    $faultTemporaryFiles = @(
        Get-ChildItem -LiteralPath $canonicalFaultRoot -Recurse -Force -File -Filter '.kadath-texture-source-snapshot-*.tmp' -ErrorAction Stop
    )
if ($faultTemporaryFiles.Count -ne 0) {
    throw "Partial-write fault cleanup left snapshot temporary files: $($faultTemporaryFiles.FullName -join '; ')"
}
}

# File ID 读取完成、PowerShell 尚未接管 owned object 前的失败必须由原 CreateNew handle 自行 Delete disposition，不能留下残片。
$fileIdFaultPrefix = Join-Path $output 'file-id-fault-package'
$fileIdFaultLocalCache = Join-Path $output 'file-id-fault-local-cache'
$fileIdFaultGlobalCache = Join-Path $output 'file-id-fault-global-cache'
$fileIdFaultRoots = [ordered]@{
    FileIdFaultPackage = $fileIdFaultPrefix
    FileIdFaultLocalCache = $fileIdFaultLocalCache
    FileIdFaultGlobalCache = $fileIdFaultGlobalCache
}
foreach ($entry in $fileIdFaultRoots.GetEnumerator()) {
    Assert-DirectChild $output $entry.Value $entry.Key
    Assert-NoReparsePointInExistingPath $entry.Value $entry.Key
    if (Test-Path -LiteralPath $entry.Value) { throw "$($entry.Key) must not exist before file-id pre-return fault verification: $($entry.Value)" }
}

$fileIdFaultArguments = [string[]]@(
    'build', 'package', '-Doptimize=ReleaseSafe',
    '--prefix', $fileIdFaultPrefix,
    '--cache-dir', $fileIdFaultLocalCache,
    '--global-cache-dir', $fileIdFaultGlobalCache,
    '-Dtexture-source-snapshot-test-fault=snapshot-file-id-before-return'
)
$fileIdFaultCapture = Start-CapturedProcess $zig $fileIdFaultArguments $root
$fileIdFaultResult = Complete-CapturedProcess $fileIdFaultCapture 300000 'File ID pre-return fault package build'
$fileIdFaultOutput = $fileIdFaultResult.Stdout + [Environment]::NewLine + $fileIdFaultResult.Stderr
if ($fileIdFaultResult.ExitCode -eq 0) { throw 'File ID pre-return fault package build unexpectedly succeeded.' }
if ($fileIdFaultOutput -notmatch [regex]::Escape('Injected snapshot file-id-before-return failure')) {
    throw "File ID pre-return fault package build failed without the injected cleanup oracle. stdout=$($fileIdFaultResult.Stdout) stderr=$($fileIdFaultResult.Stderr)"
}
foreach ($entry in $fileIdFaultRoots.GetEnumerator()) {
    if (-not (Test-Path -LiteralPath $entry.Value)) { continue }
    $canonicalFileIdFaultRoot = Resolve-CanonicalDirectory $entry.Value "$($entry.Key) after file-id pre-return fault"
    Assert-DirectChild $output $canonicalFileIdFaultRoot $entry.Key
    $fileIdFaultTemporaryFiles = @(
        Get-ChildItem -LiteralPath $canonicalFileIdFaultRoot -Recurse -Force -File -Filter '.kadath-texture-source-snapshot-*.tmp' -ErrorAction Stop
    )
    if ($fileIdFaultTemporaryFiles.Count -ne 0) {
        throw "File ID pre-return fault cleanup left snapshot temporary files: $($fileIdFaultTemporaryFiles.FullName -join '; ')"
    }
}

# 同字节 File.Replace 竞争 smoke：替换后的路径长度/哈希仍相同，但 File ID 不同，cleanup 必须拒绝按路径删除。
$replacementFaultPrefix = Join-Path $output 'replacement-fault-package'
$replacementFaultLocalCache = Join-Path $output 'replacement-fault-local-cache'
$replacementFaultGlobalCache = Join-Path $output 'replacement-fault-global-cache'
$replacementFaultRoots = [ordered]@{
    ReplacementFaultPackage = $replacementFaultPrefix
    ReplacementFaultLocalCache = $replacementFaultLocalCache
    ReplacementFaultGlobalCache = $replacementFaultGlobalCache
}
foreach ($entry in $replacementFaultRoots.GetEnumerator()) {
    Assert-DirectChild $output $entry.Value $entry.Key
    Assert-NoReparsePointInExistingPath $entry.Value $entry.Key
    if (Test-Path -LiteralPath $entry.Value) { throw "$($entry.Key) must not exist before replacement fault verification: $($entry.Value)" }
}

$replacementFaultArguments = [string[]]@(
    'build', 'package', '-Doptimize=ReleaseSafe',
    '--prefix', $replacementFaultPrefix,
    '--cache-dir', $replacementFaultLocalCache,
    '--global-cache-dir', $replacementFaultGlobalCache,
    '-Dtexture-source-snapshot-test-fault=snapshot-replace-before-cleanup'
)
$replacementFaultCapture = Start-CapturedProcess $zig $replacementFaultArguments $root
$replacementFaultResult = Complete-CapturedProcess $replacementFaultCapture 300000 'Same-byte replacement fault package build'
$replacementFaultOutput = $replacementFaultResult.Stdout + [Environment]::NewLine + $replacementFaultResult.Stderr
if ($replacementFaultResult.ExitCode -eq 0) { throw 'Same-byte replacement fault package build unexpectedly succeeded.' }
if ($replacementFaultOutput -notmatch [regex]::Escape('Refusing to delete a replaced snapshot object.')) {
    throw "Same-byte replacement fault did not fail closed on the replaced File ID. stdout=$($replacementFaultResult.Stdout) stderr=$($replacementFaultResult.Stderr)"
}

# Zig 失败路径可能随后回收整个 command output directory；拒删诊断才是本回归的对象身份 oracle。
$retainedReplacementFiles = @()
foreach ($entry in $replacementFaultRoots.GetEnumerator()) {
    if (-not (Test-Path -LiteralPath $entry.Value)) { continue }
    $canonicalReplacementFaultRoot = Resolve-CanonicalDirectory $entry.Value "$($entry.Key) after replacement fault"
    Assert-DirectChild $output $canonicalReplacementFaultRoot $entry.Key
    $retainedReplacementFiles += @(
        Get-ChildItem -LiteralPath $canonicalReplacementFaultRoot -Recurse -Force -File -Filter '.kadath-texture-source-snapshot-*.tmp' -ErrorAction Stop
    )
}
if ($retainedReplacementFiles.Count -gt 1) {
    throw "Same-byte replacement fault found multiple replacement remnants: $($retainedReplacementFiles.FullName -join '; ')"
}
if ($retainedReplacementFiles.Count -eq 1 -and -not (Test-ByteArraysEqual ([IO.File]::ReadAllBytes($retainedReplacementFiles[0].FullName)) $sourceABytes)) {
    throw 'Same-byte replacement fault remnant bytes do not match the source snapshot.'
}

# GREEN oracle：所有最终身份都从独立实物重算，不从 build marker 反推期望值。
$root = Resolve-CanonicalDirectory $KadathRoot 'KadathRoot after build'
$headAfter = Assert-CleanWorktree $root $headBefore
$output = Resolve-CanonicalDirectory $OutputDirectory 'OutputDirectory after build'
foreach ($entry in $buildRoots.GetEnumerator()) {
    Assert-DirectChild $output $entry.Value $entry.Key
    [void](Resolve-CanonicalDirectory $entry.Value "$($entry.Key) after build")
}
$rootNames = @($buildRoots.Keys)
for ($left = 0; $left -lt $rootNames.Count; $left++) {
    for ($right = $left + 1; $right -lt $rootNames.Count; $right++) {
        Assert-DisjointDirectories $buildRoots[$rootNames[$left]] $rootNames[$left] $buildRoots[$rootNames[$right]] $rootNames[$right]
    }
}

$packageSource = Resolve-CanonicalFile (Join-Path $package 'bin\assets\renderer2d\test.png') 'Package PNG source'
$packageTexture = Resolve-CanonicalFile (Join-Path $package 'bin\assets\renderer2d\test.texture') 'Package KDAT'
$markerPath = Resolve-CanonicalFile (Join-Path $package 'bin\kadath-runtime-build-profile.json') 'Runtime build profile marker'
$packageSourceBytes = [IO.File]::ReadAllBytes($packageSource)
if (-not (Test-ByteArraysEqual $packageSourceBytes $sourceABytes)) { throw 'Package PNG is not byte-identical to source A snapshot' }

$expectedA = Join-Path $output 'expected-a'
$expectedB = Join-Path $output 'expected-b'
New-Item -ItemType Directory -Path $expectedA,$expectedB | Out-Null
$expectedASource = Join-Path $expectedA 'source.png'
$expectedBSource = Join-Path $expectedB 'source.png'
$expectedAKdat = Join-Path $expectedA 'test.texture'
$expectedBKdat = Join-Path $expectedB 'test.texture'
Write-OwnedFileDurable $expectedASource $sourceABytes
Write-OwnedFileDurable $expectedBSource $sourceBBytes
$pwsh = (Get-Command pwsh -CommandType Application -ErrorAction Stop).Source
$importer = Resolve-CanonicalFile (Join-Path $root 'tools\editor-texture-importer.ps1') 'Production texture importer'
Invoke-Importer $pwsh $importer $expectedASource $expectedAKdat $root
Invoke-Importer $pwsh $importer $expectedBSource $expectedBKdat $root

$packageTextureBytes = [IO.File]::ReadAllBytes($packageTexture)
$expectedATextureBytes = [IO.File]::ReadAllBytes($expectedAKdat)
if (-not (Test-ByteArraysEqual $packageTextureBytes $expectedATextureBytes)) { throw 'Package KDAT is not byte-identical to importer(A)' }
$packageSourceHash = Get-Hash $packageSource
$packageTextureHash = Get-Hash $packageTexture
$expectedBTextureHash = Get-Hash $expectedBKdat
if ($packageSourceHash -ceq $sourceBHash -or $packageTextureHash -ceq $expectedBTextureHash) {
    throw 'Package unexpectedly contains source or KDAT identity from B'
}

$marker = Read-BuildMarker $markerPath
if ($marker.Version -ne 1 -or $marker.Optimize -cne 'ReleaseSafe' -or $marker.TextureProfile -cne 'release' -or
    $marker.TextureSourceSha256 -cne $packageSourceHash -or $marker.TextureArtifactSha256 -cne $packageTextureHash) {
    throw 'Runtime marker does not bind the package A/KDAT(A) identities'
}

$ready = Read-ReadyIdentity (Join-Path $barrier 'ready.json')
if ($ready.Length -ne $sourceABytes.Length -or $ready.Sha256 -cne $sourceAHash) { throw 'Retained ready.json identity changed' }
$release = Resolve-CanonicalFile (Join-Path $barrier 'release') 'Retained barrier release'
if ((Get-Item -LiteralPath $release -Force).Length -ne 0) { throw 'Retained barrier release is not zero length' }
[void](Assert-OwnedRegularFile $sourceTarget 'Final tracked PNG source A' $sourceABytes.Length $sourceAHash)
[void](Assert-CleanWorktree $root $headAfter)

Write-Output 'texture_png_build_identity_version=1'
Write-Output "head=$headAfter"
Write-Output "source_target=$sourceTarget"
Write-Output "source_a_length=$($sourceABytes.Length)"
Write-Output "source_a_sha256=$sourceAHash"
Write-Output "source_b_length=$($sourceBBytes.Length)"
Write-Output "source_b_sha256=$sourceBHash"
Write-Output "package_source_sha256=$packageSourceHash"
Write-Output "package_texture_sha256=$packageTextureHash"
Write-Output 'snapshot_barrier=ok'
Write-Output 'snapshot_partial_write_cleanup=ok'
Write-Output 'snapshot_file_id_before_return_cleanup=ok'
Write-Output 'snapshot_same_byte_replacement_refusal=ok'
Write-Output 'source_restored=ok'
Write-Output 'package_identity=ok'
Write-Output 'verification=ok'
