module c3d::test::async_loader;

import c3d;
import c3d::asset @public;
import c3d::asset::gltf;
import c3d::asset::loader @public;
import c3d::test::loading_fixtures;
import std::io::path;
import std::thread;

struct Holder @local {
    AsyncLoader loader;
}

struct GatedSource @local {
    Allocator         allocator;
    Mutex             lock;
    ConditionVariable changed;
    char[]            bytes;
    char[]            large;
    bool              hold_read;
    bool              entered;
    bool              allowed;
    bool              fail_read;
    String            fail_path;
    uint              reads;
    bool              destroy_started;
    bool              destroy_finished;
}

struct DestroyContext @local {
    AsyncLoader* loader;
    GatedSource* source;
}

fn void GatedSource.wait_entered(&self) {
    self.lock.lock();
    defer self.lock.unlock();
    while (!self.entered) self.changed.wait(&self.lock);
}

fn void GatedSource.allow_read(&self) {
    self.lock.lock();
    defer self.lock.unlock();
    self.allowed = true;
    self.changed.broadcast();
}

fn GatedSource create_gated_source(Allocator allocator, bool hold_read = false) @local {
    GatedSource source = {
        .allocator = allocator,
        .bytes = loading_fixtures::small_model_gltf(allocator),
        .large = loading_fixtures::small_model_gltf(allocator, 64),
        .hold_read = hold_read,
    };
    source.lock.init()!!;
    source.changed.init()!!;
    return source;
}

fn void destroy_gated_source(GatedSource* source) @local {
    source.changed.destroy();
    source.lock.destroy();
    alloc::free(source.allocator, source.bytes.ptr);
    alloc::free(source.allocator, source.large.ptr);
}

fn char[]? read_gated(void* user, Allocator allocator, String path) @local {
    GatedSource* source = user;
    source.lock.lock();
    defer source.lock.unlock();
    source.reads++;
    if (source.hold_read && !source.entered) {
        source.entered = true;
        source.changed.broadcast();
        while (!source.allowed) source.changed.wait(&source.lock);
    }
    if (source.fail_read || source.fail_path == path) return c3d::ASSET_IO_ERROR~;
    char[] source_bytes = path.starts_with("large") ? source.large : source.bytes;
    char[] bytes = alloc::new_array(allocator, char, (sz)source_bytes.len);
    mem::copy(bytes.ptr, source_bytes.ptr, source_bytes.len);
    return bytes;
}

fn AssetStore gated_store(Allocator allocator, GatedSource* source) @local {
    AssetStoreDesc desc = asset::default_asset_store_desc();
    desc.file_source = { .read = &read_gated, .user = source };
    return asset::create_asset_store(allocator, desc);
}

fn LoadRequest generated_request(String path, AssetRef[] missing = {}) @local {
    return {
        .path    = path,
        .format  = ModelFormat.GLTF,
        .options = asset::LOAD_OPTIONS_DEFAULT,
        .missing = missing,
    };
}

fn int destroy_gated_loader(void* user) @local {
    DestroyContext* context = user;
    context.source.lock.lock();
    context.source.destroy_started = true;
    context.source.changed.broadcast();
    context.source.lock.unlock();
    loader::destroy_async_loader(context.loader);
    context.source.lock.lock();
    context.source.destroy_finished = true;
    context.source.changed.broadcast();
    context.source.lock.unlock();
    return 0;
}

fn String fixture_path(String name) @local {
    Path source = path::tnew($$FILEPATH)!!;
    return (String)source.parent()!!.tappend("../fixtures/gltf", name)!!;
}

fn String fbx_fixture_path(String name) @local {
    Path source = path::tnew($$FILEPATH)!!;
    return (String)source.parent()!!.tappend("../fixtures/fbx", name)!!;
}

fn LoadRequest gltf_request(String name) @local {
    return { .path = fixture_path(name), .format = ModelFormat.GLTF, .options = asset::LOAD_OPTIONS_DEFAULT };
}

