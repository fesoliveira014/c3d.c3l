module c3d_physics_cloth_test;

import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::maths;
import c3d::physics @public;
import c3d::physics::cloth @public;
import c3d::scene;
import std::io;
import std::math;
import std::math::quaternion;
import std::core::mem::allocators;

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
        TrackingAllocator tracker;
        tracker.init(mem);
        defer tracker.free();
        Fixture fixture;
        setup(&fixture, desc: weightless(), allocator: &tracker);
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
        io::printfn(
            "continuous_box,enabled,%s,failure,%s,stage,%s,sweeps,%s,iterations,%s,impacts,%s,resweeps,%s,point,%s",
            continuous,
            state.contact_result.failure,
            state.contact_result.stage,
            state.contact_result.sweeps,
            state.contact_result.ccd_iterations,
            state.contact_result.impacts,
            state.contact_result.resweeps,
            state.published[0]
        );
        assert(!state.contact_result.failure);
        if (continuous) {
            assert(state.contact_result.impacts > 0 && state.contact_result.resweeps > 0);
            assert((state.published[0] - (Vec3){ 1.8f, 0, 0 }).length() > 0.1f);
        } else {
            assert(near(state.published[0], { 1.8f, 0, 0 }));
        }
        Vec3 local = body.local.rotation.conjugate().rotate_vec3(state.published[0] - body.local.position);
        Vec3 delta = local - math::clamp(local, -box.half_extents, box.half_extents);
        assert(delta.length() >= state.desc.thickness - state.desc.collisions.contact_tolerance);
        usz state_bytes;
        @pool() {
            foreach (allocation : tracker.allocations_tlist(tmem)) {
                if (allocation.ptr == state) state_bytes = (usz)allocation.size;
            }
        };
        usz scratch_bytes = state.staged_shapes.len * ClothShape::size + state.staged_bodies.len * ClothBody::size
          + state.frames.len * ContactFrame::size + state.candidates.len * ClothCandidate::size
          + state.contacts.len * ClothContact::size + state.self_primitives.len * ClothSelfPrimitive::size;
        scratch_bytes += Vec3::size * (state.staged_positions.len + state.staged_velocities.len + state.staged_published.len
          + state.staged_pin_anchors.len + state.staged_shape_starts.len + state.staged_shape_ends.len
          + state.local_output.len + state.local_normals.len + state.publication_roundtrip.len
          + state.staged_predicted.len + state.staged_accelerations.len + state.staged_pin_targets.len + state.sweep_start.len);
        scratch_bytes += state.sweep_bounds.len * Aabb::size + state.path_heads.len * usz::size
          + state.path_nodes.len * ClothPathNode::size + state.path_values.len * ContactIntervals::size
          + state.body_motions.len * ContactMotion::size;
        ClothStats stats = fixture.physics.cloth_stats;
        io::printfn(
            "cloth_continuous_measurement,continuous,%s,steps,1,particles,3,triangles,1,bodies,1,state_bytes,%s,prepared_scratch_bytes,%s,solve_ms,%.9f,publish_ms,%.9f,candidates,%s,contacts,%s,peak_candidates,%s,peak_contacts,%s,ccd_iterations,%s,impacts,%s,failed,%s,max_residual,%.9f",
            continuous,
            state_bytes,
            scratch_bytes,
            stats.solve_seconds * 1000,
            stats.publish_seconds * 1000,
            state.contact_result.candidates,
            state.contact_result.contacts,
            state.contact_result.peak_candidates,
            state.contact_result.peak_contacts,
            state.contact_result.ccd_iterations,
            state.contact_result.impacts,
            stats.failed,
            state.contact_result.max_residual
        );
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
    Node* body = add_body_node(
        fixture: &fixture,
        colliders: (&mesh)[:1],
        position: {},
        kind: STATIC,
    );
    Entity[1] owners = { body.id };
    Node* probe = continuous_probe(fixture: &fixture, point: { 0, 1, 0 }, owners: owners[..]);
    publish(&fixture);
    ClothState* state = state_of(&fixture, probe);
    state.velocities[0] = { 0, -2 / physics::DEFAULT_FIXED_DT, 0 };
    step(&fixture, physics::DEFAULT_FIXED_DT);
    io::printfn(
        "continuous_mesh,failure,%s,stage,%s,iterations,%s,impacts,%s,point,%s",
        state.contact_result.failure,
        state.contact_result.stage,
        state.contact_result.ccd_iterations,
        state.contact_result.impacts,
        state.published[0]
    );
    assert(!state.contact_result.failure && state.contact_result.impacts > 0);
    assert(state.published[0].y >= state.desc.thickness - state.desc.collisions.contact_tolerance);
}

