module physics_inspector_example;

import std::io;
import std::math;
import std::math::quaternion;
import std::time::clock;
import c3d;
import c3d::anim;
import c3d::asset;
import c3d::asset::gltf;
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
import ragdoll_bones;

const uint  MAX_BOXES @local = 256; // one node, one body and one draw per box; bounds the sink reading below
const uint  SCENE_NODE_CAPACITY @local = MAX_BOXES + 256; // level, chain, figure bones and the character
const usz   INSPECTOR_SINK_SEGMENTS @local = 1 << 17; // 4 MiB of vertices; room for every flag with the replay open
const String MODEL_PATH @local = "../../examples/assets/quaternius/AnimationLibrary_Godot.glb";
const String WALK_CLIP @local = "Walk_Loop";
const float GROUND_SIZE @local = 40;
const float RAMP_WIDTH @local = 8;
const float RAMP_HEIGHT @local = 0.5f;
const float RAMP_DEPTH @local = 6;
const float RAMP_ANGLE @local = 0.35f; // radians; steep enough to slide, shallow enough to stack on
const float PLATFORM_AMPLITUDE @local = 6;
const float PLATFORM_RATE @local = 0.5f;
const Vec3  PLATFORM_HOME @local = { 0, 1.5f, -6 };
const Vec3  PLATFORM_SIZE @local = { 4, 0.4f, 4 };
const Vec3  CHAIN_ANCHOR @local = { -6, 5, -4 };
const Vec3  LINK_HALF_EXTENTS @local = { 0.15f, 0.6f, 0.15f };
const uint  CHAIN_LINKS @local = 2;
const Vec3  FIGURE_POSITION @local = { 6, 0, 4 };
const int   RAGDOLL_GROUP @local = -1; // bones never collide with each other; joints hold them apart
const float DRIVE_HERTZ @local = 6;
const float DRIVE_DAMPING @local = 1;
const float IMPULSE @local = 20;
const float RAY_LENGTH @local = 200;
const float SPAWN_DISTANCE @local = 2;
const float LAUNCH_SPEED @local = 15;
const float FREE_LOOK_RADIANS_PER_PIXEL @local = 0.003f;
const float FREE_PITCH_LIMIT @local = 1.5f; // avoids the poles, where the up vector degenerates
const float FREE_SPEED @local = 8;
const float FREE_FAST_MULTIPLIER @local = 4;
const Vec3  CAMERA_START @local = { 0, 6, 16 };
const Vec2  SCENE_PANEL_POSITION @local = { 16, 16 };
const Vec2  SCENE_PANEL_SIZE @local = { 340, 420 };
const Vec2  PHYSICS_PANEL_POSITION @local = { 900, 16 };
const Vec2  PHYSICS_PANEL_SIZE @local = { 420, 860 };
const Vec2  STATS_PANEL_POSITION @local = { 16, 452 };
const Vec2  STATS_PANEL_SIZE @local = { 340, 300 };
const uint  WINDOW_WIDTH @local = 1340;
const uint  WINDOW_HEIGHT @local = 900;
const uint  DEMO_SPAWN_INTERVAL @local = 2;    // frames between thrown boxes; reaches MAX_BOXES
const uint  DEMO_SPAWN_END @local = DEMO_SPAWN_INTERVAL * MAX_BOXES;
const uint  DEMO_RECORD_START @local = 60;
const uint  DEMO_LIMP @local = 120;
const uint  DEMO_RECORD_STOP @local = 300;
const uint  DEMO_RECOVER @local = 420;
const uint  DEMO_SELECT @local = 450;

struct FreeCamera @local {
    Vec3  position;
    float yaw;
    float pitch;
    float speed;
}

struct Level @local {
    GeometryId box_geometry;
    MaterialId box_material;
    Node*      platform;
    Node*      camera_node;
    Node*      figure;
    Node*      figure_skin;
    Node*      first_link;
    uint       boxes;
}

// Command line: --demo plays a scripted run, --draw-all raises every draw flag, --replay-default-mixes opens
// replays with box3d's mixes, --frames N closes after N frames.
struct Options @local {
    bool demo;
    bool draw_all;
    bool replay_default_mixes;
    uint frames;
}

