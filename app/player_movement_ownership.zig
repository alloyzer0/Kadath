const scene_api = @import("scene.zig");

pub const AxisInput = struct {
    move_x: i8 = 0,
    move_y: i8 = 0,
};

pub const RoutedInput = struct {
    world: AxisInput,
    behaviors: AxisInput,
};

pub fn route(scene: *const scene_api.Scene, input: AxisInput) RoutedInput {
    const player_index = if (scene.gameplayEnabled()) scene.objects.indexOfKind(.player) else null;
    const behavior_owned = scene.supportsBehaviorRuntime() and
        player_index != null and
        scene.objects.entries[player_index.?].behaviors.count != 0;
    return .{
        .world = if (behavior_owned) .{} else input,
        .behaviors = input,
    };
}

pub fn routeGameplay(scene: *const scene_api.Scene, input: AxisInput, accepts_input: bool) RoutedInput {
    // Gameplay 终态先统一抑制输入，再执行 Native/Behavior ownership 分流；Host 与证据 workload 共用此规则。
    return route(scene, if (accepts_input) input else .{});
}

test "Scene v4 keeps Player movement in Native World" {
    const input = AxisInput{ .move_x = 1, .move_y = -1 };
    const routed = route(&scene_api.default_scene, input);
    try @import("std").testing.expectEqual(input, routed.world);
}

test "Behavior Scene without Player bindings keeps Player movement in Native World" {
    var scene = scene_api.default_scene;
    scene.schemaVersion = scene_api.current_schema_version;
    scene.gameplay = scene_api.goal_hazard_v1_gameplay;
    const input = AxisInput{ .move_x = -1, .move_y = 1 };
    const routed = route(&scene, input);
    try @import("std").testing.expectEqual(input, routed.world);
    try @import("std").testing.expectEqual(input, routed.behaviors);
}

test "Behavior Scene with any Player binding moves ownership to Behavior Bindings" {
    var scene = scene_api.default_scene;
    scene.schemaVersion = scene_api.current_schema_version;
    scene.gameplay = scene_api.goal_hazard_v1_gameplay;
    const player = &scene.objects.entries[scene.objects.indexOfKind(.player).?];
    player.behaviors.count = 1;
    player.behaviors.entries[0].scriptId = 999;
    const input = AxisInput{ .move_x = 1, .move_y = 1 };
    const routed = route(&scene, input);
    try @import("std").testing.expectEqual(AxisInput{}, routed.world);
    try @import("std").testing.expectEqual(input, routed.behaviors);
}

test "terminal Gameplay state suppresses both movement ownership outputs" {
    var scene = scene_api.default_scene;
    scene.schemaVersion = scene_api.current_schema_version;
    scene.gameplay = scene_api.goal_hazard_v1_gameplay;
    const player = &scene.objects.entries[scene.objects.indexOfKind(.player).?];
    player.behaviors.count = 1;
    player.behaviors.entries[0].scriptId = 999;
    const routed = routeGameplay(&scene, .{ .move_x = 1, .move_y = -1 }, false);
    try @import("std").testing.expectEqual(AxisInput{}, routed.world);
    try @import("std").testing.expectEqual(AxisInput{}, routed.behaviors);
}
