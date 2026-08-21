const std = @import("std");
const artifact = @import("behavior_artifact");
const behavior_runtime = @import("behavior_runtime");
const content_identity = @import("content_identity.zig");
const scene_adapter = @import("behavior_scene_adapter.zig");
const scene_api = @import("scene.zig");
const scene_generation_api = @import("scene_generation.zig");
const runtime_object_registry = @import("runtime_object_registry.zig");

pub const InputSnapshot = behavior_runtime.InputSnapshot;

const max_events_per_domain: usize = 64;
const max_event_drain_generation: u8 = 8;
const max_structural_requests_per_domain: usize = 64;
const max_structural_generation: u8 = 8;
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

const StructuralOperation = enum { spawn, destroy };

const StructuralOrigin = struct {
    object_id: scene_api.ObjectId = .{},
    script_id: u32 = 0,

    fn isValid(self: StructuralOrigin) bool {
        return self.object_id.byte_count != 0 and self.script_id != 0;
    }
};

const StructuralRequest = struct {
    operation: StructuralOperation = .spawn,
    handle: runtime_object_registry.Handle = .{ .slot = 0, .logical_generation = 0 },
    generation: u8 = 0,
    sequence: u64 = 0,
    origin: StructuralOrigin = .{},
};

const StructuralQueue = struct {
    requests: [max_structural_requests_per_domain]StructuralRequest = [_]StructuralRequest{.{}} ** max_structural_requests_per_domain,
    count: usize = 0,
    next_sequence: u64 = 1,
    current_origin: StructuralOrigin = .{},

    fn canAppend(self: *const StructuralQueue, generation: u8) bool {
        return self.canAppendCount(1) and
            generation <= max_structural_generation and
            self.next_sequence != std.math.maxInt(u64);
    }

    fn canAppendCount(self: *const StructuralQueue, additional_count: usize) bool {
        return additional_count <= self.requests.len - self.count and
            additional_count <= std.math.maxInt(u64) - self.next_sequence;
    }

    fn append(self: *StructuralQueue, operation: StructuralOperation, handle: runtime_object_registry.Handle, generation: u8) bool {
        if (!self.canAppend(generation)) return false;
        self.requests[self.count] = .{
            .operation = operation,
            .handle = handle,
            .generation = generation,
            .sequence = self.next_sequence,
            .origin = self.current_origin,
        };
        self.count += 1;
        self.next_sequence += 1;
        return true;
    }

    fn clear(self: *StructuralQueue) void {
        self.count = 0;
        self.current_origin = .{};
    }

    fn appendRequest(self: *StructuralQueue, request: StructuralRequest) bool {
        const previous_origin = self.current_origin;
        defer self.current_origin = previous_origin;
        self.current_origin = request.origin;
        return self.append(request.operation, request.handle, request.generation);
    }
};

fn beginStructuralOrigin(userdata: ?*anyopaque, binding_index: usize, object_id: []const u8, script_id: u32) void {
    _ = binding_index;
    const queue: *StructuralQueue = @ptrCast(@alignCast(userdata orelse return));
    queue.current_origin = .{
        .object_id = scene_api.ObjectId.init(object_id) catch return,
        .script_id = script_id,
    };
}

fn endStructuralOrigin(userdata: ?*anyopaque) void {
    const queue: *StructuralQueue = @ptrCast(@alignCast(userdata orelse return));
    queue.current_origin = .{};
}

fn structuralObserver(queue: *StructuralQueue) behavior_runtime.ActiveSet.BindingObserver {
    return .{ .userdata = queue, .begin = beginStructuralOrigin, .end = endStructuralOrigin };
}

