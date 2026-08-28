using System.Buffers.Binary;
using System.IO.Compression;
using System.Text;
using System.Text.Json;

namespace Kadath.Editor.Workspace.ContractVerifier;

/// <summary>
/// 生成原创横版地牢展示夹具。地图和 atlas 都由确定性代码构造，既能作为 Tiled 示例，
/// 也能让产品像素门稳定复现，而不依赖第三方游戏素材。
/// </summary>
internal static class MetroidvaniaShowcaseFixture
{
    internal const int TileSize = 8;
    internal const int AtlasColumns = 8;
    internal const int AtlasRows = 8;
    internal const int AtlasSize = TileSize * AtlasColumns;
    internal const int MapWidth = 64;
    internal const int MapHeight = 34;
    internal const int MapMinX = -8;

    private const uint TerrainFirstGid = 1;
    private const uint DecorFirstGid = 65;
    private const uint FlipHorizontal = 0x8000_0000;
    private const uint FlipVertical = 0x4000_0000;

    internal static string Write(string outputDirectory)
    {
        var ownedNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "prison-terrain.svg", "prison-decor.svg", "prison-terrain.png", "prison-decor.png",
            "prison-terrain.tsj", "prison-decor.tsj", "clockwork-prison.tmj", "runtime-preview.png", "README.md"
        };
        if (Directory.Exists(outputDirectory) && Directory.EnumerateFileSystemEntries(outputDirectory)
            .Any(path => !ownedNames.Contains(Path.GetFileName(path))))
            throw new InvalidOperationException("Metroidvania showcase output directory contains files not owned by the generator.");
        Directory.CreateDirectory(outputDirectory);

        var terrain = BuildAtlas(decor: false);
        var decor = BuildAtlas(decor: true);
        File.WriteAllText(Path.Combine(outputDirectory, "prison-terrain.svg"), BuildSvg(terrain), new UTF8Encoding(false));
        File.WriteAllText(Path.Combine(outputDirectory, "prison-decor.svg"), BuildSvg(decor), new UTF8Encoding(false));
        File.WriteAllBytes(Path.Combine(outputDirectory, "prison-terrain.png"), BuildPng(terrain));
        File.WriteAllBytes(Path.Combine(outputDirectory, "prison-decor.png"), BuildPng(decor));
        WriteTileset(Path.Combine(outputDirectory, "prison-terrain.tsj"), "PrisonTerrain", "prison-terrain.png");
        WriteTileset(Path.Combine(outputDirectory, "prison-decor.tsj"), "PrisonDecor", "prison-decor.png");

        var background = new uint[MapHeight, MapWidth];
        var terrainLayer = new uint[MapHeight, MapWidth];
        var decorLayer = new uint[MapHeight, MapWidth];
        var foreground = new uint[MapHeight, MapWidth];
        BuildBackground(background);
        BuildTerrain(terrainLayer);
        BuildDecor(decorLayer);
        BuildForeground(foreground);

