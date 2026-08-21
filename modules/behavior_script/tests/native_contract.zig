const std = @import("std");
const runtime = @import("behavior_runtime");
const tooling = @import("behavior_tooling");

const c = @cImport({
    @cInclude("kadath_luau.h");
});

const HostV4TestContext = struct {
    position: [2]f64 = .{ 3, 4 },
    set_calls: usize = 0,
    posted_events: usize = 0,
    spawned_objects: usize = 0,
    destroyed_objects: usize = 0,
    last_event_name: [64]u8 = [_]u8{0} ** 64,
    last_event_name_bytes: u8 = 0,
    return_invalid_object: bool = false,
};

fn hostV3Resolve(
    userdata: ?*anyopaque,
    object_id: [*c]const u8,
    object_id_length: usize,
    out_object: ?*c.KadathLuauObjectHandle,
) callconv(.c) c_int {
    const context: *HostV4TestContext = @ptrCast(@alignCast(userdata orelse return 0));
    const id = object_id[0..object_id_length];
    const is_player = std.mem.eql(u8, id, "player");
    const is_transient = std.mem.eql(u8, id, "runtime-0000000000000001");
    if (!is_player and !is_transient) return 0;
    const object = out_object orelse return 0;
    object.* = std.mem.zeroes(c.KadathLuauObjectHandle);
    object.world_epoch = 7;
    object.logical_generation = 1;
    object.kind = if (is_player) c.KADATH_LUAU_OBJECT_PLAYER else c.KADATH_LUAU_OBJECT_SPRITE;
    object.object_id_length = object_id_length;
    @memcpy(object.object_id[0..object_id_length], id);
    if (context.return_invalid_object) object.object_id_length = c.KADATH_LUAU_MAX_OBJECT_ID_BYTES + 1;
    return 1;
}

fn hostV3GetPosition(
    userdata: ?*anyopaque,
    object: ?*const c.KadathLuauObjectHandle,
    out_x: ?*f64,
    out_y: ?*f64,
) callconv(.c) c_int {
    const context: *HostV4TestContext = @ptrCast(@alignCast(userdata orelse return 0));
    if (object == null or out_x == null or out_y == null) return 0;
    out_x.?.* = context.position[0];
    out_y.?.* = context.position[1];
    return 1;
}

fn hostV3SetPosition(
    userdata: ?*anyopaque,
    object: ?*const c.KadathLuauObjectHandle,
    x: f64,
    y: f64,
) callconv(.c) c_int {
    const context: *HostV4TestContext = @ptrCast(@alignCast(userdata orelse return 0));
    if (object == null or !std.math.isFinite(x) or !std.math.isFinite(y)) return 0;
    context.position = .{ x, y };
    context.set_calls += 1;
    return 1;
}

fn hostV3PostEvent(
    userdata: ?*anyopaque,
    event: ?*const c.KadathLuauPostedEvent,
) callconv(.c) c_int {
    const context: *HostV4TestContext = @ptrCast(@alignCast(userdata orelse return 0));
    const value = event orelse return 0;
    if (value.name == null or value.name_length == 0 or value.name_length > 63) return 0;
    context.posted_events += 1;
    context.last_event_name_bytes = @intCast(value.name_length);
    @memcpy(context.last_event_name[0..value.name_length], value.name[0..value.name_length]);
    return 1;
}

fn hostV4SpawnObject(
    userdata: ?*anyopaque,
    prototype_id: [*c]const u8,
    prototype_id_length: usize,
    x: f64,
    y: f64,
    out_object: ?*c.KadathLuauObjectHandle,
) callconv(.c) c_int {
    const context: *HostV4TestContext = @ptrCast(@alignCast(userdata orelse return 0));
    if (!std.mem.eql(u8, prototype_id[0..prototype_id_length], "orb") or
        !std.math.isFinite(x) or !std.math.isFinite(y)) return 0;
    const object = out_object orelse return 0;
    const object_id = "runtime-0000000000000001";
    object.* = std.mem.zeroes(c.KadathLuauObjectHandle);
    object.world_epoch = 7;
    object.logical_generation = 1;
    object.kind = c.KADATH_LUAU_OBJECT_SPRITE;
    object.object_id_length = object_id.len;
    @memcpy(object.object_id[0..object_id.len], object_id);
    context.spawned_objects += 1;
    return 1;
}

