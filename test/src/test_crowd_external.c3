module c3d::test::crowd_external;

import c3d;
import c3d::anim;
import c3d::anim::retarget;
import c3d::asset;
import c3d::maths;
import c3d::model;
import c3d::scene;
import c3d::test::animated_crowd_fixtures;
import std::math;

fn AssetStore external_crowd_store() @local {
    return asset::create_asset_store(mem, {
        .max_geometries = 4,
        .max_textures = asset::BUILTIN_TEXTURE_COUNT,
        .max_materials = 1,
        .max_samplers = asset::BUILTIN_SAMPLER_COUNT,
        .max_models = 5,
        .max_skeletons = 3,
        .max_clips = 8,
    });
}

fn ClipId bake_external_crowd_clip(AssetStore* assets, PartsFixture* fixture) @local {
    ModelTemplate* template = &assets.model(fixture.mixed).data;
    @pool() {
        NodeIndexMapping[] mappings = alloc::new_array(tmem, NodeIndexMapping, template.nodes.len);
        Quat[] calibration = alloc::new_array(tmem, Quat, template.nodes.len);
        foreach (uint node, &mapping : mappings) {
            *mapping = { .source_node = node, .target_node = node };
            calibration[node] = maths::TRANSFORM_IDENTITY.rotation;
        }
        RetargetProfileDesc desc = retarget::RETARGET_PROFILE_DESC_DEFAULT;
        desc.mapping_mode = ProfileMappingMode.BY_INDEX;
        desc.index_map = mappings;
        desc.source_calibration = calibration;
        desc.target_calibration = calibration;
        RetargetProfile profile = retarget::create_retarget_profile(
            allocator: mem,
            source_nodes: template.nodes,
            target: template,
            desc: desc,
        )!!;
        defer retarget::destroy_retarget_profile(&profile);
        AnimationClip result = retarget::retarget_with_profile(
            allocator: mem,
            source: &assets.clip(fixture.posing).data,
            source_nodes: template.nodes,
            target: template,
            profile: &profile,
        )!!;
        assert(result.tracks.len > assets.clip(fixture.posing).data.tracks.len);
        return assets.add_clip_owned(&result, "external_crowd/profiled")!!;
    };
}

fn ClipId add_incompatible_crowd_clip(AssetStore* assets, uint node) @local {
    AnimationClip clip = {
        .name = "incompatible".copy(mem),
        .duration = 1,
        .targets = alloc::new_array(mem, uint, 1),
        .tracks = alloc::new_array(mem, Track, 1),
    };
    clip.targets[0] = node;
    clip.tracks[0] = {
        .target = 0,
        .path = TargetPath.TRANSLATION,
        .interpolation = Interpolation.LINEAR,
        .times = alloc::new_array(mem, float, 2),
        .values = alloc::new_array(mem, float, 6),
    };
    clip.tracks[0].times[1] = 1;
    return assets.add_clip_owned(&clip)!!;
}

fn void test_crowd_external_profiled_clip_matches_animator_and_rejects_stale_or_bad_layout() @test {
    AssetStore assets = external_crowd_store();
    defer asset::destroy_asset_store(&assets);
    PartsFixture fixture = animated_crowd_fixtures::add_parts_fixture(&assets)!!;
    Scene scene = scene::create_scene(mem, { .max_nodes = 48 });
    defer scene::destroy_scene(&scene);
    ClipId external = bake_external_crowd_clip(&assets, &fixture);
    foreach (clip : assets.model(fixture.mixed).data.clips) assert(!c3d::same_id(clip, external));
    CrowdInstance[1] seeds = { {
        .placement = maths::TRANSFORM_IDENTITY,
        .pose = { .clip = fixture.posing, .speed = 1, .loop = true },
        .color = { 1, 1, 1, 1 },
    } };
    Node* owner = model::add_crowd(
        assets: &assets,
        scene: &scene,
        model: fixture.mixed,
        capacity: 1,
        pose_bounds: animated_crowd_fixtures::PARTS_POSE_BOUNDS,
        instances: seeds[..],
    )!!;
    AnimatedCrowd* crowd = scene.get(owner, AnimatedCrowd);
    CrowdPlayer player = crowd.playback.player(crowd.playback.instance_id(0)!!)!!;
    player.stop(crowd.playback.slots[0].base_action)!!;
    AnimationActionId crowd_action = player.play(&assets, external)!!;
    assert(player.action(crowd_action).cursors.len == assets.clip(external).data.tracks.len);
    Node* reference = model::instantiate(&assets, &scene, fixture.mixed)!!;
    Animator* animator = anim::add_animator(&scene, reference);
    AnimationActionId reference_action = animator.play(&assets, external)!!;
    ModelInstance* instance = scene.get(reference, ModelInstance);
    float[8] steps = { 0, 1.0f / 60, 0.25f, 1.7f, 0, 0.1f, 0.4f, 2.25f };
    foreach (usz update, dt : steps) {
        if (update == 4) {
            player.action(crowd_action).time = 0.8f;
            animator.action(reference_action).time = 0.8f;
            player.action(crowd_action).speed = -1.5f;
            animator.action(reference_action).speed = -1.5f;
        }
        anim::update(&assets, &scene, dt);
        anim::crowd_update(&assets, &scene, dt);
        foreach (uint node, actual : crowd.playback.poses[:crowd.playback.base_pose.len]) {
            Transform expected = instance.present_node(node).local;
            assert(actual.position == expected.position);
            assert(actual.rotation.v == expected.rotation.v);
            assert(actual.scale == expected.scale);
        }
        foreach (usz mesh_index, node : crowd.playback.mesh_nodes) {
            Mesh* mesh = scene.get(instance.present_node(node), Mesh);
            float[] actual = crowd.playback.logical_weights[mesh_index];
            assert(actual.len == mesh.morph_weights.len);
            foreach (usz weight, expected : mesh.morph_weights) assert(actual[weight] == expected);
        }
        assert(player.action(crowd_action).time == animator.action(reference_action).time);
    }
    AnimationActionId kept = crowd_action;
    float kept_time = player.action(kept).time;
    uint kept_count = crowd.playback.slots[0].action_count;
    ClipId bad = add_incompatible_crowd_clip(&assets, (uint)crowd.playback.base_pose.len);
    assert(@catch(player.play(&assets, bad)) == c3d::INVALID_ARGUMENT);
    assert(crowd.playback.slots[0].action_count == kept_count && player.action(kept).time == kept_time);
    player.stop(kept)!!;
    animator.stop(reference_action)!!;
    assets.remove_clip(external);
    assert(@catch(player.play(&assets, external)) == c3d::INVALID_ID);
    ClipId reused = add_incompatible_crowd_clip(&assets, (uint)crowd.playback.base_pose.len);
    assert(reused.index == external.index && reused.generation != external.generation);
    assert(@catch(player.play(&assets, external)) == c3d::INVALID_ID);
    assert(@catch(player.play(&assets, reused)) == c3d::INVALID_ARGUMENT);
}
