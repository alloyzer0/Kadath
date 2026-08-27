const std = @import("std");
const behavior_host = @import("behavior_host.zig");
const behavior_host_stub = @import("behavior_host_stub.zig");
const builder = @import("behavior_package_builder");
const gameplay_replay = @import("gameplay_replay");
const gameplay_vertical_slice_fixture = @import("gameplay_vertical_slice_fixture");
const manifest = @import("behavior_manifest");
const scene_api = @import("scene.zig");
const scene_generation_api = @import("scene_generation.zig");
const runtime_core = @import("runtime_core");

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
    var built = builder.build(std.testing.allocator, &snapshot, &diagnostic) catch |err| {
        std.debug.print("Behavior fixture build failed: source={s}, diagnostic={s}\n", .{
            diagnostic.sourceName(),
            diagnostic.message(),
        });
        return err;
    };
    defer built.deinit();

    const scene = try scene_api.parse(std.testing.allocator, runtime_scene_source);
    var generation = try scene_generation_api.SceneGeneration.prepare(&scene, .{ .width = 1024, .height = 720 });
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

test "unsupported Behavior Host stub mirrors the Host v4 scheduling surface" {
    var runtime = behavior_host_stub.Runtime{};
    var generation: scene_generation_api.SceneGeneration = undefined;
    try std.testing.expectError(error.UnsupportedBehaviorRuntime, runtime.onStart(&generation));
    try std.testing.expectError(error.UnsupportedBehaviorRuntime, runtime.runFixed(&generation, 1.0 / 60.0, .{}));
    try std.testing.expectError(error.UnsupportedBehaviorRuntime, runtime.runUpdate(&generation, 0.25, .{}));
    try std.testing.expectError(error.UnsupportedBehaviorRuntime, runtime.settleFixedStructuralBeforeGameplay(&generation));
    try std.testing.expectError(error.UnsupportedBehaviorRuntime, runtime.finishFixedStep(&generation, .{}));
    try std.testing.expectError(error.UnsupportedBehaviorRuntime, runtime.finishFrame(&generation, .{}));
}

test "Runtime object lifecycle activates prototype Behavior and destroys before later callbacks" {
    const lifecycle_manifest =
        \\{"schemaVersion":2,"scripts":[
        \\{"scriptId":1,"source":"scripts/spawner.luau"},
        \\{"scriptId":2,"source":"scripts/orb.luau"}]}
    ;
    const spawner_source =
        \\--!strict
        \\local frame = 0
        \\local orb: Kadath.Object? = nil
        \\return {
        \\    update = function(self: Kadath.Object, dt: number)
        \\        frame += 1
        \\        if frame == 1 then
        \\            local created = kadath.scene.spawn("runtime-orb", 10, 20)
        \\            created:translate(2, 3)
        \\            orb = created
        \\        elseif frame == 3 and orb then
        \\            local current = orb
        \\            current:destroy()
        \\            if current:id() ~= "runtime-0000000000000001" then error("stale id changed") end
        \\        end
        \\    end,
        \\}
    ;
    const orb_source =
        \\--!strict
        \\return {
        \\    on_start = function(self: Kadath.Object) self:translate(5, 0) end,
        \\    update = function(self: Kadath.Object, dt: number) self:translate(1, 0) end,
        \\}
    ;
    const lifecycle_scene =
        \\{"schemaVersion":6,"textures":[{"textureId":1,"artifact":"assets/renderer2d/test.texture"}],"objects":[
        \\{"objectId":"goal","kind":"goal","transform":{"position":[10,20]},"sprite":{"size":[3,4],"color":[1,1,1,1],"textureId":1},"behaviors":[]},
        \\{"objectId":"hazard","kind":"patrol_hazard","transform":{"position":[30,40]},"sprite":{"size":[2,2],"color":[1,1,1,1],"textureId":1},"behaviors":[{"scriptId":2,"parameters":{}}]},
        \\{"objectId":"player","kind":"player","transform":{"position":[1,2]},"sprite":{"size":[8,9],"color":[1,1,1,1],"textureId":1},"player":{"moveSpeed":10},"behaviors":[{"scriptId":1,"parameters":{}}]}],"prototypes":[
        \\{"prototypeId":"runtime-orb","kind":"sprite","sprite":{"size":[2,2],"color":[1,1,1,1],"textureId":1},"behaviors":[{"scriptId":2,"parameters":{}}]}]}
    ;
    var fixture = try makeRuntimeFixture(lifecycle_manifest, &.{
        .{ .path = "scripts/spawner.luau", .source = spawner_source },
        .{ .path = "scripts/orb.luau", .source = orb_source },
    }, lifecycle_scene);
    defer fixture.deinit();

    try fixture.runtime.runUpdate(&fixture.generation, 0.25, .{});
    const pending_index = fixture.generation.objectIndex("runtime-0000000000000001") orelse return error.MissingPendingRuntimeObject;
    try std.testing.expectApproxEqAbs(@as(f32, 12), (try fixture.generation.objectPosition(pending_index))[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 23), (try fixture.generation.objectPosition(pending_index))[1], 0.0001);
    try std.testing.expectEqual(@as(usize, 3), fixture.generation.activeCount());

    try fixture.runtime.finishFrame(&fixture.generation, .{});
    try std.testing.expectEqual(@as(usize, 4), fixture.generation.activeCount());
    try std.testing.expectApproxEqAbs(@as(f32, 17), (try fixture.generation.objectPosition(pending_index))[0], 0.0001);

    try fixture.runtime.runUpdate(&fixture.generation, 0.25, .{});
    try fixture.runtime.finishFrame(&fixture.generation, .{});
    try std.testing.expectApproxEqAbs(@as(f32, 18), (try fixture.generation.objectPosition(pending_index))[0], 0.0001);

    try fixture.runtime.runUpdate(&fixture.generation, 0.25, .{});
    try fixture.runtime.finishFrame(&fixture.generation, .{});
    try std.testing.expect(fixture.generation.objectIndex("runtime-0000000000000001") == null);
    try std.testing.expectEqual(@as(usize, 3), fixture.generation.activeCount());
    try std.testing.expect(fixture.runtime.active.?.bindingEnabled(1));
}

