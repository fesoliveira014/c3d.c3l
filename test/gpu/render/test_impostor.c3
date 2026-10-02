module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::asset::image;
import c3d::camera;
import c3d::geometry;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::render @public;
import c3d::scene;
import c3d::spatial;
import gpu;
import std::math;
import std::io;

const uint IMPOSTOR_IMAGE_SIZE @private = 512;

fn DeformedScene? create_impostor_scene(Fixture* fixture, bool instanced = false) @private {
    DeformedScene target;
    target.scene = scene::create_scene(fixture.allocator, scene::default_scene_desc());
    defer catch scene::destroy_scene(&target.scene);
    target.scene.ambient_intensity = 1;
    StandardParams surface = material::STANDARD_PARAMS_DEFAULT;
    surface.metallic = 0;
    surface.base_color = { 0.2f, 0.4f, 0.8f, 1 };
    MaterialId material = fixture.assets.add_material(material::standard(surface))!;
    LodLevel[1] levels = {{ .part_count = 1 }};
    LodPart[1] parts = {{ .geometry = fixture.box, .material = material, .local = matrix::IDENTITY4 }};
    Transform[1] transforms = { maths::TRANSFORM_IDENTITY };
    LodDesc desc = { .levels = levels[..], .parts = parts[..] };
    target.mesh = instanced ? target.scene.add_instanced_lod_group(
        assets: &fixture.assets,
        desc: desc,
        capacity: 1,
        transforms: transforms[..],
    )! : target.scene.add_lod_group(&fixture.assets, desc)!;
    target.camera = target.scene.add_camera(camera::perspective_deg(60, 0.1f))!;
    target.camera.local.position = { 0, 0, 32 };
    target.scene.update_world();
    Impostor baked = fixture.renderer.bake_impostor(&target.scene, target.mesh)!;
    target.scene.set_lod_impostor(
        assets: &fixture.assets,
        node: target.mesh,
        impostor: baked,
        min_screen_size: 1,
    )!;
    fixture.renderer.prepare_scene(&target.scene)!;
    assert(render::texture_current(&fixture.renderer, baked.atlas));
    return target;
}

fn LodVelocityProbe? create_impostor_probe(Fixture* fixture) @private {
    gpu::AllocationDesc allocation = {
        .size = IMPOSTOR_IMAGE_SIZE * IMPOSTOR_IMAGE_SIZE * Vec4::size,
        .alignment = render::STREAM_ALIGNMENT,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access = { .graphics },
        .debug_name = "impostor_surface_readback",
    };
    return {
        .readback = gpu::allocate_mapped_memory(&fixture.renderer.device, &allocation)!,
        .output = fixture.renderer.create_buffer({ .size = allocation.size, .debug_name = "impostor_surface_output" })!,
        .shader = add_compute_shader(fixture, (String)PROBE_READBACK_SOURCE[..])!,
    };
}

fn void save_impostor_difference(Vec4[] actual, Vec4[] reference, uint direction, uint path) @private {
    @pool() {
        char[] pixels = alloc::new_array(tmem, char, IMPOSTOR_IMAGE_SIZE * IMPOSTOR_IMAGE_SIZE * 4);
        foreach (index, value : actual) {
            pixels[index * 4] = value.x > 0 ? 255 : 0;
            pixels[index * 4 + 1] = reference[index].x > 0 ? 255 : 0;
            pixels[index * 4 + 3] = 255;
        }
        image::write_png(
            path: string::tformat("impostor-difference-%s-%s.png", direction, path),
            width: IMPOSTOR_IMAGE_SIZE,
            height: IMPOSTOR_IMAGE_SIZE,
            pixels: pixels,
        )!!;
    };
}

