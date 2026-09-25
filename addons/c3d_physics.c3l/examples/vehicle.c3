module vehicle_example;

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

alias Quat @local = Quaternionf;

const uint  SCENE_NODE_CAPACITY @local = 64;
const uint  WHEEL_COUNT @local = 4;
const uint  FRONT_WHEELS @local = 2; // wheels 0 and 1 steer, 2 and 3 drive
const float GROUND_SIZE @local = 200;
const float RAMP_WIDTH @local = 8;
const float RAMP_HEIGHT @local = 0.5f;
const float RAMP_DEPTH @local = 6;
const float RAMP_ANGLE @local = 0.25f; // radians; shallow enough to drive up
const Vec3  CHASSIS_START @local = { 0, 1, 0 };
const Vec3  CHASSIS_HALF_EXTENTS @local = { 0.9f, 0.25f, 1.8f };
const float CHASSIS_DENSITY @local = 100; // about 320 kg; the acceleration lever against SPIN_TORQUE
const float WHEEL_RADIUS @local = 0.4f;
const float WHEEL_WIDTH @local = 0.3f;
const uint  WHEEL_SLICES @local = 12; // few enough facets that the spin shows
const float WHEEL_DENSITY @local = 50;
const float SUSPENSION_LOWER @local = -0.25f;
const float SUSPENSION_UPPER @local = 0.1f;
const float SPIN_SPEED @local = 15; // radians per second; about 22 km/h at this radius
const float SPIN_TORQUE @local = 300;
const float STEERING_ANGLE @local = 0.4f;
const float STEERING_LIMIT @local = 0.5f;
const float STEERING_TORQUE @local = 200;
const float STEERING_HERTZ @local = 5;
const float STEERING_DAMPING @local = 0.7f;
const Vec3  CAMERA_OFFSET @local = { 0, 4, -9 };
const Vec2  PANEL_POSITION @local = { 16, 16 };
const Vec2  PANEL_SIZE @local = { 360, 240 };
const Vec2  STATS_PANEL_POSITION @local = { 16, 272 };
const Vec2  STATS_PANEL_SIZE @local = { 360, 300 };

// Mount points in chassis space, front pair first.
const Vec3[WHEEL_COUNT] WHEEL_MOUNTS @local = {
    { 1.1f, -0.35f, 1.3f },
    { -1.1f, -0.35f, 1.3f },
    { 1.1f, -0.35f, -1.3f },
    { -1.1f, -0.35f, -1.3f },
};

struct Vehicle @local {
    Node*              chassis;
    Node*[WHEEL_COUNT] wheels;
    float              throttle;
    float              steering;
}

struct Level @local {
    Node* camera_node;
}

// Joint frame for every wheel: x up for the suspension, z along the axle for the spin.
fn Quat wheel_axes() @local {
    Vec3 diagonal = ((Vec3){ 1, 1, 1 }).normalize();
    return quaternion::from_axis_angle{float}(diagonal, (float)math::PI * 2 / 3);
}

fn Level? build_level(AssetStore* assets, Scene* scene, PhysicsWorld* physics) @local {
    GeometryId level_geometry;
    MaterialId ground_material;
    @pool() {
        Geometry[3] parts;
        parts[0] = geometry::plane(tmem, GROUND_SIZE, GROUND_SIZE);
        Vec3[2] ramp_offsets = { { -8, 0.9f, 14 }, { 8, 0.9f, 20 } };
        foreach (index, offset : ramp_offsets) {
            parts[index + 1] = geometry::box(
                allocator: tmem,
                width:     RAMP_WIDTH,
                height:    RAMP_HEIGHT,
                depth:     RAMP_DEPTH,
            );
            maths::Transform placement = {
                .position = offset,
                .rotation = quaternion::from_axis_angle{float}({ 1, 0, 0 }, -RAMP_ANGLE),
                .scale    = { 1, 1, 1 },
            };
            parts[index + 1].transform(placement.to_mat4());
        }
        Geometry merged = geometry::merge(tmem, parts[..]);
        merged.finalize();
        level_geometry = assets.add_geometry(&merged, "vehicle/level")!;
        StandardParams ground_params = material::STANDARD_PARAMS_DEFAULT;
        ground_params.base_color = { 0.45f, 0.5f, 0.45f, 1 };
        ground_params.metallic = 0;
        ground_params.roughness = 0.9f;
        ground_material = assets.add_material(material::standard(ground_params), "vehicle/ground_material")!;
    };

    Node* ground = scene.add_mesh(level_geometry, ground_material, name: "level")!;
    Node* sun = scene.add_light(light::directional({ 1, 0.95f, 0.85f }, 3), name: "sun")!;
    sun.local.rotation = maths::look_rotation(((Vec3){ -0.4f, -1, -0.3f }).normalize(), { 0, 1, 0 });
    scene.background = { .kind = COLOR, .color = { 0.55f, 0.7f, 0.9f, 1 } };
    Level level = { .camera_node = scene.add_camera(camera::perspective_deg(60, 0.1f), name: "camera")! };
    scene.update_world();

    ColliderDesc level_collider = physics::default_collider_desc(MESH);
    level_collider.geometry = level_geometry;
    physics.add_body(ground, physics::default_body_desc(STATIC), (&level_collider)[:1])!;
    return level;
}

