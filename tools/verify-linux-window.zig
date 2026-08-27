const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
    @cInclude("signal.h");
    @cInclude("sys/wait.h");
    @cInclude("X11/keysym.h");
    @cInclude("xcb/xcb.h");
});

comptime {
    if (builtin.os.tag != .linux) @compileError("verify-linux-window is Linux-only");
}

const initial_width: u16 = 960;
const initial_height: u16 = 540;
const primary_fixture = Color{ .r = 32, .g = 220, .b = 80 };
const secondary_fixture = Color{ .r = 220, .g = 80, .b = 240 };
const package_primary_expected = Color{ .r = 97, .g = 104, .b = 124 };
const sample_tolerance: u8 = 14;
const package_sample_tolerance: u8 = 20;

const AssetMode = enum {
    generated_fixture,
    package_root,
    neutral_fixture,
};

const AudioExpectation = enum {
    not_applicable,
    alsa,
    silent,
};

const Color = struct {
    r: u8,
    g: u8,
    b: u8,
};

const XcbContext = struct {
    connection: *c.xcb_connection_t,
    setup: *const c.xcb_setup_t,
    screen: *c.xcb_screen_t,

    fn deinit(self: *XcbContext) void {
        c.xcb_disconnect(self.connection);
        self.* = undefined;
    }
};

const WindowInfo = struct {
    window: c.xcb_window_t,
    visual: c.xcb_visualid_t,
    depth: u8,
    width: u16,
    height: u16,
};

const PixelLayout = struct {
    byte_order: u8,
    bits_per_pixel: u8,
    scanline_pad: u8,
    red_mask: u32,
    green_mask: u32,
    blue_mask: u32,
};

const Capture = struct {
    width: u16,
    height: u16,
    rgb: []u8,

    fn deinit(self: *Capture, allocator: std.mem.Allocator) void {
        allocator.free(self.rgb);
        self.* = undefined;
    }

    fn sample(self: Capture, x: u16, y: u16) Color {
        const index = (@as(usize, y) * self.width + x) * 3;
        return .{
            .r = self.rgb[index],
            .g = self.rgb[index + 1],
            .b = self.rgb[index + 2],
        };
    }
};

const OwnedChildren = struct {
    runtime: ?std.process.Child = null,
    xvfb: ?std.process.Child = null,

    fn cleanup(self: *OwnedChildren, io: std.Io) !void {
        var first_error: ?anyerror = null;
        cleanupChildSlot(io, "Runtime", &self.runtime) catch |cleanup_error| {
            std.log.err("Owned Runtime cleanup failed: {s}", .{@errorName(cleanup_error)});
            first_error = cleanup_error;
        };
        cleanupChildSlot(io, "Xvfb", &self.xvfb) catch |cleanup_error| {
            std.log.err("Owned Xvfb cleanup failed: {s}", .{@errorName(cleanup_error)});
            if (first_error == null) first_error = cleanup_error;
        };
        if (first_error) |cleanup_error| return cleanup_error;
    }
};

const VerifierSuccess = struct {
    evidence_root: []u8,
    asset_mode: AssetMode,
    audio_expectation: AudioExpectation,
};

pub fn main(init: std.process.Init) !void {
    var owned_children = OwnedChildren{};
    const success = runVerifier(init, &owned_children) catch |primary_error| {
        owned_children.cleanup(init.io) catch |cleanup_error| {
            std.log.err(
                "Verifier cleanup failure appended after primary failure: primary={s} cleanup={s}",
                .{ @errorName(primary_error), @errorName(cleanup_error) },
            );
        };
        return primary_error;
    };
    defer init.gpa.free(success.evidence_root);
    try owned_children.cleanup(init.io);
    try printVerificationSuccess(init.io, success.evidence_root, success.asset_mode, success.audio_expectation);
}

