#version 450

struct SpriteInstance {
    vec4 rect_ndc;
    vec4 color;
    vec4 uv_rect;
};

layout(std430, set = 1, binding = 0) readonly buffer SpriteInstances {
    SpriteInstance values[];
} sprite_instances;

layout(location = 0) out vec2 out_uv;
layout(location = 1) out vec4 out_color;

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
    vec2 ndc = vec2(
        instance.rect_ndc.x + local.x * instance.rect_ndc.z,
        instance.rect_ndc.y - local.y * instance.rect_ndc.w
    );
    // Vulkan 使用正高度 viewport：只翻转 clip-space Y，保持 PNG UV 自上而下。
    gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);
    out_uv = instance.uv_rect.xy + local * instance.uv_rect.zw;
    out_color = instance.color;
}
