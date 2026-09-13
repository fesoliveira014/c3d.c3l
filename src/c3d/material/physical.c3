module c3d::material;

import std::math;

<* Standard-equivalent surface; clearcoat, sheen, anisotropy and transmission off. *>
const PhysicalParams PHYSICAL_PARAMS_DEFAULT = {
    .standard = STANDARD_PARAMS_DEFAULT,
    .clearcoat_normal_scale = 1,
    .ior = 1.5f,
    .specular = 1,
    .specular_color = { 1, 1, 1 },
    .attenuation_color = { 1, 1, 1 },
    .clearcoat_map = { .transform = UV_TRANSFORM_IDENTITY },
    .clearcoat_roughness_map = { .transform = UV_TRANSFORM_IDENTITY },
    .clearcoat_normal_map = { .transform = UV_TRANSFORM_IDENTITY },
    .sheen_color_map = { .transform = UV_TRANSFORM_IDENTITY },
    .sheen_roughness_map = { .transform = UV_TRANSFORM_IDENTITY },
    .specular_map = { .transform = UV_TRANSFORM_IDENTITY },
    .specular_color_map = { .transform = UV_TRANSFORM_IDENTITY },
    .anisotropy_map = { .transform = UV_TRANSFORM_IDENTITY },
    .transmission_map = { .transform = UV_TRANSFORM_IDENTITY },
    .thickness_map = { .transform = UV_TRANSFORM_IDENTITY },
};

<* Standard surface with optional clearcoat, sheen, specular, anisotropy and transmission. *>
struct PhysicalParams {
    StandardParams standard;
    float clearcoat;
    float clearcoat_roughness;
    float clearcoat_normal_scale;
    Vec3 sheen_color;
    float sheen_roughness;
    float ior;
    float specular;
    Vec3 specular_color;
    float anisotropy;
    float anisotropy_rotation;
    float transmission;
    float thickness;
    float attenuation_distance;
    Vec3 attenuation_color;
    TextureSlot clearcoat_map;
    TextureSlot clearcoat_roughness_map;
    TextureSlot clearcoat_normal_map;
    TextureSlot sheen_color_map;
    TextureSlot sheen_roughness_map;
    TextureSlot specular_map;
    TextureSlot specular_color_map;
    TextureSlot anisotropy_map;
    TextureSlot transmission_map;
    TextureSlot thickness_map;
}

<*
 Layer clearcoat, sheen, specular, anisotropy and transmission over a Standard surface.
 @require @standard_params_in_range(params.standard), @standard_params_finite(params.standard)
 @require @in_unit_interval(params.clearcoat), @in_unit_interval(params.clearcoat_roughness)
 @require math::is_finite(params.clearcoat_normal_scale)
 @require @rgb_in_unit_interval(params.sheen_color)
 @require @in_unit_interval(params.sheen_roughness)
 @require @physical_specular_in_range(params), @physical_anisotropy_in_range(params)
 @require @physical_volume_in_range(params)
 @pure
*>
fn Material physical(
    PhysicalParams params = PHYSICAL_PARAMS_DEFAULT,
    MaterialCommon common = MATERIAL_COMMON_DEFAULT,
) {
    return { .kind = MaterialKind.PHYSICAL, .common = common, .physical = params };
}
