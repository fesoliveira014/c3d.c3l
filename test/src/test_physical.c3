module c3d::test::physical;

import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::material;
import c3d::render;
import c3d::scene;
import c3d::shader;
import gpu;
import std::math;

fn TextureBinding binding(uint texture, uint sampler) @local {
    return {
        .texture_index = (gpu::TextureIndex)texture,
        .sampler_index = (gpu::SamplerIndex)sampler,
        .present = true,
    };
}

fn void test_physical_prefix_matches_standard_payload() @test {
    PhysicalParams params = material::PHYSICAL_PARAMS_DEFAULT;
    params.standard.base_color = { 0.2f, 0.4f, 0.6f, 0.5f };
    params.standard.metallic = 0.3f;
    params.standard.roughness = 0.7f;
    params.standard.normal_scale = -0.5f;
    params.standard.emissive = { 1, 2, 3 };
    params.standard.emissive_strength = 2;
    params.standard.occlusion_strength = 0.4f;
    params.standard.normal_map.uv_set = 1;
    params.standard.normal_map.transform = { .offset = { 0.2f, -0.3f }, .scale = { 2, 3 }, .rotation = 0.4f };
    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    common.alpha_mode = AlphaMode.BLEND;
    common.double_sided = true;
    Material standard = material::standard(params.standard, common);
    Material physical = material::physical(params, common);
    MaterialBindings bindings = {
        .base_color = binding(0, 2),
        .metallic_roughness = binding(3, 4),
        .normal = binding(5, 6),
        .occlusion = binding(7, 8),
        .emissive = binding(9, 10),
    };
    char[render::MATERIAL_STRIDE] standard_bytes @align(16);
    char[render::MATERIAL_STRIDE] physical_bytes @align(16);
    render::write_material_block(standard_bytes[..], &standard, bindings);
    render::write_material_block(physical_bytes[..], &physical, bindings);
    assert(standard_bytes[uint::size:StandardMaterialGpu::size - uint::size]
        == physical_bytes[uint::size:StandardMaterialGpu::size - uint::size]);
    PhysicalMaterialGpu* packed = (PhysicalMaterialGpu*)&physical_bytes;
    assert(packed.standard.kind == (uint)MaterialKind.PHYSICAL.ordinal);
    assert(packed.clearcoat == 0 && packed.sheen_color_roughness == (Vec4){});
}

