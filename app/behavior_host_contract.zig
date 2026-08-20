const std = @import("std");
const behavior_host = @import("behavior_host.zig");
const behavior_host_stub = @import("behavior_host_stub.zig");
const builder = @import("behavior_package_builder");
const manifest = @import("behavior_manifest");
const scene_api = @import("scene.zig");
const scene_generation_api = @import("scene_generation.zig");

const ScriptFile = struct {
    path: []const u8,
    source: []const u8,
};

const RuntimeFixture = struct {
    generation: scene_generation_api.SceneGeneration,
    runtime: behavior_host.Runtime,

    fn deinit(self: *RuntimeFixture) void {
        self.runtime.deinit();
        self.generation.deinit();
    }
};

const no_op_source =
    \\--!strict
    \\return { fixed_update = function(self: Kadath.Object, dt: number) end }
;

fn makeRuntimeFixture(
    manifest_source: []const u8,
    files: []const ScriptFile,
    runtime_scene_source: []const u8,
) !RuntimeFixture {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "scripts", .default_dir);
    for (files) |file| {
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = file.path, .data = file.source });
    }
    var snapshot = try manifest.loadSnapshot(std.testing.io, std.testing.allocator, tmp.dir, manifest_source);
    defer snapshot.deinit();
    var diagnostic = builder.Diagnostic{};
    var built = try builder.build(std.testing.allocator, &snapshot, &diagnostic);
    defer built.deinit();

    const scene = try scene_api.parse(std.testing.allocator, runtime_scene_source);
    var generation = try scene_generation_api.SceneGeneration.prepare(scene, .{ .width = 1024, .height = 720 });
    errdefer generation.deinit();
    const runtime = try behavior_host.initArtifact(std.testing.allocator, built.bytes, &scene);
    return .{ .generation = generation, .runtime = runtime };
}

const source_manifest =
    \\{
    \\  "schemaVersion": 2,
    \\  "scripts": [
    \\    { "scriptId": 7, "source": "scripts/patrol.luau" },
    \\    { "scriptId": 8, "source": "scripts/input_scale.luau" }
    \\  ]
    \\}
;

const input_scale_source =
    \\--!strict
    \\return {
    \\    fixed_update = function(self: Kadath.Object, dt: number)
    \\        local move_x, move_y = kadath.input.move_axis()
    \\        self:translate(move_x * 2 + dt - dt, move_y)
    \\    end,
    \\    update = function(self: Kadath.Object, dt: number)
    \\        kadath.event.post(self, "advance")
    \\    end,
    \\    on_event = function(self: Kadath.Object, event: Kadath.Event)
    \\        if event.name == "advance" then
    \\            self:translate(2, 0)
    \\            kadath.event.post(self, "follow")
    \\        elseif event.name == "follow" then
    \\            self:translate(3, 0)
    \\        end
    \\    end,
    \\}
;

const patrol_source =
    \\--!strict
    \\local speed = kadath.parameter.number("speed", { default = 10, min = 0, max = 100 })
    \\local direction = 1
    \\return {
    \\    on_start = function(self: Kadath.Object)
    \\        self:translate(1, 0)
    \\    end,
    \\    fixed_update = function(self: Kadath.Object, dt: number)
    \\        local move_x, move_y = kadath.input.move_axis()
    \\        self:translate(move_x, move_y + speed * direction * dt)
    \\        direction = -direction
    \\    end,
    \\}
;

const scene_source =
    \\{"schemaVersion":5,"textures":[{"textureId":1,"artifact":"assets/renderer2d/test.texture"}],"objects":[
    \\{"objectId":"goal","kind":"goal","transform":{"position":[10,20]},"sprite":{"size":[3,4],"color":[1,1,1,1],"textureId":1},"behaviors":[]},
    \\{"objectId":"hazard-1","kind":"patrol_hazard","transform":{"position":[30,40]},"sprite":{"size":[5,6],"color":[1,0,0,1],"textureId":1},"behaviors":[{"scriptId":7,"parameters":{"speed":10}}]},
    \\{"objectId":"player","kind":"player","transform":{"position":[1,2]},"sprite":{"size":[8,9],"color":[1,1,1,1],"textureId":1},"player":{"moveSpeed":10},"behaviors":[{"scriptId":7,"parameters":{"speed":20}},{"scriptId":8,"parameters":{}}]}]}
