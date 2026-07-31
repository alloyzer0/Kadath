const std = @import("std");
const content_identity = @import("content_identity.zig");

pub const current_schema_version: u32 = 2;
pub const scene_artifact_version: u32 = 2;
const scene_artifact_header_bytes: usize = 16;
const scene_artifact_v1_payload_bytes: usize = 28 * @sizeOf(f32);
const scene_artifact_payload_bytes: usize = scene_artifact_v1_payload_bytes + 3 * @sizeOf(u32);
const max_document_bytes: usize = 64 * 1024;
const max_artifact_bytes: usize = 1 * 1024 * 1024;

pub const Sprite = struct {
    position: [2]f32,
    size: [2]f32,
    color: [4]f32,
    textureId: u32,
};

pub const Player = struct {
    position: [2]f32,
    size: [2]f32,
    color: [4]f32,
    moveSpeed: f32,
    textureId: u32,
};

pub const Hazard = struct {
    position: [2]f32,
    size: [2]f32,
    color: [4]f32,
    patrolMinY: f32,
    patrolMaxY: f32,
    patrolSpeed: f32,
    textureId: u32,
};

pub const Scene = struct {
    schemaVersion: u32,
    player: Player,
    goal: Sprite,
    hazard: Hazard,
};

pub const LoadedScene = struct {
    value: Scene,
    identity: content_identity.ContentIdentity,
    artifact_version: ?u32,
};

pub const default_scene = Scene{
    .schemaVersion = current_schema_version,
    .player = .{
        .position = .{ 312.0, 130.0 },
        .size = .{ 320.0, 240.0 },
        .color = .{ 1.0, 1.0, 1.0, 1.0 },
        .moveSpeed = 180.0,
        .textureId = 1,
    },
    .goal = .{
        .position = .{ 700.0, 200.0 },
        .size = .{ 96.0, 96.0 },
        .color = .{ 1.0, 0.75, 0.10, 1.0 },
        .textureId = 2,
    },
    .hazard = .{
        .position = .{ 650.0, 280.0 },
        .size = .{ 96.0, 96.0 },
        .color = .{ 0.95, 0.20, 0.20, 1.0 },
        .patrolMinY = 245.0,
        .patrolMaxY = 330.0,
        .patrolSpeed = 80.0,
        .textureId = 1,
    },
};

pub fn load(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Scene {
    return (try loadWithIdentity(io, allocator, path)).value;
}

pub fn loadWithIdentity(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !LoadedScene {
    // 保留既有 load 的扩展名分派语义；实际读取函数始终收到显式 content kind。
    if (std.ascii.endsWithIgnoreCase(path, ".scene")) return loadArtifactWithIdentity(io, allocator, path);
    const contents = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_document_bytes));
    defer allocator.free(contents);
    return parseWithIdentity(allocator, contents, .source_document);
}

pub fn loadArtifact(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Scene {
    return (try loadArtifactWithIdentity(io, allocator, path)).value;
}

pub fn loadArtifactWithIdentity(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !LoadedScene {
    const contents = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_artifact_bytes));
    defer allocator.free(contents);
    return parseArtifactWithIdentity(contents);
}

fn parseWithIdentity(allocator: std.mem.Allocator, contents: []const u8, kind: content_identity.ContentKind) !LoadedScene {
    const value = try parse(allocator, contents);
    // 校验成功后才发布身份；value 与 digest/bytes 均来自 contents 这一次读取。
    return .{ .value = value, .identity = try content_identity.ContentIdentity.fromBytes(kind, contents), .artifact_version = null };
}

fn parseArtifactWithIdentity(contents: []const u8) !LoadedScene {
    const value = try parseArtifact(contents);
    return .{
        .value = value,
        .identity = try content_identity.ContentIdentity.fromBytes(.artifact, contents),
        .artifact_version = readLittleU32(contents[4..8]),
    };
}

fn readLittleU32(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}

fn readLittleF32(bytes: []const u8) f32 {
    return @bitCast(readLittleU32(bytes));
}

