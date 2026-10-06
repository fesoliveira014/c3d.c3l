module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::material;
import c3d::platform;
import c3d::render @public;
import c3d::scene;
import gpu;
import std::io;
import std::math;

const uint CAPACITY_RAISED_VIEWS @private = 32;
const uint CAPACITY_RAISED_TARGETS @private = 64;
const uint CAPACITY_HIGH_INDEX @private = 32; // the first target index past one 32-bit word of flags
const uint CAPACITY_HIGH_TARGETS @private = 40;
const uint CAPACITY_SMALL_TABLE @private = 96; // the fixture holds 22 entries, so about 70 targets fill it
const uint CAPACITY_SMALL_HEAP @private = 96;
const uint CAPACITY_WARM_FRAMES @private = 2;
const uint CAPACITY_MEASURED_FRAMES @private = 2;
const uint CAPACITY_WINDOW_SIZE @private = 256;
const uint CAPACITY_WINDOW_FRAMES @private = 3;
const float CAPACITY_DOMINANT @private = 0.5f; // the filled channel; the other two stay under CAPACITY_FAINT
const float CAPACITY_FAINT @private = 0.25f;
const Vec2 CAPACITY_RECT_SIZE @private = { 64, 64 };
const String CAPACITY_OVERLAY_CASE @private = "test_overlay_and_material_sample_one_target_past_index_thirty_two";

struct CapacityCounts @private {
    ulong textures;
    ulong texture_views;
    uint  free_views;
    uint  free_targets;
}

struct CapacitySampling @private {
    RenderTargetId    sampled;
    RenderTargetId[2] outputs;
    ViewId[2]         views;
    DeformedScene     consumer;
}

fn CapacityCounts capacity_counts(Renderer* renderer) @private {
    gpu::MemoryStats memory = gpu::get_memory_stats(&renderer.device)!!;
    return {
        .textures      = memory.texture_count,
        .texture_views = memory.texture_view_count,
        .free_views    = renderer.views.free_count,
        .free_targets  = renderer.targets.free_count,
    };
}

fn void capacity_check_counts(CapacityCounts actual, CapacityCounts expected) @private {
    assert(actual.textures == expected.textures);
    assert(actual.texture_views == expected.texture_views);
    assert(actual.free_views == expected.free_views);
    assert(actual.free_targets == expected.free_targets);
}

fn RenderTargetId? capacity_add_target(Renderer* renderer) @private {
    return render::create_render_target(renderer, render::render_target_desc(TARGET_SIZE, TARGET_SIZE));
}

fn RenderTargetId? capacity_target_at(Renderer* renderer, uint index) @private {
    while (true) {
        RenderTargetId target = capacity_add_target(renderer)!;
        if (target.index == index) return target;
    }
}

fn Vec4? capacity_center(Renderer* renderer, RenderTargetId target) @private {
    Vec4[TARGET_SIZE * TARGET_SIZE] pixels;
    renderer.read_render_target(target, ((char*)&pixels)[:pixels.len * Vec4::size])!;
    return pixels[TARGET_SIZE / 2 * TARGET_SIZE + TARGET_SIZE / 2];
}

fn void capacity_check_dominant(Vec4 color, uint channel) @private {
    for (uint other = 0; other < 3; other++) {
        assert(other == channel ? color[other] > CAPACITY_DOMINANT : color[other] < CAPACITY_FAINT);
    }
}

fn void? capacity_advance_to_reading(Renderer* renderer) @private {
    do {
        renderer.begin_frame()!;
        renderer.end_frame()!;
    } while (renderer.frame_index % render::TEXTURE_STATS_INTERVAL != 1);
}

fn AssetStore capacity_assets() @private {
    return asset::create_asset_store(mem, asset::default_asset_store_desc());
}

fn void capacity_expect_creation_fault(RendererDesc desc, fault expected) @private {
    AssetStore assets = capacity_assets();
    defer asset::destroy_asset_store(&assets);
    desc.validation = true;
    desc.application_name = "render_acceptance";
    Renderer? renderer = render::create_renderer(mem, &assets, desc);
    if (try created = renderer) render::destroy_renderer(&created);
    assert(@catch(renderer) == expected);
}

