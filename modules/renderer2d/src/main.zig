const std = @import("std");
const rhi = @import("rhi");

extern const kadath_renderer2d_quad_vert_spv: u32;
extern const kadath_renderer2d_quad_vert_spv_word_count: u32;
extern const kadath_renderer2d_quad_frag_spv: u32;
extern const kadath_renderer2d_quad_frag_spv_word_count: u32;

const GpuQuadInstance = extern struct {
    rect_ndc: [4]f32,
    color: [4]f32,
    uv_rect: [4]f32,
};

comptime {
    if (@sizeOf(GpuQuadInstance) != 48) {
        @compileError("Renderer2D GPU quad instance must stay 48 bytes");
    }
    if (@offsetOf(GpuQuadInstance, "rect_ndc") != 0 or
        @offsetOf(GpuQuadInstance, "color") != 16 or
        @offsetOf(GpuQuadInstance, "uv_rect") != 32)
    {
        @compileError("Renderer2D GPU quad instance layout changed");
    }
}

/// Runtime Object publication 上限独立于 RHI 的整帧 Tilemap 上传容量。
pub const max_sprites_per_frame: usize = 128;
pub const max_tilemap_layers_per_frame: usize = 1;
pub const max_tilemap_columns: usize = 32;
pub const max_tilemap_rows: usize = 32;
pub const max_tilemap_cells_per_frame: usize = max_tilemap_columns * max_tilemap_rows;
pub const max_tilemap_atlas_dimension: usize = 256;
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

pub const Camera2DView = struct {
    // origin 是视口左上角对应的世界坐标；恒等默认值保持历史调用方兼容。
    origin: [2]f32 = .{ 0.0, 0.0 },
    zoom: f32 = 1.0,
};

pub const Frame2D = struct {
    view: Camera2DView = .{},
    tilemaps: []const TilemapLayerView = &.{},
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
                .push_constant_size = @sizeOf(GpuQuadInstance),
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
        const instance_count = try validateFrame(backend, frame);
        const begin = try backend.beginFrame(extent, .{ 0.035, 0.10, 0.22, 1.0 });
        switch (begin) {
            .skipped_minimized => return .skipped_minimized,
            .recreated => return .recreated,
            .ready => |ready| {
                var encoder = ready;
                errdefer encoder.consumeFailedFrame();

                const width: f32 = @floatFromInt(extent.width);
                const height: f32 = @floatFromInt(extent.height);
                const visible = visibleWorldRect(extent, frame.view);
                if (instance_count != 0) try encoder.bindPipeline(self.pipeline);
                for (frame.tilemaps) |tilemap| try renderTilemap(&encoder, width, height, frame.view, visible, tilemap);
                try renderSpriteRuns(&encoder, width, height, frame.view, visible, frame.sprites);
                return try encoder.finish();
            },
        }
    }
};

fn validateFrame(backend: *rhi.Rhi, frame: Frame2D) !usize {
    for (frame.view.origin) |number| {
        if (!std.math.isFinite(number)) return error.InvalidCameraOrigin;
    }
    if (!std.math.isFinite(frame.view.zoom) or frame.view.zoom < 0.125 or frame.view.zoom > 8.0) {
        return error.InvalidCameraZoom;
    }
    if (frame.sprites.len > max_sprites_per_frame) return error.SpriteLimitExceeded;
    if (frame.tilemaps.len > max_tilemap_layers_per_frame) return error.TilemapLayerLimitExceeded;
    var total_instances = frame.sprites.len;
    for (frame.sprites) |sprite| {
        try validateSprite(sprite);
        try backend.validateTextureHandle(sprite.texture);
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
        for (tilemap.cells) |cell| {
            if (cell > atlas_tiles) return error.InvalidTilemapCell;
            if (cell != 0) total_instances = try std.math.add(usize, total_instances, 1);
        }
    }
    const total_bytes = try std.math.mul(usize, total_instances, @sizeOf(GpuQuadInstance));
    if (total_bytes > rhi.max_instance_data_bytes_per_frame) return error.InstanceDataFrameLimitReached;
    return total_instances;
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
    width: f32,
    height: f32,
    view: Camera2DView,
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
                width,
                height,
                view,
                position,
                tilemap.tile_size,
                .{ 1, 1, 1, 1 },
                .{
                    @as(f32, @floatFromInt(atlas_column)) / @as(f32, @floatFromInt(tilemap.atlas_columns)),
                    @as(f32, @floatFromInt(atlas_row)) / @as(f32, @floatFromInt(tilemap.atlas_rows)),
                    1.0 / @as(f32, @floatFromInt(tilemap.atlas_columns)),
                    1.0 / @as(f32, @floatFromInt(tilemap.atlas_rows)),
                },
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

fn renderSpriteRuns(
    encoder: *rhi.FrameEncoder,
    width: f32,
    height: f32,
    view: Camera2DView,
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
        gpu_instances[batch_count] = quadInstance(width, height, view, sprite.position, sprite.size, sprite.color, sprite.uv_rect);
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

fn quadInstance(
    width: f32,
    height: f32,
    view: Camera2DView,
    position: [2]f32,
    size: [2]f32,
    color: [4]f32,
    uv_rect: [4]f32,
) GpuQuadInstance {
    const screen_position = [2]f32{
        (position[0] - view.origin[0]) * view.zoom,
        (position[1] - view.origin[1]) * view.zoom,
    };
    const screen_size = [2]f32{ size[0] * view.zoom, size[1] * view.zoom };
    return .{
        .rect_ndc = .{
            screen_position[0] / width * 2.0 - 1.0,
            1.0 - screen_position[1] / height * 2.0,
            screen_size[0] / width * 2.0,
            screen_size[1] / height * 2.0,
        },
        .color = color,
        .uv_rect = uv_rect,
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