fn AssetStore create_store(Allocator allocator) @local {
    return asset::create_asset_store(allocator, asset::default_asset_store_desc());
}

// Waits on the phase alone, so no test depends on how long a decode takes.
fn LoadStatus settle(AsyncLoader* loader, LoadId id) @local {
    LoadStatus status = loader.status(id);
    while (status.phase == LoadPhase.QUEUED || status.phase == LoadPhase.DECODING || status.phase == LoadPhase.CANCELLING) {
        thread::yield();
        status = loader.status(id);
    }
    return status;
}

fn AsyncLoader start_loader(AssetStore* assets) @local => loader::create_async_loader(mem, assets, 2)!!;

fn ulong decoded_items(AsyncLoader* loader, LoadId id) @local => loader.state.slots[id.index].prepared.items;

fn usz[8] store_counts(AssetStore* assets) @local {
    return {
        assets.geometries.free_count, assets.textures.free_count, assets.materials.free_count,
        assets.samplers.free_count, assets.models.free_count, assets.skeletons.free_count,
        assets.clips.free_count, (usz)assets.keys.len(),
    };
}

fn void test_async_load_publishes_the_same_model_as_load_model() @test {
    AssetStore async_store = create_store(mem);
    defer asset::destroy_asset_store(&async_store);
    AssetStore sync_store = create_store(mem);
    defer asset::destroy_asset_store(&sync_store);
    AsyncLoader loader = loader::create_async_loader(mem, &async_store)!!;
    defer loader::destroy_async_loader(&loader);

    LoadId id = loader.request(gltf_request("skin.gltf"))!!;
    assert(settle(&loader, id).phase == LoadPhase.DECODED);
    assert(loader.publish() == 1);
    LoadStatus status = loader.status(id);
    assert(status.phase == LoadPhase.PUBLISHED && async_store.models.is_live(status.model));
    ModelId expected = gltf::load_model(&sync_store, fixture_path("skin.gltf"))!!;

    assert(async_store.keys.len() == sync_store.keys.len());
    ModelTemplate* published = &async_store.model(status.model).data;
    ModelTemplate* loaded = &sync_store.model(expected).data;
    assert(published.nodes.len == loaded.nodes.len);
    foreach (index, node : published.nodes) assert(node.name == loaded.nodes[index].name);
    assert(published.meshes.len == loaded.meshes.len && published.skins.len == loaded.skins.len);
    assert(published.clips.len == loaded.clips.len);
    loader.release(id)!!;
}

fn void test_failed_decode_reports_the_importer_fault() @test {
    AssetStore assets = create_store(mem);
    defer asset::destroy_asset_store(&assets);
    AsyncLoader loader = loader::create_async_loader(mem, &assets)!!;
    defer loader::destroy_async_loader(&loader);
    sz keys = assets.keys.len();

    LoadStatus missing = settle(&loader, loader.request(gltf_request("missing.gltf"))!!);
    assert(missing.phase == LoadPhase.FAILED && missing.failure == c3d::ASSET_IO_ERROR);
    LoadStatus unsupported = settle(&loader, loader.request(gltf_request("unsupported.gltf"))!!);
    assert(unsupported.phase == LoadPhase.FAILED && unsupported.failure == c3d::UNSUPPORTED);
    assert(assets.keys.len() == keys);
}

