const std = @import("std");
const common = @import("behavior_common");

const c = @cImport({
    @cInclude("kadath_luau.h");
});

pub const Diagnostic = common.Diagnostic;
pub const ParameterSchema = common.ParameterSchema;
pub const max_parameter_count = common.max_parameter_count;
pub const max_analysis_diagnostic_count: usize = c.KADATH_LUAU_MAX_ANALYSIS_DIAGNOSTIC_COUNT;
pub const max_analysis_message_bytes: usize = c.KADATH_LUAU_MAX_ANALYSIS_MESSAGE_BYTES;

pub const AnalysisState = enum {
    valid,
    invalid,
};

pub const DiagnosticSeverity = enum {
    err,
};

pub const DiagnosticStage = enum {
    analysis,
    compile,
    tooling_execution,
    behavior_contract,
};

pub const DiagnosticCode = enum {
    luau_analysis_error,
    luau_analysis_budget_exceeded,
    luau_compile_error,
    tooling_execution_error,
    tooling_execution_budget_exceeded,
    tooling_memory_limit_exceeded,
    invalid_parameter_declaration,
    invalid_behavior_table,
    diagnostic_limit_reached,
};

pub const SourcePosition = struct {
    line: u32,
    column: u32,
};

pub const SourceRange = struct {
    start: SourcePosition,
    end: SourcePosition,
};

pub const AnalysisDiagnostic = struct {
    severity: DiagnosticSeverity,
    stage: DiagnosticStage,
    code: DiagnosticCode,
    range: ?SourceRange,
    message_storage: [max_analysis_message_bytes]u8 = [_]u8{0} ** max_analysis_message_bytes,
    message_bytes: u16 = 0,

    pub fn message(self: *const AnalysisDiagnostic) []const u8 {
        return self.message_storage[0..self.message_bytes];
    }
};

pub const AnalysisResult = struct {
    state: AnalysisState,
    diagnostics: [max_analysis_diagnostic_count]AnalysisDiagnostic = undefined,
    diagnostic_count: u8 = 0,

    pub fn diagnosticSlice(self: *const AnalysisResult) []const AnalysisDiagnostic {
        return self.diagnostics[0..self.diagnostic_count];
    }
};

pub const CompiledScript = struct {
    allocator: std.mem.Allocator,
    bytecode: []u8,
    parameters: [max_parameter_count]ParameterSchema = [_]ParameterSchema{.{}} ** max_parameter_count,
    parameter_count: u8 = 0,

    pub fn deinit(self: *CompiledScript) void {
        self.allocator.free(self.bytecode);
        self.* = undefined;
    }

    pub fn parameterSlice(self: *const CompiledScript) []const ParameterSchema {
        return self.parameters[0..self.parameter_count];
    }
};

pub fn toolchainIdentity() []const u8 {
    return std.mem.span(c.kadath_luau_toolchain_identity());
}

pub fn analyze(
    source: []const u8,
    chunk_name: [:0]const u8,
    failure: *Diagnostic,
) !AnalysisResult {
    failure.clear();
    var native_result = std.mem.zeroes(c.KadathLuauAnalysisResult);
    if (c.kadath_luau_analyze(
        source.ptr,
        source.len,
        chunk_name.ptr,
        &native_result,
        &failure.storage,
        failure.storage.len,
    ) != c.KADATH_OK) {
        failure.refresh();
        return error.BehaviorAnalysisFailed;
    }
    if (native_result.diagnostic_count > max_analysis_diagnostic_count) return error.InvalidBehaviorAnalysisOutput;
    var result = AnalysisResult{
        .state = try analysisState(native_result.state),
        .diagnostic_count = @intCast(native_result.diagnostic_count),
    };
    for (0..native_result.diagnostic_count) |index| {
        const native = native_result.diagnostics[index];
        if (native.message_bytes == 0 or native.message_bytes > max_analysis_message_bytes) {
            return error.InvalidBehaviorAnalysisOutput;
        }
        const native_message = native.message[0..native.message_bytes];
        if (native.message[native.message_bytes] != 0 or
            std.mem.indexOfScalar(u8, native_message, 0) != null or
            !std.unicode.utf8ValidateSlice(native_message))
        {
            return error.InvalidBehaviorAnalysisOutput;
        }
        const stage = try diagnosticStage(native.stage);
        const code = try diagnosticCode(native.code);
        if (!validDiagnosticCode(stage, code)) return error.InvalidBehaviorAnalysisOutput;
        const range: ?SourceRange = switch (native.range.has_range) {
            0 => if (positionIsZero(native.range.start) and positionIsZero(native.range.end))
                null
            else
                return error.InvalidBehaviorAnalysisOutput,
            1 => if (validRange(native.range)) .{
                .start = .{ .line = native.range.start.line, .column = native.range.start.column },
                .end = .{ .line = native.range.end.line, .column = native.range.end.column },
            } else return error.InvalidBehaviorAnalysisOutput,
            else => return error.InvalidBehaviorAnalysisOutput,
        };
        if ((stage == .tooling_execution or stage == .behavior_contract) and range != null) {
            return error.InvalidBehaviorAnalysisOutput;
        }
        var diagnostic = AnalysisDiagnostic{
            .severity = try diagnosticSeverity(native.severity),
            .stage = stage,
            .code = code,
            .range = range,
            .message_bytes = @intCast(native.message_bytes),
        };
        @memcpy(diagnostic.message_storage[0..native.message_bytes], native_message);
        result.diagnostics[index] = diagnostic;
    }
    if ((result.state == .valid) != (result.diagnostic_count == 0)) return error.InvalidBehaviorAnalysisOutput;
    try validateDiagnosticSet(result.diagnosticSlice());
    return result;
}

