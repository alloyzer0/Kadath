using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.ComponentModel;
using System.Globalization;
using Kadath.Editor.Protocol;
using Kadath.Editor.ViewModels;

namespace Kadath.Editor.Avalonia.ViewModels;

public sealed class BehaviorParameterDraftViewModel : ObservableObject
{
    private string _valueText;
    private BehaviorParameterSchema? _schema;

    public BehaviorParameterDraftViewModel(string name, double? overrideValue, BehaviorParameterSchema? schema = null)
    {
        Name = name;
        _valueText = overrideValue is { } value ? Format(value) : string.Empty;
        _schema = schema;
    }

    public string Name { get; }
    public string ValueText
    {
        get => _valueText;
        set
        {
            if (!SetProperty(ref _valueText, value)) return;
            RaisePropertyChanged(nameof(HasOverride));
            RaisePropertyChanged(nameof(IsValid));
            RaisePropertyChanged(nameof(Details));
        }
    }
    public bool HasOverride => !string.IsNullOrWhiteSpace(ValueText);
    public bool HasSchema => _schema is not null;
    public bool IsValid => TryReadOverride(out _);
    public string Details => _schema is null
        ? "参数不在当前脚本契约中"
        : $"默认 {Format(_schema.DefaultValue)} · 范围 [{Format(_schema.Minimum)}, {Format(_schema.Maximum)}]"
            + (HasOverride ? string.Empty : " · 当前使用默认值");

    internal void ApplySchema(BehaviorParameterSchema? schema)
    {
        _schema = schema;
        RaisePropertyChanged(nameof(HasSchema));
        RaisePropertyChanged(nameof(IsValid));
        RaisePropertyChanged(nameof(Details));
    }

    internal bool TryReadOverride(out double value)
    {
        value = default;
        if (!HasOverride) return true;
        if (!double.TryParse(ValueText, NumberStyles.Float, CultureInfo.InvariantCulture, out value) || !double.IsFinite(value)) return false;
        return _schema is null || value >= _schema.Minimum && value <= _schema.Maximum;
    }

    private static string Format(double value) => value.ToString("0.###", CultureInfo.InvariantCulture);
}

public sealed class SceneBehaviorBindingDraftViewModel : ObservableObject
{
    private BehaviorContractEntry? _contract;
    private bool _catalogAvailable;
    private bool _hasIdentityConflict;
    private readonly HashSet<BehaviorParameterDraftViewModel> _observedParameters = [];

    private SceneBehaviorBindingDraftViewModel(uint scriptId, string sourcePath, string sourceHash)
    {
        ScriptId = scriptId;
        SourcePath = sourcePath;
        SourceHash = sourceHash;
        Parameters.CollectionChanged += OnParametersChanged;
    }

    public uint ScriptId { get; }
    public string SourcePath { get; private set; }
    public string SourceHash { get; private set; }
    public ObservableCollection<BehaviorParameterDraftViewModel> Parameters { get; } = [];
    public string DisplayName => $"Script {ScriptId} · {SourcePath}";
    public bool HasContract => _contract is not null;
    public bool HasIdentityConflict => _hasIdentityConflict;
    public bool IsValid => !_catalogAvailable || !_hasIdentityConflict && _contract is not null && Parameters.All(parameter => parameter.HasSchema && parameter.IsValid);
    public string Status => !_catalogAvailable
        ? "当前脚本契约不可用"
        : HasIdentityConflict ? "脚本源码身份已变化，请刷新 Scene 草稿"
        : !HasContract ? "脚本不在当前契约目录中"
        : IsValid ? "参数有效" : "存在未知、格式错误或越界参数";

    public static SceneBehaviorBindingDraftViewModel FromSnapshot(
        ProjectModelSceneBehaviorBinding binding,
        BehaviorContractEntry? contract = null)
    {
        var draft = new SceneBehaviorBindingDraftViewModel(binding.ScriptId, contract?.SourcePath ?? "未解析源码", contract?.SourceHash ?? string.Empty);
        var overrides = (binding.Parameters ?? []).ToDictionary(parameter => parameter.Name, parameter => parameter.Value, StringComparer.Ordinal);
        if (contract is not null)
        {
            foreach (var schema in contract.Parameters)
            {
                draft.Parameters.Add(new BehaviorParameterDraftViewModel(
                    schema.Name,
                    overrides.TryGetValue(schema.Name, out var value) ? value : null,
                    schema));
                overrides.Remove(schema.Name);
            }
        }
        foreach (var unknown in overrides)
            draft.Parameters.Add(new BehaviorParameterDraftViewModel(unknown.Key, unknown.Value));
        draft.ApplyContract(contract, contract is not null);
        return draft;
    }

