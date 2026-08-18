const std = @import("std");
const common = @import("behavior_common");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const artifact_version: u32 = 2;
pub const source_schema_version: u32 = 2;
pub const host_interface_version: u32 = 2;
pub const max_entry_count: usize = 16;
pub const max_source_name_bytes: usize = common.max_source_name_bytes;
pub const max_toolchain_identity_bytes: usize = 127;
pub const max_artifact_bytes: usize = 16 * 1024 * 1024;
pub const ParameterSchema = common.ParameterSchema;

const header_bytes: usize = 60;
const entry_header_bytes: usize = 84;
const parameter_header_bytes: usize = 28;
const payload_hash_offset: usize = 28;

pub const BuildEntry = struct {
    script_id: u32,
    source_name: []const u8,
    source_sha256: [Sha256.digest_length]u8,
    parameters: []const ParameterSchema,
    bytecode: []const u8,
};

pub const Entry = struct {
    script_id: u32 = 0,
    source_name: []const u8 = "",
    source_sha256: [Sha256.digest_length]u8 = [_]u8{0} ** Sha256.digest_length,
    bytecode_sha256: [Sha256.digest_length]u8 = [_]u8{0} ** Sha256.digest_length,
    parameters: [common.max_parameter_count]ParameterSchema = [_]ParameterSchema{.{}} ** common.max_parameter_count,
    parameter_count: u8 = 0,
    bytecode: []const u8 = "",

    pub fn parameterSlice(self: *const Entry) []const ParameterSchema {
        return self.parameters[0..self.parameter_count];
    }
};

pub const Package = struct {
    toolchain_identity: []const u8 = "",
    entries: [max_entry_count]Entry = [_]Entry{.{}} ** max_entry_count,
    entry_count: u8 = 0,
    artifact_revision: [Sha256.digest_length]u8 = [_]u8{0} ** Sha256.digest_length,

    pub fn entrySlice(self: *const Package) []const Entry {
        return self.entries[0..self.entry_count];
    }

    pub fn findEntry(self: *const Package, script_id: u32) ?*const Entry {
        for (self.entrySlice()) |*entry| {
            if (entry.script_id == script_id) return entry;
        }
        return null;
    }
};

const Encoder = struct {
    bytes: []u8,
    index: usize = 0,

    fn writeBytes(self: *Encoder, value: []const u8) void {
        @memcpy(self.bytes[self.index .. self.index + value.len], value);
        self.index += value.len;
    }

    fn writeU32(self: *Encoder, value: u32) void {
        writeLittleU32(self.bytes[self.index .. self.index + 4], value);
        self.index += 4;
    }

    fn writeF64(self: *Encoder, value: f64) void {
        writeLittleU64(self.bytes[self.index .. self.index + 8], @bitCast(value));
        self.index += 8;
    }
};

const Cursor = struct {
    bytes: []const u8,
    index: usize = 0,

    fn take(self: *Cursor, byte_count: usize) ![]const u8 {
        if (byte_count > self.bytes.len - self.index) return error.InvalidScriptArtifact;
        const result = self.bytes[self.index .. self.index + byte_count];
        self.index += byte_count;
        return result;
    }

    fn readU32(self: *Cursor) !u32 {
        return readLittleU32(try self.take(4));
    }

    fn readF64(self: *Cursor) !f64 {
        return @bitCast(readLittleU64(try self.take(8)));
    }
};

