module c3d::render::acceptance;

import c3d;
import c3d::camera;
import c3d::light;
import c3d::maths;
import c3d::render @public;
import c3d::shader;
import c3d::shader::compile;
import gpu;
import std::io;
import std::math;

const char[*] LIGHT_CLUSTER_REFERENCE @private = $embed("light_cull_reference.comp.glsl");
const float[6] LIGHT_CLUSTER_DEPTHS @private = { 0, 2, 8, 64, 2, 64 };
const uint LIGHT_CLUSTER_CAPACITY @private = 64;
const uint LIGHT_CLUSTER_INPUT_CAPACITY @private = 320;

struct LightClusterResult @private {
    char[] bytes;
    ClusterLayout layout;
    bool spatial_active;
}

fn gpu::PipelineHandle? create_light_cluster_reference(Renderer* renderer, bool pruned) @private {
    String[1] defines = { "DEPTH_PRUNING" };
    char[] spirv = compile::compile_glsl(
        allocator: mem,
        source: (String)LIGHT_CLUSTER_REFERENCE[..],
        stage: ShaderStage.COMPUTE,
        defines: pruned ? defines[..] : (String[]){},
    )!;
    defer free(spirv);
    gpu::ComputePipelineDesc desc = {
        .shader = { .spirv = spirv },
        .debug_name = "light_cluster_reference",
    };
    return gpu::create_compute_pipeline(&renderer.device, &desc);
}

fn LightClusterResult? capture_light_clusters(
    Fixture* fixture,
    Camera* camera,
    LightGpu[] lights,
    gpu::PipelineHandle pipeline,
    bool accelerated,
    bool pruned,
    bool raster_admission = false,
) @private {
    Renderer* renderer = &fixture.renderer;
    ClusterDesc desc = {
        .tiles_x = 3,
        .tiles_y = 2,
        .depth_slices = 4,
        .lights_per_cluster = LIGHT_CLUSTER_CAPACITY,
        .far_distance = 64,
        .depth_pruning = pruned,
    };
    ClusterLayout layout = render::cluster_layout(
        desc,
        math::max(LIGHT_CLUSTER_INPUT_CAPACITY, (uint)lights.len),
        { renderer.caps.max_compute_work_group_count.x, renderer.caps.max_compute_work_group_count.y,
            renderer.caps.max_compute_work_group_count.z },
    )!;
    ViewRecord record = { .desc = { .clusters = desc } };
    record.clusters = render::create_cluster_buffers(renderer, layout)!;
    defer render::destroy_cluster_buffers(&renderer.device, &record.clusters);
    gpu::AllocationDesc allocation = {
        .size = layout.size,
        .alignment = render::STREAM_ALIGNMENT,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access = { .graphics },
        .debug_name = "light_cluster_readback",
    };
    gpu::MappedGpuSpan readback = gpu::allocate_mapped_memory(&renderer.device, &allocation)!;
    defer {
        gpu::GpuAllocation owned = readback.span.allocation();
        gpu::free_allocation(&renderer.device, &owned)!!;
    }
    CameraMatrices matrices = camera::derive_matrices(*camera, matrix::IDENTITY4, { 32, 32 });
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    Frame* slot = &renderer.frames[renderer.frame_index % render::FRAMES_IN_FLIGHT];
    ClusterFrame clustered = render::prepare_cluster_frame(
        renderer: renderer,
        record: &record,
        camera: camera,
        matrices: &matrices,
        lights: lights,
        decals: {},
        pruned: true,
    )!;
    gpu::MappedGpuSpan depths = slot.upload.take(&renderer.device, LIGHT_CLUSTER_DEPTHS.len * float::size)!;
    ((float*)depths.bytes.ptr)[:LIGHT_CLUSTER_DEPTHS.len] = LIGHT_CLUSTER_DEPTHS[..];
    gpu::BufferCopyDesc depth_copy = {
        .src = depths.span,
        .dst = record.clusters.span.unchecked_subspan(layout.tile_depth_offset, depths.bytes.len),
    };
    gpu::cmd_copy_buffer(&renderer.commands, &depth_copy)!;
    gpu::Barrier ready = { .before = { .transfer }, .after = { .compute } };
    gpu::cmd_barrier(&renderer.commands, &ready)!;
    gpu::MappedGpuSpan frame = slot.upload.take(&renderer.device, FrameRoot::size)!;
    gpu::GpuAddress spatial = accelerated ? render::upload_light_spatial(
        renderer: renderer,
        lights: lights,
        desc: render::LIGHT_CLUSTER_BVH_BUILD,
        raster_admission: raster_admission,
    )! : (gpu::GpuAddress)0;
    *(FrameRoot*)frame.bytes.ptr = {
        .view = bitcast(matrices.view, Mat4f),
        .proj = bitcast(matrices.proj, Mat4f),
        .lights = clustered.lights,
        .light_count = (uint)lights.len,
        .clusters = clustered.clusters,
        .flags = shader::FRAME_LIGHTS_CLUSTERED,
        .light_spatial = spatial,
    };
    gpu::cmd_bind_pipeline(&renderer.commands, pipeline)!;
    gpu::cmd_dispatch(&renderer.commands, frame.address, { desc.tiles_x, desc.tiles_y, desc.depth_slices })!;
    renderer.work_recorded = true;
    gpu::Barrier complete = { .before = { .compute }, .after = { .transfer } };
    gpu::cmd_barrier(&renderer.commands, &complete)!;
    gpu::BufferCopyDesc copy = { .src = record.clusters.span, .dst = readback.span };
    gpu::cmd_copy_buffer(&renderer.commands, &copy)!;
    gpu::Barrier to_host = { .before = { .transfer }, .after = { .host } };
    gpu::cmd_barrier(&renderer.commands, &to_host)!;
    renderer.end_frame()!;
    assert(renderer.frame_submitted);
    render::wait_frames(renderer)!;
    gpu::invalidate_mapped_span(&renderer.device, readback.span)!;
    char[] bytes = mem::new_array(char, (sz)layout.size);
    mem::copy(bytes.ptr, readback.bytes.ptr, (sz)layout.size);
    return { .bytes = bytes, .layout = layout, .spatial_active = spatial != (gpu::GpuAddress)0 };
}

