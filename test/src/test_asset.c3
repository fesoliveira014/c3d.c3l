module c3d::test::asset;

import std::math;
import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::material;

fn AssetStore make_store() @local {
    return asset::create_asset_store(mem, {
        .max_geometries = 4,
        .max_textures   = asset::BUILTIN_TEXTURE_COUNT + 2,
        .max_materials  = 2,
        .max_samplers   = asset::BUILTIN_SAMPLER_COUNT + 1,
    });
}

fn Geometry make_quad(Allocator allocator) @local {
    Vec3[] positions = alloc::new_array(allocator, Vec3, 4);
    positions[0] = { 0, 0, 0 };
    positions[1] = { 1, 0, 0 };
    positions[2] = { 1, 1, 0 };
    positions[3] = { 0, 1, 0 };
    Vec2[] uv0 = alloc::new_array(allocator, Vec2, 4);
    uv0[0] = { 0, 0 };
    uv0[1] = { 1, 0 };
    uv0[2] = { 1, 1 };
    uv0[3] = { 0, 1 };
    uint[] indices = alloc::new_array(allocator, uint, 6);
    indices[..] = (uint[6]){ 0, 1, 2, 0, 2, 3 }[..];
    return {
        .positions = positions,
        .uv0       = uv0,
        .indices   = indices,
        .bounds    = { .min = { 0, 0, 0 }, .max = { 1, 1, 0 } },
    };
}

fn TextureDesc make_texture_desc() @local {
    return material::texture_2d_desc(
        width:      2,
        height:     2,
        format:     RGBA8_UNORM,
        debug_name: "test_texture",
    );
}

fn void test_revision_starts_at_one_and_marks_increment() @test {
    AssetStore assets = make_store();
    defer asset::destroy_asset_store(&assets);

    Geometry quad = make_quad(tmem);
    GeometryId geometry = assets.add_geometry(&quad)!!;
    assert(assets.geometry(geometry).header.revision == 1);
    assets.mark_geometry_dirty(geometry);
    assets.mark_geometry_dirty(geometry);
    assert(assets.geometry(geometry).header.revision == 3);

    char[16] pixels;
    TextureId texture = assets.add_texture(make_texture_desc(), pixels[..])!!;
    assert(assets.texture(texture).header.revision == 1);
    assets.mark_texture_dirty(texture);
    assert(assets.texture(texture).header.revision == 2);

    SamplerId sampler = assets.add_sampler(material::sampler_desc(LINEAR, REPEAT))!!;
    assert(assets.sampler(sampler).header.revision == 1);
    assets.mark_sampler_dirty(sampler);
    assert(assets.sampler(sampler).header.revision == 2);
}

fn void test_remove_bumps_generation_and_frees_key() @test {
    AssetStore assets = make_store();
    defer asset::destroy_asset_store(&assets);

    Geometry quad = make_quad(tmem);
    GeometryId first = assets.add_geometry(&quad, "quad")!!;
    assets.remove_geometry(first);

    assert(!assets.geometries.is_live(first));
    if (catch excuse = assets.find("quad")) {
        assert(excuse == NOT_FOUND);
    } else {
        assert(false, "a removed key still resolved");
    }

    GeometryId second = assets.add_geometry(&quad, "quad")!!;
    assert(second.index == first.index);
    assert(second.generation > first.generation);
    assert(assets.find_geometry("quad")!!.generation == second.generation);
}

fn void test_add_from_temporary_memory_survives_the_scope() @test {
    AssetStore assets = make_store();
    defer asset::destroy_asset_store(&assets);

    GeometryId geometry;
    Vec3* temporary_positions;
    @pool() {
        Geometry quad = make_quad(tmem);
        temporary_positions = quad.positions.ptr;
        geometry = assets.add_geometry(&quad)!!;
    };

    GeometryAsset* record = assets.geometry(geometry);
    assert(record.data.positions.ptr != temporary_positions);
    assert(record.data.positions.len == 4);
    assert(record.data.positions[2] == (Vec3){ 1, 1, 0 });
    assert(record.data.uv0[3] == (Vec2){ 0, 1 });
    assert(record.data.indices.len == 6);
    assert(record.data.indices[5] == 3);
    assert(record.vertex_count == 4 && record.index_count == 6);
}

