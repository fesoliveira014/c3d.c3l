module c3d::test::ik;

import c3d;
import c3d::anim::ik;
import c3d::maths;
import c3d::scene;
import std::math;

const float TOLERANCE @local = 1e-4f;
const float LENGTH_TOLERANCE @local = 1e-5f;
const float QUAT_DOT_TOLERANCE @local = 1e-5f;
const uint RIG_NODES @local = 16;
const float AIM_TOLERANCE @local = 0.01f; // radians; two passes leave 0.005 on the swing test, one pass 0.065
const float CONTACT_TEST_POSITION_EPSILON @local = 1e-6f;
const float CONTACT_TEST_LENGTH_EPSILON @local = 1e-5f;
const float CONTACT_TEST_REBASE_EPSILON @local = 1e-4f;

struct ChainRig @local {
    Scene   scene;
    Node*   root;
    Node*   middle;
    Node*   end;
    Node*   target;
    Node*   pole;
    IkChain chain;
}

struct ContactRig @local {
    Scene scene;
    Node* hip;
    Node* knee;
    Node* ankle;
    Node* target;
    Node* pole;
    FootIk foot;
}

fn bool close(float first, float second, float tolerance = TOLERANCE) @local {
    return math::abs(first - second) <= tolerance;
}

fn bool close_vec3(Vec3 first, Vec3 second, float tolerance = TOLERANCE) @local {
    return (first - second).length() <= tolerance;
}

fn bool close_quat(Quat first, Quat second) @local {
    return math::abs(first.v.dot(second.v)) >= 1 - QUAT_DOT_TOLERANCE;
}

fn bool finite_quat(Quat rotation) @local {
    for (usz index = 0; index < 4; index++) {
        if (!math::is_finite(rotation.v[index])) return false;
    }
    return true;
}

fn bool same_quat(Quat first, Quat second) @local {
    for (usz index = 0; index < 4; index++) {
        if (first.v[index] != second.v[index]) return false;
    }
    return true;
}

fn Quat world_rotation_of(Node* node) @local {
    return maths::transform_from_mat4(node.world).rotation;
}

fn ChainRig make_chain() @local {
    ChainRig rig = { .scene = scene::create_scene(mem, { .max_nodes = RIG_NODES }) };
    rig.root = rig.scene.add_node(name: "root")!!;
    rig.middle = rig.scene.add_node(rig.root, "middle")!!;
    rig.end = rig.scene.add_node(rig.middle, "end")!!;
    rig.target = rig.scene.add_node(name: "target")!!;
    rig.pole = rig.scene.add_node(name: "pole")!!;
    rig.middle.local.position = { 0, 1, 0 };
    rig.end.local.position = { 0, 1, 0 };
    rig.chain = ik::ik_chain(
        root:   rig.root,
        middle: rig.middle,
        end:    rig.end,
        target: rig.target,
    );
    rig.scene.update_world();
    return rig;
}

fn FootIk rig_foot(ChainRig* rig) @local {
    return ik::foot_ik(
        hip:    rig.root,
        knee:   rig.middle,
        ankle:  rig.end,
        target: rig.target,
    );
}

fn void solve_at(ChainRig* rig, Vec3 target) @local {
    rig.target.local.position = target;
    rig.scene.update_world();
    rig.chain.solve();
    rig.scene.update_world();
}

fn void test_two_bone_reaches_a_reachable_target() @test {
    ChainRig rig = make_chain();
    defer scene::destroy_scene(&rig.scene);

    solve_at(&rig, { 1.2f, 0.8f, 0 });

    assert(close_vec3(rig.end.world_position(), { 1.2f, 0.8f, 0 }));
    assert(close((rig.middle.world_position() - rig.root.world_position()).length(), 1, LENGTH_TOLERANCE));
    assert(close((rig.end.world_position() - rig.middle.world_position()).length(), 1, LENGTH_TOLERANCE));

    Quat root_solved = rig.root.local.rotation;
    Quat middle_solved = rig.middle.local.rotation;
    rig.chain.solve();
    assert(close_quat(rig.root.local.rotation, root_solved));
    assert(close_quat(rig.middle.local.rotation, middle_solved));
}

