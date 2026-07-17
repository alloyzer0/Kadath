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

pub const GraphicsPipelineDesc = struct {
    // Shader storage must outlive the pipeline because swapchain recreation
    // rebuilds backend pipeline objects from these byte slices.
    vertex_shader: []const u8,
    fragment_shader: []const u8,
    push_constant_size: u32,
};
