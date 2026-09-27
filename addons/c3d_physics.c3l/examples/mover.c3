module mover_example;

import std::io;
import std::math;
import std::math::quaternion;
import c3d;
import c3d::asset;
import c3d::camera;
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

const uint  SCENE_NODE_CAPACITY @local = 64;
const float CAPSULE_RADIUS @local = 0.3f;
const float CAPSULE_HALF_HEIGHT @local = 0.5f;
const Vec3  SPAWN @local = { 0, 1.5f, 4 };
const uint  MOVER_ITERATIONS @local = 5; // collide, solve and cast passes per fixed step; each pass costs one plane gather and one sweep
const float MOVER_TOLERANCE @local = 0.01f; // metres; a pass that moves less ends the loop, trading a centimetre of drift for fewer sweeps
const float MAX_SPEED @local = 4; // metres per second on foot
const float SPRINT_MULTIPLIER @local = 1.5f;
const float ACCELERATE @local = 10; // fraction of max speed gained per second; lower feels heavier
const float FRICTION @local = 6; // per second; how quickly the capsule stops without input
const float STOP_SPEED @local = 1; // below it friction removes a fixed amount, so the capsule halts instead of creeping
const float MIN_SPEED @local = 0.1f; // horizontal speed snapped to zero; stops jitter at rest
const float JUMP_SPEED @local = 5; // about 1.3 m of rise under default gravity
const float MAX_SLOPE_DEGREES @local = 50; // a plane steeper than this is a wall and never grounds
const float PLANE_NORMAL_LENGTH @local = 0.25f;
const float LANDING_HEIGHT @local = 1.2f;
const Vec3  LANDING_HALF_EXTENTS @local = { 1.5f, 0.6f, 4 };
const float RAMP_HALF_THICKNESS @local = 0.1f;
const float RAMP_HALF_WIDTH @local = 1.5f;
const float WALKABLE_RAMP_DEGREES @local = 30;
const float STEEP_RAMP_DEGREES @local = 60;
const float STEEP_RAMP_HALF_LENGTH @local = 1.5f;
const Vec3  PLATFORM_SIZE @local = { 4, 0.4f, 4 };
const float PLATFORM_AMPLITUDE @local = 5; // metres; the platform's edge meets each landing at the ends of its swing
const float PLATFORM_RATE @local = 0.4f; // radians per second
const float ORBIT_RADIANS_PER_PIXEL @local = 0.005f;
const float ORBIT_PITCH_LIMIT @local = 1.5f; // avoids the poles, where the up vector degenerates
const float ORBIT_ZOOM_STEP @local = 0.9f;
const float ORBIT_DISTANCE @local = 8;
const float ORBIT_DISTANCE_MIN @local = 2;
const float ORBIT_DISTANCE_MAX @local = 30;
const Vec2  PANEL_POSITION @local = { 16, 16 };
const Vec2  PANEL_SIZE @local = { 360, 240 };
const Vec2  STATS_PANEL_POSITION @local = { 16, 272 };
const Vec2  STATS_PANEL_SIZE @local = { 360, 300 };
const uint  CAPSULE_COLOR @local = 0xFFFF8040;
const uint  PLANE_COLOR @local = 0xFF00FFFF;

struct Orbit @local {
    float distance;
    float yaw;
    float pitch;
}

struct Level @local {
    Node* platform;
    Node* capsule;
    Node* camera_node;
}

struct Mover @local {
    Scene*                                scene;
    Node*                                 node;
    Node*                                 platform;
    Vec3                                  previous;
    Vec3                                  current;
    Vec3                                  velocity;
    Vec3                                  forward;
    Vec3                                  right;
    Vec2                                  throttle;
    bool                                  sprint;
    bool                                  jump_requested;
    bool                                  grounded;
    Entity                                ground;
    float                                 platform_time;
    uint                                  iterations;
    MoverPlane[physics::MAX_MOVER_PLANES] planes;
    usz                                   plane_count;
}

fn MoverCapsule mover_capsule(Vec3 center) @local {
    return { .center = center, .half_height = CAPSULE_HALF_HEIGHT, .radius = CAPSULE_RADIUS };
}

fn Vec3 platform_position(float time) @local {
    return { PLATFORM_AMPLITUDE * (float)math::sin(time * PLATFORM_RATE), LANDING_HEIGHT - PLATFORM_SIZE.y * 0.5f, 0 };
}

