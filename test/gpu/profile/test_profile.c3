module c3d::render::profile_acceptance;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::light;
import c3d::material;
import c3d::profile;
import c3d::render @public;
import c3d::scene;
import c3d::shader::compile;
import gpu;
import std::io;
import std::math;

const char[*] COUNTER_SOURCE @private = $embed("counter.comp.glsl");
const char[*] REJECTED_SOURCE @private = $embed("rejected.comp.glsl");
const uint TARGET_SIZE @private = 32;
const uint PIXEL_ALPHA_MASK @private = 0xff000000;
const uint PIXEL_COLOR_MASK @private = 0x00ffffff;
const FixtureLimits DEFAULT_LIMITS @private = {
    .history_frames = 8,
    .history_scopes = 128,
    .renderer_scopes = 128,
    .renderer_labels = 4096,
    .timings = true,
};

struct CounterRoot @private {
    gpu::GpuAddress output_address;
    uint value;
    uint padding;
}
$assert CounterRoot::size == 16;
$assert $reflect(CounterRoot.value).offset == 8;

struct CounterOutput @private {
    uint value;
    uint pixel;
}
$assert CounterOutput::size == 8;

struct FixtureLimits @private {
    uint history_frames;
    uint history_scopes;
    uint renderer_scopes;
    uint renderer_labels;
    bool timings;
}

struct Fixture @private {
    Allocator allocator;
    profile::Recorder recorder;
    AssetStore assets;
    Scene scene;
    Renderer renderer;
    Node* camera_node;
    Node* sun;
    GeometryId geometry;
    ComputeShaderId shader;
    BufferId output;
    RenderTargetId[2] targets;
    ViewId[2] views;
    gpu::MappedGpuSpan readback;
    bool renderer_alive;
    uint label_evaluations;
}

fn void? create_fixture(Allocator allocator, Fixture* fixture, FixtureLimits limits = DEFAULT_LIMITS) @private {
    fixture.allocator = allocator;
    fixture.recorder = profile::create_recorder(allocator, {
        .frame_capacity = limits.history_frames,
        .cpu_scopes_per_frame = 16,
        .max_depth = 8,
        .gpu_scopes_per_frame = limits.history_scopes,
        .label_bytes_per_frame = 8192,
    })!;
    defer catch profile::destroy_recorder(&fixture.recorder);
    fixture.assets = asset::create_asset_store(allocator, asset::default_asset_store_desc());
    defer catch asset::destroy_asset_store(&fixture.assets);
    fixture.scene = scene::create_scene(allocator, scene::default_scene_desc());
    defer catch scene::destroy_scene(&fixture.scene);

    @pool() {
        Geometry geometry = geometry::box(
            allocator: tmem,
            width: 1,
            height: 1,
            depth: 1,
        );
        fixture.geometry = fixture.assets.add_geometry(&geometry)!;
    };
    MaterialId material = fixture.assets.add_material(material::standard({
        .base_color = { 0.8f, 0.4f, 0.2f, 1 },
        .roughness = 0.7f,
    }))!;
    fixture.scene.add_mesh(fixture.geometry, material)!;
    fixture.scene.ambient_intensity = 0.2f;
    fixture.camera_node = fixture.scene.add_camera(camera::perspective_deg(60, 0.1f))!;
    fixture.camera_node.local.position = { 0, 0, 3 };
    Light sunlight = light::directional({ 1, 1, 1 }, 2);
    sunlight.shadow.cascades = 1;
    sunlight.shadow.max_distance = 10;
    fixture.sun = fixture.scene.add_light(sunlight)!;
    fixture.scene.update_world();

    char[] spirv = compile::compile_glsl(allocator, (String)COUNTER_SOURCE[..], ShaderStage.COMPUTE)!;
    defer alloc::free(allocator, spirv.ptr);
    ComputeShaderDesc shader_desc = { .compute = spirv };
    fixture.shader = fixture.assets.add_compute_shader(&shader_desc)!;

    fixture.renderer = render::create_renderer(
        allocator: allocator,
        assets: &fixture.assets,
        desc: {
            .validation = true,
            .gpu_timings = limits.timings,
            .profiler = &fixture.recorder,
            .gpu_scope_capacity = limits.renderer_scopes,
            .gpu_label_bytes_per_slot = limits.renderer_labels,
            .shadow_resolution = 64,
            .max_shadow_layers = 1,
            .application_name = "profile_acceptance",
        },
    )!;
    defer catch render::destroy_renderer(&fixture.renderer);
    fixture.renderer_alive = true;
    foreach (index, &target : fixture.targets) {
        *target = render::create_render_target(
            renderer: &fixture.renderer,
            desc: render::render_target_desc(TARGET_SIZE, TARGET_SIZE),
        )!;
        fixture.views[index] = render::create_view(&fixture.renderer, render::texture_view_desc(*target))!;
    }
    fixture.output = fixture.renderer.create_buffer({ .size = CounterOutput::size, .debug_name = "profile_output" })!;
    gpu::AllocationDesc readback_desc = {
        .size = CounterOutput::size,
        .alignment = 16,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access = { .graphics },
        .debug_name = "profile_readback",
    };
    fixture.readback = gpu::allocate_mapped_memory(&fixture.renderer.device, &readback_desc)!;
    defer catch {
        gpu::GpuAllocation allocation = fixture.readback.span.allocation();
        (void)gpu::free_allocation(&fixture.renderer.device, &allocation);
    }
    fixture.renderer.prepare_scene(&fixture.scene)!;
}

