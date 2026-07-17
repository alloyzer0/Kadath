#version 450

layout(push_constant) uniform PushConstants {
    vec4 rect_ndc;
    vec4 color;
} pc;

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_color;

void main() {
    float checker = mod(floor(in_uv.x * 10.0) + floor(in_uv.y * 8.0), 2.0);
    vec3 dark = pc.color.rgb * 0.28;
    vec3 bright = min(pc.color.rgb * 1.15, vec3(1.0));
    out_color = vec4(mix(dark, bright, checker), pc.color.a);
}
