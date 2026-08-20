using System.Buffers.Binary;
using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Kadath.Editor.Protocol;
using Kadath.Editor.Workspace;

namespace Kadath.Editor.Workspace.ContractVerifier;

internal static class BehaviorPublicationVerifier
{
    internal static async Task VerifyAsync()
    {
        if (!OperatingSystem.IsLinux()) return;
        var toolPath = ResolveBehaviorTool();
        var previousToolPath = Environment.GetEnvironmentVariable("KADATH_BEHAVIOR_TOOL");
        var root = Path.Combine(Path.GetTempPath(), $"kadath-behavior-publication-{Guid.NewGuid():N}");
        Environment.SetEnvironmentVariable("KADATH_BEHAVIOR_TOOL", toolPath);
        try
        {
            var project = CreateProject(root);
            await VerifyAdapterFailureFramesAsync(toolPath);
            await VerifyBehaviorContractSnapshotAsync(project, root, toolPath);
            await VerifyDiagnosticsAsync(project, root);
            var model = new WorkspacePublicationModel();
            var initialSourceRevision = WorkspaceScriptDependencySet.ComputeRevision(project.ScriptPath);
            Require(IsSha256(initialSourceRevision), "Script v2 dependency revision is not SHA-256.");

            var initial = await model.BakeAsync(project, new BakeStartParameters("Both", "debug"), default);
            Require(initial.ScriptRevision == initialSourceRevision, "Publication did not persist the complete Script dependency revision.");
            var artifactPath = Path.Combine(initial.DerivedDirectory, "script.script");
            var artifact = File.ReadAllBytes(artifactPath);
            Require(BinaryPrimitives.ReadUInt32LittleEndian(artifact.AsSpan(4, 4)) == 2
                && BinaryPrimitives.ReadUInt32LittleEndian(artifact.AsSpan(12, 4)) == 3,
                "Publication did not produce KSCP v2 with Host Interface v3.");
            var hostV2Artifact = artifact.ToArray();
            BinaryPrimitives.WriteUInt32LittleEndian(hostV2Artifact.AsSpan(12, 4), 2);
            try
            {
                _ = WorkspaceScriptCodec.ValidateArtifact(hostV2Artifact);
                throw new InvalidOperationException("Editor parser accepted a Host Interface v2 artifact.");
            }
            catch (InvalidDataException) { }
            var artifactInfo = WorkspaceScriptCodec.ValidateArtifact(artifact);
            Require(artifactInfo.Format == "KSCP-SCRIPT-V2" && artifactInfo.ImporterVersion == 2 && artifactInfo.BakerVersion == 2,
                "KSCP v2 identity mismatch.");
            using (var manifest = JsonDocument.Parse(File.ReadAllBytes(initial.ManifestPath)))
            {
                var script = manifest.RootElement.GetProperty("script");
                Require(script.GetProperty("sourceSha256").GetString() == initialSourceRevision
                    && script.GetProperty("artifactFormat").GetString() == "KSCP-SCRIPT-V2"
                    && script.GetProperty("importerVersion").GetInt32() == 2
                    && script.GetProperty("bakerVersion").GetInt32() == 2,
                    "Live-bake manifest did not record the KSCP v2 contract.");
            }

            var readModel = new WorkspaceReadModel();
            var current = await readModel.ReadPublicationAsync(project, "debug", default);
            Require(current.State == "current" && current.Script.State == "current", "KSCP v2 publication was not projected as current.");

            var sourcePath = Path.Combine(project.ProjectDirectory, "scripts", "patrol.luau");
            File.WriteAllText(sourcePath, ChangedLuau, new UTF8Encoding(false));
            var changedSourceRevision = WorkspaceScriptDependencySet.ComputeRevision(project.ScriptPath);
            Require(changedSourceRevision != initialSourceRevision, "Changing only a .luau dependency did not change Script source revision.");
            var dirty = await readModel.ReadPublicationAsync(project, "debug", default);
            Require(dirty.State == "source_dirty" && dirty.Script.State == "source_dirty"
                && dirty.Script.SourceRevision == changedSourceRevision,
                "Publication state ignored a changed .luau dependency.");

            var changed = await model.BakeAsync(project, new BakeStartParameters("Script", "debug"), default);
            Require(changed.ScriptRevision == changedSourceRevision && changed.ScriptArtifactRevision != initial.ScriptArtifactRevision,
                "Script-only KSCP v2 publication did not promote the changed dependency set.");
            var retainedArtifact = File.ReadAllBytes(artifactPath);
            var retainedManifest = File.ReadAllBytes(initial.ManifestPath);

            File.WriteAllText(sourcePath, InvalidLuau, new UTF8Encoding(false));
            await ExpectFailureAsync(
                () => model.BakeAsync(project, new BakeStartParameters("Script", "debug"), default),
                WorkspacePublicationFailureKind.Validation);
            Require(File.ReadAllBytes(artifactPath).AsSpan().SequenceEqual(retainedArtifact)
                && File.ReadAllBytes(initial.ManifestPath).AsSpan().SequenceEqual(retainedManifest),
                "Invalid Luau publication replaced the active artifact or manifest.");
            RequireNoTemporaries(initial.DerivedDirectory);

            var corrupted = retainedArtifact.ToArray();
            corrupted[^1] ^= 0x01;
            Expect<InvalidDataException>(() => WorkspaceScriptCodec.ValidateArtifact(corrupted));

            VerifyInvalidManifestRetainsDependencyWatch(project.ScriptPath, sourcePath);
            await VerifyDependencySourceRecheckAsync(root + "-source-recheck");
        }
        finally
        {
            Environment.SetEnvironmentVariable("KADATH_BEHAVIOR_TOOL", previousToolPath);
            foreach (var path in Directory.GetDirectories(Path.GetDirectoryName(root)!, Path.GetFileName(root) + "*"))
            {
                try { Directory.Delete(path, recursive: true); }
                catch { }
            }
        }
    }