fn runVerifier(init: std.process.Init, owned_children: *OwnedChildren) !VerifierSuccess {
    const allocator = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 4 or args.len > 7) return error.InvalidVerifierArguments;

    const platform_test_path = try std.Io.Dir.cwd().realPathFileAlloc(io, args[1], allocator);
    defer allocator.free(platform_test_path);
    const runtime_path = try std.Io.Dir.cwd().realPathFileAlloc(io, args[2], allocator);
    defer allocator.free(runtime_path);
    const profile = args[3];
    const asset_mode: AssetMode = switch (args.len) {
        4 => .generated_fixture,
        5, 6 => .package_root,
        7 => if (std.mem.eql(u8, args[6], "neutral-fixture")) .neutral_fixture else return error.InvalidVerifierArguments,
        else => unreachable,
    };
    const package_root = if (asset_mode == .package_root) args[4] else null;
    const neutral_scene_path = if (asset_mode == .neutral_fixture)
        try std.Io.Dir.cwd().realPathFileAlloc(io, args[4], allocator)
    else
        null;
    defer if (neutral_scene_path) |path| allocator.free(path);
    const neutral_script_path = if (asset_mode == .neutral_fixture)
        try std.Io.Dir.cwd().realPathFileAlloc(io, args[5], allocator)
    else
        null;
    defer if (neutral_script_path) |path| allocator.free(path);
    const audio_expectation: AudioExpectation = switch (args.len) {
        4, 7 => .not_applicable,
        5 => .alsa,
        6 => if (std.mem.eql(u8, args[5], "expect-silent-audio")) .silent else return error.InvalidVerifierArguments,
        else => unreachable,
    };

    const current_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(current_path);
    const evidence_root = try std.fmt.allocPrint(
        allocator,
        "{s}/.zig-cache/linux-window-evidence/{s}-{d}-{d}",
        .{ current_path, profile, c.getpid(), c.time(null) },
    );
    errdefer allocator.free(evidence_root);
    try std.Io.Dir.cwd().createDirPath(io, evidence_root);

    if (asset_mode != .package_root) {
        const fixture_assets = try std.fs.path.join(allocator, &.{ evidence_root, "fixture", "assets", "renderer2d" });
        defer allocator.free(fixture_assets);
        try std.Io.Dir.cwd().createDirPath(io, fixture_assets);
        try writeTextureFixture(io, allocator, fixture_assets, "test.texture", primary_fixture);
        try writeTextureFixture(io, allocator, fixture_assets, "goal.texture", secondary_fixture);
        const fixture_scenes = try std.fs.path.join(allocator, &.{ evidence_root, "fixture", "assets", "scenes" });
        defer allocator.free(fixture_scenes);
        try std.Io.Dir.cwd().createDirPath(io, fixture_scenes);
        try writeSceneFixture(io, allocator, fixture_scenes);
    }

    var environment = try init.environ_map.clone(allocator);
    defer environment.deinit();
    const driver_path = environment.get("KADATH_LVP_ICD") orelse return error.LavapipeDriverPathMissing;
    const layer_path = environment.get("KADATH_VULKAN_LAYER_PATH") orelse return error.ValidationLayerPathMissing;
    try environment.put("VK_DRIVER_FILES", driver_path);
    try environment.put("VK_ICD_FILENAMES", driver_path);
    try environment.put("VK_LAYER_PATH", layer_path);
    try environment.put("VK_INSTANCE_LAYERS", "VK_LAYER_KHRONOS_validation");
    switch (audio_expectation) {
        .not_applicable => {},
        .alsa => try environment.put("KADATH_AUDIO_DEVICE", "null"),
        .silent => try environment.put("KADATH_AUDIO_DEVICE", "kadath-invalid-device"),
    }

    const xvfb_log = try std.fs.path.join(allocator, &.{ evidence_root, "xvfb.log" });
    defer allocator.free(xvfb_log);
    const xvfb = try startOwnedXvfb(io, allocator, xvfb_log, 5_000);
    owned_children.xvfb = xvfb.child;
    const display = try std.fmt.allocPrint(allocator, "localhost:{d}", .{xvfb.display_number});
    defer allocator.free(display);
    try environment.put("DISPLAY", display);

    const metadata = try std.fmt.allocPrint(
        allocator,
        "profile={s}\ndisplay={s}\ndriver={s}\nvalidation_layer_path={s}\nplatform_test={s}\nruntime={s}\nasset_mode={s}\naudio_expectation={s}\n",
        .{ profile, display, driver_path, layer_path, platform_test_path, runtime_path, @tagName(asset_mode), @tagName(audio_expectation) },
    );
    defer allocator.free(metadata);
    const metadata_path = try std.fs.path.join(allocator, &.{ evidence_root, "metadata.txt" });
    defer allocator.free(metadata_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = metadata_path, .data = metadata });

    const vulkan_stdout = try std.fs.path.join(allocator, &.{ evidence_root, "vulkaninfo.stdout.log" });
    defer allocator.free(vulkan_stdout);
    const vulkan_stderr = try std.fs.path.join(allocator, &.{ evidence_root, "vulkaninfo.stderr.log" });
    defer allocator.free(vulkan_stderr);
    const vulkan_result = try runCaptured(
        allocator,
        io,
        &environment,
        "vulkaninfo",
        &.{ "timeout", "--kill-after=2s", "20s", "vulkaninfo", "--summary" },
        .inherit,
        vulkan_stdout,
        vulkan_stderr,
    );
    defer allocator.free(vulkan_result.stdout);
    defer allocator.free(vulkan_result.stderr);
    try validateVulkanPreflight(vulkan_result.stdout, vulkan_result.stderr);

    const platform_stdout = try std.fs.path.join(allocator, &.{ evidence_root, "platform-contract.stdout.log" });
    defer allocator.free(platform_stdout);
    const platform_stderr = try std.fs.path.join(allocator, &.{ evidence_root, "platform-contract.stderr.log" });
    defer allocator.free(platform_stderr);
    const platform_result = try runCaptured(
        allocator,
        io,
        &environment,
        "platform-contract",
        &.{ "timeout", "--kill-after=2s", "20s", platform_test_path },
        .inherit,
        platform_stdout,
        platform_stderr,
    );
    defer allocator.free(platform_result.stdout);
    defer allocator.free(platform_result.stderr);

    const runtime_stdout = try std.fs.path.join(allocator, &.{ evidence_root, "runtime.stdout.log" });
    defer allocator.free(runtime_stdout);
    const runtime_stderr = try std.fs.path.join(allocator, &.{ evidence_root, "runtime.stderr.log" });
    defer allocator.free(runtime_stderr);
    owned_children.runtime = try spawnRuntime(
        allocator,
        io,
        runtime_path,
        package_root orelse evidence_root,
        asset_mode,
        neutral_scene_path,
        neutral_script_path,
        &environment,
        runtime_stdout,
        runtime_stderr,
    );
    const runtime = &owned_children.runtime.?;
    const runtime_pid: u32 = @intCast(runtime.id.?);

    var observer = try connectXcb(allocator, display);
    defer observer.deinit();
    const runtime_window = try waitForRuntimeWindow(&observer, runtime, runtime_pid, 5_000);
    const window_info = try queryWindowInfo(&observer, runtime_window);
    if (window_info.width != initial_width or window_info.height != initial_height) {
        std.log.err("Runtime XCB extent mismatch: expected {d}x{d}, got {d}x{d}", .{
            initial_width,
            initial_height,
            window_info.width,
            window_info.height,
        });
        return error.RuntimeWindowExtentMismatch;
    }
    const pixel_layout = try queryPixelLayout(&observer, window_info);

    const frame_one_path = try std.fs.path.join(allocator, &.{ evidence_root, "frame-1.ppm" });
    defer allocator.free(frame_one_path);
    var frame_one = try waitForRenderedFrame(
        allocator,
        io,
        &observer,
        runtime,
        window_info,
        pixel_layout,
        evidence_root,
        asset_mode,
        5_000,
    );
    defer frame_one.deinit(allocator);
    try savePpm(io, allocator, frame_one_path, frame_one);

    sleepMilliseconds(150);

    const frame_two_path = try std.fs.path.join(allocator, &.{ evidence_root, "frame-2.ppm" });
    defer allocator.free(frame_two_path);
    var frame_two = try waitForRenderedFrame(
        allocator,
        io,
        &observer,
        runtime,
        window_info,
        pixel_layout,
        evidence_root,
        asset_mode,
        5_000,
    );
    defer frame_two.deinit(allocator);
    try savePpm(io, allocator, frame_two_path, frame_two);

    if (asset_mode == .neutral_fixture) {
        try validateNeutralFrames(frame_one, frame_two);
        try verifyNeutralReload(allocator, io, &observer, runtime, runtime_window, runtime_stderr);
    }

    if (audio_expectation == .alsa) {
        try verifyPackageAudioGameplay(allocator, io, &observer, runtime, runtime_window, runtime_stderr);
    }

    try sendClose(&observer, runtime_window);
    const exit_code = try waitForOwnedChild(runtime, 10_000);
    if (exit_code != 0) {
        std.log.err("Runtime exited with code {d}", .{exit_code});
        return error.RuntimeExitFailed;
    }

    const runtime_log = try std.Io.Dir.cwd().readFileAlloc(io, runtime_stderr, allocator, .limited(8 * 1024 * 1024));
    defer allocator.free(runtime_log);
    const runtime_out = try std.Io.Dir.cwd().readFileAlloc(io, runtime_stdout, allocator, .limited(8 * 1024 * 1024));
    defer allocator.free(runtime_out);
    try validateRuntimeLogs(runtime_log, runtime_out, asset_mode, audio_expectation);

    return .{ .evidence_root = evidence_root, .asset_mode = asset_mode, .audio_expectation = audio_expectation };
}

fn printVerificationSuccess(
    io: std.Io,
    evidence_root: []const u8,
    asset_mode: AssetMode,
    audio_expectation: AudioExpectation,
) !void {
    var stdout_buffer: [2048]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print("linux_platform_contract=ok\n", .{});
    try stdout.print("linux_vulkan_driver=lavapipe\n", .{});
    try stdout.print("linux_validation_layer=ok\n", .{});
    try stdout.print("linux_window_owner=ok\n", .{});
    try stdout.print("linux_window_extent=960x540\n", .{});
    try stdout.print("linux_background_pixels=ok\n", .{});
    try stdout.print("linux_primary_texture_pixels=ok\n", .{});
    try stdout.print("linux_secondary_texture_pixels=ok\n", .{});
    if (asset_mode != .package_root) try stdout.print("linux_scene_texture_binding=ok\n", .{});
    try stdout.print("linux_two_frame_evidence=ok\n", .{});
    if (asset_mode == .neutral_fixture) {
        // 这些字段只在对应产品观察全部通过后输出；VS02 gate 独立输出第九个兼容性字段。
        try stdout.print("SCENE_MODE=neutral\n", .{});
        try stdout.print("GAMEPLAY_ACTIVE=false\n", .{});
        try stdout.print("BEHAVIOR_MOVEMENT_OBSERVED=true\n", .{});
        try stdout.print("TRANSIENT_OBJECT_OBSERVED=true\n", .{});
        try stdout.print("RENDER_SNAPSHOT_OBSERVED=true\n", .{});
        try stdout.print("OUTCOME_COUNT=0\n", .{});
        try stdout.print("GAMEPLAY_AUDIO_CUE_COUNT=0\n", .{});
        try stdout.print("RELOAD_COMMITTED=true\n", .{});
    }
    switch (audio_expectation) {
        .not_applicable => {},
        .alsa => {
            try stdout.print("linux_audio_backend=alsa\n", .{});
            try stdout.print("linux_audio_lost_cue=ok\n", .{});
            try stdout.print("linux_audio_won_cue=ok\n", .{});
        },
        .silent => try stdout.print("linux_audio_fallback=silent\n", .{}),
    }
    try stdout.print("linux_close_exit=0\n", .{});
    try stdout.print("linux_owned_cleanup=ok\n", .{});
    try stdout.print("asset_mode={s}\n", .{@tagName(asset_mode)});
    try stdout.print("evidence_root={s}\n", .{evidence_root});
    try stdout.flush();
}

fn writeTextureFixture(
    io: std.Io,
    allocator: std.mem.Allocator,
    directory: []const u8,
    name: []const u8,
    color: Color,
) !void {
    var artifact: [44]u8 = undefined;
    @memcpy(artifact[0..4], "KDAT");
    writeLittleU32(artifact[4..8], 2);
    writeLittleU32(artifact[8..12], 2);
    writeLittleU32(artifact[12..16], 2);
    writeLittleU32(artifact[16..20], 2);
    writeLittleU32(artifact[20..24], 20);
    var offset: usize = 24;
    while (offset < artifact.len) : (offset += 4) {
        artifact[offset] = color.r;
        artifact[offset + 1] = color.g;
        artifact[offset + 2] = color.b;
        artifact[offset + 3] = 255;
    }
    const path = try std.fs.path.join(allocator, &.{ directory, name });
    defer allocator.free(path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = &artifact });
}

