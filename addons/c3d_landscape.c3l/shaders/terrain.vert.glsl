#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "mesh_vertex.glsl"
#include "quadtree_morph.glsl"
#include "landscape/terrain_height.glsl"

#ifdef INSTANCED
GPU_DECLARE_READONLY_ARRAY_REF(TerrainDepthArray, uint);
#endif

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

#ifdef INSTANCED
struct TerrainMorphedHeight {
    float current;
    float previous;
};

// A shadow layer's frame holds the light's projection: it tells the selecting view's only in that view's own passes.
bool terrain_selection_is_orthographic(FrameRoot frame) {
    return frame.proj[3][3] == 1.0 && frame.camera_position.xyz == frame.selection_camera.xyz;
}

// Height of an odd grid vertex on the parent level's surface, whose cells split from their +x,-z to their -x,+z corner.
float terrain_parent_height(uint height_texture, TerrainParams params, ivec2 texel, ivec2 odd, int step) {
    ivec2 offset = odd.y == 0 ? ivec2(step, 0) : (odd.x == 0 ? ivec2(0, step) : ivec2(step, -step));
    float first = terrain_height(height_texture, params, texel - offset);
    float second = terrain_height(height_texture, params, texel + offset);
    return 0.5 * (first + second);
}

// Height of a surface vertex after its morph toward the parent level, in this rendering and in the previous one.
// Only the height moves: an odd vertex already sits at its parent cell's edge midpoint or centre.
TerrainMorphedHeight terrain_morphed_height(
    DrawRoot draw,
    FrameRoot frame,
    TerrainParams params,
    TerrainChunk chunk,
    uint height_texture,
    ivec2 texel,
    ivec2 grid,
    float fine_height
) {
    TerrainMorphedHeight heights = TerrainMorphedHeight(fine_height, fine_height);
    ivec2 odd = grid & 1;
    if ((odd.x | odd.y) == 0 || (draw.flags & DRAW_QUADTREE) == 0u) return heights;

    InstanceEffectsGpu effects = InstanceEffectsGpu(draw.instance_effects);
    QuadtreeGpu tree = QuadtreeGpu(effects.instance_quadtree);
    if (tree.metric != QUADTREE_METRIC_BOX_RANGES || terrain_selection_is_orthographic(frame)) return heights;

    uint depth = TerrainDepthArray(effects.instance_depths).values[instance_source(draw)];
    vec3 fine_local = vec3(float(texel.x) * params.cell_size, fine_height, float(texel.y) * params.cell_size);
    vec3 fine_world = (draw.model * vec4(fine_local, 1.0)).xyz;
    float world_scale = quadtree_world_scale(draw.model);
    float morph = quadtree_morph(
        tree,
        depth,
        distance(fine_world, frame.selection_camera.xyz),
        frame.selection_camera.w,
        world_scale
    );
    // The node's own motion does not enter the previous morph: both cameras share the current origin.
    float previous_morph = quadtree_morph(
        tree,
        depth,
        distance(fine_world, frame.previous_selection_camera.xyz),
        frame.previous_selection_camera.w,
        world_scale
    );
    if (morph == 0.0 && previous_morph == 0.0) return heights;

    int step = int(chunk.span) / int(TERRAIN_CHUNK_CELLS);
    float parent = terrain_parent_height(height_texture, params, texel, odd, step);
    heights.current = mix(fine_height, parent, morph);
    heights.previous = mix(fine_height, parent, previous_morph);
    return heights;
}
#endif

void main() {
    DrawRoot draw = DrawRoot(pc.vertex_root_gpu);
    FrameRoot frame = FrameRoot(draw.frame);
    CustomMaterialGpu material = CustomMaterialGpu(draw.material);
    TerrainParams params = TerrainParams(material.parameters);
    TerrainChunk chunk = terrain_chunk(draw, params);
    vec3 unit = pull_vec3(GeometryRoot(draw.geometry).positions, uint(gl_VertexIndex));
    ivec2 texel = ivec2(chunk.origin + round(unit.xz * chunk.span));
    ivec2 grid = ivec2(round(unit.xz * float(TERRAIN_CHUNK_CELLS)));
    uint height_texture = material.slots[TERRAIN_HEIGHT_SLOT].texture_index;
    // The skirt ring lies at y = 0 of the unit box, under the edge vertex it hangs from.
    bool surface = unit.y > 0.5;
    float height = surface ? terrain_height(height_texture, params, texel) : chunk.skirt_height;
    float previous_height = height;
#ifdef INSTANCED
    if (surface) {
        TerrainMorphedHeight morphed = terrain_morphed_height(
            draw,
            frame,
            params,
            chunk,
            height_texture,
            texel,
            grid,
            height
        );
        height = morphed.current;
        previous_height = morphed.previous;
    }
#endif
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
    // The chunk's shape comes from its record, not the instance matrix: only the node's motion is object motion.
    vec4 previous_world = draw.model * vec4(local.x, previous_height, local.z, 1.0);
    v_prev_clip_pos = frame.prev_view_proj * (draw.prev_model * previous_world);
#else
    v_prev_clip_pos = frame.prev_view_proj * (draw.prev_model * vec4(local, 1.0));
#endif
    clip.xy -= frame.jitter_time.xy * clip.w;
#endif
    v_clip_pos = clip;
}
