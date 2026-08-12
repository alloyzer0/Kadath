const std = @import("std");
const artifact = @import("behavior_artifact");
const common = @import("behavior_common");
const manifest = @import("behavior_manifest");
const tooling = @import("behavior_tooling");

pub const Diagnostic = struct {
    script_id: u32 = 0,
    source_name_storage: [common.max_source_name_bytes]u8 = [_]u8{0} ** common.max_source_name_bytes,
    source_name_bytes: u16 = 0,
    detail: tooling.Diagnostic = .{},

    pub fn clear(self: *Diagnostic) void {
        self.* = .{};
    }

    pub fn sourceName(self: *const Diagnostic) []const u8 {
        return self.source_name_storage[0..self.source_name_bytes];
    }

    pub fn message(self: *const Diagnostic) []const u8 {
        return self.detail.slice();
    }
};

pub const BuiltPackage = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    source_revision: [32]u8,
    artifact_revision: [32]u8,
    entry_count: u8,

    pub fn deinit(self: *BuiltPackage) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub fn build(
    allocator: std.mem.Allocator,
    snapshot: *const manifest.SourceSnapshot,
    diagnostic: *Diagnostic,
) !BuiltPackage {
    diagnostic.clear();
    if (snapshot.entry_count == 0 or snapshot.entry_count > artifact.max_entry_count) {
        return error.InvalidScriptEntryCount;
    }

    var compiled: [manifest.max_script_count]?tooling.CompiledScript = [_]?tooling.CompiledScript{null} ** manifest.max_script_count;
    defer for (&compiled) |*item| {
        if (item.*) |*value| value.deinit();
    };
    var build_entries: [artifact.max_entry_count]artifact.BuildEntry = undefined;

    for (snapshot.entrySlice(), 0..) |*source_entry, entry_index| {
        var native_diagnostic = tooling.Diagnostic{};
        var chunk_name_storage: [common.max_source_name_bytes + 1]u8 = [_]u8{0} ** (common.max_source_name_bytes + 1);
        @memcpy(chunk_name_storage[0..source_entry.sourceName().len], source_entry.sourceName());
        const chunk_name: [:0]const u8 = chunk_name_storage[0..source_entry.sourceName().len :0];
        compiled[entry_index] = tooling.compile(
            allocator,
            source_entry.source,
            chunk_name,
            &native_diagnostic,
        ) catch {
            diagnostic.script_id = source_entry.script_id;
            diagnostic.source_name_bytes = source_entry.source_name_bytes;
            @memcpy(diagnostic.source_name_storage[0..source_entry.sourceName().len], source_entry.sourceName());
            diagnostic.detail = native_diagnostic;
            return error.BehaviorPackageBuildFailed;
        };
        const compiled_script = &compiled[entry_index].?;
        build_entries[entry_index] = .{
            .script_id = source_entry.script_id,
            .source_name = source_entry.sourceName(),
            .source_sha256 = source_entry.source_sha256,
            .parameters = compiled_script.parameterSlice(),
            .bytecode = compiled_script.bytecode,
        };
    }

    const bytes = try artifact.encode(allocator, tooling.toolchainIdentity(), build_entries[0..snapshot.entry_count]);
    errdefer allocator.free(bytes);
    const package = try artifact.parse(bytes, tooling.toolchainIdentity());
    return .{
        .allocator = allocator,
        .bytes = bytes,
        .source_revision = snapshot.source_revision,
        .artifact_revision = package.artifact_revision,
        .entry_count = package.entry_count,
    };
}
