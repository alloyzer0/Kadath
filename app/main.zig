const std = @import("std");
const Host = @import("host.zig").Host;

pub fn main() !void {
    std.log.info("Kadath runtime startup", .{});

    var host = Host.init() catch |err| {
        std.log.err("Runtime startup failed: {s}", .{@errorName(err)});
        return err;
    };
    defer host.deinit();

    host.run();
}
