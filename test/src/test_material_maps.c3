module c3d::test::maps;

import c3d;
import c3d::asset;
import c3d::material;
import c3d::render @public;
import c3d::shader;
import gpu;
import std::math;

fn TextureBinding texture_binding(uint texture_index, uint sampler_index, bool present) @local {
    return {
        .texture_index = (gpu::TextureIndex)texture_index,
        .sampler_index = (gpu::SamplerIndex)sampler_index,
        .present       = present,
    };
}

fn TextureSlot map_slot(
    uint uv_set,
    Vec2 offset,
    Vec2 scale,
    float rotation,
) @local {
    return material::texture_slot(
        uv_set: uv_set,
        transform: { .offset = offset, .scale = scale, .rotation = rotation },
    );
}

fn void assert_map_transform(TextureMapGpu map, Vec2 expected_offset, Vec4 expected_linear) @local {
    assert((map.uv_offset - expected_offset).length() < 0.0001f);
    assert((map.uv_linear - expected_linear).length() < 0.0001f);
}

fn void test_material_packing_preserves_and_clears_additive_mode() @test {
    char[render::MATERIAL_STRIDE] storage @align(16);
    char[] bytes = storage[..];
    Material[5] materials = {
        material::basic(),
        material::standard(),
        material::toon(),
        material::physical(),
        { .kind = MaterialKind.CUSTOM, .common = material::MATERIAL_COMMON_DEFAULT },
    };

    foreach (&material_data : materials) {
        material_data.common.alpha_mode = AlphaMode.BLEND;
        material_data.common.blend_mode = BlendMode.ADDITIVE;
        material_data.common.double_sided = true;
        render::write_material_block(bytes, material_data, {});
        uint flags = ((BasicMaterialGpu*)bytes.ptr).flags;
        assert((flags & shader::MATERIAL_ALPHA_BLEND) != 0);
        assert((flags & shader::MATERIAL_BLEND_ADDITIVE) != 0);
        assert((flags & shader::MATERIAL_DOUBLE_SIDED) != 0);

        material_data.common.blend_mode = BlendMode.PREMULTIPLIED_ALPHA;
        render::write_material_block(bytes, material_data, {});
        flags = ((BasicMaterialGpu*)bytes.ptr).flags;
        assert((flags & shader::MATERIAL_ALPHA_BLEND) != 0);
        assert((flags & shader::MATERIAL_BLEND_ADDITIVE) == 0);

        material_data.common.blend_mode = BlendMode.ADDITIVE;
        material_data.common.alpha_mode = AlphaMode.OPAQUE;
        render::write_material_block(bytes, material_data, {});
        flags = ((BasicMaterialGpu*)bytes.ptr).flags;
        assert((flags & shader::MATERIAL_ALPHA_BLEND) == 0);
        assert((flags & shader::MATERIAL_BLEND_ADDITIVE) == 0);

        material_data.common.alpha_mode = AlphaMode.MASK;
        render::write_material_block(bytes, material_data, {});
        flags = ((BasicMaterialGpu*)bytes.ptr).flags;
        assert((flags & shader::MATERIAL_ALPHA_MASK) != 0);
        assert((flags & shader::MATERIAL_BLEND_ADDITIVE) == 0);
    }
}

