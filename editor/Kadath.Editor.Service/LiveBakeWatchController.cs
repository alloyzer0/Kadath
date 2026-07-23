using System.Security.Cryptography;
using System.Text.Json;
using Kadath.Editor.Core;
using Kadath.Editor.Protocol;

namespace Kadath.Editor.Service;

/// <summary>
/// 独立于 Runtime 的 source watcher。它只负责稳定性、顺序和 bake 事件；Runtime reload 仍由 Preview Launcher 负责。
/// </summary>
internal sealed class LiveBakeWatchController : IAsyncDisposable
{
    private readonly ProjectSessionInfo _project;
    private readonly WatchStartParameters _parameters;
    private readonly Func<string, CancellationToken, Task<EditorBakeResult>> _bake;
    private readonly Func<EditorSessionNotification, Task> _notify;
    private readonly WatchTarget[] _targets;
    private CancellationTokenSource? _stop;
    private Task? _loop;

    public LiveBakeWatchController(
        ProjectSessionInfo project,
        WatchStartParameters parameters,
        Func<string, CancellationToken, Task<EditorBakeResult>> bake,
        Func<EditorSessionNotification, Task> notify)
    {
        _project = project;
        _parameters = parameters;
        _bake = bake;
        _notify = notify;
        _targets = BuildTargets(parameters.Target);
    }

    public bool IsRunning => _loop is { IsCompleted: false };

    public void Start()
    {
        if (IsRunning) { throw new InvalidOperationException("Live bake watch is already running."); }
        _stop = new CancellationTokenSource();
        foreach (var target in _targets)
        {
            var revision = GetRevision(target.Path);
            target.ObservedRevision = revision;
            target.LastSuccessfulRevision = revision;
        }
        _loop = Task.Run(() => RunAsync(_stop.Token));
    }

    public async Task StopAsync()
    {
        if (_stop is null) { return; }
        _stop.Cancel();
        if (_loop is not null)
        {
            try { await _loop; }
            catch (OperationCanceledException) { }
        }
        _stop.Dispose();
        _stop = null;
        _loop = null;
    }

    private async Task RunAsync(CancellationToken cancellationToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromMilliseconds(_parameters.PollIntervalMilliseconds));
        while (await timer.WaitForNextTickAsync(cancellationToken))
        {
            var now = DateTime.UtcNow;
            // 固定 Scene → Script 顺序，保持 Scene restart 后 Script on_start/fixed_update 的确定性。
            foreach (var target in _targets)
            {
                await UpdateTargetAsync(target, now, cancellationToken);
            }
        }
    }

    private async Task UpdateTargetAsync(WatchTarget target, DateTime now, CancellationToken cancellationToken)
    {
        var revision = GetRevision(target.Path);
        if (!string.Equals(revision, target.ObservedRevision, StringComparison.Ordinal))
        {
            target.ObservedRevision = revision;
            target.PendingRevision = revision;
            target.PendingSince = now;
            await EmitAsync("source_change_detected", new { target = target.Name, revision }, null);
        }
        if (target.PendingRevision is null || !string.Equals(revision, target.PendingRevision, StringComparison.Ordinal)) { return; }
        if ((now - target.PendingSince).TotalMilliseconds < _parameters.DebounceMilliseconds) { return; }
        if (string.Equals(revision, target.LastSuccessfulRevision, StringComparison.Ordinal) || string.Equals(revision, target.FailedRevision, StringComparison.Ordinal))
        {
            target.PendingRevision = null;
            return;
        }

        await EmitAsync("bake_started", new { target = target.Name, profile = _parameters.Profile, revision }, null);
        try
        {
            var result = await _bake(target.AdapterTarget, cancellationToken);
            target.LastSuccessfulRevision = revision;
            target.FailedRevision = null;
            target.PendingRevision = null;
            await EmitAsync("bake_completed", result, null);
        }
        catch (EditorOperationException exception)
        {
            target.FailedRevision = revision;
            target.PendingRevision = null;
            await EmitAsync("bake_failed", new { target = target.Name, errorCode = exception.Code, message = exception.Message, retainedArtifact = true }, null);
        }
    }

    private WatchTarget[] BuildTargets(string target)
    {
        var normalized = target.ToLowerInvariant();
        if (normalized is not ("scene" or "script" or "both")) { throw new EditorOperationException("invalid_bake_target", $"Unsupported watch target: {target}"); }
        var targets = new List<WatchTarget>();
        if (normalized is "scene" or "both") { targets.Add(new WatchTarget("scene", "Scene", _project.ScenePath)); }
        if (normalized is "script" or "both") { targets.Add(new WatchTarget("script", "Script", _project.ScriptPath)); }
        return targets.ToArray();
    }

    private async Task EmitAsync(string eventName, object data, string? requestId)
    {
        await _notify(new EditorSessionNotification(eventName, JsonSerializer.SerializeToElement(data, EditorProtocol.JsonOptions), requestId));
    }

    private static string GetRevision(string path)
    {
        if (!File.Exists(path)) { return "missing"; }
        try { return Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path))); }
        catch (Exception exception) { return $"unreadable:{exception.GetType().Name}"; }
    }

    public async ValueTask DisposeAsync() => await StopAsync();

    private sealed class WatchTarget(string name, string adapterTarget, string path)
    {
        public string Name { get; } = name;
        public string AdapterTarget { get; } = adapterTarget;
        public string Path { get; } = path;
        public string? ObservedRevision { get; set; }
        public string? PendingRevision { get; set; }
        public DateTime PendingSince { get; set; }
        public string? LastSuccessfulRevision { get; set; }
        public string? FailedRevision { get; set; }
    }
}
