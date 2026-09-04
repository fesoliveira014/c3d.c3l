module c3d::test::bounds;

import c3d::maths;
import std::math;

const float TOLERANCE @local = 0.0005f;

fn Aabb point_box(Vec3 point) @local
{
    return { .min = point, .max = point };
}

fn Frustum default_frustum() @local
{
    Mat4 view = matrix::look_at{float}({ 0, 0, 0 }, { 0, 0, -1 }, { 0, 1, 0 });
    Mat4 projection = maths::perspective_reverse_z(
        fov_y:  math::PI / 3,
        aspect: 2.0f,
        near:   0.1f,
        far:    100.0f,
    );
    return maths::frustum_from_view_proj(projection.mul(view));
}

fn void test_aabb_merge_covers_both() @test
{
    Aabb first = { .min = { -1, -1, -1 }, .max = { 1, 1, 1 } };
    Aabb second = { .min = { 0, 2, -3 }, .max = { 4, 3, 0 } };
    Aabb merged = maths::aabb_merge(first, second);

    assert(merged.min.x == -1 && merged.min.y == -1 && merged.min.z == -3);
    assert(merged.max.x == 4 && merged.max.y == 3 && merged.max.z == 1);
}

fn void test_aabb_transform_of_identity_is_unchanged() @test
{
    Aabb bounds = { .min = { -1, -2, -3 }, .max = { 4, 5, 6 } };
    Aabb result = maths::aabb_transform(bounds, matrix::IDENTITY4);

    assert(math::abs(result.min.x - bounds.min.x) <= TOLERANCE);
    assert(math::abs(result.max.z - bounds.max.z) <= TOLERANCE);
}

fn void test_aabb_transform_covers_rotated_corners() @test
{
    Aabb bounds = { .min = { -1, -1, -1 }, .max = { 1, 1, 1 } };
    Transform transform = {
        .position = { 0, 0, 0 },
        .rotation = quaternion::from_axis_angle{float}({ 0, 0, 1 }, math::PI / 4),
        .scale    = { 1, 1, 1 },
    };
    Mat4 model = transform.to_mat4();
    Aabb result = maths::aabb_transform(bounds, model);

    // A unit cube turned 45 degrees about Z spans sqrt(2) in x and y.
    assert(math::abs(result.max.x - math::sqrt(2.0f)) <= TOLERANCE);
    assert(math::abs(result.max.y - math::sqrt(2.0f)) <= TOLERANCE);
    assert(math::abs(result.max.z - 1.0f) <= TOLERANCE);
}

fn void test_ray_hits_box_ahead() @test
{
    Ray ray = { .origin = { 0, 0, 0 }, .direction = { 0, 0, -1 } };
    Aabb bounds = { .min = { -1, -1, -6 }, .max = { 1, 1, -4 } };
    float distance;

    assert(maths::ray_intersects_aabb(ray, bounds, &distance));
    assert(math::abs(distance - 4.0f) <= TOLERANCE);
}

fn void test_ray_misses_box_beside_it() @test
{
    Ray ray = { .origin = { 5, 0, 0 }, .direction = { 0, 0, -1 } };
    Aabb bounds = { .min = { -1, -1, -6 }, .max = { 1, 1, -4 } };
    float distance = -1;

    assert(!maths::ray_intersects_aabb(ray, bounds, &distance));
    assert(distance == -1, "a miss must leave the distance untouched");
}

fn void test_ray_from_inside_hits() @test
{
    Ray ray = { .origin = { 0, 0, 0 }, .direction = { 1, 0, 0 } };
    Aabb bounds = { .min = { -1, -1, -1 }, .max = { 1, 1, 1 } };
    float distance;

    assert(maths::ray_intersects_aabb(ray, bounds, &distance));
    assert(math::abs(distance) <= TOLERANCE);
}

fn void test_frustum_contains_point_in_view() @test
{
    Frustum frustum = default_frustum();
    assert(maths::frustum_intersects_aabb(&frustum, point_box({ 0, 0, -5 })));
}

fn void test_frustum_rejects_point_behind_camera() @test
{
    Frustum frustum = default_frustum();
    assert(!maths::frustum_intersects_aabb(&frustum, point_box({ 0, 0, 5 })));
}

fn void test_frustum_rejects_box_beyond_far_plane() @test
{
    Frustum frustum = default_frustum();
    Aabb bounds = { .min = { -1, -1, -210 }, .max = { 1, 1, -200 } };
    assert(!maths::frustum_intersects_aabb(&frustum, bounds));
}

fn void test_frustum_accepts_straddling_box() @test
{
    Frustum frustum = default_frustum();
    Aabb bounds = { .min = { -1, -1, -110 }, .max = { 1, 1, -90 } };
    assert(maths::frustum_intersects_aabb(&frustum, bounds));
}

fn void test_frustum_rejects_point_closer_than_near() @test
{
    Frustum frustum = default_frustum();
    assert(!maths::frustum_intersects_aabb(&frustum, point_box({ 0, 0, -0.05f })));
}

fn void test_frustum_rejects_point_outside_the_field_of_view() @test
{
    Frustum frustum = default_frustum();
    assert(!maths::frustum_intersects_aabb(&frustum, point_box({ 100, 0, -5 })));
    assert(!maths::frustum_intersects_aabb(&frustum, point_box({ -100, 0, -5 })));
    assert(!maths::frustum_intersects_aabb(&frustum, point_box({ 0, 100, -5 })));
    assert(!maths::frustum_intersects_aabb(&frustum, point_box({ 0, -100, -5 })));
}

fn void test_frustum_is_wider_than_it_is_tall() @test
{
    // Aspect 2 puts the horizontal half-angle at twice the vertical tangent, so a
    // point three units off-axis is inside horizontally and outside vertically.
    Frustum frustum = default_frustum();
    assert(maths::frustum_intersects_aabb(&frustum, point_box({ 3, 0, -5 })));
    assert(!maths::frustum_intersects_aabb(&frustum, point_box({ 0, 3, -5 })));
}
