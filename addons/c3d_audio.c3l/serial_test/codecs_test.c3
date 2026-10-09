module c3d_audio_test;

import c3d;
import c3d::asset;
import c3d::audio;
import c3d::geometry;
import c3d::scene;
import c3d::serial;

const String CLIP_KEY @local = "bell";
const float EMITTER_VOLUME @local = 0.75f;
const float EMITTER_PITCH @local = 1.5f;
const float EMITTER_MIN_DISTANCE @local = 3;
const float EMITTER_MAX_DISTANCE @local = 40;
const float CLIP_SECONDS @local = 0.5f;

struct SerialFixture @local {
    AssetStore  source_assets;
    AssetStore  destination_assets;
    AudioSystem source_system;
    AudioSystem destination_system;
    Scene       source;
    Scene       destination;
    Node*       root;
    Node*       listener;
    AudioClipId clip;
}

fn AudioClipId add_keyed_clip(AssetStore* assets) @local {
    char[] wav = make_wav(
        allocator: mem,
        frequency: 440,
        amplitude: 0.5f,
        seconds: CLIP_SECONDS,
    );
    defer alloc::free(mem, wav.ptr);
    return audio::add_audio_clip(assets, wav, key: CLIP_KEY)!!;
}

fn void create_serial_fixture(SerialFixture* fixture) @local {
    audio::register_serial_codecs()!!;
    serial::register_core_codecs()!!;
    fixture.source_assets = make_store(mem);
    fixture.destination_assets = make_store(mem);
    fixture.source_system = make_system(mem, &fixture.source_assets);
    fixture.destination_system = make_system(mem, &fixture.destination_assets);
    fixture.source = make_scene(mem, &fixture.source_system);
    fixture.destination = make_scene(mem, &fixture.destination_system);
    fixture.clip = add_keyed_clip(&fixture.source_assets);
    add_keyed_clip(&fixture.destination_assets);
    fixture.root = fixture.source.add_node(name: "emitter")!!;
    fixture.listener = fixture.source.add_node(fixture.root, "listener")!!;
    fixture.source.add(fixture.root, (AudioEmitter){
        .clip         = fixture.clip,
        .bus          = audio::MUSIC_BUS,
        .volume       = EMITTER_VOLUME,
        .pitch        = EMITTER_PITCH,
        .min_distance = EMITTER_MIN_DISTANCE,
        .max_distance = EMITTER_MAX_DISTANCE,
        .looping      = true,
        .playing      = true,
    });
    fixture.source.add(fixture.listener, (AudioListener){ .active = true });
}

fn void destroy_serial_fixture(SerialFixture* fixture) @local {
    scene::destroy_scene(&fixture.destination);
    scene::destroy_scene(&fixture.source);
    audio::destroy_audio_system(&fixture.destination_system);
    audio::destroy_audio_system(&fixture.source_system);
    asset::destroy_asset_store(&fixture.destination_assets);
    asset::destroy_asset_store(&fixture.source_assets);
}

fn char[]? encode_subtree(SerialFixture* fixture, AssetStore* assets, bool text_mode) @local {
    if (text_mode) return (char[])serial::write_subtree_text(
        allocator: tmem,
        scene: &fixture.source,
        assets: assets,
        root: fixture.root,
    )!;
    return serial::write_subtree(
        allocator: tmem,
        scene: &fixture.source,
        assets: assets,
        root: fixture.root,
    );
}

fn Node*? decode_subtree(SerialFixture* fixture, AssetStore* assets, char[] bytes, bool text_mode) @local {
    if (text_mode) return serial::read_subtree_text(
        scene: &fixture.destination,
        assets: assets,
        text: (String)bytes,
    );
    return serial::read_subtree(
        scene: &fixture.destination,
        assets: assets,
        bytes: bytes,
    );
}

fn void test_emitters_and_listeners_round_trip_without_links_in_both_encodings() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            SerialFixture fixture;
            create_serial_fixture(&fixture);
            defer destroy_serial_fixture(&fixture);
            fixture.source_system.update(&fixture.source);
            assert(fixture.source_system.stats().voices == 1);
            char[] bytes = encode_subtree(&fixture, &fixture.source_assets, text_mode)!!;
            assert(!((String)bytes).contains("link"));

            Node* restored = decode_subtree(&fixture, &fixture.destination_assets, bytes, text_mode)!!;
            AudioEmitter* emitter = fixture.destination.get(restored, AudioEmitter);
            AudioClipId expected = asset::custom_id(AudioClip, fixture.destination_assets.find(CLIP_KEY)!!)!!;
            assert(emitter.clip.index == expected.index && emitter.clip.generation == expected.generation);
            assert(emitter.bus == audio::MUSIC_BUS && emitter.looping && emitter.playing);
            assert(emitter.volume == EMITTER_VOLUME && emitter.pitch == EMITTER_PITCH);
            assert(emitter.min_distance == EMITTER_MIN_DISTANCE && emitter.max_distance == EMITTER_MAX_DISTANCE);
            assert(fixture.destination.get(restored.first_child, AudioListener).active);

            assert(fixture.destination_system.stats().voices == 0);
            fixture.destination_system.update(&fixture.destination);
            assert(fixture.destination_system.stats().voices == 1);
        };
    }
}

fn void test_missing_and_wrong_kind_clip_keys_fault_on_read() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            SerialFixture fixture;
            create_serial_fixture(&fixture);
            defer destroy_serial_fixture(&fixture);
            char[] bytes = encode_subtree(&fixture, &fixture.source_assets, text_mode)!!;

            AssetStore missing = make_store(mem);
            defer asset::destroy_asset_store(&missing);
            assert(@catch(decode_subtree(&fixture, &missing, bytes, text_mode)) == c3d::INVALID_ID);

            AssetStore wrong = make_store(mem);
            defer asset::destroy_asset_store(&wrong);
            Geometry box = geometry::box(
                allocator: tmem,
                width: 1,
                height: 1,
                depth: 1,
            );
            wrong.add_geometry(&box, CLIP_KEY)!!;
            assert(@catch(decode_subtree(&fixture, &wrong, bytes, text_mode)) == c3d::INVALID_ID);
            assert(fixture.destination.root.first_child == null);
        };
    }
}

fn void test_store_without_clip_kind_faults_unsupported_on_write() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            SerialFixture fixture;
            create_serial_fixture(&fixture);
            defer destroy_serial_fixture(&fixture);
            AssetStore bare = asset::create_asset_store(mem, asset::default_asset_store_desc());
            defer asset::destroy_asset_store(&bare);
            assert(@catch(encode_subtree(&fixture, &bare, text_mode)) == c3d::UNSUPPORTED);
        };
    }
}
