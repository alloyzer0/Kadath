const std = @import("std");
const artifact = @import("behavior_artifact");
const common = @import("behavior_common");

const c = @cImport({
    @cInclude("kadath_luau.h");
});

pub const Diagnostic = common.Diagnostic;
pub const ParameterValue = common.ParameterValue;
pub const TranslateCommand = common.TranslateCommand;
pub const CommandBuffer = common.CommandBuffer;
pub const InputSnapshot = struct {
    move_x: i32 = 0,
    move_y: i32 = 0,
};
pub const NativeHostV4 = c.KadathLuauHostV4;
pub const NativeObjectHandle = c.KadathLuauObjectHandle;
pub const NativePostedEvent = c.KadathLuauPostedEvent;
pub const NativeEvent = c.KadathLuauEvent;
pub const NativeEventField = c.KadathLuauEventField;
pub const NativeEventValue = c.KadathLuauEventValue;
pub const max_parameter_count = common.max_parameter_count;
pub const max_object_id_bytes = common.max_object_id_bytes;
pub const max_entry_count = artifact.max_entry_count;
pub const max_binding_count: usize = 256;
pub const max_bindings_per_object: usize = 4;
pub const max_command_intent_count: usize = max_binding_count * common.max_command_count;
pub const default_asset_memory_limit: usize = 2 * 1024 * 1024;
pub const default_interrupt_limit: i32 = 100_000;

pub fn toolchainIdentity() []const u8 {
    return std.mem.span(c.kadath_luau_runtime_toolchain_identity());
}

pub const Asset = struct {
    handle: *c.KadathLuauAsset,

    pub fn init(
        bytecode: []const u8,
        memory_limit: usize,
        interrupt_limit: i32,
        diagnostic: *Diagnostic,
    ) !Asset {
        diagnostic.clear();
        const handle = c.kadath_luau_asset_create(
            bytecode.ptr,
            bytecode.len,
            memory_limit,
            interrupt_limit,
            &diagnostic.storage,
            diagnostic.storage.len,
        ) orelse {
            diagnostic.refresh();
            return error.BehaviorAssetCreateFailed;
        };
        diagnostic.refresh();
        return .{ .handle = handle };
    }

    pub fn deinit(self: *Asset) void {
        c.kadath_luau_asset_destroy(self.handle);
        self.* = undefined;
    }

    pub fn memoryUsed(self: *const Asset) usize {
        return c.kadath_luau_asset_memory_used(self.handle);
    }

    pub fn createInstance(
        self: *Asset,
        object_id: []const u8,
        parameters: []const ParameterValue,
        diagnostic: *Diagnostic,
    ) !Instance {
        try common.validateObjectId(object_id);
        if (parameters.len > max_parameter_count) return error.BehaviorParameterCountExceeded;
        var native_parameters: [max_parameter_count]c.KadathLuauParameterValue = undefined;
        for (parameters, 0..) |parameter, index| {
            try common.validateParameterName(parameter.name);
            if (!std.math.isFinite(parameter.value)) return error.InvalidBehaviorParameter;
            for (parameters[0..index]) |existing| {
                if (std.mem.eql(u8, existing.name, parameter.name)) return error.DuplicateBehaviorParameter;
            }
            native_parameters[index] = .{
                .name = parameter.name.ptr,
                .name_length = parameter.name.len,
                .value = parameter.value,
            };
        }
        diagnostic.clear();
        const handle = c.kadath_luau_instance_create(
            self.handle,
            object_id.ptr,
            object_id.len,
            if (parameters.len == 0) null else &native_parameters,
            parameters.len,
            &diagnostic.storage,
            diagnostic.storage.len,
        ) orelse {
            diagnostic.refresh();
            return error.BehaviorInstanceCreateFailed;
        };
        diagnostic.refresh();
        return .{ .handle = handle };
    }
};

pub const BindingSpec = struct {
    script_id: u32,
    object_id: []const u8,
    parameters: []const ParameterValue = &.{},
    position: [2]f32,
};