    private static async Task VerifyDiagnosticsAsync(ProjectSessionInfo project, string root)
    {
        var model = new WorkspaceScriptDiagnosticsModel();
        var before = ProjectIdentity(project.ProjectDirectory);
        var validSource = InitialLuau + "\n-- unsaved valid buffer\n";
        var valid = await model.AnalyzeAsync(project, new ScriptSourceAnalyzeParameters(
            project.ProjectName,
            1,
            validSource,
            Hash(validSource)), default);
        Require(valid.State == "valid" && valid.Diagnostics.Length == 0
            && valid.ProjectName == project.ProjectName && valid.ScriptId == 1
            && valid.SourcePath == "scripts/patrol.luau"
            && valid.ToolchainIdentity == "luau-0.732-decb2d0",
            "Workspace Script diagnostics valid result mismatch.");
        var repeated = await model.AnalyzeAsync(project, new ScriptSourceAnalyzeParameters(
            project.ProjectName,
            1,
            validSource,
            Hash(validSource)), default);
        Require(JsonSerializer.Serialize(valid, EditorProtocol.JsonOptions)
            == JsonSerializer.Serialize(repeated, EditorProtocol.JsonOptions),
            "Workspace Script diagnostics were not deterministic for the same Buffer Identity.");

        const string invalidSource = "--!strict\nlocal value: string = 1\nreturn {}";
        var invalid = await model.AnalyzeAsync(project, new ScriptSourceAnalyzeParameters(
            project.ProjectName,
            1,
            invalidSource,
            Hash(invalidSource)), default);
        Require(invalid.State == "invalid" && invalid.Diagnostics.Length >= 1
            && invalid.Diagnostics.All(value => value.SourcePath == "scripts/patrol.luau")
            && invalid.Diagnostics[0].Stage == "analysis"
            && invalid.Diagnostics[0].Code == "LUAU_ANALYSIS_ERROR"
            && invalid.Diagnostics[0].Range?.Start.Line == 2,
            "Workspace Script diagnostics invalid result mismatch.");

        const string nulSource = "return {}\0return { unknown = function() end }";
        var embeddedNul = await model.AnalyzeAsync(project, new ScriptSourceAnalyzeParameters(
            project.ProjectName,
            1,
            nulSource,
            Hash(nulSource)), default);
        Require(embeddedNul.State == "invalid"
            && embeddedNul.Diagnostics is [{ Code: "LUAU_ANALYSIS_ERROR", Range.Start.Column: 10, Range.End.Column: 11 }],
            "Workspace Script diagnostics did not preserve the embedded NUL range.");

        var empty = await model.AnalyzeAsync(project, new ScriptSourceAnalyzeParameters(
            project.ProjectName,
            1,
            string.Empty,
            Hash(string.Empty)), default);
        Require(empty.State == "invalid"
            && empty.Diagnostics is [{ Stage: "behavior_contract", Code: "KADATH_INVALID_BEHAVIOR_TABLE", Range: null }],
            "Workspace Script diagnostics did not classify an empty buffer as a behavior-contract error.");

        var maximumSource = "return {}\n--" + new string('a', (64 * 1024) - 12);
        Require(new UTF8Encoding(false, true).GetByteCount(maximumSource) == 64 * 1024,
            "Maximum-size diagnostics fixture is not exactly 64 KiB.");
        var maximum = await model.AnalyzeAsync(project, new ScriptSourceAnalyzeParameters(
            project.ProjectName,
            1,
            maximumSource,
            Hash(maximumSource)), default);
        Require(maximum.State == "valid", "Workspace Script diagnostics rejected the exact 64 KiB source limit.");

        await ExpectDiagnosticsFailureAsync(
            () => model.AnalyzeAsync(project, new ScriptSourceAnalyzeParameters(project.ProjectName, 1, validSource, new string('0', 64)), default),
            WorkspaceScriptDiagnosticsFailureKind.Input);
        await ExpectDiagnosticsFailureAsync(
            () => model.AnalyzeAsync(project, new ScriptSourceAnalyzeParameters(project.ProjectName, 99, validSource, Hash(validSource)), default),
            WorkspaceScriptDiagnosticsFailureKind.Input);
        var oversizedSource = maximumSource + "a";
        await ExpectDiagnosticsFailureAsync(
            () => model.AnalyzeAsync(project, new ScriptSourceAnalyzeParameters(project.ProjectName, 1, oversizedSource, Hash(oversizedSource)), default),
            WorkspaceScriptDiagnosticsFailureKind.Input);
        var legacyProject = CreateProject(root + "-script-v1");
        File.WriteAllText(legacyProject.ScriptPath, LegacyScriptJson, new UTF8Encoding(false));
        await ExpectDiagnosticsFailureAsync(
            () => model.AnalyzeAsync(legacyProject, new ScriptSourceAnalyzeParameters(legacyProject.ProjectName, 1, validSource, Hash(validSource)), default),
            WorkspaceScriptDiagnosticsFailureKind.Input);
        await VerifyDiagnosticsProcessFailuresAsync(project, root, validSource);
        Require(before == ProjectIdentity(project.ProjectDirectory), "Workspace Script diagnostics modified project files.");
    }

