const std = @import("std");
const runtime_core = @import("runtime_core");

const canonical_sources = [_]runtime_core.SourceDesc{
    .{ .object_id = "player", .kind = 2, .sprite = .{ .position = .{ 10, 20 }, .size = .{ 8, 8 }, .color = .{ 1, 1, 1, 1 }, .texture_id = 1, .move_speed = 20 } },
    .{ .object_id = "hazard", .kind = 4, .sprite = .{ .position = .{ 60, 20 }, .size = .{ 8, 8 }, .color = .{ 1, 0, 0, 1 }, .texture_id = 1 } },
    .{ .object_id = "goal", .kind = 3, .sprite = .{ .position = .{ 80, 20 }, .size = .{ 8, 8 }, .color = .{ 1, 1, 0, 1 }, .texture_id = 1 } },
};

fn prepareGameplayCandidate(core: *runtime_core.RuntimeCore) !void {
    const player = (try core.findById(.candidate, "player")).?.object_ref;
    const hazard = (try core.findById(.candidate, "hazard")).?.object_ref;
    const goal = (try core.findById(.candidate, "goal")).?.object_ref;
    try core.prepareGameplay(3.0, player, goal, &.{.{ .object_ref = hazard }});
}

fn preparePairedScene(core: *runtime_core.RuntimeCore, mode: runtime_core.PrepareMode) !void {
    _ = try core.prepare(mode, .{ 0, 0 }, .{ 100, 100 }, &canonical_sources);
    try prepareGameplayCandidate(core);
    _ = try core.preparePhaseState(.candidate, &.{});
    try core.commitPhaseState();
    try core.commitScene();
}

const ReplayRng = struct {
    state: u64,

    fn next(self: *ReplayRng) u32 {
        self.state = self.state *% 6_364_136_223_846_793_005 +% 1_442_695_040_888_963_407;
        return @truncate(self.state >> 32);
    }
};

fn seededPhaseEvent(target: runtime_core.ObjectRef, domain: u32, generation: u32, command: u32) runtime_core.PhaseEvent {
    var event = std.mem.zeroes(runtime_core.PhaseEvent);
    event.struct_size = @sizeOf(runtime_core.PhaseEvent);
    event.domain = domain;
    event.generation = generation;
    event.target = target;
    event.name_length = 2;
    event.name[0] = 'p';
    event.name[1] = @intCast('0' + (command % 10));
    return event;
}

test "Runtime Core Adapter owns and destroys one opaque Core" {
    var core = try runtime_core.RuntimeCore.init();
    try std.testing.expect(core.handle != null);
    core.deinit();
    try std.testing.expect(core.handle == null);
}

test "Scene publication requires ready Object Gameplay and Phase candidates" {
    var core = try runtime_core.RuntimeCore.init();
    defer core.deinit();
    _ = try core.prepare(.initial, .{ 0, 0 }, .{ 100, 100 }, &canonical_sources);

    try std.testing.expectError(error.RuntimeCoreInvalidState, core.commitScene());
    var outcome: runtime_core.GameplayOutcome = undefined;
    try std.testing.expectError(error.InvalidGameplayState, core.beginGameplayFixed(0.0, &outcome));
    try std.testing.expect((try core.findById(.candidate, "player")) != null);
    try prepareGameplayCandidate(&core);
    try std.testing.expectError(error.RuntimeCoreInvalidState, core.commitScene());
    _ = try core.preparePhaseState(.candidate, &.{});
    try std.testing.expectError(error.RuntimeCoreInvalidState, core.commitScene());
    try core.commitPhaseState();
    try core.commitScene();
    try std.testing.expect((try core.findById(.live, "player")) != null);
}

test "Restart is terminal-only and preserves Gameplay sequence high-water marks" {
    var core = try runtime_core.RuntimeCore.init();
    defer core.deinit();
    try preparePairedScene(&core, .initial);

    var outcome: runtime_core.GameplayOutcome = undefined;
    const first = try core.beginGameplayFixed(0.0, &outcome);
    try core.abortGameplayFixed(first.step_token);
    _ = try core.prepare(.restart, .{ 0, 0 }, .{ 100, 100 }, &canonical_sources);
    try std.testing.expectError(error.InvalidGameplayState, prepareGameplayCandidate(&core));
    try core.abortScene();

    const terminal = try core.beginGameplayFixed(3.0, &outcome);
    try std.testing.expectEqual(@as(u64, first.step_token + 1), terminal.step_token);
    try std.testing.expectEqual(@as(u64, 1), outcome.sequence);
    try core.abortGameplayFixed(terminal.step_token);
    try preparePairedScene(&core, .restart);

    var render_items: [runtime_core.max_object_count]runtime_core.GameplayRenderItem = undefined;
    const snapshot = try core.gameplaySnapshot(&render_items);
    try std.testing.expectEqual(@as(u64, 1), snapshot.last_outcome_sequence);
    const restarted = try core.beginGameplayFixed(0.0, &outcome);
    try std.testing.expectEqual(@as(u64, terminal.step_token + 1), restarted.step_token);
    try core.abortGameplayFixed(restarted.step_token);
}