fn void test_cloth_continuous_folded_crossings_and_step_splits() @test {
    for (uint split = 0; split < 3; split++) {
        Fixture fixture;
        PhysicsDesc settings = weightless();
        if (split == 2) settings.tuning.fixed_dt /= 2;
        setup(&fixture, settings);
        defer teardown(&fixture);
        GeometryId source = add_folded_strip(&fixture);
        GeometryAsset* geometry = fixture.assets.geometry(source);
        for (uint vertex = 8; vertex < 12; vertex++) geometry.data.positions[vertex].y = 1;
        geometry.data.finalize();
        Node* node = add_cloth_node(&fixture, source);
        ClothDesc desc = folded_desc();
        desc.substeps = split == 1 ? 4 : split == 2 ? 2 : 1;
        desc.iterations = 1;
        desc.stretch_stiffness = desc.bend_stiffness = desc.damping = 0;
        desc.collisions.continuous = true;
        fixture.scene.add_cloth(&fixture.assets, node, desc)!!;
        publish(&fixture);
        ClothState* state = state_of(&fixture, node);
        assert(!state.contact_result.failure);
        for (uint vertex = 8; vertex < 12; vertex++) state.velocities[vertex].y = -2 / physics::DEFAULT_FIXED_DT;
        step(&fixture, physics::DEFAULT_FIXED_DT);
        io::printfn(
            "continuous_fold,split,%s,failure,%s,stage,%s,iterations,%s,impacts,%s,resweeps,%s,upper,%s,lower,%s",
            split,
            state.contact_result.failure,
            state.contact_result.stage,
            state.contact_result.ccd_iterations,
            state.contact_result.impacts,
            state.contact_result.resweeps,
            state.published[10],
            state.published[0]
        );
        assert(!state.contact_result.failure && state.contact_result.impacts > 0 && state.contact_result.resweeps > 0);
        assert(state.contact_result.edge_edge_impacts > 0);
        check_folded_contacts(state, false);
        SelfVector face_normal = ((SelfVector)state.published[2] - (SelfVector)state.published[0])
          .cross((SelfVector)state.published[1] - (SelfVector)state.published[0]);
        double signed_face = ((SelfVector)state.published[10] - (SelfVector)state.published[0]).dot(face_normal) / face_normal.length();
        SelfVector edge_normal = ((SelfVector)state.published[2] - (SelfVector)state.published[1])
          .cross((SelfVector)state.published[11] - (SelfVector)state.published[10]);
        double signed_edge = ((SelfVector)state.published[10] - (SelfVector)state.published[1]).dot(edge_normal) / edge_normal.length();
        assert(signed_face >= 2.0 * desc.thickness - desc.collisions.contact_tolerance);
        assert(signed_edge >= 2.0 * desc.thickness - desc.collisions.contact_tolerance);
    }
}

fn void test_cloth_continuous_face_crossing_and_step_splits() @test {
    for (uint split = 0; split < 3; split++) {
        Fixture fixture;
        PhysicsDesc settings = weightless();
        if (split == 2) settings.tuning.fixed_dt /= 2;
        setup(&fixture, settings);
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
        desc.substeps = split == 1 ? 4 : split == 2 ? 2 : 1;
        desc.iterations = 1;
        desc.stretch_stiffness = desc.bend_stiffness = desc.damping = 0;
        desc.collisions.continuous = true;
        fixture.scene.add_cloth(&fixture.assets, node, desc)!!;
        publish(&fixture);
        ClothState* state = state_of(&fixture, node);
        assert(!state.contact_result.failure);
        for (uint vertex = 3; vertex < 6; vertex++) state.velocities[vertex].y = -2 / physics::DEFAULT_FIXED_DT;
        step(&fixture, physics::DEFAULT_FIXED_DT);
        io::printfn(
            "continuous_face,split,%s,failure,%s,iterations,%s,vertex_face_impacts,%s,edge_edge_impacts,%s",
            split,
            state.contact_result.failure,
            state.contact_result.ccd_iterations,
            state.contact_result.vertex_face_impacts,
            state.contact_result.edge_edge_impacts
        );
        assert(!state.contact_result.failure && state.contact_result.vertex_face_impacts > 0);
        SelfVector normal = ((SelfVector)state.published[2] - (SelfVector)state.published[0])
          .cross((SelfVector)state.published[1] - (SelfVector)state.published[0]);
        for (uint vertex = 3; vertex < 6; vertex++) {
            double signed_distance = ((SelfVector)state.published[vertex] - (SelfVector)state.published[0]).dot(normal) / normal.length();
            assert(signed_distance >= 2.0 * desc.thickness - desc.collisions.contact_tolerance);
        }
        assert(state.published[0].y < 0 && state.published[3].y < 1);
    }
}

