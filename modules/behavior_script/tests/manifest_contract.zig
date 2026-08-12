const std = @import("std");
const manifest = @import("behavior_manifest");

const valid_manifest =
    \\{
    \\  "schemaVersion": 2,
    \\  "scripts": [
    \\    { "scriptId": 7, "source": "scripts/patrol.luau" },
    \\    { "scriptId": 19, "source": "scripts/nested/bounce.luau" }
    \\  ]
    \\}
;

test "Script v2 manifest preserves stable logical identities" {
    const compact = "{\"schemaVersion\":2,\"scripts\":[{\"scriptId\":7,\"source\":\"scripts/patrol.luau\"},{\"scriptId\":19,\"source\":\"scripts/nested/bounce.luau\"}]}";
    const formatted = try manifest.parse(std.testing.allocator, valid_manifest);
    const normalized = try manifest.parse(std.testing.allocator, compact);
    try std.testing.expectEqual(@as(u8, 2), formatted.entry_count);
    try std.testing.expectEqualStrings("scripts/nested/bounce.luau", (formatted.findEntry(19) orelse return error.MissingEntry).sourceName());
    try std.testing.expectEqualSlices(u8, &formatted.normalized_revision, &normalized.normalized_revision);
}

test "Script v2 manifest rejects unknown fields duplicate ids and unsafe paths" {
    try std.testing.expectError(
        error.UnknownField,
        manifest.parse(std.testing.allocator, "{\"schemaVersion\":2,\"scripts\":[{\"scriptId\":1,\"source\":\"scripts/a.luau\"}],\"extra\":true}"),
    );
    try std.testing.expectError(
        error.DuplicateScriptId,
        manifest.parse(std.testing.allocator, "{\"schemaVersion\":2,\"scripts\":[{\"scriptId\":1,\"source\":\"scripts/a.luau\"},{\"scriptId\":1,\"source\":\"scripts/b.luau\"}]}"),
    );
    try std.testing.expectError(
        error.InvalidScriptSourceName,
        manifest.parse(std.testing.allocator, "{\"schemaVersion\":2,\"scripts\":[{\"scriptId\":1,\"source\":\"scripts/../escape.luau\"}]}"),
    );
}

test "Script source snapshot covers every dependency and detects later changes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "scripts/nested");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "scripts/patrol.luau", .data = "return { fixed_update = function(self, dt) self:translate(0, dt) end }" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "scripts/nested/bounce.luau", .data = "return { on_start = function(self) self:translate(1, 0) end }" });

    var snapshot = try manifest.loadSnapshot(std.testing.io, std.testing.allocator, tmp.dir, valid_manifest);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(u8, 2), snapshot.entry_count);
    try std.testing.expectEqualStrings("scripts/patrol.luau", snapshot.entrySlice()[0].sourceName());
    try snapshot.verifyUnchanged(std.testing.io, tmp.dir);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "scripts/patrol.luau", .data = "return {}" });
    try std.testing.expectError(error.ScriptSourceChanged, snapshot.verifyUnchanged(std.testing.io, tmp.dir));
}

test "Script source snapshot rejects an aggregate over the fixed budget" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "scripts", .default_dir);
    const source = try std.testing.allocator.alloc(u8, manifest.max_source_bytes);
    defer std.testing.allocator.free(source);
    @memset(source, 'a');
    var manifest_buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&manifest_buffer);
    try writer.writeAll("{\"schemaVersion\":2,\"scripts\":[");
    for (0..9) |index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print("{{\"scriptId\":{d},\"source\":\"scripts/{d}.luau\"}}", .{ index + 1, index });
        var path_buffer: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "scripts/{d}.luau", .{index});
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = source });
    }
    try writer.writeAll("]}");
    try std.testing.expectError(
        error.ScriptSourceBudgetExceeded,
        manifest.loadSnapshot(std.testing.io, std.testing.allocator, tmp.dir, writer.buffered()),
    );
}
