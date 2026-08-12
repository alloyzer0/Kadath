const std = @import("std");
const artifact = @import("behavior_artifact");
const builder = @import("behavior_package_builder");
const manifest = @import("behavior_manifest");
const runtime = @import("behavior_runtime");
const scene_binding = @import("behavior_scene_binding");

const source_manifest =
    \\{
    \\  "schemaVersion": 2,
    \\  "scripts": [
    \\    { "scriptId": 7, "source": "scripts/patrol.luau" }
    \\  ]
    \\}
;

const patrol_source =
    \\--!strict
    \\local minY = kadath.parameter.number("minY", { default = 1, min = -100, max = 100 })
    \\local maxY = kadath.parameter.number("maxY", { default = 9, min = -100, max = 100 })
    \\local speed = kadath.parameter.number("speed", { default = 80, min = 0, max = 1000 })
    \\return {
    \\    on_start = function(self: Kadath.Object)
    \\        self:translate(minY, maxY)
    \\        self:translate(0, speed)
    \\    end,
    \\}
;

fn makePackage() !struct { tmp: std.testing.TmpDir, package: runtime.Package, snapshot: manifest.SourceSnapshot } {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "scripts", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "scripts/patrol.luau", .data = patrol_source });
    var snapshot = try manifest.loadSnapshot(std.testing.io, std.testing.allocator, tmp.dir, source_manifest);
    errdefer snapshot.deinit();
    var diagnostic = builder.Diagnostic{};
    var built = try builder.build(std.testing.allocator, &snapshot, &diagnostic);
    defer built.deinit();
    var runtime_diagnostic = runtime.Diagnostic{};
    const package = try runtime.Package.init(
        std.testing.allocator,
        built.bytes,
        runtime.default_asset_memory_limit,
        runtime.default_interrupt_limit,
        &runtime_diagnostic,
    );
    return .{ .tmp = tmp, .package = package, .snapshot = snapshot };
}

test "Scene Binding expands defaults and preserves source order" {
    var fixture = try makePackage();
    defer {
        fixture.package.deinit();
        fixture.snapshot.deinit();
        fixture.tmp.cleanup();
    }

    const set = try scene_binding.normalize(&fixture.package.parsed, &.{
        .{
            .object_id = "hazard-1",
            .position = .{ 10, 20 },
            .bindings = &.{.{ .script_id = 7, .parameters = &.{.{ .name = "speed", .value = 10 }} }},
        },
        .{
            .object_id = "hazard-2",
            .position = .{ 30, 40 },
            .bindings = &.{.{ .script_id = 7, .parameters = &.{
                .{ .name = "maxY", .value = 8 },
                .{ .name = "minY", .value = 2 },
            } }},
        },
    });
    try std.testing.expectEqual(@as(usize, 2), set.binding_count);
    try std.testing.expectEqualStrings("hazard-1", set.bindings[0].objectId());
    try std.testing.expectEqual(@as(usize, 0), set.bindings[0].object_ordinal);
    try std.testing.expectEqual(@as(usize, 0), set.bindings[0].binding_ordinal);
    try std.testing.expectEqualStrings("minY", set.bindings[0].parameters[0].name());
    try std.testing.expectEqual(@as(f64, 1), set.bindings[0].parameters[0].value);
    try std.testing.expectEqualStrings("maxY", set.bindings[0].parameters[1].name());
    try std.testing.expectEqual(@as(f64, 9), set.bindings[0].parameters[1].value);
    try std.testing.expectEqualStrings("speed", set.bindings[0].parameters[2].name());
    try std.testing.expectEqual(@as(f64, 10), set.bindings[0].parameters[2].value);
    try std.testing.expectEqual(@as(f64, 2), set.bindings[1].parameters[0].value);
    try std.testing.expectEqual(@as(f64, 8), set.bindings[1].parameters[1].value);
    try std.testing.expectEqual(@as(f64, 80), set.bindings[1].parameters[2].value);

    var diagnostic = runtime.Diagnostic{};
    var prepared = try set.prepare(&fixture.package, &diagnostic);
    defer prepared.deinit();
    try std.testing.expectEqual(@as(usize, 2), prepared.binding_count);
    try std.testing.expectApproxEqAbs(@as(f64, 1), prepared.bindings[0].?.commands[0].dx, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 9), prepared.bindings[0].?.commands[0].dy, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 10), prepared.bindings[0].?.commands[1].dy, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 2), prepared.bindings[1].?.commands[0].dx, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 8), prepared.bindings[1].?.commands[0].dy, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 80), prepared.bindings[1].?.commands[1].dy, 0.0001);
}

