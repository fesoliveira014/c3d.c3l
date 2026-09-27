module character_example;

import std::io;
import std::math;
import std::math::quaternion;
import c3d;
import c3d::asset;
import c3d::camera;
import c3d::character;
import c3d::debug;
import c3d::ecs;
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

const uint  MAX_THROWN_BOXES @local = 64; // one node, one body and one draw per box; the scene capacity lever
const uint  CRATE_COUNT @local = 4;
const uint  SCENE_NODE_CAPACITY @local = MAX_THROWN_BOXES + CRATE_COUNT + 32;
const Vec3  SPAWN @local = { 0, 1.5f, 4 };
const float WALK_SPEED @local = 4; // metres per second on foot
const float RUN_MULTIPLIER @local = 1.5f;
const float JUMP_SPEED @local = 5; // about 1.3 m of rise under default gravity
const ulong CRATE_CATEGORY @local = 2; // left out of the capsule's mask, so the push body shoves crates
const Vec3  CRATE_HALF_EXTENTS @local = { 0.4f, 0.4f, 0.4f };
const Vec3  CRATE_ROW_START @local = { -3, 0.4f, -1 };
const float CRATE_SPACING @local = 1.2f;
const float THROW_SPEED @local = 8;
const float THROW_OFFSET @local = 1; // metres ahead of the capsule center, clear of the capsule and the push body
const float THROW_LIFT @local = 0.5f;
const float LANDING_HEIGHT @local = 1.2f;
const Vec3  LANDING_HALF_EXTENTS @local = { 1.5f, 0.6f, 4 };
const float RAMP_HALF_THICKNESS @local = 0.1f;
const float RAMP_HALF_WIDTH @local = 1.5f;
const float WALKABLE_RAMP_DEGREES @local = 30;
const float STEEP_RAMP_DEGREES @local = 60;
const float STEEP_RAMP_HALF_LENGTH @local = 1.5f;
const uint  STAIR_STEPS @local = 3;
const float STAIR_RISE @local = 0.25f; // under the default 0.35 m step height
const float STAIR_TREAD @local = 0.5f;
const float STAIR_TOP_DEPTH @local = 2;
const float STAIR_HALF_WIDTH @local = 1.5f;
const Vec3  STAIR_FOOT @local = { 4.5f, 0, -3 }; // base of the first riser; the stair climbs toward -Z
const Vec3  PLATFORM_SIZE @local = { 4, 0.4f, 4 };
const float PLATFORM_AMPLITUDE @local = 5; // metres; the platform's edge meets each landing at the ends of its swing
const float PLATFORM_RATE @local = 0.4f; // radians per second
const float ORBIT_RADIANS_PER_PIXEL @local = 0.005f;
const float ORBIT_PITCH_LIMIT @local = 1.5f; // avoids the poles, where the up vector degenerates
const float ORBIT_PITCH @local = 0.4f;
const float ORBIT_ZOOM_STEP @local = 0.9f;
const float ORBIT_DISTANCE @local = 8;
const float ORBIT_DISTANCE_MIN @local = 2;
const float ORBIT_DISTANCE_MAX @local = 30;
const Vec2  PANEL_POSITION @local = { 16, 16 };
const Vec2  PANEL_SIZE @local = { 440, 280 };
const Vec2  STATS_PANEL_POSITION @local = { 16, 312 };
const Vec2  STATS_PANEL_SIZE @local = { 440, 300 };

struct Orbit @local {
    float distance;
    float yaw;
    float pitch;
}

struct Level @local {
    GeometryId crate_geometry;
    MaterialId crate_material;
    Node*      platform;
    Node*      player;
    Node*      camera_node;
}

struct ThrownBoxes @local {
    Node*[MAX_THROWN_BOXES] nodes;
    uint                    count;
}

struct Controls @local {
    CharacterDebugOptions character;
    PhysicsDebugOptions   physics;
}

fn Vec3 platform_position(double time) @local {
    return { PLATFORM_AMPLITUDE * (float)math::sin(time * PLATFORM_RATE), LANDING_HEIGHT - PLATFORM_SIZE.y * 0.5f, 0 };
}

