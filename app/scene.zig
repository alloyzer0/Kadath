const std = @import("std");

pub const current_schema_version: u32 = 1;
const max_document_bytes: usize = 64 * 1024;

pub const Sprite = struct {
    position: [2]f32,
    size: [2]f32,
    color: [4]f32,
};

pub const Player = struct {
    position: [2]f32,
    size: [2]f32,
    color: [4]f32,
    moveSpeed: f32,
};

pub const Hazard = struct {
    position: [2]f32,
    size: [2]f32,
    color: [4]f32,
    patrolMinY: f32,
    patrolMaxY: f32,
    patrolSpeed: f32,
};

pub const Scene = struct {
    schemaVersion: u32,
    player: Player,
    goal: Sprite,
    hazard: Hazard,
};

pub const default_scene = Scene{
    .schemaVersion = current_schema_version,
    .player = .{
        .position = .{ 312.0, 130.0 },
        .size = .{ 320.0, 240.0 },
        .color = .{ 1.0, 1.0, 1.0, 1.0 },
        .moveSpeed = 180.0,
    },
    .goal = .{
        .position = .{ 700.0, 200.0 },
        .size = .{ 96.0, 96.0 },
        .color = .{ 1.0, 0.75, 0.10, 1.0 },
    },
    .hazard = .{
        .position = .{ 650.0, 280.0 },
        .size = .{ 96.0, 96.0 },
        .color = .{ 0.95, 0.20, 0.20, 1.0 },
        .patrolMinY = 245.0,
        .patrolMaxY = 330.0,
        .patrolSpeed = 80.0,
    },
};

pub fn load(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Scene {
    const contents = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_document_bytes));
    defer allocator.free(contents);
    return parse(allocator, contents);
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

test "scene v1 parses a valid preview document" {
    const contents =
        \\{
        \\  "schemaVersion": 1,
        \\  "player": { "position": [100, 120], "size": [64, 64], "color": [1, 1, 1, 1], "moveSpeed": 200 },
        \\  "goal": { "position": [444, 180], "size": [48, 48], "color": [0.2, 0.9, 0.3, 1] },
        \\  "hazard": { "position": [300, 220], "size": [40, 40], "color": [0.9, 0.2, 0.2, 1], "patrolMinY": 180, "patrolMaxY": 260, "patrolSpeed": 75 }
        \\}
    ;
    const scene = try parse(std.testing.allocator, contents);
    try std.testing.expectEqual(@as(f32, 444.0), scene.goal.position[0]);
    try std.testing.expectEqual(@as(f32, 75.0), scene.hazard.patrolSpeed);
}

test "scene v1 rejects unsupported schema" {
    const contents =
        \\{
        \\  "schemaVersion": 2,
        \\  "player": { "position": [100, 120], "size": [64, 64], "color": [1, 1, 1, 1], "moveSpeed": 200 },
        \\  "goal": { "position": [444, 180], "size": [48, 48], "color": [0.2, 0.9, 0.3, 1] },
        \\  "hazard": { "position": [300, 220], "size": [40, 40], "color": [0.9, 0.2, 0.2, 1], "patrolMinY": 180, "patrolMaxY": 260, "patrolSpeed": 75 }
        \\}
    ;
    try std.testing.expectError(error.UnsupportedSceneSchema, parse(std.testing.allocator, contents));
}

test "scene v1 rejects an invalid patrol range" {
    var scene = default_scene;
    scene.hazard.patrolMinY = scene.hazard.patrolMaxY;
    try std.testing.expectError(error.InvalidHazardPatrol, validate(scene));
}