fn void test_wrong_format_fails_with_the_importer_fault() @test {
    AssetStore assets = create_store(mem);
    defer asset::destroy_asset_store(&assets);
    AsyncLoader loader = loader::create_async_loader(mem, &assets)!!;
    defer loader::destroy_async_loader(&loader);

    LoadRequest fbx_as_gltf = {
        .path    = fbx_fixture_path("maya_cube_7400_binary.fbx"),
        .format  = ModelFormat.GLTF,
        .options = asset::LOAD_OPTIONS_DEFAULT,
    };
    LoadStatus gltf_status = settle(&loader, loader.request(fbx_as_gltf)!!);
    assert(gltf_status.phase == LoadPhase.FAILED && gltf_status.failure == c3d::ASSET_FORMAT_ERROR);
    LoadRequest gltf_as_fbx = {
        .path    = fixture_path("quad.gltf"),
        .format  = ModelFormat.FBX,
        .options = asset::LOAD_OPTIONS_DEFAULT,
    };
    LoadStatus fbx_status = settle(&loader, loader.request(gltf_as_fbx)!!);
    assert(fbx_status.phase == LoadPhase.FAILED && fbx_status.failure == c3d::ASSET_FORMAT_ERROR);
}

fn void test_request_rejects_a_key_in_the_store() @test {
    AssetStore assets = create_store(mem);
    defer asset::destroy_asset_store(&assets);
    AsyncLoader loader = loader::create_async_loader(mem, &assets)!!;
    defer loader::destroy_async_loader(&loader);

    LoadId id = loader.request(gltf_request("quad.gltf"))!!;
    assert(settle(&loader, id).phase == LoadPhase.DECODED);
    assert(loader.publish() == 1);
    loader.release(id)!!;

    assert(@catch(loader.request(gltf_request("quad.gltf"))) == c3d::INVALID_ARGUMENT);
}

fn void test_request_rejects_a_pending_path() @test {
    AssetStore assets = create_store(mem);
    defer asset::destroy_asset_store(&assets);
    AsyncLoader loader = loader::create_async_loader(mem, &assets, 1)!!;
    defer loader::destroy_async_loader(&loader);

    LoadId id = loader.request(gltf_request("quad.gltf"))!!;
    assert(@catch(loader.request(gltf_request("quad.gltf"))) == c3d::INVALID_ARGUMENT);
    assert(settle(&loader, id).phase == LoadPhase.DECODED);
}

fn void test_request_after_failed_is_accepted() @test {
    AssetStore assets = create_store(mem);
    defer asset::destroy_asset_store(&assets);
    AsyncLoader loader = loader::create_async_loader(mem, &assets, 2)!!;
    defer loader::destroy_async_loader(&loader);

    LoadId first = loader.request(gltf_request("missing.gltf"))!!;
    assert(settle(&loader, first).phase == LoadPhase.FAILED);
    LoadId second = loader.request(gltf_request("missing.gltf"))!!;
    assert(!c3d::same_id(first, second));
}

fn void test_request_faults_when_every_slot_is_unreleased() @test {
    AssetStore assets = create_store(mem);
    defer asset::destroy_asset_store(&assets);
    AsyncLoader loader = loader::create_async_loader(mem, &assets, 2)!!;
    defer loader::destroy_async_loader(&loader);

    LoadId first = loader.request(gltf_request("missing_a.gltf"))!!;
    LoadId second = loader.request(gltf_request("missing_b.gltf"))!!;
    assert(settle(&loader, first).phase == LoadPhase.FAILED);
    assert(settle(&loader, second).phase == LoadPhase.FAILED);
    assert(@catch(loader.request(gltf_request("missing_c.gltf"))) == c3d::CAPACITY_EXCEEDED);

    loader.release(first)!!;
    loader.request(gltf_request("missing_c.gltf"))!!;
}

fn void test_released_id_is_stale() @test {
    AssetStore assets = create_store(mem);
    defer asset::destroy_asset_store(&assets);
    AsyncLoader loader = loader::create_async_loader(mem, &assets, 1)!!;
    defer loader::destroy_async_loader(&loader);

    LoadId old = loader.request(gltf_request("missing.gltf"))!!;
    assert(settle(&loader, old).phase == LoadPhase.FAILED);
    loader.release(old)!!;

    LoadStatus stale = loader.status(old);
    assert(stale.phase == LoadPhase.FAILED && stale.failure == c3d::INVALID_ID);
    assert(@catch(loader.release(old)) == c3d::INVALID_ID);
    LoadStatus unrequested = loader.status({});
    assert(unrequested.phase == LoadPhase.FAILED && unrequested.failure == c3d::INVALID_ID);
    LoadId fresh = loader.request(gltf_request("missing.gltf"))!!;
    assert(fresh.index == old.index && fresh.generation != old.generation);
}