fn void test_two_bone_straightens_toward_an_unreachable_target() @test {
    ChainRig rig = make_chain();
    defer scene::destroy_scene(&rig.scene);

    Vec3 target = { 3, 4, 0 };
    solve_at(&rig, target);

    assert(close_vec3(rig.end.world_position(), target.normalize() * 2, 1e-3f));
}

fn void test_target_inside_the_inner_radius_keeps_segment_lengths() @test {
    ChainRig rig = make_chain();
    defer scene::destroy_scene(&rig.scene);
    rig.end.local.position = { 0, 0.5f, 0 };

    solve_at(&rig, { 0.1f, 0.1f, 0 });

    assert(close((rig.middle.world_position() - rig.root.world_position()).length(), 1, LENGTH_TOLERANCE));
    assert(close((rig.end.world_position() - rig.middle.world_position()).length(), 0.5f, LENGTH_TOLERANCE));
    assert(finite_quat(rig.root.local.rotation));
    assert(finite_quat(rig.middle.local.rotation));
}

fn void test_pole_selects_the_bend_side() @test {
    ChainRig right = make_chain();
    defer scene::destroy_scene(&right.scene);
    right.pole.local.position = { 1, 1, 0 };
    right.chain.pole = right.pole;
    solve_at(&right, { 0, 1.2f, 0 });

    ChainRig left = make_chain();
    defer scene::destroy_scene(&left.scene);
    left.pole.local.position = { -1, 1, 0 };
    left.chain.pole = left.pole;
    solve_at(&left, { 0, 1.2f, 0 });

    assert(right.middle.world_position().x > 0.1f);
    assert(left.middle.world_position().x < -0.1f);
}

fn void test_weight_zero_keeps_the_incoming_pose() @test {
    ChainRig rig = make_chain();
    defer scene::destroy_scene(&rig.scene);
    rig.chain.weight = 0;
    Quat root_incoming = rig.root.local.rotation;
    Quat middle_incoming = rig.middle.local.rotation;

    solve_at(&rig, { 1.2f, 0.8f, 0 });

    assert(same_quat(rig.root.local.rotation, root_incoming));
    assert(same_quat(rig.middle.local.rotation, middle_incoming));
}

fn void test_half_weight_blends_the_rotations() @test {
    ChainRig full = make_chain();
    defer scene::destroy_scene(&full.scene);
    Quat incoming = full.root.local.rotation;
    solve_at(&full, { 1.2f, 0.8f, 0 });

    ChainRig half = make_chain();
    defer scene::destroy_scene(&half.scene);
    half.chain.weight = 0.5f;
    solve_at(&half, { 1.2f, 0.8f, 0 });

    assert(close_quat(half.root.local.rotation, incoming.slerp(full.root.local.rotation, 0.5f)));
}

fn void test_solve_under_a_rotated_scaled_parent() @test {
    ChainRig rig = make_chain();
    defer scene::destroy_scene(&rig.scene);
    Node* parent = rig.scene.add_node(name: "parent")!!;
    parent.local = {
        .position = { 3, 0, -2 },
        .rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, (float)math::PI / 2),
        .scale    = { 2, 2, 2 },
    };
    rig.scene.reparent(rig.root, parent);
    rig.scene.update_world();

    Vec3 target = rig.root.world_position() + (Vec3){ 1.5f, 2, 1.8f };
    solve_at(&rig, target);

    assert(close_vec3(rig.end.world_position(), target));
}

fn void test_hinge_limit_clamps_the_middle_joint() @test {
    ChainRig rig = make_chain();
    defer scene::destroy_scene(&rig.scene);
    rig.pole.local.position = { 0, 1, 1 };
    rig.chain.pole = rig.pole;
    rig.chain.limits[1] = ik::hinge_limit(
        reference: quaternion::IDENTITY,
        axis:      { 1, 0, 0 },
        min_angle: -0.5f,
        max_angle: 0.5f,
    );

    solve_at(&rig, { 0, 0.6f, 0.3f });

    assert(close_quat(rig.middle.local.rotation, quaternion::from_axis_angle{float}({ 1, 0, 0 }, -0.5f)));
}

