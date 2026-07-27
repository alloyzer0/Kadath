#version 450

layout(push_constant) uniform PushConstants {
    vec4 rect_ndc;
    vec4 color;
} pc;

layout(location = 0) out vec2 out_uv;

const vec2 positions[6] = vec2[](
    vec2(0.0, 0.0),
    vec2(1.0, 0.0),
    vec2(1.0, 1.0),
    vec2(0.0, 0.0),
    vec2(1.0, 1.0),
    vec2(0.0, 1.0)
);

void main() {
    vec2 local = positions[gl_VertexIndex];
    vec2 ndc = vec2(
        pc.rect_ndc.x + local.x * pc.rect_ndc.z,
        pc.rect_ndc.y - local.y * pc.rect_ndc.w
    );
    // Vulkan 使用正高度 viewport：只翻转 clip-space Y，保持 PNG UV 自上而下。
    gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);
    out_uv = local;
}
