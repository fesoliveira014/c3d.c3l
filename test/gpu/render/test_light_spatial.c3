module c3d::render::acceptance;

import c3d;
import c3d::light;
import c3d::asset;
import c3d::camera;
import c3d::material;
import c3d::scene;
import c3d::maths;
import c3d::render @public;
import c3d::shader;
import gpu;
import std::math;

const String LIGHT_CANDIDATE_SOURCE @private = `#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "light_spatial.glsl"
layout(local_size_x = 32) in;
layout(push_constant) uniform Push { uint64_t root_gpu; } pc;
layout(buffer_reference, std430) readonly buffer LightCandidateRoot {
    uint64_t frame;
    uint64_t points;
    uint64_t output_address;
    uint point_count;
    uint stride;
};
GPU_DECLARE_READONLY_ARRAY_REF(LightCandidatePoints, vec4);
layout(buffer_reference, std430) buffer LightCandidateOutput { uint values[]; };
void main() {
    DispatchRoot dispatch = DispatchRoot(pc.root_gpu);
    LightCandidateRoot root = LightCandidateRoot(dispatch.parameters);
    uint point = gl_GlobalInvocationID.x;
    if (point >= root.point_count) return;
    FrameRoot frame = FrameRoot(root.frame);
#ifdef SELECTED_LIGHTS
    vec4 point_value = LightCandidatePoints(root.points).values[point];
    LightList selected = select_lights(frame, point_value.xyz, point_value.w);
#else
    LightCursor cursor = light_cursor(frame.light_spatial, frame.light_count);
#endif
    uint first = point * root.stride;
    uint count = 0u;
    uint index;
#ifdef SELECTED_LIGHTS
    for (uint selected_index = 0u; selected_index < selected.count; selected_index++) {
        index = selected_light_index(frame, selected, selected_index);
#else
    while (next_light(cursor, LightCandidatePoints(root.points).values[point].xyz, index)) {
#endif
        if (index >= frame.light_count || count++ >= frame.light_count) {
            LightCandidateOutput(root.output_address).values[first + frame.light_count] = 1u;
            break;
        }
        LightCandidateOutput(root.output_address).values[first + index]++;
    }
}
`;
const Vec4[15] LIGHT_CANDIDATE_POINTS @private = {
    { 0, 0, 0, 0 }, { 1, 0, 0, 0 }, { -1, 0, 0, 0 },
    { 0, 1, 0, 0 }, { 0, -1, 0, 0 }, { 0, 0, 1, 0 }, { 0, 0, -1, 0 },
    { 4, 2, -5, 0 }, { -8, 0, -16, 0 }, { 0, 0, -31, 0 },
    { 12, 3, -4, 0 }, { 100, 100, 100, 0 }, { -100, -100, -100, 0 },
    { 0.99999994f, 0, 0, 0 }, { 1.00000012f, 0, 0, 0 },
};

struct LightCandidateRoot @private {
    gpu::GpuAddress frame;
    gpu::GpuAddress points;
    gpu::GpuAddress output_address;
    uint point_count;
    uint stride;
}
$assert LightCandidateRoot::size == 32;

struct LightCandidateCapture @private {
    BufferId output;
    gpu::MappedGpuSpan readback;
    bool spatial;
}

struct LightCandidateSnapshot @private {
    LightGpu[8] lights;
    Vec4[15] points;
    LightCandidateCapture capture;
    uint count;
}

fn LightGpu light_candidate_value(Vec3 position, float radius, bool directional = false) @private {
    return {
        .position_range = { position.x, position.y, position.z, radius },
        .kind = (uint)(directional ? LightKind.DIRECTIONAL : LightKind.POINT).ordinal,
        .layers = 1,
        .color_intensity = { 1, 1, 1, 1 },
    };
}

fn void release_light_candidate_capture(Renderer* renderer, LightCandidateCapture* capture) @private {
    renderer.destroy_buffer(capture.output)!!;
    gpu::GpuAllocation allocation = capture.readback.span.allocation();
    gpu::free_allocation(&renderer.device, &allocation)!!;
}

