module c3d::landscape::terrain;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::ecs;
import c3d::maths;
import c3d::material;
import c3d::scene;
import std::math;

<*
 Cells along one chunk edge at every level.
*>
const uint CHUNK_CELLS = 128; // 17,157 grid and skirt vertices keep 16-bit indices; 101,376 indices per chunk draw

<*
 Quadtree levels of the largest height map, 4097 texels per side.
*>
const uint MAX_TERRAIN_LEVELS = 6; // 4097 texels: 1,365 bounds nodes, 1,024 chunks, 128 KiB of instance records

<*
 Projected chunk diameter, in output pixels, above which a chunk splits.
*>
const float DEFAULT_LOD_THRESHOLD = 512; // drawn cells under 2.8 px; halving it quadruples near chunks

<*
 Share of the threshold a split chunk falls below before it merges.
*>
const float DEFAULT_LOD_HYSTERESIS = 0.25f; // merges below 410 px; wider re-selects less, keeps finer chunks longer

<*
 Texels of a height map; columns along x, rows along z.
*>
struct TexelRect {
    uint x;
    uint z;
    uint columns;
    uint rows;
}

<*
 Height-map revisions around a terrain's last accepted refresh and the texels it covered.
*>
struct TerrainRefresh {
    uint      revision_before;
    uint      revision_after;
    TexelRect rect;            // the whole map unless the refresh took a mark_dirty rectangle
}

<*
 Maps, scales, layers and LOD tunables of one terrain.
*>
struct TerrainDesc {
    TextureId  height_map;     // R16_UINT, MIP_ZERO, square, CHUNK_CELLS * 2^n + 1 texels per side
    TextureId  control_map;    // linear RGBA8_UNORM weights of layers 0 to 3 over the extent; zero shows layer 0 alone
    float      cell_size;      // metres between texel centres along x and z
    float      height_scale;   // metres at texel 65535: height = height_scale * texel / 65535
    MaterialId[material::MAX_CUSTOM_MATERIAL_REFERENCES] layers; // STANDARD materials, leading; zero ids unused
    float      lod_threshold;  // projected chunk diameter in output pixels above which a chunk splits
    float      lod_hysteresis; // a split chunk merges below lod_threshold / (1 + lod_hysteresis)
    bool       cast_shadow;
    bool       receive_shadow;
}

<*
 Authored terrain of a node; the lod and shadow fields are read at every update.
*>
struct Terrain {
    TerrainDesc desc;
}

<*
 Derived bounds, selection and owned material of a terrain, written by the library.
*>
struct TerrainRuntime {
    Allocator                allocator;
    MaterialId               material;         // owned; removed with the runtime
    uint                     texels;           // per side of the accepted height map
    uint                     level_count;      // level 0 is the finest
    uint                     revision;         // height-map revision the bounds reflect
    char*                    pixels;           // pixels the bounds were built from; a new array is a replacement
    bool                     rejected;         // the last revision failed the checks; the batch is hidden
    TexelRect                pending;          // union of mark_dirty rectangles since the last refresh
    bool                     has_pending;
    bool                     stale;            // the batch does not hold the last selection
    uint[MAX_TERRAIN_LEVELS] level_offset;     // first node of each level
    ushort[]                 minimum;          // per node: lowest texel of its footprint
    ushort[]                 maximum;          // per node: highest texel of its footprint
    bool[]                   split;            // per node: split in the last selection
    uint[MAX_TERRAIN_LEVELS] chunks_per_level; // of the last selection
    uint                     lod_switches;     // splits plus merges in the last selection
    TerrainRefresh           last_refresh;     // kept until the next accepted refresh
}

<*
 Tunables at their defaults with shadows on; maps, scales and layers unset.
*>
fn TerrainDesc default_terrain_desc() {
    return {
        .lod_threshold  = DEFAULT_LOD_THRESHOLD,
        .lod_hysteresis = DEFAULT_LOD_HYSTERESIS,
        .cast_shadow    = true,
        .receive_shadow = true,
    };
}

<*
 Register Terrain and TerrainRuntime and the runtime's remove hook.
 @param [&inout] scene : "Gains the Terrain and TerrainRuntime stores."
 @param [&inout] assets : "Loses each removed terrain's material; outlives the scene."
 @return? c3d::CAPACITY_EXCEEDED
*>
fn void? register_terrain(Scene* scene, AssetStore* assets) {
    scene.register(Terrain)!;
    scene.register(TerrainRuntime)!;
    scene.set_remove_hook(TerrainRuntime, &remove_runtime, assets);
}

<*
 Attach a terrain to the node and build its bounds, batch and material.
 @param [&inout] scene : "Registered with register_terrain."
 @param [&inout] assets : "The store given to register_terrain."
 @param [&in] node : "Its transform places texel (0, 0)."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::CAPACITY_EXCEEDED
 @require scene.world.is_registered(TerrainRuntime)
 @require !scene.has(node, InstancedMesh) && !scene.has(node, Terrain)
