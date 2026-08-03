using Kadath.Editor.Core;
using Kadath.Editor.Workspace;

namespace Kadath.Editor.Service;

internal static class Program
{
    public static async Task<int> Main(string[] args)
    {
        try
        {
            var kadathRoot = ResolveKadathRoot(args);
            await using var session = new EditorSession(new PowerShellEditorBackend(
                kadathRoot,
                new WorkspaceProjectLifecycleModel(),
                new WorkspaceReadModel(),
                new WorkspaceAuthoringModel()));
            await using var preview = new PreviewProcessController(kadathRoot);
            var host = new EditorRpcHost(session, preview, Console.In, Console.Out);
            return await host.RunAsync();
        }
        catch (Exception exception)
        {
            await Console.Error.WriteLineAsync(exception.ToString());
            return 1;
        }
    }

    private static string ResolveKadathRoot(string[] args)
    {
        for (var index = 0; index < args.Length; index++)
        {
            if (args[index] == "--kadath-root" && index + 1 < args.Length)
            {
                return ValidateKadathRoot(args[index + 1]);
            }
        }

        var candidate = new DirectoryInfo(Environment.CurrentDirectory);
        while (candidate is not null)
        {
            if (File.Exists(Path.Combine(candidate.FullName, "tools", "editor-preview.ps1")))
            {
                return candidate.FullName;
            }

            candidate = candidate.Parent;
        }

        throw new InvalidOperationException("Kadath root was not found; pass --kadath-root <path>.");
    }

    private static string ValidateKadathRoot(string path)
    {
        var fullPath = Path.GetFullPath(path);
        if (!File.Exists(Path.Combine(fullPath, "tools", "editor-preview.ps1")))
        {
            throw new DirectoryNotFoundException($"Kadath root does not contain tools/editor-preview.ps1: {fullPath}");
        }

        return fullPath;
    }
}
