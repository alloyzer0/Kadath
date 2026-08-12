const std = @import("std");
const content_identity = @import("content_identity.zig");
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
    pub fn deinit(self: *Runtime) void {
        self.* = .{};
    }

    pub fn isLoaded(_: *const Runtime) bool {
        return false;
    }

    pub fn cloneForScene(_: *const Runtime, _: std.mem.Allocator, _: *const scene_api.Scene) !Runtime {
        return error.UnsupportedBehaviorRuntime;
    }

    pub fn onStart(_: *Runtime, _: *const scene_api.Scene) !TranslationBatch {
        return error.UnsupportedBehaviorRuntime;
    }

    pub fn runFixed(_: *Runtime, _: *const scene_api.Scene, _: []const [2]f32, _: f32) !TranslationBatch {
        return error.UnsupportedBehaviorRuntime;
    }
};

pub fn loadWithIdentity(_: std.Io, _: std.mem.Allocator, _: []const u8, _: *const scene_api.Scene) !LoadedRuntime {
    return error.UnsupportedBehaviorRuntime;
}
