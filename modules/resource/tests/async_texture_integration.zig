const std = @import("std");
const resource = @import("resource");

pub const resource_async_integration = true;

const valid_kdat_v1 = [_]u8{
    'K', 'D', 'A', 'T', 1,   0, 0,  0,
    2,   0,   0,   0,   1,   0, 0,  0,
    8,   0,   0,   0,   255, 0, 16, 255,
    0,   128, 255, 255,
};

const valid_kdat_v1_secondary = [_]u8{
    'K', 'D', 'A', 'T', 1, 0, 0, 0,
    1,   0,   0,   0,   1, 0, 0, 0,
    4,   0,   0,   0,   9, 8, 7, 255,
};

fn loadDeterministically(path: []const u8) !resource.AsyncTextureResult {
    var loader = resource.AsyncTextureLoader.init(std.testing.allocator);
    defer loader.deinit();
    try loader.request(path);
    // close/join 是确定性同步原语；测试不使用 sleep 或轮询超时猜测。
    loader.close();
    return loader.poll() orelse error.MissingAsyncTextureResult;
}

fn expectFailure(
    result: resource.AsyncTextureResult,
    stage: resource.AsyncTextureFailureStage,
    reason: resource.AsyncTextureFailureReason,
) !void {
    switch (result) {
        .failed => |failure| {
            try std.testing.expectEqual(stage, failure.stage);
            try std.testing.expectEqual(reason, failure.reason);
        },
        .loaded => |loaded| {
            var unexpected = loaded;
            unexpected.deinit(std.testing.allocator);
            return error.ExpectedAsyncTextureFailure;
        },
    }
}

test "Resource async interface loads valid artifact and transfers TextureData ownership" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "valid.texture", .data = &valid_kdat_v1 });
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPathFile(std.testing.io, "valid.texture", &path_buffer);

    const result = try loadDeterministically(path_buffer[0..path_len]);
    switch (result) {
        .loaded => |loaded| {
            var texture = loaded;
            defer texture.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(u32, 2), texture.width);
            try std.testing.expectEqual(@as(u32, 1), texture.height);
            try std.testing.expectEqualSlices(u8, &.{ 255, 0, 16, 255, 0, 128, 255, 255 }, texture.pixels_rgba8);
        },
        .failed => |failure| {
            std.debug.print("unexpected async texture failure: {s}/{s}\n", .{ @tagName(failure.stage), @tagName(failure.reason) });
            return error.ExpectedLoadedTexture;
        },
    }
}

test "Resource async interface reports missing exact-limit and malformed inputs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "missing.texture", .data = "placeholder" });
    var missing_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const missing_len = try tmp.dir.realPathFile(std.testing.io, "missing.texture", &missing_buffer);
    try tmp.dir.deleteFile(std.testing.io, "missing.texture");
    try expectFailure(
        try loadDeterministically(missing_buffer[0..missing_len]),
        .read,
        .not_found,
    );

    const exact_limit = try std.testing.allocator.alloc(u8, 8 * 1024 * 1024);
    defer std.testing.allocator.free(exact_limit);
    @memset(exact_limit, 0);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "exact-limit.texture", .data = exact_limit });
    var limit_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const limit_len = try tmp.dir.realPathFile(std.testing.io, "exact-limit.texture", &limit_buffer);
    try expectFailure(
        try loadDeterministically(limit_buffer[0..limit_len]),
        .read,
        .too_large,
    );

    const malformed = [_]u8{ 'K', 'D', 'A', 'T', 1, 0, 0, 0 };
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "malformed.texture", .data = &malformed });
    var malformed_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const malformed_len = try tmp.dir.realPathFile(std.testing.io, "malformed.texture", &malformed_buffer);
    try expectFailure(
        try loadDeterministically(malformed_buffer[0..malformed_len]),
        .decode,
        .invalid_artifact,
    );
}

test "Resource async interface rejects a second request and frees unconsumed completion" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "unconsumed.texture", .data = &valid_kdat_v1 });
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPathFile(std.testing.io, "unconsumed.texture", &path_buffer);
    const path = path_buffer[0..path_len];

    var loader = resource.AsyncTextureLoader.init(std.testing.allocator);
    try loader.request(path);
    try std.testing.expectError(error.RequestAlreadyIssued, loader.request(path));
    // 不 poll：deinit 必须 join、decode，并释放尚未转移的 TextureData/raw completion。
    loader.deinit();
}

test "failed async refresh preserves caller current texture state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const malformed = [_]u8{ 'K', 'D', 'A', 'T', 1, 0, 0, 0 };
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "failed-refresh.texture", .data = &malformed });
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPathFile(std.testing.io, "failed-refresh.texture", &path_buffer);

    var current_texture_generation: u32 = 7;
    const result = try loadDeterministically(path_buffer[0..path_len]);
    switch (result) {
        .loaded => |loaded| {
            var texture = loaded;
            texture.deinit(std.testing.allocator);
            current_texture_generation += 1;
        },
        .failed => {},
    }
    try std.testing.expectEqual(@as(u32, 7), current_texture_generation);
}

