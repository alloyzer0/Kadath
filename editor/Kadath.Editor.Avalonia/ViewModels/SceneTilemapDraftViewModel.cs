using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Globalization;
using System.Text.RegularExpressions;
using System.Windows.Input;
using Kadath.Editor.Protocol;
using Kadath.Editor.ViewModels;

namespace Kadath.Editor.Avalonia.ViewModels;

/// <summary>
/// Tilemap 的本地创作草稿。Cell 点击只修改该草稿，跨进程仍通过一次完整 AuthoringPatch 提交。
/// </summary>
public sealed class SceneTilemapDraftViewModel : ObservableObject
{
    private string _tilemapId;
    private string _originX;
    private string _originY;
    private string _tileSizeX;
    private string _tileSizeY;
    private string _columns;
    private string _rows;
    private string _textureIdText;
    private string _atlasColumns;
    private string _atlasRows;
    private string _selectedTileIndex = "1";

    private SceneTilemapDraftViewModel(
        string tilemapId,
        string originX,
        string originY,
        string tileSizeX,
        string tileSizeY,
        string columns,
        string rows,
        string textureIdText,
        string atlasColumns,
        string atlasRows,
        ObservableCollection<string> textureIds,
        IEnumerable<int> cells)
    {
        _tilemapId = tilemapId;
        _originX = originX;
        _originY = originY;
        _tileSizeX = tileSizeX;
        _tileSizeY = tileSizeY;
        _columns = columns;
        _rows = rows;
        _textureIdText = textureIdText;
        _atlasColumns = atlasColumns;
        _atlasRows = atlasRows;
        TextureIds = textureIds;
        foreach (var (value, index) in cells.Select((value, index) => (value, index)))
            AddCell(index, value);
    }

    public ObservableCollection<string> TextureIds { get; }
    public ObservableCollection<SceneTileCellDraftViewModel> Cells { get; } = [];

    public string TilemapId { get => _tilemapId; set => SetAndSignal(ref _tilemapId, value); }
    public string OriginX { get => _originX; set => SetAndSignal(ref _originX, value); }
    public string OriginY { get => _originY; set => SetAndSignal(ref _originY, value); }
    public string TileSizeX { get => _tileSizeX; set => SetAndSignal(ref _tileSizeX, value); }
    public string TileSizeY { get => _tileSizeY; set => SetAndSignal(ref _tileSizeY, value); }
    public string Columns
    {
        get => _columns;
        set
        {
            if (!SetProperty(ref _columns, value)) return;
            RaisePropertyChanged(nameof(GridColumns));
            RaisePropertyChanged(nameof(IsStructurallyValid));
        }
    }
    public string Rows { get => _rows; set => SetAndSignal(ref _rows, value); }
    public string TextureIdText { get => _textureIdText; set => SetAndSignal(ref _textureIdText, value); }
    public string AtlasColumns { get => _atlasColumns; set => SetAndSignal(ref _atlasColumns, value); }
    public string AtlasRows { get => _atlasRows; set => SetAndSignal(ref _atlasRows, value); }
    public string SelectedTileIndex { get => _selectedTileIndex; set => SetAndSignal(ref _selectedTileIndex, value); }
    public bool IsStructurallyValid => ValidateStructure();
    public int GridColumns => TryBoundedDimension(Columns, out var columns) ? columns : 1;
    public string CellCountStatus => $"Cell {Cells.Count}/1024";

    public static SceneTilemapDraftViewModel FromSnapshot(
        ProjectModelSceneTilemap tilemap,
        ObservableCollection<string> textureIds) => new(
            tilemap.TilemapId,
            Format(tilemap.Origin[0]),
            Format(tilemap.Origin[1]),
            Format(tilemap.TileSize[0]),
            Format(tilemap.TileSize[1]),
            tilemap.Columns.ToString(CultureInfo.InvariantCulture),
            tilemap.Rows.ToString(CultureInfo.InvariantCulture),
            tilemap.TextureId.ToString(CultureInfo.InvariantCulture),
            tilemap.AtlasColumns.ToString(CultureInfo.InvariantCulture),
            tilemap.AtlasRows.ToString(CultureInfo.InvariantCulture),
            textureIds,
            tilemap.Cells);

    public static SceneTilemapDraftViewModel CreateDefault(string textureId, ObservableCollection<string> textureIds) => new(
        "background", "0", "0", "32", "32", "2", "2", textureId, "4", "4", textureIds, [0, 0, 0, 0]);

