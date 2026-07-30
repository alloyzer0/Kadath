const std = @import("std");
const renderer2d = @import("renderer2d");
const resource = @import("resource");
const rhi = @import("rhi");
const world = @import("world");

pub const resource_async_integration = true;

const texture_count = 2;
pub const primary_texture_id: world.TextureId = 1;
pub const secondary_texture_id: world.TextureId = 2;

const TextureSpec = struct {
    texture_id: world.TextureId,
    artifact_key: []const u8,
    sampler: renderer2d.TextureSamplingProfile,
};

const default_texture_specs = [texture_count]TextureSpec{
    .{
        .texture_id = primary_texture_id,
        .artifact_key = "assets/renderer2d/test.texture",
        .sampler = .smooth_mipmap_anisotropic,
    },
    .{
        .texture_id = secondary_texture_id,
        .artifact_key = "assets/renderer2d/goal.texture",
        .sampler = .smooth_mipmap_anisotropic,
    },
};

pub const TextureRefreshFailureStage = enum {
    submit,
    read,
    decode,
    upload,
    internal,
};

pub const TextureRefreshFailureReason = union(enum) {
    resource: resource.AsyncTextureFailureReason,
    runtime: anyerror,
};

pub const TextureRefreshOutcome = union(enum) {
    applied,
    failed: struct {
        texture_id: world.TextureId,
        artifact_key: []const u8,
        stage: TextureRefreshFailureStage,
        reason: TextureRefreshFailureReason,
    },
};

const RefreshSlot = union(enum) {
    pending,
    loaded: resource.TextureData,
    failed: resource.AsyncTextureFailure,
    taken,
};

const CompletedRefresh = union(enum) {
    loaded: [texture_count]resource.TextureData,
    failed: struct {
        ordinal: usize,
        failure: resource.AsyncTextureFailure,
    },
};

const RefreshAccumulator = struct {
    allocator: std.mem.Allocator,
    slots: [texture_count]RefreshSlot = [_]RefreshSlot{.pending} ** texture_count,
    delivered: bool = false,

    fn init(allocator: std.mem.Allocator) RefreshAccumulator {
        return .{ .allocator = allocator };
    }

    fn feed(self: *RefreshAccumulator, ordinal: usize, result: resource.AsyncTextureResult) !void {
        if (ordinal >= texture_count) return error.InvalidRefreshOrdinal;
        if (std.meta.activeTag(self.slots[ordinal]) != .pending) return error.DuplicateRefreshOrdinal;
        self.slots[ordinal] = switch (result) {
            .loaded => |texture| .{ .loaded = texture },
            .failed => |failure| .{ .failed = failure },
        };
    }

    fn takeCompleted(self: *RefreshAccumulator) ?CompletedRefresh {
        if (self.delivered) return null;
        for (self.slots) |slot| {
            if (std.meta.activeTag(slot) == .pending) return null;
        }

        for (self.slots, 0..) |slot, ordinal| {
            switch (slot) {
                .failed => |failure| {
                    for (&self.slots) |*owned_slot| {
                        switch (owned_slot.*) {
                            .loaded => |*texture| texture.deinit(self.allocator),
                            else => {},
                        }
                        owned_slot.* = .taken;
                    }
                    self.delivered = true;
                    return .{ .failed = .{ .ordinal = ordinal, .failure = failure } };
                },
                else => {},
            }
        }

        var textures: [texture_count]resource.TextureData = undefined;
        for (&self.slots, 0..) |*slot, ordinal| {
            textures[ordinal] = switch (slot.*) {
                .loaded => |texture| texture,
                else => unreachable,
            };
            slot.* = .taken;
        }
        self.delivered = true;
        return .{ .loaded = textures };
    }

    fn deinit(self: *RefreshAccumulator) void {
        for (&self.slots) |*slot| {
            switch (slot.*) {
                .loaded => |*texture| texture.deinit(self.allocator),
                else => {},
            }
            slot.* = .taken;
        }
        self.delivered = true;
    }
};

pub const PreparedTextureSet = struct {
    allocator: std.mem.Allocator,
    textures: [texture_count]?resource.TextureData,
    deinitialized: bool = false,

    pub fn deinit(self: *PreparedTextureSet) void {
        if (self.deinitialized) return;
        for (&self.textures) |*slot| {
            if (slot.*) |*texture| texture.deinit(self.allocator);
            slot.* = null;
        }
        self.deinitialized = true;
    }
};

