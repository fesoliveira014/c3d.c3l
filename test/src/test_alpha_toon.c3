module c3d::test::alpha_toon;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::material;
import c3d::render;
import c3d::scene;
import c3d::shader;
import gpu;
import std::math;
import std::sort;

fn TextureBinding binding(uint texture, uint sampler) @local {
    return {
        .texture_index = (gpu::TextureIndex)texture,
        .sampler_index = (gpu::SamplerIndex)sampler,
        .present = true,
    };
}

fn void test_toon_packing_preserves_ramp_rim_and_base_transform() @test {
    ToonParams params = material::TOON_PARAMS_DEFAULT;
    params.color = { 0.2f, 0.4f, 0.6f, 0.5f };
    params.steps = 6;
    params.map.uv_set = 1;
    params.map.transform = { .offset = { 0.25f, -0.5f }, .scale = { 2, 3 } };
    params.rim_color = { 0.3f, 0.5f, 0.7f };
    params.rim_strength = 1.5f;
    params.rim_power = 3;
    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    common.alpha_mode = AlphaMode.BLEND;
    common.double_sided = true;
    Material material = material::toon(params, common);
    MaterialBindings bindings = { .base_color = binding(0, 5), .gradient = binding(0, 7) };
    char[render::MATERIAL_STRIDE] storage @align(16);
    render::write_material_block(storage[..], &material, bindings);
    ToonMaterialGpu* packed = (ToonMaterialGpu*)&storage;
    assert(packed.kind == (uint)MaterialKind.TOON.ordinal);
    assert(packed.flags == (shader::MATERIAL_ALPHA_BLEND | shader::MATERIAL_DOUBLE_SIDED));
    assert(packed.color == params.color && packed.steps == 6);
    assert(packed.rim_color_strength == (Vec4){ 0.3f, 0.5f, 0.7f, 1.5f });
    assert(packed.rim_power == 3);
    assert(packed.gradient_texture == (gpu::TextureIndex)0);
    assert(packed.gradient_sampler == (gpu::SamplerIndex)7);
    assert(packed.map_flags == (shader::MATERIAL_MAP_BASE_COLOR
        | (shader::MATERIAL_MAP_BASE_COLOR << shader::MATERIAL_MAP_UV1_SHIFT)
        | shader::TOON_MAP_GRADIENT));
    assert(packed.map.texture_index == (gpu::TextureIndex)0);
    assert(packed.map.sampler_index == (gpu::SamplerIndex)5);
    assert(packed.map.uv_offset == (Vec2){ 0.25f, -0.5f });
    assert(packed.map.uv_linear == (Vec4){ 2, 0, 0, 3 });
}

fn void test_toon_repack_clears_absent_bindings_and_blend_flag() @test {
    char[render::MATERIAL_STRIDE] storage @align(16);
    storage[..] = 0x7f;
    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    common.alpha_mode = AlphaMode.BLEND;
    Material material = material::toon(common: common);
    render::write_material_block(
        block: storage[..],
        material: &material,
        bindings: { .base_color = binding(9, 10), .gradient = binding(11, 12) },
    );
    material = material::standard();
    render::write_material_block(storage[..], &material, {});
    material = material::toon();
    render::write_material_block(storage[..], &material, {});
    ToonMaterialGpu* packed = (ToonMaterialGpu*)&storage;
    assert(packed.flags == 0 && packed.map_flags == 0);
    assert(packed.gradient_texture == (gpu::TextureIndex)0);
    assert(packed.gradient_sampler == (gpu::SamplerIndex)0);
    assert(packed.color == material.toon.color);
    assert(packed.rim_color_strength.w == 0);
}

fn void test_alpha_flags_follow_every_active_material_family() @test {
    Material[3] materials = {
        material::basic({ .color = { 1, 1, 1, 0.25f } }),
        material::standard(),
        material::toon(),
    };
    char[render::MATERIAL_STRIDE] storage @align(16);
    foreach (&material : materials) {
        material.common.alpha_mode = AlphaMode.BLEND;
        render::write_material_block(storage[..], material, {});
        BasicMaterialGpu* header = (BasicMaterialGpu*)&storage;
        assert(header.flags == shader::MATERIAL_ALPHA_BLEND);
        material.common.alpha_mode = AlphaMode.MASK;
        material.common.alpha_cutoff = 0.35f;
        render::write_material_block(storage[..], material, {});
        assert(header.flags == shader::MATERIAL_ALPHA_MASK && header.alpha_cutoff == 0.35f);
        material.common.alpha_mode = AlphaMode.OPAQUE;
        render::write_material_block(storage[..], material, {});
        assert(header.flags == 0);
    }
}

fn void test_toon_shadow_alpha_matches_its_visible_base_payload() @test {
    ToonParams params = material::TOON_PARAMS_DEFAULT;
    params.color.a = 0.4f;
    params.map.uv_set = 1;
    params.map.transform = { .offset = { 0.2f, -0.3f }, .scale = { 2, 3 }, .rotation = 0.7f };
    params.gradient_map = { .index = 30, .generation = 99 };
    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    common.alpha_mode = AlphaMode.MASK;
    common.alpha_cutoff = 0.35f;
    common.double_sided = true;
    Material material = material::toon(params, common);
    TextureBinding base = binding(0, 7);
    char[render::MATERIAL_STRIDE] storage @align(16);
    render::write_material_block(storage[..], &material, { .base_color = base });
    ToonMaterialGpu* visible = (ToonMaterialGpu*)&storage;
    BasicMaterialGpu shadow;
    render::write_shadow_material_block(&shadow, &material, base);
    assert(shadow.color == visible.color);
    assert(shadow.alpha_cutoff == visible.alpha_cutoff && shadow.flags == visible.flags);
    assert(shadow.map_flags == visible.map_flags);
    assert(shadow.map.texture_index == visible.map.texture_index);
    assert(shadow.map.sampler_index == visible.map.sampler_index);
    assert(shadow.map.uv_offset == visible.map.uv_offset);
    assert(shadow.map.uv_linear == visible.map.uv_linear);
}

