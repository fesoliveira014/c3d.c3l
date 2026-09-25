module ragdoll_example;

import std::io;
import std::math;
import std::math::quaternion;
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

alias Quat @local = Quaternionf;

const String MODEL_PATH @local = "../../examples/assets/quaternius/AnimationLibrary_Godot.glb";
const String WALK_CLIP @local = "Walk_Loop";
const String IDLE_CLIP @local = "Idle_Loop";
const uint  MAX_BOXES @local = 256; // one node, one body and one draw per box
const uint  SCENE_NODE_CAPACITY @local = MAX_BOXES + 128; // character nodes, bone nodes, level
const float GROUND_SIZE @local = 40;
const float BOX_SIZE @local = 0.4f;
const float BOX_DENSITY @local = 400;
const float LAUNCH_SPEED @local = 14;
const float SPAWN_DISTANCE @local = 1.5f;
const float HIT_SPEED @local = 4; // meters per second; slower boxes bounce off the walking character
const float FALLEN_SECONDS @local = 3;
const float BLEND_OUT_SECONDS @local = 0.8f;
const float CROSS_FADE_SECONDS @local = 0.3f;
const int   RAGDOLL_GROUP @local = -1; // bones never collide with each other; joints hold them apart
const float FREE_LOOK_RADIANS_PER_PIXEL @local = 0.003f;
const float FREE_PITCH_LIMIT @local = 1.5f; // avoids the poles, where the up vector degenerates
const float FREE_SPEED @local = 4;
const float FREE_FAST_MULTIPLIER @local = 4;
const Vec3  CAMERA_START @local = { 0, 1.6f, 5 };
const Vec2  PANEL_POSITION @local = { 16, 16 };
const Vec2  PANEL_SIZE @local = { 360, 220 };
const Vec2  STATS_PANEL_POSITION @local = { 16, 252 };
const Vec2  STATS_PANEL_SIZE @local = { 360, 300 };

enum Phase @local {
    WALKING,
    FALLEN,
    RECOVERING,
}

const ZString[Phase::len] PHASE_NAMES @local = { "walking", "fallen", "recovering" };

// One simulated bone of the Rigify skin; angles in radians.
struct BoneSpec @local {
    String    name;
    JointKind kind;
    float     radius;
    float     length;  // leaf bones only
    float     cone;    // SPHERICAL half angle
    float     twist;   // SPHERICAL, symmetric
    float     lower;   // REVOLUTE
    float     upper;
}

const BoneSpec[12] BONES @local = {
    { .name = "DEF-hips", .kind = SPHERICAL, .radius = 0.12f, .cone = 0.3f, .twist = 0.3f },
    { .name = "DEF-spine.001", .kind = SPHERICAL, .radius = 0.12f, .cone = 0.4f, .twist = 0.3f },
    { .name = "DEF-spine.003", .kind = SPHERICAL, .radius = 0.13f, .cone = 0.4f, .twist = 0.3f },
    { .name = "DEF-head", .kind = SPHERICAL, .radius = 0.1f, .length = 0.22f, .cone = 0.6f, .twist = 0.6f },
    { .name = "DEF-upper_arm.L", .kind = SPHERICAL, .radius = 0.05f, .cone = 1.4f, .twist = 0.8f },
    { .name = "DEF-forearm.L", .kind = REVOLUTE, .radius = 0.045f, .lower = 0, .upper = 2.4f },
    { .name = "DEF-upper_arm.R", .kind = SPHERICAL, .radius = 0.05f, .cone = 1.4f, .twist = 0.8f },
    { .name = "DEF-forearm.R", .kind = REVOLUTE, .radius = 0.045f, .lower = 0, .upper = 2.4f },
    { .name = "DEF-thigh.L", .kind = SPHERICAL, .radius = 0.07f, .cone = 1.0f, .twist = 0.4f },
    { .name = "DEF-shin.L", .kind = REVOLUTE, .radius = 0.055f, .lower = -2.4f, .upper = 0 },
    { .name = "DEF-thigh.R", .kind = SPHERICAL, .radius = 0.07f, .cone = 1.0f, .twist = 0.4f },
    { .name = "DEF-shin.R", .kind = REVOLUTE, .radius = 0.055f, .lower = -2.4f, .upper = 0 },
};

struct FreeCamera @local {
    Vec3  position;
    float yaw;
    float pitch;
}

struct Character @local {
    Node*  root;
    Node*  skin;
    ClipId walk;
    ClipId idle;
    Phase  phase;
    float  timer;
}

struct Level @local {
    GeometryId box_geometry;
    MaterialId box_material;
    Node*      camera_node;
}