fn void test_publish_failure_fails_the_slot_and_continues() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    AssetStore assets = create_store(&tracker);
    AsyncLoader loader = loader::create_async_loader(&tracker, &assets)!!;

    LoadId first = loader.request(gltf_request("quad.gltf"))!!;
    LoadId second = loader.request(gltf_request("hierarchy.gltf"))!!;
    assert(settle(&loader, first).phase == LoadPhase.DECODED);
    assert(settle(&loader, second).phase == LoadPhase.DECODED);
    gltf::load_model(&assets, fixture_path("quad.gltf"))!!;
    LoadId third = loader.request(gltf_request("strip.gltf"))!!;
    assert(settle(&loader, third).phase == LoadPhase.DECODED);

    assert(loader.publish() == 3);
    LoadStatus collided = loader.status(first);
    assert(collided.phase == LoadPhase.FAILED && collided.failure == c3d::INVALID_ARGUMENT);
    foreach (id : (LoadId[2]){ second, third }) {
        LoadStatus published = loader.status(id);
        assert(published.phase == LoadPhase.PUBLISHED && assets.models.is_live(published.model));
    }
    foreach (id : (LoadId[3]){ first, second, third }) loader.release(id)!!;
    loader::destroy_async_loader(&loader);
    asset::destroy_asset_store(&assets);
    assert(tracker.allocated() == 0);
}

fn void test_publish_counts_only_its_own_transitions() @test {
    AssetStore assets = create_store(mem);
    defer asset::destroy_asset_store(&assets);
    AsyncLoader loader = loader::create_async_loader(mem, &assets)!!;
    defer loader::destroy_async_loader(&loader);

    assert(settle(&loader, loader.request(gltf_request("missing.gltf"))!!).phase == LoadPhase.FAILED);
    assert(loader.publish() == 0);
}

fn void test_publish_reports_a_full_pool() @test {
    AssetStoreDesc desc = asset::default_asset_store_desc();
    desc.max_models = 1;
    AssetStore assets = asset::create_asset_store(mem, desc);
    defer asset::destroy_asset_store(&assets);
    AsyncLoader loader = loader::create_async_loader(mem, &assets)!!;
    defer loader::destroy_async_loader(&loader);
    gltf::load_model(&assets, fixture_path("quad.gltf"))!!;
    usz[8] counts = store_counts(&assets);

    LoadId id = loader.request(gltf_request("hierarchy.gltf"))!!;
    assert(settle(&loader, id).phase == LoadPhase.DECODED);
    assert(loader.publish() == 1);

    LoadStatus status = loader.status(id);
    assert(status.phase == LoadPhase.FAILED && status.failure == c3d::CAPACITY_EXCEEDED);
    assert(store_counts(&assets) == counts);
}

fn void test_destroy_frees_unpublished_documents() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    AssetStore assets = create_store(&tracker);
    defer asset::destroy_asset_store(&assets);
    sz before = tracker.allocated();
    AsyncLoader loader = loader::create_async_loader(&tracker, &assets)!!;

    LoadId id = loader.request(gltf_request("skin.gltf"))!!;
    assert(settle(&loader, id).phase == LoadPhase.DECODED);
    loader::destroy_async_loader(&loader);

    assert(tracker.allocated() == before);
}

fn void test_destroy_after_request_frees_everything() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    AssetStore assets = create_store(&tracker);
    defer asset::destroy_asset_store(&assets);
    sz before = tracker.allocated();
    AsyncLoader loader = loader::create_async_loader(&tracker, &assets)!!;

    loader.request(gltf_request("quad.gltf"))!!;
    loader.request(gltf_request("hierarchy.gltf"))!!;
    loader::destroy_async_loader(&loader);

    assert(tracker.allocated() == before);
}

