module cloth_example;

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
import c3d::physics::cloth;
import c3d::platform;
import c3d::render;
import c3d::scene;
import imgui;
import ragdoll_bones;
import std::io;
import std::io::file;
import std::math;
import std::math::quaternion;
import std::sort;
import std::time;
import std::time::clock;

alias Quat @local = Quaternionf;

const uint WIDTH @local = 1280;
const uint HEIGHT @local = 720;
const uint SCENE_NODE_CAPACITY @local = 256; // character joints, ragdoll bones, level
const uint FLAG_COLUMNS @local = 24;
const uint FLAG_ROWS @local = 16;
const uint BENCHMARK_CELLS @local = 32; // a 33x33-vertex flag at the default 4x8 solver settings
const float FLAG_WIDTH @local = 1.8f;
const float FLAG_HEIGHT @local = 1.2f;
const float POLE_HEIGHT @local = 4;
const float POLE_RADIUS @local = 0.05f;
const Vec3 POLE_POSITION @local = { 0.6f, 0, 0 };
const uint CAPE_COLUMNS @local = 12;
const uint CAPE_ROWS @local = 22;
const float CAPE_WIDTH @local = 0.5f;
const float CAPE_LENGTH @local = 0.95f;
const float CAPE_BACK_OFFSET @local = 0.17f; // metres behind the chest joint; clears the 0.13 m chest capsule
const float CAPE_SHOULDER_HEIGHT @local = 0.12f; // metres above the chest joint
const String CAPE_JOINT @local = "DEF-spine.003";
const float CAPE_THICKNESS @local = 0.02f; // metres; keeps the cape off the skin that lies outside the bone capsules
const Vec3 CHARACTER_POSITION @local = { -1.4f, 0, 0.6f };
const Vec3 CHARACTER_FACING @local = { -0.45f, 0, -1 }; // three-quarter back view from the camera
const String MODEL_PATH @local = "../../examples/assets/quaternius/AnimationLibrary_Godot.glb";
const String WALK_CLIP @local = "Walk_Loop";
const int RAGDOLL_GROUP @local = -1; // bones never collide with each other; joints hold them apart
const float DRIVE_HERTZ @local = 6;
const float DRIVE_DAMPING @local = 1;
const float BLEND_OUT_SECONDS @local = 0.8f;
const float AIR_RESPONSE @local = 2.5f; // per second: particle acceleration per m/s of normal wind, at any resolution
const float DEFAULT_WIND_SPEED @local = 6;
const float DEFAULT_WIND_HEADING @local = 35; // degrees off the flag plane; drag acts on the normal component only
const float GUST_SHARE @local = 0.35f; // fraction of the speed a gust adds or removes
const float GUST_RATE @local = 0.7f; // radians per second
const uint WARMUP_FRAMES @local = 120; // two simulated seconds settle the cloth before measuring
const uint MEASURED_FRAMES @local = 600;
const float STEP_SECONDS @local = 1.0f / 60;
const double NANOSECONDS_PER_MILLISECOND @local = 1_000_000;
const double PERCENTILE_95 @local = 0.95;
const uint CAPTURE_CHANNELS @local = 4;

enum Scenario @local {
    FLAG,
    CAPE,
    BOTH,
}

const String[Scenario::len] SCENARIO_NAMES @local = { "flag", "cape", "both" };

struct Options @local {
    bool      benchmark;
    bool      still;
    bool      ragdoll;
    bool      traced;
    bool      validation;
    TraceKind trace_kind;
    Scenario  scenario;
    uint      frames;
    String    capture_path;
}

struct Series @local {
    double total;
    double peak;
}

fn void Series.add(&self, double value) {
    self.total += value;
    self.peak = math::max(self.peak, value);
}

struct Character @local {
    Node* root;
    Node* skin;
    Node* cape;
    bool  ragdoll;
}

struct Demo @local {
    AssetStore   assets;
    Scene        scene;
    PhysicsWorld physics;
    Scenario     scenario;
    bool         simulated;
    bool         traced;
    Node*        flag;
    uint         flag_columns;
    uint         flag_rows;
    Character    character;
    Node*        camera;
    float        wind_speed;
    float        wind_heading;
    bool         gusts;
}

struct Controls @local {
    bool taa;
    bool motion_blur;
    bool colliders;
    bool ragdoll;
    bool reset;
}

