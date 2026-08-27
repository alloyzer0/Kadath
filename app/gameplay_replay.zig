const std = @import("std");
const runtime_core = @import("runtime_core");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Digest = [Sha256.digest_length]u8;
pub const StepStage = enum(u8) { begin = 1, commit = 2 };
pub const LifecycleStage = enum(u8) { initial = 1, restart = 2, scene_reload = 3 };

/// 只记录 Runtime Core 的公开输出；不得把 padding、reserved 或进程地址写入 transcript。
pub const Recorder = struct {
    hasher: Sha256,

    pub fn init() Recorder {
        var hasher = Sha256.init(.{});
        // 固定 domain tag，避免将来其他 SHA-256 用途与 replay transcript 混淆。
        hasher.update("kadath-gameplay-replay-v1\x00");
        return .{ .hasher = hasher };
    }

    pub fn recordSnapshot(
        self: *Recorder,
        snapshot: *const runtime_core.GameplaySnapshot,
        sprites: []const runtime_core.RenderSprite,
    ) void {
        self.writeByte(1);
        self.writeU32(snapshot.phase);
        self.writeU32(snapshot.cause);
        self.writeU32(snapshot.accepts_input);
        self.writeU64(snapshot.world_epoch);
        self.writeU64(snapshot.last_outcome_sequence);
        self.writeF32(snapshot.time_remaining_seconds);
        self.writeU64(@intCast(sprites.len));
        for (sprites) |*sprite| self.recordSprite(sprite);
    }

    pub fn recordStep(self: *Recorder, stage: StepStage, result: *const runtime_core.GameplayStepResult) void {
        self.writeByte(2);
        self.writeByte(@intFromEnum(stage));
        self.writeU32(result.phase);
        self.writeU32(result.cause);
        self.writeU32(result.accepts_input);
        self.writeF32(result.time_remaining_seconds);
        self.writeU64(result.step_token);
        self.writeU64(@intCast(result.submitted_contact_event_count));
        self.writeU64(@intCast(result.outcome_count));
    }

    pub fn recordOutcome(self: *Recorder, outcome: *const runtime_core.GameplayOutcome) void {
        self.writeByte(3);
        self.writeU32(outcome.phase);
        self.writeU32(outcome.cause);
        self.writeU32(outcome.has_other);
        self.writeU64(outcome.sequence);
        self.recordObjectRef(&outcome.player);
        if (outcome.has_other != 0) self.recordObjectRef(&outcome.other);
    }

    pub fn recordLifecycle(self: *Recorder, stage: LifecycleStage, world_epoch: u64) void {
        self.writeByte(4);
        self.writeByte(@intFromEnum(stage));
        self.writeU64(world_epoch);
    }

    pub fn finish(self: *Recorder) Digest {
        var digest: Digest = undefined;
        self.hasher.final(&digest);
        return digest;
    }

    fn recordSprite(self: *Recorder, sprite: *const runtime_core.RenderSprite) void {
        self.recordObjectRef(&sprite.object_ref);
        self.writeU64(sprite.entity_value);
        for (sprite.position) |value| self.writeF32(value);
        for (sprite.size) |value| self.writeF32(value);
        for (sprite.final_color) |value| self.writeF32(value);
        self.writeU32(sprite.texture_id);
    }

    fn recordObjectRef(self: *Recorder, object_ref: *const runtime_core.ObjectRef) void {
        self.writeU32(object_ref.kind);
        self.writeU64(object_ref.world_epoch);
        self.writeU64(object_ref.logical_generation);
        const id_length: usize = @min(object_ref.object_id_length, object_ref.object_id.len);
        self.writeU32(@intCast(id_length));
        self.hasher.update(object_ref.object_id[0..id_length]);
    }

    fn writeByte(self: *Recorder, value: u8) void {
        self.hasher.update(&.{value});
    }

    fn writeU32(self: *Recorder, value: u32) void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        self.hasher.update(&bytes);
    }

    fn writeU64(self: *Recorder, value: u64) void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        self.hasher.update(&bytes);
    }

    fn writeF32(self: *Recorder, value: f32) void {
        self.writeU32(@bitCast(value));
    }
};

test "replay digest includes public snapshot state and excludes reserved storage" {
    var snapshot = std.mem.zeroes(runtime_core.GameplaySnapshot);
    snapshot.struct_size = @sizeOf(runtime_core.GameplaySnapshot);
    snapshot.phase = @intFromEnum(runtime_core.GameplayPhase.playing);
    snapshot.cause = @intFromEnum(runtime_core.GameplayCause.none);
    snapshot.accepts_input = 1;
    snapshot.world_epoch = 7;
    snapshot.last_outcome_sequence = 3;
    snapshot.time_remaining_seconds = 2.5;
    snapshot.render_count = 1;

    var sprite = std.mem.zeroes(runtime_core.RenderSprite);
    sprite.struct_size = @sizeOf(runtime_core.RenderSprite);
    sprite.object_ref.struct_size = @sizeOf(runtime_core.ObjectRef);
    sprite.object_ref.kind = 1;
    sprite.object_ref.world_epoch = 7;
    sprite.object_ref.logical_generation = 4;
    const object_id = "player";
    sprite.object_ref.object_id_length = object_id.len;
    @memcpy(sprite.object_ref.object_id[0..object_id.len], object_id);
    sprite.entity_value = 11;
    sprite.position = .{ 10, 20 };
    sprite.size = .{ 2, 3 };
    sprite.final_color = .{ 1, 0.5, 0.25, 1 };
    sprite.texture_id = 9;

    var baseline = Recorder.init();
    baseline.recordSnapshot(&snapshot, &.{sprite});
    const baseline_digest = baseline.finish();

    var reserved_changed_snapshot = snapshot;
    reserved_changed_snapshot.reserved[0] = 0xfeed_beef;
    var reserved_changed_sprite = sprite;
    reserved_changed_sprite.reserved[0] = 0xdead_beef;
    var reserved_changed = Recorder.init();
    reserved_changed.recordSnapshot(&reserved_changed_snapshot, &.{reserved_changed_sprite});
    const reserved_changed_digest = reserved_changed.finish();
    try std.testing.expectEqualSlices(u8, &baseline_digest, &reserved_changed_digest);

    var position_changed_sprite = sprite;
    position_changed_sprite.position[0] = 11;
    var position_changed = Recorder.init();
    position_changed.recordSnapshot(&snapshot, &.{position_changed_sprite});
    const position_changed_digest = position_changed.finish();
    try std.testing.expect(!std.mem.eql(u8, &baseline_digest, &position_changed_digest));
    try std.testing.expect(!std.mem.allEqual(u8, &baseline_digest, 0));
}
