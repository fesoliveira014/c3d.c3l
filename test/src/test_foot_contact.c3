module c3d::test::ik;

import c3d;
import c3d::anim::ik;
import c3d::maths;
import c3d::scene;
import std::math;

const float CONTACT_TEST_POSITION_EPSILON @local = 1e-6f;
const float CONTACT_TEST_LENGTH_EPSILON @local = 1e-5f;
const float CONTACT_TEST_REBASE_EPSILON @local = 1e-4f;

struct ContactRig @local {
    Scene scene;
    Node* hip;
    Node* knee;
    Node* ankle;
    Node* target;
    Node* pole;
    FootIk foot;
}

fn Quat contact_test_rotation(Vec3 axis, float degrees) @local {
    return quaternion::from_axis_angle{float}(axis, degrees * (float)math::PI / 180);
}

fn Transform contact_test_pose(Vec3 position = { 0, 0.08f, 0 }) @local {
    Transform pose = maths::TRANSFORM_IDENTITY;
    pose.position = position;
    return pose;
}

fn FootSupport contact_test_support(float scale = 1) @local {
    return {
        .identity = 17,
        .kind = SUPPORT,
        .transform = {
            .rotation = quaternion::IDENTITY,
            .scale = { scale, scale, scale },
        },
    };
}

fn bool contact_test_vec(double[<3>] first, double[<3>] second, float epsilon = CONTACT_TEST_POSITION_EPSILON) @local {
    return (first - second).length() <= epsilon;
}

fn bool contact_test_quat(Quat first, Quat second) @local {
    return math::min((first.v - second.v).length(), (first.v + second.v).length()) <= 1e-6f;
}

fn bool contact_test_same_state(FootContact* first, FootContact* second) @local {
    return ((char*)first)[:FootContact::size] == ((char*)second)[:FootContact::size];
}

fn void contact_test_expect_update_fault(
    FootContact* contact,
    FootSupport support,
    Transform incoming,
    float dt,
    FootContactReason reason,
) @local {
    FootContact before = *contact;
    FootDiagnostic diagnostic;
    bool failed;
    if (catch excuse = contact.update_contact(
        support: support,
        incoming: incoming,
        dt: dt,
        diagnostic: &diagnostic,
    )) {
        failed = true;
        assert(excuse == c3d::INVALID_ARGUMENT);
        assert(diagnostic.reason == reason);
    }
    assert(failed);
    assert(contact_test_same_state(&before, contact));
}

fn ContactRig contact_test_rig(Allocator allocator = mem) @local {
    ContactRig rig = { .scene = scene::create_scene(allocator, { .max_nodes = 16 }) };
    rig.hip = rig.scene.add_node(name: "hip")!!;
    rig.knee = rig.scene.add_node(rig.hip, "knee")!!;
    rig.ankle = rig.scene.add_node(rig.knee, "ankle")!!;
    rig.target = rig.scene.add_node(name: "target")!!;
    rig.pole = rig.scene.add_node(name: "pole")!!;
    rig.hip.local.position = { 0, 1.4f, 0 };
    rig.knee.local.position = { 0, -0.7f, 0.2f };
    rig.ankle.local.position = { 0, -0.7f, -0.2f };
    rig.pole.local.position = { 0, 0.7f, 1 };
    rig.foot = ik::foot_ik(
        hip: rig.hip,
        knee: rig.knee,
        ankle: rig.ankle,
        target: rig.target,
        pole: rig.pole,
    );
    rig.scene.update_world();
    return rig;
}

fn void contact_test_incoming(ContactRig* rig, Vec3 offset = {}) @local {
    rig.hip.local.position = (Vec3){ 0, 1.4f, 0 } + offset;
    rig.hip.local.rotation = quaternion::IDENTITY;
    rig.knee.local.rotation = quaternion::IDENTITY;
    rig.ankle.local.rotation = quaternion::IDENTITY;
    rig.scene.update_world();
}

fn FootContactResult contact_test_solve(ContactRig* rig) @local {
    rig.scene.update_world();
    rig.foot.leg.solve();
    rig.scene.update_world();
    rig.foot.align_contact();
    rig.scene.update_world();
    float length = (Vec3){ 0, -0.7f, 0.2f }.length();
    assert(math::abs((rig.knee.world_position() - rig.hip.world_position()).length() - length)
        <= CONTACT_TEST_LENGTH_EPSILON);
    assert(math::abs((rig.ankle.world_position() - rig.knee.world_position()).length() - length)
        <= CONTACT_TEST_LENGTH_EPSILON);
    return rig.foot.contact_result();
}

fn void contact_test_advance_transition(
    FootContact* contact,
    FootSupport support,
    Transform* incoming,
    float duration,
    uint schedule,
) @local {
    float[3] fixed_steps = { 1.0f / 30, 1.0f / 60, 1.0f / 120 };
    float[3] variable_steps = { 1.0f / 120, 1.0f / 40, 1.0f / 60 };
    float elapsed;
    uint step;
    while (elapsed < duration) {
        float dt = schedule < 3 ? fixed_steps[schedule] : variable_steps[step % 3];
        dt = math::min(dt, duration - elapsed);
        elapsed += dt;
        step++;
        incoming.position.x += dt * 0.03f;
        contact.update_contact(support, *incoming, dt)!!;
        assert(math::is_finite(contact.requested.position.x));
        assert(contact.requested.rotation.is_normalized());
    }
}

