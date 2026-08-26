const std = @import("std");
const runtime_core = @import("runtime_core");
const scene_api = @import("scene.zig");
const PlatformExtent = @import("platform").WindowExtent;

pub const ObjectPositionUpdate = struct {
    object_index: u8,
    position: [2]f32,
};

pub const LifecycleState = enum { pending_spawn, active, pending_destroy };
pub const RuntimeHandle = runtime_core.ObjectRef;

pub const RuntimeRecord = struct {
    state: LifecycleState,
    object_id: scene_api.ObjectId,
    logical_generation: u64,
    source_index: ?u8,
    prototype_index: ?u8,
    kind: scene_api.ObjectKind,
    sprite: scene_api.Sprite,
    entity: runtime_core.EntityId,
    behavior_count: u8,
};

pub const ReservedSpawn = struct {
    handle: RuntimeHandle,
    object_id: scene_api.ObjectId,
};

pub const ActivationCommand = runtime_core.ActivationCommand;

const HazardSource = struct {
    object_index: u8 = 0,
};

pub const SceneGeneration = struct {
    scene: *scene_api.Scene,
    core: runtime_core.RuntimeCore,
    target: runtime_core.Target,
    extent: PlatformExtent,
    player_index: u8,
    goal_index: u8,
    hazards: [scene_api.max_scene_object_count]HazardSource = [_]HazardSource{.{}} ** scene_api.max_scene_object_count,
    hazard_count: u8 = 0,
    phase_candidate_ready: bool = false,

    pub fn prepare(value: *const scene_api.Scene, extent: PlatformExtent) !SceneGeneration {
        var core = try runtime_core.RuntimeCore.init();
        errdefer core.deinit();
        var generation = try prepareWithCore(value, extent, core, .initial, .live);
        errdefer std.heap.page_allocator.destroy(generation.scene);
        try generation.ensurePairedPhaseCandidate();
        try generation.core.commitScene();
        generation.phase_candidate_ready = false;
        return generation;
    }

    pub fn prepareRestart(value: *const scene_api.Scene, extent: PlatformExtent, previous: *const SceneGeneration) !SceneGeneration {
        return prepareWithCore(value, extent, previous.core.borrow(), .restart, .candidate);
    }

    pub fn prepareSceneReload(value: *const scene_api.Scene, extent: PlatformExtent, previous: *const SceneGeneration) !SceneGeneration {
        return prepareWithCore(value, extent, previous.core.borrow(), .scene_reload, .candidate);
    }

    pub fn commitPrepared(self: *SceneGeneration, previous: *SceneGeneration) !void {
        if (self.target != .candidate) return error.RuntimeCoreInvalidState;
        // Complete every fallible projection query while both candidates remain private.
        // After commitScene, ownership transfer and the target flip are no-fail operations.
        try self.ensurePairedPhaseCandidate();
        try self.core.commitScene();
        self.phase_candidate_ready = false;
        self.core.takeOwnership(&previous.core);
        self.target = .live;
    }

    pub fn deinit(self: *SceneGeneration) void {
        if (self.target == .candidate) {
            self.core.abortPhaseState() catch |err| {
                std.log.err("Runtime Core Phase candidate abort failed: {s}", .{@errorName(err)});
            };
            self.core.abortScene() catch |err| {
                std.log.err("Runtime Core candidate abort failed: {s}", .{@errorName(err)});
            };
        }
        self.core.deinit();
        std.heap.page_allocator.destroy(self.scene);
        self.hazard_count = 0;
    }

    pub fn reset(self: *SceneGeneration) !void {
        var sources: [scene_api.max_scene_object_count]runtime_core.SourceDesc = undefined;
        const source_slice = sourceDescriptors(self.scene, &sources);
        _ = try self.core.prepare(.restart, .{ 0, 0 }, boundsMax(self.extent), source_slice);
        errdefer {
            self.core.abortPhaseState() catch {};
            self.core.abortScene() catch {};
            self.phase_candidate_ready = false;
        }
        self.phase_candidate_ready = false;
        try self.prepareGameplay();
        try self.ensurePairedPhaseCandidate();
        try self.core.commitScene();
        self.phase_candidate_ready = false;
    }

    pub fn beginGameplayFixed(self: *SceneGeneration, dt_seconds: f32, outcome: *runtime_core.GameplayOutcome) !runtime_core.GameplayStepResult {
        return self.core.beginGameplayFixed(dt_seconds, outcome);
    }

    pub fn commitGameplayFixed(self: *SceneGeneration, token: u64, input: runtime_core.InputSnapshot, outcome: *runtime_core.GameplayOutcome) !runtime_core.GameplayStepResult {
        return self.core.commitGameplayFixed(token, input, outcome);
    }

    pub fn applyTranslationDeltas(self: *SceneGeneration, deltas: []const [2]f64) !void {
        var views: [runtime_core.max_object_count]runtime_core.ObjectView = undefined;
        const active = try self.core.snapshot(self.target, true, &views);
        if (deltas.len != active.len) return error.InvalidBehaviorTranslationBatch;
        var patches: [runtime_core.max_object_count]runtime_core.PositionPatch = undefined;
        var count: usize = 0;
        for (active, deltas) |view, delta| {
            const target_x = @as(f64, view.position[0]) + delta[0];
            const target_y = @as(f64, view.position[1]) + delta[1];
            if (!std.math.isFinite(target_x) or !std.math.isFinite(target_y) or
                @abs(target_x) > std.math.floatMax(f32) or @abs(target_y) > std.math.floatMax(f32))
            {
                return error.InvalidBehaviorTranslation;
            }
            if (delta[0] == 0 and delta[1] == 0) continue;
            patches[count] = .{ .object_ref = view.object_ref, .position = .{ @floatCast(target_x), @floatCast(target_y) } };
            count += 1;
        }
        if (count != 0) try self.core.applyPositions(self.target, patches[0..count]);
    }

    pub fn setGoalPosition(self: *SceneGeneration, position: [2]f32) !void {
        const goal = self.scene.goal();
        const clamped = clampPosition(position, goal.sprite.size, self.extent);
        try self.setObjectPosition(self.goal_index, clamped);
    }

    pub fn setExtent(self: *SceneGeneration, extent: PlatformExtent) !void {
        if (extent.width == 0 or extent.height == 0) return;
        try self.core.setBounds(self.target, .{ 0, 0 }, boundsMax(extent));
        self.extent = extent;
        try self.setGoalPosition(self.goalPosition());
    }

    pub fn extractSprites(self: *SceneGeneration, output: []runtime_core.RenderSprite) !struct { sprites: []runtime_core.RenderSprite, snapshot: runtime_core.GameplaySnapshot } {
        const snapshot = try self.core.gameplaySnapshot(output);
        return .{ .sprites = output[0..snapshot.render_count], .snapshot = snapshot };
    }

    /// Runtime identity 由 Rust Core 统一产生；SceneGeneration 只提供只读 Adapter。
    pub fn worldEpoch(self: *const SceneGeneration) !u64 {
        return self.core.worldEpoch(self.target);
    }

    pub fn reserveTransient(self: *SceneGeneration, prototype_id: []const u8, position: [2]f32) !ReservedSpawn {
        const prototype_index = self.scene.prototypes.indexOfId(prototype_id) orelse return error.UnknownSpawnPrototype;
        const prototype = &self.scene.prototypes.entries[prototype_index];
        const view = try self.core.reserveTransient(.{
            .prototype_key = @intCast(prototype_index),
            .kind = kindCode(prototype.kind),
            .sprite = .{
                .position = position,
                .size = prototype.sprite.size,
                .color = prototype.sprite.color,
                .texture_id = prototype.sprite.textureId,
            },
        });
        return .{ .handle = view.object_ref, .object_id = try objectId(view.object_ref) };
    }

    pub fn activateTransient(self: *SceneGeneration, handle: RuntimeHandle) !void {
        try self.core.activate(handle);
    }

    pub fn discardTransient(self: *SceneGeneration, handle: RuntimeHandle) !void {
        try self.core.discard(handle);
    }

    pub fn requestTransientDestroy(self: *SceneGeneration, handle: RuntimeHandle) !void {
        _ = try self.core.requestDestroy(handle);
    }

    pub fn requestTransientDestroyDisposition(self: *SceneGeneration, handle: RuntimeHandle) !runtime_core.DestroyDisposition {
        return self.core.requestDestroy(handle);
    }

    pub fn commitTransientDestroy(self: *SceneGeneration, handle: RuntimeHandle) !void {
        try self.core.finalizeDestroy(handle);
    }

    pub fn runtimeObject(self: *const SceneGeneration, handle: RuntimeHandle) ?RuntimeRecord {
        const view = (self.core.resolve(self.target, handle) catch return null) orelse return null;
        return self.runtimeRecordFromView(view);
    }

    /// 供同一批次的 Adapter 复用已取出的 Rust view，避免逐对象再次跨 ABI 查询。
    pub fn runtimeRecordFromView(self: *const SceneGeneration, view: runtime_core.ObjectView) ?RuntimeRecord {
        var value = record(view) catch return null;
        value.behavior_count = if (value.source_index) |index|
            self.scene.objects.entries[index].behaviors.count
        else if (value.prototype_index) |index|
            self.scene.prototypes.entries[index].behaviors.count
        else
            return null;
        return value;
    }

    pub fn runtimeHandle(self: *const SceneGeneration, object_id: []const u8) ?RuntimeHandle {
        const view = (self.core.findById(self.target, object_id) catch return null) orelse return null;
        return view.object_ref;
    }

    pub fn runtimeHandleAt(self: *const SceneGeneration, object_index: usize) ?RuntimeHandle {
        var views: [runtime_core.max_object_count]runtime_core.ObjectView = undefined;
        const visible = self.core.snapshot(self.target, false, &views) catch return null;
        if (object_index >= visible.len) return null;
        return visible[object_index].object_ref;
    }

    pub fn objectIndexForRef(self: *const SceneGeneration, object_ref: RuntimeHandle) ?usize {
        var views: [runtime_core.max_object_count]runtime_core.ObjectView = undefined;
        const visible = self.core.snapshot(self.target, false, &views) catch return null;
        for (visible, 0..) |view, index| if (runtime_core.sameObjectRef(view.object_ref, object_ref)) return index;
        return null;
    }

    pub fn activeHandles(self: *const SceneGeneration, output: []RuntimeHandle) ![]RuntimeHandle {
        var views: [runtime_core.max_object_count]runtime_core.ObjectView = undefined;
        const active = try self.core.snapshot(self.target, true, &views);
        if (output.len < active.len) return error.RuntimeObjectBufferTooSmall;
        for (active, 0..) |view, index| output[index] = view.object_ref;
        return output[0..active.len];
    }

    pub fn activeViews(self: *const SceneGeneration, output: []runtime_core.ObjectView) ![]runtime_core.ObjectView {
        return self.core.snapshot(self.target, true, output);
    }

    pub fn visibleHandles(self: *const SceneGeneration, output: []RuntimeHandle) ![]RuntimeHandle {
        var views: [runtime_core.max_object_count]runtime_core.ObjectView = undefined;
        const visible = try self.core.snapshot(self.target, false, &views);
        if (output.len < visible.len) return error.RuntimeObjectBufferTooSmall;
        for (visible, 0..) |view, index| output[index] = view.object_ref;
        return output[0..visible.len];
    }

    pub fn visibleViews(self: *const SceneGeneration, output: []runtime_core.ObjectView) ![]runtime_core.ObjectView {
        return self.core.snapshot(self.target, false, output);
    }

    pub fn activeCount(self: *const SceneGeneration) usize {
        var views: [runtime_core.max_object_count]runtime_core.ObjectView = undefined;
        return (self.core.snapshot(self.target, true, &views) catch return 0).len;
    }

    pub fn liveCount(self: *const SceneGeneration) usize {
        var views: [runtime_core.max_object_count]runtime_core.ObjectView = undefined;
        return (self.core.snapshot(self.target, false, &views) catch return 0).len;
    }

    pub fn playerEntity(self: *const SceneGeneration) runtime_core.EntityId {
        return self.entityForObject(self.player_index) orelse runtime_core.invalid_entity;
    }

    pub fn playerObjectIndex(self: *const SceneGeneration) usize {
        return self.player_index;
    }

    pub fn goalEntity(self: *const SceneGeneration) runtime_core.EntityId {
        return self.entityForObject(self.goal_index) orelse runtime_core.invalid_entity;
    }

    pub fn entityForObject(self: *const SceneGeneration, object_index: usize) ?runtime_core.EntityId {
        const handle = self.runtimeHandleAt(object_index) orelse return null;
        const view = (self.core.resolve(self.target, handle) catch return null) orelse return null;
        return if (view.entity_value == runtime_core.invalid_entity) null else view.entity_value;
    }

    pub fn objectIndex(self: *const SceneGeneration, object_id: []const u8) ?usize {
        const handle = self.runtimeHandle(object_id) orelse return null;
        return self.objectIndexForRef(handle);
    }

    pub fn objectKind(self: *const SceneGeneration, object_index: usize) ?scene_api.ObjectKind {
        const handle = self.runtimeHandleAt(object_index) orelse return null;
        const view = (self.core.resolve(self.target, handle) catch return null) orelse return null;
        return kindFromCode(view.object_ref.kind);
    }

    pub fn objectPosition(self: *const SceneGeneration, object_index: usize) ![2]f32 {
        const handle = self.runtimeHandleAt(object_index) orelse return error.UnknownSceneObject;
        const view = try self.core.resolve(self.target, handle) orelse return error.UnknownSceneObject;
        return view.position;
    }

    pub fn setObjectPosition(self: *SceneGeneration, object_index: usize, position: [2]f32) !void {
        const handle = self.runtimeHandleAt(object_index) orelse return error.UnknownSceneObject;
        try self.core.applyPositions(self.target, &.{.{ .object_ref = handle, .position = position }});
    }

    pub fn applyObjectPositionsAtomically(self: *SceneGeneration, updates: []const ObjectPositionUpdate) !void {
        if (updates.len == 0 or updates.len > runtime_core.max_object_count) return error.InvalidBehaviorPositionBatch;
        var patches: [runtime_core.max_object_count]runtime_core.PositionPatch = undefined;
        for (updates, 0..) |update, index| {
            patches[index] = .{
                .object_ref = self.runtimeHandleAt(update.object_index) orelse return error.UnknownSceneObject,
                .position = update.position,
            };
        }
        try self.core.applyPositions(self.target, patches[0..updates.len]);
    }

    pub fn commitActivation(
        self: *SceneGeneration,
        updates: []const ObjectPositionUpdate,
        commands: []const ActivationCommand,
        dispositions: []?runtime_core.DestroyDisposition,
    ) !void {
        if (updates.len > runtime_core.max_object_count) return error.InvalidBehaviorPositionBatch;
        var patches: [runtime_core.max_object_count]runtime_core.PositionPatch = undefined;
        for (updates, 0..) |update, index| {
            patches[index] = .{
                .object_ref = self.runtimeHandleAt(update.object_index) orelse return error.UnknownSceneObject,
                .position = update.position,
            };
        }
        try self.core.commitActivation(patches[0..updates.len], commands, dispositions);
    }

    pub fn refreshPhaseProjection(self: *SceneGeneration) !void {
    }

    pub fn preparePhaseState(self: *SceneGeneration, bindings: []const runtime_core.PhaseBinding) !void {
        _ = try self.core.preparePhaseState(self.target, bindings);
    }

    pub fn commitPhaseState(self: *SceneGeneration) !void {
        try self.core.commitPhaseState();
        if (self.target == .candidate) self.phase_candidate_ready = true;
    }

    pub fn abortPhaseState(self: *SceneGeneration) !void {
        try self.core.abortPhaseState();
        if (self.target == .candidate) self.phase_candidate_ready = false;
    }

    pub fn objectIdForEntity(self: *const SceneGeneration, entity: runtime_core.EntityId) ?scene_api.ObjectId {
        const view = (self.core.findByEntity(self.target, entity) catch return null) orelse return null;
        return objectId(view.object_ref) catch null;
    }

    pub fn goalPosition(self: *const SceneGeneration) [2]f32 {
        return self.objectPosition(self.goal_index) catch self.scene.goal().sprite.position;
    }

    pub fn primaryHazardY(self: *const SceneGeneration) f32 {
        if (self.hazard_count == 0) return 0;
        return (self.objectPosition(self.hazards[0].object_index) catch return 0)[1];
    }

    fn prepareGameplay(self: *SceneGeneration) !void {
        var hazards: [scene_api.max_scene_object_count - 2]runtime_core.HazardDesc = undefined;
        for (self.hazards[0..self.hazard_count], 0..) |hazard, index| {
            const object = &self.scene.objects.entries[hazard.object_index];
            const legacy = self.scene.schemaVersion == scene_api.legacy_object_schema_version;
            hazards[index] = .{
                .object_ref = (try self.core.findById(.candidate, object.objectId.slice()) orelse return error.UnknownSceneObject).object_ref,
                .legacy_patrol = legacy,
                .patrol_min_y = if (legacy) object.patrol.minY else 0,
                .patrol_max_y = if (legacy) object.patrol.maxY else 0,
                .patrol_speed = if (legacy) object.patrol.speed else 0,
            };
        }
        try self.core.prepareGameplay(
            3.0,
            (try self.core.findById(.candidate, self.scene.objects.entries[self.player_index].objectId.slice()) orelse return error.UnknownSceneObject).object_ref,
            (try self.core.findById(.candidate, self.scene.objects.entries[self.goal_index].objectId.slice()) orelse return error.UnknownSceneObject).object_ref,
            hazards[0..self.hazard_count],
        );
    }

    fn ensurePairedPhaseCandidate(self: *SceneGeneration) !void {
        if (self.phase_candidate_ready) return;
        _ = try self.core.preparePhaseState(.candidate, &.{});
        try self.core.commitPhaseState();
        self.phase_candidate_ready = true;
    }
};

