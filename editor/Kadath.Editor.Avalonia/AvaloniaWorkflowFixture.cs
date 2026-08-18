using System.Text;
using System.Text.Json;
using Kadath.Editor.Verification;

namespace Kadath.Editor.Avalonia;

internal sealed class AvaloniaWorkflowFixture : IDisposable
{
    private readonly string _projectsRoot;
    private readonly string _openProjectDirectory;
    private readonly string _createdProjectDirectory;
    private readonly List<OwnedProjectDirectory> _ownedProjectDirectories = [];
    private bool _disposed;

    private AvaloniaWorkflowFixture(
        string kadathRoot,
        string packageRoot,
        string projectsRoot,
        string openProjectName,
        string createdProjectName,
        string openProjectDirectory,
        string createdProjectDirectory)
    {
        KadathRoot = kadathRoot;
        PackageRoot = packageRoot;
        _projectsRoot = projectsRoot;
        OpenProjectName = openProjectName;
        CreatedProjectName = createdProjectName;
        _openProjectDirectory = openProjectDirectory;
        _createdProjectDirectory = createdProjectDirectory;
    }

    internal string KadathRoot { get; }
    internal string PackageRoot { get; }
    internal string OpenProjectName { get; }
    internal string CreatedProjectName { get; }

    internal static AvaloniaWorkflowFixture Create(string kadathRootArgument, string packageRootArgument)
    {
        var kadathRoot = ResolveExistingDirectory(kadathRootArgument, "Kadath root");
        var packageRoot = ResolveExistingDirectory(packageRootArgument, "Package root");
        var projectsRoot = Path.GetFullPath(Path.Combine(packageRoot, "bin", "projects"));
        Directory.CreateDirectory(projectsRoot);
        RejectReparseTree(projectsRoot, "Projects root");

        // Workspace 公共契约限制 48 个安全字符；GUID 已足以隔离并发 verifier。
        var suffix = Guid.NewGuid().ToString("N");
        var openProjectName = $"avopen_{suffix}";
        var createdProjectName = $"avcreate_{suffix}";
        var openProjectDirectory = ControlledProjectPath(projectsRoot, openProjectName);
        var createdProjectDirectory = ControlledProjectPath(projectsRoot, createdProjectName);
        foreach (var path in new[] { openProjectDirectory, createdProjectDirectory })
            if (File.Exists(path) || Directory.Exists(path))
                throw new IOException($"Avalonia workflow project already exists: {path}");

        var fixture = new AvaloniaWorkflowFixture(
            kadathRoot,
            packageRoot,
            projectsRoot,
            openProjectName,
            createdProjectName,
            openProjectDirectory,
            createdProjectDirectory);
        try
        {
            fixture.CreateOpenProject(openProjectDirectory);
            return fixture;
        }
        catch
        {
            fixture.Dispose();
            throw;
        }
    }

    internal static void VerifyCleanupOwnershipContract(string kadathRootArgument, string packageRootArgument)
    {
        // 此入口只由 native Windows owned workflow 调用；其它平台不宣告 File ID 证据。
        if (!OperatingSystem.IsWindows()) return;
        VerifyCleanupRejectsForeignReplacement(kadathRootArgument, packageRootArgument);
        VerifyCleanupRejectsReparseReplacement(kadathRootArgument, packageRootArgument);
    }

    private static void VerifyCleanupRejectsForeignReplacement(string kadathRootArgument, string packageRootArgument)
    {
        AvaloniaWorkflowFixture? fixture = null;
        string? movedOwnedDirectory = null;
        string? foreignSentinel = null;
        try
        {
            fixture = Create(kadathRootArgument, packageRootArgument);
            var ownedDirectory = fixture._openProjectDirectory;
            movedOwnedDirectory = $"{ownedDirectory}.detached-{Guid.NewGuid():N}";
            Directory.Move(ownedDirectory, movedOwnedDirectory);
            Directory.CreateDirectory(ownedDirectory);
            foreignSentinel = Path.Combine(ownedDirectory, "foreign.sentinel");
            File.WriteAllText(foreignSentinel, "foreign replacement must survive verifier cleanup");

            Exception? rejection = null;
            try { fixture.Dispose(); }
            catch (Exception exception) when (exception is IOException or InvalidOperationException)
            {
                rejection = exception;
            }

            if (rejection is null)
                throw new InvalidOperationException("Avalonia fixture cleanup accepted a same-path foreign directory replacement.");
            if (!File.Exists(foreignSentinel))
                throw new InvalidOperationException("Avalonia fixture cleanup deleted a foreign replacement sentinel.");
        }
        finally
        {
            fixture?.Dispose();
            if (foreignSentinel is not null)
            {
                var replacementDirectory = Path.GetDirectoryName(foreignSentinel)!;
                if (Directory.Exists(replacementDirectory)) Directory.Delete(replacementDirectory, recursive: true);
            }
            if (movedOwnedDirectory is not null && Directory.Exists(movedOwnedDirectory))
                Directory.Delete(movedOwnedDirectory, recursive: true);
        }
    }