fn void test_contact_support_accepts_uniform_frames_and_rejects_invalid_bases() @test {
    float[3] valid_scales = { 0.5f, 1, 2 };
    foreach (scale : valid_scales) {
        FootSupport support = contact_test_support(scale);
        support.transform.position = { 1, 2, 3 };
        support.transform.rotation = contact_test_rotation({ 0, 1, 0 }, 37);
        FootDiagnostic diagnostic = { .reason = INVALID_HIT };
        FootSupport decoded = ik::foot_support_from_mat4(
            identity: support.identity,
            kind: support.kind,
            frame: support.transform.to_mat4(),
            diagnostic: &diagnostic,
        )!!;
        assert(diagnostic.reason == NONE);
        assert(contact_test_vec(decoded.transform.position, support.transform.position));
        assert(contact_test_quat(decoded.transform.rotation, support.transform.rotation));
        assert(math::abs(decoded.transform.scale.x - scale) <= 1e-6f);
    }

    Mat4[6] frames = {
        maths::TRANSFORM_IDENTITY.to_mat4(), maths::TRANSFORM_IDENTITY.to_mat4(),
        maths::TRANSFORM_IDENTITY.to_mat4(), maths::TRANSFORM_IDENTITY.to_mat4(),
        maths::TRANSFORM_IDENTITY.to_mat4(), maths::TRANSFORM_IDENTITY.to_mat4(),
    };
    frames[0].m11 = 2;
    frames[1].m00 = 0;
    frames[2].m00 = -1;
    frames[3].m01 = 0.1f;
    frames[4].m03 = bitcast(0x7fc00000u, float);
    frames[5].m30 = 0.1f;
    FootContactReason[6] reasons = {
        NONUNIFORM_SUPPORT_SCALE, NONPOSITIVE_SUPPORT_SCALE, REFLECTED_SUPPORT,
        SHEARED_SUPPORT, NONFINITE_SUPPORT, NONAFFINE_SUPPORT,
    };
    foreach (index, frame : frames) {
        FootDiagnostic diagnostic;
        if (catch excuse = ik::foot_support_from_mat4(
            identity: 17,
            kind: SUPPORT,
            frame: frame,
            diagnostic: &diagnostic,
        )) {
            assert(excuse == c3d::INVALID_ARGUMENT);
            assert(diagnostic.reason == reasons[index]);
        } else {
            assert(false);
        }
    }
}

fn void test_contact_support_matrix_preserves_finite_extreme_uniform_scales() @test {
    float[2] scales = { 1e-30f, 1e30f };
    foreach (scale : scales) {
        FootSupport support = contact_test_support(scale);
        support.transform.rotation = contact_test_rotation({ 0, 1, 0 }, 37);
        FootSupport decoded = ik::foot_support_from_mat4(
            identity: support.identity,
            kind: support.kind,
            frame: support.transform.to_mat4(),
        )!!;
        assert(math::is_finite(decoded.transform.scale.x) && decoded.transform.scale.x > 0);
        assert(math::abs(decoded.transform.scale.x - scale) / scale <= 1e-5f);
        assert(contact_test_quat(decoded.transform.rotation, support.transform.rotation));
    }
}

fn void test_contact_reacquire_uses_world_distance_at_large_support_scale() @test {
    FootSupport support = contact_test_support(1e30f);
    Transform incoming = maths::TRANSFORM_IDENTITY;
    incoming.position = { 1, 0.08f, 0 };
    FootContact contact;
    contact.begin_contact(
        hit: { .point = { 1, 0, 0 }, .normal = { 0, 1, 0 } },
        support: support,
        incoming: incoming,
    )!!;
    contact.update_contact(support, incoming, 1)!!;
    contact.begin_contact(
        hit: { .point = { 2, 0, 0 }, .normal = { 0, 1, 0 } },
        support: support,
        incoming: incoming,
    )!!;
    assert(contact.phase == ACQUIRING);
    contact.update_contact(support, incoming, 1)!!;
    assert(math::abs(contact.requested.position.x - 2) <= 1e-6f);
}

fn void test_contact_small_support_scale_retains_finite_world_pose() @test {
    FootSupport support = contact_test_support(2e-38f);
    Transform incoming = maths::TRANSFORM_IDENTITY;
    incoming.position = { 8, 0.08f, 0 };
    FootContact contact;
    contact.begin_contact(
        hit: { .point = { 8, 0, 0 }, .normal = { 0, 1, 0 } },
        support: support,
        incoming: incoming,
    )!!;
    assert(math::is_finite(contact.requested.position.x));
    assert(contact_test_vec(contact.requested.position, incoming.position));
    contact.update_contact(support, incoming, 1)!!;
    assert(math::is_finite(contact.requested.position.x));
    assert(contact_test_vec(contact.requested.position, incoming.position));
    contact.end_contact(support, incoming)!!;
    incoming.position.x = 9;
    contact.update_contact(support, incoming, 0.1f)!!;
    assert(math::is_finite(contact.requested.position.x));
    assert(math::abs(contact.requested.position.x - 8.5f) <= 1e-6f);
    contact.update_contact(support, incoming, 0.1f)!!;
    assert(contact.phase == INACTIVE);
    assert(contact_test_vec(contact.requested.position, incoming.position));
}

fn void test_contact_support_recognition_normalizes_only_accepted_roundoff() @test {
    Mat4 frame = maths::TRANSFORM_IDENTITY.to_mat4();
    frame.m11 = 1 + 0.5e-5f;
    frame.m01 = 0.5e-5f;
    FootSupport accepted = ik::foot_support_from_mat4(1, SUPPORT, frame)!!;
    assert(accepted.transform.rotation.is_normalized());
    assert(accepted.transform.scale.x == accepted.transform.scale.y);
    frame.m01 = 2e-5f;
    FootDiagnostic diagnostic;
    if (catch excuse = ik::foot_support_from_mat4(
        identity: 1,
        kind: SUPPORT,
        frame: frame,
        diagnostic: &diagnostic,
    )) {
        assert(excuse == c3d::INVALID_ARGUMENT && diagnostic.reason == SHEARED_SUPPORT);
    } else {
        assert(false);
    }
}

