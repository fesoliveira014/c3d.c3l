module c3d::render;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::maths;
import c3d::model;
import c3d::scene;
import c3d::shader;
import c3d::test::animated_crowd_fixtures;
import gpu;
import std::math;

struct CrowdHistoryFixture @local {
    AssetStore assets;
    Scene scene;
    PartsFixture parts;
    Node* node;
    MeshCandidate[animated_crowd_fixtures::PARTS_MESH_COUNT] candidates;
    ViewHistory first;
    ViewHistory second;
}

fn CrowdHistoryFixture make_crowd_history_fixture() @local {
    CrowdHistoryFixture fixture = {
        .assets = asset::create_asset_store(mem, {
            .max_geometries = 4,
            .max_textures = asset::BUILTIN_TEXTURE_COUNT,
            .max_materials = 1,
            .max_samplers = asset::BUILTIN_SAMPLER_COUNT,
            .max_models = 5,
            .max_skeletons = 3,
            .max_clips = 4,
        }),
        .scene = scene::create_scene(mem, { .max_nodes = 32 }),
    };
    fixture.parts = animated_crowd_fixtures::add_parts_fixture(&fixture.assets)!!;
    CrowdInstance[3] seeds;
    foreach (uint instance, &seed : seeds) {
        *seed = {
            .placement = maths::TRANSFORM_IDENTITY,
            .pose = {
                .clip = fixture.parts.posing,
                .time = (float)instance * 0.3f,
                .speed = 0,
                .loop = false,
            },
            .color = { 1, 1, 1, 1 },
        };
        seed.placement.position.x = (float)instance * 30;
    }
    seeds[1].placement.scale.x = -1;
    fixture.node = model::add_crowd(
        assets: &fixture.assets,
        scene: &fixture.scene,
        model: fixture.parts.mixed,
        capacity: 4,
        pose_bounds: animated_crowd_fixtures::PARTS_POSE_BOUNDS,
        instances: seeds[..],
    )!!;
    anim::crowd_update(&fixture.assets, &fixture.scene, 0);
    AnimatedCrowd* crowd = fixture.scene.get(fixture.node, AnimatedCrowd);
    foreach (uint index, part : crowd.parts) {
        fixture.candidates[index] = {
            .node = fixture.scene.node(part.batch),
            .geometry = fixture.parts.geometries[index],
            .batch = fixture.scene.world.get(part.batch, InstancedMesh),
            .crowd = crowd,
            .crowd_part = index,
        };
    }
    return fixture;
}

fn void destroy_crowd_history_fixture(CrowdHistoryFixture* fixture) @local {
    free_view_history(mem, &fixture.first);
    free_view_history(mem, &fixture.second);
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
}

fn void capture_crowd_history(CrowdHistoryFixture* fixture, ViewHistory* history, double time) @local {
    history.commit(
        allocator: mem,
        assets: &fixture.assets,
        scene: &fixture.scene,
        candidates: fixture.candidates[..],
        view_proj: matrix::IDENTITY4,
        time: time,
    );
    history.publish();
}

fn void test_crowd_history_reorders_previous_sources_after_equal_count_parity_change() @test {
    CrowdHistoryFixture fixture = make_crowd_history_fixture();
    defer destroy_crowd_history_fixture(&fixture);
    AnimatedCrowd* crowd = fixture.scene.get(fixture.node, AnimatedCrowd);
    capture_crowd_history(&fixture, &fixture.first, 0);
    PoseRecord* owner = fixture.first.previous_pose(&fixture.scene, fixture.node);
    foreach (usz index, value : crowd.palettes[:crowd.joint_count * crowd.count]) {
        assert(owner.palette[index] == bitcast(value, Mat4f));
    }
    foreach (&candidate : fixture.candidates) {
        PoseRecord* pose = fixture.first.previous_pose(&fixture.scene, candidate.node);
        for (uint source = 0; source < crowd.count; source++) {
            assert(pose.instances[source] == bitcast(crowd.part_transform(source, candidate.crowd_part), Mat4f));
        }
    }
    crowd.placements[0].scale.x = -1;
    crowd.placements[1].scale.x = 1;
    anim::crowd_update(&fixture.assets, &fixture.scene, 0);
    uint[3] order;
    crowd_packed_order(
        packed: order[..],
        placements: crowd.placements[:crowd.count],
        crowd: crowd,
        part: 0,
    );
    assert(order[0] == 2 && order[1] == 0 && order[2] == 1);
    Mat4f[6] previous;
    write_crowd_previous_data(
        target: ((char*)&previous)[:previous.len * Mat4f::size],
        data: owner.palette.ptr,
        order: order[..],
        stride: crowd.joint_count * Mat4f::size,
    );
    foreach (uint source, packed : order) {
        for (uint joint = 0; joint < crowd.joint_count; joint++) {
            assert(previous[packed * crowd.joint_count + joint] == owner.palette[source * crowd.joint_count + joint]);
        }
    }
    foreach (&candidate : fixture.candidates) {
        PoseRecord* pose = fixture.first.previous_pose(&fixture.scene, candidate.node);
        assert(crowd_history_matches(
            assets: &fixture.assets,
            candidate: candidate,
            pose: pose,
            crowd_pose: owner,
        ));
        uint[3] part_order;
        crowd_packed_order(
            packed: part_order[..],
            placements: crowd.placements[:crowd.count],
            crowd: crowd,
            part: candidate.crowd_part,
        );
        Mat4f[3] instances;
        write_crowd_previous_data(
            target: ((char*)&instances)[:instances.len * Mat4f::size],
            data: pose.instances.ptr,
            order: part_order[..],
            stride: Mat4f::size,
        );
        foreach (uint source, packed : part_order) assert(instances[packed] == pose.instances[source]);
        if (!crowd.parts[candidate.crowd_part].weight_count) continue;
        MorphWeightsGpu[3] morphs;
        write_crowd_previous_data(
            target: ((char*)&morphs)[:morphs.len * MorphWeightsGpu::size],
            data: pose.morphs.ptr,
            order: part_order[..],
            stride: MorphWeightsGpu::size,
        );
        foreach (uint source, packed : part_order) {
            assert(morphs[packed].indices == pose.morphs[source].indices);
            assert(morphs[packed].weights == pose.morphs[source].weights);
            assert(morphs[packed].count == pose.morphs[source].count);
        }
    }
}

