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
import std::math;

const uint DECAL_TARGET_SIZE @private = 64;
const float DECAL_VIEW_HEIGHT @private = 4;
const float DECAL_PIXEL_TOLERANCE @private = 0.02f; // includes the deferred path's material quantization
const uint DECAL_STATS_FRAMES @private = render::FRAMES_IN_FLIGHT + 1;
const Vec4 DECAL_RECEIVER_COLOR @private = { 0.25f, 0.25f, 0.25f, 1 };
const Vec3 DECAL_DISTANT_OFFSET @private = { 65536, 0, 65536 };
const ShadingPath[2] DECAL_PATHS @private = { ShadingPath.FORWARD, ShadingPath.DEFERRED };

struct DecalScene @private {
    Scene scene;
    Node* camera;
    Node* receiver;
    Node* projector;
    GeometryId[2] quads;
    MaterialId[2] receivers;
    MaterialId source;
}

struct DecalView @private {
    RenderTargetId target;
    ViewId view;
}

fn GeometryId? decal_add_quad(Fixture* fixture, bool mirrored_uv) @private {
    Vec3[4] positions = { { -2, -2, 0 }, { 2, -2, 0 }, { 2, 2, 0 }, { -2, 2, 0 } };
    Vec3[4] normals = { { 0, 0, 1 }, { 0, 0, 1 }, { 0, 0, 1 }, { 0, 0, 1 } };
    Vec2[4] coordinates = { { 0, 1 }, { 1, 1 }, { 1, 0 }, { 0, 0 } };
    uint[6] indices = { 0, 1, 2, 0, 2, 3 };
    if (mirrored_uv) {
        foreach (&coordinate : coordinates) coordinate.y = 1 - coordinate.y;
    }
    Geometry geometry = {
        .topology = Topology.TRIANGLES,
        .positions = positions[..],
        .normals = normals[..],
        .uv0 = coordinates[..],
        .indices = indices[..],
    };
    geometry.finalize();
    return fixture.assets.add_geometry(&geometry);
}

fn MaterialId? decal_add_material(Fixture* fixture, StandardParams params, bool physical = false) @private {
    if (!physical) return fixture.assets.add_material(material::standard(params));
    PhysicalParams extended = material::PHYSICAL_PARAMS_DEFAULT;
    extended.standard = params;
    return fixture.assets.add_material(material::physical(extended));
}

fn DecalScene? decal_create_scene(Fixture* fixture) @private {
    DecalScene result;
    result.scene = scene::create_scene(fixture.allocator, scene::default_scene_desc());
    defer catch scene::destroy_scene(&result.scene);
    result.scene.ambient_color = { 1, 1, 1 };
    result.scene.ambient_intensity = 1;
    result.quads[0] = decal_add_quad(fixture, false)!;
    result.quads[1] = decal_add_quad(fixture, true)!;
    StandardParams params = material::STANDARD_PARAMS_DEFAULT;
    params.base_color = DECAL_RECEIVER_COLOR;
    params.metallic = 0;
    params.roughness = 1;
    for (uint kind = 0; kind < result.receivers.len; kind++) {
        result.receivers[kind] = decal_add_material(fixture, params, kind != 0)!;
    }
    result.receiver = result.scene.add_mesh(result.quads[0], result.receivers[0])!;
    result.scene.get(result.receiver, Mesh).cast_shadow = false;
    result.camera = result.scene.add_camera(camera::orthographic(DECAL_VIEW_HEIGHT, 0.1f, 20))!;
    result.camera.local.position = { 0, 0, 3 };
    params.base_color = { 1, 0, 0, 1 };
    result.source = decal_add_material(fixture, params)!;
    DecalDesc desc = scene::default_decal_desc(result.source);
    desc.size = { 2, 2, 1 };
    desc.decal.weights = { .base_color = 1, .normal = 0, .roughness = 0, .metallic = 0 };
    result.projector = result.scene.add_decal(desc)!;
    result.scene.update_world();
    return result;
}