fn void test_contact_captures_configured_sole_basis_and_metre_height() @test {
    foreach (initial_scale : (float[2]){ 0.5f, 2 }) {
        FootPlantConfig config = ik::FOOT_PLANT_DEFAULT;
        config.sole_up = { 1, 0, 0 };
        config.sole_forward = { 0, 1, 0 };
        Transform incoming = contact_test_pose({ 0.2f, 0.4f, -0.1f });
        FootSupport support = contact_test_support(initial_scale);
        support.transform.rotation = contact_test_rotation({ 0, 0, 1 }, 20);
        GroundHit hit = { .point = { 0.1f, 0, 0.2f }, .normal = { 0, 1, 0 } };
        incoming.rotation = contact_test_rotation({ 0, 0, 1 }, -90);
        FootContact contact;
        contact.begin_contact(
            hit: hit,
            support: support,
            incoming: incoming,
            config: config,
            foot_height: 0.08f,
        )!!;
        double[<3>] local_point = contact.local_point;
        contact.update_contact(support, incoming, config.acquire_seconds)!!;
        assert(contact.phase == PLANTED);
        assert(contact_test_vec(contact.requested.position, hit.point + hit.normal * 0.08f));
        assert(contact_test_vec(contact.requested.rotation * config.sole_up, hit.normal));
        Vec3 heading = contact.requested.rotation * config.sole_forward;
        assert(math::abs(heading.dot(hit.normal)) <= 1e-6f);

        support.transform.scale = { 2, 2, 2 };
        support.transform.rotation = contact_test_rotation({ 0, 1, 0 }, 30) * support.transform.rotation;
        support.transform.position = { 0.5f, 0, 0 };
        contact.update_contact(support, incoming, 0)!!;
        Vec3 carried = maths::transform_point(support.transform.to_mat4(), (Vec3)local_point);
        Vec3 normal = support.transform.rotation * contact.local_normal;
        assert(contact_test_vec(contact.requested.position - carried, normal * 0.08f));
        assert(contact_test_vec(contact.requested.rotation * config.sole_forward,
            support.transform.rotation * contact.local_heading));
    }
}

fn void test_contact_phase_commands_preserve_requested_pose_at_zero_step() @test {
    Transform incoming = contact_test_pose({ 0.2f, 0.3f, 0 });
    FootSupport support = contact_test_support(0.5f);
    GroundHit hit = { .point = {}, .normal = { 0, 1, 0 } };
    FootContact contact;
    contact.begin_contact(hit, support, incoming)!!;
    assert(contact_test_vec(contact.requested.position, incoming.position));
    contact.update_contact(support, incoming, 0.06f)!!;
    Transform before = contact.requested;
    contact.end_contact(support, incoming)!!;
    assert(contact_test_vec(contact.requested.position, before.position));
    assert(contact_test_quat(contact.requested.rotation, before.rotation));
    contact.update_contact(support, incoming, 0.1f)!!;
    before = contact.requested;
    FootSupport replacement = support;
    replacement.identity = 18;
    replacement.transform.position = { 0.1f, 0, 0 };
    contact.begin_contact({ .point = { 0.1f, 0, 0 }, .normal = { 0, 1, 0 } }, replacement, incoming)!!;
    assert(contact_test_vec(contact.requested.position, before.position));
    assert(contact_test_quat(contact.requested.rotation, before.rotation));
    assert(contact.support_identity == 18 && contact.elapsed == 0);
    contact.update_contact(replacement, incoming, 0.12f)!!;
    contact.end_contact(replacement, incoming)!!;
    incoming.position = { -0.3f, 0.4f, 0.2f };
    incoming.rotation = contact_test_rotation({ 0, 1, 0 }, 45);
    contact.update_contact(replacement, incoming, 0.2f)!!;
    assert(contact.phase == INACTIVE);
    assert(contact_test_vec(contact.requested.position, incoming.position));
    assert(contact_test_quat(contact.requested.rotation, incoming.rotation));
    assert(contact.contact_result(incoming).status == NO_TARGET);
}

fn void test_contact_release_carries_sole_without_scaling_height() @test {
    FootPlantConfig config = ik::FOOT_PLANT_DEFAULT;
    config.sole_up = { 1, 0, 0 };
    config.sole_forward = { 0, 0, -1 };
    FootSupport support = contact_test_support(0.5f);
    support.transform.rotation = contact_test_rotation({ 0, 0, 1 }, 20);
    Transform incoming = contact_test_pose({ 0.3f, 0.4f, 0.2f });
    incoming.rotation = contact_test_rotation({ 0, 1, 0 }, 15);
    FootContact contact;
    contact.begin_contact(
        hit: { .point = { 0.1f, 0, 0.1f }, .normal = { 0, 1, 0 } },
        support: support,
        incoming: incoming,
        config: config,
        foot_height: 0.08f,
    )!!;
    contact.update_contact(support, incoming, 0.06f)!!;
    Transform requested = contact.requested;
    contact.end_contact(support, incoming)!!;
    assert(contact_test_vec(contact.requested.position, requested.position));
    assert(contact_test_quat(contact.requested.rotation, requested.rotation));
    Vec3 sole = requested.position - requested.rotation * config.sole_up * 0.08f;
    Vec3 expected_local = maths::transform_point(maths::inverse_affine(support.transform.to_mat4()), sole);
    assert(contact_test_vec(contact.release_local_sole, expected_local));

    support.transform.scale = { 2, 2, 2 };
    support.transform.rotation = contact_test_rotation({ 0, 1, 0 }, 30) * support.transform.rotation;
    support.transform.position = { 0.5f, 0, 0 };
    contact.update_contact(support, incoming, 0)!!;
    Quat carried_rotation = support.transform.rotation * contact.release_local_rotation;
    Vec3 expected = maths::transform_point(support.transform.to_mat4(), expected_local)
        + carried_rotation * config.sole_up * 0.08f;
    assert(contact_test_vec(contact.requested.position, expected));
    assert(contact.elapsed == 0);
}

