module textured_example;

import std::io;
import std::math;
import c3d;
import c3d::asset;
import c3d::asset::image;
import c3d::camera;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::platform;
import c3d::render;
import c3d::scene;
import sdl;

const float ORBIT_RADIANS_PER_PIXEL @local = 0.005f;
const float ORBIT_PITCH_LIMIT @local = 1.5f; // avoids the poles, where the up vector degenerates
const float ORBIT_ZOOM_STEP @local = 0.9f;
const float ORBIT_DISTANCE_MIN @local = 2;
const float ORBIT_DISTANCE_MAX @local = 40;
const usz MOUSE_BUTTON_LEFT @local = 1; // SDL button index
const float CHECKER_REPEATS @local = 24;
const float UV_REPEAT_SCALE @local = 4;
const float UV_ROTATION_STEP @local = math::PI / 4;
const Vec2 UV_OFFSET_STEP @local = { 0.25f, 0.125f };

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
            -ORBIT_PITCH_LIMIT,
            ORBIT_PITCH_LIMIT,
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

fn void change_maps(AssetStore* assets, MaterialId[] materials, Input* input) @local {
    bool nearest = input.keys_pressed[(usz)sdl::Scancode.N];
    bool trilinear = input.keys_pressed[(usz)sdl::Scancode.L];
    bool anisotropic = input.keys_pressed[(usz)sdl::Scancode.A];
    bool scale = input.keys_pressed[(usz)sdl::Scancode.S];
    bool rotate = input.keys_pressed[(usz)sdl::Scancode.R];
    bool offset = input.keys_pressed[(usz)sdl::Scancode.O];
    bool uv_set = input.keys_pressed[(usz)sdl::Scancode.U];
    bool reset = input.keys_pressed[(usz)sdl::Scancode.BACKSPACE];
    if (!(nearest || trilinear || anisotropic || scale || rotate || offset || uv_set || reset)) return;

    foreach (material_id : materials) {
        TextureSlot* slot = &assets.material(material_id).data.basic.map;
        if (nearest) slot.sampler = asset::SAMPLER_NEAREST;
        if (trilinear) slot.sampler = asset::SAMPLER_LINEAR_REPEAT;
        if (anisotropic) slot.sampler = asset::SAMPLER_ANISOTROPIC;
        if (scale) slot.transform.scale = slot.transform.scale.x == 1
            ? (Vec2){ UV_REPEAT_SCALE, UV_REPEAT_SCALE } : (Vec2){ 1, 1 };
        if (rotate) slot.transform.rotation += UV_ROTATION_STEP;
        if (offset) slot.transform.offset += UV_OFFSET_STEP;
        if (uv_set) slot.uv_set ^= 1;
        if (reset) {
            slot.sampler = asset::SAMPLER_LINEAR_REPEAT;
            slot.transform = material::UV_TRANSFORM_IDENTITY;
            slot.uv_set = 0;
        }
        assets.mark_material_dirty(material_id);
    }

    TextureSlot* slot = &assets.material(materials[0]).data.basic.map;
    io::printf("sampler %d, UV%d", slot.sampler.index, slot.uv_set);
    io::printf(", scale %.1f, rotation %.2f rad", slot.transform.scale.x, slot.transform.rotation);
    io::printfn(", offset %s", slot.transform.offset);
}

fn void add_second_uv(Allocator allocator, Geometry* geometry) @local {
    geometry.uv1 = alloc::new_array(allocator, Vec2, geometry.uv0.len);
    foreach (index, uv : geometry.uv0) geometry.uv1[index] = { uv.y * 2, uv.x * 2 };
}

fn Geometry image_quad(Allocator allocator) @local {
    Vec3[] positions = alloc::new_array(allocator, Vec3, 4);
    positions[0] = { -1, -1, 0 };
    positions[1] = { 1, -1, 0 };
    positions[2] = { 1, 1, 0 };
    positions[3] = { -1, 1, 0 };
    Vec2[] uv0 = alloc::new_array(allocator, Vec2, 4);
    uv0[0] = { 0, 1 };
    uv0[1] = { 1, 1 };
    uv0[2] = { 1, 0 };
    uv0[3] = { 0, 0 };
    uint[] indices = alloc::new_array(allocator, uint, 6);
    indices[..] = { 0, 1, 2, 0, 2, 3 }[..];

    Geometry geometry = {
        .topology = TRIANGLES,
        .positions = positions,
        .uv0 = uv0,
        .indices = indices,
    };
    add_second_uv(allocator, &geometry);
    geometry.finalize();
    return geometry;
}

