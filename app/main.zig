const std = @import("std");
const Host = @import("host.zig").Host;
const PreviewControl = @import("preview_control.zig").PreviewControl;
const PreviewStatus = @import("preview_status").PreviewStatus;
const runtime_options = @import("runtime_options.zig");
pub fn main(init: std.process.Init) !void {
    std.log.info("Kadath runtime startup", .{});

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = runtime_options.parse(args) catch |err| {
        std.log.err("Runtime argument parsing failed: {s}", .{@errorName(err)});
        return err;
    };

    var preview_status = PreviewStatus.init(init.io, options.preview_status_jsonl);
    const host = Host.init(init.io, options.scene_path, options.script_path, &preview_status) catch |err| {
        preview_status.runtimeFailed("startup", err);
        std.log.err("Runtime startup failed: {s}", .{@errorName(err)});
        return err;
    };
    defer host.destroy();

    var preview_control = PreviewControl.init(init.io, options.preview_control_jsonl) catch |err| {
        preview_status.runtimeFailed("preview_control", err);
        std.log.err("Preview control startup failed: {s}", .{@errorName(err)});
        return err;
    };
    var wait_for_control_reader = false;
    defer preview_control.deinit(wait_for_control_reader);

    // Host 完整初始化成功后才一次性发布两类内容身份；任一加载失败都不会留下半套 ready 数据。
    preview_status.runtimeReady(host.initialLoaded());
    const exit_reason = host.run(&preview_control) catch |err| {
        preview_status.runtimeFailed("runtime_loop", err);
        std.log.err("Runtime loop failed: {s}", .{@errorName(err)});
        return err;
    };
    wait_for_control_reader = exit_reason == .control_shutdown;
    preview_status.runtimeStopping(switch (exit_reason) {
        .window_close => "window_close",
        .control_shutdown => "control_shutdown",
    });
}
