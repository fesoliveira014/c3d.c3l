module c3d::render::acceptance;

import std::math::vector;
import std::math;

import c3d;
import c3d::asset;
import c3d::material;
import c3d::maths;
import c3d::render @public;
import c3d::render::post;
import c3d::scene;
import c3d::shader;
import gpu;
import std::io;

const uint LAYERED_LIFETIME_FRAME_LIMIT @private = 512;
const uint LAYERED_LIFETIME_TEMPORAL_FRAMES @private = 120;
const uint LAYERED_LIFETIME_PRESSURE_CAPACITY @private = 128;

enum LayeredPressure @private {
    TEXTURES,
    SAMPLED_VIEWS,
    ATTACHMENT_VIEWS,
}

struct LayeredPressureFill @private {
    RenderTargetId[LAYERED_LIFETIME_PRESSURE_CAPACITY] targets;
    gpu::AttachmentViewHandle[gpu::DEFAULT_ATTACHMENT_VIEW_CAPACITY] attachments;
    uint count;
    LayeredPressure kind;
}

struct LayeredLifetimeSnapshot @private {
    ViewDesc desc;
    Target color;
    Target depth;
    TransparencyState transparency;
    gpu::GpuAllocation[render::FRAMES_IN_FLIGHT] readbacks;
    usz payload;
}

fn void check_layered_pixel_bits(Vec4[] actual, Vec4[] expected) @private {
    assert(actual.len == expected.len);
    foreach (pixel, color : actual) {
        for (uint channel = 0; channel < 4; channel++) {
            assert(bitcast(color[channel], uint) == bitcast(expected[pixel][channel], uint));
        }
    }
}

fn uint layered_prepared_compute_count(Renderer* renderer) @private {
    uint count;
    foreach (slot : PrepareComputeSlot::values) {
        if (render::prepare_compute_slot(renderer, slot).is_valid()) count++;
    }
    return count;
}

fn ModelId? layered_lifetime_model(Fixture* fixture, GeometryId geometry, MaterialId material) @private {
    ModelTemplate model = {
        .nodes = alloc::new_array(fixture.allocator, NodeTemplate, 1),
        .meshes = alloc::new_array(fixture.allocator, ModelMesh, 1),
    };
    defer catch asset::free_model_template(fixture.allocator, &model);
    model.nodes[0] = { .parent = -1, .local = maths::TRANSFORM_IDENTITY, .visible = true, .layers = uint::max };
    model.meshes[0] = { .node = 0, .geometry = geometry, .material = material };
    return fixture.assets.add_model_owned(&model);
}

fn void test_layered_lifetime_rejected_shader_replacement_keeps_the_published_declaration_and_pixels() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    Fixture fixture;
    create_fixture(&tracker, &fixture)!!;
    defer destroy_fixture(&fixture);
    LayeredScene target = create_layered_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    LayeredView view = create_layered_view(&fixture, 2)!!;
    defer destroy_layered_view(&fixture, &view);
    GeometryId geometry = add_layered_sheet_geometry(&fixture, 0.5f)!!;
    MaterialId reader = add_layered_reader(&fixture, true)!!;
    target.scene.add_mesh(geometry, reader)!!;
    Vec4[] original = render_layered_pixels(&fixture, &target, &view)!!;
    defer free(original);

    ShaderId shader = fixture.assets.material(reader).data.custom.shader;
    ShaderRes* published = &fixture.renderer.shaders[shader.index];
    uint published_revision = published.revision;
    assert(published.desc.layered_transparency);
    @pool() {
        PipelineKey[] keys = fixture.renderer.pipelines.keys_of(tmem, shader, published_revision);
        uint layered;
        foreach (key : keys) if (key.custom.layered) layered++;
        assert(layered >= 2);
    };
    asset::ShaderDesc replacement = asset::copy_shader_desc(fixture.allocator, &fixture.assets.shader(shader).desc);
    defer asset::free_shader_desc(fixture.allocator, &replacement);
    alloc::free(fixture.allocator, replacement.fragment.ptr);
    replacement.fragment = published_broken_fragment(&fixture)!!;
    replacement.layered_transparency = false;
    fixture.assets.replace_shader(shader, &replacement)!!;
    assert(@catch(fixture.renderer.upload_shader(shader)) == gpu::SHADER_INVALID);
    assert(published.revision == published_revision && published.desc.layered_transparency);
    assert(published.rejected_revision == fixture.assets.shader(shader).header.revision);

    Vec4[] after = render_layered_pixels(&fixture, &target, &view)!!;
    defer free(after);
    check_layered_pixel_bits(after, original);
    assert(fixture.renderer.view_stats(view.view)!!.transparency.fallback_draws == 0);
    check_validation(&fixture.renderer);
}

