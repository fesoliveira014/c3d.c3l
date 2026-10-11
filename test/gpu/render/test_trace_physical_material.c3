module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::camera;
import c3d::light;
import c3d::material;
import c3d::render @public;
import c3d::scene;
import c3d::shader;
import gpu;
import std::math;
import std::math::vector;

const char[*] PHYSICAL_HIT_SOURCE @private = $embed("trace_physical_material.comp.glsl");
const uint PHYSICAL_HIT_ROWS @private = 16; // Mirrored by the shader's output stride; 256 readback bytes.
const double PHYSICAL_HIT_ABSOLUTE @private = 2e-5;
const double PHYSICAL_HIT_RELATIVE @private = 2e-4;
const double PHYSICAL_HIT_HDR_ABSOLUTE @private = 0.003;
const double PHYSICAL_HIT_HDR_RELATIVE @private = 0.005;
const Vec3 PHYSICAL_HIT_ORIGIN @private = { -0.5f, -0.5f, 0 };
const Vec3 PHYSICAL_HIT_DIRECTION @private = { 0, 0, -1 };

struct PhysicalHitRoot @private {
    gpu::GpuAddress scene;
    gpu::GpuAddress frame;
    gpu::GpuAddress output_address;
    ulong padding;
    Vec4 origin_cone;
    Vec4 direction;
}
$assert PhysicalHitRoot::size == 64;
$assert $reflect(PhysicalHitRoot.origin_cone).offset == 32;

fn GeometryId? add_physical_hit_triangle(Fixture* fixture, bool tangent = true) @private {
    Vec3[3] positions = { { -1, -1, 0 }, { 1, -1, 0 }, { -1, 1, 0 } };
    Vec3[3] normals = { { 0, 0, 1 }, { 0, 0, 1 }, { 0, 0, 1 } };
    Vec4[3] tangents = { { 1, 0, 0, 1 }, { 1, 0, 0, 1 }, { 1, 0, 0, 1 } };
    Vec2[3] uv0 = { { 0, 0 }, { 1, 0 }, { 0, 1 } };
    Vec2[3] uv1 = { { 0, 1 }, { 0, 0 }, { 1, 1 } };
    Geometry geometry = {
        .positions = positions[..],
        .normals = normals[..],
        .tangents = tangent ? tangents[..] : (Vec4[]) {},
        .uv0 = uv0[..],
        .uv1 = uv1[..],
    };
    geometry.finalize();
    return fixture.assets.add_geometry(&geometry);
}

fn TextureId? add_physical_hit_map(Fixture* fixture, Vec4 color) @private {
    Vec4[4] pixels = { color, color, color, color };
    material::TextureDesc desc = {
        .width = 2,
        .height = 2,
        .layers = 1,
        .format = RGBA32_FLOAT,
        .mip_levels = 1,
        .debug_name = "physical_hit_map",
    };
    return fixture.assets.add_texture(desc, ((char*)&pixels)[:pixels.len * Vec4::size]);
}

fn void assert_physical_hit_scalar(float actual, double expected, String name) @private {
    assert(math::is_finite(actual));
    assert(math::abs((double)actual - expected) <= PHYSICAL_HIT_ABSOLUTE + PHYSICAL_HIT_RELATIVE * math::abs(expected),
        "%s: actual=%s expected=%s", name, actual, expected);
}

fn void assert_physical_hit_vector(Vec4 actual, Vec3 expected, String name) @private {
    for (uint channel = 0; channel < 3; channel++) {
        assert_physical_hit_scalar(actual[channel], (double)expected[channel], name);
    }
}

