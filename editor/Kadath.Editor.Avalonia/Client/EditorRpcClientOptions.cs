namespace Kadath.Editor.Avalonia.Client;

public sealed record EditorRpcClientOptions(
    string KadathRoot,
    string ServiceAssemblyPath,
    string DotNetExecutable = "dotnet",
    TimeSpan? HandshakeTimeout = null)
{
    public TimeSpan EffectiveHandshakeTimeout => HandshakeTimeout ?? TimeSpan.FromSeconds(10);
    public string DefaultPackageRoot => Directory.Exists(Path.Combine(KadathRoot, "zig-out")) ? Path.Combine(KadathRoot, "zig-out") : KadathRoot;

    public static EditorRpcClientOptions CreateDefault()
    {
        var kadathRoot = Environment.GetEnvironmentVariable("KADATH_ROOT");
        if (string.IsNullOrWhiteSpace(kadathRoot))
        {
            kadathRoot = FindKadathRoot(Environment.CurrentDirectory)
                ?? FindKadathRoot(AppContext.BaseDirectory)
                ?? Environment.CurrentDirectory;
        }

        kadathRoot = Path.GetFullPath(kadathRoot);
        var servicePath = Environment.GetEnvironmentVariable("KADATH_EDITOR_SERVICE");
        if (string.IsNullOrWhiteSpace(servicePath))
        {
            var debugPath = Path.Combine(kadathRoot, "editor", "Kadath.Editor.Service", "bin", "Debug", "net8.0", "Kadath.Editor.Service.dll");
            var releasePath = Path.Combine(kadathRoot, "editor", "Kadath.Editor.Service", "bin", "Release", "net8.0", "Kadath.Editor.Service.dll");
            servicePath = File.Exists(debugPath) ? debugPath : releasePath;
        }

        return new EditorRpcClientOptions(kadathRoot, Path.GetFullPath(servicePath));
    }

    private static string? FindKadathRoot(string startPath)
    {
        var candidate = new DirectoryInfo(Path.GetFullPath(startPath));
        while (candidate is not null)
        {
            if (File.Exists(Path.Combine(candidate.FullName, "build.zig"))
                && File.Exists(Path.Combine(candidate.FullName, "editor", "Kadath.Editor.sln")))
            {
                return candidate.FullName;
            }

            candidate = candidate.Parent;
        }

        return null;
    }
}
