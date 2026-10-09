module c3d::test::import_fidelity_fbx;

import c3d;
import c3d::asset;
import c3d::asset::fbx;
import c3d::asset::image;
import c3d::material;
import std::math;
import c3d::geometry;

const String MODEL_PATH @local = "memory/materials.fbx";
const String IMAGE_PATH @local = "memory/shared.image";
const char[*] CUBE_MODEL @local = $embed("../fixtures/fbx/maya_cube_7400_binary.fbx");
const char[*] AUTHORED_TANGENT_FAULTS @local = $embed("../fixtures/import_fidelity/authored_tangent_faults_v1.fbx");
const String FAULTY_TANGENTS @local = "a: 0,0,0,NaN,0,0,2,0,0,2,0,0";
const String FAULTY_BINORMALS @local = "a: 0,0,0,0,NaN,0,0,3,0,0,3,0";
const String VALID_TANGENTS @local = "a: 2,0,0,2,0,0,2,0,0,2,0,0";
const String VALID_BINORMALS @local = "a: 0,3,0,0,3,0,0,3,0,0,3,0";
const char[*] PNG_PIXELS @local = $embed("../fixtures/rgba.png");
const char[*] DDS_RGBA @local = $embed("../fixtures/texture/legacy_rgba8_2x2.dds");
const char[*] KTX_BC5 @local = $embed("../fixtures/texture/ktx2_bc5_8x4.ktx2");
const char[*] KTX_GENERATE @local = $embed("../fixtures/texture/ktx1_rgba8_generate_2x2.ktx");

const String DOCUMENT @local = `; FBX 7.4.0 project file
FBXHeaderExtension: {
    FBXHeaderVersion: 1003
    FBXVersion: 7400
}
Objects: {
%s
    Video: 3001, "Video::shared", "Clip" {
        Type: "Clip"
        Filename: "shared.image"
        RelativeFilename: "shared.image"
    }
    Texture: 2001, "Texture::shared", "" {
        Type: "TextureVideoClip"
        Version: 202
        TextureName: "Texture::shared"
        Media: "Video::shared"
        FileName: "shared.image"
        RelativeFilename: "shared.image"
        ModelUVTranslation: 0,0
        ModelUVScaling: 1,1
    }
}
Connections: {
    C: "OO",3001,2001
%s
}
`;

const String ROLE_MATERIALS @local = `
    Material: 1001, "Material::roles", "" {
        Version: 102
        ShadingModel: "unknown"
        Properties70: {
            P: "3dsMax|ClassIDa", "int", "Integer", "",943849874
            P: "3dsMax|ClassIDb", "int", "Integer", "",1174294043
            P: "3dsMax|main|baseColor", "ColorAndAlpha", "", "A",1,1,1,1
            P: "3dsMax|main|baseColorMap", "Reference", "", "A"
            P: "3dsMax|main|normal", "Float", "", "A",1
            P: "3dsMax|main|normalMap", "Reference", "", "A"
            P: "3dsMax|main|ambientOcclusion", "Float", "", "A",1
            P: "3dsMax|main|ambientOcclusionMap", "Reference", "", "A"
            P: "3dsMax|main|roughness", "Float", "", "A",1
            P: "3dsMax|main|metalness", "Float", "", "A",0
            P: "3dsMax|main|Alpha", "Float", "", "A",1
        }
    }
    Material: 1002, "Material::reused", "" {
        Version: 102
        ShadingModel: "lambert"
        Properties70: {
            P: "DiffuseColor", "ColorRGB", "Color", "",1,1,1
            P: "NormalMap", "Vector3D", "Vector", "",0,0,1
        }
    }
`;

const String ROLE_CONNECTIONS @local = `
    C: "OP",2001,1001,"3dsMax|main|baseColorMap"
    C: "OP",2001,1001,"3dsMax|main|normalMap"
    C: "OP",2001,1001,"3dsMax|main|ambientOcclusionMap"
    C: "OP",2001,1002,"NormalMap"
`;

const String SINGLE_MATERIAL @local = `
    Material: 1001, "Material::single", "" {
        Version: 102
        ShadingModel: "lambert"
        Properties70: {
            P: "DiffuseColor", "ColorRGB", "Color", "",1,1,1
            P: "NormalMap", "Vector3D", "Vector", "",0,0,1
            P: "Bump", "double", "Number", "",1
        }
    }
`;
const String NORMAL_CONNECTION @local = `C: "OP",2001,1001,"NormalMap"`;
const String BUMP_CONNECTION @local = `C: "OP",2001,1001,"Bump"`;

