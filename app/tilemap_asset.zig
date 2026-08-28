const std = @import("std");
const content_identity = @import("content_identity.zig");

pub const artifact_version: u32 = 1;
pub const chunk_edge: usize = 32;
pub const max_tile_sources: usize = 16;
pub const max_layers: usize = 4;
pub const max_artifact_bytes: usize = 64 * 1024 * 1024;

pub const Transform = packed struct(u3) {
    flip_horizontal: bool = false,
    flip_vertical: bool = false,
    flip_diagonal: bool = false,
};

pub const StableId = struct {
    byte_count: u8 = 0,
    storage: [63]u8 = [_]u8{0} ** 63,

    pub fn init(bytes: []const u8) !StableId {
        if (!isStableId(bytes)) return error.InvalidTilemapStableId;
        var value = StableId{ .byte_count = @intCast(bytes.len) };
        @memcpy(value.storage[0..bytes.len], bytes);
        return value;
    }

    pub fn slice(self: *const StableId) []const u8 {
        return self.storage[0..self.byte_count];
    }
};

pub const TileSource = struct {
    source_id: StableId,
    texture_id: u32,
    tile_width: u32,
    tile_height: u32,
    image_width: u32,
    image_height: u32,
    columns: u32,
    rows: u32,
    margin: u32,
    spacing: u32,
};

pub const Cell = struct {
    local_index: u16,
    tile_source_index: u16,
    local_tile_id: u32,
    transform: Transform,
};

pub const Chunk = struct {
    coordinate: [2]i32,
    cells: []const Cell,
};

pub const Layer = struct {
    layer_id: StableId,
    visible: bool,
    opacity: f32,
    grid_size: [2]u32,
    offset: [2]f32,
    chunks: []const Chunk,
};

pub const Asset = struct {
    allocator: std.mem.Allocator,
    tile_sources: []TileSource,
    layers: []Layer,
    chunks: []Chunk,
    cells: []Cell,
    identity: content_identity.ContentIdentity,
    deinitialized: bool = false,

    pub fn deinit(self: *Asset) void {
        if (self.deinitialized) return;
        self.allocator.free(self.cells);
        self.allocator.free(self.chunks);
        self.allocator.free(self.layers);
        self.allocator.free(self.tile_sources);
        self.tile_sources = &.{};
        self.layers = &.{};
        self.chunks = &.{};
        self.cells = &.{};
        self.deinitialized = true;
    }

    pub fn layerCount(self: *const Asset) usize {
        return self.layers.len;
    }
};