fn Vec4[PHYSICAL_HIT_ROWS]? read_physical_hit(
    Fixture* fixture,
    Scene* scene,
    ComputeShaderId shader_id,
    FrameRoot frame,
    Vec3 origin = PHYSICAL_HIT_ORIGIN,
    Vec3 direction = PHYSICAL_HIT_DIRECTION,
    float cone = 0,
    LightGpu[] lights = {},
) @private {
    Renderer* renderer = &fixture.renderer;
    usz bytes = PHYSICAL_HIT_ROWS * Vec4::size;
    BufferId output = renderer.create_buffer({ .size = bytes, .debug_name = "physical_hit" })!;
    defer renderer.destroy_buffer(output)!!;
    gpu::AllocationDesc allocation_desc = {
        .size = bytes,
        .alignment = 16,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access = { .graphics },
        .debug_name = "physical_hit",
    };
    gpu::MappedGpuSpan readback = gpu::allocate_mapped_memory(&renderer.device, &allocation_desc)!;
    defer {
        gpu::GpuAllocation allocation = readback.span.allocation();
        gpu::free_allocation(&renderer.device, &allocation)!!;
    }

    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    frame.trace = renderer.prepare_scene_trace(
        scene, renderer.caps.ray_queries.enabled ? TraceKind.HARDWARE : TraceKind.SOFTWARE)!;
    if (lights.len) {
        frame.lights = upload_trace_segment(renderer, ((char*)lights.ptr)[:lights.len * LightGpu::size])!;
        frame.light_count = (uint)lights.len;
    }
    bool sheen = render::trace_uses_sheen(renderer);
    if (sheen) render::acquire_sheen_lut(renderer)!;
    if (scene.environment.generation) {
        EnvironmentRes* environment = render::resolve_environment(
            renderer: renderer,
            environment: scene.environment,
            lighting: true,
            sheen: sheen,
        )!;
        frame.environment = render::pack_lighting_environment(
            renderer: renderer,
            environment: environment,
            intensity: scene.environment_intensity,
            rotation: scene.environment_rotation,
            sheen: sheen,
        )!;
    }
    render::record_environment_preparations(renderer, &renderer.commands)!;
    frame.sheen_lut = renderer.environment_state.sheen_lut.view.index;
    frame.sheen_sampler = renderer.environment_state.sheen_sampler;
    PhysicalHitRoot root = {
        .scene = frame.trace,
        .frame = upload_trace_segment(renderer, ((char*)&frame)[:FrameRoot::size])!,
        .output_address = renderer.buffer_address(output),
        .origin_cone = { origin.x, origin.y, origin.z, cone },
        .direction = { direction.x, direction.y, direction.z, 0 },
    };
    BufferId[1] writes = { output };
    renderer.dispatch({
        .shader = shader_id,
        .root = ((char*)&root)[:PhysicalHitRoot::size],
        .groups = { 1, 1, 1 },
        .writes = writes[..],
    })!;
    gpu::Barrier transfer = { .before = { .all }, .after = { .transfer } };
    gpu::cmd_barrier(&renderer.commands, &transfer)!;
    gpu::BufferCopyDesc copy = {
        .src = gpu::get_allocation_span(&renderer.device, renderer.buffers.get(output).allocation)!,
        .dst = readback.span,
    };
    gpu::cmd_copy_buffer(&renderer.commands, &copy)!;
    gpu::Barrier host = { .before = { .transfer }, .after = { .host } };
    gpu::cmd_barrier(&renderer.commands, &host)!;
    renderer.end_frame()!;
    render::wait_frames(renderer)!;
    gpu::invalidate_mapped_span(&renderer.device, readback.span)!;
    return *(Vec4[PHYSICAL_HIT_ROWS]*)readback.bytes.ptr;
}

