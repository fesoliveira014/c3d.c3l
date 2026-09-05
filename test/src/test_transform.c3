module c3d::test::transform;

import c3d::maths;
import std::math;

const float TOLERANCE @local = 0.0005f;

fn bool close(float first, float second) @local {
    return math::abs(first - second) <= TOLERANCE;
}

fn bool close_vec3(Vec3 first, Vec3 second) @local {
    return close(first.x, second.x) && close(first.y, second.y) && close(first.z, second.z);
}

fn bool close_mat4(Mat4 first, Mat4 second) @local {
    for (usz index = 0; index < 16; index++) {
        if (!close(first.m[index], second.m[index])) return false;
    }
    return true;
}

fn void test_identity_transform_is_identity_matrix() @test {
    assert(close_mat4(maths::TRANSFORM_IDENTITY.to_mat4(), matrix::IDENTITY4));
}

fn void test_to_mat4_places_translation() @test {
    Transform transform = {
        .position = { 1, 2, 3 },
        .rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, math::PI / 4),
        .scale    = { 2, 2, 2 },
    };
    assert(close_vec3(maths::translation(transform.to_mat4()), { 1, 2, 3 }));
}

fn void test_to_mat4_scales_before_rotating() @test {
    Transform transform = {
        .position = { 1, 2, 3 },
        .rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, math::PI / 2),
        .scale    = { 2, 1, 1 },
    };
    // Scale then rotate then translate sends +X to -Z, so the doubled x lands on z.
    Vec3 moved = maths::transform_point(transform.to_mat4(), { 1, 0, 0 });
    assert(close_vec3(moved, { 1, 2, 1 }), "composition order is not translate, rotate, scale");
}

fn void test_inverse_affine_matches_general_inverse() @test {
    Transform[3] cases = {
        {
            .position = { 1, 2, 3 },
            .rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, math::PI / 3),
            .scale    = { 1, 1, 1 },
        },
        {
            .position = { -4, 0.5f, 2 },
            .rotation = quaternion::from_axis_angle{float}(((Vec3){ 1, 1, 0 }).normalize(), 1.1f),
            .scale    = { 2, 3, 0.5f },
        },
        {
            .position = { 0, 0, 0 },
            .rotation = quaternion::from_euler{float}(0.3f, -0.7f, 1.2f),
            .scale    = { 1.5f, 1.5f, 1.5f },
        },
    };

    foreach (transform : cases) {
        Mat4 model = transform.to_mat4();
        Mat4 general = model.inverse()!!;
        assert(close_mat4(maths::inverse_affine(model), general));
    }
}

fn void test_inverse_affine_round_trips_a_point() @test {
    Transform transform = {
        .position = { 3, -1, 4 },
        .rotation = quaternion::from_euler{float}(0.2f, 0.9f, -0.4f),
        .scale    = { 2, 0.5f, 1.25f },
    };
    Mat4 model = transform.to_mat4();
    Vec3 point = { 1, 2, 3 };

    Vec3 there = maths::transform_point(model, point);
    Vec3 back = maths::transform_point(maths::inverse_affine(model), there);
    assert(close_vec3(back, point));
}

fn void test_normal_matrix_keeps_normals_perpendicular() @test {
    Transform transform = {
        .position = { 0, 0, 0 },
        .rotation = quaternion::from_axis_angle{float}({ 0, 0, 1 }, 0.6f),
        .scale    = { 3, 1, 0.5f },
    };
    Mat4 model = transform.to_mat4();

    Vec3 tangent = { 1, 0, 0 };
    Vec3 normal = { 0, 1, 0 };

    Vec3 moved_tangent = maths::transform_dir(model, tangent);
    Mat3 normals = maths::normal_matrix(model);
    Vec3 moved_normal = normals.apply(normal);

    assert(close(moved_tangent.normalize().dot(moved_normal.normalize()), 0));
}

fn void test_look_rotation_faces_the_target() @test {
    Vec3 forward = { 1, -2, 3 };
    Quat rotation = maths::look_rotation(forward, { 0, 1, 0 });
    Vec3 pointed = rotation * (Vec3){ 0, 0, -1 };
    assert(close_vec3(pointed, forward.normalize()));
}

fn void test_mat4_is_64_bytes() @test {
    assert(Mat4::size == 64, "every GPU root struct assumes a 64-byte Mat4");
}

fn void test_to_mat4_decomposes_back() @test {
    Transform transform = {
        .position = { 3, -1, 4 },
        .rotation = quaternion::from_euler{float}(0.2f, 0.9f, -0.4f),
        .scale    = { 2, 0.5f, 1.25f },
    };
    Mat4 model = transform.to_mat4();

    Vec3 column_x = { model.m00, model.m10, model.m20 };
    Vec3 column_y = { model.m01, model.m11, model.m21 };
    Vec3 column_z = { model.m02, model.m12, model.m22 };

    assert(close_vec3(maths::translation(model), transform.position));
    assert(close(column_x.length(), transform.scale.x));
    assert(close(column_y.length(), transform.scale.y));
    assert(close(column_z.length(), transform.scale.z));

    // Dividing the scale out of the columns leaves the rotation the quaternion describes.
    Vec3 point = { 0.3f, -0.7f, 0.55f };
    Vec3 by_columns = column_x.normalize() * point.x
                    + column_y.normalize() * point.y
                    + column_z.normalize() * point.z;
    assert(close_vec3(by_columns, transform.rotation * point));
}