pub const TranslationBatch = struct {
    deltas: [runtime_object_registry.max_runtime_object_count][2]f64 = [_][2]f64{.{ 0, 0 }} ** runtime_object_registry.max_runtime_object_count,
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
    fixed_structural: ?*StructuralQueue = null,
    frame_structural: ?*StructuralQueue = null,
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
        if (self.fixed_structural) |queue| self.allocator.destroy(queue);
        if (self.frame_structural) |queue| self.allocator.destroy(queue);
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
        const mutable_generation: *scene_generation_api.SceneGeneration = @constCast(generation);
        try self.prepareTransientBindings(mutable_generation);
        var handles: [runtime_object_registry.max_runtime_object_count]runtime_object_registry.Handle = undefined;
        const ordered = mutable_generation.runtime_objects.activeHandles(&handles);
        var initial_positions: [runtime_object_registry.max_runtime_object_count][2]f32 = undefined;
        var context = try OverlayHostContext.init(mutable_generation, self.world_epoch);
        for (ordered, 0..) |handle, index| initial_positions[index] = context.positions[handle.slot];
        var host = overlayNativeHost(&context);
        try active.runStartV4(&host);
        for (context.events.events[0..context.events.count]) |event| {
            if (frame_events.count >= frame_events.events.len) return error.BehaviorEventQueueOverflow;
            frame_events.events[frame_events.count] = event;
            frame_events.count += 1;
        }
        var batch = TranslationBatch{ .object_count = ordered.len };
        for (ordered, 0..) |handle, index| {
            const position = initial_positions[index];
            batch.deltas[index] = .{
                context.positions[handle.slot][0] - position[0],
                context.positions[handle.slot][1] - position[1],
            };
        }
        return batch;
    }

    fn prepareTransientBindings(self: *Runtime, generation: *scene_generation_api.SceneGeneration) !void {
        const package = self.package orelse return error.BehaviorRuntimeNotLoaded;
        const active = self.active orelse return error.BehaviorRuntimeNotLoaded;
        var diagnostic = behavior_runtime.Diagnostic{};
        var handles: [runtime_object_registry.max_runtime_object_count]runtime_object_registry.Handle = undefined;
        for (generation.runtime_objects.activeHandles(&handles)) |handle| {
            const record = generation.runtimeObject(handle) orelse continue;
            if (record.source_index != null or record.behavior_count == 0 or active.containsObject(record.object_id.slice())) continue;
            const prototype_index = record.prototype_index orelse return error.InvalidRuntimeObjectActivation;
            const prototype = &generation.scene.prototypes.entries[prototype_index];
            const normalized = try scene_adapter.normalizePrototype(&package.parsed, prototype, record.object_id.slice(), try generation.objectPosition(handle.slot));
            var prepared = try normalized.prepare(package, &diagnostic);
            errdefer prepared.deinit();
            try active.appendPrepared(&prepared);
        }
    }

    pub fn runFixed(
        self: *Runtime,
        generation: *scene_generation_api.SceneGeneration,
        dt_seconds: f32,
        input: InputSnapshot,
    ) !void {
        const active = self.active orelse return error.BehaviorRuntimeNotLoaded;
        const fixed_events = self.fixed_events orelse return error.BehaviorRuntimeNotLoaded;
        const fixed_structural = self.fixed_structural orelse return error.BehaviorRuntimeNotLoaded;
        var context = DirectHostContext{
            .generation = generation,
            .world_epoch = self.world_epoch,
            .events = fixed_events,
            .structural = fixed_structural,
        };
        var host = directNativeHost(&context);
        try active.runFixedV4Observed(dt_seconds, input, &host, structuralObserver(fixed_structural));
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
        const frame_structural = self.frame_structural orelse return error.BehaviorRuntimeNotLoaded;
        var context = DirectHostContext{
            .generation = generation,
            .world_epoch = self.world_epoch,
            .events = frame_events,
            .structural = frame_structural,
        };
        var host = directNativeHost(&context);
        try active.runUpdateV4Observed(dt_seconds, input, &host, structuralObserver(frame_structural));
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
        const structural = self.fixed_structural orelse return error.BehaviorRuntimeNotLoaded;
        try self.drainEvents(generation, self.fixed_events orelse return error.BehaviorRuntimeNotLoaded, structural, 1, input);
        try self.flushStructural(generation, self.fixed_events orelse return error.BehaviorRuntimeNotLoaded, structural);
    }

    pub fn finishFrame(
        self: *Runtime,
        generation: *scene_generation_api.SceneGeneration,
        input: InputSnapshot,
    ) !void {
        const structural = self.frame_structural orelse return error.BehaviorRuntimeNotLoaded;
        try self.drainEvents(generation, self.frame_events orelse return error.BehaviorRuntimeNotLoaded, structural, 2, input);
        try self.flushStructural(generation, self.frame_events orelse return error.BehaviorRuntimeNotLoaded, structural);
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
        structural: *StructuralQueue,
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
            if (validateRuntimeObjectHandle(generation, self.world_epoch, &event.target) == null) {
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
                .structural = structural,
                .post_generation = event.generation +| 1,
                .structural_generation = 1,
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
            try active.dispatchEventV4Observed(target_id, &native_event, input, &host, structuralObserver(structural));
        }
        queue.clear();
        logFailures(active);
    }

    fn flushStructural(
        self: *Runtime,
        generation: *scene_generation_api.SceneGeneration,
        events: *EventQueue,
        queue: *StructuralQueue,
    ) !void {
        const active = self.active orelse return error.BehaviorRuntimeNotLoaded;
        var index: usize = 0;
        while (index < queue.count) : (index += 1) {
            const request = queue.requests[index];
            switch (request.operation) {
                .spawn => {
                    const record = generation.runtimeObject(request.handle) orelse continue;
                    if (record.state != .pending_spawn) continue;
                    const package = self.package orelse return error.BehaviorRuntimeNotLoaded;
                    const prototype_index = record.prototype_index orelse {
                        generation.runtime_objects.discardTransient(request.handle) catch {};
                        reportStructuralFailure(active, request, error.InvalidRuntimeObjectActivation, null);
                        continue;
                    };
                    const prototype = &generation.scene.prototypes.entries[prototype_index];
                    const object_id = record.object_id;
                    const position = record.sprite.position;
                    const normalized = scene_adapter.normalizePrototype(&package.parsed, prototype, object_id.slice(), position) catch |err| {
                        generation.runtime_objects.discardTransient(request.handle) catch {};
                        reportStructuralFailure(active, request, err, prototype.prototypeId.slice());
                        continue;
                    };
                    var diagnostic = behavior_runtime.Diagnostic{};
                    var prepared = normalized.prepare(package, &diagnostic) catch |err| {
                        generation.runtime_objects.discardTransient(request.handle) catch {};
                        logDiagnostic("Dynamic Behavior binding preparation failed", err, diagnostic.slice());
                        reportStructuralFailure(active, request, err, prototype.prototypeId.slice());
                        continue;
                    };
                    var candidate = prepared.activate();
                    const activation_context = self.allocator.create(ActivationHostContext) catch |err| {
                        candidate.deinit();
                        generation.runtime_objects.discardTransient(request.handle) catch {};
                        reportStructuralFailure(active, request, err, prototype.prototypeId.slice());
                        continue;
                    };
                    defer self.allocator.destroy(activation_context);
                    activation_context.* = ActivationHostContext.init(
                        generation,
                        self.world_epoch,
                        events,
                        queue,
                        request.generation +| 1,
                    ) catch |err| {
                        candidate.deinit();
                        generation.runtime_objects.discardTransient(request.handle) catch {};
                        reportStructuralFailure(active, request, err, prototype.prototypeId.slice());
                        continue;
                    };
                    var activation_host = activationNativeHost(activation_context);
                    candidate.runStartV4Observed(&activation_host, structuralObserver(&activation_context.candidate_structural)) catch |err| {
                        candidate.deinit();
                        activation_context.rollback();
                        generation.runtime_objects.discardTransient(request.handle) catch {};
                        std.log.warn("Dynamic Behavior on_start failed: sequence={d}, error={s}", .{ request.sequence, @errorName(err) });
                        continue;
                    };
                    active.appendActive(&candidate) catch |err| {
                        candidate.deinit();
                        activation_context.rollback();
                        generation.runtime_objects.discardTransient(request.handle) catch {};
                        reportStructuralFailure(active, request, err, prototype.prototypeId.slice());
                        continue;
                    };
                    generation.activateTransient(request.handle) catch |err| {
                        active.removeObject(object_id.slice());
                        activation_context.rollback();
                        generation.runtime_objects.discardTransient(request.handle) catch {};
                        reportStructuralFailure(active, request, err, prototype.prototypeId.slice());
                        continue;
                    };
                    activation_context.commit() catch |err| {
                        active.removeObject(object_id.slice());
                        generation.requestTransientDestroy(request.handle) catch {};
                        generation.commitTransientDestroy(request.handle) catch {};
                        activation_context.rollback();
                        reportStructuralFailure(active, request, err, prototype.prototypeId.slice());
                        continue;
                    };
                },
                .destroy => {
                    var record = generation.runtime_objects.resolveForCommit(request.handle) orelse continue;
                    if (record.state == .active) {
                        generation.requestTransientDestroy(request.handle) catch continue;
                        record = generation.runtime_objects.resolveForCommit(request.handle) orelse continue;
                    }
                    if (record.state != .pending_destroy) continue;
                    var object_id: [scene_api.max_object_id_bytes]u8 = undefined;
                    const object_id_bytes = record.object_id.slice().len;
                    @memcpy(object_id[0..object_id_bytes], record.object_id.slice());
                    generation.commitTransientDestroy(request.handle) catch |err| {
                        reportStructuralFailure(active, request, err, object_id[0..object_id_bytes]);
                        return err;
                    };
                    active.removeObject(object_id[0..object_id_bytes]);
                },
            }
        }
        queue.clear();
    }
};