fn LightCandidateCapture? record_light_candidate_capture(
    Renderer* renderer,
    ComputeShaderId shader,
    LightGpu[] lights,
    Vec4[] points,
    gpu::GpuAddress supplied_frame = (gpu::GpuAddress)0,
) @private {
    usz bytes = points.len * (lights.len + 1) * uint::size;
    LightCandidateCapture capture;
    capture.output = renderer.create_buffer({ .size = bytes, .debug_name = "light_candidates" })!;
    defer catch renderer.destroy_buffer(capture.output)!!;
    gpu::AllocationDesc allocation = {
        .size = bytes,
        .alignment = render::STREAM_ALIGNMENT,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access = { .graphics },
        .debug_name = "light_candidates_readback",
    };
    capture.readback = gpu::allocate_mapped_memory(&renderer.device, &allocation)!;
    defer catch {
        gpu::GpuAllocation owned = capture.readback.span.allocation();
        gpu::free_allocation(&renderer.device, &owned)!!;
    }
    Frame* slot = &renderer.frames[renderer.frame_index % render::FRAMES_IN_FLIGHT];
    gpu::GpuAddress frame_address = supplied_frame;
    if (frame_address == (gpu::GpuAddress)0) {
        gpu::MappedGpuSpan frame = slot.upload.take(&renderer.device, FrameRoot::size)!;
        gpu::GpuAddress spatial = render::upload_light_spatial(renderer, lights)!;
        capture.spatial = spatial != (gpu::GpuAddress)0;
        *(FrameRoot*)frame.bytes.ptr = {
            .lights = render::upload_lights(renderer, lights)!,
            .light_count = (uint)lights.len,
            .light_spatial = spatial,
        };
        frame_address = frame.address;
    }
    gpu::MappedGpuSpan positions = slot.upload.take(&renderer.device, points.len * Vec4::size)!;
    mem::copy(positions.bytes.ptr, points.ptr, points.len * Vec4::size);
    gpu::GpuSpan output = gpu::get_allocation_span(&renderer.device, renderer.buffers.get(capture.output).allocation)!;
    gpu::cmd_fill_buffer(&renderer.commands, output, 0)!;
    gpu::Barrier initialized = { .before = { .transfer }, .after = { .compute } };
    gpu::cmd_barrier(&renderer.commands, &initialized)!;
    LightCandidateRoot root = {
        .frame = frame_address,
        .points = positions.address,
        .output_address = renderer.buffer_address(capture.output),
        .point_count = (uint)points.len,
        .stride = (uint)lights.len + 1,
    };
    BufferId[1] writes = { capture.output };
    renderer.dispatch({
        .shader = shader,
        .root = ((char*)&root)[:LightCandidateRoot::size],
        .groups = { ((uint)points.len + 31) / 32, 1, 1 },
        .writes = writes[..],
    })!;
    gpu::Barrier written = { .before = { .compute }, .after = { .transfer } };
    gpu::cmd_barrier(&renderer.commands, &written)!;
    gpu::BufferCopyDesc copy = { .src = output, .dst = capture.readback.span };
    gpu::cmd_copy_buffer(&renderer.commands, &copy)!;
    gpu::Barrier to_host = { .before = { .transfer }, .after = { .host } };
    gpu::cmd_barrier(&renderer.commands, &to_host)!;
    return capture;
}

fn void check_light_candidates(
    Renderer* renderer,
    LightCandidateCapture* capture,
    LightGpu[] lights,
    Vec4[] points,
) @private {
    gpu::invalidate_mapped_span(&renderer.device, capture.readback.span)!!;
    uint* found = (uint*)capture.readback.bytes.ptr;
    foreach (usz point_index, point : points) {
        usz first = point_index * (lights.len + 1);
        assert(found[first + lights.len] == 0);
        foreach (usz index, light : lights) {
            assert(found[first + index] <= 1, "Repeated light %s at point %s", index, point_index);
            Vec3 offset = light.position_range.xyz - point.xyz;
            bool global = light.kind == (uint)LightKind.DIRECTIONAL.ordinal || light.position_range.w == 0;
            bool contained = offset.dot(offset) <= light.position_range.w * light.position_range.w;
            if (!capture.spatial || global || contained) {
                assert(found[first + index] == 1, "Missing light %s at point %s", index, point_index);
            }
        }
    }
}