fn void test_contact_identical_intent_and_zero_updates_are_idempotent() @test {
    FootContact contact;
    FootSupport support = contact_test_support();
    Transform incoming = contact_test_pose({ 0.2f, 0.3f, 0 });
    GroundHit hit = { .point = {}, .normal = { 0, 1, 0 } };
    contact.begin_contact(hit, support, incoming)!!;
    contact.update_contact(support, incoming, 0.06f)!!;
    FootContact before = contact;
    for (uint iteration = 0; iteration < 100; iteration++) {
        contact.begin_contact(hit, support, incoming)!!;
        contact.update_contact(support, incoming, 0)!!;
    }
    assert(contact_test_same_state(&before, &contact));
    contact.update_contact(support, incoming, 0.06f)!!;
    incoming.position.x += 0.1f;
    contact.end_contact(support, incoming)!!;
    contact.update_contact(support, incoming, 0.1f)!!;
    before = contact;
    for (uint iteration = 0; iteration < 100; iteration++) {
        contact.end_contact(support, incoming)!!;
        contact.update_contact(support, incoming, 0)!!;
    }
    assert(contact_test_same_state(&before, &contact));
    support.transform.position.x += 0.5f;
    contact.update_contact(support, incoming, 0)!!;
    assert(contact.elapsed == before.elapsed);
    assert(contact_test_vec(contact.requested.position - before.requested.position, { 0.25f, 0, 0 }));
    contact.reset_contact();
    assert(contact.phase == INACTIVE);
}

fn void test_contact_validation_preserves_state_for_invalid_updates() @test {
    FootContact contact;
    FootSupport support = contact_test_support();
    Transform incoming = contact_test_pose();
    contact.begin_contact({ .point = {}, .normal = { 0, 1, 0 } }, support, incoming)!!;
    FootSupport changed = support;
    changed.identity++;
    contact_test_expect_update_fault(
        contact: &contact,
        support: changed,
        incoming: incoming,
        dt: 0,
        reason: SUPPORT_CHANGED,
    );
    changed = ik::world_static_support(support.identity);
    contact_test_expect_update_fault(
        contact: &contact,
        support: changed,
        incoming: incoming,
        dt: 0,
        reason: SUPPORT_CHANGED,
    );
    changed = support;
    changed.transform.scale = { 1, 2, 1 };
    contact_test_expect_update_fault(
        contact: &contact,
        support: changed,
        incoming: incoming,
        dt: 0,
        reason: NONUNIFORM_SUPPORT_SCALE,
    );
    changed.transform.scale = { -1, -1, -1 };
    contact_test_expect_update_fault(
        contact: &contact,
        support: changed,
        incoming: incoming,
        dt: 0,
        reason: NONPOSITIVE_SUPPORT_SCALE,
    );
    changed.transform.scale = {};
    contact_test_expect_update_fault(
        contact: &contact,
        support: changed,
        incoming: incoming,
        dt: 0,
        reason: NONPOSITIVE_SUPPORT_SCALE,
    );
    changed = support;
    changed.transform.rotation = {};
    contact_test_expect_update_fault(
        contact: &contact,
        support: changed,
        incoming: incoming,
        dt: 0,
        reason: INVALID_SUPPORT_ROTATION,
    );
    changed = support;
    changed.transform.position.x = bitcast(0x7f800000u, float);
    contact_test_expect_update_fault(
        contact: &contact,
        support: changed,
        incoming: incoming,
        dt: 0,
        reason: NONFINITE_SUPPORT,
    );
    contact_test_expect_update_fault(
        contact: &contact,
        support: support,
        incoming: incoming,
        dt: -0.1f,
        reason: INVALID_DELTA_TIME,
    );
    contact_test_expect_update_fault(
        contact: &contact,
        support: support,
        incoming: incoming,
        dt: bitcast(0x7fc00000u, float),
        reason: INVALID_DELTA_TIME,
    );
    incoming.rotation = {};
    contact_test_expect_update_fault(
        contact: &contact,
        support: support,
        incoming: incoming,
        dt: 0,
        reason: INVALID_INCOMING_POSE,
    );
}

fn void test_contact_validation_preserves_state_for_invalid_capture() @test {
    FootSupport support = contact_test_support();
    Transform incoming = contact_test_pose();
    GroundHit hit = { .point = {}, .normal = { 0, 1, 0 } };
    FootContact contact;
    contact.begin_contact(hit, support, incoming)!!;
    contact.update_contact(support, incoming, 0.06f)!!;
    FootContact before = contact;
    for (uint invalid = 0; invalid < 7; invalid++) {
        FootPlantConfig config = ik::FOOT_PLANT_DEFAULT;
        GroundHit bad_hit = hit;
        Transform pose = incoming;
        float height = 0.08f;
        FootContactReason expected;
        switch (invalid) {
            case 0: bad_hit.normal = {}; expected = INVALID_NORMAL;
            case 1: bad_hit.point.x = bitcast(0x7fc00000u, float); expected = INVALID_HIT;
            case 2: config.sole_up = { 0, 2, 0 }; expected = INVALID_SOLE_AXES;
            case 3: config.sole_forward = config.sole_up; expected = INVALID_SOLE_AXES;
            case 4: config.acquire_seconds = 0; expected = INVALID_DURATION;
            case 5: height = -1; expected = INVALID_FOOT_HEIGHT;
            case 6:
                bad_hit.point.x = 0.1f;
                pose.rotation = contact_test_rotation({ 1, 0, 0 }, 90);
                expected = DEGENERATE_HEADING;
        }
        FootDiagnostic diagnostic;
        if (catch excuse = contact.begin_contact(
            hit: bad_hit,
            support: support,
            incoming: pose,
            config: config,
            foot_height: height,
            diagnostic: &diagnostic,
        )) {
            assert(excuse == c3d::INVALID_ARGUMENT && diagnostic.reason == expected);
        } else {
            assert(false);
        }
        assert(contact_test_same_state(&before, &contact));
    }
}

