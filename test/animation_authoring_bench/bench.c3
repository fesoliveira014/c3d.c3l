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

fn void write_report(String format, any[] values) @local {
    io::printfn(format, ...values);
}

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
        write_report(
            format: "adapter=%s driver=%s info=%s driver_version=%s",
            values: {
                &info.name,
                &diagnostics.driver_name,
                &diagnostics.driver_info,
                &diagnostics.driver_version,
            },
        );
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
    bool legacy_planar,
    bool phase_times,
) @local {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    Scene scene = scene::create_scene(&tracker, { .max_nodes = 64 });
    defer scene::destroy_scene(&scene);
    ModelTemplate* template = &assets.model(model_id).data;
    ClipId walk = clip_named(assets, template, "Walk_Loop")!;
    ClipId turn = clip_named(assets, template, "Turn90_L")!;
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
    crowd.inertia_enabled = inertia_enabled;
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
        .extraction = {
            .generalized = true,
            .translation_axes = { true, true, true },
            .up = { 0, 1, 0 },
            .twist = true,
        },
    };
    if (legacy_planar) {
        play.extraction = {};
        play.root_yaw = true;
    }
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
    double[SAMPLE_FRAMES] cpu_evaluation;
    double[SAMPLE_FRAMES] cpu_publication;
    double[SAMPLE_FRAMES] gpu_pass;
    uint gpu_count;
    ulong last_gpu = ulong::max;
    ulong first_gpu = renderer.frame_index;
    uint upload_bytes;
    for (uint frame = 0; frame < SAMPLE_FRAMES + render::FRAMES_IN_FLIGHT; frame++) {
        time::Clock started = clock::now();
        if (phase_times) {
            crowd.playback.update(assets, DT);
            time::Clock evaluated = clock::now();
            anim::publish_crowd_pose(assets, &scene, crowd);
            time::Clock published = clock::now();
            if (frame < SAMPLE_FRAMES) {
                cpu_evaluation[frame] = (double)(evaluated - started) / 1e6;
                cpu_publication[frame] = (double)(published - evaluated) / 1e6;
            }
        } else {
            anim::crowd_update(assets, &scene, DT);
        }
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
    usz slot_bytes = (usz)crowd.playback.slots.len * CrowdPlaybackSlot::size;
    usz generalized_bytes = (usz)crowd.playback.slots.len * GeneralizedPlaybackState::size;
    usz scene_animator_bytes = (usz)scene.world.capacity * Animator::size;
    usz scene_crowd_bytes = (usz)scene.world.capacity * AnimatedCrowd::size;
    usz action_slots;
    usz action_bytes;
    usz pool_metadata_bytes;
    usz boolean_mask_bytes;
    usz one_d_bytes;
    usz group_bytes;
    usz cursor_bytes;
    usz reference_bytes;
    usz mask_bytes;
    usz chain_count;
    usz chain_header_bytes;
    usz chain_node_bytes;
    usz chain_layout_bytes;
    usz chain_name_bytes;
    usz chain_scale_bytes;
    foreach (&slot : crowd.playback.slots) {
        action_slots += slot.actions.items.len;
        action_bytes += (usz)slot.actions.items.len * Action::size;
        pool_metadata_bytes += (usz)(slot.actions.generations.len + slot.actions.free.len) * uint::size
          + (usz)slot.order.len * AnimationActionId::size;
        boolean_mask_bytes += (usz)slot.masks.len * bool::size;
        one_d_bytes += (usz)slot.spaces.len * BlendSpace1D::size;
        group_bytes += anim::blend_space_2d_storage_bytes((uint)slot.actions.items.len);
        foreach (id : slot.order[:slot.action_count]) {
            Action* action = slot.actions.get(id);
            cursor_bytes += (usz)action.cursors.len * uint::size;
            reference_bytes += (usz)action.reference.len * float::size;
            mask_bytes += (usz)action.weighted_mask.len * float::size;
            if (!action.motion_chain) continue;

            CapturedMotionChain* chain = action.motion_chain;
            chain_count++;
            chain_header_bytes += CapturedMotionChain::size;
            chain_node_bytes += (usz)chain.nodes.len * CapturedMotionNode::size;
            chain_layout_bytes += (usz)chain.top_level_nodes.len * uint::size
              + (usz)chain.model_names.len * String::size + (usz)chain.model_parents.len * int::size;
            foreach (name : chain.model_names) chain_name_bytes += name.len;
            chain_scale_bytes += (usz)chain.pose_scale_sums.len * double[<3>]::size;
        }
    }

    PoseDerivativeScratch* derivative = crowd.playback.pose_storage.scratch.derivative;
    usz derivative_bytes = derivative ? anim::pose_derivative_storage_bytes(derivative) : 0;
    usz derivative_scale_bytes = derivative ? (usz)derivative.scale_values.len * double[<3>]::size : 0;
    usz channel_bytes = (usz)crowd.playback.pose_storage.scratch.channels.len * ChannelSums::size;
    usz inertial_bytes = crowd.playback.inertial_storage ? crowd.playback.inertial_storage.bytes : 0;
    usz inertial_headers = crowd.playback.inertial_storage
      ? (usz)crowd.playback.inertial_storage.rows.len * InertialRow::size : 0;
    usz inertial_payload = crowd.playback.inertial_storage
      ? (usz)crowd.playback.inertial_storage.rows.len * crowd.playback.inertial_storage.row_bytes : 0;
    usz capture_bytes = chain_header_bytes + chain_node_bytes + chain_layout_bytes + chain_name_bytes + chain_scale_bytes;
    usz attributed_bytes = CrowdPlaybackState::size + PoseStorage::size + scene_animator_bytes + scene_crowd_bytes
      + slot_bytes + action_bytes
      + pool_metadata_bytes + boolean_mask_bytes + one_d_bytes + group_bytes + cursor_bytes + reference_bytes
      + mask_bytes + capture_bytes + derivative_bytes + channel_bytes + inertial_bytes;
    sz other_bytes = retained - (sz)attributed_bytes;

    double request_ms;
    sz request_peak;
    if (inertia_enabled) {
        tracker.max_usage = tracker.usage;
        AnimationTargetDesc[1] targets = { anim::ANIMATION_TARGET_DEFAULT };
        targets[0].clip = turn;
        targets[0].play = play;
        targets[0].loop = false;
        time::Clock request_started = clock::now();
        for (uint index = 0; index < count; index++) {
            CrowdPlayer player = crowd.playback.player(crowd.playback.instance_id(index)!)!;
            player.inertialize(assets, { .duration = 0.35f, .actions = targets[..] })!;
        }
        request_ms = (double)(clock::now() - request_started) / 1e6;
        request_peak = tracker.max_allocated() - retained;
    } else {
        io::printfn("row,count=%s,request_measurement=skipped_disabled_inertia_precondition", count);
    }
    write_report(
        format: "row,count=%s,inertia_enabled=%s,extraction=%s",
        values: {
            &count,
            &inertia_enabled,
            &&(legacy_planar ? "legacy_planar_EXTRACT_Y_yaw" : "generalized_XYZ_Y_twist"),
        },
    );
    usz palette_bytes = (usz)count * crowd.joint_count * Mat4f::size;
    double gpu_median = gpu_count ? percentile(gpu_pass[:gpu_count], 0.5) : 0;
    double gpu_p95 = gpu_count ? percentile(gpu_pass[:gpu_count], 0.95) : 0;
    write_report(
        format: "row,count=%s,iterations=%s,update_median_ms=%s,update_p95_ms=%s,record_median_ms=%s,record_p95_ms=%s",
        values: {
            &count,
            &&SAMPLE_FRAMES,
            &&percentile(cpu_update[..], 0.5),
            &&percentile(cpu_update[..], 0.95),
            &&percentile(cpu_record[..], 0.5),
            &&percentile(cpu_record[..], 0.95),
        },
    );
    if (phase_times) {
        write_report(
            format: "phases,count=%s,evaluation_median_ms=%s,evaluation_p95_ms=%s",
            values: {
                &count,
                &&percentile(cpu_evaluation[..], 0.5),
                &&percentile(cpu_evaluation[..], 0.95),
            },
        );
        write_report(
            format: "phases,count=%s,palette_batch_publication_median_ms=%s,palette_batch_publication_p95_ms=%s",
            values: {
                &count,
                &&percentile(cpu_publication[..], 0.5),
                &&percentile(cpu_publication[..], 0.95),
            },
        );
    }
    write_report(
        format: "row,count=%s,gpu_samples=%s,gpu_pass_median_ms=%s,gpu_pass_p95_ms=%s,request_all_ms=%s",
        values: {
            &count,
            &gpu_count,
            &gpu_median,
            &gpu_p95,
            &request_ms,
        },
    );
    write_report(
        format: "row,count=%s,retained_bytes=%s,inertial_storage_bytes=%s,two_d_bytes=%s,weighted_bytes=%s",
        values: {
            &count,
            &retained,
            &inertial_bytes,
            &group_bytes,
            &mask_bytes,
        },
    );
    write_report(
        format: "retained,count=%s,action_capacity_slots=%s,action_slots_bytes=%s,slot_records_bytes=%s",
        values: { &count, &action_slots, &action_bytes, &slot_bytes },
    );
    write_report(
        format: "retained,count=%s,embedded_generalized_bytes=%s,pool_metadata_bytes=%s,boolean_masks_bytes=%s",
        values: { &count, &generalized_bytes, &pool_metadata_bytes, &boolean_mask_bytes },
    );
    write_report(
        format: "retained,count=%s,scene_component_capacity=%s,scene_animator_records_bytes=%s,scene_crowd_records_bytes=%s",
        values: { &count, &&scene.world.capacity, &scene_animator_bytes, &scene_crowd_bytes },
    );
    write_report(
        format: "retained,count=%s,one_d_bytes=%s,cursor_bytes=%s,reference_bytes=%s,channel_sums_bytes=%s",
        values: { &count, &one_d_bytes, &cursor_bytes, &reference_bytes, &channel_bytes },
    );
    write_report(
        format: "retained,count=%s,motion_captures=%s,capture_total_bytes=%s,capture_headers_bytes=%s",
        values: { &count, &chain_count, &capture_bytes, &chain_header_bytes },
    );
    write_report(
        format: "retained,count=%s,capture_nodes_bytes=%s,capture_layout_bytes=%s,capture_names_bytes=%s",
        values: { &count, &chain_node_bytes, &chain_layout_bytes, &chain_name_bytes },
    );
    write_report(
        format: "retained,count=%s,capture_scale_sums_bytes=%s,derivative_scratch_bytes=%s,derivative_scale_values_bytes=%s",
        values: { &count, &chain_scale_bytes, &derivative_bytes, &derivative_scale_bytes },
    );
    write_report(
        format: "retained,count=%s,inertial_row_headers_bytes=%s,inertial_payload_bytes=%s,inertial_header_padding_bytes=%s",
        values: { &count, &inertial_headers, &inertial_payload,
            &&(inertial_bytes - inertial_headers - inertial_payload) },
    );
    write_report(
        format: "retained,count=%s,attributed_playback_bytes=%s,other_scene_bytes=%s,request_peak_extra=%s",
        values: {
            &count,
            &attributed_bytes,
            &other_bytes,
            &request_peak,
        },
    );
    write_report(
        format: "row,count=%s,palette_stream_bytes_per_frame=%s,asset_upload_bytes_last=%s",
        values: {
            &count,
            &palette_bytes,
            &upload_bytes,
        },
    );
    write_report(
        format: "row,count=%s,node_poses_per_update=%s,palette_matrices=%s,readbacks=0",
        values: {
            &count,
            &&((usz)count * template.nodes.len),
            &&crowd.palettes.len,
        },
    );
}

