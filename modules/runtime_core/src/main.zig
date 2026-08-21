const std = @import("std");

const c = @cImport({
    @cInclude("kadath_runtime_core.h");
});

pub const max_object_count: usize = c.KADATH_RUNTIME_MAX_OBJECTS;
pub const max_logical_generation: u64 = 9_007_199_254_740_991;
pub const EntityId = u64;
pub const invalid_entity: EntityId = c.KADATH_RUNTIME_ENTITY_INVALID;
pub const TextureId = u32;
pub const invalid_texture: TextureId = 0;

pub const ObjectRef = c.kadath_runtime_object_ref_v1_t;
pub const ObjectView = c.kadath_runtime_object_view_v1_t;

pub const Target = enum { live, candidate };
pub const PrepareMode = enum { initial, restart, scene_reload };

pub const InputSnapshot = struct {
    move_x: i8 = 0,
    move_y: i8 = 0,
};

pub const RenderSprite = extern struct {
    entity_id: EntityId,
    position: [2]f32,
    size: [2]f32,
    color: [4]f32,
    texture_id: TextureId,
};

pub const SpriteDesc = struct {
    position: [2]f32,
    size: [2]f32,
    color: [4]f32,
    texture_id: TextureId,
    move_speed: f32 = 0,
};

pub const TransientDesc = struct {
    prototype_key: u32,
    kind: u32,
    sprite: SpriteDesc,
};

pub const SourceDesc = struct {
    object_id: []const u8,
    kind: u32,
    sprite: SpriteDesc,
};

pub const CandidateInfo = struct {
    mode: PrepareMode,
    world_epoch: u64,
    source_object_count: usize,
};

pub const DestroyDisposition = enum { cancelled_pending_spawn, awaiting_finalize };

pub const PositionPatch = struct {
    object_ref: ObjectRef,
    position: [2]f32,
};

pub const ActivationCommand = union(enum) {
    activate: ObjectRef,
    discard_reservation: ObjectRef,
    request_destroy: ObjectRef,
};

