const builtin = @import("builtin");
const std = @import("std");
const runtime_core = @import("runtime_core");
const c = @cImport({
    @cDefine("KADATH_RUNTIME_PHASE_QUALITY_EVIDENCE", "1");
    @cInclude("kadath_runtime_core.h");
});

const sample_count = 256;
const active_objects = runtime_core.max_object_count;
const phase_batch = runtime_core.max_phase_events;
const bounds_max = [2]f32{ 10_000, 10_000 };
const far_position = [2]f32{ 1_000, 1_000 };

const Fixture = struct {
    core: runtime_core.RuntimeCore,
    id_storage: [active_objects][32]u8,
    sources: [active_objects]runtime_core.SourceDesc,
    hazards: [active_objects - 2]runtime_core.HazardDesc,
    player: runtime_core.ObjectRef,
    goal: runtime_core.ObjectRef,
    events: [phase_batch]runtime_core.PhaseEvent,
    drained: [phase_batch]runtime_core.PhaseEvent,
    render_items: [active_objects]runtime_core.GameplayRenderItem,
};

fn monotonicNs() u64 {
    if (builtin.os.tag != .linux) return 0;
    var timestamp: std.os.linux.timespec = undefined;
    if (std.os.linux.clock_gettime(.MONOTONIC, &timestamp) != 0) return 0;
    return @as(u64, @intCast(timestamp.sec)) * std.time.ns_per_s + @as(u64, @intCast(timestamp.nsec));
}

fn percentile(samples: []u64, numerator: usize, denominator: usize) u64 {
    std.sort.heap(u64, samples, {}, std.sort.asc(u64));
    const rank = (samples.len * numerator + denominator - 1) / denominator;
    return samples[if (rank == 0) 0 else rank - 1];
}

fn sourceFor(index: usize, id_storage: *[active_objects][32]u8) !runtime_core.SourceDesc {
    const id = if (index == 0)
        "player"
    else if (index == active_objects - 1)
        "goal"
    else
        try std.fmt.bufPrint(&id_storage[index], "hazard-{d:0>3}", .{index});
    return .{
        .object_id = id,
        .kind = if (index == 0) 2 else if (index == active_objects - 1) 3 else 4,
        // 所有碰撞对象放到屏幕外，fixed-step 仍扫描完整对象集但不会意外进入终态。
        .sprite = .{
            .position = if (index == 0) far_position else if (index == active_objects - 1) .{ 9_000, 9_000 } else .{ @floatFromInt(index * 3), 100 },
            .size = .{ 1, 1 },
            .color = if (index == 0) .{ 0.95, 0.2, 0.2, 1 } else .{ 1, 0, 0, 1 },
            .texture_id = 1,
            .move_speed = if (index == 0) 20 else 0,
        },
    };
}

fn configureGameplay(fixture: *Fixture, target: runtime_core.Target) !void {
    var views: [active_objects]runtime_core.ObjectView = undefined;
    const visible = try fixture.core.snapshot(target, true, &views);
    const objectRefAtSource = struct {
        fn get(items: []const runtime_core.ObjectView, source_index: usize) ?runtime_core.ObjectRef {
            for (items) |view| {
                if (@as(usize, view.origin_key) == source_index) return view.object_ref;
            }
            return null;
        }
    }.get;
    fixture.player = objectRefAtSource(visible, 0) orelse return error.MissingPlayer;
    fixture.goal = objectRefAtSource(visible, active_objects - 1) orelse return error.MissingGoal;
    for (&fixture.hazards, 1..) |*hazard, source_index| {
        hazard.* = .{ .object_ref = objectRefAtSource(visible, source_index) orelse return error.MissingHazard };
    }
    try fixture.core.prepareGameplay(1_000_000.0, fixture.player, fixture.goal, fixture.hazards[0 .. active_objects - 2]);
    _ = try fixture.core.preparePhaseState(target, &.{});
    try fixture.core.commitPhaseState();
}

