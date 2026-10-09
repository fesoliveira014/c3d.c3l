module c3d::asset::gltf;

import c3d;
import c3d::asset;
import c3d::material;
import gltf;
import std::io::file;
import std::io::path;

const String SOURCE_PNG @local = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAF0lEQVR4nGP4z8DwHwgbGIC0w////xkAQBgHuub96GQAAAAASUVORK5CYII=";
const String SOURCE_DOCUMENT @local = `{
    "asset":{"version":"2.0"},
    "materials":[{"name":"paint",
        "extensions":{"EXT_surface":{}},
        "pbrMetallicRoughness":{"baseColorTexture":{"index":0,"extensions":{"KHR_texture_transform":{"texCoord":1}}}},
        "normalTexture":{"index":1,"extensions":{"EXT_normal":{}}},
        "occlusionTexture":{"index":2,"extensions":{"EXT_occlusion":{}}}}],
    "textures":[{"source":0,"sampler":0,"extensions":{"EXT_image":{}}},
        {"source":0,"sampler":1},{"source":0,"sampler":0}],
    "samplers":[{"minFilter":9728,"magFilter":9728},{"minFilter":9987}],
    "images":[{"uri":"data:image/png;base64,%s"},{"uri":"must-not-be-loaded.png"}]
}`;
const uint GLB_MAGIC @local = 0x46546c67;
const uint GLB_JSON @local = 0x4e4f534a;
const uint GLB_BIN @local = 0x004e4942;
const usz GLB_HEADER_BYTES @local = 12;
const usz GLB_CHUNK_HEADER_BYTES @local = 8;
const usz GLB_ALIGNMENT @local = 4;
const sz QUAD_DECODE_ALLOCATIONS @local = 27;

fn void test_source_preserves_document_and_plain_allocation_count() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    String fixture = (String)path::tnew($$FILEPATH)!!.parent()!!.tappend("../fixtures/gltf/quad.gltf")!!;

    ModelDocument plain = decode_model(&tracker, fixture)!!;

    assert(tracker.total_allocation_count() == QUAD_DECODE_ALLOCATIONS,
      "Got %d allocations; expected %d", tracker.total_allocation_count(), QUAD_DECODE_ALLOCATIONS);

    SourceRecord source;
    SourceDiagnostic diagnostic;

    ModelDocument inspected = decode_model_with_source(
        allocator: &tracker,
        path: fixture,
        source: &source,
        diagnostic: &diagnostic,
    )!!;

    assert(diagnostic.material_index == NO_SOURCE_INDEX && diagnostic.texture_index == NO_SOURCE_INDEX);
    assert(plain.key == inspected.key);
    assert(plain.materials.len == inspected.materials.len && plain.textures.len == inspected.textures.len);
    assert(plain.samplers.len == inspected.samplers.len && plain.geometries.len == inspected.geometries.len);
    assert(plain.template.nodes.len == inspected.template.nodes.len);
    assert(plain.template.meshes.len == inspected.template.meshes.len);
    assert(mem::equals(&plain.materials[0].data, &inspected.materials[0].data, material::Material::size));
    assert(mem::equals(&plain.samplers[0].desc, &inspected.samplers[0].desc, SamplerDesc::size));
    assert(mem::equals(plain.textures[0].pixels, inspected.textures[0].pixels));

    Geometry* first = &plain.geometries[0].data;
    Geometry* second = &inspected.geometries[0].data;

    assert(mem::equals(first.positions, second.positions) && mem::equals(first.normals, second.normals));
    assert(mem::equals(first.uv0, second.uv0) && mem::equals(first.indices, second.indices));

    asset::destroy_model_document(&plain);
    asset::destroy_model_document(&inspected);

    assert(source.materials[0].name == "painted" && source.images[0].encoded.len > 0);
    assert(source.materials[0].extensions[0] == "KHR_texture_transform");

    destroy_source_record(&source);

    assert(tracker.allocated() == 0);
}