;

test "Behavior Host keeps runtime ownership stack bounded" {
    try std.testing.expect(@sizeOf(behavior_host.Runtime) < 1024);
}

test "unsupported Behavior Host stub mirrors the Host v3 scheduling surface" {
    var runtime = behavior_host_stub.Runtime{};
    var generation: scene_generation_api.SceneGeneration = undefined;
    try std.testing.expectError(error.UnsupportedBehaviorRuntime, runtime.onStart(&generation));
    try std.testing.expectError(error.UnsupportedBehaviorRuntime, runtime.runFixed(&generation, 1.0 / 60.0, .{}));
    try std.testing.expectError(error.UnsupportedBehaviorRuntime, runtime.runUpdate(&generation, 0.25, .{}));
    try std.testing.expectError(error.UnsupportedBehaviorRuntime, runtime.finishFixedStep(&generation, &.{}, .{}));
    try std.testing.expectError(error.UnsupportedBehaviorRuntime, runtime.finishFrame(&generation, .{}));
}

test "Behavior Host applies on_start and fixed commands in Scene order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "scripts", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "scripts/patrol.luau", .data = patrol_source });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "scripts/input_scale.luau", .data = input_scale_source });
    var snapshot = try manifest.loadSnapshot(std.testing.io, std.testing.allocator, tmp.dir, source_manifest);
    defer snapshot.deinit();
    var diagnostic = builder.Diagnostic{};
    var built = try builder.build(std.testing.allocator, &snapshot, &diagnostic);
    defer built.deinit();

    const scene = try scene_api.parse(std.testing.allocator, scene_source);
    var generation = try scene_generation_api.SceneGeneration.prepare(scene, .{ .width = 1024, .height = 720 });
    defer generation.deinit();
    var runtime = try behavior_host.initArtifact(std.testing.allocator, built.bytes, &scene);
    defer runtime.deinit();

    var restart_runtime = try runtime.cloneForRestart(std.testing.allocator, &scene);
    defer restart_runtime.deinit();
    try std.testing.expectEqual(runtime.worldEpoch(), restart_runtime.worldEpoch());
    var reloaded_scene_runtime = try runtime.cloneForSceneReload(std.testing.allocator, &scene);
    defer reloaded_scene_runtime.deinit();
    try std.testing.expectEqual(runtime.worldEpoch() + 1, reloaded_scene_runtime.worldEpoch());

    const start = try runtime.onStart(&generation);
    try std.testing.expectEqual(@as(usize, 3), start.object_count);
    try std.testing.expectApproxEqAbs(@as(f64, 1), start.deltas[1][0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0), start.deltas[1][1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 1), start.deltas[2][0], 0.0001);

    try generation.applyTranslationDeltas(start.slice());
    try runtime.runFixed(&generation, 0.5, .{ .move_x = 1, .move_y = -1 });
    try std.testing.expectApproxEqAbs(@as(f32, 32), (try generation.objectPosition(1))[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 44), (try generation.objectPosition(1))[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 5), (try generation.objectPosition(2))[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 10), (try generation.objectPosition(2))[1], 0.0001);
    try runtime.runFixed(&generation, 0.5, .{});
    try std.testing.expectApproxEqAbs(@as(f32, 39), (try generation.objectPosition(1))[1], 0.0001);
    const before_frame_events = (try generation.objectPosition(2))[0];
    try runtime.runUpdate(&generation, 0.25, .{});
    try std.testing.expectApproxEqAbs(before_frame_events, (try generation.objectPosition(2))[0], 0.0001);
    try runtime.finishFrame(&generation, .{});
    try std.testing.expectApproxEqAbs(before_frame_events + 5, (try generation.objectPosition(2))[0], 0.0001);
}