struct Controls @local {
    PhysicsDebugOptions draw;
    bool                ragdoll_now;
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
    MaterialId ground_material;
    @pool() {
        Geometry ground = geometry::plane(tmem, GROUND_SIZE, GROUND_SIZE);
        ground_geometry = assets.add_geometry(&ground, "ragdoll/ground")!;
        Geometry box = geometry::box(
            allocator: tmem,
            width:     BOX_SIZE,
            height:    BOX_SIZE,
            depth:     BOX_SIZE,
        );
        level.box_geometry = assets.add_geometry(&box, "ragdoll/box")!;
        StandardParams ground_params = material::STANDARD_PARAMS_DEFAULT;
        ground_params.base_color = { 0.45f, 0.5f, 0.45f, 1 };
        ground_params.metallic = 0;
        ground_params.roughness = 0.9f;
        ground_material = assets.add_material(material::standard(ground_params), "ragdoll/ground_material")!;
        StandardParams box_params = material::STANDARD_PARAMS_DEFAULT;
        box_params.base_color = { 0.85f, 0.55f, 0.2f, 1 };
        box_params.metallic = 0;
        box_params.roughness = 0.6f;
        level.box_material = assets.add_material(material::standard(box_params), "ragdoll/box_material")!;
    };

    Node* ground = scene.add_mesh(ground_geometry, ground_material, name: "ground")!;
    Node* sun = scene.add_light(light::directional({ 1, 0.95f, 0.85f }, 3), name: "sun")!;
    sun.local.rotation = maths::look_rotation(((Vec3){ -0.4f, -1, -0.3f }).normalize(), { 0, 1, 0 });
    scene.background = { .kind = COLOR, .color = { 0.55f, 0.7f, 0.9f, 1 } };
    level.camera_node = scene.add_camera(camera::perspective_deg(60, 0.05f), name: "camera")!;
    scene.update_world();

    ColliderDesc ground_collider = physics::default_collider_desc(MESH);
    ground_collider.geometry = ground_geometry;
    physics.add_body(ground, physics::default_body_desc(STATIC), (&ground_collider)[:1])!;
    return level;
}

fn ClipId? find_clip(AssetStore* assets, ClipId[] clips, String name) @local {
    foreach (clip : clips) {
        if (assets.clip(clip).data.name == name) return clip;
    }
    return NOT_FOUND~;
}

fn Character? build_character(AssetStore* assets, Scene* scene) @local {
    ModelId model = gltf::load_model(assets, MODEL_PATH)!;
    Character character = { .root = model::instantiate(assets, scene, model, name: "character")! };
    ModelInstance* instance = scene.get(character.root, ModelInstance);
    foreach (node : instance.nodes) {
        if (scene.has(node, SkinBinding)) character.skin = node;
    }
    if (!character.skin) return NOT_FOUND~;
    character.walk = find_clip(assets, instance.clips, WALK_CLIP)!;
    character.idle = find_clip(assets, instance.clips, IDLE_CLIP)!;
    anim::add_animator(scene, character.root).play(assets, character.walk)!;
    anim::update(assets, scene, 0);
    scene.update_world();

    Skeleton* skeleton = &assets.skeleton(scene.get(character.skin, SkinBinding).skeleton).data;
    RagdollBone[BONES.len] bones;
    foreach (index, &spec : BONES) {
        RagdollBone bone = physics::default_ragdoll_bone(skeleton.find_joint(spec.name)!);
        bone.kind = spec.kind;
        bone.radius = spec.radius;
        bone.length = spec.length;
        bone.cone = { .enabled = true, .upper = spec.cone };
        bone.twist = { .enabled = true, .lower = -spec.twist, .upper = spec.twist };
        bone.hinge_axis = { 1, 0, 0 };
        bone.angle = { .enabled = true, .lower = spec.lower, .upper = spec.upper };
        bones[index] = bone;
    }
    RagdollDesc desc = physics::default_ragdoll_desc();
    desc.bones = bones[..];
    desc.filter.group = RAGDOLL_GROUP;
    scene.build_ragdoll(assets, character.skin, desc)!;
    io::printfn("%s: %d joints, %d ragdoll bones", MODEL_PATH, skeleton.parents.len, bones.len);
    return character;
}

fn void cross_fade_to(Animator* animator, AssetStore* assets, ClipId clip) @local {
    animator.play(assets, clip, CROSS_FADE_SECONDS)!!;
    sz last = animator.actions.len() - 1;
    if (last > 0) animator.cross_fade(&animator.actions[last - 1], &animator.actions[last], CROSS_FADE_SECONDS);
}