fn void test_baked_box_matches_mesh() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    DeformedScene target = create_impostor_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    target.scene.ambient_intensity = 0.25f;
    Light sunlight = light::directional({ 1, 1, 1 }, 2);
    sunlight.shadow.enabled = false;
    Node* sun = target.scene.add_light(sunlight)!!;
    sun.local.rotation = maths::look_rotation((Vec3){ -0.4f, -1, -0.5f }.normalize(), { 0, 1, 0 });
    LodGroupState* group = target.scene.get(target.mesh, LodGroup).state;
    Node* reference = target.scene.add_mesh(fixture.box, group.desc.parts[0].material)!!;
    reference.visible = false;
    RenderTargetId output = render::create_render_target(
        &fixture.renderer, render::render_target_desc(IMPOSTOR_IMAGE_SIZE, IMPOSTOR_IMAGE_SIZE, PixelFormat.RGBA32_FLOAT),
    )!!;
    fixture.view = render::create_view(&fixture.renderer, render::texture_view_desc(output))!!;
    LodVelocityProbe probe = create_impostor_probe(&fixture)!!;
    defer free_lod_readback(&fixture.renderer, probe.readback);
    Vec4[] color = mem::new_array(Vec4, IMPOSTOR_IMAGE_SIZE * IMPOSTOR_IMAGE_SIZE);
    defer free(color);
    Vec4[] reference_color = mem::new_array(Vec4, color.len);
    defer free(reference_color);
    Vec4[] depth = mem::new_array(Vec4, color.len);
    defer free(depth);
    Vec4[] reference_depth = mem::new_array(Vec4, color.len);
    defer free(reference_depth);
    Vec3[6] directions = { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 }, { 1, 1, 1 }, { 1, 0.001f, -1 }, { 1, -0.001f, -1 } };
    float distance = group.impostor.bounds.radius * (float)IMPOSTOR_IMAGE_SIZE / (24 * math::tan(math::deg_to_rad(30.0f)));
    bool accepted = true;
    for (uint path = 0; path < 4; path++) {
        ViewDesc view = render::texture_view_desc(output);
        view.shading = path >= 2 ? ShadingPath.DEFERRED : ShadingPath.FORWARD;
        view.depth_prepass = path % 2 != 0;
        view.post.anti_aliasing = AntiAliasing.NONE;
        render::configure_view(&fixture.renderer, fixture.view, view)!!;
        foreach (uint direction_index, direction : directions) {
            direction = direction.normalize();
            target.camera.local.position = direction * distance;
            target.camera.local.rotation = maths::rotation_between({ 0, 0, 1 }, direction);
            target.mesh.visible = true;
            reference.visible = false;
            capture_lod_effects(
                fixture: &fixture,
                target: &target,
                probe: &probe,
                output: output,
                color: color,
                depth: depth,
            )!!;
            assert(fixture.renderer.stats.lod_objects_visible[1] == 1);
            target.mesh.visible = false;
            reference.visible = true;
            capture_lod_effects(
                fixture: &fixture,
                target: &target,
                probe: &probe,
                output: output,
                color: reference_color,
                depth: reference_depth,
            )!!;
            uint union_count;
            uint difference;
            float maximum_depth_error;
            float maximum_color_error;
            float interior_color_error;
            uint interior_count;
            foreach (index, pixel : depth) {
                bool actual = pixel.x > 0;
                bool expected = reference_depth[index].x > 0;
                union_count += actual || expected ? 1 : 0;
                difference += actual != expected ? 1 : 0;
                if (actual && expected) {
                    float error = math::abs(0.1f / pixel.x - 0.1f / reference_depth[index].x);
                    maximum_depth_error = math::max(maximum_depth_error, error);
                    Vec4 delta = math::abs(color[index] - reference_color[index]);
                    maximum_color_error = math::max(maximum_color_error, math::max(delta.x, math::max(delta.y, delta.z)));
                    uint x = (uint)(index % IMPOSTOR_IMAGE_SIZE);
                    uint y = (uint)(index / IMPOSTOR_IMAGE_SIZE);
                    bool interior = x > 0 && y > 0 && x + 1 < IMPOSTOR_IMAGE_SIZE && y + 1 < IMPOSTOR_IMAGE_SIZE;
                    for (int dy = -1; dy <= 1 && interior; dy++) {
                        for (int dx = -1; dx <= 1; dx++) {
                            Vec4 neighbor = math::abs(reference_color[(sz)index + (sz)dy * IMPOSTOR_IMAGE_SIZE + dx] - reference_color[index]);
                            if (math::max(neighbor.x, math::max(neighbor.y, neighbor.z)) > 0.01f) interior = false;
                        }
                    }
                    if (interior) {
                        interior_color_error = math::max(interior_color_error, math::max(delta.x, math::max(delta.y, delta.z)));
                        interior_count++;
                    }
                }
            }
            float mask_error = (float)difference / (float)union_count;
            float depth_tolerance = 2 * group.impostor.bounds.radius / 255 + 2 * distance * math::tan(math::deg_to_rad(30.0f)) / (float)IMPOSTOR_IMAGE_SIZE;
            bool passed = union_count > 100 && mask_error < 0.03f && maximum_depth_error <= depth_tolerance
              && interior_count > 60 && interior_color_error < 0.01f;
            io::printfn(
                "impostor direction %s path %s union %s mask %.5f depth %.6f tolerance %.6f color %.6f",
                direction_index, path, union_count, mask_error,
                maximum_depth_error, depth_tolerance, maximum_color_error,
            );
            io::printfn("interior color %.6f", interior_color_error);
            if (!passed) save_impostor_difference(
                actual: depth,
                reference: reference_depth,
                direction: direction_index,
                path: path,
            );
            accepted &= passed;
        }
    }
    check_validation(&fixture.renderer);
    assert(accepted);
}

