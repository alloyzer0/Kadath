const std = @import("std");
const artifact = @import("behavior_artifact");
const behavior_runtime = @import("behavior_runtime");
const content_identity = @import("content_identity.zig");
const scene_adapter = @import("behavior_scene_adapter.zig");
const scene_api = @import("scene.zig");
const scene_generation_api = @import("scene_generation.zig");

pub const InputSnapshot = behavior_runtime.InputSnapshot;

const max_events_per_domain: usize = 64;
const max_event_drain_generation: u8 = 8;
const max_exact_luau_world_epoch: u64 = 9_007_199_254_740_991;

const StoredEventValue = struct {
    kind: u32 = 0,
    boolean_value: i32 = 0,
    number_value: f64 = 0,
    string_storage: [128]u8 = [_]u8{0} ** 128,
    string_bytes: u8 = 0,
    object_value: behavior_runtime.NativeObjectHandle = std.mem.zeroes(behavior_runtime.NativeObjectHandle),
};

const StoredEventField = struct {
    key_storage: [32]u8 = [_]u8{0} ** 32,
    key_bytes: u8 = 0,
    value: StoredEventValue = .{},
};

const QueuedEvent = struct {
    target: behavior_runtime.NativeObjectHandle = std.mem.zeroes(behavior_runtime.NativeObjectHandle),
    has_sender: bool = false,
    sender: behavior_runtime.NativeObjectHandle = std.mem.zeroes(behavior_runtime.NativeObjectHandle),
    has_other: bool = false,
    other: behavior_runtime.NativeObjectHandle = std.mem.zeroes(behavior_runtime.NativeObjectHandle),
    name_storage: [64]u8 = [_]u8{0} ** 64,
    name_bytes: u8 = 0,
    fields: [8]StoredEventField = [_]StoredEventField{.{}} ** 8,
    field_count: u8 = 0,
    generation: u8 = 0,
};

const EventQueue = struct {
    events: [max_events_per_domain]QueuedEvent = [_]QueuedEvent{.{}} ** max_events_per_domain,
    count: usize = 0,

    fn clear(self: *EventQueue) void {
        self.count = 0;
    }

    fn appendPosted(self: *EventQueue, source: *const behavior_runtime.NativePostedEvent, generation: u8) bool {
        if (self.count >= self.events.len or source.name == null or source.name_length == 0 or source.name_length > 63 or
            source.field_count > 8 or (source.field_count > 0 and source.fields == null)) return false;
        var event = QueuedEvent{
            .target = source.target,
            .has_sender = true,
            .sender = source.sender,
            .name_bytes = @intCast(source.name_length),
            .field_count = @intCast(source.field_count),
            .generation = generation,
        };
        @memcpy(event.name_storage[0..source.name_length], source.name[0..source.name_length]);
        if (source.field_count > 0) {
            const source_fields = source.fields orelse return false;
            for (source_fields[0..source.field_count], 0..) |field, index| {
                if (field.key == null or field.key_length == 0 or field.key_length > 31) return false;
                if (!validEventValue(&field.value)) return false;
                event.fields[index].key_bytes = @intCast(field.key_length);
                @memcpy(event.fields[index].key_storage[0..field.key_length], field.key[0..field.key_length]);
                event.fields[index].value.kind = field.value.kind;
                event.fields[index].value.boolean_value = field.value.boolean_value;
                event.fields[index].value.number_value = field.value.number_value;
                event.fields[index].value.object_value = field.value.object_value;
                if (field.value.kind == 3) {
                    event.fields[index].value.string_bytes = @intCast(field.value.string_value_length);
                    @memcpy(
                        event.fields[index].value.string_storage[0..field.value.string_value_length],
                        field.value.string_value[0..field.value.string_value_length],
                    );
                }
            }
        }
        self.events[self.count] = event;
        self.count += 1;
        return true;
    }
};

pub const TranslationBatch = struct {
    deltas: [scene_api.max_scene_object_count][2]f64 = [_][2]f64{.{ 0, 0 }} ** scene_api.max_scene_object_count,
    object_count: usize = 0,

    pub fn slice(self: *const TranslationBatch) []const [2]f64 {
        return self.deltas[0..self.object_count];
    }
};

