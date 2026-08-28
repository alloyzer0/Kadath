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
    expected_instance_data_binds: u32,
    expected_draws: u32,
    expected_instances: u32,
) !void {
    try std.testing.expectEqual(expected_pipeline_binds, after.pipeline_binds - before.pipeline_binds);
    try std.testing.expectEqual(expected_texture_binds, after.texture_binds - before.texture_binds);
    try std.testing.expectEqual(expected_instance_data_binds, after.instance_data_binds - before.instance_data_binds);
    // 每个非空 Frame 只写一次 world→clip View 常量；draw 数仍等于连续纹理批次数。
    try std.testing.expectEqual(@as(u32, if (expected_instances == 0) 0 else 1), after.push_constant_writes - before.push_constant_writes);
    try std.testing.expectEqual(expected_draws, after.draws - before.draws);
    try std.testing.expectEqual(expected_instances, after.instances_drawn - before.instances_drawn);
}

fn expectNoRecordingDelta(before: rhi.NullStats, after: rhi.NullStats) !void {
    try expectRecordingDelta(before, after, 0, 0, 0, 0, 0);
}

fn traceF32(bytes: []const u8, offset: usize) f32 {
    const bits = @as(u32, bytes[offset]) |
        (@as(u32, bytes[offset + 1]) << 8) |
        (@as(u32, bytes[offset + 2]) << 16) |
        (@as(u32, bytes[offset + 3]) << 24);
    return @bitCast(bits);
}

test "Renderer2D explicit identity Camera2D preserves the instance byte trace" {
    var backend = try rhi.Rhi.init(extent);
    defer backend.deinit();
    var renderer = try renderer2d.Renderer2D.init(&backend);
    defer renderer.deinit(&backend);
    const texture = try makeTexture(&backend, &renderer);
    defer backend.destroyTexture(texture);
    const sprites = [_]renderer2d.SpriteInstance{sprite(20, 12, texture)};

    try std.testing.expectEqual(.presented, try renderer.renderFrame(&backend, extent, .{ .sprites = &sprites }));
    const first = backend.stats();
    try std.testing.expectEqual(.presented, try renderer.renderFrame(&backend, extent, .{
        .view = .{ .origin = .{ 0, 0 }, .zoom = 1 },
        .sprites = &sprites,
    }));
    const second = backend.stats();
    try std.testing.expectEqualSlices(
        u8,
        first.instance_data_trace[0..64],
        second.instance_data_trace[64..128],
    );
    std.debug.print("CAMERA_IDENTITY_COMPATIBLE=true\n", .{});
}

test "Renderer2D publishes world-space instances and Camera2D push constants" {
    var backend = try rhi.Rhi.init(extent);
    defer backend.deinit();
    var renderer = try renderer2d.Renderer2D.init(&backend);
    defer renderer.deinit(&backend);
    const texture = try makeTexture(&backend, &renderer);
    defer backend.destroyTexture(texture);

    const sprites = [_]renderer2d.SpriteInstance{sprite(20, 12, texture)};
    try std.testing.expectEqual(.presented, try renderer.renderFrame(&backend, extent, .{
        .view = .{ .origin = .{ 16, 8 }, .zoom = 2 },
        .sprites = &sprites,
    }));
    const stats = backend.stats();
    try std.testing.expectApproxEqAbs(@as(f32, 20), traceF32(&stats.instance_data_trace, 0), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 12), traceF32(&stats.instance_data_trace, 4), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 8), traceF32(&stats.instance_data_trace, 8), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 8), traceF32(&stats.instance_data_trace, 12), 0.0001);
    // push constants: viewport vec4 后是 Camera origin x/y 与 zoom。
    try std.testing.expectApproxEqAbs(@as(f32, 16), traceF32(&stats.push_constant_trace, 16), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 8), traceF32(&stats.push_constant_trace, 20), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 2), traceF32(&stats.push_constant_trace, 24), 0.0001);
}

