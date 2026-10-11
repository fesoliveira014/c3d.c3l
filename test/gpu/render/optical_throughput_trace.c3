module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::material;
import c3d::render @public;
import c3d::scene;
import c3d::shader;
import c3d::spatial::bvh;
import c3d::test::transparency_fixtures;
import gpu;
import std::io;
import std::math;

const char[*] OPTICAL_TRACE_SOURCE @private = $embed("optical_throughput.trace.comp.glsl");

struct OpticalTraceRoot @private {
    gpu::GpuAddress scene;
    gpu::GpuAddress surfaces;
    gpu::GpuAddress order;
    gpu::GpuAddress output_address;
    uint capacity;
    uint width;
    uint height;
    uint sampler_index;
}
$assert OpticalTraceRoot::size == 48;

struct OpticalTraceResources @private {
    Scene scene;
    MaterialId material;
    GeometryId[OPTICAL_SURFACE_CAPACITY] geometries;
    gpu::PipelineHandle software;
    gpu::PipelineHandle hardware;
    gpu::AccelerationStructureHandle tlas;
    gpu::AccelerationStructureHandle[OPTICAL_SURFACE_CAPACITY] bottom_levels;
    gpu::AccelerationStructureView view;
    gpu::GpuAllocation scratch;
    gpu::MappedGpuSpan output;
    usz scratch_bytes;
    uint count;
}

fn void destroy_optical_trace(Fixture* fixture, OpticalTraceResources* trace) @private {
    Renderer* renderer = &fixture.renderer;
    render::wait_frames(renderer)!!;
    if (trace.view.is_valid()) gpu::destroy_acceleration_structure_view(&renderer.device, trace.view)!!;
    if (trace.tlas.is_valid()) gpu::destroy_acceleration_structure(&renderer.device, trace.tlas)!!;
    foreach (handle : trace.bottom_levels) {
        if (handle.is_valid()) gpu::destroy_acceleration_structure(&renderer.device, handle)!!;
    }
    if (trace.scratch.is_valid()) gpu::free_allocation(&renderer.device, &trace.scratch)!!;
    foreach (pipeline : (gpu::PipelineHandle[2]){ trace.software, trace.hardware }) {
        if (pipeline.is_valid()) gpu::destroy_pipeline(&renderer.device, pipeline)!!;
    }
    if (trace.output.bytes.len) {
        gpu::GpuAllocation allocation = trace.output.span.allocation();
        gpu::free_allocation(&renderer.device, &allocation)!!;
    }
    scene::destroy_scene(&trace.scene);
    *trace = {};
}

