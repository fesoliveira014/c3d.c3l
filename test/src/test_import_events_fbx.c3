module c3d::test::import_events_fbx;

import c3d;
import c3d::anim;
import c3d::anim::retarget;
import c3d::asset;
import c3d::asset::fbx;
import c3d::asset::loader;
import std::math::quaternion;
import std::thread;

const String MODEL_PATH @local = "memory/events.fbx";
const String TARGET_PATH @local = "memory/event_target.fbx";
const char[*] FBX_EVENTS @local = $embed("../fixtures/animation_events/fbx-events-v1.fbx");
const String AUTHORED_EVENTS @local = "{\"version\":1,\"events\":[{\"time\":1,\"id\":4294967295},"
  "{\"time\":0.5,\"id\":7},{\"time\":0,\"id\":0},{\"time\":0.5,\"id\":7},{\"time\":0.5,\"id\":11}]}";
const ClipEvent[5] EXPECTED_EVENTS @local = {
    { .time = 0, .id = 0 },
    { .time = 0.5, .id = 7 },
    { .time = 0.5, .id = 7 },
    { .time = 0.5, .id = 11 },
    { .time = 1, .id = uint::max },
};

const String NEGATIVE_ORIGIN_CHANNELS @local = `    AnimationCurveNode: 212, "AnimCurveNode::R", "" {
        Properties70: {
            P: "d|X", "Number", "", "A", 0
            P: "d|Y", "Number", "", "A", 0
            P: "d|Z", "Number", "", "A", 0
        }
    }
    AnimationCurveNode: 222, "AnimCurveNode::S", "" {
        Properties70: {
            P: "d|X", "Number", "", "A", 1
            P: "d|Y", "Number", "", "A", 1
            P: "d|Z", "Number", "", "A", 1
        }
    }
    AnimationCurve: 213, "AnimCurve::RotationY", "" {
        Default: 0
        KeyVer: 4009
        KeyTime: *2 {
            a: 0,46186158000
        }
        KeyValueFloat: *2 {
            a: 0,10
        }
        KeyAttrFlags: *1 {
            a: 1028
        }
        KeyAttrDataFloat: *4 {
            a: 0,0,0,0
        }
        KeyAttrRefCount: *1 {
            a: 2
        }
    }
    AnimationCurve: 223, "AnimCurve::ScaleX", "" {
        Default: 1
        KeyVer: 4009
        KeyTime: *2 {
            a: 0,46186158000
        }
        KeyValueFloat: *2 {
            a: 1,2
        }
        KeyAttrFlags: *1 {
            a: 1028
        }
        KeyAttrDataFloat: *4 {
            a: 0,0,0,0
        }
        KeyAttrRefCount: *1 {
            a: 2
        }
    }
    AnimationCurve: 224, "AnimCurve::ScaleY", "" {
        Default: 1
        KeyVer: 4009
        KeyTime: *2 {
            a: 0,46186158000
        }
        KeyValueFloat: *2 {
            a: 1,2
        }
        KeyAttrFlags: *1 {
            a: 1028
        }
        KeyAttrDataFloat: *4 {
            a: 0,0,0,0
        }
        KeyAttrRefCount: *1 {
            a: 2
        }
    }
    AnimationCurve: 225, "AnimCurve::ScaleZ", "" {
        Default: 1
        KeyVer: 4009
        KeyTime: *2 {
            a: 0,46186158000
        }
        KeyValueFloat: *2 {
            a: 1,2
        }
        KeyAttrFlags: *1 {
            a: 1028
        }
        KeyAttrDataFloat: *4 {
            a: 0,0,0,0
        }
        KeyAttrRefCount: *1 {
            a: 2
        }
    }
`;
const String NEGATIVE_ORIGIN_CONNECTIONS @local = `    C: "OO", 212,201
    C: "OP", 212,100, "Lcl Rotation"
    C: "OP", 213,212, "d|Y"
    C: "OO", 222,201
    C: "OP", 222,100, "Lcl Scaling"
    C: "OP", 223,222, "d|X"
    C: "OP", 224,222, "d|Y"
    C: "OP", 225,222, "d|Z"
`;

