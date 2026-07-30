const std = @import("std");
const NativeSurface = @import("native_surface").NativeSurface;

pub const C = @cImport({
    @cDefine("VK_USE_PLATFORM_WIN32_KHR", "1");
    @cInclude("vulkan/vulkan.h");
});

pub const required_instance_extensions = [_][*:0]const u8{
    "VK_KHR_surface",
    "VK_KHR_win32_surface",
};

pub fn create(
    instance: C.VkInstance,
    native_surface: NativeSurface,
    out_surface: *C.VkSurfaceKHR,
) !void {
    const surface = switch (native_surface) {
        .win32 => |value| value,
        else => {
            std.log.err("vkCreateWin32SurfaceKHR received a non-Win32 NativeSurface", .{});
            return error.NativeSurfaceMismatch;
        },
    };

    var create_info = std.mem.zeroes(C.VkWin32SurfaceCreateInfoKHR);
    create_info.sType = C.VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR;

    // Zig 0.16 enforces the nominal C pointer alignment for @ptrFromInt, while
    // Win32 opaque handle tokens are not guaranteed to carry that alignment.
    // Preserve the raw handle bits for the Vulkan ABI; these values are never dereferenced.
    var hwnd_bits = @intFromPtr(surface.window);
    var hinstance_bits = @intFromPtr(surface.instance);
    @memcpy(std.mem.asBytes(&create_info.hwnd), std.mem.asBytes(&hwnd_bits));
    @memcpy(std.mem.asBytes(&create_info.hinstance), std.mem.asBytes(&hinstance_bits));

    const result = C.vkCreateWin32SurfaceKHR(instance, &create_info, null, out_surface);
    if (result != C.VK_SUCCESS) {
        std.log.err("vkCreateWin32SurfaceKHR failed: {any}", .{result});
        return error.SurfaceCreateFailed;
    }
}
