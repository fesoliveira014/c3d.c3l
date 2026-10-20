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
#ifdef OUTLINE
#include "outline.glsl"
#endif

#include "instance_effects.glsl"
#include "instance_world.glsl"
GPU_DECLARE_READONLY_ARRAY_REF(LodPreviousArray, LodHistoryGpu);
GPU_DECLARE_READONLY_ARRAY_REF(InstanceArray, InstanceGpu);
#ifdef INSTANCED
GPU_DECLARE_READONLY_ARRAY_REF(VisibleArray, uint);
#endif
#ifdef VELOCITY
GPU_DECLARE_READONLY_ARRAY_REF(PreviousInstanceArray, mat4);
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
layout(location = 8) out vec3 v_billboard;

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

// The source of a crowd record: its palette and morph row, and its posed slot.
uint logical_source(DrawRoot draw) {
    return uint(InstanceArray(draw.instance_data).values[instance_source(draw)].normal_2.w);
}

// The batch record of an instance in world space: model and normal rows composed with the node's, then seed, parity,
// source index and colour.
InstanceGpu world_instance(DrawRoot draw, uint source) {
    return instance_to_world(draw, InstanceArray(draw.instance_data).values[source]);
}
#endif

#if defined(VELOCITY) && defined(INSTANCED)
// The world model the view drew an instance with last time. An instance without a previous matrix did not change,
// so draw.prev_model carries only the batch node's motion; prev_model * model is the node's previous world.
mat4 previous_world_model(DrawRoot draw, uint source, mat4 current_world) {
    PreviousPoseGpu previous_pose = PreviousPoseGpu(draw.previous_pose);
    mat4 previous_world;
    if (previous_pose.instances != 0ul
        && source >= previous_pose.instances_first && source < previous_pose.instances_end) {
        mat4 previous_local = PreviousInstanceArray(previous_pose.instances)
            .values[source - previous_pose.instances_first];
        previous_world = (draw.prev_model * draw.model) * previous_local;
    } else {
        previous_world = draw.prev_model * current_world;
    }
    return previous_world;
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

// A posed crowd draw keeps one copy of the deformed streams per source, source after source.
uint stream_vertex_index(DrawRoot draw, GeometryRoot geometry, uint index) {
#ifdef POSED_INSTANCED
    return logical_source(draw) * geometry.vertex_count + index;
#else
    return index;
#endif
}

MeshVertexInput pull_mesh_vertex(GeometryRoot geometry, uint index, uint stream_index) {
    MeshVertexInput vertex;
    vertex.position = pull_vec3(geometry.positions, stream_index);
    vertex.normal = (geometry.flags & GEOMETRY_HAS_NORMALS) != 0u
        ? pull_vec3(geometry.normals, stream_index)
        : vec3(0.0, 0.0, 1.0);
    vertex.tangent = (geometry.flags & GEOMETRY_HAS_TANGENTS) != 0u
        ? pull_vec4(geometry.tangents, stream_index)
        : vec4(0.0);
    vertex.uv0 = (geometry.flags & GEOMETRY_HAS_UV0) != 0u ? pull_vec2(geometry.uv0, index) : vec2(0.0);
    vertex.uv1 = (geometry.flags & GEOMETRY_HAS_UV1) != 0u ? pull_vec2(geometry.uv1, index) : vec2(0.0);
    vertex.color = (geometry.flags & GEOMETRY_HAS_COLORS) != 0u ? pull_vec4(geometry.colors, index) : vec4(1.0);
    return vertex;
}

MeshVertexInput pull_mesh_vertex(GeometryRoot geometry, uint index) {
    return pull_mesh_vertex(geometry, index, index);
}

#if defined(SKINNED) || defined(SKINNED_U16) || defined(MORPH)
// A crowd instance reads the row of its logical source in the resident palette and morph block.
// A single mesh reads the base address.
uint64_t instance_palette(DrawRoot draw, uint64_t palette_base) {
#ifdef INSTANCED
    return palette_base + uint64_t(logical_source(draw)) * uint64_t(draw.skin_stride) * PALETTE_MATRIX_BYTES;
#else
    return palette_base;
#endif
}

uint64_t instance_morph(DrawRoot draw, uint64_t morph_base) {
#ifdef INSTANCED
    return morph_base + uint64_t(logical_source(draw)) * MORPH_BLOCK_BYTES;
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
    uint stream_index = stream_vertex_index(draw, geometry, index);
    vec3 position = pull_vec3(geometry.positions, stream_index);
    if ((draw.flags & DRAW_VERTEX_HISTORY_INVALID) != 0u) return position;
    if (draw.previous_pose != 0ul) {
        uint64_t positions = PreviousPoseGpu(draw.previous_pose).positions;
        if (positions != 0ul) position = pull_vec3(positions, stream_index);
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
    return sway_height_weight(InstanceEffectsGpu(draw.instance_effects).anchor, local_position.y);
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
    InstanceGpu instance = world_instance(draw, source);
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

        mat4 local = part.local;

        if (part.part_instances != 0ul) {
            uint part_source = 0u;
#ifdef INSTANCED
            part_source = source;
#endif

            InstanceGpu sampled = InstanceArray(part.part_instances).values[part_source];
            model *= sampled.model;
            normal_matrix *= mat3(sampled.normal_0.xyz, sampled.normal_1.xyz, sampled.normal_2.xyz);
            local *= sampled.model;
        }

        effect_position = (local * vec4(vertex.position, 1.0)).xyz;
    }

    vec4 world = model * vec4(vertex.position, 1.0);
    world.xyz = apply_instance_effects(draw, instance, world.xyz, instance_bend_weight(draw, effect_position, vertex.color));
#ifdef OUTLINE
    ToonMaterialGpu outline_material = ToonMaterialGpu(draw.material);
    vec2 outline_offset = outline_shift(frame, outline_material, normalize(normal_matrix * vertex.normal));
#endif
#ifdef VELOCITY
    vec4 previous = vec4(previous_position, 1.0);
    mat4 previous_instance = draw.prev_model;
    float reject_history = draw.lod_part != 0ul ? float(LodPartGpu(draw.lod_part).reject_history) : 0.0;
#ifdef INSTANCED
    if (draw.lod_part != 0ul) {
        LodPartGpu part = LodPartGpu(draw.lod_part);
        if (part.current != 0ul) reject_history = max(reject_history, float(LodPreviousArray(part.current).values[source].reject_history));

        if (reject_history == 0.0 && part.history_levels != 0u) {
            uint previous_level = LodPreviousArray(part.previous).values[source].level;
            if ((part.history_levels & (1u << previous_level)) == 0u) reject_history = 1.0;
        }

        previous_instance = reject_history != 0.0 ? instance.model : LodPreviousArray(part.previous).values[source].model;
    } else {
        previous_instance = previous_world_model(draw, source, model);
    }
#endif
    if (draw.lod_part != 0ul) {
        LodPartGpu part = LodPartGpu(draw.lod_part);
        mat4 local = part.local;

        if (part.part_instances != 0ul) {
            uint part_source = 0u;
#ifdef INSTANCED
            part_source = source;
#endif

            uint64_t previous_parts = PreviousPoseGpu(draw.previous_pose).instances;
            local *= previous_parts != 0ul ? PreviousInstanceArray(previous_parts).values[part_source]
                : InstanceArray(part.part_instances).values[part_source].model;
        }

        previous = local * previous;
    }

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
#ifdef OUTLINE
    v_prev_clip_pos.xy += outline_offset * v_prev_clip_pos.w;
#endif
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
    v_billboard = vec3(vertex.uv0, 0.0);
    v_color = vertex.color;
    if ((draw.flags & DRAW_SWAY_VERTEX_ALPHA) != 0u) v_color.a = 1.0;
    v_color *= instance.color;
#ifdef OUTLINE
    // precise: the velocity form must rasterize the hull at the depth the colour form wrote.
    precise vec4 clip = outline_clip(frame, outline_material, world, outline_offset);
#else
    vec4 clip = frame.view_proj * world;
#endif
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
