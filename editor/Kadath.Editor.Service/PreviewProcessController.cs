using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using Kadath.Editor.Protocol;

namespace Kadath.Editor.Service;

internal sealed class PreviewProcessController : IAsyncDisposable
{
    private readonly string _kadathRoot;
    private readonly object _gate = new();
    private readonly SemaphoreSlim _lifecycleBoundary = new(1, 1);
    private Process? _launcher;
    private Task _stdoutPump = Task.CompletedTask;
    private Task _stderrPump = Task.CompletedTask;
    private Task _exitObserver = Task.CompletedTask;
    private int? _runtimeProcessId;
    private bool _stopRequested;

    public PreviewProcessController(string kadathRoot) => _kadathRoot = kadathRoot;

    public event Func<string, JsonElement?, Task>? Notification;

    public async Task<PreviewStartResult> StartAsync(PreviewStartParameters parameters)
    {
        await _lifecycleBoundary.WaitAsync().ConfigureAwait(false);
        try
        {
            await RetireExitedLauncherAsync().ConfigureAwait(false);
            return await StartCoreAsync(parameters).ConfigureAwait(false);
        }
        finally { _lifecycleBoundary.Release(); }
    }

    private async Task<PreviewStartResult> StartCoreAsync(PreviewStartParameters parameters)
    {
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
            RedirectStandardError = true,
            RedirectStandardInput = true
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
        var stdoutPump = PumpOutputAsync(process, process.StandardOutput, false);
        var stderrPump = PumpOutputAsync(process, process.StandardError, true);
        var exitObserver = ObserveExitAsync(process, stdoutPump, stderrPump);
        lock (_gate) { _stdoutPump = stdoutPump; _stderrPump = stderrPump; _exitObserver = exitObserver; }
        await Task.Yield();
        // surface 元数据可先于 runtime_pid 公布；客户端随后从 preview_status 获取实际进程状态。
        var surface = new PreviewSurfaceDescriptor(PreviewSurfaceModes.ExternalWindow, "native-window", null, "KadathRuntimeWindow", null, null, null, null);
        await EmitAsync("preview_surface_created", JsonSerializer.SerializeToElement(surface, EditorProtocol.JsonOptions));
        return new PreviewStartResult("starting", PreviewSurfaceModes.ExternalWindow);
    }

    public async Task<PreviewStopResult> StopAsync()
    {
        await _lifecycleBoundary.WaitAsync().ConfigureAwait(false);
        try { return await StopCoreAsync().ConfigureAwait(false); }
        finally { _lifecycleBoundary.Release(); }
    }

    private async Task<PreviewStopResult> StopCoreAsync()
    {
        Process? process; int? runtimePid;
        lock (_gate) { process = _launcher; runtimePid = _runtimeProcessId; _stopRequested = true; }
        if (process is not null && !process.HasExited)
        {
            try
            {
                await process.StandardInput.WriteLineAsync("{\"schemaVersion\":1,\"command\":\"shutdown\"}").ConfigureAwait(false);
                await process.StandardInput.FlushAsync().ConfigureAwait(false);
                process.StandardInput.Close();
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
                await process.WaitForExitAsync(timeout.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) { }
            catch (IOException) { }
            catch (InvalidOperationException) { }
        }
        if (process is not null && !process.HasExited && runtimePid.HasValue && NativePreviewWindow.TryClose(runtimePid.Value))
        {
            try { using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(2)); await process.WaitForExitAsync(timeout.Token).ConfigureAwait(false); }
            catch (OperationCanceledException) { }
        }
        if (process is not null && !process.HasExited) { process.Kill(entireProcessTree: true); await process.WaitForExitAsync(); }
        if (process is not null) { await CompleteLifecycleAsync(process).ConfigureAwait(false); }
        return new PreviewStopResult("stopped");
    }

    private async Task RetireExitedLauncherAsync()
    {
        Process? process;
        lock (_gate) { process = _launcher; }
        if (process is null) { return; }
        if (!process.HasExited) { throw new InvalidOperationException("Preview is already running."); }
        await CompleteLifecycleAsync(process).ConfigureAwait(false);
    }

    private async Task CompleteLifecycleAsync(Process process)
    {
        Task stdoutPump; Task stderrPump; Task exitObserver;
        lock (_gate) { stdoutPump = _stdoutPump; stderrPump = _stderrPump; exitObserver = _exitObserver; }
        // 生命周期屏障：Stop/下一次 Start 返回前，旧进程的所有输出与 exit 终态必须已经串行排空。
        await Task.WhenAll(stdoutPump, stderrPump, exitObserver).ConfigureAwait(false);
        lock (_gate)
        {
            if (!ReferenceEquals(_launcher, process)) { return; }
            _launcher = null;
            _runtimeProcessId = null;
            _stdoutPump = Task.CompletedTask;
            _stderrPump = Task.CompletedTask;
            _exitObserver = Task.CompletedTask;
        }
        process.Dispose();
    }

