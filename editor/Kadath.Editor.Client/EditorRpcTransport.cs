using System.Diagnostics;

namespace Kadath.Editor.Client;

/// <summary>
/// JSONL transport 的最小 seam。UI 和协议状态机不依赖具体的进程、管道或测试实现。
/// </summary>
public interface IEditorRpcTransport : IAsyncDisposable
{
    bool IsOpen { get; }
    Task StartAsync(CancellationToken cancellationToken = default);
    Task SendLineAsync(string line, CancellationToken cancellationToken = default);
    Task<string?> ReadLineAsync(CancellationToken cancellationToken = default);
}

public sealed record EditorRpcProcessOptions(
    string FileName,
    IReadOnlyList<string> Arguments,
    string? WorkingDirectory = null);

/// <summary>
/// Editor Service 的 stdio 适配器。stderr 只做排空，控制协议永远只从 stdout 读取。
/// </summary>
public sealed class StdioEditorRpcTransport : IEditorRpcTransport
{
    private readonly EditorRpcProcessOptions _options;
    private readonly SemaphoreSlim _writeGate = new(1, 1);
    private readonly CancellationTokenSource _lifetime = new();
    private Process? _process;
    private Task? _stderrDrain;
    private int _disposed;

    public StdioEditorRpcTransport(EditorRpcProcessOptions options) => _options = options;

    public bool IsOpen => _process is { HasExited: false };

    public Task StartAsync(CancellationToken cancellationToken = default)
    {
        if (_process is not null) { throw new InvalidOperationException("The JSONL transport has already started."); }

        var startInfo = new ProcessStartInfo
        {
            FileName = _options.FileName,
            WorkingDirectory = _options.WorkingDirectory,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        foreach (var argument in _options.Arguments) { startInfo.ArgumentList.Add(argument); }

        var process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
        if (!process.Start()) { throw new InvalidOperationException("Failed to start the Editor Service process."); }
        _process = process;
        // 不消费 stderr 会让子进程在缓冲区写满后停住，因此始终异步排空。
        _stderrDrain = DrainStderrAsync(process.StandardError, _lifetime.Token);
        return Task.CompletedTask;
    }

    public async Task SendLineAsync(string line, CancellationToken cancellationToken = default)
    {
        var process = _process ?? throw new InvalidOperationException("The JSONL transport has not started.");
        if (process.HasExited) { throw new EndOfStreamException("The Editor Service process has exited."); }
        await _writeGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await process.StandardInput.WriteLineAsync(line).ConfigureAwait(false);
            await process.StandardInput.FlushAsync(cancellationToken).ConfigureAwait(false);
        }
        finally { _writeGate.Release(); }
    }

    public async Task<string?> ReadLineAsync(CancellationToken cancellationToken = default)
    {
        var process = _process ?? throw new InvalidOperationException("The JSONL transport has not started.");
        return await process.StandardOutput.ReadLineAsync(cancellationToken).ConfigureAwait(false);
    }

    private static async Task DrainStderrAsync(StreamReader reader, CancellationToken cancellationToken)
    {
        try
        {
            while (await reader.ReadLineAsync(cancellationToken).ConfigureAwait(false) is not null) { }
        }
        catch (OperationCanceledException) { }
        catch (ObjectDisposedException) { }
    }

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0) { return; }
        _lifetime.Cancel();
        var process = _process;
        if (process is not null)
        {
            try
            {
                if (!process.HasExited) { process.Kill(entireProcessTree: true); }
                await process.WaitForExitAsync().ConfigureAwait(false);
            }
            catch (InvalidOperationException) { }
            catch (System.ComponentModel.Win32Exception) { }
            process.Dispose();
            _process = null;
        }
        if (_stderrDrain is not null)
        {
            try { await _stderrDrain.ConfigureAwait(false); }
            catch (OperationCanceledException) { }
        }
        _writeGate.Dispose();
        _lifetime.Dispose();
    }
}