fn void test_owned_add_keeps_the_arrays() @test {
    AssetStore assets = make_store();
    defer asset::destroy_asset_store(&assets);

    Geometry quad = make_quad(mem);
    Vec3* owned_positions = quad.positions.ptr;
    GeometryId geometry = assets.add_geometry_owned(&quad)!!;

    assert(assets.geometry(geometry).data.positions.ptr == owned_positions);
    assert(assets.geometry(geometry).vertex_count == 4);
}

fn void test_duplicate_key_faults_without_taking_a_slot() @test {
    AssetStore assets = make_store();
    defer asset::destroy_asset_store(&assets);

    Geometry quad = make_quad(tmem);
    assets.add_geometry(&quad, "quad")!!;
    if (catch excuse = assets.add_geometry(&quad, "quad")) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "a duplicate key was accepted");
    }

    assets.add_geometry(&quad, "second")!!;
    assets.add_geometry(&quad, "third")!!;
    assets.add_geometry(&quad, "fourth")!!;
}

fn void test_empty_keys_do_not_collide() @test {
    AssetStore assets = make_store();
    defer asset::destroy_asset_store(&assets);

    Geometry quad = make_quad(tmem);
    assets.add_geometry(&quad)!!;
    assets.add_geometry(&quad)!!;
    if (catch excuse = assets.find("")) {
        assert(excuse == NOT_FOUND);
    } else {
        assert(false, "an empty key resolved");
    }
}

fn void test_release_keeps_the_record() @test {
    AssetStore assets = make_store();
    defer asset::destroy_asset_store(&assets);

    Geometry quad = make_quad(tmem);
    GeometryId geometry = assets.add_geometry(&quad, "quad")!!;
    assets.mark_geometry_dirty(geometry);
    assets.release_geometry_cpu(geometry);

    GeometryAsset* record = assets.geometry(geometry);
    assert(assets.geometries.is_live(geometry));
    assert(record.header.revision == 2);
    assert(record.vertex_count == 4 && record.index_count == 6);
    assert(record.data.bounds.max == (Vec3){ 1, 1, 0 });
    assert(record.data.positions.len == 0 && record.data.uv0.len == 0 && record.data.indices.len == 0);
    assert(record.header.key == "quad");

    assets.mark_geometry_dirty(geometry);
    assets.release_geometry_cpu(geometry);
    assert(record.header.revision == 3);
}

fn void test_geometry_channels_are_copied_and_survive_release() @test {
    AssetStore assets = make_store();
    defer asset::destroy_asset_store(&assets);
    GeometryId geometry;
    @pool() {
        Geometry quad = make_quad(tmem);
        quad.targets = alloc::new_array(tmem, MorphTarget, 2);
        foreach (&target : quad.targets) {
            target.position_deltas = alloc::new_array(tmem, Vec3, 4);
            target.normal_deltas = alloc::new_array(tmem, Vec3, 4);
        }
        float[] full_weights = alloc::new_array(tmem, float, 2);
        full_weights[0] = 0.5f;
        full_weights[1] = 1;
        quad.channels = alloc::new_array(tmem, MorphChannel, 1);
        quad.channels[0] = { .name = "smile", .first_target = 0, .full_weights = full_weights };
        geometry = assets.add_geometry(&quad, "morph_quad")!!;
    };

    GeometryAsset* record = assets.geometry(geometry);
    assert(record.data.channels.len == 1 && record.data.channels[0].name == "smile");
    assert(record.data.channels[0].full_weights.len == 2 && record.data.channels[0].full_weights[0] == 0.5f);

    assets.release_geometry_cpu(geometry);
    assert(record.data.targets.len == 0 && record.data.positions.len == 0 && record.target_count == 2);
    assert(record.data.channels.len == 1 && record.data.channels[0].name == "smile");
    assert(record.data.channels[0].first_target == 0 && record.data.channels[0].full_weights[1] == 1);
}

