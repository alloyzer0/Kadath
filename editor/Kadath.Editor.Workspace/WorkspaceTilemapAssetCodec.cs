using System.Buffers.Binary;
using System.Text;
using System.Text.RegularExpressions;

namespace Kadath.Editor.Workspace;

[Flags]
internal enum WorkspaceTileTransform : uint
{
    None = 0,
    FlipHorizontal = 1,
    FlipVertical = 2,
    FlipDiagonal = 4
}

internal sealed record WorkspaceTileSource(
    string SourceId,
    uint TextureId,
    int TileWidth,
    int TileHeight,
    int ImageWidth,
    int ImageHeight,
    int Columns,
    int Rows,
    int Margin,
    int Spacing);

internal sealed record WorkspaceTileCell(
    ushort LocalIndex,
    ushort TileSourceIndex,
    uint LocalTileId,
    WorkspaceTileTransform Transform);

internal sealed record WorkspaceTileChunk(
    int X,
    int Y,
    WorkspaceTileCell[] Cells);

internal sealed record WorkspaceTileLayer(
    string LayerId,
    bool Visible,
    float Opacity,
    int GridWidth,
    int GridHeight,
    float OffsetX,
    float OffsetY,
    WorkspaceTileChunk[] Chunks);

internal sealed record WorkspaceTilemapAsset(
    WorkspaceTileSource[] TileSources,
    WorkspaceTileLayer[] Layers);

/// <summary>
/// 来源无关的 Tilemap artifact Module。外部格式 Adapter 只需要构造规范模型，
/// Runtime 和测试通过同一二进制 Interface 消费，不需要理解 Tiled GID 或 LDtk 字段。
/// </summary>
internal static partial class WorkspaceTilemapAssetCodec
{
    internal const int ArtifactVersion = 1;
    internal const int ChunkEdge = 32;
    internal const int MaxTileSources = 16;
    internal const int MaxLayers = 4;
    internal const int MaxArtifactBytes = 64 * 1024 * 1024;