fn void test_layered_lifetime_strict_preparation_counts_instanced_keys_before_first_render() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    Fixture fixture;
    create_fixture(&tracker, &fixture)!!;
    defer destroy_fixture(&fixture);
    LayeredScene target = create_layered_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    LayeredView view = create_layered_view(&fixture, 2)!!;
    defer destroy_layered_view(&fixture, &view);
    GeometryId geometry = add_layered_sheet_geometry(&fixture, 0.5f)!!;
    MaterialId material = add_layered_basic(&fixture, { 1, 0.5f, 0.25f, 0.5f })!!;
    Node* batch_node = target.scene.add_instanced_mesh(geometry, material, 2)!!;
    target.scene.resize_instances(batch_node, 2)!!;
    InstancedMesh* batch = target.scene.get(batch_node, InstancedMesh);
    batch.transforms[0] = maths::TRANSFORM_IDENTITY;
    batch.transforms[1] = maths::TRANSFORM_IDENTITY;
    batch.transforms[1].position.z = -1;
    target.scene.mark_instances_dirty(batch_node);
    ModelId model = layered_lifetime_model(&fixture, geometry, material)!!;
    Renderer* renderer = &fixture.renderer;
    PrepareId prepared = renderer.begin_prepare_model(model)!!;
    defer renderer.end_prepare(prepared)!!;
    PrepareProgress progress = renderer.prepare_progress(prepared);
    ulong reported;
    for (uint iteration = 0;
      iteration < LAYERED_LIFETIME_FRAME_LIMIT && progress.state != PrepareState.READY;
      iteration++) {
        renderer.begin_frame()!!;
        ulong cache_before = renderer.pipelines.creations.calls;
        uint compute_before = layered_prepared_compute_count(renderer);
        PrepareReport report = renderer.advance_prepares_within({ .pipelines = 1 })!!;
        ulong actual = renderer.pipelines.creations.calls - cache_before
          + layered_prepared_compute_count(renderer) - compute_before;
        assert(report.pipelines <= 1 && report.pipelines == actual,
            "Strict pipeline reporting missed a cached or direct compute creation.");
        reported += report.pipelines;
        renderer.end_frame()!!;
        progress = renderer.prepare_progress(prepared);
        assert(progress.state != PrepareState.FAILED);
    }
    assert(progress.state == PrepareState.READY && reported > 0);
    PipelineKey instanced = render::transparency_pipeline_key(
        material: &fixture.assets.material(material).data,
        vertex: { .shader = MESH, .flags = shader::SHADER_FLAG_INSTANCED },
        polygon: gpu::PolygonMode.FILL,
        shadow_flags: 0,
        capture: true,
    );
    assert(renderer.pipelines.pipelines.has_key(instanced), "Instanced capture was not prepared.");
    instanced.color_formats[0] = gpu::Format.RGBA32_FLOAT;
    assert(renderer.pipelines.pipelines.has_key(instanced), "Instanced retained shading was not prepared.");

    ulong warm = renderer.pipelines.creations.calls;
    uint warm_compute = layered_prepared_compute_count(renderer);
    Vec4[] pixels = render_layered_pixels(&fixture, &target, &view)!!;
    defer free(pixels);
    assert(renderer.pipelines.creations.calls == warm && layered_prepared_compute_count(renderer) == warm_compute,
        "The first instanced layered draw created an unprepared pipeline.");
    check_validation(renderer);
}

fn LayeredLifetimeSnapshot layered_lifetime_snapshot(Renderer* renderer, ViewId view) @private {
    ViewRecord* record = renderer.views.get(view);
    LayeredLifetimeSnapshot snapshot = {
        .desc = record.desc,
        .color = record.hdr_color,
        .depth = record.depth,
        .transparency = record.transparency,
        .payload = record.stats.transparency.payload_bytes,
    };
    foreach (index, slot : record.transparency_readbacks.slots) {
        if (slot.mapped.bytes.len) snapshot.readbacks[index] = slot.mapped.span.allocation();
    }
    return snapshot;
}

fn void check_layered_target(Target* actual, Target* expected) @private {
    assert(actual.texture == expected.texture && actual.attachment == expected.attachment);
    assert(actual.view.index == expected.view.index && actual.view.generation == expected.view.generation);
    assert(actual.width == expected.width && actual.height == expected.height && actual.format == expected.format);
}