test "Renderer2D culls Tilemap with half-open visible row and column ranges" {
    var backend = try rhi.Rhi.init(extent);
    defer backend.deinit();
    var renderer = try renderer2d.Renderer2D.init(&backend);
    defer renderer.deinit(&backend);
    const texture = try makeTexture(&backend, &renderer);
    defer backend.destroyTexture(texture);

    const cells = [_]u16{1} ** 16;
    const tilemaps = [_]renderer2d.TilemapLayerView{.{
        .origin = .{ 0, 0 },
        .tile_size = .{ 16, 16 },
        .columns = 4,
        .rows = 4,
        .atlas_columns = 1,
        .atlas_rows = 1,
        .texture = texture,
        .cells = &cells,
    }};
    const before = backend.stats();
    try std.testing.expectEqual(.presented, try renderer.renderFrame(&backend, extent, .{
        .view = .{ .origin = .{ 16, 16 }, .zoom = 2 },
        .tilemaps = &tilemaps,
    }));
    // 可见世界矩形为 [16,48) x [16,48)，精确排除只接触边界的 Tile。
    try expectRecordingDelta(before, backend.stats(), 1, 1, 1, 1, 4);
    std.debug.print("CAMERA_TILEMAP_CULLING=true\n", .{});
}

test "Renderer2D recomputes Camera visible ranges after extent recreation" {
    var backend = try rhi.Rhi.init(extent);
    defer backend.deinit();
    var renderer = try renderer2d.Renderer2D.init(&backend);
    defer renderer.deinit(&backend);
    const texture = try makeTexture(&backend, &renderer);
    defer backend.destroyTexture(texture);

    const cells = [_]u16{1} ** 8;
    const tilemaps = [_]renderer2d.TilemapLayerView{.{
        .origin = .{ 0, 0 },
        .tile_size = .{ 16, 16 },
        .columns = 8,
        .rows = 1,
        .atlas_columns = 1,
        .atlas_rows = 1,
        .texture = texture,
        .cells = &cells,
    }};
    var before = backend.stats();
    try std.testing.expectEqual(.presented, try renderer.renderFrame(&backend, extent, .{ .tilemaps = &tilemaps }));
    try expectRecordingDelta(before, backend.stats(), 1, 1, 1, 1, 4);

    const resized = rhi.Extent2D{ .width = 128, .height = 64 };
    before = backend.stats();
    try std.testing.expectEqual(.recreated, try renderer.renderFrame(&backend, resized, .{ .tilemaps = &tilemaps }));
    try expectNoRecordingDelta(before, backend.stats());

    before = backend.stats();
    try std.testing.expectEqual(.presented, try renderer.renderFrame(&backend, resized, .{ .tilemaps = &tilemaps }));
    try expectRecordingDelta(before, backend.stats(), 1, 1, 1, 1, 8);
}

test "Renderer2D culls sprites and merges visible texture runs across invisible separators" {
    var backend = try rhi.Rhi.init(extent);
    defer backend.deinit();
    var renderer = try renderer2d.Renderer2D.init(&backend);
    defer renderer.deinit(&backend);
    const primary = try makeTexture(&backend, &renderer);
    defer backend.destroyTexture(primary);
    const secondary = try makeTexture(&backend, &renderer);
    defer backend.destroyTexture(secondary);

    const sprites = [_]renderer2d.SpriteInstance{
        sprite(0, 4, primary),
        sprite(64, 4, secondary), // 从右边界起始，按半开区间不可见。
        sprite(16, 4, primary),
        sprite(-8, 4, secondary), // 在左边界结束，按半开区间不可见。
    };
    const before = backend.stats();
    try std.testing.expectEqual(.presented, try renderer.renderFrame(&backend, extent, .{ .sprites = &sprites }));
    try expectRecordingDelta(before, backend.stats(), 1, 1, 1, 1, 2);
    std.debug.print("CAMERA_SPRITE_CULLING=true\n", .{});
}

