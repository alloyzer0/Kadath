pub const types = @import("types.zig");
pub const Extent2D = types.Extent2D;
pub const FrameOutcome = types.FrameOutcome;
pub const PipelineHandle = types.PipelineHandle;
pub const invalid_pipeline = types.invalid_pipeline;
pub const GraphicsPipelineDesc = types.GraphicsPipelineDesc;

const backend = @import("vulkan/backend.zig");
pub const Rhi = backend.Rhi;
pub const FrameEncoder = backend.FrameEncoder;
pub const BeginFrameResult = backend.BeginFrameResult;
