module taa_example;

import std::io;
import std::io::path;
import std::math;
import c3d;
import c3d::anim;
import c3d::asset;
import c3d::asset::gltf;
import c3d::camera;
import c3d::geometry;
import c3d::gui;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::model;
import c3d::platform;
import c3d::render;
import c3d::render::post;
import c3d::scene;
import imgui;

const float ORBIT_RADIANS_PER_PIXEL @local = 0.005f;
const float ORBIT_PITCH_LIMIT @local = 1.5f; // just short of the poles, where the up vector degenerates
const float ORBIT_ZOOM_STEP @local = 0.9f;
const float ORBIT_DISTANCE_MIN @local = 2;
const float ORBIT_DISTANCE_MAX @local = 40;
const float SWEEP_RADIANS_PER_SECOND @local = 0.35f; // a slow pan keeps most of the image in history
const float SPIN_RADIANS_PER_SECOND @local = 1.5f;
const Vec3 SPIN_AXIS @local = { 0.28734789f, 0.95782629f, 0.19156526f }; // normalized (0.3, 1, 0.2)
const float RING_RADIANS_PER_SECOND @local = 0.8f;
const uint RING_COUNT @local = 12;
const float RING_RADIUS @local = 1.6f;
const float RING_BALL_RADIUS @local = 0.22f;
const Vec3 RING_CENTER @local = { 0, 0.7f, 3.2f };
const uint FENCE_COUNT @local = 16;
const float FENCE_SPACING @local = 0.8f;
const float FENCE_BAR_WIDTH @local = 0.04f; // under a pixel at the default distance, so it aliases without TAA
const float FENCE_BAR_HEIGHT @local = 2.4f;
const float FENCE_TILT_DEGREES @local = 35; // diagonal edges show stair-stepping best
const float FENCE_Z @local = -3;
const uint CHECKER_SIZE @local = 512;
const uint CHECKER_CELL @local = 8;
const float GROUND_SIZE @local = 40;
const float GROUND_REPEAT @local = 24; // many texels per pixel at grazing angles
const float CUBE_SIZE @local = 1.1f;
const Vec3 CUBE_POSITION @local = { -3, 0.8f, 0.8f };
const float FOX_HEIGHT @local = 1.2f;
const uint FOX_WALK_CLIP @local = 1; // Fox.glb orders its clips Survey, Walk, Run
const Vec3 FOX_POSITION @local = { 0, 0, 0.8f };
const float MORPH_CUBE_SIZE @local = 1;
const Vec3 MORPH_CUBE_POSITION @local = { 3, 0.8f, 0.8f };
const float SUN_INTENSITY @local = 4;
const float AMBIENT_INTENSITY @local = 0.25f;
const uint INSET_MARGIN @local = 16;
const uint[<2>][2] INSET_SIZES @local = { { 384, 216 }, { 576, 324 } };
const Vec2 CONTROLS_PANEL_POSITION @local = { 16, 360 };
const Vec2 CONTROLS_PANEL_SIZE @local = { 360, 250 };
const Vec2 POST_PANEL_POSITION @local = { 900, 16 };
const Vec2 POST_PANEL_SIZE @local = { 360, 420 };
const Vec2 STATS_PANEL_POSITION @local = { 900, 450 };
const Vec2 STATS_PANEL_SIZE @local = { 360, 260 };
const String FOX_MODEL @local = "../assets/gltf/Fox.glb";
const String MORPH_MODEL @local = "../assets/gltf/AnimatedMorphCube.glb";

struct Orbit @local {
    Vec3  target;
    float distance;
    float yaw;
    float pitch;
}

struct Options @local {
    bool         gpu_timings;
    bool         freeze;
    bool         sweep;
    AntiAliasing anti_aliasing;
    TaaDebug     debug;
}

struct Movers @local {
    Node* cube;
    Node* ring;
    float spin;
    float ring_angle;
}

