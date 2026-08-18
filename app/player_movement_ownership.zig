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
    const behavior_owned = scene.schemaVersion == scene_api.current_schema_version and
        scene.player().behaviors.count != 0;
    return .{
        .world = if (behavior_owned) .{} else input,
        .behaviors = input,
    };
}

test "Scene v4 keeps Player movement in Native World" {
    const input = AxisInput{ .move_x = 1, .move_y = -1 };
    const routed = route(&scene_api.default_scene, input);
    try @import("std").testing.expectEqual(input, routed.world);
}

test "Scene v5 without Player bindings keeps Player movement in Native World" {
    var scene = scene_api.default_scene;
    scene.schemaVersion = scene_api.current_schema_version;
    const input = AxisInput{ .move_x = -1, .move_y = 1 };
    const routed = route(&scene, input);
    try @import("std").testing.expectEqual(input, routed.world);
    try @import("std").testing.expectEqual(input, routed.behaviors);
}

test "Scene v5 with any Player binding moves ownership to Behavior Bindings" {
    var scene = scene_api.default_scene;
    scene.schemaVersion = scene_api.current_schema_version;
    const player = &scene.objects.entries[scene.objects.indexOfKind(.player).?];
    player.behaviors.count = 1;
    player.behaviors.entries[0].scriptId = 999;
    const input = AxisInput{ .move_x = 1, .move_y = 1 };
    const routed = route(&scene, input);
    try @import("std").testing.expectEqual(AxisInput{}, routed.world);
    try @import("std").testing.expectEqual(input, routed.behaviors);
}