fn void check_layered_lifetime_snapshot(
    Renderer* renderer,
    ViewId view,
    LayeredLifetimeSnapshot* expected,
) @private {
    ViewRecord* record = renderer.views.get(view);
    assert(record.desc.transparency.mode == expected.desc.transparency.mode);
    assert(record.desc.transparency.layer_capacity == expected.desc.transparency.layer_capacity);
    assert(record.desc.render_scale == expected.desc.render_scale);
    assert(c3d::same_id(record.desc.target, expected.desc.target));
    check_layered_target(&record.hdr_color, &expected.color);
    check_layered_target(&record.depth, &expected.depth);
    Target*[render::TRANSPARENCY_TARGET_COUNT] previous = render::transparency_targets(&expected.transparency);
    foreach (index, target : render::transparency_targets(&record.transparency)) {
        check_layered_target(target, previous[index]);
    }
    foreach (index, slot : record.transparency_readbacks.slots) {
        gpu::GpuAllocation allocation;
        if (slot.mapped.bytes.len) allocation = slot.mapped.span.allocation();
        assert(allocation == expected.readbacks[index]);
    }
    assert(record.stats.transparency.payload_bytes == expected.payload);
}

fn void fill_layered_pressure(
    Renderer* renderer,
    LayeredPressureFill* pressure,
    gpu::TextureHandle source,
) @private {
    if (pressure.kind == LayeredPressure.ATTACHMENT_VIEWS) {
        gpu::AttachmentViewDesc desc = { .texture = source };
        while (true) {
            gpu::AttachmentViewHandle? handle = gpu::create_attachment_view(&renderer.device, &desc);
            if (catch excuse = handle) {
                assert(excuse == gpu::SLOT_TABLE_FULL);
                break;
            }
            assert(pressure.count < pressure.attachments.len);
            pressure.attachments[pressure.count++] = handle;
        }
        return;
    }
    fault expected = pressure.kind == LayeredPressure.TEXTURES ? gpu::SLOT_TABLE_FULL : gpu::DESCRIPTOR_HEAP_FULL;
    pressure.count = resize_fill(renderer, pressure.targets[..], expected);
}

fn void free_layered_pressure_slot(Renderer* renderer, LayeredPressureFill* pressure) @private {
    assert(pressure.count > 0);
    pressure.count--;
    switch (pressure.kind) {
        case TEXTURES:
        case SAMPLED_VIEWS:
            render::destroy_render_target(renderer, pressure.targets[pressure.count])!!;
        case ATTACHMENT_VIEWS:
            gpu::destroy_attachment_view(&renderer.device, pressure.attachments[pressure.count])!!;
    }
}

fn void release_layered_pressure(Renderer* renderer, LayeredPressureFill* pressure) @private {
    while (pressure.count) free_layered_pressure_slot(renderer, pressure);
}

fn void check_layered_free_attachments(Renderer* renderer, gpu::TextureHandle source, uint expected) @private {
    gpu::AttachmentViewHandle[32] probes;
    uint created;
    defer foreach (handle : probes[:created]) gpu::destroy_attachment_view(&renderer.device, handle)!!;
    gpu::AttachmentViewDesc desc = { .texture = source };
    for (; created < expected; created++) probes[created] = gpu::create_attachment_view(&renderer.device, &desc)!!;
    assert(@catch(gpu::create_attachment_view(&renderer.device, &desc)) == gpu::SLOT_TABLE_FULL,
        "A failed stage changed the number of reusable attachment slots.");
}

