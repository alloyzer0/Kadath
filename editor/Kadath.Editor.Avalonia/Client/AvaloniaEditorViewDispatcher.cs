using Avalonia.Threading;
using Kadath.Editor.ViewModels;

namespace Kadath.Editor.Avalonia.Client;

/// <summary>
/// 仅在 Avalonia 边界引用 Dispatcher；共享 ViewModel 和 RPC client 不依赖 UI 框架。
/// </summary>
public sealed class AvaloniaEditorViewDispatcher : IEditorViewDispatcher
{
    public Task InvokeAsync(Action action)
    {
        if (Dispatcher.UIThread.CheckAccess())
        {
            action();
            return Task.CompletedTask;
        }

        var completion = new TaskCompletionSource<object?>(TaskCreationOptions.RunContinuationsAsynchronously);
        Dispatcher.UIThread.Post(() =>
        {
            try
            {
                action();
                completion.TrySetResult(null);
            }
            catch (Exception exception)
            {
                completion.TrySetException(exception);
            }
        });
        return completion.Task;
    }
}
