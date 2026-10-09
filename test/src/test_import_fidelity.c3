module c3d::test::import_fidelity;

import c3d;
import c3d::asset;
import c3d::asset::gltf;
import c3d::geometry;
import c3d::material;
import std::io::path;
import std::math;

const char[*] TANGENT_FIXTURE @local = $embed("../fixtures/import_fidelity/tangent_streams_v1.gltf");
const String PNG_PAYLOAD @local = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAF0lEQVR4nGP4z8DwHwgbGIC0w////xkAQBgHuub96GQAAAAASUVORK5CYII=";
const float TANGENT_TOLERANCE @local = 0.00001f;
const String IMAGE_DOCUMENT @local = `{"asset":{"version":"2.0"},"images":[{"uri":"%s"}],
    "textures":[{"source":0}],"materials":%s}`;

fn String fixture_directory(String name) @local {
    return (String)path::tnew($$FILEPATH)!!.parent()!!.tappend("../fixtures", name)!!;
}

fn String tangent_fixture() @local {
    return (String)TANGENT_FIXTURE[..];
}

fn ModelDocument decode_text(
    String text,
    LoadOptions options = asset::LOAD_OPTIONS_DEFAULT,
    String base_dir = "",
) @local {
    return gltf::decode_model_memory(
        allocator: mem,
        bytes: (char[])text,
        base_dir: base_dir,
        key: "import-fidelity",
        options: options,
    )!!;
}

fn String image_document(String uri, String materials) @local {
    return string::tformat(IMAGE_DOCUMENT, uri, materials);
}

fn String png_document(String materials) @local {
    return image_document(string::tformat("data:image/png;base64,%s", PNG_PAYLOAD), materials);
}

fn DocumentTexture* texture_entry(ModelDocument* document, TextureId reference) @local {
    return &document.textures[(usz)reference.index - 1];
}

fn AssetStore create_store(Allocator allocator = mem) @local {
    return asset::create_asset_store(allocator, {
        .max_geometries = 4,
        .max_textures = 16,
        .max_materials = 16,
        .max_samplers = asset::BUILTIN_SAMPLER_COUNT + 2,
        .max_models = 2,
    });
}

fn void expect_decode_fault(String text, LoadOptions options, fault expected) @local {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    bool failed;

    ModelDocument? result = gltf::decode_model_memory(
        allocator: &tracker,
        bytes: (char[])text,
        base_dir: "",
        key: "import-fidelity-fault",
        options: options,
    );

    if (catch excuse = result) {
        failed = true;

        assert(excuse == expected);
    } else {
        ModelDocument document = result;

        asset::destroy_model_document(&document);
    }

    assert(failed);
    assert(tracker.allocated() == 0);
}

fn void expect_direction(Vec4 tangent, Vec3 expected) @local {
    assert(math::abs(tangent.x - expected.x) < TANGENT_TOLERANCE);
    assert(math::abs(tangent.y - expected.y) < TANGENT_TOLERANCE);
    assert(math::abs(tangent.z - expected.z) < TANGENT_TOLERANCE);
    assert(tangent.w == 1 || tangent.w == -1);
}