fn void test_loader_survives_a_move_of_its_handle() @test {
    AssetStore assets = create_store(mem);
    defer asset::destroy_asset_store(&assets);
    Holder holder = { .loader = start_loader(&assets) };

    LoadId id = holder.loader.request(gltf_request("quad.gltf"))!!;
    assert(settle(&holder.loader, id).phase == LoadPhase.DECODED);
    assert(holder.loader.publish() == 1);
    LoadStatus status = holder.loader.status(id);
    assert(status.phase == LoadPhase.PUBLISHED);
    holder.loader.release(id)!!;
    loader::destroy_async_loader(&holder.loader);

    assert(assets.models.is_live(status.model));
}

fn void test_queued_cancel_prevents_source_read_and_preserves_missing() @test {
    GatedSource source = create_gated_source(mem, true);
    defer destroy_gated_source(&source);
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    AssetStore assets = gated_store(&tracker, &source);
    usz[8] before = store_counts(&assets);
    AsyncLoader loader = loader::create_async_loader(&tracker, &assets, 2)!!;
    AssetRef[1] missing = { { .kind = AssetKind.GEOMETRY, .id = { .index = 7, .generation = 9 } } };
    AssetRef sentinel = missing[0];

    LoadId active = loader.request(generated_request("active.gltf"))!!;
    source.wait_entered();
    LoadId queued = loader.request(generated_request("queued.gltf", missing[..]))!!;
    assert(loader.status(queued).phase == LoadPhase.QUEUED);
    loader.cancel(queued)!!;
    loader.cancel(queued)!!;
    assert(loader.status(queued).phase == LoadPhase.CANCELLED);
    assert(missing[0].kind == sentinel.kind && missing[0].slot == sentinel.slot);
    assert(c3d::same_id(missing[0].id, sentinel.id) && store_counts(&assets) == before);
    loader.release(queued)!!;
    source.allow_read();
    assert(settle(&loader, active).phase == LoadPhase.DECODED);
    assert(source.reads == 1);
    assert(loader.counters().cancellations == 1);
    loader::destroy_async_loader(&loader);
    asset::destroy_asset_store(&assets);
    assert(tracker.allocated() == 0);
}

fn void test_active_cancel_acknowledges_success_and_fault_without_failure() @test {
    foreach (faulting : (bool[2]){ false, true }) {
        GatedSource source = create_gated_source(mem, true);
        source.fail_read = faulting;
        defer destroy_gated_source(&source);
        TrackingAllocator tracker;
        tracker.init(mem);
        defer tracker.free();
        AssetStore assets = gated_store(&tracker, &source);
        usz[8] before = store_counts(&assets);
        AsyncLoader loader = loader::create_async_loader(&tracker, &assets, 1)!!;
        AssetRef[1] missing = { { .kind = AssetKind.CLIP, .id = { .index = 3, .generation = 6 } } };
        AssetRef sentinel = missing[0];

        LoadId active = loader.request(generated_request("active.gltf", missing[..]))!!;
        source.wait_entered();
        assert(loader.status(active).phase == LoadPhase.DECODING);
        loader.cancel(active)!!;
        loader.cancel(active)!!;
        assert(loader.status(active).phase == LoadPhase.CANCELLING);
        assert(@catch(loader.request(generated_request("active.gltf"))) == c3d::INVALID_ARGUMENT);
        assert(@catch(loader.request(generated_request("other.gltf"))) == c3d::CAPACITY_EXCEEDED);
        source.allow_read();
        LoadStatus status = settle(&loader, active);
        assert(status.phase == LoadPhase.CANCELLED && !status.failure);
        assert(missing[0].kind == sentinel.kind && missing[0].slot == sentinel.slot);
        assert(c3d::same_id(missing[0].id, sentinel.id) && store_counts(&assets) == before);
        assert(loader.publish() == 0);
        loader.release(active)!!;
        loader::destroy_async_loader(&loader);
        asset::destroy_asset_store(&assets);
        assert(tracker.allocated() == 0);
    }
}

