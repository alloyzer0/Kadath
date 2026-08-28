# 主流引擎 Tilemap 能力调研与 Kadath 优先级建议

日期：2026-08-28

## 结论

Kadath 当前 Tilemap 已完成“静态 Atlas 背景可被创作、烘焙和渲染”的纵向验证，但还不是可承担真实关卡生产的 Tilemap 系统。下一步不应只放宽 `32×32` 常量，也不应直接追加碰撞或自动地形；应先建立可扩展的数据、渲染和创作地基。

建议按以下顺序推进：

1. **P0：Tilemap v2 地基**——TileSet 资源化、多视觉层、`32×32` 稀疏 Chunk、可见/脏块渲染、虚拟化编辑视口；
2. **P0：Tiled JSON 导入与 Cell 变换**——尽快获得真实地图生产入口；
3. **P1：静态 Tile 碰撞 Bake**——独立产物进入 Rust Runtime Core，不让 Renderer2D 成为玩法权威；
4. **P1：原生编辑效率**——框选、矩形、填充、吸管、复制粘贴、手势级 Undo/Redo；
5. **P1：运行时查询/修改与脏 Chunk 重建**；
6. **P1：Terrain/Rule Tile 自动连接**；
7. **P2：动画 Tile、导航、遮挡、Y-sort/视差等增强能力**；
8. **暂缓：六边形/等距、Scene Tile、真正磁盘流式世界等高复杂度能力**。

最重要的限制策略变化是：**不再设置全地图 Tile 总数硬上限**。安全边界应改为 Chunk 尺寸、资产字节数、常驻 Chunk、可见实例/Draw 和脏块重建预算。

## 主流实现调研

### 能力对照

| 实现 | 资源与层 | 大地图组织 | 创作能力 | 玩法与运行时 |
|---|---|---|---|---|
| Godot 4 | 独立 `TileSet`，推荐多个 `TileMapLayer`；层可重排、显隐 | 渲染和物理使用 quadrant；默认渲染 quadrant 边长为 16 | 画笔、线、矩形、填充、吸管、选择、Pattern、Terrain 自动连接 | TileSet 可带碰撞、导航、遮挡和自定义数据；支持运行时改 Cell |
| Unity 6 | `Grid` 父节点下可建多个 `Tilemap`；Tile 作为资源 | Tilemap Renderer 提供 Chunk 模式和 Chunk Culling Bounds | Tile Palette、Brush；Extras 提供 Rule Tile、Animated Tile 和扩展 Brush | Tilemap Collider 支持增量更新与达到阈值后的全量重建；脚本 API 可查询/修改 |
| Unreal Paper2D | `TileSet` 资产 + 多层 `TileMap` | 以有界地图资产为主 | Paint、Fill、Erase、多层编辑 | 支持每 Tile 碰撞和 Layer collision；但 Paper2D Tile Map/2D Physics 官方仍带实验性警告 |
| Defold | 独立 Tile Source + 多层 Tile Map | 地图有 Bounds，渲染实现对地图做专门处理 | 内置画笔，并明确支持外部关卡编辑器导出 | `get_tile`、`set_tile`、层显隐、翻转/90°旋转；Tile Source 可定义动画和碰撞组 |
| Tiled（编辑器） | 外部 Tileset；Tile/Object/Image/Group Layer | Infinite Map 以 Chunk 持久化，可向负坐标扩展 | 成熟的地图、对象、属性和图块工作流 | 格式定义翻转标志、属性、动画、碰撞对象；具体玩法语义由导入方决定 |

### 收敛出的行业共识

以下能力不是“高级功能”，而是可用 Tilemap 的基础：

- **TileSet 与地图 Cell 分离**：TileSet 定义图块外观、稳定身份和复用元数据；地图只保存放置结果；
- **多层**：背景、地面、装饰、前景需要独立排序和显隐；同一格允许跨层叠放；
- **空间分块或等价组织**：总地图规模不应等于每帧处理规模；
- **可用的绘制工具**：只支持逐格画/擦，无法高效生产真实关卡；
- **运行时查询/修改**：即使地图主要静态，也通常需要脚本读取或局部修改；
- **碰撞与导航是独立消费者**：视觉 Tile 可以携带定义，但物理/导航系统拥有各自生成物和更新策略。