fn CapacitySampling? capacity_sampling(Fixture* fixture) @private {
    Renderer* renderer = &fixture.renderer;
    CapacitySampling sampling = { .sampled = capacity_target_at(renderer, CAPACITY_HIGH_INDEX)! };
    foreach (index, &output : sampling.outputs) {
        *output = render::create_render_target(
            renderer: renderer,
            desc:     render::render_target_desc(TARGET_SIZE, TARGET_SIZE, PixelFormat.RGBA32_FLOAT),
        )!;
        sampling.views[index] = render::create_view(renderer, render::texture_view_desc(*output))!;
    }
    return sampling;
}

fn DeformedScene? capacity_consumer_scene(Fixture* fixture, MaterialId material) @private {
    DeformedScene result;
    result.scene = scene::create_scene(fixture.allocator, scene::default_scene_desc());
    defer catch scene::destroy_scene(&result.scene);
    // Two meshes of one material, so each view resolves it once and then hits its cache.
    result.mesh = result.scene.add_mesh(fixture.box, material)!;
    Node* behind = result.scene.add_mesh(fixture.box, material)!;
    behind.local.position = { 0, 0, -1 };
    result.camera = result.scene.add_camera(camera::perspective_deg(60, 0.1f))!;
    result.camera.local.position = CAMERA_POSITION;
    result.scene.update_world();
    return result;
}

fn void? capacity_fill_target(Fixture* fixture, RenderTargetId target, Vec4 color) @private {
    FillRoot root = { .color = color, .size = TARGET_SIZE };
    DispatchTexture[1] textures = { render::write_target(target) };
    uint groups = TARGET_SIZE / FILL_GROUP_SIZE;
    return fixture.renderer.dispatch({
        .shader = fixture.fill_shader,
        .root = ((char*)&root)[:FillRoot::size],
        .groups = { groups, groups, 1 },
        .textures = textures[..],
    });
}

fn void? capacity_render_sampling_frame(Fixture* fixture, CapacitySampling* sampling) @private {
    Renderer* renderer = &fixture.renderer;
    TargetRecord* sampled = renderer.targets.get(sampling.sampled);
    Vec4[2] colors = { RED, GREEN };
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    foreach (index, view : sampling.views) {
        capacity_fill_target(fixture, sampling.sampled, colors[index])!;
        renderer.render_view(&sampling.consumer.scene, sampling.consumer.camera, view)!;
        assert(render::same_texture_state(sampled.target.state, renderer.sampled_state));
        renderer.finish_view(view)!;
    }
    return renderer.end_frame();
}

fn void capacity_check_sampling(Fixture* fixture, CapacitySampling* sampling) @private {
    capacity_check_dominant(capacity_center(&fixture.renderer, sampling.outputs[0])!!, 0);
    capacity_check_dominant(capacity_center(&fixture.renderer, sampling.outputs[1])!!, 1);
    check_validation(&fixture.renderer);
}

fn void test_raised_capacities_hold_every_view_and_target() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    Fixture fixture;
    create_fixture(
        allocator:          &tracker,
        fixture:            &fixture,
        max_views:          CAPACITY_RAISED_VIEWS,
        max_render_targets: CAPACITY_RAISED_TARGETS,
    )!!;
    Renderer* renderer = &fixture.renderer;
    assert(renderer.views.items.len == CAPACITY_RAISED_VIEWS);
    assert(renderer.targets.items.len == CAPACITY_RAISED_TARGETS);

    RenderTargetId[CAPACITY_RAISED_TARGETS] targets;
    uint target_count;
    while (renderer.targets.free_count) {
        targets[target_count] = capacity_add_target(renderer)!!;
        target_count++;
    }
    ViewId[CAPACITY_RAISED_VIEWS] views;
    uint view_count;
    while (renderer.views.free_count) {
        views[view_count] = render::create_view(renderer, render::texture_view_desc(targets[view_count]))!!;
        view_count++;
    }
    if (catch excuse = render::create_view(renderer, render::texture_view_desc(targets[0]))) {
        assert(excuse == c3d::CAPACITY_EXCEEDED);
    } else {
        assert(false, "a full view pool accepted another view");
    }
    if (catch excuse = capacity_add_target(renderer)) {
        assert(excuse == c3d::CAPACITY_EXCEEDED);
    } else {
        assert(false, "a full target pool accepted another target");
    }

    fill_frame(&fixture, fixture.storage_texture, WARM)!!;
    sz allocations;
    for (uint frame = 0; frame < CAPACITY_WARM_FRAMES + CAPACITY_MEASURED_FRAMES; frame++) {
        if (frame == CAPACITY_WARM_FRAMES) allocations = tracker.total_allocation_count();
        renderer.begin_frame()!!;
        foreach (view : views[:view_count]) {
            renderer.render_view(&fixture.scene, fixture.camera_node, view)!!;
            renderer.finish_view(view)!!;
        }
        renderer.end_frame()!!;
    }
    assert(tracker.total_allocation_count() == allocations);
    sample_frame(&fixture, render::read_target(targets[view_count - 1]))!!;
    check_channels(read_pixel(&fixture), WARM);

    foreach (view : views[:view_count]) render::destroy_view(renderer, view)!!;
    foreach (target : targets[:target_count]) render::destroy_render_target(renderer, target)!!;
    destroy_fixture(&fixture);
    assert(!tracker.has_leaks());
}

