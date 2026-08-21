const std = @import("std");
const collision = @import("collision.zig");
const runtime_object_registry = @import("runtime_object_registry.zig");
const scene_api = @import("scene.zig");
const PlatformExtent = @import("platform").WindowExtent;
const world_api = @import("world");
const World = world_api.World;

pub const SceneContactTarget = struct {
    object_index: u8,
    object_id: scene_api.ObjectId,
    entity: world_api.EntityId,
};

pub const SceneContacts = struct {
    player_entity: world_api.EntityId,
    hazard: ?SceneContactTarget = null,
    goal: ?SceneContactTarget = null,
    touching: [scene_api.max_scene_object_count]bool = [_]bool{false} ** scene_api.max_scene_object_count,
};

pub const ObjectPositionUpdate = struct {
    object_index: u8,
    position: [2]f32,
};

const HazardState = struct {
    object_index: u8 = 0,
    entity: world_api.EntityId = world_api.invalid_entity,
    y: f32 = 0.0,
    direction: f32 = 1.0,
};

pub const SceneGeneration = struct {
    scene: scene_api.Scene,
    world: World,
    runtime_objects: runtime_object_registry.Registry,
    extent: PlatformExtent,
    entity_by_object: [scene_api.max_scene_object_count]world_api.EntityId = [_]world_api.EntityId{world_api.invalid_entity} ** scene_api.max_scene_object_count,
    player_index: u8,
    goal_index: u8,
    hazards: [scene_api.max_scene_object_count]HazardState = [_]HazardState{.{}} ** scene_api.max_scene_object_count,
    hazard_count: u8 = 0,
    goal_position: [2]f32,

    pub fn prepare(value: scene_api.Scene, extent: PlatformExtent) !SceneGeneration {
        try scene_api.validate(&value);
        var runtime_world = try World.init();
        errdefer runtime_world.deinit();
        try runtime_world.setBounds(worldBounds(extent));
        var runtime_objects = try runtime_object_registry.Registry.init(&value);

        var entities = [_]world_api.EntityId{world_api.invalid_entity} ** scene_api.max_scene_object_count;
        var player_index: ?u8 = null;
        var goal_index: ?u8 = null;
        var hazards = [_]HazardState{.{}} ** scene_api.max_scene_object_count;
        var hazard_count: u8 = 0;
        for (value.objects.slice(), 0..) |object, index| {
            const entity = try runtime_world.spawnSprite(spawnDesc(&object));
            entities[index] = entity;
            try runtime_objects.bindSourceEntity(index, entity);
            switch (object.kind) {
                .sprite => {},
                .player => player_index = @intCast(index),
                .goal => goal_index = @intCast(index),
                .patrol_hazard => {
                    hazards[hazard_count] = .{
                        .object_index = @intCast(index),
                        .entity = entity,
                        .y = object.sprite.position[1],
                    };
                    hazard_count += 1;
                },
            }
        }

        var generation = SceneGeneration{
            .scene = value,
            .world = runtime_world,
            .runtime_objects = runtime_objects,
            .extent = extent,
            .entity_by_object = entities,
            .player_index = player_index orelse return error.SceneGenerationMissingPlayer,
            .goal_index = goal_index orelse return error.SceneGenerationMissingGoal,
            .hazards = hazards,
            .hazard_count = hazard_count,
            .goal_position = value.goal().sprite.position,
        };
        try generation.setGoalPosition(value.goal().sprite.position);
        return generation;
    }

    pub fn prepareRestart(
        value: scene_api.Scene,
        extent: PlatformExtent,
        previous: *const SceneGeneration,
    ) !SceneGeneration {
        var generation = try prepare(value, extent);
        generation.runtime_objects.next_spawn_serial = previous.runtime_objects.next_spawn_serial;
        return generation;
    }

    pub fn deinit(self: *SceneGeneration) void {
        self.world.deinit();
        self.runtime_objects = .{};
        self.entity_by_object = [_]world_api.EntityId{world_api.invalid_entity} ** scene_api.max_scene_object_count;
        self.hazard_count = 0;
    }

    pub fn reset(self: *SceneGeneration) !void {
        try self.clearTransients();
        const player_object = &self.scene.objects.entries[self.player_index];
        const replacement = try self.world.replaceSprite(self.playerEntity(), spawnDesc(player_object));
        self.entity_by_object[self.player_index] = replacement;
        try self.runtime_objects.bindSourceEntity(self.player_index, replacement);

        for (self.scene.objects.slice(), 0..) |object, index| {
            if (index == self.player_index) continue;
            try self.world.setSpritePosition(self.entity_by_object[index], object.sprite.position);
        }
        for (self.hazards[0..self.hazard_count]) |*hazard| {
            const object = &self.scene.objects.entries[hazard.object_index];
            hazard.entity = self.entity_by_object[hazard.object_index];
            hazard.y = object.sprite.position[1];
            hazard.direction = 1.0;
        }
        try self.setGoalPosition(self.scene.goal().sprite.position);
    }

    pub fn stepFixed(self: *SceneGeneration, dt_seconds: f32, input: world_api.InputSnapshot) !void {
        if (!@import("std").math.isFinite(dt_seconds) or dt_seconds < 0.0) return error.InvalidFixedDelta;
        if (self.scene.schemaVersion == scene_api.legacy_object_schema_version) {
            for (self.hazards[0..self.hazard_count]) |*hazard| {
                const object = &self.scene.objects.entries[hazard.object_index];
                const advanced = advancePatrol(hazard.y, hazard.direction, object.patrol, dt_seconds);
                hazard.y = advanced.y;
                hazard.direction = advanced.direction;
                try self.world.setSpritePosition(hazard.entity, .{ object.sprite.position[0], hazard.y });
            }
        }
        try self.world.stepFixed(dt_seconds, input);
    }

    pub fn applyTranslationDeltas(self: *SceneGeneration, deltas: []const [2]f64) !void {
        if (deltas.len != self.runtime_objects.activeCount()) return error.InvalidBehaviorTranslationBatch;
        var sprites: [runtime_object_registry.max_runtime_object_count]world_api.RenderSprite = undefined;
        const ordered = try self.extractOrdered(&sprites);
        var targets: [runtime_object_registry.max_runtime_object_count][2]f32 = undefined;
        for (ordered, 0..) |sprite, index| {
            const target_x = @as(f64, sprite.position[0]) + deltas[index][0];
            const target_y = @as(f64, sprite.position[1]) + deltas[index][1];
            if (!@import("std").math.isFinite(target_x) or
                !@import("std").math.isFinite(target_y) or
                @abs(target_x) > @import("std").math.floatMax(f32) or
                @abs(target_y) > @import("std").math.floatMax(f32))
            {
                return error.InvalidBehaviorTranslation;
            }
            targets[index] = .{ @floatCast(target_x), @floatCast(target_y) };
        }
        var handles: [runtime_object_registry.max_runtime_object_count]runtime_object_registry.Handle = undefined;
        const active = self.runtime_objects.activeHandles(&handles);
        for (targets[0..active.len], deltas, active) |target, delta, handle| {
            if (delta[0] == 0 and delta[1] == 0) continue;
            const record = self.runtime_objects.resolve(handle) orelse return error.UnknownSceneObject;
            try self.world.setSpritePosition(record.entity, target);
            if (record.source_index == @as(?u8, self.goal_index)) self.goal_position = target;
            for (self.hazards[0..self.hazard_count]) |*hazard| {
                if (record.source_index == @as(?u8, hazard.object_index)) {
                    hazard.y = target[1];
                    break;
                }
            }
        }
    }

    pub fn setGoalPosition(self: *SceneGeneration, position: [2]f32) !void {
        const goal = self.scene.goal();
        const clamped = clampPosition(position, goal.sprite.size, self.extent);
        try self.world.setSpritePosition(self.goalEntity(), clamped);
        self.goal_position = clamped;
    }

    pub fn setExtent(self: *SceneGeneration, extent: PlatformExtent) !void {
        if (extent.width == 0 or extent.height == 0) return;
        try self.world.setBounds(worldBounds(extent));
        self.extent = extent;
        try self.setGoalPosition(self.goal_position);
    }

    pub fn observeContacts(self: *const SceneGeneration) !SceneContacts {
        var sprites: [scene_api.max_scene_object_count]world_api.RenderSprite = undefined;
        const ordered = try self.extractOrdered(&sprites);
        const player_entity = self.playerEntity();
        const player = bodyForEntity(ordered, player_entity) orelse return error.WorldProducedNoPlayerSprite;
        var contacts = SceneContacts{ .player_entity = player_entity };
        for (self.hazards[0..self.hazard_count]) |hazard| {
            const hazard_body = bodyForEntity(ordered, hazard.entity) orelse return error.WorldProducedNoHazardSprite;
            if (collision.queryContact(player, hazard_body) != null) {
                contacts.touching[hazard.object_index] = true;
                if (contacts.hazard == null) {
                    contacts.hazard = .{
                        .object_index = hazard.object_index,
                        .object_id = self.scene.objects.entries[hazard.object_index].objectId,
                        .entity = hazard.entity,
                    };
                }
            }
        }
        const goal_entity = self.goalEntity();
        const goal = bodyForEntity(ordered, goal_entity) orelse return error.WorldProducedNoGoalSprite;
        if (collision.queryContact(player, goal) != null) {
            contacts.touching[self.goal_index] = true;
            contacts.goal = .{
                .object_index = self.goal_index,
                .object_id = self.scene.objects.entries[self.goal_index].objectId,
                .entity = goal_entity,
            };
        }
        return contacts;
    }

    pub fn extractSprites(self: *const SceneGeneration, output: []world_api.RenderSprite) ![]world_api.RenderSprite {
        if (output.len < self.runtime_objects.activeCount()) return error.WorldRenderBufferTooSmall;
        return self.extractOrdered(output);
    }

    pub fn reserveTransient(
        self: *SceneGeneration,
        prototype_id: []const u8,
        position: [2]f32,
    ) !runtime_object_registry.ReservedSpawn {
        const prototype_index = self.scene.prototypes.indexOfId(prototype_id) orelse return error.UnknownSpawnPrototype;
        const prototype = &self.scene.prototypes.entries[prototype_index];
        const reserved = try self.runtime_objects.reserveSpawn(@intCast(prototype_index), position, prototype.behaviors.count);
        errdefer self.runtime_objects.requestDestroy(reserved.handle) catch {};
        try self.runtime_objects.configurePending(reserved.handle, prototype);
        return reserved;
    }

    pub fn activateTransient(self: *SceneGeneration, handle: runtime_object_registry.Handle) !void {
        const record = self.runtime_objects.resolveForCommit(handle) orelse return error.StaleRuntimeObject;
        if (record.state != .pending_spawn) return error.InvalidRuntimeObjectActivation;
        const entity = try self.world.spawnSprite(spawnDescForSprite(record.sprite));
        errdefer self.world.despawn(entity) catch {};
        try self.runtime_objects.activate(handle, entity);
    }

    pub fn requestTransientDestroy(self: *SceneGeneration, handle: runtime_object_registry.Handle) !void {
        try self.runtime_objects.requestDestroy(handle);
    }

    pub fn commitTransientDestroy(self: *SceneGeneration, handle: runtime_object_registry.Handle) !void {
        const record = self.runtime_objects.resolveForCommit(handle) orelse return error.StaleRuntimeObject;
        if (record.state != .pending_destroy or record.entity == world_api.invalid_entity) return error.InvalidRuntimeObjectDestroy;
        try self.world.despawn(record.entity);
        try self.runtime_objects.completeDestroy(handle);
    }

    pub fn runtimeObject(self: *SceneGeneration, handle: runtime_object_registry.Handle) ?*runtime_object_registry.Record {
        return self.runtime_objects.resolve(handle);
    }

    pub fn runtimeHandle(self: *SceneGeneration, object_id: []const u8) ?runtime_object_registry.Handle {
        return self.runtime_objects.findHandle(object_id);
    }

    pub fn runtimeHandleAt(self: *SceneGeneration, object_index: usize) ?runtime_object_registry.Handle {
        if (object_index >= runtime_object_registry.max_runtime_object_count) return null;
        const record = &self.runtime_objects.records[object_index];
        if (record.state == .stale or record.state == .pending_destroy) return null;
        return record.handle(object_index);
    }

    pub fn clearTransients(self: *SceneGeneration) !void {
        for (&self.runtime_objects.records, 0..) |*record, index| {
            if (record.source_index != null or record.state == .stale) continue;
            const handle = record.handle(index);
            if ((record.state == .active or record.state == .pending_destroy) and record.entity != world_api.invalid_entity) {
                try self.world.despawn(record.entity);
            }
            try self.runtime_objects.discardTransient(handle);
        }
    }

    pub fn playerEntity(self: *const SceneGeneration) world_api.EntityId {
        return self.entity_by_object[self.player_index];
    }

    pub fn playerObjectIndex(self: *const SceneGeneration) usize {
        return self.player_index;
    }

    pub fn goalEntity(self: *const SceneGeneration) world_api.EntityId {
        return self.entity_by_object[self.goal_index];
    }

    pub fn entityForObject(self: *const SceneGeneration, object_index: usize) ?world_api.EntityId {
        if (object_index >= self.scene.objects.count) return null;
        return self.entity_by_object[object_index];
    }

    pub fn objectIndex(self: *const SceneGeneration, object_id: []const u8) ?usize {
        const mutable: *SceneGeneration = @constCast(self);
        const handle = mutable.runtime_objects.findHandle(object_id) orelse return null;
        return handle.slot;
    }

    pub fn objectKind(self: *const SceneGeneration, object_index: usize) ?scene_api.ObjectKind {
        if (object_index >= runtime_object_registry.max_runtime_object_count) return null;
        const mutable: *SceneGeneration = @constCast(self);
        const record = &mutable.runtime_objects.records[object_index];
        if (record.state == .stale or record.state == .pending_destroy) return null;
        return record.kind;
    }

    pub fn objectPosition(self: *const SceneGeneration, object_index: usize) ![2]f32 {
        if (object_index >= runtime_object_registry.max_runtime_object_count) return error.UnknownSceneObject;
        const mutable: *SceneGeneration = @constCast(self);
        const record = &mutable.runtime_objects.records[object_index];
        if (record.state == .pending_spawn) return record.sprite.position;
        if (record.state != .active) return error.UnknownSceneObject;
        var sprites: [runtime_object_registry.max_runtime_object_count]world_api.RenderSprite = undefined;
        const unordered = try self.world.extractSprites(&sprites);
        return (findSprite(unordered, record.entity) orelse return error.WorldProducedIncompleteScene).position;
    }

    pub fn setObjectPosition(self: *SceneGeneration, object_index: usize, position: [2]f32) !void {
        if (object_index >= runtime_object_registry.max_runtime_object_count) return error.UnknownSceneObject;
        if (!@import("std").math.isFinite(position[0]) or !@import("std").math.isFinite(position[1])) {
            return error.InvalidBehaviorPosition;
        }
        const record = &self.runtime_objects.records[object_index];
        if (record.state == .pending_spawn) {
            record.sprite.position = position;
            return;
        }
        if (record.state != .active) return error.UnknownSceneObject;
        if (record.source_index != null and object_index == self.goal_index) {
            try self.setGoalPosition(position);
            return;
        }
        try self.world.setSpritePosition(record.entity, position);
        const actual = try self.objectPosition(object_index);
        for (self.hazards[0..self.hazard_count]) |*hazard| {
            if (hazard.object_index == object_index) {
                hazard.y = actual[1];
                break;
            }
        }
    }

    pub fn applyObjectPositionsAtomically(self: *SceneGeneration, updates: []const ObjectPositionUpdate) !void {
        if (updates.len > runtime_object_registry.max_runtime_object_count) return error.InvalidBehaviorPositionBatch;
        var previous: [runtime_object_registry.max_runtime_object_count][2]f32 = undefined;
        var seen = [_]bool{false} ** runtime_object_registry.max_runtime_object_count;
        for (updates, 0..) |update, index| {
            if (update.object_index >= runtime_object_registry.max_runtime_object_count or seen[update.object_index]) {
                return error.InvalidBehaviorPositionBatch;
            }
            if (!std.math.isFinite(update.position[0]) or !std.math.isFinite(update.position[1])) {
                return error.InvalidBehaviorPosition;
            }
            seen[update.object_index] = true;
            previous[index] = try self.objectPosition(update.object_index);
        }

        var applied: usize = 0;
        errdefer {
            while (applied > 0) {
                applied -= 1;
                self.setObjectPosition(updates[applied].object_index, previous[applied]) catch {
                    @panic("Runtime object position rollback failed");
                };
            }
        }
        for (updates) |update| {
            try self.setObjectPosition(update.object_index, update.position);
            applied += 1;
        }
    }

    pub fn objectIdForEntity(self: *const SceneGeneration, entity: world_api.EntityId) ?scene_api.ObjectId {
        for (self.runtime_objects.records) |record| {
            if (record.state == .active and record.entity == entity) return record.object_id;
        }
        return null;
    }

    pub fn goalPosition(self: *const SceneGeneration) [2]f32 {
        return self.goal_position;
    }

    pub fn primaryHazardY(self: *const SceneGeneration) f32 {
        return self.hazards[0].y;
    }

    fn extractOrdered(self: *const SceneGeneration, output: []world_api.RenderSprite) ![]world_api.RenderSprite {
        var unordered_storage: [runtime_object_registry.max_runtime_object_count]world_api.RenderSprite = undefined;
        const unordered = try self.world.extractSprites(&unordered_storage);
        const mutable: *SceneGeneration = @constCast(self);
        var handles: [runtime_object_registry.max_runtime_object_count]runtime_object_registry.Handle = undefined;
        const active = mutable.runtime_objects.activeHandles(&handles);
        if (unordered.len != active.len) return error.WorldProducedIncompleteScene;
        for (active, 0..) |handle, index| {
            const record = mutable.runtime_objects.resolve(handle) orelse return error.WorldProducedIncompleteScene;
            output[index] = findSprite(unordered, record.entity) orelse return error.WorldProducedIncompleteScene;
        }
        return output[0..active.len];
    }
};

