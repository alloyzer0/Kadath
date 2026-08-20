const std = @import("std");
const artifact = @import("behavior_artifact");

fn parameter(name: []const u8, default_value: f64, minimum: f64, maximum: f64) artifact.ParameterSchema {
    var result = artifact.ParameterSchema{
        .name_bytes = @intCast(name.len),
        .default_value = default_value,
        .minimum = minimum,
        .maximum = maximum,
    };
    @memcpy(result.name_storage[0..name.len], name);
    return result;
}

test "KSCP v2 round trips aggregate entries and identities" {
    try std.testing.expectEqual(@as(u32, 3), artifact.host_interface_version);
    const patrol_parameters = [_]artifact.ParameterSchema{
        parameter("minY", 245, -100000, 100000),
        parameter("maxY", 330, -100000, 100000),
        parameter("speed", 80, 0, 1000),
    };
    const entries = [_]artifact.BuildEntry{
        .{
            .script_id = 7,
            .source_name = "scripts/patrol.luau",
            .source_sha256 = [_]u8{0x11} ** 32,
            .parameters = &patrol_parameters,
            .bytecode = "patrol-bytecode",
        },
        .{
            .script_id = 19,
            .source_name = "scripts/bounce.luau",
            .source_sha256 = [_]u8{0x22} ** 32,
            .parameters = &.{parameter("height", 12, 0, 100)},
            .bytecode = "bounce-bytecode",
        },
    };
    const encoded = try artifact.encode(std.testing.allocator, "luau-0.732-decb2d0", &entries);
    defer std.testing.allocator.free(encoded);

    const package = try artifact.parse(encoded, "luau-0.732-decb2d0");
    try std.testing.expectEqual(@as(u8, 2), package.entry_count);
    try std.testing.expectEqualStrings("luau-0.732-decb2d0", package.toolchain_identity);
    const patrol = package.findEntry(7) orelse return error.MissingPatrolEntry;
    try std.testing.expectEqualStrings("scripts/patrol.luau", patrol.source_name);
    try std.testing.expectEqual(@as(u8, 3), patrol.parameter_count);
    try std.testing.expectEqualStrings("speed", patrol.parameterSlice()[2].name());
    try std.testing.expectEqualStrings("bounce-bytecode", (package.findEntry(19) orelse return error.MissingBounceEntry).bytecode);
}

test "KSCP v2 rejects payload and bytecode corruption before use" {
    const entries = [_]artifact.BuildEntry{.{
        .script_id = 1,
        .source_name = "scripts/patrol.luau",
        .source_sha256 = [_]u8{0x33} ** 32,
        .parameters = &.{},
        .bytecode = "valid-bytecode",
    }};
    const encoded = try artifact.encode(std.testing.allocator, "luau-0.732-decb2d0", &entries);
    defer std.testing.allocator.free(encoded);
    encoded[encoded.len - 1] ^= 0xff;
    try std.testing.expectError(error.InvalidScriptArtifact, artifact.parse(encoded, "luau-0.732-decb2d0"));
}

test "KSCP v2 rejects duplicate identities and unsafe paths" {
    const duplicate_entries = [_]artifact.BuildEntry{
        .{
            .script_id = 1,
            .source_name = "scripts/first.luau",
            .source_sha256 = [_]u8{0x44} ** 32,
            .parameters = &.{},
            .bytecode = "first",
        },
        .{
            .script_id = 1,
            .source_name = "scripts/second.luau",
            .source_sha256 = [_]u8{0x55} ** 32,
            .parameters = &.{},
            .bytecode = "second",
        },
    };
    try std.testing.expectError(
        error.DuplicateScriptId,
        artifact.encode(std.testing.allocator, "luau-0.732-decb2d0", &duplicate_entries),
    );

    const unsafe_entry = [_]artifact.BuildEntry{.{
        .script_id = 2,
        .source_name = "scripts/../escape.luau",
        .source_sha256 = [_]u8{0x66} ** 32,
        .parameters = &.{},
        .bytecode = "escape",
    }};
    try std.testing.expectError(
        error.InvalidScriptSourceName,
        artifact.encode(std.testing.allocator, "luau-0.732-decb2d0", &unsafe_entry),
    );
}

test "KSCP v2 rejects an incompatible Luau identity" {
    const entries = [_]artifact.BuildEntry{.{
        .script_id = 1,
        .source_name = "scripts/patrol.luau",
        .source_sha256 = [_]u8{0x77} ** 32,
        .parameters = &.{},
        .bytecode = "bytecode",
    }};
    const encoded = try artifact.encode(std.testing.allocator, "luau-0.732-decb2d0", &entries);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectError(error.UnsupportedScriptArtifact, artifact.parse(encoded, "luau-other"));
}

test "KSCP v2 rejects Host Interface v2 artifacts after the object API change" {
    const entries = [_]artifact.BuildEntry{.{
        .script_id = 1,
        .source_name = "scripts/patrol.luau",
        .source_sha256 = [_]u8{0x88} ** 32,
        .parameters = &.{},
        .bytecode = "bytecode",
    }};
    const encoded = try artifact.encode(std.testing.allocator, "luau-0.732-decb2d0", &entries);
    defer std.testing.allocator.free(encoded);
    std.mem.writeInt(u32, encoded[12..16], 2, .little);
    try std.testing.expectError(error.UnsupportedScriptArtifact, artifact.parse(encoded, "luau-0.732-decb2d0"));
}
