module texture_bc_example;

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

const uint TEXTURE_SIZE @local = 64;
const uint MIP_COUNT @local = 7;
const usz[MIP_COUNT] MIP_OFFSETS @local = { 0, 2048, 2560, 2688, 2720, 2728, 2736 };
const usz[MIP_COUNT] MIP_BYTES @local = { 2048, 512, 128, 32, 8, 8, 8 };
const float SURFACE_REPEATS @local = 16;
const float ORBIT_RADIANS_PER_PIXEL @local = 0.005f;
const float ORBIT_PITCH_MIN @local = 0.05f; // keeps the one-sided surface in front of the camera
const float ORBIT_PITCH_MAX @local = 1.5f; // avoids the degenerate up vector at a pole
const float ORBIT_ZOOM_STEP @local = 0.9f;
const float ORBIT_DISTANCE_MIN @local = 2;
const float ORBIT_DISTANCE_MAX @local = 100;
const usz MOUSE_BUTTON_LEFT @local = 1; // SDL button index

struct Orbit @local {
    Vec3 target;
    float distance;
    float yaw;
    float pitch;
}

fn void apply_orbit(Orbit* orbit, Input* input, Node* camera_node) @local {
    if (input.mouse_buttons[MOUSE_BUTTON_LEFT]) {
        orbit.yaw -= input.mouse_delta.x * ORBIT_RADIANS_PER_PIXEL;
        orbit.pitch = math::clamp(
            orbit.pitch + input.mouse_delta.y * ORBIT_RADIANS_PER_PIXEL,
            ORBIT_PITCH_MIN,
            ORBIT_PITCH_MAX,
        );
    }
    if (input.wheel != 0) {
        float zoomed = orbit.distance * math::pow(ORBIT_ZOOM_STEP, input.wheel);
        orbit.distance = math::clamp(zoomed, ORBIT_DISTANCE_MIN, ORBIT_DISTANCE_MAX);
    }

    Vec3 offset = {
        math::cos(orbit.pitch) * math::sin(orbit.yaw),
        math::sin(orbit.pitch),
        math::cos(orbit.pitch) * math::cos(orbit.yaw),
    };
    camera_node.local.position = orbit.target + offset * orbit.distance;
    camera_node.local.rotation = maths::look_rotation(-offset, { 0, 1, 0 });
}

fn void select_sampler(AssetStore* assets, MaterialId material_id, Input* input) @local {
    SamplerId sampler;
    if (input.keys_pressed[(usz)sdl::Scancode.N]) {
        sampler = asset::SAMPLER_NEAREST;
        io::printn("nearest sampling");
    } else if (input.keys_pressed[(usz)sdl::Scancode.L]) {
        sampler = asset::SAMPLER_LINEAR_REPEAT;
        io::printn("trilinear sampling");
    } else if (input.keys_pressed[(usz)sdl::Scancode.A]) {
        sampler = asset::SAMPLER_ANISOTROPIC;
        io::printn("anisotropic sampling");
    } else {
        return;
    }

    assets.material(material_id).data.basic.map.sampler = sampler;
    assets.mark_material_dirty(material_id);
}

fn TextureId? add_compressed_texture(AssetStore* assets) @local {
    char[] bytes = $embed("../assets/bc1_mips.bin");
    TextureMipData[MIP_COUNT] levels;
    for (uint mip = 0; mip < MIP_COUNT; mip++) {
        levels[mip] = {
            .mip = mip,
            .layer = 0,
            .bytes = bytes[MIP_OFFSETS[mip]:MIP_BYTES[mip]],
        };
    }

    TextureDesc desc = material::texture_2d_desc(TEXTURE_SIZE, TEXTURE_SIZE, BC1_RGBA_SRGB);
    desc.generate_mips = false;
    desc.mip_levels = MIP_COUNT;
    return assets.add_texture_mips(desc, levels[..], "compressed_map");
}

fn void? run() @local {
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    TextureId texture = add_compressed_texture(&assets)!;
    MaterialId material_id = assets.add_material(material::basic({
        .color = { 1, 1, 1, 1 },
        .map = material::texture_slot(texture),
    }))!;

    GeometryId surface_geometry;
    @pool() {
        Geometry surface = geometry::plane(tmem, 12, 26);
        foreach (&uv : surface.uv0) *uv *= SURFACE_REPEATS;
        surface_geometry = assets.add_geometry(&surface)!;
    };

    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    Node* surface = scene.add_mesh(surface_geometry, material_id, name: "compressed_surface")!;
    surface.local.position = { 0, 0, -6 };
    Node* camera_node = scene.add_camera(camera::perspective_deg(55, 0.1f), name: "camera")!;
    Orbit orbit = { .target = { 0, 0, -5 }, .distance = 12, .pitch = 0.32f };
    Input initial_input;
    apply_orbit(&orbit, &initial_input, camera_node);
    scene.update_world();

    platform::Window window = platform::create_window(
        platform::default_window_desc("c3d BC textures", 1280, 720))!;
    defer platform::destroy_window(&window);
    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window: &window,
        assets: &assets,
        desc: { .validation = true, .application_name = "c3d_texture_bc" },
    )!;
    defer render::destroy_renderer(&renderer);
    renderer.prepare_scene(&scene)!;

    io::printn("BC1_RGBA_SRGB, 64x64, seven supplied mips, 2744 compressed bytes");
    io::printn("mips 0..6: red, green, blue, yellow, magenta, cyan, white");
    io::printn("N nearest, L trilinear, A anisotropic; drag to orbit, wheel to zoom; Escape release quits");

    while (window.poll()) {
        Input* input = &window.input;
        if (input.keys_released[(usz)sdl::Scancode.ESCAPE]) break;

        select_sampler(&assets, material_id, input);
        apply_orbit(&orbit, input, camera_node);
        scene.update_world();

        platform::sync_window(&window, &renderer);
        renderer.render(&scene, camera_node, { .time = window.clock.total, .delta = window.clock.delta })!;
    }
}

fn int main() {
    if (catch excuse = run()) {
        io::printfn("BC texture example failed: %s", excuse);
        return 1;
    }
    return 0;
}