test "Runtime Core Adapter drives a fixed phase through the public Phase Interface" {
    var core = try runtime_core.RuntimeCore.init();
    defer core.deinit();
    try preparePairedScene(&core, .initial);
    const player = (try core.findById(.live, "player")).?.object_ref;
    try core.beginPhase(.fixed, 77);

    var event = std.mem.zeroes(runtime_core.PhaseEvent);
    event.struct_size = @sizeOf(runtime_core.PhaseEvent);
    event.domain = 1;
    event.target = player;
    event.name_length = 5;
    @memcpy(event.name[0..5], "hello");
    _ = try core.submitPhaseEvents(&[_]runtime_core.PhaseEvent{event});
    var drained: [1]runtime_core.PhaseEvent = undefined;
    try std.testing.expectEqual(@as(usize, 1), try core.drainPhaseEvents(.fixed, 77, &drained));

    var structural = std.mem.zeroes(runtime_core.PhaseStructural);
    structural.struct_size = @sizeOf(runtime_core.PhaseStructural);
    structural.operation = 1;
    structural.domain = 1;
    structural.behavior_count = 1;
    structural.prototype_key = 7;
    structural.script_id = 11;
    structural.origin = player;
    structural.transient_sprite.struct_size = @sizeOf(@TypeOf(structural.transient_sprite));
    structural.transient_sprite.size = .{ 4, 4 };
    structural.transient_sprite.color[3] = 1;
    structural.transient_sprite.texture_id = 1;
    var completion = std.mem.zeroes(runtime_core.PhaseCompletion);
    completion.struct_size = @sizeOf(runtime_core.PhaseCompletion);
    var structural_items = [_]runtime_core.PhaseStructural{structural};
    var completions = [_]runtime_core.PhaseCompletion{completion};
    _ = try core.submitPhaseStructural(&structural_items, &completions);
    var taken: [1]runtime_core.PhaseStructural = undefined;
    const flush = try core.takePhaseStructural(.fixed, 77, &taken);
    const transaction = try core.beginPhaseActivation(flush.info.flush_token, taken[0].sequence);
    var activation = std.mem.zeroes(runtime_core.PhaseActivationBatch);
    var activation_results = [_]runtime_core.PhaseActivationStructuralResult{std.mem.zeroes(runtime_core.PhaseActivationStructuralResult)};
    activation_results[0].struct_size = @sizeOf(runtime_core.PhaseActivationStructuralResult);
    activation.struct_size = @sizeOf(runtime_core.PhaseActivationBatch);
    activation.transaction_id = transaction.transaction_id;
    activation.active_binding_capacity = runtime_core.max_phase_bindings;
    activation.structural = &structural;
    activation.structural_count = 1;
    activation.structural_stride = @sizeOf(runtime_core.PhaseStructural);
    try core.submitPhaseActivation(transaction.transaction_id, &activation, &activation_results);
    try std.testing.expectEqual(@as(u32, 1), activation_results[0].status);
    try std.testing.expect(activation_results[0].sequence != 0);
    try std.testing.expect(activation_results[0].object_ref.object_id_length != 0);
    const activated = try core.commitPhaseActivation(transaction.transaction_id);
    try std.testing.expectEqual(@as(u32, 2), activated.root_object.lifecycle);
    var nested_taken: [1]runtime_core.PhaseStructural = undefined;
    const nested_flush = try core.takePhaseStructural(.fixed, 77, &nested_taken);
    const nested_transaction = try core.beginPhaseActivation(nested_flush.info.flush_token, nested_taken[0].sequence);
    var nested_activation = std.mem.zeroes(runtime_core.PhaseActivationBatch);
    nested_activation.struct_size = @sizeOf(runtime_core.PhaseActivationBatch);
    nested_activation.transaction_id = nested_transaction.transaction_id;
    nested_activation.active_binding_capacity = runtime_core.max_phase_bindings;
    try core.submitPhaseActivation(nested_transaction.transaction_id, &nested_activation, &[_]runtime_core.PhaseActivationStructuralResult{});
    _ = try core.commitPhaseActivation(nested_transaction.transaction_id);
    try core.endPhase(.fixed, 77);
}

