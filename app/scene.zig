const std = @import("std");
const content_identity = @import("content_identity.zig");

pub const current_schema_version: u32 = 3;
pub const scene_artifact_version: u32 = 3;
pub const max_texture_count: usize = 4;
pub const max_texture_artifact_bytes: usize = 255;
const scene_artifact_header_bytes: usize = 16;
const scene_artifact_v1_payload_bytes: usize = 28 * @sizeOf(f32);
const scene_artifact_v2_payload_bytes: usize = scene_artifact_v1_payload_bytes + 3 * @sizeOf(u32);
const primary_texture_artifact = "assets/renderer2d/test.texture";
const secondary_texture_artifact = "assets/renderer2d/goal.texture";
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

pub const TextureSpec = struct {
    textureId: u32 = 0,
    artifactBytes: u16 = 0,
    artifactStorage: [max_texture_artifact_bytes]u8 = [_]u8{0} ** max_texture_artifact_bytes,

    pub fn artifact(self: *const TextureSpec) []const u8 {
        return self.artifactStorage[0..self.artifactBytes];
    }
};

pub const TextureSet = struct {
    count: u8 = 0,
    entries: [max_texture_count]TextureSpec = [_]TextureSpec{.{}} ** max_texture_count,

    pub fn slice(self: *const TextureSet) []const TextureSpec {
        return self.entries[0..self.count];
    }

    pub fn contains(self: *const TextureSet, texture_id: u32) bool {
        for (self.slice()) |entry| if (entry.textureId == texture_id) return true;
        return false;
    }
};

pub const Scene = struct {
    schemaVersion: u32,
    textures: TextureSet,
    player: Player,
    goal: Sprite,
    hazard: Hazard,
};

const WireTextureSpec = struct {
    textureId: u32,
    artifact: []const u8,
};

const WireScene = struct {
    schemaVersion: u32,
    textures: []const WireTextureSpec,
    player: Player,
    goal: Sprite,
    hazard: Hazard,
};

fn makeTextureSpec(texture_id: u32, artifact: []const u8) TextureSpec {
    var spec = TextureSpec{ .textureId = texture_id, .artifactBytes = @intCast(artifact.len) };
    @memcpy(spec.artifactStorage[0..artifact.len], artifact);
    return spec;
}

fn defaultTextureSet() TextureSet {
    var set = TextureSet{ .count = 2 };
    set.entries[0] = makeTextureSpec(1, primary_texture_artifact);
    set.entries[1] = makeTextureSpec(2, secondary_texture_artifact);
    return set;
}

pub const LoadedScene = struct {
    value: Scene,
    identity: content_identity.ContentIdentity,
    artifact_version: ?u32,
};