fn writeLittleU32(destination: []u8, value: u32) void {
    destination[0] = @truncate(value);
    destination[1] = @truncate(value >> 8);
    destination[2] = @truncate(value >> 16);
    destination[3] = @truncate(value >> 24);
}

fn writeLittleF32(destination: []u8, value: f32) void {
    writeLittleU32(destination, @bitCast(value));
}

fn writeSceneFixture(io: std.Io, allocator: std.mem.Allocator, directory: []const u8) !void {
    const primary = "assets/renderer2d/test.texture";
    const secondary = "assets/renderer2d/goal.texture";
    var artifact: [258]u8 = @splat(0);
    @memcpy(artifact[0..4], "KSCN");
    writeLittleU32(artifact[4..8], 3);
    writeLittleU32(artifact[8..12], 3);
    writeLittleU32(artifact[12..16], 242);
    const values = [_]f32{
        312, 130, 320, 240,  1,    1,    1,    1,   180,
        700, 200, 96,  96,   1,    0.75, 0.10, 1,   650,
        280, 96,  96,  0.95, 0.20, 0.20, 1,    245, 330,
        80,
    };
    for (values, 0..) |value, index| writeLittleF32(artifact[16 + index * 4 ..][0..4], value);
    writeLittleU32(artifact[128..132], 2);
    writeLittleU32(artifact[132..136], 1);
    writeLittleU32(artifact[136..140], 3);
    var cursor: usize = 140;
    writeLittleU32(artifact[cursor..][0..4], 3);
    cursor += 4;
    const entries = [_]struct { id: u32, path: []const u8 }{
        .{ .id = 1, .path = primary },
        .{ .id = 2, .path = secondary },
        .{ .id = 3, .path = secondary },
    };
    for (entries) |entry| {
        writeLittleU32(artifact[cursor..][0..4], entry.id);
        writeLittleU32(artifact[cursor + 4 ..][0..4], @intCast(entry.path.len));
        cursor += 8;
        @memcpy(artifact[cursor .. cursor + entry.path.len], entry.path);
        cursor += entry.path.len;
    }
    const path = try std.fs.path.join(allocator, &.{ directory, "preview.scene" });
    defer allocator.free(path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = &artifact });
}

const OwnedXvfb = struct {
    child: std.process.Child,
    display_number: u16,
};

fn startOwnedXvfb(
    io: std.Io,
    allocator: std.mem.Allocator,
    log_path: []const u8,
    timeout_ms: u32,
) !OwnedXvfb {
    var log_file = try std.Io.Dir.cwd().createFile(io, log_path, .{});
    defer log_file.close(io);
    var child = try std.process.spawn(io, .{
        .argv = &.{
            "Xvfb",
            "-displayfd",
            "1",
            "-screen",
            "0",
            "1024x768x24",
            "-nolisten",
            "unix",
            "-listen",
            "tcp",
            "-noreset",
        },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .{ .file = log_file },
    });
    errdefer _ = terminateOwnedChildBounded(io, &child, 100, 1_000) catch |cleanup_error| {
        std.log.err("Owned Xvfb startup cleanup failed: {s}", .{@errorName(cleanup_error)});
    };

    const display_number = try readOwnedXvfbDisplayNumber(io, &child, timeout_ms);
    const display = try std.fmt.allocPrint(allocator, "localhost:{d}", .{display_number});
    defer allocator.free(display);
    try waitForOwnedDisplay(io, allocator, &child, display, timeout_ms);
    return .{ .child = child, .display_number = display_number };
}

fn readOwnedXvfbDisplayNumber(io: std.Io, child: *std.process.Child, timeout_ms: u32) !u16 {
    var display_buffer: [32]u8 = undefined;
    var display_length: usize = 0;
    var elapsed: u32 = 0;
    while (elapsed < timeout_ms) {
        if (try pollOwnedChild(io, child)) return error.XvfbExitedBeforeDisplayAssignment;
        const stdout_file = child.stdout orelse return error.XvfbDisplayPipeMissing;
        var poll_fd = [_]std.posix.pollfd{.{
            .fd = stdout_file.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const wait_ms = @min(@as(u32, 25), timeout_ms - elapsed);
        const ready = try std.posix.poll(&poll_fd, @intCast(wait_ms));
        elapsed += wait_ms;
        if (ready == 0) continue;
        if ((poll_fd[0].revents & std.posix.POLL.NVAL) != 0) return error.XvfbDisplayPipeInvalid;
        if ((poll_fd[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP)) == 0) continue;
        if (display_length == display_buffer.len) return error.XvfbDisplayNumberTooLong;
        const count = try std.posix.read(stdout_file.handle, display_buffer[display_length..]);
        if (count == 0) return error.XvfbDisplayPipeClosed;
        display_length += count;
        if (std.mem.indexOfScalar(u8, display_buffer[0..display_length], '\n')) |newline| {
            const display_number = std.fmt.parseInt(
                u16,
                std.mem.trim(u8, display_buffer[0..newline], " \t\r"),
                10,
            ) catch return error.XvfbDisplayNumberInvalid;
            stdout_file.close(io);
            child.stdout = null;
            return display_number;
        }
    }
    return error.XvfbDisplayAssignmentTimeout;
}

fn waitForOwnedDisplay(
    io: std.Io,
    allocator: std.mem.Allocator,
    child: *std.process.Child,
    display: []const u8,
    timeout_ms: u32,
) !void {
    const display_z = try allocator.dupeZ(u8, display);
    defer allocator.free(display_z);
    var elapsed: u32 = 0;
    while (elapsed < timeout_ms) : (elapsed += 25) {
        if (try pollOwnedChild(io, child)) return error.XvfbExitedBeforeReadiness;
        var screen_index: c_int = 0;
        const connection = c.xcb_connect(display_z.ptr, &screen_index);
        if (connection != null) {
            const ready = c.xcb_connection_has_error(connection) == 0;
            c.xcb_disconnect(connection);
            if (ready) {
                if (try pollOwnedChild(io, child)) return error.XvfbExitedBeforeReadiness;
                return;
            }
        }
        sleepMilliseconds(25);
    }
    return error.XvfbReadinessTimeout;
}

fn runCaptured(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    command_name: []const u8,
    argv: []const []const u8,
    cwd: std.process.Child.Cwd,
    stdout_path: []const u8,
    stderr_path: []const u8,
) !std.process.RunResult {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = cwd,
        .environ_map = environment,
        .stdout_limit = .limited(8 * 1024 * 1024),
        .stderr_limit = .limited(8 * 1024 * 1024),
    });
    errdefer allocator.free(result.stdout);
    errdefer allocator.free(result.stderr);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = stdout_path, .data = result.stdout });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = stderr_path, .data = result.stderr });
    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.log.err("Child command failed with exit code {d}: {s}", .{ code, command_name });
            return error.VerifierChildFailed;
        },
        else => {
            std.log.err("Child command terminated abnormally: {s}", .{command_name});
            return error.VerifierChildFailed;
        },
    }
    return result;
}

fn validateVulkanPreflight(stdout: []const u8, stderr: []const u8) !void {
    const forbidden_diagnostics = [_][]const u8{
        "VUID-",
        "Validation Error",
    };
    for (forbidden_diagnostics) |needle| {
        if (containsEither(stdout, stderr, needle)) {
            return error.VulkanPreflightDiagnostic;
        }
    }
    if (containsLinePrefixIgnoreCase(stdout, "error:") or
        containsLinePrefixIgnoreCase(stderr, "error:"))
    {
        return error.VulkanPreflightDiagnostic;
    }
    if (!containsEither(stdout, stderr, "VK_KHR_surface") or
        !containsEither(stdout, stderr, "VK_KHR_xcb_surface"))
    {
        return error.VulkanSurfaceExtensionMissing;
    }
    if (!containsEither(stdout, stderr, "adding layers \"VK_LAYER_KHRONOS_validation\"")) {
        return error.ValidationLayerInactive;
    }
    if (!containsEither(stdout, stderr, "llvmpipe") or
        !containsEither(stdout, stderr, "DRIVER_ID_MESA_LLVMPIPE"))
    {
        return error.LavapipeDriverInactive;
    }
}

fn containsEither(first: []const u8, second: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, first, needle) != null or std.mem.indexOf(u8, second, needle) != null;
}

