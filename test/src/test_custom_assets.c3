module c3d::test::custom_assets;

import c3d;
import c3d::asset;
import c3d::asset::custom;
import std::core::string;

struct Wave @local {
    float[] samples;
}

struct Script @local {
    int lines;
}

alias WaveId @local = CustomId{Wave};
alias WaveAsset @local = CustomAsset{Wave};

const uint WAVE_CAPACITY @local = 2;
const uint SAMPLE_COUNT @local = 4;

fn WaveId? AssetStore.add_wave_owned(&self, Wave* wave, String key = "") {
    asset::check_key(self, key)!;
    CustomPool{Wave}* pool = self.pool(Wave);
    WaveId id = pool.add({})!;
    *pool.get(id) = {
        .header = { .key = asset::copy_string(self.allocator, key), .revision = 1 },
        .data   = *wave,
    };
    asset::register_key(self, key, asset::custom_ref(Wave, id));
    return id;
}

fn WaveAsset* AssetStore.wave(&self, WaveId id) => self.pool(Wave).get(id);

fn void AssetStore.remove_wave(&self, WaveId id) {
    CustomPool{Wave}* pool = self.pool(Wave);
    WaveAsset* record = pool.get(id);
    asset::forget_key(self, record.header.key);
    asset::free_string(self.allocator, record.header.key);
    alloc::free(self.allocator, record.data.samples.ptr);
    *record = {};
    pool.remove(id);
}

fn WaveId? AssetStore.find_wave(&self, String key) => asset::custom_id(Wave, self.find(key)!);

fn void free_wave(Allocator allocator, void* data, void* user) @local {
    Wave* wave = (Wave*)data;
    alloc::free(allocator, wave.samples.ptr);
    (*(uint*)user)++;
}

fn AssetStore make_store() @local {
    return asset::create_asset_store(mem, asset::default_asset_store_desc());
}

fn Wave make_wave(Allocator allocator) @local {
    return { .samples = alloc::new_array(allocator, float, SAMPLE_COUNT) };
}

fn void test_register_gives_each_kind_its_own_pool() @test {
    AssetStore assets = make_store();
    defer asset::destroy_asset_store(&assets);
    uint hook_calls;

    assert(!assets.is_registered(Wave));
    assets.register(Wave, WAVE_CAPACITY, &free_wave, &hook_calls)!!;
    assets.register(Script, 1)!!;
    assert(assets.is_registered(Wave));
    assert(assets.is_registered(Script));
    assert((void*)assets.pool(Wave) != (void*)assets.pool(Script));

    assets.register(Wave, 16)!!;
    for (uint index = 0; index < WAVE_CAPACITY; index++) {
        Wave wave = make_wave(assets.allocator);
        assets.add_wave_owned(&wave)!!;
    }
    Wave extra = make_wave(assets.allocator);
    if (catch excuse = assets.add_wave_owned(&extra)) {
        assert(excuse == c3d::CAPACITY_EXCEEDED);
    } else {
        assert(false);
    }
    alloc::free(assets.allocator, extra.samples.ptr);
}

fn void test_owner_layer_follows_the_builtin_protocol() @test {
    AssetStore assets = make_store();
    defer asset::destroy_asset_store(&assets);
    uint hook_calls;
    assets.register(Wave, WAVE_CAPACITY, &free_wave, &hook_calls)!!;
    assets.register(Script, 1)!!;

    Wave wave = make_wave(assets.allocator);
    WaveId id = assets.add_wave_owned(&wave, "audio/wave")!!;
    assert(assets.wave(id).header.revision == 1);

    AssetRef ref = assets.find("audio/wave")!!;
    assert(ref.kind == AssetKind.CUSTOM);
    assert(ref.slot == custom::slot{Wave});
    WaveId found = assets.find_wave("audio/wave")!!;
    assert(c3d::same_id(found, id));

    if (catch excuse = assets.find_texture("audio/wave")) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false);
    }
    if (catch excuse = asset::custom_id(Script, ref)) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false);
    }

    Wave duplicate = make_wave(assets.allocator);
    if (catch excuse = assets.add_wave_owned(&duplicate, "audio/wave")) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false);
    }
    assets.add_wave_owned(&duplicate)!!;

    assets.remove_wave(id);
    assert(!assets.pool(Wave).is_live(id));
    if (catch excuse = assets.find("audio/wave")) {
        assert(excuse == NOT_FOUND);
    } else {
        assert(false);
    }
}