struct MemorySource @local {
    String document;
    char[] encoded;
    usz image_reads;
}

struct SuppliedCase @local {
    char[] bytes;
    PixelFormat format;
    bool roles;
}

struct PublishedGeometry @local {
    String key;
    Vec3* positions;
    Vec3* normals;
    Vec2* uv0;
    uint* indices;
    Vec4* tangents;
}

fn char[]? read_memory(void* user, Allocator allocator, String path) @local {
    MemorySource* source = user;
    char[] bytes;

    if (path == MODEL_PATH) {
        bytes = (char[])source.document;
    } else if (path == IMAGE_PATH) {
        bytes = source.encoded;
        source.image_reads++;
    } else {
        return c3d::ASSET_IO_ERROR~;
    }

    char[] copied = alloc::new_array(allocator, char, (sz)bytes.len);
    mem::copy(copied.ptr, bytes.ptr, bytes.len);

    return copied;
}

fn MemorySource fixture_source(String materials, String connections, char[] encoded) @local {
    return {
        .document = string::tformat(DOCUMENT, materials, connections),
        .encoded = encoded,
    };
}

fn ModelDocument decode_fixture(
    Allocator allocator,
    MemorySource* source,
    LoadOptions options = asset::LOAD_OPTIONS_DEFAULT,
) @local {
    return fbx::decode_model(
        allocator: allocator,
        path: MODEL_PATH,
        options: options,
        file_source: { .read = &read_memory, .user = source },
    )!!;
}

fn DocumentTexture* texture_entry(ModelDocument* document, TextureId reference) @local {
    assert(reference.generation == 0 && reference.index > 0 && reference.index <= document.textures.len);

    return &document.textures[reference.index - 1];
}

fn void assert_roles(ModelDocument* document, TextureSemantic normal_semantic) @local {
    assert(document.materials.len == 2 && document.textures.len == 3);

    Material* roles = &document.materials[0].data;
    Material* reused = &document.materials[1].data;

    assert(roles.kind == MaterialKind.STANDARD && reused.kind == MaterialKind.STANDARD);

    TextureId color_id = roles.standard.base_color_map.texture.asset;
    TextureId data_id = roles.standard.occlusion_map.texture.asset;
    TextureId normal_id = roles.standard.normal_map.texture.asset;

    assert(!c3d::same_id(color_id, data_id) && !c3d::same_id(color_id, normal_id));
    assert(!c3d::same_id(data_id, normal_id));
    assert(c3d::same_id(normal_id, reused.standard.normal_map.texture.asset));

    DocumentTexture* color = texture_entry(document, color_id);
    DocumentTexture* data = texture_entry(document, data_id);
    DocumentTexture* normal = texture_entry(document, normal_id);

    assert(color.desc.format == RGBA8_SRGB && color.desc.semantic == TextureSemantic.COLOR);
    assert(data.desc.format == RGBA8_UNORM && data.desc.semantic == TextureSemantic.COLOR);
    assert(normal.desc.format == RGBA8_UNORM && normal.desc.semantic == normal_semantic);
    assert(color.key == "memory/materials.fbx#image/0/srgb");
    assert(data.key == "memory/materials.fbx#image/0/linear");

    String role = normal_semantic == TextureSemantic.NORMAL_RG ? "normal_rg" : "normal_rgb";
    String expected = string::tformat("memory/materials.fbx#image/0/%s/0", role);

    assert(normal.key == expected);

    foreach (entry : document.textures) assert(entry.desc.coverage == CoveragePolicy.NONE);

    assert(roles.common.alpha_mode == AlphaMode.OPAQUE && roles.common.alpha_cutoff == 0.5f);
}

fn void test_color_data_and_normal_roles_split_and_compatible_normals_reuse() @test {
    @pool() {
        MemorySource source = fixture_source(ROLE_MATERIALS, ROLE_CONNECTIONS, PNG_PIXELS[..]);

        ModelDocument document = decode_fixture(mem, &source);
        defer asset::destroy_model_document(&document);

        assert_roles(&document, TextureSemantic.NORMAL_RGB);

        image::Image decoded = image::decode_image(tmem, PNG_PIXELS[..])!!;

        foreach (entry : document.textures) {
            assert(entry.source_kind == MIP_ZERO && entry.desc.generate_mips);
            assert(entry.pixels == decoded.pixels && entry.supplied_mips.len == 0);
        }

        Material* material = &document.materials[0].data;
        TextureId normal_id = material.standard.normal_map.texture.asset;

        material.common.alpha_mode = AlphaMode.MASK;
        material.common.alpha_cutoff = 0.25f;
        material.standard.base_color.w = 0;

        assert(c3d::same_id(normal_id, document.materials[1].data.standard.normal_map.texture.asset));

        foreach (entry : document.textures) assert(entry.desc.coverage == CoveragePolicy.NONE);
    };
}

