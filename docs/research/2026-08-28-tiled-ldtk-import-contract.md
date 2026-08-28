# Tiled / LDtk 外部地图导入契约调研

日期：2026-08-28  
目标任务：`P1-Renderer2D-Tilemap-Chunked-Layers-02`  
资料范围：只使用 Tiled、LDtk 官方文档和官方生成的 JSON Schema；本文中的“建议”“首版契约”是结合 Kadath 当前代码作出的设计结论，不是外部格式原文。

## 1. 结论摘要

外部地图导入必须作为 Chunked Layers 的同一条能力链实现，但不能直接把 Tiled 或 LDtk 数据写进当前 Scene v9 的 `Tilemap.cells: [1024]u16`。首版应先建立一个与来源格式解耦的 `MapImportIR`，再由它生成 TileSet、Layer、Chunk 和可诊断的未消费语义数据。

首版可用范围建议如下：

- Tiled：支持当前 JSON 地图（`.tmj` 或内容等价的 `.json`）、外部 JSON Tileset（`.tsj`）、正交地图、有限地图、无限 Chunk、多个视觉图层、Group 递归展开、多个 atlas Tileset、全部 8 种正交 Tile 变换。
- LDtk：支持 JSON 1.5.3、显式选择单个 Level、内嵌 Level 或外部 `.ldtkl`、Tiles / AutoLayer 视觉内容、IntGrid 与 Entity 的检测和诊断、atlas Tileset、X/Y 翻转。
- Tiled 首版数据编码支持原生 `unsigned int` JSON 数组；`base64` 及 `gzip` / `zlib` / `zstd` 必须显式报“不支持”，不能误读或静默跳过。压缩支持可在同一任务的后续小提交补齐。
- Tiled 的 Object Layer、Tile Collision、Custom Properties，以及 LDtk 的 IntGrid、Entity、Enum 数据不能静默丢弃。首版视觉导入应生成结构化 warning；严格模式应把这类 warning 升级为错误。
- 不支持的投影、非默认混合模式、图片集合 Tileset、尺寸不一致 Tile、非法路径、未知版本或数据长度错误必须拒绝。
- 所有来源路径都以“声明该路径的文档”所在目录为基准解析；默认拒绝绝对路径和逃逸导入根目录的路径。

这意味着 `P1-Renderer2D-Tilemap-Chunked-Layers-02` 的正确顺序是：规范化 IR → TileSet/Layer/Chunk 新契约 → Tiled importer → LDtk importer → 编辑器入口与结构化导入报告，而不是先扩大 `32×32` 常量。

## 2. 官方格式基线

### 2.1 Tiled JSON / TMJ / TSJ

