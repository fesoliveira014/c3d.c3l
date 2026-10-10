module c3d::serial::test_described;

import c3d;
import c3d::anim;
import c3d::asset::gltf;
import c3d::camera;
import c3d::ecs;
import c3d::maths;
import c3d::model;
import c3d::scene;
import c3d::serial @public;
import std::math;

fn void test_crowd_authoring_round_trips_pending_and_restarts_captured_clocks() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;
        ModelId model_id = gltf::load_model(&fixture.assets, skin_fixture_path())!!;
        CrowdInstance[1] instances = { {
            .placement = maths::TRANSFORM_IDENTITY,
            .pose = { .clip = fixture.assets.model(model_id).data.clips[0], .time = 0.125f, .speed = 0.5f, .loop = true },
            .color = { 0.2f, 0.4f, 0.6f, 0.8f },
        } };
        Aabb bounds = { .min = { -1, -1, -1 }, .max = { 1, 1, 1 } };
        Node* source = model::add_crowd(
            assets: &fixture.assets,
            scene: &fixture.source,
            model: model_id,
            capacity: 3,
            pose_bounds: bounds,
            instances: instances[..],
            trace: true,
        )!!;
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
        anim::crowd_update(&fixture.assets, &fixture.source, 0.5f);
        AnimatedCrowd* original = fixture.source.get(source, AnimatedCrowd);
        assert(original.playback.slots[0].actions.get(original.playback.slots[0].base_action).time == 0.375f
          && original.start_times[0] == 0.125f);
        assert(text == serial::write_subtree_text(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: source,
        )!!);
        for (uint encoding = 0; encoding < 2; encoding++) {
            Node* restored = encoding == 0
              ? serial::read_subtree(&fixture.destination, &fixture.assets, bytes)!!
              : serial::read_subtree_text(&fixture.destination, &fixture.assets, text)!!;
            AnimatedCrowd* loaded = fixture.destination.get(restored, AnimatedCrowd);
            assert(!loaded.is_prepared() && restored.first_child == null);
            assert(loaded.count == 1 && loaded.placements.len == 3 && loaded.trace);
            assert(loaded.colors[0] == instances[0].color && loaded.colors[2] == (Vec4){ 1, 1, 1, 1 });
            assert(loaded.start_times[0] == 0.125f && loaded.seeds[0].time == 0.125f);
            assert(text == serial::write_subtree_text(
                allocator: tmem,
                scene: &fixture.destination,
                assets: &fixture.assets,
                root: restored,
            )!!);
            model::prepare_crowd(&fixture.assets, &fixture.destination, restored)!!;
            anim::crowd_update(&fixture.assets, &fixture.destination, 0.5f);
            loaded = fixture.destination.get(restored, AnimatedCrowd);
            assert(loaded.is_prepared() && loaded.parts.len == original.parts.len);
            assert(loaded.playback.slots[0].actions.get(loaded.playback.slots[0].base_action).time
              == original.playback.slots[0].actions.get(original.playback.slots[0].base_action).time);
            for (usz index = 0; index < loaded.joint_count; index++) {
                for (uint coefficient = 0; coefficient < 16; coefficient++) {
                    assert(math::abs(
                        loaded.palettes[index].m[coefficient] - original.palettes[index].m[coefficient],
                    ) < 1e-6f);
                }
            }
            assert(bytes == serial::write_subtree(
                allocator: tmem,
                scene: &fixture.destination,
                assets: &fixture.assets,
                root: restored,
            )!!);
            fixture.destination.remove(restored);
        }
        for (uint encoding = 0; encoding < 2; encoding++) {
            char[]? rejected = encoding == 0
              ? serial::write_subtree(
                  allocator: tmem,
                  scene: &fixture.source,
                  assets: &fixture.assets,
                  root: source.first_child,
              )
              : (char[])serial::write_subtree_text(
                  allocator: tmem,
                  scene: &fixture.source,
                  assets: &fixture.assets,
                  root: source.first_child,
              );
            if (catch excuse = rejected) {
                assert(excuse == c3d::INVALID_ARGUMENT);
            } else {
                assert(false);
            }
        }
        fixture.source.add(source.first_child, camera::perspective_deg(60, 0.1f));
        if (catch excuse = serial::write_subtree_text(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: source,
        )) {
            assert(excuse == c3d::INVALID_ARGUMENT);
        } else {
            assert(false);
        }
    };
}

fn void test_crowd_owned_array_failures_leave_existing_scene_unchanged() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;
        ModelId model_id = gltf::load_model(&fixture.assets, skin_fixture_path())!!;
        Node* node = fixture.destination.add_node(name: "existing")!!;
        node.local.position = { 1, 2, 3 };
        node.layers = 33;
        Entity identity = node.id;
        CrowdInstance[1] instances = { {
            .placement = maths::TRANSFORM_IDENTITY,
            .pose = { .clip = fixture.assets.model(model_id).data.clips[0], .time = 0.25f, .speed = 1, .loop = true },
            .color = { 1, 1, 1, 1 },
        } };
        CrowdAuthoringV3 source = {
            .actions_per_instance = anim::DEFAULT_CROWD_ACTIONS,
            .event_capacity = anim::DEFAULT_CROWD_EVENT_CAPACITY,
            .model = model_id, .capacity = 3, .instances = instances[..],
            .pose_bounds = { .min = { -1, -1, -1 }, .max = { 1, 1, 1 } },
        };
        ReadContext context = { .scene = &fixture.destination, .assets = &fixture.assets, .node = node };
        uint slot = ecs::assigned_slot(AnimatedCrowd)!!;
        for (uint failure = 1; failure <= 4; failure++) {
            FailingAllocator allocator = { .failure = failure };
            fixture.destination.allocator = &allocator;
            defer fixture.destination.allocator = mem;
            assert(@catch(serial::codecs[slot].described.codec.attach(&source, &context)) == c3d::CAPACITY_EXCEEDED);
            assert(allocator.attempts == failure && allocator.outstanding == 0);
            assert(!fixture.destination.has(node, AnimatedCrowd) && node.first_child == null);
            assert(c3d::same_id(node.id, identity) && node.local.position == (Vec3){ 1, 2, 3 } && node.layers == 33);
            assert(fixture.destination.root.first_child == node && node.name == "existing");
        }
        source.capacity = 0;
        assert(@catch(serial::codecs[slot].described.codec.attach(&source, &context)) == c3d::INVALID_ARGUMENT);
        assert(!fixture.destination.has(node, AnimatedCrowd) && node.first_child == null);
    };
}