const std = @import("std");
const artifact = @import("behavior_artifact");
const builder = @import("behavior_package_builder");
const manifest = @import("behavior_manifest");
const tooling = @import("behavior_tooling");

const source_manifest =
    \\{
    \\  "schemaVersion": 2,
    \\  "scripts": [
    \\    { "scriptId": 7, "source": "scripts/patrol.luau" },
    \\    { "scriptId": 19, "source": "scripts/bounce.luau" }
    \\  ]
    \\}
;

test "Behavior Package Builder compiles one aggregate KSCP v2" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "scripts", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "scripts/patrol.luau",
        .data =
        \\--!strict
        \\local speed = kadath.parameter.number("speed", { default = 80, min = 0, max = 1000 })
        \\return { fixed_update = function(self: Kadath.Object, dt: number) self:translate(0, speed * dt) end }
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "scripts/bounce.luau",
        .data = "return { on_start = function(self) self:translate(1, 0) end }",
    });

    var snapshot = try manifest.loadSnapshot(std.testing.io, std.testing.allocator, tmp.dir, source_manifest);
    defer snapshot.deinit();
    var diagnostic = builder.Diagnostic{};
    var built = try builder.build(std.testing.allocator, &snapshot, &diagnostic);
    defer built.deinit();

    const package = try artifact.parse(built.bytes, tooling.toolchainIdentity());
    try std.testing.expectEqual(@as(u8, 2), package.entry_count);
    try std.testing.expectEqualSlices(u8, &snapshot.source_revision, &built.source_revision);
    try std.testing.expectEqualSlices(u8, &package.artifact_revision, &built.artifact_revision);
    try std.testing.expectEqualStrings("speed", (package.findEntry(7) orelse return error.MissingPatrol).parameterSlice()[0].name());
}

test "Behavior Package Builder reports the failing source identity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "scripts", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "scripts/patrol.luau",
        .data = "return {}",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "scripts/bounce.luau",
        .data = "--!strict\nlocal broken: string = 42\nreturn {}",
    });

    var snapshot = try manifest.loadSnapshot(std.testing.io, std.testing.allocator, tmp.dir, source_manifest);
    defer snapshot.deinit();
    var diagnostic = builder.Diagnostic{};
    try std.testing.expectError(
        error.BehaviorPackageBuildFailed,
        builder.build(std.testing.allocator, &snapshot, &diagnostic),
    );
    try std.testing.expectEqual(@as(u32, 19), diagnostic.script_id);
    try std.testing.expectEqualStrings("scripts/bounce.luau", diagnostic.sourceName());
    try std.testing.expect(diagnostic.message().len != 0);
}
