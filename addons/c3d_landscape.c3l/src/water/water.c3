module c3d::landscape::water;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::ecs;
import c3d::maths;
import c3d::material;
import c3d::scene;
import std::math;

<*
 Gerstner waves one water body sums, at most.
*>
const uint MAX_WAVES = 4; // 32 B and one vertex term each; mirrored as WATER_MAX_WAVES in landscape/water_waves.glsl

<*
 Horizontal step in metres under which a query's inversion stops.
*>
const float WATER_QUERY_TOLERANCE = 0.0001f; // metres: 0.1 mm, well under the 1 cm drawn-surface agreement; the loop's exit, a smaller value costs more steps

<*
 Fixed-point steps a query runs to invert the crest shift, at most.
*>
const uint MAX_INVERSION_ITERATIONS = 8; // the cost bound per query; a query stopped here reports its residual

<*
 Cells along one side of a built grid, at most.
*>
const uint MAX_GRID_CELLS = 512; // 263,169 vertices: 3.2 MB of positions, 6.3 MB of 32-bit indices past 254 cells

<*
 Mirror slots one water body holds, at most.
*>
const uint MAX_MIRRORS = 8; // one camera node and 8 B of runtime each; a renderer holds 8 views by default

<*
 Metres between built grid vertices at the default.
*>
const float DEFAULT_CELL_SIZE = 1.25f; // 96 cells over a 120 m lake; waves down to 2.5 m stay unaliased

<*
 Turn of the second ripple scroll away from the first, in radians.
*>
const float RIPPLE_CROSS_ANGLE = 0.6f; // crossing scrolls never line up, so the ripples show no stripes

<*
 Cells along one chunk edge of an ocean at every level.
*>
const uint OCEAN_CHUNK_CELLS = 64; // twin WATER_CHUNK_CELLS; smaller chunks shorten the finest reach, 4x the nodes

<*
 Chunks along one side of an ocean's finest level, at most.
*>
const uint MAX_OCEAN_CHUNKS = 1 << scene::MAX_QUADTREE_DEPTH; // 87,381 nodes: 4.9 MiB of records, 11 MiB on the device

<*
 Metres below the rest plane a water body reaches when the desc sets none.
*>
const float DEFAULT_WATER_DEPTH = 40; // ten default absorption distances: spends red, keeps green and blue

const Wave[2] CALM_WAVES @private = {
    { .amplitude = 0.12f, .wavelength = 6, .speed = 1.2f, .direction = { 1, 0 }, .steepness = 0.5f },
    { .amplitude = 0.07f, .wavelength = 3.5f, .speed = 0.9f, .direction = { 0.6f, 0.8f }, .steepness = 0.5f },
};

<*
 Surface a water body draws.
*>
enum WaterMode {
    BODY,  // one grid or application geometry; waves in the node's local space
    OCEAN, // a quadtree of chunks selected per view; waves anchored to the world
}

<*
 How a water body's surface is computed.
*>
enum WaterWaveModel {
    GERSTNER,  // WaterDesc.waves, evaluated in the vertex stage
    SPECTRAL,  // a wind sea's spectrum, evolved and transformed on the GPU by water_gpu::update
    SIMULATED, // a damped wave equation stepped on the CPU over the built grid's vertices
}

<*
 What update_mirror did to a mirror slot.
*>
enum MirrorState {
    PLACED, // the slot's camera reflects the viewing camera; render its view
    BELOW,  // the viewing camera is under the rest plane; the slot's camera draws nothing and its view is not needed
}

<*
 One directional Gerstner wave in the node's local XZ.
*>
struct Wave {
    float amplitude;  // metres
    float wavelength; // metres, crest to crest
    float speed;      // metres per second along direction
    Vec2  direction;  // unit
    float steepness;  // share of the largest horizontal crest shift; the mean over the waves stays below 1
}

<*
 A damped wave equation on the built grid's vertex lattice.
*>
struct WaterSimulation {
    float wave_speed; // metres per second; finite and positive
    float damping;    // 1/s: the decay rate of the surface's velocity; finite and positive
}

<*
 A spectrum of wave components, tiled across the surface.
*>
struct WaterSpectrum {
    uint  seed;       // initial amplitudes and phases
    float patch_size; // metres covered by one tile of the spectrum
    float choppiness; // horizontal displacement scale
}

<*
 Waves, rest surface, shading and references of one water body.