fn void test_roles_are_distinct_and_source_color_references_keep_their_semantics() @test {
    String text = png_document(`[
        {"pbrMetallicRoughness":{"baseColorTexture":{"index":0}},"occlusionTexture":{"index":0},"normalTexture":{"index":0}},
        {"normalTexture":{"index":0}}]`);

    foreach (NormalEncoding encoding : { NormalEncoding.RGB, NormalEncoding.RG }) {
        LoadOptions options = asset::LOAD_OPTIONS_DEFAULT;
        options.normal_encoding = encoding;
        gltf::SourceRecord source;

        ModelDocument document = gltf::decode_model_memory_with_source(
            allocator: mem,
            bytes: (char[])text,
            base_dir: "",
            key: "import-roles",
            source: &source,
            options: options,
        )!!;
        defer asset::destroy_model_document(&document);
        defer gltf::destroy_source_record(&source);

        assert(document.textures.len == 3 && source.texture_images.len == 3);

        foreach (image_index : source.texture_images) assert(image_index == 0);

        StandardParams* first = &document.materials[0].data.standard;
        TextureId color = first.base_color_map.texture.asset;
        TextureId data = first.occlusion_map.texture.asset;
        TextureId normal = first.normal_map.texture.asset;

        assert(!c3d::same_id(color, data) && !c3d::same_id(data, normal) && !c3d::same_id(color, normal));
        assert(c3d::same_id(normal, document.materials[1].data.standard.normal_map.texture.asset));
        assert(c3d::same_id(source.textures[0].srgb, color) && c3d::same_id(source.textures[0].linear, data));

        DocumentTexture* color_entry = texture_entry(&document, color);
        DocumentTexture* data_entry = texture_entry(&document, data);
        DocumentTexture* normal_entry = texture_entry(&document, normal);

        assert(color_entry.desc.semantic == TextureSemantic.COLOR && color_entry.desc.format == RGBA8_SRGB);
        assert(data_entry.desc.semantic == TextureSemantic.COLOR && data_entry.desc.format == RGBA8_UNORM);
        assert(normal_entry.desc.semantic == (encoding == NormalEncoding.RGB ? TextureSemantic.NORMAL_RGB : TextureSemantic.NORMAL_RG));
        assert(normal_entry.desc.format == RGBA8_UNORM && normal_entry.desc.coverage == CoveragePolicy.NONE);
        assert(color_entry.key == "import-roles#image/0/srgb" && data_entry.key == "import-roles#image/0/linear");
        assert(mem::equals(color_entry.pixels, data_entry.pixels) && mem::equals(data_entry.pixels, normal_entry.pixels));
    }
}

fn void test_normal_only_source_does_not_label_normal_ids_as_color() @test {
    String text = png_document(`[{"normalTexture":{"index":0}}]`);
    gltf::SourceRecord source;

    ModelDocument document = gltf::decode_model_memory_with_source(
        allocator: mem,
        bytes: (char[])text,
        base_dir: "",
        key: "import-normal-only",
        source: &source,
    )!!;
    defer asset::destroy_model_document(&document);
    defer gltf::destroy_source_record(&source);

    assert(document.textures.len == 1 && source.texture_images.len == 1);
    assert(source.texture_images[0] == 0 && source.images[0].encoded.len > 0);
    assert(c3d::same_id(source.textures[0].srgb, (TextureId){}));
    assert(c3d::same_id(source.textures[0].linear, (TextureId){}));
    assert(document.textures[0].desc.semantic == TextureSemantic.NORMAL_RGB);
}

