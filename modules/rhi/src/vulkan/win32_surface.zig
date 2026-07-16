const std = @import("std");

pub const C = @cImport({
    @cDefine("VK_USE_PLATFORM_WIN32_KHR", "1");
    @cInclude("vulkan/vulkan.h");
});

pub fn create(
    instance: C.VkInstance,
    window_handle: usize,
    instance_handle: usize,
    out_surface: *C.VkSurfaceKHR,
) !void {
    if (window_handle == 0 or instance_handle == 0) {
        return error.InvalidWindowHandle;
    }

    var create_info = std.mem.zeroes(C.VkWin32SurfaceCreateInfoKHR);
    create_info.sType = C.VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR;

    // Zig 0.16 enforces the nominal C pointer alignment for @ptrFromInt, while
    // Win32 opaque handle tokens are not guaranteed to carry that alignment.
    // Preserve the raw handle bits for the Vulkan ABI; these values are never dereferenced.
    var hwnd_bits = window_handle;
    var hinstance_bits = instance_handle;
    @memcpy(std.mem.asBytes(&create_info.hwnd), std.mem.asBytes(&hwnd_bits));
    @memcpy(std.mem.asBytes(&create_info.hinstance), std.mem.asBytes(&hinstance_bits));

    const result = C.vkCreateWin32SurfaceKHR(instance, &create_info, null, out_surface);
    if (result != C.VK_SUCCESS) {
        std.log.err("vkCreateWin32SurfaceKHR failed: {any}", .{result});
        return error.SurfaceCreateFailed;
    }
}
