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
pub const texture_artifact_max_bytes: usize = 8 * 1024 * 1024;
const texture_artifact_max_mip_levels: u32 = 32;

fn readLittleU32(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
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

pub fn decodeTextureArtifact(allocator: std.mem.Allocator, source: []const u8) !TextureData {
    // 私有 decode 只借用 raw bytes；成功的 TextureData 使用调用方 allocator 独立分配。
    if (source.len < 8 or source.len >= texture_artifact_max_bytes) return error.InvalidTextureArtifact;
    if (!std.mem.eql(u8, source[0..4], "KDAT")) return error.InvalidTextureArtifact;
    return switch (readLittleU32(source[4..8])) {
        1 => parseTextureArtifactV1(allocator, source),
        2 => parseTextureArtifactV2(allocator, source),
        else => error.UnsupportedTextureArtifactVersion,
    };
}
