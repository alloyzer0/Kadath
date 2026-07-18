const std = @import("std");
const game = @import("game.zig");
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

const test_texture_id: world_api.TextureId = 1;
const fixed_dt_seconds: f64 = 1.0 / 60.0;
const max_fixed_steps_per_frame: u8 = 4;
const player_start_position = [2]f32{ 312.0, 130.0 };

fn playerSpawnDesc() world_api.SpriteSpawnDesc {
    return .{
        .position = player_start_position,
        .size = .{ 320.0, 240.0 },
        .color = .{ 1.0, 1.0, 1.0, 1.0 },
        .texture_id = test_texture_id,
        .move_speed = 180.0,
    };
}

pub const Host = struct {
    platform: Platform,
    rhi: Rhi,
    renderer2d: Renderer2D,
    texture: rhi.TextureHandle,
    world: World,
    sprite_entity: world_api.EntityId,
    world_extent: PlatformExtent,
    session: game.GameSession = .{},
    render_sprites: [1]world_api.RenderSprite = undefined,
    render_count: usize = 0,
    quit_requested: bool = false,
    last_time_seconds: f64 = 0.0,
    accumulator_seconds: f64 = 0.0,
    frame_count: u64 = 0,
    last_heartbeat_seconds: f64 = 0.0,

    pub fn init(io: std.Io) !Host {
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

        var runtime_world = try World.init();
        errdefer runtime_world.deinit();
        try runtime_world.setBounds(.{
            .min = .{ 0.0, 0.0 },
            .max = .{ @floatFromInt(extent.width), @floatFromInt(extent.height) },
        });
        const sprite_entity = try runtime_world.spawnSprite(playerSpawnDesc());

        var self = Host{
            .platform = platform,
            .rhi = backend,
            .renderer2d = renderer2d,
            .texture = texture,
            .world = runtime_world,
            .sprite_entity = sprite_entity,
            .world_extent = extent,
            .session = .{},
        };
        const now = self.platform.nowSeconds();
        self.last_time_seconds = now;
        self.last_heartbeat_seconds = now;
        std.log.info("Runtime host initialized with Vulkan RHI and World entity={d}", .{sprite_entity});
        return self;
    }

    pub fn deinit(self: *Host) void {
        self.world.despawn(self.sprite_entity) catch |err| {
            std.log.err("World sprite despawn failed: {s}", .{@errorName(err)});
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
        const extracted = self.render_sprites[0];
        const texture = try self.resolveTexture(extracted.texture_id);
        const sprite = SpriteInstance{
            .position = extracted.position,
            .size = extracted.size,
            .color = if (self.session.phase == .won)
                .{ 0.20, 0.95, 0.35, 1.0 }
            else
                extracted.color,
        };
        const outcome = try self.renderer2d.render(
            &self.rhi,
            .{ .width = extent.width, .height = extent.height },
            sprite,
            texture,
        );
        if (outcome == .recreated) {
            std.log.debug("Renderer2D swapchain recreation completed", .{});
        }
    }

    fn syncExternalResults(self: *Host) void {
        _ = self;
    }

    fn restartGame(self: *Host) !void {
        if (self.session.phase != .won) return;

        // 先创建替代实体；spawn 失败时旧玩家仍完整保留，不会留下空世界。
        const previous_entity = self.sprite_entity;
        const replacement_entity = try self.world.spawnSprite(playerSpawnDesc());
        errdefer self.world.despawn(replacement_entity) catch {};
        try self.world.despawn(previous_entity);

        self.sprite_entity = replacement_entity;
        std.debug.assert(self.session.restart());
        self.accumulator_seconds = 0.0;
        self.render_count = 0;
        std.log.info("Game session restarted: entity={d}, position=({d:.2},{d:.2})", .{
            replacement_entity,
            player_start_position[0],
            player_start_position[1],
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
    }

    fn runFixedUpdates(self: *Host, delta_seconds: f64, input: InputSnapshot) !void {
        // 限制单帧可累积时间，避免暂停/调试断点后进入死亡螺旋。
        self.accumulator_seconds += @min(delta_seconds, 0.25);
        var steps: u8 = 0;
        while (self.accumulator_seconds >= fixed_dt_seconds and steps < max_fixed_steps_per_frame) : (steps += 1) {
            const step_input = if (self.session.acceptsInput()) input else InputSnapshot{};
            try self.world.stepFixed(@floatCast(fixed_dt_seconds), .{
                .move_x = step_input.move_x,
                .move_y = step_input.move_y,
            });
            self.accumulator_seconds -= fixed_dt_seconds;
        }
        if (steps == max_fixed_steps_per_frame and self.accumulator_seconds >= fixed_dt_seconds) {
            self.accumulator_seconds = @mod(self.accumulator_seconds, fixed_dt_seconds);
        }
    }

    fn extractRender(self: *Host) !void {
        // World 只写入稳定 POD 快照；渲染提交阶段不读取 World 内部存储。
        const sprites = try self.world.extractSprites(&self.render_sprites);
        self.render_count = sprites.len;
        if (self.render_count > 0 and self.session.observePlayer(
            self.render_sprites[0].position,
            self.render_sprites[0].size,
            self.world_extent.width,
        )) {
            std.log.info("Game session won: player reached the right World Bounds", .{});
        }
    }

    fn resolveTexture(self: *Host, texture_id: world_api.TextureId) !rhi.TextureHandle {
        // 逻辑资源身份在 Host 边界映射为 GPU handle，禁止泄漏到 World。
        if (texture_id != test_texture_id) return error.UnknownWorldTexture;
        return self.texture;
    }

    fn endFrame(self: *Host, now_seconds: f64, delta_seconds: f64) void {
        self.frame_count += 1;
        if (now_seconds - self.last_heartbeat_seconds >= 1.0) {
            if (self.render_count > 0) {
                const sprite = self.render_sprites[0];
                std.log.debug("Runtime heartbeat: frame={d}, delta={d:.6}s, phase={s}, position=({d:.2},{d:.2})", .{
                    self.frame_count,
                    delta_seconds,
                    @tagName(self.session.phase),
                    sprite.position[0],
                    sprite.position[1],
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
