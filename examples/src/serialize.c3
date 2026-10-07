module serialize_example;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::asset::gltf;
import c3d::camera;
import c3d::ecs;
import c3d::geometry;
import c3d::gui;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::model;
import c3d::platform;
import c3d::render;
import c3d::scene;
import c3d::serial;
import imgui;
import std::io;
import std::io::file;
import std::io::path;
import std::math;
import std::time;
import std::time::clock;

const uint GRID_SIDE @local = 32; // 1,024 live instances keep the subtree small while carrying a substantial batch
const uint LIGHT_COUNT @local = 8;
const uint DEFAULT_MODEL_COUNT @local = 2;
const float GRID_SPACING @local = 0.4f;
const float FOX_SCALE @local = 0.015f;
const double NANOSECONDS_PER_MILLISECOND @local = 1_000_000;
const Vec2 PANEL_POSITION @local = { 16, 16 };
const Vec2 PANEL_SIZE @local = { 390, 290 };

struct Snapshot @local {
    char[] binary;
    String text;
    String schema;
    uint nodes;
    uint components;
    double binary_write_ms;
    double text_write_ms;
    double read_ms;
    bool text_selected;
}

fn uint component_count(Scene* scene, Node* node) @local {
    uint count;
    ComponentMask mask = scene.world.mask(node.id);
    for (uint slot = 0; slot < ecs::MAX_COMPONENT_TYPES; slot++) {
        if (mask & ecs::slot_bit(slot)) count++;
    }
    for (Node* child = node.first_child; child; child = child.next_sibling) {
        count += component_count(scene, child);
    }
    return count;
}

fn Node*? create_cell(
    Scene* scene,
    AssetStore* assets,
    ModelId model_id,
    uint model_count,
) @local {
    Node* root = scene.add_node(name: "cell")!;
    defer catch scene.remove(root);
    for (uint index = 0; index < model_count; index++) {
        Node* fox = model::instantiate(
            assets: assets,
            scene: scene,
            model: model_id,
            parent: root,
            name: index ? "animated" : "still",
        )!;
        fox.local.position = { index ? 2 : -2, 0.2f, 0 };
        fox.local.scale = { FOX_SCALE, FOX_SCALE, FOX_SCALE };
        if (index) {
            anim::add_animator(scene, fox);
            ClipId[] clips = scene.get(fox, ModelInstance).clips;
            if (clips.len) scene.get(fox, Animator).play(assets, clips[0])!;
        }
    }
    Geometry geometry = geometry::box(
        allocator: tmem,
        width: 0.3f,
        height: 0.15f,
        depth: 0.3f,
    );
    GeometryId geometry_id = assets.add_geometry(&geometry, "serialize/box")!;
    StandardParams surface = material::STANDARD_PARAMS_DEFAULT;
    surface.base_color = { 0.3f, 0.55f, 0.8f, 1 };
    surface.metallic = 0;
    MaterialId material_id = assets.add_material(material::standard(surface), "serialize/blue")!;
    Transform[] transforms = alloc::new_array(tmem, Transform, GRID_SIDE * GRID_SIDE);
    foreach (index, &transform : transforms) {
        *transform = maths::TRANSFORM_IDENTITY;
        transform.position = {
            ((float)(index % GRID_SIDE) - (GRID_SIDE - 1) * 0.5f) * GRID_SPACING,
            0,
            ((float)(index / GRID_SIDE) - (GRID_SIDE - 1) * 0.5f) * GRID_SPACING,
        };
    }
    scene.add_instanced_mesh(
        geometry: geometry_id,
        material: material_id,
        capacity: GRID_SIDE * GRID_SIDE,
        transforms: transforms,
        parent: root,
        name: "boxes",
    )!;
    for (uint index = 0; index < LIGHT_COUNT; index++) {
        float angle = (float)(2 * math::PI * index / LIGHT_COUNT);
        Node* point = scene.add_light(light::point({ 0.5f, 0.7f, 1 }, 12, 4), root, "point")!;
        point.local.position = { math::cos(angle) * 4, 2, math::sin(angle) * 4 };
    }
    scene.update_world();
    return root;
}

fn void destroy_snapshot(Snapshot* snapshot) @local {
    alloc::free(mem, snapshot.binary.ptr);
    alloc::free(mem, snapshot.text.ptr);
    alloc::free(mem, snapshot.schema.ptr);
}