fn spawnRuntime(
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime_path: []const u8,
    working_root: []const u8,
    asset_mode: AssetMode,
    neutral_scene_path: ?[]const u8,
    neutral_script_path: ?[]const u8,
    environment: *const std.process.Environ.Map,
    stdout_path: []const u8,
    stderr_path: []const u8,
) !std.process.Child {
    var stdout_file = try std.Io.Dir.cwd().createFile(io, stdout_path, .{});
    defer stdout_file.close(io);
    var stderr_file = try std.Io.Dir.cwd().createFile(io, stderr_path, .{});
    defer stderr_file.close(io);
    const fixture_root = if (asset_mode != .package_root)
        try std.fs.path.join(allocator, &.{ working_root, "fixture" })
    else
        try allocator.dupe(u8, working_root);
    defer allocator.free(fixture_root);
    const package_argv = [_][]const u8{
        runtime_path,
        "--scene",
        "assets/scenes/preview.scene",
        "--script",
        "assets/scripts/preview.script",
    };
    const fixture_argv = [_][]const u8{ runtime_path, "--scene", "assets/scenes/preview.scene" };
    const neutral_argv = [_][]const u8{
        runtime_path,
        "--scene",
        neutral_scene_path orelse "",
        "--script",
        neutral_script_path orelse "",
    };
    return try std.process.spawn(io, .{
        .argv = switch (asset_mode) {
            .generated_fixture => &fixture_argv,
            .package_root => &package_argv,
            .neutral_fixture => &neutral_argv,
        },
        .cwd = .{ .path = fixture_root },
        .environ_map = environment,
        .stdin = .ignore,
        .stdout = .{ .file = stdout_file },
        .stderr = .{ .file = stderr_file },
    });
}

fn connectXcb(allocator: std.mem.Allocator, display: []const u8) !XcbContext {
    const display_z = try allocator.dupeZ(u8, display);
    defer allocator.free(display_z);
    var screen_index: c_int = 0;
    const connection_result = c.xcb_connect(display_z.ptr, &screen_index);
    if (connection_result == null or c.xcb_connection_has_error(connection_result) != 0) {
        if (connection_result != null) c.xcb_disconnect(connection_result);
        return error.XcbObserverConnectionFailed;
    }
    const connection = connection_result.?;
    errdefer c.xcb_disconnect(connection);
    const setup = c.xcb_get_setup(connection) orelse return error.XcbObserverSetupMissing;
    var screen_iterator = c.xcb_setup_roots_iterator(setup);
    var remaining_index = screen_index;
    while (remaining_index > 0 and screen_iterator.rem > 0) : (remaining_index -= 1) {
        c.xcb_screen_next(&screen_iterator);
    }
    if (screen_iterator.rem == 0 or screen_iterator.data == null) return error.XcbObserverScreenMissing;
    return .{ .connection = connection, .setup = setup, .screen = screen_iterator.data.? };
}

fn waitForRuntimeWindow(
    context: *XcbContext,
    runtime: *std.process.Child,
    expected_pid: u32,
    timeout_ms: u32,
) !c.xcb_window_t {
    const pid_atom = try internAtom(context.connection, "_NET_WM_PID");
    var elapsed: u32 = 0;
    while (elapsed < timeout_ms) : (elapsed += 25) {
        try ensureChildRunning(runtime);
        var protocol_error: ?*c.xcb_generic_error_t = null;
        const reply = c.xcb_query_tree_reply(
            context.connection,
            c.xcb_query_tree(context.connection, context.screen.*.root),
            &protocol_error,
        );
        if (protocol_error) |xcb_error| {
            c.free(xcb_error);
            if (reply != null) c.free(reply);
            return error.XcbQueryTreeFailed;
        }
        if (reply == null) return error.XcbQueryTreeFailed;
        defer c.free(reply);
        const count: usize = @intCast(c.xcb_query_tree_children_length(reply));
        const children: [*]const c.xcb_window_t = @ptrCast(c.xcb_query_tree_children(reply));
        for (children[0..count]) |window| {
            const owner = try readWindowPid(context.connection, window, pid_atom);
            if (owner == null or owner.? != expected_pid) continue;
            if (!try windowTitleEquals(context.connection, window, "Kadath Runtime")) continue;
            return window;
        }
        sleepMilliseconds(25);
    }
    return error.RuntimeWindowDiscoveryTimeout;
}

fn readWindowPid(
    connection: *c.xcb_connection_t,
    window: c.xcb_window_t,
    pid_atom: c.xcb_atom_t,
) !?u32 {
    var protocol_error: ?*c.xcb_generic_error_t = null;
    const reply = c.xcb_get_property_reply(
        connection,
        c.xcb_get_property(connection, 0, window, pid_atom, c.XCB_ATOM_CARDINAL, 0, 1),
        &protocol_error,
    );
    if (protocol_error) |xcb_error| {
        c.free(xcb_error);
        if (reply != null) c.free(reply);
        return error.XcbWindowPropertyFailed;
    }
    if (reply == null) return error.XcbWindowPropertyFailed;
    defer c.free(reply);
    if (reply.*.format != 32 or c.xcb_get_property_value_length(reply) < 4) return null;
    const bytes: [*]const u8 = @ptrCast(c.xcb_get_property_value(reply));
    var process_id: u32 = 0;
    @memcpy(std.mem.asBytes(&process_id), bytes[0..4]);
    return process_id;
}

fn windowTitleEquals(
    connection: *c.xcb_connection_t,
    window: c.xcb_window_t,
    expected: []const u8,
) !bool {
    var protocol_error: ?*c.xcb_generic_error_t = null;
    const reply = c.xcb_get_property_reply(
        connection,
        c.xcb_get_property(connection, 0, window, c.XCB_ATOM_WM_NAME, c.XCB_GET_PROPERTY_TYPE_ANY, 0, 128),
        &protocol_error,
    );
    if (protocol_error) |xcb_error| {
        c.free(xcb_error);
        if (reply != null) c.free(reply);
        return error.XcbWindowPropertyFailed;
    }
    if (reply == null) return error.XcbWindowPropertyFailed;
    defer c.free(reply);
    const length: usize = @intCast(c.xcb_get_property_value_length(reply));
    if (length != expected.len) return false;
    const bytes: [*]const u8 = @ptrCast(c.xcb_get_property_value(reply));
    return std.mem.eql(u8, bytes[0..length], expected);
}

fn queryWindowInfo(context: *XcbContext, window: c.xcb_window_t) !WindowInfo {
    var attributes_error: ?*c.xcb_generic_error_t = null;
    const attributes = c.xcb_get_window_attributes_reply(
        context.connection,
        c.xcb_get_window_attributes(context.connection, window),
        &attributes_error,
    );
    if (attributes_error) |xcb_error| {
        c.free(xcb_error);
        if (attributes != null) c.free(attributes);
        return error.XcbWindowAttributesFailed;
    }
    if (attributes == null) return error.XcbWindowAttributesFailed;
    defer c.free(attributes);

    var geometry_error: ?*c.xcb_generic_error_t = null;
    const geometry = c.xcb_get_geometry_reply(
        context.connection,
        c.xcb_get_geometry(context.connection, window),
        &geometry_error,
    );
    if (geometry_error) |xcb_error| {
        c.free(xcb_error);
        if (geometry != null) c.free(geometry);
        return error.XcbWindowGeometryFailed;
    }
    if (geometry == null) return error.XcbWindowGeometryFailed;
    defer c.free(geometry);
    return .{
        .window = window,
        .visual = attributes.*.visual,
        .depth = geometry.*.depth,
        .width = geometry.*.width,
        .height = geometry.*.height,
    };
}

fn queryPixelLayout(context: *XcbContext, window: WindowInfo) !PixelLayout {
    var bits_per_pixel: u8 = 0;
    var scanline_pad: u8 = 0;
    var format_iterator = c.xcb_setup_pixmap_formats_iterator(context.setup);
    while (format_iterator.rem > 0 and format_iterator.data != null) {
        if (format_iterator.data.?.*.depth == window.depth) {
            bits_per_pixel = format_iterator.data.?.*.bits_per_pixel;
            scanline_pad = format_iterator.data.?.*.scanline_pad;
            break;
        }
        c.xcb_format_next(&format_iterator);
    }
    if (bits_per_pixel == 0 or scanline_pad == 0) return error.XcbPixmapFormatMissing;

    var red_mask: u32 = 0;
    var green_mask: u32 = 0;
    var blue_mask: u32 = 0;
    var depth_iterator = c.xcb_screen_allowed_depths_iterator(context.screen);
    depth_loop: while (depth_iterator.rem > 0 and depth_iterator.data != null) {
        if (depth_iterator.data.?.*.depth == window.depth) {
            var visual_iterator = c.xcb_depth_visuals_iterator(depth_iterator.data.?);
            while (visual_iterator.rem > 0 and visual_iterator.data != null) {
                const visual = visual_iterator.data.?.*;
                if (visual.visual_id == window.visual) {
                    red_mask = visual.red_mask;
                    green_mask = visual.green_mask;
                    blue_mask = visual.blue_mask;
                    break :depth_loop;
                }
                c.xcb_visualtype_next(&visual_iterator);
            }
        }
        c.xcb_depth_next(&depth_iterator);
    }
    if (red_mask == 0 or green_mask == 0 or blue_mask == 0) return error.XcbVisualMasksMissing;
    return .{
        .byte_order = context.setup.*.image_byte_order,
        .bits_per_pixel = bits_per_pixel,
        .scanline_pad = scanline_pad,
        .red_mask = red_mask,
        .green_mask = green_mask,
        .blue_mask = blue_mask,
    };
}

