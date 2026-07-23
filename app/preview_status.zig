const std = @import("std");

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

    pub fn runtimeReady(self: *PreviewStatus) void {
        const sequence = self.nextSequence() orelse return;
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
    status.runtimeReady();
    status.commandReceived(.reload_scene, 7);
    status.commandRejected(.reload_script, 8, error.UnsupportedScriptSchema);
    try std.testing.expectEqual(@as(u64, 0), status.sequence);
}