fn void test_light_spatial_gpu_cursor_keeps_complete_unique_candidates() @test {
    @pool() {
        Fixture fixture;
        create_fixture(mem, &fixture)!!;
        defer destroy_fixture(&fixture);
        Renderer* renderer = &fixture.renderer;
        ComputeShaderId shader = add_compute_shader(&fixture, LIGHT_CANDIDATE_SOURCE)!!;
        LightGpu[320] lights;
        for (uint pattern = 0; pattern < 5; pattern++) {
            foreach (index, &light : lights) {
                Vec3 position = {
                    (float)((int)(index % 13) - 6) * 3,
                    (float)((int)(index % 7) - 3),
                    -(float)(index % 31),
                };
                *light = light_candidate_value(position, 2);
                if (pattern == 1) *light = light_candidate_value({}, 0, index % 2 == 0);
                if (pattern == 2) *light = light_candidate_value({}, 1);
                if (pattern == 3) {
                    if (index % 19 == 0) light.position_range.w = 0;
                    if (index % 5 == 0) light.kind = (uint)LightKind.SPOT.ordinal;
                }
            }
            if (pattern == 4) lights[0].position_range.x = math::FLOAT_MAX;
            uint count = pattern == 0 ? 0 : (uint)lights.len;
            renderer.begin_frame()!!;
            LightCandidateCapture capture = record_light_candidate_capture(
                renderer: renderer,
                shader: shader,
                lights: lights[:count],
                points: LIGHT_CANDIDATE_POINTS[..],
            )!!;
            renderer.end_frame()!!;
            assert(renderer.frame_submitted);
            render::wait_frames(renderer)!!;
            defer release_light_candidate_capture(renderer, &capture);
            assert(capture.spatial == (pattern == 2 || pattern == 3));
            check_light_candidates(
                renderer: renderer,
                capture: &capture,
                lights: lights[:count],
                points: LIGHT_CANDIDATE_POINTS[..],
            );
        }
        check_validation(renderer);
    };
}

fn void test_light_spatial_uploads_remain_independent_across_queued_frames() @test {
    @pool() {
        Fixture fixture;
        create_fixture(mem, &fixture)!!;
        defer destroy_fixture(&fixture);
        Renderer* renderer = &fixture.renderer;
        ComputeShaderId shader = add_compute_shader(&fixture, LIGHT_CANDIDATE_SOURCE)!!;
        LightCandidateSnapshot[8] snapshots;
        for (uint frame = 0; frame < 4; frame++) {
            Vec3 origin = frame > 1 ? (Vec3){ 65536, -65536, 32768 } : (Vec3){};
            renderer.begin_frame({ .reference_position = origin })!!;
            for (uint context = 0; context < 2; context++) {
                LightCandidateSnapshot* snapshot = &snapshots[frame * 2 + context];
                foreach (index, &light : snapshot.lights) {
                    Vec3 position = { (float)index * 3, (float)context, -(float)frame * 2 };
                    *light = light_candidate_value(position - origin, 2);
                }
                snapshot.lights[frame].position_range.w = 0;
                foreach (index, point : LIGHT_CANDIDATE_POINTS) {
                    snapshot.points[index] = { ...(point.xyz - origin), 0 };
                }
                snapshot.count = frame == 1 && context == 0 ? 0u : (frame == 2 ? 3u : 8u);
                snapshot.capture = record_light_candidate_capture(
                    renderer: renderer,
                    shader: shader,
                    lights: snapshot.lights[:snapshot.count],
                    points: snapshot.points[..],
                )!!;
            }
            renderer.end_frame()!!;
            assert(renderer.frame_submitted);
        }
        render::wait_frames(renderer)!!;
        foreach (&snapshot : snapshots) {
            defer release_light_candidate_capture(renderer, &snapshot.capture);
            assert(snapshot.capture.spatial == (snapshot.count > 0));
            check_light_candidates(
                renderer: renderer,
                capture: &snapshot.capture,
                lights: snapshot.lights[:snapshot.count],
                points: snapshot.points[..],
            );
        }
        check_validation(renderer);
    };
}


