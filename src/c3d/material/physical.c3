module c3d::material;

import std::math;

<* Default Standard surface with clearcoat and sheen disabled. *>
const PhysicalParams PHYSICAL_PARAMS_DEFAULT = {
    .standard = STANDARD_PARAMS_DEFAULT,
    .clearcoat_normal_scale = 1,
    .clearcoat_map = { .transform = UV_TRANSFORM_IDENTITY },
    .clearcoat_roughness_map = { .transform = UV_TRANSFORM_IDENTITY },
    .clearcoat_normal_map = { .transform = UV_TRANSFORM_IDENTITY },
    .sheen_color_map = { .transform = UV_TRANSFORM_IDENTITY },
    .sheen_roughness_map = { .transform = UV_TRANSFORM_IDENTITY },
};

<* Standard surface with optional clearcoat and sheen layers. *>
struct PhysicalParams {
    StandardParams standard;
    float clearcoat;
    float clearcoat_roughness;
    float clearcoat_normal_scale;
    Vec3 sheen_color;
    float sheen_roughness;
    TextureSlot clearcoat_map;
    TextureSlot clearcoat_roughness_map;
    TextureSlot clearcoat_normal_map;
    TextureSlot sheen_color_map;
    TextureSlot sheen_roughness_map;
}

<*
 Layer clearcoat and sheen over a Standard surface.
 @require params.standard.base_color.r >= 0, params.standard.base_color.r <= 1
 @require params.standard.base_color.g >= 0, params.standard.base_color.g <= 1
 @require params.standard.base_color.b >= 0, params.standard.base_color.b <= 1
 @require params.standard.base_color.a >= 0, params.standard.base_color.a <= 1
 @require params.standard.metallic >= 0, params.standard.metallic <= 1
 @require params.standard.roughness >= 0, params.standard.roughness <= 1
 @require params.standard.emissive.r >= 0, params.standard.emissive.g >= 0, params.standard.emissive.b >= 0
 @require math::is_finite(params.standard.emissive.r), math::is_finite(params.standard.emissive.g)
 @require math::is_finite(params.standard.emissive.b), math::is_finite(params.standard.emissive_strength)
 @require params.standard.emissive_strength >= 0, math::is_finite(params.standard.normal_scale)
 @require params.standard.occlusion_strength >= 0, params.standard.occlusion_strength <= 1
 @require params.clearcoat >= 0, params.clearcoat <= 1
 @require params.clearcoat_roughness >= 0, params.clearcoat_roughness <= 1
 @require math::is_finite(params.clearcoat_normal_scale)
 @require params.sheen_color.r >= 0, params.sheen_color.r <= 1
 @require params.sheen_color.g >= 0, params.sheen_color.g <= 1
 @require params.sheen_color.b >= 0, params.sheen_color.b <= 1
 @require params.sheen_roughness >= 0, params.sheen_roughness <= 1
 @pure
*>
fn Material physical(
    PhysicalParams params = PHYSICAL_PARAMS_DEFAULT,
    MaterialCommon common = MATERIAL_COMMON_DEFAULT,
) {
    return { .kind = MaterialKind.PHYSICAL, .common = common, .physical = params };
}