fn MaterialId add_material(AssetStore* assets, Vec4 color, String key) @local {
    StandardParams params = material::STANDARD_PARAMS_DEFAULT;
    params.base_color = color;
    params.metallic = 0;
    params.roughness = 0.8f;
    return assets.add_material(material::standard(params), key)!!;
}

fn void add_static_box(
    Scene* scene,
    PhysicsWorld* physics,
    AssetStore* assets,
    MaterialId material,
    maths::Transform placement,
    Vec3 half_extents,
    String name,
) @local {
    GeometryId geometry;
    @pool() {
        Geometry box = geometry::box(
            allocator: tmem,
            width:     half_extents.x * 2,
            height:    half_extents.y * 2,
            depth:     half_extents.z * 2,
        );
        geometry = assets.add_geometry(&box)!!;
    };
    Node* node = scene.add_mesh(geometry, material, name: name)!!;
    node.local.position = placement.position;
    node.local.rotation = placement.rotation;
    scene.update_world();
    ColliderDesc collider = physics::default_collider_desc(BOX);
    collider.half_extents = half_extents;
    physics.add_body(node, physics::default_body_desc(STATIC), (&collider)[:1])!!;
}

fn maths::Transform ramp_placement(Vec3 low_end_top, float degrees, float half_length) @local {
    float angle = (float)math::deg_to_rad(degrees);
    Vec3 along = { 0, (float)math::sin(angle), -(float)math::cos(angle) };
    Vec3 center = low_end_top + along * half_length;
    center.y -= RAMP_HALF_THICKNESS * (float)math::cos(angle);
    center.z -= RAMP_HALF_THICKNESS * (float)math::sin(angle);
    return {
        .position = center,
        .rotation = quaternion::from_axis_angle{float}({ 1, 0, 0 }, angle),
        .scale    = { 1, 1, 1 },
    };
}

fn void add_stair(
    Scene* scene,
    PhysicsWorld* physics,
    AssetStore* assets,
    MaterialId material,
) @local {
    float front_z = STAIR_FOOT.z;
    for (uint step = 0; step < STAIR_STEPS; step++) {
        float depth = step == STAIR_STEPS - 1 ? STAIR_TOP_DEPTH : STAIR_TREAD;
        float top = STAIR_RISE * (float)(step + 1);
        maths::Transform placement = maths::TRANSFORM_IDENTITY;
        placement.position = { STAIR_FOOT.x, top * 0.5f, front_z - depth * 0.5f };
        add_static_box(
            scene:        scene,
            physics:      physics,
            assets:       assets,
            material:     material,
            placement:    placement,
            half_extents: { STAIR_HALF_WIDTH, top * 0.5f, depth * 0.5f },
            name:         "stair",
        );
        front_z -= depth;
    }
}

fn Node*? add_crate(
    Scene* scene,
    PhysicsWorld* physics,
    Level* level,
    Vec3 position,
    Vec3 velocity,
) @local {
    Node* node = scene.add_mesh(level.crate_geometry, level.crate_material, name: "crate")!;
    node.local.position = position;
    scene.update_world();
    ColliderDesc collider = physics::default_collider_desc(BOX);
    collider.half_extents = CRATE_HALF_EXTENTS;
    collider.filter.category = CRATE_CATEGORY;
    BodyDesc body = physics::default_body_desc(DYNAMIC);
    body.linear_velocity = velocity;
    physics.add_body(node, body, (&collider)[:1])!;
    return node;
}