    private static void Add(ProcessStartInfo info, string value) => info.ArgumentList.Add(value);

    private async Task PumpOutputAsync(Process owner, StreamReader reader, bool isError)
    {
        while (await reader.ReadLineAsync() is { } line)
        {
            // Preview 重启后旧 Launcher 的迟到输出必须在 Service seam 被丢弃，不能污染新生命周期。
            if (!IsCurrentLauncher(owner)) { return; }
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
            if (TryNormalizeInitialLoadNotification(payload, out var initialEvent, out var initialData))
            {
                await EmitAsync(initialEvent, initialData);
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

    private bool IsCurrentLauncher(Process process)
    {
        lock (_gate) { return ReferenceEquals(_launcher, process); }
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

    private static bool TryNormalizeInitialLoadNotification(JsonElement payload, out string eventName, out JsonElement normalized)
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

        switch (launcherEvent.GetString())
        {
            case "runtime_initial_loaded":
            {
                PreviewInitialLoadedNotification? notification;
                try { notification = JsonSerializer.Deserialize<PreviewInitialLoadedNotification>(payload.GetRawText(), EditorProtocol.JsonOptions); }
                catch (JsonException) { return false; }
                if (notification is null
                    || notification.LoadVersion != 1
                    || !string.Equals(notification.State, "loaded", StringComparison.Ordinal)
                    || !ValidateInitialTarget(notification.Scene, "Scene")
                    || !ValidateInitialTarget(notification.Script, "Script")
                    || (notification.Profile is not null && notification.Profile is not ("debug" or "release")))
                {
                    return false;
                }
                eventName = "preview_initial_loaded";
                normalized = JsonSerializer.SerializeToElement(notification, EditorProtocol.JsonOptions);
                return true;
            }
            case "runtime_initial_load_failed":
            {
                PreviewInitialLoadFailedNotification? notification;
                try { notification = JsonSerializer.Deserialize<PreviewInitialLoadFailedNotification>(payload.GetRawText(), EditorProtocol.JsonOptions); }
                catch (JsonException) { return false; }
                if (notification is null
                    || notification.LoadVersion != 1
                    || !string.Equals(notification.State, "failed", StringComparison.Ordinal)
                    || string.IsNullOrWhiteSpace(notification.ErrorCode))
                {
                    return false;
                }
                eventName = "preview_initial_load_failed";
                normalized = JsonSerializer.SerializeToElement(notification, EditorProtocol.JsonOptions);
                return true;
            }
            default:
                return false;
        }
    }

    private static bool ValidateInitialTarget(PreviewLoadedTargetIdentity target, string expectedTarget)
    {
        if (target is null || !string.Equals(target.Target, expectedTarget, StringComparison.Ordinal)) { return false; }
        return target.Kind switch
        {
            "built_in" => target.Correlation == "built_in"
                && target.SourceRevision is null && target.ArtifactRevision is null && target.ArtifactBytes is null,
            "source_document" => target.Correlation == "runtime_source"
                && IsLowerHex64(target.SourceRevision)
                && target.ArtifactRevision is null && target.ArtifactBytes is null,
            "artifact" => ValidateArtifactTarget(target),
            _ => false
        };
    }

    private static bool ValidateArtifactTarget(PreviewLoadedTargetIdentity target)
    {
        if (!IsLowerHex64(target.ArtifactRevision) || target.ArtifactBytes is not > 0) { return false; }
        return target.Correlation switch
        {
            "manifest_matched" => IsLowerHex64(target.SourceRevision),
            "runtime_only" or "artifact_mismatch" or "manifest_missing" => target.SourceRevision is null,
            _ => false
        };
    }

    private static bool IsLowerHex64(string? revision) =>
        revision is { Length: 64 } && revision.All(value => value is >= '0' and <= '9' or >= 'a' and <= 'f');

    private async Task ObserveExitAsync(Process process, Task stdoutPump, Task stderrPump)
    {
        await process.WaitForExitAsync();
        // preview_stopped 必须排在 Launcher stdout/stderr 的最后一个终态之后。
        await Task.WhenAll(stdoutPump, stderrPump).ConfigureAwait(false);
        if (!IsCurrentLauncher(process)) { return; }
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
