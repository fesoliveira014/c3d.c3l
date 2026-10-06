module views_example;

import std::io;
import std::math;
import c3d;
import c3d::asset;
import c3d::asset::image;
import c3d::camera;
import c3d::geometry;
import c3d::gui;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::platform;
import c3d::render;
import c3d::render::post;
import c3d::scene;
import c3d::shader::compile;
import imgui;

const float ORBIT_RADIANS_PER_PIXEL @local = 0.005f;
const float ORBIT_PITCH_LIMIT @local = 1.5f; // just short of the poles, where the up vector degenerates
const float ORBIT_ZOOM_STEP @local = 0.9f;
const float ORBIT_DISTANCE_MIN @local = 1.0f;
const float ORBIT_DISTANCE_MAX @local = 50.0f;
const float SPIN_RADIANS_PER_SECOND @local = 0.6f;
const float PRODUCER_RADIANS_PER_SECOND @local = 0.35f;
const float PRODUCER_DISTANCE @local = 4.5f;
const float PRODUCER_HEIGHT @local = 1.6f;
const float CUBE_ROLL_DEGREES @local = 30;
const float CUBE_SIZE @local = 1.6f;
const float SPHERE_RADIUS @local = 0.7f;
const float SPHERE_OFFSET @local = 1.9f;
const float GROUND_SIZE @local = 14;
const float GROUND_LEVEL @local = -1.2f;
const float MONITOR_WIDTH @local = 3.6f;
const float MONITOR_HEIGHT @local = 3.6f;
const float MONITOR_DEPTH @local = 0.08f;
const Vec3 MONITOR_POSITION @local = { 0, 1.4f, -4.5f };
const float SUN_INTENSITY @local = 6;
const float EMISSIVE_STRENGTH @local = 4;
const float AMBIENT_INTENSITY @local = 0.1f;
const float RENDER_SCALE_MIN @local = 0.25f;
const uint MONITOR_LAYER @local = 2; // the producer camera renders layer 1 only, so it never sees its own output
const uint MIRROR_LAYER @local = 4; // the mirror camera never draws the surface that samples its target
const uint MAX_VIEWS @local = 32; // room for an editor's viewports and thumbnails; the example uses three of them
const uint MAX_RENDER_TARGETS @local = 64; // one texture each; the example uses two
const Plane GROUND_PLANE @local = { .normal = { 0, 1, 0 }, .d = -GROUND_LEVEL };
const Vec4 CONCRETE_COLOR @local = { 0.5f, 0.5f, 0.52f, 1 };
const float CONCRETE_ROUGHNESS @local = 0.9f;
const float MIRROR_REFLECTANCE_DEFAULT @local = 0.5f; // the reflection reads clearly over the lit concrete
const Vec3 SUNK_SPHERE_POSITION @local = { 0, GROUND_LEVEL, 2.2f };
const Vec3 BURIED_CRATE_POSITION @local = { -2.5f, GROUND_LEVEL - 1.2f, 1.5f }; // top 0.4 m under the floor
const char[*] MIRROR_FRAGMENT_SOURCE @local = $embed("../shaders/custom/mirror.frag.glsl");
const uint[3] CAPTURE_SIZES @local = { 256, 512, 1024 };
const ZString[3] CAPTURE_SIZE_LABELS @local = { "256", "512", "1024" };
const ZString[3] VIEW_LABELS @local = { "Window", "Capture", "Mirror" };
const Vec2 CONTROLS_PANEL_POSITION @local = { 16, 16 };
const Vec2 CONTROLS_PANEL_SIZE @local = { 360, 340 };
const Vec2 POST_PANEL_POSITION @local = { 16, 372 };
const Vec2 POST_PANEL_SIZE @local = { 360, 330 };
const Vec2 VIEW_STATS_PANEL_POSITION @local = { 392, 16 };
const Vec2 VIEW_STATS_PANEL_SIZE @local = { 490, 240 };
const Vec2 STATS_PANEL_POSITION @local = { 900, 16 };
const Vec2 STATS_PANEL_SIZE @local = { 360, 660 };

struct Orbit @local {
    Vec3  target;
    float distance;
    float yaw;
    float pitch;
}

struct Capture @local {
    RenderTargetId target;
    ViewId         view;
    ViewDesc       desc;
    int            size_index;
    bool           hdr;
}

struct MirrorBlock @local {
    Vec4     base_color;
    float    reflectance;
    float    roughness;
    float[2] padding;
}
$assert MirrorBlock::size == 32;