fn void test_contact_full_pipeline_retains_slopes_and_moving_scaled_supports() @test {
    Vec3[5] normals = {
        { 0, 1, 0 },
        contact_test_rotation({ 1, 0, 0 }, 20) * (Vec3){ 0, 1, 0 },
        contact_test_rotation({ 1, 0, 0 }, -20) * (Vec3){ 0, 1, 0 },
        contact_test_rotation({ 0, 0, 1 }, 20) * (Vec3){ 0, 1, 0 },
        contact_test_rotation({ 0, 0, 1 }, -20) * (Vec3){ 0, 1, 0 },
    };
    float[3] fixed_steps = { 1.0f / 30, 1.0f / 60, 1.0f / 120 };
    float[3] variable_steps = { 1.0f / 120, 1.0f / 40, 1.0f / 60 };
    foreach (normal : normals) {
        for (uint schedule = 0; schedule < 4; schedule++) {
            ContactRig rig = contact_test_rig();
            defer scene::destroy_scene(&rig.scene);
            FootSupport support = contact_test_support(0.5f);
            support.transform.rotation = contact_test_rotation({ 1, 0, 0 }, 10);
            contact_test_incoming(&rig, { 0, -0.2f, 0 });
            GroundHit hit = { .point = { 0.05f, 0, 0 }, .normal = normal };
            rig.foot.begin_contact(hit, support)!!;
            double[<3>] anchor = rig.foot.contact.local_point;
            Vec3 local_normal = rig.foot.contact.local_normal;
            Vec3 local_heading = rig.foot.contact.local_heading;
            float time;
            uint step;
            while (time < 10) {
                float dt = schedule < 3 ? fixed_steps[schedule] : variable_steps[step % 3];
                dt = math::min(dt, 10 - time);
                time += dt;
                step++;
                float scale = 0.5f + 1.5f * time / 10;
                support.transform.scale = { scale, scale, scale };
                support.transform.position = { 0.5f * time / 10, 0, 0 };
                support.transform.rotation = contact_test_rotation({ 0, 1, 0 }, 30 * time / 10)
                    * contact_test_rotation({ 1, 0, 0 }, 10);
                contact_test_incoming(&rig, { 0.05f * math::sin(time), -0.2f, 0 });
                rig.foot.update_contact(support, dt)!!;
                float reach = (rig.foot.contact.requested.position - rig.hip.world_position()).length();
                float upper = (rig.knee.world_position() - rig.hip.world_position()).length();
                float lower = (rig.ankle.world_position() - rig.knee.world_position()).length();
                assert(reach <= upper + lower - 0.05f && reach >= math::abs(upper - lower) + 0.05f);
                FootContactResult result = contact_test_solve(&rig);
                assert(contact_test_vec(rig.foot.contact.local_point, anchor, 0));
                assert(contact_test_vec(rig.foot.contact.local_normal, local_normal, 0));
                assert(contact_test_vec(rig.foot.contact.local_heading, local_heading, 0));
                if (result.phase == PLANTED) {
                    assert(result.status == REACHED);
                    assert(result.residual <= 0.001f);
                    assert(result.normal_error_degrees <= 1 && result.heading_error_degrees <= 1);
                    Transform ankle = maths::transform_from_mat4(rig.ankle.world);
                    Vec3 actual_sole = ankle.position - ankle.rotation * rig.foot.contact.config.sole_up * 0.08f;
                    Vec3 expected_sole = maths::transform_point(support.transform.to_mat4(), (Vec3)anchor);
                    assert(contact_test_vec(actual_sole, expected_sole, 0.001f));
                }
            }
        }
    }
}

fn void test_contact_full_pipeline_reports_constrained_residual_without_releasing() @test {
    Vec3[3] points = { { 4, 0, 0 }, { 0.01f, 1.4f, 0 }, { 0.4f, 0.2f, 0 } };
    float[3] weights = { 0, 0.5f, 1 };
    foreach (point : points) {
        foreach (weight : weights) {
            ContactRig rig = contact_test_rig();
            defer scene::destroy_scene(&rig.scene);
            rig.foot.leg.weight = weight;
            if (point.x == 0.01f) rig.ankle.local.position = { 0, -0.35f, -0.1f };
            rig.scene.update_world();
            FootSupport support = ik::world_static_support();
            rig.foot.begin_contact({ .point = point, .normal = { 0, 1, 0 } }, support)!!;
            rig.foot.update_contact(support, 0.12f)!!;
            double[<3>] retained = rig.foot.contact.local_point;
            rig.scene.update_world();
            float upper = (rig.knee.world_position() - rig.hip.world_position()).length();
            float lower = (rig.ankle.world_position() - rig.knee.world_position()).length();
            rig.foot.leg.solve();
            rig.scene.update_world();
            rig.foot.align_contact();
            rig.scene.update_world();
            FootContactResult result = rig.foot.contact_result();
            assert(math::is_finite(result.residual));
            assert(math::is_finite(result.normal_error_degrees) && math::is_finite(result.heading_error_degrees));
            assert(math::abs((rig.knee.world_position() - rig.hip.world_position()).length() - upper) <= 1e-5f);
            assert(math::abs((rig.ankle.world_position() - rig.knee.world_position()).length() - lower) <= 1e-5f);
            assert(contact_test_vec(rig.foot.contact.local_point, retained, 0));
            assert(rig.foot.contact.phase == PLANTED);
            float actual_residual = (rig.ankle.world_position() - rig.target.world_position()).length();
            assert(math::abs(result.residual - actual_residual) <= 1e-6f);
            if (point.x == 4 || point.x == 0.01f || weight < 1) assert(result.status == MISSED);
        }
    }

    for (uint limit_kind = 0; limit_kind < 2; limit_kind++) {
        ContactRig rig = contact_test_rig();
        defer scene::destroy_scene(&rig.scene);
        rig.foot.leg.limits[0] = limit_kind == 0
            ? ik::hinge_limit(
                reference: quaternion::IDENTITY,
                axis: { 1, 0, 0 },
                min_angle: 0,
                max_angle: 0,
                twist_axis: { 0, 1, 0 },
            )
            : ik::cone_limit(quaternion::IDENTITY, { 0, 1, 0 }, 0);
        rig.foot.begin_contact({ .point = { 0.5f, 0.1f, 0 }, .normal = { 0, 1, 0 } }, ik::world_static_support())!!;
        rig.foot.update_contact(ik::world_static_support(), 0.12f)!!;
        FootContactResult result = contact_test_solve(&rig);
        assert(result.status == MISSED && result.phase == PLANTED && math::is_finite(result.residual));
    }
}

