const std = @import("std");
const content_identity = @import("content_identity.zig");

pub const current_schema_version: u32 = 9;
pub const tilemap_schema_version: u32 = 8;
pub const gameplay_schema_version: u32 = 7;
pub const prototype_schema_version: u32 = 6;
pub const behavior_schema_version: u32 = 5;
pub const legacy_object_schema_version: u32 = 4;
pub const scene_artifact_version: u32 = 9;
pub const tilemap_artifact_version: u32 = 8;
pub const gameplay_artifact_version: u32 = 7;
pub const prototype_artifact_version: u32 = 6;
pub const behavior_artifact_version: u32 = 5;
pub const legacy_object_artifact_version: u32 = 4;
pub const max_texture_count: usize = 4;
pub const max_texture_artifact_bytes: usize = 255;
pub const min_scene_object_count: usize = 3;
pub const max_scene_object_count: usize = 64;
pub const max_object_id_bytes: usize = 63;
pub const max_behavior_bindings_per_object: usize = 4;
pub const max_behavior_binding_count: usize = 256;
pub const max_behavior_parameter_count: usize = 16;
pub const max_behavior_parameter_name_bytes: usize = 63;
pub const max_spawn_prototype_count: usize = 32;
pub const max_prototype_behavior_binding_count: usize = 128;
pub const max_tilemap_count: usize = 1;
pub const max_tilemap_columns: usize = 32;
pub const max_tilemap_rows: usize = 32;
pub const max_tilemap_cell_count: usize = max_tilemap_columns * max_tilemap_rows;
pub const max_tilemap_atlas_dimension: usize = 256;
pub const max_tilemap_atlas_tiles: usize = std.math.maxInt(u16);
pub const min_neutral_scene_object_count: usize = 1;

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

pub const PrototypeId = struct {
    byte_count: u8 = 0,
    storage: [max_object_id_bytes]u8 = [_]u8{0} ** max_object_id_bytes,

    pub fn init(bytes: []const u8) !PrototypeId {
        try validateObjectIdBytes(bytes);
        var value = PrototypeId{ .byte_count = @intCast(bytes.len) };
        @memcpy(value.storage[0..bytes.len], bytes);
        return value;
    }

    pub fn slice(self: *const PrototypeId) []const u8 {
        return self.storage[0..self.byte_count];
    }
};

pub const BehaviorParameter = struct {
    nameBytes: u8 = 0,
    nameStorage: [max_behavior_parameter_name_bytes]u8 = [_]u8{0} ** max_behavior_parameter_name_bytes,
    value: f64 = 0,

    pub fn name(self: *const BehaviorParameter) []const u8 {
        return self.nameStorage[0..self.nameBytes];
    }
};

pub const BehaviorBinding = struct {
    scriptId: u32 = 0,
    parameterCount: u8 = 0,
    parameters: [max_behavior_parameter_count]BehaviorParameter = [_]BehaviorParameter{.{}} ** max_behavior_parameter_count,

    pub fn parameterSlice(self: *const BehaviorBinding) []const BehaviorParameter {
        return self.parameters[0..self.parameterCount];
    }
};

pub const BehaviorBindingSet = struct {
    count: u8 = 0,
    entries: [max_behavior_bindings_per_object]BehaviorBinding = [_]BehaviorBinding{.{}} ** max_behavior_bindings_per_object,

    pub fn slice(self: *const BehaviorBindingSet) []const BehaviorBinding {
        return self.entries[0..self.count];
    }
};