fn reportStructuralFailure(
    active: *behavior_runtime.ActiveSet,
    request: StructuralRequest,
    err: anyerror,
    target_id: ?[]const u8,
) void {
    const origin_id = if (request.origin.isValid()) request.origin.object_id.slice() else "<unknown>";
    const target = target_id orelse "<unknown>";
    if (request.origin.isValid()) {
        active.disableBindingByIdentity(origin_id, request.origin.script_id, err, "structural commit failed");
    }
    std.log.warn(
        "Behavior structural commit failed: sequence={d}, operation={s}, origin_object={s}, origin_script={d}, target={s}, error={s}",
        .{ request.sequence, @tagName(request.operation), origin_id, request.origin.script_id, target, @errorName(err) },
    );
}

const OverlayHostContext = struct {
    generation: *scene_generation_api.SceneGeneration,
    world_epoch: u64,
    positions: [runtime_object_registry.max_runtime_object_count][2]f32 = [_][2]f32{.{ 0, 0 }} ** runtime_object_registry.max_runtime_object_count,
    present: [runtime_object_registry.max_runtime_object_count]bool = [_]bool{false} ** runtime_object_registry.max_runtime_object_count,
    events: EventQueue = .{},

    fn init(generation: *scene_generation_api.SceneGeneration, world_epoch: u64) !OverlayHostContext {
        var context = OverlayHostContext{ .generation = generation, .world_epoch = world_epoch };
        for (generation.runtime_objects.records, 0..) |record, index| {
            if (record.state != .active) continue;
            context.present[index] = true;
            context.positions[index] = try generation.objectPosition(index);
        }
        return context;
    }
};

const DirectHostContext = struct {
    generation: *scene_generation_api.SceneGeneration,
    world_epoch: u64,
    events: *EventQueue,
    structural: *StructuralQueue,
    post_generation: u8 = 0,
    structural_generation: u8 = 0,
};

