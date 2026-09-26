module ik_example;

import std::io;
import std::io::path;
import std::math;
import c3d;
import c3d::anim;
import c3d::anim::ik;
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
import c3d::platform;
import c3d::render;
import c3d::scene;
import imgui;

const String MODEL_FILE @local = "../assets/quaternius/AnimationLibrary_Godot.glb";
const String IDLE_CLIP @local = "Idle_Loop";
const String WALK_CLIP @local = "Walk_Loop";
const uint SCENE_NODE_CAPACITY @local = 256; // the 55-node character, IK targets, terrain, camera, light
const float TERRAIN_SIZE @local = 16;
const uint TERRAIN_SEGMENTS @local = 128; // 12.5 cm cells; finer than a foot, so the mesh matches the analytic ground
const float TERRAIN_AMPLITUDE @local = 0.15f;
const float TERRAIN_FREQUENCY @local = 1.2f; // radians per metre; two feet a stride apart sit at visibly different heights
const float CHARACTER_START_X @local = 1.3f; // metres; the walk crosses the terrain's crests there, not its flat midline
const float WALK_SPEED @local = 1.1f; // metres per second; roughly the clip's stride rate, so feet slide little
const float CROSS_FADE_SECONDS @local = 0.3f;
const float WEIGHT_STEP @local = 0.25f;
const float KNEE_POLE_DISTANCE @local = 0.5f;
const float ELBOW_POLE_DISTANCE @local = 0.4f;
const float ELBOW_POLE_DROP @local = 0.1f;
const float PROP_REACH @local = 0.3f; // metres in front of the hand's idle position
const float PROP_LIFT @local = 0.35f; // metres above it; chest height makes the reach visible
const float PROP_ORBIT_RADIUS @local = 0.15f;
const float PROP_ORBIT_SPEED @local = 1.5f; // radians per second
const float PROP_RADIUS @local = 0.04f;
const float KNEE_CORRECTION_LIMIT @local = 1.2f; // radians the solve may bend a knee away from the clip
const float HEAD_MAX_ANGLE @local = 1.0f; // radians; beyond this a person turns the body instead
const float ORBIT_RADIANS_PER_PIXEL @local = 0.005f;
const float ORBIT_PITCH_LIMIT @local = 1.5f; // avoids the poles, where the up vector degenerates
const float ORBIT_ZOOM_STEP @local = 0.9f;
const float ORBIT_MIN_DISTANCE @local = 0.5f;
const float ORBIT_START_DISTANCE @local = 3.5f;
const float ORBIT_START_YAW @local = 0.7f; // radians from the character's facing; the sunlit front quarter
const float ORBIT_START_PITCH @local = 0.25f;
const float ORBIT_MAX_DISTANCE @local = 20;
const Vec3 ORBIT_TARGET_OFFSET @local = { 0, 1, 0 };
const Vec3 WORLD_UP @local = { 0, 1, 0 };
const Vec2 PANEL_POSITION @local = { 16, 16 };
const Vec2 PANEL_SIZE @local = { 360, 300 };
const Vec2 STATS_PANEL_POSITION @local = { 16, 332 };
const Vec2 STATS_PANEL_SIZE @local = { 360, 300 };

struct Orbit @local {
    float distance;
    float yaw;
    float pitch;
}

struct Controls @local {
    float legs;
    float arm;
    float head;
    bool  lines;
    bool  walking;
}

struct Character @local {
    Node*    root;
    Node*    hips;
    Node*[2] thighs;
    Node*    upper_arm;
    Node*    head;
    Node*    prop;
    Vec3     prop_center;   // character-root space
    Vec3     facing;        // character-root space, horizontal, unit
    ClipId   idle;
    ClipId   walk;
    float    prop_angle;
}

fn float terrain_height(float x, float z) @local {
    return TERRAIN_AMPLITUDE * math::sin(TERRAIN_FREQUENCY * x) * math::cos(TERRAIN_FREQUENCY * z);
}

