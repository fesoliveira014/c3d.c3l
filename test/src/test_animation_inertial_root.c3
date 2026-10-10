module c3d::test::inertial_root;

import c3d::anim @public;
import c3d::maths;
import std::math;

fn void test_animation_inertial_root_source_final_rate_zero_step_and_discrete_decay() @test {
    InertialRow row = {
        .control = { .active = true, .duration = 1 },
        .root = {
            .source_translation_rate = { 4, 2, -1 },
            .source_twist_rate = 2,
            .target_rate_pending = true,
        },
    };
    RootMotionDelta target = { .translation = { 0.1f, 0, 0 }, .rotation = quaternion::IDENTITY };
    RootMotionDelta zero = anim::publish_inertial_root_motion(
        row: &row,
        target: {},
        target_twist: 0,
        up: { 0, 1, 0 },
        pivot: { 1, 0, 2 },
        dt: 0,
    );
    assert(zero.translation == (Vec3){} && row.root.target_rate_pending);
    row.control.elapsed = 0.5;
    RootMotionDelta actual = anim::publish_inertial_root_motion(
        row: &row,
        target: target,
        target_twist: 0.05,
        up: { 0, 1, 0 },
        pivot: { 1, 0, 2 },
        dt: 0.1,
    );
    double expected_x = (double)target.translation.x + (4 - (double)target.translation.x / 0.1) * 0.05;
    assert(math::abs((double)actual.translation.x - expected_x) < 3e-8);
    assert(math::abs(actual.translation.y - 0.1f) < 1e-8);
    assert(math::abs(actual.translation.z + 0.05f) < 1e-8);
    assert(math::abs(row.root.published_twist - 0.125) < 1e-15);
    assert(row.root.translation_rate.x == (double)actual.translation.x / 0.1);
    assert(!row.root.target_rate_pending);
    row.control.active = false;
    RootMotionDelta finished = anim::publish_inertial_root_motion(
        row: &row,
        target: target,
        target_twist: 0.05,
        up: { 0, 1, 0 },
        pivot: { 1, 0, 2 },
        dt: 0.1,
    );
    assert(finished.translation == target.translation && finished.rotation.v == target.rotation.v);
}