pub fn encode(
    allocator: std.mem.Allocator,
    toolchain_identity: []const u8,
    entries: []const BuildEntry,
) ![]u8 {
    try validateToolchainIdentity(toolchain_identity);
    if (entries.len == 0 or entries.len > max_entry_count) return error.InvalidScriptEntryCount;

    var payload_size = toolchain_identity.len;
    for (entries, 0..) |entry, entry_index| {
        try validateBuildEntry(entries, entry, entry_index);
        var entry_size = try checkedAdd(entry_header_bytes, entry.source_name.len);
        entry_size = try checkedAdd(entry_size, entry.bytecode.len);
        for (entry.parameters) |parameter| {
            entry_size = try checkedAdd(entry_size, parameter_header_bytes);
            entry_size = try checkedAdd(entry_size, parameter.name().len);
        }
        _ = std.math.cast(u32, entry_size) orelse return error.ScriptArtifactTooLarge;
        payload_size = try checkedAdd(payload_size, entry_size);
    }
    _ = std.math.cast(u32, payload_size) orelse return error.ScriptArtifactTooLarge;
    const total_size = try checkedAdd(header_bytes, payload_size);
    if (total_size > max_artifact_bytes) return error.ScriptArtifactTooLarge;

    const bytes = try allocator.alloc(u8, total_size);
    errdefer allocator.free(bytes);
    var encoder = Encoder{ .bytes = bytes };
    encoder.writeBytes("KSCP");
    encoder.writeU32(artifact_version);
    encoder.writeU32(source_schema_version);
    encoder.writeU32(host_interface_version);
    encoder.writeU32(@intCast(entries.len));
    encoder.writeU32(@intCast(toolchain_identity.len));
    encoder.writeU32(@intCast(payload_size));
    encoder.writeBytes(&([_]u8{0} ** Sha256.digest_length));
    encoder.writeBytes(toolchain_identity);

    for (entries) |entry| {
        const entry_start = encoder.index;
        encoder.writeU32(0);
        encoder.writeU32(entry.script_id);
        encoder.writeU32(@intCast(entry.source_name.len));
        encoder.writeU32(@intCast(entry.parameters.len));
        encoder.writeU32(@intCast(entry.bytecode.len));
        encoder.writeBytes(&entry.source_sha256);
        var bytecode_sha256: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(entry.bytecode, &bytecode_sha256, .{});
        encoder.writeBytes(&bytecode_sha256);
        encoder.writeBytes(entry.source_name);
        for (entry.parameters) |parameter| {
            encoder.writeU32(@intCast(parameter.name().len));
            encoder.writeF64(parameter.default_value);
            encoder.writeF64(parameter.minimum);
            encoder.writeF64(parameter.maximum);
            encoder.writeBytes(parameter.name());
        }
        encoder.writeBytes(entry.bytecode);
        writeLittleU32(bytes[entry_start .. entry_start + 4], @intCast(encoder.index - entry_start));
    }

    std.debug.assert(encoder.index == bytes.len);
    var payload_sha256: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes[header_bytes..], &payload_sha256, .{});
    @memcpy(bytes[payload_hash_offset .. payload_hash_offset + Sha256.digest_length], &payload_sha256);
    return bytes;
}

pub fn parse(bytes: []const u8, expected_toolchain_identity: []const u8) !Package {
    if (bytes.len < header_bytes or bytes.len > max_artifact_bytes) return error.InvalidScriptArtifact;
    if (!std.mem.eql(u8, bytes[0..4], "KSCP")) return error.InvalidScriptArtifact;
    if (readLittleU32(bytes[4..8]) != artifact_version) return error.UnsupportedScriptArtifact;
    if (readLittleU32(bytes[8..12]) != source_schema_version) return error.UnsupportedScriptArtifact;
    if (readLittleU32(bytes[12..16]) != host_interface_version) return error.UnsupportedScriptArtifact;

    const entry_count = readLittleU32(bytes[16..20]);
    if (entry_count == 0 or entry_count > max_entry_count) return error.InvalidScriptArtifact;
    const toolchain_identity_length = readLittleU32(bytes[20..24]);
    if (toolchain_identity_length == 0 or toolchain_identity_length > max_toolchain_identity_bytes) {
        return error.InvalidScriptArtifact;
    }
    const payload_length = readLittleU32(bytes[24..28]);
    if (payload_length != bytes.len - header_bytes) return error.InvalidScriptArtifact;

    var actual_payload_sha256: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes[header_bytes..], &actual_payload_sha256, .{});
    if (!std.mem.eql(u8, bytes[payload_hash_offset .. payload_hash_offset + Sha256.digest_length], &actual_payload_sha256)) {
        return error.InvalidScriptArtifact;
    }

    var cursor = Cursor{ .bytes = bytes[header_bytes..] };
    const toolchain_identity = try cursor.take(toolchain_identity_length);
    try validateToolchainIdentity(toolchain_identity);
    if (!std.mem.eql(u8, toolchain_identity, expected_toolchain_identity)) return error.UnsupportedScriptArtifact;

    var package = Package{
        .toolchain_identity = toolchain_identity,
        .entry_count = @intCast(entry_count),
    };
    Sha256.hash(bytes, &package.artifact_revision, .{});

    for (0..entry_count) |entry_index| {
        const entry_start = cursor.index;
        const encoded_entry_size = try cursor.readU32();
        if (encoded_entry_size < entry_header_bytes) return error.InvalidScriptArtifact;
        const entry_end = try checkedAdd(entry_start, encoded_entry_size);
        if (entry_end > cursor.bytes.len) return error.InvalidScriptArtifact;

        var entry = Entry{};
        entry.script_id = try cursor.readU32();
        if (entry.script_id == 0) return error.InvalidScriptArtifact;
        const source_name_length = try cursor.readU32();
        const parameter_count = try cursor.readU32();
        const bytecode_length = try cursor.readU32();
        if (source_name_length == 0 or source_name_length > max_source_name_bytes) return error.InvalidScriptArtifact;
        if (parameter_count > common.max_parameter_count) return error.InvalidScriptArtifact;
        if (bytecode_length == 0) return error.InvalidScriptArtifact;
        @memcpy(&entry.source_sha256, try cursor.take(Sha256.digest_length));
        @memcpy(&entry.bytecode_sha256, try cursor.take(Sha256.digest_length));
        entry.source_name = try cursor.take(source_name_length);
        try common.validateSourceName(entry.source_name);
        entry.parameter_count = @intCast(parameter_count);

        for (0..parameter_count) |parameter_index| {
            const name_length = try cursor.readU32();
            if (name_length == 0 or name_length > common.max_parameter_name_bytes) return error.InvalidScriptArtifact;
            var parameter = ParameterSchema{
                .default_value = try cursor.readF64(),
                .minimum = try cursor.readF64(),
                .maximum = try cursor.readF64(),
                .name_bytes = @intCast(name_length),
            };
            const name = try cursor.take(name_length);
            @memcpy(parameter.name_storage[0..name.len], name);
            try validateParameter(parameter);
            for (entry.parameters[0..parameter_index]) |existing| {
                if (std.mem.eql(u8, existing.name(), parameter.name())) return error.InvalidScriptArtifact;
            }
            entry.parameters[parameter_index] = parameter;
        }

        entry.bytecode = try cursor.take(bytecode_length);
        if (cursor.index != entry_end) return error.InvalidScriptArtifact;
        var actual_bytecode_sha256: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(entry.bytecode, &actual_bytecode_sha256, .{});
        if (!std.mem.eql(u8, &entry.bytecode_sha256, &actual_bytecode_sha256)) return error.InvalidScriptArtifact;
        for (package.entries[0..entry_index]) |existing| {
            if (existing.script_id == entry.script_id or std.mem.eql(u8, existing.source_name, entry.source_name)) {
                return error.InvalidScriptArtifact;
            }
        }
        package.entries[entry_index] = entry;
    }
    if (cursor.index != cursor.bytes.len) return error.InvalidScriptArtifact;
    return package;
}