fn Vec3 terrain_normal(float x, float z) @local {
    float slope = TERRAIN_AMPLITUDE * TERRAIN_FREQUENCY;
    float dx = slope * math::cos(TERRAIN_FREQUENCY * x) * math::cos(TERRAIN_FREQUENCY * z);
    float dz = -slope * math::sin(TERRAIN_FREQUENCY * x) * math::sin(TERRAIN_FREQUENCY * z);
    return (Vec3){ -dx, 1, -dz }.normalize();
}

fn GroundHit? terrain_hit(Ray ray, float length) @local {
    Vec3 point = { ray.origin.x, terrain_height(ray.origin.x, ray.origin.z), ray.origin.z };
    if (point.y < ray.origin.y - length) return NOT_FOUND~;
    return { .point = point, .normal = terrain_normal(point.x, point.z) };
}

fn void? build_level(AssetStore* assets, Scene* scene) @local {
    GeometryId terrain_geometry;
    MaterialId terrain_material;
    @pool() {
        Geometry terrain = geometry::plane(
            allocator:  tmem,
            width:      TERRAIN_SIZE,
            depth:      TERRAIN_SIZE,
            segments_x: TERRAIN_SEGMENTS,
            segments_z: TERRAIN_SEGMENTS,
        );
        foreach (index, &position : terrain.positions) {
            position.y = terrain_height(position.x, position.z);
            terrain.normals[index] = terrain_normal(position.x, position.z);
        }
        terrain.compute_tangents(tmem);
        terrain.finalize();
        terrain_geometry = assets.add_geometry(&terrain, "ik/terrain")!;
        StandardParams params = material::STANDARD_PARAMS_DEFAULT;
        params.base_color = { 0.45f, 0.55f, 0.4f, 1 };
        params.metallic = 0;
        params.roughness = 0.9f;
        terrain_material = assets.add_material(material::standard(params), "ik/terrain_material")!;
    };
    scene.add_mesh(terrain_geometry, terrain_material, name: "terrain")!;

    Node* sun = scene.add_light(light::directional({ 1, 0.95f, 0.85f }, 3), name: "sun")!;
    sun.local.rotation = maths::look_rotation(((Vec3){ -0.4f, -1, -0.3f }).normalize(), WORLD_UP);
    scene.background = { .kind = COLOR, .color = { 0.55f, 0.7f, 0.9f, 1 } };
}

fn ClipId? find_clip(AssetStore* assets, ClipId[] clips, String name) @local {
    foreach (clip : clips) {
        if (assets.clip(clip).data.name == name) return clip;
    }
    return NOT_FOUND~;
}

fn Vec3 to_root(Character* character, Vec3 world_position) @local {
    return maths::transform_point(maths::inverse_affine(character.root.world), world_position);
}

fn void? add_foot(
    Scene* scene,
    Character* character,
    usz side,
    String thigh,
    String shin,
    String foot,
) @local {
    Node* thigh_node = scene.find(thigh)!;
    Node* shin_node = scene.find(shin)!;
    Node* foot_node = scene.find(foot)!;
    Node* target = scene.add_node(character.root, "foot_target")!;
    Node* pole = scene.add_node(character.root, "knee_pole")!;
    pole.local.position = to_root(character, shin_node.world_position()) + character.facing * KNEE_POLE_DISTANCE;

    FootIk foot_ik = ik::foot_ik(thigh_node, shin_node, foot_node, target, pole);
    foot_ik.leg.limits[1] = ik::hinge_limit(
        reference: shin_node.local.rotation,
        axis:      { 1, 0, 0 },
        min_angle: -KNEE_CORRECTION_LIMIT,
        max_angle: KNEE_CORRECTION_LIMIT,
    );
    scene.add(thigh_node, foot_ik);
    character.thighs[side] = thigh_node;
}

