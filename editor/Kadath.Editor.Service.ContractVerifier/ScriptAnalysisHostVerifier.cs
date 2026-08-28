using System.Text;
using System.Text.Json;
using System.Threading.Channels;
using Kadath.Editor.Core;
using Kadath.Editor.Protocol;
using Kadath.Editor.Service;
using Kadath.Editor.Workspace;

namespace Kadath.Editor.Service.ContractVerifier;

internal static class ScriptAnalysisHostVerifier
{
    internal static async Task VerifyAsync()
    {
        await VerifyCleanupFailureRpcAsync().ConfigureAwait(false);
        var backend = new BlockingAnalysisBackend();
        await using var session = new EditorSession(backend);
        _ = await session.OpenProjectAsync(
            new ProjectOpenParameters("/tmp/kadath-package", "demo"),
            null).ConfigureAwait(false);

        var input = new ChannelTextReader();
        var output = new CapturingTextWriter();
        await using var preview = new PreviewProcessController(
            new WorkspacePreviewModel(new WorkspacePublicationModel()));
        var host = new EditorRpcHost(session, preview, input, output);
        var runTask = host.RunAsync();

        await output.WaitForAsync(messages => messages.Any(IsHello)).ConfigureAwait(false);
        input.Write(new EditorHelloAck(
            EditorProtocol.SchemaVersion,
            "hello_ack",
            "script-analysis-host-verifier",
            "1"));

        input.Write(Request("analysis-1", "script_source_analyze", AnalyzeParameters("return {}")));
        var first = await backend.Invocations.Reader.ReadAsync().ConfigureAwait(false);
        input.Write(Request("project-switch", "project_open", new ProjectOpenParameters("/tmp/kadath-package", "other")));
        input.Write(Request("capabilities", "get_capabilities", null));
        input.Write(Request("analysis-busy", "script_source_analyze", AnalyzeParameters("return {}")));

        await output.WaitForAsync(messages =>
            TryResponse(messages, "project-switch", out var switched) && switched.Ok
            && TryResponse(messages, "capabilities", out var capabilities) && capabilities.Ok
            && TryResponse(messages, "analysis-busy", out var busy) && !busy.Ok).ConfigureAwait(false);
        var busyResponse = output.Response("analysis-busy");
        Require(busyResponse.Error?.Code == "script_source_analysis_busy",
            "concurrent analysis was not rejected immediately as busy");
        Require(!output.HasResponse("analysis-1"),
            "the blocked analysis completed before the verifier released its Backend");
        Require(first.Project.ProjectName == "demo",
            "background analysis did not capture the Project Session at request acceptance");

        first.Complete();
        await output.WaitForAsync(messages => TryResponse(messages, "analysis-1", out var response) && response.Ok)
            .ConfigureAwait(false);
        Require(output.IndexOfResponse("capabilities") < output.IndexOfResponse("analysis-1"),
            "script_source_analyze blocked an ordinary Host request");
        Require(output.Events("analysis-1", "script_source_analysis_started").Count == 1
            && output.Events("analysis-1", "script_source_analysis_completed").Count == 1
            && output.Events("analysis-1", "script_source_analysis_failed").Count == 0,
            "successful analysis did not publish exactly one terminal event");

        input.Write(Request("analysis-cancel", "script_source_analyze", AnalyzeParameters("while true do end", "other")));
        _ = await backend.Invocations.Reader.ReadAsync().ConfigureAwait(false);
        input.Write(Request("shutdown", "shutdown", null));
        input.Complete();
        Require(await runTask.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false) == 0,
            "Host did not terminate cleanly after shutdown");

        var cancelled = output.Response("analysis-cancel");
        Require(!cancelled.Ok && cancelled.Error?.Code == "script_source_analysis_cancelled",
            "shutdown did not return the frozen analysis cancellation code");
        Require(output.IndexOfResponse("analysis-cancel") < output.IndexOfResponse("shutdown"),
            "shutdown response was written before the active analysis was cancelled and reaped");
        Require(output.Events("analysis-cancel", "script_source_analysis_started").Count == 1
            && output.Events("analysis-cancel", "script_source_analysis_failed").Count == 1
            && output.Events("analysis-cancel", "script_source_analysis_completed").Count == 0,
            "cancelled analysis did not publish exactly one failed terminal event");
        Require(backend.MaximumConcurrentAnalyses == 1,
            "Host allowed more than one analysis to enter the Backend");

