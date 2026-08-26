const std = @import("std");
const builtin = @import("builtin");
const behavior_host = switch (builtin.os.tag) {
    // Windows 与 Linux 的 native x86_64 构建图都已接入完整 Luau Runtime，产品 Host 不得退回拒绝加载的 stub。
    .windows, .linux => @import("behavior_host.zig"),
    else => @import("behavior_host_stub.zig"),
};
const content_identity = @import("content_identity.zig");
const audio_api = @import("audio");
const player_movement_ownership = @import("player_movement_ownership.zig");
const runtime_texture_registry = @import("runtime_texture_registry.zig");
const runtime_core = @import("runtime_core");
const scene_api = @import("scene.zig");
const scene_generation_api = @import("scene_generation.zig");
const script_api = @import("script.zig");
const preview_status_api = @import("preview_status");
const preview_control_api = @import("preview_control.zig");
const Platform = @import("platform").Platform;
const PlatformExtent = @import("platform").WindowExtent;
const InputSnapshot = @import("platform").InputSnapshot;
const rhi = @import("rhi");
const Rhi = rhi.Rhi;
const Renderer2D = @import("renderer2d").Renderer2D;
const SpriteInstance = @import("renderer2d").SpriteInstance;

const fixed_dt_seconds: f64 = 1.0 / 60.0;
const max_fixed_steps_per_frame: u8 = 4;
fn validateSceneTextureBindings(registry: *const runtime_texture_registry.RuntimeTextureRegistry, scene: *const scene_api.Scene) !void {
    for (scene.objects.slice()) |object| _ = try registry.resolve(object.sprite.textureId);
    for (scene.prototypes.slice()) |prototype| _ = try registry.resolve(prototype.sprite.textureId);
}

fn sceneHasBehaviors(scene: *const scene_api.Scene) bool {
    for (scene.objects.slice()) |object| {
        if (object.behaviors.count != 0) return true;
    }
    for (scene.prototypes.slice()) |prototype| {
        if (prototype.behaviors.count != 0) return true;
    }
    return false;
}

fn usesBehaviorRuntime(scene: *const scene_api.Scene) bool {
    return scene.schemaVersion == scene_api.behavior_schema_version or
        scene.schemaVersion == scene_api.current_schema_version;
}

fn initialLoadedTarget(identity: ?content_identity.ContentIdentity) preview_status_api.InitialLoadedTarget {
    if (identity) |value| {
        return .{ .file = .{
            .kind = switch (value.kind) {
                .source_document => .source_document,
                .artifact => .artifact,
            },
            .sha256 = value.sha256,
            .byte_count = value.byte_count,
        } };
    }
    return .built_in;
}

