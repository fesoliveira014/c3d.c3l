module c3d::render::acceptance;

import c3d;
import c3d::light;
import c3d::render @public;
import c3d::scene;
import c3d::shader;
import gpu;
import std::io;
import std::math;
import std::math::vector;

fn void test_probe_medium_uses_global_atmosphere_owner_fog_layers_and_reuses_its_centre_tint() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    FogScene target = create_fog_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    Node* sun = add_sun(&target, { 0, 1, 0 }, 1)!!;
    sun.layers = 4;
    HeightFog fog = TEST_FOG;
    Node* fog_node = add_fog(&target, fog)!!;
    fog_node.layers = 2;
    fog_node.local.position.y = 1200;
    Node* owner = target.scene.add_node(name: "probe_owner")!!;
    owner.local.position.y = 1200;
    owner.layers = 1;
    ProbeVolume volume = light::probe_volume({ 1, 1, 1 }, { 2, 2, 2 }, SCENE);
    volume.update.rays_per_probe = light::PROBE_RAYS_MIN;
    target.scene.add(owner, volume);
    target.scene.update_world();
    FogView view = create_fog_view(&fixture, FORWARD)!!;
    defer destroy_fog_view(&fixture, &view);
    render_fog_frames(
        fixture: &fixture,
        target: &target,
        fog_view: &view,
        frames: 1,
    )!!;
    Renderer* renderer = &fixture.renderer;
    Target* tint = &renderer.probe_update.sky_view;
    assert(tint.texture.is_valid());
    assert(tint.width == shader::SKY_VIEW_WIDTH && tint.height == shader::SKY_VIEW_HEIGHT);
    assert(tint.format == gpu::Format.RGBA16_FLOAT);
    assert((usz)tint.width * tint.height * 8 == 165888);
    gpu::TextureHandle retained = tint.texture;

    renderer.begin_frame()!!;
    ViewEnvironments environments = render::resolve_view_environments(renderer, &target.scene, false)!!;
    ProbeFillRecording recording = { .scene = &target.scene, .environments = &environments };
    ProbeVolumeRes mirror = { .entity = owner.id };
    gpu::GpuAddress excluded = render::pack_probe_sky_fog(renderer, &recording, &mirror)!!;
    Frame* frame = &renderer.frames[renderer.frame_index % render::FRAMES_IN_FLIGHT];
    usz first_offset = (usz)(excluded - frame.upload.mapped.address);
    SkyFogGpu first = *(SkyFogGpu*)(frame.upload.mapped.bytes.ptr + first_offset);
    assert((first.flags & shader::SKY_FOG_ATMOSPHERE) != 0);
    assert((first.flags & shader::SKY_FOG_HEIGHT_FOG) == 0);
    assert(first.camera_altitude == 1200);
    assert(math::abs(first.camera_altitude - target.camera.world_position().y) > render::SKY_REGENERATION_ALTITUDE);
    owner.layers = 2;
    gpu::GpuAddress admitted = render::pack_probe_sky_fog(renderer, &recording, &mirror)!!;
    usz second_offset = (usz)(admitted - frame.upload.mapped.address);
    SkyFogGpu second = *(SkyFogGpu*)(frame.upload.mapped.bytes.ptr + second_offset);
    assert((second.flags & shader::SKY_FOG_ATMOSPHERE) != 0);
    assert((second.flags & shader::SKY_FOG_HEIGHT_FOG) != 0);
    assert(second.camera_altitude == 1200 && second.fog_base_height == 1200);
    assert(tint.texture == retained);
    gpu::TextureState before = renderer.probe_update.frame_sky_view_state;
    render::record_probe_sky_view(renderer, admitted)!!;
    render::abort_frame(renderer);
    assert(tint.state.layout == before.layout);
    assert(tint.state.stages == before.stages && tint.state.access == before.access);
    assert(tint.texture == retained);
    check_validation(renderer);
}

fn TraceSegmentVector[] probe_medium_vectors(Vec4f[] pixels) @private {
    TraceSegmentVector[] result = alloc::new_array(tmem, TraceSegmentVector, (sz)pixels.len);
    foreach (index, value : pixels) result[index] = { value.x, value.y, value.z };
    return result;
}

