module c3d::render;

import c3d::camera;
import c3d::shader;
import std::math;

<* Maximum punctual shadow near plane in world units. *>
const float PUNCTUAL_SHADOW_NEAR_CAP = 0.05f; // clips close casters to retain far-depth precision

<* Fraction of punctual shadow range used for its near plane. *>
const float PUNCTUAL_SHADOW_NEAR_FRACTION = 0.01f; // keeps short ranges from clipping their full coverage

const Vec3[shader::SHADOW_POINT_FACE_COUNT] POINT_SHADOW_DIRECTIONS @private = {
    [shader::SHADOW_FACE_POSITIVE_X] = { 1, 0, 0 },
    [shader::SHADOW_FACE_NEGATIVE_X] = { -1, 0, 0 },
    [shader::SHADOW_FACE_POSITIVE_Y] = { 0, 1, 0 },
    [shader::SHADOW_FACE_NEGATIVE_Y] = { 0, -1, 0 },
    [shader::SHADOW_FACE_POSITIVE_Z] = { 0, 0, 1 },
    [shader::SHADOW_FACE_NEGATIVE_Z] = { 0, 0, -1 },
};
const Vec3[shader::SHADOW_POINT_FACE_COUNT] POINT_SHADOW_UP_VECTORS @private = {
    [shader::SHADOW_FACE_POSITIVE_X] = { 0, -1, 0 },
    [shader::SHADOW_FACE_NEGATIVE_X] = { 0, -1, 0 },
    [shader::SHADOW_FACE_POSITIVE_Y] = { 0, 0, 1 },
    [shader::SHADOW_FACE_NEGATIVE_Y] = { 0, 0, -1 },
    [shader::SHADOW_FACE_POSITIVE_Z] = { 0, -1, 0 },
    [shader::SHADOW_FACE_NEGATIVE_Z] = { 0, -1, 0 },
};

<*
 Derive a finite perspective shadow camera for a spot.
 @param position : "Finite world position of the light."
 @param direction : "Unit world direction of emitted light."
 @param outer_cone : "Outer half-angle in radians."
 @param shadow_range : "Finite radial coverage in world units."
 @require math::is_finite(position.x) && math::is_finite(position.y) && math::is_finite(position.z)
 @require math::abs(direction.length() - 1) < 0.0001f
 @require outer_cone > 0 && outer_cone < (float)math::PI / 2
 @require shadow_range > 0 && math::is_finite(shadow_range)
*>
fn CameraMatrices spot_shadow_camera(
    Vec3 position,
    Vec3 direction,
    float outer_cone,
    float shadow_range,
) {
    LightBasis basis = light_basis(direction);
    return perspective_shadow_camera(
        position: position,
        forward: direction,
        right: basis.right,
        up: basis.up,
        fov_y: 2 * outer_cone,
        shadow_range: shadow_range,
    );
}

<*
 Derive one finite world-aligned point shadow camera.
 @param position : "Finite world position of the light."
 @param face : "Generated shadow face index."
 @param shadow_range : "Finite radial coverage in world units."
 @require math::is_finite(position.x) && math::is_finite(position.y) && math::is_finite(position.z)
 @require face < shader::SHADOW_POINT_FACE_COUNT
 @require shadow_range > 0 && math::is_finite(shadow_range)
*>
fn CameraMatrices point_shadow_camera(Vec3 position, uint face, float shadow_range) {
    Vec3 forward = POINT_SHADOW_DIRECTIONS[face];
    Vec3 up = POINT_SHADOW_UP_VECTORS[face];
    return perspective_shadow_camera(
        position: position,
        forward: forward,
        right: forward.cross(up),
        up: up,
        fov_y: (float)math::PI / 2,
        shadow_range: shadow_range,
    );
}

fn CameraMatrices perspective_shadow_camera(
    Vec3 position,
    Vec3 forward,
    Vec3 right,
    Vec3 up,
    float fov_y,
    float shadow_range,
) @private {
    Mat4 world = {
        .m00 = right.x, .m01 = up.x, .m02 = -forward.x, .m03 = position.x,
        .m10 = right.y, .m11 = up.y, .m12 = -forward.y, .m13 = position.y,
        .m20 = right.z, .m21 = up.z, .m22 = -forward.z, .m23 = position.z,
        .m33 = 1,
    };
    float near = math::min(PUNCTUAL_SHADOW_NEAR_CAP, shadow_range * PUNCTUAL_SHADOW_NEAR_FRACTION);
    Camera camera = camera::perspective(fov_y, near, shadow_range);
    return camera::derive_matrices(camera, world, { 1, 1 });
}
