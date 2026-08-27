const std = @import("std");
const rhi = @import("rhi");
const renderer2d = @import("renderer2d");

test "Renderer2D compiles and renders through the Null RHI module remap" {
    var backend = try rhi.Rhi.init(.{ .width = 64, .height = 64 });
    defer backend.deinit();

    const shader = [_]u8{ 0, 0, 0, 0 };
    const pipeline = try backend.createGraphicsPipeline(.{
        .vertex_shader = &shader,
        .fragment_shader = &shader,
        .push_constant_size = 32,
        .uses_texture = true,
        .instance_data_stride = 32,
    });
    const pixels = [_]u8{ 255, 255, 255, 255 };
    const texture = try backend.createTexture(.{ .width = 1, .height = 1, .rgba8 = &pixels });
    defer backend.destroyTexture(texture);

    // 直接注入已创建 pipeline，避免 Null 测试依赖真实 SPIR-V 外部符号。
    var renderer = renderer2d.Renderer2D{ .pipeline = pipeline };
    const outcome = try renderer.renderSprites(
        &backend,
        .{ .width = 64, .height = 64 },
        &[_]renderer2d.SpriteInstance{.{
            .position = .{ 4, 4 },
            .size = .{ 8, 8 },
            .color = .{ 1, 1, 1, 1 },
            .texture = texture,
        }},
    );
    try std.testing.expectEqual(.presented, outcome);
    const stats = backend.stats();
    try std.testing.expectEqual(@as(u32, 1), stats.pipeline_binds);
    try std.testing.expectEqual(@as(u32, 1), stats.texture_binds);
    try std.testing.expectEqual(@as(u32, 1), stats.instance_data_binds);
    try std.testing.expectEqual(@as(u32, 0), stats.push_constant_writes);
    try std.testing.expectEqual(@as(u32, 1), stats.draws);
    try std.testing.expectEqual(@as(u32, 1), stats.instances_drawn);
}