主流引擎并不完全一致：Godot 的 TileSet/TileMap 能力最完整，Unity 的组件和扩展包边界更清楚，Defold 强调小型运行时 API 和外部编辑器工作流，Unreal Paper2D 则说明“功能存在”不等于已经达到成熟生产质量。因此 Kadath 应复制稳定共识，不追求一次覆盖每个引擎的全部能力。

## Kadath 当前基线与真实限制

### 已完成能力

- Scene/KSCN 已能持久化一个 Tilemap；
- Atlas 使用一基 `u16` Tile Index，`0` 表示空 Cell；
- Tilemap 可通过 Workspace 原子创作、Undo/Redo、Bake、Preview；
- Avalonia 有 Atlas 选择、逐格绘制和擦除；
- Renderer2D 支持 Tilemap 在 Sprite 前绘制、每 128 实例分批、Camera2D 可见范围裁剪；
- Null/Vulkan RHI 与 Windows/Linux 产品链已有验证。

### 当前硬限制不是单一常量

| 边界 | 当前状态 | 影响 |
|---|---|---|
| Scene | `max_tilemap_count = 1`；每个 Tilemap 固定 `[1024]u16` | 只能一层，最大 `32×32` |
| Source | Scene JSON 最大 64 KiB，Cell 内联 | 即便扩大数组，源文档也很快触顶 |
| KSCN/Workspace | 同步冻结单层、完整 Cell 集合和 `32×32` 校验 | 不能只改 Renderer 常量 |
| Renderer2D | 每帧最多一层；`validateFrame` 会扫描并计入全部非空 Cell | Camera 虽只画可见格，但地图越大仍会在预检阶段失败或退化 |
| GPU 实例 | 每 Tile 48 bytes，RHI 每帧实例上传预算 64 KiB | 最多约 1365 个实例；`1280×720`、32px Tile 的单致密层约 920，双层已可能越界 |
| GPU 坐标 | `GpuQuadInstance` 保存 `rect_ndc` | Camera 移动/缩放会迫使可见 Tile 重新计算和上传，不能直接复用静态 Chunk |
| Avalonia | 最多 1024 个 Cell 的有界 ItemsControl | 放宽总尺寸会造成控件数量和 Snapshot/patch 成本同步增长 |
| 领域语义 | Tilemap 明确只是静态视觉背景 | 没有碰撞、导航、触发器、Cell 元数据或 Runtime API |

因此，把 `32` 改为 `256` 只会得到更大的固定数组、全图扫描、更大的跨进程 candidate 和更容易触发的帧预算错误，不构成可用的大地图实现。

## 功能列表与优先级

### P0-1：Tilemap v2 地基（下一项）

#### 数据和持久化

- 建立可复用 TileSet 资源，至少包含：稳定 TileSet ID、Texture 引用、Tile 尺寸、margin/spacing、稳定 Tile ID；
- Tilemap 从 Scene 大型内联 Cell 数组中拆出为独立资产或独立二进制段，Scene 只引用资产；
- Tilemap 包含有序视觉 Layer；首个增量建议冻结为最多 4 个视觉层，支持名称、顺序、显隐、opacity/tint；
- Layer 使用带符号 Chunk 坐标；首个增量使用固定 `32×32` Cell Chunk，使旧 `32×32` 地图天然迁移为一个 Chunk；
- 空 Chunk 不持久化；空 Cell 不产生渲染实例；
- Cell 引用升级为能容纳 Tile ID 和 H/V/90°变换标志的稳定表示，不再把身份绑定为单 Atlas 的一基 `u16` 下标；
- v9 单 Tilemap 通过明确兼容 Adapter 读取为“一 TileSet、一 Layer、一 Chunk”，不隐式重写旧源文件。

#### 渲染

- Scene/资产加载阶段完成全量结构与 Tile 引用校验；Renderer 每帧只遍历可见 Chunk 和可见 Cell；
- Tile 实例保存世界坐标或网格坐标，Camera 变换通过 push constant/统一帧参数传入；
- Renderer2D 拥有 Chunk GPU cache，并只在首次出现或 Chunk 变脏时重建；
- 若 RHI 需要扩展，只增加通用 buffer 的 create/update/bind/destroy seam；RHI 不认识 Tilemap、TileSet、Chunk 或 Cell；
- Sprite 动态实例路径可保持现状，避免为 Tilemap 扩容破坏 Runtime Object 渲染契约；
- 绘制顺序固定为 Layer order → Chunk 稳定顺序 → Chunk 内 row-major，保证重放和产品 oracle 可预测。

