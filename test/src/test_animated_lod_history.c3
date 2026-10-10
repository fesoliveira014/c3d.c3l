module c3d::render;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::geometry;
import c3d::maths;
import c3d::model;
import c3d::scene;
import c3d::test::animated_crowd_fixtures;
import std::math;
import gpu;

const uint ANIMATED_HISTORY_PARTS @local = animated_crowd_fixtures::PARTS_MESH_COUNT;

struct AnimatedLodHistoryFixture @local {
    AssetStore assets;
    Scene scene;
    PartsFixture source;
    Node* node;
    GeometryId alternative;
    LodSelection selection;
    MeshCandidate[2 * ANIMATED_HISTORY_PARTS] candidates;
    ViewHistory first;
    ViewHistory second;
    Allocator history_allocator;
    bool different_local;
}

fn AnimatedLodPart[2 * ANIMATED_HISTORY_PARTS] animated_history_parts(AnimatedLodHistoryFixture* fixture) @local {
    ModelTemplate* template = &fixture.assets.model(fixture.source.mixed).data;
    AnimatedLodPart[2 * ANIMATED_HISTORY_PARTS] parts;
    for (uint level = 0; level < 2; level++) {
        foreach (uint index, mesh : template.meshes) {
            ModelSkin skin;
            foreach (source : template.skins) {
                if (source.mesh_node == mesh.node) skin = source;
            }
            if (level && skin.skeleton.generation) skin.skeleton = fixture.source.identical_skin;
            Mat4 local = level && index == 2 && fixture.different_local
              ? matrix::IDENTITY4.translate({ 1, 0, 0 }) : matrix::IDENTITY4;
            parts[level * ANIMATED_HISTORY_PARTS + index] = {
                .draw = {
                    .geometry = level && index == 1 ? fixture.alternative : mesh.geometry,
                    .material = mesh.material,
                    .local = local,
                },
                .mesh_index = index,
                .skin = skin,
                .default_morph_weights = mesh.default_morph_weights,
            };
        }
    }
    return parts;
}

fn void bind_animated_history_candidates(AnimatedLodHistoryFixture* fixture) @local {
    LodGroupState* state = fixture.scene.get(fixture.node, LodGroup).state;
    fixture.selection = {
        .scene_identity = fixture.scene.identity,
        .scene = &fixture.scene,
        .node = fixture.node,
        .state = state,
    };
    foreach (uint index, &candidate : fixture.candidates) {
        *candidate = {
            .node = fixture.node,
            .geometry = state.desc.parts[index].geometry,
            .material = state.desc.parts[index].material,
            .scene_identity = fixture.scene.identity,
            .lod = &fixture.selection,
            .lod_level = index / ANIMATED_HISTORY_PARTS,
            .lod_part = index,
        };
        assert(bind_animated_lod_candidate(&fixture.selection, candidate));
    }
}

fn void create_animated_history_fixture(
    AnimatedLodHistoryFixture* fixture,
    bool instanced = false,
    bool different_local = false,
) @local {
    fixture.different_local = different_local;
    fixture.history_allocator = mem;
    fixture.assets = asset::create_asset_store(mem, {
        .max_geometries = 8,
        .max_textures = asset::BUILTIN_TEXTURE_COUNT,
        .max_materials = 1,
        .max_samplers = asset::BUILTIN_SAMPLER_COUNT,
        .max_models = 5,
        .max_skeletons = 3,
        .max_clips = 4,
    });
    fixture.scene = scene::create_scene(mem, { .max_nodes = 32 });
    fixture.source = animated_crowd_fixtures::add_parts_fixture(&fixture.assets)!!;
    @pool() {
        Geometry alternative = geometry::box(tmem, 1, 1, 1);
        fixture.alternative = fixture.assets.add_geometry(&alternative)!!;
    };
    if (instanced) {
        CrowdInstance[2] seeds;
        foreach (uint source, &seed : seeds) {
            *seed = {
                .placement = maths::TRANSFORM_IDENTITY,
                .pose = { .clip = fixture.source.posing, .time = (float)source * 0.5f, .speed = 0, .loop = false },
                .color = { 1, 1, 1, 1 },
            };
            seed.placement.position.x = (float)source * 10;
        }
        seeds[1].placement.scale.x = -1;
        fixture.node = model::add_crowd(
            assets: &fixture.assets,
            scene: &fixture.scene,
            model: fixture.source.mixed,
            capacity: 3,
            pose_bounds: animated_crowd_fixtures::PARTS_POSE_BOUNDS,
            instances: seeds[..],
        )!!;
        anim::crowd_update(&fixture.assets, &fixture.scene, 0);
    } else {
        fixture.node = model::instantiate(&fixture.assets, &fixture.scene, fixture.source.mixed)!!;
    }
    AnimatedLodPart[2 * ANIMATED_HISTORY_PARTS] parts = animated_history_parts(fixture);
    LodLevel[2] levels = {
        { .first_part = 0, .part_count = ANIMATED_HISTORY_PARTS, .min_screen_size = 0.5f },
        { .first_part = ANIMATED_HISTORY_PARTS, .part_count = ANIMATED_HISTORY_PARTS },
    };
    model::attach_animated_lod(
        assets: &fixture.assets,
        scene: &fixture.scene,
        owner: fixture.node,
        desc: {
            .parts = parts[..],
            .levels = levels[..],
            .has_bounds_override = !instanced,
            .local_bounds = animated_crowd_fixtures::PARTS_POSE_BOUNDS,
        },
    )!!;
    fixture.scene.update_world();
    bind_animated_history_candidates(fixture);
}