截至调研日，Tiled 稳定文档是 1.12.2。JSON Map 的根对象包含 `type: "map"`、格式 `version`、保存应用版本 `tiledversion`、`orientation`、`renderorder`、地图网格尺寸、`layers` 与 `tilesets`；`version` 从 Tiled 1.6 起保存为字符串。[Tiled JSON Map](https://doc.mapeditor.org/en/stable/reference/json-map-format/)

Tiled 支持 `orthogonal`、`isometric`、`oblique`、`staggered`、`hexagonal` 五种方向；无限地图没有固定边界，Tile Layer 数据按 Chunk 保存。Chunk 的 `x`、`y` 是以 Tile 为单位的坐标，官方示例明确包含 `y: -16`。[Tiled JSON Map / Map 与 Chunk](https://doc.mapeditor.org/en/stable/reference/json-map-format/)

Tile Layer 的数据可以是原生 JSON `unsigned int` 数组，也可以是 base64 字符串；压缩算法可为 `zlib`、`gzip` 或 `zstd`。base64 解码和解压后，每个 GID 是一个小端序 `u32`。[Tiled JSON Map / Layer](https://doc.mapeditor.org/en/stable/reference/json-map-format/)、[Tiled TMX data](https://doc.mapeditor.org/en/stable/reference/tmx-map-format/)

无限地图使用 `chunks`；每个 Chunk 自带 `x`、`y`、`width`、`height` 和 `data`，其内容语义与普通 Layer 的 `data` 一致。[Tiled JSON Map / Chunk](https://doc.mapeditor.org/en/stable/reference/json-map-format/)

一个地图可引用多个 Tileset。地图内的 Tileset 引用通过 `firstgid` 建立地图局部 GID 范围；外部 Tileset 使用 `source` 指向独立文件，Tileset 自身可定义单张 atlas 图片、`margin`、`spacing`、`columns`、`tilecount`、Tile 尺寸、动画、碰撞对象层和属性。[Tiled JSON Map / Tileset](https://doc.mapeditor.org/en/stable/reference/json-map-format/)

Tiled 推荐将 Tileset 保存为外部文件，以便在多个地图间共享碰撞、属性、Terrain 等元信息。[Tiled Editing Tilesets](https://doc.mapeditor.org/en/stable/manual/editing-tilesets/)

GID 的高四位是变换标志：`0x80000000` 水平翻转、`0x40000000` 垂直翻转、`0x20000000` 对角翻转；`0x10000000` 在六边形地图表示 120° 旋转，即使导入非六边形地图也必须清除。正交地图的变换顺序是先对角，再水平、垂直。清除标志后的 GID 为 0 表示空格；非零 GID 通过“小于等于 GID 的最大 `firstgid`”选 Tileset，再相减得到 local Tile ID。[Tiled Global Tile IDs](https://doc.mapeditor.org/en/stable/reference/global-tile-ids/)

Tiled 文档说明地图中图层出现的顺序就是渲染顺序；Group 的 `offsetx`、`offsety`、`opacity`、`visible`、`tintcolor` 会递归影响子图层。[Tiled TMX Map / layers and groups](https://doc.mapeditor.org/en/stable/reference/tmx-map-format/)

Tile Layer 本身每格只能保存 Tile 引用和 H/V/对角变换标志；自由对象、矩形、点、椭圆、多边形、折线、Tile Object 等放在 Object Layer，并可带 Custom Properties。[Tiled Working with Layers](https://doc.mapeditor.org/en/stable/manual/layers/)、[Tiled Working with Objects](https://doc.mapeditor.org/en/stable/manual/objects/)

Tile 定义可带 `objectgroup` 碰撞形状；Tiled 的 Tile Collision Editor 支持为形状附加自定义属性。[Tiled JSON Map / Tile Definition](https://doc.mapeditor.org/en/stable/reference/json-map-format/)、[Tiled Editing Tilesets / Tile Collision](https://doc.mapeditor.org/en/stable/manual/editing-tilesets/)

Custom Properties 支持 bool、color、file、float、int、object、string，以及自定义 enum / class；其中 file 属性保存相对路径。[Tiled Custom Properties](https://doc.mapeditor.org/en/stable/manual/custom-properties/)

### 2.2 LDtk JSON

截至调研日，LDtk 官方 JSON 页面和官方生成 Schema 的当前版本是 1.5.3；根对象以字符串 `jsonVersion` 标识文件格式版本。[LDtk JSON 1.5.3](https://ldtk.io/json/)、[LDtk 官方 JSON Schema](https://ldtk.io/files/JSON_SCHEMA.json)

LDtk Project JSON 包含项目设置、`defs` 和 `levels`。`defs` 中包括 Layer、Tileset、Entity、Enum 等定义；官方说明对游戏读取最重要的定义通常是 Tileset 与 Enum，实例上大量 `__` 前缀字段用于直接提供解析所需信息。[LDtk JSON overview](https://ldtk.io/docs/game-dev/json-overview/)、[LDtk defs section](https://ldtk.io/docs/game-dev/json-overview/defs-section/)

启用 Separate Level Files 后，Project JSON 的 Level `layerInstances` 为 `null`，`externalRelPath` 指向对应 `.ldtkl`；`.ldtkl` 保存与内嵌 Level 相同的 Level 数据和所有图层内容。[LDtk Optional separate levels](https://ldtk.io/docs/game-dev/json-overview/optional-separate-levels/)、[LDtk JSON Schema / Level](https://ldtk.io/files/JSON_SCHEMA.json)

`layerInstances` 支持 `IntGrid`、`Entities`、`Tiles`、`AutoLayer`。Layer 实例包含格数 `__cWid` / `__cHei`、格尺寸 `__gridSize`、总像素偏移 `__pxTotalOffsetX` / `__pxTotalOffsetY`、可见性和透明度。官方 Schema 明确给出这四类 `__type`。[LDtk JSON Schema / LayerInstance](https://ldtk.io/files/JSON_SCHEMA.json)

Tile Layer 使用 `gridTiles`，AutoLayer 使用 `autoLayerTiles`。数组按显示顺序排列，前面的 Tile 在下面；Tile 实例包含 local Tile ID `t`、Layer 内像素坐标 `px`、Tileset 内像素坐标 `src`、透明度 `a`、X/Y 两位翻转标志 `f`。[LDtk Layer instances](https://ldtk.io/docs/game-dev/json-overview/layer-instances/)、[LDtk JSON Schema / Tile](https://ldtk.io/files/JSON_SCHEMA.json)

Level 的 `layerInstances` 数组顺序与 Tiled 不同：LDtk 官方 Schema 说明第一个是最上层，最后一个在最下层。[LDtk JSON Schema / Level.layerInstances](https://ldtk.io/files/JSON_SCHEMA.json)

Tileset 定义包含 `uid`、`relPath`、`tileGridSize`、`padding`、`spacing`、图像像素尺寸以及网格列行数；`relPath` 相对于 Project JSON。[LDtk JSON Schema / TilesetDef](https://ldtk.io/files/JSON_SCHEMA.json)

IntGrid 是整数网格，`intGridCsv` 按从左到右、从上到下保存，0 为空，数组长度必须为 `__cWid * __cHei`。IntGrid 常被用作碰撞或规则输入，AutoLayer 可从 IntGrid 生成视觉 Tile。[LDtk JSON / intGridCsv](https://ldtk.io/json/)、[LDtk Auto layers](https://ldtk.io/docs/general/auto-layers/)

Entity 实例包含标识、IID、像素 / 网格坐标、宽高、pivot、tag 和 `fieldInstances`；字段值在 `__value` 中，类型由 `__type` 表示，涵盖基础类型、Color、Enum、Point、Tile、EntityRef 及其数组。[LDtk JSON Schema / EntityInstance and FieldInstance](https://ldtk.io/files/JSON_SCHEMA.json)、[LDtk Entity fields](https://ldtk.io/docs/game-dev/json-overview/entity-fields/)

Free 与 GridVania 布局通过 Level 的 `worldX` / `worldY` 确定世界像素位置；Linear 布局里这些值为 `-1`，不能当作有效世界坐标。Multi-Worlds 在 1.5.3 Schema 中已经出现，但官方仍将其描述为迁移中的结构。[LDtk World layout](https://ldtk.io/docs/game-dev/json-overview/world-layout/)、[LDtk JSON Schema / worlds](https://ldtk.io/files/JSON_SCHEMA.json)

## 3. Kadath Scene v9 的现状与不可直接映射点

以下结论来自当前工作树代码：

| 现状 | 代码证据 | 对外部导入的影响 |
|---|---|---|
| Scene source / artifact 当前版本均为 v9 | `app/scene.zig:4-15` | 新 Tilemap 契约必须推进版本，不能让 v9 误读新布局 |
| 最多 1 个 Tilemap，最大 `32×32` | `app/scene.zig:27-30` | 无法承载多图层、无限地图和多个 Chunk |
| Cell 固定为 `[1024]u16`，0 为空，正数是单 atlas 的 one-based index | `app/scene.zig:259-271`、`app/scene.zig:1711-1741` | 无法保存 Tiled `u32 GID`、Tileset 来源和变换标志，也无法保留 LDtk `f` |
| 单 Tilemap 只引用一个 `textureId` 和规则 atlas 行列 | `app/scene.zig:259-267` | Tiled 同一 Layer 混用多个 Tileset 时没有无损映射 |
| Scene JSON 上限 64 KiB，KSCN 上限 1 MiB | `app/scene.zig:35-36` | 大地图不能继续以内联 Cells 膨胀 Scene 文档 |
| Scene 最多 4 张纹理 | `app/scene.zig:16` | 常见多 Tileset 地图会撞上旧纹理预算 |
| Renderer2D 最多 1 层、`32×32`，每帧验证并计数整张地图所有非空 Cell | `modules/renderer2d/src/main.zig:29-33`、`modules/renderer2d/src/main.zig:178-218` | 只加 Chunk 存储仍会被整帧实例预算挡住；必须只发布 / 验证可见 Chunk |
| 当前 UV 只支持无 margin / spacing 的等分 atlas | `modules/renderer2d/src/main.zig:267-289` | Tiled / LDtk atlas 的 padding、spacing 不能正确采样 |
| 当前坐标是左上原点、X 向右、Y 向下 | `app/scene.zig:282-286`、`modules/renderer2d/src/main.zig:226-235` | 与 Tiled、LDtk 的 2D 像素坐标方向相同，不需要 Y 轴翻转 |

因此，外部 importer 不能以 Scene v9 的 Wire struct 为解析目标。Importer 应先构造来源无关、可验证的 IR；只有 IR 完整成功后，才能原子生成新版本资源。

## 4. 首版来源无关导入 IR

建议把 importer 输出定义为下列概念，而非具体语言布局：

```text
MapImportIR
  sourceKind             tiled | ldtk
  sourceVersion
  sourceDocuments[]      规范化相对路径 + 内容 identity
  tileSets[]
    stableSourceId
    imagePath
    tileWidth / tileHeight
    imageWidth / imageHeight
    margin / spacing
    columns / rows
    deferredMetadata     动画、碰撞、属性、Enum tag 等未消费信息摘要
  layers[]               内部固定为“从底到顶”的稳定顺序
    stableLayerId
    name
    visible / opacity
    originPxX / originPxY
    chunks[]
      chunkX / chunkY    有符号坐标
      cells[32*32]
        tileSetIndex
        localTileId
        transform        规范化 D4 / H-V-D 标志
        alpha
  semanticLayers[]       IntGrid、Object、Entity 等，不允许无声丢失
  diagnostics[]          code、severity、document、JSON path、message
```

关键约束：

- 外部 GID 只能存在于 Tiled adapter 内；进入 IR 前必须拆成 `tileSetIndex + localTileId + transform`。
- 内部 Cell ID 至少需要 `u32` local Tile ID，Tileset 引用与变换标志使用独立字段；不能继续依赖 `u16` one-based atlas index。
- `chunkX` / `chunkY` 使用有符号整数，建议 `i32`；所有加乘运算先用更宽整数检查溢出。
- Layer 顺序统一为从底到顶，Renderer 按数组顺序提交；LDtk adapter 负责逆序，Tiled adapter 保持来源顺序。
- IR 包含来源文档和诊断，保证同一输入得到相同顺序、相同 ID、相同 artifact bytes 和相同 warning 列表。
- 解析、路径加载、Schema 验证、语义验证和规范化全部成功后才发布资源；任何失败都不得留下半写入 Scene 或部分 TileSet。

## 5. Tiled 首版支持矩阵

### 5.1 支持

| 能力 | 首版行为 | 确定性规则 |
|---|---|---|
| `.tmj` / `.json` Map | 支持 | JSON 根必须是 `type: "map"`；格式版本固定支持字符串 `1.12`，`tiledversion` 只记录到导入报告。Tiled 将格式版本与应用版本分开保存。[官方字段](https://doc.mapeditor.org/en/stable/reference/json-map-format/) |
| `.tsj` 外部 Tileset | 支持 | `source` 相对 TMJ 解析；TSJ 内图片路径相对 TSJ 解析；TSJ 根必须是 `type: "tileset"`。外部 Tileset 是 Tiled 推荐方式。[JSON Tileset](https://doc.mapeditor.org/en/stable/reference/json-map-format/)、[外部 Tileset 建议](https://doc.mapeditor.org/en/stable/manual/editing-tilesets/) |
| 内嵌 atlas Tileset | 支持 | 与 TSJ 走同一 Tileset 验证器，只是基准目录为 TMJ 所在目录。Tileset 可内嵌或外置。[官方说明](https://doc.mapeditor.org/en/stable/manual/editing-tilesets/) |
| 正交地图 | 支持 | `orientation == "orthogonal"` 且 `renderorder == "right-down"`。官方列出其它投影和其它正交渲染顺序，首版不猜测映射。[Map 字段](https://doc.mapeditor.org/en/stable/reference/json-map-format/) |
| 有限 Tile Layer | 支持 | `data.len == width * height`；从左到右、从上到下映射到有符号网格坐标，再重分块为内部 `32×32` Chunk。Tiled Tile Layer 最终形成 GID 数组。[TMX data](https://doc.mapeditor.org/en/stable/reference/tmx-map-format/) |
| 无限 Chunk Tile Layer | 支持 | 以来源 Chunk 的 `x/y/width/height` 为权威；允许负坐标；先展开为绝对 Tile 坐标，再按内部固定 Chunk 尺寸重分块，不能假设来源 Chunk 也是 `32×32`。[JSON Chunk](https://doc.mapeditor.org/en/stable/reference/json-map-format/) |
| Group Layer | 支持 | 深度优先按来源出现顺序展开；`visible` 取祖先与自身的 AND，`opacity` 连乘，像素 offset 累加。Group 属性递归影响子层。[TMX group](https://doc.mapeditor.org/en/stable/reference/tmx-map-format/) |
| 多 Tile Layer | 支持 | 保持来源出现顺序作为从底到顶顺序；Tiled 明确图层出现顺序就是渲染顺序。[TMX map](https://doc.mapeditor.org/en/stable/reference/tmx-map-format/) |
| 同层多个 atlas Tileset | 支持 | 每个非零 GID 独立解析 Tileset；Renderer 必须按稳定 cell 顺序在纹理切换处 flush，不能把整层按纹理重排。GID 的 Tileset 解析规则由官方定义。[Global Tile IDs](https://doc.mapeditor.org/en/stable/reference/global-tile-ids/) |
| H / V / 对角变换 | 支持 | 读取并清除最高四位；正交变换保留“先对角、再水平、再垂直”的语义。bit 29 清除并产生 stale-hex-flag warning。[Global Tile IDs](https://doc.mapeditor.org/en/stable/reference/global-tile-ids/) |
| atlas margin / spacing | 支持 | UV rect 使用 `margin + tileIndex * (tileSize + spacing)` 计算并检查不越图像边界；不能沿用当前等分 UV。[JSON Tileset 字段](https://doc.mapeditor.org/en/stable/reference/json-map-format/) |
| Layer visible / opacity / offset | 支持 | 递归组合 Group 后写入内部 Layer；opacity 必须在 `[0,1]`，offset 使用有限像素数。[JSON Layer 字段](https://doc.mapeditor.org/en/stable/reference/json-map-format/) |
| 原生 JSON GID 数组 | 支持 | `data` 必须是 `unsigned int` 数组；若 `encoding` 出现，只接受省略或 `csv`，若 `compression` 非空则拒绝。[JSON Layer 字段](https://doc.mapeditor.org/en/stable/reference/json-map-format/) |

### 5.2 必须拒绝

| 条件 | 诊断建议 | 原因与官方依据 |
|---|---|---|
| `orientation` 不是 `orthogonal` | `TILED_UNSUPPORTED_ORIENTATION` | 官方支持多种投影，但 Kadath 首版没有坐标投影模型。[Map 字段](https://doc.mapeditor.org/en/stable/reference/json-map-format/) |
| `renderorder` 不是 `right-down` | `TILED_UNSUPPORTED_RENDER_ORDER` | 其它方向改变 Tile 提交顺序，在大 Tile / 透明 Tile 下会改变结果。[TMX map](https://doc.mapeditor.org/en/stable/reference/tmx-map-format/) |
| base64 或任何压缩数据 | `TILED_UNSUPPORTED_DATA_ENCODING` | 官方允许 base64 和 `gzip` / `zlib` / `zstd`；首版未实现时必须显式拒绝，不能当空层。[JSON Layer](https://doc.mapeditor.org/en/stable/reference/json-map-format/) |
| 图片集合 Tileset、Tile 自带独立 image | `TILED_UNSUPPORTED_IMAGE_COLLECTION` | Tiled 支持单 atlas 和图片集合两种 Tileset；Kadath 首版只建 atlas 资源。[Editing Tilesets](https://doc.mapeditor.org/en/stable/manual/editing-tilesets/) |
| Tileset Tile 尺寸与 Map 网格不同、非默认 `tileoffset`、`tilerendersize` 或 `fillmode` | `TILED_UNSUPPORTED_TILE_GEOMETRY` | 官方允许 Tile 大于网格并向上、向右延伸，也允许绘制尺寸 / 对齐变化；当前 quad 模型不能保持该语义。[TMX map and tileset](https://doc.mapeditor.org/en/stable/reference/tmx-map-format/) |
| 非 `normal` blend mode、非白 tint、非 1 parallax | `TILED_UNSUPPORTED_LAYER_EFFECT` | Tiled 1.12 定义多种 blend mode，并支持 tint 与 parallax；首版 Renderer 没有等价实现。[JSON Layer](https://doc.mapeditor.org/en/stable/reference/json-map-format/) |
| GID 去标志后找不到 Tileset，local ID 不存在或 atlas rect 越界 | `TILED_INVALID_GID` | 官方规定按最大 `firstgid <= gid` 解析且 0 为空。[Global Tile IDs](https://doc.mapeditor.org/en/stable/reference/global-tile-ids/) |
| 来源 Chunk 重叠声明同一绝对 Cell | `TILED_OVERLAPPING_CHUNKS` | 官方 Chunk 提供明确坐标和尺寸；重叠输入没有单一来源真相，应拒绝而非“后写覆盖”。[JSON Chunk](https://doc.mapeditor.org/en/stable/reference/json-map-format/) |
| 动画 Tile 被实际使用 | `TILED_UNSUPPORTED_ANIMATED_TILE` | Tile 定义可包含 animation；把它静态化会改变可见行为。[JSON Tile Definition](https://doc.mapeditor.org/en/stable/reference/json-map-format/) |
| 绝对路径、路径逃逸、循环外部引用、重复 `firstgid` 或未递增范围 | `IMPORT_INVALID_EXTERNAL_REFERENCE` | Tiled 外部 Tileset 由 `source` 引用且 Tileset 按递增 `firstgid` 解析；路径限制是 Kadath 的安全边界。[TMX tileset](https://doc.mapeditor.org/en/stable/reference/tmx-map-format/) |
| 未支持或更高格式版本 | `TILED_UNSUPPORTED_VERSION` | Tiled 格式随 minor 版本推进，未知字段可警告，但已知语义变化不能按旧契约猜测。[TMX compatibility note](https://doc.mapeditor.org/en/stable/reference/tmx-map-format/) |

### 5.3 必须警告；严格模式升级为错误

| 来源内容 | warning | 首版行为 |
|---|---|---|
| Object Layer / Image Layer | `TILED_LAYER_NOT_IMPORTED` | 记录 layer id、name、type 和数量，不生成 Runtime 对象；Tiled 官方说明 Object Layer 承载生成点、出口等游戏语义，不能无声忽略。[Working with Objects](https://doc.mapeditor.org/en/stable/manual/objects/) |
| Tile `objectgroup` 碰撞形状 | `TILED_COLLISION_NOT_BAKED` | 保留来源摘要到 TileSet deferred metadata，但不生成碰撞；Tile Collision 是官方 Tileset 能力。[Editing Tilesets](https://doc.mapeditor.org/en/stable/manual/editing-tilesets/) |
| Map / Layer / Tileset / Tile Custom Properties | `TILED_PROPERTIES_NOT_CONSUMED` | 记录 JSON path 与 property 数量；严格模式拒绝。官方属性可包含对象引用、自定义 Enum / Class 等玩法数据。[Custom Properties](https://doc.mapeditor.org/en/stable/manual/custom-properties/) |
| Wang / Terrain / probability | `TILED_AUTHORING_METADATA_NOT_CONSUMED` | Cells 已经是规则求值结果，可继续视觉导入，但报告未消费的编辑元数据。[JSON Tileset](https://doc.mapeditor.org/en/stable/reference/json-map-format/) |
| GID bit 29 在正交地图仍置位 | `TILED_STALE_HEX_FLAG_CLEARED` | 清除此位继续；官方特别要求非六边形解析也要清除。[Global Tile IDs](https://doc.mapeditor.org/en/stable/reference/global-tile-ids/) |
| 未知可选字段 | `TILED_UNKNOWN_FIELD` | 保留 warning 后忽略；官方兼容性建议忽略未知元素 / 属性或发出 warning。[TMX compatibility note](https://doc.mapeditor.org/en/stable/reference/tmx-map-format/) |

## 6. LDtk 首版支持矩阵

### 6.1 支持

| 能力 | 首版行为 | 确定性规则 |
|---|---|---|
| `.ldtk` Project JSON 1.5.3 | 支持 | `jsonVersion` 必须精确为 `1.5.3`，并按官方 1.5.3 Schema 的必需字段和类型验证。[LDtk JSON](https://ldtk.io/json/)、[官方 Schema](https://ldtk.io/files/JSON_SCHEMA.json) |
| 单个显式 Level | 支持 | API 使用 `levelIid` 选择；只有恰好一个 Level 时允许省略。不得默认取数组第一项，因为数组顺序只对 Linear 布局有位置意义。[LDtk World layout](https://ldtk.io/docs/game-dev/json-overview/world-layout/) |
| 外部 `.ldtkl` | 支持 | 当选中 Level 的 `layerInstances == null` 时，从 `externalRelPath` 加载；路径相对 Project JSON，外部 Level IID 必须与占位 Level 一致。[Optional separate levels](https://ldtk.io/docs/game-dev/json-overview/optional-separate-levels/)、[JSON Schema / Level](https://ldtk.io/files/JSON_SCHEMA.json) |
| atlas Tileset | 支持 | `relPath` 相对 Project JSON；按 `tileGridSize`、`padding`、`spacing`、`pxWid/pxHei`、`__cWid/__cHei` 建 TileSet。[JSON Schema / TilesetDef](https://ldtk.io/files/JSON_SCHEMA.json) |
| Tiles Layer | 支持 | 读取 `gridTiles`；以 `t` 为 canonical local Tile ID，并验证 `src` 与 Tileset 几何一致。[JSON Schema / Tile](https://ldtk.io/files/JSON_SCHEMA.json) |
| AutoLayer 视觉输出 | 支持 | 直接读取已求值的 `autoLayerTiles`，不在 Kadath 中重新执行规则。[Layer instances](https://ldtk.io/docs/game-dev/json-overview/layer-instances/) |
| X / Y flip | 支持 | `f & 1` 为 X flip，`f & 2` 为 Y flip，仅允许 0..3。[JSON Schema / Tile.f](https://ldtk.io/files/JSON_SCHEMA.json) |
| Layer visible / opacity / total offset | 支持 | 使用 `visible`、`__opacity`、`__pxTotalOffsetX/Y`；不要自行重复叠加 definition offset。[JSON Schema / LayerInstance](https://ldtk.io/files/JSON_SCHEMA.json) |
| 多视觉 Layer | 支持 | LDtk `layerInstances` 从顶到底，因此先逆序为内部从底到顶，再保持每层内部 tile display order。[JSON Schema / Level.layerInstances](https://ldtk.io/files/JSON_SCHEMA.json) |
| 同 Cell Tile 堆叠 | 有界支持 | 按 `gridTiles` / `autoLayerTiles` 出现顺序为每个 Cell 计算 stack slot，并把同一来源层展开成连续内部子层；slot 0 在底部。展开后超过 Layer 预算则拒绝。[Layer instances](https://ldtk.io/docs/game-dev/json-overview/layer-instances/) |
| 负 Layer 总偏移 | 支持 | Layer origin 使用有符号像素坐标；Tile 的 `px` 必须按 `__gridSize` 对齐。官方明确 total offset 是 definition 与 instance offset 之和。[JSON Schema / LayerInstance](https://ldtk.io/files/JSON_SCHEMA.json) |

### 6.2 必须拒绝

| 条件 | 诊断建议 | 原因与官方依据 |
|---|---|---|
| `jsonVersion != "1.5.3"` | `LDTK_UNSUPPORTED_VERSION` | LDtk 官方强调 JSON 会演进并维护 breaking changes；首版固定 Schema，避免按新格式猜测。[JSON overview / evolution](https://ldtk.io/docs/game-dev/json-overview/) |
| `worlds` 非空或启用 MultiWorlds | `LDTK_UNSUPPORTED_MULTI_WORLD` | 1.5.3 Schema 把 Multi-Worlds 描述为迁移 / 预览结构；首版只处理根 `levels`。[官方 Schema](https://ldtk.io/files/JSON_SCHEMA.json) |
| 多 Level 但未给 `levelIid`，或 IID 不存在 / 重复 | `LDTK_AMBIGUOUS_LEVEL` | Level IID 是稳定实例标识；数组位置不能替代选择器。[JSON Schema / Level](https://ldtk.io/files/JSON_SCHEMA.json) |
| Tileset `relPath == null`、`embedAtlas != null`、不是可加载 atlas 图片 | `LDTK_UNSUPPORTED_TILESET_SOURCE` | 官方 Schema 允许内部 LDtk atlas 或无图片 Tileset，但 Kadath 首版不能映射。[JSON Schema / TilesetDef](https://ldtk.io/files/JSON_SCHEMA.json) |
| `tileGridSize != __gridSize`、Tile `px` 不对齐、`src` 与 `t` / Tileset 几何不一致 | `LDTK_INVALID_TILE_GEOMETRY` | Tile 实例同时提供 local ID、Layer 像素位置和 Tileset 像素位置；不一致时不能任选一个覆盖。[JSON Schema / Tile](https://ldtk.io/files/JSON_SCHEMA.json) |
| Tile `a != 1`，而内部 Cell alpha 尚未实现 | `LDTK_UNSUPPORTED_TILE_ALPHA` | 官方 Tile 实例明确支持 0..1 alpha；静默改成 1 会改变画面。[JSON Schema / Tile.a](https://ldtk.io/files/JSON_SCHEMA.json) |
| `f` 含 0..3 以外位 | `LDTK_INVALID_FLIP_BITS` | 官方只定义 X/Y 两位。[JSON Schema / Tile.f](https://ldtk.io/files/JSON_SCHEMA.json) |
| 展开堆叠后超过 Layer 预算 | `IMPORT_LAYER_BUDGET_EXCEEDED` | LDtk 允许同格多个 Tile 且数组顺序决定上下关系；截断会改变画面。[Layer instances](https://ldtk.io/docs/game-dev/json-overview/layer-instances/) |
| 外部 `.ldtkl` 缺失、IID 不一致、路径逃逸或循环引用 | `IMPORT_INVALID_EXTERNAL_REFERENCE` | `.ldtkl` 是被 Project Level 显式引用的完整 Level 数据，必须与占位项对应。[Optional separate levels](https://ldtk.io/docs/game-dev/json-overview/optional-separate-levels/) |

### 6.3 必须警告；严格模式升级为错误

| 来源内容 | warning | 首版行为 |
|---|---|---|
| IntGrid / `intGridCsv` | `LDTK_INTGRID_NOT_CONSUMED` | 验证数组尺寸和值定义，保存 layer iid、值集合和非零 Cell 数摘要，但不生成碰撞。IntGrid 是整数语义网格且常作为 AutoLayer / collision 输入。[IntGrid layers](https://ldtk.io/docs/general/intgrid-layers/)、[Auto layers](https://ldtk.io/docs/general/auto-layers/) |
| Entity Layer / fields | `LDTK_ENTITIES_NOT_IMPORTED` | 记录 Entity 数、identifier、IID 和 field 类型摘要，不生成 Runtime Object。Entity fields 可含 Enum、Point、Tile、EntityRef 与数组，不能无声丢弃。[Entity fields](https://ldtk.io/docs/game-dev/json-overview/entity-fields/) |
| Enum / external Enum | `LDTK_ENUMS_NOT_CONSUMED` | 记录定义和外部来源；严格模式拒绝。官方 `defs` 明确包含本地和外部 Enum。[defs section](https://ldtk.io/docs/game-dev/json-overview/defs-section/) |
| Tileset `customData` / `enumTags` | `LDTK_TILE_METADATA_NOT_CONSUMED` | 保留来源摘要到 TileSet deferred metadata；不宣称已实现 Gameplay 属性。[JSON Schema / TilesetDef](https://ldtk.io/files/JSON_SCHEMA.json) |
| Level `worldX/worldY/worldDepth` | `LDTK_WORLD_PLACEMENT_NOT_APPLIED` | 首版是“选择一个 Level，以 Level-local 坐标导入”；不把世界布局位置偷偷加入 Scene origin。Free / GridVania 的 world 坐标与 Linear 的 `-1` 哨兵语义不同。[World layout](https://ldtk.io/docs/game-dev/json-overview/world-layout/) |
| 未知非 Schema 字段 | `LDTK_UNKNOWN_FIELD` | 官方 Schema 使用 `additionalProperties: false`；默认拒绝 Schema 外字段，兼容模式可降为 warning 并记录。[官方 Schema](https://ldtk.io/files/JSON_SCHEMA.json) |

## 7. 坐标、Chunk 与顺序的确定性转换

### 7.1 统一坐标系

Kadath、Tiled、LDtk 首版都使用左上原点、X 向右、Y 向下的像素空间，所以不做 Y 轴翻转。来源坐标统一转换为 signed Tile coordinate 与 Layer pixel origin。

Tiled：

```text
absoluteTileX = sourceChunkX + localColumn
absoluteTileY = sourceChunkY + localRow
layerOriginPx = sum(group.offsetPx) + layer.offsetPx
```

LDtk 单 Level 模式：

```text
absoluteTileX = tile.px[0] / layer.__gridSize
absoluteTileY = tile.px[1] / layer.__gridSize
layerOriginPx = [layer.__pxTotalOffsetX, layer.__pxTotalOffsetY]
```

LDtk 的 `worldX/worldY` 首版不参与单 Level 坐标；未来 World 导入模式必须显式建模，不能复用 `-1` 当实际偏移。[LDtk World layout](https://ldtk.io/docs/game-dev/json-overview/world-layout/)

### 7.2 负坐标分块

内部 Chunk 固定 `32×32` Cell。负坐标必须使用数学上的 floor division 和非负 modulo，不能使用向零截断：

```text
chunkX = floorDiv(tileX, 32)
localX = tileX - chunkX * 32       // 恒为 0..31
chunkY = floorDiv(tileY, 32)
localY = tileY - chunkY * 32       // 恒为 0..31
cellIndex = localY * 32 + localX
```

边界例：`tileX = -1` 必须得到 `chunkX = -1, localX = 31`；`tileX = -32` 得到 `chunkX = -1, localX = 0`；`tileX = -33` 得到 `chunkX = -2, localX = 31`。Tiled 官方 Chunk 坐标可为负数，因此这不是可选优化。[Tiled JSON Chunk](https://doc.mapeditor.org/en/stable/reference/json-map-format/)

### 7.3 Tiled GID

```text
flags = gid & 0xF0000000
baseGid = gid & 0x0FFFFFFF
if baseGid == 0: empty
tileset = tileset with maximum firstgid <= baseGid
localTileId = baseGid - tileset.firstgid
transform = canonicalize(diagonal first, then horizontal, then vertical)
```

必须在查 Tileset 前清除全部四个高位。`firstgid` 是地图局部的，不能持久化为跨地图 Tile ID。[Tiled Global Tile IDs](https://doc.mapeditor.org/en/stable/reference/global-tile-ids/)

### 7.4 Layer 顺序

- Tiled：递归展开后保持来源出现顺序，内部把它解释为从底到顶。[Tiled TMX map](https://doc.mapeditor.org/en/stable/reference/tmx-map-format/)
- LDtk：先逆转 `layerInstances`，因为官方定义第一个为最上层；每层的 Tile 数组保持原顺序，前者在下。[LDtk JSON Schema / Level](https://ldtk.io/files/JSON_SCHEMA.json)、[LDtk Layer instances](https://ldtk.io/docs/game-dev/json-overview/layer-instances/)
- 稳定 ID 不用 display name。Tiled 使用 `tiled:<layer-id>`；LDtk 使用 `ldtk:<level-iid>:<layer-iid>:<stack-slot>`。超过 Kadath ID 长度时以完整来源字符串的内容哈希生成短 ID，并做碰撞检测。

## 8. 外部引用与版本策略

### 8.1 路径解析

解析基准：

- TMJ `tilesets[].source`：相对 TMJ。
- TSJ `image`：相对 TSJ。
- LDtk `defs.tilesets[].relPath`：相对 Project `.ldtk`。
- LDtk `levels[].externalRelPath`：相对 Project `.ldtk`。
- Tiled Custom Property 的 file：相对保存它的 Map 文件；首版只诊断，不消费。[Tiled Custom Properties](https://doc.mapeditor.org/en/stable/manual/custom-properties/)

Kadath 安全边界建议：规范化分隔符与 `.` / `..` 后再 resolve；默认只允许位于显式 import root 下的普通文件；拒绝绝对路径、UNC、盘符切换、符号链接逃逸、大小写归一化冲突和引用环。错误必须包含引用文档、原始路径与解析后路径。

### 8.2 版本

- Tiled 首版 pin JSON format `1.12`。`tiledversion` 仅用于报告，不代替格式版本。旧版本数字 `version` 和未来 minor 版本都返回 `TILED_UNSUPPORTED_VERSION`。[Tiled JSON version changelog](https://doc.mapeditor.org/en/stable/reference/json-map-format/)
- LDtk 首版 pin `jsonVersion == "1.5.3"`，按官方 1.5.3 Schema 验证。LDtk 官方建议 importer 持续关注 JSON changes 与 deprecations，因此不能“主版本相同就放行”。[LDtk JSON evolution](https://ldtk.io/docs/game-dev/json-overview/)
- 每次扩展支持版本，都需要新增对应官方格式 fixture 与迁移测试；不修改旧版本解析分支的既有输出。

## 9. 诊断与严格模式

Importer 返回结构化结果：

```text
ImportDiagnostic
  severity    warning | error
  code        稳定机器码
  sourcePath
  jsonPath
  message     中文
```

规则：

- 数据损坏、无法保持视觉语义、安全边界失败、预算溢出：始终 error。
- 未消费但不影响 Tile 视觉输出的玩法 / 编辑元数据：默认 warning；`strict = true` 时升级为 error。
- 不提供“静默忽略未知图层 / 属性”模式。
- warning 必须成为导入结果和 Editor UI 的一部分；仅写日志不足以证明用户看见数据损失。
- 相同输入的 diagnostics 按 `sourcePath + jsonPath + code` 排序，保证测试和构建可复现。

## 10. `P1-Renderer2D-Tilemap-Chunked-Layers-02` 内部实施优先级

### P0-A：新数据地基与 IR

1. 定义 `MapImportIR`、有符号 Chunk 坐标、Cell 的 Tileset / local ID / transform 字段、结构化诊断。
2. 新建 TileSet 资源，支持 atlas margin / spacing 与稳定 Tile ID。
3. 推进 Scene / KSCN schema 和 artifact version；v9 保持只读兼容，不把 v9 artifact 当新版本。
4. 把大 Tilemap 数据从 64 KiB Scene JSON 内联数组中拆出，建立独立资源或有界外部 artifact。

### P0-B：Chunked Layers Runtime / Renderer

1. 多 Layer，稳定从底到顶顺序、visible、opacity、origin。
2. 稀疏 `32×32` Chunk；相机只枚举相交 Chunk。
3. Renderer 仅按“本帧可见 Cell”计算实例预算，不能扫描 / 计数整张地图。
4. 同层多 Tileset 按稳定 Cell 顺序批处理，纹理变化时 flush；不得按纹理全局重排。
5. Shader / instance 数据支持 H/V/对角变换与 atlas rect。

### P0-C：Tiled importer

1. TMJ + TSJ、有限 / 无限地图、负坐标、Group、多 Tile Layer、多 atlas Tileset。
2. 原生 JSON GID 数组、全部正交 flip flags、路径安全、版本 pin。
3. Object / collision / properties 的结构化 warning 与 strict gate。

### P0-D：LDtk importer

1. `.ldtk` + `.ldtkl`、`levelIid` 选择、Tiles / AutoLayer、Layer 顺序、offset、flip、同格堆叠展开。
2. IntGrid / Entity / Enum / customData 的结构化 warning 与 strict gate。
3. 选中 Level 的 atlas Tileset 引用与路径安全。

### P1：编码与语义扩展

1. Tiled base64 无压缩，再依次加入 gzip / zlib / zstd；每种算法必须限制解压后字节数并验证 `cellCount * 4`。
2. 把 Tiled Tile Collision、Object Layer 与 LDtk IntGrid / Entity 接入未来的 Runtime Core / Gameplay 资源，不经 Renderer2D 取得权威。
3. LDtk World / Multi-World 导入、Tiled 非默认 blend / tint / parallax、动画 Tile。

## 11. 必须覆盖的验收夹具

### Tiled

- 有限 `4×4`、单 TSJ、JSON GID 数组的成功导入。
- 无限地图包含 Chunk `(-32,-32)`、`(-1,-1)`、`(0,0)` 边界，证明 floor division。
- 两个 TSJ 在同一个 Layer 交替出现，证明顺序未因纹理 batching 改变。
- 8 种 H/V/D flag 组合与 stale bit 29。
- Group 两级嵌套，验证 visible、opacity、offset 递归组合。
- 非正交、非默认 render order、图片集合、动画 Tile、异常 GID、重叠 Chunk、非默认 blend 拒绝。
- Object Layer、碰撞 objectgroup、Custom Properties 产生稳定 warning；strict 模式失败。
- base64 / gzip / zlib / zstd 在首版均给明确 unsupported error，而不是空地图。
- TSJ 路径逃逸、缺失文件、引用环、版本 1.13 输入拒绝。

### LDtk

- 内嵌单 Level、外部 `.ldtkl` 各一份成功夹具。
- 多 Level 无选择器失败；指定 IID 只导入目标 Level。
- 两个视觉 Layer 证明来源 top-first 被正确逆序。
- `gridTiles`、`autoLayerTiles`、X/Y flip、负 total offset。
- 同 Cell 两层堆叠展开，展开后超预算失败。
- Tile `t/src/px` 不一致、alpha 非 1、非法 f、缺失 Tileset 拒绝。
- IntGrid、Entity field、Enum、customData 产生稳定 warning；strict 模式失败。
- MultiWorld、未来 `jsonVersion`、外部 Level IID 不一致、路径逃逸拒绝。

### 共同门禁

- 同一输入导入两次得到完全相同的 IR、artifact bytes、资源 ID 和诊断排序。
- 任一外部文件中途失败时没有半写入资源。
- 大量不可见 Chunk 不计入本帧实例上传；移动 Camera 后只切换可见 Chunk。
- 预算错误报告来源 layer / chunk / cell，而不是只返回笼统“超过上限”。

## 12. 关键风险

1. **现有 `u16 cells` 是根本阻塞，不是常量太小。** Tiled 需要 `u32 GID` 拆分、多 Tileset 与 D4 变换；LDtk 也需要独立 flip 和 stack 语义。
2. **同层多纹理会破坏旧的一层一纹理假设。** 若按纹理重排，会改变透明 Tile 与来源顺序；必须稳定遍历、遇纹理变化 flush。
3. **当前 Renderer 在 culling 前按整图 Cell 计算帧预算。** 地图一大就算屏外也失败，必须把资产验证与本帧可见实例预算分开。
4. **Scene 64 KiB / artifact 1 MiB 上限无法承载实用地图。** Tilemap 需要独立、可分块的 asset 边界，不能继续无限增大 Scene 上限。
5. **碰撞 / Entity 数据存在权威归属风险。** Importer 可解析和保存语义，但 Tile Collision、IntGrid collision、Entity 最终必须交给 Runtime Core / Gameplay 资源；Renderer2D 只能消费视觉视图。
6. **不允许以“warning”掩盖画面错误。** 非默认 blend、动画 Tile、尺寸不一致 Tile 等会改变画面，必须拒绝；只有不影响当前视觉结果的未消费玩法元数据才能 warning。
7. **外部路径是安全与可复现边界。** TMJ→TSJ→图片和 LDtk→LDTKL / Tileset 是多跳引用；必须以声明文档为基准、限制根目录、检测环和规范化冲突。

## 13. 官方资料索引

- [Tiled JSON Map Format 1.12.2](https://doc.mapeditor.org/en/stable/reference/json-map-format/)
- [Tiled Global Tile IDs](https://doc.mapeditor.org/en/stable/reference/global-tile-ids/)
- [Tiled TMX Map Format](https://doc.mapeditor.org/en/stable/reference/tmx-map-format/)
- [Tiled Working with Layers](https://doc.mapeditor.org/en/stable/manual/layers/)
- [Tiled Working with Objects](https://doc.mapeditor.org/en/stable/manual/objects/)
- [Tiled Editing Tilesets](https://doc.mapeditor.org/en/stable/manual/editing-tilesets/)
- [Tiled Custom Properties](https://doc.mapeditor.org/en/stable/manual/custom-properties/)
- [LDtk JSON 1.5.3](https://ldtk.io/json/)
- [LDtk 1.5.3 JSON Schema](https://ldtk.io/files/JSON_SCHEMA.json)
- [LDtk JSON overview](https://ldtk.io/docs/game-dev/json-overview/)
- [LDtk Optional separate levels](https://ldtk.io/docs/game-dev/json-overview/optional-separate-levels/)
- [LDtk World layout](https://ldtk.io/docs/game-dev/json-overview/world-layout/)
- [LDtk Layer instances](https://ldtk.io/docs/game-dev/json-overview/layer-instances/)
- [LDtk Entity fields](https://ldtk.io/docs/game-dev/json-overview/entity-fields/)
- [LDtk IntGrid layers](https://ldtk.io/docs/general/intgrid-layers/)
- [LDtk Auto layers](https://ldtk.io/docs/general/auto-layers/)