fn void? create_optical_trace(
    Fixture* fixture,
    OpticalTraceResources* trace,
    OpticalSurface[] surfaces,
) @private {
    Renderer* renderer = &fixture.renderer;
    trace.scene = scene::create_scene(mem, scene::default_scene_desc());
    defer catch destroy_optical_trace(fixture, trace);
    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    common.double_sided = true;
    trace.material = fixture.assets.add_material(material::basic({ .color = { 1, 1, 1, 1 } }, common))!;
    foreach (index, surface : surfaces) {
        float distance = 9 - 8 * surface.model_scale.w;
        Vec3[4] positions = {
            { surface.bounds.x, surface.bounds.y, -distance },
            { surface.bounds.z, surface.bounds.y, -distance },
            { surface.bounds.z, surface.bounds.w, -distance },
            { surface.bounds.x, surface.bounds.w, -distance },
        };
        Vec2[4] coordinates = { { 0, 1 }, { 1, 1 }, { 1, 0 }, { 0, 0 } };
        Geometry geometry = {
            .positions = positions[..],
            .uv0 = coordinates[..],
            .indices = transparency_fixtures::QUAD_INDICES[..],
        };
        trace.geometries[index] = fixture.assets.add_geometry(&geometry)!;
        trace.scene.add_mesh(trace.geometries[index], trace.material)!;
    }
    trace.count = (uint)surfaces.len;
    trace.scene.update_world();
    renderer.prepare_scene_trace(&trace.scene, TraceKind.SOFTWARE)!;
    String[1] software_define = { "SCENE_TRACE_BVH" };
    String[1] hardware_define = { "SCENE_TRACE_RAY_QUERY" };
    foreach (branch, defines : (String[][2]){ software_define[..], hardware_define[..] }) {
        char[] spirv = compile_optical_source(
            source: (String)OPTICAL_TRACE_SOURCE[..],
            stage: ShaderStage.COMPUTE,
            name: branch ? "optical_trace_hardware" : "optical_trace_software",
            defines: defines,
        )!;
        defer free(spirv.ptr);
        gpu::ComputePipelineDesc desc = { .shader = { .spirv = spirv }, .debug_name = "optical_trace" };
        gpu::PipelineHandle pipeline = gpu::create_compute_pipeline(&renderer.device, &desc)!;
        if (branch) {
            trace.hardware = pipeline;
        } else {
            trace.software = pipeline;
        }
    }
    gpu::AccelerationStructureDesc tlas = {
        .kind = gpu::AccelerationStructureKind.TOP_LEVEL,
        .max_instance_count = trace.count,
        .flags = { .prefer_fast_trace },
        .debug_name = "optical_trace_tlas",
    };
    trace.tlas = gpu::create_acceleration_structure(&renderer.device, &tlas)!;
    trace.view = gpu::create_acceleration_structure_view(&renderer.device, trace.tlas)!;
    gpu::AccelerationStructureRequirements requirements
      = gpu::get_acceleration_structure_requirements(&renderer.device, &tlas)!;
    usz scratch_bytes = requirements.build_scratch_size;
    for (uint index = 0; index < trace.count; index++) {
        GpuGeometry* geometry = &renderer.geometries[trace.geometries[index].index];
        gpu::AccelerationStructureGeometryDesc[1] geometries = {{
            .kind = gpu::AccelerationStructureGeometryKind.TRIANGLES,
            .triangles = {
                .max_vertex_count = geometry.layout.vertex_count,
                .max_primitive_count = geometry.layout.index_count / 3,
                .index_type = geometry.layout.index_stride == ushort::size
                  ? gpu::AccelerationStructureIndexType.U16 : gpu::AccelerationStructureIndexType.U32,
            },
        }};
        gpu::AccelerationStructureDesc desc = {
            .kind = gpu::AccelerationStructureKind.BOTTOM_LEVEL,
            .geometries = geometries[..],
            .flags = { .prefer_fast_trace },
            .debug_name = "optical_trace_blas",
        };
        trace.bottom_levels[index] = gpu::create_acceleration_structure(&renderer.device, &desc)!;
        gpu::AccelerationStructureRequirements bottom
          = gpu::get_acceleration_structure_requirements(&renderer.device, &desc)!;
        scratch_bytes = math::max(scratch_bytes, bottom.build_scratch_size);
    }
    gpu::AllocationDesc scratch = {
        .size = scratch_bytes,
        .alignment = requirements.scratch_alignment,
        .memory_class = gpu::MemoryClass.GPU_PRIVATE,
        .access = { .graphics },
        .debug_name = "optical_trace_scratch",
    };
    trace.scratch = gpu::allocate_memory(&renderer.device, &scratch)!;
    trace.scratch_bytes = scratch.size;
    gpu::AllocationDesc output = {
        .size = 4 * OPTICAL_SCALAR_BYTES,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access = { .graphics },
        .debug_name = "optical_trace_output",
    };
    trace.output = gpu::allocate_mapped_memory(&renderer.device, &output)!;
}