fn TraceSegmentVector probe_medium_level_tint(TraceSegmentVector[] pixels, double altitude) @private {
    double planet = light::ATMOSPHERE_EARTH.planet_radius;
    double beta = math::acos(math::sqrt(altitude * (2 * planet + altitude)) / (planet + altitude));
    double horizon = math::PI - beta;
    double vertical = (1 - math::sqrt(1 - (math::PI / 2) / horizon)) / 2;
    return trace_segment_bilinear(
        pixels: pixels,
        width: shader::SKY_VIEW_WIDTH,
        height: shader::SKY_VIEW_HEIGHT,
        horizontal: 0,
        vertical: vertical,
    );
}

fn Vec4[]? probe_medium_sample(
    Fixture* fixture,
    ProbeFillRecording* recording,
    ProbeVolumeRes* mirror,
    TraceSegmentCase entry,
) @private {
    Renderer* renderer = &fixture.renderer;
    gpu::PipelineHandle pipeline = create_trace_segment_pipeline(renderer)!;
    defer gpu::destroy_pipeline(&renderer.device, pipeline)!!;
    Target colors = create_trace_segment_texture(
        renderer: renderer,
        width: 1,
        height: 1,
        name: "probe_segment_sample",
    )!;
    defer render::release_storage_target(&renderer.device, &colors);
    gpu::AllocationDesc desc = {
        .size = TRACE_SEGMENT_ROWS * Vec4::size,
        .alignment = 16,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access = { .graphics },
        .debug_name = "probe_segment_sample",
    };
    gpu::MappedGpuSpan output = gpu::allocate_mapped_memory(&renderer.device, &desc)!;
    defer {
        gpu::GpuAllocation allocation = output.span.allocation();
        gpu::free_allocation(&renderer.device, &allocation)!!;
    }
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    gpu::GpuAddress sky = render::pack_probe_sky_fog(renderer, recording, mirror)!;
    FrameRoot frame = { .sky_fog = sky, .ambient = { 1, 1, 1, 0 } };
    TraceSegmentInput input = {
        .frame = upload_trace_segment(renderer, ((char*)&frame)[:FrameRoot::size])!,
        .sky = sky,
        .origin_length = { entry.origin.x, entry.origin.y, entry.origin.z, entry.distance },
        .direction = { entry.direction.x, entry.direction.y, entry.direction.z, 0 },
        .radiance = { 0.8f, 0.6f, 0.4f, 1 },
        .emission = { 0.25f, 0.5f, 1, 0 },
    };
    colors.transition(&renderer.commands, gpu::storage_at({ .compute }, { .write }))!;
    TraceSegmentRoot root = {
        .inputs = upload_trace_segment(renderer, ((char*)&input)[:TraceSegmentInput::size])!,
        .outputs = output.address,
        .output_image = colors.view.index,
        .count = 1,
    };
    gpu::GpuAddress address = upload_trace_segment(renderer, ((char*)&root)[:TraceSegmentRoot::size])!;
    gpu::cmd_bind_pipeline(&renderer.commands, pipeline)!;
    gpu::cmd_dispatch(&renderer.commands, address, { 1, 1, 1 })!;
    gpu::Barrier host = { .before = { .compute }, .after = { .host } };
    gpu::cmd_barrier(&renderer.commands, &host)!;
    renderer.work_recorded = true;
    renderer.end_frame()!;
    render::wait_frames(renderer)!;
    gpu::invalidate_mapped_span(&renderer.device, output.span)!;
    return alloc::clone_slice(mem, ((Vec4*)output.bytes.ptr)[:TRACE_SEGMENT_ROWS]);
}