fn spawnDesc(object: *const scene_api.SceneObject) world_api.SpriteSpawnDesc {
    return .{
        .position = object.sprite.position,
        .size = object.sprite.size,
        .color = object.sprite.color,
        .texture_id = object.sprite.textureId,
        .move_speed = if (object.kind == .player) object.player.moveSpeed else 0.0,
    };
}

fn spawnDescForSprite(sprite: scene_api.Sprite) world_api.SpriteSpawnDesc {
    return .{
        .position = sprite.position,
        .size = sprite.size,
        .color = sprite.color,
        .texture_id = sprite.textureId,
        .move_speed = 0,
    };
}

fn worldBounds(extent: PlatformExtent) world_api.WorldBounds {
    return .{
        .min = .{ 0.0, 0.0 },
        .max = .{ @floatFromInt(extent.width), @floatFromInt(extent.height) },
    };
}

const AdvancedPatrol = struct { y: f32, direction: f32 };

fn advancePatrol(y: f32, direction: f32, patrol: scene_api.PatrolPayload, dt_seconds: f32) AdvancedPatrol {
    if (patrol.speed == 0.0 or dt_seconds == 0.0) return .{ .y = y, .direction = direction };
    const min_y: f64 = patrol.minY;
    const max_y: f64 = patrol.maxY;
    const span = max_y - min_y;
    const period = span * 2.0;
    const signed_distance: f64 = @as(f64, patrol.speed) * @as(f64, dt_seconds) * @as(f64, direction);
    const phase = @mod(@as(f64, y) - min_y + signed_distance, period);
    if (phase < span) return .{ .y = @floatCast(min_y + phase), .direction = 1.0 };
    if (phase > span) return .{ .y = @floatCast(max_y - (phase - span)), .direction = -1.0 };
    return .{ .y = patrol.maxY, .direction = -1.0 };
}