#### 编辑器

- 用可平移/缩放、按可见区域虚拟化的地图画布替代“全地图一个 Cell 控件”；
- 首增量保留 Paint/Erase，但增加活动层选择、层显隐、创建/删除/重排；
- 一个手势只形成一个 Undo 记录；只记录受影响 Chunk 的 delta，不复制整个地图；
- Workspace 仍以 revision 和原子 candidate 发布为权威，不允许半个 Chunk 或半组关联资产被发布。

#### Tile 数与资源预算

目标模型不提供 `max_tile_count`。第一阶段建议冻结以下边界：

- Chunk：固定 `32×32`；
- 坐标：带符号 32 位网格/Chunk 坐标；
- 视觉层：首增量最多 4 层，后续根据产品证据扩展；
- TileSet/Cell 引用：使用稳定的 32 位语义值或等价结构；
- 安全限制：最大未压缩资产字节、最大常驻 Chunk、每帧最大可见 Chunk/实例/Draw、每次最大脏 Chunk 数；
- 达到运行时预算时返回可诊断错误或执行明确的流式/淘汰策略，不能截断绘制。

具体字节和常驻数量应由 Windows/Linux 产品 workload 测量后冻结，而不是先拍一个“最大总 Tile 数”。

#### 首增量验收

- v9 旧场景渲染像素与升级前一致；
- 4 个视觉层可重叠、重排、显隐，Layer 顺序稳定；
- 至少一个跨正负 Chunk 坐标、远大于 `32×32` 的稀疏地图可创作、Bake、Reload 和 Preview；
- Camera 移动只让进入视口或变脏的 Chunk 产生重建，不因全图 Tile 数量增加而线性增长；
- 失败的 TileSet/Tilemap candidate 保留旧 Scene、Texture、Renderer cache、Preview identity 与 publication；
- Null 和 Vulkan Adapter 对通用 buffer 生命周期、越界、失败恢复保持同构；
- Windows 与 Linux 产品 fixture 覆盖层顺序、Chunk 边界、负坐标、Camera 平移/缩放和 reload。

### P0-2：Tiled JSON 导入与 Cell 变换

这是最快获得真实关卡生产能力的增量，优先于一次性补齐 Kadath 原生编辑器。

首版建议支持：

- `.tmj`/`.tsj`；
- orthogonal grid；
- 外部 Tileset、Tile Layer、Infinite Chunk；
- Layer 顺序、显隐、opacity、offset；
- H/V/diagonal flip 映射为 Kadath 的 H/V/90°变换；
- Texture、margin、spacing 和 Tile size；
- 确定性导入/Bake，相同输入生成相同 artifact/digest；
- 对 Object Layer、动画、Terrain、模板等未支持项给出精确错误或警告，禁止静默丢失。

首版不把 Tiled 文件变成运行时权威；它只是 Authoring 输入，输出仍需通过 Kadath TileSet/Tilemap 校验和原子发布。

### P1-1：静态 Tile 碰撞 Bake

碰撞很重要，但必须在 v2 数据身份和 Chunk 边界稳定后实施。

- TileSet 定义每种 Tile 的矩形/凸多边形碰撞形状和碰撞类别；
- Bake 按 Layer/Chunk 生成独立 `TileCollisionArtifact`，携带源 Tilemap revision/digest；
- 相邻实心格应按 Chunk 合并，不能为每个 Cell 创建独立 Runtime Object；
- Rust Runtime Core 拥有静态 body、过滤、query、contact/trigger 和发布生命周期；
- Renderer2D 只消费视觉 Chunk，既不生成碰撞事件，也不成为碰撞数据权威；
- Tilemap 与 collision candidate 原子发布，失败时两者都保留旧版本；
- 首版只做静态碰撞；one-way platform、trigger、动态图块和跨 Chunk 增量合并后续单列。

### P1-2：原生编辑效率

- 线、矩形、区域填充、吸管；
- 框选、移动、复制粘贴、Pattern；
- Palette 搜索、最近使用、常用集合；
- 多层锁定、单层聚焦、其他层淡化；
- 手势级 Chunk delta Undo/Redo；
- 大图中只刷新受影响 Chunk 和可见 Palette。

### P1-3：运行时查询与局部修改