fn void check_validation(Renderer* renderer) @private {
    DebugEntry[render::DEBUG_LOG_ENTRIES] entries;
    usz count = renderer.log.recent(entries[..]);
    foreach (entry : entries[:count]) {
        assert(!(entry.category.backend && entry.category.validation && entry.severity == gpu::DebugMessageSeverity.ERROR));
    }
}

fn void destroy_fixture(Fixture* fixture) @private {
    if (fixture.renderer_alive) {
        render::wait_frames(&fixture.renderer)!!;
        gpu::GpuAllocation allocation = fixture.readback.span.allocation();
        gpu::free_allocation(&fixture.renderer.device, &allocation)!!;
        check_validation(&fixture.renderer);
        render::destroy_renderer(&fixture.renderer);
    }
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
    profile::destroy_recorder(&fixture.recorder);
}

fn void require_timestamps(Fixture* fixture) @private {
    assert(fixture.renderer.timestamps_enabled, "Graphics timestamps unavailable: hardware acceptance cannot run.");
}

fn void? dispatch_value(Fixture* fixture, uint value, bool sample_output = false) @private {
    CounterRoot root = { .output_address = fixture.renderer.buffer_address(fixture.output), .value = value };
    BufferId[1] writes = { fixture.output };
    DispatchTexture[1] textures = { render::read_target(fixture.targets[0]) };
    fixture.renderer.dispatch({
        .shader = fixture.shader,
        .root = ((char*)&root)[:CounterRoot::size],
        .groups = { 1, 1, 1 },
        .writes = writes[..],
        .textures = sample_output ? textures[..] : (DispatchTexture[]) {},
    })!;
}

fn void? record_readback(Fixture* fixture) @private {
    Renderer* renderer = &fixture.renderer;
    gpu::Barrier copied_writes = { .before = { .all }, .after = { .transfer } };
    gpu::cmd_barrier(&renderer.commands, &copied_writes)!;
    gpu::BufferCopyDesc buffer_copy = {
        .src = gpu::get_allocation_span(&renderer.device, renderer.buffers.get(fixture.output).allocation)!,
        .dst = fixture.readback.span,
    };
    gpu::cmd_copy_buffer(&renderer.commands, &buffer_copy)!;
    gpu::Barrier host_read = { .before = { .transfer }, .after = { .host } };
    gpu::cmd_barrier(&renderer.commands, &host_read)!;
}

fn String application_label(Fixture* fixture) @private {
    fixture.label_evaluations++;
    return "application.frame";
}

fn void? record_frame(
    Fixture* fixture,
    ulong frame_id,
    uint value,
    bool copy_output = true,
) @private {
    profile::@capture(&fixture.recorder, frame_id) {
        fixture.renderer.begin_frame()!;
        defer catch render::abort_frame(&fixture.renderer);
        profile::GpuScopeToken application = render::@gpu_begin(&fixture.renderer, application_label(fixture))!;
        dispatch_value(fixture, value - 2)!;
        fixture.renderer.render_view(&fixture.scene, fixture.camera_node, fixture.views[0])!;
        dispatch_value(fixture, value - 1)!;
        fixture.renderer.render_view(&fixture.scene, fixture.camera_node, fixture.views[1])!;
        fixture.renderer.finish_view(fixture.views[0])!;
        dispatch_value(fixture, value, true)!;
        fixture.renderer.finish_view(fixture.views[1])!;
        if (copy_output) record_readback(fixture)!;
        render::@gpu_end(&fixture.renderer, application)!;
        fixture.renderer.end_frame()!;
    };
}