fn void test_explicit_rg_changes_only_the_normal_variant() @test {
    @pool() {
        MemorySource rgb_source = fixture_source(ROLE_MATERIALS, ROLE_CONNECTIONS, PNG_PIXELS[..]);

        ModelDocument rgb = decode_fixture(mem, &rgb_source);
        defer asset::destroy_model_document(&rgb);

        MemorySource rg_source = fixture_source(ROLE_MATERIALS, ROLE_CONNECTIONS, PNG_PIXELS[..]);
        LoadOptions options = asset::LOAD_OPTIONS_DEFAULT;
        options.normal_encoding = NormalEncoding.RG;

        ModelDocument rg = decode_fixture(mem, &rg_source, options);
        defer asset::destroy_model_document(&rg);

        assert_roles(&rgb, TextureSemantic.NORMAL_RGB);
        assert_roles(&rg, TextureSemantic.NORMAL_RG);

        foreach (index, &entry : rgb.textures) {
            DocumentTexture* other = &rg.textures[index];

            assert(entry.desc.format == other.desc.format && entry.pixels == other.pixels);

            if (entry.desc.semantic == TextureSemantic.COLOR) {
                assert(other.desc.semantic == TextureSemantic.COLOR && entry.key == other.key);
            } else {
                assert(entry.desc.semantic == TextureSemantic.NORMAL_RGB);
                assert(other.desc.semantic == TextureSemantic.NORMAL_RG && entry.key != other.key);
            }
        }
    };
}

fn void test_bump_connection_does_not_create_a_normal_texture() @test {
    @pool() {
        MemorySource source = fixture_source(SINGLE_MATERIAL, BUMP_CONNECTION, PNG_PIXELS[..]);
        LoadOptions options = asset::LOAD_OPTIONS_DEFAULT;
        options.normal_encoding = NormalEncoding.RG;

        ModelDocument document = decode_fixture(mem, &source, options);
        defer asset::destroy_model_document(&document);

        assert(document.materials.len == 1 && document.textures.len == 0);
        assert(c3d::same_id(document.materials[0].data.standard.normal_map.texture.asset, (TextureId){}));
        assert(source.image_reads == 0);
    };
}

fn void test_supplied_normal_chains_keep_bytes_and_do_not_infer_bc5_encoding() @test {
    @pool() {
        SuppliedCase[] cases = {
            { .bytes = DDS_RGBA[..], .format = RGBA8_UNORM, .roles = true },
            { .bytes = KTX_BC5[..], .format = BC5_UNORM },
        };

        NormalEncoding[2] encodings = { NormalEncoding.RGB, NormalEncoding.RG };

        foreach (entry : cases) {
            foreach (encoding : encodings) {
                MemorySource source = entry.roles
                  ? fixture_source(ROLE_MATERIALS, ROLE_CONNECTIONS, entry.bytes)
                  : fixture_source(SINGLE_MATERIAL, NORMAL_CONNECTION, entry.bytes);
                LoadOptions options = asset::LOAD_OPTIONS_DEFAULT;
                options.normal_encoding = encoding;

                TrackingAllocator tracker;
                tracker.init(mem);
                defer tracker.free();

                {
                    ModelDocument document = decode_fixture(&tracker, &source, options);
                    defer asset::destroy_model_document(&document);

                    TextureSemantic semantic = encoding == NormalEncoding.RG
                      ? TextureSemantic.NORMAL_RG : TextureSemantic.NORMAL_RGB;

                    if (entry.roles) {
                        assert_roles(&document, semantic);
                    } else {
                        assert(document.materials.len == 1 && document.textures.len == 1);
                    }

                    TextureId normal_id = document.materials[0].data.standard.normal_map.texture.asset;
                    DocumentTexture* normal = texture_entry(&document, normal_id);

                    assert(normal.desc.format == entry.format && normal.desc.semantic == semantic);

                    foreach (&texture : document.textures) {
                        image::ColorSpace color_space = texture.desc.format == RGBA8_SRGB
                          ? image::ColorSpace.SRGB : image::ColorSpace.LINEAR;
                        image::TextureContainerView expected = image::parse_texture_container(
                            scratch: tmem,
                            bytes: entry.bytes,
                            color_space: color_space,
                            semantic: texture.desc.semantic,
                        )!!;

                        assert(texture.source_kind == SUPPLIED_MIPS && texture.pixels.len == 0);
                        assert(!texture.desc.generate_mips && texture.desc.coverage == CoveragePolicy.NONE);
                        assert(texture.desc.mip_levels == expected.level_count);
                        assert(texture.supplied_mips.len == expected.level_count);

                        foreach (index, mip : texture.supplied_mips) {
                            assert(mip.mip == expected.levels[index].mip && mip.layer == expected.levels[index].layer);
                            assert(mip.bytes == expected.levels[index].bytes);
                            assert(mip.bytes.ptr != expected.levels[index].bytes.ptr);
                        }
                    }
                }

                assert(tracker.allocated() == 0);
            }
        }
    };
}

