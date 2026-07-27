[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$KadathRoot,

    [Parameter(Mandatory = $true)]
    [string]$PackageRoot,

    [Parameter(Mandatory = $true)]
    [string]$EvidenceDirectory,

    [Parameter(Mandatory = $true)]
    [string]$TaskLocalCacheDirectory,

    [Parameter(Mandatory = $true)]
    [string]$GlobalCacheDirectory,

    [Parameter(Mandatory = $true)]
    [string]$PreflightSidecarPath,

    [Parameter(Mandatory = $true)]
    [string]$BuildCommandEvidencePath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Text;

public sealed class KadathClientCapture
{
    public int Left { get; set; }
    public int Top { get; set; }
    public int Width { get; set; }
    public int Height { get; set; }
    public byte[] Bgra { get; set; } = Array.Empty<byte>();
}

public sealed class KadathCapturedProcess
{
    private readonly object stdoutGate = new object();
    private readonly object stderrGate = new object();
    private readonly List<string> stdout = new List<string>();
    private readonly List<string> stderr = new List<string>();

    public Process Process { get; private set; }

    private KadathCapturedProcess(Process process) { Process = process; }

    public static KadathCapturedProcess Start(string executable, string workingDirectory, IEnumerable<string> arguments)
    {
        ProcessStartInfo info = new ProcessStartInfo
        {
            FileName = executable,
            WorkingDirectory = workingDirectory,
            UseShellExecute = false,
            CreateNoWindow = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = new UTF8Encoding(false),
            StandardErrorEncoding = new UTF8Encoding(false)
        };
        foreach (string argument in arguments) info.ArgumentList.Add(argument);
        Process process = new Process { StartInfo = info, EnableRaisingEvents = true };
        KadathCapturedProcess capture = new KadathCapturedProcess(process);
        process.OutputDataReceived += (_, e) => { if (e.Data != null) lock (capture.stdoutGate) capture.stdout.Add(e.Data); };
        process.ErrorDataReceived += (_, e) => { if (e.Data != null) lock (capture.stderrGate) capture.stderr.Add(e.Data); };
        if (!process.Start()) throw new InvalidOperationException("Failed to start Kadath Runtime process.");
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        return capture;
    }

    public string StderrText { get { lock (stderrGate) return string.Join(Environment.NewLine, stderr); } }

    public bool WaitForExit(int milliseconds)
    {
        if (!Process.WaitForExit(milliseconds)) return false;
        // 第二次无参等待会排空异步 DataReceived 事件，而不会在进程已退出后无界等待。
        Process.WaitForExit();
        return true;
    }

    public void FlushLogs(string stdoutPath, string stderrPath)
    {
        string stdoutText, stderrText;
        lock (stdoutGate) stdoutText = string.Join(Environment.NewLine, stdout);
        lock (stderrGate) stderrText = string.Join(Environment.NewLine, stderr);
        File.WriteAllText(stdoutPath, stdoutText + (stdoutText.Length == 0 ? "" : Environment.NewLine), new UTF8Encoding(false));
        File.WriteAllText(stderrPath, stderrText + (stderrText.Length == 0 ? "" : Environment.NewLine), new UTF8Encoding(false));
    }
}

public static class KadathPngRuntimeNative
{
    private const int DIB_RGB_COLORS = 0;
    private const uint SRCCOPY = 0x00CC0020;
    private const uint CAPTUREBLT = 0x40000000;

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT { public int X, Y; }

    [StructLayout(LayoutKind.Sequential)]
    private struct BITMAPINFOHEADER
    {
        public uint biSize;
        public int biWidth;
        public int biHeight;
        public ushort biPlanes;
        public ushort biBitCount;
        public uint biCompression;
        public uint biSizeImage;
        public int biXPelsPerMeter;
        public int biYPelsPerMeter;
        public uint biClrUsed;
        public uint biClrImportant;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BITMAPINFO
    {
        public BITMAPINFOHEADER bmiHeader;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 4)] public uint[] bmiColors;
    }

    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool GetClientRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool ClientToScreen(IntPtr hWnd, ref POINT point);
    [DllImport("user32.dll", SetLastError = true)] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool ShowWindow(IntPtr hWnd, int command);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern IntPtr WindowFromPoint(POINT point);
    [DllImport("user32.dll")] private static extern IntPtr GetAncestor(IntPtr hWnd, uint flags);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr insertAfter, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool PostMessage(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hWnd);
    [DllImport("user32.dll", SetLastError = true)] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr GetDC(IntPtr hWnd);
    [DllImport("user32.dll", SetLastError = true)] private static extern int ReleaseDC(IntPtr hWnd, IntPtr hDc);
    [DllImport("gdi32.dll", SetLastError = true)] private static extern IntPtr CreateCompatibleDC(IntPtr hDc);
    [DllImport("gdi32.dll", SetLastError = true)] private static extern bool DeleteDC(IntPtr hDc);
    [DllImport("gdi32.dll", SetLastError = true)] private static extern IntPtr SelectObject(IntPtr hDc, IntPtr value);
    [DllImport("gdi32.dll", SetLastError = true)] private static extern bool DeleteObject(IntPtr value);
    [DllImport("gdi32.dll", SetLastError = true)] private static extern IntPtr CreateDIBSection(IntPtr hDc, ref BITMAPINFO info, uint usage, out IntPtr bits, IntPtr section, uint offset);
    [DllImport("gdi32.dll", SetLastError = true)] private static extern bool BitBlt(IntPtr destination, int x, int y, int width, int height, IntPtr source, int sourceX, int sourceY, uint operation);

    public static IntPtr EnterPerMonitorV2DpiAwareness()
    {
        // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = -4；确保 ClientToScreen 与 GDI 使用物理像素坐标。
        IntPtr previous = SetThreadDpiAwarenessContext(new IntPtr(-4));
        if (previous == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "SetThreadDpiAwarenessContext failed");
        return previous;
    }

    public static void RestoreDpiAwareness(IntPtr previous)
    {
        if (previous != IntPtr.Zero) SetThreadDpiAwarenessContext(previous);
    }

    public static uint GetOwnerProcessId(IntPtr hWnd)
    {
        GetWindowThreadProcessId(hWnd, out uint processId);
        return processId;
    }

    public static bool PrepareUnobscuredCapture(IntPtr hWnd)
    {
        ShowWindow(hWnd, 9);
        // 捕获期临时置顶，避免 Codex/终端等普通窗口覆盖 Vulkan client；结束后由 verifier 恢复。
        if (!SetWindowPos(hWnd, new IntPtr(-1), 0, 0, 0, 0, 0x0053))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "SetWindowPos(HWND_TOPMOST) failed");
        return SetForegroundWindow(hWnd);
    }

    public static void RestoreCaptureZOrder(IntPtr hWnd)
    {
        if (hWnd != IntPtr.Zero) SetWindowPos(hWnd, new IntPtr(-2), 0, 0, 0, 0, 0x0053);
    }

    public static int[] GetClientSize(IntPtr hWnd)
    {
        if (!GetClientRect(hWnd, out RECT rect))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "GetClientRect failed");
        return new int[] { rect.Right - rect.Left, rect.Bottom - rect.Top };
    }

    public static bool ClientEvidencePointsAreUnobscured(IntPtr hWnd, int[] sampleCoordinates)
    {
        if (!GetClientRect(hWnd, out RECT rect)) return false;
        int width = rect.Right - rect.Left, height = rect.Bottom - rect.Top;
        if (width <= 0 || height <= 0 || sampleCoordinates == null || sampleCoordinates.Length < 2 || sampleCoordinates.Length % 2 != 0) return false;
        List<POINT> points = new List<POINT>();
        int[] xs = new int[] { 1, width / 4, width / 2, (width * 3) / 4, width - 2 };
        int[] ys = new int[] { 1, height / 4, height / 2, (height * 3) / 4, height - 2 };
        foreach (int y in ys) foreach (int x in xs) points.Add(new POINT { X = x, Y = y });
        // 额外验证实际用于像素断言的 5 个物理坐标，避免高 DPI 缩放后检查错位。
        for (int index = 0; index < sampleCoordinates.Length; index += 2)
        {
            int x = sampleCoordinates[index], y = sampleCoordinates[index + 1];
            if (x < 0 || x >= width || y < 0 || y >= height) return false;
            points.Add(new POINT { X = x, Y = y });
        }
        foreach (POINT clientPoint in points)
        {
            POINT screenPoint = clientPoint;
            if (!ClientToScreen(hWnd, ref screenPoint)) return false;
            IntPtr hit = WindowFromPoint(screenPoint);
            if (hit == IntPtr.Zero || GetAncestor(hit, 2) != hWnd) return false;
        }
        return true;
    }

    public static IntPtr FindVisibleWindow(int processId)
    {
        IntPtr best = IntPtr.Zero;
        long bestArea = 0;
        EnumWindows((window, _) =>
        {
            if (!IsWindowVisible(window) || IsIconic(window)) return true;
            GetWindowThreadProcessId(window, out uint owner);
            if (owner != (uint)processId || !GetClientRect(window, out RECT rect)) return true;
            long area = Math.Max(0, rect.Right - rect.Left) * (long)Math.Max(0, rect.Bottom - rect.Top);
            if (area > bestArea) { best = window; bestArea = area; }
            return true;
        }, IntPtr.Zero);
        return best;
    }

    public static KadathClientCapture CaptureClient(IntPtr hWnd)
    {
        if (GetOwnerProcessId(hWnd) == 0) throw new InvalidOperationException("Window has no owner process.");
        if (!GetClientRect(hWnd, out RECT rect)) throw new Win32Exception(Marshal.GetLastWin32Error(), "GetClientRect failed");
        int width = rect.Right - rect.Left, height = rect.Bottom - rect.Top;
        if (width <= 0 || height <= 0) throw new InvalidOperationException("Runtime client area is empty.");
        POINT origin = new POINT();
        if (!ClientToScreen(hWnd, ref origin)) throw new Win32Exception(Marshal.GetLastWin32Error(), "ClientToScreen failed");

        IntPtr screen = GetDC(IntPtr.Zero), memory = IntPtr.Zero, bitmap = IntPtr.Zero, previous = IntPtr.Zero, bits = IntPtr.Zero;
        if (screen == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "GetDC failed");
        try
        {
            memory = CreateCompatibleDC(screen);
            if (memory == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateCompatibleDC failed");
            BITMAPINFO info = new BITMAPINFO
            {
                bmiHeader = new BITMAPINFOHEADER
                {
                    biSize = (uint)Marshal.SizeOf<BITMAPINFOHEADER>(), biWidth = width, biHeight = -height,
                    biPlanes = 1, biBitCount = 32, biCompression = 0, biSizeImage = checked((uint)(width * height * 4))
                },
                bmiColors = new uint[4]
            };
            bitmap = CreateDIBSection(screen, ref info, DIB_RGB_COLORS, out bits, IntPtr.Zero, 0);
            if (bitmap == IntPtr.Zero || bits == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateDIBSection failed");
            previous = SelectObject(memory, bitmap);
            if (previous == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "SelectObject failed");
            if (!BitBlt(memory, 0, 0, width, height, screen, origin.X, origin.Y, SRCCOPY | CAPTUREBLT))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "BitBlt failed");
            byte[] bgra = new byte[checked(width * height * 4)];
            Marshal.Copy(bits, bgra, 0, bgra.Length);
            return new KadathClientCapture { Left = origin.X, Top = origin.Y, Width = width, Height = height, Bgra = bgra };
        }
        finally
        {
            if (previous != IntPtr.Zero && memory != IntPtr.Zero) SelectObject(memory, previous);
            if (bitmap != IntPtr.Zero) DeleteObject(bitmap);
            if (memory != IntPtr.Zero) DeleteDC(memory);
            ReleaseDC(IntPtr.Zero, screen);
        }
    }

    public static int[] SampleRgb(KadathClientCapture capture, int x, int y)
    {
        if (x < 0 || y < 0 || x >= capture.Width || y >= capture.Height) throw new ArgumentOutOfRangeException("sample");
        int offset = checked((y * capture.Width + x) * 4);
        return new int[] { capture.Bgra[offset + 2], capture.Bgra[offset + 1], capture.Bgra[offset] };
    }

    public static void WritePng(string path, KadathClientCapture capture)
    {
        // verifier 自己写 PNG；不使用 System.Drawing，也不复用生产 decoder。
        int stride = checked(capture.Width * 4);
        byte[] rows = new byte[checked(capture.Height * (stride + 1))];
        for (int y = 0; y < capture.Height; y++)
        {
            int row = y * (stride + 1), source = y * stride;
            rows[row] = 0;
            for (int x = 0; x < capture.Width; x++)
            {
                int input = source + x * 4, output = row + 1 + x * 4;
                rows[output] = capture.Bgra[input + 2];
                rows[output + 1] = capture.Bgra[input + 1];
                rows[output + 2] = capture.Bgra[input];
                rows[output + 3] = 255;
            }
        }
        byte[] compressed;
        using (MemoryStream stream = new MemoryStream())
        {
            using (ZLibStream zlib = new ZLibStream(stream, CompressionLevel.Optimal, true)) zlib.Write(rows, 0, rows.Length);
            compressed = stream.ToArray();
        }
        using FileStream file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        file.Write(new byte[] { 137,80,78,71,13,10,26,10 });
        byte[] header = new byte[13];
        WriteUInt32(header, 0, (uint)capture.Width); WriteUInt32(header, 4, (uint)capture.Height);
        header[8] = 8; header[9] = 6;
        WriteChunk(file, "IHDR", header); WriteChunk(file, "IDAT", compressed); WriteChunk(file, "IEND", Array.Empty<byte>());
        file.Flush(true);
    }

    private static void WriteChunk(Stream output, string type, byte[] data)
    {
        byte[] typeBytes = System.Text.Encoding.ASCII.GetBytes(type), length = new byte[4], crcBytes = new byte[4];
        WriteUInt32(length, 0, (uint)data.Length); output.Write(length); output.Write(typeBytes); output.Write(data);
        uint crc = Crc32(typeBytes, data); WriteUInt32(crcBytes, 0, crc); output.Write(crcBytes);
    }

    private static void WriteUInt32(byte[] output, int offset, uint value)
    {
        output[offset] = (byte)(value >> 24); output[offset + 1] = (byte)(value >> 16);
        output[offset + 2] = (byte)(value >> 8); output[offset + 3] = (byte)value;
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
        for (int bit = 0; bit < 8; bit++) crc = (crc & 1u) != 0 ? 0xedb88320u ^ (crc >> 1) : crc >> 1;
        return crc;
    }
}
'@

