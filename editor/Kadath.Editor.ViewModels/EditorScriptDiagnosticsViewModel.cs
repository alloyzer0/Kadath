using System.Buffers;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Channels;
using Kadath.Editor.Client;
using Kadath.Editor.Protocol;

namespace Kadath.Editor.ViewModels;

public enum EditorScriptDiagnosticsState
{
    Unsupported,
    Idle,
    Debouncing,
    Analyzing,
    Valid,
    Invalid,
    Failed
}

public sealed record EditorScriptDiagnosticItem(
    ScriptSourceDiagnostic Diagnostic,
    string DisplayText,
    int? CaretIndex);

public sealed class EditorScriptDiagnosticsViewModel : ObservableObject, IAsyncDisposable
{
    private const int MaxSourceBytes = 64 * 1024;
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    private readonly IEditorRpcClient _client;
    private readonly IEditorViewDispatcher _dispatcher;
    private readonly TimeSpan _debounce;
    private readonly CancellationTokenSource _lifetime = new();
    private readonly Channel<AnalysisRequest> _requests = Channel.CreateBounded<AnalysisRequest>(new BoundedChannelOptions(1)
    {
        SingleReader = true,
        SingleWriter = false,
        FullMode = BoundedChannelFullMode.DropOldest
    });
    private readonly object _stateGate = new();
    private readonly Task _worker;
    private EditorScriptDiagnosticsState _state = EditorScriptDiagnosticsState.Unsupported;
    private ScriptSourceAnalysisResult? _result;
    private IReadOnlyList<EditorScriptDiagnosticItem> _items = Array.Empty<EditorScriptDiagnosticItem>();
    private string? _errorCode;
    private string? _errorMessage;
    private BufferSnapshot? _current;
    private bool _supported;
    private long _generation;
    private int _disposed;

    public EditorScriptDiagnosticsViewModel(
        IEditorRpcClient client,
        IEditorViewDispatcher dispatcher,
        TimeSpan? debounce = null)
    {
        _client = client ?? throw new ArgumentNullException(nameof(client));
        _dispatcher = dispatcher ?? throw new ArgumentNullException(nameof(dispatcher));
        _debounce = debounce ?? TimeSpan.FromMilliseconds(400);
        _worker = Task.Run(() => WorkerAsync(_lifetime.Token), CancellationToken.None);
    }

    public EditorScriptDiagnosticsState State { get => _state; private set => SetProperty(ref _state, value); }
    public ScriptSourceAnalysisResult? Result { get => _result; private set => SetProperty(ref _result, value); }
    public IReadOnlyList<EditorScriptDiagnosticItem> Items { get => _items; private set => SetProperty(ref _items, value); }
    public string? ErrorCode { get => _errorCode; private set => SetProperty(ref _errorCode, value); }
    public string? ErrorMessage { get => _errorMessage; private set => SetProperty(ref _errorMessage, value); }
    public bool IsSupported => _supported;
    public bool CanReanalyze => _supported && CurrentSnapshot() is not null;

    internal void SetSupported(bool supported)
    {
        lock (_stateGate) { _supported = supported; }
        RaisePropertyChanged(nameof(IsSupported));
        RaisePropertyChanged(nameof(CanReanalyze));
        if (!supported) Reset(unsupported: true);
        else if (CurrentSnapshot() is null) Reset(unsupported: false);
    }

    public void Observe(
        string? projectName,
        uint? scriptId,
        string? sourcePath,
        string? source,
        bool eligible)
    {
        ObjectDisposedException.ThrowIf(_disposed != 0, this);
        if (!IsSupported || !eligible || string.IsNullOrEmpty(projectName) || scriptId is null or 0
            || string.IsNullOrEmpty(sourcePath) || source is null)
        {
            Reset(unsupported: !IsSupported);
            return;
        }

        BufferSnapshot snapshot;
        try { snapshot = CreateSnapshot(projectName, scriptId.Value, sourcePath, source); }
        catch (EncoderFallbackException)
        {
            ApplyLocalFailure("invalid_script_source_analysis_request", "源码包含无法编码为严格 UTF-8 的字符。");
            return;
        }
        catch (ArgumentOutOfRangeException exception)
        {
            ApplyLocalFailure("invalid_script_source_analysis_request", exception.Message);
            return;
        }

        long generation;
        lock (_stateGate)
        {
            if (_current is not null && SameIdentity(_current, snapshot)) return;
            generation = ++_generation;
            _current = snapshot with { Generation = generation };
            snapshot = _current;
        }
        _ = PublishIfCurrentAsync(snapshot, () =>
        {
            Result = null;
            Items = Array.Empty<EditorScriptDiagnosticItem>();
            ErrorCode = null;
            ErrorMessage = null;
            State = EditorScriptDiagnosticsState.Debouncing;
            RaisePropertyChanged(nameof(CanReanalyze));
        });
        _requests.Writer.TryWrite(new AnalysisRequest(snapshot, Force: false));
    }

