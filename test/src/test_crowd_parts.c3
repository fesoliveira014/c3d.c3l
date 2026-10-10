module c3d::test::crowd_parts;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::geometry;
import c3d::maths;
import c3d::model;
import c3d::render;
import c3d::scene;
import c3d::shader;
import c3d::spatial;
import c3d::test::animated_crowd_fixtures;
import std::math;
import std::math::quaternion;

const float POINT_TOLERANCE @local = 1e-4f;
const uint NODE_CAPACITY @local = 64;
const uint SIGNED_TARGET_COUNT @local = 10;
const uint SIGNED_CHANNEL_COUNT @local = 5;
const uint[8] SIGNED_SELECTED_TARGETS @local = { 9, 7, 5, 8, 3, 6, 1, 4 };
const float[2][8] SIGNED_SELECTED_WEIGHTS @local = {
    { 3.5f, 3, 2.5f, -2.5f, 2, -2, 1.5f, -1.5f },
    { 4, 3.5f, 3, -3, 2.5f, -2.5f, 2, -2 },
};
const float[2][5] SIGNED_CHANNEL_WEIGHTS @local = {
    { 1.25f, 1.5f, 1.75f, 2, 2.25f },
    { 1.5f, 1.75f, 2, 2.25f, 2.5f },
};

struct PartsAllocationProbe (Allocator) @local {
    Allocator backing;
    bool enforce_limit;
    uint remaining;
    sz outstanding;
}

fn void*? PartsAllocationProbe.acquire(
    &self,
    sz size,
    AllocInitType init_type,
    sz alignment,
) @dynamic {
    if (self.enforce_limit && !self.remaining) return mem::OUT_OF_MEMORY~;
    if (self.enforce_limit) self.remaining--;
    void* pointer = self.backing.acquire(size, init_type, alignment)!;
    self.outstanding++;
    return pointer;
}

fn void*? PartsAllocationProbe.resize(
    &self,
    void* pointer,
    sz size,
    sz alignment,
) @dynamic {
    if (self.enforce_limit && !self.remaining) return mem::OUT_OF_MEMORY~;
    if (self.enforce_limit) self.remaining--;
    return self.backing.resize(pointer, size, alignment);
}

fn void PartsAllocationProbe.release(&self, void* pointer, bool aligned) @dynamic {
    self.backing.release(pointer, aligned);
    self.outstanding--;
}

fn AssetStore parts_store() @local {
    return asset::create_asset_store(mem, {
        .max_geometries = 5,
        .max_textures = asset::BUILTIN_TEXTURE_COUNT,
        .max_materials = 1,
        .max_samplers = asset::BUILTIN_SAMPLER_COUNT,
        .max_models = 5,
        .max_skeletons = 3,
        .max_clips = 4,
        .max_environments = 1,
        .max_shaders = 1,
        .max_compute_shaders = 1,
        .max_fonts = 1,
    });
}

fn CrowdInstance parts_seed(ClipId clip, float time = 0) @local {
    return {
        .placement = maths::TRANSFORM_IDENTITY,
        .pose = { .clip = clip, .time = time, .speed = 0, .loop = false },
        .color = { 0.25f, 0.5f, 0.75f, 1 },
    };
}

fn CrowdPlayer parts_player(AnimatedCrowd* crowd, uint index = 0) @local {
    return crowd.playback.player(crowd.playback.instance_id(index)!!)!!;
}

fn Vec3 parts_morphed_vertex(
    AssetStore* assets,
    AnimatedCrowd* crowd,
    CrowdPart* part,
    uint instance,
    uint vertex,
) @local {
    GeometryId geometry_id = assets.model(crowd.model).data.meshes[part.mesh_index].geometry;
    Geometry* geometry = &assets.geometry(geometry_id).data;
    Vec3 position = geometry.positions[vertex];
    if (!part.weight_count) return position;
    usz offset = (usz)instance * crowd.morph_stride + part.weight_offset;
    MorphSelection selection = geometry::select_morph_targets(
        geometry.channels,
        crowd.morph_weights[offset:part.weight_count],
    );
    for (uint active = 0; active < selection.count; active++) {
        position += geometry.targets[selection.targets[active]].position_deltas[vertex] * selection.weights[active];
    }
    return position;
}

