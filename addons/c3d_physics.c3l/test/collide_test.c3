module c3d_physics_collide_test;

import std::math;
import std::math::quaternion;
import c3d::maths;
import c3d::physics::collide;
import b3;

alias Quat @private = Quaternionf;

const float TOLERANCE @private = 1e-4f;
const float LOOSE @private = 1e-3f;
const float LINEAR_SLOP @private = 0.005f; // box3d's contact target; casts and sweeps stop within it
const Vec3 FAR @private = { 10, 0, 0 };
const Vec3 SLAB_HALF_EXTENTS @private = { 1, 0.5f, 0.25f };

fn Quat rotated() @private => quaternion::from_axis_angle{float}({ 0, 0, 1 }, (float)math::PI / 2);

fn maths::Transform posed(Vec3 position, Quat rotation = { 0, 0, 0, 1 }) @private {
    return { .position = position, .rotation = rotation, .scale = { 1, 1, 1 } };
}

fn Shape slab() @private => collide::box_shape(SLAB_HALF_EXTENTS);

fn bool near(float a, float b, float tolerance = TOLERANCE) @private => math::abs(a - b) <= tolerance;

fn bool near_vector(Vec3 a, Vec3 b, float tolerance = TOLERANCE) @private {
    return near(a.x, b.x, tolerance) && near(a.y, b.y, tolerance) && near(a.z, b.z, tolerance);
}

fn void test_overlapping_spheres_give_one_point_with_negative_separation() @test {
    collide::Manifold found = collide::manifold(
        a:      collide::sphere_shape(1),
        pose_a: posed({ 0, 0, 0 }),
        b:      collide::sphere_shape(1),
        pose_b: posed({ 1.5f, 0, 0 }),
    );
    assert(found.count == 1);
    assert(near(found.points[0].separation, -0.5f));
    assert(near_vector(found.normal, { 1, 0, 0 }));
}

fn void test_manifold_normal_follows_argument_order() @test {
    Shape sphere = collide::sphere_shape(0.5f);
    collide::Manifold forward = collide::manifold(
        a:      slab(),
        pose_a: posed(FAR, rotated()),
        b:      sphere,
        pose_b: posed({ 10, 1.4f, 0 }),
    );
    collide::Manifold backward = collide::manifold(
        a:      sphere,
        pose_a: posed({ 10, 1.4f, 0 }),
        b:      slab(),
        pose_b: posed(FAR, rotated()),
    );
    assert(near_vector(forward.normal, { 0, 1, 0 }));
    assert(near_vector(backward.normal, { 0, -1, 0 }));
    assert(forward.count == backward.count && forward.count > 0);
    for (uint index = 0; index < forward.count; index++) {
        assert(near_vector(forward.points[index].point, backward.points[index].point, LOOSE));
    }
}

fn void test_manifold_reports_world_space_for_a_moved_rotated_a() @test {
    collide::Manifold found = collide::manifold(
        a:      slab(),
        pose_a: posed(FAR, rotated()),
        b:      collide::sphere_shape(0.5f),
        pose_b: posed({ 10, 1.4f, 0 }),
    );
    assert(found.count >= 1);
    assert(near_vector(found.normal, { 0, 1, 0 }));
    for (uint index = 0; index < found.count; index++) {
        assert(near(found.points[index].separation, -0.1f, LOOSE));
        assert(found.points[index].point.y >= 0.9f - LOOSE && found.points[index].point.y <= 1.0f + LOOSE);
        assert(near(found.points[index].point.x, 10, LOOSE));
    }
}

fn void test_capsule_on_a_box_gives_up_to_four_points() @test {
    Quat lying = quaternion::from_axis_angle{float}({ 0, 0, 1 }, (float)math::PI / 2);
    collide::Manifold found = collide::manifold(
        a:      collide::box_shape({ 2, 0.5f, 2 }),
        pose_a: posed({ 0, 0, 0 }),
        b:      collide::capsule_shape(0.5f, 0.25f),
        pose_b: posed({ 0, 0.74f, 0 }, lying),
    );
    assert(found.count >= 1 && found.count <= collide::MAX_MANIFOLD_POINTS);
    for (uint index = 0; index < found.count; index++) {
        assert(near(found.points[index].point.y, 0.5f, 0.01f));
        assert(found.points[index].separation < 0);
    }
}

