module c3d::test::animation_legacy_freeze;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::asset::gltf;
import c3d::ecs;
import c3d::maths;
import c3d::model;
import c3d::scene;
import c3d::serial @public;
import std::hash::sha256;
import std::io;
import std::io::file;
import std::io::path;
import std::math;

const String HEX_DIGITS @local = "0123456789abcdef";
const String SKIN_SHA256 @local = "2d63048337e5b5e0e2e6ba3eac5ebe5ce9a619c8aea7c0e27a99d4c48d86a7fc";
const String MODEL_KEY @local = "animation_legacy/model";

fn String joined_path(String directory, String filename) @local {
    Path root = path::tnew(directory)!!;
    return (String)root.tappend(filename)!!;
}

fn char[64] digest_hex(char[32] digest) @local {
    char[64] hex;
    foreach (index, byte : digest) {
        hex[index * 2] = HEX_DIGITS[byte >> 4];
        hex[index * 2 + 1] = HEX_DIGITS[byte & 15];
    }
    return hex;
}

fn void? save_owner(
    Scene* scene,
    AssetStore* assets,
    Node* owner,
    String directory,
    String basename,
) @local {
    char[] bytes = serial::write_subtree(
        allocator: tmem,
        scene: scene,
        assets: assets,
        root: owner,
    )!;
    String text = serial::write_subtree_text(
        allocator: tmem,
        scene: scene,
        assets: assets,
        root: owner,
    )!;
    String binary_name = basename.tconcat(".bin");
    String text_name = basename.tconcat(".jsonc");
    file::save(joined_path(directory, binary_name), bytes)!;
    file::save(joined_path(directory, text_name), (char[])text)!;
    char[64] binary_hash = digest_hex(sha256::hash(bytes));
    char[64] text_hash = digest_hex(sha256::hash((char[])text));
    io::printfn("%s  %s (%s bytes)", (String)binary_hash[..], binary_name, bytes.len);
    io::printfn("%s  %s (%s bytes)", (String)text_hash[..], text_name, text.len);
}

fn Node*? create_animator_owner(Scene* scene, AssetStore* assets, ModelId model_id) @local {
    Node* owner = model::instantiate(
        assets: assets,
        scene: scene,
        model: model_id,
        name: "legacy_animator",
    )!;
    owner.local.position = { -4, 1, 6 };
    owner.layers = 5;
    ModelInstance* instance = scene.get(owner, ModelInstance);
    ClipId clip = instance.clips[0];
    Animator* animator = anim::add_animator(scene, owner);
    animator.root_node = 2;
    bool[4] all = { true, true, true, true };
    bool[4] upper = { false, true, true, false };
    JointMask all_mask = { .nodes = all[..] };
    JointMask upper_mask = { .nodes = upper[..] };
    AnimationActionId base = animator.play(assets, clip, {
        .mask = &all_mask, .root_motion = EXTRACT, .root_yaw = true,
    })!;
    Action* action = animator.action(base);
    action.speed = -0.5f;
    action.weight = 0.6f;
    action.loop = false;
    action.playing = false;
    action.time = 0.375f;
    AnimationActionId overlay = animator.play(assets, clip, {
        .layer = 1, .additive = true, .mask = &upper_mask,
    })!;
    action = animator.action(overlay);
    action.speed = 0.75f;
    action.weight = 0.25f;
    action.time = 0.25f;
    ClipId[2] clips = { clip, clip };
    float[2] positions = { -1, 2 };
    BlendSpace1D* space = animator.add_blend_space(
        assets: assets,
        clips: clips[..],
        positions: positions[..],
        desc: { .layer = 2, .mask = &all_mask },
    )!;
    space.parameter = 0.5f;
    space.weight = 0.75f;
    space.speed = -0.25f;
    space.playing = false;
    space.phase = 0.375;
    animator.action(space.actions[0]).speed = 1;
    animator.action(space.actions[1]).speed = 1.25f;
    scene.update_world();
    return owner;
}

