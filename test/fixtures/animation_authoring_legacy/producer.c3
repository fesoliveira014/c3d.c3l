module c3d::test::animation_authoring_freeze;

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
const String MODEL_KEY @local = "animation_authoring_legacy/model";

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

fn WeightedJointMask? authoring_weighted_mask(AssetStore* assets, ModelId model_id) @local {
    return anim::create_weighted_joint_mask(
        allocator: tmem,
        assets: assets,
        model: model_id,
        names: { "mesh", "joint_root", "joint_tip" },
        weights: { 0.25f, 0.5f, 0.75f },
    );
}

fn Node*? create_animator_owner(Scene* scene, AssetStore* assets, ModelId model_id) @local {
    Node* owner = model::instantiate(
        assets: assets,
        scene: scene,
        model: model_id,
        name: "legacy_weighted_animator",
    )!;
    owner.local.position = { -4, 1, 6 };
    owner.layers = 5;
    Animator* animator = anim::add_animator(scene, owner);
    animator.root_node = 2;
    ClipId clip = assets.model(model_id).data.clips[0];
    AnimationActionId base = animator.play(assets, clip, { .root_motion = EXTRACT, .root_yaw = true })!;
    Action* action = animator.action(base);
    action.speed = -0.5f;
    action.weight = 0.6f;
    action.loop = false;
    action.playing = false;
    action.time = 0.375f;

    WeightedJointMask mask = authoring_weighted_mask(assets, model_id)!;
    Vec2[3] points = { { -1, -1 }, { 2, -1 }, { -1, 2 } };
    BlendTriangle[1] triangles = { { .indices = { 2, 1, 0 } } };
    BlendSpace2D* space = animator.add_blend_space_2d(
        assets: assets,
        clips: { clip, clip, clip },
        coordinates: points[..],
        triangles: triangles[..],
        desc: { .layer = 1, .additive = true, .weighted_mask = &mask, .additive_scale = MULTIPLICATIVE },
    )!;
    space.parameter = { 0.5f, 0.25f };
    space.weight = 0.75f;
    space.speed = -0.25f;
    space.playing = false;
    anim::update(assets, scene, 0.25f);
    space.phase = 0.375;

    return owner;
}

fn Node*? create_crowd_owner(Scene* scene, AssetStore* assets, ModelId model_id) @local {
    ClipId clip = assets.model(model_id).data.clips[0];
    WeightedJointMask weighted = authoring_weighted_mask(assets, model_id)!;
    bool[4] all = { true, true, true, true };
    CrowdActionAuthoring[4] actions;
    actions[0] = {
        .clip = clip,
        .speed = -0.5f,
        .weight = 0.6f,
        .mask = all[..],
        .root_motion = EXTRACT,
        .root_yaw = true,
    };
    for (uint index = 1; index < actions.len; index++) {
        actions[index] = {
            .clip = clip,
            .speed = 1 + 0.25f * (float)(index - 1),
            .layer = 1,
            .additive = true,
            .loop = true,
            .weighted_mask = weighted.nodes,
            .additive_scale = MULTIPLICATIVE,
        };
    }
    uint[3] members = { 1, 2, 3 };
    Vec2[3] points = { { -1, -1 }, { 2, -1 }, { -1, 2 } };
    BlendTriangle[1] triangles = { { .indices = { 2, 1, 0 } } };
    CrowdSpaceAuthoring[1] spaces = { {
        .actions = members[..],
        .weight = 0.75f,
        .speed = -0.25f,
        .kind = TWO_DIMENSIONAL,
        .points = points[..],
        .triangles = triangles[..],
        .parameter_2d = { 0.5f, 0.25f },
    } };
    CrowdInstanceAuthoring[2] authoring = {
        { .configured = true, .root_node = 2, .base_action = 0, .actions = actions[..], .spaces = spaces[..] },
        { .configured = true, .root_node = anim::NO_ROOT_NODE, .base_action = uint::max },
    };
    CrowdInstance[2] instances = {
        {
            .placement = { .position = { 1, 2, 3 }, .rotation = quaternion::IDENTITY, .scale = { 2, 2, 2 } },
            .pose = { .clip = clip, .time = 0.125f, .speed = 1, .loop = true },
            .color = { 0.2f, 0.4f, 0.6f, 0.8f },
        },
        {
            .placement = { .position = { -2, 1, 4 }, .rotation = quaternion::IDENTITY, .scale = { -1, 2, 0.5f } },
            .pose = { .clip = clip, .time = 0.25f, .speed = 1, .loop = true },
            .color = { 0.8f, 0.3f, 0.1f, 1 },
        },
    };
    Node* owner = scene.add_node(name: "legacy_weighted_crowd")!;
    owner.local.position = { 4, 2, -8 };
    owner.layers = 9;
    model::attach_crowd(
        assets: assets,
        scene: scene,
        node: owner,
        model: model_id,
        capacity: 3,
        pose_bounds: { .min = { -4, -4, -4 }, .max = { 4, 4, 4 } },
        instances: instances[..],
        trace: true,
        actions_per_instance: 4,
        event_capacity: 17,
        authoring: authoring[..],
    )!;

    return owner;
}

fn void? capture_authoring(String repository, String directory) @local {
    serial::register_core_codecs()!;
    if (serial::codecs[ecs::assigned_slot(Animator)!].codec.version != 2
      || serial::codecs[ecs::assigned_slot(AnimatedCrowd)!].codec.version != 3) {
        return c3d::ASSET_FORMAT_ERROR~;
    }
    io::printn("Registered historical writers: Animator v2, AnimatedCrowd v3.");
    char[] source = file::load(tmem, joined_path(repository, "test/fixtures/gltf/skin.gltf"))!;
    char[64] source_hash = digest_hex(sha256::hash(source));
    if ((String)source_hash[..] != SKIN_SHA256) return c3d::ASSET_FORMAT_ERROR~;
    io::printfn("%s  skin.gltf (%s bytes)", (String)source_hash[..], source.len);

    AssetStore assets = asset::create_asset_store(mem, {
        .max_geometries = 8,
        .max_textures = 8,
        .max_materials = 8,
        .max_samplers = 8,
        .max_models = 2,
        .max_skeletons = 2,
        .max_clips = 4,
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
    Node* animator = create_animator_owner(&scene, &assets, model_id)!;
    save_owner(
        scene: &scene,
        assets: &assets,
        owner: animator,
        directory: directory,
        basename: "animator-v2",
    )!;
    Node* crowd = create_crowd_owner(&scene, &assets, model_id)!;
    save_owner(
        scene: &scene,
        assets: &assets,
        owner: crowd,
        directory: directory,
        basename: "crowd-v3-pending",
    )!;
    model::prepare_crowd(&assets, &scene, crowd)!;
    anim::crowd_update(&assets, &scene, 0.25f);
    save_owner(
        scene: &scene,
        assets: &assets,
        owner: crowd,
        directory: directory,
        basename: "crowd-v3-prepared",
    )!;
}

fn int main(String[] arguments) {
    if (arguments.len != 3) {
        io::eprintn("Usage: animation_authoring_freeze OLD_REPOSITORY OUTPUT_DIRECTORY");
        return 2;
    }
    @pool() {
        if (catch excuse = capture_authoring(arguments[1], arguments[2])) {
            io::eprintfn("Historical authoring capture failed: %s.", excuse);
            return 1;
        }
    };
    return 0;
}