fn void test_destroy_runs_the_hook_on_live_records_only() @test {
    AssetStore assets = make_store();
    uint hook_calls;
    assets.register(Wave, 3, &free_wave, &hook_calls)!!;

    WaveId[3] ids;
    foreach (&id : ids) {
        Wave wave = make_wave(assets.allocator);
        *id = assets.add_wave_owned(&wave)!!;
    }
    assets.remove_wave(ids[1]);
    asset::destroy_asset_store(&assets);

    assert(hook_calls == 2);
}

fn void test_two_stores_share_the_slot_and_own_their_pools() @test {
    AssetStore first = make_store();
    defer asset::destroy_asset_store(&first);
    AssetStore second = make_store();
    defer asset::destroy_asset_store(&second);
    AssetStore unregistered = make_store();
    defer asset::destroy_asset_store(&unregistered);
    uint first_calls;
    uint second_calls;

    first.register(Wave, WAVE_CAPACITY, &free_wave, &first_calls)!!;
    uint slot = custom::slot{Wave};
    second.register(Wave, WAVE_CAPACITY, &free_wave, &second_calls)!!;
    assert(custom::slot{Wave} == slot);

    Wave wave = make_wave(first.allocator);
    first.add_wave_owned(&wave)!!;
    assert((void*)first.pool(Wave) != (void*)second.pool(Wave));
    assert(first.pool(Wave).free_count == WAVE_CAPACITY - 1);
    assert(second.pool(Wave).free_count == WAVE_CAPACITY);
    assert(!unregistered.is_registered(Wave));
}

fn void test_key_capacity_setup_preserves_refs_and_repeated_registration() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        AssetStore assets = asset::create_asset_store(&tracker, {
            .max_geometries = 1, .max_textures = asset::BUILTIN_TEXTURE_COUNT,
            .max_materials = 64, .max_samplers = asset::BUILTIN_SAMPLER_COUNT,
            .max_environments = 1, .max_models = 1, .max_skeletons = 1,
            .max_clips = 1, .max_shaders = 1, .max_compute_shaders = 1, .max_fonts = 1,
        });
        defer asset::destroy_asset_store(&assets);
        void* buckets = assets.keys.table.ptr;
        assert(@sizeof(assets.keys) == 48 && @sizeof(assets.keys.table[0]) == 8
          && @sizeof(*assets.keys.table[0]) == 48);
        MaterialId[64] materials;
        @pool() {
            for (uint index = 0; index < materials.len; index++) {
                materials[index] = assets.add_material({}, string::tformat("material_%s", index))!!;
                assert((void*)assets.keys.table.ptr == buckets);
            }
        };
        ModelDocument document = asset::create_model_document(&tracker, "capacity", {});
        defer asset::destroy_model_document(&document);
        ModelId model = assets.publish_document(&document)!!;
        assert((void*)assets.keys.table.ptr == buckets);
        uint hook_calls;
        assets.register(
            Wave,
            capacity: 512,
            on_destroy: &free_wave,
            user: &hook_calls,
        )!!;
        void* expanded = assets.keys.table.ptr;
        assert(expanded != buckets);
        assert(c3d::same_id(assets.find_material("material_63")!!, materials[63]));
        assert(c3d::same_id(assets.find_model("capacity")!!, model));
        assets.register(Wave, 1024)!!;
        assert((void*)assets.keys.table.ptr == expanded && assets.pool(Wave).items.len == 512);
        Wave wave = make_wave(&tracker);
        assets.add_wave_owned(&wave, "custom_wave")!!;
        assert((void*)assets.keys.table.ptr == expanded);
        assert(assets.find_wave("custom_wave")!!.generation != 0);
    }
    assert(!tracker.has_leaks());
}
