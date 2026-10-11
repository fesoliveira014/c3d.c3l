module retarget_example;

import std::io;
import std::io::file;
import std::io::path;
import std::math;
import std::core::string;
import c3d;
import c3d::anim;
import c3d::anim::retarget;
import c3d::asset;
import c3d::asset::fbx;
import c3d::asset::gltf;
import c3d::camera;
import c3d::light;
import c3d::maths;
import c3d::model;
import c3d::platform;
import c3d::render;
import c3d::scene;

const float INSTANCE_SPACING @local = 0.8f; // metres between the two characters and the origin
const float WALK_RANGE @local = 1.5f; // metres the root-motion walker covers before it returns to its start
const float LIGHT_INTENSITY @local = 3;
const Vec3  CAMERA_POSITION @local = { 0, 1.2f, 4.5f };
const Vec3  CAMERA_TARGET @local = { 0, 0.9f, 0 };
const String SOURCE_CHARACTER @local = "../assets/mixamo/character.fbx";
const String SOURCE_WALK @local = "../assets/mixamo/walk.fbx";
const String TARGET_CHARACTER @local = "../assets/quaternius/AnimationLibrary_Godot.glb";
const String SOURCE_HIPS @local = "Hips";
const String TARGET_HIPS @local = "DEF-hips";
const String TARGET_CARRIER @local = "Rig";
const String PROFILE_VARIANT @local = "t_pose";

const NameMapping[] BODY_MAP @local = {
    { .source = "Hips",          .target = "DEF-hips" },
    { .source = "Spine",         .target = "DEF-spine.001" },
    { .source = "Spine1",        .target = "DEF-spine.002" },
    { .source = "Spine2",        .target = "DEF-spine.003" },
    { .source = "Neck",          .target = "DEF-neck" },
    { .source = "Head",          .target = "DEF-head" },
    { .source = "LeftShoulder",  .target = "DEF-shoulder.L" },
    { .source = "LeftArm",       .target = "DEF-upper_arm.L" },
    { .source = "LeftForeArm",   .target = "DEF-forearm.L" },
    { .source = "LeftHand",      .target = "DEF-hand.L" },
    { .source = "RightShoulder", .target = "DEF-shoulder.R" },
    { .source = "RightArm",      .target = "DEF-upper_arm.R" },
    { .source = "RightForeArm",  .target = "DEF-forearm.R" },
    { .source = "RightHand",     .target = "DEF-hand.R" },
    { .source = "LeftUpLeg",     .target = "DEF-thigh.L" },
    { .source = "LeftLeg",       .target = "DEF-shin.L" },
    { .source = "LeftFoot",      .target = "DEF-foot.L" },
    { .source = "LeftToeBase",   .target = "DEF-toe.L" },
    { .source = "RightUpLeg",    .target = "DEF-thigh.R" },
    { .source = "RightLeg",      .target = "DEF-shin.R" },
    { .source = "RightFoot",     .target = "DEF-foot.R" },
    { .source = "RightToeBase",  .target = "DEF-toe.R" },
};

enum TargetMode @local {
    COPY,
    CORRECT,
    PROFILE_STRIP_XZ,
    PROFILE_EXTRACT,
}

struct Showcase @local {
    Node* source;
    Node* target;
    ClipId source_clip;
    ClipId[TargetMode::len] target_clips;
    TargetMode mode;
    bool resting;
}

fn String example_path(String relative) @local {
    Path source = path::tnew($$FILEPATH)!!;

    return (String)source.parent()!!.tappend(relative)!!;
}

fn uint? node_named(NodeTemplate[] nodes, String name) @local {
    foreach (uint index, &node : nodes) {
        if (node.name == name || node.name.ends_with(string::tformat(":%s", name))) return index;
    }

    return NOT_FOUND~;
}

fn ClipId? first_clip(ClipId[] clips) @local {
    defer alloc::free(mem, clips.ptr);
    if (!clips.len) return c3d::ASSET_FORMAT_ERROR~;

    return clips[0];
}

fn ClipId? retargeted_walk(
    AssetStore* assets,
    String walk,
    ModelId model,
    RetargetOptions options,
) @local {
    ClipId[] clips = fbx::load_animations(
        allocator: mem,
        assets: assets,
        path: walk,
        target: model,
        options: options,
    )!;

    return first_clip(clips);
}

fn usz mapped_joints(AssetStore* assets, ClipId clip) @local {
    usz count;

    foreach (&track : assets.clip(clip).data.tracks) {
        if (track.path == TargetPath.ROTATION) count++;
    }

    return count;
}

