const std = @import("std");
const Host = @import("host.zig").Host;
const PreviewStatus = @import("preview_status").PreviewStatus;

const RuntimeOptions = struct {
    scene_path: ?[]const u8 = null,
    script_path: ?[]const u8 = null,
    preview_status_jsonl: bool = false,
};

fn parseRuntimeOptions(args: []const [:0]const u8) !RuntimeOptions {
    var options = RuntimeOptions{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--scene")) {
            if (options.scene_path != null) return error.DuplicateRuntimeArgument;
            index += 1;
            if (index >= args.len) return error.MissingRuntimeArgumentValue;
            options.scene_path = args[index];
        } else if (std.mem.eql(u8, args[index], "--script")) {
            if (options.script_path != null) return error.DuplicateRuntimeArgument;
            index += 1;
            if (index >= args.len) return error.MissingRuntimeArgumentValue;
            options.script_path = args[index];
        } else if (std.mem.eql(u8, args[index], "--preview-status")) {
            if (options.preview_status_jsonl) return error.DuplicateRuntimeArgument;
            index += 1;
            if (index >= args.len) return error.MissingRuntimeArgumentValue;
            if (!std.mem.eql(u8, args[index], "jsonl-v1")) return error.UnsupportedPreviewStatus;
            options.preview_status_jsonl = true;
        } else {
            return error.UnknownRuntimeArgument;
        }
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

    var preview_status = PreviewStatus.init(init.io, options.preview_status_jsonl);
    var host = Host.init(init.io, options.scene_path, options.script_path, &preview_status) catch |err| {
        preview_status.runtimeFailed("startup", err);
        std.log.err("Runtime startup failed: {s}", .{@errorName(err)});
        return err;
    };
    defer host.deinit();

    // Host 完整初始化成功后才一次性发布两类内容身份；任一加载失败都不会留下半套 ready 数据。
    preview_status.runtimeReady(host.initialLoaded());
    host.run() catch |err| {
        preview_status.runtimeFailed("runtime_loop", err);
        std.log.err("Runtime loop failed: {s}", .{@errorName(err)});
        return err;
    };
    preview_status.runtimeStopping("window_close");
}
