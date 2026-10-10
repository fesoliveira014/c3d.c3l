module c3d::render::acceptance;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::model;
import c3d::platform @public;
import c3d::render @public;
import c3d::scene;
import gpu;
import std::io;
import std::math;
import std::time::clock;

const uint LOD_PRESENT_ATTEMPTS @private = 16;
const ulong LOD_PRESENT_DEADLINE_NS @private = 10_000_000_000;
const uint LOD_PRESENT_WINDOW_SIZE @private = 256;
const uint LOD_PRESENT_RESIZED_SIZE @private = 320;
const int LOD_PRESENT_OUT_OF_DATE @private = -1000001004;

fn DebugEntry? animated_lod_present_fault(Renderer* renderer, usz first) @private {
    usz after = renderer.log.written.load();
    if (after - first > render::DEBUG_LOG_ENTRIES) return c3d::CAPACITY_EXCEEDED~;
    for (usz sequence = first; sequence < after; sequence++) {
        DebugEntry entry = renderer.log.entries[sequence % render::DEBUG_LOG_ENTRIES];
        String operation = ((ZString)&entry.operation[0]).str_view();
        if (operation != "present" || !entry.category.backend || !entry.has_fault) continue;
        if (entry.public_fault == gpu::SWAPCHAIN_OUT_OF_DATE
          && entry.validation_id_number == LOD_PRESENT_OUT_OF_DATE) return entry;
    }
    return NOT_FOUND~;
}

fn ModelId? create_animated_lod_publication_pair(Fixture* fixture, CrowdNativePair* pair) @private {
    ModelId model_id = load_crowd_native_cc0(
        fixture: fixture,
        filename: CROWD_NATIVE_MORPH_CUBE,
        expected_hash: CROWD_NATIVE_MORPH_CUBE_SHA,
    )!;
    crowd_native_flat_source_materials(fixture, model_id);
    ModelTemplate* template = &fixture.assets.model(model_id).data;
    Transform[CROWD_NATIVE_INSTANCES] placements = crowd_native_real_placements();
    foreach (&placement : placements) placement.scale *= 0.6f;
    create_crowd_native_pair(
        allocator: mem,
        fixture: fixture,
        pair: pair,
        model: model_id,
        clip: template.clips[0],
        bounds: { .min = { -2, -2, -2 }, .max = { 2, 2, 2 } },
        placements: placements[..],
    )!;
    *pair.scene.get(pair.camera, Camera) = camera::orthographic(5, 0.1f, 100);
    pair.camera.local.position = { 0, 0, 12 };
    set_animated_lod_native_motion(
        fixture: fixture,
        pair: pair,
        phase_offset: 0,
        placement_offset: 0,
    );
    @pool() {
        model::attach_animated_lod(
            assets: &fixture.assets,
            scene: &pair.scene,
            owner: pair.crowd,
            desc: lod_trace_desc(&fixture.assets, model_id),
        )!;
    };
    return model_id;
}

