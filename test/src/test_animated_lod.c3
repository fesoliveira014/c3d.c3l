module c3d::test;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::maths;
import c3d::model;
import c3d::scene;
import c3d::test::animated_crowd_fixtures;
import std::math;

fn AssetStore animated_lod_store() @local {
    return asset::create_asset_store(mem, {
        .max_geometries = 8, .max_textures = 8, .max_materials = 4, .max_samplers = 8,
        .max_models = 8, .max_skeletons = 8, .max_clips = 8,
    });
}

fn AnimatedLodDesc animated_lod_desc(AssetStore* assets, ModelId model_id) @local {
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
            skin.joint_nodes = alloc::clone_slice(tmem, skin.joint_nodes);
            parts[level * count + index] = {
                .draw = { .geometry = mesh.geometry, .material = mesh.material, .local = matrix::IDENTITY4 },
                .mesh_index = index,
                .skin = skin,
                .default_morph_weights = alloc::clone_slice(tmem, mesh.default_morph_weights),
            };
        }
    }
    return { .levels = levels, .parts = parts };
}

fn void test_animated_lod_copies_logical_parts_and_preserves_ordinary_pose() @test {
    @pool() {
        AssetStore assets = animated_lod_store();
        defer asset::destroy_asset_store(&assets);
        PartsFixture fixture = animated_crowd_fixtures::add_parts_fixture(&assets)!!;
        Scene scene = scene::create_scene(mem, { .max_nodes = 64 });
        defer scene::destroy_scene(&scene);
        Node* owner = model::instantiate(&assets, &scene, fixture.mixed)!!;
        Animator* animator = anim::add_animator(&scene, owner);
        AnimationActionId action = animator.play(&assets, fixture.posing)!!;
        animator.action(action).time = 0.5f;
        anim::update(&assets, &scene, 0);
        ModelInstance* instance = scene.get(owner, ModelInstance);
        Vec3 rigid = instance.present_node(4).local.position;
        float morph = scene.get(instance.present_node(5), Mesh).morph_weights[0];
        AnimatedLodDesc desc = animated_lod_desc(&assets, fixture.mixed);
        model::attach_animated_lod(
            assets: &assets,
            scene: &scene,
            owner: owner,
            desc: desc,
        )!!;
        LodGroupState* state = scene.get(owner, LodGroup).state;
        assert(state.animated && state.mode == LodMode.SINGLE && state.count == 1);
        assert(state.desc.levels.len == 2 && state.desc.parts.len == 10);
        assert(state.animated.parts[2].mesh_index == 2 && state.animated.parts[2].template_node == 5);
        assert(state.animated.parts[0].skinned && !state.animated.parts[1].skinned);
        assert(state.animated.joint_nodes.len == 2 && state.animated.inverse_bind.len == 2);
        assert(state.animated.defaults[0] == 0.25f && state.animated.defaults[1] == 0.75f);
        assert(state.animated.channel_names[0] == "lift" && state.animated.channel_names[1] == "lift");
        assert(!state.effects.trace);
        ulong identity = state.identity;
        uint descriptor = state.descriptor_revision;
        desc.parts[2].default_morph_weights[0] = 0.99f;
        desc.parts[0].draw.local.m03 = 123;
        desc.levels[0].min_screen_size = 0.9f;
        assert(state.desc.levels[0].min_screen_size == 0.2f && state.desc.parts[0].local.m03 == 0);
        assert(state.animated.defaults[0] == 0.25f);
        model::sync_animated_lod(&assets, &scene, owner)!!;
        assert(state.identity == identity && state.descriptor_revision == descriptor);
        assert(animator.action(action).time == 0.5f);
        assert(instance.present_node(4).local.position == rigid);
        assert(scene.get(instance.present_node(5), Mesh).morph_weights[0] == morph);
    };
}

