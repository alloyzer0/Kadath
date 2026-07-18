const std = @import("std");

pub const Phase = enum {
    playing,
    won,
    lost,
};

pub const time_limit_seconds: f32 = 3.0;

pub const GameSession = struct {
    phase: Phase = .playing,
    time_remaining_seconds: f32 = time_limit_seconds,

    pub fn acceptsInput(self: *const GameSession) bool {
        return self.phase == .playing;
    }

    pub fn restart(self: *GameSession) bool {
        if (self.phase == .playing) return false;
        self.phase = .playing;
        self.time_remaining_seconds = time_limit_seconds;
        return true;
    }

    pub fn tickFixed(self: *GameSession, dt_seconds: f32) bool {
        if (self.phase != .playing) return false;
        if (!std.math.isFinite(dt_seconds) or dt_seconds < 0.0) return false;
        if (dt_seconds >= self.time_remaining_seconds) {
            self.time_remaining_seconds = 0.0;
            self.phase = .lost;
            return true;
        }
        self.time_remaining_seconds -= dt_seconds;
        return false;
    }

    pub fn observeHazard(
        self: *GameSession,
        player_position: [2]f32,
        player_size: [2]f32,
        hazard_position: [2]f32,
        hazard_size: [2]f32,
    ) bool {
        if (self.phase != .playing) return false;
        if (!finiteRect(player_position, player_size) or !finiteRect(hazard_position, hazard_size)) return false;

        if (overlaps(player_position, player_size, hazard_position, hazard_size)) {
            self.phase = .lost;
            return true;
        }
        return false;
    }

    pub fn observeGoal(
        self: *GameSession,
        player_position: [2]f32,
        player_size: [2]f32,
        goal_position: [2]f32,
        goal_size: [2]f32,
    ) bool {
        if (self.phase != .playing) return false;
        if (!finiteRect(player_position, player_size) or !finiteRect(goal_position, goal_size)) return false;

        // 目标判定只消费两个 World 快照，不再把窗口边界当成玩法数据。
        if (overlaps(player_position, player_size, goal_position, goal_size)) {
            self.phase = .won;
            return true;
        }
        return false;
    }
};

fn finiteRect(position: [2]f32, size: [2]f32) bool {
    return std.math.isFinite(position[0]) and std.math.isFinite(position[1]) and
        std.math.isFinite(size[0]) and std.math.isFinite(size[1]) and
        size[0] >= 0.0 and size[1] >= 0.0;
}

fn overlaps(
    first_position: [2]f32,
    first_size: [2]f32,
    second_position: [2]f32,
    second_size: [2]f32,
) bool {
    const first_right = first_position[0] + first_size[0];
    const first_bottom = first_position[1] + first_size[1];
    const second_right = second_position[0] + second_size[0];
    const second_bottom = second_position[1] + second_size[1];
    return first_position[0] < second_right and first_right > second_position[0] and
        first_position[1] < second_bottom and first_bottom > second_position[1];
}

test "session changes to won once on goal overlap" {
    var session = GameSession{};
    try std.testing.expect(session.acceptsInput());
    try std.testing.expect(!session.observeGoal(.{ 100.0, 0.0 }, .{ 20.0, 20.0 }, .{ 180.0, 0.0 }, .{ 20.0, 20.0 }));
    try std.testing.expect(session.phase == .playing);
    try std.testing.expect(session.observeGoal(.{ 170.0, 0.0 }, .{ 20.0, 20.0 }, .{ 180.0, 0.0 }, .{ 20.0, 20.0 }));
    try std.testing.expect(session.phase == .won);
    try std.testing.expect(!session.acceptsInput());
    try std.testing.expect(!session.observeGoal(.{ 0.0, 0.0 }, .{ 20.0, 20.0 }, .{ 180.0, 0.0 }, .{ 20.0, 20.0 }));
    try std.testing.expect(session.restart());
    try std.testing.expect(session.phase == .playing);
    try std.testing.expect(session.acceptsInput());
    try std.testing.expect(!session.restart());
    try std.testing.expect(session.time_remaining_seconds == time_limit_seconds);
}

test "session enters lost when hazard overlaps player" {
    var session = GameSession{};
    try std.testing.expect(!session.observeHazard(.{ 100.0, 0.0 }, .{ 20.0, 20.0 }, .{ 180.0, 0.0 }, .{ 20.0, 20.0 }));
    try std.testing.expect(session.phase == .playing);
    try std.testing.expect(session.observeHazard(.{ 170.0, 0.0 }, .{ 20.0, 20.0 }, .{ 180.0, 0.0 }, .{ 20.0, 20.0 }));
    try std.testing.expect(session.phase == .lost);
    try std.testing.expect(!session.acceptsInput());
    try std.testing.expect(session.restart());
    try std.testing.expect(session.phase == .playing);
}

test "session enters lost when fixed-step timer expires" {
    var session = GameSession{};
    try std.testing.expect(!session.tickFixed(2.5));
    try std.testing.expect(session.phase == .playing);
    try std.testing.expect(session.tickFixed(0.5));
    try std.testing.expect(session.phase == .lost);
    try std.testing.expect(!session.acceptsInput());
    try std.testing.expect(session.restart());
    try std.testing.expect(session.phase == .playing);
    try std.testing.expect(session.time_remaining_seconds == time_limit_seconds);
}

test "session ignores non-finite player snapshots" {
    var session = GameSession{};
    try std.testing.expect(!session.observeGoal(.{ std.math.nan(f32), 0.0 }, .{ 20.0, 20.0 }, .{ 180.0, 0.0 }, .{ 20.0, 20.0 }));
    try std.testing.expect(!session.tickFixed(std.math.nan(f32)));
    try std.testing.expect(session.phase == .playing);
}