test "failed dynamic on_start rolls back object writes events and structural successors" {
    const manifest_source =
        \\{"schemaVersion":2,"scripts":[
        \\{"scriptId":1,"source":"scripts/spawner.luau"},
        \\{"scriptId":2,"source":"scripts/dirty.luau"},
        \\{"scriptId":3,"source":"scripts/fail.luau"}]}
    ;
    const spawner =
        \\--!strict
        \\local spawned = false
        \\return { update = function(self: Kadath.Object, dt: number)
        \\    if not spawned then kadath.scene.spawn("runtime-orb", 10, 20); spawned = true end
        \\end }
    ;
    const dirty =
        \\--!strict
        \\return { on_start = function(self: Kadath.Object)
        \\    local goal = kadath.scene.find("goal")
        \\    if goal then goal:translate(100, 0); kadath.event.post(goal, "candidate") end
        \\    kadath.scene.spawn("runtime-orb", 30, 40)
        \\end }
    ;
    const failing =
        \\--!strict
        \\return { on_start = function(self: Kadath.Object) error("activation failure") end }
    ;
    const rollback_scene_source =
        \\{"schemaVersion":6,"textures":[{"textureId":1,"artifact":"assets/renderer2d/test.texture"}],"objects":[
        \\{"objectId":"goal","kind":"goal","transform":{"position":[10,20]},"sprite":{"size":[3,4],"color":[1,1,1,1],"textureId":1},"behaviors":[]},
        \\{"objectId":"hazard","kind":"patrol_hazard","transform":{"position":[30,40]},"sprite":{"size":[2,2],"color":[1,1,1,1],"textureId":1},"behaviors":[{"scriptId":2,"parameters":{}}]},
        \\{"objectId":"player","kind":"player","transform":{"position":[1,2]},"sprite":{"size":[8,9],"color":[1,1,1,1],"textureId":1},"player":{"moveSpeed":10},"behaviors":[{"scriptId":1,"parameters":{}}]}],"prototypes":[
        \\{"prototypeId":"runtime-orb","kind":"sprite","sprite":{"size":[2,2],"color":[1,1,1,1],"textureId":1},"behaviors":[{"scriptId":2,"parameters":{}},{"scriptId":3,"parameters":{}}]}]}
    ;
    var fixture = try makeRuntimeFixture(manifest_source, &.{
        .{ .path = "scripts/spawner.luau", .source = spawner },
        .{ .path = "scripts/dirty.luau", .source = dirty },
        .{ .path = "scripts/fail.luau", .source = failing },
    }, rollback_scene_source);
    defer fixture.deinit();

    const goal_before = try fixture.generation.objectPosition(0);
    try fixture.runtime.runUpdate(&fixture.generation, 0.25, .{});
    try fixture.runtime.finishFrame(&fixture.generation, .{});
    try std.testing.expect(fixture.generation.objectIndex("runtime-0000000000000001") == null);
    try std.testing.expect(fixture.generation.objectIndex("runtime-0000000000000002") == null);
    try std.testing.expectEqual(@as(usize, 3), fixture.generation.activeCount());
    try std.testing.expectEqual(goal_before, try fixture.generation.objectPosition(0));
}

test "dynamic on_start spawn then destroy cancels child before activation" {
    const manifest_source =
        \\{"schemaVersion":2,"scripts":[
        \\{"scriptId":1,"source":"scripts/spawner.luau"},
        \\{"scriptId":2,"source":"scripts/parent.luau"},
        \\{"scriptId":3,"source":"scripts/child.luau"}]}
    ;
    const spawner =
        \\--!strict
        \\local spawned = false
        \\return { update = function(self: Kadath.Object, dt: number)
        \\    if not spawned then kadath.scene.spawn("runtime-parent", 10, 20); spawned = true end
        \\end }
    ;
    const parent =
        \\--!strict
        \\return { on_start = function(self: Kadath.Object)
        \\    local child = kadath.scene.spawn("runtime-child", 30, 40)
        \\    child:destroy()
        \\end }
    ;
    const child =
        \\--!strict
        \\return { on_start = function(self: Kadath.Object)
        \\    local goal = kadath.scene.find("goal")
        \\    if goal then goal:translate(100, 0) end
        \\end }
    ;
    const lifecycle_scene =
        \\{"schemaVersion":6,"textures":[{"textureId":1,"artifact":"assets/renderer2d/test.texture"}],"objects":[
        \\{"objectId":"goal","kind":"goal","transform":{"position":[10,20]},"sprite":{"size":[3,4],"color":[1,1,1,1],"textureId":1},"behaviors":[]},
        \\{"objectId":"hazard","kind":"patrol_hazard","transform":{"position":[30,40]},"sprite":{"size":[2,2],"color":[1,1,1,1],"textureId":1},"behaviors":[{"scriptId":3,"parameters":{}}]},
        \\{"objectId":"player","kind":"player","transform":{"position":[1,2]},"sprite":{"size":[8,9],"color":[1,1,1,1],"textureId":1},"player":{"moveSpeed":10},"behaviors":[{"scriptId":1,"parameters":{}}]}],"prototypes":[
        \\{"prototypeId":"runtime-parent","kind":"sprite","sprite":{"size":[2,2],"color":[1,1,1,1],"textureId":1},"behaviors":[{"scriptId":2,"parameters":{}}]},
        \\{"prototypeId":"runtime-child","kind":"sprite","sprite":{"size":[2,2],"color":[1,1,1,1],"textureId":1},"behaviors":[{"scriptId":3,"parameters":{}}]}]}
    ;
    var fixture = try makeRuntimeFixture(manifest_source, &.{
        .{ .path = "scripts/spawner.luau", .source = spawner },
        .{ .path = "scripts/parent.luau", .source = parent },
        .{ .path = "scripts/child.luau", .source = child },
    }, lifecycle_scene);
    defer fixture.deinit();

    const goal_before = try fixture.generation.objectPosition(0);
    try fixture.runtime.runUpdate(&fixture.generation, 0.25, .{});
    try fixture.runtime.finishFrame(&fixture.generation, .{});
    try std.testing.expectEqual(goal_before, try fixture.generation.objectPosition(0));
    try std.testing.expect(fixture.generation.objectIndex("runtime-0000000000000002") == null);
    try std.testing.expectEqual(@as(usize, 4), fixture.generation.activeCount());
}

