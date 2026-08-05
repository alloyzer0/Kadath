using Kadath.Editor.Core;
using Kadath.Editor.Workspace;

namespace Kadath.Editor.Service;

internal static class Program
{
    public static async Task<int> Main(string[] args)
    {
        try
        {
            _ = args;
            var publicationModel = new WorkspacePublicationModel();
            await using var session = new EditorSession(new WorkspaceEditorBackend(
                new WorkspaceProjectLifecycleModel(),
                new WorkspaceReadModel(),
                new WorkspaceAuthoringModel(),
                publicationModel,
                new WorkspaceTextureImportModel()));
            await using var preview = new PreviewProcessController(new WorkspacePreviewModel(publicationModel));
            var host = new EditorRpcHost(session, preview, Console.In, Console.Out);
            return await host.RunAsync();
        }
        catch (Exception exception)
        {
            await Console.Error.WriteLineAsync(exception.ToString());
            return 1;
        }
    }

}
