using System.Windows.Input;
using Kadath.Editor.Protocol;
using Kadath.Editor.ViewModels;

namespace Kadath.Editor.Avalonia.ViewModels;

/// <summary>
/// Scene 级 Camera2D 草稿；它独立于 Scene Object 与 Tilemap 身份域。
/// </summary>
public sealed class SceneCameraDraftViewModel : ObservableObject
{
    private string _originX = "0";
    private string _originY = "0";
    private string _zoom = "1";

    public SceneCameraDraftViewModel()
    {
        ResetCommand = new DelegateUiCommand(Reset);
    }

    public string OriginX { get => _originX; set => SetProperty(ref _originX, value); }
    public string OriginY { get => _originY; set => SetProperty(ref _originY, value); }
    public string Zoom { get => _zoom; set => SetProperty(ref _zoom, value); }
    public ICommand ResetCommand { get; }

    public void Load(ProjectModelSceneCamera? camera)
    {
        var origin = camera?.Origin is { Length: 2 } value ? value : [0d, 0d];
        OriginX = Format(origin[0]);
        OriginY = Format(origin[1]);
        Zoom = Format(camera?.Zoom ?? 1);
    }

    public void Reset()
    {
        OriginX = "0";
        OriginY = "0";
        Zoom = "1";
    }

    // 使用 round-trip 格式，未编辑的合法 f32 值不能因 UI 投影而被静默截断。
    private static string Format(double value) => value.ToString("R", System.Globalization.CultureInfo.InvariantCulture);
}
