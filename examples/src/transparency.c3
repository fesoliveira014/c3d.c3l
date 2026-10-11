module transparency_example;

import std::io;
import std::math;
import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::platform;
import c3d::render;
import c3d::scene;

const float ORBIT_RADIANS_PER_PIXEL @local = 0.005f;
const float ORBIT_PITCH_LIMIT @local = 1.5f; // just short of the poles, where the up vector degenerates
const float ORBIT_ZOOM_STEP @local = 0.9f;
const float ORBIT_DISTANCE_MIN @local = 1.0f;
const float ORBIT_DISTANCE_MAX @local = 50.0f;
const double STATS_PERIOD_SECONDS @local = 1.0;
const float[4] ROUGHNESS_STEPS @local = { 0, 0.25f, 0.5f, 1 };
const float GLASS_IOR @local = 1.5f;
const float GLASS_THICKNESS @local = 0.2f;
const Vec3 SLAB_SIZE @local = { 2.4f, 1.6f, 0.2f };
const Vec3 SLAB_POSITION @local = { 0, 0.9f, 0 };
const Vec3 BACKDROP_POSITION @local = { 0, 1, -1.5f };
const Vec3 BACKDROP_SCALE @local = { 7, 1, 4.5f };
const Vec2 BACKDROP_TILES @local = { 8, 5 };
const float PROP_RADIUS @local = 0.35f;
const float PROP_SPACING @local = 1.6f;
const float PROP_DEPTH @local = -1.1f;

struct Orbit @local {
    Vec3  target;
    float distance;
    float yaw;
    float pitch;
}

fn void apply_orbit(Orbit* orbit, Input* input, Node* camera_node) @local {
    if (!input.mouse_captured_by_gui) {
        if (input.button_down(platform::MouseButton.LEFT)) {
            orbit.yaw -= input.mouse_delta.x * ORBIT_RADIANS_PER_PIXEL;
            orbit.pitch = math::clamp(
                x:     orbit.pitch + input.mouse_delta.y * ORBIT_RADIANS_PER_PIXEL,
                lower: -ORBIT_PITCH_LIMIT,
                upper: ORBIT_PITCH_LIMIT,
            );
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

fn Material glass_material(float roughness) @local {
    PhysicalParams params = material::PHYSICAL_PARAMS_DEFAULT;
    params.standard.metallic = 0;
    params.standard.roughness = roughness;
    params.transmission = 1;
    params.ior = GLASS_IOR;
    params.thickness = GLASS_THICKNESS;
    return material::physical(params);
}

fn int main() {
    platform::Window window = platform::create_window(
        platform::default_window_desc("c3d transparency", 1280, 720))!!;
    defer platform::destroy_window(&window);

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      { .validation = true, .application_name = "c3d_transparency" },
    )!!;
    defer render::destroy_renderer(&renderer);

    GeometryId plane;
    GeometryId slab;
    GeometryId ball;
    @pool() {
        Geometry plane_geometry = geometry::plane(tmem, 1, 1);
        plane = assets.add_geometry(&plane_geometry, "transparency/plane")!!;

        Geometry slab_geometry = geometry::box(tmem, SLAB_SIZE.x, SLAB_SIZE.y, SLAB_SIZE.z);
        slab = assets.add_geometry(&slab_geometry, "transparency/slab")!!;

        Geometry ball_geometry = geometry::sphere(tmem, PROP_RADIUS);
        ball = assets.add_geometry(&ball_geometry, "transparency/ball")!!;
    };

    MaterialId glass = assets.add_material(glass_material(ROUGHNESS_STEPS[0]), "transparency/glass")!!;
    MaterialId backdrop_material = assets.add_material(material::basic({
        .color = { 1, 1, 1, 1 },
        .map   = material::texture_slot(
            texture:   asset::TEXTURE_CHECKER,
            sampler:   asset::SAMPLER_NEAREST,
            uv_set:    0,
            transform: { .scale = BACKDROP_TILES },
        ),
    }), "transparency/backdrop")!!;
    Vec4[3] prop_colors = { { 0.85f, 0.15f, 0.1f, 1 }, { 0.1f, 0.6f, 0.2f, 1 }, { 0.15f, 0.3f, 0.9f, 1 } };

    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);

    Node* backdrop = scene.add_mesh(plane, backdrop_material, name: "backdrop")!!;
    backdrop.local.position = BACKDROP_POSITION;
    backdrop.local.rotation = quaternion::from_axis_angle{float}({ 1, 0, 0 }, math::PI / 2);
    backdrop.local.scale = BACKDROP_SCALE;
    foreach (index, color : prop_colors) {
        MaterialId prop_material = assets.add_material(material::standard({
            .base_color = color,
            .metallic   = 0,
            .roughness  = 0.5f,
        }))!!;
        Node* prop = scene.add_mesh(ball, prop_material, name: "prop")!!;
        prop.local.position = { ((float)index - 1) * PROP_SPACING, SLAB_POSITION.y, PROP_DEPTH };
    }
    Node* pane = scene.add_mesh(slab, glass, name: "glass")!!;
    pane.local.position = SLAB_POSITION;

    Node* sun = scene.add_light(light::directional({ 1, 1, 1 }, 3, false), name: "sun")!!;
    sun.local.rotation = maths::look_rotation((Vec3){ -0.4f, -0.6f, -1 }.normalize(), { 0, 1, 0 });

    Node* camera_node = scene.add_camera(camera::perspective_deg(55, 0.1f), name: "camera")!!;
    Orbit orbit = { .target = { 0, 0.9f, -0.4f }, .distance = 5, .yaw = 0.1f, .pitch = 0.1f };
    usz roughness_step;
    double last_print;

    renderer.prepare_scene(&scene)!!;

    io::printn("drag to orbit, wheel to zoom, R steps the glass roughness, Escape release quits");

    while (window.poll()) {
        Input* input = &window.input;
        if (input.key_released(platform::Scancode.ESCAPE)) break;

        if (input.key_pressed(platform::Scancode.R) && !input.keyboard_captured_by_gui) {
            roughness_step = (roughness_step + 1) % ROUGHNESS_STEPS.len;
            assets.replace_material(glass, glass_material(ROUGHNESS_STEPS[roughness_step]));
            io::printfn("glass roughness %.2f", ROUGHNESS_STEPS[roughness_step]);
        }

        apply_orbit(&orbit, input, camera_node);
        scene.update_world();

        platform::sync_window(&window, &renderer);
        renderer.render(&scene, camera_node, { .time = window.clock.total, .delta = window.clock.delta })!!;

        if (window.clock.total - last_print >= STATS_PERIOD_SECONDS) {
            last_print = window.clock.total;
            io::printfn("draws %d, scene snapshots %d, frame %.2f ms at %dx%d",
                renderer.stats.draws, renderer.stats.scene_snapshots, renderer.stats.frame_ms,
                renderer.output_width, renderer.output_height);
        }
    }

    io::printfn("closed after %d frames, %.2fs", window.clock.frame, window.clock.total);
    return 0;
}
