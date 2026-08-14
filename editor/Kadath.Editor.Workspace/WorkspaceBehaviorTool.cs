using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;

namespace Kadath.Editor.Workspace;

internal static class WorkspaceBehaviorTool
{
    private const int MaxDiagnosticCharacters = 8192;

    internal static byte[] Build(
        string packageRoot,
        string scriptPath,
        WorkspaceScriptSourceSnapshot snapshot,
        CancellationToken cancellationToken)
    {
        if (!snapshot.IsBehaviorPackage) throw new ArgumentException("Behavior Tool requires Script source schema v2.", nameof(snapshot));
        var projectDirectory = Path.GetDirectoryName(Path.GetFullPath(scriptPath))
            ?? throw new InvalidDataException("Script source has no project directory.");
        if (!Path.GetFileName(scriptPath).Equals("script.json", StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Behavior Tool requires the manifest name script.json.");

        var toolPath = ResolveToolPath(packageRoot);
        var outputPath = Path.Combine(Path.GetTempPath(), $"kadath-behavior-{Guid.NewGuid():N}.script");
        try
        {
            var result = Run(toolPath, projectDirectory, outputPath, cancellationToken);
            if (result.ExitCode != 0)
                throw new InvalidDataException($"Behavior Tool failed with exit code {result.ExitCode}: {Bounded(result.StandardError)}");
            if (!File.Exists(outputPath)) throw new InvalidDataException("Behavior Tool succeeded without producing an artifact.");

            var artifact = File.ReadAllBytes(outputPath);
            var info = WorkspaceScriptCodec.ValidateArtifact(artifact);
            var fields = ParseFields(result.StandardOutput);
            Require(fields, "status", "succeeded");
            Require(fields, "format", info.Format);
            Require(fields, "source_revision", snapshot.Revision);
            Require(fields, "artifact_revision", info.Sha256);
            RequireLong(fields, "artifact_bytes", info.Bytes);
            RequirePositiveInt(fields, "entry_count");
            RequireNonEmpty(fields, "toolchain_identity");
            if (fields.Count != 7) throw new InvalidDataException("Behavior Tool returned unsupported metadata fields.");
            return artifact;
        }
        finally
        {
            try { if (File.Exists(outputPath)) File.Delete(outputPath); }
            catch { }
        }
    }

    internal static string ResolveToolPath(string packageRoot)
    {
        var overridePath = Environment.GetEnvironmentVariable("KADATH_BEHAVIOR_TOOL");
        var executableName = OperatingSystem.IsWindows() ? "kadath-behavior-tool.exe" : "kadath-behavior-tool";
        var candidates = string.IsNullOrWhiteSpace(overridePath)
            ? new[]
            {
                Path.Combine(packageRoot, "behavior-tools", executableName),
                Path.Combine(packageRoot, "bin", "behavior-tools", executableName)
            }
            : new[] { Path.GetFullPath(overridePath) };
        foreach (var candidate in candidates)
        {
            var fullPath = Path.GetFullPath(candidate);
            if (!File.Exists(fullPath)) continue;
            WorkspaceProjectValidator.RejectReparsePoint(fullPath, "Behavior Tool executable");
            return fullPath;
        }
        throw new InvalidDataException($"Behavior Tool executable was not found. Checked: {string.Join(", ", candidates)}.");
    }

    private static ProcessResult Run(string toolPath, string projectDirectory, string outputPath, CancellationToken cancellationToken)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = toolPath,
            WorkingDirectory = projectDirectory,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        startInfo.ArgumentList.Add("--project-root");
        startInfo.ArgumentList.Add(projectDirectory);
        startInfo.ArgumentList.Add("--manifest");
        startInfo.ArgumentList.Add("script.json");
        startInfo.ArgumentList.Add("--output");
        startInfo.ArgumentList.Add(outputPath);

        using var process = new Process { StartInfo = startInfo };
        try
        {
            if (!process.Start()) throw new InvalidDataException("Behavior Tool process did not start.");
            var stdout = process.StandardOutput.ReadToEndAsync();
            var stderr = process.StandardError.ReadToEndAsync();
            try
            {
                process.WaitForExitAsync(cancellationToken).GetAwaiter().GetResult();
            }
            catch (OperationCanceledException)
            {
                TryKill(process);
                throw;
            }
            return new ProcessResult(process.ExitCode, stdout.GetAwaiter().GetResult(), stderr.GetAwaiter().GetResult());
        }
        catch (Win32Exception exception)
        {
            throw new InvalidDataException($"Failed to start Behavior Tool: {exception.Message}", exception);
        }
    }

    private static Dictionary<string, string> ParseFields(string output)
    {
        var fields = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var line in output.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries))
        {
            var separator = line.IndexOf('=');
            if (separator <= 0 || separator == line.Length - 1) throw new InvalidDataException("Behavior Tool returned malformed metadata.");
            if (!fields.TryAdd(line[..separator], line[(separator + 1)..])) throw new InvalidDataException("Behavior Tool returned duplicate metadata fields.");
        }
        return fields;
    }

    private static void Require(IReadOnlyDictionary<string, string> fields, string name, string expected)
    {
        if (!fields.TryGetValue(name, out var value) || !value.Equals(expected, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException($"Behavior Tool metadata mismatch: {name}.");
    }

    private static void RequireLong(IReadOnlyDictionary<string, string> fields, string name, long expected)
    {
        if (!fields.TryGetValue(name, out var value)
            || !long.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out var parsed)
            || parsed != expected)
        {
            throw new InvalidDataException($"Behavior Tool metadata mismatch: {name}.");
        }
    }

    private static void RequirePositiveInt(IReadOnlyDictionary<string, string> fields, string name)
    {
        if (!fields.TryGetValue(name, out var value)
            || !int.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out var parsed)
            || parsed is < 1 or > 16)
        {
            throw new InvalidDataException($"Behavior Tool metadata mismatch: {name}.");
        }
    }

    private static void RequireNonEmpty(IReadOnlyDictionary<string, string> fields, string name)
    {
        if (!fields.TryGetValue(name, out var value) || string.IsNullOrWhiteSpace(value))
            throw new InvalidDataException($"Behavior Tool metadata mismatch: {name}.");
    }

    private static string Bounded(string value)
    {
        var trimmed = value.Trim();
        return trimmed.Length <= MaxDiagnosticCharacters ? trimmed : trimmed[..MaxDiagnosticCharacters];
    }

    private static void TryKill(Process process)
    {
        try
        {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
            process.WaitForExit();
        }
        catch { }
    }

    private sealed record ProcessResult(int ExitCode, string StandardOutput, string StandardError);
}