pub const RuntimeCore = struct {
    interface: c.kadath_runtime_object_authority_interface_t,
    handle: ?*c.kadath_runtime_core_t,
    owns_handle: bool = true,

    pub fn init() !RuntimeCore {
        var interface = std.mem.zeroes(c.kadath_runtime_object_authority_interface_t);
        interface.struct_size = @sizeOf(c.kadath_runtime_object_authority_interface_t);
        interface.interface_version = c.KADATH_RUNTIME_OBJECT_AUTHORITY_INTERFACE_V1;
        try check(c.kadath_runtime_core_query_object_authority_interface(&interface));
        var create_desc = std.mem.zeroes(c.kadath_runtime_core_create_desc_t);
        create_desc.struct_size = @sizeOf(c.kadath_runtime_core_create_desc_t);
        var handle: ?*c.kadath_runtime_core_t = null;
        try check(interface.create.?(&create_desc, &handle));
        if (handle == null) return error.RuntimeCoreCreationFailed;
        return .{ .interface = interface, .handle = handle };
    }

    pub fn borrow(self: *const RuntimeCore) RuntimeCore {
        return .{ .interface = self.interface, .handle = self.handle, .owns_handle = false };
    }

    pub fn takeOwnership(self: *RuntimeCore, previous: *RuntimeCore) void {
        std.debug.assert(self.handle == previous.handle);
        std.debug.assert(!self.owns_handle and previous.owns_handle);
        previous.owns_handle = false;
        self.owns_handle = true;
    }

    pub fn deinit(self: *RuntimeCore) void {
        if (!self.owns_handle or self.handle == null) {
            self.handle = null;
            return;
        }
        check(self.interface.destroy.?(&self.handle)) catch |err| {
            std.log.err("Runtime Core destroy failed: {s}", .{@errorName(err)});
        };
        self.owns_handle = false;
    }

    pub fn prepare(
        self: *RuntimeCore,
        mode: PrepareMode,
        bounds_min: [2]f32,
        bounds_max: [2]f32,
        sources: []const SourceDesc,
    ) !CandidateInfo {
        if (sources.len == 0 or sources.len > max_object_count) return error.InvalidRuntimeSourceCount;
        var c_sources: [max_object_count]c.kadath_runtime_source_object_desc_v1_t = undefined;
        for (sources, 0..) |source, index| {
            if (source.object_id.len == 0 or source.object_id.len > 63) return error.InvalidRuntimeObjectId;
            c_sources[index] = std.mem.zeroes(c.kadath_runtime_source_object_desc_v1_t);
            c_sources[index].struct_size = @sizeOf(c.kadath_runtime_source_object_desc_v1_t);
            c_sources[index].kind = source.kind;
            c_sources[index].object_id_length = @intCast(source.object_id.len);
            @memcpy(c_sources[index].object_id[0..source.object_id.len], source.object_id);
            c_sources[index].sprite = cSprite(source.sprite);
        }
        var desc = std.mem.zeroes(c.kadath_runtime_scene_prepare_desc_t);
        desc.struct_size = @sizeOf(c.kadath_runtime_scene_prepare_desc_t);
        desc.mode = cPrepareMode(mode);
        desc.bounds_min = bounds_min;
        desc.bounds_max = bounds_max;
        desc.source_objects = &c_sources;
        desc.source_object_count = sources.len;
        desc.source_object_stride = @sizeOf(c.kadath_runtime_source_object_desc_v1_t);
        var info = std.mem.zeroes(c.kadath_runtime_scene_candidate_info_t);
        info.struct_size = @sizeOf(c.kadath_runtime_scene_candidate_info_t);
        try check(self.interface.prepare_scene.?(self.handle, &desc, &info));
        return .{
            .mode = mode,
            .world_epoch = info.world_epoch,
            .source_object_count = info.source_object_count,
        };
    }

    pub fn commitScene(self: *RuntimeCore) !void {
        try check(self.interface.commit_scene.?(self.handle));
    }

    pub fn abortScene(self: *RuntimeCore) !void {
        try check(self.interface.abort_scene.?(self.handle));
    }

    pub fn snapshot(self: *const RuntimeCore, target: Target, active_only: bool, output: []ObjectView) ![]ObjectView {
        var item = std.mem.zeroes(c.kadath_runtime_query_item_v1_t);
        item.struct_size = @sizeOf(c.kadath_runtime_query_item_v1_t);
        item.tag = if (active_only) c.KADATH_RUNTIME_QUERY_ACTIVE_OBJECTS else c.KADATH_RUNTIME_QUERY_VISIBLE_OBJECTS;
        item.payload.object_buffer = .{
            .objects = output.ptr,
            .object_capacity = output.len,
            .object_stride = @sizeOf(ObjectView),
        };
        const result = try self.queryOne(target, &item);
        if (result.payload.snapshot.object_count > output.len) return error.RuntimeCoreInvalidOutput;
        return output[0..result.payload.snapshot.object_count];
    }

    pub fn findById(self: *const RuntimeCore, target: Target, object_id: []const u8) !?ObjectView {
        var item = std.mem.zeroes(c.kadath_runtime_query_item_v1_t);
        item.struct_size = @sizeOf(c.kadath_runtime_query_item_v1_t);
        item.tag = c.KADATH_RUNTIME_QUERY_FIND_BY_ID;
        item.payload.object_id = .{ .data = object_id.ptr, .length = object_id.len };
        const result = try self.queryOne(target, &item);
        return if (result.found == c.KADATH_RUNTIME_FOUND) result.payload.object else null;
    }

    pub fn resolve(self: *const RuntimeCore, target: Target, object_ref: ObjectRef) !?ObjectView {
        var item = std.mem.zeroes(c.kadath_runtime_query_item_v1_t);
        item.struct_size = @sizeOf(c.kadath_runtime_query_item_v1_t);
        item.tag = c.KADATH_RUNTIME_QUERY_RESOLVE_EXACT_REF;
        item.payload.object_ref = object_ref;
        const result = try self.queryOne(target, &item);
        return if (result.found == c.KADATH_RUNTIME_FOUND) result.payload.object else null;
    }

    pub fn findByEntity(self: *const RuntimeCore, target: Target, entity: EntityId) !?ObjectView {
        var item = std.mem.zeroes(c.kadath_runtime_query_item_v1_t);
        item.struct_size = @sizeOf(c.kadath_runtime_query_item_v1_t);
        item.tag = c.KADATH_RUNTIME_QUERY_FIND_BY_ENTITY;
        item.payload.entity_value = entity;
        const result = try self.queryOne(target, &item);
        return if (result.found == c.KADATH_RUNTIME_FOUND) result.payload.object else null;
    }

    pub fn setBounds(self: *RuntimeCore, target: Target, min: [2]f32, max: [2]f32) !void {
        var item = std.mem.zeroes(c.kadath_runtime_mutation_item_v1_t);
        item.struct_size = @sizeOf(c.kadath_runtime_mutation_item_v1_t);
        item.tag = c.KADATH_RUNTIME_MUTATION_SET_BOUNDS;
        item.payload.bounds.struct_size = @sizeOf(c.kadath_runtime_bounds_desc_v1_t);
        item.payload.bounds.min = min;
        item.payload.bounds.max = max;
        _ = try self.mutateOne(target, &item);
    }

    pub fn stepFixed(self: *RuntimeCore, dt_seconds: f32, input: InputSnapshot) !void {
        var item = std.mem.zeroes(c.kadath_runtime_mutation_item_v1_t);
        item.struct_size = @sizeOf(c.kadath_runtime_mutation_item_v1_t);
        item.tag = c.KADATH_RUNTIME_MUTATION_STEP_FIXED;
        item.payload.fixed_step.struct_size = @sizeOf(c.kadath_runtime_fixed_step_desc_v1_t);
        item.payload.fixed_step.dt_seconds = dt_seconds;
        item.payload.fixed_step.move_x = input.move_x;
        item.payload.fixed_step.move_y = input.move_y;
        _ = try self.mutateOne(.live, &item);
    }

    pub fn applyPositions(self: *RuntimeCore, target: Target, patches: []const PositionPatch) !void {
        var c_patches: [max_object_count]c.kadath_runtime_position_patch_v1_t = undefined;
        if (patches.len == 0 or patches.len > c_patches.len) return error.InvalidRuntimePositionBatch;
        for (patches, 0..) |patch, index| {
            c_patches[index] = std.mem.zeroes(c.kadath_runtime_position_patch_v1_t);
            c_patches[index].struct_size = @sizeOf(c.kadath_runtime_position_patch_v1_t);
            c_patches[index].object_ref = patch.object_ref;
            c_patches[index].position = patch.position;
        }
        var item = std.mem.zeroes(c.kadath_runtime_mutation_item_v1_t);
        item.struct_size = @sizeOf(c.kadath_runtime_mutation_item_v1_t);
        item.tag = c.KADATH_RUNTIME_MUTATION_APPLY_POSITIONS;
        item.payload.positions = .{
            .patches = &c_patches,
            .patch_count = patches.len,
            .patch_stride = @sizeOf(c.kadath_runtime_position_patch_v1_t),
        };
        _ = try self.mutateOne(target, &item);
    }

    pub fn reserveTransient(self: *RuntimeCore, desc: TransientDesc) !ObjectView {
        var item = std.mem.zeroes(c.kadath_runtime_mutation_item_v1_t);
        item.struct_size = @sizeOf(c.kadath_runtime_mutation_item_v1_t);
        item.tag = c.KADATH_RUNTIME_MUTATION_RESERVE_TRANSIENT;
        item.payload.transient.struct_size = @sizeOf(c.kadath_runtime_transient_desc_v1_t);
        item.payload.transient.prototype_key = desc.prototype_key;
        item.payload.transient.kind = desc.kind;
        item.payload.transient.sprite = cSprite(desc.sprite);
        const result = try self.mutateOne(.live, &item);
        return result.object;
    }

    pub fn activate(self: *RuntimeCore, object_ref: ObjectRef) !void {
        _ = try self.objectMutation(c.KADATH_RUNTIME_MUTATION_ACTIVATE_TRANSIENT, object_ref);
    }

    pub fn discard(self: *RuntimeCore, object_ref: ObjectRef) !void {
        _ = try self.objectMutation(c.KADATH_RUNTIME_MUTATION_DISCARD_TRANSIENT_RESERVATION, object_ref);
    }

    pub fn requestDestroy(self: *RuntimeCore, object_ref: ObjectRef) !DestroyDisposition {
        const result = try self.objectMutation(c.KADATH_RUNTIME_MUTATION_REQUEST_TRANSIENT_DESTROY, object_ref);
        return switch (result.destroy_disposition) {
            c.KADATH_RUNTIME_DESTROY_CANCELLED_PENDING_SPAWN => .cancelled_pending_spawn,
            c.KADATH_RUNTIME_DESTROY_AWAITING_FINALIZE => .awaiting_finalize,
            else => error.RuntimeCoreInvalidOutput,
        };
    }

    pub fn finalizeDestroy(self: *RuntimeCore, object_ref: ObjectRef) !void {
        _ = try self.objectMutation(c.KADATH_RUNTIME_MUTATION_FINALIZE_TRANSIENT_DESTROY, object_ref);
    }

    pub fn commitActivation(
        self: *RuntimeCore,
        patches: []const PositionPatch,
        commands: []const ActivationCommand,
        dispositions: []?DestroyDisposition,
    ) !void {
        const item_count = @as(usize, @intFromBool(patches.len != 0)) + commands.len;
        if (item_count == 0 or item_count > max_object_count or dispositions.len < commands.len) {
            return error.InvalidRuntimeActivationBatch;
        }
        var items: [max_object_count]c.kadath_runtime_mutation_item_v1_t = undefined;
        var results: [max_object_count]c.kadath_runtime_mutation_result_t = undefined;
        var c_patches: [max_object_count]c.kadath_runtime_position_patch_v1_t = undefined;
        var item_index: usize = 0;
        if (patches.len != 0) {
            if (patches.len > c_patches.len) return error.InvalidRuntimePositionBatch;
            for (patches, 0..) |patch, index| {
                c_patches[index] = std.mem.zeroes(c.kadath_runtime_position_patch_v1_t);
                c_patches[index].struct_size = @sizeOf(c.kadath_runtime_position_patch_v1_t);
                c_patches[index].object_ref = patch.object_ref;
                c_patches[index].position = patch.position;
            }
            items[0] = std.mem.zeroes(c.kadath_runtime_mutation_item_v1_t);
            items[0].struct_size = @sizeOf(c.kadath_runtime_mutation_item_v1_t);
            items[0].tag = c.KADATH_RUNTIME_MUTATION_APPLY_POSITIONS;
            items[0].payload.positions = .{
                .patches = &c_patches,
                .patch_count = patches.len,
                .patch_stride = @sizeOf(c.kadath_runtime_position_patch_v1_t),
            };
            item_index = 1;
        }
        for (commands, 0..) |command, command_index| {
            items[item_index + command_index] = std.mem.zeroes(c.kadath_runtime_mutation_item_v1_t);
            items[item_index + command_index].struct_size = @sizeOf(c.kadath_runtime_mutation_item_v1_t);
            switch (command) {
                .activate => |object_ref| {
                    items[item_index + command_index].tag = c.KADATH_RUNTIME_MUTATION_ACTIVATE_TRANSIENT;
                    items[item_index + command_index].payload.object_ref = object_ref;
                },
                .discard_reservation => |object_ref| {
                    items[item_index + command_index].tag = c.KADATH_RUNTIME_MUTATION_DISCARD_TRANSIENT_RESERVATION;
                    items[item_index + command_index].payload.object_ref = object_ref;
                },
                .request_destroy => |object_ref| {
                    items[item_index + command_index].tag = c.KADATH_RUNTIME_MUTATION_REQUEST_TRANSIENT_DESTROY;
                    items[item_index + command_index].payload.object_ref = object_ref;
                },
            }
        }
        for (results[0..item_count]) |*result| {
            result.* = std.mem.zeroes(c.kadath_runtime_mutation_result_t);
            result.struct_size = @sizeOf(c.kadath_runtime_mutation_result_t);
        }
        var batch = std.mem.zeroes(c.kadath_runtime_mutation_batch_t);
        batch.struct_size = @sizeOf(c.kadath_runtime_mutation_batch_t);
        batch.target = c.KADATH_RUNTIME_TARGET_LIVE;
        batch.items = &items;
        batch.item_count = item_count;
        batch.item_stride = @sizeOf(c.kadath_runtime_mutation_item_v1_t);
        try check(self.interface.mutate.?(self.handle, &batch, &results, item_count));
        for (commands, 0..) |command, command_index| {
            dispositions[command_index] = switch (command) {
                .request_destroy => switch (results[item_index + command_index].destroy_disposition) {
                    c.KADATH_RUNTIME_DESTROY_CANCELLED_PENDING_SPAWN => .cancelled_pending_spawn,
                    c.KADATH_RUNTIME_DESTROY_AWAITING_FINALIZE => .awaiting_finalize,
                    else => return error.RuntimeCoreInvalidOutput,
                },
                else => null,
            };
        }
    }

    fn objectMutation(self: *RuntimeCore, tag: u32, object_ref: ObjectRef) !c.kadath_runtime_mutation_result_t {
        var item = std.mem.zeroes(c.kadath_runtime_mutation_item_v1_t);
        item.struct_size = @sizeOf(c.kadath_runtime_mutation_item_v1_t);
        item.tag = tag;
        item.payload.object_ref = object_ref;
        return self.mutateOne(.live, &item);
    }

    fn queryOne(self: *const RuntimeCore, target: Target, item: *const c.kadath_runtime_query_item_v1_t) !c.kadath_runtime_query_result_t {
        var batch = std.mem.zeroes(c.kadath_runtime_query_batch_t);
        batch.struct_size = @sizeOf(c.kadath_runtime_query_batch_t);
        batch.target = cTarget(target);
        batch.items = item;
        batch.item_count = 1;
        batch.item_stride = @sizeOf(c.kadath_runtime_query_item_v1_t);
        var result = std.mem.zeroes(c.kadath_runtime_query_result_t);
        result.struct_size = @sizeOf(c.kadath_runtime_query_result_t);
        try check(self.interface.query.?(self.handle, &batch, &result, 1));
        return result;
    }

    fn mutateOne(self: *RuntimeCore, target: Target, item: *const c.kadath_runtime_mutation_item_v1_t) !c.kadath_runtime_mutation_result_t {
        var batch = std.mem.zeroes(c.kadath_runtime_mutation_batch_t);
        batch.struct_size = @sizeOf(c.kadath_runtime_mutation_batch_t);
        batch.target = cTarget(target);
        batch.items = item;
        batch.item_count = 1;
        batch.item_stride = @sizeOf(c.kadath_runtime_mutation_item_v1_t);
        var result = std.mem.zeroes(c.kadath_runtime_mutation_result_t);
        result.struct_size = @sizeOf(c.kadath_runtime_mutation_result_t);
        try check(self.interface.mutate.?(self.handle, &batch, &result, 1));
        return result;
    }
};