fn waitForRenderedFrame(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: *XcbContext,
    runtime: *std.process.Child,
    window: WindowInfo,
    layout: PixelLayout,
    evidence_root: []const u8,
    asset_mode: AssetMode,
    timeout_ms: u32,
) !Capture {
    const expected_background = Color{
        .r = linearToSrgbByte(0.035),
        .g = linearToSrgbByte(0.10),
        .b = linearToSrgbByte(0.22),
    };
    const expected_primary = tintedSrgb(secondary_fixture, .{ 1.0, 1.0, 1.0 });
    const expected_secondary = tintedSrgb(primary_fixture, .{ 1.0, 0.75, 0.10 });
    const package_goal_left = tintedSrgb(.{ .r = 255, .g = 0, .b = 255 }, .{ 1.0, 0.75, 0.10 });
    const package_goal_right = tintedSrgb(.{ .r = 0, .g = 255, .b = 255 }, .{ 1.0, 0.75, 0.10 });
    const neutral_backdrop = tintedSrgb(primary_fixture, .{ 0.22, 0.34, 0.58 });
    const neutral_mover = tintedSrgb(secondary_fixture, .{ 0.95, 0.82, 0.28 });
    const neutral_marker = tintedSrgb(secondary_fixture, .{ 0.30, 0.90, 0.95 });
    var last_capture: ?Capture = null;
    defer if (last_capture) |*capture| capture.deinit(allocator);

    var elapsed: u32 = 0;
    while (elapsed < timeout_ms) : (elapsed += 50) {
        try ensureChildRunning(runtime);
        var capture = try captureWindow(allocator, context, window, layout);
        const background = capture.sample(20, 20);
        const primary = capture.sample(450, 200);
        const secondary = capture.sample(748, 224);
        const pixels_match = switch (asset_mode) {
            .generated_fixture => colorNear(background, expected_background, sample_tolerance) and
                colorNear(primary, expected_primary, sample_tolerance) and
                colorNear(secondary, expected_secondary, sample_tolerance),
            .package_root => colorNear(background, expected_background, sample_tolerance) and
                colorNear(primary, package_primary_expected, package_sample_tolerance) and
                hasPackageGoalSignature(capture, package_goal_left, package_goal_right),
            .neutral_fixture => colorNear(background, expected_background, sample_tolerance) and
                colorNear(capture.sample(450, 350), neutral_backdrop, package_sample_tolerance) and
                colorStats(capture, neutral_mover, package_sample_tolerance).count >= 256 and
                colorStats(capture, neutral_marker, package_sample_tolerance).count >= 128,
        };
        if (pixels_match) {
            if (last_capture) |*previous| previous.deinit(allocator);
            last_capture = null;
            return capture;
        }
        if (last_capture) |*previous| previous.deinit(allocator);
        last_capture = capture;
        sleepMilliseconds(50);
    }

    if (last_capture) |capture| {
        const last_capture_path = try std.fs.path.join(allocator, &.{ evidence_root, "last-capture.ppm" });
        defer allocator.free(last_capture_path);
        savePpm(io, allocator, last_capture_path, capture) catch {};
        const background = capture.sample(20, 20);
        const primary = capture.sample(450, 200);
        const secondary = capture.sample(748, 224);
        std.log.err(
            "Pixel evidence timeout: background=({d},{d},{d}) primary=({d},{d},{d}) secondary=({d},{d},{d})",
            .{ background.r, background.g, background.b, primary.r, primary.g, primary.b, secondary.r, secondary.g, secondary.b },
        );
    }
    return error.RuntimePixelEvidenceTimeout;
}

const ColorStats = struct {
    count: usize = 0,
    sum_x: usize = 0,

    fn centroidX(self: ColorStats) ?f64 {
        if (self.count == 0) return null;
        return @as(f64, @floatFromInt(self.sum_x)) / @as(f64, @floatFromInt(self.count));
    }
};

fn colorStats(capture: Capture, expected: Color, tolerance: u8) ColorStats {
    var result = ColorStats{};
    var y: u16 = 0;
    while (y < capture.height) : (y += 1) {
        var x: u16 = 0;
        while (x < capture.width) : (x += 1) {
            if (!colorNear(capture.sample(x, y), expected, tolerance)) continue;
            result.count += 1;
            result.sum_x += x;
        }
    }
    return result;
}

fn validateNeutralFrames(first: Capture, second: Capture) !void {
    const mover = tintedSrgb(secondary_fixture, .{ 0.95, 0.82, 0.28 });
    const marker = tintedSrgb(secondary_fixture, .{ 0.30, 0.90, 0.95 });
    const first_mover = colorStats(first, mover, package_sample_tolerance);
    const second_mover = colorStats(second, mover, package_sample_tolerance);
    if (first_mover.count < 256 or second_mover.count < 256)
        return error.NeutralMoverRenderEvidenceMissing;
    if (colorStats(first, marker, package_sample_tolerance).count < 128 and
        colorStats(second, marker, package_sample_tolerance).count < 128)
    {
        return error.NeutralTransientRenderEvidenceMissing;
    }
    const first_x = first_mover.centroidX() orelse return error.NeutralMoverRenderEvidenceMissing;
    const second_x = second_mover.centroidX() orelse return error.NeutralMoverRenderEvidenceMissing;
    if (second_x < first_x + 2.0) return error.NeutralBehaviorMovementEvidenceMissing;
}

fn hasPackageGoalSignature(capture: Capture, expected_left: Color, expected_right: Color) bool {
    const row: u16 = 224;
    if (capture.height <= row or capture.width <= 600) return false;
    const scan_end: u16 = @min(capture.width, 840);
    var left_x: u16 = 600;
    while (left_x < scan_end) : (left_x += 1) {
        if (!colorNear(capture.sample(left_x, row), expected_left, 5)) continue;
        var right_x = left_x + 48;
        const right_end: u16 = @min(scan_end, left_x + 97);
        while (right_x < right_end) : (right_x += 1) {
            if (colorNear(capture.sample(right_x, row), expected_right, 32)) return true;
        }
    }
    return false;
}

fn colorDistance(first: Color, second: Color) u16 {
    return channelDistance(first.r, second.r) + channelDistance(first.g, second.g) + channelDistance(first.b, second.b);
}

fn channelDistance(first: u8, second: u8) u16 {
    return if (first >= second) first - second else second - first;
}

fn captureWindow(
    allocator: std.mem.Allocator,
    context: *XcbContext,
    window: WindowInfo,
    layout: PixelLayout,
) !Capture {
    var protocol_error: ?*c.xcb_generic_error_t = null;
    const reply = c.xcb_get_image_reply(
        context.connection,
        c.xcb_get_image(
            context.connection,
            c.XCB_IMAGE_FORMAT_Z_PIXMAP,
            window.window,
            0,
            0,
            window.width,
            window.height,
            std.math.maxInt(u32),
        ),
        &protocol_error,
    );
    if (protocol_error) |xcb_error| {
        c.free(xcb_error);
        if (reply != null) c.free(reply);
        return error.XcbGetImageFailed;
    }
    if (reply == null) return error.XcbGetImageFailed;
    defer c.free(reply);

    const bytes_per_pixel: usize = (@as(usize, layout.bits_per_pixel) + 7) / 8;
    const row_bits = @as(usize, window.width) * layout.bits_per_pixel;
    const stride_bits = ((row_bits + layout.scanline_pad - 1) / layout.scanline_pad) * layout.scanline_pad;
    const stride = stride_bits / 8;
    const data_length: usize = @intCast(c.xcb_get_image_data_length(reply));
    if (data_length < stride * window.height) return error.XcbImagePayloadTooShort;
    const source: [*]const u8 = @ptrCast(c.xcb_get_image_data(reply));
    const rgb = try allocator.alloc(u8, @as(usize, window.width) * window.height * 3);
    errdefer allocator.free(rgb);

    var y: usize = 0;
    while (y < window.height) : (y += 1) {
        var x: usize = 0;
        while (x < window.width) : (x += 1) {
            const source_offset = y * stride + x * bytes_per_pixel;
            const pixel = readServerPixel(source[source_offset .. source_offset + bytes_per_pixel], layout.byte_order);
            const destination = (y * window.width + x) * 3;
            rgb[destination] = scaleMasked(pixel, layout.red_mask);
            rgb[destination + 1] = scaleMasked(pixel, layout.green_mask);
            rgb[destination + 2] = scaleMasked(pixel, layout.blue_mask);
        }
    }
    return .{ .width = window.width, .height = window.height, .rgb = rgb };
}

