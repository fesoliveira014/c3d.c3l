module origin_benchmark;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::render;
import c3d::scene;
import std::io;
import std::math;
import std::time;
import std::time::clock;

const uint WARMUP_FRAMES @local = 32;
const uint SAMPLE_FRAMES @local = 128;
const uint TOTAL_FRAMES @local = WARMUP_FRAMES + SAMPLE_FRAMES + render::FRAMES_IN_FLIGHT + 1;
const uint POPULATION @local = 2048;

struct Sample @local {
    double record_ms;
    float trace_ms;
    float gpu_pass_ms;
    float gpu_upload_ms;
    float gpu_trace_ms;
    uint uploads;
    uint bytes;
    uint tlas_builds;
    bool completed;
}

fn int main(String[] args) {
    String policy = args.len > 1 ? args[1] : "zero";
    bool population = args.len > 2 && args[2] == "population";
    bool crossing = policy != "zero";
    bool exact = policy == "exact";
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    Scene scene = scene::create_scene(mem, { .max_nodes = 16 });
    defer scene::destroy_scene(&scene);
    GeometryId box;
    GeometryId ground;
    @pool() {
        Geometry shape = geometry::box(
            allocator: tmem,
            width: 1,
            height: 1,
            depth: 1,
        );
        box = assets.add_geometry(&shape)!!;
        Geometry plane = geometry::plane(tmem, 128, 128);
        ground = assets.add_geometry(&plane)!!;
    };
    StandardParams params = material::STANDARD_PARAMS_DEFAULT;
    params.base_color = { 0.3f, 0.5f, 0.7f, 1 };
    MaterialId material = assets.add_material(material::standard(params))!!;
    scene.add_mesh(ground, material)!!;
    if (population) {
        Transform[] placements = mem::new_array(Transform, POPULATION);
        defer free(placements);
        foreach (index, &placement : placements) {
            *placement = maths::TRANSFORM_IDENTITY;
            placement.position = {
                (float)(index % 32) - 16,
                0.5f + (float)(index / 1024),
                (float)((index / 32) % 32) - 16,
            };
        }
        scene.add_instanced_mesh(
            geometry: box,
            material: material,
            capacity: POPULATION,
            transforms: placements[..],
        )!!;
    } else {
        for (uint index = 0; index < 3; index++) {
            Node* node = scene.add_mesh(box, material)!!;
            node.local.position = { (float)index * 4 - 4, 1, 0 };
            node.local.scale = { 2, 2, 2 };
        }
    }
    Light sun = light::directional({ 1, 1, 1 }, 2);
    sun.shadow.cascades = 4;
    sun.shadow.max_distance = 150;
    Node* light = scene.add_light(sun)!!;
    light.local.rotation = maths::look_rotation((Vec3){ -1, -2, -1 }.normalize(), { 0, 1, 0 });
    Node* camera = scene.add_camera(camera::perspective_deg(60, 0.1f, 300))!!;
    camera.local.position = { 0, 30, 45 };
    camera.local.rotation = maths::look_rotation({ 0, -30, -45 }, { 0, 1, 0 });
    Vec3 offset = crossing ? (Vec3){ 65536, 0, 65536 } : (Vec3){};
    scene.root.local.position = offset;
    scene.update_world();
    Renderer renderer = render::create_renderer(
        allocator: mem,
        assets: &assets,
        desc: {
            .validation = true, .gpu_timings = true, .ray_queries = true,
            .shadow_resolution = 1024, .max_shadow_layers = 4,
            .application_name = "origin_benchmark",
        },
    )!!;
    defer render::destroy_renderer(&renderer);
    RenderTargetId output = render::create_render_target(&renderer, render::render_target_desc(512, 512))!!;
    ViewDesc view_desc = render::texture_view_desc(output);
    view_desc.post.anti_aliasing = AntiAliasing.NONE;
    ViewId view = render::create_view(&renderer, view_desc)!!;
    Sample[TOTAL_FRAMES] samples;
    for (uint frame = 0; frame < TOTAL_FRAMES; frame++) {
        Vec3 reference = crossing ? offset + (Vec3){ (float)frame * 4, 0, 0 } : (Vec3){};
        renderer.begin_frame({ .time = 1.25, .delta = 1.0f / 60, .reference_position = reference })!!;
        // Experimental exact-reference policy, before any coordinate-dependent work.
        if (exact) renderer.frame_origin = reference;
        if (renderer.stats.gpu_timing_state == GpuTimingState.READY) {
            ulong completed = renderer.stats.gpu_frame_index;
            if (completed < TOTAL_FRAMES) {
                samples[completed].gpu_pass_ms = 0;
                foreach (duration : renderer.stats.gpu_pass_ms) samples[completed].gpu_pass_ms += duration;
                samples[completed].gpu_upload_ms = renderer.stats.gpu_pass_ms[Pass.UPLOADS.ordinal];
                samples[completed].gpu_trace_ms = renderer.stats.gpu_pass_ms[Pass.ACCELERATION_BUILD.ordinal];
                samples[completed].completed = true;
            }
        }
        time::Clock started = clock::now();
        renderer.prepare_scene_trace(&scene, TraceKind.HARDWARE)!!;
        renderer.render_view(&scene, camera, view)!!;
        renderer.finish_view(view)!!;
        renderer.end_frame()!!;
        samples[frame].record_ms = (double)(clock::now() - started) / 1_000_000;
        samples[frame].trace_ms = renderer.stats.trace_build_ms;
        samples[frame].uploads = renderer.stats.uploads;
        samples[frame].bytes = renderer.stats.upload_bytes;
        samples[frame].tlas_builds = renderer.stats.tlas_builds;
    }
    render::wait_frames(&renderer)!!;
    renderer.log.check_validation()!!;
    io::printn("policy,scene,frame,cpu_record_ms,trace_ms,gpu_pass_ms,"
        "gpu_upload_ms,gpu_trace_ms,uploads,bytes,tlas_builds");
    for (uint frame = WARMUP_FRAMES; frame < WARMUP_FRAMES + SAMPLE_FRAMES; frame++) {
        Sample sample = samples[frame];
        if (!sample.completed || sample.gpu_pass_ms <= 0) return 2;
        io::printfn("%s,%s,%d,%.6f,%.6f,%.6f,%.6f,%.6f,%d,%d,%d",
            policy, population ? "population" : "shadows", frame,
            sample.record_ms, sample.trace_ms, sample.gpu_pass_ms, sample.gpu_upload_ms, sample.gpu_trace_ms,
            sample.uploads, sample.bytes, sample.tlas_builds);
    }
    return 0;
}
