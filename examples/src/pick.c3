module pick_example;

import std::io;
import std::io::path;
import std::math;
import c3d;
import c3d::anim;
import c3d::asset;
import c3d::asset::gltf;
import c3d::asset::image;
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
import c3d::spatial;
import imgui;
import sdl;

const float ORBIT_RADIANS_PER_PIXEL @local = 0.005f;
const float ORBIT_PITCH_LIMIT @local = 1.5f; // avoids the poles, where the up vector degenerates
const float ORBIT_ZOOM_STEP @local = 0.9f;
const float ORBIT_DISTANCE_MIN @local = 0.5f;
const float ORBIT_DISTANCE_MAX @local = 60;
const float MODEL_SCALE @local = 0.02f; // the fox is authored in centimetres
const float INSTANCE_SPACING @local = 3;
const float GROUND_SIZE @local = 20;
const float SUN_INTENSITY @local = 2.5f;
const float ENVIRONMENT_INTENSITY @local = 0.5f;
const float BACKGROUND_INTENSITY @local = 0.3f;
const float SELECTED_AXES_SIZE @local = 0.6f;
const float BOX_SIZE @local = 1;
const uint  SUN_CASCADES @local = 3;
const uint  MODEL_CAPACITY @local = 4;
const usz   MOUSE_BUTTON_LEFT @local = 1; // SDL button index
const uint  CAPTURE_SIZE @local = 512;
const float MONITOR_WIDTH @local = 1.6f;
const float MONITOR_HEIGHT @local = 1;
const float MONITOR_DEPTH @local = 0.06f;
const Vec3  MONITOR_POSITION @local = { 0, 1.7f, -3.4f };
const uint  MONITOR_LAYER @local = 2;
const Vec3  BOX_LEFT_POSITION @local = { -2.4f, BOX_SIZE * 0.5f, 0.7f };
const Vec3  BOX_RIGHT_POSITION @local = { 2.4f, BOX_SIZE * 0.5f, -0.5f };
const Vec4  BOX_LEFT_COLOR @local = { 0.85f, 0.25f, 0.2f, 1 };
const Vec4  BOX_RIGHT_COLOR @local = { 0.2f, 0.45f, 0.9f, 1 };
const String MODEL_FILE @local = "../assets/gltf/Fox.glb";
const String ENVIRONMENT_FILE @local = "../assets/ibl/studio_small_09_1k.hdr";
const Vec2 PICK_PANEL_POSITION @local = { 16, 16 };
const Vec2 PICK_PANEL_SIZE @local = { 360, 280 };
const Vec2 SCENE_PANEL_POSITION @local = { 16, 308 };
const Vec2 SCENE_PANEL_SIZE @local = { 360, 400 };
const Vec2 STATS_PANEL_POSITION @local = { 1080, 16 };
const Vec2 STATS_PANEL_SIZE @local = { 340, 420 };

struct Orbit @local {
    Vec3  target;
    float distance;
    float yaw;
    float pitch;
}

struct Capture @local {
    RenderTargetId target;
    ViewId         view;
}

struct PickState @local {
    bool  valid;
    Node* node;
    float distance;
    Vec3  position;
    bool  triangle_hit;
    uint  hits;
    uint  triangle_index;
    bool  instanced;
    uint  instance_index;
    Ray   ray;
}