fn void assert_parts_vertices(
    AssetStore* assets,
    Scene* scene,
    Node* node,
    Vec3[] expected,
    bool skin_free,
) @local {
    AnimatedCrowd* crowd = scene.get(node, AnimatedCrowd);
    assert(crowd.parts.len == (skin_free ? 3 : animated_crowd_fixtures::PARTS_MESH_COUNT));
    assert(crowd.morph_stride == 2 && crowd.morph_weights.ptr == crowd.playback.weight_values.ptr);
    foreach (uint index, &part : crowd.parts) {
        Node* child = scene.node(part.batch);
        InstancedMesh* batch = scene.get(child, InstancedMesh);
        assert(batch.count == 1 && batch.transforms[0].position == crowd.placements[0].position);
        assert(child.local.position == (Vec3){} && child.local.scale == (Vec3){ 1, 1, 1 });
        assert(part.template_node == crowd.playback.mesh_nodes[part.mesh_index]);
        uint expected_part = skin_free ? index + 1 : index;
        Mat4 world = node.world.mul(crowd.part_transform(0, index));
        Geometry* geometry = &assets.geometry(batch.geometry).data;
        foreach (uint vertex, position : geometry.positions) {
            Mat4 vertex_world = world;
            if (part.skinned) {
                vertex_world = vertex_world.mul(crowd.palettes[geometry.joints[vertex].x]);
            }
            Vec3 actual = maths::transform_point(vertex_world, parts_morphed_vertex(
                assets: assets,
                crowd: crowd,
                part: part,
                instance: 0,
                vertex: vertex,
            ));
            Vec3 point = expected[expected_part * animated_crowd_fixtures::PARTS_VERTEX_COUNT + vertex];
            assert((actual - point).length() <= POINT_TOLERANCE);
        }
        if (part.weight_count) assert(part.weight_count == 1 && geometry.targets.len == 2);
    }
}

fn void test_crowd_parts_match_literal_mixed_and_skin_free_worlds() @test {
    AssetStore assets = parts_store();
    defer asset::destroy_asset_store(&assets);
    PartsFixture fixture = animated_crowd_fixtures::add_parts_fixture(&assets)!!;
    foreach (skin_free : (bool[2]){ false, true }) {
        Scene scene = scene::create_scene(mem, { .max_nodes = NODE_CAPACITY });
        defer scene::destroy_scene(&scene);
        CrowdInstance[1] instances = { parts_seed(fixture.posing) };
        Node* node = model::add_crowd(
            assets: &assets,
            scene: &scene,
            model: skin_free ? fixture.skin_free : fixture.mixed,
            capacity: 2,
            pose_bounds: animated_crowd_fixtures::PARTS_POSE_BOUNDS,
            instances: instances[..],
            trace: true,
        )!!;
        node.local.position = animated_crowd_fixtures::PARTS_ROOT_POSITION;
        scene.update_world();
        assert_parts_vertices(
            assets: &assets,
            scene: &scene,
            node: node,
            expected: animated_crowd_fixtures::PARTS_REST_POINTS[..],
            skin_free: skin_free,
        );
        AnimatedCrowd* crowd = scene.get(node, AnimatedCrowd);
        CrowdPlayer player = parts_player(crowd);
        player.base_action()!!.time = 1;
        anim::crowd_update(&assets, &scene, 0);
        assert_parts_vertices(
            assets: &assets,
            scene: &scene,
            node: node,
            expected: animated_crowd_fixtures::PARTS_POSED_POINTS[..],
            skin_free: skin_free,
        );
        instances[0] = parts_seed(fixture.missing_weights, 1);
        model::set_crowd(
            assets: &assets,
            scene: &scene,
            node: node,
            instances: instances[..],
        )!!;
        assert_parts_vertices(
            assets: &assets,
            scene: &scene,
            node: node,
            expected: animated_crowd_fixtures::PARTS_RESTORED_POINTS[..],
            skin_free: skin_free,
        );
        assert(crowd.start_times[0] == 1 && crowd.seeds[0].time == 1);
        assert(scene.count(InstancedMesh) == crowd.parts.len);
    }
}

fn void test_crowd_parts_validate_bind_bits_and_order_before_mutation() @test {
    AssetStore assets = parts_store();
    defer asset::destroy_asset_store(&assets);
    PartsFixture fixture = animated_crowd_fixtures::add_parts_fixture(&assets)!!;
    TrackingAllocator tracking;
    tracking.init(mem);
    defer tracking.free();
    Scene scene = scene::create_scene(&tracking, { .max_nodes = NODE_CAPACITY });
    defer scene::destroy_scene(&scene);
    CrowdInstance[1] instances = { parts_seed(fixture.posing) };
    Node* compatible = model::add_crowd(
        assets: &assets,
        scene: &scene,
        model: fixture.compatible_alias,
        capacity: 2,
        pose_bounds: animated_crowd_fixtures::PARTS_POSE_BOUNDS,
        instances: instances[..],
    )!!;
    assert(scene.get(compatible, AnimatedCrowd).parts.len == 5);
    uint free_nodes = scene.world.entities.free_count;
    sz bytes = tracking.allocated();
    foreach (model_id : (ModelId[2]){ fixture.reordered_joints, fixture.different_bind }) {
        assert(@catch(model::add_crowd(
            assets: &assets,
            scene: &scene,
            model: model_id,
            capacity: 2,
            pose_bounds: animated_crowd_fixtures::PARTS_POSE_BOUNDS,
            instances: instances[..],
        )) == c3d::INVALID_ARGUMENT);
        assert(scene.world.entities.free_count == free_nodes && tracking.allocated() == bytes);
    }
    Node* pending = scene.add_node()!!;
    model::attach_crowd(
        assets: &assets,
        scene: &scene,
        node: pending,
        model: fixture.mixed,
        capacity: 2,
        pose_bounds: animated_crowd_fixtures::PARTS_POSE_BOUNDS,
        instances: instances[..],
    )!!;
    ModelSkin* skin = &assets.model(fixture.mixed).data.skins[1];
    skin.skeleton = fixture.different_bind_skin;
    bytes = tracking.allocated();
    assert(@catch(model::prepare_crowd(&assets, &scene, pending)) == c3d::INVALID_ARGUMENT);
    assert(!scene.get(pending, AnimatedCrowd).is_prepared() && !pending.first_child);
    assert(tracking.allocated() == bytes);
    skin.skeleton = fixture.common_skin;
    model::prepare_crowd(&assets, &scene, pending)!!;
    assert(scene.get(pending, AnimatedCrowd).is_prepared());
}