fn void test_gradient_freshness_participates_in_material_binding_reuse() @test {
    MaterialBindings first = {
        .gradient = {
            .texture = { .index = 7, .generation = 3 },
            .texture_binding_revision = 4,
            .texture_index = (gpu::TextureIndex)0,
            .sampler_index = (gpu::SamplerIndex)9,
            .present = true,
        },
    };
    MaterialBindings second = first;
    assert(render::material_bindings_match(first, second));
    second.gradient.texture_binding_revision++;
    assert(!render::material_bindings_match(first, second));
    second = first;
    second.gradient.texture.generation++;
    assert(!render::material_bindings_match(first, second));
    second = first;
    second.gradient.texture_index = (gpu::TextureIndex)5;
    assert(!render::material_bindings_match(first, second));
    second = first;
    second.gradient.sampler_index = (gpu::SamplerIndex)8;
    assert(!render::material_bindings_match(first, second));
    second = first;
    second.gradient.present = false;
    assert(!render::material_bindings_match(first, second));
}

fn void test_transparent_order_uses_depth_before_entity_ties() @test {
    Node[4] nodes = {
        { .id = { .index = 7, .generation = 2 } },
        { .id = { .index = 1, .generation = 3 } },
        { .id = { .index = 1, .generation = 2 } },
        { .id = { .index = 9, .generation = 1 } },
    };
    MeshCandidate[4] candidates = {
        { .node = &nodes[0], .view_depth = 4 },
        { .node = &nodes[1], .view_depth = 5 },
        { .node = &nodes[2], .view_depth = 5 },
        { .node = &nodes[3], .view_depth = 5.0001f },
    };
    sort::quicksort(candidates[..], &render::compare_transparent_candidates);
    assert(candidates[0].node == &nodes[3]);
    assert(candidates[1].node == &nodes[2]);
    assert(candidates[2].node == &nodes[1]);
    assert(candidates[3].node == &nodes[0]);
    assert(render::compare_transparent_candidates(candidates[0], candidates[0]) == 0);
}

fn void test_candidate_view_depth_uses_bounds_center_and_camera_pose() @test {
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
        MaterialId material_id = assets.add_material(material::toon())!!;
        Node* mesh_node = scene.add_mesh(geometry_id, material_id)!!;
        Mesh* mesh = scene.get(mesh_node, Mesh);
        mesh.has_bounds_override = true;
        mesh.local_bounds = { .min = { -0.5f, -0.5f, 0.5f }, .max = { 0.5f, 0.5f, 1.5f } };
        Node* camera_node = scene.add_camera(camera::perspective_deg(60, 0.1f, 30))!!;
        for (uint index = 0; index < 2; index++) {
            camera_node.local.position = { 0, 0, 5 + 2 * (float)index };
            scene.update_world();
            CameraMatrices matrices = camera::derive_matrices(
                camera: *scene.get(camera_node, Camera),
                camera_world: camera_node.world,
                viewport: { 128, 128 },
            );
            ExtractCounts counts;
            MeshCandidate[] candidates = render::extract_candidates(
                allocator: tmem,
                scene: &scene,
                assets: &assets,
                camera: &matrices,
                layers: scene::DEFAULT_LAYERS,
                counts: &counts,
            );
            assert(candidates.len == 1 && candidates[0].node == mesh_node);
            assert(math::abs(candidates[0].view_depth - (4 + 2 * (float)index)) < 0.00001f);
        }
    };
}

fn void test_blended_materials_are_excluded_from_shadow_candidates() @test {
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    Scene scene = scene::create_scene(mem, { .max_nodes = 12 });
    defer scene::destroy_scene(&scene);
    Material[3] materials = {
        material::basic({ .color = { 1, 1, 1, 0.5f } }),
        material::standard(),
        material::toon(),
    };
    AlphaMode[3] modes = { AlphaMode.OPAQUE, AlphaMode.MASK, AlphaMode.BLEND };
    @pool() {
        Geometry geometry = geometry::box(
            allocator: tmem,
            width: 1,
            height: 1,
            depth: 1,
        );
        GeometryId geometry_id = assets.add_geometry(&geometry)!!;
        foreach (material : materials) {
            foreach (mode : modes) {
                material.common.alpha_mode = mode;
                MaterialId material_id = assets.add_material(material)!!;
                Node* node = scene.add_mesh(geometry_id, material_id)!!;
                node.layers = 0;
                node.local.position = { 0, 0, 20 };
            }
        }
        scene.update_world();
        ExtractCounts counts;
        MeshCandidate[] candidates = render::extract_shadow_candidates(
            allocator: tmem,
            scene: &scene,
            assets: &assets,
            counts: &counts,
        );
        assert(candidates.len == 6 && counts.visible == 6);
        assert(counts.dangling == 0 && counts.culled == 0);
        uint[3] per_family;
        foreach (candidate : candidates) {
            Material* material = &assets.material(candidate.material).data;
            assert(material.common.alpha_mode != AlphaMode.BLEND);
            per_family[(usz)material.kind.ordinal]++;
        }
        assert(per_family[0] == 2 && per_family[1] == 2 && per_family[2] == 2);
    };
}
