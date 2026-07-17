#version 450

layout(push_constant) uniform PushConstants {
    vec4 rect_ndc;
    vec4 color;
} pc;

layout(set = 0, binding = 0) uniform sampler2D sprite_texture;
layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_color;

void main() {
    out_color = texture(sprite_texture, in_uv) * pc.color;
}