fn void test_light_spatial_cursor_observes_the_accepted_source_budget() @test {
    @pool() {
        Fixture fixture;
        create_fixture(mem, &fixture)!!;
        defer destroy_fixture(&fixture);
        Scene scene = scene::create_scene(mem, scene::default_scene_desc());
        defer scene::destroy_scene(&scene);
        for (uint index = 0; index < 80; index++) {
            Node* node = scene.add_light(light::point({ 1, 1, 1 }, 1, index % 7 ? 2 : 0))!!;
            node.local.position = { (float)index, 0, 0 };
        }
        scene.update_world();
        LightCounts counts;
        LightExtraction extraction = render::extract_lights(
            allocator: tmem,
            scene: &scene,
            frustum: null,
            view_layers: uint::max,
            capacity: 17,
            counts: &counts,
            atmosphere: null,
            altitude: 0,
        );
        assert(counts.packed == 17 && counts.dropped == 63);
        ComputeShaderId shader = add_compute_shader(&fixture, LIGHT_CANDIDATE_SOURCE)!!;
        fixture.renderer.begin_frame()!!;
        LightCandidateCapture capture = record_light_candidate_capture(
            renderer: &fixture.renderer,
            shader: shader,
            lights: extraction.lights,
            points: LIGHT_CANDIDATE_POINTS[..],
        )!!;
        fixture.renderer.end_frame()!!;
        render::wait_frames(&fixture.renderer)!!;
        defer release_light_candidate_capture(&fixture.renderer, &capture);
        check_light_candidates(
            renderer: &fixture.renderer,
            capture: &capture,
            lights: extraction.lights,
            points: LIGHT_CANDIDATE_POINTS[..],
        );
        check_validation(&fixture.renderer);
    };
}

fn void test_light_spatial_preserves_public_flat_and_cluster_fallbacks() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    ComputeShaderId shader = add_compute_shader(&fixture, LIGHT_CANDIDATE_SOURCE, { "SELECTED_LIGHTS" })!!;
    LightGpu[3] lights = {
        light_candidate_value({}, 1),
        light_candidate_value({}, 0, true),
        light_candidate_value({ 20, 0, 0 }, 1),
    };
    Vec4[2] points = { { 0, 0, 0, 2 }, { 3, 0, 0, 2 } };
    Mat4 identity_matrix = matrix::IDENTITY4;
    for (uint mode = 0; mode < 7; mode++) {
        renderer.begin_frame()!!;
        Frame* slot = &renderer.frames[renderer.frame_index % render::FRAMES_IN_FLIGHT];
        gpu::MappedGpuSpan range = slot.upload.take(&renderer.device, ClusterRange::size)!!;
        *(ClusterRange*)range.bytes.ptr = {
            .count = mode == 2 ? 0u : 1u,
            .overflow = mode == 1 || mode == 2 ? 1u : 0u,
        };
        gpu::MappedGpuSpan index = slot.upload.take(&renderer.device, uint::size)!!;
        *(uint*)index.bytes.ptr = 0;
        gpu::MappedGpuSpan global = slot.upload.take(&renderer.device, uint::size)!!;
        *(uint*)global.bytes.ptr = 1;
        gpu::MappedGpuSpan clusters = slot.upload.take(&renderer.device, ClusterGpu::size)!!;
        *(ClusterGpu*)clusters.bytes.ptr = {
            .ranges = range.address,
            .indices = index.address,
            .globals = global.address,
            .depth = { mode == 3 ? 4.0f : 1.0f, 4, 1, -1 },
            .tiles_x = 1,
            .tiles_y = 1,
            .depth_slices = 3,
            .lights_per_cluster = 1,
            .global_count = 1,
            .orthographic = 1,
            .view_proj = bitcast(identity_matrix, Mat4f),
        };
        gpu::MappedGpuSpan frame = slot.upload.take(&renderer.device, FrameRoot::size)!!;
        *(FrameRoot*)frame.bytes.ptr = {
            .lights = render::upload_lights(renderer, lights[..])!!,
            .light_count = (uint)lights.len,
            .flags = mode == 4 ? 0u : shader::FRAME_LIGHTS_CLUSTERED,
            .clusters = mode == 5 ? (gpu::GpuAddress)0 : clusters.address,
            .light_spatial = render::upload_light_spatial(renderer, lights[..])!!,
        };
        points[0].w = mode == 6 ? 5 : 1.5f;
        points[1].w = points[0].w;
        LightCandidateCapture capture = record_light_candidate_capture(
            renderer: renderer,
            shader: shader,
            lights: lights[..],
            points: points[..],
            supplied_frame: frame.address,
        )!!;
        renderer.end_frame()!!;
        render::wait_frames(renderer)!!;
        defer release_light_candidate_capture(renderer, &capture);
        gpu::invalidate_mapped_span(&renderer.device, capture.readback.span)!!;
        uint* found = (uint*)capture.readback.bytes.ptr;
        for (uint point = 0; point < 2; point++) {
            uint first = point * 4;
            assert(found[first] == 1 && found[first + 1] == 1 && found[first + 3] == 0);
            assert(found[first + 2] == (mode == 0 && point == 0 ? 0u : 1u));
        }
    }
    check_validation(renderer);
}

