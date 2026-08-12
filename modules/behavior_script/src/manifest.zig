const std = @import("std");
const common = @import("behavior_common");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const schema_version: u32 = 2;
pub const max_script_count: usize = 16;
pub const max_manifest_bytes: usize = 64 * 1024;
pub const max_source_bytes: usize = 64 * 1024;
pub const max_aggregate_source_bytes: usize = 512 * 1024;

const WireEntry = struct {
    scriptId: u32,
    source: []const u8,
};

const WireManifest = struct {
    schemaVersion: u32,
    scripts: []const WireEntry,
};

pub const Entry = struct {
    script_id: u32 = 0,
    source_name_storage: [common.max_source_name_bytes]u8 = [_]u8{0} ** common.max_source_name_bytes,
    source_name_bytes: u16 = 0,

    pub fn sourceName(self: *const Entry) []const u8 {
        return self.source_name_storage[0..self.source_name_bytes];
    }
};

pub const Manifest = struct {
    entries: [max_script_count]Entry = [_]Entry{.{}} ** max_script_count,
    entry_count: u8 = 0,
    normalized_revision: [Sha256.digest_length]u8 = [_]u8{0} ** Sha256.digest_length,

    pub fn entrySlice(self: *const Manifest) []const Entry {
        return self.entries[0..self.entry_count];
    }

    pub fn findEntry(self: *const Manifest, script_id: u32) ?*const Entry {
        for (self.entrySlice()) |*entry| {
            if (entry.script_id == script_id) return entry;
        }
        return null;
    }
};

pub const SourceEntry = struct {
    script_id: u32 = 0,
    source_name_storage: [common.max_source_name_bytes]u8 = [_]u8{0} ** common.max_source_name_bytes,
    source_name_bytes: u16 = 0,
    source: []u8 = &.{},
    source_sha256: [Sha256.digest_length]u8 = [_]u8{0} ** Sha256.digest_length,

    pub fn sourceName(self: *const SourceEntry) []const u8 {
        return self.source_name_storage[0..self.source_name_bytes];
    }
};

pub const SourceSnapshot = struct {
    allocator: std.mem.Allocator,
    manifest: Manifest,
    entries: [max_script_count]SourceEntry = [_]SourceEntry{.{}} ** max_script_count,
    entry_count: u8 = 0,
    source_revision: [Sha256.digest_length]u8 = [_]u8{0} ** Sha256.digest_length,

    pub fn deinit(self: *SourceSnapshot) void {
        for (self.entries[0..self.entry_count]) |entry| self.allocator.free(entry.source);
        self.* = undefined;
    }

    pub fn entrySlice(self: *const SourceSnapshot) []const SourceEntry {
        return self.entries[0..self.entry_count];
    }

    pub fn verifyUnchanged(self: *const SourceSnapshot, io: std.Io, project_dir: std.Io.Dir) !void {
        for (self.entrySlice()) |entry| {
            const current = try readSource(io, self.allocator, project_dir, entry.sourceName());
            defer self.allocator.free(current);
            var current_sha256: [Sha256.digest_length]u8 = undefined;
            Sha256.hash(current, &current_sha256, .{});
            if (!std.mem.eql(u8, &entry.source_sha256, &current_sha256)) return error.ScriptSourceChanged;
        }
    }
};

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Manifest {
    if (bytes.len == 0 or bytes.len > max_manifest_bytes) return error.InvalidScriptManifestSize;
    const json_bytes = if (std.mem.startsWith(u8, bytes, "\xef\xbb\xbf")) bytes[3..] else bytes;
    const parsed = try std.json.parseFromSlice(WireManifest, allocator, json_bytes, .{});
    defer parsed.deinit();
    if (parsed.value.schemaVersion != schema_version) return error.UnsupportedScriptSchema;
    if (parsed.value.scripts.len == 0 or parsed.value.scripts.len > max_script_count) {
        return error.InvalidScriptEntryCount;
    }

    var manifest = Manifest{ .entry_count = @intCast(parsed.value.scripts.len) };
    for (parsed.value.scripts, 0..) |wire_entry, entry_index| {
        if (wire_entry.scriptId == 0) return error.InvalidScriptId;
        try common.validateSourceName(wire_entry.source);
        for (manifest.entries[0..entry_index]) |existing| {
            if (existing.script_id == wire_entry.scriptId) return error.DuplicateScriptId;
            if (std.mem.eql(u8, existing.sourceName(), wire_entry.source)) return error.DuplicateScriptSource;
        }
        manifest.entries[entry_index].script_id = wire_entry.scriptId;
        manifest.entries[entry_index].source_name_bytes = @intCast(wire_entry.source.len);
        @memcpy(manifest.entries[entry_index].source_name_storage[0..wire_entry.source.len], wire_entry.source);
    }
    manifest.normalized_revision = normalizedManifestRevision(&manifest);
    return manifest;
}