fn void test_release_texture_keeps_desc() @test {
    AssetStore assets = make_store();
    defer asset::destroy_asset_store(&assets);

    char[16] pixels;
    TextureId texture = assets.add_texture(make_texture_desc(), pixels[..])!!;
    assets.release_texture_cpu(texture);

    TextureAsset* record = assets.texture(texture);
    assert(assets.textures.is_live(texture));
    assert(record.pixels.len == 0);
    assert(record.desc.width == 2 && record.desc.height == 2);
    assert(record.desc.format == RGBA8_UNORM);
}

fn void test_full_pool_faults_capacity() @test {
    AssetStore assets = make_store();
    defer asset::destroy_asset_store(&assets);

    Geometry quad = make_quad(tmem);
    for (uint index = 0; index < 4; index++) {
        assets.add_geometry(&quad)!!;
    }
    if (catch excuse = assets.add_geometry(&quad, "overflow")) {
        assert(excuse == c3d::CAPACITY_EXCEEDED);
    } else {
        assert(false, "a full pool accepted a geometry");
    }
    assert(!assets.keys.has_key("overflow"));
}

fn void test_builtins_are_live_at_fixed_ids() @test {
    AssetStore assets = make_store();
    defer asset::destroy_asset_store(&assets);

    assert(assets.textures.is_live(asset::TEXTURE_WHITE));
    assert(assets.textures.is_live(asset::TEXTURE_BLACK));
    assert(assets.textures.is_live(asset::TEXTURE_FLAT_NORMAL));
    assert(assets.textures.is_live(asset::TEXTURE_CHECKER));
    assert(assets.samplers.is_live(asset::SAMPLER_LINEAR_REPEAT));
    assert(assets.samplers.is_live(asset::SAMPLER_LINEAR_CLAMP));
    assert(assets.samplers.is_live(asset::SAMPLER_NEAREST));
    assert(assets.samplers.is_live(asset::SAMPLER_ANISOTROPIC));
    assert(assets.samplers.is_live(asset::SAMPLER_SHADOW));

    TextureId white = assets.find_texture("builtin/white")!!;
    assert(white.index == asset::TEXTURE_WHITE.index && white.generation == asset::TEXTURE_WHITE.generation);
    assert(assets.texture(asset::TEXTURE_WHITE).pixels[0] == 255);
    assert(assets.texture(asset::TEXTURE_FLAT_NORMAL).pixels[2] == 255);
    TextureAsset* checker = assets.texture(asset::TEXTURE_CHECKER);
    assert(checker.desc.width == 8 && checker.desc.height == 8);
    assert(checker.desc.format == RGBA8_SRGB);
    assert(checker.pixels.len == 8 * 8 * 4);
    assert(checker.desc.generate_mips);
    assert(assets.sampler(asset::SAMPLER_SHADOW).desc.compare == GREATER_EQUAL);
    assert(assets.sampler(asset::SAMPLER_SHADOW).desc.compare_enable);
    assert(assets.sampler(asset::SAMPLER_ANISOTROPIC).desc.anisotropy_enable);
    assert(assets.sampler(asset::SAMPLER_LINEAR_CLAMP).desc.address_u == CLAMP_TO_EDGE);

    AssetStore second = make_store();
    defer asset::destroy_asset_store(&second);
    SamplerId shadow = second.find_sampler("builtin/shadow")!!;
    assert(shadow.index == asset::SAMPLER_SHADOW.index && shadow.generation == asset::SAMPLER_SHADOW.generation);
}

fn void test_find_returns_the_kind() @test {
    AssetStore assets = make_store();
    defer asset::destroy_asset_store(&assets);

    Geometry quad = make_quad(tmem);
    GeometryId geometry = assets.add_geometry(&quad, "quad")!!;

    AssetRef found = assets.find("quad")!!;
    assert(found.kind == AssetKind.GEOMETRY);
    assert(found.id.index == geometry.index && found.id.generation == geometry.generation);
    if (catch excuse = assets.find_texture("quad")) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "a geometry key resolved as a texture");
    }
}