pub const LoadedRuntime = struct {
    value: Runtime,
    identity: content_identity.ContentIdentity,
    artifact_version: u32,
};

pub const Runtime = struct {
    allocator: std.mem.Allocator = std.heap.page_allocator,
    package: ?*behavior_runtime.Package = null,
    active: ?*behavior_runtime.ActiveSet = null,
    world_epoch: u64 = 1,
    fixed_events: ?*EventQueue = null,
    frame_events: ?*EventQueue = null,
    contact_active: [scene_api.max_scene_object_count]bool = [_]bool{false} ** scene_api.max_scene_object_count,

    pub fn deinit(self: *Runtime) void {
        if (self.active) |active| {
            active.deinit();
            self.allocator.destroy(active);
        }
        if (self.package) |package| {
            package.deinit();
            self.allocator.destroy(package);
        }
        if (self.fixed_events) |events| self.allocator.destroy(events);
        if (self.frame_events) |events| self.allocator.destroy(events);
        self.* = .{};
    }

    pub fn isLoaded(self: *const Runtime) bool {
        return self.package != null and self.active != null;
    }

    pub fn cloneForRestart(self: *const Runtime, allocator: std.mem.Allocator, scene: *const scene_api.Scene) !Runtime {
        const package = self.package orelse return error.BehaviorRuntimeNotLoaded;
        return initArtifactAtEpoch(allocator, package.bytes, scene, self.world_epoch);
    }

    pub fn cloneForSceneReload(self: *const Runtime, allocator: std.mem.Allocator, scene: *const scene_api.Scene) !Runtime {
        const package = self.package orelse return error.BehaviorRuntimeNotLoaded;
        const next_world_epoch = std.math.add(u64, self.world_epoch, 1) catch return error.BehaviorWorldEpochExhausted;
        return initArtifactAtEpoch(allocator, package.bytes, scene, next_world_epoch);
    }

    pub fn worldEpoch(self: *const Runtime) u64 {
        return self.world_epoch;
    }

    pub fn onStart(self: *Runtime, generation: *const scene_generation_api.SceneGeneration) !TranslationBatch {
        const active = self.active orelse return error.BehaviorRuntimeNotLoaded;
        const frame_events = self.frame_events orelse return error.BehaviorRuntimeNotLoaded;
        var initial_positions: [scene_api.max_scene_object_count][2]f32 = undefined;
        var context = OverlayHostContext{
            .scene = &generation.scene,
            .world_epoch = self.world_epoch,
        };
        for (generation.scene.objects.slice(), 0..) |_, index| {
            const position = try generation.objectPosition(index);
            initial_positions[index] = position;
            context.positions[index] = .{ position[0], position[1] };
        }
        var host = overlayNativeHost(&context);
        try active.runStartV3(&host);
        for (context.events.events[0..context.events.count]) |event| {
            if (frame_events.count >= frame_events.events.len) return error.BehaviorEventQueueOverflow;
            frame_events.events[frame_events.count] = event;
            frame_events.count += 1;
        }
        var batch = TranslationBatch{ .object_count = generation.scene.objects.count };
        for (initial_positions[0..generation.scene.objects.count], 0..) |position, index| {
            batch.deltas[index] = .{
                context.positions[index][0] - position[0],
                context.positions[index][1] - position[1],
            };
        }
        return batch;
    }

    pub fn runFixed(
        self: *Runtime,
        generation: *scene_generation_api.SceneGeneration,
        dt_seconds: f32,
        input: InputSnapshot,
    ) !void {
        const active = self.active orelse return error.BehaviorRuntimeNotLoaded;
        const fixed_events = self.fixed_events orelse return error.BehaviorRuntimeNotLoaded;
        var context = DirectHostContext{
            .generation = generation,
            .world_epoch = self.world_epoch,
            .events = fixed_events,
        };
        var host = directNativeHost(&context);
        try active.runFixedV3(dt_seconds, input, &host);
        logFailures(active);
    }

    pub fn runUpdate(
        self: *Runtime,
        generation: *scene_generation_api.SceneGeneration,
        dt_seconds: f32,
        input: InputSnapshot,
    ) !void {
        const active = self.active orelse return error.BehaviorRuntimeNotLoaded;
        const frame_events = self.frame_events orelse return error.BehaviorRuntimeNotLoaded;
        var context = DirectHostContext{
            .generation = generation,
            .world_epoch = self.world_epoch,
            .events = frame_events,
        };
        var host = directNativeHost(&context);
        try active.runUpdateV3(dt_seconds, input, &host);
        logFailures(active);
    }

    pub fn finishFixedStep(
        self: *Runtime,
        generation: *scene_generation_api.SceneGeneration,
        touching: []const bool,
        input: InputSnapshot,
    ) !void {
        if (touching.len != generation.scene.objects.count) return error.InvalidBehaviorContactSnapshot;
        const player_index = generation.playerObjectIndex();
        for (touching, 0..) |is_touching, index| {
            if (index == player_index or is_touching or !self.contact_active[index]) continue;
            try self.appendContactEvent(generation, player_index, index, "contact_end");
        }
        for (touching, 0..) |is_touching, index| {
            if (index == player_index or !is_touching or self.contact_active[index]) continue;
            try self.appendContactEvent(generation, player_index, index, "contact_begin");
        }
        @memcpy(self.contact_active[0..touching.len], touching);
        try self.drainEvents(generation, self.fixed_events orelse return error.BehaviorRuntimeNotLoaded, 1, input);
    }

    pub fn finishFrame(
        self: *Runtime,
        generation: *scene_generation_api.SceneGeneration,
        input: InputSnapshot,
    ) !void {
        try self.drainEvents(generation, self.frame_events orelse return error.BehaviorRuntimeNotLoaded, 2, input);
    }

    fn appendContactEvent(
        self: *Runtime,
        generation: *const scene_generation_api.SceneGeneration,
        player_index: usize,
        other_index: usize,
        name: []const u8,
    ) !void {
        try self.appendDirectedContact(generation, player_index, other_index, name);
        try self.appendDirectedContact(generation, other_index, player_index, name);
    }

    fn appendDirectedContact(
        self: *Runtime,
        generation: *const scene_generation_api.SceneGeneration,
        target_index: usize,
        other_index: usize,
        name: []const u8,
    ) !void {
        const fixed_events = self.fixed_events orelse return error.BehaviorRuntimeNotLoaded;
        if (fixed_events.count >= fixed_events.events.len) return error.BehaviorEventQueueOverflow;
        var event = QueuedEvent{ .has_other = true, .name_bytes = @intCast(name.len) };
        _ = fillObjectHandle(&generation.scene, target_index, self.world_epoch, &event.target);
        _ = fillObjectHandle(&generation.scene, other_index, self.world_epoch, &event.other);
        @memcpy(event.name_storage[0..name.len], name);
        fixed_events.events[fixed_events.count] = event;
        fixed_events.count += 1;
    }

    fn drainEvents(
        self: *Runtime,
        generation: *scene_generation_api.SceneGeneration,
        queue: *EventQueue,
        domain: u32,
        input: InputSnapshot,
    ) !void {
        const active = self.active orelse return error.BehaviorRuntimeNotLoaded;
        active.beginEventDrain();
        var index: usize = 0;
        while (index < queue.count) : (index += 1) {
            const event = &queue.events[index];
            if (event.generation > max_event_drain_generation) continue;
            const target_id = event.target.object_id[0..event.target.object_id_length];
            if (validateObjectHandle(&generation.scene, self.world_epoch, &event.target) == null) {
                std.log.warn("Behavior event target became stale before delivery: name={s}, target={s}", .{
                    event.name_storage[0..event.name_bytes],
                    target_id,
                });
                continue;
            }
            var context = DirectHostContext{
                .generation = generation,
                .world_epoch = self.world_epoch,
                .events = queue,
                .post_generation = event.generation +| 1,
            };
            var host = directNativeHost(&context);
            var native_fields: [8]behavior_runtime.NativeEventField = undefined;
            for (event.fields[0..event.field_count], 0..) |*field, field_index| {
                native_fields[field_index] = std.mem.zeroes(behavior_runtime.NativeEventField);
                native_fields[field_index].key = &field.key_storage;
                native_fields[field_index].key_length = field.key_bytes;
                native_fields[field_index].value.kind = field.value.kind;
                native_fields[field_index].value.boolean_value = field.value.boolean_value;
                native_fields[field_index].value.number_value = field.value.number_value;
                native_fields[field_index].value.object_value = field.value.object_value;
                if (field.value.kind == 3) {
                    native_fields[field_index].value.string_value = &field.value.string_storage;
                    native_fields[field_index].value.string_value_length = field.value.string_bytes;
                }
            }
            var native_event = behavior_runtime.NativeEvent{
                .name = &event.name_storage,
                .name_length = event.name_bytes,
                .domain = domain,
                .has_sender = @intFromBool(event.has_sender),
                .sender = event.sender,
                .has_other = @intFromBool(event.has_other),
                .other = event.other,
                .fields = if (event.field_count == 0) null else &native_fields,
                .field_count = event.field_count,
            };
            try active.dispatchEventV3(target_id, &native_event, input, &host);
        }
        queue.clear();
        logFailures(active);
    }
};

