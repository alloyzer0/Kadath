const std = @import("std");
const artifact = @import("behavior_artifact");
const behavior_runtime = @import("behavior_runtime");
const content_identity = @import("content_identity.zig");
const scene_adapter = @import("behavior_scene_adapter.zig");
const scene_api = @import("scene.zig");
const scene_generation_api = @import("scene_generation.zig");
const runtime_core = @import("runtime_core");

pub const InputSnapshot = behavior_runtime.InputSnapshot;

const max_exact_luau_world_epoch: u64 = 9_007_199_254_740_991;

const StructuralOrigin = struct {
    object_id: scene_api.ObjectId = .{},
    script_id: u32 = 0,

    fn isValid(self: StructuralOrigin) bool {
        return self.object_id.byte_count != 0 and self.script_id != 0;
    }
};

fn beginStructuralOrigin(userdata: ?*anyopaque, binding_index: usize, object_id: []const u8, script_id: u32) void {
    _ = binding_index;
    const origin: *StructuralOrigin = @ptrCast(@alignCast(userdata orelse return));
    origin.* = .{
        .object_id = scene_api.ObjectId.init(object_id) catch return,
        .script_id = script_id,
    };
}

fn endStructuralOrigin(userdata: ?*anyopaque) void {
    const origin: *StructuralOrigin = @ptrCast(@alignCast(userdata orelse return));
    origin.* = .{};
}

fn structuralObserver(origin: *StructuralOrigin) behavior_runtime.ActiveSet.BindingObserver {
    return .{ .userdata = origin, .begin = beginStructuralOrigin, .end = endStructuralOrigin };
}

const PhaseSession = struct {
    domain: runtime_core.PhaseDomain,
    sequence: u64,
};