struct FbxEventSource @local {
    String text;
}

struct FbxEventFault @local {
    String json;
    fault expected;
}

struct FbxStoreSnapshot @local {
    sz allocated_bytes;
    usz[12] counts;
}

fn char[]? read_events(void* user, Allocator allocator, String path) @local {
    if (path != MODEL_PATH && path != TARGET_PATH) return c3d::ASSET_IO_ERROR~;
    FbxEventSource* source = user;
    char[] copy = alloc::new_array(allocator, char, source.text.len);
    copy[..] = source.text[..];
    return copy;
}

fn String event_property(String json, String type = "KString") @local {
    return string::tformat(
        "            P: \"c3d_events\", \"%s\", \"\", \"U\", \"%s\"\n",
        type,
        json.treplace("\"", "&quot;"),
    );
}

fn String event_text(String json) @local {
    return ((String)FBX_EVENTS).treplace(event_property(AUTHORED_EVENTS), event_property(json));
}

fn AssetStore event_store(Allocator allocator, FbxEventSource* source) @local {
    return asset::create_asset_store(allocator, {
        .max_geometries = 1,
        .max_textures = asset::BUILTIN_TEXTURE_COUNT,
        .max_materials = 4,
        .max_samplers = asset::BUILTIN_SAMPLER_COUNT,
        .max_models = 4,
        .max_skeletons = 1,
        .max_clips = 8,
        .file_source = { .read = &read_events, .user = source },
    });
}

fn ModelDocument? decode_events(
    Allocator allocator,
    FbxEventSource* source,
    bool animations = true,
) @local {
    return fbx::decode_model(
        allocator: allocator,
        path: MODEL_PATH,
        options: { .animations = animations },
        file_source: { .read = &read_events, .user = source },
    );
}

fn void assert_event_table(ClipEvent[] actual, ClipEvent[] expected = EXPECTED_EVENTS[..]) @local {
    assert(actual.len == expected.len);
    foreach (index, event : expected) {
        assert(actual[index].time == event.time && actual[index].id == event.id);
    }
}

fn AnimationClip* first_clip(AssetStore* assets, ModelId model) @local {
    ModelTemplate* template = &assets.model(model).data;
    assert(template.clips.len == 1);
    return &assets.clip(template.clips[0]).data;
}

fn LoadStatus settle_events(AsyncLoader* pending, LoadId id) @local {
    LoadStatus status = pending.status(id);
    while (status.phase == LoadPhase.QUEUED || status.phase == LoadPhase.DECODING) {
        thread::yield();
        status = pending.status(id);
    }
    return status;
}

fn LoadRequest event_request() @local {
    return { .path = MODEL_PATH, .format = ModelFormat.FBX, .options = asset::LOAD_OPTIONS_DEFAULT };
}

fn FbxStoreSnapshot snapshot_store(AssetStore* assets, TrackingAllocator* tracker) @local {
    return {
        .allocated_bytes = tracker.allocated(),
        .counts = {
            assets.geometries.free_count, assets.textures.free_count, assets.materials.free_count,
            assets.samplers.free_count, assets.environments.free_count, assets.models.free_count,
            assets.skeletons.free_count, assets.clips.free_count, assets.shaders.free_count,
            assets.compute_shaders.free_count, assets.fonts.free_count, (usz)assets.keys.len(),
        },
    };
}

fn void assert_store_unchanged(
    AssetStore* assets,
    TrackingAllocator* tracker,
    FbxStoreSnapshot before,
) @local {
    FbxStoreSnapshot after = snapshot_store(assets, tracker);
    assert(after.allocated_bytes == before.allocated_bytes && after.counts == before.counts);
}

