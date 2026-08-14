using System.Buffers;
using System.Buffers.Binary;
using System.ComponentModel;
using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Kadath.Editor.Protocol;

namespace Kadath.Editor.Workspace;

public enum WorkspaceScriptDiagnosticsFailureKind
{
    Input,
    Unavailable,
    Timeout,
    Protocol,
    Cleanup
}

public sealed class WorkspaceScriptDiagnosticsException : Exception
{
    public WorkspaceScriptDiagnosticsException(
        WorkspaceScriptDiagnosticsFailureKind kind,
        string message,
        Exception? innerException = null)
        : base(message, innerException) => Kind = kind;

    public WorkspaceScriptDiagnosticsFailureKind Kind { get; }
}

public sealed class WorkspaceScriptDiagnosticsModel
{
    private const int RequestHeaderBytes = 16;
    private const int ResponseHeaderBytes = 12;
    private const int MaxSourceBytes = 64 * 1024;
    private const int MaxSourcePathBytes = 1024;
    private const int MaxResultBytes = 64 * 1024;
    private const int MaxDiagnosticCount = 32;
    private const int MaxDiagnosticMessageBytes = 1024;
    private const int MaxStandardErrorBytes = 4096;
    private static readonly byte[] RequestMagic = "KLAN"u8.ToArray();
    private static readonly byte[] ResponseMagic = "KLAR"u8.ToArray();
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    private static readonly TimeSpan AnalyzeTimeout = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan CooperativeExitTimeout = TimeSpan.FromMilliseconds(250);
    private static readonly TimeSpan KillExitTimeout = TimeSpan.FromSeconds(1);
    private readonly IProcessControl _processControl;

    public WorkspaceScriptDiagnosticsModel() : this(SystemProcessControl.Instance) { }

    internal WorkspaceScriptDiagnosticsModel(IProcessControl processControl) =>
        _processControl = processControl ?? throw new ArgumentNullException(nameof(processControl));

