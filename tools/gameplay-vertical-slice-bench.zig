const std = @import("std");
const behavior_host = @import("../app/behavior_host.zig");
const gameplay_replay = @import("../app/gameplay_replay.zig");
const player_movement_ownership = @import("../app/player_movement_ownership.zig");
const scene_api = @import("../app/scene.zig");
const scene_generation_api = @import("../app/scene_generation.zig");
const runtime_core = @import("runtime_core");
const c = @cImport({
    @cDefine("KADATH_RUNTIME_PHASE_QUALITY_EVIDENCE", "1");
    @cInclude("kadath_runtime_core.h");
});

const default_sample_count: usize = 64;
const steady_fixed_sample_count: usize = 256;
// 优化后 256/256 样本均为 0；门槛绑定该确定性基线，不保留历史宽限值。
const steady_fixed_max_allocations: u64 = 0;
const max_input_bytes: usize = 4 * 1024 * 1024;
const quality_call_count: usize = c.KADATH_RUNTIME_QUALITY_CALL_COUNT;
const quality_call_names = [_][]const u8{
    "unknown",
    "object_create",
    "object_destroy",
    "object_prepare_scene",
    "object_commit_scene",
    "object_abort_scene",
    "object_query",
    "object_mutate",
    "phase_prepare_state",
    "phase_commit_state",
    "phase_abort_state",
    "phase_begin",
    "phase_submit_events",
    "phase_drain_events",
    "phase_submit_structural",
    "phase_take_structural",
    "phase_begin_activation",
    "phase_submit_activation",
    "phase_commit_activation",
    "phase_abort_activation",
    "phase_complete_structural",
    "phase_abort_structural",
    "phase_end",
    "gameplay_prepare_state",
    "gameplay_begin_fixed",
    "gameplay_commit_fixed",
    "gameplay_abort_fixed",
    "gameplay_publish_snapshot",
};
const query_tag_names = [_][]const u8{
    "unknown",
    "state_info",
    "find_by_id",
    "resolve_exact_ref",
    "visible_objects",
    "active_objects",
    "find_by_entity",
};

comptime {
    if (quality_call_names.len != quality_call_count) @compileError("Runtime Core quality call table drifted");
}

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
    // VS02 fixture 显式启用 Gameplay；通过 union accessor 拒绝把 Neutral publication 当作 Gameplay。
    const snapshot = try publication.gameplaySnapshot();
    recorder.recordSnapshot(&snapshot, publication.sprites);
    return snapshot;
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
    const routed = player_movement_ownership.routeGameplay(
        session.generation.scene,
        .{ .move_x = @intCast(requested.move_x), .move_y = @intCast(requested.move_y) },
        begin.accepts_input != 0,
    );
    const behavior_input = behavior_host.InputSnapshot{
        .move_x = routed.behaviors.move_x,
        .move_y = routed.behaviors.move_y,
    };
    try session.runtime.runFixed(&session.generation, 1.0 / 60.0, behavior_input);
    try session.runtime.settleFixedStructuralBeforeGameplay(&session.generation);
    const committed = try session.generation.commitGameplayFixed(begin.step_token, .{
        .move_x = routed.world.move_x,
        .move_y = routed.world.move_y,
    }, &outcome);
    recorder.recordStep(.commit, &committed);
    if (committed.outcome_count == 1) {
        recorder.recordOutcome(&outcome);
        published = outcome;
    }
    try session.runtime.finishFixedStep(&session.generation, behavior_input);
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

const SteadyFixedAllocationEvidence = struct {
    total: u64,
    max: u64,
    call_totals: [quality_call_count]u64,
    call_maxes: [quality_call_count]u64,
    object_query_invocations_total: u64,
    object_query_invocations_max: u64,
    query_tag_totals: [query_tag_names.len]u64,
    query_tag_maxes: [query_tag_names.len]u64,
};

