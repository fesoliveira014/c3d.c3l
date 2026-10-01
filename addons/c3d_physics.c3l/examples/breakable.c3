module breakable_example;

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
import c3d::physics;
import c3d::platform;
import c3d::render;
import c3d::scene;
import std::io;
import std::io::file;
import std::math;
import std::time;
import std::time::clock;
import imgui;
import b3;

const uint MAX_WALLS @private = 32; // bounds the idle comparison and scene-owned root array
const uint MAX_SHOTS @private = 128; // bounds interactive debris until rebuild
const uint WALL_SIDE @private = 8;
const float PIECE_SIZE @private = 0.5f;
const float PROJECTILE_DENSITY @local = 8000; // a dense 1000 kg projectile makes localized fracture visible at 15 m/s
const float WALL_SPACING @private = 6;
const float PIECE_PITCH @local = 0.508f; // 8 mm seams connect faces but leave diagonal pieces outside the 1 cm gap
const float EXAMPLE_BREAK_FORCE @private = 40000; // supports the unhit wall while a dense projectile fractures it
const uint WINDOW_WIDTH @local = 1280;
const uint WINDOW_HEIGHT @local = 720;
const uint CAPTURE_CHANNELS @local = 4;
const uint ACCEPTANCE_THROW_FRAME @local = 30;
const float ORBIT_SENSITIVITY @local = 0.005f;

struct Options @private {
    String model_path;
    String capture_path;
    uint walls;
    uint frames;
    bool pieces;
    bool acceptance;
    bool benchmark;
}

struct Demo @private {
    Allocator allocator;
    AssetStore assets;
    Scene scene;
    PhysicsWorld physics;
    GeometryId cube;
    MaterialId piece_material;
    MaterialId alternate_material;
    MaterialId shot_material;
    ModelId model;
    Node*[MAX_WALLS] walls;
    uint wall_count;
    Node* projectiles;
    uint shot_count;
    double author_ms;
    uint breaks;
}

struct Controls @local {
    float strength;
    float speed;
    bool sleeping;
    bool draw_shapes;
    bool rebuild;
}

fn Options? parse_options(String[] args) @local {
    Options options = { .walls = 1 };
    for (usz index = 1; index < args.len; index++) {
        String arg = args[index];
        if (arg == "--model" && index + 1 < args.len) {
            options.model_path = args[++index];
        } else if (arg == "--walls" && index + 1 < args.len) {
            options.walls = args[++index].to_uint()!;
        } else if (arg.starts_with("--frames=")) {
            options.frames = arg[9..].to_uint()!;
        } else if (arg.starts_with("--capture=")) {
            options.capture_path = arg[10..];
        } else if (arg == "--pieces") {
            options.pieces = true;
        } else if (arg == "--acceptance") {
            options.acceptance = true;
        } else if (arg == "--benchmark") {
            options.benchmark = true;
        } else {
            return c3d::INVALID_ARGUMENT~;
        }
    }
    if (!options.walls || options.walls > MAX_WALLS) return c3d::INVALID_ARGUMENT~;
    if (options.acceptance && !options.frames) options.frames = 300;
    return options;
}

