using System.Text;
using System.Text.Json;
using Kadath.Editor.Core;
using Kadath.Editor.Protocol;
using Kadath.Editor.Service;

namespace Kadath.Editor.Service.ContractVerifier;

internal static class LiveBakeWatchVerifier
{
    internal static async Task VerifyAsync(string root)
    {
        var project = CreateProject(Path.Combine(root, "live-bake-watch"));
        var bakes = new BakeCollector();
        var events = new NotificationCollector();
        await using var controller = new LiveBakeWatchController(
            project,
            new WatchStartParameters("Both", "debug", PollIntervalMilliseconds: 25, DebounceMilliseconds: 150),
            bakes.BakeAsync,
            events.PublishAsync);
        controller.Start();

        var patrolPath = Path.Combine(project.ProjectDirectory, "scripts", "patrol.luau");
        File.AppendAllText(project.ScenePath, "\n", Encoding.UTF8);
        await Task.Delay(40);
        File.AppendAllText(patrolPath, "\n-- behavior changed\n", new UTF8Encoding(false));
        var both = await bakes.WaitForCountAsync(1);
        Require(both.SequenceEqual(["Both"]), "Scene and Script changes in one debounce window were not published as one Both transaction.");
        var bothStarted = await events.WaitAsync("bake_started", data => data.GetProperty("target").GetString() == "Both");
        Require(bothStarted.Data.GetProperty("revisions").TryGetProperty("scene", out _)
            && bothStarted.Data.GetProperty("revisions").TryGetProperty("script", out _),
            "Both bake event omitted source revisions.");

        File.AppendAllText(patrolPath, "\n-- script-only change\n", new UTF8Encoding(false));
        var scriptOnly = await bakes.WaitForCountAsync(2);
        Require(scriptOnly.SequenceEqual(["Both", "Script"]), "A .luau-only change did not trigger Script publication.");

        var secondPath = Path.Combine(project.ProjectDirectory, "scripts", "second.luau");
        File.WriteAllText(secondPath, SecondLuau, new UTF8Encoding(false));
        File.WriteAllText(project.ScriptPath, TwoScriptManifestJson, Encoding.UTF8);
        var manifestChanged = await bakes.WaitForCountAsync(3);
        Require(manifestChanged[^1] == "Script", "A valid Script dependency-set change did not trigger publication.");

        File.AppendAllText(secondPath, "\n-- second dependency changed\n", new UTF8Encoding(false));
        var secondDependencyChanged = await bakes.WaitForCountAsync(4);
        Require(secondDependencyChanged[^1] == "Script", "A newly declared .luau dependency was not watched.");
        await controller.StopAsync();
    }

    private static ProjectSessionInfo CreateProject(string root)
    {
        var projectDirectory = Path.Combine(root, "bin", "projects", "demo");
        Directory.CreateDirectory(Path.Combine(projectDirectory, "scripts"));
        var scenePath = Path.Combine(projectDirectory, "scene.json");
        var scriptPath = Path.Combine(projectDirectory, "script.json");
        var previewPath = Path.Combine(projectDirectory, "preview.json");
        File.WriteAllText(scenePath, "{\"schemaVersion\":5}", Encoding.UTF8);
        File.WriteAllText(scriptPath, OneScriptManifestJson, Encoding.UTF8);
        File.WriteAllText(Path.Combine(projectDirectory, "scripts", "patrol.luau"), FirstLuau, new UTF8Encoding(false));
        File.WriteAllText(previewPath, "{\"schemaVersion\":1}", Encoding.UTF8);
        return new ProjectSessionInfo(root, "demo", projectDirectory, scenePath, scriptPath, previewPath, 1);
    }

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private sealed class BakeCollector
    {
        private readonly object _gate = new();
        private readonly List<string> _targets = [];
        private TaskCompletionSource _changed = NewSignal();

        public Task<EditorBakeResult> BakeAsync(string target, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            TaskCompletionSource signal;
            lock (_gate)
            {
                _targets.Add(target);
                signal = _changed;
                _changed = NewSignal();
            }
            signal.TrySetResult();
            return Task.FromResult(new EditorBakeResult(
                "succeeded", target, "debug", "derived", "manifest", null, null, null, null, null, null));
        }

        public async Task<string[]> WaitForCountAsync(int count)
        {
            var deadline = DateTimeOffset.UtcNow + TimeSpan.FromSeconds(5);
            while (true)
            {
                Task changed;
                lock (_gate)
                {
                    if (_targets.Count >= count) return _targets.ToArray();
                    changed = _changed.Task;
                }
                var remaining = deadline - DateTimeOffset.UtcNow;
                if (remaining <= TimeSpan.Zero) throw new TimeoutException($"Timed out waiting for {count} live-bake calls.");
                await changed.WaitAsync(remaining);
            }
        }

        private static TaskCompletionSource NewSignal() => new(TaskCreationOptions.RunContinuationsAsynchronously);
    }

    private sealed class NotificationCollector
    {
        private readonly object _gate = new();
        private readonly List<ObservedNotification> _events = [];
        private TaskCompletionSource _changed = NewSignal();

        public Task PublishAsync(EditorSessionNotification notification)
        {
            TaskCompletionSource signal;
            lock (_gate)
            {
                _events.Add(new ObservedNotification(notification.Event, notification.Data?.Clone() ?? default));
                signal = _changed;
                _changed = NewSignal();
            }
            signal.TrySetResult();
            return Task.CompletedTask;
        }

        public async Task<ObservedNotification> WaitAsync(string name, Func<JsonElement, bool> predicate)
        {
            var deadline = DateTimeOffset.UtcNow + TimeSpan.FromSeconds(5);
            while (true)
            {
                Task changed;
                lock (_gate)
                {
                    var match = _events.FirstOrDefault(value => value.Name == name && predicate(value.Data));
                    if (match is not null) return match;
                    changed = _changed.Task;
                }
                var remaining = deadline - DateTimeOffset.UtcNow;
                if (remaining <= TimeSpan.Zero) throw new TimeoutException($"Timed out waiting for {name}.");
                await changed.WaitAsync(remaining);
            }
        }

        private static TaskCompletionSource NewSignal() => new(TaskCreationOptions.RunContinuationsAsynchronously);
    }

    private sealed record ObservedNotification(string Name, JsonElement Data);

    private const string OneScriptManifestJson = """
    { "schemaVersion": 2, "scripts": [{ "scriptId": 1, "source": "scripts/patrol.luau" }] }
    """;

    private const string TwoScriptManifestJson = """
    {
      "schemaVersion": 2,
      "scripts": [
        { "scriptId": 1, "source": "scripts/patrol.luau" },
        { "scriptId": 2, "source": "scripts/second.luau" }
      ]
    }
    """;

    private const string FirstLuau = """
    --!strict
    return { fixed_update = function(self: Kadath.Object, dt: number) self:translate(dt, 0) end }
    """;

    private const string SecondLuau = """
    --!strict
    return { fixed_update = function(self: Kadath.Object, dt: number) self:translate(0, dt) end }
    """;
}