fn void test_cloth_continuous_structural_correction_is_swept() @test {
    foreach (continuous : (bool[2]){ false, true }) {
        Fixture fixture;
        setup(&fixture, weightless());
        defer teardown(&fixture);
        ColliderDesc box = physics::default_collider_desc(BOX);
        box.half_extents = { 10, 0.01f, 10 };
        Node* body = add_body_node(
            fixture: &fixture,
            colliders: (&box)[:1],
            position: {},
            kind: STATIC,
        );
        Entity[1] owners = { body.id };
        Node* node = add_cloth_node(&fixture, add_triangle(&fixture, { 0, 1, 0 }, PROBE_REACH));
        uint[2] pins = { 1, 2 };
        ClothDesc desc = pinned_desc(pins[..]);
        desc.substeps = desc.iterations = 1;
        desc.stretch_stiffness = 1;
        desc.bend_stiffness = desc.damping = 0;
        desc.colliders = owners[..];
        desc.collisions.continuous = continuous;
        fixture.scene.add_cloth(&fixture.assets, node, desc)!!;
        publish(&fixture);
        fixture.physics.update(physics::DEFAULT_FIXED_DT);
        node.local.position.y = -6;
        fixture.scene.update_world();
        fixture.physics.update_cloths();
        ClothState* state = state_of(&fixture, node);
        io::printfn(
            "continuous_structural,enabled,%s,failure,%s,impacts,%s,point,%s",
            continuous,
            state.contact_result.failure,
            state.contact_result.impacts,
            state.published[0]
        );
        assert(!state.contact_result.failure);
        if (continuous) {
            assert(
                state.contact_result.impacts > 0
                  && state.published[0].y >= box.half_extents.y + desc.thickness - desc.collisions.contact_tolerance
            );
        } else {
            assert(state.published[0].y < -1);
        }
        foreach (pin : pins) assert(state.published[pin] == maths::transform_point(node.world, state.rest[pin]));
    }
}

