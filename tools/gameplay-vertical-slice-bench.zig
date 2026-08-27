const std = @import("std");
const behavior_host = @import("../app/behavior_host.zig");
const gameplay_replay = @import("../app/gameplay_replay.zig");
const scene_api = @import("../app/scene.zig");
const scene_generation_api = @import("../app/scene_generation.zig");
const runtime_core = @import("runtime_core");
const c = @cImport({
    @cDefine("KADATH_RUNTIME_PHASE_QUALITY_EVIDENCE", "1");
    @cInclude("kadath_runtime_core.h");
});

const default_sample_count: usize = 64;
const max_input_bytes: usize = 4 * 1024 * 1024;

const Session = struct {
    allocator: std.mem.Allocator,
    generation: scene_generation_api.SceneGeneration,
    runtime: behavior_host.Runtime,

    fn init(
        allocator: std.mem.Allocator,
        artifact_bytes: []const u8,
        scene_source: []const u8,
    ) !Session {
        const scene = try scene_api.parse(allocator, scene_source);
        var generation = try scene_generation_api.SceneGeneration.prepare(&scene, .{ .width = 1024, .height = 720 });
        errdefer generation.deinit();
        const runtime = try behavior_host.initArtifact(allocator, artifact_bytes, &scene);
        return .{ .allocator = allocator, .generation = generation, .runtime = runtime };
    }

    fn deinit(self: *Session) void {
        self.runtime.deinit();
        self.generation.deinit();
    }

    fn start(self: *Session) !void {
        const startup = try self.runtime.onStart(&self.generation);
        try self.generation.applyTranslationDeltas(startup.slice());
        try self.runtime.publishStartupEvents(&self.generation, &startup);
    }

    fn restart(self: *Session) !void {
        var replacement = try scene_generation_api.SceneGeneration.prepareRestart(
            self.generation.scene,
            self.generation.extent,
            &self.generation,
        );
        var transferred = false;
        errdefer if (!transferred) replacement.deinit();
        var candidate = try self.runtime.cloneForRestart(self.allocator, self.generation.scene);
        errdefer if (!transferred) candidate.deinit();
        const startup = try candidate.onStart(&replacement);
        try replacement.applyTranslationDeltas(startup.slice());
        try candidate.preparePhaseState(&replacement);
        try candidate.commitPhaseState(&replacement);
        try replacement.commitPrepared(&self.generation);

        var previous_generation = self.generation;
        var previous_runtime = self.runtime;
        self.generation = replacement;
        self.runtime = candidate;
        transferred = true;
        previous_generation.deinit();
        previous_runtime.deinit();
        try self.runtime.publishStartupEvents(&self.generation, &startup);
    }

    fn reload(self: *Session, reload_source: []const u8) !void {
        const reload_scene = try scene_api.parse(self.allocator, reload_source);
        var replacement = try scene_generation_api.SceneGeneration.prepareSceneReload(
            &reload_scene,
            self.generation.extent,
            &self.generation,
        );
        var transferred = false;
        errdefer if (!transferred) replacement.deinit();
        var candidate = try self.runtime.cloneForSceneReload(self.allocator, &reload_scene);
        errdefer if (!transferred) candidate.deinit();
        const startup = try candidate.onStart(&replacement);
        try replacement.applyTranslationDeltas(startup.slice());
        try candidate.preparePhaseState(&replacement);
        try candidate.commitPhaseState(&replacement);
        try replacement.commitPrepared(&self.generation);

        var previous_generation = self.generation;
        var previous_runtime = self.runtime;
        self.generation = replacement;
        self.runtime = candidate;
        transferred = true;
        previous_generation.deinit();
        previous_runtime.deinit();
        try self.runtime.publishStartupEvents(&self.generation, &startup);
    }
};

const StepEvidence = struct {
    outcome: ?runtime_core.GameplayOutcome,
    snapshot: runtime_core.GameplaySnapshot,
};

fn recordSnapshot(session: *Session, recorder: *gameplay_replay.Recorder) !runtime_core.GameplaySnapshot {
    var render_items: [runtime_core.max_object_count]runtime_core.RenderSprite = undefined;
    const publication = try session.generation.extractSprites(&render_items);
    recorder.recordSnapshot(&publication.snapshot, publication.sprites);
    return publication.snapshot;
}

