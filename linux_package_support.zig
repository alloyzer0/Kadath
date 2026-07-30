pub const scene = @import("app/scene.zig");
pub const script = @import("app/script.zig");
pub const primary_png = @embedFile("assets/renderer2d/test.png");
pub const secondary_png = @embedFile("assets/renderer2d/goal.png");
pub const won_wav = @embedFile("assets/audio/won.wav");
pub const lost_wav = @embedFile("assets/audio/lost.wav");
pub const scene_json = @embedFile("assets/scenes/preview.scene.json");
pub const script_json = @embedFile("assets/scripts/preview.script.json");