pub fn prepareDefault(io: std.Io, allocator: std.mem.Allocator) !PreparedTextureSet {
    var prepared = PreparedTextureSet{
        .allocator = allocator,
        .textures = [_]?resource.TextureData{null} ** texture_count,
    };
    errdefer prepared.deinit();
    for (default_texture_specs, 0..) |spec, ordinal| {
        prepared.textures[ordinal] = try resource.loadTextureArtifact(io, allocator, spec.artifact_key);
    }
    return prepared;
}

const RefreshState = struct {
    loaders: [texture_count]?resource.AsyncTextureLoader = [_]?resource.AsyncTextureLoader{null} ** texture_count,
    accumulator: RefreshAccumulator,

    fn init(allocator: std.mem.Allocator) RefreshState {
        var self = RefreshState{ .accumulator = RefreshAccumulator.init(allocator) };
        for (default_texture_specs, 0..) |spec, ordinal| {
            self.loaders[ordinal] = resource.AsyncTextureLoader.init(allocator);
            self.loaders[ordinal].?.request(spec.artifact_key) catch unreachable;
        }
        return self;
    }

    fn deinit(self: *RefreshState) void {
        for (&self.loaders) |*slot| {
            if (slot.*) |*loader| loader.deinit();
            slot.* = null;
        }
        self.accumulator.deinit();
    }
};

pub const RuntimeTextureRegistry = struct {
    allocator: std.mem.Allocator,
    handles: [texture_count]rhi.TextureHandle,
    refresh: ?RefreshState = null,
    deinitialized: bool = false,

    pub fn initPrepared(
        allocator: std.mem.Allocator,
        renderer: *renderer2d.Renderer2D,
        backend: *rhi.Rhi,
        prepared: *const PreparedTextureSet,
    ) !RuntimeTextureRegistry {
        var registry = try initPreparedWithoutRefresh(allocator, renderer, backend, prepared);
        registry.refresh = RefreshState.init(allocator);
        return registry;
    }

    pub fn resolve(self: *const RuntimeTextureRegistry, texture_id: world.TextureId) error{UnknownWorldTexture}!rhi.TextureHandle {
        std.debug.assert(!self.deinitialized);
        for (default_texture_specs, self.handles) |spec, handle| {
            if (spec.texture_id == texture_id) return handle;
        }
        return error.UnknownWorldTexture;
    }

    pub fn take(self: *RuntimeTextureRegistry) RuntimeTextureRegistry {
        std.debug.assert(!self.deinitialized);
        const moved = self.*;
        self.handles = [_]rhi.TextureHandle{rhi.invalid_texture} ** texture_count;
        self.refresh = null;
        self.deinitialized = true;
        return moved;
    }

    pub fn pollRefresh(
        self: *RuntimeTextureRegistry,
        renderer: *renderer2d.Renderer2D,
        backend: *rhi.Rhi,
    ) ?TextureRefreshOutcome {
        std.debug.assert(!self.deinitialized);
        const refresh = if (self.refresh) |*value| value else return null;

        for (&refresh.loaders, 0..) |*loader_slot, ordinal| {
            const loader = if (loader_slot.*) |*value| value else continue;
            var result = loader.poll() orelse continue;
            refresh.accumulator.feed(ordinal, result) catch |err| {
                deinitAsyncResult(self.allocator, &result);
                const spec = default_texture_specs[ordinal];
                refresh.deinit();
                return .{ .failed = .{
                    .texture_id = spec.texture_id,
                    .artifact_key = spec.artifact_key,
                    .stage = .internal,
                    .reason = .{ .runtime = err },
                } };
            };
        }

        const completed = refresh.accumulator.takeCompleted() orelse return null;
        return switch (completed) {
            .failed => |failed| blk: {
                const spec = default_texture_specs[failed.ordinal];
                break :blk .{ .failed = .{
                    .texture_id = spec.texture_id,
                    .artifact_key = spec.artifact_key,
                    .stage = mapResourceStage(failed.failure.stage),
                    .reason = .{ .resource = failed.failure.reason },
                } };
            },
            .loaded => |loaded| blk: {
                var textures = loaded;
                defer for (&textures) |*texture| texture.deinit(self.allocator);
                var texture_refs: [texture_count]*const resource.TextureData = undefined;
                for (&textures, 0..) |*texture, ordinal| texture_refs[ordinal] = texture;
                switch (uploadTextureSet(self.allocator, renderer, backend, texture_refs)) {
                    .failed => |failure| {
                        const spec = default_texture_specs[failure.ordinal];
                        break :blk .{ .failed = .{
                            .texture_id = spec.texture_id,
                            .artifact_key = spec.artifact_key,
                            .stage = .upload,
                            .reason = .{ .runtime = failure.err },
                        } };
                    },
                    .loaded => |candidate_handles| {
                        const previous_handles = self.handles;
                        self.handles = candidate_handles;
                        for (previous_handles) |handle| backend.destroyTexture(handle);
                        break :blk .applied;
                    },
                }
            },
        };
    }

    pub fn deinit(self: *RuntimeTextureRegistry, backend: *rhi.Rhi) void {
        if (self.deinitialized) return;
        if (self.refresh) |*refresh| refresh.deinit();
        self.refresh = null;
        for (&self.handles) |*handle| {
            backend.destroyTexture(handle.*);
            handle.* = rhi.invalid_texture;
        }
        self.deinitialized = true;
    }
};