pub const Host = struct {
    io: std.Io,
    preview_status: *preview_status_api.PreviewStatus,
    initial_loaded: preview_status_api.InitialLoaded,
    scene: scene_api.Scene,
    scene_path: ?[]const u8,
    script_path: ?[]const u8,
    script_program: script_api.Program,
    script_enabled: bool,
    script_tick: u64,
    behavior_runtime: behavior_host.Runtime,
    platform: Platform,
    rhi: Rhi,
    renderer2d: Renderer2D,
    audio: audio_api.Audio,
    texture_registry: runtime_texture_registry.RuntimeTextureRegistry,
    generation: scene_generation_api.SceneGeneration,
    world_extent: PlatformExtent,
    render_sprites: [runtime_core.max_object_count]runtime_core.RenderSprite = undefined,
    render_count: usize = 0,
    quit_requested: bool = false,
    last_time_seconds: f64 = 0.0,
    accumulator_seconds: f64 = 0.0,
    frame_count: u64 = 0,
    last_heartbeat_seconds: f64 = 0.0,

    pub fn init(io: std.Io, scene_path: ?[]const u8, script_path: ?[]const u8, preview_status: *preview_status_api.PreviewStatus) !*Host {
        var scene_identity: ?content_identity.ContentIdentity = null;
        const scene = if (scene_path) |path| blk: {
            const loaded = try scene_api.loadWithIdentity(io, std.heap.page_allocator, path);
            scene_identity = loaded.identity;
            // `.scene` 是运行时消费的 KSCN 二进制；JSON 仍保留原日志和兼容路径，
            // 让作者态热重载可以继续直接读取 source document。
            if (std.ascii.endsWithIgnoreCase(path, ".scene")) {
                std.log.info("Loaded preview scene artifact: {s}, artifact_version={d}", .{ path, loaded.artifact_version orelse unreachable });
            } else {
                std.log.info("Loaded preview scene: {s}", .{path});
            }
            break :blk loaded.value;
        } else blk: {
            std.log.info("Using built-in preview scene", .{});
            break :blk scene_api.default_scene;
        };
        var script_identity: ?content_identity.ContentIdentity = null;
        var script_program = script_api.Program{};
        var behavior_candidate: ?behavior_host.Runtime = null;
        errdefer if (behavior_candidate) |*runtime| runtime.deinit();
        if (usesBehaviorRuntime(&scene)) {
            if (script_path) |path| {
                const loaded = try behavior_host.loadWithIdentity(io, std.heap.page_allocator, path, &scene);
                script_identity = loaded.identity;
                behavior_candidate = loaded.value;
                std.log.info("Loaded behavior package: {s}, artifact_version={d}", .{ path, loaded.artifact_version });
            } else if (sceneHasBehaviors(&scene)) {
                return error.MissingScriptPath;
            }
        } else if (script_path) |path| {
            const loaded = try script_api.loadWithIdentity(io, std.heap.page_allocator, path);
            script_identity = loaded.identity;
            script_program = loaded.value;
            if (std.ascii.endsWithIgnoreCase(path, ".script")) {
                std.log.info("Loaded script artifact: {s}, artifact_version={d}, instructions={d}", .{ path, script_api.script_artifact_version, loaded.value.count });
            } else {
                std.log.info("Loaded script hook program: {s}, instructions={d}", .{ path, loaded.value.count });
            }
        }

        var prepared_textures = try runtime_texture_registry.prepareScene(io, std.heap.page_allocator, &scene);
        defer prepared_textures.deinit();

        var platform = try Platform.init();
        errdefer platform.deinit();

        const extent = platform.clientExtent();
        var backend = try Rhi.init(
            platform.nativeSurface(),
            .{ .width = extent.width, .height = extent.height },
        );
        errdefer backend.deinit();

        var renderer2d = try Renderer2D.init(&backend);
        errdefer renderer2d.deinit(&backend);

        var texture_registry = try runtime_texture_registry.RuntimeTextureRegistry.initPrepared(
            std.heap.page_allocator,
            &renderer2d,
            &backend,
            &prepared_textures,
        );
        errdefer texture_registry.deinit(&backend);
        try validateSceneTextureBindings(&texture_registry, &scene);

        var generation = try scene_generation_api.SceneGeneration.prepare(&scene, extent);
        errdefer generation.deinit();

        const self = try std.heap.page_allocator.create(Host);
        errdefer std.heap.page_allocator.destroy(self);
        self.* = .{
            .io = io,
            .preview_status = preview_status,
            .initial_loaded = .{
                .scene = initialLoadedTarget(scene_identity),
                .script = initialLoadedTarget(script_identity),
            },
            .scene = scene,
            .scene_path = scene_path,
            .script_path = script_path,
            .script_program = script_program,
            .script_enabled = script_program.hasInstructions(),
            .script_tick = 0,
            .behavior_runtime = behavior_candidate orelse .{},
            .platform = platform,
            .rhi = backend,
            .renderer2d = renderer2d,
            .audio = audio_api.Audio.init(io, std.heap.page_allocator),
            .texture_registry = undefined,
            .generation = generation,
            .world_extent = extent,
        };
        behavior_candidate = null;
        errdefer self.behavior_runtime.deinit();
        const now = self.platform.nowSeconds();
        self.last_time_seconds = now;
        self.last_heartbeat_seconds = now;
        try self.resetScript();
        self.texture_registry = texture_registry.take();
        std.log.info("Runtime host initialized with Vulkan RHI scene objects={d}, player={d}, goal={d}", .{
            scene.objects.count,
            self.generation.playerEntity(),
            self.generation.goalEntity(),
        });
        return self;
    }

    pub fn initialLoaded(self: *const Host) preview_status_api.InitialLoaded {
        return self.initial_loaded;
    }
    pub fn deinit(self: *Host) void {
        self.texture_registry.deinit(&self.rhi);
        self.audio.deinit();
        self.behavior_runtime.deinit();
        self.generation.deinit();
        self.renderer2d.deinit(&self.rhi);
        self.rhi.deinit();
        self.platform.deinit();
        std.log.info("Kadath runtime shutdown complete", .{});
    }

    pub fn destroy(self: *Host) void {
        self.deinit();
        std.heap.page_allocator.destroy(self);
    }

    fn processReloadCommand(self: *Host, command: preview_status_api.Command, request_id: ?u64) void {
        self.preview_status.commandReceived(command, request_id);
        switch (command) {
            .reload_scene => self.reloadScene() catch |err| {
                // 结构化响应只包住事务边界；旧 World 保持为 Runtime 的权威状态。
                self.preview_status.commandRejected(command, request_id, err);
                std.log.err("Scene reload rejected; keeping current scene: {s}", .{@errorName(err)});
                return;
            },
            .reload_script => self.reloadScript() catch |err| {
                // 非法 Program 不会替换当前脚本；响应携带稳定 errorCode 供 Launcher 消费。
                self.preview_status.commandRejected(command, request_id, err);
                std.log.err("Script reload rejected; keeping current program: {s}", .{@errorName(err)});
                return;
            },
            .shutdown => unreachable,
        }
        self.preview_status.commandSucceeded(command, request_id);
    }

    pub const ExitReason = enum {
        window_close,
        control_shutdown,
    };

    pub fn run(self: *Host, preview_control: *preview_control_api.PreviewControl) !ExitReason {
        std.log.info("Runtime main loop entered", .{});

        while (!self.quit_requested) {
            while (preview_control.poll()) |command| {
                switch (command.kind) {
                    .reload_scene => self.processReloadCommand(.reload_scene, command.request_id),
                    .reload_script => self.processReloadCommand(.reload_script, command.request_id),
                    .shutdown => {
                        self.preview_status.commandReceived(.shutdown, command.request_id);
                        self.preview_status.commandSucceeded(.shutdown, command.request_id);
                        self.quit_requested = true;
                        std.log.info("Runtime control shutdown requested", .{});
                        return .control_shutdown;
                    },
                }
            }
            const events = self.platform.pumpEvents();
            if (events.quit_requested) {
                self.quit_requested = true;
                std.log.info("Runtime exit requested", .{});
                return .window_close;
            }
            if (events.scene_reload_request_id) |request_id| {
                self.processReloadCommand(.reload_scene, request_id);
            } else if (events.input.reload_pressed != 0) {
                self.processReloadCommand(.reload_scene, null);
            }
            if (events.script_reload_request_id) |request_id| {
                self.processReloadCommand(.reload_script, request_id);
            } else if (events.input.script_reload_pressed != 0) {
                self.processReloadCommand(.reload_script, null);
            }
            if (events.input.restart_pressed != 0) try self.restartGame();

            const now = self.platform.nowSeconds();
            const delta = if (now >= self.last_time_seconds)
                now - self.last_time_seconds
            else
                0.0;
            self.last_time_seconds = now;

            self.syncExternalResults();
            try self.syncWorldBounds();
            const before_fixed = try self.queryGameplaySnapshot();
            const accepts_input = try self.runFixedUpdates(
                delta,
                events.input,
                before_fixed.accepts_input != 0,
            );
            try self.runBehaviorUpdate(
                @floatCast(@min(@max(delta, 0.0), 0.25)),
                events.input,
                accepts_input,
            );
            const gameplay = try self.extractRender();

            try self.submitRender();

            self.endFrame(now, delta, @enumFromInt(gameplay.phase));
            self.platform.sleepMilliseconds(1);
        }
        return .window_close;
    }

    fn submitRender(self: *Host) !void {
        if (self.render_count == 0) return error.WorldProducedNoRenderSprite;
        const extent: PlatformExtent = self.platform.clientExtent();
        var instances: [runtime_core.max_object_count]SpriteInstance = undefined;
        for (self.render_sprites[0..self.render_count], 0..) |sprite, index| {
            instances[index] = .{
                .position = sprite.position,
                .size = sprite.size,
                .color = sprite.final_color,
                .texture = try self.texture_registry.resolve(sprite.texture_id),
            };
        }
        const outcome = try self.renderer2d.renderSprites(
            &self.rhi,
            .{ .width = extent.width, .height = extent.height },
            instances[0..self.render_count],
        );
        if (outcome == .recreated) {
            std.log.debug("Renderer2D swapchain recreation completed", .{});
        }
    }

    fn syncExternalResults(self: *Host) void {
        const outcome = self.texture_registry.pollRefresh(&self.renderer2d, &self.rhi) orelse return;
        switch (outcome) {
            .applied => std.log.info("Async texture set refresh applied", .{}),
            .failed => |failure| switch (failure.reason) {
                .resource => |reason| std.log.err("Async texture set refresh failed: texture_id={d}, key={s}, stage={s}, reason={s}; keeping old set", .{
                    failure.texture_id,
                    failure.artifact_key,
                    @tagName(failure.stage),
                    @tagName(reason),
                }),
                .runtime => |err| std.log.err("Async texture set refresh failed: texture_id={d}, key={s}, stage={s}, reason={s}; keeping old set", .{
                    failure.texture_id,
                    failure.artifact_key,
                    @tagName(failure.stage),
                    @errorName(err),
                }),
            },
        }
    }

    fn resetScript(self: *Host) !void {
        if (usesBehaviorRuntime(&self.scene)) {
            if (!self.behavior_runtime.isLoaded()) return;
            const batch = try self.behavior_runtime.onStart(&self.generation);
            try self.generation.applyTranslationDeltas(batch.slice());
            try self.behavior_runtime.publishStartupEvents(&self.generation, &batch);
            var sprites: [runtime_core.max_object_count]runtime_core.RenderSprite = undefined;
            const ordered = (try self.generation.extractSprites(&sprites)).sprites;
            const player_entity = self.generation.playerEntity();
            const player = for (ordered) |sprite| {
                if (sprite.entity_value == player_entity) break sprite;
            } else return error.WorldProducedNoPlayerSprite;
            std.log.info("Behavior on_start hooks applied: player_position=({d:.2},{d:.2})", .{ player.position[0], player.position[1] });
            return;
        }
        self.script_tick = 0;
        self.script_enabled = self.script_program.hasInstructions();
        try self.setGoalPosition(self.scene.goal().sprite.position);
        if (!self.script_enabled) return;

        var command_buffer: script_api.CommandBuffer = undefined;
        const commands = try self.script_program.emit(.on_start, 0.0, &command_buffer);
        try self.applyScriptCommands(commands);
        std.log.info("Script on_start hook applied: commands={d}", .{commands.len});
    }

    fn runScriptFixed(self: *Host, dt_seconds: f32) void {
        if (!self.script_enabled) return;
        var command_buffer: script_api.CommandBuffer = undefined;
        const commands = self.script_program.emit(.fixed_update, dt_seconds, &command_buffer) catch |err| {
            self.disableScript(err);
            return;
        };
        self.applyScriptCommands(commands) catch |err| {
            self.disableScript(err);
            return;
        };
        if (self.script_tick == 0) {
            std.log.info("Script fixed_update hook entered: commands={d}", .{commands.len});
        }
        self.script_tick +|= 1;
    }

    fn runBehaviorFixed(self: *Host, dt_seconds: f32, input: InputSnapshot) !void {
        if (!self.behavior_runtime.isLoaded()) return;
        try self.behavior_runtime.runFixed(
            &self.generation,
            dt_seconds,
            .{ .move_x = input.move_x, .move_y = input.move_y },
        );
    }

    fn runBehaviorUpdate(self: *Host, dt_seconds: f32, input: InputSnapshot, accepts_input: bool) !void {
        if (!usesBehaviorRuntime(&self.scene) or !self.behavior_runtime.isLoaded()) return;
        const frame_input = if (accepts_input) input else InputSnapshot{};
        try self.behavior_runtime.runUpdate(
            &self.generation,
            dt_seconds,
            .{ .move_x = frame_input.move_x, .move_y = frame_input.move_y },
        );
        try self.behavior_runtime.finishFrame(
            &self.generation,
            .{ .move_x = frame_input.move_x, .move_y = frame_input.move_y },
        );
    }

    fn disableScript(self: *Host, err: anyerror) void {
        self.script_enabled = false;
        std.log.err("Script hook disabled; Runtime continues: {s}", .{@errorName(err)});
    }

    fn applyScriptCommands(self: *Host, commands: []const script_api.Command) !void {
        for (commands) |command| {
            switch (command) {
                .set_goal_position => |position| try self.setGoalPosition(position),
                .translate_goal => |delta| try self.setGoalPosition(.{
                    self.generation.goalPosition()[0] + delta[0],
                    self.generation.goalPosition()[1] + delta[1],
                }),
            }
        }
    }

    fn setGoalPosition(self: *Host, position: [2]f32) !void {
        try self.generation.setGoalPosition(position);
    }

    fn reloadScript(self: *Host) !void {
        const path = self.script_path orelse {
            std.log.warn("Script reload requested but no --script path was supplied", .{});
            return error.MissingScriptPath;
        };
        if (usesBehaviorRuntime(&self.scene)) {
            var candidate = (try behavior_host.loadWithIdentity(
                self.io,
                std.heap.page_allocator,
                path,
                &self.scene,
            )).value;
            errdefer candidate.deinit();
            const batch = try candidate.onStart(&self.generation);
            try self.generation.applyTranslationDeltas(batch.slice());
            try candidate.preparePhaseState(&self.generation);
            try candidate.commitPhaseState(&self.generation);
            var previous = self.behavior_runtime;
            self.behavior_runtime = candidate;
            previous.deinit();
            try self.behavior_runtime.publishStartupEvents(&self.generation, &batch);
            std.log.info("Behavior package reloaded explicitly", .{});
            return;
        }

        const candidate = try script_api.load(self.io, std.heap.page_allocator, path);
        const previous_program = self.script_program;
        const previous_enabled = self.script_enabled;
        const previous_tick = self.script_tick;
        const previous_goal_position = self.generation.goalPosition();

        // 关键事务边界：候选 Program 解析成功后再激活；激活失败恢复旧 Program 与 Goal 状态。
        self.script_program = candidate;
        self.resetScript() catch |err| {
            self.script_program = previous_program;
            self.script_enabled = previous_enabled;
            self.script_tick = previous_tick;
            self.setGoalPosition(previous_goal_position) catch |restore_err| {
                self.disableScript(restore_err);
                return restore_err;
            };
            return err;
        };
        std.log.info("Script reloaded explicitly: instructions={d}", .{candidate.count});
    }

    fn reloadScene(self: *Host) !void {
        const path = self.scene_path orelse {
            std.log.warn("Scene reload requested but no --scene path was supplied", .{});
            return error.MissingScenePath;
        };
        const candidate = try scene_api.load(self.io, std.heap.page_allocator, path);
        var prepared_textures = try runtime_texture_registry.prepareScene(self.io, std.heap.page_allocator, &candidate);
        defer prepared_textures.deinit();
        var candidate_registry = try runtime_texture_registry.RuntimeTextureRegistry.initPrepared(
            std.heap.page_allocator,
            &self.renderer2d,
            &self.rhi,
            &prepared_textures,
        );
        errdefer candidate_registry.deinit(&self.rhi);
        try validateSceneTextureBindings(&candidate_registry, &candidate);
        var replacement = try scene_generation_api.SceneGeneration.prepareSceneReload(&candidate, self.world_extent, &self.generation);
        errdefer replacement.deinit();
        var candidate_behavior = behavior_host.Runtime{};
        errdefer candidate_behavior.deinit();
        var candidate_startup: ?behavior_host.TranslationBatch = null;
        var candidate_program = script_api.Program{};
        var candidate_script_enabled = false;
        if (usesBehaviorRuntime(&candidate)) {
            if (self.behavior_runtime.isLoaded()) {
                candidate_behavior = try self.behavior_runtime.cloneForSceneReload(std.heap.page_allocator, &candidate);
            } else if (sceneHasBehaviors(&candidate)) {
                const script_path = self.script_path orelse return error.MissingScriptPath;
                candidate_behavior = (try behavior_host.loadWithIdentity(
                    self.io,
                    std.heap.page_allocator,
                    script_path,
                    &candidate,
                )).value;
            }
            if (candidate_behavior.isLoaded()) {
                const batch = try candidate_behavior.onStart(&replacement);
                try replacement.applyTranslationDeltas(batch.slice());
                candidate_startup = batch;
            }
        } else if (self.script_path) |script_path| {
            candidate_program = try script_api.load(self.io, std.heap.page_allocator, script_path);
            candidate_script_enabled = candidate_program.hasInstructions();
            if (candidate_script_enabled) {
                var command_buffer: script_api.CommandBuffer = undefined;
                const commands = try candidate_program.emit(.on_start, 0.0, &command_buffer);
                try applyScriptCommandsToGeneration(&replacement, commands);
            }
        }
        if (candidate_behavior.isLoaded()) {
            try candidate_behavior.preparePhaseState(&replacement);
            try candidate_behavior.commitPhaseState(&replacement);
        }
        try replacement.commitPrepared(&self.generation);
        var previous_generation = self.generation;
        var previous_registry = self.texture_registry;
        var previous_behavior = self.behavior_runtime;
        self.generation = replacement;
        self.texture_registry = candidate_registry.take();
        self.behavior_runtime = candidate_behavior;
        self.script_program = candidate_program;
        self.script_enabled = candidate_script_enabled;
        self.script_tick = 0;
        self.scene = candidate;
        self.accumulator_seconds = 0.0;
        self.render_count = 0;
        previous_generation.deinit();
        previous_registry.deinit(&self.rhi);
        previous_behavior.deinit();
        if (candidate_startup) |*startup| try self.behavior_runtime.publishStartupEvents(&self.generation, startup);
        std.log.info("Scene reloaded explicitly: objects={d}, player={d}, goal={d}", .{
            candidate.objects.count,
            self.generation.playerEntity(),
            self.generation.goalEntity(),
        });
    }

    fn restartGame(self: *Host) !void {
        const snapshot = try self.queryGameplaySnapshot();
        if (snapshot.phase == @intFromEnum(runtime_core.GameplayPhase.playing)) return;
        if (usesBehaviorRuntime(&self.scene)) {
            if (!self.behavior_runtime.isLoaded()) {
                try self.generation.reset();
                self.accumulator_seconds = 0.0;
                self.render_count = 0;
                std.log.info("Game session restarted without behavior package", .{});
                return;
            }
            var replacement = try scene_generation_api.SceneGeneration.prepareRestart(
                &self.scene,
                self.world_extent,
                &self.generation,
            );
            errdefer replacement.deinit();
            var candidate = try self.behavior_runtime.cloneForRestart(std.heap.page_allocator, &self.scene);
            errdefer candidate.deinit();
            const batch = try candidate.onStart(&replacement);
            try replacement.applyTranslationDeltas(batch.slice());
            try candidate.preparePhaseState(&replacement);
            try candidate.commitPhaseState(&replacement);
            try replacement.commitPrepared(&self.generation);
            var previous_generation = self.generation;
            var previous_behavior = self.behavior_runtime;
            self.generation = replacement;
            self.behavior_runtime = candidate;
            previous_generation.deinit();
            previous_behavior.deinit();
            try self.behavior_runtime.publishStartupEvents(&self.generation, &batch);
        } else {
            try self.generation.reset();
            self.resetScript() catch |err| self.disableScript(err);
        }
        self.accumulator_seconds = 0.0;
        self.render_count = 0;
        std.log.info("Game session restarted: entity={d}, position=({d:.2},{d:.2})", .{
            self.generation.playerEntity(),
            self.scene.player().sprite.position[0],
            self.scene.player().sprite.position[1],
        });
    }

    fn syncWorldBounds(self: *Host) !void {
        const extent = self.platform.clientExtent();
        // 最小化时客户区可能为零；保留最后一个有效边界，等待恢复后的真实尺寸。
        if (extent.width == 0 or extent.height == 0 or
            (extent.width == self.world_extent.width and extent.height == self.world_extent.height))
        {
            return;
        }
        try self.generation.setExtent(extent);
        self.world_extent = extent;
    }

    fn runFixedUpdates(self: *Host, delta_seconds: f64, input: InputSnapshot, initial_accepts_input: bool) !bool {
        // 限制单帧可累积时间，避免暂停/调试断点后进入死亡螺旋。
        self.accumulator_seconds += @min(delta_seconds, 0.25);
        var accepts_input = initial_accepts_input;
        var steps: u8 = 0;
        while (self.accumulator_seconds >= fixed_dt_seconds and steps < max_fixed_steps_per_frame) : (steps += 1) {
            var outcome: runtime_core.GameplayOutcome = undefined;
            const begin = try self.generation.beginGameplayFixed(@floatCast(fixed_dt_seconds), &outcome);
            var gameplay_committed = false;
            errdefer if (!gameplay_committed) self.generation.core.abortGameplayFixed(begin.step_token) catch {};
            accepts_input = begin.accepts_input != 0;
            if (begin.outcome_count == 1) self.consumeGameplayOutcome(outcome);
            const step_input = if (begin.accepts_input != 0) input else InputSnapshot{};
            const routed_input = player_movement_ownership.route(&self.scene, .{
                .move_x = step_input.move_x,
                .move_y = step_input.move_y,
            });
            if (usesBehaviorRuntime(&self.scene)) {
                try self.runBehaviorFixed(@floatCast(fixed_dt_seconds), .{
                    .move_x = @intCast(routed_input.behaviors.move_x),
                    .move_y = @intCast(routed_input.behaviors.move_y),
                });
            } else {
                // Legacy fixed scripts have no input parameter, but their
                // direct mutation commands still run after terminal state.
                self.runScriptFixed(@floatCast(fixed_dt_seconds));
            }
            if (!usesBehaviorRuntime(&self.scene) or !self.behavior_runtime.isLoaded()) {
                try self.generation.core.beginPhase(.fixed, begin.step_token);
            }
            const committed = self.generation.commitGameplayFixed(begin.step_token, .{
                .move_x = routed_input.world.move_x,
                .move_y = routed_input.world.move_y,
            }, &outcome) catch |err| {
                self.generation.core.abortGameplayFixed(begin.step_token) catch {};
                return err;
            };
            gameplay_committed = true;
            accepts_input = committed.accepts_input != 0;
            if (committed.outcome_count == 1) self.consumeGameplayOutcome(outcome);
            if (usesBehaviorRuntime(&self.scene) and self.behavior_runtime.isLoaded()) {
                try self.behavior_runtime.finishFixedStep(
                    &self.generation,
                    .{
                        .move_x = @intCast(routed_input.behaviors.move_x),
                        .move_y = @intCast(routed_input.behaviors.move_y),
                    },
                );
            } else {
                var drained: [runtime_core.max_phase_events]runtime_core.PhaseEvent = undefined;
                for (&drained) |*event| {
                    event.* = std.mem.zeroes(runtime_core.PhaseEvent);
                    event.struct_size = @sizeOf(runtime_core.PhaseEvent);
                }
                while (try self.generation.core.drainPhaseEvents(.fixed, begin.step_token, &drained) != 0) {}
                try self.generation.core.endPhase(.fixed, begin.step_token);
            }
            self.accumulator_seconds -= fixed_dt_seconds;
        }
        if (steps == max_fixed_steps_per_frame and self.accumulator_seconds >= fixed_dt_seconds) {
            self.accumulator_seconds = @mod(self.accumulator_seconds, fixed_dt_seconds);
        }
        return accepts_input;
    }

    fn extractRender(self: *Host) !runtime_core.GameplaySnapshot {
        const publication = try self.generation.extractSprites(&self.render_sprites);
        self.render_count = publication.sprites.len;
        return publication.snapshot;
    }

    fn queryGameplaySnapshot(self: *Host) !runtime_core.GameplaySnapshot {
        var scratch: [runtime_core.max_object_count]runtime_core.RenderSprite = undefined;
        return self.generation.core.gameplaySnapshot(&scratch);
    }

    fn consumeGameplayOutcome(self: *Host, outcome: runtime_core.GameplayOutcome) void {
        const phase: runtime_core.GameplayPhase = @enumFromInt(outcome.phase);
        const cause: runtime_core.GameplayCause = @enumFromInt(outcome.cause);
        switch (phase) {
            .won => self.audio.play(.won),
            .lost => self.audio.play(.lost),
            .playing => unreachable,
        }
        switch (cause) {
            .timer => std.log.info("Game session lost: timer expired, sequence={d}", .{outcome.sequence}),
            .hazard => std.log.info("Game session lost: player={s} hit object={s}, sequence={d}", .{
                runtime_core.objectIdSlice(&outcome.player),
                runtime_core.objectIdSlice(&outcome.other),
                outcome.sequence,
            }),
            .goal => std.log.info("Game session won: player={s} overlapped goal={s}, sequence={d}", .{
                runtime_core.objectIdSlice(&outcome.player),
                runtime_core.objectIdSlice(&outcome.other),
                outcome.sequence,
            }),
            .none => unreachable,
        }
    }

    fn renderSprite(self: *const Host, entity: runtime_core.EntityId) ?runtime_core.RenderSprite {
        for (self.render_sprites[0..self.render_count]) |sprite| {
            if (sprite.entity_value == entity) return sprite;
        }
        return null;
    }
    fn endFrame(self: *Host, now_seconds: f64, delta_seconds: f64, gameplay_phase: runtime_core.GameplayPhase) void {
        self.frame_count += 1;
        if (now_seconds - self.last_heartbeat_seconds >= 1.0) {
            if (self.render_count > 0) {
                const sprite = self.renderSprite(self.generation.playerEntity()) orelse return;
                std.log.debug("Runtime heartbeat: frame={d}, delta={d:.6}s, phase={s}, position=({d:.2},{d:.2}), hazard_y={d:.2}", .{
                    self.frame_count,
                    delta_seconds,
                    @tagName(gameplay_phase),
                    sprite.position[0],
                    sprite.position[1],
                    self.generation.primaryHazardY(),
                });
            } else {
                std.log.debug("Runtime heartbeat: frame={d}, delta={d:.6}s", .{
                    self.frame_count,
                    delta_seconds,
                });
            }
            self.last_heartbeat_seconds = now_seconds;
        }
    }
};

