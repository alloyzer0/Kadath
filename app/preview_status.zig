const std = @import("std");

pub const InitialLoadedKind = enum {
    source_document,
    artifact,

    fn protocolName(self: InitialLoadedKind) []const u8 {
        return switch (self) {
            .source_document => "source_document",
            .artifact => "artifact",
        };
    }
};

pub const InitialLoadedFile = struct {
    kind: InitialLoadedKind,
    sha256: [32]u8,
    byte_count: u64,
};

pub const InitialLoadedTarget = union(enum) {
    built_in,
    file: InitialLoadedFile,
};

pub const InitialLoaded = struct {
    scene: InitialLoadedTarget,
    script: InitialLoadedTarget,
};

pub const Command = enum {
    reload_scene,
    reload_script,

    fn protocolName(self: Command) []const u8 {
        return switch (self) {
            .reload_scene => "reload_scene",
            .reload_script => "reload_script",
        };
    }
};

pub const PreviewStatus = struct {
    io: std.Io,
    enabled: bool,
    sequence: u64 = 0,

    pub fn init(io: std.Io, enabled: bool) PreviewStatus {
        return .{ .io = io, .enabled = enabled };
    }

    pub fn runtimeReady(self: *PreviewStatus, initial_loaded: ?InitialLoaded) void {
        const sequence = self.nextSequence() orelse return;
        if (initial_loaded) |loaded| {
            var scene_buffer: [160]u8 = undefined;
            var script_buffer: [160]u8 = undefined;
            const scene = formatInitialTarget(loaded.scene, &scene_buffer) catch {
                self.disable(error.StatusEventTooLarge);
                return;
            };
            const script = formatInitialTarget(loaded.script, &script_buffer) catch {
                self.disable(error.StatusEventTooLarge);
                return;
            };
            // Scene/Script 身份与 ready 使用一次 stdout 写入原子发布，避免观察到半套初始状态。
            self.emit(
                "{{\"schemaVersion\":1,\"sequence\":{d},\"event\":\"runtime_ready\",\"initialLoaded\":{{\"scene\":{s},\"script\":{s}}}}}\n",
                .{ sequence, scene, script },
            );
            return;
        }
        // 可选 data 保持旧 Runtime/测试路径兼容；新消费者不得在缺失时猜测 identity。
        self.emit(
            "{{\"schemaVersion\":1,\"sequence\":{d},\"event\":\"runtime_ready\"}}\n",
            .{sequence},
        );
    }

    pub fn runtimeStopping(self: *PreviewStatus, reason: []const u8) void {
        const sequence = self.nextSequence() orelse return;
        self.emit(
            "{{\"schemaVersion\":1,\"sequence\":{d},\"event\":\"runtime_stopping\",\"reason\":\"{s}\"}}\n",
            .{ sequence, reason },
        );
    }

    pub fn runtimeFailed(self: *PreviewStatus, phase: []const u8, err: anyerror) void {
        const sequence = self.nextSequence() orelse return;
        self.emit(
            "{{\"schemaVersion\":1,\"sequence\":{d},\"event\":\"runtime_failed\",\"phase\":\"{s}\",\"errorCode\":\"{s}\"}}\n",
            .{ sequence, phase, errorCode(err) },
        );
    }

    pub fn commandReceived(self: *PreviewStatus, command: Command, request_id: ?u64) void {
        const sequence = self.nextSequence() orelse return;
        if (request_id) |id| {
            self.emit(
                "{{\"schemaVersion\":1,\"sequence\":{d},\"event\":\"command_received\",\"requestId\":{d},\"command\":\"{s}\"}}\n",
                .{ sequence, id, command.protocolName() },
            );
        } else {
            self.emit(
                "{{\"schemaVersion\":1,\"sequence\":{d},\"event\":\"command_received\",\"command\":\"{s}\"}}\n",
                .{ sequence, command.protocolName() },
            );
        }
    }

    pub fn commandSucceeded(self: *PreviewStatus, command: Command, request_id: ?u64) void {
        const sequence = self.nextSequence() orelse return;
        if (request_id) |id| {
            self.emit(
                "{{\"schemaVersion\":1,\"sequence\":{d},\"event\":\"command_completed\",\"requestId\":{d},\"command\":\"{s}\",\"result\":\"succeeded\"}}\n",
                .{ sequence, id, command.protocolName() },
            );
        } else {
            self.emit(
                "{{\"schemaVersion\":1,\"sequence\":{d},\"event\":\"command_completed\",\"command\":\"{s}\",\"result\":\"succeeded\"}}\n",
                .{ sequence, command.protocolName() },
            );
        }
    }

    pub fn commandRejected(self: *PreviewStatus, command: Command, request_id: ?u64, err: anyerror) void {
        const sequence = self.nextSequence() orelse return;
        if (request_id) |id| {
            self.emit(
                "{{\"schemaVersion\":1,\"sequence\":{d},\"event\":\"command_completed\",\"requestId\":{d},\"command\":\"{s}\",\"result\":\"rejected\",\"errorCode\":\"{s}\"}}\n",
                .{ sequence, id, command.protocolName(), errorCode(err) },
            );
        } else {
            self.emit(
                "{{\"schemaVersion\":1,\"sequence\":{d},\"event\":\"command_completed\",\"command\":\"{s}\",\"result\":\"rejected\",\"errorCode\":\"{s}\"}}\n",
                .{ sequence, command.protocolName(), errorCode(err) },
            );
        }
    }

    fn nextSequence(self: *PreviewStatus) ?u64 {
        if (!self.enabled) return null;
        self.sequence += 1;
        return self.sequence;
    }

    fn emit(self: *PreviewStatus, comptime format: []const u8, args: anytype) void {
        var buffer: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&buffer, format, args) catch {
            self.disable(error.StatusEventTooLarge);
            return;
        };
        std.Io.File.writeStreamingAll(.stdout(), self.io, line) catch |err| {
            // 状态通道是可选观测面；写入失败不得反向终止 Runtime 主循环。
            self.disable(err);
        };
    }

    fn disable(self: *PreviewStatus, err: anyerror) void {
        if (!self.enabled) return;
        self.enabled = false;
        std.log.warn("Preview status channel disabled: {s}", .{@errorName(err)});
    }
};

