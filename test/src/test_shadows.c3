module c3d::test::shadows;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::render;
import c3d::scene;
import c3d::shader;
import std::math;
import gpu;

const Vec2 VIEWPORT @local = { 800, 600 };

fn void test_shadow_budget_keeps_requests_whole_and_admits_later_fit() @test {
    ShadowRequest[4] requests = {
        { .light = { .index = 4, .generation = 1 }, .light_index = 3, .priority = 0, .layer_count = 1 },
        { .light = { .index = 3, .generation = 1 }, .light_index = 2, .priority = 1, .layer_count = 2 },
        { .light = { .index = 2, .generation = 1 }, .light_index = 1, .priority = 2, .layer_count = 4 },
        { .light = { .index = 1, .generation = 1 }, .light_index = 0, .priority = 3, .layer_count = 3 },
    };

    ShadowAllocation allocation = render::assign_shadow_layers(requests[..], 4);
    assert(allocation.layer_count == 4 && allocation.dropped == 2);
    assert(allocation.requests.len == 2);
    assert(allocation.requests[0].light.index == 1 && allocation.requests[0].layer_count == 3);
    assert(allocation.requests[0].first_layer == 0 && allocation.requests[0].light_index == 0);
    assert(allocation.requests[1].light.index == 4 && allocation.requests[1].layer_count == 1);
    assert(allocation.requests[1].first_layer == 3 && allocation.requests[1].light_index == 3);
}

fn void test_shadow_priority_ties_use_complete_entity_identity() @test {
    ShadowRequest[3] requests = {
        { .light = { .index = 2, .generation = 1 }, .light_index = 0, .priority = -3, .layer_count = 1 },
        { .light = { .index = 1, .generation = 9 }, .light_index = 1, .priority = -3, .layer_count = 1 },
        { .light = { .index = 1, .generation = 2 }, .light_index = 2, .priority = -3, .layer_count = 1 },
    };

    ShadowRequest[3] reordered = { requests[2], requests[0], requests[1] };
    ShadowAllocation first = render::assign_shadow_layers(requests[..], 2);
    ShadowAllocation second = render::assign_shadow_layers(reordered[..], 2);
    assert(first.dropped == 1 && second.dropped == 1);
    assert(first.requests[0].light.index == 1 && first.requests[0].light.generation == 2);
    assert(first.requests[1].light.index == 1 && first.requests[1].light.generation == 9);

    foreach (index, request : first.requests) {
        assert(request.light.index == second.requests[index].light.index);
        assert(request.light.generation == second.requests[index].light.generation);
        assert(request.first_layer == second.requests[index].first_layer);
        assert(request.light_index == second.requests[index].light_index);
    }

    ShadowRequest[1] disabled_budget = {
        { .light = { .index = 5, .generation = 1 }, .layer_count = 4 },
    };
    ShadowAllocation empty = render::assign_shadow_layers(disabled_budget[..], 0);
    assert(empty.requests.len == 0 && empty.layer_count == 0 && empty.dropped == 1);
}

fn void test_cascade_splits_match_endpoint_weights_and_finite_coverage() @test {
    ShadowSettings settings = light::SHADOW_SETTINGS_DEFAULT;
    settings.cascades = 2;
    settings.max_distance = 100;
    settings.cascade_lambda = 0;
    Camera camera = camera::perspective_deg(60, 1, 81);
    CascadeSplits linear = render::directional_cascade_splits(camera, settings);
    assert(linear.count == 2 && linear.near_depth == 1);
    assert(linear.far_depths[0] == 41 && linear.far_depths[1] == 81);

    settings.cascade_lambda = 1;
    CascadeSplits logarithmic = render::directional_cascade_splits(camera, settings);
    assert(math::abs(logarithmic.far_depths[0] - 9) < 0.0001f);
    assert(logarithmic.far_depths[1] == 81);

    settings.cascade_lambda = 0.5f;
    CascadeSplits mixed = render::directional_cascade_splits(camera, settings);
    assert(math::abs(mixed.far_depths[0] - 25) < 0.0001f);

    camera.far = 0;
    settings.max_distance = 49;
    CascadeSplits infinite = render::directional_cascade_splits(camera, settings);
    assert(infinite.far_depths[1] == 49);
    settings.max_distance = 0.5f;
    assert(render::directional_cascade_splits(camera, settings).count == 0);
}

