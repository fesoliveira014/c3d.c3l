module c3d::serial::test_described;

import std::math::vector;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::asset::gltf;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::model;
import c3d::scene;
import c3d::serial;

const char[] IMPORT_EVENT_CODEC_MODEL @local
  = $embed("../../../test/fixtures/animation_events/gltf-events-v1.gltf");

fn AssetStore import_event_codec_store() @local {
    return asset::create_asset_store(mem, {
        .max_geometries = 8, .max_textures = 8, .max_materials = 8, .max_samplers = 8,
        .max_models = 2, .max_skeletons = 2, .max_clips = 8,
    });
}

fn ModelId import_event_codec_model(AssetStore* assets) @local {
    ModelId id = gltf::load_model_memory(
        assets: assets,
        bytes: IMPORT_EVENT_CODEC_MODEL,
        base_dir: "",
        key: "event-model.gltf",
    )!!;
    Geometry box = geometry::box(
        allocator: tmem,
        width: 1,
        height: 1,
        depth: 1,
    );
    GeometryId geometry_id = assets.add_geometry(&box, "event-model.gltf/carrier_box")!!;
    MaterialId material_id = assets.add_material(material::basic({}), "event-model.gltf/carrier_material")!!;
    ModelTemplate* template = &assets.model(id).data;
    uint carrier;
    bool found;
    foreach (uint index, node : template.nodes) {
        if (node.name == "carrier") {
            carrier = index;
            found = true;
        }
    }
    assert(found && template.meshes.len == 0);
    template.meshes = alloc::new_array(assets.allocator, ModelMesh, 1);
    template.meshes[0] = { .node = carrier, .geometry = geometry_id, .material = material_id };
    return id;
}

fn Node* import_event_codec_child(Node* owner, String name) @local {
    for (Node* child = owner.first_child; child; child = child.next_sibling) {
        if (child.name == name) return child;
    }
    unreachable("Missing imported-event owner");
}

