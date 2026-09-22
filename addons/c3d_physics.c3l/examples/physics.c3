module physics_example;

import std::io;
import std::math;
import std::math::quaternion;
import c3d;
import c3d::asset;
import c3d::camera;
import c3d::debug;
import c3d::geometry;
import c3d::gui;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::physics;
import c3d::platform;
import c3d::render;
import c3d::scene;
import imgui;
import b3;

const uint  MAX_BOXES @local = 2048; // one node, one body and one draw per box; the scene and store capacity lever
const uint  SCENE_NODE_CAPACITY @local = MAX_BOXES + 16;
const uint  HIGHLIGHT_CAPACITY @local = 256; // boxes tinted per frame; contacts past it keep their material
const float GROUND_SIZE @local = 40;
const float RAMP_WIDTH @local = 8;
const float RAMP_HEIGHT @local = 0.5f;
const float RAMP_DEPTH @local = 6;
const float RAMP_ANGLE @local = 0.35f; // radians; steep enough to slide, shallow enough to stack on
const float PLATFORM_AMPLITUDE @local = 6;
const float PLATFORM_RATE @local = 0.5f;
const Vec3  PLATFORM_HOME @local = { 0, 1.5f, -6 };
const Vec3  PLATFORM_SIZE @local = { 4, 0.4f, 4 };
const float IMPULSE @local = 20;
const float RAY_LENGTH @local = 200;
const float SPAWN_DISTANCE @local = 2;
const float DEFAULT_SPAWN_RATE @local = 10;
const float DEFAULT_LAUNCH_SPEED @local = 15;
const float SPAWN_RATE_MIN @local = 1;
const float SPAWN_RATE_MAX @local = 60;
const float LAUNCH_SPEED_MAX @local = 40;
const float FREE_LOOK_RADIANS_PER_PIXEL @local = 0.003f;
const float FREE_PITCH_LIMIT @local = 1.5f; // avoids the poles, where the up vector degenerates
const float FREE_SPEED @local = 8;
const float FREE_FAST_MULTIPLIER @local = 4;
const float FREE_SPEED_WHEEL_STEP @local = 1.25f;
const Vec3  CAMERA_START @local = { 0, 6, 16 };
const Vec2  PANEL_POSITION @local = { 16, 16 };
const Vec2  PANEL_SIZE @local = { 360, 360 };
const Vec2  STATS_PANEL_POSITION @local = { 16, 392 };
const Vec2  STATS_PANEL_SIZE @local = { 360, 300 };

struct FreeCamera @local {
    Vec3  position;
    float yaw;
    float pitch;
    float speed;
}

struct BoxRing @local {
    Node*[MAX_BOXES] nodes;
    uint             count;
    float            spawn_accumulator;
}

struct Highlights @local {
    Node*[HIGHLIGHT_CAPACITY] nodes;
    uint                      count;
}

struct Controls @local {
    float               spawn_rate;
    float               launch_speed;
    PhysicsDebugOptions draw;
    bool                clear;
}

