module c3d::test::projection;

import c3d::maths;
import std::math;

const float TOLERANCE @local = 0.0005f;

fn float depth_at(Mat4 projection, float distance) @local {
    Vec4 clip = projection.apply({ 0, 0, -distance, 1 });
    return clip.z / clip.w;
}

fn Mat4 finite_perspective() @local {
    return maths::perspective_reverse_z(
        fov_y:  math::PI / 3,
        aspect: 1.0f,
        near:   0.1f,
        far:    100.0f,
    );
}

fn void test_perspective_maps_near_to_one() @test {
    assert(math::abs(depth_at(finite_perspective(), 0.1f) - 1.0f) <= TOLERANCE);
}

fn void test_perspective_maps_far_to_zero() @test {
    assert(math::abs(depth_at(finite_perspective(), 100.0f)) <= TOLERANCE);
}

fn void test_perspective_depth_is_monotonic() @test {
    Mat4 projection = finite_perspective();
    float previous = depth_at(projection, 0.1f);
    for (float distance = 0.2f; distance <= 100.0f; distance += 0.5f) {
        float current = depth_at(projection, distance);
        assert(current < previous, "reverse-Z depth must fall as a point recedes");
        previous = current;
    }
}

fn void test_infinite_perspective_maps_near_to_one() @test {
    Mat4 projection = maths::perspective_reverse_z(
        fov_y:  math::PI / 3,
        aspect: 1.6f,
        near:   0.05f,
    );
    assert(math::abs(depth_at(projection, 0.05f) - 1.0f) <= TOLERANCE);
}

fn void test_infinite_perspective_approaches_zero() @test {
    Mat4 projection = maths::perspective_reverse_z(
        fov_y:  math::PI / 3,
        aspect: 1.6f,
        near:   0.05f,
    );
    assert(depth_at(projection, 1000000.0f) < 0.0001f);
    assert(depth_at(projection, 1000000.0f) > 0);
}

fn void test_orthographic_maps_near_and_far() @test {
    Mat4 projection = maths::orthographic_reverse_z(
        left:   -10.0f,
        right:  10.0f,
        bottom: -5.0f,
        top:    5.0f,
        near:   1.0f,
        far:    50.0f,
    );
    assert(math::abs(depth_at(projection, 1.0f) - 1.0f) <= TOLERANCE);
    assert(math::abs(depth_at(projection, 50.0f)) <= TOLERANCE);
}
