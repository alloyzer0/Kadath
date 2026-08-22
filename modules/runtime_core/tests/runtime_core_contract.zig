const std = @import("std");
const runtime_core = @import("runtime_core");

test "Runtime Core Adapter owns and destroys one opaque Core" {
    var core = try runtime_core.RuntimeCore.init();
    try std.testing.expect(core.handle != null);
    core.deinit();
    try std.testing.expect(core.handle == null);
}

test "Runtime Core Adapter drives a fixed phase through the public Phase Interface" {
    var core = try runtime_core.RuntimeCore.init();
    defer core.deinit();
    const sources = [_]runtime_core.SourceDesc{
        .{ .object_id = "player", .kind = 2, .sprite = .{ .position = .{ 10, 20 }, .size = .{ 8, 8 }, .color = .{ 1, 1, 1, 1 }, .texture_id = 1, .move_speed = 20 } },
        .{ .object_id = "goal", .kind = 3, .sprite = .{ .position = .{ 80, 20 }, .size = .{ 8, 8 }, .color = .{ 1, 1, 1, 1 }, .texture_id = 1 } },
    };
    _ = try core.prepare(.initial, .{ 0, 0 }, .{ 100, 100 }, &sources);
    try core.commitScene();
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
    activation.struct_size = @sizeOf(runtime_core.PhaseActivationBatch);
    activation.transaction_id = transaction.transaction_id;
    try core.submitPhaseActivation(transaction.transaction_id, &activation);
    const activated = try core.commitPhaseActivation(transaction.transaction_id);
    try std.testing.expectEqual(@as(u32, 2), activated.root_object.lifecycle);
    try core.endPhase(.fixed, 77);
}