test "Behavior Host discards failed on_start overlay mutations" {
    const manifest_source =
        \\{"schemaVersion":2,"scripts":[
        \\{"scriptId":1,"source":"scripts/first.luau"},
        \\{"scriptId":2,"source":"scripts/failing.luau"}]}
    ;
    const first_source =
        \\return { on_start = function(self: Kadath.Object) self:translate(5, 0) end }
    ;
    const failing_source =
        \\return { on_start = function(self: Kadath.Object) self:translate(7, 0) error("injected failure") end }
    ;
    const failing_scene_source =
        \\{"schemaVersion":5,"textures":[{"textureId":1,"artifact":"assets/renderer2d/test.texture"}],"objects":[
        \\{"objectId":"goal","kind":"goal","transform":{"position":[10,20]},"sprite":{"size":[3,4],"color":[1,1,1,1],"textureId":1},"behaviors":[]},
        \\{"objectId":"hazard-1","kind":"patrol_hazard","transform":{"position":[30,40]},"sprite":{"size":[5,6],"color":[1,0,0,1],"textureId":1},"behaviors":[{"scriptId":1,"parameters":{}}]},
        \\{"objectId":"player","kind":"player","transform":{"position":[1,2]},"sprite":{"size":[8,9],"color":[1,1,1,1],"textureId":1},"player":{"moveSpeed":10},"behaviors":[{"scriptId":1,"parameters":{}},{"scriptId":2,"parameters":{}}]}]}
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "scripts", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "scripts/first.luau", .data = first_source });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "scripts/failing.luau", .data = failing_source });
    var snapshot = try manifest.loadSnapshot(std.testing.io, std.testing.allocator, tmp.dir, manifest_source);
    defer snapshot.deinit();
    var diagnostic = builder.Diagnostic{};
    var built = try builder.build(std.testing.allocator, &snapshot, &diagnostic);
    defer built.deinit();

    const scene = try scene_api.parse(std.testing.allocator, failing_scene_source);
    var generation = try scene_generation_api.SceneGeneration.prepare(scene, .{ .width = 1024, .height = 720 });
    defer generation.deinit();
    var runtime = try behavior_host.initArtifact(std.testing.allocator, built.bytes, &scene);
    defer runtime.deinit();
    const before = try generation.objectPosition(2);

    try std.testing.expectError(error.BehaviorHookFailed, runtime.onStart(&generation));
    try std.testing.expectEqual(before, try generation.objectPosition(2));
}

test "Behavior Host schedules zero one or many fixed hooks and exactly one update" {
    const scheduling_manifest =
        \\{"schemaVersion":2,"scripts":[
        \\{"scriptId":1,"source":"scripts/scheduling.luau"},
        \\{"scriptId":99,"source":"scripts/no-op.luau"}]}
    ;
    const scheduling_source =
        \\--!strict
        \\return {
        \\    fixed_update = function(self: Kadath.Object, dt: number)
        \\        self:translate(1 + dt - dt, 0)
        \\    end,
        \\    update = function(self: Kadath.Object, dt: number)
        \\        self:translate(0, 1 + dt - dt)
        \\    end,
        \\}
    ;
    const scheduling_scene =
        \\{"schemaVersion":5,"textures":[{"textureId":1,"artifact":"assets/renderer2d/test.texture"}],"objects":[
        \\{"objectId":"goal","kind":"goal","transform":{"position":[10,20]},"sprite":{"size":[3,4],"color":[1,1,1,1],"textureId":1},"behaviors":[]},
        \\{"objectId":"hazard-1","kind":"patrol_hazard","transform":{"position":[30,40]},"sprite":{"size":[5,6],"color":[1,0,0,1],"textureId":1},"behaviors":[{"scriptId":99,"parameters":{}}]},
        \\{"objectId":"player","kind":"player","transform":{"position":[1,2]},"sprite":{"size":[8,9],"color":[1,1,1,1],"textureId":1},"player":{"moveSpeed":10},"behaviors":[{"scriptId":1,"parameters":{}}]}]}
    ;

    for ([_]usize{ 0, 1, 4 }) |fixed_count| {
        var fixture = try makeRuntimeFixture(
            scheduling_manifest,
            &.{
                .{ .path = "scripts/scheduling.luau", .source = scheduling_source },
                .{ .path = "scripts/no-op.luau", .source = no_op_source },
            },
            scheduling_scene,
        );
        defer fixture.deinit();

        for (0..fixed_count) |_| try fixture.runtime.runFixed(&fixture.generation, 1.0 / 60.0, .{});
        try fixture.runtime.runUpdate(&fixture.generation, 0.25, .{});

        const position = try fixture.generation.objectPosition(2);
        try std.testing.expectApproxEqAbs(@as(f32, 1 + @as(f32, @floatFromInt(fixed_count))), position[0], 0.0001);
        try std.testing.expectApproxEqAbs(@as(f32, 3), position[1], 0.0001);
    }
}