fn void? create_demo(Allocator allocator, Demo* demo, String model_path) @private {
    demo.allocator = allocator;
    demo.assets = asset::create_asset_store(allocator, asset::default_asset_store_desc());
    defer catch asset::destroy_asset_store(&demo.assets);
    if (model_path.len) demo.model = gltf::load_model(&demo.assets, model_path)!;
    uint per_wall = WALL_SIDE * WALL_SIDE + 1;
    if (demo.model.generation) per_wall = (uint)demo.assets.model(demo.model).data.nodes.len + 1;
    demo.scene = scene::create_scene(allocator, { .max_nodes = MAX_WALLS * per_wall + MAX_SHOTS + 16 });
    defer catch scene::destroy_scene(&demo.scene);
    physics::register_physics(&demo.scene)!;
    demo.physics = physics::create_physics_world(
        allocator: allocator,
        assets: &demo.assets,
        scene: &demo.scene,
        desc: physics::default_physics_desc(),
    )!;
    defer catch physics::destroy_physics_world(&demo.physics);

    GeometryId ground;
    @pool() {
        Geometry cube = geometry::box(
            allocator: tmem,
            width: PIECE_SIZE,
            height: PIECE_SIZE,
            depth: PIECE_SIZE,
        );
        demo.cube = demo.assets.add_geometry(&cube, "breakable/cube")!;
        Geometry plane = geometry::plane(tmem, 100, 100);
        ground = demo.assets.add_geometry(&plane, "breakable/ground")!;
    };
    demo.piece_material = demo.assets.add_material(material::standard({
        .base_color = { 0.67f, 0.72f, 0.79f, 1 }, .roughness = 0.85f,
    }))!;
    demo.alternate_material = demo.assets.add_material(material::standard({
        .base_color = { 0.52f, 0.59f, 0.68f, 1 }, .roughness = 0.85f,
    }))!;
    demo.shot_material = demo.assets.add_material(material::standard({
        .base_color = { 0.92f, 0.3f, 0.08f, 1 }, .roughness = 0.5f,
    }))!;
    MaterialId ground_material = demo.assets.add_material(material::standard({
        .base_color = { 0.19f, 0.23f, 0.26f, 1 }, .roughness = 0.95f,
    }))!;
    Node* floor = demo.scene.add_mesh(ground, ground_material, name: "ground")!;
    demo.scene.get(floor, scene::Mesh).cast_shadow = false;
    demo.scene.update_world();
    ColliderDesc collider = physics::default_collider_desc(BOX);
    collider.half_extents = { 50, 0.5f, 50 };
    collider.local.position.y = -0.5f;
    demo.physics.add_body(floor, physics::default_body_desc(STATIC), (&collider)[:1])!;
}

fn void destroy_demo(Demo* demo) @private {
    physics::destroy_physics_world(&demo.physics);
    scene::destroy_scene(&demo.scene);
    asset::destroy_asset_store(&demo.assets);
}

fn Node*? add_wall(Demo* demo, Vec3 position, BreakableDesc desc) @local {
    Node* root;
    if (demo.model.generation) {
        root = model::instantiate(&demo.assets, &demo.scene, demo.model)!;
    } else {
        root = demo.scene.add_node(null, "wall")!;
    }
    defer catch demo.scene.remove(root);
    root.local.position = position;
    if (!demo.model.generation) {
        for (uint row = 0; row < WALL_SIDE; row++) {
            for (uint column = 0; column < WALL_SIDE; column++) {
                Node* piece = demo.scene.add_mesh(
                    geometry: demo.cube,
                    material: (row + column) % 2 ? demo.alternate_material : demo.piece_material,
                    parent: root,
                    name: "piece",
                )!;
                piece.local.position = {
                    ((float)column - (WALL_SIDE - 1) * 0.5f) * PIECE_PITCH,
                    (float)row * PIECE_PITCH + PIECE_SIZE * 0.5f,
                    0,
                };
            }
        }
    }
    demo.scene.update_world();
    time::Clock started = clock::now();
    demo.physics.add_breakable(root, desc)!;
    demo.author_ms += (double)(clock::now() - started) / 1_000_000;
    return root;
}

fn void? rebuild_demo(Demo* demo, uint walls, BreakableDesc desc) @private {
    foreach (root : demo.walls[:demo.wall_count]) demo.scene.remove(root);
    demo.wall_count = 0;
    if (demo.projectiles) demo.scene.remove(demo.projectiles);
    demo.projectiles = demo.scene.add_node(null, "projectiles")!;
    demo.shot_count = 0;
    demo.breaks = 0;
    demo.author_ms = 0;

    for (uint index = 0; index < walls; index++) {
        Vec3 position;
        if (walls > 1) position = { ((float)(index % 8) - 3.5f) * WALL_SPACING, 0, (float)(index / 8) * WALL_SPACING };
        Node* wall = add_wall(demo, position, desc)!;
        demo.walls[demo.wall_count++] = wall;
    }
}

