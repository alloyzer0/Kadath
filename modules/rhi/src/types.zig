pub const Extent2D = struct {
    width: u32 = 0,
    height: u32 = 0,
};

pub const FrameOutcome = enum {
    presented,
    skipped_minimized,
    recreated,
};