fn void test_crowd_parts_capacity_and_default_width_validation() @test {
    AssetStore assets = parts_store();
    defer asset::destroy_asset_store(&assets);
    PartsFixture fixture = animated_crowd_fixtures::add_parts_fixture(&assets)!!;
    Scene scene = scene::create_scene(mem, { .max_nodes = NODE_CAPACITY });
    defer scene::destroy_scene(&scene);
    uint free_nodes = scene.world.entities.free_count;
    foreach (actions : (uint[2]){ 0, anim::MAX_ACTIONS + 1 }) {
        assert(@catch(model::add_crowd(
            assets: &assets,
            scene: &scene,
            model: fixture.mixed,
            capacity: 2,
            pose_bounds: animated_crowd_fixtures::PARTS_POSE_BOUNDS,
            actions_per_instance: actions,
        )) == c3d::INVALID_ARGUMENT);
        assert(scene.world.entities.free_count == free_nodes);
    }
    ModelMesh* mesh = &assets.model(fixture.mixed).data.meshes[2];
    float[] baseline = mesh.default_morph_weights;
    float[2] wrong = { 0.25f, 0.5f };
    mesh.default_morph_weights = wrong[..];
    assert(@catch(model::add_crowd(
        assets: &assets,
        scene: &scene,
        model: fixture.mixed,
        capacity: 2,
        pose_bounds: animated_crowd_fixtures::PARTS_POSE_BOUNDS,
    )) == c3d::INVALID_ARGUMENT);
    mesh.default_morph_weights = baseline;
    assert(scene.world.entities.free_count == free_nodes);
    CrowdInstance[1] instances = { parts_seed(fixture.posing) };
    Node* node = model::add_crowd(
        assets: &assets,
        scene: &scene,
        model: fixture.mixed,
        capacity: 2,
        pose_bounds: animated_crowd_fixtures::PARTS_POSE_BOUNDS,
        instances: instances[..],
        actions_per_instance: 1,
        event_capacity: 0,
    )!!;
    AnimatedCrowd* crowd = scene.get(node, AnimatedCrowd);
    assert(crowd.playback.events.len == 0 && crowd.playback.slots[0].actions.items.len == 1);
    CrowdPlayer player = parts_player(crowd);
    assert(@catch(player.play(&assets, fixture.missing_weights)) == c3d::CAPACITY_EXCEEDED);
}