fn void check_output(Fixture* fixture, uint value) @private {
    render::wait_frames(&fixture.renderer)!!;
    gpu::invalidate_mapped_span(&fixture.renderer.device, fixture.readback.span)!!;
    CounterOutput* output = (CounterOutput*)fixture.readback.bytes.ptr;
    assert(output.value == value);
    assert(output.pixel & PIXEL_COLOR_MASK);
    assert((output.pixel & PIXEL_ALPHA_MASK) == PIXEL_ALPHA_MASK);
    check_validation(&fixture.renderer);
}

fn void check_capture(Fixture* fixture, ulong frame_id, uint revision) @private {
    profile::FrameCaptureView frame = fixture.recorder.frame(frame_id)!!;
    assert(frame.gpu_state == profile::CaptureState.READY);
    assert(frame.pending_gpu_frames == 0 && !frame.gpu_truncated);
    uint[2] opaque;
    uint[2] view_segments;
    uint dispatches;
    double[render::PASS_COUNT] pass_ns;
    bool[render::PASS_COUNT] pass_measured;
    foreach (index, sample : frame.gpu) {
        assert(sample.renderer_frame == fixture.renderer.stats.gpu_frame_index);
        assert(sample.source == frame.gpu[0].source);
        assert(math::is_finite(sample.start_ns) && sample.start_ns >= 0);
        assert(math::is_finite(sample.duration_ns) && sample.duration_ns >= 0);
        assert(!sample.has_parent || sample.parent_index < index);
        if (sample.info.kind == profile::GpuScopeKind.COMPUTE_DISPATCH) {
            assert(!sample.info.has_view);
            assert(sample.info.shader_index == fixture.shader.index);
            assert(sample.info.shader_generation == fixture.shader.generation);
            assert(sample.info.shader_revision == revision);
            assert(sample.info.pass_ordinal == (uint)(dispatches ? Pass.CUSTOM_COMPUTE_POST.ordinal : Pass.CUSTOM_COMPUTE.ordinal));
            dispatches++;
        }
        if (sample.info.kind == profile::GpuScopeKind.PASS || sample.info.kind == profile::GpuScopeKind.COMPUTE_DISPATCH) {
            pass_ns[sample.info.pass_ordinal] += sample.duration_ns;
            pass_measured[sample.info.pass_ordinal] = true;
        }
        if (!sample.info.has_view) continue;
        foreach (view_index, view : fixture.views) {
            if (sample.info.view_index != view.index || sample.info.view_generation != view.generation) continue;
            if (sample.info.kind == profile::GpuScopeKind.VIEW) view_segments[view_index]++;
            if (sample.info.kind == profile::GpuScopeKind.PASS && sample.info.pass_ordinal == Pass.FORWARD_OPAQUE.ordinal) opaque[view_index]++;
        }
    }
    assert(dispatches == 3 && opaque[0] == 1 && opaque[1] == 1);
    assert(view_segments[0] == 2 && view_segments[1] == 2);
    assert(fixture.renderer.stats.gpu_timing_state == GpuTimingState.READY);
    assert(fixture.renderer.stats.gpu_scopes_dropped == 0);
    foreach (index, duration : pass_ns) {
        assert(fixture.renderer.stats.gpu_pass_valid[index] == pass_measured[index]);
        if (!pass_measured[index]) continue;
        assert(math::abs((double)fixture.renderer.stats.gpu_pass_ms[index] - duration / 1_000_000.0) < 0.001);
    }
    assert(fixture.renderer.stats.shadow_timings.len == 2);
    bool[2] shadow_views;
    foreach (timing : fixture.renderer.stats.shadow_timings) {
        assert(timing.light.index == fixture.sun.id.index && timing.light.generation == fixture.sun.id.generation);
        assert(timing.layer_index == 0);
        foreach (index, view : fixture.views) {
            if (timing.view.index == view.index && timing.view.generation == view.generation) shadow_views[index] = true;
        }
    }
    assert(shadow_views[0] && shadow_views[1]);
}

fn void test_interleaved_views_dispatches_and_shadow_identity() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    gpu::DeviceDesc device_desc;
    gpu::Adapter adapter = render::select_adapter(&fixture.renderer.runtime, &device_desc)!!;
    gpu::AdapterInfo info = gpu::get_adapter_info(&adapter)!!;
    io::eprintfn("Vulkan acceptance adapter: %s", info.name);
    require_timestamps(&fixture);
    record_frame(&fixture, 10, 42)!!;
    check_output(&fixture, 42);
    check_capture(&fixture, 10, 1);
}