fn clampPosition(position: [2]f32, size: [2]f32, extent: PlatformExtent) [2]f32 {
    const max_x = @max(0.0, @as(f32, @floatFromInt(extent.width)) - size[0]);
    const max_y = @max(0.0, @as(f32, @floatFromInt(extent.height)) - size[1]);
    return .{
        @min(@max(position[0], 0.0), max_x),
        @min(@max(position[1], 0.0), max_y),
    };
}

fn findSprite(sprites: []const world_api.RenderSprite, entity: world_api.EntityId) ?world_api.RenderSprite {
    for (sprites) |sprite| {
        if (sprite.entity_id == entity) return sprite;
    }
    return null;
}

fn bodyForEntity(sprites: []const world_api.RenderSprite, entity: world_api.EntityId) ?collision.Body {
    const sprite = findSprite(sprites, entity) orelse return null;
    return .{
        .entity_id = entity,
        .aabb = .{ .position = sprite.position, .size = sprite.size },
    };
}

test "SceneGeneration preserves source order and updates independent hazards" {
    var generation = try SceneGeneration.prepare(scene_api.default_scene, .{ .width = 1024, .height = 720 });
    defer generation.deinit();
    var before: [scene_api.max_scene_object_count]world_api.RenderSprite = undefined;
    const initial = try generation.extractSprites(&before);
    try @import("std").testing.expectEqual(@as(usize, 5), initial.len);
    try @import("std").testing.expectEqual(generation.entityForObject(0).?, initial[0].entity_id);
    const first_y = initial[2].position[1];
    const second_y = initial[3].position[1];
    try generation.stepFixed(1.0 / 60.0, .{});
    var after: [scene_api.max_scene_object_count]world_api.RenderSprite = undefined;
    const stepped = try generation.extractSprites(&after);
    try @import("std").testing.expect(stepped[2].position[1] != first_y);
    try @import("std").testing.expect(stepped[3].position[1] != second_y);
    try @import("std").testing.expect(stepped[2].position[1] - first_y != stepped[3].position[1] - second_y);
}

