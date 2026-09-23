module physics_components_example;

import std::io;
import std::math;
import std::math::quaternion;
import std::time;
import std::time::clock;
import c3d;
import c3d::asset;
import c3d::camera;
import c3d::debug;
import c3d::geometry;
import c3d::gui;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::model;
import c3d::physics;
import c3d::platform;
import c3d::render;
import c3d::scene;
import imgui;
import b3;

const uint  MAX_SPAWNED @local = 1024; // one node, one body and one draw per spawn; the spawn budget lever
const uint  STRESS_SIDE @local = 142;
const uint  STRESS_BODIES @local = STRESS_SIDE * STRESS_SIDE; // about 20 000 static bodies; the per-body pass measurement
const uint  LEVEL_NODES @local = 64;
const uint  SCENE_NODE_CAPACITY @local = MAX_SPAWNED + STRESS_BODIES + LEVEL_NODES;
const uint  TIMING_WINDOW @local = 60;
const float STRESS_SPACING @local = 1.5f;
const float STRESS_DEPTH @local = -60;
const float KILL_HEIGHT @local = -20;
const float LAUNCH_SPEED @local = 12;
const float SPAWN_DISTANCE @local = 2;
const float RAY_LENGTH @local = 200;
const float EXPLOSION_RADIUS @local = 4;
const float EXPLOSION_FALLOFF @local = 2;
const float EXPLOSION_IMPULSE @local = 6000; // newton seconds per square meter facing the blast; about 6 m/s on a crate
const float THRUST @local = 14000;         // newtons; above a crate's weight, so it climbs
const float CRATE_GROWTH @local = 1.5f;
const float LOW_GRAVITY @local = 1.62f;    // lunar, meters per second squared
const float CONVEYOR_SPEED @local = 3;
const float ICE_FRICTION @local = 0.02f;
const float GRIP_FRICTION @local = 1.2f;
const uint  ICE_SEGMENTS @local = 4;
const uint  BRIDGE_PLANKS @local = 6;
const Vec3  WIND_MIN @local = { -16, -1, -6 };
const Vec3  WIND_MAX @local = { -8, 8, 6 };
const Wind  GUST @local = { .velocity = { 0, 2, -10 }, .drag = 1, .lift = 0.2f, .max_speed = 12 };
const float FREE_LOOK_RADIANS_PER_PIXEL @local = 0.003f;
const float FREE_PITCH_LIMIT @local = 1.5f; // avoids the poles, where the up vector degenerates
const float FREE_SPEED @local = 8;
const float FREE_FAST_MULTIPLIER @local = 4;
const float FREE_SPEED_WHEEL_STEP @local = 1.25f;
const Vec3  CAMERA_START @local = { 0, 8, 22 };
const Vec2  PANEL_POSITION @local = { 16, 16 };
const Vec2  PANEL_SIZE @local = { 420, 520 };
const uint  WIND_COLOR @local = 0xFFFFC080;
const SurfaceMaterialId GROUND_SURFACE @local = (SurfaceMaterialId)1;
const SurfaceMaterialId CONVEYOR_SURFACE @local = (SurfaceMaterialId)2;
const SurfaceMaterialId ICE_SURFACE @local = (SurfaceMaterialId)3;
const SurfaceMaterialId GRIP_SURFACE @local = (SurfaceMaterialId)4;

struct FreeCamera @local {
    Vec3  position;
    float yaw;
    float pitch;
    float speed;
}

struct Spawned @local {
    Node*[MAX_SPAWNED] nodes;
    uint               count;
}

struct Timing @local {
    float[TIMING_WINDOW] milliseconds;
    uint                 cursor;
}

struct Controls @local {
    PhysicsDebugOptions draw;
    bool                spawn_crates;
    bool                low_gravity;
    bool                stress;
    bool                thruster;
    bool                release_crate;
    bool                grow_crate;
}

struct Level @local {
    GeometryId box_geometry;
    GeometryId crate_geometry;
    MaterialId box_material;
    MaterialId crate_material;
    Node*      camera_node;
    Node*      last_crate;
    Node*      thruster;
    Node*[]    stress_nodes;
    bool       crate_drawn;
    bool       crate_released;
}