fn void test_trace_physical_mapped_channels_preserve_authored_factors_on_both_backends() @test {
    foreach (hardware : (bool[2]){ false, true }) {
        Fixture fixture;
        create_fixture(mem, &fixture, ray_queries: hardware)!!;
        defer destroy_fixture(&fixture);
        Scene scene = scene::create_scene(mem, scene::default_scene_desc());
        defer scene::destroy_scene(&scene);
        String[1] defines = { hardware ? "SCENE_TRACE_RAY_QUERY" : "SCENE_TRACE_BVH" };
        ComputeShaderId shader_id = add_compute_shader(&fixture, (String)PHYSICAL_HIT_SOURCE[..], defines[..])!!;
        GeometryId geometry_id = add_physical_hit_triangle(&fixture)!!;
        TextureId texture = add_physical_hit_map(&fixture, { 0.25f, 0.5f, 0.75f, 1 })!!;
        TextureSlot slot = material::texture_slot(texture);
        PhysicalParams params = material::PHYSICAL_PARAMS_DEFAULT;
        params.standard.base_color = { 0.8f, 0.6f, 0.4f, 1 };
        params.standard.metallic = 0.25f;
        params.standard.roughness = 0.5f;
        params.standard.base_color_map = slot;
        params.standard.metallic_roughness_map = slot;
        params.standard.occlusion_map = slot;
        params.standard.occlusion_strength = 0.5f;
        params.standard.emissive = { 0.25f, 0.5f, 1 };
        params.standard.emissive_map = slot;
        params.clearcoat = 0.5f;
        params.clearcoat_roughness = 0.5f;
        params.clearcoat_map = slot;
        params.clearcoat_roughness_map = slot;
        params.sheen_color = { 0.3f, 0.2f, 0.1f };
        params.sheen_roughness = 0.5f;
        params.sheen_color_map = slot;
        params.sheen_roughness_map = slot;
        params.specular = 0.5f;
        params.specular_color = { 0.25f, 0.5f, 1 };
        params.specular_map = slot;
        params.specular_color_map = slot;
        params.transmission = 0.25f;
        params.thickness = 2;
        params.transmission_map = slot;
        params.thickness_map = slot;
        params.anisotropy = 0.5f;
        params.anisotropy_map = slot;
        MaterialId material_id = fixture.assets.add_material(material::physical(params))!!;
        Node* owner = scene.add_mesh(geometry_id, material_id)!!;
        owner.local.position.z = -4;
        owner.local.scale = { 2, 1, 0.5f };
        scene.update_world();
        Vec4[PHYSICAL_HIT_ROWS] actual = read_physical_hit(
            fixture: &fixture,
            scene: &scene,
            shader_id: shader_id,
            frame: {},
        )!!;
        assert_physical_hit_vector(actual[1], { 0.2f, 0.3f, 0.3f }, "mapped base");
        assert_physical_hit_scalar(actual[1].w, 0.1875, "metallic blue");
        assert_physical_hit_scalar(actual[2].w, 0.25, "roughness green");
        assert_physical_hit_scalar(actual[3].w, 0.25, "coat roughness green");
        assert_physical_hit_vector(actual[4], { 0.075f, 0.1f, 0.075f }, "sheen RGB");
        assert_physical_hit_scalar(actual[4].w, 0.5, "sheen roughness alpha");
        assert_physical_hit_scalar(actual[5].w, 0.005, "coat red times view Fresnel");
        Vec3 expected_reflectance = { 0.038515625f, 0.0603125f, 0.0684375f };
        assert_physical_hit_vector(actual[5], expected_reflectance, "IOR specular F0");
        assert_physical_hit_vector(actual[6], { 0.59375f, 0.59375f, 0.59375f }, "specular F90");
        assert_physical_hit_scalar(actual[6].w, 0.1, "sheen strength");
        assert_physical_hit_vector(actual[7], { 0, 0, -0.5f }, "authored thickness and model scale");
        assert_physical_hit_scalar(actual[7].w, 0.0625, "transmission red");
        assert_physical_hit_scalar(actual[8].w, 0.625, "occlusion red and strength");
        assert_physical_hit_vector(actual[8], { 0.1625f, 0.24375f, 0.24375f }, "one nonmetal tint");
        assert_physical_hit_vector(actual[9], { -1, 0, 0 }, "anisotropy mapped RG direction");
        assert_physical_hit_scalar(actual[9].w, 0.375, "anisotropy blue");
        assert_physical_hit_vector(actual[13], { 0.0625f, 0.25f, 0.75f }, "emissive RGB");
        check_validation(&fixture.renderer);
    }
}

