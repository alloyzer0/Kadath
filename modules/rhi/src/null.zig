const std = @import("std");
const types = @import("types.zig");

const max_pipelines: usize = 8;
const max_textures: usize = 8;
const max_texture_mip_levels: usize = 32;
const max_draw_texture_trace: usize = 256;
const max_instance_data_trace: usize = 4096;

pub const Extent2D = types.Extent2D;
pub const FrameOutcome = types.FrameOutcome;
pub const PipelineHandle = types.PipelineHandle;
pub const invalid_pipeline = types.invalid_pipeline;
pub const TextureHandle = types.TextureHandle;
pub const invalid_texture = types.invalid_texture;
pub const max_instance_data_bytes_per_binding = types.max_instance_data_bytes_per_binding;
pub const max_instance_data_bytes_per_frame = types.max_instance_data_bytes_per_frame;
pub const max_instance_data_bindings_per_frame = types.max_instance_data_bindings_per_frame;
pub const TextureSamplerProfile = types.TextureSamplerProfile;
pub const TextureMipUpload = types.TextureMipUpload;
pub const TextureUploadDesc = types.TextureUploadDesc;
pub const GraphicsPipelineDesc = types.GraphicsPipelineDesc;

const PipelineSlot = struct {
    desc: ?types.GraphicsPipelineDesc = null,
};

const TextureSlot = struct {
    live: bool = false,
    sampler_profile: types.TextureSamplerProfile = .smooth_mipmap,
};

/// Null 只记录可观察的命令数量；这些信息不从生产 RHI 模块导出。
pub const NullStats = struct {
    pipeline_binds: u32 = 0,
    texture_binds: u32 = 0,
    push_constant_writes: u32 = 0,
    instance_data_binds: u32 = 0,
    instance_data_bytes: u32 = 0,
    instance_data_trace: [max_instance_data_trace]u8 = [_]u8{0} ** max_instance_data_trace,
    instance_data_trace_len: usize = 0,
    draws: u32 = 0,
    instances_drawn: u32 = 0,
    frames_finished: u32 = 0,
    failed_frames_consumed: u32 = 0,
    recreates: u32 = 0,
    textures_created: u32 = 0,
    textures_destroyed: u32 = 0,
    textures_live: u32 = 0,
    texture_sampler_trace: [max_textures]types.TextureSamplerProfile = [_]types.TextureSamplerProfile{.smooth_mipmap} ** max_textures,
    texture_sampler_trace_len: usize = 0,
    draw_texture_trace: [max_draw_texture_trace]types.TextureHandle = [_]types.TextureHandle{types.invalid_texture} ** max_draw_texture_trace,
    draw_texture_trace_len: usize = 0,
};

