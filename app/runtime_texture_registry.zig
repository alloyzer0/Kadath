const std = @import("std");
const renderer2d = @import("renderer2d");
const resource = @import("resource");
const rhi = @import("rhi");
const scene = @import("scene.zig");
const world = @import("world");

pub const resource_async_integration = true;
const max_texture_count = scene.max_texture_count;

pub const TextureRefreshFailureStage = enum { submit, read, decode, upload, internal };
pub const TextureRefreshFailureReason = union(enum) { resource: resource.AsyncTextureFailureReason, runtime: anyerror };
pub const TextureRefreshOutcome = union(enum) {
    applied,
    failed: struct {
        texture_id: world.TextureId,
        artifact_key: []const u8,
        stage: TextureRefreshFailureStage,
        reason: TextureRefreshFailureReason,
    },
};

pub const PreparedTextureSet = struct {
    allocator: std.mem.Allocator,
    specs: [max_texture_count]scene.TextureSpec = [_]scene.TextureSpec{.{}} ** max_texture_count,
    textures: [max_texture_count]?resource.TextureData = [_]?resource.TextureData{null} ** max_texture_count,
    count: u8 = 0,
    deinitialized: bool = false,

    pub fn deinit(self: *PreparedTextureSet) void {
        if (self.deinitialized) return;
        for (self.textures[0..self.count]) |*slot| {
            if (slot.*) |*texture| texture.deinit(self.allocator);
            slot.* = null;
        }
        self.deinitialized = true;
    }
};

pub fn prepareScene(io: std.Io, allocator: std.mem.Allocator, value: *const scene.Scene) !PreparedTextureSet {
    var prepared = PreparedTextureSet{ .allocator = allocator, .count = value.textures.count };
    errdefer prepared.deinit();
    for (value.textures.slice(), 0..) |spec, ordinal| {
        prepared.specs[ordinal] = spec;
        prepared.textures[ordinal] = try resource.loadTextureArtifact(io, allocator, spec.artifact());
    }
    return prepared;
}

const RefreshSlot = union(enum) { pending, loaded: resource.TextureData, failed: resource.AsyncTextureFailure, taken };

const RefreshState = struct {
    allocator: std.mem.Allocator,
    count: u8,
    loaders: [max_texture_count]?resource.AsyncTextureLoader = [_]?resource.AsyncTextureLoader{null} ** max_texture_count,
    slots: [max_texture_count]RefreshSlot = [_]RefreshSlot{.pending} ** max_texture_count,
    delivered: bool = false,

    fn init(allocator: std.mem.Allocator, specs: []const scene.TextureSpec) RefreshState {
        var self = RefreshState{ .allocator = allocator, .count = @intCast(specs.len) };
        for (specs, 0..) |spec, ordinal| {
            self.loaders[ordinal] = resource.AsyncTextureLoader.init(allocator);
            self.loaders[ordinal].?.request(spec.artifact()) catch unreachable;
        }
        return self;
    }

    fn deinit(self: *RefreshState) void {
        for (self.loaders[0..self.count]) |*slot| {
            if (slot.*) |*loader| loader.deinit();
            slot.* = null;
        }
        for (self.slots[0..self.count]) |*slot| {
            switch (slot.*) {
                .loaded => |*texture| texture.deinit(self.allocator),
                else => {},
            }
            slot.* = .taken;
        }
        self.delivered = true;
    }
};

