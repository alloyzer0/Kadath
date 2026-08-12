const std = @import("std");
const common = @import("behavior_common");

const c = @cImport({
    @cInclude("kadath_luau.h");
});

pub const Diagnostic = common.Diagnostic;
pub const ParameterSchema = common.ParameterSchema;
pub const max_parameter_count = common.max_parameter_count;

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