test "Rust Core owns generated phase sequence high-water" {
    var core = try runtime_core.RuntimeCore.init();
    defer core.deinit();
    try preparePairedScene(&core, .initial);

    const first = try core.beginPhaseOwned(.frame);
    try std.testing.expect(first != 0);
    try core.endPhase(.frame, first);
    const second = try core.beginPhaseOwned(.frame);
    try std.testing.expectEqual(first + 1, second);
    try core.endPhase(.frame, second);
}

test "Runtime Core Phase replay preserves FIFO, domain counters, and generation bounds" {
    var core = try runtime_core.RuntimeCore.init();
    defer core.deinit();
    try preparePairedScene(&core, .initial);
    const player = (try core.findById(.live, "player")).?.object_ref;

    // This is a deterministic replay trace captured under seed 0x50484153.
    const seed: u32 = 0x5048_4153;
    try std.testing.expectEqual(@as(u32, 0x5048_4153), seed);
    try core.beginPhase(.fixed, seed);

    var drained: [runtime_core.max_phase_events]runtime_core.PhaseEvent = undefined;
    var bounded_batch: [runtime_core.max_phase_events]runtime_core.PhaseEvent = undefined;
    for (&bounded_batch, 0..) |*event, index| {
        event.* = seededPhaseEvent(player, 1, 0, @intCast(index));
    }
    const batch = try core.submitPhaseEvents(bounded_batch[0..]);
    try std.testing.expectEqual(@as(u64, 1), batch.first_sequence);
    try std.testing.expectEqual(@as(u64, runtime_core.max_phase_events), batch.last_sequence);
    try std.testing.expectError(
        error.RuntimePhaseQueueCapacity,
        core.submitPhaseEvents(&[_]runtime_core.PhaseEvent{seededPhaseEvent(player, 1, 0, runtime_core.max_phase_events)}),
    );
    const bounded_count = try core.drainPhaseEvents(.fixed, seed, drained[0..]);
    try std.testing.expectEqual(runtime_core.max_phase_events, bounded_count);
    for (drained[0..bounded_count], 0..) |event, index| {
        try std.testing.expectEqual(@as(u64, @intCast(index + 1)), event.sequence);
        try std.testing.expectEqual(@as(u32, 0), event.generation);
    }
    try core.endPhase(.fixed, seed);

    try core.beginPhase(.fixed, seed + 1);
    var expected_sequence: u64 = runtime_core.max_phase_events + 1;
    const generation_steps: u32 = runtime_core.max_phase_generation + 1;
    var command: u32 = 0;
    while (command < generation_steps) : (command += 1) {
        const event = seededPhaseEvent(player, 1, 0, command);
        const generation_batch = try core.submitPhaseEvents(&[_]runtime_core.PhaseEvent{event});
        try std.testing.expectEqual(expected_sequence, generation_batch.first_sequence);
        try std.testing.expectEqual(expected_sequence, generation_batch.last_sequence);
        const count = try core.drainPhaseEvents(.fixed, seed + 1, drained[0..]);
        try std.testing.expectEqual(@as(usize, 1), count);
        try std.testing.expectEqual(expected_sequence, drained[0].sequence);
        try std.testing.expectEqual(command, drained[0].generation);
        expected_sequence += 1;
    }

    // The ninth successor is generation 8; the next request is exhausted and
    // must leave the phase state unchanged.
    try std.testing.expectError(
        error.RuntimePhaseGenerationExhausted,
        core.submitPhaseEvents(&[_]runtime_core.PhaseEvent{seededPhaseEvent(player, 1, 0, 9)}),
    );
    try std.testing.expectEqual(@as(usize, 0), try core.drainPhaseEvents(.fixed, seed + 1, drained[0..]));
    try core.endPhase(.fixed, seed + 1);

    // Fixed and frame domains keep independent sequence counters.
    try core.beginPhase(.frame, seed + 2);
    const frame_event = seededPhaseEvent(player, 2, 0, 10);
    const frame_batch = try core.submitPhaseEvents(&[_]runtime_core.PhaseEvent{frame_event});
    try std.testing.expectEqual(@as(u64, 1), frame_batch.first_sequence);
    try std.testing.expectEqual(@as(usize, 1), try core.drainPhaseEvents(.frame, seed + 2, drained[0..]));
    try std.testing.expectEqual(@as(u64, 1), drained[0].sequence);
    try core.endPhase(.frame, seed + 2);
}

