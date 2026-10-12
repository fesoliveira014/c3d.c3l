#ifndef C3D_BLEND_OUTPUT_GLSL
#define C3D_BLEND_OUTPUT_GLSL

#include "material_alpha.glsl"
#include "pre_exposure.glsl"
#ifdef WEIGHTED_BLEND
#include "weighted_blend.glsl"
#endif

layout(location = 0) out vec4 out_color;
#ifdef WEIGHTED_BLEND
layout(location = 1) out float out_revealage;
#endif

void write_blend_output(FrameRoot frame, vec4 premultiplied, vec3 world_position) {
#ifdef WEIGHTED_BLEND
    out_color = weighted_blend_color(frame, premultiplied, world_position);
    out_revealage = premultiplied.a;
#else
    out_color = premultiplied;
#endif
}

#endif
