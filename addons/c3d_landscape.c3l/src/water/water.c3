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
 Fixed-point steps that invert the horizontal crest shift in a query.
*>
const uint WAVE_INVERSION_ITERATIONS = 3; // 1.0 mm calm, 6.7 mm choppy; about 110 ns per sample

<*
 Cells along one side of a built grid, at most.
*>
const uint MAX_GRID_CELLS = 512; // 263,169 vertices: 3.2 MB of positions, 6.3 MB of 32-bit indices past 254 cells

<*
 Metres between built grid vertices at the default.
*>
const float DEFAULT_CELL_SIZE = 1.25f; // 96 cells over a 120 m lake; waves down to 2.5 m stay unaliased

<*
 Turn of the second ripple scroll away from the first, in radians.
*>
const float RIPPLE_CROSS_ANGLE = 0.6f; // crossing scrolls never line up, so the ripples show no stripes

const Wave[2] CALM_WAVES @private = {
    { .amplitude = 0.12f, .wavelength = 6, .speed = 1.2f, .direction = { 1, 0 }, .steepness = 0.5f },
    { .amplitude = 0.07f, .wavelength = 3.5f, .speed = 0.9f, .direction = { 0.6f, 0.8f }, .steepness = 0.5f },
};

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
}

<*
 Authored water body of a node; edited through set_desc.
*>
struct Water {
    WaterDesc desc;
}

<*
 Checked desc, material, grid, mirror camera and clip plane of a water body, written by the library.
*>
struct WaterRuntime {
    WaterDesc      desc;              // checked preparation or set_desc snapshot; later Water edits never reach it
    MaterialId     material;          // owned; removed with the runtime
    GeometryId     grid;              // the built grid, shared per store key, or the desc's geometry
    Entity         mirror;            // root camera node; removed by update once the water is gone
    RenderTargetId reflection_target; // sampled by the material; zero is none
    Plane          clip_plane;        // world; the mirror view's ViewDesc.clip_plane
    Vec2           rest_min;          // node-local XZ of the rest surface
    Vec2           rest_max;
}

<*
 Marks a mirror camera node the library owns and names its water node.
