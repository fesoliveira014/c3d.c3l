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
 @require @standard_params_in_range(params.standard), @standard_params_finite(params.standard)
 @require @in_unit_interval(params.clearcoat), @in_unit_interval(params.clearcoat_roughness)
 @require math::is_finite(params.clearcoat_normal_scale)
 @require @rgb_in_unit_interval(params.sheen_color)
 @require @in_unit_interval(params.sheen_roughness)
 @pure
*>
fn Material physical(
    PhysicalParams params = PHYSICAL_PARAMS_DEFAULT,
    MaterialCommon common = MATERIAL_COMMON_DEFAULT,
) {
    return { .kind = MaterialKind.PHYSICAL, .common = common, .physical = params };
}