fn RetargetProfile? create_walk_profile(
    NodeTemplate[] source_nodes,
    ModelTemplate* target,
    NameMapping[] name_map,
) @local {
    Quat[] source_calibration = alloc::new_array(tmem, Quat, source_nodes.len);
    Quat[] target_calibration = alloc::new_array(tmem, Quat, target.nodes.len);

    // Both rigs rest in a T-pose facing +Z, so their rest rotations calibrate the pair.
    foreach (index, &node : source_nodes) source_calibration[index] = node.local.rotation;
    foreach (index, &node : target.nodes) target_calibration[index] = node.local.rotation;

    RetargetProfileDesc desc = retarget::RETARGET_PROFILE_DESC_DEFAULT;
    desc.name_map = name_map;
    desc.source_calibration = source_calibration;
    desc.target_calibration = target_calibration;
    desc.source_motion_node = node_named(source_nodes, SOURCE_HIPS)!;
    desc.target_motion_node = node_named(target.nodes, TARGET_HIPS)!;
    desc.target_carrier = node_named(target.nodes, TARGET_CARRIER)!;

    return retarget::create_retarget_profile(
        allocator: mem,
        source_nodes: source_nodes,
        target: target,
        desc: desc,
    );
}

fn void? load_target_clips(
    AssetStore* assets,
    String walk,
    ModelId target_model,
    NodeTemplate[] source_nodes,
    Showcase* showcase,
) @local {
    @pool() {
        ModelTemplate* target = &assets.model(target_model).data;
        NameMapping[] body_map = alloc::new_array(tmem, NameMapping, BODY_MAP.len);

        foreach (index, mapping : BODY_MAP) {
            uint source_node = node_named(source_nodes, mapping.source)!;
            body_map[index] = { .source = source_nodes[source_node].name, .target = mapping.target };
        }

        float scale = retarget::rest_world_position(target.nodes, node_named(target.nodes, TARGET_HIPS)!).y
            / retarget::rest_world_position(source_nodes, node_named(source_nodes, SOURCE_HIPS)!).y;

        RetargetOptions options = retarget::RETARGET_OPTIONS_DEFAULT;
        options.root_motion = RootMotion.STRIP_XZ;
        options.name_map = body_map;
        options.allow_partial = true;
        options.root_translation_scale = scale;
        showcase.target_clips[TargetMode.COPY] = retargeted_walk(
            assets: assets,
            walk: walk,
            model: target_model,
            options: options,
        )!;
        options.rest_pose = RestPose.CORRECT;
        showcase.target_clips[TargetMode.CORRECT] = retargeted_walk(
            assets: assets,
            walk: walk,
            model: target_model,
            options: options,
        )!;

        RetargetProfile profile = create_walk_profile(source_nodes, target, body_map)!;
        defer retarget::destroy_retarget_profile(&profile);

        RetargetBakeOptions profile_options = retarget::RETARGET_BAKE_OPTIONS_DEFAULT;
        profile_options.allow_partial = true;
        profile_options.root_translation_scale = scale;

        foreach (mode : (TargetMode[2]){ TargetMode.PROFILE_STRIP_XZ, TargetMode.PROFILE_EXTRACT }) {
            profile_options.root_motion = mode == TargetMode.PROFILE_EXTRACT ? RootMotion.EXTRACT : RootMotion.STRIP_XZ;
            ClipId[] clips = fbx::load_animations_with_profile(
                allocator: mem,
                assets: assets,
                path: walk,
                target: target_model,
                profile: &profile,
                variant: PROFILE_VARIANT,
                options: profile_options,
            )!;
            showcase.target_clips[mode] = first_clip(clips)!;
        }

        usz mapped = mapped_joints(assets, showcase.target_clips[TargetMode.CORRECT]);
        io::printfn("root scale %.3f, %d mapped joints", scale, mapped);
    };
}

fn void play(AssetStore* assets, Scene* scene, Showcase* showcase) @local {
    Animator* source = scene.get(showcase.source, Animator);
    Animator* target = scene.get(showcase.target, Animator);

    while (source.action_count) source.stop(source.order[0])!!;
    while (target.action_count) target.stop(target.order[0])!!;

    showcase.target.local.position = { INSTANCE_SPACING, 0, 0 };
    if (showcase.resting) return;

    source.play(assets, showcase.source_clip)!!;
    RootMotion root_motion = showcase.mode == TargetMode.PROFILE_EXTRACT ? RootMotion.EXTRACT : RootMotion.KEEP;
    target.play(assets, showcase.target_clips[showcase.mode], { .root_motion = root_motion })!!;
}

