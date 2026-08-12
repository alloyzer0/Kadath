const std = @import("std");
const builder = @import("behavior_package_builder");
const manifest = @import("behavior_manifest");
const tooling = @import("behavior_tooling");

const Options = struct {
    project_root: []const u8,
    manifest_name: []const u8,
    output_path: []const u8,
};

pub fn main(init: std.process.Init) !void {
    var diagnostic = builder.Diagnostic{};
    run(init, &diagnostic) catch |err| {
        printFailure(init.io, err, &diagnostic) catch {};
        return err;
    };
}

fn run(init: std.process.Init, diagnostic: *builder.Diagnostic) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = try parseOptions(args);
    if (!std.mem.eql(u8, options.manifest_name, "script.json")) return error.InvalidManifestName;

    var project_dir = try std.Io.Dir.cwd().openDir(init.io, options.project_root, .{
        .follow_symlinks = false,
    });
    defer project_dir.close(init.io);
    const manifest_bytes = try readManifest(init.io, init.gpa, project_dir, options.manifest_name);
    defer init.gpa.free(manifest_bytes);
    var snapshot = try manifest.loadSnapshot(init.io, init.gpa, project_dir, manifest_bytes);
    defer snapshot.deinit();
    var package = try builder.build(init.gpa, &snapshot, diagnostic);
    defer package.deinit();

    const current_manifest = try readManifest(init.io, init.gpa, project_dir, options.manifest_name);
    defer init.gpa.free(current_manifest);
    if (!std.mem.eql(u8, manifest_bytes, current_manifest)) return error.ScriptManifestChanged;
    try snapshot.verifyUnchanged(init.io, project_dir);
    try writeNew(init.io, options.output_path, package.bytes);
    try printSuccess(init.io, &package);
}

fn parseOptions(args: []const []const u8) !Options {
    if (args.len != 7) return error.InvalidArguments;
    var project_root: ?[]const u8 = null;
    var manifest_name: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var index: usize = 1;
    while (index < args.len) : (index += 2) {
        const value = args[index + 1];
        if (value.len == 0) return error.InvalidArguments;
        if (std.mem.eql(u8, args[index], "--project-root")) {
            if (project_root != null) return error.InvalidArguments;
            project_root = value;
        } else if (std.mem.eql(u8, args[index], "--manifest")) {
            if (manifest_name != null) return error.InvalidArguments;
            manifest_name = value;
        } else if (std.mem.eql(u8, args[index], "--output")) {
            if (output_path != null) return error.InvalidArguments;
            output_path = value;
        } else {
            return error.InvalidArguments;
        }
    }
    return .{
        .project_root = project_root orelse return error.InvalidArguments,
        .manifest_name = manifest_name orelse return error.InvalidArguments,
        .output_path = output_path orelse return error.InvalidArguments,
    };
}

fn readManifest(
    io: std.Io,
    allocator: std.mem.Allocator,
    project_dir: std.Io.Dir,
    manifest_name: []const u8,
) ![]u8 {
    var file = try project_dir.openFile(io, manifest_name, .{
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    });
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.ScriptManifestNotFile;
    if (stat.size > manifest.max_manifest_bytes) return error.InvalidScriptManifestSize;
    var file_reader = file.reader(io, &.{});
    const bytes = file_reader.interface.allocRemaining(allocator, .limited(manifest.max_manifest_bytes + 1)) catch |err| switch (err) {
        error.StreamTooLong => return error.InvalidScriptManifestSize,
        error.ReadFailed => return file_reader.err.?,
        else => |other| return other,
    };
    errdefer allocator.free(bytes);
    if (bytes.len > manifest.max_manifest_bytes) return error.InvalidScriptManifestSize;
    return bytes;
}

fn writeNew(io: std.Io, output_path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(io, output_path, .{ .exclusive = true });
    errdefer std.Io.Dir.cwd().deleteFile(io, output_path) catch {};
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
    try file.sync(io);
}

fn printSuccess(io: std.Io, package: *const builder.BuiltPackage) !void {
    var source_hex: [64]u8 = undefined;
    var artifact_hex: [64]u8 = undefined;
    const source_revision = try std.fmt.bufPrint(&source_hex, "{x}", .{&package.source_revision});
    const artifact_revision = try std.fmt.bufPrint(&artifact_hex, "{x}", .{&package.artifact_revision});
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print("status=succeeded\n", .{});
    try stdout.print("format=KSCP-SCRIPT-V2\n", .{});
    try stdout.print("toolchain_identity={s}\n", .{tooling.toolchainIdentity()});
    try stdout.print("entry_count={d}\n", .{package.entry_count});
    try stdout.print("source_revision={s}\n", .{source_revision});
    try stdout.print("artifact_revision={s}\n", .{artifact_revision});
    try stdout.print("artifact_bytes={d}\n", .{package.bytes.len});
    try stdout.flush();
}

fn printFailure(io: std.Io, err: anyerror, diagnostic: *const builder.Diagnostic) !void {
    var stderr_buffer: [2048]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    try stderr.print("status=failed\n", .{});
    try stderr.print("error={s}\n", .{@errorName(err)});
    if (diagnostic.script_id != 0) {
        try stderr.print("script_id={d}\n", .{diagnostic.script_id});
        try stderr.print("source={s}\n", .{diagnostic.sourceName()});
        try stderr.print("diagnostic={s}\n", .{diagnostic.message()});
    }
    try stderr.flush();
}

test "behavior script tool accepts each required option once" {
    const parsed = try parseOptions(&.{
        "kadath-behavior-tool",
        "--output",
        "candidate.script",
        "--project-root",
        "project",
        "--manifest",
        "script.json",
    });
    try std.testing.expectEqualStrings("project", parsed.project_root);
    try std.testing.expectEqualStrings("script.json", parsed.manifest_name);
    try std.testing.expectEqualStrings("candidate.script", parsed.output_path);
    try std.testing.expectError(
        error.InvalidArguments,
        parseOptions(&.{ "kadath-behavior-tool", "--project-root", "project" }),
    );
}