fn void test_mask_variants_use_effective_thresholds_and_constant_pass_classes() @test {
    String text = png_document(`[
        {"pbrMetallicRoughness":{"baseColorTexture":{"index":0}}},
        {"alphaMode":"MASK","alphaCutoff":0.5,"pbrMetallicRoughness":{"baseColorTexture":{"index":0}}},
        {"alphaMode":"MASK","alphaCutoff":0.25,"pbrMetallicRoughness":{"baseColorFactor":[1,1,1,0.5],"baseColorTexture":{"index":0}}},
        {"alphaMode":"MASK","alphaCutoff":0.25,"pbrMetallicRoughness":{"baseColorTexture":{"index":0}}},
        {"alphaMode":"MASK","alphaCutoff":0,"pbrMetallicRoughness":{"baseColorFactor":[1,1,1,0],"baseColorTexture":{"index":0}}},
        {"alphaMode":"MASK","alphaCutoff":0,"pbrMetallicRoughness":{"baseColorTexture":{"index":0}}},
        {"alphaMode":"MASK","alphaCutoff":0.5,"pbrMetallicRoughness":{"baseColorFactor":[1,1,1,0],"baseColorTexture":{"index":0}}},
        {"alphaMode":"MASK","alphaCutoff":0.75,"pbrMetallicRoughness":{"baseColorFactor":[1,1,1,0.5],"baseColorTexture":{"index":0}}},
        {"alphaMode":"BLEND","pbrMetallicRoughness":{"baseColorTexture":{"index":0}}},
        {"normalTexture":{"index":0}}]`);

    ModelDocument document = decode_text(text);
    defer asset::destroy_model_document(&document);

    assert(document.textures.len == 6);

    TextureId[9] references;

    foreach (index, &reference : references) *reference = document.materials[index].data.standard.base_color_map.texture.asset;

    assert(c3d::same_id(references[0], references[8]));
    assert(c3d::same_id(references[1], references[2]));
    assert(!c3d::same_id(references[1], references[3]));
    assert(c3d::same_id(references[4], references[5]));
    assert(c3d::same_id(references[6], references[7]));
    assert(texture_entry(&document, references[0]).desc.coverage == CoveragePolicy.NONE);
    assert(texture_entry(&document, references[1]).desc.alpha_threshold == 0.5);
    assert(texture_entry(&document, references[3]).desc.alpha_threshold == 0.25);
    assert(texture_entry(&document, references[4]).desc.coverage == CoveragePolicy.ALL_PASS);
    assert(texture_entry(&document, references[6]).desc.coverage == CoveragePolicy.ALL_FAIL);

    document.materials[2].data.common.alpha_cutoff = 0.1f;

    assert(texture_entry(&document, references[1]).desc.alpha_threshold == 0.5);

    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);

    ModelId model = assets.publish_document(&document)!!;

    assert(assets.models.is_live(model));

    TextureId threshold = assets.material(assets.find_material("import-fidelity#material/1")!!).data.standard.base_color_map.texture.asset;
    TextureId quarter = assets.material(assets.find_material("import-fidelity#material/3")!!).data.standard.base_color_map.texture.asset;

    assert(assets.texture(threshold).coverage_statistics.passing[0] == 2);
    assert(assets.texture(quarter).coverage_statistics.passing[0] == 3);
}

fn void test_supplied_mips_keep_payload_and_coverage_none_for_mask_and_normal_roles() @test {
    foreach (String name : { "legacy_rgba8_2x2.dds", "ktx2_rgba8_srgb_5x3.ktx2", "ktx2_bc7_srgb_5x3.ktx2" }) {
        String text = image_document(name, `[
            {"alphaMode":"MASK","alphaCutoff":0.5,"pbrMetallicRoughness":{"baseColorTexture":{"index":0}}},
            {"normalTexture":{"index":0}}]`);

        foreach (NormalEncoding encoding : { NormalEncoding.RGB, NormalEncoding.RG }) {
            LoadOptions options = asset::LOAD_OPTIONS_DEFAULT;
            options.normal_encoding = encoding;

            ModelDocument document = decode_text(text, options, fixture_directory("texture"));
            defer asset::destroy_model_document(&document);

            assert(document.textures.len == 2);

            foreach (index, &texture : document.textures) {
                assert(texture.source_kind == TextureSourceKind.SUPPLIED_MIPS && !texture.pixels.len);
                assert(texture.desc.coverage == CoveragePolicy.NONE && texture.desc.alpha_threshold == 0);
                assert(!texture.desc.generate_mips && texture.supplied_mips.len > 0);
                assert(texture.desc.semantic == (index == 0 ? TextureSemantic.COLOR
                  : encoding == NormalEncoding.RGB ? TextureSemantic.NORMAL_RGB : TextureSemantic.NORMAL_RG));

                DocumentTexture* other = &document.textures[index == 0 ? 1 : 0];

                assert(texture.supplied_mips.len == other.supplied_mips.len);

                foreach (level_index, level : texture.supplied_mips) {
                    TextureMipData second = other.supplied_mips[level_index];

                    assert(level.mip == second.mip && level.layer == second.layer);
                    assert(mem::equals(level.bytes, second.bytes));
                }
            }
        }
    }
}

