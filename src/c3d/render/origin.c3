module c3d::render;

import std::math;

const double FRAME_ORIGIN_CELL @private = 256.0; // larger cells reduce resident uploads and trace rebuilds

<*
 Select the nearest render cell for an absolute position.
 @require math::is_finite(reference_position.x)
 @require math::is_finite(reference_position.y)
 @require math::is_finite(reference_position.z)
 @pure
*>
fn Vec3 frame_origin_for(Vec3 reference_position) {
    return {
        (float)(math::floor((double)reference_position.x / FRAME_ORIGIN_CELL + 0.5) * FRAME_ORIGIN_CELL),
        (float)(math::floor((double)reference_position.y / FRAME_ORIGIN_CELL + 0.5) * FRAME_ORIGIN_CELL),
        (float)(math::floor((double)reference_position.z / FRAME_ORIGIN_CELL + 0.5) * FRAME_ORIGIN_CELL),
    };
}

fn Mat4 camera_clip_reprojection(
    Mat4 current_view_proj,
    Mat4 previous_view_proj,
    Vec3 previous_origin,
    Vec3 current_origin,
    Vec2 jitter,
) @private {
    Mat4 unjitter = matrix::IDENTITY4;
    unjitter.m03 = -jitter.x;
    unjitter.m13 = -jitter.y;
    if (current_view_proj == previous_view_proj && current_origin == previous_origin) return unjitter;

    Matrix4x4{double} current;
    Matrix4x4{double} previous;
    Matrix4x4{double} offset = { .m00 = 1, .m11 = 1, .m22 = 1, .m33 = 1 };
    Matrix4x4{double} shift;
    foreach (index, value : current_view_proj.m) current.m[index] = value;
    foreach (index, value : previous_view_proj.m) previous.m[index] = value;
    foreach (index, value : unjitter.m) shift.m[index] = value;
    offset.m03 = (double)current_origin.x - previous_origin.x;
    offset.m13 = (double)current_origin.y - previous_origin.y;
    offset.m23 = (double)current_origin.z - previous_origin.z;
    // Cancel the coordinate translations before narrowing the clip-space mapping.
    Matrix4x4{double} reprojection = previous.mul(offset).mul(current.inverse()!!).mul(shift);
    Mat4 result;
    foreach (index, value : reprojection.m) result.m[index] = (float)value;
    return result;
}