    public void Reanalyze()
    {
        ObjectDisposedException.ThrowIf(_disposed != 0, this);
        var current = CurrentSnapshot();
        if (!IsSupported || current is null) return;
        _ = PublishIfCurrentAsync(current, () =>
        {
            ErrorCode = null;
            ErrorMessage = null;
            State = EditorScriptDiagnosticsState.Debouncing;
        });
        _requests.Writer.TryWrite(new AnalysisRequest(current with { ObservedAt = DateTimeOffset.UtcNow }, Force: true));
    }

    public void Reset(bool unsupported = false)
    {
        long generation;
        lock (_stateGate)
        {
            generation = ++_generation;
            _current = null;
        }
        _requests.Writer.TryWrite(new AnalysisRequest(null, Force: true));
        _ = PublishIfResetCurrentAsync(generation, () =>
        {
            Result = null;
            Items = Array.Empty<EditorScriptDiagnosticItem>();
            ErrorCode = null;
            ErrorMessage = null;
            State = unsupported ? EditorScriptDiagnosticsState.Unsupported : EditorScriptDiagnosticsState.Idle;
            RaisePropertyChanged(nameof(CanReanalyze));
        });
    }

    private void ApplyLocalFailure(string code, string message)
    {
        long generation;
        lock (_stateGate)
        {
            generation = ++_generation;
            _current = null;
        }
        _requests.Writer.TryWrite(new AnalysisRequest(null, Force: true));
        _ = PublishIfResetCurrentAsync(generation, () =>
        {
            Result = null;
            Items = Array.Empty<EditorScriptDiagnosticItem>();
            ErrorCode = code;
            ErrorMessage = message;
            State = EditorScriptDiagnosticsState.Failed;
            RaisePropertyChanged(nameof(CanReanalyze));
        });
    }