pub const RuntimeTextureRegistry = struct {
    allocator: std.mem.Allocator,
    specs: [max_texture_count]scene.TextureSpec = [_]scene.TextureSpec{.{}} ** max_texture_count,
    handles: [max_texture_count]rhi.TextureHandle = [_]rhi.TextureHandle{rhi.invalid_texture} ** max_texture_count,
    count: u8 = 0,
    refresh: ?RefreshState = null,
    deinitialized: bool = false,

    pub fn initPrepared(allocator: std.mem.Allocator, renderer: *renderer2d.Renderer2D, backend: *rhi.Rhi, prepared: *const PreparedTextureSet) !RuntimeTextureRegistry {
        var registry = try initPreparedWithoutRefresh(allocator, renderer, backend, prepared);
        registry.refresh = RefreshState.init(allocator, registry.specs[0..registry.count]);
        return registry;
    }

    pub fn resolve(self: *const RuntimeTextureRegistry, texture_id: world.TextureId) error{UnknownWorldTexture}!rhi.TextureHandle {
        std.debug.assert(!self.deinitialized);
        for (self.specs[0..self.count], self.handles[0..self.count]) |spec, handle| {
            if (spec.textureId == texture_id) return handle;
        }
        return error.UnknownWorldTexture;
    }

    pub fn take(self: *RuntimeTextureRegistry) RuntimeTextureRegistry {
        std.debug.assert(!self.deinitialized);
        const moved = self.*;
        self.* = .{ .allocator = self.allocator, .deinitialized = true };
        return moved;
    }

    pub fn pollRefresh(self: *RuntimeTextureRegistry, renderer: *renderer2d.Renderer2D, backend: *rhi.Rhi) ?TextureRefreshOutcome {
        std.debug.assert(!self.deinitialized);
        const refresh = if (self.refresh) |*value| value else return null;
        if (refresh.delivered) return null;
        for (refresh.loaders[0..refresh.count], 0..) |*loader_slot, ordinal| {
            if (std.meta.activeTag(refresh.slots[ordinal]) != .pending) continue;
            const loader = if (loader_slot.*) |*value| value else continue;
            refresh.slots[ordinal] = switch (loader.poll() orelse continue) {
                .loaded => |texture| .{ .loaded = texture },
                .failed => |failure| .{ .failed = failure },
            };
        }
        for (refresh.slots[0..refresh.count]) |slot| if (std.meta.activeTag(slot) == .pending) return null;
        for (refresh.slots[0..refresh.count], 0..) |slot, ordinal| switch (slot) {
            .failed => |failure| {
                const spec = self.specs[ordinal];
                refresh.deinit();
                return .{ .failed = .{ .texture_id = spec.textureId, .artifact_key = spec.artifact(), .stage = mapResourceStage(failure.stage), .reason = .{ .resource = failure.reason } } };
            },
            else => {},
        };
        var refs: [max_texture_count]*const resource.TextureData = undefined;
        for (refresh.slots[0..refresh.count], 0..) |*slot, ordinal| refs[ordinal] = switch (slot.*) {
            .loaded => |*texture| texture,
            else => unreachable,
        };
        const uploaded = uploadTextureSet(self.allocator, renderer, backend, self.specs[0..self.count], refs[0..self.count]);
        return switch (uploaded) {
            .failed => |failure| blk: {
                const spec = self.specs[failure.ordinal];
                refresh.deinit();
                break :blk .{ .failed = .{ .texture_id = spec.textureId, .artifact_key = spec.artifact(), .stage = .upload, .reason = .{ .runtime = failure.err } } };
            },
            .loaded => |candidate| blk: {
                const previous = self.handles;
                self.handles = candidate;
                for (previous[0..self.count]) |handle| backend.destroyTexture(handle);
                refresh.deinit();
                break :blk .applied;
            },
        };
    }

    pub fn deinit(self: *RuntimeTextureRegistry, backend: *rhi.Rhi) void {
        if (self.deinitialized) return;
        if (self.refresh) |*refresh| refresh.deinit();
        for (self.handles[0..self.count]) |*handle| {
            backend.destroyTexture(handle.*);
            handle.* = rhi.invalid_texture;
        }
        self.refresh = null;
        self.deinitialized = true;
    }
};

const UploadResult = union(enum) { loaded: [max_texture_count]rhi.TextureHandle, failed: struct { ordinal: usize, err: anyerror } };

fn uploadTexture(allocator: std.mem.Allocator, renderer: *renderer2d.Renderer2D, backend: *rhi.Rhi, texture: *const resource.TextureData) !rhi.TextureHandle {
    const upload_mips = try allocator.alloc(rhi.TextureMipUpload, texture.mip_levels.len);
    defer allocator.free(upload_mips);
    for (texture.mip_levels, 0..) |level, index| upload_mips[index] = .{ .width = level.width, .height = level.height, .rgba8 = level.pixels_rgba8 };
    return renderer.createTexture(backend, .{ .width = texture.width, .height = texture.height, .rgba8 = texture.pixels_rgba8, .mip_levels = upload_mips }, .smooth_mipmap_anisotropic);
}

