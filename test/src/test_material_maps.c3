module c3d::test::maps;

import c3d;
import c3d::material;
import c3d::render;
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

fn void assert_uv_rows(
    Vec4 actual_row0,
    Vec4 actual_row1,
    Vec4 expected_row0,
    Vec4 expected_row1,
) @local {
    assert(math::abs(actual_row0.x - expected_row0.x) < 0.0001f);
    assert(math::abs(actual_row0.y - expected_row0.y) < 0.0001f);
    assert(math::abs(actual_row0.z - expected_row0.z) < 0.0001f);
    assert(math::abs(actual_row0.w - expected_row0.w) < 0.0001f);
    assert(math::abs(actual_row1.x - expected_row1.x) < 0.0001f);
    assert(math::abs(actual_row1.y - expected_row1.y) < 0.0001f);
    assert(math::abs(actual_row1.z - expected_row1.z) < 0.0001f);
    assert(math::abs(actual_row1.w - expected_row1.w) < 0.0001f);
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
    assert(packed.base_color_texture == (gpu::TextureIndex)11);
    assert(packed.base_color_sampler == (gpu::SamplerIndex)21);
    assert(packed.base_color_uv_set == 0 && packed.base_color_present == 1);
    assert(packed.metallic_roughness_texture == (gpu::TextureIndex)12);
    assert(packed.metallic_roughness_sampler == (gpu::SamplerIndex)22);
    assert(packed.metallic_roughness_uv_set == 1 && packed.metallic_roughness_present == 0);
    assert(packed.normal_texture == (gpu::TextureIndex)13);
    assert(packed.normal_sampler == (gpu::SamplerIndex)23);
    assert(packed.normal_uv_set == 1 && packed.normal_present == 1);
    assert(packed.occlusion_texture == (gpu::TextureIndex)14);
    assert(packed.occlusion_sampler == (gpu::SamplerIndex)24);
    assert(packed.occlusion_uv_set == 0 && packed.occlusion_present == 0);
    assert(packed.emissive_texture == (gpu::TextureIndex)15);
    assert(packed.emissive_sampler == (gpu::SamplerIndex)25);
    assert(packed.emissive_uv_set == 1 && packed.emissive_present == 1);
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
    assert_uv_rows(
        actual_row0: packed.base_color_uv_row0,
        actual_row1: packed.base_color_uv_row1,
        expected_row0: { 2, 0, 0.25f, 0 },
        expected_row1: { 0, 3, -0.5f, 0 },
    );
    assert_uv_rows(
        actual_row0: packed.metallic_roughness_uv_row0,
        actual_row1: packed.metallic_roughness_uv_row1,
        expected_row0: { 0, -1.25f, -1.5f, 0 },
        expected_row1: { 0.5f, 0, 2.25f, 0 },
    );
    assert_uv_rows(
        actual_row0: packed.normal_uv_row0,
        actual_row1: packed.normal_uv_row1,
        expected_row0: { -1.5f, 0, 3.75f, 0 },
        expected_row1: { 0, -0.75f, -4.5f, 0 },
    );
    assert_uv_rows(
        actual_row0: packed.occlusion_uv_row0,
        actual_row1: packed.occlusion_uv_row1,
        expected_row0: { 0, 0.375f, -5, 0 },
        expected_row1: { -2.25f, 0, 6, 0 },
    );
    assert_uv_rows(
        actual_row0: packed.emissive_uv_row0,
        actual_row1: packed.emissive_uv_row1,
        expected_row0: { 0, -1.75f, 7.5f, 0 },
        expected_row1: { 0.625f, 0, -8.25f, 0 },
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
    assert(packed.base_color_present == 0);
    assert(packed.metallic_roughness_present == 0);
    assert(packed.normal_present == 0);
    assert(packed.occlusion_present == 0);
    assert(packed.emissive_present == 0);
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
    assert(packed.map_texture == (gpu::TextureIndex)37);
    assert(packed.map_sampler == (gpu::SamplerIndex)47);
    assert(packed.map_uv_set == 1 && packed.map_present == 1);
    assert_uv_rows(
        actual_row0: packed.map_uv_row0,
        actual_row1: packed.map_uv_row1,
        expected_row0: { 0, -1.25f, 1.5f, 0 },
        expected_row1: { 0.5f, 0, -2.5f, 0 },
    );
}