fn Geometry cloth_grid(
    Allocator allocator,
    uint columns,
    uint rows,
    float width,
    float height,
) @local {
    uint stride = columns + 1;
    Geometry grid = {
        .positions = alloc::new_array(allocator, Vec3, (sz)(stride * (rows + 1))),
        .uv0       = alloc::new_array(allocator, Vec2, (sz)(stride * (rows + 1))),
        .indices   = alloc::new_array(allocator, uint, (sz)(6 * columns * rows)),
    };
    for (uint row = 0; row <= rows; row++) {
        for (uint column = 0; column <= columns; column++) {
            float u = (float)column / columns;
            float v = (float)row / rows;
            grid.positions[row * stride + column] = { u * width, -v * height, 0 };
            grid.uv0[row * stride + column] = { u, v };
        }
    }
    usz next;
    for (uint row = 0; row < rows; row++) {
        for (uint column = 0; column < columns; column++) {
            uint top_left = row * stride + column;
            uint bottom_left = top_left + stride;
            uint[6] corners = { top_left, bottom_left, top_left + 1, top_left + 1, bottom_left, bottom_left + 1 };
            grid.indices[next:6] = corners[..];
            next += 6;
        }
    }
    grid.finalize();
    return grid;
}

fn MaterialId? cloth_material(AssetStore* assets, Vec4 color) @local {
    MaterialCommon two_sided = material::MATERIAL_COMMON_DEFAULT;
    two_sided.double_sided = true;
    return assets.add_material(material::standard({ .base_color = color, .roughness = 0.8f }, two_sided));
}

// Particles have unit mass, so drag scales with vertex density to keep the response resolution-independent.
fn Wind grid_wind(
    uint columns,
    uint rows,
    float width,
    float height,
) @local {
    return { .drag = AIR_RESPONSE * (float)((columns + 1) * (rows + 1)) / (width * height) };
}

fn void? build_flag(Demo* demo) @local {
    MaterialId flag_material = cloth_material(&demo.assets, { 0.75f, 0.12f, 0.1f, 1 })!;
    MaterialId pole_material = demo.assets.add_material(material::standard({
        .base_color = { 0.55f, 0.55f, 0.58f, 1 }, .roughness = 0.4f, .metallic = 1,
    }))!;
    GeometryId flag_geometry;
    GeometryId pole_geometry;
    @pool() {
        Geometry flag = cloth_grid(
            allocator: tmem,
            columns:   demo.flag_columns,
            rows:      demo.flag_rows,
            width:     FLAG_WIDTH,
            height:    FLAG_HEIGHT,
        );
        flag_geometry = demo.assets.add_geometry(&flag, "cloth/flag")!;
        Geometry pole = geometry::cylinder(
            allocator:     tmem,
            radius_top:    POLE_RADIUS,
            radius_bottom: POLE_RADIUS,
            height:        POLE_HEIGHT,
        );
        pole_geometry = demo.assets.add_geometry(&pole, "cloth/pole")!;
    };
    Node* pole = demo.scene.add_mesh(pole_geometry, pole_material, name: "pole")!;
    pole.local.position = POLE_POSITION + (Vec3){ 0, POLE_HEIGHT * 0.5f, 0 };
    demo.flag = demo.scene.add_mesh(flag_geometry, flag_material, name: "flag")!;
    demo.flag.local.position = POLE_POSITION + (Vec3){ POLE_RADIUS, POLE_HEIGHT - 0.1f, 0 };
    demo.scene.get(demo.flag, scene::Mesh).trace = demo.traced;
    demo.scene.add(demo.flag, grid_wind(
        columns: demo.flag_columns,
        rows:    demo.flag_rows,
        width:   FLAG_WIDTH,
        height:  FLAG_HEIGHT,
    ));
}

fn ClipId? find_clip(AssetStore* assets, ClipId[] clips, String name) @local {
    foreach (clip : clips) {
        if (assets.clip(clip).data.name == name) return clip;
    }
    return NOT_FOUND~;
}

fn Vec3? joint_position(Node*[] joints, Skeleton* skeleton, String name) @local {
    return maths::translation(joints[skeleton.find_joint(name)!].world);
}

