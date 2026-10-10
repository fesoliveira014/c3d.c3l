module c3d::test::import_events_gltf;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::asset::gltf;
import c3d::asset::loader;
import std::encoding::base64;
import std::io::path;
import std::thread;

const String DOCUMENT @local = $embed("../fixtures/animation_events/gltf-events-v1.gltf");
const String EXTRAS @local = `{"c3d_events":{"version":1,"events":[{"time":1,"id":9},{"time":0,"id":0},`
    `{"time":0.5,"id":4294967295},{"time":0.5,"id":3},{"time":0.5,"id":3}]}}`;
const String EXTRAS_FIELD @local = `"extras": `;
const String BUFFER_PAYLOAD @local = "AAAAAAAAgD8AAAAAAAAAAAAAAAAAAIA/AAAAQAAAQEA=";
const String MODEL_KEY @local = "event-model.gltf";
const ClipEvent[5] EXPECTED_EVENTS @local = {
    { .time = 0, .id = 0 },
    { .time = 0.5f, .id = uint::max },
    { .time = 0.5f, .id = 3 },
    { .time = 0.5f, .id = 3 },
    { .time = 1, .id = 9 },
};

struct MemorySource @local {
    String document;
}

struct FaultCase @local {
    String extras;
    fault expected;
}

fn String fixture_path() @local {
    Path source = path::tnew($$FILEPATH)!!;
    return (String)source.parent()!!.tappend("../fixtures/animation_events", "gltf-events-v1.gltf")!!;
}

fn String with_extras(String extras) @local {
    return DOCUMENT.treplace(EXTRAS, extras);
}

fn String without_extras() @local {
    return DOCUMENT.treplace(string::tformat("%s%s", EXTRAS_FIELD, EXTRAS), `"unrelated":true`);
}

fn ModelDocument? decode_text(
    Allocator allocator,
    String text,
    LoadOptions options = asset::LOAD_OPTIONS_DEFAULT,
) @local {
    return gltf::decode_model_memory(
        allocator: allocator,
        bytes: (char[])text,
        base_dir: "",
        key: MODEL_KEY,
        options: options,
    );
}

fn char[]? read_source(void* user, Allocator allocator, String path) @local {
    MemorySource* source = user;
    if (path != MODEL_KEY) return c3d::ASSET_IO_ERROR~;
    char[] bytes = alloc::new_array(allocator, char, source.document.len);
    mem::copy(bytes.ptr, source.document.ptr, source.document.len);
    return bytes;
}

fn AssetStore create_store(Allocator allocator, MemorySource* source = null) @local {
    AssetStoreDesc desc = {
        .max_geometries = 2,
        .max_textures = 4,
        .max_materials = 4,
        .max_samplers = asset::BUILTIN_SAMPLER_COUNT + 1,
        .max_models = 4,
        .max_skeletons = 2,
        .max_clips = 4,
    };
    if (source) desc.file_source = { .read = &read_source, .user = source };
    return asset::create_asset_store(allocator, desc);
}

fn AnimationClip* model_clip(AssetStore* assets, ModelId model) @local {
    ModelTemplate* template = &assets.model(model).data;
    assert(template.clips.len == 1);
    return &assets.clip(template.clips[0]).data;
}

fn void expect_events(AnimationClip* clip, ClipEvent[] expected) @local {
    assert(clip.duration == 1 && clip.events.len == expected.len);
    foreach (index, event : clip.events) {
        assert(event.time == expected[index].time && event.id == expected[index].id);
    }
}

fn usz[8] store_counts(AssetStore* assets) @local {
    return {
        assets.geometries.free_count, assets.textures.free_count, assets.materials.free_count,
        assets.samplers.free_count, assets.models.free_count, assets.skeletons.free_count,
        assets.clips.free_count, (usz)assets.keys.len(),
    };
}

fn LoadStatus settle(AsyncLoader* loader, LoadId id) @local {
    LoadStatus status = loader.status(id);
    while (status.phase == LoadPhase.QUEUED || status.phase == LoadPhase.DECODING) {
        thread::yield();
        status = loader.status(id);
    }
    return status;
}

fn LoadRequest request(
    ModelId replace = {},
    LoadOptions options = asset::LOAD_OPTIONS_DEFAULT,
) @local {
    return {
        .path = MODEL_KEY,
        .format = ModelFormat.GLTF,
        .options = options,
        .replace = replace,
    };
}

