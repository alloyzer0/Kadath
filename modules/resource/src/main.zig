const std = @import("std");
const texture_decode = @import("texture_decode.zig");

pub const TextureMipLevel = texture_decode.TextureMipLevel;
pub const TextureData = texture_decode.TextureData;
const texture_artifact_max_bytes = texture_decode.texture_artifact_max_bytes;

const DirectoryArtifactSource = struct {
    io: std.Io,
    dir: std.Io.Dir,

    fn readAlloc(
        self: DirectoryArtifactSource,
        allocator: std.mem.Allocator,
        key: []const u8,
        limit: std.Io.Limit,
    ) ![]u8 {
        return self.dir.readFileAlloc(self.io, key, allocator, limit);
    }
};

const MemoryArtifactSource = struct {
    const Entry = struct {
        key: []const u8,
        bytes: []const u8,
    };

    entries: []const Entry,

    fn readAlloc(
        self: MemoryArtifactSource,
        allocator: std.mem.Allocator,
        key: []const u8,
        limit: std.Io.Limit,
    ) ![]u8 {
        for (self.entries) |entry| {
            if (!std.mem.eql(u8, entry.key, key)) continue;
            // 与 std.Io.Dir.readFileAlloc 对齐：长度达到 limit 也必须拒绝，而不只是超过时拒绝。
            if (limit.toInt()) |maximum| {
                if (entry.bytes.len >= maximum) return error.StreamTooLong;
            }
            return allocator.dupe(u8, entry.bytes);
        }
        return error.FileNotFound;
    }
};

/// Runtime 读取 KDAT Texture Artifact v1/v2；v2 会校验完整 mip payload，再返回 base level。
pub fn loadTextureArtifact(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !TextureData {
    const source = DirectoryArtifactSource{ .io = io, .dir = std.Io.Dir.cwd() };
    return loadTextureFromSource(source, allocator, path);
}

fn loadTextureFromSource(source: anytype, allocator: std.mem.Allocator, key: []const u8) !TextureData {
    const artifact_bytes = try source.readAlloc(allocator, key, .limited(texture_artifact_max_bytes));
    // Source 只负责交付 owned bytes；Resource 在同步 decode 完成后统一释放，不能把其生命周期泄漏给 TextureData。
    defer allocator.free(artifact_bytes);
    return texture_decode.decodeTextureArtifact(allocator, artifact_bytes);
}

pub fn loadPpm3(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !TextureData {
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(source);
    return parsePpm3(allocator, source);
}

fn parsePpm3(allocator: std.mem.Allocator, source: []const u8) !TextureData {
    var tokens = std.mem.tokenizeAny(u8, source, " \t\r\n");
    const magic = tokens.next() orelse return error.InvalidPpmHeader;
    if (!std.mem.eql(u8, magic, "P3")) return error.UnsupportedTextureFormat;

    const width = try parsePositive(tokens.next() orelse return error.InvalidPpmHeader);
    const height = try parsePositive(tokens.next() orelse return error.InvalidPpmHeader);
    const max_value = try parsePositive(tokens.next() orelse return error.InvalidPpmHeader);
    if (max_value > 255) return error.UnsupportedPpmRange;

    const pixel_count = try std.math.mul(usize, @intCast(width), @intCast(height));
    const channel_count = try std.math.mul(usize, pixel_count, 4);
    const pixels = try allocator.alloc(u8, channel_count);
    errdefer allocator.free(pixels);

    for (0..pixel_count) |pixel_index| {
        const r = try parseSample(tokens.next() orelse return error.UnexpectedEndOfPixels, max_value);
        const g = try parseSample(tokens.next() orelse return error.UnexpectedEndOfPixels, max_value);
        const b = try parseSample(tokens.next() orelse return error.UnexpectedEndOfPixels, max_value);
        const offset = pixel_index * 4;
        pixels[offset + 0] = r;
        pixels[offset + 1] = g;
        pixels[offset + 2] = b;
        pixels[offset + 3] = 255;
    }

    return .{
        .width = width,
        .height = height,
        .pixels_rgba8 = pixels,
    };
}

fn parsePositive(token: []const u8) !u32 {
    const value = try std.fmt.parseInt(u32, token, 10);
    if (value == 0) return error.InvalidPpmDimension;
    return value;
}

fn parseSample(token: []const u8, max_value: u32) !u8 {
    const value = try std.fmt.parseInt(u32, token, 10);
    if (value > max_value) return error.PpmSampleOutOfRange;
    return @intCast((value * 255) / max_value);
}

const test_kdat_v1 = [_]u8{
    'K', 'D', 'A', 'T', 1,   0, 0,  0,
    2,   0,   0,   0,   1,   0, 0,  0,
    8,   0,   0,   0,   255, 0, 16, 255,
    0,   128, 255, 255,
};

const test_kdat_v2 = [_]u8{
    'K', 'D', 'A', 'T', 2,   0,   0,  0,
    2,   0,   0,   0,   2,   0,   0,  0,
    2,   0,   0,   0,   20,  0,   0,  0,
    255, 40,  40,  255, 40,  255, 40, 255,
    40,  40,  255, 255, 255, 230, 40, 255,
    147, 141, 93,  255,
};

fn expectV1Texture(texture: *const TextureData) !void {
    try std.testing.expectEqual(@as(u32, 2), texture.width);
    try std.testing.expectEqual(@as(u32, 1), texture.height);
    try std.testing.expectEqual(@as(u32, 1), texture.mip_level_count);
    try std.testing.expectEqual(@as(usize, 0), texture.mip_levels.len);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 16, 255, 0, 128, 255, 255 }, texture.pixels_rgba8);
}