struct Hover @local {
    Node*             node; // null when the cursor ray hits nothing
    SurfaceMaterialId surface;
}

struct LevelPart @local {
    String           name;
    Vec3             size;
    maths::Transform local;
    StandardParams   look;
}

fn Vec3 free_forward(FreeCamera* camera) @local {
    return {
        math::cos(camera.pitch) * math::sin(camera.yaw),
        math::sin(camera.pitch),
        math::cos(camera.pitch) * math::cos(camera.yaw),
    };
}

fn void apply_free_camera(
    FreeCamera* camera,
    Input* input,
    Node* camera_node,
    float delta_seconds,
) @local {
    if (!input.mouse_captured_by_gui) {
        if (input.button_down(platform::MouseButton.RIGHT)) {
            camera.yaw -= input.mouse_delta.x * FREE_LOOK_RADIANS_PER_PIXEL;
            camera.pitch = math::clamp(
                camera.pitch - input.mouse_delta.y * FREE_LOOK_RADIANS_PER_PIXEL,
                -FREE_PITCH_LIMIT,
                FREE_PITCH_LIMIT,
            );
        }
        if (input.wheel != 0) camera.speed *= math::pow(FREE_SPEED_WHEEL_STEP, input.wheel);
    }
    Vec3 forward = free_forward(camera);
    Vec3 up = { 0, 1, 0 };
    Vec3 right = forward.cross(up).normalize();
    if (!input.keyboard_captured_by_gui) {
        Vec3 direction;
        if (input.key_down(platform::Scancode.W)) direction += forward;
        if (input.key_down(platform::Scancode.S)) direction -= forward;
        if (input.key_down(platform::Scancode.D)) direction += right;
        if (input.key_down(platform::Scancode.A)) direction -= right;
        if (input.key_down(platform::Scancode.E)) direction += up;
        if (input.key_down(platform::Scancode.Q)) direction -= up;
        float speed = camera.speed * (input.key_down(platform::Scancode.LSHIFT) ? FREE_FAST_MULTIPLIER : 1);
        camera.position += direction * (speed * delta_seconds);
    }
    camera_node.local.position = camera.position;
    camera_node.local.rotation = maths::look_rotation(forward, up);
}

fn StandardParams look(Vec4 color, float roughness) @local {
    StandardParams params = material::STANDARD_PARAMS_DEFAULT;
    params.base_color = color;
    params.metallic = 0;
    params.roughness = roughness;
    return params;
}

fn maths::Transform placed(Vec3 position, float pitch = 0) @local {
    return {
        .position = position,
        .rotation = quaternion::from_axis_angle{float}({ 1, 0, 0 }, pitch),
        .scale    = { 1, 1, 1 },
    };
}