fn gpu::MappedGpuSpan? create_light_pixel_readback(Renderer* renderer) @private {
    gpu::AllocationDesc desc = {
        .size = Vec4::size,
        .alignment = render::STREAM_ALIGNMENT,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access = { .graphics },
        .debug_name = "light_pixel_readback",
    };
    return gpu::allocate_mapped_memory(&renderer.device, &desc);
}

fn void? record_light_pixel_readback(
    Renderer* renderer,
    RenderTargetId target,
    gpu::GpuSpan destination,
) @private {
    Target* image = &renderer.targets.get(target).target;
    gpu::TextureState previous = image.state;
    image.transition(&renderer.commands, render::TRANSFER_SOURCE_STATE)!;
    gpu::TextureBufferCopyDesc copy = {
        .texture = image.texture,
        .dst = destination,
        .x = image.width / 2,
        .y = image.height / 2,
        .width = 1,
        .height = 1,
        .depth = 1,
    };
    gpu::cmd_copy_texture_to_buffer(&renderer.commands, &copy)!;
    gpu::Barrier to_host = { .before = { .transfer }, .after = { .host } };
    gpu::cmd_barrier(&renderer.commands, &to_host)!;
    return image.transition(&renderer.commands, previous);
}

fn void check_light_spatial_views(bool admitted) @private {
    Fixture fixture;
    create_fixture(mem, &fixture, max_lights: admitted ? 4096 : 0)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    Scene scene = scene::create_scene(mem, { .max_nodes = admitted ? 8200 : 128 });
    defer scene::destroy_scene(&scene);
    scene.ambient_intensity = 0;
    MaterialId white = fixture.assets.add_material(material::standard({
        .base_color = { 1, 1, 1, 1 },
        .roughness = 1,
    }))!!;
    scene.add_mesh(fixture.box, white)!!.layers = 3;
    Node*[2] cameras;
    RenderTargetId[2] targets;
    ViewId[2] views;
    for (uint index = 0; index < 2; index++) {
        cameras[index] = scene.add_camera(camera::perspective_deg(60, 0.1f))!!;
        cameras[index].local.position = { 0, 0, 3 };
        scene.get(cameras[index], Camera).layers = 1u << index;
        targets[index] = render::create_render_target(
            renderer,
            render::render_target_desc(32, 32, PixelFormat.RGBA32_FLOAT),
        )!!;
        ViewDesc desc = render::texture_view_desc(targets[index]);
        desc.lights = LightSelection.CLUSTERED;
        desc.post.anti_aliasing = AntiAliasing.NONE;
        views[index] = render::create_view(renderer, desc)!!;
    }
    Node* red = scene.add_light(light::point({ 1, 0, 0 }, 2, 8))!!;
    red.local.position = { -0.5f, 0, 2 };
    red.layers = 1;
    scene.get(red, Light).layers = 1;
    Node* green = scene.add_light(light::point({ 0, 1, 0 }, 2, 8))!!;
    green.local.position = { 0.5f, 0, 2 };
    green.layers = 2;
    scene.get(green, Light).layers = 2;
    if (admitted) {
        for (uint index = 0; index < 4095; index++) {
            for (uint layer = 0; layer < 2; layer++) {
                Node* background = scene.add_light(light::point({ 1, 1, 1 }, 1, 0.2f))!!;
                background.local.position = { ((float)(index % 64) - 31.5f) * 0.25f,
                    ((float)(index / 64) - 31.5f) * 0.25f, -20 };
                background.layers = 1u << layer;
                scene.get(background, Light).layers = background.layers;
            }
        }
    }
    scene.update_world();
    renderer.prepare_scene(&scene)!!;
    gpu::MappedGpuSpan[8] captures;
    foreach (&capture : captures) *capture = create_light_pixel_readback(renderer)!!;
    defer {
        render::wait_frames(renderer)!!;
        foreach (capture : captures) {
            gpu::GpuAllocation allocation = capture.span.allocation();
            gpu::free_allocation(&renderer.device, &allocation)!!;
        }
    }
    for (uint frame = 0; frame < 4; frame++) {
        if (frame == 1) red.local.position = { 100, 0, 2 };
        if (frame == 2) {
            red.local.position = { -0.5f, 0, 2 };
            scene.remove(green);
        }
        Vec3 origin;
        if (frame == 3) {
            Node* blue = scene.add_light(light::point({ 0, 0, 1 }, 2, 8))!!;
            blue.local.position = { 0.5f, 0, 2 };
            blue.layers = 2;
            scene.get(blue, Light).layers = 2;
            origin = { 65536, 0, 65536 };
            scene.root.local.position = origin;
        }
        scene.update_world();
        renderer.begin_frame({ .reference_position = origin })!!;
        for (uint view_index = 0; view_index < 2; view_index++) {
            renderer.render_view(&scene, cameras[view_index], views[view_index])!!;
            renderer.finish_view(views[view_index])!!;
            bool empty = frame == 1 && view_index == 0 || frame == 2 && view_index == 1;
            assert(renderer.view_stats(views[view_index])!!.lights == (admitted ? 4095u : 0u) + (empty ? 0u : 1u));
            record_light_pixel_readback(
                renderer,
                targets[view_index],
                captures[frame * 2 + view_index].span,
            )!!;
        }
        renderer.end_frame()!!;
        assert(renderer.frame_submitted);
    }
    render::wait_frames(renderer)!!;
    for (uint frame = 0; frame < 4; frame++) {
        for (uint view_index = 0; view_index < 2; view_index++) {
            gpu::MappedGpuSpan capture = captures[frame * 2 + view_index];
            gpu::invalidate_mapped_span(&renderer.device, capture.span)!!;
            Vec4 color = *(Vec4*)capture.bytes.ptr;
            bool empty = frame == 1 && view_index == 0 || frame == 2 && view_index == 1;
            uint channel = view_index == 0 ? 0u : (frame == 3 ? 2u : 1u);
            for (uint component = 0; component < 3; component++) {
                assert(math::is_finite(color[component]));
                if (!empty && component == channel) {
                    assert(color[component] > 0.01f);
                } else {
                    assert(math::abs(color[component]) < 0.0001f);
                }
            }
        }
    }
    check_validation(renderer);
}

