module c3d::render::acceptance;

import c3d;
import c3d::light;
import c3d::render @public;
import c3d::scene;
import gpu;
import std::math::vector;

fn void check_optical_render_pixel_bits(Vec4[] actual, Vec4[] expected) @private {
    assert(actual.len == expected.len);
    assert(mem::equals(actual.ptr, expected.ptr, actual.len * Vec4::size));
}

fn void check_optical_render_phase_counts(Stats* stats, uint capacity) @private {
    assert(stats.optical_shadow_layers == 1);
    assert(stats.optical_shadow_capture_passes == capacity);
    assert(stats.optical_shadow_product_passes == capacity);
    assert(stats.optical_shadow_store_passes == capacity);
    assert(stats.optical_shadow_blocker_passes == 2);
    assert(stats.optical_shadow_overflow_passes == 1);
    usz pixels = OPTICAL_RENDER_SHADOW_EXTENT * OPTICAL_RENDER_SHADOW_EXTENT;
    assert(stats.optical_shadow_payload_bytes == pixels * (12 * (usz)capacity + 8));
    assert(stats.optical_shadow_scratch_bytes == pixels * 16);
}

fn void test_optical_render_lifetime_abort_retry_and_disabled_payload_preserve_pixels_on_all_routes() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        foreach (route : OpticalRenderRoute::values) {
            OpticalRenderFixture fixture;
            create_optical_render_fixture(&tracker, &fixture, route)!!;
            defer destroy_optical_render_fixture(&fixture);
            Vec4[] scalar = optical_render_pixels(&fixture)!!;
            defer free(scalar);
            fixture.scene.get(fixture.sun, Light).shadow.colored_transmission = true;
            Vec4[] committed = optical_render_pixels(&fixture)!!;
            defer free(committed);
            if (route == OpticalRenderRoute.ATLAS) check_optical_render_phase_counts(&fixture.renderer.stats, 4);
            fixture.renderer.begin_frame()!!;
            fixture.renderer.render_view(&fixture.scene, fixture.camera, fixture.view)!!;
            render::abort_frame(&fixture.renderer);
            Vec4[] retried = optical_render_pixels(&fixture)!!;
            defer free(retried);
            check_optical_render_pixel_bits(retried, committed);
            fixture.scene.get(fixture.sun, Light).shadow.colored_transmission = false;
            Vec4[] disabled = optical_render_pixels(&fixture)!!;
            defer free(disabled);
            check_optical_render_pixel_bits(disabled, scalar);
            assert(!fixture.renderer.optical_shadow_atlas.opaque.texture.is_valid());
            assert(!fixture.renderer.optical_scene_trace.allocation.is_valid());
            assert(fixture.renderer.stats.optical_shadow_payload_bytes == 0);
            assert(fixture.renderer.stats.optical_shadow_scratch_bytes == 0);
            assert(fixture.renderer.stats.optical_shadow_layers == 0);
            assert(fixture.renderer.stats.optical_shadow_capture_passes == 0);
            assert(fixture.renderer.stats.optical_shadow_product_passes == 0);
            assert(fixture.renderer.stats.optical_shadow_store_passes == 0);
            assert(fixture.renderer.stats.optical_shadow_blocker_passes == 0);
            assert(fixture.renderer.stats.optical_shadow_overflow_passes == 0);
            assert(fixture.renderer.stats.optical_trace_overflows == 0);
            fixture.scene.get(fixture.sun, Light).shadow.colored_transmission = true;
            Vec4[] recreated = optical_render_pixels(&fixture)!!;
            defer free(recreated);
            check_optical_render_pixel_bits(recreated, committed);
        }
    }
    assert(tracker.allocated() == 0);
}

fn void test_optical_render_lifetime_equivalent_shared_sets_add_no_optical_phases() @test {
    OpticalRenderFixture fixture;
    create_optical_render_fixture(mem, &fixture, OpticalRenderRoute.ATLAS)!!;
    defer destroy_optical_render_fixture(&fixture);
    fixture.scene.get(fixture.sun, Light).shadow.colored_transmission = true;
    ViewDesc desc = fixture.renderer.views.get(fixture.view).desc;
    desc.share_shadows = true;
    render::configure_view(&fixture.renderer, fixture.view, desc)!!;
    ViewId second = render::create_view(&fixture.renderer, desc)!!;
    fixture.renderer.begin_frame()!!;
    defer catch render::abort_frame(&fixture.renderer);
    fixture.renderer.render_view(&fixture.scene, fixture.camera, fixture.view)!!;
    fixture.renderer.finish_view(fixture.view)!!;
    check_optical_render_phase_counts(&fixture.renderer.stats, 4);
    gpu::GpuAddress original = fixture.renderer.shadow_set.optical_layers;
    fixture.renderer.render_view(&fixture.scene, fixture.camera, second)!!;
    fixture.renderer.finish_view(second)!!;
    check_optical_render_phase_counts(&fixture.renderer.stats, 4);
    assert(fixture.renderer.shadow_set.optical_layers == original);
    assert(fixture.renderer.stats.shadow_sets_shared == 1);
    fixture.renderer.end_frame()!!;
}

fn void release_optical_test_views(Renderer* renderer, gpu::AccelerationStructureView[] views) @private {
    foreach (&view : views) {
        if (!view.is_valid()) continue;
        gpu::destroy_acceleration_structure_view(&renderer.device, *view)!!;
        *view = {};
    }
}

fn void test_optical_render_lifetime_tlas_view_allocation_faults_preserve_generic_resources_and_retry() @test {
    foreach (uint failed : (uint[2]){ 0, 1 }) {
        TrackingAllocator tracker;
        tracker.init(mem);
        defer tracker.free();
        {
            OpticalRenderFixture fixture;
            create_optical_render_fixture(&tracker, &fixture, OpticalRenderRoute.HARDWARE)!!;
            defer destroy_optical_render_fixture(&fixture);
            Vec4[] baseline = optical_render_pixels(&fixture)!!;
            defer free(baseline);
            gpu::GpuAllocation allocation = fixture.renderer.scene_trace.allocation;
            gpu::AccelerationStructureHandle[render::FRAMES_IN_FLIGHT] generic;
            foreach (index, level : fixture.renderer.rt.top_levels) generic[index] = level.tlas;
            gpu::AccelerationStructureView[render::FRAMES_IN_FLIGHT] pressure;
            defer release_optical_test_views(&fixture.renderer, pressure[..]);
            uint held = render::FRAMES_IN_FLIGHT - failed;
            for (uint index = 0; index < held; index++) {
                pressure[index] = gpu::create_acceleration_structure_view(&fixture.renderer.device, generic[0])!!;
            }
            fixture.scene.get(fixture.sun, Light).shadow.colored_transmission = true;
            assert(@catch(optical_render_frame(&fixture)) == gpu::DESCRIPTOR_HEAP_FULL);
            assert(fixture.renderer.scene_trace.allocation == allocation);
            foreach (index, level : fixture.renderer.rt.top_levels) assert(level.tlas == generic[index]);
            foreach (level : fixture.renderer.optical_rt.top_levels) {
                assert(!level.tlas.is_valid() && !level.view.is_valid());
            }
            release_optical_test_views(&fixture.renderer, pressure[..]);
            Vec4[] retried = optical_render_pixels(&fixture)!!;
            defer free(retried);
            check_optical_render_visibility(
                optical_render_visibility(retried, baseline),
                optical_render_expected(optical_render_reference(optical_render_glass_params())),
                "TLAS allocation retry",
            );
        }
        assert(tracker.allocated() == 0);
    }
}