    public void ResizeCells()
    {
        if (!TryBoundedDimension(Columns, out var columns) || !TryBoundedDimension(Rows, out var rows)) return;
        var requested = columns * rows;
        var values = Cells.Select(cell => cell.Value).Take(requested).ToList();
        while (values.Count < requested) values.Add(0);
        foreach (var cell in Cells) cell.PropertyChanged -= OnCellPropertyChanged;
        Cells.Clear();
        for (var index = 0; index < values.Count; index++) AddCell(index, values[index]);
        RaisePropertyChanged(nameof(CellCountStatus));
        RaisePropertyChanged(nameof(IsStructurallyValid));
    }

    public void PaintCell(int index)
    {
        if (index < 0 || index >= Cells.Count || !int.TryParse(SelectedTileIndex, NumberStyles.None, CultureInfo.InvariantCulture, out var tile)) return;
        Cells[index].Value = tile;
    }

    public void EraseCell(int index)
    {
        if (index >= 0 && index < Cells.Count) Cells[index].Value = 0;
    }

    private void AddCell(int index, int value)
    {
        // Cell 命令闭包始终指向本次 resize 后的稳定索引，避免视图自行拼装 AuthoringPatch。
        var cell = new SceneTileCellDraftViewModel(index, value, () => PaintCell(index), () => EraseCell(index));
        cell.PropertyChanged += OnCellPropertyChanged;
        Cells.Add(cell);
    }

    private bool ValidateStructure()
    {
        if (!Regex.IsMatch(TilemapId.Trim(), "^[a-z][a-z0-9_-]{0,62}$", RegexOptions.CultureInvariant)) return false;
        if (!TryFinite(OriginX, out _) || !TryFinite(OriginY, out _)) return false;
        if (!TryFinite(TileSizeX, out var tileWidth) || tileWidth <= 0 || !TryFinite(TileSizeY, out var tileHeight) || tileHeight <= 0) return false;
        if (!TryBoundedDimension(Columns, out var columns) || !TryBoundedDimension(Rows, out var rows) || Cells.Count != columns * rows) return false;
        if (!int.TryParse(AtlasColumns, NumberStyles.None, CultureInfo.InvariantCulture, out var atlasColumns) || atlasColumns is < 1 or > 256
            || !int.TryParse(AtlasRows, NumberStyles.None, CultureInfo.InvariantCulture, out var atlasRows) || atlasRows is < 1 or > 256) return false;
        var atlasTiles = atlasColumns * atlasRows;
        if (atlasTiles > ushort.MaxValue || Cells.Any(cell => cell.Value < 0 || cell.Value > atlasTiles)) return false;
        return uint.TryParse(TextureIdText, NumberStyles.None, CultureInfo.InvariantCulture, out var textureId)
            && textureId != 0
            && TextureIds.Contains(textureId.ToString(CultureInfo.InvariantCulture), StringComparer.Ordinal);
    }

    private void SetAndSignal(ref string field, string value)
    {
        if (!SetProperty(ref field, value)) return;
        RaisePropertyChanged(nameof(IsStructurallyValid));
    }

    private void OnCellPropertyChanged(object? sender, PropertyChangedEventArgs e) => RaisePropertyChanged(nameof(IsStructurallyValid));
    private static bool TryBoundedDimension(string value, out int parsed) =>
        int.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out parsed) && parsed is >= 1 and <= 32;
    private static bool TryFinite(string value, out double parsed) =>
        double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out parsed) && double.IsFinite(parsed) && Math.Abs(parsed) <= float.MaxValue;
    private static string Format(double value) => value.ToString("0.###", CultureInfo.InvariantCulture);
}

public sealed class SceneTileCellDraftViewModel : ObservableObject
{
    private int _value;
    public SceneTileCellDraftViewModel(int index, int value, Action paint, Action erase)
    {
        Index = index;
        _value = value;
        PaintCommand = new DelegateUiCommand(paint);
        EraseCommand = new DelegateUiCommand(erase);
    }
    public int Index { get; }
    public int Value { get => _value; set { if (SetProperty(ref _value, value)) RaisePropertyChanged(nameof(Display)); } }
    public string Display => Value == 0 ? "·" : Value.ToString(CultureInfo.InvariantCulture);
    public ICommand PaintCommand { get; }
    public ICommand EraseCommand { get; }
}
