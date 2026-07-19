const std = @import("std");
const Host = @import("host.zig").Host;

const RuntimeOptions = struct {
    scene_path: ?[]const u8 = null,
    script_path: ?[]const u8 = null,
};

fn parseRuntimeOptions(args: []const [:0]const u8) !RuntimeOptions {
    var options = RuntimeOptions{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const destination = if (std.mem.eql(u8, args[index], "--scene"))
            &options.scene_path
        else if (std.mem.eql(u8, args[index], "--script"))
            &options.script_path
        else
            return error.UnknownRuntimeArgument;

        if (destination.* != null) return error.DuplicateRuntimeArgument;
        index += 1;
        if (index >= args.len) return error.MissingRuntimeArgumentValue;
        destination.* = args[index];
    }
    return options;
}

pub fn main(init: std.process.Init) !void {
    std.log.info("Kadath runtime startup", .{});

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = parseRuntimeOptions(args) catch |err| {
        std.log.err("Runtime argument parsing failed: {s}", .{@errorName(err)});
        return err;
    };

    var host = Host.init(init.io, options.scene_path, options.script_path) catch |err| {
        std.log.err("Runtime startup failed: {s}", .{@errorName(err)});
        return err;
    };
    defer host.deinit();

    host.run() catch |err| {
        std.log.err("Runtime loop failed: {s}", .{@errorName(err)});
        return err;
    };
}
