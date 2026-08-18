using System.Text.Json;
using System.Text.RegularExpressions;

namespace Kadath.Runtime.Windows.ContractVerifier;

internal static partial class RuntimeStatusProtocol
{
    public static RuntimeInitialLoadedEvidence ParseInitialLoaded(
        string stdout,
        FileIdentity expectedScene,
        FileIdentity expectedScript)
    {
        const string stage = "initial_loaded";
        var events = ParseEvents(stdout, stage);
        var ready = events.Where(value => value.Event == "runtime_ready").ToArray();
        if (ready.Length != 1)
            throw Product(stage, $"Expected exactly one runtime_ready status event, got {ready.Length}.");
        if (events.Any(value => value.Event == "runtime_failed"))
            throw Product(stage, "Runtime published runtime_failed before initial loaded identity completed.");

        var root = ready[0].Root;
        if (!root.TryGetProperty("initialLoaded", out var loaded) || loaded.ValueKind != JsonValueKind.Object)
            throw Product(stage, "runtime_ready did not atomically publish initialLoaded Scene/Script identity.");
        var scene = ParseTarget(loaded, "scene", expectedScene, stage);
        var script = ParseTarget(loaded, "script", expectedScript, stage);
        return new RuntimeInitialLoadedEvidence(ready[0].Sequence, scene, script);
    }

    public static void AssertWindowClose(string stdout, string stage)
    {
        var events = ParseEvents(stdout, stage);
        if (events.Any(value => value.Event == "runtime_failed"))
            throw Product(stage, "Runtime status channel published runtime_failed.");
        var stopping = events.Where(value => value.Event == "runtime_stopping").ToArray();
        if (stopping.Length != 1
            || !stopping[0].Root.TryGetProperty("reason", out var reason)
            || reason.ValueKind != JsonValueKind.String
            || reason.GetString() != "window_close")
        {
            throw Product(stage, "Runtime did not publish one runtime_stopping reason=window_close event.");
        }
    }

    private static RuntimeTargetIdentity ParseTarget(
        JsonElement loaded,
        string name,
        FileIdentity expected,
        string stage)
    {
        if (!loaded.TryGetProperty(name, out var target)
            || target.ValueKind != JsonValueKind.Object
            || !target.TryGetProperty("kind", out var kind)
            || kind.ValueKind != JsonValueKind.String
            || kind.GetString() != "artifact")
        {
            throw Product(stage, $"Runtime initialLoaded.{name} must identify an artifact.");
        }
        if (!target.TryGetProperty("sha256", out var sha256Value)
            || sha256Value.ValueKind != JsonValueKind.String
            || !target.TryGetProperty("bytes", out var bytesValue)
            || !bytesValue.TryGetUInt64(out var bytes))
        {
            throw Product(stage, $"Runtime initialLoaded.{name} is missing its artifact identity fields.");
        }
        var sha256 = sha256Value.GetString() ?? string.Empty;
        if (!LowerHex64().IsMatch(sha256)
            || sha256 != expected.Sha256
            || bytes != (ulong)expected.Length)
        {
            throw Product(stage, $"Runtime initialLoaded.{name} does not match the launched package artifact.");
        }
        return new RuntimeTargetIdentity("artifact", sha256, bytes);
    }

    private static List<StatusEvent> ParseEvents(string stdout, string stage)
    {
        var events = new List<StatusEvent>();
        ulong previousSequence = 0;
        foreach (var rawLine in stdout.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries))
        {
            JsonDocument document;
            try { document = JsonDocument.Parse(rawLine); }
            catch (JsonException exception) { throw Product(stage, $"Runtime stdout contains malformed JSONL status: {exception.Message}"); }
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object
                || !root.TryGetProperty("schemaVersion", out var schemaVersion)
                || !schemaVersion.TryGetInt32(out var schema)
                || schema != 1
                || !root.TryGetProperty("sequence", out var sequenceValue)
                || !sequenceValue.TryGetUInt64(out var sequence)
                || sequence <= previousSequence
                || !root.TryGetProperty("event", out var eventValue)
                || eventValue.ValueKind != JsonValueKind.String)
            {
                document.Dispose();
                throw Product(stage, "Runtime status events must be schema v1 with strictly increasing sequence values.");
            }
            previousSequence = sequence;
            // JsonElement.Clone 切断文档生命周期，避免每次阶段解析都保留 JsonDocument 句柄。
            events.Add(new StatusEvent(sequence, eventValue.GetString()!, root.Clone()));
            document.Dispose();
        }
        return events;
    }

    // 关键边界：协议解析必须保留调用者当前阶段，避免关闭失败伪装成 initial_loaded。
    private static VerifierFailure Product(string stage, string message) =>
        new(FailureClassification.ProductContract, stage, message);

    [GeneratedRegex("^[0-9a-f]{64}$", RegexOptions.CultureInvariant)]
    private static partial Regex LowerHex64();

    private sealed record StatusEvent(ulong Sequence, string Event, JsonElement Root);
}
