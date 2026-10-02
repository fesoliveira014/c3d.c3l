#ifndef C3D_IMPOSTOR_GLSL
#define C3D_IMPOSTOR_GLSL

#include "gbuffer.glsl"
#include "buffer_reference.glsl"
#include "instance_effects.glsl"

GPU_DECLARE_READONLY_ARRAY_REF(ImpostorInstances, InstanceGpu);
GPU_DECLARE_READONLY_ARRAY_REF(ImpostorIndices, uint);
GPU_DECLARE_READONLY_ARRAY_REF(ImpostorHistory, LodHistoryGpu);

vec3 impostor_direction(uint index, uint side) {
    if (side == IMPOSTOR_TETRA_SIDE) {
        return normalize(vec3(
            float((IMPOSTOR_TETRA_X_BITS >> index) & 1u),
            float((IMPOSTOR_TETRA_Y_BITS >> index) & 1u),
            float((IMPOSTOR_TETRA_Z_BITS >> index) & 1u)
        ) * 2.0 - 1.0);
    }
    return decode_octahedral(vec2(index % side, index / side) * (2.0 / float(side - 1u)) - 1.0);
}

void impostor_frames(vec3 direction, uint side, out uvec3 indices, out vec3 weights) {
    if (side == IMPOSTOR_TETRA_SIDE) {
        vec4 tetra_weights;
        uint excluded = 0u;
        for (uint index = 0u; index < 4u; index++) {
            tetra_weights[index] = (1.0 + 3.0 * dot(direction, impostor_direction(index, side))) * 0.25;
            if (tetra_weights[index] < tetra_weights[excluded]) excluded = index;
        }
        uint next = 0u;
        for (uint index = 0u; index < 4u; index++) {
            if (index == excluded) continue;
            indices[next] = index;
            weights[next++] = max(tetra_weights[index], 0.0);
        }
        weights /= dot(weights, vec3(1.0));
        return;
    }
    vec2 grid = (encode_octahedral(direction) * 0.5 + 0.5) * float(side - 1u);
    uvec2 cell = min(uvec2(max(grid, 0.0)), uvec2(side - 2u));
    vec2 fraction = clamp(grid - vec2(cell), 0.0, 1.0);
    uint first = cell.y * side + cell.x;
    if (fraction.x + fraction.y <= 1.0) {
        indices = uvec3(first, first + 1u, first + side);
        weights = vec3(1.0 - fraction.x - fraction.y, fraction.x, fraction.y);
    } else {
        indices = uvec3(first + side + 1u, first + side, first + 1u);
        weights = vec3(fraction.x + fraction.y - 1.0, 1.0 - fraction.x, 1.0 - fraction.y);
    }
}

mat3 impostor_basis(vec3 direction) {
    vec3 up = abs(direction.y) > IMPOSTOR_POLE_LIMIT ? vec3(0.0, 0.0, 1.0) : vec3(0.0, 1.0, 0.0);
    vec3 side = normalize(cross(up, direction));
    return mat3(side, cross(direction, side), direction);
}

InstanceGpu impostor_instance(DrawRoot draw, uint source) {
    if (draw.instance_data != 0ul) return ImpostorInstances(draw.instance_data).values[source];
    InstanceGpu instance;
    instance.model = draw.model;
    instance.normal_0 = vec4(draw.normal_0.xyz, LodPartGpu(draw.lod_part).seed);
    instance.normal_1 = draw.normal_1;
    instance.normal_2 = draw.normal_2;
    instance.color = vec4(1.0);
    return instance;
}

float impostor_bend(InstanceEffectsGpu effects, vec3 local) {
    float height = clamp((local.y - effects.anchor.y) * effects.anchor.w, 0.0, 1.0);
    return height * height;
}

vec3 impostor_world(DrawRoot draw, InstanceGpu instance, mat4 model, vec3 local, bool previous) {
    vec3 world = (model * vec4(local, 1.0)).xyz;
    if ((draw.flags & (DRAW_SWAY | DRAW_DISTANCE_FADE)) == 0u) return world;
    InstanceEffectsGpu effects = InstanceEffectsGpu(draw.instance_effects);
    vec3 anchor = instance_anchor(effects, model);
    if ((draw.flags & DRAW_SWAY) != 0u) {
        world += sway_offset(previous ? effects.previous_sway : effects.sway, anchor, instance.normal_0.w, impostor_bend(effects, local));
    }
    if ((draw.flags & DRAW_DISTANCE_FADE) != 0u) {
        float scale = instance_fade_scale(effects, instance_anchor(effects, instance.model), instance.normal_0.w);
        if (scale < 1.0) world = mix(anchor, world, scale);
    }
    return world;
}

vec3 impostor_local(DrawRoot draw, InstanceGpu instance, mat4 inverse_model, vec3 world) {
    if ((draw.flags & (DRAW_SWAY | DRAW_DISTANCE_FADE)) == 0u) return (inverse_model * vec4(world, 1.0)).xyz;
    InstanceEffectsGpu effects = InstanceEffectsGpu(draw.instance_effects);
    vec3 anchor = instance_anchor(effects, instance.model);
    if ((draw.flags & DRAW_DISTANCE_FADE) != 0u) {
        float scale = instance_fade_scale(effects, anchor, instance.normal_0.w);
        world = anchor + (world - anchor) / max(scale, 1e-6);
    }
    vec3 unbent = (inverse_model * vec4(world, 1.0)).xyz;
    vec3 local = unbent;
    if ((draw.flags & DRAW_SWAY) != 0u) {
        vec3 bend = mat3(inverse_model) * sway_offset(effects.sway, anchor, instance.normal_0.w, 1.0);
        for (uint iteration = 0u; iteration < 5u; iteration++) {
            local = unbent - bend * impostor_bend(effects, local);
        }
    }
    return local;
}

vec3 impostor_view_direction(FrameRoot frame, mat4 inverse_model, vec3 center) {
    vec3 direction = frame.proj[3][3] != 0.0
        ? vec3(frame.view[0][2], frame.view[1][2], frame.view[2][2])
        : frame.camera_position.xyz - center;
    return normalize(mat3(inverse_model) * direction);
}

#endif
