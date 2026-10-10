module c3d::test::traced_animated_lod;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::maths;
import c3d::model;
import c3d::render @public;
import c3d::scene;
import c3d::shader;
import c3d::test::animated_crowd_fixtures;

$assert PosedTraceKey::size == 48;

fn AssetStore trace_lod_store() @local {
    return asset::create_asset_store(mem, {
        .max_geometries = 8, .max_textures = 8, .max_materials = 4, .max_samplers = 8,
        .max_models = 8, .max_skeletons = 8, .max_clips = 8,
    });
}

fn AnimatedLodDesc trace_lod_desc(AssetStore* assets, ModelId model_id) @local {
    ModelTemplate* template = &assets.model(model_id).data;
    uint count = (uint)template.meshes.len;
    LodLevel[] levels = alloc::new_array(tmem, LodLevel, 2);
    levels[0] = { .first_part = 0, .part_count = count, .min_screen_size = 0.2f };
    levels[1] = { .first_part = count, .part_count = count, .min_screen_size = 0 };
    AnimatedLodPart[] parts = alloc::new_array(tmem, AnimatedLodPart, 2 * count);
    for (uint level = 0; level < 2; level++) {
        foreach (uint index, mesh : template.meshes) {
            ModelSkin skin;
            foreach (candidate : template.skins) {
                if (candidate.mesh_node == mesh.node) skin = candidate;
            }
            parts[level * count + index] = {
                .draw = { .geometry = mesh.geometry, .material = mesh.material, .local = matrix::IDENTITY4 },
                .mesh_index = index,
                .skin = skin,
                .default_morph_weights = mesh.default_morph_weights,
            };
        }
    }
    AnimatedLodPart first = parts[0];
    parts[0] = parts[count - 1];
    parts[count - 1] = first;
    return { .levels = levels, .parts = parts };
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
    Node* owner = model::create_crowd(
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
        desc: trace_lod_desc(assets, fixture.mixed),
    )!!;
    scene.update_world();
    return owner;
}

fn void test_traced_animated_lod_respects_source_flags_and_base_signatures() @test {
    @pool() {
        AssetStore assets = trace_lod_store();
        defer asset::destroy_asset_store(&assets);
        PartsFixture fixture = animated_crowd_fixtures::add_parts_fixture(&assets)!!;
        Scene scene = scene::create_scene(mem, { .max_nodes = 64 });
        defer scene::destroy_scene(&scene);
        Node* owner = model::instantiate(&assets, &scene, fixture.mixed)!!;
        owner.local.position = animated_crowd_fixtures::PARTS_ROOT_POSITION;
        Animator* animator = anim::add_animator(&scene, owner);
        AnimationActionId action = animator.play(&assets, fixture.posing, { .loop = false })!!;
        animator.action(action).time = 1;
        anim::update(&assets, &scene, 0);
        GeometryId coarse = assets.add_geometry(&assets.geometry(fixture.geometries[1]).data)!!;
        AnimatedLodDesc desc = trace_lod_desc(&assets, fixture.mixed);
        desc.parts[6].draw.geometry = coarse;
        model::attach_animated_lod(
            assets: &assets,
            scene: &scene,
            owner: owner,
            desc: desc,
        )!!;
        scene.update_world();
        Renderer renderer = { .assets = &assets };
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
                    assert(record.local == matrix::IDENTITY4);
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
        assets.geometry(coarse).data.bounds.max.x += 1;
        assets.mark_geometry_dirty(coarse);
        TraceCollection after_coarse = render::collect_trace_instances(tmem, &scene, &assets);
        assert(after_coarse.records.len == first.records.len);
        assert(mem::equals(first.records.ptr, after_coarse.records.ptr, first.records.len * TraceInstance::size));
        foreach (index, &record : after_coarse.records) {
            if (after_coarse.poses[index].kind == TracePose.ANIMATED_LOD) {
                char[] inputs = render::pose_inputs(&renderer, &after_coarse.poses[index], record);
                char[] before = signatures[record.part_index];
                assert(inputs.len == before.len && mem::equals(inputs.ptr, before.ptr, inputs.len));
            }
        }
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
        AssetStore assets = trace_lod_store();
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
                    assert(mem::equals(inputs.ptr, &crowd.palettes[first_matrix], inputs.len));
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
        AnimatedLodDesc next = trace_lod_desc(&assets, fixture.mixed);
        model::replace_animated_lod(
            assets: &assets,
            scene: &scene,
            owner: owner,
            desc: next,
        )!!;
        TraceCollection replacement = render::collect_trace_instances(tmem, &scene, &assets);
        assert(replacement.records.len == 15);
        assert(replacement.records[0].lod_identity != identity);
    };
}

fn void test_traced_animated_lod_capacity_prefix_and_abort_keep_distinct_slots() @test {
    @pool() {
        AssetStore assets = trace_lod_store();
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
        scene.get(owner, LodGroup).state.effects.trace = true;
        TraceCollection collection = render::collect_trace_instances(tmem, &scene, &assets);
        Renderer renderer = { .assets = &assets };
        RetireList retire;
        retire.init(mem);
        defer retire.free();
        PosedTraceTable table = render::create_posed_trace_table(mem, 2);
        defer render::free_posed_trace_storage(&table);
        table.begin_epoch(1);
        uint admitted;
        uint overflow;
        foreach (index, &record : collection.records) {
            TracePoseSource* source = &collection.poses[index];
            if (source.kind == TracePose.REST) continue;
            PosedTraceKey key = render::trace_pose_key(scene.identity, source, record);
            if (try slot_index = table.claim(key, 0, &retire)) {
                assert(slot_index == admitted);
                PosedTraceRes* slot = &table.slots[slot_index];
                char[] inputs = render::pose_inputs(&renderer, source, record);
                slot.pose = alloc::new_array(mem, char, (sz)inputs.len);
                assert(slot.update_pose(inputs) && slot.pose_serial == 1);
                assert(!slot.update_pose(inputs));
                slot.built_revision = 1;
                slot.refit_serial = slot.pose_serial;
                slot.blas_serial = slot.pose_serial;
                render::mark_posed_pending(&table, slot_index);
                admitted++;
            } else {
                assert(@catch(table.claim(key, 0, &retire)) == c3d::CAPACITY_EXCEEDED);
                overflow++;
            }
        }
        assert(admitted == 2 && overflow == 10);
        assert(!(table.slots[0].key == table.slots[1].key));
        render::discard_posed_trace(&table);
        assert(table.pending.len() == 0 && table.epoch_frame == 0);
        for (uint slot_index = 0; slot_index < 2; slot_index++) {
            PosedTraceRes* slot = &table.slots[slot_index];
            assert(slot.built_revision == 0 && !slot.pose_valid && !slot.pending);
            assert(slot.refit_serial == 0 && slot.blas_serial == 0);
            char[] inputs = render::pose_inputs(&renderer, &collection.poses[slot_index], &collection.records[slot_index]);
            assert(slot.update_pose(inputs) && slot.pose_serial == 2);
            assert(!slot.update_pose(inputs));
        }
        assert(retire.len() == 0);
    };
}