test "Renderer2D rejects invalid invisible camera and sprite data before beginFrame" {
    var backend = try rhi.Rhi.init(extent);
    defer backend.deinit();
    var renderer = try renderer2d.Renderer2D.init(&backend);
    defer renderer.deinit(&backend);

    var before = backend.stats();
    try std.testing.expectError(error.InvalidCameraZoom, renderer.renderFrame(&backend, extent, .{
        .view = .{ .zoom = 0 },
    }));
    try expectNoRecordingDelta(before, backend.stats());

    const invalid_sprites = [_]renderer2d.SpriteInstance{sprite(128, 4, rhi.invalid_texture)};
    before = backend.stats();
    try std.testing.expectError(error.InvalidTexture, renderer.renderFrame(&backend, extent, .{ .sprites = &invalid_sprites }));
    try expectNoRecordingDelta(before, backend.stats());

    const stale = try makeTexture(&backend, &renderer);
    backend.destroyTexture(stale);
    const stale_invisible = [_]renderer2d.SpriteInstance{sprite(128, 4, stale)};
    before = backend.stats();
    try std.testing.expectError(error.InvalidTexture, renderer.renderFrame(&backend, extent, .{ .sprites = &stale_invisible }));
    try expectNoRecordingDelta(before, backend.stats());
}

test "Renderer2D renders bounded tilemap before dynamic sprites in one frame" {
    var backend = try rhi.Rhi.init(extent);
    defer backend.deinit();
    var renderer = try renderer2d.Renderer2D.init(&backend);
    defer renderer.deinit(&backend);
    const texture = try makeTexture(&backend, &renderer);
    defer backend.destroyTexture(texture);

    const cells = [_]u16{ 1, 0, 6, 16 };
    const tilemaps = [_]renderer2d.TilemapLayerView{.{
        .origin = .{ 0, 0 },
        .tile_size = .{ 16, 16 },
        .columns = 2,
        .rows = 2,
        .atlas_columns = 4,
        .atlas_rows = 4,
        .texture = texture,
        .cells = &cells,
    }};
    const sprites = [_]renderer2d.SpriteInstance{sprite(8, 8, texture)};

    const before = backend.stats();
    try std.testing.expectEqual(.presented, try renderer.renderFrame(&backend, extent, .{
        .tilemaps = &tilemaps,
        .sprites = &sprites,
    }));
    const after = backend.stats();
    try expectRecordingDelta(before, after, 1, 2, 2, 2, 4);
    try std.testing.expectEqualSlices(
        rhi.TextureHandle,
        &.{ texture, texture },
        after.draw_texture_trace[before.draw_texture_trace_len..after.draw_texture_trace_len],
    );
}

test "Renderer2D expands one-based atlas indices into stable UV rectangles" {
    var backend = try rhi.Rhi.init(extent);
    defer backend.deinit();
    var renderer = try renderer2d.Renderer2D.init(&backend);
    defer renderer.deinit(&backend);
    const texture = try makeTexture(&backend, &renderer);
    defer backend.destroyTexture(texture);

    const cells = [_]u16{ 1, 6 };
    const tilemaps = [_]renderer2d.TilemapLayerView{.{
        .origin = .{ 0, 0 },
        .tile_size = .{ 16, 16 },
        .columns = 2,
        .rows = 1,
        .atlas_columns = 4,
        .atlas_rows = 4,
        .texture = texture,
        .cells = &cells,
    }};
    try std.testing.expectEqual(.presented, try renderer.renderFrame(&backend, extent, .{
        .view = .{ .zoom = 0.125 },
        .tilemaps = &tilemaps,
    }));

    const stats = backend.stats();
    try std.testing.expectEqual(@as(usize, 128), stats.instance_data_trace_len);
    // 64-byte instance 的 uv_rect 位于 32..48；Tile 1 为 (0,0)，Tile 6 为 (1,1)。
    try std.testing.expectApproxEqAbs(@as(f32, 0), traceF32(&stats.instance_data_trace, 32), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), traceF32(&stats.instance_data_trace, 36), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), traceF32(&stats.instance_data_trace, 40), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), traceF32(&stats.instance_data_trace, 44), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), traceF32(&stats.instance_data_trace, 96), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), traceF32(&stats.instance_data_trace, 100), 0.0001);
}