fn hostV4DestroyObject(
    userdata: ?*anyopaque,
    object: ?*const c.KadathLuauObjectHandle,
) callconv(.c) c_int {
    const context: *HostV4TestContext = @ptrCast(@alignCast(userdata orelse return 0));
    const value = object orelse return 0;
    if (value.world_epoch != 7 or value.logical_generation == 0) return 0;
    context.destroyed_objects += 1;
    return 1;
}

test "Behavior input snapshot preserves its public C layout" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(c.KadathLuauInputSnapshot));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(c.KadathLuauInputSnapshot, "move_x"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(c.KadathLuauInputSnapshot, "move_y"));
}

test "Behavior Host v4 preserves its public C layout and bounds" {
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(c.KadathLuauHostV4));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(c.KadathLuauHostV4, "version"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(c.KadathLuauHostV4, "struct_size"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(c.KadathLuauHostV4, "userdata"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(c.KadathLuauHostV4, "world_epoch"));
    try std.testing.expectEqual(@as(usize, 56), @offsetOf(c.KadathLuauHostV4, "spawn_object"));
    try std.testing.expectEqual(@as(usize, 64), @offsetOf(c.KadathLuauHostV4, "destroy_object"));
    try std.testing.expectEqual(@as(usize, 96), @sizeOf(c.KadathLuauObjectHandle));
    try std.testing.expectEqual(@as(c_int, 4), c.KADATH_LUAU_HOST_INTERFACE_VERSION);
    try std.testing.expectEqual(@as(c_int, 63), c.KADATH_LUAU_MAX_EVENT_NAME_BYTES);
    try std.testing.expectEqual(@as(c_int, 8), c.KADATH_LUAU_MAX_EVENT_FIELD_COUNT);
}

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

test "Luau Analysis accepts the Kadath Object and input host namespaces" {
    const typed_source =
        \\--!strict
        \\local speed = kadath.parameter.number("speed", { default = 80, min = 0, max = 1000 })
        \\return {
        \\    fixed_update = function(self: Kadath.Object, dt: number)
        \\        local move_x, move_y = kadath.input.move_axis()
        \\        local position = self:position()
        \\        if self:id() ~= "" then self:translate(move_x, move_y + speed * dt + position.y - position.y) end
        \\    end,
        \\    update = function(self: Kadath.Object, dt: number)
        \\        local spawned = kadath.scene.spawn("orb", 1, 2)
        \\        spawned:destroy()
        \\        local same = kadath.scene.find(self:id())
        \\        if same and same:is_valid() and same:kind() == "player" then
        \\            local position = same:position()
        \\            same:set_position(position.x + dt, position.y)
        \\        end
        \\    end,
        \\    on_event = function(self: Kadath.Object, event: Kadath.Event)
        \\        if event.other then kadath.event.post(event.other, "observed") end
        \\    end,
        \\}
    ;
    var diagnostic = tooling.Diagnostic{};
    var compiled = tooling.compile(std.testing.allocator, typed_source, "typed.luau", &diagnostic) catch |err| {
        std.debug.print("typed Host v4 diagnostic: {s}\n", .{diagnostic.slice()});
        return err;
    };
    defer compiled.deinit();
    try std.testing.expectEqual(@as(u8, 1), compiled.parameter_count);
}

test "Luau tooling accepts the complete Host v4 hook set" {
    const source =
        \\--!strict
        \\return {
        \\    on_start = function(self: Kadath.Object) end,
        \\    fixed_update = function(self: Kadath.Object, dt: number) end,
        \\    update = function(self: Kadath.Object, dt: number) end,
        \\    on_event = function(self: Kadath.Object, event: Kadath.Event) end,
        \\}
    ;
    var diagnostic = tooling.Diagnostic{};
    var compiled = tooling.compile(std.testing.allocator, source, "host-v4-hooks.luau", &diagnostic) catch |err| {
        std.debug.print("Host v4 hook diagnostic: {s}\n", .{diagnostic.slice()});
        return err;
    };
    defer compiled.deinit();
    try std.testing.expect(compiled.bytecode.len > 0);
}

test "Luau Host v4 update directly mutates objects and submits lifecycle requests" {
    const source =
        \\return {
        \\    update = function(self: Kadath.Object, dt: number)
        \\        local position = self:position()
        \\        self:set_position(position.x + dt, position.y - dt)
        \\        local spawned = kadath.scene.spawn("orb", 1, 2)
        \\        spawned:destroy()
        \\    end,
        \\}
    ;
    var diagnostic = tooling.Diagnostic{};
    var compiled = tooling.compile(std.testing.allocator, source, "host-v4-update.luau", &diagnostic) catch |err| {
        std.debug.print("Host v4 update diagnostic: {s}\n", .{diagnostic.slice()});
        return err;
    };
    defer compiled.deinit();

    var error_buffer: [256]u8 = undefined;
    const asset = c.kadath_luau_asset_create(
        compiled.bytecode.ptr,
        compiled.bytecode.len,
        2 * 1024 * 1024,
        100_000,
        &error_buffer,
        error_buffer.len,
    ) orelse return error.TestUnexpectedResult;
    defer c.kadath_luau_asset_destroy(asset);
    const object_id = "player";
    const instance = c.kadath_luau_instance_create(
        asset,
        object_id.ptr,
        object_id.len,
        null,
        0,
        &error_buffer,
        error_buffer.len,
    ) orelse return error.TestUnexpectedResult;
    defer c.kadath_luau_instance_destroy(instance);

    var context = HostV4TestContext{};
    var host = c.KadathLuauHostV4{
        .version = c.KADATH_LUAU_HOST_INTERFACE_VERSION,
        .struct_size = @sizeOf(c.KadathLuauHostV4),
        .userdata = &context,
        .world_epoch = 7,
        .resolve_object = hostV3Resolve,
        .get_object_position = hostV3GetPosition,
        .set_object_position = hostV3SetPosition,
        .post_event = hostV3PostEvent,
        .spawn_object = hostV4SpawnObject,
        .destroy_object = hostV4DestroyObject,
    };
    const input = c.KadathLuauInputSnapshot{ .move_x = 0, .move_y = 0 };
    try std.testing.expectEqual(
        @as(c_int, 1),
        c.kadath_luau_instance_update_v4(instance, 0.5, &input, &host, &error_buffer, error_buffer.len),
    );
    try std.testing.expectEqual(@as(usize, 1), context.set_calls);
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), context.position[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), context.position[1], 0.0001);
    try std.testing.expectEqual(@as(usize, 1), context.spawned_objects);
    try std.testing.expectEqual(@as(usize, 1), context.destroyed_objects);

    host.version = 2;
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.kadath_luau_instance_update_v4(instance, 0.5, &input, &host, &error_buffer, error_buffer.len),
    );
    try std.testing.expectEqual(@as(usize, 1), context.set_calls);

    host.version = 4;
    host.struct_size = 0;
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.kadath_luau_instance_update_v4(instance, 0.5, &input, &host, &error_buffer, error_buffer.len),
    );
    try std.testing.expectEqual(@as(usize, 1), context.set_calls);

    host.struct_size = @sizeOf(c.KadathLuauHostV4);
    context.return_invalid_object = true;
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.kadath_luau_instance_update_v4(instance, 0.5, &input, &host, &error_buffer, error_buffer.len),
    );
    try std.testing.expectEqual(@as(usize, 1), context.set_calls);
}

