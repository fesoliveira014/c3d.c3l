module c3d::test;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::model;
import c3d::render;
import c3d::scene;
import c3d::shader;
import c3d::spatial;
import c3d::test::animated_crowd_fixtures;
import std::math;

const float[3] ANIMATED_LOD_CHANNEL_DEFAULTS @local = { 0.125f, 0.75f, 0.875f };
const float[3] ANIMATED_LOD_CHANNEL_POSE @local = { 0.875f, 0.625f, 0.125f };
const float ANIMATED_LOD_QUERY_TOLERANCE @local = 1e-5f;

enum AnimatedLodAttachFaultKind @local {
    DEAD_OWNER,
    RETIRED_GEOMETRY,
    SECOND_ATTACH,
    IMPORTED_GROUP,
    CUSTOM_VERTEX,
    ALLOCATION,
}

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
    AnimatedLodDesc desc = animated_crowd_fixtures::parts_lod_desc(assets, fixture.mixed);
    desc.parts[7].draw.geometry = selected;
    desc.parts[7].default_morph_weights = alloc::new_array(tmem, float, 1);
    desc.parts[7].default_morph_weights[0] = 0.75f;
    return desc;
}

fn bool animated_lod_query_contains(Aabb bounds, Vec3 point) @local {
    for (uint axis = 0; axis < 3; axis++) {
        if (point[axis] < bounds.min[axis] - ANIMATED_LOD_QUERY_TOLERANCE
          || point[axis] > bounds.max[axis] + ANIMATED_LOD_QUERY_TOLERANCE) return false;
    }
    return true;
}