    private const int HeaderBytes = 32;
    private const int CellBytes = 12;
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);

    [GeneratedRegex("^[a-z][a-z0-9_-]{0,62}$", RegexOptions.CultureInvariant)]
    private static partial Regex StableIdPattern();

    internal static byte[] Encode(WorkspaceTilemapAsset value)
    {
        Validate(value);
        using var output = new MemoryStream();
        output.Write("KTMP"u8);
        WriteU32(output, ArtifactVersion);
        WriteU32(output, ChunkEdge);
        WriteU32(output, checked((uint)value.TileSources.Length));
        WriteU32(output, checked((uint)value.Layers.Length));
        WriteU32(output, checked((uint)value.Layers.Sum(layer => layer.Chunks.Length)));
        WriteU32(output, checked((uint)value.Layers.Sum(layer => layer.Chunks.Sum(chunk => chunk.Cells.Length))));
        WriteU32(output, 0);

        foreach (var source in value.TileSources)
        {
            using var entry = new MemoryStream();
            WriteString(entry, source.SourceId);
            WriteU32(entry, source.TextureId);
            WriteU32(entry, checked((uint)source.TileWidth));
            WriteU32(entry, checked((uint)source.TileHeight));
            WriteU32(entry, checked((uint)source.ImageWidth));
            WriteU32(entry, checked((uint)source.ImageHeight));
            WriteU32(entry, checked((uint)source.Columns));
            WriteU32(entry, checked((uint)source.Rows));
            WriteU32(entry, checked((uint)source.Margin));
            WriteU32(entry, checked((uint)source.Spacing));
            WriteEntry(output, entry);
        }

        foreach (var layer in value.Layers)
        {
            using var entry = new MemoryStream();
            WriteString(entry, layer.LayerId);
            WriteU32(entry, layer.Visible ? 1u : 0u);
            WriteF32(entry, layer.Opacity);
            WriteU32(entry, checked((uint)layer.GridWidth));
            WriteU32(entry, checked((uint)layer.GridHeight));
            WriteF32(entry, layer.OffsetX);
            WriteF32(entry, layer.OffsetY);
            WriteU32(entry, checked((uint)layer.Chunks.Length));
            foreach (var chunk in layer.Chunks)
            {
                WriteI32(entry, chunk.X);
                WriteI32(entry, chunk.Y);
                WriteU32(entry, checked((uint)chunk.Cells.Length));
                foreach (var cell in chunk.Cells)
                {
                    WriteU16(entry, cell.LocalIndex);
                    WriteU16(entry, cell.TileSourceIndex);
                    WriteU32(entry, cell.LocalTileId);
                    WriteU32(entry, (uint)cell.Transform);
                }
            }
            WriteEntry(output, entry);
        }

        if (output.Length > MaxArtifactBytes)
            throw new InvalidDataException($"Tilemap artifact exceeds the {MaxArtifactBytes} byte budget: {output.Length}.");
        return output.ToArray();
    }

    internal static WorkspaceTilemapAsset Decode(byte[] bytes)
    {
        ArgumentNullException.ThrowIfNull(bytes);
        if (bytes.Length is < HeaderBytes or > MaxArtifactBytes)
            throw new InvalidDataException("Tilemap artifact byte length is outside the supported budget.");
        var reader = new TilemapReader(bytes);
        if (!reader.ReadBytes(4).SequenceEqual("KTMP"u8)) throw new InvalidDataException("Tilemap artifact magic is invalid.");
        if (reader.ReadU32() != ArtifactVersion) throw new InvalidDataException("Tilemap artifact version is unsupported.");
        if (reader.ReadU32() != ChunkEdge) throw new InvalidDataException("Tilemap artifact chunk edge is unsupported.");
        var tileSourceCount = reader.ReadCount(MaxTileSources, "Tile source");
        var layerCount = reader.ReadCount(MaxLayers, "Layer");
        var expectedChunkCount = reader.ReadU32();
        var expectedCellCount = reader.ReadU32();
        if (reader.ReadU32() != 0) throw new InvalidDataException("Tilemap artifact reserved header field must be zero.");

        var sources = new WorkspaceTileSource[tileSourceCount];
        for (var index = 0; index < sources.Length; index++)
        {
            var entry = reader.ReadEntry();
            sources[index] = new WorkspaceTileSource(
                entry.ReadString(),
                entry.ReadU32(),
                entry.ReadPositiveInt32("Tile width"),
                entry.ReadPositiveInt32("Tile height"),
                entry.ReadPositiveInt32("Image width"),
                entry.ReadPositiveInt32("Image height"),
                entry.ReadPositiveInt32("Atlas columns"),
                entry.ReadPositiveInt32("Atlas rows"),
                entry.ReadNonNegativeInt32("Atlas margin"),
                entry.ReadNonNegativeInt32("Atlas spacing"));
            entry.RequireEnd("Tile source entry");
        }

        var layers = new WorkspaceTileLayer[layerCount];
        ulong actualChunkCount = 0;
        ulong actualCellCount = 0;
        for (var layerIndex = 0; layerIndex < layers.Length; layerIndex++)
        {
            var entry = reader.ReadEntry();
            var id = entry.ReadString();
            var visibleValue = entry.ReadU32();
            if (visibleValue > 1) throw new InvalidDataException("Tile layer visible flag is invalid.");
            var opacity = entry.ReadF32();
            var gridWidth = entry.ReadPositiveInt32("Layer grid width");
            var gridHeight = entry.ReadPositiveInt32("Layer grid height");
            var offsetX = entry.ReadF32();
            var offsetY = entry.ReadF32();
            var chunkCount = entry.ReadCountFromRemaining(12, "Chunk");
            var chunks = new WorkspaceTileChunk[chunkCount];
            actualChunkCount = checked(actualChunkCount + (uint)chunkCount);
            for (var chunkIndex = 0; chunkIndex < chunks.Length; chunkIndex++)
            {
                var x = entry.ReadI32();
                var y = entry.ReadI32();
                var cellCount = entry.ReadCountFromRemaining(CellBytes, "Cell");
                var cells = new WorkspaceTileCell[cellCount];
                actualCellCount = checked(actualCellCount + (uint)cellCount);
                for (var cellIndex = 0; cellIndex < cells.Length; cellIndex++)
                {
                    cells[cellIndex] = new WorkspaceTileCell(
                        entry.ReadU16(),
                        entry.ReadU16(),
                        entry.ReadU32(),
                        (WorkspaceTileTransform)entry.ReadU32());
                }
                chunks[chunkIndex] = new WorkspaceTileChunk(x, y, cells);
            }
            entry.RequireEnd("Tile layer entry");
            layers[layerIndex] = new WorkspaceTileLayer(id, visibleValue == 1, opacity, gridWidth, gridHeight, offsetX, offsetY, chunks);
        }
        reader.RequireEnd("Tilemap artifact");
        if (actualChunkCount != expectedChunkCount || actualCellCount != expectedCellCount)
            throw new InvalidDataException("Tilemap artifact header counts do not match its payload.");

        var result = new WorkspaceTilemapAsset(sources, layers);
        Validate(result);
        return result;
    }

    internal static void Validate(WorkspaceTilemapAsset value)
    {
        ArgumentNullException.ThrowIfNull(value);
        if (value.TileSources is not { Length: > 0 and <= MaxTileSources })
            throw new InvalidDataException($"Tilemap asset must contain 1..{MaxTileSources} Tile sources.");
        if (value.Layers is not { Length: > 0 and <= MaxLayers })
            throw new InvalidDataException($"Tilemap asset must contain 1..{MaxLayers} visual layers.");

        var sourceIds = new HashSet<string>(StringComparer.Ordinal);
        foreach (var source in value.TileSources)
        {
            if (!IsStableId(source.SourceId) || !sourceIds.Add(source.SourceId))
                throw new InvalidDataException("Tile source IDs must be unique and match [a-z][a-z0-9_-]{0,62}.");
            if (source.TextureId == 0 || source.TileWidth <= 0 || source.TileHeight <= 0
                || source.ImageWidth <= 0 || source.ImageHeight <= 0 || source.Columns <= 0 || source.Rows <= 0
                || source.Margin < 0 || source.Spacing < 0)
                throw new InvalidDataException($"Tile source {source.SourceId} geometry is invalid.");
            var usedWidth = checked(source.Margin * 2L + source.Columns * (long)source.TileWidth + Math.Max(0, source.Columns - 1L) * source.Spacing);
            var usedHeight = checked(source.Margin * 2L + source.Rows * (long)source.TileHeight + Math.Max(0, source.Rows - 1L) * source.Spacing);
            if (usedWidth > source.ImageWidth || usedHeight > source.ImageHeight)
                throw new InvalidDataException($"Tile source {source.SourceId} atlas geometry escapes its image.");
        }

        var layerIds = new HashSet<string>(StringComparer.Ordinal);
        foreach (var layer in value.Layers)
        {
            if (!IsStableId(layer.LayerId) || !layerIds.Add(layer.LayerId))
                throw new InvalidDataException("Tile layer IDs must be unique and match [a-z][a-z0-9_-]{0,62}.");
            if (!float.IsFinite(layer.Opacity) || layer.Opacity is < 0 or > 1
                || !float.IsFinite(layer.OffsetX) || !float.IsFinite(layer.OffsetY)
                || layer.GridWidth <= 0 || layer.GridHeight <= 0)
                throw new InvalidDataException($"Tile layer {layer.LayerId} display geometry is invalid.");

            var previousChunk = (X: int.MinValue, Y: int.MinValue);
            var firstChunk = true;
            foreach (var chunk in layer.Chunks)
            {
                // 规范顺序是 Y 后 X；保证相同输入的 artifact 和 draw 顺序稳定。
                if (!firstChunk && (chunk.Y < previousChunk.Y || chunk.Y == previousChunk.Y && chunk.X <= previousChunk.X))
                    throw new InvalidDataException($"Tile layer {layer.LayerId} chunks are not strictly ordered by Y then X.");
                firstChunk = false;
                previousChunk = (chunk.X, chunk.Y);
                var previousCell = -1;
                foreach (var cell in chunk.Cells)
                {
                    if (cell.LocalIndex >= ChunkEdge * ChunkEdge || cell.LocalIndex <= previousCell)
                        throw new InvalidDataException($"Tile layer {layer.LayerId} chunk cells are duplicated or not row-major ordered.");
                    previousCell = cell.LocalIndex;
                    if (cell.TileSourceIndex >= value.TileSources.Length)
                        throw new InvalidDataException($"Tile layer {layer.LayerId} cell references an unknown Tile source.");
                    var source = value.TileSources[cell.TileSourceIndex];
                    if (cell.LocalTileId >= checked((uint)(source.Columns * source.Rows)))
                        throw new InvalidDataException($"Tile layer {layer.LayerId} cell references an invalid local Tile ID.");
                    if (((uint)cell.Transform & ~(uint)(WorkspaceTileTransform.FlipHorizontal | WorkspaceTileTransform.FlipVertical | WorkspaceTileTransform.FlipDiagonal)) != 0)
                        throw new InvalidDataException($"Tile layer {layer.LayerId} cell contains unsupported transform bits.");
                }
            }
        }
    }

    private static bool IsStableId(string value) =>
        StrictUtf8.GetByteCount(value) is >= 1 and <= 63 && StableIdPattern().IsMatch(value);

    private static void WriteEntry(Stream output, MemoryStream entry)
    {
        WriteU32(output, checked((uint)entry.Length));
        entry.Position = 0;
        entry.CopyTo(output);
    }

    private static void WriteString(Stream output, string value)
    {
        var bytes = StrictUtf8.GetBytes(value);
        WriteU32(output, checked((uint)bytes.Length));
        output.Write(bytes);
    }

    private static void WriteU16(Stream output, ushort value)
    {
        Span<byte> bytes = stackalloc byte[2];
        BinaryPrimitives.WriteUInt16LittleEndian(bytes, value);
        output.Write(bytes);
    }

    private static void WriteU32(Stream output, uint value)
    {
        Span<byte> bytes = stackalloc byte[4];
        BinaryPrimitives.WriteUInt32LittleEndian(bytes, value);
        output.Write(bytes);
    }

    private static void WriteI32(Stream output, int value) => WriteU32(output, unchecked((uint)value));

    private static void WriteF32(Stream output, float value) => WriteU32(output, unchecked((uint)BitConverter.SingleToInt32Bits(value)));

    private sealed class TilemapReader
    {
        private readonly ReadOnlyMemory<byte> _source;
        private int _offset;

        internal TilemapReader(byte[] source) : this(source.AsMemory()) { }
        private TilemapReader(ReadOnlyMemory<byte> source) => _source = source;

        internal ReadOnlySpan<byte> ReadBytes(int count)
        {
            if (count < 0 || count > _source.Length - _offset) throw new InvalidDataException("Tilemap artifact is truncated.");
            var result = _source.Span.Slice(_offset, count);
            _offset += count;
            return result;
        }

        internal ushort ReadU16() => BinaryPrimitives.ReadUInt16LittleEndian(ReadBytes(2));
        internal uint ReadU32() => BinaryPrimitives.ReadUInt32LittleEndian(ReadBytes(4));
        internal int ReadI32() => unchecked((int)ReadU32());
        internal float ReadF32() => BitConverter.Int32BitsToSingle(unchecked((int)ReadU32()));

        internal int ReadCount(int maximum, string owner)
        {
            var value = ReadU32();
            if (value > maximum) throw new InvalidDataException($"{owner} count exceeds its budget: {value} > {maximum}.");
            return checked((int)value);
        }

        internal int ReadCountFromRemaining(int minimumItemBytes, string owner)
        {
            var value = ReadU32();
            if ((ulong)value * (uint)minimumItemBytes > (ulong)(_source.Length - _offset))
                throw new InvalidDataException($"{owner} count exceeds the remaining Tilemap artifact bytes.");
            return checked((int)value);
        }

        internal int ReadPositiveInt32(string owner)
        {
            var value = ReadU32();
            if (value is 0 or > int.MaxValue) throw new InvalidDataException($"{owner} must be a positive i32.");
            return (int)value;
        }

        internal int ReadNonNegativeInt32(string owner)
        {
            var value = ReadU32();
            if (value > int.MaxValue) throw new InvalidDataException($"{owner} must be a non-negative i32.");
            return (int)value;
        }

        internal string ReadString()
        {
            var byteCount = ReadU32();
            if (byteCount is 0 or > 63) throw new InvalidDataException("Tilemap stable ID byte length is invalid.");
            return StrictUtf8.GetString(ReadBytes(checked((int)byteCount)));
        }

        internal TilemapReader ReadEntry()
        {
            var bytes = ReadU32();
            if (bytes > _source.Length - _offset) throw new InvalidDataException("Tilemap entry length exceeds the remaining artifact bytes.");
            var result = new TilemapReader(_source.Slice(_offset, checked((int)bytes)));
            _offset += checked((int)bytes);
            return result;
        }

        internal void RequireEnd(string owner)
        {
            if (_offset != _source.Length) throw new InvalidDataException($"{owner} contains trailing bytes.");
        }

    }
}