fn uploadTextureSet(allocator: std.mem.Allocator, renderer: *renderer2d.Renderer2D, backend: *rhi.Rhi, specs: []const scene.TextureSpec, textures: []const *const resource.TextureData) UploadResult {
    var handles = [_]rhi.TextureHandle{rhi.invalid_texture} ** max_texture_count;
    for (specs, textures, 0..) |_, texture, ordinal| {
        handles[ordinal] = uploadTexture(allocator, renderer, backend, texture) catch |err| {
            for (handles[0..ordinal]) |handle| backend.destroyTexture(handle);
            return .{ .failed = .{ .ordinal = ordinal, .err = err } };
        };
    }
    return .{ .loaded = handles };
}

fn initPreparedWithoutRefresh(allocator: std.mem.Allocator, renderer: *renderer2d.Renderer2D, backend: *rhi.Rhi, prepared: *const PreparedTextureSet) !RuntimeTextureRegistry {
    std.debug.assert(!prepared.deinitialized);
    var refs: [max_texture_count]*const resource.TextureData = undefined;
    for (prepared.textures[0..prepared.count], 0..) |*slot, ordinal| refs[ordinal] = if (slot.*) |*texture| texture else unreachable;
    return switch (uploadTextureSet(allocator, renderer, backend, prepared.specs[0..prepared.count], refs[0..prepared.count])) {
        .loaded => |handles| .{ .allocator = allocator, .specs = prepared.specs, .handles = handles, .count = prepared.count },
        .failed => |failure| failure.err,
    };
}

fn mapResourceStage(stage: resource.AsyncTextureFailureStage) TextureRefreshFailureStage {
    return switch (stage) {
        .submit => .submit,
        .read => .read,
        .decode => .decode,
    };
}

fn testTextureData(allocator: std.mem.Allocator, rgba: [4]u8) !resource.TextureData {
    return .{ .width = 1, .height = 1, .pixels_rgba8 = try allocator.dupe(u8, &rgba) };
}

test "three scene textures publish and resolve" {
    var backend = try rhi.Rhi.init(.{ .width = 64, .height = 64 });
    defer backend.deinit();
    const shader = [_]u8{ 0, 0, 0, 0 };
    const pipeline = try backend.createGraphicsPipeline(.{ .vertex_shader = &shader, .fragment_shader = &shader, .push_constant_size = 32, .uses_texture = true });
    var renderer = renderer2d.Renderer2D{ .pipeline = pipeline };
    defer renderer.deinit(&backend);
    var prepared = PreparedTextureSet{ .allocator = std.testing.allocator, .specs = scene.default_scene.textures.entries, .count = 3 };
    for (prepared.textures[0..3], 0..) |*slot, index| slot.* = try testTextureData(std.testing.allocator, .{ @intCast(index + 1), 0, 0, 255 });
    defer prepared.deinit();
    var registry = try initPreparedWithoutRefresh(std.testing.allocator, &renderer, &backend, &prepared);
    defer registry.deinit(&backend);
    try std.testing.expect((try registry.resolve(1)) != (try registry.resolve(2)));
    try std.testing.expect((try registry.resolve(3)) != rhi.invalid_texture);
    try std.testing.expectError(error.UnknownWorldTexture, registry.resolve(4));
}

test "initial upload failure rolls back every candidate handle" {
    var backend = try rhi.Rhi.init(.{ .width = 64, .height = 64 });
    defer backend.deinit();
    const shader = [_]u8{ 0, 0, 0, 0 };
    const pipeline = try backend.createGraphicsPipeline(.{ .vertex_shader = &shader, .fragment_shader = &shader, .push_constant_size = 32, .uses_texture = true });
    var renderer = renderer2d.Renderer2D{ .pipeline = pipeline };
    defer renderer.deinit(&backend);
    const pixels = [_]u8{ 255, 255, 255, 255 };
    var blockers: [6]rhi.TextureHandle = undefined;
    for (&blockers) |*handle| handle.* = try backend.createTexture(.{ .width = 1, .height = 1, .rgba8 = &pixels });
    defer for (blockers) |handle| backend.destroyTexture(handle);
    var prepared = PreparedTextureSet{ .allocator = std.testing.allocator, .specs = scene.default_scene.textures.entries, .count = 3 };
    for (prepared.textures[0..3]) |*slot| slot.* = try testTextureData(std.testing.allocator, .{ 1, 2, 3, 255 });
    defer prepared.deinit();
    try std.testing.expectError(error.TextureLimitReached, initPreparedWithoutRefresh(std.testing.allocator, &renderer, &backend, &prepared));
    try std.testing.expectEqual(@as(u32, 6), backend.stats().textures_live);
}

