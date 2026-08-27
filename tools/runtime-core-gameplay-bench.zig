const builtin = @import("builtin");
const std = @import("std");
const runtime_core = @import("runtime_core");
const c = @cImport({
    @cDefine("KADATH_RUNTIME_PHASE_QUALITY_EVIDENCE", "1");
    @cInclude("kadath_runtime_core.h");
});

const iterations = 10_000;
const transition_pairs = runtime_core.max_phase_events / 2;
const near_position = [2]f32{ 0, 0 };
const far_position = [2]f32{ 1_000, 1_000 };

const Fixture = struct {
    core: runtime_core.RuntimeCore,
    player: runtime_core.ObjectRef,
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

fn currentRssKb() !u64 {
    var usage: std.os.linux.rusage = undefined;
    if (std.os.linux.getrusage(std.os.linux.rusage.SELF, &usage) != 0) return error.RssUnavailable;
    // Linux ru_maxrss 的单位是 KB；这里采样同一进程的峰值，不把引擎总 RSS 当作绝对门槛。
    return @intCast(usage.maxrss);
}

fn parseSteadyBatches(args: []const [:0]const u8) !?usize {
    if (args.len == 1) return null;
    if (args.len != 3 or !std.mem.eql(u8, args[1], "--steady-batches")) return error.InvalidArgument;
    const batches = try std.fmt.parseInt(usize, args[2], 10);
    if (batches == 0) return error.InvalidArgument;
    return batches;
}

fn initMaxCore() !Fixture {
    var core = try runtime_core.RuntimeCore.init();
    errdefer core.deinit();
    var id_storage: [runtime_core.max_object_count][32]u8 = undefined;
    var sources: [runtime_core.max_object_count]runtime_core.SourceDesc = undefined;
    sources[0] = .{
        .object_id = "player",
        .kind = 2,
        .sprite = .{
            .position = far_position,
            .size = .{ 1, 1 },
            .color = .{ 1, 1, 1, 1 },
            .texture_id = 1,
        },
    };
    for (1..runtime_core.max_object_count - 1) |index| {
        const id = try std.fmt.bufPrint(&id_storage[index], "hazard-{d:0>3}", .{index});
        sources[index] = .{
            .object_id = id,
            .kind = 4,
            .sprite = .{
                .position = if (index <= transition_pairs) near_position else .{ @floatFromInt(index * 3), 100 },
                .size = .{ 1, 1 },
                .color = .{ 1, 0, 0, 1 },
                .texture_id = 1,
            },
        };
    }
    sources[runtime_core.max_object_count - 1] = .{
        .object_id = "goal",
        .kind = 3,
        .sprite = .{
            .position = .{ 9_000, 9_000 },
            .size = .{ 1, 1 },
            .color = .{ 1, 1, 0, 1 },
            .texture_id = 1,
        },
    };
    _ = try core.prepare(.initial, .{ 0, 0 }, .{ 10_000, 10_000 }, &sources);
    const player = (try core.findById(.candidate, "player")).?.object_ref;
    const goal = (try core.findById(.candidate, "goal")).?.object_ref;
    var hazards: [runtime_core.max_object_count - 2]runtime_core.HazardDesc = undefined;
    for (&hazards, 1..) |*hazard, source_index| {
        hazard.* = .{
            .object_ref = (try core.findById(.candidate, sources[source_index].object_id)).?.object_ref,
        };
    }
    try core.prepareGameplay(1_000_000.0, player, goal, &hazards);
    _ = try core.preparePhaseState(.candidate, &.{});
    try core.commitPhaseState();
    try core.commitScene();
    return .{ .core = core, .player = player };
}

fn initializeEventOutput(events: []runtime_core.PhaseEvent) void {
    for (events) |*event| {
        event.* = std.mem.zeroes(runtime_core.PhaseEvent);
        event.struct_size = @sizeOf(runtime_core.PhaseEvent);
    }
}

fn runStep(
    fixture: *Fixture,
    player_position: [2]f32,
    outcome: *runtime_core.GameplayOutcome,
    events: []runtime_core.PhaseEvent,
    render_items: []runtime_core.GameplayRenderItem,
) !void {
    try fixture.core.applyPositions(.live, &.{.{
        .object_ref = fixture.player,
        .position = player_position,
    }});
    const begin = try fixture.core.beginGameplayFixed(0.0, outcome);
    const phase_sequence = try fixture.core.beginPhaseOwned(.fixed);
    const committed = try fixture.core.commitGameplayFixed(begin.step_token, .{}, outcome);
    if (committed.submitted_contact_event_count != runtime_core.max_phase_events) {
        return error.InvalidMaximumContactOutput;
    }
    const drained = try fixture.core.drainPhaseEvents(.fixed, phase_sequence, events);
    if (drained != runtime_core.max_phase_events) return error.InvalidMaximumContactOutput;
    try fixture.core.endPhase(.fixed, phase_sequence);
    const snapshot = try fixture.core.gameplaySnapshot(render_items);
    if (snapshot.render_count != runtime_core.max_object_count) return error.InvalidRenderCount;
    std.mem.doNotOptimizeAway(events);
    std.mem.doNotOptimizeAway(render_items);
}

pub fn main(init: std.process.Init) !void {
    if (builtin.os.tag != .linux) return error.UnsupportedPlatform;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var fixture = try initMaxCore();
    defer fixture.core.deinit();
    var samples: [iterations]u64 = undefined;
    var outcome: runtime_core.GameplayOutcome = undefined;
    var events: [runtime_core.max_phase_events]runtime_core.PhaseEvent = undefined;
    var render_items: [runtime_core.max_object_count]runtime_core.GameplayRenderItem = undefined;
    initializeEventOutput(&events);

    // 预置32个接触，使每次测量都发布最大成功批次：32 pair * 2 directed event。
    try runStep(&fixture, near_position, &outcome, &events, &render_items);

    if (try parseSteadyBatches(args)) |batches| {
        const first_rss = try currentRssKb();
        var last_rss = first_rss;
        var peak_rss = first_rss;
        var total_allocations: u64 = 0;
        var total_iterations: usize = 0;
        for (0..batches) |batch| {
            if (c.kadath_runtime_core_phase_quality_begin_allocation_count() != c.KADATH_OK) {
                return error.AllocationCounterUnavailable;
            }
            for (0..iterations) |index| {
                const position = if ((batch * iterations + index) % 2 == 0) far_position else near_position;
                try runStep(&fixture, position, &outcome, &events, &render_items);
            }
            var allocations: u64 = 0;
            if (c.kadath_runtime_core_phase_quality_end_allocation_count(&allocations) != c.KADATH_OK) {
                return error.AllocationCounterUnavailable;
            }
            total_allocations += allocations;
            total_iterations += iterations;
            last_rss = try currentRssKb();
            if (last_rss > peak_rss) peak_rss = last_rss;
            std.debug.print("steady_sample={d} rss_kb={d} allocations={d}\n", .{ batch + 1, last_rss, allocations });
        }
        const growth = last_rss - first_rss;
        const peak_growth = peak_rss - first_rss;
        if (total_allocations != 0) return error.SteadyStateGameplayAllocated;
        std.debug.print(
            "runtime_core_gameplay_steady_state batches={d} iterations={d} first_rss_kb={d} last_rss_kb={d} peak_rss_kb={d} growth_kb={d} peak_growth_kb={d} allocations={d}\n",
            .{ batches, total_iterations, first_rss, last_rss, peak_rss, growth, peak_growth, total_allocations },
        );
        return;
    }

    if (c.kadath_runtime_core_phase_quality_begin_allocation_count() != c.KADATH_OK) {
        return error.AllocationCounterUnavailable;
    }
    for (&samples, 0..) |*sample, index| {
        const position = if (index % 2 == 0) far_position else near_position;
        const start = monotonicNs();
        try runStep(&fixture, position, &outcome, &events, &render_items);
        sample.* = monotonicNs() - start;
    }
    var allocations: u64 = 0;
    if (c.kadath_runtime_core_phase_quality_end_allocation_count(&allocations) != c.KADATH_OK) {
        return error.AllocationCounterUnavailable;
    }
    // Gameplay 热路径在 Core 创建完成后必须只使用固定容量存储。
    if (allocations != 0) return error.SteadyStateGameplayAllocated;
    std.debug.print(
        "runtime_core_gameplay_bench iterations={d} active_objects={d} transition_pairs={d} directed_events={d} render_items={d} p50_ns={d} p95_ns={d} allocations={d}\n",
        .{
            iterations,
            runtime_core.max_object_count,
            transition_pairs,
            runtime_core.max_phase_events,
            runtime_core.max_object_count,
            percentile(&samples, 50, 100),
            percentile(&samples, 95, 100),
            allocations,
        },
    );
}
