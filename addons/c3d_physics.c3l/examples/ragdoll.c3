module ragdoll_example;

import std::io;
import std::math;
import std::core::string;
import std::core::mem::allocators;
import std::time;
import std::time::clock;
import c3d::asset::image;
import b3;
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
import c3d::physics::getup_fixture;
import c3d::platform;
import c3d::render;
import c3d::scene;
import imgui;

const uint SCENE_NODE_CAPACITY @local = 384;
const float GROUND_SIZE @local = 20;
const float BOX_SIZE @local = 0.4f;
const float BOX_DENSITY @local = 100;
const float LAUNCH_SPEED @local = 8;
const float SPAWN_DISTANCE @local = 1.5f;
const float PREPARE_SECONDS @local = 1;
const float FREE_LOOK_RADIANS_PER_PIXEL @local = 0.003f;
const float FREE_PITCH_LIMIT @local = 1.5f;
const float FREE_SPEED @local = 4;
const float FREE_FAST_MULTIPLIER @local = 4;
const Vec3 CAMERA_START @local = { 2.8f, 2.2f, 4.5f };
const Vec3 NEIGHBOUR_POSITION @local = { -0.4f, 0.2f, -0.35f };
const Vec3 BLOCKER_POSITION @local = { 0, 0.8f, 0 };
const Vec3 BLOCKER_HALF_EXTENTS @local = { 0.55f, 0.08f, 0.55f };
const Vec2 PANEL_POSITION @local = { 16, 16 };
const Vec2 PANEL_SIZE @local = { 370, 390 };
const Vec2 STATS_PANEL_POSITION @local = { 16, 418 };
const Vec2 STATS_PANEL_SIZE @local = { 370, 270 };
const ZString[RagdollRecoveryPhase::len] RECOVERY_NAMES @local = {
    "inactive", "tracking", "blocked", "ready", "completing",
};

enum Phase @local {
    PREPARING,
    FALLEN,
    RECOVERING,
    STANDING,
}

struct FreeCamera @local {
    Vec3 position;
    float yaw;
    float pitch;
}

struct ExampleCharacter @local {
    Humanoid humanoid;
    RagdollFacing facing;
    Phase phase;
    float timer;
    fault last_error;
}

struct Level @local {
    GeometryId box_geometry;
    MaterialId box_material;
    Node* camera_node;
    Node* blocker;
    Node* neighbour;
    Vec3 neighbour_start;
}

struct Controls @local {
    PhysicsDebugOptions draw;
    bool supine;
    bool prone;
    bool recover_now;
    bool drop_now;
    bool neighbour;
    bool obstruction;
    bool automatic_weight;
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
    if (!input.mouse_captured_by_gui && input.button_down(platform::MouseButton.RIGHT)) {
        camera.yaw -= input.mouse_delta.x * FREE_LOOK_RADIANS_PER_PIXEL;
        camera.pitch = math::clamp(
            camera.pitch - input.mouse_delta.y * FREE_LOOK_RADIANS_PER_PIXEL,
            -FREE_PITCH_LIMIT,
            FREE_PITCH_LIMIT,
        );
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
        float speed = FREE_SPEED * (input.key_down(platform::Scancode.LSHIFT) ? FREE_FAST_MULTIPLIER : 1);
        camera.position += direction * (speed * delta_seconds);
    }
    camera_node.local.position = camera.position;
    camera_node.local.rotation = maths::look_rotation(forward, up);
}