const ActivationHostContext = struct {
    generation: *scene_generation_api.SceneGeneration,
    world_epoch: u64,
    target_events: *EventQueue,
    target_structural: *StructuralQueue,
    positions: [runtime_object_registry.max_runtime_object_count][2]f32 = [_][2]f32{.{ 0, 0 }} ** runtime_object_registry.max_runtime_object_count,
    present: [runtime_object_registry.max_runtime_object_count]bool = [_]bool{false} ** runtime_object_registry.max_runtime_object_count,
    destroyed: [runtime_object_registry.max_runtime_object_count]bool = [_]bool{false} ** runtime_object_registry.max_runtime_object_count,
    candidate_events: EventQueue = .{},
    candidate_structural: StructuralQueue = .{},
    structural_generation: u8,

    fn init(
        generation: *scene_generation_api.SceneGeneration,
        world_epoch: u64,
        target_events: *EventQueue,
        target_structural: *StructuralQueue,
        structural_generation: u8,
    ) !ActivationHostContext {
        var context = ActivationHostContext{
            .generation = generation,
            .world_epoch = world_epoch,
            .target_events = target_events,
            .target_structural = target_structural,
            .structural_generation = structural_generation,
        };
        for (generation.runtime_objects.records, 0..) |record, index| {
            if (record.state == .stale or record.state == .pending_destroy) continue;
            context.present[index] = true;
            context.positions[index] = try generation.objectPosition(index);
        }
        return context;
    }

    fn rollback(self: *ActivationHostContext) void {
        for (self.candidate_structural.requests[0..self.candidate_structural.count]) |request| {
            if (request.operation != .spawn) continue;
            self.generation.runtime_objects.discardTransient(request.handle) catch {};
        }
    }

    fn commit(self: *ActivationHostContext) !void {
        if (self.target_events.count + self.candidate_events.count > self.target_events.events.len) return error.BehaviorEventQueueOverflow;
        var canceled = [_]bool{false} ** max_structural_requests_per_domain;
        for (self.candidate_structural.requests[0..self.candidate_structural.count], 0..) |request, destroy_index| {
            if (request.operation != .destroy) continue;
            for (self.candidate_structural.requests[0..destroy_index], 0..) |candidate, spawn_index| {
                if (candidate.operation != .spawn or
                    candidate.handle.slot != request.handle.slot or
                    candidate.handle.logical_generation != request.handle.logical_generation) continue;
                canceled[spawn_index] = true;
                canceled[destroy_index] = true;
                break;
            }
        }
        if (!self.target_structural.canAppendCount(self.candidate_structural.count)) return error.BehaviorStructuralQueueOverflow;
        for (self.candidate_structural.requests[0..self.candidate_structural.count], 0..) |request, request_index| {
            if (!canceled[request_index] and request.generation > max_structural_generation) {
                return error.BehaviorStructuralQueueOverflow;
            }
            if (!canceled[request_index] and request.operation == .destroy) {
                const record = self.generation.runtime_objects.resolveForCommit(request.handle) orelse return error.InvalidRuntimeObjectDestroy;
                if (record.source_index != null or (record.state != .pending_spawn and record.state != .active)) {
                    return error.InvalidRuntimeObjectDestroy;
                }
            }
        }
        for (self.candidate_structural.requests[0..self.candidate_structural.count], 0..) |request, request_index| {
            if (!canceled[request_index] or request.operation != .spawn) continue;
            self.generation.runtime_objects.discardTransient(request.handle) catch return error.InvalidRuntimeObjectDestroy;
        }
        var position_updates: [runtime_object_registry.max_runtime_object_count]scene_generation_api.ObjectPositionUpdate = undefined;
        var position_update_count: usize = 0;
        for (self.present, 0..) |is_present, index| {
            if (!is_present or self.destroyed[index]) continue;
            position_updates[position_update_count] = .{
                .object_index = @intCast(index),
                .position = self.positions[index],
            };
            position_update_count += 1;
        }
        try self.generation.applyObjectPositionsAtomically(position_updates[0..position_update_count]);
        for (self.candidate_events.events[0..self.candidate_events.count]) |event| {
            self.target_events.events[self.target_events.count] = event;
            self.target_events.count += 1;
        }
        for (self.candidate_structural.requests[0..self.candidate_structural.count]) |request| {
            if (!self.target_structural.appendRequest(request)) {
                return error.BehaviorStructuralQueueOverflow;
            }
        }
        for (self.candidate_structural.requests[0..self.candidate_structural.count], 0..) |request, request_index| {
            if (canceled[request_index] or request.operation != .destroy) continue;
            self.generation.requestTransientDestroy(request.handle) catch unreachable;
        }
        self.candidate_structural.count = 0;
    }
};

fn overlayNativeHost(context: *OverlayHostContext) behavior_runtime.NativeHostV4 {
    return .{
        .version = 4,
        .struct_size = @sizeOf(behavior_runtime.NativeHostV4),
        .userdata = context,
        .world_epoch = context.world_epoch,
        .resolve_object = overlayResolveObject,
        .get_object_position = overlayGetObjectPosition,
        .set_object_position = overlaySetObjectPosition,
        .post_event = overlayPostEvent,
        .spawn_object = rejectSpawnObject,
        .destroy_object = rejectDestroyObject,
    };
}

fn directNativeHost(context: *DirectHostContext) behavior_runtime.NativeHostV4 {
    return .{
        .version = 4,
        .struct_size = @sizeOf(behavior_runtime.NativeHostV4),
        .userdata = context,
        .world_epoch = context.world_epoch,
        .resolve_object = directResolveObject,
        .get_object_position = directGetObjectPosition,
        .set_object_position = directSetObjectPosition,
        .post_event = directPostEvent,
        .spawn_object = directSpawnObject,
        .destroy_object = directDestroyObject,
    };
}

fn activationNativeHost(context: *ActivationHostContext) behavior_runtime.NativeHostV4 {
    return .{
        .version = 4,
        .struct_size = @sizeOf(behavior_runtime.NativeHostV4),
        .userdata = context,
        .world_epoch = context.world_epoch,
        .resolve_object = activationResolveObject,
        .get_object_position = activationGetObjectPosition,
        .set_object_position = activationSetObjectPosition,
        .post_event = activationPostEvent,
        .spawn_object = activationSpawnObject,
        .destroy_object = activationDestroyObject,
    };
}

fn rejectSpawnObject(
    userdata: ?*anyopaque,
    prototype_id: [*c]const u8,
    prototype_id_length: usize,
    x: f64,
    y: f64,
    out_object: ?*behavior_runtime.NativeObjectHandle,
) callconv(.c) c_int {
    _ = userdata;
    _ = prototype_id;
    _ = prototype_id_length;
    _ = x;
    _ = y;
    _ = out_object;
    return 0;
}