test "three texture refresh swaps only after the full set succeeds" {
    var backend = try rhi.Rhi.init(.{ .width = 64, .height = 64 });
    defer backend.deinit();
    const shader = [_]u8{ 0, 0, 0, 0 };
    const pipeline = try backend.createGraphicsPipeline(.{ .vertex_shader = &shader, .fragment_shader = &shader, .push_constant_size = 32, .uses_texture = true });
    var renderer = renderer2d.Renderer2D{ .pipeline = pipeline };
    defer renderer.deinit(&backend);
    var prepared = PreparedTextureSet{ .allocator = std.testing.allocator, .specs = scene.default_scene.textures.entries, .count = 3 };
    for (prepared.textures[0..3]) |*slot| slot.* = try testTextureData(std.testing.allocator, .{ 1, 2, 3, 255 });
    defer prepared.deinit();
    var registry = try initPreparedWithoutRefresh(std.testing.allocator, &renderer, &backend, &prepared);
    defer registry.deinit(&backend);
    const old = registry.handles;
    registry.refresh = RefreshState{ .allocator = std.testing.allocator, .count = 3 };
    for (registry.refresh.?.slots[0..3], 0..) |*slot, index| slot.* = .{ .loaded = try testTextureData(std.testing.allocator, .{ @intCast(index + 4), 5, 6, 255 }) };
    try std.testing.expectEqual(.applied, registry.pollRefresh(&renderer, &backend).?);
    for (registry.handles[0..3], old[0..3]) |current, previous| try std.testing.expect(current != previous);
    try std.testing.expectEqual(@as(u32, 3), backend.stats().textures_live);
}

test "refresh resource failure preserves the active set" {
    var backend = try rhi.Rhi.init(.{ .width = 64, .height = 64 });
    defer backend.deinit();
    const shader = [_]u8{ 0, 0, 0, 0 };
    const pipeline = try backend.createGraphicsPipeline(.{ .vertex_shader = &shader, .fragment_shader = &shader, .push_constant_size = 32, .uses_texture = true });
    var renderer = renderer2d.Renderer2D{ .pipeline = pipeline };
    defer renderer.deinit(&backend);
    var prepared = PreparedTextureSet{ .allocator = std.testing.allocator, .specs = scene.default_scene.textures.entries, .count = 3 };
    for (prepared.textures[0..3]) |*slot| slot.* = try testTextureData(std.testing.allocator, .{ 1, 2, 3, 255 });
    defer prepared.deinit();
    var registry = try initPreparedWithoutRefresh(std.testing.allocator, &renderer, &backend, &prepared);
    defer registry.deinit(&backend);
    const old = registry.handles;
    registry.refresh = RefreshState{ .allocator = std.testing.allocator, .count = 3 };
    registry.refresh.?.slots[0] = .{ .loaded = try testTextureData(std.testing.allocator, .{ 4, 5, 6, 255 }) };
    registry.refresh.?.slots[1] = .{ .failed = .{ .stage = .read, .reason = .not_found } };
    registry.refresh.?.slots[2] = .{ .loaded = try testTextureData(std.testing.allocator, .{ 7, 8, 9, 255 }) };
    const outcome = registry.pollRefresh(&renderer, &backend).?;
    switch (outcome) {
        .applied => return error.ExpectedRefreshFailure,
        .failed => |failure| try std.testing.expectEqual(@as(world.TextureId, 2), failure.texture_id),
    }
    try std.testing.expectEqualSlices(rhi.TextureHandle, old[0..3], registry.handles[0..3]);
    try std.testing.expectEqual(@as(u32, 3), backend.stats().textures_live);
}