fn RetargetProfile event_profile(Allocator allocator, NodeTemplate[] source, ModelTemplate* target) @local {
    NodeIndexMapping[2] mapping = {
        { .source_node = 1, .target_node = 1 },
        { .source_node = 2, .target_node = 2 },
    };
    Quat[3] calibration;
    foreach (index, node : source) calibration[index] = node.local.rotation;
    RetargetProfileDesc desc = retarget::RETARGET_PROFILE_DESC_DEFAULT;
    desc.mapping_mode = ProfileMappingMode.BY_INDEX;
    desc.index_map = mapping[..];
    desc.source_calibration = calibration[..];
    desc.target_calibration = calibration[..];
    desc.source_motion_node = 1;
    desc.target_motion_node = 1;
    desc.target_carrier = 0;
    return retarget::create_retarget_profile(
        allocator: allocator,
        source_nodes: source,
        target: target,
        desc: desc,
    )!!;
}

fn void assert_origin_paths(String text) @local {
    FbxEventSource source = { .text = text };
    ModelDocument document = decode_events(mem, &source)!!;
    defer asset::destroy_model_document(&document);
    assert(document.clips.len == 1);
    AnimationClip* decoded = &document.clips[0].data;
    assert(decoded.duration == 1);
    assert(decoded.tracks.len == 3);
    TargetPath[3] paths = { TargetPath.TRANSLATION, TargetPath.ROTATION, TargetPath.SCALE };
    foreach (index, track : decoded.tracks) {
        assert(track.path == paths[index] && decoded.targets[track.target] == 0);
        assert(track.times.len >= 2 && track.times[0] == 0 && track.times[^1] == 1);
        foreach (key, time : track.times) {
            assert(time >= 0 && time <= 1 && (key == 0 || time > track.times[key - 1]));
        }
    }
    assert_event_table(decoded.events);

    AssetStore assets = event_store(mem, &source);
    defer asset::destroy_asset_store(&assets);
    ModelId model = fbx::load_model(&assets, MODEL_PATH)!!;
    assert_event_table(first_clip(&assets, model).events);

    ClipId[] animations = fbx::load_animations(
        allocator: mem,
        assets: &assets,
        path: MODEL_PATH,
        target: model,
    )!!;
    defer alloc::free(mem, animations.ptr);
    assert(animations.len == 1);
    assert_event_table(assets.clip(animations[0]).data.events);

    RetargetProfile profile = event_profile(mem, document.template.nodes, &assets.model(model).data);
    defer retarget::destroy_retarget_profile(&profile);
    ClipId[] profiled = fbx::load_animations_with_profile(
        allocator: mem,
        assets: &assets,
        path: MODEL_PATH,
        target: model,
        profile: &profile,
        variant: "events",
    )!!;
    defer alloc::free(mem, profiled.ptr);
    assert(profiled.len == 1);
    assert_event_table(assets.clip(profiled[0]).data.events);
    AssetStore asynchronous = event_store(mem, &source);
    defer asset::destroy_asset_store(&asynchronous);
    AsyncLoader pending = loader::create_async_loader(mem, &asynchronous, 1)!!;
    defer loader::destroy_async_loader(&pending);
    LoadId id = pending.request(event_request())!!;
    assert(settle_events(&pending, id).phase == LoadPhase.DECODED);
    assert(pending.publish() == 1);
    LoadStatus status = pending.status(id);
    assert(status.phase == LoadPhase.PUBLISHED);
    assert_event_table(first_clip(&asynchronous, status.model).events);
    pending.release(id)!!;
}

fn String animate_negative_origin(String text) @local {
    sz connections = text.index_of("}\nConnections:")!!;
    String prefix = string::tformat("%s%s", text[:connections], NEGATIVE_ORIGIN_CHANNELS);
    String objects = string::tformat("%s%s", prefix, text[connections..]);
    sz close = objects.len - 2;
    assert(objects[close] == '}');
    return string::tformat("%s%s}\n", objects[:close], NEGATIVE_ORIGIN_CONNECTIONS);
}

fn String without_curve(String text) @local {
    sz begin = text.index_of("    AnimationLayer: 201")!!;
    return string::tformat(
        "%s}\nConnections: {\n    C: \"OO\", 100,0\n    C: \"OO\", 101,100\n"
        "    C: \"OO\", 102,101\n}\n",
        text[:begin],
    );
}

