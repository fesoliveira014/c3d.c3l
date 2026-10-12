#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "cloud_density.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

// One texel of the bottom plane: the transmittance along the sun from the plane through the layer, which is taken as
// flat over the map. The march leans along the sun by the same floored cosine the receivers project with.
void main() {
    CloudShadowRoot shadow = CloudShadowRoot(pc.root_gpu);
    ivec2 texel = ivec2(gl_GlobalInvocationID.xy);
    if (texel.x >= int(CLOUD_SHADOW_SIZE) || texel.y >= int(CLOUD_SHADOW_SIZE)) return;

    CloudsRoot layer = CloudsRoot(shadow.clouds);
    float texel_size = CLOUD_SHADOW_EXTENT / float(CLOUD_SHADOW_SIZE);
    vec2 plane = shadow.map.xy + (vec2(texel) + 0.5) * texel_size + FrameRoot(layer.frame).origin.xz;
    vec3 to_sun = shadow.to_sun.xyz;
    float sun_up = max(to_sun.y, CLOUD_SUN_FLOOR);
    float thickness = shadow.top - shadow.bottom;
    float step_length = thickness / sun_up / float(CLOUD_SHADOW_STEPS);

    float optical_depth = 0.0;
    for (uint step = 0u; step < CLOUD_SHADOW_STEPS; step++) {
        float height = (float(step) + 0.5) / float(CLOUD_SHADOW_STEPS) * thickness;
        vec2 horizontal = plane + to_sun.xz * (height / sun_up);
        optical_depth += cloud_density(layer, horizontal, shadow.bottom + height, true) * step_length;
    }
    store_storage_texture(shadow.texture, texel, vec4(exp(-optical_depth)));
}