    private static async Task VerifyBehaviorContractSnapshotAsync(ProjectSessionInfo project, string root, string toolPath)
    {
        var model = new WorkspaceBehaviorContractModel();
        var before = ProjectIdentity(project.ProjectDirectory);
        var ready = await model.ReadAsync(project, default);
        Require(ready.State == "ready"
            && ready.Entries.Length == 1
            && ready.Entries[0].ScriptId == 1
            && ready.Entries[0].SourcePath == "scripts/patrol.luau"
            && ready.Entries[0].SourceHash == Hash(InitialLuau)
            && ready.Entries[0].Parameters.Length == 1
            && ready.Entries[0].Parameters[0] is { Name: "speed", Type: "number", DefaultValue: 80, Minimum: 0, Maximum: 1000 }
            && ready.AuthoringRevision.Length == 64
            && ready.ScriptSourceRevision.Length == 64
            && !string.IsNullOrWhiteSpace(ready.ToolchainIdentity),
            "Behavior Contract Snapshot did not expose the KSCP v2 parameter catalog.");
        Require(before == ProjectIdentity(project.ProjectDirectory), "Behavior Contract Snapshot modified the project tree.");

        var previousToolPath = Environment.GetEnvironmentVariable("KADATH_BEHAVIOR_TOOL");
        try
        {
            Environment.SetEnvironmentVariable("KADATH_BEHAVIOR_TOOL", Path.Combine(root, "missing-behavior-tool"));
            var unavailable = await model.ReadAsync(project, default);
            Require(unavailable.State == "unavailable"
                && unavailable.ErrorCode == "behavior_contract_tool_failure"
                && unavailable.Entries.Length == 0,
                "Behavior Contract Snapshot did not classify a missing tool as tool_failure.");
        }
        finally { Environment.SetEnvironmentVariable("KADATH_BEHAVIOR_TOOL", toolPath); }
        Require(before == ProjectIdentity(project.ProjectDirectory), "Failed Behavior Contract Snapshot modified the project tree.");
    }