pub const FrameEncoder = struct {
    rhi: *Rhi,
    frame_token: u64,
    bound_pipeline: types.PipelineHandle = types.invalid_pipeline,
    bound_texture: types.TextureHandle = types.invalid_texture,
    bound_instance_capacity: u32 = 0,
    instance_data_bytes_uploaded: usize = 0,
    instance_data_binding_count: usize = 0,
    recording: bool = true,
    finished: bool = false,

    pub fn bindPipeline(self: *FrameEncoder, pipeline: types.PipelineHandle) !void {
        if (!self.recording or self.finished) return error.FrameAlreadyFinished;
        try self.rhi.validateFrame(self);
        try self.rhi.validatePipeline(pipeline);
        self.bound_pipeline = pipeline;
        self.bound_instance_capacity = 0;
        self.rhi.stats_value.pipeline_binds += 1;
    }

    pub fn bindTexture(self: *FrameEncoder, texture: types.TextureHandle) !void {
        if (!self.recording or self.finished) return error.FrameAlreadyFinished;
        try self.rhi.validateFrame(self);
        if (self.bound_pipeline == types.invalid_pipeline) return error.InvalidPipeline;
        const pipeline = self.rhi.pipelineSlot(self.bound_pipeline) orelse return error.InvalidPipeline;
        const desc = pipeline.desc orelse return error.InvalidPipeline;
        if (!desc.uses_texture) return error.TextureBindingUnsupported;
        _ = self.rhi.textureSlot(texture) orelse return error.InvalidTexture;
        self.bound_texture = texture;
        self.rhi.stats_value.texture_binds += 1;
    }

    pub fn pushConstants(self: *FrameEncoder, bytes: []const u8) !void {
        if (!self.recording or self.finished) return error.FrameAlreadyFinished;
        try self.rhi.validateFrame(self);
        if (self.bound_pipeline == types.invalid_pipeline) return error.InvalidPipeline;
        const slot = self.rhi.pipelineSlot(self.bound_pipeline) orelse return error.InvalidPipeline;
        const desc = slot.desc orelse return error.InvalidPipeline;
        if (bytes.len > desc.push_constant_size) return error.PipelinePushConstantTooLarge;
        if (bytes.len % 4 != 0) return error.PushConstantAlignment;
        self.rhi.stats_value.push_constant_writes += 1;
    }

    pub fn bindInstanceData(self: *FrameEncoder, bytes: []const u8) !void {
        if (!self.recording or self.finished) return error.FrameAlreadyFinished;
        try self.rhi.validateFrame(self);
        const desc = try self.boundPipelineDesc();
        if (desc.instance_data_stride == 0) return error.InstanceDataBindingUnsupported;
        const stride: usize = @intCast(desc.instance_data_stride);
        if (bytes.len == 0 or bytes.len % stride != 0) return error.InvalidInstanceDataSize;
        if (bytes.len > types.max_instance_data_bytes_per_binding) return error.InstanceDataBindingSizeLimitReached;
        if (self.instance_data_binding_count >= types.max_instance_data_bindings_per_frame) {
            return error.InstanceDataBindingLimitReached;
        }
        if (bytes.len > types.max_instance_data_bytes_per_frame - self.instance_data_bytes_uploaded) {
            return error.InstanceDataFrameLimitReached;
        }

        self.instance_data_binding_count += 1;
        self.instance_data_bytes_uploaded += bytes.len;
        self.bound_instance_capacity = @intCast(bytes.len / stride);
        self.rhi.stats_value.instance_data_binds += 1;
        self.rhi.stats_value.instance_data_bytes += @intCast(bytes.len);
        const trace_remaining = max_instance_data_trace - self.rhi.stats_value.instance_data_trace_len;
        const trace_bytes = @min(trace_remaining, bytes.len);
        if (trace_bytes != 0) {
            const trace_start = self.rhi.stats_value.instance_data_trace_len;
            @memcpy(self.rhi.stats_value.instance_data_trace[trace_start .. trace_start + trace_bytes], bytes[0..trace_bytes]);
            self.rhi.stats_value.instance_data_trace_len += trace_bytes;
        }
    }

    pub fn draw(self: *FrameEncoder, vertex_count: u32) !void {
        return self.recordDraw(vertex_count, 1, false);
    }

    pub fn drawInstanced(self: *FrameEncoder, vertex_count: u32, instance_count: u32) !void {
        return self.recordDraw(vertex_count, instance_count, true);
    }

    fn recordDraw(self: *FrameEncoder, vertex_count: u32, instance_count: u32, require_instanced: bool) !void {
        if (!self.recording or self.finished) return error.FrameAlreadyFinished;
        try self.rhi.validateFrame(self);
        const desc = try self.boundPipelineDesc();
        if (require_instanced and desc.instance_data_stride == 0) return error.InstanceDataBindingUnsupported;
        if (vertex_count == 0) return error.InvalidDrawCount;
        if (instance_count == 0) return error.InvalidInstanceCount;
        if (desc.instance_data_stride != 0) {
            if (self.bound_instance_capacity == 0) return error.InstanceDataRequired;
            if (instance_count > self.bound_instance_capacity) return error.InstanceCountExceedsBoundData;
        }
        if (self.rhi.stats_value.draw_texture_trace_len < max_draw_texture_trace) {
            self.rhi.stats_value.draw_texture_trace[self.rhi.stats_value.draw_texture_trace_len] = self.bound_texture;
            self.rhi.stats_value.draw_texture_trace_len += 1;
        }
        self.rhi.stats_value.draws += 1;
        self.rhi.stats_value.instances_drawn += instance_count;
    }

    fn boundPipelineDesc(self: *FrameEncoder) !types.GraphicsPipelineDesc {
        if (self.bound_pipeline == types.invalid_pipeline) return error.InvalidPipeline;
        const slot = self.rhi.pipelineSlot(self.bound_pipeline) orelse return error.InvalidPipeline;
        return slot.desc orelse error.InvalidPipeline;
    }

    /// 失败帧必须释放 active token，否则下一帧会永久收到 FrameAlreadyActive。
    pub fn consumeFailedFrame(self: *FrameEncoder) void {
        if (!self.recording or self.finished) return;
        self.recording = false;
        self.finished = true;
        if (self.rhi.active_frame_token == self.frame_token) {
            self.rhi.active_frame_token = null;
        }
        self.rhi.stats_value.failed_frames_consumed += 1;
    }

    pub fn finish(self: *FrameEncoder) !types.FrameOutcome {
        if (self.finished) return error.FrameAlreadyFinished;
        if (!self.recording) return error.NoActiveFrame;
        try self.rhi.validateFrame(self);
        self.recording = false;
        self.finished = true;
        self.rhi.active_frame_token = null;
        self.rhi.stats_value.frames_finished += 1;
        return .presented;
    }
};