fn void layered_lifetime_acquisition_faults(LayeredPressure kind, bool resize) @private {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        Fixture fixture;
        create_fixture(
            allocator: &tracker,
            fixture: &fixture,
            max_render_targets: LAYERED_LIFETIME_PRESSURE_CAPACITY,
            texture_capacity: kind == LayeredPressure.TEXTURES ? LAYERED_LIFETIME_PRESSURE_CAPACITY : 0,
            texture_heap_capacity: kind == LayeredPressure.SAMPLED_VIEWS ? LAYERED_LIFETIME_PRESSURE_CAPACITY : 0,
        )!!;
        defer destroy_fixture(&fixture);
        LayeredScene target = create_layered_scene(&fixture)!!;
        defer scene::destroy_scene(&target.scene);
        LayeredView view = create_layered_view(&fixture, 1)!!;
        defer destroy_layered_view(&fixture, &view);
        GeometryId geometry = add_layered_sheet_geometry(&fixture, 0.5f)!!;
        MaterialId material = add_layered_basic(&fixture, { 1, 0.5f, 0.25f, 0.5f })!!;
        target.scene.add_mesh(geometry, material)!!;
        for (uint frame = 0; frame < render::FRAMES_IN_FLIGHT; frame++) {
            Vec4[] warm = render_layered_pixels(&fixture, &target, &view)!!;
            free(warm);
        }
        Vec4[] original = render_layered_pixels(&fixture, &target, &view)!!;
        defer free(original);
        Renderer* renderer = &fixture.renderer;
        ViewRecord* record = renderer.views.get(view.view);
        LayeredLifetimeSnapshot snapshot = layered_lifetime_snapshot(renderer, view.view);
        ResizeTargetState output = resize_target_state(renderer, view.target);
        gpu::TextureHandle source = renderer.targets.get(view.target).target.texture;
        LayeredPressureFill* pressure = mem::new(LayeredPressureFill);
        defer free(pressure);
        pressure.kind = kind;
        fill_layered_pressure(renderer, pressure, source);
        defer release_layered_pressure(renderer, pressure);
        uint prefix = resize ? 3 : 0;
        for (uint slot = 0; slot < prefix; slot++) free_layered_pressure_slot(renderer, pressure);
        uint groups = resize ? 2 : 3;
        uint mips = transparency_fixtures::mip_level_count(resize ? 129 : 128, resize ? 65 : 128);
        uint acquisitions;
        switch (kind) {
            case TEXTURES: acquisitions = groups + 8;
            case SAMPLED_VIEWS: acquisitions = groups + 6 + 2 * (1 + mips);
            case ATTACHMENT_VIEWS: acquisitions = groups + 6;
        }
        for (uint failed = 0; failed < acquisitions; failed++) {
            CapacityCounts before = capacity_counts(renderer);
            ulong allocations_before = gpu::get_memory_stats(&renderer.device)!!.live_allocation_count;
            ViewDesc changed = record.desc;
            changed.transparency.layer_capacity = 2;
            fault expected = kind == LayeredPressure.SAMPLED_VIEWS ? gpu::DESCRIPTOR_HEAP_FULL : gpu::SLOT_TABLE_FULL;
            if (resize) {
                assert(@catch(render::resize_render_target(
                    renderer: renderer,
                    target: view.target,
                    width: 129,
                    height: 65,
                )) == expected);
            } else {
                assert(@catch(render::configure_view(renderer, view.view, changed)) == expected);
            }
            capacity_check_counts(capacity_counts(renderer), before);
            assert(gpu::get_memory_stats(&renderer.device)!!.live_allocation_count == allocations_before);
            check_layered_lifetime_snapshot(renderer, view.view, &snapshot);
            resize_check_target(renderer, view.target, output);
            if (kind == LayeredPressure.ATTACHMENT_VIEWS) {
                check_layered_free_attachments(renderer, source, prefix + failed);
            }
            Vec4[] retained = render_layered_pixels(&fixture, &target, &view)!!;
            check_layered_pixel_bits(retained, original);
            free(retained);
            free_layered_pressure_slot(renderer, pressure);
        }
        io::printfn("layered acquisition kind=%s resize=%s fault_positions=%s", kind, resize, acquisitions);
        check_validation(renderer);
    }
    assert(tracker.allocated() == 0, "Faulted transparency acquisition retained tracked allocations.");
}

fn void test_layered_lifetime_each_configure_image_and_view_acquisition_is_atomic() @test {
    foreach (kind : LayeredPressure::values) layered_lifetime_acquisition_faults(kind, false);
}

fn void test_layered_lifetime_each_resize_image_and_view_acquisition_is_atomic() @test {
    foreach (kind : LayeredPressure::values) layered_lifetime_acquisition_faults(kind, true);
}

fn ViewDesc layered_fresh_description(ViewDesc previous) @private {
    ViewDesc fresh;
    foreach (&byte : ((char*)&fresh)[:ViewDesc::size]) *byte = 0xa5;
    $foreach $member : ViewDesc::members:
        fresh.$member = previous.$member;
    $endforeach
    PostStack post;
    foreach (&byte : ((char*)&post)[:PostStack::size]) *byte = 0x5a;
    $foreach $member : PostStack::members:
        post.$member = previous.post.$member;
    $endforeach
    fresh.post = post;
    return fresh;
}

fn Vec4[]? read_layered_lifetime_output(Fixture* fixture, LayeredView* view) @private {
    Target* target = &fixture.renderer.targets.get(view.target).target;
    Vec4[] pixels = mem::new_array(Vec4, (usz)target.width * target.height);
    defer catch free(pixels);
    fixture.renderer.read_render_target(view.target, ((char*)pixels.ptr)[:pixels.len * Vec4::size])!;
    return pixels;
}

fn void layered_quality_change_preserves_history(
    Fixture* fixture,
    LayeredView* view,
    TransparencyMode mode,
    uint capacity,
) @private {
    ViewRecord* record = fixture.renderer.views.get(view.view);
    ViewHistory previous = record.history;
    ViewDesc desc = layered_fresh_description(record.desc);
    desc.transparency = { .mode = mode, .layer_capacity = capacity };
    render::configure_view(&fixture.renderer, view.view, desc)!!;
    assert(record.history.valid == previous.valid && record.history.pending == previous.pending);
    assert(record.history.sample_index == previous.sample_index && record.history.slot == previous.slot);
    assert(record.history.models.ptr == previous.models.ptr && record.history.time == previous.time,
        "A quality-only change reset or replaced temporal history.");
}

