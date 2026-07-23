const std = @import("std");
const content_identity = @import("content_identity.zig");

pub const current_schema_version: u32 = 1;
pub const max_instructions: usize = 16;
pub const script_artifact_version: u32 = 1;
const script_artifact_header_bytes: usize = 16;
const script_artifact_instruction_bytes: usize = 16;
const max_document_bytes: usize = 64 * 1024;
const max_artifact_bytes: usize = script_artifact_header_bytes + max_instructions * script_artifact_instruction_bytes;
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

pub const LoadedScript = struct {
    value: Program,
    identity: content_identity.ContentIdentity,
};

pub fn load(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Program {
    return (try loadWithIdentity(io, allocator, path)).value;
}

pub fn loadWithIdentity(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !LoadedScript {
    // 保留既有 load 的扩展名分派语义；artifact/source 的解析意图不会由魔数猜测。
    if (std.ascii.endsWithIgnoreCase(path, ".script")) return loadArtifactWithIdentity(io, allocator, path);
    const contents = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_document_bytes));
    defer allocator.free(contents);
    return parseWithIdentity(allocator, contents, .source_document);
}

pub fn loadArtifact(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Program {
    return (try loadArtifactWithIdentity(io, allocator, path)).value;
}

pub fn loadArtifactWithIdentity(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !LoadedScript {
    const contents = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_artifact_bytes));
    defer allocator.free(contents);
    return parseArtifactWithIdentity(contents);
}

fn parseWithIdentity(allocator: std.mem.Allocator, contents: []const u8, kind: content_identity.ContentKind) !LoadedScript {
    const value = try parse(allocator, contents);
    // Program 与身份必须共同来自同一 buffer；解析失败不得泄漏候选 digest。
    return .{ .value = value, .identity = try content_identity.ContentIdentity.fromBytes(kind, contents) };
}

fn parseArtifactWithIdentity(contents: []const u8) !LoadedScript {
    const value = try parseArtifact(contents);
    return .{ .value = value, .identity = try content_identity.ContentIdentity.fromBytes(.artifact, contents) };
}

fn readLittleU32(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}

fn readLittleF32(bytes: []const u8) f32 {
    return @bitCast(readLittleU32(bytes));
}

fn decodeHook(raw: u32) !Hook {
    return switch (raw) {
        0 => .on_start,
        1 => .fixed_update,
        else => error.InvalidScriptArtifact,
    };
}

fn decodeOperation(raw: u32) !Operation {
    return switch (raw) {
        0 => .set_goal_position,
        1 => .move_goal_velocity,
        else => error.InvalidScriptArtifact,
    };
}

