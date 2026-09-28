module c3d::test::async_loader;

import c3d;
import c3d::asset;
import c3d::asset::gltf;
import c3d::asset::loader;
import std::io::path;
import std::thread;

struct Holder @local {
    AsyncLoader loader;
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
    while (status.phase == LoadPhase.QUEUED || status.phase == LoadPhase.DECODING) {
        thread::yield();
        status = loader.status(id);
    }
    return status;
}

fn AsyncLoader start_loader(AssetStore* assets) @local => loader::create_async_loader(mem, assets, 2)!!;

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