fn Node*? throw_box(Demo* demo, Vec3 position, Vec3 direction, float speed) @private {
    if (demo.shot_count == MAX_SHOTS) return c3d::CAPACITY_EXCEEDED~;
    Node* node = demo.scene.add_mesh(
        geometry: demo.cube,
        material: demo.shot_material,
        parent: demo.projectiles,
        name: "projectile",
    )!;
    defer catch demo.scene.remove(node);
    node.local.position = position;
    demo.scene.update_world();
    ColliderDesc collider = physics::default_collider_desc(BOX);
    collider.half_extents = { PIECE_SIZE * 0.5f, PIECE_SIZE * 0.5f, PIECE_SIZE * 0.5f };
    collider.hit_events = true;
    collider.density = PROJECTILE_DENSITY;
    BodyDesc body = physics::default_body_desc(DYNAMIC);
    body.linear_velocity = direction * speed;
    body.bullet = true;
    demo.physics.add_body(node, body, (&collider)[:1])!;
    demo.shot_count++;
    return node;
}

fn maths::Aabb wall_bounds(Demo* demo) @private {
    BreakableState* state = demo.scene.get(demo.walls[0], Breakable).state;
    maths::Aabb bounds;
    foreach (index, entity : state.pieces) {
        Node* node = demo.scene.node(entity);
        scene::Mesh* mesh = demo.scene.get(node, scene::Mesh);
        maths::Aabb piece = maths::aabb_transform(demo.assets.geometry(mesh.geometry).data.bounds, node.world);
        bounds = index ? maths::aabb_merge(bounds, piece) : piece;
    }
    return bounds;
}

fn Vec3 aim_point(Demo* demo) @private {
    maths::Aabb bounds = wall_bounds(demo);
    Vec3 middle = (bounds.min + bounds.max) * 0.5f;
    Vec3 chosen = middle;
    float nearest = float::max;
    BreakableState* state = demo.scene.get(demo.walls[0], Breakable).state;
    foreach (entity : state.pieces) {
        Node* node = demo.scene.node(entity);
        scene::Mesh* mesh = demo.scene.get(node, scene::Mesh);
        maths::Aabb piece = maths::aabb_transform(demo.assets.geometry(mesh.geometry).data.bounds, node.world);
        Vec3 center = (piece.min + piece.max) * 0.5f;
        float distance = (center - middle).length();
        if (distance < nearest) {
            nearest = distance;
            chosen = center;
        }
    }
    return chosen;
}

fn void draw_panel(Demo* demo, Controls* controls, float delta) @local {
    imgui::set_next_window_pos({ 16, 16 }, imgui::COND_FIRST_USE_EVER);
    imgui::set_next_window_size({ 360, 305 }, imgui::COND_FIRST_USE_EVER);
    if (imgui::begin("Breakable", null, {})) {
        imgui::text("Left click throws; right drag orbits; wheel zooms");
        imgui::slider_float(
            label: "Launch speed",
            v: &controls.speed,
            v_min: 1,
            v_max: 40,
        );
        imgui::slider_float(
            label: "Break force",
            v: &controls.strength,
            v_min: 100,
            v_max: 100000,
        );
        imgui::checkbox("Sleep until hit", &controls.sleeping);
        imgui::checkbox("Draw collision", &controls.draw_shapes);
        controls.rebuild = imgui::button("Rebuild with these settings");
        imgui::separator();
        BreakableState* state = demo.scene.get(demo.walls[0], Breakable).state;
        imgui::text("First wall: %s", state.form == ASSEMBLY ? "ASSEMBLY" : "PIECES");
        imgui::text("Pieces: %u / %llu; welds: %u / %llu",
            state.alive_pieces, state.pieces.len, state.alive_welds, state.welds.len);
        imgui::text("Status: %s", state.status == LIVE ? "LIVE" : state.status == PENDING ? "PENDING" : "FAILED");
        if (state.status == FAILED) imgui::text("Weld binding failed; see the failure report.");
        b3::Counters counters = demo.physics.world.counters();
        imgui::text("Bodies %d, joints %d, awake %d", counters.body_count, counters.joint_count, demo.physics.world.awake_body_count());
        imgui::text("Breaks %llu / %u total; dropped %u", demo.physics.breaks().len, demo.breaks, demo.physics.dropped_events);
        imgui::text("Steps %u, frame %.2f ms", demo.physics.steps_last_update, delta * 1000);
    }
    imgui::end();
}

