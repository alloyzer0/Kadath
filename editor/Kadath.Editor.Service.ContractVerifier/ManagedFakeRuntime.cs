using System.Diagnostics;
using System.Security.Cryptography;
using System.Text.Json;
using Kadath.Editor.Protocol;

namespace Kadath.Editor.Service.ContractVerifier;

internal static class ManagedFakeRuntime
{
    private static readonly object OutputGate = new();

    internal static async Task<int> RunAsync(string[] args)
    {
        if (args.Length < 2)
        {
            Console.Error.WriteLine("fake Runtime requires <mode> <child-pid-path>");
            return 64;
        }

        var mode = args[0];
        var childPidPath = Path.GetFullPath(args[1]);
        var scenePath = ResolveDocumentArgument(args, "--scene");
        var scriptPath = ResolveDocumentArgument(args, "--script");

        EmitRaw("not-json");
        EmitRaw("info: fake runtime stdout");
        Emit(new { schemaVersion = 1, sequence = 1, @event = "unknown_status" });
        Console.Error.WriteLine("fake runtime stderr");

        if (mode == "startup_fail")
        {
            Emit(new
            {
                schemaVersion = 1,
                sequence = 2,
                @event = "runtime_failed",
                phase = "startup",
                errorCode = "fake_startup_failure"
            });
            return 3;
        }

        if (mode == "source")
        {
            Emit(new
            {
                schemaVersion = 1,
                sequence = 2,
                @event = "runtime_ready",
                initialLoaded = new
                {
                    scene = new { kind = "source_document", sha256 = new string('b', 64), bytes = 5 },
                    script = new { kind = "source_document", sha256 = new string('c', 64), bytes = 6 }
                }
            });
        }
        else if (mode is "artifact_missing" or "artifact_mismatch")
        {
            // 留出稳定窗口，让 verifier 在 Runtime 报告 identity 前删除或篡改 manifest。
            await Task.Delay(400).ConfigureAwait(false);
            Emit(new
            {
                schemaVersion = 1,
                sequence = 2,
                @event = "runtime_ready",
                initialLoaded = new
                {
                    scene = ArtifactIdentity(scenePath),
                    script = ArtifactIdentity(scriptPath)
                }
            });
        }
        else
        {
            Emit(new
            {
                schemaVersion = 1,
                sequence = 2,
                @event = "runtime_ready",
                initialLoaded = new
                {
                    scene = new { kind = "built_in" },
                    script = new { kind = "built_in" }
                }
            });
        }

        if (mode == "self_exit")
        {
            await Task.Delay(100).ConfigureAwait(false);
            return 7;
        }

        if (mode == "hang")
        {
            StartOwnedChild(childPidPath);
        }

        var delayedScene = false;
        while (await Console.In.ReadLineAsync().ConfigureAwait(false) is { } line)
        {
            using var document = JsonDocument.Parse(line);
            var root = document.RootElement;
            var command = root.GetProperty("command").GetString();
            var requestId = root.GetProperty("requestId").GetUInt64();
            switch (command)
            {
                case "reload_script":
                    if (mode == "timeout") break;
                    if (mode == "reject")
                    {
                        Emit(new { schemaVersion = 1, sequence = 3, @event = "command_completed", requestId, command = "reload_script", result = "rejected", errorCode = "fake_reject" });
                    }
                    else
                    {
                        Emit(new { schemaVersion = 1, sequence = 3, @event = "command_completed", requestId, command = "reload_script", result = "succeeded" });
                    }
                    break;
                case "reload_scene":
                    if (mode == "stale" && !delayedScene)
                    {
                        delayedScene = true;
                        _ = EmitDelayedSceneCompletionAsync(requestId);
                    }
                    else
                    {
                        Emit(new { schemaVersion = 1, sequence = 4, @event = "command_completed", requestId, command = "reload_scene", result = "succeeded" });
                    }
                    break;
                case "shutdown":
                    if (mode == "hang") break;
                    Emit(new { schemaVersion = 1, sequence = 6, @event = "command_completed", requestId, command = "shutdown", result = "succeeded" });
                    Emit(new { schemaVersion = 1, sequence = 7, @event = "runtime_stopping", reason = "control_shutdown" });
                    return 0;
            }
        }

        if (mode == "hang")
        {
            await Task.Delay(Timeout.InfiniteTimeSpan).ConfigureAwait(false);
        }
        return 0;
    }

    internal static async Task<int> RunChildAsync()
    {
        await Task.Delay(Timeout.InfiniteTimeSpan).ConfigureAwait(false);
        return 0;
    }

    private static async Task EmitDelayedSceneCompletionAsync(ulong requestId)
    {
        await Task.Delay(450).ConfigureAwait(false);
        Emit(new { schemaVersion = 1, sequence = 5, @event = "command_completed", requestId, command = "reload_scene", result = "succeeded" });
    }

    private static void StartOwnedChild(string childPidPath)
    {
        // 子进程必须由 fake Runtime 直接创建，才能从产品的整棵进程树终止语义观察到它被收割。
        var executable = Environment.ProcessPath
            ?? throw new InvalidOperationException("fake Runtime executable path is unavailable");
        var startInfo = new ProcessStartInfo
        {
            FileName = executable,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        startInfo.ArgumentList.Add("--fake-child");
        var child = Process.Start(startInfo)
            ?? throw new InvalidOperationException("failed to start fake Runtime child");
        File.WriteAllText(childPidPath, child.Id.ToString(System.Globalization.CultureInfo.InvariantCulture));
        child.Dispose();
    }

    private static string ResolveDocumentArgument(IReadOnlyList<string> args, string option)
    {
        for (var index = 2; index + 1 < args.Count; index++)
        {
            if (args[index] == option) return Path.GetFullPath(args[index + 1]);
        }
        throw new ArgumentException($"fake Runtime is missing {option}");
    }

    private static object ArtifactIdentity(string path)
    {
        var bytes = File.ReadAllBytes(path);
        return new
        {
            kind = "artifact",
            sha256 = Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant(),
            bytes = bytes.LongLength
        };
    }

    private static void Emit(object value) => EmitRaw(JsonSerializer.Serialize(value, EditorProtocol.JsonOptions));

    private static void EmitRaw(string line)
    {
        lock (OutputGate)
        {
            Console.Out.WriteLine(line);
            Console.Out.Flush();
        }
    }
}
