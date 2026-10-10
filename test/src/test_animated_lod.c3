module c3d::test;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::geometry;
import c3d::maths;
import c3d::model;
import c3d::render;
import c3d::scene;
import c3d::shader;
import c3d::test::animated_crowd_fixtures;
import std::math;

const float[3] ANIMATED_LOD_CHANNEL_DEFAULTS @local = { 0.125f, 0.75f, 0.875f };
const float[3] ANIMATED_LOD_CHANNEL_POSE @local = { 0.875f, 0.625f, 0.125f };

struct AnimatedLodChannelFixture @local {
    GeometryId selected;
    GeometryId foreign;
    ClipId weights;
}

struct AnimatedLodAllocationProbe (Allocator) @local {
    bool reject;
    usz outstanding;
    uint rejected;
}

fn void*? AnimatedLodAllocationProbe.acquire(
    &self,
    sz size,
    AllocInitType init_type,
    sz alignment,
) @dynamic {
    if (self.reject) {
        self.rejected++;
        return mem::OUT_OF_MEMORY~;
    }
    void* pointer = mem.acquire(size, init_type, alignment)!;
    self.outstanding++;
    return pointer;
}

fn void*? AnimatedLodAllocationProbe.resize(
    &self,
    void* pointer,
    sz size,
    sz alignment,
) @dynamic {
    if (self.reject) {
        self.rejected++;
        return mem::OUT_OF_MEMORY~;
    }
    return mem.resize(pointer, size, alignment);
}

fn void AnimatedLodAllocationProbe.release(&self, void* pointer, bool aligned) @dynamic {
    mem.release(pointer, aligned);
    self.outstanding--;
}

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
    AnimatedLodPart[] parts = alloc::new_array(tmem, AnimatedLodPart, (sz)count * 2);
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

fn GeometryId add_animated_lod_channel_geometry(
    AssetStore* assets,
    GeometryId source,
    bool subset,
) @local {
    Geometry* original = &assets.geometry(source).data;
    Geometry geometry = {
        .topology = Topology.TRIANGLES,
        .positions = original.positions,
        .normals = original.normals,
        .targets = alloc::new_array(tmem, MorphTarget, subset ? 4 : 3),
        .channels = alloc::new_array(tmem, MorphChannel, subset ? 1 : 3),
        .bounds = original.bounds,
    };
    foreach (index, &target : geometry.targets) {
        target.position_deltas = alloc::new_array(tmem, Vec3, original.positions.len);
        target.position_deltas[..] = (Vec3){ (float)index + 1, 0, 0 };
    }
    String[3] names = { "left", "middle", "right" };
    foreach (uint index, &channel : geometry.channels) {
        channel.name = subset ? "middle" : names[index];
        channel.first_target = subset ? 0 : index;
        channel.full_weights = alloc::new_array(tmem, float, subset ? 4 : 1);
        if (subset) {
            float[4] full_weights = { 0.25f, 0.5f, 0.75f, 1 };
            channel.full_weights[..] = full_weights[..];
        } else {
            channel.full_weights[0] = 1;
        }
    }
    return assets.add_geometry(&geometry)!!;
}