fn void test_morph_targets_are_deep_copied() @test {
    AssetStore assets = make_store();
    defer asset::destroy_asset_store(&assets);

    GeometryId geometry;
    @pool() {
        Geometry quad = make_quad(tmem);
        Vec3[] deltas = alloc::new_array(tmem, Vec3, 4);
        deltas[1] = { 0, 0, 5 };
        MorphTarget[] targets = alloc::new_array(tmem, MorphTarget, 1);
        targets[0] = { .position_deltas = deltas, .name = string::tformat("smile_%d", 1) };
        quad.targets = targets;
        geometry = assets.add_geometry(&quad)!!;
    };

    GeometryAsset* record = assets.geometry(geometry);
    assert(record.target_count == 1);
    assert(record.data.targets[0].position_deltas[1] == (Vec3){ 0, 0, 5 });
    assert(record.data.targets[0].normal_deltas.len == 0);
    assert(record.data.targets[0].name == "smile_1");
    assets.remove_geometry(geometry);
}

fn void test_material_lifecycle_and_key() @test {
    AssetStore assets = make_store();
    defer asset::destroy_asset_store(&assets);
    MaterialId red = assets.add_material(material::basic({ .color = { 1, 0, 0, 1 } }), "mat/red")!!;
    assert(assets.materials.is_live(red));
    assert(assets.material(red).header.revision == 1);
    MaterialId found = assets.find_material("mat/red")!!;
    assert(found.index == red.index && found.generation == red.generation);

    assets.material(red).data.basic.color = { 0, 1, 0, 1 };
    assets.mark_material_dirty(red);
    assert(assets.material(red).header.revision == 2);
    assert(assets.material(red).data.basic.color.g == 1);

    assets.remove_material(red);
    assert(!assets.materials.is_live(red));
    if (catch excuse = assets.find_material("mat/red")) {
        assert(excuse == NOT_FOUND);
    } else {
        assert(false, "key survived removal");
    }
}

fn void test_material_duplicate_key_and_capacity() @test {
    AssetStore assets = make_store();
    defer asset::destroy_asset_store(&assets);
    Material white = material::basic({ .color = { 1, 1, 1, 1 } });
    assets.add_material(white, "mat/a")!!;
    if (catch excuse = assets.add_material(white, "mat/a")) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "duplicate key accepted");
    }
    assets.add_material(white)!!;
    if (catch excuse = assets.add_material(white)) {
        assert(excuse == c3d::CAPACITY_EXCEEDED);
    } else {
        assert(false, "pool overfilled");
    }
}

fn void test_add_texture_empty_forces_storage_and_defaults() @test {
    AssetStore assets = make_store();
    defer asset::destroy_asset_store(&assets);
    TextureId noise = assets.add_texture_empty({ .width = 64, .height = 64, .format = PixelFormat.RGBA8_UNORM }, "noise")!!;
    TextureAsset* record = assets.texture(noise);
    assert(record.source_kind == TextureSourceKind.EMPTY);
    assert(record.desc.storage && record.desc.mip_levels == 1 && record.desc.layers == 1);
    assert(record.pixels.len == 0 && record.supplied_mips.len == 0);
    assert(assets.find_texture("noise")!!.index == noise.index);

    TextureId mipped = assets.add_texture_empty({ .width = 64, .height = 64, .format = PixelFormat.RGBA16_FLOAT, .mip_levels = 3 })!!;
    assert(assets.texture(mipped).desc.mip_levels == 3);
    assets.remove_texture(mipped);
    assert(!assets.textures.is_live(mipped));
}

fn void test_add_texture_empty_rejects_generated_mips_and_zero_extent() @test {
    AssetStore assets = make_store();
    defer asset::destroy_asset_store(&assets);
    if (catch excuse = assets.add_texture_empty({ .width = 64, .height = 64, .format = PixelFormat.RGBA8_UNORM, .generate_mips = true })) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "an empty texture with generated mips was accepted");
    }
    if (catch excuse = assets.add_texture_empty({ .width = 0, .height = 64, .format = PixelFormat.RGBA8_UNORM })) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "an empty texture with zero width was accepted");
    }
}

