using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Kadath.Editor.Protocol;
using Kadath.Editor.Service;
using Kadath.Editor.Workspace;

namespace Kadath.Editor.Service.ContractVerifier;

internal static class Program
{
    private static readonly PreviewProcessTimeouts TestTimeouts = new(
        TimeSpan.FromMilliseconds(300),
        TimeSpan.FromMilliseconds(100),
        TimeSpan.FromMilliseconds(350));

    public static async Task<int> Main(string[] args)
    {
        // fake Runtime 与 verifier 共用同一个托管入口，避免测试能力被 shell 或宿主平台绑死。
        if (args is ["--fake-runtime", .. var runtimeArguments])
        {
            return await ManagedFakeRuntime.RunAsync(runtimeArguments).ConfigureAwait(false);
        }
        if (args is ["--fake-child"])
        {
            return await ManagedFakeRuntime.RunChildAsync().ConfigureAwait(false);
        }
        if (args.Length != 0)
        {
            Console.Error.WriteLine("verification=failed: unsupported verifier arguments");
            return 1;
        }

        var root = Path.Combine(Path.GetTempPath(), $"kadath-native-preview-{Guid.NewGuid():N}");
        try
        {
            Directory.CreateDirectory(root);
            await ScriptAnalysisHostVerifier.VerifyAsync();
            await VerifyInitialIdentityBoundariesAsync(root);
            await VerifyRejectedReloadAsync(root);
            await VerifyReloadTimeoutAsync(root);
            await VerifyStaleReloadAsync(root);
            await VerifyUnexpectedExitAndRestartAsync(root);
            await VerifyBoundedProcessTreeKillAsync(root);
            await LiveBakeWatchVerifier.VerifyAsync(root);
            Console.WriteLine("preview_diagnostics=ok");
            Console.WriteLine("script_analysis_host_concurrency=ok");
            Console.WriteLine("script_analysis_cleanup_mapping=ok");
            Console.WriteLine("preview_initial_identity_boundaries=ok");
            Console.WriteLine("preview_reload_rejected=ok");
            Console.WriteLine("preview_reload_timeout=ok");
            Console.WriteLine("preview_reload_stale=ok");
            Console.WriteLine("preview_unexpected_exit_restart=ok");
            Console.WriteLine("preview_process_tree_kill=ok");
            Console.WriteLine("live_bake_dependency_watch=ok");
            Console.WriteLine("verification=ok");
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine($"verification=failed: {exception}");
            return 1;
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
    }

    private static async Task VerifyInitialIdentityBoundariesAsync(string root)
    {
        var sourceFixture = CreateFixture(root, "source");
        await using (var controller = CreateController(out var sourceEvents))
        {
            await controller.StartAsync(new PreviewStartParameters(sourceFixture.ConfigPath, sourceFixture.PackageRoot, PollIntervalMilliseconds: 25));
            var source = await sourceEvents.WaitAsync("preview_initial_loaded");
            Require(source.Data.GetProperty("scene").GetProperty("kind").GetString() == "source_document"
                && source.Data.GetProperty("scene").GetProperty("correlation").GetString() == "runtime_source", "source initial identity mismatch");
            await controller.StopAsync();
        }

        var missingFixture = CreateFixture(root, "artifact_missing");
        await using (var controller = CreateController(out var missingEvents))
        {
            await controller.StartAsync(new PreviewStartParameters(missingFixture.ConfigPath, missingFixture.PackageRoot, LiveBake: true, PollIntervalMilliseconds: 25));
            File.Delete(missingFixture.ManifestPath);
            var missing = await missingEvents.WaitAsync("preview_initial_loaded");
            Require(missing.Data.GetProperty("scene").GetProperty("correlation").GetString() == "manifest_missing", "missing manifest correlation mismatch");
            await controller.StopAsync();
        }

        var mismatchFixture = CreateFixture(root, "artifact_mismatch");
        await using (var controller = CreateController(out var mismatchEvents))
        {
            await controller.StartAsync(new PreviewStartParameters(mismatchFixture.ConfigPath, mismatchFixture.PackageRoot, LiveBake: true, PollIntervalMilliseconds: 25));
            var manifest = JsonNode.Parse(File.ReadAllText(mismatchFixture.ManifestPath, Encoding.UTF8))
                ?? throw new InvalidOperationException("preview manifest parse failed");
            manifest["scene"]!["artifactSha256"] = new string('0', 64);
            File.WriteAllText(mismatchFixture.ManifestPath, manifest.ToJsonString(EditorProtocol.JsonOptions), new UTF8Encoding(false));
            var mismatch = await mismatchEvents.WaitAsync("preview_initial_loaded");
            Require(mismatch.Data.GetProperty("scene").GetProperty("correlation").GetString() == "artifact_mismatch", "artifact mismatch correlation mismatch");
            await controller.StopAsync();
        }

        var failedFixture = CreateFixture(root, "startup_fail");
        await using (var controller = CreateController(out var failedEvents))
        {
            await controller.StartAsync(new PreviewStartParameters(failedFixture.ConfigPath, failedFixture.PackageRoot, PollIntervalMilliseconds: 25));
            var failed = await failedEvents.WaitAsync("preview_initial_load_failed");
            Require(failed.Data.GetProperty("errorCode").GetString() == "fake_startup_failure", "startup failure code mismatch");
            var stopped = await failedEvents.WaitAsync("preview_stopped");
            Require(!stopped.Data.GetProperty("requested").GetBoolean() && failedEvents.Count("preview_initial_load_failed") == 1, "startup failure terminal multiplicity mismatch");
        }
    }

    private static async Task VerifyRejectedReloadAsync(string root)
    {
        var fixture = CreateFixture(root, "reject");
        await using var controller = CreateController(out var events);
        await controller.StartAsync(new PreviewStartParameters(
            fixture.ConfigPath,
            fixture.PackageRoot,
            ReloadScriptAfterMilliseconds: 75,
            PollIntervalMilliseconds: 25));
        var initial = await events.WaitAsync("preview_initial_loaded", data => data.GetProperty("scene").GetProperty("correlation").GetString() == "built_in");
        Require(initial.Data.GetProperty("script").GetProperty("kind").GetString() == "built_in", "built-in initial identity mismatch");
        _ = await events.WaitAsync("preview_status", data => data.TryGetProperty("event", out var value) && value.GetString() == "protocol_error");
        var stdoutLog = await events.WaitAsync("preview_status", data => data.TryGetProperty("event", out var value)
            && value.GetString() == "runtime_log"
            && data.GetProperty("stream").GetString() == "stdout");
        Require(stdoutLog.Data.GetProperty("message").GetString() == "info: fake runtime stdout", "Runtime stdout log projection mismatch");
        _ = await events.WaitAsync("preview_status", data => data.TryGetProperty("event", out var value) && value.GetString() == "unknown_status");
        var failed = await events.WaitAsync("preview_reload_failed", data => data.GetProperty("target").GetString() == "Script");
        Require(failed.Data.GetProperty("result").GetString() == "rejected"
            && failed.Data.GetProperty("errorCode").GetString() == "fake_reject", "rejected reload terminal mismatch");
        await controller.StopAsync();
        var stopped = await events.WaitAsync("preview_stopped");
        Require(stopped.Data.GetProperty("requested").GetBoolean(), "explicit stop must be requested");
    }

    private static async Task VerifyReloadTimeoutAsync(string root)
    {
        var fixture = CreateFixture(root, "timeout");
        await using var controller = CreateController(out var events);
        await controller.StartAsync(new PreviewStartParameters(
            fixture.ConfigPath,
            fixture.PackageRoot,
            ReloadScriptAfterMilliseconds: 50,
            PollIntervalMilliseconds: 25));
        var failed = await events.WaitAsync("preview_reload_failed", data => data.GetProperty("result").GetString() == "timeout");
        Require(failed.Data.GetProperty("errorCode").GetString() == "runtime_reload_timeout", "reload timeout error mismatch");
        await controller.StopAsync();
    }

    private static async Task VerifyStaleReloadAsync(string root)
    {
        var fixture = CreateFixture(root, "stale");
        await using var controller = CreateController(out var events);
        await controller.StartAsync(new PreviewStartParameters(
            fixture.ConfigPath,
            fixture.PackageRoot,
            WatchChanges: true,
            PollIntervalMilliseconds: 25,
            DebounceMilliseconds: 50));
        _ = await events.WaitAsync("preview_initial_loaded");
        File.WriteAllText(fixture.ScenePath, "first", Encoding.UTF8);
        var first = await events.WaitAsync("preview_reload_requested", data => data.GetProperty("target").GetString() == "Scene");
        File.WriteAllText(fixture.ScenePath, "second", Encoding.UTF8);
        var second = await events.WaitAsync("preview_reload_requested", data =>
            data.GetProperty("target").GetString() == "Scene"
            && data.GetProperty("requestId").GetUInt64() != first.Data.GetProperty("requestId").GetUInt64());
        var secondId = second.Data.GetProperty("requestId").GetUInt64();
        var firstId = first.Data.GetProperty("requestId").GetUInt64();
        _ = await events.WaitAsync("preview_reload_acknowledged", data => data.GetProperty("requestId").GetUInt64() == secondId);
        var stale = await events.WaitAsync("preview_reload_stale", data => data.GetProperty("requestId").GetUInt64() == firstId);
        Require(stale.Data.GetProperty("ignored").GetBoolean()
            && stale.Data.GetProperty("latestRequestedSourceRevision").GetString() == second.Data.GetProperty("sourceRevision").GetString(), "stale reload protection mismatch");
        await controller.StopAsync();
    }

    private static async Task VerifyUnexpectedExitAndRestartAsync(string root)
    {
        var fixture = CreateFixture(root, "self_exit");
        await using var controller = CreateController(out var events);
        await controller.StartAsync(new PreviewStartParameters(fixture.ConfigPath, fixture.PackageRoot, PollIntervalMilliseconds: 25));
        var stopped = await events.WaitAsync("preview_stopped", data => data.GetProperty("exitCode").GetInt32() == 7);
        Require(!stopped.Data.GetProperty("requested").GetBoolean(), "unexpected exit was marked requested");

        fixture = CreateFixture(root, "normal");
        await controller.StartAsync(new PreviewStartParameters(fixture.ConfigPath, fixture.PackageRoot, PollIntervalMilliseconds: 25));
        _ = await events.WaitAsync("preview_initial_loaded");
        await controller.StopAsync();
        await controller.StopAsync();
    }

    private static async Task VerifyBoundedProcessTreeKillAsync(string root)
    {
        var fixture = CreateFixture(root, "hang");
        await using var controller = CreateController(out var events);
        await controller.StartAsync(new PreviewStartParameters(fixture.ConfigPath, fixture.PackageRoot, PollIntervalMilliseconds: 25));
        _ = await events.WaitAsync("preview_initial_loaded");
        await WaitUntilAsync(() => File.Exists(fixture.ChildPidPath), TimeSpan.FromSeconds(2));
        var childProcessId = int.Parse(File.ReadAllText(fixture.ChildPidPath, Encoding.UTF8));
        var stopwatch = Stopwatch.StartNew();
        await controller.StopAsync();
        Require(stopwatch.Elapsed < TimeSpan.FromSeconds(2), "bounded stop exceeded verifier limit");
        await WaitUntilAsync(() => !IsProcessAlive(childProcessId), TimeSpan.FromSeconds(2));
        var stopped = await events.WaitAsync("preview_stopped");
        Require(stopped.Data.GetProperty("requested").GetBoolean(), "killed runtime stop was not requested");
    }

    private static PreviewProcessController CreateController(out EventCollector events)
    {
        events = new EventCollector();
        var controller = new PreviewProcessController(
            new WorkspacePreviewModel(new WorkspacePublicationModel()),
            TestTimeouts);
        controller.Notification += events.PublishAsync;
        return controller;
    }

    private static PreviewFixture CreateFixture(string root, string mode)
    {
        var packageRoot = Path.Combine(root, mode);
        var bin = Path.Combine(packageRoot, "bin");
        var project = Path.Combine(bin, "projects", "demo");
        Directory.CreateDirectory(project);
        var runtimeExecutable = InstallManagedFakeRuntime(bin);
        var scenePath = Path.Combine(project, "scene.json");
        var scriptPath = Path.Combine(project, "script.json");
        var configPath = Path.Combine(project, "preview.json");
        var childPidPath = Path.Combine(packageRoot, "child.pid");
        File.WriteAllText(scenePath, """
        {"schemaVersion":3,"textures":[{"textureId":1,"artifact":"assets/renderer2d/test.texture"}],"player":{"position":[312,130],"size":[320,240],"color":[1,1,1,1],"moveSpeed":180,"textureId":1},"goal":{"position":[700,200],"size":[96,96],"color":[1,0.75,0.1,1],"textureId":1},"hazard":{"position":[650,280],"size":[96,96],"color":[0.95,0.2,0.2,1],"patrolMinY":245,"patrolMaxY":330,"patrolSpeed":80,"textureId":1}}
        """, new UTF8Encoding(false));
        File.WriteAllText(scriptPath, """
        {"schemaVersion":1,"instructions":[{"hook":"on_start","op":"set_goal_position","value":[680,200]},{"hook":"fixed_update","op":"move_goal_velocity","value":[-12,0]}]}
        """, new UTF8Encoding(false));
        File.WriteAllText(configPath, JsonSerializer.Serialize(new
        {
            schemaVersion = 1,
            runtime = new
            {
                executable = $"bin/{runtimeExecutable}",
                workingDirectory = "bin",
                arguments = new[]
                {
                    "--fake-runtime",
                    mode,
                    childPidPath,
                    "--scene",
                    "projects/demo/scene.json",
                    "--script",
                    "projects/demo/script.json"
                }
            }
        }, EditorProtocol.JsonOptions), new UTF8Encoding(false));
        return new PreviewFixture(
            packageRoot,
            configPath,
            scenePath,
            childPidPath,
            Path.Combine(project, ".kadath", "derived", ".live-bake.manifest.json"));
    }

    private static string InstallManagedFakeRuntime(string destinationDirectory)
    {
        var executableName = OperatingSystem.IsWindows()
            ? "Kadath.Editor.Service.ContractVerifier.exe"
            : "Kadath.Editor.Service.ContractVerifier";
        var sourceDirectory = AppContext.BaseDirectory;
        var sourceExecutable = Path.Combine(sourceDirectory, executableName);
        if (!File.Exists(sourceExecutable))
        {
            throw new FileNotFoundException("Managed fake Runtime apphost was not built.", sourceExecutable);
        }

        // apphost、runtimeconfig 与依赖程序集必须保持同目录，复制完整输出集合可保持普通 dotnet build 可运行。
        foreach (var source in Directory.EnumerateFiles(sourceDirectory))
        {
            File.Copy(source, Path.Combine(destinationDirectory, Path.GetFileName(source)), overwrite: false);
        }

        var installedExecutable = Path.Combine(destinationDirectory, executableName);
        if (!OperatingSystem.IsWindows())
        {
            File.SetUnixFileMode(installedExecutable,
                UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute
                | UnixFileMode.GroupRead | UnixFileMode.GroupExecute
                | UnixFileMode.OtherRead | UnixFileMode.OtherExecute);
        }
        return executableName;
    }

    private static bool IsProcessAlive(int processId)
    {
        try
        {
            using var process = Process.GetProcessById(processId);
            return !process.HasExited;
        }
        catch (ArgumentException)
        {
            return false;
        }
    }

    private static async Task WaitUntilAsync(Func<bool> predicate, TimeSpan timeout)
    {
        var deadline = DateTimeOffset.UtcNow + timeout;
        while (!predicate())
        {
            if (DateTimeOffset.UtcNow >= deadline) throw new TimeoutException("Verifier condition timed out.");
            await Task.Delay(20);
        }
    }

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private sealed record PreviewFixture(
        string PackageRoot,
        string ConfigPath,
        string ScenePath,
        string ChildPidPath,
        string ManifestPath);

    private sealed class EventCollector
    {
        private readonly object _gate = new();
        private readonly List<ObservedEvent> _events = [];
        private TaskCompletionSource _changed = NewSignal();

        public Task PublishAsync(string eventName, JsonElement? data)
        {
            TaskCompletionSource signal;
            lock (_gate)
            {
                _events.Add(new ObservedEvent(eventName, data?.Clone() ?? default));
                signal = _changed;
                _changed = NewSignal();
            }
            signal.TrySetResult();
            return Task.CompletedTask;
        }

        public async Task<ObservedEvent> WaitAsync(
            string eventName,
            Func<JsonElement, bool>? predicate = null,
            TimeSpan? timeout = null)
        {
            var deadline = DateTimeOffset.UtcNow + (timeout ?? TimeSpan.FromSeconds(5));
            while (true)
            {
                Task changed;
                lock (_gate)
                {
                    var match = _events.FirstOrDefault(value => value.Name == eventName && (predicate is null || predicate(value.Data)));
                    if (match is not null) return match;
                    changed = _changed.Task;
                }
                var remaining = deadline - DateTimeOffset.UtcNow;
                if (remaining <= TimeSpan.Zero) throw new TimeoutException($"Timed out waiting for {eventName}.");
                await changed.WaitAsync(remaining);
            }
        }

        public int Count(string eventName)
        {
            lock (_gate) return _events.Count(value => value.Name == eventName);
        }

        private static TaskCompletionSource NewSignal() => new(TaskCreationOptions.RunContinuationsAsynchronously);
    }

    private sealed record ObservedEvent(string Name, JsonElement Data);
}
