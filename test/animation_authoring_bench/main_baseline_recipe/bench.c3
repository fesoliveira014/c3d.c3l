module animation_authoring_bench;

import c3d;
import c3d::anim @public;
import c3d::asset;
import c3d::asset::gltf;
import c3d::camera;
import c3d::material;
import c3d::maths;
import c3d::model;
import c3d::render;
import c3d::scene;
import gpu;
import std::hash::sha256;
import std::io;
import std::io::file;
import std::math;
import std::sort;
import std::time;
import std::time::clock;

const uint[3] CROWD_SIZES @local = { 64, 512, 4096 };
const uint ACTION_CAPACITY @local = 4; // Keeps four action and two shared group rows per crowd slot.
const uint WARMUP_FRAMES @local = 4; // Exceeds the two asynchronous frame slots before observations.
const uint SAMPLE_FRAMES @local = 12; // Bounds the three-row measurement without a scenario matrix.
const uint TARGET_PIXELS @local = 256;
const usz UPLOAD_BYTES @local = 32 << 20; // Covers 4096 * 53 * Mat4f::size palettes plus roots in each frame slot.
const float DT @local = 1.0f / 60;
const String MODEL_PATH @local = "../../examples/assets/quaternius/AnimationLibrary_Godot.glb";
const String MODEL_SHA @local = "272d5c1e2c27f566595ece27b6985935d42dcee1dacee1b320af9f0c40d5c97c";

fn void check_source(char[] bytes) @local {
    char[32] digest = sha256::hash(bytes);
    char[64] encoded;
    foreach (index, byte : digest) {
        encoded[2 * index] = "0123456789abcdef"[byte >> 4];
        encoded[2 * index + 1] = "0123456789abcdef"[byte & 15];
    }
    assert((String)encoded[..] == MODEL_SHA);
    io::printfn("fixture=%s bytes=%s sha256=%s", MODEL_PATH, bytes.len, (String)encoded[..]);
}

fn ClipId? clip_named(AssetStore* assets, ModelTemplate* template, String name) @local {
    foreach (clip : template.clips) if (assets.clip(clip).data.name == name) return clip;
    return NOT_FOUND~;
}

fn uint? node_named(ModelTemplate* template, String name) @local {
    foreach (index, node : template.nodes) if (node.name == name) return (uint)index;
    return NOT_FOUND~;
}

fn double percentile(double[] samples, double probability) @local {
    sort::quicksort(samples);
    uint index = (uint)math::ceil(probability * (double)samples.len) - 1;
    return samples[index];
}

fn void? report_adapter(Renderer* renderer) @local {
    gpu::AdapterList adapters = gpu::enumerate_adapters(&renderer.runtime)!;
    for (uint index = 0; index < adapters.count; index++) {
        gpu::Adapter adapter = adapters.get(index)!;
        gpu::AdapterInfo info = gpu::get_adapter_info(&adapter)!;
        if (info.name != renderer.adapter_name) continue;
        gpu::AdapterDiagnostics diagnostics = gpu::get_adapter_diagnostics(&adapter)!;
        io::printfn("adapter=%s driver=%s info=%s driver_version=%s", info.name,
            diagnostics.driver_name, diagnostics.driver_info, diagnostics.driver_version);
        break;
    }
}

fn void? record_frame(
    Renderer* renderer,
    Scene* scene,
    Node* camera,
    ViewId view,
    uint frame,
) @local {
    renderer.begin_frame({ .time = (double)frame * DT, .delta = DT })!;
    defer catch render::abort_frame(renderer);
    renderer.render_view(scene, camera, view)!;
    renderer.finish_view(view)!;
    renderer.end_frame()!;
}