pub fn load(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Asset {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_artifact_bytes));
    defer allocator.free(bytes);
    return decode(allocator, bytes);
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Asset {
    if (bytes.len < 32 or bytes.len > max_artifact_bytes) return error.InvalidTilemapArtifact;
    var reader = Reader{ .source = bytes };
    if (!std.mem.eql(u8, try reader.readBytes(4), "KTMP")) return error.InvalidTilemapArtifact;
    if (try reader.readU32() != artifact_version) return error.UnsupportedTilemapArtifactVersion;
    if (try reader.readU32() != chunk_edge) return error.UnsupportedTilemapChunkEdge;
    const tile_source_count = try reader.readCount(max_tile_sources);
    const layer_count = try reader.readCount(max_layers);
    const chunk_count = try reader.readCountFromBytes(12);
    const cell_count = try reader.readCountFromBytes(12);
    if (try reader.readU32() != 0) return error.InvalidTilemapArtifact;

    const tile_sources = try allocator.alloc(TileSource, tile_source_count);
    errdefer allocator.free(tile_sources);
    const layers = try allocator.alloc(Layer, layer_count);
    errdefer allocator.free(layers);
    const chunks = try allocator.alloc(Chunk, chunk_count);
    errdefer allocator.free(chunks);
    const cells = try allocator.alloc(Cell, cell_count);
    errdefer allocator.free(cells);

    for (tile_sources) |*source| {
        var entry = try reader.readEntry();
        source.* = .{
            .source_id = try StableId.init(try entry.readString()),
            .texture_id = try entry.readU32(),
            .tile_width = try entry.readPositiveU32(),
            .tile_height = try entry.readPositiveU32(),
            .image_width = try entry.readPositiveU32(),
            .image_height = try entry.readPositiveU32(),
            .columns = try entry.readPositiveU32(),
            .rows = try entry.readPositiveU32(),
            .margin = try entry.readU32(),
            .spacing = try entry.readU32(),
        };
        if (!entry.atEnd()) return error.InvalidTilemapArtifact;
    }

    var chunk_cursor: usize = 0;
    var cell_cursor: usize = 0;
    for (layers) |*layer| {
        var entry = try reader.readEntry();
        layer.layer_id = try StableId.init(try entry.readString());
        layer.visible = switch (try entry.readU32()) {
            0 => false,
            1 => true,
            else => return error.InvalidTilemapLayer,
        };
        layer.opacity = try entry.readF32();
        layer.grid_size = .{ try entry.readPositiveU32(), try entry.readPositiveU32() };
        layer.offset = .{ try entry.readF32(), try entry.readF32() };
        const layer_chunk_count = try entry.readCountFromBytes(12);
        if (layer_chunk_count > chunks.len - chunk_cursor) return error.InvalidTilemapArtifact;
        const layer_chunks = chunks[chunk_cursor .. chunk_cursor + layer_chunk_count];
        chunk_cursor += layer_chunk_count;
        for (layer_chunks) |*chunk| {
            chunk.coordinate = .{ try entry.readI32(), try entry.readI32() };
            const chunk_cell_count = try entry.readCountFromBytes(12);
            if (chunk_cell_count > cells.len - cell_cursor) return error.InvalidTilemapArtifact;
            const chunk_cells = cells[cell_cursor .. cell_cursor + chunk_cell_count];
            cell_cursor += chunk_cell_count;
            for (chunk_cells) |*cell| {
                cell.local_index = try entry.readU16();
                cell.tile_source_index = try entry.readU16();
                cell.local_tile_id = try entry.readU32();
                const flags = try entry.readU32();
                if (flags > 7) return error.InvalidTilemapTransform;
                cell.transform = @bitCast(@as(u3, @intCast(flags)));
            }
            chunk.cells = chunk_cells;
        }
        layer.chunks = layer_chunks;
        if (!entry.atEnd()) return error.InvalidTilemapArtifact;
    }
    if (!reader.atEnd() or chunk_cursor != chunks.len or cell_cursor != cells.len) return error.InvalidTilemapArtifact;

    var value = Asset{
        .allocator = allocator,
        .tile_sources = tile_sources,
        .layers = layers,
        .chunks = chunks,
        .cells = cells,
        .identity = try content_identity.ContentIdentity.fromBytes(.artifact, bytes),
    };
    errdefer value.deinit();
    try validate(&value);
    return value;
}

