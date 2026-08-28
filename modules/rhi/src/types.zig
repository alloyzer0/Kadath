pub const Extent2D = struct {
    width: u32 = 0,
    height: u32 = 0,
};

pub const FrameOutcome = enum {
    presented,
    skipped_minimized,
    recreated,
};

pub const PipelineHandle = u32;
pub const invalid_pipeline: PipelineHandle = 0;

pub const TextureHandle = u32;
pub const invalid_texture: TextureHandle = 0;

/// 每次绑定最多携带 128 个 48-byte Quad instance；整帧容量同时覆盖 1024 Tile 与 128 Sprite。
// 64-byte world-space quad × 128 instances；Tilemap 仍以有界批次提交。
pub const max_instance_data_bytes_per_binding: usize = 8192;
// 可见实例预算与全地图规模解耦；16384 个 quad 是当前产品门禁。
pub const max_instance_data_bytes_per_frame: usize = 1024 * 1024;
pub const max_instance_data_bindings_per_frame: usize = 256;

pub const TextureSamplerProfile = enum {
    pixel_nearest,
    smooth_linear,
    smooth_mipmap,
    smooth_mipmap_anisotropic,
};

pub const TextureMipUpload = struct {
    width: u32,
    height: u32,
    rgba8: []const u8,
};

pub const TextureUploadDesc = struct {
    width: u32,
    height: u32,
    rgba8: []const u8,
    // mip_levels 只包含 base 之后的附加 levels，顺序必须连续减半到 1x1。
    mip_levels: []const TextureMipUpload = &.{},
    sampler_profile: TextureSamplerProfile = .smooth_mipmap,
};

pub const GraphicsPipelineDesc = struct {
    // Shader storage must outlive the pipeline because swapchain recreation
    // rebuilds backend pipeline objects from these byte slices.
    vertex_shader: []const u8,
    fragment_shader: []const u8,
    push_constant_size: u32,
    uses_texture: bool = false,
    // 0 表示普通 pipeline；非零值由 RHI 用于校验 opaque instance bytes。
    instance_data_stride: u32 = 0,
};