fn void apply_friction(Mover* mover, float fixed_dt) @local {
    float speed = mover.velocity.length();
    if (speed < MIN_SPEED) {
        mover.velocity.x = 0;
        mover.velocity.z = 0;
        return;
    }
    float control = math::max(speed, STOP_SPEED);
    float remaining = math::max(0.0f, speed - control * FRICTION * fixed_dt);
    mover.velocity.x *= remaining / speed;
    mover.velocity.z *= remaining / speed;
}

fn void accelerate(Mover* mover, float fixed_dt) @local {
    float max_speed = mover.sprint ? MAX_SPEED * SPRINT_MULTIPLIER : MAX_SPEED;
    Vec3 desired = (mover.forward * mover.throttle.x + mover.right * mover.throttle.y) * max_speed;
    float desired_speed = desired.length();
    if (desired_speed == 0) return;
    Vec3 direction = desired / desired_speed;
    desired_speed = math::min(desired_speed, max_speed);

    float added = desired_speed - mover.velocity.dot(direction);
    if (added <= 0) return;
    mover.velocity += direction * math::min(ACCELERATE * max_speed * fixed_dt, added);
}

fn Vec3 ground_carry(Mover* mover, PhysicsWorld* world) @local {
    if (!mover.grounded || !mover.scene.world.is_alive(mover.ground)) return {};
    return world.point_velocity(mover.scene.node(mover.ground), mover.current) ?? (Vec3){};
}

fn float walkable_normal_y() @local => (float)math::cos(math::deg_to_rad(MAX_SLOPE_DEGREES));

// A steep plane solved as it is turns horizontal input into climbing; as a vertical wall it only blocks.
fn void flatten_steep_planes(Mover* mover) @local {
    float walkable = walkable_normal_y();
    foreach (&plane : mover.planes[:mover.plane_count]) {
        if (plane.normal.y <= 0 || plane.normal.y >= walkable) continue;
        Vec3 horizontal = { plane.normal.x, 0, plane.normal.z };
        float length = horizontal.length();
        plane.normal = horizontal / length;
        plane.offset /= length;
    }
}

fn void update_grounded(Mover* mover) @local {
    float walkable = walkable_normal_y();
    mover.grounded = false;
    mover.ground = {};
    foreach (&plane : mover.planes[:mover.plane_count]) {
        if (plane.normal.y < walkable) continue;
        mover.grounded = true;
        mover.ground = plane.entity;
    }
}

fn void step_mover(void* context, PhysicsWorld* world, float fixed_dt) @local {
    Mover* mover = context;
    mover.platform_time += fixed_dt;
    world.set_kinematic_target(mover.platform, platform_position(mover.platform_time), quaternion::IDENTITY)!!;

    mover.previous = mover.current;
    apply_friction(mover, fixed_dt);
    if (mover.grounded) mover.velocity.y = 0;
    accelerate(mover, fixed_dt);
    if (mover.jump_requested && mover.grounded) {
        mover.velocity.y = JUMP_SPEED;
        mover.grounded = false;
    }
    mover.jump_requested = false;
    mover.velocity += world.desc.tuning.gravity * fixed_dt;

    Vec3 target = mover.current + (mover.velocity + ground_carry(mover, world)) * fixed_dt;
    mover.iterations = 0;
    for (uint iteration = 0; iteration < MOVER_ITERATIONS; iteration++) {
        MoverCapsule capsule = mover_capsule(mover.current);
        mover.plane_count = world.collide_mover(capsule, mover.planes[..]);
        flatten_steep_planes(mover);
        MoverSolve solve = physics::solve_planes(target - mover.current, mover.planes[:mover.plane_count]);
        mover.iterations += solve.iterations;
        Vec3 delta = solve.delta * world.cast_mover(capsule, solve.delta);
        mover.current += delta;
        if (delta.length_sq() < MOVER_TOLERANCE * MOVER_TOLERANCE) break;
    }
    mover.velocity = physics::clip_vector(mover.velocity, mover.planes[:mover.plane_count]);
    update_grounded(mover);
}