fn cSprite(value: SpriteDesc) c.kadath_runtime_sprite_desc_v1_t {
    var result = std.mem.zeroes(c.kadath_runtime_sprite_desc_v1_t);
    result.struct_size = @sizeOf(c.kadath_runtime_sprite_desc_v1_t);
    result.position = value.position;
    result.size = value.size;
    result.color = value.color;
    result.texture_id = value.texture_id;
    result.move_speed = value.move_speed;
    return result;
}

fn cTarget(value: Target) u32 {
    return switch (value) {
        .live => c.KADATH_RUNTIME_TARGET_LIVE,
        .candidate => c.KADATH_RUNTIME_TARGET_CANDIDATE,
    };
}

pub fn cPrepareMode(value: PrepareMode) u32 {
    return switch (value) {
        .initial => c.KADATH_RUNTIME_PREPARE_INITIAL,
        .restart => c.KADATH_RUNTIME_PREPARE_RESTART,
        .scene_reload => c.KADATH_RUNTIME_PREPARE_SCENE_RELOAD,
    };
}

pub fn objectIdSlice(value: *const ObjectRef) []const u8 {
    return value.object_id[0..value.object_id_length];
}

pub fn sameObjectRef(a: ObjectRef, b: ObjectRef) bool {
    return a.world_epoch == b.world_epoch and
        a.logical_generation == b.logical_generation and
        a.kind == b.kind and
        std.mem.eql(u8, objectIdSlice(&a), objectIdSlice(&b));
}

