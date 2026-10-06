module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::platform;
import c3d::render @public;
import c3d::render::post @public;
import c3d::scene;
import gpu;
import sdl;
import std::io;

const uint RESIZE_TABLE @private = 96; // the fixture holds about 30 entries with one TAA view; fillers take the rest
const uint RESIZE_HEAP @private = 96; // the fixture holds about 30 heap slots with one TAA view
const uint RESIZE_EXTENT @private = 2 * TARGET_SIZE;
const float RESIZE_SCALE @private = 0.5f;
const uint RESIZE_HISTORY_FRAMES @private = 3; // publishes the TAA history and advances its sample index
const uint RESIZE_FREE_HEAP_SLOTS @private = 2; // two bloom levels fit; the chain's third level faults
const uint RESIZE_WINDOW @private = 256;
const uint RESIZE_WINDOW_GROWN @private = 320;
const String RESIZE_WINDOW_CASE @private = "test_window_resize_at_a_full_table_keeps_the_window_view";

struct ResizeTargetState @private {
    gpu::TextureHandle texture;
    uint               width;
    uint               height;
    uint               revision;
}

struct ResizeViewState @private {
    gpu::TextureHandle color;
    uint[<2>]          extent;
    uint               images;
}

fn ResizeTargetState resize_target_state(Renderer* renderer, RenderTargetId target) @private {
    TargetRecord* record = renderer.targets.get(target);
    return {
        .texture  = record.target.texture,
        .width    = record.target.width,
        .height   = record.target.height,
        .revision = record.revision,
    };
}

fn ResizeViewState resize_view_state(Renderer* renderer, ViewId view) @private {
    ViewRecord* record = renderer.views.get(view);
    return {
        .color  = record.hdr_color.texture,
        .extent = renderer.view_extent(view)!!,
        .images = render::live_view_images(record),
    };
}

fn void resize_check_target(Renderer* renderer, RenderTargetId target, ResizeTargetState expected) @private {
    ResizeTargetState actual = resize_target_state(renderer, target);
    assert(actual.texture == expected.texture);
    assert(actual.width == expected.width && actual.height == expected.height);
    assert(actual.revision == expected.revision);
}

fn void resize_check_view(Renderer* renderer, ViewId view, ResizeViewState expected) @private {
    ResizeViewState actual = resize_view_state(renderer, view);
    assert(actual.color == expected.color);
    assert(actual.extent == expected.extent);
    assert(actual.images == expected.images);
}

fn void resize_check_history(ViewHistory* history, ViewHistory* pinned) @private {
    assert(history.valid);
    assert(history.sample_index == pinned.sample_index && history.slot == pinned.slot);
    assert(history.models.ptr == pinned.models.ptr && history.models.len == pinned.models.len);
}

fn uint? resize_render(Fixture* fixture, ViewId[] views, RenderTargetId target) @private {
    Renderer* renderer = &fixture.renderer;
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    foreach (view : views) {
        renderer.render_view(&fixture.scene, fixture.camera_node, view)!;
        renderer.finish_view(view)!;
    }
    sample(fixture, render::read_target(target))!;
    record_readback(fixture)!;
    renderer.end_frame()!;
    return read_pixel(fixture);
}

fn void? resize_grow_target(Renderer* renderer, RenderTargetId target) @private {
    return render::resize_render_target(
        renderer: renderer,
        target:   target,
        width:    RESIZE_EXTENT,
        height:   RESIZE_EXTENT,
    );
}

fn uint resize_fill(Renderer* renderer, RenderTargetId[] fillers, fault exhaustion) @private {
    uint count;
    while (true) {
        RenderTargetId? filler = capacity_add_target(renderer);
        if (catch excuse = filler) {
            assert(excuse == exhaustion);
            return count;
        }
        fillers[count] = filler;
        count++;
    }
}

fn uint resize_destroy_fillers(Renderer* renderer, RenderTargetId[] fillers, uint count) @private {
    foreach (filler : fillers[^count..]) render::destroy_render_target(renderer, filler)!!;
    return (uint)fillers.len - count;
}

