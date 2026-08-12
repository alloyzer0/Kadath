const std = @import("std");
const builder = @import("behavior_package_builder");
const manifest = @import("behavior_manifest");
const runtime = @import("behavior_runtime");

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
    \\local speed = kadath.parameter.number("speed", { default = 80, min = 0, max = 1000 })
    \\local direction = 1
    \\return {
    \\    on_start = function(self: Kadath.Object)
    \\        self:translate(1, 0)
    \\    end,
    \\    fixed_update = function(self: Kadath.Object, dt: number)
    \\        self:translate(0, speed * direction * dt)
    \\        direction = -direction
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

test "Runtime Package creates isolated binding instances from one entry" {
    var fixture = try makePackage();
    defer {
        fixture.package.deinit();
        fixture.snapshot.deinit();
        fixture.tmp.cleanup();
    }
    var diagnostic = runtime.Diagnostic{};
    var prepared = try fixture.package.prepareBindings(&.{
        .{ .script_id = 7, .object_id = "hazard-1", .parameters = &.{.{ .name = "speed", .value = 10 }}, .position = .{ 0, 10 } },
        .{ .script_id = 7, .object_id = "hazard-2", .parameters = &.{.{ .name = "speed", .value = 20 }}, .position = .{ 0, 20 } },
    }, &diagnostic);
    defer prepared.deinit();
    try std.testing.expectEqual(@as(usize, 2), prepared.binding_count);

    var first = &prepared.bindings[0].?;
    var second = &prepared.bindings[1].?;
    var first_commands: runtime.CommandBuffer = undefined;
    var second_commands: runtime.CommandBuffer = undefined;
    const first_tick = try first.instance.fixedUpdate(0.5, .{ 0, 10 }, &first_commands, &diagnostic);
    const second_tick = try second.instance.fixedUpdate(0.5, .{ 0, 20 }, &second_commands, &diagnostic);
    try std.testing.expectApproxEqAbs(@as(f64, 5), first_tick[0].dy, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 10), second_tick[0].dy, 0.0001);
    const first_reverse = try first.instance.fixedUpdate(0.5, .{ 0, 15 }, &first_commands, &diagnostic);
    const second_reverse = try second.instance.fixedUpdate(0.5, .{ 0, 30 }, &second_commands, &diagnostic);
    try std.testing.expectApproxEqAbs(@as(f64, -5), first_reverse[0].dy, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, -10), second_reverse[0].dy, 0.0001);
}

test "Runtime Package validates binding identity and parameter ranges before VM work" {
    var fixture = try makePackage();
    defer {
        fixture.package.deinit();
        fixture.snapshot.deinit();
        fixture.tmp.cleanup();
    }
    var diagnostic = runtime.Diagnostic{};
    try std.testing.expectError(
        error.UnknownBehaviorParameter,
        fixture.package.prepareBindings(&.{.{
            .script_id = 7,
            .object_id = "hazard-1",
            .parameters = &.{.{ .name = "unknown", .value = 1 }},
            .position = .{ 0, 0 },
        }}, &diagnostic),
    );
    try std.testing.expectError(
        error.BehaviorParameterOutOfRange,
        fixture.package.prepareBindings(&.{.{
            .script_id = 7,
            .object_id = "hazard-1",
            .parameters = &.{.{ .name = "speed", .value = 1001 }},
            .position = .{ 0, 0 },
        }}, &diagnostic),
    );
    try std.testing.expectError(
        error.DuplicateBehaviorBinding,
        fixture.package.prepareBindings(&.{
            .{ .script_id = 7, .object_id = "hazard-1", .position = .{ 0, 0 } },
            .{ .script_id = 7, .object_id = "hazard-1", .position = .{ 0, 0 } },
        }, &diagnostic),
    );
    try std.testing.expectError(
        error.MissingScriptId,
        fixture.package.prepareBindings(&.{.{ .script_id = 999, .object_id = "hazard-1", .position = .{ 0, 0 } }}, &diagnostic),
    );
}

test "ActiveSet preserves binding order and tick-start snapshots" {
    var fixture = try makePackage();
    defer {
        fixture.package.deinit();
        fixture.snapshot.deinit();
        fixture.tmp.cleanup();
    }
    var diagnostic = runtime.Diagnostic{};
    var prepared = try fixture.package.prepareBindings(&.{
        .{ .script_id = 7, .object_id = "hazard-1", .parameters = &.{.{ .name = "speed", .value = 10 }}, .position = .{ 0, 10 } },
        .{ .script_id = 7, .object_id = "hazard-2", .parameters = &.{.{ .name = "speed", .value = 20 }}, .position = .{ 0, 20 } },
    }, &diagnostic);
    defer prepared.deinit();
    var active = prepared.activate();
    defer active.deinit();

    const start_commands = active.onStartCommands();
    try std.testing.expectEqual(@as(usize, 2), start_commands.len);
    try std.testing.expectEqualStrings("hazard-1", active.commandObjectId(start_commands[0]));
    try std.testing.expectEqualStrings("hazard-2", active.commandObjectId(start_commands[1]));

    try active.runFixed(0.5, &.{
        .{ .object_id = "hazard-1", .position = .{ 0, 10 } },
        .{ .object_id = "hazard-2", .position = .{ 0, 20 } },
    });
    const commands = active.commandSlice();
    try std.testing.expectEqual(@as(usize, 2), commands.len);
    try std.testing.expectEqualStrings("hazard-1", active.commandObjectId(commands[0]));
    try std.testing.expectApproxEqAbs(@as(f64, 5), commands[0].dy, 0.0001);
    try std.testing.expectEqualStrings("hazard-2", active.commandObjectId(commands[1]));
    try std.testing.expectApproxEqAbs(@as(f64, 10), commands[1].dy, 0.0001);
}

test "ActiveSet disables one failed binding and continues the rest" {
    var fixture = try makePackage();
    defer {
        fixture.package.deinit();
        fixture.snapshot.deinit();
        fixture.tmp.cleanup();
    }
    var diagnostic = runtime.Diagnostic{};
    var prepared = try fixture.package.prepareBindings(&.{
        .{ .script_id = 7, .object_id = "hazard-1", .parameters = &.{.{ .name = "speed", .value = 10 }}, .position = .{ 0, 10 } },
        .{ .script_id = 7, .object_id = "hazard-2", .parameters = &.{.{ .name = "speed", .value = 20 }}, .position = .{ 0, 20 } },
    }, &diagnostic);
    defer prepared.deinit();
    var active = prepared.activate();
    defer active.deinit();

    try active.runFixed(0.5, &.{.{ .object_id = "hazard-2", .position = .{ 0, 20 } }});
    try std.testing.expectEqual(@as(usize, 1), active.failureSlice().len);
    try std.testing.expectEqualStrings("MissingBehaviorObjectSnapshot", active.failureSlice()[0].errorName());
    try std.testing.expect(!active.bindingEnabled(0));
    try std.testing.expect(active.bindingEnabled(1));
    try std.testing.expectEqual(@as(usize, 1), active.commandSlice().len);
    try std.testing.expectEqualStrings("hazard-2", active.commandObjectId(active.commandSlice()[0]));

    try active.runFixed(0.5, &.{.{ .object_id = "hazard-2", .position = .{ 0, 30 } }});
    try std.testing.expectEqual(@as(usize, 0), active.failureSlice().len);
    try std.testing.expectEqual(@as(usize, 1), active.commandSlice().len);
}