fn void test_hinge_keeps_the_clip_twist_about_the_bone_axis() @test {
    ChainRig rig = make_chain();
    defer scene::destroy_scene(&rig.scene);
    Quat flexion = quaternion::from_axis_angle{float}({ 1, 0, 0 }, 0.3f);
    Quat clip = flexion * quaternion::from_axis_angle{float}({ 0, 1, 0 }, 0.8f);
    rig.middle.local.rotation = clip;
    rig.scene.update_world();
    rig.chain.limits[1] = ik::hinge_limit(
        reference:  quaternion::IDENTITY,
        axis:       { 1, 0, 0 },
        min_angle:  -1,
        max_angle:  1,
        twist_axis: { 0, 1, 0 },
    );

    solve_at(&rig, rig.end.world_position());

    assert(close_quat(rig.middle.local.rotation, clip));
}

fn void test_hinge_clamps_flexion_and_keeps_the_twist() @test {
    ChainRig rig = make_chain();
    defer scene::destroy_scene(&rig.scene);
    Quat twist = quaternion::from_axis_angle{float}({ 0, 1, 0 }, 0.8f);
    rig.middle.local.rotation = twist;
    rig.pole.local.position = { 0, 1, 1 };
    rig.chain.pole = rig.pole;
    rig.chain.limits[1] = ik::hinge_limit(
        reference:  quaternion::IDENTITY,
        axis:       { 1, 0, 0 },
        min_angle:  -0.5f,
        max_angle:  0.5f,
        twist_axis: { 0, 1, 0 },
    );

    solve_at(&rig, { 0, 0.6f, 0.3f });

    assert(close_quat(rig.middle.local.rotation, quaternion::from_axis_angle{float}({ 1, 0, 0 }, -0.5f) * twist));
}

fn void test_cone_limit_bounds_the_root_swing() @test {
    ChainRig rig = make_chain();
    defer scene::destroy_scene(&rig.scene);
    rig.chain.limits[0] = ik::cone_limit(quaternion::IDENTITY, { 0, 1, 0 }, 0.3f);

    solve_at(&rig, { 1.5f, 0.5f, 0 });

    Vec3 root_axis = rig.root.local.rotation * (Vec3){ 0, 1, 0 };
    assert(math::acos(math::clamp(root_axis.dot({ 0, 1, 0 }), -1.0f, 1.0f)) <= 0.3f + TOLERANCE);
}

fn void test_chain_valid_rejects_broken_and_removed_nodes() @test {
    ChainRig rig = make_chain();
    defer scene::destroy_scene(&rig.scene);
    assert(ik::ik_chain_valid(&rig.chain));

    IkChain broken = rig.chain;
    broken.joints[2] = rig.target;
    assert(!ik::ik_chain_valid(&broken));

    rig.scene.remove(rig.target);
    assert(!ik::ik_chain_valid(&rig.chain));
}

fn void test_collinear_chain_without_pole_keeps_its_pose() @test {
    ChainRig rig = make_chain();
    defer scene::destroy_scene(&rig.scene);
    Quat root_incoming = rig.root.local.rotation;
    Quat middle_incoming = rig.middle.local.rotation;

    solve_at(&rig, { 0, 2, 0 });

    assert(same_quat(rig.root.local.rotation, root_incoming));
    assert(same_quat(rig.middle.local.rotation, middle_incoming));
}

fn void test_look_at_clamps_to_max_angle() @test {
    ChainRig rig = make_chain();
    defer scene::destroy_scene(&rig.scene);
    rig.target.local.position = { 5, 0, 0 };
    rig.scene.update_world();

    LookAt clamped = ik::look_at((&rig.pole)[:1], rig.target, { 0, 0, -1 });
    clamped.max_angle = 0.25f;
    clamped.solve();
    rig.scene.update_world();
    Vec3 forward = maths::transform_dir(rig.pole.world, { 0, 0, -1 }).normalize();
    assert(close(math::acos(math::clamp(forward.dot({ 0, 0, -1 }), -1.0f, 1.0f)), 0.25f));

    rig.pole.local.rotation = quaternion::IDENTITY;
    rig.scene.update_world();
    LookAt free = ik::look_at((&rig.pole)[:1], rig.target, { 0, 0, -1 });
    free.solve();
    rig.scene.update_world();
    forward = maths::transform_dir(rig.pole.world, { 0, 0, -1 }).normalize();
    assert(close_vec3(forward, { 1, 0, 0 }));
}