fn void test_impostor_depth_occludes_consistently() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    DeformedScene target = create_impostor_scene(&fixture, true)!!;
    defer scene::destroy_scene(&target.scene);
    RenderTargetId output = render::create_render_target(
        &fixture.renderer, render::render_target_desc(IMPOSTOR_IMAGE_SIZE, IMPOSTOR_IMAGE_SIZE, PixelFormat.RGBA32_FLOAT),
    )!!;
    fixture.view = render::create_view(&fixture.renderer, render::texture_view_desc(output))!!;
    LodVelocityProbe probe = create_impostor_probe(&fixture)!!;
    defer free_lod_readback(&fixture.renderer, probe.readback);
    Vec4[] color = mem::new_array(Vec4, IMPOSTOR_IMAGE_SIZE * IMPOSTOR_IMAGE_SIZE);
    defer free(color);
    Vec4[] depth = mem::new_array(Vec4, color.len);
    defer free(depth);
    MaterialId red = fixture.assets.add_material(material::basic({ .color = { 1, 0, 0, 1 } }))!!;
    Node* plane = target.scene.add_mesh(fixture.box, red)!!;
    plane.local.scale = { 2, 2, 0.005f };
    usz center = (IMPOSTOR_IMAGE_SIZE / 2) * IMPOSTOR_IMAGE_SIZE + IMPOSTOR_IMAGE_SIZE / 2;
    for (uint path = 0; path < 4; path++) {
        ViewDesc view = render::texture_view_desc(output);
        view.shading = path >= 2 ? ShadingPath.DEFERRED : ShadingPath.FORWARD;
        view.depth_prepass = path % 2 != 0;
        view.post.anti_aliasing = AntiAliasing.NONE;
        render::configure_view(&fixture.renderer, fixture.view, view)!!;
        foreach (float camera_x : { -0.2f, 0.2f }) {
            target.camera.local.position.x = camera_x;
            target.camera.local.rotation = maths::look_rotation(-target.camera.local.position.normalize(), { 0, 1, 0 });
            foreach (bool front : { false, true }) {
                plane.local.position.z = front ? 0.6f : 0.3f;
                capture_lod_effects(
                    fixture: &fixture,
                    target: &target,
                    probe: &probe,
                    output: output,
                    color: color,
                    depth: depth,
                )!!;
                Vec4 pixel = color[center];
                assert(front ? pixel.x > 0.95f && pixel.z < 0.01f : pixel.z > 0.7f && pixel.x < 0.3f);
                float surface = 32 - 0.1f / depth[center].x;
                assert(math::abs(surface - (front ? 0.6025f : 0.5f)) < 0.02f);
                assert(fixture.renderer.stats.lod_visible[1] == 1);
            }
        }
    }
    check_validation(&fixture.renderer);
}

fn Vec4 impostor_velocity_pixel(LodVelocityProbe* probe, Vec2 uv) @private {
    uint x = (uint)(uv.x * IMPOSTOR_IMAGE_SIZE);
    uint y = (uint)(uv.y * IMPOSTOR_IMAGE_SIZE);
    return ((Vec4*)probe.readback.bytes.ptr)[y * IMPOSTOR_IMAGE_SIZE + x];
}