pub const TranslationBatch = struct {
    deltas: [runtime_core.max_object_count][2]f64 = [_][2]f64{.{ 0, 0 }} ** runtime_core.max_object_count,
    object_count: usize = 0,
    events: [runtime_core.max_phase_events]runtime_core.PhaseEvent = undefined,
    event_count: usize = 0,

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
    phase_serial: u64 = 1,
    active_phase: ?PhaseSession = null,

    pub fn deinit(self: *Runtime) void {
        if (self.active) |active| {
            active.deinit();
            self.allocator.destroy(active);
        }
        if (self.package) |package| {
            package.deinit();
            self.allocator.destroy(package);
        }
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

    pub fn preparePhaseState(self: *Runtime, generation: *scene_generation_api.SceneGeneration) !void {
        const active = self.active orelse return error.BehaviorRuntimeNotLoaded;
        var bindings: [runtime_core.max_phase_bindings]runtime_core.PhaseBinding = undefined;
        var binding_count: usize = 0;
        if (active.binding_count > runtime_core.max_phase_bindings) return error.BehaviorInstanceCapacityExceeded;
        for (active.bindings[0..active.binding_count]) |optional_binding| {
            const behavior = optional_binding orelse continue;
            if (binding_count >= bindings.len) return error.BehaviorInstanceCapacityExceeded;
            var binding = std.mem.zeroes(runtime_core.PhaseBinding);
            binding.struct_size = @sizeOf(runtime_core.PhaseBinding);
            binding.behavior_count = 1;
            binding.script_id = behavior.script_id;
            binding.object_ref = generation.runtimeHandle(behavior.objectId()) orelse return error.StaleRuntimeObject;
            bindings[binding_count] = binding;
            binding_count += 1;
        }
        try generation.preparePhaseState(bindings[0..binding_count]);
    }

    pub fn commitPhaseState(self: *Runtime, generation: *scene_generation_api.SceneGeneration) !void {
        _ = self.active orelse return error.BehaviorRuntimeNotLoaded;
        try generation.commitPhaseState();
    }

    pub fn abortPhaseState(self: *Runtime, generation: *scene_generation_api.SceneGeneration) void {
        if (!self.isLoaded()) return;
        generation.abortPhaseState() catch |err| {
            std.log.err("Runtime Core phase candidate abort failed: {s}", .{@errorName(err)});
        };
    }

    fn beginPhase(self: *Runtime, generation: *scene_generation_api.SceneGeneration, domain: runtime_core.PhaseDomain) !PhaseSession {
        if (self.active_phase != null or self.phase_serial == 0 or self.phase_serial == std.math.maxInt(u64)) {
            return error.RuntimePhaseBusy;
        }
        try self.preparePhaseState(generation);
        try self.commitPhaseState(generation);
        const session = PhaseSession{ .domain = domain, .sequence = self.phase_serial };
        try generation.core.beginPhase(domain, session.sequence);
        self.phase_serial += 1;
        self.active_phase = session;
        return session;
    }

    fn requirePhase(self: *Runtime, domain: runtime_core.PhaseDomain) !PhaseSession {
        const session = self.active_phase orelse return error.RuntimePhaseActiveRequired;
        if (session.domain != domain) return error.InvalidRuntimePhaseDomain;
        return session;
    }

    fn endPhase(self: *Runtime, generation: *scene_generation_api.SceneGeneration, session: PhaseSession) !void {
        try generation.core.endPhase(session.domain, session.sequence);
        self.active_phase = null;
    }

    pub fn onStart(self: *Runtime, generation: *const scene_generation_api.SceneGeneration) !TranslationBatch {
        const active = self.active orelse return error.BehaviorRuntimeNotLoaded;
        const mutable_generation: *scene_generation_api.SceneGeneration = @constCast(generation);
        try self.prepareTransientBindings(mutable_generation);
        var handles: [runtime_core.max_object_count]scene_generation_api.RuntimeHandle = undefined;
        const ordered = try mutable_generation.activeHandles(&handles);
        var initial_positions: [runtime_core.max_object_count][2]f32 = undefined;
        var context = try OverlayHostContext.init(mutable_generation, self.world_epoch);
        for (ordered, 0..) |handle, index| {
            const object_index = mutable_generation.objectIndexForRef(handle) orelse return error.StaleRuntimeObject;
            initial_positions[index] = context.positions[object_index];
        }
        var host = overlayNativeHost(&context);
        try active.runStartV4(&host);
        var batch = TranslationBatch{ .object_count = ordered.len };
        for (ordered, 0..) |handle, index| {
            const object_index = mutable_generation.objectIndexForRef(handle) orelse return error.StaleRuntimeObject;
            const position = initial_positions[index];
            batch.deltas[index] = .{
                context.positions[object_index][0] - position[0],
                context.positions[object_index][1] - position[1],
            };
        }
        batch.event_count = context.event_count;
        @memcpy(batch.events[0..context.event_count], context.events[0..context.event_count]);
        return batch;
    }

    fn prepareTransientBindings(self: *Runtime, generation: *scene_generation_api.SceneGeneration) !void {
        const package = self.package orelse return error.BehaviorRuntimeNotLoaded;
        var diagnostic = behavior_runtime.Diagnostic{};
        var handles: [runtime_core.max_object_count]scene_generation_api.RuntimeHandle = undefined;
        for (try generation.activeHandles(&handles)) |handle| {
            const record = generation.runtimeObject(handle) orelse continue;
            if (record.source_index != null or record.behavior_count == 0 or self.active.?.containsObject(record.object_id.slice())) continue;
            const prototype_index = record.prototype_index orelse return error.InvalidRuntimeObjectActivation;
            const prototype = &generation.scene.prototypes.entries[prototype_index];
            const normalized = try scene_adapter.normalizePrototype(
                &package.parsed,
                prototype,
                record.object_id.slice(),
                record.sprite.position,
            );
            var prepared = try normalized.prepare(package, &diagnostic);
            errdefer prepared.deinit();
            try self.active.?.appendPrepared(&prepared);
        }
    }

    pub fn publishStartupEvents(
        self: *Runtime,
        generation: *scene_generation_api.SceneGeneration,
        batch: *const TranslationBatch,
    ) !void {
        if (batch.event_count == 0) return;
        const session = try self.beginPhase(generation, .frame);
        _ = try generation.core.submitPhaseEvents(batch.events[0..batch.event_count]);
        try self.settlePhase(generation, session, .{});
        try self.endPhase(generation, session);
    }

    pub fn runFixed(
        self: *Runtime,
        generation: *scene_generation_api.SceneGeneration,
        dt_seconds: f32,
        input: InputSnapshot,
    ) !void {
        const active = self.active orelse return error.BehaviorRuntimeNotLoaded;
        _ = try self.beginPhase(generation, .fixed);
        var context = DirectHostContext{
            .generation = generation,
            .world_epoch = self.world_epoch,
            .domain = .fixed,
        };
        var host = directNativeHost(&context);
        try active.runFixedV4Observed(dt_seconds, input, &host, structuralObserver(&context.origin));
        logFailures(active);
    }

    pub fn runUpdate(
        self: *Runtime,
        generation: *scene_generation_api.SceneGeneration,
        dt_seconds: f32,
        input: InputSnapshot,
    ) !void {
        const active = self.active orelse return error.BehaviorRuntimeNotLoaded;
        _ = try self.beginPhase(generation, .frame);
        var context = DirectHostContext{
            .generation = generation,
            .world_epoch = self.world_epoch,
            .domain = .frame,
        };
        var host = directNativeHost(&context);
        try active.runUpdateV4Observed(dt_seconds, input, &host, structuralObserver(&context.origin));
        logFailures(active);
    }

    pub fn finishFixedStep(
        self: *Runtime,
        generation: *scene_generation_api.SceneGeneration,
        input: InputSnapshot,
    ) !void {
        const session = if (self.active_phase == null)
            try self.beginPhase(generation, .fixed)
        else
            try self.requirePhase(.fixed);
        try self.settlePhase(generation, session, input);
        try self.endPhase(generation, session);
    }

    pub fn finishFrame(
        self: *Runtime,
        generation: *scene_generation_api.SceneGeneration,
        input: InputSnapshot,
    ) !void {
        const session = try self.requirePhase(.frame);
        try self.settlePhase(generation, session, input);
        try self.endPhase(generation, session);
    }

    fn settlePhase(
        self: *Runtime,
        generation: *scene_generation_api.SceneGeneration,
        session: PhaseSession,
        input: InputSnapshot,
    ) !void {
        const active = self.active orelse return error.BehaviorRuntimeNotLoaded;
        active.beginEventDrain();
        while (true) {
            const drained = try self.drainEvents(generation, session, input);
            const flushed = try self.flushStructural(generation, session);
            if (!drained and !flushed) return;
        }
    }

    fn drainEvents(
        self: *Runtime,
        generation: *scene_generation_api.SceneGeneration,
        session: PhaseSession,
        input: InputSnapshot,
    ) !bool {
        const active = self.active orelse return error.BehaviorRuntimeNotLoaded;
        var did_work = false;
        while (true) {
            var drained: [runtime_core.max_phase_events]runtime_core.PhaseEvent = undefined;
            for (&drained) |*event| {
                event.* = std.mem.zeroes(runtime_core.PhaseEvent);
                event.struct_size = @sizeOf(runtime_core.PhaseEvent);
            }
            const count = try generation.core.drainPhaseEvents(session.domain, session.sequence, &drained);
            if (count == 0) break;
            did_work = true;
            for (drained[0..count]) |*event| {
                const target_id = runtime_core.objectIdSlice(&event.target);
                if (generation.runtimeObject(event.target) == null) {
                    std.log.warn("Behavior event target became stale before delivery: name={s}, target={s}", .{
                        event.name[0..event.name_length],
                        target_id,
                    });
                    continue;
                }
                var context = DirectHostContext{
                    .generation = generation,
                    .world_epoch = self.world_epoch,
                    .domain = session.domain,
                };
                var host = directNativeHost(&context);
                var native_fields: [8]behavior_runtime.NativeEventField = undefined;
                for (event.fields[0..event.field_count], 0..) |*field, field_index| {
                    native_fields[field_index] = std.mem.zeroes(behavior_runtime.NativeEventField);
                    native_fields[field_index].key = &field.key;
                    native_fields[field_index].key_length = field.key_length;
                    native_fields[field_index].value.kind = field.value_kind;
                    switch (field.value_kind) {
                        runtime_core.phase_event_boolean => native_fields[field_index].value.boolean_value = field.value.boolean_value,
                        runtime_core.phase_event_number => native_fields[field_index].value.number_value = field.value.number_value,
                        runtime_core.phase_event_string => {
                            native_fields[field_index].value.string_value = &field.value.string_value.bytes;
                            native_fields[field_index].value.string_value_length = field.value.string_value.length;
                        },
                        runtime_core.phase_event_object => {
                            _ = fillNativeObjectHandle(field.value.object_value, &native_fields[field_index].value.object_value);
                        },
                        else => return error.InvalidRuntimePhaseRequest,
                    }
                }
                var sender = std.mem.zeroes(behavior_runtime.NativeObjectHandle);
                var other = std.mem.zeroes(behavior_runtime.NativeObjectHandle);
                if (event.has_sender != 0) _ = fillNativeObjectHandle(event.sender, &sender);
                if (event.has_other != 0) _ = fillNativeObjectHandle(event.other, &other);
                var native_event = behavior_runtime.NativeEvent{
                    .name = &event.name,
                    .name_length = event.name_length,
                    .domain = @intFromEnum(session.domain),
                    .has_sender = event.has_sender,
                    .sender = sender,
                    .has_other = event.has_other,
                    .other = other,
                    .fields = if (event.field_count == 0) null else &native_fields,
                    .field_count = event.field_count,
                };
                try active.dispatchEventV4Observed(
                    target_id,
                    &native_event,
                    input,
                    &host,
                    structuralObserver(&context.origin),
                );
            }
        }
        logFailures(active);
        return did_work;
    }

    fn flushStructural(
        self: *Runtime,
        generation: *scene_generation_api.SceneGeneration,
        session: PhaseSession,
    ) !bool {
        const active = self.active orelse return error.BehaviorRuntimeNotLoaded;
        var did_work = false;
        while (true) {
            var requests: [runtime_core.max_phase_structural]runtime_core.PhaseStructural = undefined;
            for (&requests) |*request| {
                request.* = std.mem.zeroes(runtime_core.PhaseStructural);
                request.struct_size = @sizeOf(runtime_core.PhaseStructural);
            }
            const taken = try generation.core.takePhaseStructural(session.domain, session.sequence, &requests);
            if (taken.count == 0) break;
            did_work = true;

            var completions: [runtime_core.max_phase_structural]runtime_core.PhaseCompletion = undefined;
            var completion_count: usize = 0;
            for (requests[0..taken.count]) |request| {
                switch (request.operation) {
                    runtime_core.phase_operation_reserve_transient => {
                        const transaction = try generation.core.beginPhaseActivation(taken.info.flush_token, request.sequence);
                        const maybe_record = generation.runtimeObject(request.object_ref);
                        if (maybe_record == null) {
                            var context = ActivationHostContext.init(
                                generation,
                                self.world_epoch,
                                transaction.transaction_id,
                                session.domain,
                                runtime_core.max_phase_bindings,
                            ) catch |err| {
                                try generation.core.abortPhaseActivation(transaction.transaction_id);
                                reportStructuralFailure(active, request, err, null);
                                continue;
                            };
                            context.finish() catch |err| {
                                try generation.core.abortPhaseActivation(transaction.transaction_id);
                                reportStructuralFailure(active, request, err, null);
                                continue;
                            };
                            _ = generation.core.commitPhaseActivation(transaction.transaction_id) catch |err| {
                                generation.core.abortPhaseActivation(transaction.transaction_id) catch {};
                                reportStructuralFailure(active, request, err, null);
                                continue;
                            };
                            continue;
                        }

                        const record = maybe_record.?;
                        const package = self.package orelse return error.BehaviorRuntimeNotLoaded;
                        const prototype_index = record.prototype_index orelse {
                            try generation.core.abortPhaseActivation(transaction.transaction_id);
                            reportStructuralFailure(active, request, error.InvalidRuntimeObjectActivation, null);
                            continue;
                        };
                        const prototype = &generation.scene.prototypes.entries[prototype_index];
                        const normalized = scene_adapter.normalizePrototype(
                            &package.parsed,
                            prototype,
                            record.object_id.slice(),
                            record.sprite.position,
                        ) catch |err| {
                            try generation.core.abortPhaseActivation(transaction.transaction_id);
                            reportStructuralFailure(active, request, err, prototype.prototypeId.slice());
                            continue;
                        };
                        var diagnostic = behavior_runtime.Diagnostic{};
                        var prepared = normalized.prepare(package, &diagnostic) catch |err| {
                            try generation.core.abortPhaseActivation(transaction.transaction_id);
                            logDiagnostic("Dynamic Behavior binding preparation failed", err, diagnostic.slice());
                            reportStructuralFailure(active, request, err, prototype.prototypeId.slice());
                            continue;
                        };
                        var candidate = prepared.activate();
                        if (active.binding_count > runtime_core.max_phase_bindings or
                            candidate.binding_count > runtime_core.max_phase_bindings - active.binding_count)
                        {
                            candidate.deinit();
                            try generation.core.abortPhaseActivation(transaction.transaction_id);
                            reportStructuralFailure(active, request, error.BehaviorBindingCountExceeded, prototype.prototypeId.slice());
                            continue;
                        }

                        const activation_context = self.allocator.create(ActivationHostContext) catch |err| {
                            candidate.deinit();
                            try generation.core.abortPhaseActivation(transaction.transaction_id);
                            reportStructuralFailure(active, request, err, prototype.prototypeId.slice());
                            continue;
                        };
                        defer self.allocator.destroy(activation_context);
                        activation_context.* = ActivationHostContext.init(
                            generation,
                            self.world_epoch,
                            transaction.transaction_id,
                            session.domain,
                            runtime_core.max_phase_bindings,
                        ) catch |err| {
                            candidate.deinit();
                            try generation.core.abortPhaseActivation(transaction.transaction_id);
                            reportStructuralFailure(active, request, err, prototype.prototypeId.slice());
                            continue;
                        };
                        var activation_host = activationNativeHost(activation_context);
                        candidate.runStartV4Observed(
                            &activation_host,
                            structuralObserver(&activation_context.origin),
                        ) catch |err| {
                            candidate.deinit();
                            try generation.core.abortPhaseActivation(transaction.transaction_id);
                            std.log.warn("Dynamic Behavior on_start failed: sequence={d}, error={s}", .{
                                request.sequence,
                                @errorName(err),
                            });
                            continue;
                        };
                        activation_context.finish() catch |err| {
                            candidate.deinit();
                            try generation.core.abortPhaseActivation(transaction.transaction_id);
                            reportStructuralFailure(active, request, err, prototype.prototypeId.slice());
                            continue;
                        };
                        const activation_result = generation.core.commitPhaseActivation(transaction.transaction_id) catch |err| {
                            candidate.deinit();
                            generation.core.abortPhaseActivation(transaction.transaction_id) catch {};
                            reportStructuralFailure(active, request, err, prototype.prototypeId.slice());
                            continue;
                        };
                        if (activation_result.root_object.struct_size == 0) {
                            candidate.deinit();
                        } else {
                            active.appendActive(&candidate) catch unreachable;
                        }
                    },
                    runtime_core.phase_operation_request_destroy,
                    runtime_core.phase_operation_discard_reservation,
                    => {
                        completions[completion_count] = std.mem.zeroes(runtime_core.PhaseCompletion);
                        completions[completion_count].struct_size = @sizeOf(runtime_core.PhaseCompletion);
                        completions[completion_count].status = runtime_core.phase_completion_accepted;
                        completions[completion_count].sequence = request.sequence;
                        completion_count += 1;
                    },
                    else => return error.InvalidRuntimePhaseRequest,
                }
            }
            if (completion_count != 0) {
                try generation.core.completePhaseStructural(taken.info.flush_token, completions[0..completion_count]);
                for (requests[0..taken.count]) |request| {
                    if (request.operation == runtime_core.phase_operation_request_destroy or
                        request.operation == runtime_core.phase_operation_discard_reservation)
                    {
                        active.removeObject(runtime_core.objectIdSlice(&request.object_ref));
                    }
                }
            }
        }
        if (did_work) try generation.refreshPhaseProjection();
        return did_work;
    }
};

fn reportStructuralFailure(
    active: *behavior_runtime.ActiveSet,
    request: runtime_core.PhaseStructural,
    err: anyerror,
    target_id: ?[]const u8,
) void {
    const has_origin = request.origin.struct_size != 0 and request.script_id != 0;
    const origin_id = if (has_origin) runtime_core.objectIdSlice(&request.origin) else "<unknown>";
    const target = target_id orelse "<unknown>";
    if (has_origin) {
        active.disableBindingByIdentity(origin_id, request.script_id, err, "structural commit failed");
    }
    std.log.warn(
        "Behavior structural commit failed: sequence={d}, operation={s}, origin_object={s}, origin_script={d}, target={s}, error={s}",
        .{ request.sequence, phaseOperationName(request.operation), origin_id, request.script_id, target, @errorName(err) },
    );
}

fn phaseOperationName(operation: u32) []const u8 {
    return switch (operation) {
        runtime_core.phase_operation_reserve_transient => "spawn",
        runtime_core.phase_operation_request_destroy => "destroy",
        runtime_core.phase_operation_discard_reservation => "discard",
        else => "unknown",
    };
}

const OverlayHostContext = struct {
    generation: *scene_generation_api.SceneGeneration,
    world_epoch: u64,
    positions: [runtime_core.max_object_count][2]f32 = [_][2]f32{.{ 0, 0 }} ** runtime_core.max_object_count,
    present: [runtime_core.max_object_count]bool = [_]bool{false} ** runtime_core.max_object_count,
    events: [runtime_core.max_phase_events]runtime_core.PhaseEvent = undefined,
    event_count: usize = 0,

    fn init(generation: *scene_generation_api.SceneGeneration, world_epoch: u64) !OverlayHostContext {
        var context = OverlayHostContext{ .generation = generation, .world_epoch = world_epoch };
        var handles: [runtime_core.max_object_count]scene_generation_api.RuntimeHandle = undefined;
        for (try generation.activeHandles(&handles)) |handle| {
            const index = generation.objectIndexForRef(handle) orelse return error.StaleRuntimeObject;
            context.present[index] = true;
            context.positions[index] = try generation.objectPosition(index);
        }
        return context;
    }
};

const DirectHostContext = struct {
    generation: *scene_generation_api.SceneGeneration,
    world_epoch: u64,
    domain: runtime_core.PhaseDomain,
    origin: StructuralOrigin = .{},
};

const ActivationHostContext = struct {
    generation: *scene_generation_api.SceneGeneration,
    world_epoch: u64,
    transaction_id: u64,
    domain: runtime_core.PhaseDomain,
    active_binding_capacity: usize,
    handles: [runtime_core.max_object_count]runtime_core.ObjectRef = undefined,
    positions: [runtime_core.max_object_count][2]f32 = [_][2]f32{.{ 0, 0 }} ** runtime_core.max_object_count,
    present: [runtime_core.max_object_count]bool = [_]bool{false} ** runtime_core.max_object_count,
    destroyed: [runtime_core.max_object_count]bool = [_]bool{false} ** runtime_core.max_object_count,
    handle_count: usize = 0,
    origin: StructuralOrigin = .{},

    fn init(
        generation: *scene_generation_api.SceneGeneration,
        world_epoch: u64,
        transaction_id: u64,
        domain: runtime_core.PhaseDomain,
        active_binding_capacity: usize,
    ) !ActivationHostContext {
        var context = ActivationHostContext{
            .generation = generation,
            .world_epoch = world_epoch,
            .transaction_id = transaction_id,
            .domain = domain,
            .active_binding_capacity = active_binding_capacity,
        };
        var handles: [runtime_core.max_object_count]scene_generation_api.RuntimeHandle = undefined;
        for (try generation.visibleHandles(&handles)) |handle| {
            const index = context.handle_count;
            context.handles[index] = handle;
            context.present[index] = true;
            const object_index = generation.objectIndexForRef(handle) orelse return error.StaleRuntimeObject;
            context.positions[index] = try generation.objectPosition(object_index);
            context.handle_count += 1;
        }
        return context;
    }

    fn indexOf(self: *const ActivationHostContext, object: *const behavior_runtime.NativeObjectHandle) ?usize {
        for (self.handles[0..self.handle_count], 0..) |handle, index| {
            if (nativeMatchesObjectRef(object, handle) and self.present[index] and !self.destroyed[index]) return index;
        }
        return null;
    }

    fn submit(self: *ActivationHostContext, batch: *runtime_core.PhaseActivationBatch, results: []runtime_core.PhaseActivationStructuralResult) !void {
        batch.struct_size = @sizeOf(runtime_core.PhaseActivationBatch);
        batch.transaction_id = self.transaction_id;
        batch.active_binding_capacity = self.active_binding_capacity;
        try self.generation.core.submitPhaseActivation(self.transaction_id, batch, results);
    }

    fn finish(self: *ActivationHostContext) !void {
        var batch = std.mem.zeroes(runtime_core.PhaseActivationBatch);
        try self.submit(&batch, &[_]runtime_core.PhaseActivationStructuralResult{});
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
        !validPosition(x, y)) return 0;
    const prototype_index = context.generation.scene.prototypes.indexOfId(prototype_id[0..prototype_id_length]) orelse return 0;
    const prototype = &context.generation.scene.prototypes.entries[prototype_index];
    const request = phaseSpawnRequest(
        context.generation,
        context.domain,
        context.origin,
        prototype_index,
        prototype,
        .{ @floatCast(x), @floatCast(y) },
    ) orelse return 0;
    var acceptance = std.mem.zeroes(runtime_core.PhaseCompletion);
    acceptance.struct_size = @sizeOf(runtime_core.PhaseCompletion);
    var acceptances = [_]runtime_core.PhaseCompletion{acceptance};
    _ = context.generation.core.submitPhaseStructural(&.{request}, &acceptances) catch return 0;
    return fillNativeObjectHandle(acceptances[0].object.object_ref, output);
}

fn directDestroyObject(
    userdata: ?*anyopaque,
    object: ?*const behavior_runtime.NativeObjectHandle,
) callconv(.c) c_int {
    const context: *DirectHostContext = @ptrCast(@alignCast(userdata orelse return 0));
    const slot = validateRuntimeObjectHandle(context.generation, context.world_epoch, object) orelse return 0;
    const handle = context.generation.runtimeHandleAt(slot) orelse return 0;
    const request = phaseDestroyRequest(context.generation, context.domain, context.origin, handle) orelse return 0;
    var acceptance = std.mem.zeroes(runtime_core.PhaseCompletion);
    acceptance.struct_size = @sizeOf(runtime_core.PhaseCompletion);
    var acceptances = [_]runtime_core.PhaseCompletion{acceptance};
    _ = context.generation.core.submitPhaseStructural(&.{request}, &acceptances) catch return 0;
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
        !validPosition(x, y) or context.handle_count >= context.handles.len) return 0;
    const prototype_index = context.generation.scene.prototypes.indexOfId(prototype_id[0..prototype_id_length]) orelse return 0;
    const prototype = &context.generation.scene.prototypes.entries[prototype_index];
    const request = phaseSpawnRequest(
        context.generation,
        context.domain,
        context.origin,
        prototype_index,
        prototype,
        .{ @floatCast(x), @floatCast(y) },
    ) orelse return 0;
    var result = std.mem.zeroes(runtime_core.PhaseActivationStructuralResult);
    result.struct_size = @sizeOf(runtime_core.PhaseActivationStructuralResult);
    var results = [_]runtime_core.PhaseActivationStructuralResult{result};
    var batch = std.mem.zeroes(runtime_core.PhaseActivationBatch);
    batch.structural = &request;
    batch.structural_count = 1;
    batch.structural_stride = @sizeOf(runtime_core.PhaseStructural);
    context.submit(&batch, &results) catch return 0;
    const index = context.handle_count;
    context.handles[index] = results[0].object_ref;
    context.positions[index] = .{ @floatCast(x), @floatCast(y) };
    context.present[index] = true;
    context.handle_count += 1;
    return fillNativeObjectHandle(results[0].object_ref, output);
}