fn readServerPixel(bytes: []const u8, byte_order: u8) u32 {
    var value: u32 = 0;
    if (byte_order == c.XCB_IMAGE_ORDER_LSB_FIRST) {
        for (bytes, 0..) |byte, index| value |= @as(u32, byte) << @intCast(index * 8);
    } else {
        for (bytes) |byte| value = (value << 8) | byte;
    }
    return value;
}

fn scaleMasked(pixel: u32, mask: u32) u8 {
    const shift = @ctz(mask);
    const maximum = mask >> @intCast(shift);
    const value = (pixel & mask) >> @intCast(shift);
    return @intCast((@as(u64, value) * 255 + maximum / 2) / maximum);
}

fn savePpm(io: std.Io, allocator: std.mem.Allocator, path: []const u8, capture: Capture) !void {
    const header = try std.fmt.allocPrint(allocator, "P6\n{d} {d}\n255\n", .{ capture.width, capture.height });
    defer allocator.free(header);
    const output = try allocator.alloc(u8, header.len + capture.rgb.len);
    defer allocator.free(output);
    @memcpy(output[0..header.len], header);
    @memcpy(output[header.len..], capture.rgb);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = output });
}

fn tintedSrgb(color: Color, tint: [3]f64) Color {
    return .{
        .r = linearToSrgbByte(srgbByteToLinear(color.r) * tint[0]),
        .g = linearToSrgbByte(srgbByteToLinear(color.g) * tint[1]),
        .b = linearToSrgbByte(srgbByteToLinear(color.b) * tint[2]),
    };
}

fn srgbByteToLinear(value: u8) f64 {
    const normalized = @as(f64, @floatFromInt(value)) / 255.0;
    if (normalized <= 0.04045) return normalized / 12.92;
    return std.math.pow(f64, (normalized + 0.055) / 1.055, 2.4);
}

fn linearToSrgbByte(value: f64) u8 {
    const clamped = std.math.clamp(value, 0.0, 1.0);
    const encoded = if (clamped <= 0.0031308)
        clamped * 12.92
    else
        1.055 * std.math.pow(f64, clamped, 1.0 / 2.4) - 0.055;
    return @intFromFloat(@round(encoded * 255.0));
}

fn colorNear(actual: Color, expected: Color, tolerance: u8) bool {
    return channelNear(actual.r, expected.r, tolerance) and
        channelNear(actual.g, expected.g, tolerance) and
        channelNear(actual.b, expected.b, tolerance);
}

fn channelNear(actual: u8, expected: u8, tolerance: u8) bool {
    const difference = if (actual >= expected) actual - expected else expected - actual;
    return difference <= tolerance;
}

fn sendClose(context: *XcbContext, window: c.xcb_window_t) !void {
    const wm_protocols = try internAtom(context.connection, "WM_PROTOCOLS");
    const wm_delete_window = try internAtom(context.connection, "WM_DELETE_WINDOW");
    var event = std.mem.zeroes(c.xcb_client_message_event_t);
    event.response_type = c.XCB_CLIENT_MESSAGE;
    event.window = window;
    event.type = wm_protocols;
    event.format = 32;
    event.data.data32[0] = wm_delete_window;
    try checkRequest(context.connection, c.xcb_send_event_checked(
        context.connection,
        0,
        window,
        c.XCB_EVENT_MASK_NO_EVENT,
        @ptrCast(&event),
    ));
    if (c.xcb_flush(context.connection) <= 0) return error.XcbFlushFailed;
}

fn verifyNeutralReload(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: *XcbContext,
    runtime: *std.process.Child,
    window: c.xcb_window_t,
    runtime_stderr: []const u8,
) !void {
    const reload = try keycodeForKeysym(context.connection, c.XK_F5);
    try sendKey(context, window, reload, c.XCB_KEY_PRESS, 50);
    try sendKey(context, window, reload, c.XCB_KEY_RELEASE, 51);
    try waitForRuntimeLog(
        allocator,
        io,
        runtime,
        runtime_stderr,
        "Neutral scene reloaded explicitly: objects=2",
        3_000,
    );
}

fn verifyPackageAudioGameplay(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: *XcbContext,
    runtime: *std.process.Child,
    window: c.xcb_window_t,
    runtime_stderr: []const u8,
) !void {
    try waitForRuntimeLog(allocator, io, runtime, runtime_stderr, "Game session lost: timer expired, sequence=1", 5_000);
    try waitForRuntimeLog(allocator, io, runtime, runtime_stderr, "Audio cue played: lost", 2_000);

    const restart = try keycodeForKeysym(context.connection, c.XK_r);
    const up = try keycodeForKeysym(context.connection, c.XK_Up);
    const right = try keycodeForKeysym(context.connection, c.XK_Right);
    var timestamp: c.xcb_timestamp_t = 100;
    try sendKey(context, window, restart, c.XCB_KEY_PRESS, timestamp);
    timestamp += 1;
    try sendKey(context, window, restart, c.XCB_KEY_RELEASE, timestamp);
    try waitForRuntimeLog(allocator, io, runtime, runtime_stderr, "Game session restarted", 2_000);

    timestamp += 1;
    try sendKey(context, window, up, c.XCB_KEY_PRESS, timestamp);
    sleepMilliseconds(800);
    timestamp += 1;
    try sendKey(context, window, up, c.XCB_KEY_RELEASE, timestamp);
    sleepMilliseconds(50);

    timestamp += 1;
    try sendKey(context, window, right, c.XCB_KEY_PRESS, timestamp);
    sleepMilliseconds(450);
    timestamp += 1;
    try sendKey(context, window, right, c.XCB_KEY_RELEASE, timestamp);

    try waitForRuntimeLog(allocator, io, runtime, runtime_stderr, "Game session won: player=player overlapped goal=goal, sequence=2", 2_000);
    try waitForRuntimeLog(allocator, io, runtime, runtime_stderr, "Audio cue played: won", 2_000);

    const log = try std.Io.Dir.cwd().readFileAlloc(io, runtime_stderr, allocator, .limited(8 * 1024 * 1024));
    defer allocator.free(log);
    if (std.mem.count(u8, log, "Game session lost:") != 1 or
        std.mem.count(u8, log, "Game session won:") != 1 or
        std.mem.count(u8, log, "Audio cue played: lost") != 1 or
        std.mem.count(u8, log, "Audio cue played: won") != 1)
    {
        return error.GameplayOutcomeWasNotExactlyOnce;
    }
}

fn waitForRuntimeLog(
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime: *std.process.Child,
    path: []const u8,
    needle: []const u8,
    timeout_ms: u32,
) !void {
    var elapsed: u32 = 0;
    while (elapsed <= timeout_ms) : (elapsed += 25) {
        try ensureChildRunning(runtime);
        const log = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(8 * 1024 * 1024));
        defer allocator.free(log);
        if (std.mem.indexOf(u8, log, needle) != null) return;
        if (elapsed == timeout_ms) break;
        sleepMilliseconds(25);
    }
    std.log.err("Runtime log evidence timeout: {s}", .{needle});
    return error.RuntimeLogEvidenceTimeout;
}