fn AnimatedLodChannelFixture add_animated_lod_channel_fixture(AssetStore* assets, PartsFixture* parts) @local {
    GeometryId base = add_animated_lod_channel_geometry(assets, parts.geometries[2], false);
    GeometryId selected = add_animated_lod_channel_geometry(assets, parts.geometries[2], true);
    Geometry foreign = assets.geometry(selected).data;
    foreign.channels = alloc::clone_slice(tmem, foreign.channels);
    foreign.channels[0].name = "foreign";
    GeometryId foreign_id = assets.add_geometry(&foreign)!!;
    ModelMesh* mesh = &assets.model(parts.mixed).data.meshes[2];
    mesh.geometry = base;
    alloc::free(assets.allocator, mesh.default_morph_weights.ptr);
    mesh.default_morph_weights = alloc::clone_slice(assets.allocator, ANIMATED_LOD_CHANNEL_DEFAULTS[..]);
    AnimationClip clip = {
        .name = "lod_channel_weights".copy(assets.allocator),
        .duration = 1,
        .tracks = alloc::new_array(assets.allocator, Track, 1),
        .targets = alloc::new_array(assets.allocator, uint, 1),
    };
    defer catch asset::free_clip(assets.allocator, &clip);
    clip.targets[0] = animated_crowd_fixtures::PARTS_MORPH_A;
    clip.tracks[0] = {
        .target = 0,
        .path = TargetPath.MORPH_WEIGHTS,
        .interpolation = Interpolation.LINEAR,
        .times = alloc::new_array(assets.allocator, float, 2),
        .values = alloc::new_array(assets.allocator, float, 6),
    };
    clip.tracks[0].times[1] = 1;
    clip.tracks[0].values[:3] = ANIMATED_LOD_CHANNEL_POSE[..];
    clip.tracks[0].values[3:3] = ANIMATED_LOD_CHANNEL_POSE[..];
    return { .selected = selected, .foreign = foreign_id, .weights = assets.add_clip_owned(&clip)!! };
}

fn Node* animated_lod_contract_owner(
    AssetStore* assets,
    Scene* scene,
    PartsFixture* fixture,
    bool crowd,
) @local {
    if (!crowd) return model::instantiate(assets, scene, fixture.mixed)!!;
    CrowdInstance[1] instances = { {
        .placement = maths::TRANSFORM_IDENTITY,
        .pose = { .clip = fixture.missing_weights, .speed = 0, .loop = false },
        .color = { 1, 1, 1, 1 },
    } };
    return model::add_crowd(
        assets: assets,
        scene: scene,
        model: fixture.mixed,
        capacity: 1,
        pose_bounds: animated_crowd_fixtures::PARTS_POSE_BOUNDS,
        instances: instances[..],
        event_capacity: 0,
    )!!;
}