fn float aim_error(Node* tip, Node* target) @local {
    Vec3 forward = maths::transform_dir(tip.world, { 0, 0, -1 }).normalize();
    Vec3 desired = (target.world_position() - tip.world_position()).normalize();
    return math::acos(math::clamp(forward.dot(desired), -1.0f, 1.0f));
}

fn void test_look_at_spreads_the_turn_by_default_shares() @test {
    ChainRig rig = make_chain();
    defer scene::destroy_scene(&rig.scene);
    rig.target.local.position = { 100, 2, 0 };
    rig.scene.update_world();
    Node*[3] spine = { rig.root, rig.middle, rig.end };

    LookAt look_at = ik::look_at(spine[..], rig.target, { 0, 0, -1 });
    look_at.solve();
    rig.scene.update_world();

    float[3] shares = { 1.0f / 6, 2.0f / 6, 3.0f / 6 };
    foreach (index, joint : spine) {
        assert(close(look_at.weights[index], shares[index], LENGTH_TOLERANCE));
        Quat expected = quaternion::from_axis_angle{float}({ 0, -1, 0 }, (float)math::PI / 2 * shares[index]);
        assert(close_quat(joint.local.rotation, expected));
    }
    assert(aim_error(rig.end, rig.target) <= TOLERANCE);
}

fn void test_look_at_second_pass_corrects_the_tip_swing() @test {
    ChainRig rig = make_chain();
    defer scene::destroy_scene(&rig.scene);
    rig.middle.local.position = { 0, 0, -0.5f };
    rig.end.local.position = { 0, 0, -0.5f };
    rig.target.local.position = { 3, 0, -1 };
    rig.scene.update_world();
    Node*[3] spine = { rig.root, rig.middle, rig.end };

    LookAt look_at = ik::look_at(spine[..], rig.target, { 0, 0, -1 });
    look_at.solve();
    rig.scene.update_world();

    assert(aim_error(rig.end, rig.target) <= AIM_TOLERANCE);
}

fn void test_look_at_valid_rejects_bad_shares_and_broken_chains() @test {
    ChainRig rig = make_chain();
    defer scene::destroy_scene(&rig.scene);
    Node*[3] spine = { rig.root, rig.middle, rig.end };
    LookAt look_at = ik::look_at(spine[..], rig.target, { 0, 0, -1 });
    assert(ik::look_at_valid(&look_at));

    LookAt uneven = look_at;
    uneven.weights[0] += 0.1f;
    assert(!ik::look_at_valid(&uneven));

    LookAt broken = look_at;
    broken.joints[1] = rig.pole;
    assert(!ik::look_at_valid(&broken));
}

fn void test_foot_place_on_floor_height_keeps_the_ankle() @test {
    ChainRig rig = make_chain();
    defer scene::destroy_scene(&rig.scene);
    FootIk foot = rig_foot(&rig);

    foot.place({ .point = { 0, 0, 0 }, .normal = { 0, 1, 0 } }, 0);
    rig.scene.update_world();

    assert(close_vec3(rig.target.world_position(), rig.end.world_position()));
    assert(foot.grounded);
}

fn void test_foot_place_offsets_the_target_by_the_ground() @test {
    ChainRig rig = make_chain();
    defer scene::destroy_scene(&rig.scene);
    Node* holder = rig.scene.add_node(name: "holder")!!;
    holder.local.position = { 1, 0, 0 };
    rig.scene.reparent(rig.target, holder);
    rig.scene.update_world();
    FootIk foot = rig_foot(&rig);

    foot.place({ .point = { 0, -0.3f, 0 }, .normal = { 0, 1, 0 } }, 0);
    rig.scene.update_world();

    assert(close_vec3(rig.target.world_position(), rig.end.world_position() + (Vec3){ 0, -0.3f, 0 }));
    assert(close(foot.ground_offset, -0.3f));
}