fn void test_trace_physical_coat_and_ior_weights_match_normal_incidence_identity() @test {
    foreach (hardware : (bool[2]){ false, true }) {
        Fixture fixture;
        create_fixture(mem, &fixture, ray_queries: hardware)!!;
        defer destroy_fixture(&fixture);
        Scene scene = scene::create_scene(mem, scene::default_scene_desc());
        defer scene::destroy_scene(&scene);
        String[1] defines = { hardware ? "SCENE_TRACE_RAY_QUERY" : "SCENE_TRACE_BVH" };
        ComputeShaderId shader_id = add_compute_shader(&fixture, (String)PHYSICAL_HIT_SOURCE[..], defines[..])!!;
        GeometryId geometry_id = add_physical_hit_triangle(&fixture)!!;
        PhysicalParams params = material::PHYSICAL_PARAMS_DEFAULT;
        params.standard.base_color = { 0.8f, 0.6f, 0.4f, 1 };
        params.standard.metallic = 0;
        params.standard.roughness = 0.5f;
        params.standard.emissive = { 0.25f, 0.5f, 1 };
        MaterialId material_id = fixture.assets.add_material(material::physical(params))!!;
        Node* owner = scene.add_mesh(geometry_id, material_id)!!;
        owner.local.position.z = -4;
        scene.update_world();
        foreach (coat : (float[3]){ 0, 0.5f, 1 }) {
            foreach (ior : (float[3]){ 1, 1.5f, 2 }) {
                params.clearcoat = coat;
                params.clearcoat_roughness = 0.5f;
                params.ior = ior;
                fixture.assets.replace_material(material_id, material::physical(params));
                Vec4[PHYSICAL_HIT_ROWS] actual = read_physical_hit(
                    fixture: &fixture,
                    scene: &scene,
                    shader_id: shader_id,
                    frame: { .ambient = { 0.1f, 0.2f, 0.4f, 0 } },
                )!!;
                double ratio = ((double)ior - 1) / ((double)ior + 1);
                double weight = (double)coat * 0.04;
                assert_physical_hit_scalar(actual[5].x, ratio * ratio, "normal-incidence IOR reflectance");
                assert_physical_hit_scalar(actual[5].w, weight, "coat Fresnel weight");
                for (uint channel = 0; channel < 3; channel++) {
                    double[3] ambient = { 0.1, 0.2, 0.4 };
                    double expected = (1 - weight) * ((double)params.standard.base_color[channel] * ambient[channel]
                        + (double)params.standard.emissive[channel]);
                    assert_physical_hit_scalar(actual[0][channel], expected, "ambient and emission layered once");
                }
            }
        }
        check_validation(&fixture.renderer);
    }
}

fn void test_trace_physical_extension_maps_use_selected_uv_set_and_ray_cone_mip() @test {
    foreach (hardware : (bool[2]){ false, true }) {
        Fixture fixture;
        create_fixture(mem, &fixture, ray_queries: hardware)!!;
        defer destroy_fixture(&fixture);
        Scene scene = scene::create_scene(mem, scene::default_scene_desc());
        defer scene::destroy_scene(&scene);
        String[1] defines = { hardware ? "SCENE_TRACE_RAY_QUERY" : "SCENE_TRACE_BVH" };
        ComputeShaderId shader_id = add_compute_shader(&fixture, (String)PHYSICAL_HIT_SOURCE[..], defines[..])!!;
        GeometryId geometry_id = add_physical_hit_triangle(&fixture)!!;
        Vec4[4] base = {
            { 0.25f, 0.5f, 0.75f, 1 }, { 1, 0.75f, 0.5f, 0.25f },
            { 0.5f, 0.25f, 1, 0.75f }, { 0.75f, 1, 0.25f, 0.5f },
        };
        Vec4 high = { 0.125f, 0.875f, 0.375f, 0.625f };
        material::TextureDesc desc = {
            .width = 2, .height = 2, .layers = 1, .format = RGBA32_FLOAT, .mip_levels = 2,
            .debug_name = "physical_hit_mips",
        };
        TextureMipData[2] levels = {
            { .mip = 0, .bytes = ((char*)&base)[:base.len * Vec4::size] },
            { .mip = 1, .bytes = ((char*)&high)[:Vec4::size] },
        };
        TextureId texture = fixture.assets.add_texture_mips(desc, levels[..])!!;
        SamplerId sampler = fixture.assets.add_sampler(material::sampler_desc(NEAREST, CLAMP_TO_EDGE))!!;
        PhysicalParams params = material::PHYSICAL_PARAMS_DEFAULT;
        params.standard.metallic = 0;
        params.clearcoat = 1;
        params.clearcoat_roughness = 1;
        MaterialId material_id = fixture.assets.add_material(material::physical(params))!!;
        Node* owner = scene.add_mesh(geometry_id, material_id)!!;
        owner.local.position.z = -4;
        scene.update_world();
        for (uint uv_set = 0; uv_set < 2; uv_set++) {
            TextureSlot slot = material::texture_slot(texture, sampler, uv_set);
            params.clearcoat_map = slot;
            params.clearcoat_roughness_map = slot;
            fixture.assets.replace_material(material_id, material::physical(params));
            foreach (cone : (float[2]){ 1, 2 }) {
                Vec4[PHYSICAL_HIT_ROWS] actual = read_physical_hit(
                    fixture: &fixture,
                    scene: &scene,
                    shader_id: shader_id,
                    frame: {},
                    cone: cone,
                )!!;
                Vec4 expected = cone == 2 ? high : base[uv_set == 0 ? 0 : 2];
                assert_physical_hit_scalar(actual[5].w, (double)expected.r * 0.04, "coat red at chosen UV/LOD");
                assert_physical_hit_scalar(actual[3].w, expected.g, "coat green at chosen UV/LOD");
                assert_physical_hit_scalar(actual[11].x, 0.25, "UV0 x");
                assert_physical_hit_scalar(actual[11].y, 0.25, "UV0 y");
                assert_physical_hit_scalar(actual[11].z, 0.25, "UV1 x");
                assert_physical_hit_scalar(actual[11].w, 0.75, "UV1 y");
            }
        }
        check_validation(&fixture.renderer);
    }
}