const UploadTextureSetResult = union(enum) {
    loaded: [texture_count]rhi.TextureHandle,
    failed: struct {
        ordinal: usize,
        err: anyerror,
    },
};

fn uploadTexture(
    allocator: std.mem.Allocator,
    renderer: *renderer2d.Renderer2D,
    backend: *rhi.Rhi,
    texture: *const resource.TextureData,
    sampler: renderer2d.TextureSamplingProfile,
) !rhi.TextureHandle {
    const upload_mips = try allocator.alloc(rhi.TextureMipUpload, texture.mip_levels.len);
    defer allocator.free(upload_mips);
    for (texture.mip_levels, 0..) |level, index| {
        upload_mips[index] = .{
            .width = level.width,
            .height = level.height,
            .rgba8 = level.pixels_rgba8,
        };
    }
    return renderer.createTexture(backend, .{
        .width = texture.width,
        .height = texture.height,
        .rgba8 = texture.pixels_rgba8,
        .mip_levels = upload_mips,
    }, sampler);
}

fn uploadTextureSet(
    allocator: std.mem.Allocator,
    renderer: *renderer2d.Renderer2D,
    backend: *rhi.Rhi,
    textures: [texture_count]*const resource.TextureData,
) UploadTextureSetResult {
    var handles = [_]rhi.TextureHandle{rhi.invalid_texture} ** texture_count;
    for (default_texture_specs, textures, 0..) |spec, texture, ordinal| {
        handles[ordinal] = uploadTexture(allocator, renderer, backend, texture, spec.sampler) catch |err| {
            for (handles[0..ordinal]) |handle| backend.destroyTexture(handle);
            return .{ .failed = .{ .ordinal = ordinal, .err = err } };
        };
    }
    return .{ .loaded = handles };
}

fn initPreparedWithoutRefresh(
    allocator: std.mem.Allocator,
    renderer: *renderer2d.Renderer2D,
    backend: *rhi.Rhi,
    prepared: *const PreparedTextureSet,
) !RuntimeTextureRegistry {
    std.debug.assert(!prepared.deinitialized);
    var texture_refs: [texture_count]*const resource.TextureData = undefined;
    for (&prepared.textures, 0..) |*slot, ordinal| {
        texture_refs[ordinal] = if (slot.*) |*texture| texture else unreachable;
    }
    return switch (uploadTextureSet(allocator, renderer, backend, texture_refs)) {
        .loaded => |handles| .{ .allocator = allocator, .handles = handles },
        .failed => |failure| failure.err,
    };
}

fn initPreparedForTest(
    allocator: std.mem.Allocator,
    renderer: *renderer2d.Renderer2D,
    backend: *rhi.Rhi,
    prepared: *const PreparedTextureSet,
) !RuntimeTextureRegistry {
    return initPreparedWithoutRefresh(allocator, renderer, backend, prepared);
}

fn mapResourceStage(stage: resource.AsyncTextureFailureStage) TextureRefreshFailureStage {
    return switch (stage) {
        .submit => .submit,
        .read => .read,
        .decode => .decode,
    };
}

fn deinitAsyncResult(allocator: std.mem.Allocator, result: *resource.AsyncTextureResult) void {
    switch (result.*) {
        .loaded => |*texture| texture.deinit(allocator),
        .failed => {},
    }
}

