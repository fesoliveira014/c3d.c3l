module navmesh_example;

import std::io;
import std::math;
import std::math::quaternion;
import c3d;
import c3d::asset;
import c3d::camera;
import c3d::debug;
import c3d::geometry;
import c3d::gui;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::nav;
import c3d::platform;
import c3d::render;
import c3d::scene;
import imgui;

const uint  SCENE_NODE_CAPACITY @local = 64;
const float FLOOR_SIZE @local = 24;
const uint  FLOOR_SEGMENTS @local = 24; // 1152 floor triangles, so a low rasterization budget spans frames
const float LEVEL_HALF_SIZE @local = 12;
const float LEVEL_TOP @local = 6; // metres above the floor the builder voxelizes
const uint  TILES_PER_FRAME @local = 4;
const uint  RASTERIZE_BUDGET @local = 96; // triangles per call; low enough that a slot's spans stay on screen
const char  MUD_AREA @local = 2;
const float RAMP_ANGLE @local = 0.3f; // radians; 17 degrees, under the 45 degree slope limit
const float STEEP_RAMP_ANGLE @local = 1.0f; // radians; 57 degrees, over the slope limit
const float STEP_HEIGHT @local = 0.2f; // metres; the flight stays within the 0.9 m climb, so its sides are no ledge
const float STEP_DEPTH @local = 1.2f;
const Vec3  PLATFORM_HOME @local = { 7, 0.5f, -6 };
const float PLATFORM_SHIFT @local = 4; // metres along X each press of M
const uint  SPAN_COLOR @local = 0xFF40FFFF;
const float FREE_LOOK_RADIANS_PER_PIXEL @local = 0.003f;
const float FREE_PITCH_LIMIT @local = 1.5f; // avoids the poles, where the up vector degenerates
const float FREE_SPEED @local = 8;
const float FREE_FAST_MULTIPLIER @local = 4;
const float FREE_SPEED_WHEEL_STEP @local = 1.25f;
const Vec3  CAMERA_START @local = { 0, 14, 20 };
const float CAMERA_START_PITCH @local = -0.6f;
const Vec2  PANEL_POSITION @local = { 16, 16 };
const Vec2  PANEL_SIZE @local = { 380, 260 };

struct FreeCamera @local {
    Vec3  position;
    float yaw;
    float pitch;
    float speed;
}

struct Controls @local {
    NavDebugOptions draw;
    bool            spans;
}

struct BuildTotals @local {
    uint built;
    uint skipped;
    uint failed;
}

struct Level @local {
    Node* platform;
    Node* camera_node;
    bool  platform_shifted;
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
    if (!input.mouse_captured_by_gui) {
        if (input.button_down(platform::MouseButton.RIGHT)) {
            camera.yaw -= input.mouse_delta.x * FREE_LOOK_RADIANS_PER_PIXEL;
            camera.pitch = math::clamp(
                camera.pitch - input.mouse_delta.y * FREE_LOOK_RADIANS_PER_PIXEL,
                -FREE_PITCH_LIMIT,
                FREE_PITCH_LIMIT,
            );
        }
        if (input.wheel != 0) camera.speed *= math::pow(FREE_SPEED_WHEEL_STEP, input.wheel);
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
        float speed = camera.speed * (input.key_down(platform::Scancode.LSHIFT) ? FREE_FAST_MULTIPLIER : 1);
        camera.position += direction * (speed * delta_seconds);
    }
    camera_node.local.position = camera.position;
    camera_node.local.rotation = maths::look_rotation(forward, up);
}

fn MaterialId? add_colour(AssetStore* assets, Vec4 color, String key) @local {
    StandardParams params = material::STANDARD_PARAMS_DEFAULT;
    params.base_color = color;
    params.metallic = 0;
    params.roughness = 0.85f;
    return assets.add_material(material::standard(params), key);
}

fn Node*? add_block(
    Scene* scene,
    AssetStore* assets,
    MaterialId material,
    Vec3 size,
    Vec3 position,
    float pitch = 0,
) @local {
    GeometryId block;
    @pool() {
        Geometry geometry = geometry::box(tmem, size.x, size.y, size.z);
        block = assets.add_geometry(&geometry)!;
    };
    Node* node = scene.add_mesh(block, material)!;
    node.local.position = position;
    node.local.rotation = quaternion::from_axis_angle{float}({ 1, 0, 0 }, pitch);
    return node;
}