pub fn loadSnapshot(
    io: std.Io,
    allocator: std.mem.Allocator,
    project_dir: std.Io.Dir,
    manifest_bytes: []const u8,
) !SourceSnapshot {
    const manifest = try parse(allocator, manifest_bytes);
    var snapshot = SourceSnapshot{
        .allocator = allocator,
        .manifest = manifest,
        .entry_count = manifest.entry_count,
    };
    errdefer snapshot.deinit();

    var aggregate_bytes: usize = 0;
    for (manifest.entrySlice(), 0..) |manifest_entry, entry_index| {
        const source = try readSource(io, allocator, project_dir, manifest_entry.sourceName());
        aggregate_bytes = checkedAdd(aggregate_bytes, source.len) catch {
            allocator.free(source);
            return error.ScriptSourceBudgetExceeded;
        };
        if (aggregate_bytes > max_aggregate_source_bytes) {
            allocator.free(source);
            return error.ScriptSourceBudgetExceeded;
        }
        var source_entry = SourceEntry{
            .script_id = manifest_entry.script_id,
            .source_name_bytes = manifest_entry.source_name_bytes,
            .source = source,
        };
        @memcpy(source_entry.source_name_storage[0..manifest_entry.sourceName().len], manifest_entry.sourceName());
        Sha256.hash(source, &source_entry.source_sha256, .{});
        snapshot.entries[entry_index] = source_entry;
    }
    snapshot.source_revision = sourceRevision(&snapshot);
    return snapshot;
}

fn normalizedManifestRevision(manifest: *const Manifest) [Sha256.digest_length]u8 {
    var hasher = Sha256.init(.{});
    hasher.update("KADATH-SCRIPT-MANIFEST-V2\x00");
    hashU32(&hasher, schema_version);
    hashU32(&hasher, manifest.entry_count);
    for (manifest.entrySlice()) |entry| {
        hashU32(&hasher, entry.script_id);
        hashU32(&hasher, @intCast(entry.sourceName().len));
        hasher.update(entry.sourceName());
    }
    var digest: [Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn sourceRevision(snapshot: *const SourceSnapshot) [Sha256.digest_length]u8 {
    var hasher = Sha256.init(.{});
    hasher.update("KADATH-SCRIPT-SOURCE-SET-V2\x00");
    hasher.update(&snapshot.manifest.normalized_revision);
    for (snapshot.entrySlice()) |entry| {
        hashU32(&hasher, entry.script_id);
        hashU32(&hasher, @intCast(entry.sourceName().len));
        hasher.update(entry.sourceName());
        hashU64(&hasher, entry.source.len);
        hasher.update(entry.source);
    }
    var digest: [Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn readSource(io: std.Io, allocator: std.mem.Allocator, project_dir: std.Io.Dir, source_name: []const u8) ![]u8 {
    var file = try openSourceFile(io, project_dir, source_name);
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.ScriptSourceNotFile;
    if (stat.size > max_source_bytes) return error.ScriptSourceTooLarge;
    var file_reader = file.reader(io, &.{});
    const source = file_reader.interface.allocRemaining(allocator, .limited(max_source_bytes + 1)) catch |err| switch (err) {
        error.StreamTooLong => return error.ScriptSourceTooLarge,
        error.ReadFailed => return file_reader.err.?,
        else => |other| return other,
    };
    errdefer allocator.free(source);
    if (source.len > max_source_bytes) return error.ScriptSourceTooLarge;
    if (!std.unicode.utf8ValidateSlice(source)) return error.InvalidScriptSourceEncoding;
    return source;
}

fn openSourceFile(io: std.Io, project_dir: std.Io.Dir, source_name: []const u8) !std.Io.File {
    try common.validateSourceName(source_name);
    var segments = std.mem.splitScalar(u8, source_name, '/');
    var current_dir = project_dir;
    var owns_current_dir = false;
    errdefer if (owns_current_dir) current_dir.close(io);

    while (segments.next()) |segment| {
        if (segments.peek() == null) {
            const file = current_dir.openFile(io, segment, .{
                .allow_directory = false,
                .follow_symlinks = false,
                .resolve_beneath = true,
            }) catch |err| return switch (err) {
                error.FileNotFound => error.ScriptSourceMissing,
                error.SymLinkLoop => error.ScriptSourceReparsePoint,
                error.IsDir => error.ScriptSourceNotFile,
                else => |other| other,
            };
            if (owns_current_dir) current_dir.close(io);
            return file;
        }
        const next_dir = current_dir.openDir(io, segment, .{
            .follow_symlinks = false,
        }) catch |err| return switch (err) {
            error.FileNotFound => error.ScriptSourceMissing,
            error.SymLinkLoop => error.ScriptSourceReparsePoint,
            error.NotDir => error.ScriptSourceReparsePoint,
            else => |other| other,
        };
        if (owns_current_dir) current_dir.close(io);
        current_dir = next_dir;
        owns_current_dir = true;
    }
    return error.InvalidScriptSourceName;
}

fn hashU32(hasher: *Sha256, value: u32) void {
    var bytes: [4]u8 = undefined;
    writeLittleU32(&bytes, value);
    hasher.update(&bytes);
}

fn hashU64(hasher: *Sha256, value: u64) void {
    var bytes: [8]u8 = undefined;
    writeLittleU64(&bytes, value);
    hasher.update(&bytes);
}

fn checkedAdd(left: usize, right: usize) !usize {
    if (right > std.math.maxInt(usize) - left) return error.Overflow;
    return left + right;
}

fn writeLittleU32(bytes: []u8, value: u32) void {
    bytes[0] = @truncate(value);
    bytes[1] = @truncate(value >> 8);
    bytes[2] = @truncate(value >> 16);
    bytes[3] = @truncate(value >> 24);
}

fn writeLittleU64(bytes: []u8, value: u64) void {
    for (bytes[0..8], 0..) |*byte, shift_index| {
        byte.* = @truncate(value >> @intCast(shift_index * 8));
    }
}
