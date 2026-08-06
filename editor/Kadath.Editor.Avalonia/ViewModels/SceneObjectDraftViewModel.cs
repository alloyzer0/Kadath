using System.Collections.ObjectModel;
using Kadath.Editor.Protocol;
using Kadath.Editor.ViewModels;

namespace Kadath.Editor.Avalonia.ViewModels;

public sealed class SceneObjectDraftViewModel : ObservableObject
{
    private string _objectId;
    private string _positionX;
    private string _positionY;
    private string _sizeX;
    private string _sizeY;
    private string _colorR;
    private string _colorG;
    private string _colorB;
    private string _colorA;
    private string _textureIdText;
    private string _moveSpeed;
    private string _patrolMinY;
    private string _patrolMaxY;
    private string _patrolSpeed;

    public SceneObjectDraftViewModel(
        string originalObjectId,
        string objectId,
        string kind,
        string positionX,
        string positionY,
        string sizeX,
        string sizeY,
        string colorR,
        string colorG,
        string colorB,
        string colorA,
        string textureIdText,
        string moveSpeed,
        string patrolMinY,
        string patrolMaxY,
        string patrolSpeed,
        ObservableCollection<string> textureIds)
    {
        OriginalObjectId = originalObjectId;
        _objectId = objectId;
        Kind = kind;
        _positionX = positionX;
        _positionY = positionY;
        _sizeX = sizeX;
        _sizeY = sizeY;
        _colorR = colorR;
        _colorG = colorG;
        _colorB = colorB;
        _colorA = colorA;
        _textureIdText = textureIdText;
        _moveSpeed = moveSpeed;
        _patrolMinY = patrolMinY;
        _patrolMaxY = patrolMaxY;
        _patrolSpeed = patrolSpeed;
        TextureIds = textureIds;
    }

    public string OriginalObjectId { get; }
    public string Kind { get; }
    public ObservableCollection<string> TextureIds { get; }
    public bool IsPlayer => Kind == "player";
    public bool IsPatrolHazard => Kind == "patrol_hazard";
    public string DisplayName => $"{ObjectId} [{Kind}]";

    public string ObjectId
    {
        get => _objectId;
        set
        {
            if (!SetProperty(ref _objectId, value)) { return; }
            RaisePropertyChanged(nameof(DisplayName));
        }
    }

    public string PositionX { get => _positionX; set => SetProperty(ref _positionX, value); }
    public string PositionY { get => _positionY; set => SetProperty(ref _positionY, value); }
    public string SizeX { get => _sizeX; set => SetProperty(ref _sizeX, value); }
    public string SizeY { get => _sizeY; set => SetProperty(ref _sizeY, value); }
    public string ColorR { get => _colorR; set => SetProperty(ref _colorR, value); }
    public string ColorG { get => _colorG; set => SetProperty(ref _colorG, value); }
    public string ColorB { get => _colorB; set => SetProperty(ref _colorB, value); }
    public string ColorA { get => _colorA; set => SetProperty(ref _colorA, value); }
    public string TextureIdText { get => _textureIdText; set => SetProperty(ref _textureIdText, value); }
    public string MoveSpeed { get => _moveSpeed; set => SetProperty(ref _moveSpeed, value); }
    public string PatrolMinY { get => _patrolMinY; set => SetProperty(ref _patrolMinY, value); }
    public string PatrolMaxY { get => _patrolMaxY; set => SetProperty(ref _patrolMaxY, value); }
    public string PatrolSpeed { get => _patrolSpeed; set => SetProperty(ref _patrolSpeed, value); }

    public static SceneObjectDraftViewModel FromSnapshot(ProjectModelSceneObject sceneObject, ObservableCollection<string> textureIds) => new(
        sceneObject.ObjectId,
        sceneObject.ObjectId,
        sceneObject.Kind,
        Format(sceneObject.Position[0]),
        Format(sceneObject.Position[1]),
        Format(sceneObject.Size[0]),
        Format(sceneObject.Size[1]),
        Format(sceneObject.Color[0]),
        Format(sceneObject.Color[1]),
        Format(sceneObject.Color[2]),
        Format(sceneObject.Color[3]),
        sceneObject.TextureId.ToString(System.Globalization.CultureInfo.InvariantCulture),
        sceneObject.MoveSpeed is null ? string.Empty : Format(sceneObject.MoveSpeed.Value),
        sceneObject.PatrolMinY is null ? string.Empty : Format(sceneObject.PatrolMinY.Value),
        sceneObject.PatrolMaxY is null ? string.Empty : Format(sceneObject.PatrolMaxY.Value),
        sceneObject.PatrolSpeed is null ? string.Empty : Format(sceneObject.PatrolSpeed.Value),
        textureIds);

    public static SceneObjectDraftViewModel NewSprite(string objectId, string textureId, ObservableCollection<string> textureIds) => new(
        objectId, objectId, "sprite", "160", "160", "64", "64", "1", "1", "1", "1", textureId,
        string.Empty, string.Empty, string.Empty, string.Empty, textureIds);

    public static SceneObjectDraftViewModel NewPatrolHazard(string objectId, string textureId, ObservableCollection<string> textureIds) => new(
        objectId, objectId, "patrol_hazard", "500", "420", "72", "72", "1", "0.3", "0.2", "1", textureId,
        string.Empty, "380", "460", "55", textureIds);

    private static string Format(double value) => value.ToString("0.###", System.Globalization.CultureInfo.InvariantCulture);
}