fn void test_light_spatial_views_keep_layers_and_light_changes_across_queued_frames() @test {
    check_light_spatial_views(false);
}

fn void test_light_spatial_admitted_views_keep_layers_and_light_changes_across_queued_frames() @test {
    check_light_spatial_views(true);
}

fn void test_light_spatial_probe_scenes_keep_their_own_finite_lights() @test {
    foreach (ray_queries : TRACE_KINDS) {
        @pool() {
            Fixture fixture;
            create_fixture(mem, &fixture, ray_queries: ray_queries)!!;
            defer destroy_fixture(&fixture);
            ProbeRoom first = create_probe_room(&fixture, lamp: true)!!;
            defer scene::destroy_scene(&first.scene);
            ProbeRoom second = create_probe_room(&fixture, lamp: true)!!;
            defer scene::destroy_scene(&second.scene);
            first.scene.get(first.lamp, Light).color = { 1, 0, 0 };
            second.scene.get(second.lamp, Light).color = { 0, 1, 0 };
            first.scene.get(first.volume, ProbeVolume).update.hysteresis = 0;
            second.scene.get(second.volume, ProbeVolume).update.hysteresis = 0;
            ProbeView first_view = create_probe_view(&fixture, ShadingPath.FORWARD)!!;
            defer destroy_probe_view(&fixture, &first_view);
            ProbeView second_view = create_probe_view(&fixture, ShadingPath.FORWARD)!!;
            defer destroy_probe_view(&fixture, &second_view);
            for (uint frame = 0; frame < 8; frame++) {
                fixture.renderer.begin_frame()!!;
                fixture.renderer.render_view(&first.scene, first.camera, first_view.view)!!;
                fixture.renderer.finish_view(first_view.view)!!;
                fixture.renderer.render_view(&second.scene, second.camera, second_view.view)!!;
                fixture.renderer.finish_view(second_view.view)!!;
                fixture.renderer.end_frame()!!;
                assert(fixture.renderer.stats.probe_updates == 2);
            }
            Vec3 first_color = interior_channels(&fixture, &first);
            Vec3 second_color = interior_channels(&fixture, &second);
            assert(first_color.x > first_color.y + 0.02f);
            assert(second_color.y > second_color.x + 0.02f);
            check_validation(&fixture.renderer);
        };
    }
}

