module c3d::test::gbuffer;

import c3d;
import c3d::camera;
import c3d::material;
import c3d::maths;
import c3d::render;
import std::math;

const float OCTAHEDRAL_TOLERANCE @local = 1e-5f;
const float RECONSTRUCTION_TOLERANCE @local = 1e-3f;
const Vec2 VIEWPORT @local = { 1280, 720 };

fn Material physical_with(PhysicalParams params) @local {
    return material::physical(params);
}

fn void test_gbuffer_encodable_by_kind_and_alpha_mode() @test {
    Material basic = material::basic();
    Material toon = material::toon();
    Material standard = material::standard();
    Material masked = material::standard(common: { .alpha_mode = AlphaMode.MASK, .alpha_cutoff = 0.5f });
    Material blended = material::standard(common: { .alpha_mode = AlphaMode.BLEND });
    Material physical = material::physical();
    Material physical_blended = material::physical(common: { .alpha_mode = AlphaMode.BLEND });
    Material custom = { .kind = MaterialKind.CUSTOM };

    assert(!render::gbuffer_encodable(&basic));
    assert(!render::gbuffer_encodable(&toon));
    assert(render::gbuffer_encodable(&standard));
    assert(render::gbuffer_encodable(&masked));
    assert(!render::gbuffer_encodable(&blended));
    assert(render::gbuffer_encodable(&physical));
    assert(!render::gbuffer_encodable(&physical_blended));
    assert(!render::gbuffer_encodable(&custom));
}

fn void test_gbuffer_encodable_routes_lobed_physical_forward() @test {
    TextureId map = { .index = 3, .generation = 1 };
    PhysicalParams clearcoat = material::PHYSICAL_PARAMS_DEFAULT;
    clearcoat.clearcoat = 0.5f;
    PhysicalParams sheen = material::PHYSICAL_PARAMS_DEFAULT;
    sheen.sheen_color = { 0.2f, 0, 0 };
    PhysicalParams anisotropy = material::PHYSICAL_PARAMS_DEFAULT;
    anisotropy.anisotropy = 0.3f;
    PhysicalParams transmission = material::PHYSICAL_PARAMS_DEFAULT;
    transmission.transmission = 0.5f;
    PhysicalParams ior = material::PHYSICAL_PARAMS_DEFAULT;
    ior.ior = 1.4f;
    PhysicalParams tinted = material::PHYSICAL_PARAMS_DEFAULT;
    tinted.specular_color = { 0.5f, 1, 1 };
    PhysicalParams tint_map = material::PHYSICAL_PARAMS_DEFAULT;
    tint_map.specular_color_map = material::texture_slot(map);
    PhysicalParams weight = material::PHYSICAL_PARAMS_DEFAULT;
    weight.specular = 0.5f;
    PhysicalParams weight_map = material::PHYSICAL_PARAMS_DEFAULT;
    weight_map.specular_map = material::texture_slot(map);

    Material[7] forward = {
        physical_with(clearcoat), physical_with(sheen), physical_with(anisotropy), physical_with(transmission),
        physical_with(ior), physical_with(tinted), physical_with(tint_map),
    };
    foreach (&candidate : forward) assert(!render::gbuffer_encodable(candidate));

    Material encodable_weight = physical_with(weight);
    Material encodable_weight_map = physical_with(weight_map);
    assert(render::gbuffer_encodable(&encodable_weight));
    assert(render::gbuffer_encodable(&encodable_weight_map));
}

