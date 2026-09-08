module cube_example;

import std::io;
import std::math;
import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::platform;
import c3d::render;
import c3d::scene;
import sdl;

const float ORBIT_RADIANS_PER_PIXEL @local = 0.005f;
const float ORBIT_PITCH_LIMIT @local = 1.5f; // just short of the poles, where the up vector degenerates
const float ORBIT_ZOOM_STEP @local = 0.9f;
const float ORBIT_DISTANCE_MIN @local = 1.0f;
const float ORBIT_DISTANCE_MAX @local = 50.0f;
const float SPIN_RADIANS_PER_SECOND @local = 0.8f;
const float MOVE_UNITS_PER_SECOND @local = 2.0f;
const double STATS_PERIOD_SECONDS @local = 1.0;
const usz MOUSE_BUTTON_LEFT @local = 1; // SDL button index

struct Orbit @local {
    Vec3  target;
    float distance;
    float yaw;
    float pitch;
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

fn void move_cube(Node* cube, Input* input, float delta) @local {
    if (input.keyboard_captured_by_gui) return;
    float step = MOVE_UNITS_PER_SECOND * delta;
    if (input.keys[(usz)sdl::Scancode.LEFT]) cube.local.position.x -= step;
    if (input.keys[(usz)sdl::Scancode.RIGHT]) cube.local.position.x += step;
    if (input.keys[(usz)sdl::Scancode.UP]) cube.local.position.y += step;
    if (input.keys[(usz)sdl::Scancode.DOWN]) cube.local.position.y -= step;
}

fn int main() {
    platform::Window window = platform::create_window(
        platform::default_window_desc("c3d cube", 1280, 720))!!;
    defer platform::destroy_window(&window);

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      { .validation = true, .application_name = "c3d_cube" },
    )!!;
    defer render::destroy_renderer(&renderer);

    GeometryId box;
    GeometryId ball;
    @pool() {
        Geometry box_geometry = geometry::box(tmem, 1, 1, 1);
        box = assets.add_geometry(&box_geometry, "cube/box")!!;
        Geometry ball_geometry = geometry::sphere(tmem, 0.6f);
        ball = assets.add_geometry(&ball_geometry, "cube/sphere")!!;
    };
    MaterialId red = assets.add_material(material::basic({ .color = { 0.9f, 0.2f, 0.2f, 1 } }), "cube/red")!!;
    MaterialId blue = assets.add_material(material::basic({ .color = { 0.2f, 0.4f, 0.9f, 1 } }), "cube/blue")!!;

    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    Node* cube = scene.add_mesh(box, red, name: "cube")!!;
    Node* sphere = scene.add_mesh(ball, blue, name: "sphere")!!;
    sphere.local.position = { 0.7f, 0.4f, 0.3f };
    Node* camera_node = scene.add_camera(camera::perspective_deg(60, 0.1f), name: "camera")!!;
    Orbit orbit = { .distance = 5 };
    bool orthographic;
    double last_print;

    renderer.prepare_scene(&scene)!!;
    io::printn("drag to orbit, wheel to zoom, O toggles the lens, arrows move the cube, Escape release quits");

    while (window.poll()) {
        Input* input = &window.input;
        if (input.keys_released[(usz)sdl::Scancode.ESCAPE]) break;
        if (input.keys_pressed[(usz)sdl::Scancode.O] && !input.keyboard_captured_by_gui) {
            orthographic = !orthographic;
            *scene.get(camera_node, camera::Camera) = orthographic
                ? camera::orthographic(6, 0.1f, 100)
                : camera::perspective_deg(60, 0.1f);
        }
        move_cube(cube, input, window.clock.delta);
        cube.local.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 },
            (float)window.clock.total * SPIN_RADIANS_PER_SECOND);
        apply_orbit(&orbit, input, camera_node);
        scene.update_world();

        platform::sync_window(&window, &renderer);
        renderer.render(&scene, camera_node, { .time = window.clock.total, .delta = window.clock.delta })!!;

        if (window.clock.total - last_print >= STATS_PERIOD_SECONDS) {
            last_print = window.clock.total;
            io::printfn("draws %d, triangles %d, culled %d, frame %.2f ms at %dx%d",
                renderer.stats.draws, renderer.stats.triangles, renderer.stats.culled, renderer.stats.frame_ms,
                renderer.hdr_color.width, renderer.hdr_color.height);
        }
    }

    io::printfn("closed after %d frames, %.2fs", window.clock.frame, window.clock.total);
    return 0;
}
