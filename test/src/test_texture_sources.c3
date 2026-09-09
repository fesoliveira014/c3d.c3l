module c3d::test::texture_sources;

import c3d;
import c3d::asset;
import c3d::asset::image;
import c3d::material;
import c3d::render;
import std::io::path;

fn AssetStore create_texture_source_store(Allocator allocator) @local {
    return asset::create_asset_store(allocator, {
        .max_geometries = 1,
        .max_textures = 8,
        .max_materials = 1,
        .max_samplers = 5,
    });
}

fn void test_supplied_source_owns_copies_and_release_keeps_identity() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    {
        AssetStore assets = asset::create_asset_store(&tracker, {
            .max_geometries = 1,
            .max_textures = 5,
            .max_materials = 1,
            .max_samplers = 5,
        });
        defer asset::destroy_asset_store(&assets);

        char[16] base = { [0] = 255, [1] = 0, [2] = 0, [3] = 255 };
        char[4] tail = { 0, 255, 0, 255 };
        TextureMipData[2] levels = {
            { .mip = 0, .layer = 0, .bytes = base[..] },
            { .mip = 1, .layer = 0, .bytes = tail[..] },
        };
        material::TextureDesc desc = material::texture_2d_desc(2, 2, RGBA8_UNORM);
        desc.generate_mips = false;
        desc.mip_levels = 2;
        TextureId texture = assets.add_texture_mips(desc, levels[..])!!;
        base[0] = 0;
        tail[1] = 0;
        levels[0].mip = 3;
        TextureAsset* record = assets.texture(texture);

        assert(record.pixels.len == 0 && record.source_kind == SUPPLIED_MIPS);
        assert(record.supplied_mips[0].mip == 0 && record.supplied_mips[0].bytes[0] == 255);
        assert(record.supplied_mips[1].bytes[1] == 255);

        uint revision = record.header.revision;
        assets.release_texture_cpu(texture);

        assert(record.supplied_mips.len == 0 && record.header.revision == revision && record.desc.mip_levels == 2);
        assert(record.source_kind == SUPPLIED_MIPS && assets.textures.is_live(texture));
        if (catch excuse = render::create_supplied_texture_mips(mem, record.desc, record.supplied_mips)) {
            assert(excuse == c3d::ASSET_DATA_UNAVAILABLE);
        } else {
            assert(false, "Released source accepted");
        }
    }

    assert(!tracker.has_leaks());
}

fn void test_bc_chain_preserves_blocks_and_tail() @test {
    char[32] base = { [0] = 1, [1] = 2, [2] = 3, [3] = 4 };
    char[8] level1 = { [0] = 5, [1] = 6, [2] = 7, [3] = 8 };
    char[8] level2 = { [0] = 9, [1] = 10, [2] = 11, [3] = 12 };
    char[8] level3 = { [0] = 13, [1] = 14, [2] = 15, [3] = 16 };
    TextureMipData[4] levels = {
        { .mip = 0, .bytes = base[..] },
        { .mip = 1, .bytes = level1[..] },
        { .mip = 2, .bytes = level2[..] },
        { .mip = 3, .bytes = level3[..] },
    };
    material::TextureDesc desc = material::texture_2d_desc(8, 8, BC1_RGBA_UNORM);
    desc.generate_mips = false;
    desc.mip_levels = 4;
    TextureMipChain chain = render::create_supplied_texture_mips(mem, desc, levels[..])!!;
    defer render::destroy_texture_mips(&chain);

    assert(chain.pixels.len == 56 && chain.offsets[1] == 32 && chain.offsets[2] == 40 && chain.offsets[3] == 48);
    assert(chain.pixels[:32] == base[..] && chain.pixels[48..] == level3[..]);
    levels[3].bytes = level3[:4];
    if (catch excuse = render::create_supplied_texture_mips(mem, desc, levels[..])) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "Partial BC tail accepted");
    }
}

