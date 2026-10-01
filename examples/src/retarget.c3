module retarget_example;

import std::io;
import std::io::file;
import std::io::path;
import std::math;
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
const float LIGHT_INTENSITY @local = 3;
const Vec3  CAMERA_POSITION @local = { 0, 1.2f, 4.5f };
const Vec3  CAMERA_TARGET @local = { 0, 0.9f, 0 };
const String SOURCE_CHARACTER @local = "../assets/mixamo/eve_j_gonzales.fbx";
const String SOURCE_WALK @local = "../assets/mixamo/walk.fbx";
const String TARGET_CHARACTER @local = "../assets/quaternius/AnimationLibrary_Godot.glb";
const String SOURCE_HIPS @local = "Hips";
const String TARGET_HIPS @local = "DEF-hips";
const String TARGET_ROOT @local = "root";

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

struct Showcase @local {
    Node*  source;
    Node*  target;
    ClipId source_clip;
    ClipId corrected_clip;
    ClipId copied_clip;
    bool   corrected;
    bool   resting;
}

fn String example_path(String relative) @local {
    Path source = path::tnew($$FILEPATH)!!;
    return (String)source.parent()!!.tappend(relative)!!;
}

fn uint? node_named(ModelTemplate* template, String name) @local {
    foreach (uint index, &node : template.nodes) {
        if (node.name == name || node.name.ends_with(string::tformat(":%s", name))) return index;
    }
    return NOT_FOUND~;
}

fn usz mapped_joints(AssetStore* assets, ClipId clip) @local {
    usz count;
    foreach (&track : assets.clip(clip).data.tracks) {
        if (track.path == TargetPath.ROTATION) count++;
    }
    return count;
}

fn void play(AssetStore* assets, Scene* scene, Showcase* showcase) @local {
    Animator* source = scene.get(showcase.source, Animator);
    Animator* target = scene.get(showcase.target, Animator);
    while (source.action_count) source.stop(source.order[0])!!;
    while (target.action_count) target.stop(target.order[0])!!;
    if (showcase.resting) return;
    source.play(assets, showcase.source_clip)!!;
    target.play(assets, showcase.corrected ? showcase.corrected_clip : showcase.copied_clip)!!;
}

fn void report(Showcase* showcase, float scale, usz mapped) @local {
    io::printfn("right: %s, %s, root scale %.3f, %d mapped joints",
        showcase.corrected ? "CORRECT" : "COPY", showcase.resting ? "rest pose" : "walking", scale, mapped);
}

fn ClipId? retargeted_walk(
    AssetStore* assets,
    String walk,
    ModelId model,
    RetargetOptions options,
) @local {
    ClipId[] clips = fbx::load_animations(mem, assets, walk, model, options)!;
    defer alloc::free(mem, clips.ptr);
    if (!clips.len) return c3d::ASSET_FORMAT_ERROR~;
    return clips[0];
}

fn int main() {
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
    ModelTemplate* source_template = &assets.model(source_model).data;
    ModelTemplate* target_template = &assets.model(target_model).data;
    uint source_hips = node_named(source_template, SOURCE_HIPS)!!;
    uint target_hips = node_named(target_template, TARGET_HIPS)!!;
    float scale = retarget::rest_world_position(target_template.nodes, target_hips).y
        / retarget::rest_world_position(source_template.nodes, source_hips).y;

    RetargetOptions copy_options = retarget::RETARGET_OPTIONS_DEFAULT;
    copy_options.root_motion = RootMotion.STRIP_XZ;
    RetargetOptions target_options = copy_options;
    target_options.name_map = BODY_MAP[..];
    target_options.allow_partial = true;
    target_options.root_translation_scale = scale;
    RetargetOptions corrected_options = target_options;
    corrected_options.rest_pose = RestPose.CORRECT;

    Showcase showcase = {
        .source_clip    = retargeted_walk(&assets, required[1], source_model, copy_options)!!,
        .copied_clip    = retargeted_walk(&assets, required[1], target_model, target_options)!!,
        .corrected_clip = retargeted_walk(&assets, required[1], target_model, corrected_options)!!,
        .corrected      = true,
    };

    usz mapped = mapped_joints(&assets, showcase.corrected_clip);

    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    showcase.source = model::instantiate(&assets, &scene, source_model, name: "source")!!;
    showcase.target = model::instantiate(&assets, &scene, target_model, name: "target")!!;
    showcase.source.local.position = { -INSTANCE_SPACING, 0, 0 };
    showcase.target.local.position = { INSTANCE_SPACING, 0, 0 };
    anim::add_animator(&scene, showcase.source);
    anim::add_animator(&scene, showcase.target);
    play(&assets, &scene, &showcase);

    Node* sun = scene.add_light(light::directional({ 1, 0.95f, 0.85f }, LIGHT_INTENSITY), name: "sun")!!;
    sun.local.rotation = maths::look_rotation((Vec3){ -0.4f, -1, -0.6f }.normalize(), { 0, 1, 0 });
    Node* camera_node = scene.add_camera(camera::perspective_deg(45, 0.05f), name: "camera")!!;
    camera_node.local.position = CAMERA_POSITION;
    camera_node.local.rotation = maths::look_rotation(CAMERA_TARGET - CAMERA_POSITION, { 0, 1, 0 });
    scene.update_world();
    renderer.prepare_scene(&scene)!!;

    io::printn("left: Mixamo source (COPY); right: Quaternius target");
    io::printn("T toggles CORRECT and COPY on the right, R toggles the rest pose, Escape quits");
    report(&showcase, scale, mapped);
    while (window.poll()) {
        Input* input = &window.input;
        if (input.key_released(Scancode.ESCAPE)) break;
        if (input.key_pressed(Scancode.T) || input.key_pressed(Scancode.R)) {
            if (input.key_pressed(Scancode.T)) showcase.corrected = !showcase.corrected;
            if (input.key_pressed(Scancode.R)) showcase.resting = !showcase.resting;
            play(&assets, &scene, &showcase);
            report(&showcase, scale, mapped);
        }
        anim::update(&assets, &scene, window.clock.delta);
        scene.update_world();
        platform::sync_window(&window, &renderer);
        renderer.render(&scene, camera_node, { .time = window.clock.total, .delta = window.clock.delta })!!;
    }
    return 0;
}