fn void test_import_events_codec_keyed_binary_and_jsonc_restore_destination_tables_and_restart_owners() @test {
    @pool() {
        serial::register_core_codecs()!!;
        AssetStore source_assets = import_event_codec_store();
        defer asset::destroy_asset_store(&source_assets);
        AssetStore destination_assets = import_event_codec_store();
        defer asset::destroy_asset_store(&destination_assets);
        AnimationClip unrelated = { .name = "unrelated".copy(mem), .duration = 1 };
        destination_assets.add_clip_owned(&unrelated, "destination-only/clip")!!;
        ModelId source_model = import_event_codec_model(&source_assets);
        ModelId destination_model = import_event_codec_model(&destination_assets);
        ClipId source_clip = source_assets.model(source_model).data.clips[0];
        ClipId destination_clip = destination_assets.model(destination_model).data.clips[0];
        assert(source_clip.index != destination_clip.index);
        assert(c3d::same_id(destination_assets.find_clip("event-model.gltf#anim/0")!!, destination_clip));
        Scene source = scene::create_scene(mem, { .max_nodes = 32 });
        defer scene::destroy_scene(&source);
        Scene destination = scene::create_scene(mem, { .max_nodes = 32 });
        defer scene::destroy_scene(&destination);
        Node* tree = source.add_node(name: "imported_event_owners")!!;
        Node* ordinary = model::instantiate(
            assets: &source_assets,
            scene: &source,
            model: source_model,
            parent: tree,
            name: "ordinary",
        )!!;
        Animator* animator = anim::add_animator(&source, ordinary);
        AnimationActionId id = animator.play(&source_assets, source_clip)!!;
        animator.action(id).weight = 0.5f;
        Node* crowded = source.add_node(tree, "crowd")!!;
        CrowdInstance[1] seeds = { {
            .placement = maths::TRANSFORM_IDENTITY,
            .pose = { .clip = source_clip, .time = 0.25f, .speed = 1, .loop = false },
            .color = { 1, 1, 1, 1 },
        } };
        model::attach_crowd(
            assets: &source_assets,
            scene: &source,
            node: crowded,
            model: source_model,
            capacity: 2,
            pose_bounds: { .min = { -2, -2, -2 }, .max = { 2, 3, 4 } },
            instances: seeds[..],
            event_capacity: 16,
        )!!;
        model::prepare_crowd(&source_assets, &source, crowded)!!;
        anim::update(&source_assets, &source, 0.75f);
        anim::crowd_update(&source_assets, &source, 0.375f);
        AnimatedCrowd* original_crowd = source.get(crowded, AnimatedCrowd);
        Action ordinary_before = *animator.action(id);
        CrowdPlaybackSlot crowd_before = original_crowd.playback.slots[0];
        Action crowd_action_before = *crowd_before.actions.get(crowd_before.base_action);
        ClipEvent[5] source_events;
        ClipEvent* event_pointer = source_assets.clip(source_clip).data.events.ptr;
        source_events[..] = source_assets.clip(source_clip).data.events[..];
        FiredEvent[] ordinary_events = alloc::clone_slice(tmem, animator.events[:animator.event_count]);
        CrowdEvent[] retained_crowd_events = original_crowd.playback.events[:original_crowd.playback.event_count];
        CrowdEvent[] crowd_events = alloc::clone_slice(tmem, retained_crowd_events);
        char[] bytes = serial::write_subtree(
            allocator: tmem,
            scene: &source,
            assets: &source_assets,
            root: tree,
        )!!;
        String text = serial::write_subtree_text(
            allocator: tmem,
            scene: &source,
            assets: &source_assets,
            root: tree,
        )!!;
        assert(mem::equals(&ordinary_before, animator.action(id), Action::size));
        assert(mem::equals(&crowd_action_before, crowd_before.actions.get(crowd_before.base_action), Action::size));
        assert(source_assets.clip(source_clip).data.events.ptr == event_pointer);
        assert(mem::equals(source_events[..], source_assets.clip(source_clip).data.events));
        assert(animator.event_count == ordinary_events.len);
        assert(mem::equals(ordinary_events.ptr, animator.events.ptr, ordinary_events.len * FiredEvent::size));
        assert(original_crowd.playback.event_count == crowd_events.len);
        assert(mem::equals(crowd_events.ptr, original_crowd.playback.events.ptr, crowd_events.len * CrowdEvent::size));
        for (uint encoding = 0; encoding < 2; encoding++) {
            Node* restored = encoding == 0
              ? serial::read_subtree(&destination, &destination_assets, bytes)!!
              : serial::read_subtree_text(&destination, &destination_assets, text)!!;
            Node* restored_ordinary = import_event_codec_child(restored, "ordinary");
            Node* restored_crowd = import_event_codec_child(restored, "crowd");
            Animator* loaded = destination.get(restored_ordinary, Animator);
            assert(loaded.action_count == 1);
            Action* action = loaded.action(loaded.order[0]);
            assert(c3d::same_id(action.clip, destination_clip) && action.time == 0 && loaded.event_count == 0);
            assert(action.weight == 0.5f && action.loop);
            AnimatedCrowd* crowd = destination.get(restored_crowd, AnimatedCrowd);
            assert(!crowd.is_prepared() && crowd.start_times[0] == 0.25f);
            model::prepare_crowd(&destination_assets, &destination, restored_crowd)!!;
            CrowdPlaybackSlot* slot = &crowd.playback.slots[0];
            assert(c3d::same_id(slot.actions.get(slot.base_action).clip, destination_clip));
            assert(slot.actions.get(slot.base_action).time == 0.25f && crowd.playback.event_count == 0);
            anim::update(&destination_assets, &destination, 1);
            uint[5] expected = { 0, uint::max, 3, 3, 9 };
            assert(loaded.event_count == 5 && loaded.events_dropped == 0);
            foreach (index, event : loaded.events[:loaded.event_count]) {
                assert(event.id == expected[index] && c3d::same_id(event.clip, destination_clip));
            }
            anim::crowd_update(&destination_assets, &destination, 0.75f);
            uint[4] crowd_expected = { uint::max, 3, 3, 9 };
            assert(crowd.playback.event_count == 4 && crowd.playback.events_dropped == 0);
            foreach (index, event : crowd.playback.events[:crowd.playback.event_count]) {
                assert(event.event.id == crowd_expected[index]);
                assert(c3d::same_id(event.event.clip, destination_clip));
            }
            destination.remove(restored);
        }
        destination_assets.remove_clip(destination_clip);
        Node* existing = destination.add_node(name: "existing")!!;
        existing.local.position = { 3, 5, 7 };
        uint free_before = destination.world.entities.free_count;
        for (uint encoding = 0; encoding < 2; encoding++) {
            Node*? restored = encoding == 0
              ? serial::read_subtree(&destination, &destination_assets, bytes)
              : serial::read_subtree_text(&destination, &destination_assets, text);
            assert(@catch(restored) == c3d::INVALID_ID);
            assert(destination.world.entities.free_count == free_before);
            assert(destination.root.first_child == existing && existing.next_sibling == null);
            assert(existing.local.position == (Vec3){ 3, 5, 7 });
            assert(destination.count(Animator) == 0 && destination.count(AnimatedCrowd) == 0);
        }
        assert(source_assets.clip(source_clip).data.events.ptr == event_pointer);
        assert(mem::equals(source_events[..], source_assets.clip(source_clip).data.events));
        assert(mem::equals(&ordinary_before, animator.action(id), Action::size));
    };
}
