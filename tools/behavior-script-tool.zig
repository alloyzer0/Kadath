const std = @import("std");
const builder = @import("behavior_package_builder");
const manifest = @import("behavior_manifest");
const tooling = @import("behavior_tooling");

const Options = struct {
    project_root: []const u8,
    manifest_name: []const u8,
    output_path: []const u8,
};

const Mode = union(enum) {
    build: Options,
    analyze_stdin,
};

const request_magic = "KLAN";
const response_magic = "KLAR";
const protocol_version: u32 = 1;
const request_header_bytes: usize = 16;
const response_header_bytes: usize = 12;
const max_source_path_bytes: usize = 1024;
const max_source_bytes: usize = 64 * 1024;
const max_result_json_bytes: usize = 64 * 1024;

const AnalyzeRequest = struct {
    source_path: []const u8,
    source: []const u8,
};

const WirePosition = struct {
    line: u32,
    column: u32,
};

const WireRange = struct {
    start: WirePosition,
    end: WirePosition,
};

const WireDiagnostic = struct {
    severity: []const u8,
    stage: []const u8,
    code: []const u8,
    message: []const u8,
    range: ?WireRange,
};

const WireAnalysisResult = struct {
    state: []const u8,
    toolchainIdentity: []const u8,
    diagnostics: []const WireDiagnostic,
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
    const mode = try parseMode(args);
    switch (mode) {
        .analyze_stdin => return analyzeStdin(init),
        .build => |options| return buildPackage(init, diagnostic, options),
    }
}

