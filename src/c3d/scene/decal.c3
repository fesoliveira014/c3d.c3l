module c3d::scene;

import c3d;
import std::math;

<*
 Angle from the projection axis beyond which a decal contributes nothing, in radians.
*>
const float DEFAULT_DECAL_FADE_ANGLE = (float)math::PI * 4 / 9; // 80 degrees limits projection stretching.

<*
 Independent blend strengths for projected material channels.
*>
struct DecalWeights {
    float base_color;
    float normal;
    float roughness;
    float metallic;
}

<*
 Projected material volume attached to a scene node.
*>
struct Decal {
    MaterialId   material;
    DecalWeights weights;
    float        fade_angle;
    uint         receiver_layers;
    int          order;
}

<*
 Initial size and component of a decal node.
*>
struct DecalDesc {
    Vec3  size;
    Decal decal;
}

<*
 Unit box projecting the material with full weights onto every layer.
 @pure
*>
fn DecalDesc default_decal_desc(MaterialId material) {
    return {
        .size  = { 1, 1, 1 },
        .decal = {
            .material        = material,
            .weights         = { .base_color = 1, .normal = 1, .roughness = 1, .metallic = 1 },
            .fade_angle      = DEFAULT_DECAL_FADE_ANGLE,
            .receiver_layers = uint::max,
        },
    };
}

fn bool decal_desc_valid(DecalDesc* desc) @private {
    for (uint axis = 0; axis < 3; axis++) {
        if (!math::is_finite(desc.size[axis]) || desc.size[axis] <= 0) return false;
    }

    float[4] weights = {
        desc.decal.weights.base_color,
        desc.decal.weights.normal,
        desc.decal.weights.roughness,
        desc.decal.weights.metallic,
    };
    foreach (weight : weights) {
        if (!math::is_finite(weight) || weight < 0 || weight > 1) return false;
    }

    return math::is_finite(desc.decal.fade_angle)
      && desc.decal.fade_angle >= 0 && desc.decal.fade_angle <= (float)math::PI / 2;
}