fn runFixed(
    session: *Session,
    requested: behavior_host.InputSnapshot,
    recorder: *gameplay_replay.Recorder,
) !StepEvidence {
    var outcome = std.mem.zeroes(runtime_core.GameplayOutcome);
    const begin = try session.generation.beginGameplayFixed(1.0 / 60.0, &outcome);
    recorder.recordStep(.begin, &begin);
    var published: ?runtime_core.GameplayOutcome = null;
    if (begin.outcome_count == 1) {
        recorder.recordOutcome(&outcome);
        published = outcome;
    }
    const routed = if (begin.accepts_input != 0) requested else behavior_host.InputSnapshot{};
    try session.runtime.runFixed(&session.generation, 1.0 / 60.0, routed);
    try session.runtime.settleFixedStructuralBeforeGameplay(&session.generation);
    const committed = try session.generation.commitGameplayFixed(begin.step_token, .{}, &outcome);
    recorder.recordStep(.commit, &committed);
    if (committed.outcome_count == 1) {
        recorder.recordOutcome(&outcome);
        published = outcome;
    }
    try session.runtime.finishFixedStep(&session.generation, routed);
    return .{ .outcome = published, .snapshot = try recordSnapshot(session, recorder) };
}

const WorkloadEvidence = struct {
    digest: gameplay_replay.Digest,
    initial_outcome: runtime_core.GameplayOutcome,
    restart_outcome: runtime_core.GameplayOutcome,
    reload_outcome: runtime_core.GameplayOutcome,
    initial_probe_x: f32,
    initial_epoch: u64,
    restart_epoch: u64,
    reload_epoch: u64,
    initial_player_entity: runtime_core.EntityId,
    restart_player_entity: runtime_core.EntityId,
    final_snapshot: runtime_core.GameplaySnapshot,
};

fn runWorkload(
    allocator: std.mem.Allocator,
    artifact_bytes: []const u8,
    initial_source: []const u8,
    reload_source: []const u8,
) !WorkloadEvidence {
    var session = try Session.init(allocator, artifact_bytes, initial_source);
    defer session.deinit();
    try session.start();

    var recorder = gameplay_replay.Recorder.init();
    const initial_epoch = try session.generation.worldEpoch();
    const initial_player_entity = session.generation.playerEntity();
    recorder.recordLifecycle(.initial, initial_epoch);
    _ = try recordSnapshot(&session, &recorder);
    _ = try runFixed(&session, .{}, &recorder);
    const initial_terminal = try runFixed(&session, .{}, &recorder);
    const initial_outcome = initial_terminal.outcome orelse return error.MissingInitialOutcome;
    const terminal_no_replay = try runFixed(&session, .{ .move_y = 1 }, &recorder);
    if (terminal_no_replay.outcome != null) return error.TerminalOutcomeReplayed;
    const probe_index = session.generation.objectIndex("phase-probe") orelse return error.MissingPhaseProbe;
    const initial_probe_x = (try session.generation.objectPosition(probe_index))[0];

    try session.restart();
    const restart_epoch = try session.generation.worldEpoch();
    const restart_player_entity = session.generation.playerEntity();
    recorder.recordLifecycle(.restart, restart_epoch);
    const restart_snapshot = try recordSnapshot(&session, &recorder);
    if (restart_snapshot.phase != @intFromEnum(runtime_core.GameplayPhase.playing)) return error.RestartDidNotResetPhase;
    _ = try runFixed(&session, .{}, &recorder);
    const restart_terminal = try runFixed(&session, .{}, &recorder);
    const restart_outcome = restart_terminal.outcome orelse return error.MissingRestartOutcome;

    try session.reload(reload_source);
    const reload_epoch = try session.generation.worldEpoch();
    recorder.recordLifecycle(.scene_reload, reload_epoch);
    _ = try recordSnapshot(&session, &recorder);
    _ = try runFixed(&session, .{}, &recorder);
    const reload_terminal = try runFixed(&session, .{}, &recorder);
    const reload_outcome = reload_terminal.outcome orelse return error.MissingReloadOutcome;

    return .{
        .digest = recorder.finish(),
        .initial_outcome = initial_outcome,
        .restart_outcome = restart_outcome,
        .reload_outcome = reload_outcome,
        .initial_probe_x = initial_probe_x,
        .initial_epoch = initial_epoch,
        .restart_epoch = restart_epoch,
        .reload_epoch = reload_epoch,
        .initial_player_entity = initial_player_entity,
        .restart_player_entity = restart_player_entity,
        .final_snapshot = reload_terminal.snapshot,
    };
}