test "Runtime Core Phase bounded command replay is reproducible across seeds" {
    const seeds = [_]u64{
        0x5048_4153_0000_0001,
        0x5048_4153_0000_0002,
        0x5048_4153_0000_0003,
        0x5048_4153_0000_0004,
    };

    for (seeds) |seed| {
        var core = try runtime_core.RuntimeCore.init();
        defer core.deinit();
        try preparePairedScene(&core, .initial);
        const player = (try core.findById(.live, "player")).?.object_ref;
        const phase_sequence = if (seed == 0) 1 else seed;
        try core.beginPhase(.fixed, phase_sequence);

        var rng = ReplayRng{ .state = seed };
        var drained: [runtime_core.max_phase_events]runtime_core.PhaseEvent = undefined;
        var expected_generation: u32 = 0;
        var expected_sequence: u64 = 1;
        var queued: usize = 0;
        var command_index: u32 = 0;
        while (command_index < 32) : (command_index += 1) {
            const draw = rng.next();
            if (queued > 0 and (draw & 3) == 0) {
                const count = try core.drainPhaseEvents(.fixed, phase_sequence, drained[0..]);
                try std.testing.expectEqual(queued, count);
                const first_sequence = expected_sequence - @as(u64, @intCast(count));
                for (drained[0..count], 0..) |event, index| {
                    try std.testing.expectEqual(expected_generation, event.generation);
                    try std.testing.expectEqual(first_sequence + @as(u64, @intCast(index)), event.sequence);
                }
                queued = 0;
                expected_generation += 1;
                if (expected_generation > runtime_core.max_phase_generation) break;
                continue;
            }
            if (expected_generation > runtime_core.max_phase_generation) break;

            const input_generation = switch ((draw >> 2) % 4) {
                0 => 0,
                1 => expected_generation,
                2 => expected_generation + 1,
                else => runtime_core.max_phase_generation + 1,
            };
            const event = seededPhaseEvent(player, 1, input_generation, command_index);
            const result = core.submitPhaseEvents(&[_]runtime_core.PhaseEvent{event}) catch |err| {
                const expected_error = if (input_generation > runtime_core.max_phase_generation)
                    error.InvalidRuntimeCoreArgument
                else
                    error.InvalidRuntimePhaseRequest;
                try std.testing.expectEqual(expected_error, err);
                continue;
            };
            try std.testing.expectEqual(expected_sequence, result.first_sequence);
            try std.testing.expectEqual(expected_sequence, result.last_sequence);
            expected_sequence += 1;
            queued += 1;
        }

        if (queued > 0) {
            const count = try core.drainPhaseEvents(.fixed, phase_sequence, drained[0..]);
            try std.testing.expectEqual(queued, count);
            for (drained[0..count]) |event| {
                try std.testing.expectEqual(expected_generation, event.generation);
            }
        }
        try core.endPhase(.fixed, phase_sequence);
    }
}