fn void expect_decode_fault(String text, fault expected) @local {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    ModelDocument? decoded = decode_text(&tracker, text);
    if (catch excuse = decoded) {
        assert(excuse == expected);
    } else {
        ModelDocument document = decoded;
        asset::destroy_model_document(&document);
        unreachable("Malformed event metadata was accepted.");
    }
    assert(tracker.allocated() == 0);
}

fn void test_import_events_gltf_fixture_recipe_and_store_free_order() @test {
    @pool() {
        float[8] buffer = { 0, 1, 0, 0, 0, 1, 2, 3 };
        assert(base64::tencode(((char*)&buffer)[:float::size * buffer.len]) == BUFFER_PAYLOAD);
        assert(DOCUMENT.contains(BUFFER_PAYLOAD));
    };

    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        ModelDocument document = decode_text(&tracker, DOCUMENT)!!;
        defer asset::destroy_model_document(&document);
        assert(document.clips.len == 1 && document.template.clips.len == 1);
        assert(document.clips[0].key == "event-model.gltf#anim/0");
        expect_events(&document.clips[0].data, EXPECTED_EVENTS[..]);
        Track* track = &document.clips[0].data.tracks[0];
        assert(track.times.len == 2 && track.times[0] == 0 && track.times[1] == 1);
        assert(track.values.len == 6 && track.values[3] == 1 && track.values[4] == 2 && track.values[5] == 3);
    }
    assert(tracker.allocated() == 0);
}

fn void test_import_events_gltf_absent_empty_and_unrelated_metadata() @test {
    @pool() {
        String[4] sources = {
            without_extras(),
            with_extras("{}"),
            with_extras(`{"other":{"version":"unrelated","events":"ignored"}}`),
            with_extras(`{"c3d_events":{"version":1,"events":[]}}`),
        };
        foreach (source : sources) {
            ModelDocument document = decode_text(mem, source)!!;
            defer asset::destroy_model_document(&document);
            expect_events(&document.clips[0].data, {});
        }
    };
}

fn void test_import_events_gltf_unknown_fields_do_not_change_event_identity() @test {
    @pool() {
        String source = with_extras(`{"ignored":false,"c3d_events":{"version":1,"extra":{"id":-1},`
            `"events":[{"time":0.5,"id":4294967295,"note":"ignored"},{"time":0,"id":0}]}}`);
        ModelDocument document = decode_text(mem, source)!!;
        defer asset::destroy_model_document(&document);
        ClipEvent[2] expected = { { .time = 0, .id = 0 }, { .time = 0.5f, .id = uint::max } };
        expect_events(&document.clips[0].data, expected[..]);
    };
}

fn void test_import_events_gltf_exact_integral_spellings_preserve_ids() @test {
    String[4] versions = { "1", "1.0", "1e0", "10e-1" };
    foreach (version : versions) {
        @pool() {
            String metadata = string::tformat(
                `{"c3d_events":{"version":%s,"events":[{"time":0,"id":1.0},`
                `{"time":0.25,"id":1e0},{"time":0.5,"id":10e-1},{"time":1,"id":-0}]}}`,
                version,
            );
            ModelDocument document = decode_text(mem, with_extras(metadata))!!;
            defer asset::destroy_model_document(&document);
            ClipEvent[4] expected = {
                { .time = 0, .id = 1 },
                { .time = 0.25f, .id = 1 },
                { .time = 0.5f, .id = 1 },
                { .time = 1, .id = 0 },
            };
            expect_events(&document.clips[0].data, expected[..]);
        };
    }
}

fn void test_import_events_gltf_nested_duplicates_and_extreme_unrelated_numbers_are_ignored() @test {
    @pool() {
        String source = with_extras(
            extras: `{"future":1,"future":2,"large":123456789012345678901234567890,"exponent":1e999999999,`
                `"c3d_events":{"version":1,"future":{"key":1,"key":2},`
                `"events":[{"time":0.5,"id":7,"future":{"key":1,"key":2}}]}}`,
        );
        ModelDocument document = decode_text(mem, source)!!;
        defer asset::destroy_model_document(&document);
        ClipEvent[1] expected = { { .time = 0.5f, .id = 7 } };
        expect_events(&document.clips[0].data, expected[..]);
    };
}