fn activationDestroyObject(
    userdata: ?*anyopaque,
    object: ?*const behavior_runtime.NativeObjectHandle,
) callconv(.c) c_int {
    const context: *ActivationHostContext = @ptrCast(@alignCast(userdata orelse return 0));
    const value = object orelse return 0;
    const slot = context.indexOf(value) orelse return 0;
    const request = phaseDestroyRequest(
        context.generation,
        context.domain,
        context.origin,
        context.handles[slot],
    ) orelse return 0;
    var result = std.mem.zeroes(runtime_core.PhaseActivationStructuralResult);
    result.struct_size = @sizeOf(runtime_core.PhaseActivationStructuralResult);
    var results = [_]runtime_core.PhaseActivationStructuralResult{result};
    var batch = std.mem.zeroes(runtime_core.PhaseActivationBatch);
    batch.structural = &request;
    batch.structural_count = 1;
    batch.structural_stride = @sizeOf(runtime_core.PhaseStructural);
    context.submit(&batch, &results) catch return 0;
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
    for (context.handles[0..context.handle_count], 0..) |handle, index| {
        if (context.destroyed[index] or !std.mem.eql(u8, runtime_core.objectIdSlice(&handle), object_id[0..object_id_length])) continue;
        return fillNativeObjectHandle(handle, out_object);
    }
    return 0;
}

