const std = @import("std");
const content_identity = @import("content_identity.zig");
const scene_api = @import("scene.zig");
const scene_generation_api = @import("scene_generation.zig");

pub const InputSnapshot = struct {
    move_x: i32 = 0,
    move_y: i32 = 0,
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
    pub fn deinit(self: *Runtime) void {
        self.* = .{};
    }

    pub fn isLoaded(_: *const Runtime) bool {
        return false;
    }

    pub fn cloneForRestart(_: *const Runtime, _: std.mem.Allocator, _: *const scene_api.Scene) !Runtime {
        return error.UnsupportedBehaviorRuntime;
    }

    pub fn cloneForSceneReload(_: *const Runtime, _: std.mem.Allocator, _: *const scene_api.Scene) !Runtime {
        return error.UnsupportedBehaviorRuntime;
    }

    pub fn worldEpoch(_: *const Runtime) u64 {
        return 1;
    }

    pub fn onStart(_: *Runtime, _: *const scene_generation_api.SceneGeneration) !TranslationBatch {
        return error.UnsupportedBehaviorRuntime;
    }

    pub fn runFixed(_: *Runtime, _: *scene_generation_api.SceneGeneration, _: f32, _: InputSnapshot) !void {
        return error.UnsupportedBehaviorRuntime;
    }

    pub fn runUpdate(_: *Runtime, _: *scene_generation_api.SceneGeneration, _: f32, _: InputSnapshot) !void {
        return error.UnsupportedBehaviorRuntime;
    }

    pub fn finishFixedStep(_: *Runtime, _: *scene_generation_api.SceneGeneration, _: []const bool, _: InputSnapshot) !void {
        return error.UnsupportedBehaviorRuntime;
    }

    pub fn finishFrame(_: *Runtime, _: *scene_generation_api.SceneGeneration, _: InputSnapshot) !void {
        return error.UnsupportedBehaviorRuntime;
    }
};

pub fn loadWithIdentity(_: std.Io, _: std.mem.Allocator, _: []const u8, _: *const scene_api.Scene) !LoadedRuntime {
    return error.UnsupportedBehaviorRuntime;
}

pub fn loadWithIdentityAtEpoch(_: std.Io, _: std.mem.Allocator, _: []const u8, _: *const scene_api.Scene, _: u64) !LoadedRuntime {
    return error.UnsupportedBehaviorRuntime;
}