fn Character? build_character(AssetStore* assets, Scene* scene) @local {
    ModelId model = gltf::load_model(assets, example_path(MODEL_FILE))!;
    Character character = { .root = model::instantiate(assets, scene, model, name: "character")! };
    character.root.local.position = { CHARACTER_START_X, terrain_height(CHARACTER_START_X, 0), 0 };
    ModelInstance* instance = scene.get(character.root, ModelInstance);
    character.idle = find_clip(assets, instance.clips, IDLE_CLIP)!;
    character.walk = find_clip(assets, instance.clips, WALK_CLIP)!;
    foreach (node : instance.nodes) {
        if (!scene.has(node, SkinBinding)) continue;
        io::printfn("%s: %d skin joints", MODEL_FILE, scene.get(node, SkinBinding).joints.len);
        break;
    }
    anim::add_animator(scene, character.root).play(assets, character.idle)!;
    anim::update(assets, scene, 0);
    scene.update_world();

    character.hips = scene.find("DEF-hips")!;
    character.upper_arm = scene.find("DEF-upper_arm.R")!;
    character.head = scene.find("DEF-head")!;
    Vec3 toe = scene.find("DEF-toe.L")!.world_position() - scene.find("DEF-foot.L")!.world_position();
    character.facing = (Vec3){ toe.x, 0, toe.z }.normalize();

    add_foot(
        scene:     scene,
        character: &character,
        side:      0,
        thigh:     "DEF-thigh.L",
        shin:      "DEF-shin.L",
        foot:      "DEF-foot.L",
    )!;
    add_foot(
        scene:     scene,
        character: &character,
        side:      1,
        thigh:     "DEF-thigh.R",
        shin:      "DEF-shin.R",
        foot:      "DEF-foot.R",
    )!;

    Node* forearm = scene.find("DEF-forearm.R")!;
    Node* hand = scene.find("DEF-hand.R")!;
    character.prop_center = to_root(&character, hand.world_position()) + character.facing * PROP_REACH
        + WORLD_UP * PROP_LIFT;
    Node* elbow_pole = scene.add_node(character.root, "elbow_pole")!;
    elbow_pole.local.position = to_root(&character, forearm.world_position())
        - character.facing * ELBOW_POLE_DISTANCE - WORLD_UP * ELBOW_POLE_DROP;
    GeometryId prop_geometry;
    @pool() {
        Geometry sphere = geometry::sphere(tmem, PROP_RADIUS);
        prop_geometry = assets.add_geometry(&sphere, "ik/prop")!;
    };
    StandardParams params = material::STANDARD_PARAMS_DEFAULT;
    params.base_color = { 0.9f, 0.5f, 0.15f, 1 };
    MaterialId prop_material = assets.add_material(material::standard(params), "ik/prop_material")!;
    character.prop = scene.add_mesh(prop_geometry, prop_material, character.root, "prop")!;
    scene.add(character.upper_arm, ik::ik_chain(character.upper_arm, forearm, hand, character.prop, elbow_pole));
    return character;
}

fn void add_head(Scene* scene, Character* character, Node* camera_node) @local {
    Vec3 facing_world = maths::transform_dir(character.root.world, character.facing).normalize();
    Quat head_world = maths::transform_from_mat4(character.head.world).rotation;
    LookAt look_at = ik::look_at(character.head, camera_node, head_world.conjugate() * facing_world);
    look_at.max_angle = HEAD_MAX_ANGLE;
    scene.add(character.head, look_at);
}

fn void handle_keys(
    Input* input,
    Controls* controls,
    AssetStore* assets,
    Scene* scene,
    Character* character,
) @local {
    if (input.keyboard_captured_by_gui) return;
    if (input.key_pressed(platform::Scancode.W)) {
        controls.walking = !controls.walking;
        Animator* animator = scene.get(character.root, Animator);
        animator.play(assets, controls.walking ? character.walk : character.idle, CROSS_FADE_SECONDS)!!;
        sz last = animator.actions.len() - 1;
        animator.cross_fade(&animator.actions[last - 1], &animator.actions[last], CROSS_FADE_SECONDS);
    }
    float step;
    if (input.key_pressed(platform::Scancode.LEFTBRACKET)) step = -WEIGHT_STEP;
    if (input.key_pressed(platform::Scancode.RIGHTBRACKET)) step = WEIGHT_STEP;
    if (step != 0) {
        controls.legs = math::clamp(controls.legs + step, 0.0f, 1.0f);
        controls.arm = math::clamp(controls.arm + step, 0.0f, 1.0f);
        controls.head = math::clamp(controls.head + step, 0.0f, 1.0f);
    }
    if (input.key_pressed(platform::Scancode.I)) controls.lines = !controls.lines;
}