*>
fn void? add_terrain(
    Scene* scene,
    AssetStore* assets,
    Node* node,
    TerrainDesc desc,
) {
    attach_terrain(
        scene: scene,
        assets: assets,
        node: node,
        desc: desc,
    )!;
    defer catch scene.remove_component(node, Terrain);
    return prepare(scene, assets, node);
}

<*
 Attach validated terrain authoring without generating draw resources.
 @param [&inout] scene : "Registered with register_terrain."
 @param [&in] assets : "Resolves authored references; unchanged."
 @param [&in] node : "Receives the pending terrain component."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED
 @require scene.world.is_registered(TerrainRuntime)
 @require !scene.has(node, InstancedMesh) && !scene.has(node, Terrain)
*>
fn void? attach_terrain(
    Scene* scene,
    AssetStore* assets,
    Node* node,
    TerrainDesc desc,
) {
    check_terrain_desc(assets, &desc)!;
    scene.add(node, (Terrain){ .desc = desc });
}

<*
 Whether the separate terrain runtime component is present.
 @param [&in] scene : "Contains authoring and optional runtime components."
 @param [&in] node : "Carries Terrain."
 @require scene.has(node, Terrain)
*>
fn bool is_prepared(Scene* scene, Node* node) => scene.has(node, TerrainRuntime);

<*
 Prepare a pending terrain atomically; prepared terrain is unchanged.
 @param [&inout] scene : "Registered with register_terrain."
 @param [&inout] assets : "The store given to register_terrain."
 @param [&in] node : "Carries Terrain."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::CAPACITY_EXCEEDED
 @require scene.has(node, Terrain)
*>
fn void? prepare(Scene* scene, AssetStore* assets, Node* node) {
    if (is_prepared(scene, node)) return;
    TerrainDesc desc = scene.get(node, Terrain).desc;
    uint layer_count = check_terrain_desc(assets, &desc)!;
    TextureAsset* height_map = assets.texture(desc.height_map);
    uint texels = height_map.desc.width;
    bool shader_created, grid_created;
    ShaderId shader = terrain_shader(assets, &shader_created)!;
    defer catch if (shader_created) assets.remove_shader(shader);
    GeometryId grid = terrain_grid(assets, &grid_created)!;
    defer catch if (grid_created) assets.remove_geometry(grid);
    MaterialId owned = add_terrain_material(
        assets:      assets,
        shader:      shader,
        desc:        &desc,
        layer_count: layer_count,
    )!;
    defer catch assets.remove_material(owned);

    TerrainRuntime runtime = create_runtime(scene.allocator, texels)!;
    defer catch free_runtime(&runtime);
    runtime.material = owned;
    runtime.revision = height_map.header.revision;
    runtime.pixels = height_map.pixels.ptr;
    runtime.last_refresh = {
        .revision_before = runtime.revision,
        .revision_after  = runtime.revision,
        .rect            = whole_map(texels),
    };
    refresh_bounds(&runtime, height_texels(height_map), whole_map(texels));
    InstancedMesh batch = create_batch(
        allocator: scene.allocator,
        grid:      grid,
        owned:     owned,
        capacity:  finest_chunk_count(&runtime),
        desc:      &desc,
    )!;

    scene.add(node, batch);
    scene.add(node, runtime);
}

<*
 Prepare every pending terrain in a subtree, retaining successful owners.
 @param [&inout] scene : "Registered; prepared owners remain unchanged."
 @param [&inout] assets : "Receives generated resources during preparation."
 @param [in] root : "Null selects the scene root; root is included."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED, c3d::UNSUPPORTED
*>
fn void? prepare_subtree(Scene* scene, AssetStore* assets, Node* root = null) {
    if (!root) root = scene.root;
    fault failure;
    scene.@each(Terrain; entity, owner) {
        Node* node = scene.node(entity);
        Node* ancestor = node;
        while (ancestor && ancestor != root) ancestor = ancestor.parent;
        if (ancestor) {
            if (catch excuse = prepare(scene, assets, node)) {
                if (!failure) failure = excuse;
            }
        }
    };
    if (failure) return failure~;
}

<*
 Record texels written in place since the last update.
 @param [&inout] scene
 @param [&in] node : "Carries a terrain."
 @require scene.has(node, TerrainRuntime), rect.columns > 0 && rect.rows > 0
 @require rect.x + rect.columns <= scene.get(node, TerrainRuntime).texels
 @require rect.z + rect.rows <= scene.get(node, TerrainRuntime).texels
*>
fn void mark_dirty(Scene* scene, Node* node, TexelRect rect) {
    TerrainRuntime* runtime = scene.get(node, TerrainRuntime);
    if (!runtime.has_pending) {
        runtime.pending = rect;
        runtime.has_pending = true;
        return;
    }
    runtime.pending = union_rect(runtime.pending, rect);
}