fn activationGetObjectPosition(
    userdata: ?*anyopaque,
    object: ?*const behavior_runtime.NativeObjectHandle,
    out_x: ?*f64,
    out_y: ?*f64,
) callconv(.c) c_int {
    const context: *ActivationHostContext = @ptrCast(@alignCast(userdata orelse return 0));
    const slot = context.indexOf(object orelse return 0) orelse return 0;
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
    const slot = context.indexOf(object orelse return 0) orelse return 0;
    if (!validPosition(x, y)) return 0;
    var patch = std.mem.zeroes(runtime_core.PhasePositionPatch);
    patch.struct_size = @sizeOf(runtime_core.PhasePositionPatch);
    patch.object_ref = context.handles[slot];
    patch.position = .{ @floatCast(x), @floatCast(y) };
    var batch = std.mem.zeroes(runtime_core.PhaseActivationBatch);
    batch.positions = &patch;
    batch.position_count = 1;
    batch.position_stride = @sizeOf(runtime_core.PhasePositionPatch);
    context.submit(&batch, &[_]runtime_core.PhaseActivationStructuralResult{}) catch return 0;
    context.positions[slot] = .{ @floatCast(x), @floatCast(y) };
    return 1;
}

fn activationPostEvent(userdata: ?*anyopaque, event: ?*const behavior_runtime.NativePostedEvent) callconv(.c) c_int {
    const context: *ActivationHostContext = @ptrCast(@alignCast(userdata orelse return 0));
    const posted = event orelse return 0;
    if (context.indexOf(&posted.target) == null or context.indexOf(&posted.sender) == null) return 0;
    if (posted.field_count > 0) {
        const fields = posted.fields orelse return 0;
        for (fields[0..posted.field_count]) |field| {
            if (field.value.kind == runtime_core.phase_event_object and context.indexOf(&field.value.object_value) == null) return 0;
        }
    }
    var phase_event = phaseEventFromPosted(posted, context.domain) orelse return 0;
    var batch = std.mem.zeroes(runtime_core.PhaseActivationBatch);
    batch.events = &phase_event;
    batch.event_count = 1;
    batch.event_stride = @sizeOf(runtime_core.PhaseEvent);
    context.submit(&batch, &[_]runtime_core.PhaseActivationStructuralResult{}) catch return 0;
    return 1;
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
    const object_index = context.generation.objectIndexForRef(handle) orelse return 0;
    if (!context.present[object_index]) return 0;
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
    if (context.event_count >= context.events.len) return 0;
    if (validateOverlayObjectHandle(context, &posted.target) == null or
        validateOverlayObjectHandle(context, &posted.sender) == null) return 0;
    if (posted.field_count > 0) {
        const fields = posted.fields orelse return 0;
        for (fields[0..posted.field_count]) |field| {
            if (field.value.kind == runtime_core.phase_event_object and validateOverlayObjectHandle(context, &field.value.object_value) == null) return 0;
        }
    }
    context.events[context.event_count] = phaseEventFromPosted(posted, .frame) orelse return 0;
    context.event_count += 1;
    return 1;
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
    const posted = event orelse return 0;
    if (!validRuntimePostedEventObjects(context.generation, context.world_epoch, posted)) return 0;
    const phase_event = phaseEventFromPosted(posted, context.domain) orelse return 0;
    _ = context.generation.core.submitPhaseEvents(&.{phase_event}) catch return 0;
    return 1;
}