fn void animated_lod_query_equal(PickHit[] direct, PickHit[] indexed) @local {
    assert(direct.len == indexed.len);
    foreach (index, hit : direct) {
        assert(hit.node == indexed[index].node && hit.lod_group == indexed[index].lod_group);
        assert(hit.instance_index == indexed[index].instance_index && hit.part_index == indexed[index].part_index);
        assert(c3d::same_id(hit.geometry, indexed[index].geometry));
        assert(hit.distance == indexed[index].distance && hit.triangle_hit == indexed[index].triangle_hit);
    }
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
        AnimatedLodDesc desc = animated_crowd_fixtures::parts_lod_desc(&assets, fixture.mixed);
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

fn void test_animated_lod_replace_faults_preserve_existing_descriptor() @test {
    @pool() {
        AssetStore assets = animated_lod_store();
        defer asset::destroy_asset_store(&assets);
        PartsFixture fixture = animated_crowd_fixtures::add_parts_fixture(&assets)!!;
        AnimatedLodChannelFixture channels = add_animated_lod_channel_fixture(&assets, &fixture);
        ModelSkin compatible = assets.model(fixture.compatible_alias).data.skins[1];
        ModelSkin reordered = assets.model(fixture.reordered_joints).data.skins[1];
        ModelSkin changed_bind = assets.model(fixture.different_bind).data.skins[1];
        float[1] wrong_default = { 0.625f };
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
            desc.parts[9].skin = compatible;
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
            for (uint mutation = 0; mutation < 6; mutation++) {
                AnimatedLodDesc changed = { .levels = desc.levels, .parts = alloc::clone_slice(tmem, desc.parts) };
                switch (mutation) {
                    case 0: changed.parts[7].draw.geometry = channels.foreign;
                    case 1: changed.parts[7].default_morph_weights = wrong_default[..];
                    case 2: changed.parts[9].skin.joint_nodes = desc.parts[9].skin.joint_nodes[:1];
                    case 3: changed.parts[9].skin = reordered;
                    case 4: changed.parts[9].skin = changed_bind;
                    case 5: changed.parts[9].draw.geometry = { .index = uint::max, .generation = 1 };
                }
                fault expected = mutation == 5 ? c3d::INVALID_ID : c3d::INVALID_ARGUMENT;
                assert(@catch(model::replace_animated_lod(
                    assets: &assets,
                    scene: &scene,
                    owner: owner,
                    desc: changed,
                )) == expected);
                assert(scene.get(owner, LodGroup).state == previous && previous.identity == identity);
                assert(previous.descriptor_revision == descriptor && previous.revision == revision);
                assert(scene.world.entities.free_count == free_nodes && owner.first_child == first_child);
                assert(previous.animated.weight_indices[previous.animated.parts[7].weight_offset] == 1);
                assert(c3d::same_id(previous.desc.parts[7].geometry, channels.selected));
            }
            model::sync_animated_lod(&assets, &scene, owner)!!;
            assert(scene.get(owner, LodGroup).state == previous && previous.identity == identity);
        }
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
        AnimatedLodDesc desc = animated_crowd_fixtures::parts_lod_desc(&assets, fixture.skin_free);
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
        uint pending_revision = state.revision;
        model::prepare_crowd(&assets, &scene, owner)!!;
        assert_animated_lod_crowd_publication(&scene, crowd, state);
        assert(state.count == 2 && state.identity == identity && state.descriptor_revision == 1);
        assert(state.revision != pending_revision);
        uint generation = state.slot_generations[0];
        uint prepared_revision = state.revision;
        anim::crowd_update(&assets, &scene, 0.25f);
        assert_animated_lod_crowd_publication(&scene, crowd, state);
        assert(state.identity == identity && state.slot_generations[0] == generation);
        assert(state.revision != prepared_revision);
        uint updated_revision = state.revision;
        model::set_crowd(&assets, &scene, owner, instances[:1])!!;
        assert_animated_lod_crowd_publication(&scene, crowd, state);
        assert(state.count == 1 && state.identity == identity && state.slot_generations[0] != generation);
        assert(state.revision != updated_revision);
        uint replaced_generation = state.slot_generations[0];
        uint replaced_revision = state.revision;
        crowd.playback.slots[0].root_motion = { .translation = { 2, 0, 0 }, .rotation = quaternion::IDENTITY };
        scene.apply_crowd_root_motion(crowd);
        assert_animated_lod_crowd_publication(&scene, crowd, state);
        assert(state.transforms[0].position == (Vec3){ 2, 0, 0 });
        assert(state.slot_generations[0] == replaced_generation && state.revision != replaced_revision);
        assert(state.identity == identity && state.descriptor_revision == 1);
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
            AnimatedLodDesc desc = animated_crowd_fixtures::parts_lod_desc(&assets, fixture.mixed);
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
            for (uint stage = 0; stage < 2; stage++) {
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
            }
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
            AnimatedLodDesc desc = animated_crowd_fixtures::parts_lod_desc(&assets, fixture.mixed);
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

fn void test_animated_lod_attach_fault_table_preserves_components_and_allocator() @test {
    AnimatedLodAttachFaultKind[6] cases = {
        AnimatedLodAttachFaultKind.DEAD_OWNER,
        AnimatedLodAttachFaultKind.RETIRED_GEOMETRY,
        AnimatedLodAttachFaultKind.SECOND_ATTACH,
        AnimatedLodAttachFaultKind.IMPORTED_GROUP,
        AnimatedLodAttachFaultKind.CUSTOM_VERTEX,
        AnimatedLodAttachFaultKind.ALLOCATION,
    };
    bool[6] crowd_owner = { false, true, false, true, false, true };
    fault[6] expected = {
        c3d::INVALID_ID, c3d::INVALID_ID, c3d::INVALID_ARGUMENT,
        c3d::UNSUPPORTED, c3d::UNSUPPORTED, c3d::CAPACITY_EXCEEDED,
    };
    foreach (uint index, mutation : cases) {
        @pool() {
            AssetStore assets = animated_lod_store();
            defer asset::destroy_asset_store(&assets);
            PartsFixture fixture = animated_crowd_fixtures::add_parts_fixture(&assets)!!;
            AnimatedLodAllocationProbe allocator;
            Scene scene = scene::create_scene(&allocator, { .max_nodes = 64 });
            defer {
                scene::destroy_scene(&scene);
                assert(allocator.outstanding == 0);
            }
            Node* live_owner = animated_lod_contract_owner(
                assets: &assets,
                scene: &scene,
                fixture: &fixture,
                crowd: crowd_owner[index],
            );
            Node retired_owner;
            Node* owner = live_owner;
            AnimatedLodDesc desc = animated_crowd_fixtures::parts_lod_desc(&assets, fixture.mixed);
            LodGroupState* previous;
            LodGroupState previous_value;
            switch (mutation) {
                case AnimatedLodAttachFaultKind.DEAD_OWNER:
                    retired_owner = *live_owner;
                    scene.remove(live_owner);
                    owner = &retired_owner;
                case AnimatedLodAttachFaultKind.RETIRED_GEOMETRY:
                    assets.remove_geometry(desc.parts[0].draw.geometry);
                case AnimatedLodAttachFaultKind.SECOND_ATTACH:
                    model::attach_animated_lod(
                        assets: &assets,
                        scene: &scene,
                        owner: owner,
                        desc: desc,
                    )!!;
                    previous = scene.get(owner, LodGroup).state;
                    previous_value = *previous;
                case AnimatedLodAttachFaultKind.IMPORTED_GROUP:
                    ModelTemplate* template = &assets.model(fixture.mixed).data;
                    template.lod_groups = alloc::new_array(assets.allocator, ModelLodGroup, 1);
                    ModelLodGroup* imported = &template.lod_groups[0];
                    imported.node = template.meshes[1].node;
                    imported.desc.parts = alloc::new_array(assets.allocator, LodPart, 1);
                    imported.desc.parts[0] = desc.parts[1].draw;
                    imported.desc.levels = alloc::new_array(assets.allocator, LodLevel, 1);
                    imported.desc.levels[0] = { .part_count = 1 };
                case AnimatedLodAttachFaultKind.CUSTOM_VERTEX:
                    char[1] bytecode = { 1 };
                    ShaderDesc shader_desc = {
                        .fragment = bytecode[..],
                        .vertex = { .shaded = bytecode[..], .depth = bytecode[..] },
                    };
                    ShaderId shader_id = assets.add_shader(&shader_desc)!!;
                    desc.parts[desc.levels[1].first_part].draw.material =
                      assets.add_material(material::custom(shader_id, {}))!!;
                case AnimatedLodAttachFaultKind.ALLOCATION:
                    allocator.reject = true;
            }
            usz outstanding = allocator.outstanding;
            uint components = scene.count(LodGroup);
            uint free_nodes = scene.world.entities.free_count;
            fault observed = @catch(model::attach_animated_lod(
                assets: &assets,
                scene: &scene,
                owner: owner,
                desc: desc,
            ));
            allocator.reject = false;
            assert(observed == expected[index]);
            assert(allocator.outstanding == outstanding && scene.count(LodGroup) == components);
            assert(scene.world.entities.free_count == free_nodes);
            if (previous) {
                assert(scene.get(owner, LodGroup).state == previous);
                assert(mem::equals((char*)previous, (char*)&previous_value, LodGroupState::size));
            } else {
                assert(!scene.world.is_alive(owner.id) || !scene.has(owner, LodGroup));
            }
            if (mutation == AnimatedLodAttachFaultKind.ALLOCATION) assert(allocator.rejected == 1);
        };
    }
}

fn void test_animated_lod_removed_crowd_keeps_group_without_freed_source_aliases() @test {
    @pool() {
        AssetStore assets = animated_lod_store();
        defer asset::destroy_asset_store(&assets);
        PartsFixture fixture = animated_crowd_fixtures::add_parts_fixture(&assets)!!;
        Scene scene = scene::create_scene(mem, { .max_nodes = 64 });
        defer scene::destroy_scene(&scene);
        Node* owner = animated_lod_contract_owner(
            assets: &assets,
            scene: &scene,
            fixture: &fixture,
            crowd: true,
        );
        model::attach_animated_lod(
            assets: &assets,
            scene: &scene,
            owner: owner,
            desc: animated_crowd_fixtures::parts_lod_desc(&assets, fixture.mixed),
        )!!;
        scene.update_world();
        LodGroupState* state = scene.get(owner, LodGroup).state;
        ulong identity = state.identity;
        assert(state.count == 1 && state.transforms.len > 0 && state.colors.len > 0);
        scene.remove_component(owner, AnimatedCrowd);
        assert(scene.has(owner, LodGroup) && !scene.has(owner, AnimatedCrowd));
        assert(scene.get(owner, LodGroup).state == state && state.identity == identity);
        assert(state.count == 0 && state.transforms.len == 0 && state.colors.len == 0);
        LodGroupState before = *state;
        assert(!spatial::lod_group_is_live(
            assets: &assets,
            group: scene.get(owner, LodGroup),
            scene: &scene,
            node: owner,
        ));
        assert(mem::equals((char*)state, (char*)&before, LodGroupState::size));
        AnimatedLodBinding binding_before = *state.animated;
        uint[] generations_before = alloc::clone_slice(tmem, state.slot_generations);
        CrowdInstance[3] instances;
        foreach (uint index, &instance : instances) {
            *instance = {
                .placement = maths::TRANSFORM_IDENTITY,
                .pose = { .clip = fixture.posing, .time = 0.25f * (float)index, .speed = 1, .loop = true },
                .color = { 1, 1, 1, 1 },
            };
        }
        model::attach_crowd(
            assets: &assets,
            scene: &scene,
            node: owner,
            model: fixture.mixed,
            capacity: 4,
            pose_bounds: animated_crowd_fixtures::PARTS_POSE_BOUNDS,
            instances: instances[..],
        )!!;
        model::prepare_crowd(&assets, &scene, owner)!!;
        AnimatedCrowd* larger = scene.get(owner, AnimatedCrowd);
        assert(larger.is_prepared() && larger.count == 3 && larger.playback.slots.len == 4);
        scene.write_crowd_batches(larger);
        assert(@catch(model::sync_animated_lod(&assets, &scene, owner)) == c3d::INVALID_ARGUMENT);
        assert(scene.get(owner, LodGroup).state == state);
        assert(mem::equals((char*)state, (char*)&before, LodGroupState::size));
        assert(mem::equals((char*)state.animated, (char*)&binding_before, AnimatedLodBinding::size));
        assert(state.slot_generations == generations_before);
        scene.remove_component(owner, LodGroup);
        assert(!scene.has(owner, LodGroup));
    };
}

fn void assert_animated_lod_crowd_publication(
    Scene* scene,
    AnimatedCrowd* crowd,
    LodGroupState* state,
) @local {
    assert(state.count == crowd.count);
    assert(state.transforms.ptr == crowd.placements.ptr && state.colors.ptr == crowd.colors.ptr);
    assert(state.instance_epoch == crowd.playback.identity);
    assert(state.slot_generations.len == crowd.playback.slots.len);
    foreach (index, slot : crowd.playback.slots) assert(state.slot_generations[index] == slot.generation);
    InstancedMesh* batch = scene.world.get(crowd.parts[0].batch, InstancedMesh);
    assert(state.animated.source_revision == batch.revision);
}

fn void test_animated_lod_animator_update_publishes_source_without_explicit_sync() @test {
    @pool() {
        AssetStore assets = animated_lod_store();
        defer asset::destroy_asset_store(&assets);
        PartsFixture fixture = animated_crowd_fixtures::add_parts_fixture(&assets)!!;
        Scene scene = scene::create_scene(mem, { .max_nodes = 64 });
        defer scene::destroy_scene(&scene);
        Node* owner = model::instantiate(&assets, &scene, fixture.mixed)!!;
        Animator* animator = anim::add_animator(&scene, owner);
        AnimationActionId action = animator.play(&assets, fixture.posing)!!;
        model::attach_animated_lod(
            assets: &assets,
            scene: &scene,
            owner: owner,
            desc: animated_crowd_fixtures::parts_lod_desc(&assets, fixture.mixed),
        )!!;
        LodGroupState* state = scene.get(owner, LodGroup).state;
        ModelInstance* instance = scene.get(owner, ModelInstance);
        uint before = state.revision;
        ulong identity = state.identity;
        uint descriptor_revision = state.descriptor_revision;
        animator.action(action).time = 0.5f;
        anim::update(&assets, &scene, 0);
        assert(instance.present_node(animated_crowd_fixtures::PARTS_RIGID_NODE).local.position == (Vec3){ 2, 0, 0 });
        assert(state.revision != before && state.aggregate_revision == 0);
        assert(state.count == 1 && state.identity == identity && state.descriptor_revision == descriptor_revision);
    };
}

fn void test_animated_lod_queries_use_posed_base_logical_parts_once() @test {
    @pool() {
        AssetStore assets = animated_lod_store();
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
        model::attach_animated_lod(
            assets: &assets,
            scene: &scene,
            owner: owner,
            desc: animated_crowd_fixtures::parts_lod_desc(&assets, fixture.mixed, permuted: true),
        )!!;
        Node* extra = scene.add_mesh(
            geometry: fixture.geometries[1],
            material: fixture.material,
            parent: owner,
            name: "unrelated_child",
        )!!;
        extra.local.position.x = 40;
        scene.update_world();
        SceneIndex index = spatial::create_scene_index(mem, 6);
        defer spatial::destroy_scene_index(&index);
        index.refresh(&assets, &scene)!!;
        assert(index.count == 6 && index.dangling == 0);
        uint[animated_crowd_fixtures::PARTS_MESH_COUNT] seen;
        uint unrelated;
        foreach (entry : index.entries[:index.count]) {
            if (!entry.flags.lod_group) {
                assert(entry.node == extra);
                unrelated++;
            } else {
                assert(entry.node == owner && entry.instance_index == 0 && !entry.flags.instanced);
                assert(entry.part_index < seen.len);
                seen[entry.part_index]++;
                assert(c3d::same_id(entry.geometry, fixture.geometries[entry.part_index]));
                assert(entry.flags.static_triangles == (entry.part_index == 1));
                assert(entry.flags.skinned == (entry.part_index == 0 || entry.part_index == 4));
                for (uint vertex = 0; vertex < animated_crowd_fixtures::PARTS_VERTEX_COUNT; vertex++) {
                    assert(animated_lod_query_contains(entry.bounds,
                        animated_crowd_fixtures::PARTS_POSED_POINTS[3 * entry.part_index + vertex]));
                }
                if (entry.part_index == 1) {
                    assert(entry.bounds.min == (Vec3){ 14, 1, -2 });
                    assert(entry.bounds.max == (Vec3){ 16, 2, -2 });
                }
            }
        }
        foreach (count : seen) assert(count == 1);
        assert(unrelated == 1);
        spatial::prepare_triangle_picks(&assets, &scene);
        for (uint part = 0; part < animated_crowd_fixtures::PARTS_MESH_COUNT; part++) {
            Vec3 first = animated_crowd_fixtures::PARTS_POSED_POINTS[3 * part];
            Vec3 second = animated_crowd_fixtures::PARTS_POSED_POINTS[3 * part + 1];
            Vec3 third = animated_crowd_fixtures::PARTS_POSED_POINTS[3 * part + 2];
            Vec3 centre = (first + second + third) / 3;
            Ray ray = { .origin = { centre.x, centre.y, 10 }, .direction = { 0, 0, -1 } };
            PickOptions options = { .precision = PickPrecision.TRIANGLES, .faces = PickFaces.BOTH, .layers = uint::max };
            PickHit[] direct = spatial::pick(
                allocator: tmem,
                assets: &assets,
                scene: &scene,
                ray: ray,
                options: options,
            );
            PickHit[] indexed = index.pick(
                allocator: tmem,
                assets: &assets,
                ray: ray,
                options: options,
            );
            animated_lod_query_equal(direct, indexed);
            bool found;
            foreach (hit : direct) {
                if (hit.node == owner && hit.part_index == part) {
                    found = true;
                    assert(hit.lod_group && hit.instance_index == 0);
                    assert(c3d::same_id(hit.geometry, fixture.geometries[part]));
                    assert(hit.triangle_hit == (part == 1));
                }
            }
            assert(found);
        }
    };
}

fn void test_animated_lod_queries_keep_retained_pose_bounds_without_cpu_streams() @test {
    @pool() {
        AssetStore assets = animated_lod_store();
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
        model::attach_animated_lod(
            assets: &assets,
            scene: &scene,
            owner: owner,
            desc: animated_crowd_fixtures::parts_lod_desc(&assets, fixture.mixed, permuted: true),
        )!!;
        scene.update_world();
        SceneIndex index = spatial::create_scene_index(mem, 5);
        defer spatial::destroy_scene_index(&index);
        index.refresh(&assets, &scene)!!;
        Aabb[animated_crowd_fixtures::PARTS_MESH_COUNT] retained;
        foreach (entry : index.entries[:index.count]) retained[entry.part_index] = entry.bounds;
        assets.release_geometry_cpu(fixture.geometries[0]);
        assets.release_geometry_cpu(fixture.geometries[1]);
        assets.release_geometry_cpu(fixture.geometries[2]);
        assets.release_geometry_cpu(fixture.geometries[4]);
        index.refresh(&assets, &scene)!!;
        assert(index.count == 5 && index.dangling == 0);
        foreach (entry : index.entries[:index.count]) {
            assert(entry.bounds.min == retained[entry.part_index].min);
            assert(entry.bounds.max == retained[entry.part_index].max);
            assert(!entry.flags.static_triangles);
        }
        Ray ray = { .origin = { 10.5f, 1, 10 }, .direction = { 0, 0, -1 } };
        PickOptions options = { .precision = PickPrecision.TRIANGLES, .faces = PickFaces.BOTH, .layers = uint::max };
        PickHit[] direct = spatial::pick(
            allocator: tmem,
            assets: &assets,
            scene: &scene,
            ray: ray,
            options: options,
        );
        PickHit[] indexed = index.pick(
            allocator: tmem,
            assets: &assets,
            ray: ray,
            options: options,
        );
        animated_lod_query_equal(direct, indexed);
        assert(direct.len > 0);
        foreach (hit : direct) assert(!hit.triangle_hit);
    };
}

fn void test_animated_lod_queries_use_crowd_envelope_source_slots_and_regrowth() @test {
    @pool() {
        AssetStore assets = animated_lod_store();
        defer asset::destroy_asset_store(&assets);
        PartsFixture fixture = animated_crowd_fixtures::add_parts_fixture(&assets)!!;
        Scene scene = scene::create_scene(mem, { .max_nodes = 64 });
        defer scene::destroy_scene(&scene);
        Node* owner = scene.add_node(name: "crowd_lod")!!;
        owner.local.position = animated_crowd_fixtures::PARTS_ROOT_POSITION;
        CrowdInstance[2] instances = {
            { .placement = maths::TRANSFORM_IDENTITY, .pose = { .clip = fixture.posing, .time = 0.75f, .speed = 1, .loop = true }, .color = { 1, 1, 1, 1 } },
            { .placement = maths::TRANSFORM_IDENTITY, .pose = { .clip = fixture.posing, .time = 0.25f, .speed = 1, .loop = true }, .color = { 0.5f, 0.7f, 1, 1 } },
        };
        instances[0].placement.scale = { -2, 3, 0.5f };
        instances[1].placement.position.x = 50;
        model::attach_crowd(
            assets: &assets,
            scene: &scene,
            node: owner,
            model: fixture.mixed,
            capacity: 4,
            pose_bounds: animated_crowd_fixtures::PARTS_POSE_BOUNDS,
            instances: instances[..],
        )!!;
        model::attach_animated_lod(
            assets: &assets,
            scene: &scene,
            owner: owner,
            desc: animated_crowd_fixtures::parts_lod_desc(&assets, fixture.mixed, permuted: true),
        )!!;
        LodGroupState* state = scene.get(owner, LodGroup).state;
        ulong identity = state.identity;
        uint descriptor = state.descriptor_revision;
        assert(state.count == 0);
        model::prepare_crowd(&assets, &scene, owner)!!;
        scene.update_world();
        Ray ray = { .origin = { 10, 0, 10 }, .direction = { 0, 0, -1 } };
        PickOptions options = { .precision = PickPrecision.TRIANGLES, .faces = PickFaces.BOTH, .layers = uint::max };
        PickHit[] initial = spatial::pick(
            allocator: tmem,
            assets: &assets,
            scene: &scene,
            ray: ray,
            options: options,
        );
        assert(state.count == 2 && initial.len == 5);
        SceneIndex index = spatial::create_scene_index(mem, 10);
        defer spatial::destroy_scene_index(&index);
        index.refresh(&assets, &scene)!!;
        assert(index.count == 10 && index.dangling == 0);
        uint generation = state.slot_generations[0];
        uint[10] seen;
        foreach (entry : index.entries[:index.count]) {
            assert(entry.node == owner && entry.flags.lod_group && entry.flags.instanced);
            assert(!entry.flags.static_triangles && entry.instance_index < 2);
            assert(entry.part_index < 5 && c3d::same_id(entry.geometry, fixture.geometries[entry.part_index]));
            seen[5 * entry.instance_index + entry.part_index]++;
            Aabb expected = entry.instance_index == 0
              ? (Aabb){ .min = { -14, -9, -4 }, .max = { 22, 18, 0 } }
              : (Aabb){ .min = { 54, -3, -6 }, .max = { 72, 6, 2 } };
            assert(entry.bounds.min == expected.min && entry.bounds.max == expected.max);
        }
        foreach (count : seen) assert(count == 1);
        PickHit[] indexed = index.pick(
            allocator: tmem,
            assets: &assets,
            ray: ray,
            options: options,
        );
        animated_lod_query_equal(initial, indexed);
        foreach (hit : initial) assert(hit.instance_index == 0 && !hit.triangle_hit);
        ray.origin.x = 60;
        PickHit[] second = spatial::pick(
            allocator: tmem,
            assets: &assets,
            scene: &scene,
            ray: ray,
            options: options,
        );
        assert(second.len == 5);
        foreach (hit : second) assert(hit.instance_index == 1 && hit.node == owner);
        model::set_crowd(
            assets: &assets,
            scene: &scene,
            node: owner,
            instances: instances[:1],
        )!!;
        index.refresh(&assets, &scene)!!;
        assert(index.count == 5 && state.count == 1 && state.slot_generations[0] != generation);
        model::set_crowd(
            assets: &assets,
            scene: &scene,
            node: owner,
            instances: instances[..],
        )!!;
        index.refresh(&assets, &scene)!!;
        assert(index.count == 10 && state.count == 2);
        assert(state.identity == identity && state.descriptor_revision == descriptor);
        foreach (entry : index.entries[:index.count]) {
            assert(entry.node == owner && entry.part_index < 5 && entry.instance_index < 2);
        }
    };
}

fn void test_animated_lod_queries_skip_whole_missing_source_without_base_duplicates() @test {
    @pool() {
        AssetStore assets = animated_lod_store();
        defer asset::destroy_asset_store(&assets);
        PartsFixture fixture = animated_crowd_fixtures::add_parts_fixture(&assets)!!;
        Scene scene = scene::create_scene(mem, { .max_nodes = 64 });
        defer scene::destroy_scene(&scene);
        SceneIndex index = spatial::create_scene_index(mem, 5);
        defer spatial::destroy_scene_index(&index);
        for (uint missing = 0; missing < 3; missing++) {
            Node* owner = model::instantiate(&assets, &scene, fixture.mixed)!!;
            model::attach_animated_lod(
                assets: &assets,
                scene: &scene,
                owner: owner,
                desc: animated_crowd_fixtures::parts_lod_desc(&assets, fixture.mixed, permuted: true),
            )!!;
            scene.update_world();
            index.refresh(&assets, &scene)!!;
            assert(index.count == 5);
            ModelInstance* instance = scene.get(owner, ModelInstance);
            if (missing < 2) {
                scene.remove(instance.present_node(missing == 0 ? 4u : 0u));
            } else {
                assets.remove_geometry(fixture.geometries[2]);
            }
            Ray ray = { .origin = { 6, 0.5f, 10 }, .direction = { 0, 0, -1 } };
            PickHit[] direct = spatial::pick(
                allocator: tmem,
                assets: &assets,
                scene: &scene,
                ray: ray,
            );
            PickHit[] indexed = index.pick(
                allocator: tmem,
                assets: &assets,
                ray: ray,
            );
            assert(direct.len == 0 && indexed.len == 0);
            spatial::prepare_triangle_picks(&assets, &scene);
            index.refresh(&assets, &scene)!!;
            assert(index.count == 0 && index.dangling == 1);
            scene.remove(owner);
        }
    };
}