fn void test_orthographic_splits_accept_nonpositive_near_and_ignore_log_weight() @test {
    Camera camera = camera::orthographic(10, -10, 10);
    ShadowSettings settings = light::SHADOW_SETTINGS_DEFAULT;
    settings.cascades = 4;
    settings.cascade_lambda = 1;
    CascadeSplits splits = render::directional_cascade_splits(camera, settings);
    assert(splits.count == 4 && splits.near_depth == -10);
    assert(splits.far_depths == (float[4]){ -5, 0, 5, 10 });

    settings.cascade_lambda = 0;
    assert(render::directional_cascade_splits(camera, settings).far_depths == splits.far_depths);
}

fn void test_cascade_fit_preserves_receiver_guard_band_and_off_camera_depth() @test {
    Camera camera = camera::perspective_deg(60, 1, 50);
    camera.lens_shift = { 0.3f, -0.2f };
    Mat4 camera_world = matrix::IDENTITY4;
    camera_world.m00 = -2;
    camera_world.m11 = 1.5f;
    camera_world.m03 = 4;
    CameraMatrices matrices = camera::derive_matrices(camera, camera_world, VIEWPORT);

    MeshCandidate[1] casters = {{
        .world_bounds = { .min = { 3, -1, 20 }, .max = { 5, 1, 22 } },
    }};
    assert(!maths::frustum_intersects_aabb(&matrices.frustum, casters[0].world_bounds));
    ShadowCascade cascade = render::fit_directional_cascade(
        view: &matrices,
        near_depth: 1,
        far_depth: 12,
        light_direction: { 0, 0, -1 },
        casters: casters[..],
        resolution: 1024,
        normal_bias: 0.02f,
    );
    assert(cascade.split_depth == 12);
    assert(math::is_finite(cascade.camera.view_proj.m22));
    assert(math::abs(cascade.camera.proj.m00 - cascade.camera.proj.m11) < 0.00001f);
    assert(maths::frustum_intersects_aabb(&cascade.camera.frustum, casters[0].world_bounds));

    float[2] depths = { 1, 12 };
    foreach (depth : depths) {
        Vec4 depth_clip = matrices.proj.apply({ 0, 0, -depth, 1 });
        for (uint corner = 0; corner < 4; corner++) {
            float x = (corner & 1) != 0 ? 1.0f : -1.0f;
            float y = (corner & 2) != 0 ? 1.0f : -1.0f;
            Vec4 world = matrices.inv_view_proj.apply({ x, y, depth_clip.z / depth_clip.w, 1 });
            world /= world.w;
            Vec4 shadow = cascade.camera.view_proj.apply(world);
            shadow /= shadow.w;
            assert(math::abs(shadow.x) <= 1.0f - 3.0f / 1024 + 0.0001f);
            assert(math::abs(shadow.y) <= 1.0f - 3.0f / 1024 + 0.0001f);
            assert(shadow.z >= -0.0001f && shadow.z <= 1.0001f);
        }
    }

    Vec4 closer = cascade.camera.view_proj.apply({ 4, 0, 22, 1 });
    Vec4 farther = cascade.camera.view_proj.apply({ 4, 0, -12, 1 });
    assert(closer.z / closer.w > farther.z / farther.w);
}