$runtimeStartAttempted = $false
try {

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
    if (((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Name root cannot be a reparse point: $current" }
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

function Resolve-CanonicalDirectory([string]$Path, [string]$Name) {
    Assert-NoWin32DevicePath $Path $Name
    if (-not [IO.Path]::IsPathFullyQualified($Path)) { throw "$Name must be a fully qualified local path: $Path" }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "$Name does not exist: $Path" }
    $full = [IO.Path]::GetFullPath($Path)
    Assert-NoReparsePointInExistingPath $full $Name
    return (Resolve-Path -LiteralPath $full).Path
}

function Resolve-CanonicalFile([string]$Path, [string]$Name) {
    Assert-NoWin32DevicePath $Path $Name
    if (-not [IO.Path]::IsPathFullyQualified($Path)) { throw "$Name must be a fully qualified local path: $Path" }
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $Path.Equals($full, [StringComparison]::OrdinalIgnoreCase)) { throw "$Name must use its canonical absolute spelling: $Path" }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "$Name does not exist or is not a regular file: $full" }
    Assert-NoReparsePointInExistingPath $full $Name
    $file = Get-Item -LiteralPath $full -Force
    if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Name cannot be a reparse point: $full" }
    return (Resolve-Path -LiteralPath $full).Path
}

function Invoke-GitLines([string]$Root, [string[]]$Arguments, [string]$Name) {
    $output = @(& git -C $Root @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "$Name failed: $($output -join [Environment]::NewLine)" }
    return @($output | ForEach-Object { [string]$_ })
}

function Resolve-PackageFile([string]$Root, [string]$RelativePath, [string]$Name) {
    if ([IO.Path]::IsPathRooted($RelativePath)) { throw "$Name must be relative to PackageRoot: $RelativePath" }
    $path = [IO.Path]::GetFullPath((Join-Path $Root $RelativePath))
    $prefix = $Root.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "$Name escapes PackageRoot: $RelativePath" }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "$Name does not exist: $path" }
    Assert-NoReparsePointInExistingPath $path $Name
    return $path
}