*>
struct WaterMirror {
    Entity water;
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
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
 @require scene.world.is_registered(WaterRuntime)
 @require !scene.has(node, Mesh) && !scene.has(node, Water) && !scene.has(node, WaterRuntime)
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
 @require !scene.has(node, Mesh) && !scene.has(node, Water) && !scene.has(node, WaterRuntime)
*>
fn void? attach_water(
    Scene* scene,
    AssetStore* assets,
    Node* node,
    WaterDesc desc,
) {
    check_desc(assets, &desc)!;
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
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
 @require scene.has(node, Water)
*>
fn void? prepare(Scene* scene, AssetStore* assets, Node* node) {
    if (is_prepared(scene, node)) return;
    WaterDesc desc = scene.get(node, Water).desc;
    check_desc(assets, &desc)!;
    bool shader_created, grid_created;
    ShaderId shader = water_shader(assets, &shader_created)!;
    defer catch if (shader_created) assets.remove_shader(shader);
    GeometryId surface = desc.geometry;
    if (!surface.generation) {
        surface = water_grid(
            assets: assets,
            extent: desc.extent,
            cell_size: desc.cell_size,
            created: &grid_created,
        )!;
    }
    defer catch if (grid_created) assets.remove_geometry(surface);
    WaterParams params = pack_params(&desc, {});
    MaterialId owned = assets.add_material(material::custom(
        shader:      shader,
        param_block: material::@as_bytes(params),
        references:  { [RIPPLE_REFERENCE] = desc.ripples, [FOAM_REFERENCE] = desc.foam },
    ))!;
    defer catch assets.remove_material(owned);
    Node* mirror = scene.add_camera(MIRROR_PLACEHOLDER, name: "water_mirror")!;
    scene.add(mirror, (WaterMirror){ .water = node.id });

    Aabb rest = rest_bounds(assets, &desc);
    scene.add(node, (Mesh){
        .geometry            = surface,
        .material            = owned,
        .receive_shadow      = true,
        .has_bounds_override = true,
        .local_bounds        = drawn_bounds(rest, &desc),
    });
    scene.add(node, (WaterRuntime){
        .desc       = desc,
        .material   = owned,
        .grid       = surface,
        .mirror     = mirror.id,
        .clip_plane = mirror_clip_plane(node.world, total_amplitude(&desc)),
        .rest_min   = { rest.min.x, rest.min.z },
        .rest_max   = { rest.max.x, rest.max.z },
    });
}

<*
 Prepare every pending water in a subtree, retaining successful owners.
 @param [&inout] scene : "Registered; prepared owners remain unchanged."
 @param [&inout] assets : "Receives generated resources during preparation."
 @param [in] root : "Null selects the scene root; root is included."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
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
    check_desc(assets, &desc)!;
    WaterRuntime* runtime = scene.get(node, WaterRuntime);
    GeometryId surface = runtime.grid;
    if (!same_shape(&runtime.desc, &desc)) {
        surface = desc.geometry.generation ? desc.geometry : water_grid(assets, desc.extent, desc.cell_size)!;
    }

    MaterialAsset* record = assets.material(runtime.material);
    WaterParams* params = assets.@custom_params(runtime.material, WaterParams);
    *params = pack_params(&desc, *params);
    record.data.custom.references[RIPPLE_REFERENCE] = desc.ripples;
    record.data.custom.references[FOAM_REFERENCE] = desc.foam;
    assets.mark_material_dirty(runtime.material);

    Aabb rest = rest_bounds(assets, &desc);
    Mesh* mesh = scene.get(node, Mesh);
    mesh.geometry = surface;
    mesh.local_bounds = drawn_bounds(rest, &desc);
    runtime.grid = surface;
    runtime.rest_min = { rest.min.x, rest.min.z };
    runtime.rest_max = { rest.max.x, rest.max.z };
    runtime.desc = desc;
    scene.get(node, Water).desc = desc;
}

<*
 Point the material's planar reflection at a render target; zero removes it.
 @param [&inout] scene
 @param [&inout] assets : "The store given to register_water."
 @param [&in] node : "Carries a water body."
 @require scene.has(node, WaterRuntime)
*>
fn void set_reflection_target(
    Scene* scene,
    AssetStore* assets,
    Node* node,
    RenderTargetId target,
) {
    WaterRuntime* runtime = scene.get(node, WaterRuntime);
    TextureSlot* slot = &assets.material(runtime.material).data.custom.slots[REFLECTION_SLOT];
    slot.texture = target.generation ? { .kind = RENDER_TARGET, .target = target } : { .kind = ASSET };
    slot.sampler = asset::SAMPLER_LINEAR_CLAMP;
    assets.mark_material_dirty(runtime.material);
    runtime.reflection_target = target;
}

<*
 Place every mirror camera for the viewing camera and scroll the ripples with the wind.
 Invalidates Mesh and WaterRuntime pointers when a Water was removed.
 @param [&inout] scene : "World matrices current; pending water is skipped unchanged."
 @param [&inout] assets : "The store given to register_water."
 @param viewing_camera : "Root node carrying the Camera the mirrors reflect."
 @param wind_velocity : "World metres per second; zero is calm."
 @param time : "Seconds; the FrameInfo.time the frame renders with."
 @return? c3d::INVALID_ARGUMENT
 @require scene.world.is_alive(viewing_camera) && scene.world.has(viewing_camera, Camera)
 @require scene.node(viewing_camera).parent == scene.root : "Mirrors read the camera's local transform."
 @require math::is_finite(wind_velocity.x) && math::is_finite(wind_velocity.y) && math::is_finite(wind_velocity.z)
*>
fn void? update(
    Scene* scene,
    AssetStore* assets,
    Entity viewing_camera,
    Vec3 wind_velocity,
    double time,
) {
    remove_orphans(scene);
    Node* viewing = scene.node(viewing_camera);
    Camera camera = *scene.get(viewing, Camera);
    fault failure;
    scene.@each(WaterRuntime; entity, runtime) {
        Node* node = scene.node(entity);
        WaterDesc* desc = &runtime.desc;
        follow_wind(
            assets:        assets,
            node:          node,
            desc:          desc,
            runtime:       runtime,
            wind_velocity: wind_velocity,
            time:          time,
        );
        fault excuse = @catch(place_mirror(
            scene:   scene,
            node:    node,
            desc:    desc,
            runtime: runtime,
            viewing: viewing,
            camera:  camera,
        ));
        if (excuse && !failure) failure = excuse;
    };
    if (failure) return failure~;
}

// A hook runs inside the entity's removal: the node's other components may already be gone.
fn void remove_runtime(Entity entity, void* component, void* user) @private {
    WaterRuntime* runtime = component;
    AssetStore* assets = user;
    assets.remove_material(runtime.material);
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
        scene.remove_component(node, Mesh);
        scene.remove_component(node, WaterRuntime);
    }
    while (true) {
        Entity stray;
        scene.@each(WaterMirror; entity, mirror) {
            if (!mirror_owned(scene, entity, mirror.water)) stray = entity;
        };
        if (!stray.generation) return;
        scene.remove(scene.node(stray));
    }
}

fn bool mirror_owned(Scene* scene, Entity mirror, Entity water) @private {
    if (!scene.world.is_alive(water) || !scene.world.has(water, WaterRuntime)) return false;
    return c3d::same_id(scene.world.get(water, WaterRuntime).mirror, mirror);
}
