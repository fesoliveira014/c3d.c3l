#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "mesh_vertex.glsl"
#include "quadtree_morph.glsl"
#include "landscape/water_waves.glsl"
#include "landscape/water_simulation.glsl"
#include "landscape/water_spectral.glsl"

#ifdef INSTANCED
GPU_DECLARE_READONLY_ARRAY_REF(WaterDepthArray, uint);

const int WATER_CHUNK_CELLS = 64; // mirrored as OCEAN_CHUNK_CELLS in water/water.c3

// A chunk of the ocean: its origin and edge in lattice cells of the finest level, from the node's centre.
struct WaterChunk {
    ivec2 origin;
    int span;
};

struct WaterOceanPoint {
    vec3 position;
    vec3 normal;
    float crest;
};

WaterChunk water_chunk(DrawRoot draw) {
    vec4 record = InstanceArray(draw.instance_data).values[instance_source(draw)].color;
    return WaterChunk(ivec2(round(record.xy)), int(round(record.z)));
}

// Morph of a vertex toward its parent level for the camera that selected this pass's levels.
float water_morph(DrawRoot draw, FrameRoot frame, vec2 rest, vec4 selection_camera) {
    if ((draw.flags & DRAW_QUADTREE) == 0u) return 0.0;

    InstanceEffectsGpu effects = InstanceEffectsGpu(draw.instance_effects);
    QuadtreeGpu tree = QuadtreeGpu(effects.instance_quadtree);
    if (tree.metric != QUADTREE_METRIC_BOX_RANGES || quadtree_selection_orthographic(frame)) return 0.0;

    uint depth = WaterDepthArray(effects.instance_depths).values[instance_source(draw)];
    vec3 world = (draw.model * vec4(rest.x, 0.0, rest.y, 1.0)).xyz;
    return quadtree_morph(
        tree,
        depth,
        distance(world, selection_camera.xyz),
        selection_camera.w,
        quadtree_world_scale(draw.model)
    );
}

// The ocean's surface at a rest point from the waves or from the field, by the body's wave model.
WaterSurfacePoint water_ocean_surface(
    CustomMaterialGpu material,
    WaterParams params,
    vec2 rest,
    float time,
    float cell
) {
    if ((params.flags & WATER_SPECTRAL) != 0u) return water_spectral_point(material, params, rest);
    return water_surface_point(params, rest, time, cell);
}

// Where the update before drew the rest point.
vec3 water_ocean_previous(CustomMaterialGpu material, WaterParams params, vec2 rest, float time, float cell) {
    if ((params.flags & WATER_SPECTRAL) != 0u) return water_spectral_previous_position(material, params, rest);
    return water_displaced_position(params, true, rest, time, cell);
}

// The parent lattice's neighbours of an odd vertex, in lattice cells of this level: the cell's edge ends along an edge
// vertex, its diagonal ends at the cell centre, on the diagonal the chunk's triangles split along.
ivec2 water_parent_offset(ivec2 grid, int step) {
    ivec2 odd = grid & 1;
    return odd.y == 0 ? ivec2(step, 0) : (odd.x == 0 ? ivec2(0, step) : ivec2(step, -step));
}

// The vertex after its morph: its point is blended toward the mean of its two parent-lattice neighbours' points, which
// lie on the coarse side's triangle edge. The wave fade follows the morph, so a vertex at morph 1 fades like its
// parent level's.
WaterOceanPoint water_ocean_point(
    CustomMaterialGpu material,
    WaterParams params,
    ivec2 lattice,
    ivec2 grid,
    int step,
    float morph,
    float time
) {
    float cell = params.cell_size * float(step) * exp2(morph);
    WaterSurfacePoint own = water_ocean_surface(material, params, vec2(lattice) * params.cell_size, time, cell);
    WaterOceanPoint point = WaterOceanPoint(own.position, own.normal, own.crest);
    if (morph > 0.0 && ((grid.x | grid.y) & 1) != 0) {
        ivec2 offset = water_parent_offset(grid, step);
        vec2 first_rest = vec2(lattice - offset) * params.cell_size;
        vec2 second_rest = vec2(lattice + offset) * params.cell_size;
        WaterSurfacePoint first = water_ocean_surface(material, params, first_rest, time, cell);
        WaterSurfacePoint second = water_ocean_surface(material, params, second_rest, time, cell);
        point.position = mix(own.position, 0.5 * (first.position + second.position), morph);
        point.normal = normalize(mix(own.normal, normalize(first.normal + second.normal), morph));
        point.crest = mix(own.crest, 0.5 * (first.crest + second.crest), morph);
    }
    return point;
}