    public async Task<ScriptSourceAnalysisResult> AnalyzeAsync(
        ProjectSessionInfo project,
        ScriptSourceAnalyzeParameters parameters,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(project);
        ArgumentNullException.ThrowIfNull(parameters);
        cancellationToken.ThrowIfCancellationRequested();
        try
        {
            return await AnalyzeCoreAsync(project, parameters, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) { throw; }
        catch (WorkspaceScriptDiagnosticsException) { throw; }
        catch (WorkspaceReadException exception)
        {
            throw Failure(WorkspaceScriptDiagnosticsFailureKind.Input, exception.Message, exception);
        }
        catch (WorkspaceProjectValidationException exception)
        {
            throw Failure(WorkspaceScriptDiagnosticsFailureKind.Input, exception.Message, exception);
        }
        catch (EncoderFallbackException exception)
        {
            throw Failure(WorkspaceScriptDiagnosticsFailureKind.Input, "Script source must be strict UTF-8.", exception);
        }
        catch (DecoderFallbackException exception)
        {
            throw Failure(WorkspaceScriptDiagnosticsFailureKind.Protocol, "Behavior Tool output must be strict UTF-8.", exception);
        }
        catch (InvalidDataException exception)
        {
            throw Failure(WorkspaceScriptDiagnosticsFailureKind.Protocol, exception.Message, exception);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException or FormatException or OverflowException)
        {
            throw Failure(WorkspaceScriptDiagnosticsFailureKind.Protocol, exception.Message, exception);
        }
    }

    private async Task<ScriptSourceAnalysisResult> AnalyzeCoreAsync(
        ProjectSessionInfo project,
        ScriptSourceAnalyzeParameters parameters,
        CancellationToken cancellationToken)
    {
        if (parameters.ProjectName is not null
            && !parameters.ProjectName.Equals(project.ProjectName, StringComparison.Ordinal))
        {
            throw Failure(WorkspaceScriptDiagnosticsFailureKind.Input, "Script analysis project does not match the open project.");
        }
        if (parameters.ScriptId == 0)
            throw Failure(WorkspaceScriptDiagnosticsFailureKind.Input, "Script analysis requires a non-zero scriptId.");
        if (parameters.Source is null)
            throw Failure(WorkspaceScriptDiagnosticsFailureKind.Input, "Script analysis requires source text.");
        if (!IsLowerSha256(parameters.SourceHash))
            throw Failure(WorkspaceScriptDiagnosticsFailureKind.Input, "Script analysis sourceHash must be lowercase SHA-256 hex.");

        byte[] sourceBytes;
        try { sourceBytes = StrictUtf8.GetBytes(parameters.Source); }
        catch (EncoderFallbackException exception)
        {
            throw Failure(WorkspaceScriptDiagnosticsFailureKind.Input, "Script analysis source must be strict UTF-8.", exception);
        }
        if (sourceBytes.Length > MaxSourceBytes)
            throw Failure(WorkspaceScriptDiagnosticsFailureKind.Input, "Script analysis source exceeds 64 KiB.");
        var sourceHash = Convert.ToHexString(SHA256.HashData(sourceBytes)).ToLowerInvariant();
        if (!sourceHash.Equals(parameters.SourceHash, StringComparison.Ordinal))
            throw Failure(WorkspaceScriptDiagnosticsFailureKind.Input, "Script analysis sourceHash does not match the submitted source.");

        var projectSnapshot = await new WorkspaceReadModel().ReadProjectAsync(project, cancellationToken).ConfigureAwait(false);
        if (projectSnapshot.Script.SchemaVersion != 2)
            throw Failure(WorkspaceScriptDiagnosticsFailureKind.Input, "Script analysis requires Script schema v2.");
        var dependency = projectSnapshot.Script.Dependencies?.SingleOrDefault(value => value.ScriptId == parameters.ScriptId)
            ?? throw Failure(WorkspaceScriptDiagnosticsFailureKind.Input, "Script analysis scriptId is not declared by the current manifest.");
        var sourcePathBytes = StrictUtf8.GetBytes(dependency.Source);
        if (sourcePathBytes.Length is < 1 or > MaxSourcePathBytes)
            throw Failure(WorkspaceScriptDiagnosticsFailureKind.Input, "Script analysis source path is outside the protocol bounds.");

        var toolPath = ResolveToolPath(project.PackageRoot);
        var frame = CreateRequestFrame(sourcePathBytes, sourceBytes);
        var invocation = await InvokeAsync(toolPath, project.ProjectDirectory, frame, cancellationToken).ConfigureAwait(false);
        var nativeResult = ParseResponse(invocation.ResponseJson, parameters.Source);
        var diagnostics = nativeResult.Diagnostics.Select(value => new ScriptSourceDiagnostic(
            value.Severity,
            value.Stage,
            value.Code,
            value.Message,
            dependency.Source,
            value.Range)).ToArray();
        return new ScriptSourceAnalysisResult(
            nativeResult.State,
            project.ProjectName,
            parameters.ScriptId,
            dependency.Source,
            sourceHash,
            projectSnapshot.AuthoringRevision,
            nativeResult.ToolchainIdentity,
            diagnostics);
    }

    private static string ResolveToolPath(string packageRoot)
    {
        try { return WorkspaceBehaviorTool.ResolveToolPath(packageRoot); }
        catch (Exception exception) when (exception is InvalidDataException or IOException or UnauthorizedAccessException or WorkspaceProjectValidationException)
        {
            throw Failure(WorkspaceScriptDiagnosticsFailureKind.Unavailable, exception.Message, exception);
        }
    }

    private static byte[] CreateRequestFrame(byte[] sourcePath, byte[] source)
    {
        var frame = new byte[checked(RequestHeaderBytes + sourcePath.Length + source.Length)];
        RequestMagic.CopyTo(frame, 0);
        BinaryPrimitives.WriteUInt32LittleEndian(frame.AsSpan(4, 4), 1);
        BinaryPrimitives.WriteUInt32LittleEndian(frame.AsSpan(8, 4), checked((uint)sourcePath.Length));
        BinaryPrimitives.WriteUInt32LittleEndian(frame.AsSpan(12, 4), checked((uint)source.Length));
        sourcePath.CopyTo(frame, RequestHeaderBytes);
        source.CopyTo(frame, RequestHeaderBytes + sourcePath.Length);
        return frame;
    }

    private async Task<ToolInvocationResult> InvokeAsync(
        string toolPath,
        string workingDirectory,
        byte[] request,
        CancellationToken cancellationToken)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = toolPath,
            WorkingDirectory = workingDirectory,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        startInfo.ArgumentList.Add("--analyze-stdin");
        using var process = new Process { StartInfo = startInfo };
        try
        {
            if (!process.Start())
                throw Failure(WorkspaceScriptDiagnosticsFailureKind.Unavailable, "Behavior Tool process did not start.");
        }
        catch (Win32Exception exception)
        {
            throw Failure(WorkspaceScriptDiagnosticsFailureKind.Unavailable, $"Failed to start Behavior Tool: {exception.Message}", exception);
        }

        using var timeout = new CancellationTokenSource(AnalyzeTimeout);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeout.Token);
        var writeTask = WriteRequestAsync(process.StandardInput.BaseStream, request, linked.Token);
        var responseTask = ReadResponseAsync(process.StandardOutput.BaseStream, linked.Token);
        var stderrTask = ReadBoundedAsync(process.StandardError.BaseStream, MaxStandardErrorBytes, linked.Token);
        var exitTask = process.WaitForExitAsync(linked.Token);
        Task[] tasks = [writeTask, responseTask, stderrTask, exitTask];
        try
        {
            await AwaitAllFailFastAsync(tasks).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (linked.IsCancellationRequested)
        {
            try { await StopProcessAsync(process).ConfigureAwait(false); }
            finally { await ObserveTasksAsync(tasks).ConfigureAwait(false); }
            if (cancellationToken.IsCancellationRequested) throw new OperationCanceledException(cancellationToken);
            throw Failure(WorkspaceScriptDiagnosticsFailureKind.Timeout, "Script source analysis timed out.");
        }
        catch (Exception exception)
        {
            linked.Cancel();
            try { await StopProcessAsync(process).ConfigureAwait(false); }
            finally { await ObserveTasksAsync(tasks).ConfigureAwait(false); }
            throw Failure(WorkspaceScriptDiagnosticsFailureKind.Protocol, "Behavior Tool pipe protocol failed.", exception);
        }

        var stderr = StrictUtf8.GetString(await stderrTask.ConfigureAwait(false));
        if (process.ExitCode != 0)
        {
            var summary = string.IsNullOrWhiteSpace(stderr) ? "no stderr summary" : stderr.Trim();
            throw Failure(
                WorkspaceScriptDiagnosticsFailureKind.Protocol,
                $"Behavior Tool exited with code {process.ExitCode}: {summary}");
        }
        return new ToolInvocationResult(await responseTask.ConfigureAwait(false));
    }