fn Level? build_level(AssetStore* assets, Scene* scene) @local {
    Level level;
    MaterialId floor_material = add_colour(assets, { 0.55f, 0.58f, 0.55f, 1 }, "navmesh/floor")!;
    MaterialId block_material = add_colour(assets, { 0.75f, 0.62f, 0.45f, 1 }, "navmesh/block")!;
    MaterialId steep_material = add_colour(assets, { 0.8f, 0.35f, 0.3f, 1 }, "navmesh/steep")!;
    MaterialId platform_material = add_colour(assets, { 0.3f, 0.5f, 0.9f, 1 }, "navmesh/platform")!;

    GeometryId floor_geometry;
    @pool() {
        Geometry floor = geometry::plane(tmem, FLOOR_SIZE, FLOOR_SIZE, FLOOR_SEGMENTS, FLOOR_SEGMENTS);
        floor_geometry = assets.add_geometry(&floor, "navmesh/floor_plane")!;
    };
    scene.add_mesh(floor_geometry, floor_material, name: "floor")!;

    add_block(
        scene:    scene,
        assets:   assets,
        material: block_material,
        size:     { 3, 0.2f, 6 },
        position: { -7, 0.85f, -5 },
        pitch:    RAMP_ANGLE,
    )!;
    add_block(
        scene:    scene,
        assets:   assets,
        material: steep_material,
        size:     { 3, 0.2f, 3 },
        position: { -1, 1.2f, -6 },
        pitch:    STEEP_RAMP_ANGLE,
    )!;
    for (uint step = 1; step <= 3; step++) {
        add_block(
            scene:    scene,
            assets:   assets,
            material: block_material,
            size:     { 4, step * STEP_HEIGHT, STEP_DEPTH },
            position: { -7, step * STEP_HEIGHT * 0.5f, 2 + step * STEP_DEPTH },
        )!;
    }
    add_block(
        scene:    scene,
        assets:   assets,
        material: block_material,
        size:     { 16, 2, 0.4f },
        position: { 0, 1, 10 },
    )!;
    add_block(
        scene:    scene,
        assets:   assets,
        material: block_material,
        size:     { 0.4f, 2, 7 },
        position: { 0, 1, 3 },
    )!;
    level.platform = add_block(
        scene:    scene,
        assets:   assets,
        material: platform_material,
        size:     { 4, 1, 4 },
        position: PLATFORM_HOME,
    )!;

    Node* mud = scene.add_node(name: "mud")!;
    scene.add_nav_volume(mud, {
        .kind = BOX,
        .area = MUD_AREA,
        .box  = { .min = { 3, -0.5f, 2 }, .max = { 9, 0.5f, 8 } },
    })!;

    Node* sun = scene.add_light(light::directional({ 1, 0.95f, 0.85f }, 3), name: "sun")!;
    sun.local.rotation = maths::look_rotation(((Vec3){ -0.4f, -1, -0.3f }).normalize(), { 0, 1, 0 });
    scene.background = { .kind = COLOR, .color = { 0.55f, 0.7f, 0.9f, 1 } };
    level.camera_node = scene.add_camera(camera::perspective_deg(60, 0.1f), name: "camera")!;
    scene.update_world();
    scene.add_nav_sources(scene.root);
    return level;
}

fn void move_platform(Scene* scene, Level* level) @local {
    level.platform_shifted = !level.platform_shifted;
    level.platform.local.position.x = PLATFORM_HOME.x - (level.platform_shifted ? PLATFORM_SHIFT : 0);
    scene.update_world();
    scene.get(level.platform, NavSource).mark_changed();
}