fn Level? build_level(AssetStore* assets, Scene* scene, PhysicsWorld* physics) @local {
    Level level;
    GeometryId ground_geometry;
    GeometryId blocker_geometry;
    MaterialId ground_material;
    MaterialId blocker_material;
    @pool() {
        Geometry ground = geometry::plane(tmem, GROUND_SIZE, GROUND_SIZE);
        ground_geometry = assets.add_geometry(&ground, "ragdoll/ground")!;
        Geometry box = geometry::box(
            allocator: tmem,
            width: BOX_SIZE,
            height: BOX_SIZE,
            depth: BOX_SIZE,
        );
        level.box_geometry = assets.add_geometry(&box, "ragdoll/box")!;
        Geometry blocker = geometry::box(
            allocator: tmem,
            width: BLOCKER_HALF_EXTENTS.x * 2,
            height: BLOCKER_HALF_EXTENTS.y * 2,
            depth: BLOCKER_HALF_EXTENTS.z * 2,
        );
        blocker_geometry = assets.add_geometry(&blocker, "ragdoll/blocker")!;
        StandardParams params = material::STANDARD_PARAMS_DEFAULT;
        params.base_color = { 0.34f, 0.39f, 0.36f, 1 };
        params.roughness = 0.9f;
        ground_material = assets.add_material(material::standard(params), "ragdoll/ground_material")!;
        params.base_color = { 0.9f, 0.55f, 0.15f, 1 };
        level.box_material = assets.add_material(material::standard(params), "ragdoll/box_material")!;
        params.base_color = { 0.65f, 0.22f, 0.18f, 1 };
        blocker_material = assets.add_material(material::standard(params), "ragdoll/blocker_material")!;
    };
    Node* ground = scene.add_mesh(ground_geometry, ground_material, name: "ground")!;
    level.blocker = scene.add_mesh(blocker_geometry, blocker_material, name: "static_blocker")!;
    level.blocker.local.position = BLOCKER_POSITION;
    level.blocker.visible = false;
    Node* sun = scene.add_light(light::directional({ 1, 0.95f, 0.85f }, 3), name: "sun")!;
    sun.local.rotation = maths::look_rotation(((Vec3){ -0.4f, -1, -0.3f }).normalize(), { 0, 1, 0 });
    scene.background = { .kind = COLOR, .color = { 0.55f, 0.7f, 0.9f, 1 } };
    level.camera_node = scene.add_camera(camera::perspective_deg(60, 0.05f), name: "camera")!;
    scene.update_world();
    ColliderDesc ground_collider = physics::default_collider_desc(BOX);
    ground_collider.half_extents = { GROUND_SIZE * 0.5f, 0.1f, GROUND_SIZE * 0.5f };
    ground_collider.local.position.y = -0.1f;
    ground_collider.material.friction = 0.4f;
    physics.add_body(ground, physics::default_body_desc(STATIC), (&ground_collider)[:1])!;
    ColliderDesc blocker_collider = physics::default_collider_desc(BOX);
    blocker_collider.half_extents = BLOCKER_HALF_EXTENTS;
    physics.add_body(level.blocker, physics::default_body_desc(STATIC), (&blocker_collider)[:1])!;
    physics.set_enabled(level.blocker, false);
    return level;
}

fn Node*? add_box(
    Scene* scene,
    PhysicsWorld* physics,
    Level* level,
    Vec3 position,
    Vec3 velocity = {},
) @local {
    Node* node = scene.add_mesh(level.box_geometry, level.box_material, name: "movable_box")!;
    defer catch scene.remove(node);
    node.local.position = position;
    scene.update_world();
    ColliderDesc collider = physics::default_collider_desc(BOX);
    collider.half_extents = (Vec3){ BOX_SIZE, BOX_SIZE, BOX_SIZE } * 0.5f;
    collider.density = BOX_DENSITY;
    collider.material.friction = 0.4f;
    collider.contact_events = true;
    collider.hit_events = true;
    BodyDesc body = physics::default_body_desc(DYNAMIC);
    body.linear_velocity = velocity;
    body.bullet = true;
    physics.add_body(node, body, (&collider)[:1])!;
    return node;
}

fn void prepare_character(
    ExampleCharacter* character,
    Scene* scene,
    PhysicsWorld* physics,
    RagdollFacing facing,
) @local {
    physics.set_ragdoll_mode(character.humanoid.skin, ANIMATED);
    character.humanoid.character.local = maths::TRANSFORM_IDENTITY;
    character.facing = facing;
    character.phase = PREPARING;
    character.timer = 0;
    character.last_error = {};
    Ragdoll* ragdoll = scene.get(character.humanoid.skin, Ragdoll);
    ragdoll.weight = 1;
}

