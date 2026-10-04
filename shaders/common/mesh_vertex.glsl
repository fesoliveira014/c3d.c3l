#ifndef C3D_MESH_VERTEX_GLSL
#define C3D_MESH_VERTEX_GLSL

#include "vertex_pull.glsl"
#include "view_clip.glsl"
#if defined(SKINNED) || defined(SKINNED_U16) || defined(MORPH)
#include "deform.glsl"
#endif
#if !defined(DEPTH_ONLY) && !defined(VELOCITY)
#include "normal_mapping.glsl"
#endif

#include "instance_effects.glsl"
GPU_DECLARE_READONLY_ARRAY_REF(LodPreviousArray, LodHistoryGpu);
#ifdef INSTANCED
GPU_DECLARE_READONLY_ARRAY_REF(InstanceArray, InstanceGpu);
GPU_DECLARE_READONLY_ARRAY_REF(VisibleArray, uint);
#ifdef VELOCITY
GPU_DECLARE_READONLY_ARRAY_REF(PreviousInstanceArray, mat4);
#endif
#endif

layout(location = 0) out vec3 v_world_pos;
layout(location = 1) out vec3 v_normal;
layout(location = 2) out vec4 v_tangent;
layout(location = 3) out vec2 v_uv0;
layout(location = 4) out vec2 v_uv1;
layout(location = 5) out vec4 v_color;
layout(location = 6) out vec4 v_clip_pos;
#ifdef VELOCITY
layout(location = 7) out vec4 v_prev_clip_pos;
#endif

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

#ifdef INSTANCED
// A culled or sorted range draws over its visible list; every per-instance read indexes through this.
uint instance_source(DrawRoot draw) {
    return draw.instance_indices != 0ul
        ? VisibleArray(draw.instance_indices).values[gl_InstanceIndex]
        : uint(gl_InstanceIndex);
}
#endif

struct MeshVertexInput {
    vec3 position;
    vec3 normal;
    vec4 tangent;
    vec2 uv0;
    vec2 uv1;
    vec4 color;
};

MeshVertexInput pull_mesh_vertex(GeometryRoot geometry, uint index) {
    MeshVertexInput vertex;
    vertex.position = pull_vec3(geometry.positions, index);
    vertex.normal = (geometry.flags & GEOMETRY_HAS_NORMALS) != 0u
        ? pull_vec3(geometry.normals, index)
        : vec3(0.0, 0.0, 1.0);
    vertex.tangent = (geometry.flags & GEOMETRY_HAS_TANGENTS) != 0u
        ? pull_vec4(geometry.tangents, index)
        : vec4(0.0);
    vertex.uv0 = (geometry.flags & GEOMETRY_HAS_UV0) != 0u ? pull_vec2(geometry.uv0, index) : vec2(0.0);
    vertex.uv1 = (geometry.flags & GEOMETRY_HAS_UV1) != 0u ? pull_vec2(geometry.uv1, index) : vec2(0.0);
    vertex.color = (geometry.flags & GEOMETRY_HAS_COLORS) != 0u ? pull_vec4(geometry.colors, index) : vec4(1.0);
    return vertex;
}

#if defined(SKINNED) || defined(SKINNED_U16) || defined(MORPH)
#define PALETTE_MATRIX_BYTES 64ul // mirrors Mat4f::size of a palette entry
#define MORPH_BLOCK_BYTES 80ul // mirrors MorphWeightsGpu::size

// A crowd instance reads its own palette and morph block; a single mesh reads the base address.
uint64_t instance_palette(DrawRoot draw, uint64_t palette_base) {
#ifdef INSTANCED
    return palette_base + uint64_t(instance_source(draw)) * uint64_t(draw.skin_stride) * PALETTE_MATRIX_BYTES;
#else
    return palette_base;
#endif
}

uint64_t instance_morph(DrawRoot draw, uint64_t morph_base) {
#ifdef INSTANCED
    return morph_base + uint64_t(instance_source(draw)) * MORPH_BLOCK_BYTES;
#else
    return morph_base;
#endif
}
#endif

void apply_mesh_deformation(inout MeshVertexInput vertex, DrawRoot draw, GeometryRoot geometry, uint index) {
#ifdef MORPH
    MorphWeightsGpu morph = MorphWeightsGpu(instance_morph(draw, draw.morph));
    vertex.position += morph_delta(geometry, morph, index, MORPH_STREAM_POSITION);
    vertex.normal += morph_delta(geometry, morph, index, MORPH_STREAM_NORMAL);
#endif
#if defined(SKINNED) || defined(SKINNED_U16)
    mat4 skin = skin_matrix(geometry, instance_palette(draw, draw.skin), index);
    vertex.position = (skin * vec4(vertex.position, 1.0)).xyz;
    vertex.normal = mat3(skin) * vertex.normal;
    vertex.tangent.xyz = mat3(skin) * vertex.tangent.xyz;
#endif
}