fn keycodeForKeysym(connection: *c.xcb_connection_t, keysym: c.xcb_keysym_t) !c.xcb_keycode_t {
    const setup = c.xcb_get_setup(connection);
    if (setup == null) return error.XcbSetupUnavailable;
    const minimum = setup.*.min_keycode;
    const maximum = setup.*.max_keycode;
    const count: u8 = @intCast(@as(u16, maximum) - @as(u16, minimum) + 1);
    var protocol_error: ?*c.xcb_generic_error_t = null;
    const reply = c.xcb_get_keyboard_mapping_reply(
        connection,
        c.xcb_get_keyboard_mapping(connection, minimum, count),
        &protocol_error,
    );
    if (protocol_error) |xcb_error| {
        c.free(xcb_error);
        if (reply != null) c.free(reply);
        return error.KeyboardMappingFailed;
    }
    if (reply == null) return error.KeyboardMappingFailed;
    defer c.free(reply);

    const keysyms = c.xcb_get_keyboard_mapping_keysyms(reply);
    const per_keycode: usize = reply.*.keysyms_per_keycode;
    var keycode = minimum;
    while (keycode <= maximum) : (keycode += 1) {
        const offset = (@as(usize, keycode) - minimum) * per_keycode;
        for (0..per_keycode) |index| {
            if (keysyms[offset + index] == keysym) return keycode;
        }
        if (keycode == maximum) break;
    }
    return error.KeysymUnavailable;
}

fn sendKey(
    context: *XcbContext,
    window: c.xcb_window_t,
    keycode: c.xcb_keycode_t,
    response_type: u8,
    timestamp: c.xcb_timestamp_t,
) !void {
    var event = std.mem.zeroes(c.xcb_key_press_event_t);
    event.response_type = response_type;
    event.detail = keycode;
    event.time = timestamp;
    event.event = window;
    event.same_screen = 1;
    try checkRequest(context.connection, c.xcb_send_event_checked(
        context.connection,
        0,
        window,
        if (response_type == c.XCB_KEY_PRESS) c.XCB_EVENT_MASK_KEY_PRESS else c.XCB_EVENT_MASK_KEY_RELEASE,
        @ptrCast(&event),
    ));
    if (c.xcb_flush(context.connection) <= 0) return error.XcbFlushFailed;
}

fn internAtom(connection: *c.xcb_connection_t, name: []const u8) !c.xcb_atom_t {
    var protocol_error: ?*c.xcb_generic_error_t = null;
    const reply = c.xcb_intern_atom_reply(
        connection,
        c.xcb_intern_atom(connection, 0, @intCast(name.len), name.ptr),
        &protocol_error,
    );
    if (protocol_error) |xcb_error| {
        c.free(xcb_error);
        if (reply != null) c.free(reply);
        return error.XcbInternAtomFailed;
    }
    if (reply == null) return error.XcbInternAtomFailed;
    defer c.free(reply);
    return reply.*.atom;
}

fn checkRequest(connection: *c.xcb_connection_t, cookie: c.xcb_void_cookie_t) !void {
    const protocol_error = c.xcb_request_check(connection, cookie);
    if (protocol_error) |xcb_error| {
        defer c.free(xcb_error);
        return error.XcbRequestFailed;
    }
}

fn ensureChildRunning(child: *std.process.Child) !void {
    const process_id = child.id orelse return error.RuntimeExitedEarly;
    var status: c_int = 0;
    const result = c.waitpid(process_id, &status, c.WNOHANG);
    if (result == 0) return;
    if (result == process_id) {
        child.id = null;
        std.log.err("Runtime exited before verification completed: status={d}", .{status});
        return error.RuntimeExitedEarly;
    }
    return error.RuntimeWaitFailed;
}

fn waitForOwnedChild(child: *std.process.Child, timeout_ms: u32) !u8 {
    const process_id = child.id orelse return error.RuntimeAlreadyReaped;
    var elapsed: u32 = 0;
    while (elapsed < timeout_ms) : (elapsed += 10) {
        var status: c_int = 0;
        const result = c.waitpid(process_id, &status, c.WNOHANG);
        if (result == 0) {
            sleepMilliseconds(10);
            continue;
        }
        if (result != process_id) return error.RuntimeWaitFailed;
        child.id = null;
        if (!c.WIFEXITED(status)) return error.RuntimeTerminatedAbnormally;
        return @intCast(c.WEXITSTATUS(status));
    }
    return error.RuntimeCloseTimeout;
}

const OwnedChildTermination = struct {
    escalated: bool,
};

fn cleanupChildSlot(
    io: std.Io,
    child_name: []const u8,
    child_slot: *?std.process.Child,
) !void {
    const child = if (child_slot.*) |*owned_child| owned_child else return;
    const process_id = child.id;
    const termination = try terminateOwnedChildBounded(io, child, 500, 1_000);
    if (child.id != null) return error.OwnedChildStillAlive;
    if (termination.escalated and process_id != null) {
        std.log.warn("Owned {s} ignored TERM; escalated PID {d} to SIGKILL", .{ child_name, process_id.? });
    }
    child_slot.* = null;
}

fn terminateOwnedChildBounded(
    io: std.Io,
    child: *std.process.Child,
    term_grace_ms: u32,
    kill_grace_ms: u32,
) !OwnedChildTermination {
    const process_id = child.id orelse return .{ .escalated = false };
    std.posix.kill(process_id, .TERM) catch |signal_error| switch (signal_error) {
        error.ProcessNotFound => {},
        else => return error.OwnedChildTerminateFailed,
    };
    if (try waitForOwnedExit(io, child, term_grace_ms)) {
        return .{ .escalated = false };
    }

    const kill_process_id = child.id orelse return .{ .escalated = false };
    std.posix.kill(kill_process_id, .KILL) catch |signal_error| switch (signal_error) {
        error.ProcessNotFound => {},
        else => return error.OwnedChildKillFailed,
    };
    if (!try waitForOwnedExit(io, child, kill_grace_ms)) {
        return error.OwnedChildCleanupTimeout;
    }
    return .{ .escalated = true };
}

fn waitForOwnedExit(io: std.Io, child: *std.process.Child, timeout_ms: u32) !bool {
    var elapsed: u32 = 0;
    while (true) {
        if (try pollOwnedChild(io, child)) return true;
        if (elapsed >= timeout_ms) return false;
        const sleep_ms = @min(@as(u32, 10), timeout_ms - elapsed);
        if (sleep_ms == 0) return false;
        sleepMilliseconds(sleep_ms);
        elapsed += sleep_ms;
    }
}

fn pollOwnedChild(io: std.Io, child: *std.process.Child) !bool {
    const process_id = child.id orelse return true;
    while (true) {
        var status: c_int = 0;
        const result = c.waitpid(process_id, &status, c.WNOHANG);
        if (result == 0) return false;
        if (result == process_id) {
            child.id = null;
            closeOwnedChildStreams(io, child);
            return true;
        }
        if (std.c.errno(result) == .INTR) continue;
        return error.OwnedChildWaitFailed;
    }
}

fn closeOwnedChildStreams(io: std.Io, child: *std.process.Child) void {
    if (child.stdin) |stdin| stdin.close(io);
    if (child.stdout) |stdout| stdout.close(io);
    if (child.stderr) |stderr| stderr.close(io);
    child.stdin = null;
    child.stdout = null;
    child.stderr = null;
}