test "dynamic on_start self destroy skips later bindings and never renders" {
    const manifest_source =
        \\{"schemaVersion":2,"scripts":[
        \\{"scriptId":1,"source":"scripts/spawner.luau"},
        \\{"scriptId":2,"source":"scripts/destroy-self.luau"},
        \\{"scriptId":3,"source":"scripts/after-destroy.luau"}]}
    ;
    const spawner =
        \\--!strict
        \\local spawned = false
        \\return { update = function(self: Kadath.Object, dt: number)
        \\    if not spawned then kadath.scene.spawn("runtime-orb", 10, 20); spawned = true end
        \\end }
    ;
    const destroy_self =
        \\--!strict
        \\return { on_start = function(self: Kadath.Object) self:destroy() end }
    ;
    const after_destroy =
        \\--!strict
        \\return { on_start = function(self: Kadath.Object)
        \\    local goal = kadath.scene.find("goal")
        \\    if goal then goal:translate(1000, 0) end
        \\end }
    ;
    const lifecycle_scene =
        \\{"schemaVersion":6,"textures":[{"textureId":1,"artifact":"assets/renderer2d/test.texture"}],"objects":[
        \\{"objectId":"goal","kind":"goal","transform":{"position":[10,20]},"sprite":{"size":[3,4],"color":[1,1,1,1],"textureId":1},"behaviors":[]},
        \\{"objectId":"hazard","kind":"patrol_hazard","transform":{"position":[30,40]},"sprite":{"size":[2,2],"color":[1,1,1,1],"textureId":1},"behaviors":[{"scriptId":3,"parameters":{}}]},
        \\{"objectId":"player","kind":"player","transform":{"position":[1,2]},"sprite":{"size":[8,9],"color":[1,1,1,1],"textureId":1},"player":{"moveSpeed":10},"behaviors":[{"scriptId":1,"parameters":{}}]}],"prototypes":[
        \\{"prototypeId":"runtime-orb","kind":"sprite","sprite":{"size":[2,2],"color":[1,1,1,1],"textureId":1},"behaviors":[{"scriptId":2,"parameters":{}},{"scriptId":3,"parameters":{}}]}]}
    ;
    var fixture = try makeRuntimeFixture(manifest_source, &.{
        .{ .path = "scripts/spawner.luau", .source = spawner },
        .{ .path = "scripts/destroy-self.luau", .source = destroy_self },
        .{ .path = "scripts/after-destroy.luau", .source = after_destroy },
    }, lifecycle_scene);
    defer fixture.deinit();

    const goal_before = try fixture.generation.objectPosition(0);
    try fixture.runtime.runUpdate(&fixture.generation, 0.25, .{});
    try fixture.runtime.finishFrame(&fixture.generation, .{});
    try std.testing.expectEqual(goal_before, try fixture.generation.objectPosition(0));
    try std.testing.expect(fixture.generation.objectIndex("runtime-0000000000000001") == null);
    try std.testing.expectEqual(@as(usize, 3), fixture.generation.activeCount());
}

test "dynamic on_start destroy hides an existing transient from later activations in the same flush" {
    const manifest_source =
        \\{"schemaVersion":2,"scripts":[
        \\{"scriptId":1,"source":"scripts/spawner.luau"},
        \\{"scriptId":2,"source":"scripts/killer.luau"},
        \\{"scriptId":3,"source":"scripts/observer.luau"}]}
    ;
    const spawner =
        \\--!strict
        \\local frame = 0
        \\return { update = function(self: Kadath.Object, dt: number)
        \\    frame += 1
        \\    if frame == 1 then
        \\        kadath.scene.spawn("runtime-victim", 10, 20)
        \\    elseif frame == 2 then
        \\        kadath.scene.spawn("runtime-killer", 30, 40)
        \\        kadath.scene.spawn("runtime-observer", 50, 60)
        \\    end
        \\end }
    ;
    const killer =
        \\--!strict
        \\return { on_start = function(self: Kadath.Object)
        \\    local victim = kadath.scene.find("runtime-0000000000000001")
        \\    if victim then victim:destroy() end
        \\end }
    ;
    const observer =
        \\--!strict
        \\return { on_start = function(self: Kadath.Object)
        \\    if kadath.scene.find("runtime-0000000000000001") then
        \\        local goal = kadath.scene.find("goal")
        \\        if goal then goal:translate(100, 0) end
        \\    end
        \\end }
    ;
    const lifecycle_scene =
        \\{"schemaVersion":6,"textures":[{"textureId":1,"artifact":"assets/renderer2d/test.texture"}],"objects":[
        \\{"objectId":"goal","kind":"goal","transform":{"position":[10,20]},"sprite":{"size":[3,4],"color":[1,1,1,1],"textureId":1},"behaviors":[]},
        \\{"objectId":"hazard","kind":"patrol_hazard","transform":{"position":[30,40]},"sprite":{"size":[2,2],"color":[1,1,1,1],"textureId":1},"behaviors":[{"scriptId":3,"parameters":{}}]},
        \\{"objectId":"player","kind":"player","transform":{"position":[1,2]},"sprite":{"size":[8,9],"color":[1,1,1,1],"textureId":1},"player":{"moveSpeed":10},"behaviors":[{"scriptId":1,"parameters":{}}]}],"prototypes":[
        \\{"prototypeId":"runtime-victim","kind":"sprite","sprite":{"size":[2,2],"color":[1,1,1,1],"textureId":1},"behaviors":[]},
        \\{"prototypeId":"runtime-killer","kind":"sprite","sprite":{"size":[2,2],"color":[1,1,1,1],"textureId":1},"behaviors":[{"scriptId":2,"parameters":{}}]},
        \\{"prototypeId":"runtime-observer","kind":"sprite","sprite":{"size":[2,2],"color":[1,1,1,1],"textureId":1},"behaviors":[{"scriptId":3,"parameters":{}}]}]}
    ;
    var fixture = try makeRuntimeFixture(manifest_source, &.{
        .{ .path = "scripts/spawner.luau", .source = spawner },
        .{ .path = "scripts/killer.luau", .source = killer },
        .{ .path = "scripts/observer.luau", .source = observer },
    }, lifecycle_scene);
    defer fixture.deinit();

    try fixture.runtime.runUpdate(&fixture.generation, 0.25, .{});
    try fixture.runtime.finishFrame(&fixture.generation, .{});
    try std.testing.expect(fixture.generation.objectIndex("runtime-0000000000000001") != null);

    const goal_before = try fixture.generation.objectPosition(0);
    try fixture.runtime.runUpdate(&fixture.generation, 0.25, .{});
    try fixture.runtime.finishFrame(&fixture.generation, .{});
    try std.testing.expectEqual(goal_before, try fixture.generation.objectPosition(0));
    try std.testing.expect(fixture.generation.objectIndex("runtime-0000000000000001") == null);
}