fn testTextureData(allocator: std.mem.Allocator, rgba: [4]u8) !resource.TextureData {
    const pixels = try allocator.dupe(u8, &rgba);
    return .{
        .width = 1,
        .height = 1,
        .pixels_rgba8 = pixels,
    };
}

test "prepared textures publish one complete owned registry" {
    var backend = try rhi.Rhi.init(.{ .width = 64, .height = 64 });
    defer backend.deinit();
    const shader = [_]u8{ 0, 0, 0, 0 };
    const pipeline = try backend.createGraphicsPipeline(.{
        .vertex_shader = &shader,
        .fragment_shader = &shader,
        .push_constant_size = 32,
        .uses_texture = true,
    });
    var renderer = renderer2d.Renderer2D{ .pipeline = pipeline };
    defer renderer.deinit(&backend);

    var prepared = PreparedTextureSet{
        .allocator = std.testing.allocator,
        .textures = .{
            try testTextureData(std.testing.allocator, .{ 255, 0, 0, 255 }),
            try testTextureData(std.testing.allocator, .{ 0, 255, 0, 255 }),
        },
    };
    defer prepared.deinit();

    var registry_source = try initPreparedForTest(std.testing.allocator, &renderer, &backend, &prepared);
    var registry = registry_source.take();
    registry_source.deinit(&backend);
    prepared.deinit();
    prepared.deinit();
    const primary = try registry.resolve(1);
    const secondary = try registry.resolve(2);
    try std.testing.expect(primary != secondary);
    try std.testing.expectEqual(@as(u32, 2), backend.stats().textures_live);
    const before_unknown = backend.stats();
    try std.testing.expectError(error.UnknownWorldTexture, registry.resolve(3));
    try std.testing.expectEqualDeep(before_unknown, backend.stats());

    registry.deinit(&backend);
    registry.deinit(&backend);
    const stats = backend.stats();
    try std.testing.expectEqual(@as(u32, 2), stats.textures_created);
    try std.testing.expectEqual(@as(u32, 2), stats.textures_destroyed);
    try std.testing.expectEqual(@as(u32, 0), stats.textures_live);
}

test "refresh accumulator preserves spec order across reverse completion" {
    var accumulator = RefreshAccumulator.init(std.testing.allocator);
    defer accumulator.deinit();

    try accumulator.feed(1, .{ .loaded = try testTextureData(std.testing.allocator, .{ 0, 255, 0, 255 }) });
    try std.testing.expect(accumulator.takeCompleted() == null);
    try accumulator.feed(0, .{ .loaded = try testTextureData(std.testing.allocator, .{ 255, 0, 0, 255 }) });

    const completed = accumulator.takeCompleted() orelse return error.MissingCompletedTextureSet;
    switch (completed) {
        .loaded => |loaded| {
            var textures = loaded;
            defer for (&textures) |*texture| texture.deinit(std.testing.allocator);
            try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, textures[0].pixels_rgba8);
            try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, textures[1].pixels_rgba8);
        },
        .failed => return error.ExpectedLoadedTextureSet,
    }
    try std.testing.expect(accumulator.takeCompleted() == null);
}

test "refresh accumulator reports the lowest failed spec ordinal" {
    var accumulator = RefreshAccumulator.init(std.testing.allocator);
    defer accumulator.deinit();

    try accumulator.feed(1, .{ .failed = .{ .stage = .decode, .reason = .invalid_artifact } });
    try accumulator.feed(0, .{ .failed = .{ .stage = .read, .reason = .not_found } });
    const completed = accumulator.takeCompleted() orelse return error.MissingCompletedTextureSet;
    switch (completed) {
        .loaded => return error.ExpectedRefreshFailure,
        .failed => |failure| {
            try std.testing.expectEqual(@as(usize, 0), failure.ordinal);
            try std.testing.expectEqual(.read, failure.failure.stage);
            try std.testing.expectEqual(.not_found, failure.failure.reason);
        },
    }
}