test "later Behavior Binding observes earlier live cross-object mutations" {
    const live_manifest =
        \\{"schemaVersion":2,"scripts":[
        \\{"scriptId":1,"source":"scripts/writer.luau"},
        \\{"scriptId":2,"source":"scripts/observer.luau"},
        \\{"scriptId":99,"source":"scripts/no-op.luau"}]}
    ;
    const writer_source =
        \\--!strict
        \\return { fixed_update = function(self: Kadath.Object, dt: number)
        \\    local goal = kadath.scene.find("goal")
        \\    if not goal then error("missing goal") end
        \\    self:translate(1 + dt - dt, 0)
        \\    goal:translate(4, 0)
        \\end }
    ;
    const observer_source =
        \\--!strict
        \\return { fixed_update = function(self: Kadath.Object, dt: number)
        \\    local goal = kadath.scene.find("goal")
        \\    if not goal then error("missing goal") end
        \\    local self_position = self:position()
        \\    local goal_position = goal:position()
        \\    if self_position.x ~= 2 or goal_position.x ~= 14 then error("mutation was not live") end
        \\    self:translate(goal_position.x + dt - dt, 0)
        \\end }
    ;
    const live_scene =
        \\{"schemaVersion":5,"textures":[{"textureId":1,"artifact":"assets/renderer2d/test.texture"}],"objects":[
        \\{"objectId":"goal","kind":"goal","transform":{"position":[10,20]},"sprite":{"size":[3,4],"color":[1,1,1,1],"textureId":1},"behaviors":[]},
        \\{"objectId":"hazard-1","kind":"patrol_hazard","transform":{"position":[30,40]},"sprite":{"size":[5,6],"color":[1,0,0,1],"textureId":1},"behaviors":[{"scriptId":99,"parameters":{}}]},
        \\{"objectId":"player","kind":"player","transform":{"position":[1,2]},"sprite":{"size":[8,9],"color":[1,1,1,1],"textureId":1},"player":{"moveSpeed":10},"behaviors":[{"scriptId":1,"parameters":{}},{"scriptId":2,"parameters":{}}]}]}
    ;
    var fixture = try makeRuntimeFixture(
        live_manifest,
        &.{
            .{ .path = "scripts/writer.luau", .source = writer_source },
            .{ .path = "scripts/observer.luau", .source = observer_source },
            .{ .path = "scripts/no-op.luau", .source = no_op_source },
        },
        live_scene,
    );
    defer fixture.deinit();

    try fixture.runtime.runFixed(&fixture.generation, 1.0 / 60.0, .{});
    try std.testing.expectApproxEqAbs(@as(f32, 16), (try fixture.generation.objectPosition(2))[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 14), (try fixture.generation.objectPosition(0))[0], 0.0001);
}