fn void test_trace_physical_base_and_coat_normals_preserve_tangents_mirrors_and_facing() @test {
    foreach (hardware : (bool[2]){ false, true }) {
        Fixture fixture;
        create_fixture(mem, &fixture, ray_queries: hardware)!!;
        defer destroy_fixture(&fixture);
        Scene scene = scene::create_scene(mem, scene::default_scene_desc());
        defer scene::destroy_scene(&scene);
        String[1] defines = { hardware ? "SCENE_TRACE_RAY_QUERY" : "SCENE_TRACE_BVH" };
        ComputeShaderId shader_id = add_compute_shader(&fixture, (String)PHYSICAL_HIT_SOURCE[..], defines[..])!!;
        TextureId base_normal = add_physical_hit_map(&fixture, { 1, 0.5f, 0.5f, 1 })!!;
        TextureId coat_normal = add_physical_hit_map(&fixture, { 0.5f, 1, 0.5f, 1 })!!;
        PhysicalParams params = material::PHYSICAL_PARAMS_DEFAULT;
        params.standard.normal_map = material::texture_slot(base_normal);
        params.clearcoat = 0.5f;
        params.clearcoat_normal_map = material::texture_slot(coat_normal);
        MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
        common.double_sided = true;
        MaterialId material_id = fixture.assets.add_material(material::physical(params, common))!!;
        foreach (tangent : (bool[2]){ false, true }) {
            GeometryId geometry_id = add_physical_hit_triangle(&fixture, tangent)!!;
            Node* owner = scene.add_mesh(geometry_id, material_id)!!;
            owner.local.position.z = -4;
            foreach (mirror : (float[2]){ 1, -1 }) {
                owner.local.scale.x = mirror;
                scene.update_world();
                foreach (back : (bool[2]){ false, true }) {
                    Vec3 origin = { -0.5f * mirror, -0.5f, back ? -8 : 0 };
                    Vec3 direction = { 0, 0, back ? 1 : -1 };
                    Vec4[PHYSICAL_HIT_ROWS] actual = read_physical_hit(
                        fixture: &fixture,
                        scene: &scene,
                        shader_id: shader_id,
                        frame: {},
                        origin: origin,
                        direction: direction,
                    )!!;
                    float facing = back ? -1 : 1;
                    assert_physical_hit_vector(actual[2], { mirror * facing, 0, 0 }, "base tangent normal");
                    assert_physical_hit_vector(actual[3], { 0, facing, 0 }, "coat tangent normal");
                }
            }
            scene.remove(owner);
        }
        check_validation(&fixture.renderer);
    }
}

