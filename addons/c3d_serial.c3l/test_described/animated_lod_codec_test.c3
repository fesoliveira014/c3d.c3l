module c3d::serial::test_described;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::asset::gltf;
import c3d::ecs;
import c3d::describe;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::model;
import c3d::scene;
import c3d::serial @public;
import std::math;

fn AnimatedLodDesc codec_animated_lod_desc(AssetStore* assets, ModelId model_id) @local {
    ModelTemplate* template = &assets.model(model_id).data;
    uint count = (uint)template.meshes.len;
    LodLevel[] levels = alloc::new_array(tmem, LodLevel, 2);
    levels[0] = { .part_count = count, .min_screen_size = 0.25f };
    levels[1] = { .first_part = count, .part_count = count };
    AnimatedLodPart[] parts = alloc::new_array(tmem, AnimatedLodPart, (sz)count * 2);
    for (uint level = 0; level < 2; level++) {
        foreach (uint index, mesh : template.meshes) {
            ModelSkin skin;
            foreach (candidate : template.skins) if (candidate.mesh_node == mesh.node) skin = candidate;
            parts[level * count + index] = {
                .draw = { .geometry = mesh.geometry, .material = mesh.material, .local = matrix::IDENTITY4 },
                .mesh_index = index,
                .skin = skin,
                .default_morph_weights = mesh.default_morph_weights,
            };
        }
    }
    return { .levels = levels, .parts = parts };
}

fn void assert_codec_animated_lod_owned(
    LodGroupState* source,
    LodGroupState* restored,
    Node* owner,
) @local {
    assert(restored.animated && c3d::same_id(restored.animated.source_owner, owner.id));
    assert(c3d::same_id(restored.animated.source_model, source.animated.source_model));
    assert(restored.identity != source.identity && restored.descriptor_revision == 1);
    assert(restored.desc.levels.len == source.desc.levels.len && restored.desc.parts.len == source.desc.parts.len);
    assert(restored.desc.parts.ptr != source.desc.parts.ptr && restored.animated.parts.ptr != source.animated.parts.ptr);
    assert(restored.animated.joint_nodes.ptr != source.animated.joint_nodes.ptr);
    assert(restored.animated.joint_nodes == source.animated.joint_nodes);
    assert(restored.animated.defaults == source.animated.defaults);
    foreach (index, part : restored.animated.parts) {
        AnimatedLodPartBinding expected = source.animated.parts[index];
        assert(part.mesh_index == expected.mesh_index && part.template_node == expected.template_node);
        assert(part.skinned == expected.skinned && c3d::same_id(part.skeleton, expected.skeleton));
        assert(part.weight_count == expected.weight_count && part.weight_offset == expected.weight_offset);
        assert(c3d::same_id(restored.desc.parts[index].geometry, source.desc.parts[index].geometry));
        assert(c3d::same_id(restored.desc.parts[index].material, source.desc.parts[index].material));
        assert(mem::equals(&restored.desc.parts[index].local, &source.desc.parts[index].local, Mat4::size));
    }
    assert(!restored.bounds_revision && !restored.aggregate_revision);
}

