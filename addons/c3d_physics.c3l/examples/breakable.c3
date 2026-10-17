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
import std::sort;
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
const float EXAMPLE_TWIST_LIMIT @local = 8000; // Nm; exposes torsional failure under the localized impact
const float EXAMPLE_BENDING_LIMIT @local = 16000; // Nm; keeps the standing wall intact before impact
const float ANCHOR_ROW_TOLERANCE @local = 1e-4f;
const uint WINDOW_WIDTH @local = 1280;
const uint WINDOW_HEIGHT @local = 720;
const uint CAPTURE_CHANNELS @local = 4;
const uint ACCEPTANCE_THROW_FRAME @local = 30;
const uint FRAME_WARMUP @local = 60;
const uint FRAME_SAMPLES @local = 300;
const String RESET_FRAME_OPTION @local = "--reset-at=";
const String RESET_CAPTURE_OPTION @local = "--capture-before-reset=";
const float ORBIT_SENSITIVITY @local = 0.005f;

struct Options @private {
    String model_path;
    String capture_path;
    String reset_capture_path;
    uint walls;
    uint frames;
    uint reset_frame;
    bool pieces;
    bool acceptance;
    bool benchmark;
    bool anchored;
    bool sampled;
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
    MaterialId anchor_material;
    ModelId model;
    Node*[MAX_WALLS] walls;
    uint wall_count;
    Node* projectiles;
    Node* anchor_target;
    uint shot_count;
    double author_ms;
    uint breaks;
    BreakableStrength strength;
    BreakableEvaluation evaluation;
    bool anchored;
    bool have_break;
    BreakCriterion last_criterion;
    BreakSamplePhase last_phase;
    BreakableStrength last_loads;
}

struct Controls @local {
    float strength;
    float speed;
    bool sleeping;
    bool draw_shapes;
    bool rebuild;
    float twist;
    float bending;
    bool anchored;
    bool sampled;
    bool reset_assembly;
    bool reset_pieces;
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
        } else if (arg.starts_with(RESET_FRAME_OPTION)) {
            options.reset_frame = arg[RESET_FRAME_OPTION.len..].to_uint()!;
        } else if (arg.starts_with(RESET_CAPTURE_OPTION)) {
            options.reset_capture_path = arg[RESET_CAPTURE_OPTION.len..];
        } else if (arg == "--pieces") {
            options.pieces = true;
        } else if (arg == "--acceptance") {
            options.acceptance = true;
        } else if (arg == "--benchmark") {
            options.benchmark = true;
        } else if (arg == "--anchors") {
            options.anchored = true;
        } else if (arg == "--sampled") {
            options.sampled = true;
        } else {
            return c3d::INVALID_ARGUMENT~;
        }
    }
    if (!options.walls || options.walls > MAX_WALLS) return c3d::INVALID_ARGUMENT~;
    if (options.acceptance && !options.frames) options.frames = 300;
    if (options.reset_capture_path.len && !options.reset_frame) return c3d::INVALID_ARGUMENT~;
    if (options.reset_frame && options.frames && options.reset_frame >= options.frames) return c3d::INVALID_ARGUMENT~;
    return options;
}