fn positionIsZero(position: c.KadathLuauSourcePosition) bool {
    return position.line == 0 and position.column == 0;
}

fn validRange(range: c.KadathLuauSourceRange) bool {
    if (range.start.line == 0 or range.start.column == 0 or range.end.line == 0 or range.end.column == 0) {
        return false;
    }
    return range.start.line < range.end.line or
        (range.start.line == range.end.line and range.start.column <= range.end.column);
}

fn validDiagnosticCode(stage: DiagnosticStage, code: DiagnosticCode) bool {
    return switch (stage) {
        .analysis => code == .luau_analysis_error or
            code == .luau_analysis_budget_exceeded or
            code == .diagnostic_limit_reached,
        .compile => code == .luau_compile_error,
        .tooling_execution => code == .tooling_execution_error or
            code == .tooling_execution_budget_exceeded or
            code == .tooling_memory_limit_exceeded,
        .behavior_contract => code == .invalid_parameter_declaration or
            code == .invalid_behavior_table,
    };
}

fn validateDiagnosticSet(diagnostics: []const AnalysisDiagnostic) !void {
    var limit_count: usize = 0;
    for (diagnostics, 0..) |diagnostic, index| {
        if (index > 0 and diagnosticLess(diagnostic, diagnostics[index - 1])) {
            return error.InvalidBehaviorAnalysisOutput;
        }
        if (diagnostic.code == .diagnostic_limit_reached) {
            limit_count += 1;
            if (diagnostics.len != max_analysis_diagnostic_count or
                index != diagnostics.len - 1 or
                diagnostic.stage != .analysis or
                diagnostic.range != null)
            {
                return error.InvalidBehaviorAnalysisOutput;
            }
        }
    }
    if (limit_count > 1) return error.InvalidBehaviorAnalysisOutput;
}

fn diagnosticLess(left: AnalysisDiagnostic, right: AnalysisDiagnostic) bool {
    if ((left.range == null) != (right.range == null)) return left.range != null;
    if (left.range != null) {
        const left_range = left.range.?;
        const right_range = right.range.?;
        const start = comparePosition(left_range.start, right_range.start);
        if (start != 0) return start < 0;
        const end = comparePosition(left_range.end, right_range.end);
        if (end != 0) return end < 0;
    }
    if (@intFromEnum(left.stage) != @intFromEnum(right.stage)) {
        return @intFromEnum(left.stage) < @intFromEnum(right.stage);
    }
    if (@intFromEnum(left.code) != @intFromEnum(right.code)) {
        return @intFromEnum(left.code) < @intFromEnum(right.code);
    }
    return std.mem.order(u8, left.message(), right.message()) == .lt;
}

fn comparePosition(left: SourcePosition, right: SourcePosition) i2 {
    if (left.line < right.line) return -1;
    if (left.line > right.line) return 1;
    if (left.column < right.column) return -1;
    if (left.column > right.column) return 1;
    return 0;
}