fn void compare_light_clusters(
    LightClusterResult* original,
    LightClusterResult* accelerated,
    LightGpu[] lights,
    Camera* camera,
    bool pruned,
) @private {
    ClusterDesc desc = {
        .tiles_x = 3,
        .tiles_y = 2,
        .depth_slices = 4,
        .lights_per_cluster = LIGHT_CLUSTER_CAPACITY,
        .far_distance = 64,
        .depth_pruning = pruned,
    };
    CameraMatrices matrices = camera::derive_matrices(*camera, matrix::IDENTITY4, { 32, 32 });
    ClusterDepth depth = render::cluster_depth(camera, desc);
    ClusterRange* reference_ranges = (ClusterRange*)&original.bytes[original.layout.ranges_offset];
    ClusterRange* candidate_ranges = (ClusterRange*)&accelerated.bytes[accelerated.layout.ranges_offset];
    uint* reference_indices = (uint*)&original.bytes[original.layout.indices_offset];
    uint* candidate_indices = (uint*)&accelerated.bytes[accelerated.layout.indices_offset];
    uint overflow_count;
    uint skipped_count;
    for (uint z = 0; z < desc.depth_slices; z++) {
        for (uint y = 0; y < desc.tiles_y; y++) {
            for (uint x = 0; x < desc.tiles_x; x++) {
                uint cell = x + desc.tiles_x * (y + desc.tiles_y * z);
                bool skipped = pruned && render::cluster_slice_bounds(depth, z).x > LIGHT_CLUSTER_DEPTHS[x + desc.tiles_x * y];
                if (skipped) {
                    assert(reference_ranges[cell].count == 0 && reference_ranges[cell].overflow == 1);
                    assert(candidate_ranges[cell].count == 0 && candidate_ranges[cell].overflow == 1);
                    skipped_count++;
                    continue;
                }
                Plane[6] planes = render::cluster_cell_planes(
                    desc: desc,
                    depth: depth,
                    matrices: &matrices,
                    cell: { x, y, z },
                );
                bool[] expected = alloc::new_array(tmem, bool, (sz)lights.len);
                uint expected_count;
                foreach (index, light : lights) {
                    if (light.kind == (uint)LightKind.DIRECTIONAL.ordinal || light.position_range.w == 0) continue;
                    bool inside = true;
                    foreach (plane : planes) {
                        if (plane.normal.dot(light.position_range.xyz) + plane.d < -light.position_range.w) inside = false;
                    }
                    expected[index] = inside;
                    if (inside) expected_count++;
                }
                uint retained = math::min(expected_count, desc.lights_per_cluster);
                uint overflow = expected_count > desc.lights_per_cluster ? 1u : 0u;
                assert(reference_ranges[cell].count == retained && reference_ranges[cell].overflow == overflow);
                assert(candidate_ranges[cell].count == retained && candidate_ranges[cell].overflow == overflow);
                overflow_count += overflow;
                bool[] reference_seen = alloc::new_array(tmem, bool, (sz)lights.len);
                bool[] candidate_seen = alloc::new_array(tmem, bool, (sz)lights.len);
                for (uint slot = 0; slot < retained; slot++) {
                    uint reference = reference_indices[cell * desc.lights_per_cluster + slot];
                    uint candidate = candidate_indices[cell * desc.lights_per_cluster + slot];
                    assert(reference < lights.len && expected[reference] && !reference_seen[reference]);
                    assert(candidate < lights.len && expected[candidate] && !candidate_seen[candidate]);
                    reference_seen[reference] = true;
                    candidate_seen[candidate] = true;
                }
                if (!overflow) {
                    for (usz index = 0; index < lights.len; index++) assert(reference_seen[index] == candidate_seen[index]);
                }
            }
        }
    }
    ClusterCounterGpu* reference_counter = (ClusterCounterGpu*)&original.bytes[original.layout.counter_offset];
    ClusterCounterGpu* candidate_counter = (ClusterCounterGpu*)&accelerated.bytes[accelerated.layout.counter_offset];
    assert(reference_counter.overflows == overflow_count && candidate_counter.overflows == overflow_count);
    assert(reference_counter.skipped == skipped_count && candidate_counter.skipped == skipped_count);
    assert(reference_counter.decal_overflows == 0 && candidate_counter.decal_overflows == 0);
}

