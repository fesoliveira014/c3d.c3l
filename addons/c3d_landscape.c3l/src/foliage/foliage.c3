module c3d::landscape::foliage;

import c3d;
import c3d::asset;
import c3d::ecs;
import c3d::landscape::terrain @public;
import c3d::scene;
import std::math;

<*
 Cell edge of a layer at the default, in metres.
*>
const float DEFAULT_CELL_SIZE = 32; // 4,096 cells and nodes over a 2 km terrain; 64 m takes a quarter of both

<*
 Cells along one edge of a layer grid, at most.
*>
const uint MAX_CELLS_PER_SIDE = 1024; // 1,048,576 cells: 8 MiB of cell handles before any cell has a node

<*
 Candidate strata along one cell edge, at most.
*>
const uint MAX_STRATA_PER_SIDE = 1024; // 1,048,576 candidates per cell; a full cell holds 56 MiB of instance arrays

<*
 Distance fade of the default layer, in metres from the view camera.
*>
const InstanceFade DEFAULT_FADE = { .start = 60, .end = 90 }; // grass; the fade end is the far edge of every pass

<*
 Wind response of a layer, scaled by the wind speed at each update.
*>
struct SwayTemplate {
    float      amplitude;       // world units at bend weight 1 once the wind reaches full_bend_speed
    float      full_bend_speed; // metres per second of wind that bends to the full amplitude
    float      frequency;       // cycles per second at every wind speed
    float      lean;            // share of the amplitude held as a steady bend, in [0, 1]
    float      wavelength;      // world units between gust crests; 0 keeps the layer in phase
    float      variation;       // cycles of phase spread over the instance seeds
    SwayWeight weight;
}

<*
 Where candidates grow and how each placed instance varies.
*>
struct ScatterRules {
    TextureId density_map;     // linear RGBA8_UNORM over the ground's extent, terrain UV [0, 1]
    uint      density_channel; // 0 to 3: red, green, blue, alpha
    float     spacing;         // metres between candidate strata; one candidate per stratum
    uint      seed;
    float     max_slope;       // radians between up and the ground's face normal
    float     min_altitude;    // world y
    float     max_altitude;
    float     min_scale;
    float     max_scale;
    Vec3      min_tint;        // instance colour; multiplies the material's base colour
    Vec3      max_tint;
}

<*
 Geometry, material, ground, grid, rules and effects of one layer.
*>
struct FoliageDesc {
    GeometryId   geometry;
    MaterialId   material;
    LodDesc*     lod;       // copied when set; replaces the geometry/material pair
    Entity       ground;    // node carrying the Terrain the layer grows on
    float        cell_size; // metres along a cell edge; the grid covers the ground's extent
    ScatterRules rules;
    SwayTemplate sway;
    InstanceFade fade;
    bool         cast_shadow;
    bool         receive_shadow;
    bool         trace;     // traced views see the cells in their rest pose
}

<*
 Poses and revisions a layer's cells were scattered against.
*>
struct ScatterInputs {
    Mat4 layer_world;
    Mat4 ground_world;
    uint ground_revision;  // the ground's height-map revision after its last refresh
    uint density_revision;
}

<*
 Authored layer owning its copied LOD description; read during preparation.
*>
struct Foliage {
    FoliageDesc desc;
}

<*
 Checked desc, cells, placement identity and wind state of a layer, written by the library.
*>
struct FoliageRuntime {
    Allocator     allocator;
    FoliageDesc   desc;                // captured preparation snapshot; authored edits never reach existing cells
    uint          cells_per_side;
    Entity[]      cells;               // row-major, x fastest; zero where a cell has no node
    ScatterInputs placed;              // of the cells
    ScatterInputs rejected;            // of the last failed re-scatter
    fault         rejection;           // of the last failed re-scatter; cleared by a successful one
    uint          rejected_free_nodes; // free scene nodes when it failed
    uint          count_passes;        // re-scatters that counted candidates
    Vec3          wind_velocity;       // of the last sway written
    InstanceSway  sway;                // written into every cell
    uint          cell_nodes;          // cells with a node
    uint          instances;           // placed over every cell
    uint          placed_cells;        // cells placed by the last update
}

<*
 Grass defaults: 32 m cells, a 60 to 90 m fade, no shadow; ids, ground and spacing unset.