// The same blend of positions, with the waves of the update before.
vec3 water_ocean_previous_position(
    CustomMaterialGpu material,
    WaterParams params,
    ivec2 lattice,
    ivec2 grid,
    int step,
    float morph,
    float time
) {
    float cell = params.cell_size * float(step) * exp2(morph);
    vec3 position = water_ocean_previous(material, params, vec2(lattice) * params.cell_size, time, cell);
    if (morph > 0.0 && ((grid.x | grid.y) & 1) != 0) {
        ivec2 offset = water_parent_offset(grid, step);
        vec3 first = water_ocean_previous(material, params, vec2(lattice - offset) * params.cell_size, time, cell);
        vec3 second = water_ocean_previous(material, params, vec2(lattice + offset) * params.cell_size, time, cell);
        position = mix(position, 0.5 * (first + second), morph);
    }
    return position;
}
#endif

void main() {
    DrawRoot draw = DrawRoot(pc.vertex_root_gpu);
    GeometryRoot geometry = GeometryRoot(draw.geometry);
    FrameRoot frame = FrameRoot(draw.frame);
    CustomMaterialGpu material = CustomMaterialGpu(draw.material);
    WaterParams params = WaterParams(material.parameters);

#ifdef INSTANCED
    // The chunk's shape comes from its record, not the instance matrix: only the node's motion is object motion.
    WaterChunk chunk = water_chunk(draw);
    vec3 unit = pull_vec3(geometry.positions, uint(gl_VertexIndex));
    ivec2 lattice = chunk.origin + ivec2(round(unit.xz * float(chunk.span)));
    ivec2 grid = ivec2(round(unit.xz * float(WATER_CHUNK_CELLS)));
    int step = chunk.span / WATER_CHUNK_CELLS;
    vec2 rest = vec2(lattice) * params.cell_size;

    float morph = water_morph(draw, frame, rest, frame.selection_camera);
    WaterOceanPoint point = water_ocean_point(material, params, lattice, grid, step, morph, frame.jitter_time.z);
    vec4 world = draw.model * vec4(point.position, 1.0);
#if !defined(DEPTH_ONLY) && !defined(VELOCITY)
    v_world_pos = world.xyz;
    v_normal = normalize(mat3(draw.normal_0.xyz, draw.normal_1.xyz, draw.normal_2.xyz) * point.normal);
    v_tangent = vec4(0.0);
#endif
    v_uv0 = rest;
    v_uv1 = rest;
    v_color = vec4(1.0, 1.0, 1.0, point.crest);
    vec4 clip = frame.view_proj * world;
    gl_Position = clip;
    gl_ClipDistance[0] = view_clip_distance(frame, world.xyz);
#ifdef VELOCITY
    // The ocean is anchored to the world, so the point it drew last is the same world point under the current node.
    float previous_morph = water_morph(draw, frame, rest, frame.previous_selection_camera);
    vec3 previous = water_ocean_previous_position(
        material,
        params,
        lattice,
        grid,
        step,
        previous_morph,
        frame.previous_time
    );
    v_prev_clip_pos = frame.prev_view_proj * (draw.model * vec4(previous, 1.0));
    clip.xy -= frame.jitter_time.xy * clip.w;
    if ((draw.flags & DRAW_VERTEX_HISTORY_INVALID) != 0u) v_prev_clip_pos = clip;
#endif
    v_clip_pos = clip;
#else
    MeshVertexInput vertex = pull_mesh_vertex(geometry, uint(gl_VertexIndex));
    vec2 rest = vertex.position.xz;
    bool simulated = (params.flags & WATER_SIMULATED) != 0u;
    bool spectral = (params.flags & WATER_SPECTRAL) != 0u;
    uint grid_texture = material.slots[WATER_SIMULATION_SLOT].texture_index;
    WaterSurfacePoint point;
    if (simulated) {
        point = water_simulated_point(params, grid_texture, uint(gl_VertexIndex), rest);
    } else if (spectral) {
        point = water_spectral_point(material, params, rest);
    } else {
        point = water_surface_point(params, rest, frame.jitter_time.z);
    }
    vertex.position = point.position;
    vertex.normal = point.normal;
    vertex.tangent = vec4(point.tangent, 1.0);
    vertex.uv0 = rest;
    vertex.uv1 = rest;
    vertex.color = vec4(1.0, 1.0, 1.0, point.crest);
#ifdef VELOCITY
    vec3 previous;
    if (simulated) {
        previous = water_simulated_previous_position(params, grid_texture, uint(gl_VertexIndex), rest);
    } else if (spectral) {
        previous = water_spectral_previous_position(material, params, rest);
    } else {
        previous = water_previous_position(params, rest, frame.previous_time);
    }
    write_mesh_outputs(vertex, previous, draw, frame, geometry);
#else
    write_mesh_outputs(vertex, draw, frame, geometry);
#endif
#endif
}