pub const BeginFrameResult = union(enum) {
    ready: FrameEncoder,
    skipped_minimized,
    recreated,
};

pub const Rhi = struct {
    requested_extent: types.Extent2D = .{},
    swapchain_ready: bool = false,
    next_frame_token: u64 = 0,
    active_frame_token: ?u64 = null,
    pipeline_slots: [max_pipelines]PipelineSlot = [_]PipelineSlot{.{}} ** max_pipelines,
    texture_slots: [max_textures]TextureSlot = [_]TextureSlot{.{}} ** max_textures,
    stats_value: NullStats = .{},

    pub fn init(requested_extent: types.Extent2D) !Rhi {
        return .{
            .requested_extent = requested_extent,
            // 非零尺寸表示 Vulkan 初始化阶段已经准备好 swapchain；保持首次 begin 的语义一致。
            .swapchain_ready = requested_extent.width != 0 and requested_extent.height != 0,
        };
    }

    pub fn deinit(self: *Rhi) void {
        self.active_frame_token = null;
        self.swapchain_ready = false;
        self.requested_extent = .{};
        for (&self.pipeline_slots) |*slot| slot.* = .{};
        for (&self.texture_slots) |*slot| slot.* = .{};
    }

    pub fn stats(self: *const Rhi) NullStats {
        return self.stats_value;
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
        if (desc.instance_data_stride != 0 and
            (desc.instance_data_stride % 4 != 0 or desc.instance_data_stride > types.max_instance_data_bytes_per_binding))
        {
            return error.InvalidInstanceDataStride;
        }
        for (&self.pipeline_slots, 0..) |*slot, index| {
            if (slot.desc == null) {
                slot.desc = desc;
                return @intCast(index + 1);
            }
        }
        return error.PipelineLimitReached;
    }

    pub fn destroyGraphicsPipeline(self: *Rhi, handle: types.PipelineHandle) void {
        const slot = self.pipelineSlot(handle) orelse return;
        slot.* = .{};
    }

    pub fn createTexture(self: *Rhi, desc: types.TextureUploadDesc) !types.TextureHandle {
        if (self.active_frame_token != null) return error.TextureCreationDuringFrame;
        _ = try textureUploadBytes(desc);
        for (&self.texture_slots, 0..) |*slot, index| {
            if (!slot.live) {
                slot.* = .{ .live = true, .sampler_profile = desc.sampler_profile };
                self.stats_value.textures_created += 1;
                self.stats_value.textures_live += 1;
                if (self.stats_value.texture_sampler_trace_len < max_textures) {
                    self.stats_value.texture_sampler_trace[self.stats_value.texture_sampler_trace_len] = desc.sampler_profile;
                    self.stats_value.texture_sampler_trace_len += 1;
                }
                return @intCast(index + 1);
            }
        }
        return error.TextureLimitReached;
    }

    pub fn destroyTexture(self: *Rhi, handle: types.TextureHandle) void {
        const slot = self.textureSlot(handle) orelse return;
        slot.* = .{};
        self.stats_value.textures_destroyed += 1;
        self.stats_value.textures_live -= 1;
    }

    pub fn beginFrame(self: *Rhi, requested_extent: types.Extent2D, clear_color: [4]f32) !BeginFrameResult {
        _ = clear_color;
        if (self.active_frame_token != null) return error.FrameAlreadyActive;
        if (requested_extent.width == 0 or requested_extent.height == 0) return .skipped_minimized;
        if (!self.swapchain_ready or requested_extent.width != self.requested_extent.width or
            requested_extent.height != self.requested_extent.height)
        {
            self.requested_extent = requested_extent;
            self.swapchain_ready = true;
            self.stats_value.recreates += 1;
            return .recreated;
        }
        self.next_frame_token +%= 1;
        if (self.next_frame_token == 0) self.next_frame_token = 1;
        self.active_frame_token = self.next_frame_token;
        return .{ .ready = .{ .rhi = self, .frame_token = self.next_frame_token } };
    }

    fn validateFrame(self: *Rhi, encoder: *const FrameEncoder) !void {
        const active = self.active_frame_token orelse return error.NoActiveFrame;
        if (active != encoder.frame_token) return error.StaleFrameEncoder;
    }

    fn pipelineSlot(self: *Rhi, handle: types.PipelineHandle) ?*PipelineSlot {
        if (handle == types.invalid_pipeline or handle > max_pipelines) return null;
        const slot = &self.pipeline_slots[@intCast(handle - 1)];
        if (slot.desc == null) return null;
        return slot;
    }

    fn textureSlot(self: *Rhi, handle: types.TextureHandle) ?*TextureSlot {
        if (handle == types.invalid_texture or handle > max_textures) return null;
        const slot = &self.texture_slots[@intCast(handle - 1)];
        if (!slot.live) return null;
        return slot;
    }

    fn validatePipeline(self: *Rhi, handle: types.PipelineHandle) !void {
        _ = self.pipelineSlot(handle) orelse return error.InvalidPipeline;
    }
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
    // 空 mip slice 兼容 KDAT v1；一旦提供 mip，必须提供完整连续链。
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

test "null adapter validates lifecycle and failed frame recovery" {
    var rhi = try Rhi.init(.{ .width = 64, .height = 64 });
    defer rhi.deinit();

    const shader = [_]u8{ 0, 0, 0, 0 };
    const pipeline = try rhi.createGraphicsPipeline(.{
        .vertex_shader = &shader,
        .fragment_shader = &shader,
        .push_constant_size = 32,
        .uses_texture = true,
    });
    const pixels = [_]u8{ 255, 255, 255, 255 };
    const texture = try rhi.createTexture(.{ .width = 1, .height = 1, .rgba8 = &pixels });

    const begin = try rhi.beginFrame(.{ .width = 64, .height = 64 }, .{ 0, 0, 0, 1 });
    var encoder = switch (begin) {
        .ready => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectError(error.FrameAlreadyActive, rhi.beginFrame(.{ .width = 64, .height = 64 }, .{ 0, 0, 0, 1 }));
    try std.testing.expectError(error.InvalidPipeline, encoder.bindTexture(texture));
    try encoder.bindPipeline(pipeline);
    try encoder.bindTexture(texture);
    try std.testing.expectError(error.PushConstantAlignment, encoder.pushConstants(&[_]u8{ 0, 0 }));
    try std.testing.expectError(error.InvalidDrawCount, encoder.draw(0));
    encoder.consumeFailedFrame();
    try std.testing.expectEqual(@as(?u64, null), rhi.active_frame_token);
    try std.testing.expectEqual(.skipped_minimized, try rhi.beginFrame(.{}, .{ 0, 0, 0, 1 }));
    try std.testing.expectEqual(.recreated, try rhi.beginFrame(.{ .width = 128, .height = 64 }, .{ 0, 0, 0, 1 }));
    rhi.destroyTexture(texture);
    rhi.destroyGraphicsPipeline(pipeline);
}

test "null adapter validates bindings handles and completed frames" {
    var rhi = try Rhi.init(.{ .width = 80, .height = 60 });
    defer rhi.deinit();

    const shader = [_]u8{ 0, 0, 0, 0 };
    const pipeline = try rhi.createGraphicsPipeline(.{
        .vertex_shader = &shader,
        .fragment_shader = &shader,
        .push_constant_size = 32,
        .uses_texture = false,
    });
    const pixels = [_]u8{ 255, 255, 255, 255 };
    const texture = try rhi.createTexture(.{ .width = 1, .height = 1, .rgba8 = &pixels });

    const begin = try rhi.beginFrame(.{ .width = 80, .height = 60 }, .{ 0, 0, 0, 1 });
    var encoder = switch (begin) {
        .ready => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectError(error.InvalidPipeline, encoder.bindPipeline(types.invalid_pipeline));
    try encoder.bindPipeline(pipeline);
    try std.testing.expectError(error.TextureBindingUnsupported, encoder.bindTexture(texture));
    try std.testing.expectError(error.PipelinePushConstantTooLarge, encoder.pushConstants(&([_]u8{0} ** 36)));
    try encoder.pushConstants(&([_]u8{0} ** 32));
    try encoder.draw(6);
    try std.testing.expectEqual(.presented, try encoder.finish());
    try std.testing.expectError(error.FrameAlreadyFinished, encoder.finish());

    rhi.destroyTexture(texture);
    rhi.destroyTexture(texture);
    rhi.destroyGraphicsPipeline(pipeline);
    rhi.destroyGraphicsPipeline(pipeline);

    const next = try rhi.beginFrame(.{ .width = 80, .height = 60 }, .{ 0, 0, 0, 1 });
    var next_encoder = switch (next) {
        .ready => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectError(error.InvalidPipeline, next_encoder.bindPipeline(pipeline));
    next_encoder.consumeFailedFrame();
}

test "null adapter rejects stale frame encoders" {
    var rhi = try Rhi.init(.{ .width = 32, .height = 32 });
    defer rhi.deinit();
    const shader = [_]u8{ 0, 0, 0, 0 };
    const pipeline = try rhi.createGraphicsPipeline(.{
        .vertex_shader = &shader,
        .fragment_shader = &shader,
        .push_constant_size = 4,
    });

    const first = try rhi.beginFrame(.{ .width = 32, .height = 32 }, .{ 0, 0, 0, 1 });
    var stale = switch (first) {
        .ready => |value| value,
        else => return error.TestUnexpectedResult,
    };
    var finishing_copy = stale;
    _ = try finishing_copy.finish();

    const second = try rhi.beginFrame(.{ .width = 32, .height = 32 }, .{ 0, 0, 0, 1 });
    var current = switch (second) {
        .ready => |value| value,
        else => return error.TestUnexpectedResult,
    };
    // 旧 encoder 的 token 不能操作新帧，避免跨帧命令污染。
    try std.testing.expectError(error.StaleFrameEncoder, stale.bindPipeline(pipeline));
    current.consumeFailedFrame();
}

test "null adapter validates texture mip chain" {
    var rhi = try Rhi.init(.{});
    defer rhi.deinit();

    try std.testing.expectError(error.InvalidTextureExtent, rhi.createTexture(.{ .width = 0, .height = 1, .rgba8 = &.{} }));
    try std.testing.expectError(error.InvalidTextureByteCount, rhi.createTexture(.{ .width = 1, .height = 1, .rgba8 = &[_]u8{0} }));

    const base = [_]u8{0} ** (4 * 4 * 4);
    const mip_2x2 = [_]u8{0} ** (2 * 2 * 4);
    const mip_1x1 = [_]u8{0} ** 4;
    const valid_mips = [_]types.TextureMipUpload{
        .{ .width = 2, .height = 2, .rgba8 = &mip_2x2 },
        .{ .width = 1, .height = 1, .rgba8 = &mip_1x1 },
    };
    const texture = try rhi.createTexture(.{
        .width = 4,
        .height = 4,
        .rgba8 = &base,
        .mip_levels = &valid_mips,
    });
    rhi.destroyTexture(texture);

    const invalid_mips = [_]types.TextureMipUpload{
        .{ .width = 3, .height = 2, .rgba8 = &mip_2x2 },
        .{ .width = 1, .height = 1, .rgba8 = &mip_1x1 },
    };
    try std.testing.expectError(error.InvalidTextureMipExtent, rhi.createTexture(.{
        .width = 4,
        .height = 4,
        .rgba8 = &base,
        .mip_levels = &invalid_mips,
    }));
}

test "null adapter reports texture ownership counts" {
    var rhi = try Rhi.init(.{});
    defer rhi.deinit();
    const pixels = [_]u8{ 255, 255, 255, 255 };

    const first = try rhi.createTexture(.{ .width = 1, .height = 1, .rgba8 = &pixels });
    const second = try rhi.createTexture(.{ .width = 1, .height = 1, .rgba8 = &pixels });
    var stats = rhi.stats();
    try std.testing.expectEqual(@as(u32, 2), stats.textures_created);
    try std.testing.expectEqual(@as(u32, 0), stats.textures_destroyed);
    try std.testing.expectEqual(@as(u32, 2), stats.textures_live);

    rhi.destroyTexture(first);
    rhi.destroyTexture(first);
    stats = rhi.stats();
    try std.testing.expectEqual(@as(u32, 2), stats.textures_created);
    try std.testing.expectEqual(@as(u32, 1), stats.textures_destroyed);
    try std.testing.expectEqual(@as(u32, 1), stats.textures_live);

    rhi.destroyTexture(second);
    stats = rhi.stats();
    try std.testing.expectEqual(@as(u32, 2), stats.textures_created);
    try std.testing.expectEqual(@as(u32, 2), stats.textures_destroyed);
    try std.testing.expectEqual(@as(u32, 0), stats.textures_live);
}

test "null adapter draw trace saturation does not fail rendering" {
    var rhi = try Rhi.init(.{ .width = 32, .height = 32 });
    defer rhi.deinit();
    const shader = [_]u8{ 0, 0, 0, 0 };
    const pipeline = try rhi.createGraphicsPipeline(.{
        .vertex_shader = &shader,
        .fragment_shader = &shader,
        .push_constant_size = 4,
        .uses_texture = true,
    });
    const pixels = [_]u8{ 255, 255, 255, 255 };
    const texture = try rhi.createTexture(.{ .width = 1, .height = 1, .rgba8 = &pixels });

    const begin = try rhi.beginFrame(.{ .width = 32, .height = 32 }, .{ 0, 0, 0, 1 });
    var encoder = switch (begin) {
        .ready => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try encoder.bindPipeline(pipeline);
    try encoder.bindTexture(texture);
    for (0..max_draw_texture_trace + 1) |_| try encoder.draw(6);
    try std.testing.expectEqual(.presented, try encoder.finish());

    const stats = rhi.stats();
    try std.testing.expectEqual(@as(u32, max_draw_texture_trace + 1), stats.draws);
    try std.testing.expectEqual(max_draw_texture_trace, stats.draw_texture_trace_len);
}

test "null adapter validates bounded instance data and instanced draws" {
    var rhi = try Rhi.init(.{ .width = 64, .height = 64 });
    defer rhi.deinit();
    const shader = [_]u8{ 0, 0, 0, 0 };
    const pipeline = try rhi.createGraphicsPipeline(.{
        .vertex_shader = &shader,
        .fragment_shader = &shader,
        .push_constant_size = 32,
        .instance_data_stride = 32,
    });

    const begin = try rhi.beginFrame(.{ .width = 64, .height = 64 }, .{ 0, 0, 0, 1 });
    var encoder = switch (begin) {
        .ready => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try encoder.bindPipeline(pipeline);
    try std.testing.expectError(error.InstanceDataRequired, encoder.drawInstanced(6, 1));
    try std.testing.expectError(error.InvalidInstanceDataSize, encoder.bindInstanceData(&([_]u8{0} ** 31)));

    const two_instances = [_]u8{0} ** 64;
    try encoder.bindInstanceData(&two_instances);
    try std.testing.expectError(error.InvalidDrawCount, encoder.drawInstanced(0, 2));
    try std.testing.expectError(error.InvalidInstanceCount, encoder.drawInstanced(6, 0));
    try std.testing.expectError(error.InstanceCountExceedsBoundData, encoder.drawInstanced(6, 3));
    try encoder.drawInstanced(6, 2);
    try std.testing.expectEqual(.presented, try encoder.finish());

    const stats = rhi.stats();
    try std.testing.expectEqual(@as(u32, 1), stats.instance_data_binds);
    try std.testing.expectEqual(@as(u32, 64), stats.instance_data_bytes);
    try std.testing.expectEqual(@as(u32, 1), stats.draws);
    try std.testing.expectEqual(@as(u32, 2), stats.instances_drawn);
}

test "null adapter separates ordinary and instanced pipeline contracts" {
    var rhi = try Rhi.init(.{ .width = 32, .height = 32 });
    defer rhi.deinit();
    const shader = [_]u8{ 0, 0, 0, 0 };
    try std.testing.expectError(error.InvalidInstanceDataStride, rhi.createGraphicsPipeline(.{
        .vertex_shader = &shader,
        .fragment_shader = &shader,
        .push_constant_size = 4,
        .instance_data_stride = 2,
    }));
    const ordinary = try rhi.createGraphicsPipeline(.{
        .vertex_shader = &shader,
        .fragment_shader = &shader,
        .push_constant_size = 4,
    });

    const begin = try rhi.beginFrame(.{ .width = 32, .height = 32 }, .{ 0, 0, 0, 1 });
    var encoder = switch (begin) {
        .ready => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try encoder.bindPipeline(ordinary);
    try std.testing.expectError(error.InstanceDataBindingUnsupported, encoder.bindInstanceData(&([_]u8{0} ** 4)));
    try std.testing.expectError(error.InstanceDataBindingUnsupported, encoder.drawInstanced(6, 1));
    encoder.consumeFailedFrame();
}

test "null adapter enforces per-frame instance binding count budget" {
    var rhi = try Rhi.init(.{ .width = 32, .height = 32 });
    defer rhi.deinit();
    const shader = [_]u8{ 0, 0, 0, 0 };
    const pipeline = try rhi.createGraphicsPipeline(.{
        .vertex_shader = &shader,
        .fragment_shader = &shader,
        .push_constant_size = 4,
        .instance_data_stride = 4,
    });

    const begin = try rhi.beginFrame(.{ .width = 32, .height = 32 }, .{ 0, 0, 0, 1 });
    var binding_limited = switch (begin) {
        .ready => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try binding_limited.bindPipeline(pipeline);
    for (0..types.max_instance_data_bindings_per_frame) |_| {
        try binding_limited.bindInstanceData(&([_]u8{0} ** 4));
    }
    try std.testing.expectError(error.InstanceDataBindingLimitReached, binding_limited.bindInstanceData(&([_]u8{0} ** 4)));
    binding_limited.consumeFailedFrame();
}

test "null adapter separates per-binding and per-frame instance budgets" {
    var rhi = try Rhi.init(.{ .width = 32, .height = 32 });
    defer rhi.deinit();
    const shader = [_]u8{ 0, 0, 0, 0 };
    const pipeline = try rhi.createGraphicsPipeline(.{
        .vertex_shader = &shader,
        .fragment_shader = &shader,
        .push_constant_size = 48,
        .instance_data_stride = 48,
    });

    const begin = try rhi.beginFrame(.{ .width = 32, .height = 32 }, .{ 0, 0, 0, 1 });
    var encoder = switch (begin) {
        .ready => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try encoder.bindPipeline(pipeline);
    try std.testing.expectError(
        error.InstanceDataBindingSizeLimitReached,
        encoder.bindInstanceData(&([_]u8{0} ** (types.max_instance_data_bytes_per_binding + 48))),
    );
    for (0..10) |_| {
        try encoder.bindInstanceData(&([_]u8{0} ** types.max_instance_data_bytes_per_binding));
    }
    try encoder.bindInstanceData(&([_]u8{0} ** 4080));
    try std.testing.expectError(error.InstanceDataFrameLimitReached, encoder.bindInstanceData(&([_]u8{0} ** 48)));
    encoder.consumeFailedFrame();
}