fn void test_animated_lod_binding_and_default_faults_preserve_existing_descriptor() @test {
    @pool() {
        AssetStore assets = animated_lod_store();
        defer asset::destroy_asset_store(&assets);
        PartsFixture fixture = animated_crowd_fixtures::add_parts_fixture(&assets)!!;
        Scene scene = scene::create_scene(mem, { .max_nodes = 64 });
        defer scene::destroy_scene(&scene);
        Node* owner = model::instantiate(&assets, &scene, fixture.mixed)!!;
        AnimatedLodDesc desc = animated_lod_desc(&assets, fixture.mixed);
        ModelTemplate* alias = &assets.model(fixture.compatible_alias).data;
        desc.parts[9].skin = alias.skins[1];
        model::attach_animated_lod(
            assets: &assets,
            scene: &scene,
            owner: owner,
            desc: desc,
        )!!;
        LodGroupState* previous = scene.get(owner, LodGroup).state;
        ulong identity = previous.identity;
        ModelTemplate* reordered = &assets.model(fixture.reordered_joints).data;
        desc.parts[9].skin = reordered.skins[1];
        assert(@catch(model::replace_animated_lod(
            assets: &assets,
            scene: &scene,
            owner: owner,
            desc: desc,
        )) == c3d::INVALID_ARGUMENT);
        assert(scene.get(owner, LodGroup).state == previous && previous.identity == identity);
        ModelTemplate* changed_bind = &assets.model(fixture.different_bind).data;
        desc.parts[9].skin = changed_bind.skins[1];
        assert(@catch(model::replace_animated_lod(
            assets: &assets,
            scene: &scene,
            owner: owner,
            desc: desc,
        )) == c3d::INVALID_ARGUMENT);
        desc.parts[9].skin = alias.skins[1];
        desc.parts[7].default_morph_weights[0] = 0.5f;
        assert(@catch(model::replace_animated_lod(
            assets: &assets,
            scene: &scene,
            owner: owner,
            desc: desc,
        )) == c3d::INVALID_ARGUMENT);
        desc.parts[7].default_morph_weights[0] = 0.25f;
        desc.parts[9].draw.geometry = { .index = uint::max, .generation = 1 };
        assert(@catch(model::replace_animated_lod(
            assets: &assets,
            scene: &scene,
            owner: owner,
            desc: desc,
        )) == c3d::INVALID_ID);
        assert(scene.get(owner, LodGroup).state == previous && previous.identity == identity);
    };
}

fn void test_animated_lod_pending_crowd_reacquires_fixed_source_without_replacement() @test {
    @pool() {
        AssetStore assets = animated_lod_store();
        defer asset::destroy_asset_store(&assets);
        PartsFixture fixture = animated_crowd_fixtures::add_parts_fixture(&assets)!!;
        Scene scene = scene::create_scene(mem, { .max_nodes = 64 });
        defer scene::destroy_scene(&scene);
        Node* owner = scene.add_node(name: "pending_lod")!!;
        CrowdInstance[2] instances = {
            { .placement = maths::TRANSFORM_IDENTITY, .pose = { .clip = fixture.posing, .speed = 1, .loop = true }, .color = { 1, 1, 1, 1 } },
            { .placement = maths::TRANSFORM_IDENTITY, .pose = { .clip = fixture.posing, .time = 0.5f, .speed = 1, .loop = true }, .color = { 1, 1, 1, 1 } },
        };
        model::attach_crowd(
            assets: &assets,
            scene: &scene,
            node: owner,
            model: fixture.skin_free,
            capacity: 4,
            pose_bounds: animated_crowd_fixtures::PARTS_POSE_BOUNDS,
            instances: instances[..],
        )!!;
        AnimatedLodDesc desc = animated_lod_desc(&assets, fixture.skin_free);
        model::attach_animated_lod(
            assets: &assets,
            scene: &scene,
            owner: owner,
            desc: desc,
        )!!;
        AnimatedCrowd* crowd = scene.get(owner, AnimatedCrowd);
        LodGroupState* state = scene.get(owner, LodGroup).state;
        ulong identity = state.identity;
        assert(state.mode == LodMode.INSTANCED && state.count == 0);
        assert(state.transforms.ptr == crowd.placements.ptr && state.colors.ptr == crowd.colors.ptr);
        assert(state.desc.has_bounds_override && state.desc.local_bounds.min == crowd.pose_bounds.min);
        model::prepare_crowd(&assets, &scene, owner)!!;
        model::sync_animated_lod(&assets, &scene, owner)!!;
        assert(state.count == 2 && state.identity == identity && state.descriptor_revision == 1);
        uint generation = state.slot_generations[0];
        anim::crowd_update(&assets, &scene, 0.25f);
        model::sync_animated_lod(&assets, &scene, owner)!!;
        assert(state.identity == identity && state.slot_generations[0] == generation);
        assert(@catch(scene.resize_lod_instances(owner, 3)) == c3d::INVALID_ARGUMENT);
        model::set_crowd(&assets, &scene, owner, instances[:1])!!;
        model::sync_animated_lod(&assets, &scene, owner)!!;
        assert(state.count == 1 && state.identity == identity && state.slot_generations[0] != generation);
    };
}