fn expectV2Texture(texture: *const TextureData) !void {
    try std.testing.expectEqual(@as(u32, 2), texture.width);
    try std.testing.expectEqual(@as(u32, 2), texture.height);
    try std.testing.expectEqual(@as(u32, 2), texture.mip_level_count);
    try std.testing.expectEqual(@as(usize, 1), texture.mip_levels.len);
    try std.testing.expectEqual(@as(u32, 1), texture.mip_levels[0].width);
    try std.testing.expectEqual(@as(u32, 1), texture.mip_levels[0].height);
    try std.testing.expectEqualSlices(u8, &.{ 147, 141, 93, 255 }, texture.mip_levels[0].pixels_rgba8);
    try std.testing.expectEqualSlices(u8, &.{ 255, 40, 40, 255, 40, 255, 40, 255, 40, 40, 255, 255, 255, 230, 40, 255 }, texture.pixels_rgba8);
}

test "parse KDAT texture artifact v1 into RGBA8" {
    var texture = try texture_decode.decodeTextureArtifact(std.testing.allocator, &test_kdat_v1);
    defer texture.deinit(std.testing.allocator);
    try expectV1Texture(&texture);
}

test "parse KDAT texture artifact v2 mip chain and return base RGBA8" {
    var texture = try texture_decode.decodeTextureArtifact(std.testing.allocator, &test_kdat_v2);
    defer texture.deinit(std.testing.allocator);
    try expectV2Texture(&texture);
}

fn expectSourceLimitContract(source: anytype) !void {
    const allocator = std.testing.allocator;
    const short = try source.readAlloc(allocator, "short", .limited(4));
    defer allocator.free(short);
    try std.testing.expectEqualStrings("abc", short);
    try std.testing.expectError(error.StreamTooLong, source.readAlloc(allocator, "equal", .limited(4)));
    try std.testing.expectError(error.StreamTooLong, source.readAlloc(allocator, "long", .limited(4)));
    try std.testing.expectError(error.FileNotFound, source.readAlloc(allocator, "missing", .limited(4)));
}

test "directory and memory artifact sources share strict limit semantics" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "short", .data = "abc" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "equal", .data = "abcd" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "long", .data = "abcde" });

    const directory = DirectoryArtifactSource{ .io = std.testing.io, .dir = tmp.dir };
    try expectSourceLimitContract(directory);

    const entries = [_]MemoryArtifactSource.Entry{
        .{ .key = "short", .bytes = "abc" },
        .{ .key = "equal", .bytes = "abcd" },
        .{ .key = "long", .bytes = "abcde" },
    };
    try expectSourceLimitContract(MemoryArtifactSource{ .entries = &entries });
}

fn expectSourceLoadsV2(source: anytype, key: []const u8) !void {
    var texture = try loadTextureFromSource(source, std.testing.allocator, key);
    defer texture.deinit(std.testing.allocator);
    try expectV2Texture(&texture);
}