    private static async Task AwaitAllFailFastAsync(IEnumerable<Task> tasks)
    {
        var pending = tasks.ToList();
        while (pending.Count > 0)
        {
            var completed = await Task.WhenAny(pending).ConfigureAwait(false);
            pending.Remove(completed);
            await completed.ConfigureAwait(false);
        }
    }

    private static async Task ObserveTasksAsync(IEnumerable<Task> tasks)
    {
        foreach (var task in tasks)
        {
            try { await task.ConfigureAwait(false); }
            catch { }
        }
    }

    private static async Task WriteRequestAsync(Stream stream, byte[] request, CancellationToken cancellationToken)
    {
        try
        {
            await stream.WriteAsync(request, cancellationToken).ConfigureAwait(false);
            await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
        }
        finally { stream.Close(); }
    }

    private static async Task<byte[]> ReadResponseAsync(Stream stream, CancellationToken cancellationToken)
    {
        var header = new byte[ResponseHeaderBytes];
        await ReadExactlyAsync(stream, header, cancellationToken).ConfigureAwait(false);
        if (!header.AsSpan(0, 4).SequenceEqual(ResponseMagic))
            throw new InvalidDataException("Behavior Tool response magic is invalid.");
        if (BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(4, 4)) != 1)
            throw new InvalidDataException("Behavior Tool response version is unsupported.");
        var resultBytes = BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(8, 4));
        if (resultBytes is 0 or > MaxResultBytes)
            throw new InvalidDataException("Behavior Tool response length is outside protocol bounds.");
        var result = new byte[resultBytes];
        await ReadExactlyAsync(stream, result, cancellationToken).ConfigureAwait(false);
        var trailing = false;
        var buffer = ArrayPool<byte>.Shared.Rent(4096);
        try
        {
            int read;
            while ((read = await stream.ReadAsync(buffer, cancellationToken).ConfigureAwait(false)) != 0)
                trailing = true;
        }
        finally { ArrayPool<byte>.Shared.Return(buffer); }
        if (trailing) throw new InvalidDataException("Behavior Tool response contains trailing bytes.");
        try { _ = StrictUtf8.GetString(result); }
        catch (DecoderFallbackException exception)
        {
            throw new InvalidDataException("Behavior Tool response is not strict UTF-8.", exception);
        }
        return result;
    }

    private static async Task<byte[]> ReadBoundedAsync(Stream stream, int maximum, CancellationToken cancellationToken)
    {
        using var output = new MemoryStream(maximum);
        var buffer = ArrayPool<byte>.Shared.Rent(4096);
        try
        {
            int read;
            while ((read = await stream.ReadAsync(buffer, cancellationToken).ConfigureAwait(false)) != 0)
            {
                var retained = Math.Min(read, maximum - checked((int)output.Length));
                if (retained > 0) output.Write(buffer, 0, retained);
            }
            return output.ToArray();
        }
        finally { ArrayPool<byte>.Shared.Return(buffer); }
    }

    private static async Task ReadExactlyAsync(Stream stream, byte[] buffer, CancellationToken cancellationToken)
    {
        var offset = 0;
        while (offset < buffer.Length)
        {
            var read = await stream.ReadAsync(buffer.AsMemory(offset), cancellationToken).ConfigureAwait(false);
            if (read == 0) throw new EndOfStreamException("Behavior Tool response was truncated.");
            offset += read;
        }
    }

    private async Task StopProcessAsync(Process process)
    {
        try { process.StandardInput.Close(); }
        catch { }
        if (process.HasExited) return;
        if (await _processControl.WaitForExitAsync(process, CooperativeExitTimeout).ConfigureAwait(false)) return;
        try { if (!process.HasExited) _processControl.KillTree(process); }
        catch (Exception exception)
        {
            throw Failure(WorkspaceScriptDiagnosticsFailureKind.Cleanup, "Behavior Tool process could not be killed.", exception);
        }
        if (!await _processControl.WaitForExitAsync(process, KillExitTimeout).ConfigureAwait(false))
        {
            throw Failure(WorkspaceScriptDiagnosticsFailureKind.Cleanup, "Behavior Tool process did not exit after kill.");
        }
    }

    internal interface IProcessControl
    {
        Task<bool> WaitForExitAsync(Process process, TimeSpan timeout);
        void KillTree(Process process);
    }

    private sealed class SystemProcessControl : IProcessControl
    {
        internal static SystemProcessControl Instance { get; } = new();

        public async Task<bool> WaitForExitAsync(Process process, TimeSpan timeout)
        {
            using var cancellation = new CancellationTokenSource(timeout);
            try
            {
                await process.WaitForExitAsync(cancellation.Token).ConfigureAwait(false);
                return true;
            }
            catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
            {
                return false;
            }
        }

        public void KillTree(Process process) => process.Kill(entireProcessTree: true);
    }

    private static NativeAnalysisResult ParseResponse(byte[] json, string source)
    {
        try
        {
            using var document = JsonDocument.Parse(json, new JsonDocumentOptions
            {
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow,
                MaxDepth = 16
            });
            var root = document.RootElement;
            RequireProperties(root, ["state", "toolchainIdentity", "diagnostics"], "analysis result");
            var state = RequireString(root, "state", "analysis result");
            if (state is not ("valid" or "invalid")) throw new InvalidDataException("Analysis state is unsupported.");
            var toolchainIdentity = RequireString(root, "toolchainIdentity", "analysis result");
            if (!IsPrintableAsciiToken(toolchainIdentity, 128)) throw new InvalidDataException("Analysis toolchain identity is invalid.");
            var values = root.GetProperty("diagnostics");
            if (values.ValueKind != JsonValueKind.Array || values.GetArrayLength() > MaxDiagnosticCount)
                throw new InvalidDataException("Analysis diagnostics are outside protocol bounds.");

            var validPositions = SourcePositions(source);
            var diagnostics = new List<NativeDiagnostic>(values.GetArrayLength());
            foreach (var value in values.EnumerateArray())
                diagnostics.Add(ParseDiagnostic(value, validPositions));
            if ((state == "valid") != (diagnostics.Count == 0))
                throw new InvalidDataException("Analysis state and diagnostics disagree.");
            ValidateDiagnosticOrder(diagnostics);
            return new NativeAnalysisResult(state, toolchainIdentity, diagnostics.ToArray());
        }
        catch (JsonException exception)
        {
            throw new InvalidDataException($"Behavior Tool result JSON is invalid: {exception.Message}", exception);
        }
    }

    private static NativeDiagnostic ParseDiagnostic(JsonElement value, HashSet<ScriptSourcePosition> validPositions)
    {
        RequireProperties(value, ["severity", "stage", "code", "message", "range"], "diagnostic");
        var severity = RequireString(value, "severity", "diagnostic");
        if (severity != "error") throw new InvalidDataException("Diagnostic severity is unsupported.");
        var stage = RequireString(value, "stage", "diagnostic");
        var code = RequireString(value, "code", "diagnostic");
        if (!ValidDiagnosticCode(stage, code)) throw new InvalidDataException("Diagnostic stage/code pair is unsupported.");
        var message = RequireString(value, "message", "diagnostic");
        int messageBytes;
        try { messageBytes = StrictUtf8.GetByteCount(message); }
        catch (EncoderFallbackException exception)
        {
            throw new InvalidDataException("Diagnostic message is not strict UTF-8.", exception);
        }
        if (message.Length == 0 || messageBytes > MaxDiagnosticMessageBytes)
            throw new InvalidDataException("Diagnostic message is outside protocol bounds.");
        var rangeValue = value.GetProperty("range");
        ScriptSourceRange? range = null;
        if (rangeValue.ValueKind != JsonValueKind.Null)
        {
            RequireProperties(rangeValue, ["start", "end"], "diagnostic range");
            var start = ParsePosition(rangeValue.GetProperty("start"), "diagnostic range start");
            var end = ParsePosition(rangeValue.GetProperty("end"), "diagnostic range end");
            if (!validPositions.Contains(start) || !validPositions.Contains(end) || Compare(start, end) > 0)
                throw new InvalidDataException("Diagnostic range does not map to the submitted source.");
            range = new ScriptSourceRange(start, end);
        }
        if (stage is "tooling_execution" or "behavior_contract" && range is not null)
            throw new InvalidDataException("Tooling and behavior-contract diagnostics cannot have source ranges.");
        return new NativeDiagnostic(severity, stage, code, message, range);
    }

    private static ScriptSourcePosition ParsePosition(JsonElement value, string owner)
    {
        RequireProperties(value, ["line", "column"], owner);
        if (!value.GetProperty("line").TryGetInt32(out var line) || line < 1
            || !value.GetProperty("column").TryGetInt32(out var column) || column < 1)
        {
            throw new InvalidDataException($"{owner} is invalid.");
        }
        return new ScriptSourcePosition(line, column);
    }

    private static HashSet<ScriptSourcePosition> SourcePositions(string source)
    {
        var positions = new HashSet<ScriptSourcePosition>();
        var line = 1;
        var column = 1;
        positions.Add(new ScriptSourcePosition(line, column));
        foreach (var rune in source.EnumerateRunes())
        {
            if (rune.Value == '\n')
            {
                line = checked(line + 1);
                column = 1;
            }
            else column = checked(column + 1);
            positions.Add(new ScriptSourcePosition(line, column));
        }
        return positions;
    }

    private static void ValidateDiagnosticOrder(IReadOnlyList<NativeDiagnostic> diagnostics)
    {
        for (var index = 1; index < diagnostics.Count; index++)
        {
            if (Compare(diagnostics[index - 1], diagnostics[index]) > 0)
                throw new InvalidDataException("Analysis diagnostics are not in stable order.");
        }
        var limitIndices = diagnostics
            .Select((value, index) => (value, index))
            .Where(entry => entry.value.Code == "KADATH_DIAGNOSTIC_LIMIT_REACHED")
            .Select(entry => entry.index)
            .ToArray();
        if (limitIndices.Length > 1
            || limitIndices is [var limitIndex] && (diagnostics.Count != MaxDiagnosticCount
                || limitIndex != diagnostics.Count - 1
                || diagnostics[limitIndex].Stage != "analysis"
                || diagnostics[limitIndex].Range is not null))
        {
            throw new InvalidDataException("Analysis diagnostic limit sentinel is invalid.");
        }
    }

    private static int Compare(NativeDiagnostic left, NativeDiagnostic right)
    {
        if ((left.Range is null) != (right.Range is null)) return left.Range is null ? 1 : -1;
        if (left.Range is not null && right.Range is not null)
        {
            var range = Compare(left.Range.Start, right.Range.Start);
            if (range != 0) return range;
            range = Compare(left.Range.End, right.Range.End);
            if (range != 0) return range;
        }
        var value = StringComparer.Ordinal.Compare(left.Stage, right.Stage);
        if (value != 0) return value;
        value = StringComparer.Ordinal.Compare(left.Code, right.Code);
        return value != 0 ? value : StringComparer.Ordinal.Compare(left.Message, right.Message);
    }

    private static int Compare(ScriptSourcePosition left, ScriptSourcePosition right)
    {
        var line = left.Line.CompareTo(right.Line);
        return line != 0 ? line : left.Column.CompareTo(right.Column);
    }

    private static bool ValidDiagnosticCode(string stage, string code) => (stage, code) switch
    {
        ("analysis", "LUAU_ANALYSIS_ERROR") => true,
        ("analysis", "LUAU_ANALYSIS_BUDGET_EXCEEDED") => true,
        ("analysis", "KADATH_DIAGNOSTIC_LIMIT_REACHED") => true,
        ("compile", "LUAU_COMPILE_ERROR") => true,
        ("tooling_execution", "KADATH_TOOLING_EXECUTION_ERROR") => true,
        ("tooling_execution", "KADATH_TOOLING_EXECUTION_BUDGET_EXCEEDED") => true,
        ("tooling_execution", "KADATH_TOOLING_MEMORY_LIMIT_EXCEEDED") => true,
        ("behavior_contract", "KADATH_INVALID_PARAMETER_DECLARATION") => true,
        ("behavior_contract", "KADATH_INVALID_BEHAVIOR_TABLE") => true,
        _ => false
    };

    private static void RequireProperties(JsonElement value, string[] names, string owner)
    {
        if (value.ValueKind != JsonValueKind.Object) throw new InvalidDataException($"{owner} must be an object.");
        var expected = new HashSet<string>(names, StringComparer.Ordinal);
        var actual = new HashSet<string>(StringComparer.Ordinal);
        foreach (var property in value.EnumerateObject())
        {
            if (!expected.Contains(property.Name)) throw new InvalidDataException($"{owner} contains an unknown property: {property.Name}.");
            if (!actual.Add(property.Name)) throw new InvalidDataException($"{owner} contains a duplicate property: {property.Name}.");
        }
        if (!actual.SetEquals(expected)) throw new InvalidDataException($"{owner} is missing required properties.");
    }

    private static string RequireString(JsonElement value, string name, string owner)
    {
        var property = value.GetProperty(name);
        if (property.ValueKind != JsonValueKind.String || property.GetString() is not { } result)
            throw new InvalidDataException($"{owner}.{name} must be a string.");
        return result;
    }

    private static bool IsLowerSha256(string? value) => value is { Length: 64 }
        && value.All(character => character is >= '0' and <= '9' or >= 'a' and <= 'f');

    private static bool IsPrintableAsciiToken(string value, int maximum) => value.Length is > 0
        && value.Length <= maximum
        && value.All(character => character is >= (char)0x21 and <= (char)0x7e);

    private static WorkspaceScriptDiagnosticsException Failure(
        WorkspaceScriptDiagnosticsFailureKind kind,
        string message,
        Exception? innerException = null) => new(kind, message, innerException);

    private sealed record ToolInvocationResult(byte[] ResponseJson);
    private sealed record NativeAnalysisResult(string State, string ToolchainIdentity, NativeDiagnostic[] Diagnostics);
    private sealed record NativeDiagnostic(
        string Severity,
        string Stage,
        string Code,
        string Message,
        ScriptSourceRange? Range);
}