fn prepareWithCore(
    value: *const scene_api.Scene,
    extent: PlatformExtent,
    core_value: runtime_core.RuntimeCore,
    mode: runtime_core.PrepareMode,
    target: runtime_core.Target,
) !SceneGeneration {
    try scene_api.validate(value);
    const owned_scene = try std.heap.page_allocator.create(scene_api.Scene);
    errdefer std.heap.page_allocator.destroy(owned_scene);
    owned_scene.* = value.*;
    var core = core_value;
    errdefer if (mode != .initial) core.abortScene() catch {};
    var sources: [scene_api.max_scene_object_count]runtime_core.SourceDesc = undefined;
    _ = try core.prepare(mode, .{ 0, 0 }, boundsMax(extent), sourceDescriptors(value, &sources));
    var player_index: ?u8 = null;
    var goal_index: ?u8 = null;
    var hazards = [_]HazardSource{.{}} ** scene_api.max_scene_object_count;
    var hazard_count: u8 = 0;
    for (value.objects.slice(), 0..) |object, index| switch (object.kind) {
        .sprite => {},
        .player => player_index = @intCast(index),
        .goal => goal_index = @intCast(index),
        .patrol_hazard => {
            hazards[hazard_count] = .{ .object_index = @intCast(index) };
            hazard_count += 1;
        },
    };
    var generation = SceneGeneration{
        .scene = owned_scene,
        .core = core,
        .target = target,
        .extent = extent,
        .player_index = player_index orelse return error.SceneGenerationMissingPlayer,
        .goal_index = goal_index orelse return error.SceneGenerationMissingGoal,
        .hazards = hazards,
        .hazard_count = hazard_count,
        .phase_candidate_ready = false,
    };
    try generation.prepareGameplay();
    return generation;
}

