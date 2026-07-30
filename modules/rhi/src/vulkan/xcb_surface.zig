const std = @import("std");
const NativeSurface = @import("native_surface").NativeSurface;

pub const C = @cImport({
    @cDefine("VK_USE_PLATFORM_XCB_KHR", "1");
    @cInclude("vulkan/vulkan.h");
});

pub const required_instance_extensions = [_][*:0]const u8{
    "VK_KHR_surface",
    "VK_KHR_xcb_surface",
};

pub fn create(
    instance: C.VkInstance,
    native_surface: NativeSurface,
    out_surface: *C.VkSurfaceKHR,
) !void {
    const surface = switch (native_surface) {
        .xcb => |value| value,
        else => {
            std.log.err("vkCreateXcbSurfaceKHR received a non-XCB NativeSurface", .{});
            return error.NativeSurfaceMismatch;
        },
    };
    if (surface.window == 0) {
        std.log.err("vkCreateXcbSurfaceKHR received a zero XCB window", .{});
        return error.InvalidWindowHandle;
    }

    var create_info = std.mem.zeroes(C.VkXcbSurfaceCreateInfoKHR);
    create_info.sType = C.VK_STRUCTURE_TYPE_XCB_SURFACE_CREATE_INFO_KHR;
    create_info.connection = @ptrCast(@alignCast(surface.connection));
    create_info.window = surface.window;

    const result = C.vkCreateXcbSurfaceKHR(instance, &create_info, null, out_surface);
    if (result != C.VK_SUCCESS) {
        std.log.err("vkCreateXcbSurfaceKHR failed: {any}", .{result});
        return error.SurfaceCreateFailed;
    }
}