#ifdef VELOCITY
// Object-space position under the base positions, skin and morph the view drew last time.
vec3 previous_mesh_position(DrawRoot draw, GeometryRoot geometry, uint index) {
    vec3 position = pull_vec3(geometry.positions, index);
    if ((draw.flags & DRAW_VERTEX_HISTORY_INVALID) != 0u) return position;
    if (draw.previous_pose != 0ul) {
        uint64_t positions = PreviousPoseGpu(draw.previous_pose).positions;
        if (positions != 0ul) position = pull_vec3(positions, index);
    }
#ifdef MORPH
    MorphWeightsGpu morph = MorphWeightsGpu(instance_morph(draw, PreviousPoseGpu(draw.previous_pose).morph));
    position += morph_delta(geometry, morph, index, MORPH_STREAM_POSITION);
#endif
#if defined(SKINNED) || defined(SKINNED_U16)
    mat4 skin = skin_matrix(geometry, instance_palette(draw, PreviousPoseGpu(draw.previous_pose).skin), index);
    position = (skin * vec4(position, 1.0)).xyz;
#endif
    return position;
}
#endif

// The effects block is read only under DRAW_SWAY or DRAW_DISTANCE_FADE; DRAW_SWAY_VERTEX_ALPHA alone reads vertex colour only.
float instance_bend_weight(DrawRoot draw, vec3 local_position, vec4 color) {
    if ((draw.flags & DRAW_SWAY) == 0u) return 0.0;
    if ((draw.flags & DRAW_SWAY_VERTEX_ALPHA) != 0u) return clamp(color.a, 0.0, 1.0);
    vec4 anchor = InstanceEffectsGpu(draw.instance_effects).anchor;
    // Height weight assumes +Y up in geometry space.
    float height = clamp((local_position.y - anchor.y) * anchor.w, 0.0, 1.0);
    return height * height;
}

vec3 apply_instance_effects(DrawRoot draw, InstanceGpu instance, vec3 world_position, float bend_weight) {
    if ((draw.flags & (DRAW_SWAY | DRAW_DISTANCE_FADE)) == 0u) return world_position;
    InstanceEffectsGpu effects = InstanceEffectsGpu(draw.instance_effects);
    vec3 anchor = instance_anchor(effects, instance.model);
    float seed = instance.normal_0.w;
    vec3 position = world_position;
    if ((draw.flags & DRAW_SWAY) != 0u) position += sway_offset(effects.sway, anchor, seed, bend_weight);
    if ((draw.flags & DRAW_DISTANCE_FADE) != 0u) {
        float scale = instance_fade_scale(effects, anchor, seed);
        // mix is not exact at 1 on every backend; an instance before the band keeps its position bit for bit.
        if (scale < 1.0) position = mix(anchor, position, scale);
    }
    return position;
}

#ifdef VELOCITY
vec3 apply_previous_instance_effects(
    DrawRoot draw,
    InstanceGpu instance,
    mat4 previous_model,
    vec3 previous_world_position,
    float bend_weight
) {
    if ((draw.flags & (DRAW_SWAY | DRAW_DISTANCE_FADE)) == 0u) return previous_world_position;
    InstanceEffectsGpu effects = InstanceEffectsGpu(draw.instance_effects);
    vec3 previous_anchor = instance_anchor(effects, previous_model);
    float seed = instance.normal_0.w;
    vec3 position = previous_world_position;
    if ((draw.flags & DRAW_SWAY) != 0u) position += sway_offset(effects.previous_sway, previous_anchor, seed, bend_weight);
    if ((draw.flags & DRAW_DISTANCE_FADE) != 0u) {
        // The current scale: the collapse itself carries no motion.
        float scale = instance_fade_scale(effects, instance_anchor(effects, instance.model), seed);
        if (scale < 1.0) position = mix(previous_anchor, position, scale);
    }
    return position;
}
#endif

