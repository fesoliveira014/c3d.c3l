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

struct ChainRig @local {
    Scene   scene;
    Node*   root;
    Node*   middle;
    Node*   end;
    Node*   target;
    Node*   pole;
    IkChain chain;
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

    LookAt clamped = ik::look_at(rig.pole, rig.target, { 0, 0, -1 });
    clamped.max_angle = 0.25f;
    clamped.solve();
    rig.scene.update_world();
    Vec3 forward = maths::transform_dir(rig.pole.world, { 0, 0, -1 }).normalize();
    assert(close(math::acos(math::clamp(forward.dot({ 0, 0, -1 }), -1.0f, 1.0f)), 0.25f));

    rig.pole.local.rotation = quaternion::IDENTITY;
    rig.scene.update_world();
    LookAt free = ik::look_at(rig.pole, rig.target, { 0, 0, -1 });
    free.solve();
    rig.scene.update_world();
    forward = maths::transform_dir(rig.pole.world, { 0, 0, -1 }).normalize();
    assert(close_vec3(forward, { 1, 0, 0 }));
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