test "initial upload failure never publishes a partial registry" {
    var backend = try rhi.Rhi.init(.{ .width = 64, .height = 64 });
    defer backend.deinit();
    const shader = [_]u8{ 0, 0, 0, 0 };
    const pipeline = try backend.createGraphicsPipeline(.{
        .vertex_shader = &shader,
        .fragment_shader = &shader,
        .push_constant_size = 32,
        .uses_texture = true,
    });
    var renderer = renderer2d.Renderer2D{ .pipeline = pipeline };
    defer renderer.deinit(&backend);
    const pixels = [_]u8{ 255, 255, 255, 255 };
    var blockers: [7]rhi.TextureHandle = undefined;
    for (&blockers) |*handle| handle.* = try backend.createTexture(.{ .width = 1, .height = 1, .rgba8 = &pixels });
    defer for (blockers) |handle| backend.destroyTexture(handle);

    var prepared = PreparedTextureSet{
        .allocator = std.testing.allocator,
        .textures = .{
            try testTextureData(std.testing.allocator, .{ 255, 0, 0, 255 }),
            try testTextureData(std.testing.allocator, .{ 0, 255, 0, 255 }),
        },
    };
    defer prepared.deinit();

    const before = backend.stats();
    try std.testing.expectError(
        error.TextureLimitReached,
        initPreparedForTest(std.testing.allocator, &renderer, &backend, &prepared),
    );
    const after = backend.stats();
    try std.testing.expectEqual(@as(u32, 1), after.textures_created - before.textures_created);
    try std.testing.expectEqual(@as(u32, 1), after.textures_destroyed - before.textures_destroyed);
    try std.testing.expectEqual(@as(u32, 7), after.textures_live);
}

test "refresh failure preserves the complete active registry" {
    var backend = try rhi.Rhi.init(.{ .width = 64, .height = 64 });
    defer backend.deinit();
    const shader = [_]u8{ 0, 0, 0, 0 };
    const pipeline = try backend.createGraphicsPipeline(.{
        .vertex_shader = &shader,
        .fragment_shader = &shader,
        .push_constant_size = 32,
        .uses_texture = true,
    });
    var renderer = renderer2d.Renderer2D{ .pipeline = pipeline };
    defer renderer.deinit(&backend);

    var prepared = PreparedTextureSet{
        .allocator = std.testing.allocator,
        .textures = .{
            try testTextureData(std.testing.allocator, .{ 255, 0, 0, 255 }),
            try testTextureData(std.testing.allocator, .{ 0, 255, 0, 255 }),
        },
    };
    defer prepared.deinit();
    var registry = try initPreparedForTest(std.testing.allocator, &renderer, &backend, &prepared);
    defer registry.deinit(&backend);
    const primary = try registry.resolve(primary_texture_id);
    const secondary = try registry.resolve(secondary_texture_id);

    registry.refresh = .{ .accumulator = RefreshAccumulator.init(std.testing.allocator) };
    try registry.refresh.?.accumulator.feed(0, .{ .loaded = try testTextureData(std.testing.allocator, .{ 1, 2, 3, 255 }) });
    try registry.refresh.?.accumulator.feed(1, .{ .failed = .{ .stage = .read, .reason = .not_found } });

    const outcome = registry.pollRefresh(&renderer, &backend) orelse return error.MissingRefreshOutcome;
    switch (outcome) {
        .applied => return error.ExpectedRefreshFailure,
        .failed => |failure| {
            try std.testing.expectEqual(secondary_texture_id, failure.texture_id);
            try std.testing.expectEqualStrings("assets/renderer2d/goal.texture", failure.artifact_key);
            try std.testing.expectEqual(.read, failure.stage);
            try std.testing.expectEqual(.not_found, failure.reason.resource);
        },
    }
    try std.testing.expectEqual(primary, try registry.resolve(primary_texture_id));
    try std.testing.expectEqual(secondary, try registry.resolve(secondary_texture_id));
    try std.testing.expectEqual(@as(u32, 2), backend.stats().textures_live);
    try std.testing.expect(registry.pollRefresh(&renderer, &backend) == null);
}

