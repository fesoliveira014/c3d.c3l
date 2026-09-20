module profile_gpu_example;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::material;
import c3d::profile;
import c3d::render;
import c3d::scene;
import c3d::shader::compile;
import std::io;
import gpu;

const uint FRAME_COUNT @private = 3;
const uint TARGET_SIZE @private = 64;
const char[*] COUNTER_SOURCE @private = $embed("../shaders/custom/counter.comp.glsl");

struct CounterRoot @private {
    gpu::GpuAddress output_address;
    uint value;
    uint padding;
}
$assert CounterRoot::size == 16;
$assert $reflect(CounterRoot.value).offset == 8;

fn void? dispatch_counter(
    render::Renderer* renderer,
    ComputeShaderId shader,
    BufferId output,
    uint value,
) @private {
    CounterRoot root = { .output_address = renderer.buffer_address(output), .value = value };
    BufferId[1] writes = { output };
    renderer.dispatch({
        .shader = shader,
        .root = ((char*)&root)[:CounterRoot::size],
        .groups = { 1, 1, 1 },
        .writes = writes[..],
    })!;
}

fn void? record_frame(
    render::Renderer* renderer,
    Scene* scene,
    Node* camera_node,
    ViewId[] views,
    ComputeShaderId shader,
    BufferId output,
    ulong frame_id,
) @private {
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    profile::GpuScopeToken application = render::@gpu_begin(renderer, "application.render")!;
    dispatch_counter(
        renderer: renderer,
        shader: shader,
        output: output,
        value: (uint)frame_id * 3,
    )!;
    renderer.render_view(scene, camera_node, views[0])!;
    dispatch_counter(
        renderer: renderer,
        shader: shader,
        output: output,
        value: (uint)frame_id * 3 + 1,
    )!;
    renderer.render_view(scene, camera_node, views[1])!;
    renderer.finish_view(views[0])!;
    renderer.finish_view(views[1])!;
    dispatch_counter(
        renderer: renderer,
        shader: shader,
        output: output,
        value: (uint)frame_id * 3 + 2,
    )!;
    render::@gpu_end(renderer, application)!;
    renderer.end_frame()!;
}

fn void? capture_workload(profile::Recorder* recorder) @private {
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    char[] spirv = compile::compile_glsl(mem, (String)COUNTER_SOURCE[..], ShaderStage.COMPUTE)!;
    defer free(spirv.ptr);
    ComputeShaderDesc shader_desc = { .compute = spirv };
    ComputeShaderId shader = assets.add_compute_shader(&shader_desc)!;

    GeometryId geometry;
    @pool() {
        Geometry box = geometry::box(
            allocator: tmem,
            width: 1,
            height: 1,
            depth: 1,
        );
        geometry = assets.add_geometry(&box)!;
    };
    MaterialId material = assets.add_material(material::basic({
        .color = { 0.3f, 0.6f, 0.9f, 1 },
    }))!;
    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    scene.add_mesh(geometry, material)!;
    Node* camera_node = scene.add_camera(camera::perspective_deg(60, 0.1f))!;
    camera_node.local.position = { 0, 0, 3 };

    render::Renderer renderer = render::create_renderer(
        allocator: mem,
        assets: &assets,
        desc: {
            .validation = true,
            .gpu_timings = true,
            .profiler = recorder,
            .application_name = "profile_gpu",
        },
    )!;
    defer render::destroy_renderer(&renderer);
    BufferId output = renderer.create_buffer({ .size = uint::size, .debug_name = "capture_counter" })!;
    ViewId[2] views;
    foreach (&view : views) {
        RenderTargetId target = render::create_render_target(
            &renderer, render::render_target_desc(TARGET_SIZE, TARGET_SIZE))!;
        *view = render::create_view(&renderer, render::texture_view_desc(target))!;
    }

    for (ulong frame_id = 0; frame_id < FRAME_COUNT; frame_id++) {
        profile::@capture(recorder, frame_id) {
            profile::@scope("application.update") { scene.update_world(); };
            profile::@scope("application.render") {
                record_frame(
                    renderer: &renderer,
                    scene: &scene,
                    camera_node: camera_node,
                    views: views[..],
                    shader: shader,
                    output: output,
                    frame_id: frame_id,
                )!;
            };
        };
    }
}

<* Export a headless CPU and GPU capture as JSON. *>
fn int main() {
    profile::Recorder recorder = profile::create_recorder(mem, {
        .frame_capacity = FRAME_COUNT + 1,
        .cpu_scopes_per_frame = 64,
        .max_depth = 8,
        .gpu_scopes_per_frame = 128,
        .label_bytes_per_frame = 8192,
    })!!;
    defer profile::destroy_recorder(&recorder);
    if (catch excuse = capture_workload(&recorder)) {
        io::eprintfn("Capture failed: %s", excuse);
        return 1;
    }
    profile::FrameCaptureView frame = recorder.frame(FRAME_COUNT - 1)!!;
    String json = profile::capture_json(mem, frame);
    defer free(json.ptr);
    io::eprintfn("Recorder storage: %d bytes; GPU state: %s", recorder.allocated_bytes, frame.gpu_state);
    io::printn(json);
    return 0;
}
