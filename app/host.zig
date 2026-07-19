const std = @import("std");
const audio_api = @import("audio");
const collision = @import("collision.zig");
const game = @import("game.zig");
const scene_api = @import("scene.zig");
const script_api = @import("script.zig");
const Platform = @import("platform").Platform;
const PlatformExtent = @import("platform").WindowExtent;
const InputSnapshot = @import("platform").InputSnapshot;
const rhi = @import("rhi");
const Rhi = rhi.Rhi;
const resource = @import("resource");
const world_api = @import("world");
const World = world_api.World;
const Renderer2D = @import("renderer2d").Renderer2D;
const SpriteInstance = @import("renderer2d").SpriteInstance;
const SpawnedScene = struct {
    world: World,
    player_entity: world_api.EntityId,
    goal_entity: world_api.EntityId,
    hazard_entity: world_api.EntityId,
};

fn clampPosition(position: [2]f32, size: [2]f32, extent: PlatformExtent) [2]f32 {
    const max_x = @max(0.0, @as(f32, @floatFromInt(extent.width)) - size[0]);
    const max_y = @max(0.0, @as(f32, @floatFromInt(extent.height)) - size[1]);
    return .{
        @min(@max(position[0], 0.0), max_x),
        @min(@max(position[1], 0.0), max_y),
    };
}

fn spawnSceneWorld(scene: *const scene_api.Scene, extent: PlatformExtent) !SpawnedScene {
    var runtime_world = try World.init();
    errdefer runtime_world.deinit();
    try runtime_world.setBounds(.{
        .min = .{ 0.0, 0.0 },
        .max = .{ @floatFromInt(extent.width), @floatFromInt(extent.height) },
    });
    const player_entity = try runtime_world.spawnSprite(playerSpawnDesc(scene));
    const goal_entity = try runtime_world.spawnSprite(goalSpawnDesc(scene));
    const hazard_entity = try runtime_world.spawnSprite(hazardSpawnDesc(scene));
    return .{
        .world = runtime_world,
        .player_entity = player_entity,
        .goal_entity = goal_entity,
        .hazard_entity = hazard_entity,
    };
}

const test_texture_id: world_api.TextureId = 1;
const fixed_dt_seconds: f64 = 1.0 / 60.0;
const max_fixed_steps_per_frame: u8 = 4;

fn playerSpawnDesc(scene: *const scene_api.Scene) world_api.SpriteSpawnDesc {
    return .{
        .position = scene.player.position,
        .size = scene.player.size,
        .color = scene.player.color,
        .texture_id = test_texture_id,
        .move_speed = scene.player.moveSpeed,
    };
}

fn goalSpawnDesc(scene: *const scene_api.Scene) world_api.SpriteSpawnDesc {
    return .{
        .position = scene.goal.position,
        .size = scene.goal.size,
        .color = scene.goal.color,
        .texture_id = test_texture_id,
        .move_speed = 0.0,
    };
}

fn hazardSpawnDesc(scene: *const scene_api.Scene) world_api.SpriteSpawnDesc {
    return .{
        .position = scene.hazard.position,
        .size = scene.hazard.size,
        .color = scene.hazard.color,
        .texture_id = test_texture_id,
        .move_speed = 0.0,
    };
}