pub const PreparedBinding = struct {
    instance: Instance,
    script_id: u32,
    object_id_storage: [max_object_id_bytes]u8 = [_]u8{0} ** max_object_id_bytes,
    object_id_bytes: u8 = 0,
    commands: [common.max_command_count]TranslateCommand = undefined,
    command_count: u8 = 0,
    enabled: bool = true,

    pub fn objectId(self: *const PreparedBinding) []const u8 {
        return self.object_id_storage[0..self.object_id_bytes];
    }

    pub fn commandSlice(self: *const PreparedBinding) []const TranslateCommand {
        return self.commands[0..self.command_count];
    }
};

pub const PreparedSet = struct {
    bindings: [max_binding_count]?PreparedBinding = [_]?PreparedBinding{null} ** max_binding_count,
    binding_count: usize = 0,

    pub fn deinit(self: *PreparedSet) void {
        for (self.bindings[0..self.binding_count]) |*binding| {
            if (binding.*) |*value| value.instance.deinit();
        }
        self.* = undefined;
    }

    pub fn bindingSlice(self: *const PreparedSet) []const ?PreparedBinding {
        return self.bindings[0..self.binding_count];
    }

    pub fn activate(self: *PreparedSet) ActiveSet {
        var active: ActiveSet = undefined;
        self.activateInto(&active);
        return active;
    }

    pub fn activateInto(self: *PreparedSet, active: *ActiveSet) void {
        active.bindings = self.bindings;
        active.binding_count = self.binding_count;
        active.command_intent_count = 0;
        active.failure_count = 0;
        self.bindings = [_]?PreparedBinding{null} ** max_binding_count;
        self.binding_count = 0;
    }
};

pub const ObjectSnapshot = struct {
    object_id: []const u8,
    position: [2]f32,
};

pub const CommandIntent = struct {
    binding_index: u16,
    dx: f64,
    dy: f64,
};

pub const BindingFailure = struct {
    binding_index: u16 = 0,
    error_name_storage: [64]u8 = [_]u8{0} ** 64,
    error_name_bytes: u8 = 0,
    diagnostic_storage: [common.max_diagnostic_bytes]u8 = [_]u8{0} ** common.max_diagnostic_bytes,
    diagnostic_bytes: u16 = 0,

    pub fn errorName(self: *const BindingFailure) []const u8 {
        return self.error_name_storage[0..self.error_name_bytes];
    }

    pub fn diagnostic(self: *const BindingFailure) []const u8 {
        return self.diagnostic_storage[0..self.diagnostic_bytes];
    }
};

