const std = @import("std");
const content_identity = @import("content_identity.zig");

pub const current_schema_version: u32 = 4;
pub const scene_artifact_version: u32 = 4;
pub const max_texture_count: usize = 4;
pub const max_texture_artifact_bytes: usize = 255;
pub const min_scene_object_count: usize = 3;
pub const max_scene_object_count: usize = 64;
pub const max_object_id_bytes: usize = 63;

const scene_artifact_header_bytes: usize = 16;
const scene_artifact_v1_payload_bytes: usize = 28 * @sizeOf(f32);
const scene_artifact_v2_payload_bytes: usize = scene_artifact_v1_payload_bytes + 3 * @sizeOf(u32);
const primary_texture_artifact = "assets/renderer2d/test.texture";
const secondary_texture_artifact = "assets/renderer2d/goal.texture";
const max_document_bytes: usize = 64 * 1024;
const max_artifact_bytes: usize = 1 * 1024 * 1024;

pub const Sprite = struct {
    position: [2]f32 = .{ 0.0, 0.0 },
    size: [2]f32 = .{ 1.0, 1.0 },
    color: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
    textureId: u32 = 0,
};

pub const PlayerPayload = struct {
    moveSpeed: f32 = 0.0,
};

pub const PatrolPayload = struct {
    minY: f32 = 0.0,
    maxY: f32 = 1.0,
    speed: f32 = 0.0,
};

pub const ObjectKind = enum(u32) {
    sprite = 1,
    player = 2,
    goal = 3,
    patrol_hazard = 4,
};

pub const ObjectId = struct {
    byte_count: u8 = 0,
    storage: [max_object_id_bytes]u8 = [_]u8{0} ** max_object_id_bytes,

    pub fn init(bytes: []const u8) !ObjectId {
        try validateObjectIdBytes(bytes);
        var value = ObjectId{ .byte_count = @intCast(bytes.len) };
        @memcpy(value.storage[0..bytes.len], bytes);
        return value;
    }

    pub fn slice(self: *const ObjectId) []const u8 {
        return self.storage[0..self.byte_count];
    }

    pub fn eql(self: *const ObjectId, other: *const ObjectId) bool {
        return std.mem.eql(u8, self.slice(), other.slice());
    }
};

pub const SceneObject = struct {
    objectId: ObjectId = .{},
    kind: ObjectKind = .sprite,
    sprite: Sprite = .{},
    player: PlayerPayload = .{},
    patrol: PatrolPayload = .{},
};

pub const SceneObjectSet = struct {
    count: u8 = 0,
    entries: [max_scene_object_count]SceneObject = [_]SceneObject{.{}} ** max_scene_object_count,

    pub fn slice(self: *const SceneObjectSet) []const SceneObject {
        return self.entries[0..self.count];
    }

    pub fn mutableSlice(self: *SceneObjectSet) []SceneObject {
        return self.entries[0..self.count];
    }

    pub fn indexOfKind(self: *const SceneObjectSet, kind: ObjectKind) ?usize {
        for (self.slice(), 0..) |object, index| {
            if (object.kind == kind) return index;
        }
        return null;
    }

    pub fn indexOfId(self: *const SceneObjectSet, object_id: []const u8) ?usize {
        for (self.slice(), 0..) |object, index| {
            if (std.mem.eql(u8, object.objectId.slice(), object_id)) return index;
        }
        return null;
    }
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
        for (self.slice()) |entry| {
            if (entry.textureId == texture_id) return true;
        }
        return false;
    }
};

pub const Scene = struct {
    schemaVersion: u32 = current_schema_version,
    textures: TextureSet,
    objects: SceneObjectSet,

    pub fn player(self: *const Scene) *const SceneObject {
        return &self.objects.entries[self.objects.indexOfKind(.player) orelse unreachable];
    }

    pub fn goal(self: *const Scene) *const SceneObject {
        return &self.objects.entries[self.objects.indexOfKind(.goal) orelse unreachable];
    }

    pub fn primaryHazard(self: *const Scene) *const SceneObject {
        return &self.objects.entries[self.objects.indexOfKind(.patrol_hazard) orelse unreachable];
    }
};

const LegacyPlayer = struct {
    position: [2]f32,
    size: [2]f32,
    color: [4]f32,
    moveSpeed: f32,
    textureId: u32,
};

const LegacyHazard = struct {
    position: [2]f32,
    size: [2]f32,
    color: [4]f32,
    patrolMinY: f32,
    patrolMaxY: f32,
    patrolSpeed: f32,
    textureId: u32,
};

const WireTextureSpec = struct {
    textureId: u32,
    artifact: []const u8,
};

const WireSceneV3 = struct {
    schemaVersion: u32,
    textures: []const WireTextureSpec,
    player: LegacyPlayer,
    goal: Sprite,
    hazard: LegacyHazard,
};

const WireTransform = struct {
    position: [2]f32,
};

const WireSprite = struct {
    size: [2]f32,
    color: [4]f32,
    textureId: u32,
};

