module c3d::render;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::maths;
import c3d::model;
import c3d::scene;
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

fn void test_crowd_history_keeps_logical_sources_after_equal_count_parity_change() @test {
    CrowdHistoryFixture fixture = make_crowd_history_fixture();
    defer destroy_crowd_history_fixture(&fixture);
    AnimatedCrowd* crowd = fixture.scene.get(fixture.node, AnimatedCrowd);
    capture_crowd_history(&fixture, &fixture.first, 0);
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
    crowd_packed_order(order[..], crowd, 0);
    assert(order[0] == 2 && order[1] == 0 && order[2] == 1);
    foreach (&candidate : fixture.candidates) {
        PoseRecord* pose = fixture.first.previous_pose(&fixture.scene, candidate.node);
        assert(crowd_history_matches(
            assets: &fixture.assets,
            candidate: candidate,
            pose: pose,
        ));
    }
}

fn void test_crowd_history_rejects_replacement_and_incompatible_representation() @test {
    CrowdHistoryFixture fixture = make_crowd_history_fixture();
    defer destroy_crowd_history_fixture(&fixture);
    capture_crowd_history(&fixture, &fixture.first, 0);
    AnimatedCrowd* crowd = fixture.scene.get(fixture.node, AnimatedCrowd);
    MeshCandidate* candidate = &fixture.candidates[0];
    PoseRecord* pose = fixture.first.previous_pose(&fixture.scene, candidate.node);
    assert(crowd_history_matches(
        assets: &fixture.assets,
        candidate: candidate,
        pose: pose,
    ));
    fixture.assets.geometry(candidate.geometry).header.revision++;
    assert(!crowd_history_matches(
        assets: &fixture.assets,
        candidate: candidate,
        pose: pose,
    ));
    fixture.assets.geometry(candidate.geometry).header.revision--;
    uint saved_part = candidate.crowd_part;
    candidate.crowd_part = 1;
    assert(!crowd_history_matches(
        assets: &fixture.assets,
        candidate: candidate,
        pose: pose,
    ));
    candidate.crowd_part = saved_part;
    assert(crowd_history_matches(
        assets: &fixture.assets,
        candidate: candidate,
        pose: pose,
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
    ));
}
