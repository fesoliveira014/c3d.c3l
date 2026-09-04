module c3d::maths;

import std::math;

<*
 Reverse-Z perspective projection; far 0 selects an infinite far plane.
 @require fov_y > 0 && aspect > 0 && near > 0
 @require far == 0 || far > near
*>
fn Mat4 perspective_reverse_z(float fov_y, float aspect, float near, float far = 0) {
    float focal = 1.0f / math::tan(fov_y * 0.5f);
    bool infinite = far == 0;
    return {
        .m00 = focal / aspect,
        .m11 = focal,
        .m22 = infinite ? 0 : near / (far - near),
        .m23 = infinite ? near : far * near / (far - near),
        .m32 = -1,
    };
}

<*
 Reverse-Z orthographic projection.
 @require right > left && top > bottom && far > near
*>
fn Mat4 orthographic_reverse_z(float left, float right, float bottom, float top,
  float near, float far) {
    return {
        .m00 = 2.0f / (right - left),
        .m03 = -(right + left) / (right - left),
        .m11 = 2.0f / (top - bottom),
        .m13 = -(top + bottom) / (top - bottom),
        .m22 = 1.0f / (far - near),
        .m23 = far / (far - near),
        .m33 = 1,
    };
}