fn void test_contact_pause_uses_fresh_animation_before_solving() @test {
    ContactRig rig = contact_test_rig();
    defer scene::destroy_scene(&rig.scene);
    FootSupport support = contact_test_support();
    rig.foot.begin_contact({ .point = { 0.1f, 0, 0 }, .normal = { 0, 1, 0 } }, support)!!;
    rig.foot.update_contact(support, 0.06f)!!;
    contact_test_solve(&rig);
    FootContact before = rig.foot.contact;
    for (uint frame = 0; frame < 100; frame++) {
        contact_test_incoming(&rig);
        rig.foot.update_contact(support, 0)!!;
        FootContactResult result = contact_test_solve(&rig);
        assert(result.residual <= 0.001f);
        assert(contact_test_same_state(&before, &rig.foot.contact));
    }
    support.transform.position.x += 0.2f;
    contact_test_incoming(&rig);
    rig.foot.update_contact(support, 0)!!;
    assert(rig.foot.contact.elapsed == before.elapsed);
    assert(contact_test_vec(rig.foot.contact.requested.position - before.requested.position, { 0.1f, 0, 0 }));
    contact_test_solve(&rig);
}

fn void test_contact_pelvis_adjustment_preserves_the_requested_anchor() @test {
    ContactRig rig = contact_test_rig();
    defer scene::destroy_scene(&rig.scene);
    Node* pelvis = rig.scene.add_node(name: "pelvis")!!;
    rig.scene.reparent(rig.hip, pelvis);
    rig.scene.update_world();
    FootSupport support = ik::world_static_support();
    rig.foot.begin_contact({ .point = { 0.1f, -0.2f, 0 }, .normal = { 0, 1, 0 } }, support)!!;
    rig.foot.update_contact(support, 0.12f)!!;
    FootContact before = rig.foot.contact;
    FootIk*[1] feet = { &rig.foot };
    float drop = ik::lower_pelvis(pelvis, feet[..]);
    assert(math::abs(drop - 0.2f) <= 1e-6f);
    rig.scene.update_world();
    FootContactResult result = contact_test_solve(&rig);
    assert(result.status == REACHED);
    assert(contact_test_same_state(&before, &rig.foot.contact));
}

fn void test_contact_invalid_adapter_call_preserves_target_and_authoring() @test {
    ContactRig rig = contact_test_rig();
    defer scene::destroy_scene(&rig.scene);
    FootSupport support = contact_test_support();
    rig.foot.begin_contact({ .point = {}, .normal = { 0, 1, 0 } }, support)!!;
    FootIk before = rig.foot;
    Transform target = rig.target.local;
    FootDiagnostic diagnostic;
    if (catch excuse = rig.foot.update_contact(
        support: support,
        dt: -1,
        floor_height: 0,
        diagnostic: &diagnostic,
    )) {
        assert(excuse == c3d::INVALID_ARGUMENT && diagnostic.reason == INVALID_DELTA_TIME);
    } else {
        assert(false);
    }
    assert(((char*)&before)[:FootIk::size] == ((char*)&rig.foot)[:FootIk::size]);
    assert(((char*)&target)[:Transform::size] == ((char*)&rig.target.local)[:Transform::size]);
    rig.foot.plant.acquire_seconds = 1;
    rig.foot.foot_height = 0.25f;
    contact_test_incoming(&rig);
    rig.foot.update_contact(support, 0.12f)!!;
    assert(rig.foot.contact.config.acquire_seconds == 0.12f && rig.foot.contact.foot_height == 0.08f);
    rig.foot.begin_contact({ .point = { 0.1f, 0, 0 }, .normal = { 0, 1, 0 } }, support)!!;
    assert(rig.foot.contact.config.acquire_seconds == 1 && rig.foot.contact.foot_height == 0.25f);
}

fn void test_contact_two_instances_remain_independent_without_allocation_growth() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    ContactRig first = contact_test_rig(&tracker);
    defer scene::destroy_scene(&first.scene);
    ContactRig second = contact_test_rig(&tracker);
    defer scene::destroy_scene(&second.scene);
    FootSupport support = contact_test_support();
    first.foot.begin_contact({ .point = { 0.1f, 0, 0 }, .normal = { 0, 1, 0 } }, support)!!;
    second.foot.plant.acquire_seconds = 0.24f;
    second.foot.begin_contact({ .point = { -0.1f, 0, 0 }, .normal = { 0, 1, 0 } }, support)!!;
    FootContact second_before = second.foot.contact;
    sz allocation_count = tracker.total_allocation_count();
    sz allocated = tracker.allocated();
    mem::@scoped(&tracker) {
        for (uint frame = 0; frame < 1000; frame++) {
            contact_test_incoming(&first);
            first.foot.update_contact(support, 1.0f / 120)!!;
            contact_test_solve(&first);
            if (frame == 100) {
                contact_test_incoming(&first);
                first.foot.end_contact(support)!!;
            }
            if (frame == 200) {
                contact_test_incoming(&first);
                first.foot.reset_contact();
            }
            if (frame == 300) {
                contact_test_incoming(&first);
                first.foot.begin_contact({ .point = { 0.2f, 0, 0 }, .normal = { 0, 1, 0 } }, support)!!;
            }
        }
    };
    assert(contact_test_same_state(&second_before, &second.foot.contact));
    assert(tracker.allocated() == allocated && tracker.total_allocation_count() == allocation_count);
    second.foot.update_contact(support, 0.24f)!!;
    FootContactResult result = contact_test_solve(&second);
    assert(result.status == REACHED);
}