fn DecalView? decal_create_view(Fixture* fixture) @private {
    DecalView result;
    result.target = render::create_render_target(
        renderer: &fixture.renderer,
        desc: render::render_target_desc(DECAL_TARGET_SIZE, DECAL_TARGET_SIZE, PixelFormat.RGBA32_FLOAT),
    )!;
    defer catch render::destroy_render_target(&fixture.renderer, result.target)!!;
    ViewDesc desc = render::texture_view_desc(result.target);
    desc.post.anti_aliasing = AntiAliasing.NONE;
    result.view = render::create_view(&fixture.renderer, desc)!;
    return result;
}

fn void decal_destroy_view(Fixture* fixture, DecalView* shot) @private {
    render::destroy_view(&fixture.renderer, shot.view)!!;
    render::destroy_render_target(&fixture.renderer, shot.target)!!;
}

fn void? decal_configure_view(
    Fixture* fixture,
    DecalView* shot,
    ShadingPath shading,
    LightSelection lights = LightSelection.FLAT,
) @private {
    ViewDesc desc = fixture.renderer.views.get(shot.view).desc;
    desc.shading = shading;
    desc.lights = lights;
    return render::configure_view(&fixture.renderer, shot.view, desc);
}

fn Vec4[]? decal_render_pixels(
    Fixture* fixture,
    DecalScene* target,
    DecalView* shot,
    uint frames = 1,
    Vec3 reference = {},
    bool raw_hdr = false,
) @private {
    target.scene.update_world();
    Renderer* renderer = &fixture.renderer;
    for (uint frame = 0; frame < frames; frame++) {
        renderer.begin_frame({ .reference_position = reference })!;
        defer catch render::abort_frame(renderer);
        renderer.render_view(&target.scene, target.camera, shot.view)!;
        renderer.finish_view(shot.view)!;
        if (raw_hdr) {
            render::composite_target(
                renderer: renderer,
                source: &renderer.views.get(shot.view).hdr_color,
                output: &renderer.targets.get(shot.target).target,
                rect: {},
            )!;
        }
        renderer.end_frame()!;
    }
    return read_float_target(fixture, shot.target);
}

fn uint decal_pixel_at(Vec3 position) @private {
    uint column = (uint)((position.x / DECAL_VIEW_HEIGHT + 0.5f) * DECAL_TARGET_SIZE);
    uint row = (uint)((0.5f - position.y / DECAL_VIEW_HEIGHT) * DECAL_TARGET_SIZE);
    return row * DECAL_TARGET_SIZE + column;
}

fn float decal_check_pixel(Vec4 actual, Vec4 expected) @private {
    float maximum;
    for (uint channel = 0; channel < 4; channel++) {
        float difference = math::abs(actual[channel] - expected[channel]);
        assert(difference <= DECAL_PIXEL_TOLERANCE,
            "Decal channel %d: expected %f, found %f", channel, expected[channel], actual[channel]);
        maximum = math::max(maximum, difference);
    }
    return maximum;
}

fn float decal_check_images(Vec4[] actual, Vec4[] expected) @private {
    assert(actual.len == expected.len);
    float maximum;
    foreach (index, pixel : actual) maximum = math::max(maximum, decal_check_pixel(pixel, expected[index]));
    return maximum;
}

fn void decal_check_mip_edges(Vec4[] pixels, Vec4 expected) @private {
    uint[2] inside_columns = { DECAL_TARGET_SIZE / 4 + 1, 3 * DECAL_TARGET_SIZE / 4 };
    uint[2] outside_columns = { DECAL_TARGET_SIZE / 4, 3 * DECAL_TARGET_SIZE / 4 + 1 };
    for (uint row = DECAL_TARGET_SIZE / 2; row < DECAL_TARGET_SIZE / 2 + 2; row++) {
        foreach (edge, column : inside_columns) {
            decal_check_pixel(pixels[row * DECAL_TARGET_SIZE + column], expected);
            decal_check_pixel(pixels[row * DECAL_TARGET_SIZE + outside_columns[edge]], DECAL_RECEIVER_COLOR);
        }
    }
}