fn float max_friction(
    float friction_a,
    SurfaceMaterialId surface_a,
    float friction_b,
    SurfaceMaterialId surface_b,
) @local => math::max(friction_a, friction_b);

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
        float speed = camera.speed * (input.key_down(platform::Scancode.LSHIFT) ? FREE_FAST_MULTIPLIER : 1);
        camera.position += direction * (speed * delta_seconds);
    }
    camera_node.local.position = camera.position;
    camera_node.local.rotation = maths::look_rotation(forward, up);
}

fn GeometryId? build_level_geometry(AssetStore* assets) @local {
    GeometryId level;
    @pool() {
        Geometry[4] parts;
        parts[0] = geometry::plane(tmem, GROUND_SIZE, GROUND_SIZE);
        Vec3[3] ramp_offsets = { { -10, 1, 4 }, { 10, 1, -2 }, { 0, 1, -12 } };
        foreach (index, offset : ramp_offsets) {
            parts[index + 1] = geometry::box(tmem, RAMP_WIDTH, RAMP_HEIGHT, RAMP_DEPTH);
            maths::Transform placement = {
                .position = offset,
                .rotation = quaternion::from_axis_angle{float}({ 1, 0, 0 }, RAMP_ANGLE),
                .scale    = { 1, 1, 1 },
            };
            parts[index + 1].transform(placement.to_mat4());
        }
        Geometry merged = geometry::merge(tmem, parts[..]);
        merged.finalize();
        level = assets.add_geometry(&merged, "inspector/level")!;
    };
    return level;
}

fn MaterialId? add_colored_material(AssetStore* assets, Vec4 color, String key) @local {
    StandardParams params = material::STANDARD_PARAMS_DEFAULT;
    params.base_color = color;
    params.metallic = 0;
    params.roughness = 0.7f;
    return assets.add_material(material::standard(params), key);
}

fn Level? build_level(AssetStore* assets, Scene* scene, PhysicsWorld* physics) @local {
    Level level;
    GeometryId level_geometry = build_level_geometry(assets)!;
    GeometryId platform_geometry;
    GeometryId link_geometry;
    @pool() {
        Geometry box = geometry::box(tmem, 1, 1, 1);
        level.box_geometry = assets.add_geometry(&box, "inspector/box_geometry")!;
        Geometry platform = geometry::box(tmem, PLATFORM_SIZE.x, PLATFORM_SIZE.y, PLATFORM_SIZE.z);
        platform_geometry = assets.add_geometry(&platform, "inspector/platform_geometry")!;
        Vec3 link_size = LINK_HALF_EXTENTS * 2;
        Geometry link = geometry::box(tmem, link_size.x, link_size.y, link_size.z);
        link_geometry = assets.add_geometry(&link, "inspector/link_geometry")!;
    };
    MaterialId ground_material = add_colored_material(assets, { 0.45f, 0.5f, 0.45f, 1 }, "inspector/ground")!;
    level.box_material = add_colored_material(assets, { 0.85f, 0.55f, 0.2f, 1 }, "inspector/box")!;
    MaterialId platform_material = add_colored_material(assets, { 0.3f, 0.5f, 0.9f, 1 }, "inspector/platform")!;
    MaterialId link_material = add_colored_material(assets, { 0.7f, 0.7f, 0.75f, 1 }, "inspector/link")!;

    Node* ground = scene.add_mesh(level_geometry, ground_material, name: "level")!;
    level.platform = scene.add_mesh(platform_geometry, platform_material, name: "platform")!;
    level.platform.local.position = PLATFORM_HOME;
    Node* sun = scene.add_light(light::directional({ 1, 0.95f, 0.85f }, 3), name: "sun")!;
    sun.local.rotation = maths::look_rotation(((Vec3){ -0.4f, -1, -0.3f }).normalize(), { 0, 1, 0 });
    scene.background = { .kind = COLOR, .color = { 0.55f, 0.7f, 0.9f, 1 } };
    level.camera_node = scene.add_camera(camera::perspective_deg(60, 0.1f), name: "camera")!;
    level.camera_node.local.position = CAMERA_START;
    scene.update_world();

    ColliderDesc level_collider = physics::default_collider_desc(MESH);
    level_collider.geometry = level_geometry;
    physics.add_body(ground, physics::default_body_desc(STATIC), (&level_collider)[:1])!;
    ColliderDesc platform_collider = physics::default_collider_desc(BOX);
    platform_collider.half_extents = PLATFORM_SIZE * 0.5f;
    physics.add_body(level.platform, physics::default_body_desc(KINEMATIC), (&platform_collider)[:1])!;
    level.first_link = build_chain(scene, physics, link_geometry, link_material)!;
    build_figure(assets, scene, &level)!;
    return level;
}

