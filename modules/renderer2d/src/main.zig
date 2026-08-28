const std = @import("std");
const rhi = @import("rhi");

extern const kadath_renderer2d_quad_vert_spv: u32;
extern const kadath_renderer2d_quad_vert_spv_word_count: u32;
extern const kadath_renderer2d_quad_frag_spv: u32;
extern const kadath_renderer2d_quad_frag_spv_word_count: u32;

const GpuQuadInstance = extern struct {
    rect_world: [4]f32,
    color: [4]f32,
    uv_rect: [4]f32,
    transform: [4]f32,
};

comptime {
    if (@sizeOf(GpuQuadInstance) != 64) {
        @compileError("Renderer2D GPU quad instance must stay 64 bytes");
    }
    if (@offsetOf(GpuQuadInstance, "rect_world") != 0 or
        @offsetOf(GpuQuadInstance, "color") != 16 or
        @offsetOf(GpuQuadInstance, "uv_rect") != 32 or
        @offsetOf(GpuQuadInstance, "transform") != 48)
    {
        @compileError("Renderer2D GPU quad instance layout changed");
    }
}

const ViewPushConstants = extern struct {
    viewport: [4]f32,
    camera: [4]f32,
};

comptime {
    if (@sizeOf(ViewPushConstants) != 32) @compileError("Renderer2D view push constants must stay 32 bytes");
}

/// Runtime Object publication 上限独立于 RHI 的整帧 Tilemap 上传容量。
pub const max_sprites_per_frame: usize = 128;
pub const max_tilemap_layers_per_frame: usize = 4;
pub const max_tilemap_columns: usize = 32;
pub const max_tilemap_rows: usize = 32;
pub const max_tilemap_cells_per_frame: usize = max_tilemap_columns * max_tilemap_rows;
pub const max_tilemap_atlas_dimension: usize = 256;
pub const max_chunked_tilemap_sources_per_frame: usize = 16;
pub const chunked_tilemap_edge: usize = 32;
const max_instances_per_binding: usize = rhi.max_instance_data_bytes_per_binding / @sizeOf(GpuQuadInstance);

comptime {
    if (max_instances_per_binding != 128) {
        @compileError("Renderer2D instance binding must hold exactly 128 quads");
    }
}

pub const SpriteInstance = struct {
    position: [2]f32,
    size: [2]f32,
    color: [4]f32,
    texture: rhi.TextureHandle,
    uv_rect: [4]f32 = .{ 0, 0, 1, 1 },
};

pub const TilemapLayerView = struct {
    origin: [2]f32,
    tile_size: [2]f32,
    columns: u32,
    rows: u32,
    atlas_columns: u32,
    atlas_rows: u32,
    texture: rhi.TextureHandle,
    cells: []const u16,
};

pub const TileTransform = packed struct(u3) {
    flip_horizontal: bool = false,
    flip_vertical: bool = false,
    flip_diagonal: bool = false,
};

pub const TileSourceView = struct {
    texture: rhi.TextureHandle,
    tile_size: [2]u32,
    image_size: [2]u32,
    columns: u32,
    rows: u32,
    margin: u32,
    spacing: u32,
};

pub const ChunkedTileCellView = struct {
    local_index: u16,
    tile_source_index: u16,
    local_tile_id: u32,
    transform: TileTransform = .{},
};

pub const TilemapChunkView = struct {
    coordinate: [2]i32,
    cells: []const ChunkedTileCellView,
};

pub const ChunkedTilemapLayerView = struct {
    origin: [2]f32,
    offset: [2]f32,
    grid_size: [2]u32,
    visible: bool = true,
    opacity: f32 = 1,
    tile_sources: []const TileSourceView,
    chunks: []const TilemapChunkView,
};

pub const Camera2DView = struct {
    // origin 是视口左上角对应的世界坐标；恒等默认值保持历史调用方兼容。
    origin: [2]f32 = .{ 0.0, 0.0 },
    zoom: f32 = 1.0,
};

