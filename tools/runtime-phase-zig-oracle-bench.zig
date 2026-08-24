const builtin = @import("builtin");
const std = @import("std");
const behavior_runtime = @import("behavior_runtime");
const scene_api = @import("scene.zig");
const runtime_object_registry = @import("runtime_object_registry.zig");

const iterations = 10_000;
const batch_size = 64;

// BEGIN FROZEN bfc5504 app/behavior_host.zig CONSTANTS
const max_events_per_domain: usize = 64;
const max_event_drain_generation: u8 = 8;
const max_structural_requests_per_domain: usize = 64;
const max_structural_generation: u8 = 8;
// END FROZEN bfc5504 app/behavior_host.zig CONSTANTS

// BEGIN FROZEN bfc5504 app/behavior_host.zig EVENT AUTHORITY
const StoredEventValue = struct {
    kind: u32 = 0,
    boolean_value: i32 = 0,
    number_value: f64 = 0,
    string_storage: [128]u8 = [_]u8{0} ** 128,
    string_bytes: u8 = 0,
    object_value: behavior_runtime.NativeObjectHandle = std.mem.zeroes(behavior_runtime.NativeObjectHandle),
};

const StoredEventField = struct {
    key_storage: [32]u8 = [_]u8{0} ** 32,
    key_bytes: u8 = 0,
    value: StoredEventValue = .{},
};

const QueuedEvent = struct {
    target: behavior_runtime.NativeObjectHandle = std.mem.zeroes(behavior_runtime.NativeObjectHandle),
    has_sender: bool = false,
    sender: behavior_runtime.NativeObjectHandle = std.mem.zeroes(behavior_runtime.NativeObjectHandle),
    has_other: bool = false,
    other: behavior_runtime.NativeObjectHandle = std.mem.zeroes(behavior_runtime.NativeObjectHandle),
    name_storage: [64]u8 = [_]u8{0} ** 64,
    name_bytes: u8 = 0,
    fields: [8]StoredEventField = [_]StoredEventField{.{}} ** 8,
    field_count: u8 = 0,
    generation: u8 = 0,
};

const EventQueue = struct {
    events: [max_events_per_domain]QueuedEvent = [_]QueuedEvent{.{}} ** max_events_per_domain,
    count: usize = 0,

    fn clear(self: *EventQueue) void {
        self.count = 0;
    }

    fn appendPosted(self: *EventQueue, source: *const behavior_runtime.NativePostedEvent, generation: u8) bool {
        if (self.count >= self.events.len or source.name == null or source.name_length == 0 or source.name_length > 63 or
            source.field_count > 8 or (source.field_count > 0 and source.fields == null)) return false;
        var event = QueuedEvent{
            .target = source.target,
            .has_sender = true,
            .sender = source.sender,
            .name_bytes = @intCast(source.name_length),
            .field_count = @intCast(source.field_count),
            .generation = generation,
        };
        @memcpy(event.name_storage[0..source.name_length], source.name[0..source.name_length]);
        if (source.field_count > 0) {
            const source_fields = source.fields orelse return false;
            for (source_fields[0..source.field_count], 0..) |field, index| {
                if (field.key == null or field.key_length == 0 or field.key_length > 31) return false;
                if (!validEventValue(&field.value)) return false;
                event.fields[index].key_bytes = @intCast(field.key_length);
                @memcpy(event.fields[index].key_storage[0..field.key_length], field.key[0..field.key_length]);
                event.fields[index].value.kind = field.value.kind;
                event.fields[index].value.boolean_value = field.value.boolean_value;
                event.fields[index].value.number_value = field.value.number_value;
                event.fields[index].value.object_value = field.value.object_value;
                if (field.value.kind == 3) {
                    event.fields[index].value.string_bytes = @intCast(field.value.string_value_length);
                    @memcpy(
                        event.fields[index].value.string_storage[0..field.value.string_value_length],
                        field.value.string_value[0..field.value.string_value_length],
                    );
                }
            }
        }
        self.events[self.count] = event;
        self.count += 1;
        return true;
    }
};
// END FROZEN bfc5504 app/behavior_host.zig EVENT AUTHORITY

// BEGIN FROZEN bfc5504 app/behavior_host.zig STRUCTURAL AUTHORITY
const StructuralOperation = enum { spawn, destroy };

const StructuralOrigin = struct {
    object_id: scene_api.ObjectId = .{},
    script_id: u32 = 0,

    fn isValid(self: StructuralOrigin) bool {
        return self.object_id.byte_count != 0 and self.script_id != 0;
    }
};

const StructuralRequest = struct {
    operation: StructuralOperation = .spawn,
    handle: runtime_object_registry.Handle = .{ .slot = 0, .logical_generation = 0 },
    generation: u8 = 0,
    sequence: u64 = 0,
    origin: StructuralOrigin = .{},
};

