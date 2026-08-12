const std = @import("std");
const runtime = @import("behavior_runtime");
const tooling = @import("behavior_tooling");

const patrol_source =
    \\local speed = kadath.parameter.number("speed", { default = 80, min = 0, max = 1000 })
    \\local direction = 1
    \\return {
    \\    on_start = function(self)
    \\        self:translate(0, 0)
    \\    end,
    \\    fixed_update = function(self, dt)
    \\        self:translate(0, speed * direction * dt)
    \\        direction = -direction
    \\    end,
    \\}
;

test "Luau tooling extracts bounded number schema" {
    var diagnostic = tooling.Diagnostic{};
    var compiled = try tooling.compile(std.testing.allocator, patrol_source, "patrol.luau", &diagnostic);
    defer compiled.deinit();
    try std.testing.expectEqualStrings("luau-0.732-decb2d0", tooling.toolchainIdentity());
    try std.testing.expectEqual(@as(u8, 1), compiled.parameter_count);
    try std.testing.expectEqualStrings("speed", compiled.parameters[0].name());
    try std.testing.expectEqual(@as(f64, 80), compiled.parameters[0].default_value);
    try std.testing.expect(compiled.bytecode.len > 0);
}

test "Luau Analysis accepts the Kadath Object type namespace" {
    const typed_source =
        \\--!strict
        \\local speed = kadath.parameter.number("speed", { default = 80, min = 0, max = 1000 })
        \\return {
        \\    fixed_update = function(self: Kadath.Object, dt: number)
        \\        local position = self:position()
        \\        if self:id() ~= "" then self:translate(0, speed * dt + position.y - position.y) end
        \\    end,
        \\}
    ;
    var diagnostic = tooling.Diagnostic{};
    var compiled = try tooling.compile(std.testing.allocator, typed_source, "typed.luau", &diagnostic);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(u8, 1), compiled.parameter_count);
}

test "Luau Analysis rejects type errors and forbidden globals" {
    var diagnostic = tooling.Diagnostic{};
    try std.testing.expectError(
        error.BehaviorCompileFailed,
        tooling.compile(
            std.testing.allocator,
            "--!strict\nlocal value: string = 1\nreturn {}",
            "type-error.luau",
            &diagnostic,
        ),
    );
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.slice(), "Type") != null or diagnostic.slice().len != 0);

    try std.testing.expectError(
        error.BehaviorCompileFailed,
        tooling.compile(
            std.testing.allocator,
            "--!strict\nreturn { fixed_update = function() os.clock() end }",
            "forbidden.luau",
            &diagnostic,
        ),
    );
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.slice(), "os") != null);
}

test "Luau runtime isolates binding closure and parameter values" {
    var diagnostic = tooling.Diagnostic{};
    var compiled = try tooling.compile(std.testing.allocator, patrol_source, "patrol.luau", &diagnostic);
    defer compiled.deinit();
    var asset = try runtime.Asset.init(compiled.bytecode, 2 * 1024 * 1024, 100_000, &diagnostic);
    defer asset.deinit();
    var first = try asset.createInstance("hazard-1", &.{.{ .name = "speed", .value = 10 }}, &diagnostic);
    defer first.deinit();
    var second = try asset.createInstance("hazard-2", &.{.{ .name = "speed", .value = 20 }}, &diagnostic);
    defer second.deinit();

    var commands: runtime.CommandBuffer = undefined;
    const first_tick = try first.fixedUpdate(0.5, .{ 0, 10 }, &commands, &diagnostic);
    try std.testing.expectEqual(@as(usize, 1), first_tick.len);
    try std.testing.expectApproxEqAbs(@as(f64, 5), first_tick[0].dy, 0.0001);
    const first_second_tick = try first.fixedUpdate(0.5, .{ 0, 15 }, &commands, &diagnostic);
    try std.testing.expectApproxEqAbs(@as(f64, -5), first_second_tick[0].dy, 0.0001);
    const second_tick = try second.fixedUpdate(0.5, .{ 0, 10 }, &commands, &diagnostic);
    try std.testing.expectApproxEqAbs(@as(f64, 10), second_tick[0].dy, 0.0001);
    try std.testing.expect(asset.memoryUsed() > 0);
}