pub const Frame2D = struct {
    view: Camera2DView = .{},
    tilemaps: []const TilemapLayerView = &.{},
    chunked_tilemap_layers: []const ChunkedTilemapLayerView = &.{},
    sprites: []const SpriteInstance = &.{},
};

const VisibleWorldRect = struct {
    min: [2]f32,
    max: [2]f32,
};

pub const TextureSamplingProfile = enum {
    pixel_art,
    smooth_linear,
    smooth_mipmap,
    smooth_mipmap_anisotropic,
};

pub const Renderer2D = struct {
    pipeline: rhi.PipelineHandle = rhi.invalid_pipeline,

    pub fn init(backend: *rhi.Rhi) !Renderer2D {
        const vertex_shader = shaderBytes(
            &kadath_renderer2d_quad_vert_spv,
            kadath_renderer2d_quad_vert_spv_word_count,
        );
        const fragment_shader = shaderBytes(
            &kadath_renderer2d_quad_frag_spv,
            kadath_renderer2d_quad_frag_spv_word_count,
        );
        return .{
            .pipeline = try backend.createGraphicsPipeline(.{
                .vertex_shader = vertex_shader,
                .fragment_shader = fragment_shader,
                .push_constant_size = @sizeOf(ViewPushConstants),
                .uses_texture = true,
                .instance_data_stride = @sizeOf(GpuQuadInstance),
            }),
        };
    }

    pub fn deinit(self: *Renderer2D, backend: *rhi.Rhi) void {
        if (self.pipeline != rhi.invalid_pipeline) {
            backend.destroyGraphicsPipeline(self.pipeline);
            self.pipeline = rhi.invalid_pipeline;
        }
        std.log.info("Renderer2D shutdown complete", .{});
    }

    pub fn createTexture(
        self: *Renderer2D,
        backend: *rhi.Rhi,
        desc: rhi.TextureUploadDesc,
        sampling_profile: TextureSamplingProfile,
    ) !rhi.TextureHandle {
        if (self.pipeline == rhi.invalid_pipeline) return error.RendererNotInitialized;
        // Renderer2D 选择高层采样意图；尺寸/完整链和 Vulkan sampler 映射由 RHI 统一校验。
        var upload = desc;
        upload.sampler_profile = switch (sampling_profile) {
            .pixel_art => .pixel_nearest,
            .smooth_linear => .smooth_linear,
            .smooth_mipmap => .smooth_mipmap,
            .smooth_mipmap_anisotropic => .smooth_mipmap_anisotropic,
        };
        const texture = try backend.createTexture(upload);
        std.log.info("Renderer2D texture upload complete: mip_levels={d}, sampler={s}", .{ 1 + desc.mip_levels.len, @tagName(upload.sampler_profile) });
        return texture;
    }
    pub fn renderSprites(
        self: *Renderer2D,
        backend: *rhi.Rhi,
        extent: rhi.Extent2D,
        sprites: []const SpriteInstance,
    ) !rhi.FrameOutcome {
        return self.renderFrame(backend, extent, .{ .sprites = sprites });
    }

    pub fn renderFrame(
        self: *Renderer2D,
        backend: *rhi.Rhi,
        extent: rhi.Extent2D,
        frame: Frame2D,
    ) !rhi.FrameOutcome {
        const visible = visibleWorldRect(extent, frame.view);
        const instance_count = try validateFrame(backend, visible, frame);
        const begin = try backend.beginFrame(extent, .{ 0.035, 0.10, 0.22, 1.0 });
        switch (begin) {
            .skipped_minimized => return .skipped_minimized,
            .recreated => return .recreated,
            .ready => |ready| {
                var encoder = ready;
                errdefer encoder.consumeFailedFrame();

                const width: f32 = @floatFromInt(extent.width);
                const height: f32 = @floatFromInt(extent.height);
                if (instance_count != 0) {
                    try encoder.bindPipeline(self.pipeline);
                    const view = ViewPushConstants{
                        .viewport = .{ width, height, 1.0 / width, 1.0 / height },
                        .camera = .{ frame.view.origin[0], frame.view.origin[1], frame.view.zoom, 0 },
                    };
                    try encoder.pushConstants(std.mem.asBytes(&view));
                }
                for (frame.tilemaps) |tilemap| try renderTilemap(&encoder, visible, tilemap);
                for (frame.chunked_tilemap_layers) |layer| try renderChunkedTilemapLayer(&encoder, visible, layer);
                try renderSpriteRuns(&encoder, visible, frame.sprites);
                return try encoder.finish();
            },
        }
    }
};