fn void apply_orbit(Orbit* orbit, Input* input, Node* camera_node) @local {
    if (!input.mouse_captured_by_gui) {
        if (input.button_down(platform::MouseButton.LEFT)) {
            orbit.yaw -= input.mouse_delta.x * ORBIT_RADIANS_PER_PIXEL;
            orbit.pitch = math::clamp(orbit.pitch + input.mouse_delta.y * ORBIT_RADIANS_PER_PIXEL,
                -ORBIT_PITCH_LIMIT, ORBIT_PITCH_LIMIT);
        }
        if (input.wheel != 0) {
            float zoomed = orbit.distance * math::pow(ORBIT_ZOOM_STEP, input.wheel);
            orbit.distance = math::clamp(zoomed, ORBIT_DISTANCE_MIN, ORBIT_DISTANCE_MAX);
        }
    }

    Vec3 offset = {
        math::cos(orbit.pitch) * math::sin(orbit.yaw),
        math::sin(orbit.pitch),
        math::cos(orbit.pitch) * math::cos(orbit.yaw),
    };
    camera_node.local.position = orbit.target + offset * orbit.distance;
    camera_node.local.rotation = maths::look_rotation(-offset, { 0, 1, 0 });
}

fn String example_path(String relative) @local {
    Path source = path::tnew($$FILEPATH)!!;
    return (String)source.parent()!!.tappend(relative)!!;
}

fn TextureId? add_checker(AssetStore* assets) @local {
    char[] pixels = alloc::new_array(tmem, char, CHECKER_SIZE * CHECKER_SIZE * 4);
    for (uint row = 0; row < CHECKER_SIZE; row++) {
        for (uint column = 0; column < CHECKER_SIZE; column++) {
            bool light = ((row / CHECKER_CELL) + (column / CHECKER_CELL)) % 2 == 0;
            char value = light ? 230 : 25;
            usz texel = ((usz)row * CHECKER_SIZE + column) * 4;
            pixels[texel:3] = value;
            pixels[texel + 3] = char::max;
        }
    }
    return assets.add_texture(material::texture_2d_desc(CHECKER_SIZE, CHECKER_SIZE, RGBA8_SRGB), pixels, "taa/checker");
}

fn Aabb template_bounds(AssetStore* assets, ModelTemplate* template) @local {
    Mat4[] node_matrices = alloc::new_array(tmem, Mat4, template.nodes.len);
    foreach (index, &node : template.nodes) {
        Mat4 local = node.local.to_mat4();
        node_matrices[index] = node.parent < 0 ? local : node_matrices[node.parent].mul(local);
    }
    Aabb bounds = { .min = { 0, 0, 0 }, .max = { 0, 0, 0 } };
    foreach (index, &mesh : template.meshes) {
        Aabb mesh_bounds = maths::aabb_transform(assets.geometry(mesh.geometry).data.bounds, node_matrices[mesh.node]);
        bounds = index == 0 ? mesh_bounds : maths::aabb_merge(bounds, mesh_bounds);
    }
    return bounds;
}

fn Node*? add_animated(
    AssetStore* assets,
    Scene* scene,
    String file,
    float height,
    Vec3 position,
    uint preferred_clip,
) @local {
    ModelId model = gltf::load_model(assets, example_path(file))!;
    Aabb bounds = template_bounds(assets, &assets.model(model).data);
    float scale = height / math::max(bounds.max.y - bounds.min.y, 0.001f);
    Node* root = model::instantiate(assets, scene, model)!;
    root.local.scale = { scale, scale, scale };
    root.local.position = position - (Vec3){ 0, bounds.min.y * scale, 0 };

    ClipId[] clips = scene.get(root, ModelInstance).clips;
    Animator* animator = anim::add_animator(scene, root);
    if (clips.len) animator.play(assets, clips[math::min((usz)preferred_clip, (usz)clips.len - 1)])!;
    return root;
}