fn void test_import_events_gltf_schema_faults_free_every_owned_array() @test {
    FaultCase[] cases = {
        { .extras = `{"c3d_events":null}`, .expected = c3d::ASSET_FORMAT_ERROR },
        { .extras = `{"c3d_events":[]}`, .expected = c3d::ASSET_FORMAT_ERROR },
        { .extras = `{"c3d_events":true}`, .expected = c3d::ASSET_FORMAT_ERROR },
        { .extras = `{"c3d_events":{}}`, .expected = c3d::ASSET_FORMAT_ERROR },
        { .extras = `{"c3d_events":{"version":1}}`, .expected = c3d::ASSET_FORMAT_ERROR },
        { .extras = `{"c3d_events":{"events":[]}}`, .expected = c3d::ASSET_FORMAT_ERROR },
        { .extras = `{"c3d_events":{"version":"1","events":[]}}`, .expected = c3d::ASSET_FORMAT_ERROR },
        { .extras = `{"c3d_events":{"version":true,"events":[]}}`, .expected = c3d::ASSET_FORMAT_ERROR },
        { .extras = `{"c3d_events":{"version":0,"events":[]}}`, .expected = c3d::UNSUPPORTED },
        { .extras = `{"c3d_events":{"version":2,"events":[]}}`, .expected = c3d::UNSUPPORTED },
        { .extras = `{"c3d_events":{"version":1e30,"events":[]}}`, .expected = c3d::UNSUPPORTED },
        { .extras = `{"c3d_events":{"version":123456789012345678901234567890,"events":[]}}`,
          .expected = c3d::UNSUPPORTED },
        { .extras = `{"c3d_events":{"version":1.5,"events":[]}}`, .expected = c3d::ASSET_FORMAT_ERROR },
        { .extras = `{"c3d_events":{"version":1,"events":{}}}`, .expected = c3d::ASSET_FORMAT_ERROR },
        { .extras = `{"c3d_events":{"version":1,"events":[null]}}`, .expected = c3d::ASSET_FORMAT_ERROR },
        { .extras = `{"c3d_events":{"version":1,"events":[{}]}}`, .expected = c3d::ASSET_FORMAT_ERROR },
        { .extras = `{"c3d_events":{"version":1,"events":[{"time":0}]}}`, .expected = c3d::ASSET_FORMAT_ERROR },
        { .extras = `{"c3d_events":{"version":1,"events":[{"id":0}]}}`, .expected = c3d::ASSET_FORMAT_ERROR },
        { .extras = `{"c3d_events":{"version":1,"events":[{"time":"0","id":0}]}}`, .expected = c3d::ASSET_FORMAT_ERROR },
        { .extras = `{"c3d_events":{"version":1,"events":[{"time":0,"id":"0"}]}}`, .expected = c3d::ASSET_FORMAT_ERROR },
        { .extras = `{"c3d_events":{"version":1,"events":[{"time":-0.1,"id":0}]}}`, .expected = c3d::ASSET_FORMAT_ERROR },
        { .extras = `{"c3d_events":{"version":1,"events":[{"time":1.01,"id":0}]}}`, .expected = c3d::ASSET_FORMAT_ERROR },
        { .extras = `{"c3d_events":{"version":1,"events":[{"time":1e999,"id":0}]}}`, .expected = c3d::ASSET_FORMAT_ERROR },
        { .extras = `{"c3d_events":{"version":1,"events":[{"time":0,"id":-1}]}}`, .expected = c3d::ASSET_FORMAT_ERROR },
        { .extras = `{"c3d_events":{"version":1,"events":[{"time":0,"id":0.5}]}}`, .expected = c3d::ASSET_FORMAT_ERROR },
        { .extras = `{"c3d_events":{"version":1,"events":[{"time":0,"id":1.0000000000000000001}]}}`,
          .expected = c3d::ASSET_FORMAT_ERROR },
        { .extras = `{"c3d_events":{"version":1,"events":[{"time":0,"id":4294967296}]}}`, .expected = c3d::ASSET_FORMAT_ERROR },
        { .extras = `{"c3d_events":{"version":1,"events":[{"time":0,"id":1e999}]}}`, .expected = c3d::ASSET_FORMAT_ERROR },
        { .extras = `{"c3d_events":{"version":1,"events":[{"time":NaN,"id":0}]}}`, .expected = c3d::ASSET_FORMAT_ERROR },
        { .extras = `{"c3d_events":{"version":1,"events":[{"time":0,"id":0}]`, .expected = c3d::ASSET_FORMAT_ERROR },
    };
    foreach (entry : cases) {
        @pool() { expect_decode_fault(with_extras(entry.extras), entry.expected); };
    }
}