fn validateFrame(backend: *rhi.Rhi, visible: VisibleWorldRect, frame: Frame2D) !usize {
    for (frame.view.origin) |number| {
        if (!std.math.isFinite(number)) return error.InvalidCameraOrigin;
    }
    if (!std.math.isFinite(frame.view.zoom) or frame.view.zoom < 0.125 or frame.view.zoom > 8.0) {
        return error.InvalidCameraZoom;
    }
    if (frame.sprites.len > max_sprites_per_frame) return error.SpriteLimitExceeded;
    if (frame.tilemaps.len + frame.chunked_tilemap_layers.len > max_tilemap_layers_per_frame) return error.TilemapLayerLimitExceeded;
    var total_instances: usize = 0;
    for (frame.sprites) |sprite| {
        try validateSprite(sprite);
        try backend.validateTextureHandle(sprite.texture);
        if (aabbIntersects(sprite.position, sprite.size, visible)) total_instances = try std.math.add(usize, total_instances, 1);
    }
    for (frame.tilemaps) |tilemap| {
        if (tilemap.columns == 0 or tilemap.columns > max_tilemap_columns or
            tilemap.rows == 0 or tilemap.rows > max_tilemap_rows)
        {
            return error.InvalidTilemapDimensions;
        }
        if (tilemap.atlas_columns == 0 or tilemap.atlas_columns > max_tilemap_atlas_dimension or
            tilemap.atlas_rows == 0 or tilemap.atlas_rows > max_tilemap_atlas_dimension)
        {
            return error.InvalidTilemapAtlas;
        }
        const cell_count = std.math.mul(usize, @as(usize, tilemap.columns), @as(usize, tilemap.rows)) catch {
            return error.InvalidTilemapDimensions;
        };
        if (tilemap.cells.len != cell_count) return error.InvalidTilemapCellCount;
        const atlas_tiles = std.math.mul(usize, @as(usize, tilemap.atlas_columns), @as(usize, tilemap.atlas_rows)) catch {
            return error.InvalidTilemapAtlas;
        };
        if (atlas_tiles > std.math.maxInt(u16)) return error.InvalidTilemapAtlas;
        for (tilemap.origin) |number| {
            if (!std.math.isFinite(number)) return error.InvalidTilemapOrigin;
        }
        for (tilemap.tile_size) |number| {
            if (!std.math.isFinite(number) or number <= 0) return error.InvalidTilemapSize;
        }
        try backend.validateTextureHandle(tilemap.texture);
        for (tilemap.cells) |cell| if (cell > atlas_tiles) return error.InvalidTilemapCell;
        const column_range = visibleTileRange(visible.min[0], visible.max[0], tilemap.origin[0], tilemap.tile_size[0], tilemap.columns);
        const row_range = visibleTileRange(visible.min[1], visible.max[1], tilemap.origin[1], tilemap.tile_size[1], tilemap.rows);
        var row = row_range.start;
        while (row < row_range.end) : (row += 1) {
            var column = column_range.start;
            while (column < column_range.end) : (column += 1) {
                if (tilemap.cells[row * @as(usize, tilemap.columns) + column] != 0) {
                    total_instances = try std.math.add(usize, total_instances, 1);
                }
            }
        }
    }
    for (frame.chunked_tilemap_layers) |layer| {
        try validateChunkedLayer(backend, layer);
        if (!layer.visible or layer.opacity == 0) continue;
        for (layer.chunks) |chunk| {
            if (!chunkIntersectsVisible(layer, chunk.coordinate, visible)) continue;
            for (chunk.cells) |cell| {
                if (!chunkCellIntersectsVisible(layer, chunk.coordinate, cell.local_index, visible)) continue;
                try validateVisibleChunkCell(layer, cell);
                total_instances = try std.math.add(usize, total_instances, 1);
            }
        }
    }
    const total_bytes = try std.math.mul(usize, total_instances, @sizeOf(GpuQuadInstance));
    if (total_bytes > rhi.max_instance_data_bytes_per_frame) return error.InstanceDataFrameLimitReached;
    return total_instances;
}