fn objectRefFromNative(value: *const behavior_runtime.NativeObjectHandle) ?runtime_core.ObjectRef {
    if (!validObjectHandleShape(value)) return null;
    var result = std.mem.zeroes(runtime_core.ObjectRef);
    result.struct_size = @sizeOf(runtime_core.ObjectRef);
    result.kind = value.kind;
    result.world_epoch = value.world_epoch;
    result.logical_generation = value.logical_generation;
    result.object_id_length = @intCast(value.object_id_length);
    @memcpy(result.object_id[0..value.object_id_length], value.object_id[0..value.object_id_length]);
    return result;
}

fn fillNativeObjectHandle(value: runtime_core.ObjectRef, output: ?*behavior_runtime.NativeObjectHandle) c_int {
    const result = output orelse return 0;
    result.* = std.mem.zeroes(behavior_runtime.NativeObjectHandle);
    result.world_epoch = value.world_epoch;
    result.logical_generation = value.logical_generation;
    result.kind = value.kind;
    result.object_id_length = value.object_id_length;
    @memcpy(result.object_id[0..value.object_id_length], value.object_id[0..value.object_id_length]);
    return 1;
}

fn nativeMatchesObjectRef(value: *const behavior_runtime.NativeObjectHandle, object_ref: runtime_core.ObjectRef) bool {
    return value.world_epoch == object_ref.world_epoch and
        value.logical_generation == object_ref.logical_generation and
        value.kind == object_ref.kind and
        value.object_id_length == object_ref.object_id_length and
        std.mem.eql(u8, value.object_id[0..value.object_id_length], runtime_core.objectIdSlice(&object_ref));
}