// The level is a model template, so its static bodies come from components added after instantiate.
fn ModelId? build_level_model(AssetStore* assets) @local {
    LevelPart[7] parts = {
        { .name = "floor", .size = { 40, 0, 40 }, .local = placed({ 0, 0, 0 }), .look = look({ 0.45f, 0.5f, 0.45f, 1 }, 0.9f) },
        { .name = "ramp", .size = { 6, 0.5f, 8 }, .local = placed({ 8, 1.2f, -6 }, 0.3f), .look = look({ 0.6f, 0.55f, 0.5f, 1 }, 0.8f) },
        { .name = "step_low", .size = { 4, 0.5f, 2 }, .local = placed({ -2, 0.25f, -10 }), .look = look({ 0.5f, 0.5f, 0.55f, 1 }, 0.8f) },
        { .name = "step_mid", .size = { 4, 1, 2 }, .local = placed({ -2, 0.5f, -12 }), .look = look({ 0.5f, 0.5f, 0.55f, 1 }, 0.8f) },
        { .name = "step_high", .size = { 4, 1.5f, 2 }, .local = placed({ -2, 0.75f, -14 }), .look = look({ 0.5f, 0.5f, 0.55f, 1 }, 0.8f) },
        { .name = "conveyor", .size = { 3, 0.2f, 12 }, .local = placed({ 2, 0.1f, 4 }), .look = look({ 0.15f, 0.15f, 0.18f, 1 }, 0.5f) },
        { .name = "ice", .size = { 8, 0, 8 }, .local = placed({ -12, 0.02f, 10 }), .look = look({ 0.7f, 0.85f, 1, 1 }, 0.1f) },
    };

    Allocator allocator = assets.allocator;
    NodeTemplate[] nodes = alloc::new_array(allocator, NodeTemplate, (sz)parts.len + 1);
    ModelMesh[] meshes = alloc::new_array(allocator, ModelMesh, (sz)parts.len);
    nodes[0] = {
        .parent  = -1,
        .name    = ((String)"level").copy(allocator),
        .local   = maths::TRANSFORM_IDENTITY,
        .layers  = scene::DEFAULT_LAYERS,
        .visible = true,
    };
    foreach (index, &part : parts) {
        GeometryId geometry;
        @pool() {
            Geometry shape = part.size.y == 0
                ? geometry::plane(tmem, part.size.x, part.size.z, ICE_SEGMENTS, ICE_SEGMENTS)
                : geometry::box(tmem, part.size.x, part.size.y, part.size.z);
            geometry = assets.add_geometry(&shape)!;
        };
        nodes[index + 1] = {
            .parent  = 0,
            .name    = part.name.copy(allocator),
            .local   = part.local,
            .layers  = scene::DEFAULT_LAYERS,
            .visible = true,
        };
        meshes[index] = {
            .node     = (uint)index + 1,
            .geometry = geometry,
            .material = assets.add_material(material::standard(part.look))!,
        };
    }
    ModelTemplate template = { .nodes = nodes, .meshes = meshes };
    return assets.add_model_owned(&template, "physics_components/level");
}

fn Node*? find_child(Node* parent, String name) @local {
    for (Node* child = parent.first_child; child; child = child.next_sibling) {
        if (child.name == name) return child;
    }
    return c3d::INVALID_ARGUMENT~;
}

fn void? author_ice(Scene* scene, AssetStore* assets, Node* ice) @local {
    GeometryId geometry = scene.get(ice, scene::Mesh).geometry;
    uint triangle_count = assets.geometry(geometry).index_count / 3;
    @pool() {
        char[] indices = alloc::new_array(tmem, char, (sz)triangle_count);
        foreach (triangle, &index : indices) *index = (char)((triangle / 2) % ICE_SEGMENTS % 2);
        SurfaceMaterialDesc[2] faces = { physics::default_surface_material(), physics::default_surface_material() };
        faces[0].friction = ICE_FRICTION;
        faces[0].id = ICE_SURFACE;
        faces[1].friction = GRIP_FRICTION;
        faces[1].id = GRIP_SURFACE;
        ColliderDesc collider = physics::default_collider_desc(MESH);
        collider.geometry = geometry;
        collider.material_indices = indices;
        collider.face_materials = faces[..];
        scene.add_physics_body(ice, physics::default_body_desc(STATIC), (&collider)[:1])!;
    };
}

fn void? author_bridge(Scene* scene, Level* level) @local {
    Node* bridge = scene.add_node(name: "bridge")!;
    bridge.local.position = { 12, 1.5f, 10 };
    CompoundChild[BRIDGE_PLANKS + 2] children;
    for (uint plank = 0; plank < BRIDGE_PLANKS; plank++) {
        children[plank] = physics::default_compound_child(BOX);
        children[plank].half_extents = { 0.45f, 0.08f, 1 };
        children[plank].local.position = { plank - (BRIDGE_PLANKS - 1) * 0.5f, 0, 0 };
        Node* visual = scene.add_mesh(level.box_geometry, level.crate_material, bridge, "plank")!;
        visual.local.position = children[plank].local.position;
        visual.local.scale = children[plank].half_extents * 2;
    }
    foreach (post, x : (float[2]){ -3.2f, 3.2f }) {
        CompoundChild* child = &children[BRIDGE_PLANKS + post];
        *child = physics::default_compound_child(SPHERE);
        child.radius = 0.35f;
        child.local.position = { x, 0, 0 };
    }
    ColliderDesc collider = physics::default_collider_desc(COMPOUND);
    collider.children = children[..];
    scene.add_physics_body(bridge, physics::default_body_desc(STATIC), (&collider)[:1])!;
}