fn void test_crowd_parts_set_rolls_back_and_keeps_stale_handles_stale() @test {
    AssetStore assets = parts_store();
    defer asset::destroy_asset_store(&assets);
    PartsFixture fixture = animated_crowd_fixtures::add_parts_fixture(&assets)!!;
    PartsAllocationProbe probe = { .backing = mem };
    Scene scene = scene::create_scene(&probe, { .max_nodes = NODE_CAPACITY });
    CrowdInstance[2] instances = { parts_seed(fixture.posing, 0.25f), parts_seed(fixture.posing, 0.5f) };
    Node* node = model::add_crowd(
        assets: &assets,
        scene: &scene,
        model: fixture.mixed,
        capacity: 3,
        pose_bounds: animated_crowd_fixtures::PARTS_POSE_BOUNDS,
        instances: instances[..],
        actions_per_instance: 1,
        event_capacity: 0,
    )!!;
    AnimatedCrowd* crowd = scene.get(node, AnimatedCrowd);
    CrowdPlaybackState* state = crowd.playback;
    CrowdInstanceId old_instance = state.instance_id(0)!!;
    CrowdPlayer old_player = state.player(old_instance)!!;
    AnimationActionId old_action = state.slots[0].base_action;
    Action* items = state.slots[0].actions.items.ptr;
    sz outstanding = probe.outstanding;
    instances[0] = parts_seed(fixture.missing_weights, 0.75f);
    instances[1] = parts_seed(fixture.missing_weights, 0.625f);
    foreach (allowance : (uint[2]){ 0, 1 }) {
        probe.enforce_limit = true;
        probe.remaining = allowance;
        assert(@catch(model::set_crowd(
            assets: &assets,
            scene: &scene,
            node: node,
            instances: instances[..],
        )) == c3d::CAPACITY_EXCEEDED);
        probe.enforce_limit = false;
        assert(probe.outstanding == outstanding && crowd.playback == state && crowd.count == 2);
        assert(crowd.start_times[0] == 0.25f && old_player.try_action(old_action)!!.time == 0.25f);
        assert(state.instance_id(0)!!.generation == old_instance.generation);
    }
    model::set_crowd(
        assets: &assets,
        scene: &scene,
        node: node,
        instances: instances[..],
    )!!;
    assert(crowd.playback == state && state.slots[0].actions.items.ptr == items);
    assert(@catch(state.player(old_instance)) == c3d::INVALID_ID);
    CrowdPlayer replacement = parts_player(crowd);
    assert(@catch(replacement.try_action(old_action)) == c3d::INVALID_ID);
    CrowdInstanceId before_shrink = state.instance_id(1)!!;
    model::set_crowd(
        assets: &assets,
        scene: &scene,
        node: node,
        instances: instances[:1],
    )!!;
    assert(@catch(state.player(before_shrink)) == c3d::INVALID_ID);
    model::set_crowd(
        assets: &assets,
        scene: &scene,
        node: node,
        instances: instances[..],
    )!!;
    assert(@catch(state.player(before_shrink)) == c3d::INVALID_ID);
    CrowdInstanceId before_reorder = state.instance_id(0)!!;
    CrowdInstance[2] reordered = { instances[1], instances[0] };
    model::set_crowd(
        assets: &assets,
        scene: &scene,
        node: node,
        instances: reordered[..],
    )!!;
    assert(@catch(state.player(before_reorder)) == c3d::INVALID_ID);
    assert(crowd.start_times[0] == 0.625f);
    state.slots[0].generation = uint::max;
    CrowdInstanceId wrapped = state.instance_id(0)!!;
    model::set_crowd(
        assets: &assets,
        scene: &scene,
        node: node,
        instances: reordered[..],
    )!!;
    assert(state.slots[0].generation == 1 && @catch(state.player(wrapped)) == c3d::INVALID_ID);
    scene::destroy_scene(&scene);
    assert(probe.outstanding == 0);
}

fn void test_crowd_parts_prepare_rolls_back_every_allocation_and_retries() @test {
    AssetStore assets = parts_store();
    defer asset::destroy_asset_store(&assets);
    PartsFixture fixture = animated_crowd_fixtures::add_parts_fixture(&assets)!!;
    PartsAllocationProbe probe = { .backing = mem };
    Scene scene = scene::create_scene(&probe, { .max_nodes = NODE_CAPACITY });
    Node* node = scene.add_node()!!;
    CrowdInstance[1] instances = { parts_seed(fixture.posing, 0.5f) };
    model::attach_crowd(
        assets: &assets,
        scene: &scene,
        node: node,
        model: fixture.mixed,
        capacity: 2,
        pose_bounds: animated_crowd_fixtures::PARTS_POSE_BOUNDS,
        instances: instances[..],
        actions_per_instance: 1,
        event_capacity: 0,
    )!!;
    AnimatedCrowd* crowd = scene.get(node, AnimatedCrowd);
    sz outstanding = probe.outstanding;
    uint free_nodes = scene.world.entities.free_count;
    bool succeeded;
    for (uint allowance = 0; allowance < 160; allowance++) {
        probe.enforce_limit = true;
        probe.remaining = allowance;
        if (catch excuse = model::prepare_crowd(&assets, &scene, node)) {
            probe.enforce_limit = false;
            assert(excuse == c3d::CAPACITY_EXCEEDED);
            assert(probe.outstanding == outstanding && scene.world.entities.free_count == free_nodes);
            assert(!crowd.is_prepared() && !crowd.parts.len && !node.first_child);
            assert(crowd.seeds[0].time == 0.5f && crowd.start_times[0] == 0.5f);
        } else {
            probe.enforce_limit = false;
            assert(crowd.is_prepared() && crowd.parts.len == 5);
            succeeded = true;
            break;
        }
    }
    assert(succeeded);
    sz ready = probe.outstanding;
    model::prepare_crowd(&assets, &scene, node)!!;
    assert(probe.outstanding == ready);
    scene::destroy_scene(&scene);
    assert(probe.outstanding == 0);
}