fn void destroy_animated_history_fixture(AnimatedLodHistoryFixture* fixture) @local {
    free_view_history(fixture.history_allocator, &fixture.first);
    free_view_history(fixture.history_allocator, &fixture.second);
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
}

fn void capture_animated_history(
    AnimatedLodHistoryFixture* fixture,
    ViewHistory* history,
    MeshCandidate[] candidates,
) @local {
    history.commit(
        allocator: fixture.history_allocator,
        assets: &fixture.assets,
        scene: &fixture.scene,
        candidates: candidates,
        view_proj: matrix::IDENTITY4,
        time: 0,
    );
    history.publish();
}

fn PoseRecord* previous_animated_history(
    AnimatedLodHistoryFixture* fixture,
    ViewHistory* history,
    uint part,
) @local {
    return history.previous_candidate_pose(
        scene: &fixture.scene,
        assets: &fixture.assets,
        candidate: &fixture.candidates[part],
    );
}

fn void test_animated_lod_history_preserves_same_owner_parts_and_simultaneous_representations() @test {
    foreach (bool instanced : { false, true }) {
        AnimatedLodHistoryFixture fixture;
        create_animated_history_fixture(&fixture, instanced);
        defer destroy_animated_history_fixture(&fixture);
        uint count = instanced ? (uint)fixture.candidates.len : ANIMATED_HISTORY_PARTS;
        capture_animated_history(&fixture, &fixture.first, fixture.candidates[:count]);
        PoseRecord* rigid = previous_animated_history(&fixture, &fixture.first, 1);
        PoseRecord* first_morph = previous_animated_history(&fixture, &fixture.first, 2);
        PoseRecord* second_morph = previous_animated_history(&fixture, &fixture.first, 3);
        assert(rigid && first_morph && second_morph);
        assert(rigid != first_morph && first_morph != second_morph);
        for (uint part = 0; part < count; part++) {
            assert(!previous_animated_history(&fixture, &fixture.first, part).palette.len);
        }
        assert(rigid.instances[0] == bitcast(animated_lod_part_local(&fixture.candidates[1]), Mat4f));
        assert(first_morph.morphs[0].weights != second_morph.morphs[0].weights);
        PoseRecord* owner = fixture.first.previous_pose(&fixture.scene, fixture.node);
        uint sources = instanced ? 2 : 1;
        assert(owner.palette.len == fixture.selection.state.animated.joint_nodes.len * (instanced ? 3 : 1));
        if (instanced) {
            AnimatedCrowd* crowd = fixture.candidates[0].crowd;
            foreach (index, palette : crowd.palettes[:sources * crowd.joint_count]) {
                assert(owner.palette[index] == bitcast(palette, Mat4f));
            }
            PoseRecord* alternative = previous_animated_history(&fixture, &fixture.first, ANIMATED_HISTORY_PARTS + 1);
            PoseRecord* lower_morph = previous_animated_history(&fixture, &fixture.first, ANIMATED_HISTORY_PARTS + 2);
            assert(lower_morph && lower_morph != first_morph);
            assert(alternative && alternative != rigid && alternative.instance_count == sources);
            assert(alternative.instances[1]
              == bitcast(animated_lod_part_local(&fixture.candidates[ANIMATED_HISTORY_PARTS + 1], 1), Mat4f));
        }
    }
}

fn void test_animated_lod_history_accepts_compatible_levels_and_rejects_topology_changes() @test {
    AnimatedLodHistoryFixture fixture;
    create_animated_history_fixture(&fixture);
    defer destroy_animated_history_fixture(&fixture);
    capture_animated_history(&fixture, &fixture.first, fixture.candidates[:ANIMATED_HISTORY_PARTS]);
    assert(previous_animated_history(&fixture, &fixture.first, ANIMATED_HISTORY_PARTS));
    assert(previous_animated_history(&fixture, &fixture.first, ANIMATED_HISTORY_PARTS + 2));
    assert(!previous_animated_history(&fixture, &fixture.first, ANIMATED_HISTORY_PARTS + 1));
    fixture.assets.geometry(fixture.candidates[2].geometry).header.revision++;
    assert(!previous_animated_history(&fixture, &fixture.first, 2));
    fixture.assets.geometry(fixture.candidates[2].geometry).header.revision--;
    fixture.assets.skeleton(fixture.source.common_skin).header.revision++;
    assert(!previous_animated_history(&fixture, &fixture.first, 0));
    fixture.assets.skeleton(fixture.source.common_skin).header.revision--;
    fixture.assets.model(fixture.source.mixed).header.revision++;
    assert(!previous_animated_history(&fixture, &fixture.first, 1));
    fixture.assets.model(fixture.source.mixed).header.revision--;
    fixture.selection.state.descriptor_revision++;
    assert(!previous_animated_history(&fixture, &fixture.first, 1));
    fixture.selection.state.descriptor_revision--;
    fixture.selection.state.identity++;
    assert(!previous_animated_history(&fixture, &fixture.first, 1));
    fixture.selection.state.identity--;
    Node* source = fixture.candidates[1].source_node;
    Entity identity = source.id;
    source.id.generation++;
    assert(!previous_animated_history(&fixture, &fixture.first, 1));
    source.id = identity;
    ulong scene_identity = fixture.scene.identity;
    fixture.scene.identity++;
    assert(!previous_animated_history(&fixture, &fixture.first, 1));
    fixture.scene.identity = scene_identity;
}