    private async Task WorkerAsync(CancellationToken cancellationToken)
    {
        try
        {
            while (await _requests.Reader.WaitToReadAsync(cancellationToken).ConfigureAwait(false))
            {
                var request = ReadLatest();
                if (request.Snapshot is null) continue;
                request = await DebounceLatestAsync(request, cancellationToken).ConfigureAwait(false);
                if (request.Snapshot is null || !IsCurrent(request.Snapshot)) continue;
                await AnalyzeAsync(request.Snapshot, cancellationToken).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { }
    }

    private AnalysisRequest ReadLatest()
    {
        if (!_requests.Reader.TryRead(out var latest)) return default;
        while (_requests.Reader.TryRead(out var next)) latest = next;
        return latest;
    }

    private async Task<AnalysisRequest> DebounceLatestAsync(AnalysisRequest request, CancellationToken cancellationToken)
    {
        while (request.Snapshot is not null && !request.Force)
        {
            var remaining = request.Snapshot.ObservedAt + _debounce - DateTimeOffset.UtcNow;
            if (remaining <= TimeSpan.Zero) return request;
            var delay = Task.Delay(remaining, cancellationToken);
            using var waitCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            var available = _requests.Reader.WaitToReadAsync(waitCancellation.Token).AsTask();
            var completed = await Task.WhenAny(delay, available).ConfigureAwait(false);
            if (completed == delay)
            {
                waitCancellation.Cancel();
                try { await available.ConfigureAwait(false); }
                catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested) { }
                return request;
            }
            if (!await available.ConfigureAwait(false)) return request;
            request = ReadLatest();
        }
        return request;
    }

    private async Task AnalyzeAsync(BufferSnapshot snapshot, CancellationToken cancellationToken)
    {
        await PublishIfCurrentAsync(snapshot, () =>
        {
            ErrorCode = null;
            ErrorMessage = null;
            State = EditorScriptDiagnosticsState.Analyzing;
        }).ConfigureAwait(false);
        try
        {
            var result = await _client.AnalyzeScriptSourceAsync(new ScriptSourceAnalyzeParameters(
                snapshot.ProjectName,
                snapshot.ScriptId,
                snapshot.Source,
                snapshot.SourceHash), cancellationToken).ConfigureAwait(false);
            if (!Matches(snapshot, result)) return;
            var items = CreateItems(snapshot.Source, result.Diagnostics);
            await PublishIfCurrentAsync(snapshot, () =>
            {
                Result = result;
                Items = items;
                ErrorCode = null;
                ErrorMessage = null;
                State = result.State == "valid" ? EditorScriptDiagnosticsState.Valid : EditorScriptDiagnosticsState.Invalid;
            }).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { }
        catch (Exception exception)
        {
            var (code, message) = exception switch
            {
                EditorRpcException rpc => (rpc.Code, rpc.Message),
                _ => ("script_source_analysis_failed", exception.Message)
            };
            await PublishIfCurrentAsync(snapshot, () =>
            {
                ErrorCode = code;
                ErrorMessage = message;
                State = EditorScriptDiagnosticsState.Failed;
            }).ConfigureAwait(false);
        }
    }

    private async Task PublishIfCurrentAsync(BufferSnapshot snapshot, Action action)
    {
        if (!IsCurrent(snapshot)) return;
        await PublishAsync(() =>
        {
            if (IsCurrent(snapshot)) action();
        }).ConfigureAwait(false);
    }

    private async Task PublishIfResetCurrentAsync(long generation, Action action)
    {
        if (!IsResetCurrent(generation)) return;
        await PublishAsync(() =>
        {
            if (IsResetCurrent(generation)) action();
        }).ConfigureAwait(false);
    }

    private Task PublishAsync(Action action) => _dispatcher.InvokeAsync(action);

    private BufferSnapshot? CurrentSnapshot()
    {
        lock (_stateGate) { return _current; }
    }

    private bool IsCurrent(BufferSnapshot snapshot)
    {
        lock (_stateGate)
        {
            return _current is not null
                && _current.Generation == snapshot.Generation
                && SameIdentity(_current, snapshot);
        }
    }

    private bool IsResetCurrent(long generation)
    {
        lock (_stateGate) { return _generation == generation && _current is null; }
    }

    private static BufferSnapshot CreateSnapshot(string projectName, uint scriptId, string sourcePath, string source)
    {
        var sourceBytes = StrictUtf8.GetBytes(source);
        if (sourceBytes.Length > MaxSourceBytes)
            throw new ArgumentOutOfRangeException(nameof(source), "源码超过 64 KiB，不能执行即时诊断。");
        return new BufferSnapshot(
            projectName,
            scriptId,
            sourcePath,
            source,
            Convert.ToHexString(SHA256.HashData(sourceBytes)).ToLowerInvariant(),
            Generation: 0,
            DateTimeOffset.UtcNow);
    }

    private static bool SameIdentity(BufferSnapshot left, BufferSnapshot right) =>
        left.ProjectName.Equals(right.ProjectName, StringComparison.Ordinal)
        && left.ScriptId == right.ScriptId
        && left.SourcePath.Equals(right.SourcePath, StringComparison.Ordinal)
        && left.SourceHash.Equals(right.SourceHash, StringComparison.Ordinal);

    private static bool Matches(BufferSnapshot snapshot, ScriptSourceAnalysisResult result) =>
        result.State is "valid" or "invalid"
        && snapshot.ProjectName.Equals(result.ProjectName, StringComparison.Ordinal)
        && snapshot.ScriptId == result.ScriptId
        && snapshot.SourcePath.Equals(result.SourcePath, StringComparison.Ordinal)
        && snapshot.SourceHash.Equals(result.SourceHash, StringComparison.Ordinal)
        && result.Diagnostics.All(value => snapshot.SourcePath.Equals(value.SourcePath, StringComparison.Ordinal))
        && ((result.State == "valid") == (result.Diagnostics.Length == 0));

    private static IReadOnlyList<EditorScriptDiagnosticItem> CreateItems(
        string source,
        IReadOnlyList<ScriptSourceDiagnostic> diagnostics) => diagnostics
        .Select(value => new EditorScriptDiagnosticItem(
            value,
            FormatDiagnostic(value),
            value.Range is null ? null : ToUtf16Index(source, value.Range.Start)))
        .ToArray();

    private static string FormatDiagnostic(ScriptSourceDiagnostic diagnostic)
    {
        var stage = diagnostic.Stage switch
        {
            "analysis" => "分析",
            "compile" => "编译",
            "tooling_execution" => "工具执行",
            "behavior_contract" => "行为契约",
            _ => diagnostic.Stage
        };
        return diagnostic.Range is { } range
            ? $"{range.Start.Line}:{range.Start.Column} · {stage} · {diagnostic.Message}"
            : $"{stage} · {diagnostic.Message}";
    }

    public static int ToUtf16Index(string source, ScriptSourcePosition position)
    {
        if (position.Line < 1 || position.Column < 1) throw new ArgumentOutOfRangeException(nameof(position));
        var line = 1;
        var column = 1;
        var index = 0;
        while (true)
        {
            if (line == position.Line && column == position.Column) return index;
            if (index == source.Length) break;
            var status = Rune.DecodeFromUtf16(source.AsSpan(index), out var rune, out var consumed);
            if (status != OperationStatus.Done) throw new ArgumentException("Source is not valid UTF-16.", nameof(source));
            index += consumed;
            if (rune.Value == '\n')
            {
                line += 1;
                column = 1;
            }
            else column += 1;
        }
        throw new ArgumentOutOfRangeException(nameof(position), "Diagnostic position is outside the source buffer.");
    }

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
        _requests.Writer.TryComplete();
        _lifetime.Cancel();
        try { await _worker.ConfigureAwait(false); }
        catch (OperationCanceledException) { }
        _lifetime.Dispose();
    }

    private sealed record BufferSnapshot(
        string ProjectName,
        uint ScriptId,
        string SourcePath,
        string Source,
        string SourceHash,
        long Generation,
        DateTimeOffset ObservedAt);

    private readonly record struct AnalysisRequest(BufferSnapshot? Snapshot, bool Force);
}