fn void test_physical_maps_have_independent_flags_and_transforms() @test {
    PhysicalParams params = material::PHYSICAL_PARAMS_DEFAULT;
    params.clearcoat = 0.8f;
    params.clearcoat_roughness = 0.6f;
    params.clearcoat_normal_scale = -0.25f;
    params.sheen_color = { 0.2f, 0.3f, 0.4f };
    params.sheen_roughness = 0.7f;
    params.clearcoat_map.uv_set = 1;
    params.clearcoat_normal_map.uv_set = 1;
    params.sheen_roughness_map.uv_set = 1;
    params.clearcoat_map.transform = { .offset = { 1, 2 }, .scale = { 2, 3 } };
    params.clearcoat_roughness_map.transform = { .offset = { 3, 4 }, .scale = { 4, 5 } };
    params.clearcoat_normal_map.transform = { .offset = { 5, 6 }, .scale = { 6, 7 } };
    params.sheen_color_map.transform = { .offset = { 7, 8 }, .scale = { 8, 9 } };
    params.sheen_roughness_map.transform = { .offset = { 9, 10 }, .scale = { 10, 11 } };
    Material material = material::physical(params);
    MaterialBindings bindings = {
        .clearcoat = binding(0, 2),
        .clearcoat_roughness = binding(3, 4),
        .clearcoat_normal = binding(5, 6),
        .sheen_color = binding(7, 8),
        .sheen_roughness = binding(9, 10),
    };
    char[render::MATERIAL_STRIDE] storage @align(16);
    render::write_material_block(storage[..], &material, bindings);
    PhysicalMaterialGpu* packed = (PhysicalMaterialGpu*)&storage;
    uint present = shader::PHYSICAL_MAP_CLEARCOAT | shader::PHYSICAL_MAP_CLEARCOAT_ROUGHNESS
      | shader::PHYSICAL_MAP_CLEARCOAT_NORMAL | shader::PHYSICAL_MAP_SHEEN_COLOR
      | shader::PHYSICAL_MAP_SHEEN_ROUGHNESS;
    uint alternate_uv = shader::PHYSICAL_MAP_CLEARCOAT | shader::PHYSICAL_MAP_CLEARCOAT_NORMAL
      | shader::PHYSICAL_MAP_SHEEN_ROUGHNESS;
    assert(packed.map_flags == (present | (alternate_uv << shader::MATERIAL_MAP_UV1_SHIFT)));
    assert(packed.standard.map_flags == 0);
    assert(packed.clearcoat == 0.8f && packed.clearcoat_roughness == 0.6f);
    assert(packed.clearcoat_normal_scale == -0.25f);
    assert(packed.sheen_color_roughness == (Vec4){ 0.2f, 0.3f, 0.4f, 0.7f });
    TextureMapGpu[5] maps = {
        packed.clearcoat_map, packed.clearcoat_roughness_map, packed.clearcoat_normal_map,
        packed.sheen_color_map, packed.sheen_roughness_map,
    };
    uint[5] textures = { 0, 3, 5, 7, 9 };
    foreach (index, map : maps) {
        float offset = 1 + 2 * (float)index;
        assert(map.texture_index == (gpu::TextureIndex)textures[index]);
        assert(map.sampler_index == (gpu::SamplerIndex)(2 + 2 * (uint)index));
        assert(map.uv_offset == (Vec2){ offset, offset + 1 });
        assert(map.uv_linear == (Vec4){ offset + 1, 0, 0, offset + 2 });
    }
}

fn void test_physical_repack_clears_layer_state_after_family_reuse() @test {
    PhysicalParams params = material::PHYSICAL_PARAMS_DEFAULT;
    params.clearcoat = 1;
    params.sheen_color = { 1, 1, 1 };
    Material material = material::physical(params);
    material.common.alpha_mode = AlphaMode.BLEND;
    MaterialBindings bindings = {
        .clearcoat = binding(1, 2), .clearcoat_roughness = binding(3, 4),
        .clearcoat_normal = binding(5, 6), .sheen_color = binding(7, 8),
        .sheen_roughness = binding(9, 10),
    };
    char[render::MATERIAL_STRIDE] storage @align(16);
    storage[..] = 0x7f;
    render::write_material_block(storage[..], &material, bindings);
    material = material::toon();
    render::write_material_block(storage[..], &material, { .gradient = binding(11, 12) });
    material = material::physical();
    render::write_material_block(storage[..], &material, {});
    PhysicalMaterialGpu* packed = (PhysicalMaterialGpu*)&storage;
    assert(packed.standard.flags == 0 && packed.map_flags == 0);
    assert(packed.clearcoat == 0 && packed.sheen_color_roughness == (Vec4){});
    assert(packed.clearcoat_map.texture_index == (gpu::TextureIndex)0);
    assert(packed.clearcoat_roughness_map.texture_index == (gpu::TextureIndex)0);
    assert(packed.clearcoat_normal_map.texture_index == (gpu::TextureIndex)0);
    assert(packed.sheen_color_map.texture_index == (gpu::TextureIndex)0);
    assert(packed.sheen_roughness_map.texture_index == (gpu::TextureIndex)0);
}