test "Runtime Core Phase admission overflow preserves structural state" {
    var core = try runtime_core.RuntimeCore.init();
    defer core.deinit();
    try preparePairedScene(&core, .initial);
    const player = (try core.findById(.live, "player")).?.object_ref;

    var over_capacity: [runtime_core.max_phase_bindings / 4 + 1]runtime_core.PhaseBinding = undefined;
    for (&over_capacity) |*binding| {
        binding.* = std.mem.zeroes(runtime_core.PhaseBinding);
        binding.struct_size = @sizeOf(runtime_core.PhaseBinding);
        binding.object_ref = player;
        binding.behavior_count = 4;
    }
    try std.testing.expectError(
        error.RuntimePhaseAdmissionCapacity,
        core.preparePhaseState(.live, over_capacity[0..]),
    );

    var bindings: [runtime_core.max_phase_bindings / 4]runtime_core.PhaseBinding = undefined;
    for (&bindings) |*binding| {
        binding.* = std.mem.zeroes(runtime_core.PhaseBinding);
        binding.struct_size = @sizeOf(runtime_core.PhaseBinding);
        binding.object_ref = player;
        binding.behavior_count = 4;
    }
    const candidate = try core.preparePhaseState(.live, bindings[0..]);
    try std.testing.expectEqual(@as(u32, runtime_core.max_phase_bindings / 4), candidate.binding_count);
    try core.commitPhaseState();

    const phase_sequence: u64 = 0x4144_4d49_5353_494f;
    try core.beginPhase(.fixed, phase_sequence);
    var structural = std.mem.zeroes(runtime_core.PhaseStructural);
    structural.struct_size = @sizeOf(runtime_core.PhaseStructural);
    structural.operation = runtime_core.phase_operation_reserve_transient;
    structural.domain = 1;
    structural.behavior_count = 1;
    structural.prototype_key = 5;
    structural.script_id = 19;
    structural.origin = player;
    structural.transient_sprite.struct_size = @sizeOf(@TypeOf(structural.transient_sprite));
    structural.transient_sprite.size = .{ 4, 4 };
    structural.transient_sprite.color[3] = 1;
    structural.transient_sprite.texture_id = 1;
    var completion = std.mem.zeroes(runtime_core.PhaseCompletion);
    completion.struct_size = @sizeOf(runtime_core.PhaseCompletion);
    var structural_items = [_]runtime_core.PhaseStructural{structural};
    var completions = [_]runtime_core.PhaseCompletion{completion};
    try std.testing.expectError(
        error.RuntimePhaseAdmissionCapacity,
        core.submitPhaseStructural(structural_items[0..], completions[0..]),
    );

    var taken: [1]runtime_core.PhaseStructural = undefined;
    const flush = try core.takePhaseStructural(.fixed, phase_sequence, taken[0..]);
    try std.testing.expectEqual(@as(usize, 0), flush.count);
    try core.endPhase(.fixed, phase_sequence);

    // A 255-binding state plus one accepted structural reservation must admit
    // the exact 256th binding; only the 257th is overflow.
    bindings[bindings.len - 1].behavior_count = 3;
    const exact_candidate = try core.preparePhaseState(.live, bindings[0..]);
    try std.testing.expectEqual(@as(u32, runtime_core.max_phase_bindings / 4), exact_candidate.binding_count);
    try core.commitPhaseState();
    try core.beginPhase(.fixed, phase_sequence + 1);
    completion = std.mem.zeroes(runtime_core.PhaseCompletion);
    completion.struct_size = @sizeOf(runtime_core.PhaseCompletion);
    completions[0] = completion;
    const exact_batch = try core.submitPhaseStructural(structural_items[0..], completions[0..]);
    try std.testing.expectEqual(@as(usize, 1), exact_batch.accepted_count);
    const exact_flush = try core.takePhaseStructural(.fixed, phase_sequence + 1, taken[0..]);
    try std.testing.expectEqual(@as(usize, 1), exact_flush.count);
    try core.abortPhaseStructural(exact_flush.info.flush_token);
    try core.endPhase(.fixed, phase_sequence + 1);
}

test "candidate Phase admission stays private until paired Scene commit" {
    var core = try runtime_core.RuntimeCore.init();
    defer core.deinit();
    try preparePairedScene(&core, .initial);
    const live_player = (try core.findById(.live, "player")).?.object_ref;

    var restart_outcome: runtime_core.GameplayOutcome = undefined;
    const terminal = try core.beginGameplayFixed(3.0, &restart_outcome);
    try core.abortGameplayFixed(terminal.step_token);
    _ = try core.prepare(.restart, .{ 0, 0 }, .{ 100, 100 }, &canonical_sources);
    const candidate_player = (try core.findById(.candidate, "player")).?.object_ref;
    try prepareGameplayCandidate(&core);
    var bindings: [runtime_core.max_phase_bindings / 4]runtime_core.PhaseBinding = undefined;
    for (&bindings) |*binding| {
        binding.* = std.mem.zeroes(runtime_core.PhaseBinding);
        binding.struct_size = @sizeOf(runtime_core.PhaseBinding);
        binding.object_ref = candidate_player;
        binding.behavior_count = 4;
    }
    _ = try core.preparePhaseState(.candidate, bindings[0..]);
    try core.commitPhaseState();

    var request = std.mem.zeroes(runtime_core.PhaseStructural);
    request.struct_size = @sizeOf(runtime_core.PhaseStructural);
    request.operation = runtime_core.phase_operation_reserve_transient;
    request.domain = @intFromEnum(runtime_core.PhaseDomain.fixed);
    request.behavior_count = 1;
    request.prototype_key = 5;
    request.origin = live_player;
    request.transient_sprite.struct_size = @sizeOf(@TypeOf(request.transient_sprite));
    request.transient_sprite.size = .{ 4, 4 };
    request.transient_sprite.color[3] = 1;
    request.transient_sprite.texture_id = 1;
    var completion = std.mem.zeroes(runtime_core.PhaseCompletion);
    completion.struct_size = @sizeOf(runtime_core.PhaseCompletion);
    var requests = [_]runtime_core.PhaseStructural{request};
    var completions = [_]runtime_core.PhaseCompletion{completion};

    try core.beginPhase(.fixed, 0x5041_4952_4c49_5645);
    _ = try core.submitPhaseStructural(requests[0..], completions[0..]);
    var taken: [1]runtime_core.PhaseStructural = undefined;
    const flush = try core.takePhaseStructural(.fixed, 0x5041_4952_4c49_5645, taken[0..]);
    try core.abortPhaseStructural(flush.info.flush_token);
    try core.endPhase(.fixed, 0x5041_4952_4c49_5645);

    try core.commitScene();
    requests[0].origin = candidate_player;
    completions[0] = std.mem.zeroes(runtime_core.PhaseCompletion);
    completions[0].struct_size = @sizeOf(runtime_core.PhaseCompletion);
    try core.beginPhase(.fixed, 0x5041_4952_4e45_5753);
    try std.testing.expectError(
        error.RuntimePhaseAdmissionCapacity,
        core.submitPhaseStructural(requests[0..], completions[0..]),
    );
    try core.endPhase(.fixed, 0x5041_4952_4e45_5753);
}

