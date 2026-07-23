const std = @import("std");
const types = @import("../types.zig");
const surface_bridge = @import("win32_surface.zig");
const c = surface_bridge.C;

const allocator = std.heap.page_allocator;
const api_version: u32 = 1 << 22;

const max_pipelines: usize = 8;
const max_textures: usize = 8;
const max_texture_mip_levels: usize = 32;

const TextureSlot = struct {
    image: c.VkImage = null,
    memory: c.VkDeviceMemory = null,
    view: c.VkImageView = null,
    sampler: c.VkSampler = null,
    descriptor_set: c.VkDescriptorSet = null,
    mip_levels: u32 = 1,
    sampler_profile: types.TextureSamplerProfile = .smooth_mipmap,
    anisotropy_enabled: bool = false,
    anisotropy_level: f32 = 1.0,
};

const BufferAllocation = struct {
    buffer: c.VkBuffer = null,
    memory: c.VkDeviceMemory = null,
};

fn textureLevelBytes(width: u32, height: u32) !usize {
    const pixels = try std.math.mul(usize, @intCast(width), @intCast(height));
    return try std.math.mul(usize, pixels, 4);
}

fn nextMipDimension(value: u32) u32 {
    return if (value > 1) value / 2 else 1;
}

fn textureUploadBytes(desc: types.TextureUploadDesc) !usize {
    if (desc.width == 0 or desc.height == 0) return error.InvalidTextureExtent;
    if (desc.mip_levels.len + 1 > max_texture_mip_levels) return error.InvalidTextureMipCount;
    const base_bytes = try textureLevelBytes(desc.width, desc.height);
    if (desc.rgba8.len != base_bytes) return error.InvalidTextureByteCount;

    var expected_additional: usize = 0;
    var width = desc.width;
    var height = desc.height;
    while (width > 1 or height > 1) {
        width = nextMipDimension(width);
        height = nextMipDimension(height);
        expected_additional += 1;
    }
    // 空 slice 保持 KDAT v1/base-only 兼容；提供 mip 时必须是完整链。
    if (desc.mip_levels.len != 0 and desc.mip_levels.len != expected_additional) return error.InvalidTextureMipCount;

    var total = base_bytes;
    width = desc.width;
    height = desc.height;
    for (desc.mip_levels) |level| {
        width = nextMipDimension(width);
        height = nextMipDimension(height);
        if (level.width != width or level.height != height) return error.InvalidTextureMipExtent;
        const level_bytes = try textureLevelBytes(width, height);
        if (level.rgba8.len != level_bytes) return error.InvalidTextureByteCount;
        total = try std.math.add(usize, total, level_bytes);
    }
    return total;
}
const PipelineSlot = struct {
    desc: ?types.GraphicsPipelineDesc = null,
    layout: c.VkPipelineLayout = null,
    pipeline: c.VkPipeline = null,
};

pub const FrameEncoder = struct {
    rhi: *Rhi,
    image_index: u32,
    acquire_result: c.VkResult,
    frame_token: u64,
    bound_pipeline: types.PipelineHandle = types.invalid_pipeline,
    recording: bool = true,
    finished: bool = false,

    pub fn bindPipeline(self: *FrameEncoder, pipeline: types.PipelineHandle) !void {
        if (!self.recording or self.finished) return error.FrameAlreadyFinished;
        try self.rhi.validateFrame(self);
        try self.rhi.validatePipeline(pipeline);
        const slot = self.rhi.pipelineSlot(pipeline) orelse return error.InvalidPipeline;
        c.vkCmdBindPipeline(self.rhi.command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, slot.pipeline);
        self.bound_pipeline = pipeline;
    }

    pub fn bindTexture(self: *FrameEncoder, texture: types.TextureHandle) !void {
        if (!self.recording or self.finished) return error.FrameAlreadyFinished;
        try self.rhi.validateFrame(self);
        if (self.bound_pipeline == types.invalid_pipeline) return error.InvalidPipeline;
        const pipeline = self.rhi.pipelineSlot(self.bound_pipeline) orelse return error.InvalidPipeline;
        const desc = pipeline.desc orelse return error.InvalidPipeline;
        if (!desc.uses_texture) return error.TextureBindingUnsupported;
        const slot = self.rhi.textureSlot(texture) orelse return error.InvalidTexture;
        if (slot.descriptor_set == null) return error.InvalidTexture;
        c.vkCmdBindDescriptorSets(
            self.rhi.command_buffer,
            c.VK_PIPELINE_BIND_POINT_GRAPHICS,
            pipeline.layout,
            0,
            1,
            &slot.descriptor_set,
            0,
            null,
        );
    }

    pub fn pushConstants(self: *FrameEncoder, bytes: []const u8) !void {
        if (!self.recording or self.finished) return error.FrameAlreadyFinished;
        try self.rhi.validateFrame(self);
        if (self.bound_pipeline == types.invalid_pipeline) return error.InvalidPipeline;
        const slot = self.rhi.pipelineSlot(self.bound_pipeline) orelse return error.InvalidPipeline;
        const desc = slot.desc orelse return error.InvalidPipeline;
        if (bytes.len > desc.push_constant_size) return error.PipelinePushConstantTooLarge;
        if (bytes.len % 4 != 0) return error.PushConstantAlignment;
        c.vkCmdPushConstants(
            self.rhi.command_buffer,
            slot.layout,
            @intCast(c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT),
            0,
            @intCast(bytes.len),
            @ptrCast(bytes.ptr),
        );
    }

    pub fn draw(self: *FrameEncoder, vertex_count: u32) !void {
        if (!self.recording or self.finished) return error.FrameAlreadyFinished;
        try self.rhi.validateFrame(self);
        if (self.bound_pipeline == types.invalid_pipeline) return error.InvalidPipeline;
        if (vertex_count == 0) return error.InvalidDrawCount;
        c.vkCmdDraw(self.rhi.command_buffer, vertex_count, 1, 0, 0);
    }

    // Completes a partially recorded frame so acquire/fence state stays reusable.
    // The original rendering error remains the caller's result; this is not a normal recovery path.
    pub fn consumeFailedFrame(self: *FrameEncoder) void {
        if (!self.recording or self.finished) return;
        _ = self.rhi.finishFrame(self) catch |err| {
            std.log.err("RHI failed to consume a partially recorded frame: {s}", .{@errorName(err)});
        };
    }

    pub fn finish(self: *FrameEncoder) !types.FrameOutcome {
        return try self.rhi.finishFrame(self);
    }
};