fn void? build_character(Demo* demo) @local {
    AssetStore* assets = &demo.assets;
    Scene* scene = &demo.scene;
    Character* character = &demo.character;
    ModelId model = gltf::load_model(assets, MODEL_PATH)!;
    character.root = model::instantiate(assets, scene, model, name: "character")!;
    ModelInstance* instance = scene.get(character.root, ModelInstance);
    for (usz node_index = 0; node_index < instance.nodes.len; node_index++) {
        Node* node = instance.present_node(node_index);
        if (!node) continue;
        if (scene.has(node, SkinBinding)) character.skin = node;
    }
    if (!character.skin) return NOT_FOUND~;
    ClipId walk = find_clip(assets, instance.clips, WALK_CLIP)!;
    anim::add_animator(scene, character.root).play(assets, walk)!;
    anim::update(assets, scene, 0);
    scene.update_world();

    Node*[] joints = scene.get(character.skin, SkinBinding).joints;
    Skeleton* skeleton = &assets.skeleton(scene.get(character.skin, SkinBinding).skeleton).data;
    Vec3 forward = joint_position(joints, skeleton, "DEF-toe.L")! - joint_position(joints, skeleton, "DEF-foot.L")!;
    Vec3 facing = CHARACTER_FACING.normalize();
    float turn = math::atan2(facing.x, facing.z) - math::atan2(forward.x, forward.z);
    character.root.local.position = CHARACTER_POSITION;
    character.root.local.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, turn);
    scene.update_world();

    RagdollBone[ragdoll_bones::RIGIFY_BONE_COUNT] bones;
    ragdoll_bones::rigify_bones(
        skeleton:      skeleton,
        bones:         bones[..],
        drive_hertz:   DRIVE_HERTZ,
        drive_damping: DRIVE_DAMPING,
    )!;
    RagdollDesc desc = physics::default_ragdoll_desc();
    desc.bones = bones[..];
    desc.filter.group = RAGDOLL_GROUP;
    scene.build_ragdoll(assets, character.skin, desc)!;
    demo.physics.update(0); // builds the bone bodies whose capsules the cape captures

    MaterialId cape_material = cloth_material(assets, { 0.12f, 0.2f, 0.55f, 1 })!;
    GeometryId cape_geometry;
    @pool() {
        Geometry cape = cloth_grid(
            allocator: tmem,
            columns:   CAPE_COLUMNS,
            rows:      CAPE_ROWS,
            width:     CAPE_WIDTH,
            height:    CAPE_LENGTH,
        );
        cape_geometry = assets.add_geometry(&cape, "cloth/cape")!;
    };
    // The grid hangs along -Y with its normal on +Z, so turning +Z backward lays it across the back.
    Quat heading = quaternion::from_axis_angle{float}({ 0, 1, 0 }, math::atan2(facing.x, facing.z));
    Vec3 right = heading.rotate_vec3({ -1, 0, 0 });
    Node* chest = joints[skeleton.find_joint(CAPE_JOINT)!];
    maths::Transform placement = {
        .position = maths::translation(chest.world) + (Vec3){ 0, CAPE_SHOULDER_HEIGHT, 0 }
            - facing * CAPE_BACK_OFFSET - right * (CAPE_WIDTH * 0.5f),
        .rotation = heading.mul(quaternion::from_axis_angle{float}({ 0, 1, 0 }, (float)math::PI)),
        .scale    = { 1, 1, 1 },
    };
    character.cape = scene.add_mesh(
        geometry: cape_geometry,
        material: cape_material,
        parent:   chest,
        name:     "cape",
    )!;
    character.cape.local = maths::transform_from_mat4(maths::inverse_affine(chest.world).mul(placement.to_mat4()));
    scene.get(character.cape, scene::Mesh).trace = demo.traced;
    scene.add(character.cape, grid_wind(
        columns: CAPE_COLUMNS,
        rows:    CAPE_ROWS,
        width:   CAPE_WIDTH,
        height:  CAPE_LENGTH,
    ));
    scene.update_world();
}

fn void? attach_flag(Demo* demo) @local {
    ClothDesc desc = cloth::default_cloth_desc();
    @pool() {
        uint[] pins = alloc::new_array(tmem, uint, (sz)(demo.flag_rows + 1));
        foreach (row, &pin : pins) *pin = (uint)row * (demo.flag_columns + 1);
        desc.pins = pins;
        demo.scene.add_cloth(&demo.assets, demo.flag, desc)!;
    };
}

fn void? attach_cape(Demo* demo) @local {
    Ragdoll* ragdoll = demo.scene.get(demo.character.skin, Ragdoll);
    ClothDesc desc = cloth::default_cloth_desc();
    desc.collide_ground = true;
    desc.thickness = CAPE_THICKNESS;
    Entity[ragdoll_bones::RIGIFY_BONE_COUNT] colliders;
    foreach (index, bone : ragdoll.bone_nodes) colliders[index] = bone.id;
    desc.colliders = colliders[..];
    @pool() {
        uint[] pins = alloc::new_array(tmem, uint, (sz)(CAPE_COLUMNS + 1));
        foreach (column, &pin : pins) *pin = (uint)column;
        desc.pins = pins;
        demo.scene.add_cloth(&demo.assets, demo.character.cape, desc)!;
    };
}