pub const ActiveSet = struct {
    bindings: [max_binding_count]?PreparedBinding = [_]?PreparedBinding{null} ** max_binding_count,
    binding_count: usize = 0,
    command_intents: [max_command_intent_count]CommandIntent = undefined,
    command_intent_count: usize = 0,
    failures: [max_binding_count]BindingFailure = [_]BindingFailure{.{}} ** max_binding_count,
    failure_count: usize = 0,

    pub fn deinit(self: *ActiveSet) void {
        for (self.bindings[0..self.binding_count]) |*binding| {
            if (binding.*) |*value| value.instance.deinit();
        }
        self.* = undefined;
    }

    pub fn appendPrepared(self: *ActiveSet, prepared: *PreparedSet) !void {
        if (self.binding_count + prepared.binding_count > self.bindings.len) {
            return error.BehaviorBindingCountExceeded;
        }
        for (prepared.bindings[0..prepared.binding_count]) |*optional_binding| {
            self.bindings[self.binding_count] = optional_binding.*;
            optional_binding.* = null;
            self.binding_count += 1;
        }
        prepared.binding_count = 0;
    }

    pub fn appendActive(self: *ActiveSet, source: *ActiveSet) !void {
        if (self.binding_count + source.binding_count > self.bindings.len) {
            return error.BehaviorBindingCountExceeded;
        }
        for (source.bindings[0..source.binding_count]) |*optional_binding| {
            self.bindings[self.binding_count] = optional_binding.*;
            optional_binding.* = null;
            self.binding_count += 1;
        }
        source.binding_count = 0;
    }

    pub fn removeObject(self: *ActiveSet, object_id: []const u8) void {
        var write_index: usize = 0;
        for (self.bindings[0..self.binding_count], 0..) |*optional_binding, read_index| {
            var binding = optional_binding.* orelse continue;
            if (std.mem.eql(u8, binding.objectId(), object_id)) {
                binding.instance.deinit();
                optional_binding.* = null;
                continue;
            }
            if (write_index != read_index) {
                self.bindings[write_index] = binding;
                optional_binding.* = null;
            }
            write_index += 1;
        }
        for (self.bindings[write_index..self.binding_count]) |*binding| binding.* = null;
        self.binding_count = write_index;
    }

    pub fn onStartCommands(self: *ActiveSet) []const CommandIntent {
        self.command_intent_count = 0;
        self.failure_count = 0;
        for (self.bindings[0..self.binding_count], 0..) |*optional_binding, binding_index| {
            const binding = &optional_binding.*.?;
            if (!binding.enabled) continue;
            self.appendCommands(binding_index, binding.commandSlice());
        }
        return self.commandSlice();
    }

    pub fn runFixed(self: *ActiveSet, dt_seconds: f32, snapshots: []const ObjectSnapshot, input: InputSnapshot) !void {
        if (!std.math.isFinite(dt_seconds) or dt_seconds < 0) return error.InvalidFixedDelta;
        self.command_intent_count = 0;
        self.failure_count = 0;
        try validateInputSnapshot(input);
        for (self.bindings[0..self.binding_count], 0..) |*optional_binding, binding_index| {
            const binding = &optional_binding.*.?;
            if (!binding.enabled) continue;
            const snapshot = findSnapshot(snapshots, binding.objectId()) orelse {
                binding.enabled = false;
                self.recordFailure(binding_index, error.MissingBehaviorObjectSnapshot, "");
                continue;
            };
            var diagnostic = Diagnostic{};
            const commands = binding.instance.fixedUpdate(dt_seconds, snapshot.position, input, &binding.commands, &diagnostic) catch |err| {
                binding.enabled = false;
                self.recordFailure(binding_index, err, diagnostic.slice());
                continue;
            };
            binding.command_count = @intCast(commands.len);
            self.appendCommands(binding_index, commands);
        }
    }

    pub const BindingObserver = struct {
        userdata: ?*anyopaque,
        begin: *const fn (?*anyopaque, usize, []const u8, u32) void,
        end: *const fn (?*anyopaque) void,
    };

    pub fn runStartV4(self: *ActiveSet, host: *const NativeHostV4) !void {
        return self.runStartV4Observed(host, null);
    }

    pub fn runStartV4Observed(self: *ActiveSet, host: *const NativeHostV4, observer: ?BindingObserver) !void {
        self.failure_count = 0;
        for (self.bindings[0..self.binding_count], 0..) |*optional_binding, binding_index| {
            const binding = &optional_binding.*.?;
            if (!binding.enabled) continue;
            if (!hostResolves(host, binding.objectId())) continue;
            var diagnostic = Diagnostic{};
            if (observer) |value| value.begin(value.userdata, binding_index, binding.objectId(), binding.script_id);
            const result = binding.instance.onStartV4(host, &diagnostic);
            if (observer) |value| value.end(value.userdata);
            try result;
        }
    }

    pub fn runFixedV4(self: *ActiveSet, dt_seconds: f32, input: InputSnapshot, host: *const NativeHostV4) !void {
        return self.runFixedV4Observed(dt_seconds, input, host, null);
    }

    pub fn runFixedV4Observed(self: *ActiveSet, dt_seconds: f32, input: InputSnapshot, host: *const NativeHostV4, observer: ?BindingObserver) !void {
        if (!std.math.isFinite(dt_seconds) or dt_seconds <= 0) return error.InvalidFixedDelta;
        try validateInputSnapshot(input);
        self.failure_count = 0;
        for (self.bindings[0..self.binding_count], 0..) |*optional_binding, binding_index| {
            const binding = &optional_binding.*.?;
            if (!binding.enabled) continue;
            if (!hostResolves(host, binding.objectId())) continue;
            var diagnostic = Diagnostic{};
            if (observer) |value| value.begin(value.userdata, binding_index, binding.objectId(), binding.script_id);
            const result = binding.instance.fixedUpdateV4(dt_seconds, input, host, &diagnostic);
            if (observer) |value| value.end(value.userdata);
            result catch |err| {
                binding.enabled = false;
                self.recordFailure(binding_index, err, diagnostic.slice());
                continue;
            };
        }
    }

    pub fn runUpdateV4(self: *ActiveSet, dt_seconds: f32, input: InputSnapshot, host: *const NativeHostV4) !void {
        return self.runUpdateV4Observed(dt_seconds, input, host, null);
    }

    pub fn runUpdateV4Observed(self: *ActiveSet, dt_seconds: f32, input: InputSnapshot, host: *const NativeHostV4, observer: ?BindingObserver) !void {
        if (!std.math.isFinite(dt_seconds) or dt_seconds < 0) return error.InvalidFrameDelta;
        try validateInputSnapshot(input);
        self.failure_count = 0;
        for (self.bindings[0..self.binding_count], 0..) |*optional_binding, binding_index| {
            const binding = &optional_binding.*.?;
            if (!binding.enabled) continue;
            if (!hostResolves(host, binding.objectId())) continue;
            var diagnostic = Diagnostic{};
            if (observer) |value| value.begin(value.userdata, binding_index, binding.objectId(), binding.script_id);
            const result = binding.instance.updateV4(dt_seconds, input, host, &diagnostic);
            if (observer) |value| value.end(value.userdata);
            result catch |err| {
                binding.enabled = false;
                self.recordFailure(binding_index, err, diagnostic.slice());
                continue;
            };
        }
    }

    pub fn dispatchEventV4(
        self: *ActiveSet,
        target_object_id: []const u8,
        event: *const NativeEvent,
        input: InputSnapshot,
        host: *const NativeHostV4,
    ) !void {
        return self.dispatchEventV4Observed(target_object_id, event, input, host, null);
    }

    pub fn dispatchEventV4Observed(
        self: *ActiveSet,
        target_object_id: []const u8,
        event: *const NativeEvent,
        input: InputSnapshot,
        host: *const NativeHostV4,
        observer: ?BindingObserver,
    ) !void {
        try validateInputSnapshot(input);
        for (self.bindings[0..self.binding_count], 0..) |*optional_binding, binding_index| {
            const binding = &optional_binding.*.?;
            if (!binding.enabled or !std.mem.eql(u8, binding.objectId(), target_object_id)) continue;
            if (!hostResolves(host, binding.objectId())) continue;
            var diagnostic = Diagnostic{};
            if (observer) |value| value.begin(value.userdata, binding_index, binding.objectId(), binding.script_id);
            const result = binding.instance.onEventV4(event, input, host, &diagnostic);
            if (observer) |value| value.end(value.userdata);
            result catch |err| {
                binding.enabled = false;
                self.recordFailure(binding_index, err, diagnostic.slice());
                continue;
            };
        }
    }

    pub fn commandSlice(self: *const ActiveSet) []const CommandIntent {
        return self.command_intents[0..self.command_intent_count];
    }

    pub fn failureSlice(self: *const ActiveSet) []const BindingFailure {
        return self.failures[0..self.failure_count];
    }

    pub fn beginEventDrain(self: *ActiveSet) void {
        self.failure_count = 0;
    }

    pub fn commandObjectId(self: *const ActiveSet, command: CommandIntent) []const u8 {
        return self.bindings[command.binding_index].?.objectId();
    }

    pub fn bindingObjectId(self: *const ActiveSet, binding_index: usize) []const u8 {
        return self.bindings[binding_index].?.objectId();
    }

    pub fn bindingScriptId(self: *const ActiveSet, binding_index: usize) u32 {
        return self.bindings[binding_index].?.script_id;
    }

    pub fn bindingEnabled(self: *const ActiveSet, binding_index: usize) bool {
        if (binding_index >= self.binding_count) return false;
        return self.bindings[binding_index].?.enabled;
    }

    pub fn containsObject(self: *const ActiveSet, object_id: []const u8) bool {
        for (self.bindings[0..self.binding_count]) |optional_binding| {
            const binding = optional_binding orelse continue;
            if (std.mem.eql(u8, binding.objectId(), object_id)) return true;
        }
        return false;
    }

    pub fn disableBinding(self: *ActiveSet, binding_index: usize, err: anyerror, diagnostic: []const u8) void {
        if (binding_index >= self.binding_count) return;
        const binding = &self.bindings[binding_index].?;
        if (!binding.enabled) return;
        binding.enabled = false;
        self.recordFailure(binding_index, err, diagnostic);
    }

    pub fn disableBindingByIdentity(self: *ActiveSet, object_id: []const u8, script_id: u32, err: anyerror, diagnostic: []const u8) void {
        for (self.bindings[0..self.binding_count], 0..) |*optional_binding, binding_index| {
            const binding = &optional_binding.*.?;
            if (binding.script_id != script_id or !std.mem.eql(u8, binding.objectId(), object_id)) continue;
            self.disableBinding(binding_index, err, diagnostic);
            return;
        }
    }

    fn appendCommands(self: *ActiveSet, binding_index: usize, commands: []const TranslateCommand) void {
        std.debug.assert(self.command_intent_count + commands.len <= self.command_intents.len);
        for (commands) |command| {
            self.command_intents[self.command_intent_count] = .{
                .binding_index = @intCast(binding_index),
                .dx = command.dx,
                .dy = command.dy,
            };
            self.command_intent_count += 1;
        }
    }

    fn recordFailure(self: *ActiveSet, binding_index: usize, err: anyerror, diagnostic: []const u8) void {
        std.debug.assert(self.failure_count < self.failures.len);
        var failure = BindingFailure{ .binding_index = @intCast(binding_index) };
        const error_name = @errorName(err);
        failure.error_name_bytes = @intCast(@min(error_name.len, failure.error_name_storage.len));
        @memcpy(failure.error_name_storage[0..failure.error_name_bytes], error_name[0..failure.error_name_bytes]);
        failure.diagnostic_bytes = @intCast(@min(diagnostic.len, failure.diagnostic_storage.len));
        @memcpy(failure.diagnostic_storage[0..failure.diagnostic_bytes], diagnostic[0..failure.diagnostic_bytes]);
        self.failures[self.failure_count] = failure;
        self.failure_count += 1;
    }
};