fn void test_standard_packing_keeps_all_map_bindings() @test {
    char[render::MATERIAL_STRIDE] storage @align(16);
    char[] bytes = storage[..];

    StandardParams params = material::STANDARD_PARAMS_DEFAULT;
    params.base_color = { 0.15f, 0.3f, 0.55f, 0.8f };
    params.metallic = 0.2f;
    params.roughness = 0.7f;
    params.emissive = { 0.4f, 0.8f, 1.2f };
    params.emissive_strength = 2.5f;
    params.normal_scale = 0.65f;
    params.occlusion_strength = 0.45f;
    params.base_color_map = map_slot(
        uv_set: 0,
        offset: {},
        scale: { 1, 1 },
        rotation: 0,
    );
    params.metallic_roughness_map = map_slot(
        uv_set: 1,
        offset: {},
        scale: { 1, 1 },
        rotation: 0,
    );
    params.normal_map = map_slot(
        uv_set: 1,
        offset: {},
        scale: { 1, 1 },
        rotation: 0,
    );
    params.occlusion_map = map_slot(
        uv_set: 0,
        offset: {},
        scale: { 1, 1 },
        rotation: 0,
    );
    params.emissive_map = map_slot(
        uv_set: 1,
        offset: {},
        scale: { 1, 1 },
        rotation: 0,
    );

    Material material = material::standard(params);
    MaterialBindings bindings = {
        .base_color = texture_binding(11, 21, true),
        .metallic_roughness = texture_binding(12, 22, false),
        .normal = texture_binding(13, 23, true),
        .occlusion = texture_binding(14, 24, false),
        .emissive = texture_binding(15, 25, true),
    };
    render::write_material_block(bytes, &material, bindings);

    StandardMaterialGpu* packed = (StandardMaterialGpu*)bytes.ptr;
    assert(packed.base_color == params.base_color);
    assert(packed.metallic == params.metallic && packed.roughness == params.roughness);
    assert(packed.emissive_strength == (Vec4){ 0.4f, 0.8f, 1.2f, 2.5f });
    assert(packed.normal_scale == params.normal_scale);
    assert(packed.occlusion_strength == params.occlusion_strength);
    assert(packed.map_flags == 0x2d5);
    assert(packed.base_color_map.texture_index == (gpu::TextureIndex)11);
    assert(packed.base_color_map.sampler_index == (gpu::SamplerIndex)21);
    assert(packed.metallic_roughness_map.texture_index == (gpu::TextureIndex)12);
    assert(packed.metallic_roughness_map.sampler_index == (gpu::SamplerIndex)22);
    assert(packed.normal_map.texture_index == (gpu::TextureIndex)13);
    assert(packed.normal_map.sampler_index == (gpu::SamplerIndex)23);
    assert(packed.occlusion_map.texture_index == (gpu::TextureIndex)14);
    assert(packed.occlusion_map.sampler_index == (gpu::SamplerIndex)24);
    assert(packed.emissive_map.texture_index == (gpu::TextureIndex)15);
    assert(packed.emissive_map.sampler_index == (gpu::SamplerIndex)25);
}

fn void test_standard_packing_keeps_each_map_transform() @test {
    char[render::MATERIAL_STRIDE] storage @align(16);
    char[] bytes = storage[..];

    StandardParams params = material::STANDARD_PARAMS_DEFAULT;
    params.base_color_map = map_slot(
        uv_set: 0,
        offset: { 0.25f, -0.5f },
        scale: { 2, 3 },
        rotation: 0,
    );
    params.metallic_roughness_map = map_slot(
        uv_set: 1,
        offset: { -1.5f, 2.25f },
        scale: { 0.5f, 1.25f },
        rotation: math::PI / 2,
    );
    params.normal_map = map_slot(
        uv_set: 0,
        offset: { 3.75f, -4.5f },
        scale: { 1.5f, 0.75f },
        rotation: math::PI,
    );
    params.occlusion_map = map_slot(
        uv_set: 1,
        offset: { -5, 6 },
        scale: { 2.25f, 0.375f },
        rotation: -math::PI / 2,
    );
    params.emissive_map = map_slot(
        uv_set: 0,
        offset: { 7.5f, -8.25f },
        scale: { 0.625f, 1.75f },
        rotation: math::PI / 2,
    );

    Material material = material::standard(params);
    render::write_material_block(bytes, &material, {});

    StandardMaterialGpu* packed = (StandardMaterialGpu*)bytes.ptr;
    assert_map_transform(
        map: packed.base_color_map,
        expected_offset: { 0.25f, -0.5f },
        expected_linear: { 2, 0, 0, 3 },
    );
    assert_map_transform(
        map: packed.metallic_roughness_map,
        expected_offset: { -1.5f, 2.25f },
        expected_linear: { 0, -1.25f, 0.5f, 0 },
    );
    assert_map_transform(
        map: packed.normal_map,
        expected_offset: { 3.75f, -4.5f },
        expected_linear: { -1.5f, 0, 0, -0.75f },
    );
    assert_map_transform(
        map: packed.occlusion_map,
        expected_offset: { -5, 6 },
        expected_linear: { 0, 0.375f, -2.25f, 0 },
    );
    assert_map_transform(
        map: packed.emissive_map,
        expected_offset: { 7.5f, -8.25f },
        expected_linear: { 0, -1.75f, 0.625f, 0 },
    );
}