fn validateChunkedLayer(backend: *rhi.Rhi, layer: ChunkedTilemapLayerView) !void {
    for (layer.origin ++ layer.offset) |number| if (!std.math.isFinite(number)) return error.InvalidTilemapOrigin;
    if (layer.grid_size[0] == 0 or layer.grid_size[1] == 0) return error.InvalidTilemapSize;
    if (!std.math.isFinite(layer.opacity) or layer.opacity < 0 or layer.opacity > 1) return error.InvalidTilemapOpacity;
    if (layer.tile_sources.len == 0 or layer.tile_sources.len > max_chunked_tilemap_sources_per_frame) return error.InvalidTilemapSourceCount;
    for (layer.tile_sources) |source| {
        try backend.validateTextureHandle(source.texture);
        if (source.tile_size[0] == 0 or source.tile_size[1] == 0 or source.image_size[0] == 0 or source.image_size[1] == 0 or
            source.columns == 0 or source.rows == 0)
        {
            return error.InvalidTilemapAtlas;
        }
        const used_width = try atlasExtent(source.margin, source.spacing, source.tile_size[0], source.columns);
        const used_height = try atlasExtent(source.margin, source.spacing, source.tile_size[1], source.rows);
        if (used_width > source.image_size[0] or used_height > source.image_size[1]) return error.InvalidTilemapAtlas;
    }
    var previous_coordinate: ?[2]i32 = null;
    for (layer.chunks) |chunk| {
        if (previous_coordinate) |previous| {
            if (chunk.coordinate[1] < previous[1] or
                (chunk.coordinate[1] == previous[1] and chunk.coordinate[0] <= previous[0]))
            {
                return error.InvalidTilemapChunkOrder;
            }
        }
        previous_coordinate = chunk.coordinate;
    }
}

fn validateVisibleChunkCell(layer: ChunkedTilemapLayerView, cell: ChunkedTileCellView) !void {
    if (cell.local_index >= chunked_tilemap_edge * chunked_tilemap_edge) return error.InvalidTilemapCell;
    if (cell.tile_source_index >= layer.tile_sources.len) return error.InvalidTilemapCell;
    const source = layer.tile_sources[cell.tile_source_index];
    const tile_count = std.math.mul(u32, source.columns, source.rows) catch return error.InvalidTilemapAtlas;
    if (cell.local_tile_id >= tile_count) return error.InvalidTilemapCell;
}

fn atlasExtent(margin: u32, spacing: u32, tile_size: u32, count: u32) !u32 {
    const margins = try std.math.mul(u32, margin, 2);
    const tiles = try std.math.mul(u32, tile_size, count);
    const spaces = try std.math.mul(u32, spacing, count - 1);
    return try std.math.add(u32, margins, try std.math.add(u32, tiles, spaces));
}

fn validateSprite(sprite: SpriteInstance) !void {
    for (sprite.position) |number| {
        if (!std.math.isFinite(number)) return error.InvalidSpritePosition;
    }
    for (sprite.size) |number| {
        if (!std.math.isFinite(number) or number <= 0) return error.InvalidSpriteSize;
    }
    for (sprite.color ++ sprite.uv_rect) |number| {
        if (!std.math.isFinite(number)) return error.InvalidSpriteData;
    }
    if (!std.math.isFinite(sprite.position[0] + sprite.size[0]) or
        !std.math.isFinite(sprite.position[1] + sprite.size[1]))
    {
        return error.InvalidSpriteSize;
    }
    if (sprite.texture == rhi.invalid_texture) return error.InvalidTexture;
}

