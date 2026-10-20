#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "impostor_surface.glsl"
#ifdef PROXY_SKIP
#include "proxy_skip_output.glsl"
#endif

void main() {
#ifdef PROXY_SKIP
    write_proxy_skip();
#endif
    vec3 world;
    vec3 local;
    uvec3 frames;
    impostor_surface(world, local, frames);
}