fn void test_import_events_fbx_schema_and_stable_identity() @test {
    @pool() {
        FbxEventSource source = { .text = (String)FBX_EVENTS };
        ModelDocument document = decode_events(mem, &source)!!;
        defer asset::destroy_model_document(&document);
        assert_event_table(document.clips[0].data.events);
        assert(document.clips[0].data.duration == 1);
    };
}

fn void test_import_events_fbx_absent_empty_and_unrelated_properties() @test {
    @pool() {
        String[3] texts = {
            ((String)FBX_EVENTS).treplace(event_property(AUTHORED_EVENTS), ""),
            event_text(`{"version":1,"events":[]}`),
            ((String)FBX_EVENTS).treplace("\"c3d_events\"", "\"application_events\""),
        };
        foreach (text : texts) {
            FbxEventSource source = { .text = text };
            ModelDocument document = decode_events(mem, &source)!!;
            defer asset::destroy_model_document(&document);
            assert(document.clips.len == 1 && document.clips[0].data.events.len == 0);
        }
        FbxEventSource source = {
            .text = event_text(`{"version":1,"events":[{"time":0,"id":0,"extra":true}],"extra":[]}`),
        };
        ModelDocument document = decode_events(mem, &source)!!;
        defer asset::destroy_model_document(&document);
        ClipEvent[1] expected = { { .time = 0, .id = 0 } };
        assert_event_table(document.clips[0].data.events, expected[..]);
    };
}

fn void test_import_events_fbx_schema_faults_release_partial_clip() @test {
    @pool() {
        FbxEventFault[*] cases = {
            { .json = "", .expected = c3d::ASSET_FORMAT_ERROR },
            { .json = "{", .expected = c3d::ASSET_FORMAT_ERROR },
            { .json = "[]", .expected = c3d::ASSET_FORMAT_ERROR },
            { .json = `{"events":[]}`, .expected = c3d::ASSET_FORMAT_ERROR },
            { .json = `{"version":1}`, .expected = c3d::ASSET_FORMAT_ERROR },
            { .json = `{"version":"1","events":[]}`, .expected = c3d::ASSET_FORMAT_ERROR },
            { .json = `{"version":true,"events":[]}`, .expected = c3d::ASSET_FORMAT_ERROR },
            { .json = `{"version":1,"events":{}}`, .expected = c3d::ASSET_FORMAT_ERROR },
            { .json = `{"version":1,"events":[{}]}`, .expected = c3d::ASSET_FORMAT_ERROR },
            { .json = `{"version":1,"events":[{"time":0,"id":"0"}]}`, .expected = c3d::ASSET_FORMAT_ERROR },
            { .json = `{"version":1,"events":[{"time":0,"id":-1}]}`, .expected = c3d::ASSET_FORMAT_ERROR },
            { .json = `{"version":1,"events":[{"time":0,"id":4294967296}]}`, .expected = c3d::ASSET_FORMAT_ERROR },
            { .json = `{"version":1,"events":[{"time":0,"id":0.5}]}`, .expected = c3d::ASSET_FORMAT_ERROR },
            { .json = `{"version":1,"events":[{"time":"0","id":0}]}`, .expected = c3d::ASSET_FORMAT_ERROR },
            { .json = `{"version":1,"events":[{"time":-0.01,"id":0}]}`, .expected = c3d::ASSET_FORMAT_ERROR },
            { .json = `{"version":1,"events":[{"time":1.01,"id":0}]}`, .expected = c3d::ASSET_FORMAT_ERROR },
            { .json = `{"version":1,"events":[{"time":1e999,"id":0}]}`, .expected = c3d::ASSET_FORMAT_ERROR },
            { .json = `{"version":1,"events":[{"time":NaN,"id":0}]}`, .expected = c3d::ASSET_FORMAT_ERROR },
            { .json = `{"version":1,"version":1,"events":[]}`, .expected = c3d::ASSET_FORMAT_ERROR },
            { .json = `{"version":1,"events":[],"events":[]}`, .expected = c3d::ASSET_FORMAT_ERROR },
            { .json = `{"version":1,"events":[{"time":0,"time":0,"id":0}]}`, .expected = c3d::ASSET_FORMAT_ERROR },
            { .json = `{"version":1,"events":[{"time":0,"id":0,"id":0}]}`, .expected = c3d::ASSET_FORMAT_ERROR },
            { .json = `{"version":2,"events":[]}`, .expected = c3d::UNSUPPORTED },
        };
        TrackingAllocator tracker;
        tracker.init(mem);
        defer tracker.free();
        foreach (row : cases) {
            FbxEventSource source = { .text = event_text(row.json) };
            assert(@catch(decode_events(&tracker, &source)) == row.expected, "metadata: %s", row.json);
            assert(tracker.allocated() == 0, "metadata leaked: %s", row.json);
        }
    };
}

