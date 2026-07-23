using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using Kadath.Editor.Protocol;

namespace Kadath.Editor.Service;

internal sealed class PreviewProcessController : IAsyncDisposable
{
    private readonly string _kadathRoot;
    private readonly object _gate = new();
    private Process? _launcher;
    private int? _runtimeProcessId;
    private bool _stopRequested;

    public PreviewProcessController(string kadathRoot) => _kadathRoot = kadathRoot;

    public event Func<string, JsonElement?, Task>? Notification;

    public async Task<PreviewStartResult> StartAsync(PreviewStartParameters parameters)
    {
        lock (_gate)
        {
            if (_launcher is { HasExited: false }) { throw new InvalidOperationException("Preview is already running."); }
        }

        if (string.IsNullOrWhiteSpace(parameters.ConfigPath)) { throw new InvalidOperationException("Preview config path was not resolved."); }
        if (string.IsNullOrWhiteSpace(parameters.PackageRoot)) { throw new InvalidOperationException("Package root was not resolved."); }
        var configPath = parameters.ConfigPath;
        var packageRoot = parameters.PackageRoot;
        var launcherPath = Path.Combine(_kadathRoot, "tools", "editor-preview.ps1");
        if (!File.Exists(launcherPath)) { throw new FileNotFoundException("Preview launcher does not exist.", launcherPath); }

        var startInfo = new ProcessStartInfo
        {
            FileName = "pwsh",
            WorkingDirectory = _kadathRoot,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        Add(startInfo, "-NoProfile"); Add(startInfo, "-File"); Add(startInfo, launcherPath);
        Add(startInfo, "-ConfigPath"); Add(startInfo, configPath);
        Add(startInfo, "-PackageRoot"); Add(startInfo, packageRoot);
        Add(startInfo, "-StructuredStatus");
        if (parameters.StopAfterMilliseconds > 0) { Add(startInfo, "-StopAfterMilliseconds"); Add(startInfo, parameters.StopAfterMilliseconds.ToString()); }
        if (parameters.ReloadScriptAfterMilliseconds > 0) { Add(startInfo, "-ReloadScriptAfterMilliseconds"); Add(startInfo, parameters.ReloadScriptAfterMilliseconds.ToString()); }
        if (parameters.WatchChanges) { Add(startInfo, "-WatchChanges"); }
        Add(startInfo, "-PollIntervalMilliseconds"); Add(startInfo, parameters.PollIntervalMilliseconds.ToString());
        Add(startInfo, "-DebounceMilliseconds"); Add(startInfo, parameters.DebounceMilliseconds.ToString());
        if (parameters.LiveBake) { Add(startInfo, "-LiveBake"); Add(startInfo, "-BakeProfile"); Add(startInfo, parameters.BakeProfile); }
        if (!string.IsNullOrWhiteSpace(parameters.DerivedDirectory)) { Add(startInfo, "-DerivedDirectory"); Add(startInfo, parameters.DerivedDirectory!); }

        var process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
        if (!process.Start()) { throw new InvalidOperationException("Failed to start editor-preview.ps1."); }
        lock (_gate) { _launcher = process; _runtimeProcessId = null; _stopRequested = false; }
        _ = PumpOutputAsync(process.StandardOutput, false);
        _ = PumpOutputAsync(process.StandardError, true);
        _ = ObserveExitAsync(process);
        await Task.Yield();
        // surface 元数据可先于 runtime_pid 公布；客户端随后从 preview_status 获取实际进程状态。
        var surface = new PreviewSurfaceDescriptor(PreviewSurfaceModes.ExternalWindow, "native-window", null, "KadathRuntimeWindow", null, null, null, null);
        await EmitAsync("preview_surface_created", JsonSerializer.SerializeToElement(surface, EditorProtocol.JsonOptions));
        return new PreviewStartResult("starting", PreviewSurfaceModes.ExternalWindow);
    }

    public async Task<PreviewStopResult> StopAsync()
    {
        Process? process; int? runtimePid;
        lock (_gate) { process = _launcher; runtimePid = _runtimeProcessId; _stopRequested = true; }
        if (process is null || process.HasExited) { return new PreviewStopResult("stopped"); }
        if (runtimePid.HasValue && NativePreviewWindow.TryClose(runtimePid.Value))
        {
            try { using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10)); await process.WaitForExitAsync(timeout.Token); }
            catch (OperationCanceledException) { }
        }
        if (!process.HasExited) { process.Kill(entireProcessTree: true); await process.WaitForExitAsync(); }
        return new PreviewStopResult("stopped");
    }

    private static void Add(ProcessStartInfo info, string value) => info.ArgumentList.Add(value);

    private async Task PumpOutputAsync(StreamReader reader, bool isError)
    {
        while (await reader.ReadLineAsync() is { } line)
        {
            if (isError)
            {
                await EmitAsync("preview_log", JsonSerializer.SerializeToElement(new { stream = "stderr", message = line }, EditorProtocol.JsonOptions));
                continue;
            }
            JsonElement payload;
            try { payload = JsonSerializer.Deserialize<JsonElement>(line, EditorProtocol.JsonOptions); }
            catch (JsonException) { payload = JsonSerializer.SerializeToElement(new { stream = "stdout", message = line }, EditorProtocol.JsonOptions); }
            await EmitAsync("preview_status", payload);
            // 旧 preview_status 保持透传；新事件只暴露经过验证的 reload contract，不泄漏 Launcher 私有结构。
            if (TryNormalizeReloadNotification(payload, out var reloadEvent, out var reloadData))
            {
                await EmitAsync(reloadEvent, reloadData);
            }
            if (line.Contains("runtime_pid", StringComparison.Ordinal))
            {
                // PowerShell 可能把 value 序列化为 JSON number 或 string；两种形态都必须兼容。
                var runtimePid = 0;
                if (payload.TryGetProperty("value", out var statusValue))
                {
                    _ = TryReadRuntimeProcessId(statusValue, out runtimePid);
                }
                if (runtimePid <= 0)
                {
                    lock (_gate) { runtimePid = _launcher?.Id ?? 0; }
                }
                lock (_gate) { _runtimeProcessId = runtimePid; }
            }
        }
    }

    private static bool TryReadRuntimeProcessId(JsonElement value, out int processId)
    {
        if (value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out processId)) { return true; }
        if (value.ValueKind == JsonValueKind.String && int.TryParse(value.GetString(), out processId)) { return true; }
        processId = 0;
        return false;
    }

    private static bool TryNormalizeReloadNotification(JsonElement payload, out string eventName, out JsonElement normalized)
    {
        eventName = string.Empty;
        normalized = default;
        if (payload.ValueKind != JsonValueKind.Object
            || !payload.TryGetProperty("origin", out var origin)
            || !string.Equals(origin.GetString(), "launcher", StringComparison.Ordinal)
            || !payload.TryGetProperty("event", out var launcherEvent))
        {
            return false;
        }

        var expectedState = launcherEvent.GetString() switch
        {
            "runtime_reload_requested" => "requested",
            "runtime_reload_acknowledged" => "acknowledged",
            "runtime_reload_failed" => "failed",
            "runtime_reload_stale" => "stale",
            _ => null
        };
        if (expectedState is null) { return false; }

        PreviewReloadNotification? notification;
        try { notification = JsonSerializer.Deserialize<PreviewReloadNotification>(payload.GetRawText(), EditorProtocol.JsonOptions); }
        catch (JsonException) { return false; }
        if (notification is null
            || notification.ReloadVersion != 1
            || notification.RequestId == 0
            || !string.Equals(notification.State, expectedState, StringComparison.Ordinal)
            || notification.Target is not ("Scene" or "Script")
            || string.IsNullOrWhiteSpace(notification.Source)
            || !IsOptionalRevision(notification.SourceRevision)
            || !IsOptionalRevision(notification.ArtifactRevision)
            || !IsOptionalRevision(notification.LatestRequestedSourceRevision)
            || !IsOptionalRevision(notification.AcknowledgedSourceRevision)
            || !IsOptionalRevision(notification.AcknowledgedArtifactRevision)
            || !IsOptionalRevision(notification.FailedSourceRevision)
            || (notification.ArtifactBytes is <= 0)
            || (expectedState == "stale" && !notification.Ignored))
        {
            return false;
        }

        eventName = $"preview_reload_{expectedState}";
        normalized = JsonSerializer.SerializeToElement(notification, EditorProtocol.JsonOptions);
        return true;
    }

    private static bool IsOptionalRevision(string? revision) =>
        revision is null || (revision.Length == 64 && revision.All(Uri.IsHexDigit));
    private async Task ObserveExitAsync(Process process)
    {
        await process.WaitForExitAsync();
        bool requested; lock (_gate) { requested = _stopRequested; }
        await EmitAsync("preview_stopped", JsonSerializer.SerializeToElement(new { exitCode = process.ExitCode, requested }, EditorProtocol.JsonOptions));
    }

    private async Task EmitAsync(string eventName, JsonElement data)
    {
        var handler = Notification;
        if (handler is not null) { await handler(eventName, data); }
    }

    public async ValueTask DisposeAsync() => await StopAsync();
}

internal static class NativePreviewWindow
{
    private const uint WmClose = 0x0010;
    public static bool TryClose(int processId)
    {
        if (!OperatingSystem.IsWindows()) { return false; }
        var result = false;
        EnumWindows((window, _) =>
        {
            GetWindowThreadProcessId(window, out var owner);
            if (owner != processId) { return true; }
            var name = new System.Text.StringBuilder(256);
            if (GetClassName(window, name, name.Capacity) > 0 && name.ToString() == "KadathRuntimeWindow")
            { result = PostMessage(window, WmClose, IntPtr.Zero, IntPtr.Zero); return false; }
            return true;
        }, IntPtr.Zero);
        return result;
    }
    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
    [DllImport("user32.dll", SetLastError = true)] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder className, int maxCount);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool PostMessage(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam);
}