function Get-Hash([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

function Get-IdentitySnapshot([Collections.IDictionary]$Paths) {
    $snapshot = [ordered]@{}
    foreach ($name in $Paths.Keys) {
        $entry = $Paths[$name]
        $file = Get-Item -LiteralPath ([string]$entry.Path) -Force
        $snapshot[$name] = [ordered]@{
            RelativePath = [string]$entry.RelativePath
            Length = [int64]$file.Length
            Sha256 = Get-Hash ([string]$entry.Path)
        }
    }
    return $snapshot
}

function Assert-IdentityUnchanged([Collections.IDictionary]$Before, [Collections.IDictionary]$After) {
    if ($Before.Count -ne $After.Count) { throw 'Runtime identity set changed after preflight' }
    foreach ($name in $Before.Keys) {
        if (-not $After.Contains($name) -or
            [string]$Before[$name].RelativePath -cne [string]$After[$name].RelativePath -or
            [int64]$Before[$name].Length -ne [int64]$After[$name].Length -or
            [string]$Before[$name].Sha256 -cne [string]$After[$name].Sha256) {
            throw "Runtime identity file changed after preflight: $name"
        }
    }
}

function Get-SampleCoordinates([int]$ClientWidth, [int]$ClientHeight, [int]$RenderWidth, [int]$RenderHeight) {
    if ($RenderWidth -le 552 -or $RenderHeight -le 310) { throw "Runtime render extent is too small for frozen logical samples: ${RenderWidth}x${RenderHeight}" }
    $scaleX = $ClientWidth / [double]$RenderWidth
    $scaleY = $ClientHeight / [double]$RenderHeight
    if ([double]::IsNaN($scaleX) -or [double]::IsInfinity($scaleX) -or $scaleX -le 0 -or
        [double]::IsNaN($scaleY) -or [double]::IsInfinity($scaleY) -or $scaleY -le 0) {
        throw "Runtime logical-to-physical scale is invalid: scaleX=$scaleX scaleY=$scaleY"
    }
    $scaleTolerance = [math]::Max(0.02, [math]::Max($scaleX, $scaleY) * 0.01)
    if ([math]::Abs($scaleX - $scaleY) -gt $scaleTolerance) {
        throw "Runtime client scaling is non-uniform: scaleX=$scaleX scaleY=$scaleY tolerance=$scaleTolerance"
    }

    $logicalPoints = [ordered]@{
        Background = @(100, 100)
        Alpha0 = @(392, 190)
        Alpha64 = @(552, 190)
        Alpha128 = @(392, 310)
        Alpha255 = @(552, 310)
    }
    $coordinates = [ordered]@{}
    $physicalFlat = [Collections.Generic.List[int]]::new()
    foreach ($entry in $logicalPoints.GetEnumerator()) {
        # 以像素中心映射逻辑坐标，避免 2x DPI 下出现半像素偏移。
        $physicalX = [int][math]::Round((($entry.Value[0] + 0.5) * $scaleX) - 0.5, [MidpointRounding]::AwayFromZero)
        $physicalY = [int][math]::Round((($entry.Value[1] + 0.5) * $scaleY) - 0.5, [MidpointRounding]::AwayFromZero)
        if ($physicalX -lt 0 -or $physicalX -ge $ClientWidth -or $physicalY -lt 0 -or $physicalY -ge $ClientHeight) {
            throw "Mapped sample $($entry.Key) escapes the physical client: logical=$($entry.Value -join ',') physical=$physicalX,$physicalY client=${ClientWidth}x${ClientHeight}"
        }
        $coordinates[$entry.Key] = [ordered]@{ Logical = @($entry.Value); Physical = @($physicalX, $physicalY) }
        $physicalFlat.Add($physicalX)
        $physicalFlat.Add($physicalY)
    }
    return [pscustomobject]@{
        RenderWidth = $RenderWidth
        RenderHeight = $RenderHeight
        ClientWidth = $ClientWidth
        ClientHeight = $ClientHeight
        ScaleX = $scaleX
        ScaleY = $scaleY
        Coordinates = $coordinates
        PhysicalFlat = [int[]]$physicalFlat.ToArray()
    }
}

function Get-SampleEvidence([KadathClientCapture]$Capture, [int]$RenderWidth, [int]$RenderHeight) {
    $mapping = Get-SampleCoordinates $Capture.Width $Capture.Height $RenderWidth $RenderHeight
    $background = [KadathPngRuntimeNative]::SampleRgb($Capture, $mapping.Coordinates.Background.Physical[0], $mapping.Coordinates.Background.Physical[1])
    $topLeft = [KadathPngRuntimeNative]::SampleRgb($Capture, $mapping.Coordinates.Alpha0.Physical[0], $mapping.Coordinates.Alpha0.Physical[1])
    $topRight = [KadathPngRuntimeNative]::SampleRgb($Capture, $mapping.Coordinates.Alpha64.Physical[0], $mapping.Coordinates.Alpha64.Physical[1])
    $bottomLeft = [KadathPngRuntimeNative]::SampleRgb($Capture, $mapping.Coordinates.Alpha128.Physical[0], $mapping.Coordinates.Alpha128.Physical[1])
    $bottomRight = [KadathPngRuntimeNative]::SampleRgb($Capture, $mapping.Coordinates.Alpha255.Physical[0], $mapping.Coordinates.Alpha255.Physical[1])
    $distance64 = [math]::Sqrt([math]::Pow($topRight[0] - $background[0], 2) + [math]::Pow($topRight[1] - $background[1], 2) + [math]::Pow($topRight[2] - $background[2], 2))
    $distance128 = [math]::Sqrt([math]::Pow($bottomLeft[0] - $background[0], 2) + [math]::Pow($bottomLeft[1] - $background[1], 2) + [math]::Pow($bottomLeft[2] - $background[2], 2))
    $alphaPasses = $true
    for ($channel = 0; $channel -lt 3; $channel++) {
        if ([math]::Abs($topLeft[$channel] - $background[$channel]) -gt 24) { $alphaPasses = $false }
        if ($bottomRight[$channel] -lt 230) { $alphaPasses = $false }
    }
    if ($distance64 -le 32 -or $distance128 -lt ($distance64 + 16)) { $alphaPasses = $false }
    return [pscustomobject]@{
        Passed = $alphaPasses
        AlphaPassed = $alphaPasses
        Background = @($background)
        Alpha0 = @($topLeft)
        Alpha64 = @($topRight)
        Alpha128 = @($bottomLeft)
        Alpha255 = @($bottomRight)
        Distance64 = $distance64
        Distance128 = $distance128
        RenderWidth = $mapping.RenderWidth
        RenderHeight = $mapping.RenderHeight
        ScaleX = $mapping.ScaleX
        ScaleY = $mapping.ScaleY
        Coordinates = $mapping.Coordinates
    }
}

$rawPathInputs = @(
    [pscustomobject]@{ Path = $KadathRoot; Name = 'KadathRoot' },
    [pscustomobject]@{ Path = $PackageRoot; Name = 'PackageRoot' },
    [pscustomobject]@{ Path = $EvidenceDirectory; Name = 'EvidenceDirectory' },
    [pscustomobject]@{ Path = $TaskLocalCacheDirectory; Name = 'TaskLocalCacheDirectory' },
    [pscustomobject]@{ Path = $GlobalCacheDirectory; Name = 'GlobalCacheDirectory' },
    [pscustomobject]@{ Path = $PreflightSidecarPath; Name = 'PreflightSidecarPath' },
    [pscustomobject]@{ Path = $BuildCommandEvidencePath; Name = 'BuildCommandEvidencePath' }
)
foreach ($rawPath in $rawPathInputs) {
    Assert-NoWin32DevicePath $rawPath.Path $rawPath.Name
    if (-not [IO.Path]::IsPathFullyQualified($rawPath.Path)) { throw "$($rawPath.Name) must be a fully qualified local path: $($rawPath.Path)" }
}

$expectedKadathRoot = Resolve-CanonicalDirectory (Split-Path -Parent $PSScriptRoot) 'Verifier repository root'
$kadath = Resolve-CanonicalDirectory $KadathRoot 'KadathRoot'
if (-not $kadath.Equals($expectedKadathRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "KadathRoot must be the Inner worktree containing this verifier: expected=$expectedKadathRoot actual=$kadath"
}

$package = Resolve-CanonicalDirectory $PackageRoot 'PackageRoot'
$taskLocalCache = Resolve-CanonicalDirectory $TaskLocalCacheDirectory 'TaskLocalCacheDirectory'
$globalCache = Resolve-CanonicalDirectory $GlobalCacheDirectory 'GlobalCacheDirectory'
$defaultZigOut = [IO.Path]::GetFullPath((Join-Path $kadath 'zig-out'))
if (Test-DirectoryContains $defaultZigOut $package) {
    throw 'Runtime PNG evidence rejects the repository default zig-out and every descendant; use a fresh isolated ReleaseSafe prefix'
}

Assert-NoWin32DevicePath $EvidenceDirectory 'EvidenceDirectory'
if (-not [IO.Path]::IsPathFullyQualified($EvidenceDirectory)) { throw "EvidenceDirectory must be a fully qualified local path: $EvidenceDirectory" }
$evidence = [IO.Path]::GetFullPath($EvidenceDirectory)
if (Test-Path -LiteralPath $evidence) { throw "EvidenceDirectory already exists: $evidence" }
if ($evidence -eq [IO.Path]::GetPathRoot($evidence)) { throw 'EvidenceDirectory cannot be a filesystem root' }
Assert-NoReparsePointInExistingPath $evidence 'EvidenceDirectory'

$rootSet = @(
    [pscustomobject]@{ Path = $kadath; Name = 'KadathRoot' },
    [pscustomobject]@{ Path = $package; Name = 'PackageRoot' },
    [pscustomobject]@{ Path = $taskLocalCache; Name = 'TaskLocalCacheDirectory' },
    [pscustomobject]@{ Path = $globalCache; Name = 'GlobalCacheDirectory' },
    [pscustomobject]@{ Path = $evidence; Name = 'EvidenceDirectory' }
)
for ($leftIndex = 0; $leftIndex -lt $rootSet.Count; $leftIndex++) {
    for ($rightIndex = $leftIndex + 1; $rightIndex -lt $rootSet.Count; $rightIndex++) {
        Assert-DisjointDirectories ($rootSet[$leftIndex].Path) ($rootSet[$leftIndex].Name) ($rootSet[$rightIndex].Path) ($rootSet[$rightIndex].Name)
    }
}

$preflightSidecar = Resolve-CanonicalFile $PreflightSidecarPath 'PreflightSidecarPath'
$buildCommandEvidencePath = Resolve-CanonicalFile $BuildCommandEvidencePath 'BuildCommandEvidencePath'
if ($preflightSidecar.Equals($buildCommandEvidencePath, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'PreflightSidecarPath and BuildCommandEvidencePath must be distinct files'
}
foreach ($rootEntry in $rootSet) {
    if (Test-DirectoryContains $rootEntry.Path $preflightSidecar) {
        throw "PreflightSidecarPath must stay outside $($rootEntry.Name): $preflightSidecar"
    }
    if (Test-DirectoryContains $rootEntry.Path $buildCommandEvidencePath) {
        throw "BuildCommandEvidencePath must stay outside $($rootEntry.Name): $buildCommandEvidencePath"
    }
}
[byte[]]$preflightBytes = [IO.File]::ReadAllBytes($preflightSidecar)
if ($preflightBytes.Length -eq 0 -or $preflightBytes.Length -gt 65536) { throw 'Preflight sidecar must contain 1..65536 bytes' }
$preflightSidecarSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($preflightBytes)).ToLowerInvariant()
try {
    $preflightJson = [Text.UTF8Encoding]::new($false, $true).GetString($preflightBytes)
    $preflight = $preflightJson | ConvertFrom-Json
    $preflightJsonDocument = [System.Text.Json.JsonDocument]::Parse($preflightJson)
    try { $preflightGeneratedAtText = $preflightJsonDocument.RootElement.GetProperty('GeneratedAtUtc').GetString() } finally { $preflightJsonDocument.Dispose() }
} catch {
    throw "Preflight sidecar is not strict UTF-8 JSON: $($_.Exception.Message)"
}
$preflightGeneratedAt = [DateTimeOffset]::MinValue
if ([string]::IsNullOrWhiteSpace($preflightGeneratedAtText) -or
    -not [DateTimeOffset]::TryParseExact($preflightGeneratedAtText, 'O', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$preflightGeneratedAt) -or
    $preflightGeneratedAt.Offset -ne [TimeSpan]::Zero) {
    throw 'Preflight GeneratedAtUtc must be a valid UTC timestamp'
}
$preflightSidecarInfo = Get-Item -LiteralPath $preflightSidecar -Force
$rootCreationTimesUtc = [ordered]@{}
$timestampTolerance = [TimeSpan]::FromSeconds(2)
if ([math]::Abs(($preflightGeneratedAt.UtcDateTime - $preflightSidecarInfo.LastWriteTimeUtc).TotalSeconds) -gt $timestampTolerance.TotalSeconds) {
    throw 'Preflight GeneratedAtUtc and sidecar LastWriteTimeUtc differ by more than 2 seconds'
}
foreach ($rootEntry in @(
    [pscustomobject]@{ Path = $package; Name = 'PackageRoot' },
    [pscustomobject]@{ Path = $taskLocalCache; Name = 'TaskLocalCacheDirectory' },
    [pscustomobject]@{ Path = $globalCache; Name = 'GlobalCacheDirectory' }
)) {
    $rootInfo = Get-Item -LiteralPath $rootEntry.Path -Force
    $rootCreationTimesUtc[$rootEntry.Name] = $rootInfo.CreationTimeUtc.ToString('O')
    $latestWitnessTime = $rootInfo.CreationTimeUtc + $timestampTolerance
    if ($preflightGeneratedAt.UtcDateTime -gt $latestWitnessTime -or $preflightSidecarInfo.LastWriteTimeUtc -gt $latestWitnessTime) {
        throw "Preflight witness is newer than $($rootEntry.Name) creation time"
    }
}
$claimedRoots = @(
    [pscustomobject]@{ Value = [string]$preflight.PackageRoot; Expected = $package; Name = 'PackageRoot' },
    [pscustomobject]@{ Value = [string]$preflight.TaskLocalCacheDirectory; Expected = $taskLocalCache; Name = 'TaskLocalCacheDirectory' },
    [pscustomobject]@{ Value = [string]$preflight.GlobalCacheDirectory; Expected = $globalCache; Name = 'GlobalCacheDirectory' }
)
foreach ($claimed in $claimedRoots) {
    if ([string]::IsNullOrWhiteSpace($claimed.Value) -or -not [IO.Path]::IsPathFullyQualified($claimed.Value)) {
        throw "Preflight $($claimed.Name) must be a canonical absolute path"
    }
    Assert-NoWin32DevicePath $claimed.Value "Preflight $($claimed.Name)"
    $claimedFull = [IO.Path]::GetFullPath($claimed.Value)
    if (-not $claimed.Value.Equals($claimedFull, [StringComparison]::OrdinalIgnoreCase) -or
        -not $claimedFull.Equals($claimed.Expected, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Preflight $($claimed.Name) does not match this invocation: claimed=$($claimed.Value) actual=$($claimed.Expected)"
    }
}
if ([int]$preflight.Version -ne 1 -or
    ($preflight.PackageRootAbsentBefore -isnot [bool]) -or -not $preflight.PackageRootAbsentBefore -or
    ($preflight.TaskLocalCacheAbsentBefore -isnot [bool]) -or -not $preflight.TaskLocalCacheAbsentBefore -or
    ($preflight.GlobalCacheAbsentBefore -isnot [bool]) -or -not $preflight.GlobalCacheAbsentBefore) {
    throw 'Preflight sidecar must be v1 and prove all package/cache roots were absent before build'
}

# 构建命令证据冻结真实 argv，避免仅凭可伪造的目录快照推断 ReleaseSafe 构建方式。
[byte[]]$buildCommandEvidenceBytes = [IO.File]::ReadAllBytes($buildCommandEvidencePath)
if ($buildCommandEvidenceBytes.Length -eq 0 -or $buildCommandEvidenceBytes.Length -gt 65536) { throw 'Build command evidence must contain 1..65536 bytes' }
$buildCommandEvidenceSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($buildCommandEvidenceBytes)).ToLowerInvariant()
try {
    $buildCommandEvidenceJson = [Text.UTF8Encoding]::new($false, $true).GetString($buildCommandEvidenceBytes)
    $buildCommandJsonDocument = [System.Text.Json.JsonDocument]::Parse($buildCommandEvidenceJson)
    try {
        if ($buildCommandJsonDocument.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { throw 'root must be an object' }
        $expectedPropertyNames = @('Version', 'Executable', 'Arguments', 'WorkingDirectory', 'StartedAtUtc', 'EndedAtUtc', 'ExitCode', 'PackageRoot', 'TaskLocalCacheDirectory', 'GlobalCacheDirectory') | Sort-Object
        $actualPropertyNames = @($buildCommandJsonDocument.RootElement.EnumerateObject() | ForEach-Object { $_.Name }) | Sort-Object
        if ($actualPropertyNames.Count -ne $expectedPropertyNames.Count -or @(Compare-Object -ReferenceObject $expectedPropertyNames -DifferenceObject $actualPropertyNames -CaseSensitive).Count -ne 0) {
            throw 'properties do not exactly match schema v1'
        }
        $versionElement = $buildCommandJsonDocument.RootElement.GetProperty('Version')
        $executableElement = $buildCommandJsonDocument.RootElement.GetProperty('Executable')
        $argumentsElement = $buildCommandJsonDocument.RootElement.GetProperty('Arguments')
        $workingDirectoryElement = $buildCommandJsonDocument.RootElement.GetProperty('WorkingDirectory')
        $startedElement = $buildCommandJsonDocument.RootElement.GetProperty('StartedAtUtc')
        $endedElement = $buildCommandJsonDocument.RootElement.GetProperty('EndedAtUtc')
        $exitCodeElement = $buildCommandJsonDocument.RootElement.GetProperty('ExitCode')
        $packageRootElement = $buildCommandJsonDocument.RootElement.GetProperty('PackageRoot')
        $localCacheElement = $buildCommandJsonDocument.RootElement.GetProperty('TaskLocalCacheDirectory')
        $globalCacheElement = $buildCommandJsonDocument.RootElement.GetProperty('GlobalCacheDirectory')
        if ($versionElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Number -or
            $executableElement.ValueKind -ne [System.Text.Json.JsonValueKind]::String -or
            $argumentsElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Array -or
            $workingDirectoryElement.ValueKind -ne [System.Text.Json.JsonValueKind]::String -or
            $startedElement.ValueKind -ne [System.Text.Json.JsonValueKind]::String -or
            $endedElement.ValueKind -ne [System.Text.Json.JsonValueKind]::String -or
            $exitCodeElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Number -or
            $packageRootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::String -or
            $localCacheElement.ValueKind -ne [System.Text.Json.JsonValueKind]::String -or
            $globalCacheElement.ValueKind -ne [System.Text.Json.JsonValueKind]::String) {
            throw 'property types do not match schema v1'
        }
        $buildCommandVersion = $versionElement.GetInt32()
        $buildCommandExecutable = $executableElement.GetString()
        $buildCommandArguments = [Collections.Generic.List[string]]::new()
        foreach ($argumentElement in $argumentsElement.EnumerateArray()) {
            if ($argumentElement.ValueKind -ne [System.Text.Json.JsonValueKind]::String) { throw 'Arguments must contain only strings' }
            $buildCommandArguments.Add($argumentElement.GetString())
        }
        $buildCommandWorkingDirectory = $workingDirectoryElement.GetString()
        $buildCommandStartedAtText = $startedElement.GetString()
        $buildCommandEndedAtText = $endedElement.GetString()
        $buildCommandExitCode = $exitCodeElement.GetInt32()
        $buildCommandPackageRoot = $packageRootElement.GetString()
        $buildCommandLocalCache = $localCacheElement.GetString()
        $buildCommandGlobalCache = $globalCacheElement.GetString()
    } finally {
        $buildCommandJsonDocument.Dispose()
    }
} catch {
    throw "Build command evidence is not strict UTF-8 JSON schema v1: $($_.Exception.Message)"
}
$buildCommandStartedAt = [DateTimeOffset]::MinValue
$buildCommandEndedAt = [DateTimeOffset]::MinValue
if (-not [DateTimeOffset]::TryParseExact($buildCommandStartedAtText, 'O', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$buildCommandStartedAt) -or
    -not [DateTimeOffset]::TryParseExact($buildCommandEndedAtText, 'O', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$buildCommandEndedAt) -or
    $buildCommandStartedAt.Offset -ne [TimeSpan]::Zero -or $buildCommandEndedAt.Offset -ne [TimeSpan]::Zero -or
    $buildCommandStartedAt -gt $buildCommandEndedAt) {
    throw 'Build command evidence timestamps must be ordered UTC O-format values'
}
$expectedBuildArguments = [string[]]@(
    'build',
    'package',
    '-Doptimize=ReleaseSafe',
    '--prefix', $package,
    '--cache-dir', $taskLocalCache,
    '--global-cache-dir', $globalCache,
    "-Druntime-preflight-sidecar=$preflightSidecar"
)
$zigCommand = Get-Command zig -CommandType Application -ErrorAction Stop | Select-Object -First 1
$expectedZigExecutable = Resolve-CanonicalFile ([string]$zigCommand.Source) 'Resolved Zig executable'
if (-not [IO.Path]::IsPathFullyQualified($buildCommandExecutable) -or
    -not $buildCommandExecutable.Equals([IO.Path]::GetFullPath($buildCommandExecutable), [StringComparison]::OrdinalIgnoreCase) -or
    $buildCommandVersion -ne 1 -or
    -not $buildCommandExecutable.Equals($expectedZigExecutable, [StringComparison]::OrdinalIgnoreCase) -or $buildCommandExitCode -ne 0 -or
    -not $buildCommandWorkingDirectory.Equals($kadath, [StringComparison]::OrdinalIgnoreCase) -or
    -not $buildCommandPackageRoot.Equals($package, [StringComparison]::OrdinalIgnoreCase) -or
    -not $buildCommandLocalCache.Equals($taskLocalCache, [StringComparison]::OrdinalIgnoreCase) -or
    -not $buildCommandGlobalCache.Equals($globalCache, [StringComparison]::OrdinalIgnoreCase) -or
    $buildCommandArguments.Count -ne $expectedBuildArguments.Count) {
    throw 'Build command evidence does not describe this successful isolated ReleaseSafe build'
}
for ($argumentIndex = 0; $argumentIndex -lt $expectedBuildArguments.Count; $argumentIndex++) {
    if ($buildCommandArguments[$argumentIndex] -cne $expectedBuildArguments[$argumentIndex]) {
        throw "Build command evidence argv mismatch at index ${argumentIndex}"
    }
}
$buildCommandEvidence = [ordered]@{
    Version = $buildCommandVersion
    Executable = $buildCommandExecutable
    Arguments = [string[]]$buildCommandArguments.ToArray()
    WorkingDirectory = $buildCommandWorkingDirectory
    StartedAtUtc = $buildCommandStartedAt.ToString('O')
    EndedAtUtc = $buildCommandEndedAt.ToString('O')
    ExitCode = $buildCommandExitCode
    PackageRoot = $buildCommandPackageRoot
    TaskLocalCacheDirectory = $buildCommandLocalCache
    GlobalCacheDirectory = $buildCommandGlobalCache
}

$vertexShaderPath = [IO.Path]::GetFullPath((Join-Path $kadath 'shaders\renderer2d\quad.vert.glsl'))
$fragmentShaderPath = [IO.Path]::GetFullPath((Join-Path $kadath 'shaders\renderer2d\quad.frag.glsl'))
foreach ($shader in @(
    [pscustomobject]@{ Path = $vertexShaderPath; Name = 'Vertex shader source' },
    [pscustomobject]@{ Path = $fragmentShaderPath; Name = 'Fragment shader source' }
)) {
    if (-not (Test-Path -LiteralPath $shader.Path -PathType Leaf)) { throw "$($shader.Name) does not exist: $($shader.Path)" }
    Assert-NoReparsePointInExistingPath $shader.Path $shader.Name
}
$vertexShaderSha256 = Get-Hash $vertexShaderPath
$fragmentShaderSha256 = Get-Hash $fragmentShaderPath

$runtime = Resolve-PackageFile $package 'bin\kadath.exe' 'Runtime executable'
$buildProfilePath = Resolve-PackageFile $package 'bin\kadath-runtime-build-profile.json' 'Runtime build profile marker'
$scene = Resolve-PackageFile $package 'bin\assets\scenes\preview.scene.json' 'Scene source'
$script = Resolve-PackageFile $package 'bin\assets\scripts\preview.script.json' 'Script source'
$source = Resolve-PackageFile $package 'bin\assets\renderer2d\test.png' 'PNG source'
$texture = Resolve-PackageFile $package 'bin\assets\renderer2d\test.texture' 'KDAT texture'
[byte[]]$buildProfileBytes = [IO.File]::ReadAllBytes($buildProfilePath)
if ($buildProfileBytes.Length -eq 0 -or $buildProfileBytes.Length -gt 65536) { throw 'Runtime build profile marker must contain 1..65536 bytes' }
$buildProfileMarkerSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($buildProfileBytes)).ToLowerInvariant()
try {
    $buildProfileJson = [Text.UTF8Encoding]::new($false, $true).GetString($buildProfileBytes)
    $buildProfileJsonDocument = [System.Text.Json.JsonDocument]::Parse($buildProfileJson)
    try {
        $rootElement = $buildProfileJsonDocument.RootElement
        if ($rootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { throw 'root must be an object' }
        $expectedBuildProfileFields = [string[]]@('Version', 'Optimize', 'TextureProfile', 'RuntimeExeSha256', 'TextureSourceSha256', 'TextureArtifactSha256', 'VertexShaderSourceSha256', 'FragmentShaderSourceSha256', 'BuildPreflightSidecarSha256')
        $actualBuildProfileFields = @($rootElement.EnumerateObject() | ForEach-Object { $_.Name })
        $uniqueBuildProfileFields = @($actualBuildProfileFields | Sort-Object -Unique -CaseSensitive)
        if ($actualBuildProfileFields.Count -ne 9 -or $uniqueBuildProfileFields.Count -ne 9 -or
            @(Compare-Object -ReferenceObject ($expectedBuildProfileFields | Sort-Object) -DifferenceObject ($actualBuildProfileFields | Sort-Object) -CaseSensitive).Count -ne 0) {
            throw 'properties must be unique and exactly match the nine schema v1 names'
        }
        $versionElement = $rootElement.GetProperty('Version')
        if ($versionElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Number -or $versionElement.GetInt32() -ne 1) { throw 'Version must be the JSON number 1' }
        $stringFields = $expectedBuildProfileFields | Where-Object { $_ -cne 'Version' }
        foreach ($field in $stringFields) {
            if ($rootElement.GetProperty($field).ValueKind -ne [System.Text.Json.JsonValueKind]::String) { throw "$field must be a JSON string" }
        }
        $buildProfile = [pscustomobject][ordered]@{
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
        $buildProfileJsonDocument.Dispose()
    }
} catch {
    throw "Runtime build profile marker is not strict UTF-8 exact-nine JSON schema v1: $($_.Exception.Message)"
}
$runtimeExeSha256 = Get-Hash $runtime
$sourceSha256 = Get-Hash $source
[byte[]]$textureBytes = [IO.File]::ReadAllBytes($texture)
if ($textureBytes.Length -ne 44 -or [Text.Encoding]::ASCII.GetString($textureBytes, 0, 4) -cne 'KDAT' -or [BitConverter]::ToUInt32($textureBytes, 4) -ne 2 -or [BitConverter]::ToUInt32($textureBytes, 8) -ne 2 -or [BitConverter]::ToUInt32($textureBytes, 12) -ne 2 -or [BitConverter]::ToUInt32($textureBytes, 16) -ne 2 -or [BitConverter]::ToUInt32($textureBytes, 20) -ne 20) { throw 'Package texture is not the frozen KDAT v2 2x2 mip chain' }
$kdatSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($textureBytes)).ToLowerInvariant()
if ([int]$buildProfile.Version -ne 1 -or [string]$buildProfile.Optimize -cne 'ReleaseSafe' -or
    [string]$buildProfile.TextureProfile -cne 'release' -or
    [string]$buildProfile.RuntimeExeSha256 -cne $runtimeExeSha256 -or
    [string]$buildProfile.TextureSourceSha256 -cne $sourceSha256 -or
    [string]$buildProfile.TextureArtifactSha256 -cne $kdatSha256 -or
    [string]$buildProfile.VertexShaderSourceSha256 -cne $vertexShaderSha256 -or
    [string]$buildProfile.FragmentShaderSourceSha256 -cne $fragmentShaderSha256 -or
    [string]$buildProfile.BuildPreflightSidecarSha256 -cnotmatch '^[0-9a-f]{64}$' -or
    [string]$buildProfile.BuildPreflightSidecarSha256 -cne $preflightSidecarSha256) {
    throw 'Runtime PNG evidence requires a sidecar-bound v1 ReleaseSafe marker for this package/cache/exe/texture/shader identity'
}
if ($sourceSha256 -cne 'a6fab23c053638849d8b64ba72e260c22efb6e60a6876e36c662ae43a42e1eff') { throw 'Package PNG source identity is not the frozen 2x2 RGBA asset' }

# 所有 package/build evidence 已先完成无写入校验；启动 Runtime 前仍必须绑定当前干净 Inner HEAD/tree。
$gitStatus = @(Invoke-GitLines -Root $kadath -Arguments @('status', '--porcelain=v1', '--untracked-files=all') -Name 'git status')
if ($gitStatus.Count -ne 0) { throw "KadathRoot index/worktree is not clean: $($gitStatus -join '; ')" }
$gitHeadLines = @(Invoke-GitLines -Root $kadath -Arguments @('rev-parse', '--verify', 'HEAD') -Name 'git rev-parse HEAD')
$gitTreeLines = @(Invoke-GitLines -Root $kadath -Arguments @('rev-parse', '--verify', 'HEAD^{tree}') -Name 'git rev-parse HEAD tree')
if ($gitHeadLines.Count -ne 1 -or $gitHeadLines[0] -notmatch '^[0-9a-fA-F]{40}$' -or
    $gitTreeLines.Count -ne 1 -or $gitTreeLines[0] -notmatch '^[0-9a-fA-F]{40}$') {
    throw 'KadathRoot did not produce one valid HEAD and tree identity'
}
$gitHead = $gitHeadLines[0].ToLowerInvariant()
$gitTree = $gitTreeLines[0].ToLowerInvariant()

$identityPaths = [ordered]@{
    RuntimeExe = [pscustomobject]@{ Path = $runtime; RelativePath = 'package:bin/kadath.exe' }
    BuildProfileMarker = [pscustomobject]@{ Path = $buildProfilePath; RelativePath = 'package:bin/kadath-runtime-build-profile.json' }
    TextureSource = [pscustomobject]@{ Path = $source; RelativePath = 'package:bin/assets/renderer2d/test.png' }
    TextureArtifact = [pscustomobject]@{ Path = $texture; RelativePath = 'package:bin/assets/renderer2d/test.texture' }
    VertexShaderSource = [pscustomobject]@{ Path = $vertexShaderPath; RelativePath = 'repository:shaders/renderer2d/quad.vert.glsl' }
    FragmentShaderSource = [pscustomobject]@{ Path = $fragmentShaderPath; RelativePath = 'repository:shaders/renderer2d/quad.frag.glsl' }
    BuildPreflightSidecar = [pscustomobject]@{ Path = $preflightSidecar; RelativePath = 'external:runtime-preflight-sidecar.json' }
    BuildCommandEvidence = [pscustomobject]@{ Path = $buildCommandEvidencePath; RelativePath = 'external:zig-build-command-evidence.json' }
}
$identityBefore = Get-IdentitySnapshot $identityPaths
$identityAfter = $null

New-Item -ItemType Directory -Path $evidence | Out-Null
$stdoutPath = Join-Path $evidence 'runtime.stdout.log'
$stderrPath = Join-Path $evidence 'runtime.stderr.log'
$screenshotPath = Join-Path $evidence 'runtime-client.png'
$evidencePath = Join-Path $evidence 'texture-png-runtime.evidence.json'
$process = $null
$processCapture = $null
$window = [IntPtr]::Zero
$lastCapture = $null
$lastSamples = $null
$previousDpi = [IntPtr]::Zero
$forcedKill = $false
$passTimes = [Collections.Generic.List[string]]::new()
$windowOwnerPid = 0
$windowDpi = 0
$foregroundAcquired = $false
$renderWidth = 0
$renderHeight = 0
$scaleX = 0.0
$scaleY = 0.0
$sampleCoordinates = $null
$occlusionProbeCount = 0

try {
    $previousDpi = [KadathPngRuntimeNative]::EnterPerMonitorV2DpiAwareness()
    $workingDirectory = Split-Path -Parent $runtime
    $runtimeArguments = [string[]]@('--scene', [IO.Path]::GetRelativePath($workingDirectory, $scene).Replace('\','/'), '--script', [IO.Path]::GetRelativePath($workingDirectory, $script).Replace('\','/'))
    $runtimeStartAttempted = $true
    $processCapture = [KadathCapturedProcess]::Start($runtime, $workingDirectory, $runtimeArguments)
    $process = $processCapture.Process

    $readyDeadline = [DateTime]::UtcNow.AddSeconds(15)
    $runtimeLog = ''
    $ready = $false
    while ([DateTime]::UtcNow -lt $readyDeadline -and -not $process.HasExited) {
        $process.Refresh()
        $window = [KadathPngRuntimeNative]::FindVisibleWindow($process.Id)
        $runtimeLog = $processCapture.StderrText
        $ready = $runtimeLog.Contains('Runtime host initialized with Vulkan RHI entities') -and
            $runtimeLog.Contains('RHI texture created: handle=1, extent=2x2, mip_levels=2, upload_bytes=20') -and
            $runtimeLog.Contains('Renderer2D texture upload complete: mip_levels=2')
        if ($window -ne [IntPtr]::Zero -and $ready) { break }
        Start-Sleep -Milliseconds 100
    }
    if ($process.HasExited) { throw "Runtime exited before PNG evidence was ready: exit=$($process.ExitCode)" }
    if ($window -eq [IntPtr]::Zero) { throw 'Runtime did not expose a visible, non-minimized top-level window' }
    $windowOwnerPid = [KadathPngRuntimeNative]::GetOwnerProcessId($window)
    $windowDpi = [KadathPngRuntimeNative]::GetDpiForWindow($window)
    if ($windowOwnerPid -ne $process.Id) { throw 'Runtime HWND owner PID does not match the launched process' }
    if ($windowDpi -le 0) { throw 'Runtime window did not report a valid physical DPI' }
    if (-not $ready) { throw 'Runtime host/texture upload readiness evidence timed out' }
    if ($runtimeLog -match '(?im)\bVUID-|validation\s+error|VulkanCallFailed|error:') { throw 'Runtime log contains Vulkan validation/error evidence' }

    $extentMatches = [regex]::Matches($runtimeLog, '(?im)^.*Vulkan swapchain created:.*\bextent=(?<width>[1-9]\d*)x(?<height>[1-9]\d*)\b.*$')
    if ($extentMatches.Count -eq 0) { throw 'Runtime log does not contain a valid Vulkan swapchain extent' }
    $distinctExtents = @($extentMatches | ForEach-Object { "$($_.Groups['width'].Value)x$($_.Groups['height'].Value)" } | Sort-Object -Unique)
    if ($distinctExtents.Count -ne 1) { throw "Runtime log contains conflicting Vulkan swapchain extents: $($distinctExtents -join ', ')" }
    $renderWidth = [int]$extentMatches[0].Groups['width'].Value
    $renderHeight = [int]$extentMatches[0].Groups['height'].Value

    $foregroundAcquired = [KadathPngRuntimeNative]::PrepareUnobscuredCapture($window)
    Start-Sleep -Milliseconds 200
    $clientSize = [KadathPngRuntimeNative]::GetClientSize($window)
    if ($clientSize[0] -lt 553 -or $clientSize[1] -lt 311) {
        throw "Runtime physical client is too small for frozen samples: $($clientSize[0])x$($clientSize[1]) < 553x311"
    }
    $sampleCoordinates = Get-SampleCoordinates $clientSize[0] $clientSize[1] $renderWidth $renderHeight
    $occlusionProbeCount = 25 + ($sampleCoordinates.PhysicalFlat.Length / 2)
    $scaleX = $sampleCoordinates.ScaleX
    $scaleY = $sampleCoordinates.ScaleY
    if (-not [KadathPngRuntimeNative]::ClientEvidencePointsAreUnobscured($window, [int[]]$sampleCoordinates.PhysicalFlat)) { throw 'Runtime client grid/sample points are obscured; GDI capture is not trustworthy' }

    $captureDeadline = [DateTime]::UtcNow.AddSeconds(10)
    $previousPassed = $false
    $previousPassAt = [DateTime]::MinValue
    while ([DateTime]::UtcNow -lt $captureDeadline -and -not $process.HasExited) {
        if (-not [KadathPngRuntimeNative]::IsWindowVisible($window) -or [KadathPngRuntimeNative]::IsIconic($window) -or -not [KadathPngRuntimeNative]::ClientEvidencePointsAreUnobscured($window, [int[]]$sampleCoordinates.PhysicalFlat)) { throw 'Runtime window became hidden, minimized, or obscured during capture' }
        $lastCapture = [KadathPngRuntimeNative]::CaptureClient($window)
        if ($lastCapture.Width -ne $clientSize[0] -or $lastCapture.Height -ne $clientSize[1]) { throw "Runtime client area changed during evidence capture: initial=$($clientSize[0])x$($clientSize[1]) current=$($lastCapture.Width)x$($lastCapture.Height)" }
        $lastSamples = Get-SampleEvidence $lastCapture $renderWidth $renderHeight
        $now = [DateTime]::UtcNow
        if ($lastSamples.Passed) {
            $passTimes.Add($now.ToString('O'))
            if ($previousPassed -and ($now - $previousPassAt).TotalMilliseconds -ge 100) { break }
            $previousPassed = $true
            $previousPassAt = $now
        } else {
            $previousPassed = $false
            $passTimes.Clear()
        }
        Start-Sleep -Milliseconds 100
    }
    if ($passTimes.Count -lt 2 -or -not $lastSamples.Passed) { throw 'Runtime client pixels did not pass the alpha evidence on two consecutive captures' }
    [KadathPngRuntimeNative]::WritePng($screenshotPath, $lastCapture)

    [KadathPngRuntimeNative]::RestoreCaptureZOrder($window)
    if (-not [KadathPngRuntimeNative]::PostMessage($window, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)) { throw 'WM_CLOSE failed for Runtime window' }
    if (-not $processCapture.WaitForExit(10000)) { $forcedKill = $true; $process.Kill($true); $process.WaitForExit(); $processCapture.FlushLogs($stdoutPath, $stderrPath); throw 'Runtime did not exit within 10 seconds after WM_CLOSE' }
    if ($process.ExitCode -ne 0) { throw "Runtime exited with code $($process.ExitCode)" }
    $processCapture.FlushLogs($stdoutPath, $stderrPath)
    $runtimeLog = $processCapture.StderrText
    if (-not $runtimeLog.Contains('Kadath runtime shutdown complete')) { throw 'Runtime shutdown evidence is missing' }
    if ($runtimeLog -match '(?im)\bVUID-|validation\s+error|VulkanCallFailed|error:') { throw 'Runtime log contains Vulkan validation/error evidence' }
    $identityAfter = Get-IdentitySnapshot $identityPaths
    Assert-IdentityUnchanged $identityBefore $identityAfter

    $document = [ordered]@{
        VerificationVersion = 1
        KadathRoot = $kadath
        GitHead = $gitHead
        GitTree = $gitTree
        PackageRoot = $package
        TaskLocalCacheDirectory = $taskLocalCache
        GlobalCacheDirectory = $globalCache
        PreflightSidecarPath = $preflightSidecar
        PreflightSidecarSha256 = $preflightSidecarSha256
        BuildPreflight = $preflight
        PreflightGeneratedAtUtc = $preflightGeneratedAt.ToString('O')
        PreflightSidecarLastWriteTimeUtc = $preflightSidecarInfo.LastWriteTimeUtc.ToString('O')
        BuildRootCreationTimesUtc = $rootCreationTimesUtc
        BuildCommandEvidenceSha256 = $buildCommandEvidenceSha256
        BuildCommandEvidence = $buildCommandEvidence
        IdentityBefore = $identityBefore
        IdentityAfter = $identityAfter
        RuntimePid = $process.Id
        RuntimeExeSha256 = $runtimeExeSha256
        VertexShaderSourceSha256 = $vertexShaderSha256
        FragmentShaderSourceSha256 = $fragmentShaderSha256
        WindowHandle = ('0x{0:x}' -f $window.ToInt64())
        WindowOwnerPid = $windowOwnerPid
        Dpi = $windowDpi
        ClientLeft = $lastCapture.Left
        ClientTop = $lastCapture.Top
        ClientWidth = $lastCapture.Width
        ClientHeight = $lastCapture.Height
        RenderWidth = $renderWidth
        RenderHeight = $renderHeight
        ScaleX = $scaleX
        ScaleY = $scaleY
        ConsecutivePassTimesUtc = @($passTimes)
        Samples = $lastSamples
        SourceSha256 = $sourceSha256
        KdatSha256 = $kdatSha256
        BuildProfileMarkerSha256 = $buildProfileMarkerSha256
        BuildProfile = $buildProfile
        ScreenshotSha256 = Get-Hash $screenshotPath
        RuntimeExitCode = $process.ExitCode
        ForcedKill = $forcedKill
        ForegroundAcquired = $foregroundAcquired
        TopmostTemporary = $true
        OcclusionProbeCount = $occlusionProbeCount
        OcclusionProbesPassed = $occlusionProbeCount
        ClientEvidencePointsUnobscured = $true
        HostReady = $true
        TextureUploadReady = $true
        VulkanValidationErrors = 0
    }
    [IO.File]::WriteAllText($evidencePath, ($document | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))

    Write-Output "evidence_directory=$evidence"
    Write-Output "git_head=$gitHead"
    Write-Output "git_tree=$gitTree"
    Write-Output "package_root=$package"
    Write-Output "task_local_cache=$taskLocalCache"
    Write-Output "global_cache=$globalCache"
    Write-Output "preflight_sidecar_sha256=$preflightSidecarSha256"
    Write-Output "build_command_evidence_sha256=$buildCommandEvidenceSha256"
    Write-Output "runtime_exe_sha256=$runtimeExeSha256"
    Write-Output "build_profile_marker_sha256=$buildProfileMarkerSha256"
    Write-Output "runtime_pid=$($process.Id)"
    Write-Output "client_size=$($lastCapture.Width)x$($lastCapture.Height)"
    Write-Output "render_size=${renderWidth}x${renderHeight}"
    Write-Output "logical_to_physical_scale=$scaleX,$scaleY"
    Write-Output "dpi=$windowDpi"
    Write-Output 'alpha_samples=ok'
    Write-Output 'build_profile=ReleaseSafe'
    Write-Output 'consecutive_frames=2'
    Write-Output 'vulkan_validation=ok'
    Write-Output 'runtime_shutdown=ok'
    Write-Output 'verification=ok'
} catch {
    if ($null -ne $processCapture) { try { $processCapture.FlushLogs($stdoutPath, $stderrPath) } catch { } }
    if ($null -ne $lastCapture -and -not (Test-Path -LiteralPath $screenshotPath)) {
        try { [KadathPngRuntimeNative]::WritePng($screenshotPath, $lastCapture) } catch { }
    }
    if ($null -ne $process -and -not $process.HasExited) {
        if ($window -ne [IntPtr]::Zero) { [void][KadathPngRuntimeNative]::PostMessage($window, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) }
        if ($null -eq $processCapture -or -not $processCapture.WaitForExit(3000)) { $forcedKill = $true; $process.Kill($true); $process.WaitForExit() }
    }
    $identityAfter = Get-IdentitySnapshot $identityPaths
    Assert-IdentityUnchanged $identityBefore $identityAfter
    if (-not (Test-Path -LiteralPath $evidencePath)) {
        try {
            $failureDocument = [ordered]@{
                VerificationVersion = 1
                Failed = $true
                Error = $_.Exception.Message
                KadathRoot = $kadath
                GitHead = $gitHead
                GitTree = $gitTree
                PackageRoot = $package
                TaskLocalCacheDirectory = $taskLocalCache
                GlobalCacheDirectory = $globalCache
                PreflightSidecarPath = $preflightSidecar
                PreflightSidecarSha256 = $preflightSidecarSha256
                BuildPreflight = $preflight
                PreflightGeneratedAtUtc = $preflightGeneratedAt.ToString('O')
                PreflightSidecarLastWriteTimeUtc = $preflightSidecarInfo.LastWriteTimeUtc.ToString('O')
                BuildRootCreationTimesUtc = $rootCreationTimesUtc
                BuildCommandEvidenceSha256 = $buildCommandEvidenceSha256
                BuildCommandEvidence = $buildCommandEvidence
                IdentityBefore = $identityBefore
                IdentityAfter = $identityAfter
                RuntimePid = if ($null -ne $process) { $process.Id } else { 0 }
                RuntimeExeSha256 = $runtimeExeSha256
                VertexShaderSourceSha256 = $vertexShaderSha256
                FragmentShaderSourceSha256 = $fragmentShaderSha256
                WindowHandle = ('0x{0:x}' -f $window.ToInt64())
                WindowOwnerPid = $windowOwnerPid
                Dpi = $windowDpi
                ForegroundAcquired = $foregroundAcquired
                TopmostTemporary = $true
                OcclusionProbeCount = $occlusionProbeCount
                ClientWidth = if ($null -ne $lastCapture) { $lastCapture.Width } else { 0 }
                ClientHeight = if ($null -ne $lastCapture) { $lastCapture.Height } else { 0 }
                RenderWidth = $renderWidth
                RenderHeight = $renderHeight
                ScaleX = $scaleX
                ScaleY = $scaleY
                Samples = $lastSamples
                SourceSha256 = $sourceSha256
                KdatSha256 = $kdatSha256
                BuildProfileMarkerSha256 = $buildProfileMarkerSha256
                BuildProfile = $buildProfile
                ScreenshotSha256 = if (Test-Path -LiteralPath $screenshotPath) { Get-Hash $screenshotPath } else { $null }
            }
            [IO.File]::WriteAllText($evidencePath, ($failureDocument | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
        } catch { }
    }
    throw
} finally {
    if ($window -ne [IntPtr]::Zero) { [KadathPngRuntimeNative]::RestoreCaptureZOrder($window) }
    if ($null -ne $process -and -not $process.HasExited) {
        if ($window -ne [IntPtr]::Zero) { [void][KadathPngRuntimeNative]::PostMessage($window, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) }
        if ($null -ne $processCapture -and -not $processCapture.WaitForExit(3000)) { $forcedKill = $true; $process.Kill($true); $process.WaitForExit() }
    }
    if ($null -ne $processCapture) { try { $processCapture.FlushLogs($stdoutPath, $stderrPath) } catch { } }
    [KadathPngRuntimeNative]::RestoreDpiAwareness($previousDpi)
    if ($null -eq $identityAfter) {
        $identityAfter = Get-IdentitySnapshot $identityPaths
        Assert-IdentityUnchanged $identityBefore $identityAfter
    }
}
} catch {
    if (-not $runtimeStartAttempted) { [Console]::Error.WriteLine('runtime_start_attempted=false') }
    throw
}