fn void? attach_cloths(Demo* demo) @local {
    if (!demo.simulated) return;
    if (demo.flag) attach_flag(demo)!;
    if (demo.character.cape) attach_cape(demo)!;
}

fn void? reset_cloths(Demo* demo) @local {
    if (!demo.simulated) return;
    if (demo.flag) demo.scene.remove_cloth(demo.flag);
    if (demo.character.cape) demo.scene.remove_cloth(demo.character.cape);
    return attach_cloths(demo);
}

fn void? create_demo(
    Demo* demo,
    Scenario scenario,
    uint flag_columns,
    uint flag_rows,
    bool simulated,
    bool traced = false,
) @local {
    demo.scenario = scenario;
    demo.simulated = simulated;
    demo.traced = traced;
    demo.flag_columns = flag_columns;
    demo.flag_rows = flag_rows;
    demo.assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer catch asset::destroy_asset_store(&demo.assets);
    demo.scene = scene::create_scene(mem, { .max_nodes = SCENE_NODE_CAPACITY });
    defer catch scene::destroy_scene(&demo.scene);
    physics::register_physics(&demo.scene)!;
    demo.physics = physics::create_physics_world(
        allocator: mem,
        assets:    &demo.assets,
        scene:     &demo.scene,
        desc:      physics::default_physics_desc(),
    )!;
    defer catch physics::destroy_physics_world(&demo.physics);

    MaterialId ground_material = demo.assets.add_material(material::standard({
        .base_color = { 0.22f, 0.27f, 0.2f, 1 }, .roughness = 0.95f,
    }))!;
    GeometryId ground_geometry;
    @pool() {
        Geometry ground = geometry::plane(tmem, 40, 40);
        ground_geometry = demo.assets.add_geometry(&ground, "cloth/ground")!;
    };
    Node* ground = demo.scene.add_mesh(ground_geometry, ground_material, name: "ground")!;
    Light sun_light = light::directional({ 1, 0.96f, 0.9f }, 3);
    sun_light.shadow.ray_traced = traced;
    Node* sun = demo.scene.add_light(sun_light, name: "sun")!;
    sun.local.rotation = maths::look_rotation(((Vec3){ -0.4f, -1, -0.6f }).normalize(), { 0, 1, 0 });
    demo.scene.ambient_color = { 0.55f, 0.65f, 0.8f };
    demo.scene.ambient_intensity = 0.35f;
    demo.scene.background = { .kind = COLOR, .color = { 0.45f, 0.6f, 0.8f, 1 } };
    demo.camera = demo.scene.add_camera(camera::perspective_deg(45, 0.05f), name: "camera")!;
    demo.scene.update_world();
    ColliderDesc ground_collider = physics::default_collider_desc(MESH);
    ground_collider.geometry = ground_geometry;
    demo.physics.add_body(ground, physics::default_body_desc(STATIC), (&ground_collider)[:1])!;

    if (scenario != CAPE) build_flag(demo)!;
    if (scenario != FLAG) build_character(demo)!;
    switch (scenario) {
        case FLAG:
            demo.camera.local.position = POLE_POSITION + (Vec3){ 1.4f, POLE_HEIGHT - 0.6f, 4.2f };
            demo.camera.local.rotation = maths::look_rotation(((Vec3){ -0.25f, 0, -1 }).normalize(), { 0, 1, 0 });
        case CAPE:
            demo.camera.local.position = CHARACTER_POSITION + (Vec3){ 0.6f, 1.5f, 2.6f };
            demo.camera.local.rotation = maths::look_rotation(((Vec3){ -0.2f, -0.18f, -1 }).normalize(), { 0, 1, 0 });
        case BOTH:
            demo.camera.local.position = { 0.2f, 2.3f, 6.8f };
            demo.camera.local.rotation = maths::look_rotation(((Vec3){ 0, -0.05f, -1 }).normalize(), { 0, 1, 0 });
    }
    demo.scene.update_world();
    attach_cloths(demo)!;
    demo.wind_speed = DEFAULT_WIND_SPEED;
    demo.wind_heading = DEFAULT_WIND_HEADING;
    demo.gusts = true;
}