*>
struct WaterDesc {
    Wave[MAX_WAVES] waves;
    uint            wave_count;
    GeometryId      geometry;              // application rest surface, flat at y = 0; zero builds a grid
    float           extent;                // metres along each side of the built grid, centred on the node
    float           cell_size;             // metres between built grid vertices, at most
    Vec3            absorption_color;      // transmittance after absorption_distance metres, each in (0, 1]
    float           absorption_distance;   // metres
    Vec3            scatter_color;         // albedo of the water body under ambient and indirect light
    float           roughness;
    float           refraction_strength;   // screen uv per unit of normal tilt
    float           reflection_distortion; // screen uv per unit of normal tilt in the planar sample
    float           foam_depth;            // metres of water behind the surface under which shore foam shows
    float           foam_crest;            // crest factor in [0, 1) above which wave foam shows
    float           ripple_drift;          // ripple scroll in metres per second per metre per second of wind
    MaterialId      ripples;               // STANDARD, normal map only; zero draws the waves' normal alone
    MaterialId      foam;                  // STANDARD foam colour and roughness; zero shows no foam
    bool            march_reflections;     // screen-space march where the planar sample is missing
    uint            max_mirrors;           // mirror slots, one per viewing view, in [1, MAX_MIRRORS]
    uint            reflection_view_slot;  // view texture the material samples, below material::MAX_VIEW_TEXTURES
    bool            trace;                 // scene traces see the displaced surface, posed again every frame
    WaterMode       mode;                  // OCEAN builds its chunks: no geometry or trace
    float           depth;                 // metres below the rest plane the body reaches; finite and positive
    WaterWaveModel  wave_model;            // GERSTNER draws waves; SIMULATED steps simulation over the built grid
    WaterSimulation simulation;            // read by SIMULATED
    WaterSpectrum   spectrum;              // read by SPECTRAL
    Entity          ground;                // optional terrain node: SIMULATED cells it stands above are dry
}

<*
 Authored water body of a node; edited through set_desc.
*>
struct Water {
    WaterDesc desc;
}

<*
 Checked desc, material, grid, mirror cameras, medium node and clip plane of a water body, written by the library.
*>
struct WaterRuntime {
    WaterDesc           desc;           // checked preparation or set_desc snapshot; later Water edits never reach it
    MaterialId          material;       // owned; removed with the runtime
    GeometryId          grid;           // the built grid, shared per store key, or the desc's geometry
    Entity[MAX_MIRRORS] mirrors;        // root camera nodes by slot; zero where none stands
    Entity              medium_node;    // child of the body carrying its MediumVolume; owned, removed with the runtime
    Plane               clip_plane;     // world; the mirror views' ViewDesc.clip_plane
    Vec2                rest_min;       // node-local XZ of the rest surface
    Vec2                rest_max;
    SeaBlend            sea;            // the sea-state blend set_sea_state started; idle without one
    OceanState          ocean;          // zero for a BODY
    SimulationState*    simulation;     // owned; null unless the wave model is SIMULATED
    SpectralState*      spectral;       // owned; null unless the wave model is SPECTRAL
    float               spectral_bound; // metres: how far the twin may stand from the drawn surface; zero otherwise
}

<*
 Marks a mirror camera node the library owns and names its water node and slot.
*>
struct WaterMirror {
    Entity water;
    uint   slot;
}

<*
 Clear lake shading with two calm crossing waves; extent unset.
*>
fn WaterDesc default_water_desc() {
    return {
        .waves                 = { [0] = CALM_WAVES[0], [1] = CALM_WAVES[1] },
        .wave_count            = 2,
        .cell_size             = DEFAULT_CELL_SIZE,
        .absorption_color      = { 0.35f, 0.6f, 0.75f },
        .absorption_distance   = 4,
        .scatter_color         = { 0.02f, 0.08f, 0.1f },
        .roughness             = 0.05f,
        .refraction_strength   = 0.02f,
        .reflection_distortion = 0.05f,
        .foam_depth            = 0.4f,
        .foam_crest            = 0.5f,
        .ripple_drift          = 0.03f,
        .march_reflections     = true,
        .max_mirrors           = 1,
        .depth                 = DEFAULT_WATER_DEPTH,
        .simulation            = { .wave_speed = DEFAULT_WAVE_SPEED, .damping = DEFAULT_DAMPING },
        .spectrum              = {
            .seed       = DEFAULT_SPECTRUM_SEED,
            .patch_size = DEFAULT_PATCH_SIZE,
            .choppiness = DEFAULT_CHOPPINESS,
        },
    };
}

