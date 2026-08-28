const std = @import("std");
const scene_api = @import("scene.zig");
const tilemap_asset = @import("tilemap_asset.zig");

pub const max_visible_layers = tilemap_asset.max_layers;

/// Scene 引用与独立 Tilemap artifact 的候选集合。只有所有身份、Texture 和 Layer 预算
/// 都通过后，Host 才会把整个集合与 Scene/Texture Registry 一起发布。
pub const RuntimeTilemapSet = struct {
    allocator: std.mem.Allocator,
    assets: [scene_api.max_chunked_tilemap_count]?tilemap_asset.Asset = [_]?tilemap_asset.Asset{null} ** scene_api.max_chunked_tilemap_count,
    count: u8 = 0,
    layer_count: u8 = 0,
    deinitialized: bool = false,

    pub fn loadForScene(io: std.Io, allocator: std.mem.Allocator, scene: *const scene_api.Scene) !RuntimeTilemapSet {
        var result = RuntimeTilemapSet{ .allocator = allocator };
        errdefer result.deinit();
        for (scene.chunkedTilemaps.slice(), 0..) |reference, index| {
            var asset = try tilemap_asset.load(io, allocator, reference.artifact.slice());
            errdefer asset.deinit();
            try validateIdentity(&reference, &asset);
            try validateTextureSources(scene, &asset);
            const next_layers = std.math.add(usize, result.layer_count, asset.layers.len) catch return error.TilemapLayerLimitExceeded;
            if (next_layers > max_visible_layers) return error.TilemapLayerLimitExceeded;
            result.assets[index] = asset;
            result.count += 1;
            result.layer_count = @intCast(next_layers);
        }
        return result;
    }

    pub fn take(self: *RuntimeTilemapSet) RuntimeTilemapSet {
        std.debug.assert(!self.deinitialized);
        const moved = self.*;
        self.* = .{ .allocator = self.allocator, .deinitialized = true };
        return moved;
    }

    pub fn deinit(self: *RuntimeTilemapSet) void {
        if (self.deinitialized) return;
        for (self.assets[0..self.count]) |*slot| {
            if (slot.*) |*asset| asset.deinit();
            slot.* = null;
        }
        self.count = 0;
        self.layer_count = 0;
        self.deinitialized = true;
    }
};

fn validateIdentity(reference: *const scene_api.ChunkedTilemapRef, asset: *const tilemap_asset.Asset) !void {
    if (asset.identity.byte_count != reference.artifactBytes) return error.TilemapArtifactIdentityMismatch;
    var actual_hex: [64]u8 = undefined;
    if (!std.mem.eql(u8, asset.identity.writeHexLower(&actual_hex), reference.artifactRevision.slice())) {
        return error.TilemapArtifactIdentityMismatch;
    }
}

fn validateTextureSources(scene: *const scene_api.Scene, asset: *const tilemap_asset.Asset) !void {
    for (asset.tile_sources) |source| {
        const texture = scene.textures.find(source.texture_id) orelse return error.UnknownSceneTexture;
        if (texture.samplingProfile != .pixel_art) return error.InvalidTilemapSamplingProfile;
    }
}

test "empty legacy Scene prepares an empty chunked Tilemap candidate" {
    var result = try RuntimeTilemapSet.loadForScene(std.testing.io, std.testing.allocator, &scene_api.default_scene);
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 0), result.count);
    try std.testing.expectEqual(@as(u8, 0), result.layer_count);
}