fn void destroy_demo(Demo* demo) @local {
    physics::destroy_physics_world(&demo.physics);
    scene::destroy_scene(&demo.scene);
    asset::destroy_asset_store(&demo.assets);
}

fn void apply_wind(Demo* demo, double time) @local {
    float speed = demo.wind_speed;
    if (demo.gusts) speed *= 1 + GUST_SHARE * math::sin((float)time * GUST_RATE) * math::sin((float)time * GUST_RATE * 2.3f);
    float heading = math::deg_to_rad(demo.wind_heading);
    Vec3 velocity = { math::cos(heading) * speed, 0, math::sin(heading) * speed };
    if (demo.flag) demo.scene.get(demo.flag, Wind).velocity = velocity;
    if (demo.character.cape) demo.scene.get(demo.character.cape, Wind).velocity = velocity;
}

fn void set_ragdoll(Demo* demo, bool enabled) @local {
    Character* character = &demo.character;
    if (enabled) {
        demo.physics.set_ragdoll_mode(character.skin, SIMULATED);
        demo.scene.get(character.skin, Ragdoll).weight = 1;
    } else {
        demo.physics.recover_bones(character.skin);
    }
    character.ragdoll = enabled;
}

// Animation, physics and final ragdoll poses precede the cloth, so pins and contacts see this frame's pose.
fn void step_demo(Demo* demo, float delta, double time) @local {
    apply_wind(demo, time);
    if (demo.character.root) anim::update(&demo.assets, &demo.scene, delta);
    demo.scene.update_world();
    demo.physics.update(delta);
    if (demo.character.root && !demo.character.ragdoll) {
        Ragdoll* ragdoll = demo.scene.get(demo.character.skin, Ragdoll);
        ragdoll.weight = math::max(ragdoll.weight - delta / BLEND_OUT_SECONDS, 0.0f);
    }
    demo.physics.update_ragdolls();
    demo.scene.update_world();
    demo.physics.update_cloths();
}

fn void? configure_temporal(Renderer* renderer, ViewId view, Controls controls) @local {
    ViewDesc desc = renderer.views.get(view).desc;
    desc.post.anti_aliasing = controls.taa ? AntiAliasing.TAA : AntiAliasing.NONE;
    desc.post.motion_blur = controls.motion_blur;
    return render::configure_view(renderer, view, desc);
}

fn void panel(
    Demo* demo,
    Controls* controls,
    Renderer* renderer,
    float frame_ms,
) @local {
    if (imgui::begin("Cloth", null, {})) {
        ClothStats stats = demo.physics.cloth_stats;
        uint upload_bytes = renderer.stats.upload_bytes;
        uint history_bytes = renderer.stats.vertex_history_bytes;
        imgui::text("Scene: %s", SCENARIO_NAMES[demo.scenario.ordinal]);
        imgui::text("Solve %.3f ms, publish %.3f ms", stats.solve_seconds * 1000, stats.publish_seconds * 1000);
        imgui::text("Particles %u, constraints %u", stats.particles, stats.constraints);
        imgui::text("Geometry upload %u bytes, history %u bytes", upload_bytes, history_bytes);
        imgui::text("Frame %.2f ms", frame_ms);
        imgui::slider_float(
            label: "Wind speed",
            v: &demo.wind_speed,
            v_min: 0,
            v_max: 20,
        );
        imgui::slider_float(
            label: "Wind heading",
            v: &demo.wind_heading,
            v_min: -180,
            v_max: 180,
        );
        imgui::checkbox("Gusts", &demo.gusts);
        if (demo.character.root) imgui::checkbox("Ragdoll", &controls.ragdoll);
        imgui::checkbox("Collider guides", &controls.colliders);
        imgui::checkbox("TAA", &controls.taa);
        imgui::checkbox("Motion blur", &controls.motion_blur);
        controls.reset = imgui::button("Reset cloth");
    }
    imgui::end();
}