test "event destroy skips later bindings for the same transient target" {
    const manifest_source =
        \\{"schemaVersion":2,"scripts":[
        \\{"scriptId":1,"source":"scripts/driver.luau"},
        \\{"scriptId":2,"source":"scripts/destroy-on-event.luau"},
        \\{"scriptId":3,"source":"scripts/after-destroy.luau"}]}
    ;
    const driver =
        \\--!strict
        \\local frame = 0
        \\local target: Kadath.Object? = nil
        \\return { update = function(self: Kadath.Object, dt: number)
        \\    frame += 1
        \\    if frame == 1 then
        \\        target = kadath.scene.spawn("runtime-target", 10, 20)
        \\    elseif frame == 2 and target then
        \\        kadath.event.post(target, "destroy")
        \\    end
        \\end }
    ;
    const destroy_on_event =
        \\--!strict
        \\return { on_event = function(self: Kadath.Object, event: Kadath.Event)
        \\    if event.name == "destroy" then self:destroy() end
        \\end }
    ;
    const after_destroy =
        \\--!strict
        \\return { on_event = function(self: Kadath.Object, event: Kadath.Event)
        \\    if event.name == "destroy" then
        \\        local goal = kadath.scene.find("goal")
        \\        if goal then goal:translate(100, 0) end
        \\    end
        \\end }
    ;
    const lifecycle_scene =
        \\{"schemaVersion":6,"textures":[{"textureId":1,"artifact":"assets/renderer2d/test.texture"}],"objects":[
        \\{"objectId":"goal","kind":"goal","transform":{"position":[10,20]},"sprite":{"size":[3,4],"color":[1,1,1,1],"textureId":1},"behaviors":[]},
        \\{"objectId":"hazard","kind":"patrol_hazard","transform":{"position":[30,40]},"sprite":{"size":[2,2],"color":[1,1,1,1],"textureId":1},"behaviors":[{"scriptId":3,"parameters":{}}]},
        \\{"objectId":"player","kind":"player","transform":{"position":[1,2]},"sprite":{"size":[8,9],"color":[1,1,1,1],"textureId":1},"player":{"moveSpeed":10},"behaviors":[{"scriptId":1,"parameters":{}}]}],"prototypes":[
        \\{"prototypeId":"runtime-target","kind":"sprite","sprite":{"size":[2,2],"color":[1,1,1,1],"textureId":1},"behaviors":[{"scriptId":2,"parameters":{}},{"scriptId":3,"parameters":{}}]}]}
    ;
    var fixture = try makeRuntimeFixture(manifest_source, &.{
        .{ .path = "scripts/driver.luau", .source = driver },
        .{ .path = "scripts/destroy-on-event.luau", .source = destroy_on_event },
        .{ .path = "scripts/after-destroy.luau", .source = after_destroy },
    }, lifecycle_scene);
    defer fixture.deinit();

    try fixture.runtime.runUpdate(&fixture.generation, 0.25, .{});
    try fixture.runtime.finishFrame(&fixture.generation, .{});
    const goal_before = try fixture.generation.objectPosition(0);
    try fixture.runtime.runUpdate(&fixture.generation, 0.25, .{});
    try fixture.runtime.finishFrame(&fixture.generation, .{});
    try std.testing.expectEqual(goal_before, try fixture.generation.objectPosition(0));
    try std.testing.expect(fixture.generation.objectIndex("runtime-0000000000000001") == null);
}

test "eighth generation event can enqueue a first generation structural request" {
    const manifest_source =
        \\{"schemaVersion":2,"scripts":[
        \\{"scriptId":1,"source":"scripts/event-chain.luau"},
        \\{"scriptId":99,"source":"scripts/no-op.luau"}]}
    ;
    const event_chain =
        \\--!strict
        \\local started = false
        \\local count = 0
        \\return {
        \\    update = function(self: Kadath.Object, dt: number)
        \\        if not started then started = true; kadath.event.post(self, "chain") end
        \\    end,
        \\    on_event = function(self: Kadath.Object, event: Kadath.Event)
        \\        if event.name ~= "chain" then return end
        \\        count += 1
        \\        if count < 9 then
        \\            kadath.event.post(self, "chain")
        \\        else
        \\            kadath.scene.spawn("runtime-target", 10, 20)
        \\        end
        \\    end,
        \\}
    ;
    const lifecycle_scene =
        \\{"schemaVersion":6,"textures":[{"textureId":1,"artifact":"assets/renderer2d/test.texture"}],"objects":[
        \\{"objectId":"goal","kind":"goal","transform":{"position":[10,20]},"sprite":{"size":[3,4],"color":[1,1,1,1],"textureId":1},"behaviors":[]},
        \\{"objectId":"hazard","kind":"patrol_hazard","transform":{"position":[30,40]},"sprite":{"size":[2,2],"color":[1,1,1,1],"textureId":1},"behaviors":[{"scriptId":99,"parameters":{}}]},
        \\{"objectId":"player","kind":"player","transform":{"position":[1,2]},"sprite":{"size":[8,9],"color":[1,1,1,1],"textureId":1},"player":{"moveSpeed":10},"behaviors":[{"scriptId":1,"parameters":{}}]}],"prototypes":[
        \\{"prototypeId":"runtime-target","kind":"sprite","sprite":{"size":[2,2],"color":[1,1,1,1],"textureId":1},"behaviors":[]}]}
    ;
    var fixture = try makeRuntimeFixture(manifest_source, &.{
        .{ .path = "scripts/event-chain.luau", .source = event_chain },
        .{ .path = "scripts/no-op.luau", .source = no_op_source },
    }, lifecycle_scene);
    defer fixture.deinit();

    try fixture.runtime.runUpdate(&fixture.generation, 0.25, .{});
    try fixture.runtime.finishFrame(&fixture.generation, .{});
    try std.testing.expect(fixture.generation.objectIndex("runtime-0000000000000001") != null);
}

