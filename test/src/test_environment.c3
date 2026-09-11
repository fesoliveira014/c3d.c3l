module c3d::test::environment;

import c3d;
import c3d::asset;
import c3d::light;
import c3d::material;
import std::math;

fn AssetStore environment_store(uint capacity = 2) @local {
    AssetStoreDesc desc = asset::default_asset_store_desc();
    desc.max_geometries = 1;
    desc.max_textures = asset::BUILTIN_TEXTURE_COUNT + 8;
    desc.max_materials = 1;
    desc.max_samplers = asset::BUILTIN_SAMPLER_COUNT;
    desc.max_environments = capacity;
    return asset::create_asset_store(mem, desc);
}

fn TextureId hdr_source(AssetStore* assets, String key = "") @local {
    float[8] pixels = { 1, 2, 4, 1, 2, 4, 8, 1 };
    TextureDesc desc = material::texture_2d_desc(
        width: 2,
        height: 1,
        format: RGBA32_FLOAT,
        debug_name: "environment_source",
    );
    return assets.add_texture(desc, ((char*)&pixels)[:pixels.len * float::size], key)!!;
}

fn void test_environment_records_share_sources_without_owning_them() @test {
    AssetStore assets = environment_store();
    defer asset::destroy_asset_store(&assets);

    TextureId source = hdr_source(&assets, "source");
    EnvironmentId first = assets.add_environment(light::texture_environment(source), "first")!!;
    EnvironmentId second = assets.add_environment(light::texture_environment(source), "second")!!;
    uint first_revision = assets.environment(first).header.revision;
    uint texture_revision = assets.texture(source).header.revision;
    uint second_revision = assets.environment(second).header.revision;

    assets.environment(first).desc.settings.specular_size = 512;
    assets.mark_environment_dirty(first);
    assert(assets.environment(first).header.revision == first_revision + 1);
    assert(assets.texture(source).header.revision == texture_revision);
    assert(assets.environment(second).header.revision == second_revision);
    assert(assets.environment(second).desc.settings.specular_size == 256);

    assets.remove_environment(first);
    assert(assets.textures.is_live(source));
    assert(assets.texture(source).pixels.len == 8 * float::size);
    assert(assets.environments.is_live(second));
    EnvironmentId replacement = assets.add_environment(light::solid_environment({ 2, 1, 0.5f }), "first")!!;
    assert(replacement.index == first.index);
    assert(replacement.generation != first.generation);
    assert(!assets.environments.is_live(first));

    assets.remove_texture(source);
    assert(assets.environments.is_live(second));
    if (catch excuse = assets.validate_environment(assets.environment(second).desc)) {
        assert(excuse == c3d::INVALID_ID);
    } else {
        assert(false, "a removed source was accepted");
    }
    assets.validate_environment(assets.environment(replacement).desc)!!;
}

fn void test_environment_registration_failures_preserve_capacity_and_keys() @test {
    AssetStore assets = environment_store(1);
    defer asset::destroy_asset_store(&assets);

    TextureId source = hdr_source(&assets, "source");
    EnvironmentDesc desc = light::texture_environment(source);
    if (catch excuse = assets.add_environment(desc, "source")) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "a texture key was reused by an environment");
    }
    if (catch excuse = assets.add_environment(light::texture_environment({}), "invalid")) {
        assert(excuse == c3d::INVALID_ID);
    } else {
        assert(false, "a missing texture source was accepted");
    }

    EnvironmentId environment = assets.add_environment(desc, "environment")!!;
    AssetRef found = assets.find("environment")!!;
    assert(found.kind == AssetKind.ENVIRONMENT);
    EnvironmentId typed = assets.find_environment("environment")!!;
    assert(typed.index == environment.index && typed.generation == environment.generation);
    if (catch excuse = assets.find_environment("source")) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "a texture key resolved as an environment");
    }
    if (catch excuse = assets.add_environment(desc, "overflow")) {
        assert(excuse == c3d::CAPACITY_EXCEEDED);
    } else {
        assert(false, "a full environment pool accepted another record");
    }

    assets.remove_environment(environment);
    foreach (key : (String[3]){ "environment", "invalid", "overflow" }) {
        if (catch excuse = assets.find(key)) {
            assert(excuse == NOT_FOUND);
        } else {
            assert(false, "a removed or failed insertion retained its key");
        }
    }
    assets.add_environment(desc, "overflow")!!;
}