test "Scene Binding rejects invalid references and parameter overrides" {
    var fixture = try makePackage();
    defer {
        fixture.package.deinit();
        fixture.snapshot.deinit();
        fixture.tmp.cleanup();
    }
    const package = &fixture.package.parsed;

    try std.testing.expectError(error.MissingScriptId, scene_binding.normalize(package, &.{.{
        .object_id = "hazard-1",
        .position = .{ 0, 0 },
        .bindings = &.{.{ .script_id = 999 }},
    }}));
    try std.testing.expectError(error.UnknownBehaviorParameter, scene_binding.normalize(package, &.{.{
        .object_id = "hazard-1",
        .position = .{ 0, 0 },
        .bindings = &.{.{ .script_id = 7, .parameters = &.{.{ .name = "unknown", .value = 1 }} }},
    }}));
    try std.testing.expectError(error.BehaviorParameterOutOfRange, scene_binding.normalize(package, &.{.{
        .object_id = "hazard-1",
        .position = .{ 0, 0 },
        .bindings = &.{.{ .script_id = 7, .parameters = &.{.{ .name = "speed", .value = 1001 }} }},
    }}));
    try std.testing.expectError(error.DuplicateBehaviorParameter, scene_binding.normalize(package, &.{.{
        .object_id = "hazard-1",
        .position = .{ 0, 0 },
        .bindings = &.{.{ .script_id = 7, .parameters = &.{
            .{ .name = "speed", .value = 1 },
            .{ .name = "speed", .value = 2 },
        } }},
    }}));
    try std.testing.expectError(error.DuplicateBehaviorBinding, scene_binding.normalize(package, &.{.{
        .object_id = "hazard-1",
        .position = .{ 0, 0 },
        .bindings = &.{ .{ .script_id = 7 }, .{ .script_id = 7 } },
    }}));
}

test "Scene Binding enforces per-object and aggregate limits" {
    var package = artifact.Package{ .entry_count = 5 };
    for (package.entries[0..5], 0..) |*entry, index| entry.script_id = @intCast(index + 1);

    try std.testing.expectError(error.ObjectBindingCountExceeded, scene_binding.normalize(&package, &.{.{
        .object_id = "hazard-1",
        .position = .{ 0, 0 },
        .bindings = &.{
            .{ .script_id = 1 },
            .{ .script_id = 2 },
            .{ .script_id = 3 },
            .{ .script_id = 4 },
            .{ .script_id = 5 },
        },
    }}));

    var object_ids: [65][16]u8 = undefined;
    var binding_lists: [65][4]scene_binding.BindingInput = undefined;
    var objects: [65]scene_binding.ObjectInput = undefined;
    for (&objects, 0..) |*object, index| {
        const object_id = try std.fmt.bufPrint(&object_ids[index], "object-{d}", .{index});
        binding_lists[index] = .{
            .{ .script_id = 1 },
            .{ .script_id = 2 },
            .{ .script_id = 3 },
            .{ .script_id = 4 },
        };
        object.* = .{
            .object_id = object_id,
            .position = .{ 0, 0 },
            .bindings = &binding_lists[index],
        };
    }
    try std.testing.expectError(error.BehaviorBindingCountExceeded, scene_binding.normalize(&package, &objects));
}