fn void test_decal_coverage_order_and_overflow_match_both_paths() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    DecalScene target = decal_create_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    DecalView shot = decal_create_view(&fixture)!!;
    defer decal_destroy_view(&fixture, &shot);
    uint center = decal_pixel_at({});
    uint outside = decal_pixel_at({ 1.5f, 1.5f, 0 });
    float maximum;

    foreach (receiver : target.receivers) {
        target.scene.get(target.receiver, Mesh).material = receiver;
        decal_configure_view(&fixture, &shot, ShadingPath.FORWARD)!!;
        Vec4[] forward = decal_render_pixels(&fixture, &target, &shot)!!;
        defer free(forward);
        assert(forward[center].r > forward[center].g + 0.2f);
        decal_check_pixel(forward[center], { 1, 0, 0, 1 });
        decal_check_pixel(forward[outside], DECAL_RECEIVER_COLOR);
        decal_configure_view(&fixture, &shot, ShadingPath.DEFERRED)!!;
        Vec4[] deferred = decal_render_pixels(&fixture, &target, &shot)!!;
        defer free(deferred);
        maximum = math::max(maximum, decal_check_images(deferred, forward));
    }

    for (int order = 7; order >= 0; order--) {
        StandardParams params = material::STANDARD_PARAMS_DEFAULT;
        params.base_color = (order & 1) != 0 ? (Vec4){ 0, 1, 0, 0.5f } : (Vec4){ 1, 0, 0, 0.5f };
        DecalDesc desc = scene::default_decal_desc(decal_add_material(&fixture, params)!!);
        desc.size = { 2, 2, 1 };
        desc.decal.weights = { .base_color = 1, .normal = 0, .roughness = 0, .metallic = 0 };
        desc.decal.order = order;
        target.scene.add_decal(desc)!!;
    }
    fixture.assets.material(target.source).data.standard.base_color = { 0, 0, 1, 1 };
    fixture.assets.mark_material_dirty(target.source);
    target.scene.get(target.projector, Decal).order = 8;
    Vec3 ordered = DECAL_RECEIVER_COLOR.xyz;
    for (uint order = 0; order < 8; order++) {
        ordered = ordered * 0.5f + ((order & 1) != 0 ? (Vec3){ 0, 0.5f, 0 } : (Vec3){ 0.5f, 0, 0 });
    }
    foreach (receiver : target.receivers) {
        target.scene.get(target.receiver, Mesh).material = receiver;
        foreach (shading : DECAL_PATHS) {
            target.projector.visible = false;
            target.scene.get(target.projector, Decal).receiver_layers = uint::max;
            decal_configure_view(&fixture, &shot, shading)!!;
            Vec4[] flat = decal_render_pixels(&fixture, &target, &shot)!!;
            defer free(flat);
            decal_check_pixel(flat[center], { ordered.x, ordered.y, ordered.z, 1 });
            decal_configure_view(
                fixture: &fixture,
                shot: &shot,
                shading: shading,
                lights: LightSelection.CLUSTERED,
            )!!;
            Vec4[] clustered = decal_render_pixels(
                fixture: &fixture,
                target: &target,
                shot: &shot,
                frames: DECAL_STATS_FRAMES,
            )!!;
            defer free(clustered);
            maximum = math::max(maximum, decal_check_images(clustered, flat));
            assert(fixture.renderer.view_stats(shot.view)!!.decal_overflows == 0);

            target.projector.visible = true;
            Vec4[] overflowed = decal_render_pixels(
                fixture: &fixture,
                target: &target,
                shot: &shot,
                frames: DECAL_STATS_FRAMES,
            )!!;
            defer free(overflowed);
            assert(fixture.renderer.view_stats(shot.view)!!.decal_overflows > 0);
            decal_check_pixel(overflowed[center], { 0, 0, 1, 1 });
            decal_check_pixel(overflowed[outside], DECAL_RECEIVER_COLOR);
            decal_configure_view(&fixture, &shot, shading)!!;
            Vec4[] complete = decal_render_pixels(&fixture, &target, &shot)!!;
            defer free(complete);
            maximum = math::max(maximum, decal_check_images(overflowed, complete));

            target.scene.get(target.projector, Decal).receiver_layers = 2;
            decal_configure_view(
                fixture: &fixture,
                shot: &shot,
                shading: shading,
                lights: LightSelection.CLUSTERED,
            )!!;
            Vec4[] excluded = decal_render_pixels(&fixture, &target, &shot)!!;
            defer free(excluded);
            maximum = math::max(maximum, decal_check_images(excluded, flat));
        }
    }
    io::printfn("Decal coverage/order/overflow maximum channel difference: %f", maximum);
    check_validation(&fixture.renderer);
}

