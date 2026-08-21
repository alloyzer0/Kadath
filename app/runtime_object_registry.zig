const std = @import("std");
const scene_api = @import("scene.zig");

pub const max_runtime_object_count: usize = 128;
pub const max_behavior_instance_count: usize = 256;
pub const max_logical_generation: u64 = 9_007_199_254_740_991;

pub const LifecycleState = enum {
    stale,
    pending_spawn,
    active,
    pending_destroy,
};

pub const Handle = struct {
    slot: u8,
    logical_generation: u64,
};

pub const Record = struct {
    state: LifecycleState = .stale,
    object_id: scene_api.ObjectId = .{},
    logical_generation: u64 = 1,
    source_index: ?u8 = null,
    prototype_index: ?u8 = null,
    kind: scene_api.ObjectKind = .sprite,
    sprite: scene_api.Sprite = .{},
    entity: u64 = 0,
    spawn_serial: u64 = 0,
    behavior_count: u8 = 0,

    pub fn handle(self: *const Record, slot: usize) Handle {
        return .{ .slot = @intCast(slot), .logical_generation = self.logical_generation };
    }
};

pub const ReservedSpawn = struct {
    handle: Handle,
    object_id: scene_api.ObjectId,
};

pub const Registry = struct {
    records: [max_runtime_object_count]Record = [_]Record{.{}} ** max_runtime_object_count,
    live_count: usize = 0,
    behavior_instance_count: usize = 0,
    next_spawn_serial: u64 = 1,

    pub fn init(scene: *const scene_api.Scene) !Registry {
        if (scene.objects.count > max_runtime_object_count) return error.RuntimeObjectCapacityExceeded;
        var registry = Registry{};
        for (scene.objects.slice(), 0..) |object, index| {
            registry.records[index] = .{
                .state = .active,
                .object_id = object.objectId,
                .source_index = @intCast(index),
                .kind = object.kind,
                .sprite = object.sprite,
                .behavior_count = object.behaviors.count,
            };
            registry.live_count += 1;
            registry.behavior_instance_count += object.behaviors.count;
        }
        if (registry.behavior_instance_count > max_behavior_instance_count) return error.BehaviorInstanceCapacityExceeded;
        return registry;
    }

    pub fn liveCount(self: *const Registry) usize {
        return self.live_count;
    }

    pub fn behaviorInstanceCount(self: *const Registry) usize {
        return self.behavior_instance_count;
    }

    pub fn find(self: *Registry, object_id: []const u8) ?*Record {
        for (&self.records) |*record| {
            if (record.state == .stale or record.state == .pending_destroy) continue;
            if (std.mem.eql(u8, record.object_id.slice(), object_id)) return record;
        }
        return null;
    }

    pub fn findHandle(self: *Registry, object_id: []const u8) ?Handle {
        for (&self.records, 0..) |*record, index| {
            if (record.state == .stale or record.state == .pending_destroy) continue;
            if (std.mem.eql(u8, record.object_id.slice(), object_id)) return record.handle(index);
        }
        return null;
    }

    pub fn bindSourceEntity(self: *Registry, source_index: usize, entity: u64) !void {
        if (source_index >= self.records.len or entity == 0) return error.InvalidRuntimeObjectActivation;
        const record = &self.records[source_index];
        if (record.source_index != @as(?u8, @intCast(source_index)) or record.state != .active) return error.InvalidRuntimeObjectActivation;
        record.entity = entity;
    }

    pub fn reserveSpawn(
        self: *Registry,
        prototype_index: u8,
        position: [2]f32,
        behavior_count: u8,
    ) !ReservedSpawn {
        if (!std.math.isFinite(position[0]) or !std.math.isFinite(position[1])) return error.InvalidSpawnPosition;
        if (self.live_count >= max_runtime_object_count) return error.RuntimeObjectCapacityExceeded;
        if (self.behavior_instance_count + behavior_count > max_behavior_instance_count) {
            return error.BehaviorInstanceCapacityExceeded;
        }
        const slot = for (&self.records, 0..) |*record, index| {
            if (record.state == .stale and record.logical_generation < max_logical_generation) break index;
        } else return error.RuntimeObjectCapacityExceeded;
        var serial = self.next_spawn_serial;
        var object_id: scene_api.ObjectId = undefined;
        while (true) {
            if (serial == std.math.maxInt(u64)) return error.TransientObjectIdExhausted;
            var id_storage: [scene_api.max_object_id_bytes]u8 = undefined;
            const id = try std.fmt.bufPrint(&id_storage, "runtime-{x:0>16}", .{serial});
            if (self.find(id) == null) {
                object_id = try scene_api.ObjectId.init(id);
                break;
            }
            serial += 1;
        }
        self.next_spawn_serial = serial + 1;
        const logical_generation = self.records[slot].logical_generation;
        self.records[slot] = .{
            .state = .pending_spawn,
            .object_id = object_id,
            .logical_generation = logical_generation,
            .prototype_index = prototype_index,
            .sprite = .{ .position = position },
            .spawn_serial = serial,
            .behavior_count = behavior_count,
        };
        self.live_count += 1;
        self.behavior_instance_count += behavior_count;
        return .{ .handle = self.records[slot].handle(slot), .object_id = object_id };
    }

    pub fn configurePending(self: *Registry, handle: Handle, prototype: *const scene_api.SpawnPrototype) !void {
        const record = self.resolveMutable(handle, true) orelse return error.StaleRuntimeObject;
        if (record.state != .pending_spawn) return error.InvalidRuntimeObjectActivation;
        const position = record.sprite.position;
        record.kind = prototype.kind;
        record.sprite = prototype.sprite;
        record.sprite.position = position;
    }

    pub fn activate(self: *Registry, handle: Handle, entity: u64) !void {
        const record = self.resolveMutable(handle, true) orelse return error.StaleRuntimeObject;
        if (record.state != .pending_spawn or entity == 0) return error.InvalidRuntimeObjectActivation;
        record.entity = entity;
        record.state = .active;
    }

    pub fn requestDestroy(self: *Registry, handle: Handle) !void {
        const record = self.resolveMutable(handle, true) orelse return error.StaleRuntimeObject;
        if (record.source_index != null) return error.SourceRuntimeObjectDestroyRejected;
        switch (record.state) {
            .pending_spawn => {
                self.releaseRecord(record);
            },
            .active => record.state = .pending_destroy,
            .pending_destroy, .stale => return error.StaleRuntimeObject,
        }
    }

    pub fn completeDestroy(self: *Registry, handle: Handle) !void {
        const record = self.resolveMutable(handle, true) orelse return error.StaleRuntimeObject;
        if (record.state != .pending_destroy) return error.InvalidRuntimeObjectDestroy;
        self.releaseRecord(record);
    }

    pub fn discardTransient(self: *Registry, handle: Handle) !void {
        const record = self.resolveMutable(handle, true) orelse return error.StaleRuntimeObject;
        if (record.source_index != null) return error.SourceRuntimeObjectDestroyRejected;
        self.releaseRecord(record);
    }

    pub fn resolve(self: *Registry, handle: Handle) ?*Record {
        return self.resolveMutable(handle, false);
    }

    pub fn resolveForCommit(self: *Registry, handle: Handle) ?*Record {
        return self.resolveMutable(handle, true);
    }

    pub fn activeCount(self: *const Registry) usize {
        var count: usize = 0;
        for (self.records) |record| {
            if (record.state == .active) count += 1;
        }
        return count;
    }

    pub fn orderedHandles(self: *Registry, output: []Handle) []Handle {
        var count: usize = 0;
        for (&self.records, 0..) |*record, index| {
            if (record.state == .stale or record.state == .pending_destroy) continue;
            if (record.source_index == null) continue;
            if (count == output.len) break;
            output[count] = record.handle(index);
            count += 1;
        }
        for (&self.records, 0..) |*record, index| {
            if (record.state == .stale or record.state == .pending_destroy or record.source_index != null) continue;
            if (count == output.len) break;
            var insert_at = count;
            while (insert_at > 0) {
                const previous = self.resolveMutable(output[insert_at - 1], true) orelse break;
                if (previous.source_index != null or previous.spawn_serial <= record.spawn_serial) break;
                output[insert_at] = output[insert_at - 1];
                insert_at -= 1;
            }
            output[insert_at] = record.handle(index);
            count += 1;
        }
        return output[0..count];
    }

    pub fn activeHandles(self: *Registry, output: []Handle) []Handle {
        const ordered = self.orderedHandles(output);
        var count: usize = 0;
        for (ordered) |handle| {
            const record = self.resolveMutable(handle, true) orelse continue;
            if (record.state != .active) continue;
            output[count] = handle;
            count += 1;
        }
        return output[0..count];
    }

    fn resolveMutable(self: *Registry, handle: Handle, include_pending_destroy: bool) ?*Record {
        if (handle.slot >= self.records.len or handle.logical_generation == 0) return null;
        const record = &self.records[handle.slot];
        if (record.logical_generation != handle.logical_generation or record.state == .stale) return null;
        if (!include_pending_destroy and record.state == .pending_destroy) return null;
        return record;
    }

    fn releaseRecord(self: *Registry, record: *Record) void {
        self.live_count -= 1;
        self.behavior_instance_count -= record.behavior_count;
        record.* = .{ .logical_generation = @min(record.logical_generation + 1, max_logical_generation) };
    }
};