fn void test_trace_physical_environment_transmission_matches_independent_absorption_and_raster_fallback() @test {
    foreach (hardware : (bool[2]){ false, true }) {
        Fixture fixture;
        create_fixture(mem, &fixture, ray_queries: hardware)!!;
        defer destroy_fixture(&fixture);
        Scene scene = scene::create_scene(mem, scene::default_scene_desc());
        defer scene::destroy_scene(&scene);
        scene.ambient_intensity = 0;
        scene.environment = reflection_solid(&fixture, { 0.25f, 0.5f, 1 })!!;
        String[1] defines = { hardware ? "SCENE_TRACE_RAY_QUERY" : "SCENE_TRACE_BVH" };
        ComputeShaderId shader_id = add_compute_shader(&fixture, (String)PHYSICAL_HIT_SOURCE[..], defines[..])!!;
        GeometryId geometry_id = add_physical_hit_triangle(&fixture)!!;
        TextureId normal_texture = add_physical_hit_map(&fixture, { 0.8535534f, 0.5f, 0.8535534f, 1 })!!;
        PhysicalParams params = material::PHYSICAL_PARAMS_DEFAULT;
        params.standard.base_color = { 0.8f, 0.6f, 0.4f, 1 };
        params.standard.metallic = 0;
        params.standard.roughness = 0.5f;
        params.standard.normal_map = material::texture_slot(normal_texture);
        params.specular = 0;
        params.transmission = 1;
        params.thickness = 1;
        params.attenuation_color = { 0.5f, 0.25f, 0.125f };
        params.attenuation_distance = 2;
        MaterialId material_id = fixture.assets.add_material(material::physical(params))!!;
        Node* owner = scene.add_mesh(geometry_id, material_id)!!;
        owner.local.position.z = -4;
        Node* camera_node = scene.add_camera(camera::orthographic(0.02f, 0.1f, 20))!!;
        camera_node.local.position = PHYSICAL_HIT_ORIGIN;
        foreach (scale : (Vec3[3]){ { 1, 1, 1 }, { 2, 2, 2 }, { 2, 1, 0.5f } }) {
            owner.local.scale = scale;
            scene.update_world();
            Vec4[PHYSICAL_HIT_ROWS] actual = read_physical_hit(
                fixture: &fixture,
                scene: &scene,
                shader_id: shader_id,
                frame: {},
            )!!;
            double eta = 2.0 / 3.0;
            double normal = 1.0 / math::sqrt(2.0);
            double factor = math::sqrt(1 - eta * eta * 0.5) - eta * normal;
            double ray_x = -factor * normal * (double)scale.x;
            double ray_z = (-eta - factor * normal) * (double)scale.z;
            double distance = math::sqrt(ray_x * ray_x + ray_z * ray_z);
            double[3] surroundings = { 0.25, 0.5, 1 };
            for (uint channel = 0; channel < 3; channel++) {
                double expected = surroundings[channel] * (double)params.standard.base_color[channel]
                    * math::exp(math::ln((double)params.attenuation_color[channel]) * distance / 2);
                assert_physical_hit_scalar(actual[12][channel], expected, "environment absorption and tint once");
                assert_physical_hit_scalar(actual[0][channel], expected, "outgoing pure transmission");
            }
            assert_physical_hit_scalar(actual[12].w, distance, "component-scaled volume distance");
            foreach (path : (ShadingPath[2]){ FORWARD, DEFERRED }) {
                ReflectionShot shot = reflection_shot(
                    fixture: &fixture,
                    scene: &scene,
                    camera_node: camera_node,
                    shading: path,
                    size: { 128, 128 },
                )!!;
                defer reflection_destroy_shot(&fixture, &shot);
                Vec4[] pixels = reflection_render(&fixture, &shot)!!;
                defer free(pixels);
                Vec4 pixel = pixels[64 * 128 + 64];
                for (uint channel = 0; channel < 3; channel++) {
                    double error = math::abs((double)pixel[channel] - (double)actual[0][channel]);
                    double tolerance = PHYSICAL_HIT_HDR_ABSOLUTE
                      + PHYSICAL_HIT_HDR_RELATIVE * math::abs((double)actual[0][channel]);
                    assert(math::is_finite(pixel[channel]) && error <= tolerance,
                        "Raster fallback differs: backend=%s path=%s scale=%s channel=%s hit=%s raster=%s",
                        hardware, path, scale, channel, actual[0][channel], pixel[channel]);
                }
            }
        }
        check_validation(&fixture.renderer);
    }
}