const OverlayHostContext = struct {
    scene: *const scene_api.Scene,
    world_epoch: u64,
    positions: [scene_api.max_scene_object_count][2]f64 = [_][2]f64{.{ 0, 0 }} ** scene_api.max_scene_object_count,
    events: EventQueue = .{},
};

const DirectHostContext = struct {
    generation: *scene_generation_api.SceneGeneration,
    world_epoch: u64,
    events: *EventQueue,
    post_generation: u8 = 0,
};

fn overlayNativeHost(context: *OverlayHostContext) behavior_runtime.NativeHostV3 {
    return .{
        .version = 3,
        .struct_size = @sizeOf(behavior_runtime.NativeHostV3),
        .userdata = context,
        .world_epoch = context.world_epoch,
        .resolve_object = overlayResolveObject,
        .get_object_position = overlayGetObjectPosition,
        .set_object_position = overlaySetObjectPosition,
        .post_event = overlayPostEvent,
    };
}

fn directNativeHost(context: *DirectHostContext) behavior_runtime.NativeHostV3 {
    return .{
        .version = 3,
        .struct_size = @sizeOf(behavior_runtime.NativeHostV3),
        .userdata = context,
        .world_epoch = context.world_epoch,
        .resolve_object = directResolveObject,
        .get_object_position = directGetObjectPosition,
        .set_object_position = directSetObjectPosition,
        .post_event = directPostEvent,
    };
}

