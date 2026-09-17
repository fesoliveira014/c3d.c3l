module picking_example;

import std::io;
import std::io::path;
import std::math;
import c3d;
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
import c3d::spatial;
import imgui;

const float ORBIT_RADIANS_PER_PIXEL @local = 0.005f;
const float ORBIT_PITCH_LIMIT @local = 1.5f; // just short of the poles, where the up vector degenerates
const float ORBIT_ZOOM_STEP @local = 0.9f;
const float ORBIT_DISTANCE_MIN @local = 1.0f;
const float ORBIT_DISTANCE_MAX @local = 60.0f;
const float ORBIT_DISTANCE_SCALE @local = 3.5f; // starting distance in model radii; frames both instances and the boxes
const float INSTANCE_GAP_SCALE @local = 0.25f; // gap between instances in model widths
const float BOX_SIZE @local = 1;
const float BOX_TURN_DEGREES @local = 45;
const Vec3 BOX_SCALE @local = { 2, 1, 0.5f };
const Vec3 ROTATED_BOX_POSITION @local = { 0, 0.5f, 2 };
const Vec3 SCALED_BOX_POSITION @local = { 0, 0.5f, -3 };
const Vec3 PROBE_ORIGIN @local = { 0.25f, 0.5f, 10 }; // off-center, so the rotated box's face sits behind its bound
const Ray STARTUP_PROBE @local = { .origin = PROBE_ORIGIN, .direction = { 0, 0, -1 } };
const float GROUND_SIZE @local = 24;
const float MONITOR_WIDTH @local = 4;
const float MONITOR_HEIGHT @local = 4;
const float MONITOR_DEPTH @local = 0.1f;
const Vec3 MONITOR_POSITION @local = { 0, 2, -6 };
const Vec3 PRODUCER_POSITION @local = { 6, 4, 6 };
const uint MONITOR_LAYER @local = 2; // the producer camera renders layer 1 only, so it never sees its own output
const uint CAPTURE_SIZE @local = 512;
const uint MONITOR_FRONT_FACE @local = 4; // geometry::box face order: +X, -X, +Y, -Y, +Z, -Z
const uint TRIANGLES_PER_BOX_FACE @local = 2;
const float SUN_INTENSITY @local = 3;
const float AMBIENT_INTENSITY @local = 0.15f;
const Vec2 PICKING_PANEL_POSITION @local = { 16, 16 };
const Vec2 PICKING_PANEL_SIZE @local = { 380, 300 };
const Vec2 SCENE_PANEL_POSITION @local = { 16, 332 };
const Vec2 SCENE_PANEL_SIZE @local = { 380, 400 };
const String DEFAULT_MODEL @local = "../assets/gltf/BoxTextured.glb";

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
}

