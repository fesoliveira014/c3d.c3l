module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::debug;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::render @public;
import c3d::scene;
import c3d::shader;
import gpu;
import std::io;
import std::math;

const Vec3 DISTANT_OFFSET @private = { 65536, 0, 65536 };
const Vec3 REFERENCE_CROSSING @private = { 256, 0, -256 };
const uint RELATIVE_PIXEL_BYTES @private = TARGET_SIZE * TARGET_SIZE * 4;

fn void? render_relative_pair(
    Fixture* fixture,
    DeformedScene* target,
    Vec3 reference,
    bool reversed = false,
    bool trace_first = false,
) @private {
    Renderer* renderer = &fixture.renderer;
    target.scene.update_world();
    renderer.begin_frame({ .time = 1.25, .delta = 1.0f / 60, .reference_position = reference })!;
    defer catch render::abort_frame(renderer);
    if (trace_first) {
        renderer.prepare_scene_trace(&target.scene, TraceKind.SOFTWARE)!;
        assert(renderer.scene_trace.origin == render::frame_origin_for(reference));
    }
    ViewId[2] views = { fixture.display_view, fixture.second_view };
    for (uint index = 0; index < 2; index++) {
        ViewId view = views[reversed ? 1 - index : index];
        renderer.render_view(&target.scene, target.camera, view)!;
        renderer.finish_view(view)!;
    }
    return renderer.end_frame();
}

fn void test_relative_first_frame_and_view_order_preserve_raster_output() @test {
    Fixture fixture;
    create_fixture(allocator: mem, fixture: &fixture, max_shadow_layers: 4)!!;
    defer destroy_fixture(&fixture);
    print_adapter(&fixture);
    Renderer* renderer = &fixture.renderer;
    // Each view records its own shadow set, so reversing the order still compares two recordings.
    ViewDesc second = renderer.views.get(fixture.second_view).desc;
    second.share_shadows = false;
    render::configure_view(renderer, fixture.second_view, second)!!;
    StandardParams params = material::STANDARD_PARAMS_DEFAULT;
    params.base_color = { 0.25f, 0.5f, 0.75f, 1 };
    MaterialId matte = fixture.assets.add_material(material::standard(params))!!;
    DeformedScene target = create_single_box_scene(
        fixture: &fixture,
        geometry: fixture.box,
        material: matte,
        sunlit: true,
    )!!;
    defer scene::destroy_scene(&target.scene);
    Node* ground = target.scene.add_mesh(fixture.box, matte)!!;
    ground.local.position = { 0, -1, 0 };
    ground.local.scale = { 8, 0.25f, 8 };
    target.scene.@each(Light; Entity entity, Light* light) {
        light.shadow.cascades = 2;
        target.scene.node(entity).local.rotation = maths::look_rotation({ -1, -2, -1 }, { 0, 1, 0 });
    };
    char[RELATIVE_PIXEL_BYTES] reference_pixels;
    char[RELATIVE_PIXEL_BYTES] found;
    for (uint variant = 0; variant < 6; variant++) {
        ViewDesc desc = renderer.views.get(fixture.display_view).desc;
        desc.shading = variant & 1 ? ShadingPath.DEFERRED : ShadingPath.FORWARD;
        desc.post.anti_aliasing = AntiAliasing.NONE;
        render::configure_view(renderer, fixture.display_view, desc)!!;
        target.scene.@each(Light; Entity entity, Light* light) {
            light.shadow.cascade_blend = variant & 2 ? 0.1f : 0;
            light.shadow.enabled = variant < 4;
        };
        target.scene.root.local.position = {};
        render_relative_pair(
            fixture: &fixture,
            target: &target,
            reference: {},
            trace_first: true,
        )!!;
        renderer.read_render_target(fixture.ldr_target, reference_pixels[..])!!;
        target.scene.root.local.position = DISTANT_OFFSET;
        render_relative_pair(
            fixture: &fixture,
            target: &target,
            reference: DISTANT_OFFSET,
            reversed: true,
            trace_first: true,
        )!!;
        renderer.read_render_target(fixture.ldr_target, found[..])!!;
        uint maximum;
        ulong total;
        foreach (index, value : found) {
            uint difference = (uint)math::abs((int)value - (int)reference_pixels[index]);
            maximum = math::max(maximum, difference);
            total += difference;
        }
        io::printfn("Translated shadow raster variant=%d max_byte_error=%d mean_byte_error=%.6f",
            variant, maximum, (double)total / found.len);
        // A common physical translation changes the phase of the world-fixed shadow lattice.
        assert(variant < 4 ? maximum <= 12 && total <= (ulong)found.len : maximum == 0);
        reference_pixels = found;
        render_relative_pair(&fixture, &target, DISTANT_OFFSET)!!;
        renderer.read_render_target(fixture.ldr_target, found[..])!!;
        assert(mem::equals(&found, &reference_pixels, found.len));
        render_relative_pair(&fixture, &target, DISTANT_OFFSET + REFERENCE_CROSSING)!!;
        renderer.read_render_target(fixture.ldr_target, found[..])!!;
        maximum = 0;
        foreach (index, value : found) {
            maximum = math::max(maximum, (uint)math::abs((int)value - (int)reference_pixels[index]));
        }
        io::printfn("Reference-only shadow raster variant=%d max_byte_error=%d", variant, maximum);
        assert(maximum <= 1);
    }
    Vec3[3] invalid = { { float::nan, 0, 0 }, { 0, float::inf, 0 }, { 0, 0, -float::inf } };
    foreach (reference : invalid) {
        if (catch excuse = renderer.begin_frame({ .reference_position = reference })) {
            assert(excuse == c3d::INVALID_ARGUMENT && !renderer.frame_open);
        } else {
            assert(false, "nonfinite frame reference accepted");
        }
    }
    render_relative_pair(&fixture, &target, DISTANT_OFFSET)!!;
    renderer.render_to(
        scene: &target.scene,
        camera_node: target.camera,
        target: fixture.ldr_target,
        color: OutputMode.DISPLAY_LDR,
        info: { .reference_position = DISTANT_OFFSET },
    )!!;
    assert(renderer.frame_origin == DISTANT_OFFSET && !renderer.frame_open);
    check_validation(renderer);
}