fn overlayResolveObject(
    userdata: ?*anyopaque,
    object_id: [*c]const u8,
    object_id_length: usize,
    out_object: ?*behavior_runtime.NativeObjectHandle,
) callconv(.c) c_int {
    const context: *OverlayHostContext = @ptrCast(@alignCast(userdata orelse return 0));
    const index = findObjectIndex(context.scene, object_id[0..object_id_length]) orelse return 0;
    return fillObjectHandle(context.scene, index, context.world_epoch, out_object);
}

fn overlayGetObjectPosition(
    userdata: ?*anyopaque,
    object: ?*const behavior_runtime.NativeObjectHandle,
    out_x: ?*f64,
    out_y: ?*f64,
) callconv(.c) c_int {
    const context: *OverlayHostContext = @ptrCast(@alignCast(userdata orelse return 0));
    const index = validateObjectHandle(context.scene, context.world_epoch, object) orelse return 0;
    if (out_x == null or out_y == null) return 0;
    out_x.?.* = context.positions[index][0];
    out_y.?.* = context.positions[index][1];
    return 1;
}

fn overlaySetObjectPosition(
    userdata: ?*anyopaque,
    object: ?*const behavior_runtime.NativeObjectHandle,
    x: f64,
    y: f64,
) callconv(.c) c_int {
    const context: *OverlayHostContext = @ptrCast(@alignCast(userdata orelse return 0));
    const index = validateObjectHandle(context.scene, context.world_epoch, object) orelse return 0;
    if (!validPosition(x, y)) return 0;
    context.positions[index] = .{ x, y };
    return 1;
}

