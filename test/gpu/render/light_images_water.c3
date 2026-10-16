module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::landscape::water;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::render @public;
import c3d::scene;
import std::io;
import std::core::string;
import std::math;

const uint IMAGE_WATER_SIZE @private = 64;
const Vec3 IMAGE_WATER_CAMERA @private = { 0, 1.5f, 4 };
const Vec3 IMAGE_WATER_FLOATING_BOX @private = { 0, 2, -8 };
const Vec3 IMAGE_WATER_BURIED_BOX @private = { 3, -0.6f, -8 };

fn void? add_water_image_box(
    Fixture* fixture,
    Scene* scene,
    Vec3 position,
    Vec3 size,
) @private {
    StandardParams glow = material::STANDARD_PARAMS_DEFAULT;
    glow.base_color = { 0, 0, 0, 1 };
    glow.emissive = { 1, 1, 1 };
    glow.emissive_strength = 20;
    MaterialId material = fixture.assets.add_material(material::standard(glow))!;
    Node* node = scene.add_mesh(fixture.box, material, name: "emissive")!;
    node.local.position = position;
    node.local.scale = size;
}

fn float water_image_luminance(Vec4 color) @private {
    return 0.2126f * color.x + 0.7152f * color.y + 0.0722f * color.z;
}

fn void? check_water_image(
    Fixture* fixture,
    Scene* scene,
    Node* camera_node,
    LightImageView image,
    LightSelection lights,
) @private {
    CameraMatrices matrices = camera::derive_matrices(
        *scene.get(camera_node, Camera), camera_node.world, { IMAGE_WATER_SIZE, IMAGE_WATER_SIZE });
    Vec4[] pixels = mem::new_array(Vec4, IMAGE_WATER_SIZE * IMAGE_WATER_SIZE);
    defer free(pixels);
    ulong frame = fixture.renderer.frame_index;
    fixture.renderer.read_render_target(image.target, ((char*)pixels.ptr)[:pixels.len * Vec4::size])!;
    assert(fixture.renderer.frame_index == frame);
    Vec3 box_image = IMAGE_WATER_FLOATING_BOX * (Vec3){ 1, -1, 1 };
    Vec3[3] points = {
        box_image,
        IMAGE_WATER_BURIED_BOX * (Vec3){ 1, -1, 1 },
        { -4, 0, -8 },
    };
    float[3] values;
    foreach (index, point : points) {
        Vec4 clip = matrices.view_proj * (Vec4){ point.x, point.y, point.z, 1 };
        Vec2 uv = { clip.x / clip.w * 0.5f + 0.5f, 0.5f - clip.y / clip.w * 0.5f };
        uint x = (uint)(uv.x * IMAGE_WATER_SIZE);
        uint y = (uint)(uv.y * IMAGE_WATER_SIZE);
        assert(x < IMAGE_WATER_SIZE && y < IMAGE_WATER_SIZE);
        values[index] = water_image_luminance(pixels[y * IMAGE_WATER_SIZE + x]);
    }
    Vec3 ray = box_image - IMAGE_WATER_CAMERA;
    Vec3 plane_hit = IMAGE_WATER_CAMERA + ray * (-IMAGE_WATER_CAMERA.y / ray.y);
    float normal_view = (IMAGE_WATER_CAMERA - plane_hit).normalize().y;
    float complement = 1 - normal_view;
    float schlick = 0.02f + 0.98f * complement * complement * complement * complement * complement;
    float minimum = 0.5f * schlick * 20;
    io::printfn("water_semantic,%s,%s,%s,%s,%s,%s", lights, frame, values[0], values[1], values[2], minimum);
    assert(values[0] >= minimum);
    assert(values[1] <= 0.01f);
    assert(values[2] <= 0.01f);
}