const WirePlayerPayload = struct {
    moveSpeed: f32,
};

const WirePatrolPayload = struct {
    minY: f32,
    maxY: f32,
    speed: f32,
};

const WireSceneObject = struct {
    objectId: []const u8,
    kind: ObjectKind,
    transform: WireTransform,
    sprite: WireSprite,
    player: ?WirePlayerPayload = null,
    patrol: ?WirePatrolPayload = null,
};

const WireSceneV4 = struct {
    schemaVersion: u32,
    textures: []const WireTextureSpec,
    objects: []const WireSceneObject,
};

const SchemaProbe = struct {
    schemaVersion: u32,
};

fn makeTextureSpec(texture_id: u32, artifact: []const u8) TextureSpec {
    var spec = TextureSpec{ .textureId = texture_id, .artifactBytes = @intCast(artifact.len) };
    @memcpy(spec.artifactStorage[0..artifact.len], artifact);
    return spec;
}

fn defaultTextureSet() TextureSet {
    var set = TextureSet{ .count = 3 };
    set.entries[0] = makeTextureSpec(1, primary_texture_artifact);
    set.entries[1] = makeTextureSpec(2, secondary_texture_artifact);
    set.entries[2] = makeTextureSpec(3, secondary_texture_artifact);
    return set;
}

fn objectIdLiteral(comptime bytes: []const u8) ObjectId {
    var value = ObjectId{ .byte_count = bytes.len };
    @memcpy(value.storage[0..bytes.len], bytes);
    return value;
}

fn sceneObject(
    comptime object_id: []const u8,
    kind: ObjectKind,
    sprite: Sprite,
    player: PlayerPayload,
    patrol: PatrolPayload,
) SceneObject {
    return .{
        .objectId = objectIdLiteral(object_id),
        .kind = kind,
        .sprite = sprite,
        .player = player,
        .patrol = patrol,
    };
}

pub const default_scene = Scene{
    .textures = defaultTextureSet(),
    .objects = blk: {
        var objects = SceneObjectSet{ .count = 5 };
        objects.entries[0] = sceneObject("decoration-1", .sprite, .{
            .position = .{ 100.0, 420.0 },
            .size = .{ 80.0, 80.0 },
            .color = .{ 0.45, 0.65, 1.0, 0.8 },
            .textureId = 2,
        }, .{}, .{});
        objects.entries[1] = sceneObject("goal", .goal, .{
            .position = .{ 700.0, 200.0 },
            .size = .{ 96.0, 96.0 },
            .color = .{ 1.0, 0.75, 0.10, 1.0 },
            .textureId = 2,
        }, .{}, .{});
        objects.entries[2] = sceneObject("hazard-1", .patrol_hazard, .{
            .position = .{ 650.0, 280.0 },
            .size = .{ 96.0, 96.0 },
            .color = .{ 0.95, 0.20, 0.20, 1.0 },
            .textureId = 3,
        }, .{}, .{ .minY = 245.0, .maxY = 330.0, .speed = 80.0 });
        objects.entries[3] = sceneObject("hazard-2", .patrol_hazard, .{
            .position = .{ 500.0, 420.0 },
            .size = .{ 72.0, 72.0 },
            .color = .{ 1.0, 0.35, 0.20, 1.0 },
            .textureId = 3,
        }, .{}, .{ .minY = 380.0, .maxY = 460.0, .speed = 55.0 });
        objects.entries[4] = sceneObject("player", .player, .{
            .position = .{ 312.0, 130.0 },
            .size = .{ 320.0, 240.0 },
            .color = .{ 1.0, 1.0, 1.0, 1.0 },
            .textureId = 1,
        }, .{ .moveSpeed = 180.0 }, .{});
        break :blk objects;
    },
};

pub const LoadedScene = struct {
    value: Scene,
    identity: content_identity.ContentIdentity,
    artifact_version: ?u32,
};