fn Node*? create_crowd_owner(Scene* scene, AssetStore* assets, ModelId model_id) @local {
    ClipId clip = assets.model(model_id).data.clips[0];
    CrowdInstance[2] instances = {
        {
            .placement = {
                .position = { 1, 2, 3 }, .rotation = quaternion::IDENTITY, .scale = { 2, 2, 2 },
            },
            .pose = { .clip = clip, .time = 0.125f, .speed = 1, .loop = true },
            .color = { 0.2f, 0.4f, 0.6f, 0.8f },
        },
        {
            .placement = {
                .position = { -2, 1, 4 }, .rotation = quaternion::IDENTITY, .scale = { -1, 2, 0.5f },
            },
            .pose = { .clip = clip, .time = 0.25f, .speed = 1, .loop = true },
            .color = { 0.8f, 0.3f, 0.1f, 1 },
        },
    };
    bool[4] all = { true, true, true, true };
    bool[4] upper = { false, true, true, false };
    CrowdActionAuthoring[4] actions = {
        {
            .clip = clip, .speed = -0.5f, .weight = 0.6f, .loop = false, .playing = false,
            .mask = all[..], .root_motion = EXTRACT, .root_yaw = true,
        },
        {
            .clip = clip, .speed = 0.75f, .weight = 0, .layer = 1, .additive = true,
            .loop = true, .playing = true, .mask = upper[..],
        },
        { .clip = clip, .speed = 1, .weight = 0, .loop = true, .mask = all[..] },
        {
            .clip = clip, .speed = 1.25f, .weight = 0, .layer = 2, .additive = true,
            .loop = false, .mask = upper[..],
        },
    };
    uint[2] members = { 2, 3 };
    float[2] positions = { -1, 2 };
    CrowdSpaceAuthoring[1] spaces = { {
        .actions = members[..], .positions = positions[..], .parameter = 0.5f,
        .weight = 0.75f, .speed = -0.25f, .playing = false,
    } };
    CrowdInstanceAuthoring[2] descriptions = {
        { .configured = true, .root_node = 2, .base_action = 0, .actions = actions[..], .spaces = spaces[..] },
        { .configured = true, .root_node = anim::NO_ROOT_NODE, .base_action = uint::max },
    };
    Node* owner = scene.add_node(name: "legacy_crowd")!;
    model::attach_crowd(
        assets: assets,
        scene: scene,
        node: owner,
        model: model_id,
        capacity: 4,
        pose_bounds: { .min = { -4, -4, -4 }, .max = { 4, 4, 4 } },
        instances: instances[..],
        trace: true,
        actions_per_instance: 6,
        event_capacity: 0,
        authoring: descriptions[..],
    )!;
    owner.local.position = { 4, 2, -8 };
    owner.layers = 9;
    return owner;
}

fn void? freeze_animation_legacy(String repository, String directory) @local {
    serial::register_core_codecs()!;
    if (serial::codecs[ecs::assigned_slot(Animator)!].codec.version != 1
        || serial::codecs[ecs::assigned_slot(AnimatedCrowd)!].codec.version != 2) {
        return c3d::ASSET_FORMAT_ERROR~;
    }
    io::printn("Registered historical writers: Animator v1, AnimatedCrowd v2.");
    char[] source = file::load(tmem, joined_path(repository, "test/fixtures/gltf/skin.gltf"))!;
    char[64] source_hash = digest_hex(sha256::hash(source));
    if ((String)source_hash[..] != SKIN_SHA256) return c3d::ASSET_FORMAT_ERROR~;
    io::printfn("%s  skin.gltf (%s bytes)", (String)source_hash[..], source.len);
    AssetStore assets = asset::create_asset_store(mem, {
        .max_geometries = 8, .max_textures = 8, .max_materials = 8, .max_samplers = 8,
        .max_models = 2, .max_skeletons = 2, .max_clips = 4,
    });
    defer asset::destroy_asset_store(&assets);
    Scene scene = scene::create_scene(mem, { .max_nodes = 64 });
    defer scene::destroy_scene(&scene);
    ModelId model_id = gltf::load_model_memory(
        assets: &assets,
        bytes: source,
        base_dir: "",
        key: MODEL_KEY,
    )!;
    Node* animator_owner = create_animator_owner(&scene, &assets, model_id)!;
    save_owner(
        scene: &scene,
        assets: &assets,
        owner: animator_owner,
        directory: directory,
        basename: "animator-v1",
    )!;
    Node* crowd_owner = create_crowd_owner(&scene, &assets, model_id)!;
    save_owner(
        scene: &scene,
        assets: &assets,
        owner: crowd_owner,
        directory: directory,
        basename: "crowd-v2-pending",
    )!;
    model::prepare_crowd(&assets, &scene, crowd_owner)!;
    anim::crowd_update(&assets, &scene, 0.25f);
    save_owner(
        scene: &scene,
        assets: &assets,
        owner: crowd_owner,
        directory: directory,
        basename: "crowd-v2-prepared",
    )!;
}

fn int main(String[] arguments) {
    if (arguments.len != 3) {
        io::eprintn("Usage: animation_legacy_freeze OLD_REPOSITORY OUTPUT_DIRECTORY");
        return 2;
    }
    @pool() {
        if (catch excuse = freeze_animation_legacy(arguments[1], arguments[2])) {
            io::eprintfn("Historical animation capture failed: %s.", excuse);
            return 1;
        }
    };
    return 0;
}