fn void test_animated_lod_native_resize_present_failure_keeps_submitted_history() @test {
    platform::Window window = platform::create_window(platform::default_window_desc(
        "Animated LOD presentation", LOD_PRESENT_WINDOW_SIZE, LOD_PRESENT_WINDOW_SIZE))!!;
    defer platform::destroy_window(&window);
    Fixture fixture = {
        .allocator = mem,
        .assets = asset::create_asset_store(mem, asset::default_asset_store_desc()),
    };
    defer asset::destroy_asset_store(&fixture.assets);
    fixture.renderer = platform::create_window_renderer(
        allocator: mem,
        window: &window,
        assets: &fixture.assets,
        desc: { .validation = true, .application_name = "animated_lod_publication" },
    )!!;
    defer {
        render::wait_frames(&fixture.renderer)!!;
        check_crowd_native_validation(&fixture.renderer);
        render::destroy_renderer(&fixture.renderer);
    }
    CrowdNativePair pair;
    create_animated_lod_publication_pair(&fixture, &pair)!!;
    defer scene::destroy_scene(&pair.scene);
    CrowdNativeOutput[2] outputs;
    for (uint index = 0; index < outputs.len; index++) {
        create_crowd_native_output(&fixture, &outputs[index])!!;
        configure_crowd_native_temporal(&fixture, &outputs[index])!!;
    }
    defer foreach (&output : outputs) destroy_crowd_native_output(&fixture, output);
    for (uint frame = 0; frame < 2; frame++) {
        animated_lod_native_temporal_frame(
            fixture: &fixture,
            pair: &pair,
            crowd: &outputs[0],
            ordinary: &outputs[1],
        )!!;
    }
    Renderer* renderer = &fixture.renderer;
    ViewRecord* actual = renderer.views.get(outputs[0].view);
    ViewRecord* reference = renderer.views.get(outputs[1].view);
    LodGroupState* state = pair.scene.get(pair.crowd, LodGroup).state;
    std::time::Clock started = clock::now();
    bool observed;
    uint attempted;
    for (uint attempt = 0; attempt < LOD_PRESENT_ATTEMPTS; attempt++) {
        if ((ulong)started.to_now() >= LOD_PRESENT_DEADLINE_NS) break;
        attempted++;
        if (!window.poll()) break;
        platform::sync_window(&window, renderer);
        set_animated_lod_native_motion(
            fixture: &fixture,
            pair: &pair,
            phase_offset: 0.003f * (float)(attempt + 1),
            placement_offset: 0.08f * (float)(attempt + 1),
        );
        renderer.begin_frame({ .time = 0.37, .delta = 0 })!!;
        if (!renderer.has_output) {
            renderer.end_frame()!!;
            continue;
        }
        ulong actual_serial = actual.history.serial;
        ulong reference_serial = reference.history.serial;
        gpu::CompletionPoint before_submit = renderer.last_submission;
        for (uint source = 0; source < 2; source++) {
            record_crowd_native_temporal_view(
                fixture: &fixture,
                pair: &pair,
                output: &outputs[source],
                crowd_visible: source == 0,
            )!!;
        }
        assert(actual.history.pending && reference.history.pending);
        LodHistoryEntry* selection = &actual.lod_history.entries[pair.crowd.id.index];
        assert(selection.dirty && selection.pending.identity == state.identity);
        usz first_diagnostic = renderer.log.written.load();
        uint size = attempt % 2 == 0 ? LOD_PRESENT_RESIZED_SIZE : LOD_PRESENT_WINDOW_SIZE;
        if (catch excuse = platform::resize_preparation_present_window(&window, size, size)) {
            render::abort_frame(renderer);
            io::eprintfn("INCONCLUSIVE: native LOD presentation resize failed: %s", excuse);
            break;
        }
        platform::sync_window(&window, renderer);
        fault ended = @catch(renderer.end_frame());
        gpu::CompletionPoint submitted = renderer.last_submission;
        assert(renderer.frame_submitted && submitted.is_valid() && submitted != before_submit);
        assert(actual.history.valid && !actual.history.pending && actual.history.serial == actual_serial + 1);
        assert(reference.history.valid && !reference.history.pending
          && reference.history.serial == reference_serial + 1);
        assert(!selection.dirty && selection.committed.valid && selection.committed.identity == state.identity);
        PoseRecord* owner = &actual.history.poses[pair.crowd.id.index];
        assert(owner.animated_lod && owner.animated_lod.seen == actual.history.serial);
        assert(owner.animated_lod.parts[0].seen == actual.history.serial);
        DebugEntry? present = animated_lod_present_fault(renderer, first_diagnostic);
        if (try entry = present) {
            observed = true;
            assert(!ended || ended == gpu::SWAPCHAIN_OUT_OF_DATE);
            io::eprintfn("LOD_PRESENT_FAILURE_OBSERVED native_result=%s", entry.validation_id_number);
            io::eprintfn("submitted completion_payload=%s", submitted.payload);
            io::eprintfn("committed animated history serial=%s", actual.history.serial);
        } else {
            if (ended) io::eprintfn("INCONCLUSIVE: unexpected post-submit LOD frame fault: %s", ended);
        }
        render::wait_frames(renderer)!!;
        for (uint source = 0; source < 2; source++) read_crowd_native_temporal(&fixture, &outputs[source])!!;
        float movement = check_animated_lod_native_view_motion(
            outputs: outputs[..],
            view: 0,
            rejection: 0,
            still: false,
        );
        assert(movement > CROWD_NATIVE_VELOCITY_TOLERANCE);
        check_crowd_native_validation(renderer);
        if (!observed) continue;
        assert(window.poll());
        platform::sync_window(&window, renderer);
        ulong published_serial = actual.history.serial;
        animated_lod_native_temporal_frame(
            fixture: &fixture,
            pair: &pair,
            crowd: &outputs[0],
            ordinary: &outputs[1],
        )!!;
        (void)check_animated_lod_native_view_motion(
            outputs: outputs[..],
            view: 0,
            rejection: 0,
            still: true,
        );
        assert(actual.history.valid && actual.history.serial == published_serial + 1);
        break;
    }
    check_crowd_native_validation(renderer);
    io::eprintfn("animated_lod_presentation_attempts=%s", attempted);
    if (!observed) io::eprintfn("INCONCLUSIVE: no native present ERROR_OUT_OF_DATE_KHR observed.");
    assert(observed, "INCONCLUSIVE: post-submit animated LOD history publication remains unproven.");
}

