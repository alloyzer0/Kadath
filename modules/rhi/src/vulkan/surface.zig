const builtin = @import("builtin");

const adapter = switch (builtin.os.tag) {
    .windows => @import("win32_surface.zig"),
    .linux => @import("xcb_surface.zig"),
    else => @compileError("Vulkan production surface is supported only on Windows and Linux"),
};

pub const C = adapter.C;
pub const required_instance_extensions = adapter.required_instance_extensions;
pub const create = adapter.create;