<*
 Refresh changed bounds and select every terrain's chunks for one camera.
 Invalidates InstancedMesh and TerrainRuntime pointers when a Terrain was removed.
 @param [&inout] scene : "Pending terrains are skipped; their authoring is unchanged."
 @param [&inout] assets : "The store given to register_terrain."
 @param [&in] camera_node : "Carries a Camera; world matrices current."
 @param output_height_pixels : "Height of the output the thresholds are tuned for."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED
 @require scene.has(camera_node, Camera), output_height_pixels > 0
*>
fn void? update(
    Scene* scene,
    AssetStore* assets,
    Node* camera_node,
    float output_height_pixels,
) {
    remove_orphans(scene);
    Camera camera = *scene.get(camera_node, Camera);
    Vec3 camera_position = maths::translation(camera_node.world);
    fault failure;
    scene.@each(TerrainRuntime; entity, runtime) {
        Node* node = scene.node(entity);
        Terrain* terrain = scene.get(node, Terrain);
        InstancedMesh* batch = scene.get(node, InstancedMesh);
        if (catch excuse = refresh_changed_bounds(assets, &terrain.desc, runtime)) {
            if (!failure) failure = excuse;
            // The GPU copy may already hold the rejected shape; draw nothing until a conforming revision.
            if (batch.count) {
                batch.count = 0;
                scene.mark_instances_dirty(node);
            }
            runtime.stale = true;
        } else {
            SelectFrame frame = {
                .runtime         = runtime,
                .batch           = batch,
                .desc            = &terrain.desc,
                .world           = node.world,
                .world_scale     = largest_axis_scale(node.world),
                .camera          = camera,
                .camera_position = camera_position,
                .output_height   = output_height_pixels,
            };
            select_chunks(&frame);
            if (runtime.stale || runtime.lod_switches) {
                scene.mark_instances_dirty(node);
                runtime.stale = false;
            }
            batch.cast_shadow = terrain.desc.cast_shadow;
            batch.receive_shadow = terrain.desc.receive_shadow;
        }
    };
    if (failure) return failure~;
}

fn TexelRect union_rect(TexelRect first, TexelRect second) @private {
    uint x = min(first.x, second.x);
    uint z = min(first.z, second.z);
    uint end_x = max(first.x + first.columns, second.x + second.columns);
    uint end_z = max(first.z + first.rows, second.z + second.rows);
    return { .x = x, .z = z, .columns = end_x - x, .rows = end_z - z };
}

fn TexelRect whole_map(uint texels) @private {
    return { .columns = texels, .rows = texels };
}

fn void? refresh_changed_bounds(AssetStore* assets, TerrainDesc* desc, TerrainRuntime* runtime) @private {
    if (!assets.textures.is_live(desc.height_map)) return c3d::INVALID_ID~;
    TextureAsset* texture = assets.texture(desc.height_map);
    if (texture.header.revision == runtime.revision) return;
    defer catch runtime.rejected = true;
    check_height_map(texture)!;
    // Bounds, instance capacity and the material payload are sized for one side length.
    if (texture.desc.width != runtime.texels) return c3d::INVALID_ARGUMENT~;
    // The rectangle covers in-place writes only: a rejected revision or a replacement, whose pixels may
    // reuse an address, rebuilds everything.
    bool in_place = runtime.has_pending
        && !runtime.rejected
        && texture.pixels.ptr == runtime.pixels
        && texture.header.replaced_revision <= runtime.revision;
    TexelRect refreshed = in_place ? runtime.pending : whole_map(runtime.texels);
    refresh_bounds(runtime, height_texels(texture), refreshed);
    runtime.last_refresh = {
        .revision_before = runtime.revision,
        .revision_after  = texture.header.revision,
        .rect            = refreshed,
    };
    runtime.pixels = texture.pixels.ptr;
    runtime.rejected = false;
    runtime.has_pending = false;
    runtime.revision = texture.header.revision;
    runtime.stale = true;
}

// A hook runs inside the entity's removal: the node's other components may already be gone.
fn void remove_runtime(Entity entity, void* component, void* user) @private {
    TerrainRuntime* runtime = component;
    AssetStore* assets = user;
    assets.remove_material(runtime.material);
    free_runtime(runtime);
}

// Hooks cannot remove a sibling component, so a runtime whose Terrain left is torn down here.
fn void remove_orphans(Scene* scene) @private {
    while (true) {
        Entity orphan;
        scene.@each(TerrainRuntime; entity, runtime) {
            if (!scene.world.has(entity, Terrain)) orphan = entity;
        };
        if (!orphan.generation) return;
        Node* node = scene.node(orphan);
        scene.remove_component(node, InstancedMesh);
        scene.remove_component(node, TerrainRuntime);
    }
}