test "Runtime Object Registry keeps source identity and never revives stale transient refs" {
    var registry = try Registry.init(&scene_api.default_scene);
    try std.testing.expectEqual(scene_api.default_scene.objects.count, registry.liveCount());

    const player = registry.find("player") orelse return error.MissingPlayer;
    try std.testing.expectEqual(.active, player.state);
    try std.testing.expect(player.source_index != null);

    const pending = try registry.reserveSpawn(0, .{ 10, 20 }, 1);
    try std.testing.expectEqualStrings("runtime-0000000000000001", pending.object_id.slice());
    try std.testing.expect(registry.resolve(pending.handle) != null);
    try registry.activate(pending.handle, 77);
    try registry.requestDestroy(pending.handle);
    try std.testing.expect(registry.resolve(pending.handle) == null);
    try registry.completeDestroy(pending.handle);

    const replacement = try registry.reserveSpawn(0, .{ 30, 40 }, 1);
    try std.testing.expectEqualStrings("runtime-0000000000000002", replacement.object_id.slice());
    try std.testing.expect(registry.resolve(pending.handle) == null);
    try std.testing.expect(registry.resolve(replacement.handle) != null);
}

test "Runtime Object Registry exposes pending state and stable source then spawn order" {
    var registry = try Registry.init(&scene_api.default_scene);
    const second = try registry.reserveSpawn(0, .{ 2, 2 }, 0);
    const first = try registry.reserveSpawn(0, .{ 1, 1 }, 0);
    try std.testing.expectEqual(.pending_spawn, registry.resolve(first.handle).?.state);
    try std.testing.expectEqual(.pending_spawn, registry.resolve(second.handle).?.state);

    var handles: [max_runtime_object_count]Handle = undefined;
    const ordered = registry.orderedHandles(&handles);
    try std.testing.expectEqual(scene_api.default_scene.objects.count + 2, ordered.len);
    try std.testing.expectEqualStrings("decoration-1", registry.resolve(ordered[0]).?.object_id.slice());
    try std.testing.expectEqualStrings("runtime-0000000000000001", registry.resolve(ordered[scene_api.default_scene.objects.count]).?.object_id.slice());
    try std.testing.expectEqualStrings("runtime-0000000000000002", registry.resolve(ordered[scene_api.default_scene.objects.count + 1]).?.object_id.slice());

    try registry.activate(second.handle, 10);
    try registry.requestDestroy(second.handle);
    try registry.completeDestroy(second.handle);
    const third = try registry.reserveSpawn(0, .{ 3, 3 }, 0);
    const reordered = registry.orderedHandles(&handles);
    try std.testing.expectEqualStrings("runtime-0000000000000002", registry.resolve(reordered[scene_api.default_scene.objects.count]).?.object_id.slice());
    try std.testing.expectEqualStrings("runtime-0000000000000003", registry.resolve(reordered[scene_api.default_scene.objects.count + 1]).?.object_id.slice());
    try std.testing.expect(registry.resolve(third.handle) != null);
}