fn void test_ktx_mip_zero_keeps_generation_and_explicit_normal_semantics() @test {
    @pool() {
        MemorySource source = fixture_source(SINGLE_MATERIAL, NORMAL_CONNECTION, KTX_GENERATE[..]);
        LoadOptions options = asset::LOAD_OPTIONS_DEFAULT;
        options.normal_encoding = NormalEncoding.RG;

        ModelDocument document = decode_fixture(mem, &source, options);
        defer asset::destroy_model_document(&document);

        assert(document.textures.len == 1 && document.materials.len == 1);

        DocumentTexture* texture = &document.textures[0];
        image::TextureContainerView expected = image::parse_texture_container(
            scratch: tmem,
            bytes: KTX_GENERATE[..],
            color_space: image::ColorSpace.LINEAR,
            semantic: TextureSemantic.NORMAL_RG,
        )!!;

        assert(expected.desc.generate_mips);
        assert(texture.source_kind == MIP_ZERO && texture.desc.generate_mips);
        assert(texture.desc.semantic == TextureSemantic.NORMAL_RG && texture.desc.coverage == CoveragePolicy.NONE);
        assert(texture.supplied_mips.len == 0 && texture.pixels == expected.levels[0].bytes);
        assert(texture.pixels.ptr != expected.levels[0].bytes.ptr);
    };
}

fn void test_forced_fbx_tangents_use_converted_uv0_and_transfer_without_regeneration() @test {
    @pool() {
        MemorySource source = { .document = (String)CUBE_MODEL[..] };
        LoadOptions options = asset::LOAD_OPTIONS_DEFAULT;
        options.animations = false;
        options.generate_tangents = false;

        ModelDocument plain = decode_fixture(mem, &source, options);
        defer asset::destroy_model_document(&plain);

        options.regenerate_tangents = true;

        ModelDocument forced = decode_fixture(mem, &source, options);
        defer asset::destroy_model_document(&forced);

        assert(plain.geometries.len > 0 && plain.geometries.len == forced.geometries.len);

        PublishedGeometry[] transferred = alloc::new_array(tmem, PublishedGeometry, forced.geometries.len);

        foreach (index, &entry : forced.geometries) {
            Geometry* original = &plain.geometries[index].data;
            Geometry* generated = &entry.data;

            assert(original.uv0.len == original.positions.len && original.uv0.len > 0);
            assert(generated.normals.len == generated.positions.len && generated.uv0.len == generated.positions.len);
            assert(generated.tangents.len == generated.positions.len && generated.indices.len == original.indices.len);
            assert(generated.topology == original.topology);
            assert(entry.tangent_provenance.origin == TangentOrigin.GENERATED);
            assert(entry.tangent_provenance.uv_set == 0 && entry.tangent_provenance.derivation_revision == 0);

            foreach (corner, vertex : generated.indices) {
                uint original_vertex = original.indices[corner];
                Vec4 tangent = generated.tangents[vertex];
                Vec3 direction = { tangent.x, tangent.y, tangent.z };

                assert(generated.positions[vertex] == original.positions[original_vertex]);
                assert(generated.normals[vertex] == original.normals[original_vertex]);
                assert(generated.uv0[vertex] == original.uv0[original_vertex]);
                assert(math::abs(direction.length() - 1) < 0.00001f);
                assert(tangent.w == 1 || tangent.w == -1);
            }

            transferred[index] = {
                .key = entry.key.copy(tmem),
                .positions = generated.positions.ptr,
                .normals = generated.normals.ptr,
                .uv0 = generated.uv0.ptr,
                .indices = generated.indices.ptr,
                .tangents = generated.tangents.ptr,
            };
        }

        AssetStore assets = asset::create_asset_store(mem, {
            .max_geometries = 8,
            .max_textures = asset::BUILTIN_TEXTURE_COUNT + 8,
            .max_materials = 8,
            .max_samplers = asset::BUILTIN_SAMPLER_COUNT + 2,
            .max_models = 1,
            .max_skeletons = 1,
            .max_clips = 1,
        });
        defer asset::destroy_asset_store(&assets);
        (void)assets.publish_document(&forced)!!;

        assert(forced.geometries.len == 0);

        foreach (expected : transferred) {
            GeometryAsset* record = assets.geometry(assets.find_geometry(expected.key)!!);

            assert(record.tangent_provenance.origin == TangentOrigin.GENERATED);
            assert(record.tangent_provenance.uv_set == 0);
            assert(record.tangent_provenance.derivation_revision == record.header.revision);
            assert(record.data.positions.ptr == expected.positions && record.data.normals.ptr == expected.normals);
            assert(record.data.uv0.ptr == expected.uv0 && record.data.indices.ptr == expected.indices);
            assert(record.data.tangents.ptr == expected.tangents);
        }
    };
}

