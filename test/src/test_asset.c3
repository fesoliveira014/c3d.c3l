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
    assert(!checker.desc.generate_mips);
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