fn void test_bc5_normal_source_keeps_default_rgb_and_explicit_rg_without_inference() @test {
    String text = image_document("ktx2_bc5_8x4.ktx2", `[{"normalTexture":{"index":0}}]`);

    ModelDocument rgb = decode_text(text, asset::LOAD_OPTIONS_DEFAULT, fixture_directory("texture"));
    defer asset::destroy_model_document(&rgb);

    LoadOptions options = asset::LOAD_OPTIONS_DEFAULT;
    options.normal_encoding = NormalEncoding.RG;

    ModelDocument rg = decode_text(text, options, fixture_directory("texture"));
    defer asset::destroy_model_document(&rg);

    assert(rgb.textures.len == 1 && rg.textures.len == 1);

    DocumentTexture* first = &rgb.textures[0];
    DocumentTexture* second = &rg.textures[0];

    assert(first.source_kind == TextureSourceKind.SUPPLIED_MIPS && second.source_kind == TextureSourceKind.SUPPLIED_MIPS);
    assert(first.desc.semantic == TextureSemantic.NORMAL_RGB && second.desc.semantic == TextureSemantic.NORMAL_RG);
    assert(first.desc.format == BC5_UNORM && second.desc.format == BC5_UNORM);
    assert(first.desc.coverage == CoveragePolicy.NONE && second.desc.coverage == CoveragePolicy.NONE);
    assert(first.key != second.key && first.supplied_mips.len == second.supplied_mips.len);

    foreach (index, level : first.supplied_mips) assert(mem::equals(level.bytes, second.supplied_mips[index].bytes));
}

fn void test_generated_ktx_mip_zero_is_eligible_for_mask_variants() @test {
    String text = image_document("ktx1_rgba8_generate_2x2.ktx", `[
        {"alphaMode":"MASK","alphaCutoff":0.5,"pbrMetallicRoughness":{"baseColorTexture":{"index":0}}},
        {"pbrMetallicRoughness":{"baseColorTexture":{"index":0}}}]`);

    ModelDocument document = decode_text(text, asset::LOAD_OPTIONS_DEFAULT, fixture_directory("texture"));
    defer asset::destroy_model_document(&document);

    assert(document.textures.len == 2);
    assert(document.textures[0].source_kind == TextureSourceKind.MIP_ZERO);
    assert(document.textures[0].desc.generate_mips && document.textures[0].desc.coverage == CoveragePolicy.THRESHOLD);
    assert(document.textures[0].desc.alpha_threshold == 0.5 && !document.textures[0].supplied_mips.len);
    assert(document.textures[1].desc.coverage == CoveragePolicy.NONE);
    assert(mem::equals(document.textures[0].pixels, document.textures[1].pixels));
}

fn void test_authored_xyz_and_mixed_handedness_are_retained_then_signs_normalized_on_publish() @test {
    ModelDocument document = decode_text(tangent_fixture());
    defer asset::destroy_model_document(&document);

    assert(document.geometries[0].tangent_provenance.origin == TangentOrigin.AUTHORED);

    foreach (index, tangent : document.geometries[0].data.tangents) {
        assert(tangent.x == 2 && tangent.y == 0 && tangent.z == 0);
        assert(tangent.w == (index % 2 ? -3 : 2));
    }

    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);

    ModelId model = assets.publish_document(&document)!!;

    GeometryId id = assets.model(model).data.meshes[0].geometry;
    GeometryAsset* geometry = assets.geometry(id);

    assert(geometry.tangent_provenance.origin == TangentOrigin.AUTHORED);

    foreach (index, tangent : geometry.data.tangents) {
        assert(tangent.x == 2 && tangent.w == (index % 2 ? -1 : 1));
    }
}