test "Renderer2D splits a full 32 by 32 tilemap into eight bounded draws" {
    var backend = try rhi.Rhi.init(extent);
    defer backend.deinit();
    var renderer = try renderer2d.Renderer2D.init(&backend);
    defer renderer.deinit(&backend);
    const texture = try makeTexture(&backend, &renderer);
    defer backend.destroyTexture(texture);

    const cells = [_]u16{1} ** renderer2d.max_tilemap_cells_per_frame;
    const tilemaps = [_]renderer2d.TilemapLayerView{.{
        .origin = .{ 0, 0 },
        .tile_size = .{ 8, 8 },
        .columns = 32,
        .rows = 32,
        .atlas_columns = 1,
        .atlas_rows = 1,
        .texture = texture,
        .cells = &cells,
    }};
    const before = backend.stats();
    try std.testing.expectEqual(.presented, try renderer.renderFrame(&backend, extent, .{
        .view = .{ .zoom = 0.125 },
        .tilemaps = &tilemaps,
    }));
    try expectRecordingDelta(before, backend.stats(), 1, 1, 8, 8, 1024);
}

test "Renderer2D skips empty cells and splits 129 visible tiles" {
    var backend = try rhi.Rhi.init(extent);
    defer backend.deinit();
    var renderer = try renderer2d.Renderer2D.init(&backend);
    defer renderer.deinit(&backend);
    const texture = try makeTexture(&backend, &renderer);
    defer backend.destroyTexture(texture);

    var cells = [_]u16{0} ** 160;
    const tilemaps = [_]renderer2d.TilemapLayerView{.{
        .origin = .{ 0, 0 },
        .tile_size = .{ 8, 8 },
        .columns = 32,
        .rows = 5,
        .atlas_columns = 1,
        .atlas_rows = 1,
        .texture = texture,
        .cells = &cells,
    }};
    var before = backend.stats();
    try std.testing.expectEqual(.presented, try renderer.renderFrame(&backend, extent, .{
        .view = .{ .zoom = 0.125 },
        .tilemaps = &tilemaps,
    }));
    try expectNoRecordingDelta(before, backend.stats());

    @memset(cells[0..129], 1);
    before = backend.stats();
    try std.testing.expectEqual(.presented, try renderer.renderFrame(&backend, extent, .{
        .view = .{ .zoom = 0.125 },
        .tilemaps = &tilemaps,
    }));
    try expectRecordingDelta(before, backend.stats(), 1, 1, 2, 2, 129);
}

test "Renderer2D accepts the frozen 1024 tile plus 128 sprite frame budget" {
    var backend = try rhi.Rhi.init(extent);
    defer backend.deinit();
    var renderer = try renderer2d.Renderer2D.init(&backend);
    defer renderer.deinit(&backend);
    const texture = try makeTexture(&backend, &renderer);
    defer backend.destroyTexture(texture);

    const cells = [_]u16{1} ** renderer2d.max_tilemap_cells_per_frame;
    const tilemaps = [_]renderer2d.TilemapLayerView{.{
        .origin = .{ 0, 0 },
        .tile_size = .{ 8, 8 },
        .columns = 32,
        .rows = 32,
        .atlas_columns = 1,
        .atlas_rows = 1,
        .texture = texture,
        .cells = &cells,
    }};
    var sprites: [renderer2d.max_sprites_per_frame]renderer2d.SpriteInstance = undefined;
    for (&sprites, 0..) |*item, index| item.* = sprite(@floatFromInt(index), 4, texture);

    const before = backend.stats();
    try std.testing.expectEqual(.presented, try renderer.renderFrame(&backend, extent, .{
        .view = .{ .zoom = 0.125 },
        .tilemaps = &tilemaps,
        .sprites = &sprites,
    }));
    // Tilemap 与动态 Sprite 是两个语义段，即便 Texture 相同也不能跨边界重排/合批。
    try expectRecordingDelta(before, backend.stats(), 1, 2, 9, 9, 1152);
    std.debug.print("TILEMAP_BATCH_1024=true\n", .{});
}