fn void test_environment_validation_preserves_source_roles_and_cpu_release() @test {
    AssetStore assets = environment_store();
    defer asset::destroy_asset_store(&assets);

    TextureId source = hdr_source(&assets);
    EnvironmentDesc equirectangular = light::texture_environment(
        source,
        { .conversion_size = 37, .specular_size = 33 },
    );
    assets.validate_environment(equirectangular)!!;
    assets.release_texture_cpu(source);
    assets.validate_environment(equirectangular)!!;

    char[24] cube_pixels;
    TextureDesc cube_desc = material::texture_cube_desc(1, RGBA8_UNORM);
    TextureId cube = assets.add_texture(cube_desc, cube_pixels[..])!!;
    EnvironmentDesc native_cube = light::texture_environment(cube, { .conversion_size = 0, .specular_size = 32 });
    assets.validate_environment(native_cube)!!;
    assets.texture(cube).desc.layers = 5;
    if (catch excuse = assets.validate_environment(native_cube)) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "a five-layer cube was accepted");
    }
    assets.texture(cube).desc.layers = 6;
    assets.texture(cube).desc.width = 2;
    if (catch excuse = assets.validate_environment(native_cube)) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "a nonsquare cube was accepted");
    }
    assets.texture(cube).desc.width = 0;
    if (catch excuse = assets.validate_environment(native_cube)) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "a zero-extent cube was accepted");
    }
    assets.texture(cube).desc.width = 1;
    assets.texture(cube).desc.depth = 1;
    assets.texture(cube).desc.layers = 5;
    if (catch excuse = assets.validate_environment(native_cube)) {
        assert(excuse == c3d::UNSUPPORTED);
    } else {
        assert(false, "a depth source was accepted");
    }
    assets.texture(cube).desc.depth = 0;
    assets.texture(cube).desc.layers = 6;
    assets.texture(source).desc.layers = 2;
    if (catch excuse = assets.validate_environment(equirectangular)) {
        assert(excuse == c3d::UNSUPPORTED);
    } else {
        assert(false, "an array source was accepted");
    }
    assets.texture(source).desc.layers = 1;
    assets.texture(cube).desc.format = BC6H_UFLOAT;
    if (catch excuse = assets.validate_environment(native_cube)) {
        assert(excuse == c3d::UNSUPPORTED);
    } else {
        assert(false, "a compressed cube was accepted");
    }

    assets.texture(source).desc.format = RGBA8_UNORM;
    if (catch excuse = assets.validate_environment(equirectangular)) {
        assert(excuse == c3d::UNSUPPORTED);
    } else {
        assert(false, "an unsupported equirectangular format was accepted");
    }

    EnvironmentDesc solid = light::solid_environment({ 4, 2, 1 }, { .conversion_size = 0, .specular_size = 32 });
    solid.source = { .index = 200, .generation = 10 };
    assets.validate_environment(solid)!!;
}

fn void test_environment_validation_rejects_invalid_processing_data() @test {
    AssetStore assets = environment_store(1);
    defer asset::destroy_asset_store(&assets);

    TextureId source = hdr_source(&assets);
    EnvironmentDesc equirectangular = light::texture_environment(source);
    equirectangular.settings.conversion_size = 0;
    if (catch excuse = assets.validate_environment(equirectangular)) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "a zero-sized conversion was accepted");
    }

    EnvironmentDesc solid = light::solid_environment({ 1, 1, 1 });
    solid.settings.specular_size = 31;
    if (catch excuse = assets.add_environment(solid, "too_small")) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "a size without six mip levels was accepted");
    }
    solid.settings.specular_size = 32;
    solid.solid_color.x = -1;
    if (catch excuse = assets.add_environment(solid, "negative")) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "a negative solid radiance was accepted");
    }
    foreach (invalid : (float[2]){ bitcast((uint)0x7f800000, float), bitcast((uint)0x7fc00000, float) }) {
        solid.solid_color.x = invalid;
        if (catch excuse = assets.add_environment(solid, "non_finite")) {
            assert(excuse == c3d::INVALID_ARGUMENT);
        } else {
            assert(false, "a non-finite solid radiance was accepted");
        }
    }
    solid.solid_color = { 1, 2, 3 };
    assets.add_environment(solid, "valid")!!;
}
