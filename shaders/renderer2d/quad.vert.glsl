#version 450

struct SpriteInstance {
    vec4 rect_world;
    vec4 color;
    vec4 uv_rect;
    vec4 transform;
};

layout(std430, set = 1, binding = 0) readonly buffer SpriteInstances {
    SpriteInstance values[];
} sprite_instances;

layout(location = 0) out vec2 out_uv;
layout(location = 1) out vec4 out_color;

layout(push_constant) uniform View2D {
    vec4 viewport; // width, height, inverse width, inverse height
    vec4 camera;   // origin x/y, zoom, reserved
} view;

const vec2 positions[6] = vec2[](
    vec2(0.0, 0.0),
    vec2(1.0, 0.0),
    vec2(1.0, 1.0),
    vec2(0.0, 0.0),
    vec2(1.0, 1.0),
    vec2(0.0, 1.0)
);

void main() {
    SpriteInstance instance = sprite_instances.values[gl_InstanceIndex];
    vec2 local = positions[gl_VertexIndex];
    uint flags = uint(instance.transform.x);
    vec2 local_uv = local;
    // Tiled 正交语义：先 diagonal，再 horizontal / vertical。
    if ((flags & 4u) != 0u) local_uv = local_uv.yx;
    if ((flags & 1u) != 0u) local_uv.x = 1.0 - local_uv.x;
    if ((flags & 2u) != 0u) local_uv.y = 1.0 - local_uv.y;
    vec2 screen_position = (instance.rect_world.xy - view.camera.xy) * view.camera.z;
    vec2 screen_size = instance.rect_world.zw * view.camera.z;
    vec2 ndc = vec2(
        screen_position.x * view.viewport.z * 2.0 - 1.0 + local.x * screen_size.x * view.viewport.z * 2.0,
        screen_position.y * view.viewport.w * 2.0 - 1.0 + local.y * screen_size.y * view.viewport.w * 2.0
    );
    // Vulkan 使用正高度 viewport：只翻转 clip-space Y，保持 PNG UV 自上而下。
    gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);
    out_uv = instance.uv_rect.xy + local_uv * instance.uv_rect.zw;
    out_color = instance.color;
}
