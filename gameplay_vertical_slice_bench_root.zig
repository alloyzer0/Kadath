const std = @import("std");

// 根模块放在仓库根目录，使证据工具可以同时复用 app/ 与 tools/ 下的公开 Adapter。
pub fn main(init: std.process.Init) !void {
    return @import("tools/gameplay-vertical-slice-bench.zig").main(init);
}