fn void test_contact_standalone_rebase_preserves_local_state_in_every_phase() @test {
    Vec3[2] offsets = { { 256, 0, -512 }, { 65536, 0, -65536 } };
    foreach (offset : offsets) {
        for (uint kind = 0; kind < 2; kind++) {
            for (uint phase = 0; phase < 3; phase++) {
                FootSupport support = kind == 0 ? ik::world_static_support() : contact_test_support();
                Transform incoming = contact_test_pose({ 0.25f, 0.25f, 0.125f });
                GroundHit hit = { .point = { 0.125f, 0, 0.25f }, .normal = { 0, 1, 0 } };
                FootContact control;
                control.begin_contact(hit, support, incoming)!!;
                FootContact shifted;
                Transform distant_incoming = incoming;
                distant_incoming.position += offset;
                GroundHit distant_hit = hit;
                distant_hit.point += offset;
                FootSupport distant_support = support;
                if (kind == 1) distant_support.transform.position += offset;
                shifted.begin_contact(distant_hit, distant_support, distant_incoming)!!;
                float dt = phase == 0 ? 0.06f : 0.12f;
                control.update_contact(support, incoming, dt)!!;
                shifted.update_contact(distant_support, distant_incoming, dt)!!;
                if (phase == 2) {
                    control.end_contact(support, incoming)!!;
                    shifted.end_contact(distant_support, distant_incoming)!!;
                    control.update_contact(support, incoming, 0.1f)!!;
                    shifted.update_contact(distant_support, distant_incoming, 0.1f)!!;
                }
                double[<3>] local = shifted.local_point;
                double[<3>] release = shifted.release_local_sole;
                Vec3 local_normal = shifted.local_normal;
                Vec3 local_heading = shifted.local_heading;
                shifted.shift_origin(offset);
                if (kind == 1) distant_support.transform.position -= offset;
                shifted.update_contact(distant_support, incoming, 0)!!;
                control.update_contact(support, incoming, 0)!!;
                assert(contact_test_vec(
                    first: shifted.requested.position,
                    second: control.requested.position,
                    epsilon: CONTACT_TEST_REBASE_EPSILON,
                ));
                assert(contact_test_quat(shifted.requested.rotation, control.requested.rotation));
                assert(contact_test_vec(shifted.local_point, local, 0));
                assert(contact_test_vec(shifted.release_local_sole, release, 0));
                assert(contact_test_vec(shifted.local_normal, local_normal, 0));
                assert(contact_test_vec(shifted.local_heading, local_heading, 0));
                shifted.update_contact(distant_support, incoming, 0)!!;
                assert(contact_test_vec(
                    first: shifted.requested.position,
                    second: control.requested.position,
                    epsilon: CONTACT_TEST_REBASE_EPSILON,
                ));
            }
        }
    }
}

fn void test_contact_scene_rebase_visits_component_owners_once() @test {
    ContactRig rig = contact_test_rig();
    defer scene::destroy_scene(&rig.scene);
    FootSupport support = ik::world_static_support();
    Vec3 offset = { 256, 0, -512 };
    contact_test_incoming(&rig, offset);
    rig.foot.begin_contact({ .point = offset, .normal = { 0, 1, 0 } }, support)!!;
    rig.foot.update_contact(support, 0.12f)!!;
    rig.scene.add(rig.hip, rig.foot);
    FootIk* component = rig.scene.get(rig.hip, FootIk);
    double[<3>] local = component.contact.local_point;
    Transform requested = component.contact.requested;
    FootContact standalone = component.contact;
    rig.scene.shift_origin(offset);
    rig.scene.update_world();
    rig.scene.shift_foot_contacts(offset);
    assert(contact_test_vec(component.contact.requested.position, requested.position - offset));
    assert(contact_test_vec(component.contact.local_point, local, 0));
    assert(contact_test_vec(standalone.requested.position, requested.position, 0));
    standalone.shift_origin(offset);
    component.update_contact(support, 0)!!;
    assert(contact_test_vec(component.contact.requested.position, standalone.requested.position));
}