test "SceneGeneration activates and despawns transient prototype objects without exposing pending state" {
    var scene = scene_api.default_scene;
    scene.schemaVersion = scene_api.current_schema_version;
    for (scene.objects.mutableSlice()) |*object| {
        if (object.kind == .patrol_hazard) {
            object.behaviors.count = 1;
            object.behaviors.entries[0].scriptId = 7;
        }
    }
    scene.prototypes.count = 1;
    scene.prototypes.entries[0] = .{
        .prototypeId = try scene_api.PrototypeId.init("runtime-orb"),
        .sprite = .{ .size = .{ 12, 8 }, .color = .{ 1, 1, 1, 1 }, .textureId = 1 },
    };
    var generation = try SceneGeneration.prepare(scene, .{ .width = 1024, .height = 720 });
    defer generation.deinit();

    const pending = try generation.reserveTransient("runtime-orb", .{ 20, 30 });
    var before: [runtime_object_registry.max_runtime_object_count]world_api.RenderSprite = undefined;
    try std.testing.expectEqual(scene.objects.count, (try generation.extractSprites(&before)).len);

    try generation.activateTransient(pending.handle);
    const active = try generation.extractSprites(&before);
    try std.testing.expectEqual(scene.objects.count + 1, active.len);
    try std.testing.expectEqual(@as(f32, 20), active[active.len - 1].position[0]);

    try generation.requestTransientDestroy(pending.handle);
    try generation.commitTransientDestroy(pending.handle);
    try std.testing.expectEqual(scene.objects.count, (try generation.extractSprites(&before)).len);
    try std.testing.expect(generation.runtimeObject(pending.handle) == null);

    const restart_transient = try generation.reserveTransient("runtime-orb", .{ 40, 50 });
    try generation.activateTransient(restart_transient.handle);
    try generation.reset();
    try std.testing.expect(generation.runtimeObject(restart_transient.handle) == null);
    const after_restart = try generation.reserveTransient("runtime-orb", .{ 60, 70 });
    try std.testing.expectEqualStrings("runtime-0000000000000003", after_restart.object_id.slice());

    var replacement = try SceneGeneration.prepareRestart(scene, .{ .width = 1024, .height = 720 }, &generation);
    defer replacement.deinit();
    const replacement_transient = try replacement.reserveTransient("runtime-orb", .{ 80, 90 });
    try std.testing.expectEqualStrings("runtime-0000000000000004", replacement_transient.object_id.slice());
}

