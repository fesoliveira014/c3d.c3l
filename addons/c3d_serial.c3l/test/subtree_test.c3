module c3d::serial::test;

import c3d;
import c3d::asset;
import c3d::asset::custom;
import c3d::ecs;
import c3d::material;
import c3d::maths;
import c3d::scene;
import c3d::serial;
import std::math;

fn void test_ordinary_tree_round_trip_owns_values() @test {
    @pool() {
        Fixture fixture;
        init_fixture(&fixture);
        defer free_fixture(&fixture);
        Node* source = value_tree(&fixture);
        char[] bytes = serial::write_subtree(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: source,
        )!!;
        char[] repeated = serial::write_subtree(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: source,
        )!!;
        assert(bytes == repeated);
        Node* restored = serial::read_subtree(&fixture.destination, &fixture.assets, bytes)!!;
        assert(restored.name == "root");
        assert(restored.first_child.name == "second" && !restored.first_child.visible);
        Node* first = restored.first_child.next_sibling;
        assert(first.name == "first" && first.local.position == (Vec3){ 2, 3, 4 } && first.layers == 9);
        Node* leaf = first.first_child;
        assert(leaf.transform_space == TransformSpace.WORLD && leaf.world_position() == (Vec3){ 8, 9, 10 });
        Value* value = fixture.destination.get(restored, Value);
        assert(value.number == 42 && value.enabled && c3d::same_id(value.other, leaf.id));
        assert(value.pointer == leaf);
        Owned* owned = fixture.destination.get(restored.first_child, Owned);
        assert(owned.values == (uint[]){ 3, 5, 8 } && owned.label == "persistent");
        assert(owned.values.ptr != fixture.source.get(source.first_child, Owned).values.ptr);
        fixture.source.remove(source);
        char[] rewritten = serial::write_subtree(
            allocator: tmem,
            scene: &fixture.destination,
            assets: &fixture.assets,
            root: restored,
        )!!;
        assert(bytes == rewritten);
        bytes[..] = 0;
        assert(owned.label == "persistent" && owned.values[2] == 8);
    };
}

fn void test_missing_and_wrong_kind_keys_leave_existing_scene() @test {
    @pool() {
        Fixture fixture;
        init_fixture(&fixture);
        defer free_fixture(&fixture);
        GeometryId geometry = add_geometry(&fixture.assets, "shape");
        Node* source = fixture.source.add_node()!!;
        fixture.source.add(source, (Value){ .geometry = geometry });
        char[] bytes = serial::write_subtree(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: source,
        )!!;
        Node* existing = fixture.destination.add_node(name: "existing")!!;
        fixture.destination.add(existing, (Value){ .number = 99 });
        uint free_before = fixture.destination.world.entities.free_count;
        fixture.assets.remove_geometry(geometry);
        assert(@catch(serial::read_subtree(&fixture.destination, &fixture.assets, bytes)) == c3d::INVALID_ID);
        assert(fixture.destination.world.entities.free_count == free_before);
        (void)fixture.assets.add_material(material::standard(), "shape")!!;
        assert(@catch(serial::read_subtree(&fixture.destination, &fixture.assets, bytes)) == c3d::INVALID_ID);
        assert(fixture.destination.world.entities.free_count == free_before && fixture.destination.count(Value) == 1);
        assert(fixture.destination.get(existing, Value).number == 99);
    };
}

fn void test_late_payload_failure_frees_attached_values() @test {
    @pool() {
        Fixture fixture;
        init_fixture(&fixture);
        defer free_fixture(&fixture);
        Node* source = value_tree(&fixture);
        char[] bytes = serial::write_subtree(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: source,
        )!!;
        uint before = fixture.destination.world.entities.free_count;
        bytes[value_payload_offset(bytes) + uint::size] = 2;
        assert(@catch(serial::read_subtree(&fixture.destination, &fixture.assets, bytes)) == c3d::ASSET_FORMAT_ERROR);
        assert(fixture.removed == 1 && fixture.destination.count(Owned) == 0);
        assert(fixture.destination.world.entities.free_count == before && fixture.destination.root.first_child == null);
    };
}