fn initFixture() !Fixture {
    var fixture = Fixture{
        .core = try runtime_core.RuntimeCore.init(),
        .id_storage = undefined,
        .sources = undefined,
        .hazards = undefined,
        .player = undefined,
        .goal = undefined,
        .events = undefined,
        .drained = undefined,
        .render_items = undefined,
    };
    errdefer fixture.core.deinit();
    for (&fixture.sources, 0..) |*source, index| source.* = try sourceFor(index, &fixture.id_storage);
    _ = try fixture.core.prepare(.initial, .{ 0, 0 }, bounds_max, fixture.sources[0..]);
    try configureGameplay(&fixture, .candidate);
    try fixture.core.commitScene();
    fixture.player = (try fixture.core.findById(.live, "player")).?.object_ref;
    fixture.goal = (try fixture.core.findById(.live, "goal")).?.object_ref;
    for (&fixture.events, 0..) |*event, index| {
        event.* = std.mem.zeroes(runtime_core.PhaseEvent);
        event.struct_size = @sizeOf(runtime_core.PhaseEvent);
        event.domain = @intFromEnum(runtime_core.PhaseDomain.fixed);
        event.target = fixture.player;
        event.name_length = 5;
        @memcpy(event.name[0..5], "bench");
        event.field_count = 0;
        _ = index;
    }
    for (&fixture.drained) |*event| {
        event.* = std.mem.zeroes(runtime_core.PhaseEvent);
        event.struct_size = @sizeOf(runtime_core.PhaseEvent);
    }
    return fixture;
}

fn runFixedStep(fixture: *Fixture, step: usize) !void {
    try fixture.core.applyPositions(.live, &[_]runtime_core.PositionPatch{.{ .object_ref = fixture.player, .position = far_position }});
    var outcome: runtime_core.GameplayOutcome = undefined;
    const begin = try fixture.core.beginGameplayFixed(1.0 / 60.0, &outcome);
    const phase_sequence = try fixture.core.beginPhaseOwned(.fixed);
    _ = try fixture.core.commitGameplayFixed(begin.step_token, .{ .move_x = if (step % 2 == 0) 1 else -1 }, &outcome);
    _ = try fixture.core.drainPhaseEvents(.fixed, phase_sequence, fixture.drained[0..]);
    try fixture.core.endPhase(.fixed, phase_sequence);
    _ = try fixture.core.gameplaySnapshot(fixture.render_items[0..]);
    std.mem.doNotOptimizeAway(outcome);
}

fn runPhaseDrain(fixture: *Fixture) !void {
    const phase_sequence = try fixture.core.beginPhaseOwned(.fixed);
    _ = try fixture.core.submitPhaseEvents(fixture.events[0..]);
    const count = try fixture.core.drainPhaseEvents(.fixed, phase_sequence, fixture.drained[0..]);
    if (count != phase_batch) return error.InvalidPhaseDrainCount;
    try fixture.core.endPhase(.fixed, phase_sequence);
}

fn runSnapshot(fixture: *Fixture) !void {
    const snapshot = try fixture.core.gameplaySnapshot(fixture.render_items[0..]);
    if (snapshot.render_count != active_objects) return error.InvalidSnapshotCount;
    std.mem.doNotOptimizeAway(snapshot);
}

fn runLifecycle(fixture: *Fixture, mode: runtime_core.PrepareMode) !void {
    _ = try fixture.core.prepare(mode, .{ 0, 0 }, bounds_max, fixture.sources[0..]);
    try configureGameplay(fixture, .candidate);
    try fixture.core.commitScene();
    fixture.player = (try fixture.core.findById(.live, "player")).?.object_ref;
    fixture.goal = (try fixture.core.findById(.live, "goal")).?.object_ref;
}

fn forceTerminal(fixture: *Fixture) !void {
    var outcome: runtime_core.GameplayOutcome = undefined;
    const begin = try fixture.core.beginGameplayFixed(1_000_001.0, &outcome);
    const phase_sequence = try fixture.core.beginPhaseOwned(.fixed);
    _ = try fixture.core.commitGameplayFixed(begin.step_token, .{}, &outcome);
    try fixture.core.endPhase(.fixed, phase_sequence);
}

fn measureFixed(fixture: *Fixture, samples: *[sample_count]u64) !u64 {
    if (c.kadath_runtime_core_phase_quality_begin_allocation_count() != c.KADATH_OK) return error.AllocationCounterUnavailable;
    for (samples, 0..) |*sample, index| {
        const start = monotonicNs();
        try runFixedStep(fixture, index);
        sample.* = monotonicNs() - start;
    }
    var allocations: u64 = 0;
    if (c.kadath_runtime_core_phase_quality_end_allocation_count(&allocations) != c.KADATH_OK) return error.AllocationCounterUnavailable;
    return allocations;
}