fn void test_relative_trace_refreshes_closed_preparation_and_preserves_hits() @test {
    Fixture fixture;
    create_fixture(mem, &fixture, ray_queries: true)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    TraceScene trace;
    create_trace_scene(&fixture, &trace)!!;
    defer destroy_trace_scene(&fixture, &trace);
    TraceGridResult[] reference = mem::new_array(TraceGridResult, TRACE_GRID_SIZE * TRACE_GRID_SIZE);
    defer free(reference);
    TraceGridResult[] found = mem::new_array(TraceGridResult, reference.len);
    defer free(found);
    for (uint mode = 0; mode < 2; mode++) {
        if (mode && !renderer.caps.ray_queries.enabled) {
            io::printn("SKIP hardware trace: ray queries unavailable");
            continue;
        }
        TraceKind kind = mode ? TraceKind.HARDWARE : TraceKind.SOFTWARE;
        trace.scene.root.local.position = {};
        trace.scene.update_world();
        trace_grid(
            fixture: &fixture,
            trace: &trace,
            results: reference,
            kind: kind,
        )!!;
        trace.scene.root.local.position = DISTANT_OFFSET;
        trace.scene.update_world();
        renderer.prepare_scene_trace(&trace.scene, kind)!!;
        assert(renderer.scene_trace.origin == (Vec3){});
        for (uint crossing = 0; crossing < 2; crossing++) {
            Vec3 origin = DISTANT_OFFSET + (crossing ? REFERENCE_CROSSING : (Vec3){});
            trace_grid(
                fixture: &fixture,
                trace: &trace,
                results: found,
                kind: kind,
                info: { .reference_position = origin },
                world_offset: DISTANT_OFFSET,
            )!!;
            assert(renderer.scene_trace.origin == origin);
            foreach (index, expected : reference) {
                assert(found[index].hit == expected.hit);
                if (!expected.hit) continue;
                assert(math::abs(found[index].t - expected.t) < TRACE_DISTANCE_TOLERANCE);
                assert(found[index].primitive == expected.primitive);
            }
        }
    }
    check_validation(renderer);
}

fn void test_relative_path_accumulation_resets_then_continues() @test {
    Fixture fixture;
    create_fixture(mem, &fixture, ray_tracing_pipelines: true)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    if (!renderer.caps.ray_tracing_pipelines.enabled) {
        io::printn("SKIP path accumulation: ray tracing pipelines unavailable");
        return;
    }
    PathScene target = create_path_scene(&fixture, FRONT_POSE)!!;
    defer scene::destroy_scene(&target.scene);
    MaterialId material = fixture.assets.add_material(material::basic({ .color = BASIC_COLOR }))!!;
    Node* box = target.scene.add_mesh(fixture.box, material)!!;
    box.local.position = { 0, 0, -3 };
    target.scene.root.local.position = DISTANT_OFFSET;
    target.scene.update_world();
    RenderTargetId output = float_target(&fixture)!!;
    ViewId view = create_path_view(&fixture, output, { .max_bounces = 2, .samples_per_frame = 1 })!!;
    uint[4] expected = { 1, 2, 1, 2 };
    foreach (frame, samples : expected) {
        Vec3 origin = DISTANT_OFFSET + (frame >= 2 ? REFERENCE_CROSSING : (Vec3){});
        renderer.begin_frame({ .reference_position = origin })!!;
        renderer.prepare_scene_trace(&target.scene, TraceKind.HARDWARE)!!;
        renderer.render_view(&target.scene, target.camera, view)!!;
        renderer.finish_view(view)!!;
        renderer.end_frame()!!;
        assert(renderer.views.get(view).history.accumulated_samples == samples);
        Vec4[] pixels = read_float_target(&fixture, output)!!;
        defer free(pixels);
        assert(near_rgb(centre_texel(pixels), BASIC_COLOR.xyz, EXACT_TOLERANCE));
    }
    check_validation(renderer);
}