fn void test_decal_sheared_coverage_survives_frame_origin_changes() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    DecalScene target = decal_create_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    DecalView shot = decal_create_view(&fixture)!!;
    defer decal_destroy_view(&fixture, &shot);
    Node* parent = target.scene.add_node()!!;
    parent.local.scale = { 2, 1, 1 };
    target.scene.reparent(target.projector, parent, false);
    target.projector.local.scale = { 1, 1, 1 };
    target.projector.local.rotation = quaternion::from_axis_angle{float}({ 0, 0, 1 }, (float)math::PI / 4);
    target.scene.update_world();
    uint inside = decal_pixel_at(maths::transform_point(target.projector.world, { 0.45f, 0, 0 }));
    uint outside = decal_pixel_at(maths::transform_point(target.projector.world, { 0.65f, 0, 0 }));
    float maximum;
    foreach (shading : DECAL_PATHS) {
        target.scene.root.local.position = {};
        decal_configure_view(
            fixture: &fixture,
            shot: &shot,
            shading: shading,
            lights: LightSelection.CLUSTERED,
        )!!;
        Vec4[] reference = decal_render_pixels(&fixture, &target, &shot)!!;
        defer free(reference);
        decal_check_pixel(reference[inside], { 1, 0, 0, 1 });
        decal_check_pixel(reference[outside], DECAL_RECEIVER_COLOR);
        target.scene.root.local.position = DECAL_DISTANT_OFFSET;
        Vec3[2] origins = { DECAL_DISTANT_OFFSET, DECAL_DISTANT_OFFSET + (Vec3){ 256, 0, -256 } };
        foreach (origin : origins) {
            Vec4[] shifted = decal_render_pixels(
                fixture: &fixture,
                target: &target,
                shot: &shot,
                reference: origin,
            )!!;
            defer free(shifted);
            maximum = math::max(maximum, decal_check_pixel(shifted[inside], reference[inside]));
            maximum = math::max(maximum, decal_check_pixel(shifted[outside], reference[outside]));
        }
    }
    io::printfn("Decal affine/origin sample maximum channel difference: %f", maximum);
    check_validation(&fixture.renderer);
}

