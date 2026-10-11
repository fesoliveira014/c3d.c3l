module c3d::render;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::geometry;
import c3d::maths;
import c3d::model;
import c3d::scene;
import c3d::shader;
import c3d::spatial;
import c3d::test::animated_crowd_fixtures;
import gpu;
import std::math;

const uint ANIMATED_HISTORY_PARTS @local = animated_crowd_fixtures::PARTS_MESH_COUNT;
const uint SHADOW_BASE_PARTS @local = 5;
const uint SHADOW_REDUCED_PARTS @local = 2;
const uint SHADOW_REPRESENTATIONS @local = SHADOW_BASE_PARTS + SHADOW_REDUCED_PARTS;

$assert PosedTraceKey::size == 48;

struct AnimatedLodHistoryFixture @local {
    AssetStore assets;
    Scene scene;
    PartsFixture source;
    Node* node;
    GeometryId alternative;
    LodSelection selection;
    MeshCandidate[2 * ANIMATED_HISTORY_PARTS] candidates;
    ViewHistory first;
    Allocator history_allocator;
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
    @pool() {
        AnimatedLodDesc desc = animated_crowd_fixtures::parts_lod_desc(&fixture.assets, fixture.source.mixed);
        foreach (&part : desc.parts[ANIMATED_HISTORY_PARTS..]) {
            if (part.skin.skeleton.generation) part.skin.skeleton = fixture.source.identical_skin;
        }
        desc.parts[ANIMATED_HISTORY_PARTS + 1].draw.geometry = fixture.alternative;
        if (different_local) {
            desc.parts[ANIMATED_HISTORY_PARTS + 2].draw.local = matrix::IDENTITY4.translate({ 1, 0, 0 });
        }
        desc.has_bounds_override = !instanced;
        desc.local_bounds = animated_crowd_fixtures::PARTS_POSE_BOUNDS;
        model::attach_animated_lod(
            assets: &fixture.assets,
            scene: &fixture.scene,
            owner: fixture.node,
            desc: desc,
        )!!;
    };
    fixture.scene.update_world();
    bind_animated_history_candidates(fixture);
}