fn void test_light_spatial_clusters_match_exhaustive_membership_and_overflow() @test {
    @pool() {
        Fixture fixture;
        create_fixture(mem, &fixture)!!;
        defer destroy_fixture(&fixture);
        Renderer* renderer = &fixture.renderer;
        gpu::PipelineHandle[2] references;
        for (usz index = 0; index < references.len; index++) references[index] = create_light_cluster_reference(renderer, index != 0)!!;
        defer foreach (pipeline : references) gpu::destroy_pipeline(&renderer.device, pipeline)!!;
        render::acquire_compute_slot(renderer, ComputeSlot.CLUSTER)!!;
        render::acquire_compute_slot(renderer, ComputeSlot.CLUSTER_PRUNED)!!;
        LightGpu[LIGHT_CLUSTER_INPUT_CAPACITY] lights;
        uint[7] counts = { 0, 4, 64, 65, 257, LIGHT_CLUSTER_INPUT_CAPACITY, 2 };
        foreach (pattern, count : counts) {
            foreach (index, &light : lights) {
                *light = light_candidate_value({ 0, 0, -2 }, 32);
                if (pattern == 1) *light = light_candidate_value({}, 0, index % 2 == 0);
                if (pattern == 5) {
                    Vec3 position = { (float)((int)(index % 17) - 8) * 2, (float)((int)(index % 5) - 2),
                        -1 - (float)(index % 61) };
                    *light = light_candidate_value(position, 3.25f);
                    if (index % 23 == 0) light.position_range.w = 0;
                }
            }
            if (pattern == 6) lights[0].position_range.w = 1e20f;
            for (uint projection = 0; projection < 2; projection++) {
                Camera camera = projection == 0 ? camera::perspective_deg(60, 0.1f, 64) : camera::orthographic(20, 0.1f, 64);
                for (uint pruned = 0; pruned < 2; pruned++) {
                    LightClusterResult original = capture_light_clusters(
                        fixture: &fixture,
                        camera: &camera,
                        lights: lights[:count],
                        pipeline: references[pruned],
                        accelerated: false,
                        pruned: pruned != 0,
                    )!!;
                    defer free(original.bytes);
                    LightClusterResult accelerated = capture_light_clusters(
                        fixture: &fixture,
                        camera: &camera,
                        lights: lights[:count],
                        pipeline: pruned ? renderer.cluster_pruned_pipeline : renderer.cluster_pipeline,
                        accelerated: true,
                        pruned: pruned != 0,
                    )!!;
                    defer free(accelerated.bytes);
                    assert(accelerated.spatial_active == (pattern >= 2 && pattern <= 5));
                    compare_light_clusters(
                        original: &original,
                        accelerated: &accelerated,
                        lights: lights[:count],
                        camera: &camera,
                        pruned: pruned != 0,
                    );
                }
            }
        }
        io::eprintfn("Light cluster membership: 28 matched input/projection/pruning cases passed.");
        check_validation(renderer);
    };
}