fn measureSteadyFixedAllocations(
    allocator: std.mem.Allocator,
    artifact_bytes: []const u8,
    initial_source: []const u8,
) !SteadyFixedAllocationEvidence {
    var total: u64 = 0;
    var max: u64 = 0;
    var call_totals = [_]u64{0} ** quality_call_count;
    var call_maxes = [_]u64{0} ** quality_call_count;
    var object_query_invocations_total: u64 = 0;
    var object_query_invocations_max: u64 = 0;
    var query_tag_totals = [_]u64{0} ** query_tag_names.len;
    var query_tag_maxes = [_]u64{0} ** query_tag_names.len;
    for (0..steady_fixed_sample_count) |_| {
        var session = try Session.init(allocator, artifact_bytes, initial_source);
        defer session.deinit();
        try session.start();
        var recorder = gameplay_replay.Recorder.init();

        // Session 构造与 on_start 属于冷路径；计数窗口只覆盖同一场景的活跃 fixed-step。
        if (c.kadath_runtime_core_phase_quality_begin_allocation_count() != c.KADATH_OK) {
            return error.AllocationCounterUnavailable;
        }
        const step = runFixed(&session, .{}, &recorder) catch |err| {
            var ignored: u64 = 0;
            _ = c.kadath_runtime_core_phase_quality_end_allocation_count(&ignored);
            return err;
        };
        var allocations: u64 = 0;
        if (c.kadath_runtime_core_phase_quality_end_allocation_count(&allocations) != c.KADATH_OK) {
            return error.AllocationCounterUnavailable;
        }
        var attributed: u64 = 0;
        for (0..quality_call_count) |call_id| {
            var call_allocations: u64 = 0;
            if (c.kadath_runtime_core_phase_quality_call_allocation_count(@intCast(call_id), &call_allocations) != c.KADATH_OK) {
                return error.AllocationCounterUnavailable;
            }
            attributed += call_allocations;
            call_totals[call_id] += call_allocations;
            call_maxes[call_id] = @max(call_maxes[call_id], call_allocations);
        }
        var object_query_invocations: u64 = 0;
        if (c.kadath_runtime_core_phase_quality_call_invocation_count(
            c.KADATH_RUNTIME_QUALITY_CALL_OBJECT_QUERY,
            &object_query_invocations,
        ) != c.KADATH_OK) return error.AllocationCounterUnavailable;
        object_query_invocations_total += object_query_invocations;
        object_query_invocations_max = @max(object_query_invocations_max, object_query_invocations);
        for (0..query_tag_names.len) |query_tag| {
            var query_tag_count: u64 = 0;
            if (c.kadath_runtime_core_phase_quality_query_tag_count(@intCast(query_tag), &query_tag_count) != c.KADATH_OK) {
                return error.AllocationCounterUnavailable;
            }
            query_tag_totals[query_tag] += query_tag_count;
            query_tag_maxes[query_tag] = @max(query_tag_maxes[query_tag], query_tag_count);
        }
        // 所有 Rust 分配必须落到某个公开调用；否则该归因不能作为热点证据。
        if (attributed != allocations) return error.AllocationAttributionMismatch;
        if (step.outcome != null or step.snapshot.phase != @intFromEnum(runtime_core.GameplayPhase.playing)) {
            return error.SteadyFixedStepLeftPlayingPhase;
        }
        total += allocations;
        max = @max(max, allocations);
    }
    return .{
        .total = total,
        .max = max,
        .call_totals = call_totals,
        .call_maxes = call_maxes,
        .object_query_invocations_total = object_query_invocations_total,
        .object_query_invocations_max = object_query_invocations_max,
        .query_tag_totals = query_tag_totals,
        .query_tag_maxes = query_tag_maxes,
    };
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
    const steady_fixed_allocations = try measureSteadyFixedAllocations(
        init.gpa,
        artifact_bytes,
        initial_source,
    );
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
        "vertical_slice_samples={d} p50_ns={d} p95_ns={d} p99_ns={d} rust_allocations_total={d} rust_allocations_max={d} rust_steady_fixed_samples={d} rust_steady_fixed_allocations_total={d} rust_steady_fixed_allocations_max={d} digest={s}\n",
        .{
            sample_count,
            percentile(samples, 50, 100),
            percentile(samples, 95, 100),
            percentile(samples, 99, 100),
            total_allocations,
            max_allocations,
            steady_fixed_sample_count,
            steady_fixed_allocations.total,
            steady_fixed_allocations.max,
            &digest_hex,
        },
    );
    try stdout.print(
        "vertical_slice_contract objects=5 fixed_steps=7 outcomes=3 steady_fixed_samples=256 steady_fixed_max_allocations={d} initial_epoch=1 restart_epoch=1 reload_epoch=2 contact_order=212 status=PASS\n",
        .{steady_fixed_max_allocations},
    );
    try stdout.writeAll("rust_steady_fixed_allocation_calls");
    for (quality_call_names, 0..) |name, call_id| {
        const call_total = steady_fixed_allocations.call_totals[call_id];
        if (call_total == 0) continue;
        try stdout.print(" {s}_total={d} {s}_max={d}", .{
            name,
            call_total,
            name,
            steady_fixed_allocations.call_maxes[call_id],
        });
    }
    try stdout.print(" object_query_invocations_total={d} object_query_invocations_max={d}", .{
        steady_fixed_allocations.object_query_invocations_total,
        steady_fixed_allocations.object_query_invocations_max,
    });
    for (query_tag_names, 0..) |name, query_tag| {
        const query_tag_total = steady_fixed_allocations.query_tag_totals[query_tag];
        if (query_tag_total == 0) continue;
        try stdout.print(" query_{s}_total={d} query_{s}_max={d}", .{
            name,
            query_tag_total,
            name,
            steady_fixed_allocations.query_tag_maxes[query_tag],
        });
    }
    try stdout.writeAll(" status=PASS\n");
    try stdout.flush();
}