test "failed active Binding keeps prior writes and isolates later hooks" {
    const failure_manifest =
        \\{"schemaVersion":2,"scripts":[
        \\{"scriptId":1,"source":"scripts/failing.luau"},
        \\{"scriptId":2,"source":"scripts/healthy.luau"},
        \\{"scriptId":99,"source":"scripts/no-op.luau"}]}
    ;
    const failing_source =
        \\--!strict
        \\return { fixed_update = function(self: Kadath.Object, dt: number)
        \\    self:translate(3 + dt - dt, 0)
        \\    error("injected failure")
        \\end }
    ;
    const healthy_source =
        \\--!strict
        \\return { fixed_update = function(self: Kadath.Object, dt: number)
        \\    self:translate(5 + dt - dt, 0)
        \\end }
    ;
    const failure_scene =
        \\{"schemaVersion":5,"textures":[{"textureId":1,"artifact":"assets/renderer2d/test.texture"}],"objects":[
        \\{"objectId":"goal","kind":"goal","transform":{"position":[10,20]},"sprite":{"size":[3,4],"color":[1,1,1,1],"textureId":1},"behaviors":[]},
        \\{"objectId":"hazard-1","kind":"patrol_hazard","transform":{"position":[30,40]},"sprite":{"size":[5,6],"color":[1,0,0,1],"textureId":1},"behaviors":[{"scriptId":99,"parameters":{}}]},
        \\{"objectId":"player","kind":"player","transform":{"position":[1,2]},"sprite":{"size":[8,9],"color":[1,1,1,1],"textureId":1},"player":{"moveSpeed":10},"behaviors":[{"scriptId":1,"parameters":{}},{"scriptId":2,"parameters":{}}]}]}
    ;
    var fixture = try makeRuntimeFixture(
        failure_manifest,
        &.{
            .{ .path = "scripts/failing.luau", .source = failing_source },
            .{ .path = "scripts/healthy.luau", .source = healthy_source },
            .{ .path = "scripts/no-op.luau", .source = no_op_source },
        },
        failure_scene,
    );
    defer fixture.deinit();

    try fixture.runtime.runFixed(&fixture.generation, 1.0 / 60.0, .{});
    try std.testing.expectApproxEqAbs(@as(f32, 9), (try fixture.generation.objectPosition(2))[0], 0.0001);
    try std.testing.expect(!fixture.runtime.active.?.bindingEnabled(1));
    try std.testing.expect(fixture.runtime.active.?.bindingEnabled(2));

    try fixture.runtime.runFixed(&fixture.generation, 1.0 / 60.0, .{});
    try std.testing.expectApproxEqAbs(@as(f32, 14), (try fixture.generation.objectPosition(2))[0], 0.0001);
}

test "contact events are directed and deliver end before begin" {
    const contact_manifest =
        \\{"schemaVersion":2,"scripts":[{"scriptId":1,"source":"scripts/contact-recorder.luau"}]}
    ;
    const contact_source =
        \\--!strict
        \\local sequence = 0
        \\return { on_event = function(self: Kadath.Object, event: Kadath.Event)
        \\    if event.name == "contact_end" then
        \\        sequence = sequence * 10 + 1
        \\    elseif event.name == "contact_begin" then
        \\        sequence = sequence * 10 + 2
        \\    else
        \\        return
        \\    end
        \\    local position = self:position()
        \\    self:set_position(sequence, position.y)
        \\end }
    ;
    const contact_scene =
        \\{"schemaVersion":5,"textures":[{"textureId":1,"artifact":"assets/renderer2d/test.texture"}],"objects":[
        \\{"objectId":"goal","kind":"goal","transform":{"position":[10,20]},"sprite":{"size":[3,4],"color":[1,1,1,1],"textureId":1},"behaviors":[]},
        \\{"objectId":"hazard-1","kind":"patrol_hazard","transform":{"position":[30,40]},"sprite":{"size":[5,6],"color":[1,0,0,1],"textureId":1},"behaviors":[{"scriptId":1,"parameters":{}}]},
        \\{"objectId":"player","kind":"player","transform":{"position":[1,2]},"sprite":{"size":[8,9],"color":[1,1,1,1],"textureId":1},"player":{"moveSpeed":10},"behaviors":[{"scriptId":1,"parameters":{}}]}]}
    ;
    var fixture = try makeRuntimeFixture(
        contact_manifest,
        &.{.{ .path = "scripts/contact-recorder.luau", .source = contact_source }},
        contact_scene,
    );
    defer fixture.deinit();

    const touching_hazard = [_]bool{ false, true, false };
    try fixture.runtime.finishFixedStep(&fixture.generation, &touching_hazard, .{});
    try std.testing.expectApproxEqAbs(@as(f32, 2), (try fixture.generation.objectPosition(1))[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 2), (try fixture.generation.objectPosition(2))[0], 0.0001);

    const touching_goal = [_]bool{ true, false, false };
    try fixture.runtime.finishFixedStep(&fixture.generation, &touching_goal, .{});
    try std.testing.expectApproxEqAbs(@as(f32, 21), (try fixture.generation.objectPosition(1))[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 212), (try fixture.generation.objectPosition(2))[0], 0.0001);
}

