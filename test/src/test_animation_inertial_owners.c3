module c3d::test::anim;

import c3d;
import c3d::anim @public;
import c3d::asset;
import c3d::maths;
import c3d::model;
import c3d::scene;

struct InertialOwnerAllocationProbe (Allocator) @local {
    Allocator backing;
    uint acquisitions;
    uint failure;
    uint outstanding;
}

fn void*? InertialOwnerAllocationProbe.acquire(
    &self,
    sz size,
    AllocInitType init_type,
    sz alignment,
) @dynamic {
    if (++self.acquisitions == self.failure) return mem::OUT_OF_MEMORY~;
    void* pointer = self.backing.acquire(size, init_type, alignment)!;
    self.outstanding++;
    return pointer;
}

fn void*? InertialOwnerAllocationProbe.resize(
    &self,
    void* pointer,
    sz size,
    sz alignment,
) @dynamic {
    if (++self.acquisitions == self.failure) return mem::OUT_OF_MEMORY~;
    return self.backing.resize(pointer, size, alignment);
}

fn void InertialOwnerAllocationProbe.release(&self, void* pointer, bool aligned) @dynamic {
    self.backing.release(pointer, aligned);
    self.outstanding--;
}

fn bool inertial_owner_allocation_is_live(TrackingAllocator* tracker, void* pointer) @local {
    @pool() {
        foreach (allocation : tracker.allocations_tlist(tmem)) {
            if (allocation.ptr == pointer) return true;
        }
    };
    return false;
}

fn void test_animation_inertial_owners_animator_opt_in_has_one_private_row_and_removal_frees_it() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        LayerFixture fixture;
        create_layer_fixture(&fixture, &tracker);
        defer destroy_layer_fixture(&fixture);
        assert(fixture.animator.inertial_storage == null);
        sz disabled_bytes = tracker.allocated();
        fixture.scene.remove_component(fixture.root, Animator);
        sz without_animator = tracker.allocated();
        Animator* disabled = anim::add_animator(&fixture.scene, fixture.root);
        assert(disabled.inertial_storage == null && tracker.allocated() == disabled_bytes);
        fixture.scene.remove_component(fixture.root, Animator);
        assert(tracker.allocated() == without_animator);
        Animator* enabled = anim::add_animator(&fixture.scene, fixture.root, { .inertia_enabled = true });
        InertialStorage* storage = enabled.inertial_storage;
        assert(storage && storage.rows.len == 1 && storage.nodes == 4 && storage.morphs == 1);
        assert(tracker.allocated() == disabled_bytes + (sz)storage.bytes
          + (sz)anim::pose_derivative_storage_bytes(enabled.pose_storage.scratch.derivative));
        assert(storage.rows[0].control.generation == fixture.root.id.generation);
        assert(!storage.rows[0].control.history_valid && !storage.rows[0].control.active);
        assert(storage.rows[0].previous_pose.ptr != enabled.pose_storage.destination.pose.ptr);
        void* block = storage;
        assert(inertial_owner_allocation_is_live(&tracker, block));
        ClipId clip = layer_translation(&fixture, { 1, 2, 3 });
        enabled.play(&fixture.assets, clip, { .additive = true })!!;
        fixture.scene.remove_component(fixture.root, Animator);
        assert(!inertial_owner_allocation_is_live(&tracker, block));
        assert(tracker.allocated() == without_animator);
        enabled = anim::add_animator(&fixture.scene, fixture.root, { .inertia_enabled = true });
        block = enabled.inertial_storage;
        fixture.scene.remove(fixture.root);
        assert(!inertial_owner_allocation_is_live(&tracker, block));
    }
    assert(!tracker.has_leaks());
}