fn void? create_demo(Allocator allocator, Demo* demo, String model_path) @private {
    demo.allocator = allocator;
    demo.strength = physics::default_breakable_strength(EXAMPLE_BREAK_FORCE);
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
    demo.anchor_material = demo.assets.add_material(material::standard({
        .base_color = { 0.22f, 0.63f, 0.42f, 1 }, .roughness = 0.85f,
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
    demo.anchor_target = floor;
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
    if (demo.anchored || demo.evaluation == SAMPLED_REACTION) {
        @pool() {
            BreakableRecipeDesc recipe = capture_wall_recipe(demo, root, desc);
            demo.physics.remove_breakable(root);
            demo.physics.add_breakable_recipe(root, recipe)!;
        };
    }
    demo.author_ms += (double)(clock::now() - started) / 1_000_000;
    return root;
}

fn BreakableRecipeDesc capture_wall_recipe(Demo* demo, Node* root, BreakableDesc desc) @local {
    BreakableState* source = demo.scene.get(root, Breakable).state;
    BreakableRecipeDesc recipe = {
        .settings = desc,
        .strength = demo.strength,
        .evaluation = demo.evaluation,
        .pieces = alloc::new_array(tmem, BreakablePieceView, source.pieces.len),
        .welds = alloc::new_array(tmem, BreakableWeldDesc, source.welds.len),
    };
    float lowest = float::max;
    foreach (uint index, &piece : recipe.pieces) {
        *piece = source.piece_view(index);
        piece.hulls = alloc::clone_slice(tmem, piece.hulls);
        lowest = math::min(lowest, piece.rest_frame.position.y);
    }
    foreach (uint index, &weld : recipe.welds) {
        BreakableWeldView captured = source.weld_view(index);
        *weld = {
            .piece_a = captured.piece_a,
            .piece_b = captured.piece_b,
            .frame_a = captured.frame_a,
            .frame_b = captured.frame_b,
            .moment_axis = { 1, 0, 0 },
        };
    }
    if (!demo.anchored) return recipe;
    uint count;
    foreach (piece : recipe.pieces) if (piece.rest_frame.position.y <= lowest + ANCHOR_ROW_TOLERANCE) count++;
    recipe.anchors = alloc::new_array(tmem, BreakableAnchorDesc, count);
    uint next;
    Mat4 target_inverse = maths::inverse_affine(demo.anchor_target.world);
    foreach (uint index, piece : recipe.pieces) {
        if (piece.rest_frame.position.y > lowest + ANCHOR_ROW_TOLERANCE) continue;
        maths::Transform frame_a = maths::TRANSFORM_IDENTITY;
        if (!demo.model.generation) frame_a.position.y = -PIECE_SIZE * 0.5f;
        Mat4 frame_world = root.world.mul(piece.rest_frame.to_mat4()).mul(frame_a.to_mat4());
        recipe.anchors[next++] = {
            .piece = index,
            .target = demo.anchor_target.id,
            .frame_a = frame_a,
            .frame_b = maths::transform_from_mat4(target_inverse.mul(frame_world)),
            .moment_axis = { 1, 0, 0 },
            .strength_override = physics::default_breakable_strength(float::max),
            .has_strength_override = true,
        };
        demo.scene.get(demo.scene.node(piece.node), scene::Mesh).material = demo.anchor_material;
    }
    return recipe;
}

fn void? rebuild_demo(Demo* demo, uint walls, BreakableDesc desc) @private {
    foreach (root : demo.walls[:demo.wall_count]) demo.scene.remove(root);
    demo.wall_count = 0;
    if (demo.projectiles) demo.scene.remove(demo.projectiles);
    demo.projectiles = demo.scene.add_node(null, "projectiles")!;
    demo.shot_count = 0;
    demo.breaks = 0;
    demo.have_break = false;
    demo.author_ms = 0;

    for (uint index = 0; index < walls; index++) {
        Vec3 position;
        if (walls > 1) position = { ((float)(index % 8) - 3.5f) * WALL_SPACING, 0, (float)(index / 8) * WALL_SPACING };
        Node* wall = add_wall(demo, position, desc)!;
        demo.walls[demo.wall_count++] = wall;
    }
}

fn void? reset_demo(Demo* demo, BreakableForm form) @private {
    demo.scene.update_world();
    foreach (root : demo.walls[:demo.wall_count]) demo.physics.reset_breakable(root, form)!;
    if (demo.projectiles) demo.scene.remove(demo.projectiles);
    demo.projectiles = demo.scene.add_node(null, "projectiles")!;
    demo.shot_count = 0;
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
    imgui::set_next_window_size({ 390, 485 }, imgui::COND_FIRST_USE_EVER);
    if (imgui::begin("Breakable", null, {})) {
        imgui::text("Left click throws; right drag orbits; wheel zooms");
        imgui::slider_float(
            label: "Launch speed",
            v: &controls.speed,
            v_min: 1,
            v_max: 40,
        );
        imgui::slider_float(
            label: "Force / wake threshold (N)",
            v: &controls.strength,
            v_min: 100,
            v_max: 100000,
        );
        imgui::checkbox("Anchor bottom row", &controls.anchored);
        imgui::checkbox("Sample force and moments", &controls.sampled);
        if (controls.sampled) {
            imgui::slider_float(
                label: "Twist limit (N.m)",
                v: &controls.twist,
                v_min: 0,
                v_max: 50000,
            );
            imgui::slider_float(
                label: "Bending limit (N.m)",
                v: &controls.bending,
                v_min: 0,
                v_max: 50000,
            );
        }
        imgui::checkbox("Sleep until hit", &controls.sleeping);
        imgui::checkbox("Draw collision", &controls.draw_shapes);
        controls.rebuild = imgui::button("Rebuild with these settings");
        controls.reset_assembly = imgui::button("Reset to assembly");
        imgui::same_line();
        controls.reset_pieces = imgui::button("Reset to pieces");
        imgui::separator();
        BreakableState* state = demo.scene.get(demo.walls[0], Breakable).state;
        imgui::text("First wall: %s", state.form == ASSEMBLY ? "ASSEMBLY" : "PIECES");
        imgui::text("Pieces: %u / %llu; welds: %u / %llu",
            state.alive_pieces, state.pieces.len, state.alive_welds, state.welds.len);
        imgui::text("Anchors: %u / %u", state.alive_anchors, state.anchor_count());
        if (state.form == ASSEMBLY && state.anchor_count()) imgui::text("Anchors engage after wake.");
        imgui::text("Status: %s", state.status == LIVE ? "LIVE" : state.status == PENDING ? "PENDING" : "FAILED");
        if (state.status == FAILED) imgui::text("Weld binding failed; see the failure report.");
        b3::Counters counters = demo.physics.world.counters();
        imgui::text("Bodies %d, joints %d, awake %d", counters.body_count, counters.joint_count, demo.physics.world.awake_body_count());
        imgui::text("Breaks %llu / %u total; dropped %u", demo.physics.breaks().len, demo.breaks, demo.physics.dropped_events);
        if (demo.have_break) {
            imgui::text("Last criterion: %s", BreakCriterion::names[demo.last_criterion.ordinal]);
            if (demo.last_phase == POST_FIXED_STEP) {
                imgui::text("Sample: %.1f N, %.1f twist, %.1f bend N.m",
                    demo.last_loads.force, demo.last_loads.twist, demo.last_loads.bending);
            } else {
                imgui::text("Native threshold; trigger load unavailable.");
            }
        }
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
    demo.anchored = options.anchored;
    demo.evaluation = options.sampled ? SAMPLED_REACTION : NATIVE_FORCE;
    if (options.sampled) demo.strength = { .force = EXAMPLE_BREAK_FORCE, .twist = EXAMPLE_TWIST_LIMIT, .bending = EXAMPLE_BENDING_LIMIT };
    rebuild_demo(demo, options.walls, desc)!;
    Controls controls = {
        .strength = EXAMPLE_BREAK_FORCE,
        .speed = 15,
        .sleeping = !options.pieces,
        .twist = EXAMPLE_TWIST_LIMIT,
        .bending = EXAMPLE_BENDING_LIMIT,
        .anchored = options.anchored,
        .sampled = options.sampled,
    };
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
    if (options.capture_path.len || options.reset_capture_path.len) {
        capture_target = render::create_render_target(
            renderer: &renderer,
            desc: render::render_target_desc(WINDOW_WIDTH, WINDOW_HEIGHT, PixelFormat.RGBA8_SRGB),
        )!;
        ViewDesc view = render::texture_view_desc(capture_target, OutputMode.DISPLAY_LDR);
        view.post.anti_aliasing = AntiAliasing.NONE;
        capture_view = render::create_view(&renderer, view)!;
    }
    io::printn("Left click throws; right drag orbits; wheel zooms; rebuild applies strength and form.");
    io::printfn("adapter,%s,viewport,%d,%d,validation,true", renderer.adapter_name, WINDOW_WIDTH, WINDOW_HEIGHT);
    io::printfn("author_ms,%.6f,walls,%d", demo.author_ms, demo.wall_count);
    uint frame;
    double[FRAME_SAMPLES] frame_samples;
    uint sample_count;
    while (window.poll()) {
        if (options.frames && frame >= options.frames) break;
        time::Clock frame_started = clock::now();
        Input* input = &window.input;
        if (input.key_pressed(platform::Scancode.ESCAPE) && !input.keyboard_captured_by_gui) break;
        float delta = options.acceptance ? physics::DEFAULT_FIXED_DT : window.clock.delta;
        gui_renderer.new_frame();
        defer if (gui_renderer.frame_open) gui_renderer.finish_frame();
        draw_panel(demo, &controls, delta);
        if (controls.rebuild) {
            desc.break_force = controls.strength;
            desc.sleep_until_hit = controls.sleeping;
            demo.anchored = controls.anchored;
            demo.evaluation = controls.sampled ? SAMPLED_REACTION : NATIVE_FORCE;
            demo.strength = {
                .force = controls.strength,
                .twist = controls.sampled ? controls.twist : float::max,
                .bending = controls.sampled ? controls.bending : float::max,
            };
            rebuild_demo(demo, options.walls, desc)!;
        }
        if (controls.reset_assembly) reset_demo(demo, ASSEMBLY)!;
        if (controls.reset_pieces) reset_demo(demo, PIECES)!;
        if (options.reset_frame && frame == options.reset_frame) {
            if (options.reset_capture_path.len) save_window_capture(&renderer, capture_target, options.reset_capture_path)!;
            reset_demo(demo, controls.sleeping ? ASSEMBLY : PIECES)!;
            io::printfn("reset_frame,%d,form,%s", frame, controls.sleeping ? "ASSEMBLY" : "PIECES");
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
        foreach (event : demo.physics.breaks()) {
            demo.have_break = true;
            demo.last_criterion = event.criterion;
            demo.last_phase = event.phase;
            demo.last_loads = event.loads;
        }
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
        if (options.acceptance && frame >= FRAME_WARMUP && sample_count < FRAME_SAMPLES) {
            frame_samples[sample_count++] = (double)(clock::now() - frame_started) / 1_000_000;
        }
        frame++;
    }

    if (options.capture_path.len) save_window_capture(&renderer, capture_target, options.capture_path)!;
    renderer.log.check_validation()!;
    BreakableState* state = demo.scene.get(demo.walls[0], Breakable).state;
    io::printfn("frames,%d,breaks,%d,alive_welds,%d,form,%s", frame, demo.breaks, state.alive_welds,
        state.form == ASSEMBLY ? "ASSEMBLY" : "PIECES");
    if (options.acceptance && !demo.breaks) return c3d::INVALID_ARGUMENT~;
    if (sample_count) {
        foreach (index, milliseconds : frame_samples[:sample_count]) io::printfn("frame_cpu_ms,%d,%.6f", index + FRAME_WARMUP, milliseconds);
        sort::quicksort(frame_samples[:sample_count]);
        double median = (frame_samples[(sample_count - 1) / 2] + frame_samples[sample_count / 2]) * 0.5;
        uint percentile = (sample_count * 95 + 99) / 100 - 1;
        io::printfn("frame_cpu_summary,samples,%d,median_ms,%.6f,p95_ms,%.6f,views,%d",
            sample_count, median, frame_samples[percentile], capture_target.generation ? 2 : 1);
    }
}

fn void? save_window_capture(Renderer* renderer, RenderTargetId target, String path) @local {
    char[] pixels = alloc::new_array(renderer.allocator, char, WINDOW_WIDTH * WINDOW_HEIGHT * CAPTURE_CHANNELS);
    defer alloc::free(renderer.allocator, pixels.ptr);
    renderer.read_render_target(target, pixels)!;
    file::save(path, pixels)!;
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
