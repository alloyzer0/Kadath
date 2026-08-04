using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using Kadath.Editor.Protocol;
using Kadath.Editor.Workspace;

namespace Kadath.Editor.Service;

internal sealed class PreviewProcessController : IAsyncDisposable
{
    private readonly WorkspacePreviewModel _workspacePreviewModel;
    private readonly PreviewProcessTimeouts _timeouts;
    private readonly object _gate = new();
    private readonly SemaphoreSlim _lifecycleBoundary = new(1, 1);
    private readonly SemaphoreSlim _eventBoundary = new(1, 1);
    private Process? _runtime;
    private CancellationTokenSource? _backgroundCancellation;
    private Task _stdoutPump = Task.CompletedTask;
    private Task _stderrPump = Task.CompletedTask;
    private Task _backgroundTask = Task.CompletedTask;
    private Task _exitObserver = Task.CompletedTask;
    private WorkspacePreviewPlan? _plan;
    private Dictionary<ulong, PendingRequest> _pendingRequests = [];
    private Dictionary<string, ReloadTargetState> _reloadTargets = CreateReloadTargets();
    private List<WatchTarget> _watchTargets = [];
    private ulong _nextRequestId = 1;
    private ulong _launcherSequence;
    private long _generation;
    private bool _stopRequested;
    private bool _standardInputClosed;
    private bool _initialTerminalEmitted;
    private bool _stoppedEmitted;

    public PreviewProcessController(WorkspacePreviewModel workspacePreviewModel)
        : this(workspacePreviewModel, PreviewProcessTimeouts.Default) { }

    internal PreviewProcessController(WorkspacePreviewModel workspacePreviewModel, PreviewProcessTimeouts timeouts)
    {
        _workspacePreviewModel = workspacePreviewModel;
        _timeouts = timeouts;
    }

    public event Func<string, JsonElement?, Task>? Notification;