fn void test_light_spatial_clusters_keep_complete_admission_fallbacks() @test {
    @pool() {
        Fixture fixture;
        create_fixture(mem, &fixture)!!;
        defer destroy_fixture(&fixture);
        Renderer* renderer = &fixture.renderer;
        gpu::PipelineHandle[2] references;
        for (usz index = 0; index < references.len; index++) references[index] = create_light_cluster_reference(renderer, index != 0)!!;
        defer foreach (pipeline : references) gpu::destroy_pipeline(&renderer.device, pipeline)!!;
        render::acquire_compute_slot(renderer, ComputeSlot.CLUSTER)!!;
        render::acquire_compute_slot(renderer, ComputeSlot.CLUSTER_PRUNED)!!;
        LightGpu[] lights = alloc::alloc_array(tmem, LightGpu, 4096);
        for (uint pattern = 0; pattern < 5; pattern++) {
            foreach (index, &light : lights) {
                Vec3 position = { (float)((int)(index % 64) - 32), (float)((int)((index / 64) % 8) - 4),
                    -1 - (float)(index / 512) * 8 };
                *light = light_candidate_value(position, pattern == 4 ? 1e17f : pattern == 2 ? 32 : 1);
            }
            if (pattern == 3) lights[4095].position_range.w = 0;
            uint count = pattern == 0 ? 4095 : 4096;
            for (uint projection = 0; projection < 2; projection++) {
                Camera camera = projection == 0 ? camera::perspective_deg(60, 0.1f, 64) : camera::orthographic(20, 0.1f, 64);
                for (uint pruned = 0; pruned < 2; pruned++) {
                    LightClusterResult original = capture_light_clusters(
                        fixture: &fixture,
                        camera: &camera,
                        lights: lights[:count],
                        pipeline: references[pruned],
                        accelerated: false,
                        pruned: pruned != 0,
                    )!!;
                    defer free(original.bytes);
                    LightClusterResult accelerated = capture_light_clusters(
                        fixture: &fixture,
                        camera: &camera,
                        lights: lights[:count],
                        pipeline: pruned ? renderer.cluster_pruned_pipeline : renderer.cluster_pipeline,
                        accelerated: true,
                        pruned: pruned != 0,
                        raster_admission: true,
                    )!!;
                    defer free(accelerated.bytes);
                    assert(accelerated.spatial_active == (pattern == 1));
                    compare_light_clusters(
                        original: &original,
                        accelerated: &accelerated,
                        lights: lights[:count],
                        camera: &camera,
                        pruned: pruned != 0,
                    );
                }
            }
        }
        io::eprintfn("Light cluster admission: 20 matched small/sparse/dense/global-boundary/numeric cases passed.");
        check_validation(renderer);
    };
}
