module c3d_physics_cloth_test;

import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::maths;
import c3d::physics @public;
import c3d::physics::cloth @public;
import c3d::scene;
import std::math;
import std::math::quaternion;

fn Node* continuous_probe(
    Fixture* fixture,
    Vec3 point,
    Entity[] owners,
    bool continuous = true,
    uint limit = cloth::DEFAULT_CCD_ITERATIONS,
    uint contacts = cloth::DEFAULT_CONTACTS,
) @private {
    Node* node = add_cloth_node(fixture, add_triangle(fixture, point, PROBE_REACH));
    uint[2] pins = { 1, 2 };
    ClothDesc desc = pinned_desc(pins[..]);
    desc.substeps = 1;
    desc.iterations = 1;
    desc.stretch_stiffness = desc.bend_stiffness = desc.damping = 0;
    desc.colliders = owners;
    desc.collisions.continuous = continuous;
    desc.collisions.max_ccd_iterations = limit;
    desc.collisions.max_contacts = contacts;
    fixture.scene.add_cloth(&fixture.assets, node, desc)!!;
    return node;
}

fn void test_cloth_continuous_rotating_box_and_mesh_crossing() @test {
    foreach (continuous : (bool[2]){ false, true }) {
        Fixture fixture;
        setup(&fixture, desc: weightless());
        defer teardown(&fixture);

        ColliderDesc box = physics::default_collider_desc(BOX);
        box.half_extents = { 2, 0.05f, 0.2f };
        Node* body = add_body_node(
            fixture: &fixture,
            colliders: (&box)[:1],
            position: {},
            kind: STATIC,
        );
        body.local.rotation = quaternion::from_axis_angle((Vec3){ 0, 0, 1 }, -(float)math::PI / 4);
        fixture.scene.update_world();
        Entity[1] owners = { body.id };
        Node* probe = continuous_probe(
            fixture: &fixture,
            point: { 1.8f, 0, 0 },
            owners: owners[..],
            continuous: continuous,
        );
        publish(&fixture);
        ClothState* state = state_of(&fixture, probe);
        assert(!state.contact_result.failure);

        fixture.physics.update(physics::DEFAULT_FIXED_DT);
        body.local.position = { 0.1f, 0, 0 };
        body.local.rotation = quaternion::from_axis_angle((Vec3){ 0, 0, 1 }, (float)math::PI / 4);
        fixture.scene.update_world();
        fixture.physics.update_cloths();
        assert(!state.contact_result.failure);
        if (continuous) {
            assert(state.contact_result.impacts > 0 && state.contact_result.resweeps > 0);
            assert((state.published[0] - (Vec3){ 1.8f, 0, 0 }).length() > 0.1f);
        } else {
            assert(near(state.published[0], { 1.8f, 0, 0 }));
        }
    }

    Fixture fixture;
    setup(&fixture, weightless());
    defer teardown(&fixture);
    Vec3[3] vertices = { { -1, 0, -1 }, { 1, 0, -1 }, { 0, 0, 2 } };
    uint[3] indices = { 0, 2, 1 };
    Geometry triangle = { .positions = vertices[..], .indices = indices[..] };
    triangle.finalize();
    GeometryId source = fixture.assets.add_geometry(&triangle)!!;
    ColliderDesc mesh = physics::default_collider_desc(MESH);
    mesh.geometry = source;
    Node* body = add_body_node(fixture: &fixture, colliders: (&mesh)[:1], position: {}, kind: STATIC);
    Entity[1] owners = { body.id };
    Node* probe = continuous_probe(fixture: &fixture, point: { 0, 1, 0 }, owners: owners[..]);
    publish(&fixture);
    ClothState* state = state_of(&fixture, probe);
    state.velocities[0] = { 0, -2 / physics::DEFAULT_FIXED_DT, 0 };
    step(&fixture, physics::DEFAULT_FIXED_DT);
    assert(!state.contact_result.failure && state.contact_result.impacts > 0);
    assert(state.published[0].y >= state.desc.thickness - state.desc.collisions.contact_tolerance);
}

fn void test_cloth_continuous_self_edge_and_face_crossings() @test {
    {
        Fixture fixture;
        setup(&fixture, weightless());
        defer teardown(&fixture);

        GeometryId source = add_folded_strip(&fixture);
        GeometryAsset* geometry = fixture.assets.geometry(source);
        for (uint vertex = 8; vertex < 12; vertex++) geometry.data.positions[vertex].y = 1;
        geometry.data.finalize();
        Node* node = add_cloth_node(&fixture, source);
        ClothDesc desc = folded_desc();
        desc.substeps = desc.iterations = 1;
        desc.stretch_stiffness = desc.bend_stiffness = desc.damping = 0;
        desc.collisions.continuous = true;
        fixture.scene.add_cloth(&fixture.assets, node, desc)!!;
        publish(&fixture);
        ClothState* state = state_of(&fixture, node);

        for (uint vertex = 8; vertex < 12; vertex++) state.velocities[vertex].y = -2 / physics::DEFAULT_FIXED_DT;
        step(&fixture, physics::DEFAULT_FIXED_DT);
        assert(!state.contact_result.failure && state.contact_result.impacts > 0 && state.contact_result.edge_edge_impacts > 0);
        check_folded_contacts(state, false);
    }

    {
        Fixture fixture;
        setup(&fixture, weightless());
        defer teardown(&fixture);

        Vec3[6] positions = {
            { -1, 0, -1 }, { 1, 0, -1 }, { -1, 0, 1 },
            { -0.6f, 1, -0.8f }, { -0.4f, 1, -0.8f }, { -0.6f, 1, -0.6f },
        };
        uint[6] indices = { 0, 2, 1, 3, 5, 4 };
        Geometry geometry = { .positions = positions[..], .indices = indices[..] };
        geometry.finalize();
        GeometryId source = fixture.assets.add_geometry(&geometry)!!;
        Node* node = add_cloth_node(&fixture, source);
        ClothDesc desc = folded_desc();
        desc.substeps = desc.iterations = 1;
        desc.stretch_stiffness = desc.bend_stiffness = desc.damping = 0;
        desc.collisions.continuous = true;
        fixture.scene.add_cloth(&fixture.assets, node, desc)!!;
        publish(&fixture);
        ClothState* state = state_of(&fixture, node);

        for (uint vertex = 3; vertex < 6; vertex++) state.velocities[vertex].y = -2 / physics::DEFAULT_FIXED_DT;
        step(&fixture, physics::DEFAULT_FIXED_DT);
        assert(!state.contact_result.failure && state.contact_result.vertex_face_impacts > 0);
        assert(state.published[0].y < 0 && state.published[3].y < 1);
    }
}