fn void? run_window(Demo* demo, Options options) @local {
    platform::Window window = platform::create_window(platform::default_window_desc("c3d breakable", WINDOW_WIDTH, WINDOW_HEIGHT))!;
    defer platform::destroy_window(&window);
    render::Renderer renderer = platform::create_window_renderer(
        allocator: demo.allocator,
        window: &window,
        assets: &demo.assets,
        desc: { .validation = true, .application_name = "c3d_breakable" },
    )!;
    defer render::destroy_renderer(&renderer);
    GuiRenderer gui_renderer = gui::create_gui_renderer(demo.allocator, &renderer, &window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);
    debug::DebugDraw debug = debug::create_debug_draw(demo.allocator);
    defer debug::destroy_debug_draw(&debug);

    BreakableDesc desc = physics::default_breakable_desc();
    desc.break_force = EXAMPLE_BREAK_FORCE;
    desc.sleep_until_hit = !options.pieces;
    rebuild_demo(demo, options.walls, desc)!;
    Controls controls = { .strength = EXAMPLE_BREAK_FORCE, .speed = 15, .sleeping = !options.pieces };
    Node* sun = demo.scene.add_light(light::directional({ 1, 0.95f, 0.88f }, 3), name: "sun")!;
    sun.local.rotation = maths::look_rotation(((Vec3){ -0.4f, -1, -0.5f }).normalize(), { 0, 1, 0 });
    demo.scene.ambient_color = { 0.55f, 0.65f, 0.8f };
    demo.scene.ambient_intensity = 0.4f;
    demo.scene.background = { .kind = COLOR, .color = { 0.045f, 0.065f, 0.09f, 1 } };
    maths::Aabb bounds = wall_bounds(demo);
    Vec3 target = aim_point(demo);
    float distance = math::max(5.0f, (bounds.max - bounds.min).length() * 2);
    float yaw = 0.25f;
    float pitch = 0.15f;
    Node* camera_node = demo.scene.add_camera(camera::perspective_deg(50, 0.05f), name: "camera")!;
    renderer.prepare_scene(&demo.scene)!;

    RenderTargetId capture_target;
    ViewId capture_view;
    if (options.capture_path.len) {
        capture_target = render::create_render_target(
            renderer: &renderer,
            desc: render::render_target_desc(WINDOW_WIDTH, WINDOW_HEIGHT, PixelFormat.RGBA8_SRGB),
        )!;
        ViewDesc view = render::texture_view_desc(capture_target, OutputMode.DISPLAY_LDR);
        view.post.anti_aliasing = AntiAliasing.NONE;
        capture_view = render::create_view(&renderer, view)!;
    }
    io::printn("Left click throws; right drag orbits; wheel zooms; rebuild applies strength and form.");
    io::printfn("author_ms,%.6f,walls,%d", demo.author_ms, demo.wall_count);
    uint frame;
    while (window.poll()) {
        if (options.frames && frame >= options.frames) break;
        Input* input = &window.input;
        if (input.key_pressed(platform::Scancode.ESCAPE) && !input.keyboard_captured_by_gui) break;
        float delta = options.acceptance ? physics::DEFAULT_FIXED_DT : window.clock.delta;
        gui_renderer.new_frame();
        defer if (gui_renderer.frame_open) gui_renderer.finish_frame();
        draw_panel(demo, &controls, delta);
        if (controls.rebuild) {
            desc.break_force = controls.strength;
            desc.sleep_until_hit = controls.sleeping;
            rebuild_demo(demo, options.walls, desc)!;
        }
        if (!input.mouse_captured_by_gui) {
            if (input.button_down(platform::MouseButton.RIGHT)) {
                yaw -= input.mouse_delta.x * ORBIT_SENSITIVITY;
                pitch = math::clamp(pitch + input.mouse_delta.y * ORBIT_SENSITIVITY, -0.1f, 1.3f);
            }
            distance = math::clamp(distance * math::pow(0.9f, input.wheel), 2.0f, 100.0f);
        }
        Vec3 offset = { math::cos(pitch) * math::sin(yaw), math::sin(pitch), math::cos(pitch) * math::cos(yaw) };
        camera_node.local.position = target + offset * distance;
        camera_node.local.rotation = maths::look_rotation(-offset, { 0, 1, 0 });
        if (input.button_pressed(platform::MouseButton.LEFT) && !input.mouse_captured_by_gui) {
            if (catch excuse = throw_box(
                demo: demo,
                position: camera_node.local.position - offset,
                direction: -offset,
                speed: controls.speed,
            )) {
                io::eprintfn("Throw failed: %s", excuse);
            }
        }
        if (options.acceptance && frame == ACCEPTANCE_THROW_FRAME) {
            throw_box(
                demo: demo,
                position: target + (Vec3){ 0, 0, 3 },
                direction: { 0, 0, -1 },
                speed: controls.speed,
            )!;
        }

        demo.scene.update_world();
        demo.physics.update(delta);
        demo.breaks += (uint)demo.physics.breaks().len;
        foreach (failure : demo.physics.build_failures()) io::eprintfn("Build failed: %s", failure.reason);
        demo.scene.update_world();
        debug.clear();
        if (controls.draw_shapes) demo.physics.debug_draw(&debug, { .colliders = true, .joints = true });
        gui_renderer.finish_frame();
        platform::sync_window(&window, &renderer);
        renderer.begin_frame({ .time = window.clock.total, .delta = delta })!;
        defer catch render::abort_frame(&renderer);
        if (renderer.has_output) {
            renderer.render_view(
                scene: &demo.scene,
                camera_node: camera_node,
                view: renderer.default_view,
                debug: &debug,
            )!;
            renderer.finish_view(renderer.default_view)!;
            OverlayContext overlay = renderer.begin_overlay()!;
            gui_renderer.record(&overlay)!;
            renderer.end_overlay(&overlay)!;
        }
        if (capture_target.generation) {
            renderer.render_view(&demo.scene, camera_node, capture_view)!;
            renderer.finish_view(capture_view)!;
        }
        renderer.end_frame()!;
        frame++;
    }

    if (capture_target.generation) {
        char[] pixels = alloc::new_array(demo.allocator, char, WINDOW_WIDTH * WINDOW_HEIGHT * CAPTURE_CHANNELS);
        defer alloc::free(demo.allocator, pixels.ptr);
        renderer.read_render_target(capture_target, pixels)!;
        file::save(options.capture_path, pixels)!;
    }
    renderer.log.check_validation()!;
    BreakableState* state = demo.scene.get(demo.walls[0], Breakable).state;
    io::printfn("frames,%d,breaks,%d,alive_welds,%d,form,%s", frame, demo.breaks, state.alive_welds,
        state.form == ASSEMBLY ? "ASSEMBLY" : "PIECES");
    if (options.acceptance && !demo.breaks) return c3d::INVALID_ARGUMENT~;
}

fn int main(String[] args) {
    Options? options = parse_options(args);
    if (catch excuse = options) {
        io::eprintfn("Invalid options: %s", excuse);
        return 1;
    }
    if (options.benchmark) {
        if (catch excuse = run_benchmark()) {
            io::eprintfn("Benchmark failed: %s", excuse);
            return 1;
        }
        return 0;
    }
    Demo demo;
    if (catch excuse = create_demo(mem, &demo, options.model_path)) {
        io::eprintfn("Setup failed: %s", excuse);
        return 1;
    }
    defer destroy_demo(&demo);
    if (catch excuse = run_window(&demo, options)) {
        io::eprintfn("Breakable example failed: %s", excuse);
        return 1;
    }
    return 0;
}