    private static void VerifyCleanupRejectsReparseReplacement(string kadathRootArgument, string packageRootArgument)
    {
        AvaloniaWorkflowFixture? fixture = null;
        string? ownedDirectory = null;
        string? sentinel = null;
        try
        {
            fixture = Create(kadathRootArgument, packageRootArgument);
            ownedDirectory = fixture._openProjectDirectory;
            sentinel = Path.Combine(ownedDirectory, "owned.sentinel");
            File.WriteAllText(sentinel, "junction target must survive rejected cleanup");

            Exception? rejection = null;
            VerifierWindowsDirectoryLink.WithDirectoryReplacement(ownedDirectory, () =>
            {
                try { fixture.Dispose(); }
                catch (Exception exception) when (exception is IOException or InvalidOperationException)
                {
                    rejection = exception;
                }
            });

            if (rejection is null)
                throw new InvalidOperationException("Avalonia fixture cleanup accepted a reparse-backed owned directory path.");
            if (!File.Exists(sentinel))
                throw new InvalidOperationException("Avalonia fixture cleanup deleted a reparse target sentinel.");
        }
        finally
        {
            fixture?.Dispose();
            if (ownedDirectory is not null && Directory.Exists(ownedDirectory))
                Directory.Delete(ownedDirectory, recursive: true);
        }
    }

    internal void ClaimCreatedProject(string serviceProjectDirectory)
    {
        var candidate = Path.GetFullPath(serviceProjectDirectory);
        if (!candidate.Equals(_createdProjectDirectory, StringComparison.OrdinalIgnoreCase)
            || !Directory.Exists(_createdProjectDirectory))
            throw new IOException("Avalonia workflow cannot claim an unexpected or missing created project directory.");
        ClaimOwnedProjectDirectory(_createdProjectDirectory);
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        for (var index = _ownedProjectDirectories.Count - 1; index >= 0; index--)
        {
            var claim = _ownedProjectDirectories[index];
            var projectDirectory = claim.Path;
            if (!Directory.Exists(projectDirectory)) continue;
            var controlled = ControlledProjectPath(_projectsRoot, Path.GetFileName(projectDirectory));
            if (!controlled.Equals(projectDirectory, StringComparison.OrdinalIgnoreCase))
                throw new IOException("Refusing to clean an Avalonia workflow project outside package/bin/projects.");
            if (OperatingSystem.IsWindows())
            {
                var identity = claim.WindowsIdentity
                    ?? throw new InvalidOperationException("Owned Avalonia workflow project has no captured Windows directory identity.");
                using var deletionLease = identity.AcquireDeletionLease(projectDirectory);
                // lease 覆盖 File ID 复验、reparse 检查、子项清空和 root handle 删除。
                deletionLease.DeleteOwnedDirectoryTree();
            }
            else
            {
                // 非 Windows 不宣告 File ID 原子删除，只保留既有路径/reparse 防线。
                RejectReparseTree(projectDirectory, "Owned Avalonia workflow project");
                Directory.Delete(projectDirectory, recursive: true);
            }
        }
    }