        var mapPath = Path.Combine(outputDirectory, "clockwork-prison.tmj");
        var layers = new object[]
        {
            TileLayer(1, "FarBackground", background, 1.0),
            TileLayer(2, "Terrain", terrainLayer, 1.0),
            TileLayer(3, "ArchitectureAndHazards", decorLayer, 1.0),
            TileLayer(4, "ForegroundSilhouettes", foreground, 0.58),
            new
            {
                id = 5,
                name = "GameplayMarkers",
                type = "objectgroup",
                visible = true,
                opacity = 1.0,
                objects = new object[]
                {
                    new { id = 1, name = "PlayerSpawn", type = "spawn", x = -4 * TileSize, y = 19 * TileSize },
                    new { id = 2, name = "EliteArena", type = "encounter", x = 19 * TileSize, y = 15 * TileSize, width = 10 * TileSize, height = 8 * TileSize },
                    new { id = 3, name = "ExitLift", type = "exit", x = 49 * TileSize, y = 21 * TileSize }
                }
            }
        };
        var map = new
        {
            type = "map",
            version = "1.12",
            tiledversion = "1.12.2",
            orientation = "orthogonal",
            renderorder = "right-down",
            tilewidth = TileSize,
            tileheight = TileSize,
            infinite = true,
            nextlayerid = 6,
            nextobjectid = 4,
            tilesets = new object[]
            {
                new { firstgid = TerrainFirstGid, source = "prison-terrain.tsj" },
                new { firstgid = DecorFirstGid, source = "prison-decor.tsj" }
            },
            layers
        };
        File.WriteAllText(mapPath, JsonSerializer.Serialize(map, JsonOptions), new UTF8Encoding(false));
        File.WriteAllText(Path.Combine(outputDirectory, "README.md"),
            """
            # 原创横版地牢 Tilemap 展示夹具

            这是用于 Kadath Tilemap 产品展示的原创 Tiled 1.12 无限地图，不含任何第三方游戏资产。

            - 地图范围：64×34 格，世界 X 从 -8 开始；
            - Chunk：跨越 X=-32/0/32 与 Y=0/32，共 6 个空间块；
            - 视觉层：远景、地形、建筑与机关、前景剪影，共 4 层；
            - TileSource：地形与透明装饰两套 8×8 atlas，共 128 个 tile；
            - 场景：入口牢房、中央大厅、钟楼竖井、熔炉、下水道、断桥和出口升降机；
            - GameplayMarkers Object Layer 会被当前视觉导入器诊断但不会静默进入 Runtime authority。

            ## Runtime 产品截图

            ![复杂横版地牢 Runtime 截图](runtime-preview.png)
            """, new UTF8Encoding(false));
        return mapPath;
    }

    internal static byte[] BuildAtlas(bool decor)
    {
        var pixels = new byte[AtlasSize * AtlasSize * 4];
        for (var tile = 0; tile < AtlasColumns * AtlasRows; tile++)
        {
            var tileColumn = tile % AtlasColumns;
            var tileRow = tile / AtlasColumns;
            for (var y = 0; y < TileSize; y++)
            for (var x = 0; x < TileSize; x++)
            {
                var pixel = decor
                    ? DecorPixel(tileRow, tileColumn, x, y)
                    : TerrainPixel(tileRow, tileColumn, x, y);
                var atlasX = tileColumn * TileSize + x;
                var atlasY = tileRow * TileSize + y;
                var offset = (atlasY * AtlasSize + atlasX) * 4;
                pixels[offset] = pixel.R;
                pixels[offset + 1] = pixel.G;
                pixels[offset + 2] = pixel.B;
                pixels[offset + 3] = pixel.A;
            }
        }
        return pixels;
    }

    private static object TileLayer(int id, string name, uint[,] cells, double opacity) => new
    {
        id,
        name,
        type = "tilelayer",
        visible = true,
        opacity,
        offsetx = 0,
        offsety = 0,
        chunks = BuildChunks(cells)
    };

    private static object[] BuildChunks(uint[,] cells)
    {
        var chunks = new List<object>();
        foreach (var chunkY in new[] { 0, 32 })
        foreach (var chunkX in new[] { -32, 0, 32 })
        {
            var height = chunkY == 32 ? MapHeight - 32 : 32;
            var data = new uint[32 * height];
            var nonEmpty = false;
            for (var y = 0; y < height; y++)
            for (var x = 0; x < 32; x++)
            {
                var worldX = chunkX + x;
                var worldY = chunkY + y;
                var value = Get(cells, worldX, worldY);
                data[y * 32 + x] = value;
                nonEmpty |= value != 0;
            }
            if (nonEmpty) chunks.Add(new { x = chunkX, y = chunkY, width = 32, height, data });
        }
        return chunks.ToArray();
    }

    private static void BuildBackground(uint[,] layer)
    {
        for (var y = 0; y < MapHeight; y++)
        for (var x = MapMinX; x < MapMinX + MapWidth; x++)
        {
            var variant = PositiveMod(x / 3 + y / 2, 8);
            Set(layer, x, y, TerrainFirstGid + (uint)variant);
        }

        // 房间区域用不同材质带区分空间，让大地图在缩放后仍有清晰块面。
        Fill(layer, -7, 2, 10, 20, Terrain(0, 2));
        Fill(layer, 11, 2, 28, 24, Terrain(0, 4));
        Fill(layer, 30, 1, 42, 31, Terrain(0, 6));
        Fill(layer, 43, 10, 54, 31, Terrain(5, 3));
        Fill(layer, -1, 25, 41, 32, Terrain(5, 1));
    }

    private static void BuildTerrain(uint[,] layer)
    {
        // 外轮廓与主楼板。
        Fill(layer, MapMinX, 0, MapMinX + MapWidth - 1, 1, Terrain(2, 0));
        Fill(layer, MapMinX, 32, MapMinX + MapWidth - 1, 33, Terrain(1, 1));
        Fill(layer, -8, 0, -7, 33, Terrain(2, 2));
        Fill(layer, 54, 0, 55, 33, Terrain(2, 3));

        // 入口牢房与破损平台。
        Platform(layer, -6, 8, 22, 0);
        Platform(layer, -4, 4, 17, 1);
        Platform(layer, 3, 9, 12, 2);
        Fill(layer, 9, 2, 10, 24, Terrain(3, 1));
        Carve(layer, 9, 17, 10, 20);

        // 中央大厅、上层回廊和断桥。
        Platform(layer, 12, 25, 24, 3);
        Platform(layer, 14, 27, 17, 4);
        Platform(layer, 12, 18, 10, 5);
        Platform(layer, 22, 28, 10, 6);
        Platform(layer, 13, 18, 29, 7);
        Platform(layer, 22, 27, 27, 1);
        Fill(layer, 28, 1, 29, 31, Terrain(3, 4));
        Carve(layer, 28, 8, 29, 11);
        Carve(layer, 28, 21, 29, 24);

        // 钟楼竖井：左右交错平台制造真实的纵向 traversal。
        Platform(layer, 30, 37, 29, 2);
        Platform(layer, 35, 42, 25, 3);
        Platform(layer, 30, 37, 21, 4);
        Platform(layer, 35, 42, 17, 5);
        Platform(layer, 30, 37, 13, 6);
        Platform(layer, 35, 42, 9, 7);
        Platform(layer, 30, 37, 5, 0);
        Fill(layer, 42, 1, 43, 31, Terrain(3, 6));
        Carve(layer, 42, 14, 43, 17);
        Carve(layer, 42, 25, 43, 28);

        // 熔炉与出口升降机。
        Platform(layer, 44, 53, 29, 1);
        Platform(layer, 45, 53, 23, 2);
        Platform(layer, 44, 49, 16, 3);
        Platform(layer, 50, 53, 11, 4);
        Fill(layer, 49, 24, 50, 31, Terrain(3, 7));
        Carve(layer, 49, 27, 50, 29);

        // 下水道主通道与跳台。
        Platform(layer, -1, 41, 31, 5);
        Platform(layer, 2, 8, 27, 6);
        Platform(layer, 12, 18, 27, 7);
        Platform(layer, 23, 28, 30, 0);
        Platform(layer, 33, 39, 27, 1);

        // 阶梯、悬空小平台与隐藏房间入口。
        Platform(layer, 0, 4, 26, 2);
        Platform(layer, 4, 8, 24, 3);
        Platform(layer, 18, 21, 21, 4);
        Platform(layer, 20, 24, 19, 5);
        Platform(layer, 46, 48, 20, 6);
        Platform(layer, 51, 53, 18, 7);
    }

    private static void BuildDecor(uint[,] layer)
    {
        // 拱门、彩窗和火把给房间建立视觉节奏。
        foreach (var x in new[] { -5, 2, 13, 20, 25, 45, 52 })
        {
            Set(layer, x, 3 + PositiveMod(x, 3) * 5, Decor(3, PositiveMod(x, 8)));
            Set(layer, x + 1, 3 + PositiveMod(x, 3) * 5, Decor(5, PositiveMod(x + 2, 8)));
        }
        foreach (var point in new[] { (-4, 20), (6, 20), (15, 22), (25, 22), (31, 27), (40, 23), (46, 27), (52, 21) })
            Set(layer, point.Item1, point.Item2, Decor(0, PositiveMod(point.Item1, 8)));

        // 钟楼链条贯穿多个楼层，部分使用 Tiled flip flag。
        foreach (var x in new[] { 32, 39 })
        for (var y = 2; y < 29; y++)
            if (y % 4 != 0) Set(layer, x, y, Decor(1, PositiveMod(y + x, 8)) | (y % 2 == 0 ? FlipHorizontal : 0));

        // 下水道管线和排水口。
        for (var x = 0; x <= 40; x++)
            if (x % 5 != 1) Set(layer, x, 26, Decor(4, PositiveMod(x, 8)));
        foreach (var x in new[] { 1, 10, 19, 31, 40, 47 })
        for (var y = 27; y <= 31; y++)
            Set(layer, x, y, Decor(4, PositiveMod(x + y, 8)) | (x % 2 == 0 ? FlipVertical : 0));

        // 尖刺与发光机关。
        foreach (var range in new[] { (5, 7, 21), (16, 18, 23), (24, 26, 26), (36, 38, 24), (47, 49, 28) })
            for (var x = range.Item1; x <= range.Item2; x++) Set(layer, x, range.Item3, Decor(6, PositiveMod(x, 8)));
        foreach (var point in new[] { (17, 16), (24, 9), (33, 20), (38, 8), (47, 15), (52, 10) })
            Set(layer, point.Item1, point.Item2, Decor(7, PositiveMod(point.Item1 + point.Item2, 8)));
    }

    private static void BuildForeground(uint[,] layer)
    {
        // 半透明前景藤蔓和栅栏用于验证第四层遮挡，但不会大面积盖住 traversal 路径。
        foreach (var x in new[] { -7, 8, 11, 27, 30, 43, 54 })
        for (var y = 3; y < 31; y++)
            if ((x + y) % 3 != 0) Set(layer, x, y, Decor(2, PositiveMod(x + y, 8)));
        foreach (var x in new[] { 16, 17, 24, 25, 36, 37, 48, 49 })
        for (var y = 1; y <= 4; y++)
            Set(layer, x, y, Decor(1, PositiveMod(x + y, 8)) | FlipHorizontal);
        for (var x = -5; x <= 52; x += 6)
            Set(layer, x, 31, Decor(7, PositiveMod(x, 8)));
    }

    private static void WriteTileset(string path, string name, string image)
    {
        var tileset = new
        {
            type = "tileset",
            version = "1.12",
            tiledversion = "1.12.2",
            name,
            tilewidth = TileSize,
            tileheight = TileSize,
            tilecount = AtlasColumns * AtlasRows,
            columns = AtlasColumns,
            image,
            imagewidth = AtlasSize,
            imageheight = AtlasSize,
            margin = 0,
            spacing = 0
        };
        File.WriteAllText(path, JsonSerializer.Serialize(tileset, JsonOptions), new UTF8Encoding(false));
    }

    private static string BuildSvg(byte[] pixels)
    {
        var output = new StringBuilder();
        output.Append("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"64\" height=\"64\" viewBox=\"0 0 64 64\" shape-rendering=\"crispEdges\">");
        for (var y = 0; y < AtlasSize; y++)
        {
            var x = 0;
            while (x < AtlasSize)
            {
                var offset = (y * AtlasSize + x) * 4;
                var r = pixels[offset];
                var g = pixels[offset + 1];
                var b = pixels[offset + 2];
                var a = pixels[offset + 3];
                var run = 1;
                while (x + run < AtlasSize)
                {
                    var next = (y * AtlasSize + x + run) * 4;
                    if (pixels[next] != r || pixels[next + 1] != g || pixels[next + 2] != b || pixels[next + 3] != a) break;
                    run++;
                }
                if (a != 0)
                {
                    output.Append("<rect x=\"").Append(x).Append("\" y=\"").Append(y)
                        .Append("\" width=\"").Append(run).Append("\" height=\"1\" fill=\"#")
                        .Append(r.ToString("x2")).Append(g.ToString("x2")).Append(b.ToString("x2")).Append('"');
                    if (a != 255) output.Append(" opacity=\"").Append((a / 255.0).ToString("0.###", System.Globalization.CultureInfo.InvariantCulture)).Append('"');
                    output.Append("/>");
                }
                x += run;
            }
        }
        output.Append("</svg>");
        return output.ToString();
    }

    private static byte[] BuildPng(byte[] rgba)
    {
        var stride = AtlasSize * 4;
        var scanlines = new byte[(stride + 1) * AtlasSize];
        for (var y = 0; y < AtlasSize; y++)
            Buffer.BlockCopy(rgba, y * stride, scanlines, y * (stride + 1) + 1, stride);

        using var compressed = new MemoryStream();
        using (var zlib = new ZLibStream(compressed, CompressionLevel.Optimal, leaveOpen: true))
            zlib.Write(scanlines);

        using var png = new MemoryStream();
        png.Write([137, 80, 78, 71, 13, 10, 26, 10]);
        var header = new byte[13];
        BinaryPrimitives.WriteUInt32BigEndian(header.AsSpan(0, 4), AtlasSize);
        BinaryPrimitives.WriteUInt32BigEndian(header.AsSpan(4, 4), AtlasSize);
        header[8] = 8;
        header[9] = 6; // RGBA8
        WritePngChunk(png, "IHDR"u8, header);
        WritePngChunk(png, "IDAT"u8, compressed.ToArray());
        WritePngChunk(png, "IEND"u8, []);
        return png.ToArray();
    }

    private static void WritePngChunk(Stream output, ReadOnlySpan<byte> type, byte[] data)
    {
        Span<byte> number = stackalloc byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(number, (uint)data.Length);
        output.Write(number);
        output.Write(type);
        output.Write(data);

        var crc = 0xffff_ffffu;
        foreach (var value in type) crc = Crc32Byte(crc, value);
        foreach (var value in data) crc = Crc32Byte(crc, value);
        BinaryPrimitives.WriteUInt32BigEndian(number, ~crc);
        output.Write(number);
    }

    private static uint Crc32Byte(uint crc, byte value)
    {
        crc ^= value;
        for (var bit = 0; bit < 8; bit++) crc = (crc >> 1) ^ (0xedb8_8320u & (uint)-(int)(crc & 1));
        return crc;
    }

    private static Pixel TerrainPixel(int row, int column, int x, int y)
    {
        var bases = new[]
        {
            new Pixel(20, 29, 46, 255), new Pixel(36, 48, 65, 255), new Pixel(48, 53, 67, 255),
            new Pixel(38, 59, 65, 255), new Pixel(43, 64, 50, 255), new Pixel(28, 61, 67, 255),
            new Pixel(78, 45, 43, 255), new Pixel(54, 38, 72, 255)
        };
        var baseColor = bases[row];
        var noise = ((x * 3 + y * 5 + column * 7) % 11) - 5;
        var pixel = Shift(baseColor, noise);
        if (y == 0) pixel = Shift(baseColor, 22);
        if (y is 3 or 7) pixel = Shift(baseColor, -15);
        if ((x + (y >= 4 ? 4 : 0) + column) % 8 == 0) pixel = Shift(baseColor, -22);
        if (row == 4 && (x + column) % 5 == 0 && y < 3) pixel = new Pixel(65, 104, 61, 255);
        if (row == 5 && y == 6) pixel = new Pixel(26, 92, 101, 255);
        if (row == 6 && (x == 2 || x == 5) && y < 3) pixel = new Pixel(143, 67, 45, 255);
        if (row == 7 && (x == y || x + y == 7) && (column % 2 == 0)) pixel = new Pixel(91, 208, 194, 255);
        if (row == 7 && x is >= 3 and <= 4 && y is >= 3 and <= 4 && column % 2 == 1) pixel = new Pixel(224, 151, 58, 255);
        return pixel;
    }

    private static Pixel DecorPixel(int row, int column, int x, int y)
    {
        var clear = new Pixel(0, 0, 0, 0);
        return row switch
        {
            0 => FlamePixel(column, x, y, clear),
            1 => (x == 3 + ((y + column) & 1) || x == 4 - ((y + column) & 1))
                ? new Pixel(100, 118, 120, 255) : clear,
            2 => (x == PositiveMod(y + column, 5) + 1 || x == PositiveMod(y + column + 1, 5) + 1)
                ? new Pixel((byte)(48 + column * 3), (byte)(105 + column * 4), 62, 230) : clear,
            3 => (y <= 1 && x is >= 1 and <= 6 || x is 1 or 6 && y <= 6)
                ? new Pixel(82, 91, 103, 255) : clear,
            4 => (column % 2 == 0 ? y is 3 or 4 : x is 3 or 4)
                ? new Pixel(37, 116, 121, 255) : clear,
            5 => (x is >= 2 and <= 5 && y is >= 1 and <= 5)
                ? ((x + y + column) % 3 == 0 ? new Pixel(73, 183, 173, 220) : new Pixel(53, 79, 111, 220)) : clear,
            6 => y >= 7 - Math.Abs(3 - x) / 2
                ? new Pixel((byte)(145 + column * 6), 62, 47, 255) : clear,
            7 => RunePixel(column, x, y, clear),
            _ => clear
        };
    }

    private static Pixel FlamePixel(int column, int x, int y, Pixel clear)
    {
        if (x is 3 or 4 && y >= 4) return new Pixel(93, 72, 58, 255);
        if (y <= 4 && Math.Abs(x - 3.5) <= (4 - y) / 2.0 + 0.5)
            return y <= 1 ? new Pixel(255, 215, 92, 245) : new Pixel((byte)(222 + column * 3), 112, 48, 245);
        return clear;
    }

    private static Pixel RunePixel(int column, int x, int y, Pixel clear)
    {
        var cyan = new Pixel(79, 224, 207, 220);
        var amber = new Pixel(235, 157, 57, 220);
        var color = column % 2 == 0 ? cyan : amber;
        if (column < 4)
            return x == y || x + y == 7 ? color : clear;
        return (x is 3 or 4 && y is >= 1 and <= 6) || (y is 3 or 4 && x is >= 1 and <= 6) ? color : clear;
    }

    private static Pixel Shift(Pixel value, int delta) => new(
        (byte)Math.Clamp(value.R + delta, 0, 255),
        (byte)Math.Clamp(value.G + delta, 0, 255),
        (byte)Math.Clamp(value.B + delta, 0, 255),
        value.A);

    private static uint Terrain(int row, int column) => TerrainFirstGid + (uint)(row * AtlasColumns + PositiveMod(column, AtlasColumns));
    private static uint Decor(int row, int column) => DecorFirstGid + (uint)(row * AtlasColumns + PositiveMod(column, AtlasColumns));

    private static void Platform(uint[,] layer, int startX, int endX, int y, int variant)
    {
        for (var x = startX; x <= endX; x++)
        {
            var column = x == startX ? 0 : x == endX ? 2 : 1 + PositiveMod(x + variant, 6);
            Set(layer, x, y, Terrain(1, column));
            if (y + 1 < MapHeight) Set(layer, x, y + 1, Terrain(2, PositiveMod(x + variant, 8)));
        }
    }

    private static void Fill(uint[,] layer, int minX, int minY, int maxX, int maxY, uint value)
    {
        for (var y = minY; y <= maxY; y++)
        for (var x = minX; x <= maxX; x++)
            Set(layer, x, y, value);
    }

    private static void Carve(uint[,] layer, int minX, int minY, int maxX, int maxY) => Fill(layer, minX, minY, maxX, maxY, 0);

    private static uint Get(uint[,] layer, int worldX, int worldY)
    {
        var x = worldX - MapMinX;
        return x < 0 || x >= MapWidth || worldY < 0 || worldY >= MapHeight ? 0 : layer[worldY, x];
    }

    private static void Set(uint[,] layer, int worldX, int worldY, uint value)
    {
        var x = worldX - MapMinX;
        if (x < 0 || x >= MapWidth || worldY < 0 || worldY >= MapHeight) return;
        layer[worldY, x] = value;
    }

    private static int PositiveMod(int value, int modulus) => ((value % modulus) + modulus) % modulus;

    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };
    private readonly record struct Pixel(byte R, byte G, byte B, byte A);
}