fn void test_zeroed_capacities_keep_eight_views_eight_targets_and_gpu_defaults() @test {
    AssetStore assets = capacity_assets();
    defer asset::destroy_asset_store(&assets);
    Renderer renderer = render::create_renderer(
        allocator: mem,
        assets:    &assets,
        desc:      { .validation = true, .application_name = "render_acceptance" },
    )!!;
    defer render::destroy_renderer(&renderer);
    assert(renderer.views.items.len == render::DEFAULT_MAX_VIEWS);
    assert(renderer.targets.items.len == render::DEFAULT_MAX_RENDER_TARGETS);

    RenderTargetId first = capacity_add_target(&renderer)!!;
    for (uint index = 1; index < render::DEFAULT_MAX_RENDER_TARGETS; index++) {
        capacity_add_target(&renderer)!!;
    }
    if (catch excuse = capacity_add_target(&renderer)) {
        assert(excuse == c3d::CAPACITY_EXCEEDED);
    } else {
        assert(false, "a ninth target was accepted");
    }
    for (uint index = 1; index < render::DEFAULT_MAX_VIEWS; index++) {
        render::create_view(&renderer, render::texture_view_desc(first))!!;
    }
    if (catch excuse = render::create_view(&renderer, render::texture_view_desc(first))) {
        assert(excuse == c3d::CAPACITY_EXCEEDED);
    } else {
        assert(false, "an eighth view beside the default view was accepted");
    }

    renderer.begin_frame()!!;
    renderer.end_frame()!!;
    assert(renderer.stats.texture_capacity == gpu::DEFAULT_TEXTURE_CAPACITY);
    assert(renderer.stats.texture_heap_capacity == gpu::DEFAULT_TEXTURE_HEAP_CAPACITY);
    check_validation(&renderer);
}

fn void test_one_view_capacity_leaves_only_the_default_view() @test {
    AssetStore assets = capacity_assets();
    defer asset::destroy_asset_store(&assets);
    Renderer renderer = render::create_renderer(
        allocator: mem,
        assets:    &assets,
        desc:      { .validation = true, .application_name = "render_acceptance", .max_views = 1 },
    )!!;
    defer render::destroy_renderer(&renderer);
    assert(renderer.views.is_live(renderer.default_view) && !renderer.views.free_count);
    RenderTargetId target = capacity_add_target(&renderer)!!;
    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    Node* camera_node = scene.add_camera(camera::perspective_deg(60, 0.1f))!!;
    scene.update_world();

    CapacityCounts before = capacity_counts(&renderer);
    if (catch excuse = render::create_view(&renderer, render::texture_view_desc(target))) {
        assert(excuse == c3d::CAPACITY_EXCEEDED);
    } else {
        assert(false, "a second view was accepted");
    }
    if (catch excuse = renderer.render_to(&scene, camera_node, target)) {
        assert(excuse == c3d::CAPACITY_EXCEEDED);
    } else {
        assert(false, "render_to found a view slot");
    }
    assert(!renderer.frame_open);
    capacity_check_counts(capacity_counts(&renderer), before);
    check_validation(&renderer);
}