fn void test_cascade_grid_stays_stable_under_subtexel_translation_and_camera_rotation() @test {
    Camera camera = camera::perspective_deg(60, 1, 30);
    CameraMatrices matrices = camera::derive_matrices(camera, matrix::IDENTITY4, VIEWPORT);
    ShadowCascade first = render::fit_directional_cascade(
        view: &matrices,
        near_depth: 1,
        far_depth: 20,
        light_direction: { 0, 0, -1 },
        casters: {},
        resolution: 1024,
        normal_bias: 0,
    );

    float texel_size = 2 / first.camera.proj.m00 / 1024;
    Mat4 moved = matrix::IDENTITY4;
    moved.m03 = texel_size * 0.2f;
    matrices = camera::derive_matrices(camera, moved, VIEWPORT);
    ShadowCascade translated = render::fit_directional_cascade(
        view: &matrices,
        near_depth: 1,
        far_depth: 20,
        light_direction: { 0, 0, -1 },
        casters: {},
        resolution: 1024,
        normal_bias: 0,
    );
    assert(math::abs(first.camera.view_proj.m03 - translated.camera.view_proj.m03) < 0.000001f);
    assert(math::abs(first.camera.view_proj.m00 - translated.camera.view_proj.m00) < 0.000001f);

    Mat4 rotated = {
        .m00 = 0, .m02 = 1,
        .m11 = 1,
        .m20 = -1, .m22 = 0,
        .m33 = 1,
    };
    matrices = camera::derive_matrices(camera, rotated, VIEWPORT);
    ShadowCascade turned = render::fit_directional_cascade(
        view: &matrices,
        near_depth: 1,
        far_depth: 20,
        light_direction: { 0, 0, -1 },
        casters: {},
        resolution: 1024,
        normal_bias: 0,
    );
    assert(math::abs(first.camera.proj.m00 - turned.camera.proj.m00) < 0.000001f);
}

fn void test_caster_extraction_ignores_layers_and_keeps_authored_bounds() @test {
    AssetStore assets = asset::create_asset_store(mem, {
        .max_geometries = 2,
        .max_materials = 1,
        .max_textures = asset::BUILTIN_TEXTURE_COUNT,
        .max_samplers = asset::BUILTIN_SAMPLER_COUNT,
    });
    defer asset::destroy_asset_store(&assets);

    Scene scene = scene::create_scene(mem, { .max_nodes = 8 });
    defer scene::destroy_scene(&scene);

    MaterialId material = assets.add_material(material::basic({ .color = { 1, 1, 1, 1 } }))!!;

    @pool() {
        Geometry geometry = geometry::box(
            allocator: tmem,
            width: 1,
            height: 1,
            depth: 1,
        );
        GeometryId geometry_id = assets.add_geometry(&geometry)!!;
        Node* caster = scene.add_mesh(geometry_id, material)!!;
        caster.layers = 0;
        caster.local.position = { 0, 0, 20 };
        Mesh* mesh = scene.get(caster, Mesh);
        mesh.receive_shadow = false;
        mesh.has_bounds_override = true;
        mesh.local_bounds = { .min = { -2, -3, -4 }, .max = { 2, 3, 4 } };

        Node* disabled = scene.add_mesh(geometry_id, material)!!;
        scene.get(disabled, Mesh).cast_shadow = false;

        Node* hidden_parent = scene.add_node()!!;
        hidden_parent.visible = false;
        scene.add_mesh(geometry_id, material, hidden_parent)!!;

        GeometryId dead = { .index = 1, .generation = 99 };
        scene.add_mesh(dead, material)!!;
        scene.update_world();

        ExtractCounts counts;
        MeshCandidate[] candidates = render::extract_shadow_candidates(
            allocator: tmem,
            scene: &scene,
            assets: &assets,
            counts: &counts,
        );
        assert(candidates.len == 1 && candidates[0].node == caster);
        assert(candidates[0].world_bounds.min == (Vec3){ -2, -3, 16 });
        assert(candidates[0].world_bounds.max == (Vec3){ 2, 3, 24 });
        assert(counts.visible == 1 && counts.dangling == 1 && counts.culled == 0);
    };
}