fn void? run_interactive(Options options) @local {
    platform::Window window = platform::create_window(platform::default_window_desc("c3d cloth", WIDTH, HEIGHT))!;
    defer platform::destroy_window(&window);
    Demo demo;
    create_demo(
        demo:         &demo,
        scenario:     options.scenario,
        flag_columns: FLAG_COLUMNS,
        flag_rows:    FLAG_ROWS,
        simulated:    !options.still,
    )!;
    defer destroy_demo(&demo);
    Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window: &window,
        assets: &demo.assets,
        desc: { .validation = true, .gpu_timings = true },
    )!;
    defer render::destroy_renderer(&renderer);
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, &renderer, &window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);
    debug::DebugDraw guides = debug::create_debug_draw(mem);
    defer debug::destroy_debug_draw(&guides);
    Controls controls = { .taa = true, .motion_blur = true };
    Controls applied;
    double elapsed;
    float frame_ms;
    uint frame;
    while (window.poll()) {
        if (options.frames && frame++ >= options.frames) break;
        if (window.input.key_released(platform::Scancode.ESCAPE) && !window.input.keyboard_captured_by_gui) break;
        time::Clock started = clock::now();
        @pool() {
            gui_renderer.new_frame();
            defer if (gui_renderer.frame_open) gui_renderer.finish_frame();
            panel(
                demo:     &demo,
                controls: &controls,
                renderer: &renderer,
                frame_ms: frame_ms,
            );
            gui_renderer.finish_frame();
            platform::sync_window(&window, &renderer);
            if (controls.taa != applied.taa || controls.motion_blur != applied.motion_blur || !frame) {
                configure_temporal(&renderer, renderer.default_view, controls)!;
                applied = controls;
            }
            if (controls.ragdoll != demo.character.ragdoll) set_ragdoll(&demo, controls.ragdoll);
            if (controls.reset) reset_cloths(&demo)!;
            elapsed += window.clock.delta;
            step_demo(&demo, window.clock.delta, elapsed);
            guides.clear();
            if (controls.colliders) demo.physics.debug_draw(&guides, { .colliders = true });
            renderer.begin_frame({
                .time = elapsed,
                .delta = window.clock.delta,
                .reference_position = demo.camera.world_position(),
            })!;
            defer catch render::abort_frame(&renderer);
            if (renderer.has_output) {
                renderer.render_view(
                    scene:       &demo.scene,
                    camera_node: demo.camera,
                    view:        renderer.default_view,
                    debug:       &guides,
                )!;
                renderer.finish_view(renderer.default_view)!;
                OverlayContext overlay = renderer.begin_overlay()!;
                gui_renderer.record(&overlay)!;
                renderer.end_overlay(&overlay)!;
            }
            renderer.end_frame()!;
        };
        frame_ms = (float)((double)(clock::now() - started) / NANOSECONDS_PER_MILLISECOND);
    }
    return renderer.log.check_validation();
}

fn double percentile(double[] samples, double fraction) @local {
    sort::quicksort(samples);
    usz index = (usz)math::min((double)(samples.len - 1), math::floor(fraction * (double)samples.len));
    return samples[index];
}

fn double mean(double[] samples) @local {
    double total;
    foreach (sample : samples) total += sample;
    return total / (double)samples.len;
}

fn void print_trace_report(
    String path,
    Series trace_build_ms,
    Series pose_ms,
    Series acceleration_ms,
    Series trace_gpu_ms,
    usz gpu_samples,
) @local {
    io::printfn("trace,%s", path);
    io::printfn("trace_build_ms,mean,%.4f,max,%.4f", trace_build_ms.total / MEASURED_FRAMES, trace_build_ms.peak);
    if (!gpu_samples) {
        io::printn("trace_gpu_ms,unavailable");
        return;
    }
    double samples = (double)gpu_samples;
    io::printfn("trace_pose_ms,mean,%.4f,max,%.4f", pose_ms.total / samples, pose_ms.peak);
    io::printfn("acceleration_build_ms,mean,%.4f,max,%.4f", acceleration_ms.total / samples, acceleration_ms.peak);
    io::printfn(
        "trace_work_ms,mean,%.4f,max_bound,%.4f",
        trace_build_ms.total / MEASURED_FRAMES + trace_gpu_ms.total / samples,
        trace_build_ms.peak + trace_gpu_ms.peak,
    );
}