fn void test_cloth_continuous_zero_step_and_discontinuity_histories() @test {
    Fixture fixture;
    setup(&fixture, weightless());
    defer teardown(&fixture);
    ColliderDesc box = physics::default_collider_desc(BOX);
    box.half_extents = { 2, 0.05f, 0.2f };
    Node* body = add_body_node(
        fixture: &fixture,
        colliders: (&box)[:1],
        position: {},
        kind: STATIC,
    );
    Quat first = quaternion::from_axis_angle((Vec3){ 0, 0, 1 }, -(float)math::PI / 4);
    Quat last = quaternion::from_axis_angle((Vec3){ 0, 0, 1 }, (float)math::PI / 4);
    body.local.rotation = first;
    fixture.scene.update_world();
    Entity[1] owners = { body.id };
    Node* node = continuous_probe(fixture: &fixture, point: { 1.8f, 0, 0 }, owners: owners[..]);
    publish(&fixture);
    ClothState* state = state_of(&fixture, node);
    maths::Transform solved_body = state.bodies[0].solved;
    Vec3[3] solved = { state.positions[0], state.positions[1], state.positions[2] };
    Vec3[3] velocities = { state.velocities[0], state.velocities[1], state.velocities[2] };
    Vec3[2] anchors = { state.pin_anchors[0], state.pin_anchors[1] };
    fixture.physics.update(0);
    body.local.position = { 0.1f, 0, 0 };
    body.local.rotation = last;
    node.local.position.z = 0.1f;
    fixture.scene.update_world();
    fixture.physics.update_cloths();
    assert(!state.contact_result.failure && state.contact_result.impacts > 0);
    assert(state.positions == solved[..] && state.velocities == velocities[..] && state.pin_anchors == anchors[..]);
    assert(
        state.bodies[0].solved.position == solved_body.position
          && state.bodies[0].solved.rotation.v == solved_body.rotation.v
    );
    assert(state.bodies[0].published.position == body.local.position);
    assert(state.pin_targets[0] == maths::transform_point(node.world, state.rest[state.pins[0]]));
    step(&fixture, physics::DEFAULT_FIXED_DT);
    assert(!state.contact_result.failure && state.contact_result.impacts > 0);
    assert(state.bodies[0].solved.position == body.local.position);

    Vec3 offset = { 256, 0, -256 };
    Vec3 published_body = state.bodies[0].published.position;
    Vec3 velocity = state.velocities[0];
    Vec3 local_point = geometry_of(&fixture, node).data.positions[0];
    ContactVector path_point = state.path_nodes[0].start;
    fixture.scene.shift_origin(offset);
    fixture.scene.update_world();
    fixture.physics.shift_origin(&fixture.scene, offset);
    assert(state.bodies[0].published.position == published_body - offset);
    assert(state.velocities[0] == velocity && geometry_of(&fixture, node).data.positions[0] == local_point);
    assert(state.path_nodes[0].start == path_point - (ContactVector)offset && state.path_count == 0);
    publish(&fixture);
    assert(!state.contact_result.failure);

    fixture.scene.remove_cloth(node);
    fixture.physics.teleport(node: body, position: {}, rotation: first);
    Node* reset_probe = continuous_probe(fixture: &fixture, point: { 1.8f, 0, 0 }, owners: owners[..]);
    publish(&fixture);
    state = state_of(&fixture, reset_probe);
    fixture.physics.teleport(node: body, position: { 0.1f, 0, 0 }, rotation: last);
    publish(&fixture);
    assert(!state.contact_result.failure && state.contact_result.impacts == 0);
    assert(near(state.published[0], { 1.8f, 0, 0 }));
    fixture.physics.update(0);
    body.local.position = {};
    body.local.rotation = first;
    fixture.scene.update_world();
    cloth::reset_contact_history(fixture.scene.get(reset_probe, Cloth));
    fixture.physics.update_cloths();
    assert(!state.contact_result.failure && state.contact_result.impacts == 0);
    assert(near(state.published[0], { 1.8f, 0, 0 }));
}

fn void test_cloth_continuous_iteration_failure_rolls_back_and_recovers() @test {
    Fixture fixture;
    setup(&fixture, weightless());
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
    Node* node = continuous_probe(
        fixture: &fixture,
        point: { 1.8f, 0, 0 },
        owners: owners[..],
        limit: 1,
    );
    Node* other = continuous_probe(fixture: &fixture, point: { 8, 3, 0 }, owners: {});
    publish(&fixture);
    ClothState* state = state_of(&fixture, node);
    ClothState* other_state = state_of(&fixture, other);
    other_state.velocities[0] = { 1, 0, 0 };
    Vec3[3] positions = { state.positions[0], state.positions[1], state.positions[2] };
    Vec3[3] velocities = { state.velocities[0], state.velocities[1], state.velocities[2] };
    Vec3[3] published = { state.published[0], state.published[1], state.published[2] };
    Vec3[2] anchors = { state.pin_anchors[0], state.pin_anchors[1] };
    ClothBody history = state.bodies[0];
    uint revision = geometry_of(&fixture, node).header.revision;
    fixture.physics.update(physics::DEFAULT_FIXED_DT);
    body.local.position = { 0.1f, 0, 0 };
    body.local.rotation = quaternion::from_axis_angle((Vec3){ 0, 0, 1 }, (float)math::PI / 4);
    fixture.scene.update_world();
    fixture.physics.update_cloths();
    assert(
        state.contact_result.failure == cloth::CONTACT_NONCONVERGENT
          && state.contact_result.stage == ClothContactStage.CONTACTS
    );
    assert(state.positions == positions[..] && state.velocities == velocities[..] && state.published == published[..]);
    assert(state.pin_anchors == anchors[..] && geometry_of(&fixture, node).header.revision == revision);
    assert(
        state.bodies[0].solved.rotation.v == history.solved.rotation.v
          && state.bodies[0].published.rotation.v == history.published.rotation.v
    );
    assert(
        state.bodies[0].solved.position == history.solved.position
          && state.bodies[0].published.position == history.published.position
    );
    assert(
        state.bodies[0].current.position == history.current.position
          && state.bodies[0].current.rotation.v == history.current.rotation.v
    );
    assert(
        state.bodies[0].observed == history.observed
          && state.bodies[0].published_observed == history.published_observed
    );
    assert(state.bodies[0].native_identity == history.native_identity);
    assert(!other_state.contact_result.failure && other_state.positions[0].x > 8);

    fixture.physics.update(0);
    node.local.position.x = 0.25f;
    fixture.scene.update_world();
    fixture.physics.update_cloths();
    assert(state.contact_result.failure == cloth::CONTACT_NONCONVERGENT);
    assert(state.positions == positions[..] && state.published == published[..]);
    assert(state.pin_targets == anchors[..] && state.pin_anchors == anchors[..]);
    assert(
        state.bodies[0].solved.position == history.solved.position
          && state.bodies[0].published.position == history.published.position
    );
    assert(geometry_of(&fixture, node).header.revision == revision + 1);
    foreach (index, point : published) assert(near(published_world(&fixture, node, (uint)index), point));
    Vec3[3] local = { geometry_of(&fixture, node).data.positions[0], geometry_of(&fixture, node).data.positions[1], geometry_of(&fixture, node).data.positions[2] };
    fixture.physics.update(0);
    node.local.scale = { 1e-39f, 1e-39f, 1e-39f };
    fixture.scene.update_world();
    fixture.physics.update_cloths();
    assert(
        state.contact_result.failure == cloth::CONTACT_PRECISION_EXCEEDED
          && state.contact_result.stage == ClothContactStage.REEXPRESSION
    );
    assert(
        geometry_of(&fixture, node).data.positions == local[..]
          && geometry_of(&fixture, node).header.revision == revision + 1
    );
    assert(state.positions == positions[..] && state.published == published[..]);
    node.local.scale = { 1, 1, 1 };
    fixture.scene.update_world();
    cloth::reset_contact_history(fixture.scene.get(node, Cloth));
    step(&fixture, physics::DEFAULT_FIXED_DT);
    assert(!state.contact_result.failure);
}

