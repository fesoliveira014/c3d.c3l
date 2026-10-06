module posed_trace_benchmark;

import c3d;
import c3d::asset;
import c3d::asset::gltf;
import c3d::camera;
import c3d::light;
import c3d::maths;
import c3d::model;
import c3d::render;
import c3d::scene;
import c3d::shader::compile;
import gpu;
import std::io;
import std::math;
import std::time;
import std::time::clock;

const String MODEL_PATH @local = "examples/assets/quaternius/AnimationLibrary_Godot.glb";
const String STRONG_CLIP @local = "Dance_Loop";
const String CROWD_CLIP @local = "Walk_Loop";
const char[*] BENCH_SOURCE @local = $embed("bench_posed_trace.comp.glsl");
const uint GROUP_SIZE @local = 8;           // mirrored as local_size_x and _y in bench_posed_trace.comp.glsl
const uint WARMUP_FRAMES @local = 32;
const uint SAMPLE_FRAMES @local = 128;
const uint TOTAL_FRAMES @local = WARMUP_FRAMES + SAMPLE_FRAMES + render::FRAMES_IN_FLIGHT + 1;
const uint WIDTH @local = 1920;
const uint HEIGHT @local = 1080;
const float STRONG_TIME @local = 0.5f;      // seconds into the strong clip held by the strong pose
const float GRID_SPACING @local = 2;
const float FRAME_DELTA @local = 1.0f / 60;
const uint PARTS_PER_CHARACTER @local = 2;  // the example Mannequin draws two skinned parts
const uint NODES_PER_CHARACTER @local = 160; // joints, mesh nodes and spare room of one instantiated character
const uint SCENE_NODE_RESERVE @local = 64;   // the sun, the camera and spare nodes
const uint CAPACITY_HEADROOM @local = 2;     // trace rows and slots at twice the parts, so no capacity limits a sample
const uint TRACE_ROW_RESERVE @local = 64;    // rows beyond the characters' parts

struct BenchRoot @local {
    Mat4f           inv_view_proj;
    Vec4f           camera;
    gpu::GpuAddress scene;
    gpu::GpuAddress output_address;
    uint            width;
    uint            height;
    uint            _pad0;
    uint            _pad1;
}
$assert BenchRoot::size == 112;

struct Sample @local {
    float gpu_pose_ms;
    float gpu_build_ms;
    float gpu_trace_ms;
    float trace_build_ms;
    usz   posed_bytes;
    uint  poses;
    uint  refits;
    uint  updates;
    uint  builds;
    bool  completed;
}

fn ClipId? find_clip(AssetStore* assets, ModelId model, String name) @local {
    foreach (clip : assets.model(model).data.clips) {
        if (assets.clip(clip).data.name == name) return clip;
    }
    return c3d::ASSET_FORMAT_ERROR~;
}

fn void print_storage_sizes(Renderer* renderer, GeometryId geometry) @local {
    GpuGeometry* mirror = &renderer.geometries[geometry.index];
    gpu::AccelerationStructureIndexType index_type = mirror.layout.flags.indices_u16
      ? gpu::AccelerationStructureIndexType.U16 : gpu::AccelerationStructureIndexType.U32;
    gpu::AccelerationStructureGeometryDesc[1] geometries = {{
        .kind      = gpu::AccelerationStructureGeometryKind.TRIANGLES,
        .triangles = {
            .max_vertex_count    = mirror.layout.vertex_count,
            .max_primitive_count = mirror.layout.index_count / 3,
            .index_type          = index_type,
        },
    }};
    gpu::AccelerationStructureDesc fixed = {
        .kind       = gpu::AccelerationStructureKind.BOTTOM_LEVEL,
        .geometries = geometries[..],
        .flags      = { .prefer_fast_trace },
    };
    gpu::AccelerationStructureDesc updatable = fixed;
    updatable.flags = { .allow_update, .prefer_fast_trace };
    gpu::AccelerationStructureRequirements without = gpu::get_acceleration_structure_requirements(
        &renderer.device,
        &fixed,
    )!!;
    gpu::AccelerationStructureRequirements with = gpu::get_acceleration_structure_requirements(
        &renderer.device,
        &updatable,
    )!!;
    io::printfn(
        "blas_storage_bytes,without_allow_update,%d,with_allow_update,%d,update_scratch_bytes,%d",
        without.storage_size,
        with.storage_size,
        with.update_scratch_size,
    );
}

<*
 Usage: posed_trace_bench mannequin <count> <software|hardware> <rest|strong|animate> [fresh]
        posed_trace_bench crowd <count> <software|hardware>
 Run from the repository root; prints one CSV row per sampled frame.