fn sourceDescriptors(scene: *const scene_api.Scene, output: []runtime_core.SourceDesc) []runtime_core.SourceDesc {
    for (scene.objects.slice(), 0..) |*object, index| output[index] = .{
        .object_id = object.objectId.slice(),
        .kind = kindCode(object.kind),
        .sprite = .{
            .position = object.sprite.position,
            .size = object.sprite.size,
            .color = object.sprite.color,
            .texture_id = object.sprite.textureId,
            .move_speed = if (object.kind == .player) object.player.moveSpeed else 0,
        },
    };
    return output[0..scene.objects.count];
}

fn boundsMax(extent: PlatformExtent) [2]f32 {
    return .{ @floatFromInt(extent.width), @floatFromInt(extent.height) };
}

fn kindCode(kind: scene_api.ObjectKind) u32 {
    return switch (kind) {
        .sprite => 1,
        .player => 2,
        .goal => 3,
        .patrol_hazard => 4,
    };
}

fn kindFromCode(kind: u32) ?scene_api.ObjectKind {
    return switch (kind) {
        1 => .sprite,
        2 => .player,
        3 => .goal,
        4 => .patrol_hazard,
        else => null,
    };
}

fn objectId(value: runtime_core.ObjectRef) !scene_api.ObjectId {
    return scene_api.ObjectId.init(runtime_core.objectIdSlice(&value));
}