fn void begin_recovery(ExampleCharacter* character, Scene* scene, PhysicsWorld* physics) @local {
    if (character.phase == PREPARING || character.phase == STANDING) {
        physics.set_ragdoll_mode(character.humanoid.skin, SIMULATED);
    }
    RagdollFacing? facing = physics.recover_ragdoll(character.humanoid.skin, character.humanoid.character);
    if (catch excuse = facing) {
        character.last_error = excuse;
        if (character.phase != RECOVERING) character.phase = FALLEN;
        return;
    }
    character.facing = facing;
    character.phase = RECOVERING;
    character.timer = 0;
    character.last_error = {};
    scene.get(character.humanoid.skin, Ragdoll).weight = 1;
}

fn void update_requests(
    ExampleCharacter* character,
    Scene* scene,
    PhysicsWorld* physics,
    Controls* controls,
    float delta_seconds,
) @local {
    character.timer += delta_seconds;
    if (controls.supine || controls.prone) {
        prepare_character(
            character: character,
            scene: scene,
            physics: physics,
            facing: controls.prone ? FACE_DOWN : FACE_UP,
        );
        controls.automatic_weight = true;
        return;
    }
    if (controls.drop_now) {
        physics.set_ragdoll_mode(character.humanoid.skin, SIMULATED);
        character.phase = FALLEN;
        scene.get(character.humanoid.skin, Ragdoll).weight = 1;
        return;
    }
    if (controls.recover_now || (character.phase == PREPARING && character.timer >= PREPARE_SECONDS)) {
        begin_recovery(character, scene, physics);
    }
}

fn void sample_character(ExampleCharacter* character, Scene* scene, Controls* controls) @local {
    switch (character.phase) {
        case PREPARING:
        case FALLEN:
            getup_fixture::sample_getup(&character.humanoid, character.facing, 0);
        case RECOVERING:
            getup_fixture::sample_getup(&character.humanoid, character.facing, character.timer);
            if (controls.automatic_weight) {
                scene.get(character.humanoid.skin, Ragdoll).weight =
                  math::max(1 - character.timer / getup_fixture::SOURCE_FADE_TIME, 0.0f);
            }
        case STANDING:
            getup_fixture::sample_standing(&character.humanoid);
    }
}

fn void finish_character(ExampleCharacter* character, Scene* scene, PhysicsWorld* physics) @local {
    if (character.phase != RECOVERING || character.timer < getup_fixture::STANDING_TIME) return;
    Ragdoll* ragdoll = scene.get(character.humanoid.skin, Ragdoll);
    if (ragdoll.weight != 0) return;
    if (catch excuse = physics.finish_ragdoll_recovery(character.humanoid.skin)) {
        character.last_error = excuse;
        return;
    }
    character.phase = STANDING;
    character.last_error = {};
}