fn void test_distance_between_separated_boxes_equals_the_gap() @test {
    Shape cube = collide::box_shape({ 0.5f, 0.5f, 0.5f });
    Distance gap = collide::distance(
        a:      cube,
        pose_a: posed({ 0, 0, 0 }),
        b:      cube,
        pose_b: posed({ 3, 0, 0 }),
    );
    assert(near(gap.distance, 2));
    assert(near(gap.point_a.x, 0.5f));
    assert(near(gap.point_b.x, 2.5f));
}

fn void test_distance_reports_world_space_for_a_moved_rotated_a() @test {
    Distance gap = collide::distance(
        a:      slab(),
        pose_a: posed(FAR, rotated()),
        b:      collide::sphere_shape(0.5f),
        pose_b: posed({ 10, 3.5f, 0 }),
    );
    assert(near(gap.distance, 2));
    assert(near_vector(gap.point_a, { 10, 1, 0 }));
    assert(near_vector(gap.point_b, { 10, 3, 0 }));
    assert(near_vector(gap.normal, { 0, 1, 0 }));
}

fn void test_distance_reports_zero_when_overlapping() @test {
    Distance gap = collide::distance(
        a:      slab(),
        pose_a: posed(FAR, rotated()),
        b:      collide::sphere_shape(0.5f),
        pose_b: posed({ 10, 0.8f, 0 }),
    );
    assert(gap.distance == 0);
}

fn void test_cast_sphere_into_box_reports_the_contact_time() @test {
    Impact impact = collide::cast(
        a:           collide::box_shape({ 0.5f, 0.5f, 0.5f }),
        pose_a:      posed({ 0, 0, 0 }),
        b:           collide::sphere_shape(0.5f),
        pose_b:      posed({ -3, 0, 0 }),
        translation: { 6, 0, 0 },
    )!!;
    assert(near(impact.time, (3 - 0.5f - 0.5f) / 6, LOOSE));
    assert(near_vector(impact.normal, { -1, 0, 0 }));
}

fn void test_cast_reports_world_space_for_a_moved_rotated_a() @test {
    Impact impact = collide::cast(
        a:           slab(),
        pose_a:      posed(FAR, rotated()),
        b:           collide::sphere_shape(0.5f),
        pose_b:      posed({ 7, 0, 0 }),
        translation: { 6, 0, 0 },
    )!!;
    assert(near(impact.time, (9.5f - 0.5f - 7) / 6, LOOSE));
    assert(near(impact.point.x, 9.5f, LOOSE));
    assert(near_vector(impact.normal, { -1, 0, 0 }));
}

fn void test_cast_from_an_overlapped_start_reports_time_zero() @test {
    Impact impact = collide::cast(
        a:           slab(),
        pose_a:      posed(FAR, rotated()),
        b:           collide::sphere_shape(0.5f),
        pose_b:      posed({ 10, 0.8f, 0 }),
        translation: { 1, 0, 0 },
    )!!;
    assert(impact.time == 0);
    assert(impact.normal == (Vec3){ 0, 0, 0 });
}

fn void test_cast_miss_faults_no_hit() @test {
    if (catch excuse = collide::cast(
        a:           slab(),
        pose_a:      posed(FAR, rotated()),
        b:           collide::sphere_shape(0.5f),
        pose_b:      posed({ 7, 5, 0 }),
        translation: { 6, 0, 0 },
    )) {
        assert(excuse == b3::NO_HIT);
        return;
    }
    assert(false);
}

fn void test_time_of_impact_reports_world_space() @test {
    collide::Sweep resting = { .start = posed(FAR, rotated()), .end = posed(FAR, rotated()) };
    collide::Sweep moving = { .start = posed({ 7, 0, 0 }), .end = posed({ 13, 0, 0 }) };
    Impact impact = collide::time_of_impact(
        a:       slab(),
        sweep_a: resting,
        b:       collide::sphere_shape(0.5f),
        sweep_b: moving,
    )!!;
    assert(near(impact.time, (9.5f - 0.5f - 7) / 6, LOOSE));
    assert(near(impact.point.x, 9.5f, LINEAR_SLOP));
    assert(near_vector(impact.normal, { -1, 0, 0 }, LOOSE));
}