test "Luau Host v4 posts and receives one bounded frame event" {
    const source =
        \\--!strict
        \\return {
        \\    update = function(self: Kadath.Object, dt: number)
        \\        if dt == 0 then
        \\            local forged = { __kadath_object_id = "player", __kadath_world_epoch = 0 / 0, __kadath_logical_generation = 1 } :: any
        \\            kadath.event.post(forged, "invalid")
        \\            return
        \\        end
        \\        kadath.event.post(self, "ping")
        \\    end,
        \\    on_event = function(self: Kadath.Object, event: Kadath.Event)
        \\        if event.name == "ping" and event.domain == "frame" then self:translate(2, 0) end
        \\    end,
        \\}
    ;
    var diagnostic = tooling.Diagnostic{};
    var compiled = try tooling.compile(std.testing.allocator, source, "host-v4-event.luau", &diagnostic);
    defer compiled.deinit();
    var error_buffer: [256]u8 = undefined;
    const asset = c.kadath_luau_asset_create(compiled.bytecode.ptr, compiled.bytecode.len, 2 * 1024 * 1024, 100_000, &error_buffer, error_buffer.len) orelse return error.TestUnexpectedResult;
    defer c.kadath_luau_asset_destroy(asset);
    const object_id = "player";
    const instance = c.kadath_luau_instance_create(asset, object_id.ptr, object_id.len, null, 0, &error_buffer, error_buffer.len) orelse return error.TestUnexpectedResult;
    defer c.kadath_luau_instance_destroy(instance);
    var context = HostV4TestContext{};
    const host = c.KadathLuauHostV4{
        .version = 4,
        .struct_size = @sizeOf(c.KadathLuauHostV4),
        .userdata = &context,
        .world_epoch = 7,
        .resolve_object = hostV3Resolve,
        .get_object_position = hostV3GetPosition,
        .set_object_position = hostV3SetPosition,
        .post_event = hostV3PostEvent,
        .spawn_object = hostV4SpawnObject,
        .destroy_object = hostV4DestroyObject,
    };
    const input = c.KadathLuauInputSnapshot{ .move_x = 0, .move_y = 0 };
    try std.testing.expectEqual(@as(c_int, 1), c.kadath_luau_instance_update_v4(instance, 0.25, &input, &host, &error_buffer, error_buffer.len));
    try std.testing.expectEqual(@as(usize, 1), context.posted_events);
    try std.testing.expectEqualStrings("ping", context.last_event_name[0..context.last_event_name_bytes]);
    try std.testing.expectEqual(@as(c_int, 0), c.kadath_luau_instance_update_v4(instance, 0, &input, &host, &error_buffer, error_buffer.len));
    try std.testing.expectEqual(@as(usize, 1), context.posted_events);

    const event_name = "ping";
    var payload_key = [_]u8{'x'};
    var fields = [_]c.KadathLuauEventField{.{
        .key = &payload_key,
        .key_length = payload_key.len,
        .value = .{
            .kind = c.KADATH_LUAU_EVENT_BOOLEAN,
            .boolean_value = 1,
            .number_value = 0,
            .string_value = null,
            .string_value_length = 0,
            .object_value = std.mem.zeroes(c.KadathLuauObjectHandle),
        },
    }};
    var event = c.KadathLuauEvent{
        .name = event_name.ptr,
        .name_length = event_name.len,
        .domain = c.KADATH_LUAU_EVENT_DOMAIN_FRAME,
        .has_sender = 0,
        .sender = std.mem.zeroes(c.KadathLuauObjectHandle),
        .has_other = 0,
        .other = std.mem.zeroes(c.KadathLuauObjectHandle),
        .fields = &fields,
        .field_count = fields.len,
    };
    const invalid_input = c.KadathLuauInputSnapshot{ .move_x = 2, .move_y = 0 };
    try std.testing.expectEqual(@as(c_int, 0), c.kadath_luau_instance_on_event_v4(instance, &event, &invalid_input, &host, &error_buffer, error_buffer.len));
    fields[0].value.kind = c.KADATH_LUAU_EVENT_NUMBER;
    fields[0].value.number_value = std.math.nan(f64);
    try std.testing.expectEqual(@as(c_int, 0), c.kadath_luau_instance_on_event_v4(instance, &event, &input, &host, &error_buffer, error_buffer.len));
    fields[0].value.kind = c.KADATH_LUAU_EVENT_BOOLEAN;
    fields[0].value.boolean_value = 1;
    try std.testing.expectEqual(@as(c_int, 1), c.kadath_luau_instance_on_event_v4(instance, &event, &input, &host, &error_buffer, error_buffer.len));
    try std.testing.expectApproxEqAbs(@as(f64, 5), context.position[0], 0.0001);
}