fn parseArtifact(source: []const u8) !Scene {
    if (source.len < scene_artifact_header_bytes) return error.InvalidSceneArtifact;
    if (!std.mem.eql(u8, source[0..4], "KSCN")) return error.InvalidSceneArtifact;
    const artifact_version = readLittleU32(source[4..8]);
    const schema_version = readLittleU32(source[8..12]);
    const payload_bytes = readLittleU32(source[12..16]);
    const texture_ids: [3]u32 = switch (artifact_version) {
        1 => blk: {
            if (schema_version != 1) return error.UnsupportedSceneSchema;
            if (payload_bytes != scene_artifact_v1_payload_bytes or source.len != scene_artifact_header_bytes + scene_artifact_v1_payload_bytes) return error.InvalidSceneArtifact;
            break :blk .{ 1, 2, 1 };
        },
        scene_artifact_version => blk: {
            if (schema_version != current_schema_version) return error.UnsupportedSceneSchema;
            if (payload_bytes != scene_artifact_payload_bytes or source.len != scene_artifact_header_bytes + scene_artifact_payload_bytes) return error.InvalidSceneArtifact;
            const texture_offset = scene_artifact_header_bytes + scene_artifact_v1_payload_bytes;
            break :blk .{
                readLittleU32(source[texture_offset..][0..4]),
                readLittleU32(source[texture_offset + 4 ..][0..4]),
                readLittleU32(source[texture_offset + 8 ..][0..4]),
            };
        },
        else => return error.UnsupportedSceneArtifactVersion,
    };

    // KSCN v1 的前 112 bytes 字段顺序仍是兼容 ABI；变更该前缀必须再次提升 artifact version。
    const offset: usize = scene_artifact_header_bytes;
    const scene = Scene{
        .schemaVersion = current_schema_version,
        .player = .{
            .position = .{ readLittleF32(source[offset..][0..4]), readLittleF32(source[offset + 4 ..][0..4]) },
            .size = .{ readLittleF32(source[offset + 8 ..][0..4]), readLittleF32(source[offset + 12 ..][0..4]) },
            .color = .{ readLittleF32(source[offset + 16 ..][0..4]), readLittleF32(source[offset + 20 ..][0..4]), readLittleF32(source[offset + 24 ..][0..4]), readLittleF32(source[offset + 28 ..][0..4]) },
            .moveSpeed = readLittleF32(source[offset + 32 ..][0..4]),
            .textureId = texture_ids[0],
        },
        .goal = .{
            .position = .{ readLittleF32(source[offset + 36 ..][0..4]), readLittleF32(source[offset + 40 ..][0..4]) },
            .size = .{ readLittleF32(source[offset + 44 ..][0..4]), readLittleF32(source[offset + 48 ..][0..4]) },
            .color = .{ readLittleF32(source[offset + 52 ..][0..4]), readLittleF32(source[offset + 56 ..][0..4]), readLittleF32(source[offset + 60 ..][0..4]), readLittleF32(source[offset + 64 ..][0..4]) },
            .textureId = texture_ids[1],
        },
        .hazard = .{
            .position = .{ readLittleF32(source[offset + 68 ..][0..4]), readLittleF32(source[offset + 72 ..][0..4]) },
            .size = .{ readLittleF32(source[offset + 76 ..][0..4]), readLittleF32(source[offset + 80 ..][0..4]) },
            .color = .{ readLittleF32(source[offset + 84 ..][0..4]), readLittleF32(source[offset + 88 ..][0..4]), readLittleF32(source[offset + 92 ..][0..4]), readLittleF32(source[offset + 96 ..][0..4]) },
            .patrolMinY = readLittleF32(source[offset + 100 ..][0..4]),
            .patrolMaxY = readLittleF32(source[offset + 104 ..][0..4]),
            .patrolSpeed = readLittleF32(source[offset + 108 ..][0..4]),
            .textureId = texture_ids[2],
        },
    };
    try validate(scene);
    return scene;
}
pub fn parse(allocator: std.mem.Allocator, contents: []const u8) !Scene {
    // 关键契约：严格解析拒绝未知/重复字段，避免 Editor 与 Runtime 静默使用不同语义。
    const parsed = try std.json.parseFromSlice(Scene, allocator, contents, .{});
    defer parsed.deinit();
    try validate(parsed.value);
    return parsed.value;
}

fn validate(scene: Scene) !void {
    if (scene.schemaVersion != current_schema_version) return error.UnsupportedSceneSchema;
    try validateSprite(scene.player.position, scene.player.size, scene.player.color);
    try validateSprite(scene.goal.position, scene.goal.size, scene.goal.color);
    try validateSprite(scene.hazard.position, scene.hazard.size, scene.hazard.color);
    if (scene.player.textureId == 0 or scene.goal.textureId == 0 or scene.hazard.textureId == 0) return error.InvalidTextureId;

    if (!std.math.isFinite(scene.player.moveSpeed) or scene.player.moveSpeed < 0.0) {
        return error.InvalidPlayerMoveSpeed;
    }
    if (!std.math.isFinite(scene.hazard.patrolMinY) or
        !std.math.isFinite(scene.hazard.patrolMaxY) or
        !std.math.isFinite(scene.hazard.patrolSpeed) or
        scene.hazard.patrolMinY >= scene.hazard.patrolMaxY or
        scene.hazard.patrolSpeed < 0.0 or
        scene.hazard.position[1] < scene.hazard.patrolMinY or
        scene.hazard.position[1] > scene.hazard.patrolMaxY)
    {
        return error.InvalidHazardPatrol;
    }
}