    public async Task<PreviewStartResult> StartAsync(
        PreviewStartParameters parameters,
        CancellationToken cancellationToken = default)
    {
        await _lifecycleBoundary.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await RetireExitedRuntimeAsync().ConfigureAwait(false);
            return await StartCoreAsync(parameters, cancellationToken).ConfigureAwait(false);
        }
        finally { _lifecycleBoundary.Release(); }
    }

    private async Task<PreviewStartResult> StartCoreAsync(
        PreviewStartParameters parameters,
        CancellationToken cancellationToken)
    {
        var plan = await _workspacePreviewModel.PrepareAsync(parameters, cancellationToken).ConfigureAwait(false);
        var watchTargets = parameters.WatchChanges ? CreateWatchTargets(plan, parameters.LiveBake) : [];
        var startInfo = new ProcessStartInfo
        {
            FileName = plan.ExecutablePath,
            WorkingDirectory = plan.WorkingDirectory,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = true
        };
        foreach (var argument in plan.RuntimeArguments) startInfo.ArgumentList.Add(argument);

        var process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
        if (!process.Start())
        {
            process.Dispose();
            throw new InvalidOperationException("Failed to start Runtime process.");
        }

        var backgroundCancellation = new CancellationTokenSource();
        long generation;
        lock (_gate)
        {
            generation = ++_generation;
            _runtime = process;
            _backgroundCancellation = backgroundCancellation;
            _plan = plan;
            _pendingRequests = [];
            _reloadTargets = CreateReloadTargets();
            _watchTargets = watchTargets;
            _nextRequestId = 1;
            _launcherSequence = 0;
            _stopRequested = false;
            _standardInputClosed = false;
            _initialTerminalEmitted = false;
            _stoppedEmitted = false;
        }

        try
        {
            await EmitStartupStatusAsync(process, generation, plan, parameters).ConfigureAwait(false);
            var stdoutPump = PumpStdoutAsync(process, generation);
            var stderrPump = PumpStderrAsync(process, generation);
            var backgroundTask = MaintainRuntimeAsync(process, generation, plan, parameters, backgroundCancellation.Token);
            var exitObserver = ObserveExitAsync(process, generation, stdoutPump, stderrPump, backgroundTask, backgroundCancellation);
            lock (_gate)
            {
                if (IsCurrentRuntimeLocked(process, generation))
                {
                    _stdoutPump = stdoutPump;
                    _stderrPump = stderrPump;
                    _backgroundTask = backgroundTask;
                    _exitObserver = exitObserver;
                }
            }
            var surface = new PreviewSurfaceDescriptor(
                PreviewSurfaceModes.ExternalWindow,
                "native-window",
                null,
                "KadathRuntimeWindow",
                null,
                null,
                null,
                null);
            await EmitOwnedAsync(process, generation, "preview_surface_created", JsonSerializer.SerializeToElement(surface, EditorProtocol.JsonOptions)).ConfigureAwait(false);
            return new PreviewStartResult("starting", PreviewSurfaceModes.ExternalWindow);
        }
        catch
        {
            backgroundCancellation.Cancel();
            await StopOwnedRuntimeAsync(process, generation).ConfigureAwait(false);
            await CompleteLifecycleAsync(process, generation).ConfigureAwait(false);
            throw;
        }
    }

    public async Task<PreviewStopResult> StopAsync(CancellationToken cancellationToken = default)
    {
        await _lifecycleBoundary.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            Process? process;
            CancellationTokenSource? backgroundCancellation;
            long generation;
            lock (_gate)
            {
                process = _runtime;
                generation = _generation;
                backgroundCancellation = _backgroundCancellation;
                _stopRequested = true;
            }
            backgroundCancellation?.Cancel();
            if (process is not null)
            {
                await StopOwnedRuntimeAsync(process, generation).ConfigureAwait(false);
                await CompleteLifecycleAsync(process, generation).ConfigureAwait(false);
            }
            return new PreviewStopResult("stopped");
        }
        finally { _lifecycleBoundary.Release(); }
    }

    private async Task EmitStartupStatusAsync(
        Process process,
        long generation,
        WorkspacePreviewPlan plan,
        PreviewStartParameters parameters)
    {
        await EmitLauncherStatusAsync(process, generation, "preview_contract", "1").ConfigureAwait(false);
        await EmitLauncherStatusAsync(process, generation, "runtime_executable", plan.ExecutablePath).ConfigureAwait(false);
        await EmitLauncherStatusAsync(process, generation, "runtime_working_directory", plan.WorkingDirectory).ConfigureAwait(false);
        if (parameters.LiveBake)
        {
            await EmitLiveBakeEventAsync(process, generation, "live_bake_started", "Both", plan, null, null).ConfigureAwait(false);
            await EmitLiveBakeEventAsync(process, generation, "live_bake_completed", "Both", plan, plan.InitialBake, null).ConfigureAwait(false);
            await EmitLauncherStatusAsync(process, generation, "live_bake", "1").ConfigureAwait(false);
            await EmitLauncherStatusAsync(process, generation, "live_bake_profile", plan.BakeProfile!).ConfigureAwait(false);
            await EmitLauncherStatusAsync(process, generation, "live_bake_derived_directory", plan.DerivedDirectory!).ConfigureAwait(false);
        }
        await EmitLauncherStatusAsync(process, generation, "runtime_pid", process.Id.ToString()).ConfigureAwait(false);
        if (parameters.WatchChanges)
        {
            await EmitLauncherStatusAsync(process, generation, "watch_changes", "1").ConfigureAwait(false);
            await EmitLauncherStatusAsync(process, generation, "watch_poll_interval_ms", parameters.PollIntervalMilliseconds.ToString()).ConfigureAwait(false);
            await EmitLauncherStatusAsync(process, generation, "watch_debounce_ms", parameters.DebounceMilliseconds.ToString()).ConfigureAwait(false);
        }
    }

    private async Task PumpStdoutAsync(Process process, long generation)
    {
        while (await process.StandardOutput.ReadLineAsync().ConfigureAwait(false) is { } line)
        {
            if (!IsCurrentRuntime(process, generation)) return;
            await _eventBoundary.WaitAsync().ConfigureAwait(false);
            try
            {
                if (!IsCurrentRuntime(process, generation)) return;
                JsonElement runtimeEvent;
                try { runtimeEvent = JsonSerializer.Deserialize<JsonElement>(line, EditorProtocol.JsonOptions); }
                catch (JsonException)
                {
                    await EmitLauncherEventCoreAsync(process, generation, new Dictionary<string, object?>
                    {
                        ["event"] = "protocol_error",
                        ["message"] = "Runtime emitted invalid JSONL"
                    }).ConfigureAwait(false);
                    continue;
                }
                await EmitOwnedAsync(process, generation, "preview_status", runtimeEvent).ConfigureAwait(false);
                await HandleRuntimeEventCoreAsync(process, generation, runtimeEvent).ConfigureAwait(false);
            }
            finally { _eventBoundary.Release(); }
        }
    }

    private async Task PumpStderrAsync(Process process, long generation)
    {
        while (await process.StandardError.ReadLineAsync().ConfigureAwait(false) is { } line)
        {
            if (!IsCurrentRuntime(process, generation)) return;
            await _eventBoundary.WaitAsync().ConfigureAwait(false);
            try
            {
                await EmitLauncherEventCoreAsync(process, generation, new Dictionary<string, object?>
                {
                    ["event"] = "runtime_log",
                    ["stream"] = "stderr",
                    ["message"] = line
                }).ConfigureAwait(false);
            }
            finally { _eventBoundary.Release(); }
        }
    }

    private async Task HandleRuntimeEventCoreAsync(Process process, long generation, JsonElement runtimeEvent)
    {
        if (runtimeEvent.ValueKind != JsonValueKind.Object
            || !runtimeEvent.TryGetProperty("event", out var eventProperty)
            || eventProperty.ValueKind != JsonValueKind.String)
        {
            return;
        }
        switch (eventProperty.GetString())
        {
            case "runtime_ready":
                await PublishInitialLoadedCoreAsync(process, generation, runtimeEvent).ConfigureAwait(false);
                break;
            case "runtime_failed":
                if (runtimeEvent.TryGetProperty("phase", out var phase)
                    && string.Equals(phase.GetString(), "startup", StringComparison.Ordinal))
                {
                    var errorCode = runtimeEvent.TryGetProperty("errorCode", out var code) ? code.GetString() : null;
                    await PublishInitialFailedCoreAsync(
                        process,
                        generation,
                        string.IsNullOrWhiteSpace(errorCode) ? "runtime_startup_failed" : errorCode!,
                        "Runtime startup failed before initial content became ready.").ConfigureAwait(false);
                }
                break;
            case "command_completed":
                await CompleteCommandCoreAsync(process, generation, runtimeEvent).ConfigureAwait(false);
                break;
        }
    }

    private async Task PublishInitialLoadedCoreAsync(Process process, long generation, JsonElement runtimeEvent)
    {
        if (_initialTerminalEmitted
            || !runtimeEvent.TryGetProperty("initialLoaded", out var loaded)
            || loaded.ValueKind != JsonValueKind.Object)
        {
            return;
        }
        try
        {
            var plan = RequireCurrentPlan(process, generation);
            var scene = ConvertInitialTarget("Scene", loaded.GetProperty("scene"), plan);
            var script = ConvertInitialTarget("Script", loaded.GetProperty("script"), plan);
            var notification = new PreviewInitialLoadedNotification(1, "loaded", scene, script, plan.BakeProfile);
            _initialTerminalEmitted = true;
            await EmitCompatibilityAndStableCoreAsync(
                process,
                generation,
                "runtime_initial_loaded",
                "preview_initial_loaded",
                notification).ConfigureAwait(false);
        }
        catch (Exception exception) when (exception is JsonException or InvalidDataException or InvalidOperationException)
        {
            await PublishInitialFailedCoreAsync(
                process,
                generation,
                "runtime_initial_identity_invalid",
                exception.Message).ConfigureAwait(false);
        }
    }

    private async Task PublishInitialFailedCoreAsync(
        Process process,
        long generation,
        string errorCode,
        string? message)
    {
        if (_initialTerminalEmitted) return;
        _initialTerminalEmitted = true;
        var notification = new PreviewInitialLoadFailedNotification(1, "failed", errorCode, message);
        await EmitCompatibilityAndStableCoreAsync(
            process,
            generation,
            "runtime_initial_load_failed",
            "preview_initial_load_failed",
            notification).ConfigureAwait(false);
    }

    private PreviewLoadedTargetIdentity ConvertInitialTarget(
        string targetName,
        JsonElement runtimeTarget,
        WorkspacePreviewPlan plan)
    {
        if (runtimeTarget.ValueKind != JsonValueKind.Object) throw new InvalidDataException($"Runtime initialLoaded is missing {targetName}.");
        var kind = runtimeTarget.GetProperty("kind").GetString()
            ?? throw new InvalidDataException($"Runtime initialLoaded.{targetName} kind is missing.");
        if (kind == "built_in") return new PreviewLoadedTargetIdentity(targetName, kind, "built_in");
        if (kind is not ("source_document" or "artifact"))
            throw new InvalidDataException($"Runtime initialLoaded.{targetName} has unsupported kind: {kind}.");
        var revision = runtimeTarget.GetProperty("sha256").GetString();
        if (!IsLowerHex64(revision)) throw new InvalidDataException($"Runtime initialLoaded.{targetName} sha256 must be lowercase 64-hex.");
        if (!runtimeTarget.GetProperty("bytes").TryGetUInt64(out var bytes) || bytes == 0)
            throw new InvalidDataException($"Runtime initialLoaded.{targetName} bytes must be positive uint64.");
        if (kind == "source_document")
            return new PreviewLoadedTargetIdentity(targetName, kind, "runtime_source", revision);
        if (plan.ManifestPath is null)
            return new PreviewLoadedTargetIdentity(targetName, kind, "runtime_only", null, revision, bytes);
        var correlation = CorrelateManifestTarget(plan.ManifestPath, targetName, revision!, bytes);
        return new PreviewLoadedTargetIdentity(targetName, kind, correlation.Correlation, correlation.SourceRevision, revision, bytes);
    }

    private static ManifestCorrelation CorrelateManifestTarget(
        string manifestPath,
        string targetName,
        string artifactRevision,
        ulong artifactBytes)
    {
        if (!File.Exists(manifestPath)) return new ManifestCorrelation("manifest_missing", null);
        try
        {
            using var document = JsonDocument.Parse(File.ReadAllBytes(manifestPath));
            var root = document.RootElement;
            if (root.GetProperty("schemaVersion").GetInt32() != 1) return new ManifestCorrelation("artifact_mismatch", null);
            var entry = root.GetProperty(targetName.ToLowerInvariant());
            var manifestRevision = entry.GetProperty("artifactSha256").GetString();
            if (!entry.GetProperty("artifactBytes").TryGetUInt64(out var manifestBytes)
                || !string.Equals(manifestRevision, artifactRevision, StringComparison.Ordinal)
                || manifestBytes != artifactBytes)
            {
                return new ManifestCorrelation("artifact_mismatch", null);
            }
            var sourceRevision = entry.GetProperty("sourceSha256").GetString();
            return IsLowerHex64(sourceRevision)
                ? new ManifestCorrelation("manifest_matched", sourceRevision)
                : new ManifestCorrelation("artifact_mismatch", null);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException or KeyNotFoundException or InvalidOperationException)
        {
            return new ManifestCorrelation("artifact_mismatch", null);
        }
    }

    private async Task CompleteCommandCoreAsync(Process process, long generation, JsonElement runtimeEvent)
    {
        if (!runtimeEvent.TryGetProperty("requestId", out var requestProperty)
            || !requestProperty.TryGetUInt64(out var requestId))
        {
            return;
        }
        _pendingRequests.Remove(requestId, out var pending);
        var command = runtimeEvent.TryGetProperty("command", out var commandProperty) ? commandProperty.GetString() ?? string.Empty : string.Empty;
        var result = runtimeEvent.TryGetProperty("result", out var resultProperty) ? resultProperty.GetString() ?? string.Empty : string.Empty;
        var errorCode = runtimeEvent.TryGetProperty("errorCode", out var errorProperty) ? errorProperty.GetString() : null;
        var response = new Dictionary<string, object?>
        {
            ["event"] = "command_response",
            ["requestId"] = requestId,
            ["command"] = command,
            ["result"] = result
        };
        AddPendingIdentity(response, pending);
        if (!string.IsNullOrWhiteSpace(errorCode)) response["errorCode"] = errorCode;
        await EmitLauncherEventCoreAsync(process, generation, response).ConfigureAwait(false);
        if (pending?.Target is not null)
            await CompleteReloadCoreAsync(process, generation, pending, requestId, result, errorCode).ConfigureAwait(false);
    }

    private async Task CompleteReloadCoreAsync(
        Process process,
        long generation,
        PendingRequest pending,
        ulong requestId,
        string result,
        string? errorCode)
    {
        var targetState = _reloadTargets[pending.Target!];
        PreviewReloadNotification notification;
        string compatibilityEvent;
        string stableEvent;
        if (targetState.LatestRequestId != requestId)
        {
            notification = BuildReloadNotification("stale", pending, requestId, targetState, result, errorCode, true);
            compatibilityEvent = "runtime_reload_stale";
            stableEvent = "preview_reload_stale";
        }
        else if (result == "succeeded")
        {
            if (pending.Revision is not null) targetState.AcknowledgedSourceRevision = pending.Revision;
            if (pending.ArtifactRevision is not null) targetState.AcknowledgedArtifactRevision = pending.ArtifactRevision;
            targetState.FailedSourceRevision = null;
            notification = BuildReloadNotification("acknowledged", pending, requestId, targetState, result, null, false);
            compatibilityEvent = "runtime_reload_acknowledged";
            stableEvent = "preview_reload_acknowledged";
        }
        else
        {
            targetState.FailedSourceRevision = pending.Revision;
            notification = BuildReloadNotification("failed", pending, requestId, targetState, result, errorCode, false);
            compatibilityEvent = "runtime_reload_failed";
            stableEvent = "preview_reload_failed";
        }
        await EmitCompatibilityAndStableCoreAsync(process, generation, compatibilityEvent, stableEvent, notification).ConfigureAwait(false);
    }

    private async Task MaintainRuntimeAsync(
        Process process,
        long generation,
        WorkspacePreviewPlan plan,
        PreviewStartParameters parameters,
        CancellationToken cancellationToken)
    {
        var startedAt = Stopwatch.StartNew();
        var scriptReloadSent = false;
        try
        {
            while (!process.HasExited)
            {
                await Task.Delay(parameters.PollIntervalMilliseconds, cancellationToken).ConfigureAwait(false);
                if (!IsCurrentRuntime(process, generation) || process.HasExited) return;
                await ExpirePendingRequestsAsync(process, generation).ConfigureAwait(false);
                if (parameters.ReloadScriptAfterMilliseconds > 0
                    && !scriptReloadSent
                    && startedAt.ElapsedMilliseconds >= parameters.ReloadScriptAfterMilliseconds)
                {
                    await RequestReloadAsync(process, generation, "Script", "timer", null, null, null).ConfigureAwait(false);
                    scriptReloadSent = true;
                    await EmitLauncherStatusAsync(process, generation, "script_reload_requested", "1").ConfigureAwait(false);
                }
                if (parameters.WatchChanges)
                    await UpdateWatchTargetsAsync(process, generation, plan, parameters).ConfigureAwait(false);
                if (parameters.StopAfterMilliseconds > 0
                    && startedAt.ElapsedMilliseconds >= parameters.StopAfterMilliseconds)
                {
                    lock (_gate)
                    {
                        if (IsCurrentRuntimeLocked(process, generation)) _stopRequested = true;
                    }
                    await StopOwnedRuntimeAsync(process, generation).ConfigureAwait(false);
                    return;
                }
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { }
        catch (Exception exception)
        {
            await EmitOwnedAsync(process, generation, "preview_log", JsonSerializer.SerializeToElement(new
            {
                stream = "service",
                message = exception.Message
            }, EditorProtocol.JsonOptions)).ConfigureAwait(false);
        }
    }

    private async Task UpdateWatchTargetsAsync(
        Process process,
        long generation,
        WorkspacePreviewPlan plan,
        PreviewStartParameters parameters)
    {
        var now = DateTimeOffset.UtcNow;
        foreach (var target in _watchTargets)
        {
            var revision = TryGetFileRevision(target.Path);
            if (!string.Equals(revision, target.ObservedRevision, StringComparison.Ordinal))
            {
                target.ObservedRevision = revision;
                target.PendingRevision = revision;
                target.PendingSince = now;
                await EmitLauncherStatusAsync(process, generation, $"{target.Name.ToLowerInvariant()}_change_detected", "1").ConfigureAwait(false);
            }
            if (target.PendingRevision is null
                || !string.Equals(revision, target.PendingRevision, StringComparison.Ordinal)
                || now - target.PendingSince < TimeSpan.FromMilliseconds(parameters.DebounceMilliseconds)
                || !IsHex64(revision))
            {
                continue;
            }
            if (parameters.LiveBake)
                await PublishAndReloadWatchTargetAsync(process, generation, plan, target).ConfigureAwait(false);
            else
                await ReloadWatchTargetAsync(process, generation, target).ConfigureAwait(false);
        }
    }

    private async Task PublishAndReloadWatchTargetAsync(
        Process process,
        long generation,
        WorkspacePreviewPlan plan,
        WatchTarget target)
    {
        var revision = target.PendingRevision!;
        if (revision == target.LastSuccessfulRevision || revision == target.FailedRevision)
        {
            target.ClearPending();
            return;
        }
        await EmitLiveBakeEventAsync(process, generation, "live_bake_started", target.Name, plan, null, null).ConfigureAwait(false);
        EditorBakeResult bake;
        try
        {
            bake = await _workspacePreviewModel.BakeAsync(plan, target.Name, CancellationToken.None).ConfigureAwait(false);
        }
        catch (Exception exception)
        {
            target.FailedRevision = revision;
            target.ClearPending();
            await EmitLiveBakeEventAsync(process, generation, "live_bake_failed", target.Name, plan, null, exception).ConfigureAwait(false);
            return;
        }
        await EmitLiveBakeEventAsync(process, generation, "live_bake_completed", target.Name, plan, bake, null).ConfigureAwait(false);
        if (!string.Equals(TryGetFileRevision(target.Path), revision, StringComparison.Ordinal))
        {
            target.ClearPending();
            return;
        }
        target.LastSuccessfulRevision = revision;
        target.FailedRevision = null;
        var artifactRevision = target.Name == "Scene" ? bake.SceneArtifactRevision : bake.ScriptArtifactRevision;
        var artifactBytes = target.Name == "Scene" ? bake.SceneArtifactBytes : bake.ScriptArtifactBytes;
        await RequestReloadAsync(process, generation, target.Name, "live_bake", revision, artifactRevision, artifactBytes).ConfigureAwait(false);
        target.ClearPending();
        await EmitLauncherStatusAsync(process, generation, $"{target.Name.ToLowerInvariant()}_reload_requested", "auto").ConfigureAwait(false);
    }

    private async Task ReloadWatchTargetAsync(Process process, long generation, WatchTarget target)
    {
        var revision = target.PendingRevision!;
        if (revision == target.LastRequestedRevision)
        {
            target.ClearPending();
            return;
        }
        await RequestReloadAsync(process, generation, target.Name, "file_change", revision, null, null).ConfigureAwait(false);
        target.LastRequestedRevision = revision;
        target.ClearPending();
        await EmitLauncherStatusAsync(process, generation, $"{target.Name.ToLowerInvariant()}_reload_requested", "auto").ConfigureAwait(false);
    }

    private async Task RequestReloadAsync(
        Process process,
        long generation,
        string target,
        string source,
        string? revision,
        string? artifactRevision,
        int? artifactBytes)
    {
        await _eventBoundary.WaitAsync().ConfigureAwait(false);
        try
        {
            if (!IsCurrentRuntime(process, generation) || process.HasExited || _standardInputClosed) return;
            var requestId = _nextRequestId++;
            var command = target == "Scene" ? "reload_scene" : "reload_script";
            var pending = new PendingRequest(
                command,
                target,
                source,
                revision,
                artifactRevision,
                artifactBytes,
                DateTimeOffset.UtcNow);
            _pendingRequests.Add(requestId, pending);
            try { await WriteRuntimeCommandCoreAsync(process, requestId, command).ConfigureAwait(false); }
            catch
            {
                _pendingRequests.Remove(requestId);
                throw;
            }
            var requested = new Dictionary<string, object?>
            {
                ["event"] = "command_requested",
                ["requestId"] = requestId,
                ["command"] = command,
                ["source"] = source
            };
            AddPendingIdentity(requested, pending);
            requested.Remove("source");
            requested["source"] = source;
            await EmitLauncherEventCoreAsync(process, generation, requested).ConfigureAwait(false);
            var targetState = _reloadTargets[target];
            targetState.LatestRequestId = requestId;
            targetState.LatestRequestedSourceRevision = revision;
            targetState.FailedSourceRevision = null;
            var notification = BuildReloadNotification("requested", pending, requestId, targetState, null, null, false);
            await EmitCompatibilityAndStableCoreAsync(
                process,
                generation,
                "runtime_reload_requested",
                "preview_reload_requested",
                notification).ConfigureAwait(false);
        }
        finally { _eventBoundary.Release(); }
    }

    private async Task ExpirePendingRequestsAsync(Process process, long generation)
    {
        await _eventBoundary.WaitAsync().ConfigureAwait(false);
        try
        {
            var expired = _pendingRequests
                .Where(pair => DateTimeOffset.UtcNow - pair.Value.SentAt >= _timeouts.Request)
                .ToArray();
            foreach (var pair in expired)
            {
                if (!_pendingRequests.Remove(pair.Key)) continue;
                var response = new Dictionary<string, object?>
                {
                    ["event"] = "command_response",
                    ["requestId"] = pair.Key,
                    ["command"] = pair.Value.Command,
                    ["result"] = "timeout"
                };
                AddPendingIdentity(response, pair.Value);
                await EmitLauncherEventCoreAsync(process, generation, response).ConfigureAwait(false);
                if (pair.Value.Target is not null)
                    await CompleteReloadCoreAsync(process, generation, pair.Value, pair.Key, "timeout", "runtime_reload_timeout").ConfigureAwait(false);
            }
        }
        finally { _eventBoundary.Release(); }
    }

    private async Task StopOwnedRuntimeAsync(Process process, long generation)
    {
        if (!IsCurrentRuntime(process, generation) || process.HasExited) return;
        await RequestShutdownAsync(process, generation).ConfigureAwait(false);
        if (await WaitForExitAsync(process, _timeouts.RuntimeShutdown).ConfigureAwait(false)) return;
        if (NativePreviewWindow.TryClose(process.Id)
            && await WaitForExitAsync(process, _timeouts.WindowClose).ConfigureAwait(false))
        {
            return;
        }
        if (!process.HasExited)
        {
            process.Kill(entireProcessTree: true);
            await process.WaitForExitAsync().ConfigureAwait(false);
        }
    }

    private async Task RequestShutdownAsync(Process process, long generation)
    {
        await _eventBoundary.WaitAsync().ConfigureAwait(false);
        try
        {
            if (!IsCurrentRuntime(process, generation) || process.HasExited || _standardInputClosed) return;
            var requestId = _nextRequestId++;
            var pending = new PendingRequest("shutdown", null, "lifecycle", null, null, null, DateTimeOffset.UtcNow);
            _pendingRequests.Add(requestId, pending);
            try
            {
                await WriteRuntimeCommandCoreAsync(process, requestId, "shutdown").ConfigureAwait(false);
                var requested = new Dictionary<string, object?>
                {
                    ["event"] = "command_requested",
                    ["requestId"] = requestId,
                    ["command"] = "shutdown",
                    ["source"] = "lifecycle"
                };
                await EmitLauncherEventCoreAsync(process, generation, requested).ConfigureAwait(false);
                process.StandardInput.Close();
                _standardInputClosed = true;
            }
            catch (Exception exception) when (exception is IOException or InvalidOperationException)
            {
                _pendingRequests.Remove(requestId);
                _standardInputClosed = true;
            }
        }
        finally { _eventBoundary.Release(); }
    }

    private static async Task WriteRuntimeCommandCoreAsync(Process process, ulong requestId, string command)
    {
        var line = JsonSerializer.Serialize(new { schemaVersion = 1, requestId, command }, EditorProtocol.JsonOptions);
        await process.StandardInput.WriteLineAsync(line).ConfigureAwait(false);
        await process.StandardInput.FlushAsync().ConfigureAwait(false);
    }

    private async Task ObserveExitAsync(
        Process process,
        long generation,
        Task stdoutPump,
        Task stderrPump,
        Task backgroundTask,
        CancellationTokenSource backgroundCancellation)
    {
        await process.WaitForExitAsync().ConfigureAwait(false);
        backgroundCancellation.Cancel();
        await Task.WhenAll(stdoutPump, stderrPump, backgroundTask).ConfigureAwait(false);
        await _eventBoundary.WaitAsync().ConfigureAwait(false);
        try
        {
            if (!IsCurrentRuntime(process, generation) || _stoppedEmitted) return;
            _stoppedEmitted = true;
            bool requested;
            lock (_gate) { requested = _stopRequested; }
            await EmitOwnedAsync(process, generation, "preview_stopped", JsonSerializer.SerializeToElement(new
            {
                exitCode = process.ExitCode,
                requested
            }, EditorProtocol.JsonOptions)).ConfigureAwait(false);
        }
        finally { _eventBoundary.Release(); }
    }

    private async Task RetireExitedRuntimeAsync()
    {
        Process? process;
        long generation;
        lock (_gate)
        {
            process = _runtime;
            generation = _generation;
        }
        if (process is null) return;
        if (!process.HasExited) throw new InvalidOperationException("Preview is already running.");
        await CompleteLifecycleAsync(process, generation).ConfigureAwait(false);
    }

    private async Task CompleteLifecycleAsync(Process process, long generation)
    {
        Task stdoutPump;
        Task stderrPump;
        Task backgroundTask;
        Task exitObserver;
        CancellationTokenSource? backgroundCancellation;
        lock (_gate)
        {
            stdoutPump = _stdoutPump;
            stderrPump = _stderrPump;
            backgroundTask = _backgroundTask;
            exitObserver = _exitObserver;
            backgroundCancellation = _backgroundCancellation;
        }
        backgroundCancellation?.Cancel();
        await Task.WhenAll(stdoutPump, stderrPump, backgroundTask, exitObserver).ConfigureAwait(false);
        lock (_gate)
        {
            if (!IsCurrentRuntimeLocked(process, generation)) return;
            _runtime = null;
            _backgroundCancellation = null;
            _plan = null;
            _pendingRequests = [];
            _reloadTargets = CreateReloadTargets();
            _watchTargets = [];
            _stdoutPump = Task.CompletedTask;
            _stderrPump = Task.CompletedTask;
            _backgroundTask = Task.CompletedTask;
            _exitObserver = Task.CompletedTask;
        }
        backgroundCancellation?.Dispose();
        process.Dispose();
    }

    private async Task EmitLauncherStatusAsync(Process process, long generation, string name, string value)
    {
        await _eventBoundary.WaitAsync().ConfigureAwait(false);
        try
        {
            await EmitLauncherEventCoreAsync(process, generation, new Dictionary<string, object?>
            {
                ["event"] = "launcher_status",
                ["name"] = name,
                ["value"] = value
            }).ConfigureAwait(false);
        }
        finally { _eventBoundary.Release(); }
    }

    private async Task EmitLiveBakeEventAsync(
        Process process,
        long generation,
        string eventName,
        string target,
        WorkspacePreviewPlan plan,
        EditorBakeResult? bake,
        Exception? exception)
    {
        await _eventBoundary.WaitAsync().ConfigureAwait(false);
        try
        {
            var fields = new Dictionary<string, object?>
            {
                ["event"] = eventName,
                ["target"] = target,
                ["profile"] = plan.BakeProfile,
                ["entries"] = bake is null ? Array.Empty<object>() : ReadManifestEntries(plan.ManifestPath),
                ["adapterVersion"] = 1
            };
            if (exception is not null)
            {
                fields["errorCode"] = MapBakeFailure(exception);
                fields["message"] = exception.Message;
            }
            await EmitLauncherEventCoreAsync(process, generation, fields).ConfigureAwait(false);
        }
        finally { _eventBoundary.Release(); }
    }

    private async Task EmitCompatibilityAndStableCoreAsync<T>(
        Process process,
        long generation,
        string compatibilityEvent,
        string stableEvent,
        T notification)
    {
        var fields = JsonObjectFields(notification);
        fields["event"] = compatibilityEvent;
        await EmitLauncherEventCoreAsync(process, generation, fields).ConfigureAwait(false);
        await EmitOwnedAsync(
            process,
            generation,
            stableEvent,
            JsonSerializer.SerializeToElement(notification, EditorProtocol.JsonOptions)).ConfigureAwait(false);
    }

    private async Task EmitLauncherEventCoreAsync(
        Process process,
        long generation,
        Dictionary<string, object?> fields)
    {
        if (!IsCurrentRuntime(process, generation)) return;
        fields["schemaVersion"] = 1;
        fields["origin"] = "launcher";
        fields["sequence"] = ++_launcherSequence;
        await EmitOwnedAsync(
            process,
            generation,
            "preview_status",
            JsonSerializer.SerializeToElement(fields, EditorProtocol.JsonOptions)).ConfigureAwait(false);
    }

    private async Task EmitOwnedAsync(Process process, long generation, string eventName, JsonElement data)
    {
        if (!IsCurrentRuntime(process, generation)) return;
        var handler = Notification;
        if (handler is not null) await handler(eventName, data).ConfigureAwait(false);
    }

    private WorkspacePreviewPlan RequireCurrentPlan(Process process, long generation)
    {
        lock (_gate)
        {
            if (!IsCurrentRuntimeLocked(process, generation) || _plan is null)
                throw new InvalidOperationException("Preview generation is no longer current.");
            return _plan;
        }
    }

    private bool IsCurrentRuntime(Process process, long generation)
    {
        lock (_gate) { return IsCurrentRuntimeLocked(process, generation); }
    }

    private bool IsCurrentRuntimeLocked(Process process, long generation) =>
        ReferenceEquals(_runtime, process) && _generation == generation;

    private static async Task<bool> WaitForExitAsync(Process process, TimeSpan timeout)
    {
        if (process.HasExited) return true;
        try
        {
            using var cancellation = new CancellationTokenSource(timeout);
            await process.WaitForExitAsync(cancellation.Token).ConfigureAwait(false);
            return true;
        }
        catch (OperationCanceledException) { return process.HasExited; }
    }

    private static Dictionary<string, ReloadTargetState> CreateReloadTargets() => new(StringComparer.Ordinal)
    {
        ["Scene"] = new ReloadTargetState(),
        ["Script"] = new ReloadTargetState()
    };

    private static List<WatchTarget> CreateWatchTargets(WorkspacePreviewPlan plan, bool liveBake)
    {
        var scenePath = liveBake ? plan.SceneSourcePath! : plan.SceneInputPath;
        var scriptPath = liveBake ? plan.ScriptSourcePath! : plan.ScriptInputPath;
        return
        [
            WatchTarget.Create("Scene", scenePath, liveBake),
            WatchTarget.Create("Script", scriptPath, liveBake)
        ];
    }

    private static PreviewReloadNotification BuildReloadNotification(
        string state,
        PendingRequest pending,
        ulong requestId,
        ReloadTargetState targetState,
        string? result,
        string? errorCode,
        bool ignored) => new(
            1,
            state,
            pending.Target!,
            requestId,
            pending.Source,
            pending.Revision,
            pending.ArtifactRevision,
            pending.ArtifactBytes,
            targetState.LatestRequestedSourceRevision,
            targetState.AcknowledgedSourceRevision,
            targetState.AcknowledgedArtifactRevision,
            state == "failed" ? targetState.FailedSourceRevision : null,
            result,
            errorCode,
            null,
            ignored);

    private static void AddPendingIdentity(Dictionary<string, object?> fields, PendingRequest? pending)
    {
        if (pending is null) return;
        fields["source"] = pending.Source;
        if (pending.Revision is not null) fields["revision"] = pending.Revision;
        if (pending.ArtifactRevision is not null) fields["artifactRevision"] = pending.ArtifactRevision;
        if (pending.ArtifactBytes is > 0) fields["artifactBytes"] = pending.ArtifactBytes;
    }

    private static Dictionary<string, object?> JsonObjectFields<T>(T value)
    {
        var element = JsonSerializer.SerializeToElement(value, EditorProtocol.JsonOptions);
        var fields = new Dictionary<string, object?>(StringComparer.Ordinal);
        foreach (var property in element.EnumerateObject()) fields[property.Name] = property.Value.Clone();
        return fields;
    }

    private static object[] ReadManifestEntries(string? manifestPath)
    {
        if (manifestPath is null || !File.Exists(manifestPath)) return [];
        try
        {
            using var document = JsonDocument.Parse(File.ReadAllBytes(manifestPath));
            return
            [
                document.RootElement.GetProperty("scene").Clone(),
                document.RootElement.GetProperty("script").Clone()
            ];
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException or KeyNotFoundException or InvalidOperationException)
        {
            return [];
        }
    }

    private static string MapBakeFailure(Exception exception) => exception switch
    {
        WorkspacePublicationException { Kind: WorkspacePublicationFailureKind.SourceChanged } => "source_changed_during_bake",
        WorkspacePublicationException { Kind: WorkspacePublicationFailureKind.Promote } => "artifact_promote_failed",
        WorkspacePublicationException { Kind: WorkspacePublicationFailureKind.Validation or WorkspacePublicationFailureKind.InvalidTarget or WorkspacePublicationFailureKind.InvalidProfile } => "bake_validation_failed",
        _ => "live_bake_failed"
    };

    private static string TryGetFileRevision(string path)
    {
        try { return Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path))).ToLowerInvariant(); }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return $"unreadable:{exception.GetType().Name}";
        }
    }

    private static bool IsLowerHex64(string? revision) =>
        revision is { Length: 64 } && revision.All(value => value is >= '0' and <= '9' or >= 'a' and <= 'f');

    private static bool IsHex64(string? revision) =>
        revision is { Length: 64 } && revision.All(Uri.IsHexDigit);

    public async ValueTask DisposeAsync() => await StopAsync().ConfigureAwait(false);

    private sealed record PendingRequest(
        string Command,
        string? Target,
        string Source,
        string? Revision,
        string? ArtifactRevision,
        int? ArtifactBytes,
        DateTimeOffset SentAt);

    private sealed class ReloadTargetState
    {
        public ulong LatestRequestId { get; set; }
        public string? LatestRequestedSourceRevision { get; set; }
        public string? AcknowledgedSourceRevision { get; set; }
        public string? AcknowledgedArtifactRevision { get; set; }
        public string? FailedSourceRevision { get; set; }
    }

    private sealed class WatchTarget
    {
        private WatchTarget(string name, string path, string revision, bool liveBake)
        {
            Name = name;
            Path = path;
            ObservedRevision = revision;
            LastSuccessfulRevision = liveBake ? revision : null;
            LastRequestedRevision = liveBake ? null : revision;
        }

        public string Name { get; }
        public string Path { get; }
        public string ObservedRevision { get; set; }
        public string? PendingRevision { get; set; }
        public DateTimeOffset PendingSince { get; set; }
        public string? LastRequestedRevision { get; set; }
        public string? LastSuccessfulRevision { get; set; }
        public string? FailedRevision { get; set; }

        public static WatchTarget Create(string name, string path, bool liveBake) =>
            new(name, path, TryGetFileRevision(path), liveBake);

        public void ClearPending()
        {
            PendingRevision = null;
            PendingSince = default;
        }
    }

    private sealed record ManifestCorrelation(string Correlation, string? SourceRevision);
}

internal sealed record PreviewProcessTimeouts(
    TimeSpan RuntimeShutdown,
    TimeSpan WindowClose,
    TimeSpan Request)
{
    internal static PreviewProcessTimeouts Default { get; } = new(
        TimeSpan.FromSeconds(10),
        TimeSpan.FromSeconds(2),
        TimeSpan.FromSeconds(10));
}

internal static class NativePreviewWindow
{
    private const uint WmClose = 0x0010;

    public static bool TryClose(int processId)
    {
        if (!OperatingSystem.IsWindows()) return false;
        var result = false;
        EnumWindows((window, _) =>
        {
            GetWindowThreadProcessId(window, out var owner);
            if (owner != processId) return true;
            var name = new System.Text.StringBuilder(256);
            if (GetClassName(window, name, name.Capacity) > 0 && name.ToString() == "KadathRuntimeWindow")
            {
                result = PostMessage(window, WmClose, IntPtr.Zero, IntPtr.Zero);
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return result;
    }

    private delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int GetClassName(IntPtr window, System.Text.StringBuilder className, int maxCount);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool PostMessage(IntPtr window, uint message, IntPtr wordParameter, IntPtr longParameter);
}