test "Luau tooling rejects top-level input reads as tooling execution errors" {
    var failure = tooling.Diagnostic{};
    const result = try tooling.analyze(
        "--!strict\nlocal move_x, move_y = kadath.input.move_axis()\nreturn {}",
        "top-level-input.luau",
        &failure,
    );
    try std.testing.expectEqual(tooling.AnalysisState.invalid, result.state);
    try std.testing.expectEqual(@as(usize, 1), result.diagnosticSlice().len);
    try std.testing.expectEqual(tooling.DiagnosticStage.tooling_execution, result.diagnosticSlice()[0].stage);
    try std.testing.expectEqual(tooling.DiagnosticCode.tooling_execution_error, result.diagnosticSlice()[0].code);
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

test "Luau structured analysis returns stable diagnostics for the submitted buffer" {
    var failure = tooling.Diagnostic{};
    const valid = try tooling.analyze(
        "--!strict\nreturn {}",
        "valid-diagnostics.luau",
        &failure,
    );
    try std.testing.expectEqual(tooling.AnalysisState.valid, valid.state);
    try std.testing.expectEqual(@as(usize, 0), valid.diagnosticSlice().len);

    const invalid = try tooling.analyze(
        "--!strict\nlocal label: string = 1\nlocal count: number = \"bad\"\nreturn {}",
        "invalid-diagnostics.luau",
        &failure,
    );
    try std.testing.expectEqual(tooling.AnalysisState.invalid, invalid.state);
    try std.testing.expect(invalid.diagnosticSlice().len >= 2);
    for (invalid.diagnosticSlice()) |diagnostic| {
        try std.testing.expectEqual(tooling.DiagnosticSeverity.err, diagnostic.severity);
        try std.testing.expectEqual(tooling.DiagnosticStage.analysis, diagnostic.stage);
        try std.testing.expectEqual(tooling.DiagnosticCode.luau_analysis_error, diagnostic.code);
        try std.testing.expect(diagnostic.message().len > 0);
        const range = diagnostic.range orelse return error.TestExpectedEqual;
        try std.testing.expect(range.start.line >= 2);
        try std.testing.expect(range.start.column >= 1);
        try std.testing.expect(range.end.line > range.start.line or range.end.column >= range.start.column);
    }

    const embedded_nul = try tooling.analyze(
        "return {}\x00return { unknown = function() end }",
        "nul-diagnostics.luau",
        &failure,
    );
    try std.testing.expectEqual(tooling.AnalysisState.invalid, embedded_nul.state);
    try std.testing.expectEqual(@as(usize, 1), embedded_nul.diagnosticSlice().len);
    const nul_diagnostic = embedded_nul.diagnosticSlice()[0];
    try std.testing.expectEqual(tooling.DiagnosticCode.luau_analysis_error, nul_diagnostic.code);
    try std.testing.expectEqual(@as(u32, 10), nul_diagnostic.range.?.start.column);
    try std.testing.expectEqual(@as(u32, 11), nul_diagnostic.range.?.end.column);
}

test "Luau analysis C ABI uses stable error codes and deterministic bytes" {
    const source = "--!strict\nlocal label: string = 1\nreturn {}";
    var first = std.mem.zeroes(c.KadathLuauAnalysisResult);
    var second = std.mem.zeroes(c.KadathLuauAnalysisResult);
    var failure: [512]u8 = undefined;
    try std.testing.expectEqual(
        @as(i32, c.KADATH_OK),
        @as(i32, c.kadath_luau_analyze(source, source.len, "abi.luau", &first, &failure, failure.len)),
    );
    try std.testing.expectEqual(
        @as(i32, c.KADATH_OK),
        @as(i32, c.kadath_luau_analyze(source, source.len, "abi.luau", &second, &failure, failure.len)),
    );
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&first), std.mem.asBytes(&second));

    const invalid_utf8 = [_]u8{0xff};
    var rejected = std.mem.zeroes(c.KadathLuauAnalysisResult);
    try std.testing.expectEqual(
        @as(i32, c.KADATH_ERR_INVALID_ARGUMENT),
        @as(i32, c.kadath_luau_analyze(&invalid_utf8, invalid_utf8.len, "abi.luau", &rejected, &failure, failure.len)),
    );
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** @sizeOf(c.KadathLuauAnalysisResult)), std.mem.asBytes(&rejected));
}