fn void test_decal_normals_match_derived_material_frames() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    DecalScene target = decal_create_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    DecalView shot = decal_create_view(&fixture)!!;
    defer decal_destroy_view(&fixture, &shot);
    target.scene.ambient_intensity = 0;
    Node* sun = target.scene.add_light(light::directional({ 1, 1, 1 }, 3, false))!!;
    sun.local.rotation = maths::look_rotation((Vec3){ 0, 1, -1 }.normalize(), { 0, 0, 1 });
    Vec4[1] normal_pixel = { { 0.5f, 0.85f, 0.85f, 1 } };
    TextureId normal = fixture.assets.add_texture(
        material::texture_2d_desc(1, 1, PixelFormat.RGBA32_FLOAT),
        ((char*)&normal_pixel)[:Vec4::size],
    )!!;
    TextureSlot normal_map = material::texture_slot(normal);
    fixture.assets.material(target.source).data.standard.normal_map = normal_map;
    fixture.assets.material(target.source).data.standard.normal_scale = 1;
    fixture.assets.mark_material_dirty(target.source);
    target.scene.get(target.projector, Decal).weights = {
        .base_color = 0, .normal = 1, .roughness = 0, .metallic = 0,
    };
    MaterialId[2] mapped_materials;
    for (uint kind = 0; kind < mapped_materials.len; kind++) {
        StandardParams params = material::STANDARD_PARAMS_DEFAULT;
        params.base_color = DECAL_RECEIVER_COLOR;
        params.metallic = 0;
        params.roughness = 1;
        params.normal_map = normal_map;
        mapped_materials[kind] = decal_add_material(&fixture, params, kind != 0)!!;
    }
    uint center = decal_pixel_at({});
    float maximum;
    for (uint kind = 0; kind < mapped_materials.len; kind++) {
        foreach (shading : DECAL_PATHS) {
            decal_configure_view(&fixture, &shot, shading)!!;
            target.projector.visible = false;
            target.scene.get(target.receiver, Mesh).material = target.receivers[kind];
            Vec4[] baseline = decal_render_pixels(&fixture, &target, &shot)!!;
            defer free(baseline);
            for (uint mirrored = 0; mirrored < 2; mirrored++) {
                target.projector.visible = false;
                target.scene.get(target.receiver, Mesh).geometry = target.quads[mirrored];
                target.scene.get(target.receiver, Mesh).material = mapped_materials[kind];
                Vec4[] reference = decal_render_pixels(&fixture, &target, &shot)!!;
                defer free(reference);
                assert(math::abs(reference[center].r - baseline[center].r) > 0.05f);

                target.projector.visible = true;
                target.projector.local.scale.y = mirrored != 0 ? -2 : 2;
                target.scene.get(target.receiver, Mesh).material = target.receivers[kind];
                Vec4[] projected = decal_render_pixels(&fixture, &target, &shot)!!;
                defer free(projected);
                for (uint row = 24; row < 40; row++) {
                    for (uint column = 24; column < 40; column++) {
                        uint pixel = row * DECAL_TARGET_SIZE + column;
                        maximum = math::max(maximum, decal_check_pixel(projected[pixel], reference[pixel]));
                    }
                }
            }

            fixture.assets.material(target.source).data.standard.normal_scale = 0;
            fixture.assets.mark_material_dirty(target.source);
            Vec4[] unperturbed = decal_render_pixels(&fixture, &target, &shot)!!;
            defer free(unperturbed);
            maximum = math::max(maximum, decal_check_pixel(unperturbed[center], baseline[center]));
            fixture.assets.material(target.source).data.standard.normal_scale = 1;
            fixture.assets.mark_material_dirty(target.source);
        }
    }

    *((Vec4*)fixture.assets.texture(normal).pixels.ptr) = { 0.5f, 0.5f, 0, 1 };
    fixture.assets.mark_texture_dirty(normal);
    target.scene.get(target.projector, Decal).weights.normal = 0.5f;
    foreach (shading : DECAL_PATHS) {
        decal_configure_view(&fixture, &shot, shading)!!;
        target.projector.visible = false;
        Vec4[] baseline = decal_render_pixels(&fixture, &target, &shot)!!;
        defer free(baseline);
        target.projector.visible = true;
        Vec4[] opposite = decal_render_pixels(&fixture, &target, &shot)!!;
        defer free(opposite);
        maximum = math::max(maximum, decal_check_pixel(opposite[center], baseline[center]));
    }
    sun.local.rotation = quaternion::IDENTITY;
    fixture.assets.material(target.source).data.standard.metallic = 1;
    fixture.assets.material(target.source).data.standard.roughness = 0.2f;
    fixture.assets.mark_material_dirty(target.source);
    for (uint kind = 0; kind < target.receivers.len; kind++) {
        for (uint mode = 0; mode < 3; mode++) {
            bool roughness = mode != 2;
            bool metallic = mode != 1;
            StandardParams params = material::STANDARD_PARAMS_DEFAULT;
            params.base_color = DECAL_RECEIVER_COLOR;
            params.metallic = metallic ? 1 : 0;
            params.roughness = roughness ? 0.2f : 1;
            MaterialId direct = decal_add_material(&fixture, params, kind != 0)!!;
            target.scene.get(target.projector, Decal).weights = {
                .base_color = 0,
                .normal = 0,
                .roughness = roughness ? 1 : 0,
                .metallic = metallic ? 1 : 0,
            };
            foreach (shading : DECAL_PATHS) {
                decal_configure_view(&fixture, &shot, shading)!!;
                target.projector.visible = false;
                target.scene.get(target.receiver, Mesh).material = target.receivers[kind];
                Vec4[] baseline = decal_render_pixels(&fixture, &target, &shot)!!;
                defer free(baseline);
                target.scene.get(target.receiver, Mesh).material = direct;
                Vec4[] reference = decal_render_pixels(&fixture, &target, &shot)!!;
                defer free(reference);
                assert(math::abs(reference[center].r - baseline[center].r) > 0.05f);

                target.projector.visible = true;
                target.scene.get(target.receiver, Mesh).material = target.receivers[kind];
                Vec4[] projected = decal_render_pixels(&fixture, &target, &shot)!!;
                defer free(projected);
                maximum = math::max(maximum, decal_check_pixel(projected[center], reference[center]));
            }
        }
    }
    io::printfn("Decal normal/material-channel maximum channel difference: %f", maximum);
    check_validation(&fixture.renderer);
}