test "Runtime Core structural replay preserves bounded FIFO and successor generation" {
    var core = try runtime_core.RuntimeCore.init();
    defer core.deinit();
    try preparePairedScene(&core, .initial);
    const player = (try core.findById(.live, "player")).?.object_ref;
    const phase_sequence: u64 = 0x5354_5255_4354_5552;
    try core.beginPhase(.fixed, phase_sequence);

    var structural_items: [runtime_core.max_phase_structural]runtime_core.PhaseStructural = undefined;
    var completions: [runtime_core.max_phase_structural]runtime_core.PhaseCompletion = undefined;
    for (&structural_items, 0..) |*item, index| {
        item.* = std.mem.zeroes(runtime_core.PhaseStructural);
        item.struct_size = @sizeOf(runtime_core.PhaseStructural);
        item.operation = runtime_core.phase_operation_reserve_transient;
        item.domain = 1;
        item.behavior_count = 1;
        item.prototype_key = @intCast(index + 1);
        item.script_id = @intCast(index + 1);
        item.origin = player;
        item.transient_sprite.struct_size = @sizeOf(@TypeOf(item.transient_sprite));
        item.transient_sprite.size = .{ 4, 4 };
        item.transient_sprite.color[3] = 1;
        item.transient_sprite.texture_id = 1;
        completions[index] = std.mem.zeroes(runtime_core.PhaseCompletion);
        completions[index].struct_size = @sizeOf(runtime_core.PhaseCompletion);
    }
    const batch = try core.submitPhaseStructural(structural_items[0..], completions[0..]);
    try std.testing.expectEqual(@as(u64, 1), batch.first_sequence);
    try std.testing.expectEqual(@as(u64, runtime_core.max_phase_structural), batch.last_sequence);
    for (completions, 0..) |completion, index| {
        try std.testing.expectEqual(@as(u32, runtime_core.phase_completion_accepted), completion.status);
        try std.testing.expectEqual(@as(u64, @intCast(index + 1)), completion.sequence);
        try std.testing.expect(completion.object.object_ref.object_id_length != 0);
    }

    var overflow_item = structural_items[0];
    overflow_item.prototype_key = 999;
    var overflow_completion = std.mem.zeroes(runtime_core.PhaseCompletion);
    overflow_completion.struct_size = @sizeOf(runtime_core.PhaseCompletion);
    var overflow_items = [_]runtime_core.PhaseStructural{overflow_item};
    var overflow_completions = [_]runtime_core.PhaseCompletion{overflow_completion};
    try std.testing.expectError(
        error.RuntimePhaseQueueCapacity,
        core.submitPhaseStructural(overflow_items[0..], overflow_completions[0..]),
    );

    var taken: [runtime_core.max_phase_structural]runtime_core.PhaseStructural = undefined;
    const flush = try core.takePhaseStructural(.fixed, phase_sequence, taken[0..]);
    try std.testing.expectEqual(runtime_core.max_phase_structural, flush.count);
    for (taken[0..flush.count], 0..) |item, index| {
        try std.testing.expectEqual(@as(u64, @intCast(index + 1)), item.sequence);
        try std.testing.expectEqual(@as(u32, 0), item.generation);
    }
    try core.abortPhaseStructural(flush.info.flush_token);

    var successor_item = structural_items[0];
    successor_item.prototype_key = 1_001;
    var successor_completion = std.mem.zeroes(runtime_core.PhaseCompletion);
    successor_completion.struct_size = @sizeOf(runtime_core.PhaseCompletion);
    var successor_items = [_]runtime_core.PhaseStructural{successor_item};
    var successor_completions = [_]runtime_core.PhaseCompletion{successor_completion};
    const successor_batch = try core.submitPhaseStructural(successor_items[0..], successor_completions[0..]);
    try std.testing.expectEqual(@as(u64, runtime_core.max_phase_structural + 1), successor_batch.first_sequence);
    const successor_flush = try core.takePhaseStructural(.fixed, phase_sequence, taken[0..]);
    try std.testing.expectEqual(@as(usize, 1), successor_flush.count);
    try std.testing.expectEqual(@as(u32, 1), taken[0].generation);
    try core.abortPhaseStructural(successor_flush.info.flush_token);
    try core.endPhase(.fixed, phase_sequence);
}