struct Mirror @local {
    RenderTargetId target;
    ViewId         view;
    ViewDesc       desc;
    MaterialId     material;
    bool           clipped;
    float          reflectance;
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

fn void place_producer(Node* producer_node, double time) @local {
    float yaw = (float)time * PRODUCER_RADIANS_PER_SECOND;
    Vec3 offset = { math::sin(yaw) * PRODUCER_DISTANCE, PRODUCER_HEIGHT, math::cos(yaw) * PRODUCER_DISTANCE };
    producer_node.local.position = offset;
    producer_node.local.rotation = maths::look_rotation(-offset.normalize(), { 0, 1, 0 });
}

fn void? create_capture(
    render::Renderer* renderer,
    AssetStore* assets,
    MaterialId monitor,
    Capture* capture,
) @local {
    uint size = CAPTURE_SIZES[capture.size_index];
    material::PixelFormat format = capture.hdr ? material::PixelFormat.RGBA16_FLOAT : material::PixelFormat.RGBA8_SRGB;
    capture.target = render::create_render_target(renderer, render::render_target_desc(size, size, format))!;
    defer catch (void)render::destroy_render_target(renderer, capture.target);

    capture.desc.output = ViewOutput.TEXTURE;
    capture.desc.target = capture.target;
    capture.desc.color = capture.hdr ? OutputMode.LINEAR_HDR : OutputMode.DISPLAY_LDR;
    capture.view = render::create_view(renderer, capture.desc)!;

    assets.material(monitor).data.basic.map.texture = { .kind = RENDER_TARGET, .target = capture.target };
    assets.mark_material_dirty(monitor);
}

fn void? destroy_capture(render::Renderer* renderer, Capture* capture) @local {
    render::destroy_view(renderer, capture.view)!;
    return render::destroy_render_target(renderer, capture.target);
}

fn void? place_mirror(
    Scene* scene,
    Node* camera_node,
    Node* mirror_node,
    float aspect,
) @local {
    Mat4 mirrored = maths::reflection_matrix(GROUND_PLANE).mul(camera_node.local.to_mat4());
    mirror_node.local = maths::transform_from_affine(mirrored)!;
    scene.get(mirror_node, camera::Camera).aspect = aspect;
    scene.get(camera_node, camera::Camera).aspect = aspect;
}

fn void? create_mirror(render::Renderer* renderer, AssetStore* assets, Mirror* mirror) @local {
    mirror.target = render::create_render_target(
        renderer,
        render::render_target_desc(renderer.output_width / 2, renderer.output_height / 2),
    )!;
    defer catch (void)render::destroy_render_target(renderer, mirror.target);

    mirror.desc = render::texture_view_desc(mirror.target);
    mirror.desc.post.anti_aliasing = AntiAliasing.NONE;
    mirror.desc.clip_plane = GROUND_PLANE;
    mirror.view = render::create_view(renderer, mirror.desc)!;

    assets.material(mirror.material).data.custom.slots[0].texture = { .kind = RENDER_TARGET, .target = mirror.target };
    assets.mark_material_dirty(mirror.material);
}

fn void? destroy_mirror(render::Renderer* renderer, Mirror* mirror) @local {
    render::destroy_view(renderer, mirror.view)!;
    return render::destroy_render_target(renderer, mirror.target);
}

fn ShaderId? add_mirror_shader(AssetStore* assets) @local {
    ShaderId shader;
    @pool() {
        ShaderDesc desc = {
            .fragment = compile::compile_glsl(
                allocator:  tmem,
                source:     (String)MIRROR_FRAGMENT_SOURCE[..],
                stage:      ShaderStage.FRAGMENT,
                debug_name: "mirror.frag",
            )!,
            .param_block_size = MirrorBlock::size,
        };
        shader = assets.add_shader(&desc, "views/mirror")!;
    };
    return shader;
}

fn void? draw_gui_frame(
    render::Renderer* renderer,
    Scene* scene,
    Node* camera_node,
    Node* producer_node,
    Node* mirror_node,
    ViewId capture_view,
    ViewId mirror_view,
    GuiRenderer* gui_renderer,
    FrameInfo info,
) @local {
    renderer.begin_frame(info)!;
    defer catch render::abort_frame(renderer);

    renderer.render_view(scene, producer_node, capture_view)!;
    renderer.finish_view(capture_view)!;
    if (renderer.has_output) {
        renderer.render_view(
            scene:         scene,
            camera_node:   mirror_node,
            view:          mirror_view,
            shadow_camera: camera_node,
        )!;
        renderer.finish_view(mirror_view)!;
        renderer.render_view(scene, camera_node, renderer.default_view)!;
        renderer.finish_view(renderer.default_view)!;

        OverlayContext overlay = renderer.begin_overlay()!;
        gui_renderer.record(&overlay)!;
        renderer.end_overlay(&overlay)!;
    }

    return renderer.end_frame();
}

fn void? run_gui(
    platform::Window* window,
    render::Renderer* renderer,
    AssetStore* assets,
    Scene* scene,
    Node* cube,
    Node* camera_node,
    Node* producer_node,
    Node* mirror_node,
    MaterialId monitor,
    MaterialId mirror_floor,
) @local {
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, renderer, window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);

