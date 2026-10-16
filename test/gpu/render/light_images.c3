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
import c3d::shader;
import gpu;
import std::io;
import std::io::file;
import std::math;
import std::core::string;

const ShadingPath[2] IMAGE_SHADING_PATHS @private = { ShadingPath.FORWARD, ShadingPath.DEFERRED };
const LightSelection[2] IMAGE_LIGHT_SELECTIONS @private = { LightSelection.FLAT, LightSelection.CLUSTERED };
const uint IMAGE_IRRELEVANT_LIGHTS @private = 32;

bool image_adapter_printed @private;

struct LightImageRun @private {
    String directory;
    uint repetition;
}

struct LightImageView @private {
    RenderTargetId target;
    ViewId view;
}

fn LightImageView? create_light_image_view(
    Fixture* fixture,
    uint width,
    uint height,
    OutputMode output,
    ShadingPath shading,
    LightSelection lights = LightSelection.FLAT,
) @private {
    if (!image_adapter_printed) {
        print_adapter(fixture);
        image_adapter_printed = true;
    }
    RenderTargetId target = render::create_render_target(
        renderer: &fixture.renderer,
        desc: render::render_target_desc(width, height,
            output == OutputMode.LINEAR_HDR ? PixelFormat.RGBA32_FLOAT : PixelFormat.RGBA8_UNORM),
    )!;
    ViewDesc desc = render::texture_view_desc(target, output);
    desc.shading = shading;
    desc.lights = lights;
    desc.post.anti_aliasing = AntiAliasing.NONE;
    return { .target = target, .view = render::create_view(&fixture.renderer, desc)! };
}

fn void? add_irrelevant_image_lights(Scene* scene) @private {
    for (uint index = 0; index < IMAGE_IRRELEVANT_LIGHTS; index++) {
        Node* lamp = scene.add_light(light::point({ 1, 1, 1 }, 1, 1))!;
        lamp.local.position = { 100 + (float)index, 100, 100 };
    }
    scene.update_world();
}

fn void? save_light_image(
    LightImageRun run,
    Fixture* fixture,
    LightImageView image,
    String name,
) @private {
    Renderer* renderer = &fixture.renderer;
    TargetRecord* target = renderer.targets.get(image.target);
    uint width = target.target.width;
    uint height = target.target.height;
    bool floating = target.format == PixelFormat.RGBA32_FLOAT;
    usz bytes = (usz)width * height * (floating ? Vec4::size : uint::size);
    char[] pixels = mem::new_array(char, (sz)bytes);
    defer free(pixels);
    ulong frame = renderer.frame_index;
    renderer.read_render_target(image.target, pixels)!;
    assert(renderer.frame_index == frame);
    if (floating) assert_finite(((Vec4*)pixels.ptr)[:(usz)width * height]);
    @pool() {
        String filename = string::tformat("%s_%s_%s.bin", name, run.repetition, frame);
        file::save(string::tformat("%s/%s", run.directory, filename), pixels)!;
        ViewStats stats = renderer.view_stats(image.view)!;
        io::printfn("image,%s,%s,%s,%s,%s,%s,%s,%s,%s", filename, name,
            floating ? "rgba32f" : "rgba8", width, height, frame,
            stats.accumulated_samples, stats.lights, renderer.stats.probe_rays);
    };
    check_validation(renderer);
}

fn void? save_light_image_inputs(
    LightImageRun run,
    Fixture* fixture,
    Scene* scene,
    Node* camera_node,
    LightImageView image,
    String name,
    bool traced,
    bool probes = false,
) @private {
    @pool() {
        Camera* camera = scene.get(camera_node, Camera);
        Target* target = &fixture.renderer.targets.get(image.target).target;
        scene.update_world();
        CameraMatrices matrices = camera::derive_matrices(*camera, camera_node.world, {
            (float)target.width, (float)target.height,
        });
        LightCounts counts;
        LightExtraction extraction = render::extract_lights(
            allocator: tmem,
            scene: scene,
            frustum: traced ? null : &matrices.frustum,
            view_layers: probes ? uint::max : camera.layers,
            capacity: fixture.renderer.max_lights,
            counts: &counts,
            atmosphere: null,
            altitude: matrices.position.y,
            trace_shadows: traced,
        );
        String filename = string::tformat("%s_%s_inputs.bin", name, run.repetition);
        if (extraction.lights.len) {
            file::save(string::tformat("%s/%s", run.directory, filename),
                ((char*)extraction.lights.ptr)[:extraction.lights.len * LightGpu::size])!;
        }
        io::printfn("input,%s,%s,%s,%s,%s", filename, counts.packed, counts.culled, counts.dropped, traced);
    };
}