fn rejectDestroyObject(
    userdata: ?*anyopaque,
    object: ?*const behavior_runtime.NativeObjectHandle,
) callconv(.c) c_int {
    _ = userdata;
    _ = object;
    return 0;
}

fn directSpawnObject(
    userdata: ?*anyopaque,
    prototype_id: [*c]const u8,
    prototype_id_length: usize,
    x: f64,
    y: f64,
    out_object: ?*behavior_runtime.NativeObjectHandle,
) callconv(.c) c_int {
    const context: *DirectHostContext = @ptrCast(@alignCast(userdata orelse return 0));
    const output = out_object orelse return 0;
    output.* = std.mem.zeroes(behavior_runtime.NativeObjectHandle);
    if (prototype_id == null or prototype_id_length == 0 or prototype_id_length > scene_api.max_object_id_bytes or
        !validPosition(x, y) or !context.structural.canAppend(context.structural_generation)) return 0;
    const reserved = context.generation.reserveTransient(
        prototype_id[0..prototype_id_length],
        .{ @floatCast(x), @floatCast(y) },
    ) catch return 0;
    if (!context.structural.append(.spawn, reserved.handle, context.structural_generation)) {
        context.generation.runtime_objects.discardTransient(reserved.handle) catch {};
        return 0;
    }
    if (fillRuntimeObjectHandle(context.generation, reserved.handle, context.world_epoch, output) == 0) {
        context.structural.count -= 1;
        context.generation.runtime_objects.discardTransient(reserved.handle) catch {};
        return 0;
    }
    return 1;
}

fn directDestroyObject(
    userdata: ?*anyopaque,
    object: ?*const behavior_runtime.NativeObjectHandle,
) callconv(.c) c_int {
    const context: *DirectHostContext = @ptrCast(@alignCast(userdata orelse return 0));
    if (!context.structural.canAppend(context.structural_generation)) return 0;
    const slot = validateRuntimeObjectHandle(context.generation, context.world_epoch, object) orelse return 0;
    const handle = context.generation.runtimeHandleAt(slot) orelse return 0;
    const record = context.generation.runtimeObject(handle) orelse return 0;
    if (record.source_index != null) return 0;
    if (!context.structural.append(.destroy, handle, context.structural_generation)) return 0;
    context.generation.requestTransientDestroy(handle) catch {
        context.structural.count -= 1;
        context.structural.next_sequence -= 1;
        return 0;
    };
    return 1;
}

fn activationSpawnObject(
    userdata: ?*anyopaque,
    prototype_id: [*c]const u8,
    prototype_id_length: usize,
    x: f64,
    y: f64,
    out_object: ?*behavior_runtime.NativeObjectHandle,
) callconv(.c) c_int {
    const context: *ActivationHostContext = @ptrCast(@alignCast(userdata orelse return 0));
    const output = out_object orelse return 0;
    output.* = std.mem.zeroes(behavior_runtime.NativeObjectHandle);
    if (prototype_id == null or prototype_id_length == 0 or prototype_id_length > scene_api.max_object_id_bytes or
        !validPosition(x, y) or !context.candidate_structural.canAppend(context.structural_generation) or
        context.target_structural.count + context.candidate_structural.count >= context.target_structural.requests.len) return 0;
    const reserved = context.generation.reserveTransient(
        prototype_id[0..prototype_id_length],
        .{ @floatCast(x), @floatCast(y) },
    ) catch return 0;
    if (!context.candidate_structural.append(.spawn, reserved.handle, context.structural_generation)) {
        context.generation.runtime_objects.discardTransient(reserved.handle) catch {};
        return 0;
    }
    context.present[reserved.handle.slot] = true;
    context.positions[reserved.handle.slot] = .{ @floatCast(x), @floatCast(y) };
    return fillRuntimeObjectHandle(context.generation, reserved.handle, context.world_epoch, output);
}

fn activationDestroyObject(
    userdata: ?*anyopaque,
    object: ?*const behavior_runtime.NativeObjectHandle,
) callconv(.c) c_int {
    const context: *ActivationHostContext = @ptrCast(@alignCast(userdata orelse return 0));
    if (!context.candidate_structural.canAppend(context.structural_generation) or
        context.target_structural.count + context.candidate_structural.count >= context.target_structural.requests.len) return 0;
    const slot = validateActivationObjectHandle(context, object) orelse return 0;
    const handle = context.generation.runtimeHandleAt(slot) orelse return 0;
    const record = context.generation.runtimeObject(handle) orelse return 0;
    if (record.source_index != null) return 0;
    if (!context.candidate_structural.append(.destroy, handle, context.structural_generation)) return 0;
    context.destroyed[slot] = true;
    return 1;
}

fn activationResolveObject(
    userdata: ?*anyopaque,
    object_id: [*c]const u8,
    object_id_length: usize,
    out_object: ?*behavior_runtime.NativeObjectHandle,
) callconv(.c) c_int {
    const context: *ActivationHostContext = @ptrCast(@alignCast(userdata orelse return 0));
    if (object_id == null or object_id_length == 0 or object_id_length > behavior_runtime.max_object_id_bytes) return 0;
    const handle = context.generation.runtimeHandle(object_id[0..object_id_length]) orelse return 0;
    if (context.destroyed[handle.slot]) return 0;
    return fillRuntimeObjectHandle(context.generation, handle, context.world_epoch, out_object);
}