fn void test_crowd_parts_preserve_affine_shear_for_mirrored_placements() @test {
    AssetStore assets = parts_store();
    defer asset::destroy_asset_store(&assets);
    PartsFixture fixture = animated_crowd_fixtures::add_parts_fixture(&assets)!!;
    ModelTemplate* template = &assets.model(fixture.mixed).data;
    template.nodes[animated_crowd_fixtures::PARTS_RIGID_NODE].local.rotation =
      quaternion::from_axis_angle{float}({ 0, 0, 1 }, (float)math::PI / 4);
    Scene scene = scene::create_scene(mem, { .max_nodes = NODE_CAPACITY });
    defer scene::destroy_scene(&scene);
    CrowdInstance[1] instances = { parts_seed(fixture.posing, 1) };
    instances[0].placement.position = { 2, 0, -3 };
    instances[0].placement.scale = { -2, 3, 0.5f };
    instances[0].placement.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, (float)math::PI / 2);
    Node* node = model::add_crowd(
        assets: &assets,
        scene: &scene,
        model: fixture.mixed,
        capacity: 1,
        pose_bounds: animated_crowd_fixtures::PARTS_POSE_BOUNDS,
        instances: instances[..],
    )!!;
    node.local.position = animated_crowd_fixtures::PARTS_ROOT_POSITION;
    scene.update_world();
    AnimatedCrowd* crowd = scene.get(node, AnimatedCrowd);
    Mat4 affine = crowd.part_transform(0, 1);
    Vec3 axis_a = { affine.m00, affine.m10, affine.m20 };
    Vec3 axis_b = { affine.m01, affine.m11, affine.m21 };
    assert(math::abs(axis_a.dot(axis_b)) > 1 && affine.determinant() < 0);
    Vec3 actual = maths::transform_point(node.world.mul(affine), { 1, 0, 0 });
    float diagonal = math::sqrt(0.5f);
    Vec3 expected = { 12, 3 * (1 + diagonal), 3 + 4 * diagonal };
    assert((actual - expected).length() <= POINT_TOLERANCE);
}

fn void test_crowd_parts_accept_external_compatible_clip_without_track_budget() @test {
    AssetStore assets = parts_store();
    defer asset::destroy_asset_store(&assets);
    PartsFixture fixture = animated_crowd_fixtures::add_parts_fixture(&assets)!!;
    Scene scene = scene::create_scene(mem, { .max_nodes = NODE_CAPACITY });
    defer scene::destroy_scene(&scene);
    CrowdInstance[1] instances = { parts_seed(fixture.posing) };
    Node* node = model::add_crowd(
        assets: &assets,
        scene: &scene,
        model: fixture.mixed,
        capacity: 2,
        pose_bounds: animated_crowd_fixtures::PARTS_POSE_BOUNDS,
        instances: instances[..],
    )!!;
    ModelTemplate* template = &assets.model(fixture.mixed).data;
    AnimationClip clip = {
        .name = "external_wide".copy(mem),
        .duration = 1,
        .tracks = alloc::new_array(mem, Track, 4),
        .targets = alloc::new_array(mem, uint, 4),
    };
    uint[4] nodes = { 0, 1, 4, 5 };
    clip.targets[..] = nodes[..];
    foreach (uint index, &track : clip.tracks) {
        Vec3 base = template.nodes[nodes[index]].local.position;
        *track = {
            .target = index,
            .path = TargetPath.TRANSLATION,
            .interpolation = Interpolation.LINEAR,
            .times = alloc::new_array(mem, float, 2),
            .values = alloc::new_array(mem, float, 6),
        };
        track.times[0] = 0;
        track.times[1] = 1;
        float[6] values = { base.x, base.y, base.z, base.x + 1, base.y, base.z };
        track.values[..] = values[..];
    }
    ClipId external = assets.add_clip_owned(&clip, "animated_parts/external_wide")!!;
    assert(template.clips.len == 2);
    foreach (authored : template.clips) assert(!c3d::same_id(authored, external));
    instances[0] = parts_seed(external, 0.5f);
    model::set_crowd(
        assets: &assets,
        scene: &scene,
        node: node,
        instances: instances[..],
    )!!;
    CrowdPlayer player = parts_player(scene.get(node, AnimatedCrowd));
    assert(c3d::same_id(player.base_action()!!.clip, external));
    assert(player.base_action()!!.cursors.len == 4);
}

fn void test_crowd_parts_action_capacities_admit_exactly_the_prepared_slots() @test {
    AssetStore assets = parts_store();
    defer asset::destroy_asset_store(&assets);
    PartsFixture fixture = animated_crowd_fixtures::add_parts_fixture(&assets)!!;
    foreach (capacity : (uint[3]){ 1, anim::DEFAULT_CROWD_ACTIONS, anim::MAX_ACTIONS }) {
        Scene scene = scene::create_scene(mem, { .max_nodes = NODE_CAPACITY });
        defer scene::destroy_scene(&scene);
        CrowdInstance[1] seeds = { parts_seed(fixture.posing) };
        Node* node = model::add_crowd(
            assets: &assets,
            scene: &scene,
            model: fixture.mixed,
            capacity: 1,
            pose_bounds: animated_crowd_fixtures::PARTS_POSE_BOUNDS,
            instances: seeds[..],
            actions_per_instance: capacity,
            event_capacity: 0,
        )!!;
        AnimatedCrowd* crowd = scene.get(node, AnimatedCrowd);
        CrowdPlayer player = parts_player(crowd);
        AnimationActionId[anim::MAX_ACTIONS] actions;
        actions[0] = crowd.playback.slots[0].base_action;
        for (uint index = 1; index < capacity; index++) actions[index] = player.play(&assets, fixture.posing)!!;
        assert(crowd.playback.slots[0].action_count == capacity);
        float before = player.action(actions[0]).time;
        assert(@catch(player.play(&assets, fixture.posing)) == c3d::CAPACITY_EXCEEDED);
        ClipId[2] clips = { fixture.posing, fixture.missing_weights };
        float[2] positions = { 0, 1 };
        assert(@catch(player.add_blend_space(&assets, clips[..], positions[..])) == c3d::CAPACITY_EXCEEDED);
        assert(crowd.playback.slots[0].action_count == capacity && player.action(actions[0]).time == before);
        foreach (action : actions[:capacity]) assert(c3d::same_id(player.try_action(action)!!.clip, fixture.posing));
    }
}

