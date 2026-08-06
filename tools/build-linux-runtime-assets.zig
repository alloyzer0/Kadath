const std = @import("std");
const builtin = @import("builtin");
const support = @import("package_support");
const scene_api = support.scene;
const script_api = support.script;

const c = @cImport({
    @cInclude("png.h");
});

comptime {
    if (builtin.os.tag != .linux) @compileError("build-linux-runtime-assets is Linux-only");
}

const primary_png = support.primary_png;
const secondary_png = support.secondary_png;
const won_wav = support.won_wav;
const lost_wav = support.lost_wav;
const scene_json = support.scene_json;
const script_json = support.script_json;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 7) return error.InvalidArguments;

    const primary = try buildTextureArtifact(init.gpa, primary_png);
    defer init.gpa.free(primary);
    const secondary = try buildTextureArtifact(init.gpa, secondary_png);
    defer init.gpa.free(secondary);
    try validateCanonicalWav(won_wav);
    try validateCanonicalWav(lost_wav);
    const scene = try buildSceneArtifact(init.gpa, scene_json);
    defer init.gpa.free(scene);
    const script = try buildScriptArtifact(init.gpa, script_json);
    defer init.gpa.free(script);

    try writeNew(init.io, args[1], primary);
    try writeNew(init.io, args[2], secondary);
    try writeNew(init.io, args[3], won_wav);
    try writeNew(init.io, args[4], lost_wav);
    try writeNew(init.io, args[5], scene);
    try writeNew(init.io, args[6], script);
}

fn writeNew(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

fn buildTextureArtifact(allocator: std.mem.Allocator, png_bytes: []const u8) ![]u8 {
    var image: c.png_image = std.mem.zeroes(c.png_image);
    image.version = c.PNG_IMAGE_VERSION;
    if (c.png_image_begin_read_from_memory(&image, png_bytes.ptr, png_bytes.len) == 0) {
        return error.InvalidPng;
    }
    defer c.png_image_free(&image);
    if (image.width == 0 or image.height == 0) return error.InvalidPngDimensions;
    const pixel_count = try std.math.mul(usize, image.width, image.height);
    if (pixel_count > 1024 * 1024) return error.TexturePixelBudgetExceeded;
    image.format = c.PNG_FORMAT_RGBA;
    const base_bytes = try std.math.mul(usize, pixel_count, 4);
    var current = try allocator.alloc(u8, base_bytes);
    defer allocator.free(current);
    if (c.png_image_finish_read(&image, null, current.ptr, 0, null) == 0) return error.InvalidPng;

    var width: u32 = image.width;
    var height: u32 = image.height;
    var level_count: u32 = 0;
    var pixel_bytes: usize = 0;
    while (true) {
        level_count += 1;
        pixel_bytes = try std.math.add(usize, pixel_bytes, try levelBytes(width, height));
        if (width == 1 and height == 1) break;
        width = nextMipDimension(width);
        height = nextMipDimension(height);
    }
    if (24 + pixel_bytes >= 8 * 1024 * 1024) return error.TextureArtifactBudgetExceeded;

    const artifact = try allocator.alloc(u8, 24 + pixel_bytes);
    errdefer allocator.free(artifact);
    @memcpy(artifact[0..4], "KDAT");
    putU32(artifact[4..8], 2);
    putU32(artifact[8..12], image.width);
    putU32(artifact[12..16], image.height);
    putU32(artifact[16..20], level_count);
    putU32(artifact[20..24], @intCast(pixel_bytes));

    width = image.width;
    height = image.height;
    var offset: usize = 24;
    while (true) {
        @memcpy(artifact[offset .. offset + current.len], current);
        offset += current.len;
        if (width == 1 and height == 1) break;
        const next_width = nextMipDimension(width);
        const next_height = nextMipDimension(height);
        const next = try downsample(allocator, current, width, height, next_width, next_height);
        allocator.free(current);
        current = next;
        width = next_width;
        height = next_height;
    }
    return artifact;
}

fn downsample(
    allocator: std.mem.Allocator,
    source: []const u8,
    width: u32,
    height: u32,
    next_width: u32,
    next_height: u32,
) ![]u8 {
    const output = try allocator.alloc(u8, try levelBytes(next_width, next_height));
    for (0..next_height) |next_y| {
        for (0..next_width) |next_x| {
            var sums = [_]u16{ 0, 0, 0, 0 };
            for (0..2) |dy| {
                const sample_y = @min(height - 1, @as(u32, @intCast(next_y * 2 + dy)));
                for (0..2) |dx| {
                    const sample_x = @min(width - 1, @as(u32, @intCast(next_x * 2 + dx)));
                    const source_offset = (@as(usize, sample_y) * width + sample_x) * 4;
                    for (0..4) |channel| sums[channel] += source[source_offset + channel];
                }
            }
            const output_offset = (next_y * next_width + next_x) * 4;
            for (0..4) |channel| output[output_offset + channel] = @intCast(sums[channel] / 4);
        }
    }
    return output;
}

fn buildSceneArtifact(allocator: std.mem.Allocator, json: []const u8) ![]u8 {
    const scene = try scene_api.parse(allocator, json);
    return scene_api.encodeArtifact(allocator, &scene);
}

fn buildScriptArtifact(allocator: std.mem.Allocator, json: []const u8) ![]u8 {
    const program = try script_api.parse(allocator, json);
    const artifact = try allocator.alloc(u8, 16 + program.count * 16);
    @memcpy(artifact[0..4], "KSCP");
    putU32(artifact[4..8], script_api.script_artifact_version);
    putU32(artifact[8..12], script_api.current_schema_version);
    putU32(artifact[12..16], @intCast(program.count));
    for (program.instructions[0..program.count], 0..) |instruction, index| {
        const offset = 16 + index * 16;
        putU32(artifact[offset..][0..4], @intFromEnum(instruction.hook));
        putU32(artifact[offset + 4 ..][0..4], @intFromEnum(instruction.op));
        putF32(artifact[offset + 8 ..][0..4], instruction.value[0]);
        putF32(artifact[offset + 12 ..][0..4], instruction.value[1]);
    }
    return artifact;
}

fn validateCanonicalWav(bytes: []const u8) !void {
    if (bytes.len < 44 or !std.mem.eql(u8, bytes[0..4], "RIFF") or !std.mem.eql(u8, bytes[8..12], "WAVE")) {
        return error.InvalidCanonicalWav;
    }
    if (readU32(bytes[4..8]) + 8 != bytes.len or !std.mem.eql(u8, bytes[12..16], "fmt ") or readU32(bytes[16..20]) != 16) {
        return error.InvalidCanonicalWav;
    }
    const channels = readU16(bytes[22..24]);
    const sample_rate = readU32(bytes[24..28]);
    const byte_rate = readU32(bytes[28..32]);
    const block_align = readU16(bytes[32..34]);
    const bits_per_sample = readU16(bytes[34..36]);
    if (readU16(bytes[20..22]) != 1 or channels == 0 or channels > 2 or sample_rate == 0 or bits_per_sample != 16) {
        return error.InvalidCanonicalWav;
    }
    if (block_align != channels * 2 or byte_rate != sample_rate * block_align) return error.InvalidCanonicalWav;
    if (!std.mem.eql(u8, bytes[36..40], "data") or readU32(bytes[40..44]) + 44 != bytes.len) return error.InvalidCanonicalWav;
}

fn levelBytes(width: u32, height: u32) !usize {
    return try std.math.mul(usize, try std.math.mul(usize, width, height), 4);
}

fn nextMipDimension(value: u32) u32 {
    return @max(1, value / 2);
}

fn putU32(bytes: []u8, value: u32) void {
    bytes[0] = @truncate(value);
    bytes[1] = @truncate(value >> 8);
    bytes[2] = @truncate(value >> 16);
    bytes[3] = @truncate(value >> 24);
}

fn putF32(bytes: []u8, value: f32) void {
    putU32(bytes, @bitCast(value));
}

fn readU16(bytes: []const u8) u16 {
    return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
}

fn readU32(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) | (@as(u32, bytes[1]) << 8) | (@as(u32, bytes[2]) << 16) | (@as(u32, bytes[3]) << 24);
}