fn void test_two_views_sample_one_target_past_index_thirty_two() @test {
    Fixture fixture;
    create_fixture(mem, &fixture, max_render_targets: CAPACITY_HIGH_TARGETS)!!;
    defer destroy_fixture(&fixture);
    CapacitySampling sampling = capacity_sampling(&fixture)!!;
    MaterialId monitor = fixture.assets.add_material(material::basic({
        .color = { 1, 1, 1, 1 },
        .map   = { .texture = { .kind = RENDER_TARGET, .target = sampling.sampled } },
    }))!!;
    sampling.consumer = capacity_consumer_scene(&fixture, monitor)!!;
    defer scene::destroy_scene(&sampling.consumer.scene);

    capacity_render_sampling_frame(&fixture, &sampling)!!;
    capacity_check_sampling(&fixture, &sampling);
}

fn void test_reference_material_samples_its_layer_target_in_both_views() @test {
    Fixture fixture;
    create_fixture(mem, &fixture, max_render_targets: CAPACITY_HIGH_TARGETS)!!;
    defer destroy_fixture(&fixture);
    CapacitySampling sampling = capacity_sampling(&fixture)!!;
    StandardParams params = material::STANDARD_PARAMS_DEFAULT;
    params.base_color = { 0, 0, 0, 1 };
    params.emissive = { 1, 1, 1 };
    params.emissive_map.texture = { .kind = RENDER_TARGET, .target = sampling.sampled };
    MaterialId layer = fixture.assets.add_material(material::standard(params))!!;
    ShaderId shader = add_reference_shader(&fixture)!!;
    MaterialId custom = fixture.assets.add_material(material::custom(shader, references: { [0] = layer }))!!;
    sampling.consumer = capacity_consumer_scene(&fixture, custom)!!;
    defer scene::destroy_scene(&sampling.consumer.scene);

    capacity_render_sampling_frame(&fixture, &sampling)!!;
    capacity_check_sampling(&fixture, &sampling);
}