test "candidate on_start rebuilds and updates live transient Behavior state" {
    const manifest_source =
        \\{"schemaVersion":2,"scripts":[
        \\{"scriptId":1,"source":"scripts/spawner.luau"},
        \\{"scriptId":2,"source":"scripts/orb.luau"}]}
    ;
    const spawner =
        \\--!strict
        \\local spawned = false
        \\return { update = function(self: Kadath.Object, dt: number)
        \\    if not spawned then kadath.scene.spawn("runtime-orb", 10, 20); spawned = true end
        \\end }
    ;
    const orb =
        \\--!strict
        \\return { on_start = function(self: Kadath.Object) self:translate(5, 0) end }
    ;
    const reload_scene =
        \\{"schemaVersion":6,"textures":[{"textureId":1,"artifact":"assets/renderer2d/test.texture"}],"objects":[
        \\{"objectId":"goal","kind":"goal","transform":{"position":[10,20]},"sprite":{"size":[3,4],"color":[1,1,1,1],"textureId":1},"behaviors":[]},
        \\{"objectId":"hazard","kind":"patrol_hazard","transform":{"position":[30,40]},"sprite":{"size":[2,2],"color":[1,1,1,1],"textureId":1},"behaviors":[{"scriptId":2,"parameters":{}}]},
        \\{"objectId":"player","kind":"player","transform":{"position":[1,2]},"sprite":{"size":[8,9],"color":[1,1,1,1],"textureId":1},"player":{"moveSpeed":10},"behaviors":[{"scriptId":1,"parameters":{}}]}],"prototypes":[
        \\{"prototypeId":"runtime-orb","kind":"sprite","sprite":{"size":[2,2],"color":[1,1,1,1],"textureId":1},"behaviors":[{"scriptId":2,"parameters":{}}]}]}
    ;
    var fixture = try makeRuntimeFixture(manifest_source, &.{
        .{ .path = "scripts/spawner.luau", .source = spawner },
        .{ .path = "scripts/orb.luau", .source = orb },
    }, reload_scene);
    defer fixture.deinit();
    try fixture.runtime.runUpdate(&fixture.generation, 0.25, .{});
    try fixture.runtime.finishFrame(&fixture.generation, .{});
    const transient_index = fixture.generation.objectIndex("runtime-0000000000000001") orelse return error.MissingTransientRuntimeObject;
    try std.testing.expectApproxEqAbs(@as(f32, 15), (try fixture.generation.objectPosition(transient_index))[0], 0.0001);

    var candidate = try fixture.runtime.cloneForRestart(std.testing.allocator, fixture.generation.scene);
    defer candidate.deinit();
    const batch = try candidate.onStart(&fixture.generation);
    try fixture.generation.applyTranslationDeltas(batch.slice());
    try std.testing.expectApproxEqAbs(@as(f32, 20), (try fixture.generation.objectPosition(transient_index))[0], 0.0001);
    try std.testing.expect(candidate.active.?.containsObject("runtime-0000000000000001"));
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
    var generation = try scene_generation_api.SceneGeneration.prepare(&scene, .{ .width = 1024, .height = 720 });
    defer generation.deinit();
    var runtime = try behavior_host.initArtifact(std.testing.allocator, built.bytes, &scene);
    defer runtime.deinit();

    var restart_runtime = try runtime.cloneForRestart(std.testing.allocator, &scene);
    defer restart_runtime.deinit();
    var reloaded_scene_runtime = try runtime.cloneForSceneReload(std.testing.allocator, &scene);
    defer reloaded_scene_runtime.deinit();
    try std.testing.expectEqual(@as(u64, 1), try generation.worldEpoch());

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
    try runtime.finishFixedStep(&generation, .{});
    try runtime.runFixed(&generation, 0.5, .{});
    try std.testing.expectApproxEqAbs(@as(f32, 39), (try generation.objectPosition(1))[1], 0.0001);
    try runtime.finishFixedStep(&generation, .{});
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
    var generation = try scene_generation_api.SceneGeneration.prepare(&scene, .{ .width = 1024, .height = 720 });
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

        for (0..fixed_count) |_| {
            try fixture.runtime.runFixed(&fixture.generation, 1.0 / 60.0, .{});
            try fixture.runtime.finishFixedStep(&fixture.generation, .{});
        }
        try fixture.runtime.runUpdate(&fixture.generation, 0.25, .{});
        try fixture.runtime.finishFrame(&fixture.generation, .{});

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
    try fixture.runtime.finishFixedStep(&fixture.generation, .{});

    try fixture.runtime.runFixed(&fixture.generation, 1.0 / 60.0, .{});
    try std.testing.expectApproxEqAbs(@as(f32, 14), (try fixture.generation.objectPosition(2))[0], 0.0001);
    try fixture.runtime.finishFixedStep(&fixture.generation, .{});
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

    try fixture.generation.setObjectPosition(2, .{ 30, 40 });
    var outcome: runtime_core.GameplayOutcome = undefined;
    const first = try fixture.generation.beginGameplayFixed(1.0 / 60.0, &outcome);
    try fixture.runtime.runFixed(&fixture.generation, 1.0 / 60.0, .{});
    _ = try fixture.generation.commitGameplayFixed(first.step_token, .{}, &outcome);
    try fixture.runtime.finishFixedStep(&fixture.generation, .{});
    try std.testing.expectApproxEqAbs(@as(f32, 2), (try fixture.generation.objectPosition(1))[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 2), (try fixture.generation.objectPosition(2))[0], 0.0001);

    // Frame phase 使用独立的Core sequence；穿插执行不得影响下一Gameplay step token。
    try fixture.runtime.runUpdate(&fixture.generation, 0.25, .{});
    try fixture.runtime.finishFrame(&fixture.generation, .{});

    try fixture.generation.setObjectPosition(2, .{ 10, 20 });
    const second = try fixture.generation.beginGameplayFixed(1.0 / 60.0, &outcome);
    try fixture.runtime.runFixed(&fixture.generation, 1.0 / 60.0, .{});
    _ = try fixture.generation.commitGameplayFixed(second.step_token, .{}, &outcome);
    try fixture.runtime.finishFixedStep(&fixture.generation, .{});
    try std.testing.expectApproxEqAbs(@as(f32, 21), (try fixture.generation.objectPosition(1))[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 212), (try fixture.generation.objectPosition(2))[0], 0.0001);
    std.debug.print("\nGAMEPLAY_DECISION directed_contact_order covered=4 total=4\n", .{});
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
    std.debug.print("\nGAMEPLAY_DECISION behavior_overflow_isolation covered=5 total=5\n", .{});
}

