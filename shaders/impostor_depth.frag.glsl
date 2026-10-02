#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "impostor_surface.glsl"

void main() {
    vec3 world;
    vec3 local;
    uvec3 frames;
    impostor_surface(world, local, frames);
}