- `getTile(layer, coordinate)`、有界区域查询；
- `setTile`/批量修改通过 Runtime Core 命令或明确的 Runtime Tilemap authority；
- 视觉、碰撞和其他派生产物按同一脏 Chunk 集合更新；
- 每帧修改量受预算约束，超限排队或稳定拒绝；
- Restart/reload 对运行时修改是保留还是清除，需要在契约中明确。

### P1-4：Terrain/Rule Tile

- TileSet 保存邻接规则和候选权重；
- 支持 Connect/Path 或等价的地形笔刷；
- 随机选择必须使用显式种子并可重放；
- 规则求解只修改受影响 Cell 的邻域；
- 规则结果最终落为普通 Cell，Renderer 不理解 Terrain。

它依赖稳定 Tile ID、变换标志和批量编辑事务，因此不能早于 P0。

### P2：增强能力

- Animated Tile：共享动画定义、可见动画更新、确定性时间源；
- TileSet 自定义元数据和类型标签；
- 视差、Layer blend、Y-sort、遮挡；
- 导航 Bake；优先烘焙为独立导航网格，不直接堆叠每 Tile 导航多边形；
- Object Layer 导入并显式映射为 Scene Object/Spawn Prototype；
- 多 TileSet/多 Texture 批处理深化；
- 热重载时对 GPU/碰撞/导航脏 Chunk 的统一调度。

### 暂缓

- Hex/Isometric/Staggered grid；
- 任意角度 Cell 旋转；
- Scene Tile/在 Cell 中实例化完整对象；
- 真正的磁盘级 Chunk streaming、跨区预取和持久化淘汰；
- 大规模 GPU indirect/compute Tile 渲染；
- 与 Unreal Paper2D 等实验性路线对齐的完整 2D 物理特性。

这些能力要么需求尚未证明，要么会显著扩大坐标、排序、资产或 Runtime authority 设计，不应阻塞正交 2D 关卡可用性。

## 建议的下一项可执行任务

任务名建议：`P1-Renderer2D-Tilemap-Chunked-Layers-02`。

第一步先做契约发现并冻结以下接口，再进入实现：

1. TileSet/Tilemap 资产身份、v9 兼容读取和下一版 KSCN 布局；
2. `32×32` Chunk、最多 4 个视觉层和 Cell 变换位；
3. Renderer2D 的可见 Chunk 输入、世界坐标实例和脏 Chunk cache 生命周期；
4. RHI 通用静态/可更新实例 buffer seam 及 Null/Vulkan 同构契约；
5. Workspace 的原子多资产 candidate、revision、Undo/Redo；
6. Avalonia 虚拟化地图画布和活动层最小工作流；
7. Windows/Linux 产品验收 workload 和资源预算。

本增量明确不包含碰撞、Terrain、动画、Object Layer 和 Runtime `setTile`。它的完成标准不是“能放更多 Tile”，而是：**全地图规模与单帧工作量解耦，并让旧单层地图无损进入多层分块模型。**

## 官方资料

- Godot：[Using TileMaps](https://docs.godotengine.org/en/stable/tutorials/2d/using_tilemaps.html)、[Using TileSets](https://docs.godotengine.org/en/stable/tutorials/2d/using_tilesets.html)、[TileMapLayer](https://docs.godotengine.org/en/stable/classes/class_tilemaplayer.html)
- Unity：[创建 Tilemap](https://docs.unity3d.com/cn/6000.0/Manual/tilemaps/work-with-tilemaps/create-tilemap.html)、[Tilemap Collider 2D](https://docs.unity3d.com/6000.0/Documentation/Manual/tilemaps/work-with-tilemaps/tilemap-collider-2d-reference.html)、[2D Tilemap Extras](https://docs.unity3d.com/cn/6000.0/Manual/com.unity.2d.tilemap.extras.html)
- Unreal Engine：[Paper 2D Tile Sets / Tile Maps](https://dev.epicgames.com/documentation/unreal-engine/paper-2d-tile-sets-and-tile-maps-in-unreal-engine?lang=en-US)
- Defold：[Tile Map](https://defold.com/manuals/tilemap/)、[Tile Source](https://defold.com/manuals/tilesource/)、[Tilemap API](https://defold.com/ref/stable/tilemap-lua/)
- Tiled：[TMX Map Format](https://doc.mapeditor.org/en/stable/reference/tmx-map-format/)、[JSON Map Format](https://doc.mapeditor.org/en/stable/reference/json-map-format/)