fn phaseEventFromPosted(
    posted: *const behavior_runtime.NativePostedEvent,
    domain: runtime_core.PhaseDomain,
) ?runtime_core.PhaseEvent {
    if (posted.name == null or posted.name_length == 0 or posted.name_length > 63 or
        posted.field_count > 8 or (posted.field_count > 0 and posted.fields == null)) return null;
    var event = std.mem.zeroes(runtime_core.PhaseEvent);
    event.struct_size = @sizeOf(runtime_core.PhaseEvent);
    event.domain = @intFromEnum(domain);
    event.has_sender = 1;
    event.target = objectRefFromNative(&posted.target) orelse return null;
    event.sender = objectRefFromNative(&posted.sender) orelse return null;
    event.name_length = @intCast(posted.name_length);
    @memcpy(event.name[0..posted.name_length], posted.name[0..posted.name_length]);
    event.field_count = @intCast(posted.field_count);
    if (posted.field_count > 0) {
        const fields = posted.fields orelse return null;
        for (fields[0..posted.field_count], 0..) |field, index| {
            if (field.key == null or field.key_length == 0 or field.key_length > 31 or !validEventValue(&field.value)) return null;
            event.fields[index].struct_size = @sizeOf(@TypeOf(event.fields[index]));
            event.fields[index].value_kind = field.value.kind;
            event.fields[index].key_length = @intCast(field.key_length);
            @memcpy(event.fields[index].key[0..field.key_length], field.key[0..field.key_length]);
            switch (field.value.kind) {
                runtime_core.phase_event_boolean => event.fields[index].value.boolean_value = field.value.boolean_value,
                runtime_core.phase_event_number => event.fields[index].value.number_value = field.value.number_value,
                runtime_core.phase_event_string => {
                    event.fields[index].value.string_value.length = @intCast(field.value.string_value_length);
                    @memcpy(
                        event.fields[index].value.string_value.bytes[0..field.value.string_value_length],
                        field.value.string_value[0..field.value.string_value_length],
                    );
                },
                runtime_core.phase_event_object => event.fields[index].value.object_value = objectRefFromNative(&field.value.object_value) orelse return null,
                else => return null,
            }
        }
    }
    return event;
}