fn void test_relative_probe_updates_keep_partial_sweep_and_atlas_storage() @test {
    foreach (hardware : TRACE_KINDS) {
        Fixture fixture;
        create_fixture(mem, &fixture, ray_queries: hardware)!!;
        defer destroy_fixture(&fixture);
        ProbeRoom room = create_probe_room(&fixture)!!;
        defer scene::destroy_scene(&room.scene);
        room.scene.root.local.position = DISTANT_OFFSET;
        room.scene.update_world();
        ProbeVolume* volume = room.scene.get(room.volume, ProbeVolume);
        volume.update.probes_per_frame = 4;
        Renderer* renderer = &fixture.renderer;
        gpu::TextureHandle atlas;
        Vec3 absolute = room.volume.world_position() - volume.half_extents;
        for (uint frame = 0; frame < 3; frame++) {
            Vec3 origin = DISTANT_OFFSET + (frame ? REFERENCE_CROSSING : (Vec3){});
            renderer.begin_frame({ .reference_position = origin })!!;
            renderer.render_view(&room.scene, room.camera, fixture.view)!!;
            renderer.finish_view(fixture.view)!!;
            renderer.end_frame()!!;
            ProbeVolumeRes* mirror = mirror_of(&fixture, &room.scene, room.volume);
            assert(mirror.fill.cursor == 4 * (frame + 1));
            assert(mirror.fill.traced_origin == absolute && !mirror.fill.scene_swept);
            if (frame == 0) {
                atlas = mirror.irradiance.texture;
            } else {
                assert(mirror.irradiance.texture == atlas);
            }
        }
        @pool() {
            ProbeVolumeRes* mirror = mirror_of(&fixture, &room.scene, room.volume);
            assert_finite(read_atlas(&fixture, &mirror.irradiance)!!);
            assert_finite(read_atlas(&fixture, &mirror.visibility)!!);
        };
        check_validation(renderer);
    }
}

fn void test_relative_fog_sky_clip_and_scene_reads_keep_their_coordinates() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    FogScene target = create_fog_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    add_fog(&target, TEST_FOG)!!;
    add_sun(&target, (Vec3){ 0, 1, 1 }.normalize(), 2)!!;
    add_facing_plane(&target, add_unlit(&fixture, BED_COLOR)!!, BED_DISTANCE)!!;
    ShaderId reader = add_fog_reader(&fixture, {})!!;
    add_facing_plane(&target, add_reader_material(&fixture, reader)!!, READER_DISTANCE)!!;
    target.scene.root.local.position = DISTANT_OFFSET;
    target.scene.update_world();
    for (uint mode = 0; mode < 2; mode++) {
        FogView view = create_fog_view(
            fixture: &fixture,
            shading: mode ? ShadingPath.DEFERRED : ShadingPath.FORWARD,
            clip_plane: { .normal = { 0, 0, -1 }, .d = DISTANT_OFFSET.z - 1 },
        )!!;
        defer destroy_fog_view(&fixture, &view);
        Vec4[] reference;
        defer free(reference);
        for (uint frame = 0; frame < 3; frame++) {
            Vec3 origin = DISTANT_OFFSET + (frame == 2 ? (Vec3){ 256, 256, -256 } : (Vec3){});
            fixture.renderer.begin_frame({ .time = 1.25, .reference_position = origin })!!;
            fixture.renderer.render_view(&target.scene, target.camera, view.view)!!;
            fixture.renderer.finish_view(view.view)!!;
            fixture.renderer.end_frame()!!;
            if (frame == 0) continue;
            if (frame == 1) {
                reference = read_float_target(&fixture, view.target)!!;
            } else {
                assert(fixture.renderer.stats.sky_regenerations == 0);
                Vec4[] found = read_float_target(&fixture, view.target)!!;
                defer free(found);
                foreach (index, expected : reference) check_rgb_close(found[index], expected.xyz, "reference change");
            }
        }
    }
    check_validation(&fixture.renderer);
}

fn void test_relative_skin_morph_and_published_stages_match_near_origin() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    fill_frame(&fixture, fixture.storage_texture, WARM)!!;
    for (uint kind = 0; kind < 2; kind++) {
        DeformedScene target;
        if (kind == 0) {
            target = create_deformed_scene(&fixture, { 0.25f, 0, 0 }, 0.5f)!!;
        } else {
            PublishedScene published = create_published_scene(&fixture)!!;
            published_replace(&fixture, published.shader, false)!!;
            target = published.target;
        }
        defer scene::destroy_scene(&target.scene);
        char[RELATIVE_PIXEL_BYTES] reference;
        char[RELATIVE_PIXEL_BYTES] found;
        render_relative_pair(&fixture, &target, {})!!;
        fixture.renderer.read_render_target(fixture.ldr_target, reference[..])!!;
        target.scene.root.local.position = DISTANT_OFFSET;
        render_relative_pair(&fixture, &target, DISTANT_OFFSET)!!;
        fixture.renderer.read_render_target(fixture.ldr_target, found[..])!!;
        assert(mem::equals(&reference, &found, found.len));
    }
    check_validation(&fixture.renderer);
}