fn void? render_light_image_frame(
    Fixture* fixture,
    Scene* scene,
    Node* camera_node,
    ViewId view,
) @private {
    Renderer* renderer = &fixture.renderer;
    renderer.begin_frame({ .time = 0, .delta = 1.0f / 60 })!;
    defer catch render::abort_frame(renderer);
    renderer.render_view(scene, camera_node, view)!;
    renderer.finish_view(view)!;
    renderer.end_frame()!;
    assert(renderer.frame_submitted);
    assert(renderer.stats.shader_rejections == 0);
}

fn MaterialId? light_image_material(Fixture* fixture, TwinScene* twin, uint kind) @private {
    switch (kind) {
        case 0: return twin.sphere_standard;
        case 1:
            ToonParams toon = material::TOON_PARAMS_DEFAULT;
            toon.color = TWIN_SPHERE_PARAMS.base_color;
            return fixture.assets.add_material(material::toon(toon));
        case 2:
            PhysicalParams physical = material::PHYSICAL_PARAMS_DEFAULT;
            physical.standard.base_color = TWIN_SPHERE_PARAMS.base_color;
            return fixture.assets.add_material(material::physical(physical));
        case 3:
            StandardParams blended = material::STANDARD_PARAMS_DEFAULT;
            blended.base_color = TWIN_SPHERE_PARAMS.base_color;
            blended.base_color.w = 0.5f;
            MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
            common.alpha_mode = AlphaMode.BLEND;
            return fixture.assets.add_material(material::standard(blended, common));
        case 4:
            PhysicalParams glass = material::PHYSICAL_PARAMS_DEFAULT;
            glass.standard.base_color = TWIN_SPHERE_PARAMS.base_color;
            glass.standard.roughness = 0.25f;
            glass.transmission = 1;
            return fixture.assets.add_material(material::physical(glass));
        case 5: return twin.sphere_twin;
        default: unreachable();
    }
}

fn void? capture_material_images(LightImageRun run, LightSelection lights) @private {
    foreach (shading : IMAGE_SHADING_PATHS) {
        for (uint kind = 0; kind < 6; kind++) {
            for (uint mixed = 0; mixed < 2; mixed++) {
                @pool() {
                    Fixture fixture;
                    create_fixture(mem, &fixture)!;
                    defer destroy_fixture(&fixture);
                    TwinScene twin = create_twin_scene(&fixture)!;
                    defer scene::destroy_scene(&twin.scene);
                    twin.scene.get(twin.sphere, Mesh).material = light_image_material(&fixture, &twin, kind)!;
                    if (mixed) add_irrelevant_image_lights(&twin.scene)!;
                    LightImageView image = create_light_image_view(
                        fixture: &fixture,
                        width: 64,
                        height: 64,
                        output: OutputMode.LINEAR_HDR,
                        shading: shading,
                        lights: lights,
                    )!;
                    String name = string::tformat("material_%s_%s_%s_%s", shading, lights, kind, mixed);
                    save_light_image_inputs(
                        run: run,
                        fixture: &fixture,
                        scene: &twin.scene,
                        camera_node: twin.camera,
                        image: image,
                        name: name,
                        traced: false,
                    )!;
                    save_light_image_inputs(
                        run: run,
                        fixture: &fixture,
                        scene: &twin.scene,
                        camera_node: twin.camera,
                        image: image,
                        name: string::tformat("%s_traced_input_inspection", name),
                        traced: true,
                    )!;
                    fixture.renderer.prepare_scene(&twin.scene)!;
                    for (uint frame = 0; frame < 8; frame++) {
                        render_light_image_frame(
                            fixture: &fixture,
                            scene: &twin.scene,
                            camera_node: twin.camera,
                            view: image.view,
                        )!;
                    }
                    assert(fixture.renderer.frame_index == 8);
                    save_light_image(
                        run: run,
                        fixture: &fixture,
                        image: image,
                        name: name,
                    )!;
                };
            }
        }
    }
}