    public static SceneBehaviorBindingDraftViewModel Create(BehaviorContractEntry contract)
    {
        var draft = new SceneBehaviorBindingDraftViewModel(contract.ScriptId, contract.SourcePath, contract.SourceHash);
        draft.ApplyContract(contract, true);
        return draft;
    }

    internal void ApplyContract(BehaviorContractEntry? contract, bool catalogAvailable = false)
    {
        var previousContract = _contract;
        _catalogAvailable = catalogAvailable;
        _hasIdentityConflict = contract is not null
            && (SourceHash.Length != 0 && !SourceHash.Equals(contract.SourceHash, StringComparison.Ordinal)
                || previousContract is not null && !ContractIdentityEquals(previousContract, contract));
        if (!_hasIdentityConflict) _contract = contract;
        if (contract is not null && !_hasIdentityConflict)
        {
            SourcePath = contract.SourcePath;
            SourceHash = contract.SourceHash;
            var existing = Parameters.ToDictionary(parameter => parameter.Name, StringComparer.Ordinal);
            var ordered = new List<BehaviorParameterDraftViewModel>();
            foreach (var schema in contract.Parameters)
            {
                if (!existing.Remove(schema.Name, out var parameter))
                    parameter = new BehaviorParameterDraftViewModel(schema.Name, null, schema);
                else parameter.ApplySchema(schema);
                ordered.Add(parameter);
            }
            foreach (var parameter in existing.Values)
            {
                parameter.ApplySchema(null);
                ordered.Add(parameter);
            }
            Parameters.Clear();
            foreach (var parameter in ordered) Parameters.Add(parameter);
        }
        else if (contract is null)
        {
            foreach (var parameter in Parameters) parameter.ApplySchema(null);
        }
        RaisePropertyChanged(nameof(SourcePath));
        RaisePropertyChanged(nameof(SourceHash));
        RaisePropertyChanged(nameof(DisplayName));
        RaisePropertyChanged(nameof(HasContract));
        RaisePropertyChanged(nameof(HasIdentityConflict));
        RaisePropertyChanged(nameof(IsValid));
        RaisePropertyChanged(nameof(Status));
    }

    private static bool ContractIdentityEquals(BehaviorContractEntry left, BehaviorContractEntry right) =>
        left.ScriptId == right.ScriptId
        && left.SourcePath.Equals(right.SourcePath, StringComparison.Ordinal)
        && left.SourceHash.Equals(right.SourceHash, StringComparison.Ordinal)
        && left.Parameters.Length == right.Parameters.Length
        && left.Parameters.Zip(right.Parameters).All(pair =>
            pair.First.Name == pair.Second.Name
            && pair.First.Type == pair.Second.Type
            && pair.First.DefaultValue == pair.Second.DefaultValue
            && pair.First.Minimum == pair.Second.Minimum
            && pair.First.Maximum == pair.Second.Maximum);

    internal SceneBehaviorBindingDefinition CreateDefinition()
    {
        if (!IsValid) throw new InvalidOperationException($"Behavior binding {ScriptId} contains invalid parameters.");
        var overrides = new Dictionary<string, double>(StringComparer.Ordinal);
        foreach (var parameter in Parameters)
        {
            if (!parameter.HasOverride) continue;
            if (!parameter.TryReadOverride(out var value))
                throw new InvalidOperationException($"Behavior binding {ScriptId} parameter {parameter.Name} is invalid.");
            overrides.Add(parameter.Name, value);
        }
        return new SceneBehaviorBindingDefinition(ScriptId, overrides);
    }

    private void OnParametersChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        if (e.Action == NotifyCollectionChangedAction.Reset)
        {
            foreach (var parameter in _observedParameters) parameter.PropertyChanged -= OnParameterPropertyChanged;
            _observedParameters.Clear();
        }
        if (e.OldItems is not null)
            foreach (BehaviorParameterDraftViewModel parameter in e.OldItems)
            {
                parameter.PropertyChanged -= OnParameterPropertyChanged;
                _observedParameters.Remove(parameter);
            }
        if (e.NewItems is not null)
            foreach (BehaviorParameterDraftViewModel parameter in e.NewItems)
            {
                parameter.PropertyChanged += OnParameterPropertyChanged;
                _observedParameters.Add(parameter);
            }
        RaisePropertyChanged(nameof(IsValid));
        RaisePropertyChanged(nameof(Status));
    }

    private void OnParameterPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        RaisePropertyChanged(nameof(IsValid));
        RaisePropertyChanged(nameof(Status));
    }
}