fn void report(Showcase* showcase) @local {
    io::printfn("right: %s, %s", showcase.mode, showcase.resting ? "rest pose" : "walking");
}

fn int main(String[] args) {
    uint frame_limit;

    foreach (argument : args[1..]) {
        if (argument.starts_with("--frames=")) {
            frame_limit = argument[9..].to_uint()!!;
        } else {
            io::eprintfn("Unknown option: %s", argument);

            return 1;
        }
    }

    String[3] required = { example_path(SOURCE_CHARACTER), example_path(SOURCE_WALK), example_path(TARGET_CHARACTER) };

    foreach (candidate : required) {
        if (!file::is_file(candidate)) {
            io::eprintfn("missing %s; examples/assets/mixamo/README.md lists the files this example needs", candidate);

            return 1;
        }
    }

    platform::Window window = platform::create_window(platform::default_window_desc("c3d retarget", 1280, 720))!!;
    defer platform::destroy_window(&window);
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      { .validation = true, .application_name = "c3d_retarget" },
    )!!;
    defer render::destroy_renderer(&renderer);

    ModelId source_model = fbx::load_model(&assets, required[0])!!;
    ModelId target_model = gltf::load_model(&assets, required[2])!!;
    ModelDocument walk = fbx::decode_model(mem, required[1], { .animations = false })!!;
    defer asset::destroy_model_document(&walk);

    RetargetOptions source_options = retarget::RETARGET_OPTIONS_DEFAULT;
    source_options.root_motion = RootMotion.STRIP_XZ;
    Showcase showcase = {
        .source_clip = retargeted_walk(
            assets: &assets,
            walk: required[1],
            model: source_model,
            options: source_options,
        )!!,
        .mode = TargetMode.PROFILE_EXTRACT,
    };

    load_target_clips(
        assets: &assets,
        walk: required[1],
        target_model: target_model,
        source_nodes: walk.template.nodes,
        showcase: &showcase,
    )!!;

    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    showcase.source = model::instantiate(
        assets: &assets,
        scene: &scene,
        model: source_model,
        name: "source",
    )!!;
    showcase.target = model::instantiate(
        assets: &assets,
        scene: &scene,
        model: target_model,
        name: "target",
    )!!;
    showcase.source.local.position = { -INSTANCE_SPACING, 0, 0 };
    anim::add_animator(&scene, showcase.source);
    Animator* target_animator = anim::add_animator(&scene, showcase.target);
    target_animator.root_node = node_named(assets.model(target_model).data.nodes, TARGET_CARRIER)!!;
    play(&assets, &scene, &showcase);

    Node* sun = scene.add_light(light::directional({ 1, 0.95f, 0.85f }, LIGHT_INTENSITY), name: "sun")!!;
    sun.local.rotation = maths::look_rotation((Vec3){ -0.4f, -1, -0.6f }.normalize(), { 0, 1, 0 });
    Node* camera_node = scene.add_camera(camera::perspective_deg(45, 0.05f), name: "camera")!!;
    camera_node.local.position = CAMERA_POSITION;
    camera_node.local.rotation = maths::look_rotation(CAMERA_TARGET - CAMERA_POSITION, { 0, 1, 0 });
    scene.update_world();
    renderer.prepare_scene(&scene)!!;

    io::printn("left: Mixamo source; right: Quaternius target");
    io::printn("T cycles COPY, CORRECT, profile STRIP_XZ and profile EXTRACT on the right, R toggles the rest pose");
    report(&showcase);
    uint frame;

    while (window.poll()) {
        if (frame_limit && frame >= frame_limit) break;
        Input* input = &window.input;
        if (input.key_released(Scancode.ESCAPE)) break;
        if (input.key_pressed(Scancode.T) || input.key_pressed(Scancode.R)) {
            if (input.key_pressed(Scancode.T)) {
                showcase.mode = TargetMode::from_ordinal((showcase.mode.ordinal + 1) % (int)TargetMode::len);
            }

            if (input.key_pressed(Scancode.R)) showcase.resting = !showcase.resting;
            play(&assets, &scene, &showcase);
            report(&showcase);
        }

        anim::update(&assets, &scene, window.clock.delta);
        anim::apply_root_motion(showcase.target, scene.get(showcase.target, Animator).root_motion);
        if (showcase.target.local.position.z > WALK_RANGE) showcase.target.local.position.z = 0;
        scene.update_world();
        platform::sync_window(&window, &renderer);
        renderer.render(&scene, camera_node, { .time = window.clock.total, .delta = window.clock.delta })!!;
        frame++;
    }

    renderer.log.check_validation()!!;

    return 0;
}