        var sequences = output.Messages()
            .Where(message => message.TryGetProperty("type", out var type) && type.GetString() == "event")
            .Select(message => message.GetProperty("sequence").GetInt64())
            .ToArray();
        Require(sequences.SequenceEqual(sequences.OrderBy(value => value))
            && sequences.Distinct().Count() == sequences.Length,
            "concurrent Host writes produced duplicate or decreasing event sequences");
    }

    private static async Task VerifyCleanupFailureRpcAsync()
    {
        var mapped = WorkspaceEditorBackend.MapScriptDiagnosticsFailure(new WorkspaceScriptDiagnosticsException(
            WorkspaceScriptDiagnosticsFailureKind.Cleanup,
            "injected cleanup failure"));
        var backend = new BlockingAnalysisBackend(mapped);
        await using var session = new EditorSession(backend);
        _ = await session.OpenProjectAsync(
            new ProjectOpenParameters("/tmp/kadath-package", "demo"),
            null).ConfigureAwait(false);

        var input = new ChannelTextReader();
        var output = new CapturingTextWriter();
        await using var preview = new PreviewProcessController(
            new WorkspacePreviewModel(new WorkspacePublicationModel()));
        var host = new EditorRpcHost(session, preview, input, output);
        var runTask = host.RunAsync();
        await output.WaitForAsync(messages => messages.Any(IsHello)).ConfigureAwait(false);
        input.Write(new EditorHelloAck(
            EditorProtocol.SchemaVersion,
            "hello_ack",
            "script-analysis-cleanup-verifier",
            "1"));
        input.Write(Request("analysis-cleanup", "script_source_analyze", AnalyzeParameters("return {}")));
        await output.WaitForAsync(messages => TryResponse(messages, "analysis-cleanup", out _)).ConfigureAwait(false);
        var response = output.Response("analysis-cleanup");
        Require(!response.Ok && response.Error?.Code == "script_source_analysis_cleanup_failed",
            "cleanup failure did not retain the frozen Service RPC code");
        Require(output.Events("analysis-cleanup", "script_source_analysis_started").Count == 1
            && output.Events("analysis-cleanup", "script_source_analysis_failed").Count == 1
            && output.Events("analysis-cleanup", "script_source_analysis_completed").Count == 0,
            "cleanup failure did not publish exactly one failed terminal event");
        input.Write(Request("shutdown-cleanup", "shutdown", null));
        input.Complete();
        Require(await runTask.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false) == 0,
            "cleanup failure Host verifier did not shut down cleanly");
    }

    private static ScriptSourceAnalyzeParameters AnalyzeParameters(string source, string projectName = "demo") => new(
        projectName,
        1,
        source,
        new string(source.Length == 9 ? 'a' : 'b', 64));

    private static EditorRpcRequest Request(string id, string method, object? parameters) => new(
        EditorProtocol.SchemaVersion,
        "request",
        id,
        method,
        parameters is null ? null : JsonSerializer.SerializeToElement(parameters, EditorProtocol.JsonOptions));

    private static bool IsHello(JsonElement message) =>
        message.TryGetProperty("type", out var type) && type.GetString() == "hello";

    private static bool TryResponse(IReadOnlyList<JsonElement> messages, string id, out EditorRpcResponse response)
    {
        foreach (var message in messages)
        {
            if (!message.TryGetProperty("type", out var type) || type.GetString() != "response"
                || !message.TryGetProperty("id", out var responseId) || responseId.GetString() != id)
            {
                continue;
            }
            response = JsonSerializer.Deserialize<EditorRpcResponse>(message.GetRawText(), EditorProtocol.JsonOptions)
                ?? throw new InvalidOperationException("Host response was empty.");
            return true;
        }
        response = null!;
        return false;
    }

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private sealed class ChannelTextReader : TextReader
    {
        private readonly Channel<string> _lines = Channel.CreateUnbounded<string>();

        internal void Write<T>(T value) => _lines.Writer.TryWrite(
            JsonSerializer.Serialize(value, EditorProtocol.JsonOptions));

        internal void Complete() => _lines.Writer.TryComplete();

        public override async Task<string?> ReadLineAsync()
        {
            try { return await _lines.Reader.ReadAsync().ConfigureAwait(false); }
            catch (ChannelClosedException) { return null; }
        }
    }

    private sealed class CapturingTextWriter : TextWriter
    {
        private readonly object _gate = new();
        private readonly List<JsonElement> _messages = [];
        private TaskCompletionSource _changed = NewSignal();

        public override Encoding Encoding => Encoding.UTF8;

        public override Task WriteLineAsync(string? value)
        {
            if (value is null) return Task.CompletedTask;
            using var document = JsonDocument.Parse(value);
            TaskCompletionSource changed;
            lock (_gate)
            {
                _messages.Add(document.RootElement.Clone());
                changed = _changed;
                _changed = NewSignal();
            }
            changed.TrySetResult();
            return Task.CompletedTask;
        }

        internal async Task WaitForAsync(Func<IReadOnlyList<JsonElement>, bool> predicate)
        {
            var deadline = DateTimeOffset.UtcNow + TimeSpan.FromSeconds(5);
            while (true)
            {
                Task changed;
                lock (_gate)
                {
                    if (predicate(_messages)) return;
                    changed = _changed.Task;
                }
                var remaining = deadline - DateTimeOffset.UtcNow;
                if (remaining <= TimeSpan.Zero) throw new TimeoutException("Host verifier timed out.");
                await changed.WaitAsync(remaining).ConfigureAwait(false);
            }
        }

        internal IReadOnlyList<JsonElement> Messages()
        {
            lock (_gate) return _messages.ToArray();
        }

        internal bool HasResponse(string id) => Messages().Any(message => IsResponse(message, id));

        internal EditorRpcResponse Response(string id)
        {
            var message = Messages().Single(value => IsResponse(value, id));
            return JsonSerializer.Deserialize<EditorRpcResponse>(message.GetRawText(), EditorProtocol.JsonOptions)
                ?? throw new InvalidOperationException($"Response {id} was empty.");
        }

        internal int IndexOfResponse(string id)
        {
            var messages = Messages();
            for (var index = 0; index < messages.Count; index++)
            {
                if (IsResponse(messages[index], id)) return index;
            }
            throw new InvalidOperationException($"Response {id} was not observed.");
        }

        internal IReadOnlyList<JsonElement> Events(string requestId, string eventName) => Messages()
            .Where(message => message.TryGetProperty("type", out var type) && type.GetString() == "event"
                && message.TryGetProperty("requestId", out var observedRequestId) && observedRequestId.GetString() == requestId
                && message.TryGetProperty("event", out var observedEvent) && observedEvent.GetString() == eventName)
            .ToArray();

        private static bool IsResponse(JsonElement message, string id) =>
            message.TryGetProperty("type", out var type) && type.GetString() == "response"
            && message.TryGetProperty("id", out var responseId) && responseId.GetString() == id;

        private static TaskCompletionSource NewSignal() =>
            new(TaskCreationOptions.RunContinuationsAsynchronously);
    }

    private sealed class BlockingAnalysisBackend : IEditorSessionBackend
    {
        private readonly EditorOperationException? _analysisFailure;
        private int _activeAnalyses;
        private int _maximumConcurrentAnalyses;

        internal BlockingAnalysisBackend(EditorOperationException? analysisFailure = null) =>
            _analysisFailure = analysisFailure;

        internal Channel<AnalysisInvocation> Invocations { get; } = Channel.CreateUnbounded<AnalysisInvocation>();
        internal int MaximumConcurrentAnalyses => Volatile.Read(ref _maximumConcurrentAnalyses);
        public event Func<EditorSessionNotification, Task>? Notification
        {
            add { }
            remove { }
        }

        public Task<ProjectSessionInfo> OpenProjectAsync(ProjectOpenParameters parameters, CancellationToken cancellationToken) =>
            Task.FromResult(new ProjectSessionInfo(
                parameters.PackageRoot,
                parameters.ProjectName,
                $"/tmp/kadath-package/bin/projects/{parameters.ProjectName}",
                $"/tmp/kadath-package/bin/projects/{parameters.ProjectName}/scene.json",
                $"/tmp/kadath-package/bin/projects/{parameters.ProjectName}/script.json",
                $"/tmp/kadath-package/bin/projects/{parameters.ProjectName}/preview.json",
                1));

        public async Task<ScriptSourceAnalysisResult> AnalyzeScriptSourceAsync(
            ProjectSessionInfo project,
            ScriptSourceAnalyzeParameters parameters,
            CancellationToken cancellationToken)
        {
            if (_analysisFailure is not null) throw _analysisFailure;
            var active = Interlocked.Increment(ref _activeAnalyses);
            UpdateMaximum(active);
            var invocation = new AnalysisInvocation(project);
            await Invocations.Writer.WriteAsync(invocation, cancellationToken).ConfigureAwait(false);
            try
            {
                await invocation.Completion.Task.WaitAsync(cancellationToken).ConfigureAwait(false);
                return new ScriptSourceAnalysisResult(
                    "valid",
                    project.ProjectName,
                    parameters.ScriptId,
                    "scripts/patrol.luau",
                    parameters.SourceHash,
                    new string('1', 64),
                    "luau-0.732-decb2d0",
                    []);
            }
            finally { Interlocked.Decrement(ref _activeAnalyses); }
        }

        private void UpdateMaximum(int active)
        {
            while (true)
            {
                var observed = Volatile.Read(ref _maximumConcurrentAnalyses);
                if (observed >= active || Interlocked.CompareExchange(ref _maximumConcurrentAnalyses, active, observed) == observed)
                    return;
            }
        }

        public Task<ProjectSessionInfo> CreateProjectAsync(ProjectCreateParameters parameters, CancellationToken cancellationToken) => throw Unsupported();
        public Task<ProjectValidateResult> ValidateProjectAsync(ProjectSessionInfo project, CancellationToken cancellationToken) => throw Unsupported();
        public Task<ProjectModelSnapshot> GetProjectSnapshotAsync(ProjectSessionInfo project, CancellationToken cancellationToken) => throw Unsupported();
        public Task<HierarchySnapshot> GetHierarchySnapshotAsync(ProjectSessionInfo project, CancellationToken cancellationToken) => throw Unsupported();
        public Task<AssetCatalogSnapshot> GetAssetCatalogSnapshotAsync(ProjectSessionInfo project, CancellationToken cancellationToken) => throw Unsupported();
        public Task<ScriptSourceDocument> GetScriptSourceAsync(ProjectSessionInfo project, ScriptSourceQueryParameters parameters, CancellationToken cancellationToken) => throw Unsupported();
        public Task<BehaviorContractSnapshotResult> GetBehaviorContractSnapshotAsync(ProjectSessionInfo project, BehaviorContractSnapshotParameters parameters, CancellationToken cancellationToken) => throw Unsupported();
        public Task<PublicationSnapshot> GetPublicationSnapshotAsync(ProjectSessionInfo project, PublicationSnapshotQueryParameters parameters, CancellationToken cancellationToken) => throw Unsupported();
        public Task<TextureImportResult> ImportTextureAsync(ProjectSessionInfo project, TextureImportParameters parameters, CancellationToken cancellationToken) => throw Unsupported();
        public Task<TilemapImportResult> ImportTilemapAsync(ProjectSessionInfo project, TilemapImportParameters parameters, CancellationToken cancellationToken) => throw Unsupported();
        public Task<AuthoringMutationResult> ApplyAuthoringAsync(ProjectSessionInfo project, AuthoringApplyParameters parameters, CancellationToken cancellationToken) => throw Unsupported();
        public Task<AuthoringMutationResult> UndoAuthoringAsync(ProjectSessionInfo project, AuthoringUndoParameters parameters, CancellationToken cancellationToken) => throw Unsupported();
        public Task<AuthoringMutationResult> RedoAuthoringAsync(ProjectSessionInfo project, AuthoringRedoParameters parameters, CancellationToken cancellationToken) => throw Unsupported();
        public Task<ScriptSourceMutationResult> EditScriptSourceAsync(ProjectSessionInfo project, ScriptSourceEditParameters parameters, CancellationToken cancellationToken) => throw Unsupported();
        public Task<ScriptSourceMutationResult> UndoScriptSourceAsync(ProjectSessionInfo project, ScriptSourceUndoParameters parameters, CancellationToken cancellationToken) => throw Unsupported();
        public Task<ScriptAssetMutationResult> CreateScriptAssetAsync(ProjectSessionInfo project, ScriptAssetCreateParameters parameters, CancellationToken cancellationToken) => throw Unsupported();
        public Task<ScriptAssetMutationResult> RenameScriptAssetAsync(ProjectSessionInfo project, ScriptAssetRenameParameters parameters, CancellationToken cancellationToken) => throw Unsupported();
        public Task<ScriptAssetMutationResult> DeleteScriptAssetAsync(ProjectSessionInfo project, ScriptAssetDeleteParameters parameters, CancellationToken cancellationToken) => throw Unsupported();
        public Task<ScriptAssetMutationResult> UndoScriptAssetAsync(ProjectSessionInfo project, ScriptAssetUndoParameters parameters, CancellationToken cancellationToken) => throw Unsupported();
        public Task<EditorBakeResult> BakeAsync(ProjectSessionInfo project, BakeStartParameters parameters, CancellationToken cancellationToken) => throw Unsupported();
        public Task<EditorWatchResult> StartWatchAsync(ProjectSessionInfo project, WatchStartParameters parameters, CancellationToken cancellationToken) => throw Unsupported();
        public Task<EditorWatchResult> StopWatchAsync(CancellationToken cancellationToken) =>
            Task.FromResult(new EditorWatchResult("stopped", "demo", "Both", "debug", null));

        public ValueTask DisposeAsync()
        {
            Invocations.Writer.TryComplete();
            return ValueTask.CompletedTask;
        }

        private static NotSupportedException Unsupported() => new("This Host verifier operation is not used.");
    }

    internal sealed class AnalysisInvocation
    {
        internal AnalysisInvocation(ProjectSessionInfo project) => Project = project;
        internal ProjectSessionInfo Project { get; }
        internal TaskCompletionSource Completion { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal void Complete() => Completion.TrySetResult();
    }
}