fn void? run_row(
    AssetStore* assets,
    Renderer* renderer,
    ViewId view,
    ModelId model_id,
    uint count,
    bool inertia_enabled,
) @local {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    Scene scene = scene::create_scene(&tracker, { .max_nodes = 64 });
    defer scene::destroy_scene(&scene);
    ModelTemplate* template = &assets.model(model_id).data;
    ClipId walk = clip_named(assets, template, "Walk_Loop")!;
    uint root = node_named(template, "root")!;
    CrowdInstance[] instances = alloc::new_array(mem, CrowdInstance, (sz)count);
    defer alloc::free(mem, instances.ptr);
    foreach (index, &instance : instances) {
        *instance = {
            .placement = {
                .position = { ((float)(index % 64) - 31.5f) * 0.7f, 0, -0.7f * (float)(index / 64) },
                .rotation = quaternion::IDENTITY,
                .scale = { 0.3f, 0.3f, 0.3f },
            },
            .pose = { .clip = walk, .speed = 1, .loop = true },
            .color = { 1, 1, 1, 1 },
        };
    }
    Node* owner = scene.add_node(name: "measured_crowd")!;
    model::attach_crowd(
        assets: assets,
        scene: &scene,
        node: owner,
        model: model_id,
        capacity: count,
        pose_bounds: { .min = { -4, -4, -4 }, .max = { 4, 4, 4 } },
        instances: instances,
        actions_per_instance: ACTION_CAPACITY,
        event_capacity: 0,
    )!;
    AnimatedCrowd* crowd = scene.get(owner, AnimatedCrowd);
    model::prepare_crowd(assets, &scene, owner)!;
    WeightedJointMask mask = anim::create_feathered_joint_mask(
        allocator: mem,
        assets: assets,
        model: model_id,
        names: { "root" },
        weights: { 1 },
        depths: { 0 },
    )!;
    defer anim::destroy_weighted_joint_mask(&mask);
    PlayDesc play = {
        .weighted_mask = &mask,
        .root_motion = EXTRACT,
        .root_yaw = true,
    };
    for (uint index = 0; index < count; index++) {
        CrowdPlayer player = crowd.playback.player(crowd.playback.instance_id(index)!)!;
        player.stop(player.state.slots[index].base_action)!;
        player.state.slots[index].root_node = root;
        AnimationActionId action = player.play(assets, walk, play)!;
        player.state.slots[index].base_action = action;
    }
    Node* camera = scene.add_camera(camera::orthographic(48, 0.1f, 200))!;
    camera.local.position = { 0, 24, 25 };
    camera.local.rotation = maths::look_rotation((Vec3){ 0, 0, -16 } - camera.local.position, { 0, 1, 0 });
    anim::crowd_update(assets, &scene, 0);
    scene.update_world();
    renderer.prepare_scene(&scene)!;
    for (uint frame = 0; frame < WARMUP_FRAMES; frame++) {
        anim::crowd_update(assets, &scene, DT);
        scene.update_world();
        record_frame(
            renderer: renderer,
            scene: &scene,
            camera: camera,
            view: view,
            frame: frame,
        )!;
    }
    double[SAMPLE_FRAMES] cpu_update;
    double[SAMPLE_FRAMES] cpu_record;
    double[SAMPLE_FRAMES] gpu_pass;
    uint gpu_count;
    ulong last_gpu = ulong::max;
    ulong first_gpu = renderer.frame_index;
    uint upload_bytes;
    for (uint frame = 0; frame < SAMPLE_FRAMES + render::FRAMES_IN_FLIGHT; frame++) {
        time::Clock started = clock::now();
        anim::crowd_update(assets, &scene, DT);
        double update_ms = (double)(clock::now() - started) / 1e6;
        scene.update_world();
        started = clock::now();
        record_frame(
            renderer: renderer,
            scene: &scene,
            camera: camera,
            view: view,
            frame: frame + WARMUP_FRAMES,
        )!;
        double record_ms = (double)(clock::now() - started) / 1e6;
        if (frame < SAMPLE_FRAMES) {
            cpu_update[frame] = update_ms;
            cpu_record[frame] = record_ms;
            upload_bytes = renderer.stats.upload_bytes;
        }
        if (renderer.stats.gpu_frame_index != last_gpu && renderer.stats.gpu_frame_index >= first_gpu
          && gpu_count < SAMPLE_FRAMES) {
            double gpu_ms;
            bool valid;
            foreach (index, available : renderer.stats.gpu_pass_valid) {
                if (!available) continue;
                valid = true;
                gpu_ms += renderer.stats.gpu_pass_ms[index];
            }
            if (valid) gpu_pass[gpu_count++] = gpu_ms;
            last_gpu = renderer.stats.gpu_frame_index;
        }
    }
    render::wait_frames(renderer)!;
    sz retained = tracker.allocated();
    double request_ms;
    sz request_peak;
    usz history_bytes;
    io::printfn("row,count=%s,request_measurement=unsupported_on_main,inertia_enabled=false,extraction=legacy_planar_EXTRACT_Y_yaw", count);
    usz group_bytes = (usz)count * anim::blend_space_2d_storage_bytes(ACTION_CAPACITY);
    usz mask_bytes = (usz)count * template.nodes.len * float::size;
    usz palette_bytes = (usz)count * crowd.joint_count * Mat4f::size;
    double gpu_median = gpu_count ? percentile(gpu_pass[:gpu_count], 0.5) : 0;
    double gpu_p95 = gpu_count ? percentile(gpu_pass[:gpu_count], 0.95) : 0;
    io::printfn("row,count=%s,iterations=%s,update_median_ms=%s,update_p95_ms=%s,record_median_ms=%s,record_p95_ms=%s",
        count, SAMPLE_FRAMES, percentile(cpu_update[..], 0.5), percentile(cpu_update[..], 0.95),
        percentile(cpu_record[..], 0.5), percentile(cpu_record[..], 0.95));
    io::printfn("row,count=%s,gpu_samples=%s,gpu_pass_median_ms=%s,gpu_pass_p95_ms=%s,request_all_ms=%s",
        count, gpu_count, gpu_median, gpu_p95, request_ms);
    io::printfn("row,count=%s,retained_bytes=%s,history_bytes=%s,two_d_bytes=%s,weighted_bytes=%s,request_peak_extra=%s",
        count, retained, history_bytes, group_bytes, mask_bytes, request_peak);
    io::printfn("row,count=%s,palette_stream_bytes_per_frame=%s,asset_upload_bytes_last=%s,node_poses_per_update=%s,palette_matrices=%s,readbacks=0",
        count, palette_bytes, upload_bytes, (usz)count * template.nodes.len, crowd.palettes.len);
}