fn int main(String[] args) {
    if (args.len > 2) {
        io::printn("usage: textured [image.png|image.jpg]");
        return 1;
    }

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    TextureId image_texture;
    if (args.len == 2) {
        TextureId? loaded = image::load_texture(&assets, args[1], true);
        if (catch excuse = loaded) {
            io::printfn("Could not load image: %s", excuse);
            return 1;
        }
        image_texture = loaded;
    } else {
        Image decoded = image::decode_image(mem, $embed("../assets/texture.png"))!!;
        defer image::destroy_image(&decoded);

        image_texture = assets.add_texture(
            material::texture_2d_desc(decoded.width, decoded.height, RGBA8_SRGB),
            decoded.pixels,
        )!!;
    }

    GeometryId box;
    GeometryId floor;
    GeometryId quad;
    @pool() {
        Geometry box_geometry = geometry::box(
            allocator: tmem,
            width: 1.7f,
            height: 1.7f,
            depth: 1.7f,
        );
        add_second_uv(tmem, &box_geometry);
        box = assets.add_geometry(&box_geometry)!!;

        Geometry floor_geometry = geometry::plane(tmem, 14, 18);
        foreach (&uv : floor_geometry.uv0) *uv *= CHECKER_REPEATS;
        add_second_uv(tmem, &floor_geometry);
        floor = assets.add_geometry(&floor_geometry)!!;

        Geometry quad_geometry = image_quad(tmem);
        quad = assets.add_geometry(&quad_geometry)!!;
    };

    MaterialId image_material = assets.add_material(material::basic({
        .color = { 1, 1, 1, 1 },
        .map = material::texture_slot(image_texture),
    }))!!;
    MaterialId checker_material = assets.add_material(material::basic({
        .color = { 1, 1, 1, 1 },
        .map = material::texture_slot(asset::TEXTURE_CHECKER),
    }))!!;
    MaterialCommon mask = material::MATERIAL_COMMON_DEFAULT;
    mask.alpha_mode = MASK;
    MaterialId mask_material = assets.add_material(material::basic({
        .color = { 1, 1, 1, 1 },
        .map = material::texture_slot(image_texture),
    }, mask))!!;
    MaterialId backdrop_material = assets.add_material(material::basic({ .color = { 0.8f, 0.15f, 0.8f, 1 } }))!!;
    MaterialId[3] mapped_materials = { image_material, checker_material, mask_material };

    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);

    Node* cube = scene.add_mesh(box, image_material, name: "image_cube")!!;
    cube.local.position = { -1.7f, 0, 0 };
    cube.local.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, math::PI / 6);
    Node* checker = scene.add_mesh(floor, checker_material, name: "checker_floor")!!;
    checker.local.position = { 0, -1.1f, -5 };
    Node* cutout = scene.add_mesh(quad, mask_material, name: "masked_image")!!;
    cutout.local.position = { 1.7f, 0, 0 };
    Node* backdrop = scene.add_mesh(quad, backdrop_material, name: "opaque_backdrop")!!;
    backdrop.local.position = { 1.7f, 0, -0.2f };
    Node* camera_node = scene.add_camera(camera::perspective_deg(55, 0.1f), name: "camera")!!;
    Orbit orbit = { .distance = 8, .pitch = 0.25f };
    Input initial_input;
    apply_orbit(&orbit, &initial_input, camera_node);
    scene.update_world();

    platform::Window window = platform::create_window(
        platform::default_window_desc("c3d textured", 1280, 720))!!;
    defer platform::destroy_window(&window);

    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window: &window,
        assets: &assets,
        desc: { .validation = true, .application_name = "c3d_textured" },
    )!!;
    defer render::destroy_renderer(&renderer);
    renderer.prepare_scene(&scene)!!;

    io::printn("N nearest, L trilinear, A anisotropic; S repeat scale, R rotate, O offset, U UV0/UV1");
    io::printn("Backspace resets maps; drag to orbit, wheel to zoom; Escape release quits");

    while (window.poll()) {
        Input* input = &window.input;
        if (input.keys_released[(usz)sdl::Scancode.ESCAPE]) break;

        change_maps(&assets, mapped_materials[..], input);
        apply_orbit(&orbit, input, camera_node);
        scene.update_world();

        platform::sync_window(&window, &renderer);
        renderer.render(&scene, camera_node, { .time = window.clock.total, .delta = window.clock.delta })!!;
    }

    return 0;
}