fn GeometryId add_parts_signed_morph_geometry(AssetStore* assets, GeometryId source_id) @local {
    @pool() {
        Geometry* source = &assets.geometry(source_id).data;
        Geometry geometry = {
            .topology = Topology.TRIANGLES,
            .positions = alloc::clone_slice(tmem, source.positions),
            .normals = alloc::clone_slice(tmem, source.normals),
            .targets = alloc::new_array(tmem, MorphTarget, SIGNED_TARGET_COUNT),
            .channels = alloc::new_array(tmem, MorphChannel, SIGNED_CHANNEL_COUNT),
            .bounds = source.bounds,
        };
        foreach (index, &target : geometry.targets) {
            target.position_deltas = alloc::new_array(tmem, Vec3, source.positions.len);
            // The two omitted targets make an all-target bound observably wrong.
            target.position_deltas[..] = (Vec3){ 0, index == 0 || index == 2 ? 1024 : (float)index + 1, 0 };
        }
        foreach (uint index, &channel : geometry.channels) {
            channel.name = string::tformat("signed_channel_%s", index);
            channel.first_target = index * 2;
            channel.full_weights = alloc::new_array(tmem, float, 2);
            channel.full_weights[0] = 0.5f;
            channel.full_weights[1] = 1;
        }
        return assets.add_geometry(&geometry, "animated_parts/signed_morph")!!;
    };
}

fn ClipId add_parts_signed_weights_clip(AssetStore* assets) @local {
    AnimationClip clip = {
        .name = "signed_weights".copy(assets.allocator),
        .duration = 1,
        .targets = alloc::new_array(assets.allocator, uint, 1),
        .tracks = alloc::new_array(assets.allocator, Track, 1),
    };
    clip.targets[0] = animated_crowd_fixtures::PARTS_MORPH_A;
    clip.tracks[0] = {
        .target = 0,
        .path = TargetPath.MORPH_WEIGHTS,
        .interpolation = Interpolation.LINEAR,
        .times = alloc::new_array(assets.allocator, float, 2),
        .values = alloc::new_array(assets.allocator, float, SIGNED_CHANNEL_COUNT * 2),
    };
    clip.tracks[0].times[1] = 1;
    for (uint key = 0; key < 2; key++) {
        clip.tracks[0].values[key * SIGNED_CHANNEL_COUNT:SIGNED_CHANNEL_COUNT] = SIGNED_CHANNEL_WEIGHTS[1][..];
    }
    return assets.add_clip_owned(&clip)!!;
}

fn void test_crowd_parts_signed_top_eight_packing_and_bounds_match_literal_selection() @test {
    AssetStore assets = parts_store();
    defer asset::destroy_asset_store(&assets);
    PartsFixture fixture = animated_crowd_fixtures::add_parts_fixture(&assets)!!;
    GeometryId geometry_id = add_parts_signed_morph_geometry(&assets, fixture.geometries[2]);
    ModelMesh* mesh = &assets.model(fixture.mixed).data.meshes[2];
    mesh.geometry = geometry_id;
    alloc::free(assets.allocator, mesh.default_morph_weights.ptr);
    mesh.default_morph_weights = alloc::clone_slice(assets.allocator, SIGNED_CHANNEL_WEIGHTS[0][..]);
    ClipId weights_clip = add_parts_signed_weights_clip(&assets);
    Scene scene = scene::create_scene(mem, { .max_nodes = NODE_CAPACITY });
    defer scene::destroy_scene(&scene);
    CrowdInstance[2] instances = { parts_seed(fixture.missing_weights), parts_seed(weights_clip) };
    instances[1].placement.position = { 3, 2, -1 };
    instances[1].placement.scale = { -2, 3, 0.5f };
    Node* owner = model::add_crowd(
        assets: &assets,
        scene: &scene,
        model: fixture.mixed,
        capacity: 2,
        pose_bounds: { .min = { -6, -3, -4 }, .max = { 12, 50, 4 } },
        instances: instances[..],
    )!!;
    anim::crowd_update(&assets, &scene, 0);
    scene.update_world();
    AnimatedCrowd* crowd = scene.get(owner, AnimatedCrowd);
    CrowdPart* part = &crowd.parts[2];
    Geometry* geometry = &assets.geometry(geometry_id).data;
    assert(geometry.targets.len == SIGNED_TARGET_COUNT && part.weight_count == SIGNED_CHANNEL_COUNT);
    shader::MorphWeightsGpu[2] packed;
    render::pack_crowd_morphs(
        blocks: packed[..],
        crowd: crowd,
        part: 2,
        channels: geometry.channels,
    );
    Node* reference = scene.add_mesh(geometry_id, fixture.material)!!;
    Mesh* reference_mesh = scene.get(reference, Mesh);
    reference_mesh.morph_weights = alloc::new_array(scene.allocator, float, SIGNED_CHANNEL_COUNT);
    scene.update_world();
    foreach (uint source, block : packed) {
        assert(block.count == 8);
        foreach (uint active, target : SIGNED_SELECTED_TARGETS) {
            assert(block.indices[active] == target);
            assert(bitcast(block.weights[active], uint) == bitcast(SIGNED_SELECTED_WEIGHTS[source][active], uint));
        }
        reference_mesh.morph_weights[..] = SIGNED_CHANNEL_WEIGHTS[source][..];
        Aabb bounds = spatial::mesh_world_bounds(
            assets: &assets,
            node: reference,
            mesh: reference_mesh,
            skin: null,
        );
        float displacement = source == 0 ? 41 : 45.5f;
        assert(bounds.min == (Vec3){ 0, displacement, 0 });
        assert(bounds.max == (Vec3){ 1, displacement + 1, 0 });
        Node* batch_node = scene.node(part.batch);
        Aabb envelope = spatial::instanced_world_bounds(&assets, batch_node, scene.get(batch_node, InstancedMesh));
        Mat4 world = owner.world.mul(crowd.part_transform(source, 2));
        foreach (position : geometry.positions) {
            Vec3 point = maths::transform_point(world, position + (Vec3){ 0, displacement, 0 });
            for (uint axis = 0; axis < 3; axis++) {
                assert(point[axis] >= envelope.min[axis] && point[axis] <= envelope.max[axis]);
            }
        }
    }
}