fn void apply_orbit(Orbit* orbit, Input* input, Node* camera_node) @local {
    if (!input.mouse_captured_by_gui) {
        if (input.mouse_buttons[MOUSE_BUTTON_LEFT]) {
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

fn void forward_gui_event(sdl::Event* event, void* user) @local {
    GuiRenderer* gui_renderer = (GuiRenderer*)user;
    gui_renderer.process_event(event);
}

fn Ray view_ray(
    Scene* scene,
    Node* camera_node,
    ViewDesc desc,
    platform::Window* window,
    Vec2 output_pixel,
) @local {
    PixelRect viewport = desc.viewport;
    Vec2 extent = viewport.width && viewport.height
        ? (Vec2){ (float)viewport.width, (float)viewport.height }
        : (Vec2){ (float)window.width, (float)window.height };
    Vec2 pixel = {
        output_pixel.x - (float)viewport.x,
        output_pixel.y - (float)viewport.y,
    };

    CameraMatrices matrices = camera::derive_matrices(
        camera:       *scene.get(camera_node, camera::Camera),
        camera_world: camera_node.world,
        viewport:     extent,
    );
    return camera::screen_to_ray(&matrices, pixel, extent);
}

fn PickState query(
    Scene* scene,
    AssetStore* assets,
    Ray ray,
    PickOptions options,
) @local {
    PickState state;
    @pool() {
        PickHit[] hits = spatial::pick(
            allocator: tmem,
            assets:    assets,
            scene:     scene,
            ray:       ray,
            options:   options,
        );

        state = { .valid = hits.len > 0, .hits = (uint)hits.len, .ray = ray };
        if (state.valid) {
            state.node = hits[0].node;
            state.distance = hits[0].distance;
            state.position = hits[0].position;
            state.triangle_hit = hits[0].triangle_hit;
            state.triangle_index = hits[0].triangle_index;
            record_instance_index(scene, hits[0].node, &state);
        }
    };
    return state;
}

fn void record_instance_index(Scene* scene, Node* node, PickState* state) @local {
    for (Node* current = node; current; current = current.parent) {
        if (ModelInstance* instance = scene.get(current, ModelInstance)) {
            foreach (index, entry : instance.nodes) {
                if (entry == node) {
                    state.instanced = true;
                    state.instance_index = (uint)index;
                    return;
                }
            }
            return;
        }
    }
}

fn Vec3 local_corner(GeometryAsset* record, uint triangle_index, uint corner) @local {
    usz index = (usz)(triangle_index * 3 + corner);
    return record.data.positions[record.data.indices.len ? record.data.indices[index] : index];
}

fn void fill_debug_lines(
    DebugDraw* debug,
    Scene* scene,
    AssetStore* assets,
    PickState* pick,
) @local {
    debug.clear();
    if (!pick.valid || !scene.world.is_alive(pick.node.id)) return;

    Mesh* mesh = scene.get(pick.node, Mesh);
    if (!mesh) return;

    if (mesh.has_bounds_override) {
        debug.box(pick.node.world, mesh.local_bounds, debug::COLOR_YELLOW);
    } else if (assets.geometries.is_live(mesh.geometry)) {
        debug.box(pick.node.world, assets.geometry(mesh.geometry).data.bounds, debug::COLOR_YELLOW);
    }

    debug.axes(matrix::IDENTITY4.translate(pick.position), SELECTED_AXES_SIZE);
    debug.line(pick.ray.origin, pick.ray.origin + pick.ray.direction * pick.distance, debug::COLOR_RED);

    if (pick.triangle_hit && assets.geometries.is_live(mesh.geometry)) {
        GeometryAsset* record = assets.geometry(mesh.geometry);
        Vec3[3] corners = {
            local_corner(record, pick.triangle_index, 0),
            local_corner(record, pick.triangle_index, 1),
            local_corner(record, pick.triangle_index, 2),
        };
        foreach (&corner : corners) *corner = maths::transform_point(pick.node.world, *corner);

        debug.line(corners[0], corners[1], debug::COLOR_GREEN);
        debug.line(corners[1], corners[2], debug::COLOR_GREEN);
        debug.line(corners[2], corners[0], debug::COLOR_GREEN);
    }
}

fn void? create_capture(
    render::Renderer* renderer,
    AssetStore* assets,
    MaterialId monitor,
    Capture* capture,
) @local {
    capture.target = render::create_render_target(renderer,
        render::render_target_desc(CAPTURE_SIZE, CAPTURE_SIZE, material::PixelFormat.RGBA8_SRGB))!;
    defer catch (void)render::destroy_render_target(renderer, capture.target);

    capture.view = render::create_view(renderer,
        render::texture_view_desc(capture.target, OutputMode.DISPLAY_LDR))!;

    assets.material(monitor).data.basic.map.texture = { .kind = RENDER_TARGET, .target = capture.target };
    assets.mark_material_dirty(monitor);
}

fn void? destroy_capture(render::Renderer* renderer, Capture* capture) @local {
    render::destroy_view(renderer, capture.view)!;
    return render::destroy_render_target(renderer, capture.target);
}

fn void? draw_gui_frame(
    render::Renderer* renderer,
    Scene* scene,
    Node* camera_node,
    Node* producer_node,
    Capture* capture,
    DebugDraw* debug,
    GuiRenderer* gui_renderer,
    FrameInfo info,
) @local {
    renderer.begin_frame(info)!;
    defer catch render::abort_frame(renderer);

    renderer.render_view(
        scene:       scene,
        camera_node: producer_node,
        view:        capture.view,
        debug:       debug,
    )!;
    if (renderer.has_output) {
        renderer.render_view(
            scene:       scene,
            camera_node: camera_node,
            view:        renderer.default_view,
            debug:       debug,
        )!;

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
    Node* camera_node,
    Node* producer_node,
    MaterialId monitor,
) @local {
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, renderer, window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);

    DebugDraw debug = debug::create_debug_draw(mem);
    defer debug::destroy_debug_draw(&debug);

    GuiPanelState panels = {};
    Capture capture;
    create_capture(
        renderer: renderer,
        assets:   assets,
        monitor:  monitor,
        capture:  &capture,
    )!;
    defer (void)destroy_capture(renderer, &capture);

    PickOptions options = spatial::PICK_OPTIONS_DEFAULT;
    PickState pick;
    Orbit orbit = { .target = { 0, 0.8f, 0 }, .distance = 9, .yaw = 0.5f, .pitch = 0.35f };
    ViewDesc window_desc = render::default_view_desc();
    bool left_was_down;
    bool escape_captured;

    apply_orbit(&orbit, &window.input, camera_node);
    scene.update_world();

    // Picking is pure CPU, so the first query answers before any frame is recorded.
    Vec2 center = { (float)window.width * 0.5f, (float)window.height * 0.5f };
    Ray startup_ray = view_ray(
        scene:        scene,
        camera_node:  camera_node,
        desc:         window_desc,
        window:       window,
        output_pixel: center,
    );
    pick = query(scene: scene, assets: assets, ray: startup_ray, options: options);
    if (pick.valid) {
        panels.selected = pick.node.id;
        io::printfn("pre-render pick: %s at %.3f m, %s", pick.node.name, (double)pick.distance,
            pick.triangle_hit ? "triangle" : "bound");
    } else {
        io::printn("pre-render pick: no hit");
    }

    while (window.poll(&forward_gui_event, &gui_renderer)) {
        bool keyboard_was_captured = window.input.keyboard_captured_by_gui;
        gui_renderer.new_frame();
        defer {
            if (gui_renderer.frame_open) gui_renderer.finish_frame();
        }

        Input* input = &window.input;
        // Text editing can drop capture on Escape down before its release arrives.
        if (input.keys_pressed[(usz)sdl::Scancode.ESCAPE] || input.keys_released[(usz)sdl::Scancode.ESCAPE]) {
            escape_captured |= keyboard_was_captured || input.keyboard_captured_by_gui;
        }
        if (input.keys_released[(usz)sdl::Scancode.ESCAPE]) {
            bool quit = !escape_captured;
            escape_captured = false;
            if (quit) break;
        }

        bool left_down = input.mouse_buttons[MOUSE_BUTTON_LEFT];
        if (left_down && !left_was_down && !input.mouse_captured_by_gui) {
            Ray ray = view_ray(
                scene:        scene,
                camera_node:  camera_node,
                desc:         window_desc,
                window:       window,
                output_pixel: input.mouse_position,
            );
            pick = query(scene: scene, assets: assets, ray: ray, options: options);
            if (pick.valid) panels.selected = pick.node.id;
        }
        left_was_down = left_down;

        imgui::set_next_window_pos(PICK_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(PICK_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        if (imgui::begin("Pick", null, {})) {
            imgui::text("Click a box or a fox; drag orbits, wheel zooms");
            imgui::separator_text("Precision");
            if (imgui::radio_button("Bounds", options.precision == PickPrecision.BOUNDS)) {
                options.precision = PickPrecision.BOUNDS;
            }
            if (imgui::radio_button("Triangles", options.precision == PickPrecision.TRIANGLES)) {
                options.precision = PickPrecision.TRIANGLES;
            }
            imgui::separator_text("Faces");
            if (imgui::radio_button("Material", options.faces == PickFaces.MATERIAL)) {
                options.faces = PickFaces.MATERIAL;
            }
            if (imgui::radio_button("Both", options.faces == PickFaces.BOTH)) {
                options.faces = PickFaces.BOTH;
            }
            if (imgui::radio_button("Front", options.faces == PickFaces.FRONT)) {
                options.faces = PickFaces.FRONT;
            }
            imgui::separator_text("Last query");
            if (pick.valid) {
                imgui::text("node: %s", pick.node.name);
                imgui::text("hits: %u, nearest %.3f m", pick.hits, (double)pick.distance);
                imgui::text("precision: %s", pick.triangle_hit ? "triangle" : "bound");
                if (pick.instanced) {
                    imgui::text("model instance, template node %u", pick.instance_index);
                }
                if (pick.triangle_hit) {
                    imgui::text("triangle %u", pick.triangle_index);
                }
            } else {
                imgui::text("no hit");
            }
        }
        imgui::end();

        apply_orbit(&orbit, input, camera_node);
        anim::update(assets, scene, (float)window.clock.delta);

        imgui::set_next_window_pos(SCENE_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(SCENE_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        gui::scene_panel(scene, &panels);

        imgui::set_next_window_pos(STATS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(STATS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        gui::stats_panel(renderer)!;

        scene.update_world();
        fill_debug_lines(
            debug:  &debug,
            scene:  scene,
            assets: assets,
            pick:   &pick,
        );
        gui_renderer.finish_frame();

        platform::sync_window(window, renderer);
        draw_gui_frame(
            renderer:      renderer,
            scene:         scene,
            camera_node:   camera_node,
            producer_node: producer_node,
            capture:       &capture,
            debug:         &debug,
            gui_renderer:  &gui_renderer,
            info:          { .time = window.clock.total, .delta = window.clock.delta },
        )!;
    }
}

fn int main(String[] args) {
    bool gpu_timings;
    foreach (argument : args[1..]) {
        if (argument == "--gpu-timings") {
            gpu_timings = true;
        } else {
            io::printfn("Unknown argument: %s", argument);
            return 1;
        }
    }

    platform::Window window = platform::create_window(
        platform::default_window_desc("c3d pick", 1440, 900))!!;
    defer platform::destroy_window(&window);

    AssetStoreDesc store_desc = asset::default_asset_store_desc();
    store_desc.max_models = MODEL_CAPACITY;
    AssetStore assets = asset::create_asset_store(mem, store_desc);
    defer asset::destroy_asset_store(&assets);

    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      { .gpu_timings = gpu_timings, .validation = true, .application_name = "c3d_pick" },
    )!!;
    defer render::destroy_renderer(&renderer);

    String model_path = example_path(MODEL_FILE);
    ModelId model;
    if (catch excuse = gltf::load_model(&assets, model_path)) {
        io::printfn("Loading %s failed: %s", model_path, excuse);
        return 1;
    } else {
        model = assets.find_model(model_path)!!;
    }
    TextureId studio = image::load_hdr(&assets, example_path(ENVIRONMENT_FILE), "pick/environment_source")!!;
    EnvironmentId environment = assets.add_environment(
        light::texture_environment(studio), "pick/environment")!!;
    renderer.upload_environment(environment)!!;

    GeometryId box;
    GeometryId ground_geometry;
    GeometryId monitor_geometry;
    @pool() {
        Geometry box_data = geometry::box(
            allocator: tmem,
            width:     BOX_SIZE,
            height:    BOX_SIZE,
            depth:     BOX_SIZE,
        );
        box = assets.add_geometry(&box_data, "pick/box")!!;

        Geometry ground_data = geometry::plane(tmem, GROUND_SIZE, GROUND_SIZE);
        ground_geometry = assets.add_geometry(&ground_data, "pick/ground")!!;

        Geometry monitor_data = geometry::box(
            allocator: tmem,
            width:     MONITOR_WIDTH,
            height:    MONITOR_HEIGHT,
            depth:     MONITOR_DEPTH,
        );
        monitor_geometry = assets.add_geometry(&monitor_data, "pick/monitor")!!;
    };
    MaterialId left_material = assets.add_material(
        material::standard({ .base_color = BOX_LEFT_COLOR, .metallic = 0, .roughness = 0.5f }),
        "pick/left_material",
    )!!;
    MaterialId right_material = assets.add_material(
        material::standard({ .base_color = BOX_RIGHT_COLOR, .metallic = 0, .roughness = 0.5f }),
        "pick/right_material",
    )!!;
    MaterialId ground_material = assets.add_material(material::standard({
        .base_color = { 0.62f, 0.64f, 0.68f, 1 },
        .metallic   = 0,
        .roughness  = 0.82f,
    }), "pick/ground_material")!!;
    // The capture target is bound once the renderer has created it; the sampler clamps the screen edges.
    MaterialId monitor_material = assets.add_material(
        material::basic({
            .color = { 1, 1, 1, 1 },
            .map   = material::texture_slot(sampler: asset::SAMPLER_LINEAR_CLAMP),
        }),
        "pick/monitor_material",
    )!!;

    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    scene.environment = environment;
    scene.environment_intensity = ENVIRONMENT_INTENSITY;
    scene.background = scene::BACKGROUND_DEFAULT;
    scene.background.kind = BackgroundKind.ENVIRONMENT;
    scene.background.environment = environment;
    scene.background.intensity = BACKGROUND_INTENSITY;

    Node* ground = scene.add_mesh(ground_geometry, ground_material, name: "ground")!!;
    ground.local.position = { 0, -0.001f, 0 };

    Node* left_box = scene.add_mesh(box, left_material, name: "box_left")!!;
    left_box.local.position = BOX_LEFT_POSITION;
    Node* right_box = scene.add_mesh(box, right_material, name: "box_right")!!;
    right_box.local.position = BOX_RIGHT_POSITION;

    Node* first = model::instantiate(
        assets: &assets,
        scene:  &scene,
        model:  model,
        name:   "fox_left",
    )!!;
    Node* second = model::instantiate(
        assets: &assets,
        scene:  &scene,
        model:  model,
        name:   "fox_right",
    )!!;
    first.local.position = { -INSTANCE_SPACING * 0.5f, 0, 0 };
    second.local.position = { INSTANCE_SPACING * 0.5f, 0, 0 };
    first.local.scale = { MODEL_SCALE, MODEL_SCALE, MODEL_SCALE };
    second.local.scale = { MODEL_SCALE, MODEL_SCALE, MODEL_SCALE };
    ClipId[] clips = scene.get(second, ModelInstance).clips;
    anim::add_animator(&scene, second);
    if (clips.len) scene.get(second, Animator).play(&assets, clips[0])!!;

    Node* monitor = scene.add_mesh(monitor_geometry, monitor_material, name: "monitor")!!;
    monitor.local.position = MONITOR_POSITION;
    monitor.local.rotation = maths::look_rotation({ 0, 0, 1 }, { 0, 1, 0 });
    monitor.layers = MONITOR_LAYER;

    Light sun = light::directional({ 1, 0.95f, 0.85f }, SUN_INTENSITY);
    sun.shadow.cascades = SUN_CASCADES;
    Node* sun_node = scene.add_light(sun, name: "sun")!!;
    sun_node.local.rotation = maths::look_rotation((Vec3){ -0.5f, -1, -0.6f }.normalize(), { 0, 1, 0 });

    Node* camera_node = scene.add_camera(camera::perspective_deg(50, 0.05f), name: "camera")!!;
    Node* producer_node = scene.add_camera(camera::perspective_deg(50, 0.05f), name: "producer")!!;
    producer_node.local.position = { 6, 4, 6 };
    producer_node.local.rotation = maths::look_rotation((Vec3){ -6, -3.2f, -6 }.normalize(), { 0, 1, 0 });
    scene.get(producer_node, camera::Camera).layers = scene::DEFAULT_LAYERS;

    scene.update_world();
    renderer.prepare_scene(&scene)!!;

    io::printn("click to pick, drag to orbit, wheel to zoom, Escape release quits");
    if (catch excuse = run_gui(
        window:        &window,
        renderer:      &renderer,
        assets:        &assets,
        scene:         &scene,
        camera_node:   camera_node,
        producer_node: producer_node,
        monitor:       monitor_material,
    )) {
        io::printfn("GUI failed: %s", excuse);
        return 1;
    }

    io::printfn("closed after %d frames, %.2fs", window.clock.frame, window.clock.total);
    return 0;
}