fn int main(String[] arguments) {
    uint selected_count = 4096;
    bool inertia_enabled = false;
    foreach (argument : arguments[1..]) {
        if (argument == "--inertia-off") {
            inertia_enabled = false;
        } else if (argument.starts_with("--count=")) {
            if (catch excuse = argument[8..].to_uint()) {
                io::eprintfn("Invalid count: %s", excuse);
                return 2;
            } else {
                selected_count = argument[8..].to_uint()!!;
            }
            bool supported;
            foreach (count : CROWD_SIZES) supported |= count == selected_count;
            if (!supported) {
                io::eprintn("Count must be 64, 512 or 4096.");
                return 2;
            }
        } else {
            io::eprintfn("Unknown option: %s", argument);
            return 2;
        }
    }
    @pool() {
        AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
        defer asset::destroy_asset_store(&assets);
        char[] bytes = file::load(tmem, MODEL_PATH)!!;
        check_source(bytes);
        LoadOptions options = asset::LOAD_OPTIONS_DEFAULT;
        options.generate_tangents = false;
        ModelId model_id = gltf::load_model_memory(
            assets: &assets,
            bytes: bytes,
            base_dir: "../../examples/assets",
            key: "motion_bench/model",
            options: options,
        )!!;
        foreach (mesh : assets.model(model_id).data.meshes) {
            assets.material(mesh.material).data = material::basic({ .color = { 1, 1, 1, 1 } });
            assets.mark_material_dirty(mesh.material);
        }
        Renderer renderer = render::create_renderer(
            allocator: mem,
            assets: &assets,
            desc: {
                .validation = false,
                .gpu_timings = true,
                .application_name = "animation_authoring_measurement",
                .upload_ring_bytes = UPLOAD_BYTES,
                .shadow_resolution = 64,
                .max_shadow_layers = 1,
            },
        )!!;
        defer render::destroy_renderer(&renderer);
        report_adapter(&renderer)!!;
        io::printfn("protocol=measurement_only,O3_requested,validation_off,one_view,no_readback,baseline_main_73edb0d,semantic_feature_difference_legacy_planar,selected_count=%s,inertia_enabled=%s,no_thresholds",
            selected_count, inertia_enabled);
        io::printn("CPU record includes frame-slot wait; GPU pass samples are asynchronously completed sums.");
        RenderTargetId target = render::create_render_target(
            &renderer, render::render_target_desc(TARGET_PIXELS, TARGET_PIXELS))!!;
        ViewId view = render::create_view(&renderer, render::texture_view_desc(target))!!;
        foreach (count : CROWD_SIZES) {
            if (selected_count && count != selected_count) continue;
            if (catch excuse = run_row(
                assets: &assets,
                renderer: &renderer,
                view: view,
                model_id: model_id,
                count: count,
                inertia_enabled: inertia_enabled,
            )) {
                io::eprintfn("Motion measurement failed at %s instances: %s", count, excuse);
                return 1;
            }
        }
    };
    return 0;
}