fn void test_storage_rejects_compressed_and_srgb_formats() @test {
    AssetStore assets = make_store();
    defer asset::destroy_asset_store(&assets);
    char[16] pixels;
    PixelFormat[2] rejected = { PixelFormat.BC7_UNORM, PixelFormat.RGBA8_SRGB };
    foreach (format : rejected) {
        TextureDesc desc = { .width = 4, .height = 4, .layers = 1, .mip_levels = 1, .format = format, .storage = true };
        if (catch excuse = assets.add_texture(desc, pixels[..])) {
            assert(excuse == c3d::INVALID_ARGUMENT);
        } else {
            assert(false, "a storage texture with a compressed or sRGB format was accepted");
        }
        if (catch excuse = assets.add_texture_empty(desc)) {
            assert(excuse == c3d::INVALID_ARGUMENT);
        } else {
            assert(false, "an empty texture with a compressed or sRGB format was accepted");
        }
    }
    TextureDesc accepted = { .width = 4, .height = 4, .layers = 1, .mip_levels = 1, .format = PixelFormat.RGBA8_UNORM, .storage = true };
    assets.add_texture(accepted, pixels[..])!!;
}

fn ShaderDesc make_shader_desc(char[] fragment, char[] shaded = {}, char[] depth = {}, char[] gbuffer = {}) @local {
    return {
        .fragment = fragment,
        .gbuffer = gbuffer,
        .vertex = { .shaded = shaded, .depth = depth },
        .param_block_size = 32,
    };
}

fn void test_add_shader_copies_stages() @test {
    AssetStore store = make_store();
    defer asset::destroy_asset_store(&store);
    char[4] fragment = { 1, 2, 3, 4 };
    char[4] shaded = { 5, 6, 7, 8 };
    char[4] depth = { 9, 10, 11, 12 };
    ShaderDesc desc = make_shader_desc(fragment[..], shaded[..], depth[..]);
    ShaderId id = store.add_shader(&desc, "pulse")!!;
    fragment[0] = 0;
    shaded[0] = 0;
    depth[0] = 0;

    ShaderAsset* record = store.shader(id);
    assert(record.header.revision == 1);
    assert(record.desc.fragment[0] == 1 && record.desc.vertex.shaded[0] == 5 && record.desc.vertex.depth[0] == 9);
    assert(record.desc.param_block_size == 32);
    assert(record.desc.fragment.ptr != &fragment[0]);
    assert(store.find_shader("pulse")!!.index == id.index);
}

fn void test_add_shader_rejects_half_vertex_pair() @test {
    AssetStore store = make_store();
    defer asset::destroy_asset_store(&store);
    char[4] bytes = { 1, 2, 3, 4 };

    ShaderDesc shaded_only = make_shader_desc(bytes[..], shaded: bytes[..]);
    if (catch excuse = store.add_shader(&shaded_only)) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "a shaded vertex form without its depth form was accepted");
    }

    ShaderDesc depth_only = make_shader_desc(bytes[..], depth: bytes[..]);
    if (catch excuse = store.add_shader(&depth_only)) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "a depth vertex form without its shaded form was accepted");
    }

    ShaderDesc no_fragment = make_shader_desc({});
    if (catch excuse = store.add_shader(&no_fragment)) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "an empty fragment stage was accepted");
    }
    ShaderDesc valid = make_shader_desc(bytes[..]);
    assert(store.add_shader(&valid)!!.index == 0);
}