fn Snapshot? capture(Scene* scene, AssetStore* assets, Node* root) @local {
    Snapshot snapshot;
    defer catch destroy_snapshot(&snapshot);
    time::Clock started = clock::now();
    snapshot.binary = serial::write_subtree(
        allocator: mem,
        scene: scene,
        assets: assets,
        root: root,
    )!;
    snapshot.binary_write_ms = (double)(clock::now() - started) / NANOSECONDS_PER_MILLISECOND;
    started = clock::now();
    snapshot.text = serial::write_subtree_text(
        allocator: mem,
        scene: scene,
        assets: assets,
        root: root,
    )!;
    snapshot.text_write_ms = (double)(clock::now() - started) / NANOSECONDS_PER_MILLISECOND;
    snapshot.schema = serial::write_schema(mem)!;
    snapshot.nodes = serial::read_header(snapshot.binary)!.node_count;
    snapshot.components = component_count(scene, root);
    char[] second = serial::write_subtree(
        allocator: tmem,
        scene: scene,
        assets: assets,
        root: root,
    )!;
    String second_text = serial::write_subtree_text(
        allocator: tmem,
        scene: scene,
        assets: assets,
        root: root,
    )!;
    if (second != snapshot.binary || second_text != snapshot.text) return c3d::INVALID_ARGUMENT~;
    return snapshot;
}

fn Node*? restore(Snapshot* snapshot, Scene* scene, AssetStore* assets) @local {
    time::Clock started = clock::now();
    Node* restored = snapshot.text_selected
      ? serial::read_subtree_text(scene, assets, snapshot.text)!
      : serial::read_subtree(scene, assets, snapshot.binary)!;
    snapshot.read_ms = (double)(clock::now() - started) / NANOSECONDS_PER_MILLISECOND;
    io::printfn("CPU %s read %.3f ms", snapshot.text_selected ? "JSONC" : "binary", snapshot.read_ms);
    return restored;
}

fn void? check_round_trip(
    Snapshot* snapshot,
    Scene* scene,
    AssetStore* assets,
    Node* root,
) @local {
    char[] binary = serial::write_subtree(
        allocator: tmem,
        scene: scene,
        assets: assets,
        root: root,
    )!;
    String text = serial::write_subtree_text(
        allocator: tmem,
        scene: scene,
        assets: assets,
        root: root,
    )!;
    if (binary != snapshot.binary || text != snapshot.text || component_count(scene, root) != snapshot.components) {
        return c3d::INVALID_ARGUMENT~;
    }
}

fn void? draw_frame(
    Renderer* renderer,
    GuiRenderer* gui_renderer,
    Scene* scene,
    Node* camera_node,
    FrameInfo frame,
) @local {
    renderer.begin_frame(frame)!;
    defer catch render::abort_frame(renderer);
    if (renderer.has_output) {
        renderer.render_view(scene, camera_node, renderer.default_view)!;
        renderer.finish_view(renderer.default_view)!;
        OverlayContext overlay = renderer.begin_overlay()!;
        gui_renderer.record(&overlay)!;
        renderer.end_overlay(&overlay)!;
    }
    return renderer.end_frame();
}