fn Level? build_level(AssetStore* assets, Scene* scene) @local {
    Level level;
    @pool() {
        Geometry box = geometry::box(tmem, 1, 1, 1);
        level.box_geometry = assets.add_geometry(&box, "physics_components/box")!;
        level.crate_geometry = assets.add_geometry(&box, "physics_components/crate")!;
    };
    level.box_material = assets.add_material(material::standard(look({ 0.85f, 0.55f, 0.2f, 1 }, 0.6f)))!;
    level.crate_material = assets.add_material(material::standard(look({ 0.55f, 0.4f, 0.25f, 1 }, 0.8f)))!;

    Node* root = model::instantiate(assets, scene, build_level_model(assets)!, name: "level")!;
    Node* sun = scene.add_light(light::directional({ 1, 0.95f, 0.85f }, 3), name: "sun")!;
    sun.local.rotation = maths::look_rotation(((Vec3){ -0.4f, -1, -0.3f }).normalize(), { 0, 1, 0 });
    scene.background = { .kind = COLOR, .color = { 0.55f, 0.7f, 0.9f, 1 } };
    level.camera_node = scene.add_camera(camera::perspective_deg(60, 0.1f), name: "camera")!;
    level.camera_node.local.position = CAMERA_START;
    scene.update_world();

    Node* level_root = root.first_child;
    author_ice(scene, assets, find_child(level_root, "ice")!)!;
    uint authored = scene.add_static_mesh_bodies(root);
    PhysicsBody* conveyor = scene.get(find_child(level_root, "conveyor")!, PhysicsBody);
    conveyor.colliders[0].material.tangent_velocity = { 0, 0, CONVEYOR_SPEED };
    conveyor.colliders[0].material.id = CONVEYOR_SURFACE;
    scene.get(find_child(level_root, "floor")!, PhysicsBody).colliders[0].material.id = GROUND_SURFACE;
    author_bridge(scene, &level)!;
    io::printfn("level: %d static mesh bodies authored before the world exists", authored + 1);
    return level;
}

fn void? spawn(
    Scene* scene,
    Level* level,
    Spawned* spawned,
    FreeCamera* camera,
    bool crate,
) @local {
    if (spawned.count == MAX_SPAWNED) return;
    Vec3 forward = free_forward(camera);
    GeometryId geometry = crate ? level.crate_geometry : level.box_geometry;
    MaterialId material = crate ? level.crate_material : level.box_material;
    Node* node = scene.add_mesh(geometry, material, name: crate ? "crate" : "box")!;
    node.local.position = camera.position + forward * SPAWN_DISTANCE;
    node.local.rotation = maths::look_rotation(forward, { 0, 1, 0 });

    BodyDesc body = physics::default_body_desc(DYNAMIC);
    body.linear_velocity = forward * LAUNCH_SPEED;
    if (crate) {
        ColliderDesc[3] colliders;
        colliders[0] = physics::default_collider_desc(HULL);
        colliders[0].geometry = level.crate_geometry;
        colliders[0].hit_events = true;
        colliders[1] = physics::default_collider_desc(SPHERE);
        colliders[1].radius = 0.2f;
        colliders[1].local.position = { -0.35f, -0.5f, 0 };
        colliders[2] = colliders[1];
        colliders[2].local.position = { 0.35f, -0.5f, 0 };
        scene.add_physics_body(node, body, colliders[..])!;
        level.last_crate = node;
    } else {
        ColliderDesc collider = physics::default_collider_desc(BOX);
        collider.half_extents = { 0.5f, 0.5f, 0.5f };
        collider.hit_events = true;
        scene.add_physics_body(node, body, (&collider)[:1])!;
    }
    spawned.nodes[spawned.count++] = node;
}

fn void cull_fallen(Scene* scene, Level* level, Spawned* spawned) @local {
    for (uint index = 0; index < spawned.count;) {
        Node* node = spawned.nodes[index];
        if (node.world_position().y > KILL_HEIGHT) {
            index++;
            continue;
        }
        if (node == level.last_crate) level.last_crate = null;
        if (node == level.thruster) level.thruster = null;
        scene.remove_later(node);
        spawned.nodes[index] = spawned.nodes[--spawned.count];
    }
}