fn void? capture_water_images(LightImageRun run, LightSelection lights) @private {
    Fixture fixture;
    create_fixture(mem, &fixture)!;
    defer destroy_fixture(&fixture);
    Scene scene = scene::create_scene(fixture.allocator, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    scene.background = { .kind = COLOR, .color = { 0, 0, 0, 1 } };
    scene.ambient_color = {};
    water::register_water(&scene, &fixture.assets)!;
    WaterDesc water_desc = water::default_water_desc();
    water_desc.wave_count = 0;
    water_desc.extent = 40;
    water_desc.cell_size = 1;
    water_desc.absorption_color = { 0.001f, 0.001f, 0.001f };
    water_desc.absorption_distance = 0.1f;
    water_desc.scatter_color = {};
    water_desc.march_reflections = false;
    Node* water_node = scene.add_node(name: "water")!;
    water_node.layers = 2;
    scene.update_world();
    water::add_water(
        scene: &scene,
        assets: &fixture.assets,
        node: water_node,
        desc: water_desc,
    )!;
    add_water_image_box(
        fixture: &fixture,
        scene: &scene,
        position: IMAGE_WATER_FLOATING_BOX,
        size: { 1, 1, 1 },
    )!;
    add_water_image_box(
        fixture: &fixture,
        scene: &scene,
        position: IMAGE_WATER_BURIED_BOX,
        size: { 0.5f, 0.5f, 0.5f },
    )!;
    Node* sun = scene.add_light(light::directional({ 1, 1, 1 }, 3), name: "sun")!;
    sun.local.rotation = maths::look_rotation(TWIN_SUN_DIRECTION.normalize(), { 0, 1, 0 });
    foreach (position : TWIN_LAMP_POSITIONS) {
        Node* lamp = scene.add_light(light::point({ 1, 0.9f, 0.8f }, TWIN_LAMP_INTENSITY, TWIN_LAMP_RANGE))!;
        lamp.local.position = position;
    }
    Node* camera_node = scene.add_camera(camera::perspective_deg(60, 0.5f, 100))!;
    camera_node.local.position = IMAGE_WATER_CAMERA;
    camera_node.local.rotation = maths::look_rotation(((Vec3){ 0, -0.25f, -1 }).normalize(), { 0, 1, 0 });
    scene.update_world();
    water::update(
        scene: &scene,
        assets: &fixture.assets,
        viewing_camera: camera_node.id,
        wind_velocity: {},
        time: 0.5,
    )!;
    WaterRuntime* runtime = scene.get(water_node, WaterRuntime);
    LightImageView primary = create_light_image_view(
        fixture: &fixture,
        width: IMAGE_WATER_SIZE,
        height: IMAGE_WATER_SIZE,
        output: OutputMode.LINEAR_HDR,
        shading: ShadingPath.FORWARD,
        lights: lights,
    )!;
    LightImageView mirror = create_light_image_view(
        fixture: &fixture,
        width: IMAGE_WATER_SIZE,
        height: IMAGE_WATER_SIZE,
        output: OutputMode.LINEAR_HDR,
        shading: ShadingPath.FORWARD,
        lights: lights,
    )!;
    ViewDesc mirror_desc = fixture.renderer.views.get(mirror.view).desc;
    mirror_desc.clip_plane = runtime.clip_plane;
    render::configure_view(&fixture.renderer, mirror.view, mirror_desc)!;
    water::set_reflection_target(&scene, &fixture.assets, water_node, mirror.target);
    Node* mirror_node = scene.node(runtime.mirror);
    save_light_image_inputs(
        run: run,
        fixture: &fixture,
        scene: &scene,
        camera_node: camera_node,
        image: primary,
        name: string::tformat("water_%s_primary", lights),
        traced: false,
    )!;
    save_light_image_inputs(
        run: run,
        fixture: &fixture,
        scene: &scene,
        camera_node: mirror_node,
        image: mirror,
        name: string::tformat("water_%s_mirror", lights),
        traced: false,
    )!;
    Renderer* renderer = &fixture.renderer;
    renderer.prepare_scene(&scene)!;
    for (uint frame = 1; frame <= 8; frame++) {
        scene.update_world();
        water::update(
            scene: &scene,
            assets: &fixture.assets,
            viewing_camera: camera_node.id,
            wind_velocity: {},
            time: 0.5,
        )!;
        renderer.begin_frame({ .time = 0.5, .delta = 0.1f })!;
        defer catch render::abort_frame(renderer);
        renderer.render_view(&scene, mirror_node, mirror.view)!;
        renderer.finish_view(mirror.view)!;
        renderer.render_view(&scene, camera_node, primary.view)!;
        renderer.finish_view(primary.view)!;
        renderer.end_frame()!;
        assert(renderer.frame_submitted && renderer.frame_index == frame);
        assert(renderer.stats.shader_rejections == 0);
    }
    save_light_image(
        run: run,
        fixture: &fixture,
        image: primary,
        name: string::tformat("water_%s_primary", lights),
    )!;
    save_light_image(
        run: run,
        fixture: &fixture,
        image: mirror,
        name: string::tformat("water_%s_mirror", lights),
    )!;
    check_water_image(
        fixture: &fixture,
        scene: &scene,
        camera_node: camera_node,
        image: primary,
        lights: lights,
    )!;
}