fn void test_each_physical_binding_participates_in_reuse() @test {
    MaterialBindings first;
    for (uint slot = 0; slot < 5; slot++) {
        for (uint change = 0; change < 9; change++) {
            MaterialBindings second = first;
            TextureBinding* selected;
            switch (slot) {
                case 0: selected = &second.clearcoat;
                case 1: selected = &second.clearcoat_roughness;
                case 2: selected = &second.clearcoat_normal;
                case 3: selected = &second.sheen_color;
                case 4: selected = &second.sheen_roughness;
                default: unreachable();
            }
            switch (change) {
                case 0: selected.texture.index = 1;
                case 1: selected.texture.generation = 1;
                case 2: selected.sampler.index = 1;
                case 3: selected.sampler.generation = 1;
                case 4: selected.texture_binding_revision = 1;
                case 5: selected.sampler_revision = 1;
                case 6: selected.texture_index = (gpu::TextureIndex)1;
                case 7: selected.sampler_index = (gpu::SamplerIndex)1;
                case 8: selected.present = true;
                default: unreachable();
            }
            assert(!render::material_bindings_match(first, second));
        }
    }
    assert(render::material_bindings_match(first, first));
}

fn void test_physical_shadow_payload_uses_only_standard_base_alpha() @test {
    PhysicalParams params = material::PHYSICAL_PARAMS_DEFAULT;
    params.standard.base_color = { 0.2f, 0.4f, 0.6f, 0.3f };
    params.standard.base_color_map.uv_set = 1;
    params.standard.base_color_map.transform = { .offset = { 0.2f, 0.3f }, .scale = { 2, 3 }, .rotation = 0.7f };
    params.clearcoat = 1;
    params.sheen_color = { 1, 1, 1 };
    params.clearcoat_map.texture.asset = { .index = 99, .generation = 9 };
    params.sheen_color_map.texture.asset = { .index = 98, .generation = 9 };
    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    common.alpha_mode = AlphaMode.MASK;
    common.alpha_cutoff = 0.25f;
    common.double_sided = true;
    Material material = material::physical(params, common);
    TextureBinding base = binding(0, 7);
    char[render::MATERIAL_STRIDE] storage @align(16);
    render::write_material_block(storage[..], &material, { .base_color = base });
    PhysicalMaterialGpu* visible = (PhysicalMaterialGpu*)&storage;
    BasicMaterialGpu shadow;
    render::write_shadow_material_block(&shadow, &material, base);
    assert(shadow.color == visible.standard.base_color);
    assert(shadow.flags == visible.standard.flags && shadow.alpha_cutoff == visible.standard.alpha_cutoff);
    assert(shadow.map_flags == visible.standard.map_flags);
    assert(shadow.map.texture_index == visible.standard.base_color_map.texture_index);
    assert(shadow.map.sampler_index == visible.standard.base_color_map.sampler_index);
    assert(shadow.map.uv_offset == visible.standard.base_color_map.uv_offset);
    assert(shadow.map.uv_linear == visible.standard.base_color_map.uv_linear);
}

fn void test_physical_blends_do_not_enter_shadow_candidates() @test {
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    Scene scene = scene::create_scene(mem, { .max_nodes = 4 });
    defer scene::destroy_scene(&scene);
    @pool() {
        Geometry geometry = geometry::box(
            allocator: tmem,
            width: 1,
            height: 1,
            depth: 1,
        );
        GeometryId geometry_id = assets.add_geometry(&geometry)!!;
        foreach (AlphaMode mode : { AlphaMode.OPAQUE, AlphaMode.MASK, AlphaMode.BLEND }) {
            Material material = material::physical();
            material.common.alpha_mode = mode;
            MaterialId material_id = assets.add_material(material)!!;
            Node* node = scene.add_mesh(geometry_id, material_id)!!;
            node.layers = 0;
            node.local.position = { 0, 0, 20 };
        }
        scene.update_world();
        ExtractCounts counts;
        MeshCandidate[] candidates = render::extract_shadow_candidates(
            allocator: tmem,
            scene: &scene,
            assets: &assets,
            counts: &counts,
        );
        assert(candidates.len == 2 && counts.visible == 2);
        assert(counts.culled == 0 && counts.dangling == 0);
        foreach (candidate : candidates) {
            assert(assets.material(candidate.material).data.kind == MaterialKind.PHYSICAL);
            assert(assets.material(candidate.material).data.common.alpha_mode != AlphaMode.BLEND);
        }
    };
}