pub fn validate(value: *const Asset) !void {
    if (value.tile_sources.len == 0 or value.tile_sources.len > max_tile_sources) return error.InvalidTileSourceCount;
    if (value.layers.len == 0 or value.layers.len > max_layers) return error.InvalidTilemapLayerCount;
    for (value.tile_sources, 0..) |source, index| {
        _ = try StableId.init(source.source_id.slice());
        for (value.tile_sources[0..index]) |previous| {
            if (std.mem.eql(u8, source.source_id.slice(), previous.source_id.slice())) return error.DuplicateTileSourceId;
        }
        if (source.texture_id == 0 or source.tile_width == 0 or source.tile_height == 0 or
            source.image_width == 0 or source.image_height == 0 or source.columns == 0 or source.rows == 0)
        {
            return error.InvalidTileSource;
        }
        const used_width = try atlasExtent(source.margin, source.spacing, source.tile_width, source.columns);
        const used_height = try atlasExtent(source.margin, source.spacing, source.tile_height, source.rows);
        if (used_width > source.image_width or used_height > source.image_height) return error.InvalidTileSource;
    }
    for (value.layers, 0..) |layer, layer_index| {
        _ = try StableId.init(layer.layer_id.slice());
        for (value.layers[0..layer_index]) |previous| {
            if (std.mem.eql(u8, layer.layer_id.slice(), previous.layer_id.slice())) return error.DuplicateTilemapLayerId;
        }
        if (!std.math.isFinite(layer.opacity) or layer.opacity < 0 or layer.opacity > 1 or
            !std.math.isFinite(layer.offset[0]) or !std.math.isFinite(layer.offset[1]) or
            layer.grid_size[0] == 0 or layer.grid_size[1] == 0)
        {
            return error.InvalidTilemapLayer;
        }
        var previous_coordinate: ?[2]i32 = null;
        for (layer.chunks) |chunk| {
            if (previous_coordinate) |previous| {
                if (chunk.coordinate[1] < previous[1] or
                    (chunk.coordinate[1] == previous[1] and chunk.coordinate[0] <= previous[0]))
                {
                    return error.InvalidTilemapChunkOrder;
                }
            }
            previous_coordinate = chunk.coordinate;
            var previous_cell: ?u16 = null;
            for (chunk.cells) |cell| {
                if (cell.local_index >= chunk_edge * chunk_edge) return error.InvalidTilemapCell;
                if (previous_cell) |previous| if (cell.local_index <= previous) return error.InvalidTilemapCellOrder;
                previous_cell = cell.local_index;
                if (cell.tile_source_index >= value.tile_sources.len) return error.InvalidTilemapCell;
                const source = value.tile_sources[cell.tile_source_index];
                const tile_count = std.math.mul(u32, source.columns, source.rows) catch return error.InvalidTileSource;
                if (cell.local_tile_id >= tile_count) return error.InvalidTilemapCell;
            }
        }
    }
}

fn atlasExtent(margin: u32, spacing: u32, tile_size: u32, count: u32) !u32 {
    const margins = try std.math.mul(u32, margin, 2);
    const tiles = try std.math.mul(u32, tile_size, count);
    const spaces = try std.math.mul(u32, spacing, count - 1);
    return try std.math.add(u32, margins, try std.math.add(u32, tiles, spaces));
}