fn void apply_wind_region(Scene* scene, Spawned* spawned, debug::DebugDraw* debug) @local {
    foreach (node : spawned.nodes[:spawned.count]) {
        Vec3 position = node.world_position();
        bool inside = position.x >= WIND_MIN.x && position.x <= WIND_MAX.x
            && position.y >= WIND_MIN.y && position.y <= WIND_MAX.y
            && position.z >= WIND_MIN.z && position.z <= WIND_MAX.z;
        bool blown = scene.has(node, Wind);
        if (inside && !blown) scene.add(node, GUST);
        if (!inside && blown) scene.remove_component(node, Wind);
    }
    debug.aabb({ .min = WIND_MIN, .max = WIND_MAX }, WIND_COLOR);
}

fn void toggle_stress(Scene* scene, Level* level, bool enable) @local {
    if (!enable) {
        foreach (node : level.stress_nodes) scene.remove(node);
        free(level.stress_nodes.ptr);
        level.stress_nodes = {};
        return;
    }
    level.stress_nodes = mem::new_array(Node*, STRESS_BODIES);
    ColliderDesc collider = physics::default_collider_desc(BOX);
    collider.half_extents = { 0.5f, 0.5f, 0.5f };
    float origin = -(float)STRESS_SIDE * STRESS_SPACING * 0.5f;
    foreach (index, &slot : level.stress_nodes) {
        Node* node = scene.add_node(name: "stress")!!;
        float column = (float)(index % STRESS_SIDE);
        float row = (float)(index / STRESS_SIDE);
        node.local.position = { origin + column * STRESS_SPACING, STRESS_DEPTH, origin + row * STRESS_SPACING };
        scene.add_physics_body(node, physics::default_body_desc(STATIC), (&collider)[:1])!!;
        *slot = node;
    }
}

fn void apply_controls(
    Scene* scene,
    AssetStore* assets,
    PhysicsWorld* physics,
    Level* level,
    Controls* controls,
) @local {
    if (controls.release_crate && level.crate_drawn && !level.crate_released) {
        assets.release_geometry_cpu(level.crate_geometry);
        level.crate_released = true;
    }
    if (controls.grow_crate && level.last_crate) {
        PhysicsBody* physics_body = scene.get(level.last_crate, PhysicsBody);
        physics_body.colliders[0].local.scale *= CRATE_GROWTH;
        level.last_crate.local.scale *= CRATE_GROWTH;
        physics_body.mark_changed();
    }

    Node* wanted = controls.thruster ? level.last_crate : null;
    if (wanted != level.thruster) {
        if (level.thruster) scene.remove_component(level.thruster, Force);
        if (wanted) scene.add(wanted, (Force){ .force = { 0, THRUST, 0 }, .local_point = { 0, 0.5f, 0 } });
        level.thruster = wanted;
    }

    bool low = physics.desc.tuning.gravity.y != physics::DEFAULT_GRAVITY.y;
    if (controls.low_gravity != low) {
        PhysicsTuning tuning = physics.desc.tuning;
        tuning.gravity = controls.low_gravity ? (Vec3){ 0, -LOW_GRAVITY, 0 } : physics::DEFAULT_GRAVITY;
        physics.set_tuning(tuning);
    }

    if (controls.stress != (level.stress_nodes.len > 0)) toggle_stress(scene, level, controls.stress);
}

fn void explode_under_cursor(
    Scene* scene,
    PhysicsWorld* physics,
    Level* level,
    Vec2 pixel,
    Vec2 viewport,
) @local {
    Ray ray = cursor_ray(scene, level, pixel, viewport);
    if (try hit = physics.raycast(ray.origin, ray.direction, RAY_LENGTH)) {
        ExplosionDesc explosion = physics::default_explosion_desc();
        explosion.position = hit.point + hit.normal * 0.2f;
        explosion.radius = EXPLOSION_RADIUS;
        explosion.falloff = EXPLOSION_FALLOFF;
        explosion.impulse_per_area = EXPLOSION_IMPULSE;
        if (catch excuse = physics.explode(explosion)) io::eprintfn("explode failed: %s", excuse);
    }
}