fn Node*? add_fence(Scene* scene, GeometryId bar, MaterialId material) @local {
    Transform[FENCE_COUNT] transforms;
    Quat tilt = quaternion::from_axis_angle{float}({ 0, 0, 1 }, math::deg_to_rad(FENCE_TILT_DEGREES));
    float half_extent = (FENCE_COUNT - 1) * FENCE_SPACING * 0.5f;
    foreach (index, &transform : transforms) {
        *transform = maths::TRANSFORM_IDENTITY;
        transform.position = { (float)index * FENCE_SPACING - half_extent, FENCE_BAR_HEIGHT * 0.5f, 0 };
        transform.rotation = tilt;
    }
    Node* fence = scene.add_instanced_mesh(
        geometry:   bar,
        material:   material,
        capacity:   FENCE_COUNT,
        transforms: transforms[..],
        name:       "fence",
    )!;
    fence.local.position = { 0, 0, FENCE_Z };
    return fence;
}

fn void place_ring(Scene* scene, Node* ring, float angle) @local {
    InstancedMesh* batch = scene.get(ring, InstancedMesh);
    for (uint index = 0; index < RING_COUNT; index++) {
        float phase = (float)index / RING_COUNT * 2 * (float)math::PI;
        float direction = index % 2 == 0 ? 1 : -1;
        float radius = RING_RADIUS * (index % 3 == 0 ? 0.6f : 1.0f);
        float instance_angle = phase + angle * direction * (1 + (float)(index % 4) * 0.25f);
        batch.transforms[index].position = {
            math::cos(instance_angle) * radius,
            0,
            math::sin(instance_angle) * radius,
        };
    }
}

fn Movers? build_scene(AssetStore* assets, Scene* scene) @local {
    GeometryId ground;
    GeometryId cube;
    GeometryId bar;
    GeometryId ball;
    TextureId checker;
    @pool() {
        Geometry ground_geometry = geometry::plane(tmem, GROUND_SIZE, GROUND_SIZE);
        ground = assets.add_geometry(&ground_geometry, "taa/ground")!;
        Geometry cube_geometry = geometry::box(tmem, CUBE_SIZE, CUBE_SIZE, CUBE_SIZE);
        cube = assets.add_geometry(&cube_geometry, "taa/cube")!;
        Geometry bar_geometry = geometry::box(tmem, FENCE_BAR_WIDTH, FENCE_BAR_HEIGHT, FENCE_BAR_WIDTH);
        bar = assets.add_geometry(&bar_geometry, "taa/bar")!;
        Geometry ball_geometry = geometry::sphere(tmem, RING_BALL_RADIUS);
        ball = assets.add_geometry(&ball_geometry, "taa/ball")!;
        checker = add_checker(assets)!;
    };

    StandardParams floor = material::STANDARD_PARAMS_DEFAULT;
    floor.metallic = 0;
    floor.roughness = 0.8f;
    floor.base_color_map = material::texture_slot(
        texture:   checker,
        sampler:   asset::SAMPLER_LINEAR_REPEAT,
        transform: { .scale = { GROUND_REPEAT, GROUND_REPEAT } },
    );
    MaterialId ground_material = assets.add_material(material::standard(floor), "taa/ground_material")!;
    StandardParams boxed = floor;
    boxed.base_color_map.transform = material::UV_TRANSFORM_IDENTITY;
    MaterialId cube_material = assets.add_material(material::standard(boxed), "taa/cube_material")!;
    StandardParams metal = material::STANDARD_PARAMS_DEFAULT;
    metal.base_color = { 0.9f, 0.85f, 0.7f, 1 };
    metal.metallic = 1;
    metal.roughness = 0.3f;
    MaterialId metal_material = assets.add_material(material::standard(metal), "taa/metal")!;
    StandardParams painted = material::STANDARD_PARAMS_DEFAULT;
    painted.base_color = { 0.9f, 0.35f, 0.1f, 1 };
    painted.metallic = 0;
    painted.roughness = 0.4f;
    MaterialId ring_material = assets.add_material(material::standard(painted), "taa/painted")!;

    scene.add_mesh(ground, ground_material, name: "ground")!;
    add_fence(scene, bar, metal_material)!;
    Movers movers;
    movers.cube = scene.add_mesh(cube, cube_material, name: "spinner")!;
    movers.cube.local.position = CUBE_POSITION;
    movers.ring = scene.add_instanced_mesh(
        geometry: ball,
        material: ring_material,
        capacity: RING_COUNT,
        name:     "ring",
    )!;
    scene.resize_instances(movers.ring, RING_COUNT)!;
    movers.ring.local.position = RING_CENTER;
    place_ring(scene, movers.ring, 0);

    add_animated(
        assets:         assets,
        scene:          scene,
        file:           FOX_MODEL,
        height:         FOX_HEIGHT,
        position:       FOX_POSITION,
        preferred_clip: FOX_WALK_CLIP,
    )!;
    add_animated(
        assets:         assets,
        scene:          scene,
        file:           MORPH_MODEL,
        height:         MORPH_CUBE_SIZE,
        position:       MORPH_CUBE_POSITION,
        preferred_clip: 0,
    )!;

    Node* sun = scene.add_light(light::directional({ 1, 0.96f, 0.9f }, SUN_INTENSITY), name: "sun")!;
    sun.local.rotation = maths::look_rotation((Vec3){ -0.4f, -0.8f, -0.45f }.normalize(), { 0, 1, 0 });
    scene.ambient_intensity = AMBIENT_INTENSITY;
    return movers;
}

