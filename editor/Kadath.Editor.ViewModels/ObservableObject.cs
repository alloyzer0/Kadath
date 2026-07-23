using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace Kadath.Editor.ViewModels;

/// <summary>
/// 不依赖 Avalonia 的最小绑定基类；任何桌面 UI 都可以直接订阅 PropertyChanged。
/// </summary>
public abstract class ObservableObject : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    protected bool SetProperty<T>(ref T storage, T value, [CallerMemberName] string? propertyName = null)
    {
        if (EqualityComparer<T>.Default.Equals(storage, value)) { return false; }
        storage = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
        return true;
    }

    protected void RaisePropertyChanged([CallerMemberName] string? propertyName = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
}

public interface IEditorViewDispatcher
{
    Task InvokeAsync(Action action);
}

/// <summary>
/// 测试和非 UI 宿主使用的同步 dispatcher。
/// </summary>
public sealed class InlineEditorViewDispatcher : IEditorViewDispatcher
{
    public Task InvokeAsync(Action action)
    {
        action();
        return Task.CompletedTask;
    }
}

/// <summary>
/// Avalonia 可通过当前 UI SynchronizationContext 注入此适配器，ViewModel 本身不引用 Avalonia。
/// </summary>
public sealed class SynchronizationContextEditorViewDispatcher : IEditorViewDispatcher
{
    private readonly SynchronizationContext _context;

    public SynchronizationContextEditorViewDispatcher(SynchronizationContext context) => _context = context;

    public Task InvokeAsync(Action action)
    {
        if (SynchronizationContext.Current == _context)
        {
            action();
            return Task.CompletedTask;
        }

        var completion = new TaskCompletionSource<object?>(TaskCreationOptions.RunContinuationsAsynchronously);
        _context.Post(_ =>
        {
            try
            {
                action();
                completion.TrySetResult(null);
            }
            catch (Exception exception) { completion.TrySetException(exception); }
        }, null);
        return completion.Task;
    }
}
