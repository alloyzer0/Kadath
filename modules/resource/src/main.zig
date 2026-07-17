const std = @import("std");

pub const TextureData = struct {
    width: u32,
    height: u32,
    pixels_rgba8: []u8,

    pub fn deinit(self: *TextureData, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels_rgba8);
        self.* = undefined;
    }
};

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
test "parse PPM P3 into RGBA8" {
    const source = "P3\n2 1\n255\n255 0 16  0 128 255\n";
    var texture = try parsePpm3(std.testing.allocator, source);
    defer texture.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 2), texture.width);
    try std.testing.expectEqual(@as(u32, 1), texture.height);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 16, 255, 0, 128, 255, 255 }, texture.pixels_rgba8);
}
