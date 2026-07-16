const std = @import("std");
const Platform = @import("platform").Platform;

pub const Host = struct {
    platform: Platform,
    quit_requested: bool = false,
    last_time_seconds: f64 = 0.0,
    frame_count: u64 = 0,
    last_heartbeat_seconds: f64 = 0.0,

    pub fn init() !Host {
        var self = Host{
            .platform = try Platform.init(),
        };
        errdefer self.platform.deinit();

        const now = self.platform.nowSeconds();
        self.last_time_seconds = now;
        self.last_heartbeat_seconds = now;
        std.log.info("Runtime host initialized", .{});
        return self;
    }

    pub fn deinit(self: *Host) void {
        self.platform.deinit();
        std.log.info("Kadath runtime shutdown complete", .{});
    }

    pub fn run(self: *Host) void {
        std.log.info("Runtime main loop entered", .{});

        while (!self.quit_requested) {
            if (self.platform.pumpEvents()) {
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
            self.submitRender();
            self.endFrame(now, delta);

            // P2-M0-01 没有模拟或渲染工作；短暂让出 CPU，避免空循环忙等。
            std.time.sleep(1 * std.time.ns_per_ms);
        }
    }

    fn syncExternalResults(self: *Host) void {
        _ = self;
        // 后续 Resource / 后台任务结果只在此同步点回流。
    }

    fn runFixedUpdates(self: *Host, delta_seconds: f64) void {
        _ = self;
        _ = delta_seconds;
        // World 接入前不执行模拟；保留 ADR-0008 的阶段边界。
    }

    fn extractRender(self: *Host) void {
        _ = self;
        // RHI / Renderer2D 尚未接入。
    }

    fn submitRender(self: *Host) void {
        _ = self;
        // RHI / Renderer2D 尚未接入。
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