fn void test_import_events_fbx_property_requires_string() @test {
    @pool() {
        FbxEventSource source = {
            .text = ((String)FBX_EVENTS).treplace(
                needle: event_property(AUTHORED_EVENTS),
                new_str: "            P: \"c3d_events\", \"int\", \"Integer\", \"U\", 1\n",
            ),
        };
        assert(@catch(decode_events(mem, &source)) == c3d::ASSET_FORMAT_ERROR);
    };
}

fn void test_import_events_fbx_animation_disabled_ignores_recognized_faults() @test {
    @pool() {
        String[2] texts = {
            event_text("{"),
            ((String)FBX_EVENTS).treplace(
                needle: event_property(AUTHORED_EVENTS),
                new_str: "            P: \"c3d_events\", \"int\", \"Integer\", \"U\", 1\n",
            ),
        };
        foreach (text : texts) {
            FbxEventSource source = { .text = text };
            ModelDocument document = decode_events(mem, &source, false)!!;
            defer asset::destroy_model_document(&document);
            assert(document.clips.len == 0 && document.template.clips.len == 0);
        }
    };
}

fn void test_import_events_fbx_zero_and_negative_stack_origins_keep_keys() @test {
    @pool() {
        assert_origin_paths((String)FBX_EVENTS);
        String negative = ((String)FBX_EVENTS).treplace(
            needle: "P: \"LocalStart\", \"KTime\", \"Time\", \"\", 0",
            new_str: "P: \"LocalStart\", \"KTime\", \"Time\", \"\", -46186158000",
        );
        assert_origin_paths(animate_negative_origin(negative));
    };
}

fn void test_import_events_fbx_positive_origin_trims_tracks_not_markers() @test {
    @pool() {
        String positive = ((String)FBX_EVENTS).treplace(
            needle: "P: \"LocalStart\", \"KTime\", \"Time\", \"\", 0",
            new_str: "P: \"LocalStart\", \"KTime\", \"Time\", \"\", 46186158000",
        )
          .treplace(
              needle: "P: \"LocalStop\", \"KTime\", \"Time\", \"\", 46186158000",
              new_str: "P: \"LocalStop\", \"KTime\", \"Time\", \"\", 92372316000",
          )
          .treplace("a: 0,46186158000", "a: 46186158000,92372316000");
        assert_origin_paths(positive);
    };
}

fn void test_import_events_fbx_negative_track_keys_preserve_profile_rejection() @test {
    @pool() {
        FbxEventSource source = {
            .text = ((String)FBX_EVENTS).treplace(
                needle: "P: \"LocalStart\", \"KTime\", \"Time\", \"\", 0",
                new_str: "P: \"LocalStart\", \"KTime\", \"Time\", \"\", -46186158000",
            )
              .treplace("a: 0,46186158000", "a: -46186158000,46186158000"),
        };
        ModelDocument document = decode_events(mem, &source)!!;
        defer asset::destroy_model_document(&document);
        assert(document.clips[0].data.tracks[0].times[0] == -1);
        assert(document.clips[0].data.duration == 1);
        assert_event_table(document.clips[0].data.events);
        RetargetProfile profile = event_profile(mem, document.template.nodes, &document.template);
        defer retarget::destroy_retarget_profile(&profile);
        assert(@catch(retarget::retarget_with_profile(
            allocator: mem,
            source: &document.clips[0].data,
            source_nodes: document.template.nodes,
            target: &document.template,
            profile: &profile,
        )) == c3d::ASSET_FORMAT_ERROR);
    };
}