fn void test_target_resize_at_a_full_table_changes_nothing() @test {
    Fixture fixture;
    create_fixture(
        allocator:          mem,
        fixture:            &fixture,
        max_render_targets: RESIZE_TABLE,
        texture_capacity:   RESIZE_TABLE,
    )!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    ViewId[1] views = { fixture.display_view };
    fill_frame(&fixture, fixture.storage_texture, WARM)!!;
    uint pixel = resize_render(&fixture, views[..], fixture.ldr_target)!!;
    ResizeTargetState target = resize_target_state(renderer, fixture.ldr_target);
    ResizeViewState view = resize_view_state(renderer, fixture.display_view);

    RenderTargetId[RESIZE_TABLE] fillers;
    uint filled = resize_fill(renderer, fillers[..], gpu::SLOT_TABLE_FULL);
    filled = resize_destroy_fillers(renderer, fillers[:filled], 1);
    CapacityCounts before = capacity_counts(renderer);
    if (catch excuse = resize_grow_target(renderer, fixture.ldr_target)) {
        assert(excuse == gpu::SLOT_TABLE_FULL);
    } else {
        assert(false, "a target and its view's images fit one free table entry");
    }
    capacity_check_counts(capacity_counts(renderer), before);
    resize_check_target(renderer, fixture.ldr_target, target);
    resize_check_view(renderer, fixture.display_view, view);
    assert(resize_render(&fixture, views[..], fixture.ldr_target)!! == pixel);

    resize_destroy_fillers(renderer, fillers[:filled], filled);
    resize_grow_target(renderer, fixture.ldr_target)!!;
    ResizeTargetState resized = resize_target_state(renderer, fixture.ldr_target);
    assert(resized.width == RESIZE_EXTENT && resized.revision == target.revision + 1);
    assert(renderer.view_extent(fixture.display_view)!! == (uint[<2>]){ RESIZE_EXTENT, RESIZE_EXTENT });
    resize_render(&fixture, views[..], fixture.ldr_target)!!;
    check_validation(renderer);
}

fn void test_target_resize_failing_on_its_second_view_changes_neither_view() @test {
    Fixture fixture;
    create_fixture(
        allocator:          mem,
        fixture:            &fixture,
        max_render_targets: RESIZE_TABLE,
        texture_capacity:   RESIZE_TABLE,
    )!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    enable_taa(&fixture, fixture.view)!!;
    ViewId[2] views = { fixture.view, fixture.second_view };
    fill_frame(&fixture, fixture.storage_texture, WARM)!!;
    for (uint frame = 0; frame < RESIZE_HISTORY_FRAMES; frame++) {
        resize_render(&fixture, views[..], fixture.hdr_target)!!;
    }
    uint pixel = resize_render(&fixture, views[..], fixture.hdr_target)!!;
    ViewRecord* first = renderer.views.get(fixture.view);
    ViewHistory history = first.history;
    ResizeTargetState target = resize_target_state(renderer, fixture.hdr_target);
    ResizeViewState first_view = resize_view_state(renderer, fixture.view);
    ResizeViewState second_view = resize_view_state(renderer, fixture.second_view);

    RenderTargetId[RESIZE_TABLE] fillers;
    uint filled = resize_fill(renderer, fillers[..], gpu::SLOT_TABLE_FULL);
    filled = resize_destroy_fillers(renderer, fillers[:filled], 1 + first_view.images);
    CapacityCounts before = capacity_counts(renderer);
    if (catch excuse = resize_grow_target(renderer, fixture.hdr_target)) {
        assert(excuse == gpu::SLOT_TABLE_FULL);
    } else {
        assert(false, "the second view's images fit the entries the target and the first view took");
    }
    capacity_check_counts(capacity_counts(renderer), before);
    resize_check_target(renderer, fixture.hdr_target, target);
    resize_check_view(renderer, fixture.view, first_view);
    resize_check_view(renderer, fixture.second_view, second_view);
    resize_check_history(&first.history, &history);
    assert(resize_render(&fixture, views[..], fixture.hdr_target)!! == pixel);

    resize_destroy_fillers(renderer, fillers[:filled], filled);
    resize_grow_target(renderer, fixture.hdr_target)!!;
    assert(renderer.view_extent(fixture.view)!! == (uint[<2>]){ RESIZE_EXTENT, RESIZE_EXTENT });
    assert(renderer.view_extent(fixture.second_view)!! == (uint[<2>]){ RESIZE_EXTENT, RESIZE_EXTENT });
    assert(!first.history.valid && !first.history.models.len);
    resize_render(&fixture, views[..], fixture.hdr_target)!!;
    check_validation(renderer);
}