fn void test_relative_debug_lines_match_near_origin_without_mutating_endpoints() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    DeformedScene target = create_single_box_scene(
        fixture: &fixture,
        geometry: fixture.box,
        material: fixture.plain,
        sunlit: false,
    )!!;
    defer scene::destroy_scene(&target.scene);
    DebugDraw draw = debug::create_debug_draw(mem, 16);
    defer debug::destroy_debug_draw(&draw);
    char[RELATIVE_PIXEL_BYTES] reference;
    char[RELATIVE_PIXEL_BYTES] found;
    for (uint step = 0; step < 3; step++) {
        Vec3 offset = step ? DISTANT_OFFSET : (Vec3){};
        target.scene.root.local.position = offset;
        target.scene.update_world();
        draw.clear();
        Vec3 start = offset + (Vec3){ -0.25f, 0.25f, 0.75f };
        draw.line(from: start, to: offset + (Vec3){ 0.25f, -0.25f, 0.75f }, rgba: 0xff00ff00);
        fixture.renderer.begin_frame({ .reference_position = offset + (step == 2 ? REFERENCE_CROSSING : (Vec3){}) })!!;
        fixture.renderer.render_view(
            scene: &target.scene,
            camera_node: target.camera,
            view: fixture.display_view,
            debug: &draw,
        )!!;
        fixture.renderer.finish_view(fixture.display_view)!!;
        fixture.renderer.end_frame()!!;
        assert(draw.vertices.array_view()[0].position == start);
        fixture.renderer.read_render_target(fixture.ldr_target, found[..])!!;
        if (step == 0) {
            reference = found;
        } else {
            assert(mem::equals(&reference, &found, found.len));
        }
    }
    check_validation(&fixture.renderer);
}

fn Vec4[]? relative_effects_pixels(bool hardware, uint effect, uint variant) @private {
    Fixture fixture;
    create_fixture(mem, &fixture, ray_queries: hardware)!;
    defer destroy_fixture(&fixture);
    MirrorScene target = create_mirror_scene(&fixture, true)!;
    defer scene::destroy_scene(&target.scene);
    target.scene.root.local.position = DISTANT_OFFSET;
    target.scene.@each(Light; Entity entity, Light* light) {
        light.shadow.enabled = true;
        light.shadow.ray_traced = true;
    };
    target.scene.update_world();
    RenderTargetId output = float_target(&fixture)!;
    ViewDesc desc = render::texture_view_desc(output);
    desc.shading = ShadingPath.DEFERRED;
    desc.post.anti_aliasing = effect ? AntiAliasing.TAA : AntiAliasing.NONE;
    desc.post.motion_blur = effect > 0;
    if (effect == 2) desc.screen_space_gi = render::SCREEN_SPACE_GI_DEFAULT;
    desc.ambient_occlusion = render::AMBIENT_OCCLUSION_DEFAULT;
    desc.ambient_occlusion.kind = AoKind.RAY_TRACED;
    desc.ray_tracing.shadows = true;
    desc.ray_tracing.reflections = true;
    ViewId view = render::create_view(&fixture.renderer, desc)!;
    LodVelocityProbe probe = create_impostor_probe(&fixture)!;
    defer free_lod_readback(&fixture.renderer, probe.readback);
    for (uint frame = 0; frame < 8; frame++) {
        Vec3 origin = DISTANT_OFFSET + (variant && frame >= 4 ? REFERENCE_CROSSING : (Vec3){});
        fixture.renderer.begin_frame({ .time = 1.25, .delta = 1.0f / 60, .reference_position = origin })!;
        defer catch render::abort_frame(&fixture.renderer);
        fixture.renderer.render_view(&target.scene, target.camera, view)!;
        if (effect && frame == 7) record_lod_target(&fixture, &probe, &fixture.renderer.views.get(view).velocity)!;
        fixture.renderer.finish_view(view)!;
        fixture.renderer.end_frame()!;
    }
    Vec4[] pixels = read_float_target(&fixture, output)!;
    defer catch free(pixels);
    if (effect) {
        gpu::invalidate_mapped_span(&fixture.renderer.device, probe.readback.span)!;
        float maximum_velocity;
        foreach (velocity : ((Vec4*)probe.readback.bytes.ptr)[:PATH_TARGET_SIZE * PATH_TARGET_SIZE]) {
            maximum_velocity = math::max(maximum_velocity, math::abs(velocity.x), math::abs(velocity.y));
        }
        assert(maximum_velocity < 0.000001f);
    }
    check_validation(&fixture.renderer);
    return pixels;
}