test "Runtime Core Gameplay owns terminal priority contact events outcome and final tint" {
    var core = try runtime_core.RuntimeCore.init();
    defer core.deinit();
    const sources = [_]runtime_core.SourceDesc{
        .{ .object_id = "player", .kind = 2, .sprite = .{ .position = .{ 10, 20 }, .size = .{ 8, 8 }, .color = .{ 1, 1, 1, 1 }, .texture_id = 1, .move_speed = 20 } },
        .{ .object_id = "hazard", .kind = 4, .sprite = .{ .position = .{ 10, 20 }, .size = .{ 8, 8 }, .color = .{ 1, 0, 0, 1 }, .texture_id = 1 } },
        .{ .object_id = "goal", .kind = 3, .sprite = .{ .position = .{ 10, 20 }, .size = .{ 8, 8 }, .color = .{ 1, 1, 0, 1 }, .texture_id = 1 } },
    };
    _ = try core.prepare(.initial, .{ 0, 0 }, .{ 100, 100 }, &sources);
    const player = (try core.findById(.candidate, "player")).?.object_ref;
    const hazard = (try core.findById(.candidate, "hazard")).?.object_ref;
    const goal = (try core.findById(.candidate, "goal")).?.object_ref;
    try core.prepareGameplay(3.0, player, goal, &.{.{ .object_ref = hazard }});
    _ = try core.preparePhaseState(.candidate, &.{});
    try core.commitPhaseState();
    try core.commitScene();

    var outcome: runtime_core.GameplayOutcome = undefined;
    const begin = try core.beginGameplayFixed(0.0, &outcome);
    try std.testing.expectEqual(@intFromEnum(runtime_core.GameplayPhase.playing), begin.phase);
    try std.testing.expectEqual(@as(usize, 0), begin.outcome_count);
    try core.beginPhase(.fixed, begin.step_token);
    const committed = try core.commitGameplayFixed(begin.step_token, .{}, &outcome);
    try std.testing.expectEqual(@intFromEnum(runtime_core.GameplayPhase.lost), committed.phase);
    try std.testing.expectEqual(@intFromEnum(runtime_core.GameplayCause.hazard), committed.cause);
    try std.testing.expectEqual(@as(usize, 1), committed.outcome_count);
    try std.testing.expectEqual(@as(usize, 4), committed.submitted_contact_event_count);
    try std.testing.expectEqual(@as(u64, 1), outcome.sequence);
    try std.testing.expect(runtime_core.sameObjectRef(hazard, outcome.other));

    var events: [runtime_core.max_phase_events]runtime_core.PhaseEvent = undefined;
    for (&events) |*event| {
        event.* = std.mem.zeroes(runtime_core.PhaseEvent);
        event.struct_size = @sizeOf(runtime_core.PhaseEvent);
    }
    const event_count = try core.drainPhaseEvents(.fixed, begin.step_token, &events);
    try std.testing.expectEqual(@as(usize, 4), event_count);
    try std.testing.expectEqualStrings("contact_begin", events[0].name[0..events[0].name_length]);
    try core.endPhase(.fixed, begin.step_token);

    var render_items: [runtime_core.max_object_count]runtime_core.GameplayRenderItem = undefined;
    const snapshot = try core.gameplaySnapshot(&render_items);
    try std.testing.expectEqual(@intFromEnum(runtime_core.GameplayPhase.lost), snapshot.phase);
    try std.testing.expectEqual(@as(u32, 0), snapshot.accepts_input);
    try std.testing.expectEqual(@as(u64, 1), snapshot.last_outcome_sequence);
    try std.testing.expectEqual([4]f32{ 0.95, 0.20, 0.20, 1.0 }, render_items[0].final_color);

    const terminal_begin = try core.beginGameplayFixed(0.5, &outcome);
    try std.testing.expectEqual(@as(usize, 0), terminal_begin.outcome_count);
    try core.abortGameplayFixed(terminal_begin.step_token);
}

test "Gameplay step token is independent from the active fixed Phase sequence" {
    var core = try runtime_core.RuntimeCore.init();
    defer core.deinit();
    try preparePairedScene(&core, .initial);

    var outcome: runtime_core.GameplayOutcome = undefined;
    const begin = try core.beginGameplayFixed(0.0, &outcome);
    const phase_sequence: u64 = 77;
    try std.testing.expect(begin.step_token != phase_sequence);
    try core.beginPhase(.fixed, phase_sequence);
    _ = try core.commitGameplayFixed(begin.step_token, .{}, &outcome);
    var events: [runtime_core.max_phase_events]runtime_core.PhaseEvent = undefined;
    for (&events) |*event| {
        event.* = std.mem.zeroes(runtime_core.PhaseEvent);
        event.struct_size = @sizeOf(runtime_core.PhaseEvent);
    }
    while (try core.drainPhaseEvents(.fixed, phase_sequence, &events) != 0) {}
    try core.endPhase(.fixed, phase_sequence);
}