test "two Resource loaders preserve fixed ordinal ownership" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "primary.texture", .data = &valid_kdat_v1 });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "secondary.texture", .data = &valid_kdat_v1_secondary });
    var primary_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const primary_len = try tmp.dir.realPathFile(std.testing.io, "primary.texture", &primary_buffer);
    var secondary_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const secondary_len = try tmp.dir.realPathFile(std.testing.io, "secondary.texture", &secondary_buffer);

    var loaders = [_]resource.AsyncTextureLoader{
        resource.AsyncTextureLoader.init(std.testing.allocator),
        resource.AsyncTextureLoader.init(std.testing.allocator),
    };
    defer for (&loaders) |*loader| loader.deinit();
    try loaders[0].request(primary_buffer[0..primary_len]);
    try loaders[1].request(secondary_buffer[0..secondary_len]);
    loaders[1].close();
    loaders[0].close();

    const secondary_result = loaders[1].poll() orelse return error.MissingAsyncTextureResult;
    const primary_result = loaders[0].poll() orelse return error.MissingAsyncTextureResult;
    switch (primary_result) {
        .loaded => |loaded| {
            var texture = loaded;
            defer texture.deinit(std.testing.allocator);
            try std.testing.expectEqualSlices(u8, &.{ 255, 0, 16, 255, 0, 128, 255, 255 }, texture.pixels_rgba8);
        },
        .failed => return error.ExpectedLoadedTexture,
    }
    switch (secondary_result) {
        .loaded => |loaded| {
            var texture = loaded;
            defer texture.deinit(std.testing.allocator);
            try std.testing.expectEqualSlices(u8, &.{ 9, 8, 7, 255 }, texture.pixels_rgba8);
        },
        .failed => return error.ExpectedLoadedTexture,
    }
}

test "two Resource loaders release successful data when the peer fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "primary.texture", .data = &valid_kdat_v1 });
    const malformed = [_]u8{ 'K', 'D', 'A', 'T', 1, 0, 0, 0 };
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "malformed.texture", .data = &malformed });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "missing.texture", .data = "placeholder" });
    var primary_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const primary_len = try tmp.dir.realPathFile(std.testing.io, "primary.texture", &primary_buffer);
    var malformed_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const malformed_len = try tmp.dir.realPathFile(std.testing.io, "malformed.texture", &malformed_buffer);
    var missing_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const missing_len = try tmp.dir.realPathFile(std.testing.io, "missing.texture", &missing_buffer);
    try tmp.dir.deleteFile(std.testing.io, "missing.texture");

    const peer_paths = [_][]const u8{ missing_buffer[0..missing_len], malformed_buffer[0..malformed_len] };
    const expected_reasons = [_]resource.AsyncTextureFailureReason{ .not_found, .invalid_artifact };
    const expected_stages = [_]resource.AsyncTextureFailureStage{ .read, .decode };
    for (peer_paths, expected_stages, expected_reasons) |peer_path, expected_stage, expected_reason| {
        var primary_loader = resource.AsyncTextureLoader.init(std.testing.allocator);
        defer primary_loader.deinit();
        var peer_loader = resource.AsyncTextureLoader.init(std.testing.allocator);
        defer peer_loader.deinit();
        try primary_loader.request(primary_buffer[0..primary_len]);
        try peer_loader.request(peer_path);
        primary_loader.close();
        peer_loader.close();

        const primary_result = primary_loader.poll() orelse return error.MissingAsyncTextureResult;
        switch (primary_result) {
            .loaded => |loaded| {
                var texture = loaded;
                texture.deinit(std.testing.allocator);
            },
            .failed => return error.ExpectedLoadedTexture,
        }
        try expectFailure(peer_loader.poll() orelse return error.MissingAsyncTextureResult, expected_stage, expected_reason);
    }
}

test "two unpolled Resource loaders release all completions on deinit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "primary.texture", .data = &valid_kdat_v1 });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "secondary.texture", .data = &valid_kdat_v1_secondary });
    var primary_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const primary_len = try tmp.dir.realPathFile(std.testing.io, "primary.texture", &primary_buffer);
    var secondary_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const secondary_len = try tmp.dir.realPathFile(std.testing.io, "secondary.texture", &secondary_buffer);

    var primary_loader = resource.AsyncTextureLoader.init(std.testing.allocator);
    try primary_loader.request(primary_buffer[0..primary_len]);
    var secondary_loader = resource.AsyncTextureLoader.init(std.testing.allocator);
    try secondary_loader.request(secondary_buffer[0..secondary_len]);
    primary_loader.deinit();
    secondary_loader.deinit();
}