struct Level @local {
    GeometryId box_geometry;
    MaterialId box_material;
    MaterialId contact_material;
    Node*      ground;
    Node*      platform;
    Node*      camera_node;
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

fn void rotate_about_x(Geometry* geometry, float angle) @local {
    Quaternionf rotation = quaternion::from_axis_angle{float}({ 1, 0, 0 }, angle);
    foreach (&position : geometry.positions) *position = rotation.rotate_vec3(*position);
    foreach (&normal : geometry.normals) *normal = rotation.rotate_vec3(*normal);
}

fn void translate(Geometry* geometry, Vec3 offset) @local {
    foreach (&position : geometry.positions) *position += offset;
}

fn GeometryId build_level_geometry(AssetStore* assets) @local {
    GeometryId level;
    @pool() {
        Geometry[4] parts;
        parts[0] = geometry::plane(tmem, GROUND_SIZE, GROUND_SIZE);
        Vec3[3] ramp_offsets = { { -10, 1, 4 }, { 10, 1, -2 }, { 0, 1, -12 } };
        foreach (index, offset : ramp_offsets) {
            parts[index + 1] = geometry::box(tmem, RAMP_WIDTH, RAMP_HEIGHT, RAMP_DEPTH);
            rotate_about_x(&parts[index + 1], RAMP_ANGLE);
            translate(&parts[index + 1], offset);
        }
        Geometry merged = geometry::merge(tmem, parts[..]);
        merged.finalize();
        level = assets.add_geometry(&merged, "physics/level")!!;
    };
    return level;
}

fn Level? build_level(AssetStore* assets, Scene* scene, PhysicsWorld* physics) @local {
    Level level;
    GeometryId level_geometry = build_level_geometry(assets);
    @pool() {
        Geometry box = geometry::box(tmem, 1, 1, 1);
        level.box_geometry = assets.add_geometry(&box, "physics/box")!;
        Geometry platform = geometry::box(tmem, PLATFORM_SIZE.x, PLATFORM_SIZE.y, PLATFORM_SIZE.z);
        GeometryId platform_geometry = assets.add_geometry(&platform, "physics/platform")!;

        StandardParams ground_params = material::STANDARD_PARAMS_DEFAULT;
        ground_params.base_color = { 0.45f, 0.5f, 0.45f, 1 };
        ground_params.metallic = 0;
        ground_params.roughness = 0.9f;
        MaterialId ground_material = assets.add_material(material::standard(ground_params), "physics/ground_material")!;
        StandardParams box_params = material::STANDARD_PARAMS_DEFAULT;
        box_params.base_color = { 0.85f, 0.55f, 0.2f, 1 };
        box_params.metallic = 0;
        box_params.roughness = 0.6f;
        level.box_material = assets.add_material(material::standard(box_params), "physics/box_material")!;
        StandardParams contact_params = box_params;
        contact_params.base_color = { 0.9f, 0.15f, 0.15f, 1 };
        contact_params.emissive = { 0.6f, 0.05f, 0.05f };
        level.contact_material = assets.add_material(material::standard(contact_params), "physics/contact_material")!;
        StandardParams platform_params = box_params;
        platform_params.base_color = { 0.3f, 0.5f, 0.9f, 1 };
        MaterialId platform_material = assets.add_material(material::standard(platform_params), "physics/platform_material")!;

        level.ground = scene.add_mesh(level_geometry, ground_material, name: "level")!;
        level.platform = scene.add_mesh(platform_geometry, platform_material, name: "platform")!;
        level.platform.local.position = PLATFORM_HOME;
    };

    Node* sun = scene.add_light(light::directional({ 1, 0.95f, 0.85f }, 3), name: "sun")!;
    sun.local.rotation = maths::look_rotation(((Vec3){ -0.4f, -1, -0.3f }).normalize(), { 0, 1, 0 });
    scene.background = { .kind = COLOR, .color = { 0.55f, 0.7f, 0.9f, 1 } };
    level.camera_node = scene.add_camera(camera::perspective_deg(60, 0.1f), name: "camera")!;
    level.camera_node.local.position = CAMERA_START;
    scene.update_world();

    ColliderDesc level_collider = physics::default_collider_desc(MESH);
    level_collider.geometry = level_geometry;
    physics.add_body(level.ground, physics::default_body_desc(STATIC), (&level_collider)[:1])!;
    ColliderDesc platform_collider = physics::default_collider_desc(BOX);
    platform_collider.half_extents = PLATFORM_SIZE * 0.5f;
    physics.add_body(level.platform, physics::default_body_desc(KINEMATIC), (&platform_collider)[:1])!;
    return level;
}

fn void spawn_box(
    Scene* scene,
    PhysicsWorld* physics,
    Level* level,
    BoxRing* ring,
    FreeCamera* camera,
    float launch_speed,
) @local {
    if (ring.count == MAX_BOXES) return;
    Vec3 forward = free_forward(camera);
    Node*? added = scene.add_mesh(level.box_geometry, level.box_material, name: "box");
    if (catch added) return;
    Node* node = added;
    node.local.position = camera.position + forward * SPAWN_DISTANCE;
    node.local.rotation = maths::look_rotation(forward, { 0, 1, 0 });
    scene.update_world();

    ColliderDesc collider = physics::default_collider_desc(BOX);
    collider.half_extents = { 0.5f, 0.5f, 0.5f };
    collider.contact_events = true;
    collider.hit_events = true;
    BodyDesc body = physics::default_body_desc(DYNAMIC);
    body.linear_velocity = forward * launch_speed;
    if (catch excuse = physics.add_body(node, body, (&collider)[:1])) {
        io::eprintfn("add_body failed: %s", excuse);
        scene.remove(node);
        return;
    }
    ring.nodes[ring.count++] = node;
}

fn void clear_boxes(Scene* scene, BoxRing* ring, Highlights* highlights) @local {
    foreach (node : ring.nodes[:ring.count]) scene.remove(node);
    ring.count = 0;
    highlights.count = 0;
}

fn void apply_highlights(
    Scene* scene,
    PhysicsWorld* physics,
    Level* level,
    Highlights* highlights,
) @local {
    foreach (node : highlights.nodes[:highlights.count]) {
        if (scene.world.is_alive(node.id) && scene.has(node, scene::Mesh)) scene.get(node, scene::Mesh).material = level.box_material;
    }
    highlights.count = 0;
    foreach (contact : physics.contacts_begin()) {
        highlight(scene: scene, level: level, highlights: highlights, node: contact.a);
        highlight(scene: scene, level: level, highlights: highlights, node: contact.b);
    }
}

fn void highlight(
    Scene* scene,
    Level* level,
    Highlights* highlights,
    Node* node,
) @local {
    if (node == level.ground || node == level.platform || highlights.count == HIGHLIGHT_CAPACITY) return;
    scene.get(node, scene::Mesh).material = level.contact_material;
    highlights.nodes[highlights.count++] = node;
}

fn void push_under_cursor(
    Scene* scene,
    PhysicsWorld* physics,
    Level* level,
    Vec2 pixel,
    Vec2 viewport,
) @local {
    camera::Camera* camera = scene.get(level.camera_node, camera::Camera);
    CameraMatrices matrices = camera::derive_matrices(*camera, level.camera_node.world, viewport);
    Ray ray = camera::screen_to_ray(&matrices, pixel, viewport);
    if (try hit = physics.raycast(ray.origin, ray.direction, RAY_LENGTH)) {
        if (hit.node != level.ground && hit.node != level.platform) {
            physics.apply_impulse(hit.node, ray.direction * IMPULSE, hit.point);
        }
    }
}

fn void? draw_panel(
    render::Renderer* renderer,
    PhysicsWorld* physics,
    Controls* controls,
    BoxRing* ring,
    float delta_seconds,
) @local {
    imgui::set_next_window_pos(PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
    imgui::set_next_window_size(PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
    if (imgui::begin("Physics", null, {})) {
        imgui::text("Left click throws, hold to stream, middle click pushes");
        imgui::text("Right drag looks, WASDQE move, Shift fast, wheel speed");
        imgui::slider_float("Spawn rate", &controls.spawn_rate, SPAWN_RATE_MIN, SPAWN_RATE_MAX);
        imgui::slider_float("Launch speed", &controls.launch_speed, 0, LAUNCH_SPEED_MAX);
        imgui::checkbox("Colliders", &controls.draw.colliders);
        imgui::checkbox("Contacts", &controls.draw.contacts);
        imgui::checkbox("Bounds", &controls.draw.bounds);
        controls.clear = imgui::button("Clear");
        imgui::separator();
        b3::Counters counters = physics.world.counters();
        imgui::text("Boxes: %u / %u", ring.count, MAX_BOXES);
        imgui::text("Bodies: %d   awake: %d   contacts: %d", counters.body_count, physics.world.awake_body_count(), counters.contact_count);
        imgui::text("Steps: %u   alpha: %.2f", physics.steps_last_update, physics.alpha);
        imgui::text("Begin: %u   end: %u   hits: %u   dropped: %u",
            (uint)physics.contacts_begin().len, (uint)physics.contacts_end().len, (uint)physics.hits().len, physics.dropped_events);
        imgui::text("Frame: %.2f ms", delta_seconds * 1000);
    }
    imgui::end();

    imgui::set_next_window_pos(STATS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
    imgui::set_next_window_size(STATS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
    return gui::stats_panel(renderer);
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
) @local {
    Level level = build_level(assets, scene, physics)!;
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, renderer, window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);
    debug::DebugDraw debug = debug::create_debug_draw(mem);
    defer debug::destroy_debug_draw(&debug);

    FreeCamera camera = { .position = CAMERA_START, .yaw = (float)math::PI, .speed = FREE_SPEED };
    BoxRing* ring = mem::new(BoxRing);
    defer free(ring);
    Highlights highlights;
    Controls controls = {
        .spawn_rate   = DEFAULT_SPAWN_RATE,
        .launch_speed = DEFAULT_LAUNCH_SPEED,
        .draw         = { .colliders = true },
    };
    renderer.prepare_scene(scene)!;

    while (window.poll()) {
        Input* input = &window.input;
        if (input.key_released(platform::Scancode.ESCAPE) && !input.keyboard_captured_by_gui) break;
        float delta = window.clock.delta;
        gui_renderer.new_frame();
        defer {
            if (gui_renderer.frame_open) gui_renderer.finish_frame();
        }
        draw_panel(
            renderer:      renderer,
            physics:       physics,
            controls:      &controls,
            ring:          ring,
            delta_seconds: delta,
        )!;

        if (controls.clear) clear_boxes(scene, ring, &highlights);
        if (!input.mouse_captured_by_gui) {
            if (input.button_pressed(platform::MouseButton.LEFT)) {
                spawn_box(
                    scene:        scene,
                    physics:      physics,
                    level:        &level,
                    ring:         ring,
                    camera:       &camera,
                    launch_speed: controls.launch_speed,
                );
                ring.spawn_accumulator = 0;
            } else if (input.button_down(platform::MouseButton.LEFT)) {
                ring.spawn_accumulator += controls.spawn_rate * delta;
                while (ring.spawn_accumulator >= 1) {
                    spawn_box(
                        scene:        scene,
                        physics:      physics,
                        level:        &level,
                        ring:         ring,
                        camera:       &camera,
                        launch_speed: controls.launch_speed,
                    );
                    ring.spawn_accumulator -= 1;
                }
            }
            if (input.button_pressed(platform::MouseButton.MIDDLE)) {
                push_under_cursor(
                    scene:    scene,
                    physics:  physics,
                    level:    &level,
                    pixel:    input.mouse_position,
                    viewport: { renderer.output_width, renderer.output_height },
                );
            }
        }

        level.platform.local.position.x = PLATFORM_HOME.x + PLATFORM_AMPLITUDE * (float)math::sin(window.clock.total * PLATFORM_RATE);
        apply_free_camera(camera: &camera, input: input, camera_node: level.camera_node, delta_seconds: delta);
        scene.update_world();
        physics.update(delta);
        apply_highlights(scene: scene, physics: physics, level: &level, highlights: &highlights);
        scene.flush_removals();
        scene.update_world();

        debug.clear();
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
    }
}

fn int main() {
    platform::Window window = platform::create_window(platform::default_window_desc("c3d physics", 1280, 720))!!;
    defer platform::destroy_window(&window);

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      { .validation = true, .application_name = "c3d_physics" },
    )!!;
    defer render::destroy_renderer(&renderer);

    Scene scene = scene::create_scene(mem, { .max_nodes = SCENE_NODE_CAPACITY });
    defer scene::destroy_scene(&scene);

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
    )) {
        io::eprintfn("physics example failed: %s", excuse);
        return 1;
    }
    io::printfn("closed after %d frames, %.2fs", window.clock.frame, window.clock.total);
    return 0;
}