fn void test_impostor_motion_and_transition() @test {
    foreach (bool instanced : { false, true }) {
        Fixture fixture;
        create_fixture(mem, &fixture)!!;
        defer destroy_fixture(&fixture);
        DeformedScene target = create_impostor_scene(&fixture, instanced)!!;
        defer scene::destroy_scene(&target.scene);
        target.camera.local.position = { 0.3f, 0.1f, 8 };
        LodGroupState* group = target.scene.get(target.mesh, LodGroup).state;
        if (instanced) {
            Node* old = target.mesh;
            Transform[2] transforms = { maths::TRANSFORM_IDENTITY, maths::TRANSFORM_IDENTITY };
            transforms[1].position.x = -1.5f;
            target.mesh = target.scene.add_instanced_lod_group(
                assets: &fixture.assets,
                desc: group.desc,
                capacity: 2,
                transforms: transforms[..],
            )!!;
            target.scene.set_lod_impostor(
                assets: &fixture.assets,
                node: target.mesh,
                impostor: group.impostor,
                min_screen_size: 1,
            )!!;
            target.scene.remove(old);
            group = target.scene.get(target.mesh, LodGroup).state;
        }
        Node* stable = target.scene.add_mesh(fixture.box, group.desc.parts[0].material)!!;
        stable.local.position = { 1.5f, 0, 0 };
        RenderTargetId output = render::create_render_target(
            &fixture.renderer, render::render_target_desc(IMPOSTOR_IMAGE_SIZE, IMPOSTOR_IMAGE_SIZE, PixelFormat.RGBA32_FLOAT),
        )!!;
        fixture.view = render::create_view(&fixture.renderer, render::texture_view_desc(output))!!;
        enable_taa(&fixture, fixture.view)!!;
        LodVelocityProbe probe = create_impostor_probe(&fixture)!!;
        defer free_lod_readback(&fixture.renderer, probe.readback);
        target.scene.update_world();
        CameraMatrices matrices = camera::derive_matrices(*target.scene.get(target.camera, Camera), target.camera.world, { IMPOSTOR_IMAGE_SIZE, IMPOSTOR_IMAGE_SIZE });
        Vec2 uv = projected_uv(&matrices, { 0, 0, 0.5f });
        for (uint frame = 0; frame < SETTLE_FRAMES; frame++) {
            render_lod_velocity(
                fixture: &fixture,
                target: &target,
                probe: &probe,
                uv: uv,
            )!!;
        }
        assert(impostor_velocity_pixel(&probe, uv).w == 0);
        ViewId main_view = fixture.view;
        fixture.second_view = render::create_view(&fixture.renderer, render::texture_view_desc(output))!!;
        enable_taa(&fixture, fixture.second_view)!!;
        fixture.view = fixture.second_view;
        target.camera.local.position.x = -2;
        render_lod_velocity(
            fixture: &fixture,
            target: &target,
            probe: &probe,
            uv: uv,
        )!!;
        target.camera.local.position.x = 0.3f;
        fixture.view = main_view;
        if (instanced) {
            group.transforms[0].position.x = 0.05f;
            target.scene.mark_lod_instances_dirty(target.mesh);
        } else {
            target.mesh.local.position.x = 0.05f;
        }
        uv = projected_uv(&matrices, { 0.05f, 0, 0.5f });
        render_lod_velocity(
            fixture: &fixture,
            target: &target,
            probe: &probe,
            uv: uv,
        )!!;
        Vec4 velocity = impostor_velocity_pixel(&probe, uv);
        Vec2 previous = projected_uv(&matrices, { 0, 0, 0.5f });
        assert(velocity.w == 0 && math::abs(velocity.x - (uv.x - previous.x)) < 1e-4f && math::abs(velocity.y) < 1e-4f);
        Vec2 stable_uv = projected_uv(&matrices, stable.local.position);
        assert(impostor_velocity_pixel(&probe, stable_uv).w == 0);
        if (instanced) {
            Vec4 stationary = impostor_velocity_pixel(&probe, projected_uv(&matrices, { -1.5f, 0, 0.5f }));
            assert(stationary.w == 0 && math::abs(stationary.x) < 1e-4f && math::abs(stationary.y) < 1e-4f);
        }

        target.camera.local.position.x = -0.3f;
        target.scene.update_world();
        matrices = camera::derive_matrices(*target.scene.get(target.camera, Camera), target.camera.world, { IMPOSTOR_IMAGE_SIZE, IMPOSTOR_IMAGE_SIZE });
        uv = projected_uv(&matrices, { 0.05f, 0, 0.5f });
        render_lod_velocity(
            fixture: &fixture,
            target: &target,
            probe: &probe,
            uv: uv,
        )!!;
        assert(impostor_velocity_pixel(&probe, uv).w == 1);
        assert(impostor_velocity_pixel(&probe, projected_uv(&matrices, stable.local.position)).w == 0);
        render_lod_velocity(
            fixture: &fixture,
            target: &target,
            probe: &probe,
            uv: uv,
        )!!;
        assert(impostor_velocity_pixel(&probe, uv).w == 0);
        ViewDesc view = fixture.renderer.views.get(fixture.view).desc;
        view.lod_bias = 8;
        render::configure_view(&fixture.renderer, fixture.view, view)!!;
        render_lod_velocity(
            fixture: &fixture,
            target: &target,
            probe: &probe,
            uv: uv,
        )!!;
        assert(impostor_velocity_pixel(&probe, uv).w == 1);
        render_lod_velocity(
            fixture: &fixture,
            target: &target,
            probe: &probe,
            uv: uv,
        )!!;
        assert(impostor_velocity_pixel(&probe, uv).w == 0);
        view.lod_bias = 0;
        render::configure_view(&fixture.renderer, fixture.view, view)!!;
        render_lod_velocity(
            fixture: &fixture,
            target: &target,
            probe: &probe,
            uv: uv,
        )!!;
        assert(impostor_velocity_pixel(&probe, uv).w == 1);
        fixture.assets.remove_texture(group.impostor.atlas);
        for (uint frame = 0; frame < SETTLE_FRAMES; frame++) {
            render_lod_velocity(
                fixture: &fixture,
                target: &target,
                probe: &probe,
                uv: uv,
            )!!;
        }
        assert(fixture.renderer.stats.impostor_fallbacks == 1);
        assert(instanced ? fixture.renderer.stats.lod_visible[0] == 2 && fixture.renderer.stats.lod_visible[1] == 0
          : fixture.renderer.stats.lod_objects_visible[0] == 1 && fixture.renderer.stats.lod_objects_visible[1] == 0);
        check_validation(&fixture.renderer);
    }
}