*>
fn FoliageDesc default_foliage_desc() {
    return {
        .cell_size      = DEFAULT_CELL_SIZE,
        .rules          = {
            .max_slope    = (float)math::PI * 0.5f,
            .min_altitude = -float::max,
            .max_altitude = float::max,
            .min_scale    = 1,
            .max_scale    = 1,
            .min_tint     = { 1, 1, 1 },
            .max_tint     = { 1, 1, 1 },
        },
        .sway           = {
            .amplitude       = 0.15f,
            .full_bend_speed = 12,
            .frequency       = 0.8f,
            .lean            = 0.3f,
            .wavelength      = 6,
            .variation       = 0.25f,
        },
        .fade           = DEFAULT_FADE,
        .receive_shadow = true,
    };
}

<*
 Register foliage components and their removal hooks.
 @param [&inout] scene : "Gains the Foliage and FoliageRuntime stores."
 @return? c3d::CAPACITY_EXCEEDED
*>
fn void? register_foliage(Scene* scene) {
    scene.register(Foliage)!;
    scene.register(FoliageRuntime)!;
    scene.set_remove_hook(Foliage, &remove_authoring, scene.hook_allocator);
    scene.set_remove_hook(FoliageRuntime, &remove_runtime, null);
}

<*
 Attach a layer to the node and scatter its cells over the ground.
 @param [&inout] scene : "Registered with register_foliage; world matrices current."
 @param [&in] assets
 @param [&inout] node : "Places the grid; its cells become children with its layers."
 @return? terrain::NOT_PREPARED
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::CAPACITY_EXCEEDED
 @require scene.world.is_registered(FoliageRuntime), !scene.has(node, Foliage)
 @require terrain::upright_rigid(node.world) : "Translation and rotation about Y."
*>
fn void? add_foliage(
    Scene* scene,
    AssetStore* assets,
    Node* node,
    FoliageDesc desc,
) {
    attach_foliage(
        scene: scene,
        assets: assets,
        node: node,
        desc: desc,
    )!;
    defer catch scene.remove_component(node, Foliage);
    return prepare(scene, assets, node);
}

<*
 Attach validated foliage authoring and copy its optional LOD description.
 @param [&inout] scene : "Registered with register_foliage."
 @param [&in] assets : "Resolves authored references; unchanged."
 @param [&in] node : "Receives the pending foliage component."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::CAPACITY_EXCEEDED
 @require scene.world.is_registered(FoliageRuntime), !scene.has(node, Foliage)
*>
fn void? attach_foliage(
    Scene* scene,
    AssetStore* assets,
    Node* node,
    FoliageDesc desc,
) {
    check_authoring(scene, assets, &desc)!;
    if (desc.lod) desc.lod = copy_lod_desc(scene.allocator, desc.lod)!;
    scene.add(node, (Foliage){ .desc = desc });
}

<*
 Whether the separate foliage runtime component is present.
 @param [&in] scene : "Contains authoring and optional runtime components."
 @param [&in] node : "Carries Foliage."
 @require scene.has(node, Foliage)
*>
fn bool is_prepared(Scene* scene, Node* node) => scene.has(node, FoliageRuntime);

<*
 Prepare pending foliage atomically; prepared foliage is unchanged.
 @param [&inout] scene : "Ground terrain prepared; world matrices current."
 @param [&in] assets : "Resolves authored references; unchanged."
 @param [&in] node : "Carries Foliage."
 @return? terrain::NOT_PREPARED
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::CAPACITY_EXCEEDED
 @require scene.has(node, Foliage)
 @require terrain::upright_rigid(node.world) : "Translation and rotation about Y."
*>
fn void? prepare(Scene* scene, AssetStore* assets, Node* node) {
    if (is_prepared(scene, node)) return;
    FoliageDesc desc = scene.get(node, Foliage).desc;
    check_authoring(scene, assets, &desc)!;
    if (!terrain::is_prepared(scene, scene.node(desc.ground))) return terrain::NOT_PREPARED~;
    ScatterFrame frame = scatter_frame(
        scene:  scene,
        assets: assets,
        node:   node,
        desc:   &desc,
    )!;
    uint cells_per_side = (uint)math::ceil(frame.extent / desc.cell_size);
    if (cells_per_side > MAX_CELLS_PER_SIDE) return c3d::INVALID_ARGUMENT~;

    ScatterInputs inputs = current_inputs(
        scene:  scene,
        assets: assets,
        node:   node,
        desc:   &desc,
    )!;
    FoliageRuntime runtime = create_runtime(scene.allocator, cells_per_side, desc)!;
    defer catch free_runtime(&runtime);
    runtime.sway = layer_sway(desc.sway, {});
    rescatter(
        scene:   scene,
        assets:  assets,
        node:    node,
        desc:    &desc,
        frame:   &frame,
        runtime: &runtime,
    )!;
    runtime.placed = inputs;

    scene.add(node, runtime);
}