pub const BeginFrameResult = union(enum) {
    ready: FrameEncoder,
    skipped_minimized,
    recreated,
};
pub const Rhi = struct {
    instance: c.VkInstance = null,
    surface: c.VkSurfaceKHR = null,
    physical_device: c.VkPhysicalDevice = null,
    device: c.VkDevice = null,
    queue: c.VkQueue = null,
    queue_family_index: u32 = 0,

    swapchain: c.VkSwapchainKHR = null,
    swapchain_format: c.VkFormat = undefined,
    swapchain_color_space: c.VkColorSpaceKHR = undefined,
    swapchain_extent: types.Extent2D = .{},
    requested_extent: types.Extent2D = .{},
    swapchain_images: ?[]c.VkImage = null,
    swapchain_views: ?[]c.VkImageView = null,
    framebuffers: ?[]c.VkFramebuffer = null,
    render_pass: c.VkRenderPass = null,

    command_pool: c.VkCommandPool = null,
    command_buffer: c.VkCommandBuffer = null,
    image_available: c.VkSemaphore = null,
    render_finished: ?[]c.VkSemaphore = null,
    in_flight: c.VkFence = null,
    pipeline_slots: [max_pipelines]PipelineSlot = [_]PipelineSlot{.{}} ** max_pipelines,
    render_pass_generation: u64 = 0,
    next_frame_token: u64 = 0,
    active_frame_token: ?u64 = null,
    texture_slots: [max_textures]TextureSlot = [_]TextureSlot{.{}} ** max_textures,
    descriptor_pool: c.VkDescriptorPool = null,
    texture_descriptor_set_layout: c.VkDescriptorSetLayout = null,
    sampler_anisotropy_supported: bool = false,
    max_sampler_anisotropy: f32 = 1.0,

    pub fn init(window_handle: usize, instance_handle: usize, requested_extent: types.Extent2D) !Rhi {
        var self = Rhi{};
        errdefer self.deinit();

        try self.createInstance();
        try surface_bridge.create(self.instance, window_handle, instance_handle, &self.surface);
        try self.selectPhysicalDevice();
        try self.createDevice();
        try self.createTextureDescriptors();
        try self.createCommandPool();
        try self.createSyncObjects();
        if (requested_extent.width != 0 and requested_extent.height != 0) {
            self.createSwapchain(requested_extent) catch |err| switch (err) {
                error.SurfaceSuspended => {},
                else => return err,
            };
        }

        std.log.info("Vulkan RHI initialized", .{});
        return self;
    }

    pub fn deinit(self: *Rhi) void {
        if (self.device != null) {
            _ = c.vkDeviceWaitIdle(self.device);
        }
        self.destroySwapchainResources();
        self.destroyTextureObjects();
        self.destroyPipelineLayouts();
        self.destroyTextureDescriptors();
        if (self.in_flight != null and self.device != null) {
            c.vkDestroyFence(self.device, self.in_flight, null);
            self.in_flight = null;
        }
        if (self.image_available != null and self.device != null) {
            c.vkDestroySemaphore(self.device, self.image_available, null);
            self.image_available = null;
        }
        if (self.command_pool != null and self.device != null) {
            c.vkDestroyCommandPool(self.device, self.command_pool, null);
            self.command_pool = null;
            self.command_buffer = null;
        }
        if (self.device != null) {
            c.vkDestroyDevice(self.device, null);
            self.device = null;
            self.queue = null;
        }
        if (self.surface != null and self.instance != null) {
            c.vkDestroySurfaceKHR(self.instance, self.surface, null);
            self.surface = null;
        }
        if (self.instance != null) {
            c.vkDestroyInstance(self.instance, null);
            self.instance = null;
        }
        std.log.info("Vulkan RHI shutdown complete", .{});
        self.active_frame_token = null;
    }

    pub fn createGraphicsPipeline(self: *Rhi, desc: types.GraphicsPipelineDesc) !types.PipelineHandle {
        if (desc.push_constant_size == 0 or desc.push_constant_size > 128 or desc.push_constant_size % 4 != 0) {
            return error.InvalidPushConstantSize;
        }
        if (desc.vertex_shader.len == 0 or desc.vertex_shader.len % 4 != 0 or
            desc.fragment_shader.len == 0 or desc.fragment_shader.len % 4 != 0)
        {
            return error.InvalidShaderCode;
        }
        for (&self.pipeline_slots, 0..) |*slot, index| {
            if (slot.desc == null) {
                const layout = try self.createPipelineLayout(desc.push_constant_size, desc.uses_texture);
                slot.layout = layout;
                slot.desc = desc;
                errdefer {
                    c.vkDestroyPipelineLayout(self.device, slot.layout, null);
                    slot.* = .{};
                }
                if (self.render_pass != null) {
                    try self.rebuildPipelineSlot(slot);
                }
                const handle: types.PipelineHandle = @intCast(index + 1);
                std.log.info("RHI graphics pipeline created: handle={d}", .{handle});
                return handle;
            }
        }
        return error.PipelineLimitReached;
    }

    pub fn destroyGraphicsPipeline(self: *Rhi, handle: types.PipelineHandle) void {
        const slot = self.pipelineSlot(handle) orelse return;
        if (self.device != null) {
            _ = c.vkDeviceWaitIdle(self.device);
        }
        if (slot.pipeline != null) {
            c.vkDestroyPipeline(self.device, slot.pipeline, null);
        }
        if (slot.layout != null) {
            c.vkDestroyPipelineLayout(self.device, slot.layout, null);
        }
        slot.* = .{};
    }

    pub fn createTexture(self: *Rhi, desc: types.TextureUploadDesc) !types.TextureHandle {
        if (self.active_frame_token != null) return error.TextureCreationDuringFrame;
        try check(c.vkDeviceWaitIdle(self.device), "vkDeviceWaitIdle(texture upload)");
        const requested_profile = desc.sampler_profile;
        var upload_desc = desc;
        const anisotropy_fallback = requested_profile == .smooth_mipmap_anisotropic and !self.sampler_anisotropy_supported;
        if (anisotropy_fallback) upload_desc.sampler_profile = .smooth_mipmap;
        const upload_bytes = try textureUploadBytes(upload_desc);

        for (&self.texture_slots, 0..) |*destination, index| {
            if (destination.image != null) continue;

            var texture = TextureSlot{};
            errdefer self.destroyTextureSlot(&texture);
            try self.createTextureImage(&texture, upload_desc);
            try self.createTextureViewSamplerDescriptor(&texture);
            destination.* = texture;

            const handle: types.TextureHandle = @intCast(index + 1);
            std.log.info("RHI texture created: handle={d}, extent={d}x{d}, mip_levels={d}, upload_bytes={d}, sampler_requested={s}, sampler={s}, anisotropy={s}, anisotropy_level={d}, lod=0..{d}", .{
                handle,
                desc.width,
                desc.height,
                1 + desc.mip_levels.len,
                upload_bytes,
                @tagName(requested_profile),
                @tagName(texture.sampler_profile),
                if (texture.anisotropy_enabled) "on" else "off",
                texture.anisotropy_level,
                if (texture.sampler_profile == .smooth_linear) 0 else desc.mip_levels.len,
            });
            if (anisotropy_fallback) {
                std.log.warn("Texture sampler anisotropy unsupported; falling back to smooth_mipmap", .{});
            }
            return handle;
        }
        return error.TextureLimitReached;
    }
    pub fn destroyTexture(self: *Rhi, handle: types.TextureHandle) void {
        const slot = self.textureSlot(handle) orelse return;
        if (self.device != null) {
            _ = c.vkDeviceWaitIdle(self.device);
        }
        self.destroyTextureSlot(slot);
    }
    pub fn beginFrame(
        self: *Rhi,
        requested_extent: types.Extent2D,
        clear_color: [4]f32,
    ) !BeginFrameResult {
        if (self.active_frame_token != null) return error.FrameAlreadyActive;
        if (requested_extent.width == 0 or requested_extent.height == 0) {
            return .skipped_minimized;
        }
        if (self.swapchain == null or
            requested_extent.width != self.requested_extent.width or
            requested_extent.height != self.requested_extent.height)
        {
            return try self.recreateBeginResult(requested_extent);
        }

        try check(c.vkWaitForFences(self.device, 1, &self.in_flight, c.VK_TRUE, std.math.maxInt(u64)), "vkWaitForFences");

        var image_index: u32 = 0;
        const acquire_result = c.vkAcquireNextImageKHR(
            self.device,
            self.swapchain,
            std.math.maxInt(u64),
            self.image_available,
            null,
            &image_index,
        );
        if (acquire_result == c.VK_ERROR_OUT_OF_DATE_KHR) {
            return try self.recreateBeginResult(requested_extent);
        }
        if (acquire_result != c.VK_SUCCESS and acquire_result != c.VK_SUBOPTIMAL_KHR) {
            try check(acquire_result, "vkAcquireNextImageKHR");
        }

        const framebuffers = self.framebuffers orelse return error.FramebuffersUnavailable;
        if (image_index >= framebuffers.len) return error.InvalidSwapchainImage;
        try check(c.vkResetCommandBuffer(self.command_buffer, 0), "vkResetCommandBuffer");

        var begin_info = std.mem.zeroes(c.VkCommandBufferBeginInfo);
        begin_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        try check(c.vkBeginCommandBuffer(self.command_buffer, &begin_info), "vkBeginCommandBuffer");

        var clear_value = std.mem.zeroes(c.VkClearValue);
        clear_value.color.float32[0] = clear_color[0];
        clear_value.color.float32[1] = clear_color[1];
        clear_value.color.float32[2] = clear_color[2];
        clear_value.color.float32[3] = clear_color[3];

        var pass_info = std.mem.zeroes(c.VkRenderPassBeginInfo);
        pass_info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
        pass_info.renderPass = self.render_pass;
        pass_info.framebuffer = framebuffers[image_index];
        pass_info.renderArea.offset = .{ .x = 0, .y = 0 };
        pass_info.renderArea.extent = .{ .width = self.swapchain_extent.width, .height = self.swapchain_extent.height };
        pass_info.clearValueCount = 1;
        pass_info.pClearValues = &clear_value;
        c.vkCmdBeginRenderPass(self.command_buffer, &pass_info, c.VK_SUBPASS_CONTENTS_INLINE);

        var viewport = std.mem.zeroes(c.VkViewport);
        viewport.width = @floatFromInt(self.swapchain_extent.width);
        viewport.height = @floatFromInt(self.swapchain_extent.height);
        viewport.minDepth = 0.0;
        viewport.maxDepth = 1.0;
        c.vkCmdSetViewport(self.command_buffer, 0, 1, &viewport);

        var scissor = std.mem.zeroes(c.VkRect2D);
        scissor.extent = .{ .width = self.swapchain_extent.width, .height = self.swapchain_extent.height };
        c.vkCmdSetScissor(self.command_buffer, 0, 1, &scissor);

        self.next_frame_token +%= 1;
        if (self.next_frame_token == 0) self.next_frame_token = 1;
        const frame_token = self.next_frame_token;
        self.active_frame_token = frame_token;
        return .{ .ready = .{
            .rhi = self,
            .image_index = image_index,
            .acquire_result = acquire_result,
            .frame_token = frame_token,
        } };
    }

    fn finishFrame(self: *Rhi, encoder: *FrameEncoder) !types.FrameOutcome {
        if (encoder.finished) return error.FrameAlreadyFinished;
        if (!encoder.recording) return error.NoActiveFrame;
        try self.validateFrame(encoder);
        errdefer self.active_frame_token = null;
        c.vkCmdEndRenderPass(self.command_buffer);
        try check(c.vkEndCommandBuffer(self.command_buffer), "vkEndCommandBuffer");
        encoder.recording = false;

        const render_finished = self.render_finished orelse return error.PresentSemaphoresUnavailable;
        if (encoder.image_index >= render_finished.len) return error.InvalidSwapchainImage;

        try check(c.vkResetFences(self.device, 1, &self.in_flight), "vkResetFences");
        var wait_stage: u32 = @intCast(c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT);
        var submit_info = std.mem.zeroes(c.VkSubmitInfo);
        submit_info.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submit_info.waitSemaphoreCount = 1;
        submit_info.pWaitSemaphores = &self.image_available;
        submit_info.pWaitDstStageMask = &wait_stage;
        submit_info.commandBufferCount = 1;
        submit_info.pCommandBuffers = &self.command_buffer;
        submit_info.signalSemaphoreCount = 1;
        submit_info.pSignalSemaphores = &render_finished[encoder.image_index];
        try check(c.vkQueueSubmit(self.queue, 1, &submit_info, self.in_flight), "vkQueueSubmit");

        var present_info = std.mem.zeroes(c.VkPresentInfoKHR);
        present_info.sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
        present_info.waitSemaphoreCount = 1;
        present_info.pWaitSemaphores = &render_finished[encoder.image_index];
        present_info.swapchainCount = 1;
        present_info.pSwapchains = &self.swapchain;
        present_info.pImageIndices = &encoder.image_index;
        const present_result = c.vkQueuePresentKHR(self.queue, &present_info);
        encoder.finished = true;
        self.active_frame_token = null;
        if (present_result == c.VK_ERROR_OUT_OF_DATE_KHR or
            present_result == c.VK_SUBOPTIMAL_KHR or
            encoder.acquire_result == c.VK_SUBOPTIMAL_KHR)
        {
            return try self.recreateForFrame(self.requested_extent);
        }
        try check(present_result, "vkQueuePresentKHR");
        return .presented;
    }

    fn validateFrame(self: *Rhi, encoder: *const FrameEncoder) !void {
        const active_token = self.active_frame_token orelse return error.NoActiveFrame;
        if (active_token != encoder.frame_token) return error.StaleFrameEncoder;
    }

    fn pipelineSlot(self: *Rhi, handle: types.PipelineHandle) ?*PipelineSlot {
        if (handle == types.invalid_pipeline or handle > @as(types.PipelineHandle, max_pipelines)) return null;
        const index: usize = @intCast(handle - 1);
        return &self.pipeline_slots[index];
    }

    fn textureSlot(self: *Rhi, handle: types.TextureHandle) ?*TextureSlot {
        if (handle == types.invalid_texture or handle > @as(types.TextureHandle, max_textures)) return null;
        const index: usize = @intCast(handle - 1);
        const slot = &self.texture_slots[index];
        if (slot.image == null) return null;
        return slot;
    }

    fn validatePipeline(self: *Rhi, handle: types.PipelineHandle) !void {
        const slot = self.pipelineSlot(handle) orelse return error.InvalidPipeline;
        if (slot.desc == null) return error.InvalidPipeline;
        if (slot.pipeline == null) return error.PipelineNotReady;
    }

    fn createPipelineLayout(self: *Rhi, push_constant_size: u32, uses_texture: bool) !c.VkPipelineLayout {
        var range = std.mem.zeroes(c.VkPushConstantRange);
        range.stageFlags = @intCast(c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT);
        range.offset = 0;
        range.size = push_constant_size;
        var info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
        info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        info.pushConstantRangeCount = 1;
        info.pPushConstantRanges = &range;
        var set_layouts = [_]c.VkDescriptorSetLayout{self.texture_descriptor_set_layout};
        if (uses_texture) {
            if (self.texture_descriptor_set_layout == null) return error.TextureDescriptorsUnavailable;
            info.setLayoutCount = 1;
            info.pSetLayouts = &set_layouts;
        }
        var layout: c.VkPipelineLayout = null;
        try check(c.vkCreatePipelineLayout(self.device, &info, null, &layout), "vkCreatePipelineLayout");
        return layout;
    }

    fn createInstance(self: *Rhi) !void {
        var loader_api_version: u32 = api_version;
        const enumerate_version: ?@TypeOf(&c.vkEnumerateInstanceVersion) =
            @ptrCast(c.vkGetInstanceProcAddr(null, "vkEnumerateInstanceVersion"));
        if (enumerate_version) |query| {
            _ = query(&loader_api_version);
        }

        const app_name: [*:0]const u8 = "Kadath";
        var app_info = std.mem.zeroes(c.VkApplicationInfo);
        app_info.sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO;
        app_info.pApplicationName = app_name;
        app_info.applicationVersion = 1;
        app_info.pEngineName = app_name;
        app_info.engineVersion = 1;
        app_info.apiVersion = api_version;

        const extensions = [_][*:0]const u8{
            "VK_KHR_surface",
            "VK_KHR_win32_surface",
        };
        var create_info = std.mem.zeroes(c.VkInstanceCreateInfo);
        create_info.sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
        create_info.pApplicationInfo = &app_info;
        create_info.enabledExtensionCount = extensions.len;
        create_info.ppEnabledExtensionNames = @ptrCast(&extensions);

        try check(c.vkCreateInstance(&create_info, null, &self.instance), "vkCreateInstance");
        std.log.info("Vulkan loader API {d}.{d}.{d}; instance API 1.0", .{
            loader_api_version >> 22,
            (loader_api_version >> 12) & 0x3ff,
            loader_api_version & 0xfff,
        });
    }

    fn selectPhysicalDevice(self: *Rhi) !void {
        var count: u32 = 0;
        try check(c.vkEnumeratePhysicalDevices(self.instance, &count, null), "vkEnumeratePhysicalDevices(count)");
        if (count == 0) {
            return error.NoPhysicalDevice;
        }

        const devices = try allocator.alloc(c.VkPhysicalDevice, count);
        defer allocator.free(devices);
        try check(c.vkEnumeratePhysicalDevices(self.instance, &count, devices.ptr), "vkEnumeratePhysicalDevices(list)");

        for (devices) |device| {
            if (!try self.deviceSupportsSwapchain(device)) continue;

            var capabilities: c.VkSurfaceCapabilitiesKHR = undefined;
            try check(
                c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(device, self.surface, &capabilities),
                "vkGetPhysicalDeviceSurfaceCapabilitiesKHR",
            );
            if ((capabilities.supportedUsageFlags & c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT) == 0) continue;
            var format_count: u32 = 0;
            try check(c.vkGetPhysicalDeviceSurfaceFormatsKHR(device, self.surface, &format_count, null), "vkGetPhysicalDeviceSurfaceFormatsKHR(count)");
            if (format_count == 0) continue;
            var queue_count: u32 = 0;
            c.vkGetPhysicalDeviceQueueFamilyProperties(device, &queue_count, null);
            if (queue_count == 0) continue;

            const properties = try allocator.alloc(c.VkQueueFamilyProperties, queue_count);
            defer allocator.free(properties);
            c.vkGetPhysicalDeviceQueueFamilyProperties(device, &queue_count, properties.ptr);

            for (properties, 0..) |queue_properties, index| {
                if (queue_properties.queueCount == 0 or
                    (queue_properties.queueFlags & c.VK_QUEUE_GRAPHICS_BIT) == 0)
                {
                    continue;
                }
                var present_supported: c.VkBool32 = c.VK_FALSE;
                try check(
                    c.vkGetPhysicalDeviceSurfaceSupportKHR(
                        device,
                        @intCast(index),
                        self.surface,
                        &present_supported,
                    ),
                    "vkGetPhysicalDeviceSurfaceSupportKHR",
                );
                if (present_supported == c.VK_TRUE) {
                    self.physical_device = device;
                    self.queue_family_index = @intCast(index);
                    var device_properties: c.VkPhysicalDeviceProperties = undefined;
                    c.vkGetPhysicalDeviceProperties(device, &device_properties);
                    var device_features: c.VkPhysicalDeviceFeatures = undefined;
                    c.vkGetPhysicalDeviceFeatures(device, &device_features);
                    self.sampler_anisotropy_supported = device_features.samplerAnisotropy == c.VK_TRUE;
                    self.max_sampler_anisotropy = if (self.sampler_anisotropy_supported) device_properties.limits.maxSamplerAnisotropy else 1.0;
                    const name = std.mem.sliceTo(&device_properties.deviceName, 0);
                    std.log.info("Vulkan GPU selected: {s}, queue_family={d}, sampler_anisotropy={any}, max={d}", .{
                        name,
                        self.queue_family_index,
                        self.sampler_anisotropy_supported,
                        self.max_sampler_anisotropy,
                    });
                    return;
                }
            }
        }
        return error.NoGraphicsPresentQueue;
    }

    fn deviceSupportsSwapchain(_: *Rhi, device: c.VkPhysicalDevice) !bool {
        var count: u32 = 0;
        try check(
            c.vkEnumerateDeviceExtensionProperties(device, null, &count, null),
            "vkEnumerateDeviceExtensionProperties(count)",
        );
        if (count == 0) return false;

        const properties = try allocator.alloc(c.VkExtensionProperties, count);
        defer allocator.free(properties);
        try check(
            c.vkEnumerateDeviceExtensionProperties(device, null, &count, properties.ptr),
            "vkEnumerateDeviceExtensionProperties(list)",
        );
        for (properties) |property| {
            const name = std.mem.sliceTo(&property.extensionName, 0);
            if (std.mem.eql(u8, name, "VK_KHR_swapchain")) return true;
        }
        return false;
    }

    fn createDevice(self: *Rhi) !void {
        const priority: f32 = 1.0;
        var queue_info = std.mem.zeroes(c.VkDeviceQueueCreateInfo);
        queue_info.sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
        queue_info.queueFamilyIndex = self.queue_family_index;
        queue_info.queueCount = 1;
        queue_info.pQueuePriorities = &priority;

        const extensions = [_][*:0]const u8{"VK_KHR_swapchain"};
        var enabled_features = std.mem.zeroes(c.VkPhysicalDeviceFeatures);
        if (self.sampler_anisotropy_supported) enabled_features.samplerAnisotropy = c.VK_TRUE;
        var device_info = std.mem.zeroes(c.VkDeviceCreateInfo);
        device_info.sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
        device_info.pEnabledFeatures = &enabled_features;
        device_info.queueCreateInfoCount = 1;
        device_info.pQueueCreateInfos = &queue_info;
        device_info.enabledExtensionCount = extensions.len;
        device_info.ppEnabledExtensionNames = @ptrCast(&extensions);

        try check(c.vkCreateDevice(self.physical_device, &device_info, null, &self.device), "vkCreateDevice");
        c.vkGetDeviceQueue(self.device, self.queue_family_index, 0, &self.queue);
        std.log.info("Vulkan logical device and queue created", .{});
    }

    fn createCommandPool(self: *Rhi) !void {
        var info = std.mem.zeroes(c.VkCommandPoolCreateInfo);
        info.sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
        info.flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
        info.queueFamilyIndex = self.queue_family_index;
        try check(c.vkCreateCommandPool(self.device, &info, null, &self.command_pool), "vkCreateCommandPool");

        var allocation = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
        allocation.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        allocation.commandPool = self.command_pool;
        allocation.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        allocation.commandBufferCount = 1;
        try check(c.vkAllocateCommandBuffers(self.device, &allocation, &self.command_buffer), "vkAllocateCommandBuffers");
    }

    fn createSyncObjects(self: *Rhi) !void {
        var semaphore_info = std.mem.zeroes(c.VkSemaphoreCreateInfo);
        semaphore_info.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
        try check(c.vkCreateSemaphore(self.device, &semaphore_info, null, &self.image_available), "vkCreateSemaphore(image_available)");

        var fence_info = std.mem.zeroes(c.VkFenceCreateInfo);
        fence_info.sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
        fence_info.flags = c.VK_FENCE_CREATE_SIGNALED_BIT;
        try check(c.vkCreateFence(self.device, &fence_info, null, &self.in_flight), "vkCreateFence");
    }

    fn createSwapchain(self: *Rhi, requested_extent: types.Extent2D) !void {
        errdefer self.destroySwapchainResources();
        var capabilities: c.VkSurfaceCapabilitiesKHR = undefined;
        try check(
            c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(self.physical_device, self.surface, &capabilities),
            "vkGetPhysicalDeviceSurfaceCapabilitiesKHR",
        );

        if ((capabilities.supportedUsageFlags & c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT) == 0) {
            return error.ColorAttachmentUnsupported;
        }

        var format_count: u32 = 0;
        try check(
            c.vkGetPhysicalDeviceSurfaceFormatsKHR(self.physical_device, self.surface, &format_count, null),
            "vkGetPhysicalDeviceSurfaceFormatsKHR(count)",
        );
        if (format_count == 0) return error.NoSurfaceFormat;
        const formats = try allocator.alloc(c.VkSurfaceFormatKHR, format_count);
        defer allocator.free(formats);
        try check(
            c.vkGetPhysicalDeviceSurfaceFormatsKHR(self.physical_device, self.surface, &format_count, formats.ptr),
            "vkGetPhysicalDeviceSurfaceFormatsKHR(list)",
        );

        var chosen_format = formats[0];
        for (formats) |candidate| {
            if (candidate.format == c.VK_FORMAT_B8G8R8A8_SRGB and
                candidate.colorSpace == c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR)
            {
                chosen_format = candidate;
                break;
            }
        }
        if (chosen_format.format == c.VK_FORMAT_UNDEFINED) {
            chosen_format.format = c.VK_FORMAT_B8G8R8A8_UNORM;
        }

        const chosen_extent = chooseExtent(capabilities, requested_extent);
        if (chosen_extent.width == 0 or chosen_extent.height == 0) {
            return error.SurfaceSuspended;
        }

        var image_count = capabilities.minImageCount + 1;
        if (capabilities.maxImageCount != 0 and image_count > capabilities.maxImageCount) {
            image_count = capabilities.maxImageCount;
        }

        var info = std.mem.zeroes(c.VkSwapchainCreateInfoKHR);
        info.sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
        info.surface = self.surface;
        info.minImageCount = image_count;
        info.imageFormat = chosen_format.format;
        info.imageColorSpace = chosen_format.colorSpace;
        info.imageExtent = .{ .width = chosen_extent.width, .height = chosen_extent.height };
        info.imageArrayLayers = 1;
        info.imageUsage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
        info.imageSharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
        info.preTransform = capabilities.currentTransform;
        const composite_alpha = chooseCompositeAlpha(@intCast(capabilities.supportedCompositeAlpha)) orelse
            return error.NoCompositeAlphaMode;
        info.compositeAlpha = @intCast(composite_alpha);
        info.presentMode = c.VK_PRESENT_MODE_FIFO_KHR;
        info.clipped = c.VK_TRUE;

        try check(c.vkCreateSwapchainKHR(self.device, &info, null, &self.swapchain), "vkCreateSwapchainKHR");
        self.swapchain_format = chosen_format.format;
        self.swapchain_color_space = chosen_format.colorSpace;
        self.swapchain_extent = chosen_extent;
        self.requested_extent = requested_extent;

        var actual_image_count: u32 = 0;
        try check(
            c.vkGetSwapchainImagesKHR(self.device, self.swapchain, &actual_image_count, null),
            "vkGetSwapchainImagesKHR(count)",
        );
        const images = try allocator.alloc(c.VkImage, actual_image_count);
        self.swapchain_images = images;
        try check(
            c.vkGetSwapchainImagesKHR(self.device, self.swapchain, &actual_image_count, images.ptr),
            "vkGetSwapchainImagesKHR(list)",
        );
        try self.createRenderFinishedSemaphores(actual_image_count);

        try self.createRenderPass();
        self.render_pass_generation += 1;
        try self.rebuildAllPipelines();
        try self.createImageViewsAndFramebuffers();
        std.log.info("Vulkan swapchain created: format={d}, extent={d}x{d}, images={d}", .{
            self.swapchain_format,
            self.swapchain_extent.width,
            self.swapchain_extent.height,
            actual_image_count,
        });
    }

    fn createTextureDescriptors(self: *Rhi) !void {
        var binding = std.mem.zeroes(c.VkDescriptorSetLayoutBinding);
        binding.binding = 0;
        binding.descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        binding.descriptorCount = 1;
        binding.stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT;

        var layout_info = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
        layout_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        layout_info.bindingCount = 1;
        layout_info.pBindings = &binding;
        try check(c.vkCreateDescriptorSetLayout(
            self.device,
            &layout_info,
            null,
            &self.texture_descriptor_set_layout,
        ), "vkCreateDescriptorSetLayout(texture)");

        var pool_size = std.mem.zeroes(c.VkDescriptorPoolSize);
        pool_size.type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        pool_size.descriptorCount = max_textures;

        var pool_info = std.mem.zeroes(c.VkDescriptorPoolCreateInfo);
        pool_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
        pool_info.flags = c.VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT;
        pool_info.maxSets = max_textures;
        pool_info.poolSizeCount = 1;
        pool_info.pPoolSizes = &pool_size;
        try check(c.vkCreateDescriptorPool(
            self.device,
            &pool_info,
            null,
            &self.descriptor_pool,
        ), "vkCreateDescriptorPool(texture)");
    }

    fn destroyTextureDescriptors(self: *Rhi) void {
        if (self.descriptor_pool != null) {
            c.vkDestroyDescriptorPool(self.device, self.descriptor_pool, null);
            self.descriptor_pool = null;
        }
        if (self.texture_descriptor_set_layout != null) {
            c.vkDestroyDescriptorSetLayout(self.device, self.texture_descriptor_set_layout, null);
            self.texture_descriptor_set_layout = null;
        }
    }

    fn createTextureImage(self: *Rhi, destination: *TextureSlot, desc: types.TextureUploadDesc) !void {
        const upload_bytes = try textureUploadBytes(desc);
        const mip_level_count: u32 = @intCast(1 + desc.mip_levels.len);
        var image_info = std.mem.zeroes(c.VkImageCreateInfo);
        image_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        image_info.imageType = c.VK_IMAGE_TYPE_2D;
        image_info.format = c.VK_FORMAT_R8G8B8A8_SRGB;
        image_info.extent = .{ .width = desc.width, .height = desc.height, .depth = 1 };
        image_info.mipLevels = mip_level_count;
        image_info.arrayLayers = 1;
        image_info.samples = c.VK_SAMPLE_COUNT_1_BIT;
        image_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
        image_info.usage = c.VK_IMAGE_USAGE_TRANSFER_DST_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT;
        image_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
        image_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        try check(c.vkCreateImage(self.device, &image_info, null, &destination.image), "vkCreateImage(texture)");

        var requirements: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(self.device, destination.image, &requirements);
        var memory_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
        memory_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        memory_info.allocationSize = requirements.size;
        memory_info.memoryTypeIndex = try self.findMemoryType(requirements.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        try check(c.vkAllocateMemory(self.device, &memory_info, null, &destination.memory), "vkAllocateMemory(texture)");
        try check(c.vkBindImageMemory(self.device, destination.image, destination.memory, 0), "vkBindImageMemory(texture)");

        const staging = try self.createBuffer(
            @intCast(upload_bytes),
            c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        );
        defer self.destroyBuffer(staging);

        var mapped: ?*anyopaque = null;
        try check(c.vkMapMemory(self.device, staging.memory, 0, @intCast(upload_bytes), 0, &mapped), "vkMapMemory(texture)");
        const mapped_bytes: [*]u8 = @ptrCast(mapped.?);
        var upload_offset: usize = 0;
        @memcpy(mapped_bytes[upload_offset .. upload_offset + desc.rgba8.len], desc.rgba8);
        upload_offset += desc.rgba8.len;
        for (desc.mip_levels) |level| {
            @memcpy(mapped_bytes[upload_offset .. upload_offset + level.rgba8.len], level.rgba8);
            upload_offset += level.rgba8.len;
        }
        c.vkUnmapMemory(self.device, staging.memory);
        destination.mip_levels = mip_level_count;
        destination.sampler_profile = desc.sampler_profile;
        try self.uploadTexture(staging.buffer, destination.image, desc);
    }

    fn createTextureViewSamplerDescriptor(self: *Rhi, destination: *TextureSlot) !void {
        var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
        view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        view_info.image = destination.image;
        view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        view_info.format = c.VK_FORMAT_R8G8B8A8_SRGB;
        view_info.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
        view_info.subresourceRange.levelCount = destination.mip_levels;
        view_info.subresourceRange.layerCount = 1;
        try check(c.vkCreateImageView(self.device, &view_info, null, &destination.view), "vkCreateImageView(texture)");

        var sampler_info = std.mem.zeroes(c.VkSamplerCreateInfo);
        sampler_info.sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
        sampler_info.addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sampler_info.addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sampler_info.addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        switch (destination.sampler_profile) {
            .pixel_nearest => {
                sampler_info.magFilter = c.VK_FILTER_NEAREST;
                sampler_info.minFilter = c.VK_FILTER_NEAREST;
                sampler_info.mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_NEAREST;
                sampler_info.maxLod = @floatFromInt(destination.mip_levels - 1);
            },
            .smooth_linear => {
                sampler_info.magFilter = c.VK_FILTER_LINEAR;
                sampler_info.minFilter = c.VK_FILTER_LINEAR;
                sampler_info.mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_NEAREST;
                sampler_info.maxLod = 0.0;
            },
            .smooth_mipmap => {
                sampler_info.magFilter = c.VK_FILTER_LINEAR;
                sampler_info.minFilter = c.VK_FILTER_LINEAR;
                sampler_info.mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_LINEAR;
                sampler_info.maxLod = @floatFromInt(destination.mip_levels - 1);
            },
            .smooth_mipmap_anisotropic => {
                sampler_info.magFilter = c.VK_FILTER_LINEAR;
                sampler_info.minFilter = c.VK_FILTER_LINEAR;
                sampler_info.mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_LINEAR;
                sampler_info.maxLod = @floatFromInt(destination.mip_levels - 1);
            },
        }
        if (destination.sampler_profile == .smooth_mipmap_anisotropic and self.sampler_anisotropy_supported) {
            destination.anisotropy_enabled = true;
            destination.anisotropy_level = @min(4.0, self.max_sampler_anisotropy);
            sampler_info.anisotropyEnable = c.VK_TRUE;
            sampler_info.maxAnisotropy = destination.anisotropy_level;
        }
        try check(c.vkCreateSampler(self.device, &sampler_info, null, &destination.sampler), "vkCreateSampler(texture)");

        var allocate_info = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
        allocate_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        allocate_info.descriptorPool = self.descriptor_pool;
        allocate_info.descriptorSetCount = 1;
        allocate_info.pSetLayouts = &self.texture_descriptor_set_layout;
        try check(c.vkAllocateDescriptorSets(self.device, &allocate_info, &destination.descriptor_set), "vkAllocateDescriptorSets(texture)");

        var descriptor_image = std.mem.zeroes(c.VkDescriptorImageInfo);
        descriptor_image.sampler = destination.sampler;
        descriptor_image.imageView = destination.view;
        descriptor_image.imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

        var write = std.mem.zeroes(c.VkWriteDescriptorSet);
        write.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        write.dstSet = destination.descriptor_set;
        write.dstBinding = 0;
        write.descriptorCount = 1;
        write.descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        write.pImageInfo = &descriptor_image;
        c.vkUpdateDescriptorSets(self.device, 1, &write, 0, null);
    }

    fn uploadTexture(self: *Rhi, staging: c.VkBuffer, image: c.VkImage, desc: types.TextureUploadDesc) !void {
        const mip_level_count: u32 = @intCast(1 + desc.mip_levels.len);
        try check(c.vkResetCommandBuffer(self.command_buffer, 0), "vkResetCommandBuffer(texture)");
        var begin_info = std.mem.zeroes(c.VkCommandBufferBeginInfo);
        begin_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        begin_info.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        try check(c.vkBeginCommandBuffer(self.command_buffer, &begin_info), "vkBeginCommandBuffer(texture)");

        var barrier = std.mem.zeroes(c.VkImageMemoryBarrier);
        barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        barrier.dstAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
        barrier.oldLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        barrier.newLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        barrier.image = image;
        barrier.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
        barrier.subresourceRange.levelCount = mip_level_count;
        barrier.subresourceRange.layerCount = 1;
        c.vkCmdPipelineBarrier(self.command_buffer, c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, c.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &barrier);

        // 一个 staging buffer 连续存放所有 levels；每个 copy region 指向对应 Vulkan mipLevel。
        var copies: [max_texture_mip_levels]c.VkBufferImageCopy = undefined;
        copies[0] = std.mem.zeroes(c.VkBufferImageCopy);
        copies[0].imageSubresource.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
        copies[0].imageSubresource.mipLevel = 0;
        copies[0].imageSubresource.layerCount = 1;
        copies[0].imageExtent = .{ .width = desc.width, .height = desc.height, .depth = 1 };
        var upload_offset = desc.rgba8.len;
        for (desc.mip_levels, 0..) |level, index| {
            const copy_index = index + 1;
            copies[copy_index] = std.mem.zeroes(c.VkBufferImageCopy);
            copies[copy_index].bufferOffset = @intCast(upload_offset);
            copies[copy_index].imageSubresource.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
            copies[copy_index].imageSubresource.mipLevel = @intCast(copy_index);
            copies[copy_index].imageSubresource.layerCount = 1;
            copies[copy_index].imageExtent = .{ .width = level.width, .height = level.height, .depth = 1 };
            upload_offset += level.rgba8.len;
        }
        c.vkCmdCopyBufferToImage(
            self.command_buffer,
            staging,
            image,
            c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            mip_level_count,
            &copies[0],
        );

        barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
        barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
        barrier.oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        barrier.newLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        c.vkCmdPipelineBarrier(self.command_buffer, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &barrier);

        try check(c.vkEndCommandBuffer(self.command_buffer), "vkEndCommandBuffer(texture)");
        try check(c.vkResetFences(self.device, 1, &self.in_flight), "vkResetFences(texture)");
        var submit = std.mem.zeroes(c.VkSubmitInfo);
        submit.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submit.commandBufferCount = 1;
        submit.pCommandBuffers = &self.command_buffer;
        try check(c.vkQueueSubmit(self.queue, 1, &submit, self.in_flight), "vkQueueSubmit(texture)");
        try check(c.vkWaitForFences(self.device, 1, &self.in_flight, c.VK_TRUE, std.math.maxInt(u64)), "vkWaitForFences(texture)");
    }
    fn createBuffer(self: *Rhi, size: c.VkDeviceSize, usage: u32, properties: u32) !BufferAllocation {
        var info = std.mem.zeroes(c.VkBufferCreateInfo);
        info.sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
        info.size = size;
        info.usage = usage;
        info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
        var allocation = BufferAllocation{};
        errdefer self.destroyBuffer(allocation);
        try check(c.vkCreateBuffer(self.device, &info, null, &allocation.buffer), "vkCreateBuffer(texture staging)");

        var requirements: c.VkMemoryRequirements = undefined;
        c.vkGetBufferMemoryRequirements(self.device, allocation.buffer, &requirements);
        var memory_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
        memory_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        memory_info.allocationSize = requirements.size;
        memory_info.memoryTypeIndex = try self.findMemoryType(requirements.memoryTypeBits, properties);
        try check(c.vkAllocateMemory(self.device, &memory_info, null, &allocation.memory), "vkAllocateMemory(texture staging)");
        try check(c.vkBindBufferMemory(self.device, allocation.buffer, allocation.memory, 0), "vkBindBufferMemory(texture staging)");
        return allocation;
    }

    fn destroyBuffer(self: *Rhi, allocation: BufferAllocation) void {
        if (allocation.buffer != null) c.vkDestroyBuffer(self.device, allocation.buffer, null);
        if (allocation.memory != null) c.vkFreeMemory(self.device, allocation.memory, null);
    }

    fn destroyTextureSlot(self: *Rhi, slot: *TextureSlot) void {
        if (slot.descriptor_set != null and self.descriptor_pool != null) {
            _ = c.vkFreeDescriptorSets(self.device, self.descriptor_pool, 1, &slot.descriptor_set);
        }
        if (slot.sampler != null) c.vkDestroySampler(self.device, slot.sampler, null);
        if (slot.view != null) c.vkDestroyImageView(self.device, slot.view, null);
        if (slot.image != null) c.vkDestroyImage(self.device, slot.image, null);
        if (slot.memory != null) c.vkFreeMemory(self.device, slot.memory, null);
        slot.* = .{};
    }

    fn destroyTextureObjects(self: *Rhi) void {
        for (&self.texture_slots) |*slot| {
            if (slot.image != null) self.destroyTextureSlot(slot);
        }
    }

    fn findMemoryType(self: *Rhi, type_bits: u32, properties: u32) !u32 {
        var memory_properties: c.VkPhysicalDeviceMemoryProperties = undefined;
        c.vkGetPhysicalDeviceMemoryProperties(self.physical_device, &memory_properties);
        for (0..@intCast(memory_properties.memoryTypeCount)) |index| {
            const bit: u32 = @as(u32, 1) << @intCast(index);
            if ((type_bits & bit) != 0 and
                (memory_properties.memoryTypes[index].propertyFlags & properties) == properties)
            {
                return @intCast(index);
            }
        }
        return error.NoCompatibleMemoryType;
    }
    fn createRenderFinishedSemaphores(self: *Rhi, count: u32) !void {
        const semaphores = try allocator.alloc(c.VkSemaphore, count);
        @memset(semaphores, null);
        self.render_finished = semaphores;

        var info = std.mem.zeroes(c.VkSemaphoreCreateInfo);
        info.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
        for (semaphores) |*semaphore| {
            try check(
                c.vkCreateSemaphore(self.device, &info, null, semaphore),
                "vkCreateSemaphore(render_finished)",
            );
        }
    }

    fn createRenderPass(self: *Rhi) !void {
        var attachment = std.mem.zeroes(c.VkAttachmentDescription);
        attachment.format = self.swapchain_format;
        attachment.samples = c.VK_SAMPLE_COUNT_1_BIT;
        attachment.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
        attachment.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
        attachment.stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        attachment.stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
        attachment.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        attachment.finalLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;

        var color_ref = std.mem.zeroes(c.VkAttachmentReference);
        color_ref.attachment = 0;
        color_ref.layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

        var subpass = std.mem.zeroes(c.VkSubpassDescription);
        subpass.pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS;
        subpass.colorAttachmentCount = 1;
        subpass.pColorAttachments = &color_ref;

        var dependency = std.mem.zeroes(c.VkSubpassDependency);
        dependency.srcSubpass = c.VK_SUBPASS_EXTERNAL;
        dependency.dstSubpass = 0;
        dependency.srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        dependency.dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        dependency.dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;

        var info = std.mem.zeroes(c.VkRenderPassCreateInfo);
        info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
        info.attachmentCount = 1;
        info.pAttachments = &attachment;
        info.subpassCount = 1;
        info.pSubpasses = &subpass;
        info.dependencyCount = 1;
        info.pDependencies = &dependency;
        try check(c.vkCreateRenderPass(self.device, &info, null, &self.render_pass), "vkCreateRenderPass");
    }

    fn createImageViewsAndFramebuffers(self: *Rhi) !void {
        const images = self.swapchain_images orelse return error.SwapchainImagesUnavailable;
        const views = try allocator.alloc(c.VkImageView, images.len);
        @memset(views, null);
        self.swapchain_views = views;

        const framebuffers = try allocator.alloc(c.VkFramebuffer, images.len);
        @memset(framebuffers, null);
        self.framebuffers = framebuffers;

        for (images, 0..) |image, index| {
            var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
            view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
            view_info.image = image;
            view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
            view_info.format = self.swapchain_format;
            view_info.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
            view_info.subresourceRange.baseMipLevel = 0;
            view_info.subresourceRange.levelCount = 1;
            view_info.subresourceRange.baseArrayLayer = 0;
            view_info.subresourceRange.layerCount = 1;
            try check(
                c.vkCreateImageView(self.device, &view_info, null, &views[index]),
                "vkCreateImageView",
            );

            var framebuffer_info = std.mem.zeroes(c.VkFramebufferCreateInfo);
            framebuffer_info.sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
            framebuffer_info.renderPass = self.render_pass;
            framebuffer_info.attachmentCount = 1;
            framebuffer_info.pAttachments = &views[index];
            framebuffer_info.width = self.swapchain_extent.width;
            framebuffer_info.height = self.swapchain_extent.height;
            framebuffer_info.layers = 1;
            try check(
                c.vkCreateFramebuffer(self.device, &framebuffer_info, null, &framebuffers[index]),
                "vkCreateFramebuffer",
            );
        }
    }

    fn destroySwapchainResources(self: *Rhi) void {
        self.destroyPipelineObjects();
        if (self.framebuffers) |framebuffers| {
            for (framebuffers) |framebuffer| {
                if (framebuffer != null) c.vkDestroyFramebuffer(self.device, framebuffer, null);
            }
            allocator.free(framebuffers);
            self.framebuffers = null;
        }
        if (self.swapchain_views) |views| {
            for (views) |view| {
                if (view != null) c.vkDestroyImageView(self.device, view, null);
            }
            allocator.free(views);
            self.swapchain_views = null;
        }
        if (self.render_finished) |semaphores| {
            for (semaphores) |semaphore| {
                if (semaphore != null) c.vkDestroySemaphore(self.device, semaphore, null);
            }
            allocator.free(semaphores);
            self.render_finished = null;
        }
        if (self.render_pass != null) {
            c.vkDestroyRenderPass(self.device, self.render_pass, null);
            self.render_pass = null;
        }
        if (self.swapchain != null) {
            c.vkDestroySwapchainKHR(self.device, self.swapchain, null);
            self.swapchain = null;
        }
        if (self.swapchain_images) |images| {
            allocator.free(images);
            self.swapchain_images = null;
        }
        self.swapchain_extent = .{};
        self.requested_extent = .{};
    }

    fn recreateBeginResult(self: *Rhi, requested_extent: types.Extent2D) !BeginFrameResult {
        return switch (try self.recreateForFrame(requested_extent)) {
            .recreated => .recreated,
            .skipped_minimized => .skipped_minimized,
            .presented => error.InvalidRecreateOutcome,
        };
    }

    fn recreateForFrame(self: *Rhi, requested_extent: types.Extent2D) !types.FrameOutcome {
        self.recreateSwapchain(requested_extent) catch |err| switch (err) {
            error.SurfaceSuspended => return .skipped_minimized,
            else => return err,
        };
        return .recreated;
    }

    fn recreateSwapchain(self: *Rhi, requested_extent: types.Extent2D) !void {
        if (requested_extent.width == 0 or requested_extent.height == 0) {
            return error.SurfaceSuspended;
        }
        var capabilities: c.VkSurfaceCapabilitiesKHR = undefined;
        try check(
            c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(self.physical_device, self.surface, &capabilities),
            "vkGetPhysicalDeviceSurfaceCapabilitiesKHR(recreate)",
        );
        const target_extent = chooseExtent(capabilities, requested_extent);
        if (target_extent.width == 0 or target_extent.height == 0) return error.SurfaceSuspended;

        try check(c.vkDeviceWaitIdle(self.device), "vkDeviceWaitIdle(recreate)");
        self.destroySwapchainResources();
        try self.createSwapchain(requested_extent);
        std.log.info("Vulkan swapchain recreated", .{});
    }

    fn rebuildAllPipelines(self: *Rhi) !void {
        for (&self.pipeline_slots) |*slot| {
            if (slot.desc != null) {
                try self.rebuildPipelineSlot(slot);
            }
        }
    }

    fn rebuildPipelineSlot(self: *Rhi, slot: *PipelineSlot) !void {
        const desc = slot.desc orelse return;
        if (self.render_pass == null) return;
        if (slot.pipeline != null) {
            c.vkDestroyPipeline(self.device, slot.pipeline, null);
            slot.pipeline = null;
        }

        const vertex_module = try self.createShaderModule(desc.vertex_shader, "vertex");
        defer c.vkDestroyShaderModule(self.device, vertex_module, null);
        const fragment_module = try self.createShaderModule(desc.fragment_shader, "fragment");
        defer c.vkDestroyShaderModule(self.device, fragment_module, null);

        const entry_point: [*:0]const u8 = "main";
        var stages = [_]c.VkPipelineShaderStageCreateInfo{
            .{
                .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .stage = c.VK_SHADER_STAGE_VERTEX_BIT,
                .module = vertex_module,
                .pName = entry_point,
            },
            .{
                .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT,
                .module = fragment_module,
                .pName = entry_point,
            },
        };

        var vertex_input = std.mem.zeroes(c.VkPipelineVertexInputStateCreateInfo);
        vertex_input.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;

        var input_assembly = std.mem.zeroes(c.VkPipelineInputAssemblyStateCreateInfo);
        input_assembly.sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
        input_assembly.topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
        input_assembly.primitiveRestartEnable = c.VK_FALSE;

        var viewport_state = std.mem.zeroes(c.VkPipelineViewportStateCreateInfo);
        viewport_state.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
        viewport_state.viewportCount = 1;
        viewport_state.scissorCount = 1;

        var rasterization = std.mem.zeroes(c.VkPipelineRasterizationStateCreateInfo);
        rasterization.sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
        rasterization.depthClampEnable = c.VK_FALSE;
        rasterization.rasterizerDiscardEnable = c.VK_FALSE;
        rasterization.polygonMode = c.VK_POLYGON_MODE_FILL;
        rasterization.cullMode = c.VK_CULL_MODE_NONE;
        rasterization.frontFace = c.VK_FRONT_FACE_COUNTER_CLOCKWISE;
        rasterization.depthBiasEnable = c.VK_FALSE;
        rasterization.lineWidth = 1.0;

        var multisample = std.mem.zeroes(c.VkPipelineMultisampleStateCreateInfo);
        multisample.sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
        multisample.rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT;

        var blend_attachment = std.mem.zeroes(c.VkPipelineColorBlendAttachmentState);
        blend_attachment.blendEnable = c.VK_TRUE;
        blend_attachment.srcColorBlendFactor = c.VK_BLEND_FACTOR_SRC_ALPHA;
        blend_attachment.dstColorBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
        blend_attachment.colorBlendOp = c.VK_BLEND_OP_ADD;
        blend_attachment.srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE;
        blend_attachment.dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
        blend_attachment.alphaBlendOp = c.VK_BLEND_OP_ADD;
        blend_attachment.colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT |
            c.VK_COLOR_COMPONENT_G_BIT |
            c.VK_COLOR_COMPONENT_B_BIT |
            c.VK_COLOR_COMPONENT_A_BIT;

        var color_blend = std.mem.zeroes(c.VkPipelineColorBlendStateCreateInfo);
        color_blend.sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
        color_blend.logicOpEnable = c.VK_FALSE;
        color_blend.attachmentCount = 1;
        color_blend.pAttachments = &blend_attachment;

        var dynamic_states = [_]c.VkDynamicState{
            c.VK_DYNAMIC_STATE_VIEWPORT,
            c.VK_DYNAMIC_STATE_SCISSOR,
        };
        var dynamic_state = std.mem.zeroes(c.VkPipelineDynamicStateCreateInfo);
        dynamic_state.sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
        dynamic_state.dynamicStateCount = dynamic_states.len;
        dynamic_state.pDynamicStates = &dynamic_states;

        var pipeline_info = std.mem.zeroes(c.VkGraphicsPipelineCreateInfo);
        pipeline_info.sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
        pipeline_info.stageCount = stages.len;
        pipeline_info.pStages = &stages;
        pipeline_info.pVertexInputState = &vertex_input;
        pipeline_info.pInputAssemblyState = &input_assembly;
        pipeline_info.pViewportState = &viewport_state;
        pipeline_info.pRasterizationState = &rasterization;
        pipeline_info.pMultisampleState = &multisample;
        pipeline_info.pColorBlendState = &color_blend;
        pipeline_info.pDynamicState = &dynamic_state;
        pipeline_info.layout = slot.layout;
        pipeline_info.renderPass = self.render_pass;
        pipeline_info.subpass = 0;

        try check(
            c.vkCreateGraphicsPipelines(self.device, null, 1, &pipeline_info, null, &slot.pipeline),
            "vkCreateGraphicsPipelines",
        );
        std.log.info("RHI graphics pipeline rebuilt (generation={d})", .{self.render_pass_generation});
    }

    fn createShaderModule(self: *Rhi, bytes: []const u8, stage: []const u8) !c.VkShaderModule {
        if (bytes.len == 0 or bytes.len % 4 != 0) {
            std.log.err("Invalid {s} SPIR-V byte length: {d}", .{ stage, bytes.len });
            return error.InvalidShaderCode;
        }
        const words = try allocator.alloc(u32, bytes.len / 4);
        defer allocator.free(words);
        @memcpy(std.mem.sliceAsBytes(words), bytes);

        var info = std.mem.zeroes(c.VkShaderModuleCreateInfo);
        info.sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
        info.codeSize = bytes.len;
        info.pCode = words.ptr;
        var module: c.VkShaderModule = null;
        try check(c.vkCreateShaderModule(self.device, &info, null, &module), "vkCreateShaderModule");
        return module;
    }

    fn destroyPipelineObjects(self: *Rhi) void {
        for (&self.pipeline_slots) |*slot| {
            if (slot.pipeline != null) {
                c.vkDestroyPipeline(self.device, slot.pipeline, null);
                slot.pipeline = null;
            }
        }
    }

    fn destroyPipelineLayouts(self: *Rhi) void {
        for (&self.pipeline_slots) |*slot| {
            if (slot.layout != null) {
                c.vkDestroyPipelineLayout(self.device, slot.layout, null);
            }
            slot.* = .{};
        }
    }

    fn check(result: c.VkResult, stage: []const u8) !void {
        if (result != c.VK_SUCCESS) {
            std.log.err("{s} failed (VkResult={any})", .{ stage, result });
            return error.VulkanCallFailed;
        }
    }

    fn chooseCompositeAlpha(flags: u32) ?u32 {
        const candidates = [_]u32{
            @intCast(c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR),
            @intCast(c.VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR),
            @intCast(c.VK_COMPOSITE_ALPHA_POST_MULTIPLIED_BIT_KHR),
            @intCast(c.VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR),
        };
        for (candidates) |candidate| {
            if ((flags & candidate) != 0) return candidate;
        }
        return null;
    }

    fn chooseExtent(capabilities: c.VkSurfaceCapabilitiesKHR, requested: types.Extent2D) types.Extent2D {
        if (capabilities.currentExtent.width != std.math.maxInt(u32)) {
            return .{
                .width = capabilities.currentExtent.width,
                .height = capabilities.currentExtent.height,
            };
        }
        return .{
            .width = std.math.clamp(requested.width, capabilities.minImageExtent.width, capabilities.maxImageExtent.width),
            .height = std.math.clamp(requested.height, capabilities.minImageExtent.height, capabilities.maxImageExtent.height),
        };
    }
};