fn void test_relative_traced_and_temporal_effects_match_completed_views() @test {
    for (uint effect = 0; effect < 3; effect++) {
        foreach (hardware : TRACE_KINDS) {
            Vec4[] reference = relative_effects_pixels(hardware, effect, 0)!!;
            defer free(reference);
            Vec4[] found = relative_effects_pixels(hardware, effect, 1)!!;
            defer free(found);
            float maximum;
            foreach (index, expected : reference) {
                for (uint channel = 0; channel < 3; channel++) {
                    maximum = math::max(maximum, math::abs(found[index][channel] - expected[channel]));
                }
            }
            io::printfn("relative effects case=%d hardware=%s maximum=%f", effect, hardware, maximum);
            assert(maximum <= 0.003f);
        }
    }
}

fn void test_relative_instance_uploads_share_views_and_recover_after_abort() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    DeformedScene target = create_single_box_scene(
        fixture: &fixture,
        geometry: fixture.box,
        material: fixture.plain,
        sunlit: false,
    )!!;
    defer scene::destroy_scene(&target.scene);
    target.mesh.visible = false;
    Node* batch_node = add_parity_batch(&target, fixture.box, fixture.plain, 0)!!;
    target.scene.root.local.position = DISTANT_OFFSET;
    Renderer* renderer = &fixture.renderer;
    for (uint warm = 0; warm < render::FRAMES_IN_FLIGHT + 1; warm++) {
        render_relative_pair(&fixture, &target, DISTANT_OFFSET)!!;
    }
    Uploads steady = frame_uploads(renderer);
    render_relative_pair(&fixture, &target, DISTANT_OFFSET + (Vec3){ 1, 0, 1 })!!;
    check_uploads(renderer, steady);
    InstancedMesh* batch = target.scene.get(batch_node, InstancedMesh);
    Uploads crossing = { .count = steady.count + 1, .bytes = steady.bytes + batch.count * (uint)InstanceGpu::size };
    for (uint recovery = 0; recovery < 2; recovery++) {
        render_relative_pair(&fixture, &target, DISTANT_OFFSET)!!;
        renderer.begin_frame({ .reference_position = DISTANT_OFFSET + REFERENCE_CROSSING })!!;
        renderer.render_view(&target.scene, target.camera, fixture.display_view)!!;
        renderer.finish_view(fixture.display_view)!!;
        render::abort_frame(renderer);
        Vec3 resume = recovery == 0 ? DISTANT_OFFSET : DISTANT_OFFSET + REFERENCE_CROSSING;
        render_relative_pair(&fixture, &target, resume)!!;
        // Aborting invalidates the material stamp alongside the resident record.
        check_uploads(renderer, {
            .count = crossing.count + 1,
            .bytes = crossing.bytes + (uint)render::MATERIAL_STRIDE,
        });
        render_relative_pair(&fixture, &target, resume)!!;
        check_uploads(renderer, steady);
    }
    render_relative_pair(&fixture, &target, DISTANT_OFFSET)!!;
    check_uploads(renderer, crossing);
    check_validation(renderer);
}

fn void test_relative_billboards_keep_facing_and_upload_once_per_crossing() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Billboard[2] values = { scene::BILLBOARD_DEFAULT, scene::BILLBOARD_DEFAULT };
    values[0].position.x = -0.75f;
    values[1].position.x = 0.75f;
    values[1].direction = { 1, 0, 0 };
    for (uint mode = 0; mode < 2; mode++) {
        BillboardFacing facing = mode ? BillboardFacing.DIRECTIONAL : BillboardFacing.CAMERA;
        BillboardScene target = create_billboard_scene(&fixture, values[..], facing)!!;
        defer destroy_billboard_scene(&fixture, &target);
        render_billboard_frames(fixture: &fixture, target: &target, both_views: true)!!;
        Vec4[][2] reference;
        foreach (index, image : target.targets) reference[index] = read_float_target(&fixture, image)!!;
        defer foreach (pixels : reference) free(pixels);
        target.scene.root.local.position = DISTANT_OFFSET;
        target.scene.update_world();
        for (uint step = 0; step < 3; step++) {
            Vec3 origin = DISTANT_OFFSET + (step ? REFERENCE_CROSSING : (Vec3){});
            fixture.renderer.begin_frame({ .reference_position = origin })!!;
            foreach (index, view : target.views) {
                fixture.renderer.render_view(&target.scene, target.cameras[index], view)!!;
                fixture.renderer.finish_view(view)!!;
            }
            fixture.renderer.end_frame()!!;
            assert(fixture.renderer.stats.uploads == (step == 2 ? 0 : 1));
            foreach (index, image : target.targets) {
                Vec4[] found = read_float_target(&fixture, image)!!;
                defer free(found);
                foreach (pixel, expected : reference[index]) check_billboard_pixel(found[pixel], expected);
            }
        }
    }
    check_validation(&fixture.renderer);
}

