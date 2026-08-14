const std = @import("std");
const runtime = @import("behavior_runtime");
const tooling = @import("behavior_tooling");

const c = @cImport({
    @cInclude("kadath_luau.h");
});

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