fn Node*? build_chain(
    Scene* scene,
    PhysicsWorld* physics,
    GeometryId link_geometry,
    MaterialId link_material,
) @local {
    Node* anchor = scene.add_node(name: "chain anchor")!;
    anchor.local.position = CHAIN_ANCHOR;
    scene.update_world();
    ColliderDesc anchor_collider = physics::default_collider_desc(SPHERE);
    anchor_collider.radius = 0.1f;
    physics.add_body(anchor, physics::default_body_desc(STATIC), (&anchor_collider)[:1])!;

    Node* previous = anchor;
    Node* first;
    Vec3 previous_bottom = CHAIN_ANCHOR;
    for (uint link = 0; link < CHAIN_LINKS; link++) {
        Node* node = scene.add_mesh(link_geometry, link_material, name: "chain link")!;
        node.local.position = previous_bottom - (Vec3){ 0, LINK_HALF_EXTENTS.y, 0 };
        scene.update_world();
        ColliderDesc collider = physics::default_collider_desc(BOX);
        collider.half_extents = LINK_HALF_EXTENTS;
        physics.add_body(node, physics::default_body_desc(DYNAMIC), (&collider)[:1])!;
        JointDesc hinge = physics::default_joint_desc(REVOLUTE, previous.id);
        hinge.frame.position = { 0, LINK_HALF_EXTENTS.y, 0 };
        hinge.anchor_frame.position = link == 0 ? (Vec3){} : (Vec3){ 0, -LINK_HALF_EXTENTS.y, 0 };
        physics.add_joint(node, hinge)!;
        if (!first) first = node;
        previous = node;
        previous_bottom = node.local.position - (Vec3){ 0, LINK_HALF_EXTENTS.y, 0 };
    }
    return first;
}

fn void? build_figure(AssetStore* assets, Scene* scene, Level* level) @local {
    ModelId model = gltf::load_model(assets, MODEL_PATH)!;
    level.figure = model::instantiate(assets, scene, model, name: "figure")!;
    level.figure.local.position = FIGURE_POSITION;
    ModelInstance* instance = scene.get(level.figure, ModelInstance);
    foreach (node : instance.nodes) {
        if (scene.has(node, SkinBinding)) level.figure_skin = node;
    }
    if (!level.figure_skin) return NOT_FOUND~;
    foreach (clip : instance.clips) {
        if (assets.clip(clip).data.name == WALK_CLIP) anim::add_animator(scene, level.figure).play(assets, clip)!;
    }
    anim::update(assets, scene, 0);
    scene.update_world();

    Skeleton* skeleton = &assets.skeleton(scene.get(level.figure_skin, SkinBinding).skeleton).data;
    RagdollBone[ragdoll_bones::RIGIFY_BONE_COUNT] bones;
    ragdoll_bones::rigify_bones(skeleton, bones[..], DRIVE_HERTZ, DRIVE_DAMPING)!;
    RagdollDesc desc = physics::default_ragdoll_desc();
    desc.bones = bones[..];
    desc.filter.group = RAGDOLL_GROUP;
    scene.build_ragdoll(assets, level.figure_skin, desc)!;
}

fn void spawn_box(
    Scene* scene,
    PhysicsWorld* physics,
    Level* level,
    FreeCamera* camera,
) @local {
    if (level.boxes == MAX_BOXES) return;
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
    body.linear_velocity = forward * LAUNCH_SPEED;
    if (catch excuse = physics.add_body(node, body, (&collider)[:1])) {
        io::eprintfn("add_body failed: %s", excuse);
        scene.remove(node);
        return;
    }
    level.boxes++;
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
        if (scene.get(hit.node, RigidBody).kind == DYNAMIC) {
            physics.apply_impulse(hit.node, ray.direction * IMPULSE, hit.point);
        }
    }
}

