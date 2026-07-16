const std = @import("std");
const Platform = @import("platform").Platform;
const PlatformExtent = @import("platform").WindowExtent;
const Rhi = @import("rhi").Rhi;

pub const Host = struct {
    platform: Platform,
    rhi: Rhi,
    quit_requested: bool = false,
    last_time_seconds: f64 = 0.0,
    frame_count: u64 = 0,
    last_heartbeat_seconds: f64 = 0.0,

    pub fn init() !Host {
        var platform = try Platform.init();
        errdefer platform.deinit();

        const extent = platform.clientExtent();
        var rhi = try Rhi.init(
            platform.nativeWindowHandle(),
            platform.nativeInstanceHandle(),
            .{ .width = extent.width, .height = extent.height },
        );
        errdefer rhi.deinit();

        var self = Host{
            .platform = platform,
            .rhi = rhi,
        };
        const now = self.platform.nowSeconds();
        self.last_time_seconds = now;
        self.last_heartbeat_seconds = now;
        std.log.info("Runtime host initialized with Vulkan RHI", .{});
        return self;
    }

    pub fn deinit(self: *Host) void {
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
        const outcome = try self.rhi.drawFrame(.{ .width = extent.width, .height = extent.height });
        if (outcome == .recreated) {
            std.log.debug("RHI swapchain recreation completed", .{});
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
        _ = self;
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