    private static async Task VerifyAdapterFailureFramesAsync(string toolPath)
    {
        var validHeader = new byte[16];
        "KLAN"u8.CopyTo(validHeader);
        BinaryPrimitives.WriteUInt32LittleEndian(validHeader.AsSpan(4, 4), 1);
        BinaryPrimitives.WriteUInt32LittleEndian(validHeader.AsSpan(8, 4), 19);
        BinaryPrimitives.WriteUInt32LittleEndian(validHeader.AsSpan(12, 4), 9);
        var validFrame = validHeader
            .Concat("scripts/patrol.luau"u8.ToArray())
            .Concat("return {}"u8.ToArray())
            .ToArray();

        var badMagic = validFrame.ToArray();
        badMagic[0] = (byte)'X';
        await RequireAdapterFailureAsync(toolPath, badMagic, "bad magic");

        var badVersion = validFrame.ToArray();
        BinaryPrimitives.WriteUInt32LittleEndian(badVersion.AsSpan(4, 4), 2);
        await RequireAdapterFailureAsync(toolPath, badVersion, "unsupported version");

        var oversized = validHeader.ToArray();
        BinaryPrimitives.WriteUInt32LittleEndian(oversized.AsSpan(12, 4), (64 * 1024) + 1);
        await RequireAdapterFailureAsync(toolPath, oversized, "oversized source");

        await RequireAdapterFailureAsync(toolPath, validFrame[..8], "truncated header");
        await RequireAdapterFailureAsync(toolPath, validFrame[..^1], "truncated body");
        await RequireAdapterFailureAsync(toolPath, validFrame.Concat(new byte[] { 0 }).ToArray(), "trailing request bytes");
    }