fn void test_decal_fade_matches_cpu_weight_on_both_paths() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    DecalScene target = decal_create_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    DecalView shot = decal_create_view(&fixture)!!;
    defer decal_destroy_view(&fixture, &shot);
    target.projector.local.scale = { 3, 3, 3 };
    uint center = decal_pixel_at({});
    float[4] angles = { 0, 10, 45, 90 };
    float maximum;
    foreach (degrees : angles) {
        float angle = math::deg_to_rad(degrees);
        target.scene.get(target.projector, Decal).fade_angle = angle;
        float cosine = math::cos(angle);
        float band = math::min(shader::DECAL_FADE_BAND, 1.0f - cosine);
        float[3] facing = { 1, band > 0 ? cosine + band * 0.5f : 0.999f, cosine - 0.01f };
        foreach (orientation : facing) {
            target.projector.local.rotation = quaternion::from_axis_angle{float}(
                { 0, 1, 0 }, math::acos(orientation));
            target.scene.update_world();
            DecalGpu packed = render::pack_decal(
                target.projector, target.scene.get(target.projector, Decal), (gpu::GpuAddress)0);
            float weight = render::decal_angle_weight(
                packed.projection_fade.z, packed.fade_cosine, packed.projection_fade.w);
            Vec3 expected = DECAL_RECEIVER_COLOR.xyz * (1 - weight) + (Vec3){ weight, 0, 0 };
            foreach (shading : DECAL_PATHS) {
                decal_configure_view(&fixture, &shot, shading)!!;
                Vec4[] pixels = decal_render_pixels(&fixture, &target, &shot)!!;
                defer free(pixels);
                maximum = math::max(maximum,
                    decal_check_pixel(pixels[center], { expected.x, expected.y, expected.z, 1 }));
            }
        }
    }
    io::printfn("Decal fade CPU/GPU maximum channel difference: %f", maximum);
    check_validation(&fixture.renderer);
}