const StructuralQueue = struct {
    requests: [max_structural_requests_per_domain]StructuralRequest = [_]StructuralRequest{.{}} ** max_structural_requests_per_domain,
    count: usize = 0,
    next_sequence: u64 = 1,
    current_origin: StructuralOrigin = .{},

    fn canAppend(self: *const StructuralQueue, generation: u8) bool {
        return self.canAppendCount(1) and
            generation <= max_structural_generation and
            self.next_sequence != std.math.maxInt(u64);
    }

    fn canAppendCount(self: *const StructuralQueue, additional_count: usize) bool {
        return additional_count <= self.requests.len - self.count and
            additional_count <= std.math.maxInt(u64) - self.next_sequence;
    }

    fn append(self: *StructuralQueue, operation: StructuralOperation, handle: runtime_object_registry.Handle, generation: u8) bool {
        if (!self.canAppend(generation)) return false;
        self.requests[self.count] = .{
            .operation = operation,
            .handle = handle,
            .generation = generation,
            .sequence = self.next_sequence,
            .origin = self.current_origin,
        };
        self.count += 1;
        self.next_sequence += 1;
        return true;
    }

    fn clear(self: *StructuralQueue) void {
        self.count = 0;
        self.current_origin = .{};
    }

    fn appendRequest(self: *StructuralQueue, request: StructuralRequest) bool {
        const previous_origin = self.current_origin;
        defer self.current_origin = previous_origin;
        self.current_origin = request.origin;
        return self.append(request.operation, request.handle, request.generation);
    }
};
// END FROZEN bfc5504 app/behavior_host.zig STRUCTURAL AUTHORITY

fn validEventValue(value: *const behavior_runtime.NativeEventValue) bool {
    return switch (value.kind) {
        1 => value.boolean_value == 0 or value.boolean_value == 1,
        2 => std.math.isFinite(value.number_value),
        3 => value.string_value != null and value.string_value_length <= 127,
        4 => validObjectHandleShape(&value.object_value),
        else => false,
    };
}

fn validObjectHandleShape(value: *const behavior_runtime.NativeObjectHandle) bool {
    return value.world_epoch != 0 and value.logical_generation != 0 and
        value.kind >= 1 and value.kind <= 4 and
        value.object_id_length > 0 and value.object_id_length <= behavior_runtime.max_object_id_bytes;
}

fn monotonicNs() u64 {
    var timestamp: std.os.linux.timespec = undefined;
    if (std.os.linux.clock_gettime(.MONOTONIC, &timestamp) != 0) return 0;
    return @as(u64, @intCast(timestamp.sec)) * std.time.ns_per_s + @as(u64, @intCast(timestamp.nsec));
}

fn percentile(samples: []u64, numerator: usize, denominator: usize) u64 {
    std.sort.heap(u64, samples, {}, std.sort.asc(u64));
    const rank = (samples.len * numerator + denominator - 1) / denominator;
    return samples[if (rank == 0) 0 else rank - 1];
}

fn fillHandle(handle: *behavior_runtime.NativeObjectHandle, id: []const u8) void {
    handle.* = std.mem.zeroes(behavior_runtime.NativeObjectHandle);
    handle.world_epoch = 1;
    handle.logical_generation = 1;
    handle.kind = 2;
    handle.object_id_length = id.len;
    @memcpy(handle.object_id[0..id.len], id);
}

fn runDomain(samples: []u64) !void {
    var event_queue = EventQueue{};
    var fields: [batch_size][8]behavior_runtime.NativeEventField = undefined;
    var field_strings: [batch_size][8][128]u8 = undefined;
    var batch: [batch_size]behavior_runtime.NativePostedEvent = undefined;
    var event_output: [batch_size]QueuedEvent = undefined;
    var structural_queue = StructuralQueue{};
    var structural_output: [batch_size]StructuralRequest = undefined;
    var registry = try runtime_object_registry.Registry.init(&scene_api.default_scene);

    for (&batch, 0..) |*event, event_index| {
        event.* = std.mem.zeroes(behavior_runtime.NativePostedEvent);
        fillHandle(&event.target, "player");
        fillHandle(&event.sender, "player");
        event.name = "o0";
        event.name_length = 2;
        event.fields = &fields[event_index];
        event.field_count = fields[event_index].len;
        for (&fields[event_index], 0..) |*field, field_index| {
            field.* = std.mem.zeroes(behavior_runtime.NativeEventField);
            field.key = "k0";
            field.key_length = 2;
            @memset(&field_strings[event_index][field_index], @intCast('a' + (field_index % 26)));
            field.value.kind = 3;
            field.value.string_value = &field_strings[event_index][field_index];
            field.value.string_value_length = field_strings[event_index][field_index].len - 1;
        }
    }

    for (samples) |*sample| {
        const start = monotonicNs();
        for (&batch) |*event| {
            if (!event_queue.appendPosted(event, 0)) return error.InvalidBenchmarkBatch;
        }
        @memcpy(&event_output, &event_queue.events);
        event_queue.clear();

        for (0..batch_size) |index| {
            const reserved = try registry.reserveSpawn(0, .{ @floatFromInt(index), 0 }, 1);
            if (!structural_queue.append(.spawn, reserved.handle, 0)) return error.InvalidBenchmarkBatch;
        }
        @memcpy(&structural_output, &structural_queue.requests);
        structural_queue.clear();
        for (&structural_output) |*request| try registry.discardTransient(request.handle);

        std.mem.doNotOptimizeAway(&event_output);
        std.mem.doNotOptimizeAway(&structural_output);
        sample.* = monotonicNs() - start;
    }
}

pub fn main() !void {
    if (builtin.os.tag != .linux) return error.UnsupportedPlatform;
    var fixed_samples: [iterations]u64 = undefined;
    var frame_samples: [iterations]u64 = undefined;
    try runDomain(fixed_samples[0..]);
    try runDomain(frame_samples[0..]);
    std.debug.print(
        "phase_zig_oracle_bench iterations={d} batch={d} fixed_p50_ns={d} fixed_p95_ns={d} frame_p50_ns={d} frame_p95_ns={d} allocations=0\n",
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