fn void test_overlay_and_material_sample_one_target_past_index_thirty_two() @test {
    platform::Window? opened = platform::create_window(
        platform::default_window_desc("c3d capacities", CAPACITY_WINDOW_SIZE, CAPACITY_WINDOW_SIZE));
    if (catch excuse = opened) {
        io::eprintfn("%s: skipped, no window (%s)", CAPACITY_OVERLAY_CASE, excuse);
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
            .max_render_targets = CAPACITY_HIGH_TARGETS,
        },
    )!!;
    defer render::destroy_renderer(&renderer);

    RenderTargetId shared = capacity_target_at(&renderer, CAPACITY_HIGH_INDEX)!!;
    RenderTargetId overlay_only = capacity_add_target(&renderer)!!;
    RenderTargetId output = capacity_add_target(&renderer)!!;
    ViewId producer = render::create_view(&renderer, render::texture_view_desc(shared))!!;
    ViewId consumer = render::create_view(&renderer, render::texture_view_desc(output))!!;

    GeometryId box;
    @pool() {
        Geometry box_geometry = geometry::box(
            allocator: tmem,
            width:     1,
            height:    1,
            depth:     1,
        );
        box = assets.add_geometry(&box_geometry)!!;
    };
    MaterialId plain = assets.add_material(material::basic({ .color = RED }))!!;
    MaterialId monitor = assets.add_material(material::basic({
        .color = { 1, 1, 1, 1 },
        .map   = { .texture = { .kind = RENDER_TARGET, .target = shared } },
    }))!!;
    Scene source = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&source);
    source.add_mesh(box, plain)!!;
    Node* source_camera = source.add_camera(camera::perspective_deg(60, 0.1f))!!;
    source_camera.local.position = CAMERA_POSITION;
    source.update_world();
    Scene screen = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&screen);
    screen.add_mesh(box, monitor)!!;
    Node* screen_camera = screen.add_camera(camera::perspective_deg(60, 0.1f))!!;
    screen_camera.local.position = CAMERA_POSITION;
    screen.update_world();

    OverlayList list = render::create_overlay_list(mem, render::default_overlay_list_desc());
    defer render::destroy_overlay_list(&list);
    OverlayRect rect = render::OVERLAY_RECT_DEFAULT;
    rect.max = CAPACITY_RECT_SIZE;
    rect.texture = { .kind = RENDER_TARGET, .target = shared };
    list.add_rect(rect)!!;
    rect.min = { CAPACITY_RECT_SIZE.x, 0 };
    rect.max = { 2 * CAPACITY_RECT_SIZE.x, CAPACITY_RECT_SIZE.y };
    list.add_rect(rect)!!;
    rect.min = { 0, CAPACITY_RECT_SIZE.y };
    rect.max = { CAPACITY_RECT_SIZE.x, 2 * CAPACITY_RECT_SIZE.y };
    rect.texture.target = overlay_only;
    list.add_rect(rect)!!;

    Target* shared_image = &renderer.targets.get(shared).target;
    Target* overlay_image = &renderer.targets.get(overlay_only).target;
    uint overlay_frames;
    for (uint frame = 0; frame < CAPACITY_WINDOW_FRAMES; frame++) {
        window.poll();
        platform::sync_window(&window, &renderer);
        renderer.begin_frame()!!;
        renderer.render_view(&source, source_camera, producer)!!;
        renderer.finish_view(producer)!!;
        renderer.render_view(&screen, screen_camera, consumer)!!;
        renderer.finish_view(consumer)!!;
        assert(render::same_texture_state(shared_image.state, renderer.sampled_state));
        if (renderer.has_output) {
            renderer.prepare_overlay_list(&list)!!;
            assert(render::same_texture_state(shared_image.state, renderer.sampled_state));
            assert(render::same_texture_state(overlay_image.state, renderer.sampled_state));
            OverlayContext overlay = renderer.begin_overlay()!!;
            overlay.draw_list(&list)!!;
            renderer.end_overlay(&overlay)!!;
            overlay_frames++;
        }
        renderer.end_frame()!!;
    }
    if (!overlay_frames) io::eprintfn("%s: skipped, no window output", CAPACITY_OVERLAY_CASE);
    check_validation(&renderer);
}

fn void test_abort_restores_targets_past_index_thirty_two() @test {
    Fixture fixture;
    create_fixture(mem, &fixture, max_render_targets: CAPACITY_HIGH_TARGETS)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    CapacitySampling sampling = capacity_sampling(&fixture)!!;
    MaterialId monitor = fixture.assets.add_material(material::basic({
        .color = { 1, 1, 1, 1 },
        .map   = { .texture = { .kind = RENDER_TARGET, .target = sampling.sampled } },
    }))!!;
    sampling.consumer = capacity_consumer_scene(&fixture, monitor)!!;
    defer scene::destroy_scene(&sampling.consumer.scene);
    TargetRecord* sampled = renderer.targets.get(sampling.sampled);

    renderer.begin_frame()!!;
    capacity_fill_target(&fixture, sampling.sampled, RED)!!;
    renderer.end_frame()!!;
    gpu::TextureState submitted = sampled.target.state;

    renderer.begin_frame()!!;
    renderer.render_view(&sampling.consumer.scene, sampling.consumer.camera, sampling.views[0])!!;
    assert(render::same_texture_state(sampled.target.state, renderer.sampled_state));
    renderer.upload_material(monitor)!!;
    RenderTargetId late = capacity_add_target(renderer)!!;
    capacity_fill_target(&fixture, late, GREEN)!!;
    render::abort_frame(renderer);

    assert(render::same_texture_state(sampled.target.state, submitted));
    assert(sampled.sample_pending);
    assert(renderer.targets.get(late).target.state.layout == gpu::TextureLayout.UNDEFINED);
    renderer.begin_frame()!!;
    foreach (&record : renderer.targets.items) assert(!record.sample_pending);
    renderer.render_view(&sampling.consumer.scene, sampling.consumer.camera, sampling.views[0])!!;
    renderer.finish_view(sampling.views[0])!!;
    renderer.end_frame()!!;
    capacity_check_dominant(capacity_center(renderer, sampling.outputs[0])!!, 0);
    check_validation(renderer);
}