fn void test_contact_lifecycle_continuity_across_fixed_and_varying_steps() @test {
    for (uint schedule = 0; schedule < 4; schedule++) {
        FootContact contact;
        FootSupport support = contact_test_support();
        Transform incoming = contact_test_pose({ 0.2f, 0.3f, 0 });
        for (uint cycle = 0; cycle < 10; cycle++) {
            contact.begin_contact({ .point = {}, .normal = { 0, 1, 0 } }, support, incoming)!!;
            contact_test_advance_transition(
                contact: &contact,
                support: support,
                incoming: &incoming,
                duration: 0.06f,
                schedule: schedule,
            );
            Transform before = contact.requested;
            contact.end_contact(support, incoming)!!;
            assert(contact_test_vec(contact.requested.position, before.position));
            assert(contact_test_quat(contact.requested.rotation, before.rotation));
            contact_test_advance_transition(
                contact: &contact,
                support: support,
                incoming: &incoming,
                duration: 0.1f,
                schedule: schedule,
            );
            before = contact.requested;
            contact.begin_contact({ .point = { 0.05f, 0, 0 }, .normal = { 0, 1, 0 } }, support, incoming)!!;
            assert(contact_test_vec(contact.requested.position, before.position));
            assert(contact_test_quat(contact.requested.rotation, before.rotation));
            contact_test_advance_transition(
                contact: &contact,
                support: support,
                incoming: &incoming,
                duration: 0.06f,
                schedule: schedule,
            );
            contact.end_contact(support, incoming)!!;
            contact_test_advance_transition(
                contact: &contact,
                support: support,
                incoming: &incoming,
                duration: 0.1f,
                schedule: schedule,
            );
            before = contact.requested;
            support.identity++;
            contact.begin_contact({ .point = { -0.05f, 0, 0 }, .normal = { 0, 1, 0 } }, support, incoming)!!;
            assert(contact_test_vec(contact.requested.position, before.position));
            assert(contact_test_quat(contact.requested.rotation, before.rotation));
            contact_test_advance_transition(
                contact: &contact,
                support: support,
                incoming: &incoming,
                duration: 0.12f,
                schedule: schedule,
            );
            assert(contact.phase == PLANTED);
            contact.end_contact(support, incoming)!!;
            contact_test_advance_transition(
                contact: &contact,
                support: support,
                incoming: &incoming,
                duration: 0.2f,
                schedule: schedule,
            );
            assert(contact.phase == INACTIVE);
            assert(contact_test_vec(contact.requested.position, incoming.position));
            assert(contact_test_quat(contact.requested.rotation, incoming.rotation));
            contact_test_advance_transition(
                contact: &contact,
                support: support,
                incoming: &incoming,
                duration: 0.26f,
                schedule: schedule,
            );
        }
    }
}

fn void test_contact_transition_endpoints_have_zero_slope() @test {
    FootSupport support = ik::world_static_support();
    Transform incoming = contact_test_pose({ 0.2f, 0.3f, 0 });
    FootContact contact;
    contact.begin_contact({ .point = {}, .normal = { 0, 1, 0 } }, support, incoming)!!;
    Transform initial = contact.requested;
    contact.update_contact(support, incoming, 0.00012f)!!;
    assert((contact.requested.position - initial.position).length() <= 1e-6f);
    contact.update_contact(support, incoming, 0.11976f)!!;
    Transform near_end = contact.requested;
    contact.update_contact(support, incoming, 0.00012f)!!;
    assert((contact.requested.position - near_end.position).length() <= 1e-6f);
    contact.end_contact(support, incoming)!!;
    initial = contact.requested;
    contact.update_contact(support, incoming, 0.0002f)!!;
    assert((contact.requested.position - initial.position).length() <= 1e-6f);
    contact.update_contact(support, incoming, 0.1996f)!!;
    near_end = contact.requested;
    contact.update_contact(support, incoming, 0.0002f)!!;
    assert((contact.requested.position - near_end.position).length() <= 1e-6f);
}

fn void test_contact_component_rebase_matches_conditioned_pipeline_in_every_phase() @test {
    Vec3[2] offsets = { { 256, 0, -512 }, { 65536, 0, -65536 } };
    foreach (offset : offsets) {
        for (uint kind = 0; kind < 2; kind++) {
            for (uint phase = 0; phase < 3; phase++) {
                ContactRig control = contact_test_rig();
                defer scene::destroy_scene(&control.scene);
                ContactRig shifted = contact_test_rig();
                defer scene::destroy_scene(&shifted.scene);
                FootSupport support = kind == 0 ? ik::world_static_support() : contact_test_support();
                FootSupport distant_support = support;
                if (kind == 1) distant_support.transform.position = offset;
                contact_test_incoming(&control, { 0.125f, 0, 0.25f });
                contact_test_incoming(&shifted, offset + (Vec3){ 0.125f, 0, 0.25f });
                GroundHit hit = { .point = { 0.125f, 0, 0.25f }, .normal = { 0, 1, 0 } };
                GroundHit distant_hit = hit;
                distant_hit.point += offset;
                control.foot.begin_contact(hit, support)!!;
                shifted.foot.begin_contact(distant_hit, distant_support)!!;
                float dt = phase == 0 ? 0.06f : 0.12f;
                control.foot.update_contact(support, dt)!!;
                shifted.foot.update_contact(distant_support, dt)!!;
                if (phase == 2) {
                    control.foot.end_contact(support)!!;
                    shifted.foot.end_contact(distant_support)!!;
                    control.foot.update_contact(support, 0.1f)!!;
                    shifted.foot.update_contact(distant_support, 0.1f)!!;
                }
                shifted.scene.add(shifted.hip, shifted.foot);
                double[<3>] local_point = shifted.foot.contact.local_point;
                double[<3>] local_release = shifted.foot.contact.release_local_sole;
                shifted.scene.shift_origin(offset);
                shifted.scene.update_world();
                shifted.scene.shift_foot_contacts(offset);
                if (kind == 1) distant_support.transform.position -= offset;
                FootIk* component = shifted.scene.get(shifted.hip, FootIk);
                component.update_contact(distant_support, 0)!!;
                shifted.foot = *component;
                control.foot.update_contact(support, 0)!!;
                assert(contact_test_vec(shifted.foot.contact.local_point, local_point, 0));
                assert(contact_test_vec(shifted.foot.contact.release_local_sole, local_release, 0));
                assert(contact_test_vec(shifted.foot.contact.requested.position,
                    control.foot.contact.requested.position, CONTACT_TEST_REBASE_EPSILON));
                FootContactResult control_result = contact_test_solve(&control);
                FootContactResult shifted_result = contact_test_solve(&shifted);
                assert(control_result.status == REACHED && shifted_result.status == REACHED);
                assert(contact_test_vec(
                    first: control.ankle.world_position(),
                    second: shifted.ankle.world_position(),
                    epsilon: CONTACT_TEST_REBASE_EPSILON,
                ));
                assert(contact_test_quat(maths::transform_from_mat4(control.ankle.world).rotation,
                    maths::transform_from_mat4(shifted.ankle.world).rotation));
            }
        }
    }
}