test "event payload values cross the Core Phase seam without losing type or identity" {
    const payload_manifest =
        \\{"schemaVersion":2,"scripts":[
        \\{"scriptId":1,"source":"scripts/payload.luau"},
        \\{"scriptId":2,"source":"scripts/no-op.luau"}]}
    ;
    const payload_source =
        \\--!strict
        \\local function post_typed(self: Kadath.Object, amount: number)
        \\    local goal = kadath.scene.find("goal")
        \\    if not goal then error("missing goal") end
        \\    local payload = ({
        \\        enabled = true,
        \\        amount = amount,
        \\        label = "phase",
        \\        target = goal,
        \\    } :: any)
        \\    kadath.event.post(self, "typed", payload)
        \\end
        \\return {
        \\    on_start = function(self: Kadath.Object)
        \\        post_typed(self, 4)
        \\    end,
        \\    update = function(self: Kadath.Object, dt: number)
        \\        post_typed(self, 4 + dt - dt)
        \\    end,
        \\    on_event = function(self: Kadath.Object, event: Kadath.Event)
        \\        local payload = event.payload :: any
        \\        if event.name == "typed" and
        \\            payload["enabled"] == true and
        \\            payload["amount"] == 4 and
        \\            payload["label"] == "phase" and
        \\            payload["target"]:id() == "goal" then
        \\            self:translate(7, 0)
        \\        end
        \\    end,
        \\}
    ;
    const payload_scene =
        \\{"schemaVersion":5,"textures":[{"textureId":1,"artifact":"assets/renderer2d/test.texture"}],"objects":[
        \\{"objectId":"goal","kind":"goal","transform":{"position":[10,20]},"sprite":{"size":[3,4],"color":[1,1,1,1],"textureId":1},"behaviors":[]},
        \\{"objectId":"player","kind":"player","transform":{"position":[1,2]},"sprite":{"size":[8,9],"color":[1,1,1,1],"textureId":1},"player":{"moveSpeed":10},"behaviors":[{"scriptId":1,"parameters":{}}]},
        \\{"objectId":"hazard-1","kind":"patrol_hazard","transform":{"position":[30,40]},"sprite":{"size":[5,6],"color":[1,0,0,1],"textureId":1},"behaviors":[{"scriptId":2,"parameters":{}}]}]}
    ;
    var fixture = try makeRuntimeFixture(
        payload_manifest,
        &.{
            .{ .path = "scripts/payload.luau", .source = payload_source },
            .{ .path = "scripts/no-op.luau", .source = no_op_source },
        },
        payload_scene,
    );
    defer fixture.deinit();

    const start = try fixture.runtime.onStart(&fixture.generation);
    try fixture.generation.applyTranslationDeltas(start.slice());
    try fixture.runtime.publishStartupEvents(&fixture.generation, &start);
    try fixture.runtime.runUpdate(&fixture.generation, 0.25, .{});
    try fixture.runtime.finishFrame(&fixture.generation, .{});
    try std.testing.expectApproxEqAbs(@as(f32, 15), (try fixture.generation.objectPosition(1))[0], 0.0001);
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
    try fixture.runtime.finishFrame(&fixture.generation, .{});
    var replacement = try scene_generation_api.SceneGeneration.prepareSceneReload(
        fixture.generation.scene,
        fixture.generation.extent,
        &fixture.generation,
    );
    replacement.commitPrepared(&fixture.generation) catch |err| {
        replacement.deinit();
        return err;
    };
    var previous_generation = fixture.generation;
    fixture.generation = replacement;
    previous_generation.deinit();
    try std.testing.expectEqual(@as(u64, 2), try fixture.generation.worldEpoch());
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
    var restart_outcome: runtime_core.GameplayOutcome = undefined;
    const terminal = try fixture.generation.beginGameplayFixed(3.0, &restart_outcome);
    try fixture.generation.core.abortGameplayFixed(terminal.step_token);
    try fixture.generation.reset();
    try std.testing.expect(previous_entity != fixture.generation.playerEntity());

    try fixture.runtime.runUpdate(&fixture.generation, 0.25, .{});
    try std.testing.expectApproxEqAbs(@as(f32, 3), (try fixture.generation.objectPosition(2))[0], 0.0001);
    try fixture.runtime.finishFrame(&fixture.generation, .{});

    var replacement = try scene_generation_api.SceneGeneration.prepareSceneReload(
        fixture.generation.scene,
        fixture.generation.extent,
        &fixture.generation,
    );
    replacement.commitPrepared(&fixture.generation) catch |err| {
        replacement.deinit();
        return err;
    };
    var previous_generation = fixture.generation;
    fixture.generation = replacement;
    previous_generation.deinit();
    try std.testing.expectEqual(@as(u64, 2), try fixture.generation.worldEpoch());
    try fixture.runtime.runUpdate(&fixture.generation, 0.25, .{});
    try std.testing.expectApproxEqAbs(@as(f32, 1), (try fixture.generation.objectPosition(2))[0], 0.0001);
    try std.testing.expect(!fixture.runtime.active.?.bindingEnabled(1));
}

const vertical_slice_manifest = gameplay_vertical_slice_fixture.manifest;
const vertical_slice_player_source = gameplay_vertical_slice_fixture.player_source;
const vertical_slice_no_op_source = gameplay_vertical_slice_fixture.no_op_source;
const vertical_slice_scene = gameplay_vertical_slice_fixture.initial_scene;
const vertical_slice_reload_scene = gameplay_vertical_slice_fixture.reload_scene;

const InitialVerticalEvidence = struct {
    digest: gameplay_replay.Digest,
    first_outcome: runtime_core.GameplayOutcome,
    final_snapshot: runtime_core.GameplaySnapshot,
    player_position: [2]f32,
    probe_position: [2]f32,
};

const VerticalStepEvidence = struct {
    outcome: ?runtime_core.GameplayOutcome,
    snapshot: runtime_core.GameplaySnapshot,
};

