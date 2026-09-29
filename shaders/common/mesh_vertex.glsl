#ifndef C3D_MESH_VERTEX_GLSL
#define C3D_MESH_VERTEX_GLSL

#include "vertex_pull.glsl"
#if defined(SKINNED) || defined(SKINNED_U16) || defined(MORPH)
#include "deform.glsl"
#endif
#if !defined(DEPTH_ONLY) && !defined(VELOCITY)
#include "normal_mapping.glsl"
#endif

#ifdef INSTANCED
#include "instance_effects.glsl"
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
// A culled range draws over its visible list; every per-instance read indexes through this.
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
// Object-space position under the skin and morph the view drew last time.
vec3 previous_mesh_position(DrawRoot draw, GeometryRoot geometry, uint index) {
    vec3 position = pull_vec3(geometry.positions, index);
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

#ifdef INSTANCED
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
    mat4 model = instance.model;
    mat3 normal_matrix = mat3(instance.normal_0.xyz, instance.normal_1.xyz, instance.normal_2.xyz);
#else
    mat4 model = draw.model;
    mat3 normal_matrix = mat3(draw.normal_0.xyz, draw.normal_1.xyz, draw.normal_2.xyz);
#endif
    vec4 world = model * vec4(vertex.position, 1.0);
#ifdef INSTANCED
    world.xyz = apply_instance_effects(draw, instance, world.xyz, instance_bend_weight(draw, vertex.position, vertex.color));
#endif
#ifdef VELOCITY
    vec4 previous = vec4(previous_position, 1.0);
#ifdef INSTANCED
    // Without previous instance matrices, prev_model is the batch node's motion after the current instance matrix.
    uint64_t previous_instances = PreviousPoseGpu(draw.previous_pose).instances;
    vec4 previous_world = previous_instances != 0ul
        ? PreviousInstanceArray(previous_instances).values[source] * previous
        : draw.prev_model * (model * previous);
    if ((draw.flags & (DRAW_SWAY | DRAW_DISTANCE_FADE)) != 0u) {
        mat4 previous_model = previous_instances != 0ul
            ? PreviousInstanceArray(previous_instances).values[source]
            : draw.prev_model * model;
        previous_world.xyz = apply_previous_instance_effects(
            draw,
            instance,
            previous_model,
            previous_world.xyz,
            instance_bend_weight(draw, previous_position, vertex.color)
        );
    }
    v_prev_clip_pos = frame.prev_view_proj * previous_world;
#else
    v_prev_clip_pos = frame.prev_view_proj * (draw.prev_model * previous);
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
    v_color = vertex.color;
#ifdef INSTANCED
    if ((draw.flags & DRAW_SWAY_VERTEX_ALPHA) != 0u) v_color.a = 1.0;
    v_color *= instance.color;
#endif
    vec4 clip = frame.view_proj * world;
    gl_Position = clip;
#ifdef VELOCITY
    // Velocity is unjittered: remove the view's jitter from the rasterized position.
    clip.xy -= frame.jitter_time.xy * clip.w;
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