fn void test_force_recovers_only_decodable_invalid_tangent_values() @test {
    LoadOptions forced = asset::LOAD_OPTIONS_DEFAULT;
    forced.generate_tangents = false;
    forced.regenerate_tangents = true;

    foreach (uint accessor : { 10, 11, 12 }) {
        String text = tangent_fixture().treplace(`"TANGENT":5`, string::tformat(`"TANGENT":%d`, accessor));

        expect_decode_fault(text, asset::LOAD_OPTIONS_DEFAULT, c3d::ASSET_FORMAT_ERROR);

        ModelDocument document = decode_text(text, forced);
        defer asset::destroy_model_document(&document);

        assert(document.geometries[0].tangent_provenance.origin == TangentOrigin.GENERATED);

        foreach (tangent : document.geometries[0].data.tangents) expect_direction(tangent, { 1, 0, 0 });
    }
}

fn void test_force_does_not_bypass_structural_tangent_shape_count_or_component_faults() @test {
    LoadOptions forced = asset::LOAD_OPTIONS_DEFAULT;
    forced.regenerate_tangents = true;

    foreach (uint accessor : { 13, 14, 16 }) {
        String text = tangent_fixture().treplace(`"TANGENT":5`, string::tformat(`"TANGENT":%d`, accessor));

        if (accessor == 16) text = text.treplace(`"asset":{"version":"2.0"}`, `"asset":{"version":"2.0"},"extensionsRequired":["KHR_mesh_quantization"]`);

        expect_decode_fault(text, forced, c3d::ASSET_FORMAT_ERROR);
    }

    String truncated = tangent_fixture().treplace(`"byteOffset":668,"byteLength":16`, `"byteOffset":668,"byteLength":20`);

    expect_decode_fault(truncated, forced, c3d::ASSET_FORMAT_ERROR);
}

fn void test_declared_signed_normalized_quantized_tangents_remain_authored() @test {
    String text = tangent_fixture().treplace(`"TANGENT":5`, `"TANGENT":15`);

    expect_decode_fault(text, asset::LOAD_OPTIONS_DEFAULT, c3d::ASSET_FORMAT_ERROR);

    text = text.treplace(`"asset":{"version":"2.0"}`, `"asset":{"version":"2.0"},"extensionsRequired":["KHR_mesh_quantization"]`);

    ModelDocument document = decode_text(text);
    defer asset::destroy_model_document(&document);

    assert(document.geometries[0].tangent_provenance.origin == TangentOrigin.AUTHORED);

    foreach (tangent : document.geometries[0].data.tangents) assert(tangent == (Vec4){ 1, 0, 0, 1 });
}

fn void test_selected_raw_uv1_and_generated_normals_preserve_all_owned_streams() @test {
    String text = tangent_fixture().treplace(`"TANGENT":5,`, "").treplace(`"NORMAL":1,`, "").treplace(`"texCoord":0`, `"texCoord":1`);
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    ModelDocument document = gltf::decode_model_memory(
        allocator: &tracker,
        bytes: (char[])text,
        base_dir: "",
        key: "import-uv1",
    )!!;

    DocumentGeometry* entry = &document.geometries[0];
    Geometry* geometry = &entry.data;

    assert(entry.tangent_provenance.origin == TangentOrigin.GENERATED && entry.tangent_provenance.uv_set == 1);
    assert(geometry.positions.len == 4 && geometry.normals.len == 4 && geometry.uv0.len == 4 && geometry.uv1.len == 4);
    assert(geometry.colors.len == 4 && geometry.joints.len == 4 && geometry.weights.len == 4 && geometry.indices.len == 6);
    assert(geometry.targets.len == 1 && geometry.targets[0].name == "raise");

    Vec4[4] colors = { { 1, 0, 0, 1 }, { 0, 1, 0, 0.75f }, { 0, 0, 1, 0.5f }, { 1, 1, 1, 0.25f } };

    foreach (index, position : geometry.positions) {
        expect_direction(geometry.tangents[index], { 0, -1, 0 });

        assert(geometry.normals[index] == (Vec3){ 0, 0, 1 });
        assert(geometry.uv0[index] == (Vec2){ position.x, position.y });
        assert(geometry.uv1[index] == (Vec2){ -position.y, position.x });
        assert(geometry.colors[index] == colors[index]);
        assert(geometry.joints[index] == (ushort[<4>]){ 0, 1, 0, 0 });
        assert(geometry.weights[index] == (Vec4){ 0.25f, 0.75f, 0, 0 });
        assert(math::abs(geometry.targets[0].position_deltas[index].z - ((float)index + 1) * 0.1f) < TANGENT_TOLERANCE);
        assert(geometry.targets[0].normal_deltas[index] == (Vec3){});
    }

    AssetStore assets = create_store(&tracker);
    ModelId model = assets.publish_document(&document)!!;

    GeometryId id = assets.model(model).data.meshes[0].geometry;
    GeometryAsset* published = assets.geometry(id);

    assert(published.tangent_provenance.origin == TangentOrigin.GENERATED && published.tangent_provenance.uv_set == 1);
    assert(published.tangent_provenance.derivation_revision == published.header.revision);

    assets.release_geometry_cpu(id);

    assert(!published.data.positions.ptr && published.tangent_provenance.origin == TangentOrigin.GENERATED);

    asset::destroy_model_document(&document);
    asset::destroy_asset_store(&assets);

    assert(tracker.allocated() == 0);
}