fn void write_mover(void* context, PhysicsWorld* world, float alpha) @local {
    Mover* mover = context;
    mover.node.set_world_position(mover.previous + (mover.current - mover.previous) * alpha);
    RigidBody* platform = mover.scene.get(mover.platform, RigidBody);
    Vec3 from = platform.previous.position;
    mover.platform.set_world_position(from + (platform.current.position - from) * alpha);
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
        Geometry box = geometry::box(tmem, half_extents.x * 2, half_extents.y * 2, half_extents.z * 2);
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
    Vec3 center = low_end_top + (Vec3){ 0, half_length * (float)math::sin(angle), -half_length * (float)math::cos(angle) };
    center.y -= RAMP_HALF_THICKNESS * (float)math::cos(angle);
    center.z -= RAMP_HALF_THICKNESS * (float)math::sin(angle);
    return {
        .position = center,
        .rotation = quaternion::from_axis_angle{float}({ 1, 0, 0 }, angle),
        .scale    = { 1, 1, 1 },
    };
}

fn MaterialId add_material(AssetStore* assets, Vec4 color, String key) @local {
    StandardParams params = material::STANDARD_PARAMS_DEFAULT;
    params.base_color = color;
    params.metallic = 0;
    params.roughness = 0.8f;
    return assets.add_material(material::standard(params), key)!!;
}

fn Level build_level(AssetStore* assets, Scene* scene, PhysicsWorld* physics) @local {
    Level level;
    MaterialId ground = add_material(assets, { 0.45f, 0.5f, 0.45f, 1 }, "mover/ground");
    MaterialId stone = add_material(assets, { 0.6f, 0.6f, 0.62f, 1 }, "mover/stone");
    MaterialId steep = add_material(assets, { 0.8f, 0.35f, 0.3f, 1 }, "mover/steep");
    MaterialId moving = add_material(assets, { 0.3f, 0.5f, 0.9f, 1 }, "mover/platform");
    MaterialId character = add_material(assets, { 0.95f, 0.6f, 0.25f, 1 }, "mover/character");
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

    @pool() {
        Geometry platform = geometry::box(tmem, PLATFORM_SIZE.x, PLATFORM_SIZE.y, PLATFORM_SIZE.z);
        level.platform = scene.add_mesh(assets.add_geometry(&platform, "mover/platform_geometry")!!, moving, name: "platform")!!;
        Geometry capsule = geometry::capsule(tmem, CAPSULE_RADIUS, CAPSULE_HALF_HEIGHT * 2);
        level.capsule = scene.add_mesh(assets.add_geometry(&capsule, "mover/capsule_geometry")!!, character, name: "capsule")!!;
    };
    level.platform.local.position = platform_position(0);
    level.capsule.local.position = SPAWN;

    Node* sun = scene.add_light(light::directional({ 1, 0.95f, 0.85f }, 3), name: "sun")!!;
    sun.local.rotation = maths::look_rotation(((Vec3){ -0.4f, -1, -0.3f }).normalize(), { 0, 1, 0 });
    scene.background = { .kind = COLOR, .color = { 0.55f, 0.7f, 0.9f, 1 } };
    level.camera_node = scene.add_camera(camera::perspective_deg(60, 0.1f), name: "camera")!!;
    scene.update_world();

    ColliderDesc platform_collider = physics::default_collider_desc(BOX);
    platform_collider.half_extents = PLATFORM_SIZE * 0.5f;
    physics.add_body(level.platform, physics::default_body_desc(KINEMATIC), (&platform_collider)[:1])!!;
    return level;
}

fn void read_input(Mover* mover, Orbit* orbit, Input* input) @local {
    if (!input.mouse_captured_by_gui) {
        if (input.button_down(platform::MouseButton.RIGHT)) {
            orbit.yaw -= input.mouse_delta.x * ORBIT_RADIANS_PER_PIXEL;
            orbit.pitch = math::clamp(
                orbit.pitch + input.mouse_delta.y * ORBIT_RADIANS_PER_PIXEL,
                -ORBIT_PITCH_LIMIT,
                ORBIT_PITCH_LIMIT,
            );
        }
        if (input.wheel != 0) {
            orbit.distance = math::clamp(orbit.distance * math::pow(ORBIT_ZOOM_STEP, input.wheel), ORBIT_DISTANCE_MIN, ORBIT_DISTANCE_MAX);
        }
    }
    mover.forward = { -(float)math::sin(orbit.yaw), 0, -(float)math::cos(orbit.yaw) };
    mover.right = mover.forward.cross({ 0, 1, 0 });
    mover.throttle = {};
    if (input.keyboard_captured_by_gui) return;
    if (input.key_down(platform::Scancode.W)) mover.throttle.x += 1;
    if (input.key_down(platform::Scancode.S)) mover.throttle.x -= 1;
    if (input.key_down(platform::Scancode.D)) mover.throttle.y += 1;
    if (input.key_down(platform::Scancode.A)) mover.throttle.y -= 1;
    mover.sprint = input.key_down(platform::Scancode.LSHIFT);
    if (input.key_pressed(platform::Scancode.SPACE)) mover.jump_requested = true;
}

