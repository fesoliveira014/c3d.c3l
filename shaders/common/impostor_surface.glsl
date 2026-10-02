#ifndef C3D_IMPOSTOR_SURFACE_GLSL
#define C3D_IMPOSTOR_SURFACE_GLSL

#include "descriptor_heap.glsl"
#include "impostor.glsl"
#include "standard_surface.glsl"

layout(location = 0) flat in uint v_source;
layout(push_constant) uniform Push { uint64_t vertex_root_gpu; uint64_t fragment_root_gpu; } pc;

const uint IMPOSTOR_REFINE_STEPS = 2u; // Two corrections per seed bound reconstruction independently of empty space.
const float IMPOSTOR_SLOPE_LIMIT = 0.1; // Flat sampled gradients use capture-plane depth to bound corrections.
const float IMPOSTOR_DEPTH_RESIDUAL = 0.04; // Reject cutout crossings behind their sampled depth sheet.

struct ImpostorSample {
    vec4 color;
    vec3 normal;
    float roughness;
    float distance;
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
    // Color remains coverage weighted; dilated surface attributes seed transparent pixels.
    result.color.rgb /= max(result.color.a, 1e-6);
    result.normal = decode_octahedral(surface.xy * 2.0 - 1.0);
    result.roughness = surface.z;
    result.distance = (point.z - (1.0 - 2.0 * surface.w)) * impostor.bounds.w;
    return result;
}

ImpostorSample impostor_project(
    ImpostorGpu impostor, uint index, vec3 origin, vec3 direction, float first, float last, float plane
) {
    mat3 basis = impostor_basis(impostor_direction(index, impostor.frames_per_side));
    float slope = dot(direction, basis[2]);
    ImpostorSample result;
    result.hit = false;
    if (abs(slope) < 1e-6 * length(direction)) return result;
    float distance = clamp((dot(impostor.bounds.xyz - origin, basis[2]) + plane) / slope, first, last);
    float probe_step = 2.0 * impostor.bounds.w / (float(impostor.cell_size - 2u * IMPOSTOR_GUTTER) * length(direction));
    for (uint refinement = 0u; refinement <= IMPOSTOR_REFINE_STEPS; refinement++) {
        result = impostor_sample(impostor, index, basis, origin + direction * distance);
        if (refinement == IMPOSTOR_REFINE_STEPS) break;
        ImpostorSample probe = impostor_sample(impostor, index, basis, origin + direction * (distance + probe_step));
        float gradient = (probe.distance - result.distance) / probe_step;
        float correction = result.distance / (abs(gradient) > abs(slope) * IMPOSTOR_SLOPE_LIMIT ? gradient : slope);
        distance = clamp(distance - correction, first, last);
    }
    // A cutout edge is not a surface if the ray entered behind its depth sheet.
    result.hit = result.hit && abs(result.distance) < impostor.bounds.w * IMPOSTOR_DEPTH_RESIDUAL;
    result.distance = distance;
    return result;
}

ImpostorSample impostor_trace(
    ImpostorGpu impostor, uint index, vec3 origin, vec3 direction, float first, float last
) {
    ImpostorSample result = impostor_project(impostor, index, origin, direction, first, last, impostor.bounds.w);
    if (!result.hit) result = impostor_project(impostor, index, origin, direction, first, last, 0.0);
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
    if (last <= first) discard;
    float reference_distance = clamp(-projected, first, last);
    vec3 reference_world = origin + direction * reference_distance;
    vec3 reference_local = impostor_local(draw, instance, inverse_model, reference_world);
    vec3 local_direction = mat3(inverse_model) * direction;
    if ((draw.flags & DRAW_DISTANCE_FADE) != 0u) {
        InstanceEffectsGpu effects = InstanceEffectsGpu(draw.instance_effects);
        local_direction /= max(instance_fade_scale(effects, instance_anchor(effects, instance.model), instance.normal_0.w), 1e-6);
    }
    if ((draw.flags & DRAW_SWAY) != 0u) {
        InstanceEffectsGpu effects = InstanceEffectsGpu(draw.instance_effects);
        vec3 bend = mat3(inverse_model) * sway_offset(effects.sway, instance_anchor(effects, instance.model), instance.normal_0.w, 1.0);
        float height = clamp((reference_local.y - effects.anchor.y) * effects.anchor.w, 0.0, 1.0);
        float derivative = 2.0 * height * effects.anchor.w;
        local_direction -= bend * (derivative * local_direction.y / (1.0 + derivative * bend.y));
    }
    vec3 local_origin = reference_local - local_direction * reference_distance;
    float coverage = 0.0;
    float distance = 0.0;
    vec3 color = vec3(0.0);
    vec3 normal = vec3(0.0);
    float roughness = 0.0;
    for (uint index = 0u; index < 3u; index++) {
        if (weights[index] == 0.0) continue;
        ImpostorSample sample_value = impostor_trace(impostor, frames[index], local_origin, local_direction, first, last);
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