fn void test_time_of_impact_separated_faults_no_hit() @test {
    collide::Sweep resting = { .start = posed(FAR, rotated()), .end = posed(FAR, rotated()) };
    collide::Sweep moving = { .start = posed({ 7, 5, 0 }), .end = posed({ 13, 5, 0 }) };
    if (catch excuse = collide::time_of_impact(
        a:       slab(),
        sweep_a: resting,
        b:       collide::sphere_shape(0.5f),
        sweep_b: moving,
    )) {
        assert(excuse == b3::NO_HIT);
        return;
    }
    assert(false);
}

fn void test_ray_cast_hits_the_capsule_cap() @test {
    ShapeRayHit hit = collide::ray_cast(
        shape:        collide::capsule_shape(1, 0.5f),
        pose:         posed({ 0, 0, 0 }),
        origin:       { 0, 5, 0 },
        direction:    { 0, -1, 0 },
        max_distance: 10,
    )!!;
    assert(near(hit.fraction, (5 - 1.5f) / 10));
    assert(near_vector(hit.point, { 0, 1.5f, 0 }));
    assert(near_vector(hit.normal, { 0, 1, 0 }));
}

fn void test_ray_cast_respects_the_pose() @test {
    ShapeRayHit hit = collide::ray_cast(
        shape:        slab(),
        pose:         posed(FAR, rotated()),
        origin:       { 10, 5, 0 },
        direction:    { 0, -1, 0 },
        max_distance: 10,
    )!!;
    assert(near(hit.fraction, (5 - 1.0f) / 10));
    assert(near_vector(hit.point, { 10, 1, 0 }));
    assert(near_vector(hit.normal, { 0, 1, 0 }));
}

fn void test_ray_cast_from_inside_reports_fraction_zero() @test {
    ShapeRayHit hit = collide::ray_cast(
        shape:        slab(),
        pose:         posed(FAR, rotated()),
        origin:       FAR,
        direction:    { 0, -1, 0 },
        max_distance: 10,
    )!!;
    assert(hit.fraction == 0);
    assert(hit.normal == (Vec3){ 0, 0, 0 });
}

fn void test_ray_cast_miss_faults_no_hit() @test {
    if (catch excuse = collide::ray_cast(
        shape:        slab(),
        pose:         posed(FAR, rotated()),
        origin:       { 10, 5, 5 },
        direction:    { 0, -1, 0 },
        max_distance: 10,
    )) {
        assert(excuse == b3::NO_HIT);
        return;
    }
    assert(false);
}

fn void test_create_hull_cooks_from_points() @test {
    Vec3[8] corners;
    for (uint corner = 0; corner < 8; corner++) {
        Vec3 sign = { corner & 1 ? 1 : -1, corner & 2 ? 1 : -1, corner & 4 ? 1 : -1 };
        corners[corner] = SLAB_HALF_EXTENTS * sign;
    }
    Hull hull = collide::create_hull(corners[..])!!;
    defer collide::destroy_hull(&hull);

    Shape sphere = collide::sphere_shape(0.5f);
    Distance cooked = collide::distance(
        a:      collide::hull_shape(&hull),
        pose_a: posed(FAR, rotated()),
        b:      sphere,
        pose_b: posed({ 10, 3.5f, 0 }),
    );
    Distance boxed = collide::distance(
        a:      slab(),
        pose_a: posed(FAR, rotated()),
        b:      sphere,
        pose_b: posed({ 10, 3.5f, 0 }),
    );
    assert(near(cooked.distance, boxed.distance));
    assert(near_vector(cooked.point_a, boxed.point_a));
}

fn void test_create_hull_faults_on_degenerate_points() @test {
    Vec3[3] three = { { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 } };
    Vec3[4] coplanar = { { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 }, { 1, 1, 0 } };
    Vec3[][3] inputs = { three[..], {}, coplanar[..] };
    foreach (points : inputs) {
        if (catch excuse = collide::create_hull(points)) {
            assert(excuse == b3::DEGENERATE_GEOMETRY);
            continue;
        }
        assert(false);
    }
}

fn void test_unit_scale_accepts_a_decomposed_world_pose() @test {
    maths::Transform decomposed = maths::transform_from_mat4(posed(FAR, rotated()).to_mat4());
    assert(collide::unit_scale(decomposed));
    assert(!collide::unit_scale({ .position = FAR, .rotation = rotated(), .scale = { 1, 1.1f, 1 } }));
}
