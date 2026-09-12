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
    }
}

<*
 Unlit material.
*>
fn Material basic(BasicParams params, MaterialCommon common = MATERIAL_COMMON_DEFAULT) {
    return { .kind = MaterialKind.BASIC, .common = common, .basic = params };
}

<*
 Metallic-roughness material with optional texture maps.
 @require params.base_color.r >= 0, params.base_color.r <= 1
 @require params.base_color.g >= 0, params.base_color.g <= 1
 @require params.base_color.b >= 0, params.base_color.b <= 1
 @require params.base_color.a >= 0, params.base_color.a <= 1
 @require params.emissive.r >= 0, params.emissive.g >= 0, params.emissive.b >= 0
 @require math::is_finite(params.emissive.r), math::is_finite(params.emissive.g), math::is_finite(params.emissive.b)
 @require math::is_finite(params.emissive_strength)
 @require params.metallic >= 0, params.metallic <= 1
 @require params.roughness >= 0, params.roughness <= 1
 @require params.emissive_strength >= 0
 @require math::is_finite(params.normal_scale)
 @require params.occlusion_strength >= 0, params.occlusion_strength <= 1
 @pure
*>
fn Material standard(
    StandardParams params = STANDARD_PARAMS_DEFAULT,
    MaterialCommon common = MATERIAL_COMMON_DEFAULT,
) {
    return { .kind = STANDARD, .common = common, .standard = params };
}