fn void test_cloth_continuous_curved_response_regenerates_other_candidates() @test {
    Fixture fixture;
    setup(&fixture, weightless());
    defer teardown(&fixture);
    ColliderDesc box = physics::default_collider_desc(BOX);
    box.half_extents = { 2, 0.05f, 0.2f };
    Node* moving = add_body_node(
        fixture: &fixture,
        colliders: (&box)[:1],
        position: {},
        kind: STATIC,
    );
    moving.local.rotation = quaternion::from_axis_angle((Vec3){ 0, 0, 1 }, -(float)math::PI / 4);
    ColliderDesc ball = sphere(0.08f);
    Node* obstacle = add_body_node(
        fixture: &fixture,
        colliders: (&ball)[:1],
        position: { 1.5244f, 0.6652f, 0 },
        kind: STATIC,
    );
    fixture.scene.update_world();
    Entity[2] owners = { moving.id, obstacle.id };
    Node* node = continuous_probe(
        fixture: &fixture,
        point: { 1.8f, 0, 0 },
        owners: owners[..],
        contacts: 1,
    );
    publish(&fixture);
    ClothState* state = state_of(&fixture, node);
    assert(!state.contact_result.failure);
    Vec3 original = state.published[0];
    uint revision = geometry_of(&fixture, node).header.revision;
    fixture.physics.update(physics::DEFAULT_FIXED_DT);
    moving.local.position = { 0.1f, 0, 0 };
    moving.local.rotation = quaternion::from_axis_angle((Vec3){ 0, 0, 1 }, (float)math::PI / 4);
    fixture.scene.update_world();
    fixture.physics.update_cloths();
    io::printfn(
        "continuous_curve,failure,%s,stage,%s,contacts,%s,impacts,%s,resweeps,%s",
        state.contact_result.failure,
        state.contact_result.stage,
        state.contact_result.contacts,
        state.contact_result.impacts,
        state.contact_result.resweeps
    );
    assert(
        state.contact_result.failure == c3d::CAPACITY_EXCEEDED
          && state.contact_result.stage == ClothContactStage.CONTACTS
    );
    assert(
        state.contact_result.impacts == 1
          && state.contact_result.resweeps == 1
          && state.contact_result.contacts >= 2
    );
    assert(
        state.positions[0] == original
          && state.published[0] == original
          && geometry_of(&fixture, node).header.revision == revision
    );
}