fn void test_configure_resize_at_a_full_table_changes_nothing() @test {
    Fixture fixture;
    create_fixture(
        allocator:          mem,
        fixture:            &fixture,
        max_render_targets: RESIZE_TABLE,
        texture_capacity:   RESIZE_TABLE,
    )!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    enable_taa(&fixture, fixture.view)!!;
    ViewId[1] views = { fixture.view };
    fill_frame(&fixture, fixture.storage_texture, WARM)!!;
    for (uint frame = 0; frame < RESIZE_HISTORY_FRAMES; frame++) {
        resize_render(&fixture, views[..], fixture.hdr_target)!!;
    }
    uint pixel = resize_render(&fixture, views[..], fixture.hdr_target)!!;
    ViewRecord* record = renderer.views.get(fixture.view);
    ViewHistory history = record.history;
    ResizeViewState view = resize_view_state(renderer, fixture.view);
    ViewDesc desc = record.desc;
    desc.render_scale = RESIZE_SCALE;

    RenderTargetId[RESIZE_TABLE] fillers;
    uint filled = resize_fill(renderer, fillers[..], gpu::SLOT_TABLE_FULL);
    CapacityCounts before = capacity_counts(renderer);
    if (catch excuse = render::configure_view(renderer, fixture.view, desc)) {
        assert(excuse == gpu::SLOT_TABLE_FULL);
    } else {
        assert(false, "a view's images at half scale fit a full table");
    }
    capacity_check_counts(capacity_counts(renderer), before);
    assert(record.desc.render_scale == 1);
    resize_check_view(renderer, fixture.view, view);
    resize_check_history(&record.history, &history);
    assert(resize_render(&fixture, views[..], fixture.hdr_target)!! == pixel);

    resize_destroy_fillers(renderer, fillers[:filled], filled);
    render::configure_view(renderer, fixture.view, desc)!!;
    assert(record.desc.render_scale == RESIZE_SCALE);
    assert(renderer.view_extent(fixture.view)!! == view.extent / 2);
    assert(!record.history.valid && !record.history.models.len);
    resize_render(&fixture, views[..], fixture.hdr_target)!!;
    check_validation(renderer);
}

fn void test_in_place_configure_at_a_full_heap_keeps_the_configuration() @test {
    Fixture fixture;
    create_fixture(
        allocator:             mem,
        fixture:               &fixture,
        max_render_targets:    RESIZE_HEAP,
        texture_heap_capacity: RESIZE_HEAP,
    )!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    ViewRecord* record = renderer.views.get(fixture.view);
    ViewDesc occluded = record.desc;
    occluded.post.anti_aliasing = AntiAliasing.TAA;
    occluded.ambient_occlusion = render::AMBIENT_OCCLUSION_DEFAULT;
    render::configure_view(renderer, fixture.view, occluded)!!;
    ViewId[1] views = { fixture.view };
    fill_frame(&fixture, fixture.storage_texture, WARM)!!;
    uint pixel = resize_render(&fixture, views[..], fixture.hdr_target)!!;
    gpu::TextureHandle ao = record.ao.texture;
    gpu::TextureHandle taa = record.taa_color[0].texture;
    ResizeViewState view = resize_view_state(renderer, fixture.view);
    ViewDesc bloomed = occluded;
    bloomed.ambient_occlusion.kind = AoKind.NONE;
    bloomed.post.bloom = true;

    RenderTargetId[RESIZE_HEAP] fillers;
    uint filled = resize_fill(renderer, fillers[..], gpu::DESCRIPTOR_HEAP_FULL);
    filled = resize_destroy_fillers(renderer, fillers[:filled], RESIZE_FREE_HEAP_SLOTS);
    CapacityCounts before = capacity_counts(renderer);
    if (catch excuse = render::configure_view(renderer, fixture.view, bloomed)) {
        assert(excuse == gpu::DESCRIPTOR_HEAP_FULL);
    } else {
        assert(false, "the bloom chain fit two free heap slots");
    }
    capacity_check_counts(capacity_counts(renderer), before);
    assert(record.desc.ambient_occlusion.kind == AoKind.SSAO && !record.desc.post.bloom);
    assert(record.ao.texture == ao && record.taa_color[0].texture == taa && !record.bloom_levels);
    resize_check_view(renderer, fixture.view, view);
    assert(resize_render(&fixture, views[..], fixture.hdr_target)!! == pixel);

    resize_destroy_fillers(renderer, fillers[:filled], filled);
    render::configure_view(renderer, fixture.view, bloomed)!!;
    assert(record.bloom_levels == bloomed.post.bloom_params.levels && !record.ao.texture.is_valid());
    assert(record.taa_color[0].texture == taa && record.hdr_color.texture == view.color);
    resize_render(&fixture, views[..], fixture.hdr_target)!!;
    check_validation(renderer);
}