fn validateEvidence(evidence: *const WorkloadEvidence) !void {
    if (evidence.initial_epoch != 1 or evidence.restart_epoch != 1 or evidence.reload_epoch != 2) {
        return error.InvalidLifecycleEpoch;
    }
    if (evidence.initial_player_entity == evidence.restart_player_entity) return error.RestartDidNotReplaceEntity;
    if (evidence.initial_probe_x != 212) return error.InvalidContactPhaseOrder;
    if (evidence.initial_outcome.sequence != 1 or evidence.initial_outcome.cause != @intFromEnum(runtime_core.GameplayCause.hazard)) {
        return error.InvalidInitialOutcome;
    }
    if (evidence.restart_outcome.sequence != 2 or evidence.restart_outcome.cause != @intFromEnum(runtime_core.GameplayCause.hazard)) {
        return error.InvalidRestartOutcome;
    }
    if (evidence.reload_outcome.sequence != 3 or evidence.reload_outcome.cause != @intFromEnum(runtime_core.GameplayCause.goal)) {
        return error.InvalidReloadOutcome;
    }
    if (evidence.final_snapshot.phase != @intFromEnum(runtime_core.GameplayPhase.won) or
        evidence.final_snapshot.world_epoch != evidence.reload_epoch)
    {
        return error.InvalidFinalSnapshot;
    }
}

fn percentile(sorted: []const u64, numerator: usize, denominator: usize) u64 {
    const rank = (sorted.len * numerator + denominator - 1) / denominator;
    return sorted[if (rank == 0) 0 else rank - 1];
}

fn parseSampleCount(args: []const [:0]const u8) !usize {
    if (args.len == 4) return default_sample_count;
    if (args.len != 6 or !std.mem.eql(u8, args[4], "--samples")) return error.InvalidArgument;
    const count = try std.fmt.parseInt(usize, args[5], 10);
    if (count == 0 or count > 4096) return error.InvalidArgument;
    return count;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 4) return error.InvalidArgument;
    const sample_count = try parseSampleCount(args);
    const artifact_bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], init.gpa, .limited(max_input_bytes));
    defer init.gpa.free(artifact_bytes);
    const initial_source = try std.Io.Dir.cwd().readFileAlloc(init.io, args[2], init.gpa, .limited(max_input_bytes));
    defer init.gpa.free(initial_source);
    const reload_source = try std.Io.Dir.cwd().readFileAlloc(init.io, args[3], init.gpa, .limited(max_input_bytes));
    defer init.gpa.free(reload_source);

    const warmup = try runWorkload(init.gpa, artifact_bytes, initial_source, reload_source);
    try validateEvidence(&warmup);
    const expected_digest = warmup.digest;
    const samples = try init.gpa.alloc(u64, sample_count);
    defer init.gpa.free(samples);
    var total_allocations: u64 = 0;
    var max_allocations: u64 = 0;
    for (samples) |*sample| {
        if (c.kadath_runtime_core_phase_quality_begin_allocation_count() != c.KADATH_OK) {
            return error.AllocationCounterUnavailable;
        }
        const started = std.Io.Clock.awake.now(init.io);
        const evidence = try runWorkload(init.gpa, artifact_bytes, initial_source, reload_source);
        const elapsed = started.durationTo(std.Io.Clock.awake.now(init.io)).toNanoseconds();
        if (elapsed <= 0) return error.ClockUnavailable;
        sample.* = @intCast(elapsed);
        var allocations: u64 = 0;
        if (c.kadath_runtime_core_phase_quality_end_allocation_count(&allocations) != c.KADATH_OK) {
            return error.AllocationCounterUnavailable;
        }
        try validateEvidence(&evidence);
        if (!std.mem.eql(u8, &expected_digest, &evidence.digest)) return error.ReplayDigestMismatch;
        total_allocations += allocations;
        max_allocations = @max(max_allocations, allocations);
        std.mem.doNotOptimizeAway(evidence);
    }
    std.sort.heap(u64, samples, {}, std.sort.asc(u64));
    const digest_hex = std.fmt.bytesToHex(expected_digest, .lower);
    var stdout_buffer: [2048]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "vertical_slice_samples={d} p50_ns={d} p95_ns={d} p99_ns={d} rust_allocations_total={d} rust_allocations_max={d} digest={s}\n",
        .{
            sample_count,
            percentile(samples, 50, 100),
            percentile(samples, 95, 100),
            percentile(samples, 99, 100),
            total_allocations,
            max_allocations,
            &digest_hex,
        },
    );
    try stdout.print(
        "vertical_slice_contract objects=5 fixed_steps=7 outcomes=3 initial_epoch=1 restart_epoch=1 reload_epoch=2 contact_order=212 status=PASS\n",
        .{},
    );
    try stdout.flush();
}