fn void test_foot_release_puts_the_target_on_the_ankle() @test {
    ChainRig rig = make_chain();
    defer scene::destroy_scene(&rig.scene);
    FootIk foot = rig_foot(&rig);
    foot.place({ .point = { 0, -0.3f, 0 }, .normal = { 0, 1, 0 } }, 0);

    foot.release();
    rig.scene.update_world();

    assert(close_vec3(rig.target.world_position(), rig.end.world_position()));
    assert(!foot.grounded);
    assert(foot.align_weight == 0);
}

fn void test_foot_align_tilts_up_onto_the_normal() @test {
    ChainRig rig = make_chain();
    defer scene::destroy_scene(&rig.scene);
    FootIk foot = rig_foot(&rig);
    foot.foot_height = 2;
    Vec3 normal = (Vec3){ 0.6f, 0.8f, 0 }.normalize();
    Quat incoming = world_rotation_of(rig.end);

    foot.place({ .point = { 0, 0, 0 }, .normal = normal }, 0);
    foot.align();
    rig.scene.update_world();

    Quat expected = quaternion::from_normalized_rotation{float}({ 0, 1, 0 }, normal) * incoming;
    assert(close(foot.align_weight, 1));
    assert(close_quat(world_rotation_of(rig.end), expected));

    rig.end.local.rotation = quaternion::IDENTITY;
    rig.scene.update_world();
    foot.foot_height = 2 - foot.lift_fade;
    foot.place({ .point = { 0, 0, 0 }, .normal = normal }, 0);
    foot.align();
    assert(foot.align_weight == 0);
    assert(same_quat(rig.end.local.rotation, quaternion::IDENTITY));
}

fn void test_lower_pelvis_drops_by_the_lowest_foot() @test {
    ChainRig rig = make_chain();
    defer scene::destroy_scene(&rig.scene);
    Node* armature = rig.scene.add_node(name: "armature")!!;
    armature.local.rotation = quaternion::from_axis_angle{float}({ 0, 0, 1 }, (float)math::PI / 2);
    armature.local.scale = { 2, 2, 2 };
    Node* pelvis = rig.scene.add_node(armature, "pelvis")!!;
    rig.scene.update_world();
    Vec3 before = pelvis.world_position();

    FootIk[3] feet;
    foreach (&foot : feet) *foot = rig_foot(&rig);
    feet[0].grounded = true;
    feet[0].ground_offset = -0.2f;
    feet[1].grounded = true;
    feet[1].ground_offset = 0.1f;
    feet[2].ground_offset = -0.5f;
    FootIk*[3] pointers = { &feet[0], &feet[1], &feet[2] };

    float drop = ik::lower_pelvis(pelvis, pointers[..]);
    rig.scene.update_world();

    assert(close(drop, 0.2f, LENGTH_TOLERANCE));
    assert(close_vec3(pelvis.world_position() - before, { 0, -0.2f, 0 }, LENGTH_TOLERANCE));

    feet[0].ground_offset = 0;
    Vec3 dropped = pelvis.world_position();
    assert(ik::lower_pelvis(pelvis, pointers[..]) == 0);
    rig.scene.update_world();
    assert(close_vec3(pelvis.world_position(), dropped, 0));
}

fn void test_ik_and_look_at_use_a_world_root_basis() @test {
    ChainRig rig = make_chain();
    defer scene::destroy_scene(&rig.scene);
    Node* holder = rig.scene.add_node()!!;
    holder.local.position = { 5, -3, 4 };
    holder.local.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, 0.7f);
    holder.local.scale = { 2, 2, 2 };
    rig.scene.reparent(rig.root, holder);
    rig.root.transform_space = TransformSpace.WORLD;
    solve_at(&rig, { 1, 1, 0 });
    assert(close_vec3(rig.end.world_position(), rig.target.world_position()));

    rig.root.local.rotation = quaternion::IDENTITY;
    rig.middle.local.rotation = quaternion::IDENTITY;
    rig.middle.local.position = { 0, 0, -0.5f };
    rig.end.local.position = { 0, 0, -0.5f };
    rig.target.local.position = { 3, 0, -1 };
    rig.scene.update_world();
    Node*[3] spine = { rig.root, rig.middle, rig.end };
    LookAt aim = ik::look_at(spine[..], rig.target, { 0, 0, -1 });
    aim.solve();
    rig.scene.update_world();
    assert(aim_error(rig.end, rig.target) <= AIM_TOLERANCE);

    rig.middle.transform_space = TransformSpace.WORLD;
    assert(!ik::ik_chain_valid(&rig.chain));
    assert(!ik::look_at_valid(&aim));
}