fn void test_import_events_gltf_later_clip_failure_releases_earlier_event_payloads() @test {
    @pool() {
        String source = DOCUMENT.treplace(
            needle: `"animations": [{`,
            new_str: `"animations": [{"name":"first","samplers":[{"input":0,"output":1}],`
                `"channels":[{"sampler":0,"target":{"node":0,"path":"translation"}}],`
                `"extras":{"c3d_events":{"version":1,"events":[{"time":0.25,"id":99}]}}},{`,
        );
        source = source.treplace(EXTRAS, `{"c3d_events":{"version":1,"events":[{"time":2,"id":0}]}}`);
        expect_decode_fault(source, c3d::ASSET_FORMAT_ERROR);
    };
}

fn void test_import_events_gltf_duplicate_schema_keys_including_escaped_names_fail() @test {
    String[] extras = {
        `{"c3d_events":{"version":1,"version":1,"events":[]}}`,
        `{"c3d_events":{"version":1,"events":[],"events":[]}}`,
        `{"c3d_events":{"version":1,"events":[{"time":0,"time":0,"id":1}]}}`,
        `{"c3d_events":{"version":1,"events":[{"time":0,"id":1,"id":2}]}}`,
        `{"c3d_events":{"version":1,"future":1,"future":2,"events":[]}}`,
        `{"c3d_events":{"version":1,"events":[{"time":0,"id":1,"future":1,"future":2}]}}`,
        `{"c3d_events":{"version":1,"future":1,"fut\u0075re":2,"events":[]}}`,
        `{"c3d_events":{"version":1,"ver\u0073ion":1,"events":[]}}`,
        `{"c3d_events":{"version":1,"events":[{"time":0,"i\u0064":1,"id":2}]}}`,
        `{"c3d_events":{"version":1,"events":[]},"c3d_events":{"version":1,"events":[]}}`,
    };
    foreach (entry : extras) {
        @pool() { expect_decode_fault(with_extras(entry), c3d::ASSET_FORMAT_ERROR); };
    }
}

fn void test_import_events_gltf_zero_duration_does_not_expand_to_event_markers() @test {
    @pool() {
        String source = DOCUMENT.treplace(`"count": 2`, `"count": 1`);
        source = source.treplace(EXTRAS, `{"c3d_events":{"version":1,"events":[{"time":0,"id":17}]}}`);
        ModelDocument document = decode_text(mem, source)!!;
        defer asset::destroy_model_document(&document);
        assert(document.clips[0].data.duration == 0);
        assert(document.clips[0].data.events.len == 1 && document.clips[0].data.events[0].time == 0);
        assert(document.clips[0].data.events[0].id == 17);
        expect_decode_fault(source.treplace(`"time":0`, `"time":0.5`), c3d::ASSET_FORMAT_ERROR);
    };
}

fn void test_import_events_gltf_animation_disabled_ignores_recognized_faults() @test {
    @pool() {
        String source = with_extras(`{"c3d_events":{"version":1,"version":2,"events":"bad"}}`);
        LoadOptions options = asset::LOAD_OPTIONS_DEFAULT;
        options.animations = false;
        ModelDocument document = decode_text(mem, source, options)!!;
        defer asset::destroy_model_document(&document);
        assert(document.clips.len == 0 && document.template.clips.len == 0);
        assert(document.template.nodes.len == 1 && document.template.nodes[0].name == "carrier");
    };
}