fn void? draw_panel(
    render::Renderer* renderer,
    ExampleCharacter* character,
    Scene* scene,
    Level* level,
    Controls* controls,
) @local {
    imgui::set_next_window_pos(PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
    imgui::set_next_window_size(PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
    if (imgui::begin("Physical get-up", null, {})) {
        controls.supine = imgui::button("Supine get-up");
        imgui::same_line();
        controls.prone = imgui::button("Prone get-up");
        controls.recover_now = imgui::button("Recover / re-enter (R)");
        imgui::same_line();
        controls.drop_now = imgui::button("Release (F)");
        imgui::checkbox("Static obstruction", &controls.obstruction);
        controls.neighbour = imgui::button("Place movable neighbour");
        imgui::checkbox("Colliders", &controls.draw.colliders);
        imgui::same_line();
        imgui::checkbox("Joints", &controls.draw.joints);
        imgui::checkbox("Contacts", &controls.draw.contacts);
        imgui::checkbox("Automatic source-weight fade", &controls.automatic_weight);
        Ragdoll* ragdoll = scene.get(character.humanoid.skin, Ragdoll);
        if (!controls.automatic_weight) {
            imgui::slider_float(
                label: "Source weight",
                v: &ragdoll.weight,
                v_min: 0,
                v_max: 1,
            );
        }
        imgui::slider_float(
            label: "Ordinary joint drive",
            v: &ragdoll.drive_strength,
            v_min: 0,
            v_max: 1,
        );
        RagdollRecoveryStatus status = ragdoll.recovery_status();
        imgui::separator();
        imgui::text(
            "%s: %.2f s   source weight: %.2f",
            character.facing == FACE_UP ? "Supine" : "Prone",
            character.timer,
            ragdoll.weight,
        );
        imgui::text("Recovery: %s   bodies: %u", RECOVERY_NAMES[status.phase.ordinal], status.participating);
        imgui::text("Target error: %.5f m / %.5f rad", status.position_error, status.angle_error);
        imgui::text("Motion: %.4f m/s / %.4f rad/s", status.linear_speed, status.angular_speed);
        imgui::text("Actuator: %.3f N / %.3f Nm", status.force, status.torque);
        if (status.failure) imgui::text("Recovery fault: %s", string::tformat_zstr("%s", status.failure));
        if (character.last_error) imgui::text("Last request: %s", string::tformat_zstr("%s", character.last_error));
        if (level.neighbour) {
            float displacement = (level.neighbour.world_position() - level.neighbour_start).length();
            imgui::text("Neighbour displacement: %.3f m", displacement);
        }
        imgui::text("Left click: box. Right drag: look. WASDQE: move.");
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
            scene: scene,
            camera_node: camera_node,
            view: renderer.default_view,
            debug: debug,
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
    Level level = build_level(assets, scene, physics)!;
    ExampleCharacter character = { .humanoid = getup_fixture::create_humanoid(assets, scene)! };
    getup_fixture::sample_getup(&character.humanoid, FACE_UP, 0);
    scene.update_world();
    physics.update(0);
    physics.update_ragdolls();
    scene.update_world();
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, renderer, window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);
    debug::DebugDraw debug = debug::create_debug_draw(mem);
    defer debug::destroy_debug_draw(&debug);
    FreeCamera camera = { .position = CAMERA_START, .yaw = -2.59f, .pitch = -0.25f };
    Controls controls = { .automatic_weight = true, .draw = { .colliders = true } };
    renderer.prepare_scene(scene)!;
    while (window.poll()) {
        Input* input = &window.input;
        if (input.key_released(platform::Scancode.ESCAPE) && !input.keyboard_captured_by_gui) break;
        float delta = window.clock.delta;
        gui_renderer.new_frame();
        defer {
            if (gui_renderer.frame_open) gui_renderer.finish_frame();
        }
        controls.supine = false;
        controls.prone = false;
        controls.recover_now = false;
        controls.drop_now = false;
        controls.neighbour = false;
        draw_panel(
            renderer: renderer,
            character: &character,
            scene: scene,
            level: &level,
            controls: &controls,
        )!;
        if (!input.keyboard_captured_by_gui) {
            controls.recover_now = controls.recover_now || input.key_pressed(platform::Scancode.R);
            controls.drop_now = controls.drop_now || input.key_pressed(platform::Scancode.F);
        }
        update_requests(
            character: &character,
            scene: scene,
            physics: physics,
            controls: &controls,
            delta_seconds: delta,
        );
        if (controls.obstruction != physics.is_enabled(level.blocker)) {
            physics.set_enabled(level.blocker, controls.obstruction);
            level.blocker.visible = controls.obstruction;
        }
        if (controls.neighbour) {
            if (level.neighbour) scene.remove(level.neighbour);
            level.neighbour = add_box(
                scene: scene,
                physics: physics,
                level: &level,
                position: NEIGHBOUR_POSITION,
            )!;
            level.neighbour_start = NEIGHBOUR_POSITION;
        }
        if (!input.mouse_captured_by_gui && input.button_pressed(platform::MouseButton.LEFT)) {
            Vec3 forward = free_forward(&camera);
            if (catch excuse = add_box(
                scene: scene,
                physics: physics,
                level: &level,
                position: camera.position + forward * SPAWN_DISTANCE,
                velocity: forward * LAUNCH_SPEED,
            )) io::eprintfn("add_box failed: %s", excuse);
        }
        apply_free_camera(camera: &camera, input: input, camera_node: level.camera_node, delta_seconds: delta);
        sample_character(&character, scene, &controls);
        scene.update_world();
        physics.update(delta);
        finish_character(&character, scene, physics);
        physics.update_ragdolls();
        scene.flush_removals();
        scene.update_world();
        debug.clear();
        physics.debug_draw(&debug, controls.draw);
        gui_renderer.finish_frame();
        platform::sync_window(window, renderer);
        draw_frame(
            renderer: renderer,
            scene: scene,
            camera_node: level.camera_node,
            gui_renderer: &gui_renderer,
            debug: &debug,
            info: { .time = window.clock.total, .delta = window.clock.delta },
        )!;
    }
}
fn int main(String[] args) {
    String captures;
    bool cpu_observation;
    for (usz index = 1; index < args.len; index++) {
        if (args[index] == "--acceptance" && index + 1 < args.len) {
            captures = args[++index];
        } else if (args[index] == "--cpu-observation") {
            cpu_observation = true;
        } else {
            io::eprintn("Usage: ragdoll [--acceptance existing-output-directory | --cpu-observation]");
            return 1;
        }
    }
    if (cpu_observation) {
        if (catch excuse = observe_cpu_cost()) {
            io::eprintfn("CPU observation failed: %s", excuse);
            return 1;
        }
        return 0;
    }
    platform::Window window = platform::create_window(platform::default_window_desc("c3d ragdoll", 1280, 720))!!;
    defer platform::destroy_window(&window);

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      { .validation = true, .application_name = "c3d_ragdoll" },
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

    if (captures.len) {
        io::printfn(
            "adapter,%s,width,1280,height,720,validation,true,dataset,%s",
            renderer.adapter_name,
            getup_fixture::DATASET,
        );
        for (uint scenario = 0; scenario < 4; scenario++) {
            if (catch excuse = run_acceptance(
                window: &window,
                renderer: &renderer,
                assets: &assets,
                directory: captures,
                scenario: scenario,
            )) {
                io::eprintfn("Acceptance failed: %s", excuse);
                return 1;
            }
        }
        return 0;
    }    if (catch excuse = run(
        window:   &window,
        renderer: &renderer,
        assets:   &assets,
        scene:    &scene,
        physics:  &physics,
    )) {
        io::eprintfn("ragdoll example failed: %s", excuse);
        return 1;
    }
    io::printfn("closed after %d frames, %.2fs", window.clock.frame, window.clock.total);
    return 0;
}

fn void? observe_cpu_cost() @local {
    const uint WARMUP = 120;
    const uint SAMPLES = 1080;
    foreach (active : (bool[2]){ false, true }) {
        TrackingAllocator tracking;
        tracking.init(mem);
        defer tracking.free();
        AssetStore assets = asset::create_asset_store(&tracking, asset::default_asset_store_desc());
        defer asset::destroy_asset_store(&assets);
        Scene scene = scene::create_scene(&tracking, { .max_nodes = SCENE_NODE_CAPACITY });
        defer scene::destroy_scene(&scene);
        physics::register_physics(&scene)!;
        PhysicsWorld physics = physics::create_physics_world(
            allocator: &tracking,
            assets: &assets,
            scene: &scene,
            desc: physics::default_physics_desc(),
        )!;
        defer physics::destroy_physics_world(&physics);
        Level level = build_level(&assets, &scene, &physics)!;
        Humanoid humanoid = getup_fixture::create_humanoid(&assets, &scene)!;
        Ragdoll* ragdoll = scene.get(humanoid.skin, Ragdoll);
        foreach (node : ragdoll.bone_nodes) scene.get(node, PhysicsBody).body.allow_sleep = false;
        getup_fixture::sample_getup(&humanoid, FACE_UP, 0);
        scene.update_world();
        physics.update(0);
        physics.set_ragdoll_mode(humanoid.skin, SIMULATED);
        ragdoll.weight = 1;
        physics.update_ragdolls();
        scene.update_world();
        if (active) physics.recover_ragdoll(humanoid.skin, humanoid.character)!;
        ulong elapsed;
        ulong peak;
        uint steps;
        sz allocation_start;
        for (uint frame = 0; frame < WARMUP + SAMPLES; frame++) {
            float time = (float)frame * physics::DEFAULT_FIXED_DT;
            getup_fixture::sample_getup(&humanoid, FACE_UP, time);
            ragdoll.weight = math::max(1 - time / getup_fixture::SOURCE_FADE_TIME, 0.0f);
            scene.update_world();
            if (frame == WARMUP) allocation_start = tracking.total_allocation_count();
            time::Clock before = clock::now();
            physics.update(physics::DEFAULT_FIXED_DT);
            physics.update_ragdolls();
            scene.update_world();
            ulong duration = (ulong)(clock::now() - before);
            if (frame >= WARMUP) {
                elapsed += duration;
                peak = math::max(peak, duration);
                steps += physics.steps_last_update;
            }
        }
        io::printfn(
            "cpu,recovery,%s,bones,%d,warmup,%d,samples,%d,fixed_steps,%d,mean_us,%.6f,peak_us,%.6f,allocations,%d",
            active,
            getup_fixture::BONE_COUNT,
            WARMUP,
            SAMPLES,
            steps,
            (double)elapsed / SAMPLES / 1000,
            (double)peak / 1000,
            tracking.total_allocation_count() - allocation_start,
        );
    }
}

fn void? save_capture(Renderer* renderer, RenderTargetId target, String path) @local {
    char[] pixels = mem::new_array(char, 1280 * 720 * 4);
    defer free(pixels);
    renderer.read_render_target(target, pixels)!;
    image::write_png(
        path: path,
        width: 1280,
        height: 720,
        pixels: pixels,
    )!;
}

fn void? run_acceptance(
    platform::Window* window,
    Renderer* renderer,
    AssetStore* assets,
    String directory,
    uint scenario,
) @local {
    Scene scene = scene::create_scene(mem, { .max_nodes = SCENE_NODE_CAPACITY });
    defer scene::destroy_scene(&scene);
    physics::register_physics(&scene)!;
    PhysicsWorld physics = physics::create_physics_world(
        allocator: mem,
        assets: assets,
        scene: &scene,
        desc: physics::default_physics_desc(),
    )!;
    defer physics::destroy_physics_world(&physics);
    Level level = build_level(assets, &scene, &physics)!;
    RagdollFacing facing = scenario == 1 ? FACE_DOWN : FACE_UP;
    String name = scenario == 0 ? "supine" : scenario == 1 ? "prone" : scenario == 2 ? "blocked" : "neighbour";
    Controls controls = { .automatic_weight = true, .draw = { .colliders = true }, .obstruction = scenario == 2 };
    physics.set_enabled(level.blocker, controls.obstruction);
    level.blocker.visible = controls.obstruction;
    if (scenario == 3) {
        level.neighbour = add_box(
            scene: &scene,
            physics: &physics,
            level: &level,
            position: NEIGHBOUR_POSITION,
        )!;
        level.neighbour_start = NEIGHBOUR_POSITION;
    }
    ExampleCharacter character = { .humanoid = getup_fixture::create_humanoid(assets, &scene)!, .facing = facing };
    getup_fixture::sample_getup(&character.humanoid, facing, 0);
    scene.update_world();
    physics.update(0);
    physics.update_ragdolls();
    scene.update_world();
    begin_recovery(&character, &scene, &physics);
    if (character.last_error) return character.last_error~;
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, renderer, window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);
    debug::DebugDraw debug = debug::create_debug_draw(mem);
    defer debug::destroy_debug_draw(&debug);
    RenderTargetId target = render::create_render_target(
        renderer: renderer,
        desc: render::render_target_desc(1280, 720, PixelFormat.RGBA8_SRGB),
    )!;
    defer (void)render::destroy_render_target(renderer, target);
    ViewId capture_view = render::create_view(renderer, render::texture_view_desc(target, OutputMode.DISPLAY_LDR))!;
    defer (void)render::destroy_view(renderer, capture_view);
    renderer.prepare_scene(&scene)!;
    float[5] capture_times = { 0, 2, 6, 12.5f, 18 };
    uint next_capture;
    usz frame;
    float peak_position;
    float peak_angle;
    float peak_penetration;
    float peak_force;
    float peak_torque;
    float completion_time;
    while (next_capture < capture_times.len && window.poll()) {
        float delta = frame == 0 ? 0 : getup_fixture::FRAME_MULTIPLIERS[(frame - 1) % getup_fixture::FRAME_MULTIPLIERS.len] * physics::DEFAULT_FIXED_DT;
        frame++;
        character.timer += delta;
        gui_renderer.new_frame();
        draw_panel(
            renderer: renderer,
            character: &character,
            scene: &scene,
            level: &level,
            controls: &controls,
        )!;
        sample_character(&character, &scene, &controls);
        scene.update_world();
        physics.update(delta);
        bool active = character.phase == RECOVERING;
        finish_character(&character, &scene, &physics);
        if (active && character.phase == STANDING) completion_time = character.timer;
        physics.update_ragdolls();
        scene.update_world();
        Ragdoll* ragdoll = scene.get(character.humanoid.skin, Ragdoll);
        RagdollRecoveryStatus status = ragdoll.recovery_status();
        peak_force = math::max(peak_force, status.force);
        peak_torque = math::max(peak_torque, status.torque);
        if (active) {
            foreach (index, node : ragdoll.bone_nodes) {
                b3::BodyId body = physics.body(node)!;
                b3::WorldTransform native = body.transform();
                maths::Transform visible = maths::transform_from_mat4(character.humanoid.joints[ragdoll.bone_joints[index]].world);
                maths::Transform bone = maths::transform_from_mat4(node.world);
                Vec3 joint_position = body.world_point(ragdoll.joint_in_bone[index].position);
                Quaternionf joint_rotation = native.q.mul(ragdoll.joint_in_bone[index].rotation).normalize();
                peak_position = math::max(peak_position, (visible.position - joint_position).length(), (bone.position - (Vec3)native.p).length());
                foreach (difference : (Quaternionf[2]){ visible.rotation.mul(joint_rotation.conjugate()), bone.rotation.mul(native.q.conjugate()) }) {
                    Vec3 axis = { difference.i, difference.j, difference.k };
                    peak_angle = math::max(peak_angle, 2 * math::atan2(axis.length(), math::abs(difference.l)));
                }
                b3::ContactData[32] storage;
                foreach (contact : body.contact_data(storage[..])) {
                    foreach (&manifold : contact.contact_manifolds()) {
                        foreach (point : manifold.contact_points()) peak_penetration = math::max(peak_penetration, -point.separation);
                    }
                }
            }
        }
        debug.clear();
        physics.debug_draw(&debug, controls.draw);
        gui_renderer.finish_frame();
        platform::sync_window(window, renderer);
        renderer.begin_frame({ .time = character.timer, .delta = delta })!;
        defer catch render::abort_frame(renderer);
        renderer.render_view(
            scene: &scene,
            camera_node: level.camera_node,
            view: capture_view,
            debug: &debug,
        )!;
        renderer.finish_view(capture_view)!;
        if (renderer.has_output) {
            renderer.render_view(
                scene: &scene,
                camera_node: level.camera_node,
                view: renderer.default_view,
                debug: &debug,
            )!;
            renderer.finish_view(renderer.default_view)!;
            OverlayContext overlay = renderer.begin_overlay()!;
            gui_renderer.record(&overlay)!;
            renderer.end_overlay(&overlay)!;
        }
        renderer.end_frame()!;
        if (character.timer >= capture_times[next_capture]) {
            String path = string::tformat("%s/%s-%d.png", directory, name, next_capture);
            save_capture(renderer, target, path)!;
            io::printfn(
                "capture,%s,time,%.6f,phase,%s,residual_m,%.6f,residual_rad,%.6f",
                path,
                character.timer,
                status.phase,
                status.position_error,
                status.angle_error,
            );
            next_capture++;
        }
    }
    float neighbour_motion = level.neighbour ? (level.neighbour.world_position() - level.neighbour_start).length() : 0;
    io::printfn(
        "visual,%s,frames,%d,completion,%.6f,position,%.9f,angle,%.9f,penetration,%.9f,force,%.6f,torque,%.6f,neighbour,%.6f",
        name,
        frame,
        completion_time,
        peak_position,
        peak_angle,
        peak_penetration,
        peak_force,
        peak_torque,
        neighbour_motion,
    );
    if (next_capture != capture_times.len || peak_position > 0.00002f || peak_angle > 0.0001f
        || peak_penetration > getup_fixture::PENETRATION_LIMIT || peak_force > 200.0001f || peak_torque > 20.0001f) return c3d::INVALID_ARGUMENT~;
    if (scenario < 2 && character.phase != STANDING) return c3d::INVALID_ARGUMENT~;
    if (scenario == 2 && character.phase != RECOVERING) return c3d::INVALID_ARGUMENT~;
    if (scenario == 3 && neighbour_motion <= 0.01f) return c3d::INVALID_ARGUMENT~;
}
