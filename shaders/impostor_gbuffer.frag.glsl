#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "impostor_surface.glsl"
#include "gbuffer_output.glsl"

void main() {
    vec3 world;
    vec3 local;
    uvec3 frames;
    StandardMaterialSample surface = impostor_surface(world, local, frames);
    write_gbuffer(surface, 1.0, DrawRoot(pc.fragment_root_gpu));
}