test "event overflow disables only the producer and drains accepted events" {
    const overflow_manifest =
        \\{"schemaVersion":2,"scripts":[
        \\{"scriptId":1,"source":"scripts/overflow.luau"},
        \\{"scriptId":2,"source":"scripts/receiver.luau"},
        \\{"scriptId":99,"source":"scripts/no-op.luau"}]}
    ;
    const overflow_source =
        \\--!strict
        \\return { update = function(self: Kadath.Object, dt: number)
        \\    for index = 1, 65 do kadath.event.post(self, "accepted") end
        \\end }
    ;
    const receiver_source =
        \\--!strict
        \\return {
        \\    update = function(self: Kadath.Object, dt: number) self:translate(5 + dt - dt, 0) end,
        \\    on_event = function(self: Kadath.Object, event: Kadath.Event)
        \\        if event.name == "accepted" then self:translate(1, 0) end
        \\    end,
        \\}
    ;
    const overflow_scene =
        \\{"schemaVersion":5,"textures":[{"textureId":1,"artifact":"assets/renderer2d/test.texture"}],"objects":[
        \\{"objectId":"goal","kind":"goal","transform":{"position":[10,20]},"sprite":{"size":[3,4],"color":[1,1,1,1],"textureId":1},"behaviors":[]},
        \\{"objectId":"hazard-1","kind":"patrol_hazard","transform":{"position":[30,40]},"sprite":{"size":[5,6],"color":[1,0,0,1],"textureId":1},"behaviors":[{"scriptId":99,"parameters":{}}]},
        \\{"objectId":"player","kind":"player","transform":{"position":[1,2]},"sprite":{"size":[8,9],"color":[1,1,1,1],"textureId":1},"player":{"moveSpeed":10},"behaviors":[{"scriptId":1,"parameters":{}},{"scriptId":2,"parameters":{}}]}]}
    ;
    var fixture = try makeRuntimeFixture(
        overflow_manifest,
        &.{
            .{ .path = "scripts/overflow.luau", .source = overflow_source },
            .{ .path = "scripts/receiver.luau", .source = receiver_source },
            .{ .path = "scripts/no-op.luau", .source = no_op_source },
        },
        overflow_scene,
    );
    defer fixture.deinit();

    try fixture.runtime.runUpdate(&fixture.generation, 0.25, .{});
    try std.testing.expect(!fixture.runtime.active.?.bindingEnabled(1));
    try std.testing.expect(fixture.runtime.active.?.bindingEnabled(2));
    try fixture.runtime.finishFrame(&fixture.generation, .{});
    try std.testing.expectEqual(@as(usize, 0), fixture.runtime.active.?.failureSlice().len);
    try std.testing.expectApproxEqAbs(@as(f32, 70), (try fixture.generation.objectPosition(2))[0], 0.0001);

    try fixture.runtime.runUpdate(&fixture.generation, 0.25, .{});
    try fixture.runtime.finishFrame(&fixture.generation, .{});
    try std.testing.expectApproxEqAbs(@as(f32, 75), (try fixture.generation.objectPosition(2))[0], 0.0001);
}