fn void test_crowd_history_rejects_replacement_and_incompatible_representation() @test {
    CrowdHistoryFixture fixture = make_crowd_history_fixture();
    defer destroy_crowd_history_fixture(&fixture);
    capture_crowd_history(&fixture, &fixture.first, 0);
    AnimatedCrowd* crowd = fixture.scene.get(fixture.node, AnimatedCrowd);
    MeshCandidate* candidate = &fixture.candidates[0];
    PoseRecord* pose = fixture.first.previous_pose(&fixture.scene, candidate.node);
    PoseRecord* owner = fixture.first.previous_pose(&fixture.scene, fixture.node);
    assert(crowd_history_matches(
        assets: &fixture.assets,
        candidate: candidate,
        pose: pose,
        crowd_pose: owner,
    ));
    fixture.assets.geometry(candidate.geometry).header.revision++;
    assert(!crowd_history_matches(
        assets: &fixture.assets,
        candidate: candidate,
        pose: pose,
        crowd_pose: owner,
    ));
    fixture.assets.geometry(candidate.geometry).header.revision--;
    fixture.assets.skeleton(fixture.parts.common_skin).header.revision++;
    assert(!crowd_history_matches(
        assets: &fixture.assets,
        candidate: candidate,
        pose: pose,
        crowd_pose: owner,
    ));
    fixture.assets.skeleton(fixture.parts.common_skin).header.revision--;
    fixture.assets.model(crowd.model).header.revision++;
    assert(!crowd_history_matches(
        assets: &fixture.assets,
        candidate: candidate,
        pose: pose,
        crowd_pose: owner,
    ));
    fixture.assets.model(crowd.model).header.revision--;
    uint saved_part = candidate.crowd_part;
    candidate.crowd_part = 1;
    assert(!crowd_history_matches(
        assets: &fixture.assets,
        candidate: candidate,
        pose: pose,
        crowd_pose: owner,
    ));
    candidate.crowd_part = saved_part;
    CrowdPlaybackState* replacement = anim::create_crowd_playback(
        allocator: mem,
        template: &fixture.assets.model(crowd.model).data,
        placements: crowd.placements,
        actions_per_instance: crowd.actions_per_instance,
        event_capacity: crowd.event_capacity,
    )!!;
    defer anim::destroy_crowd_playback(replacement);
    CrowdPlaybackState* original = crowd.playback;
    crowd.playback = replacement;
    assert(!crowd_history_matches(
        assets: &fixture.assets,
        candidate: candidate,
        pose: pose,
        crowd_pose: owner,
    ));
    crowd.playback = original;
    assert(crowd_history_matches(
        assets: &fixture.assets,
        candidate: candidate,
        pose: pose,
        crowd_pose: owner,
    ));
    CrowdInstance[3] seeds;
    foreach (uint instance, &seed : seeds) {
        *seed = {
            .placement = crowd.placements[instance],
            .pose = crowd.seeds[instance],
            .color = crowd.colors[instance],
        };
    }
    model::set_crowd(
        assets: &fixture.assets,
        scene: &fixture.scene,
        node: fixture.node,
        instances: seeds[..],
    )!!;
    assert(!crowd_history_matches(
        assets: &fixture.assets,
        candidate: candidate,
        pose: pose,
        crowd_pose: owner,
    ));
}

fn void test_crowd_history_keeps_independent_view_observations_and_aborts() @test {
    CrowdHistoryFixture fixture = make_crowd_history_fixture();
    defer destroy_crowd_history_fixture(&fixture);
    capture_crowd_history(&fixture, &fixture.first, 0);
    AnimatedCrowd* crowd = fixture.scene.get(fixture.node, AnimatedCrowd);
    MeshCandidate* candidate = &fixture.candidates[1];
    PoseRecord* first = fixture.first.previous_pose(&fixture.scene, candidate.node);
    Mat4f saved = first.instances[0];
    CrowdPlayer player = crowd.playback.player(crowd.playback.instance_id(0)!!)!!;
    player.base_action()!!.time = 0.8f;
    anim::crowd_update(&fixture.assets, &fixture.scene, 0);
    capture_crowd_history(&fixture, &fixture.second, 1);
    PoseRecord* second = fixture.second.previous_pose(&fixture.scene, candidate.node);
    assert(first.instances[0] == saved && second.instances[0] != saved);
    fixture.second.commit(
        allocator: mem,
        assets: &fixture.assets,
        scene: &fixture.scene,
        candidates: fixture.candidates[..],
        view_proj: matrix::IDENTITY4,
        time: 2,
    );
    fixture.second.discard();
    assert(!fixture.second.has_previous(&fixture.scene, candidate.node));
    assert(fixture.first.has_previous(&fixture.scene, candidate.node) && first.instances[0] == saved);
    capture_crowd_history(&fixture, &fixture.second, 3);
    assert(fixture.second.has_previous(&fixture.scene, candidate.node));
}
