module c3d::render::acceptance;

import c3d;
import c3d::camera;
import c3d::light;
import c3d::maths;
import c3d::render @public;
import c3d::scene;
import c3d::shader;
import gpu;
import std::io;
import std::io::file;
import std::core::string;
import std::math;

struct ImageAtlasReadback @private {
    ComputeShaderId shader;
    BufferId output;
    gpu::MappedGpuSpan host;
    uint width;
    uint height;
}

fn LightGpu[] image_probe_lights(Renderer* renderer, Scene* scene) @private {
    LightCounts counts;
    LightExtraction extraction = render::extract_lights(
        allocator: tmem,
        scene: scene,
        frustum: null,
        view_layers: uint::max,
        capacity: renderer.max_lights,
        counts: &counts,
        atmosphere: null,
        altitude: 0,
        trace_shadows: true,
        origin: {},
    );
    assert(counts.dropped == 0);
    return extraction.lights;
}

fn void assert_probe_image_lights(Renderer* renderer, Scene* scene, LightGpu[] expected) @private {
    @pool() {
        LightGpu[] actual = image_probe_lights(renderer, scene);
        assert(actual.len == expected.len && renderer.frame_origin == (Vec3){});
        usz bytes = actual.len * LightGpu::size;
        char[] expected_bytes = ((char*)expected.ptr)[:bytes];
        char[] actual_bytes = ((char*)actual.ptr)[:bytes];
        foreach (index, value : expected_bytes) assert(actual_bytes[index] == value);
    };
}

fn ImageAtlasReadback? create_image_atlas_readback(Fixture* fixture) @private {
    Renderer* renderer = &fixture.renderer;
    uint[<2>] extent = render::probe_atlas_extent(ROOM_COUNTS, shader::PROBE_IRRADIANCE_CELL);
    usz bytes = (usz)extent.x * extent.y * Vec4::size;
    ImageAtlasReadback result = {
        .shader = add_compute_shader(fixture, (String)PROBE_READBACK_SOURCE[..])!,
        .output = renderer.create_buffer({ .size = bytes, .debug_name = "image_atlas_output" })!,
        .width = extent.x,
        .height = extent.y,
    };
    defer catch (void)renderer.destroy_buffer(result.output);
    gpu::AllocationDesc desc = {
        .size = bytes,
        .alignment = 16,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access = { .graphics },
        .debug_name = "image_atlas_readback",
    };
    result.host = gpu::allocate_mapped_memory(&renderer.device, &desc)!;
    return result;
}

fn void destroy_image_atlas_readback(Renderer* renderer, ImageAtlasReadback* readback) @private {
    render::wait_frames(renderer)!!;
    gpu::GpuAllocation allocation = readback.host.span.allocation();
    gpu::free_allocation(&renderer.device, &allocation)!!;
    renderer.destroy_buffer(readback.output)!!;
}

fn void? record_image_atlas(Renderer* renderer, ImageAtlasReadback* readback, Target* atlas) @private {
    assert(atlas.width == readback.width && atlas.height == readback.height);
    ProbeReadbackRoot root = {
        .output_address = renderer.buffer_address(readback.output),
        .atlas = atlas.view.index,
        .width = atlas.width,
        .height = atlas.height,
    };
    BufferId[1] writes = { readback.output };
    renderer.dispatch({
        .shader = readback.shader,
        .root = ((char*)&root)[:ProbeReadbackRoot::size],
        .groups = {
            (atlas.width + PROBE_READBACK_GROUP - 1) / PROBE_READBACK_GROUP,
            (atlas.height + PROBE_READBACK_GROUP - 1) / PROBE_READBACK_GROUP,
            1,
        },
        .writes = writes[..],
    })!;
    gpu::Barrier written = { .before = { .all }, .after = { .transfer } };
    gpu::cmd_barrier(&renderer.commands, &written)!;
    gpu::BufferCopyDesc copy = {
        .src = gpu::get_allocation_span(&renderer.device, renderer.buffers.get(readback.output).allocation)!,
        .dst = readback.host.span,
    };
    gpu::cmd_copy_buffer(&renderer.commands, &copy)!;
    gpu::Barrier host_read = { .before = { .transfer }, .after = { .host } };
    gpu::cmd_barrier(&renderer.commands, &host_read)!;
}

