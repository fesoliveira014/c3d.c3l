#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "impostor_surface.glsl"
#include "standard_shading.glsl"

layout(location = 0) out vec4 out_color;

void main() {
    DrawRoot draw = DrawRoot(pc.fragment_root_gpu);
    FrameRoot frame = FrameRoot(draw.frame);
    vec3 world;
    vec3 local;
    uvec3 frames;
    StandardMaterialSample surface = impostor_surface(world, local, frames);
    out_color = vec4(shade_standard_surface(frame, draw, surface, 1.0, world, ivec2(gl_FragCoord.xy)), 1.0);
}
