using System.ComponentModel;
using System.Runtime.InteropServices;

namespace Kadath.Runtime.Windows.ContractVerifier;

internal sealed record WindowMetrics(int Left, int Top, int Width, int Height);

internal sealed class PixelCapture
{
    public required int Left { get; init; }
    public required int Top { get; init; }
    public required int Width { get; init; }
    public required int Height { get; init; }
    public required byte[] Bgra { get; init; }

    public Rgb Sample(int x, int y)
    {
        if (x < 0 || y < 0 || x >= Width || y >= Height) throw new ArgumentOutOfRangeException(nameof(x));
        var offset = checked((y * Width + x) * 4);
        return new Rgb(Bgra[offset + 2], Bgra[offset + 1], Bgra[offset]);
    }
}

internal sealed class Win32RuntimeWindow : IDisposable
{
    private const uint WmClose = 0x0010;
    private const uint WmKeyDown = 0x0100;
    private const uint WmKeyUp = 0x0101;
    private const int SwRestore = 9;
    private const uint GaRoot = 2;
    private const uint DibRgbColors = 0;
    private const uint SrcCopy = 0x00CC0020;
    private const uint CaptureBlt = 0x40000000;
    private const uint TopmostFlags = 0x0053;
    private static readonly nint HwndTopmost = new(-1);
    private static readonly nint HwndNotTopmost = new(-2);

    private bool _topmost;

    public Win32RuntimeWindow(nint handle, int expectedProcessId)
    {
        Handle = handle;
        OwnerProcessId = GetOwnerProcessId(handle);
        if (OwnerProcessId != (uint)expectedProcessId)
            throw WindowBlocked("Runtime HWND owner PID does not match the launched process.");
        ClassName = ReadClassName(handle);
        if (!ClassName.Equals("KadathRuntimeWindow", StringComparison.Ordinal))
            throw new VerifierFailure(FailureClassification.ProductContract, "window_ready", $"Unexpected Runtime window class: {ClassName}");
    }

    public nint Handle { get; }
    public uint OwnerProcessId { get; }
    public string ClassName { get; }
    public uint Dpi => GetDpiForWindow(Handle);
    public bool IsVisible => IsWindowVisible(Handle) && !IsIconic(Handle);

    public static nint FindLargestVisibleWindow(int processId)
    {
        nint best = 0;
        long bestArea = 0;
        EnumWindows((window, ignoredParameter) =>
        {
            if (!IsWindowVisible(window) || IsIconic(window)) return true;
            _ = GetWindowThreadProcessId(window, out var owner);
            if (owner != (uint)processId || !GetClientRect(window, out var rect)) return true;
            var area = Math.Max(0, rect.Right - rect.Left) * (long)Math.Max(0, rect.Bottom - rect.Top);
            if (area > bestArea)
            {
                best = window;
                bestArea = area;
            }
            _ = ignoredParameter;
            return true;
        }, 0);
        return best;
    }

    public bool PrepareUnobscuredCapture()
    {
        _ = ShowWindow(Handle, SwRestore);
        // 临时置顶只服务于可信 GDI 取证；Dispose 无条件恢复 NOTOPMOST。
        if (!SetWindowPos(Handle, HwndTopmost, 0, 0, 0, 0, TopmostFlags))
            throw WindowBlocked("SetWindowPos(HWND_TOPMOST) failed.", new Win32Exception(Marshal.GetLastWin32Error()));
        _topmost = true;
        return SetForegroundWindow(Handle);
    }

    public WindowMetrics GetMetrics()
    {
        using var dpi = DpiScope.Enter();
        if (!GetClientRect(Handle, out var rect))
            throw WindowBlocked("GetClientRect failed.", new Win32Exception(Marshal.GetLastWin32Error()));
        var origin = new Point();
        if (!ClientToScreen(Handle, ref origin))
            throw WindowBlocked("ClientToScreen failed.", new Win32Exception(Marshal.GetLastWin32Error()));
        return new WindowMetrics(origin.X, origin.Y, rect.Right - rect.Left, rect.Bottom - rect.Top);
    }

