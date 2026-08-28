# Chunked Tilemap 外部导入夹具

- `world.tmj` + 两个 `.tsj`：验证 Tiled 无限 Chunk、负坐标、多 Tileset、多 Layer、H/V/Diagonal 变换与 Object Layer warning。
- `world.ldtk` + `Level_0.ldtkl`：验证 LDtk 外部 Level、top-first 逆序、Tiles/AutoLayer、X/Y flip、IntGrid/Entity/Enum warning。
- `.ppm` 只用于导入测试的普通 atlas 路径；产品验证会把它们先转换为 KDAT Texture，再执行地图导入。

夹具只覆盖视觉导入。Object、Collision、IntGrid 与 Entity 不在本增量取得 Runtime authority。
