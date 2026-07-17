const builtin = @import("builtin");

pub const WindowExtent = struct {
    width: u32 = 0,
    height: u32 = 0,
};

pub const InputSnapshot = extern struct {
    move_x: i8 = 0,
    move_y: i8 = 0,
};

pub const PumpResult = struct {
    quit_requested: bool = false,
    input: InputSnapshot = .{},
};

pub const Platform = if (builtin.os.tag == .windows)
    @import("win32.zig").Platform
else
    struct {
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

        pub fn nativeWindowHandle(self: *@This()) usize {
            _ = self;
            return 0;
        }

        pub fn nativeInstanceHandle(self: *@This()) usize {
            _ = self;
            return 0;
        }

        pub fn clientExtent(self: *@This()) WindowExtent {
            _ = self;
            return .{};
        }
    };