fn hostResolves(host: *const NativeHostV4, object_id: []const u8) bool {
    const resolve = host.resolve_object orelse return false;
    var object = std.mem.zeroes(NativeObjectHandle);
    return resolve(host.userdata, object_id.ptr, object_id.len, &object) != 0;
}

fn findSnapshot(snapshots: []const ObjectSnapshot, object_id: []const u8) ?ObjectSnapshot {
    for (snapshots) |snapshot| {
        if (std.mem.eql(u8, snapshot.object_id, object_id)) return snapshot;
    }
    return null;
}

fn validateInputSnapshot(input: InputSnapshot) !void {
    if (input.move_x < -1 or input.move_x > 1 or input.move_y < -1 or input.move_y > 1) {
        return error.InvalidBehaviorInputSnapshot;
    }
}

pub const Package = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    parsed: artifact.Package,
    assets: [max_entry_count]?Asset = [_]?Asset{null} ** max_entry_count,
    entry_count: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        artifact_bytes: []const u8,
        memory_limit: usize,
        interrupt_limit: i32,
        diagnostic: *Diagnostic,
    ) !Package {
        if (memory_limit == 0 or interrupt_limit <= 0) return error.InvalidBehaviorRuntimeLimits;
        const bytes = try allocator.dupe(u8, artifact_bytes);
        errdefer allocator.free(bytes);
        const parsed = try artifact.parse(bytes, toolchainIdentity());
        var package = Package{
            .allocator = allocator,
            .bytes = bytes,
            .parsed = parsed,
            .entry_count = parsed.entry_count,
        };
        errdefer package.deinit();
        for (parsed.entrySlice(), 0..) |entry, entry_index| {
            package.assets[entry_index] = Asset.init(entry.bytecode, memory_limit, interrupt_limit, diagnostic) catch |err| {
                return err;
            };
        }
        return package;
    }

    pub fn deinit(self: *Package) void {
        for (self.assets[0..self.entry_count]) |*asset| {
            if (asset.*) |*value| value.deinit();
        }
        self.allocator.free(self.bytes);
        self.* = undefined;
    }

    pub fn entrySlice(self: *const Package) []const artifact.Entry {
        return self.parsed.entrySlice();
    }

    pub fn prepareBindings(
        self: *Package,
        specs: []const BindingSpec,
        diagnostic: *Diagnostic,
    ) !PreparedSet {
        if (specs.len > max_binding_count) return error.BehaviorBindingCountExceeded;
        var prepared = PreparedSet{};
        errdefer prepared.deinit();
        for (specs, 0..) |spec, spec_index| {
            try validateBindingSpec(specs, spec, spec_index, self.parsed.entrySlice());
            const entry_index = entryIndex(self.parsed.entrySlice(), spec.script_id) orelse return error.MissingScriptId;
            const asset = &self.assets[entry_index].?;
            var binding = PreparedBinding{
                .instance = try asset.createInstance(spec.object_id, spec.parameters, diagnostic),
                .script_id = spec.script_id,
                .object_id_bytes = @intCast(spec.object_id.len),
            };
            @memcpy(binding.object_id_storage[0..spec.object_id.len], spec.object_id);
            prepared.bindings[spec_index] = binding;
            prepared.binding_count += 1;
        }
        return prepared;
    }
};