fn void test_unknown_types_and_explicit_transient_policy() @test {
    @pool() {
        Fixture fixture;
        init_fixture(&fixture);
        defer free_fixture(&fixture);
        Node* root = fixture.source.add_node()!!;
        fixture.source.add(root, (Unknown){ .value = 4 });
        assert(!serial::is_serializable(Unknown));
        assert(@catch(serial::write_subtree(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: root,
        )) == c3d::UNSUPPORTED);
        serial::register_transient(Unknown)!!;
        assert(serial::is_serializable(Unknown));
        char[] bytes = serial::write_subtree(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: root,
        )!!;
        Node* restored = serial::read_subtree(&fixture.destination, &fixture.assets, bytes)!!;
        assert(!fixture.destination.has(restored, Unknown));
    };
}

fn void test_version_branches_and_duplicate_names() @test {
    @pool() {
        Fixture fixture;
        init_fixture(&fixture);
        defer free_fixture(&fixture);
        assert(@catch(serial::register_codec(Duplicate, {
            .name = "value",
            .version = 1,
            .write = &write_value,
            .read = &read_value,
        })) == c3d::INVALID_ARGUMENT);
        Node* root = fixture.source.add_node()!!;
        fixture.source.add(root, (Versioned){ .first = 11, .second = 99 });
        serial::register_codec(Versioned, {
            .name = "versioned",
            .version = 1,
            .write = &write_old_version,
            .read = &read_versioned,
        })!!;
        char[] bytes = serial::write_subtree(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: root,
        )!!;
        register_codecs();
        Node* restored = serial::read_subtree(&fixture.destination, &fixture.assets, bytes)!!;
        Versioned* value = fixture.destination.get(restored, Versioned);
        assert(value.first == 11 && value.second == 7);
        uint type_offset = chunk_offset(bytes, ChunkKind.TYPES);
        Reader reader = serial::reader_over(bytes);
        reader.offset = type_offset + uint::size;
        (void)reader.read_string()!!;
        patch_uint(bytes, reader.offset, 3);
        assert(@catch(serial::read_subtree(&fixture.destination, &fixture.assets, bytes)) == c3d::UNSUPPORTED);
        patch_uint(bytes, reader.offset, 1);
        bytes[type_offset + 2 * uint::size] = 'x';
        assert(@catch(serial::read_subtree(&fixture.destination, &fixture.assets, bytes)) == c3d::UNSUPPORTED);
    };
}

fn void test_capacity_and_reference_boundary() @test {
    @pool() {
        Fixture fixture;
        init_fixture(&fixture, 2);
        defer free_fixture(&fixture);
        Node* root = value_tree(&fixture);
        char[] bytes = serial::write_subtree(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: root,
        )!!;
        uint before = fixture.destination.world.entities.free_count;
        assert(@catch(serial::read_subtree(&fixture.destination, &fixture.assets, bytes)) == c3d::CAPACITY_EXCEEDED);
        assert(fixture.destination.world.entities.free_count == before);
        Node* outside = fixture.source.add_node()!!;
        fixture.source.get(root, Value).other = outside.id;
        assert(@catch(serial::write_subtree(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: root,
        )) == c3d::INVALID_ARGUMENT);
    };
}

fn void test_owned_projection_preserves_authored_children() @test {
    @pool() {
        Fixture fixture;
        init_fixture(&fixture);
        defer free_fixture(&fixture);
        Node* root = fixture.source.add_node()!!;
        Node* generated = fixture.source.add_node(root)!!;
        fixture.source.add(generated, (Value){});
        fixture.source.add(root, (Composite){ .child = generated.id });
        char[] bytes = serial::write_subtree(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: root,
        )!!;
        assert(serial::read_header(bytes)!!.node_count == 1);
        Node* restored = serial::read_subtree(&fixture.destination, &fixture.assets, bytes)!!;
        assert(fixture.destination.has(restored, Composite) && restored.first_child == null);
        (void)fixture.source.add_node(generated, "authored")!!;
        assert(@catch(serial::write_subtree(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: root,
        )) == c3d::INVALID_ARGUMENT);
    };
}

fn void test_foreign_node_pointer_is_not_a_local_reference() @test {
    @pool() {
        Fixture fixture;
        init_fixture(&fixture);
        defer free_fixture(&fixture);
        Node* root = fixture.source.add_node()!!;
        Node* foreign = fixture.destination.add_node()!!;
        assert(c3d::same_id(root.id, foreign.id));
        fixture.source.add(root, (Value){ .pointer = foreign });
        assert(@catch(serial::write_subtree(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: root,
        )) == c3d::INVALID_ARGUMENT);
    };
}