fn AnimatedLodDesc animated_lod_channel_desc(
    AssetStore* assets,
    PartsFixture* fixture,
    GeometryId selected,
) @local {
    AnimatedLodDesc desc = animated_lod_desc(assets, fixture.mixed);
    desc.parts[7].draw.geometry = selected;
    desc.parts[7].default_morph_weights = alloc::new_array(tmem, float, 1);
    desc.parts[7].default_morph_weights[0] = 0.75f;
    return desc;
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
        ModelTemplate* alias_template = &assets.model(fixture.compatible_alias).data;
        desc.parts[9].skin = alias_template.skins[1];
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
        desc.parts[9].skin = alias_template.skins[1];
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
            {
                .placement = maths::TRANSFORM_IDENTITY,
                .pose = { .clip = fixture.posing, .speed = 1, .loop = true },
                .color = { 1, 1, 1, 1 },
            },
            {
                .placement = maths::TRANSFORM_IDENTITY,
                .pose = { .clip = fixture.posing, .time = 0.5f, .speed = 1, .loop = true },
                .color = { 1, 1, 1, 1 },
            },
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

fn void test_animated_lod_removed_mesh_or_joint_rejects_whole_source_entry() @test {
    @pool() {
        AssetStore assets = animated_lod_store();
        defer asset::destroy_asset_store(&assets);
        PartsFixture fixture = animated_crowd_fixtures::add_parts_fixture(&assets)!!;
        Scene scene = scene::create_scene(mem, { .max_nodes = 64 });
        defer scene::destroy_scene(&scene);
        for (uint missing = 0; missing < 2; missing++) {
            Node* owner = model::instantiate(&assets, &scene, fixture.mixed)!!;
            AnimatedLodDesc desc = animated_lod_desc(&assets, fixture.mixed);
            model::attach_animated_lod(
                assets: &assets,
                scene: &scene,
                owner: owner,
                desc: desc,
            )!!;
            LodGroupState* state = scene.get(owner, LodGroup).state;
            ulong identity = state.identity;
            ModelInstance* instance = scene.get(owner, ModelInstance);
            Node* removed = instance.present_node(missing == 0 ? 4u : 0u);
            scene.remove(removed);
            assert(@catch(model::sync_animated_lod(&assets, &scene, owner)) == c3d::INVALID_ID);
            assert(scene.get(owner, LodGroup).state == state && state.identity == identity);
            scene.remove(owner);
        }
    };
}

fn void test_animated_lod_named_channel_subset_uses_logical_weights_and_restores_defaults() @test {
    @pool() {
        AssetStore assets = animated_lod_store();
        defer asset::destroy_asset_store(&assets);
        PartsFixture fixture = animated_crowd_fixtures::add_parts_fixture(&assets)!!;
        AnimatedLodChannelFixture channels = add_animated_lod_channel_fixture(&assets, &fixture);
        Geometry* selected = &assets.geometry(channels.selected).data;
        assert(selected.targets.len == 4 && selected.channels.len == 1);
        assert(assets.geometry(assets.model(fixture.mixed).data.meshes[2].geometry).target_count == 3);
        for (uint kind = 0; kind < 2; kind++) {
            Scene scene = scene::create_scene(mem, { .max_nodes = 64 });
            defer scene::destroy_scene(&scene);
            Node* owner = animated_lod_contract_owner(
                assets: &assets,
                scene: &scene,
                fixture: &fixture,
                crowd: kind == 1,
            );
            AnimatedCrowd* crowd = scene.get(owner, AnimatedCrowd);
            Animator* animator;
            CrowdPlayer player;
            AnimationActionId action;
            if (crowd) {
                player = crowd.playback.player(crowd.playback.instance_id(0)!!)!!;
                action = player.play(&assets, channels.weights)!!;
            } else {
                animator = anim::add_animator(&scene, owner);
                (void)animator.play(&assets, fixture.missing_weights)!!;
                action = animator.play(&assets, channels.weights)!!;
            }
            AnimatedLodDesc desc = animated_lod_channel_desc(&assets, &fixture, channels.selected);
            model::attach_animated_lod(
                assets: &assets,
                scene: &scene,
                owner: owner,
                desc: desc,
            )!!;
            LodGroupState* state = scene.get(owner, LodGroup).state;
            AnimatedLodPartBinding* part = &state.animated.parts[7];
            uint[] indices = state.animated.weight_indices[part.weight_offset:part.weight_count];
            uint logical_first = state.animated.channel_offsets[2];
            assert(part.mesh_index == 2 && part.weight_count == 1 && indices.len == 1 && indices[0] == 1);
            assert(state.animated.channel_offsets[3] - logical_first == 3);
            assert(state.animated.channel_names[logical_first] == "left");
            assert(state.animated.channel_names[logical_first + 1] == "middle");
            assert(state.animated.channel_names[logical_first + 2] == "right");
            for (uint index = 0; index < 3; index++) {
                assert(bitcast(state.animated.defaults[logical_first + index], uint)
                  == bitcast(ANIMATED_LOD_CHANNEL_DEFAULTS[index], uint));
            }
            ulong identity = state.identity;
            uint descriptor = state.descriptor_revision;
            for (uint stage = 0; stage < 3; stage++) {
                if (stage == 1) {
                    if (crowd) {
                        player.stop(action)!!;
                    } else {
                        animator.stop(action)!!;
                    }
                }
                anim::update(&assets, &scene, 0);
                anim::crowd_update(&assets, &scene, 0);
                model::sync_animated_lod(&assets, &scene, owner)!!;
                assert(state.identity == identity && state.descriptor_revision == descriptor);
                float[] weights;
                if (crowd) {
                    CrowdPart* source = &crowd.parts[2];
                    assert(source.weight_count == 3);
                    weights = crowd.morph_weights[source.weight_offset:source.weight_count];
                } else {
                    ModelInstance* instance = scene.get(owner, ModelInstance);
                    weights = scene.get(instance.present_node(animated_crowd_fixtures::PARTS_MORPH_A), Mesh)
                      .morph_weights;
                }
                for (uint index = 0; index < 3; index++) {
                    float expected = stage ? ANIMATED_LOD_CHANNEL_DEFAULTS[index] : ANIMATED_LOD_CHANNEL_POSE[index];
                    assert(bitcast(weights[index], uint) == bitcast(expected, uint));
                }
                MorphSelection selection = geometry::select_morph_targets(selected.channels, weights, indices);
                shader::MorphWeightsGpu block = render::pack_morph_selection(selection);
                // Middle maps to logical weight 1; its four target keys differ from the base's three channels.
                if (!stage) {
                    assert(block.count == 2 && block.indices[0] == 1 && block.indices[1] == 2);
                    assert(block.weights[0] == 0.5f && block.weights[1] == 0.5f);
                } else {
                    assert(block.count == 1 && block.indices[0] == 2 && block.weights[0] == 1);
                }
                Vec3 point = selected.positions[0];
                for (uint active = 0; active < block.count; active++) {
                    point += selected.targets[block.indices[active]].position_deltas[0] * block.weights[active];
                }
                assert(point == selected.positions[0] + (Vec3){ stage ? 3 : 2.5f, 0, 0 });
            }
        }
    };
}

fn void test_animated_lod_foreign_selected_channel_and_subset_joints_fault_atomically() @test {
    @pool() {
        AssetStore assets = animated_lod_store();
        defer asset::destroy_asset_store(&assets);
        PartsFixture fixture = animated_crowd_fixtures::add_parts_fixture(&assets)!!;
        AnimatedLodChannelFixture channels = add_animated_lod_channel_fixture(&assets, &fixture);
        for (uint kind = 0; kind < 2; kind++) {
            Scene scene = scene::create_scene(mem, { .max_nodes = 64 });
            defer scene::destroy_scene(&scene);
            Node* owner = animated_lod_contract_owner(
                assets: &assets,
                scene: &scene,
                fixture: &fixture,
                crowd: kind == 1,
            );
            AnimatedLodDesc desc = animated_lod_channel_desc(&assets, &fixture, channels.selected);
            model::attach_animated_lod(
                assets: &assets,
                scene: &scene,
                owner: owner,
                desc: desc,
            )!!;
            LodGroupState* previous = scene.get(owner, LodGroup).state;
            ulong identity = previous.identity;
            uint descriptor = previous.descriptor_revision;
            uint revision = previous.revision;
            Node* first_child = owner.first_child;
            uint free_nodes = scene.world.entities.free_count;
            ModelSkin original_skin = desc.parts[9].skin;
            for (uint mutation = 0; mutation < 3; mutation++) {
                if (mutation == 0) desc.parts[7].draw.geometry = channels.foreign;
                if (mutation == 1) desc.parts[7].default_morph_weights[0] = 0.625f;
                if (mutation == 2) desc.parts[9].skin.joint_nodes = original_skin.joint_nodes[:1];
                assert(@catch(model::replace_animated_lod(
                    assets: &assets,
                    scene: &scene,
                    owner: owner,
                    desc: desc,
                )) == c3d::INVALID_ARGUMENT);
                assert(scene.get(owner, LodGroup).state == previous && previous.identity == identity);
                assert(previous.descriptor_revision == descriptor && previous.revision == revision);
                assert(scene.world.entities.free_count == free_nodes && owner.first_child == first_child);
                assert(previous.animated.weight_indices[previous.animated.parts[7].weight_offset] == 1);
                assert(c3d::same_id(previous.desc.parts[7].geometry, channels.selected));
                GeometryId expected_geometry = mutation == 0 ? channels.foreign : channels.selected;
                assert(c3d::same_id(desc.parts[7].draw.geometry, expected_geometry));
                if (mutation == 1) assert(desc.parts[7].default_morph_weights[0] == 0.625f);
                if (mutation == 2) assert(desc.parts[9].skin.joint_nodes.len == 1);
                desc.parts[7].draw.geometry = channels.selected;
                desc.parts[7].default_morph_weights[0] = 0.75f;
                desc.parts[9].skin = original_skin;
            }
            model::sync_animated_lod(&assets, &scene, owner)!!;
            assert(scene.get(owner, LodGroup).state == previous && previous.identity == identity);
        }
    };
}

fn void test_animated_lod_public_replace_allocation_failure_preserves_owned_state_and_caller_data() @test {
    @pool() {
        AssetStore assets = animated_lod_store();
        defer asset::destroy_asset_store(&assets);
        PartsFixture fixture = animated_crowd_fixtures::add_parts_fixture(&assets)!!;
        for (uint kind = 0; kind < 2; kind++) {
            AnimatedLodAllocationProbe allocator;
            Scene scene = scene::create_scene(&allocator, { .max_nodes = 64 });
            defer {
                scene::destroy_scene(&scene);
                assert(!allocator.outstanding);
            }
            Node* owner = animated_lod_contract_owner(
                assets: &assets,
                scene: &scene,
                fixture: &fixture,
                crowd: kind == 1,
            );
            AnimatedLodDesc desc = animated_lod_desc(&assets, fixture.mixed);
            model::attach_animated_lod(
                assets: &assets,
                scene: &scene,
                owner: owner,
                desc: desc,
            )!!;
            LodGroupState* previous = scene.get(owner, LodGroup).state;
            ulong identity = previous.identity;
            uint descriptor = previous.descriptor_revision;
            uint revision = previous.revision;
            usz outstanding = allocator.outstanding;
            uint free_nodes = scene.world.entities.free_count;
            Node* first_child = owner.first_child;
            LodLevel* levels = desc.levels.ptr;
            AnimatedLodPart* parts = desc.parts.ptr;
            uint* joints = desc.parts[9].skin.joint_nodes.ptr;
            float* defaults = desc.parts[7].default_morph_weights.ptr;
            AnimatedCrowd* crowd = scene.get(owner, AnimatedCrowd);
            ulong playback = crowd ? crowd.playback.identity : 0;
            uint generation = crowd ? crowd.playback.slots[0].generation : 0;
            desc.levels[0].min_screen_size = 0.3f;
            allocator.reject = true;
            assert(@catch(model::replace_animated_lod(
                assets: &assets,
                scene: &scene,
                owner: owner,
                desc: desc,
            )) == c3d::CAPACITY_EXCEEDED);
            allocator.reject = false;
            assert(allocator.rejected == 1 && allocator.outstanding == outstanding);
            assert(scene.get(owner, LodGroup).state == previous && previous.identity == identity);
            assert(previous.descriptor_revision == descriptor && previous.revision == revision);
            assert(previous.desc.levels[0].min_screen_size == 0.2f);
            assert(scene.world.entities.free_count == free_nodes && owner.first_child == first_child);
            assert(desc.levels.ptr == levels && desc.parts.ptr == parts && desc.levels[0].min_screen_size == 0.3f);
            assert(desc.parts[9].skin.joint_nodes.ptr == joints
              && desc.parts[7].default_morph_weights.ptr == defaults);
            assert(joints[0] == 0 && joints[1] == 1 && defaults[0] == 0.25f);
            if (crowd) assert(crowd.playback.identity == playback && crowd.playback.slots[0].generation == generation);
            model::replace_animated_lod(
                assets: &assets,
                scene: &scene,
                owner: owner,
                desc: desc,
            )!!;
            LodGroupState* next = scene.get(owner, LodGroup).state;
            assert(next != previous && next.identity != identity && next.desc.levels[0].min_screen_size == 0.3f);
            assert(allocator.outstanding == outstanding && scene.world.entities.free_count == free_nodes);
            if (crowd) assert(crowd.playback.identity == playback && crowd.playback.slots[0].generation == generation);
        }
    };
}
