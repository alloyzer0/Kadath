const builtin = @import("builtin");
const std = @import("std");
const runtime_core = @import("runtime_core");

const iterations = 10_000;
const batch_size = runtime_core.max_phase_events;

extern fn kadath_runtime_core_phase_quality_begin_allocation_count() callconv(.c) void;
extern fn kadath_runtime_core_phase_quality_end_allocation_count() callconv(.c) u64;

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
    event.field_count = runtime_core.max_phase_event_fields;
    for (&event.fields, 0..) |*field, field_index| {
        field.struct_size = @sizeOf(@TypeOf(field.*));
        field.value_kind = runtime_core.phase_event_string;
        field.key_length = 2;
        field.key[0] = 'k';
        field.key[1] = @intCast('0' + (field_index % 10));
        field.value.string_value.length = field.value.string_value.bytes.len - 1;
        @memset(field.value.string_value.bytes[0..field.value.string_value.length], @intCast('a' + (field_index % 26)));
    }
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
) !u64 {
    var events: [batch_size]runtime_core.PhaseEvent = undefined;
    for (&events, 0..) |*event, index| event.* = eventFor(target, domain, index);
    var drained: [batch_size]runtime_core.PhaseEvent = undefined;
    var structural: [batch_size]runtime_core.PhaseStructural = undefined;
    var completions: [batch_size]runtime_core.PhaseCompletion = undefined;
    var taken: [batch_size]runtime_core.PhaseStructural = undefined;
    for (&structural, 0..) |*item, index| {
        item.* = std.mem.zeroes(runtime_core.PhaseStructural);
        item.struct_size = @sizeOf(runtime_core.PhaseStructural);
        item.operation = runtime_core.phase_operation_reserve_transient;
        item.domain = @intFromEnum(domain);
        item.prototype_key = @intCast(index + 1);
        item.origin = target;
        item.transient_sprite.struct_size = @sizeOf(@TypeOf(item.transient_sprite));
        item.transient_sprite.size = .{ 4, 4 };
        item.transient_sprite.color[3] = 1;
        item.transient_sprite.texture_id = 1;
        completions[index] = std.mem.zeroes(runtime_core.PhaseCompletion);
        completions[index].struct_size = @sizeOf(runtime_core.PhaseCompletion);
    }

    kadath_runtime_core_phase_quality_begin_allocation_count();
    for (samples, 0..) |*sample, index| {
        const phase_sequence = @as(u64, @intCast(index)) + 1;
        try core.beginPhase(domain, phase_sequence);
        const start = monotonicNs();
        _ = try core.submitPhaseEvents(events[0..]);
        _ = try core.submitPhaseStructural(structural[0..], completions[0..]);
        const count = try core.drainPhaseEvents(domain, phase_sequence, drained[0..]);
        if (count != batch_size) return error.InvalidBenchmarkBatch;
        const flush = try core.takePhaseStructural(domain, phase_sequence, taken[0..]);
        if (flush.count != batch_size) return error.InvalidBenchmarkBatch;
        try core.abortPhaseStructural(flush.info.flush_token);
        sample.* = monotonicNs() - start;
        try core.endPhase(domain, phase_sequence);
    }
    return kadath_runtime_core_phase_quality_end_allocation_count();
}

pub fn main() !void {
    if (builtin.os.tag != .linux) return error.UnsupportedPlatform;
    var core = try initCore();
    defer core.deinit();
    const player = (try core.findById(.live, "player")).?.object_ref;

    var fixed_samples: [iterations]u64 = undefined;
    var frame_samples: [iterations]u64 = undefined;
    const fixed_allocations = try runDomain(&core, player, .fixed, fixed_samples[0..]);
    const frame_allocations = try runDomain(&core, player, .frame, frame_samples[0..]);

    std.debug.print(
        "phase_commit_bench iterations={d} batch={d} fixed_p50_ns={d} fixed_p95_ns={d} frame_p50_ns={d} frame_p95_ns={d} fixed_allocations={d} frame_allocations={d}\n",
        .{
            iterations,
            batch_size,
            percentile(fixed_samples[0..], 50, 100),
            percentile(fixed_samples[0..], 95, 100),
            percentile(frame_samples[0..], 50, 100),
            percentile(frame_samples[0..], 95, 100),
            fixed_allocations,
            frame_allocations,
        },
    );
}