fn int main(String[] arguments) {
    uint selected_count;
    bool inertia_enabled = true;
    bool legacy_planar;
    bool phase_times;
    foreach (argument : arguments[1..]) {
        if (argument == "--inertia-off") {
            inertia_enabled = false;
        } else if (argument == "--legacy-planar") {
            legacy_planar = true;
        } else if (argument == "--phase-times") {
            phase_times = true;
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
        write_report(
            format: "layout,Action=%s,CrowdPlaybackSlot=%s,GeneralizedPlaybackState=%s,ChannelSums=%s",
            values: { &&Action::size, &&CrowdPlaybackSlot::size, &&GeneralizedPlaybackState::size, &&ChannelSums::size },
        );
        write_report(
            format: "layout,CapturedMotionChain=%s,scale_value=%s,PoseDerivativeScratch=%s,PoseVelocity=%s",
            values: { &&CapturedMotionChain::size, &&double[<3>]::size,
                &&PoseDerivativeScratch::size, &&PoseVelocity::size },
        );
        write_report(
            format: "layout,RootInertialState=%s,InertialRow=%s,InertialControl=%s",
            values: { &&RootInertialState::size, &&InertialRow::size, &&InertialControl::size },
        );

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
        io::printn("protocol=measurement_only,O3_requested,validation_off,one_view,no_readback,no_thresholds");
        write_report(
            format: "options,selected_count=%s,inertia_enabled=%s,legacy_planar=%s,phase_times=%s",
            values: {
                &selected_count,
                &inertia_enabled,
                &legacy_planar,
                &phase_times,
            },
        );
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
                legacy_planar: legacy_planar,
                phase_times: phase_times,
            )) {
                io::eprintfn("Motion measurement failed at %s instances: %s", count, excuse);
                return 1;
            }
        }
    };
    return 0;
}