fn void test_cloth_continuous_rebuild_and_prepared_allocation_lifetime() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        Fixture fixture;
        PhysicsDesc settings = weightless();
        settings.snapshot_capacity = 2;
        setup(&fixture, desc: settings, allocator: &tracker);
        defer teardown(&fixture);
        GeometryId geometry;
        @pool() {
            Geometry box = geometry::box(
                allocator: tmem,
                width: 2,
                height: 1,
                depth: 2,
            );
            geometry = fixture.assets.add_geometry(&box)!!;
        };
        ColliderDesc hull = physics::default_collider_desc(HULL);
        hull.geometry = geometry;
        Node* body = add_body_node(
            fixture: &fixture,
            colliders: (&hull)[:1],
            position: { -3, 0, 0 },
            kind: STATIC,
        );
        Entity owner = body.id;
        Entity[1] owners = { owner };
        ClothCollisionDesc limits = cloth::default_cloth_collision_desc();
        limits.continuous = true;
        limits.max_shapes = 2;
        Node* probe = bounded_probe(
            fixture: &fixture,
            point: { 0, 0.4f, 0 },
            colliders: owners[..],
            collisions: limits,
        );
        publish(&fixture);
        ClothState* state = state_of(&fixture, probe);
        assert(!state.contact_result.failure);
        SnapshotHandle previous = state.shapes[0].snapshot;
        @pool() {
            Geometry taller = geometry::box(
                allocator: tmem,
                width: 2,
                height: 2,
                depth: 2,
            );
            fixture.assets.replace_geometry(geometry, &taller)!!;
        };
        body.local.position.x = 3;
        fixture.scene.update_world();
        fixture.scene.get(body, PhysicsBody).mark_changed();
        fixture.physics.update(0);
        fixture.scene.update_world();
        sz allocations = tracker.total_allocation_count();
        fixture.physics.update_cloths();
        assert(tracker.total_allocation_count() == allocations);
        assert(!state.contact_result.failure && state.contact_result.impacts == 0);
        assert(
            state.shapes[0].snapshot.index != previous.index
              || state.shapes[0].snapshot.generation != previous.generation
        );
        assert(state.bodies[0].solved.position.x == 3 && state.bodies[0].published.position.x == 3);

        CompoundChild[3] children;
        children[0] = physics::default_compound_child(HULL);
        children[0].geometry = geometry;
        children[1] = physics::default_compound_child(SPHERE);
        children[1].radius = 0.25f;
        children[1].local.position = { 2, 0, 0 };
        children[2] = children[1];
        ColliderDesc compound = physics::default_collider_desc(COMPOUND);
        compound.children = children[..];
        fixture.physics.remove_body(body);
        fixture.physics.add_body(body, physics::default_body_desc(STATIC), (&compound)[:1])!!;
        publish(&fixture);
        assert(
            state.contact_result.failure == c3d::CAPACITY_EXCEEDED
              && state.contact_result.stage == ClothContactStage.BINDINGS
        );
        assert(state.shapes.len == 1 && state.published[0] == (Vec3){ 0, 0.4f, 0 });
        fixture.physics.remove_body(body);
        compound.children = children[:2];
        fixture.physics.add_body(body, physics::default_body_desc(STATIC), (&compound)[:1])!!;
        fixture.physics.update(0);
        fixture.scene.update_world();
        allocations = tracker.total_allocation_count();
        fixture.physics.update_cloths();
        assert(
            tracker.total_allocation_count() == allocations
              && !state.contact_result.failure
              && state.shapes.len == 2
        );

        GeometryId fold_source = add_folded_strip(&fixture);
        GeometryAsset* fold_geometry = fixture.assets.geometry(fold_source);
        for (uint vertex = 8; vertex < 12; vertex++) fold_geometry.data.positions[vertex].y = 1;
        fold_geometry.data.finalize();
        Node* fold = add_cloth_node(&fixture, fold_source);
        ClothDesc desc = folded_desc();
        desc.colliders = owners[..];
        desc.substeps = desc.iterations = 1;
        desc.stretch_stiffness = desc.bend_stiffness = desc.damping = 0;
        desc.collisions.max_shapes = 2;
        desc.collisions.continuous = true;
        fixture.scene.add_cloth(&fixture.assets, fold, desc)!!;
        publish(&fixture);
        ClothState* folded = state_of(&fixture, fold);
        assert(!folded.contact_result.failure);
        for (uint vertex = 8; vertex < 12; vertex++) folded.velocities[vertex].y = -2 / physics::DEFAULT_FIXED_DT;
        step(&fixture, physics::DEFAULT_FIXED_DT);
        assert(!folded.contact_result.failure && folded.contact_result.impacts > 0);
        folded.velocities[..] = (Vec3){};
        for (uint update = 0; update < 12; update++) {
            fixture.physics.update((float)(update % 3) * physics::DEFAULT_FIXED_DT);
            fixture.scene.update_world();
            allocations = tracker.total_allocation_count();
            fixture.physics.update_cloths();
            assert(tracker.total_allocation_count() == allocations);
            assert(!state.contact_result.failure && !folded.contact_result.failure);
        }
        fixture.scene.remove_cloth(fold);
        assert(c3d::same_id(fixture.scene.get(fold, Mesh).geometry, fold_source));
        assert(!fixture.scene.get(fold, Mesh).vertex_motion);
        fixture.scene.remove(body);
        Node* replacement = add_body_node(
            fixture: &fixture,
            colliders: (&hull)[:1],
            position: {},
            kind: STATIC,
        );
        assert(replacement.id.index == owner.index && replacement.id.generation != owner.generation);
        publish(&fixture);
        assert(!state.contact_result.failure && state.shapes.len == 0 && state.contact_result.impacts == 0);
    }
    assert(!tracker.has_leaks());
}