test "Runtime Object Registry accepts exact object capacity and rejects one over" {
    var registry = try Registry.init(&scene_api.default_scene);
    var reservations: [max_runtime_object_count]ReservedSpawn = undefined;
    const remaining = max_runtime_object_count - scene_api.default_scene.objects.count;
    for (reservations[0..remaining], 0..) |*reservation, index| {
        reservation.* = try registry.reserveSpawn(0, .{ @floatFromInt(index), 0 }, 0);
    }
    try std.testing.expectEqual(max_runtime_object_count, registry.liveCount());
    try std.testing.expectError(error.RuntimeObjectCapacityExceeded, registry.reserveSpawn(0, .{ 0, 0 }, 0));
}

test "Runtime Object Registry reserves behavior capacity independently" {
    var scene = scene_api.default_scene;
    for (scene.objects.mutableSlice()) |*object| object.behaviors.count = 4;
    var registry = try Registry.init(&scene);
    const remaining_instances = max_behavior_instance_count - registry.behaviorInstanceCount();
    for (0..remaining_instances / 4) |index| {
        _ = try registry.reserveSpawn(0, .{ @floatFromInt(index), 0 }, 4);
    }
    try std.testing.expectEqual(max_behavior_instance_count, registry.behaviorInstanceCount());
    try std.testing.expectError(error.BehaviorInstanceCapacityExceeded, registry.reserveSpawn(0, .{ 0, 0 }, 1));
}

test "Runtime Object Registry retires exhausted generations instead of reviving stale refs" {
    var registry = try Registry.init(&scene_api.default_scene);
    const retired_slot = scene_api.default_scene.objects.count;
    registry.records[retired_slot].logical_generation = max_logical_generation - 1;
    const final = try registry.reserveSpawn(0, .{ 1, 2 }, 0);
    try std.testing.expectEqual(@as(u64, max_logical_generation - 1), final.handle.logical_generation);
    try registry.requestDestroy(final.handle);
    try std.testing.expectEqual(max_logical_generation, registry.records[retired_slot].logical_generation);

    const replacement = try registry.reserveSpawn(0, .{ 3, 4 }, 0);
    try std.testing.expect(replacement.handle.slot != final.handle.slot);
    try std.testing.expect(registry.resolve(final.handle) == null);
}