test "Luau structured analysis classifies tooling and behavior contract failures" {
    var failure = tooling.Diagnostic{};
    const cases = [_]struct {
        source: []const u8,
        stage: tooling.DiagnosticStage,
        code: tooling.DiagnosticCode,
    }{
        .{
            .source = "error(\"top-level failure\")",
            .stage = .tooling_execution,
            .code = .tooling_execution_error,
        },
        .{
            .source = "while true do end\nreturn {}",
            .stage = .tooling_execution,
            .code = .tooling_execution_budget_exceeded,
        },
        .{
            .source = "local values = table.create(1000000, 0)\nreturn {}",
            .stage = .tooling_execution,
            .code = .tooling_memory_limit_exceeded,
        },
        .{
            .source = "kadath.parameter.number(\"\", { default = 1, min = 0, max = 2 })\nreturn {}",
            .stage = .behavior_contract,
            .code = .invalid_parameter_declaration,
        },
        .{
            .source = "return { unknown = function() end }",
            .stage = .behavior_contract,
            .code = .invalid_behavior_table,
        },
        .{
            .source = "",
            .stage = .behavior_contract,
            .code = .invalid_behavior_table,
        },
    };
    for (cases, 0..) |case, index| {
        const result = try tooling.analyze(case.source, "classification.luau", &failure);
        try std.testing.expectEqual(tooling.AnalysisState.invalid, result.state);
        try std.testing.expectEqual(@as(usize, 1), result.diagnosticSlice().len);
        try std.testing.expectEqual(case.stage, result.diagnosticSlice()[0].stage);
        try std.testing.expectEqual(case.code, result.diagnosticSlice()[0].code);
        try std.testing.expect(result.diagnosticSlice()[0].range == null);
        errdefer std.log.err("classification case {d} failed", .{index});
    }
}