fn void test_hdr_composite_follows_closed_post_chain_per_view() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    require_timestamps(&fixture);
    foreach (index, view : fixture.views) {
        ViewDesc desc = render::texture_view_desc(fixture.targets[index], OutputMode.LINEAR_HDR);
        desc.post.depth_of_field = true;
        render::configure_view(&fixture.renderer, view, desc)!!;
    }
    record_frame(&fixture, 0, 43)!!;
    check_output(&fixture, 43);
    check_capture(&fixture, 0, 1);

    profile::FrameCaptureView frame = fixture.recorder.frame(0)!!;
    uint[2] post_chains;
    uint[2] composites;
    foreach (sample : frame.gpu) {
        if (sample.info.kind != profile::GpuScopeKind.PASS) continue;
        if (sample.info.pass_ordinal != Pass.POST_CHAIN.ordinal
            && sample.info.pass_ordinal != Pass.COMPOSITE.ordinal) continue;
        assert(sample.has_parent && sample.info.has_view);
        profile::GpuSample parent = frame.gpu[sample.parent_index];
        assert(parent.info.kind == profile::GpuScopeKind.VIEW);
        assert(parent.label == "view.finish");
        assert(parent.info.view_index == sample.info.view_index);
        assert(parent.info.view_generation == sample.info.view_generation);
        foreach (index, view : fixture.views) {
            if (sample.info.view_index != view.index || sample.info.view_generation != view.generation) continue;
            if (sample.info.pass_ordinal == Pass.POST_CHAIN.ordinal) post_chains[index]++;
            if (sample.info.pass_ordinal == Pass.COMPOSITE.ordinal) composites[index]++;
        }
    }
    assert(post_chains[0] == 1 && post_chains[1] == 1);
    assert(composites[0] == 1 && composites[1] == 1);
}

fn void test_compute_reload_capture_keeps_active_revision() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    require_timestamps(&fixture);
    record_frame(&fixture, 0, 17)!!;
    check_output(&fixture, 17);
    char[] spirv = compile::compile_glsl(mem, (String)COUNTER_SOURCE[..], ShaderStage.COMPUTE)!!;
    defer free(spirv.ptr);
    ComputeShaderDesc shader_desc = { .compute = spirv };
    fixture.assets.replace_compute_shader(fixture.shader, &shader_desc)!!;
    record_frame(&fixture, 1, 23)!!;
    check_output(&fixture, 23);
    check_capture(&fixture, 1, 2);
    char[] rejected = compile::compile_glsl(mem, (String)REJECTED_SOURCE[..], ShaderStage.COMPUTE)!!;
    defer free(rejected.ptr);
    shader_desc.compute = rejected;
    fixture.assets.replace_compute_shader(fixture.shader, &shader_desc)!!;
    record_frame(&fixture, 2, 31)!!;
    check_output(&fixture, 31);
    check_capture(&fixture, 2, 2);
    assert(fixture.renderer.stats.shader_rejections == 1);
}

fn void? record_failed_dispatch(Fixture* fixture) @private {
    profile::@capture(&fixture.recorder, 0) {
        fixture.renderer.begin_frame()!;
        defer catch render::abort_frame(&fixture.renderer);
        profile::GpuScopeToken token = render::@gpu_begin(&fixture.renderer, "application.aborted")!;
        fixture.renderer.dispatch({ .groups = { 1, 1, 1 } })!;
        render::@gpu_end(&fixture.renderer, token)!;
        fixture.renderer.end_frame()!;
    };
}

fn void test_abort_and_empty_recordings_release_capture_pins() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    require_timestamps(&fixture);
    if (catch excuse = record_failed_dispatch(&fixture)) {
        assert(excuse == c3d::INVALID_ID);
    } else {
        assert(false);
    }
    profile::FrameCaptureView failed = fixture.recorder.frame(0)!!;
    assert(failed.gpu_state == profile::CaptureState.ABORTED && failed.gpu.len == 0);
    profile::@capture(&fixture.recorder, 1) {
        fixture.renderer.begin_frame()!!;
        fixture.renderer.end_frame()!!;
    };
    profile::FrameCaptureView empty = fixture.recorder.frame(1)!!;
    assert(empty.gpu_state == profile::CaptureState.ABORTED && empty.pending_gpu_frames == 0);
    record_frame(&fixture, 2, 19)!!;
    check_output(&fixture, 19);
    check_capture(&fixture, 2, 1);
}

