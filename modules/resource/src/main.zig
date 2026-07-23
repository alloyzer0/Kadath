const std = @import("std");

pub const TextureMipLevel = struct {
    width: u32,
    height: u32,
    pixels_rgba8: []u8,
};

pub const TextureData = struct {
    width: u32,
    height: u32,
    pixels_rgba8: []u8,
    // v2 的附加 levels 由 Resource 拥有，Host 会把它们转交给 RHI upload。
    mip_levels: []TextureMipLevel = &.{},
    mip_level_count: u32 = 1,

    pub fn deinit(self: *TextureData, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels_rgba8);
        for (self.mip_levels) |level| allocator.free(level.pixels_rgba8);
        if (self.mip_levels.len != 0) allocator.free(self.mip_levels);
        self.* = undefined;
    }
};

const texture_artifact_v1_header_bytes: usize = 20;
const texture_artifact_v2_header_bytes: usize = 24;
const texture_artifact_max_bytes: usize = 8 * 1024 * 1024;
const texture_artifact_max_mip_levels: u32 = 32;

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

fn readLittleU32(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}

/// Runtime 读取 KDAT Texture Artifact v1/v2；v2 会校验完整 mip payload，再返回 base level。
pub fn loadTextureArtifact(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !TextureData {
    const source = DirectoryArtifactSource{ .io = io, .dir = std.Io.Dir.cwd() };
    return loadTextureFromSource(source, allocator, path);
}

fn loadTextureFromSource(source: anytype, allocator: std.mem.Allocator, key: []const u8) !TextureData {
    const artifact_bytes = try source.readAlloc(allocator, key, .limited(texture_artifact_max_bytes));
    // Source 只负责交付 owned bytes；Resource 在同步 decode 完成后统一释放，不能把其生命周期泄漏给 TextureData。
    defer allocator.free(artifact_bytes);
    return decodeTextureArtifact(allocator, artifact_bytes);
}

fn levelPixelBytes(width: u32, height: u32) !usize {
    const pixel_count = std.math.mul(usize, @intCast(width), @intCast(height)) catch return error.InvalidTextureArtifact;
    return std.math.mul(usize, pixel_count, 4) catch return error.InvalidTextureArtifact;
}

fn nextMipDimension(value: u32) u32 {
    return if (value > 1) value / 2 else 1;
}

fn expectedMipLevelCount(width: u32, height: u32) u32 {
    var levels: u32 = 1;
    var current_width = width;
    var current_height = height;
    while (current_width > 1 or current_height > 1) {
        current_width = nextMipDimension(current_width);
        current_height = nextMipDimension(current_height);
        levels += 1;
    }
    return levels;
}

fn copyBasePixels(allocator: std.mem.Allocator, source: []const u8, offset: usize, width: u32, height: u32) ![]u8 {
    const base_bytes = try levelPixelBytes(width, height);
    if (offset > source.len or base_bytes > source.len - offset) return error.InvalidTextureArtifact;
    const pixels = try allocator.alloc(u8, base_bytes);
    errdefer allocator.free(pixels);
    @memcpy(pixels, source[offset .. offset + base_bytes]);
    return pixels;
}

fn parseTextureArtifactV1(allocator: std.mem.Allocator, source: []const u8) !TextureData {
    if (source.len < texture_artifact_v1_header_bytes) return error.InvalidTextureArtifact;
    const width = readLittleU32(source[8..12]);
    const height = readLittleU32(source[12..16]);
    const pixel_bytes = readLittleU32(source[16..20]);
    if (width == 0 or height == 0) return error.InvalidTextureArtifact;
    const expected_pixel_bytes = try levelPixelBytes(width, height);
    if (expected_pixel_bytes != pixel_bytes or texture_artifact_v1_header_bytes + expected_pixel_bytes != source.len) {
        return error.InvalidTextureArtifact;
    }
    const pixels = try copyBasePixels(allocator, source, texture_artifact_v1_header_bytes, width, height);
    return .{ .width = width, .height = height, .pixels_rgba8 = pixels, .mip_level_count = 1 };
}

fn parseTextureArtifactV2(allocator: std.mem.Allocator, source: []const u8) !TextureData {
    if (source.len < texture_artifact_v2_header_bytes) return error.InvalidTextureArtifact;
    const width = readLittleU32(source[8..12]);
    const height = readLittleU32(source[12..16]);
    const mip_level_count = readLittleU32(source[16..20]);
    const pixel_bytes = readLittleU32(source[20..24]);
    if (width == 0 or height == 0 or mip_level_count == 0 or mip_level_count > texture_artifact_max_mip_levels) {
        return error.InvalidTextureArtifact;
    }
    if (mip_level_count != expectedMipLevelCount(width, height)) return error.InvalidTextureArtifact;

    var total_bytes: usize = 0;
    var level_width = width;
    var level_height = height;
    var level_index: u32 = 0;
    while (level_index < mip_level_count) : (level_index += 1) {
        const bytes = try levelPixelBytes(level_width, level_height);
        total_bytes = std.math.add(usize, total_bytes, bytes) catch return error.InvalidTextureArtifact;
        level_width = nextMipDimension(level_width);
        level_height = nextMipDimension(level_height);
    }
    if (total_bytes != pixel_bytes or texture_artifact_v2_header_bytes + total_bytes != source.len) {
        return error.InvalidTextureArtifact;
    }
    const pixels = try copyBasePixels(allocator, source, texture_artifact_v2_header_bytes, width, height);
    errdefer allocator.free(pixels);
    const additional_count: usize = @intCast(mip_level_count - 1);
    const mip_levels = try allocator.alloc(TextureMipLevel, additional_count);
    for (mip_levels) |*level| level.* = .{ .width = 0, .height = 0, .pixels_rgba8 = &.{} };
    errdefer {
        for (mip_levels) |level| if (level.pixels_rgba8.len != 0) allocator.free(level.pixels_rgba8);
        allocator.free(mip_levels);
    }
    var copy_width = width;
    var copy_height = height;
    var level_offset = texture_artifact_v2_header_bytes + (try levelPixelBytes(width, height));
    var copy_index: u32 = 1;
    while (copy_index < mip_level_count) : (copy_index += 1) {
        copy_width = nextMipDimension(copy_width);
        copy_height = nextMipDimension(copy_height);
        const level_bytes = try levelPixelBytes(copy_width, copy_height);
        const level_pixels = try copyBasePixels(allocator, source, level_offset, copy_width, copy_height);
        mip_levels[@intCast(copy_index - 1)] = .{ .width = copy_width, .height = copy_height, .pixels_rgba8 = level_pixels };
        level_offset += level_bytes;
    }
    return .{ .width = width, .height = height, .pixels_rgba8 = pixels, .mip_levels = mip_levels, .mip_level_count = mip_level_count };
}

fn decodeTextureArtifact(allocator: std.mem.Allocator, source: []const u8) !TextureData {
    // decode 只借用 artifact bytes；成功返回的 TextureData 拥有独立副本，失败时不得留下部分分配。
    if (source.len < 8 or source.len > texture_artifact_max_bytes) return error.InvalidTextureArtifact;
    if (!std.mem.eql(u8, source[0..4], "KDAT")) return error.InvalidTextureArtifact;
    return switch (readLittleU32(source[4..8])) {
        1 => parseTextureArtifactV1(allocator, source),
        2 => parseTextureArtifactV2(allocator, source),
        else => error.UnsupportedTextureArtifactVersion,
    };
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
    var texture = try decodeTextureArtifact(std.testing.allocator, &test_kdat_v1);
    defer texture.deinit(std.testing.allocator);
    try expectV1Texture(&texture);
}

test "parse KDAT texture artifact v2 mip chain and return base RGBA8" {
    var texture = try decodeTextureArtifact(std.testing.allocator, &test_kdat_v2);
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

    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/public.texture", .{tmp.sub_path});
    var texture = try loadTextureArtifact(std.testing.io, std.testing.allocator, path);
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
