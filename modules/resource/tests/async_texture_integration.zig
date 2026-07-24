const std = @import("std");
const async_texture = @import("resource_async_texture");

const valid_kdat_v1 = [_]u8{
    'K', 'D', 'A', 'T', 1,   0, 0,  0,
    2,   0,   0,   0,   1,   0, 0,  0,
    8,   0,   0,   0,   255, 0, 16, 255,
    0,   128, 255, 255,
};

fn loadDeterministically(path: []const u8) !async_texture.AsyncTextureResult {
    var loader = async_texture.AsyncTextureLoader.init(std.testing.allocator);
    defer loader.deinit();
    try loader.request(path);
    // close/join 是确定性同步原语；测试不使用 sleep 或轮询超时猜测。
    loader.close();
    return loader.poll() orelse error.MissingAsyncTextureResult;
}

fn expectFailure(
    result: async_texture.AsyncTextureResult,
    stage: async_texture.AsyncTextureFailureStage,
    reason: async_texture.AsyncTextureFailureReason,
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

    var loader = async_texture.AsyncTextureLoader.init(std.testing.allocator);
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
