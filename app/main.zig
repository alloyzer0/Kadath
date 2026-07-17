const std = @import("std");
const Host = @import("host.zig").Host;

pub fn main(init: std.process.Init) !void {
    std.log.info("Kadath runtime startup", .{});

    var host = Host.init(init.io) catch |err| {
        std.log.err("Runtime startup failed: {s}", .{@errorName(err)});
        return err;
    };
    defer host.deinit();

    host.run() catch |err| {
        std.log.err("Runtime loop failed: {s}", .{@errorName(err)});
        return err;
    };
}
