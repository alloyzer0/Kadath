const std = @import("std");
const rhi = @import("rhi");

extern const kadath_renderer2d_quad_vert_spv: u32;
extern const kadath_renderer2d_quad_vert_spv_word_count: u32;
extern const kadath_renderer2d_quad_frag_spv: u32;
extern const kadath_renderer2d_quad_frag_spv_word_count: u32;

const QuadPushConstants = extern struct {
    rect_ndc: [4]f32,
    color: [4]f32,
};

comptime {
    if (@sizeOf(QuadPushConstants) != 32) {
        @compileError("Renderer2D push constants must stay 32 bytes");
    }
    if (@offsetOf(QuadPushConstants, "rect_ndc") != 0 or
        @offsetOf(QuadPushConstants, "color") != 16)
    {
        @compileError("Renderer2D push constant layout changed");
    }
}

pub const SpriteInstance = struct {
    position: [2]f32,
    size: [2]f32,
    color: [4]f32,
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
                .push_constant_size = @sizeOf(QuadPushConstants),
                .uses_texture = true,
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

    pub fn render(
        self: *Renderer2D,
        backend: *rhi.Rhi,
        extent: rhi.Extent2D,
        sprite: SpriteInstance,
        texture: rhi.TextureHandle,
    ) !rhi.FrameOutcome {
        const begin = try backend.beginFrame(extent, .{ 0.035, 0.10, 0.22, 1.0 });
        switch (begin) {
            .skipped_minimized => return .skipped_minimized,
            .recreated => return .recreated,
            .ready => |ready| {
                var encoder = ready;
                errdefer encoder.consumeFailedFrame();

                const width: f32 = @floatFromInt(extent.width);
                const height: f32 = @floatFromInt(extent.height);
                const push = QuadPushConstants{
                    .rect_ndc = .{
                        sprite.position[0] / width * 2.0 - 1.0,
                        1.0 - sprite.position[1] / height * 2.0,
                        sprite.size[0] / width * 2.0,
                        sprite.size[1] / height * 2.0,
                    },
                    .color = sprite.color,
                };

                try encoder.bindPipeline(self.pipeline);
                try encoder.bindTexture(texture);
                try encoder.pushConstants(std.mem.asBytes(&push));
                try encoder.draw(6);
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
