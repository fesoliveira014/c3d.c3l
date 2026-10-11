#ifndef C3D_BLEND_OUTPUT_GLSL
#define C3D_BLEND_OUTPUT_GLSL

#include "material_alpha.glsl"
#include "weighted_blend.glsl"

layout(location = 0) out vec4 out_color;
layout(location = 1) out float out_revealage;

void write_blend_output(FrameRoot frame, DrawRoot draw, vec4 premultiplied, vec3 world_position) {
    out_color = (draw.flags & DRAW_WEIGHTED_BLEND) != 0u
        ? weighted_blend_color(frame, premultiplied, world_position) : premultiplied;
    out_revealage = premultiplied.a;
}

#endif