fn void follow(Orbit* orbit, Node* camera_node, Vec3 target) @local {
    Vec3 offset = {
        (float)math::cos(orbit.pitch) * (float)math::sin(orbit.yaw),
        (float)math::sin(orbit.pitch),
        (float)math::cos(orbit.pitch) * (float)math::cos(orbit.yaw),
    };
    camera_node.local.position = target + offset * orbit.distance;
    camera_node.local.rotation = maths::look_rotation(-offset, { 0, 1, 0 });
}

fn void draw_mover(Mover* mover, debug::DebugDraw* sink) @local {
    sink.capsule(mover.node.world_position(), { 0, 1, 0 }, CAPSULE_HALF_HEIGHT, CAPSULE_RADIUS, CAPSULE_COLOR);
    foreach (&plane : mover.planes[:mover.plane_count]) {
        sink.line(plane.point, plane.point + plane.normal * PLANE_NORMAL_LENGTH, PLANE_COLOR);
    }
}

fn void? draw_panel(render::Renderer* renderer, Mover* mover, float delta_seconds) @local {
    imgui::set_next_window_pos(PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
    imgui::set_next_window_size(PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
    if (imgui::begin("Mover", null, {})) {
        imgui::text("WASD move, Shift run, Space jump");
        imgui::text("Right drag orbits, wheel zooms");
        imgui::separator();
        String ground = "none";
        if (mover.grounded && mover.scene.world.is_alive(mover.ground)) ground = mover.scene.node(mover.ground).name;
        imgui::text("Grounded: %s   ground: %s", mover.grounded ? "yes" : "no", ground);
        Vec3 horizontal = { mover.velocity.x, 0, mover.velocity.z };
        imgui::text("Speed: %.2f m/s   vertical: %.2f m/s", horizontal.length(), mover.velocity.y);
        imgui::text("Planes: %d   solver passes: %u", (int)mover.plane_count, mover.iterations);
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
    Level level = build_level(assets, scene, physics);
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, renderer, window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);
    debug::DebugDraw debug = debug::create_debug_draw(mem);
    defer debug::destroy_debug_draw(&debug);

    Mover* mover = mem::new(Mover);
    defer free(mover);
    *mover = {
        .scene    = scene,
        .node     = level.capsule,
        .platform = level.platform,
        .previous = SPAWN,
        .current  = SPAWN,
    };
    physics.set_mover_pass({ .step = &step_mover, .write = &write_mover, .context = mover });
    defer physics.set_mover_pass({});
    Orbit orbit = { .distance = ORBIT_DISTANCE, .pitch = 0.4f };
    renderer.prepare_scene(scene)!;

    while (window.poll()) {
        Input* input = &window.input;
        if (input.key_released(platform::Scancode.ESCAPE) && !input.keyboard_captured_by_gui) break;
        float delta = window.clock.delta;
        gui_renderer.new_frame();
        defer {
            if (gui_renderer.frame_open) gui_renderer.finish_frame();
        }
        draw_panel(renderer, mover, delta)!;

        read_input(mover, &orbit, input);
        scene.update_world();
        physics.update(delta);
        scene.update_world();
        follow(&orbit, level.camera_node, level.capsule.world_position());
        scene.update_world();

        debug.clear();
        draw_mover(mover, &debug);
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
    platform::Window window = platform::create_window(platform::default_window_desc("c3d mover", 1280, 720))!!;
    defer platform::destroy_window(&window);

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      { .validation = true, .application_name = "c3d_mover" },
    )!!;
    defer render::destroy_renderer(&renderer);

    Scene scene = scene::create_scene(mem, { .max_nodes = SCENE_NODE_CAPACITY });
    defer scene::destroy_scene(&scene);
    physics::register_physics(&scene)!!;

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
        io::eprintfn("mover example failed: %s", excuse);
        return 1;
    }
    io::printfn("closed after %d frames, %.2fs", window.clock.frame, window.clock.total);
    return 0;
}