fn void test_faulting_configure_keeps_the_exposure_state() @test {
    Fixture fixture;
    create_fixture(
        allocator:             mem,
        fixture:               &fixture,
        max_render_targets:    RESIZE_HEAP,
        texture_heap_capacity: RESIZE_HEAP,
    )!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    ExposureScene scene = exposure_create_scene(&fixture, EXPOSURE_DIM_LUMINANCE)!!;
    defer scene::destroy_scene(&scene.scene);
    ViewId view = exposure_create_view(&fixture, post::AUTO_EXPOSURE_DEFAULT)!!;
    exposure_render_frames(&scene, view, 0, RESIZE_HISTORY_FRAMES)!!;
    ViewRecord* record = renderer.views.get(view);
    ViewExposure* exposure = &record.auto_exposure;
    ExposureHistory history = exposure.history;
    bool[render::FRAMES_IN_FLIGHT] pending = exposure.readback_pending;
    bool any_pending;
    foreach (flag : pending) any_pending = any_pending || flag;
    assert(history.valid && any_pending);
    ViewDesc manual = record.desc;
    manual.post.auto_exposure = false;
    manual.post.bloom = true;

    RenderTargetId[RESIZE_HEAP] fillers;
    uint filled = resize_fill(renderer, fillers[..], gpu::DESCRIPTOR_HEAP_FULL);
    filled = resize_destroy_fillers(renderer, fillers[:filled], RESIZE_FREE_HEAP_SLOTS);
    if (catch excuse = render::configure_view(renderer, view, manual)) {
        assert(excuse == gpu::DESCRIPTOR_HEAP_FULL);
    } else {
        assert(false, "the bloom chain fit two free heap slots");
    }
    assert(record.desc.post.auto_exposure && !record.desc.post.bloom);
    assert(exposure.readback_pending == pending);
    assert(exposure.history.valid == history.valid && exposure.history.pending == history.pending);
    assert(exposure.history.slot == history.slot && exposure.history.time == history.time);
    exposure_render_frame(&scene, view, EXPOSURE_FRAME_SECONDS * RESIZE_HISTORY_FRAMES)!!;

    resize_destroy_fillers(renderer, fillers[:filled], filled);
    render::configure_view(renderer, view, manual)!!;
    assert(!record.desc.post.auto_exposure && record.desc.post.bloom);
    bool[render::FRAMES_IN_FLIGHT] none;
    assert(exposure.readback_pending == none);
    check_validation(renderer);
}

fn void test_window_resize_at_a_full_table_keeps_the_window_view() @test {
    platform::Window? opened = platform::create_window(
        platform::default_window_desc("c3d resize", RESIZE_WINDOW, RESIZE_WINDOW));
    if (catch excuse = opened) {
        io::eprintfn("%s: skipped, no window (%s)", RESIZE_WINDOW_CASE, excuse);
        return;
    }
    platform::Window window = opened;
    defer platform::destroy_window(&window);
    AssetStore assets = capacity_assets();
    defer asset::destroy_asset_store(&assets);
    Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      {
            .validation         = true,
            .application_name   = "render_acceptance",
            .max_render_targets = RESIZE_TABLE,
            .texture_capacity   = RESIZE_TABLE,
        },
    )!!;
    defer render::destroy_renderer(&renderer);
    window.poll();
    platform::sync_window(&window, &renderer);
    renderer.begin_frame()!!;
    renderer.end_frame()!!;
    ResizeViewState view = resize_view_state(&renderer, renderer.default_view);
    if (!view.color.is_valid()) {
        io::eprintfn("%s: skipped, no window output", RESIZE_WINDOW_CASE);
        return;
    }

    RenderTargetId[RESIZE_TABLE] fillers;
    uint filled = resize_fill(&renderer, fillers[..], gpu::SLOT_TABLE_FULL);
    sdl::set_window_size(window.handle, (int)RESIZE_WINDOW_GROWN, (int)RESIZE_WINDOW_GROWN);
    sdl::sync_window(window.handle);
    window.poll();
    platform::sync_window(&window, &renderer);
    if (!renderer.output_dirty) {
        io::eprintfn("%s: skipped, the window kept its size", RESIZE_WINDOW_CASE);
        return;
    }
    if (catch excuse = renderer.begin_frame()) {
        assert(excuse == gpu::SLOT_TABLE_FULL);
    } else {
        assert(false, "the window view's images fit a full table");
    }
    assert(!renderer.frame_open && renderer.output_dirty);
    resize_check_view(&renderer, renderer.default_view, view);
    uint[<2>] rebuilt = { renderer.swapchain_info.width, renderer.swapchain_info.height };
    assert(!renderer.swapchain_info.dormant);
    assert(rebuilt == (uint[<2>]){ renderer.output_width, renderer.output_height });
    assert(rebuilt != view.extent);

    resize_destroy_fillers(&renderer, fillers[:filled], filled);
    renderer.begin_frame()!!;
    renderer.end_frame()!!;
    assert(!renderer.output_dirty);
    uint[<2>] output = { renderer.swapchain_info.width, renderer.swapchain_info.height };
    assert(renderer.view_extent(renderer.default_view)!! == output);
    io::eprintfn("%s: resized to %s", RESIZE_WINDOW_CASE, output);
    check_validation(&renderer);
}