fn void test_probe_medium_centre_altitude_matches_the_segment_oracle_and_differs_from_camera_tint() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    FogScene target = create_fog_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    add_sun(&target, { 0, 1, 0 }, 1)!!;
    HeightFog authored = TEST_FOG;
    authored.density = 0.125f;
    authored.falloff = 0.25f;
    authored.albedo = { 0.1f, 0.2f, 0.4f };
    Node* fog = add_fog(&target, authored)!!;
    fog.local.position.y = 1200;
    fog.layers = 2;
    Node* owner = target.scene.add_node(name: "probe_owner")!!;
    owner.local.position.y = 1200;
    owner.layers = 2;
    ProbeVolume volume = light::probe_volume({ 1, 1, 1 }, { 2, 2, 2 }, SCENE);
    volume.update.rays_per_probe = light::PROBE_RAYS_MIN;
    target.scene.add(owner, volume);
    target.scene.update_world();
    FogView view = create_fog_view(&fixture, FORWARD)!!;
    defer destroy_fog_view(&fixture, &view);
    render_fog_frames(
        fixture: &fixture,
        target: &target,
        fog_view: &view,
        frames: 1,
    )!!;
    Renderer* renderer = &fixture.renderer;
    Vec4f[] centre_pixels = read_atlas(&fixture, &renderer.probe_update.sky_view)!!;
    Target* camera_tint = &renderer.views.get(view.view).sky_view;
    Vec4f[] camera_pixels = read_atlas(&fixture, camera_tint)!!;
    TraceSegmentVector centre = probe_medium_level_tint(probe_medium_vectors(centre_pixels), 1200);
    TraceSegmentVector camera = probe_medium_level_tint(probe_medium_vectors(camera_pixels), target.camera.world_position().y);
    io::printfn("probe centre tint altitude=1200 camera_altitude=%s tint_distance=%s",
        target.camera.world_position().y, (centre - camera).length());
    assert((centre - camera).length() > 1e-6, "The altitude witness must distinguish the camera tint.");
    renderer.begin_frame()!!;
    ViewEnvironments environments = render::resolve_view_environments(renderer, &target.scene, false)!!;
    renderer.end_frame()!!;
    render::wait_frames(renderer)!!;
    AtmosphereRes* atmosphere = environments.atmosphere;
    Target transmittance = {
        .texture = atmosphere.transmittance,
        .view = atmosphere.transmittance_view,
        .width = shader::SKY_TRANSMITTANCE_WIDTH,
        .height = shader::SKY_TRANSMITTANCE_HEIGHT,
    };
    Target multiple = {
        .texture = atmosphere.multi_scattering,
        .view = atmosphere.multi_scattering_view,
        .width = shader::SKY_MULTI_SCATTERING_SIZE,
        .height = shader::SKY_MULTI_SCATTERING_SIZE,
    };
    TraceSegmentTableData tables = {
        .transmittance = probe_medium_vectors(read_atlas(&fixture, &transmittance)!!),
        .multiple = probe_medium_vectors(read_atlas(&fixture, &multiple)!!),
    };
    TraceSegmentCase entry = {
        .origin = { 0, 1200, 0 },
        .direction = { 1, 0, 0 },
        .sun = { 0, 1, 0 },
        .distance = 4,
        .density = authored.density,
        .falloff = authored.falloff,
        .base_height = 1200,
        .height = true,
        .atmosphere = true,
    };
    TraceSegmentTerms air = trace_segment_atmosphere_reference(
        entry: entry,
        atmosphere: light::ATMOSPHERE_EARTH,
        tables: &tables,
        steps: TRACE_SEGMENT_REFERENCE_HIGH,
    );
    TraceSegmentTerms height = trace_segment_height_reference(entry);
    height.scattering *= centre;
    ProbeFillRecording recording = { .scene = &target.scene, .environments = &environments };
    ProbeVolumeRes mirror = { .entity = owner.id };
    Vec4[] actual = probe_medium_sample(
        fixture: &fixture,
        recording: &recording,
        mirror: &mirror,
        entry: entry,
    )!!;
    defer free(actual.ptr);
    TraceSegmentVector expected = height.transmittance
      * (air.transmittance * (TraceSegmentVector){ 0.8, 0.6, 0.4 } + air.scattering) + height.scattering;
    double maximum_color_error;
    double maximum_tint_error;
    for (uint channel = 0; channel < 3; channel++) {
        double bound = TRACE_SEGMENT_HEIGHT_ABSOLUTE + TRACE_SEGMENT_HEIGHT_RELATIVE * math::abs(height.scattering[channel]);
        maximum_tint_error = math::max(maximum_tint_error, math::abs((double)actual[3][channel] - height.scattering[channel]));
        assert(math::abs((double)actual[3][channel] - height.scattering[channel]) <= bound);
        bound = TRACE_SEGMENT_HDR_ABSOLUTE + TRACE_SEGMENT_HDR_RELATIVE * math::abs(expected[channel]);
        maximum_color_error = math::max(maximum_color_error, math::abs((double)actual[6][channel] - expected[channel]));
        assert(math::abs((double)actual[6][channel] - expected[channel]) <= bound);
    }
    io::printfn("probe segment maximum_color_error=%s maximum_tint_error=%s",
        maximum_color_error, maximum_tint_error);
    check_validation(renderer);
}