test "Renderer2D renders visible multi-source chunks in stable layer and cell order" {
    var backend = try rhi.Rhi.init(extent);
    defer backend.deinit();
    var renderer = try renderer2d.Renderer2D.init(&backend);
    defer renderer.deinit(&backend);
    const ground = try makeTexture(&backend, &renderer);
    defer backend.destroyTexture(ground);
    const decor = try makeTexture(&backend, &renderer);
    defer backend.destroyTexture(decor);

    const sources = [_]renderer2d.TileSourceView{
        .{ .texture = ground, .tile_size = .{ 16, 16 }, .image_size = .{ 35, 18 }, .columns = 2, .rows = 1, .margin = 1, .spacing = 1 },
        .{ .texture = decor, .tile_size = .{ 16, 16 }, .image_size = .{ 16, 16 }, .columns = 1, .rows = 1, .margin = 0, .spacing = 0 },
    };
    const visible_cells = [_]renderer2d.ChunkedTileCellView{
        .{ .local_index = 0, .tile_source_index = 0, .local_tile_id = 0 },
        .{ .local_index = 1, .tile_source_index = 1, .local_tile_id = 0, .transform = .{ .flip_horizontal = true, .flip_vertical = true, .flip_diagonal = true } },
    };
    const far_cells = [_]renderer2d.ChunkedTileCellView{.{ .local_index = 0, .tile_source_index = 0, .local_tile_id = 1 }};
    const background_chunks = [_]renderer2d.TilemapChunkView{
        .{ .coordinate = .{ 0, 0 }, .cells = &visible_cells },
        .{ .coordinate = .{ 100, 100 }, .cells = &far_cells },
    };
    const foreground_cells = [_]renderer2d.ChunkedTileCellView{.{ .local_index = 0, .tile_source_index = 0, .local_tile_id = 1 }};
    const foreground_chunks = [_]renderer2d.TilemapChunkView{.{ .coordinate = .{ 0, 0 }, .cells = &foreground_cells }};
    const layers = [_]renderer2d.ChunkedTilemapLayerView{
        .{ .origin = .{ 0, 0 }, .offset = .{ 0, 0 }, .grid_size = .{ 16, 16 }, .tile_sources = &sources, .chunks = &background_chunks },
        .{ .origin = .{ 0, 0 }, .offset = .{ 0, 0 }, .grid_size = .{ 16, 16 }, .opacity = 0.5, .tile_sources = &sources, .chunks = &foreground_chunks },
    };
    const before = backend.stats();
    try std.testing.expectEqual(.presented, try renderer.renderFrame(&backend, extent, .{ .chunked_tilemap_layers = &layers }));
    const after = backend.stats();
    try expectRecordingDelta(before, after, 1, 3, 3, 3, 3);
    try std.testing.expectEqualSlices(
        rhi.TextureHandle,
        &.{ ground, decor, ground },
        after.draw_texture_trace[before.draw_texture_trace_len..after.draw_texture_trace_len],
    );
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 35.0), traceF32(&after.instance_data_trace, 32), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 7), traceF32(&after.instance_data_trace, 64 + 48), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), traceF32(&after.instance_data_trace, 128 + 28), 0.0001);
    std.debug.print("TILEMAP_CHUNKED_LAYERS=true\n", .{});
}

test "Renderer2D supports negative chunk coordinates without counting offscreen chunks" {
    var backend = try rhi.Rhi.init(extent);
    defer backend.deinit();
    var renderer = try renderer2d.Renderer2D.init(&backend);
    defer renderer.deinit(&backend);
    const texture = try makeTexture(&backend, &renderer);
    defer backend.destroyTexture(texture);
    const sources = [_]renderer2d.TileSourceView{.{
        .texture = texture,
        .tile_size = .{ 16, 16 },
        .image_size = .{ 16, 16 },
        .columns = 1,
        .rows = 1,
        .margin = 0,
        .spacing = 0,
    }};
    const cells = [_]renderer2d.ChunkedTileCellView{.{ .local_index = 1023, .tile_source_index = 0, .local_tile_id = 0 }};
    const chunks = [_]renderer2d.TilemapChunkView{.{ .coordinate = .{ -1, -1 }, .cells = &cells }};
    const layers = [_]renderer2d.ChunkedTilemapLayerView{.{
        .origin = .{ 0, 0 },
        .offset = .{ 0, 0 },
        .grid_size = .{ 16, 16 },
        .tile_sources = &sources,
        .chunks = &chunks,
    }};
    const before = backend.stats();
    try std.testing.expectEqual(.presented, try renderer.renderFrame(&backend, extent, .{
        .view = .{ .origin = .{ -16, -16 }, .zoom = 1 },
        .chunked_tilemap_layers = &layers,
    }));
    try expectRecordingDelta(before, backend.stats(), 1, 1, 1, 1, 1);
    try std.testing.expectApproxEqAbs(@as(f32, -16), traceF32(&backend.stats().instance_data_trace, 0), 0.0001);
}