fn Level build_level(AssetStore* assets, Scene* scene, PhysicsWorld* physics) @local {
    Level level;
    MaterialId ground = add_material(assets, { 0.45f, 0.5f, 0.45f, 1 }, "character/ground");
    MaterialId stone = add_material(assets, { 0.6f, 0.6f, 0.62f, 1 }, "character/stone");
    MaterialId steep = add_material(assets, { 0.8f, 0.35f, 0.3f, 1 }, "character/steep");
    MaterialId moving = add_material(assets, { 0.3f, 0.5f, 0.9f, 1 }, "character/platform");
    MaterialId player = add_material(assets, { 0.95f, 0.6f, 0.25f, 1 }, "character/player");
    level.crate_material = add_material(assets, { 0.7f, 0.5f, 0.3f, 1 }, "character/crate");
    maths::Transform placement = maths::TRANSFORM_IDENTITY;

    placement.position = { 0, -0.5f, 0 };
    add_static_box(
        scene:        scene,
        physics:      physics,
        assets:       assets,
        material:     ground,
        placement:    placement,
        half_extents: { 20, 0.5f, 20 },
        name:         "floor",
    );
    placement.position = { -8.5f, LANDING_HALF_EXTENTS.y, 2 };
    add_static_box(
        scene:        scene,
        physics:      physics,
        assets:       assets,
        material:     stone,
        placement:    placement,
        half_extents: LANDING_HALF_EXTENTS,
        name:         "west landing",
    );
    placement.position = { 8.5f, LANDING_HALF_EXTENTS.y, 2 };
    add_static_box(
        scene:        scene,
        physics:      physics,
        assets:       assets,
        material:     stone,
        placement:    placement,
        half_extents: LANDING_HALF_EXTENTS,
        name:         "east landing",
    );
    placement.position = { 0, 1.5f, 12 };
    add_static_box(
        scene:        scene,
        physics:      physics,
        assets:       assets,
        material:     stone,
        placement:    placement,
        half_extents: { 6, 1.5f, 0.25f },
        name:         "south wall",
    );
    placement.position = { 14, 1.5f, 8 };
    add_static_box(
        scene:        scene,
        physics:      physics,
        assets:       assets,
        material:     stone,
        placement:    placement,
        half_extents: { 0.25f, 1.5f, 6 },
        name:         "east wall",
    );

    float walkable_half_length = LANDING_HEIGHT / (2 * (float)math::sin(math::deg_to_rad(WALKABLE_RAMP_DEGREES)));
    float walkable_run = 2 * walkable_half_length * (float)math::cos(math::deg_to_rad(WALKABLE_RAMP_DEGREES));
    add_static_box(
        scene:        scene,
        physics:      physics,
        assets:       assets,
        material:     stone,
        placement:    ramp_placement({ -8.5f, 0, 6 + walkable_run }, WALKABLE_RAMP_DEGREES, walkable_half_length),
        half_extents: { RAMP_HALF_WIDTH, RAMP_HALF_THICKNESS, walkable_half_length },
        name:         "walkable ramp",
    );
    add_static_box(
        scene:        scene,
        physics:      physics,
        assets:       assets,
        material:     steep,
        placement:    ramp_placement({ 0, 0, -6 }, STEEP_RAMP_DEGREES, STEEP_RAMP_HALF_LENGTH),
        half_extents: { RAMP_HALF_WIDTH, RAMP_HALF_THICKNESS, STEEP_RAMP_HALF_LENGTH },
        name:         "steep ramp",
    );
    add_stair(
        scene:    scene,
        physics:  physics,
        assets:   assets,
        material: stone,
    );

    CharacterDesc desc = character::default_character_desc();
    @pool() {
        Geometry platform = geometry::box(
            allocator: tmem,
            width:     PLATFORM_SIZE.x,
            height:    PLATFORM_SIZE.y,
            depth:     PLATFORM_SIZE.z,
        );
        GeometryId platform_geometry = assets.add_geometry(&platform, "character/platform_geometry")!!;
        level.platform = scene.add_mesh(platform_geometry, moving, name: "platform")!!;
        Geometry capsule = geometry::capsule(tmem, desc.radius, desc.half_height * 2);
        GeometryId player_geometry = assets.add_geometry(&capsule, "character/player_geometry")!!;
        level.player = scene.add_mesh(player_geometry, player, name: "player")!!;
        Geometry crate = geometry::box(
            allocator: tmem,
            width:     CRATE_HALF_EXTENTS.x * 2,
            height:    CRATE_HALF_EXTENTS.y * 2,
            depth:     CRATE_HALF_EXTENTS.z * 2,
        );
        level.crate_geometry = assets.add_geometry(&crate, "character/crate_geometry")!!;
    };
    level.platform.local.position = platform_position(0);
    level.player.local.position = SPAWN;

    Node* sun = scene.add_light(light::directional({ 1, 0.95f, 0.85f }, 3), name: "sun")!!;
    sun.local.rotation = maths::look_rotation(((Vec3){ -0.4f, -1, -0.3f }).normalize(), { 0, 1, 0 });
    scene.background = { .kind = COLOR, .color = { 0.55f, 0.7f, 0.9f, 1 } };
    level.camera_node = scene.add_camera(camera::perspective_deg(60, 0.1f), name: "camera")!!;
    scene.update_world();

    ColliderDesc platform_collider = physics::default_collider_desc(BOX);
    platform_collider.half_extents = PLATFORM_SIZE * 0.5f;
    physics.add_body(level.platform, physics::default_body_desc(KINEMATIC), (&platform_collider)[:1])!!;
    for (uint index = 0; index < CRATE_COUNT; index++) {
        Vec3 position = CRATE_ROW_START + (Vec3){ 0, 0, -CRATE_SPACING * index };
        add_crate(
            scene:    scene,
            physics:  physics,
            level:    &level,
            position: position,
            velocity: {},
        )!!;
    }

    desc.push_bodies = true;
    desc.filter.mask = ~CRATE_CATEGORY;
    scene.add_character(level.player, desc)!!;
    return level;
}

