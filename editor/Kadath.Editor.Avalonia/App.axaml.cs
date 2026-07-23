using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;
using Kadath.Editor.Avalonia.Client;
using Kadath.Editor.Avalonia.ViewModels;
using Kadath.Editor.Avalonia.Views;
using Kadath.Editor.Client;
using Kadath.Editor.ViewModels;

namespace Kadath.Editor.Avalonia;

public sealed partial class App : Application
{
    public override void Initialize() => AvaloniaXamlLoader.Load(this);

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            // 组合根只负责依赖装配；窗口和 ViewModel 不自行构造或定位 Editor Service。
            var options = EditorRpcClientOptions.CreateDefault();
            // Avalonia 只组装 shared Client + shared WorkspaceViewModel，不重新实现 RPC 协议。
            var transport = new StdioEditorRpcTransport(new EditorRpcProcessOptions(
                options.DotNetExecutable,
                [options.ServiceAssemblyPath, "--kadath-root", options.KadathRoot],
                options.KadathRoot));
            var client = new EditorRpcClient(transport, "kadath-editor-avalonia", "1");
            var workspace = new EditorWorkspaceViewModel(client, new AvaloniaEditorViewDispatcher());
            var viewModel = new AvaloniaEditorViewModel(workspace, new AvaloniaEditorViewDispatcher(), options.DefaultPackageRoot, options.EffectiveHandshakeTimeout);
            var window = new MainWindow { DataContext = viewModel };

            window.Opened += async (_, _) => await viewModel.InitializeAsync();
            var closing = false;
            window.Closing += async (_, args) =>
            {
                if (closing) { return; }
                args.Cancel = true;
                try
                {
                    await viewModel.DisposeAsync();
                }
                finally
                {
                    closing = true;
                    window.Close();
                }
            };
            desktop.MainWindow = window;
        }

        base.OnFrameworkInitializationCompleted();
    }
}
