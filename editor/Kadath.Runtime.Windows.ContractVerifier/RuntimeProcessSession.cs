using System.Diagnostics;
using System.Text;

namespace Kadath.Runtime.Windows.ContractVerifier;

internal sealed class RuntimeProcessSession : IAsyncDisposable
{
    private readonly object _stdoutGate = new();
    private readonly object _stderrGate = new();
    private readonly StringBuilder _stdout = new();
    private readonly StringBuilder _stderr = new();

    private RuntimeProcessSession(Process process) => Process = process;

    public Process Process { get; }
    public bool ForcedTreeKill { get; private set; }
    public int Id => Process.Id;
    public bool HasExited
    {
        get
        {
            try { return Process.HasExited; }
            catch (InvalidOperationException) { return true; }
        }
    }

    public int? ExitCode => HasExited ? Process.ExitCode : null;

    public static RuntimeProcessSession Start(string executable, string workingDirectory, IReadOnlyList<string> arguments)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = executable,
            WorkingDirectory = workingDirectory,
            UseShellExecute = false,
            CreateNoWindow = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = new UTF8Encoding(false, true),
            StandardErrorEncoding = new UTF8Encoding(false, true)
        };
        foreach (var argument in arguments) startInfo.ArgumentList.Add(argument);

        var process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
        var session = new RuntimeProcessSession(process);
        process.OutputDataReceived += (_, eventArgs) => session.Append(session._stdoutGate, session._stdout, eventArgs.Data);
        process.ErrorDataReceived += (_, eventArgs) => session.Append(session._stderrGate, session._stderr, eventArgs.Data);
        if (!process.Start())
            throw new VerifierFailure(FailureClassification.ProductContract, "runtime_start", "Failed to start package Runtime executable.");
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        return session;
    }

    public string StdoutText
    {
        get { lock (_stdoutGate) return _stdout.ToString(); }
    }

    public string StderrText
    {
        get { lock (_stderrGate) return _stderr.ToString(); }
    }

    public async Task<int> WaitForStderrAsync(
        string marker,
        TimeSpan timeout,
        int searchStart,
        string stage,
        CancellationToken cancellationToken)
    {
        var deadline = DateTimeOffset.UtcNow + timeout;
        while (DateTimeOffset.UtcNow <= deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var current = StderrText;
            var position = current.IndexOf(marker, Math.Clamp(searchStart, 0, current.Length), StringComparison.Ordinal);
            if (position >= searchStart) return position;
            if (HasExited)
            {
                DrainAsyncReaders();
                throw new VerifierFailure(
                    FailureClassification.ProductContract,
                    stage,
                    $"Runtime exited with code {Process.ExitCode} before log marker: {marker}");
            }
            await Task.Delay(25, cancellationToken).ConfigureAwait(false);
        }
        throw new VerifierFailure(FailureClassification.Timeout, stage, $"Timed out waiting for Runtime log marker: {marker}");
    }

    public async Task WaitForExitAsync(TimeSpan timeout, CancellationToken cancellationToken)
    {
        if (HasExited)
        {
            DrainAsyncReaders();
            return;
        }
        using var timeoutSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutSource.CancelAfter(timeout);
        try
        {
            await Process.WaitForExitAsync(timeoutSource.Token).ConfigureAwait(false);
            DrainAsyncReaders();
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new VerifierFailure(FailureClassification.Timeout, "runtime_close", "Runtime did not exit within the bounded WM_CLOSE window.");
        }
    }

    public async Task EnsureStoppedAsync(nint window, CancellationToken cancellationToken)
    {
        if (HasExited)
        {
            DrainAsyncReaders();
            return;
        }

        if (window != 0) _ = Win32RuntimeWindow.PostClose(window);
        try
        {
            await WaitForExitAsync(TimeSpan.FromSeconds(3), cancellationToken).ConfigureAwait(false);
            return;
        }
        catch (VerifierFailure exception) when (exception.Classification == FailureClassification.Timeout) { }

        // 失败路径只终止本次 verifier 启动的进程树，并等待句柄确认退出，避免遗留 Runtime/辅助进程。
        ForcedTreeKill = true;
        Process.Kill(entireProcessTree: true);
        using var killTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        await Process.WaitForExitAsync(killTimeout.Token).ConfigureAwait(false);
        DrainAsyncReaders();
    }

    public async ValueTask DisposeAsync()
    {
        try
        {
            if (!HasExited) await EnsureStoppedAsync(0, CancellationToken.None).ConfigureAwait(false);
        }
        finally
        {
            Process.Dispose();
        }
    }

    private void DrainAsyncReaders()
    {
        if (Process.HasExited) Process.WaitForExit();
    }

    private void Append(object gate, StringBuilder builder, string? line)
    {
        if (line is null) return;
        lock (gate) builder.AppendLine(line);
    }
}
