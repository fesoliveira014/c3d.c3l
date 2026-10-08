module c3d::test::file_sources;

import c3d;
import c3d::asset;
import c3d::asset::fbx;
import c3d::asset::gltf;
import c3d::asset::image;
import c3d::asset::loader;
import std::io::file;
import std::io::path;
import std::thread;

const usz MAX_ENTRIES @local = 16;
const usz MAX_LOG @local = 32;
const usz LOG_PATH_BYTES @local = 96;
const usz BUFFER_BYTES @local = 36;

const String MODEL_JSON @local = `{"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],"nodes":[{"mesh":0}],`
    `"meshes":[{"primitives":[{"attributes":{"POSITION":0},"material":0}]}],`
    `"materials":[{"pbrMetallicRoughness":{"baseColorTexture":{"index":0}},"normalTexture":{"index":1}}],`
    `"textures":[{"source":0},{"source":1}],`
    `"images":[{"uri":"textures/albedo.png"},{"uri":"./textures/normal.png"}],`
    `"buffers":[{"uri":"bin/mesh.bin","byteLength":36}],`
    `"bufferViews":[{"buffer":0,"byteLength":36}],`
    `"accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3","min":[0,0,0],"max":[1,1,0]}]}`;

struct Entry @local {
    String path;
    char[] bytes;
}

struct MemorySource @local {
    Entry[MAX_ENTRIES] entries;
    usz                entry_count;
    String[MAX_LOG]    log;
    char[LOG_PATH_BYTES][MAX_LOG] log_storage;
    usz                log_count;
    bool               fail_every_read;
}

struct PathCase @local {
    String input;
    String expected;
}

fn char[]? read_memory(void* user, Allocator allocator, String path) @local {
    MemorySource* source = user;
    if (source.log_count < MAX_LOG && path.len <= LOG_PATH_BYTES) {
        char[] stored = source.log_storage[source.log_count][:path.len];
        mem::copy(stored.ptr, path.ptr, path.len);
        source.log[source.log_count++] = (String)stored;
    }
    if (source.fail_every_read) return c3d::UNSUPPORTED~;
    foreach (&entry : source.entries[:source.entry_count]) {
        if (entry.path != path) continue;
        char[] copy = alloc::new_array(allocator, char, (sz)entry.bytes.len);
        mem::copy(copy.ptr, entry.bytes.ptr, entry.bytes.len);
        return copy;
    }
    return c3d::ASSET_IO_ERROR~;
}

fn FileSource file_source_of(MemorySource* source) @local {
    return { .read = &read_memory, .user = source };
}

fn void MemorySource.serve(&self, String path, char[] bytes) {
    self.entries[self.entry_count++] = { .path = path, .bytes = bytes };
}

fn bool MemorySource.logged(&self, String path) {
    foreach (entry : self.log[:self.log_count]) if (entry == path) return true;
    return false;
}

fn AssetStore create_store(Allocator allocator, MemorySource* source) @local {
    AssetStoreDesc desc = asset::default_asset_store_desc();
    desc.file_source = file_source_of(source);
    return asset::create_asset_store(allocator, desc);
}

fn String fixture_path(String name) @local {
    Path source = path::tnew($$FILEPATH)!!;
    return (String)source.parent()!!.tappend("../fixtures", name)!!;
}

fn void serve_model(MemorySource* source, String prefix) @local {
    static char[BUFFER_BYTES] triangle;
    source.serve(string::tformat("%s/bin/mesh.bin", prefix), triangle[..]);
    source.serve(string::tformat("%s/textures/albedo.png", prefix), $embed("../fixtures/rgba.png"));
    source.serve(string::tformat("%s/textures/normal.png", prefix), $embed("../fixtures/rgba.png"));
}

fn void test_normalize_path_table() @test {
    PathCase[] cases = {
        { `a\b/c`, "a/b/c" },
        { "./a/./b", "a/b" },
        { "a/b/../c", "a/c" },
        { "../a", "../a" },
        { "a/../../b", "../b" },
        { `C:\x\..\y`, "C:/y" },
        { "//server/share/a/../b", "//server/share/b" },
        { "/a//b", "/a/b" },
        { "dir/100%25.png", "dir/100%25.png" },
        { "a/..", "." },
    };
    foreach (entry : cases) {
        String normalized = asset::normalize_path(mem, entry.input);
        defer free(normalized.ptr);
        assert(normalized == entry.expected, "%s gave %s", entry.input, normalized);
    }
}

fn void test_gltf_reads_buffers_and_images_through_the_source() @test {
    MemorySource source;
    source.serve("scene/model.gltf", (char[])MODEL_JSON);
    serve_model(&source, "scene");
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    AssetStore assets = create_store(&tracker, &source);

    ModelId model = gltf::load_model(&assets, "scene/model.gltf")!!;

    assert(assets.models.is_live(model));
    assert(assets.find("scene/model.gltf")!!.kind == AssetKind.MODEL);
    assert(source.log_count == 4);
    assert(source.log[0] == "scene/model.gltf" && source.log[1] == "scene/bin/mesh.bin");
    assert(source.logged("scene/textures/albedo.png") && source.logged("scene/textures/normal.png"));
    asset::destroy_asset_store(&assets);
    assert(tracker.allocated() == 0);
}

