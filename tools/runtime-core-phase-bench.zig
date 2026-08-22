const builtin = @import("builtin");
const std = @import("std");
const runtime_core = @import("runtime_core");

const iterations = 10_000;
const batch_size = runtime_core.max_phase_events;

fn monotonicNs() u64 {
    if (builtin.os.tag != .linux) return 0;
    var timestamp: std.os.linux.timespec = undefined;
    if (std.os.linux.clock_gettime(.MONOTONIC, &timestamp) != 0) return 0;
    return @as(u64, @intCast(timestamp.sec)) * std.time.ns_per_s + @as(u64, @intCast(timestamp.nsec));
}

fn eventFor(target: runtime_core.ObjectRef, domain: runtime_core.PhaseDomain, command: usize) runtime_core.PhaseEvent {
    var event = std.mem.zeroes(runtime_core.PhaseEvent);
    event.struct_size = @sizeOf(runtime_core.PhaseEvent);
    event.domain = @intFromEnum(domain);
    event.target = target;
    event.name_length = 2;
    event.name[0] = 'b';
    event.name[1] = @intCast('0' + (command % 10));
    return event;
}

fn percentile(samples: []u64, numerator: usize, denominator: usize) u64 {
    std.sort.heap(u64, samples, {}, std.sort.asc(u64));
    const rank = (samples.len * numerator + denominator - 1) / denominator;
    return samples[if (rank == 0) 0 else rank - 1];
}

fn initCore() !runtime_core.RuntimeCore {
    var core = try runtime_core.RuntimeCore.init();
    errdefer core.deinit();
    const sources = [_]runtime_core.SourceDesc{
        .{ .object_id = "player", .kind = 2, .sprite = .{ .position = .{ 10, 20 }, .size = .{ 8, 8 }, .color = .{ 1, 1, 1, 1 }, .texture_id = 1, .move_speed = 20 } },
    };
    _ = try core.prepare(.initial, .{ 0, 0 }, .{ 100, 100 }, &sources);
    try core.commitScene();
    return core;
}

fn runDomain(
    core: *runtime_core.RuntimeCore,
    target: runtime_core.ObjectRef,
    domain: runtime_core.PhaseDomain,
    samples: []u64,
) !void {
    var events: [batch_size]runtime_core.PhaseEvent = undefined;
    for (&events, 0..) |*event, index| event.* = eventFor(target, domain, index);
    var drained: [batch_size]runtime_core.PhaseEvent = undefined;

    for (samples, 0..) |*sample, index| {
        const phase_sequence = @as(u64, @intCast(index)) + 1;
        const start = monotonicNs();
        try core.beginPhase(domain, phase_sequence);
        _ = try core.submitPhaseEvents(events[0..]);
        const count = try core.drainPhaseEvents(domain, phase_sequence, drained[0..]);
        if (count != batch_size) return error.InvalidBenchmarkBatch;
        try core.endPhase(domain, phase_sequence);
        sample.* = monotonicNs() - start;
    }
}

pub fn main() !void {
    if (builtin.os.tag != .linux) return error.UnsupportedPlatform;
    var core = try initCore();
    defer core.deinit();
    const player = (try core.findById(.live, "player")).?.object_ref;

    var fixed_samples: [iterations]u64 = undefined;
    var frame_samples: [iterations]u64 = undefined;
    try runDomain(&core, player, .fixed, fixed_samples[0..]);
    try runDomain(&core, player, .frame, frame_samples[0..]);

    std.debug.print(
        "phase_commit_bench iterations={d} batch={d} fixed_p50_ns={d} fixed_p95_ns={d} frame_p50_ns={d} frame_p95_ns={d}\n",
        .{
            iterations,
            batch_size,
            percentile(fixed_samples[0..], 50, 100),
            percentile(fixed_samples[0..], 95, 100),
            percentile(frame_samples[0..], 50, 100),
            percentile(frame_samples[0..], 95, 100),
        },
    );
}