fn void handle_keys(
    Input* input,
    PhysicsPanel* panel,
    PhysicsWorld* physics,
    Scene* scene,
    Level* level,
) @local {
    if (input.keyboard_captured_by_gui) return;
    if (input.key_pressed(platform::Scancode.P)) panel.paused = !panel.paused;
    if (input.key_pressed(platform::Scancode.N)) {
        panel.paused = true;
        panel.single_step = true;
    }
    if (input.key_pressed(platform::Scancode.R)) {
        if (physics.recording_active()) {
            panel.stop_recording();
        } else {
            panel.start_recording();
        }
    }
    if (input.key_pressed(platform::Scancode.L) && panel.recording.len) panel.open_replay();
    Ragdoll* ragdoll = scene.get(level.figure_skin, Ragdoll);
    if (input.key_pressed(platform::Scancode.G)) {
        physics.set_ragdoll_mode(level.figure_skin, SIMULATED);
        ragdoll.weight = 1;
    }
    if (input.key_pressed(platform::Scancode.H) && ragdoll.bone_modes[0] == SIMULATED) {
        physics.recover_ragdoll(level.figure_skin, level.figure);
        ragdoll.weight = 0;
    }
}

fn void play_demo(
    uint frame,
    PhysicsPanel* panel,
    PhysicsWorld* physics,
    Scene* scene,
    Level* level,
    FreeCamera* camera,
) @local {
    if (frame < DEMO_SPAWN_END && frame % DEMO_SPAWN_INTERVAL == 0) {
        spawn_box(
            scene:   scene,
            physics: physics,
            level:   level,
            camera:  camera,
        );
    }
    if (frame == DEMO_RECORD_START) panel.start_recording();
    if (frame == DEMO_LIMP) {
        physics.set_ragdoll_mode(level.figure_skin, SIMULATED);
        scene.get(level.figure_skin, Ragdoll).weight = 1;
    }
    if (frame == DEMO_RECORD_STOP) {
        panel.stop_recording();
        panel.open_replay();
    }
    if (frame > DEMO_RECORD_STOP && panel.has_replay) (void)panel.replay.step();
    if (frame == DEMO_RECOVER) {
        physics.recover_ragdoll(level.figure_skin, level.figure);
        scene.get(level.figure_skin, Ragdoll).weight = 0;
    }
    if (frame == DEMO_SELECT) panel.selection.selected = level.first_link.id;
}

fn void print_readings(
    PhysicsPanel* panel,
    Scene* scene,
    Level* level,
    usz sink_peak,
) @local {
    io::printfn("sink peak: %d segments of %d", sink_peak, INSPECTOR_SINK_SEGMENTS);
    io::printfn("events logged: %d of %d rows", panel.event_count, panel.events.len);
    io::printfn("last recording: %d bytes", panel.recording.len);
    if (panel.has_replay) {
        io::printfn("replay: frame %d of %d", panel.replay.frame(), panel.replay.frame_count());
        uint? diverged = panel.replay.diverge_frame();
        if (try diverged) {
            io::printfn("replay diverged at frame %d", diverged);
        } else {
            io::printfn("replay: no divergence");
        }
    }
    Ragdoll* ragdoll = scene.get(level.figure_skin, Ragdoll);
    io::printfn("ragdoll recoveries: %d, last facing %s", ragdoll.recoveries, ragdoll.last_facing);
    PhysicsCounters counters = panel.physics.counters();
    io::printfn("bodies %d, shapes %d, joints %d", counters.bodies, counters.shapes, counters.joints);
}