fn Ray cursor_ray(Scene* scene, Level* level, Vec2 pixel, Vec2 viewport) @local {
    camera::Camera* camera = scene.get(level.camera_node, camera::Camera);
    CameraMatrices matrices = camera::derive_matrices(*camera, level.camera_node.world, viewport);
    return camera::screen_to_ray(&matrices, pixel, viewport);
}

fn uint occupied_snapshots(PhysicsWorld* physics) @local {
    uint count;
    foreach (&slot : physics.snapshots.slots) {
        if (slot.generation % 2 == 1) count++;
    }
    return count;
}

fn float average_milliseconds(Timing* timing) @local {
    float sum;
    foreach (sample : timing.milliseconds) sum += sample;
    return sum / TIMING_WINDOW;
}

fn void draw_panel(
    PhysicsWorld* physics,
    Level* level,
    Controls* controls,
    Spawned* spawned,
    Timing* timing,
    Hover hover,
) @local {
    imgui::set_next_window_pos(PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
    imgui::set_next_window_size(PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
    if (imgui::begin("Physics components", null, {})) {
        imgui::text("Left click spawns, middle click explodes");
        imgui::text("Right drag looks, WASDQE move, wheel speed");
        imgui::checkbox("Spawn crates (HULL and two SPHERE feet)", &controls.spawn_crates);
        imgui::checkbox("Colliders", &controls.draw.colliders);
        imgui::checkbox("Contacts", &controls.draw.contacts);
        imgui::checkbox("Low gravity (set_tuning)", &controls.low_gravity);
        imgui::checkbox("Thruster on last crate (Force)", &controls.thruster);
        imgui::checkbox("20k static bodies", &controls.stress);
        controls.grow_crate = imgui::button("Grow last crate (mark_changed)");
        controls.release_crate = imgui::button("Release crate CPU geometry");
        imgui::separator();
        imgui::text("Spawned: %u / %u", spawned.count, MAX_SPAWNED);
        imgui::text("Crate geometry: %s", level.crate_released ? "CPU streams released" : "CPU streams resident");
        imgui::text("Occupied snapshots: %u", occupied_snapshots(physics));
        b3::Counters counters = physics.world.counters();
        imgui::text("Bodies: %d   awake: %d   contacts: %d", counters.body_count, physics.world.awake_body_count(), counters.contact_count);
        imgui::text("physics.update: %.3f ms (mean of %u frames)", average_milliseconds(timing), TIMING_WINDOW);
        imgui::text("Steps: %u   hits: %u   build failures: %u   dropped: %u",
            physics.steps_last_update, (uint)physics.hits().len, (uint)physics.build_failures().len, physics.dropped_events);
        if (hover.node) {
            imgui::text("Under cursor: %s, surface %d", hover.node.name, (ulong)hover.surface);
        } else {
            imgui::text("Under cursor: nothing");
        }
    }
    imgui::end();
}

fn void? draw_frame(
    render::Renderer* renderer,
    Scene* scene,
    Node* camera_node,
    GuiRenderer* gui_renderer,
    debug::DebugDraw* debug,
    FrameInfo info,
) @local {
    renderer.begin_frame(info)!;
    defer catch render::abort_frame(renderer);
    if (renderer.has_output) {
        renderer.render_view(scene, camera_node, renderer.default_view, debug)!;
        renderer.finish_view(renderer.default_view)!;
        OverlayContext overlay = renderer.begin_overlay()!;
        gui_renderer.record(&overlay)!;
        renderer.end_overlay(&overlay)!;
    }
    return renderer.end_frame();
}

fn void? run(
    platform::Window* window,
    render::Renderer* renderer,
    AssetStore* assets,
    Scene* scene,
    PhysicsWorld* physics,
    Level* level,
) @local {
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, renderer, window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);
    debug::DebugDraw debug = debug::create_debug_draw(mem);
    defer debug::destroy_debug_draw(&debug);
    defer {
        if (level.stress_nodes.len) toggle_stress(scene, level, false);
    }

    FreeCamera camera = { .position = CAMERA_START, .yaw = (float)math::PI, .speed = FREE_SPEED };
    Spawned* spawned = mem::new(Spawned);
    defer free(spawned);
    Timing timing;
    Controls controls = { .draw = { .colliders = true } };
    renderer.prepare_scene(scene)!;

    while (window.poll()) {
        Input* input = &window.input;
        if (input.key_released(platform::Scancode.ESCAPE) && !input.keyboard_captured_by_gui) break;
        float delta = window.clock.delta;
        Vec2 viewport = { renderer.output_width, renderer.output_height };
        gui_renderer.new_frame();
        defer {
            if (gui_renderer.frame_open) gui_renderer.finish_frame();
        }

        Hover hover;
        if (!input.mouse_captured_by_gui) {
            Ray ray = cursor_ray(scene, level, input.mouse_position, viewport);
            if (try hit = physics.raycast(ray.origin, ray.direction, RAY_LENGTH)) hover = { .node = hit.node, .surface = hit.surface };
            if (input.button_pressed(platform::MouseButton.LEFT)) {
                if (catch excuse = spawn(scene, level, spawned, &camera, controls.spawn_crates)) io::eprintfn("spawn failed: %s", excuse);
            }
            if (input.button_pressed(platform::MouseButton.MIDDLE)) {
                explode_under_cursor(
                    scene:    scene,
                    physics:  physics,
                    level:    level,
                    pixel:    input.mouse_position,
                    viewport: viewport,
                );
            }
        }
        draw_panel(
            physics:    physics,
            level:      level,
            controls:   &controls,
            spawned:    spawned,
            timing:     &timing,
            hover:      hover,
        );
        apply_controls(
            scene:    scene,
            assets:   assets,
            physics:  physics,
            level:    level,
            controls: &controls,
        );

        apply_free_camera(camera: &camera, input: input, camera_node: level.camera_node, delta_seconds: delta);
        debug.clear();
        apply_wind_region(scene, spawned, &debug);
        scene.update_world();
        time::Clock started = clock::now();
        physics.update(delta);
        timing.milliseconds[timing.cursor] = (float)(long)started.to_now() / 1_000_000;
        timing.cursor = (timing.cursor + 1) % TIMING_WINDOW;
        foreach (failure : physics.build_failures()) io::eprintfn("build failed for %s: %s", failure.node.name, failure.reason);
        cull_fallen(scene, level, spawned);
        scene.flush_removals();
        scene.update_world();

        physics.debug_draw(&debug, controls.draw);
        gui_renderer.finish_frame();

        platform::sync_window(window, renderer);
        draw_frame(
            renderer:     renderer,
            scene:        scene,
            camera_node:  level.camera_node,
            gui_renderer: &gui_renderer,
            debug:        &debug,
            info:         { .time = window.clock.total, .delta = window.clock.delta },
        )!;
        if (level.last_crate) level.crate_drawn = true;
    }
}

fn int main() {
    platform::Window window = platform::create_window(platform::default_window_desc("c3d physics components", 1280, 720))!!;
    defer platform::destroy_window(&window);

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      { .validation = true, .application_name = "c3d_physics_components" },
    )!!;
    defer render::destroy_renderer(&renderer);

    Scene scene = scene::create_scene(mem, { .max_nodes = SCENE_NODE_CAPACITY });
    defer scene::destroy_scene(&scene);
    physics::register_physics(&scene)!!;
    Level level = build_level(&assets, &scene)!!;

    PhysicsWorld physics = physics::create_physics_world(
        allocator: mem,
        assets:    &assets,
        scene:     &scene,
        desc:      physics::default_physics_desc(),
    )!!;
    defer physics::destroy_physics_world(&physics);

    if (catch excuse = run(
        window:   &window,
        renderer: &renderer,
        assets:   &assets,
        scene:    &scene,
        physics:  &physics,
        level:    &level,
    )) {
        io::eprintfn("physics components example failed: %s", excuse);
        return 1;
    }
    io::printfn("closed after %d frames, %.2fs", window.clock.frame, window.clock.total);
    return 0;
}