fn void test_decoded_cancel_unlinks_middle_head_and_tail_without_reordering_publication() @test {
    GatedSource source = create_gated_source(mem);
    defer destroy_gated_source(&source);
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    AssetStore assets = gated_store(&tracker, &source);
    AsyncLoader loader = loader::create_async_loader(&tracker, &assets, 3)!!;
    LoadId first = loader.request(generated_request("first.gltf"))!!;
    LoadId middle = loader.request(generated_request("middle.gltf"))!!;
    LoadId last = loader.request(generated_request("last.gltf"))!!;
    foreach (id : (LoadId[3]){ first, middle, last }) assert(settle(&loader, id).phase == LoadPhase.DECODED);
    usz[8] before = store_counts(&assets);

    loader.cancel(middle)!!;
    assert(loader.status(middle).phase == LoadPhase.CANCELLED && store_counts(&assets) == before);
    assert(loader.publish() == 2);
    assert(loader.status(first).phase == LoadPhase.PUBLISHED && loader.status(last).phase == LoadPhase.PUBLISHED);
    ModelId first_model = loader.status(first).model;
    loader.cancel(first)!!;
    assert(c3d::same_id(loader.status(first).model, first_model) && assets.models.is_live(first_model));
    foreach (id : (LoadId[3]){ first, middle, last }) loader.release(id)!!;

    LoadId head = loader.request(generated_request("head.gltf"))!!;
    LoadId tail = loader.request(generated_request("tail.gltf"))!!;
    assert(settle(&loader, head).phase == LoadPhase.DECODED && settle(&loader, tail).phase == LoadPhase.DECODED);
    loader.cancel(head)!!;
    loader.cancel(tail)!!;
    loader.release(head)!!;
    loader.release(tail)!!;
    LoadId reused = loader.request(generated_request("head.gltf"))!!;
    assert(@catch(loader.cancel(head)) == c3d::INVALID_ID && @catch(loader.release(head)) == c3d::INVALID_ID);
    assert(settle(&loader, reused).phase == LoadPhase.DECODED);
    assert(loader.publish() == 1 && loader.status(reused).phase == LoadPhase.PUBLISHED);
    loader.release(reused)!!;
    loader::destroy_async_loader(&loader);
    asset::destroy_asset_store(&assets);
    assert(tracker.allocated() == 0);
}

fn void test_failed_cancel_preserves_fault() @test {
    GatedSource source = create_gated_source(mem);
    source.fail_path = "failed.gltf";
    defer destroy_gated_source(&source);
    AssetStore assets = gated_store(mem, &source);
    defer asset::destroy_asset_store(&assets);
    AsyncLoader loader = loader::create_async_loader(mem, &assets)!!;
    defer loader::destroy_async_loader(&loader);
    LoadId failed = loader.request(generated_request("failed.gltf"))!!;
    assert(settle(&loader, failed).failure == c3d::ASSET_IO_ERROR);
    loader.cancel(failed)!!;
    loader.cancel(failed)!!;
    LoadStatus status = loader.status(failed);
    assert(status.phase == LoadPhase.FAILED && status.failure == c3d::ASSET_IO_ERROR);
    assert(loader.publish() == 0 && loader.publish_within({ .items = 1 }).failed == 0);
}