fn runVerticalFixedStep(
    fixture: *RuntimeFixture,
    requested: behavior_host.InputSnapshot,
    recorder: *gameplay_replay.Recorder,
) !VerticalStepEvidence {
    var outcome = std.mem.zeroes(runtime_core.GameplayOutcome);
    const begin = try fixture.generation.beginGameplayFixed(1.0 / 60.0, &outcome);
    recorder.recordStep(.begin, &begin);
    var published_outcome: ?runtime_core.GameplayOutcome = null;
    if (begin.outcome_count == 1) {
        recorder.recordOutcome(&outcome);
        published_outcome = outcome;
    }
    const routed = if (begin.accepts_input != 0) requested else behavior_host.InputSnapshot{};
    try fixture.runtime.runFixed(&fixture.generation, 1.0 / 60.0, routed);
    try fixture.runtime.settleFixedStructuralBeforeGameplay(&fixture.generation);
    const committed = try fixture.generation.commitGameplayFixed(begin.step_token, .{}, &outcome);
    recorder.recordStep(.commit, &committed);
    if (committed.outcome_count == 1) {
        recorder.recordOutcome(&outcome);
        published_outcome = outcome;
    }
    try fixture.runtime.finishFixedStep(&fixture.generation, routed);
    var render_items: [runtime_core.max_object_count]runtime_core.RenderSprite = undefined;
    const publication = try fixture.generation.extractSprites(&render_items);
    recorder.recordSnapshot(&publication.snapshot, publication.sprites);
    return .{ .outcome = published_outcome, .snapshot = publication.snapshot };
}

fn startVerticalRuntime(fixture: *RuntimeFixture) !void {
    const startup = try fixture.runtime.onStart(&fixture.generation);
    try fixture.generation.applyTranslationDeltas(startup.slice());
    try fixture.runtime.publishStartupEvents(&fixture.generation, &startup);
}

fn recordVerticalSnapshot(
    fixture: *RuntimeFixture,
    recorder: *gameplay_replay.Recorder,
) !runtime_core.GameplaySnapshot {
    var render_items: [runtime_core.max_object_count]runtime_core.RenderSprite = undefined;
    const publication = try fixture.generation.extractSprites(&render_items);
    recorder.recordSnapshot(&publication.snapshot, publication.sprites);
    return publication.snapshot;
}

fn restartVerticalFixture(fixture: *RuntimeFixture) !void {
    var replacement = try scene_generation_api.SceneGeneration.prepareRestart(
        fixture.generation.scene,
        fixture.generation.extent,
        &fixture.generation,
    );
    var transferred = false;
    errdefer if (!transferred) replacement.deinit();
    var candidate = try fixture.runtime.cloneForRestart(std.testing.allocator, fixture.generation.scene);
    errdefer if (!transferred) candidate.deinit();
    const startup = try candidate.onStart(&replacement);
    try replacement.applyTranslationDeltas(startup.slice());
    try candidate.preparePhaseState(&replacement);
    try candidate.commitPhaseState(&replacement);
    try replacement.commitPrepared(&fixture.generation);

    var previous_generation = fixture.generation;
    var previous_runtime = fixture.runtime;
    fixture.generation = replacement;
    fixture.runtime = candidate;
    transferred = true;
    previous_generation.deinit();
    previous_runtime.deinit();
    try fixture.runtime.publishStartupEvents(&fixture.generation, &startup);
}

fn reloadVerticalFixture(fixture: *RuntimeFixture) !void {
    const reload_scene = try scene_api.parse(std.testing.allocator, vertical_slice_reload_scene);
    var replacement = try scene_generation_api.SceneGeneration.prepareSceneReload(
        &reload_scene,
        fixture.generation.extent,
        &fixture.generation,
    );
    var transferred = false;
    errdefer if (!transferred) replacement.deinit();
    var candidate = try fixture.runtime.cloneForSceneReload(std.testing.allocator, &reload_scene);
    errdefer if (!transferred) candidate.deinit();
    const startup = try candidate.onStart(&replacement);
    try replacement.applyTranslationDeltas(startup.slice());
    try candidate.preparePhaseState(&replacement);
    try candidate.commitPhaseState(&replacement);
    try replacement.commitPrepared(&fixture.generation);

    var previous_generation = fixture.generation;
    var previous_runtime = fixture.runtime;
    fixture.generation = replacement;
    fixture.runtime = candidate;
    transferred = true;
    previous_generation.deinit();
    previous_runtime.deinit();
    try fixture.runtime.publishStartupEvents(&fixture.generation, &startup);
}

fn runInitialVerticalSlice(first_move_y: i8) !InitialVerticalEvidence {
    var fixture = try makeRuntimeFixture(
        vertical_slice_manifest,
        &.{
            .{ .path = "scripts/vertical-player.luau", .source = vertical_slice_player_source },
            .{ .path = "scripts/no-op.luau", .source = vertical_slice_no_op_source },
        },
        vertical_slice_scene,
    );
    defer fixture.deinit();

    try startVerticalRuntime(&fixture);

    var recorder = gameplay_replay.Recorder.init();
    var render_items: [runtime_core.max_object_count]runtime_core.RenderSprite = undefined;
    var publication = try fixture.generation.extractSprites(&render_items);
    recorder.recordSnapshot(&publication.snapshot, publication.sprites);

    var first_outcome: ?runtime_core.GameplayOutcome = null;
    const requested_inputs = [_]behavior_host.InputSnapshot{
        .{ .move_y = first_move_y },
        .{},
        // 终态后的这个输入必须由 Host 路由规则抑制，Behavior 只收到零输入。
        .{ .move_y = 1 },
    };
    for (requested_inputs) |requested| {
        const step = try runVerticalFixedStep(&fixture, requested, &recorder);
        if (first_outcome == null) first_outcome = step.outcome;
        publication.snapshot = step.snapshot;
    }

    const player_index = fixture.generation.objectIndex("player") orelse return error.MissingVerticalPlayer;
    const probe_index = fixture.generation.objectIndex("phase-probe") orelse return error.MissingVerticalProbe;
    return .{
        .digest = recorder.finish(),
        .first_outcome = first_outcome orelse return error.MissingVerticalOutcome,
        .final_snapshot = publication.snapshot,
        .player_position = try fixture.generation.objectPosition(player_index),
        .probe_position = try fixture.generation.objectPosition(probe_index),
    };
}