fn validateSprite(position: [2]f32, size: [2]f32, color: [4]f32) !void {
    for (position) |value| {
        if (!std.math.isFinite(value)) return error.InvalidSpritePosition;
    }
    for (size) |value| {
        if (!std.math.isFinite(value) or value <= 0.0) return error.InvalidSpriteSize;
    }
    for (color) |value| {
        if (!std.math.isFinite(value) or value < 0.0 or value > 1.0) return error.InvalidSpriteColor;
    }
}

test "scene v2 parses texture bindings" {
    const contents =
        \\{
        \\  "schemaVersion": 2,
        \\  "player": { "position": [100, 120], "size": [64, 64], "color": [1, 1, 1, 1], "moveSpeed": 200, "textureId": 2 },
        \\  "goal": { "position": [444, 180], "size": [48, 48], "color": [0.2, 0.9, 0.3, 1], "textureId": 1 },
        \\  "hazard": { "position": [300, 220], "size": [40, 40], "color": [0.9, 0.2, 0.2, 1], "patrolMinY": 180, "patrolMaxY": 260, "patrolSpeed": 75, "textureId": 2 }
        \\}
    ;
    const scene = try parse(std.testing.allocator, contents);
    try std.testing.expectEqual(@as(f32, 444.0), scene.goal.position[0]);
    try std.testing.expectEqual(@as(f32, 75.0), scene.hazard.patrolSpeed);
    try std.testing.expectEqual(@as(u32, 2), scene.player.textureId);
    try std.testing.expectEqual(@as(u32, 1), scene.goal.textureId);
}

test "scene source identity is computed from the parsed buffer" {
    const contents =
        \\{
        \\  "schemaVersion": 2,
        \\  "player": { "position": [100, 120], "size": [64, 64], "color": [1, 1, 1, 1], "moveSpeed": 200, "textureId": 1 },
        \\  "goal": { "position": [444, 180], "size": [48, 48], "color": [0.2, 0.9, 0.3, 1], "textureId": 2 },
        \\  "hazard": { "position": [300, 220], "size": [40, 40], "color": [0.9, 0.2, 0.2, 1], "patrolMinY": 180, "patrolMaxY": 260, "patrolSpeed": 75, "textureId": 1 }
        \\}
    ;
    const loaded = try parseWithIdentity(std.testing.allocator, contents, .source_document);
    const expected = try content_identity.ContentIdentity.fromBytes(.source_document, contents);
    try std.testing.expectEqual(expected, loaded.identity);
    try std.testing.expectEqual(@as(f32, 444.0), loaded.value.goal.position[0]);
}

test "scene v2 rejects unsupported schema" {
    const contents =
        \\{
        \\  "schemaVersion": 3,
        \\  "player": { "position": [100, 120], "size": [64, 64], "color": [1, 1, 1, 1], "moveSpeed": 200, "textureId": 1 },
        \\  "goal": { "position": [444, 180], "size": [48, 48], "color": [0.2, 0.9, 0.3, 1], "textureId": 2 },
        \\  "hazard": { "position": [300, 220], "size": [40, 40], "color": [0.9, 0.2, 0.2, 1], "patrolMinY": 180, "patrolMaxY": 260, "patrolSpeed": 75, "textureId": 1 }
        \\}
    ;
    try std.testing.expectError(error.UnsupportedSceneSchema, parse(std.testing.allocator, contents));
}

test "scene v2 rejects invalid patrol and texture ids" {
    var scene = default_scene;
    scene.hazard.patrolMinY = scene.hazard.patrolMaxY;
    try std.testing.expectError(error.InvalidHazardPatrol, validate(scene));
    scene = default_scene;
    scene.goal.textureId = 0;
    try std.testing.expectError(error.InvalidTextureId, validate(scene));
}
fn writeLittleU32(bytes: []u8, value: u32) void {
    bytes[0] = @truncate(value);
    bytes[1] = @truncate(value >> 8);
    bytes[2] = @truncate(value >> 16);
    bytes[3] = @truncate(value >> 24);
}

fn writeLittleF32(bytes: []u8, value: f32) void {
    writeLittleU32(bytes, @bitCast(value));
}

