const artifact = @import("behavior_artifact");
const scene_binding = @import("behavior_scene_binding");
const scene_api = @import("scene.zig");

pub fn normalize(
    package: *const artifact.Package,
    scene: *const scene_api.Scene,
) !scene_binding.Set {
    if (!scene.supportsBehaviorRuntime()) return error.UnsupportedBehaviorSceneSchema;
    try scene_api.validate(scene);

    var object_inputs: [scene_api.max_scene_object_count]scene_binding.ObjectInput = undefined;
    var binding_inputs: [scene_api.max_scene_object_count][scene_api.max_behavior_bindings_per_object]scene_binding.BindingInput = undefined;
    var parameter_inputs: [scene_api.max_scene_object_count][scene_api.max_behavior_bindings_per_object][scene_api.max_behavior_parameter_count]scene_binding.ParameterOverride = undefined;

    for (scene.objects.slice(), 0..) |*object, object_index| {
        for (object.behaviors.slice(), 0..) |*binding, binding_index| {
            for (binding.parameterSlice(), 0..) |*parameter, parameter_index| {
                parameter_inputs[object_index][binding_index][parameter_index] = .{
                    .name = parameter.name(),
                    .value = parameter.value,
                };
            }
            binding_inputs[object_index][binding_index] = .{
                .script_id = binding.scriptId,
                .parameters = parameter_inputs[object_index][binding_index][0..binding.parameterCount],
            };
        }
        object_inputs[object_index] = .{
            .object_id = object.objectId.slice(),
            .position = object.sprite.position,
            .bindings = binding_inputs[object_index][0..object.behaviors.count],
        };
    }
    return scene_binding.normalize(package, object_inputs[0..scene.objects.count]);
}

pub fn validatePrototypes(package: *const artifact.Package, scene: *const scene_api.Scene) !void {
    for (scene.prototypes.slice()) |*prototype| {
        _ = try normalizePrototype(package, prototype, "runtime-0000000000000001", .{ 0, 0 });
    }
}

pub fn normalizePrototype(
    package: *const artifact.Package,
    prototype: *const scene_api.SpawnPrototype,
    object_id: []const u8,
    position: [2]f32,
) !scene_binding.Set {
    var binding_inputs: [scene_api.max_behavior_bindings_per_object]scene_binding.BindingInput = undefined;
    var parameter_inputs: [scene_api.max_behavior_bindings_per_object][scene_api.max_behavior_parameter_count]scene_binding.ParameterOverride = undefined;
    for (prototype.behaviors.slice(), 0..) |*binding, binding_index| {
        for (binding.parameterSlice(), 0..) |*parameter, parameter_index| {
            parameter_inputs[binding_index][parameter_index] = .{ .name = parameter.name(), .value = parameter.value };
        }
        binding_inputs[binding_index] = .{
            .script_id = binding.scriptId,
            .parameters = parameter_inputs[binding_index][0..binding.parameterCount],
        };
    }
    const objects = [_]scene_binding.ObjectInput{.{
        .object_id = object_id,
        .position = position,
        .bindings = binding_inputs[0..prototype.behaviors.count],
    }};
    return scene_binding.normalize(package, &objects);
}

fn parameterSchema(name: []const u8, default_value: f64, minimum: f64, maximum: f64) artifact.ParameterSchema {
    var schema = artifact.ParameterSchema{
        .name_bytes = @intCast(name.len),
        .default_value = default_value,
        .minimum = minimum,
        .maximum = maximum,
    };
    @memcpy(schema.name_storage[0..name.len], name);
    return schema;
}

fn testPackage() artifact.Package {
    var package = artifact.Package{ .entry_count = 1 };
    package.entries[0].script_id = 7;
    package.entries[0].parameter_count = 3;
    package.entries[0].parameters[0] = parameterSchema("minY", 20, -100, 100);
    package.entries[0].parameters[1] = parameterSchema("maxY", 60, -100, 100);
    package.entries[0].parameters[2] = parameterSchema("speed", 80, 0, 1000);
    return package;
}

const test_scene_source =
    \\{"schemaVersion":6,"textures":[{"textureId":1,"artifact":"assets/renderer2d/test.texture"}],"objects":[
    \\{"objectId":"goal","kind":"goal","transform":{"position":[10,20]},"sprite":{"size":[3,4],"color":[1,1,1,1],"textureId":1},"behaviors":[]},
    \\{"objectId":"hazard-1","kind":"patrol_hazard","transform":{"position":[30,40]},"sprite":{"size":[5,6],"color":[1,0,0,1],"textureId":1},"behaviors":[{"scriptId":7,"parameters":{"speed":7}}]},
    \\{"objectId":"player","kind":"player","transform":{"position":[1,2]},"sprite":{"size":[8,9],"color":[1,1,1,1],"textureId":1},"player":{"moveSpeed":10},"behaviors":[]}],"prototypes":[]}
;

test "Scene adapter validates KSCP references and expands defaults" {
    const std = @import("std");
    const package = testPackage();
    const scene = try scene_api.parse(std.testing.allocator, test_scene_source);
    const set = try normalize(&package, &scene);
    try std.testing.expectEqual(@as(usize, 1), set.binding_count);
    try std.testing.expectEqualStrings("hazard-1", set.bindings[0].objectId());
    try std.testing.expectEqual(@as(u32, 7), set.bindings[0].script_id);
    try std.testing.expectEqual(@as(u8, 3), set.bindings[0].parameter_count);
    try std.testing.expectEqualStrings("minY", set.bindings[0].parameters[0].name());
    try std.testing.expectEqual(@as(f64, 20), set.bindings[0].parameters[0].value);
    try std.testing.expectEqualStrings("speed", set.bindings[0].parameters[2].name());
    try std.testing.expectEqual(@as(f64, 7), set.bindings[0].parameters[2].value);
}

test "Scene adapter rejects missing scripts and invalid overrides" {
    const std = @import("std");
    const package = testPackage();
    var scene = try scene_api.parse(std.testing.allocator, test_scene_source);

    scene.objects.entries[1].behaviors.entries[0].scriptId = 999;
    try std.testing.expectError(error.MissingScriptId, normalize(&package, &scene));

    scene = try scene_api.parse(std.testing.allocator, test_scene_source);
    scene.objects.entries[1].behaviors.entries[0].parameters[0].value = 1001;
    try std.testing.expectError(error.BehaviorParameterOutOfRange, normalize(&package, &scene));

    scene = try scene_api.parse(std.testing.allocator, test_scene_source);
    var parameter = &scene.objects.entries[1].behaviors.entries[0].parameters[0];
    parameter.nameBytes = 7;
    @memcpy(parameter.nameStorage[0..7], "unknown");
    try std.testing.expectError(error.UnknownBehaviorParameter, normalize(&package, &scene));
}