fn void test_foot_placement_uses_a_world_target_basis() @test {
    ChainRig rig = make_chain();
    defer scene::destroy_scene(&rig.scene);
    Node* holder = rig.scene.add_node()!!;
    holder.local.position = { 4, 1, -3 };
    holder.local.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, 0.7f);
    rig.scene.reparent(rig.target, holder);
    rig.target.transform_space = TransformSpace.WORLD;
    rig.scene.update_world();
    FootIk foot = rig_foot(&rig);
    foot.place({ .point = { 0, -0.3f, 0 }, .normal = { 0, 1, 0 } }, 0);
    Vec3 expected = rig.end.world_position() + (Vec3){ 0, foot.ground_offset, 0 };
    rig.scene.update_world();
    assert(close_vec3(rig.target.world_position(), expected));
}

fn void test_lower_pelvis_uses_a_world_basis_for_incremental_drops() @test {
    ChainRig rig = make_chain();
    defer scene::destroy_scene(&rig.scene);
    Node* holder = rig.scene.add_node()!!;
    holder.local.position = { 4, 2, -3 };
    holder.local.rotation = quaternion::from_axis_angle{float}({ 0, 0, 1 }, 0.7f);
    holder.local.scale = { 2, 2, 2 };
    Node* pelvis = rig.scene.add_node(holder)!!;
    pelvis.transform_space = TransformSpace.WORLD;
    pelvis.local.position = { 1, 3, 2 };
    rig.scene.update_world();
    FootIk foot = rig_foot(&rig);
    foot.grounded = true;
    foot.ground_offset = -0.2f;
    FootIk*[1] feet = { &foot };

    assert(close(ik::lower_pelvis(pelvis, feet[..]), 0.2f));
    assert(close(ik::lower_pelvis(pelvis, feet[..]), 0.2f));
    assert(close_vec3(pelvis.world_position(), { 1, 3, 2 }));
    rig.scene.update_world();
    assert(close_vec3(pelvis.world_position(), { 1, 2.6f, 2 }));
}

fn void test_legacy_foot_mode_leaves_contact_inactive() @test {
    ChainRig rig = make_chain();
    defer scene::destroy_scene(&rig.scene);
    FootIk foot = rig_foot(&rig);
    foot.place({ .point = { 0, -0.3f, 0 }, .normal = { 0, 1, 0 } }, 0);
    rig.scene.update_world();
    foot.align();
    rig.scene.update_world();
    assert(foot.contact.phase == INACTIVE);
    foot.release();
    rig.scene.update_world();
    assert(foot.contact.phase == INACTIVE && !foot.grounded);
    assert(close_vec3(rig.target.world_position(), rig.end.world_position()));
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
) @local {
    FootContact before = *contact;
    assert(@catch(contact.update_contact(support, incoming, dt)) == c3d::INVALID_ARGUMENT);
    assert(contact_test_same_state(&before, contact));
}