    private void CreateOpenProject(string projectDirectory)
    {
        var sceneTemplate = ResolveExistingFile(
            Path.Combine(PackageRoot, "bin", "assets", "scenes", "preview.scene.json"),
            "Scene template");
        var scriptTemplate = ResolveExistingFile(
            Path.Combine(PackageRoot, "bin", "assets", "scripts", "preview.script.json"),
            "Script template");
        Directory.CreateDirectory(projectDirectory);
        // 创建目录后立即取得所有权；后续模板复制失败也只能回收这一 File ID 对应的对象。
        ClaimOwnedProjectDirectory(projectDirectory);
        File.Copy(sceneTemplate, Path.Combine(projectDirectory, "scene.json"), overwrite: false);
        File.Copy(scriptTemplate, Path.Combine(projectDirectory, "script.json"), overwrite: false);
        CopyScriptDependencies(scriptTemplate, projectDirectory);

        var preview = new
        {
            schemaVersion = 1,
            runtime = new
            {
                executable = OperatingSystem.IsWindows() ? "bin/kadath.exe" : "bin/kadath",
                workingDirectory = "bin",
                arguments = new[]
                {
                    "--scene", $"projects/{OpenProjectName}/scene.json",
                    "--script", $"projects/{OpenProjectName}/script.json"
                }
            }
        };
        File.WriteAllText(
            Path.Combine(projectDirectory, "preview.json"),
            JsonSerializer.Serialize(preview),
            new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
    }

    private void ClaimOwnedProjectDirectory(string projectDirectory)
    {
        if (_ownedProjectDirectories.Any(claim => claim.Path.Equals(projectDirectory, StringComparison.OrdinalIgnoreCase)))
            throw new InvalidOperationException($"Avalonia workflow project was already claimed: {projectDirectory}");
        RejectReparseTree(projectDirectory, "Owned Avalonia workflow project", inspectDescendants: false);
        // 共享 helper 明确只服务本任务的 Windows workflow；其它平台沿用既有路径/reparse 边界。
        var identity = OperatingSystem.IsWindows()
            ? VerifierWindowsDirectoryIdentity.Capture(projectDirectory)
            : (VerifierWindowsDirectoryIdentity?)null;
        _ownedProjectDirectories.Add(new OwnedProjectDirectory(projectDirectory, identity));
    }

    private void CopyScriptDependencies(string scriptTemplate, string projectDirectory)
    {
        using var document = JsonDocument.Parse(File.ReadAllBytes(scriptTemplate));
        var root = document.RootElement;
        var schemaVersion = root.GetProperty("schemaVersion").GetInt32();
        if (schemaVersion == 1) return;
        if (schemaVersion != 2) throw new InvalidDataException($"Unsupported workflow Script schema version: {schemaVersion}");

        var assetRoot = Path.GetFullPath(Path.Combine(PackageRoot, "bin", "assets"));
        foreach (var entry in root.GetProperty("scripts").EnumerateArray())
        {
            var source = entry.GetProperty("source").GetString()
                ?? throw new InvalidDataException("Workflow Script dependency source is missing.");
            if (!IsSafeScriptSource(source))
                throw new InvalidDataException($"Workflow fixture received an unsafe Script source path: {source}");
            var sourcePath = ContainedPath(assetRoot, source, "Package Script dependency");
            var destinationPath = ContainedPath(projectDirectory, source, "Project Script dependency");
            ResolveExistingFile(sourcePath, "Package Script dependency");
            Directory.CreateDirectory(Path.GetDirectoryName(destinationPath)!);
            File.Copy(sourcePath, destinationPath, overwrite: false);
        }
    }

    private static bool IsSafeScriptSource(string source) =>
        source.StartsWith("scripts/", StringComparison.Ordinal) &&
        source.EndsWith(".luau", StringComparison.Ordinal) &&
        !source.Contains("..", StringComparison.Ordinal) &&
        !source.Contains('\\') &&
        !Path.IsPathRooted(source);

    private static string ControlledProjectPath(string projectsRoot, string projectName)
    {
        if (string.IsNullOrWhiteSpace(projectName) || projectName is "." or ".." ||
            projectName.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 ||
            projectName.Contains(Path.DirectorySeparatorChar) || projectName.Contains(Path.AltDirectorySeparatorChar))
            throw new InvalidDataException("Avalonia workflow project name is unsafe.");
        return ContainedPath(projectsRoot, projectName, "Avalonia workflow project");
    }

    private static string ContainedPath(string root, string relativePath, string name)
    {
        var canonicalRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var candidate = Path.GetFullPath(Path.Combine(canonicalRoot, relativePath.Replace('/', Path.DirectorySeparatorChar)));
        var prefix = canonicalRoot + Path.DirectorySeparatorChar;
        if (!candidate.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            throw new IOException($"{name} escaped its controlled root.");
        return candidate;
    }

    private static string ResolveExistingDirectory(string path, string name)
    {
        var full = Path.GetFullPath(path);
        if (!Directory.Exists(full)) throw new DirectoryNotFoundException($"{name} does not exist: {full}");
        RejectReparseTree(full, name, inspectDescendants: false);
        return full;
    }

    private static string ResolveExistingFile(string path, string name)
    {
        var full = Path.GetFullPath(path);
        if (!File.Exists(full)) throw new FileNotFoundException($"{name} does not exist.", full);
        if ((File.GetAttributes(full) & FileAttributes.ReparsePoint) != 0)
            throw new IOException($"{name} cannot be a reparse point: {full}");
        return full;
    }

    private static void RejectReparseTree(string root, string name, bool inspectDescendants = true)
    {
        if ((File.GetAttributes(root) & FileAttributes.ReparsePoint) != 0)
            throw new IOException($"{name} cannot be a reparse point: {root}");
        if (!inspectDescendants) return;
        foreach (var path in Directory.EnumerateFileSystemEntries(root, "*", SearchOption.AllDirectories))
            if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
                throw new IOException($"{name} cannot contain a reparse point: {path}");
    }

    private sealed record OwnedProjectDirectory(
        string Path,
        VerifierWindowsDirectoryIdentity? WindowsIdentity);
}