pub fn load(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Scene {
    return (try loadWithIdentity(io, allocator, path)).value;
}

pub fn loadWithIdentity(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !LoadedScene {
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
    return .{
        .value = value,
        .identity = try content_identity.ContentIdentity.fromBytes(kind, contents),
        .artifact_version = null,
    };
}

fn parseArtifactWithIdentity(contents: []const u8) !LoadedScene {
    const value = try parseArtifact(contents);
    return .{
        .value = value,
        .identity = try content_identity.ContentIdentity.fromBytes(.artifact, contents),
        .artifact_version = readLittleU32(contents[4..8]),
    };
}

pub fn parse(allocator: std.mem.Allocator, contents: []const u8) !Scene {
    const probe = try std.json.parseFromSlice(SchemaProbe, allocator, contents, .{ .ignore_unknown_fields = true });
    defer probe.deinit();
    return switch (probe.value.schemaVersion) {
        3 => parseSourceV3(allocator, contents),
        current_schema_version => parseSourceV4(allocator, contents),
        else => error.UnsupportedSceneSchema,
    };
}

fn parseSourceV3(allocator: std.mem.Allocator, contents: []const u8) !Scene {
    const parsed = try std.json.parseFromSlice(WireSceneV3, allocator, contents, .{});
    defer parsed.deinit();
    if (parsed.value.schemaVersion != 3) return error.UnsupportedSceneSchema;
    const textures = try normalizeTextures(parsed.value.textures);
    const value = normalizeLegacyScene(textures, parsed.value.player, parsed.value.goal, parsed.value.hazard);
    try validate(&value);
    return value;
}

fn parseSourceV4(allocator: std.mem.Allocator, contents: []const u8) !Scene {
    const parsed = try std.json.parseFromSlice(WireSceneV4, allocator, contents, .{});
    defer parsed.deinit();
    if (parsed.value.schemaVersion != current_schema_version) return error.UnsupportedSceneSchema;
    const textures = try normalizeTextures(parsed.value.textures);
    if (parsed.value.objects.len < min_scene_object_count or parsed.value.objects.len > max_scene_object_count) {
        return error.InvalidSceneObjectCount;
    }
    var objects = SceneObjectSet{ .count = @intCast(parsed.value.objects.len) };
    for (parsed.value.objects, 0..) |wire, index| {
        const object_id = try ObjectId.init(wire.objectId);
        const sprite = Sprite{
            .position = wire.transform.position,
            .size = wire.sprite.size,
            .color = wire.sprite.color,
            .textureId = wire.sprite.textureId,
        };
        objects.entries[index] = switch (wire.kind) {
            .sprite, .goal => blk: {
                if (wire.player != null or wire.patrol != null) return error.InvalidSceneObjectPayload;
                break :blk .{ .objectId = object_id, .kind = wire.kind, .sprite = sprite };
            },
            .player => blk: {
                if (wire.player == null or wire.patrol != null) return error.InvalidSceneObjectPayload;
                break :blk .{
                    .objectId = object_id,
                    .kind = wire.kind,
                    .sprite = sprite,
                    .player = .{ .moveSpeed = wire.player.?.moveSpeed },
                };
            },
            .patrol_hazard => blk: {
                if (wire.player != null or wire.patrol == null) return error.InvalidSceneObjectPayload;
                break :blk .{
                    .objectId = object_id,
                    .kind = wire.kind,
                    .sprite = sprite,
                    .patrol = .{
                        .minY = wire.patrol.?.minY,
                        .maxY = wire.patrol.?.maxY,
                        .speed = wire.patrol.?.speed,
                    },
                };
            },
        };
    }
    const value = Scene{ .textures = textures, .objects = objects };
    try validate(&value);
    return value;
}

fn normalizeTextures(wire_textures: []const WireTextureSpec) !TextureSet {
    if (wire_textures.len == 0 or wire_textures.len > max_texture_count) return error.InvalidTextureSetCount;
    var textures = TextureSet{ .count = @intCast(wire_textures.len) };
    for (wire_textures, 0..) |wire, index| {
        if (wire.artifact.len == 0 or wire.artifact.len > max_texture_artifact_bytes) return error.InvalidTextureArtifact;
        textures.entries[index] = makeTextureSpec(wire.textureId, wire.artifact);
    }
    return textures;
}

fn normalizeLegacyScene(textures: TextureSet, player: LegacyPlayer, goal: Sprite, hazard: LegacyHazard) Scene {
    var objects = SceneObjectSet{ .count = 3 };
    objects.entries[0] = .{
        .objectId = objectIdLiteral("player"),
        .kind = .player,
        .sprite = .{
            .position = player.position,
            .size = player.size,
            .color = player.color,
            .textureId = player.textureId,
        },
        .player = .{ .moveSpeed = player.moveSpeed },
    };
    objects.entries[1] = .{
        .objectId = objectIdLiteral("goal"),
        .kind = .goal,
        .sprite = goal,
    };
    objects.entries[2] = .{
        .objectId = objectIdLiteral("hazard"),
        .kind = .patrol_hazard,
        .sprite = .{
            .position = hazard.position,
            .size = hazard.size,
            .color = hazard.color,
            .textureId = hazard.textureId,
        },
        .patrol = .{
            .minY = hazard.patrolMinY,
            .maxY = hazard.patrolMaxY,
            .speed = hazard.patrolSpeed,
        },
    };
    return .{ .textures = textures, .objects = objects };
}

pub fn encodeArtifact(allocator: std.mem.Allocator, value: *const Scene) ![]u8 {
    try validate(value);
    const byte_count = try artifactByteCount(value);
    if (byte_count > max_artifact_bytes) return error.SceneArtifactTooLarge;
    const output = try allocator.alloc(u8, byte_count);
    errdefer allocator.free(output);
    _ = try writeArtifact(value, output);
    return output;
}

pub fn artifactByteCount(value: *const Scene) !usize {
    var payload_bytes: usize = 4;
    for (value.textures.slice()) |texture| {
        payload_bytes = try std.math.add(usize, payload_bytes, 8 + texture.artifact().len);
    }
    payload_bytes = try std.math.add(usize, payload_bytes, 4);
    for (value.objects.slice()) |object| {
        payload_bytes = try std.math.add(usize, payload_bytes, 4 + objectEntryBytes(&object));
    }
    return try std.math.add(usize, scene_artifact_header_bytes, payload_bytes);
}

pub fn writeArtifact(value: *const Scene, output: []u8) ![]u8 {
    try validate(value);
    const byte_count = try artifactByteCount(value);
    if (output.len != byte_count) return error.InvalidSceneArtifactBuffer;
    @memcpy(output[0..4], "KSCN");
    writeLittleU32(output[4..8], scene_artifact_version);
    writeLittleU32(output[8..12], current_schema_version);
    writeLittleU32(output[12..16], @intCast(byte_count - scene_artifact_header_bytes));
    var cursor: usize = scene_artifact_header_bytes;
    writeLittleU32(output[cursor..][0..4], value.textures.count);
    cursor += 4;
    for (value.textures.slice()) |texture| {
        writeLittleU32(output[cursor..][0..4], texture.textureId);
        writeLittleU32(output[cursor + 4 ..][0..4], texture.artifactBytes);
        cursor += 8;
        @memcpy(output[cursor .. cursor + texture.artifactBytes], texture.artifact());
        cursor += texture.artifactBytes;
    }
    writeLittleU32(output[cursor..][0..4], value.objects.count);
    cursor += 4;
    for (value.objects.slice()) |object| {
        const entry_bytes = objectEntryBytes(&object);
        writeLittleU32(output[cursor..][0..4], @intCast(entry_bytes));
        cursor += 4;
        writeLittleU32(output[cursor..][0..4], @intFromEnum(object.kind));
        writeLittleU32(output[cursor + 4 ..][0..4], object.objectId.byte_count);
        cursor += 8;
        @memcpy(output[cursor .. cursor + object.objectId.byte_count], object.objectId.slice());
        cursor += object.objectId.byte_count;
        for (object.sprite.position ++ object.sprite.size ++ object.sprite.color) |number| {
            writeLittleF32(output[cursor..][0..4], number);
            cursor += 4;
        }
        writeLittleU32(output[cursor..][0..4], object.sprite.textureId);
        cursor += 4;
        switch (object.kind) {
            .sprite, .goal => {},
            .player => {
                writeLittleF32(output[cursor..][0..4], object.player.moveSpeed);
                cursor += 4;
            },
            .patrol_hazard => {
                writeLittleF32(output[cursor..][0..4], object.patrol.minY);
                writeLittleF32(output[cursor + 4 ..][0..4], object.patrol.maxY);
                writeLittleF32(output[cursor + 8 ..][0..4], object.patrol.speed);
                cursor += 12;
            },
        }
    }
    std.debug.assert(cursor == output.len);
    return output;
}

fn objectEntryBytes(object: *const SceneObject) usize {
    const payload_bytes: usize = switch (object.kind) {
        .sprite, .goal => 0,
        .player => 4,
        .patrol_hazard => 12,
    };
    return 4 + 4 + object.objectId.byte_count + 8 * 4 + 4 + payload_bytes;
}

fn parseArtifact(source: []const u8) !Scene {
    if (source.len < scene_artifact_header_bytes) return error.InvalidSceneArtifact;
    if (!std.mem.eql(u8, source[0..4], "KSCN")) return error.InvalidSceneArtifact;
    const artifact_version = readLittleU32(source[4..8]);
    const schema_version = readLittleU32(source[8..12]);
    const payload_bytes = readLittleU32(source[12..16]);
    if (source.len != scene_artifact_header_bytes + @as(usize, payload_bytes)) return error.InvalidSceneArtifact;
    return switch (artifact_version) {
        1, 2, 3 => parseLegacyArtifact(source, artifact_version, schema_version, payload_bytes),
        scene_artifact_version => parseArtifactV4(source, schema_version),
        else => error.UnsupportedSceneArtifactVersion,
    };
}

fn parseLegacyArtifact(source: []const u8, artifact_version: u32, schema_version: u32, payload_bytes: u32) !Scene {
    if (schema_version != artifact_version) return error.UnsupportedSceneSchema;
    if (artifact_version == 1 and payload_bytes != scene_artifact_v1_payload_bytes) return error.InvalidSceneArtifact;
    if (artifact_version == 2 and payload_bytes != scene_artifact_v2_payload_bytes) return error.InvalidSceneArtifact;
    if (artifact_version == 3 and payload_bytes < scene_artifact_v2_payload_bytes + 4) return error.InvalidSceneArtifact;

    const offset = scene_artifact_header_bytes;
    const player = LegacyPlayer{
        .position = .{ readLittleF32(source[offset..][0..4]), readLittleF32(source[offset + 4 ..][0..4]) },
        .size = .{ readLittleF32(source[offset + 8 ..][0..4]), readLittleF32(source[offset + 12 ..][0..4]) },
        .color = .{ readLittleF32(source[offset + 16 ..][0..4]), readLittleF32(source[offset + 20 ..][0..4]), readLittleF32(source[offset + 24 ..][0..4]), readLittleF32(source[offset + 28 ..][0..4]) },
        .moveSpeed = readLittleF32(source[offset + 32 ..][0..4]),
        .textureId = 0,
    };
    const goal = Sprite{
        .position = .{ readLittleF32(source[offset + 36 ..][0..4]), readLittleF32(source[offset + 40 ..][0..4]) },
        .size = .{ readLittleF32(source[offset + 44 ..][0..4]), readLittleF32(source[offset + 48 ..][0..4]) },
        .color = .{ readLittleF32(source[offset + 52 ..][0..4]), readLittleF32(source[offset + 56 ..][0..4]), readLittleF32(source[offset + 60 ..][0..4]), readLittleF32(source[offset + 64 ..][0..4]) },
        .textureId = 0,
    };
    const hazard = LegacyHazard{
        .position = .{ readLittleF32(source[offset + 68 ..][0..4]), readLittleF32(source[offset + 72 ..][0..4]) },
        .size = .{ readLittleF32(source[offset + 76 ..][0..4]), readLittleF32(source[offset + 80 ..][0..4]) },
        .color = .{ readLittleF32(source[offset + 84 ..][0..4]), readLittleF32(source[offset + 88 ..][0..4]), readLittleF32(source[offset + 92 ..][0..4]), readLittleF32(source[offset + 96 ..][0..4]) },
        .patrolMinY = readLittleF32(source[offset + 100 ..][0..4]),
        .patrolMaxY = readLittleF32(source[offset + 104 ..][0..4]),
        .patrolSpeed = readLittleF32(source[offset + 108 ..][0..4]),
        .textureId = 0,
    };

    var textures = defaultTextureSet();
    var texture_ids: [3]u32 = .{ 1, 2, 1 };
    if (artifact_version >= 2) {
        const texture_offset = scene_artifact_header_bytes + scene_artifact_v1_payload_bytes;
        texture_ids = .{
            readLittleU32(source[texture_offset..][0..4]),
            readLittleU32(source[texture_offset + 4 ..][0..4]),
            readLittleU32(source[texture_offset + 8 ..][0..4]),
        };
    }
    if (artifact_version < 3) {
        textures.count = 2;
    } else {
        var reader = ByteReader{ .source = source, .cursor = scene_artifact_header_bytes + scene_artifact_v2_payload_bytes };
        textures = try readTextureSet(&reader);
        if (!reader.atEnd()) return error.InvalidSceneArtifact;
    }
    var normalized_player = player;
    var normalized_goal = goal;
    var normalized_hazard = hazard;
    normalized_player.textureId = texture_ids[0];
    normalized_goal.textureId = texture_ids[1];
    normalized_hazard.textureId = texture_ids[2];
    const value = normalizeLegacyScene(textures, normalized_player, normalized_goal, normalized_hazard);
    try validate(&value);
    return value;
}

fn parseArtifactV4(source: []const u8, schema_version: u32) !Scene {
    if (schema_version != current_schema_version) return error.UnsupportedSceneSchema;
    var reader = ByteReader{ .source = source, .cursor = scene_artifact_header_bytes };
    const textures = try readTextureSet(&reader);
    const object_count = try reader.readU32();
    if (object_count < min_scene_object_count or object_count > max_scene_object_count) return error.InvalidSceneObjectCount;
    var objects = SceneObjectSet{ .count = @intCast(object_count) };
    for (objects.mutableSlice()) |*object| {
        const entry_bytes = try reader.readU32();
        const entry_source = try reader.readBytes(entry_bytes);
        var entry = ByteReader{ .source = entry_source };
        const kind_value = try entry.readU32();
        const kind: ObjectKind = switch (kind_value) {
            1 => .sprite,
            2 => .player,
            3 => .goal,
            4 => .patrol_hazard,
            else => return error.InvalidSceneObjectKind,
        };
        const object_id_bytes = try entry.readU32();
        const object_id = try ObjectId.init(try entry.readBytes(object_id_bytes));
        const sprite = Sprite{
            .position = .{ try entry.readF32(), try entry.readF32() },
            .size = .{ try entry.readF32(), try entry.readF32() },
            .color = .{ try entry.readF32(), try entry.readF32(), try entry.readF32(), try entry.readF32() },
            .textureId = try entry.readU32(),
        };
        object.* = .{ .objectId = object_id, .kind = kind, .sprite = sprite };
        switch (kind) {
            .sprite, .goal => {},
            .player => object.player.moveSpeed = try entry.readF32(),
            .patrol_hazard => object.patrol = .{
                .minY = try entry.readF32(),
                .maxY = try entry.readF32(),
                .speed = try entry.readF32(),
            },
        }
        if (!entry.atEnd()) return error.InvalidSceneObjectPayload;
    }
    if (!reader.atEnd()) return error.InvalidSceneArtifact;
    const value = Scene{ .textures = textures, .objects = objects };
    try validate(&value);
    return value;
}

const ByteReader = struct {
    source: []const u8,
    cursor: usize = 0,

    fn readBytes(self: *ByteReader, byte_count: usize) ![]const u8 {
        const end = std.math.add(usize, self.cursor, byte_count) catch return error.InvalidSceneArtifact;
        if (end > self.source.len) return error.InvalidSceneArtifact;
        const bytes = self.source[self.cursor..end];
        self.cursor = end;
        return bytes;
    }

    fn readU32(self: *ByteReader) !u32 {
        return readLittleU32(try self.readBytes(4));
    }

    fn readF32(self: *ByteReader) !f32 {
        return @bitCast(try self.readU32());
    }

    fn atEnd(self: *const ByteReader) bool {
        return self.cursor == self.source.len;
    }
};

fn readTextureSet(reader: *ByteReader) !TextureSet {
    const texture_count = try reader.readU32();
    if (texture_count == 0 or texture_count > max_texture_count) return error.InvalidTextureSetCount;
    var textures = TextureSet{ .count = @intCast(texture_count) };
    for (textures.entries[0..textures.count]) |*entry| {
        const texture_id = try reader.readU32();
        const artifact_bytes = try reader.readU32();
        if (artifact_bytes == 0 or artifact_bytes > max_texture_artifact_bytes) return error.InvalidTextureArtifact;
        entry.* = makeTextureSpec(texture_id, try reader.readBytes(artifact_bytes));
    }
    return textures;
}

pub fn validate(value: *const Scene) !void {
    if (value.schemaVersion != current_schema_version) return error.UnsupportedSceneSchema;
    if (value.textures.count == 0 or value.textures.count > max_texture_count) return error.InvalidTextureSetCount;
    for (value.textures.slice(), 0..) |entry, index| {
        if (entry.textureId == 0) return error.InvalidTextureId;
        try validateTextureArtifact(entry.artifact());
        for (value.textures.slice()[0..index]) |previous| {
            if (previous.textureId == entry.textureId) return error.DuplicateTextureId;
        }
    }
    if (value.objects.count < min_scene_object_count or value.objects.count > max_scene_object_count) {
        return error.InvalidSceneObjectCount;
    }
    var player_count: usize = 0;
    var goal_count: usize = 0;
    var hazard_count: usize = 0;
    for (value.objects.slice(), 0..) |object, index| {
        try validateObjectIdBytes(object.objectId.slice());
        for (value.objects.slice()[0..index]) |previous| {
            if (object.objectId.eql(&previous.objectId)) return error.DuplicateSceneObjectId;
        }
        try validateSprite(object.sprite.position, object.sprite.size, object.sprite.color);
        if (object.sprite.textureId == 0) return error.InvalidTextureId;
        if (!value.textures.contains(object.sprite.textureId)) return error.UnknownSceneTexture;
        switch (object.kind) {
            .sprite => {},
            .player => {
                player_count += 1;
                if (!std.math.isFinite(object.player.moveSpeed) or object.player.moveSpeed < 0.0) {
                    return error.InvalidPlayerMoveSpeed;
                }
            },
            .goal => goal_count += 1,
            .patrol_hazard => {
                hazard_count += 1;
                if (!std.math.isFinite(object.patrol.minY) or
                    !std.math.isFinite(object.patrol.maxY) or
                    !std.math.isFinite(object.patrol.speed) or
                    object.patrol.minY >= object.patrol.maxY or
                    object.patrol.speed < 0.0 or
                    object.sprite.position[1] < object.patrol.minY or
                    object.sprite.position[1] > object.patrol.maxY)
                {
                    return error.InvalidHazardPatrol;
                }
            },
        }
    }
    if (player_count != 1 or goal_count != 1 or hazard_count == 0) return error.InvalidSceneRoleCount;
}

fn validateObjectIdBytes(bytes: []const u8) !void {
    if (bytes.len == 0 or bytes.len > max_object_id_bytes) return error.InvalidSceneObjectId;
    if (bytes[0] < 'a' or bytes[0] > 'z') return error.InvalidSceneObjectId;
    for (bytes[1..]) |byte| {
        const valid = (byte >= 'a' and byte <= 'z') or
            (byte >= '0' and byte <= '9') or
            byte == '_' or byte == '-';
        if (!valid) return error.InvalidSceneObjectId;
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
    for (position) |number| {
        if (!std.math.isFinite(number)) return error.InvalidSpritePosition;
    }
    for (size) |number| {
        if (!std.math.isFinite(number) or number <= 0.0) return error.InvalidSpriteSize;
    }
    for (color) |number| {
        if (!std.math.isFinite(number) or number < 0.0 or number > 1.0) return error.InvalidSpriteColor;
    }
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

fn writeLittleU32(bytes: []u8, value: u32) void {
    bytes[0] = @truncate(value);
    bytes[1] = @truncate(value >> 8);
    bytes[2] = @truncate(value >> 16);
    bytes[3] = @truncate(value >> 24);
}

fn writeLittleF32(bytes: []u8, value: f32) void {
    writeLittleU32(bytes, @bitCast(value));
}

fn makeLegacyArtifact(allocator: std.mem.Allocator, version: u32) ![]u8 {
    const player = default_scene.player();
    const goal = default_scene.goal();
    const hazard = default_scene.primaryHazard();
    var payload_bytes: usize = switch (version) {
        1 => scene_artifact_v1_payload_bytes,
        2 => scene_artifact_v2_payload_bytes,
        3 => scene_artifact_v2_payload_bytes + 4,
        else => unreachable,
    };
    if (version == 3) {
        for (default_scene.textures.slice()) |texture| payload_bytes += 8 + texture.artifact().len;
    }
    const artifact = try allocator.alloc(u8, scene_artifact_header_bytes + payload_bytes);
    @memcpy(artifact[0..4], "KSCN");
    writeLittleU32(artifact[4..8], version);
    writeLittleU32(artifact[8..12], version);
    writeLittleU32(artifact[12..16], @intCast(payload_bytes));
    const values = [_]f32{
        player.sprite.position[0], player.sprite.position[1], player.sprite.size[0],     player.sprite.size[1],
        player.sprite.color[0],    player.sprite.color[1],    player.sprite.color[2],    player.sprite.color[3],
        player.player.moveSpeed,   goal.sprite.position[0],   goal.sprite.position[1],   goal.sprite.size[0],
        goal.sprite.size[1],       goal.sprite.color[0],      goal.sprite.color[1],      goal.sprite.color[2],
        goal.sprite.color[3],      hazard.sprite.position[0], hazard.sprite.position[1], hazard.sprite.size[0],
        hazard.sprite.size[1],     hazard.sprite.color[0],    hazard.sprite.color[1],    hazard.sprite.color[2],
        hazard.sprite.color[3],    hazard.patrol.minY,        hazard.patrol.maxY,        hazard.patrol.speed,
    };
    for (values, 0..) |number, index| writeLittleF32(artifact[16 + index * 4 ..][0..4], number);
    if (version >= 2) {
        writeLittleU32(artifact[128..132], player.sprite.textureId);
        writeLittleU32(artifact[132..136], goal.sprite.textureId);
        writeLittleU32(artifact[136..140], if (version == 2) 1 else hazard.sprite.textureId);
    }
    if (version == 3) {
        var cursor: usize = 140;
        writeLittleU32(artifact[cursor..][0..4], default_scene.textures.count);
        cursor += 4;
        for (default_scene.textures.slice()) |texture| {
            writeLittleU32(artifact[cursor..][0..4], texture.textureId);
            writeLittleU32(artifact[cursor + 4 ..][0..4], texture.artifactBytes);
            cursor += 8;
            @memcpy(artifact[cursor .. cursor + texture.artifactBytes], texture.artifact());
            cursor += texture.artifactBytes;
        }
    }
    return artifact;
}

test "scene v4 parses ordered objects" {
    const contents =
        \\{"schemaVersion":4,"textures":[{"textureId":1,"artifact":"assets/renderer2d/test.texture"}],"objects":[
        \\{"objectId":"goal","kind":"goal","transform":{"position":[10,20]},"sprite":{"size":[3,4],"color":[1,1,1,1],"textureId":1}},
        \\{"objectId":"hazard-1","kind":"patrol_hazard","transform":{"position":[30,40]},"sprite":{"size":[5,6],"color":[1,0,0,1],"textureId":1},"patrol":{"minY":20,"maxY":60,"speed":7}},
        \\{"objectId":"player","kind":"player","transform":{"position":[1,2]},"sprite":{"size":[8,9],"color":[1,1,1,1],"textureId":1},"player":{"moveSpeed":10}}]}
    ;
    const value = try parse(std.testing.allocator, contents);
    try std.testing.expectEqual(@as(usize, 3), value.objects.slice().len);
    try std.testing.expectEqualStrings("goal", value.objects.entries[0].objectId.slice());
    try std.testing.expectEqualStrings("hazard-1", value.objects.entries[1].objectId.slice());
    try std.testing.expectEqual(@as(f32, 10.0), value.player().player.moveSpeed);
}

test "scene v3 normalizes fixed roles to objects" {
    const contents =
        \\{"schemaVersion":3,"textures":[{"textureId":1,"artifact":"assets/renderer2d/test.texture"},{"textureId":2,"artifact":"assets/renderer2d/goal.texture"}],
        \\"player":{"position":[0,0],"size":[1,1],"color":[1,1,1,1],"moveSpeed":2,"textureId":1},
        \\"goal":{"position":[2,0],"size":[1,1],"color":[1,1,1,1],"textureId":2},
        \\"hazard":{"position":[4,1],"size":[1,1],"color":[1,0,0,1],"patrolMinY":0,"patrolMaxY":2,"patrolSpeed":3,"textureId":1}}
    ;
    const value = try parse(std.testing.allocator, contents);
    try std.testing.expectEqual(current_schema_version, value.schemaVersion);
    try std.testing.expectEqualStrings("player", value.objects.entries[0].objectId.slice());
    try std.testing.expectEqualStrings("goal", value.objects.entries[1].objectId.slice());
    try std.testing.expectEqualStrings("hazard", value.objects.entries[2].objectId.slice());
}

test "scene v4 validates identity payload and role invariants" {
    var value = default_scene;
    value.objects.count = 2;
    try std.testing.expectError(error.InvalidSceneObjectCount, validate(&value));
    value = default_scene;
    value.objects.entries[1].objectId = objectIdLiteral("hazard-1");
    try std.testing.expectError(error.DuplicateSceneObjectId, validate(&value));
    value = default_scene;
    value.objects.entries[4].kind = .sprite;
    try std.testing.expectError(error.InvalidSceneRoleCount, validate(&value));
    value = default_scene;
    value.objects.entries[2].patrol.minY = value.objects.entries[2].patrol.maxY;
    try std.testing.expectError(error.InvalidHazardPatrol, validate(&value));

    value = default_scene;
    for (value.objects.entries[5..], 5..) |*object, index| {
        var object_id_buffer: [16]u8 = undefined;
        const object_id = try std.fmt.bufPrint(&object_id_buffer, "sprite-{d}", .{index});
        object.* = .{
            .objectId = try ObjectId.init(object_id),
            .kind = .sprite,
            .sprite = .{ .textureId = 1 },
        };
    }
    value.objects.count = max_scene_object_count;
    try validate(&value);

    try std.testing.expectError(error.InvalidSceneObjectId, ObjectId.init("1player"));
    try std.testing.expectError(error.InvalidSceneObjectId, ObjectId.init("Player"));
}

test "KSCN v4 round trips object order and payloads" {
    const artifact = try encodeArtifact(std.testing.allocator, &default_scene);
    defer std.testing.allocator.free(artifact);
    try std.testing.expectEqual(scene_artifact_version, readLittleU32(artifact[4..8]));
    const value = try parseArtifact(artifact);
    try std.testing.expectEqual(default_scene.objects.count, value.objects.count);
    try std.testing.expectEqualStrings("decoration-1", value.objects.entries[0].objectId.slice());
    try std.testing.expectEqual(default_scene.primaryHazard().patrol.speed, value.primaryHazard().patrol.speed);
    try std.testing.expectEqual(default_scene.player().sprite.textureId, value.player().sprite.textureId);
}

test "KSCN v4 rejects truncated entry and trailing bytes" {
    const artifact = try encodeArtifact(std.testing.allocator, &default_scene);
    defer std.testing.allocator.free(artifact);
    try std.testing.expectError(error.InvalidSceneArtifact, parseArtifact(artifact[0 .. artifact.len - 1]));
    var mutated = try std.testing.allocator.dupe(u8, artifact);
    defer std.testing.allocator.free(mutated);
    const first_entry_offset = 16 + 4 +
        (8 + primary_texture_artifact.len) +
        (8 + secondary_texture_artifact.len) +
        (8 + secondary_texture_artifact.len) + 4;
    writeLittleU32(mutated[first_entry_offset..][0..4], readLittleU32(mutated[first_entry_offset..][0..4]) + 1);
    try std.testing.expectError(error.InvalidSceneObjectPayload, parseArtifact(mutated));
}

test "KSCN v1 through v3 normalize legacy object identities" {
    for (1..4) |version| {
        const artifact = try makeLegacyArtifact(std.testing.allocator, @intCast(version));
        defer std.testing.allocator.free(artifact);
        const loaded = try parseArtifactWithIdentity(artifact);
        try std.testing.expectEqual(@as(?u32, @intCast(version)), loaded.artifact_version);
        try std.testing.expectEqualStrings("player", loaded.value.objects.entries[0].objectId.slice());
        try std.testing.expectEqualStrings("goal", loaded.value.objects.entries[1].objectId.slice());
        try std.testing.expectEqualStrings("hazard", loaded.value.objects.entries[2].objectId.slice());
    }
}

test "scene identity is computed from the validated source buffer" {
    const contents =
        \\{"schemaVersion":3,"textures":[{"textureId":1,"artifact":"assets/renderer2d/test.texture"},{"textureId":2,"artifact":"assets/renderer2d/goal.texture"}],
        \\"player":{"position":[0,0],"size":[1,1],"color":[1,1,1,1],"moveSpeed":2,"textureId":1},
        \\"goal":{"position":[2,0],"size":[1,1],"color":[1,1,1,1],"textureId":2},
        \\"hazard":{"position":[4,1],"size":[1,1],"color":[1,0,0,1],"patrolMinY":0,"patrolMaxY":2,"patrolSpeed":3,"textureId":1}}
    ;
    const loaded = try parseWithIdentity(std.testing.allocator, contents, .source_document);
    const expected = try content_identity.ContentIdentity.fromBytes(.source_document, contents);
    try std.testing.expectEqual(expected, loaded.identity);
}