fn void test_layered_lifetime_two_taa_views_keep_quality_history_and_retry_without_corpus_resets() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    Fixture fixture;
    create_fixture(&tracker, &fixture)!!;
    defer destroy_fixture(&fixture);
    LayeredScene target = create_layered_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    LayeredView first = create_layered_view(&fixture, 1)!!;
    defer destroy_layered_view(&fixture, &first);
    LayeredView second = create_layered_view(&fixture, 2)!!;
    defer destroy_layered_view(&fixture, &second);
    enable_taa(&fixture, first.view)!!;
    enable_taa(&fixture, second.view)!!;
    GeometryId near_geometry = add_layered_sheet_geometry(&fixture, 0.75f)!!;
    GeometryId far_geometry = add_layered_sheet_geometry(&fixture, 0.5f)!!;
    MaterialId red = add_layered_basic(&fixture, { 1, 0, 0, 0.5f })!!;
    MaterialId green = add_layered_basic(&fixture, { 0, 1, 0, 0.25f })!!;
    target.scene.add_mesh(near_geometry, red)!!;
    target.scene.add_mesh(far_geometry, green)!!;
    target.scene.update_world();
    transparency_fixtures::Color expected = transparency_fixtures::compose_over(
        behind: transparency_fixtures::compose_over(transparency_fixtures::PLANAR_BACKGROUND, { 0, 1, 0 }, 0.25),
        radiance: { 1, 0, 0 },
        coverage: 0.5,
    );
    Renderer* renderer = &fixture.renderer;
    ViewRecord* first_record = renderer.views.get(first.view);
    ViewRecord* second_record = renderer.views.get(second.view);
    uint quality_changes;
    uint aborted;
    for (uint frame = 0; frame < LAYERED_LIFETIME_TEMPORAL_FRAMES; frame++) {
        if (frame == 30 || frame == 60 || frame == 90) {
            TransparencyMode first_mode = frame == 30 ? TransparencyMode.SORTED : TransparencyMode.LAYERED;
            TransparencyMode second_mode = frame == 60 ? TransparencyMode.SORTED : TransparencyMode.LAYERED;
            layered_quality_change_preserves_history(
                fixture: &fixture,
                view: &first,
                mode: first_mode,
                capacity: frame == 90 ? 16 : 4,
            );
            layered_quality_change_preserves_history(
                fixture: &fixture,
                view: &second,
                mode: second_mode,
                capacity: frame == 90 ? 1 : 2,
            );
            quality_changes += 2;
        }
        if (frame == 40 || frame == 80) {
            ViewDesc desc = first_record.desc;
            desc.render_scale = frame == 40 ? 0.75f : 1;
            render::configure_view(renderer, first.view, desc)!!;
            assert(!first_record.history.valid);
            desc = second_record.desc;
            desc.render_scale = frame == 40 ? 0.5f : 1;
            render::configure_view(renderer, second.view, desc)!!;
            assert(!second_record.history.valid);
        }
        if (frame == 44) {
            ViewDesc changed = first_record.desc;
            changed.lod_bias += 0.125f;
            render::configure_view(renderer, first.view, changed)!!;
            assert(!first_record.history.valid, "A non-transparency descriptor change stopped invalidating history.");
        }
        bool abandon = frame == 17 || frame == 53 || frame == 89;
        Vec4[] previous_first;
        Vec4[] previous_second;
        if (abandon) {
            previous_first = read_layered_lifetime_output(&fixture, &first)!!;
            previous_second = read_layered_lifetime_output(&fixture, &second)!!;
        }
        defer free(previous_first);
        defer free(previous_second);
        FrameInfo info = { .time = (double)frame / 60, .delta = 1.0f / 60 };
        renderer.begin_frame(info)!!;
        ViewHistory first_history = first_record.history;
        ViewHistory second_history = second_record.history;
        TransparencyStats first_completed = first_record.stats.transparency;
        TransparencyStats second_completed = second_record.stats.transparency;
        renderer.render_view(&target.scene, target.camera, first.view)!!;
        renderer.finish_view(first.view)!!;
        renderer.render_view(&target.scene, target.camera, second.view)!!;
        renderer.finish_view(second.view)!!;
        if (abandon) {
            render::abort_frame(renderer);
            assert(!first_record.history.pending && !second_record.history.pending);
            assert(first_record.history.sample_index == first_history.sample_index);
            assert(second_record.history.sample_index == second_history.sample_index);
            assert(first_record.history.slot == first_history.slot);
            assert(second_record.history.slot == second_history.slot);
            assert(first_record.stats.transparency.overflow_frame_index == first_completed.overflow_frame_index);
            assert(second_record.stats.transparency.overflow_frame_index == second_completed.overflow_frame_index);
            Vec4[] untouched_first = read_layered_lifetime_output(&fixture, &first)!!;
            defer free(untouched_first);
            Vec4[] untouched_second = read_layered_lifetime_output(&fixture, &second)!!;
            defer free(untouched_second);
            check_layered_pixel_bits(untouched_first, previous_first);
            check_layered_pixel_bits(untouched_second, previous_second);
            renderer.begin_frame(info)!!;
            renderer.render_view(&target.scene, target.camera, first.view)!!;
            renderer.finish_view(first.view)!!;
            renderer.render_view(&target.scene, target.camera, second.view)!!;
            renderer.finish_view(second.view)!!;
            aborted++;
        }
        renderer.end_frame()!!;
        assert(first_record.history.valid && second_record.history.valid);
        Vec4[] first_pixels = read_layered_lifetime_output(&fixture, &first)!!;
        defer free(first_pixels);
        Vec4[] second_pixels = read_layered_lifetime_output(&fixture, &second)!!;
        defer free(second_pixels);
        check_layered_color(layered_center(first_pixels, 128, 128), expected);
        check_layered_color(layered_center(second_pixels, 128, 128), expected);
        assert(first_record.hdr_color.texture != second_record.hdr_color.texture);
        if (first_record.desc.transparency.mode == TransparencyMode.LAYERED
          && second_record.desc.transparency.mode == TransparencyMode.LAYERED) {
            assert(first_record.transparency.depths[0].texture != second_record.transparency.depths[0].texture);
            assert(first_record.transparency_readbacks.slots[0].mapped.bytes.ptr
                != second_record.transparency_readbacks.slots[0].mapped.bytes.ptr);
        }
    }
    assert(quality_changes == 6 && aborted == 3);
    io::printfn("layered temporal frames=%s quality_changes=%s aborted_retries=%s corpus=unchanged",
        LAYERED_LIFETIME_TEMPORAL_FRAMES, quality_changes, aborted);
    check_validation(renderer);
}

