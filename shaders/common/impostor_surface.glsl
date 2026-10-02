#ifndef C3D_IMPOSTOR_SURFACE_GLSL
#define C3D_IMPOSTOR_SURFACE_GLSL

#include "descriptor_heap.glsl"
#include "impostor.glsl"
#include "standard_surface.glsl"

layout(location = 0) flat in uint v_source;
layout(push_constant) uniform Push { uint64_t vertex_root_gpu; uint64_t fragment_root_gpu; } pc;

// The march brackets discontinuous cutout edges before refining continuous surface depth.
const uint IMPOSTOR_MARCH_STEPS = 32u;
const uint IMPOSTOR_REFINE_STEPS = 8u;

struct ImpostorSample {
    vec4 color;
    vec3 normal;
    float roughness;
    float distance;
    vec3 local;
    bool hit;
};

ImpostorSample impostor_sample(ImpostorGpu impostor, uint index, mat3 basis, vec3 local) {
    ImpostorSample result;
    vec3 point = transpose(basis) * (local - impostor.bounds.xyz) / impostor.bounds.w;
    vec2 cell_uv = point.xy * vec2(0.5, -0.5) + 0.5;
    result.hit = all(greaterThanEqual(cell_uv, vec2(0.0))) && all(lessThanEqual(cell_uv, vec2(1.0)));
    vec2 cell = vec2(index % impostor.frames_per_side, index / impostor.frames_per_side);
    float gutter = float(IMPOSTOR_GUTTER);
    float usable = float(impostor.cell_size - 2u * IMPOSTOR_GUTTER);
    vec2 pixel = cell * float(impostor.cell_size) + clamp(vec2(gutter) + cell_uv * usable, vec2(gutter + 0.5), vec2(gutter + usable - 0.5));
    vec2 uv = pixel / vec2(impostor.frames_per_side * impostor.cell_size, 2u * impostor.frames_per_side * impostor.cell_size);
    result.color = sample_texture_2d(impostor.atlas, impostor.sampler_index, uv);
    vec4 surface = sample_texture_2d(impostor.atlas, impostor.sampler_index, uv + vec2(0.0, 0.5));
    result.hit = result.hit && result.color.a >= 0.5;
    // Empty texels store zeros, so linear filtering weights every attribute by coverage.
    surface /= max(result.color.a, 1e-6);
    result.color.rgb /= max(result.color.a, 1e-6);
    result.normal = decode_octahedral(surface.xy * 2.0 - 1.0);
    result.roughness = surface.z;
    result.distance = (point.z - (1.0 - 2.0 * surface.w)) * impostor.bounds.w;
    result.local = local;
    return result;
}

ImpostorSample impostor_trace(
    DrawRoot draw, ImpostorGpu impostor, InstanceGpu instance, mat4 inverse_model,
    uint index, vec3 origin, vec3 direction, float first, float last
) {
    mat3 basis = impostor_basis(impostor_direction(index, impostor.frames_per_side));
    float step_size = (last - first) / float(IMPOSTOR_MARCH_STEPS);
    float before = first;
    ImpostorSample result;
    result.hit = false;
    for (uint step_index = 0u; step_index <= IMPOSTOR_MARCH_STEPS; step_index++) {
        float distance = first + step_size * float(step_index);
        vec3 local = impostor_local(draw, instance, inverse_model, origin + direction * distance);
        ImpostorSample sample_value = impostor_sample(impostor, index, basis, local);
        if (sample_value.hit && sample_value.distance <= 0.0) {
            float after = distance;
            for (uint refinement = 0u; refinement < IMPOSTOR_REFINE_STEPS; refinement++) {
                float middle = (before + after) * 0.5;
                vec3 refined = impostor_local(draw, instance, inverse_model, origin + direction * middle);
                ImpostorSample probe = impostor_sample(impostor, index, basis, refined);
                if (probe.hit && probe.distance <= 0.0) after = middle;
                else before = middle;
            }
            vec3 refined = impostor_local(draw, instance, inverse_model, origin + direction * after);
            result = impostor_sample(impostor, index, basis, refined);
            // A cutout edge is not a surface if the ray entered behind its depth sheet.
            result.hit = result.hit && abs(result.distance) < impostor.bounds.w * 0.04;
            if (result.hit) { result.distance = after; return result; }
        }
        before = distance;
    }
    result.hit = false;
    return result;
}