fn void test_animated_lod_codec_ordinary_rebuilds_binding_and_restarts_animation() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture, 32);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;
        ModelId model_id = gltf::load_model(&fixture.assets, skin_fixture_path())!!;
        Node* source = model::instantiate(&fixture.assets, &fixture.source, model_id)!!;
        ModelInstance* instance = fixture.source.get(source, ModelInstance);
        AnimatedLodDesc desc = codec_animated_lod_desc(&fixture.assets, model_id);
        instance.base_morph_weights[0][0] = 0.25f;
        foreach (&part : desc.parts) part.default_morph_weights = instance.base_morph_weights[part.mesh_index];
        desc.has_bounds_override = true;
        desc.local_bounds = { .min = { -2, -3, -4 }, .max = { 5, 6, 7 } };
        model::attach_animated_lod(
            assets: &fixture.assets,
            scene: &fixture.source,
            owner: source,
            desc: desc,
        )!!;
        LodEffects effects = { .cast_shadow = false, .receive_shadow = true, .trace = true };
        fixture.source.set_lod_effects(source, effects);
        Animator* animator = anim::add_animator(&fixture.source, source);
        AnimationActionId action = animator.play(&fixture.assets, instance.clips[0])!!;
        animator.action(action).time = 0.5f;
        anim::update(&fixture.assets, &fixture.source, 0);
        LodGroupState* original = fixture.source.get(source, LodGroup).state;
        ulong identity = original.identity;
        uint revision = original.revision;
        char[] bytes = serial::write_subtree(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: source,
        )!!;
        String text = serial::write_subtree_text(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: source,
        )!!;
        assert(animator.action(action).time == 0.5f && original.identity == identity && original.revision == revision);
        for (uint encoding = 0; encoding < 2; encoding++) {
            Node* restored = encoding == 0
              ? serial::read_subtree(&fixture.destination, &fixture.assets, bytes)!!
              : serial::read_subtree_text(&fixture.destination, &fixture.assets, text)!!;
            LodGroupState* loaded = fixture.destination.get(restored, LodGroup).state;
            assert_codec_animated_lod_owned(original, loaded, restored);
            assert(loaded.mode == SINGLE && loaded.count == 1 && !loaded.transforms.len);
            assert(loaded.desc.has_bounds_override && loaded.desc.local_bounds.min == desc.local_bounds.min);
            assert(loaded.desc.local_bounds.max == desc.local_bounds.max);
            assert(!loaded.effects.cast_shadow && loaded.effects.receive_shadow && loaded.effects.trace);
            Animator* playback = fixture.destination.get(restored, Animator);
            assert(playback.action_count == 1 && playback.actions.get(playback.order[0]).time == 0);
            model::sync_animated_lod(&fixture.assets, &fixture.destination, restored)!!;
            assert(bytes == serial::write_subtree(
                allocator: tmem,
                scene: &fixture.destination,
                assets: &fixture.assets,
                root: restored,
            )!!);
            assert(text == serial::write_subtree_text(
                allocator: tmem,
                scene: &fixture.destination,
                assets: &fixture.assets,
                root: restored,
            )!!);
            fixture.destination.remove(restored);
        }
    };
}

fn void test_animated_lod_codec_crowd_preserves_pending_owner_and_prepares_later() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture, 32);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;
        ModelId model_id = gltf::load_model(&fixture.assets, skin_fixture_path())!!;
        CrowdInstance[2] instances = {
            { .placement = maths::TRANSFORM_IDENTITY, .pose = { .time = 0.125f, .speed = -0.5f, .loop = true },
                .color = { 0.2f, 0.4f, 0.6f, 1 } },
            { .placement = maths::TRANSFORM_IDENTITY, .pose = { .time = 0.25f, .speed = 1, .loop = false },
                .color = { 0.8f, 0.6f, 0.4f, 1 } },
        };
        instances[0].placement.scale = { -1, 2, 0.5f };
        instances[1].placement.position = { 3, 1, -2 };
        foreach (&instance : instances) instance.pose.clip = fixture.assets.model(model_id).data.clips[0];
        Node* source = fixture.source.add_node(name: "pending_animated_lod")!!;
        model::attach_crowd(
            assets: &fixture.assets,
            scene: &fixture.source,
            node: source,
            model: model_id,
            capacity: 4,
            pose_bounds: { .min = { -4, -4, -4 }, .max = { 4, 4, 4 } },
            instances: instances[..],
            trace: false,
            actions_per_instance: 6,
            event_capacity: 0,
        )!!;
        model::attach_animated_lod(
            assets: &fixture.assets,
            scene: &fixture.source,
            owner: source,
            desc: codec_animated_lod_desc(&fixture.assets, model_id),
        )!!;
        LodEffects effects = { .cast_shadow = true, .receive_shadow = false, .trace = true };
        fixture.source.set_lod_effects(source, effects);
        LodGroupState* original = fixture.source.get(source, LodGroup).state;
        for (uint prepared = 0; prepared < 2; prepared++) {
            if (prepared) {
                model::prepare_crowd(&fixture.assets, &fixture.source, source)!!;
                anim::crowd_update(&fixture.assets, &fixture.source, 0.25f);
                model::sync_animated_lod(&fixture.assets, &fixture.source, source)!!;
            }
            char[] bytes = serial::write_subtree(
                allocator: tmem,
                scene: &fixture.source,
                assets: &fixture.assets,
                root: source,
            )!!;
            String text = serial::write_subtree_text(
                allocator: tmem,
                scene: &fixture.source,
                assets: &fixture.assets,
                root: source,
            )!!;
            for (uint encoding = 0; encoding < 2; encoding++) {
                Node* restored = encoding == 0
                  ? serial::read_subtree(&fixture.destination, &fixture.assets, bytes)!!
                  : serial::read_subtree_text(&fixture.destination, &fixture.assets, text)!!;
                AnimatedCrowd* crowd = fixture.destination.get(restored, AnimatedCrowd);
                LodGroupState* loaded = fixture.destination.get(restored, LodGroup).state;
                assert_codec_animated_lod_owned(original, loaded, restored);
                assert(!crowd.is_prepared() && restored.first_child == null);
                assert(crowd.count == 2 && crowd.placements.len == 4 && crowd.actions_per_instance == 6);
                assert(crowd.event_capacity == 0 && crowd.placements[0].scale == instances[0].placement.scale);
                assert(crowd.start_times[0] == 0.125f && crowd.start_times[1] == 0.25f);
                assert(loaded.mode == INSTANCED && loaded.count == 0 && loaded.slot_generations.len == 4);
                assert(loaded.transforms.ptr == crowd.placements.ptr && loaded.colors.ptr == crowd.colors.ptr);
                assert(loaded.desc.has_bounds_override && loaded.desc.local_bounds.min == crowd.pose_bounds.min);
                assert(loaded.effects.cast_shadow && !loaded.effects.receive_shadow && loaded.effects.trace);
                assert(bytes == serial::write_subtree(
                    allocator: tmem,
                    scene: &fixture.destination,
                    assets: &fixture.assets,
                    root: restored,
                )!!);
                model::prepare_crowd(&fixture.assets, &fixture.destination, restored)!!;
                model::sync_animated_lod(&fixture.assets, &fixture.destination, restored)!!;
                assert(loaded.count == 2 && loaded.transforms.ptr == crowd.placements.ptr);
                assert(loaded.identity != original.identity && loaded.descriptor_revision == 1);
                assert(crowd.playback.slots[0].actions.get(crowd.playback.slots[0].base_action).time == 0.125f);
                assert(crowd.playback.slots[1].actions.get(crowd.playback.slots[1].base_action).time == 0.25f);
                fixture.destination.remove(restored);
            }
        }
    };
}