fn void test_trace_physical_punctual_transmission_sees_back_lights_with_one_absorption_factor() @test {
    foreach (hardware : (bool[2]){ false, true }) {
        Fixture fixture;
        create_fixture(mem, &fixture, ray_queries: hardware)!!;
        defer destroy_fixture(&fixture);
        Scene scene = scene::create_scene(mem, scene::default_scene_desc());
        defer scene::destroy_scene(&scene);
        String[1] defines = { hardware ? "SCENE_TRACE_RAY_QUERY" : "SCENE_TRACE_BVH" };
        ComputeShaderId shader_id = add_compute_shader(&fixture, (String)PHYSICAL_HIT_SOURCE[..], defines[..])!!;
        GeometryId geometry_id = add_physical_hit_triangle(&fixture)!!;
        PhysicalParams params = material::PHYSICAL_PARAMS_DEFAULT;
        params.standard.base_color = { 0.8f, 0.6f, 0.4f, 1 };
        params.standard.metallic = 0;
        params.standard.roughness = 0.5f;
        params.specular = 0;
        params.transmission = 1;
        params.thickness = 1;
        params.attenuation_color = { 0.5f, 0.25f, 0.125f };
        params.attenuation_distance = 2;
        MaterialId material_id = fixture.assets.add_material(material::physical(params))!!;
        Node* owner = scene.add_mesh(geometry_id, material_id)!!;
        owner.local.position.z = -4;
        LightGpu[1] lights = {
            { .direction_cos_outer = { 0, 0, 1, 0 }, .color_intensity = { 1, 1, 1, 1 }, .layers = 1 },
        };
        for (uint row = 0; row < 9; row++) {
            params.transmission = row == 1 ? 0 : row == 2 ? 0.25f : 1;
            params.thickness = row == 3 ? 0 : row == 4 ? 2 : 1;
            params.ior = row == 5 ? 1.33f : row == 6 ? 2 : 1.5f;
            owner.local.scale = row == 7 ? (Vec3){ 2, 2, 2 } : row == 8 ? (Vec3){ 2, 1, 0.5f } : (Vec3){ 1, 1, 1 };
            fixture.assets.replace_material(material_id, material::physical(params));
            scene.update_world();
            Vec4[PHYSICAL_HIT_ROWS] actual = read_physical_hit(
                fixture: &fixture,
                scene: &scene,
                shader_id: shader_id,
                frame: {},
                lights: lights[..],
            )!!;
            double alpha = 0.25 * math::min(1.0, 2.0 * (double)params.ior - 2.0);
            double response = 1.0 / (4.0 * math::PI * alpha * alpha);
            double distance = (double)params.thickness * owner.local.scale.z;
            for (uint channel = 0; channel < 3; channel++) {
                double expected = (double)params.transmission * (double)params.standard.base_color[channel] * response
                    * math::exp(math::ln((double)params.attenuation_color[channel]) * distance / 2.0);
                assert_physical_hit_scalar(actual[0][channel], expected, "normal-incidence punctual transmission");
            }
        }
        check_validation(&fixture.renderer);
    }
}