fn void test_crowd_parts_rigid_and_morph_vertices_fit_mirrored_affine_envelopes() @test {
    AssetStore assets = parts_store();
    defer asset::destroy_asset_store(&assets);
    PartsFixture fixture = animated_crowd_fixtures::add_parts_fixture(&assets)!!;
    assets.model(fixture.mixed).data.nodes[animated_crowd_fixtures::PARTS_RIGID_NODE].local.rotation =
      quaternion::from_axis_angle{float}({ 0, 0, 1 }, (float)math::PI / 4);
    Scene scene = scene::create_scene(mem, { .max_nodes = NODE_CAPACITY });
    defer scene::destroy_scene(&scene);
    CrowdInstance[2] instances = { parts_seed(fixture.posing), parts_seed(fixture.posing) };
    instances[0].placement.position = { -4, 1, 2 };
    instances[1].placement.position = { 2, 0, -3 };
    instances[1].placement.scale = { -2, 3, 0.5f };
    instances[1].placement.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, 0.7f);
    Node* owner = model::add_crowd(
        assets: &assets,
        scene: &scene,
        model: fixture.mixed,
        capacity: 2,
        pose_bounds: animated_crowd_fixtures::PARTS_POSE_BOUNDS,
        instances: instances[..],
    )!!;
    owner.local.position = animated_crowd_fixtures::PARTS_ROOT_POSITION;
    AnimatedCrowd* crowd = scene.get(owner, AnimatedCrowd);
    float diagonal = math::sqrt(0.5f);
    for (uint phase = 0; phase < 3; phase++) {
        if (phase == 2) {
            foreach (&instance : instances) instance.pose = parts_seed(fixture.missing_weights, 1).pose;
            model::set_crowd(
                assets: &assets,
                scene: &scene,
                node: owner,
                instances: instances[..],
            )!!;
        } else {
            for (uint source = 0; source < 2; source++) parts_player(crowd, source).base_action()!!.time = (float)phase;
        }
        anim::crowd_update(&assets, &scene, 0);
        scene.update_world();
        Vec3[] literal = phase == 0 ? animated_crowd_fixtures::PARTS_REST_POINTS[..]
          : (phase == 1 ? animated_crowd_fixtures::PARTS_POSED_POINTS[..] : animated_crowd_fixtures::PARTS_RESTORED_POINTS[..]);
        float rigid_x = phase == 0 ? 0 : (phase == 1 ? 4 : 2);
        float rigid_y = phase == 2 ? 2 : 1;
        Vec3[3] rigid = {
            { rigid_x + 2 * diagonal, rigid_y + diagonal, 0 },
            { rigid_x - 2 * diagonal, rigid_y + diagonal, 0 },
            { rigid_x, rigid_y, 0 },
        };
        for (uint source = 0; source < 2; source++) {
            Mat4 placement = owner.world.mul(instances[source].placement.to_mat4());
            for (uint part_index = 1; part_index <= 3; part_index++) {
                CrowdPart* part = &crowd.parts[part_index];
                Node* batch_node = scene.node(part.batch);
                Aabb envelope = spatial::instanced_world_bounds(&assets, batch_node, scene.get(batch_node, InstancedMesh));
                Mat4 world = owner.world.mul(crowd.part_transform(source, part_index));
                for (uint vertex = 0; vertex < animated_crowd_fixtures::PARTS_VERTEX_COUNT; vertex++) {
                    Vec3 model_point = part_index == 1 ? rigid[vertex]
                      : literal[part_index * animated_crowd_fixtures::PARTS_VERTEX_COUNT + vertex]
                        - animated_crowd_fixtures::PARTS_ROOT_POSITION;
                    Vec3 expected = maths::transform_point(placement, model_point);
                    Vec3 actual = maths::transform_point(world, parts_morphed_vertex(
                        assets: &assets,
                        crowd: crowd,
                        part: part,
                        instance: source,
                        vertex: vertex,
                    ));
                    assert((actual - expected).length() <= POINT_TOLERANCE);
                    for (uint axis = 0; axis < 3; axis++) {
                        assert(expected[axis] >= envelope.min[axis] && expected[axis] <= envelope.max[axis]);
                    }
                }
            }
            Mat4 affine = crowd.part_transform(source, 1);
            Vec3 axis_x = { affine.m00, affine.m10, affine.m20 };
            Vec3 axis_y = { affine.m01, affine.m11, affine.m21 };
            assert(math::abs(axis_x.dot(axis_y)) > 1);
        }
    }
}