fn void test_import_events_gltf_file_and_memory_publication_copy_the_same_table() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        ModelDocument decoded = gltf::decode_model(&tracker, fixture_path())!!;
        defer asset::destroy_model_document(&decoded);
        expect_events(&decoded.clips[0].data, EXPECTED_EVENTS[..]);

        AssetStore files = create_store(&tracker);
        defer asset::destroy_asset_store(&files);
        ModelId from_file = gltf::load_model(&files, fixture_path())!!;
        expect_events(model_clip(&files, from_file), EXPECTED_EVENTS[..]);

        AssetStore memory = create_store(&tracker);
        defer asset::destroy_asset_store(&memory);
        ModelId from_memory = gltf::load_model_memory(
            assets: &memory,
            bytes: (char[])DOCUMENT,
            base_dir: "",
            key: MODEL_KEY,
        )!!;
        expect_events(model_clip(&memory, from_memory), EXPECTED_EVENTS[..]);
        assert(model_clip(&files, from_file).events.ptr != model_clip(&memory, from_memory).events.ptr);
        assert(model_clip(&memory, from_memory).events.ptr != decoded.clips[0].data.events.ptr);
    }
    assert(tracker.allocated() == 0);
}

fn void test_import_events_gltf_invalid_sync_load_preserves_the_store() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        AssetStore assets = create_store(&tracker);
        defer asset::destroy_asset_store(&assets);
        usz[8] counts = store_counts(&assets);
        sz allocated = tracker.allocated();
        @pool() {
            String source = with_extras(`{"c3d_events":{"version":1,"events":[{"time":2,"id":0}]}}`);
            fault result = @catch(gltf::load_model_memory(
                assets: &assets,
                bytes: (char[])source,
                base_dir: "",
                key: MODEL_KEY,
            ));
            assert(result == c3d::ASSET_FORMAT_ERROR);
        };
        assert(store_counts(&assets) == counts && tracker.allocated() == allocated);
    }
    assert(tracker.allocated() == 0);
}

fn void test_import_events_gltf_replacement_replaces_and_clears_the_table_atomically() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        MemorySource source = { .document = DOCUMENT };
        AssetStore assets = create_store(&tracker, &source);
        defer asset::destroy_asset_store(&assets);
        ModelId model = gltf::load_model(&assets, MODEL_KEY)!!;
        ClipId clip = assets.model(model).data.clips[0];
        ClipEvent* retained = assets.clip(clip).data.events.ptr;
        uint model_revision = assets.model(model).header.revision;
        uint clip_revision = assets.clip(clip).header.revision;
        usz[8] counts = store_counts(&assets);
        sz allocated = tracker.allocated();

        @pool() {
            source.document = with_extras(`{"c3d_events":{"version":1,"events":[{"time":2,"id":11}]}}`);
            assert(@catch(gltf::replace_model(&assets, model, MODEL_KEY)) == c3d::ASSET_FORMAT_ERROR);
            assert(store_counts(&assets) == counts && tracker.allocated() == allocated);
            assert(assets.model(model).header.revision == model_revision);
            assert(assets.clip(clip).header.revision == clip_revision);
            assert(assets.clip(clip).data.events.ptr == retained);
            expect_events(model_clip(&assets, model), EXPECTED_EVENTS[..]);
        };
        @pool() {
            source.document = with_extras(`{"c3d_events":{"version":1,"events":[{"time":0.75,"id":41}]}}`);
            gltf::replace_model(&assets, model, MODEL_KEY)!!;
            assert(c3d::same_id(assets.model(model).data.clips[0], clip));
            ClipEvent[1] expected = { { .time = 0.75f, .id = 41 } };
            expect_events(model_clip(&assets, model), expected[..]);
            assert(assets.clip(clip).header.revision == clip_revision + 1);
        };
        @pool() {
            source.document = without_extras();
            gltf::replace_model(&assets, model, MODEL_KEY)!!;
            assert(c3d::same_id(assets.model(model).data.clips[0], clip));
            expect_events(model_clip(&assets, model), {});
        };
    }
    assert(tracker.allocated() == 0);
}

fn void test_import_events_gltf_memory_replacement_reads_only_the_new_events() @test {
    AssetStore assets = create_store(mem);
    defer asset::destroy_asset_store(&assets);
    ModelId model = gltf::load_model_memory(
        assets: &assets,
        bytes: (char[])DOCUMENT,
        base_dir: "",
        key: MODEL_KEY,
    )!!;
    @pool() {
        String source = with_extras(`{"c3d_events":{"version":1,"events":[{"time":0.25,"id":7}]}}`);
        gltf::replace_model_memory(
            assets: &assets,
            model: model,
            bytes: (char[])source,
            base_dir: "",
            key: MODEL_KEY,
        )!!;
        ClipEvent[1] expected = { { .time = 0.25f, .id = 7 } };
        expect_events(model_clip(&assets, model), expected[..]);
    };
}