fn activationGetObjectPosition(
    userdata: ?*anyopaque,
    object: ?*const behavior_runtime.NativeObjectHandle,
    out_x: ?*f64,
    out_y: ?*f64,
) callconv(.c) c_int {
    const context: *ActivationHostContext = @ptrCast(@alignCast(userdata orelse return 0));
    const slot = validateActivationObjectHandle(context, object) orelse return 0;
    if (out_x == null or out_y == null) return 0;
    out_x.?.* = context.positions[slot][0];
    out_y.?.* = context.positions[slot][1];
    return 1;
}

fn activationSetObjectPosition(
    userdata: ?*anyopaque,
    object: ?*const behavior_runtime.NativeObjectHandle,
    x: f64,
    y: f64,
) callconv(.c) c_int {
    const context: *ActivationHostContext = @ptrCast(@alignCast(userdata orelse return 0));
    const slot = validateActivationObjectHandle(context, object) orelse return 0;
    if (!validPosition(x, y)) return 0;
    context.positions[slot] = .{ @floatCast(x), @floatCast(y) };
    return 1;
}

fn activationPostEvent(userdata: ?*anyopaque, event: ?*const behavior_runtime.NativePostedEvent) callconv(.c) c_int {
    const context: *ActivationHostContext = @ptrCast(@alignCast(userdata orelse return 0));
    if (context.target_events.count + context.candidate_events.count >= context.target_events.events.len) return 0;
    const posted = event orelse return 0;
    const target_slot = validateActivationObjectHandle(context, &posted.target) orelse return 0;
    if (context.generation.runtime_objects.records[target_slot].state != .active or
        validateActivationObjectHandle(context, &posted.sender) == null) return 0;
    if (posted.field_count > 0) {
        const fields = posted.fields orelse return 0;
        for (fields[0..posted.field_count]) |field| {
            if (field.value.kind == 4 and validateActivationObjectHandle(context, &field.value.object_value) == null) return 0;
        }
    }
    return @intFromBool(context.candidate_events.appendPosted(posted, 0));
}

fn validateActivationObjectHandle(
    context: *ActivationHostContext,
    object: ?*const behavior_runtime.NativeObjectHandle,
) ?usize {
    const slot = validateRuntimeObjectHandle(context.generation, context.world_epoch, object) orelse return null;
    if (!context.present[slot] or context.destroyed[slot]) return null;
    return slot;
}

fn overlayResolveObject(
    userdata: ?*anyopaque,
    object_id: [*c]const u8,
    object_id_length: usize,
    out_object: ?*behavior_runtime.NativeObjectHandle,
) callconv(.c) c_int {
    const context: *OverlayHostContext = @ptrCast(@alignCast(userdata orelse return 0));
    if (object_id == null or object_id_length == 0 or object_id_length > behavior_runtime.max_object_id_bytes) return 0;
    const handle = context.generation.runtimeHandle(object_id[0..object_id_length]) orelse return 0;
    if (!context.present[handle.slot]) return 0;
    return fillRuntimeObjectHandle(context.generation, handle, context.world_epoch, out_object);
}

fn overlayGetObjectPosition(
    userdata: ?*anyopaque,
    object: ?*const behavior_runtime.NativeObjectHandle,
    out_x: ?*f64,
    out_y: ?*f64,
) callconv(.c) c_int {
    const context: *OverlayHostContext = @ptrCast(@alignCast(userdata orelse return 0));
    const index = validateOverlayObjectHandle(context, object) orelse return 0;
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
    const index = validateOverlayObjectHandle(context, object) orelse return 0;
    if (!validPosition(x, y)) return 0;
    context.positions[index] = .{ @floatCast(x), @floatCast(y) };
    return 1;
}

fn directResolveObject(
    userdata: ?*anyopaque,
    object_id: [*c]const u8,
    object_id_length: usize,
    out_object: ?*behavior_runtime.NativeObjectHandle,
) callconv(.c) c_int {
    const context: *DirectHostContext = @ptrCast(@alignCast(userdata orelse return 0));
    if (object_id == null or object_id_length == 0 or object_id_length > behavior_runtime.max_object_id_bytes) return 0;
    const handle = context.generation.runtimeHandle(object_id[0..object_id_length]) orelse return 0;
    return fillRuntimeObjectHandle(context.generation, handle, context.world_epoch, out_object);
}

fn directGetObjectPosition(
    userdata: ?*anyopaque,
    object: ?*const behavior_runtime.NativeObjectHandle,
    out_x: ?*f64,
    out_y: ?*f64,
) callconv(.c) c_int {
    const context: *DirectHostContext = @ptrCast(@alignCast(userdata orelse return 0));
    const index = validateRuntimeObjectHandle(context.generation, context.world_epoch, object) orelse return 0;
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
    const index = validateRuntimeObjectHandle(context.generation, context.world_epoch, object) orelse return 0;
    if (!validPosition(x, y)) return 0;
    context.generation.setObjectPosition(index, .{ @floatCast(x), @floatCast(y) }) catch return 0;
    return 1;
}

fn overlayPostEvent(userdata: ?*anyopaque, event: ?*const behavior_runtime.NativePostedEvent) callconv(.c) c_int {
    const context: *OverlayHostContext = @ptrCast(@alignCast(userdata orelse return 0));
    const posted = event orelse return 0;
    if (validateOverlayObjectHandle(context, &posted.target) == null or
        validateOverlayObjectHandle(context, &posted.sender) == null) return 0;
    if (posted.field_count > 0) {
        const fields = posted.fields orelse return 0;
        for (fields[0..posted.field_count]) |field| {
            if (field.value.kind == 4 and validateOverlayObjectHandle(context, &field.value.object_value) == null) return 0;
        }
    }
    return @intFromBool(context.events.appendPosted(posted, 0));
}