test "SceneGeneration contacts ignore decorative sprites" {
    var value = scene_api.default_scene;
    const player_index = value.objects.indexOfKind(.player).?;
    value.objects.entries[player_index].sprite.position = value.objects.entries[0].sprite.position;
    var generation = try SceneGeneration.prepare(value, .{ .width = 1024, .height = 720 });
    defer generation.deinit();
    const contacts = try generation.observeContacts();
    try @import("std").testing.expect(contacts.hazard == null);
    try @import("std").testing.expect(contacts.goal == null);
}

test "SceneGeneration reports contact with any patrol hazard" {
    var value = scene_api.default_scene;
    const player_index = value.objects.indexOfKind(.player).?;
    value.objects.entries[player_index].sprite.position = value.objects.entries[3].sprite.position;
    value.objects.entries[player_index].sprite.size = .{ 1.0, 1.0 };
    var generation = try SceneGeneration.prepare(value, .{ .width = 1024, .height = 720 });
    defer generation.deinit();
    const contacts = try generation.observeContacts();
    try @import("std").testing.expectEqualStrings("hazard-2", contacts.hazard.?.object_id.slice());
}

test "SceneGeneration patrol reflection remains bounded after large travel" {
    var generation = try SceneGeneration.prepare(scene_api.default_scene, .{ .width = 1024, .height = 720 });
    defer generation.deinit();
    try generation.stepFixed(1000.0, .{});
    for (generation.hazards[0..generation.hazard_count]) |hazard| {
        const patrol = generation.scene.objects.entries[hazard.object_index].patrol;
        try @import("std").testing.expect(hazard.y >= patrol.minY and hazard.y <= patrol.maxY);
    }
    try @import("std").testing.expectError(error.InvalidFixedDelta, generation.stepFixed(-1.0, .{}));
}