fn void test_cube_generated_mips_keep_faces_separate() @test {
    char[96] pixels;
    for (uint face = 0; face < material::CUBE_FACE_COUNT; face++) {
        for (uint pixel = 0; pixel < 4; pixel++) {
            usz offset = (usz)face * 16 + (usz)pixel * 4;
            pixels[offset] = (char)(face * 40);
            pixels[offset + 3] = 255;
        }
    }
    TextureMipChain chain = render::create_texture_mips(mem, material::texture_cube_desc(2, RGBA8_UNORM), pixels[..])!!;
    defer render::destroy_texture_mips(&chain);

    assert(chain.layer_count == 6 && chain.mip_count == 2 && chain.offsets[1] == 96 && chain.pixels.len == 120);
    for (uint face = 0; face < material::CUBE_FACE_COUNT; face++) {
        assert(chain.pixels[96 + face * 4] == (char)(face * 40));
        assert(chain.pixels[96 + face * 4 + 3] == 255);
    }
}

fn String cube_fixture(String name) @local {
    return (String)path::tnew($$FILEPATH)!!.parent()!!.tappend("../fixtures/cube", name)!!;
}

fn void test_cube_loader_preserves_face_order_and_hdr_range() @test {
    @pool() {
        AssetStore assets = create_texture_source_store(mem);
        defer asset::destroy_asset_store(&assets);

        String[6] faces = {
            cube_fixture("face0.png"), cube_fixture("face1.png"), cube_fixture("face2.png"),
            cube_fixture("face3.png"), cube_fixture("face4.png"), cube_fixture("face5.png"),
        };
        TextureId texture = image::load_cube(&assets, faces, true)!!;
        TextureAsset* record = assets.texture(texture);

        assert(record.desc.is_cube && record.desc.layers == 6 && record.desc.format == RGBA8_SRGB);
        assert(record.pixels.len == 96);
        for (uint face = 0; face < 6; face++) assert(record.pixels[face * 16] == (char)(face * 40));

        String[6] hdr_faces = {
            cube_fixture("face0.hdr"), cube_fixture("face1.hdr"), cube_fixture("face2.hdr"),
            cube_fixture("face3.hdr"), cube_fixture("face4.hdr"), cube_fixture("face5.hdr"),
        };
        TextureId hdr = image::load_cube(&assets, hdr_faces, true)!!;
        TextureAsset* float_record = assets.texture(hdr);
        assert(float_record.desc.format == RGBA32_FLOAT && float_record.pixels.len == 384);
        float[] values = ((float*)float_record.pixels.ptr)[:96];
        for (uint face = 0; face < 6; face++) assert(values[face * 16] == (float)(face + 1) * 0.5f);

        faces[5] = cube_fixture("gray.jpg");
        TextureId mixed_ldr = image::load_cube(&assets, faces, false)!!;
        TextureAsset* linear = assets.texture(mixed_ldr);
        assert(linear.desc.format == RGBA8_UNORM && linear.source_kind == MIP_ZERO);
        assert(linear.pixels[5 * 16] == 128 && linear.pixels[5 * 16 + 3] == 255);
    };
}

fn void test_cube_loader_failure_releases_partial_faces() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    @pool() {
        AssetStore assets = asset::create_asset_store(&tracker, {
            .max_geometries = 1,
            .max_textures = 8,
            .max_materials = 1,
            .max_samplers = 5,
        });
        defer asset::destroy_asset_store(&assets);

        String[6] faces = {
            cube_fixture("face0.png"), cube_fixture("face1.png"), cube_fixture("face2.png"),
            cube_fixture("face3.png"), cube_fixture("face4.png"), cube_fixture("face5.png"),
        };
        sz before = tracker.allocated();
        faces[0] = cube_fixture("rect.png");
        if (catch excuse = image::load_cube(&assets, faces, false)) {
            assert(excuse == c3d::ASSET_FORMAT_ERROR);
        } else {
            assert(false, "Non-square first face was accepted");
        }
        assert(tracker.allocated() == before);
        faces[0] = cube_fixture("face0.png");

        faces[5] = cube_fixture("rect.png");
        if (catch excuse = image::load_cube(&assets, faces, false)) {
            assert(excuse == c3d::ASSET_FORMAT_ERROR);
        } else {
            assert(false, "Mismatched face was accepted");
        }
        assert(tracker.allocated() == before);

        faces[5] = cube_fixture("large.png");
        if (catch excuse = image::load_cube(&assets, faces, false)) {
            assert(excuse == c3d::ASSET_FORMAT_ERROR);
        } else {
            assert(false, "Unequal square faces were accepted");
        }
        assert(tracker.allocated() == before);

        faces[5] = cube_fixture("face5.hdr");
        if (catch excuse = image::load_cube(&assets, faces, true)) {
            assert(excuse == c3d::ASSET_FORMAT_ERROR);
        } else {
            assert(false, "Mixed HDR cube was accepted");
        }
        assert(tracker.allocated() == before);

        faces[5] = cube_fixture("missing.png");
        if (catch excuse = image::load_cube(&assets, faces, true)) {
            assert(excuse == c3d::ASSET_IO_ERROR);
        } else {
            assert(false, "Missing face was accepted");
        }
        assert(tracker.allocated() == before);
    };

    assert(!tracker.has_leaks());
}

