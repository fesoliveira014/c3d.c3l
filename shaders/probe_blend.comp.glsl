#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "buffer_reference.glsl"
#include "constants.glsl"
#include "sampling.glsl"
#include "gbuffer.glsl"
#include "probe_atlas.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

GPU_DECLARE_READONLY_ARRAY_REF(RayResultReadonly, RayResultGpu);

const float PROBE_DISTANCE_SHARPNESS = 50.0; // cosine power of the visibility filter; narrow keeps edges of occluders
const float PROBE_MIN_WEIGHT_SUM = 1e-4;     // a texel no ray reached keeps a finite estimate

void main() {
    ProbeBlendRoot root = ProbeBlendRoot(pc.root_gpu);
    FrameRoot frame = FrameRoot(root.frame);
    ProbeVolumeGpu volume = ProbeVolumeSetGpu(frame.probe_volumes).volumes[root.volume];
    bool irradiance = root.kind == PROBE_ATLAS_IRRADIANCE;
    uint cell_edge = irradiance ? PROBE_IRRADIANCE_CELL : PROBE_VISIBILITY_CELL;
    uint interior = cell_edge - 2u;
    uvec2 thread = gl_GlobalInvocationID.xy;
    if (thread.x >= root.probe_count * interior || thread.y >= interior) return;

    uint probe = root.first_probe + thread.x / interior;
    uvec2 local = uvec2(thread.x % interior, thread.y);
    uvec3 counts = uvec3(volume.count_x, volume.count_y, volume.count_z);
    uvec3 cell = uvec3(probe % counts.x, (probe / counts.x) % counts.y, probe / (counts.x * counts.y));
    uvec2 atlas_cell = probe_cell(counts, volume.slices_per_row, cell);
    ivec2 texel = ivec2(atlas_cell * cell_edge + 1u + local);
    vec3 texel_direction = decode_octahedral((vec2(local) + 0.5) / float(interior) * 2.0 - 1.0);

    float max_distance = volume.spacing_max_distance.w;
    vec3 sum = vec3(0.0);
    float weight_sum = 0.0;
    uint first_ray = (probe - root.first_probe) * root.rays_per_probe;
    for (uint ray = 0u; ray < root.rays_per_probe; ray++) {
        vec4 result = RayResultReadonly(root.rays).values[first_ray + ray].radiance_distance;
        vec3 direction = quaternion_rotate(root.rotation, spherical_fibonacci(ray, root.rays_per_probe));
        float cosine = max(dot(texel_direction, direction), 0.0);
        if (irradiance) {
            // Back-face rays carry zero radiance and keep their weight, so a probe inside geometry goes dark.
            sum += cosine * result.rgb;
            weight_sum += cosine;
        } else {
            float weight = pow(cosine, PROBE_DISTANCE_SHARPNESS);
            float distance = result.w < 0.0 ? 0.0 : min(result.w, max_distance);
            sum += weight * vec3(distance, distance * distance, 0.0);
            weight_sum += weight;
        }
    }
    // The cosine-weighted mean radiance times PI is the irradiance E the texels store.
    vec3 estimate = sum / max(weight_sum, PROBE_MIN_WEIGHT_SUM) * (irradiance ? PI : 1.0);
    uint atlas = irradiance ? volume.irradiance : volume.visibility;
    vec4 previous = load_storage_texture(atlas, texel);
    vec3 blended = mix(estimate, previous.rgb, root.hysteresis);
    store_storage_texture(atlas, texel, vec4(blended, 1.0));
}