fn void? run_benchmark(Options options) @local {
    Demo demo;
    create_demo(
        demo:         &demo,
        scenario:     options.scenario,
        flag_columns: BENCHMARK_CELLS,
        flag_rows:    BENCHMARK_CELLS,
        simulated:    !options.still,
        traced:       options.traced,
    )!;
    defer destroy_demo(&demo);
    demo.gusts = false;
    bool hardware = options.traced && options.trace_kind == TraceKind.HARDWARE;
    Renderer? created = render::create_renderer(
        allocator: mem,
        assets:    &demo.assets,
        desc:      { .validation = options.validation, .gpu_timings = true, .ray_queries = hardware },
    );
    if (catch excuse = created) {
        if (hardware) io::eprintn("Hardware tracing needs ray queries; this adapter or driver does not provide them.");
        return excuse~;
    }
    Renderer renderer = created;
    defer render::destroy_renderer(&renderer);
    if (hardware && !renderer.caps.ray_queries.enabled) {
        io::eprintn("Hardware tracing needs ray queries; this adapter or driver does not provide them.");
        return c3d::UNSUPPORTED~;
    }
    RenderTargetId target = render::create_render_target(
        renderer: &renderer,
        desc: render::render_target_desc(WIDTH, HEIGHT, PixelFormat.RGBA8_SRGB),
    )!;
    ViewDesc view_desc = render::texture_view_desc(target, OutputMode.DISPLAY_LDR);
    view_desc.post.anti_aliasing = AntiAliasing.TAA;
    view_desc.post.motion_blur = true;
    ViewId view = render::create_view(&renderer, view_desc)!;
    double[MEASURED_FRAMES] solve_ms;
    double[MEASURED_FRAMES] publish_ms;
    double[MEASURED_FRAMES] gpu_ms;
    usz gpu_samples;
    ulong upload_bytes;
    ulong history_bytes;
    Series trace_build_ms;
    Series blas_builds;
    Series blas_updates;
    Series tlas_builds;
    Series upload_series;
    Series pose_ms;
    Series acceleration_ms;
    Series trace_gpu_ms;
    ulong first_measured = renderer.frame_index + WARMUP_FRAMES;
    ulong last_gpu_frame = ulong::max;
    uint total_frames = WARMUP_FRAMES + MEASURED_FRAMES + render::FRAMES_IN_FLIGHT + 1;
    for (uint frame = 0; frame < total_frames; frame++) {
        double time = (double)frame * STEP_SECONDS;
        if (options.ragdoll && frame == WARMUP_FRAMES) set_ragdoll(&demo, true);
        step_demo(&demo, STEP_SECONDS, time);
        renderer.begin_frame({ .time = time, .delta = STEP_SECONDS })!;
        defer catch render::abort_frame(&renderer);
        renderer.render_view(&demo.scene, demo.camera, view)!;
        renderer.finish_view(view)!;
        renderer.end_frame()!;
        if (frame >= WARMUP_FRAMES && frame < WARMUP_FRAMES + MEASURED_FRAMES) {
            solve_ms[frame - WARMUP_FRAMES] = demo.physics.cloth_stats.solve_seconds * 1000;
            publish_ms[frame - WARMUP_FRAMES] = demo.physics.cloth_stats.publish_seconds * 1000;
            upload_bytes += renderer.stats.upload_bytes;
            history_bytes += renderer.stats.vertex_history_bytes;
            trace_build_ms.add(renderer.stats.trace_build_ms);
            blas_builds.add(renderer.stats.blas_builds);
            blas_updates.add(renderer.stats.blas_updates);
            tlas_builds.add(renderer.stats.tlas_builds);
            upload_series.add(renderer.stats.upload_bytes);
        }
        Stats* stats = &renderer.stats;
        if (stats.gpu_timing_state == GpuTimingState.READY && stats.gpu_frame_index != last_gpu_frame
            && stats.gpu_frame_index >= first_measured && stats.gpu_frame_index < first_measured + MEASURED_FRAMES) {
            double total;
            foreach (pass_ms : stats.gpu_pass_ms) total += pass_ms;
            gpu_ms[gpu_samples++] = total;
            float pose = stats.gpu_pass_ms[Pass.TRACE_POSE.ordinal];
            float acceleration = stats.gpu_pass_ms[Pass.ACCELERATION_BUILD.ordinal];
            pose_ms.add(pose);
            acceleration_ms.add(acceleration);
            trace_gpu_ms.add((double)(pose + acceleration));
            last_gpu_frame = stats.gpu_frame_index;
        }
    }
    if (options.capture_path.len) {
        char[] pixels = alloc::new_array(mem, char, WIDTH * HEIGHT * CAPTURE_CHANNELS);
        defer alloc::free(mem, pixels.ptr);
        renderer.read_render_target(target, pixels)!;
        file::save(options.capture_path, pixels)!;
    }
    ClothStats stats = demo.physics.cloth_stats;
    io::printfn("adapter,%s", renderer.adapter_name);
    io::printfn("scene,%s,simulated,%s", SCENARIO_NAMES[options.scenario.ordinal], demo.simulated);
    io::printfn("resolution,%dx%d,particles,%d,constraints,%d", WIDTH, HEIGHT, stats.particles, stats.constraints);
    io::printfn("frames,%d,warmup,%d,substeps,%d,iterations,%d", MEASURED_FRAMES, WARMUP_FRAMES,
        cloth::DEFAULT_CLOTH_SUBSTEPS, cloth::DEFAULT_CLOTH_ITERATIONS);
    io::printfn("solve_ms,mean,%.4f,p95,%.4f", mean(solve_ms[..]), percentile(solve_ms[..], PERCENTILE_95));
    io::printfn("publish_ms,mean,%.4f,p95,%.4f", mean(publish_ms[..]), percentile(publish_ms[..], PERCENTILE_95));
    io::printfn("upload_bytes_per_frame,%.0f", (double)upload_bytes / MEASURED_FRAMES);
    io::printfn("vertex_history_bytes_per_frame,%.0f", (double)history_bytes / MEASURED_FRAMES);
    if (gpu_samples) {
        io::printfn("gpu_frame_ms,samples,%d,median,%.4f,p95,%.4f", gpu_samples,
            percentile(gpu_ms[:gpu_samples], 0.5), percentile(gpu_ms[:gpu_samples], PERCENTILE_95));
    }
    if (options.traced) {
        print_trace_report(
            path:            hardware ? "hardware" : "software",
            trace_build_ms:  trace_build_ms,
            pose_ms:         pose_ms,
            acceleration_ms: acceleration_ms,
            trace_gpu_ms:    trace_gpu_ms,
            gpu_samples:     gpu_samples,
        );
        io::printfn("trace_blas_builds,mean,%.4f,max,%.0f", blas_builds.total / MEASURED_FRAMES, blas_builds.peak);
        io::printfn("trace_blas_updates,mean,%.4f,max,%.0f", blas_updates.total / MEASURED_FRAMES, blas_updates.peak);
        io::printfn("trace_tlas_builds,mean,%.4f,max,%.0f", tlas_builds.total / MEASURED_FRAMES, tlas_builds.peak);
        io::printfn("trace_upload_bytes,mean,%.0f,max,%.0f", upload_series.total / MEASURED_FRAMES, upload_series.peak);
    }
    return renderer.log.check_validation();
}