fn record(view: runtime_core.ObjectView) !RuntimeRecord {
    return .{
        .state = switch (view.lifecycle) {
            1 => .pending_spawn,
            2 => .active,
            else => .pending_destroy,
        },
        .object_id = try objectId(view.object_ref),
        .logical_generation = view.object_ref.logical_generation,
        .source_index = if (view.origin == 1) @intCast(view.origin_key) else null,
        .prototype_index = if (view.origin == 2) @intCast(view.origin_key) else null,
        .kind = kindFromCode(view.object_ref.kind) orelse return error.InvalidRuntimeObjectKind,
        .sprite = .{ .position = view.position, .size = view.size, .color = view.color, .textureId = view.texture_id },
        .entity = view.entity_value,
        .behavior_count = 0,
    };
}

fn clampPosition(position: [2]f32, size: [2]f32, extent: PlatformExtent) [2]f32 {
    const max_x = @max(0.0, @as(f32, @floatFromInt(extent.width)) - size[0]);
    const max_y = @max(0.0, @as(f32, @floatFromInt(extent.height)) - size[1]);
    return .{ @min(@max(position[0], 0.0), max_x), @min(@max(position[1], 0.0), max_y) };
}

fn testGameplayStep(generation: *SceneGeneration, dt_seconds: f32, input: runtime_core.InputSnapshot) !struct { result: runtime_core.GameplayStepResult, outcome: runtime_core.GameplayOutcome } {
    var outcome: runtime_core.GameplayOutcome = undefined;
    const begin = try generation.beginGameplayFixed(dt_seconds, &outcome);
    try generation.core.beginPhase(.fixed, begin.step_token);
    const result = try generation.commitGameplayFixed(begin.step_token, input, &outcome);
    var events: [runtime_core.max_phase_events]runtime_core.PhaseEvent = undefined;
    for (&events) |*event| {
        event.* = std.mem.zeroes(runtime_core.PhaseEvent);
        event.struct_size = @sizeOf(runtime_core.PhaseEvent);
    }
    _ = try generation.core.drainPhaseEvents(.fixed, begin.step_token, &events);
    try generation.core.endPhase(.fixed, begin.step_token);
    return .{ .result = result, .outcome = outcome };
}