fn void test_relative_lod_history_keeps_static_velocity_across_reference_changes() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    gpu::AllocationDesc desc = {
        .size = TARGET_SIZE * TARGET_SIZE * Vec4::size,
        .alignment = render::STREAM_ALIGNMENT,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access = { .graphics },
        .debug_name = "relative_velocity_readback",
    };
    gpu::MappedGpuSpan readback = gpu::allocate_mapped_memory(&renderer.device, &desc)!!;
    defer free_lod_readback(renderer, readback);
    LodVelocityProbe probe = {
        .readback = readback,
        .output = renderer.create_buffer({ .size = desc.size, .debug_name = "relative_velocity_output" })!!,
        .shader = add_compute_shader(&fixture, (String)PROBE_READBACK_SOURCE[..])!!,
    };
    for (uint mode = 0; mode < 5; mode++) {
        DeformedScene target;
        if (mode == 0) {
            target = create_single_box_scene(
                fixture: &fixture,
                geometry: fixture.box,
                material: fixture.plain,
                sunlit: false,
            )!!;
        } else if (mode < 3) {
            target = create_lod_scene(&fixture, mode == 1)!!;
        } else {
            target = create_impostor_scene(&fixture, mode == 4)!!;
            target.camera.local.position = { 0, 0, 5 };
        }
        defer scene::destroy_scene(&target.scene);
        if (mode == 2) {
            target.scene.resize_lod_instances(target.mesh, 1)!!;
            target.scene.get(target.mesh, LodGroup).state.transforms[0] = maths::TRANSFORM_IDENTITY;
            target.scene.mark_lod_instances_dirty(target.mesh);
        }
        if (mode) {
            LodGroupState* state = target.scene.get(target.mesh, LodGroup).state;
            state.effects.sway = { .direction = { 3, 0, 4 }, .amplitude = 0.125f, .frequency = 0.5f, .wavelength = 16 };
            state.effects.fade = { .start = 10, .end = 20 };
        }
        target.scene.root.local.position = DISTANT_OFFSET;
        target.scene.update_world();
        enable_taa(fixture: &fixture, view: fixture.view, motion_blur: true)!!;
        enable_taa(&fixture, fixture.second_view)!!;
        for (uint frame = 0; frame < 9; frame++) {
            if (frame == 5) renderer.views.get(fixture.view).history.valid = false;
            if (frame == 7) {
                target.mesh.local.position.x += 0.125f;
                target.scene.update_world();
            }
            Vec3 origin = DISTANT_OFFSET + (frame >= 3 ? REFERENCE_CROSSING : (Vec3){});
            renderer.begin_frame({ .time = 1.25, .delta = 1.0f / 60, .reference_position = origin })!!;
            renderer.render_view(&target.scene, target.camera, fixture.view)!!;
            sample(&fixture, render::read_view_color(fixture.view))!!;
            record_readback(&fixture)!!;
            record_lod_target(&fixture, &probe, &renderer.views.get(fixture.view).velocity)!!;
            renderer.finish_view(fixture.view)!!;
            if (frame % 2 == 0) {
                renderer.render_view(&target.scene, target.camera, fixture.second_view)!!;
                renderer.finish_view(fixture.second_view)!!;
            }
            renderer.end_frame()!!;
            render::wait_frames(renderer)!!;
            uint color = read_pixel(&fixture);
            assert((color & 0xff) > 10 || ((color >> 8) & 0xff) > 10 || ((color >> 16) & 0xff) > 10);
            if (frame == 3) assert(renderer.stats.uploads == (mode == 2 || mode == 4 ? 1 : 0));
            gpu::invalidate_mapped_span(&renderer.device, readback.span)!!;
            if (frame == 0 || frame == 5) continue;
            Vec4 velocity = lod_velocity_pixel(readback, CENTER_UV);
            if (frame == 7) {
                assert(math::abs(velocity.x) > 0.001f || (mode >= 3 && velocity.w == 1));
            } else {
                assert(math::abs(velocity.x) < 0.00001f && math::abs(velocity.y) < 0.00001f);
                assert(velocity.w == 0);
            }
            assert(renderer.views.get(fixture.view).history.origin == origin);
        }
    }
    check_validation(renderer);
}

const Vec3 REBASE_BASE @private = { 32768, 0, 32768 };
const Vec3 REBASE_SHIFT @private = { 16384, 0, 16384 };
const uint REBASE_WARM_FRAMES @private = 4;
const float REBASE_VELOCITY_LIMIT @private = 0.000001f;
const Vec3 REBASE_CLIP_KEPT @private = { 0.4f, 0, 0.5f };
const Vec3 REBASE_CLIP_CLIPPED @private = { -0.3f, 0, 0.5f };
const float REBASE_CLIP_CUT @private = 0.25f; // inside the unit box, so one face is cut