fn measurePhaseDrain(fixture: *Fixture, samples: *[sample_count]u64) !u64 {
    if (c.kadath_runtime_core_phase_quality_begin_allocation_count() != c.KADATH_OK) return error.AllocationCounterUnavailable;
    for (samples) |*sample| {
        const phase_sequence = try fixture.core.beginPhaseOwned(.fixed);
        _ = try fixture.core.submitPhaseEvents(fixture.events[0..]);
        const start = monotonicNs();
        const count = try fixture.core.drainPhaseEvents(.fixed, phase_sequence, fixture.drained[0..]);
        sample.* = monotonicNs() - start;
        if (count != phase_batch) return error.InvalidPhaseDrainCount;
        try fixture.core.endPhase(.fixed, phase_sequence);
    }
    var allocations: u64 = 0;
    if (c.kadath_runtime_core_phase_quality_end_allocation_count(&allocations) != c.KADATH_OK) return error.AllocationCounterUnavailable;
    return allocations;
}

fn measureSnapshot(fixture: *Fixture, samples: *[sample_count]u64) !u64 {
    if (c.kadath_runtime_core_phase_quality_begin_allocation_count() != c.KADATH_OK) return error.AllocationCounterUnavailable;
    for (samples) |*sample| {
        const start = monotonicNs();
        try runSnapshot(fixture);
        sample.* = monotonicNs() - start;
    }
    var allocations: u64 = 0;
    if (c.kadath_runtime_core_phase_quality_end_allocation_count(&allocations) != c.KADATH_OK) return error.AllocationCounterUnavailable;
    return allocations;
}

fn measureLifecycle(fixture: *Fixture, mode: runtime_core.PrepareMode, samples: *[sample_count]u64) !u64 {
    var max_allocations: u64 = 0;
    for (samples) |*sample| {
        // Restart 语义要求从 terminal state 开始；终态准备不计入 lifecycle 样本。
        try forceTerminal(fixture);
        if (c.kadath_runtime_core_phase_quality_begin_allocation_count() != c.KADATH_OK) return error.AllocationCounterUnavailable;
        const start = monotonicNs();
        try runLifecycle(fixture, mode);
        sample.* = monotonicNs() - start;
        var allocations: u64 = 0;
        if (c.kadath_runtime_core_phase_quality_end_allocation_count(&allocations) != c.KADATH_OK) return error.AllocationCounterUnavailable;
        if (sample.* == 0) return error.ClockUnavailable;
        // restart/reload 是冷路径，允许构造候选状态的受控分配；记录峰值供产品基线比较。
        if (allocations > max_allocations) max_allocations = allocations;
    }
    return max_allocations;
}

fn printMetric(name: []const u8, samples: *[sample_count]u64, allocations: u64) void {
    std.debug.print("representative_{s}_samples={d} p95_ns={d} p99_ns={d} allocations={d}\n", .{
        name,
        sample_count,
        percentile(samples[0..], 95, 100),
        percentile(samples[0..], 99, 100),
        allocations,
    });
}

pub fn main() !void {
    if (builtin.os.tag != .linux) return error.UnsupportedPlatform;
    var fixture = try initFixture();
    defer fixture.core.deinit();
    var fixed_samples: [sample_count]u64 = undefined;
    var phase_samples: [sample_count]u64 = undefined;
    var snapshot_samples: [sample_count]u64 = undefined;
    var restart_samples: [sample_count]u64 = undefined;
    var reload_samples: [sample_count]u64 = undefined;

    const fixed_allocations = try measureFixed(&fixture, &fixed_samples);
    const phase_allocations = try measurePhaseDrain(&fixture, &phase_samples);
    const snapshot_allocations = try measureSnapshot(&fixture, &snapshot_samples);
    const restart_allocations = try measureLifecycle(&fixture, .restart, &restart_samples);
    const reload_allocations = try measureLifecycle(&fixture, .scene_reload, &reload_samples);
    printMetric("fixed_step", &fixed_samples, fixed_allocations);
    printMetric("phase_drain", &phase_samples, phase_allocations);
    printMetric("snapshot", &snapshot_samples, snapshot_allocations);
    printMetric("restart", &restart_samples, restart_allocations);
    printMetric("scene_reload", &reload_samples, reload_allocations);
    std.debug.print(
        "runtime_core_representative_workload samples={d} active_objects={d} phase_events={d} fixed_allocations={d} phase_allocations={d} snapshot_allocations={d} restart_allocations={d} scene_reload_allocations={d}\n",
        .{ sample_count, active_objects, phase_batch, fixed_allocations, phase_allocations, snapshot_allocations, restart_allocations, reload_allocations },
    );
}