test "SceneGeneration keeps fixed-capacity Scene storage out of line" {
    try std.testing.expect(@sizeOf(scene_api.Scene) > 400 * 1024);
    try std.testing.expect(@sizeOf(SceneGeneration) < 64 * 1024);
}

test "SceneGeneration preserves source order and updates independent hazards" {
    var generation = try SceneGeneration.prepare(&scene_api.default_scene, .{ .width = 1024, .height = 720 });
    defer generation.deinit();
    var before: [scene_api.max_scene_object_count]runtime_core.RenderSprite = undefined;
    const initial = (try generation.extractSprites(&before)).sprites;
    try std.testing.expectEqual(@as(usize, 5), initial.len);
    try std.testing.expectEqual(generation.entityForObject(0).?, initial[0].entity_value);
    const first_y = initial[2].position[1];
    const second_y = initial[3].position[1];
    _ = try testGameplayStep(&generation, 1.0 / 60.0, .{});
    var after: [scene_api.max_scene_object_count]runtime_core.RenderSprite = undefined;
    const stepped = (try generation.extractSprites(&after)).sprites;
    try std.testing.expect(stepped[2].position[1] != first_y);
    try std.testing.expect(stepped[3].position[1] != second_y);
    try std.testing.expect(stepped[2].position[1] - first_y != stepped[3].position[1] - second_y);
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
    var generation = try SceneGeneration.prepare(&scene, .{ .width = 1024, .height = 720 });
    defer generation.deinit();
    const pending = try generation.reserveTransient("runtime-orb", .{ 20, 30 });
    var sprites: [runtime_core.max_object_count]runtime_core.RenderSprite = undefined;
    try std.testing.expectEqual(scene.objects.count, (try generation.extractSprites(&sprites)).sprites.len);
    try generation.activateTransient(pending.handle);
    try std.testing.expectEqual(scene.objects.count + 1, (try generation.extractSprites(&sprites)).sprites.len);
    try generation.requestTransientDestroy(pending.handle);
    try generation.commitTransientDestroy(pending.handle);
    try std.testing.expect(generation.runtimeObject(pending.handle) == null);
    const restart_transient = try generation.reserveTransient("runtime-orb", .{ 40, 50 });
    try generation.activateTransient(restart_transient.handle);
    _ = try testGameplayStep(&generation, 3.0, .{});
    try generation.reset();
    try std.testing.expect(generation.runtimeObject(restart_transient.handle) == null);
    const after_restart = try generation.reserveTransient("runtime-orb", .{ 60, 70 });
    try std.testing.expectEqualStrings("runtime-0000000000000003", after_restart.object_id.slice());
}