StandardMaterialSample impostor_surface(out vec3 world, out vec3 local, out uvec3 frames) {
    DrawRoot draw = DrawRoot(pc.fragment_root_gpu);
    FrameRoot frame = FrameRoot(draw.frame);
    ImpostorGpu impostor = ImpostorGpu(LodPartGpu(draw.lod_part).impostor);
    InstanceGpu instance = impostor_instance(draw, v_source);
    mat4 inverse_model = inverse(instance.model);
    vec3 center = (instance.model * vec4(impostor.bounds.xyz, 1.0)).xyz;
    vec3 weights;
    impostor_frames(impostor_view_direction(frame, inverse_model, center), impostor.frames_per_side, frames, weights);
    vec2 uv = gl_FragCoord.xy / frame.camera_params.zw;
    vec3 origin = reconstruct_world_position(frame, uv, 1.0);
    vec3 direction = normalize(reconstruct_world_position(frame, uv, 0.5) - origin);
    float radius = impostor.bounds.w * sqrt(dot(instance.model[0].xyz, instance.model[0].xyz)
        + dot(instance.model[1].xyz, instance.model[1].xyz) + dot(instance.model[2].xyz, instance.model[2].xyz));
    if ((draw.flags & DRAW_SWAY) != 0u) radius += InstanceEffectsGpu(draw.instance_effects).sway.direction_amplitude.w;
    if ((draw.flags & DRAW_DISTANCE_FADE) != 0u) {
        InstanceEffectsGpu effects = InstanceEffectsGpu(draw.instance_effects);
        vec3 anchor = instance_anchor(effects, instance.model);
        float scale = instance_fade_scale(effects, anchor, instance.normal_0.w);
        if (scale == 0.0) discard;
        center = mix(anchor, center, scale);
        radius *= scale;
    }
    vec3 offset = origin - center;
    float projected = dot(offset, direction);
    vec3 closest = offset - projected * direction;
    float discriminant = radius * radius - dot(closest, closest);
    if (discriminant <= 0.0) discard;
    float root = sqrt(discriminant);
    float first = max(-projected - root, 0.0);
    float last = -projected + root;
    float coverage = 0.0;
    float distance = 0.0;
    vec3 color = vec3(0.0);
    vec3 normal = vec3(0.0);
    float roughness = 0.0;
    for (uint index = 0u; index < 3u; index++) {
        if (weights[index] == 0.0) continue;
        ImpostorSample sample_value = impostor_trace(draw, impostor, instance, inverse_model, frames[index], origin, direction, first, last);
        if (!sample_value.hit) continue;
        float weight = weights[index] * sample_value.color.a;
        coverage += weight;
        distance += sample_value.distance * weight;
        color += sample_value.color.rgb * weight;
        normal += sample_value.normal * weight;
        roughness += sample_value.roughness * weight;
    }
    if (coverage < 0.5) discard;
    world = origin + direction * (distance / coverage);
    local = impostor_local(draw, instance, inverse_model, world);
    if ((frame.flags & FRAME_CLIP_PLANE) != 0u && dot(frame.clip_plane.xyz, world) + frame.clip_plane.w < 0.0) discard;
    precise vec4 clip = frame.view_proj * vec4(world, 1.0);
    gl_FragDepth = clip.z / clip.w;
    StandardMaterialSample surface;
    surface.base_color = vec4(color / coverage, 1.0) * instance.color;
    surface.normal = normalize(transpose(mat3(inverse_model)) * normal);
    surface.offset_normal = surface.normal;
    surface.roughness = roughness / coverage;
    surface.metallic = 0.0;
    surface.occlusion = 1.0;
    surface.emissive = vec3(0.0);
    surface.view_direction = frame.proj[3][3] != 0.0
        ? normalize(vec3(frame.view[0][2], frame.view[1][2], frame.view[2][2]))
        : normalize(frame.camera_position.xyz - world);
    return surface;
}

#endif
