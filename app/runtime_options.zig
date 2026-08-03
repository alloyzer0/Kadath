const std = @import("std");

pub const RuntimeOptions = struct {
    scene_path: ?[]const u8 = null,
    script_path: ?[]const u8 = null,
    preview_status_jsonl: bool = false,
    preview_control_jsonl: bool = false,
};

pub fn parse(args: []const []const u8) !RuntimeOptions {
    var options = RuntimeOptions{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--scene")) {
            if (options.scene_path != null) return error.DuplicateRuntimeArgument;
            index += 1;
            if (index >= args.len) return error.MissingRuntimeArgumentValue;
            options.scene_path = args[index];
        } else if (std.mem.eql(u8, args[index], "--script")) {
            if (options.script_path != null) return error.DuplicateRuntimeArgument;
            index += 1;
            if (index >= args.len) return error.MissingRuntimeArgumentValue;
            options.script_path = args[index];
        } else if (std.mem.eql(u8, args[index], "--preview-status")) {
            if (options.preview_status_jsonl) return error.DuplicateRuntimeArgument;
            index += 1;
            if (index >= args.len) return error.MissingRuntimeArgumentValue;
            if (!std.mem.eql(u8, args[index], "jsonl-v1")) return error.UnsupportedPreviewStatus;
            options.preview_status_jsonl = true;
        } else if (std.mem.eql(u8, args[index], "--preview-control")) {
            if (options.preview_control_jsonl) return error.DuplicateRuntimeArgument;
            index += 1;
            if (index >= args.len) return error.MissingRuntimeArgumentValue;
            if (!std.mem.eql(u8, args[index], "jsonl-v1")) return error.UnsupportedPreviewControl;
            options.preview_control_jsonl = true;
        } else {
            return error.UnknownRuntimeArgument;
        }
    }
    if (options.preview_control_jsonl and !options.preview_status_jsonl) return error.PreviewControlRequiresStatus;
    return options;
}

test "runtime options enable paired preview control and status" {
    const options = try parse(&.{ "kadath", "--scene", "scene.json", "--script", "script.json", "--preview-status", "jsonl-v1", "--preview-control", "jsonl-v1" });
    try std.testing.expectEqualStrings("scene.json", options.scene_path.?);
    try std.testing.expectEqualStrings("script.json", options.script_path.?);
    try std.testing.expect(options.preview_status_jsonl);
    try std.testing.expect(options.preview_control_jsonl);
}

test "runtime options reject an unobservable control channel" {
    try std.testing.expectError(
        error.PreviewControlRequiresStatus,
        parse(&.{ "kadath", "--preview-control", "jsonl-v1" }),
    );
}

test "runtime options reject unsupported and duplicate control arguments" {
    try std.testing.expectError(
        error.UnsupportedPreviewControl,
        parse(&.{ "kadath", "--preview-status", "jsonl-v1", "--preview-control", "jsonl-v2" }),
    );
    try std.testing.expectError(
        error.DuplicateRuntimeArgument,
        parse(&.{ "kadath", "--preview-status", "jsonl-v1", "--preview-control", "jsonl-v1", "--preview-control", "jsonl-v1" }),
    );
}