fn void test_trace_physical_coat_sheen_specular_and_anisotropy_environment_match_raster_at_view_angles() @test {
    foreach (hardware : (bool[2]){ false, true }) {
        Fixture fixture;
        create_fixture(mem, &fixture, ray_queries: hardware)!!;
        defer destroy_fixture(&fixture);
        Scene scene = scene::create_scene(mem, scene::default_scene_desc());
        defer scene::destroy_scene(&scene);
        scene.ambient_color = { 0.1f, 0.2f, 0.4f };
        scene.ambient_intensity = 1;
        scene.ambient_add = true;
        scene.environment = reflection_solid(&fixture, { 0.25f, 0.5f, 1 })!!;
        String[1] defines = { hardware ? "SCENE_TRACE_RAY_QUERY" : "SCENE_TRACE_BVH" };
        ComputeShaderId shader_id = add_compute_shader(&fixture, (String)PHYSICAL_HIT_SOURCE[..], defines[..])!!;
        GeometryId geometry_id = add_physical_hit_triangle(&fixture)!!;
        MaterialId material_id = fixture.assets.add_material(material::physical())!!;
        Node* owner = scene.add_mesh(geometry_id, material_id)!!;
        owner.local.position.z = -4;
        Node* camera_node = scene.add_camera(camera::orthographic(0.02f, 0.1f, 20))!!;
        Vec3 point = { -0.5f, -0.5f, -4 };
        Vec4 neutral;
        uint changed;
        for (uint row = 0; row < 9; row++) {
            PhysicalParams params = material::PHYSICAL_PARAMS_DEFAULT;
            params.standard.base_color = { 0.8f, 0.6f, 0.4f, 1 };
            params.standard.metallic = 0.25f;
            params.standard.roughness = 0.5f;
            params.standard.emissive = { 0.25f, 0.5f, 1 };
            params.clearcoat = row == 1 || row == 3 || row >= 6 ? 0.5f : 0;
            params.clearcoat_roughness = 0.25f;
            params.sheen_color = row == 2 || row == 3 || row >= 6 ? (Vec3){ 0.3f, 0.2f, 0.1f } : (Vec3){};
            params.sheen_roughness = 0.5f;
            params.specular = row == 4 || row >= 6 ? 0.5f : 1;
            params.specular_color = row == 4 || row >= 6 ? (Vec3){ 0.25f, 0.5f, 1 } : (Vec3){ 1, 1, 1 };
            params.ior = row == 4 || row >= 6 ? 1.33f : 1.5f;
            params.anisotropy = row == 5 || row >= 6 ? 0.5f : 0;
            params.anisotropy_rotation = (float)math::PI / 4;
            fixture.assets.replace_material(material_id, material::physical(params));
            float degrees = row == 6 ? 30 : row == 7 ? 60 : row == 8 ? 80 : 0;
            float angle = math::deg_to_rad(degrees);
            Vec3 direction = { -math::sin(angle), 0, -math::cos(angle) };
            Vec3 origin = point - direction * 4;
            camera_node.local.position = origin;
            camera_node.local.rotation = maths::look_rotation(direction, { 0, 1, 0 });
            scene.update_world();
            Vec4[PHYSICAL_HIT_ROWS] actual = read_physical_hit(
                fixture: &fixture,
                scene: &scene,
                shader_id: shader_id,
                frame: { .ambient = { 0.1f, 0.2f, 0.4f, 0 } },
                origin: origin,
                direction: direction,
            )!!;
            if (row == 0) {
                neutral = actual[0];
            } else if (row <= 4 && actual[0] != neutral) {
                changed++;
            }
            foreach (path : (ShadingPath[2]){ FORWARD, DEFERRED }) {
                ReflectionShot shot = reflection_shot(
                    fixture: &fixture,
                    scene: &scene,
                    camera_node: camera_node,
                    shading: path,
                    size: { 128, 128 },
                )!!;
                defer reflection_destroy_shot(&fixture, &shot);
                Vec4[] pixels = reflection_render(&fixture, &shot)!!;
                defer free(pixels);
                Vec4 pixel = pixels[64 * 128 + 64];
                for (uint channel = 0; channel < 3; channel++) {
                    double error = math::abs((double)pixel[channel] - (double)actual[0][channel]);
                    double tolerance = PHYSICAL_HIT_HDR_ABSOLUTE
                      + PHYSICAL_HIT_HDR_RELATIVE * math::abs((double)actual[0][channel]);
                    assert(math::is_finite(pixel[channel]) && error <= tolerance,
                        "Physical lobe mismatch: backend=%s path=%s row=%s channel=%s hit=%s raster=%s",
                        hardware, path, row, channel, actual[0][channel], pixel[channel]);
                }
            }
        }
        assert(changed == 4, "Coat, sheen, their pair and the IOR/specular control must change outgoing radiance");
        check_validation(&fixture.renderer);
    }
}