pub const default_scene = Scene{
    .schemaVersion = current_schema_version,
    .textures = blk: {
        var set = defaultTextureSet();
        set.count = 3;
        set.entries[2] = makeTextureSpec(3, secondary_texture_artifact);
        break :blk set;
    },
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
        .textureId = 3,
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
    if (source.len != scene_artifact_header_bytes + @as(usize, payload_bytes)) return error.InvalidSceneArtifact;
    var textures = defaultTextureSet();
    const texture_ids: [3]u32 = switch (artifact_version) {
        1 => blk: {
            if (schema_version != 1) return error.UnsupportedSceneSchema;
            if (payload_bytes != scene_artifact_v1_payload_bytes) return error.InvalidSceneArtifact;
            break :blk .{ 1, 2, 1 };
        },
        2 => blk: {
            if (schema_version != 2) return error.UnsupportedSceneSchema;
            if (payload_bytes != scene_artifact_v2_payload_bytes) return error.InvalidSceneArtifact;
            const texture_offset = scene_artifact_header_bytes + scene_artifact_v1_payload_bytes;
            break :blk .{
                readLittleU32(source[texture_offset..][0..4]),
                readLittleU32(source[texture_offset + 4 ..][0..4]),
                readLittleU32(source[texture_offset + 8 ..][0..4]),
            };
        },
        scene_artifact_version => blk: {
            if (schema_version != current_schema_version) return error.UnsupportedSceneSchema;
            if (payload_bytes < scene_artifact_v2_payload_bytes + @sizeOf(u32)) return error.InvalidSceneArtifact;
            const texture_offset = scene_artifact_header_bytes + scene_artifact_v1_payload_bytes;
            const ids = [3]u32{
                readLittleU32(source[texture_offset..][0..4]),
                readLittleU32(source[texture_offset + 4 ..][0..4]),
                readLittleU32(source[texture_offset + 8 ..][0..4]),
            };
            var cursor = scene_artifact_header_bytes + scene_artifact_v2_payload_bytes;
            const texture_count = readLittleU32(source[cursor..][0..4]);
            cursor += 4;
            if (texture_count == 0 or texture_count > max_texture_count) return error.InvalidTextureSetCount;
            textures = .{ .count = @intCast(texture_count) };
            for (textures.entries[0..textures.count]) |*entry| {
                if (cursor + 8 > source.len) return error.InvalidSceneArtifact;
                const texture_id = readLittleU32(source[cursor..][0..4]);
                const artifact_bytes = readLittleU32(source[cursor + 4 ..][0..4]);
                cursor += 8;
                if (artifact_bytes == 0 or artifact_bytes > max_texture_artifact_bytes or cursor + artifact_bytes > source.len) return error.InvalidSceneArtifact;
                entry.* = makeTextureSpec(texture_id, source[cursor .. cursor + artifact_bytes]);
                cursor += artifact_bytes;
            }
            if (cursor != source.len) return error.InvalidSceneArtifact;
            break :blk ids;
        },
        else => return error.UnsupportedSceneArtifactVersion,
    };

    // KSCN v1 的前 112 bytes 字段顺序仍是兼容 ABI；变更该前缀必须再次提升 artifact version。
    const offset: usize = scene_artifact_header_bytes;
    const scene = Scene{
        .schemaVersion = current_schema_version,
        .textures = textures,
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
    const parsed = try std.json.parseFromSlice(WireScene, allocator, contents, .{});
    defer parsed.deinit();
    if (parsed.value.textures.len == 0 or parsed.value.textures.len > max_texture_count) return error.InvalidTextureSetCount;
    var textures = TextureSet{ .count = @intCast(parsed.value.textures.len) };
    for (parsed.value.textures, 0..) |wire, index| {
        if (wire.artifact.len == 0 or wire.artifact.len > max_texture_artifact_bytes) return error.InvalidTextureArtifact;
        textures.entries[index] = makeTextureSpec(wire.textureId, wire.artifact);
    }
    const scene = Scene{
        .schemaVersion = parsed.value.schemaVersion,
        .textures = textures,
        .player = parsed.value.player,
        .goal = parsed.value.goal,
        .hazard = parsed.value.hazard,
    };
    try validate(scene);
    return scene;
}

fn validate(scene: Scene) !void {
    if (scene.schemaVersion != current_schema_version) return error.UnsupportedSceneSchema;
    if (scene.textures.count == 0 or scene.textures.count > max_texture_count) return error.InvalidTextureSetCount;
    for (scene.textures.slice(), 0..) |entry, index| {
        if (entry.textureId == 0) return error.InvalidTextureId;
        try validateTextureArtifact(entry.artifact());
        for (scene.textures.slice()[0..index]) |previous| {
            if (previous.textureId == entry.textureId) return error.DuplicateTextureId;
        }
    }
    try validateSprite(scene.player.position, scene.player.size, scene.player.color);
    try validateSprite(scene.goal.position, scene.goal.size, scene.goal.color);
    try validateSprite(scene.hazard.position, scene.hazard.size, scene.hazard.color);
    if (scene.player.textureId == 0 or scene.goal.textureId == 0 or scene.hazard.textureId == 0) return error.InvalidTextureId;
    if (!scene.textures.contains(scene.player.textureId) or !scene.textures.contains(scene.goal.textureId) or !scene.textures.contains(scene.hazard.textureId)) return error.UnknownSceneTexture;

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

fn validateTextureArtifact(artifact: []const u8) !void {
    if (artifact.len == 0 or artifact.len > max_texture_artifact_bytes) return error.InvalidTextureArtifact;
    if (!std.unicode.utf8ValidateSlice(artifact)) return error.InvalidTextureArtifact;
    if (!std.mem.startsWith(u8, artifact, "assets/renderer2d/") or !std.mem.endsWith(u8, artifact, ".texture")) return error.InvalidTextureArtifact;
    if (std.mem.indexOfScalar(u8, artifact, '\\') != null or artifact[0] == '/') return error.InvalidTextureArtifact;
    var segments = std.mem.splitScalar(u8, artifact, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.InvalidTextureArtifact;
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

test "scene v3 parses texture set and bindings" {
    const contents =
        \\{
        \\  "schemaVersion": 3,
        \\  "textures": [
        \\    { "textureId": 1, "artifact": "assets/renderer2d/test.texture" },
        \\    { "textureId": 2, "artifact": "assets/renderer2d/goal.texture" },
        \\    { "textureId": 3, "artifact": "assets/renderer2d/goal.texture" }
        \\  ],
        \\  "player": { "position": [100, 120], "size": [64, 64], "color": [1, 1, 1, 1], "moveSpeed": 200, "textureId": 2 },
        \\  "goal": { "position": [444, 180], "size": [48, 48], "color": [0.2, 0.9, 0.3, 1], "textureId": 1 },
        \\  "hazard": { "position": [300, 220], "size": [40, 40], "color": [0.9, 0.2, 0.2, 1], "patrolMinY": 180, "patrolMaxY": 260, "patrolSpeed": 75, "textureId": 3 }
        \\}
    ;
    const scene = try parse(std.testing.allocator, contents);
    try std.testing.expectEqual(@as(f32, 444.0), scene.goal.position[0]);
    try std.testing.expectEqual(@as(f32, 75.0), scene.hazard.patrolSpeed);
    try std.testing.expectEqual(@as(u32, 2), scene.player.textureId);
    try std.testing.expectEqual(@as(u32, 1), scene.goal.textureId);
    try std.testing.expectEqual(@as(usize, 3), scene.textures.slice().len);
}

test "scene source identity is computed from the parsed buffer" {
    const contents =
        \\{
        \\  "schemaVersion": 3,
        \\  "textures": [
        \\    { "textureId": 1, "artifact": "assets/renderer2d/test.texture" },
        \\    { "textureId": 2, "artifact": "assets/renderer2d/goal.texture" }
        \\  ],
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
        \\  "schemaVersion": 4,
        \\  "textures": [
        \\    { "textureId": 1, "artifact": "assets/renderer2d/test.texture" },
        \\    { "textureId": 2, "artifact": "assets/renderer2d/goal.texture" }
        \\  ],
        \\  "player": { "position": [100, 120], "size": [64, 64], "color": [1, 1, 1, 1], "moveSpeed": 200, "textureId": 1 },
        \\  "goal": { "position": [444, 180], "size": [48, 48], "color": [0.2, 0.9, 0.3, 1], "textureId": 2 },
        \\  "hazard": { "position": [300, 220], "size": [40, 40], "color": [0.9, 0.2, 0.2, 1], "patrolMinY": 180, "patrolMaxY": 260, "patrolSpeed": 75, "textureId": 1 }
        \\}
    ;
    try std.testing.expectError(error.UnsupportedSceneSchema, parse(std.testing.allocator, contents));
}

test "scene v3 rejects invalid patrol and texture references" {
    var scene = default_scene;
    scene.hazard.patrolMinY = scene.hazard.patrolMaxY;
    try std.testing.expectError(error.InvalidHazardPatrol, validate(scene));
    scene = default_scene;
    scene.goal.textureId = 4;
    try std.testing.expectError(error.UnknownSceneTexture, validate(scene));
}

test "scene v3 rejects duplicate ids and invalid artifact paths" {
    const duplicate =
        \\{"schemaVersion":3,"textures":[{"textureId":1,"artifact":"assets/renderer2d/test.texture"},{"textureId":1,"artifact":"assets/renderer2d/goal.texture"}],
        \\"player":{"position":[0,0],"size":[1,1],"color":[1,1,1,1],"moveSpeed":1,"textureId":1},
        \\"goal":{"position":[0,0],"size":[1,1],"color":[1,1,1,1],"textureId":1},
        \\"hazard":{"position":[0,1],"size":[1,1],"color":[1,1,1,1],"patrolMinY":0,"patrolMaxY":2,"patrolSpeed":1,"textureId":1}}
    ;
    try std.testing.expectError(error.DuplicateTextureId, parse(std.testing.allocator, duplicate));
    const invalid_path =
        \\{"schemaVersion":3,"textures":[{"textureId":1,"artifact":"assets/renderer2d/../test.texture"}],
        \\"player":{"position":[0,0],"size":[1,1],"color":[1,1,1,1],"moveSpeed":1,"textureId":1},
        \\"goal":{"position":[0,0],"size":[1,1],"color":[1,1,1,1],"textureId":1},
        \\"hazard":{"position":[0,1],"size":[1,1],"color":[1,1,1,1],"patrolMinY":0,"patrolMaxY":2,"patrolSpeed":1,"textureId":1}}
    ;
    try std.testing.expectError(error.InvalidTextureArtifact, parse(std.testing.allocator, invalid_path));
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

const default_scene_artifact_payload_bytes = scene_artifact_v2_payload_bytes + 4 +
    (8 + primary_texture_artifact.len) +
    (8 + secondary_texture_artifact.len) +
    (8 + secondary_texture_artifact.len);

fn makeDefaultSceneArtifact() [scene_artifact_header_bytes + default_scene_artifact_payload_bytes]u8 {
    var artifact = [_]u8{0} ** (scene_artifact_header_bytes + default_scene_artifact_payload_bytes);
    artifact[0] = 'K';
    artifact[1] = 'S';
    artifact[2] = 'C';
    artifact[3] = 'N';
    writeLittleU32(artifact[4..8], scene_artifact_version);
    writeLittleU32(artifact[8..12], current_schema_version);
    writeLittleU32(artifact[12..16], default_scene_artifact_payload_bytes);

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
    var cursor = scene_artifact_header_bytes + scene_artifact_v2_payload_bytes;
    writeLittleU32(artifact[cursor..][0..4], default_scene.textures.count);
    cursor += 4;
    for (default_scene.textures.slice()) |entry| {
        writeLittleU32(artifact[cursor..][0..4], entry.textureId);
        writeLittleU32(artifact[cursor + 4 ..][0..4], entry.artifactBytes);
        cursor += 8;
        @memcpy(artifact[cursor .. cursor + entry.artifactBytes], entry.artifact());
        cursor += entry.artifactBytes;
    }
    return artifact;
}

test "KSCN v3 parses texture set and bindings" {
    const artifact = makeDefaultSceneArtifact();
    const scene = try parseArtifact(artifact[0..]);
    try std.testing.expectEqual(default_scene.player.moveSpeed, scene.player.moveSpeed);
    try std.testing.expectEqual(default_scene.goal.position[0], scene.goal.position[0]);
    try std.testing.expectEqual(default_scene.hazard.patrolSpeed, scene.hazard.patrolSpeed);
    try std.testing.expectEqual(default_scene.goal.textureId, scene.goal.textureId);
    try std.testing.expectEqual(@as(usize, 3), scene.textures.slice().len);
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

test "KSCN v2 remains compatible with the default two texture set" {
    var artifact = [_]u8{0} ** (scene_artifact_header_bytes + scene_artifact_v2_payload_bytes);
    const current = makeDefaultSceneArtifact();
    @memcpy(artifact[0..artifact.len], current[0..artifact.len]);
    writeLittleU32(artifact[4..8], 2);
    writeLittleU32(artifact[8..12], 2);
    writeLittleU32(artifact[12..16], scene_artifact_v2_payload_bytes);
    writeLittleU32(artifact[128..132], 1);
    writeLittleU32(artifact[132..136], 2);
    writeLittleU32(artifact[136..140], 1);
    const loaded = try parseArtifactWithIdentity(&artifact);
    try std.testing.expectEqual(@as(?u32, 2), loaded.artifact_version);
    try std.testing.expectEqual(@as(usize, 2), loaded.value.textures.slice().len);
    try std.testing.expectEqualStrings(primary_texture_artifact, loaded.value.textures.entries[0].artifact());
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