fn void test_impostor_transform_and_shadow() @test {
    Fixture fixture;
    create_fixture(allocator: mem, fixture: &fixture, shadow_resolution: IMPOSTOR_IMAGE_SIZE)!!;
    defer destroy_fixture(&fixture);
    DeformedScene target = create_impostor_scene(&fixture, true)!!;
    defer scene::destroy_scene(&target.scene);
    target.scene.ambient_intensity = 0.2f;
    target.camera.local.position = { 0, 0, 3 };
    target.camera.local.rotation = maths::look_rotation(((Vec3){ 0, -2, -2 } - target.camera.local.position).normalize(), { 0, 1, 0 });
    target.mesh.local.position = { 0, 3, 0 };
    target.mesh.local.scale = { -1.2f, 0.8f, 0.6f };
    LodGroupState* group = target.scene.get(target.mesh, LodGroup).state;
    LodEffects effects = group.effects;
    effects.sway = { .direction = { 1, 0, 0 }, .amplitude = 0.12f, .frequency = 0.5f, .lean = 0.3f, .weight = SwayWeight.HEIGHT };
    target.scene.set_lod_effects(target.mesh, effects);
    MaterialId matte = fixture.assets.add_material(material::standard(SHADOW_GROUND_PARAMS))!!;
    Node* wall = target.scene.add_mesh(fixture.box, matte)!!;
    wall.local.position = { 0, 0, -2 };
    wall.local.scale = { 8, 8, 0.02f };
    target.scene.get(wall, Mesh).cast_shadow = false;
    Light sunlight = light::directional({ 1, 1, 1 }, 3);
    sunlight.shadow.cascades = 1;
    sunlight.shadow.max_distance = 12;
    Node* sun = target.scene.add_light(sunlight)!!;
    sun.local.rotation = maths::rotation_between({ 0, 0, -1 }, (Vec3){ 0, -1, -0.5f }.normalize());
    RenderTargetId output = render::create_render_target(
        &fixture.renderer, render::render_target_desc(IMPOSTOR_IMAGE_SIZE, IMPOSTOR_IMAGE_SIZE, PixelFormat.RGBA32_FLOAT),
    )!!;
    fixture.view = render::create_view(&fixture.renderer, render::texture_view_desc(output))!!;
    target.scene.update_world();
    CameraMatrices matrices = camera::derive_matrices(*target.scene.get(target.camera, Camera), target.camera.world, { IMPOSTOR_IMAGE_SIZE, IMPOSTOR_IMAGE_SIZE });
    Aabb bounds = spatial::lod_world_bounds(&fixture.assets, target.mesh, target.scene.get(target.mesh, LodGroup));
    assert(!maths::frustum_intersects_aabb(&matrices.frustum, bounds));
    Vec2 uv = projected_uv(&matrices, { 0, -0.98f, -1.99f });
    uint impostor_pixel = render_at(
        fixture: &fixture,
        target: &target,
        view: fixture.view,
        time: 0.37,
        uv: uv,
    )!!;
    assert(fixture.renderer.stats.shadow_layers == 1);
    Vec4[] actual = mem::new_array(Vec4, IMPOSTOR_IMAGE_SIZE * IMPOSTOR_IMAGE_SIZE);
    defer free(actual);
    Vec4[] reference = mem::new_array(Vec4, actual.len);
    defer free(reference);
    Vec4[] empty = mem::new_array(Vec4, actual.len);
    defer free(empty);
    fixture.renderer.read_render_target(output, ((char*)actual.ptr)[:actual.len * Vec4::size])!!;
    ViewDesc view = fixture.renderer.views.get(fixture.view).desc;
    view.lod_bias = 8;
    render::configure_view(&fixture.renderer, fixture.view, view)!!;
    uint mesh_pixel = render_at(
        fixture: &fixture,
        target: &target,
        view: fixture.view,
        time: 0.37,
        uv: uv,
    )!!;
    fixture.renderer.read_render_target(output, ((char*)reference.ptr)[:reference.len * Vec4::size])!!;
    check_near_pixel(impostor_pixel, mesh_pixel);
    target.mesh.visible = false;
    uint empty_pixel = render_at(
        fixture: &fixture,
        target: &target,
        view: fixture.view,
        time: 0.37,
        uv: uv,
    )!!;
    fixture.renderer.read_render_target(output, ((char*)empty.ptr)[:empty.len * Vec4::size])!!;
    assert(shade(impostor_pixel) + 30 < shade(empty_pixel));
    uint shadow_union;
    uint unmatched;
    for (int y = 1; y + 1 < (int)IMPOSTOR_IMAGE_SIZE; y++) {
        for (int x = 1; x + 1 < (int)IMPOSTOR_IMAGE_SIZE; x++) {
            sz index = (sz)y * IMPOSTOR_IMAGE_SIZE + x;
            bool shadow = empty[index].x - actual[index].x > 0.05f;
            bool expected = empty[index].x - reference[index].x > 0.05f;
            shadow_union += shadow || expected ? 1 : 0;
            if (shadow == expected) continue;
            bool matched;
            for (int dy = -1; dy <= 1 && !matched; dy++) {
                for (int dx = -1; dx <= 1; dx++) {
                    sz neighbor = index + (sz)dy * IMPOSTOR_IMAGE_SIZE + dx;
                    matched |= shadow == (empty[neighbor].x - reference[neighbor].x > 0.05f);
                }
            }
            unmatched += matched ? 0 : 1;
        }
    }
    io::printfn("impostor shadow union %s unmatched beyond one pixel %s", shadow_union, unmatched);
    if ((float)unmatched / (float)shadow_union >= 0.03f) {
        foreach (index, &pixel : actual) pixel.x = empty[index].x - pixel.x > 0.05f ? 1 : 0;
        foreach (index, &pixel : reference) pixel.x = empty[index].x - pixel.x > 0.05f ? 1 : 0;
        save_impostor_difference(
            actual: actual,
            reference: reference,
            direction: 6,
            path: 0,
        );
    }
    assert(shadow_union > 200 && (float)unmatched / (float)shadow_union < 0.03f);
    check_validation(&fixture.renderer);
}