fn void test_query_and_label_limits_preserve_rendered_output() @test {
    foreach (limits : (FixtureLimits[2]){
        { ...DEFAULT_LIMITS, .renderer_scopes = 2 },
        { ...DEFAULT_LIMITS, .renderer_labels = 1 },
    }) {
        Fixture fixture;
        create_fixture(mem, &fixture, limits)!!;
        defer destroy_fixture(&fixture);
        require_timestamps(&fixture);
        record_frame(&fixture, 0, 29)!!;
        check_output(&fixture, 29);
        profile::FrameCaptureView frame = fixture.recorder.frame(0)!!;
        assert(frame.gpu_state == profile::CaptureState.TRUNCATED);
        assert(frame.gpu_truncated && frame.dropped_gpu_scopes > 0);
        assert(frame.gpu.len <= limits.renderer_scopes);
        assert(fixture.renderer.stats.gpu_timing_state == GpuTimingState.TRUNCATED);
    }
}

fn void test_history_pressure_toggle_and_teardown_drain() @test {
    Fixture fixture;
    create_fixture(mem, &fixture, { ...DEFAULT_LIMITS, .history_frames = 1 })!!;
    defer destroy_fixture(&fixture);
    require_timestamps(&fixture);
    record_frame(&fixture, 0, 11)!!;
    record_frame(&fixture, 1, 13)!!;
    assert(fixture.recorder.dropped_frames == 1);
    assert(fixture.label_evaluations == 1);
    if (catch excuse = fixture.recorder.frame(1)) {
        assert(excuse == profile::NOT_FOUND);
    } else {
        assert(false);
    }
    fixture.recorder.set_enabled(false);
    record_frame(&fixture, 2, 17)!!;
    check_output(&fixture, 17);
    assert(fixture.recorder.frame(0)!!.gpu_state == profile::CaptureState.READY);
    fixture.recorder.set_enabled(true);
    record_frame(&fixture, 3, 23)!!;
    render::wait_frames(&fixture.renderer)!!;
    gpu::GpuAllocation allocation = fixture.readback.span.allocation();
    gpu::free_allocation(&fixture.renderer.device, &allocation)!!;
    record_frame(
        fixture: &fixture,
        frame_id: 4,
        value: 31,
        copy_output: false,
    )!!;
    render::destroy_renderer(&fixture.renderer);
    fixture.renderer_alive = false;
    assert(fixture.recorder.frame(4)!!.gpu_state == profile::CaptureState.READY);
    assert(fixture.recorder.frame(4)!!.pending_gpu_frames == 0);
}

fn void test_resize_and_closed_preparation_collect_prior_frames() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    require_timestamps(&fixture);
    record_frame(&fixture, 0, 11)!!;
    render::resize_render_target(
        renderer: &fixture.renderer,
        target: fixture.targets[0],
        width: TARGET_SIZE + 16,
        height: TARGET_SIZE + 16,
    )!!;
    assert(fixture.recorder.frame(0)!!.gpu_state == profile::CaptureState.READY);
    fixture.renderer.prepare_scene(&fixture.scene)!!;
    record_frame(&fixture, 1, 17)!!;
    record_frame(&fixture, 2, 23)!!;
    fixture.assets.mark_geometry_dirty(fixture.geometry);
    fixture.renderer.upload(fixture.geometry)!!;
    render::wait_frames(&fixture.renderer)!!;
    assert(fixture.recorder.frame(1)!!.gpu_state == profile::CaptureState.READY);
    assert(fixture.recorder.frame(2)!!.gpu_state == profile::CaptureState.READY);
    check_output(&fixture, 23);
}

fn void test_runtime_disabled_gpu_scope_skips_labels() @test {
    Fixture fixture;
    create_fixture(mem, &fixture, { ...DEFAULT_LIMITS, .timings = false })!!;
    defer destroy_fixture(&fixture);
    record_frame(&fixture, 0, 37)!!;
    check_output(&fixture, 37);
    assert(fixture.label_evaluations == 0);
    profile::FrameCaptureView frame = fixture.recorder.frame(0)!!;
    assert(frame.gpu_state == profile::CaptureState.UNAVAILABLE && frame.gpu.len == 0);
    assert(fixture.renderer.stats.gpu_timing_state == GpuTimingState.UNAVAILABLE);
}