    private static async Task RequireAdapterFailureAsync(string toolPath, byte[] request, string owner)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = toolPath,
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };
        startInfo.ArgumentList.Add("--analyze-stdin");
        using var process = Process.Start(startInfo)
            ?? throw new InvalidOperationException($"Behavior Tool did not start for {owner}.");
        var stdoutTask = ReadAllBytesAsync(process.StandardOutput.BaseStream);
        var stderrTask = ReadAllBytesAsync(process.StandardError.BaseStream);
        await process.StandardInput.BaseStream.WriteAsync(request);
        process.StandardInput.Close();
        await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5));
        var stdout = await stdoutTask;
        var stderr = await stderrTask;
        Require(process.ExitCode != 0 && stdout.Length == 0 && stderr.Length is > 0 and <= 4096,
            $"Behavior Tool {owner} failure violated exit/stdout/stderr bounds.");
    }

    private static async Task VerifyDiagnosticsProcessFailuresAsync(
        ProjectSessionInfo project,
        string root,
        string validSource)
    {
        var model = new WorkspaceScriptDiagnosticsModel();
        var parameters = new ScriptSourceAnalyzeParameters(project.ProjectName, 1, validSource, Hash(validSource));
        var previousToolPath = Environment.GetEnvironmentVariable("KADATH_BEHAVIOR_TOOL");
        var fakeRoot = Path.Combine(root, "diagnostic-failures");
        Directory.CreateDirectory(fakeRoot);
        try
        {
            Environment.SetEnvironmentVariable("KADATH_BEHAVIOR_TOOL", Path.Combine(fakeRoot, "missing-tool"));
            await ExpectDiagnosticsFailureAsync(
                () => model.AnalyzeAsync(project, parameters, default),
                WorkspaceScriptDiagnosticsFailureKind.Unavailable);

            var nonExecutable = Path.Combine(fakeRoot, "non-executable-tool");
            File.WriteAllText(nonExecutable, "not executable", new UTF8Encoding(false));
            Environment.SetEnvironmentVariable("KADATH_BEHAVIOR_TOOL", nonExecutable);
            await ExpectDiagnosticsFailureAsync(
                () => model.AnalyzeAsync(project, parameters, default),
                WorkspaceScriptDiagnosticsFailureKind.Unavailable);

            await ExpectProtocolResponseFailureAsync(model, project, parameters, fakeRoot, "truncated-response", "NOPE"u8.ToArray());
            await ExpectProtocolResponseFailureAsync(model, project, parameters, fakeRoot, "unknown-json", CreateResponseFrame(
                "{\"state\":\"valid\",\"toolchainIdentity\":\"fake-tool\",\"diagnostics\":[],\"unknown\":true}"u8.ToArray()));
            await ExpectProtocolResponseFailureAsync(model, project, parameters, fakeRoot, "duplicate-json", CreateResponseFrame(
                "{\"state\":\"valid\",\"state\":\"valid\",\"toolchainIdentity\":\"fake-tool\",\"diagnostics\":[]}"u8.ToArray()));
            await ExpectProtocolResponseFailureAsync(model, project, parameters, fakeRoot, "invalid-stage-code", CreateResponseFrame(
                "{\"state\":\"invalid\",\"toolchainIdentity\":\"fake-tool\",\"diagnostics\":[{\"severity\":\"error\",\"stage\":\"compile\",\"code\":\"LUAU_ANALYSIS_ERROR\",\"message\":\"bad pair\",\"range\":null}]}"u8.ToArray()));
            await ExpectProtocolResponseFailureAsync(model, project, parameters, fakeRoot, "invalid-range", CreateResponseFrame(
                "{\"state\":\"invalid\",\"toolchainIdentity\":\"fake-tool\",\"diagnostics\":[{\"severity\":\"error\",\"stage\":\"analysis\",\"code\":\"LUAU_ANALYSIS_ERROR\",\"message\":\"bad range\",\"range\":{\"start\":{\"line\":1,\"column\":9999},\"end\":{\"line\":1,\"column\":10000}}}]}"u8.ToArray()));
            var oversizedResponse = new byte[12];
            "KLAR"u8.CopyTo(oversizedResponse);
            BinaryPrimitives.WriteUInt32LittleEndian(oversizedResponse.AsSpan(4, 4), 1);
            BinaryPrimitives.WriteUInt32LittleEndian(oversizedResponse.AsSpan(8, 4), (64 * 1024) + 1);
            await ExpectProtocolResponseFailureAsync(model, project, parameters, fakeRoot, "oversized-response", oversizedResponse);
            await ExpectProtocolResponseFailureAsync(model, project, parameters, fakeRoot, "trailing-response", CreateResponseFrame(
                "{\"state\":\"valid\",\"toolchainIdentity\":\"fake-tool\",\"diagnostics\":[]}"u8.ToArray()).Concat(new byte[] { 0 }).ToArray());
            await ExpectProtocolResponseFailureAsync(model, project, parameters, fakeRoot, "invalid-utf8", CreateResponseFrame([0xff]));

            var validResponse = Path.Combine(fakeRoot, "valid-response.bin");
            File.WriteAllBytes(validResponse, CreateResponseFrame(
                "{\"state\":\"valid\",\"toolchainIdentity\":\"fake-tool\",\"diagnostics\":[]}"u8.ToArray()));
            var nonzeroTool = WriteExecutable(fakeRoot, "nonzero-tool.sh",
                $"#!/bin/sh\ncat >/dev/null\ncat '{validResponse}'\nprintf 'injected failure' >&2\nexit 7\n");
            Environment.SetEnvironmentVariable("KADATH_BEHAVIOR_TOOL", nonzeroTool);
            await ExpectDiagnosticsFailureAsync(
                () => model.AnalyzeAsync(project, parameters, default),
                WorkspaceScriptDiagnosticsFailureKind.Protocol);

            await VerifyBoundedProcessStopAsync(project, parameters, model, fakeRoot, cancel: false);
            await VerifyBoundedProcessStopAsync(project, parameters, model, fakeRoot, cancel: true);
            await VerifyUnconfirmedExitAsync(project, parameters, fakeRoot);
        }
        finally
        {
            Environment.SetEnvironmentVariable("KADATH_BEHAVIOR_TOOL", previousToolPath);
        }
    }

    private static async Task ExpectProtocolResponseFailureAsync(
        WorkspaceScriptDiagnosticsModel model,
        ProjectSessionInfo project,
        ScriptSourceAnalyzeParameters parameters,
        string fakeRoot,
        string name,
        byte[] response)
    {
        var responsePath = Path.Combine(fakeRoot, $"{name}.bin");
        File.WriteAllBytes(responsePath, response);
        var tool = WriteExecutable(fakeRoot, $"{name}.sh", $"#!/bin/sh\ncat >/dev/null\ncat '{responsePath}'\n");
        Environment.SetEnvironmentVariable("KADATH_BEHAVIOR_TOOL", tool);
        await ExpectDiagnosticsFailureAsync(
            () => model.AnalyzeAsync(project, parameters, default),
            WorkspaceScriptDiagnosticsFailureKind.Protocol);
    }

    private static async Task VerifyBoundedProcessStopAsync(
        ProjectSessionInfo project,
        ScriptSourceAnalyzeParameters parameters,
        WorkspaceScriptDiagnosticsModel model,
        string fakeRoot,
        bool cancel)
    {
        var prefix = cancel ? "cancel" : "timeout";
        var parentPidPath = Path.Combine(fakeRoot, $"{prefix}-parent.pid");
        var childPidPath = Path.Combine(fakeRoot, $"{prefix}-child.pid");
        var tool = WriteExecutable(fakeRoot, $"{prefix}-tool.sh", $"""
            #!/bin/sh
            printf '%s' "$$" > '{parentPidPath}'
            sleep 300 &
            child=$!
            printf '%s' "$child" > '{childPidPath}'
            wait "$child"
            """);
        Environment.SetEnvironmentVariable("KADATH_BEHAVIOR_TOOL", tool);
        using var cancellation = new CancellationTokenSource();
        var stopwatch = Stopwatch.StartNew();
        var analysis = model.AnalyzeAsync(project, parameters, cancellation.Token);
        await WaitUntilAsync(() => File.Exists(parentPidPath) && File.Exists(childPidPath), TimeSpan.FromSeconds(2));
        if (cancel) cancellation.Cancel();
        if (cancel)
        {
            try { await analysis; }
            catch (OperationCanceledException) { }
            if (!analysis.IsCanceled) throw new InvalidOperationException("Cancelled diagnostics process did not surface cancellation.");
        }
        else
        {
            await ExpectDiagnosticsFailureAsync(() => analysis, WorkspaceScriptDiagnosticsFailureKind.Timeout);
        }
        Require(stopwatch.Elapsed < TimeSpan.FromSeconds(4),
            $"{prefix} diagnostics cleanup exceeded the bounded verifier limit.");
        var parentPid = int.Parse(File.ReadAllText(parentPidPath, Encoding.UTF8));
        var childPid = int.Parse(File.ReadAllText(childPidPath, Encoding.UTF8));
        await WaitUntilAsync(
            () => !Directory.Exists($"/proc/{parentPid}") && !Directory.Exists($"/proc/{childPid}"),
            TimeSpan.FromSeconds(2));
    }

    private static async Task VerifyUnconfirmedExitAsync(
        ProjectSessionInfo project,
        ScriptSourceAnalyzeParameters parameters,
        string fakeRoot)
    {
        var parentPidPath = Path.Combine(fakeRoot, "cleanup-parent.pid");
        var childPidPath = Path.Combine(fakeRoot, "cleanup-child.pid");
        var tool = WriteExecutable(fakeRoot, "cleanup-tool.sh", $"""
            #!/bin/sh
            printf '%s' "$$" > '{parentPidPath}'
            sleep 300 &
            child=$!
            printf '%s' "$child" > '{childPidPath}'
            wait "$child"
            """);
        Environment.SetEnvironmentVariable("KADATH_BEHAVIOR_TOOL", tool);
        var processControl = new UnconfirmedExitProcessControl();
        var model = new WorkspaceScriptDiagnosticsModel(processControl);
        var analysis = model.AnalyzeAsync(project, parameters, default);
        await WaitUntilAsync(() => File.Exists(parentPidPath) && File.Exists(childPidPath), TimeSpan.FromSeconds(2));
        await ExpectDiagnosticsFailureAsync(() => analysis, WorkspaceScriptDiagnosticsFailureKind.Cleanup);
        Require(processControl.KillObserved, "Cleanup failure verifier did not reach the process-tree kill boundary.");
        var parentPid = int.Parse(File.ReadAllText(parentPidPath, Encoding.UTF8));
        var childPid = int.Parse(File.ReadAllText(childPidPath, Encoding.UTF8));
        await WaitUntilAsync(
            () => !Directory.Exists($"/proc/{parentPid}") && !Directory.Exists($"/proc/{childPid}"),
            TimeSpan.FromSeconds(2));
    }

    private sealed class UnconfirmedExitProcessControl : WorkspaceScriptDiagnosticsModel.IProcessControl
    {
        private int _waitCount;

        internal bool KillObserved { get; private set; }

        public async Task<bool> WaitForExitAsync(Process process, TimeSpan timeout)
        {
            _ = timeout;
            if (Interlocked.Increment(ref _waitCount) == 1) return false;
            try { await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(2)); }
            catch { }
            return false;
        }

        public void KillTree(Process process)
        {
            KillObserved = true;
            process.Kill(entireProcessTree: true);
        }
    }

    private static byte[] CreateResponseFrame(byte[] json)
    {
        var frame = new byte[12 + json.Length];
        "KLAR"u8.CopyTo(frame);
        BinaryPrimitives.WriteUInt32LittleEndian(frame.AsSpan(4, 4), 1);
        BinaryPrimitives.WriteUInt32LittleEndian(frame.AsSpan(8, 4), checked((uint)json.Length));
        json.CopyTo(frame, 12);
        return frame;
    }

    private static string WriteExecutable(string root, string name, string contents)
    {
        if (!OperatingSystem.IsLinux())
            throw new PlatformNotSupportedException("Diagnostics process cleanup verification requires Linux.");
        var path = Path.Combine(root, name);
        File.WriteAllText(path, contents, new UTF8Encoding(false));
        File.SetUnixFileMode(path,
            UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        return path;
    }

    private static async Task<byte[]> ReadAllBytesAsync(Stream stream)
    {
        using var output = new MemoryStream();
        await stream.CopyToAsync(output);
        return output.ToArray();
    }

    private static async Task WaitUntilAsync(Func<bool> predicate, TimeSpan timeout)
    {
        var deadline = DateTimeOffset.UtcNow + timeout;
        while (!predicate())
        {
            if (DateTimeOffset.UtcNow >= deadline) throw new TimeoutException("Diagnostics process verifier timed out.");
            await Task.Delay(20);
        }
    }

    private static async Task ExpectDiagnosticsFailureAsync(
        Func<Task> action,
        WorkspaceScriptDiagnosticsFailureKind kind)
    {
        try { await action(); }
        catch (WorkspaceScriptDiagnosticsException exception) when (exception.Kind == kind) { return; }
        throw new InvalidOperationException($"Expected WorkspaceScriptDiagnosticsException with kind {kind}.");
    }

    private static string ProjectIdentity(string projectDirectory)
    {
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        foreach (var path in Directory.EnumerateFiles(projectDirectory, "*", SearchOption.AllDirectories).OrderBy(value => value, StringComparer.Ordinal))
        {
            var relative = Path.GetRelativePath(projectDirectory, path).Replace('\\', '/');
            hash.AppendData(Encoding.UTF8.GetBytes(relative));
            hash.AppendData([0]);
            hash.AppendData(File.ReadAllBytes(path));
        }
        return Convert.ToHexString(hash.GetHashAndReset());
    }

    private static string Hash(string value) =>
        Convert.ToHexString(SHA256.HashData(new UTF8Encoding(false, true).GetBytes(value))).ToLowerInvariant();

    private static void VerifyInvalidManifestRetainsDependencyWatch(string manifestPath, string sourcePath)
    {
        File.WriteAllText(sourcePath, ChangedLuau, new UTF8Encoding(false));
        var tracker = WorkspaceScriptDependencySet.CreateRevisionTracker(manifestPath);
        _ = tracker.ComputeRevision();
        var manifest = File.ReadAllBytes(manifestPath);
        File.WriteAllText(manifestPath, "{", new UTF8Encoding(false));
        var invalidManifestRevision = tracker.ComputeRevision();
        File.AppendAllText(sourcePath, "\n-- retained dependency changed\n", new UTF8Encoding(false));
        var invalidDependencyRevision = tracker.ComputeRevision();
        Require(invalidManifestRevision.StartsWith("invalid:", StringComparison.Ordinal)
            && invalidDependencyRevision.StartsWith("invalid:", StringComparison.Ordinal)
            && invalidDependencyRevision != invalidManifestRevision,
            "Invalid manifest observation discarded the last validated dependency watch set.");
        File.WriteAllBytes(manifestPath, manifest);
    }

    private static async Task VerifyDependencySourceRecheckAsync(string root)
    {
        var project = CreateProject(root);
        var sourcePath = Path.Combine(project.ProjectDirectory, "scripts", "patrol.luau");
        var model = new WorkspacePublicationModel(phase =>
        {
            if (phase == WorkspacePublicationPhase.AfterStaging)
                File.AppendAllText(sourcePath, "\n-- changed during publication\n", new UTF8Encoding(false));
        });
        await ExpectFailureAsync(
            () => model.BakeAsync(project, new BakeStartParameters("Both", "debug"), default),
            WorkspacePublicationFailureKind.SourceChanged);
        var derived = Path.Combine(project.ProjectDirectory, ".kadath", "derived");
        Require(!Directory.EnumerateFiles(derived).Any(path => path.EndsWith(".scene", StringComparison.Ordinal)
            || path.EndsWith(".script", StringComparison.Ordinal)
            || Path.GetFileName(path) == ".live-bake.manifest.json"),
            "Changed Luau source exposed a partially committed publication.");
        RequireNoTemporaries(derived);
    }

    private static ProjectSessionInfo CreateProject(string root)
    {
        var projectDirectory = Path.Combine(root, "bin", "projects", "demo");
        Directory.CreateDirectory(Path.Combine(projectDirectory, "scripts"));
        File.WriteAllText(Path.Combine(projectDirectory, "scene.json"), SceneJson, Encoding.UTF8);
        File.WriteAllText(Path.Combine(projectDirectory, "script.json"), ScriptManifestJson, Encoding.UTF8);
        File.WriteAllText(Path.Combine(projectDirectory, "scripts", "patrol.luau"), InitialLuau, new UTF8Encoding(false));
        File.WriteAllText(Path.Combine(projectDirectory, "preview.json"),
            $$$"""{"schemaVersion":1,"runtime":{"executable":"{{{VerifierPlatform.RuntimeRelativePath}}}","workingDirectory":"bin","arguments":["--scene","projects/demo/scene.json","--script","projects/demo/script.json"]}}""",
            Encoding.UTF8);
        File.WriteAllBytes(Path.Combine(root, VerifierPlatform.RuntimeRelativePath), [0]);
        return new ProjectSessionInfo(root, "demo", projectDirectory,
            Path.Combine(projectDirectory, "scene.json"),
            Path.Combine(projectDirectory, "script.json"),
            Path.Combine(projectDirectory, "preview.json"), 1);
    }

    private static string ResolveBehaviorTool()
    {
        var overridePath = Environment.GetEnvironmentVariable("KADATH_BEHAVIOR_TOOL");
        if (!string.IsNullOrWhiteSpace(overridePath) && File.Exists(overridePath)) return Path.GetFullPath(overridePath);
        var executable = OperatingSystem.IsWindows() ? "kadath-behavior-tool.exe" : "kadath-behavior-tool";
        var candidate = Path.Combine(Directory.GetCurrentDirectory(), "zig-out", "behavior-tools", executable);
        if (File.Exists(candidate)) return candidate;
        throw new InvalidOperationException("Native Behavior Tool is missing; run zig build install-behavior-script-tool --prefix zig-out.");
    }

    private static async Task ExpectFailureAsync(Func<Task> action, WorkspacePublicationFailureKind kind)
    {
        try { await action(); }
        catch (WorkspacePublicationException exception) when (exception.Kind == kind) { return; }
        throw new InvalidOperationException($"Expected WorkspacePublicationException with kind {kind}.");
    }

    private static void RequireNoTemporaries(string derived) =>
        Require(!Directory.EnumerateFileSystemEntries(derived).Any(path => Path.GetFileName(path).Contains(".publication.", StringComparison.Ordinal)),
            "Publication left staging or recovery files.");

    private static void Expect<T>(Action action) where T : Exception
    {
        try { action(); }
        catch (T) { return; }
        throw new InvalidOperationException($"Expected {typeof(T).Name}.");
    }

    private static bool IsSha256(string value) => value.Length == 64 && value.All(Uri.IsHexDigit);
    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private const string ScriptManifestJson = """
    {
      "schemaVersion": 2,
      "scripts": [
        { "scriptId": 1, "source": "scripts/patrol.luau" }
      ]
    }
    """;

    private const string LegacyScriptJson = """
    {
      "schemaVersion": 1,
      "instructions": [
        { "hook": "on_start", "op": "set_goal_position", "value": [680.0, 200.0] },
        { "hook": "fixed_update", "op": "move_goal_velocity", "value": [-12.0, 0.0] }
      ]
    }
    """;

    private const string InitialLuau = """
    --!strict

    local speed = kadath.parameter.number("speed", {
        default = 80,
        min = 0,
        max = 1000,
    })

    return {
        fixed_update = function(self: Kadath.Object, dt: number)
            self:translate(speed * dt, 0)
        end,
    }
    """;

    private const string ChangedLuau = """
    --!strict

    local speed = kadath.parameter.number("speed", {
        default = 80,
        min = 0,
        max = 1000,
    })

    return {
        fixed_update = function(self: Kadath.Object, dt: number)
            self:translate(speed * dt * 0.5, 0)
        end,
    }
    """;

    private const string InvalidLuau = """
    --!strict
    return {
        fixed_update = function(
    }
    """;

    private const string SceneJson = """
    {
      "schemaVersion": 3,
      "textures": [
        { "textureId": 1, "artifact": "assets/renderer2d/test.texture" },
        { "textureId": 2, "artifact": "assets/renderer2d/goal.texture" },
        { "textureId": 3, "artifact": "assets/renderer2d/goal.texture" }
      ],
      "player": { "position": [312.0, 130.0], "size": [320.0, 240.0], "color": [1.0, 1.0, 1.0, 1.0], "moveSpeed": 180.0, "textureId": 1 },
      "goal": { "position": [700.0, 200.0], "size": [96.0, 96.0], "color": [1.0, 0.75, 0.1, 1.0], "textureId": 2 },
      "hazard": { "position": [650.0, 280.0], "size": [96.0, 96.0], "color": [0.95, 0.2, 0.2, 1.0], "patrolMinY": 245.0, "patrolMaxY": 330.0, "patrolSpeed": 80.0, "textureId": 3 }
    }
    """;
}