test "Gameplay Zig Adapter preserves caller outputs when Core rejects a call" {
    var core = try runtime_core.RuntimeCore.init();
    defer core.deinit();
    try preparePairedScene(&core, .initial);

    var outcome = std.mem.zeroes(runtime_core.GameplayOutcome);
    outcome.sequence = 0x1122_3344_5566_7788;
    const outcome_before = std.mem.asBytes(&outcome).*;
    try std.testing.expectError(error.InvalidRuntimeCoreArgument, core.beginGameplayFixed(-1.0, &outcome));
    try std.testing.expectEqualSlices(u8, &outcome_before, std.mem.asBytes(&outcome));

    var render_items: [1]runtime_core.GameplayRenderItem = undefined;
    @memset(std.mem.asBytes(&render_items), 0xA5);
    const render_before = std.mem.asBytes(&render_items).*;
    try std.testing.expectError(error.RuntimeCoreBufferTooSmall, core.gameplaySnapshot(&render_items));
    try std.testing.expectEqualSlices(u8, &render_before, std.mem.asBytes(&render_items));
}

test "Gameplay commit keeps its plan private when the shared Phase queue is full" {
    var core = try runtime_core.RuntimeCore.init();
    defer core.deinit();
    try preparePairedScene(&core, .initial);
    const player = (try core.findById(.live, "player")).?.object_ref;
    const hazard = (try core.findById(.live, "hazard")).?.object_ref;
    const goal = (try core.findById(.live, "goal")).?.object_ref;
    try core.applyPositions(.live, &.{
        .{ .object_ref = hazard, .position = .{ 10, 20 } },
        .{ .object_ref = goal, .position = .{ 10, 20 } },
    });

    var outcome = std.mem.zeroes(runtime_core.GameplayOutcome);
    outcome.sequence = 0x8877_6655_4433_2211;
    const outcome_before = std.mem.asBytes(&outcome).*;
    const begin = try core.beginGameplayFixed(0.0, &outcome);
    const phase_sequence: u64 = 900;
    try core.beginPhase(.fixed, phase_sequence);
    var ordinary: [runtime_core.max_phase_events - 2]runtime_core.PhaseEvent = undefined;
    for (&ordinary) |*event| {
        event.* = std.mem.zeroes(runtime_core.PhaseEvent);
        event.struct_size = @sizeOf(runtime_core.PhaseEvent);
        event.domain = @intFromEnum(runtime_core.PhaseDomain.fixed);
        event.target = player;
        event.name_length = 4;
        @memcpy(event.name[0..4], "user");
    }
    _ = try core.submitPhaseEvents(&ordinary);
    try std.testing.expectError(
        error.RuntimePhaseQueueCapacity,
        core.commitGameplayFixed(begin.step_token, .{}, &outcome),
    );
    try std.testing.expectEqualSlices(u8, &outcome_before, std.mem.asBytes(&outcome));
    try core.abortGameplayFixed(begin.step_token);

    var drained: [runtime_core.max_phase_events]runtime_core.PhaseEvent = undefined;
    for (&drained) |*event| {
        event.* = std.mem.zeroes(runtime_core.PhaseEvent);
        event.struct_size = @sizeOf(runtime_core.PhaseEvent);
    }
    try std.testing.expectEqual(ordinary.len, try core.drainPhaseEvents(.fixed, phase_sequence, &drained));
    try std.testing.expectEqualStrings("user", drained[ordinary.len - 1].name[0..4]);
    try core.endPhase(.fixed, phase_sequence);

    const retry = try core.beginGameplayFixed(0.0, &outcome);
    try core.beginPhase(.fixed, phase_sequence + 1);
    const committed = try core.commitGameplayFixed(retry.step_token, .{}, &outcome);
    try std.testing.expectEqual(@as(usize, 1), committed.outcome_count);
    try std.testing.expectEqual(@intFromEnum(runtime_core.GameplayCause.hazard), committed.cause);
    try std.testing.expectEqual(@as(u64, 1), outcome.sequence);
    while (try core.drainPhaseEvents(.fixed, phase_sequence + 1, &drained) != 0) {}
    try core.endPhase(.fixed, phase_sequence + 1);
}