fn Vec3 orbit_offset(Orbit* orbit) @local {
    return {
        (float)math::cos(orbit.pitch) * (float)math::sin(orbit.yaw),
        (float)math::sin(orbit.pitch),
        (float)math::cos(orbit.pitch) * (float)math::cos(orbit.yaw),
    };
}

fn void orbit_input(Orbit* orbit, Input* input) @local {
    if (input.mouse_captured_by_gui) return;
    if (input.button_down(platform::MouseButton.RIGHT)) {
        orbit.yaw -= input.mouse_delta.x * ORBIT_RADIANS_PER_PIXEL;
        orbit.pitch = math::clamp(
            orbit.pitch + input.mouse_delta.y * ORBIT_RADIANS_PER_PIXEL,
            -ORBIT_PITCH_LIMIT,
            ORBIT_PITCH_LIMIT,
        );
    }
    if (input.wheel != 0) {
        float zoomed = orbit.distance * math::pow(ORBIT_ZOOM_STEP, input.wheel);
        orbit.distance = math::clamp(zoomed, ORBIT_DISTANCE_MIN, ORBIT_DISTANCE_MAX);
    }
}

fn Vec3 desired_velocity(Orbit* orbit, Input* input) @local {
    if (input.keyboard_captured_by_gui) return {};
    Vec3 forward = { -(float)math::sin(orbit.yaw), 0, -(float)math::cos(orbit.yaw) };
    Vec3 right = forward.cross({ 0, 1, 0 });
    Vec3 direction;
    if (input.key_down(platform::Scancode.W)) direction += forward;
    if (input.key_down(platform::Scancode.S)) direction -= forward;
    if (input.key_down(platform::Scancode.D)) direction += right;
    if (input.key_down(platform::Scancode.A)) direction -= right;
    if (direction.length_sq() == 0) return {};
    float speed = input.key_down(platform::Scancode.LSHIFT) ? WALK_SPEED * RUN_MULTIPLIER : WALK_SPEED;
    return direction.normalize() * speed;
}

fn void throw_box(
    Scene* scene,
    PhysicsWorld* physics,
    Level* level,
    ThrownBoxes* thrown,
    Orbit* orbit,
) @local {
    if (thrown.count == MAX_THROWN_BOXES) return;
    Vec3 aim = -orbit_offset(orbit);
    Vec3 ahead = (Vec3){ aim.x, 0, aim.z }.normalize();
    Vec3 position = level.player.world_position() + ahead * THROW_OFFSET + (Vec3){ 0, THROW_LIFT, 0 };
    Node*? node = add_crate(
        scene:    scene,
        physics:  physics,
        level:    level,
        position: position,
        velocity: aim * THROW_SPEED,
    );
    if (catch excuse = node) {
        io::eprintfn("throw failed: %s", excuse);
        return;
    }
    thrown.nodes[thrown.count++] = node;
}

// The application moves the platform's node and the body follows one step later; showing the interpolated body pose
// keeps the platform in step with the interpolated character riding it.
fn void show_platform(Scene* scene, PhysicsWorld* physics, Node* platform) @local {
    RigidBody* body = scene.get(platform, RigidBody);
    float alpha = physics.desc.tuning.interpolate ? physics.alpha : 1;
    Vec3 from = body.previous.position;
    platform.set_world_position(from + (body.current.position - from) * alpha);
}