fn ContactRig contact_test_rig() @local {
    ContactRig rig = { .scene = scene::create_scene(mem, { .max_nodes = RIG_NODES }) };
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

fn void contact_test_solve(ContactRig* rig) @local {
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
}

fn void test_contact_extreme_support_scales_retain_finite_world_poses() @test {
    FootSupport large = contact_test_support(1e30f);
    Transform incoming = contact_test_pose({ 1, 0.08f, 0 });
    FootContact distant;
    distant.begin_contact({ .point = { 1, 0, 0 }, .normal = { 0, 1, 0 } }, large, incoming)!!;
    distant.update_contact(large, incoming, 1)!!;
    distant.begin_contact({ .point = { 2, 0, 0 }, .normal = { 0, 1, 0 } }, large, incoming)!!;
    assert(distant.phase == ACQUIRING);
    distant.update_contact(large, incoming, 1)!!;
    assert(math::abs(distant.requested.position.x - 2) <= 1e-6f);

    FootSupport small = contact_test_support(2e-38f);
    incoming.position = { 8, 0.08f, 0 };
    FootContact tiny;
    tiny.begin_contact({ .point = { 8, 0, 0 }, .normal = { 0, 1, 0 } }, small, incoming)!!;
    tiny.update_contact(small, incoming, 1)!!;
    assert(contact_test_vec(tiny.requested.position, incoming.position));
    tiny.end_contact(small, incoming)!!;
    incoming.position.x = 9;
    tiny.update_contact(small, incoming, 0.1f)!!;
    assert(math::abs(tiny.requested.position.x - 8.5f) <= 1e-6f);
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

fn void test_contact_paused_updates_are_idempotent() @test {
    ContactRig rig = contact_test_rig();
    defer scene::destroy_scene(&rig.scene);
    FootSupport support = contact_test_support();
    GroundHit hit = { .point = { 0.1f, 0, 0 }, .normal = { 0, 1, 0 } };
    rig.foot.begin_contact(hit, support)!!;
    rig.foot.update_contact(support, 0.06f)!!;
    contact_test_solve(&rig);
    FootContact before = rig.foot.contact;
    for (uint frame = 0; frame < 100; frame++) {
        contact_test_incoming(&rig);
        rig.foot.update_contact(support, 0)!!;
        contact_test_solve(&rig);
        assert(contact_test_same_state(&before, &rig.foot.contact));
    }

    support.transform.position.x += 0.2f;
    contact_test_incoming(&rig);
    rig.foot.update_contact(support, 0)!!;
    assert(rig.foot.contact.elapsed == before.elapsed);
    assert(contact_test_vec(rig.foot.contact.requested.position - before.requested.position, { 0.1f, 0, 0 }));

    contact_test_incoming(&rig);
    rig.foot.end_contact(support)!!;
    rig.foot.update_contact(support, 0.1f)!!;
    before = rig.foot.contact;
    for (uint frame = 0; frame < 100; frame++) {
        contact_test_incoming(&rig);
        rig.foot.end_contact(support)!!;
        rig.foot.update_contact(support, 0)!!;
        assert(contact_test_same_state(&before, &rig.foot.contact));
    }
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
    );
    changed = support;
    changed.transform.scale = { 1, 2, 1 };
    contact_test_expect_update_fault(
        contact: &contact,
        support: changed,
        incoming: incoming,
        dt: 0,
    );
    contact_test_expect_update_fault(
        contact: &contact,
        support: support,
        incoming: incoming,
        dt: -0.1f,
    );
    Transform invalid = incoming;
    invalid.rotation = {};
    contact_test_expect_update_fault(
        contact: &contact,
        support: support,
        incoming: invalid,
        dt: 0,
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
    for (uint invalid = 0; invalid < 3; invalid++) {
        FootPlantConfig config = ik::FOOT_PLANT_DEFAULT;
        GroundHit bad_hit = hit;
        Transform pose = incoming;
        switch (invalid) {
            case 0:
                bad_hit.normal = {};
            case 1:
                config.sole_forward = config.sole_up;
            case 2:
                pose.rotation = contact_test_rotation({ 1, 0, 0 }, 90);
        }
        fault excuse = @catch(contact.begin_contact(
            hit: bad_hit,
            support: support,
            incoming: pose,
            config: config,
        ));
        assert(excuse == c3d::INVALID_ARGUMENT);
        assert(contact_test_same_state(&before, &contact));
    }
}

fn void test_contact_full_pipeline_retains_slopes_and_moving_scaled_supports() @test {
    Vec3[2] normals = { { 0, 1, 0 }, contact_test_rotation({ 1, 0, 0 }, 20) * (Vec3){ 0, 1, 0 } };
    foreach (normal : normals) {
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
        while (time < 10) {
            float dt = math::min(1.0f / 60, 10 - time);
            time += dt;
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
            contact_test_solve(&rig);
            assert(contact_test_vec(rig.foot.contact.local_point, anchor, 0));
            assert(contact_test_vec(rig.foot.contact.local_normal, local_normal, 0));
            assert(contact_test_vec(rig.foot.contact.local_heading, local_heading, 0));
            if (rig.foot.contact.phase == PLANTED) {
                Transform ankle = maths::transform_from_mat4(rig.ankle.world);
                assert(close_vec3(ankle.position, rig.foot.contact.requested.position, 0.001f));
                assert(close_quat(ankle.rotation, rig.foot.contact.requested.rotation));
                Vec3 actual_sole = ankle.position - ankle.rotation * rig.foot.contact.config.sole_up * 0.08f;
                Vec3 expected_sole = maths::transform_point(support.transform.to_mat4(), (Vec3)anchor);
                assert(contact_test_vec(actual_sole, expected_sole, 0.001f));
            }
        }
    }
}

fn void test_contact_constrained_miss_keeps_the_anchor_planted() @test {
    Vec3[3] points = { { 4, 0, 0 }, { 0.4f, 0.2f, 0 }, { 0.5f, 0.1f, 0 } };
    float[3] weights = { 1, 0.5f, 1 };
    foreach (index, point : points) {
        ContactRig rig = contact_test_rig();
        defer scene::destroy_scene(&rig.scene);
        rig.foot.leg.weight = weights[index];
        if (index == 2) {
            rig.foot.leg.limits[0] = ik::hinge_limit(
                reference: quaternion::IDENTITY,
                axis: { 1, 0, 0 },
                min_angle: 0,
                max_angle: 0,
                twist_axis: { 0, 1, 0 },
            );
        }
        FootSupport support = contact_test_support();
        rig.foot.begin_contact({ .point = point, .normal = { 0, 1, 0 } }, support)!!;
        rig.foot.update_contact(support, 0.12f)!!;
        double[<3>] retained = rig.foot.contact.local_point;
        contact_test_solve(&rig);
        assert(rig.foot.contact.phase == PLANTED);
        assert(contact_test_vec(rig.foot.contact.local_point, retained, 0));
        assert(close_vec3(rig.target.world_position(), rig.foot.contact.requested.position));
        assert((rig.ankle.world_position() - rig.target.world_position()).length() > 0.001f);
    }
}

fn void test_contact_pelvis_adjustment_preserves_the_requested_anchor() @test {
    ContactRig rig = contact_test_rig();
    defer scene::destroy_scene(&rig.scene);
    Node* pelvis = rig.scene.add_node(name: "pelvis")!!;
    rig.scene.reparent(rig.hip, pelvis);
    rig.scene.update_world();
    FootSupport support = contact_test_support();
    rig.foot.begin_contact({ .point = { 0.1f, -0.2f, 0 }, .normal = { 0, 1, 0 } }, support)!!;
    rig.foot.update_contact(support, 0.12f)!!;
    FootContact before = rig.foot.contact;
    FootIk*[1] feet = { &rig.foot };
    float drop = ik::lower_pelvis(pelvis, feet[..]);
    assert(math::abs(drop - 0.2f) <= 1e-6f);
    contact_test_solve(&rig);
    assert(close_vec3(rig.ankle.world_position(), rig.foot.contact.requested.position, 0.001f));
    assert(contact_test_same_state(&before, &rig.foot.contact));
}

fn void test_contact_invalid_adapter_call_preserves_target_and_authoring() @test {
    ContactRig rig = contact_test_rig();
    defer scene::destroy_scene(&rig.scene);
    FootSupport support = contact_test_support();
    rig.foot.begin_contact({ .point = {}, .normal = { 0, 1, 0 } }, support)!!;
    FootIk before = rig.foot;
    Transform target = rig.target.local;
    assert(@catch(rig.foot.update_contact(support, -1)) == c3d::INVALID_ARGUMENT);
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

fn void test_contact_standalone_rebase_preserves_local_state_in_every_phase() @test {
    Vec3[2] offsets = { { 256, 0, -512 }, { 65536, 0, -65536 } };
    foreach (offset : offsets) {
        for (uint phase = 0; phase < 3; phase++) {
            FootSupport support = contact_test_support();
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
            distant_support.transform.position += offset;
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
            distant_support.transform.position -= offset;
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
        }
    }
}

fn void test_contact_scene_rebase_visits_component_owners_once() @test {
    ContactRig rig = contact_test_rig();
    defer scene::destroy_scene(&rig.scene);
    FootSupport support = contact_test_support();
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
    support.transform.position -= offset;
    component.update_contact(support, 0)!!;
    assert(contact_test_vec(component.contact.requested.position, standalone.requested.position));
}