test "Luau analysis exposes scalar columns and a deterministic diagnostic limit" {
    var failure = tooling.Diagnostic{};
    const unicode = try tooling.analyze(
        "--!strict\nlocal emoji = \"😀\"; local value: string = 1\nreturn {}",
        "unicode-column.luau",
        &failure,
    );
    try std.testing.expectEqual(tooling.AnalysisState.invalid, unicode.state);
    try std.testing.expect(unicode.diagnosticSlice().len >= 1);
    const unicode_range = unicode.diagnosticSlice()[0].range orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u32, 2), unicode_range.start.line);
    try std.testing.expectEqual(@as(u32, 20), unicode_range.start.column);
    try std.testing.expectEqual(@as(u32, 43), unicode_range.end.column);

    const many_errors =
        "--!strict\n" ++
        "local v01: string = 1\nlocal v02: string = 2\nlocal v03: string = 3\n" ++
        "local v04: string = 4\nlocal v05: string = 5\nlocal v06: string = 6\n" ++
        "local v07: string = 7\nlocal v08: string = 8\nlocal v09: string = 9\n" ++
        "local v10: string = 10\nlocal v11: string = 11\nlocal v12: string = 12\n" ++
        "local v13: string = 13\nlocal v14: string = 14\nlocal v15: string = 15\n" ++
        "local v16: string = 16\nlocal v17: string = 17\nlocal v18: string = 18\n" ++
        "local v19: string = 19\nlocal v20: string = 20\nlocal v21: string = 21\n" ++
        "local v22: string = 22\nlocal v23: string = 23\nlocal v24: string = 24\n" ++
        "local v25: string = 25\nlocal v26: string = 26\nlocal v27: string = 27\n" ++
        "local v28: string = 28\nlocal v29: string = 29\nlocal v30: string = 30\n" ++
        "local v31: string = 31\nlocal v32: string = 32\nlocal v33: string = 33\n" ++
        "local v34: string = 34\nlocal v35: string = 35\nlocal v36: string = 36\n" ++
        "return {}";
    const limited = try tooling.analyze(many_errors, "limit.luau", &failure);
    try std.testing.expectEqual(@as(usize, tooling.max_analysis_diagnostic_count), limited.diagnosticSlice().len);
    try std.testing.expectEqual(
        tooling.DiagnosticCode.diagnostic_limit_reached,
        limited.diagnosticSlice()[tooling.max_analysis_diagnostic_count - 1].code,
    );
    try std.testing.expect(limited.diagnosticSlice()[tooling.max_analysis_diagnostic_count - 1].range == null);
}

