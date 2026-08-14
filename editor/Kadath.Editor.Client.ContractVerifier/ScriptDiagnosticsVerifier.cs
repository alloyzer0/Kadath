using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Kadath.Editor.Client;
using Kadath.Editor.Protocol;
using Kadath.Editor.ViewModels;

namespace Kadath.Editor.Client.ContractVerifier;

internal static class ScriptDiagnosticsVerifier
{
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);

    internal static async Task VerifyAsync()
    {
        await VerifyCapabilityFallbackAsync().ConfigureAwait(false);

        var transport = new ScriptedTransport();
        var client = new EditorRpcClient(transport, "script-diagnostics-verifier", "1");
        await using var workspace = new EditorWorkspaceViewModel(client);
        await workspace.ConnectAsync().ConfigureAwait(false);
        Require(workspace.Capabilities.CanAnalyzeScriptSource, "script_source_analyze capability was not projected");

        var document = new ScriptSourceDocument(
            "demo",
            1,
            "scripts/patrol.luau",
            "return {}",
            new string('1', 64));

        string latestRapidSource = string.Empty;
        for (var index = 0; index < 100; index++)
        {
            latestRapidSource = $"return {{ value = {index} }}";
            workspace.ObserveScriptSourceBuffer(document, latestRapidSource);
        }
        var latestRapidHash = Hash(latestRapidSource);
        await WaitUntilAsync(() => workspace.ScriptDiagnostics is
        {
            State: EditorScriptDiagnosticsState.Valid,
            Result.SourceHash: var sourceHash
        } && sourceHash == latestRapidHash).ConfigureAwait(false);
        Require(transport.ScriptAnalyzeRequestCount == 1,
            $"100 rapid observations produced {transport.ScriptAnalyzeRequestCount} analyze requests instead of one");
        VerifyWireShape(transport.LastScriptAnalyzeRequest, latestRapidSource, latestRapidHash);

        workspace.ObserveScriptSourceBuffer(document, latestRapidSource);
        await Task.Delay(500).ConfigureAwait(false);
        Require(transport.ScriptAnalyzeRequestCount == 1, "unchanged buffer was analyzed automatically twice");

        workspace.ReanalyzeScriptSource();
        await WaitUntilAsync(() => transport.ScriptAnalyzeRequestCount == 2
            && workspace.ScriptDiagnostics.State == EditorScriptDiagnosticsState.Valid).ConfigureAwait(false);

        transport.DelayNextOperationResponse("script_source_analyze");
        const string staleSource = "-- invalid stale\nreturn {}";
        workspace.ObserveScriptSourceBuffer(document, staleSource);
        await WaitUntilAsync(() => transport.DelayedOperationPending
            && transport.ScriptAnalyzeRequestCount == 3
            && workspace.ScriptDiagnostics.State == EditorScriptDiagnosticsState.Analyzing).ConfigureAwait(false);

        string latestPendingSource = string.Empty;
        for (var index = 0; index < 100; index++)
        {
            latestPendingSource = $"-- invalid latest {index}\nreturn {{}}";
            workspace.ObserveScriptSourceBuffer(document, latestPendingSource);
        }
        Require(transport.ScriptAnalyzeRequestCount == 3, "pending-latest buffer started a concurrent RPC");
        await transport.ReleaseDelayedOperationAsync().ConfigureAwait(false);

        var latestPendingHash = Hash(latestPendingSource);
        await WaitUntilAsync(() => workspace.ScriptDiagnostics is
        {
            State: EditorScriptDiagnosticsState.Invalid,
            Result.SourceHash: var sourceHash,
            Items.Count: 1
        } && sourceHash == latestPendingHash).ConfigureAwait(false);
        Require(transport.ScriptAnalyzeRequestCount == 4,
            "in-flight replacement did not collapse to exactly one pending-latest request");
        Require(workspace.ScriptDiagnostics.Result?.SourceHash != Hash(staleSource),
            "stale in-flight result was projected onto the latest buffer");

        var retainedResult = workspace.ScriptDiagnostics.Result
            ?? throw new InvalidOperationException("matching invalid result was not retained");
        var retainedItem = workspace.ScriptDiagnostics.Items.Single();
        transport.FailNextRequest(
            "script_source_analyze",
            "script_source_analysis_timeout",
            "injected analyzer timeout");
        workspace.ReanalyzeScriptSource();
        await WaitUntilAsync(() => workspace.ScriptDiagnostics.State == EditorScriptDiagnosticsState.Failed).ConfigureAwait(false);
        Require(workspace.ScriptDiagnostics.ErrorCode == "script_source_analysis_timeout"
            && ReferenceEquals(workspace.ScriptDiagnostics.Result, retainedResult)
            && workspace.ScriptDiagnostics.Items.Single() == retainedItem,
            "analyzer failure did not preserve the latest matching successful diagnostics");

        var requestCountBeforeLocalFailure = transport.ScriptAnalyzeRequestCount;
        workspace.ObserveScriptSourceBuffer(document, "\ud800");
        await WaitUntilAsync(() => workspace.ScriptDiagnostics.State == EditorScriptDiagnosticsState.Failed
            && workspace.ScriptDiagnostics.ErrorCode == "invalid_script_source_analysis_request").ConfigureAwait(false);
        Require(transport.ScriptAnalyzeRequestCount == requestCountBeforeLocalFailure
            && workspace.ScriptDiagnostics.Result is null
            && workspace.ScriptDiagnostics.Items.Count == 0,
            "invalid UTF-16 crossed the RPC seam or retained diagnostics for a different buffer identity");

        VerifyUnicodeCaretMapping();
    }

    private static async Task VerifyCapabilityFallbackAsync()
    {
        var transport = new ScriptedTransport(advertiseScriptAnalysis: false);
        var client = new EditorRpcClient(transport, "script-diagnostics-capability-verifier", "1");
        await using var workspace = new EditorWorkspaceViewModel(client);
        await workspace.ConnectAsync().ConfigureAwait(false);
        Require(!workspace.Capabilities.CanAnalyzeScriptSource
            && workspace.ScriptDiagnostics.State == EditorScriptDiagnosticsState.Unsupported,
            "missing script_source_analyze capability did not preserve the unsupported fallback");
        workspace.ObserveScriptSourceBuffer(new ScriptSourceDocument(
            "demo", 1, "scripts/patrol.luau", "return {}", new string('1', 64)), "return {}");
        await Task.Delay(450).ConfigureAwait(false);
        Require(transport.ScriptAnalyzeRequestCount == 0,
            "unsupported Service received a script_source_analyze request");
    }

    private static void VerifyWireShape(JsonElement? request, string source, string sourceHash)
    {
        var root = request ?? throw new InvalidOperationException("typed analyze request was not observed");
        Require(root.GetProperty("method").GetString() == "script_source_analyze",
            "typed analyze Client used the wrong RPC method");
        var parameters = root.GetProperty("params");
        var names = parameters.EnumerateObject()
            .Select(property => property.Name)
            .OrderBy(value => value, StringComparer.Ordinal)
            .ToArray();
        Require(names.SequenceEqual(["projectName", "scriptId", "source", "sourceHash"]),
            $"script_source_analyze params mismatch: {string.Join(',', names)}");
        Require(parameters.GetProperty("projectName").GetString() == "demo"
            && parameters.GetProperty("scriptId").GetUInt32() == 1
            && parameters.GetProperty("source").GetString() == source
            && parameters.GetProperty("sourceHash").GetString() == sourceHash,
            "typed analyze Client did not preserve Buffer Identity");
    }

    private static void VerifyUnicodeCaretMapping()
    {
        const string source = "a界😀b\r\nx";
        Require(EditorScriptDiagnosticsViewModel.ToUtf16Index(source, new ScriptSourcePosition(1, 1)) == 0,
            "line 1 column 1 UTF-16 mapping mismatch");
        Require(EditorScriptDiagnosticsViewModel.ToUtf16Index(source, new ScriptSourcePosition(1, 2)) == 1,
            "BMP scalar start mapping mismatch");
        Require(EditorScriptDiagnosticsViewModel.ToUtf16Index(source, new ScriptSourcePosition(1, 3)) == 2,
            "supplementary scalar start mapping mismatch");
        Require(EditorScriptDiagnosticsViewModel.ToUtf16Index(source, new ScriptSourcePosition(1, 4)) == 4,
            "supplementary scalar end mapping mismatch");
        Require(EditorScriptDiagnosticsViewModel.ToUtf16Index(source, new ScriptSourcePosition(1, 6)) == 6,
            "CRLF LF boundary mapping mismatch");
        Require(EditorScriptDiagnosticsViewModel.ToUtf16Index(source, new ScriptSourcePosition(2, 1)) == 7,
            "line 2 start mapping mismatch");
    }

    private static string Hash(string source) =>
        Convert.ToHexString(SHA256.HashData(StrictUtf8.GetBytes(source))).ToLowerInvariant();

    private static async Task WaitUntilAsync(Func<bool> predicate)
    {
        var deadline = DateTimeOffset.UtcNow + TimeSpan.FromSeconds(8);
        while (!predicate())
        {
            if (DateTimeOffset.UtcNow >= deadline) throw new TimeoutException("Script diagnostics verifier timed out.");
            await Task.Delay(20).ConfigureAwait(false);
        }
    }

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
