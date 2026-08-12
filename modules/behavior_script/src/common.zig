const std = @import("std");

pub const max_parameter_count: usize = 16;
pub const max_parameter_name_bytes: usize = 63;
pub const max_command_count: usize = 16;
pub const max_object_id_bytes: usize = 63;
pub const max_diagnostic_bytes: usize = 512;
pub const max_source_name_bytes: usize = 1024;

pub const Diagnostic = struct {
    storage: [max_diagnostic_bytes]u8 = [_]u8{0} ** max_diagnostic_bytes,
    byte_count: usize = 0,

    pub fn clear(self: *Diagnostic) void {
        @memset(&self.storage, 0);
        self.byte_count = 0;
    }

    pub fn refresh(self: *Diagnostic) void {
        self.byte_count = std.mem.indexOfScalar(u8, &self.storage, 0) orelse self.storage.len;
    }

    pub fn slice(self: *const Diagnostic) []const u8 {
        return self.storage[0..self.byte_count];
    }
};

pub const ParameterSchema = struct {
    name_storage: [max_parameter_name_bytes]u8 = [_]u8{0} ** max_parameter_name_bytes,
    name_bytes: u8 = 0,
    default_value: f64 = 0.0,
    minimum: f64 = 0.0,
    maximum: f64 = 0.0,

    pub fn name(self: *const ParameterSchema) []const u8 {
        return self.name_storage[0..self.name_bytes];
    }
};

pub const ParameterValue = struct {
    name: []const u8,
    value: f64,
};

pub const TranslateCommand = struct {
    dx: f64,
    dy: f64,
};

pub const CommandBuffer = [max_command_count]TranslateCommand;

pub fn validateParameterName(name: []const u8) !void {
    if (name.len == 0 or name.len > max_parameter_name_bytes) return error.InvalidBehaviorParameter;
    if (!isAsciiIdentifierStart(name[0])) return error.InvalidBehaviorParameter;
    for (name[1..]) |byte| {
        if (!isAsciiIdentifierContinue(byte)) return error.InvalidBehaviorParameter;
    }
}

pub fn validateObjectId(object_id: []const u8) !void {
    if (object_id.len == 0 or object_id.len > max_object_id_bytes) return error.InvalidObjectId;
    if (object_id[0] < 'a' or object_id[0] > 'z') return error.InvalidObjectId;
    for (object_id[1..]) |byte| {
        const valid = (byte >= 'a' and byte <= 'z') or
            (byte >= '0' and byte <= '9') or
            byte == '_' or byte == '-';
        if (!valid) return error.InvalidObjectId;
    }
}

pub fn validateSourceName(source_name: []const u8) !void {
    if (source_name.len == 0 or source_name.len > max_source_name_bytes) return error.InvalidScriptSourceName;
    if (!std.unicode.utf8ValidateSlice(source_name)) return error.InvalidScriptSourceName;
    if (!std.mem.startsWith(u8, source_name, "scripts/") or !std.mem.endsWith(u8, source_name, ".luau")) {
        return error.InvalidScriptSourceName;
    }
    if (std.mem.indexOfAny(u8, source_name, "\\\x00") != null) return error.InvalidScriptSourceName;
    var segments = std.mem.splitScalar(u8, source_name, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) {
            return error.InvalidScriptSourceName;
        }
    }
}

fn isAsciiIdentifierStart(byte: u8) bool {
    return (byte >= 'A' and byte <= 'Z') or (byte >= 'a' and byte <= 'z') or byte == '_';
}

fn isAsciiIdentifierContinue(byte: u8) bool {
    return isAsciiIdentifierStart(byte) or (byte >= '0' and byte <= '9');
}