fn void move_character(Character* character, Controls* controls, float delta_seconds) @local {
    Vec3* position = &character.root.local.position;
    if (controls.walking) {
        *position += character.facing * (WALK_SPEED * delta_seconds);
        float half = TERRAIN_SIZE * 0.5f - 1;
        if (math::abs(position.x) > half) position.x = -position.x;
        if (math::abs(position.z) > half) position.z = -position.z;
    }
    position.y = terrain_height(position.x, position.z);

    character.prop_angle += PROP_ORBIT_SPEED * delta_seconds;
    Vec3 side = WORLD_UP.cross(character.facing);
    character.prop.local.position = character.prop_center
        + (side * math::cos(character.prop_angle) + WORLD_UP * math::sin(character.prop_angle)) * PROP_ORBIT_RADIUS;
}

fn float solve_ik(Scene* scene, Character* character, Controls* controls) @local {
    float floor_height = character.root.world_position().y;
    FootIk*[2] feet;
    foreach (side, thigh : character.thighs) {
        FootIk* foot = scene.get(thigh, FootIk);
        foot.leg.weight = controls.legs;
        // The clip twists the shin about its bone axis, so the hinge bounds the correction from the clip pose.
        foot.leg.limits[1].reference = foot.leg.joints[1].local.rotation;
        Ray ray = foot.ground_ray();
        if (try hit = terrain_hit(ray, foot.ray_length)) {
            foot.place(hit, floor_height);
        } else {
            foot.release();
        }
        feet[side] = foot;
    }
    float drop = ik::lower_pelvis(character.hips, feet[..]);
    scene.update_world();

    foreach (foot : feet) foot.leg.solve();
    IkChain* arm = scene.get(character.upper_arm, IkChain);
    arm.weight = controls.arm;
    arm.solve();
    scene.update_world();

    foreach (foot : feet) foot.align();
    LookAt* head = scene.get(character.head, LookAt);
    head.weight = controls.head;
    head.solve();
    scene.update_world();
    return drop;
}

fn void apply_orbit(Orbit* orbit, Input* input, Node* camera_node, Vec3 target) @local {
    if (!input.mouse_captured_by_gui && input.button_down(platform::MouseButton.LEFT)) {
        orbit.yaw -= input.mouse_delta.x * ORBIT_RADIANS_PER_PIXEL;
        orbit.pitch = math::clamp(
            orbit.pitch + input.mouse_delta.y * ORBIT_RADIANS_PER_PIXEL,
            -ORBIT_PITCH_LIMIT,
            ORBIT_PITCH_LIMIT,
        );
    }
    if (!input.mouse_captured_by_gui && input.wheel != 0) {
        float zoomed = orbit.distance * math::pow(ORBIT_ZOOM_STEP, input.wheel);
        orbit.distance = math::clamp(zoomed, ORBIT_MIN_DISTANCE, ORBIT_MAX_DISTANCE);
    }

    Vec3 offset = {
        math::cos(orbit.pitch) * math::sin(orbit.yaw),
        math::sin(orbit.pitch),
        math::cos(orbit.pitch) * math::cos(orbit.yaw),
    };
    camera_node.local.position = target + offset * orbit.distance;
    camera_node.local.rotation = maths::look_rotation(-offset, WORLD_UP);
}

