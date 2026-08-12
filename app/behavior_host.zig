const std = @import("std");
const artifact = @import("behavior_artifact");
const behavior_runtime = @import("behavior_runtime");
const content_identity = @import("content_identity.zig");
const scene_adapter = @import("behavior_scene_adapter.zig");
const scene_api = @import("scene.zig");

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
    package: ?behavior_runtime.Package = null,
    active: ?behavior_runtime.ActiveSet = null,

    pub fn deinit(self: *Runtime) void {
        if (self.active) |*active| active.deinit();
        if (self.package) |*package| package.deinit();
        self.* = .{};
    }

    pub fn isLoaded(self: *const Runtime) bool {
        return self.package != null and self.active != null;
    }

    pub fn cloneForScene(self: *const Runtime, allocator: std.mem.Allocator, scene: *const scene_api.Scene) !Runtime {
        const package = self.package orelse return error.BehaviorRuntimeNotLoaded;
        return initArtifact(allocator, package.bytes, scene);
    }

    pub fn onStart(self: *Runtime, scene: *const scene_api.Scene) !TranslationBatch {
        const active = if (self.active) |*value| value else return error.BehaviorRuntimeNotLoaded;
        var positions: [scene_api.max_scene_object_count][2]f32 = undefined;
        for (scene.objects.slice(), 0..) |object, index| positions[index] = object.sprite.position;
        return aggregateCommands(active, scene, positions[0..scene.objects.count], active.onStartCommands(), true);
    }

    pub fn runFixed(
        self: *Runtime,
        scene: *const scene_api.Scene,
        positions: []const [2]f32,
        dt_seconds: f32,
    ) !TranslationBatch {
        if (positions.len != scene.objects.count) return error.InvalidBehaviorSnapshotBatch;
        const active = if (self.active) |*value| value else return error.BehaviorRuntimeNotLoaded;
        var snapshots: [scene_api.max_scene_object_count]behavior_runtime.ObjectSnapshot = undefined;
        for (scene.objects.slice(), positions, 0..) |*object, position, index| {
            snapshots[index] = .{ .object_id = object.objectId.slice(), .position = position };
        }
        try active.runFixed(dt_seconds, snapshots[0..scene.objects.count]);
        const batch = try aggregateCommands(active, scene, positions, active.commandSlice(), false);
        logFailures(active);
        return batch;
    }
};

pub fn loadWithIdentity(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    scene: *const scene_api.Scene,
) !LoadedRuntime {
    const contents = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(artifact.max_artifact_bytes));
    defer allocator.free(contents);
    return .{
        .value = try initArtifact(allocator, contents, scene),
        .identity = try content_identity.ContentIdentity.fromBytes(.artifact, contents),
        .artifact_version = artifact.artifact_version,
    };
}

pub fn initArtifact(allocator: std.mem.Allocator, bytes: []const u8, scene: *const scene_api.Scene) !Runtime {
    if (scene.schemaVersion != scene_api.current_schema_version) return error.UnsupportedBehaviorSceneSchema;
    var diagnostic = behavior_runtime.Diagnostic{};
    var package = behavior_runtime.Package.init(
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
    var prepared = normalized.prepare(&package, &diagnostic) catch |err| {
        logDiagnostic("Behavior binding preparation failed", err, diagnostic.slice());
        return err;
    };
    return .{ .package = package, .active = prepared.activate() };
}

fn aggregateCommands(
    active: *behavior_runtime.ActiveSet,
    scene: *const scene_api.Scene,
    positions: []const [2]f32,
    commands: []const behavior_runtime.CommandIntent,
    strict: bool,
) !TranslationBatch {
    var batch = TranslationBatch{ .object_count = scene.objects.count };
    if (commands.len == 0) return batch;

    var command_index: usize = 0;
    while (command_index < commands.len) {
        const binding_index = commands[command_index].binding_index;
        var binding_delta = [2]f64{ 0, 0 };
        while (command_index < commands.len and commands[command_index].binding_index == binding_index) : (command_index += 1) {
            binding_delta[0] += commands[command_index].dx;
            binding_delta[1] += commands[command_index].dy;
        }
        const object_index = findObjectIndex(scene, active.bindingObjectId(binding_index)) orelse {
            if (strict) return error.MissingBehaviorObjectSnapshot;
            active.disableBinding(binding_index, error.MissingBehaviorObjectSnapshot, "");
            continue;
        };
        const target_x = @as(f64, positions[object_index][0]) + batch.deltas[object_index][0] + binding_delta[0];
        const target_y = @as(f64, positions[object_index][1]) + batch.deltas[object_index][1] + binding_delta[1];
        if (!validTranslation(binding_delta, target_x, target_y)) {
            if (strict) return error.InvalidBehaviorTranslation;
            active.disableBinding(binding_index, error.InvalidBehaviorTranslation, "");
            continue;
        }
        batch.deltas[object_index][0] += binding_delta[0];
        batch.deltas[object_index][1] += binding_delta[1];
    }
    return batch;
}

fn validTranslation(delta: [2]f64, target_x: f64, target_y: f64) bool {
    return std.math.isFinite(delta[0]) and
        std.math.isFinite(delta[1]) and
        std.math.isFinite(target_x) and
        std.math.isFinite(target_y) and
        @abs(target_x) <= std.math.floatMax(f32) and
        @abs(target_y) <= std.math.floatMax(f32);
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
        std.log.err("Behavior binding disabled: binding={d}, object={s}, script_id={d}, error={s}, diagnostic={s}", .{
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