fn void test_destroy_joins_gated_decode_and_discards_queued_work() @test {
    foreach (cancelling : (bool[2]){ false, true }) {
        GatedSource source = create_gated_source(mem, true);
        defer destroy_gated_source(&source);
        TrackingAllocator tracker;
        tracker.init(mem);
        defer tracker.free();
        AssetStore assets = gated_store(&tracker, &source);
        AsyncLoader loader = loader::create_async_loader(&tracker, &assets, 2)!!;
        LoadId active = loader.request(generated_request("active.gltf"))!!;
        source.wait_entered();
        loader.request(generated_request("queued.gltf"))!!;
        if (cancelling) loader.cancel(active)!!;
        DestroyContext context = { .loader = &loader, .source = &source };
        Thread destroyer;
        destroyer.create(&destroy_gated_loader, &context)!!;
        source.lock.lock();
        while (!source.destroy_started) source.changed.wait(&source.lock);
        assert(!source.destroy_finished && source.reads == 1);
        source.lock.unlock();
        bool stopping;
        while (!stopping) {
            loader.state.lock.lock();
            stopping = loader.state.stopping;
            loader.state.lock.unlock();
            if (!stopping) thread::yield();
        }
        source.allow_read();
        destroyer.join()!!;
        assert(source.destroy_finished && source.reads == 1);
        asset::destroy_asset_store(&assets);
        assert(tracker.allocated() == 0);
    }
}

fn void test_strict_fifo_defers_oversized_head_and_preserves_fresh_allowances() @test {
    GatedSource source = create_gated_source(mem);
    defer destroy_gated_source(&source);
    AssetStore assets = gated_store(mem, &source);
    defer asset::destroy_asset_store(&assets);
    AsyncLoader loader = loader::create_async_loader(mem, &assets, 2)!!;
    defer loader::destroy_async_loader(&loader);
    LoadId head = loader.request(generated_request("large_head.gltf"))!!;
    LoadId follower = loader.request(generated_request("small_follower.gltf"))!!;
    assert(settle(&loader, head).phase == LoadPhase.DECODED);
    assert(settle(&loader, follower).phase == LoadPhase.DECODED);
    sz keys = assets.keys.len();
    ulong head_items = decoded_items(&loader, head);
    ulong follower_items = decoded_items(&loader, follower);
    assert(head_items - 1 > follower_items);

    PublishReport tiny = loader.publish_within({ .items = head_items - 1 });
    assert(tiny.deferred && tiny.required_items == head_items);
    assert(tiny.items_used == 0 && tiny.published == 0 && tiny.failed == 0);
    assert(loader.status(head).phase == LoadPhase.DECODED && loader.status(follower).phase == LoadPhase.DECODED);
    assert(assets.keys.len() == keys);

    PublishReport first = loader.publish_within({ .items = head_items });
    assert(first.published == 1 && first.failed == 0 && first.items_used == head_items);
    assert(first.deferred && first.required_items == follower_items);
    assert(loader.status(head).phase == LoadPhase.PUBLISHED && loader.status(follower).phase == LoadPhase.DECODED);
    PublishReport next = loader.publish_within({ .items = follower_items });
    assert(next.published == 1 && next.failed == 0 && next.items_used == follower_items);
    assert(!next.deferred && next.required_items == 0);
    assert(loader.publish() == 0);
    LoaderCounters counters = loader.counters();
    assert(counters.publications == 2 && counters.decoded == 0);
    assert(counters.publication_items == head_items + follower_items);
}

