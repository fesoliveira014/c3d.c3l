module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::render @public;
import c3d::scene;
import std::core::string;
import std::math;

const uint IMAGE_HALL_LIGHTS @private = 4096;
const float IMAGE_HALL_WIDTH @private = 40;
const float IMAGE_HALL_LENGTH @private = 64;
const Vec3[6] IMAGE_HALL_COLORS @private = {
    { 1, 0.25f, 0.12f }, { 0.15f, 0.5f, 1 }, { 0.2f, 1, 0.4f },
    { 1, 0.65f, 0.2f }, { 0.65f, 0.25f, 1 }, { 0.15f, 0.9f, 1 },
};

struct ImageHall @private {
    Scene scene;
    Node* camera;
}

fn ImageHall? create_image_hall(Fixture* fixture, uint lights, float range) @private {
    ImageHall hall;
    hall.scene = scene::create_scene(fixture.allocator, { .max_nodes = IMAGE_HALL_LIGHTS + 128 });
    defer catch scene::destroy_scene(&hall.scene);
    Scene* scene = &hall.scene;
    StandardParams surface = material::STANDARD_PARAMS_DEFAULT;
    surface.base_color = { 0.65f, 0.65f, 0.65f, 1 };
    surface.roughness = 0.6f;
    MaterialId material = fixture.assets.add_material(material::standard(surface), "hall/surface")!;
    Node* floor = scene.add_mesh(fixture.box, material, name: "floor")!;
    floor.local.position = { 0, -0.25f, 0 };
    floor.local.scale = { IMAGE_HALL_WIDTH, 0.5f, IMAGE_HALL_LENGTH };
    for (uint side = 0; side < 2; side++) {
        Node* wall = scene.add_mesh(fixture.box, material, name: "wall")!;
        wall.local.position = { side ? IMAGE_HALL_WIDTH * 0.5f : -IMAGE_HALL_WIDTH * 0.5f, 3, 0 };
        wall.local.scale = { 0.5f, 6, IMAGE_HALL_LENGTH };
    }
    Node* back = scene.add_mesh(fixture.box, material, name: "back_wall")!;
    back.local.position = { 0, 3, -IMAGE_HALL_LENGTH * 0.5f };
    back.local.scale = { IMAGE_HALL_WIDTH, 6, 0.5f };
    for (uint row = 0; row < 8; row++) {
        for (uint column = 0; column < 5; column++) {
            Node* pillar = scene.add_mesh(fixture.box, material, name: "pillar")!;
            pillar.local.position = {
                ((float)column + 0.5f) / 5 * IMAGE_HALL_WIDTH - IMAGE_HALL_WIDTH * 0.5f,
                1.5f,
                ((float)row + 0.5f) / 8 * IMAGE_HALL_LENGTH - IMAGE_HALL_LENGTH * 0.5f,
            };
            pillar.local.scale = { 1.5f, 3, 1.5f };
        }
    }
    uint columns = (uint)math::sqrt((float)lights);
    for (uint index = 0; index < IMAGE_HALL_LIGHTS; index++) {
        Node* lamp = scene.add_light(light::point(IMAGE_HALL_COLORS[index % IMAGE_HALL_COLORS.len], 8, 6))!;
        lamp.visible = index < lights;
        if (!lamp.visible) continue;
        lamp.local.position = {
            ((float)(index % columns) + 0.5f) / columns * IMAGE_HALL_WIDTH - IMAGE_HALL_WIDTH * 0.5f,
            2.5f,
            ((float)(index / columns) + 0.5f) / columns * IMAGE_HALL_LENGTH - IMAGE_HALL_LENGTH * 0.5f,
        };
        scene.get(lamp, Light).range = range;
        assert(!scene.get(lamp, Light).shadow.enabled);
    }
    hall.camera = scene.add_camera(camera::perspective_deg(60, 0.1f), name: "camera")!;
    Vec3 offset = { math::cos(0.65f) * math::sin(0.2f), math::sin(0.65f), math::cos(0.65f) * math::cos(0.2f) };
    hall.camera.local.position = offset * 65;
    hall.camera.local.rotation = maths::look_rotation(-offset, { 0, 1, 0 });
    scene.ambient_intensity = 0.015f;
    scene.update_world();
    return hall;
}

fn void? capture_hall_images(LightImageRun run) @private {
    uint[2] light_counts = { 64, IMAGE_HALL_LIGHTS };
    uint[2] ranges = { 3, 32 };
    uint[2] capacities = { 1, 64 };
    foreach (shading : IMAGE_SHADING_PATHS) {
        foreach (lights : light_counts) {
            foreach (range : ranges) {
                foreach (capacity : capacities) {
                    for (uint pruning = 0; pruning < 2; pruning++) {
                        @pool() {
                            Fixture fixture;
                            create_fixture(mem, &fixture, max_lights: IMAGE_HALL_LIGHTS)!;
                            defer destroy_fixture(&fixture);
                            ImageHall hall = create_image_hall(&fixture, lights, range)!;
                            defer scene::destroy_scene(&hall.scene);
                            LightImageView[2] images;
                            for (uint output = 0; output < 2; output++) {
                                images[output] = create_light_image_view(
                                    fixture: &fixture,
                                    width: 320,
                                    height: 180,
                                    output: output ? OutputMode.DISPLAY_LDR : OutputMode.LINEAR_HDR,
                                    shading: shading,
                                )!;
                                ViewDesc desc = fixture.renderer.views.get(images[output].view).desc;
                                desc.lights = LightSelection.CLUSTERED;
                                desc.clusters.lights_per_cluster = capacity;
                                desc.clusters.depth_pruning = (bool)pruning;
                                render::configure_view(&fixture.renderer, images[output].view, desc)!;
                            }
                            String name = string::tformat("hall_%s_%s_%s_%s_%s", shading, lights, range, capacity, pruning);
                            save_light_image_inputs(
                                run: run,
                                fixture: &fixture,
                                scene: &hall.scene,
                                camera_node: hall.camera,
                                image: images[0],
                                name: name,
                                traced: false,
                            )!;
                            Renderer* renderer = &fixture.renderer;
                            renderer.prepare_scene(&hall.scene)!;
                            for (uint frame = 1; frame <= 8; frame++) {
                                renderer.begin_frame({ .time = 0, .delta = 1.0f / 60 })!;
                                defer catch render::abort_frame(renderer);
                                foreach (image : images) {
                                    renderer.render_view(&hall.scene, hall.camera, image.view)!;
                                    renderer.finish_view(image.view)!;
                                }
                                renderer.end_frame()!;
                                assert(renderer.frame_submitted && renderer.frame_index == frame);
                                assert(renderer.stats.shader_rejections == 0 && renderer.stats.lights_dropped == 0);
                            }
                            foreach (output, image : images) {
                                save_light_image(
                                    run: run,
                                    fixture: &fixture,
                                    image: image,
                                    name: string::tformat("%s_%s", name, output ? "ldr" : "hdr"),
                                )!;
                            }
                        };
                    }
                }
            }
        }
    }
}