test "Renderer2D rejects malformed tilemap before beginning a frame" {
    var backend = try rhi.Rhi.init(extent);
    defer backend.deinit();
    var renderer = try renderer2d.Renderer2D.init(&backend);
    defer renderer.deinit(&backend);
    const texture = try makeTexture(&backend, &renderer);
    defer backend.destroyTexture(texture);

    const cells = [_]u16{1};
    const tilemaps = [_]renderer2d.TilemapLayerView{.{
        .origin = .{ 0, 0 },
        .tile_size = .{ 8, 8 },
        .columns = 2,
        .rows = 2,
        .atlas_columns = 1,
        .atlas_rows = 1,
        .texture = texture,
        .cells = &cells,
    }};
    const before = backend.stats();
    try std.testing.expectError(error.InvalidTilemapCellCount, renderer.renderFrame(&backend, extent, .{ .tilemaps = &tilemaps }));
    try expectNoRecordingDelta(before, backend.stats());
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
    try expectRecordingDelta(before, after, 1, 1, 1, 1, 3);
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
    try expectRecordingDelta(before, after, 1, 2, 2, 2, 3);
    // Null trace 按 draw 记录实际纹理，用它证明批处理没有改变输入顺序。
    try std.testing.expectEqualSlices(
        rhi.TextureHandle,
        &.{ secondary, primary },
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
    try expectRecordingDelta(before, after, 1, 3, 3, 3, 5);
    try std.testing.expectEqualSlices(
        rhi.TextureHandle,
        &.{ primary, secondary, primary },
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

test "Renderer2D rejects a stale texture before beginFrame and can present the next frame" {
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
    try expectNoRecordingDelta(before, after_failure);
    try std.testing.expectEqual(before.failed_frames_consumed, after_failure.failed_frames_consumed);
    try std.testing.expectEqual(before.frames_finished, after_failure.frames_finished);

    // 帧前拒绝不能留下 active token；替换为有效 handle 后下一帧必须可正常提交。
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
    // 完整预检发生在 beginFrame 前，不产生录制状态，也无需消费失败帧。
    try expectNoRecordingDelta(before, after_failure);
    try std.testing.expectEqual(before.failed_frames_consumed, after_failure.failed_frames_consumed);

    const replacement = try makeTexture(&backend, &renderer);
    defer backend.destroyTexture(replacement);
    const valid_sprites = [_]renderer2d.SpriteInstance{sprite(4, 4, replacement)};
    try std.testing.expectEqual(.presented, try renderer.renderSprites(&backend, extent, &valid_sprites));
    try std.testing.expectEqual(@as(u32, 1), backend.stats().frames_finished - after_failure.frames_finished);
}

test "Renderer2D rejects more than one bounded instance frame before recording" {
    var backend = try rhi.Rhi.init(extent);
    defer backend.deinit();
    var renderer = try renderer2d.Renderer2D.init(&backend);
    defer renderer.deinit(&backend);
    const texture = try makeTexture(&backend, &renderer);
    defer backend.destroyTexture(texture);

    var sprites: [129]renderer2d.SpriteInstance = undefined;
    for (&sprites, 0..) |*item, index| {
        item.* = sprite(@floatFromInt(index), 4, texture);
    }
    const before = backend.stats();
    try std.testing.expectError(error.SpriteLimitExceeded, renderer.renderSprites(&backend, extent, &sprites));
    try expectNoRecordingDelta(before, backend.stats());

    // 预检必须发生在 beginFrame 前；拒绝后下一帧仍可正常提交。
    try std.testing.expectEqual(.presented, try renderer.renderSprites(&backend, extent, sprites[0..1]));
}