fn void test_animated_lod_history_rejects_aliases_with_different_local_transforms() @test {
    AnimatedLodHistoryFixture fixture;
    create_animated_history_fixture(&fixture, false, true);
    defer destroy_animated_history_fixture(&fixture);
    capture_animated_history(&fixture, &fixture.first, fixture.candidates[:ANIMATED_HISTORY_PARTS]);
    assert(previous_animated_history(&fixture, &fixture.first, 2));
    assert(!previous_animated_history(&fixture, &fixture.first, ANIMATED_HISTORY_PARTS + 2));
}

fn void test_animated_lod_history_preserves_unchanged_logical_sources_after_reuse_growth_and_parity() @test {
    AnimatedLodHistoryFixture fixture;
    create_animated_history_fixture(&fixture, true);
    defer destroy_animated_history_fixture(&fixture);
    capture_animated_history(&fixture, &fixture.first, fixture.candidates[..]);
    PoseRecord* pose = previous_animated_history(&fixture, &fixture.first, 2);
    MeshCandidate* candidate = &fixture.candidates[2];
    AnimatedCrowd* crowd = candidate.crowd;
    assert(animated_lod_previous_valid(pose, candidate, 0));
    assert(animated_lod_previous_valid(pose, candidate, 1));
    Mat4f first = pose.instances[0];
    crowd.placements[0].scale.x = -1;
    crowd.placements[1].scale.x = 1;
    assert(animated_lod_previous_valid(pose, candidate, 0));
    assert(animated_lod_previous_valid(pose, candidate, 1));
    assert(pose.instances[0] == first);
    anim::reset_crowd_playback_slot(crowd.playback, 1);
    assert(animated_lod_previous_valid(pose, candidate, 0));
    assert(!animated_lod_previous_valid(pose, candidate, 1));
    crowd.count = 3;
    assert(animated_lod_previous_valid(pose, candidate, 0));
    assert(!animated_lod_previous_valid(pose, candidate, 2));
    crowd.count = 2;
}

fn void test_animated_lod_history_observations_are_view_local_and_discarded_frames_reject_history() @test {
    AnimatedLodHistoryFixture fixture;
    create_animated_history_fixture(&fixture);
    defer destroy_animated_history_fixture(&fixture);
    capture_animated_history(&fixture, &fixture.first, fixture.candidates[:ANIMATED_HISTORY_PARTS]);
    ModelInstance* source = fixture.scene.get(fixture.node, ModelInstance);
    source.present_node(animated_crowd_fixtures::PARTS_RIGID_NODE).local.position.x += 5;
    fixture.scene.update_world();
    capture_animated_history(&fixture, &fixture.second, fixture.candidates[:ANIMATED_HISTORY_PARTS]);
    PoseRecord* first = previous_animated_history(&fixture, &fixture.first, 1);
    PoseRecord* second = previous_animated_history(&fixture, &fixture.second, 1);
    assert(first && second && first.instances[0] != second.instances[0]);
    fixture.first.commit(
        allocator: mem,
        assets: &fixture.assets,
        scene: &fixture.scene,
        candidates: fixture.candidates[:ANIMATED_HISTORY_PARTS],
        view_proj: matrix::IDENTITY4,
        time: 1,
    );
    fixture.first.discard();
    assert(!previous_animated_history(&fixture, &fixture.first, 1));
    assert(previous_animated_history(&fixture, &fixture.second, 1));
    capture_animated_history(&fixture, &fixture.first, fixture.candidates[:1]);
    assert(!previous_animated_history(&fixture, &fixture.first, 1));
    assert(previous_animated_history(&fixture, &fixture.first, 0));
}

fn void test_animated_lod_history_reuses_owned_storage_between_observations() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        AnimatedLodHistoryFixture fixture;
        create_animated_history_fixture(&fixture, true);
        defer destroy_animated_history_fixture(&fixture);

        fixture.history_allocator = &tracker;
        capture_animated_history(&fixture, &fixture.first, fixture.candidates[..]);
        sz allocations = tracker.total_allocation_count();
        for (uint frame = 0; frame < 4; frame++) {
            capture_animated_history(&fixture, &fixture.first, fixture.candidates[..]);
        }
        assert(tracker.total_allocation_count() == allocations);
    }
    assert(!tracker.has_leaks());
}