fn TextureId? decal_add_mip_texture(Fixture* fixture) @private {
    const uint MIP_COUNT = 7;
    const uint TEXEL_BYTES = 4;
    const uint[MIP_COUNT] COLORS = {
        0xff0000ff, 0xff00ff00, 0xffff0000, 0xff00ffff, 0xffff00ff, 0xffffff00, 0xffffffff,
    };
    @pool() {
        TextureMipData[MIP_COUNT] levels;
        for (uint mip = 0; mip < MIP_COUNT; mip++) {
            uint width = DECAL_TARGET_SIZE >> mip;
            uint[] pixels = alloc::new_array(tmem, uint, (sz)(width * width));
            foreach (&pixel : pixels) *pixel = COLORS[mip];
            levels[mip] = { .mip = mip, .bytes = ((char*)pixels.ptr)[:pixels.len * TEXEL_BYTES] };
        }
        material::TextureDesc desc = material::texture_2d_desc(
            DECAL_TARGET_SIZE, DECAL_TARGET_SIZE, PixelFormat.RGBA8_UNORM);
        desc.generate_mips = false;
        desc.mip_levels = MIP_COUNT;
        return fixture.assets.add_texture_mips(desc, levels[..]);
    };
}

fn void test_decal_gradients_preserve_uv_scale_and_mip_bias() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    DecalScene target = decal_create_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    DecalView shot = decal_create_view(&fixture)!!;
    defer decal_destroy_view(&fixture, &shot);
    TextureId texture = decal_add_mip_texture(&fixture)!!;
    StandardParams* source = &fixture.assets.material(target.source).data.standard;
    source.base_color = { 1, 1, 1, 1 };
    source.base_color_map = material::texture_slot(texture, asset::SAMPLER_NEAREST);
    fixture.assets.mark_material_dirty(target.source);
    // One pixel of translation makes both vertical edges split 2x2 fragment quads.
    target.projector.local.position.x = DECAL_VIEW_HEIGHT / (float)DECAL_TARGET_SIZE;
    uint center = decal_pixel_at({});
    foreach (shading : DECAL_PATHS) {
        ViewDesc desc = fixture.renderer.views.get(shot.view).desc;
        desc.shading = shading;
        desc.post.anti_aliasing = AntiAliasing.NONE;
        render::configure_view(&fixture.renderer, shot.view, desc)!!;
        source.base_color_map.transform.scale = { 1, 1 };
        fixture.assets.mark_material_dirty(target.source);
        Vec4[] original = decal_render_pixels(&fixture, &target, &shot)!!;
        defer free(original);
        decal_check_pixel(original[center], { 0, 1, 0, 1 });

        source.base_color_map.transform.scale = { 4, 4 };
        fixture.assets.mark_material_dirty(target.source);
        Vec4[] scaled = decal_render_pixels(
            fixture: &fixture,
            target: &target,
            shot: &shot,
            raw_hdr: true,
        )!!;
        defer free(scaled);
        decal_check_pixel(scaled[center], { 1, 1, 0, 1 });
        decal_check_mip_edges(scaled, { 1, 1, 0, 1 });

        desc.post.anti_aliasing = AntiAliasing.TAA;
        desc.post.taa_params.current_weight = 1;
        desc.post.taa_params.mip_bias = -1;
        render::configure_view(&fixture.renderer, shot.view, desc)!!;
        Vec4[] biased = decal_render_pixels(
            fixture: &fixture,
            target: &target,
            shot: &shot,
            raw_hdr: true,
        )!!;
        defer free(biased);
        decal_check_pixel(biased[center], { 0, 0, 1, 1 });
        decal_check_mip_edges(biased, { 0, 0, 1, 1 });
    }
    check_validation(&fixture.renderer);
}
