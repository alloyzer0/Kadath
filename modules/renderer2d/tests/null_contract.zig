const std = @import("std");
const rhi = @import("rhi");
const renderer2d = @import("renderer2d");

// 这些占位字节只满足 Null Adapter 的非空/4-byte 对齐检查，不代表真实 SPIR-V。
export var kadath_renderer2d_quad_vert_spv: u32 = 0;
export var kadath_renderer2d_quad_vert_spv_word_count: u32 = 1;
export var kadath_renderer2d_quad_frag_spv: u32 = 0;
export var kadath_renderer2d_quad_frag_spv_word_count: u32 = 1;

const extent = rhi.Extent2D{ .width = 64, .height = 64 };

fn makeTexture(backend: *rhi.Rhi, renderer: *renderer2d.Renderer2D) !rhi.TextureHandle {
    const pixels = [_]u8{ 255, 255, 255, 255 };
    return renderer.createTexture(
        backend,
        .{ .width = 1, .height = 1, .rgba8 = &pixels },
        .smooth_mipmap,
    );
}

fn sprite(x: f32, y: f32) renderer2d.SpriteInstance {
    return .{
        .position = .{ x, y },
        .size = .{ 8, 8 },
        .color = .{ 1, 1, 1, 1 },
    };
}

fn expectRecordingDelta(before: rhi.NullStats, after: rhi.NullStats, expected: u32) !void {
    try std.testing.expectEqual(expected, after.pipeline_binds - before.pipeline_binds);
    try std.testing.expectEqual(expected, after.texture_binds - before.texture_binds);
    try std.testing.expectEqual(expected, after.push_constant_writes - before.push_constant_writes);
    try std.testing.expectEqual(expected, after.draws - before.draws);
}

fn expectNoRecordingDelta(before: rhi.NullStats, after: rhi.NullStats) !void {
    try expectRecordingDelta(before, after, 0);
}

test "Renderer2D init and deinit use the existing RHI seam" {
    var backend = try rhi.Rhi.init(0, 0, extent);
    defer backend.deinit();

    var renderer = try renderer2d.Renderer2D.init(&backend);
    try std.testing.expect(renderer.pipeline != rhi.invalid_pipeline);
    renderer.deinit(&backend);
    try std.testing.expectEqual(rhi.invalid_pipeline, renderer.pipeline);
    try std.testing.expectError(
        error.RendererNotInitialized,
        renderer.createTexture(
            &backend,
            .{ .width = 1, .height = 1, .rgba8 = &[_]u8{ 255, 255, 255, 255 } },
            .pixel_art,
        ),
    );
    // deinit 的幂等性属于 Renderer2D 生命周期，不要求 Null 暴露额外状态。
    renderer.deinit(&backend);
}

test "Renderer2D records one command sequence per sprite" {
    var backend = try rhi.Rhi.init(0, 0, extent);
    defer backend.deinit();
    var renderer = try renderer2d.Renderer2D.init(&backend);
    defer renderer.deinit(&backend);
    const texture = try makeTexture(&backend, &renderer);
    defer backend.destroyTexture(texture);

    const sprites = [_]renderer2d.SpriteInstance{ sprite(4, 4), sprite(16, 8), sprite(28, 12) };
    const before = backend.stats();
    try std.testing.expectEqual(.presented, try renderer.renderSprites(&backend, extent, &sprites, texture));
    const after = backend.stats();
    try expectRecordingDelta(before, after, 3);
    try std.testing.expectEqual(@as(u32, 1), after.frames_finished - before.frames_finished);
}

test "Renderer2D accepts an empty sprite slice without recording draws" {
    var backend = try rhi.Rhi.init(0, 0, extent);
    defer backend.deinit();
    var renderer = try renderer2d.Renderer2D.init(&backend);
    defer renderer.deinit(&backend);
    const texture = try makeTexture(&backend, &renderer);
    defer backend.destroyTexture(texture);

    const before = backend.stats();
    try std.testing.expectEqual(.presented, try renderer.renderSprites(&backend, extent, &[_]renderer2d.SpriteInstance{}, texture));
    const after = backend.stats();
    try expectNoRecordingDelta(before, after);
    try std.testing.expectEqual(@as(u32, 1), after.frames_finished - before.frames_finished);
}

test "Renderer2D preserves minimized and recreated outcomes without recording" {
    var backend = try rhi.Rhi.init(0, 0, extent);
    defer backend.deinit();
    var renderer = try renderer2d.Renderer2D.init(&backend);
    defer renderer.deinit(&backend);
    const texture = try makeTexture(&backend, &renderer);
    defer backend.destroyTexture(texture);
    const sprites = [_]renderer2d.SpriteInstance{sprite(4, 4)};

    var before = backend.stats();
    try std.testing.expectEqual(.skipped_minimized, try renderer.renderSprites(&backend, .{}, &sprites, texture));
    var after = backend.stats();
    try expectNoRecordingDelta(before, after);
    try std.testing.expectEqual(before.frames_finished, after.frames_finished);

    before = after;
    try std.testing.expectEqual(.recreated, try renderer.renderSprites(&backend, .{ .width = 128, .height = 64 }, &sprites, texture));
    after = backend.stats();
    try expectNoRecordingDelta(before, after);
    try std.testing.expectEqual(before.frames_finished, after.frames_finished);

    // recreated 只更新 RHI 尺寸状态；下一次稳定尺寸才进入正常录制路径。
    try std.testing.expectEqual(.presented, try renderer.renderSprites(&backend, .{ .width = 128, .height = 64 }, &sprites, texture));
    try std.testing.expectEqual(@as(u32, 1), backend.stats().draws - after.draws);
}

test "Renderer2D consumes a failed frame and can present the next frame" {
    var backend = try rhi.Rhi.init(0, 0, extent);
    defer backend.deinit();
    var renderer = try renderer2d.Renderer2D.init(&backend);
    defer renderer.deinit(&backend);
    const texture = try makeTexture(&backend, &renderer);
    defer backend.destroyTexture(texture);
    const sprites = [_]renderer2d.SpriteInstance{sprite(4, 4)};

    const before = backend.stats();
    try std.testing.expectError(
        error.InvalidTexture,
        renderer.renderSprites(&backend, extent, &sprites, rhi.invalid_texture),
    );
    const after_failure = backend.stats();
    try std.testing.expectEqual(@as(u32, 1), after_failure.pipeline_binds - before.pipeline_binds);
    try std.testing.expectEqual(@as(u32, 0), after_failure.texture_binds - before.texture_binds);
    try std.testing.expectEqual(@as(u32, 1), after_failure.failed_frames_consumed - before.failed_frames_consumed);
    try std.testing.expectEqual(@as(u32, 0), after_failure.frames_finished - before.frames_finished);

    // 失败路径的 errdefer 必须消费 active token，否则这一帧会被错误卡在 FrameAlreadyActive。
    try std.testing.expectEqual(.presented, try renderer.renderSprites(&backend, extent, &sprites, texture));
    const after_success = backend.stats();
    try std.testing.expectEqual(@as(u32, 1), after_success.frames_finished - after_failure.frames_finished);
    try std.testing.expectEqual(@as(u32, 1), after_success.draws - after_failure.draws);
}
