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

fn sprite(x: f32, y: f32, texture: rhi.TextureHandle) renderer2d.SpriteInstance {
    return .{
        .position = .{ x, y },
        .size = .{ 8, 8 },
        .color = .{ 1, 1, 1, 1 },
        .texture = texture,
    };
}

fn expectRecordingDelta(
    before: rhi.NullStats,
    after: rhi.NullStats,
    expected_pipeline_binds: u32,
    expected_texture_binds: u32,
    expected_sprites: u32,
) !void {
    try std.testing.expectEqual(expected_pipeline_binds, after.pipeline_binds - before.pipeline_binds);
    try std.testing.expectEqual(expected_texture_binds, after.texture_binds - before.texture_binds);
    // 提交批处理只减少状态绑定；每个精灵仍必须保留自己的常量和 draw。
    try std.testing.expectEqual(expected_sprites, after.push_constant_writes - before.push_constant_writes);
    try std.testing.expectEqual(expected_sprites, after.draws - before.draws);
}

fn expectNoRecordingDelta(before: rhi.NullStats, after: rhi.NullStats) !void {
    try expectRecordingDelta(before, after, 0, 0, 0);
}

test "Renderer2D init and deinit use the existing RHI seam" {
    var backend = try rhi.Rhi.init(extent);
    defer backend.deinit();

    var renderer = try renderer2d.Renderer2D.init(&backend);
    renderer.deinit(&backend);
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

test "Renderer2D batches pipeline and consecutive identical texture state" {
    var backend = try rhi.Rhi.init(extent);
    defer backend.deinit();
    var renderer = try renderer2d.Renderer2D.init(&backend);
    defer renderer.deinit(&backend);
    const texture = try makeTexture(&backend, &renderer);
    defer backend.destroyTexture(texture);

    const sprites = [_]renderer2d.SpriteInstance{ sprite(4, 4, texture), sprite(16, 8, texture), sprite(28, 12, texture) };
    const before = backend.stats();
    try std.testing.expectEqual(.presented, try renderer.renderSprites(&backend, extent, &sprites));
    const after = backend.stats();
    try expectRecordingDelta(before, after, 1, 1, 3);
    try std.testing.expectEqual(@as(u32, 1), after.frames_finished - before.frames_finished);
}

test "Renderer2D preserves input order while batching consecutive texture runs" {
    var backend = try rhi.Rhi.init(extent);
    defer backend.deinit();
    var renderer = try renderer2d.Renderer2D.init(&backend);
    defer renderer.deinit(&backend);
    const primary = try makeTexture(&backend, &renderer);
    defer backend.destroyTexture(primary);
    const secondary = try makeTexture(&backend, &renderer);
    defer backend.destroyTexture(secondary);

    const sprites = [_]renderer2d.SpriteInstance{
        .{ .position = .{ 4, 4 }, .size = .{ 8, 8 }, .color = .{ 1, 1, 1, 1 }, .texture = secondary },
        .{ .position = .{ 16, 8 }, .size = .{ 8, 8 }, .color = .{ 1, 1, 1, 1 }, .texture = primary },
        .{ .position = .{ 28, 12 }, .size = .{ 8, 8 }, .color = .{ 1, 1, 1, 1 }, .texture = primary },
    };
    const before = backend.stats();
    try std.testing.expectEqual(.presented, try renderer.renderSprites(&backend, extent, &sprites));
    const after = backend.stats();
    try expectRecordingDelta(before, after, 1, 2, 3);
    // Null trace 按 draw 记录实际纹理，用它证明批处理没有改变输入顺序。
    try std.testing.expectEqualSlices(
        rhi.TextureHandle,
        &.{ secondary, primary, primary },
        after.draw_texture_trace[before.draw_texture_trace_len..after.draw_texture_trace_len],
    );
}

test "Renderer2D starts a new texture batch when input returns to an earlier texture" {
    var backend = try rhi.Rhi.init(extent);
    defer backend.deinit();
    var renderer = try renderer2d.Renderer2D.init(&backend);
    defer renderer.deinit(&backend);
    const primary = try makeTexture(&backend, &renderer);
    defer backend.destroyTexture(primary);
    const secondary = try makeTexture(&backend, &renderer);
    defer backend.destroyTexture(secondary);

    const sprites = [_]renderer2d.SpriteInstance{
        sprite(4, 4, primary),
        sprite(12, 4, primary),
        sprite(20, 4, secondary),
        sprite(28, 4, secondary),
        sprite(36, 4, primary),
    };
    const before = backend.stats();
    try std.testing.expectEqual(.presented, try renderer.renderSprites(&backend, extent, &sprites));
    const after = backend.stats();
    try expectRecordingDelta(before, after, 1, 3, 5);
    try std.testing.expectEqualSlices(
        rhi.TextureHandle,
        &.{ primary, primary, secondary, secondary, primary },
        after.draw_texture_trace[before.draw_texture_trace_len..after.draw_texture_trace_len],
    );
}

test "Renderer2D accepts an empty sprite slice without recording draws" {
    var backend = try rhi.Rhi.init(extent);
    defer backend.deinit();
    var renderer = try renderer2d.Renderer2D.init(&backend);
    defer renderer.deinit(&backend);
    const before = backend.stats();
    try std.testing.expectEqual(.presented, try renderer.renderSprites(&backend, extent, &[_]renderer2d.SpriteInstance{}));
    const after = backend.stats();
    try expectNoRecordingDelta(before, after);
    try std.testing.expectEqual(@as(u32, 1), after.frames_finished - before.frames_finished);
}

test "Renderer2D preserves minimized and recreated outcomes without recording" {
    var backend = try rhi.Rhi.init(extent);
    defer backend.deinit();
    var renderer = try renderer2d.Renderer2D.init(&backend);
    defer renderer.deinit(&backend);
    const texture = try makeTexture(&backend, &renderer);
    defer backend.destroyTexture(texture);
    const sprites = [_]renderer2d.SpriteInstance{sprite(4, 4, texture)};

    var before = backend.stats();
    try std.testing.expectEqual(.skipped_minimized, try renderer.renderSprites(&backend, .{}, &sprites));
    var after = backend.stats();
    try expectNoRecordingDelta(before, after);
    try std.testing.expectEqual(before.frames_finished, after.frames_finished);

    before = after;
    try std.testing.expectEqual(.recreated, try renderer.renderSprites(&backend, .{ .width = 128, .height = 64 }, &sprites));
    after = backend.stats();
    try expectNoRecordingDelta(before, after);
    try std.testing.expectEqual(before.frames_finished, after.frames_finished);

    // recreated 只更新 RHI 尺寸状态；下一次稳定尺寸才进入正常录制路径。
    try std.testing.expectEqual(.presented, try renderer.renderSprites(&backend, .{ .width = 128, .height = 64 }, &sprites));
    try std.testing.expectEqual(@as(u32, 1), backend.stats().draws - after.draws);
}

test "Renderer2D consumes a failed frame and can present the next frame" {
    var backend = try rhi.Rhi.init(extent);
    defer backend.deinit();
    var renderer = try renderer2d.Renderer2D.init(&backend);
    defer renderer.deinit(&backend);
    const primary = try makeTexture(&backend, &renderer);
    defer backend.destroyTexture(primary);
    const stale = try makeTexture(&backend, &renderer);
    backend.destroyTexture(stale);
    const invalid_sprites = [_]renderer2d.SpriteInstance{
        sprite(4, 4, primary),
        sprite(16, 8, stale),
        sprite(28, 12, primary),
    };

    const before = backend.stats();
    try std.testing.expectError(
        error.InvalidTexture,
        renderer.renderSprites(&backend, extent, &invalid_sprites),
    );
    const after_failure = backend.stats();
    try std.testing.expectEqual(@as(u32, 1), after_failure.pipeline_binds - before.pipeline_binds);
    try std.testing.expectEqual(@as(u32, 1), after_failure.texture_binds - before.texture_binds);
    try std.testing.expectEqual(@as(u32, 1), after_failure.push_constant_writes - before.push_constant_writes);
    try std.testing.expectEqual(@as(u32, 1), after_failure.draws - before.draws);
    try std.testing.expectEqual(@as(u32, 1), after_failure.failed_frames_consumed - before.failed_frames_consumed);
    try std.testing.expectEqual(@as(u32, 0), after_failure.frames_finished - before.frames_finished);
    try std.testing.expectEqualSlices(
        rhi.TextureHandle,
        &.{primary},
        after_failure.draw_texture_trace[before.draw_texture_trace_len..after_failure.draw_texture_trace_len],
    );

    // 失败路径的 errdefer 必须消费 active token，否则这一帧会被错误卡在 FrameAlreadyActive。
    const replacement = try makeTexture(&backend, &renderer);
    defer backend.destroyTexture(replacement);
    const valid_sprites = [_]renderer2d.SpriteInstance{
        sprite(4, 4, primary),
        sprite(16, 8, replacement),
        sprite(28, 12, primary),
    };
    try std.testing.expectEqual(.presented, try renderer.renderSprites(&backend, extent, &valid_sprites));
    const after_success = backend.stats();
    try std.testing.expectEqual(@as(u32, 1), after_success.frames_finished - after_failure.frames_finished);
    try std.testing.expectEqual(@as(u32, 3), after_success.draws - after_failure.draws);
}

test "Renderer2D validates an invalid first texture before recording a draw" {
    var backend = try rhi.Rhi.init(extent);
    defer backend.deinit();
    var renderer = try renderer2d.Renderer2D.init(&backend);
    defer renderer.deinit(&backend);

    const before = backend.stats();
    const invalid_sprites = [_]renderer2d.SpriteInstance{sprite(4, 4, rhi.invalid_texture)};
    try std.testing.expectError(
        error.InvalidTexture,
        renderer.renderSprites(&backend, extent, &invalid_sprites),
    );
    const after_failure = backend.stats();
    // optional 绑定状态不能把 invalid_texture 误当成“已经绑定”的哨兵值。
    try expectRecordingDelta(before, after_failure, 1, 0, 0);
    try std.testing.expectEqual(@as(u32, 1), after_failure.failed_frames_consumed - before.failed_frames_consumed);

    const replacement = try makeTexture(&backend, &renderer);
    defer backend.destroyTexture(replacement);
    const valid_sprites = [_]renderer2d.SpriteInstance{sprite(4, 4, replacement)};
    try std.testing.expectEqual(.presented, try renderer.renderSprites(&backend, extent, &valid_sprites));
    try std.testing.expectEqual(@as(u32, 1), backend.stats().frames_finished - after_failure.frames_finished);
}