fn MaterialId? reflection_image_material(Fixture* fixture, uint kind) @private {
    StandardParams plain = { .base_color = { 1, 1, 1, 1 }, .metallic = 0, .roughness = 1 };
    if (kind == 0) return fixture.assets.add_material(material::standard(plain));
    if (kind == 1) {
        ToonParams toon = material::TOON_PARAMS_DEFAULT;
        toon.color = { 1, 1, 1, 1 };
        toon.steps = HIT_LAMP_TOON_STEPS;
        return fixture.assets.add_material(material::toon(toon));
    }
    if (kind == 2) return twin_material(fixture, add_twin_shader(fixture, false)!, plain);
    PhysicalParams physical = material::PHYSICAL_PARAMS_DEFAULT;
    physical.standard.base_color = plain.base_color;
    physical.standard.metallic = plain.metallic;
    physical.standard.roughness = plain.roughness;
    switch (kind) {
        case 3: break;
        case 4:
            physical.clearcoat = 1;
            physical.clearcoat_roughness = COAT_ROUGHNESS;
        case 5:
            physical.ior = HIGH_INDEX;
            physical.specular_color = TINTED_SPECULAR;
        case 6:
            physical.transmission = 1;
            physical.thickness = GLASS_THICKNESS;
        default: unreachable();
    }
    return fixture.assets.add_material(material::physical(physical));
}

fn void? capture_reflection_images(LightImageRun run) @private {
    foreach (ray_queries : TRACE_KINDS) {
        foreach (shading : IMAGE_SHADING_PATHS) {
            for (uint kind = 0; kind < 7; kind++) {
                for (uint mixed = 0; mixed < 2; mixed++) {
                    for (uint lamp_mode = 0; lamp_mode < (kind < 3 ? 3u : 1u); lamp_mode++) {
                        @pool() {
                            Fixture fixture;
                            create_fixture(mem, &fixture, ray_queries: ray_queries)!;
                            defer destroy_fixture(&fixture);
                            MirrorScene mirror = create_mirror_scene(&fixture, false)!;
                            defer scene::destroy_scene(&mirror.scene);
                            mirror.scene.get(mirror.emitter, Mesh).material = reflection_image_material(&fixture, kind)!;
                            if (kind < 3) {
                                Camera* camera = mirror.scene.get(mirror.camera, Camera);
                                CameraMatrices matrices = camera::derive_matrices(*camera, mirror.camera.world, {
                                    AO_TARGET_WIDTH, AO_TARGET_HEIGHT,
                                });
                                assert(!maths::frustum_intersects_sphere(&matrices.frustum, {
                                    .center = LAMP_POSITION, .radius = LAMP_RANGE,
                                }));
                            }
                            if (kind >= 3 || lamp_mode != 0) {
                                Node* lamp = mirror.scene.add_light(light::point({ 1, 0, 0 },
                                    kind < 3 ? LAMP_INTENSITY : COAT_LAMP_INTENSITY,
                                    kind < 3 ? LAMP_RANGE : COAT_LAMP_RANGE))!;
                                lamp.local.position = kind < 3 ? LAMP_POSITION : COAT_LAMP_POSITION;
                                if (kind < 3 && lamp_mode == 1) mirror.scene.get(lamp, Light).layers = EXCLUDED_RECEIVER_LAYERS;
                            }
                            if (mixed) add_irrelevant_image_lights(&mirror.scene)!;
                            mirror.scene.update_world();
                            LightImageView image = create_light_image_view(
                                fixture: &fixture,
                                width: AO_TARGET_WIDTH,
                                height: AO_TARGET_HEIGHT,
                                output: OutputMode.DISPLAY_LDR,
                                shading: shading,
                            )!;
                            ViewDesc desc = fixture.renderer.views.get(image.view).desc;
                            desc.post.anti_aliasing = AntiAliasing.FXAA;
                            desc.ray_tracing.reflections = true;
                            desc.ray_tracing.reflection_rays = 4;
                            desc.ray_tracing.reflection_resolution = ReflectionResolution.FULL;
                            desc.ray_tracing.reflection_history = true;
                            render::configure_view(&fixture.renderer, image.view, desc)!;
                            String name = string::tformat("reflection_%s_%s_%s_%s_%s",
                                ray_queries, shading, kind, mixed, lamp_mode);
                            save_light_image_inputs(
                                run: run,
                                fixture: &fixture,
                                scene: &mirror.scene,
                                camera_node: mirror.camera,
                                image: image,
                                name: name,
                                traced: true,
                            )!;
                            fixture.renderer.prepare_scene(&mirror.scene)!;
                            for (uint frame = 1; frame <= 32; frame++) {
                                render_light_image_frame(
                                    fixture: &fixture,
                                    scene: &mirror.scene,
                                    camera_node: mirror.camera,
                                    view: image.view,
                                )!;
                                assert(fixture.renderer.frame_index == frame);
                                if (frame == 1 || frame == 8 || frame == 32) {
                                    save_light_image(
                                        run: run,
                                        fixture: &fixture,
                                        image: image,
                                        name: name,
                                    )!;
                                }
                            }
                        };
                    }
                }
            }
        }
    }
}