fn void test_import_events_fbx_event_only_and_zero_duration_do_not_extend_clip() @test {
    @pool() {
        String no_curve = without_curve(event_text(`{"version":1,"events":[{"time":0,"id":9}]}`));
        String zero_curve = event_text(`{"version":1,"events":[{"time":0,"id":9}]}`)
          .treplace("KeyTime: *2", "KeyTime: *1")
          .treplace("a: 0,46186158000", "a: 0")
          .treplace("KeyValueFloat: *2", "KeyValueFloat: *1")
          .treplace("a: 0,1", "a: 0")
          .treplace("a: 2", "a: 1")
          .treplace(
              needle: "P: \"LocalStop\", \"KTime\", \"Time\", \"\", 46186158000",
              new_str: "P: \"LocalStop\", \"KTime\", \"Time\", \"\", 0",
          );
        foreach (text : (String[2]){ no_curve, zero_curve }) {
            FbxEventSource source = { .text = text };
            ModelDocument document = decode_events(mem, &source)!!;
            defer asset::destroy_model_document(&document);
            assert(document.clips[0].data.duration == 0);
            ClipEvent[1] expected = { { .time = 0, .id = 9 } };
            assert_event_table(document.clips[0].data.events, expected[..]);
            source.text = text.treplace("&quot;time&quot;:0", "&quot;time&quot;:0.25");
            assert(@catch(decode_events(mem, &source)) == c3d::ASSET_FORMAT_ERROR);
        }
    };
}

fn void test_import_events_fbx_document_sync_and_async_tables_match() @test {
    @pool() {
        FbxEventSource source = { .text = (String)FBX_EVENTS };
        ModelDocument document = decode_events(mem, &source)!!;
        defer asset::destroy_model_document(&document);
        AssetStore published = event_store(mem, &source);
        defer asset::destroy_asset_store(&published);
        ModelId published_model = published.publish_document(&document)!!;
        assert_event_table(first_clip(&published, published_model).events);
        AssetStore synchronous = event_store(mem, &source);
        defer asset::destroy_asset_store(&synchronous);
        ModelId synchronous_model = fbx::load_model(&synchronous, MODEL_PATH)!!;
        assert_event_table(first_clip(&synchronous, synchronous_model).events);
        AssetStore asynchronous = event_store(mem, &source);
        defer asset::destroy_asset_store(&asynchronous);
        AsyncLoader pending = loader::create_async_loader(mem, &asynchronous, 1)!!;
        defer loader::destroy_async_loader(&pending);
        LoadId id = pending.request(event_request())!!;
        assert(settle_events(&pending, id).phase == LoadPhase.DECODED);
        assert(pending.publish() == 1);
        LoadStatus status = pending.status(id);
        assert(status.phase == LoadPhase.PUBLISHED);
        assert_event_table(first_clip(&asynchronous, status.model).events);
        pending.release(id)!!;
    };
}

