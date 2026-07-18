const std = @import("std");
const collision = @import("collision.zig");

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
        player: collision.Body,
        hazard: collision.Body,
    ) bool {
        if (self.phase != .playing) return false;

        if (collision.queryContact(player, hazard) != null) {
            self.phase = .lost;
            return true;
        }
        return false;
    }

    pub fn observeGoal(
        self: *GameSession,
        player: collision.Body,
        goal: collision.Body,
    ) bool {
        if (self.phase != .playing) return false;

        // 玩法状态只消费 Contact 结果，几何有效性与重叠语义统一留在 collision 模块。
        if (collision.queryContact(player, goal) != null) {
            self.phase = .won;
            return true;
        }
        return false;
    }
};

fn body(entity_id: collision.EntityId, position: [2]f32, size: [2]f32) collision.Body {
    return .{
        .entity_id = entity_id,
        .aabb = .{
            .position = position,
            .size = size,
        },
    };
}

test "session changes to won once on goal overlap" {
    var session = GameSession{};
    try std.testing.expect(session.acceptsInput());
    try std.testing.expect(!session.observeGoal(body(1, .{ 100.0, 0.0 }, .{ 20.0, 20.0 }), body(2, .{ 180.0, 0.0 }, .{ 20.0, 20.0 })));
    try std.testing.expect(session.phase == .playing);
    try std.testing.expect(session.observeGoal(body(1, .{ 170.0, 0.0 }, .{ 20.0, 20.0 }), body(2, .{ 180.0, 0.0 }, .{ 20.0, 20.0 })));
    try std.testing.expect(session.phase == .won);
    try std.testing.expect(!session.acceptsInput());
    try std.testing.expect(!session.observeGoal(body(1, .{ 0.0, 0.0 }, .{ 20.0, 20.0 }), body(2, .{ 180.0, 0.0 }, .{ 20.0, 20.0 })));
    try std.testing.expect(session.restart());
    try std.testing.expect(session.phase == .playing);
    try std.testing.expect(session.acceptsInput());
    try std.testing.expect(!session.restart());
    try std.testing.expect(session.time_remaining_seconds == time_limit_seconds);
}

test "session enters lost when hazard overlaps player" {
    var session = GameSession{};
    try std.testing.expect(!session.observeHazard(body(1, .{ 100.0, 0.0 }, .{ 20.0, 20.0 }), body(3, .{ 180.0, 0.0 }, .{ 20.0, 20.0 })));
    try std.testing.expect(session.phase == .playing);
    try std.testing.expect(session.observeHazard(body(1, .{ 170.0, 0.0 }, .{ 20.0, 20.0 }), body(3, .{ 180.0, 0.0 }, .{ 20.0, 20.0 })));
    try std.testing.expect(session.phase == .lost);
    try std.testing.expect(!session.acceptsInput());
    try std.testing.expect(session.restart());
    try std.testing.expect(session.phase == .playing);
}

test "session prioritizes hazard loss when goal overlaps in the same snapshot" {
    var session = GameSession{};
    const player = body(1, .{ 170.0, 0.0 }, .{ 20.0, 20.0 });
    const hazard = body(3, .{ 180.0, 0.0 }, .{ 20.0, 20.0 });
    const goal = body(2, .{ 180.0, 0.0 }, .{ 20.0, 20.0 });

    // 关键规则：Host 先提交 Hazard 接触；Lost 终态必须拒绝同帧后续 Goal 结果。
    try std.testing.expect(session.observeHazard(player, hazard));
    try std.testing.expect(session.phase == .lost);
    try std.testing.expect(!session.observeGoal(player, goal));
    try std.testing.expect(session.phase == .lost);
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
    try std.testing.expect(!session.observeGoal(body(1, .{ std.math.nan(f32), 0.0 }, .{ 20.0, 20.0 }), body(2, .{ 180.0, 0.0 }, .{ 20.0, 20.0 })));
    try std.testing.expect(!session.tickFixed(std.math.nan(f32)));
    try std.testing.expect(session.phase == .playing);
}