fn void test_animated_lod_native_admitted_channel_metadata_edit_rejects_current_pose() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    ModelId model_id = load_crowd_native_cc0(
        fixture: &fixture,
        filename: CROWD_NATIVE_MORPH_CUBE,
        expected_hash: CROWD_NATIVE_MORPH_CUBE_SHA,
    )!!;
    crowd_native_flat_source_materials(&fixture, model_id);
    ModelTemplate* template = &fixture.assets.model(model_id).data;
    assert(template.meshes.len == 1 && template.meshes[0].default_morph_weights.len == 2);
    GeometryId original = template.meshes[0].geometry;
    GeometryId selected;
    @pool() {
        Geometry named = fixture.assets.geometry(original).data;
        assert(named.targets.len == 2);
        named.channels = alloc::new_array(tmem, MorphChannel, 2);
        String[2] names = { "square", "cube" };
        foreach (uint index, &channel : named.channels) {
            *channel = {
                .name = names[index],
                .first_target = index,
                .full_weights = alloc::new_array(tmem, float, 1),
            };
            channel.full_weights[0] = 1;
        }
        template.meshes[0].geometry = fixture.assets.add_geometry(&named)!!;
        selected = fixture.assets.add_geometry(&named)!!;
    };
    CrowdNativePair pair;
    Transform[CROWD_NATIVE_INSTANCES] placements = crowd_native_real_placements();
    foreach (&placement : placements) placement.scale *= 0.6f;
    create_crowd_native_pair(
        allocator: mem,
        fixture: &fixture,
        pair: &pair,
        model: model_id,
        clip: template.clips[0],
        bounds: { .min = { -2, -2, -2 }, .max = { 2, 2, 2 } },
        placements: placements[..],
    )!!;
    defer scene::destroy_scene(&pair.scene);
    *pair.scene.get(pair.camera, Camera) = camera::orthographic(5, 0.1f, 100);
    pair.camera.local.position = { 0, 0, 12 };
    crowd_native_phase(&pair, 0.5f)!!;
    crowd_native_update(&fixture, &pair, 0);
    @pool() {
        AnimatedLodDesc desc = lod_trace_desc(&fixture.assets, model_id);
        desc.parts[1].draw.geometry = selected;
        model::attach_animated_lod(
            assets: &fixture.assets,
            scene: &pair.scene,
            owner: pair.crowd,
            desc: desc,
        )!!;
    };
    set_animated_lod_native_reference_geometry(&pair, template, selected);
    CrowdNativeOutput[2] outputs;
    for (uint index = 0; index < outputs.len; index++) {
        create_crowd_native_output(&fixture, &outputs[index])!!;
        configure_crowd_native_temporal(&fixture, &outputs[index])!!;
        ViewDesc desc = fixture.renderer.views.get(outputs[index].view).desc;
        desc.lod_bias = -16;
        render::configure_view(&fixture.renderer, outputs[index].view, desc)!!;
    }
    defer foreach (&output : outputs) destroy_crowd_native_output(&fixture, output);
    for (uint frame = 0; frame < 2; frame++) {
        animated_lod_native_temporal_frame(
            fixture: &fixture,
            pair: &pair,
            crowd: &outputs[0],
            ordinary: &outputs[1],
        )!!;
        (void)check_animated_lod_native_view_motion(
            outputs: outputs[..],
            view: 0,
            rejection: frame ? 0 : 1,
            still: true,
        );
    }
    LodGroupState* state = pair.scene.get(pair.crowd, LodGroup).state;
    ulong identity = state.identity;
    uint descriptor_revision = state.descriptor_revision;
    AnimatedCrowd* crowd = pair.scene.get(pair.crowd, AnimatedCrowd);
    float[] weights = crowd.playback.logical_weights[0];
    MorphSelection before = geometry::select_morph_targets(fixture.assets.geometry(selected).data.channels, weights);
    uint vertices = fixture.assets.geometry(selected).vertex_count;
    uint indices = fixture.assets.geometry(selected).index_count;
    uint revision = fixture.assets.geometry(selected).header.revision;
    @pool() {
        Geometry changed = fixture.assets.geometry(selected).data;
        changed.channels = alloc::clone_slice(tmem, changed.channels);
        foreach (&channel : changed.channels) {
            channel.full_weights = alloc::clone_slice(tmem, channel.full_weights);
            channel.full_weights[0] = 0.75f;
        }
        fixture.assets.replace_geometry(selected, &changed)!!;
    };
    assert(fixture.assets.geometry(selected).header.revision != revision);
    assert(fixture.assets.geometry(selected).vertex_count == vertices
      && fixture.assets.geometry(selected).index_count == indices);
    MorphSelection after = geometry::select_morph_targets(fixture.assets.geometry(selected).data.channels, weights);
    assert(!mem::equals(&before, &after, MorphSelection::size),
      "Channel metadata mutation must change packed weights.");
    model::sync_animated_lod(&fixture.assets, &pair.scene, pair.crowd)!!;
    assert(state.identity == identity && state.descriptor_revision == descriptor_revision);
    animated_lod_native_temporal_frame(
        fixture: &fixture,
        pair: &pair,
        crowd: &outputs[0],
        ordinary: &outputs[1],
    )!!;
    (void)check_animated_lod_native_view_motion(
        outputs: outputs[..],
        view: 0,
        rejection: 1,
        still: true,
    );
    animated_lod_native_temporal_frame(
        fixture: &fixture,
        pair: &pair,
        crowd: &outputs[0],
        ordinary: &outputs[1],
    )!!;
    (void)check_animated_lod_native_view_motion(
        outputs: outputs[..],
        view: 0,
        rejection: 0,
        still: true,
    );
    check_crowd_native_validation(&fixture.renderer);
}
