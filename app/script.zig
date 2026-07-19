const std = @import("std");

pub const current_schema_version: u32 = 1;
pub const max_instructions: usize = 16;
const max_document_bytes: usize = 64 * 1024;
const max_velocity: f32 = 1000.0;

pub const Hook = enum {
    on_start,
    fixed_update,
};

pub const Operation = enum {
    set_goal_position,
    move_goal_velocity,
};

pub const Instruction = struct {
    hook: Hook,
    op: Operation,
    value: [2]f32,
};

const Document = struct {
    schemaVersion: u32,
    instructions: []Instruction,
};

pub const Command = union(enum) {
    set_goal_position: [2]f32,
    translate_goal: [2]f32,
};

pub const CommandBuffer = [max_instructions]Command;

pub const Program = struct {
    instructions: [max_instructions]Instruction = undefined,
    count: usize = 0,

    pub fn hasInstructions(self: *const Program) bool {
        return self.count != 0;
    }

    pub fn emit(
        self: *const Program,
        hook: Hook,
        dt_seconds: f32,
        output: *CommandBuffer,
    ) ![]const Command {
        if (!std.math.isFinite(dt_seconds) or dt_seconds < 0.0) return error.InvalidScriptDelta;

        var output_count: usize = 0;
        for (self.instructions[0..self.count]) |instruction| {
            if (instruction.hook != hook) continue;
            output[output_count] = switch (instruction.op) {
                .set_goal_position => .{ .set_goal_position = instruction.value },
                .move_goal_velocity => .{ .translate_goal = .{
                    instruction.value[0] * dt_seconds,
                    instruction.value[1] * dt_seconds,
                } },
            };
            output_count += 1;
        }
        return output[0..output_count];
    }
};

pub fn load(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Program {
    const contents = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_document_bytes));
    defer allocator.free(contents);
    return parse(allocator, contents);
}

pub fn parse(allocator: std.mem.Allocator, contents: []const u8) !Program {
    // 关键宿主边界：程序只解析为固定预算的命令，不获得 World、RHI 或平台对象引用。
    const parsed = try std.json.parseFromSlice(Document, allocator, contents, .{});
    defer parsed.deinit();
    if (parsed.value.schemaVersion != current_schema_version) return error.UnsupportedScriptSchema;
    if (parsed.value.instructions.len > max_instructions) return error.ScriptInstructionBudgetExceeded;

    var program = Program{};
    for (parsed.value.instructions) |instruction| {
        try validateInstruction(instruction);
        program.instructions[program.count] = instruction;
        program.count += 1;
    }
    return program;
}

fn validateInstruction(instruction: Instruction) !void {
    for (instruction.value) |value| {
        if (!std.math.isFinite(value)) return error.InvalidScriptValue;
    }
    switch (instruction.hook) {
        .on_start => if (instruction.op != .set_goal_position) return error.InvalidScriptHookOperation,
        .fixed_update => {
            if (instruction.op != .move_goal_velocity) return error.InvalidScriptHookOperation;
            if (@abs(instruction.value[0]) > max_velocity or @abs(instruction.value[1]) > max_velocity) {
                return error.ScriptVelocityLimitExceeded;
            }
        },
    }
}

test "script program emits deterministic start and fixed commands" {
    const contents =
        \\{
        \\  "schemaVersion": 1,
        \\  "instructions": [
        \\    { "hook": "on_start", "op": "set_goal_position", "value": [680, 200] },
        \\    { "hook": "fixed_update", "op": "move_goal_velocity", "value": [-30, 0] }
        \\  ]
        \\}
    ;
    const program = try parse(std.testing.allocator, contents);
    var buffer: CommandBuffer = undefined;
    const start_commands = try program.emit(.on_start, 0.0, &buffer);
    try std.testing.expectEqual(@as(usize, 1), start_commands.len);
    try std.testing.expectEqual(@as(f32, 680.0), start_commands[0].set_goal_position[0]);

    const fixed_commands = try program.emit(.fixed_update, 1.0 / 60.0, &buffer);
    try std.testing.expectEqual(@as(usize, 1), fixed_commands.len);
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), fixed_commands[0].translate_goal[0], 0.0001);
}

test "script program rejects hook operation mismatch" {
    const contents =
        \\{
        \\  "schemaVersion": 1,
        \\  "instructions": [
        \\    { "hook": "on_start", "op": "move_goal_velocity", "value": [10, 0] }
        \\  ]
        \\}
    ;
    try std.testing.expectError(error.InvalidScriptHookOperation, parse(std.testing.allocator, contents));
}

test "script program rejects unsupported schema" {
    const contents =
        \\{ "schemaVersion": 2, "instructions": [] }
    ;
    try std.testing.expectError(error.UnsupportedScriptSchema, parse(std.testing.allocator, contents));
}

test "script program rejects excessive velocity" {
    const contents =
        \\{
        \\  "schemaVersion": 1,
        \\  "instructions": [
        \\    { "hook": "fixed_update", "op": "move_goal_velocity", "value": [1001, 0] }
        \\  ]
        \\}
    ;
    try std.testing.expectError(error.ScriptVelocityLimitExceeded, parse(std.testing.allocator, contents));
}