fn void test_standard_packing_clears_absent_map_flags() @test {
    char[render::MATERIAL_STRIDE] storage @align(16);
    char[] bytes = storage[..];
    bytes[..] = 0x7f;

    StandardParams params = material::STANDARD_PARAMS_DEFAULT;
    params.base_color = { 0.2f, 0.4f, 0.6f, 0.8f };
    params.emissive = { 0.3f, 0.5f, 0.7f };
    params.emissive_strength = 1.75f;
    Material material = material::standard(params);
    render::write_material_block(bytes, &material, {});

    StandardMaterialGpu* packed = (StandardMaterialGpu*)bytes.ptr;
    assert(packed.base_color == params.base_color);
    assert(packed.emissive_strength == (Vec4){ 0.3f, 0.5f, 0.7f, 1.75f });
    assert(packed.map_flags == 0);
}

fn void test_normal_bindings_track_semantics_and_content_at_a_stable_index() @test {
    TextureBinding first = texture_binding(17, 4, true);
    first.texture_binding_revision = 3;
    first.texture_content_revision = 7;
    first.semantic = TextureSemantic.NORMAL_RGB;
    TextureBinding changed = first;
    changed.semantic = TextureSemantic.NORMAL_RG;

    assert(!render::texture_binding_matches(first, changed));

    changed = first;
    changed.texture_content_revision++;

    assert(!render::texture_binding_matches(first, changed));
    assert(render::texture_binding_matches(first, first));
}

fn void test_base_and_coat_normal_encoding_flags_are_independent() @test {
    char[render::MATERIAL_STRIDE] storage @align(16);
    PhysicalParams params = material::PHYSICAL_PARAMS_DEFAULT;
    params.clearcoat = 1;
    params.standard.normal_map.uv_set = 1;
    params.clearcoat_normal_map.uv_set = 1;
    Material material_data = material::physical(params);

    for (uint base = 0; base < 2; base++) {
        for (uint coat = 0; coat < 2; coat++) {
            MaterialBindings bindings = {
                .normal = texture_binding(17, 4, true),
                .clearcoat_normal = texture_binding(18, 4, true),
            };
            bindings.normal.semantic = base ? TextureSemantic.NORMAL_RG : TextureSemantic.NORMAL_RGB;
            bindings.clearcoat_normal.semantic = coat ? TextureSemantic.NORMAL_RG : TextureSemantic.NORMAL_RGB;

            render::write_material_block(storage[..], &material_data, bindings);

            PhysicalMaterialGpu* packed = (PhysicalMaterialGpu*)&storage;

            assert(((packed.standard.map_flags & shader::MATERIAL_MAP_NORMAL_RG) != 0) == (base != 0));
            assert(((packed.map_flags & shader::PHYSICAL_MAP_CLEARCOAT_NORMAL_RG) != 0) == (coat != 0));
            assert((packed.standard.map_flags & (shader::MATERIAL_MAP_NORMAL << shader::MATERIAL_MAP_UV1_SHIFT)) != 0);
            assert((packed.map_flags & (shader::PHYSICAL_MAP_CLEARCOAT_NORMAL << shader::MATERIAL_MAP_UV1_SHIFT)) != 0);
            assert(packed.standard.normal_map.texture_index == (gpu::TextureIndex)17);
            assert(packed.clearcoat_normal_map.texture_index == (gpu::TextureIndex)18);
        }
    }
}