fn makeDefaultSceneArtifact() [scene_artifact_header_bytes + scene_artifact_payload_bytes]u8 {
    var artifact = [_]u8{0} ** (scene_artifact_header_bytes + scene_artifact_payload_bytes);
    artifact[0] = 'K';
    artifact[1] = 'S';
    artifact[2] = 'C';
    artifact[3] = 'N';
    writeLittleU32(artifact[4..8], scene_artifact_version);
    writeLittleU32(artifact[8..12], current_schema_version);
    writeLittleU32(artifact[12..16], scene_artifact_payload_bytes);

    // 测试数据显式列出全部 28 个字段，防止 importer 与 Runtime 的布局悄然漂移。
    const payload = [_]f32{
        default_scene.player.position[0],
        default_scene.player.position[1],
        default_scene.player.size[0],
        default_scene.player.size[1],
        default_scene.player.color[0],
        default_scene.player.color[1],
        default_scene.player.color[2],
        default_scene.player.color[3],
        default_scene.player.moveSpeed,
        default_scene.goal.position[0],
        default_scene.goal.position[1],
        default_scene.goal.size[0],
        default_scene.goal.size[1],
        default_scene.goal.color[0],
        default_scene.goal.color[1],
        default_scene.goal.color[2],
        default_scene.goal.color[3],
        default_scene.hazard.position[0],
        default_scene.hazard.position[1],
        default_scene.hazard.size[0],
        default_scene.hazard.size[1],
        default_scene.hazard.color[0],
        default_scene.hazard.color[1],
        default_scene.hazard.color[2],
        default_scene.hazard.color[3],
        default_scene.hazard.patrolMinY,
        default_scene.hazard.patrolMaxY,
        default_scene.hazard.patrolSpeed,
    };
    for (payload, 0..) |value, index| {
        const start = scene_artifact_header_bytes + index * @sizeOf(f32);
        writeLittleF32(artifact[start .. start + @sizeOf(f32)], value);
    }
    const texture_offset = scene_artifact_header_bytes + scene_artifact_v1_payload_bytes;
    writeLittleU32(artifact[texture_offset..][0..4], default_scene.player.textureId);
    writeLittleU32(artifact[texture_offset + 4 ..][0..4], default_scene.goal.textureId);
    writeLittleU32(artifact[texture_offset + 8 ..][0..4], default_scene.hazard.textureId);
    return artifact;
}

test "KSCN v2 parses texture bindings" {
    const artifact = makeDefaultSceneArtifact();
    const scene = try parseArtifact(artifact[0..]);
    try std.testing.expectEqual(default_scene.player.moveSpeed, scene.player.moveSpeed);
    try std.testing.expectEqual(default_scene.goal.position[0], scene.goal.position[0]);
    try std.testing.expectEqual(default_scene.hazard.patrolSpeed, scene.hazard.patrolSpeed);
    try std.testing.expectEqual(default_scene.goal.textureId, scene.goal.textureId);
}

test "KSCN v1 remains compatible with default texture bindings" {
    var artifact = [_]u8{0} ** (scene_artifact_header_bytes + scene_artifact_v1_payload_bytes);
    const current = makeDefaultSceneArtifact();
    @memcpy(artifact[0 .. scene_artifact_header_bytes + scene_artifact_v1_payload_bytes], current[0 .. scene_artifact_header_bytes + scene_artifact_v1_payload_bytes]);
    writeLittleU32(artifact[4..8], 1);
    writeLittleU32(artifact[8..12], 1);
    writeLittleU32(artifact[12..16], scene_artifact_v1_payload_bytes);
    const loaded = try parseArtifactWithIdentity(&artifact);
    try std.testing.expectEqual(@as(?u32, 1), loaded.artifact_version);
    try std.testing.expectEqual(@as(u32, 1), loaded.value.player.textureId);
    try std.testing.expectEqual(@as(u32, 2), loaded.value.goal.textureId);
    try std.testing.expectEqual(@as(u32, 1), loaded.value.hazard.textureId);
}

test "KSCN identity is computed from the validated artifact buffer" {
    const artifact = makeDefaultSceneArtifact();
    const loaded = try parseArtifactWithIdentity(artifact[0..]);
    const expected = try content_identity.ContentIdentity.fromBytes(.artifact, artifact[0..]);
    try std.testing.expectEqual(expected, loaded.identity);
    try std.testing.expectEqual(default_scene.goal.position[0], loaded.value.goal.position[0]);
}

test "KSCN rejects truncated unsupported and zero texture artifacts" {
    var artifact = makeDefaultSceneArtifact();
    try std.testing.expectError(error.InvalidSceneArtifact, parseArtifact(artifact[0 .. artifact.len - 1]));

    writeLittleU32(artifact[4..8], scene_artifact_version + 1);
    try std.testing.expectError(error.UnsupportedSceneArtifactVersion, parseArtifact(artifact[0..]));
    artifact = makeDefaultSceneArtifact();
    writeLittleU32(artifact[scene_artifact_header_bytes + scene_artifact_v1_payload_bytes ..][0..4], 0);
    try std.testing.expectError(error.InvalidTextureId, parseArtifact(artifact[0..]));
}