fn void test_replace_shader_bumps_revision_and_copies() @test {
    AssetStore store = make_store();
    defer asset::destroy_asset_store(&store);
    char[4] first = { 1, 2, 3, 4 };
    ShaderDesc desc = make_shader_desc(first[..]);
    ShaderId id = store.add_shader(&desc)!!;

    char[8] second = { 8, 7, 6, 5, 4, 3, 2, 1 };
    ShaderDesc replacement = make_shader_desc(second[..]);
    replacement.param_block_size = 16;
    store.replace_shader(id, &replacement)!!;
    second[0] = 0;

    ShaderAsset* record = store.shader(id);
    assert(record.header.revision == 2);
    assert(record.desc.fragment.len == 8 && record.desc.fragment[0] == 8);
    assert(record.desc.param_block_size == 16);
    assert(record.desc.vertex.shaded.len == 0 && record.desc.vertex.depth.len == 0);

    ShaderDesc invalid = make_shader_desc(second[..], shaded: second[..]);
    if (catch excuse = store.replace_shader(id, &invalid)) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "an invalid replacement was accepted");
    }
    assert(record.header.revision == 2 && record.desc.fragment.len == 8);
}

fn void test_shader_gbuffer_stage_is_copied_and_replaceable() @test {
    AssetStore store = make_store();
    defer asset::destroy_asset_store(&store);
    char[4] fragment = { 1, 2, 3, 4 };
    char[3] gbuffer = { 9, 8, 7 };
    ShaderDesc desc = make_shader_desc(fragment[..], gbuffer: gbuffer[..]);
    ShaderId id = store.add_shader(&desc)!!;
    gbuffer[0] = 0;

    ShaderAsset* record = store.shader(id);
    assert(record.desc.gbuffer.ptr != &gbuffer[0]);
    assert(record.desc.gbuffer.len == 3 && record.desc.gbuffer[0] == 9 && record.desc.gbuffer[2] == 7);

    ShaderDesc forward_only = make_shader_desc(fragment[..]);
    store.replace_shader(id, &forward_only)!!;
    assert(record.header.revision == 2);
    assert(record.desc.gbuffer.len == 0 && record.desc.fragment.len == 4);

    store.remove_shader(id);
    assert(!store.shaders.is_live(id));
}

fn void test_remove_shader_makes_id_stale() @test {
    AssetStore store = make_store();
    defer asset::destroy_asset_store(&store);
    char[4] bytes = { 1, 2, 3, 4 };
    ShaderDesc desc = make_shader_desc(bytes[..]);
    ShaderId id = store.add_shader(&desc, "tint")!!;
    store.remove_shader(id);
    assert(!store.shaders.is_live(id));
    if (catch excuse = store.find_shader("tint")) {
        assert(excuse == NOT_FOUND);
    } else {
        assert(false, "the key of a removed shader still resolves");
    }
}

fn void test_add_compute_shader_copies_stage() @test {
    AssetStore store = make_store();
    defer asset::destroy_asset_store(&store);
    char[4] compute = { 1, 2, 3, 4 };
    ComputeShaderDesc desc = { .compute = compute[..] };
    ComputeShaderId id = store.add_compute_shader(&desc, "particles")!!;
    compute[0] = 0;

    ComputeShaderAsset* record = store.compute_shader(id);
    assert(record.header.revision == 1);
    assert(record.desc.compute[0] == 1 && record.desc.compute.ptr != &compute[0]);
    assert(store.find_compute_shader("particles")!!.index == id.index);
    if (catch excuse = store.find_shader("particles")) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "a compute shader key resolved as a graphics shader");
    }
}

fn void test_add_compute_shader_rejects_empty_stage() @test {
    AssetStore store = make_store();
    defer asset::destroy_asset_store(&store);
    ComputeShaderDesc empty;
    if (catch excuse = store.add_compute_shader(&empty)) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "an empty compute stage was accepted");
    }
}

fn void test_replace_compute_shader_bumps_revision_and_copies() @test {
    AssetStore store = make_store();
    defer asset::destroy_asset_store(&store);
    char[4] first = { 1, 1, 1, 1 };
    char[8] second = { 2, 2, 2, 2, 2, 2, 2, 2 };
    ComputeShaderDesc desc = { .compute = first[..] };
    ComputeShaderId id = store.add_compute_shader(&desc)!!;

    ComputeShaderDesc replacement = { .compute = second[..] };
    store.replace_compute_shader(id, &replacement)!!;
    second[0] = 0;
    ComputeShaderAsset* record = store.compute_shader(id);
    assert(record.header.revision == 2);
    assert(record.desc.compute.len == 8 && record.desc.compute[0] == 2);

    ComputeShaderDesc empty;
    if (catch excuse = store.replace_compute_shader(id, &empty)) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "an empty replacement was accepted");
    }
    assert(record.header.revision == 2 && record.desc.compute.len == 8);
}