fn void test_bake_isolates_subject_and_restores_state() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    StandardParams surface = material::STANDARD_PARAMS_DEFAULT;
    surface.metallic = 0;
    surface.base_color = { 0.2f, 0.4f, 0.8f, 1 };
    surface.roughness = 0.5f;
    MaterialId material = fixture.assets.add_material(material::standard(surface))!!;
    DeformedScene target = create_single_box_scene(&fixture, fixture.box, material, false)!!;
    defer scene::destroy_scene(&target.scene);
    target.mesh.local.position = { 3, 4, 5 };
    Node* sibling = target.scene.add_mesh(fixture.box, fixture.plain)!!;
    sibling.local.position = target.mesh.local.position;
    target.scene.background.color = { 1, 0, 1, 1 };
    target.scene.update_world();
    Mat4 original = target.mesh.world;
    ViewDesc view_before = fixture.renderer.views.get(fixture.view).desc;
    uint view_count = fixture.renderer.views.free_count;
    uint target_count = fixture.renderer.targets.free_count;
    Impostor baked = fixture.renderer.bake_impostor(&target.scene, target.mesh)!!;
    assert(target.mesh.world == original && target.mesh.visible && sibling.visible);
    assert(mem::equals(&view_before, &fixture.renderer.views.get(fixture.view).desc, ViewDesc::size));
    assert(view_count == fixture.renderer.views.free_count && target_count == fixture.renderer.targets.free_count);
    TextureAsset* atlas = fixture.assets.texture(baked.atlas);
    assert(atlas.desc.width == 1024 && atlas.desc.height == 2048 && atlas.pixels.len == 8 * 1024 * 1024);
    assert(baked.bounds.center.length() < 1e-6f && math::abs(baked.bounds.radius - math::sqrt(0.75f)) < 1e-6f);
    uint covered;
    for (usz pixel = 0; pixel < (usz)atlas.desc.width * atlas.desc.width; pixel++) {
        char* color = &atlas.pixels[pixel * 4];
        if (!color[3]) continue;
        covered++;
        assert(color[3] == 255);
        assert(math::abs((int)color[0] - 51) <= 1 && math::abs((int)color[1] - 102) <= 1 && math::abs((int)color[2] - 204) <= 1);
        assert(math::abs((int)atlas.pixels[(pixel + (usz)atlas.desc.width * atlas.desc.width) * 4 + 2] - 128) <= 1);
    }
    assert(covered > 100000);
    target.mesh.local.position = {};
    sibling.visible = false;
    target.scene.update_world();
    render_scene_frame(&fixture, &target)!!;
    check_validation(&fixture.renderer);
    io::printfn("impostor bake %.3f ms, %s atlas bytes, %s capture bytes, %s readback bytes, %s scene peak bytes",
        fixture.renderer.last_impostor_bake.elapsed_ms,
        fixture.renderer.last_impostor_bake.atlas_bytes,
        fixture.renderer.last_impostor_bake.capture_texel_bytes,
        fixture.renderer.last_impostor_bake.readback_bytes,
        fixture.renderer.last_impostor_bake.scene_host_peak,
    );
}

