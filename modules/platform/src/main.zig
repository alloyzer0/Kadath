const builtin = @import("builtin");

pub const NativeSurface = @import("native_surface").NativeSurface;

pub const WindowExtent = struct {
    width: u32 = 0,
    height: u32 = 0,
};

pub const InputSnapshot = extern struct {
    move_x: i8 = 0,
    move_y: i8 = 0,
    restart_pressed: u8 = 0,
    reload_pressed: u8 = 0,
    script_reload_pressed: u8 = 0,
};

// Preview 机器命令使用 WM_APP 私有区间；具体传输仅属于 Windows Platform 物理装配。
pub const preview_reload_scene_message: u32 = 0x84D0;
pub const preview_reload_script_message: u32 = 0x84D1;

pub const PumpResult = struct {
    quit_requested: bool = false,
    input: InputSnapshot = .{},
    scene_reload_request_id: ?u64 = null,
    script_reload_request_id: ?u64 = null,
};

pub const Platform = switch (builtin.os.tag) {
    .windows => @import("win32.zig").Platform,
    .linux => @import("xcb.zig").Platform,
    else => struct {
        pub fn init() !@This() {
            return error.UnsupportedPlatform;
        }

        pub fn deinit(self: *@This()) void {
            _ = self;
        }

        pub fn pumpEvents(self: *@This()) PumpResult {
            _ = self;
            return .{ .quit_requested = true, .input = .{} };
        }

        pub fn nowSeconds(self: *@This()) f64 {
            _ = self;
            return 0.0;
        }

        pub fn sleepMilliseconds(self: *@This(), milliseconds: u32) void {
            _ = self;
            _ = milliseconds;
        }

        pub fn nativeSurface(self: *@This()) NativeSurface {
            _ = self;
            unreachable;
        }

        pub fn clientExtent(self: *@This()) WindowExtent {
            _ = self;
            return .{};
        }
    },
};