struct Selection @local {
    bool    valid;
    PickHit hit;
    Ray     ray;
    bool    through_monitor;
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

fn String example_path(String relative) @local {
    Path source = path::tnew($$FILEPATH)!!;
    return (String)source.parent()!!.tappend(relative)!!;
}

fn void print_hits(String label, PickHit[] hits) @local {
    io::printfn("%s: %d hit(s)", label, hits.len);
    foreach (hit : hits) {
        if (hit.triangle_hit) {
            io::printfn("  %s at %.3f, triangle %d", hit.node.name, hit.distance, hit.triangle_index);
        } else {
            io::printfn("  %s at %.3f, bounds", hit.node.name, hit.distance);
        }
    }
}

fn Node* instance_root(Scene* scene, Node* node) @local {
    for (Node* candidate = node; candidate != scene.root; candidate = candidate.parent) {
        if (scene.has(candidate, ModelInstance)) return candidate;
    }
    return null;
}

fn Vec2 interpolate_uv0(Geometry* geometry, uint triangle_index, Vec3 barycentric) @local {
    usz first = (usz)triangle_index * 3;
    uint[3] corners;
    for (usz corner = 0; corner < 3; corner++) {
        corners[corner] = geometry.indices.len ? geometry.indices[first + corner] : (uint)(first + corner);
    }
    return geometry.uv0[corners[0]] * barycentric.x
         + geometry.uv0[corners[1]] * barycentric.y
         + geometry.uv0[corners[2]] * barycentric.z;
}

fn Ray view_ray(
    Scene* scene,
    Node* camera_node,
    Vec2 pixel,
    Vec2 viewport,
) @local {
    camera::Camera* camera = scene.get(camera_node, camera::Camera);
    CameraMatrices matrices = camera::derive_matrices(*camera, camera_node.world, viewport);
    return camera::screen_to_ray(&matrices, pixel, viewport);
}

fn PickHit[] pick_with(AssetStore* assets, Scene* scene, Ray ray, PickOptions options) @local {
    return spatial::pick(
        allocator: tmem,
        assets:    assets,
        scene:     scene,
        ray:       ray,
        options:   options,
    );
}

fn Selection select_at(
    AssetStore* assets,
    Scene* scene,
    Node* camera_node,
    Node* producer_node,
    Node* monitor_node,
    Vec2 pixel,
    Vec2 viewport,
    PickOptions options,
) @local {
    Selection selection;
    selection.ray = view_ray(
        scene:       scene,
        camera_node: camera_node,
        pixel:       pixel,
        viewport:    viewport,
    );
    PickHit[] hits = pick_with(assets, scene, selection.ray, options);
    if (hits.len == 0) return selection;
    selection.valid = true;
    selection.hit = hits[0];

    if (hits[0].node != monitor_node) return selection;
    PickOptions monitor_options = options;
    monitor_options.precision = TRIANGLES;
    monitor_options.layers = MONITOR_LAYER;
    PickHit[] monitor_hits = pick_with(assets, scene, selection.ray, monitor_options);
    if (monitor_hits.len == 0) return selection;
    Mesh* monitor = scene.get(monitor_node, Mesh);
    Geometry* slab = &assets.geometry(monitor.geometry).data;
    Vec2 uv = interpolate_uv0(slab, monitor_hits[0].triangle_index, monitor_hits[0].barycentric);
    Vec2 capture_viewport = { CAPTURE_SIZE, CAPTURE_SIZE };
    Ray capture_ray = view_ray(
        scene:       scene,
        camera_node: producer_node,
        pixel:       uv * capture_viewport,
        viewport:    capture_viewport,
    );
    PickHit[] capture_hits = pick_with(assets, scene, capture_ray, options);
    if (capture_hits.len == 0) return selection;
    selection.hit = capture_hits[0];
    selection.ray = capture_ray;
    selection.through_monitor = true;
    return selection;
}

fn void picking_panel(Scene* scene, PickOptions* options, Selection* selection) @local {
    if (imgui::begin("Picking", null, {})) {
        imgui::separator_text("Precision");
        if (imgui::radio_button("Bounds", options.precision == BOUNDS)) options.precision = BOUNDS;
        imgui::same_line();
        if (imgui::radio_button("Triangles", options.precision == TRIANGLES)) options.precision = TRIANGLES;
        imgui::separator_text("Faces");
        if (imgui::radio_button("Material", options.faces == MATERIAL)) options.faces = MATERIAL;
        imgui::same_line();
        if (imgui::radio_button("Both", options.faces == BOTH)) options.faces = BOTH;
        imgui::same_line();
        if (imgui::radio_button("Front", options.faces == FRONT)) options.faces = FRONT;
        imgui::separator_text("Last pick");
        if (selection.valid) {
            PickHit* hit = &selection.hit;
            imgui::text("Node: %s", hit.node.name.zstr_tcopy());
            imgui::text("Distance: %.3f", (double)hit.distance);
            imgui::text("Precision: %s", hit.triangle_hit ? "triangle" : "bounds");
            if (hit.triangle_hit) {
                imgui::text("Triangle %d  barycentric (%.2f %.2f %.2f)", hit.triangle_index,
                    (double)hit.barycentric.x, (double)hit.barycentric.y, (double)hit.barycentric.z);
            }
            Node* root = instance_root(scene, hit.node);
            if (root) imgui::text("Instance: %s", root.name.zstr_tcopy());
            if (selection.through_monitor) imgui::text("Through monitor");
        } else {
            imgui::text("none");
        }
        imgui::text_wrapped("Left click selects; drag orbits; wheel zooms. A monitor click picks through its camera.");
    }
    imgui::end();
}

fn void? create_capture(
    render::Renderer* renderer,
    AssetStore* assets,
    MaterialId monitor,
    Capture* capture,
) @local {
    capture.target = render::create_render_target(
        renderer, render::render_target_desc(CAPTURE_SIZE, CAPTURE_SIZE, material::PixelFormat.RGBA8_SRGB))!;
    defer catch (void)render::destroy_render_target(renderer, capture.target);

    capture.desc = render::default_view_desc();
    capture.desc.output = ViewOutput.TEXTURE;
    capture.desc.target = capture.target;
    capture.desc.color = OutputMode.DISPLAY_LDR;
    capture.view = render::create_view(renderer, capture.desc)!;

    assets.material(monitor).data.basic.map.texture = { .kind = RENDER_TARGET, .target = capture.target };
    assets.mark_material_dirty(monitor);
}

fn void? destroy_capture(render::Renderer* renderer, Capture* capture) @local {
    render::destroy_view(renderer, capture.view)!;
    return render::destroy_render_target(renderer, capture.target);
}

fn void? draw_frame(
    render::Renderer* renderer,
    Scene* scene,
    Node* camera_node,
    Node* producer_node,
    ViewId capture_view,
    GuiRenderer* gui_renderer,
    DebugDraw* debug,
    FrameInfo info,
) @local {
    renderer.begin_frame(info)!;
    defer catch render::abort_frame(renderer);

    renderer.render_view(scene, producer_node, capture_view, debug)!;
    renderer.finish_view(capture_view)!;
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
    Node* camera_node,
    Node* producer_node,
    Node* monitor_node,
    MaterialId monitor,
    Orbit* orbit,
) @local {
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, renderer, window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);