fn void test_source_image_sampler_pairs_and_nested_extensions_in_both_containers() @test {
    String text = string::tformat(SOURCE_DOCUMENT, SOURCE_PNG);

    foreach (bool binary : { false, true }) {
        SourceRecord source;
        char[] bytes = binary ? source_glb(text) : (char[])text;

        ModelDocument document = decode_model_memory_with_source(
            allocator: mem,
            bytes: bytes,
            base_dir: "",
            key: "source-pairs",
            source: &source,
        )!!;
        defer asset::destroy_model_document(&document);

        assert(document.textures.len == 3 && source.texture_images.len == 3);
        assert(source.texture_images[0] == 0 && source.texture_images[1] == 0 && source.texture_images[2] == 0);
        assert(source.images[0].encoded.len > 0 && !source.images[1].encoded.len);
        assert(source.images[0].declared_mime_type == "image/png");
        assert(source.textures[0].image == 0 && source.textures[1].image == 0);
        assert(source.textures[0].sampler == 0 && source.textures[1].sampler == 1);
        assert(c3d::same_id(source.textures[0].srgb, source.textures[1].srgb));
        assert(c3d::same_id(source.textures[0].linear, source.textures[1].linear));
        assert(source.samplers[0].min_filter == 9728 && source.samplers[1].min_filter == 9987);
        assert(source.samplers[1].mag_filter == 0);
        assert(source.materials[0].textures.len == 3);
        assert(source.materials[0].textures[0] == 0 && source.materials[0].textures[2] == 2);

        String[] names = source.materials[0].extensions;

        assert(names.len == 4 && names[0] == "EXT_normal" && names[1] == "EXT_occlusion");
        assert(names[2] == "EXT_surface" && names[3] == "KHR_texture_transform");
        assert(source.textures[0].extensions.len == 1 && source.textures[0].extensions[0] == "EXT_image");

        material::Material* material = &document.materials[0].data;

        assert(material.standard.base_color_map.uv_set == 1);
        assert(!c3d::same_id(material.standard.base_color_map.sampler, material.standard.normal_map.sampler));

        destroy_source_record(&source);

        assert(document.textures[0].pixels.len > 0 && material.standard.base_color_map.uv_set == 1);
    }
}

fn void test_source_encoded_images_are_identical_in_all_storage_forms() @test {
    char[] png = gltf::decode_base64(tmem, SOURCE_PNG)!!;
    String directory = (String)path::temp_directory(tmem)!!;
    String image_path = (String)path::tnew(directory)!!.tappend("c3d_source_record_image.png")!!;
    file::save(image_path, png)!!;
    defer (void)file::delete(image_path);
    String[3] images = {
        string::tformat(`"images":[{"uri":"data:image/png;base64,%s"}]`, SOURCE_PNG),
        `"images":[{"uri":"c3d_source_record_image.png"}]`,
        string::tformat(`"images":[{"bufferView":0,"mimeType":"image/jpeg"}],
            "buffers":[{"byteLength":%d}],"bufferViews":[{"buffer":0,"byteLength":%d}]`, png.len, png.len),
    };
    foreach (index, image : images) {
        String text = string::tformat(`{"asset":{"version":"2.0"},%s,
            "textures":[{"source":0}],"materials":[{"normalTexture":{"index":0}}]}`, image);
        char[] bytes = index == 2 ? source_glb(text, png) : (char[])text;
        SourceRecord source;
        ModelDocument document = decode_model_memory_with_source(
            allocator: mem,
            bytes: bytes,
            base_dir: directory,
            key: "source-encoding",
            source: &source,
        )!!;
        defer asset::destroy_model_document(&document);
        defer destroy_source_record(&source);
        assert(mem::equals(source.images[0].encoded, png));
        assert(source.images[0].declared_mime_type == (index == 0 ? "image/png" : index == 1 ? "" : "image/jpeg"));
        assert(source.textures[0].sampler == NO_SOURCE_INDEX);
        assert(c3d::same_id(source.textures[0].srgb, (TextureId){}));
    }
}

fn void test_source_omitted_nodes_and_required_names() @test {
    String text = `{"asset":{"version":"2.0"},"extensionsRequired":["KHR_materials_unlit"],
        "scene":0,"scenes":[{"nodes":[0]}],"nodes":[{"name":"represented"},{"name":"outside"}],
        "materials":[{"extensions":{"KHR_materials_unlit":{}}}]}`;
    SourceRecord source;
    ModelDocument document = decode_model_memory_with_source(
        allocator: mem,
        bytes: (char[])text,
        base_dir: "",
        key: "source-nodes",
        source: &source,
    )!!;
    defer asset::destroy_model_document(&document);
    defer destroy_source_record(&source);
    assert(source.template_nodes.len == 2 && source.template_nodes[0] == 0);
    assert(source.template_nodes[1] == NO_TEMPLATE_NODE && document.template.nodes.len == 1);
    assert(source.extensions_required.len == 1 && source.extensions_required[0] == "KHR_materials_unlit");
    assert(source.materials[0].extensions[0] == "KHR_materials_unlit");
}

fn void test_source_decode_failure_releases_both_owners_and_preserves_output() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    String text = string::tformat(SOURCE_DOCUMENT, SOURCE_PNG);
    text = text.treplace(`{"source":0,"sampler":1}`, `{"source":1,"sampler":1}`);
    usz[1] marker = { 123 };
    SourceRecord source = { .template_nodes = marker[..] };
    SourceDiagnostic diagnostic = { .material_index = 5, .texture_index = 8 };
    assert(@catch(decode_model_memory_with_source(
        allocator: &tracker,
        bytes: (char[])text,
        base_dir: "",
        key: "source-failure",
        source: &source,
        diagnostic: &diagnostic,
    )) == c3d::ASSET_IO_ERROR);
    assert(tracker.allocated() == 0);
    assert(source.template_nodes.ptr == &marker[0] && source.template_nodes[0] == 123);
    assert(diagnostic.material_index == NO_SOURCE_INDEX && diagnostic.texture_index == NO_SOURCE_INDEX);
}

