const std = @import("std");
const behavior_host = @import("behavior_host.zig");
const builder = @import("behavior_package_builder");
const manifest = @import("behavior_manifest");
const scene_api = @import("scene.zig");

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
    var runtime = try behavior_host.initArtifact(std.testing.allocator, built.bytes, &scene);
    defer runtime.deinit();

    const start = try runtime.onStart(&scene);
    try std.testing.expectEqual(@as(usize, 3), start.object_count);
    try std.testing.expectApproxEqAbs(@as(f64, 1), start.deltas[1][0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0), start.deltas[1][1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 1), start.deltas[2][0], 0.0001);

    const positions = [_][2]f32{ .{ 10, 20 }, .{ 31, 40 }, .{ 1, 2 } };
    const first = try runtime.runFixed(&scene, &positions, 0.5, .{ .move_x = 1, .move_y = -1 });
    try std.testing.expectApproxEqAbs(@as(f64, 1), first.deltas[1][0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 4), first.deltas[1][1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 3), first.deltas[2][0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 8), first.deltas[2][1], 0.0001);
    const second = try runtime.runFixed(&scene, &positions, 0.5, .{});
    try std.testing.expectApproxEqAbs(@as(f64, -5), second.deltas[1][1], 0.0001);
}