<*
 Register Water, WaterRuntime and WaterMirror and the runtime's remove hook.
 @param [&inout] scene : "Gains the three stores."
 @param [&inout] assets : "Loses each removed water body's material; outlives the scene."
 @return? c3d::CAPACITY_EXCEEDED
*>
fn void? register_water(Scene* scene, AssetStore* assets) {
    scene.register(Water)!;
    scene.register(WaterRuntime)!;
    scene.register(WaterMirror)!;
    scene.set_remove_hook(WaterRuntime, &remove_runtime, assets);
}

<*
 Attach a water body to the node: its mesh, material and mirror camera.
 @param [&inout] scene : "Registered with register_water."
 @param [&inout] assets : "The store given to register_water."
 @param [&in] node : "World matrix current; the mirror excludes its layers."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED, c3d::UNSUPPORTED
 @require scene.world.is_registered(WaterRuntime)
 @require !scene.has(node, Mesh) && !scene.has(node, InstancedMesh)
 @require !scene.has(node, Water) && !scene.has(node, WaterRuntime)
*>
fn void? add_water(
    Scene* scene,
    AssetStore* assets,
    Node* node,
    WaterDesc desc,
) {
    attach_water(
        scene: scene,
        assets: assets,
        node: node,
        desc: desc,
    )!;
    defer catch scene.remove_component(node, Water);
    return prepare(scene, assets, node);
}

<*
 Attach validated water authoring without generating draw resources.
 @param [&inout] scene : "Registered with register_water."
 @param [&in] assets : "Resolves authored references; unchanged."
 @param [&in] node : "Receives the pending water component."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT
 @require scene.world.is_registered(WaterRuntime)
 @require !scene.has(node, Mesh) && !scene.has(node, InstancedMesh)
 @require !scene.has(node, Water) && !scene.has(node, WaterRuntime)
*>
fn void? attach_water(
    Scene* scene,
    AssetStore* assets,
    Node* node,
    WaterDesc desc,
) {
    check_authoring(scene, assets, &desc)!;
    scene.add(node, (Water){ .desc = desc });
}

<*
 Whether the separate water runtime component is present.
 @param [&in] scene : "Contains authoring and optional runtime components."
 @param [&in] node : "Carries Water."
 @require scene.has(node, Water)
*>
fn bool is_prepared(Scene* scene, Node* node) => scene.has(node, WaterRuntime);

<*
 Prepare pending water atomically; prepared water is unchanged.
 @param [&inout] scene : "Registered; node world matrix current."
 @param [&inout] assets : "The store given to register_water."
 @param [&in] node : "Carries Water."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED, c3d::UNSUPPORTED
 @require scene.has(node, Water)
