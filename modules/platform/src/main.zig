const builtin = @import("builtin");

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

        pub fn pumpEvents(self: *@This()) bool {
            _ = self;
            return true;
        }

        pub fn nowSeconds(self: *@This()) f64 {
            _ = self;
            return 0.0;
        }
    };