fn validateBindingSpec(
    specs: []const BindingSpec,
    spec: BindingSpec,
    spec_index: usize,
    entries: []const artifact.Entry,
) !void {
    try common.validateObjectId(spec.object_id);
    if (!std.math.isFinite(spec.position[0]) or !std.math.isFinite(spec.position[1])) return error.InvalidBindingPosition;
    if (spec.parameters.len > max_parameter_count) return error.BehaviorParameterCountExceeded;
    const entry_index = entryIndex(entries, spec.script_id) orelse return error.MissingScriptId;
    const schema = entries[entry_index].parameterSlice();
    for (spec.parameters, 0..) |parameter, parameter_index| {
        try common.validateParameterName(parameter.name);
        if (!std.math.isFinite(parameter.value)) return error.InvalidBehaviorParameter;
        const schema_parameter = findParameter(schema, parameter.name) orelse return error.UnknownBehaviorParameter;
        if (parameter.value < schema_parameter.minimum or parameter.value > schema_parameter.maximum) return error.BehaviorParameterOutOfRange;
        for (spec.parameters[0..parameter_index]) |existing| {
            if (std.mem.eql(u8, existing.name, parameter.name)) return error.DuplicateBehaviorParameter;
        }
    }
    var object_binding_count: usize = 0;
    for (specs[0..spec_index]) |existing| {
        if (!std.mem.eql(u8, existing.object_id, spec.object_id)) continue;
        object_binding_count += 1;
        if (existing.script_id == spec.script_id) return error.DuplicateBehaviorBinding;
    }
    if (object_binding_count >= max_bindings_per_object) return error.ObjectBindingCountExceeded;
}

