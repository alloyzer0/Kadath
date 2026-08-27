const std = @import("std");
const rhi = @import("rhi");

extern const kadath_renderer2d_quad_vert_spv: u32;
extern const kadath_renderer2d_quad_vert_spv_word_count: u32;
extern const kadath_renderer2d_quad_frag_spv: u32;
extern const kadath_renderer2d_quad_frag_spv_word_count: u32;

const GpuSpriteInstance = extern struct {
    rect_ndc: [4]f32,
    color: [4]f32,
};

comptime {
    if (@sizeOf(GpuSpriteInstance) != 32) {
        @compileError("Renderer2D GPU sprite instance must stay 32 bytes");
    }
    if (@offsetOf(GpuSpriteInstance, "rect_ndc") != 0 or
        @offsetOf(GpuSpriteInstance, "color") != 16)
    {
        @compileError("Renderer2D GPU sprite instance layout changed");
    }
}

pub const max_sprites_per_frame: usize = rhi.max_instance_data_bytes_per_frame / @sizeOf(GpuSpriteInstance);

pub const SpriteInstance = struct {
    position: [2]f32,
    size: [2]f32,
    color: [4]f32,
    texture: rhi.TextureHandle,
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
                // 先保留既有 32-byte pipeline layout；本轮只替换 per-Sprite 提交路径。
                .push_constant_size = @sizeOf(GpuSpriteInstance),
                .uses_texture = true,
                .instance_data_stride = @sizeOf(GpuSpriteInstance),
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
        // Runtime 当前最多发布 128 个对象；在 beginFrame 前拒绝可避免部分命令录制。
        if (sprites.len > max_sprites_per_frame) return error.SpriteLimitExceeded;
        const begin = try backend.beginFrame(extent, .{ 0.035, 0.10, 0.22, 1.0 });
        switch (begin) {
            .skipped_minimized => return .skipped_minimized,
            .recreated => return .recreated,
            .ready => |ready| {
                var encoder = ready;
                errdefer encoder.consumeFailedFrame();

                const width: f32 = @floatFromInt(extent.width);
                const height: f32 = @floatFromInt(extent.height);
                if (sprites.len != 0) {
                    // 同一帧只使用一个 Renderer2D pipeline；空帧不录制无意义的状态。
                    try encoder.bindPipeline(self.pipeline);
                }

                var gpu_instances: [max_sprites_per_frame]GpuSpriteInstance = undefined;
                var batch_start: usize = 0;
                while (batch_start < sprites.len) {
                    const batch_texture = sprites[batch_start].texture;
                    var batch_end = batch_start + 1;
                    // 只合并连续纹理 run，绝不为减少 draw 而重排 Runtime Snapshot。
                    while (batch_end < sprites.len and sprites[batch_end].texture == batch_texture) : (batch_end += 1) {}

                    const batch_count = batch_end - batch_start;
                    for (sprites[batch_start..batch_end], 0..) |sprite, batch_index| {
                        gpu_instances[batch_index] = .{
                            .rect_ndc = .{
                                sprite.position[0] / width * 2.0 - 1.0,
                                1.0 - sprite.position[1] / height * 2.0,
                                sprite.size[0] / width * 2.0,
                                sprite.size[1] / height * 2.0,
                            },
                            .color = sprite.color,
                        };
                    }

                    try encoder.bindTexture(batch_texture);
                    try encoder.bindInstanceData(std.mem.sliceAsBytes(gpu_instances[0..batch_count]));
                    try encoder.drawInstanced(6, @intCast(batch_count));
                    batch_start = batch_end;
                }
                return try encoder.finish();
            },
        }
    }
};

fn shaderBytes(first_word: *const u32, word_count: u32) []const u8 {
    const words: [*]const u32 = @ptrCast(first_word);
    const count: usize = @intCast(word_count);
    return std.mem.sliceAsBytes(words[0..count]);
}