fn void? draw_panel(
    render::Renderer* renderer,
    Scene* scene,
    Character* character,
    Controls* controls,
    float drop,
) @local {
    imgui::set_next_window_pos(PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
    imgui::set_next_window_size(PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
    if (imgui::begin("Inverse kinematics", null, {})) {
        imgui::text("W walk or idle, [ ] step weights, I lines");
        imgui::text("Drag orbits, wheel zooms, Escape quits");
        imgui::slider_float("Legs", &controls.legs, 0, 1);
        imgui::slider_float("Arm", &controls.arm, 0, 1);
        imgui::slider_float("Head", &controls.head, 0, 1);
        imgui::checkbox("Lines", &controls.lines);
        imgui::separator();
        ZString[2] sides = { "Left", "Right" };
        foreach (side, thigh : character.thighs) {
            FootIk* foot = scene.get(thigh, FootIk);
            imgui::text("%s foot: %s, offset %.3f m", sides[side], foot.grounded ? "grounded" : "free", foot.ground_offset);
        }
        imgui::text("Pelvis drop: %.3f m", drop);
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

fn String example_path(String relative) @local {
    Path source = path::tnew($$FILEPATH)!!;
    return (String)source.parent()!!.tappend(relative)!!;
}

fn void? run(
    platform::Window* window,
    render::Renderer* renderer,
    AssetStore* assets,
    Scene* scene,
) @local {
    build_level(assets, scene)!;
    Character character = build_character(assets, scene)!;
    Node* camera_node = scene.add_camera(camera::perspective_deg(50, 0.05f), name: "camera")!;
    Orbit orbit = {
        .distance = ORBIT_START_DISTANCE,
        .yaw      = math::atan2(character.facing.x, character.facing.z) + ORBIT_START_YAW,
        .pitch    = ORBIT_START_PITCH,
    };
    apply_orbit(&orbit, &window.input, camera_node, character.root.world_position() + ORBIT_TARGET_OFFSET);
    scene.update_world();
    add_head(scene, &character, camera_node);

    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, renderer, window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);
    debug::DebugDraw debug = debug::create_debug_draw(mem);
    defer debug::destroy_debug_draw(&debug);
    Controls controls = { .legs = 1, .arm = 1, .head = 1, .lines = true };
    renderer.prepare_scene(scene)!;

    float drop;
    while (window.poll()) {
        Input* input = &window.input;
        if (input.key_released(platform::Scancode.ESCAPE) && !input.keyboard_captured_by_gui) break;
        float delta = window.clock.delta;
        gui_renderer.new_frame();
        defer {
            if (gui_renderer.frame_open) gui_renderer.finish_frame();
        }
        draw_panel(
            renderer:  renderer,
            scene:     scene,
            character: &character,
            controls:  &controls,
            drop:      drop,
        )!;

        handle_keys(
            input:     input,
            controls:  &controls,
            assets:    assets,
            scene:     scene,
            character: &character,
        );
        move_character(&character, &controls, delta);
        apply_orbit(&orbit, input, camera_node, character.root.world_position() + ORBIT_TARGET_OFFSET);
        anim::update(assets, scene, delta);
        scene.update_world();
        drop = solve_ik(scene, &character, &controls);

        debug.clear();
        if (controls.lines) debug.ik(scene, debug::COLOR_YELLOW);
        gui_renderer.finish_frame();

        platform::sync_window(window, renderer);
        draw_frame(
            renderer:     renderer,
            scene:        scene,
            camera_node:  camera_node,
            gui_renderer: &gui_renderer,
            debug:        &debug,
            info:         { .time = window.clock.total, .delta = window.clock.delta },
        )!;
    }
}

fn int main() {
    platform::Window window = platform::create_window(platform::default_window_desc("c3d ik", 1280, 720))!!;
    defer platform::destroy_window(&window);

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      { .validation = true, .application_name = "c3d_ik" },
    )!!;
    defer render::destroy_renderer(&renderer);

    Scene scene = scene::create_scene(mem, { .max_nodes = SCENE_NODE_CAPACITY });
    defer scene::destroy_scene(&scene);

    if (catch excuse = run(
        window:   &window,
        renderer: &renderer,
        assets:   &assets,
        scene:    &scene,
    )) {
        io::eprintfn("ik example failed: %s", excuse);
        return 1;
    }
    io::printfn("closed after %d frames, %.2fs", window.clock.frame, window.clock.total);
    return 0;
}