fn void test_animated_lod_codec_attachment_fault_keeps_pending_crowd_and_retries() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture, 32);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;
        ModelId model_id = gltf::load_model(&fixture.assets, skin_fixture_path())!!;
        Node* owner = fixture.destination.add_node(name: "pending")!!;
        model::attach_crowd(
            assets: &fixture.assets,
            scene: &fixture.destination,
            node: owner,
            model: model_id,
            capacity: 2,
            pose_bounds: { .min = { -2, -2, -2 }, .max = { 2, 2, 2 } },
        )!!;
        AnimatedCrowd* crowd = fixture.destination.get(owner, AnimatedCrowd);
        Transform* placements = crowd.placements.ptr;
        LodAuthoring source = {
            .animated = true,
            .source_owner = owner.id,
            .animated_desc = codec_animated_lod_desc(&fixture.assets, model_id),
            .effects = { .cast_shadow = true, .receive_shadow = true },
        };
        ReadContext context = { .scene = &fixture.destination, .assets = &fixture.assets, .node = owner };
        CodecEntry* entry = &serial::codecs[ecs::assigned_slot(LodGroup)!!];
        source.animated_desc.parts[1].mesh_index = uint::max;
        assert(@catch(entry.described.codec.attach(&source, &context)) == c3d::INVALID_ARGUMENT);
        assert(!fixture.destination.has(owner, LodGroup) && crowd.placements.ptr == placements && !crowd.is_prepared());
        source.animated_desc.parts[1].mesh_index = 0;
        GeometryId geometry = source.animated_desc.parts[1].draw.geometry;
        source.animated_desc.parts[1].draw.geometry = { .index = uint::max, .generation = 1 };
        assert(@catch(entry.described.codec.attach(&source, &context)) == c3d::INVALID_ID);
        assert(!fixture.destination.has(owner, LodGroup) && crowd.placements.ptr == placements);
        source.animated_desc.parts[1].draw.geometry = geometry;
        FailingAllocator allocator = { .failure = 1 };
        fixture.destination.allocator = &allocator;
        assert(@catch(entry.described.codec.attach(&source, &context)) == c3d::CAPACITY_EXCEEDED);
        fixture.destination.allocator = mem;
        assert(!allocator.outstanding && !fixture.destination.has(owner, LodGroup));
        assert(crowd.placements.ptr == placements && owner.first_child == null && !crowd.is_prepared());
        entry.described.codec.attach(&source, &context)!!;
        assert(fixture.destination.get(owner, LodGroup).state.animated);
    };
}

fn void? project_codec_lod_v1(void* component, void* value, WriteContext* context) @local {
    LodGroupState* state = ((LodGroup*)component).state;
    *(LodAuthoringV1*)value = {
        .desc = state.desc,
        .mode = state.mode,
        .capacity = (uint)state.transforms.len,
        .transforms = state.mode == INSTANCED ? state.transforms[:state.count] : (Transform[]) {},
        .colors = state.mode == INSTANCED ? state.colors[:state.count] : (Vec4[]) {},
        .effects = state.effects,
        .has_impostor = state.has_impostor,
        .impostor = state.impostor,
        .impostor_min_screen_size = state.impostor_min_screen_size,
    };
}