test "failed event handler keeps prior writes and later handlers continue" {
    const handler_manifest =
        \\{"schemaVersion":2,"scripts":[
        \\{"scriptId":1,"source":"scripts/poster.luau"},
        \\{"scriptId":2,"source":"scripts/failing-handler.luau"},
        \\{"scriptId":3,"source":"scripts/healthy-handler.luau"},
        \\{"scriptId":99,"source":"scripts/no-op.luau"}]}
    ;
    const poster_source =
        \\--!strict
        \\return { update = function(self: Kadath.Object, dt: number) kadath.event.post(self, "dispatch") end }
    ;
    const failing_handler_source =
        \\--!strict
        \\return { on_event = function(self: Kadath.Object, event: Kadath.Event)
        \\    if event.name == "dispatch" then self:translate(3, 0) error("injected handler failure") end
        \\end }
    ;
    const healthy_handler_source =
        \\--!strict
        \\return { on_event = function(self: Kadath.Object, event: Kadath.Event)
        \\    if event.name == "dispatch" then self:translate(5, 0) end
        \\end }
    ;
    const handler_scene =
        \\{"schemaVersion":5,"textures":[{"textureId":1,"artifact":"assets/renderer2d/test.texture"}],"objects":[
        \\{"objectId":"goal","kind":"goal","transform":{"position":[10,20]},"sprite":{"size":[3,4],"color":[1,1,1,1],"textureId":1},"behaviors":[]},
        \\{"objectId":"hazard-1","kind":"patrol_hazard","transform":{"position":[30,40]},"sprite":{"size":[5,6],"color":[1,0,0,1],"textureId":1},"behaviors":[{"scriptId":99,"parameters":{}}]},
        \\{"objectId":"player","kind":"player","transform":{"position":[1,2]},"sprite":{"size":[8,9],"color":[1,1,1,1],"textureId":1},"player":{"moveSpeed":10},"behaviors":[{"scriptId":1,"parameters":{}},{"scriptId":2,"parameters":{}},{"scriptId":3,"parameters":{}}]}]}
    ;
    var fixture = try makeRuntimeFixture(
        handler_manifest,
        &.{
            .{ .path = "scripts/poster.luau", .source = poster_source },
            .{ .path = "scripts/failing-handler.luau", .source = failing_handler_source },
            .{ .path = "scripts/healthy-handler.luau", .source = healthy_handler_source },
            .{ .path = "scripts/no-op.luau", .source = no_op_source },
        },
        handler_scene,
    );
    defer fixture.deinit();

    try fixture.runtime.runUpdate(&fixture.generation, 0.25, .{});
    try fixture.runtime.finishFrame(&fixture.generation, .{});
    try std.testing.expectApproxEqAbs(@as(f32, 9), (try fixture.generation.objectPosition(2))[0], 0.0001);
    try std.testing.expectEqual(@as(usize, 1), fixture.runtime.active.?.failureSlice().len);
    try std.testing.expect(!fixture.runtime.active.?.bindingEnabled(2));
    try std.testing.expect(fixture.runtime.active.?.bindingEnabled(3));

    try fixture.runtime.runUpdate(&fixture.generation, 0.25, .{});
    try fixture.runtime.finishFrame(&fixture.generation, .{});
    try std.testing.expectApproxEqAbs(@as(f32, 14), (try fixture.generation.objectPosition(2))[0], 0.0001);
}