fn void follow(Orbit* orbit, Node* camera_node, Vec3 target) @local {
    Vec3 offset = orbit_offset(orbit);
    camera_node.local.position = target + offset * orbit.distance;
    camera_node.local.rotation = maths::look_rotation(-offset, { 0, 1, 0 });
}

fn void? draw_panel(
    render::Renderer* renderer,
    Scene* scene,
    CharacterSystem* system,
    Level* level,
    Controls* controls,
    float delta_seconds,
) @local {
    imgui::set_next_window_pos(PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
    imgui::set_next_window_size(PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
    if (imgui::begin("Character", null, {})) {
        imgui::text("WASD move, Shift run, Space jump");
        imgui::text("Right drag orbits, wheel zooms, left click throws a box");
        imgui::separator();
        Character* player = scene.get(level.player, Character);
        String ground = "none";
        if (player.grounded && scene.world.is_alive(player.ground)) ground = scene.node(player.ground).name;
        imgui::text("Grounded: %s   ground: %s", player.grounded ? "yes" : "no", ground);
        Vec3 horizontal = { player.velocity.x, 0, player.velocity.z };
        imgui::text("Speed: %.2f m/s   vertical: %.2f m/s", horizontal.length(), player.velocity.y);
        imgui::text("Character steps last update: %u", system.state.stepped);
        imgui::text("Frame: %.2f ms", delta_seconds * 1000);
        imgui::separator();
        imgui::checkbox("Capsules", &controls.character.capsules);
        imgui::checkbox("Planes", &controls.character.planes);
        imgui::checkbox("Ground normal", &controls.character.ground);
        imgui::checkbox("Colliders", &controls.physics.colliders);
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
        renderer.render_view(
            scene:       scene,
            camera_node: camera_node,
            view:        renderer.default_view,
            debug:       debug,
        )!;
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
    Level level = build_level(assets, scene, physics);
    CharacterSystem system = character::create_character_system(mem, physics, scene)!;
    defer character::destroy_character_system(&system);
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, renderer, window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);
    debug::DebugDraw debug = debug::create_debug_draw(mem);
    defer debug::destroy_debug_draw(&debug);

    ThrownBoxes* thrown = mem::new(ThrownBoxes);
    defer free(thrown);
    Orbit orbit = { .distance = ORBIT_DISTANCE, .pitch = ORBIT_PITCH };
    Controls controls = { .character = { .capsules = true, .ground = true } };
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
            scene:         scene,
            system:        &system,
            level:         &level,
            controls:      &controls,
            delta_seconds: delta,
        )!;

        orbit_input(&orbit, input);
        scene.move_character(level.player, desired_velocity(&orbit, input));
        if (!input.keyboard_captured_by_gui && input.key_pressed(platform::Scancode.SPACE)) {
            scene.jump_character(level.player, JUMP_SPEED);
        }
        if (!input.mouse_captured_by_gui && input.button_pressed(platform::MouseButton.LEFT)) {
            throw_box(
                scene:   scene,
                physics: physics,
                level:   &level,
                thrown:  thrown,
                orbit:   &orbit,
            );
        }
        level.platform.local.position = platform_position(window.clock.total);
        scene.update_world();
        physics.update(delta);
        show_platform(scene, physics, level.platform);
        scene.update_world();
        follow(&orbit, level.camera_node, level.player.world_position());
        scene.update_world();

        debug.clear();
        system.debug_draw(&debug, controls.character);
        physics.debug_draw(&debug, controls.physics);
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
    platform::Window window = platform::create_window(platform::default_window_desc("c3d character", 1280, 720))!!;
    defer platform::destroy_window(&window);

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      { .validation = true, .application_name = "c3d_character" },
    )!!;
    defer render::destroy_renderer(&renderer);

    Scene scene = scene::create_scene(mem, { .max_nodes = SCENE_NODE_CAPACITY });
    defer scene::destroy_scene(&scene);
    physics::register_physics(&scene)!!;
    character::register_character(&scene)!!;

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
        io::eprintfn("character example failed: %s", excuse);
        return 1;
    }
    io::printfn("closed after %d frames, %.2fs", window.clock.frame, window.clock.total);
    return 0;
}
