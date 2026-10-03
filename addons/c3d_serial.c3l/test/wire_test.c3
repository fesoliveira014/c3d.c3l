module c3d::serial::test;

import c3d;
import c3d::asset;
import c3d::asset::custom;
import c3d::ecs;
import c3d::scene;
import c3d::serial;

fn void test_corrupt_container_ranges_and_records() @test {
    @pool() {
        Fixture fixture;
        init_fixture(&fixture);
        defer free_fixture(&fixture);
        Node* root = value_tree(&fixture);
        char[] original = serial::write_subtree(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: root,
        )!!;
        uint free_before = fixture.destination.world.entities.free_count;
        usz[8] offsets = {
            0, 8, 24, 24 + 8, 36, 36 + 4,
            chunk_offset(original, ChunkKind.NODES),
            (usz)chunk_offset(original, ChunkKind.NODES) + 73 + (usz)root.name.len,
        };
        uint[8] values = { 0, 0, 9, uint::max, 0, 0, 0, uint::max };
        foreach (index, offset : offsets) {
            char[] bytes = alloc::clone_slice(tmem, original);
            patch_uint(bytes, offset, values[index]);
            assert(@catch(serial::read_subtree(&fixture.destination, &fixture.assets, bytes))
              == c3d::ASSET_FORMAT_ERROR);
            assert(fixture.destination.world.entities.free_count == free_before);
        }
        assert(@catch(serial::read_subtree(
            scene: &fixture.destination,
            assets: &fixture.assets,
            bytes: original[:original.len - 1],
        )) == c3d::ASSET_FORMAT_ERROR);
        char[] newer = alloc::clone_slice(tmem, original);
        patch_uint(newer, 4, serial::SUBTREE_VERSION + 1);
        assert(@catch(serial::read_subtree(&fixture.destination, &fixture.assets, newer)) == c3d::UNSUPPORTED);
        char[] duplicate = alloc::clone_slice(tmem, original);
        patch_uint(duplicate, 36 + 4, chunk_offset(original, ChunkKind.NODES));
        assert(@catch(serial::read_subtree(&fixture.destination, &fixture.assets, duplicate))
          == c3d::ASSET_FORMAT_ERROR);
    };
}

fn void test_unknown_chunk_is_skipped() @test {
    @pool() {
        Fixture fixture;
        init_fixture(&fixture);
        defer free_fixture(&fixture);
        Node* root = value_tree(&fixture);
        char[] original = serial::write_subtree(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: root,
        )!!;
        char[] extended = extend_chunk_table(original, 1);
        Node* restored = serial::read_subtree(&fixture.destination, &fixture.assets, extended)!!;
        assert(restored.name == "root" && fixture.destination.count(Value) == 1);
    };
}

fn void test_payload_framing_and_duplicate_component_fail() @test {
    @pool() {
        Fixture fixture;
        init_fixture(&fixture);
        defer free_fixture(&fixture);
        Node* root = fixture.source.add_node()!!;
        Node* child = fixture.source.add_node(root)!!;
        fixture.source.add(root, (Value){ .number = 1 });
        fixture.source.add(child, (Value){ .number = 2 });
        char[] original = serial::write_subtree(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: root,
        )!!;
        uint payload = value_payload_offset(original, 0);
        char[] truncated = alloc::clone_slice(tmem, original);
        patch_uint(truncated, payload - uint::size, uint::max);
        assert(@catch(serial::read_subtree(&fixture.destination, &fixture.assets, truncated))
          == c3d::ASSET_FORMAT_ERROR);
        Reader reader = serial::reader_over(original);
        reader.offset = payload - uint::size;
        uint payload_size = reader.read_uint()!!;
        char[] duplicated = alloc::clone_slice(tmem, original);
        patch_uint(duplicated, (usz)payload + payload_size, 0);
        assert(@catch(serial::read_subtree(&fixture.destination, &fixture.assets, duplicated))
          == c3d::ASSET_FORMAT_ERROR);
        char[] bad_reference = alloc::clone_slice(tmem, original);
        patch_uint(bad_reference, payload + uint::size + 1, 100);
        assert(@catch(serial::read_subtree(&fixture.destination, &fixture.assets, bad_reference))
          == c3d::ASSET_FORMAT_ERROR);
        assert(fixture.destination.count(Value) == 0 && fixture.destination.root.first_child == null);
    };
}

