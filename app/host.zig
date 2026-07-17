const std = @import("std");
const Platform = @import("platform").Platform;
const PlatformExtent = @import("platform").WindowExtent;
const rhi = @import("rhi");
const Rhi = rhi.Rhi;
const resource = @import("resource");
const Renderer2D = @import("renderer2d").Renderer2D;
const SpriteInstance = @import("renderer2d").SpriteInstance;

pub const Host = struct {
    platform: Platform,
    rhi: Rhi,
    renderer2d: Renderer2D,
    texture: rhi.TextureHandle,
    sprite: SpriteInstance = .{
        .position = .{ 0.0, 0.0 },
        .size = .{ 320.0, 240.0 },
        .color = .{ 1.0, 1.0, 1.0, 1.0 },
    },
    quit_requested: bool = false,
    last_time_seconds: f64 = 0.0,
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

        var self = Host{
            .platform = platform,
            .rhi = backend,
            .renderer2d = renderer2d,
            .texture = texture,
        };
        const now = self.platform.nowSeconds();
        self.last_time_seconds = now;
        self.last_heartbeat_seconds = now;
        std.log.info("Runtime host initialized with Vulkan RHI", .{});
        return self;
    }

    pub fn deinit(self: *Host) void {
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

            const now = self.platform.nowSeconds();
            const delta = if (now >= self.last_time_seconds)
                now - self.last_time_seconds
            else
                0.0;
            self.last_time_seconds = now;

            self.syncExternalResults();
            self.runFixedUpdates(delta);
            self.extractRender();

            try self.submitRender();

            self.endFrame(now, delta);
            self.platform.sleepMilliseconds(1);
        }
    }

    fn submitRender(self: *Host) !void {
        const extent: PlatformExtent = self.platform.clientExtent();
        const outcome = try self.renderer2d.render(
            &self.rhi,
            .{ .width = extent.width, .height = extent.height },
            self.sprite,
            self.texture,
        );
        if (outcome == .recreated) {
            std.log.debug("Renderer2D swapchain recreation completed", .{});
        }
    }

    fn syncExternalResults(self: *Host) void {
        _ = self;
    }

    fn runFixedUpdates(self: *Host, delta_seconds: f64) void {
        _ = self;
        _ = delta_seconds;
    }

    fn extractRender(self: *Host) void {
        const extent = self.platform.clientExtent();
        if (extent.width == 0 or extent.height == 0) return;

        const width: f32 = @floatFromInt(extent.width);
        const height: f32 = @floatFromInt(extent.height);
        self.sprite.position = .{
            width * 0.5 - self.sprite.size[0] * 0.5,
            height * 0.5 - self.sprite.size[1] * 0.5,
        };
    }

    fn endFrame(self: *Host, now_seconds: f64, delta_seconds: f64) void {
        self.frame_count += 1;
        if (now_seconds - self.last_heartbeat_seconds >= 1.0) {
            std.log.debug("Runtime heartbeat: frame={d}, delta={d:.6}s", .{
                self.frame_count,
                delta_seconds,
            });
            self.last_heartbeat_seconds = now_seconds;
        }
    }
};