test "directory and memory sources decode through the same resource seam" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "valid.texture", .data = &test_kdat_v2 });
    try expectSourceLoadsV2(
        DirectoryArtifactSource{ .io = std.testing.io, .dir = tmp.dir },
        "valid.texture",
    );

    const entries = [_]MemoryArtifactSource.Entry{
        .{ .key = "valid.texture", .bytes = &test_kdat_v2 },
    };
    try expectSourceLoadsV2(MemoryArtifactSource{ .entries = &entries }, "valid.texture");
}

test "public texture loader keeps the cwd directory production path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "public.texture", .data = &test_kdat_v1 });

    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.Io.Dir.cwd().realPath(std.testing.io, &cwd_buffer);
    const cwd_path = cwd_buffer[0..cwd_len];
    var fixture_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const fixture_len = try tmp.dir.realPathFile(std.testing.io, "public.texture", &fixture_buffer);
    const fixture_path = fixture_buffer[0..fixture_len];
    // 只通过公开路径 API 计算 cwd-relative key，测试不依赖 tmpDir 的缓存布局，也不修改全局 cwd。
    const relative_path = try std.fs.path.relative(std.testing.allocator, cwd_path, null, cwd_path, fixture_path);
    defer std.testing.allocator.free(relative_path);

    var texture = try loadTextureArtifact(std.testing.io, std.testing.allocator, relative_path);
    defer texture.deinit(std.testing.allocator);
    try expectV1Texture(&texture);
}

fn expectMemoryLoadError(expected_error: anyerror, bytes: []const u8) !void {
    const entries = [_]MemoryArtifactSource.Entry{
        .{ .key = "invalid.texture", .bytes = bytes },
    };
    try std.testing.expectError(
        expected_error,
        loadTextureFromSource(MemoryArtifactSource{ .entries = &entries }, std.testing.allocator, "invalid.texture"),
    );
}

test "resource seam rejects malformed KDAT without partial results" {
    const exact_limit = try std.testing.allocator.alloc(u8, texture_artifact_max_bytes);
    defer std.testing.allocator.free(exact_limit);
    try std.testing.expectError(error.InvalidTextureArtifact, texture_decode.decodeTextureArtifact(std.testing.allocator, exact_limit));

    try expectMemoryLoadError(error.InvalidTextureArtifact, test_kdat_v2[0..7]);
    try expectMemoryLoadError(error.InvalidTextureArtifact, test_kdat_v2[0 .. test_kdat_v2.len - 1]);

    var unsupported = test_kdat_v2;
    unsupported[4] = 3;
    try expectMemoryLoadError(error.UnsupportedTextureArtifactVersion, &unsupported);

    var wrong_mip_count = test_kdat_v2;
    wrong_mip_count[16] = 1;
    try expectMemoryLoadError(error.InvalidTextureArtifact, &wrong_mip_count);

    var wrong_payload_bytes = test_kdat_v2;
    wrong_payload_bytes[20] = 19;
    try expectMemoryLoadError(error.InvalidTextureArtifact, &wrong_payload_bytes);
}

fn loadV2WithAllocator(allocator: std.mem.Allocator, bytes: []const u8) !void {
    const entries = [_]MemoryArtifactSource.Entry{
        .{ .key = "allocation.texture", .bytes = bytes },
    };
    var texture = try loadTextureFromSource(MemoryArtifactSource{ .entries = &entries }, allocator, "allocation.texture");
    defer texture.deinit(allocator);
    try expectV2Texture(&texture);
}

test "artifact source and mip decode roll back every allocation failure" {
    // 从 Memory source 的 owned-byte 复制到最后一个 mip，逐一验证失败时没有泄漏或半成品。
    try std.testing.checkAllAllocationFailures(std.testing.allocator, loadV2WithAllocator, .{test_kdat_v2[0..]});
}

test "parse PPM P3 into RGBA8" {
    const source = "P3\n2 1\n255\n255 0 16  0 128 255\n";
    var texture = try parsePpm3(std.testing.allocator, source);
    defer texture.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 2), texture.width);
    try std.testing.expectEqual(@as(u32, 1), texture.height);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 16, 255, 0, 128, 255, 255 }, texture.pixels_rgba8);
}