pub const SceneObject = struct {
    objectId: ObjectId = .{},
    kind: ObjectKind = .sprite,
    sprite: Sprite = .{},
    player: PlayerPayload = .{},
    patrol: PatrolPayload = .{},
    behaviors: BehaviorBindingSet = .{},
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

pub const SpawnPrototype = struct {
    prototypeId: PrototypeId = .{},
    kind: ObjectKind = .sprite,
    sprite: Sprite = .{},
    behaviors: BehaviorBindingSet = .{},
};

pub const SpawnPrototypeSet = struct {
    count: u8 = 0,
    entries: [max_spawn_prototype_count]SpawnPrototype = [_]SpawnPrototype{.{}} ** max_spawn_prototype_count,

    pub fn slice(self: *const SpawnPrototypeSet) []const SpawnPrototype {
        return self.entries[0..self.count];
    }

    pub fn indexOfId(self: *const SpawnPrototypeSet, prototype_id: []const u8) ?usize {
        for (self.slice(), 0..) |prototype, index| {
            if (std.mem.eql(u8, prototype.prototypeId.slice(), prototype_id)) return index;
        }
        return null;
    }
};

pub const TextureSpec = struct {
    textureId: u32 = 0,
    artifactBytes: u16 = 0,
    artifactStorage: [max_texture_artifact_bytes]u8 = [_]u8{0} ** max_texture_artifact_bytes,
    samplingProfile: TextureSamplingProfile = .smooth_mipmap_anisotropic,

    pub fn artifact(self: *const TextureSpec) []const u8 {
        return self.artifactStorage[0..self.artifactBytes];
    }
};

pub const TextureSamplingProfile = enum(u32) {
    pixel_art = 1,
    smooth_linear = 2,
    smooth_mipmap = 3,
    smooth_mipmap_anisotropic = 4,
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

    pub fn find(self: *const TextureSet, texture_id: u32) ?*const TextureSpec {
        for (self.slice()) |*entry| {
            if (entry.textureId == texture_id) return entry;
        }
        return null;
    }
};

pub const GameplayProfile = enum(u32) {
    none = 0,
    goal_hazard_v1 = 1,
};

pub const GameplayConfig = struct {
    profile: GameplayProfile = .none,
    timeLimitSeconds: f32 = 0,
};

pub const TilemapId = struct {
    byte_count: u8 = 0,
    storage: [max_object_id_bytes]u8 = [_]u8{0} ** max_object_id_bytes,

    pub fn init(bytes: []const u8) !TilemapId {
        validateObjectIdBytes(bytes) catch return error.InvalidTilemapId;
        var value = TilemapId{ .byte_count = @intCast(bytes.len) };
        @memcpy(value.storage[0..bytes.len], bytes);
        return value;
    }

    pub fn slice(self: *const TilemapId) []const u8 {
        return self.storage[0..self.byte_count];
    }
};

pub const Tilemap = struct {
    tilemapId: TilemapId = .{},
    origin: [2]f32 = .{ 0, 0 },
    tileSize: [2]f32 = .{ 1, 1 },
    columns: u32 = 1,
    rows: u32 = 1,
    textureId: u32 = 0,
    atlasColumns: u32 = 1,
    atlasRows: u32 = 1,
    cells: [max_tilemap_cell_count]u16 = [_]u16{0} ** max_tilemap_cell_count,

    pub fn cellSlice(self: *const Tilemap) []const u16 {
        const count: usize = @intCast(self.columns * self.rows);
        return self.cells[0..count];
    }
};

pub const TilemapSet = struct {
    count: u8 = 0,
    entries: [max_tilemap_count]Tilemap = [_]Tilemap{.{}} ** max_tilemap_count,

    pub fn slice(self: *const TilemapSet) []const Tilemap {
        return self.entries[0..self.count];
    }
};

pub const Camera2DConfig = struct {
    // 相机原点是视口左上角对应的世界坐标；默认值保持 v4-v8 的像素输出不变。
    origin: [2]f32 = .{ 0.0, 0.0 },
    zoom: f32 = 1.0,
};

// 旧 Demo 玩法的显式配置；v7 夹具和调用方不能再借 schema 版本隐式启用 Gameplay。
pub const goal_hazard_v1_gameplay = GameplayConfig{
    .profile = .goal_hazard_v1,
    .timeLimitSeconds = 3,
};

pub const Scene = struct {
    schemaVersion: u32 = current_schema_version,
    textures: TextureSet,
    objects: SceneObjectSet,
    prototypes: SpawnPrototypeSet = .{},
    gameplay: GameplayConfig = .{},
    tilemaps: TilemapSet = .{},
    camera: Camera2DConfig = .{},

    pub fn gameplayProfile(self: *const Scene) GameplayProfile {
        // v4-v6 的 wire 没有显式 profile；兼容 Adapter 必须保持旧 Demo 语义。
        return if (self.schemaVersion < gameplay_schema_version) .goal_hazard_v1 else self.gameplay.profile;
    }

    pub fn gameplayEnabled(self: *const Scene) bool {
        return self.gameplayProfile() != .none;
    }

    pub fn supportsBehaviorRuntime(self: *const Scene) bool {
        return schemaHasBehaviorBindings(self.schemaVersion);
    }

    pub fn supportsSpawnPrototypes(self: *const Scene) bool {
        return schemaHasSpawnPrototypes(self.schemaVersion);
    }

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

const WireTextureSpecV8 = struct {
    textureId: u32,
    artifact: []const u8,
    samplingProfile: TextureSamplingProfile,
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

const WireBehaviorBinding = struct {
    scriptId: u32,
    parameters: std.json.ArrayHashMap(f64),
};

const WireSceneObjectV5 = struct {
    objectId: []const u8,
    kind: ObjectKind,
    transform: WireTransform,
    sprite: WireSprite,
    player: ?WirePlayerPayload = null,
    patrol: ?WirePatrolPayload = null,
    behaviors: ?[]const WireBehaviorBinding = null,
};

const WireSceneV5 = struct {
    schemaVersion: u32,
    textures: []const WireTextureSpec,
    objects: []const WireSceneObjectV5,
};

const WireSpawnPrototype = struct {
    prototypeId: []const u8,
    kind: ObjectKind,
    sprite: WireSprite,
    behaviors: []const WireBehaviorBinding,
};

const WireSceneV6 = struct {
    schemaVersion: u32,
    textures: []const WireTextureSpec,
    objects: []const WireSceneObjectV5,
    prototypes: []const WireSpawnPrototype,
};

const WireGameplayConfig = struct {
    profile: GameplayProfile,
    timeLimitSeconds: f32,
};

const WireSceneV7 = struct {
    schemaVersion: u32,
    textures: []const WireTextureSpec,
    objects: []const WireSceneObjectV5,
    prototypes: []const WireSpawnPrototype,
    gameplay: ?WireGameplayConfig = null,
};

const WireTilemap = struct {
    tilemapId: []const u8,
    origin: [2]f32,
    tileSize: [2]f32,
    columns: u32,
    rows: u32,
    textureId: u32,
    atlasColumns: u32,
    atlasRows: u32,
    cells: []const u16,
};

const WireSceneV8 = struct {
    schemaVersion: u32,
    textures: []const WireTextureSpecV8,
    objects: []const WireSceneObjectV5,
    prototypes: []const WireSpawnPrototype,
    gameplay: ?WireGameplayConfig = null,
    tilemaps: []const WireTilemap,
};

const WireCamera2D = struct {
    origin: [2]f32,
    zoom: f32,
};

const WireSceneV9 = struct {
    schemaVersion: u32,
    textures: []const WireTextureSpecV8,
    objects: []const WireSceneObjectV5,
    prototypes: []const WireSpawnPrototype,
    gameplay: ?WireGameplayConfig = null,
    tilemaps: []const WireTilemap,
    camera: WireCamera2D,
};

const SchemaProbe = struct {
    schemaVersion: u32,
};

fn makeTextureSpec(texture_id: u32, artifact: []const u8) TextureSpec {
    var spec = TextureSpec{ .textureId = texture_id, .artifactBytes = @intCast(artifact.len) };
    @memcpy(spec.artifactStorage[0..artifact.len], artifact);
    return spec;
}

fn makeTextureSpecWithProfile(texture_id: u32, artifact: []const u8, sampling_profile: TextureSamplingProfile) TextureSpec {
    var spec = makeTextureSpec(texture_id, artifact);
    spec.samplingProfile = sampling_profile;
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
    .schemaVersion = legacy_object_schema_version,
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
    var value: Scene = undefined;
    try parseInto(allocator, contents, &value);
    return .{
        .value = value,
        .identity = try content_identity.ContentIdentity.fromBytes(kind, contents),
        .artifact_version = null,
    };
}

fn parseArtifactWithIdentity(contents: []const u8) !LoadedScene {
    var value: Scene = undefined;
    try parseArtifactInto(contents, &value);
    return .{
        .value = value,
        .identity = try content_identity.ContentIdentity.fromBytes(.artifact, contents),
        .artifact_version = readLittleU32(contents[4..8]),
    };
}

pub fn parse(allocator: std.mem.Allocator, contents: []const u8) !Scene {
    var value: Scene = undefined;
    try parseInto(allocator, contents, &value);
    return value;
}

fn parseInto(allocator: std.mem.Allocator, contents: []const u8, output: *Scene) !void {
    const probe = try std.json.parseFromSlice(SchemaProbe, allocator, contents, .{ .ignore_unknown_fields = true });
    defer probe.deinit();
    switch (probe.value.schemaVersion) {
        3 => output.* = try parseSourceV3(allocator, contents),
        legacy_object_schema_version => output.* = try parseSourceV4(allocator, contents),
        behavior_schema_version => try parseSourceV5Into(allocator, contents, output),
        prototype_schema_version => try parseSourceV6Into(allocator, contents, output),
        gameplay_schema_version => try parseSourceV7Into(allocator, contents, output),
        tilemap_schema_version => try parseSourceV8Into(allocator, contents, output),
        current_schema_version => try parseSourceV9Into(allocator, contents, output),
        else => return error.UnsupportedSceneSchema,
    }
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
    if (parsed.value.schemaVersion != legacy_object_schema_version) return error.UnsupportedSceneSchema;
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
    const value = Scene{ .schemaVersion = legacy_object_schema_version, .textures = textures, .objects = objects };
    try validate(&value);
    return value;
}

fn parseSourceV5Into(allocator: std.mem.Allocator, contents: []const u8, output: *Scene) !void {
    const parsed = try std.json.parseFromSlice(WireSceneV5, allocator, contents, .{});
    defer parsed.deinit();
    if (parsed.value.schemaVersion != behavior_schema_version) return error.UnsupportedSceneSchema;
    output.* = .{
        .schemaVersion = behavior_schema_version,
        .textures = try normalizeTextures(parsed.value.textures),
        .objects = undefined,
    };
    try normalizeBehaviorSceneObjectsInto(parsed.value.objects, min_scene_object_count, &output.objects);
    try validate(output);
}

fn parseSourceV6Into(allocator: std.mem.Allocator, contents: []const u8, output: *Scene) !void {
    const parsed = try std.json.parseFromSlice(WireSceneV6, allocator, contents, .{});
    defer parsed.deinit();
    if (parsed.value.schemaVersion != prototype_schema_version) return error.UnsupportedSceneSchema;
    output.* = .{
        .schemaVersion = prototype_schema_version,
        .textures = try normalizeTextures(parsed.value.textures),
        .objects = undefined,
    };
    try normalizeBehaviorSceneObjectsInto(parsed.value.objects, min_scene_object_count, &output.objects);
    if (parsed.value.prototypes.len > max_spawn_prototype_count) return error.SpawnPrototypeCountExceeded;
    output.prototypes.count = @intCast(parsed.value.prototypes.len);
    for (parsed.value.prototypes, 0..) |wire, index| {
        output.prototypes.entries[index] = .{
            .prototypeId = try PrototypeId.init(wire.prototypeId),
            .kind = wire.kind,
            .sprite = .{
                .size = wire.sprite.size,
                .color = wire.sprite.color,
                .textureId = wire.sprite.textureId,
            },
            .behaviors = try normalizeBehaviorBindings(wire.behaviors),
        };
    }
    try validate(output);
}

fn parseSourceV7Into(allocator: std.mem.Allocator, contents: []const u8, output: *Scene) !void {
    const parsed = try std.json.parseFromSlice(WireSceneV7, allocator, contents, .{});
    defer parsed.deinit();
    if (parsed.value.schemaVersion != gameplay_schema_version) return error.UnsupportedSceneSchema;
    const gameplay = if (parsed.value.gameplay) |wire|
        GameplayConfig{ .profile = wire.profile, .timeLimitSeconds = wire.timeLimitSeconds }
    else
        GameplayConfig{};
    output.* = .{
        .schemaVersion = gameplay_schema_version,
        .textures = try normalizeTextures(parsed.value.textures),
        .objects = undefined,
        .gameplay = gameplay,
    };
    try normalizeBehaviorSceneObjectsInto(parsed.value.objects, min_neutral_scene_object_count, &output.objects);
    if (parsed.value.prototypes.len > max_spawn_prototype_count) return error.SpawnPrototypeCountExceeded;
    output.prototypes.count = @intCast(parsed.value.prototypes.len);
    for (parsed.value.prototypes, 0..) |wire, index| {
        output.prototypes.entries[index] = .{
            .prototypeId = try PrototypeId.init(wire.prototypeId),
            .kind = wire.kind,
            .sprite = .{
                .size = wire.sprite.size,
                .color = wire.sprite.color,
                .textureId = wire.sprite.textureId,
            },
            .behaviors = try normalizeBehaviorBindings(wire.behaviors),
        };
    }
    try validate(output);
}

fn parseSourceV8Into(allocator: std.mem.Allocator, contents: []const u8, output: *Scene) !void {
    const parsed = try std.json.parseFromSlice(WireSceneV8, allocator, contents, .{});
    defer parsed.deinit();
    if (parsed.value.schemaVersion != tilemap_schema_version) return error.UnsupportedSceneSchema;
    try normalizeTilemapSceneSourceInto(parsed.value, tilemap_schema_version, .{}, output);
}

fn parseSourceV9Into(allocator: std.mem.Allocator, contents: []const u8, output: *Scene) !void {
    const parsed = try std.json.parseFromSlice(WireSceneV9, allocator, contents, .{});
    defer parsed.deinit();
    if (parsed.value.schemaVersion != current_schema_version) return error.UnsupportedSceneSchema;
    try normalizeTilemapSceneSourceInto(parsed.value, current_schema_version, .{
        .origin = parsed.value.camera.origin,
        .zoom = parsed.value.camera.zoom,
    }, output);
}

fn normalizeTilemapSceneSourceInto(wire_scene: anytype, schema_version: u32, camera: Camera2DConfig, output: *Scene) !void {
    // v8 与 v9 共享全部 Tilemap-era 归一化；Camera 只通过显式参数形成版本差异。
    const gameplay = if (wire_scene.gameplay) |wire|
        GameplayConfig{ .profile = wire.profile, .timeLimitSeconds = wire.timeLimitSeconds }
    else
        GameplayConfig{};
    output.* = .{
        .schemaVersion = schema_version,
        .textures = try normalizeTexturesV8(wire_scene.textures),
        .objects = undefined,
        .gameplay = gameplay,
        .camera = camera,
    };
    try normalizeBehaviorSceneObjectsInto(wire_scene.objects, min_neutral_scene_object_count, &output.objects);
    if (wire_scene.prototypes.len > max_spawn_prototype_count) return error.SpawnPrototypeCountExceeded;
    output.prototypes.count = @intCast(wire_scene.prototypes.len);
    for (wire_scene.prototypes, 0..) |wire, index| {
        output.prototypes.entries[index] = .{
            .prototypeId = try PrototypeId.init(wire.prototypeId),
            .kind = wire.kind,
            .sprite = .{
                .size = wire.sprite.size,
                .color = wire.sprite.color,
                .textureId = wire.sprite.textureId,
            },
            .behaviors = try normalizeBehaviorBindings(wire.behaviors),
        };
    }
    try normalizeTilemapsInto(wire_scene.tilemaps, &output.tilemaps);
    try validate(output);
}

fn normalizeTilemapsInto(wire_tilemaps: []const WireTilemap, output: *TilemapSet) !void {
    if (wire_tilemaps.len > max_tilemap_count) return error.TilemapCountExceeded;
    output.* = .{ .count = @intCast(wire_tilemaps.len) };
    for (wire_tilemaps, 0..) |wire, index| {
        if (wire.columns == 0 or wire.columns > max_tilemap_columns or
            wire.rows == 0 or wire.rows > max_tilemap_rows)
        {
            return error.InvalidTilemapDimensions;
        }
        const cell_count = std.math.mul(usize, @as(usize, wire.columns), @as(usize, wire.rows)) catch {
            return error.InvalidTilemapCellCount;
        };
        if (wire.cells.len != cell_count) return error.InvalidTilemapCellCount;
        output.entries[index] = .{
            .tilemapId = try TilemapId.init(wire.tilemapId),
            .origin = wire.origin,
            .tileSize = wire.tileSize,
            .columns = wire.columns,
            .rows = wire.rows,
            .textureId = wire.textureId,
            .atlasColumns = wire.atlasColumns,
            .atlasRows = wire.atlasRows,
        };
        @memcpy(output.entries[index].cells[0..cell_count], wire.cells);
    }
}

fn normalizeBehaviorSceneObjectsInto(wire_objects: []const WireSceneObjectV5, minimum_count: usize, output: *SceneObjectSet) !void {
    if (wire_objects.len < minimum_count or wire_objects.len > max_scene_object_count) {
        return error.InvalidSceneObjectCount;
    }
    output.* = .{ .count = @intCast(wire_objects.len) };
    for (wire_objects, 0..) |wire, index| {
        const object_id = try ObjectId.init(wire.objectId);
        const sprite = Sprite{
            .position = wire.transform.position,
            .size = wire.sprite.size,
            .color = wire.sprite.color,
            .textureId = wire.sprite.textureId,
        };
        const wire_behaviors = wire.behaviors orelse return error.MissingSceneBehaviors;
        const behaviors = try normalizeBehaviorBindings(wire_behaviors);
        output.entries[index] = switch (wire.kind) {
            .sprite, .goal => blk: {
                if (wire.player != null or wire.patrol != null) return error.InvalidSceneObjectPayload;
                break :blk .{ .objectId = object_id, .kind = wire.kind, .sprite = sprite, .behaviors = behaviors };
            },
            .player => blk: {
                if (wire.player == null or wire.patrol != null) return error.InvalidSceneObjectPayload;
                break :blk .{
                    .objectId = object_id,
                    .kind = wire.kind,
                    .sprite = sprite,
                    .player = .{ .moveSpeed = wire.player.?.moveSpeed },
                    .behaviors = behaviors,
                };
            },
            .patrol_hazard => blk: {
                if (wire.player != null or wire.patrol != null) return error.InvalidSceneObjectPayload;
                break :blk .{
                    .objectId = object_id,
                    .kind = wire.kind,
                    .sprite = sprite,
                    .behaviors = behaviors,
                };
            },
        };
    }
}

fn normalizeBehaviorBindings(wire_bindings: []const WireBehaviorBinding) !BehaviorBindingSet {
    if (wire_bindings.len > max_behavior_bindings_per_object) return error.ObjectBehaviorBindingCountExceeded;
    var bindings = BehaviorBindingSet{ .count = @intCast(wire_bindings.len) };
    for (wire_bindings, 0..) |wire, binding_index| {
        if (wire.scriptId == 0) return error.InvalidBehaviorScriptId;
        for (wire_bindings[0..binding_index]) |previous| {
            if (previous.scriptId == wire.scriptId) return error.DuplicateBehaviorBinding;
        }
        if (wire.parameters.map.count() > max_behavior_parameter_count) return error.BehaviorParameterCountExceeded;
        var binding = BehaviorBinding{ .scriptId = wire.scriptId };
        var iterator = wire.parameters.map.iterator();
        while (iterator.next()) |entry| {
            try insertBehaviorParameter(&binding, entry.key_ptr.*, entry.value_ptr.*);
        }
        bindings.entries[binding_index] = binding;
    }
    return bindings;
}

fn insertBehaviorParameter(binding: *BehaviorBinding, name: []const u8, value: f64) !void {
    try validateBehaviorParameterName(name);
    if (!std.math.isFinite(value)) return error.InvalidBehaviorParameter;
    if (binding.parameterCount >= max_behavior_parameter_count) return error.BehaviorParameterCountExceeded;
    var insert_index: usize = binding.parameterCount;
    while (insert_index > 0 and std.mem.lessThan(u8, name, binding.parameters[insert_index - 1].name())) {
        binding.parameters[insert_index] = binding.parameters[insert_index - 1];
        insert_index -= 1;
    }
    var parameter = BehaviorParameter{ .nameBytes = @intCast(name.len), .value = value };
    @memcpy(parameter.nameStorage[0..name.len], name);
    binding.parameters[insert_index] = parameter;
    binding.parameterCount += 1;
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

fn normalizeTexturesV8(wire_textures: []const WireTextureSpecV8) !TextureSet {
    if (wire_textures.len == 0 or wire_textures.len > max_texture_count) return error.InvalidTextureSetCount;
    var textures = TextureSet{ .count = @intCast(wire_textures.len) };
    for (wire_textures, 0..) |wire, index| {
        if (wire.artifact.len == 0 or wire.artifact.len > max_texture_artifact_bytes) return error.InvalidTextureArtifact;
        textures.entries[index] = makeTextureSpecWithProfile(wire.textureId, wire.artifact, wire.samplingProfile);
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
    return .{ .schemaVersion = legacy_object_schema_version, .textures = textures, .objects = objects };
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
        if (schemaHasTextureSamplingProfiles(value.schemaVersion)) {
            payload_bytes = try std.math.add(usize, payload_bytes, 4);
        }
    }
    payload_bytes = try std.math.add(usize, payload_bytes, 4);
    for (value.objects.slice()) |object| {
        payload_bytes = try std.math.add(usize, payload_bytes, 4);
        payload_bytes = try std.math.add(usize, payload_bytes, try objectEntryBytes(value.schemaVersion, &object));
    }
    if (schemaHasSpawnPrototypes(value.schemaVersion)) {
        payload_bytes = try std.math.add(usize, payload_bytes, 4);
        for (value.prototypes.slice()) |prototype| {
            payload_bytes = try std.math.add(usize, payload_bytes, 4);
            payload_bytes = try std.math.add(usize, payload_bytes, try prototypeEntryBytes(&prototype));
        }
    }
    if (schemaHasExplicitGameplay(value.schemaVersion)) {
        // KSCN v7 尾部显式保存 profile 与 time limit，Runtime 不再从角色表猜测模式。
        payload_bytes = try std.math.add(usize, payload_bytes, 8);
    }
    if (schemaHasTilemaps(value.schemaVersion)) {
        payload_bytes = try std.math.add(usize, payload_bytes, 4);
        for (value.tilemaps.slice()) |tilemap| {
            const cell_bytes = try std.math.mul(usize, tilemap.cellSlice().len, @sizeOf(u16));
            payload_bytes = try std.math.add(usize, payload_bytes, 4 + tilemap.tilemapId.slice().len + 8 + 8 + 24);
            payload_bytes = try std.math.add(usize, payload_bytes, cell_bytes);
        }
    }
    if (value.schemaVersion == current_schema_version) {
        // KSCN v9 在 v8 Tilemap 尾部后追加 Camera2D：origin f32[2] + zoom f32。
        payload_bytes = try std.math.add(usize, payload_bytes, 3 * @sizeOf(f32));
    }
    return try std.math.add(usize, scene_artifact_header_bytes, payload_bytes);
}

pub fn writeArtifact(value: *const Scene, output: []u8) ![]u8 {
    try validate(value);
    const byte_count = try artifactByteCount(value);
    if (output.len != byte_count) return error.InvalidSceneArtifactBuffer;
    const artifact_version = try artifactVersionForSchema(value.schemaVersion);
    @memcpy(output[0..4], "KSCN");
    writeLittleU32(output[4..8], artifact_version);
    writeLittleU32(output[8..12], value.schemaVersion);
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
        if (schemaHasTextureSamplingProfiles(value.schemaVersion)) {
            writeLittleU32(output[cursor..][0..4], @intFromEnum(texture.samplingProfile));
            cursor += 4;
        }
    }
    writeLittleU32(output[cursor..][0..4], value.objects.count);
    cursor += 4;
    for (value.objects.slice()) |object| {
        const entry_bytes = try objectEntryBytes(value.schemaVersion, &object);
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
                if (value.schemaVersion == legacy_object_schema_version) {
                    writeLittleF32(output[cursor..][0..4], object.patrol.minY);
                    writeLittleF32(output[cursor + 4 ..][0..4], object.patrol.maxY);
                    writeLittleF32(output[cursor + 8 ..][0..4], object.patrol.speed);
                    cursor += 12;
                }
            },
        }
        if (schemaHasBehaviorBindings(value.schemaVersion)) {
            cursor = writeBehaviorBindingSet(output, cursor, &object.behaviors);
        }
    }
    if (schemaHasSpawnPrototypes(value.schemaVersion)) {
        writeLittleU32(output[cursor..][0..4], value.prototypes.count);
        cursor += 4;
        for (value.prototypes.slice()) |prototype| {
            const entry_bytes = try prototypeEntryBytes(&prototype);
            writeLittleU32(output[cursor..][0..4], @intCast(entry_bytes));
            cursor += 4;
            writeLittleU32(output[cursor..][0..4], @intFromEnum(prototype.kind));
            writeLittleU32(output[cursor + 4 ..][0..4], prototype.prototypeId.byte_count);
            cursor += 8;
            @memcpy(output[cursor .. cursor + prototype.prototypeId.byte_count], prototype.prototypeId.slice());
            cursor += prototype.prototypeId.byte_count;
            for (prototype.sprite.size ++ prototype.sprite.color) |number| {
                writeLittleF32(output[cursor..][0..4], number);
                cursor += 4;
            }
            writeLittleU32(output[cursor..][0..4], prototype.sprite.textureId);
            cursor += 4;
            cursor = writeBehaviorBindingSet(output, cursor, &prototype.behaviors);
        }
    }
    if (schemaHasExplicitGameplay(value.schemaVersion)) {
        writeLittleU32(output[cursor..][0..4], @intFromEnum(value.gameplay.profile));
        writeLittleF32(output[cursor + 4 ..][0..4], value.gameplay.timeLimitSeconds);
        cursor += 8;
    }
    if (schemaHasTilemaps(value.schemaVersion)) {
        writeLittleU32(output[cursor..][0..4], value.tilemaps.count);
        cursor += 4;
        for (value.tilemaps.slice()) |tilemap| {
            writeLittleU32(output[cursor..][0..4], tilemap.tilemapId.byte_count);
            cursor += 4;
            @memcpy(output[cursor .. cursor + tilemap.tilemapId.byte_count], tilemap.tilemapId.slice());
            cursor += tilemap.tilemapId.byte_count;
            for (tilemap.origin ++ tilemap.tileSize) |number| {
                writeLittleF32(output[cursor..][0..4], number);
                cursor += 4;
            }
            writeLittleU32(output[cursor..][0..4], tilemap.columns);
            writeLittleU32(output[cursor + 4 ..][0..4], tilemap.rows);
            writeLittleU32(output[cursor + 8 ..][0..4], tilemap.textureId);
            writeLittleU32(output[cursor + 12 ..][0..4], tilemap.atlasColumns);
            writeLittleU32(output[cursor + 16 ..][0..4], tilemap.atlasRows);
            writeLittleU32(output[cursor + 20 ..][0..4], @intCast(tilemap.cellSlice().len));
            cursor += 24;
            for (tilemap.cellSlice()) |cell| {
                writeLittleU16(output[cursor..][0..2], cell);
                cursor += 2;
            }
        }
    }
    if (value.schemaVersion == current_schema_version) {
        writeLittleF32(output[cursor..][0..4], value.camera.origin[0]);
        writeLittleF32(output[cursor + 4 ..][0..4], value.camera.origin[1]);
        writeLittleF32(output[cursor + 8 ..][0..4], value.camera.zoom);
        cursor += 12;
    }
    std.debug.assert(cursor == output.len);
    return output;
}

fn artifactVersionForSchema(schema_version: u32) !u32 {
    return switch (schema_version) {
        legacy_object_schema_version => legacy_object_artifact_version,
        behavior_schema_version => behavior_artifact_version,
        prototype_schema_version => prototype_artifact_version,
        gameplay_schema_version => gameplay_artifact_version,
        tilemap_schema_version => tilemap_artifact_version,
        current_schema_version => scene_artifact_version,
        else => error.UnsupportedSceneSchema,
    };
}

fn objectEntryBytes(schema_version: u32, object: *const SceneObject) !usize {
    var payload_bytes: usize = switch (object.kind) {
        .sprite, .goal => 0,
        .player => 4,
        .patrol_hazard => if (schema_version == legacy_object_schema_version) 12 else 0,
    };
    if (schemaHasBehaviorBindings(schema_version)) {
        payload_bytes = try std.math.add(usize, payload_bytes, 4);
        for (object.behaviors.slice()) |binding| {
            payload_bytes = try std.math.add(usize, payload_bytes, 8);
            for (binding.parameterSlice()) |parameter| {
                payload_bytes = try std.math.add(usize, payload_bytes, 4 + parameter.name().len + 8);
            }
        }
    } else if (schema_version != legacy_object_schema_version) {
        return error.UnsupportedSceneSchema;
    }
    return try std.math.add(usize, 4 + 4 + object.objectId.byte_count + 8 * 4 + 4, payload_bytes);
}

fn prototypeEntryBytes(prototype: *const SpawnPrototype) !usize {
    var payload_bytes: usize = 4 + 4 + prototype.prototypeId.byte_count + 6 * 4 + 4 + 4;
    for (prototype.behaviors.slice()) |binding| {
        payload_bytes = try std.math.add(usize, payload_bytes, 8);
        for (binding.parameterSlice()) |parameter| {
            payload_bytes = try std.math.add(usize, payload_bytes, 4 + parameter.name().len + 8);
        }
    }
    return payload_bytes;
}

fn writeBehaviorBindingSet(output: []u8, start: usize, bindings: *const BehaviorBindingSet) usize {
    var cursor = start;
    writeLittleU32(output[cursor..][0..4], bindings.count);
    cursor += 4;
    for (bindings.slice()) |binding| {
        writeLittleU32(output[cursor..][0..4], binding.scriptId);
        writeLittleU32(output[cursor + 4 ..][0..4], binding.parameterCount);
        cursor += 8;
        for (binding.parameterSlice()) |parameter| {
            writeLittleU32(output[cursor..][0..4], parameter.nameBytes);
            cursor += 4;
            @memcpy(output[cursor .. cursor + parameter.nameBytes], parameter.name());
            cursor += parameter.nameBytes;
            writeLittleF64(output[cursor..][0..8], parameter.value);
            cursor += 8;
        }
    }
    return cursor;
}

fn schemaHasBehaviorBindings(schema_version: u32) bool {
    return schema_version == behavior_schema_version or
        schema_version == prototype_schema_version or
        schema_version == gameplay_schema_version or
        schema_version == tilemap_schema_version or
        schema_version == current_schema_version;
}

fn schemaHasSpawnPrototypes(schema_version: u32) bool {
    return schema_version == prototype_schema_version or
        schema_version == gameplay_schema_version or
        schema_version == tilemap_schema_version or
        schema_version == current_schema_version;
}

fn schemaHasExplicitGameplay(schema_version: u32) bool {
    return schema_version == gameplay_schema_version or
        schema_version == tilemap_schema_version or
        schema_version == current_schema_version;
}

fn schemaHasTextureSamplingProfiles(schema_version: u32) bool {
    return schema_version == tilemap_schema_version or schema_version == current_schema_version;
}

fn schemaHasTilemaps(schema_version: u32) bool {
    return schema_version == tilemap_schema_version or schema_version == current_schema_version;
}

fn parseArtifact(source: []const u8) !Scene {
    var value: Scene = undefined;
    try parseArtifactInto(source, &value);
    return value;
}

fn parseArtifactInto(source: []const u8, output: *Scene) !void {
    if (source.len < scene_artifact_header_bytes) return error.InvalidSceneArtifact;
    if (!std.mem.eql(u8, source[0..4], "KSCN")) return error.InvalidSceneArtifact;
    const artifact_version = readLittleU32(source[4..8]);
    const schema_version = readLittleU32(source[8..12]);
    const payload_bytes = readLittleU32(source[12..16]);
    if (source.len != scene_artifact_header_bytes + @as(usize, payload_bytes)) return error.InvalidSceneArtifact;
    switch (artifact_version) {
        1, 2, 3 => output.* = try parseLegacyArtifact(source, artifact_version, schema_version, payload_bytes),
        legacy_object_artifact_version => try parseArtifactV4Into(source, schema_version, output),
        behavior_artifact_version => {
            if (schema_version != behavior_schema_version) return error.UnsupportedSceneSchema;
            try parseArtifactBehaviorSceneInto(source, behavior_schema_version, false, false, false, false, output);
        },
        prototype_artifact_version => {
            if (schema_version != prototype_schema_version) return error.UnsupportedSceneSchema;
            try parseArtifactBehaviorSceneInto(source, prototype_schema_version, true, false, false, false, output);
        },
        gameplay_artifact_version => {
            if (schema_version != gameplay_schema_version) return error.UnsupportedSceneSchema;
            try parseArtifactBehaviorSceneInto(source, gameplay_schema_version, true, true, false, false, output);
        },
        tilemap_artifact_version => {
            if (schema_version != tilemap_schema_version) return error.UnsupportedSceneSchema;
            try parseArtifactBehaviorSceneInto(source, tilemap_schema_version, true, true, true, true, output);
        },
        scene_artifact_version => {
            if (schema_version != current_schema_version) return error.UnsupportedSceneSchema;
            try parseArtifactBehaviorSceneInto(source, current_schema_version, true, true, true, true, output);
        },
        else => return error.UnsupportedSceneArtifactVersion,
    }
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
        textures = try readTextureSet(&reader, false);
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

fn parseArtifactV4Into(source: []const u8, schema_version: u32, output: *Scene) !void {
    if (schema_version != legacy_object_schema_version) return error.UnsupportedSceneSchema;
    var reader = ByteReader{ .source = source, .cursor = scene_artifact_header_bytes };
    output.* = .{
        .schemaVersion = legacy_object_schema_version,
        .textures = try readTextureSet(&reader, false),
        .objects = undefined,
    };
    const object_count = try reader.readU32();
    if (object_count < min_scene_object_count or object_count > max_scene_object_count) return error.InvalidSceneObjectCount;
    output.objects = .{ .count = @intCast(object_count) };
    for (output.objects.mutableSlice()) |*object| {
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
    try validate(output);
}

fn parseArtifactBehaviorSceneInto(
    source: []const u8,
    schema_version: u32,
    read_prototypes: bool,
    read_gameplay: bool,
    read_sampling_profiles: bool,
    read_tilemaps: bool,
    output: *Scene,
) !void {
    var reader = ByteReader{ .source = source, .cursor = scene_artifact_header_bytes };
    output.* = .{
        .schemaVersion = schema_version,
        .textures = try readTextureSet(&reader, read_sampling_profiles),
        .objects = undefined,
    };
    const object_count = try reader.readU32();
    const minimum_count: usize = if (schemaHasExplicitGameplay(schema_version)) min_neutral_scene_object_count else min_scene_object_count;
    if (object_count < minimum_count or object_count > max_scene_object_count) return error.InvalidSceneObjectCount;
    output.objects = .{ .count = @intCast(object_count) };
    for (output.objects.mutableSlice()) |*object| {
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
        if (kind == .player) object.player.moveSpeed = try entry.readF32();
        object.behaviors = try readBehaviorBindingSet(&entry);
        if (!entry.atEnd()) return error.InvalidSceneObjectPayload;
    }
    if (read_prototypes) {
        const prototype_count = try reader.readU32();
        if (prototype_count > max_spawn_prototype_count) return error.SpawnPrototypeCountExceeded;
        output.prototypes.count = @intCast(prototype_count);
        for (output.prototypes.entries[0..output.prototypes.count]) |*prototype| {
            const entry_bytes = try reader.readU32();
            var entry = ByteReader{ .source = try reader.readBytes(entry_bytes) };
            const kind_value = try entry.readU32();
            if (kind_value != @intFromEnum(ObjectKind.sprite)) return error.InvalidSpawnPrototypeKind;
            const prototype_id_bytes = try entry.readU32();
            prototype.prototypeId = try PrototypeId.init(try entry.readBytes(prototype_id_bytes));
            prototype.kind = .sprite;
            prototype.sprite = .{
                .size = .{ try entry.readF32(), try entry.readF32() },
                .color = .{ try entry.readF32(), try entry.readF32(), try entry.readF32(), try entry.readF32() },
                .textureId = try entry.readU32(),
            };
            prototype.behaviors = try readBehaviorBindingSet(&entry);
            if (!entry.atEnd()) return error.InvalidSpawnPrototypePayload;
        }
    }
    if (read_gameplay) {
        output.gameplay.profile = switch (try reader.readU32()) {
            0 => .none,
            1 => .goal_hazard_v1,
            else => return error.InvalidGameplayProfile,
        };
        output.gameplay.timeLimitSeconds = try reader.readF32();
    }
    if (read_tilemaps) {
        const tilemap_count = try reader.readU32();
        if (tilemap_count > max_tilemap_count) return error.TilemapCountExceeded;
        output.tilemaps.count = @intCast(tilemap_count);
        for (output.tilemaps.entries[0..output.tilemaps.count]) |*tilemap| {
            const tilemap_id_bytes = try reader.readU32();
            tilemap.tilemapId = try TilemapId.init(try reader.readBytes(tilemap_id_bytes));
            tilemap.origin = .{ try reader.readF32(), try reader.readF32() };
            tilemap.tileSize = .{ try reader.readF32(), try reader.readF32() };
            tilemap.columns = try reader.readU32();
            tilemap.rows = try reader.readU32();
            tilemap.textureId = try reader.readU32();
            tilemap.atlasColumns = try reader.readU32();
            tilemap.atlasRows = try reader.readU32();
            const cell_count = try reader.readU32();
            if (cell_count > max_tilemap_cell_count) return error.InvalidTilemapCellCount;
            const expected_count = std.math.mul(usize, @as(usize, tilemap.columns), @as(usize, tilemap.rows)) catch {
                return error.InvalidTilemapCellCount;
            };
            if (cell_count != expected_count) return error.InvalidTilemapCellCount;
            for (tilemap.cells[0..cell_count]) |*cell| cell.* = try reader.readU16();
        }
    }
    if (schema_version == current_schema_version) {
        // v9 Camera2D 尾部必须完整存在；截断和额外字节均由 ByteReader 拒绝。
        output.camera.origin = .{ try reader.readF32(), try reader.readF32() };
        output.camera.zoom = try reader.readF32();
    }
    if (!reader.atEnd()) return error.InvalidSceneArtifact;
    try validate(output);
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

    fn readU16(self: *ByteReader) !u16 {
        const bytes = try self.readBytes(2);
        return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
    }

    fn readF32(self: *ByteReader) !f32 {
        return @bitCast(try self.readU32());
    }

    fn readF64(self: *ByteReader) !f64 {
        return @bitCast(try self.readU64());
    }

    fn readU64(self: *ByteReader) !u64 {
        return readLittleU64(try self.readBytes(8));
    }

    fn atEnd(self: *const ByteReader) bool {
        return self.cursor == self.source.len;
    }
};

fn readBehaviorBindingSet(reader: *ByteReader) !BehaviorBindingSet {
    const binding_count = try reader.readU32();
    if (binding_count > max_behavior_bindings_per_object) return error.ObjectBehaviorBindingCountExceeded;
    var bindings = BehaviorBindingSet{ .count = @intCast(binding_count) };
    for (bindings.entries[0..bindings.count]) |*binding| {
        binding.scriptId = try reader.readU32();
        const parameter_count = try reader.readU32();
        if (parameter_count > max_behavior_parameter_count) return error.BehaviorParameterCountExceeded;
        binding.parameterCount = @intCast(parameter_count);
        for (binding.parameters[0..binding.parameterCount]) |*parameter| {
            const name_bytes = try reader.readU32();
            if (name_bytes == 0 or name_bytes > max_behavior_parameter_name_bytes) return error.InvalidBehaviorParameter;
            const name = try reader.readBytes(name_bytes);
            try validateBehaviorParameterName(name);
            parameter.nameBytes = @intCast(name_bytes);
            @memcpy(parameter.nameStorage[0..name_bytes], name);
            parameter.value = try reader.readF64();
        }
    }
    try validateBehaviorBindings(&bindings);
    return bindings;
}

fn readTextureSet(reader: *ByteReader, read_sampling_profiles: bool) !TextureSet {
    const texture_count = try reader.readU32();
    if (texture_count == 0 or texture_count > max_texture_count) return error.InvalidTextureSetCount;
    var textures = TextureSet{ .count = @intCast(texture_count) };
    for (textures.entries[0..textures.count]) |*entry| {
        const texture_id = try reader.readU32();
        const artifact_bytes = try reader.readU32();
        if (artifact_bytes == 0 or artifact_bytes > max_texture_artifact_bytes) return error.InvalidTextureArtifact;
        entry.* = makeTextureSpec(texture_id, try reader.readBytes(artifact_bytes));
        if (read_sampling_profiles) {
            entry.samplingProfile = switch (try reader.readU32()) {
                1 => .pixel_art,
                2 => .smooth_linear,
                3 => .smooth_mipmap,
                4 => .smooth_mipmap_anisotropic,
                else => return error.InvalidTextureSamplingProfile,
            };
        }
    }
    return textures;
}

pub fn validate(value: *const Scene) !void {
    if (value.schemaVersion != legacy_object_schema_version and
        value.schemaVersion != behavior_schema_version and
        value.schemaVersion != prototype_schema_version and
        value.schemaVersion != gameplay_schema_version and
        value.schemaVersion != tilemap_schema_version and
        value.schemaVersion != current_schema_version)
    {
        return error.UnsupportedSceneSchema;
    }
    if (value.textures.count == 0 or value.textures.count > max_texture_count) return error.InvalidTextureSetCount;
    for (value.textures.slice(), 0..) |entry, index| {
        if (entry.textureId == 0) return error.InvalidTextureId;
        try validateTextureArtifact(entry.artifact());
        for (value.textures.slice()[0..index]) |previous| {
            if (previous.textureId == entry.textureId) return error.DuplicateTextureId;
        }
    }
    const minimum_object_count: usize = if (schemaHasExplicitGameplay(value.schemaVersion) and !value.gameplayEnabled())
        min_neutral_scene_object_count
    else
        min_scene_object_count;
    if (value.objects.count < minimum_object_count or value.objects.count > max_scene_object_count) {
        return error.InvalidSceneObjectCount;
    }
    if (schemaHasExplicitGameplay(value.schemaVersion)) switch (value.gameplay.profile) {
        .none => if (value.gameplay.timeLimitSeconds != 0) return error.InvalidGameplayTimeLimit,
        .goal_hazard_v1 => if (!std.math.isFinite(value.gameplay.timeLimitSeconds) or value.gameplay.timeLimitSeconds <= 0)
            return error.InvalidGameplayTimeLimit,
    };
    var player_count: usize = 0;
    var goal_count: usize = 0;
    var hazard_count: usize = 0;
    var behavior_binding_count: usize = 0;
    for (value.objects.slice(), 0..) |object, index| {
        try validateObjectIdBytes(object.objectId.slice());
        for (value.objects.slice()[0..index]) |previous| {
            if (object.objectId.eql(&previous.objectId)) return error.DuplicateSceneObjectId;
        }
        try validateSprite(object.sprite.position, object.sprite.size, object.sprite.color);
        if (object.sprite.textureId == 0) return error.InvalidTextureId;
        if (!value.textures.contains(object.sprite.textureId)) return error.UnknownSceneTexture;
        if (value.schemaVersion == legacy_object_schema_version) {
            if (object.behaviors.count != 0) return error.LegacySceneBehaviorBinding;
        } else {
            try validateBehaviorBindings(&object.behaviors);
            behavior_binding_count = std.math.add(usize, behavior_binding_count, object.behaviors.count) catch {
                return error.BehaviorBindingCountExceeded;
            };
            if (behavior_binding_count > max_behavior_binding_count) return error.BehaviorBindingCountExceeded;
        }
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
                if (value.schemaVersion == legacy_object_schema_version) {
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
                } else if (value.gameplayEnabled() and object.behaviors.count == 0) {
                    return error.MissingHazardBehaviorBinding;
                }
            },
        }
    }
    if (value.gameplayEnabled() and (player_count != 1 or goal_count != 1 or hazard_count == 0)) {
        return error.InvalidSceneRoleCount;
    }
    if (!schemaHasSpawnPrototypes(value.schemaVersion)) {
        if (value.prototypes.count != 0) return error.LegacySceneSpawnPrototype;
    } else {
        if (value.prototypes.count > max_spawn_prototype_count) return error.SpawnPrototypeCountExceeded;
        var prototype_binding_count: usize = 0;
        for (value.prototypes.slice(), 0..) |prototype, index| {
            try validateObjectIdBytes(prototype.prototypeId.slice());
            for (value.prototypes.slice()[0..index]) |previous| {
                if (std.mem.eql(u8, prototype.prototypeId.slice(), previous.prototypeId.slice())) {
                    return error.DuplicateSpawnPrototypeId;
                }
            }
            if (prototype.kind != .sprite) return error.InvalidSpawnPrototypeKind;
            try validateSprite(.{ 0, 0 }, prototype.sprite.size, prototype.sprite.color);
            if (prototype.sprite.textureId == 0) return error.InvalidTextureId;
            if (!value.textures.contains(prototype.sprite.textureId)) return error.UnknownSceneTexture;
            try validateBehaviorBindings(&prototype.behaviors);
            prototype_binding_count = std.math.add(usize, prototype_binding_count, prototype.behaviors.count) catch {
                return error.PrototypeBehaviorBindingCountExceeded;
            };
            if (prototype_binding_count > max_prototype_behavior_binding_count) {
                return error.PrototypeBehaviorBindingCountExceeded;
            }
        }
    }

    if (!schemaHasTilemaps(value.schemaVersion)) {
        if (value.tilemaps.count != 0) return error.LegacySceneTilemap;
    } else {
        if (value.tilemaps.count > max_tilemap_count) return error.TilemapCountExceeded;
        for (value.tilemaps.slice()) |tilemap| {
            try validateTilemap(value, &tilemap);
        }
    }

    if (value.schemaVersion != current_schema_version) {
        if (value.camera.origin[0] != 0 or value.camera.origin[1] != 0 or value.camera.zoom != 1) {
            return error.LegacySceneCamera;
        }
        return;
    }
    for (value.camera.origin) |number| {
        if (!std.math.isFinite(number)) return error.InvalidCameraOrigin;
    }
    if (!std.math.isFinite(value.camera.zoom) or value.camera.zoom < 0.125 or value.camera.zoom > 8.0) {
        return error.InvalidCameraZoom;
    }
}

fn validateTilemap(scene: *const Scene, tilemap: *const Tilemap) !void {
    _ = TilemapId.init(tilemap.tilemapId.slice()) catch return error.InvalidTilemapId;
    for (tilemap.origin) |number| {
        if (!std.math.isFinite(number)) return error.InvalidTilemapOrigin;
    }
    for (tilemap.tileSize) |number| {
        if (!std.math.isFinite(number) or number <= 0) return error.InvalidTilemapSize;
    }
    if (tilemap.columns == 0 or tilemap.columns > max_tilemap_columns or
        tilemap.rows == 0 or tilemap.rows > max_tilemap_rows)
    {
        return error.InvalidTilemapDimensions;
    }
    if (tilemap.atlasColumns == 0 or tilemap.atlasColumns > max_tilemap_atlas_dimension or
        tilemap.atlasRows == 0 or tilemap.atlasRows > max_tilemap_atlas_dimension)
    {
        return error.InvalidTilemapAtlas;
    }
    const atlas_tiles = std.math.mul(usize, @as(usize, tilemap.atlasColumns), @as(usize, tilemap.atlasRows)) catch {
        return error.InvalidTilemapAtlas;
    };
    if (atlas_tiles > max_tilemap_atlas_tiles) return error.InvalidTilemapAtlas;
    const texture = scene.textures.find(tilemap.textureId) orelse return error.UnknownSceneTexture;
    if (texture.samplingProfile != .pixel_art) return error.InvalidTilemapSamplingProfile;
    const cell_count = std.math.mul(usize, @as(usize, tilemap.columns), @as(usize, tilemap.rows)) catch {
        return error.InvalidTilemapCellCount;
    };
    for (tilemap.cells[0..cell_count]) |cell| {
        if (cell > atlas_tiles) return error.InvalidTilemapCell;
    }
}

fn validateBehaviorBindings(bindings: *const BehaviorBindingSet) !void {
    if (bindings.count > max_behavior_bindings_per_object) return error.ObjectBehaviorBindingCountExceeded;
    for (bindings.slice(), 0..) |binding, binding_index| {
        if (binding.scriptId == 0) return error.InvalidBehaviorScriptId;
        if (binding.parameterCount > max_behavior_parameter_count) return error.BehaviorParameterCountExceeded;
        for (bindings.slice()[0..binding_index]) |previous| {
            if (previous.scriptId == binding.scriptId) return error.DuplicateBehaviorBinding;
        }
        for (binding.parameterSlice(), 0..) |parameter, parameter_index| {
            try validateBehaviorParameterName(parameter.name());
            if (!std.math.isFinite(parameter.value)) return error.InvalidBehaviorParameter;
            for (binding.parameterSlice()[0..parameter_index]) |previous| {
                if (std.mem.eql(u8, previous.name(), parameter.name())) return error.DuplicateBehaviorParameter;
            }
        }
    }
}

fn validateBehaviorParameterName(name: []const u8) !void {
    if (name.len == 0 or name.len > max_behavior_parameter_name_bytes) return error.InvalidBehaviorParameter;
    if (!isBehaviorIdentifierStart(name[0])) return error.InvalidBehaviorParameter;
    for (name[1..]) |byte| {
        if (!isBehaviorIdentifierContinue(byte)) return error.InvalidBehaviorParameter;
    }
}

fn isBehaviorIdentifierStart(byte: u8) bool {
    return (byte >= 'A' and byte <= 'Z') or (byte >= 'a' and byte <= 'z') or byte == '_';
}

fn isBehaviorIdentifierContinue(byte: u8) bool {
    return isBehaviorIdentifierStart(byte) or (byte >= '0' and byte <= '9');
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

fn readLittleU64(bytes: []const u8) u64 {
    var value: u64 = 0;
    for (bytes[0..8], 0..) |byte, shift_index| {
        value |= @as(u64, byte) << @intCast(shift_index * 8);
    }
    return value;
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

fn writeLittleU16(bytes: []u8, value: u16) void {
    bytes[0] = @truncate(value);
    bytes[1] = @truncate(value >> 8);
}

fn writeLittleF32(bytes: []u8, value: f32) void {
    writeLittleU32(bytes, @bitCast(value));
}

fn writeLittleU64(bytes: []u8, value: u64) void {
    for (bytes[0..8], 0..) |*byte, shift_index| {
        byte.* = @truncate(value >> @intCast(shift_index * 8));
    }
}

fn writeLittleF64(bytes: []u8, value: f64) void {
    writeLittleU64(bytes, @bitCast(value));
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

const scene_v5_source =
    \\{"schemaVersion":5,"textures":[{"textureId":1,"artifact":"assets/renderer2d/test.texture"}],"objects":[
    \\{"objectId":"goal","kind":"goal","transform":{"position":[10,20]},"sprite":{"size":[3,4],"color":[1,1,1,1],"textureId":1},"behaviors":[]},
    \\{"objectId":"hazard-1","kind":"patrol_hazard","transform":{"position":[30,40]},"sprite":{"size":[5,6],"color":[1,0,0,1],"textureId":1},"behaviors":[{"scriptId":7,"parameters":{"speed":7,"minY":20,"maxY":60}}]},
    \\{"objectId":"player","kind":"player","transform":{"position":[1,2]},"sprite":{"size":[8,9],"color":[1,1,1,1],"textureId":1},"player":{"moveSpeed":10},"behaviors":[]}]}
;

const scene_v6_source =
    \\{"schemaVersion":6,"textures":[{"textureId":1,"artifact":"assets/renderer2d/test.texture"}],"objects":[
    \\{"objectId":"goal","kind":"goal","transform":{"position":[10,20]},"sprite":{"size":[3,4],"color":[1,1,1,1],"textureId":1},"behaviors":[]},
    \\{"objectId":"hazard-1","kind":"patrol_hazard","transform":{"position":[30,40]},"sprite":{"size":[5,6],"color":[1,0,0,1],"textureId":1},"behaviors":[{"scriptId":7,"parameters":{"speed":7,"minY":20,"maxY":60}}]},
    \\{"objectId":"player","kind":"player","transform":{"position":[1,2]},"sprite":{"size":[8,9],"color":[1,1,1,1],"textureId":1},"player":{"moveSpeed":10},"behaviors":[]}],"prototypes":[
    \\{"prototypeId":"runtime-orb","kind":"sprite","sprite":{"size":[2,3],"color":[0.25,0.5,0.75,1],"textureId":1},"behaviors":[{"scriptId":9,"parameters":{"speed":12}}]}]}
;

const scene_v8_source =
    \\{"schemaVersion":8,"textures":[{"textureId":1,"artifact":"assets/renderer2d/test.texture","samplingProfile":"pixel_art"}],"objects":[
    \\{"objectId":"decor","kind":"sprite","transform":{"position":[10,20]},"sprite":{"size":[16,16],"color":[1,1,1,1],"textureId":1},"behaviors":[]}
    \\],"prototypes":[],"tilemaps":[
    \\{"tilemapId":"background","origin":[0,0],"tileSize":[32,32],"columns":2,"rows":2,"textureId":1,"atlasColumns":4,"atlasRows":4,"cells":[1,0,6,16]}]}
;

const scene_v9_source =
    \\{"schemaVersion":9,"textures":[{"textureId":1,"artifact":"assets/renderer2d/test.texture","samplingProfile":"pixel_art"}],"objects":[
    \\{"objectId":"decor","kind":"sprite","transform":{"position":[10,20]},"sprite":{"size":[16,16],"color":[1,1,1,1],"textureId":1},"behaviors":[]}
    \\],"prototypes":[],"tilemaps":[
    \\{"tilemapId":"background","origin":[0,0],"tileSize":[32,32],"columns":2,"rows":2,"textureId":1,"atlasColumns":4,"atlasRows":4,"cells":[1,0,6,16]}],
    \\ "camera":{"origin":[200,120],"zoom":2}}
;

test "scene v9 parses authored Camera2D while v8 normalizes identity" {
    const value = try parse(std.testing.allocator, scene_v9_source);
    try std.testing.expectEqual(@as(u32, 9), value.schemaVersion);
    try std.testing.expectEqualSlices(f32, &.{ 200, 120 }, &value.camera.origin);
    try std.testing.expectEqual(@as(f32, 2), value.camera.zoom);

    const legacy = try parse(std.testing.allocator, scene_v8_source);
    try std.testing.expectEqualSlices(f32, &.{ 0, 0 }, &legacy.camera.origin);
    try std.testing.expectEqual(@as(f32, 1), legacy.camera.zoom);
}

test "scene v9 rejects non-finite origin and zoom outside the contract" {
    var value = try parse(std.testing.allocator, scene_v9_source);
    value.camera.origin[0] = std.math.nan(f32);
    try std.testing.expectError(error.InvalidCameraOrigin, validate(&value));

    value.camera.origin[0] = 0;
    value.camera.zoom = 0.124;
    try std.testing.expectError(error.InvalidCameraZoom, validate(&value));
    value.camera.zoom = 8.001;
    try std.testing.expectError(error.InvalidCameraZoom, validate(&value));
}

test "KSCN v9 round trips Camera2D and rejects truncated camera tail" {
    const source = try parse(std.testing.allocator, scene_v9_source);
    const artifact = try encodeArtifact(std.testing.allocator, &source);
    defer std.testing.allocator.free(artifact);
    try std.testing.expectEqual(@as(u32, 9), readLittleU32(artifact[4..8]));
    try std.testing.expectEqual(@as(u32, 9), readLittleU32(artifact[8..12]));

    const decoded = try parseArtifact(artifact);
    try std.testing.expectEqualSlices(f32, &.{ 200, 120 }, &decoded.camera.origin);
    try std.testing.expectEqual(@as(f32, 2), decoded.camera.zoom);
    try std.testing.expectError(error.InvalidSceneArtifact, parseArtifact(artifact[0 .. artifact.len - 1]));
}

test "scene v8 parses bounded atlas tilemap and sampling profile" {
    const value = try parse(std.testing.allocator, scene_v8_source);
    try std.testing.expectEqual(@as(u32, 8), value.schemaVersion);
    try std.testing.expectEqual(TextureSamplingProfile.pixel_art, value.textures.entries[0].samplingProfile);
    try std.testing.expectEqual(@as(u8, 1), value.tilemaps.count);
    const tilemap = &value.tilemaps.entries[0];
    try std.testing.expectEqualStrings("background", tilemap.tilemapId.slice());
    try std.testing.expectEqual(@as(u16, 6), tilemap.cells[2]);
    try std.testing.expectEqual(@as(u32, 4), tilemap.atlasColumns);
}

test "KSCN v8 round trips texture sampling and tilemap cells" {
    const source = try parse(std.testing.allocator, scene_v8_source);
    const artifact = try encodeArtifact(std.testing.allocator, &source);
    defer std.testing.allocator.free(artifact);
    try std.testing.expectEqual(tilemap_artifact_version, readLittleU32(artifact[4..8]));
    try std.testing.expectEqual(tilemap_schema_version, readLittleU32(artifact[8..12]));

    const decoded = try parseArtifact(artifact);
    try std.testing.expectEqual(TextureSamplingProfile.pixel_art, decoded.textures.entries[0].samplingProfile);
    try std.testing.expectEqual(@as(u8, 1), decoded.tilemaps.count);
    try std.testing.expectEqualStrings("background", decoded.tilemaps.entries[0].tilemapId.slice());
    try std.testing.expectEqualSlices(u16, &.{ 1, 0, 6, 16 }, decoded.tilemaps.entries[0].cells[0..4]);
}

test "scene v8 rejects invalid atlas references and bounds" {
    var value = try parse(std.testing.allocator, scene_v8_source);
    value.textures.entries[0].samplingProfile = .smooth_linear;
    try std.testing.expectError(error.InvalidTilemapSamplingProfile, validate(&value));

    value.textures.entries[0].samplingProfile = .pixel_art;
    value.tilemaps.entries[0].textureId = 99;
    try std.testing.expectError(error.UnknownSceneTexture, validate(&value));

    value.tilemaps.entries[0].textureId = 1;
    value.tilemaps.entries[0].tileSize[0] = 0;
    try std.testing.expectError(error.InvalidTilemapSize, validate(&value));

    value.tilemaps.entries[0].tileSize[0] = 32;
    value.tilemaps.entries[0].cells[3] = 17;
    try std.testing.expectError(error.InvalidTilemapCell, validate(&value));

    const wrong_cell_count =
        \\{"schemaVersion":8,"textures":[{"textureId":1,"artifact":"assets/renderer2d/test.texture","samplingProfile":"pixel_art"}],"objects":[
        \\{"objectId":"decor","kind":"sprite","transform":{"position":[10,20]},"sprite":{"size":[16,16],"color":[1,1,1,1],"textureId":1},"behaviors":[]}
        \\],"prototypes":[],"tilemaps":[
        \\{"tilemapId":"background","origin":[0,0],"tileSize":[32,32],"columns":2,"rows":2,"textureId":1,"atlasColumns":4,"atlasRows":4,"cells":[1,2,3]}]}
    ;
    try std.testing.expectError(error.InvalidTilemapCellCount, parse(std.testing.allocator, wrong_cell_count));
}

test "KSCN v8 rejects truncation trailing bytes and unknown sampling profile" {
    const source = try parse(std.testing.allocator, scene_v8_source);
    const artifact = try encodeArtifact(std.testing.allocator, &source);
    defer std.testing.allocator.free(artifact);
    try std.testing.expectError(error.InvalidSceneArtifact, parseArtifact(artifact[0 .. artifact.len - 1]));

    var trailing = try std.testing.allocator.alloc(u8, artifact.len + 1);
    defer std.testing.allocator.free(trailing);
    @memcpy(trailing[0..artifact.len], artifact);
    trailing[artifact.len] = 0;
    try std.testing.expectError(error.InvalidSceneArtifact, parseArtifact(trailing));

    var unknown_profile = try std.testing.allocator.dupe(u8, artifact);
    defer std.testing.allocator.free(unknown_profile);
    const profile_offset = 16 + 4 + 8 + primary_texture_artifact.len;
    writeLittleU32(unknown_profile[profile_offset..][0..4], 99);
    try std.testing.expectError(error.InvalidTextureSamplingProfile, parseArtifact(unknown_profile));

    const tilemap_id_offset = std.mem.indexOf(u8, artifact, "background") orelse return error.TestUnexpectedResult;
    const dimensions_offset = tilemap_id_offset + "background".len + 16;
    const cell_count_offset = dimensions_offset + 20;
    var wrong_count = try std.testing.allocator.dupe(u8, artifact);
    defer std.testing.allocator.free(wrong_count);
    writeLittleU32(wrong_count[cell_count_offset..][0..4], 3);
    try std.testing.expectError(error.InvalidTilemapCellCount, parseArtifact(wrong_count));

    var overflow_dimensions = try std.testing.allocator.dupe(u8, artifact);
    defer std.testing.allocator.free(overflow_dimensions);
    writeLittleU32(overflow_dimensions[dimensions_offset..][0..4], std.math.maxInt(u32));
    writeLittleU32(overflow_dimensions[dimensions_offset + 4 ..][0..4], std.math.maxInt(u32));
    try std.testing.expectError(error.InvalidTilemapCellCount, parseArtifact(overflow_dimensions));
}

test "KSCN v4 through v7 compatibility reads without mutating artifact bytes" {
    const expectUnchanged = struct {
        fn run(value: *const Scene) !void {
            const artifact = try encodeArtifact(std.testing.allocator, value);
            defer std.testing.allocator.free(artifact);
            const original = try std.testing.allocator.dupe(u8, artifact);
            defer std.testing.allocator.free(original);
            _ = try parseArtifact(artifact);
            try std.testing.expectEqualSlices(u8, original, artifact);
        }
    }.run;

    try expectUnchanged(&default_scene);
    const value_v5 = try parse(std.testing.allocator, scene_v5_source);
    try expectUnchanged(&value_v5);
    const value_v6 = try parse(std.testing.allocator, scene_v6_source);
    try expectUnchanged(&value_v6);
    var value_v7 = value_v6;
    value_v7.schemaVersion = gameplay_schema_version;
    value_v7.gameplay = goal_hazard_v1_gameplay;
    try validate(&value_v7);
    try expectUnchanged(&value_v7);
}

test "scene v7 parses one-object neutral scene" {
    const contents =
        \\{"schemaVersion":7,"textures":[{"textureId":1,"artifact":"assets/renderer2d/test.texture"}],"objects":[
        \\{"objectId":"decor","kind":"sprite","transform":{"position":[10,20]},"sprite":{"size":[16,16],"color":[1,1,1,1],"textureId":1},"behaviors":[]}
        \\],"prototypes":[]}
    ;
    const value = try parse(std.testing.allocator, contents);
    try std.testing.expectEqual(gameplay_schema_version, value.schemaVersion);
    try std.testing.expectEqual(GameplayProfile.none, value.gameplay.profile);
    try std.testing.expectEqual(@as(u8, 1), value.objects.count);
    try std.testing.expectEqualStrings("decor", value.objects.entries[0].objectId.slice());
}

test "KSCN v7 round trips explicit neutral profile" {
    const contents =
        \\{"schemaVersion":7,"textures":[{"textureId":1,"artifact":"assets/renderer2d/test.texture"}],"objects":[
        \\{"objectId":"decor","kind":"sprite","transform":{"position":[10,20]},"sprite":{"size":[16,16],"color":[1,1,1,1],"textureId":1},"behaviors":[]}
        \\],"prototypes":[]}
    ;
    const source = try parse(std.testing.allocator, contents);
    const artifact = try encodeArtifact(std.testing.allocator, &source);
    defer std.testing.allocator.free(artifact);
    try std.testing.expectEqual(gameplay_artifact_version, readLittleU32(artifact[4..8]));
    const decoded = try parseArtifact(artifact);
    try std.testing.expectEqual(GameplayProfile.none, decoded.gameplay.profile);
    try std.testing.expectEqual(@as(u8, 1), decoded.objects.count);
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
    try std.testing.expectEqual(legacy_object_schema_version, value.schemaVersion);
    try std.testing.expectEqualStrings("player", value.objects.entries[0].objectId.slice());
    try std.testing.expectEqualStrings("goal", value.objects.entries[1].objectId.slice());
    try std.testing.expectEqualStrings("hazard", value.objects.entries[2].objectId.slice());
}

test "scene v5 parses ordered behavior bindings and canonical parameters" {
    const value = try parse(std.testing.allocator, scene_v5_source);
    try std.testing.expectEqual(behavior_schema_version, value.schemaVersion);
    try std.testing.expectEqual(@as(u8, 1), value.objects.entries[1].behaviors.count);
    const binding = &value.objects.entries[1].behaviors.entries[0];
    try std.testing.expectEqual(@as(u32, 7), binding.scriptId);
    try std.testing.expectEqual(@as(u8, 3), binding.parameterCount);
    try std.testing.expectEqualStrings("maxY", binding.parameters[0].name());
    try std.testing.expectEqual(@as(f64, 60), binding.parameters[0].value);
    try std.testing.expectEqualStrings("minY", binding.parameters[1].name());
    try std.testing.expectEqualStrings("speed", binding.parameters[2].name());
}

test "scene v6 parses bounded sprite spawn prototypes" {
    const value = try parse(std.testing.allocator, scene_v6_source);
    try std.testing.expectEqual(@as(u32, 6), value.schemaVersion);
    try std.testing.expectEqual(@as(u8, 1), value.prototypes.count);
    const prototype = &value.prototypes.entries[0];
    try std.testing.expectEqualStrings("runtime-orb", prototype.prototypeId.slice());
    try std.testing.expectEqual(.sprite, prototype.kind);
    try std.testing.expectEqual(@as(f32, 2), prototype.sprite.size[0]);
    try std.testing.expectEqual(@as(u32, 9), prototype.behaviors.entries[0].scriptId);
    try std.testing.expectEqualStrings("speed", prototype.behaviors.entries[0].parameters[0].name());
}

test "scene v6 rejects invalid prototype identity kind texture and count" {
    var value = try parse(std.testing.allocator, scene_v6_source);
    value.prototypes.entries[0].kind = .goal;
    try std.testing.expectError(error.InvalidSpawnPrototypeKind, validate(&value));

    value = try parse(std.testing.allocator, scene_v6_source);
    value.prototypes.count = 2;
    value.prototypes.entries[1] = value.prototypes.entries[0];
    try std.testing.expectError(error.DuplicateSpawnPrototypeId, validate(&value));

    value = try parse(std.testing.allocator, scene_v6_source);
    value.prototypes.entries[0].sprite.textureId = 99;
    try std.testing.expectError(error.UnknownSceneTexture, validate(&value));

    value = try parse(std.testing.allocator, scene_v6_source);
    value.prototypes.count = max_spawn_prototype_count + 1;
    try std.testing.expectError(error.SpawnPrototypeCountExceeded, validate(&value));

    var legacy = try parse(std.testing.allocator, scene_v5_source);
    legacy.prototypes.count = 1;
    legacy.prototypes.entries[0] = value.prototypes.entries[0];
    try std.testing.expectError(error.LegacySceneSpawnPrototype, validate(&legacy));
}

test "scene v5 requires explicit behaviors and behavior-driven hazards" {
    const missing_behaviors =
        \\{"schemaVersion":5,"textures":[{"textureId":1,"artifact":"assets/renderer2d/test.texture"}],"objects":[
        \\{"objectId":"goal","kind":"goal","transform":{"position":[10,20]},"sprite":{"size":[3,4],"color":[1,1,1,1],"textureId":1}},
        \\{"objectId":"hazard-1","kind":"patrol_hazard","transform":{"position":[30,40]},"sprite":{"size":[5,6],"color":[1,0,0,1],"textureId":1},"behaviors":[{"scriptId":7,"parameters":{}}]},
        \\{"objectId":"player","kind":"player","transform":{"position":[1,2]},"sprite":{"size":[8,9],"color":[1,1,1,1],"textureId":1},"player":{"moveSpeed":10},"behaviors":[]}]}
    ;
    try std.testing.expectError(error.MissingSceneBehaviors, parse(std.testing.allocator, missing_behaviors));

    const unbound_hazard =
        \\{"schemaVersion":5,"textures":[{"textureId":1,"artifact":"assets/renderer2d/test.texture"}],"objects":[
        \\{"objectId":"goal","kind":"goal","transform":{"position":[10,20]},"sprite":{"size":[3,4],"color":[1,1,1,1],"textureId":1},"behaviors":[]},
        \\{"objectId":"hazard-1","kind":"patrol_hazard","transform":{"position":[30,40]},"sprite":{"size":[5,6],"color":[1,0,0,1],"textureId":1},"behaviors":[]},
        \\{"objectId":"player","kind":"player","transform":{"position":[1,2]},"sprite":{"size":[8,9],"color":[1,1,1,1],"textureId":1},"player":{"moveSpeed":10},"behaviors":[]}]}
    ;
    try std.testing.expectError(error.MissingHazardBehaviorBinding, parse(std.testing.allocator, unbound_hazard));
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
    try std.testing.expectEqual(legacy_object_artifact_version, readLittleU32(artifact[4..8]));
    const value = try parseArtifact(artifact);
    try std.testing.expectEqual(default_scene.objects.count, value.objects.count);
    try std.testing.expectEqualStrings("decoration-1", value.objects.entries[0].objectId.slice());
    try std.testing.expectEqual(default_scene.primaryHazard().patrol.speed, value.primaryHazard().patrol.speed);
    try std.testing.expectEqual(default_scene.player().sprite.textureId, value.player().sprite.textureId);
}

test "KSCN v5 round trips behavior order and f64 parameters" {
    const source = try parse(std.testing.allocator, scene_v5_source);
    const artifact = try encodeArtifact(std.testing.allocator, &source);
    defer std.testing.allocator.free(artifact);
    try std.testing.expectEqual(behavior_artifact_version, readLittleU32(artifact[4..8]));
    try std.testing.expectEqual(behavior_schema_version, readLittleU32(artifact[8..12]));
    const value = try parseArtifact(artifact);
    try std.testing.expectEqual(behavior_schema_version, value.schemaVersion);
    const binding = &value.objects.entries[1].behaviors.entries[0];
    try std.testing.expectEqual(@as(u32, 7), binding.scriptId);
    try std.testing.expectEqualStrings("maxY", binding.parameters[0].name());
    try std.testing.expectEqual(@as(f64, 60), binding.parameters[0].value);
    try std.testing.expectEqualStrings("speed", binding.parameters[2].name());
    try std.testing.expectEqual(@as(f64, 7), binding.parameters[2].value);
}

test "KSCN v6 round trips spawn prototypes while v5 normalizes empty" {
    const source = try parse(std.testing.allocator, scene_v6_source);
    const artifact = try encodeArtifact(std.testing.allocator, &source);
    defer std.testing.allocator.free(artifact);
    try std.testing.expectEqual(@as(u32, 6), readLittleU32(artifact[4..8]));
    try std.testing.expectEqual(@as(u32, 6), readLittleU32(artifact[8..12]));
    const value = try parseArtifact(artifact);
    try std.testing.expectEqual(@as(u8, 1), value.prototypes.count);
    try std.testing.expectEqualStrings("runtime-orb", value.prototypes.entries[0].prototypeId.slice());
    try std.testing.expectEqual(@as(f64, 12), value.prototypes.entries[0].behaviors.entries[0].parameters[0].value);

    const legacy = try parse(std.testing.allocator, scene_v5_source);
    try std.testing.expectEqual(@as(u8, 0), legacy.prototypes.count);
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