// Non-velocity forms ignore previous_position.
void write_mesh_outputs(
    MeshVertexInput vertex,
    vec3 previous_position,
    DrawRoot draw,
    FrameRoot frame,
    GeometryRoot geometry
) {
#ifdef INSTANCED
    uint source = instance_source(draw);
    InstanceGpu instance = InstanceArray(draw.instance_data).values[source];
#else
    InstanceGpu instance;
    instance.model = draw.model;
    instance.normal_0 = draw.normal_0;
    instance.normal_0.w = draw.lod_part != 0ul ? LodPartGpu(draw.lod_part).seed : 0.0;
    instance.normal_1 = draw.normal_1;
    instance.normal_2 = draw.normal_2;
    instance.color = vec4(1.0);
#endif
    mat4 model = instance.model;
    mat3 normal_matrix = mat3(instance.normal_0.xyz, instance.normal_1.xyz, instance.normal_2.xyz);
    vec3 effect_position = vertex.position;
    if (draw.lod_part != 0ul) {
        LodPartGpu part = LodPartGpu(draw.lod_part);
        model *= part.local;
        normal_matrix *= mat3(part.normal_0.xyz, part.normal_1.xyz, part.normal_2.xyz);
        effect_position = (part.local * vec4(vertex.position, 1.0)).xyz;
    }
    vec4 world = model * vec4(vertex.position, 1.0);
    world.xyz = apply_instance_effects(draw, instance, world.xyz, instance_bend_weight(draw, effect_position, vertex.color));
#ifdef VELOCITY
    vec4 previous = vec4(previous_position, 1.0);
    mat4 previous_instance = draw.prev_model;
    float reject_history = draw.lod_part != 0ul ? float(LodPartGpu(draw.lod_part).reject_history) : 0.0;
#ifdef INSTANCED
    if (draw.lod_part != 0ul) {
        LodPartGpu part = LodPartGpu(draw.lod_part);
        if (part.current != 0ul) reject_history = max(reject_history, float(LodPreviousArray(part.current).values[source].reject_history));
        previous_instance = reject_history != 0.0 ? instance.model : LodPreviousArray(part.previous).values[source].model;
    } else {
        // Without previous instance matrices, prev_model carries only the batch node's motion.
        uint64_t previous_instances = PreviousPoseGpu(draw.previous_pose).instances;
        previous_instance = previous_instances != 0ul
            ? PreviousInstanceArray(previous_instances).values[source] : draw.prev_model * model;
    }
#endif
    if (draw.lod_part != 0ul) previous = LodPartGpu(draw.lod_part).local * previous;
    vec4 previous_world = previous_instance * previous;
    previous_world.xyz = apply_previous_instance_effects(
        draw, instance, previous_instance, previous_world.xyz,
        instance_bend_weight(draw, previous.xyz, vertex.color)
    );
    if (draw.lod_part != 0ul) {
        LodPartGpu part = LodPartGpu(draw.lod_part);
        if (reject_history != 0.0) {
            previous_world = world;
            previous_world.xyz += part.current_origin_delta.xyz;
        }
#ifdef INSTANCED
        else {
            previous_world.xyz += part.history_origin_delta.xyz;
        }
#endif
    }
    v_prev_clip_pos = frame.prev_view_proj * previous_world;
#endif
#if !defined(DEPTH_ONLY) && !defined(VELOCITY)
    v_world_pos = world.xyz;
    v_normal = normalize(normal_matrix * vertex.normal);
    v_tangent = (geometry.flags & GEOMETRY_HAS_TANGENTS) != 0u
        ? world_tangent(model, vertex.tangent)
        : vec4(0.0);
#endif
    v_uv0 = vertex.uv0;
    v_uv1 = vertex.uv1;
    v_color = vertex.color;
    if ((draw.flags & DRAW_SWAY_VERTEX_ALPHA) != 0u) v_color.a = 1.0;
    v_color *= instance.color;
    vec4 clip = frame.view_proj * world;
    gl_Position = clip;
    gl_ClipDistance[0] = view_clip_distance(frame, world.xyz);
#ifdef VELOCITY
    // Velocity is unjittered: remove the view's jitter from the rasterized position.
    clip.xy -= frame.jitter_time.xy * clip.w;
    if (draw.lod_part != 0ul) clip.z = reject_history;
    if ((draw.flags & DRAW_VERTEX_HISTORY_INVALID) != 0u) v_prev_clip_pos = clip;
#endif
    v_clip_pos = clip;
}

void write_mesh_outputs(MeshVertexInput vertex, DrawRoot draw, FrameRoot frame, GeometryRoot geometry) {
#ifdef VELOCITY
    write_mesh_outputs(vertex, previous_mesh_position(draw, geometry, uint(gl_VertexIndex)), draw, frame, geometry);
#else
    write_mesh_outputs(vertex, vertex.position, draw, frame, geometry);
#endif
}

#endif