fn entryIndex(entries: []const artifact.Entry, script_id: u32) ?usize {
    for (entries, 0..) |entry, index| {
        if (entry.script_id == script_id) return index;
    }
    return null;
}

fn findParameter(parameters: []const common.ParameterSchema, name: []const u8) ?*const common.ParameterSchema {
    for (parameters) |*parameter| {
        if (std.mem.eql(u8, parameter.name(), name)) return parameter;
    }
    return null;
}

pub const Instance = struct {
    handle: *c.KadathLuauInstance,

    pub fn deinit(self: *Instance) void {
        c.kadath_luau_instance_destroy(self.handle);
        self.* = undefined;
    }

    pub fn onStart(
        self: *Instance,
        position: [2]f32,
        output: *CommandBuffer,
        diagnostic: *Diagnostic,
    ) ![]const TranslateCommand {
        return self.run(false, 0.0, position, .{}, output, diagnostic);
    }

    pub fn fixedUpdate(
        self: *Instance,
        dt_seconds: f32,
        position: [2]f32,
        input: InputSnapshot,
        output: *CommandBuffer,
        diagnostic: *Diagnostic,
    ) ![]const TranslateCommand {
        return self.run(true, dt_seconds, position, input, output, diagnostic);
    }

    pub fn onStartV4(self: *Instance, host: *const NativeHostV4, diagnostic: *Diagnostic) !void {
        diagnostic.clear();
        const succeeded = c.kadath_luau_instance_on_start_v4(
            self.handle,
            host,
            &diagnostic.storage,
            diagnostic.storage.len,
        );
        diagnostic.refresh();
        if (succeeded == 0) return error.BehaviorHookFailed;
    }

    pub fn fixedUpdateV4(
        self: *Instance,
        dt_seconds: f32,
        input: InputSnapshot,
        host: *const NativeHostV4,
        diagnostic: *Diagnostic,
    ) !void {
        return self.runV4(.fixed, dt_seconds, input, host, diagnostic);
    }

    pub fn updateV4(
        self: *Instance,
        dt_seconds: f32,
        input: InputSnapshot,
        host: *const NativeHostV4,
        diagnostic: *Diagnostic,
    ) !void {
        return self.runV4(.frame, dt_seconds, input, host, diagnostic);
    }

    pub fn onEventV4(
        self: *Instance,
        event: *const NativeEvent,
        input: InputSnapshot,
        host: *const NativeHostV4,
        diagnostic: *Diagnostic,
    ) !void {
        var native_input = c.KadathLuauInputSnapshot{ .move_x = input.move_x, .move_y = input.move_y };
        diagnostic.clear();
        const succeeded = c.kadath_luau_instance_on_event_v4(
            self.handle,
            event,
            &native_input,
            host,
            &diagnostic.storage,
            diagnostic.storage.len,
        );
        diagnostic.refresh();
        if (succeeded == 0) return error.BehaviorHookFailed;
    }

    const V4Phase = enum { fixed, frame };

    fn runV4(
        self: *Instance,
        phase: V4Phase,
        dt_seconds: f32,
        input: InputSnapshot,
        host: *const NativeHostV4,
        diagnostic: *Diagnostic,
    ) !void {
        var native_input = c.KadathLuauInputSnapshot{ .move_x = input.move_x, .move_y = input.move_y };
        diagnostic.clear();
        const succeeded = switch (phase) {
            .fixed => c.kadath_luau_instance_fixed_update_v4(
                self.handle,
                dt_seconds,
                &native_input,
                host,
                &diagnostic.storage,
                diagnostic.storage.len,
            ),
            .frame => c.kadath_luau_instance_update_v4(
                self.handle,
                dt_seconds,
                &native_input,
                host,
                &diagnostic.storage,
                diagnostic.storage.len,
            ),
        };
        diagnostic.refresh();
        if (succeeded == 0) return error.BehaviorHookFailed;
    }

    fn run(
        self: *Instance,
        fixed_update: bool,
        dt_seconds: f32,
        position: [2]f32,
        input: InputSnapshot,
        output: *CommandBuffer,
        diagnostic: *Diagnostic,
    ) ![]const TranslateCommand {
        var native_commands: [common.max_command_count]c.KadathLuauTranslateCommand = undefined;
        var native_input = c.KadathLuauInputSnapshot{ .move_x = input.move_x, .move_y = input.move_y };
        var command_count: usize = 0;
        diagnostic.clear();
        const succeeded = if (fixed_update)
            c.kadath_luau_instance_fixed_update(
                self.handle,
                dt_seconds,
                position[0],
                position[1],
                &native_input,
                &native_commands,
                native_commands.len,
                &command_count,
                &diagnostic.storage,
                diagnostic.storage.len,
            )
        else
            c.kadath_luau_instance_on_start(
                self.handle,
                position[0],
                position[1],
                &native_commands,
                native_commands.len,
                &command_count,
                &diagnostic.storage,
                diagnostic.storage.len,
            );
        diagnostic.refresh();
        if (succeeded == 0) return error.BehaviorHookFailed;
        if (command_count > output.len) return error.InvalidBehaviorCommandCount;
        for (native_commands[0..command_count], 0..) |command, index| {
            output[index] = .{ .dx = command.dx, .dy = command.dy };
        }
        return output[0..command_count];
    }
};