fn void test_view_draw_list_selects_gbuffer_only_on_deferred_views() @test {
    Material standard = material::standard();
    Material blended = material::standard(common: { .alpha_mode = AlphaMode.BLEND });
    Material toon = material::toon();
    PhysicalParams params = material::PHYSICAL_PARAMS_DEFAULT;
    params.transmission = 1;
    Material transmissive = physical_with(params);

    assert(render::view_draw_list(&standard, ShadingPath.DEFERRED) == DrawList.GBUFFER);
    assert(render::view_draw_list(&standard, ShadingPath.FORWARD) == DrawList.OPAQUE);
    assert(render::view_draw_list(&transmissive, ShadingPath.DEFERRED) == DrawList.TRANSMISSION);
    assert(render::view_draw_list(&transmissive, ShadingPath.FORWARD) == DrawList.TRANSMISSION);
    assert(render::view_draw_list(&blended, ShadingPath.DEFERRED) == DrawList.TRANSPARENT);
    assert(render::view_draw_list(&blended, ShadingPath.FORWARD) == DrawList.TRANSPARENT);
    assert(render::view_draw_list(&toon, ShadingPath.DEFERRED) == DrawList.OPAQUE);
    assert(render::view_draw_list(&toon, ShadingPath.FORWARD) == DrawList.OPAQUE);
}

fn void test_custom_routes_by_gbuffer_stage() @test {
    Material custom = { .kind = MaterialKind.CUSTOM, .common = material::MATERIAL_COMMON_DEFAULT };
    Material blended = custom;
    blended.common.alpha_mode = AlphaMode.BLEND;

    assert(render::gbuffer_encodable(&custom, true));
    assert(!render::gbuffer_encodable(&custom, false));
    assert(!render::gbuffer_encodable(&blended, true));
    assert(render::view_draw_list(&custom, ShadingPath.DEFERRED, true) == DrawList.GBUFFER);
    assert(render::view_draw_list(&custom, ShadingPath.DEFERRED, false) == DrawList.OPAQUE);
    assert(render::view_draw_list(&custom, ShadingPath.FORWARD, true) == DrawList.OPAQUE);
    assert(render::view_draw_list(&blended, ShadingPath.DEFERRED, true) == DrawList.TRANSPARENT);
}

fn void test_octahedral_round_trip() @test {
    Vec3[17] normals = {
        { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 },
        { 1, 1, 1 }, { -1, 1, 1 }, { 1, -1, 1 }, { 1, 1, -1 }, { -1, -1, 1 }, { -1, 1, -1 }, { 1, -1, -1 },
        { -1, -1, -1 }, { 0.3f, -0.8f, 0.2f }, { -0.1f, 0.05f, -0.9f }, { 0.6f, 0.7f, -0.05f },
    };
    foreach (normal : normals) {
        Vec3 unit = normal.normalize();
        Vec2 encoded = render::encode_octahedral(unit);
        assert(math::abs(encoded.x) <= 1 && math::abs(encoded.y) <= 1);
        Vec3 decoded = render::decode_octahedral(encoded);
        assert((decoded - unit).length() < OCTAHEDRAL_TOLERANCE);
    }
}

fn void test_world_position_reconstruction_from_reverse_z_depth() @test {
    Vec3[3] points = { { 0, 0, 0 }, { 1.5f, -0.5f, 2 }, { -2, 3, -4 } };
    Transform pose = {
        .position = { 0, 1, 5 },
        .rotation = maths::look_rotation((Vec3){ 0, -1, -5 }.normalize(), { 0, 1, 0 }),
        .scale    = { 1, 1, 1 },
    };
    Mat4 world = pose.to_mat4();
    Camera[2] cameras = { camera::perspective_deg(60, 0.1f), camera::orthographic(8, 0.1f, 100) };
    foreach (camera : cameras) {
        CameraMatrices matrices = camera::derive_matrices(camera, world, VIEWPORT);
        foreach (point : points) {
            Vec4 clip = matrices.view_proj.apply({ point.x, point.y, point.z, 1 });
            Vec3 ndc = clip.xyz / clip.w;
            Vec2 uv = { ndc.x * 0.5f + 0.5f, 0.5f - ndc.y * 0.5f };
            Vec3 reconstructed = render::reconstruct_world_position(matrices.inv_view_proj, uv, ndc.z);
            assert((reconstructed - point).length() < RECONSTRUCTION_TOLERANCE);
        }
    }
}
