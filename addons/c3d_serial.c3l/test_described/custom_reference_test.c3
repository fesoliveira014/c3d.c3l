module c3d::serial::test_described;

import c3d;
import c3d::asset;
import c3d::asset::custom;
import c3d::describe;
import c3d::scene;
import c3d::serial @public;

struct Chime @private {
    float gain;
}

struct Rumble @private {
    float gain;
}

struct Lateness @private {
    float gain;
}

struct Holder @private {
    CustomId{Chime} chime;
    float level;
}

struct LateHolder @private {
    CustomId{Lateness} item;
}

fn void defaults_holder(void* raw) @private => *(Holder*)raw = {};
fn void defaults_late_holder(void* raw) @private => *(LateHolder*)raw = {};

fn AssetStore custom_store() @private {
    return asset::create_asset_store(mem, {
        .max_geometries = 2,
        .max_textures = 8,
        .max_materials = 2,
        .max_samplers = 8,
        .max_models = 1,
        .max_skeletons = 1,
        .max_clips = 1,
        .max_environments = 1,
        .max_shaders = 1,
        .max_compute_shaders = 1,
        .max_fonts = 1,
    });
}

macro add_custom_record(AssetStore* assets, $Type, String key) @private {
    CustomPool{$Type}* pool = assets.pool($Type);
    CustomId{$Type} id = pool.add({})!!;
    *pool.get(id) = {
        .header = { .key = asset::copy_string(assets.allocator, key), .revision = 1 },
    };
    asset::register_key(assets, key, asset::custom_ref($Type, id));
    return id;
}

fn void register_holder_codecs() @private {
    describe::register_reflected(Holder)!!;
    serial::register_described_type(
        $Type: Holder,
        version: 1,
        layout: serial::description_layout(describe::get(Holder)!!)!!,
        defaults: &defaults_holder,
    )!!;
    serial::register_described(Holder, { .name = "holder" })!!;
}

fn void test_custom_reference_round_trips_by_key_in_both_encodings() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        register_holder_codecs();
        fixture.source.register(Holder)!!;
        fixture.destination.register(Holder)!!;
        fixture.assets.register(Chime, 4)!!;
        CustomId{Chime} bell = add_custom_record(&fixture.assets, Chime, "bell");
        Node* source = fixture.source.add_node(name: "holder")!!;
        fixture.source.add(source, (Holder){ .chime = bell, .level = 0.5f });
        Node* empty = fixture.source.add_node(name: "empty")!!;
        fixture.source.add(empty, (Holder){ .level = 2 });
        for (uint encoding = 0; encoding < 2; encoding++) {
            Node*[2] roots = { source, empty };
            foreach (root : roots) {
                char[] bytes = fixture_bytes(&fixture, root);
                String text = fixture_text(&fixture, root);
                Node* restored = encoding == 0
                  ? serial::read_subtree(&fixture.destination, &fixture.assets, bytes)!!
                  : serial::read_subtree_text(&fixture.destination, &fixture.assets, text)!!;
                Holder* expected = fixture.source.get(root, Holder);
                Holder* actual = fixture.destination.get(restored, Holder);
                assert(actual.level == expected.level);
                assert(actual.chime.index == expected.chime.index);
                assert(actual.chime.generation == expected.chime.generation);
                fixture.destination.remove(restored);
            }
        }
    };
}

fn void test_custom_reference_rejects_key_of_another_kind_and_dead_ids() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        register_holder_codecs();
        fixture.source.register(Holder)!!;
        fixture.destination.register(Holder)!!;
        fixture.assets.register(Chime, 4)!!;
        CustomId{Chime} bell = add_custom_record(&fixture.assets, Chime, "bell");
        Node* source = fixture.source.add_node(name: "holder")!!;
        fixture.source.add(source, (Holder){ .chime = bell });
        char[] bytes = fixture_bytes(&fixture, source);
        String text = fixture_text(&fixture, source);

        AssetStore other = custom_store();
        defer asset::destroy_asset_store(&other);
        other.register(Chime, 4)!!;
        other.register(Rumble, 4)!!;
        add_custom_record(&other, Rumble, "bell");
        assert(@catch(serial::read_subtree(&fixture.destination, &other, bytes)) == c3d::INVALID_ID);
        assert(@catch(serial::read_subtree_text(&fixture.destination, &other, text)) == c3d::INVALID_ID);
        assert(fixture.destination.root.first_child == null);

        asset::forget_key(&fixture.assets, "bell");
        asset::free_string(fixture.assets.allocator, fixture.assets.pool(Chime).get(bell).header.key);
        *fixture.assets.pool(Chime).get(bell) = {};
        fixture.assets.pool(Chime).remove(bell);
        assert(@catch(serial::write_subtree(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: source,
        )) == c3d::INVALID_ID);
    };
}

fn void test_custom_reference_resolves_description_reflected_before_registration() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        describe::register_reflected(LateHolder)!!;
        assert(*asset::slot_address(Lateness) == 0);
        serial::register_described_type(
            $Type: LateHolder,
            version: 1,
            layout: serial::description_layout(describe::get(LateHolder)!!)!!,
            defaults: &defaults_late_holder,
        )!!;
        serial::register_described(LateHolder, { .name = "late_holder" })!!;
        fixture.source.register(LateHolder)!!;
        fixture.destination.register(LateHolder)!!;
        Node* source = fixture.source.add_node(name: "late")!!;
        fixture.source.add(source, (LateHolder){});
        fixture.assets.register(Lateness, 2)!!;
        assert(*asset::slot_address(Lateness) != 0);
        CustomId{Lateness} item = add_custom_record(&fixture.assets, Lateness, "late");
        fixture.source.get(source, LateHolder).item = item;
        char[] bytes = fixture_bytes(&fixture, source);
        Node* restored = serial::read_subtree(&fixture.destination, &fixture.assets, bytes)!!;
        assert(fixture.destination.get(restored, LateHolder).item.index == item.index);
        String text = fixture_text(&fixture, source);
        fixture.destination.remove(restored);
        restored = serial::read_subtree_text(&fixture.destination, &fixture.assets, text)!!;
        assert(fixture.destination.get(restored, LateHolder).item.generation == item.generation);
    };
}

fn void test_custom_reference_write_rejects_keyless_records_and_stores_without_the_kind() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        register_holder_codecs();
        fixture.source.register(Holder)!!;
        fixture.assets.register(Chime, 4)!!;
        CustomId{Chime} anonymous = add_custom_record(&fixture.assets, Chime, "");
        Node* source = fixture.source.add_node(name: "holder")!!;
        fixture.source.add(source, (Holder){ .chime = anonymous });
        assert(@catch(serial::write_subtree(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: source,
        )) == c3d::INVALID_ARGUMENT);
        AssetStore bare = custom_store();
        defer asset::destroy_asset_store(&bare);
        assert(@catch(serial::write_subtree_text(
            allocator: tmem,
            scene: &fixture.source,
            assets: &bare,
            root: source,
        )) == c3d::UNSUPPORTED);
    };
}