fn void test_gltf_memory_entry_reads_through_the_source() @test {
    MemorySource source;
    serve_model(&source, "pack/scene");

    ModelDocument document = gltf::decode_model_memory(
        allocator:   mem,
        bytes:       (char[])MODEL_JSON,
        base_dir:    "pack/scene",
        key:         "scene",
        file_source: file_source_of(&source),
    )!!;
    defer asset::destroy_model_document(&document);

    assert(source.log_count == 3);
    assert(source.logged("pack/scene/bin/mesh.bin"));
    assert(source.logged("pack/scene/textures/albedo.png") && source.logged("pack/scene/textures/normal.png"));
}

fn void test_fbx_external_textures_through_the_source() @test {
    String[2] texture_paths = {
        "models/textures/checkerboard_diffuse.png",
        "D:/Dev/clean/ufbx/data/textures/checkerboard_diffuse.png",
    };
    foreach (served : texture_paths) {
        MemorySource source;
        source.serve("models/blender.fbx", $embed("../fixtures/fbx/blender_279_internal_textures_7400_binary.fbx"));
        source.serve(served, $embed("../fixtures/rgba.png"));
        TrackingAllocator tracker;
        tracker.init(mem);
        defer tracker.free();
        AssetStore assets = create_store(&tracker, &source);

        ModelId model = fbx::load_model(&assets, "models/blender.fbx")!!;

        assert(assets.models.is_live(model));
        assert(source.log[0] == "models/blender.fbx");
        assert(source.logged(texture_paths[0]));
        assert(source.logged(texture_paths[1]) == (served == texture_paths[1]));
        usz live_textures;
        foreach (&record : assets.textures.items) if (record.header.revision) live_textures++;
        assert(live_textures > asset::BUILTIN_TEXTURE_COUNT);
        asset::destroy_asset_store(&assets);
        assert(tracker.allocated() == 0);
    }
}

fn void test_image_loaders_through_the_source() @test {
    MemorySource source;
    source.serve("virtual/color.png", $embed("../fixtures/rgba.png"));
    source.serve("virtual/height.png", $embed("../fixtures/gray16.png"));
    source.serve("virtual/container.dds", $embed("../fixtures/texture/dx10_rgba8_srgb_5x3.dds"));
    String[6] faces;
    foreach (index, &face : faces) {
        *face = string::tformat("virtual/cube/face%d.png", index);
        source.serve(*face, $embed("../fixtures/cube/face0.png"));
    }
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    AssetStore assets = create_store(&tracker, &source);

    image::load_texture(&assets, "virtual/color.png", true)!!;
    image::load_texture_r16(&assets, "virtual/height.png")!!;
    image::load_texture_container(&assets, "virtual/container.dds")!!;
    image::load_cube(&assets, faces, true)!!;

    assert(source.log_count == 9);
    assert(source.logged("virtual/color.png") && source.logged("virtual/height.png"));
    assert(source.logged("virtual/container.dds"));
    foreach (face : faces) assert(source.logged(face));
    asset::destroy_asset_store(&assets);
    assert(tracker.allocated() == 0);
}

fn void test_async_request_reads_through_the_source() @test {
    MemorySource source;
    source.serve("scene/model.gltf", (char[])MODEL_JSON);
    serve_model(&source, "scene");
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    AssetStore assets = create_store(&tracker, &source);
    AsyncLoader loader = loader::create_async_loader(&tracker, &assets)!!;

    LoadId id = loader.request({
        .path    = "scene/model.gltf",
        .format  = ModelFormat.GLTF,
        .options = asset::LOAD_OPTIONS_DEFAULT,
    })!!;
    LoadStatus status = loader.status(id);
    while (status.phase == LoadPhase.QUEUED || status.phase == LoadPhase.DECODING) {
        thread::yield();
        status = loader.status(id);
    }
    assert(loader.publish() == 1);

    status = loader.status(id);
    assert(status.phase == LoadPhase.PUBLISHED && assets.models.is_live(status.model));
    assert(source.log_count == 4 && source.log[0] == "scene/model.gltf");
    assert(source.logged("scene/bin/mesh.bin") && source.logged("scene/textures/albedo.png"));
    loader.release(id)!!;
    loader::destroy_async_loader(&loader);
    asset::destroy_asset_store(&assets);
    assert(tracker.allocated() == 0);
}

fn void test_missing_path_faults_io_error() @test {
    MemorySource source;
    AssetStore assets = create_store(mem, &source);
    defer asset::destroy_asset_store(&assets);
    sz keys_before = assets.keys.len();

    assert(@catch(gltf::load_model(&assets, "nowhere/model.gltf")) == c3d::ASSET_IO_ERROR);
    assert(@catch(image::load_texture(&assets, "nowhere/color.png", true)) == c3d::ASSET_IO_ERROR);

    assert(assets.keys.len() == keys_before);
}

fn void test_source_faults_map_to_io_error() @test {
    MemorySource source;
    source.fail_every_read = true;
    AssetStore assets = create_store(mem, &source);
    defer asset::destroy_asset_store(&assets);

    assert(@catch(assets.read_file(mem, "any/file.bin")) == c3d::ASSET_IO_ERROR);
    assert(@catch(gltf::load_model(&assets, "scene/model.gltf")) == c3d::ASSET_IO_ERROR);
}

fn void test_read_file_system_is_the_default() @test {
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    String path = fixture_path("rgba.png");

    char[] through_store = assets.read_file(tmem, path)!!;
    char[] direct = file::load(tmem, path)!!;

    assert(through_store == direct);
}
