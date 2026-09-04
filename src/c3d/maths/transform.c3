module c3d::maths;

import std::math;

<*
 Position, rotation and scale of a node in its parent's space.
*>
struct Transform
{
    Vec3 position;
    Quat rotation;
    Vec3 scale;
}

<*
 Transform that leaves every point where it is.
*>
const Transform TRANSFORM_IDENTITY = {
    .position = { 0, 0, 0 },
    .rotation = { 0, 0, 0, 1 },
    .scale    = { 1, 1, 1 },
};

<*
 Compose the transform into a model matrix.
*>
fn Mat4 Transform.to_mat4(self)
{
    Mat4 translated = matrix::IDENTITY4.translate(self.position);
    Mat4 rotated = translated.mul(self.rotation.to_matrix());
    return rotated.scale(self.scale);
}

fn Mat3 inverse_upper3(Mat4 model) @private
{
    Vec3 column_x = { model.m00, model.m10, model.m20 };
    Vec3 column_y = { model.m01, model.m11, model.m21 };
    Vec3 column_z = { model.m02, model.m12, model.m22 };

    Vec3 row_x = column_y.cross(column_z);
    Vec3 row_y = column_z.cross(column_x);
    Vec3 row_z = column_x.cross(column_y);

    float inverse_determinant = 1.0f / column_x.dot(row_x);
    row_x = row_x * inverse_determinant;
    row_y = row_y * inverse_determinant;
    row_z = row_z * inverse_determinant;

    return {
        .m00 = row_x.x, .m01 = row_x.y, .m02 = row_x.z,
        .m10 = row_y.x, .m11 = row_y.y, .m12 = row_y.z,
        .m20 = row_z.x, .m21 = row_z.y, .m22 = row_z.z,
    };
}

<*
 Inverse of an affine matrix, for view and joint matrices.
 @require model.m30 == 0 && model.m31 == 0 && model.m32 == 0
*>
fn Mat4 inverse_affine(Mat4 model)
{
    Mat3 rotation = inverse_upper3(model);
    Vec3 offset = { model.m03, model.m13, model.m23 };

    Vec3 row_x = { rotation.m00, rotation.m01, rotation.m02 };
    Vec3 row_y = { rotation.m10, rotation.m11, rotation.m12 };
    Vec3 row_z = { rotation.m20, rotation.m21, rotation.m22 };

    return {
        .m00 = row_x.x, .m01 = row_x.y, .m02 = row_x.z, .m03 = -row_x.dot(offset),
        .m10 = row_y.x, .m11 = row_y.y, .m12 = row_y.z, .m13 = -row_y.dot(offset),
        .m20 = row_z.x, .m21 = row_z.y, .m22 = row_z.z, .m23 = -row_z.dot(offset),
        .m30 = 0,       .m31 = 0,       .m32 = 0,       .m33 = 1,
    };
}

<*
 Matrix that keeps normals perpendicular under non-uniform scale.
*>
fn Mat3 normal_matrix(Mat4 model)
{
    Mat3 inverse = inverse_upper3(model);
    return inverse.transpose();
}

<*
 Translation column of a matrix.
*>
fn Vec3 translation(Mat4 model)
{
    return { model.m03, model.m13, model.m23 };
}

<*
 Apply the matrix to a point, including its translation.
*>
fn Vec3 transform_point(Mat4 model, Vec3 point)
{
    Vec4 result = model.apply({ point.x, point.y, point.z, 1 });
    return { result.x, result.y, result.z };
}

<*
 Apply the matrix to a direction, ignoring its translation.
*>
fn Vec3 transform_dir(Mat4 model, Vec3 direction)
{
    Vec4 result = model.apply({ direction.x, direction.y, direction.z, 0 });
    return { result.x, result.y, result.z };
}

<*
 Rotation whose forward axis points along the given direction.
 @require forward.length() > 0 && up.length() > 0
*>
fn Quat look_rotation(Vec3 forward, Vec3 up)
{
    Vec3 axis_z = -forward.normalize();
    Vec3 axis_x = up.cross(axis_z).normalize();
    Vec3 axis_y = axis_z.cross(axis_x);

    float trace = axis_x.x + axis_y.y + axis_z.z;
    if (trace > 0) {
        float scale = math::sqrt(trace + 1.0f) * 2.0f;
        return {
            (axis_y.z - axis_z.y) / scale,
            (axis_z.x - axis_x.z) / scale,
            (axis_x.y - axis_y.x) / scale,
            0.25f * scale,
        };
    }
    if (axis_x.x > axis_y.y && axis_x.x > axis_z.z) {
        float scale = math::sqrt(1.0f + axis_x.x - axis_y.y - axis_z.z) * 2.0f;
        return {
            0.25f * scale,
            (axis_y.x + axis_x.y) / scale,
            (axis_z.x + axis_x.z) / scale,
            (axis_y.z - axis_z.y) / scale,
        };
    }
    if (axis_y.y > axis_z.z) {
        float scale = math::sqrt(1.0f + axis_y.y - axis_x.x - axis_z.z) * 2.0f;
        return {
            (axis_y.x + axis_x.y) / scale,
            0.25f * scale,
            (axis_z.y + axis_y.z) / scale,
            (axis_z.x - axis_x.z) / scale,
        };
    }
    float scale = math::sqrt(1.0f + axis_z.z - axis_x.x - axis_y.y) * 2.0f;
    return {
        (axis_z.x + axis_x.z) / scale,
        (axis_z.y + axis_y.z) / scale,
        0.25f * scale,
        (axis_x.y - axis_y.x) / scale,
    };
}
