const std = @import("std");

pub const Phase = enum {
    playing,
    won,
};

pub const GameSession = struct {
    phase: Phase = .playing,

    pub fn acceptsInput(self: *const GameSession) bool {
        return self.phase == .playing;
    }

    pub fn restart(self: *GameSession) bool {
        if (self.phase != .won) return false;
        self.phase = .playing;
        return true;
    }

    pub fn observePlayer(
        self: *GameSession,
        position: [2]f32,
        size: [2]f32,
        world_width: u32,
    ) bool {
        if (self.phase != .playing) return false;
        if (!std.math.isFinite(position[0]) or !std.math.isFinite(size[0])) return false;

        const right_edge = position[0] + size[0];
        const width: f32 = @floatFromInt(world_width);
        // World 已负责 clamp；epsilon 只吸收浮点累积误差，避免边界快照漏掉胜利。
        if (right_edge >= width - 0.5) {
            self.phase = .won;
            return true;
        }
        return false;
    }
};

test "session changes to won once at the right goal" {
    var session = GameSession{};
    try std.testing.expect(session.acceptsInput());
    try std.testing.expect(!session.observePlayer(.{ 100.0, 0.0 }, .{ 20.0, 20.0 }, 200));
    try std.testing.expect(session.phase == .playing);
    try std.testing.expect(session.observePlayer(.{ 180.0, 0.0 }, .{ 20.0, 20.0 }, 200));
    try std.testing.expect(session.phase == .won);
    try std.testing.expect(!session.acceptsInput());
    try std.testing.expect(!session.observePlayer(.{ 0.0, 0.0 }, .{ 20.0, 20.0 }, 200));
    try std.testing.expect(session.restart());
    try std.testing.expect(session.phase == .playing);
    try std.testing.expect(session.acceptsInput());
    try std.testing.expect(!session.restart());
}

test "session ignores non-finite player snapshots" {
    var session = GameSession{};
    try std.testing.expect(!session.observePlayer(.{ std.math.nan(f32), 0.0 }, .{ 20.0, 20.0 }, 200));
    try std.testing.expect(session.phase == .playing);
}