fn void test_absent_destination_store_is_unsupported() @test {
    @pool() {
        Fixture fixture;
        init_fixture(&fixture);
        defer free_fixture(&fixture);
        Node* root = fixture.source.add_node()!!;
        fixture.source.add(root, (Value){});
        char[] bytes = serial::write_subtree(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: root,
        )!!;
        Scene plain = scene::create_scene(mem, { .max_nodes = 8 });
        defer scene::destroy_scene(&plain);
        assert(@catch(serial::read_subtree(&plain, &fixture.assets, bytes)) == c3d::UNSUPPORTED);
        assert(plain.root.first_child == null);
    };
}

fn void test_custom_asset_references_keep_kind_identity() @test {
    @pool() {
        Fixture fixture;
        init_fixture(&fixture);
        defer free_fixture(&fixture);
        fixture.assets.register(Wave, 2)!!;
        fixture.assets.register(OtherAsset, 2)!!;
        String key = "wave/ping".copy(mem);
        CustomId{Wave} wave = fixture.assets.pool(Wave).add({
            .header = { .key = key, .revision = 1 },
            .data = { .amplitude = 0.5f },
        })!!;
        asset::register_key(&fixture.assets, key, asset::custom_ref(Wave, wave));
        Node* root = fixture.source.add_node()!!;
        fixture.source.add(root, (CustomValue){ .wave = wave });
        char[] bytes = serial::write_subtree(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: root,
        )!!;
        Node* restored = serial::read_subtree(&fixture.destination, &fixture.assets, bytes)!!;
        CustomId{Wave} actual = fixture.destination.get(restored, CustomValue).wave;
        assert(actual.index == wave.index && actual.generation == wave.generation);
        CustomId{OtherAsset} other = fixture.assets.pool(OtherAsset).add({
            .header = { .revision = 1 },
            .data = { .amplitude = 1 },
        })!!;
        asset::forget_key(&fixture.assets, key);
        asset::register_key(&fixture.assets, key, asset::custom_ref(OtherAsset, other));
        assert(@catch(serial::read_subtree(&fixture.destination, &fixture.assets, bytes)) == c3d::INVALID_ID);
    };
}

fn void? read_value_prefix(Reader* reader, ReadContext* context) @private {
    context.scene.add(context.node, (Value){ .number = reader.read_uint()! });
}

fn void test_unconsumed_payload_rolls_back() @test {
    @pool() {
        Fixture fixture;
        init_fixture(&fixture);
        defer free_fixture(&fixture);
        Node* root = fixture.source.add_node()!!;
        fixture.source.add(root, (Value){ .number = 7 });
        char[] bytes = serial::write_subtree(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: root,
        )!!;
        serial::register_codec(Value, {
            .name = "value",
            .version = 1,
            .write = &write_value,
            .read = &read_value_prefix,
        })!!;
        assert(@catch(serial::read_subtree(&fixture.destination, &fixture.assets, bytes))
          == c3d::ASSET_FORMAT_ERROR);
        assert(fixture.destination.count(Value) == 0);
        assert(fixture.destination.root.first_child == null);
        register_codecs();
    };
}

fn void test_unkeyed_and_dead_source_assets_fail() @test {
    @pool() {
        Fixture fixture;
        init_fixture(&fixture);
        defer free_fixture(&fixture);
        GeometryId geometry = add_geometry(&fixture.assets, "");
        Node* root = fixture.source.add_node()!!;
        fixture.source.add(root, (Value){ .geometry = geometry });
        assert(@catch(serial::write_subtree(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: root,
        )) == c3d::INVALID_ARGUMENT);
        fixture.assets.remove_geometry(geometry);
        assert(@catch(serial::write_subtree(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: root,
        )) == c3d::INVALID_ID);
    };
}