fn validateRuntimeLogs(
    stderr: []const u8,
    stdout: []const u8,
    asset_mode: AssetMode,
    audio_expectation: AudioExpectation,
) !void {
    const required = [_][]const u8{
        "Platform XCB window created (960x540)",
        "Vulkan GPU selected: llvmpipe",
        "Vulkan RHI initialized",
        "Runtime main loop entered",
        "Vulkan RHI shutdown complete",
        "Platform shutdown complete",
        "Kadath runtime shutdown complete",
    };
    for (required) |needle| {
        if (!containsEither(stderr, stdout, needle)) {
            std.log.err("Runtime log evidence missing: {s}", .{needle});
            return error.RuntimeLogEvidenceMissing;
        }
    }
    const scene_required: []const []const u8 = switch (asset_mode) {
        .generated_fixture => &.{
            "Loaded preview scene artifact: assets/scenes/preview.scene, artifact_version=3",
            "Runtime host initialized with Vulkan RHI scene objects=3",
        },
        .package_root => &.{
            "Loaded preview scene artifact: assets/scenes/preview.scene, artifact_version=6",
            "Runtime host initialized with Vulkan RHI scene objects=5",
        },
        .neutral_fixture => &.{
            "Loaded preview scene:",
            "Loaded behavior package:",
            "artifact_version=2",
            "Behavior on_start hooks applied to neutral scene objects=2",
            "Runtime host initialized with Vulkan RHI neutral scene objects=2",
            "Neutral scene reloaded explicitly: objects=2",
        },
    };
    for (scene_required) |needle| {
        if (!containsEither(stderr, stdout, needle)) {
            std.log.err("Runtime Scene evidence missing: {s}", .{needle});
            return error.RuntimeLogEvidenceMissing;
        }
    }
    if (asset_mode == .package_root) {
        const behavior_required = [_][]const u8{
            "Loaded behavior package: assets/scripts/preview.script, artifact_version=2",
            "Behavior on_start hooks applied",
        };
        for (behavior_required) |needle| {
            if (!containsEither(stderr, stdout, needle)) {
                std.log.err("Runtime Behavior evidence missing: {s}", .{needle});
                return error.RuntimeLogEvidenceMissing;
            }
        }
    }
    if (asset_mode == .neutral_fixture) {
        const gameplay_leaks = [_][]const u8{
            "Game session lost:",
            "Game session won:",
            "Audio cue played:",
            "mode=gameplay",
        };
        for (gameplay_leaks) |needle| {
            if (containsEither(stderr, stdout, needle)) return error.RuntimeNeutralGameplayLeak;
        }
    }
    const audio_required: []const []const u8 = switch (audio_expectation) {
        .not_applicable => &.{},
        .alsa => &.{
            "Audio initialized: backend=alsa device=null",
            "Audio cue played: lost",
            "Audio cue played: won",
            "Audio shutdown complete",
        },
        .silent => &.{
            "Linux audio unavailable; using silent fallback: AlsaDeviceOpenFailed",
            "Audio initialized: backend=silent",
            "Audio shutdown complete",
        },
    };
    for (audio_required) |needle| {
        if (!containsEither(stderr, stdout, needle)) return error.RuntimeAudioEvidenceMissing;
    }
    if (countSubstring(stderr, "Renderer2D texture upload complete") < 2 or
        countSubstring(stderr, "RHI texture created") < 2)
    {
        return error.DualTextureLogEvidenceMissing;
    }
    const forbidden = [_][]const u8{
        "VUID-",
        "Validation Error",
        "VulkanCallFailed",
        "vkCreateXcbSurfaceKHR failed",
        "panic:",
        "unexpected error:",
    };
    for (forbidden) |needle| {
        if (containsEither(stderr, stdout, needle)) {
            std.log.err("Runtime log contains forbidden diagnostic: {s}", .{needle});
            return error.RuntimeLogFailureDiagnostic;
        }
    }
    if (containsLinePrefixIgnoreCase(stderr, "error:") or
        containsLinePrefixIgnoreCase(stdout, "error:"))
    {
        return error.RuntimeLogFailureDiagnostic;
    }
    const rhi_shutdown = std.mem.indexOf(u8, stderr, "Vulkan RHI shutdown complete") orelse
        return error.RuntimeShutdownEvidenceMissing;
    const platform_shutdown = std.mem.indexOf(u8, stderr, "Platform shutdown complete") orelse
        return error.RuntimeShutdownEvidenceMissing;
    if (rhi_shutdown >= platform_shutdown) return error.RuntimeShutdownOrderMismatch;
}

fn containsLinePrefixIgnoreCase(text: []const u8, prefix: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(std.mem.trimStart(u8, line, " \t\r"), prefix)) return true;
    }
    return false;
}

fn countSubstring(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, offset, needle)) |index| {
        count += 1;
        offset = index + needle.len;
    }
    return count;
}

fn sleepMilliseconds(milliseconds: u32) void {
    _ = c.usleep(milliseconds * 1000);
}

test "owned Xvfb allocation assigns distinct live displays" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "xvfb-first.log", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "xvfb-second.log", .data = "" });

    var first_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const first_path_len = try tmp.dir.realPathFile(std.testing.io, "xvfb-first.log", &first_path_buffer);
    var second_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const second_path_len = try tmp.dir.realPathFile(std.testing.io, "xvfb-second.log", &second_path_buffer);

    var first = try startOwnedXvfb(
        std.testing.io,
        std.testing.allocator,
        first_path_buffer[0..first_path_len],
        5_000,
    );
    defer _ = terminateOwnedChildBounded(std.testing.io, &first.child, 100, 1_000) catch unreachable;

    var second = try startOwnedXvfb(
        std.testing.io,
        std.testing.allocator,
        second_path_buffer[0..second_path_len],
        5_000,
    );
    defer _ = terminateOwnedChildBounded(std.testing.io, &second.child, 100, 1_000) catch unreachable;

    try std.testing.expect(first.child.id != null);
    try std.testing.expect(second.child.id != null);
    try std.testing.expect(first.display_number != second.display_number);
}

test "owned child cleanup escalates ignored TERM and reaps within its deadline" {
    var child = try std.process.spawn(std.testing.io, .{
        .argv = &.{ "sh", "-c", "trap '' TERM; while :; do :; done" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer if (child.id) |process_id| {
        _ = c.kill(process_id, c.SIGKILL);
        var status: c_int = 0;
        _ = c.waitpid(process_id, &status, 0);
        child.id = null;
    };
    sleepMilliseconds(50);

    const started = std.Io.Clock.awake.now(std.testing.io);
    const termination = try terminateOwnedChildBounded(std.testing.io, &child, 50, 500);
    const elapsed = started.durationTo(std.Io.Clock.awake.now(std.testing.io)).toMilliseconds();

    try std.testing.expect(termination.escalated);
    try std.testing.expect(child.id == null);
    try std.testing.expect(elapsed < 1_000);
}

test "Vulkan preflight rejects validation diagnostics" {
    try std.testing.expectError(
        error.VulkanPreflightDiagnostic,
        validateVulkanPreflight(
            "VK_KHR_surface VK_KHR_xcb_surface llvmpipe DRIVER_ID_MESA_LLVMPIPE",
            "adding layers \"VK_LAYER_KHRONOS_validation\"\nValidation Error: [ VUID-review-probe ] layer reported a failure",
        ),
    );
}

test "Vulkan preflight rejects generic loader errors" {
    try std.testing.expectError(
        error.VulkanPreflightDiagnostic,
        validateVulkanPreflight(
            "VK_KHR_surface VK_KHR_xcb_surface llvmpipe DRIVER_ID_MESA_LLVMPIPE",
            "adding layers \"VK_LAYER_KHRONOS_validation\"\nERROR: [Loader Message] review probe failed",
        ),
    );
}

test "Runtime log validation rejects unexpected error records" {
    const runtime_log =
        "info: Platform XCB window created (960x540)\n" ++
        "info: Vulkan GPU selected: llvmpipe\n" ++
        "info: Vulkan RHI initialized\n" ++
        "info: Renderer2D texture upload complete\n" ++
        "info: Renderer2D texture upload complete\n" ++
        "info: RHI texture created\n" ++
        "info: RHI texture created\n" ++
        "info: Loaded preview scene artifact: assets/scenes/preview.scene, artifact_version=3\n" ++
        "info: Runtime host initialized with Vulkan RHI scene objects=3\n" ++
        "info: Runtime main loop entered\n" ++
        "error: Async texture set refresh failed: review probe\n" ++
        "info: Vulkan RHI shutdown complete\n" ++
        "info: Platform shutdown complete\n" ++
        "info: Kadath runtime shutdown complete\n";
    try std.testing.expectError(
        error.RuntimeLogFailureDiagnostic,
        validateRuntimeLogs(runtime_log, "", .generated_fixture, .not_applicable),
    );
}

test "Neutral product logs prove reload and reject Gameplay or Audio leakage" {
    const neutral_log =
        "info: Platform XCB window created (960x540)\n" ++
        "info: Vulkan GPU selected: llvmpipe\n" ++
        "info: Vulkan RHI initialized\n" ++
        "info: Renderer2D texture upload complete\n" ++
        "info: Renderer2D texture upload complete\n" ++
        "info: RHI texture created\n" ++
        "info: RHI texture created\n" ++
        "info: Loaded preview scene: /tmp/neutral/scene.json\n" ++
        "info: Loaded behavior package: /tmp/neutral/preview.script, artifact_version=2\n" ++
        "info: Behavior on_start hooks applied to neutral scene objects=2\n" ++
        "info: Runtime host initialized with Vulkan RHI neutral scene objects=2\n" ++
        "info: Runtime main loop entered\n" ++
        "info: Neutral scene reloaded explicitly: objects=2\n" ++
        "info: Vulkan RHI shutdown complete\n" ++
        "info: Platform shutdown complete\n" ++
        "info: Kadath runtime shutdown complete\n";
    try validateRuntimeLogs(neutral_log, "", .neutral_fixture, .not_applicable);

    const leaked_audio = neutral_log ++ "info: Audio cue played: won\n";
    try std.testing.expectError(
        error.RuntimeNeutralGameplayLeak,
        validateRuntimeLogs(leaked_audio, "", .neutral_fixture, .not_applicable),
    );
}
