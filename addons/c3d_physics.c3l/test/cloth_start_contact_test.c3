module c3d_physics_cloth_test;

import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::maths;
import c3d::physics;
import c3d::physics::cloth @public;
import c3d::scene;
import std::math;
import std::math::quaternion;

const uint CAPE_COLUMNS @private = 12;
const uint CAPE_ROWS @private = 22;
const float CAPE_WIDTH @private = 0.5f;
const float CAPE_LENGTH @private = 0.95f;
const float CAPE_THICKNESS @private = 0.02f;
const float CAPE_BEND_COMPLIANCE @private = 0.02f;
const float ARM_BONE_RADIUS @private = 0.06f;
const float ARM_BONE_HALF_LENGTH @private = 0.3f;
const float ARM_BONE_TILT_RADIANS @private = 0.35f; // from vertical, towards the cape plane
const float ARM_BONE_DEPTH_BEHIND_CAPE @private = 0.03f;
const uint START_CONTACT_UPDATES @private = 20;
const float SKINNED_BALL_RADIUS @private = 1.2f; // metres; deeper than one push bound from every corner of the unit quad
const float SKINNED_BALL_DEPTH @private = 0.3f; // metres behind the quad, so the push also bends it

fn Geometry cape_grid(Allocator allocator) @private {
    uint side = CAPE_COLUMNS + 1;
    Geometry grid = {
        .positions = alloc::new_array(allocator, Vec3, (sz)(side * (CAPE_ROWS + 1))),
        .indices   = alloc::new_array(allocator, uint, (sz)(6 * CAPE_COLUMNS * CAPE_ROWS)),
    };
    for (uint row = 0; row <= CAPE_ROWS; row++) {
        for (uint column = 0; column <= CAPE_COLUMNS; column++) {
            grid.positions[row * side + column] = {
                (float)column / CAPE_COLUMNS * CAPE_WIDTH - CAPE_WIDTH * 0.5f,
                -(float)row / CAPE_ROWS * CAPE_LENGTH,
                0,
            };
        }
    }

    usz next;
    for (uint row = 0; row < CAPE_ROWS; row++) {
        for (uint column = 0; column < CAPE_COLUMNS; column++) {
            uint top_left = row * side + column;
            uint bottom_left = top_left + side;
            uint[6] corners = { top_left, bottom_left, top_left + 1, top_left + 1, bottom_left, bottom_left + 1 };
            grid.indices[next:6] = corners[..];
            next += 6;
        }
    }
    grid.finalize();
    return grid;
}

fn void test_cloth_starting_in_contact_recovers() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    maths::Transform across = maths::TRANSFORM_IDENTITY;
    across.rotation = quaternion::from_axis_angle{float}({ 1, 0, 0 }, ARM_BONE_TILT_RADIANS);
    ColliderDesc bone = capsule(ARM_BONE_RADIUS, ARM_BONE_HALF_LENGTH, across);
    Node* body = add_body_node(
        fixture:   &fixture,
        colliders: (&bone)[:1],
        position:  { 0, -0.5f, -ARM_BONE_DEPTH_BEHIND_CAPE },
        kind:      STATIC,
    );
    Entity[1] colliders = { body.id };

    GeometryId source;
    @pool() {
        Geometry grid = cape_grid(tmem);
        source = fixture.assets.add_geometry(&grid)!!;
    };
    Node* node = add_cloth_node(&fixture, source);
    ClothDesc desc = pinned_desc(top_row(CAPE_COLUMNS));
    desc.colliders = colliders[..];
    desc.thickness = CAPE_THICKNESS;
    desc.bend_mode = DIHEDRAL;
    desc.bend_compliance = CAPE_BEND_COMPLIANCE;
    fixture.scene.add_cloth(&fixture.assets, node, desc)!!;
    ClothState* state = state_of(&fixture, node);

    Vec3 half_axis = across.rotation.rotate_vec3({ 0, ARM_BONE_HALF_LENGTH, 0 });
    Vec3 start = maths::translation(body.world) - half_axis;
    Vec3 end = maths::translation(body.world) + half_axis;
    float expanded = ARM_BONE_RADIUS + CAPE_THICKNESS;
    float deepest = expanded;
    foreach (position : state.positions) deepest = math::min(deepest, segment_distance(position, start, end));
    assert(deepest < ARM_BONE_RADIUS);

    for (uint update = 0; update < START_CONTACT_UPDATES; update++) {
        step(&fixture, physics::DEFAULT_FIXED_DT);
        assert(!state.contact_result.failure);
    }
    for (uint vertex = 0; vertex < (CAPE_COLUMNS + 1) * (CAPE_ROWS + 1); vertex++) {
        assert(segment_distance(published_world(&fixture, node, vertex), start, end) >= expanded - CONTACT_TOLERANCE);
    }
}

fn void test_skinned_cloth_starting_in_contact_prepares_clear() @test {
    Fixture fixture;
    setup(&fixture, weightless());
    defer teardown(&fixture);

    GeometryId source = add_skinned_quad(&fixture);
    SkeletonId skeleton = add_two_joint_skeleton(&fixture);
    Node* root_joint = fixture.scene.add_node(name: "root_joint")!!;
    Node* tip_joint = fixture.scene.add_node(root_joint, "tip_joint")!!;
    Node* owner = add_cloth_node(&fixture, source);
    Node*[] joints = alloc::new_array(mem, Node*, 2);
    joints[0] = root_joint;
    joints[1] = tip_joint;
    fixture.scene.add(owner, (SkinBinding){ .skeleton = skeleton, .joints = joints });
    fixture.scene.update_world();

    Vec3 centre = { 0.5f, -0.5f, -SKINNED_BALL_DEPTH };
    ColliderDesc ball = sphere(SKINNED_BALL_RADIUS, centre);
    Node* body = add_body_node(&fixture, (&ball)[:1], kind: STATIC);
    Entity[1] colliders = { body.id };
    ClothDesc desc = cloth::default_cloth_desc();
    desc.bend_mode = DIHEDRAL;
    desc.colliders = colliders[..];
    fixture.scene.attach_cloth(&fixture.assets, owner, desc)!!;
    fixture.physics.update(0);
    cloth::prepare(
        scene:  &fixture.scene,
        assets: &fixture.assets,
        node:   owner,
        world:  &fixture.physics,
    )!!;

    ClothState* state = fixture.scene.get(owner, Cloth).state;
    float reach = SKINNED_BALL_RADIUS + desc.thickness;
    foreach (position : state.positions) assert((position - centre).length() >= reach - CONTACT_TOLERANCE);

    ClothHinge* hinge = &state.hinges[0];
    Vec3[4] points = {
        state.positions[hinge.p0],
        state.positions[hinge.p1],
        state.positions[hinge.p2],
        state.positions[hinge.p3],
    };
    assert(math::abs(cloth::evaluate_hinge_angle(points)!! - hinge.last_angle) <= POSITION_TOLERANCE);
    step(&fixture, physics::DEFAULT_FIXED_DT);
    assert(!state.contact_result.failure);
}