fn void? save_image_atlas(
    LightImageRun run,
    Renderer* renderer,
    ImageAtlasReadback* readback,
    String name,
) @private {
    ulong frame = renderer.frame_index;
    render::wait_frames(renderer)!;
    gpu::invalidate_mapped_span(&renderer.device, readback.host.span)!;
    assert(renderer.frame_index == frame);
    usz count = (usz)readback.width * readback.height;
    assert_finite(((Vec4*)readback.host.bytes.ptr)[:count]);
    String filename = string::tformat("%s_atlas_%s_%s.bin", name, run.repetition, frame);
    file::save(string::tformat("%s/%s", run.directory, filename), readback.host.bytes[:count * Vec4::size])!;
    io::printfn("image,%s,%s_atlas,rgba32f,%s,%s,%s,0,0,%s", filename, name,
        readback.width, readback.height, frame, renderer.stats.probe_rays);
    check_validation(renderer);
}

fn void? capture_probe_images(LightImageRun run) @private {
    foreach (ray_queries : TRACE_KINDS) {
        for (uint alternate = 0; alternate < 2; alternate++) {
            for (uint mixed = 0; mixed < 2; mixed++) {
                for (uint lamp_enabled = 0; lamp_enabled < 2; lamp_enabled++) {
                    @pool() {
                        Fixture fixture;
                        create_fixture(mem, &fixture, ray_queries: ray_queries)!;
                        defer destroy_fixture(&fixture);
                        ProbeRoom room = create_bounce_room(&fixture)!;
                        defer scene::destroy_scene(&room.scene);
                        room.lamp.visible = (bool)lamp_enabled;
                        room.volume.visible = true;
                        ProbeVolume* volume = room.scene.get(room.volume, ProbeVolume);
                        volume.update.rays_per_probe = 128;
                        volume.update.probes_per_frame = 0;
                        assert(volume.update.hysteresis == 0.5f);
                        if (alternate) room.camera.local.position = { 30, 1.5f, 1.2f };
                        if (mixed) add_irrelevant_image_lights(&room.scene)!;
                        room.scene.update_world();
                        if (alternate) {
                            CameraMatrices matrices = camera::derive_matrices(
                                *room.scene.get(room.camera, Camera), room.camera.world, { 64, 64 });
                            assert(!maths::frustum_intersects_sphere(&matrices.frustum, {
                                .center = room.lamp.world_position(), .radius = room.scene.get(room.lamp, Light).range,
                            }));
                        }
                        LightImageView image = create_light_image_view(
                            fixture: &fixture,
                            width: 64,
                            height: 64,
                            output: OutputMode.LINEAR_HDR,
                            shading: ShadingPath.FORWARD,
                        )!;
                        ImageAtlasReadback readback = create_image_atlas_readback(&fixture)!;
                        defer destroy_image_atlas_readback(&fixture.renderer, &readback);
                        String name = string::tformat("probe_%s_%s_%s_%s", ray_queries, alternate, mixed, lamp_enabled);
                        save_light_image_inputs(
                            run: run,
                            fixture: &fixture,
                            scene: &room.scene,
                            camera_node: room.camera,
                            image: image,
                            name: name,
                            traced: true,
                            probes: true,
                        )!;
                        fixture.renderer.prepare_scene(&room.scene)!;
                        Renderer* renderer = &fixture.renderer;
                        LightGpu[] expected_lights = image_probe_lights(renderer, &room.scene);
                        assert(expected_lights.len == (usz)(mixed * IMAGE_IRRELEVANT_LIGHTS + lamp_enabled));
                        for (uint update = 1; update <= 60; update++) {
                            bool capture = update == 1 || update == 30 || update == 60;
                            renderer.begin_frame({ .time = 0, .delta = 1.0f / 60 })!;
                            defer catch render::abort_frame(renderer);
                            assert_probe_image_lights(renderer, &room.scene, expected_lights);
                            renderer.render_view(&room.scene, room.camera, image.view)!;
                            ProbeVolumeRes* mirror = mirror_of(&fixture, &room.scene, room.volume);
                            assert(mirror && mirror.updated_frame == update);
                            if (capture) record_image_atlas(renderer, &readback, &mirror.irradiance)!;
                            renderer.finish_view(image.view)!;
                            renderer.end_frame()!;
                            assert(renderer.frame_submitted && renderer.frame_index == update);
                            assert(renderer.stats.probe_updates == 1);
                            assert(renderer.stats.probe_rays == volume.probe_count() * volume.update.rays_per_probe);
                            assert(renderer.stats.shader_rejections == 0 && renderer.stats.lights_dropped == 0);
                            if (capture) {
                                io::printfn("probe,%s,%s,%s,%s,%s,%s,%s,%s", name, update,
                                    mirror.updated_frame, mirror.fill.cursor, mirror.fill.scene_swept,
                                    volume.probe_count(), volume.update.rays_per_probe, renderer.stats.probe_rays);
                                save_light_image(
                                    run: run,
                                    fixture: &fixture,
                                    image: image,
                                    name: name,
                                )!;
                                save_image_atlas(
                                    run: run,
                                    renderer: renderer,
                                    readback: &readback,
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