fn void test_light_spatial_cursor_keeps_operand_cancellation_candidates() @test {
    @pool() {
        Fixture fixture;
        create_fixture(mem, &fixture)!!;
        defer destroy_fixture(&fixture);
        Renderer* renderer = &fixture.renderer;
        ComputeShaderId shader = add_compute_shader(&fixture, LIGHT_CANDIDATE_SOURCE)!!;
        float[5] radii = { 1.1f, 0.1f, 10, 1e-10f, 1e10f };
        foreach (radius : radii) {
            for (uint axis = 0; axis < 3; axis++) {
                for (uint sign = 0; sign < 2; sign++) {
                    Vec3 center;
                    Vec4[1] points;
                    center[axis] = sign ? radius : -radius;
                    points[0][axis] = (sign ? -1.0f : 1.0f) * (radius == 1.1f ? 2e-8f : radius * math::FLOAT_EPSILON * 0.125f);
                    LightGpu[1] lights = { light_candidate_value(center, radius) };
                    Vec3 offset = center - points[0].xyz;
                    assert(offset.dot(offset) <= radius * radius);
                    renderer.begin_frame()!!;
                    LightCandidateCapture capture = record_light_candidate_capture(
                        renderer: renderer,
                        shader: shader,
                        lights: lights[..],
                        points: points[..],
                    )!!;
                    renderer.end_frame()!!;
                    render::wait_frames(renderer)!!;
                    defer release_light_candidate_capture(renderer, &capture);
                    assert(capture.spatial);
                    check_light_candidates(
                        renderer: renderer,
                        capture: &capture,
                        lights: lights[..],
                        points: points[..],
                    );
                }
            }
        }
        check_validation(renderer);
    };
}

fn void test_light_spatial_cursor_keeps_subnormal_range_candidates() @test {
    @pool() {
        Fixture fixture;
        create_fixture(mem, &fixture)!!;
        defer destroy_fixture(&fixture);
        Renderer* renderer = &fixture.renderer;
        ComputeShaderId shader = add_compute_shader(&fixture, LIGHT_CANDIDATE_SOURCE)!!;
        LightGpu[1] lights = { light_candidate_value({}, 3e-23f) };
        Vec4[1] points = { { 4e-23f, 0, 0, 0 } };
        Vec3 offset = lights[0].position_range.xyz - points[0].xyz;
        assert(offset.dot(offset) <= lights[0].position_range.w * lights[0].position_range.w);
        renderer.begin_frame()!!;
        LightCandidateCapture capture = record_light_candidate_capture(
            renderer: renderer,
            shader: shader,
            lights: lights[..],
            points: points[..],
        )!!;
        renderer.end_frame()!!;
        render::wait_frames(renderer)!!;
        defer release_light_candidate_capture(renderer, &capture);
        assert(!capture.spatial);
        check_light_candidates(
            renderer: renderer,
            capture: &capture,
            lights: lights[..],
            points: points[..],
        );
        check_validation(renderer);
    };
}
