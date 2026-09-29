#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "mesh_vertex.glsl"
#include "landscape/terrain_height.glsl"

struct TerrainChunk {
    vec2 origin;
    float span;
    float skirt_height;
};

TerrainChunk terrain_chunk(DrawRoot draw, TerrainParams params) {
#ifdef INSTANCED
    vec4 packed_chunk = InstanceArray(draw.instance_data).values[instance_source(draw)].color;
    return TerrainChunk(packed_chunk.xy, packed_chunk.z, packed_chunk.w);
#else
    // A plain draw is the whole map as one chunk; heights are never negative, so its skirts reach 0.
    return TerrainChunk(vec2(0.0), float(params.texels - 1u), 0.0);
#endif
}

void main() {
    DrawRoot draw = DrawRoot(pc.vertex_root_gpu);
    FrameRoot frame = FrameRoot(draw.frame);
    CustomMaterialGpu material = CustomMaterialGpu(draw.material);
    TerrainParams params = TerrainParams(material.parameters);
    TerrainChunk chunk = terrain_chunk(draw, params);
    vec3 unit = pull_vec3(GeometryRoot(draw.geometry).positions, uint(gl_VertexIndex));
    ivec2 texel = ivec2(chunk.origin + round(unit.xz * chunk.span));
    // The skirt ring lies at y = 0 of the unit box, under the edge vertex it hangs from.
    float height = unit.y > 0.5
        ? terrain_height(material.slots[TERRAIN_HEIGHT_SLOT].texture_index, params, texel)
        : chunk.skirt_height;
    vec3 local = vec3(float(texel.x) * params.cell_size, height, float(texel.y) * params.cell_size);
    vec4 world = draw.model * vec4(local, 1.0);
#if !defined(DEPTH_ONLY) && !defined(VELOCITY)
    v_world_pos = world.xyz;
    v_normal = normalize(mat3(draw.normal_0.xyz, draw.normal_1.xyz, draw.normal_2.xyz) * vec3(0.0, 1.0, 0.0));
    v_tangent = vec4(0.0);
#endif
    v_uv0 = local.xz;
    v_uv1 = vec2(texel) / float(params.texels - 1u);
    v_color = vec4(1.0);
    vec4 clip = frame.view_proj * world;
    gl_Position = clip;
    gl_ClipDistance[0] = view_clip_distance(frame, world.xyz);
#ifdef VELOCITY
#ifdef INSTANCED
    // Re-selection reuses record indices for other chunks: only the node's motion is object motion.
    v_prev_clip_pos = frame.prev_view_proj * (draw.prev_model * world);
#else
    v_prev_clip_pos = frame.prev_view_proj * (draw.prev_model * vec4(local, 1.0));
#endif
    clip.xy -= frame.jitter_time.xy * clip.w;
#endif
    v_clip_pos = clip;
}