test "SceneGeneration reports contact with any patrol hazard through Gameplay outcome" {
    var value = scene_api.default_scene;
    const player_index = value.objects.indexOfKind(.player).?;
    value.objects.entries[player_index].sprite.position = value.objects.entries[3].sprite.position;
    value.objects.entries[player_index].sprite.size = .{ 1.0, 1.0 };
    var generation = try SceneGeneration.prepare(&value, .{ .width = 1024, .height = 720 });
    defer generation.deinit();
    const step = try testGameplayStep(&generation, 0.0, .{});
    try std.testing.expectEqual(@intFromEnum(runtime_core.GameplayCause.hazard), step.result.cause);
    try std.testing.expectEqualStrings("hazard-2", runtime_core.objectIdSlice(&step.outcome.other));
}

test "SceneGeneration patrol reflection remains bounded after large travel" {
    var generation = try SceneGeneration.prepare(&scene_api.default_scene, .{ .width = 1024, .height = 720 });
    defer generation.deinit();
    _ = try testGameplayStep(&generation, 1000.0, .{});
    for (generation.hazards[0..generation.hazard_count]) |hazard| {
        const patrol = generation.scene.objects.entries[hazard.object_index].patrol;
        const y = (try generation.objectPosition(hazard.object_index))[1];
        try std.testing.expect(y >= patrol.minY and y <= patrol.maxY);
    }
    var outcome: runtime_core.GameplayOutcome = undefined;
    try std.testing.expectError(error.InvalidRuntimeCoreArgument, generation.beginGameplayFixed(-1.0, &outcome));
}