test "refresh swaps both handles only after both candidate uploads succeed" {
    var backend = try rhi.Rhi.init(.{ .width = 64, .height = 64 });
    defer backend.deinit();
    const shader = [_]u8{ 0, 0, 0, 0 };
    const pipeline = try backend.createGraphicsPipeline(.{
        .vertex_shader = &shader,
        .fragment_shader = &shader,
        .push_constant_size = 32,
        .uses_texture = true,
    });
    var renderer = renderer2d.Renderer2D{ .pipeline = pipeline };
    defer renderer.deinit(&backend);

    var prepared = PreparedTextureSet{
        .allocator = std.testing.allocator,
        .textures = .{
            try testTextureData(std.testing.allocator, .{ 255, 0, 0, 255 }),
            try testTextureData(std.testing.allocator, .{ 0, 255, 0, 255 }),
        },
    };
    defer prepared.deinit();
    var registry = try initPreparedForTest(std.testing.allocator, &renderer, &backend, &prepared);
    defer registry.deinit(&backend);
    const old_primary = try registry.resolve(primary_texture_id);
    const old_secondary = try registry.resolve(secondary_texture_id);

    registry.refresh = .{ .accumulator = RefreshAccumulator.init(std.testing.allocator) };
    try registry.refresh.?.accumulator.feed(1, .{ .loaded = try testTextureData(std.testing.allocator, .{ 7, 8, 9, 255 }) });
    try registry.refresh.?.accumulator.feed(0, .{ .loaded = try testTextureData(std.testing.allocator, .{ 4, 5, 6, 255 }) });

    try std.testing.expectEqual(.applied, registry.pollRefresh(&renderer, &backend).?);
    const new_primary = try registry.resolve(primary_texture_id);
    const new_secondary = try registry.resolve(secondary_texture_id);
    try std.testing.expect(new_primary != old_primary);
    try std.testing.expect(new_secondary != old_secondary);
    const stats = backend.stats();
    try std.testing.expectEqual(@as(u32, 4), stats.textures_created);
    try std.testing.expectEqual(@as(u32, 2), stats.textures_destroyed);
    try std.testing.expectEqual(@as(u32, 2), stats.textures_live);
    try std.testing.expect(registry.pollRefresh(&renderer, &backend) == null);
}

test "refresh rolls back the first candidate when the second upload fails" {
    var backend = try rhi.Rhi.init(.{ .width = 64, .height = 64 });
    defer backend.deinit();
    const shader = [_]u8{ 0, 0, 0, 0 };
    const pipeline = try backend.createGraphicsPipeline(.{
        .vertex_shader = &shader,
        .fragment_shader = &shader,
        .push_constant_size = 32,
        .uses_texture = true,
    });
    var renderer = renderer2d.Renderer2D{ .pipeline = pipeline };
    defer renderer.deinit(&backend);

    var prepared = PreparedTextureSet{
        .allocator = std.testing.allocator,
        .textures = .{
            try testTextureData(std.testing.allocator, .{ 255, 0, 0, 255 }),
            try testTextureData(std.testing.allocator, .{ 0, 255, 0, 255 }),
        },
    };
    defer prepared.deinit();
    var registry = try initPreparedForTest(std.testing.allocator, &renderer, &backend, &prepared);
    defer registry.deinit(&backend);
    const old_primary = try registry.resolve(primary_texture_id);
    const old_secondary = try registry.resolve(secondary_texture_id);

    const pixels = [_]u8{ 255, 255, 255, 255 };
    var blockers: [5]rhi.TextureHandle = undefined;
    for (&blockers) |*handle| handle.* = try backend.createTexture(.{ .width = 1, .height = 1, .rgba8 = &pixels });
    defer for (blockers) |handle| backend.destroyTexture(handle);

    registry.refresh = .{ .accumulator = RefreshAccumulator.init(std.testing.allocator) };
    try registry.refresh.?.accumulator.feed(0, .{ .loaded = try testTextureData(std.testing.allocator, .{ 4, 5, 6, 255 }) });
    try registry.refresh.?.accumulator.feed(1, .{ .loaded = try testTextureData(std.testing.allocator, .{ 7, 8, 9, 255 }) });

    const before = backend.stats();
    const outcome = registry.pollRefresh(&renderer, &backend) orelse return error.MissingRefreshOutcome;
    switch (outcome) {
        .applied => return error.ExpectedRefreshFailure,
        .failed => |failure| {
            try std.testing.expectEqual(secondary_texture_id, failure.texture_id);
            try std.testing.expectEqual(.upload, failure.stage);
            try std.testing.expectEqual(error.TextureLimitReached, failure.reason.runtime);
        },
    }
    const after = backend.stats();
    try std.testing.expectEqual(@as(u32, 1), after.textures_created - before.textures_created);
    try std.testing.expectEqual(@as(u32, 1), after.textures_destroyed - before.textures_destroyed);
    try std.testing.expectEqual(@as(u32, 7), after.textures_live);
    try std.testing.expectEqual(old_primary, try registry.resolve(primary_texture_id));
    try std.testing.expectEqual(old_secondary, try registry.resolve(secondary_texture_id));
}
