module c3d::serial::test_described;

import c3d;
import c3d::asset;
import c3d::ecs;
import c3d::scene;
import c3d::serial @public;
import std::math;

const char[*] LEGACY_NUMBER_BYTES @private = {
    0x43, 0x33, 0x44, 0x53, 0x01, 0x00, 0x00, 0x00, 0xc1, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x48, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x48, 0x00, 0x00, 0x00, 0x12, 0x00, 0x00, 0x00,
    0x02, 0x00, 0x00, 0x00, 0x5a, 0x00, 0x00, 0x00, 0x4f, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00,
    0xa9, 0x00, 0x00, 0x00, 0x18, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00,
    0x6e, 0x75, 0x6d, 0x62, 0x65, 0x72, 0x01, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x06, 0x00,
    0x00, 0x00, 0x6c, 0x65, 0x67, 0x61, 0x63, 0x79, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x80, 0x3f, 0x00, 0x00, 0x80, 0x3f, 0x00, 0x00, 0x80, 0x3f, 0x00, 0x00, 0x80, 0x3f,
    0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x2a, 0x00, 0x00,
    0x00,
};

fn void test_described_binary_round_trip_owns_authoring_and_exact_bits() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        Node* source = fixture_tree(&fixture);
        char[] bytes = fixture_bytes(&fixture, source);
        assert(bytes == fixture_bytes(&fixture, source));
        Node* restored = serial::read_subtree(&fixture.destination, &fixture.assets, bytes)!!;
        Number* number = fixture.destination.get(restored, Number);
        assert(number.count == 21 && c3d::same_id(number.target, restored.first_child.id));
        assert(bitcast(number.gain, uint) == 0x80000000U);
        Owner* owner = fixture.destination.get(restored.first_child, Owner);
        assert(owner.items.len == 2 && owner.items[0].label == "first" && owner.items[1].label == "second");
        assert(owner.items[0].amount == short::min && owner.items[1].amount == short::max);
        assert(owner.total == ulong::max && bitcast(owner.precision, ulong) == 0x7ff0000000000001UL);
        assert(owner.cells == (uint[<3>]){ 0, 2147483648U, uint::max });
        assert(owner.basis.m01 == 0.375f && owner.basis.m22 == -2);
        assert(owner.items.ptr != fixture.source.get(source.first_child, Owner).items.ptr);
        fixture.source.remove(source);
        char[] repeated = serial::write_subtree(
            allocator: tmem,
            scene: &fixture.destination,
            assets: &fixture.assets,
            root: restored,
        )!!;
        assert(bytes == repeated);
        bytes[..] = 0;
        assert(owner.items[0].label == "first" && owner.items[1].amount == short::max);
    };
}

fn void test_described_binary_allocation_faults_rollback_attached_owners() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        Node* source = fixture_tree(&fixture);
        char[] bytes = fixture_bytes(&fixture, source);
        Node* existing = fixture.destination.add_node(name: "existing")!!;
        fixture.destination.add(existing, (Number){ .count = 123, .gain = 0.25f });
        existing.local.position = { 4, 5, 6 };
        existing.local.scale = { 2, 3, 4 };
        existing.layers = 7;
        existing.visible = false;
        fixture.destination.update_world();
        Node snapshot = *existing;
        MaterialId material = fixture.assets.add_material({}, "unchanged")!!;
        uint revision = fixture.assets.material(material).header.revision;
        uint materials_free = fixture.assets.materials.free_count;
        uint geometries_free = fixture.assets.geometries.free_count;
        sz keys = fixture.assets.keys.len();
        uint free_before = fixture.destination.world.entities.free_count;
        FailingAllocator counter;
        ReadOptions options = serial::READ_OPTIONS_DEFAULT;
        options.allocator = &counter;
        Node* successful = serial::read_subtree(
            scene: &fixture.destination,
            assets: &fixture.assets,
            bytes: bytes,
            options: options,
        )!!;
        uint attempts = counter.attempts;
        fixture.destination.remove(successful);
        assert(attempts == 6 && !counter.outstanding);
        uint removed_before = fixture.removed;
        for (uint failure = 1; failure <= attempts; failure++) {
            counter = { .failure = failure };
            if (catch excuse = serial::read_subtree(
                scene: &fixture.destination,
                assets: &fixture.assets,
                bytes: bytes,
                options: options,
            )) {
                assert(excuse == c3d::CAPACITY_EXCEEDED);
            } else {
                assert(false);
            }
            assert(!counter.outstanding);
            assert(fixture.destination.world.entities.free_count == free_before);
            assert(fixture.destination.count(Owner) == 0 && fixture.destination.count(Number) == 1);
            assert(fixture.destination.get(existing, Number).count == 123);
            assert(fixture.destination.get(existing, Number).gain == 0.25f && existing.name == "existing");
            assert(c3d::same_id(existing.id, snapshot.id) && existing.transform_space == snapshot.transform_space);
            assert(existing.local.position == snapshot.local.position && existing.local.rotation.v == snapshot.local.rotation.v);
            assert(existing.local.scale == snapshot.local.scale && existing.world == snapshot.world);
            assert(existing.layers == snapshot.layers && existing.visible == snapshot.visible);
            assert(existing.visible_effective == snapshot.visible_effective && existing.parent == snapshot.parent);
            assert(existing.first_child == snapshot.first_child && existing.next_sibling == snapshot.next_sibling);
            assert(fixture.assets.materials.free_count == materials_free && fixture.assets.geometries.free_count == geometries_free);
            assert(fixture.assets.keys.len() == keys && fixture.assets.material(material).header.revision == revision);
            assert(c3d::same_id(fixture.assets.find_material("unchanged")!!, material));
        }
        assert(fixture.removed == removed_before + 1);
    };
}