fn void test_texture_table_exhaustion_leaves_no_partial_resource() @test {
    Fixture fixture;
    create_fixture(
        allocator:          mem,
        fixture:            &fixture,
        max_render_targets: CAPACITY_SMALL_TABLE,
        texture_capacity:   CAPACITY_SMALL_TABLE,
    )!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;

    RenderTargetId[CAPACITY_SMALL_TABLE] targets;
    uint target_count;
    while (true) {
        CapacityCounts before = capacity_counts(renderer);
        RenderTargetId? target = capacity_add_target(renderer);
        if (catch excuse = target) {
            assert(excuse == gpu::SLOT_TABLE_FULL);
            capacity_check_counts(capacity_counts(renderer), before);
            break;
        }
        targets[target_count] = target;
        target_count++;
    }
    assert(target_count > 2);

    target_count -= 2;
    foreach (target : targets[target_count:2]) render::destroy_render_target(renderer, target)!!;
    CapacityCounts before = capacity_counts(renderer);
    if (catch excuse = render::create_view(renderer, render::texture_view_desc(fixture.hdr_target))) {
        assert(excuse == gpu::SLOT_TABLE_FULL);
    } else {
        assert(false, "a view's images fit two free table entries");
    }
    capacity_check_counts(capacity_counts(renderer), before);
    capacity_add_target(renderer)!!;
    check_validation(renderer);
}

fn void test_texture_heap_exhaustion_leaves_no_partial_resource() @test {
    Fixture fixture;
    create_fixture(
        allocator:             mem,
        fixture:               &fixture,
        max_render_targets:    CAPACITY_SMALL_HEAP,
        texture_heap_capacity: CAPACITY_SMALL_HEAP,
    )!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    assert(renderer.caps.texture_heap_capacity == CAPACITY_SMALL_HEAP);

    uint created;
    while (true) {
        CapacityCounts before = capacity_counts(renderer);
        if (catch excuse = capacity_add_target(renderer)) {
            assert(excuse == gpu::DESCRIPTOR_HEAP_FULL);
            capacity_check_counts(capacity_counts(renderer), before);
            break;
        }
        created++;
    }
    assert(created > 0);
    check_validation(renderer);
}

fn void test_texture_capacities_above_the_gpu_limit_fault() @test {
    uint above_limit = gpu::MAX_SHADER_HEAP_CAPACITY + 1;
    capacity_expect_creation_fault({ .texture_heap_capacity = above_limit }, gpu::INVALID_ARGUMENT);
    capacity_expect_creation_fault({ .texture_capacity = above_limit }, gpu::INVALID_ARGUMENT);
}

fn void test_render_target_capacity_above_the_texture_table_faults() @test {
    capacity_expect_creation_fault({ .max_render_targets = gpu::DEFAULT_TEXTURE_CAPACITY + 1 }, c3d::INVALID_ARGUMENT);
    capacity_expect_creation_fault(
        { .texture_capacity = CAPACITY_SMALL_TABLE, .max_render_targets = CAPACITY_SMALL_TABLE + 1 },
        c3d::INVALID_ARGUMENT,
    );
}

fn void test_texture_stats_count_view_images_and_targets() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;

    capacity_advance_to_reading(renderer)!!;
    Stats before = renderer.stats;
    CapacityCounts live = capacity_counts(renderer);
    assert(before.textures == live.textures && before.texture_views == live.texture_views);
    assert(before.texture_capacity == gpu::DEFAULT_TEXTURE_CAPACITY);
    assert(renderer.views.get(renderer.default_view).stats.images == 0);

    RenderTargetId target = capacity_add_target(renderer)!!;
    ViewId view = render::create_view(renderer, render::texture_view_desc(target))!!;
    renderer.begin_frame()!!;
    renderer.end_frame()!!;
    uint images = renderer.views.get(view).stats.images;
    assert(images > 0);
    assert(renderer.stats.textures == before.textures);

    capacity_advance_to_reading(renderer)!!;
    assert(renderer.stats.textures == before.textures + 1 + images);
    assert(renderer.stats.texture_views == before.texture_views + 1 + images);
    check_validation(renderer);
}
