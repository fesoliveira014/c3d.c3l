#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "fog.glsl"

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

void main() {
    FrameRoot frame = FrameRoot(SkyRoot(pc.fragment_root_gpu).frame);
    SkyFogGpu sky = SkyFogGpu(frame.sky_fog);
    vec3 origin;
    vec3 direction;
    fog_pixel_ray(frame, v_uv, origin, direction);
    vec3 illuminance = sky.sun_illuminance.rgb;
    vec3 disc = min(sky_sun_disc(sky, direction) * illuminance, vec3(SKY_SUN_DISC_LIMIT));
    out_color = vec4(sky_view_radiance(sky, direction, false) * illuminance + disc, 1.0);
}