fn void test_source_record_survives_document_publication() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    AssetStore assets = asset::create_asset_store(&tracker, {
        .max_geometries = 2,
        .max_textures = 8,
        .max_materials = 8,
        .max_samplers = 8,
        .max_models = 2,
    });
    SourceRecord source;
    String fixture = (String)path::tnew($$FILEPATH)!!.parent()!!.tappend("../fixtures/gltf/quad.gltf")!!;
    ModelDocument document = decode_model_with_source(&tracker, fixture, &source)!!;
    TextureId decoded = source.textures[0].srgb;
    assets.publish_document(&document)!!;
    assert(document.textures.len == 0 && source.images[0].encoded.len > 0);
    assert(source.materials[0].name == "painted" && c3d::same_id(source.textures[0].srgb, decoded));
    destroy_source_record(&source);
    asset::destroy_asset_store(&assets);
    assert(tracker.allocated() == 0);
}

fn void test_source_metadata_crosscheck_reports_exact_indices_and_cleans_up() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    String text = string::tformat(SOURCE_DOCUMENT, SOURCE_PNG);
    gltf::Data* data = parse_bytes((char[])text)!!;
    defer gltf::free(data);
    char[] original = data.json;
    defer data.json = original;
    String[3] changed = {
        text.treplace(`"normalTexture":{"index":1`, `"normalTexture":{"index":0`),
        text.treplace(`"normalTexture"`, `"ignoredTexture"`),
        text.treplace(`"textures":[`, `"textures":[{},`),
    };
    foreach (index, mismatch : changed) {
        SourceRecord source = { .allocator = &tracker };
        source.materials = alloc::new_array(&tracker, SourceMaterial, data.materials.len);
        source.textures = alloc::new_array(&tracker, SourceTexture, data.textures.len);
        Importer importer = { .allocator = &tracker, .data = data, .source = &source };
        data.json = (char[])mismatch;
        SourceDiagnostic diagnostic;
        reset_source_diagnostic(&diagnostic);
        assert(@catch(inspect_source_extensions(&importer, &diagnostic)) == c3d::ASSET_FORMAT_ERROR);
        assert(diagnostic.material_index == (index < 2 ? 0 : NO_SOURCE_INDEX));
        assert(diagnostic.texture_index == (index < 2 ? 1 : NO_SOURCE_INDEX));
        destroy_source_record(&source);
        assert(tracker.allocated() == 0);
    }
    String two_materials = `{"asset":{"version":"2.0"},"images":[{}],"textures":[{"source":0}],
        "materials":[{"extensions":{"EXT_kept":{}}},{"normalTexture":{"index":0}}]}`;
    gltf::Data* second = parse_bytes((char[])two_materials)!!;
    defer gltf::free(second);
    char[] second_json = second.json;
    defer second.json = second_json;
    second.json = (char[])two_materials.treplace(`"normalTexture"`, `"ignoredTexture"`);
    SourceRecord partial = { .allocator = &tracker };
    partial.materials = alloc::new_array(&tracker, SourceMaterial, second.materials.len);
    partial.textures = alloc::new_array(&tracker, SourceTexture, second.textures.len);
    Importer importer = { .allocator = &tracker, .data = second, .source = &partial };
    SourceDiagnostic diagnostic;
    reset_source_diagnostic(&diagnostic);
    assert(@catch(inspect_source_extensions(&importer, &diagnostic)) == c3d::ASSET_FORMAT_ERROR);
    assert(diagnostic.material_index == 1 && diagnostic.texture_index == 0);
    assert(partial.materials[0].extensions[0] == "EXT_kept");
    destroy_source_record(&partial);
    assert(tracker.allocated() == 0);
}

fn char[] source_glb(String text, char[] binary = {}) @local {
    usz json_size = (text.len + GLB_ALIGNMENT - 1) & ~(GLB_ALIGNMENT - 1);
    usz binary_size = (binary.len + GLB_ALIGNMENT - 1) & ~(GLB_ALIGNMENT - 1);
    usz total = GLB_HEADER_BYTES + GLB_CHUNK_HEADER_BYTES + json_size;
    if (binary.len) total += GLB_CHUNK_HEADER_BYTES + binary_size;
    char[] bytes = alloc::new_array(tmem, char, (sz)total);
    uint* words = (uint*)bytes.ptr;
    words[0] = GLB_MAGIC;
    words[1] = 2;
    words[2] = (uint)total;
    words[3] = (uint)json_size;
    words[4] = GLB_JSON;
    usz first = GLB_HEADER_BYTES + GLB_CHUNK_HEADER_BYTES;
    bytes[first:json_size] = ' ';
    bytes[first:text.len] = ((char[])text)[..];
    if (binary.len) {
        usz offset = first + json_size;
        uint* chunk = (uint*)&bytes[offset];
        chunk[0] = (uint)binary_size;
        chunk[1] = GLB_BIN;
        bytes[offset + GLB_CHUNK_HEADER_BYTES:binary.len] = binary[..];
    }
    return bytes;
}