test "release mip generation preserves PNG RGBA and box-filter rules" {
    const primary = try buildTextureArtifact(std.testing.allocator, primary_png);
    defer std.testing.allocator.free(primary);
    const secondary = try buildTextureArtifact(std.testing.allocator, secondary_png);
    defer std.testing.allocator.free(secondary);
    const expected_primary = [_]u8{
        'K', 'D', 'A', 'T', 2, 0,   0, 0,  2, 0, 0,   0,   2,   0,   0,   0,   2,   0,   0,   0,   20, 0, 0, 0,
        255, 0,   0,   0,   0, 255, 0, 64, 0, 0, 255, 128, 255, 255, 255, 255, 127, 127, 127, 111,
    };
    const expected_secondary = [_]u8{
        'K', 'D', 'A', 'T', 2, 0,   0,   0,   2, 0, 0, 0,   2,   0,   0,   0,   2,   0,   0,   0,   20, 0, 0, 0,
        255, 0,   255, 255, 0, 255, 255, 255, 0, 0, 0, 255, 255, 255, 255, 255, 127, 127, 191, 255,
    };
    try std.testing.expectEqualSlices(u8, &expected_primary, primary);
    try std.testing.expectEqualSlices(u8, &expected_secondary, secondary);
}

test "scene and script artifacts preserve their frozen disk ABI" {
    const scene = try buildSceneArtifact(std.testing.allocator, scene_json);
    defer std.testing.allocator.free(scene);
    const script = try buildScriptArtifact(std.testing.allocator, script_json);
    defer std.testing.allocator.free(script);
    try std.testing.expectEqual(scene_api.scene_artifact_version, readU32(scene[4..8]));
    try std.testing.expectEqual(scene_api.current_schema_version, readU32(scene[8..12]));
    try std.testing.expectEqual(@as(u32, 3), readU32(scene[16..20]));
    var cursor: usize = 20;
    for (0..3) |_| {
        const artifact_bytes = readU32(scene[cursor + 4 ..][0..4]);
        cursor += 8 + artifact_bytes;
    }
    try std.testing.expectEqual(@as(u32, 5), readU32(scene[cursor..][0..4]));
    cursor += 4;
    const first_entry_bytes = readU32(scene[cursor..][0..4]);
    try std.testing.expectEqual(@as(u32, 1), readU32(scene[cursor + 4 ..][0..4]));
    try std.testing.expectEqual(@as(u32, "decoration-1".len), readU32(scene[cursor + 8 ..][0..4]));
    try std.testing.expectEqual(@as(usize, 44 + "decoration-1".len), first_entry_bytes);
    try std.testing.expectEqual(@as(usize, 48), script.len);
    try std.testing.expectEqualSlices(u8, "KSCN", scene[0..4]);
    try std.testing.expectEqualSlices(u8, "KSCP", script[0..4]);
}

test "shipped audio sources are canonical Runtime artifacts" {
    try validateCanonicalWav(won_wav);
    try validateCanonicalWav(lost_wav);
}