fn double layered_motion_halton(uint index, uint base) @private {
    double value;
    double place = 1;
    while (index) {
        place /= base;
        value += place * (index % base);
        index /= base;
    }
    return value;
}

fn void check_layered_motion_pixels(
    Vec4[] pixels,
    uint width,
    uint height,
    uint frame,
    uint sample,
    TransparencyMode mode,
) @private {
    uint point = sample % post::TAA_SAMPLE_COUNT + 1;
    double pixel_jitter_x = layered_motion_halton(point, 2) - 0.5;
    double pixel_jitter_y = layered_motion_halton(point, 3) - 0.5;
    double jitter_x = 2 * pixel_jitter_x / width;
    double jitter_y = -2 * pixel_jitter_y / height;
    double aspect = (double)width / height;
    double glass_x = (double)frame / 64;
    double backdrop_x = -(double)frame / 128;
    double top = (double)height / 8 + pixel_jitter_y;
    double bottom = 7 * (double)height / 8 + pixel_jitter_y;
    double left = (double)width / 2 - 3 * (double)height / 8 + pixel_jitter_x;
    double right = (double)width / 2 + 3 * (double)height / 8 + pixel_jitter_x;
    double glass_offset = glass_x * height / 2;
    double backdrop_offset = backdrop_x * height / 2;
    for (uint row = 0; row < height; row++) {
        double world_y = 1 - 2 * ((double)row + 0.5) / height - jitter_y;
        // The top and left raster edges are included; bottom and right are excluded.
        bool vertical = (double)row + 0.5 >= top && (double)row + 0.5 < bottom;
        for (uint column = 0; column < width; column++) {
            double world_x = (2 * ((double)column + 0.5) / width - 1 - jitter_x) * aspect;
            double pixel_x = (double)column + 0.5;
            bool backdrop = vertical && pixel_x >= left + backdrop_offset && pixel_x < right + backdrop_offset;
            bool glass = vertical && pixel_x >= left + glass_offset && pixel_x < right + glass_offset;
            bool green = vertical && pixel_x >= left && pixel_x < right;
            transparency_fixtures::Color opaque = backdrop ? transparency_fixtures::PLANAR_BACKGROUND
              : (transparency_fixtures::Color){};
            transparency_fixtures::Color behind = green
              ? transparency_fixtures::compose_over(opaque, { 0, 1, 0 }, 0.25) : opaque;
            transparency_fixtures::Color expected = behind;
            if (glass) {
                if (mode == TransparencyMode.LAYERED) {
                    expected = 0.875 * behind + (transparency_fixtures::Color){ 0.25, 0, 0 };
                } else {
                    expected = 0.875 * opaque + (transparency_fixtures::Color){ 0.25, 0, 0 };
                    if (green) expected = transparency_fixtures::compose_over(expected, { 0, 1, 0 }, 0.25);
                }
            }
            Vec4 actual = pixels[row * width + column];
            bool mismatch;
            for (uint channel = 0; channel < 3; channel++) {
                double bound = LAYERED_COLOR_ABSOLUTE_TOLERANCE
                  + LAYERED_COLOR_RELATIVE_TOLERANCE * math::abs(expected[channel]);
                mismatch |= !math::is_finite(actual[channel])
                  || math::abs((double)actual[channel] - expected[channel]) > bound;
            }
            if (mismatch) {
                io::printfn("moving frame=%s extent=%sx%s sample=%s row=%s column=%s mode=%s",
                    frame,
                    width,
                    height,
                    sample,
                    row,
                    column,
                    mode,
                );
                io::printfn("world=(%s,%s) jitter=(%s,%s) glass_x=%s backdrop_x=%s",
                    world_x,
                    world_y,
                    jitter_x,
                    jitter_y,
                    glass_x,
                    backdrop_x,
                );
                io::printfn("coverage vertical=%s bg=%s glass=%s green=%s actual=(%s,%s,%s) expected=(%s,%s,%s)",
                    vertical,
                    backdrop,
                    glass,
                    green,
                    actual.x,
                    actual.y,
                    actual.z,
                    expected.x,
                    expected.y,
                    expected.z,
                );
            }
            check_layered_color(actual, expected);
        }
    }
}

