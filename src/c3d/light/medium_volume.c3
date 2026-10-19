module c3d::light;

import std::math;

<*
 Box of participating medium hanging below its node's local XZ plane.
*>
struct MediumVolume {
    Vec3  absorption;  // 1/m per channel
    Vec3  scattering;  // 1/m per channel
    float anisotropy;  // Henyey-Greenstein g of the sun term, in (-1, 1)
    Vec2  center;      // local x and z of the box centre, metres
    Vec2  half_extent; // local x and z, metres
    float depth;       // local metres below the top face
}

<*
 Whether the medium volume can be drawn.
 @param [&in] medium : "Component to check."
 @pure
*>
fn bool medium_volume_valid(MediumVolume* medium) {
    Vec3[2] coefficients = { medium.absorption, medium.scattering };
    foreach (coefficient : coefficients) {
        foreach (channel : coefficient) {
            if (!math::is_finite(channel) || channel < 0) return false;
        }
    }
    if (!math::is_finite(medium.center.x) || !math::is_finite(medium.center.y)) return false;

    float[3] sizes = { medium.half_extent.x, medium.half_extent.y, medium.depth };
    foreach (size : sizes) {
        if (!math::is_finite(size) || size <= 0) return false;
    }
    return math::is_finite(medium.anisotropy) && math::abs(medium.anisotropy) < 1;
}