fn void test_normal_binding_uses_pending_resource_metadata_before_a_newer_cpu_revision() @test {
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    char[4] pixels = { 128, 128, 255, 255 };
    material::TextureDesc desc = material::texture_2d_desc(1, 1, PixelFormat.RGBA8_UNORM);
    desc.semantic = TextureSemantic.NORMAL_RGB;

    TextureId texture = assets.add_texture(desc, pixels[..])!!;

    TextureRes mirror = { .asset = texture, .revision = 1, .semantic = TextureSemantic.NORMAL_RGB };
    Renderer renderer = { .assets = &assets };
    renderer.pending_texture_uploads.init(mem);
    defer renderer.pending_texture_uploads.free();

    TextureBinding content = render::texture_binding_content(&renderer, texture, &mirror);

    assert(content.texture_content_revision == 1 && content.semantic == TextureSemantic.NORMAL_RGB);

    desc.semantic = TextureSemantic.NORMAL_RG;

    assets.replace_texture(texture, desc, pixels[..])!!;

    renderer.pending_texture_uploads.push({
        .asset = texture, .revision = 2, .semantic = TextureSemantic.NORMAL_RG,
    });
    desc.semantic = TextureSemantic.NORMAL_RGB;

    assets.replace_texture(texture, desc, pixels[..])!!;

    assert(assets.texture(texture).header.revision == 3);

    content = render::texture_binding_content(&renderer, texture, &mirror);

    assert(content.texture_content_revision == 2 && content.semantic == TextureSemantic.NORMAL_RG);
    renderer.pending_texture_uploads.push({
        .asset = texture, .revision = 3, .semantic = TextureSemantic.NORMAL_RGB,
    });
    content = render::texture_binding_content(&renderer, texture, &mirror);

    assert(content.texture_content_revision == 3 && content.semantic == TextureSemantic.NORMAL_RGB);
    renderer.pending_texture_uploads.clear();
    content = render::texture_binding_content(&renderer, texture, &mirror);

    assert(content.texture_content_revision == 1 && content.semantic == TextureSemantic.NORMAL_RGB);
}

fn void test_target_base_and_coat_normal_bindings_pack_rgb() @test {
    char[render::MATERIAL_STRIDE] storage @align(16);
    PhysicalParams params = material::PHYSICAL_PARAMS_DEFAULT;
    params.clearcoat = 1;
    Material material_data = material::physical(params);
    MaterialBindings bindings = {
        .normal = texture_binding(17, 4, true),
        .clearcoat_normal = texture_binding(18, 4, true),
    };
    bindings.normal.target = { .index = 1, .generation = 1 };
    bindings.clearcoat_normal.target = { .index = 2, .generation = 1 };

    render::write_material_block(storage[..], &material_data, bindings);

    PhysicalMaterialGpu* packed = (PhysicalMaterialGpu*)&storage;

    assert((packed.standard.map_flags & shader::MATERIAL_MAP_NORMAL_RG) == 0);
    assert((packed.map_flags & shader::PHYSICAL_MAP_CLEARCOAT_NORMAL_RG) == 0);
}

fn void test_basic_packing_uses_base_color_binding_after_standard() @test {
    char[render::MATERIAL_STRIDE] storage @align(16);
    char[] bytes = storage[..];

    Material standard = material::standard();
    render::write_material_block(
        block: bytes,
        material: &standard,
        bindings: {
            .base_color = texture_binding(31, 41, true),
            .metallic_roughness = texture_binding(32, 42, true),
            .normal = texture_binding(33, 43, true),
            .occlusion = texture_binding(34, 44, true),
            .emissive = texture_binding(35, 45, true),
        },
    );

    BasicParams params = {
        .color = { 0.1f, 0.25f, 0.5f, 0.75f },
        .map = map_slot(
            uv_set: 1,
            offset: { 1.5f, -2.5f },
            scale: { 0.5f, 1.25f },
            rotation: math::PI / 2,
        ),
    };
    Material material = material::basic(params);
    render::write_material_block(
        block: bytes,
        material: &material,
        bindings: { .base_color = texture_binding(37, 47, true) },
    );

    BasicMaterialGpu* packed = (BasicMaterialGpu*)bytes.ptr;
    assert(packed.color == params.color);
    assert(packed.map.texture_index == (gpu::TextureIndex)37);
    assert(packed.map.sampler_index == (gpu::SamplerIndex)47);
    assert(packed.map_flags == 0x21);
    assert_map_transform(
        map: packed.map,
        expected_offset: { 1.5f, -2.5f },
        expected_linear: { 0, -1.25f, 0.5f, 0 },
    );

    material = material::basic({ .color = { 1, 1, 1, 1 } });
    render::write_material_block(bytes, &material, {});
    assert(packed.map_flags == 0);
}
