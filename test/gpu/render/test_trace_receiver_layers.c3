module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::material;
import c3d::render @public;
import c3d::scene;
import c3d::shader;
import gpu;
import std::math::vector;

const char[*] RECEIVER_LAYER_SOURCE @private = $embed("trace_receiver_layers.comp.glsl");

struct ReceiverLayerRoot @private {
    gpu::GpuAddress scene;
    gpu::GpuAddress frame;
    gpu::GpuAddress output_address;
}
$assert ReceiverLayerRoot::size == 24;

fn void test_trace_receiver_full_width_layers_filter_punctual_lighting_on_both_backends() @test {
    foreach (hardware : (bool[2]){ false, true }) {
        Fixture fixture;
        create_fixture(mem, &fixture, ray_queries: hardware)!!;
        defer destroy_fixture(&fixture);
        String[1] defines = { hardware ? "SCENE_TRACE_RAY_QUERY" : "SCENE_TRACE_BVH" };
        ComputeShaderId shader_id = add_compute_shader(&fixture, (String)RECEIVER_LAYER_SOURCE[..], defines[..])!!;
        MaterialId material_id = fixture.assets.add_material(material::standard())!!;
        GeometryId geometry_id;
        @pool() {
            Geometry geometry = geometry::box(tmem, 2, 2, 0.5f);
            geometry_id = fixture.assets.add_geometry(&geometry)!!;
        };
        Node* owner = fixture.scene.add_mesh(geometry_id, material_id)!!;
        owner.local.position.z = -4;
        fixture.scene.update_world();
        Renderer* renderer = &fixture.renderer;
        BufferId output = renderer.create_buffer({ .size = Vec4::size, .debug_name = "receiver_layers" })!!;
        gpu::AllocationDesc readback_desc = {
            .size = Vec4::size,
            .alignment = 16,
            .memory_class = gpu::MemoryClass.CPU_READ,
            .access = { .graphics },
            .debug_name = "receiver_layers",
        };
        gpu::MappedGpuSpan readback = gpu::allocate_mapped_memory(&renderer.device, &readback_desc)!!;
        defer {
            gpu::GpuAllocation allocation = readback.span.allocation();
            gpu::free_allocation(&renderer.device, &allocation)!!;
        }
        LightGpu[3] lights = {
            { .direction_cos_outer = { 0, 0, -1, 0 }, .color_intensity = { 1, 0, 0, 1 }, .layers = 1 },
            { .direction_cos_outer = { 0, 0, -1, 0 }, .color_intensity = { 0, 1, 0, 1 }, .layers = 2 },
            { .direction_cos_outer = { 0, 0, -1, 0 }, .color_intensity = { 0, 0, 1, 1 }, .layers = 0x80000000 },
        };
        foreach (layers : (uint[5]){ 0, 1, 2, 0x80000000, 0x80000001 }) {
            owner.layers = layers;
            renderer.begin_frame()!!;
            defer catch render::abort_frame(renderer);
            gpu::GpuAddress scene_root = renderer.prepare_scene_trace(
                &fixture.scene, hardware ? TraceKind.HARDWARE : TraceKind.SOFTWARE)!!;
            FrameRoot frame = {
                .lights = upload_trace_segment(renderer, ((char*)&lights)[:lights.len * LightGpu::size])!!,
                .light_count = 3,
            };
            ReceiverLayerRoot root = {
                .scene = scene_root,
                .frame = upload_trace_segment(renderer, ((char*)&frame)[:FrameRoot::size])!!,
                .output_address = renderer.buffer_address(output),
            };
            BufferId[1] writes = { output };
            renderer.dispatch({
                .shader = shader_id,
                .root = ((char*)&root)[:ReceiverLayerRoot::size],
                .groups = { 1, 1, 1 },
                .writes = writes[..],
            })!!;
            gpu::Barrier transfer = { .before = { .all }, .after = { .transfer } };
            gpu::cmd_barrier(&renderer.commands, &transfer)!!;
            gpu::BufferCopyDesc copy = {
                .src = gpu::get_allocation_span(&renderer.device, renderer.buffers.get(output).allocation)!!,
                .dst = readback.span,
            };
            gpu::cmd_copy_buffer(&renderer.commands, &copy)!!;
            gpu::Barrier host = { .before = { .transfer }, .after = { .host } };
            gpu::cmd_barrier(&renderer.commands, &host)!!;
            renderer.end_frame()!!;
            render::wait_frames(renderer)!!;
            gpu::invalidate_mapped_span(&renderer.device, readback.span)!!;
            Vec4 actual = *(Vec4*)readback.bytes.ptr;
            assert(bitcast(actual.w, uint) == layers);
            for (uint channel = 0; channel < 3; channel++) {
                bool eligible = (layers & lights[channel].layers) != 0;
                assert(eligible ? actual[channel] > 0 : actual[channel] == 0,
                    "Receiver layers=%s backend=%s channel=%s actual=%s", layers, hardware, channel, actual[channel]);
            }
        }
        check_validation(renderer);
    }
}