fn phaseSpawnRequest(
    generation: *scene_generation_api.SceneGeneration,
    domain: runtime_core.PhaseDomain,
    origin: StructuralOrigin,
    prototype_index: usize,
    prototype: *const scene_api.SpawnPrototype,
    position: [2]f32,
) ?runtime_core.PhaseStructural {
    if (!origin.isValid()) return null;
    var request = std.mem.zeroes(runtime_core.PhaseStructural);
    request.struct_size = @sizeOf(runtime_core.PhaseStructural);
    request.operation = runtime_core.phase_operation_reserve_transient;
    request.domain = @intFromEnum(domain);
    request.behavior_count = prototype.behaviors.count;
    request.prototype_key = @intCast(prototype_index);
    request.script_id = origin.script_id;
    request.origin = generation.runtimeHandle(origin.object_id.slice()) orelse return null;
    request.transient_sprite.struct_size = @sizeOf(@TypeOf(request.transient_sprite));
    request.transient_sprite.position = position;
    request.transient_sprite.size = prototype.sprite.size;
    request.transient_sprite.color = prototype.sprite.color;
    request.transient_sprite.texture_id = prototype.sprite.textureId;
    return request;
}

fn phaseDestroyRequest(
    generation: *scene_generation_api.SceneGeneration,
    domain: runtime_core.PhaseDomain,
    origin: StructuralOrigin,
    object_ref: runtime_core.ObjectRef,
) ?runtime_core.PhaseStructural {
    if (!origin.isValid()) return null;
    var request = std.mem.zeroes(runtime_core.PhaseStructural);
    request.struct_size = @sizeOf(runtime_core.PhaseStructural);
    request.operation = runtime_core.phase_operation_request_destroy;
    request.domain = @intFromEnum(domain);
    request.script_id = origin.script_id;
    request.object_ref = object_ref;
    request.origin = generation.runtimeHandle(origin.object_id.slice()) orelse return null;
    return request;
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
    handle: scene_generation_api.RuntimeHandle,
    world_epoch: u64,
    out_object: ?*behavior_runtime.NativeObjectHandle,
) c_int {
    const output = out_object orelse return 0;
    const record = generation.runtimeObject(handle) orelse return 0;
    output.* = std.mem.zeroes(behavior_runtime.NativeObjectHandle);
    if (handle.world_epoch != world_epoch) return 0;
    output.world_epoch = handle.world_epoch;
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
    return generation.objectIndexForRef(handle);
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
    const target_handle = generation.runtimeHandleAt(target_index) orelse return false;
    if (generation.runtimeObject(target_handle).?.state != .active or
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
    prepared.activateInto(active);
    return .{
        .allocator = allocator,
        .package = package,
        .active = active,
        .world_epoch = world_epoch,
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