fn void test_import_events_gltf_async_publication_and_replacement_keep_explicit_order() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        MemorySource source = { .document = DOCUMENT };
        AssetStore assets = create_store(&tracker, &source);
        defer asset::destroy_asset_store(&assets);
        AsyncLoader loader = loader::create_async_loader(mem, &assets, 1)!!;
        defer loader::destroy_async_loader(&loader);
        LoadId id = loader.request(request())!!;
        assert(settle(&loader, id).phase == LoadPhase.DECODED);
        assert(loader.publish() == 1);
        LoadStatus status = loader.status(id);
        assert(status.phase == LoadPhase.PUBLISHED);
        ModelId model = status.model;
        expect_events(model_clip(&assets, model), EXPECTED_EVENTS[..]);
        loader.release(id)!!;

        @pool() {
            source.document = with_extras(
                extras: `{"c3d_events":{"version":1,"events":[{"time":0.25,"id":8},{"time":0.25,"id":7}]}}`,
            );
            id = loader.request(request(model))!!;
            assert(settle(&loader, id).phase == LoadPhase.DECODED);
            assert(loader.publish() == 1);
            status = loader.status(id);
            assert(status.phase == LoadPhase.PUBLISHED && c3d::same_id(status.model, model));
            ClipEvent[2] expected = { { .time = 0.25f, .id = 8 }, { .time = 0.25f, .id = 7 } };
            expect_events(model_clip(&assets, model), expected[..]);
            loader.release(id)!!;
        };
        @pool() {
            source.document = without_extras();
            id = loader.request(request(model))!!;
            assert(settle(&loader, id).phase == LoadPhase.DECODED && loader.publish() == 1);
            expect_events(model_clip(&assets, model), {});
            loader.release(id)!!;
        };
    }
    assert(tracker.allocated() == 0);
}

fn void test_import_events_gltf_async_malformed_replacement_preserves_live_data() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        MemorySource source = { .document = DOCUMENT };
        AssetStore assets = create_store(&tracker, &source);
        defer asset::destroy_asset_store(&assets);
        ModelId model = gltf::load_model(&assets, MODEL_KEY)!!;
        AsyncLoader loader = loader::create_async_loader(mem, &assets, 1)!!;
        defer loader::destroy_async_loader(&loader);
        uint model_revision = assets.model(model).header.revision;
        ClipId clip = assets.model(model).data.clips[0];
        ClipEvent* retained = assets.clip(clip).data.events.ptr;
        uint clip_revision = assets.clip(clip).header.revision;
        usz[8] counts = store_counts(&assets);

        @pool() {
            source.document = with_extras(`{"c3d_events":{"version":1,"events":[{"time":0,"id":-1}]}}`);
            LoadId id = loader.request(request(model))!!;
            LoadStatus status = settle(&loader, id);
            assert(status.phase == LoadPhase.FAILED && status.failure == c3d::ASSET_FORMAT_ERROR);
            assert(loader.publish() == 0 && store_counts(&assets) == counts);
            assert(assets.model(model).header.revision == model_revision);
            assert(assets.clip(clip).header.revision == clip_revision && assets.clip(clip).data.events.ptr == retained);
            expect_events(model_clip(&assets, model), EXPECTED_EVENTS[..]);
            loader.release(id)!!;
        };
    }
    assert(tracker.allocated() == 0);
}

fn void test_import_events_gltf_async_animation_disabled_ignores_metadata() @test {
    @pool() {
        MemorySource source = {
            .document = with_extras(`{"c3d_events":{"version":1,"events":"bad"}}`),
        };
        AssetStore assets = create_store(mem, &source);
        defer asset::destroy_asset_store(&assets);
        AsyncLoader loader = loader::create_async_loader(mem, &assets, 1)!!;
        defer loader::destroy_async_loader(&loader);
        LoadOptions options = asset::LOAD_OPTIONS_DEFAULT;
        options.animations = false;
        LoadId id = loader.request(request(options: options))!!;
        assert(settle(&loader, id).phase == LoadPhase.DECODED && loader.publish() == 1);
        LoadStatus status = loader.status(id);
        assert(status.phase == LoadPhase.PUBLISHED);
        assert(assets.model(status.model).data.clips.len == 0);
        loader.release(id)!!;
    };
}