<*
 Prepare every pending foliage in a subtree, retaining successful owners.
 @param [&inout] scene : "Registered; prepared owners remain unchanged."
 @param [&in] assets : "Resolves authored references; unchanged."
 @param [in] root : "Null selects the scene root; root is included."
 @return? terrain::NOT_PREPARED
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED, c3d::UNSUPPORTED
*>
fn void? prepare_subtree(Scene* scene, AssetStore* assets, Node* root = null) {
    if (!root) root = scene.root;
    fault failure;
    scene.@each(Foliage; entity, owner) {
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
 Re-place changed layers, then write the wind into every cell.
 Invalidates InstancedMesh and FoliageRuntime pointers when cells or a Foliage were removed.
 @param [&inout] scene : "Terrains updated; pending foliage skipped; world matrices current."
 @param [&in] assets
 @param wind_velocity : "World metres per second; zero is calm."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::CAPACITY_EXCEEDED
 @require math::is_finite(wind_velocity.x) && math::is_finite(wind_velocity.y) && math::is_finite(wind_velocity.z)
*>
fn void? update(Scene* scene, AssetStore* assets, Vec3 wind_velocity) {
    remove_orphans(scene);
    fault failure;
    scene.@each(FoliageRuntime; entity, runtime) {
        Node* node = scene.node(entity);
        FoliageDesc* desc = &runtime.desc;
        runtime.placed_cells = 0;
        if (catch excuse = refresh_layer(
            scene:   scene,
            assets:  assets,
            node:    node,
            desc:    desc,
            runtime: runtime,
        )) {
            if (!failure) failure = excuse;
        }
        apply_wind(
            scene:         scene,
            runtime:       runtime,
            template:      desc.sway,
            wind_velocity: wind_velocity,
        );
    };
    if (failure) return failure~;
}

fn void? check_authoring(Scene* scene, AssetStore* assets, FoliageDesc* desc) @private {
    check_desc(desc)!;
    if (desc.lod) {
        scene::validate_lod_desc(assets, *desc.lod, LodMode.INSTANCED)!;
    } else if (!assets.geometries.is_live(desc.geometry) || !assets.materials.is_live(desc.material)) {
        return c3d::INVALID_ID~;
    }
    if (!scene.world.is_alive(desc.ground) || !scene.world.has(desc.ground, Terrain)) return c3d::INVALID_ID~;
    TerrainDesc* ground = &scene.world.get(desc.ground, Terrain).desc;
    TextureAsset* height_map = assets.textures.try_get(ground.height_map)!;
    terrain::check_height_map(height_map)!;
    float extent = (float)(height_map.desc.width - 1) * ground.cell_size;
    if (!(math::ceil(extent / desc.cell_size) <= MAX_CELLS_PER_SIDE)) return c3d::INVALID_ARGUMENT~;
    if (!assets.textures.is_live(desc.rules.density_map)) return c3d::INVALID_ID~;
    check_density_map(assets.textures.get(desc.rules.density_map))!;
}

fn LodDesc*? copy_lod_desc(Allocator allocator, LodDesc* desc) @private {
    sz levels_offset = mem::aligned_offset(LodDesc::size, LodLevel::alignment);
    sz parts_offset = mem::aligned_offset(levels_offset + (sz)desc.levels.len * LodLevel::size, LodPart::alignment);
    sz bytes = parts_offset + (sz)desc.parts.len * LodPart::size;
    char*? allocation = alloc::malloc_try(allocator, bytes);
    if (catch allocation) return c3d::CAPACITY_EXCEEDED~;
    LodDesc* copy = (LodDesc*)allocation;
    *copy = *desc;
    copy.levels = ((LodLevel*)(allocation + levels_offset))[:desc.levels.len];
    copy.parts = ((LodPart*)(allocation + parts_offset))[:desc.parts.len];
    copy.levels[..] = desc.levels[..];
    copy.parts[..] = desc.parts[..];
    return copy;
}

fn void remove_authoring(Entity entity, void* component, void* user) @private {
    alloc::free(*(Allocator*)user, ((Foliage*)component).desc.lod);
}

// Descs come from files as well as code, so every value check is a fault; negated so NaN faults too.
fn void? check_desc(FoliageDesc* desc) @private {
    ScatterRules* rules = &desc.rules;
    if (!(desc.cell_size > 0) || !(rules.spacing > 0)) return c3d::INVALID_ARGUMENT~;
    if (!(desc.cell_size / rules.spacing <= MAX_STRATA_PER_SIDE)) return c3d::INVALID_ARGUMENT~;
    if (rules.density_channel > 3) return c3d::INVALID_ARGUMENT~;
    if (!(rules.max_slope >= 0 && rules.max_slope <= (float)math::PI * 0.5f)) return c3d::INVALID_ARGUMENT~;
    if (!(rules.min_altitude <= rules.max_altitude)) return c3d::INVALID_ARGUMENT~;
    if (!(rules.min_scale > 0 && rules.min_scale <= rules.max_scale && math::is_finite(rules.max_scale))) {
        return c3d::INVALID_ARGUMENT~;
    }
    if (!is_finite_vec(rules.min_tint) || !is_finite_vec(rules.max_tint)) return c3d::INVALID_ARGUMENT~;
    SwayTemplate* sway = &desc.sway;
    if (!(sway.amplitude >= 0 && math::is_finite(sway.amplitude))) return c3d::INVALID_ARGUMENT~;
    if (!(sway.full_bend_speed > 0 && math::is_finite(sway.full_bend_speed))) return c3d::INVALID_ARGUMENT~;
    if (!(sway.frequency >= 0 && math::is_finite(sway.frequency))) return c3d::INVALID_ARGUMENT~;
    if (!(sway.lean >= 0 && sway.lean <= 1)) return c3d::INVALID_ARGUMENT~;
    if (!(sway.wavelength >= 0 && math::is_finite(sway.wavelength))) return c3d::INVALID_ARGUMENT~;
    if (!(sway.variation >= 0 && math::is_finite(sway.variation))) return c3d::INVALID_ARGUMENT~;
    InstanceFade fade = desc.fade;
    if (fade.end != 0 && !(fade.start >= 0 && fade.start < fade.end && math::is_finite(fade.end))) {
        return c3d::INVALID_ARGUMENT~;
    }
}

fn bool is_finite_vec(Vec3 value) @private {
    return math::is_finite(value.x) && math::is_finite(value.y) && math::is_finite(value.z);
}

fn void? refresh_layer(
    Scene* scene,
    AssetStore* assets,
    Node* node,
    FoliageDesc* desc,
    FoliageRuntime* runtime,
) @private {
    ScatterInputs current = current_inputs(
        scene:  scene,
        assets: assets,
        node:   node,
        desc:   desc,
    )!;
    ScatterInputs* placed = &runtime.placed;
    bool moved = current.layer_world != placed.layer_world || current.ground_world != placed.ground_world;
    if (moved || current.density_revision != placed.density_revision) {
        return rescatter_layer(
            scene:   scene,
            assets:  assets,
            node:    node,
            desc:    desc,
            runtime: runtime,
            current: current,
        );
    }
    if (placed.ground_revision == current.ground_revision) return;

    ScatterFrame frame = scatter_frame(
        scene:  scene,
        assets: assets,
        node:   node,
        desc:   desc,
    )!;
    TerrainRefresh refresh = scene.get(scene.node(desc.ground), TerrainRuntime).last_refresh;
    // Only the last refresh is kept: a layer that missed an earlier one re-places whole.
    CellRange range = placed.ground_revision == refresh.revision_before
      ? cells_meeting(&frame, runtime, refresh.rect)
      : whole_grid(runtime);
    place_cells(
        scene:   scene,
        frame:   &frame,
        runtime: runtime,
        range:   range,
    );
    placed.ground_revision = current.ground_revision;
}

// A count pass costs milliseconds, so a failed re-scatter waits for an input or the free node count to change.
fn void? rescatter_layer(
    Scene* scene,
    AssetStore* assets,
    Node* node,
    FoliageDesc* desc,
    FoliageRuntime* runtime,
    ScatterInputs current,
) @private {
    uint free_nodes = scene.world.entities.free_count;
    bool retried = same_inputs(current, runtime.rejected) && free_nodes == runtime.rejected_free_nodes;
    if (runtime.rejection && retried) return runtime.rejection~;
    if (catch excuse = rescatter_from(
        scene:   scene,
        assets:  assets,
        node:    node,
        desc:    desc,
        runtime: runtime,
    )) {
        runtime.rejection = excuse;
        runtime.rejected = current;
        runtime.rejected_free_nodes = free_nodes;
        return excuse~;
    }
    runtime.rejection = {};
    runtime.placed = current;
}

fn void? rescatter_from(
    Scene* scene,
    AssetStore* assets,
    Node* node,
    FoliageDesc* desc,
    FoliageRuntime* runtime,
) @private {
    ScatterFrame frame = scatter_frame(
        scene:  scene,
        assets: assets,
        node:   node,
        desc:   desc,
    )!;
    return rescatter(
        scene:   scene,
        assets:  assets,
        node:    node,
        desc:    desc,
        frame:   &frame,
        runtime: runtime,
    );
}

fn ScatterInputs? current_inputs(
    Scene* scene,
    AssetStore* assets,
    Node* node,
    FoliageDesc* desc,
) @private {
    if (!scene.world.is_alive(desc.ground) || !scene.world.has(desc.ground, TerrainRuntime)) {
        return c3d::INVALID_ID~;
    }
    if (!assets.textures.is_live(desc.rules.density_map)) return c3d::INVALID_ID~;
    Node* ground = scene.node(desc.ground);
    return {
        .layer_world      = node.world,
        .ground_world     = ground.world,
        .ground_revision  = scene.get(ground, TerrainRuntime).last_refresh.revision_after,
        .density_revision = assets.textures.get(desc.rules.density_map).header.revision,
    };
}

fn bool same_inputs(ScatterInputs first, ScatterInputs second) @private {
    return first.layer_world == second.layer_world && first.ground_world == second.ground_world
      && first.ground_revision == second.ground_revision && first.density_revision == second.density_revision;
}

fn InstanceSway layer_sway(SwayTemplate template, Vec3 wind_velocity) @private {
    float speed = wind_velocity.length();
    // A VERTEX_ALPHA layer keeps its weight when calm, so its vertex alpha never starts cutting the material.
    if (speed == 0 || template.amplitude == 0) return { .weight = template.weight };
    return {
        .direction  = wind_velocity / speed,
        .amplitude  = template.amplitude * math::min(speed / template.full_bend_speed, 1.0f),
        .frequency  = template.frequency,
        .lean       = template.lean,
        .wavelength = template.wavelength,
        .variation  = template.variation,
        .weight     = template.weight,
    };
}

fn void apply_wind(
    Scene* scene,
    FoliageRuntime* runtime,
    SwayTemplate template,
    Vec3 wind_velocity,
) @private {
    if (wind_velocity == runtime.wind_velocity) return;
    runtime.wind_velocity = wind_velocity;
    runtime.sway = layer_sway(template, wind_velocity);
    foreach (cell : runtime.cells) {
        if (!cell.generation) continue;
        if (runtime.desc.lod) {
            LodGroupState* state = scene.world.get(cell, LodGroup).state;
            LodEffects effects = state.effects;
            effects.sway = runtime.sway;
            scene.set_lod_effects(scene.node(cell), effects);
        } else {
            scene.world.get(cell, InstancedMesh).sway = runtime.sway;
        }
    }
}

// A hook runs inside the entity's removal: the cell nodes are gone when the layer node is removed.
fn void remove_runtime(Entity entity, void* component, void* user) @private {
    free_runtime((FoliageRuntime*)component);
}

// Hooks cannot remove sibling components or other nodes, so a runtime whose Foliage left is torn down here.
fn void remove_orphans(Scene* scene) @private {
    while (true) {
        Entity orphan;
        scene.@each(FoliageRuntime; entity, runtime) {
            if (!scene.world.has(entity, Foliage)) orphan = entity;
        };
        if (!orphan.generation) return;
        Node* node = scene.node(orphan);
        foreach (cell : scene.get(node, FoliageRuntime).cells) {
            if (cell.generation) scene.remove(scene.node(cell));
        }
        scene.remove_component(node, FoliageRuntime);
    }
}
