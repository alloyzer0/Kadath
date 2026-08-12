const std = @import("std");
const artifact = @import("behavior_artifact");
const common = @import("behavior_common");
const runtime = @import("behavior_runtime");

pub const max_binding_count = runtime.max_binding_count;
pub const max_bindings_per_object = runtime.max_bindings_per_object;
pub const ParameterOverride = common.ParameterValue;

pub const BindingInput = struct {
    script_id: u32,
    parameters: []const ParameterOverride = &.{},
};

pub const ObjectInput = struct {
    object_id: []const u8,
    position: [2]f32,
    bindings: []const BindingInput = &.{},
};

pub const Parameter = struct {
    name_storage: [common.max_parameter_name_bytes]u8 = [_]u8{0} ** common.max_parameter_name_bytes,
    name_bytes: u8 = 0,
    value: f64 = 0,

    pub fn name(self: *const Parameter) []const u8 {
        return self.name_storage[0..self.name_bytes];
    }
};

pub const Binding = struct {
    object_id_storage: [common.max_object_id_bytes]u8 = [_]u8{0} ** common.max_object_id_bytes,
    object_id_bytes: u8 = 0,
    object_ordinal: usize = 0,
    binding_ordinal: usize = 0,
    script_id: u32 = 0,
    position: [2]f32 = .{ 0, 0 },
    parameters: [common.max_parameter_count]Parameter = [_]Parameter{.{}} ** common.max_parameter_count,
    parameter_count: u8 = 0,

    pub fn objectId(self: *const Binding) []const u8 {
        return self.object_id_storage[0..self.object_id_bytes];
    }

    pub fn parameterSlice(self: *const Binding) []const Parameter {
        return self.parameters[0..self.parameter_count];
    }
};

pub const Set = struct {
    bindings: [max_binding_count]Binding = [_]Binding{.{}} ** max_binding_count,
    binding_count: usize = 0,

    pub fn bindingSlice(self: *const Set) []const Binding {
        return self.bindings[0..self.binding_count];
    }

    pub fn prepare(
        self: *const Set,
        package: *runtime.Package,
        diagnostic: *runtime.Diagnostic,
    ) !runtime.PreparedSet {
        var specs: [max_binding_count]runtime.BindingSpec = undefined;
        var values: [max_binding_count][common.max_parameter_count]runtime.ParameterValue = undefined;
        for (self.bindingSlice(), 0..) |*binding, binding_index| {
            for (binding.parameterSlice(), 0..) |*parameter, parameter_index| {
                values[binding_index][parameter_index] = .{
                    .name = parameter.name(),
                    .value = parameter.value,
                };
            }
            specs[binding_index] = .{
                .script_id = binding.script_id,
                .object_id = binding.objectId(),
                .parameters = values[binding_index][0..binding.parameter_count],
                .position = binding.position,
            };
        }
        return package.prepareBindings(specs[0..self.binding_count], diagnostic);
    }
};

pub fn normalize(package: *const artifact.Package, objects: []const ObjectInput) !Set {
    var result = Set{};
    for (objects, 0..) |object, object_ordinal| {
        try common.validateObjectId(object.object_id);
        if (!std.math.isFinite(object.position[0]) or !std.math.isFinite(object.position[1])) {
            return error.InvalidBindingPosition;
        }
        for (objects[0..object_ordinal]) |previous| {
            if (std.mem.eql(u8, previous.object_id, object.object_id)) return error.DuplicateObjectId;
        }
        if (object.bindings.len > max_bindings_per_object) return error.ObjectBindingCountExceeded;
        for (object.bindings, 0..) |input, binding_ordinal| {
            if (result.binding_count >= max_binding_count) return error.BehaviorBindingCountExceeded;
            for (object.bindings[0..binding_ordinal]) |previous| {
                if (previous.script_id == input.script_id) return error.DuplicateBehaviorBinding;
            }
            const entry = package.findEntry(input.script_id) orelse return error.MissingScriptId;
            if (input.parameters.len > common.max_parameter_count) return error.BehaviorParameterCountExceeded;

            var binding = Binding{
                .object_id_bytes = @intCast(object.object_id.len),
                .object_ordinal = object_ordinal,
                .binding_ordinal = binding_ordinal,
                .script_id = input.script_id,
                .position = object.position,
                .parameter_count = entry.parameter_count,
            };
            @memcpy(binding.object_id_storage[0..object.object_id.len], object.object_id);
            for (entry.parameterSlice(), 0..) |schema, parameter_index| {
                binding.parameters[parameter_index] = .{
                    .name_bytes = schema.name_bytes,
                    .value = schema.default_value,
                };
                @memcpy(
                    binding.parameters[parameter_index].name_storage[0..schema.name_bytes],
                    schema.name(),
                );
            }
            for (input.parameters, 0..) |override, override_index| {
                try common.validateParameterName(override.name);
                if (!std.math.isFinite(override.value)) return error.InvalidBehaviorParameter;
                for (input.parameters[0..override_index]) |previous| {
                    if (std.mem.eql(u8, previous.name, override.name)) return error.DuplicateBehaviorParameter;
                }
                const parameter_index = findParameterIndex(entry.parameterSlice(), override.name) orelse {
                    return error.UnknownBehaviorParameter;
                };
                const schema = entry.parameters[parameter_index];
                if (override.value < schema.minimum or override.value > schema.maximum) {
                    return error.BehaviorParameterOutOfRange;
                }
                binding.parameters[parameter_index].value = override.value;
            }
            result.bindings[result.binding_count] = binding;
            result.binding_count += 1;
        }
    }
    return result;
}

fn findParameterIndex(parameters: []const common.ParameterSchema, name: []const u8) ?usize {
    for (parameters, 0..) |*parameter, index| {
        if (std.mem.eql(u8, parameter.name(), name)) return index;
    }
    return null;
}
