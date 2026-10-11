#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#define RT_SHADOWS
#include "hit_shading.glsl"

const uint PHYSICAL_HIT_ROWS = 16u; // Mirrored by test_trace_physical_material.c3's result count.
const float PHYSICAL_HIT_RAY_LIMIT = 20.0;

layout(local_size_x = 1) in;
layout(push_constant) uniform Push { uint64_t root_gpu; } pc;
layout(buffer_reference, std430, buffer_reference_align = 8) readonly buffer PhysicalHitRoot {
    uint64_t scene;
    uint64_t frame;
    uint64_t output_address;
    uint64_t padding;
    vec4 origin_cone;
    vec4 direction;
};
GPU_DECLARE_WRITEONLY_ARRAY_REF(PhysicalHitOutput, vec4);

void main() {
    DispatchRoot dispatch = DispatchRoot(pc.root_gpu);
    PhysicalHitRoot root = PhysicalHitRoot(dispatch.parameters);
    for (uint row = 0u; row < PHYSICAL_HIT_ROWS; row++) {
        PhysicalHitOutput(root.output_address).values[row] = vec4(-1.0);
    }

    SceneHit scene_hit;
    if (!trace_scene(
        SceneTraceRoot(root.scene),
        root.origin_cone.xyz,
        root.direction.xyz,
        PHYSICAL_HIT_RAY_LIMIT,
        TRACE_MASK_ALL,
        scene_hit
    )) {
        return;
    }

    FrameRoot frame = FrameRoot(root.frame);
    TraceSurface hit = surface_from_hit(SceneTraceRoot(root.scene), scene_hit, root.direction.xyz, root.origin_cone.w);
    PhysicalHitOutput output_rows = PhysicalHitOutput(root.output_address);
    output_rows.values[0] = vec4(shade_hit(frame, hit, -root.direction.xyz), float(hit.material_kind));
    output_rows.values[1] = vec4(hit.albedo, hit.metallic);
    output_rows.values[2] = vec4(hit.normal, hit.roughness);
    output_rows.values[13] = vec4(hit.emissive, 0.0);
    if (hit.material_kind != MATERIAL_KIND_PHYSICAL) return;

    PhysicalSurface surface = prepare_physical_hit_surface(
        hit,
        -root.direction.xyz,
        frame.sheen_lut,
        frame.sheen_sampler
    );
    ReflectionSelection reflections = reflection_probe_select(frame, hit.position);
    output_rows.values[3] = vec4(surface.coat_normal, surface.coat_roughness);
    output_rows.values[4] = vec4(surface.sheen_color, surface.sheen_roughness);
    output_rows.values[5] = vec4(surface.standard.reflectance, surface.coat_weight);
    output_rows.values[6] = vec4(surface.standard.grazing_reflectance, surface.sheen_strength);
    output_rows.values[7] = vec4(surface.transmission_ray, surface.transmission);
    output_rows.values[8] = vec4(surface.transmission_color, hit.occlusion);
    output_rows.values[9] = vec4(surface.standard.anisotropic_tangent, surface.standard.anisotropy);
    output_rows.values[10] = vec4(surface.standard.anisotropic_bitangent, surface.standard.alpha_tangent);
    output_rows.values[11] = vec4(hit.context.uv0, hit.context.uv1);
    vec3 transmitted = physical_hit_transmitted_radiance(frame, reflections, hit, surface);
    output_rows.values[12] = vec4(transmitted, length(surface.transmission_ray));
    output_rows.values[13].w = surface.sheen_view_albedo;
    output_rows.values[14] = frame.light_count == 0u ? vec4(0.0) : vec4(evaluate_physical_light(
        LightArray(frame.lights).values[0],
        hit.position,
        surface,
        frame.sheen_lut,
        frame.sheen_sampler
    ), 1.0);
    output_rows.values[15] = !frame_has_indirect(frame) ? vec4(0.0) : vec4(evaluate_physical_environment(
        frame,
        reflections,
        hit.position,
        surface,
        hit.roughness,
        hit.occlusion,
        1.0
    ), 1.0);
}