fn void test_cloth_continuous_arbitrary_axis_and_rotation_limits() @test {
    Fixture fixture;
    setup(&fixture, weightless());
    defer teardown(&fixture);
    Quat basis = quaternion::from_axis_angle(((Vec3){ 1, 2, 3 }).normalize(), 0.8f);
    Quat first_turn = quaternion::from_axis_angle((Vec3){ 0, 0, 1 }, -(float)math::PI / 4);
    Quat last_turn = quaternion::from_axis_angle((Vec3){ 0, 0, 1 }, (float)math::PI / 4);
    ColliderDesc box = physics::default_collider_desc(BOX);
    box.half_extents = { 2, 0.05f, 0.2f };
    box.local.rotation = basis;
    Node* body = add_body_node(
        fixture: &fixture,
        colliders: (&box)[:1],
        position: {},
        kind: STATIC,
    );
    body.local.rotation = basis * first_turn * basis.conjugate();
    fixture.scene.update_world();
    Entity[1] owners = { body.id };
    Vec3 original = basis.rotate_vec3({ 1.8f, 0, 0 });
    Node* node = continuous_probe(fixture: &fixture, point: original, owners: owners[..]);
    publish(&fixture);
    fixture.physics.update(physics::DEFAULT_FIXED_DT);
    body.local.position = basis.rotate_vec3({ 0.1f, 0, 0 });
    body.local.rotation = basis * last_turn * basis.conjugate();
    fixture.scene.update_world();
    fixture.physics.update_cloths();
    ClothState* state = state_of(&fixture, node);
    assert(!state.contact_result.failure && state.contact_result.impacts > 0);
    assert((state.published[0] - original).length() > 0.1f);
    Vec3 local = (body.local.rotation * basis).conjugate().rotate_vec3(state.published[0] - body.local.position);
    assert(
        (local - math::clamp(local, -box.half_extents, box.half_extents)).length()
            >= state.desc.thickness - state.desc.collisions.contact_tolerance
    );

    Quat[3] rotations = {
        { .v = { 1.0f / 3, 2.0f / 3, 2.0f / 3, 0 } },
        quaternion::from_axis_angle(((Vec3){ 1, 2, 3 }).normalize(), 1e-8f),
        { .v = { 0, 0, 0, -1 } },
    };
    foreach (rotation : rotations) {
        maths::Transform last = maths::TRANSFORM_IDENTITY;
        last.rotation = rotation;
        ContactMotion motion = physics::contact_motion(maths::TRANSFORM_IDENTITY, last)!!;
        ContactFrame endpoint = physics::contact_motion_frame(&motion, physics::contact_value(1))!!;
        ContactFrame direct = physics::contact_frame_of(last)!!;
        foreach (index, value : endpoint.rotation) {
            assert(value.min <= direct.rotation[index].max && value.max >= direct.rotation[index].min);
        }
        ContactFrame middle = physics::contact_motion_frame(&motion, physics::contact_value(0.5))!!;
        foreach (value : middle.rotation) assert(math::is_finite(value.min) && math::is_finite(value.max));
    }
}