test "Luau tooling rejects invalid behavior contract" {
    var diagnostic = tooling.Diagnostic{};
    try std.testing.expectError(
        error.BehaviorCompileFailed,
        tooling.compile(std.testing.allocator, "return { unknown = function() end }", "invalid.luau", &diagnostic),
    );
    try std.testing.expect(diagnostic.slice().len > 0);
}

test "Luau tooling bounds top-level execution" {
    var diagnostic = tooling.Diagnostic{};
    try std.testing.expectError(
        error.BehaviorCompileFailed,
        tooling.compile(
            std.testing.allocator,
            "while true do end\nreturn {}",
            "runaway-tooling.luau",
            &diagnostic,
        ),
    );
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.slice(), "execution budget") != null);
}

test "Luau tooling bounds top-level memory" {
    var diagnostic = tooling.Diagnostic{};
    try std.testing.expectError(
        error.BehaviorCompileFailed,
        tooling.compile(
            std.testing.allocator,
            "local values = table.create(1000000, 0)\nreturn {}",
            "memory-tooling.luau",
            &diagnostic,
        ),
    );
    try std.testing.expect(diagnostic.slice().len > 0);
}

test "Luau runtime interrupts runaway hooks" {
    const source =
        \\return {
        \\    fixed_update = function(self, dt)
        \\        while true do end
        \\    end,
        \\}
    ;
    var diagnostic = tooling.Diagnostic{};
    var compiled = try tooling.compile(std.testing.allocator, source, "runaway.luau", &diagnostic);
    defer compiled.deinit();
    var asset = try runtime.Asset.init(compiled.bytecode, 2 * 1024 * 1024, 100, &diagnostic);
    defer asset.deinit();
    var instance = try asset.createInstance("hazard-1", &.{}, &diagnostic);
    defer instance.deinit();
    var commands: runtime.CommandBuffer = undefined;
    try std.testing.expectError(error.BehaviorHookFailed, instance.fixedUpdate(1.0 / 60.0, .{ 0, 0 }, &commands, &diagnostic));
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.slice(), "budget") != null);
}

test "Luau runtime enforces the frozen per-hook command budget" {
    const source =
        \\return {
        \\    on_start = function(self)
        \\        for _ = 1, 17 do
        \\            self:translate(1, 0)
        \\        end
        \\    end,
        \\}
    ;
    var diagnostic = tooling.Diagnostic{};
    var compiled = try tooling.compile(std.testing.allocator, source, "command-budget.luau", &diagnostic);
    defer compiled.deinit();
    var asset = try runtime.Asset.init(compiled.bytecode, 2 * 1024 * 1024, 100_000, &diagnostic);
    defer asset.deinit();
    var instance = try asset.createInstance("hazard-1", &.{}, &diagnostic);
    defer instance.deinit();
    var commands: runtime.CommandBuffer = undefined;
    try std.testing.expectError(error.BehaviorHookFailed, instance.onStart(.{ 0, 0 }, &commands, &diagnostic));
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.slice(), "command budget") != null);
}

test "Luau runtime rejects invalid direct parameter values" {
    var diagnostic = tooling.Diagnostic{};
    var compiled = try tooling.compile(std.testing.allocator, patrol_source, "patrol.luau", &diagnostic);
    defer compiled.deinit();
    var asset = try runtime.Asset.init(compiled.bytecode, 2 * 1024 * 1024, 100_000, &diagnostic);
    defer asset.deinit();

    try std.testing.expectError(
        error.InvalidBehaviorParameter,
        asset.createInstance("hazard-1", &.{.{ .name = "bad-name", .value = 1 }}, &diagnostic),
    );
    try std.testing.expectError(
        error.InvalidBehaviorParameter,
        asset.createInstance("hazard-1", &.{.{ .name = "speed", .value = std.math.nan(f64) }}, &diagnostic),
    );
    try std.testing.expectError(
        error.DuplicateBehaviorParameter,
        asset.createInstance("hazard-1", &.{
            .{ .name = "speed", .value = 1 },
            .{ .name = "speed", .value = 2 },
        }, &diagnostic),
    );
}