fn void? capture_path_images(LightImageRun run) @private {
    for (uint off_camera = 0; off_camera < 2; off_camera++) {
        @pool() {
            Fixture fixture;
            create_fixture(mem, &fixture, ray_tracing_pipelines: true)!;
            defer destroy_fixture(&fixture);
            PathScene room;
            MirrorScene mirror;
            Scene* scene;
            Node* camera_node;
            if (off_camera) {
                mirror = create_mirror_scene(&fixture, false)!;
                scene = &mirror.scene;
                camera_node = mirror.camera;
                StandardParams plain = { .base_color = { 1, 1, 1, 1 }, .metallic = 0, .roughness = 1 };
                scene.get(mirror.emitter, Mesh).material = fixture.assets.add_material(material::standard(plain))!;
                Camera* camera = scene.get(camera_node, Camera);
                CameraMatrices matrices = camera::derive_matrices(*camera, camera_node.world, { 32, 32 });
                assert(!maths::frustum_intersects_sphere(&matrices.frustum, {
                    .center = LAMP_POSITION, .radius = LAMP_RANGE,
                }));
                Node* lamp = scene.add_light(light::point({ 1, 0, 0 }, LAMP_INTENSITY, LAMP_RANGE))!;
                lamp.local.position = LAMP_POSITION;
            } else {
                room = create_lit_room(&fixture)!;
                scene = &room.scene;
                camera_node = room.camera;
            }
            defer scene::destroy_scene(scene);
            scene.update_world();
            LightImageView image = create_light_image_view(
                fixture: &fixture,
                width: 32,
                height: 32,
                output: OutputMode.LINEAR_HDR,
                shading: ShadingPath.PATH_TRACED,
            )!;
            ViewDesc desc = fixture.renderer.views.get(image.view).desc;
            desc.path_trace = { .max_bounces = 4, .samples_per_frame = 1, .max_samples = 64 };
            render::configure_view(&fixture.renderer, image.view, desc)!;
            String name = string::tformat("path_%s", off_camera);
            save_light_image_inputs(
                run: run,
                fixture: &fixture,
                scene: scene,
                camera_node: camera_node,
                image: image,
                name: name,
                traced: true,
            )!;
            fixture.renderer.prepare_scene(scene)!;
            for (uint frame = 1; frame <= 64; frame++) {
                render_light_image_frame(
                    fixture: &fixture,
                    scene: scene,
                    camera_node: camera_node,
                    view: image.view,
                )!;
                assert(fixture.renderer.frame_index == frame);
                assert(fixture.renderer.view_stats(image.view)!.accumulated_samples == frame);
                if (frame == 1 || frame == 16 || frame == 64) {
                    save_light_image(
                        run: run,
                        fixture: &fixture,
                        image: image,
                        name: name,
                    )!;
                }
            }
        };
    }
}