    public bool EvidencePointsAreUnobscured(IReadOnlyList<(int X, int Y)> sampleCoordinates)
    {
        using var dpi = DpiScope.Enter();
        if (!GetClientRect(Handle, out var rect)) return false;
        var width = rect.Right - rect.Left;
        var height = rect.Bottom - rect.Top;
        if (width <= 0 || height <= 0) return false;

        var points = new List<Point>();
        var xs = new[] { 1, width / 4, width / 2, width * 3 / 4, width - 2 };
        var ys = new[] { 1, height / 4, height / 2, height * 3 / 4, height - 2 };
        foreach (var y in ys)
            foreach (var x in xs)
                points.Add(new Point { X = x, Y = y });
        foreach (var (x, y) in sampleCoordinates)
        {
            if (x < 0 || x >= width || y < 0 || y >= height) return false;
            points.Add(new Point { X = x, Y = y });
        }

        foreach (var clientPoint in points)
        {
            var screenPoint = clientPoint;
            if (!ClientToScreen(Handle, ref screenPoint)) return false;
            var hit = WindowFromPoint(screenPoint);
            if (hit == 0 || GetAncestor(hit, GaRoot) != Handle) return false;
        }
        return true;
    }

    public PixelCapture CaptureClient()
    {
        using var dpi = DpiScope.Enter();
        var metrics = GetMetrics();
        if (metrics.Width <= 0 || metrics.Height <= 0) throw WindowBlocked("Runtime client area is empty.");

        var screen = GetDC(0);
        nint memory = 0;
        nint bitmap = 0;
        nint previous = 0;
        if (screen == 0) throw WindowBlocked("GetDC failed.", new Win32Exception(Marshal.GetLastWin32Error()));
        try
        {
            memory = CreateCompatibleDC(screen);
            if (memory == 0) throw WindowBlocked("CreateCompatibleDC failed.", new Win32Exception(Marshal.GetLastWin32Error()));
            var info = new BitmapInfo
            {
                Header = new BitmapInfoHeader
                {
                    Size = (uint)Marshal.SizeOf<BitmapInfoHeader>(),
                    Width = metrics.Width,
                    Height = -metrics.Height,
                    Planes = 1,
                    BitCount = 32,
                    Compression = 0,
                    SizeImage = checked((uint)(metrics.Width * metrics.Height * 4))
                },
                Colors = new uint[4]
            };
            bitmap = CreateDIBSection(screen, ref info, DibRgbColors, out var bits, 0, 0);
            if (bitmap == 0 || bits == 0) throw WindowBlocked("CreateDIBSection failed.", new Win32Exception(Marshal.GetLastWin32Error()));
            previous = SelectObject(memory, bitmap);
            if (previous == 0) throw WindowBlocked("SelectObject failed.", new Win32Exception(Marshal.GetLastWin32Error()));
            if (!BitBlt(memory, 0, 0, metrics.Width, metrics.Height, screen, metrics.Left, metrics.Top, SrcCopy | CaptureBlt))
                throw WindowBlocked("BitBlt failed.", new Win32Exception(Marshal.GetLastWin32Error()));
            var bgra = new byte[checked(metrics.Width * metrics.Height * 4)];
            Marshal.Copy(bits, bgra, 0, bgra.Length);
            return new PixelCapture
            {
                Left = metrics.Left,
                Top = metrics.Top,
                Width = metrics.Width,
                Height = metrics.Height,
                Bgra = bgra
            };
        }
        finally
        {
            if (previous != 0 && memory != 0) _ = SelectObject(memory, previous);
            if (bitmap != 0) _ = DeleteObject(bitmap);
            if (memory != 0) _ = DeleteDC(memory);
            _ = ReleaseDC(0, screen);
        }
    }

    public void PostKeyDown(int virtualKey) => PostKey(WmKeyDown, virtualKey, "WM_KEYDOWN");

    public void PostKeyUp(int virtualKey) => PostKey(WmKeyUp, virtualKey, "WM_KEYUP");

    public void PostCloseOrThrow()
    {
        if (!PostClose(Handle))
            throw new VerifierFailure(FailureClassification.ProductContract, "runtime_close", "WM_CLOSE failed for Runtime window.");
    }