fn void test_cascade_fit_keeps_flat_casters_inside_depth_clip() @test {
    Camera camera = camera::orthographic(4, 0.1f, 30);
    Mat4 camera_world = matrix::IDENTITY4;
    camera_world.m23 = 5;
    CameraMatrices matrices = camera::derive_matrices(camera, camera_world, { 128, 128 });
    MeshCandidate[1] casters = {{
        .world_bounds = { .min = { -1, -1, 8 }, .max = { 1, 1, 8 } },
    }};

    ShadowCascade cascade = render::fit_directional_cascade(
        view: &matrices,
        near_depth: 0.1f,
        far_depth: 30,
        light_direction: { 0, 0, -1 },
        casters: casters[..],
        resolution: 2048,
        normal_bias: 0,
    );

    Vec4 clip = cascade.camera.view_proj.apply({ 0, 0, 8, 1 });
    assert(clip.z / clip.w < 1 && clip.z / clip.w > 0);
    assert(maths::frustum_intersects_aabb(&cascade.camera.frustum, casters[0].world_bounds));
}

fn void test_shadow_alpha_matches_both_visible_material_payloads() @test {
    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    common.alpha_mode = AlphaMode.MASK;
    common.alpha_cutoff = 0.35f;

    TextureSlot slot = material::texture_slot({ .index = 1, .generation = 1 });
    slot.uv_set = 1;
    slot.transform.scale = { 2, 3 };
    slot.transform.rotation = 0.7f;
    slot.transform.offset = { 0.25f, -0.5f };
    TextureBinding binding = {
        .texture_index = (gpu::TextureIndex)0,
        .sampler_index = (gpu::SamplerIndex)7,
        .present = true,
    };

    Material basic = material::basic({ .color = { 1, 1, 1, 0.4f }, .map = slot }, common);
    char[render::MATERIAL_STRIDE] storage @align(16);
    render::write_material_block(storage[..], &basic, { .base_color = binding });
    BasicMaterialGpu* visible_basic = (BasicMaterialGpu*)storage[..].ptr;
    BasicMaterialGpu shadow;
    render::write_shadow_material_block(&shadow, &basic, binding);
    assert(shadow.color.a == visible_basic.color.a && shadow.alpha_cutoff == visible_basic.alpha_cutoff);
    assert(shadow.map_flags == visible_basic.map_flags);
    assert(shadow.map.texture_index == (gpu::TextureIndex)0);
    assert(shadow.map.sampler_index == visible_basic.map.sampler_index);
    assert(shadow.map.uv_linear == visible_basic.map.uv_linear && shadow.map.uv_offset == visible_basic.map.uv_offset);

    StandardParams params = material::STANDARD_PARAMS_DEFAULT;
    params.base_color.a = 0.6f;
    params.base_color_map = slot;
    Material standard = material::standard(params, common);
    render::write_material_block(storage[..], &standard, { .base_color = binding });
    StandardMaterialGpu* visible_standard = (StandardMaterialGpu*)storage[..].ptr;
    render::write_shadow_material_block(&shadow, &standard, binding);
    assert(shadow.color.a == visible_standard.base_color.a && shadow.alpha_cutoff == visible_standard.alpha_cutoff);
    assert(shadow.map_flags == visible_standard.map_flags);
    assert(shadow.map.uv_linear == visible_standard.base_color_map.uv_linear);
    assert(shadow.map.uv_offset == visible_standard.base_color_map.uv_offset);
    assert(shadow.map.sampler_index == visible_standard.base_color_map.sampler_index);

    binding.present = false;
    render::write_shadow_material_block(&shadow, &standard, binding);
    assert((shadow.map_flags & shader::MATERIAL_MAP_BASE_COLOR) == 0);
    assert(shadow.color.a == 0.6f);
}