fn Vehicle? build_vehicle(AssetStore* assets, Scene* scene) @local {
    Vehicle vehicle;
    @pool() {
        Geometry chassis_shape = geometry::box(
            allocator: tmem,
            width:     CHASSIS_HALF_EXTENTS.x * 2,
            height:    CHASSIS_HALF_EXTENTS.y * 2,
            depth:     CHASSIS_HALF_EXTENTS.z * 2,
        );
        GeometryId chassis_geometry = assets.add_geometry(&chassis_shape, "vehicle/chassis")!;
        Geometry wheel_shape = geometry::cylinder(
            allocator:     tmem,
            radius_top:    WHEEL_RADIUS,
            radius_bottom: WHEEL_RADIUS,
            height:        WHEEL_WIDTH,
            slices:        WHEEL_SLICES,
        );
        GeometryId wheel_geometry = assets.add_geometry(&wheel_shape, "vehicle/wheel")!;
        StandardParams chassis_params = material::STANDARD_PARAMS_DEFAULT;
        chassis_params.base_color = { 0.8f, 0.2f, 0.15f, 1 };
        chassis_params.roughness = 0.4f;
        MaterialId chassis_material = assets.add_material(material::standard(chassis_params), "vehicle/body_material")!;
        StandardParams wheel_params = material::STANDARD_PARAMS_DEFAULT;
        wheel_params.base_color = { 0.1f, 0.1f, 0.1f, 1 };
        wheel_params.metallic = 0;
        wheel_params.roughness = 0.9f;
        MaterialId wheel_material = assets.add_material(material::standard(wheel_params), "vehicle/wheel_material")!;

        vehicle.chassis = scene.add_mesh(chassis_geometry, chassis_material, name: "chassis")!;
        vehicle.chassis.local.position = CHASSIS_START;
        foreach (index, mount : WHEEL_MOUNTS) {
            Node* wheel = scene.add_node(name: "wheel")!;
            wheel.local.position = CHASSIS_START + mount;
            Node* tire = scene.add_mesh(
                geometry: wheel_geometry,
                material: wheel_material,
                parent:   wheel,
                name:     "tire",
            )!;
            tire.local.rotation = quaternion::from_axis_angle{float}({ 0, 0, 1 }, (float)math::PI / 2);
            vehicle.wheels[index] = wheel;
        }
    };
    scene.update_world();

    ColliderDesc chassis_collider = physics::default_collider_desc(BOX);
    chassis_collider.half_extents = CHASSIS_HALF_EXTENTS;
    chassis_collider.density = CHASSIS_DENSITY;
    scene.add_physics_body(vehicle.chassis, physics::default_body_desc(DYNAMIC), (&chassis_collider)[:1])!;

    ColliderDesc wheel_collider = physics::default_collider_desc(SPHERE);
    wheel_collider.radius = WHEEL_RADIUS;
    wheel_collider.density = WHEEL_DENSITY;
    Quat axes = wheel_axes();
    foreach (index, wheel : vehicle.wheels) {
        scene.add_physics_body(wheel, physics::default_body_desc(DYNAMIC), (&wheel_collider)[:1])!;
        JointDesc desc = physics::default_joint_desc(WHEEL, vehicle.chassis.id);
        desc.anchor_frame = { .position = WHEEL_MOUNTS[index], .rotation = axes, .scale = { 1, 1, 1 } };
        desc.frame = { .rotation = axes, .scale = { 1, 1, 1 } };
        desc.wheel.suspension_limit = { .enabled = true, .lower = SUSPENSION_LOWER, .upper = SUSPENSION_UPPER };
        if (index < FRONT_WHEELS) {
            desc.wheel.steering = { .enabled = true, .hertz = STEERING_HERTZ, .damping_ratio = STEERING_DAMPING };
            desc.wheel.max_steering_torque = STEERING_TORQUE;
            desc.wheel.steering_limit = { .enabled = true, .lower = -STEERING_LIMIT, .upper = STEERING_LIMIT };
        } else {
            desc.wheel.spin = { .enabled = false, .speed = 0, .max_force = SPIN_TORQUE };
        }
        scene.add_physics_joint(wheel, desc)!;
    }
    return vehicle;
}

