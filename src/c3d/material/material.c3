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

<*
 Shading family of a material.
*>
enum MaterialKind {
    BASIC,
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
 Unlit color.
*>
struct BasicParams {
    Vec4 color;
}

<*
 Material description; the kind selects which parameters are read.
*>
struct Material {
    MaterialKind   kind;
    MaterialCommon common;
    BasicParams    basic;
}

<*
 Unlit material.
*>
fn Material basic(BasicParams params, MaterialCommon common = MATERIAL_COMMON_DEFAULT) {
    return { .kind = MaterialKind.BASIC, .common = common, .basic = params };
}