struct RebaseResult @private {
    char[RELATIVE_PIXEL_BYTES] pixels;
    float                      maximum_velocity;
    Uploads                    steady_uploads;
    Uploads                    uploads;
    uint                       tlas_builds;
    ulong                      steady_revision;
    ulong                      revision;
}

fn void shift_scene_protocol(Renderer* renderer, Scene* scene, Vec3 offset) @private {
    scene.shift_origin(offset);
    scene.update_world();
    renderer.shift_origin(scene, offset);
}

fn LodVelocityProbe? create_rebase_probe(Fixture* fixture) @private {
    gpu::AllocationDesc allocation = {
        .size = TARGET_SIZE * TARGET_SIZE * Vec4::size,
        .alignment = render::STREAM_ALIGNMENT,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access = { .graphics },
        .debug_name = "rebase_velocity_readback",
    };
    return {
        .readback = gpu::allocate_mapped_memory(&fixture.renderer.device, &allocation)!,
        .output = fixture.renderer.create_buffer({ .size = allocation.size, .debug_name = "rebase_velocity_output" })!,
        .shader = add_compute_shader(fixture, (String)PROBE_READBACK_SOURCE[..])!,
    };
}

fn void? render_rebase_frame(
    Fixture* fixture,
    DeformedScene* target,
    TraceKind kind,
    LodVelocityProbe* probe = null,
) @private {
    Renderer* renderer = &fixture.renderer;
    target.scene.update_world();
    renderer.begin_frame({
        .time = 1.25,
        .delta = 1.0f / 60,
        .reference_position = target.camera.world_position(),
    })!;
    defer catch render::abort_frame(renderer);
    renderer.prepare_scene_trace(&target.scene, kind)!;
    renderer.render_view(&target.scene, target.camera, fixture.display_view)!;
    if (probe) record_lod_target(fixture, probe, &renderer.views.get(fixture.display_view).velocity)!;
    renderer.finish_view(fixture.display_view)!;
    return renderer.end_frame();
}

fn RebaseResult? render_rebase_sequence(bool shifted, bool hardware) @private {
    Fixture fixture;
    create_fixture(mem, &fixture, ray_queries: hardware)!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    DeformedScene target = create_single_box_scene(
        fixture: &fixture,
        geometry: fixture.box,
        material: fixture.plain,
        sunlit: false,
    )!;
    defer scene::destroy_scene(&target.scene);
    Node* batch = add_parity_batch(&target, fixture.box, fixture.plain, 0)!;
    Vec3 base = shifted ? REBASE_BASE : REBASE_BASE - REBASE_SHIFT;
    target.mesh.local.position = base;
    batch.local.position = base + (Vec3){ 2, 0, 0 };
    target.camera.local.position = base + (Vec3){ 1, 0, 6 };
    enable_taa(&fixture, fixture.display_view)!;
    LodVelocityProbe probe = create_rebase_probe(&fixture)!;
    defer free_lod_readback(renderer, probe.readback);
    TraceKind kind = hardware ? TraceKind.HARDWARE : TraceKind.SOFTWARE;
    RebaseResult result;
    for (uint frame = 0; frame < REBASE_WARM_FRAMES; frame++) render_rebase_frame(&fixture, &target, kind)!;
    result.steady_uploads = frame_uploads(renderer);
    result.steady_revision = renderer.scene_trace.revision;
    if (shifted) shift_scene_protocol(renderer, &target.scene, REBASE_SHIFT);
    render_rebase_frame(&fixture, &target, kind, &probe)!;
    render::wait_frames(renderer)!;
    result.uploads = frame_uploads(renderer);
    result.tlas_builds = renderer.stats.tlas_builds;
    result.revision = renderer.scene_trace.revision;
    renderer.read_render_target(fixture.ldr_target, result.pixels[..])!;
    gpu::invalidate_mapped_span(&renderer.device, probe.readback.span)!;
    foreach (velocity : ((Vec4*)probe.readback.bytes.ptr)[:TARGET_SIZE * TARGET_SIZE]) {
        result.maximum_velocity = math::max(result.maximum_velocity, math::abs(velocity.x), math::abs(velocity.y));
    }
    check_validation(renderer);
    return result;
}