fn validateBuildEntry(entries: []const BuildEntry, entry: BuildEntry, entry_index: usize) !void {
    if (entry.script_id == 0) return error.InvalidScriptId;
    try common.validateSourceName(entry.source_name);
    if (entry.parameters.len > common.max_parameter_count) return error.InvalidScriptParameterSchema;
    if (entry.bytecode.len == 0) return error.InvalidScriptBytecode;
    _ = std.math.cast(u32, entry.bytecode.len) orelse return error.ScriptArtifactTooLarge;
    for (entry.parameters, 0..) |parameter, parameter_index| {
        try validateParameter(parameter);
        for (entry.parameters[0..parameter_index]) |existing| {
            if (std.mem.eql(u8, existing.name(), parameter.name())) return error.InvalidScriptParameterSchema;
        }
    }
    for (entries[0..entry_index]) |existing| {
        if (existing.script_id == entry.script_id) return error.DuplicateScriptId;
        if (std.mem.eql(u8, existing.source_name, entry.source_name)) return error.DuplicateScriptSource;
    }
}

fn validateToolchainIdentity(identity: []const u8) !void {
    if (identity.len == 0 or identity.len > max_toolchain_identity_bytes) return error.InvalidToolchainIdentity;
    for (identity) |character| {
        const valid = std.ascii.isAlphanumeric(character) or character == '.' or character == '-' or character == '_';
        if (!valid) return error.InvalidToolchainIdentity;
    }
}

fn validateParameter(parameter: ParameterSchema) !void {
    const name = parameter.name();
    if (name.len == 0 or name.len > common.max_parameter_name_bytes) return error.InvalidScriptParameterSchema;
    if (!(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return error.InvalidScriptParameterSchema;
    for (name[1..]) |character| {
        if (!(std.ascii.isAlphanumeric(character) or character == '_')) return error.InvalidScriptParameterSchema;
    }
    if (!std.math.isFinite(parameter.default_value) or
        !std.math.isFinite(parameter.minimum) or
        !std.math.isFinite(parameter.maximum) or
        parameter.minimum > parameter.maximum or
        parameter.default_value < parameter.minimum or
        parameter.default_value > parameter.maximum)
    {
        return error.InvalidScriptParameterSchema;
    }
}

fn checkedAdd(left: usize, right: usize) !usize {
    if (right > std.math.maxInt(usize) - left) return error.ScriptArtifactTooLarge;
    return left + right;
}

fn readLittleU32(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}

fn readLittleU64(bytes: []const u8) u64 {
    var value: u64 = 0;
    for (bytes[0..8], 0..) |byte, shift_index| {
        value |= @as(u64, byte) << @intCast(shift_index * 8);
    }
    return value;
}

fn writeLittleU32(bytes: []u8, value: u32) void {
    bytes[0] = @truncate(value);
    bytes[1] = @truncate(value >> 8);
    bytes[2] = @truncate(value >> 16);
    bytes[3] = @truncate(value >> 24);
}

fn writeLittleU64(bytes: []u8, value: u64) void {
    for (bytes[0..8], 0..) |*byte, shift_index| {
        byte.* = @truncate(value >> @intCast(shift_index * 8));
    }
}