test "stale queued target is dropped without disabling its producer" {
    const stale_manifest =
        \\{"schemaVersion":2,"scripts":[
        \\{"scriptId":1,"source":"scripts/post-to-goal.luau"},
        \\{"scriptId":99,"source":"scripts/no-op.luau"}]}
    ;
    const stale_source =
        \\--!strict
        \\return { update = function(self: Kadath.Object, dt: number)
        \\    local goal = kadath.scene.find("goal")
        \\    if not goal then error("missing goal") end
        \\    kadath.event.post(goal, "stale-after-reload")
        \\end }
    ;
    const stale_scene =
        \\{"schemaVersion":5,"textures":[{"textureId":1,"artifact":"assets/renderer2d/test.texture"}],"objects":[
        \\{"objectId":"goal","kind":"goal","transform":{"position":[10,20]},"sprite":{"size":[3,4],"color":[1,1,1,1],"textureId":1},"behaviors":[]},
        \\{"objectId":"hazard-1","kind":"patrol_hazard","transform":{"position":[30,40]},"sprite":{"size":[5,6],"color":[1,0,0,1],"textureId":1},"behaviors":[{"scriptId":99,"parameters":{}}]},
        \\{"objectId":"player","kind":"player","transform":{"position":[1,2]},"sprite":{"size":[8,9],"color":[1,1,1,1],"textureId":1},"player":{"moveSpeed":10},"behaviors":[{"scriptId":1,"parameters":{}}]}]}
    ;
    var fixture = try makeRuntimeFixture(
        stale_manifest,
        &.{
            .{ .path = "scripts/post-to-goal.luau", .source = stale_source },
            .{ .path = "scripts/no-op.luau", .source = no_op_source },
        },
        stale_scene,
    );
    defer fixture.deinit();

    try fixture.runtime.runUpdate(&fixture.generation, 0.25, .{});
    fixture.runtime.world_epoch += 1;
    try fixture.runtime.finishFrame(&fixture.generation, .{});
    try std.testing.expect(fixture.runtime.active.?.bindingEnabled(1));
}

test "saved ObjectRef follows restart replacement and rejects a new world epoch" {
    const identity_manifest =
        \\{"schemaVersion":2,"scripts":[
        \\{"scriptId":1,"source":"scripts/identity.luau"},
        \\{"scriptId":99,"source":"scripts/no-op.luau"}]}
    ;
    const identity_source =
        \\--!strict
        \\local saved: Kadath.Object? = nil
        \\return {
        \\    on_start = function(self: Kadath.Object) saved = self end,
        \\    update = function(self: Kadath.Object, dt: number)
        \\        local object = saved
        \\        if not object then error("missing saved ObjectRef") end
        \\        object:translate(2 + dt - dt, 0)
        \\    end,
        \\}
    ;
    const identity_scene =
        \\{"schemaVersion":5,"textures":[{"textureId":1,"artifact":"assets/renderer2d/test.texture"}],"objects":[
        \\{"objectId":"goal","kind":"goal","transform":{"position":[10,20]},"sprite":{"size":[3,4],"color":[1,1,1,1],"textureId":1},"behaviors":[]},
        \\{"objectId":"hazard-1","kind":"patrol_hazard","transform":{"position":[30,40]},"sprite":{"size":[5,6],"color":[1,0,0,1],"textureId":1},"behaviors":[{"scriptId":99,"parameters":{}}]},
        \\{"objectId":"player","kind":"player","transform":{"position":[1,2]},"sprite":{"size":[8,9],"color":[1,1,1,1],"textureId":1},"player":{"moveSpeed":10},"behaviors":[{"scriptId":1,"parameters":{}}]}]}
    ;
    var fixture = try makeRuntimeFixture(
        identity_manifest,
        &.{
            .{ .path = "scripts/identity.luau", .source = identity_source },
            .{ .path = "scripts/no-op.luau", .source = no_op_source },
        },
        identity_scene,
    );
    defer fixture.deinit();

    const start = try fixture.runtime.onStart(&fixture.generation);
    try fixture.generation.applyTranslationDeltas(start.slice());
    const previous_entity = fixture.generation.playerEntity();
    try fixture.generation.reset();
    try std.testing.expect(previous_entity != fixture.generation.playerEntity());

    try fixture.runtime.runUpdate(&fixture.generation, 0.25, .{});
    try std.testing.expectApproxEqAbs(@as(f32, 3), (try fixture.generation.objectPosition(2))[0], 0.0001);

    fixture.runtime.world_epoch += 1;
    try fixture.runtime.runUpdate(&fixture.generation, 0.25, .{});
    try std.testing.expectApproxEqAbs(@as(f32, 3), (try fixture.generation.objectPosition(2))[0], 0.0001);
    try std.testing.expect(!fixture.runtime.active.?.bindingEnabled(1));
}