fn void test_animation_inertial_owners_prepared_crowd_reserves_capacity_and_replacement_resets_incarnations() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        LayerFixture fixture;
        create_layer_fixture(&fixture, &tracker);
        defer destroy_layer_fixture(&fixture);
        ClipId clip = fixture.assets.model(fixture.model).data.clips[0];
        CrowdInstance[2] seeds = {
            {
                .placement = maths::TRANSFORM_IDENTITY,
                .pose = { .clip = clip, .speed = 1, .loop = true },
                .color = { 1, 1, 1, 1 },
            },
            {
                .placement = maths::TRANSFORM_IDENTITY,
                .pose = { .clip = clip, .time = 0.25f, .speed = 1, .loop = true },
                .color = { 1, 1, 1, 1 },
            },
        };
        for (uint enabled = 0; enabled < 2; enabled++) {
            Node* owner = fixture.scene.add_node(name: "inertial_crowd")!!;
            model::attach_crowd(
                assets: &fixture.assets,
                scene: &fixture.scene,
                node: owner,
                model: fixture.model,
                capacity: 4,
                pose_bounds: { .min = { -4, -4, -4 }, .max = { 4, 4, 4 } },
                instances: seeds[..],
                actions_per_instance: 4,
                event_capacity: 0,
            )!!;
            AnimatedCrowd* crowd = fixture.scene.get(owner, AnimatedCrowd);
            crowd.inertia_enabled = enabled != 0;
            assert(!crowd.is_prepared());
            model::prepare_crowd(&fixture.assets, &fixture.scene, owner)!!;
            if (!enabled) {
                assert(crowd.playback.inertial_storage == null);
                fixture.scene.remove(owner);
                continue;
            }
            InertialStorage* storage = crowd.playback.inertial_storage;
            assert(storage && storage.rows.len == 4 && crowd.count == 2);
            assert(storage.nodes == 4 && storage.morphs == 1);
            foreach (index, &row : storage.rows) {
                assert(row.control.generation == crowd.playback.slots[index].generation);
                assert(!row.control.history_valid && !row.control.active);
                row.control.history_valid = true;
                row.control.active = true;
                row.root.target_rate_pending = true;
                row.velocity[0].translation = { (double)index + 1, 2, 3 };
                row.morph_offset[0] = (double)index + 5;
            }
            assert(storage.rows[0].previous_pose.ptr != crowd.playback.poses.ptr);
            assert(storage.rows[0].previous_pose.ptr != crowd.playback.pose_storage.destination.pose.ptr);
            CrowdInstanceId stale = crowd.playback.instance_id(0)!!;
            void* block = storage;
            uint[4] generations;
            foreach (index, slot : crowd.playback.slots) generations[index] = slot.generation;
            seeds[0].pose.time = 0.5f;
            model::set_crowd(
                assets: &fixture.assets,
                scene: &fixture.scene,
                node: owner,
                instances: seeds[:1],
            )!!;
            assert(crowd.playback.inertial_storage == storage && storage.rows.len == 4 && crowd.count == 1);
            assert(@catch(crowd.playback.player(stale)) == c3d::INVALID_ID);
            foreach (index, row : storage.rows) {
                assert(crowd.playback.slots[index].generation == generations[index] + 1);
                assert(row.control.generation == crowd.playback.slots[index].generation);
                assert(!row.control.history_valid && !row.control.active && !row.root.target_rate_pending);
                assert(row.velocity[0].translation == (double[<3>]){} && row.morph_offset[0] == 0);
            }
            fixture.scene.remove(owner);
            assert(!inertial_owner_allocation_is_live(&tracker, block));
        }
    }
    assert(!tracker.has_leaks());
}

fn void test_animation_inertial_owners_crowd_creation_failure_at_every_allocation_releases_reserved_rows() @test {
    NodeTemplate[4] nodes;
    foreach (&node : nodes) *node = { .parent = -1, .local = maths::TRANSFORM_IDENTITY };
    float[2] morphs = { 0.25f, 0.75f };
    ModelMesh[1] meshes = { { .node = 3, .default_morph_weights = morphs[..] } };
    ModelTemplate template = { .nodes = nodes[..], .meshes = meshes[..] };
    Transform[4] placements;
    placements[..] = maths::TRANSFORM_IDENTITY;
    foreach (capacity : (uint[2]){ 1, 4 }) {
        foreach (actions : (uint[2]){ 4, 16 }) {
            InertialOwnerAllocationProbe probe = { .backing = mem };
            CrowdPlaybackState* state = anim::create_crowd_playback(
                allocator: &probe,
                template: &template,
                placements: placements[:capacity],
                actions_per_instance: actions,
                event_capacity: 0,
                inertia_enabled: true,
            )!!;
            uint acquisitions = probe.acquisitions;
            assert(state.inertial_storage.rows.len == capacity && state.inertial_storage.morphs == 2);
            foreach (index, row : state.inertial_storage.rows) {
                assert(row.control.generation == state.slots[index].generation);
            }
            anim::destroy_crowd_playback(state);
            assert(probe.outstanding == 0);
            for (uint failure = 1; failure <= acquisitions; failure++) {
                InertialOwnerAllocationProbe failing = { .backing = mem, .failure = failure };
                assert(@catch(anim::create_crowd_playback(
                    allocator: &failing,
                    template: &template,
                    placements: placements[:capacity],
                    actions_per_instance: actions,
                    event_capacity: 0,
                    inertia_enabled: true,
                )) == c3d::CAPACITY_EXCEEDED);
                assert(failing.acquisitions == failure && failing.outstanding == 0);
            }
        }
    }
}