fn void check_path_accumulation_continues_across_a_shift() @private {
    Fixture fixture;
    create_fixture(mem, &fixture, ray_tracing_pipelines: true)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    if (!renderer.caps.ray_tracing_pipelines.enabled) {
        io::printn("SKIP path accumulation across a shift: ray tracing pipelines unavailable");
        return;
    }
    PathScene target = create_path_scene(&fixture, FRONT_POSE)!!;
    defer scene::destroy_scene(&target.scene);
    MaterialId material = fixture.assets.add_material(material::basic({ .color = BASIC_COLOR }))!!;
    Node* box = target.scene.add_mesh(fixture.box, material)!!;
    box.local.position = REBASE_BASE + (Vec3){ 0, 0, -3 };
    target.camera.local.position = REBASE_BASE;
    RenderTargetId output = float_target(&fixture)!!;
    ViewId view = create_path_view(&fixture, output, { .max_bounces = 2, .samples_per_frame = 1 })!!;
    uint[3] expected = { 1, 2, 3 };
    foreach (frame, samples : expected) {
        if (frame == 2) shift_scene_protocol(renderer, &target.scene, REBASE_SHIFT);
        target.scene.update_world();
        renderer.begin_frame({ .reference_position = target.camera.world_position() })!!;
        renderer.prepare_scene_trace(&target.scene, TraceKind.HARDWARE)!!;
        renderer.render_view(&target.scene, target.camera, view)!!;
        renderer.finish_view(view)!!;
        renderer.end_frame()!!;
        assert(renderer.views.get(view).history.accumulated_samples == samples);
        Vec4[] pixels = read_float_target(&fixture, output)!!;
        defer free(pixels);
        assert(near_rgb(centre_texel(pixels), BASIC_COLOR.xyz, EXACT_TOLERANCE));
    }
    check_validation(renderer);
}

fn void test_shifted_scene_renders_identically_and_keeps_history() @test {
    foreach (hardware : TRACE_KINDS) {
        RebaseResult reference = render_rebase_sequence(false, hardware)!!;
        RebaseResult found = render_rebase_sequence(true, hardware)!!;
        io::printfn("Rebased frame hardware=%s uploads=%d tlas_builds=%d velocity=%f",
            hardware, found.uploads.count, found.tlas_builds, found.maximum_velocity);
        assert(mem::equals(&found.pixels, &reference.pixels, found.pixels.len));
        assert(found.maximum_velocity < REBASE_VELOCITY_LIMIT);
        assert(reference.maximum_velocity < REBASE_VELOCITY_LIMIT);
        assert(found.uploads.count == found.steady_uploads.count && found.uploads.bytes == found.steady_uploads.bytes);
        assert(found.tlas_builds == 0);
        assert(found.revision == found.steady_revision);
    }
    check_path_accumulation_continues_across_a_shift();
}

fn void? read_rebased_clip_points(Fixture* fixture, ClipScene* clip, Vec3 base, uint[2]* pixels) @private {
    Renderer* renderer = &fixture.renderer;
    clip.scene.update_world();
    Vec3 reference = clip.camera.world_position();
    Vec3 origin = render::frame_origin_for(reference);
    Camera* camera = clip.scene.get(clip.camera, Camera);
    CameraMatrices matrices = camera::derive_matrices(
        *camera,
        maths::rebase(clip.camera.world, origin),
        { AO_TARGET_WIDTH, AO_TARGET_HEIGHT },
    );
    Vec3[2] points = { base + REBASE_CLIP_KEPT, base + REBASE_CLIP_CLIPPED };
    foreach (index, point : points) {
        renderer.begin_frame({ .reference_position = reference })!;
        defer catch render::abort_frame(renderer);
        renderer.render_view(&clip.scene, clip.camera, clip.view)!;
        sample(fixture, render::read_view_color(clip.view), projected_uv(&matrices, point - origin))!;
        record_readback(fixture)!;
        renderer.finish_view(clip.view)!;
        renderer.end_frame()!;
        (*pixels)[index] = read_pixel(fixture);
    }
}

fn void test_mirror_view_survives_a_shift() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    MaterialId red_material = add_matte_material(&fixture, RED)!!;
    ClipScene clip = create_clip_scene(&fixture, red_material)!!;
    defer scene::destroy_scene(&clip.scene);
    clip.buried.visible = false;
    clip.box.local.position += REBASE_BASE;
    clip.batch.local.position += REBASE_BASE;
    clip.camera.local.position += REBASE_BASE;
    AoView ao_view = create_clip_view(&fixture, RASTER_PATHS[1])!!;
    clip.view = ao_view.view;
    enable_taa(&fixture, clip.view)!!;
    Plane plane = { .normal = { 1, 0, 0 }, .d = -(REBASE_BASE.x + REBASE_CLIP_CUT) };
    set_clip_plane(&fixture, clip.view, plane)!!;

    uint[2] before;
    read_rebased_clip_points(&fixture, &clip, REBASE_BASE, &before)!!;
    check_dominant_channel(before[0], 0);
    assert(pixel_channel(before[1], 0) < DOMINANT_CHANNEL_MINIMUM);

    shift_scene_protocol(renderer, &clip.scene, REBASE_SHIFT);
    Plane shifted = renderer.views.get(clip.view).desc.clip_plane;
    assert(shifted.normal == plane.normal && shifted.d == plane.d + REBASE_SHIFT.x);
    uint[2] after;
    read_rebased_clip_points(&fixture, &clip, REBASE_BASE - REBASE_SHIFT, &after)!!;
    check_dominant_channel(after[0], 0);
    assert(pixel_channel(after[1], 0) < DOMINANT_CHANNEL_MINIMUM);
    check_validation(renderer);
}