fn void test_fbx_authored_zero_and_nan_tangents_fault_unless_forced() @test {
    @pool() {
        String malformed = (String)AUTHORED_TANGENT_FAULTS[..];
        String valid = malformed.treplace(FAULTY_TANGENTS, VALID_TANGENTS).treplace(FAULTY_BINORMALS, VALID_BINORMALS);

        TrackingAllocator tracker;
        tracker.init(mem);
        defer tracker.free();

        {
            MemorySource source = { .document = valid };
            ModelDocument document = decode_fixture(&tracker, &source);
            defer asset::destroy_model_document(&document);

            assert(document.geometries.len == 1);
            assert(document.geometries[0].tangent_provenance.origin == TangentOrigin.AUTHORED);

            foreach (tangent : document.geometries[0].data.tangents) assert(tangent == (Vec4){ 2, 0, 0, -1 });
        }

        assert(tracker.allocated() == 0);

        String[5] cases = {
            malformed,
            valid.treplace(VALID_TANGENTS, "a: 0,0,0,2,0,0,2,0,0,2,0,0"),
            valid.treplace(VALID_TANGENTS, "a: NaN,0,0,2,0,0,2,0,0,2,0,0"),
            valid.treplace(VALID_BINORMALS, "a: 0,0,0,0,3,0,0,3,0,0,3,0"),
            valid.treplace(VALID_BINORMALS, "a: 0,NaN,0,0,3,0,0,3,0,0,3,0"),
        };

        foreach (text : cases) {
            MemorySource source = { .document = text };
            ModelDocument? result = fbx::decode_model(
                allocator: &tracker,
                path: MODEL_PATH,
                file_source: { .read = &read_memory, .user = &source },
            );
            bool rejected;

            if (catch excuse = result) {
                rejected = true;
                assert(excuse == c3d::ASSET_FORMAT_ERROR);
            } else {
                ModelDocument document = result;
                asset::destroy_model_document(&document);
            }

            assert(rejected && tracker.allocated() == 0);

            {
                LoadOptions forced = asset::LOAD_OPTIONS_DEFAULT;
                forced.generate_tangents = false;
                forced.regenerate_tangents = true;

                ModelDocument document = decode_fixture(&tracker, &source, forced);
                defer asset::destroy_model_document(&document);

                assert(document.geometries.len == 1);

                DocumentGeometry* entry = &document.geometries[0];

                assert(entry.tangent_provenance.origin == TangentOrigin.GENERATED);
                assert(entry.tangent_provenance.uv_set == 0);
                assert(entry.data.positions.len == 4 && entry.data.indices.len == 6);
                assert(entry.data.tangents.len == entry.data.positions.len);

                foreach (index, tangent : entry.data.tangents) {
                    Vec3 position = entry.data.positions[index];

                    assert(tangent == (Vec4){ 1, 0, 0, -1 });
                    assert(entry.data.normals[index] == (Vec3){ 0, 0, 1 });
                    assert(entry.data.uv0[index] == (Vec2){ position.x, 1 - position.y });
                }
            }

            assert(tracker.allocated() == 0);
        }
    };
}