test "Luau analysis normalizes LF and CRLF positions across BMP and supplementary scalars" {
    var failure = tooling.Diagnostic{};
    const lf = try tooling.analyze(
        "--!strict\nlocal prefix = \"界😀\"; local value: string = 1\nreturn {}",
        "lf-unicode.luau",
        &failure,
    );
    const crlf = try tooling.analyze(
        "--!strict\r\nlocal prefix = \"界😀\"; local value: string = 1\r\nreturn {}",
        "crlf-unicode.luau",
        &failure,
    );
    try std.testing.expectEqual(@as(usize, 1), lf.diagnosticSlice().len);
    try std.testing.expectEqual(@as(usize, 1), crlf.diagnosticSlice().len);
    const lf_range = lf.diagnosticSlice()[0].range orelse return error.TestExpectedEqual;
    const crlf_range = crlf.diagnosticSlice()[0].range orelse return error.TestExpectedEqual;
    try std.testing.expectEqualDeep(lf_range, crlf_range);
    try std.testing.expectEqual(@as(u32, 2), lf_range.start.line);
    try std.testing.expectEqual(@as(u32, 22), lf_range.start.column);
    try std.testing.expectEqual(@as(u32, 45), lf_range.end.column);
}

test "Luau analysis classifies compiler limit failures before tooling execution" {
    var source_buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&source_buffer);
    try writer.writeAll("return ");
    for (0..300) |index| {
        if (index != 0) try writer.writeByte(',');
        try writer.writeByte('1');
    }
    var failure = tooling.Diagnostic{};
    const result = try tooling.analyze(writer.buffered(), "compile-limit.luau", &failure);
    try std.testing.expectEqual(tooling.AnalysisState.invalid, result.state);
    try std.testing.expectEqual(@as(usize, 1), result.diagnosticSlice().len);
    try std.testing.expectEqual(tooling.DiagnosticStage.compile, result.diagnosticSlice()[0].stage);
    try std.testing.expectEqual(tooling.DiagnosticCode.luau_compile_error, result.diagnosticSlice()[0].code);
    try std.testing.expect(result.diagnosticSlice()[0].range == null);
}

test "legacy Luau compile rejects embedded NUL through the shared pipeline" {
    var failure = tooling.Diagnostic{};
    try std.testing.expectError(
        error.BehaviorCompileFailed,
        tooling.compile(
            std.testing.allocator,
            "return {}\x00return { unknown = function() end }",
            "legacy-nul.luau",
            &failure,
        ),
    );
    try std.testing.expect(std.mem.indexOf(u8, failure.slice(), "embedded NUL") != null);
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
    const first_tick = try first.fixedUpdate(0.5, .{ 0, 10 }, .{}, &commands, &diagnostic);
    try std.testing.expectEqual(@as(usize, 1), first_tick.len);
    try std.testing.expectApproxEqAbs(@as(f64, 5), first_tick[0].dy, 0.0001);
    const first_second_tick = try first.fixedUpdate(0.5, .{ 0, 15 }, .{}, &commands, &diagnostic);
    try std.testing.expectApproxEqAbs(@as(f64, -5), first_second_tick[0].dy, 0.0001);
    const second_tick = try second.fixedUpdate(0.5, .{ 0, 10 }, .{}, &commands, &diagnostic);
    try std.testing.expectApproxEqAbs(@as(f64, 10), second_tick[0].dy, 0.0001);
    try std.testing.expect(asset.memoryUsed() > 0);
}