fn void test_masked_capture_has_coverage() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    StandardParams surface = material::STANDARD_PARAMS_DEFAULT;
    surface.metallic = 0;
    surface.roughness = 0.5f;
    material::TextureDesc single_texel = material::texture_2d_desc(1, 1, PixelFormat.RGBA8_UNORM);
    single_texel.generate_mips = false;
    char[4] normal_texel = { 128, 128, 255, 255 };
    char[4] roughness_texel = { 255, 64, 0, 255 };
    surface.normal_map = material::texture_slot(fixture.assets.add_texture(single_texel, normal_texel[..])!!);
    surface.metallic_roughness_map = material::texture_slot(fixture.assets.add_texture(single_texel, roughness_texel[..])!!);
    MaterialId material = fixture.assets.add_material(material::standard(surface))!!;
    DeformedScene target = create_single_box_scene(&fixture, fixture.box, material, false)!!;
    defer scene::destroy_scene(&target.scene);
    ImpostorDesc desc = { .frames_per_side = 4, .cell_size = 32 };
    Impostor opaque = fixture.renderer.bake_impostor(&target.scene, target.mesh, desc)!!;
    char[4 * 4 * 4] mask;
    for (uint y = 0; y < 4; y++) {
        for (uint x = 0; x < 4; x++) {
            usz pixel = ((usz)y * 4 + x) * 4;
            mask[pixel] = mask[pixel + 1] = mask[pixel + 2] = 255;
            mask[pixel + 3] = x == 1 || x == 2 ? 0 : 255;
        }
    }
    material::TextureDesc texture_desc = material::texture_2d_desc(4, 4, PixelFormat.RGBA8_UNORM);
    texture_desc.generate_mips = false;
    TextureId texture = fixture.assets.add_texture(texture_desc, mask[..])!!;
    Material* edited = &fixture.assets.material(material).data;
    edited.common.alpha_mode = AlphaMode.MASK;
    edited.standard.base_color_map = material::texture_slot(texture);
    fixture.assets.mark_material_dirty(material);
    Impostor masked = fixture.renderer.bake_impostor(&target.scene, target.mesh, desc)!!;
    char[] solid = fixture.assets.texture(opaque.atlas).pixels;
    char[] cutout = fixture.assets.texture(masked.atlas).pixels;
    char[][2] atlases = { solid, cutout };
    uint solid_count;
    uint cutout_count;
    for (usz pixel = 3; pixel < solid.len / 2; pixel += 4) {
        if (solid[pixel]) solid_count++;
        if (cutout[pixel]) cutout_count++;
        assert(cutout[pixel] == 0 || cutout[pixel] == 255);
        foreach (pixels : atlases) {
            if (!pixels[pixel]) continue;
            usz packed = pixel - 3 + pixels.len / 2;
            assert(math::abs((int)pixels[packed + 2] - 32) <= 1);
            Vec2 encoded = { (float)pixels[packed], (float)pixels[packed + 1] };
            Vec3 normal = math::abs(render::decode_octahedral(encoded * (2.0f / 255) - 1));
            assert(math::max(normal.x, math::max(normal.y, normal.z)) >= math::cos(math::deg_to_rad(2.0f)));
        }
    }
    assert(cutout_count > 0 && cutout_count < solid_count * 3 / 4);
    check_validation(&fixture.renderer);
}