fn buildPackage(init: std.process.Init, diagnostic: *builder.Diagnostic, options: Options) !void {
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

fn parseMode(args: []const []const u8) !Mode {
    if (args.len == 2 and std.mem.eql(u8, args[1], "--analyze-stdin")) return .analyze_stdin;
    return .{ .build = try parseOptions(args) };
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

fn analyzeStdin(init: std.process.Init) !void {
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(init.io, &stdin_buffer);
    var request_header: [request_header_bytes]u8 = undefined;
    try stdin_reader.interface.readSliceAll(&request_header);
    const body_bytes = try requestBodyBytes(&request_header);
    const body = try init.gpa.alloc(u8, body_bytes);
    defer init.gpa.free(body);
    try stdin_reader.interface.readSliceAll(body);
    if (stdin_reader.interface.peekByte()) |_| {
        return error.TrailingAnalyzeRequestBytes;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    const request = try parseAnalyzeRequest(&request_header, body);
    const chunk_name = try init.gpa.dupeZ(u8, request.source_path);
    defer init.gpa.free(chunk_name);
    var failure = tooling.Diagnostic{};
    const analysis = try tooling.analyze(request.source, chunk_name, &failure);
    const result_json = try encodeAnalysisResult(init.gpa, &analysis);
    defer init.gpa.free(result_json);

    var response_header = std.mem.zeroes([response_header_bytes]u8);
    @memcpy(response_header[0..4], response_magic);
    std.mem.writeInt(u32, response_header[4..8], protocol_version, .little);
    std.mem.writeInt(u32, response_header[8..12], @intCast(result_json.len), .little);
    try std.Io.File.stdout().writeStreamingAll(init.io, &response_header);
    try std.Io.File.stdout().writeStreamingAll(init.io, result_json);
}

fn requestBodyBytes(header: *const [request_header_bytes]u8) !usize {
    if (!std.mem.eql(u8, header[0..4], request_magic)) return error.InvalidAnalyzeRequestMagic;
    if (std.mem.readInt(u32, header[4..8], .little) != protocol_version) return error.UnsupportedAnalyzeRequestVersion;
    const source_path_bytes = std.mem.readInt(u32, header[8..12], .little);
    const source_bytes = std.mem.readInt(u32, header[12..16], .little);
    if (source_path_bytes == 0 or source_path_bytes > max_source_path_bytes) return error.InvalidAnalyzeSourcePathSize;
    if (source_bytes > max_source_bytes) return error.InvalidAnalyzeSourceSize;
    return @as(usize, source_path_bytes) + @as(usize, source_bytes);
}

fn parseAnalyzeRequest(header: *const [request_header_bytes]u8, body: []const u8) !AnalyzeRequest {
    if (body.len != try requestBodyBytes(header)) return error.InvalidAnalyzeRequestBody;
    const source_path_bytes = std.mem.readInt(u32, header[8..12], .little);
    const source_path = body[0..source_path_bytes];
    const source = body[source_path_bytes..];
    if (!std.unicode.utf8ValidateSlice(source_path) or !std.unicode.utf8ValidateSlice(source)) {
        return error.InvalidAnalyzeRequestUtf8;
    }
    if (!validSourcePath(source_path)) return error.InvalidAnalyzeSourcePath;
    return .{ .source_path = source_path, .source = source };
}

fn validSourcePath(source_path: []const u8) bool {
    if (!std.mem.startsWith(u8, source_path, "scripts/") or
        !std.mem.endsWith(u8, source_path, ".luau") or
        std.mem.indexOfScalar(u8, source_path, '\\') != null or
        std.mem.indexOfScalar(u8, source_path, 0) != null)
    {
        return false;
    }
    var segments = std.mem.splitScalar(u8, source_path, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
    }
    return true;
}

fn encodeAnalysisResult(allocator: std.mem.Allocator, analysis: *const tooling.AnalysisResult) ![]u8 {
    var diagnostics: [tooling.max_analysis_diagnostic_count]WireDiagnostic = undefined;
    for (analysis.diagnosticSlice(), 0..) |diagnostic, index| {
        diagnostics[index] = .{
            .severity = "error",
            .stage = diagnosticStage(diagnostic.stage),
            .code = diagnosticCode(diagnostic.code),
            .message = diagnostic.message(),
            .range = if (diagnostic.range) |range| .{
                .start = .{ .line = range.start.line, .column = range.start.column },
                .end = .{ .line = range.end.line, .column = range.end.column },
            } else null,
        };
    }
    const root = WireAnalysisResult{
        .state = if (analysis.state == .valid) "valid" else "invalid",
        .toolchainIdentity = tooling.toolchainIdentity(),
        .diagnostics = diagnostics[0..analysis.diagnosticSlice().len],
    };
    var json = try std.json.Stringify.valueAlloc(allocator, root, .{});
    if (json.len <= max_result_json_bytes) return json;

    var diagnostic_index = root.diagnostics.len;
    while (diagnostic_index > 0 and json.len > max_result_json_bytes) {
        diagnostic_index -= 1;
        const first_scalar_bytes = try firstUtf8ScalarBytes(diagnostics[diagnostic_index].message);
        diagnostics[diagnostic_index].message = diagnostics[diagnostic_index].message[0..first_scalar_bytes];
        allocator.free(json);
        json = try std.json.Stringify.valueAlloc(allocator, root, .{});
    }
    if (json.len > max_result_json_bytes) {
        allocator.free(json);
        return error.AnalyzeResultTooLarge;
    }
    return json;
}

fn firstUtf8ScalarBytes(value: []const u8) !usize {
    if (value.len == 0) return error.EmptyAnalyzeDiagnosticMessage;
    const sequence_length = try std.unicode.utf8ByteSequenceLength(value[0]);
    if (sequence_length > value.len) return error.InvalidAnalyzeDiagnosticUtf8;
    _ = try std.unicode.utf8Decode(value[0..sequence_length]);
    return sequence_length;
}

fn diagnosticStage(stage: tooling.DiagnosticStage) []const u8 {
    return switch (stage) {
        .analysis => "analysis",
        .compile => "compile",
        .tooling_execution => "tooling_execution",
        .behavior_contract => "behavior_contract",
    };
}

fn diagnosticCode(code: tooling.DiagnosticCode) []const u8 {
    return switch (code) {
        .luau_analysis_error => "LUAU_ANALYSIS_ERROR",
        .luau_analysis_budget_exceeded => "LUAU_ANALYSIS_BUDGET_EXCEEDED",
        .luau_compile_error => "LUAU_COMPILE_ERROR",
        .tooling_execution_error => "KADATH_TOOLING_EXECUTION_ERROR",
        .tooling_execution_budget_exceeded => "KADATH_TOOLING_EXECUTION_BUDGET_EXCEEDED",
        .tooling_memory_limit_exceeded => "KADATH_TOOLING_MEMORY_LIMIT_EXCEEDED",
        .invalid_parameter_declaration => "KADATH_INVALID_PARAMETER_DECLARATION",
        .invalid_behavior_table => "KADATH_INVALID_BEHAVIOR_TABLE",
        .diagnostic_limit_reached => "KADATH_DIAGNOSTIC_LIMIT_REACHED",
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

test "behavior script tool freezes analyze mode and frame bounds" {
    try std.testing.expectEqual(Mode.analyze_stdin, try parseMode(&.{ "kadath-behavior-tool", "--analyze-stdin" }));
    try std.testing.expectError(
        error.InvalidArguments,
        parseMode(&.{ "kadath-behavior-tool", "--analyze-stdin", "extra" }),
    );

    var header = std.mem.zeroes([request_header_bytes]u8);
    @memcpy(header[0..4], request_magic);
    std.mem.writeInt(u32, header[4..8], protocol_version, .little);
    std.mem.writeInt(u32, header[8..12], 19, .little);
    std.mem.writeInt(u32, header[12..16], 9, .little);
    const request = try parseAnalyzeRequest(&header, "scripts/player.luaureturn {}");
    try std.testing.expectEqualStrings("scripts/player.luau", request.source_path);
    try std.testing.expectEqualStrings("return {}", request.source);

    std.mem.writeInt(u32, header[12..16], max_source_bytes + 1, .little);
    try std.testing.expectError(error.InvalidAnalyzeSourceSize, requestBodyBytes(&header));
    std.mem.writeInt(u32, header[12..16], 9, .little);
    header[0] = 'X';
    try std.testing.expectError(error.InvalidAnalyzeRequestMagic, requestBodyBytes(&header));
}

test "behavior script tool serializes strict structured diagnostics" {
    var failure = tooling.Diagnostic{};
    const analysis = try tooling.analyze(
        "--!strict\nlocal value: string = 1\nreturn {}",
        "scripts/invalid.luau",
        &failure,
    );
    const json = try encodeAnalysisResult(std.testing.allocator, &analysis);
    defer std.testing.allocator.free(json);
    try std.testing.expect(json.len <= max_result_json_bytes);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"state\":\"invalid\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"stage\":\"analysis\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"code\":\"LUAU_ANALYSIS_ERROR\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"range\":{") != null);
}