test "SceneGeneration behavior schema stops native patrol and applies one atomic translation batch" {
    var value = scene_api.default_scene;
    value.schemaVersion = scene_api.behavior_schema_version;
    for (value.objects.mutableSlice()) |*object| {
        if (object.kind != .patrol_hazard) continue;
        object.behaviors.count = 1;
        object.behaviors.entries[0].scriptId = 1;
    }
    var generation = try SceneGeneration.prepare(&value, .{ .width = 1024, .height = 720 });
    defer generation.deinit();
    var before_storage: [scene_api.max_scene_object_count]runtime_core.RenderSprite = undefined;
    const before = (try generation.extractSprites(&before_storage)).sprites;
    _ = try testGameplayStep(&generation, 1.0, .{});
    var native_step_storage: [scene_api.max_scene_object_count]runtime_core.RenderSprite = undefined;
    const native_step = (try generation.extractSprites(&native_step_storage)).sprites;
    try std.testing.expectEqual(before[2].position, native_step[2].position);
    try std.testing.expectEqual(before[3].position, native_step[3].position);

    var deltas = [_][2]f64{.{ 0, 0 }} ** scene_api.max_scene_object_count;
    deltas[2] = .{ 0, 5 };
    deltas[3] = .{ -2, -7 };
    try generation.applyTranslationDeltas(deltas[0..value.objects.count]);
    var after_storage: [scene_api.max_scene_object_count]runtime_core.RenderSprite = undefined;
    const after = (try generation.extractSprites(&after_storage)).sprites;
    try std.testing.expectApproxEqAbs(before[2].position[1] + 5, after[2].position[1], 0.0001);
    try std.testing.expectApproxEqAbs(before[3].position[0] - 2, after[3].position[0], 0.0001);
    try std.testing.expectApproxEqAbs(before[3].position[1] - 7, after[3].position[1], 0.0001);
}