fn visibleWorldRect(extent: rhi.Extent2D, view: Camera2DView) VisibleWorldRect {
    return .{
        .min = view.origin,
        .max = .{
            view.origin[0] + @as(f32, @floatFromInt(extent.width)) / view.zoom,
            view.origin[1] + @as(f32, @floatFromInt(extent.height)) / view.zoom,
        },
    };
}

fn renderTilemap(
    encoder: *rhi.FrameEncoder,
    visible: VisibleWorldRect,
    tilemap: TilemapLayerView,
) !void {
    var gpu_instances: [max_instances_per_binding]GpuQuadInstance = undefined;
    var batch_count: usize = 0;
    var texture_bound = false;
    const column_range = visibleTileRange(visible.min[0], visible.max[0], tilemap.origin[0], tilemap.tile_size[0], tilemap.columns);
    const row_range = visibleTileRange(visible.min[1], visible.max[1], tilemap.origin[1], tilemap.tile_size[1], tilemap.rows);
    var row = row_range.start;
    while (row < row_range.end) : (row += 1) {
        var column = column_range.start;
        while (column < column_range.end) : (column += 1) {
            // 只遍历可见行列，但 cell_index 仍按全局 row-major 计算，稳定保持绘制顺序。
            const cell_index = row * @as(usize, tilemap.columns) + column;
            const cell = tilemap.cells[cell_index];
            if (cell == 0) continue;
            const atlas_index: usize = cell - 1;
            const atlas_column = atlas_index % @as(usize, tilemap.atlas_columns);
            const atlas_row = atlas_index / @as(usize, tilemap.atlas_columns);
            const position = [2]f32{
                tilemap.origin[0] + @as(f32, @floatFromInt(column)) * tilemap.tile_size[0],
                tilemap.origin[1] + @as(f32, @floatFromInt(row)) * tilemap.tile_size[1],
            };
            gpu_instances[batch_count] = quadInstance(
                position,
                tilemap.tile_size,
                .{ 1, 1, 1, 1 },
                .{
                    @as(f32, @floatFromInt(atlas_column)) / @as(f32, @floatFromInt(tilemap.atlas_columns)),
                    @as(f32, @floatFromInt(atlas_row)) / @as(f32, @floatFromInt(tilemap.atlas_rows)),
                    1.0 / @as(f32, @floatFromInt(tilemap.atlas_columns)),
                    1.0 / @as(f32, @floatFromInt(tilemap.atlas_rows)),
                },
                .{},
            );
            batch_count += 1;
            if (batch_count == gpu_instances.len) {
                if (!texture_bound) {
                    try encoder.bindTexture(tilemap.texture);
                    texture_bound = true;
                }
                try submitBatch(encoder, gpu_instances[0..batch_count]);
                batch_count = 0;
            }
        }
    }
    if (batch_count != 0) {
        if (!texture_bound) try encoder.bindTexture(tilemap.texture);
        try submitBatch(encoder, gpu_instances[0..batch_count]);
    }
}