*>
fn void? prepare(Scene* scene, AssetStore* assets, Node* node) {
    if (is_prepared(scene, node)) return;
    WaterDesc desc = scene.get(node, Water).desc;
    check_authoring(scene, assets, &desc)!;
    $if !$feat(C3D_LANDSCAPE_GPU):
        if (desc.wave_model == WaterWaveModel.SPECTRAL) return c3d::UNSUPPORTED~;
    $endif

    bool shader_created, grid_created;
    ShaderId shader = water_shader(assets, &shader_created)!;
    defer catch if (shader_created) assets.remove_shader(shader);
    bool ocean = desc.mode == WaterMode.OCEAN;
    GeometryId surface = desc.geometry;
    if (ocean) {
        surface = ocean_chunk(assets, &grid_created)!;
    } else if (!surface.generation) {
        surface = water_grid(
            assets: assets,
            extent: desc.extent,
            cell_size: desc.cell_size,
            created: &grid_created,
        )!;
    }
    defer catch if (grid_created) assets.remove_geometry(surface);
    Aabb rest = rest_bounds(assets, &desc);
    SimulationState* simulation;
    if (desc.wave_model == WaterWaveModel.SIMULATED) simulation = create_simulation(assets, &desc)!;
    defer catch if (simulation) release_simulation(assets, simulation);
    SpectralState* spectral;
    if (desc.wave_model == WaterWaveModel.SPECTRAL) {
        spectral = create_spectral(assets, &desc, { rest.min.x, rest.min.z }, { rest.max.x, rest.max.z })!;
    }
    defer catch if (spectral) release_spectral(assets, spectral);
    float envelope = spectral ? spectral.envelope : 0;

    OceanState layout = ocean ? ocean_layout(&desc) : (OceanState){};
    WaterParams params = pack_params(&desc, {});
    if (ocean) {
        layout.anchor = ocean_anchor(scene, node);
        anchor_waves(
            waves:   params.waves[:desc.wave_count],
            inverse: maths::inverse_affine(node.world),
            delta:   layout.anchor,
        );
        params.previous = params.waves;
    }
    if (spectral) params.field_offset = field_offset(&desc, maths::inverse_affine(node.world), layout.anchor);
    TextureSlot[material::MAX_CUSTOM_TEXTURE_SLOTS] slots = material::CUSTOM_SLOTS_DEFAULT;
    slots[REFLECTION_SLOT] = reflection_slot(desc.reflection_view_slot);
    if (simulation) slots[SIMULATION_SLOT] = material::texture_slot(simulation.texture);
    if (spectral) {
        slots[SPECTRAL_DISPLACEMENT_SLOT] = field_slot(spectral.displacement);
        slots[SPECTRAL_SLOPE_SLOT] = field_slot(spectral.slope);
        slots[SPECTRAL_PREVIOUS_SLOT] = field_slot(spectral.previous);
    }
    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    common.double_sided = true;
    MaterialId owned = assets.add_material(material::custom(
        shader:      shader,
        param_block: material::@as_bytes(params),
        slots:       slots,
        references:  { [RIPPLE_REFERENCE] = desc.ripples, [FOAM_REFERENCE] = desc.foam },
        common:      common,
    ))!;
    defer catch assets.remove_material(owned);
    if (ocean) {
        add_ocean_batch(
            scene:    scene,
            node:     node,
            ocean:    &layout,
            desc:     &desc,
            surface:  surface,
            material: owned,
            envelope: envelope,
        )!;
    }
    defer catch if (ocean) scene.remove_component(node, InstancedMesh);
    Node* medium_node = scene.add_node(node, "water_medium")!;
    defer catch scene.remove(medium_node);
    Entity[MAX_MIRRORS] mirrors;
    add_mirrors(scene, node.id, mirrors[:desc.max_mirrors])!;

    if (!ocean) {
        scene.add(node, (Mesh){
            .geometry            = surface,
            .material            = owned,
            .receive_shadow      = true,
            .trace               = desc.trace,
            .has_bounds_override = true,
            .local_bounds        = drawn_bounds(rest, &desc, desc.waves[:desc.wave_count], envelope),
        });
    }
    scene.add(node, (WaterRuntime){
        .desc           = desc,
        .material       = owned,
        .grid           = surface,
        .mirrors        = mirrors,
        .medium_node    = medium_node.id,
        .rest_min       = { rest.min.x, rest.min.z },
        .rest_max       = { rest.max.x, rest.max.z },
        .ocean          = layout,
        .simulation     = simulation,
        .spectral       = spectral,
        .spectral_bound = spectral ? spectral.bound : 0,
    });
    WaterRuntime* runtime = scene.get(node, WaterRuntime);
    runtime.clip_plane = mirror_clip_plane(node.world, vertical_reach(runtime));
    if (simulation) {
        follow_ground(
            scene:   scene,
            assets:  assets,
            node:    node,
            runtime: runtime,
        );
    }
    write_medium(scene, node, runtime);
}

<*
 Prepare every pending water in a subtree, retaining successful owners.
 @param [&inout] scene : "Registered; prepared owners remain unchanged."
 @param [&inout] assets : "Receives generated resources during preparation."
 @param [in] root : "Null selects the scene root; root is included."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED, c3d::UNSUPPORTED