*>
fn int main(String[] args) {
    if (args.len < 4) {
        io::eprintn("usage: posed_trace_bench mannequin <count> <software|hardware> <rest|strong|animate> [fresh]");
        io::eprintn("       posed_trace_bench crowd <count> <software|hardware>");
        return 1;
    }
    bool crowd = args[1] == "crowd";
    uint count = (uint)args[2].to_int()!!;
    bool hardware = args[3] == "hardware";
    String pose = !crowd && args.len > 4 ? args[4] : "animate";
    bool fresh = !crowd && args.len > 5 && args[5] == "fresh";
    TraceKind kind = hardware ? TraceKind.HARDWARE : TraceKind.SOFTWARE;

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    ModelId model = gltf::load_model(&assets, MODEL_PATH)!!;
    Scene scene = scene::create_scene(mem, { .max_nodes = count * NODES_PER_CHARACTER + SCENE_NODE_RESERVE });
    defer scene::destroy_scene(&scene);

    uint columns = (uint)math::ceil(math::sqrt((float)count));
    if (crowd) {
        CrowdInstance[] instances = mem::new_array(CrowdInstance, count);
        defer free(instances);
        ClipId? found_walk = find_clip(&assets, model, CROWD_CLIP);
        if (catch found_walk) {
            io::eprintfn("no clip named %s in %s", CROWD_CLIP, MODEL_PATH);
            return 1;
        }
        ClipId walk = found_walk;
        foreach (index, &instance : instances) {
            Transform placement = maths::TRANSFORM_IDENTITY;
            placement.position = {
                ((float)(index % columns) - (float)columns / 2) * GRID_SPACING,
                0,
                -(float)(index / columns) * GRID_SPACING,
            };
            *instance = {
                .placement = placement,
                .pose      = { .clip = walk, .time = (float)index * 0.1f, .speed = 1, .loop = true },
                .color     = { 1, 1, 1, 1 },
            };
        }
        model::add_crowd(
            assets:      &assets,
            scene:       &scene,
            model:       model,
            capacity:    count,
            pose_bounds: { .min = { -1, -0.2f, -1 }, .max = { 1, 2.2f, 1 } },
            instances:   instances,
            trace:       true,
        )!!;
    } else {
        ClipId? found_strong = find_clip(&assets, model, STRONG_CLIP);
        if (catch found_strong) {
            io::eprintfn("no clip named %s in %s", STRONG_CLIP, MODEL_PATH);
            return 1;
        }
        ClipId strong = found_strong;
        for (uint index = 0; index < count; index++) {
            Node* node = model::instantiate(&assets, &scene, model, name: "mannequin")!!;
            node.local.position = {
                ((float)(index % columns) - (float)columns / 2) * GRID_SPACING,
                0,
                -(float)(index / columns) * GRID_SPACING,
            };
            if (pose == "rest") continue;
            anim::add_animator(&scene, node);
            Animator* animator = scene.get(node, Animator);
            AnimationActionId action_id = animator.play(&assets, strong)!!;
            Action* action = animator.action(action_id);
            action.time = pose == "strong" ? STRONG_TIME : (float)index * 0.1f;
            action.speed = pose == "strong" ? 0 : 1;
        }
    }
    Light sun = light::directional({ 1, 1, 1 }, 2);
    Node* sun_node = scene.add_light(sun, name: "sun")!!;
    sun_node.local.rotation = maths::look_rotation((Vec3){ -1, -2, -1 }.normalize(), { 0, 1, 0 });
    float extent = (float)columns * GRID_SPACING;
    Node* camera_node = scene.add_camera(camera::perspective_deg(60, 0.1f, 1000), name: "camera")!!;
    camera_node.local.position = { 0, extent * 0.5f + 2, extent * 0.5f + 4 };
    camera_node.local.rotation = maths::look_rotation(
        (Vec3){ 0, 1, -extent * 0.5f } - camera_node.local.position,
        { 0, 1, 0 },
    );
    scene.update_world();

    Renderer renderer = render::create_renderer(
        allocator: mem,
        assets:    &assets,
        desc:      {
            .validation                = true,
            .gpu_timings               = true,
            .ray_queries               = hardware,
            .application_name          = "posed_trace_benchmark",
            .max_trace_instances       = count * PARTS_PER_CHARACTER * CAPACITY_HEADROOM + TRACE_ROW_RESERVE,
            .max_posed_trace_instances = count * PARTS_PER_CHARACTER * CAPACITY_HEADROOM,
        },
    )!!;
    defer render::destroy_renderer(&renderer);

    char[] spirv = compile::compile_glsl(
        allocator: mem,
        source:    (String)BENCH_SOURCE[..],
        stage:     ShaderStage.COMPUTE,
        defines:   { hardware ? "SCENE_TRACE_RAY_QUERY" : "SCENE_TRACE_BVH" },
    )!!;
    defer free(spirv.ptr);
    ComputeShaderDesc shader_desc = { .compute = spirv };
    ComputeShaderId shader = assets.add_compute_shader(&shader_desc)!!;
    BufferId output = renderer.create_buffer({
        .size       = (usz)WIDTH * HEIGHT * float::size,
        .debug_name = "bench_trace",
    })!!;

    Sample[TOTAL_FRAMES] samples;
    bool storage_printed;
    Camera* camera = scene.get(camera_node, Camera);
    uint attempts;
    while (renderer.frame_index < TOTAL_FRAMES) {
        bool aborted = fresh && attempts++ % 2 == 1;
        renderer.begin_frame({ .time = 1.0, .delta = FRAME_DELTA })!!;
        ulong frame = renderer.frame_index;
        if (renderer.stats.gpu_timing_state == GpuTimingState.READY) {
            ulong completed = renderer.stats.gpu_frame_index;
            if (completed < TOTAL_FRAMES) {
                samples[completed].gpu_pose_ms = renderer.stats.gpu_pass_ms[Pass.TRACE_POSE.ordinal];
                samples[completed].gpu_build_ms = renderer.stats.gpu_pass_ms[Pass.ACCELERATION_BUILD.ordinal];
                samples[completed].gpu_trace_ms = renderer.stats.gpu_pass_ms[Pass.CUSTOM_COMPUTE.ordinal];
                samples[completed].completed = true;
            }
        }
        if (pose == "animate") anim::update(&assets, &scene, FRAME_DELTA);
        if (crowd) anim::crowd_update(&assets, &scene, FRAME_DELTA);
        if (pose == "strong") anim::update(&assets, &scene, 0);
        scene.update_world();
        CameraMatrices matrices = camera::derive_matrices(*camera, camera_node.world, { WIDTH, HEIGHT });
        BenchRoot root = {
            .inv_view_proj  = bitcast(matrices.inv_view_proj, Mat4f),
            .camera         = { matrices.position.x, matrices.position.y, matrices.position.z, 1 },
            .scene          = renderer.prepare_scene_trace(&scene, kind)!!,
            .output_address = renderer.buffer_address(output),
            .width          = WIDTH,
            .height         = HEIGHT,
        };
        if (aborted) {
            render::abort_frame(&renderer);
            continue;
        }
        BufferId[1] writes = { output };
        renderer.dispatch({
            .shader = shader,
            .root   = ((char*)&root)[:BenchRoot::size],
            .groups = { (WIDTH + GROUP_SIZE - 1) / GROUP_SIZE, (HEIGHT + GROUP_SIZE - 1) / GROUP_SIZE, 1 },
            .writes = writes[..],
        })!!;
        renderer.end_frame()!!;
        samples[frame].trace_build_ms = renderer.stats.trace_build_ms;
        samples[frame].posed_bytes = renderer.stats.trace_posed_bytes;
        samples[frame].poses = renderer.stats.trace_poses;
        samples[frame].refits = renderer.stats.trace_refits;
        samples[frame].updates = renderer.stats.blas_updates;
        samples[frame].builds = renderer.stats.blas_builds;
        if (hardware && !storage_printed) {
            storage_printed = true;
            print_storage_sizes(&renderer, assets.model(model).data.meshes[0].geometry);
        }
    }
    render::wait_frames(&renderer)!!;
    renderer.log.check_validation()!!;
    io::printn("mode,count,kind,pose,frame,gpu_trace_pose_ms,gpu_acceleration_build_ms,gpu_trace_ms,"
        "trace_build_ms,posed_bytes,poses,refits,blas_updates,blas_builds");
    for (uint frame = WARMUP_FRAMES; frame < WARMUP_FRAMES + SAMPLE_FRAMES; frame++) {
        Sample sample = samples[frame];
        if (!sample.completed) return 2;
        io::printfn(
            "%s,%d,%s,%s,%d,%.6f,%.6f,%.6f,%.6f,%d,%d,%d,%d,%d",
            crowd ? "crowd" : "mannequin",
            count,
            hardware ? "hardware" : "software",
            crowd ? "walk" : pose,
            frame,
            sample.gpu_pose_ms,
            sample.gpu_build_ms,
            sample.gpu_trace_ms,
            sample.trace_build_ms,
            sample.posed_bytes,
            sample.poses,
            sample.refits,
            sample.updates,
            sample.builds,
        );
    }
    return 0;
}