fn parseArtifact(source: []const u8) !Program {
    if (source.len < script_artifact_header_bytes) return error.InvalidScriptArtifact;
    if (!std.mem.eql(u8, source[0..4], "KSCP")) return error.InvalidScriptArtifact;
    if (readLittleU32(source[4..8]) != script_artifact_version) return error.UnsupportedScriptArtifactVersion;
    if (readLittleU32(source[8..12]) != current_schema_version) return error.UnsupportedScriptSchema;

    const instruction_count = readLittleU32(source[12..16]);
    if (instruction_count > max_instructions) return error.ScriptInstructionBudgetExceeded;
    const count: usize = @intCast(instruction_count);
    const expected_bytes = script_artifact_header_bytes + count * script_artifact_instruction_bytes;
    if (source.len != expected_bytes) return error.InvalidScriptArtifact;

    // KSCP v1 将 hook/op/value 固定为 16-byte 记录；未知枚举不能静默降级。
    var program = Program{};
    var offset: usize = script_artifact_header_bytes;
    for (0..count) |index| {
        const instruction = Instruction{
            .hook = try decodeHook(readLittleU32(source[offset .. offset + 4])),
            .op = try decodeOperation(readLittleU32(source[offset + 4 .. offset + 8])),
            .value = .{
                readLittleF32(source[offset + 8 .. offset + 12]),
                readLittleF32(source[offset + 12 .. offset + 16]),
            },
        };
        try validateInstruction(instruction);
        program.instructions[index] = instruction;
        offset += script_artifact_instruction_bytes;
    }
    program.count = count;
    return program;
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

test "script source identity is computed from the parsed buffer" {
    const contents =
        \\{
        \\  "schemaVersion": 1,
        \\  "instructions": [
        \\    { "hook": "on_start", "op": "set_goal_position", "value": [680, 200] }
        \\  ]
        \\}
    ;
    const loaded = try parseWithIdentity(std.testing.allocator, contents, .source_document);
    const expected = try content_identity.ContentIdentity.fromBytes(.source_document, contents);
    try std.testing.expectEqual(expected, loaded.identity);
    try std.testing.expectEqual(@as(usize, 1), loaded.value.count);
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
fn writeLittleU32(bytes: []u8, value: u32) void {
    bytes[0] = @truncate(value);
    bytes[1] = @truncate(value >> 8);
    bytes[2] = @truncate(value >> 16);
    bytes[3] = @truncate(value >> 24);
}

fn writeLittleF32(bytes: []u8, value: f32) void {
    writeLittleU32(bytes, @bitCast(value));
}

fn makeTestScriptArtifact() [script_artifact_header_bytes + 2 * script_artifact_instruction_bytes]u8 {
    var artifact = [_]u8{0} ** (script_artifact_header_bytes + 2 * script_artifact_instruction_bytes);
    artifact[0] = 'K';
    artifact[1] = 'S';
    artifact[2] = 'C';
    artifact[3] = 'P';
    writeLittleU32(artifact[4..8], script_artifact_version);
    writeLittleU32(artifact[8..12], current_schema_version);
    writeLittleU32(artifact[12..16], 2);

    // 测试固定 ABI：on_start/set_goal_position 与 fixed_update/move_goal_velocity。
    writeLittleU32(artifact[16..20], 0);
    writeLittleU32(artifact[20..24], 0);
    writeLittleF32(artifact[24..28], 680.0);
    writeLittleF32(artifact[28..32], 200.0);
    writeLittleU32(artifact[32..36], 1);
    writeLittleU32(artifact[36..40], 1);
    writeLittleF32(artifact[40..44], -12.0);
    writeLittleF32(artifact[44..48], 0.0);
    return artifact;
}

test "KSCP v1 parses a fixed instruction artifact" {
    const artifact = makeTestScriptArtifact();
    const program = try parseArtifact(artifact[0..]);
    try std.testing.expectEqual(@as(usize, 2), program.count);
    try std.testing.expectEqual(Hook.on_start, program.instructions[0].hook);
    try std.testing.expectEqual(Operation.move_goal_velocity, program.instructions[1].op);
}

test "KSCP identity is computed from the validated artifact buffer" {
    const artifact = makeTestScriptArtifact();
    const loaded = try parseArtifactWithIdentity(artifact[0..]);
    const expected = try content_identity.ContentIdentity.fromBytes(.artifact, artifact[0..]);
    try std.testing.expectEqual(expected, loaded.identity);
    try std.testing.expectEqual(@as(usize, 2), loaded.value.count);
}

test "KSCP v1 rejects malformed header, trailing bytes, and unknown opcode" {
    var artifact = makeTestScriptArtifact();
    try std.testing.expectError(error.InvalidScriptArtifact, parseArtifact(artifact[0 .. artifact.len - 1]));

    artifact[0] = 'X';
    try std.testing.expectError(error.InvalidScriptArtifact, parseArtifact(artifact[0..]));

    var unknown = makeTestScriptArtifact();
    writeLittleU32(unknown[20..24], 99);
    try std.testing.expectError(error.InvalidScriptArtifact, parseArtifact(unknown[0..]));

    writeLittleU32(unknown[4..8], script_artifact_version + 1);
    try std.testing.expectError(error.UnsupportedScriptArtifactVersion, parseArtifact(unknown[0..]));
}