*>
fn void? prepare_subtree(Scene* scene, AssetStore* assets, Node* root = null) {
    if (!root) root = scene.root;
    fault failure;
    scene.@each(Water; entity, owner) {
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
 Replace a water body's desc; the grid is rebuilt only when its shape changed.
 Ends a running sea-state blend and writes the body's MediumVolume again.
 Invalidates Camera pointers when max_mirrors shrinks.
 An ocean keeps its mode, extent and cell size, and a simulated body its extent and cell size; remove and add the
 body to change them. No body changes its wave model.
 @param [&inout] scene
 @param [&inout] assets : "The store given to register_water."
 @param [&in] node : "Carries a water body."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
 @require scene.has(node, WaterRuntime)
*>
fn void? set_desc(
    Scene* scene,
    AssetStore* assets,
    Node* node,
    WaterDesc desc,
) {
    check_authoring(scene, assets, &desc)!;
    WaterRuntime* runtime = scene.get(node, WaterRuntime);
    bool ocean = runtime.desc.mode == WaterMode.OCEAN;
    bool fixed_grid = ocean || runtime.simulation || runtime.spectral;
    if (desc.mode != runtime.desc.mode || desc.wave_model != runtime.desc.wave_model) return c3d::INVALID_ARGUMENT~;
    if (runtime.spectral && !same_spectrum(&desc.spectrum, &runtime.desc.spectrum)) return c3d::INVALID_ARGUMENT~;
    if (fixed_grid && (desc.extent != runtime.desc.extent || desc.cell_size != runtime.desc.cell_size)) {
        return c3d::INVALID_ARGUMENT~;
    }

    GeometryId surface = runtime.grid;
    if (!ocean && !same_shape(&runtime.desc, &desc)) {
        surface = desc.geometry.generation ? desc.geometry : water_grid(assets, desc.extent, desc.cell_size)!;
    }

    for (uint slot = desc.max_mirrors; slot < runtime.desc.max_mirrors; slot++) {
        release_mirror(scene, node.id, slot);
    }

    MaterialAsset* record = assets.material(runtime.material);
    WaterParams* params = assets.@custom_params(runtime.material, WaterParams);
    WaterParams before = *params;
    OceanMove move = ocean_move(scene, node, runtime);
    if (move.moved) {
        anchor_waves(before.waves[:before.wave_count], move.inverse, move.delta);
        anchor_ripples(
            assets:  assets,
            runtime: runtime,
            params:  &before,
            move:    move,
        );
    }
    *params = pack_params(&desc, before);
    if (runtime.spectral && move.moved) {
        params.field_offset = field_offset(&desc, move.inverse, runtime.ocean.anchor);
    }
    if (ocean) {
        anchor_changed_waves(
            params:  params,
            before:  &before,
            inverse: maths::inverse_affine(node.world),
            anchor:  runtime.ocean.anchor,
        );
    }
    record.data.custom.references[RIPPLE_REFERENCE] = desc.ripples;
    record.data.custom.references[FOAM_REFERENCE] = desc.foam;
    record.data.custom.slots[REFLECTION_SLOT] = reflection_slot(desc.reflection_view_slot);
    assets.mark_material_dirty(runtime.material);

    Aabb rest = rest_bounds(assets, &desc);
    runtime.sea = {};
    runtime.grid = surface;
    runtime.rest_min = { rest.min.x, rest.min.z };
    runtime.rest_max = { rest.max.x, rest.max.z };
    runtime.desc = desc;
    scene.get(node, Water).desc = desc;
    write_medium(scene, node, runtime);
    if (ocean) {
        place_ocean_bounds(
            scene:    scene,
            node:     node,
            ocean:    &runtime.ocean,
            desc:     &runtime.desc,
            waves:    desc.waves[:desc.wave_count],
            envelope: spectral_envelope(runtime),
        );
        return;
    }

    Mesh* mesh = scene.get(node, Mesh);
    mesh.geometry = surface;
    mesh.trace = desc.trace;
    mesh.local_bounds = drawn_bounds(rest, &desc, desc.waves[:desc.wave_count], spectral_envelope(runtime));
}

<*
 Place one mirror slot's camera to reflect the viewing camera across the water's rest plane.
 Writes WaterRuntime.clip_plane; creates the slot's camera after release_mirror. A viewing camera under the rest
 plane leaves the clip plane and the camera's pose as they were and puts the camera on no layer.
 @param [&inout] scene : "World matrices current."
 @param body : "Node carrying prepared water."
 @param slot : "Mirror slot of the viewing view, below the body's max_mirrors."
 @param viewing_camera : "Root node carrying the Camera the mirror reflects."
 @return "BELOW when the viewing camera is under the rest plane."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
 @require !scene.world.is_alive(body) || !scene.world.has(body, WaterRuntime) || slot < scene.world.get(body, WaterRuntime).desc.max_mirrors
 @require !scene.world.is_alive(viewing_camera) || (scene.world.has(viewing_camera, Camera) && scene.node(viewing_camera).parent == scene.root)
*>
fn MirrorState? update_mirror(
    Scene* scene,
    Entity body,
    uint slot,
    Entity viewing_camera,
) {
    if (!scene.world.is_alive(body) || !scene.world.has(body, WaterRuntime)) return c3d::INVALID_ID~;
    if (!scene.world.is_alive(viewing_camera)) return c3d::INVALID_ID~;

    if (!scene.world.get(body, WaterRuntime).mirrors[slot].generation) {
        Entity mirror = add_mirror(scene, body, slot)!;
        scene.world.get(body, WaterRuntime).mirrors[slot] = mirror;
    }

    return place_mirror(
        scene:   scene,
        node:    scene.node(body),
        runtime: scene.world.get(body, WaterRuntime),
        slot:    slot,
        viewing: scene.node(viewing_camera),
    );
}

<*
 Free one mirror slot's camera.
 Invalidates Camera pointers.
 @param [&inout] scene
 @require slot < MAX_MIRRORS
*>
fn void release_mirror(Scene* scene, Entity body, uint slot) {
    if (!scene.world.is_alive(body) || !scene.world.has(body, WaterRuntime)) return;
    WaterRuntime* runtime = scene.world.get(body, WaterRuntime);
    Entity mirror = runtime.mirrors[slot];
    if (!mirror.generation) return;

    runtime.mirrors[slot] = {};
    scene.remove(scene.node(mirror));
}

<*
 Tear down removed water bodies, scroll the ripples with the wind, step simulations, advance sea-state blends and
 re-anchor oceans.
 Invalidates Mesh, InstancedMesh and WaterRuntime pointers when a Water was removed.
 @param [&inout] scene : "World matrices current; pending water is skipped unchanged."
 @param [&inout] assets : "The store given to register_water."
 @param wind_velocity : "World metres per second; zero is calm."
 @param time : "Seconds; the FrameInfo.time the frame renders with."
 @require math::is_finite(wind_velocity.x) && math::is_finite(wind_velocity.y) && math::is_finite(wind_velocity.z)
*>
fn void update(
    Scene* scene,
    AssetStore* assets,
    Vec3 wind_velocity,
    double time,
) {
    remove_orphans(scene);
    scene.@each(WaterRuntime; entity, runtime) {
        Node* node = scene.node(entity);
        follow_wind(
            assets:        assets,
            node:          node,
            desc:          &runtime.desc,
            runtime:       runtime,
            wind_velocity: wind_velocity,
            time:          time,
        );
        scene.node(runtime.medium_node).layers = node.layers;
        OceanMove move = ocean_move(scene, node, runtime);
        advance_sea(
            scene:   scene,
            assets:  assets,
            node:    node,
            runtime: runtime,
            time:    time,
            move:    move,
        );
        if (runtime.spectral) {
            advance_spectral(
                scene:   scene,
                assets:  assets,
                node:    node,
                runtime: runtime,
                time:    time,
                move:    move,
            );
        }
        if (runtime.simulation) {
            advance_simulation(
                scene:   scene,
                assets:  assets,
                node:    node,
                runtime: runtime,
                time:    time,
            );
        }
    };
}

// A hook runs inside the entity's removal: the node's other components may already be gone.
fn void remove_runtime(Entity entity, void* component, void* user) @private {
    WaterRuntime* runtime = component;
    AssetStore* assets = user;
    assets.remove_material(runtime.material);
    if (runtime.simulation) release_simulation(assets, runtime.simulation);
    if (runtime.spectral) release_spectral(assets, runtime.spectral);
}

// Hooks cannot remove a sibling component or another node, so orphans are torn down here.
fn void remove_orphans(Scene* scene) @private {
    while (true) {
        Entity orphan;
        scene.@each(WaterRuntime; entity, runtime) {
            if (!scene.world.has(entity, Water)) orphan = entity;
        };
        if (!orphan.generation) break;
        Node* node = scene.node(orphan);
        if (scene.get(node, WaterRuntime).desc.mode == WaterMode.OCEAN) {
            scene.remove_component(node, InstancedMesh);
        } else {
            scene.remove_component(node, Mesh);
        }
        Entity medium_node = scene.get(node, WaterRuntime).medium_node;
        if (scene.world.is_alive(medium_node)) scene.remove(scene.node(medium_node));
        scene.remove_component(node, WaterRuntime);
    }
    while (true) {
        Entity stray;
        scene.@each(WaterMirror; entity, mirror) {
            if (!mirror_owned(scene, entity, mirror)) stray = entity;
        };
        if (!stray.generation) return;
        scene.remove(scene.node(stray));
    }
}

fn bool mirror_owned(Scene* scene, Entity mirror, WaterMirror* owner) @private {
    if (!scene.world.is_alive(owner.water) || !scene.world.has(owner.water, WaterRuntime)) return false;
    return c3d::same_id(scene.world.get(owner.water, WaterRuntime).mirrors[owner.slot], mirror);
}
