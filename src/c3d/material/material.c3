module c3d::material;

import std::math;

<*
 Common state every material starts from: opaque, depth tested and written.
*>
const MaterialCommon MATERIAL_COMMON_DEFAULT = {
    .alpha_mode   = AlphaMode.OPAQUE,
    .alpha_cutoff = 0.5f,
    .depth_write  = true,
    .depth_test   = true,
};

<* Default unlit color and base-map transform. *>
const BasicParams BASIC_PARAMS_DEFAULT = {
    .color = { 1, 1, 1, 1 },
    .map = { .transform = UV_TRANSFORM_IDENTITY },
};

<* Default metallic-roughness factors. *>
const StandardParams STANDARD_PARAMS_DEFAULT = {
    .base_color = { 1, 1, 1, 1 },
    .metallic = 1,
    .roughness = 1,
    .emissive_strength = 1,
    .normal_scale = 1,
    .occlusion_strength = 1,
    .base_color_map = { .transform = UV_TRANSFORM_IDENTITY },
    .metallic_roughness_map = { .transform = UV_TRANSFORM_IDENTITY },
    .normal_map = { .transform = UV_TRANSFORM_IDENTITY },
    .occlusion_map = { .transform = UV_TRANSFORM_IDENTITY },
    .emissive_map = { .transform = UV_TRANSFORM_IDENTITY },
};

<*
 Shading family of a material.
*>
enum MaterialKind {
    BASIC,
    STANDARD,
    TOON,
    PHYSICAL,
}

<*
 How fragment alpha is treated.
*>
enum AlphaMode {
    OPAQUE,
    MASK,
    BLEND,
}

<*
 Raster and depth state shared by every material kind.
*>
struct MaterialCommon {
    AlphaMode alpha_mode;
    float     alpha_cutoff;
    bool      double_sided;
    bool      depth_write;
    bool      depth_test;
    bool      wireframe;
}

<*
 Unlit color multiplied by an optional texture map.
*>
struct BasicParams {
    Vec4 color;
    TextureSlot map;
}

<* Metallic-roughness factors and independently mapped textures. *>
struct StandardParams {
    Vec4 base_color;
    float metallic;
    float roughness;
    Vec3 emissive;
    float emissive_strength;
    float normal_scale;
    float occlusion_strength;
    TextureSlot base_color_map;
    TextureSlot metallic_roughness_map;
    TextureSlot normal_map;
    TextureSlot occlusion_map;
    TextureSlot emissive_map;
}

<*
 Material description; the kind selects which parameters are read.
*>
struct Material {
    MaterialKind   kind;
    MaterialCommon common;
    union {
        BasicParams basic;
        StandardParams standard;
        ToonParams toon;
        PhysicalParams physical;
    }
}

<*
 Unlit material.
 @pure
*>
fn Material basic(BasicParams params = BASIC_PARAMS_DEFAULT, MaterialCommon common = MATERIAL_COMMON_DEFAULT) {
    return { .kind = MaterialKind.BASIC, .common = common, .basic = params };
}

<*
 Metallic-roughness material with optional texture maps.
 @require @standard_params_in_range(params), @standard_params_finite(params)
 @pure
*>
fn Material standard(
    StandardParams params = STANDARD_PARAMS_DEFAULT,
    MaterialCommon common = MATERIAL_COMMON_DEFAULT,
) {
    return { .kind = STANDARD, .common = common, .standard = params };
}

macro bool @in_unit_interval(float #value) @private {
    return #value >= 0 && #value <= 1;
}

macro bool @rgb_in_unit_interval(#color) @private {
    return @in_unit_interval(#color.r) && @in_unit_interval(#color.g) && @in_unit_interval(#color.b);
}

macro bool @rgb_nonnegative_finite(#color) @private {
    return #color.r >= 0 && #color.g >= 0 && #color.b >= 0
        && math::is_finite(#color.r) && math::is_finite(#color.g) && math::is_finite(#color.b);
}

macro bool @physical_specular_in_range(PhysicalParams #params) @private {
    return #params.ior >= 1 && math::is_finite(#params.ior)
        && @in_unit_interval(#params.specular) && @rgb_nonnegative_finite(#params.specular_color);
}

macro bool @physical_anisotropy_in_range(PhysicalParams #params) @private {
    return @in_unit_interval(#params.anisotropy) && math::is_finite(#params.anisotropy_rotation);
}

macro bool @physical_volume_in_range(PhysicalParams #params) @private {
    return @in_unit_interval(#params.transmission)
        && #params.thickness >= 0 && math::is_finite(#params.thickness)
        && #params.attenuation_distance >= 0 && math::is_finite(#params.attenuation_distance)
        && @rgb_in_unit_interval(#params.attenuation_color);
}

macro bool @standard_params_in_range(StandardParams #params) @private {
    return @rgb_in_unit_interval(#params.base_color) && @in_unit_interval(#params.base_color.a)
        && @in_unit_interval(#params.metallic) && @in_unit_interval(#params.roughness)
        && @in_unit_interval(#params.occlusion_strength)
        && #params.emissive.r >= 0 && #params.emissive.g >= 0 && #params.emissive.b >= 0
        && #params.emissive_strength >= 0;
}

macro bool @standard_params_finite(StandardParams #params) @private {
    return math::is_finite(#params.emissive.r) && math::is_finite(#params.emissive.g)
        && math::is_finite(#params.emissive.b) && math::is_finite(#params.emissive_strength)
        && math::is_finite(#params.normal_scale);
}