fn void draw_panel(NavBuilder* builder, Controls* controls, BuildTotals* totals) @local {
    imgui::set_next_window_pos(PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
    imgui::set_next_window_size(PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
    if (imgui::begin("Navmesh", null, {})) {
        imgui::text("M moves the platform; right drag looks, WASDQE move");
        imgui::checkbox("Tiles", &controls.draw.tiles);
        imgui::checkbox("Polygons", &controls.draw.polys);
        imgui::checkbox("Spans of the rasterizing slot", &controls.spans);
        imgui::separator();
        imgui::text("Tiles: %u x %u   dirty: %u", builder.tiles_x, builder.tiles_z, builder.dirty_count);
        imgui::text("Built: %u   skipped sources: %u   failed: %u", totals.built, totals.skipped, totals.failed);
        if (totals.failed) {
            TileFailure failure = builder.last_failure;
            @pool() {
                imgui::text("Last failure: tile %d %d, %s at %s", failure.tile_x, failure.tile_z,
                    string::tformat_zstr("%s", failure.reason), string::tformat_zstr("%s", failure.stage));
            };
        }
    }
    imgui::end();
}

fn void draw_debug(NavBuilder* builder, debug::DebugDraw* sink, Controls* controls) @local {
    sink.clear();
    builder.debug_draw(sink, controls.draw);
    if (!controls.spans) return;
    foreach (&job : builder.jobs) {
        if (job.state == RASTERIZING) nav::debug_draw_heightfield(&job.heightfield, sink, SPAN_COLOR);
    }
}

fn void? draw_frame(
    render::Renderer* renderer,
    Scene* scene,
    Node* camera_node,
    GuiRenderer* gui_renderer,
    debug::DebugDraw* sink,
    FrameInfo info,
) @local {
    renderer.begin_frame(info)!;
    defer catch render::abort_frame(renderer);
    if (renderer.has_output) {
        renderer.render_view(scene, camera_node, renderer.default_view, sink)!;
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
) @local {
    Level level = build_level(assets, scene)!;
    NavBuilderDesc desc = nav::default_nav_builder_desc({
        .min = { -LEVEL_HALF_SIZE, -1, -LEVEL_HALF_SIZE },
        .max = { LEVEL_HALF_SIZE, LEVEL_TOP, LEVEL_HALF_SIZE },
    });
    desc.rasterize_budget = RASTERIZE_BUDGET;
    NavBuilder builder = nav::create_nav_builder(mem, scene, desc)!;
    defer nav::destroy_nav_builder(&builder);
    NavMesh mesh = nav::create_nav_mesh_for(mem, &builder)!;
    defer nav::destroy_nav_mesh(&mesh);

    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, renderer, window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);
    debug::DebugDraw sink = debug::create_debug_draw(mem);
    defer debug::destroy_debug_draw(&sink);

    FreeCamera camera = {
        .position = CAMERA_START,
        .yaw      = (float)math::PI,
        .pitch    = CAMERA_START_PITCH,
        .speed    = FREE_SPEED,
    };
    Controls controls = { .draw = { .tiles = true, .polys = true }, .spans = true };
    BuildTotals totals;
    renderer.prepare_scene(scene)!;

    while (window.poll()) {
        Input* input = &window.input;
        if (input.key_released(platform::Scancode.ESCAPE) && !input.keyboard_captured_by_gui) break;
        gui_renderer.new_frame();
        defer {
            if (gui_renderer.frame_open) gui_renderer.finish_frame();
        }
        draw_panel(&builder, &controls, &totals);

        if (input.key_pressed(platform::Scancode.M) && !input.keyboard_captured_by_gui) move_platform(scene, &level);
        apply_free_camera(
            camera:        &camera,
            input:         input,
            camera_node:   level.camera_node,
            delta_seconds: window.clock.delta,
        );
        scene.update_world();

        NavSyncResult result = nav::nav_sync(
            builder: &builder,
            mesh:    &mesh,
            scene:   scene,
            assets:  assets,
            budget:  TILES_PER_FRAME,
        );
        totals.built += result.built;
        totals.skipped += result.skipped;
        totals.failed += result.failed;
        draw_debug(&builder, &sink, &controls);
        gui_renderer.finish_frame();

        platform::sync_window(window, renderer);
        draw_frame(
            renderer:     renderer,
            scene:        scene,
            camera_node:  level.camera_node,
            gui_renderer: &gui_renderer,
            sink:         &sink,
            info:         { .time = window.clock.total, .delta = window.clock.delta },
        )!;
    }
}

fn int main() {
    platform::Window window = platform::create_window(platform::default_window_desc("c3d navmesh", 1280, 720))!!;
    defer platform::destroy_window(&window);

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      { .validation = true, .application_name = "c3d_navmesh" },
    )!!;
    defer render::destroy_renderer(&renderer);

    Scene scene = scene::create_scene(mem, { .max_nodes = SCENE_NODE_CAPACITY });
    defer scene::destroy_scene(&scene);
    nav::register_nav(&scene)!!;

    if (catch excuse = run(
        window:   &window,
        renderer: &renderer,
        assets:   &assets,
        scene:    &scene,
    )) {
        io::eprintfn("navmesh example failed: %s", excuse);
        return 1;
    }
    io::printfn("closed after %d frames, %.2fs", window.clock.frame, window.clock.total);
    return 0;
}