fn directResolveObject(
    userdata: ?*anyopaque,
    object_id: [*c]const u8,
    object_id_length: usize,
    out_object: ?*behavior_runtime.NativeObjectHandle,
) callconv(.c) c_int {
    const context: *DirectHostContext = @ptrCast(@alignCast(userdata orelse return 0));
    const index = context.generation.objectIndex(object_id[0..object_id_length]) orelse return 0;
    return fillObjectHandle(&context.generation.scene, index, context.world_epoch, out_object);
}

fn directGetObjectPosition(
    userdata: ?*anyopaque,
    object: ?*const behavior_runtime.NativeObjectHandle,
    out_x: ?*f64,
    out_y: ?*f64,
) callconv(.c) c_int {
    const context: *DirectHostContext = @ptrCast(@alignCast(userdata orelse return 0));
    const index = validateObjectHandle(&context.generation.scene, context.world_epoch, object) orelse return 0;
    if (out_x == null or out_y == null) return 0;
    const position = context.generation.objectPosition(index) catch return 0;
    out_x.?.* = position[0];
    out_y.?.* = position[1];
    return 1;
}

fn directSetObjectPosition(
    userdata: ?*anyopaque,
    object: ?*const behavior_runtime.NativeObjectHandle,
    x: f64,
    y: f64,
) callconv(.c) c_int {
    const context: *DirectHostContext = @ptrCast(@alignCast(userdata orelse return 0));
    const index = validateObjectHandle(&context.generation.scene, context.world_epoch, object) orelse return 0;
    if (!validPosition(x, y)) return 0;
    context.generation.setObjectPosition(index, .{ @floatCast(x), @floatCast(y) }) catch return 0;
    return 1;
}

fn overlayPostEvent(userdata: ?*anyopaque, event: ?*const behavior_runtime.NativePostedEvent) callconv(.c) c_int {
    const context: *OverlayHostContext = @ptrCast(@alignCast(userdata orelse return 0));
    const posted = event orelse return 0;
    if (!validPostedEventObjects(context.scene, context.world_epoch, posted)) return 0;
    return @intFromBool(context.events.appendPosted(posted, 0));
}

fn directPostEvent(userdata: ?*anyopaque, event: ?*const behavior_runtime.NativePostedEvent) callconv(.c) c_int {
    const context: *DirectHostContext = @ptrCast(@alignCast(userdata orelse return 0));
    if (context.post_generation > max_event_drain_generation) return 0;
    const posted = event orelse return 0;
    if (!validPostedEventObjects(&context.generation.scene, context.world_epoch, posted)) return 0;
    return @intFromBool(context.events.appendPosted(posted, context.post_generation));
}

fn fillObjectHandle(
    scene: *const scene_api.Scene,
    object_index: usize,
    world_epoch: u64,
    out_object: ?*behavior_runtime.NativeObjectHandle,
) c_int {
    const output = out_object orelse return 0;
    const object = &scene.objects.entries[object_index];
    output.* = std.mem.zeroes(behavior_runtime.NativeObjectHandle);
    output.world_epoch = world_epoch;
    output.logical_generation = 1;
    output.kind = switch (object.kind) {
        .sprite => 1,
        .player => 2,
        .goal => 3,
        .patrol_hazard => 4,
    };
    const object_id = object.objectId.slice();
    output.object_id_length = object_id.len;
    @memcpy(output.object_id[0..object_id.len], object_id);
    return 1;
}

fn validateObjectHandle(
    scene: *const scene_api.Scene,
    world_epoch: u64,
    object: ?*const behavior_runtime.NativeObjectHandle,
) ?usize {
    const value = object orelse return null;
    if (value.world_epoch != world_epoch or value.logical_generation != 1 or value.object_id_length > behavior_runtime.max_object_id_bytes) return null;
    return findObjectIndex(scene, value.object_id[0..value.object_id_length]);
}