fn void test_import_events_fbx_replacement_replaces_clears_and_rolls_back() @test {
    @pool() {
        FbxEventSource source = { .text = (String)FBX_EVENTS };
        AssetStore assets = event_store(mem, &source);
        defer asset::destroy_asset_store(&assets);
        ModelId model = fbx::load_model(&assets, MODEL_PATH)!!;
        ClipId original = assets.model(model).data.clips[0];
        source.text = event_text(`{"version":1,"events":[{"time":0.25,"id":42}]}`);
        fbx::replace_model(&assets, model, MODEL_PATH)!!;
        assert(c3d::same_id(original, assets.model(model).data.clips[0]));
        ClipEvent[1] replacement = { { .time = 0.25, .id = 42 } };
        assert_event_table(first_clip(&assets, model).events, replacement[..]);
        uint model_revision = assets.model(model).header.revision;
        uint clip_revision = assets.clip(original).header.revision;
        NodeTemplate* nodes = assets.model(model).data.nodes.ptr;
        ClipEvent* events = first_clip(&assets, model).events.ptr;
        String name = first_clip(&assets, model).name;
        sz keys = assets.keys.len();
        source.text = event_text(`{"version":1,"events":[{"time":2,"id":0}]}`);
        assert(@catch(fbx::replace_model(&assets, model, MODEL_PATH)) == c3d::ASSET_FORMAT_ERROR);
        assert(assets.model(model).header.revision == model_revision
          && assets.clip(original).header.revision == clip_revision);
        assert(assets.model(model).data.nodes.ptr == nodes && first_clip(&assets, model).events.ptr == events);
        assert(first_clip(&assets, model).name == name && assets.keys.len() == keys);
        assert_event_table(first_clip(&assets, model).events, replacement[..]);
        source.text = ((String)FBX_EVENTS).treplace(event_property(AUTHORED_EVENTS), "");
        fbx::replace_model(&assets, model, MODEL_PATH)!!;
        assert(c3d::same_id(original, assets.model(model).data.clips[0]));
        assert(first_clip(&assets, model).events.len == 0);
    };
}

fn void test_import_events_fbx_all_load_paths_report_same_schema_fault() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    @pool() {
        FbxEventSource source = { .text = (String)FBX_EVENTS };
        AssetStore assets = event_store(&tracker, &source);
        defer asset::destroy_asset_store(&assets);
        ModelId target = fbx::load_model(&assets, TARGET_PATH, { .animations = false })!!;
        RetargetProfile profile = event_profile(&tracker, assets.model(target).data.nodes, &assets.model(target).data);
        defer retarget::destroy_retarget_profile(&profile);
        FbxEventFault[2] cases = {
            { .json = `{"version":1,"events":[{"time":2,"id":0}]}`, .expected = c3d::ASSET_FORMAT_ERROR },
            { .json = `{"version":2,"events":[]}`, .expected = c3d::UNSUPPORTED },
        };
        foreach (row : cases) {
            source.text = event_text(row.json);
            FbxStoreSnapshot before = snapshot_store(&assets, &tracker);
            assert(@catch(decode_events(&tracker, &source)) == row.expected);
            assert_store_unchanged(&assets, &tracker, before);

            before = snapshot_store(&assets, &tracker);
            assert(@catch(fbx::load_model(&assets, MODEL_PATH)) == row.expected);
            assert_store_unchanged(&assets, &tracker, before);

            before = snapshot_store(&assets, &tracker);
            assert(@catch(fbx::load_animations(
                allocator: &tracker,
                assets: &assets,
                path: MODEL_PATH,
                target: target,
            )) == row.expected);
            assert_store_unchanged(&assets, &tracker, before);

            before = snapshot_store(&assets, &tracker);
            assert(@catch(fbx::load_animations_with_profile(
                allocator: &tracker,
                assets: &assets,
                path: MODEL_PATH,
                target: target,
                profile: &profile,
                variant: "bad_events",
            )) == row.expected);
            assert_store_unchanged(&assets, &tracker, before);
            assert(assets.model(target).header.revision == 1);

            AsyncLoader pending = loader::create_async_loader(mem, &assets, 1)!!;
            defer loader::destroy_async_loader(&pending);
            before = snapshot_store(&assets, &tracker);
            LoadId id = pending.request(event_request())!!;
            LoadStatus status = settle_events(&pending, id);
            assert(status.phase == LoadPhase.FAILED && status.failure == row.expected);
            assert(pending.publish() == 0);
            assert_store_unchanged(&assets, &tracker, before);
            pending.release(id)!!;
            assert_store_unchanged(&assets, &tracker, before);
        }
    };
    assert(tracker.allocated() == 0);
}