fn renderChunkedTilemapLayer(
    encoder: *rhi.FrameEncoder,
    visible: VisibleWorldRect,
    layer: ChunkedTilemapLayerView,
) !void {
    if (!layer.visible or layer.opacity == 0) return;
    var gpu_instances: [max_instances_per_binding]GpuQuadInstance = undefined;
    var batch_texture: ?rhi.TextureHandle = null;
    var batch_count: usize = 0;
    for (layer.chunks) |chunk| {
        if (!chunkIntersectsVisible(layer, chunk.coordinate, visible)) continue;
        for (chunk.cells) |cell| {
            if (!chunkCellIntersectsVisible(layer, chunk.coordinate, cell.local_index, visible)) continue;
            try validateVisibleChunkCell(layer, cell);
            const source = layer.tile_sources[cell.tile_source_index];
            if (batch_texture != null and batch_texture.? != source.texture) {
                try encoder.bindTexture(batch_texture.?);
                try submitBatch(encoder, gpu_instances[0..batch_count]);
                batch_count = 0;
            }
            batch_texture = source.texture;
            const position = try chunkCellWorldPosition(layer, chunk.coordinate, cell.local_index);
            const atlas_column = cell.local_tile_id % source.columns;
            const atlas_row = cell.local_tile_id / source.columns;
            const pixel_x = source.margin + atlas_column * (source.tile_size[0] + source.spacing);
            const pixel_y = source.margin + atlas_row * (source.tile_size[1] + source.spacing);
            gpu_instances[batch_count] = quadInstance(
                position,
                .{ @floatFromInt(layer.grid_size[0]), @floatFromInt(layer.grid_size[1]) },
                .{ 1, 1, 1, layer.opacity },
                .{
                    @as(f32, @floatFromInt(pixel_x)) / @as(f32, @floatFromInt(source.image_size[0])),
                    @as(f32, @floatFromInt(pixel_y)) / @as(f32, @floatFromInt(source.image_size[1])),
                    @as(f32, @floatFromInt(source.tile_size[0])) / @as(f32, @floatFromInt(source.image_size[0])),
                    @as(f32, @floatFromInt(source.tile_size[1])) / @as(f32, @floatFromInt(source.image_size[1])),
                },
                cell.transform,
            );
            batch_count += 1;
            if (batch_count == gpu_instances.len) {
                try encoder.bindTexture(batch_texture.?);
                try submitBatch(encoder, gpu_instances[0..batch_count]);
                batch_count = 0;
            }
        }
    }
    if (batch_count != 0) {
        try encoder.bindTexture(batch_texture.?);
        try submitBatch(encoder, gpu_instances[0..batch_count]);
    }
}

fn renderSpriteRuns(
    encoder: *rhi.FrameEncoder,
    visible: VisibleWorldRect,
    sprites: []const SpriteInstance,
) !void {
    var gpu_instances: [max_instances_per_binding]GpuQuadInstance = undefined;
    var batch_texture: ?rhi.TextureHandle = null;
    var batch_count: usize = 0;
    for (sprites) |sprite| {
        if (!aabbIntersects(sprite.position, sprite.size, visible)) continue;
        if (batch_texture != null and batch_texture.? != sprite.texture) {
            try encoder.bindTexture(batch_texture.?);
            try submitBatch(encoder, gpu_instances[0..batch_count]);
            batch_count = 0;
        }
        // 不可见 Sprite 不形成 run 边界；可见 Sprite 的相对顺序仍与输入完全一致。
        batch_texture = sprite.texture;
        gpu_instances[batch_count] = quadInstance(sprite.position, sprite.size, sprite.color, sprite.uv_rect, .{});
        batch_count += 1;
    }
    if (batch_count != 0) {
        try encoder.bindTexture(batch_texture.?);
        try submitBatch(encoder, gpu_instances[0..batch_count]);
    }
}

const TileRange = struct { start: usize, end: usize };

fn visibleTileRange(visible_min: f32, visible_max: f32, origin: f32, tile_size: f32, count: u32) TileRange {
    const count_f: f32 = @floatFromInt(count);
    const start_f = std.math.clamp(@floor((visible_min - origin) / tile_size), 0.0, count_f);
    const end_f = std.math.clamp(@ceil((visible_max - origin) / tile_size), 0.0, count_f);
    return .{ .start = @intFromFloat(start_f), .end = @intFromFloat(end_f) };
}

fn aabbIntersects(position: [2]f32, size: [2]f32, visible: VisibleWorldRect) bool {
    // 半开区间：仅接触任一边界不算可见。
    return position[0] < visible.max[0] and position[0] + size[0] > visible.min[0] and
        position[1] < visible.max[1] and position[1] + size[1] > visible.min[1];
}

