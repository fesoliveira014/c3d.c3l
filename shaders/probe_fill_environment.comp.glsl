#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "gbuffer.glsl"
#include "ibl.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

void main() {
    ProbeFillRoot root = ProbeFillRoot(pc.root_gpu);
    uvec2 texel = gl_GlobalInvocationID.xy;
    if (texel.x >= root.width || texel.y >= root.height) return;

    uvec2 local = texel % root.cell_edge;
    uint last = root.cell_edge - 1u;
    if (local.x == 0u || local.y == 0u || local.x == last || local.y == last) return;

    if (root.kind == PROBE_ATLAS_VISIBILITY) {
        vec2 moments = vec2(root.max_distance, root.max_distance * root.max_distance);
        store_storage_texture(root.atlas, ivec2(texel), vec4(moments, 0.0, 0.0));
        return;
    }
    vec2 encoded = (vec2(local - 1u) + 0.5) / float(root.cell_edge - 2u) * 2.0 - 1.0;
    vec3 direction = decode_octahedral(encoded);
    EnvironmentGpu environment = EnvironmentGpu(root.environment);
    vec3 irradiance = environment_irradiance(environment.sh, environment_rotate(environment.rotation, direction))
        * environment.intensity;
    store_storage_texture(root.atlas, ivec2(texel), vec4(irradiance, 1.0));
}