fn validateOverlayObjectHandle(
    context: *OverlayHostContext,
    object: ?*const behavior_runtime.NativeObjectHandle,
) ?usize {
    const slot = validateRuntimeObjectHandle(context.generation, context.world_epoch, object) orelse return null;
    if (!context.present[slot]) return null;
    return slot;
}

fn directPostEvent(userdata: ?*anyopaque, event: ?*const behavior_runtime.NativePostedEvent) callconv(.c) c_int {
    const context: *DirectHostContext = @ptrCast(@alignCast(userdata orelse return 0));
    if (context.post_generation > max_event_drain_generation) return 0;
    const posted = event orelse return 0;
    if (!validRuntimePostedEventObjects(context.generation, context.world_epoch, posted)) return 0;
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

fn fillRuntimeObjectHandle(
    generation: *scene_generation_api.SceneGeneration,
    handle: runtime_object_registry.Handle,
    world_epoch: u64,
    out_object: ?*behavior_runtime.NativeObjectHandle,
) c_int {
    const output = out_object orelse return 0;
    const record = generation.runtimeObject(handle) orelse return 0;
    output.* = std.mem.zeroes(behavior_runtime.NativeObjectHandle);
    output.world_epoch = world_epoch;
    output.logical_generation = handle.logical_generation;
    output.kind = switch (record.kind) {
        .sprite => 1,
        .player => 2,
        .goal => 3,
        .patrol_hazard => 4,
    };
    const object_id = record.object_id.slice();
    output.object_id_length = object_id.len;
    @memcpy(output.object_id[0..object_id.len], object_id);
    return 1;
}

fn validateRuntimeObjectHandle(
    generation: *scene_generation_api.SceneGeneration,
    world_epoch: u64,
    object: ?*const behavior_runtime.NativeObjectHandle,
) ?usize {
    const value = object orelse return null;
    if (value.world_epoch != world_epoch or value.logical_generation == 0 or
        value.object_id_length == 0 or value.object_id_length > behavior_runtime.max_object_id_bytes) return null;
    const handle = generation.runtimeHandle(value.object_id[0..value.object_id_length]) orelse return null;
    if (handle.logical_generation != value.logical_generation) return null;
    const record = generation.runtimeObject(handle) orelse return null;
    const expected_kind: u32 = switch (record.kind) {
        .sprite => 1,
        .player => 2,
        .goal => 3,
        .patrol_hazard => 4,
    };
    if (value.kind != expected_kind) return null;
    return handle.slot;
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

fn validRuntimePostedEventObjects(
    generation: *scene_generation_api.SceneGeneration,
    world_epoch: u64,
    event: *const behavior_runtime.NativePostedEvent,
) bool {
    const target_index = validateRuntimeObjectHandle(generation, world_epoch, &event.target) orelse return false;
    if (generation.runtime_objects.records[target_index].state != .active or
        validateRuntimeObjectHandle(generation, world_epoch, &event.sender) == null or
        event.field_count > 8 or (event.field_count > 0 and event.fields == null)) return false;
    if (event.field_count > 0) {
        const fields = event.fields orelse return false;
        for (fields[0..event.field_count]) |field| {
            if (field.value.kind == 4 and validateRuntimeObjectHandle(generation, world_epoch, &field.value.object_value) == null) return false;
        }
    }
    return true;
}

test "Behavior event drain rejects a ninth-generation successor before enqueue" {
    var queue = EventQueue{};
    var structural = StructuralQueue{};
    var unused_generation: scene_generation_api.SceneGeneration = undefined;
    const unused_event = std.mem.zeroes(behavior_runtime.NativePostedEvent);
    var context = DirectHostContext{
        .generation = &unused_generation,
        .world_epoch = 1,
        .events = &queue,
        .structural = &structural,
        .post_generation = max_event_drain_generation + 1,
    };
    try std.testing.expectEqual(@as(c_int, 0), directPostEvent(&context, &unused_event));
    try std.testing.expectEqual(@as(usize, 0), queue.count);
}

test "Direct Host resolves replacement entities and rejects stale object handles" {
    var generation = try scene_generation_api.SceneGeneration.prepare(scene_api.default_scene, .{ .width = 1024, .height = 720 });
    defer generation.deinit();
    var queue = EventQueue{};
    var structural = StructuralQueue{};
    var context = DirectHostContext{
        .generation = &generation,
        .world_epoch = 7,
        .events = &queue,
        .structural = &structural,
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

test "Direct Host enforces exact structural request and successor budgets" {
    const source =
        \\{"schemaVersion":6,"textures":[{"textureId":1,"artifact":"assets/renderer2d/test.texture"}],"objects":[
        \\{"objectId":"goal","kind":"goal","transform":{"position":[10,20]},"sprite":{"size":[3,4],"color":[1,1,1,1],"textureId":1},"behaviors":[]},
        \\{"objectId":"hazard","kind":"patrol_hazard","transform":{"position":[30,40]},"sprite":{"size":[2,2],"color":[1,1,1,1],"textureId":1},"behaviors":[{"scriptId":1,"parameters":{}}]},
        \\{"objectId":"player","kind":"player","transform":{"position":[1,2]},"sprite":{"size":[8,9],"color":[1,1,1,1],"textureId":1},"player":{"moveSpeed":10},"behaviors":[]}],"prototypes":[
        \\{"prototypeId":"runtime-orb","kind":"sprite","sprite":{"size":[2,2],"color":[1,1,1,1],"textureId":1},"behaviors":[]}]}
    ;
    const scene = try scene_api.parse(std.testing.allocator, source);
    var generation = try scene_generation_api.SceneGeneration.prepare(scene, .{ .width = 1024, .height = 720 });
    defer generation.deinit();
    var events = EventQueue{};
    var structural = StructuralQueue{};
    var context = DirectHostContext{
        .generation = &generation,
        .world_epoch = 7,
        .events = &events,
        .structural = &structural,
    };
    const prototype_id = "runtime-orb";
    for (0..max_structural_requests_per_domain) |index| {
        var object = std.mem.zeroes(behavior_runtime.NativeObjectHandle);
        try std.testing.expectEqual(@as(c_int, 1), directSpawnObject(
            &context,
            prototype_id.ptr,
            prototype_id.len,
            @floatFromInt(index),
            0,
            &object,
        ));
    }
    try std.testing.expectEqual(max_structural_requests_per_domain, structural.count);
    var rejected = std.mem.zeroes(behavior_runtime.NativeObjectHandle);
    try std.testing.expectEqual(@as(c_int, 0), directSpawnObject(&context, prototype_id.ptr, prototype_id.len, 0, 0, &rejected));
    try std.testing.expectEqual(scene.objects.count + max_structural_requests_per_domain, generation.runtime_objects.liveCount());

    var source_object = std.mem.zeroes(behavior_runtime.NativeObjectHandle);
    const player_id = "player";
    try std.testing.expectEqual(@as(c_int, 1), directResolveObject(&context, player_id.ptr, player_id.len, &source_object));
    try std.testing.expectEqual(@as(c_int, 0), directDestroyObject(&context, &source_object));

    structural.clear();
    context.structural_generation = max_structural_generation + 1;
    try std.testing.expectEqual(@as(c_int, 0), directSpawnObject(&context, prototype_id.ptr, prototype_id.len, 0, 0, &rejected));
    try std.testing.expectEqual(@as(usize, 0), structural.count);
}

test "Direct Host destroy failure leaves active transient object usable" {
    const source =
        \\{"schemaVersion":6,"textures":[{"textureId":1,"artifact":"assets/renderer2d/test.texture"}],"objects":[
        \\{"objectId":"goal","kind":"goal","transform":{"position":[10,20]},"sprite":{"size":[3,4],"color":[1,1,1,1],"textureId":1},"behaviors":[]},
        \\{"objectId":"hazard","kind":"patrol_hazard","transform":{"position":[30,40]},"sprite":{"size":[2,2],"color":[1,1,1,1],"textureId":1},"behaviors":[{"scriptId":1,"parameters":{}}]},
        \\{"objectId":"player","kind":"player","transform":{"position":[1,2]},"sprite":{"size":[8,9],"color":[1,1,1,1],"textureId":1},"player":{"moveSpeed":10},"behaviors":[]}],"prototypes":[
        \\{"prototypeId":"runtime-orb","kind":"sprite","sprite":{"size":[2,2],"color":[1,1,1,1],"textureId":1},"behaviors":[]}]}
    ;
    const scene = try scene_api.parse(std.testing.allocator, source);
    var generation = try scene_generation_api.SceneGeneration.prepare(scene, .{ .width = 1024, .height = 720 });
    defer generation.deinit();
    var events = EventQueue{};
    var structural = StructuralQueue{ .next_sequence = std.math.maxInt(u64) };
    var context = DirectHostContext{
        .generation = &generation,
        .world_epoch = 7,
        .events = &events,
        .structural = &structural,
    };
    const prototype_id = "runtime-orb";
    var rejected = std.mem.zeroes(behavior_runtime.NativeObjectHandle);
    try std.testing.expectEqual(@as(c_int, 0), directSpawnObject(
        &context,
        prototype_id.ptr,
        prototype_id.len,
        12,
        34,
        &rejected,
    ));
    try std.testing.expectEqual(scene.objects.count, generation.runtime_objects.liveCount());

    structural.next_sequence = 1;
    var pending = std.mem.zeroes(behavior_runtime.NativeObjectHandle);
    try std.testing.expectEqual(@as(c_int, 1), directSpawnObject(
        &context,
        prototype_id.ptr,
        prototype_id.len,
        12,
        34,
        &pending,
    ));
    const reserved = generation.runtimeHandle("runtime-0000000000000001") orelse return error.MissingTransient;
    try generation.activateTransient(reserved);
    structural.clear();
    structural.next_sequence = std.math.maxInt(u64);
    var object = std.mem.zeroes(behavior_runtime.NativeObjectHandle);
    try std.testing.expectEqual(@as(c_int, 1), fillRuntimeObjectHandle(&generation, reserved, context.world_epoch, &object));

    try std.testing.expectEqual(@as(c_int, 0), directDestroyObject(&context, &object));
    try std.testing.expectEqual(.active, generation.runtimeObject(reserved).?.state);
    try std.testing.expectEqual(@as(usize, 0), structural.count);
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
    if (scene.schemaVersion != scene_api.behavior_schema_version and
        scene.schemaVersion != scene_api.current_schema_version) return error.UnsupportedBehaviorSceneSchema;
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
    try scene_adapter.validatePrototypes(&package.parsed, scene);
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
    const fixed_structural = try allocator.create(StructuralQueue);
    errdefer allocator.destroy(fixed_structural);
    fixed_structural.* = .{};
    const frame_structural = try allocator.create(StructuralQueue);
    errdefer allocator.destroy(frame_structural);
    frame_structural.* = .{};
    prepared.activateInto(active);
    return .{
        .allocator = allocator,
        .package = package,
        .active = active,
        .world_epoch = world_epoch,
        .fixed_events = fixed_events,
        .frame_events = frame_events,
        .fixed_structural = fixed_structural,
        .frame_structural = frame_structural,
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
