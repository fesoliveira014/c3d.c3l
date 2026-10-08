module c3d::test::loader_replace;

import c3d;
import c3d::asset;
import c3d::asset::gltf;
import c3d::asset::loader;
import std::io::file;
import std::io::path;
import std::thread;

fn String fixture_path(String name) @local {
    Path source = path::tnew($$FILEPATH)!!;
    return (String)source.parent()!!.tappend("../fixtures/gltf", name)!!;
}

fn String scratch_path() @local {
    Path source = path::tnew($$FILEPATH)!!;
    return (String)source.parent()!!.tappend("../build/loader_replace_target.gltf")!!;
}

fn AssetStore create_store(Allocator allocator) @local {
    return asset::create_asset_store(allocator, asset::default_asset_store_desc());
}

fn LoadStatus settle(AsyncLoader* loader, LoadId id) @local {
    LoadStatus status = loader.status(id);
    while (status.phase == LoadPhase.QUEUED || status.phase == LoadPhase.DECODING) {
        thread::yield();
        status = loader.status(id);
    }
    return status;
}

fn LoadRequest replace_request(String path, ModelId model, AssetRef[] missing = {}) @local {
    return {
        .path    = path,
        .format  = ModelFormat.GLTF,
        .options = asset::LOAD_OPTIONS_DEFAULT,
        .replace = model,
        .missing = missing,
    };
}

fn uint count_parts(AssetStore* assets, String model_key) @local {
    uint parts;
    @pool() {
        foreach (key : assets.keys.tkeys()) {
            if (key.starts_with(model_key) && key.len > model_key.len) parts++;
        }
    };
    return parts;
}

fn void test_loader_replaces_model() @test {
    AssetStore assets = create_store(mem);
    defer asset::destroy_asset_store(&assets);
    AsyncLoader loader = loader::create_async_loader(mem, &assets, 2)!!;
    defer loader::destroy_async_loader(&loader);

    String path = fixture_path("skin.gltf");
    ModelId model = gltf::load_model(&assets, path)!!;
    uint parts = count_parts(&assets, path);
    AssetRef[2] missing;

    LoadId id = loader.request(replace_request(path, model, missing[..]))!!;
    assert(settle(&loader, id).phase == LoadPhase.DECODED);
    assert(loader.publish() == 1);

    LoadStatus status = loader.status(id);
    assert(status.phase == LoadPhase.PUBLISHED && c3d::same_id(status.model, model));
    assert(status.report.replaced == parts && status.report.added == 0 && status.report.missing == 0);
    assert(assets.model(model).header.revision == 2);
    loader.release(id)!!;
}

fn void test_loader_replace_checks_target() @test {
    AssetStore assets = create_store(mem);
    defer asset::destroy_asset_store(&assets);
    AsyncLoader loader = loader::create_async_loader(mem, &assets, 2)!!;
    defer loader::destroy_async_loader(&loader);

    ModelId skin = gltf::load_model(&assets, fixture_path("skin.gltf"))!!;
    assert(@catch(loader.request(replace_request(fixture_path("quad.gltf"), skin))) == c3d::INVALID_ARGUMENT);

    String quad_path = fixture_path("quad.gltf");
    ModelId quad = gltf::load_model(&assets, quad_path)!!;
    assets.remove_model(quad);
    assert(@catch(loader.request(replace_request(quad_path, quad))) == c3d::INVALID_ID);

    GeometryId geometry = assets.model(skin).data.meshes[0].geometry;
    sz keys = assets.keys.len();
    LoadId id = loader.request(replace_request(fixture_path("skin.gltf"), skin))!!;
    assert(settle(&loader, id).phase == LoadPhase.DECODED);
    assets.remove_model(skin);
    assert(loader.publish() == 1);

    LoadStatus status = loader.status(id);
    assert(status.phase == LoadPhase.FAILED && status.failure == c3d::INVALID_ID);
    assert(assets.geometry(geometry).header.revision == 1);
    assert(assets.keys.len() == keys - 1);
}

fn void test_loader_replace_reports_incompatible() @test {
    AssetStore assets = create_store(mem);
    defer asset::destroy_asset_store(&assets);
    AsyncLoader loader = loader::create_async_loader(mem, &assets, 2)!!;
    defer loader::destroy_async_loader(&loader);

    String target = scratch_path();
    file::save(target, file::load_temp(fixture_path("hierarchy.gltf"))!!)!!;
    defer (void)file::delete(target);
    ModelId model = gltf::load_model(&assets, target)!!;
    file::save(target, file::load_temp(fixture_path("skin.gltf"))!!)!!;

    LoadId id = loader.request(replace_request(target, model))!!;
    assert(settle(&loader, id).phase == LoadPhase.DECODED);
    assert(loader.publish() == 1);

    LoadStatus status = loader.status(id);
    assert(status.phase == LoadPhase.FAILED && status.failure == c3d::INCOMPATIBLE_STRUCTURE);
    assert(assets.model(model).header.revision == 1);
}