fn void test_missing_custom_pool_is_invalid_id() @test {
    @pool() {
        Fixture fixture;
        init_fixture(&fixture);
        defer free_fixture(&fixture);
        fixture.assets.register(Wave, 1)!!;
        String key = "wave";
        CustomId{Wave} wave = fixture.assets.pool(Wave).add({
            .header = { .key = key.copy(mem), .revision = 1 },
            .data = { .amplitude = 1 },
        })!!;
        asset::register_key(&fixture.assets, key, asset::custom_ref(Wave, wave));
        Node* root = fixture.source.add_node()!!;
        fixture.source.add(root, (CustomValue){ .wave = wave });
        char[] bytes = serial::write_subtree(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: root,
        )!!;
        AssetStore other = asset::create_asset_store(mem, asset::default_asset_store_desc());
        defer asset::destroy_asset_store(&other);
        other.register(OtherAsset, 1)!!;
        CustomId{OtherAsset} id = other.pool(OtherAsset).add({
            .header = { .key = key.copy(mem), .revision = 1 },
            .data = { .amplitude = 1 },
        })!!;
        asset::register_key(&other, key, asset::custom_ref(OtherAsset, id));
        assert(@catch(serial::read_subtree(&fixture.destination, &other, bytes)) == c3d::INVALID_ID);
        assert(fixture.destination.root.first_child == null);
    };
}

fn void test_chunk_count_bound_accepts_limit_and_rejects_excess() @test {
    @pool() {
        Fixture fixture;
        init_fixture(&fixture);
        defer free_fixture(&fixture);
        Node* source = value_tree(&fixture);
        char[] original = serial::write_subtree(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: source,
        )!!;
        char[] at_limit = extend_chunk_table(original, serial::MAX_CHUNKS - 4);
        Node* restored = serial::read_subtree(&fixture.destination, &fixture.assets, at_limit)!!;
        assert(restored.name == "root" && fixture.destination.count(Value) == 1);
        uint free_before = fixture.destination.world.entities.free_count;
        foreach (count : (uint[]){ serial::MAX_CHUNKS + 1, 40_000 }) {
            char[] excess = extend_chunk_table(original, count - 4);
            assert(@catch(serial::read_header(excess)) == c3d::ASSET_FORMAT_ERROR);
            assert(@catch(serial::read_subtree(&fixture.destination, &fixture.assets, excess))
              == c3d::ASSET_FORMAT_ERROR);
            assert(fixture.destination.world.entities.free_count == free_before);
        }
    };
}

fn char[] extend_chunk_table(char[] original, uint unknown_count) @private {
    const usz TABLE_END = 72;
    const usz ENTRY_BYTES = 12;
    usz added_size = (usz)unknown_count * ENTRY_BYTES;
    char[] extended = alloc::new_array(tmem, char, (sz)((usz)original.len + added_size));
    extended[:TABLE_END] = original[:TABLE_END];
    extended[TABLE_END + added_size..] = original[TABLE_END..];
    patch_uint(extended, 8, (uint)extended.len);
    patch_uint(extended, 20, 4 + unknown_count);
    for (uint index = 0; index < 4; index++) {
        Reader entry = serial::reader_over(original);
        usz field = 24 + index * ENTRY_BYTES + 4;
        entry.offset = field;
        uint shifted = entry.read_uint()!! + (uint)added_size;
        patch_uint(extended, field, shifted);
    }
    Writer added = serial::writer_over(extended[TABLE_END:added_size]);
    for (uint index = 0; index < unknown_count; index++) {
        added.write_uint(42);
        added.write_uint((uint)extended.len);
        added.write_uint(0);
    }
    return extended;
}