test "Luau runtime exposes one validated input snapshot only during hooks" {
    const source =
        \\local calls = 0
        \\return {
        \\    on_start = function(self)
        \\        local move_x, move_y = kadath.input.move_axis()
        \\        self:translate(move_x, move_y)
        \\    end,
        \\    fixed_update = function(self, dt)
        \\        calls += 1
        \\        local move_x, move_y = kadath.input.move_axis()
        \\        self:translate(move_x + calls, move_y + dt - dt)
        \\    end,
        \\}
    ;
    var diagnostic = tooling.Diagnostic{};
    var compiled = try tooling.compile(std.testing.allocator, source, "input-host.luau", &diagnostic);
    defer compiled.deinit();
    var asset = try runtime.Asset.init(compiled.bytecode, 2 * 1024 * 1024, 100_000, &diagnostic);
    defer asset.deinit();
    var instance = try asset.createInstance("player", &.{}, &diagnostic);
    defer instance.deinit();

    var commands: runtime.CommandBuffer = undefined;
    const start_commands = try instance.onStart(.{ 0, 0 }, &commands, &diagnostic);
    try std.testing.expectEqual(@as(usize, 1), start_commands.len);
    try std.testing.expectEqual(@as(f64, 0), start_commands[0].dx);
    try std.testing.expectEqual(@as(f64, 0), start_commands[0].dy);

    var invalid_commands: [1]c.KadathLuauTranslateCommand = undefined;
    var invalid_count: usize = 123;
    var error_buffer: [256]u8 = undefined;
    const native_asset = c.kadath_luau_asset_create(
        compiled.bytecode.ptr,
        compiled.bytecode.len,
        2 * 1024 * 1024,
        100_000,
        &error_buffer,
        error_buffer.len,
    ) orelse return error.TestUnexpectedResult;
    defer c.kadath_luau_asset_destroy(native_asset);
    const object_id = "player";
    const native_instance = c.kadath_luau_instance_create(
        native_asset,
        object_id.ptr,
        object_id.len,
        null,
        0,
        &error_buffer,
        error_buffer.len,
    ) orelse return error.TestUnexpectedResult;
    defer c.kadath_luau_instance_destroy(native_instance);
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.kadath_luau_instance_fixed_update(
            native_instance,
            1.0 / 60.0,
            0,
            0,
            null,
            &invalid_commands,
            invalid_commands.len,
            &invalid_count,
            &error_buffer,
            error_buffer.len,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), invalid_count);

    invalid_count = 123;
    const invalid_input = c.KadathLuauInputSnapshot{ .move_x = 2, .move_y = 0 };
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.kadath_luau_instance_fixed_update(
            native_instance,
            1.0 / 60.0,
            0,
            0,
            &invalid_input,
            &invalid_commands,
            invalid_commands.len,
            &invalid_count,
            &error_buffer,
            error_buffer.len,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), invalid_count);

    const native_input = c.KadathLuauInputSnapshot{ .move_x = 1, .move_y = -1 };
    try std.testing.expectEqual(
        @as(c_int, 1),
        c.kadath_luau_instance_fixed_update(
            native_instance,
            1.0 / 60.0,
            0,
            0,
            &native_input,
            &invalid_commands,
            invalid_commands.len,
            &invalid_count,
            &error_buffer,
            error_buffer.len,
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), invalid_count);
    try std.testing.expectEqual(@as(f64, 2), invalid_commands[0].dx);
    try std.testing.expectEqual(@as(f64, -1), invalid_commands[0].dy);

    invalid_count = 123;
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.kadath_luau_instance_fixed_update(
            native_instance,
            1.0 / 60.0,
            0,
            0,
            null,
            &invalid_commands,
            invalid_commands.len,
            &invalid_count,
            &error_buffer,
            error_buffer.len,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), invalid_count);

    try std.testing.expectEqual(
        @as(c_int, 1),
        c.kadath_luau_instance_fixed_update(
            native_instance,
            1.0 / 60.0,
            0,
            0,
            &native_input,
            &invalid_commands,
            invalid_commands.len,
            &invalid_count,
            &error_buffer,
            error_buffer.len,
        ),
    );
    try std.testing.expectEqual(@as(f64, 3), invalid_commands[0].dx);

    const fixed_commands = try instance.fixedUpdate(
        1.0 / 60.0,
        .{ 0, 0 },
        .{ .move_x = 1, .move_y = -1 },
        &commands,
        &diagnostic,
    );
    try std.testing.expectEqual(@as(usize, 1), fixed_commands.len);
    try std.testing.expectEqual(@as(f64, 2), fixed_commands[0].dx);
    try std.testing.expectEqual(@as(f64, -1), fixed_commands[0].dy);
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
    try std.testing.expectError(error.BehaviorHookFailed, instance.fixedUpdate(1.0 / 60.0, .{ 0, 0 }, .{}, &commands, &diagnostic));
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