fn isStableId(bytes: []const u8) bool {
    if (bytes.len == 0 or bytes.len > 63 or bytes[0] < 'a' or bytes[0] > 'z') return false;
    for (bytes[1..]) |byte| {
        if (!((byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9') or byte == '_' or byte == '-')) return false;
    }
    return std.unicode.utf8ValidateSlice(bytes);
}

const Reader = struct {
    source: []const u8,
    cursor: usize = 0,

    fn readBytes(self: *Reader, byte_count: usize) ![]const u8 {
        const end = std.math.add(usize, self.cursor, byte_count) catch return error.InvalidTilemapArtifact;
        if (end > self.source.len) return error.InvalidTilemapArtifact;
        const bytes = self.source[self.cursor..end];
        self.cursor = end;
        return bytes;
    }

    fn readU16(self: *Reader) !u16 {
        const bytes = try self.readBytes(2);
        return std.mem.readInt(u16, bytes[0..2], .little);
    }

    fn readU32(self: *Reader) !u32 {
        const bytes = try self.readBytes(4);
        return std.mem.readInt(u32, bytes[0..4], .little);
    }

    fn readI32(self: *Reader) !i32 {
        return @bitCast(try self.readU32());
    }

    fn readF32(self: *Reader) !f32 {
        return @bitCast(try self.readU32());
    }

    fn readPositiveU32(self: *Reader) !u32 {
        const value = try self.readU32();
        if (value == 0) return error.InvalidTilemapArtifact;
        return value;
    }

    fn readCount(self: *Reader, maximum: usize) !usize {
        const value: usize = @intCast(try self.readU32());
        if (value > maximum) return error.InvalidTilemapArtifact;
        return value;
    }

    fn readCountFromBytes(self: *Reader, minimum_item_bytes: usize) !usize {
        const value: usize = @intCast(try self.readU32());
        const minimum = std.math.mul(usize, value, minimum_item_bytes) catch return error.InvalidTilemapArtifact;
        if (minimum > self.source.len - self.cursor) return error.InvalidTilemapArtifact;
        return value;
    }

    fn readString(self: *Reader) ![]const u8 {
        const byte_count = try self.readCount(63);
        if (byte_count == 0) return error.InvalidTilemapStableId;
        return try self.readBytes(byte_count);
    }

    fn readEntry(self: *Reader) !Reader {
        const byte_count: usize = @intCast(try self.readU32());
        return .{ .source = try self.readBytes(byte_count) };
    }

    fn atEnd(self: *const Reader) bool {
        return self.cursor == self.source.len;
    }
};

const TestWriter = struct {
    storage: []u8,
    cursor: usize = 0,

    fn slice(self: *const TestWriter) []const u8 {
        return self.storage[0..self.cursor];
    }

    fn writeBytes(self: *TestWriter, source: []const u8) void {
        @memcpy(self.storage[self.cursor .. self.cursor + source.len], source);
        self.cursor += source.len;
    }

    fn writeU16(self: *TestWriter, value: u16) void {
        std.mem.writeInt(u16, self.storage[self.cursor..][0..2], value, .little);
        self.cursor += 2;
    }

    fn writeU32(self: *TestWriter, value: u32) void {
        std.mem.writeInt(u32, self.storage[self.cursor..][0..4], value, .little);
        self.cursor += 4;
    }

    fn writeI32(self: *TestWriter, value: i32) void {
        self.writeU32(@bitCast(value));
    }

    fn writeF32(self: *TestWriter, value: f32) void {
        self.writeU32(@bitCast(value));
    }

    fn writeString(self: *TestWriter, value: []const u8) void {
        self.writeU32(@intCast(value.len));
        self.writeBytes(value);
    }
};

fn makeTestArtifact(output: []u8) []const u8 {
    var writer = TestWriter{ .storage = output };
    writer.writeBytes("KTMP");
    writer.writeU32(artifact_version);
    writer.writeU32(chunk_edge);
    writer.writeU32(1);
    writer.writeU32(1);
    writer.writeU32(1);
    writer.writeU32(2);
    writer.writeU32(0);

    writer.writeU32(45);
    writer.writeString("tiles");
    for ([_]u32{ 1, 16, 16, 32, 32, 2, 2, 0, 0 }) |value| writer.writeU32(value);

    writer.writeU32(74);
    writer.writeString("ground");
    writer.writeU32(1);
    writer.writeF32(0.5);
    writer.writeU32(16);
    writer.writeU32(16);
    writer.writeF32(-4);
    writer.writeF32(8);
    writer.writeU32(1);
    writer.writeI32(-1);
    writer.writeI32(-1);
    writer.writeU32(2);
    writer.writeU16(0);
    writer.writeU16(0);
    writer.writeU32(0);
    writer.writeU32(0);
    writer.writeU16(1023);
    writer.writeU16(0);
    writer.writeU32(3);
    writer.writeU32(5);
    return writer.slice();
}

test "chunked Tilemap artifact decodes signed chunks and transforms deterministically" {
    var storage: [256]u8 = undefined;
    const bytes = makeTestArtifact(&storage);
    var value = try decode(std.testing.allocator, bytes);
    defer value.deinit();
    try std.testing.expectEqual(@as(usize, 1), value.tile_sources.len);
    try std.testing.expectEqual(@as(usize, 1), value.layers.len);
    try std.testing.expectEqualSlices(i32, &.{ -1, -1 }, &value.layers[0].chunks[0].coordinate);
    try std.testing.expect(value.layers[0].chunks[0].cells[1].transform.flip_horizontal);
    try std.testing.expect(value.layers[0].chunks[0].cells[1].transform.flip_diagonal);
    try std.testing.expect(!value.layers[0].chunks[0].cells[1].transform.flip_vertical);
    try std.testing.expectError(error.InvalidTilemapArtifact, decode(std.testing.allocator, bytes[0 .. bytes.len - 1]));
}