fn void? draw_panels(
    render::Renderer* renderer,
    Scene* scene,
    GuiPanelState* selection,
    PhysicsPanel* panel,
) @local {
    imgui::set_next_window_pos(SCENE_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
    imgui::set_next_window_size(SCENE_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
    gui::scene_panel(scene, selection);
    imgui::set_next_window_pos(PHYSICS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
    imgui::set_next_window_size(PHYSICS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
    gui::physics_panel(panel);
    imgui::set_next_window_pos(STATS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
    imgui::set_next_window_size(STATS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
    return gui::stats_panel(renderer);
}

fn void? draw_frame(
    render::Renderer* renderer,
    Scene* scene,
    Node* camera_node,
    GuiRenderer* gui_renderer,
    debug::DebugDraw* sink,
    FrameInfo info,
) @local {
    renderer.begin_frame(info)!;
    defer catch render::abort_frame(renderer);
    if (renderer.has_output) {
        renderer.render_view(scene, camera_node, renderer.default_view, sink)!;
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
    Options options,
) @local {
    Level level = build_level(assets, scene, physics)!;
    $if $feat(C3D_PHYSICS_GUI_CHARACTER):
        InspectorCharacter walker = add_inspector_character(assets, scene, physics)!;
        defer remove_inspector_character(&walker);
    $endif
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, renderer, window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);
    gui::expose_physics_components();
    debug::DebugDraw sink = debug::create_debug_draw(mem, INSPECTOR_SINK_SEGMENTS);
    defer debug::destroy_debug_draw(&sink);
    GuiPanelState selection;
    PhysicsPanel panel = gui::create_physics_panel(mem, physics, scene, &selection);
    defer gui::destroy_physics_panel(&panel);
    panel.replay_default_mixes = options.replay_default_mixes;
    if (options.draw_all) {
        panel.draw = {
            .colliders      = true,
            .contacts       = true,
            .bounds         = true,
            .joints         = true,
            .joint_extras   = true,
            .mass           = true,
            .contact_forces = true,
            .graph_colors   = true,
            .islands        = true,
        };
    }

    FreeCamera camera = { .position = CAMERA_START, .yaw = (float)math::PI, .speed = FREE_SPEED };
    usz sink_peak;
    renderer.prepare_scene(scene)!;
    uint frame;
    while (window.poll()) {
        Input* input = &window.input;
        if (input.key_released(platform::Scancode.ESCAPE) && !input.keyboard_captured_by_gui) break;
        if (options.frames && frame == options.frames) break;
        if (options.demo) {
            play_demo(
                frame:   frame,
                panel:   &panel,
                physics: physics,
                scene:   scene,
                level:   &level,
                camera:  &camera,
            );
        }
        frame++;
        float delta = window.clock.delta;
        gui_renderer.new_frame();
        defer {
            if (gui_renderer.frame_open) gui_renderer.finish_frame();
        }
        draw_panels(
            renderer:  renderer,
            scene:     scene,
            selection: &selection,
            panel:     &panel,
        )!;

        handle_keys(
            input:   input,
            panel:   &panel,
            physics: physics,
            scene:   scene,
            level:   &level,
        );
        if (!input.mouse_captured_by_gui && input.button_pressed(platform::MouseButton.LEFT)) {
            spawn_box(
                scene:   scene,
                physics: physics,
                level:   &level,
                camera:  &camera,
            );
        }
        if (!input.mouse_captured_by_gui && input.button_pressed(platform::MouseButton.MIDDLE)) {
            push_under_cursor(
                scene:    scene,
                physics:  physics,
                level:    &level,
                pixel:    input.mouse_position,
                viewport: { renderer.output_width, renderer.output_height },
            );
        }
        $if $feat(C3D_PHYSICS_GUI_CHARACTER):
            drive_inspector_character(&walker, input);
        $endif
        float step = panel.step_dt(delta);
        if (step > 0) {
            float swing = (float)math::sin(window.clock.total * PLATFORM_RATE);
            level.platform.local.position.x = PLATFORM_HOME.x + PLATFORM_AMPLITUDE * swing;
        }
        apply_free_camera(camera: &camera, input: input, camera_node: level.camera_node, delta_seconds: delta);

        anim::update(assets, scene, step);
        scene.update_world();
        time::Clock started = clock::now();
        physics.update(step);
        panel.record_events((float)(long)started.to_now() / 1_000_000);
        physics.update_ragdolls();
        scene.flush_removals();
        scene.update_world();

        sink.clear();
        panel.debug_draw(&sink);
        sink_peak = math::max(sink_peak, panel.sink_segments + panel.sink_dropped);
        gui_renderer.finish_frame();

        platform::sync_window(window, renderer);
        draw_frame(
            renderer:     renderer,
            scene:        scene,
            camera_node:  level.camera_node,
            gui_renderer: &gui_renderer,
            sink:         &sink,
            info:         { .time = window.clock.total, .delta = window.clock.delta },
        )!;
    }
    print_readings(
        panel:     &panel,
        scene:     scene,
        level:     &level,
        sink_peak: sink_peak,
    );
}

fn int main(String[] args) {
    Options options;
    for (usz index = 1; index < args.len; index++) {
        switch (args[index]) {
            case "--demo": options.demo = true;
            case "--draw-all": options.draw_all = true;
            case "--replay-default-mixes": options.replay_default_mixes = true;
            case "--frames":
                if (index + 1 < args.len) options.frames = args[++index].to_uint() ?? 0;
            default:
                io::printfn("Unknown option: %s", args[index]);
                return 1;
        }
    }
    String title = "c3d physics inspector";
    platform::WindowDesc window_desc = platform::default_window_desc(title, WINDOW_WIDTH, WINDOW_HEIGHT);
    platform::Window window = platform::create_window(window_desc)!!;
    defer platform::destroy_window(&window);

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      { .validation = true, .application_name = "c3d_physics_inspector" },
    )!!;
    defer render::destroy_renderer(&renderer);

    Scene scene = scene::create_scene(mem, { .max_nodes = SCENE_NODE_CAPACITY });
    defer scene::destroy_scene(&scene);
    physics::register_physics(&scene)!!;
    $if $feat(C3D_PHYSICS_GUI_CHARACTER):
        register_inspector_character(&scene)!!;
    $endif

    PhysicsDesc desc = physics::default_physics_desc();
    desc.tuning.friction_mix = &max_friction;
    PhysicsWorld physics = physics::create_physics_world(
        allocator: mem,
        assets:    &assets,
        scene:     &scene,
        desc:      desc,
    )!!;
    defer physics::destroy_physics_world(&physics);

    if (catch excuse = run(
        window:   &window,
        renderer: &renderer,
        assets:   &assets,
        scene:    &scene,
        physics:  &physics,
        options:  options,
    )) {
        io::eprintfn("physics inspector failed: %s", excuse);
        return 1;
    }
    io::printfn("closed after %d frames, %.2fs", window.clock.frame, window.clock.total);
    return 0;
}

module physics_inspector_example @feat(C3D_PHYSICS_GUI_CHARACTER);

import std::math;
import c3d;
import c3d::asset;
import c3d::character;
import c3d::geometry;
import c3d::material;
import c3d::physics;
import c3d::platform;
import c3d::scene;

const Vec3  WALKER_START @local = { -4, 0.5f, 8 };
const float WALKER_SPEED @local = 3;

struct InspectorCharacter @private {
    CharacterSystem system;
    Scene*          scene;
    Node*           node;
}

fn void? register_inspector_character(Scene* scene) @private {
    character::register_character(scene)!;
}

fn InspectorCharacter? add_inspector_character(AssetStore* assets, Scene* scene, PhysicsWorld* physics) @private {
    CharacterDesc desc = character::default_character_desc();
    desc.push_bodies = true;
    StandardParams params = material::STANDARD_PARAMS_DEFAULT;
    params.base_color = { 0.2f, 0.7f, 0.9f, 1 };
    params.metallic = 0;
    MaterialId walker_material = assets.add_material(material::standard(params), "inspector/walker")!;
    GeometryId capsule_geometry;
    @pool() {
        Geometry capsule = geometry::capsule(tmem, desc.radius, desc.half_height * 2);
        capsule_geometry = assets.add_geometry(&capsule, "inspector/walker_capsule")!;
    };
    InspectorCharacter walker = {
        .system = character::create_character_system(mem, physics, scene)!,
        .scene  = scene,
        .node   = scene.add_node(name: "walker")!,
    };
    Node* body = scene.add_mesh(capsule_geometry, walker_material, parent: walker.node, name: "walker body")!;
    body.local.position = { 0, desc.half_height + desc.radius, 0 };
    walker.node.local.position = WALKER_START;
    scene.update_world();
    scene.add_character(walker.node, desc)!;
    return walker;
}

fn void remove_inspector_character(InspectorCharacter* walker) @private {
    character::destroy_character_system(&walker.system);
}

fn void drive_inspector_character(InspectorCharacter* walker, Input* input) @private {
    Vec3 desired;
    if (!input.keyboard_captured_by_gui) {
        if (input.key_down(platform::Scancode.UP)) desired.z -= WALKER_SPEED;
        if (input.key_down(platform::Scancode.DOWN)) desired.z += WALKER_SPEED;
        if (input.key_down(platform::Scancode.LEFT)) desired.x -= WALKER_SPEED;
        if (input.key_down(platform::Scancode.RIGHT)) desired.x += WALKER_SPEED;
    }
    walker.scene.move_character(walker.node, desired);
}