fn Vec4[]? read_layered_motion_target(Fixture* fixture, RenderTargetId id) @private {
    Target* target = &fixture.renderer.targets.get(id).target;
    Vec4[] pixels = mem::new_array(Vec4, (usz)target.width * target.height);
    defer catch free(pixels);
    fixture.renderer.read_render_target(id, ((char*)pixels.ptr)[:pixels.len * Vec4::size])!;
    return pixels;
}

fn void record_layered_motion_copy(Renderer* renderer, ViewRecord* view, RenderTargetId id) @private {
    render::composite_target(
        renderer: renderer,
        source: &view.hdr_color,
        output: &renderer.targets.get(id).target,
        rect: {},
    )!!;
}

fn void test_layered_lifetime_moving_glass_keeps_two_view_current_pixels_and_quality_history() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    Fixture fixture;
    create_fixture(&tracker, &fixture)!!;
    defer destroy_fixture(&fixture);
    LayeredScene target = create_layered_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    Node* backdrop;
    target.scene.@each(Mesh; Entity entity, Mesh* mesh) { backdrop = target.scene.node(entity); };
    assert(backdrop);
    target.scene.ambient_color = {};
    target.scene.ambient_intensity = 0;
    PhysicalParams params = material::PHYSICAL_PARAMS_DEFAULT;
    params.standard.base_color = { 1, 1, 1, 0.5f };
    params.standard.metallic = 0;
    params.standard.roughness = 0;
    params.standard.emissive = { 0.5f, 0, 0 };
    params.ior = 1;
    params.specular = 0;
    params.transmission = 0.75f;
    params.thickness = 0;
    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    common.alpha_mode = AlphaMode.BLEND;
    common.double_sided = true;
    common.depth_write = false;
    MaterialId material = fixture.assets.add_material(material::physical(params, common))!!;
    Node* glass = target.scene.add_mesh(add_layered_sheet_geometry(&fixture, 0.75f)!!, material)!!;
    MaterialId green = add_layered_basic(&fixture, { 0, 1, 0, 0.25f })!!;
    target.scene.add_mesh(add_layered_sheet_geometry(&fixture, 0.5f)!!, green)!!;
    LayeredView first = create_layered_view(&fixture, 1)!!;
    defer destroy_layered_view(&fixture, &first);
    LayeredView second = create_layered_view(&fixture, 2)!!;
    defer destroy_layered_view(&fixture, &second);
    render::resize_render_target(
        renderer: &fixture.renderer,
        target: second.target,
        width: 257,
        height: 129,
    )!!;
    enable_taa(&fixture, first.view)!!;
    enable_taa(&fixture, second.view)!!;
    Renderer* renderer = &fixture.renderer;
    ViewRecord* first_record = renderer.views.get(first.view);
    ViewRecord* second_record = renderer.views.get(second.view);
    RenderTargetId first_copy = render::create_render_target(renderer, render::render_target_desc(
        width: 128,
        height: 128,
        format: PixelFormat.RGBA32_FLOAT,
    ))!!;
    defer render::destroy_render_target(renderer, first_copy)!!;
    RenderTargetId second_copy = render::create_render_target(renderer, render::render_target_desc(
        width: 257,
        height: 129,
        format: PixelFormat.RGBA32_FLOAT,
    ))!!;
    defer render::destroy_render_target(renderer, second_copy)!!;
    uint quality_changes;
    uint aborted;
    for (uint frame = 0; frame < LAYERED_LIFETIME_TEMPORAL_FRAMES; frame++) {
        glass.local.position.x = (float)frame / 64;
        backdrop.local.position.x = -(float)frame / 128;
        target.scene.update_world();
        if (frame == 30 || frame == 60 || frame == 90) {
            layered_quality_change_preserves_history(
                fixture: &fixture,
                view: &first,
                mode: frame == 30 ? TransparencyMode.SORTED : TransparencyMode.LAYERED,
                capacity: frame == 90 ? 16 : 4,
            );
            layered_quality_change_preserves_history(
                fixture: &fixture,
                view: &second,
                mode: frame == 60 ? TransparencyMode.SORTED : TransparencyMode.LAYERED,
                capacity: frame == 90 ? 1 : 2,
            );
            quality_changes += 2;
        }
        if (frame == 40 || frame == 80) {
            ViewDesc changed = first_record.desc;
            changed.render_scale = frame == 40 ? 0.75f : 1;
            render::configure_view(renderer, first.view, changed)!!;
            assert(!first_record.history.valid);
            changed = second_record.desc;
            changed.render_scale = frame == 40 ? 0.5f : 1;
            render::configure_view(renderer, second.view, changed)!!;
            assert(!second_record.history.valid);
            render::resize_render_target(
                renderer: renderer,
                target: first_copy,
                width: first_record.hdr_color.width,
                height: first_record.hdr_color.height,
            )!!;
            render::resize_render_target(
                renderer: renderer,
                target: second_copy,
                width: second_record.hdr_color.width,
                height: second_record.hdr_color.height,
            )!!;
        }
        bool abandon = frame == 17 || frame == 53 || frame == 89;
        Vec4[] previous_first;
        Vec4[] previous_second;
        if (abandon) {
            previous_first = read_layered_motion_target(&fixture, first_copy)!!;
            previous_second = read_layered_motion_target(&fixture, second_copy)!!;
        }
        defer free(previous_first);
        defer free(previous_second);
        uint first_sample = first_record.history.sample_index;
        uint second_sample = second_record.history.sample_index;
        FrameInfo info = { .time = (double)frame / 60, .delta = 1.0f / 60 };
        renderer.begin_frame(info)!!;
        renderer.render_view(&target.scene, target.camera, first.view)!!;
        renderer.finish_view(first.view)!!;
        record_layered_motion_copy(renderer, first_record, first_copy);
        renderer.render_view(&target.scene, target.camera, second.view)!!;
        renderer.finish_view(second.view)!!;
        record_layered_motion_copy(renderer, second_record, second_copy);
        if (abandon) {
            render::abort_frame(renderer);
            assert(first_record.history.sample_index == first_sample);
            assert(second_record.history.sample_index == second_sample);
            Vec4[] untouched_first = read_layered_motion_target(&fixture, first_copy)!!;
            defer free(untouched_first);
            Vec4[] untouched_second = read_layered_motion_target(&fixture, second_copy)!!;
            defer free(untouched_second);
            check_layered_pixel_bits(untouched_first, previous_first);
            check_layered_pixel_bits(untouched_second, previous_second);
            renderer.begin_frame(info)!!;
            renderer.render_view(&target.scene, target.camera, first.view)!!;
            renderer.finish_view(first.view)!!;
            record_layered_motion_copy(renderer, first_record, first_copy);
            renderer.render_view(&target.scene, target.camera, second.view)!!;
            renderer.finish_view(second.view)!!;
            record_layered_motion_copy(renderer, second_record, second_copy);
            aborted++;
        }
        renderer.end_frame()!!;
        assert(first_record.history.valid && second_record.history.valid);
        Vec4[] current_first = read_layered_motion_target(&fixture, first_copy)!!;
        defer free(current_first);
        Vec4[] current_second = read_layered_motion_target(&fixture, second_copy)!!;
        defer free(current_second);
        check_layered_motion_pixels(
            pixels: current_first,
            width: first_record.hdr_color.width,
            height: first_record.hdr_color.height,
            frame: frame,
            sample: first_sample,
            mode: first_record.desc.transparency.mode,
        );
        check_layered_motion_pixels(
            pixels: current_second,
            width: second_record.hdr_color.width,
            height: second_record.hdr_color.height,
            frame: frame,
            sample: second_sample,
            mode: second_record.desc.transparency.mode,
        );
        Vec4[] history_first = read_layered_lifetime_output(&fixture, &first)!!;
        defer free(history_first);
        Vec4[] history_second = read_layered_lifetime_output(&fixture, &second)!!;
        defer free(history_second);
        foreach (pixel : history_first) foreach (channel : pixel) assert(math::is_finite(channel));
        foreach (pixel : history_second) foreach (channel : pixel) assert(math::is_finite(channel));
    }
    assert(quality_changes == 6 && aborted == 3);
    io::printfn("layered moving temporal frames=%s extents=128x128,257x129 quality_changes=%s retries=%s",
        LAYERED_LIFETIME_TEMPORAL_FRAMES, quality_changes, aborted);
    check_validation(renderer);
}