fn void destroy_animated_history_fixture(AnimatedLodHistoryFixture* fixture) @local {
    free_view_history(fixture.history_allocator, &fixture.first);
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

fn void test_animated_lod_addresses_grow_and_reset_without_stale_entries() @test {
    AnimatedLodAddresses addresses = create_animated_lod_addresses(mem);
    defer destroy_animated_lod_addresses(&addresses);
    for (uint frame = 0; frame < 2; frame++) {
        for (uint part = 0; part < 100; part++) {
            AnimatedLodKey key = { .scene = 1, .identity = 2, .part = part, .stream = MORPHS };
            assert(@catch(addresses.get(key)) == NOT_FOUND);
            addresses.set(key, (gpu::GpuAddress)(part + 1));
        }
        for (uint part = 0; part < 100; part++) {
            AnimatedLodKey key = { .scene = 1, .identity = 2, .part = part, .stream = MORPHS };
            assert(addresses.get(key)!! == (gpu::GpuAddress)(part + 1));
            key.stream = PARTS;
            assert(@catch(addresses.get(key)) == NOT_FOUND);
        }
        addresses.reset();
    }
}

fn AssetStore animated_lod_render_store() @local {
    return asset::create_asset_store(mem, {
        .max_geometries = 8, .max_textures = 8, .max_materials = 4, .max_samplers = 8,
        .max_models = 8, .max_skeletons = 8, .max_clips = 8,
    });
}

fn AnimatedLodDesc shadow_lod_desc(AssetStore* assets, ModelId model_id) @local {
    AnimatedLodDesc desc = animated_crowd_fixtures::parts_lod_desc(assets, model_id);
    desc.levels[1].part_count = SHADOW_REDUCED_PARTS;
    desc.parts[SHADOW_BASE_PARTS + 1] = desc.parts[2];
    desc.parts = desc.parts[:SHADOW_REPRESENTATIONS];
    return desc;
}

fn void test_animated_lod_shadow_ordinary_uses_selected_parts_and_their_parity() @test {
    @pool() {
        AssetStore assets = animated_lod_render_store();
        defer asset::destroy_asset_store(&assets);
        PartsFixture fixture = animated_crowd_fixtures::add_parts_fixture(&assets)!!;
        Scene scene = scene::create_scene(mem, { .max_nodes = 64 });
        defer scene::destroy_scene(&scene);
        Node* owner = model::instantiate(&assets, &scene, fixture.mixed)!!;
        AnimatedLodDesc desc = shadow_lod_desc(&assets, fixture.mixed);
        desc.parts[SHADOW_BASE_PARTS + 1].draw.local = matrix::IDENTITY4.scale({ -1, 1, 1 });
        model::attach_animated_lod(
            assets: &assets,
            scene: &scene,
            owner: owner,
            desc: desc,
        )!!;
        Node* unrelated = scene.add_mesh(
            geometry: fixture.geometries[1],
            material: fixture.material,
            parent: owner,
            name: "unrelated_shadow_child",
        )!!;
        unrelated.local.position.x = 30;
        scene.update_world();
        LodGroup* group = scene.get(owner, LodGroup);
        LodSelection[1] selections = {
            {
                .scene = &scene,
                .scene_identity = scene.identity,
                .node = owner,
                .state = group.state,
                .level = 1,
                .world_bounds = spatial::lod_world_bounds(
                    assets: &assets,
                    node: owner,
                    group: group,
                    scene: &scene,
                ),
            },
        };
        ExtractCounts counts;
        MeshCandidate[] candidates = render::extract_shadow_candidates(
            allocator: tmem,
            scene: &scene,
            assets: &assets,
            fade_origin: {},
            counts: &counts,
            lod: selections[..],
        );
        assert(counts.dangling == 0 && counts.visible == 3 && candidates.len == 3);
        uint imported;
        uint unrelated_count;
        uint[SHADOW_REDUCED_PARTS] selected;
        ModelInstance* instance = scene.get(owner, ModelInstance);
        foreach (candidate : candidates) {
            if (candidate.node == unrelated) {
                assert(candidate.lod == null && candidate.animated_lod == null);
                unrelated_count++;
            } else if (candidate.node == owner) {
                assert(candidate.lod == &selections[0] && candidate.lod_level == 1);
                assert(candidate.lod_part >= SHADOW_BASE_PARTS && candidate.lod_part < SHADOW_REPRESENTATIONS);
                uint part = candidate.lod_part - SHADOW_BASE_PARTS;
                selected[part]++;
                assert(candidate.animated_lod.mesh_index == (part == 0 ? 0u : 2u));
                assert(candidate.animated_lod.skinned == (part == 0));
                assert(candidate.model_instance == instance && candidate.crowd == null);
                assert(candidate.source_node == instance.present_node(part == 0 ? 2u : 5u));
                assert(candidate.instance_count == 1 && candidate.mirrored == (part == 1));
                assert(c3d::same_id(candidate.geometry, fixture.geometries[part == 0 ? 0u : 2u]));
            } else {
                imported++;
            }
        }
        assert(imported == 0 && unrelated_count == 1);
        foreach (count : selected) assert(count == 1);
    };
}

fn void test_animated_lod_shadow_crowd_keeps_parent_representations_and_source_parities() @test {
    @pool() {
        AssetStore assets = animated_lod_render_store();
        defer asset::destroy_asset_store(&assets);
        PartsFixture fixture = animated_crowd_fixtures::add_parts_fixture(&assets)!!;
        Scene scene = scene::create_scene(mem, { .max_nodes = 64 });
        defer scene::destroy_scene(&scene);
        CrowdInstance[3] instances;
        for (uint source = 0; source < 3; source++) {
            instances[source] = {
                .placement = maths::TRANSFORM_IDENTITY,
                .pose = { .clip = fixture.posing, .time = 0.25f * (float)source, .speed = 0, .loop = false },
                .color = { 1, 1, 1, 1 },
            };
            instances[source].placement.position.x = 30 * (float)source;
        }
        instances[1].placement.scale.x = -1;
        Node* owner = model::add_crowd(
            assets: &assets,
            scene: &scene,
            model: fixture.mixed,
            capacity: 3,
            pose_bounds: animated_crowd_fixtures::PARTS_POSE_BOUNDS,
            instances: instances[..],
        )!!;
        model::attach_animated_lod(
            assets: &assets,
            scene: &scene,
            owner: owner,
            desc: shadow_lod_desc(&assets, fixture.mixed),
        )!!;
        Node* unrelated = scene.add_mesh(
            geometry: fixture.geometries[1],
            material: fixture.material,
            parent: owner,
            name: "unrelated_crowd_shadow_child",
        )!!;
        unrelated.local.position.x = 90;
        scene.update_world();
        LodGroup* group = scene.get(owner, LodGroup);
        uint[SHADOW_REPRESENTATIONS] unmirrored;
        unmirrored[..] = 2;
        LodSelection[1] selections = {
            {
                .scene = &scene,
                .scene_identity = scene.identity,
                .node = owner,
                .state = group.state,
                .part_unmirrored = unmirrored[..],
                .world_bounds = spatial::lod_world_bounds(
                    assets: &assets,
                    node: owner,
                    group: group,
                    scene: &scene,
                ),
            },
        };
        ExtractCounts counts;
        MeshCandidate[] candidates = render::extract_shadow_candidates(
            allocator: tmem,
            scene: &scene,
            assets: &assets,
            fade_origin: {},
            counts: &counts,
            lod: selections[..],
        );
        assert(counts.dangling == 0 && counts.visible == 15 && candidates.len == 15);
        AnimatedCrowd* crowd = scene.get(owner, AnimatedCrowd);
        uint unrelated_count;
        uint[SHADOW_REPRESENTATIONS] parities;
        foreach (candidate : candidates) {
            if (candidate.node == unrelated) {
                assert(candidate.lod == null && candidate.batch == null);
                unrelated_count++;
            } else {
                assert(candidate.node == owner && candidate.lod == &selections[0]);
                assert(candidate.batch == null && candidate.crowd == crowd);
                assert(candidate.lod_part < SHADOW_REPRESENTATIONS);
                assert(candidate.lod_level == (candidate.lod_part < SHADOW_BASE_PARTS ? 0u : 1u));
                assert(candidate.instance_count == (candidate.mirrored ? 1u : 2u));
                assert(c3d::same_id(candidate.geometry, group.state.desc.parts[candidate.lod_part].geometry));
                parities[candidate.lod_part] |= candidate.mirrored ? 2u : 1u;
                foreach (part : crowd.parts) assert(!c3d::same_id(candidate.node.id, part.batch));
            }
        }
        assert(unrelated_count == 1);
        foreach (parity : parities) assert(parity == 3);
    };
}

fn CrowdInstance[3] trace_lod_instances(ClipId clip) @local {
    CrowdInstance[3] instances;
    for (uint index = 0; index < 3; index++) {
        instances[index] = {
            .placement = maths::TRANSFORM_IDENTITY,
            .pose = { .clip = clip, .time = 0.25f * (float)(index + 1), .speed = 1, .loop = true },
            .color = { 1, 1, 1, 1 },
        };
        instances[index].placement.position.x = 30 * (float)index;
    }
    instances[1].placement.scale = { -1, 2, 1 };
    instances[2].placement.scale = { 2, 1, -1 };
    return instances;
}

fn Node* trace_lod_crowd(
    AssetStore* assets,
    Scene* scene,
    PartsFixture* fixture,
    CrowdInstance[] instances,
) @local {
    Node* owner = model::add_crowd(
        assets: assets,
        scene: scene,
        model: fixture.mixed,
        capacity: 3,
        pose_bounds: animated_crowd_fixtures::PARTS_POSE_BOUNDS,
        instances: instances,
    )!!;
    owner.local.position = animated_crowd_fixtures::PARTS_ROOT_POSITION;
    model::attach_animated_lod(
        assets: assets,
        scene: scene,
        owner: owner,
        desc: animated_crowd_fixtures::parts_lod_desc(assets, fixture.mixed, permuted: true),
    )!!;
    scene.update_world();
    return owner;
}

fn void test_traced_animated_lod_respects_source_flags_and_base_signatures() @test {
    @pool() {
        AssetStore assets = animated_lod_render_store();
        defer asset::destroy_asset_store(&assets);
        PartsFixture fixture = animated_crowd_fixtures::add_parts_fixture(&assets)!!;
        Scene scene = scene::create_scene(mem, { .max_nodes = 64 });
        defer scene::destroy_scene(&scene);
        Node* owner = model::instantiate(&assets, &scene, fixture.mixed)!!;
        owner.local.position = animated_crowd_fixtures::PARTS_ROOT_POSITION;
        Animator* animator = anim::add_animator(&scene, owner);
        AnimationActionId action = animator.play(&assets, fixture.posing)!!;
        Action* played = animator.try_action(action)!!;
        played.loop = false;
        animator.action(action).time = 1;
        anim::update(&assets, &scene, 0);
        GeometryId coarse = assets.add_geometry(&assets.geometry(fixture.geometries[1]).data)!!;
        AnimatedLodDesc desc = animated_crowd_fixtures::parts_lod_desc(&assets, fixture.mixed, permuted: true);
        desc.parts[6].draw.geometry = coarse;
        model::attach_animated_lod(
            assets: &assets,
            scene: &scene,
            owner: owner,
            desc: desc,
        )!!;
        scene.update_world();
        Renderer renderer = { .assets = &assets };
        LodGroupState* initial_state = scene.get(owner, LodGroup).state;
        assert(!initial_state.effects.trace);
        assert(render::collect_trace_instances(tmem, &scene, &assets).records.len == 0);
        initial_state.effects.trace = true;
        TraceCollection first = render::collect_trace_instances(tmem, &scene, &assets);
        assert(first.records.len == 5 && first.dangling == 0);
        uint[5] seen;
        char[][] signatures = alloc::new_array(tmem, char[], 5);
        foreach (index, &record : first.records) {
            TracePoseSource* source = &first.poses[index];
            assert(c3d::same_id(record.entity, owner.id) && record.instance_index == 0);
            assert(record.part_index < 5 && c3d::same_id(record.geometry, fixture.geometries[record.part_index]));
            seen[record.part_index]++;
            assert(record.lod_identity == scene.get(owner, LodGroup).state.identity);
            PosedTraceKey key = render::trace_pose_key(scene.identity, source, record);
            assert(key.logical_part == record.part_index && key.lod_identity == record.lod_identity);
            assert(key.source_identity == 1 && key.slot_generation == 1);
            if (record.part_index == 1) {
                assert(source.kind == TracePose.REST && render::pose_input_bytes(source, &assets) == 0);
                Vec3 first_vertex = maths::transform_point(render::trace_instance_world(record), { 1, 0, 0 });
                assert(first_vertex == (Vec3){ 16, 1, -2 });
            } else {
                assert(source.kind == TracePose.ANIMATED_LOD);
                signatures[record.part_index] = render::pose_inputs(&renderer, source, record);
                if (record.part_index == 0 || record.part_index == 4) {
                    Mat4 identity = matrix::IDENTITY4;
                    assert(record.local == identity);
                    assert(signatures[record.part_index].len == 2 * Mat4f::size);
                } else {
                    assert(signatures[record.part_index].len == MorphWeightsGpu::size);
                }
            }
        }
        foreach (count : seen) assert(count == 1);
        assert(c3d::same_id(first.records[2].geometry, first.records[3].geometry));
        PosedTraceKey first_morph = render::trace_pose_key(scene.identity, &first.poses[2], &first.records[2]);
        PosedTraceKey second_morph = render::trace_pose_key(scene.identity, &first.poses[3], &first.records[3]);
        assert(!(first_morph == second_morph));
        assert(mem::equals(signatures[2].ptr, signatures[3].ptr, MorphWeightsGpu::size));
        ModelInstance* instance = scene.get(owner, ModelInstance);
        scene.get(instance.present_node(6), Mesh).trace = false;
        TraceCollection disabled_part = render::collect_trace_instances(tmem, &scene, &assets);
        assert(disabled_part.records.len == 4);
        foreach (record : disabled_part.records) assert(record.part_index != 3);
        scene.get(owner, LodGroup).state.effects.trace = false;
        TraceCollection disabled_group = render::collect_trace_instances(tmem, &scene, &assets);
        assert(disabled_group.records.len == 0);
        scene.get(owner, LodGroup).state.effects.trace = true;
        scene.remove(instance.present_node(0));
        TraceCollection missing_joint = render::collect_trace_instances(tmem, &scene, &assets);
        assert(missing_joint.records.len == 0 && missing_joint.dangling == 1);
    };
}

fn void test_traced_animated_lod_key_fields_are_complete() @test {
    PosedTraceKey base = {
        .scene = 7,
        .node = { .index = 3, .generation = 2 },
        .instance = 1,
        .lod_identity = 11,
        .source_identity = 13,
        .slot_generation = 5,
        .logical_part = 2,
    };
    RetireList retire;
    retire.init(mem);
    defer retire.free();
    PosedTraceTable table = render::create_posed_trace_table(mem, 9);
    defer render::free_posed_trace_storage(&table);
    table.begin_epoch(1);
    assert(table.claim(base, 0, &retire)!! == 0);
    for (uint field = 0; field < 8; field++) {
        PosedTraceKey changed = base;
        switch (field) {
            case 0: changed.scene++;
            case 1: changed.node.index++;
            case 2: changed.node.generation++;
            case 3: changed.instance++;
            case 4: changed.lod_identity++;
            case 5: changed.source_identity++;
            case 6: changed.slot_generation++;
            case 7: changed.logical_part++;
        }
        assert(!(base == changed));
        assert(table.claim(changed, 0, &retire)!! == field + 1);
        assert(table.lookup.get(changed)!! == field + 1);
    }
    assert(table.claim(base, 0, &retire)!! == 0 && retire.len() == 0);
}

fn void test_traced_animated_lod_crowd_uses_logical_pose_order_and_fresh_keys() @test {
    @pool() {
        AssetStore assets = animated_lod_render_store();
        defer asset::destroy_asset_store(&assets);
        PartsFixture fixture = animated_crowd_fixtures::add_parts_fixture(&assets)!!;
        Scene scene = scene::create_scene(mem, { .max_nodes = 64 });
        defer scene::destroy_scene(&scene);
        CrowdInstance[3] instances = trace_lod_instances(fixture.posing);
        Node* owner = trace_lod_crowd(
            assets: &assets,
            scene: &scene,
            fixture: &fixture,
            instances: instances[..],
        );
        AnimatedCrowd* crowd = scene.get(owner, AnimatedCrowd);
        LodGroupState* state = scene.get(owner, LodGroup).state;
        assert(!crowd.trace && !state.effects.trace);
        TraceCollection untraced = render::collect_trace_instances(tmem, &scene, &assets);
        assert(untraced.records.len == 0);
        state.effects.trace = true;
        Renderer renderer = { .assets = &assets };
        TraceCollection first = render::collect_trace_instances(tmem, &scene, &assets);
        assert(first.records.len == 15 && first.dangling == 0);
        uint[15] seen;
        PosedTraceKey[15] keys;
        foreach (index, &record : first.records) {
            TracePoseSource* source = &first.poses[index];
            uint logical = 5 * record.instance_index + record.part_index;
            seen[logical]++;
            keys[logical] = render::trace_pose_key(scene.identity, source, record);
            assert(c3d::same_id(record.entity, owner.id) && record.lod_identity == state.identity);
            assert(keys[logical].source_identity == crowd.playback.identity);
            assert(keys[logical].slot_generation == crowd.playback.slots[record.instance_index].generation);
            if (record.part_index == 1) {
                assert(source.kind == TracePose.REST);
            } else {
                assert(source.kind == TracePose.ANIMATED_LOD);
                char[] inputs = render::pose_inputs(&renderer, source, record);
                if (record.part_index == 0 || record.part_index == 4) {
                    usz first_matrix = (usz)record.instance_index * crowd.joint_count;
                    assert(inputs.len == (usz)crowd.joint_count * Mat4f::size);
                    assert(mem::equals(inputs.ptr, (char*)&crowd.palettes[first_matrix], inputs.len));
                    assert(record.local == crowd.placements[record.instance_index].to_mat4());
                }
            }
        }
        foreach (count : seen) assert(count == 1);
        foreach (index, key : keys) {
            foreach (other : keys[:index]) assert(!(key == other));
        }
        ulong identity = state.identity;
        model::set_crowd(
            assets: &assets,
            scene: &scene,
            node: owner,
            instances: instances[:1],
        )!!;
        TraceCollection shrunk = render::collect_trace_instances(tmem, &scene, &assets);
        assert(shrunk.records.len == 5);
        model::set_crowd(
            assets: &assets,
            scene: &scene,
            node: owner,
            instances: instances[..],
        )!!;
        TraceCollection regrown = render::collect_trace_instances(tmem, &scene, &assets);
        assert(regrown.records.len == 15 && state.identity == identity);
        foreach (index, &record : regrown.records) {
            uint logical = 5 * record.instance_index + record.part_index;
            PosedTraceKey fresh = render::trace_pose_key(scene.identity, &regrown.poses[index], record);
            assert(!(fresh == keys[logical]));
            assert(fresh.logical_part == keys[logical].logical_part && fresh.instance == keys[logical].instance);
        }
    };
}