test "scene texture bindings must resolve before world replacement" {
    var registry = runtime_texture_registry.RuntimeTextureRegistry{
        .allocator = std.testing.allocator,
        .specs = scene_api.default_scene.textures.entries,
        .handles = [_]rhi.TextureHandle{rhi.invalid_texture} ** scene_api.max_texture_count,
        .count = scene_api.default_scene.textures.count,
    };
    var scene = scene_api.default_scene;
    try validateSceneTextureBindings(&registry, &scene);
    scene.objects.entries[0].sprite.textureId = 4;
    try std.testing.expectError(error.UnknownWorldTexture, validateSceneTextureBindings(&registry, &scene));
}

test "Scene v5 and v6 share Behavior Runtime while v4 keeps legacy scripts" {
    var scene = scene_api.default_scene;
    scene.schemaVersion = scene_api.legacy_object_schema_version;
    try std.testing.expect(!usesBehaviorRuntime(&scene));
    scene.schemaVersion = scene_api.behavior_schema_version;
    try std.testing.expect(usesBehaviorRuntime(&scene));
    scene.schemaVersion = scene_api.current_schema_version;
    try std.testing.expect(usesBehaviorRuntime(&scene));
}

fn applyScriptCommandsToGeneration(generation: *scene_generation_api.SceneGeneration, commands: []const script_api.Command) !void {
    for (commands) |command| {
        switch (command) {
            .set_goal_position => |position| try generation.setGoalPosition(position),
            .translate_goal => |delta| {
                const current = generation.goalPosition();
                try generation.setGoalPosition(.{ current[0] + delta[0], current[1] + delta[1] });
            },
        }
    }
}