fn void test_remove_compute_shader_makes_id_stale() @test {
    AssetStore store = make_store();
    defer asset::destroy_asset_store(&store);
    char[4] compute = { 1, 2, 3, 4 };
    ComputeShaderDesc desc = { .compute = compute[..] };
    ComputeShaderId id = store.add_compute_shader(&desc, "particles")!!;
    store.remove_compute_shader(id);
    assert(!store.compute_shaders.is_live(id));
    if (catch excuse = store.find_compute_shader("particles")) {
        assert(excuse == NOT_FOUND);
    } else {
        assert(false, "the key of a removed compute shader still resolves");
    }
}

struct TestParams @local {
    float[<4>] color;
    float[<4>] motion;
}

fn void test_add_custom_material_copies_param_block() @test {
    AssetStore store = make_store();
    defer asset::destroy_asset_store(&store);
    TestParams params = { .color = { 1, 2, 3, 4 }, .motion = { 5, 6, 7, 8 } };
    char[] bytes = ((char*)&params)[:TestParams::size];
    MaterialId id = store.add_material(material::custom({ .index = 1, .generation = 1 }, bytes))!!;
    params.color.x = 0;

    Material* stored = &store.material(id).data;
    assert(stored.kind == MaterialKind.CUSTOM);
    assert(stored.custom.param_block.len == TestParams::size);
    assert(stored.custom.param_block.ptr != bytes.ptr);
    assert(((TestParams*)stored.custom.param_block.ptr).color.x == 1);
    assert(stored.custom.slots[0].transform.scale == (Vec2){ 1, 1 });
}

fn void test_set_custom_params_resizes_and_bumps_revision() @test {
    AssetStore store = make_store();
    defer asset::destroy_asset_store(&store);
    MaterialId id = store.add_material(material::custom({ .index = 1, .generation = 1 }))!!;
    assert(store.material(id).data.custom.param_block.len == 0);

    char[8] bytes = { 1, 2, 3, 4, 5, 6, 7, 8 };
    store.set_custom_params(id, bytes[..])!!;
    Material* stored = &store.material(id).data;
    assert(store.material(id).header.revision == 2);
    assert(stored.custom.param_block.len == 8 && stored.custom.param_block[7] == 8);

    char[4] shorter = { 9, 9, 9, 9 };
    store.set_custom_params(id, shorter[..])!!;
    assert(store.material(id).header.revision == 3);
    assert(stored.custom.param_block.len == 4 && stored.custom.param_block[3] == 9);

    store.set_custom_params(id, {})!!;
    assert(stored.custom.param_block.len == 0);
}

fn void test_set_custom_params_rejects_other_kinds() @test {
    AssetStore store = make_store();
    defer asset::destroy_asset_store(&store);
    MaterialId id = store.add_material(material::basic())!!;
    char[4] bytes = { 1, 2, 3, 4 };
    if (catch excuse = store.set_custom_params(id, bytes[..])) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "a basic material accepted a custom payload");
    }
    assert(store.material(id).header.revision == 1);
}

fn void test_typed_custom_params_round_trip() @test {
    AssetStore store = make_store();
    defer asset::destroy_asset_store(&store);
    MaterialId id = store.add_material(material::custom({ .index = 1, .generation = 1 }))!!;
    TestParams params = { .color = { 1, 2, 3, 4 }, .motion = { 5, 6, 7, 8 } };
    store.@set_custom_params(id, params)!!;

    TestParams* live = store.@custom_params(id, TestParams);
    assert(live.motion == (float[<4>]){ 5, 6, 7, 8 });
    live.color.y = 42;
    assert(((TestParams*)store.material(id).data.custom.param_block.ptr).color.y == 42);
    assert(store.material(id).header.revision == 2);
}