fn gpu::GpuAddress? upload_optical_trace_scene(
    Fixture* fixture,
    OpticalTraceResources* trace,
    OpticalSurface[] surfaces,
    gpu::GpuAddress* surface_address,
    gpu::GpuAddress* order_address,
) @private {
    Renderer* renderer = &fixture.renderer;
    gpu::GpuSpan scratch = gpu::get_allocation_span(&renderer.device, trace.scratch)!;
    gpu::Barrier uploads = { .before = { .transfer, .host }, .after = { .acceleration_structure_build } };
    gpu::cmd_barrier(&renderer.commands, &uploads)!;
    gpu::Barrier builds = {
        .before = { .acceleration_structure_build },
        .after = { .acceleration_structure_build },
    };
    for (uint index = 0; index < trace.count; index++) {
        GpuGeometry* geometry = &renderer.geometries[trace.geometries[index].index];
        gpu::AccelerationStructureGeometryBuildDesc[1] geometries = {{
            .kind = gpu::AccelerationStructureGeometryKind.TRIANGLES,
            .triangles = {
                .vertices = geometry.positions,
                .vertex_stride = render::PACKED_VEC3_BYTES,
                .vertex_count = geometry.layout.vertex_count,
                .indices = geometry.indices,
                .primitive_count = geometry.layout.index_count / 3,
            },
        }};
        gpu::AccelerationStructureBuildDesc build = {
            .destination = trace.bottom_levels[index],
            .geometries = geometries[..],
            .scratch = scratch,
        };
        gpu::cmd_build_acceleration_structure(&renderer.commands, &build)!;
        gpu::cmd_barrier(&renderer.commands, &builds)!;
    }
    Aabb[OPTICAL_SURFACE_CAPACITY] bounds;
    TraceInstanceGpu[OPTICAL_SURFACE_CAPACITY] rows;
    OpticalSurface[OPTICAL_SURFACE_CAPACITY] reordered;
    foreach (index, surface : surfaces) {
        float distance = 9 - 8 * surface.model_scale.w;
        bounds[index] = {
            .min = { surface.bounds.x, surface.bounds.y, -distance },
            .max = { surface.bounds.z, surface.bounds.w, -distance },
        };
    }
    @pool() {
        Bvh top = bvh::build_box_bvh(tmem, bounds[:surfaces.len], { .bins = 12, .leaf_size = 1 })!;
        Frame* frame = &renderer.frames[renderer.frame_index % render::FRAMES_IN_FLIGHT];
        gpu::MappedGpuSpan instances = frame.upload.take(
            &renderer.device, surfaces.len * gpu::AccelerationStructureInstance::size)!;
        gpu::AccelerationStructureInstance* packed = (gpu::AccelerationStructureInstance*)instances.bytes.ptr;
        foreach (row, index : top.primitives) {
            GpuGeometry* geometry = &renderer.geometries[trace.geometries[index].index];
            MaterialRes* material = &renderer.materials[trace.material.index];
            rows[row] = {
                .geometry = geometry.root,
                .material = material.address,
                .flags = shader::TRACE_INSTANCE_DOUBLE_SIDED,
                .material_kind = shader::MATERIAL_KIND_BASIC,
                .mask = shader::TRACE_MASK_ALL,
                .world_to_local_0 = { 1, 0, 0, 0 },
                .world_to_local_1 = { 0, 1, 0, 0 },
                .world_to_local_2 = { 0, 0, 1, 0 },
                .local_to_world_0 = { 1, 0, 0, 0 },
                .local_to_world_1 = { 0, 1, 0, 0 },
                .local_to_world_2 = { 0, 0, 1, 0 },
                .nodes = geometry.trace.nodes,
                .primitives = geometry.trace.primitives,
            };
            reordered[row] = surfaces[index];
            gpu::AccelerationStructureInstanceDesc desc = {
                .transform_row_0 = { 1, 0, 0, 0 },
                .transform_row_1 = { 0, 1, 0, 0 },
                .transform_row_2 = { 0, 0, 1, 0 },
                .bottom_level = trace.bottom_levels[index],
                .custom_index = (uint)row,
                .mask = shader::TRACE_MASK_ALL,
                .flags = { .triangle_cull_disable = true, .force_non_opaque = true },
            };
            packed[row] = gpu::make_acceleration_structure_instance(&renderer.device, &desc)!;
        }
        gpu::AccelerationStructureBuildDesc build = {
            .destination = trace.tlas,
            .instances = instances.span,
            .instance_count = (uint)surfaces.len,
            .scratch = gpu::get_allocation_span(&renderer.device, trace.scratch)!,
        };
        gpu::Barrier inputs = { .before = { .host, .acceleration_structure_build },
            .after = { .acceleration_structure_build } };
        gpu::cmd_barrier(&renderer.commands, &inputs)!;
        gpu::cmd_build_acceleration_structure(&renderer.commands, &build)!;
        gpu::Barrier built = { .before = { .acceleration_structure_build }, .after = { .compute } };
        gpu::cmd_barrier(&renderer.commands, &built)!;
        char[] row_bytes = ((char*)&rows)[:surfaces.len * TraceInstanceGpu::size];
        char[] node_bytes = ((char*)top.nodes.ptr)[:top.nodes.len * BvhNodeGpu::size];
        SceneTraceRoot root = {
            .top_nodes = write_optical_bytes(renderer, node_bytes)!,
            .instances = write_optical_bytes(renderer, row_bytes)!,
            .instance_count = (uint)surfaces.len,
            .top_node_count = (uint)top.nodes.len,
            .tlas_index = (uint)trace.view.index,
        };
        char[] surface_bytes = ((char*)&reordered)[:surfaces.len * OpticalSurface::size];
        *surface_address = write_optical_bytes(renderer, surface_bytes)!;
        uint[OPTICAL_SURFACE_CAPACITY] order;
        order_optical_surfaces(reordered[:surfaces.len], order[:surfaces.len]);
        char[] order_bytes = ((char*)&order)[:surfaces.len * uint::size];
        *order_address = write_optical_bytes(renderer, order_bytes)!;
        return write_optical_bytes(renderer, ((char*)&root)[:SceneTraceRoot::size]);
    };
}