fn validPosition(x: f64, y: f64) bool {
    return std.math.isFinite(x) and std.math.isFinite(y) and
        @abs(x) <= std.math.floatMax(f32) and @abs(y) <= std.math.floatMax(f32);
}

fn validEventValue(value: *const behavior_runtime.NativeEventValue) bool {
    return switch (value.kind) {
        1 => value.boolean_value == 0 or value.boolean_value == 1,
        2 => std.math.isFinite(value.number_value),
        3 => value.string_value != null and value.string_value_length <= 127,
        4 => validObjectHandleShape(&value.object_value),
        else => false,
    };
}

fn validObjectHandleShape(value: *const behavior_runtime.NativeObjectHandle) bool {
    return value.world_epoch != 0 and value.logical_generation != 0 and
        value.kind >= 1 and value.kind <= 4 and
        value.object_id_length > 0 and value.object_id_length <= behavior_runtime.max_object_id_bytes;
}

fn validPostedEventObjects(
    scene: *const scene_api.Scene,
    world_epoch: u64,
    event: *const behavior_runtime.NativePostedEvent,
) bool {
    if (validateObjectHandle(scene, world_epoch, &event.target) == null or
        validateObjectHandle(scene, world_epoch, &event.sender) == null or
        event.field_count > 8 or (event.field_count > 0 and event.fields == null)) return false;
    if (event.field_count > 0) {
        const fields = event.fields orelse return false;
        for (fields[0..event.field_count]) |field| {
            if (field.value.kind == 4 and validateObjectHandle(scene, world_epoch, &field.value.object_value) == null) return false;
        }
    }
    return true;
}

test "Behavior event drain rejects a ninth-generation successor before enqueue" {
    var queue = EventQueue{};
    var unused_generation: scene_generation_api.SceneGeneration = undefined;
    const unused_event = std.mem.zeroes(behavior_runtime.NativePostedEvent);
    var context = DirectHostContext{
        .generation = &unused_generation,
        .world_epoch = 1,
        .events = &queue,
        .post_generation = max_event_drain_generation + 1,
    };
    try std.testing.expectEqual(@as(c_int, 0), directPostEvent(&context, &unused_event));
    try std.testing.expectEqual(@as(usize, 0), queue.count);
}

test "Direct Host resolves replacement entities and rejects stale object handles" {
    var generation = try scene_generation_api.SceneGeneration.prepare(scene_api.default_scene, .{ .width = 1024, .height = 720 });
    defer generation.deinit();
    var queue = EventQueue{};
    var context = DirectHostContext{
        .generation = &generation,
        .world_epoch = 7,
        .events = &queue,
    };
    const host = directNativeHost(&context);
    const player_id = "player";
    var object = std.mem.zeroes(behavior_runtime.NativeObjectHandle);

    try std.testing.expectEqual(@as(c_int, 1), host.resolve_object.?(&context, player_id.ptr, player_id.len, &object));
    const previous_entity = generation.playerEntity();
    try generation.reset();
    try std.testing.expect(previous_entity != generation.playerEntity());

    var x: f64 = 0;
    var y: f64 = 0;
    try std.testing.expectEqual(@as(c_int, 1), host.get_object_position.?(&context, &object, &x, &y));
    try std.testing.expectEqual(@as(c_int, 1), host.set_object_position.?(&context, &object, x + 3, y));
    try std.testing.expectApproxEqAbs(@as(f32, @floatCast(x + 3)), (try generation.objectPosition(generation.playerObjectIndex()))[0], 0.0001);

    context.world_epoch += 1;
    try std.testing.expectEqual(@as(c_int, 0), host.get_object_position.?(&context, &object, &x, &y));
    try std.testing.expectEqual(@as(c_int, 0), host.set_object_position.?(&context, &object, x, y));
    const unknown_id = "unknown";
    try std.testing.expectEqual(@as(c_int, 0), host.resolve_object.?(&context, unknown_id.ptr, unknown_id.len, &object));
    try std.testing.expectEqual(@as(c_int, 0), host.set_object_position.?(&context, &object, std.math.nan(f64), y));
    try std.testing.expectEqual(@as(c_int, 0), host.resolve_object.?(null, player_id.ptr, player_id.len, &object));
}