fn check(result: i32) !void {
    return switch (result) {
        c.KADATH_OK => {},
        c.KADATH_ERR_INVALID_ARGUMENT => error.InvalidRuntimeCoreArgument,
        c.KADATH_ERR_OUT_OF_MEMORY => error.OutOfMemory,
        c.KADATH_ERR_BUFFER_TOO_SMALL => error.RuntimeCoreBufferTooSmall,
        c.KADATH_ERR_NOT_SUPPORTED => error.RuntimeCoreNotSupported,
        c.KADATH_ERR_INTERNAL => error.RuntimeCoreInternalFailure,
        c.KADATH_ERR_RUNTIME_WRONG_THREAD => error.RuntimeCoreWrongThread,
        c.KADATH_ERR_RUNTIME_REENTRANT => error.RuntimeCoreReentrant,
        c.KADATH_ERR_RUNTIME_INVALID_STATE => error.RuntimeCoreInvalidState,
        c.KADATH_ERR_RUNTIME_CANDIDATE_BUSY => error.RuntimeCoreCandidateBusy,
        c.KADATH_ERR_RUNTIME_STALE_OBJECT => error.StaleRuntimeObject,
        c.KADATH_ERR_RUNTIME_SOURCE_DESTROY_REJECTED => error.SourceRuntimeObjectDestroyRejected,
        c.KADATH_ERR_RUNTIME_OBJECT_CAPACITY => error.RuntimeObjectCapacityExceeded,
        c.KADATH_ERR_RUNTIME_INVALID_LIFECYCLE => error.InvalidRuntimeObjectLifecycle,
        c.KADATH_ERR_RUNTIME_TRANSIENT_ID_EXHAUSTED => error.TransientObjectIdExhausted,
        c.KADATH_ERR_RUNTIME_EPOCH_EXHAUSTED => error.RuntimeEpochExhausted,
        c.KADATH_ERR_RUNTIME_DUPLICATE_OBJECT_ID => error.DuplicateRuntimeObjectId,
        else => error.RuntimeCoreCallFailed,
    };
}