fn void? run_optical_trace(
    Fixture* fixture,
    OpticalTraceResources* trace,
    OpticalSurface[] surfaces,
    uint capacity,
    bool hardware,
    gpu::SamplerIndex sampler = (gpu::SamplerIndex)0,
) @private {
    Renderer* renderer = &fixture.renderer;
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    gpu::GpuAddress surface_address;
    gpu::GpuAddress order_address;
    gpu::GpuAddress scene = upload_optical_trace_scene(
        fixture: fixture,
        trace: trace,
        surfaces: surfaces,
        surface_address: &surface_address,
        order_address: &order_address,
    )!;
    OpticalTraceRoot parameters = {
        .scene = scene,
        .surfaces = surface_address,
        .order = order_address,
        .output_address = trace.output.address,
        .capacity = capacity,
        .width = OPTICAL_EXTENT,
        .height = OPTICAL_EXTENT,
        .sampler_index = (uint)sampler,
    };
    gpu::GpuAddress root = write_optical_bytes(renderer, ((char*)&parameters)[:OpticalTraceRoot::size])!;
    gpu::cmd_bind_pipeline(&renderer.commands, hardware ? trace.hardware : trace.software)!;
    uint groups = OPTICAL_EXTENT / OPTICAL_RESOLVE_GROUP_SIZE;
    gpu::cmd_dispatch(&renderer.commands, root, { groups, groups, 1 })!;
    gpu::Barrier host = { .before = { .compute }, .after = { .host } };
    gpu::cmd_barrier(&renderer.commands, &host)!;
    renderer.work_recorded = true;
    renderer.end_frame()!;
    render::wait_frames(renderer)!;
    gpu::invalidate_mapped_span(&renderer.device, trace.output.span)!;
}

fn void test_optical_throughput_forced_hardware_and_software_share_the_atlas_interior_product_and_blockers() @test {
    Fixture fixture;
    create_fixture(mem, &fixture, ray_queries: true)!!;
    defer destroy_fixture(&fixture);
    assert(fixture.renderer.caps.ray_queries.enabled, "Hardware optics requires ray queries.");
    OpticalStack stack;
    create_optical_stack(&fixture.renderer, &stack)!!;
    defer destroy_optical_stack(&fixture.renderer, &stack);
    OpticalSurface[OPTICAL_SURFACE_CAPACITY] surfaces;
    uint count = make_optical_stack_sheets(surfaces[..], 6, true);
    OpticalTraceResources trace;
    create_optical_trace(&fixture, &trace, surfaces[:count])!!;
    defer destroy_optical_trace(&fixture, &trace);
    foreach (blocked : (bool[2]){ false, true }) {
        surfaces[count - 1].flags = blocked ? OPTICAL_OPAQUE : OPTICAL_ALPHA_BLEND;
        foreach (capacity : (uint[4]){ 1, 2, 4, 16 }) {
            run_optical_stack(
                renderer: &fixture.renderer,
                stack: &stack,
                surfaces: surfaces[:count],
                capacity: capacity,
            )!!;
            check_optical_stack(&stack, surfaces[:count], capacity);
            Vec4[] atlas = mem::new_array(Vec4, OPTICAL_EXTENT * OPTICAL_EXTENT);
            defer free(atlas.ptr);
            mem::copy(atlas.ptr, stack.output.bytes.ptr, (sz)stack.output.bytes.len);
            foreach (hardware : (bool[2]){ false, true }) {
                run_optical_trace(
                    fixture: &fixture,
                    trace: &trace,
                    surfaces: surfaces[:count],
                    capacity: capacity,
                    hardware: hardware,
                )!!;
                Vec4* actual = (Vec4*)trace.output.bytes.ptr;
                for (uint row = 16; row < 48; row++) {
                    for (uint column = 16; column < 48; column++) {
                        uint pixel = row * OPTICAL_EXTENT + column;
                        assert(bitcast(actual[pixel].w, uint) == bitcast(atlas[pixel].w, uint),
                            "Legacy scalar visibility changed.");
                        for (uint channel = 0; channel < 3; channel++) {
                            double reference = atlas[pixel][channel];
                            double error = math::abs((double)actual[pixel][channel] - reference);
                            double bound = OPTICAL_ABSOLUTE_TOLERANCE
                              + OPTICAL_RELATIVE_TOLERANCE * math::abs(reference);
                            assert(math::is_finite(actual[pixel][channel]) && error <= bound,
                              "trace hardware=%s cap=%s pixel=%s channel=%s actual=%s atlas=%s",
                              hardware, capacity, pixel, channel, actual[pixel][channel], reference);
                            if (blocked || capacity < 6) assert(actual[pixel][channel] == 0);
                        }
                    }
                }
                io::printfn("optical forced hardware=%s cap=%s tied_surfaces=%s interior_samples=1024", hardware, capacity, count);
            }
        }
    }
    check_validation(&fixture.renderer);
}