pub fn loadWithIdentity(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    scene: *const scene_api.Scene,
) !LoadedRuntime {
    return loadWithIdentityAtEpoch(io, allocator, path, scene, 1);
}

pub fn loadWithIdentityAtEpoch(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    scene: *const scene_api.Scene,
    world_epoch: u64,
) !LoadedRuntime {
    const contents = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(artifact.max_artifact_bytes));
    defer allocator.free(contents);
    return .{
        .value = try initArtifactAtEpoch(allocator, contents, scene, world_epoch),
        .identity = try content_identity.ContentIdentity.fromBytes(.artifact, contents),
        .artifact_version = artifact.artifact_version,
    };
}

pub fn initArtifact(allocator: std.mem.Allocator, bytes: []const u8, scene: *const scene_api.Scene) !Runtime {
    return initArtifactAtEpoch(allocator, bytes, scene, 1);
}

pub fn initArtifactAtEpoch(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    scene: *const scene_api.Scene,
    world_epoch: u64,
) !Runtime {
    if (scene.schemaVersion != scene_api.current_schema_version) return error.UnsupportedBehaviorSceneSchema;
    if (world_epoch == 0 or world_epoch > max_exact_luau_world_epoch) return error.InvalidBehaviorWorldEpoch;
    var diagnostic = behavior_runtime.Diagnostic{};
    const package = try allocator.create(behavior_runtime.Package);
    errdefer allocator.destroy(package);
    package.* = behavior_runtime.Package.init(
        allocator,
        bytes,
        behavior_runtime.default_asset_memory_limit,
        behavior_runtime.default_interrupt_limit,
        &diagnostic,
    ) catch |err| {
        logDiagnostic("Behavior package activation failed", err, diagnostic.slice());
        return err;
    };
    errdefer package.deinit();
    const normalized = try scene_adapter.normalize(&package.parsed, scene);
    var prepared = normalized.prepare(package, &diagnostic) catch |err| {
        logDiagnostic("Behavior binding preparation failed", err, diagnostic.slice());
        return err;
    };
    errdefer prepared.deinit();
    const active = try allocator.create(behavior_runtime.ActiveSet);
    errdefer allocator.destroy(active);
    const fixed_events = try allocator.create(EventQueue);
    errdefer allocator.destroy(fixed_events);
    fixed_events.* = .{};
    const frame_events = try allocator.create(EventQueue);
    errdefer allocator.destroy(frame_events);
    frame_events.* = .{};
    prepared.activateInto(active);
    return .{
        .allocator = allocator,
        .package = package,
        .active = active,
        .world_epoch = world_epoch,
        .fixed_events = fixed_events,
        .frame_events = frame_events,
    };
}

fn findObjectIndex(scene: *const scene_api.Scene, object_id: []const u8) ?usize {
    for (scene.objects.slice(), 0..) |object, index| {
        if (std.mem.eql(u8, object.objectId.slice(), object_id)) return index;
    }
    return null;
}

fn logFailures(active: *const behavior_runtime.ActiveSet) void {
    for (active.failureSlice()) |failure| {
        const binding_index: usize = failure.binding_index;
        std.log.warn("Behavior binding disabled: binding={d}, object={s}, script_id={d}, error={s}, diagnostic={s}", .{
            binding_index,
            active.bindingObjectId(binding_index),
            active.bindingScriptId(binding_index),
            failure.errorName(),
            failure.diagnostic(),
        });
    }
}

fn logDiagnostic(prefix: []const u8, err: anyerror, diagnostic: []const u8) void {
    std.log.err("{s}: error={s}, diagnostic={s}", .{ prefix, @errorName(err), diagnostic });
}