const FullVerticalEvidence = struct {
    digest: gameplay_replay.Digest,
    initial_world_epoch: u64,
    initial_player_entity: runtime_core.EntityId,
    restart_world_epoch: u64,
    restart_player_entity: runtime_core.EntityId,
    restart_snapshot: runtime_core.GameplaySnapshot,
    restart_probe_position: [2]f32,
    restart_outcome: runtime_core.GameplayOutcome,
    reload_world_epoch: u64,
    reload_snapshot: runtime_core.GameplaySnapshot,
    reload_outcome: runtime_core.GameplayOutcome,
};

fn runFullVerticalSlice() !FullVerticalEvidence {
    var fixture = try makeRuntimeFixture(
        vertical_slice_manifest,
        &.{
            .{ .path = "scripts/vertical-player.luau", .source = vertical_slice_player_source },
            .{ .path = "scripts/no-op.luau", .source = vertical_slice_no_op_source },
        },
        vertical_slice_scene,
    );
    defer fixture.deinit();
    try startVerticalRuntime(&fixture);

    var recorder = gameplay_replay.Recorder.init();
    const initial_world_epoch = try fixture.generation.worldEpoch();
    const initial_player_entity = fixture.generation.playerEntity();
    recorder.recordLifecycle(.initial, initial_world_epoch);
    _ = try recordVerticalSnapshot(&fixture, &recorder);
    _ = try runVerticalFixedStep(&fixture, .{}, &recorder);
    _ = try runVerticalFixedStep(&fixture, .{}, &recorder);
    _ = try runVerticalFixedStep(&fixture, .{ .move_y = 1 }, &recorder);

    try restartVerticalFixture(&fixture);
    const restart_world_epoch = try fixture.generation.worldEpoch();
    const restart_player_entity = fixture.generation.playerEntity();
    recorder.recordLifecycle(.restart, restart_world_epoch);
    const restart_snapshot = try recordVerticalSnapshot(&fixture, &recorder);
    const probe_index = fixture.generation.objectIndex("phase-probe") orelse return error.MissingVerticalProbe;
    const restart_probe_position = try fixture.generation.objectPosition(probe_index);
    _ = try runVerticalFixedStep(&fixture, .{}, &recorder);
    const restart_terminal = try runVerticalFixedStep(&fixture, .{}, &recorder);
    const restart_outcome = restart_terminal.outcome orelse return error.MissingRestartOutcome;

    try reloadVerticalFixture(&fixture);
    const reload_world_epoch = try fixture.generation.worldEpoch();
    recorder.recordLifecycle(.scene_reload, reload_world_epoch);
    _ = try recordVerticalSnapshot(&fixture, &recorder);
    _ = try runVerticalFixedStep(&fixture, .{}, &recorder);
    const reload_terminal = try runVerticalFixedStep(&fixture, .{}, &recorder);
    const reload_outcome = reload_terminal.outcome orelse return error.MissingReloadOutcome;

    return .{
        .digest = recorder.finish(),
        .initial_world_epoch = initial_world_epoch,
        .initial_player_entity = initial_player_entity,
        .restart_world_epoch = restart_world_epoch,
        .restart_player_entity = restart_player_entity,
        .restart_snapshot = restart_snapshot,
        .restart_probe_position = restart_probe_position,
        .restart_outcome = restart_outcome,
        .reload_world_epoch = reload_world_epoch,
        .reload_snapshot = reload_terminal.snapshot,
        .reload_outcome = reload_outcome,
    };
}

test "Vertical Slice replay is deterministic through Behavior fixed Contact Phase and terminal Snapshot" {
    const first = try runInitialVerticalSlice(0);
    const replay = try runInitialVerticalSlice(0);
    const changed_input = try runInitialVerticalSlice(1);

    try std.testing.expectEqualSlices(u8, &first.digest, &replay.digest);
    try std.testing.expect(!std.mem.eql(u8, &first.digest, &changed_input.digest));
    try std.testing.expectEqual(@intFromEnum(runtime_core.GameplayPhase.lost), first.first_outcome.phase);
    try std.testing.expectEqual(@intFromEnum(runtime_core.GameplayCause.hazard), first.first_outcome.cause);
    try std.testing.expectEqual(@as(u64, 1), first.first_outcome.sequence);
    try std.testing.expectEqualStrings("hazard-a", runtime_core.objectIdSlice(&first.first_outcome.other));
    try std.testing.expectEqual(@intFromEnum(runtime_core.GameplayPhase.lost), first.final_snapshot.phase);
    try std.testing.expectEqual(@intFromEnum(runtime_core.GameplayCause.hazard), first.final_snapshot.cause);
    try std.testing.expectEqual(@as(u32, 0), first.final_snapshot.accepts_input);
    try std.testing.expectEqual(@as(u64, 1), first.final_snapshot.last_outcome_sequence);
    try std.testing.expectEqual(@as(f32, 30), first.player_position[0]);
    // 2=begin(A)，随后 1=end(A)、2=begin(B)，证明跨接触切换的 Phase 投递顺序为 212。
    try std.testing.expectEqual(@as(f32, 212), first.probe_position[0]);
}

test "Vertical Slice restart and reload preserve outcome sequence and advance world epoch" {
    const first = try runFullVerticalSlice();
    const replay = try runFullVerticalSlice();

    try std.testing.expectEqualSlices(u8, &first.digest, &replay.digest);
    try std.testing.expectEqual(@as(u64, 1), first.initial_world_epoch);
    try std.testing.expectEqual(first.initial_world_epoch, first.restart_world_epoch);
    try std.testing.expect(first.initial_player_entity != first.restart_player_entity);
    try std.testing.expectEqual(@intFromEnum(runtime_core.GameplayPhase.playing), first.restart_snapshot.phase);
    try std.testing.expectEqual(@as(f32, 0), first.restart_probe_position[0]);
    try std.testing.expectEqual(@as(u64, 2), first.restart_outcome.sequence);
    try std.testing.expectEqual(@intFromEnum(runtime_core.GameplayCause.hazard), first.restart_outcome.cause);
    try std.testing.expectEqual(first.restart_world_epoch + 1, first.reload_world_epoch);
    try std.testing.expectEqual(@as(u64, 3), first.reload_outcome.sequence);
    try std.testing.expectEqual(@intFromEnum(runtime_core.GameplayCause.goal), first.reload_outcome.cause);
    try std.testing.expectEqual(@intFromEnum(runtime_core.GameplayPhase.won), first.reload_snapshot.phase);
    try std.testing.expectEqual(first.reload_world_epoch, first.reload_snapshot.world_epoch);
}