fn void test_cloth_continuous_structural_and_discontinuity_histories() @test {
    Fixture fixture;
    setup(&fixture, weightless());
    defer teardown(&fixture);

    ColliderDesc box = physics::default_collider_desc(BOX);
    box.half_extents = { 10, 0.01f, 10 };
    Node* body = add_body_node(fixture: &fixture, colliders: (&box)[:1], position: {}, kind: STATIC);
    Entity[1] owners = { body.id };
    Node* node = add_cloth_node(&fixture, add_triangle(&fixture, { 0, 1, 0 }, PROBE_REACH));
    uint[2] pins = { 1, 2 };
    ClothDesc desc = pinned_desc(pins[..]);
    desc.substeps = desc.iterations = 1;
    desc.stretch_stiffness = 1;
    desc.bend_stiffness = desc.damping = 0;
    desc.colliders = owners[..];
    desc.collisions.continuous = true;
    fixture.scene.add_cloth(&fixture.assets, node, desc)!!;
    publish(&fixture);

    fixture.physics.update(physics::DEFAULT_FIXED_DT);
    node.local.position.y = -6;
    fixture.scene.update_world();
    fixture.physics.update_cloths();
    ClothState* state = state_of(&fixture, node);
    assert(!state.contact_result.failure && state.contact_result.impacts > 0);
    assert(state.published[0].y >= box.half_extents.y + desc.thickness - desc.collisions.contact_tolerance);

    Vec3 offset = { 256, 0, -256 };
    Vec3 published_body = state.bodies[0].published.position;
    fixture.scene.shift_origin(offset);
    fixture.scene.update_world();
    fixture.physics.shift_origin(&fixture.scene, offset);
    assert(state.bodies[0].published.position == published_body - offset && state.path_count == 0);
    publish(&fixture);
    assert(!state.contact_result.failure);

    fixture.scene.remove_cloth(node);
    Node* reset_probe = continuous_probe(fixture: &fixture, point: { 0, 1, 0 }, owners: owners[..]);
    publish(&fixture);
    state = state_of(&fixture, reset_probe);
    fixture.physics.teleport(node: body, position: { 0, 2, 0 }, rotation: maths::TRANSFORM_IDENTITY.rotation);
    publish(&fixture);
    assert(!state.contact_result.failure && state.contact_result.impacts == 0);
}

fn void test_cloth_continuous_failure_rollback_and_resweep() @test {
    Fixture fixture;
    setup(&fixture, weightless());
    defer teardown(&fixture);
    ColliderDesc box = physics::default_collider_desc(BOX);
    box.half_extents = { 2, 0.05f, 0.2f };
    Node* moving = add_body_node(fixture: &fixture, colliders: (&box)[:1], position: {}, kind: STATIC);
    moving.local.rotation = quaternion::from_axis_angle((Vec3){ 0, 0, 1 }, -(float)math::PI / 4);
    ColliderDesc ball = sphere(0.08f);
    Node* obstacle = add_body_node(
        fixture: &fixture, colliders: (&ball)[:1], position: { 1.5244f, 0.6652f, 0 }, kind: STATIC,
    );
    fixture.scene.update_world();

    Entity[1] single_owner = { moving.id };
    Node* nonconvergent = continuous_probe(
        fixture: &fixture, point: { 1.8f, 0, 0 }, owners: single_owner[..], limit: 1,
    );
    Entity[2] both_owners = { moving.id, obstacle.id };
    Node* curved = continuous_probe(
        fixture: &fixture, point: { 1.8f, 0, 0 }, owners: both_owners[..], contacts: 1,
    );
    publish(&fixture);

    ClothState* state_a = state_of(&fixture, nonconvergent);
    ClothState* state_b = state_of(&fixture, curved);
    Vec3 original = state_a.published[0];
    uint revision_a = geometry_of(&fixture, nonconvergent).header.revision;

    fixture.physics.update(physics::DEFAULT_FIXED_DT);
    moving.local.position = { 0.1f, 0, 0 };
    moving.local.rotation = quaternion::from_axis_angle((Vec3){ 0, 0, 1 }, (float)math::PI / 4);
    fixture.scene.update_world();
    fixture.physics.update_cloths();

    assert(state_a.contact_result.failure == cloth::CONTACT_NONCONVERGENT && state_a.published[0] == original);
    assert(geometry_of(&fixture, nonconvergent).header.revision == revision_a);
    assert(state_b.contact_result.failure == c3d::CAPACITY_EXCEEDED && state_b.contact_result.resweeps == 1);
    assert(state_b.published[0] == original);

    cloth::reset_contact_history(fixture.scene.get(nonconvergent, Cloth));
    step(&fixture, physics::DEFAULT_FIXED_DT);
    assert(!state_a.contact_result.failure);
}