fn void test_supplied_source_removal_and_destruction_free_one_owner() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    {
        AssetStore assets = create_texture_source_store(&tracker);
        defer asset::destroy_asset_store(&assets);

        char[16] base = {};
        char[4] tail = {};
        TextureMipData[2] levels = {
            { .mip = 0, .bytes = base[..] },
            { .mip = 1, .bytes = tail[..] },
        };
        TextureDesc desc = material::texture_2d_desc(2, 2, RGBA8_UNORM);
        desc.generate_mips = false;
        desc.mip_levels = 2;
        sz before = tracker.allocation_count();
        TextureId removed = assets.add_texture_mips(desc, levels[..])!!;
        assert(tracker.allocation_count() == before + 1);

        assets.remove_texture(removed);
        assert(!assets.textures.is_live(removed) && tracker.allocation_count() == before);

        TextureId retained = assets.add_texture_mips(desc, levels[..])!!;
        assets.texture(retained).supplied_mips[1].bytes[0] = 255;
        assets.mark_texture_dirty(retained);
        assert(tail[0] == 0 && assets.texture(retained).header.revision == 2);
    }

    assert(!tracker.has_leaks());
}

fn void test_supplied_source_capacity_and_empty_payload_do_not_allocate() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    {
        AssetStore assets = asset::create_asset_store(&tracker, {
            .max_geometries = 1,
            .max_textures = asset::BUILTIN_TEXTURE_COUNT,
            .max_materials = 1,
            .max_samplers = asset::BUILTIN_SAMPLER_COUNT,
        });
        defer asset::destroy_asset_store(&assets);

        char[4] pixel = {};
        TextureMipData[1] levels = {{ .bytes = pixel[..] }};
        TextureDesc desc = material::texture_2d_desc(1, 1, RGBA8_UNORM);
        desc.generate_mips = false;
        sz before = tracker.allocated();

        if (catch excuse = assets.add_texture_mips(desc, levels[..])) {
            assert(excuse == c3d::CAPACITY_EXCEEDED);
        } else {
            assert(false, "Full store accepted supplied mips");
        }
        assert(tracker.allocated() == before);

        levels[0].bytes = {};
        if (catch excuse = assets.add_texture_mips(desc, levels[..])) {
            assert(excuse == c3d::INVALID_ARGUMENT);
        } else {
            assert(false, "Empty supplied payload was accepted");
        }
        assert(tracker.allocated() == before);
    }

    assert(!tracker.has_leaks());
}

fn void test_supplied_source_order_and_rejected_insert_are_atomic() @test {
    AssetStore assets = create_texture_source_store(mem);
    defer asset::destroy_asset_store(&assets);

    char[16] pixels = {};
    TextureMipData[2] levels = {
        { .mip = 0, .bytes = pixels[..] },
        { .mip = 1, .bytes = pixels[:4] },
    };
    material::TextureDesc desc = material::texture_2d_desc(2, 2, RGBA8_UNORM);
    desc.generate_mips = false;
    desc.mip_levels = 2;
    levels[1].mip = 0;
    if (catch excuse = assets.add_texture_mips(desc, levels[..], "cube/mips")) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "Duplicate mip was accepted");
    }
    levels[1].mip = 1;
    TextureId texture = assets.add_texture_mips(desc, levels[..], "cube/mips")!!;
    assert(texture.index == asset::BUILTIN_TEXTURE_COUNT);
    char* owned = assets.texture(texture).supplied_mips[0].bytes.ptr;
    if (catch excuse = assets.add_texture_mips(desc, levels[..], "cube/mips")) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "Duplicate key was accepted");
    }
    assert(assets.texture(texture).supplied_mips[0].bytes.ptr == owned);
}