fn int main(String[] args) {
    uint frame_limit;
    uint model_count = DEFAULT_MODEL_COUNT;
    bool cpu_only;
    bool acceptance;
    bool show_original;
    String export_prefix;
    foreach (argument : args[1..]) {
        if (argument.starts_with("--frames=")) {
            frame_limit = argument[9..].to_uint()!!;
        } else if (argument.starts_with("--models=")) {
            model_count = argument[9..].to_uint()!!;
            if (model_count < DEFAULT_MODEL_COUNT) {
                io::eprintfn("--models needs at least %d", DEFAULT_MODEL_COUNT);
                return 1;
            }
        } else if (argument == "--cpu-only") {
            cpu_only = true;
        } else if (argument == "--acceptance") {
            acceptance = true;
        } else if (argument == "--original") {
            show_original = true;
        } else if (argument.starts_with("--export=")) {
            export_prefix = argument[9..];
        } else {
            io::eprintfn("Unknown argument: %s", argument);
            return 1;
        }
    }
    serial::register_core_codecs()!!;
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    Snapshot snapshot;
    defer destroy_snapshot(&snapshot);
    Node* cell;
    @pool() {
        Path source = path::tnew($$FILEPATH)!!;
        String model_path = (String)source.parent()!!.tappend("../assets/gltf/Fox.glb")!!;
        ModelId model_id = gltf::load_model(&assets, model_path)!!;
        cell = create_cell(
            scene: &scene,
            assets: &assets,
            model_id: model_id,
            model_count: model_count,
        )!!;
        snapshot = capture(&scene, &assets, cell)!!;
        Scene comparison;
        Scene* destination = &scene;
        if (show_original) {
            comparison = scene::create_scene(mem, scene::default_scene_desc());
            destination = &comparison;
        } else {
            scene.remove(cell);
        }
        defer if (show_original) scene::destroy_scene(&comparison);
        for (uint format = 0; format < 2; format++) {
            snapshot.text_selected = format != 0;
            Node* restored = restore(&snapshot, destination, &assets)!!;
            check_round_trip(
                snapshot: &snapshot,
                scene: destination,
                assets: &assets,
                root: restored,
            )!!;
            if (!format) {
                destination.remove(restored);
            } else if (!show_original) {
                cell = restored;
            }
        }
        io::printfn("%d binary bytes, %d JSONC bytes", snapshot.binary.len, snapshot.text.len);
        io::printfn("%d nodes, %d components", snapshot.nodes, snapshot.components);
        io::printfn("%.1f binary bytes/node", (double)snapshot.binary.len / snapshot.nodes);
        io::printfn("CPU write: binary %.3f ms, JSONC %.3f ms", snapshot.binary_write_ms, snapshot.text_write_ms);
        io::printfn("Schema: %d bytes", snapshot.schema.len);
        io::printn("Repeated writes and binary/JSONC read-write checks passed.");
        if (export_prefix.len) {
            file::save(string::tformat("%s.bin", export_prefix), snapshot.binary)!!;
            file::save(string::tformat("%s.jsonc", export_prefix), (char[])snapshot.text)!!;
            file::save(string::tformat("%s.schema.json", export_prefix), (char[])snapshot.schema)!!;
        }
    };
    if (cpu_only) return 0;

    platform::Window window = platform::create_window(
        platform::default_window_desc("c3d serialization", 1280, 800),
    )!!;
    defer platform::destroy_window(&window);
    Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window: &window,
        assets: &assets,
        desc: { .validation = true, .application_name = "serialize" },
    )!!;
    defer render::destroy_renderer(&renderer);
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, &renderer, &window)!!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);
    scene.ambient_intensity = 0.4f;
    Node* sun = scene.add_light(light::directional({ 1, 0.95f, 0.85f }, 2), name: "sun")!!;
    sun.local.rotation = maths::look_rotation((Vec3){ -1, -2, -1 }.normalize(), { 0, 1, 0 });
    Node* camera_node = scene.add_camera(camera::perspective_deg(50, 0.1f), name: "camera")!!;
    camera_node.local.position = { 14, 10, 17 };
    camera_node.local.rotation = maths::look_rotation(
        (Vec3){ 0, 1, 0 } - camera_node.local.position, { 0, 1, 0 },
    );
    scene.update_world();
    renderer.prepare_scene(&scene)!!;
    io::printn("R reloads the snapshot; choose binary or JSONC in the panel; Escape quits.");
    uint frame;
    while (window.poll()) {
        if (frame_limit && frame >= frame_limit) break;
        gui_renderer.new_frame();
        if (window.input.key_pressed(platform::Scancode.ESCAPE)) {
            gui_renderer.finish_frame();
            break;
        }
        imgui::set_next_window_pos(PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        bool reload = window.input.key_pressed(platform::Scancode.R) && !window.input.keyboard_captured_by_gui;
        if (imgui::begin("Serialization", null, {})) {
            imgui::text_unformatted(show_original ? "Authored source" : "Restored snapshot");
            imgui::text("Binary: %llu bytes", (ulong)snapshot.binary.len);
            imgui::text("JSONC: %llu bytes", (ulong)snapshot.text.len);
            imgui::text("Nodes: %u, components: %u", snapshot.nodes, snapshot.components);
            imgui::text("Binary bytes/node: %.1f", (double)snapshot.binary.len / snapshot.nodes);
            imgui::text("CPU write: %.3f / %.3f ms", snapshot.binary_write_ms, snapshot.text_write_ms);
            imgui::text("CPU read: %.3f ms", snapshot.read_ms);
            imgui::checkbox("Read JSONC", &snapshot.text_selected);
            reload |= imgui::button("Reload snapshot (R)");
            imgui::text_wrapped("Both formats restore the authored scene. Animation restarts at time zero.");
        }
        imgui::end();
        if (acceptance && (frame == 60 || frame == 120)) {
            snapshot.text_selected = frame == 60;
            reload = true;
        }
        @pool() {
            if (reload) {
                scene.remove(cell);
                cell = restore(&snapshot, &scene, &assets)!!;
                show_original = false;
                check_round_trip(
                    snapshot: &snapshot,
                    scene: &scene,
                    assets: &assets,
                    root: cell,
                )!!;
                scene.update_world();
                renderer.prepare_scene(&scene)!!;
            }
        };
        anim::update(&assets, &scene, acceptance ? 1.0f / 60 : window.clock.delta);
        scene.update_world();
        gui_renderer.finish_frame();
        platform::sync_window(&window, &renderer);
        draw_frame(
            renderer: &renderer,
            gui_renderer: &gui_renderer,
            scene: &scene,
            camera_node: camera_node,
            frame: { .time = window.clock.total, .delta = window.clock.delta },
        )!!;
        frame++;
    }
    renderer.log.check_validation()!!;
    return 0;
}