fn Scenario? scenario_named(String name) @local {
    foreach (index, scenario_name : SCENARIO_NAMES) {
        if (scenario_name == name) return Scenario::from_ordinal(index);
    }
    return c3d::INVALID_ARGUMENT~;
}

fn Options? parse_options(String[] args) @local {
    Options options = { .scenario = BOTH };
    for (usz index = 1; index < args.len; index++) {
        if (args[index] == "--benchmark") {
            options.benchmark = true;
        } else if (args[index] == "--still") {
            options.still = true;
        } else if (args[index] == "--ragdoll") {
            options.ragdoll = true;
        } else if (args[index] == "--validation") {
            options.validation = true;
        } else if (args[index] == "--trace" && index + 1 < args.len) {
            String kind = args[++index];
            if (kind == "software") {
                options.trace_kind = TraceKind.SOFTWARE;
            } else if (kind == "hardware") {
                options.trace_kind = TraceKind.HARDWARE;
            } else {
                return c3d::INVALID_ARGUMENT~;
            }
            options.traced = true;
        } else if (args[index] == "--scene" && index + 1 < args.len) {
            options.scenario = scenario_named(args[++index])!;
        } else if (args[index] == "--frames" && index + 1 < args.len) {
            options.frames = args[++index].to_uint()!;
        } else if (args[index] == "--capture" && index + 1 < args.len) {
            options.capture_path = args[++index];
        } else {
            return c3d::INVALID_ARGUMENT~;
        }
    }
    if ((options.traced || options.validation) && !options.benchmark) return c3d::INVALID_ARGUMENT~;
    if (options.ragdoll && (!options.benchmark || options.scenario == FLAG)) return c3d::INVALID_ARGUMENT~;
    return options;
}

fn int main(String[] args) {
    Options? options = parse_options(args);
    if (catch excuse = options) {
        io::eprintn("Use cloth [--scene flag|cape|both] [--still] [--frames count]");
        io::eprintn("  [--benchmark [--ragdoll] [--capture path.rgba] [--trace software|hardware] [--validation]]");
        io::eprintn("Run timings without --validation; the validation layers inflate them.");
        return 1;
    }
    fault excuse = options.benchmark ? @catch(run_benchmark(options)) : @catch(run_interactive(options));
    if (excuse) {
        io::eprintfn("Cloth example failed: %s", excuse);
        return 1;
    }
    return 0;
}