test "SceneGeneration restart and reload keep live isolated until candidate commit" {
    var scene = scene_api.default_scene;
    scene.schemaVersion = scene_api.current_schema_version;
    for (scene.objects.mutableSlice()) |*object| {
        if (object.kind == .patrol_hazard) {
            object.behaviors.count = 1;
            object.behaviors.entries[0].scriptId = 1;
        }
    }
    scene.prototypes.count = 1;
    scene.prototypes.entries[0] = .{
        .prototypeId = try scene_api.PrototypeId.init("runtime-orb"),
        .sprite = .{ .size = .{ 2, 2 }, .color = .{ 1, 1, 1, 1 }, .textureId = 1 },
    };
    var generation = try SceneGeneration.prepare(&scene, .{ .width = 1024, .height = 720 });
    defer generation.deinit();
    const original_player = generation.runtimeHandle("player") orelse return error.MissingPlayer;
    const original_entity = generation.playerEntity();
    const transient = try generation.reserveTransient("runtime-orb", .{ 10, 20 });
    try generation.activateTransient(transient.handle);
    _ = try testGameplayStep(&generation, 3.0, .{});

    var restart = try SceneGeneration.prepareRestart(&scene, generation.extent, &generation);
    var restart_needs_cleanup = true;
    defer if (restart_needs_cleanup) restart.deinit();
    const restart_player = restart.runtimeHandle("player") orelse return error.MissingPlayer;
    try std.testing.expect(runtime_core.sameObjectRef(original_player, restart_player));
    try std.testing.expect(restart.playerEntity() != original_entity);
    try std.testing.expect(generation.runtimeObject(transient.handle) != null);
    try std.testing.expect(restart.runtimeObject(transient.handle) == null);
    try restart.commitPrepared(&generation);
    var previous = generation;
    generation = restart;
    restart_needs_cleanup = false;
    previous.deinit();
    const after_restart = try generation.reserveTransient("runtime-orb", .{ 30, 40 });
    try std.testing.expectEqualStrings("runtime-0000000000000002", after_restart.object_id.slice());

    var reload = try SceneGeneration.prepareSceneReload(&scene, generation.extent, &generation);
    var reload_needs_cleanup = true;
    defer if (reload_needs_cleanup) reload.deinit();
    try std.testing.expect(reload.runtimeObject(original_player) == null);
    try std.testing.expect(generation.runtimeObject(original_player) != null);
    try reload.commitPrepared(&generation);
    previous = generation;
    generation = reload;
    reload_needs_cleanup = false;
    previous.deinit();
    try std.testing.expect(generation.runtimeObject(original_player) == null);
    const reload_player = generation.runtimeHandle("player") orelse return error.MissingPlayer;
    try std.testing.expect(reload_player.world_epoch == original_player.world_epoch + 1);
}