fn formatInitialTarget(target: InitialLoadedTarget, buffer: *[160]u8) ![]const u8 {
    return switch (target) {
        .built_in => std.fmt.bufPrint(buffer, "{{\"kind\":\"built_in\"}}", .{}),
        .file => |identity| std.fmt.bufPrint(
            buffer,
            "{{\"kind\":\"{s}\",\"sha256\":\"{x}\",\"bytes\":{d}}}",
            .{ identity.kind.protocolName(), &identity.sha256, identity.byte_count },
        ),
    };
}

pub fn errorCode(err: anyerror) []const u8 {
    if (err == error.UnsupportedSceneSchema) return "UnsupportedSceneSchema";
    if (err == error.UnsupportedScriptSchema) return "UnsupportedScriptSchema";
    if (err == error.MissingScenePath) return "MissingScenePath";
    if (err == error.MissingScriptPath) return "MissingScriptPath";
    if (err == error.FileNotFound) return "FileNotFound";
    if (err == error.AccessDenied) return "AccessDenied";
    return "ReloadFailed";
}
test "protocol error codes stay stable" {
    try std.testing.expectEqualStrings("UnsupportedSceneSchema", errorCode(error.UnsupportedSceneSchema));
    try std.testing.expectEqualStrings("UnsupportedScriptSchema", errorCode(error.UnsupportedScriptSchema));
    try std.testing.expectEqualStrings("MissingScenePath", errorCode(error.MissingScenePath));
    try std.testing.expectEqualStrings("MissingScriptPath", errorCode(error.MissingScriptPath));
    try std.testing.expectEqualStrings("FileNotFound", errorCode(error.FileNotFound));
    try std.testing.expectEqualStrings("AccessDenied", errorCode(error.AccessDenied));
    try std.testing.expectEqualStrings("ReloadFailed", errorCode(error.UnexpectedReloadFailure));
}

test "command names stay stable" {
    try std.testing.expectEqualStrings("reload_scene", Command.reload_scene.protocolName());
    try std.testing.expectEqualStrings("reload_script", Command.reload_script.protocolName());
}

test "disabled status channel is inert" {
    var status = PreviewStatus.init(undefined, false);
    status.runtimeReady(null);
    status.commandReceived(.reload_scene, 7);
    status.commandRejected(.reload_script, 8, error.UnsupportedScriptSchema);
    try std.testing.expectEqual(@as(u64, 0), status.sequence);
}

test "initial loaded target uses lowercase fixed-width identity and built-in has no digest" {
    const identity = InitialLoadedFile{
        .kind = .artifact,
        .sha256 = .{
            0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea,
            0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23,
            0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c,
            0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad,
        },
        .byte_count = 3,
    };
    var file_buffer: [160]u8 = undefined;
    const file = try formatInitialTarget(.{ .file = identity }, &file_buffer);
    try std.testing.expectEqualStrings(
        "{\"kind\":\"artifact\",\"sha256\":\"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\",\"bytes\":3}",
        file,
    );
    var built_in_buffer: [160]u8 = undefined;
    try std.testing.expectEqualStrings("{\"kind\":\"built_in\"}", try formatInitialTarget(.built_in, &built_in_buffer));
}