test "SceneGeneration v5 stops native patrol and applies one validated translation batch" {
    var value = scene_api.default_scene;
    value.schemaVersion = scene_api.current_schema_version;
    for (value.objects.mutableSlice()) |*object| {
        if (object.kind != .patrol_hazard) continue;
        object.behaviors.count = 1;
        object.behaviors.entries[0].scriptId = 1;
    }
    var generation = try SceneGeneration.prepare(value, .{ .width = 1024, .height = 720 });
    defer generation.deinit();
    var before_storage: [scene_api.max_scene_object_count]world_api.RenderSprite = undefined;
    const before = try generation.extractSprites(&before_storage);
    try generation.stepFixed(1.0, .{});
    var native_step_storage: [scene_api.max_scene_object_count]world_api.RenderSprite = undefined;
    const native_step = try generation.extractSprites(&native_step_storage);
    try @import("std").testing.expectEqual(before[2].position, native_step[2].position);
    try @import("std").testing.expectEqual(before[3].position, native_step[3].position);

    var deltas = [_][2]f64{.{ 0, 0 }} ** scene_api.max_scene_object_count;
    deltas[2] = .{ 0, 5 };
    deltas[3] = .{ -2, -7 };
    try generation.applyTranslationDeltas(deltas[0..value.objects.count]);
    var after_storage: [scene_api.max_scene_object_count]world_api.RenderSprite = undefined;
    const after = try generation.extractSprites(&after_storage);
    try @import("std").testing.expectApproxEqAbs(before[2].position[1] + 5, after[2].position[1], 0.0001);
    try @import("std").testing.expectApproxEqAbs(before[3].position[0] - 2, after[3].position[0], 0.0001);
    try @import("std").testing.expectApproxEqAbs(before[3].position[1] - 7, after[3].position[1], 0.0001);
}
