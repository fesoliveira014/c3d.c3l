#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#define RT_SHADOWS
#include "hit_shading.glsl"

const uint PHYSICAL_CC0_ROWS = 16u; // Matches read_physical_hit's diagnostic result allocation.
const float PHYSICAL_CC0_RAY_LIMIT = 20.0;

layout(local_size_x = 1) in;
layout(push_constant) uniform Push { uint64_t root_gpu; } pc;
layout(buffer_reference, std430, buffer_reference_align = 8) readonly buffer PhysicalCc0Root {
    uint64_t scene;
    uint64_t frame;
    uint64_t output_address;
    uint64_t padding;
    vec4 origin_cone;
    vec4 direction;
};
GPU_DECLARE_WRITEONLY_ARRAY_REF(PhysicalCc0Output, vec4);

void main() {
    DispatchRoot dispatch = DispatchRoot(pc.root_gpu);
    PhysicalCc0Root root = PhysicalCc0Root(dispatch.parameters);
    PhysicalCc0Output output_rows = PhysicalCc0Output(root.output_address);
    for (uint row = 0u; row < PHYSICAL_CC0_ROWS; row++) output_rows.values[row] = vec4(-1.0);

    SceneHit scene_hit;
    if (!trace_scene(
        SceneTraceRoot(root.scene),
        root.origin_cone.xyz,
        root.direction.xyz,
        PHYSICAL_CC0_RAY_LIMIT,
        TRACE_MASK_ALL,
        scene_hit
    )) return;

    FrameRoot frame = FrameRoot(root.frame);
    TraceSurface hit = surface_from_hit(SceneTraceRoot(root.scene), scene_hit, root.direction.xyz, root.origin_cone.w);
    output_rows.values[0] = vec4(shade_hit(frame, hit, -root.direction.xyz), float(hit.material_kind));
    output_rows.values[1] = vec4(shade_standard_hit(frame, hit, -root.direction.xyz), float(scene_hit.primitive));
    output_rows.values[2] = vec4(hit.normal, hit.roughness);
    output_rows.values[4] = vec4(hit.position, scene_hit.t);
    if (hit.material_kind != MATERIAL_KIND_PHYSICAL) return;

    PhysicalSurface surface = prepare_physical_hit_surface(
        hit,
        -root.direction.xyz,
        frame.sheen_lut,
        frame.sheen_sampler
    );
    output_rows.values[3] = vec4(
        surface.coat_weight,
        surface.sheen_strength,
        surface.standard.anisotropy,
        surface.transmission
    );
}