fn void test_lookup_transform_changes_sampling_but_generation_uses_raw_selected_uv() @test {
    String text = tangent_fixture().treplace(`"TANGENT":5,`, "");
    text = text.treplace(`"normalTexture":{"index":0,"texCoord":0}`,
        `"normalTexture":{"index":0,"texCoord":0,"extensions":{"KHR_texture_transform":{"texCoord":1,"rotation":1.2,"scale":[-2,0.5],"offset":[3,4]}}}`);

    ModelDocument document = decode_text(text);
    defer asset::destroy_model_document(&document);

    assert(document.materials[0].data.standard.normal_map.uv_set == 1);
    assert(document.materials[0].data.standard.normal_map.transform.rotation == 1.2f);
    assert(document.geometries[0].tangent_provenance.uv_set == 1);

    foreach (tangent : document.geometries[0].data.tangents) expect_direction(tangent, { 0, -1, 0 });
}

fn void test_missing_selected_uv_keeps_derivative_fallback_even_when_forced() @test {
    LoadOptions forced = asset::LOAD_OPTIONS_DEFAULT;
    forced.generate_tangents = false;
    forced.regenerate_tangents = true;
    String text = tangent_fixture().treplace(`"TEXCOORD_1":3,`, "").treplace(`"texCoord":0`, `"texCoord":1`);

    ModelDocument document = decode_text(text, forced);
    defer asset::destroy_model_document(&document);

    assert(!document.geometries[0].data.tangents.len);
    assert(document.geometries[0].data.uv0.len == 4 && !document.geometries[0].data.uv1.len);
    assert(document.geometries[0].tangent_provenance.origin == TangentOrigin.NONE);
}

fn void test_base_and_coat_uv_conflict_faults_only_when_generation_is_requested() @test {
    String text = tangent_fixture().treplace(`"normalTexture":{"index":0,"texCoord":0}`,
        `"normalTexture":{"index":0,"texCoord":0},"extensions":{"KHR_materials_clearcoat":{"clearcoatNormalTexture":{"index":0,"texCoord":1}}}`);

    ModelDocument authored = decode_text(text);
    defer asset::destroy_model_document(&authored);

    assert(authored.geometries[0].tangent_provenance.origin == TangentOrigin.AUTHORED);

    LoadOptions forced = asset::LOAD_OPTIONS_DEFAULT;
    forced.regenerate_tangents = true;

    expect_decode_fault(text, forced, c3d::UNSUPPORTED);

    String missing = text.treplace(`"TANGENT":5,`, "");

    expect_decode_fault(missing, asset::LOAD_OPTIONS_DEFAULT, c3d::UNSUPPORTED);

    LoadOptions disabled = asset::LOAD_OPTIONS_DEFAULT;
    disabled.generate_tangents = false;

    ModelDocument fallback = decode_text(missing, disabled);
    defer asset::destroy_model_document(&fallback);

    assert(!fallback.geometries[0].data.tangents.len);
}