    DebugDraw debug = debug::create_debug_draw(mem);
    defer debug::destroy_debug_draw(&debug);

    Capture capture;
    create_capture(renderer, assets, monitor, &capture)!;
    defer (void)destroy_capture(renderer, &capture);
    renderer.prepare_scene(scene)!;

    GuiPanelState panels;
    PickOptions options = spatial::PICK_OPTIONS_DEFAULT;
    Selection selection;
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

        imgui::set_next_window_pos(PICKING_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(PICKING_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        picking_panel(scene, &options, &selection);
        imgui::set_next_window_pos(SCENE_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(SCENE_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        gui::scene_panel(scene, &panels);

        if (input.button_pressed(platform::MouseButton.LEFT) && !input.mouse_captured_by_gui) {
            @pool() {
                selection = select_at(
                    assets:        assets,
                    scene:         scene,
                    camera_node:   camera_node,
                    producer_node: producer_node,
                    monitor_node:  monitor_node,
                    pixel:         input.mouse_position,
                    viewport:      { (float)window.width, (float)window.height },
                    options:       options,
                );
            };
            if (selection.valid) panels.selected = selection.hit.node.id;
        }
        if (selection.valid && !scene.world.is_alive(selection.hit.node.id)) selection = {};

        apply_orbit(orbit, input, camera_node);
        scene.update_world();

        debug.clear();
        if (scene.world.is_alive(panels.selected)) {
            Node* selected = scene.node(panels.selected);
            Mesh* mesh = scene.get(selected, Mesh);
            SkinBinding* skin = scene.get(selected, SkinBinding);
            if (mesh && spatial::mesh_is_live(assets, mesh, skin)) {
                Aabb bounds = spatial::mesh_world_bounds(
                    assets: assets,
                    node:   selected,
                    mesh:   mesh,
                    skin:   skin,
                );
                debug.aabb(bounds, debug::COLOR_YELLOW);
            }
        }
        if (selection.valid) debug.line(selection.ray.origin, selection.hit.position, debug::COLOR_GREEN);
        gui_renderer.finish_frame();

        platform::sync_window(window, renderer);
        draw_frame(
            renderer:      renderer,
            scene:         scene,
            camera_node:   camera_node,
            producer_node: producer_node,
            capture_view:  capture.view,
            gui_renderer:  &gui_renderer,
            debug:         &debug,
            info:          { .time = window.clock.total, .delta = window.clock.delta },
        )!;
    }
}

fn int main(String[] args) {
    bool gpu_timings;
    String model_path;
    foreach (argument : args[1..]) {
        if (argument == "--gpu-timings") {
            gpu_timings = true;
        } else if (!model_path.len && !argument.starts_with("--")) {
            model_path = argument;
        } else {
            io::printfn("Unknown argument: %s", argument);
            return 1;
        }
    }

    platform::Window window = platform::create_window(
        platform::default_window_desc("c3d picking", 1440, 900))!!;
    defer platform::destroy_window(&window);

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      { .gpu_timings = gpu_timings, .validation = true, .application_name = "c3d_picking" },
    )!!;
    defer render::destroy_renderer(&renderer);

    if (!model_path.len) model_path = example_path(DEFAULT_MODEL);
    ModelId model;
    if (catch excuse = gltf::load_model(&assets, model_path)) {
        io::printfn("Loading %s failed: %s", model_path, excuse);
        return 1;
    } else {
        model = assets.find_model(model_path)!!;
    }

    GeometryId box;
    GeometryId ground;
    GeometryId screen;
    @pool() {
        Geometry box_geometry = geometry::box(tmem, BOX_SIZE, BOX_SIZE, BOX_SIZE);
        box = assets.add_geometry(&box_geometry, "picking/box")!!;
        Geometry ground_geometry = geometry::plane(tmem, GROUND_SIZE, GROUND_SIZE);
        ground = assets.add_geometry(&ground_geometry, "picking/ground")!!;
        Geometry screen_geometry = geometry::box(tmem, MONITOR_WIDTH, MONITOR_HEIGHT, MONITOR_DEPTH);
        screen = assets.add_geometry(&screen_geometry, "picking/screen")!!;
    };
    MaterialId orange = assets.add_material(
        material::standard({ .base_color = { 0.9f, 0.45f, 0.1f, 1 }, .metallic = 0, .roughness = 0.5f }),
        "picking/orange",
    )!!;
    MaterialId teal = assets.add_material(
        material::standard({ .base_color = { 0.1f, 0.6f, 0.6f, 1 }, .metallic = 0, .roughness = 0.4f }),
        "picking/teal",
    )!!;
    MaterialId concrete = assets.add_material(
        material::standard({ .base_color = { 0.5f, 0.5f, 0.52f, 1 }, .metallic = 0, .roughness = 0.9f }),
        "picking/concrete",
    )!!;
    // The capture target is bound once the renderer has created it; the sampler clamps the screen edges.
    MaterialId monitor = assets.add_material(
        material::basic({
            .color = { 1, 1, 1, 1 },
            .map   = material::texture_slot(sampler: asset::SAMPLER_LINEAR_CLAMP),
        }),
        "picking/monitor",
    )!!;

    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    scene.ambient_intensity = AMBIENT_INTENSITY;

    Node* rotated = scene.add_mesh(box, orange, name: "rotated box")!!;
    rotated.local.position = ROTATED_BOX_POSITION;
    rotated.local.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, math::deg_to_rad(BOX_TURN_DEGREES));
    Node* scaled = scene.add_mesh(box, teal, name: "scaled box")!!;
    scaled.local.position = SCALED_BOX_POSITION;
    scaled.local.scale = BOX_SCALE;
    scene.update_world();
    @pool() {
        PickOptions triangles = spatial::PICK_OPTIONS_DEFAULT;
        triangles.precision = TRIANGLES;
        PickOptions bounds = spatial::PICK_OPTIONS_DEFAULT;
        print_hits("bounds before the first frame", pick_with(&assets, &scene, STARTUP_PROBE, bounds));
        print_hits("triangles before the first frame", pick_with(&assets, &scene, STARTUP_PROBE, triangles));
    };

    ModelTemplate* template = &assets.model(model).data;
    Aabb bounds = template_bounds(&assets, template);
    Vec3 extent = bounds.max - bounds.min;
    Vec3 center = (bounds.min + bounds.max) * 0.5f;
    float radius = math::max(extent.length() * 0.5f, 0.001f);
    float spacing = extent.x * (1 + INSTANCE_GAP_SCALE);
    Node* left = model::instantiate(&assets, &scene, model, name: "left instance")!!;
    Node* right = model::instantiate(&assets, &scene, model, name: "right instance")!!;
    left.local.position = { -spacing * 0.5f - extent.x, 0, 0 };
    right.local.position = { spacing * 0.5f + extent.x, 0, 0 };

    Node* floor = scene.add_mesh(ground, concrete, name: "ground")!!;
    floor.local.position = { 0, bounds.min.y, 0 };
    Node* monitor_node = scene.add_mesh(screen, monitor, name: "monitor")!!;
    monitor_node.local.position = MONITOR_POSITION;
    monitor_node.layers = MONITOR_LAYER;
    Node* sun = scene.add_light(light::directional({ 1, 0.95f, 0.85f }, SUN_INTENSITY), name: "sun")!!;
    sun.local.rotation = maths::look_rotation((Vec3){ -0.5f, -1, -0.6f }.normalize(), { 0, 1, 0 });

    Node* camera_node = scene.add_camera(camera::perspective_deg(50, radius * 0.05f), name: "camera")!!;
    Node* producer_node = scene.add_camera(camera::perspective_deg(50, radius * 0.05f), name: "producer")!!;
    scene.get(producer_node, camera::Camera).layers = scene::DEFAULT_LAYERS;
    producer_node.local.position = PRODUCER_POSITION;
    producer_node.local.rotation = maths::look_rotation((center - PRODUCER_POSITION).normalize(), { 0, 1, 0 });
    Orbit orbit = {
        .target   = center,
        .distance = radius * ORBIT_DISTANCE_SCALE + spacing,
        .yaw      = 0.6f,
        .pitch    = 0.35f,
    };
    apply_orbit(&orbit, &window.input, camera_node);
    scene.update_world();

    io::printn("left click selects, drag to orbit, wheel to zoom, Escape release quits");
    if (catch excuse = run(
        window:        &window,
        renderer:      &renderer,
        assets:        &assets,
        scene:         &scene,
        camera_node:   camera_node,
        producer_node: producer_node,
        monitor_node:  monitor_node,
        monitor:       monitor,
        orbit:         &orbit,
    )) {
        io::printfn("picking example failed: %s", excuse);
        return 1;
    }

    io::printfn("closed after %d frames, %.2fs", window.clock.frame, window.clock.total);
    return 0;
}