    Orbit orbit = { .distance = 8, .pitch = 0.3f };
    ViewDesc window_desc = render::default_view_desc();
    Capture capture = { .desc = render::default_view_desc(), .size_index = 1 };
    create_capture(renderer, assets, monitor, &capture)!;
    defer (void)destroy_capture(renderer, &capture);
    Mirror mirror = { .material = mirror_floor, .clipped = true, .reflectance = MIRROR_REFLECTANCE_DEFAULT };
    create_mirror(renderer, assets, &mirror)!;
    defer (void)destroy_mirror(renderer, &mirror);
    renderer.prepare_scene(scene)!;

    Quat roll = quaternion::from_axis_angle{float}({ 0, 0, 1 }, math::deg_to_rad(CUBE_ROLL_DEGREES));
    float spin_angle;
    bool spin = true;
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

        bool window_changed;
        bool capture_changed;
        bool capture_recreate;
        bool capture_resize;
        bool mirror_changed;
        bool reflectance_changed;
        imgui::set_next_window_pos(CONTROLS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(CONTROLS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        if (imgui::begin("Views", null, {})) {
            imgui::checkbox("Spin", &spin);
            imgui::separator_text("Window view");
            window_changed |= imgui::slider_float_ex(
                label:  "Render scale",
                v:      &window_desc.render_scale,
                v_min:  RENDER_SCALE_MIN,
                v_max:  render::MAX_RENDER_SCALE,
                format: "%.2f",
                flags:  imgui::SLIDER_FLAGS_ALWAYS_CLAMP,
            );
            imgui::separator_text("Capture view");
            capture_resize |= imgui::combo_char(
                label:         "Size",
                current_item:  &capture.size_index,
                items:         &CAPTURE_SIZE_LABELS[0],
                items_count:   CAPTURE_SIZES.len,
            );
            if (imgui::radio_button("Display LDR, sRGB target", !capture.hdr)) {
                capture.hdr = false;
                capture_recreate = true;
            }
            if (imgui::radio_button("Linear HDR, float target", capture.hdr)) {
                capture.hdr = true;
                capture_recreate = true;
            }
            capture_changed |= gui::anti_aliasing_combo("Anti-aliasing", &capture.desc.post.anti_aliasing);
            capture_changed |= imgui::checkbox("Bloom", &capture.desc.post.bloom);
            imgui::separator_text("Mirror floor");
            mirror_changed |= imgui::checkbox("Clip plane", &mirror.clipped);
            mirror_changed |= imgui::slider_float_ex(
                label:  "Render scale##mirror",
                v:      &mirror.desc.render_scale,
                v_min:  RENDER_SCALE_MIN,
                v_max:  render::MAX_RENDER_SCALE,
                format: "%.2f",
                flags:  imgui::SLIDER_FLAGS_ALWAYS_CLAMP,
            );
            reflectance_changed = imgui::slider_float_ex(
                label:  "Reflectance",
                v:      &mirror.reflectance,
                v_min:  0,
                v_max:  1,
                format: "%.2f",
                flags:  imgui::SLIDER_FLAGS_ALWAYS_CLAMP,
            );
        }
        imgui::end();

        imgui::set_next_window_pos(VIEW_STATS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(VIEW_STATS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        ViewId[3] views = { renderer.default_view, capture.view, mirror.view };
        if (imgui::begin("View stats", null, {})) gui::view_stats_table(renderer, views[..], VIEW_LABELS[..]);
        imgui::end();

        imgui::set_next_window_pos(POST_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(POST_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        window_changed |= gui::post_panel(&window_desc, {});

        imgui::set_next_window_pos(STATS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(STATS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        gui::stats_panel(renderer)!;

        if (spin) spin_angle += window.clock.delta * SPIN_RADIANS_PER_SECOND;
        Quat yaw = quaternion::from_axis_angle{float}({ 0, 1, 0 }, spin_angle);
        cube.local.rotation = yaw.mul(roll).normalize();
        apply_orbit(&orbit, input, camera_node);
        place_producer(producer_node, window.clock.total);
        place_mirror(
            scene:       scene,
            camera_node: camera_node,
            mirror_node: mirror_node,
            aspect:      (float)renderer.output_width / (float)renderer.output_height,
        )!;

        scene.update_world();
        gui_renderer.finish_frame();

        platform::sync_window(window, renderer);
        if (window_changed) render::configure_view(renderer, renderer.default_view, window_desc)!;
        if (capture_recreate) {
            destroy_capture(renderer, &capture)!;
            create_capture(renderer, assets, monitor, &capture)!;
        } else if (capture_resize) {
            uint size = CAPTURE_SIZES[capture.size_index];
            render::resize_render_target(renderer, capture.target, size, size)!;
        } else if (capture_changed) {
            render::configure_view(renderer, capture.view, capture.desc)!;
        }
        if (mirror_changed) {
            mirror.desc.clip_plane = mirror.clipped ? GROUND_PLANE : (Plane){};
            render::configure_view(renderer, mirror.view, mirror.desc)!;
        }
        if (reflectance_changed) {
            assets.@custom_params(mirror.material, MirrorBlock).reflectance = mirror.reflectance;
            assets.mark_material_dirty(mirror.material);
        }
        draw_gui_frame(
            renderer:      renderer,
            scene:         scene,
            camera_node:   camera_node,
            producer_node: producer_node,
            mirror_node:   mirror_node,
            capture_view:  capture.view,
            mirror_view:   mirror.view,
            gui_renderer:  &gui_renderer,
            info:          { .time = window.clock.total, .delta = window.clock.delta },
        )!;
    }
}

fn int main(String[] args) {
    bool gpu_timings;

    foreach (argument : args[1..]) {
        if (argument == "--gpu-timings") {
            $if $feat(C3D_PROFILE_GPU):
                gpu_timings = true;
            $else
                io::eprintfn("--gpu-timings needs GPU profiling: c3c build <target> --path examples --lib c3d_profile -D C3D_PROFILE_GPU -D C3D_PROFILE_INTERNAL");
                return 1;
            $endif
        } else {
            io::printfn("Unknown argument: %s", argument);
            return 1;
        }
    }

    platform::Window window = platform::create_window(
        platform::default_window_desc("c3d views", 1280, 720))!!;
    defer platform::destroy_window(&window);

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      {
            .gpu_timings        = gpu_timings,
            .validation         = true,
            .application_name   = "c3d_views",
            .max_views          = MAX_VIEWS,
            .max_render_targets = MAX_RENDER_TARGETS,
        },
    )!!;
    defer render::destroy_renderer(&renderer);

    Image decoded = image::decode_image(mem, $embed("../assets/texture.png"))!!;
    defer image::destroy_image(&decoded);
    TextureId image_texture = assets.add_texture(
        material::texture_2d_desc(decoded.width, decoded.height, RGBA8_SRGB),
        decoded.pixels,
        "views/texture",
    )!!;

    GeometryId box;
    GeometryId ball;
    GeometryId ground;
    GeometryId screen;
    @pool() {
        Geometry box_geometry = geometry::box(tmem, CUBE_SIZE, CUBE_SIZE, CUBE_SIZE);
        box = assets.add_geometry(&box_geometry, "views/box")!!;

        Geometry ball_geometry = geometry::sphere(tmem, SPHERE_RADIUS);
        ball = assets.add_geometry(&ball_geometry, "views/sphere")!!;

        Geometry ground_geometry = geometry::plane(tmem, GROUND_SIZE, GROUND_SIZE);
        ground = assets.add_geometry(&ground_geometry, "views/ground")!!;

        Geometry screen_geometry = geometry::box(tmem, MONITOR_WIDTH, MONITOR_HEIGHT, MONITOR_DEPTH);
        screen = assets.add_geometry(&screen_geometry, "views/screen")!!;
    };

    MaterialId textured = assets.add_material(
        material::basic({ .color = { 1, 1, 1, 1 }, .map = material::texture_slot(image_texture) }),
        "views/textured",
    )!!;
    MaterialId chrome = assets.add_material(
        material::standard({ .base_color = { 0.9f, 0.9f, 0.9f, 1 }, .metallic = 1, .roughness = 0.25f }),
        "views/chrome",
    )!!;
    MaterialId lamp = assets.add_material(
        material::standard({
            .base_color        = { 0.2f, 0.2f, 0.2f, 1 },
            .roughness         = 0.6f,
            .emissive          = { 1, 0.6f, 0.2f },
            .emissive_strength = EMISSIVE_STRENGTH,
        }),
        "views/lamp",
    )!!;
    ShaderId mirror_shader = add_mirror_shader(&assets)!!;
    MirrorBlock floor_block = {
        .base_color  = CONCRETE_COLOR,
        .reflectance = MIRROR_REFLECTANCE_DEFAULT,
        .roughness   = CONCRETE_ROUGHNESS,
    };
    // The mirror target is bound once the renderer has created it.
    TextureSlot[material::MAX_CUSTOM_TEXTURE_SLOTS] floor_slots = material::CUSTOM_SLOTS_DEFAULT;
    floor_slots[0].sampler = asset::SAMPLER_LINEAR_CLAMP;
    floor_slots[0].texture.kind = RENDER_TARGET;
    MaterialId mirror_floor = assets.add_material(
        material::custom(mirror_shader, material::@as_bytes(floor_block), floor_slots),
        "views/mirror_floor",
    )!!;
    // The capture target is bound once the renderer has created it; the sampler clamps the screen edges.
    MaterialId monitor = assets.add_material(
        material::basic({
            .color = { 1, 1, 1, 1 },
            .map   = material::texture_slot(sampler: asset::SAMPLER_LINEAR_CLAMP),
        }),
        "views/monitor",
    )!!;

    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    scene.ambient_intensity = AMBIENT_INTENSITY;

    Node* cube = scene.add_mesh(box, textured, name: "cube")!!;
    Node* chrome_sphere = scene.add_mesh(ball, chrome, name: "chrome")!!;
    chrome_sphere.local.position = { SPHERE_OFFSET, 0, 0 };
    Node* lamp_sphere = scene.add_mesh(ball, lamp, name: "lamp")!!;
    lamp_sphere.local.position = { -SPHERE_OFFSET, 0, 0 };
    Node* sunk_sphere = scene.add_mesh(ball, chrome, name: "sunk_chrome")!!;
    sunk_sphere.local.position = SUNK_SPHERE_POSITION;
    Node* crate = scene.add_mesh(box, textured, name: "buried_crate")!!;
    crate.local.position = BURIED_CRATE_POSITION;
    Node* floor = scene.add_mesh(ground, mirror_floor, name: "ground")!!;
    floor.local.position = { 0, GROUND_LEVEL, 0 };
    // The mirror target is registered to the window view's pixels; no other camera may draw the ground.
    floor.layers = MIRROR_LAYER;
    Node* screen_node = scene.add_mesh(screen, monitor, name: "monitor")!!;
    screen_node.local.position = MONITOR_POSITION;
    screen_node.layers = MONITOR_LAYER;
    Node* sun = scene.add_light(light::directional({ 1, 1, 1 }, SUN_INTENSITY), name: "sun")!!;
    sun.local.rotation = maths::look_rotation((Vec3){ 0.4f, -0.7f, -0.6f }.normalize(), { 0, 1, 0 });
    Node* camera_node = scene.add_camera(camera::perspective_deg(60, 0.1f), name: "camera")!!;
    Node* producer_node = scene.add_camera(camera::perspective_deg(50, 0.1f), name: "producer")!!;
    scene.get(producer_node, camera::Camera).layers = scene::DEFAULT_LAYERS;
    Node* mirror_node = scene.add_camera(camera::perspective_deg(60, 0.1f), name: "mirror")!!;
    scene.get(mirror_node, camera::Camera).layers = camera::ALL_LAYERS & ~MIRROR_LAYER;

    if (catch excuse = run_gui(
        window:        &window,
        renderer:      &renderer,
        assets:        &assets,
        scene:         &scene,
        cube:          cube,
        camera_node:   camera_node,
        producer_node: producer_node,
        mirror_node:   mirror_node,
        monitor:       monitor,
        mirror_floor:  mirror_floor,
    )) {
        io::printfn("GUI failed: %s", excuse);
        return 1;
    }

    return 0;
}