pub const Host = struct {
    io: std.Io,
    scene: scene_api.Scene,
    scene_path: ?[]const u8,
    script_program: script_api.Program,
    script_enabled: bool,
    script_tick: u64,
    goal_position: [2]f32,
    platform: Platform,
    rhi: Rhi,
    renderer2d: Renderer2D,
    audio: audio_api.Audio,
    texture: rhi.TextureHandle,
    world: World,
    sprite_entity: world_api.EntityId,
    goal_entity: world_api.EntityId,
    hazard_entity: world_api.EntityId,
    hazard_y: f32,
    hazard_direction: f32,
    world_extent: PlatformExtent,
    session: game.GameSession = .{},
    render_sprites: [3]world_api.RenderSprite = undefined,
    render_count: usize = 0,
    quit_requested: bool = false,
    last_time_seconds: f64 = 0.0,
    accumulator_seconds: f64 = 0.0,
    frame_count: u64 = 0,
    last_heartbeat_seconds: f64 = 0.0,

    pub fn init(io: std.Io, scene_path: ?[]const u8, script_path: ?[]const u8) !Host {
        const scene = if (scene_path) |path| blk: {
            const loaded = try scene_api.load(io, std.heap.page_allocator, path);
            std.log.info("Loaded preview scene: {s}", .{path});
            break :blk loaded;
        } else blk: {
            std.log.info("Using built-in preview scene", .{});
            break :blk scene_api.default_scene;
        };
        const script_program = if (script_path) |path| blk: {
            const loaded = try script_api.load(io, std.heap.page_allocator, path);
            std.log.info("Loaded script hook program: {s}, instructions={d}", .{ path, loaded.count });
            break :blk loaded;
        } else script_api.Program{};

        var platform = try Platform.init();
        errdefer platform.deinit();

        const extent = platform.clientExtent();
        var backend = try Rhi.init(
            platform.nativeWindowHandle(),
            platform.nativeInstanceHandle(),
            .{ .width = extent.width, .height = extent.height },
        );
        errdefer backend.deinit();

        var renderer2d = try Renderer2D.init(&backend);
        errdefer renderer2d.deinit(&backend);

        var texture_data = try resource.loadPpm3(io, std.heap.page_allocator, "assets/renderer2d/test.ppm");
        defer texture_data.deinit(std.heap.page_allocator);
        const texture = try backend.createTexture(.{
            .width = texture_data.width,
            .height = texture_data.height,
            .rgba8 = texture_data.pixels_rgba8,
        });
        errdefer backend.destroyTexture(texture);

        const spawned = try spawnSceneWorld(&scene, extent);
        var runtime_world = spawned.world;
        errdefer runtime_world.deinit();

        var self = Host{
            .io = io,
            .scene = scene,
            .scene_path = scene_path,
            .script_program = script_program,
            .script_enabled = script_program.hasInstructions(),
            .script_tick = 0,
            .goal_position = clampPosition(scene.goal.position, scene.goal.size, extent),
            .platform = platform,
            .rhi = backend,
            .renderer2d = renderer2d,
            .audio = audio_api.Audio.init(),
            .texture = texture,
            .world = runtime_world,
            .sprite_entity = spawned.player_entity,
            .goal_entity = spawned.goal_entity,
            .hazard_entity = spawned.hazard_entity,
            .hazard_y = scene.hazard.position[1],
            .hazard_direction = 1.0,
            .world_extent = extent,
            .session = .{},
        };
        const now = self.platform.nowSeconds();
        self.last_time_seconds = now;
        self.last_heartbeat_seconds = now;
        try self.resetScript();
        std.log.info("Runtime host initialized with Vulkan RHI entities: player={d}, goal={d}, hazard={d}", .{
            spawned.player_entity,
            spawned.goal_entity,
            spawned.hazard_entity,
        });
        return self;
    }
    pub fn deinit(self: *Host) void {
        self.audio.deinit();
        self.world.despawn(self.sprite_entity) catch |err| {
            std.log.err("World sprite despawn failed: {s}", .{@errorName(err)});
        };
        self.world.despawn(self.goal_entity) catch |err| {
            std.log.err("World goal despawn failed: {s}", .{@errorName(err)});
        };
        self.world.despawn(self.hazard_entity) catch |err| {
            std.log.err("World hazard despawn failed: {s}", .{@errorName(err)});
        };
        self.world.deinit();
        self.rhi.destroyTexture(self.texture);
        self.renderer2d.deinit(&self.rhi);
        self.rhi.deinit();
        self.platform.deinit();
        std.log.info("Kadath runtime shutdown complete", .{});
    }

    pub fn run(self: *Host) !void {
        std.log.info("Runtime main loop entered", .{});

        while (!self.quit_requested) {
            const events = self.platform.pumpEvents();
            if (events.quit_requested) {
                self.quit_requested = true;
                std.log.info("Runtime exit requested", .{});
                break;
            }
            if (events.input.reload_pressed != 0) {
                self.reloadScene() catch |err| {
                    // reload 失败不终止当前 Runtime；旧 World 仍是可运行的事务提交结果。
                    std.log.err("Scene reload rejected; keeping current scene: {s}", .{@errorName(err)});
                };
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
            try self.runFixedUpdates(delta, events.input);
            try self.extractRender();

            try self.submitRender();

            self.endFrame(now, delta);
            self.platform.sleepMilliseconds(1);
        }
    }

    fn submitRender(self: *Host) !void {
        if (self.render_count == 0) return error.WorldProducedNoRenderSprite;
        const extent: PlatformExtent = self.platform.clientExtent();
        const goal = self.renderSprite(self.goal_entity) orelse return error.WorldProducedNoGoalSprite;
        const hazard = self.renderSprite(self.hazard_entity) orelse return error.WorldProducedNoHazardSprite;
        const player = self.renderSprite(self.sprite_entity) orelse return error.WorldProducedNoPlayerSprite;
        _ = try self.resolveTexture(goal.texture_id);
        _ = try self.resolveTexture(hazard.texture_id);
        _ = try self.resolveTexture(player.texture_id);
        // 固定目标、Hazard 先画，玩家后画，避免重开后的 slot 顺序改变可见层级。
        const instances = [_]SpriteInstance{
            .{
                .position = goal.position,
                .size = goal.size,
                .color = goal.color,
            },
            .{
                .position = hazard.position,
                .size = hazard.size,
                .color = hazard.color,
            },
            .{
                .position = player.position,
                .size = player.size,
                .color = switch (self.session.phase) {
                    .won => .{ 0.20, 0.95, 0.35, 1.0 },
                    .lost => .{ 0.95, 0.20, 0.20, 1.0 },
                    .playing => player.color,
                },
            },
        };
        const outcome = try self.renderer2d.renderSprites(
            &self.rhi,
            .{ .width = extent.width, .height = extent.height },
            instances[0..],
            self.texture,
        );
        if (outcome == .recreated) {
            std.log.debug("Renderer2D swapchain recreation completed", .{});
        }
    }

    fn syncExternalResults(self: *Host) void {
        _ = self;
    }

    fn resetScript(self: *Host) !void {
        self.script_tick = 0;
        self.script_enabled = self.script_program.hasInstructions();
        try self.setGoalPosition(self.scene.goal.position);
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

    fn disableScript(self: *Host, err: anyerror) void {
        self.script_enabled = false;
        std.log.err("Script hook disabled; Runtime continues: {s}", .{@errorName(err)});
    }

    fn applyScriptCommands(self: *Host, commands: []const script_api.Command) !void {
        for (commands) |command| {
            switch (command) {
                .set_goal_position => |position| try self.setGoalPosition(position),
                .translate_goal => |delta| try self.setGoalPosition(.{
                    self.goal_position[0] + delta[0],
                    self.goal_position[1] + delta[1],
                }),
            }
        }
    }

    fn setGoalPosition(self: *Host, position: [2]f32) !void {
        self.goal_position = clampPosition(position, self.scene.goal.size, self.world_extent);
        try self.world.setSpritePosition(self.goal_entity, self.goal_position);
    }

    fn reloadScene(self: *Host) !void {
        const path = self.scene_path orelse {
            std.log.warn("Scene reload requested but no --scene path was supplied", .{});
            return;
        };
        const candidate = try scene_api.load(self.io, std.heap.page_allocator, path);
        // 关键事务边界：完整新 World 成功后才替换旧 World，解析/创建失败不会破坏当前运行场景。
        const replacement = try spawnSceneWorld(&candidate, self.world_extent);
        var previous_world = self.world;
        self.world = replacement.world;
        self.scene = candidate;
        self.sprite_entity = replacement.player_entity;
        self.goal_entity = replacement.goal_entity;
        self.hazard_entity = replacement.hazard_entity;
        self.goal_position = clampPosition(candidate.goal.position, candidate.goal.size, self.world_extent);
        self.hazard_y = candidate.hazard.position[1];
        self.hazard_direction = 1.0;
        self.session = .{};
        self.accumulator_seconds = 0.0;
        self.render_count = 0;
        previous_world.deinit();
        self.resetScript() catch |err| self.disableScript(err);
        std.log.info("Scene reloaded explicitly: player={d}, goal={d}, hazard={d}", .{
            self.sprite_entity,
            self.goal_entity,
            self.hazard_entity,
        });
    }

    fn restartGame(self: *Host) !void {
        if (self.session.phase == .playing) return;

        // 先创建替代实体；spawn 失败时旧玩家仍完整保留，不会留下空世界。
        const previous_entity = self.sprite_entity;
        const replacement_entity = try self.world.spawnSprite(playerSpawnDesc(&self.scene));
        errdefer self.world.despawn(replacement_entity) catch {};
        try self.world.despawn(previous_entity);

        self.sprite_entity = replacement_entity;
        self.hazard_y = self.scene.hazard.position[1];
        self.hazard_direction = 1.0;
        try self.world.setSpritePosition(self.hazard_entity, self.scene.hazard.position);
        std.debug.assert(self.session.restart());
        self.accumulator_seconds = 0.0;
        self.render_count = 0;
        self.resetScript() catch |err| self.disableScript(err);
        std.log.info("Game session restarted: entity={d}, position=({d:.2},{d:.2})", .{
            replacement_entity,
            self.scene.player.position[0],
            self.scene.player.position[1],
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
        try self.world.setBounds(.{
            .min = .{ 0.0, 0.0 },
            .max = .{ @floatFromInt(extent.width), @floatFromInt(extent.height) },
        });
        self.world_extent = extent;
        try self.setGoalPosition(self.goal_position);
    }

    fn runFixedUpdates(self: *Host, delta_seconds: f64, input: InputSnapshot) !void {
        // 限制单帧可累积时间，避免暂停/调试断点后进入死亡螺旋。
        self.accumulator_seconds += @min(delta_seconds, 0.25);
        var steps: u8 = 0;
        while (self.accumulator_seconds >= fixed_dt_seconds and steps < max_fixed_steps_per_frame) : (steps += 1) {
            if (self.session.tickFixed(@floatCast(fixed_dt_seconds))) {
                self.audio.play(.lost);
                std.log.info("Game session lost: timer expired", .{});
            }
            if (self.session.acceptsInput()) try self.stepHazard(@floatCast(fixed_dt_seconds));
            const step_input = if (self.session.acceptsInput()) input else InputSnapshot{};
            try self.world.stepFixed(@floatCast(fixed_dt_seconds), .{
                .move_x = step_input.move_x,
                .move_y = step_input.move_y,
            });
            if (self.session.acceptsInput()) self.runScriptFixed(@floatCast(fixed_dt_seconds));
            self.accumulator_seconds -= fixed_dt_seconds;
        }
        if (steps == max_fixed_steps_per_frame and self.accumulator_seconds >= fixed_dt_seconds) {
            self.accumulator_seconds = @mod(self.accumulator_seconds, fixed_dt_seconds);
        }
    }

    fn stepHazard(self: *Host, dt_seconds: f32) !void {
        self.hazard_y += self.hazard_direction * self.scene.hazard.patrolSpeed * dt_seconds;
        if (self.hazard_y > self.scene.hazard.patrolMaxY) {
            self.hazard_y = self.scene.hazard.patrolMaxY - (self.hazard_y - self.scene.hazard.patrolMaxY);
            self.hazard_direction = -1.0;
        } else if (self.hazard_y < self.scene.hazard.patrolMinY) {
            self.hazard_y = self.scene.hazard.patrolMinY + (self.scene.hazard.patrolMinY - self.hazard_y);
            self.hazard_direction = 1.0;
        }
        // 巡逻状态由 Host 驱动，最终位置仍通过 World 受控 setter 提交。
        try self.world.setSpritePosition(self.hazard_entity, .{ self.scene.hazard.position[0], self.hazard_y });
    }

    fn extractRender(self: *Host) !void {
        // World 只写入稳定 POD 快照；渲染提交阶段不读取 World 内部存储。
        const sprites = try self.world.extractSprites(&self.render_sprites);
        self.render_count = sprites.len;

        const player = self.collisionBody(self.sprite_entity) orelse return error.WorldProducedNoPlayerSprite;
        const hazard = self.collisionBody(self.hazard_entity) orelse return error.WorldProducedNoHazardSprite;
        // 失败判定优先，避免同帧同时接触 Hazard/Goal 时被误判为成功。
        if (self.session.observeHazard(player, hazard)) {
            self.audio.play(.lost);
            std.log.info("Game session lost: player={d} hit hazard={d}", .{ self.sprite_entity, self.hazard_entity });
        }
        if (self.session.phase == .playing) {
            const goal = self.collisionBody(self.goal_entity) orelse return error.WorldProducedNoGoalSprite;
            if (self.session.observeGoal(player, goal)) {
                self.audio.play(.won);
                std.log.info("Game session won: player={d} overlapped goal={d}", .{ self.sprite_entity, self.goal_entity });
            }
        }
    }

    fn resolveTexture(self: *Host, texture_id: world_api.TextureId) !rhi.TextureHandle {
        // 逻辑资源身份在 Host 边界映射为 GPU handle，禁止泄漏到 World。
        if (texture_id != test_texture_id) return error.UnknownWorldTexture;
        return self.texture;
    }

    fn renderSprite(self: *const Host, entity: world_api.EntityId) ?world_api.RenderSprite {
        for (self.render_sprites[0..self.render_count]) |sprite| {
            if (sprite.entity_id == entity) return sprite;
        }
        return null;
    }
    fn collisionBody(self: *const Host, entity: world_api.EntityId) ?collision.Body {
        const sprite = self.renderSprite(entity) orelse return null;
        // 关键映射：玩法碰撞只消费 World 快照值，不持有 World 或 Renderer2D 内部状态。
        return .{
            .entity_id = entity,
            .aabb = .{
                .position = sprite.position,
                .size = sprite.size,
            },
        };
    }

    fn endFrame(self: *Host, now_seconds: f64, delta_seconds: f64) void {
        self.frame_count += 1;
        if (now_seconds - self.last_heartbeat_seconds >= 1.0) {
            if (self.render_count > 0) {
                const sprite = self.renderSprite(self.sprite_entity) orelse return;
                std.log.debug("Runtime heartbeat: frame={d}, delta={d:.6}s, phase={s}, position=({d:.2},{d:.2}), hazard_y={d:.2}", .{
                    self.frame_count,
                    delta_seconds,
                    @tagName(self.session.phase),
                    sprite.position[0],
                    sprite.position[1],
                    self.hazard_y,
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