fn analysisState(value: u32) !AnalysisState {
    return switch (value) {
        c.KADATH_LUAU_ANALYSIS_VALID => .valid,
        c.KADATH_LUAU_ANALYSIS_INVALID => .invalid,
        else => error.InvalidBehaviorAnalysisOutput,
    };
}

fn diagnosticSeverity(value: u32) !DiagnosticSeverity {
    return switch (value) {
        c.KADATH_LUAU_DIAGNOSTIC_ERROR => .err,
        else => error.InvalidBehaviorAnalysisOutput,
    };
}

fn diagnosticStage(value: u32) !DiagnosticStage {
    return switch (value) {
        c.KADATH_LUAU_DIAGNOSTIC_ANALYSIS => .analysis,
        c.KADATH_LUAU_DIAGNOSTIC_COMPILE => .compile,
        c.KADATH_LUAU_DIAGNOSTIC_TOOLING_EXECUTION => .tooling_execution,
        c.KADATH_LUAU_DIAGNOSTIC_BEHAVIOR_CONTRACT => .behavior_contract,
        else => error.InvalidBehaviorAnalysisOutput,
    };
}

fn diagnosticCode(value: u32) !DiagnosticCode {
    return switch (value) {
        c.KADATH_LUAU_DIAGNOSTIC_LUAU_ANALYSIS_ERROR => .luau_analysis_error,
        c.KADATH_LUAU_DIAGNOSTIC_LUAU_ANALYSIS_BUDGET_EXCEEDED => .luau_analysis_budget_exceeded,
        c.KADATH_LUAU_DIAGNOSTIC_LUAU_COMPILE_ERROR => .luau_compile_error,
        c.KADATH_LUAU_DIAGNOSTIC_TOOLING_EXECUTION_ERROR => .tooling_execution_error,
        c.KADATH_LUAU_DIAGNOSTIC_TOOLING_EXECUTION_BUDGET_EXCEEDED => .tooling_execution_budget_exceeded,
        c.KADATH_LUAU_DIAGNOSTIC_TOOLING_MEMORY_LIMIT_EXCEEDED => .tooling_memory_limit_exceeded,
        c.KADATH_LUAU_DIAGNOSTIC_INVALID_PARAMETER_DECLARATION => .invalid_parameter_declaration,
        c.KADATH_LUAU_DIAGNOSTIC_INVALID_BEHAVIOR_TABLE => .invalid_behavior_table,
        c.KADATH_LUAU_DIAGNOSTIC_LIMIT_REACHED => .diagnostic_limit_reached,
        else => error.InvalidBehaviorAnalysisOutput,
    };
}

pub fn compile(
    allocator: std.mem.Allocator,
    source: []const u8,
    chunk_name: [:0]const u8,
    diagnostic: *Diagnostic,
) !CompiledScript {
    diagnostic.clear();
    var native_result = std.mem.zeroes(c.KadathLuauCompileResult);
    defer c.kadath_luau_compile_result_destroy(&native_result);
    if (c.kadath_luau_compile(
        source.ptr,
        source.len,
        chunk_name.ptr,
        &native_result,
        &diagnostic.storage,
        diagnostic.storage.len,
    ) == 0) {
        diagnostic.refresh();
        return error.BehaviorCompileFailed;
    }
    if (native_result.bytecode == null or native_result.bytecode_size == 0) return error.InvalidBehaviorCompilerOutput;
    if (native_result.parameter_count > max_parameter_count) return error.InvalidBehaviorCompilerOutput;

    var compiled = CompiledScript{
        .allocator = allocator,
        .bytecode = try allocator.dupe(u8, native_result.bytecode[0..native_result.bytecode_size]),
        .parameter_count = @intCast(native_result.parameter_count),
    };
    errdefer compiled.deinit();
    for (0..native_result.parameter_count) |index| {
        const native_parameter = native_result.parameters[index];
        const native_name = std.mem.sliceTo(&native_parameter.name, 0);
        if (native_name.len == 0 or native_name.len > common.max_parameter_name_bytes) {
            return error.InvalidBehaviorCompilerOutput;
        }
        compiled.parameters[index].name_bytes = @intCast(native_name.len);
        @memcpy(compiled.parameters[index].name_storage[0..native_name.len], native_name);
        compiled.parameters[index].default_value = native_parameter.default_value;
        compiled.parameters[index].minimum = native_parameter.minimum;
        compiled.parameters[index].maximum = native_parameter.maximum;
    }
    diagnostic.refresh();
    return compiled;
}