fn void test_failed_bake_releases_resources() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        Fixture fixture;
        create_fixture(&tracker, &fixture)!!;
        defer destroy_fixture(&fixture);
        StandardParams surface = material::STANDARD_PARAMS_DEFAULT;
        surface.metallic = 0;
        MaterialId material = fixture.assets.add_material(material::standard(surface))!!;
        DeformedScene target = create_single_box_scene(&fixture, fixture.box, material, false)!!;
        defer scene::destroy_scene(&target.scene);
        ImpostorDesc desc = { .frames_per_side = 2, .cell_size = 8 };
        uint views = fixture.renderer.views.free_count;
        uint targets = fixture.renderer.targets.free_count;
        uint textures = fixture.assets.textures.free_count;
        Material* edited = &fixture.assets.material(material).data;
        Material supported = *edited;
        Material[5] unsupported = { supported, supported, supported, supported, material::basic() };
        unsupported[0].common.alpha_mode = AlphaMode.BLEND;
        unsupported[1].standard.metallic = 1;
        unsupported[2].standard.emissive = { 1, 0, 0 };
        unsupported[3].kind = MaterialKind.CUSTOM;
        foreach (value : unsupported) {
            *edited = value;
            assert(@catch(fixture.renderer.bake_impostor(&target.scene, target.mesh, desc)) == c3d::UNSUPPORTED);
            assert(fixture.renderer.views.free_count == views && fixture.renderer.targets.free_count == targets);
            assert(fixture.assets.textures.free_count == textures);
        }
        *edited = supported;
        Mesh* mesh = target.scene.get(target.mesh, Mesh);
        mesh.geometry = fixture.deformed_box;
        assert(@catch(fixture.renderer.bake_impostor(&target.scene, target.mesh, desc)) == c3d::UNSUPPORTED);
        mesh.geometry = fixture.box;
        Impostor first = fixture.renderer.bake_impostor(
            scene: &target.scene,
            subject: target.mesh,
            desc: desc,
            key: "baked_surface",
        )!!;
        assert(@catch(fixture.renderer.bake_impostor(
            scene: &target.scene,
            subject: target.mesh,
            desc: desc,
            key: "baked_surface",
        )) == c3d::INVALID_ARGUMENT);
        TextureId last;
        while (fixture.assets.textures.free_count) {
            last = fixture.assets.add_texture_empty({ .width = 1, .height = 1, .format = PixelFormat.RGBA8_UNORM })!!;
        }
        assert(@catch(fixture.renderer.bake_impostor(&target.scene, target.mesh, desc)) == c3d::CAPACITY_EXCEEDED);
        assert(fixture.renderer.views.free_count == views && fixture.renderer.targets.free_count == targets);
        fixture.assets.remove_texture(last);
        Impostor second = fixture.renderer.bake_impostor(&target.scene, target.mesh, desc)!!;
        assert(!c3d::same_id(first.atlas, second.atlas));
        check_validation(&fixture.renderer);
    }
    assert(tracker.allocated() == 0);
}