fn void drive(
    Scene* scene,
    PhysicsWorld* physics,
    Vehicle* vehicle,
    Input* input,
) @local {
    float throttle;
    float steering;
    if (!input.keyboard_captured_by_gui) {
        if (input.key_down(platform::Scancode.W)) throttle += 1;
        if (input.key_down(platform::Scancode.S)) throttle -= 1;
        if (input.key_down(platform::Scancode.A)) steering += 1;
        if (input.key_down(platform::Scancode.D)) steering -= 1;
        if (input.key_pressed(platform::Scancode.R)) scene.get(vehicle.chassis, PhysicsBody).mark_changed();
    }
    if (throttle == vehicle.throttle && steering == vehicle.steering) return;
    vehicle.throttle = throttle;
    vehicle.steering = steering;

    foreach (index, wheel : vehicle.wheels) {
        WheelJoint* joint = &scene.get(wheel, PhysicsJoint).desc.wheel;
        if (index < FRONT_WHEELS) {
            joint.target_steering_angle = steering * STEERING_ANGLE;
        } else {
            joint.spin.enabled = throttle != 0;
            joint.spin.speed = throttle * SPIN_SPEED;
        }
        physics.apply_joint(wheel);
    }
}

fn void follow(Node* camera_node, Node* chassis) @local {
    Vec3 target = maths::transform_point(chassis.world, {});
    camera_node.local.position = target + CAMERA_OFFSET;
    camera_node.local.rotation = maths::look_rotation((target - camera_node.local.position).normalize(), { 0, 1, 0 });
}

fn void? draw_panel(
    render::Renderer* renderer,
    PhysicsWorld* physics,
    Vehicle* vehicle,
    PhysicsDebugOptions* draw,
) @local {
    imgui::set_next_window_pos(PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
    imgui::set_next_window_size(PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
    if (imgui::begin("Vehicle", null, {})) {
        imgui::text("W/S throttle, A/D steer, R rebuilds the chassis");
        imgui::checkbox("Colliders", &draw.colliders);
        imgui::checkbox("Joints", &draw.joints);
        imgui::checkbox("Joint forces", &draw.joint_extras);
        imgui::separator();
        uint live;
        foreach (wheel : vehicle.wheels) {
            if (physics.scene.get(wheel, PhysicsJoint).status == LIVE) live++;
        }
        imgui::text("Wheel joints live: %u / %u", live, WHEEL_COUNT);
        if (try chassis = physics.body(vehicle.chassis)) {
            imgui::text("Speed: %.1f m/s", chassis.linear_velocity().length());
        }
        imgui::text("Build failures: %u", (uint)physics.build_failures().len);
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
    Vehicle vehicle = build_vehicle(assets, scene)!;
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, renderer, window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);
    debug::DebugDraw debug = debug::create_debug_draw(mem);
    defer debug::destroy_debug_draw(&debug);
    PhysicsDebugOptions draw = { .joints = true };
    renderer.prepare_scene(scene)!;

    while (window.poll()) {
        Input* input = &window.input;
        if (input.key_released(platform::Scancode.ESCAPE) && !input.keyboard_captured_by_gui) break;
        gui_renderer.new_frame();
        defer {
            if (gui_renderer.frame_open) gui_renderer.finish_frame();
        }
        draw_panel(renderer: renderer, physics: physics, vehicle: &vehicle, draw: &draw)!;

        drive(scene: scene, physics: physics, vehicle: &vehicle, input: input);
        scene.update_world();
        physics.update(window.clock.delta);
        scene.update_world();
        follow(level.camera_node, vehicle.chassis);
        scene.update_world();

        debug.clear();
        physics.debug_draw(&debug, draw);
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
    platform::Window window = platform::create_window(platform::default_window_desc("c3d vehicle", 1280, 720))!!;
    defer platform::destroy_window(&window);

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      { .validation = true, .application_name = "c3d_vehicle" },
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
        io::eprintfn("vehicle example failed: %s", excuse);
        return 1;
    }
    io::printfn("closed after %d frames, %.2fs", window.clock.frame, window.clock.total);
    return 0;
}