fn void test_supplied_cube_mips_are_not_regenerated() @test {
    char[96] base;
    char[24] tail;
    TextureMipData[12] levels;
    for (uint face = 0; face < 6; face++) {
        base[face * 16] = (char)(face * 30);
        tail[face * 4] = (char)(255 - face * 30);
        levels[face] = { .mip = 0, .layer = face, .bytes = base[face * 16:16] };
        levels[6 + face] = { .mip = 1, .layer = face, .bytes = tail[face * 4:4] };
    }
    material::TextureDesc desc = material::texture_cube_desc(2, RGBA8_UNORM);
    desc.generate_mips = false;
    desc.mip_levels = 2;
    TextureMipChain chain = render::create_supplied_texture_mips(mem, desc, levels[..])!!;
    defer render::destroy_texture_mips(&chain);

    assert(chain.layer_count == 6 && chain.offsets[1] == 96 && chain.pixels.len == 120);
    assert(chain.pixels[:96] == base[..] && chain.pixels[96..] == tail[..]);
}

fn void test_bc7_odd_extent_uses_complete_blocks() @test {
    char[64] base = {};
    char[16] level1 = {};
    char[16] level2 = {};
    TextureMipData[3] levels = {
        { .mip = 0, .bytes = base[..] },
        { .mip = 1, .bytes = level1[..] },
        { .mip = 2, .bytes = level2[..] },
    };
    material::TextureDesc desc = material::texture_2d_desc(5, 7, BC7_UNORM);
    desc.generate_mips = false;
    desc.mip_levels = 3;
    TextureMipChain chain = render::create_supplied_texture_mips(mem, desc, levels[..])!!;
    defer render::destroy_texture_mips(&chain);

    assert(chain.offsets[1] == 64 && chain.offsets[2] == 80 && chain.pixels.len == 96);
}

fn void test_cube_loader_insertion_failure_releases_combined_pixels() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    @pool() {
        AssetStore assets = asset::create_asset_store(&tracker, {
            .max_geometries = 1,
            .max_textures = 4,
            .max_materials = 1,
            .max_samplers = 5,
        });
        defer asset::destroy_asset_store(&assets);

        String[6] faces = {
            cube_fixture("face0.png"), cube_fixture("face1.png"), cube_fixture("face2.png"),
            cube_fixture("face3.png"), cube_fixture("face4.png"), cube_fixture("face5.png"),
        };
        sz before = tracker.allocated();
        if (catch excuse = image::load_cube(&assets, faces, false)) {
            assert(excuse == c3d::CAPACITY_EXCEEDED);
        } else {
            assert(false, "Full store accepted a cube");
        }
        assert(tracker.allocated() == before);
    };

    assert(!tracker.has_leaks());
}

fn void test_invalid_supplied_shape_and_generation_faults() @test {
    AssetStore assets = create_texture_source_store(mem);
    defer asset::destroy_asset_store(&assets);

    char[16] bytes = {};
    TextureMipData[1] levels = {{ .mip = 0, .layer = 0, .bytes = bytes[..] }};
    material::TextureDesc desc = material::texture_2d_desc(2, 2, RGBA8_UNORM);
    if (catch excuse = assets.add_texture_mips(desc, levels[..])) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "Supplied data requested generation");
    }
    desc.generate_mips = false;
    desc.mip_levels = 2;
    if (catch excuse = assets.add_texture_mips(desc, levels[..])) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "Missing mip accepted");
    }
    desc = material::texture_cube_desc(2, BC1_RGBA_UNORM);
    desc.generate_mips = false;
    if (catch excuse = render::create_supplied_texture_mips(mem, desc, levels[..])) {
        assert(excuse == c3d::UNSUPPORTED);
    } else {
        assert(false, "Compressed cube accepted");
    }
}
