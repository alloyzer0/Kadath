const builtin = @import("builtin");
const std = @import("std");
const c = @cImport({
    @cInclude("kadath_runtime_core.h");
});

const iterations = 10_000;
const active_objects = 128;
const max_events = 64;
const transition_pairs = max_events / 2;
const frozen_oracle_sha = "f114d755a927acd202872bb3468a1d9e7b87decb";
const near_position = [2]f32{ 0, 0 };
const far_position = [2]f32{ 1_000, 1_000 };

const Sprite = struct {
    position: [2]f32,
    size: [2]f32,
    color: [4]f32,
    texture_id: u32,
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

fn strictOverlap(first: Sprite, second: Sprite) bool {
    if (first.size[0] == 0 or first.size[1] == 0 or second.size[0] == 0 or second.size[1] == 0) return false;
    return first.position[0] < second.position[0] + second.size[0] and
        first.position[0] + first.size[0] > second.position[0] and
        first.position[1] < second.position[1] + second.size[1] and
        first.position[1] + first.size[1] > second.position[1];
}

fn appendDirected(
    events: *[max_events]c.kadath_runtime_phase_event_v1_t,
    count: *usize,
    target: usize,
    other: usize,
    name: []const u8,
) void {
    var event = std.mem.zeroes(c.kadath_runtime_phase_event_v1_t);
    event.struct_size = @sizeOf(c.kadath_runtime_phase_event_v1_t);
    event.domain = c.KADATH_RUNTIME_PHASE_DOMAIN_FIXED;
    event.has_other = 1;
    event.target.logical_generation = @intCast(target + 1);
    event.other.logical_generation = @intCast(other + 1);
    event.name_length = @intCast(name.len);
    @memcpy(event.name[0..name.len], name);
    events[count.*] = event;
    count.* += 1;
}

fn runOracleStep(
    objects: *[active_objects]Sprite,
    previous_contacts: *[active_objects - 1]bool,
    current_contacts: *[active_objects - 1]bool,
    events: *[max_events]c.kadath_runtime_phase_event_v1_t,
    phase_queue: *[max_events]c.kadath_runtime_phase_event_v1_t,
    drained: *[max_events]c.kadath_runtime_phase_event_v1_t,
    render: *[active_objects]c.kadath_runtime_render_item_v1_t,
    player_position: [2]f32,
) !void {
    objects[0].position = player_position;
    for (objects[1..], 0..) |object, index| {
        current_contacts[index] = strictOverlap(objects[0], object);
    }
    var event_count: usize = 0;
    for ([2][]const u8{ "contact_end", "contact_begin" }) |name| {
        for (previous_contacts, current_contacts, 0..) |previous, current, index| {
            const transitioned = if (std.mem.eql(u8, name, "contact_end")) previous and !current else !previous and current;
            if (!transitioned) continue;
            appendDirected(events, &event_count, 0, index + 1, name);
            appendDirected(events, &event_count, index + 1, 0, name);
        }
    }
    if (event_count != max_events) return error.InvalidMaximumContactOutput;
    @memcpy(phase_queue, events);
    @memcpy(drained, phase_queue);
    previous_contacts.* = current_contacts.*;

    for (objects, render, 0..) |object, *item, index| {
        item.* = std.mem.zeroes(c.kadath_runtime_render_item_v1_t);
        item.struct_size = @sizeOf(c.kadath_runtime_render_item_v1_t);
        item.entity_value = index + 1;
        item.position = object.position;
        item.size = object.size;
        item.final_color = object.color;
        item.texture_id = object.texture_id;
    }
    std.mem.doNotOptimizeAway(drained);
    std.mem.doNotOptimizeAway(render);
}

pub fn main() !void {
    if (builtin.os.tag != .linux) return error.UnsupportedPlatform;
    var objects: [active_objects]Sprite = undefined;
    objects[0] = .{ .position = near_position, .size = .{ 1, 1 }, .color = .{ 0.95, 0.20, 0.20, 1.0 }, .texture_id = 1 };
    for (objects[1 .. active_objects - 1], 1..) |*object, index| {
        object.* = .{
            .position = if (index <= transition_pairs) near_position else .{ @floatFromInt(index * 3), 100 },
            .size = .{ 1, 1 },
            .color = .{ 1, 0, 0, 1 },
            .texture_id = 1,
        };
    }
    objects[active_objects - 1] = .{
        .position = .{ 9_000, 9_000 },
        .size = .{ 1, 1 },
        .color = .{ 1, 1, 0, 1 },
        .texture_id = 1,
    };
    var previous_contacts = [_]bool{false} ** (active_objects - 1);
    @memset(previous_contacts[0..transition_pairs], true);
    var current_contacts = previous_contacts;
    var events: [max_events]c.kadath_runtime_phase_event_v1_t = undefined;
    var phase_queue: [max_events]c.kadath_runtime_phase_event_v1_t = undefined;
    var drained: [max_events]c.kadath_runtime_phase_event_v1_t = undefined;
    var render: [active_objects]c.kadath_runtime_render_item_v1_t = undefined;
    var samples: [iterations]u64 = undefined;

    for (&samples, 0..) |*sample, index| {
        const position = if (index % 2 == 0) far_position else near_position;
        const start = monotonicNs();
        try runOracleStep(
            &objects,
            &previous_contacts,
            &current_contacts,
            &events,
            &phase_queue,
            &drained,
            &render,
            position,
        );
        sample.* = monotonicNs() - start;
    }

    std.debug.print(
        "runtime_gameplay_oracle_bench oracle_sha={s} iterations={d} active_objects={d} transition_pairs={d} directed_events={d} render_items={d} p50_ns={d} p95_ns={d} allocations=0\n",
        .{
            frozen_oracle_sha,
            iterations,
            active_objects,
            transition_pairs,
            max_events,
            active_objects,
            percentile(&samples, 50, 100),
            percentile(&samples, 95, 100),
        },
    );
}