fn void test_failed_commit_consumes_items_before_the_next_fifo_request() @test {
    GatedSource source = create_gated_source(mem);
    defer destroy_gated_source(&source);
    foreach (admit_follower : (bool[2]){ false, true }) {
        TrackingAllocator tracker;
        tracker.init(mem);
        defer tracker.free();
        AssetStore assets = gated_store(&tracker, &source);
        AsyncLoader loader = loader::create_async_loader(&tracker, &assets, 2)!!;
        LoadId failed = loader.request(generated_request("collision.gltf"))!!;
        LoadId success = loader.request(generated_request("success.gltf"))!!;
        assert(settle(&loader, failed).phase == LoadPhase.DECODED);
        assert(settle(&loader, success).phase == LoadPhase.DECODED);
        ModelId collision = gltf::load_model(&assets, "collision.gltf")!!;
        ulong failed_items = decoded_items(&loader, failed);
        ulong success_items = decoded_items(&loader, success);
        ulong allowance = failed_items + (admit_follower ? success_items : 0);

        PublishReport report = loader.publish_within({ .items = allowance });
        assert(report.failed == 1 && report.published == (uint)admit_follower && report.items_used == allowance);
        assert(loader.status(failed).failure == c3d::INVALID_ARGUMENT);
        assert(c3d::same_id(assets.find_model("collision.gltf")!!, collision));
        if (admit_follower) {
            assert(!report.deferred && report.required_items == 0);
            assert(loader.status(success).phase == LoadPhase.PUBLISHED);
        } else {
            assert(report.deferred && report.required_items == success_items);
            assert(loader.status(success).phase == LoadPhase.DECODED);
        }
        assert(loader.publish() == (admit_follower ? 0 : 1));
        assert(loader.status(success).phase == LoadPhase.PUBLISHED && loader.publish() == 0);
        LoaderCounters counters = loader.counters();
        assert(counters.commit_failures == 1 && counters.publications == 1 && counters.decode_failures == 0);
        assert(counters.publication_items == failed_items + success_items);
        loader::destroy_async_loader(&loader);
        asset::destroy_asset_store(&assets);
        assert(tracker.allocated() == 0);
    }
}

fn void test_replacement_publishes_within_a_frame_allowance() @test {
    GatedSource source = create_gated_source(mem);
    defer destroy_gated_source(&source);
    AssetStore assets = gated_store(mem, &source);
    defer asset::destroy_asset_store(&assets);
    AsyncLoader loader = loader::create_async_loader(mem, &assets)!!;
    defer loader::destroy_async_loader(&loader);
    LoadId added = loader.request(generated_request("model.gltf"))!!;
    assert(settle(&loader, added).phase == LoadPhase.DECODED && loader.publish() == 1);
    ModelId model = loader.status(added).model;
    loader.release(added)!!;

    LoadRequest request = generated_request("model.gltf");
    request.replace = model;
    LoadId replacement = loader.request(request)!!;
    assert(settle(&loader, replacement).phase == LoadPhase.DECODED);

    PublishReport report = loader.publish_within({ .items = 1024 });
    assert(report.published == 1 && !report.deferred);
    assert(loader.status(replacement).phase == LoadPhase.PUBLISHED && assets.model(model).header.revision == 2);
}

fn void test_reports_exclude_earlier_decode_failure_and_cancellation() @test {
    GatedSource source = create_gated_source(mem);
    source.fail_path = "failed.gltf";
    defer destroy_gated_source(&source);
    AssetStore assets = gated_store(mem, &source);
    defer asset::destroy_asset_store(&assets);
    AsyncLoader loader = loader::create_async_loader(mem, &assets, 3)!!;
    defer loader::destroy_async_loader(&loader);
    LoadId failed = loader.request(generated_request("failed.gltf"))!!;
    LoadId cancelled = loader.request(generated_request("cancelled.gltf"))!!;
    LoadId published = loader.request(generated_request("published.gltf"))!!;
    assert(settle(&loader, failed).phase == LoadPhase.FAILED);
    assert(settle(&loader, cancelled).phase == LoadPhase.DECODED);
    assert(settle(&loader, published).phase == LoadPhase.DECODED);
    loader.cancel(cancelled)!!;
    ulong items = decoded_items(&loader, published);

    PublishReport report = loader.publish_within({});
    assert(report.published == 1 && report.failed == 0 && report.items_used == items);
    assert(!report.deferred && report.required_items == 0);
    PublishReport empty = loader.publish_within({});
    assert(empty.published == 0 && empty.failed == 0 && empty.items_used == 0);
    assert(!empty.deferred && empty.required_items == 0);
}
