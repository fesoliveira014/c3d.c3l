module c3d::scene;

import c3d;
import std::math;

<*
 Angle from the projection axis where decal fading ends, in radians.
*>
const float DEFAULT_DECAL_FADE_ANGLE = (float)math::PI * 4 / 9; // 80 degrees limits projection stretching.

<*
 Projected material volume attached to a scene node.
*>
struct Decal {
    MaterialId material;
    Vec4       weights;
    float      fade_angle;
    uint       layers;
    int        order;
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
            .material   = material,
            .weights    = { 1, 1, 1, 1 },
            .fade_angle = DEFAULT_DECAL_FADE_ANGLE,
            .layers     = uint::max,
        },
    };
}

<*
 Whether the description meets the component contract.
 @param [&in] desc : "Description to validate."
 @pure
*>
fn bool decal_desc_valid(DecalDesc* desc) {
    for (uint axis = 0; axis < 3; axis++) {
        if (!math::is_finite(desc.size[axis]) || desc.size[axis] <= 0) return false;
    }

    for (uint channel = 0; channel < 4; channel++) {
        float weight = desc.decal.weights[channel];
        if (!math::is_finite(weight) || weight < 0 || weight > 1) return false;
    }

    return math::is_finite(desc.decal.fade_angle)
      && desc.decal.fade_angle >= 0 && desc.decal.fade_angle <= (float)math::PI / 2;
}