fn chunkIntersectsVisible(layer: ChunkedTilemapLayerView, coordinate: [2]i32, visible: VisibleWorldRect) bool {
    const position = chunkWorldPositionF64(layer, coordinate);
    const size = [2]f64{
        @as(f64, @floatFromInt(layer.grid_size[0])) * chunked_tilemap_edge,
        @as(f64, @floatFromInt(layer.grid_size[1])) * chunked_tilemap_edge,
    };
    return position[0] < visible.max[0] and position[0] + size[0] > visible.min[0] and
        position[1] < visible.max[1] and position[1] + size[1] > visible.min[1];
}

fn chunkCellIntersectsVisible(layer: ChunkedTilemapLayerView, coordinate: [2]i32, local_index: u16, visible: VisibleWorldRect) bool {
    if (local_index >= chunked_tilemap_edge * chunked_tilemap_edge) return false;
    const chunk_position = chunkWorldPositionF64(layer, coordinate);
    const local_x = local_index % chunked_tilemap_edge;
    const local_y = local_index / chunked_tilemap_edge;
    const position = [2]f64{
        chunk_position[0] + @as(f64, @floatFromInt(local_x)) * @as(f64, @floatFromInt(layer.grid_size[0])),
        chunk_position[1] + @as(f64, @floatFromInt(local_y)) * @as(f64, @floatFromInt(layer.grid_size[1])),
    };
    return position[0] < visible.max[0] and position[0] + @as(f64, @floatFromInt(layer.grid_size[0])) > visible.min[0] and
        position[1] < visible.max[1] and position[1] + @as(f64, @floatFromInt(layer.grid_size[1])) > visible.min[1];
}

fn chunkWorldPositionF64(layer: ChunkedTilemapLayerView, coordinate: [2]i32) [2]f64 {
    return .{
        @as(f64, layer.origin[0]) + @as(f64, layer.offset[0]) +
            @as(f64, @floatFromInt(coordinate[0])) * chunked_tilemap_edge * @as(f64, @floatFromInt(layer.grid_size[0])),
        @as(f64, layer.origin[1]) + @as(f64, layer.offset[1]) +
            @as(f64, @floatFromInt(coordinate[1])) * chunked_tilemap_edge * @as(f64, @floatFromInt(layer.grid_size[1])),
    };
}

fn chunkCellWorldPosition(layer: ChunkedTilemapLayerView, coordinate: [2]i32, local_index: u16) ![2]f32 {
    const chunk_position = chunkWorldPositionF64(layer, coordinate);
    const local_x = local_index % chunked_tilemap_edge;
    const local_y = local_index / chunked_tilemap_edge;
    const position = [2]f64{
        chunk_position[0] + @as(f64, @floatFromInt(local_x)) * @as(f64, @floatFromInt(layer.grid_size[0])),
        chunk_position[1] + @as(f64, @floatFromInt(local_y)) * @as(f64, @floatFromInt(layer.grid_size[1])),
    };
    for (position) |number| if (!std.math.isFinite(number) or @abs(number) > std.math.floatMax(f32)) return error.InvalidTilemapOrigin;
    return .{ @floatCast(position[0]), @floatCast(position[1]) };
}

fn quadInstance(
    position: [2]f32,
    size: [2]f32,
    color: [4]f32,
    uv_rect: [4]f32,
    transform: TileTransform,
) GpuQuadInstance {
    return .{
        .rect_world = .{ position[0], position[1], size[0], size[1] },
        .color = color,
        .uv_rect = uv_rect,
        .transform = .{ @floatFromInt(@as(u3, @bitCast(transform))), 0, 0, 0 },
    };
}

fn submitBatch(encoder: *rhi.FrameEncoder, instances: []const GpuQuadInstance) !void {
    try encoder.bindInstanceData(std.mem.sliceAsBytes(instances));
    try encoder.drawInstanced(6, @intCast(instances.len));
}

fn shaderBytes(first_word: *const u32, word_count: u32) []const u8 {
    const words: [*]const u32 = @ptrCast(first_word);
    const count: usize = @intCast(word_count);
    return std.mem.sliceAsBytes(words[0..count]);
}