fn void? capture_fog_images(LightImageRun run, LightSelection lights) @private {
    foreach (shading : IMAGE_SHADING_PATHS) {
        for (uint outside = 0; outside < 2; outside++) {
            @pool() {
                Fixture fixture;
                create_fixture(mem, &fixture)!;
                defer destroy_fixture(&fixture);
                FogScene target = create_fog_scene(&fixture)!;
                defer scene::destroy_scene(&target.scene);
                add_facing_plane(&target, add_unlit(&fixture, BED_COLOR)!, VOLUME_END + (outside ? 1 : -1))!;
                add_fog(&target, volume_fog())!;
                float elevation = VOLUME_SUN_DEGREES * DEGREE;
                add_plain_sun(&target, { 0, math::sin(elevation), -math::cos(elevation) }, false)!;
                Vec3[3] positions = { { 0, 1, -2 }, { 1, 1, -4 }, { -1, 1, -6 } };
                Vec3[3] colors = { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } };
                foreach (index, position : positions) {
                    Node* lamp = target.scene.add_light(light::point(colors[index], 2, 3))!;
                    lamp.local.position = position;
                }
                target.scene.update_world();
                LightImageView image = create_light_image_view(
                    fixture: &fixture,
                    width: SKY_TARGET_SIZE,
                    height: SKY_TARGET_SIZE,
                    output: OutputMode.LINEAR_HDR,
                    shading: shading,
                    lights: lights,
                )!;
                ViewDesc desc = fixture.renderer.views.get(image.view).desc;
                desc.volumetric_fog = true;
                desc.fog_temporal = true;
                desc.post.anti_aliasing = AntiAliasing.TAA;
                render::configure_view(&fixture.renderer, image.view, desc)!;
                String name = string::tformat("fog_%s_%s_%s", shading, lights, outside);
                save_light_image_inputs(
                    run: run,
                    fixture: &fixture,
                    scene: &target.scene,
                    camera_node: target.camera,
                    image: image,
                    name: name,
                    traced: false,
                )!;
                fixture.renderer.prepare_scene(&target.scene)!;
                for (uint frame = 1; frame <= 32; frame++) {
                    render_light_image_frame(
                        fixture: &fixture,
                        scene: &target.scene,
                        camera_node: target.camera,
                        view: image.view,
                    )!;
                    assert(fixture.renderer.frame_index == frame);
                    if (frame == 1 || frame == 8 || frame == 32) {
                        save_light_image(
                            run: run,
                            fixture: &fixture,
                            image: image,
                            name: name,
                        )!;
                    }
                }
            };
        }
    }
}

fn int main(String[] args) {
    if (args.len != 4) {
        io::eprintn("usage: light_images OUTPUT_DIRECTORY FIXTURE REPETITION");
        return 2;
    }
    LightImageRun run = { .directory = args[1], .repetition = args[3].to_uint()!! };
    @pool() {
        switch (args[2]) {
            case "material":
                foreach (lights : IMAGE_LIGHT_SELECTIONS) capture_material_images(run, lights)!!;
            case "reflection": capture_reflection_images(run)!!;
            case "path": capture_path_images(run)!!;
            case "fog":
                foreach (lights : IMAGE_LIGHT_SELECTIONS) capture_fog_images(run, lights)!!;
            case "probe": capture_probe_images(run)!!;
            case "hall": capture_hall_images(run)!!;
            case "water":
                foreach (lights : IMAGE_LIGHT_SELECTIONS) capture_water_images(run, lights)!!;
            default: return 2;
        }
    };
    return 0;
}