fn void test_described_binary_compatibility_requires_an_explicit_old_reader() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        Node* source = fixture.source.add_node(name: "legacy")!!;
        fixture.source.add(source, (Number){ .count = 42 });
        serial::register_codec(Number, {
            .name = "number",
            .version = 1,
            .write = &write_old_number,
            .read = &read_old_number,
        })!!;
        char[] old = alloc::clone_slice(tmem, LEGACY_NUMBER_BYTES[..]);
        assert(old == fixture_bytes(&fixture, source));
        register_described_codecs();
        assert(serial::codecs[ecs::slot_of(Number)!!].codec.version == 2);
        assert(serial::codecs[ecs::slot_of(Number)!!].described.codec.binary_compatibility.len == 1);
        assert(serial::codecs[ecs::slot_of(Number)!!].described.codec.binary_compatibility[0].version == 1);
        Node* restored = serial::read_subtree(&fixture.destination, &fixture.assets, old)!!;
        Number* number = fixture.destination.get(restored, Number);
        assert(number.count == 42 && number.gain == 0.5f && !number.target.index);
        serial::register_described(Number, { .name = "number", .phase = REFERENCES })!!;
        uint free_before = fixture.destination.world.entities.free_count;
        if (catch excuse = serial::read_subtree(&fixture.destination, &fixture.assets, old)) {
            assert(excuse == c3d::UNSUPPORTED);
        } else {
            assert(false);
        }
        assert(fixture.destination.world.entities.free_count == free_before);
        register_described_codecs();
    };
}

fn void test_described_binary_rejects_truncated_current_payload_without_defaults() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        Node* source = fixture_tree(&fixture);
        char[] bytes = fixture_bytes(&fixture, source);
        SubtreeHeader header = serial::read_header(bytes)!!;
        Reader groups = serial::reader_over(serial::chunk_bytes(bytes, header.chunk_count, COMPONENTS));
        uint group_count = groups.read_uint()!!;
        char[] owner_payload;
        for (uint group = 0; group < group_count; group++) {
            groups.read_uint()!!;
            uint count = groups.read_uint()!!;
            for (uint index = 0; index < count; index++) {
                uint node = groups.read_uint()!!;
                uint length = groups.read_uint()!!;
                char[] payload = groups.read_bytes(length)!!;
                if (node == 1) owner_payload = payload;
            }
        }
        assert(owner_payload.len > 0);
        Node* node = fixture.destination.add_node()!!;
        FailingAllocator counter;
        ReadContext context = {
            .scene = &fixture.destination,
            .assets = &fixture.assets,
            .allocator = &counter,
            .node = node,
            .version = 1,
            .slot = ecs::slot_of(Owner)!!,
        };
        foreach (cut, ignored : owner_payload) {
            Reader truncated = serial::reader_over(owner_payload[:cut]);
            if (catch excuse = serial::codecs[context.slot].codec.read(&truncated, &context)) {
                assert(excuse == c3d::ASSET_FORMAT_ERROR);
            } else {
                assert(false);
            }
            assert(!fixture.destination.has(node, Owner) && !counter.outstanding);
        }
    };
}