fn bool is_bone(Node* node, Character* character) @local => node.parent == character.skin;

fn bool was_hit(PhysicsWorld* physics, Character* character) @local {
    foreach (hit : physics.hits()) {
        if (hit.approach_speed < HIT_SPEED) continue;
        if (is_bone(hit.a, character) || is_bone(hit.b, character)) return true;
    }
    return false;
}

fn void advance_character(
    Character* character,
    AssetStore* assets,
    Scene* scene,
    PhysicsWorld* physics,
    bool ragdoll_now,
    float delta_seconds,
) @local {
    Ragdoll* ragdoll = scene.get(character.skin, Ragdoll);
    character.timer += delta_seconds;
    switch (character.phase) {
        case WALKING:
            if (!ragdoll_now && !was_hit(physics, character)) return;
            physics.set_ragdoll_mode(character.skin, SIMULATED);
            ragdoll.weight = 1;
            character.phase = FALLEN;
            character.timer = 0;
        case FALLEN:
            if (character.timer < FALLEN_SECONDS) return;
            physics.recover_ragdoll(character.skin, character.root);
            cross_fade_to(scene.get(character.root, Animator), assets, character.idle);
            character.phase = RECOVERING;
            character.timer = 0;
        case RECOVERING:
            ragdoll.weight = math::max(1 - character.timer / BLEND_OUT_SECONDS, 0.0f);
            if (ragdoll.weight > 0) return;
            cross_fade_to(scene.get(character.root, Animator), assets, character.walk);
            character.phase = WALKING;
    }
}

fn void throw_box(
    Scene* scene,
    PhysicsWorld* physics,
    Level* level,
    FreeCamera* camera,
) @local {
    Vec3 forward = free_forward(camera);
    Node*? added = scene.add_mesh(level.box_geometry, level.box_material, name: "box");
    if (catch added) return;
    Node* node = added;
    node.local.position = camera.position + forward * SPAWN_DISTANCE;
    scene.update_world();

    ColliderDesc collider = physics::default_collider_desc(BOX);
    collider.half_extents = (Vec3){ BOX_SIZE, BOX_SIZE, BOX_SIZE } * 0.5f;
    collider.density = BOX_DENSITY;
    collider.hit_events = true;
    BodyDesc body = physics::default_body_desc(DYNAMIC);
    body.linear_velocity = forward * LAUNCH_SPEED;
    body.bullet = true;
    if (catch excuse = physics.add_body(node, body, (&collider)[:1])) {
        io::eprintfn("add_body failed: %s", excuse);
        scene.remove(node);
    }
}

fn void? draw_panel(
    render::Renderer* renderer,
    Character* character,
    Scene* scene,
    Controls* controls,
) @local {
    imgui::set_next_window_pos(PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
    imgui::set_next_window_size(PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
    if (imgui::begin("Ragdoll", null, {})) {
        imgui::text("Left click throws a box, R ragdolls now");
        imgui::text("Right drag looks, WASDQE move, Shift fast");
        imgui::checkbox("Colliders", &controls.draw.colliders);
        imgui::checkbox("Joints", &controls.draw.joints);
        imgui::separator();
        Ragdoll* ragdoll = scene.get(character.skin, Ragdoll);
        imgui::text("Phase: %s   weight: %.2f", PHASE_NAMES[character.phase.ordinal], ragdoll.weight);
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
    Character character = build_character(assets, scene)!;
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, renderer, window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);
    debug::DebugDraw debug = debug::create_debug_draw(mem);
    defer debug::destroy_debug_draw(&debug);

    FreeCamera camera = { .position = CAMERA_START, .yaw = (float)math::PI };
    Controls controls;
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
            renderer:  renderer,
            character: &character,
            scene:     scene,
            controls:  &controls,
        )!;

        if (!input.mouse_captured_by_gui && input.button_pressed(platform::MouseButton.LEFT)) {
            throw_box(scene: scene, physics: physics, level: &level, camera: &camera);
        }
        controls.ragdoll_now = !input.keyboard_captured_by_gui && input.key_pressed(platform::Scancode.R);
        apply_free_camera(camera: &camera, input: input, camera_node: level.camera_node, delta_seconds: delta);

        anim::update(assets, scene, delta);
        scene.update_world();
        physics.update(delta);
        advance_character(
            character:     &character,
            assets:        assets,
            scene:         scene,
            physics:       physics,
            ragdoll_now:   controls.ragdoll_now,
            delta_seconds: delta,
        );
        physics.update_ragdolls();
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

    if (catch excuse = run(
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
