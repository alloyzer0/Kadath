const std = @import("std");
const runtime_core = @import("runtime_core");

test "Runtime Core Adapter owns and destroys one opaque Core" {
    var core = try runtime_core.RuntimeCore.init();
    try std.testing.expect(core.handle != null);
    core.deinit();
    try std.testing.expect(core.handle == null);
}