fn void test_animated_lod_codec_backward_rigid_v1_binary_and_text() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;
        Geometry geometry = geometry::box(
            allocator: tmem,
            width: 1,
            height: 1,
            depth: 1,
        );
        GeometryId geometry_id = fixture.assets.add_geometry(&geometry, "legacy_box")!!;
        MaterialId material_id = fixture.assets.add_material(material::basic({}), "legacy_material")!!;
        Mat4 affine = matrix::IDENTITY4;
        affine.m01 = 0.125f;
        affine.m03 = 2;
        LodPart[2] parts = {
            { .geometry = geometry_id, .material = material_id, .local = affine },
            { .geometry = geometry_id, .material = material_id, .local = matrix::IDENTITY4 },
        };
        LodLevel[2] levels = {
            { .part_count = 1, .min_screen_size = 0.2f },
            { .first_part = 1, .part_count = 1 },
        };
        Transform[1] placements = { maths::TRANSFORM_IDENTITY };
        placements[0].position = { 1, 2, 3 };
        Vec4[1] colors = { { 0.1f, 0.2f, 0.3f, 1 } };
        Node* source = fixture.source.add_instanced_lod_group(
            assets: &fixture.assets,
            desc: { .parts = parts[..], .levels = levels[..] },
            capacity: 5,
            transforms: placements[..],
            colors: colors[..],
        )!!;
        CodecEntry* entry = &serial::codecs[ecs::assigned_slot(LodGroup)!!];
        CodecEntry saved = *entry;
        DescribedBinding saved_binding = *entry.described;
        char[] bytes;
        String text;
        {
            defer {
                *saved.described = saved_binding;
                *entry = saved;
            }
            entry.codec.version = 1;
            entry.described.type = serial::described_type(LodAuthoringV1)!!;
            entry.described.codec.project = &project_codec_lod_v1;
            bytes = serial::write_subtree(
                allocator: tmem,
                scene: &fixture.source,
                assets: &fixture.assets,
                root: source,
            )!!;
            text = serial::write_subtree_text(
                allocator: tmem,
                scene: &fixture.source,
                assets: &fixture.assets,
                root: source,
            )!!;
        }
        for (uint encoding = 0; encoding < 2; encoding++) {
            Node* restored = encoding == 0
              ? serial::read_subtree(&fixture.destination, &fixture.assets, bytes)!!
              : serial::read_subtree_text(&fixture.destination, &fixture.assets, text)!!;
            LodGroupState* loaded = fixture.destination.get(restored, LodGroup).state;
            assert(!loaded.animated && loaded.mode == INSTANCED && loaded.count == 1);
            assert(loaded.transforms.len == 5 && loaded.desc.levels.len == 2 && loaded.desc.parts.len == 2);
            assert(loaded.desc.parts[0].local.m01 == 0.125f && loaded.desc.parts[0].local.m03 == 2);
            assert(loaded.transforms[0].position == placements[0].position && loaded.colors[0] == colors[0]);
            assert(loaded.transforms[4].scale == (Vec3){ 1, 1, 1 } && loaded.colors[4] == (Vec4){ 1, 1, 1, 1 });
            assert(!loaded.bounds_revision && !loaded.aggregate_revision);
            fixture.destination.remove(restored);
        }
    };
}

fn void test_animated_lod_codec_layout_fingerprints() @test {
    describe::register_core_values()!!;
    describe::register_reflected(LodAuthoringV1)!!;
    describe::register_reflected(ModelSkin)!!;
    describe::register_reflected(AnimatedLodPart)!!;
    describe::register_reflected(AnimatedLodDesc)!!;
    describe::register_reflected(LodAuthoring)!!;
    assert(serial::description_layout(describe::get(LodAuthoringV1)!!)!! == 0xdb17924ea7b43e3f);
    assert(serial::description_layout(describe::get(ModelSkin)!!)!! == 0x03ef0a55ec3ccd1c);
    assert(serial::description_layout(describe::get(AnimatedLodPart)!!)!! == 0x67066c59b87af8fe);
    assert(serial::description_layout(describe::get(AnimatedLodDesc)!!)!! == 0xa65aa93a04287bbc);
    assert(serial::description_layout(describe::get(LodAuthoring)!!)!! == 0xa2d20e5979acddbb);
}