fn void assert_parts_admission_fault_preserves_scene(
    AssetStore* assets,
    Scene* scene,
    TrackingAllocator* tracking,
    ModelId model,
) @local {
    uint free_nodes = scene.world.entities.free_count;
    sz bytes = tracking.allocated();
    assert(@catch(model::add_crowd(
        assets: assets,
        scene: scene,
        model: model,
        capacity: 2,
        pose_bounds: animated_crowd_fixtures::PARTS_POSE_BOUNDS,
    )) == c3d::INVALID_ARGUMENT);
    assert(scene.world.entities.free_count == free_nodes && tracking.allocated() == bytes);
    assert(scene.count(AnimatedCrowd) == 0 && scene.count(InstancedMesh) == 0);
}

fn void test_crowd_parts_subset_joints_conflicting_channels_and_nan_defaults_fault_before_mutation() @test {
    AssetStore assets = parts_store();
    defer asset::destroy_asset_store(&assets);
    PartsFixture fixture = animated_crowd_fixtures::add_parts_fixture(&assets)!!;
    TrackingAllocator tracking;
    tracking.init(mem);
    defer tracking.free();
    Scene scene = scene::create_scene(&tracking, { .max_nodes = NODE_CAPACITY });
    defer scene::destroy_scene(&scene);
    ModelTemplate* template = &assets.model(fixture.mixed).data;
    ModelSkin* skin = &template.skins[1];
    ModelSkin original_skin = *skin;
    Skeleton* skeleton = &assets.skeleton(fixture.identical_skin).data;
    Skeleton original_skeleton = *skeleton;
    defer {
        *skin = original_skin;
        *skeleton = original_skeleton;
    }
    skin.skeleton = fixture.identical_skin;
    skin.joint_nodes = skin.joint_nodes[:1];
    skeleton.joint_names = skeleton.joint_names[:1];
    skeleton.parents = skeleton.parents[:1];
    skeleton.rest_pose = skeleton.rest_pose[:1];
    skeleton.inverse_bind = skeleton.inverse_bind[:1];
    assert_parts_admission_fault_preserves_scene(
        assets: &assets,
        scene: &scene,
        tracking: &tracking,
        model: fixture.mixed,
    );
    *skin = original_skin;
    *skeleton = original_skeleton;
    Geometry* geometry = &assets.geometry(fixture.geometries[2]).data;
    MorphChannel[] original_channels = geometry.channels;
    float[] original_defaults = template.meshes[2].default_morph_weights;
    float[] original_second_defaults = template.meshes[3].default_morph_weights;
    defer {
        geometry.channels = original_channels;
        template.meshes[2].default_morph_weights = original_defaults;
        template.meshes[3].default_morph_weights = original_second_defaults;
    }
    MorphChannel[2] conflicting = { original_channels[0], original_channels[0] };
    float[2] defaults = { 0.25f, 0.75f };
    geometry.channels = conflicting[..];
    template.meshes[2].default_morph_weights = defaults[..];
    template.meshes[3].default_morph_weights = defaults[..];
    assert_parts_admission_fault_preserves_scene(
        assets: &assets,
        scene: &scene,
        tracking: &tracking,
        model: fixture.mixed,
    );
    geometry.channels = original_channels;
    template.meshes[2].default_morph_weights = original_defaults;
    template.meshes[3].default_morph_weights = original_second_defaults;
    float[1] nonfinite = { bitcast(0x7fc00000u, float) };
    template.meshes[2].default_morph_weights = nonfinite[..];
    assert_parts_admission_fault_preserves_scene(
        assets: &assets,
        scene: &scene,
        tracking: &tracking,
        model: fixture.mixed,
    );
    assert(bitcast(template.meshes[2].default_morph_weights[0], uint) == 0x7fc00000u);
    template.meshes[2].default_morph_weights = original_defaults;
}