    public static bool PostClose(nint handle) => handle != 0 && PostMessage(handle, WmClose, 0, 0);

    public void Dispose()
    {
        if (_topmost && Handle != 0)
        {
            _ = SetWindowPos(Handle, HwndNotTopmost, 0, 0, 0, 0, TopmostFlags);
            _topmost = false;
        }
    }

    private void PostKey(uint message, int virtualKey, string name)
    {
        if (!PostMessage(Handle, message, virtualKey, 0))
            throw WindowBlocked($"{name} failed for virtual key 0x{virtualKey:x2}.", new Win32Exception(Marshal.GetLastWin32Error()));
    }

    private static uint GetOwnerProcessId(nint handle)
    {
        _ = GetWindowThreadProcessId(handle, out var processId);
        return processId;
    }

    private static string ReadClassName(nint handle)
    {
        Span<char> buffer = stackalloc char[256];
        var length = GetClassName(handle, ref MemoryMarshal.GetReference(buffer), buffer.Length);
        if (length <= 0) throw WindowBlocked("GetClassNameW failed.", new Win32Exception(Marshal.GetLastWin32Error()));
        return new string(buffer[..length]);
    }

    private static VerifierFailure WindowBlocked(string message, Exception? inner = null) =>
        new(FailureClassification.WindowEnvironment, "window_capture", message, inner);

    private readonly struct DpiScope : IDisposable
    {
        private readonly nint _previous;

        private DpiScope(nint previous) => _previous = previous;

        public static DpiScope Enter()
        {
            var previous = SetThreadDpiAwarenessContext(new nint(-4));
            if (previous == 0)
                throw WindowBlocked("SetThreadDpiAwarenessContext(PER_MONITOR_AWARE_V2) failed.", new Win32Exception(Marshal.GetLastWin32Error()));
            return new DpiScope(previous);
        }

        public void Dispose()
        {
            if (_previous != 0) _ = SetThreadDpiAwarenessContext(_previous);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Rect { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    private struct Point { public int X, Y; }

    [StructLayout(LayoutKind.Sequential)]
    private struct BitmapInfoHeader
    {
        public uint Size;
        public int Width;
        public int Height;
        public ushort Planes;
        public ushort BitCount;
        public uint Compression;
        public uint SizeImage;
        public int XPelsPerMeter;
        public int YPelsPerMeter;
        public uint ClrUsed;
        public uint ClrImportant;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BitmapInfo
    {
        public BitmapInfoHeader Header;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 4)] public uint[] Colors;
    }

    private delegate bool EnumWindowsProc(nint window, nint parameter);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EnumWindows(EnumWindowsProc callback, nint parameter);
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetClientRect(nint window, out Rect rect);
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ClientToScreen(nint window, ref Point point);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint GetWindowThreadProcessId(nint window, out uint processId);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsWindowVisible(nint window);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsIconic(nint window);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ShowWindow(nint window, int command);
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(nint window);
    [DllImport("user32.dll")]
    private static extern nint WindowFromPoint(Point point);
    [DllImport("user32.dll")]
    private static extern nint GetAncestor(nint window, uint flags);
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowPos(nint window, nint insertAfter, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool PostMessage(nint window, uint message, nint wParam, nint lParam);
    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(nint window);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern nint SetThreadDpiAwarenessContext(nint context);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int GetClassName(nint window, ref char className, int maximumCount);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern nint GetDC(nint window);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern int ReleaseDC(nint window, nint deviceContext);
    [DllImport("gdi32.dll", SetLastError = true)]
    private static extern nint CreateCompatibleDC(nint deviceContext);
    [DllImport("gdi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DeleteDC(nint deviceContext);
    [DllImport("gdi32.dll", SetLastError = true)]
    private static extern nint SelectObject(nint deviceContext, nint value);
    [DllImport("gdi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DeleteObject(nint value);
    [DllImport("gdi32.dll", SetLastError = true)]
    private static extern nint CreateDIBSection(nint deviceContext, ref BitmapInfo info, uint usage, out nint bits, nint section, uint offset);
    [DllImport("gdi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool BitBlt(nint destination, int x, int y, int width, int height, nint source, int sourceX, int sourceY, uint operation);
}
