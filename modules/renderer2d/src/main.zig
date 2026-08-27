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

pub const Frame2D = struct {
    tilemaps: []const TilemapLayerView = &.{},
    sprites: []const SpriteInstance = &.{},
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
        const instance_count = try validateFrame(frame);
        const begin = try backend.beginFrame(extent, .{ 0.035, 0.10, 0.22, 1.0 });
        switch (begin) {
            .skipped_minimized => return .skipped_minimized,
            .recreated => return .recreated,
            .ready => |ready| {
                var encoder = ready;
                errdefer encoder.consumeFailedFrame();

                const width: f32 = @floatFromInt(extent.width);
                const height: f32 = @floatFromInt(extent.height);
                if (instance_count != 0) try encoder.bindPipeline(self.pipeline);
                for (frame.tilemaps) |tilemap| try renderTilemap(&encoder, width, height, tilemap);
                try renderSpriteRuns(&encoder, width, height, frame.sprites);
                return try encoder.finish();
            },
        }
    }
};

fn validateFrame(frame: Frame2D) !usize {
    if (frame.sprites.len > max_sprites_per_frame) return error.SpriteLimitExceeded;
    if (frame.tilemaps.len > max_tilemap_layers_per_frame) return error.TilemapLayerLimitExceeded;
    var total_instances = frame.sprites.len;
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
        if (tilemap.texture == rhi.invalid_texture) return error.InvalidTexture;
        for (tilemap.cells) |cell| {
            if (cell > atlas_tiles) return error.InvalidTilemapCell;
            if (cell != 0) total_instances = try std.math.add(usize, total_instances, 1);
        }
    }
    const total_bytes = try std.math.mul(usize, total_instances, @sizeOf(GpuQuadInstance));
    if (total_bytes > rhi.max_instance_data_bytes_per_frame) return error.InstanceDataFrameLimitReached;
    return total_instances;
}

fn renderTilemap(
    encoder: *rhi.FrameEncoder,
    width: f32,
    height: f32,
    tilemap: TilemapLayerView,
) !void {
    var gpu_instances: [max_instances_per_binding]GpuQuadInstance = undefined;
    var batch_count: usize = 0;
    var texture_bound = false;
    for (tilemap.cells, 0..) |cell, cell_index| {
        if (cell == 0) continue;
        const column = cell_index % @as(usize, tilemap.columns);
        const row = cell_index / @as(usize, tilemap.columns);
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
    if (batch_count != 0) {
        if (!texture_bound) try encoder.bindTexture(tilemap.texture);
        try submitBatch(encoder, gpu_instances[0..batch_count]);
    }
}

fn renderSpriteRuns(
    encoder: *rhi.FrameEncoder,
    width: f32,
    height: f32,
    sprites: []const SpriteInstance,
) !void {
    var gpu_instances: [max_instances_per_binding]GpuQuadInstance = undefined;
    var batch_start: usize = 0;
    while (batch_start < sprites.len) {
        const batch_texture = sprites[batch_start].texture;
        var batch_end = batch_start + 1;
        // Runtime Snapshot 顺序是正式语义；只合并连续纹理 run。
        while (batch_end < sprites.len and sprites[batch_end].texture == batch_texture) : (batch_end += 1) {}
        const batch_count = batch_end - batch_start;
        for (sprites[batch_start..batch_end], 0..) |sprite, batch_index| {
            gpu_instances[batch_index] = quadInstance(
                width,
                height,
                sprite.position,
                sprite.size,
                sprite.color,
                sprite.uv_rect,
            );
        }
        try encoder.bindTexture(batch_texture);
        try submitBatch(encoder, gpu_instances[0..batch_count]);
        batch_start = batch_end;
    }
}

fn quadInstance(
    width: f32,
    height: f32,
    position: [2]f32,
    size: [2]f32,
    color: [4]f32,
    uv_rect: [4]f32,
) GpuQuadInstance {
    return .{
        .rect_ndc = .{
            position[0] / width * 2.0 - 1.0,
            1.0 - position[1] / height * 2.0,
            size[0] / width * 2.0,
            size[1] / height * 2.0,
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