fn ViewDesc inset_desc(uint size_index) @local {
    ViewDesc desc = render::default_view_desc();
    desc.post.anti_aliasing = AntiAliasing.TAA;
    desc.viewport = {
        .x      = INSET_MARGIN,
        .y      = INSET_MARGIN,
        .width  = INSET_SIZES[size_index].x,
        .height = INSET_SIZES[size_index].y,
    };
    return desc;
}

fn void? draw_frame(
    render::Renderer* renderer,
    Scene* scene,
    Node* camera_node,
    ViewId inset,
    GuiRenderer* gui_renderer,
    FrameInfo info,
) @local {
    renderer.begin_frame(info)!;
    defer catch render::abort_frame(renderer);

    if (renderer.has_output) {
        renderer.render_view(scene, camera_node, renderer.default_view)!;
        renderer.finish_view(renderer.default_view)!;
        renderer.render_view(scene, camera_node, inset)!;
        renderer.finish_view(inset)!;

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
    Movers* movers,
    Node* camera_node,
    Options options,
) @local {
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, renderer, window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);

    ViewDesc main_desc = render::default_view_desc();
    main_desc.post.anti_aliasing = options.anti_aliasing;
    main_desc.post.taa_params.debug = options.debug;
    render::configure_view(renderer, renderer.default_view, main_desc)!;
    uint inset_size = 0;
    ViewDesc inset = inset_desc(inset_size);
    ViewId inset_view = render::create_view(renderer, inset)!;
    defer (void)render::destroy_view(renderer, inset_view);
    renderer.prepare_scene(scene)!;

    Orbit orbit = { .target = { 0, 0.8f, 0 }, .distance = 9, .yaw = 0.3f, .pitch = 0.22f };
    bool freeze = options.freeze;
    bool sweep = options.sweep;
    bool escape_captured;
    while (window.poll()) {
        bool keyboard_was_captured = window.input.keyboard_captured_by_gui;
        gui_renderer.new_frame();
        defer {
            if (gui_renderer.frame_open) gui_renderer.finish_frame();
        }

        Input* input = &window.input;
        // Text editing can drop capture on Escape down before its release arrives.
        if (input.key_pressed(platform::Scancode.ESCAPE) || input.key_released(platform::Scancode.ESCAPE)) {
            escape_captured |= keyboard_was_captured || input.keyboard_captured_by_gui;
        }
        if (input.key_released(platform::Scancode.ESCAPE)) {
            bool quit = !escape_captured;
            escape_captured = false;
            if (quit) break;
        }

        bool cut;
        bool inset_changed;
        imgui::set_next_window_pos(CONTROLS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(CONTROLS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        if (imgui::begin("Temporal AA", null, {})) {
            imgui::checkbox("Freeze motion", &freeze);
            imgui::checkbox("Camera sweep", &sweep);
            cut = imgui::button("Cut main view");
            imgui::separator_text("Inset view");
            if (imgui::button("Resize inset")) {
                inset_size ^= 1;
                inset.viewport = inset_desc(inset_size).viewport;
                inset_changed = true;
            }
            inset_changed |= gui::anti_aliasing_combo("Inset anti-aliasing", &inset.post.anti_aliasing);
            imgui::text("Drag to orbit, wheel to zoom, Escape quits.");
        }
        imgui::end();

        imgui::set_next_window_pos(POST_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(POST_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        bool main_changed = gui::post_panel(&main_desc, {});

        imgui::set_next_window_pos(STATS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(STATS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        gui::stats_panel(renderer)!;

        float delta = freeze ? 0 : (float)window.clock.delta;
        movers.spin += delta * SPIN_RADIANS_PER_SECOND;
        movers.cube.local.rotation = quaternion::from_axis_angle{float}(SPIN_AXIS, movers.spin);
        movers.ring_angle += delta * RING_RADIANS_PER_SECOND;
        place_ring(scene, movers.ring, movers.ring_angle);
        anim::update(assets, scene, delta);
        if (sweep && !freeze) orbit.yaw += (float)window.clock.delta * SWEEP_RADIANS_PER_SECOND;
        if (cut) orbit.yaw += (float)math::PI;
        apply_orbit(&orbit, input, camera_node);
        scene.update_world();
        gui_renderer.finish_frame();

        platform::sync_window(window, renderer);
        if (main_changed) render::configure_view(renderer, renderer.default_view, main_desc)!;
        if (inset_changed) render::configure_view(renderer, inset_view, inset)!;
        if (cut) render::reset_view_history(renderer, renderer.default_view)!;
        draw_frame(
            renderer:     renderer,
            scene:        scene,
            camera_node:  camera_node,
            inset:        inset_view,
            gui_renderer: &gui_renderer,
            info:         { .time = window.clock.total, .delta = window.clock.delta },
        )!;
    }
}

fn int main(String[] args) {
    Options options = { .anti_aliasing = AntiAliasing.TAA };
    foreach (argument : args[1..]) {
        switch (argument) {
            case "--gpu-timings":
                $if $feat(C3D_PROFILE_GPU):
                    options.gpu_timings = true;
                $else
                    io::eprintfn("--gpu-timings needs GPU profiling: c3c build <target> --path examples --lib c3d_profile -D C3D_PROFILE_GPU -D C3D_PROFILE_INTERNAL");
                    return 1;
                $endif
            case "--freeze": options.freeze = true;
            case "--sweep": options.sweep = true;
            case "--no-aa": options.anti_aliasing = AntiAliasing.NONE;
            case "--fxaa": options.anti_aliasing = AntiAliasing.FXAA;
            case "--debug-velocity": options.debug = TaaDebug.VELOCITY;
            case "--debug-rejection": options.debug = TaaDebug.REJECTION;
            case "--debug-weight": options.debug = TaaDebug.HISTORY_WEIGHT;
            default:
                io::printfn("Unknown argument: %s", argument);
                return 1;
        }
    }

    platform::Window window = platform::create_window(platform::default_window_desc("c3d taa", 1280, 720))!!;
    defer platform::destroy_window(&window);

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      { .gpu_timings = options.gpu_timings, .validation = true, .application_name = "c3d_taa" },
    )!!;
    defer render::destroy_renderer(&renderer);

    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    Movers movers = build_scene(&assets, &scene)!!;
    Node* camera_node = scene.add_camera(camera::perspective_deg(55, 0.1f), name: "camera")!!;

    if (catch excuse = run(
        window:      &window,
        renderer:    &renderer,
        assets:      &assets,
        scene:       &scene,
        movers:      &movers,
        camera_node: camera_node,
        options:     options,
    )) {
        io::printfn("TAA example failed: %s", excuse);
        return 1;
    }
    return 0;
}
