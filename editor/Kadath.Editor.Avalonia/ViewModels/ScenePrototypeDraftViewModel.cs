using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.ComponentModel;
using Kadath.Editor.Protocol;
using Kadath.Editor.ViewModels;

namespace Kadath.Editor.Avalonia.ViewModels;

/// <summary>
/// Spawn Prototype 的 UI 草稿。Prototype 不是 Scene Object，因此不携带 position 或 Hierarchy identity。
/// </summary>
public sealed class ScenePrototypeDraftViewModel : ObservableObject
{
    private string _prototypeId;
    private string _sizeX;
    private string _sizeY;
    private string _colorR;
    private string _colorG;
    private string _colorB;
    private string _colorA;
    private string _textureIdText;

    public ScenePrototypeDraftViewModel(
        string originalPrototypeId,
        string prototypeId,
        string kind,
        string sizeX,
        string sizeY,
        string colorR,
        string colorG,
        string colorB,
        string colorA,
        string textureIdText,
        ObservableCollection<string> textureIds,
        IReadOnlyList<ProjectModelSceneBehaviorBinding>? behaviors = null)
    {
        OriginalPrototypeId = originalPrototypeId;
        _prototypeId = prototypeId;
        Kind = kind;
        _sizeX = sizeX;
        _sizeY = sizeY;
        _colorR = colorR;
        _colorG = colorG;
        _colorB = colorB;
        _colorA = colorA;
        _textureIdText = textureIdText;
        TextureIds = textureIds;
        Behaviors = new ObservableCollection<SceneBehaviorBindingDraftViewModel>(
            (behaviors ?? []).Select(binding => SceneBehaviorBindingDraftViewModel.FromSnapshot(binding)));
        Behaviors.CollectionChanged += OnBehaviorsChanged;
        foreach (var binding in Behaviors) binding.PropertyChanged += OnBehaviorPropertyChanged;
    }

    public string OriginalPrototypeId { get; }
    public string Kind { get; }
    public ObservableCollection<string> TextureIds { get; }
    public ObservableCollection<SceneBehaviorBindingDraftViewModel> Behaviors { get; }
    public bool AreBehaviorsValid => Behaviors.All(binding => binding.IsValid);
    public string DisplayName => $"{PrototypeId} [{Kind}]";

    public string PrototypeId
    {
        get => _prototypeId;
        set
        {
            if (!SetProperty(ref _prototypeId, value)) return;
            RaisePropertyChanged(nameof(DisplayName));
        }
    }

    public string SizeX { get => _sizeX; set => SetProperty(ref _sizeX, value); }
    public string SizeY { get => _sizeY; set => SetProperty(ref _sizeY, value); }
    public string ColorR { get => _colorR; set => SetProperty(ref _colorR, value); }
    public string ColorG { get => _colorG; set => SetProperty(ref _colorG, value); }
    public string ColorB { get => _colorB; set => SetProperty(ref _colorB, value); }
    public string ColorA { get => _colorA; set => SetProperty(ref _colorA, value); }
    public string TextureIdText { get => _textureIdText; set => SetProperty(ref _textureIdText, value); }

    public static ScenePrototypeDraftViewModel FromSnapshot(
        ProjectModelScenePrototype prototype,
        ObservableCollection<string> textureIds) => new(
            prototype.PrototypeId,
            prototype.PrototypeId,
            prototype.Kind,
            Format(prototype.Size[0]),
            Format(prototype.Size[1]),
            Format(prototype.Color[0]),
            Format(prototype.Color[1]),
            Format(prototype.Color[2]),
            Format(prototype.Color[3]),
            prototype.TextureId.ToString(System.Globalization.CultureInfo.InvariantCulture),
            textureIds,
            prototype.Behaviors);

    public static ScenePrototypeDraftViewModel NewSprite(
        string prototypeId,
        string textureId,
        ObservableCollection<string> textureIds) => new(
            prototypeId,
            prototypeId,
            "sprite",
            "32",
            "32",
            "1",
            "1",
            "1",
            "1",
            textureId,
            textureIds);

    public IReadOnlyList<SceneBehaviorBindingDefinition> CreateBehaviorDefinitions() =>
        Behaviors.Select(binding => binding.CreateDefinition()).ToArray();

    public void ApplyBehaviorContracts(
        IReadOnlyDictionary<uint, BehaviorContractEntry> contracts,
        bool catalogAvailable = false)
    {
        foreach (var binding in Behaviors)
            binding.ApplyContract(contracts.GetValueOrDefault(binding.ScriptId), catalogAvailable);
        RaisePropertyChanged(nameof(AreBehaviorsValid));
    }

    private void OnBehaviorsChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        if (e.OldItems is not null)
            foreach (SceneBehaviorBindingDraftViewModel binding in e.OldItems)
                binding.PropertyChanged -= OnBehaviorPropertyChanged;
        if (e.NewItems is not null)
            foreach (SceneBehaviorBindingDraftViewModel binding in e.NewItems)
                binding.PropertyChanged += OnBehaviorPropertyChanged;
        RaisePropertyChanged(nameof(AreBehaviorsValid));
        RaisePropertyChanged(nameof(DisplayName));
    }

    private void OnBehaviorPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        RaisePropertyChanged(nameof(AreBehaviorsValid));
        RaisePropertyChanged(nameof(DisplayName));
    }

    private static string Format(double value) =>
        value.ToString("0.###", System.Globalization.CultureInfo.InvariantCulture);
}
