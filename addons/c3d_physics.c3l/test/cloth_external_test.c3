module c3d_physics_cloth_test;

import std::math;
import std::io;
import std::core::mem::allocators;
import std::math::quaternion;
import c3d;
import c3d::asset;
import c3d::ecs;
import c3d::geometry;
import c3d::maths;
import c3d::physics @public;
import c3d::physics::cloth @public;
import c3d::scene;
import b3;

const uint DRAPE_SIDE @private = 5;
const uint DRAPE_STEPS @private = 90;
const uint DRAPE_GEOMETRIES @private = 32;
const float DRAPE_SEPARATION @private = 0.01f - 0.0001f;

fn GeometryId add_drape_wedge(Fixture* fixture) @private {
    GeometryId id;
    @pool() {
        Geometry geometry = {
            .positions = alloc::new_array(tmem, Vec3, 6),
            .indices = alloc::new_array(tmem, uint, 24),
        };
        geometry.positions[..] = ((Vec3[6]){
            { -0.5f, 0, -0.6f }, { 0.5f, 0, -0.6f }, { -0.5f, 0.5f, -0.6f },
            { -0.5f, 0, 0.6f }, { 0.5f, 0, 0.6f }, { -0.5f, 0.5f, 0.6f },
        })[..];
        geometry.indices[..] = {
            0, 2, 1, 3, 4, 5, 0, 1, 4, 0, 4, 3,
            0, 3, 5, 0, 5, 2, 1, 2, 5, 1, 5, 4,
        }[..];
        geometry.finalize();
        id = fixture.assets.add_geometry(&geometry)!!;
    };
    return id;
}

fn GeometryId add_drape_ramp(Fixture* fixture) @private {
    GeometryId id;
    @pool() {
        Geometry geometry = {
            .positions = alloc::new_array(tmem, Vec3, 4),
            .indices = alloc::new_array(tmem, uint, 6),
        };
        geometry.positions[..] = ((Vec3[4]){
            { -1.5f, -0.375f, -1.5f }, { 1.5f, 0.375f, -1.5f },
            { 1.5f, 0.375f, 1.5f }, { -1.5f, -0.375f, 1.5f },
        })[..];
        geometry.indices[..] = { 0, 2, 1, 0, 3, 2 }[..];
        geometry.finalize();
        id = fixture.assets.add_geometry(&geometry)!!;
    };
    return id;
}

fn Node* add_drape_section(
    Fixture* fixture,
    Vec3 corner,
    Vec3 span,
    Entity owner,
) @private {
    GeometryId id;
    @pool() {
        Geometry geometry = {
            .positions = alloc::new_array(tmem, Vec3, DRAPE_SIDE * DRAPE_SIDE),
            .indices = alloc::new_array(tmem, uint, 6 * (DRAPE_SIDE - 1) * (DRAPE_SIDE - 1)),
        };
        for (uint row = 0; row < DRAPE_SIDE; row++) {
            for (uint column = 0; column < DRAPE_SIDE; column++) {
                geometry.positions[row * DRAPE_SIDE + column] = corner + (Vec3){
                    span.x * (float)row / (float)(DRAPE_SIDE - 1),
                    0,
                    span.z * (float)column / (float)(DRAPE_SIDE - 1),
                };
            }
        }
        usz next;
        for (uint row = 0; row + 1 < DRAPE_SIDE; row++) {
            for (uint column = 0; column + 1 < DRAPE_SIDE; column++) {
                uint first = row * DRAPE_SIDE + column;
                uint[6] indices = {
                    first, first + 1, first + DRAPE_SIDE,
                    first + 1, first + DRAPE_SIDE + 1, first + DRAPE_SIDE,
                };
                geometry.indices[next:6] = indices[..];
                next += 6;
            }
        }
        geometry.finalize();
        id = fixture.assets.add_geometry(&geometry)!!;
    };
    Node* node = add_cloth_node(fixture, id);
    uint[DRAPE_SIDE] pins = { 0, 1, 2, 3, 4 };
    Entity[1] colliders = { owner };
    ClothDesc desc = pinned_desc(pins[..]);
    desc.colliders = colliders[..];
    fixture.scene.add_cloth(&fixture.assets, node, desc)!!;
    return node;
}

fn Node* add_external_probe(Fixture* fixture, Vec3 point, Entity owner) @private {
    Node* node = add_cloth_node(fixture, add_triangle(fixture, point, PROBE_REACH));
    uint[2] pins = { 1, 2 };
    Entity[1] colliders = { owner };
    ClothDesc desc = pinned_desc(pins[..]);
    desc.stretch_stiffness = 0;
    desc.bend_stiffness = 0;
    desc.colliders = colliders[..];
    fixture.scene.add_cloth(&fixture.assets, node, desc)!!;
    return node;
}

fn float drape_box_distance(Vec3 relative, Vec3 half_extents) @private {
    Vec3 outside = { math::abs(relative.x), math::abs(relative.y), math::abs(relative.z) };
    outside -= half_extents;
    Vec3 positive = { math::max(outside.x, 0.0f), math::max(outside.y, 0.0f), math::max(outside.z, 0.0f) };
    return positive.length() + math::min(math::max(outside.x, math::max(outside.y, outside.z)), 0.0f);
}

fn float drape_wedge_distance(Vec3 point) @private {
    Vec3 local = point - (Vec3){ -5.75f, 0.25f, 0 };
    Vec3 planar = { local.x, local.y, 0 };
    float edge = math::min(
        segment_distance(planar, { -0.5f, 0, 0 }, { 0.5f, 0, 0 }),
        math::min(
            segment_distance(planar, { 0.5f, 0, 0 }, { -0.5f, 1, 0 }),
            segment_distance(planar, { -0.5f, 1, 0 }, { -0.5f, 0, 0 }),
        ),
    );
    if (local.x >= -0.5f && local.y >= 0 && local.x + local.y <= 0.5f) edge = -edge;
    float end = math::abs(local.z) - 0.6f;
    float outside_edge = math::max(edge, 0.0f);
    float outside_end = math::max(end, 0.0f);
    return math::sqrt(outside_edge * outside_edge + outside_end * outside_end)
      + math::min(math::max(edge, end), 0.0f);
}

fn float drape_mesh_distance(Vec3 point) @private {
    float plane = point.y - 0.5f * point.x;
    float projected_x = point.x + 0.4f * plane;
    if (math::abs(projected_x) <= 1.5f && math::abs(point.z) <= 1.5f) {
        return math::abs(plane) / math::sqrt(1.25f);
    }
    return math::min(
        math::min(
            segment_distance(point, { -1.5f, -0.75f, -1.5f }, { 1.5f, 0.75f, -1.5f }),
            segment_distance(point, { 1.5f, 0.75f, -1.5f }, { 1.5f, 0.75f, 1.5f }),
        ),
        math::min(
            segment_distance(point, { 1.5f, 0.75f, 1.5f }, { -1.5f, -0.75f, 1.5f }),
            segment_distance(point, { -1.5f, -0.75f, 1.5f }, { -1.5f, -0.75f, -1.5f }),
        ),
    );
}

fn float drape_field_distance(Vec3 point) @private {
    Vec3 local = point - (Vec3){ 6, 0, 0 };
    float plane = local.y - 0.25f * local.x;
    float projected_x = local.x + plane * (0.25f / 1.0625f);
    bool in_hole = projected_x > 1 && projected_x < 2 && local.z > 1 && local.z < 2;
    if (projected_x >= 0 && projected_x <= 3 && local.z >= 0 && local.z <= 3 && !in_hole) {
        return math::abs(plane) / math::sqrt(1.0625f);
    }
    float outer = math::min(
        math::min(
            segment_distance(local, { 0, 0, 0 }, { 3, 0.75f, 0 }),
            segment_distance(local, { 3, 0.75f, 0 }, { 3, 0.75f, 3 }),
        ),
        math::min(
            segment_distance(local, { 3, 0.75f, 3 }, { 0, 0, 3 }),
            segment_distance(local, { 0, 0, 3 }, { 0, 0, 0 }),
        ),
    );
    float hole = math::min(
        math::min(
            segment_distance(local, { 1, 0.25f, 1 }, { 2, 0.5f, 1 }),
            segment_distance(local, { 2, 0.5f, 1 }, { 2, 0.5f, 2 }),
        ),
        math::min(
            segment_distance(local, { 2, 0.5f, 2 }, { 1, 0.25f, 2 }),
            segment_distance(local, { 1, 0.25f, 2 }, { 1, 0.25f, 1 }),
        ),
    );
    return math::min(outer, hole);
}

fn float drape_compound_mesh_distance(Vec3 point) @private {
    float plane = point.y - 0.5f + point.z;
    float projected_z = point.z - 0.5f * plane;
    if (point.x >= 13.5f && point.x <= 16.5f && math::abs(projected_z) <= 0.75f) {
        return math::abs(plane) / math::sqrt(2.0f);
    }
    return math::min(
        math::min(
            segment_distance(point, { 13.5f, 1.25f, -0.75f }, { 16.5f, 1.25f, -0.75f }),
            segment_distance(point, { 16.5f, 1.25f, -0.75f }, { 16.5f, -0.25f, 0.75f }),
        ),
        math::min(
            segment_distance(point, { 16.5f, -0.25f, 0.75f }, { 13.5f, -0.25f, 0.75f }),
            segment_distance(point, { 13.5f, -0.25f, 0.75f }, { 13.5f, 1.25f, -0.75f }),
        ),
    );
}

fn void check_drape_particles(Fixture* fixture, Node*[] sections) @private {
    foreach (section, node : sections) {
        ClothState* state = state_of(fixture, node);
        assert(!state.contact_result.failure);
        assert(state.contact_result.max_residual <= CONTACT_TOLERANCE);
        foreach (index, position : state.positions) {
            Vec3 published = published_world(fixture, node, (uint)index);
            assert(finite(position) && finite(published));
            if (state.inverse_masses[index] == 0) {
                assert(near(position, state.rest[index]) && near(published, state.rest[index]));
                continue;
            }
            foreach (point : (Vec3[2]){ position, published }) {
                switch (section) {
                    case 0:
                        Vec3 relative = point - (Vec3){ -11.8f, 0.3f, 0 };
                        assert(drape_box_distance(relative, { 0.5f, 0.75f, 0.6f }) >= DRAPE_SEPARATION);
                    case 1:
                        assert(drape_wedge_distance(point) >= DRAPE_SEPARATION);
                    case 2:
                        assert(drape_mesh_distance(point) >= DRAPE_SEPARATION);
                    case 3:
                        assert(drape_field_distance(point) >= DRAPE_SEPARATION);
                    case 4:
                    case 5:
                        Vec3 relative = point - (Vec3){ 13, 0.4f, 0 };
                        assert(drape_box_distance(relative, { 0.15f, 0.35f, 0.4f }) >= DRAPE_SEPARATION);
                        assert(drape_compound_mesh_distance(point) >= DRAPE_SEPARATION);
                    default:
                        unreachable();
                }
            }
        }
    }
}

fn void test_cloth_drapes_over_all_external_collider_kinds() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    Fixture fixture;
    setup(fixture: &fixture, allocator: &tracker, max_geometries: DRAPE_GEOMETRIES);
    defer {
        teardown(&fixture);
        assert(!tracker.has_leaks());
    }
    GeometryId wedge = add_drape_wedge(&fixture);
    GeometryId ramp = add_drape_ramp(&fixture);

    ColliderDesc box = physics::default_collider_desc(BOX);
    box.half_extents = { 0.75f, 0.5f, 0.6f };
    box.local.position = { 0.2f, 0.3f, 0 };
    box.local.rotation = quaternion::from_axis_angle{float}({ 0, 0, 1 }, (float)math::PI / 2);
    ColliderDesc hull = physics::default_collider_desc(HULL);
    hull.geometry = wedge;
    hull.local.position = { 0.25f, 0.25f, 0 };
    hull.local.scale = { 1, 2, 1 };
    ColliderDesc mesh = physics::default_collider_desc(MESH);
    mesh.geometry = ramp;
    mesh.local.scale = { 1, 2, 1 };
    float[16] heights = { 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3 };
    char[9] materials = { 0, 0, 0, 0, physics::HEIGHT_FIELD_HOLE, 0, 0, 0, 0 };
    ColliderDesc field = physics::default_collider_desc(HEIGHT_FIELD);
    field.height_field = { .heights = heights[..], .count_x = 4, .count_z = 4 };
    field.local.scale = { 1, 0.25f, 1 };
    field.material_indices = materials[..];
    field.face_materials = (&field.material)[:1];
    CompoundChild[2] children;
    children[0] = physics::default_compound_child(BOX);
    children[0].half_extents = { 0.35f, 0.15f, 0.4f };
    children[0].local.position = { -1, 0.4f, 0 };
    children[0].local.rotation = box.local.rotation;
    children[1] = physics::default_compound_child(MESH);
    children[1].geometry = ramp;
    children[1].local.position = { 1, 0.5f, 0 };
    children[1].local.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, (float)math::PI / 2);
    children[1].local.scale = { 0.5f, 2, 1 };
    ColliderDesc compound = physics::default_collider_desc(COMPOUND);
    compound.children = children[..];

    Node*[5] bodies;
    bodies[0] = add_body_node(
        fixture: &fixture,
        colliders: (&box)[:1],
        position: { -12, 0, 0 },
        kind: STATIC,
    );
    bodies[1] = add_body_node(
        fixture: &fixture,
        colliders: (&hull)[:1],
        position: { -6, 0, 0 },
        kind: STATIC,
    );
    bodies[2] = add_body_node(
        fixture: &fixture,
        colliders: (&mesh)[:1],
        position: {},
        kind: STATIC,
    );
    bodies[3] = add_body_node(
        fixture: &fixture,
        colliders: (&field)[:1],
        position: { 6, 0, 0 },
        kind: STATIC,
    );
    bodies[4] = add_body_node(
        fixture: &fixture,
        colliders: (&compound)[:1],
        position: { 14, 0, 0 },
        kind: STATIC,
    );
    b3::WorldTransform[5] native_poses;
    foreach (index, body : bodies) native_poses[index] = fixture.physics.body(body)!!.transform();

    Node*[6] sections;
    sections[0] = add_drape_section(
        fixture: &fixture,
        corner: { -12.45f, 1.2f, -0.4f },
        span: { 1.3f, 0, 0.8f },
        owner: bodies[0].id,
    );
    sections[1] = add_drape_section(
        fixture: &fixture,
        corner: { -6.15f, 1.25f, -0.4f },
        span: { 0.8f, 0, 0.8f },
        owner: bodies[1].id,
    );
    sections[2] = add_drape_section(
        fixture: &fixture,
        corner: { -0.6f, 0.45f, -0.4f },
        span: { 1.2f, 0, 0.8f },
        owner: bodies[2].id,
    );
    sections[3] = add_drape_section(
        fixture: &fixture,
        corner: { 6.15f, 0.35f, 0.15f },
        span: { 0.7f, 0, 0.7f },
        owner: bodies[3].id,
    );
    sections[4] = add_drape_section(
        fixture: &fixture,
        corner: { 12.75f, 0.9f, -0.3f },
        span: { 0.5f, 0, 0.6f },
        owner: bodies[4].id,
    );
    sections[5] = add_drape_section(
        fixture: &fixture,
        corner: { 14.65f, 1, -0.3f },
        span: { 0.7f, 0, 0.6f },
        owner: bodies[4].id,
    );
    Node* box_inside = add_external_probe(&fixture, { -11.6f, 0.3f, 0 }, bodies[0].id);
    Node* hull_inside = add_external_probe(&fixture, { -5.75f, 0.6f, 0 }, bodies[1].id);
    Node* mesh_below = add_external_probe(&fixture, { 0, -0.005f, 0.75f }, bodies[2].id);
    Node* field_below = add_external_probe(&fixture, { 6.5f, 0.12f, 2.5f }, bodies[3].id);
    Node* hole = add_external_probe(&fixture, { 7.5f, 0.4f, 1.5f }, bodies[3].id);
    Node* child_inside = add_external_probe(&fixture, { 13.05f, 0.4f, 0 }, bodies[4].id);
    Node* child_below = add_external_probe(&fixture, { 15, 0.495f, 0 }, bodies[4].id);
    Node*[6] contact_probes = { box_inside, hull_inside, mesh_below, field_below, child_inside, child_below };

    publish(&fixture);
    foreach (probe : contact_probes) {
        ClothState* state = state_of(&fixture, probe);
        assert(!state.contact_result.failure && state.contact_result.contacts > 0);
    }
    assert(near(published_world(&fixture, box_inside, 0), { -11.29f, 0.3f, 0 }, CONTACT_TOLERANCE));
    float diagonal_offset = 0.01f / math::sqrt(2.0f);
    Vec3 hull_exit = { -5.675f + diagonal_offset, 0.675f + diagonal_offset, 0 };
    assert(near(published_world(&fixture, hull_inside, 0), hull_exit, CONTACT_TOLERANCE));
    assert(near(published_world(&fixture, child_inside, 0), { 13.16f, 0.4f, 0 }, CONTACT_TOLERANCE));
    assert(near(published_world(&fixture, hole, 0), { 7.5f, 0.4f, 1.5f }));
    assert(state_of(&fixture, hole).contact_result.candidates == 0);
    Vec3 mesh_normal = ((Vec3){ -0.5f, 1, 0 }).normalize();
    Vec3 field_normal = ((Vec3){ -0.25f, 1, 0 }).normalize();
    Vec3 child_normal = ((Vec3){ 0, 1, 1 }).normalize();
    state_of(&fixture, mesh_below).velocities[0] = mesh_normal * 0.25f;
    state_of(&fixture, field_below).velocities[0] = field_normal * 0.25f;
    state_of(&fixture, child_below).velocities[0] = child_normal * 0.25f;

    usz state_bytes, scratch_bytes, particles, triangles, captured_shapes;
    @pool() {
        Allocation[] allocations = tracker.allocations_tlist(tmem);
        fixture.scene.@each(Cloth; entity, component) {
            ClothState* state = component.state;
            foreach (allocation : allocations) if (allocation.ptr == state) state_bytes += (usz)allocation.size;
            particles += state.positions.len;
            triangles += fixture.assets.geometry(state.geometry).data.indices.len / 3;
            captured_shapes += state.shapes.len;
            scratch_bytes += state.staged_shapes.len * ClothShape::size + state.staged_bodies.len * ClothBody::size
              + state.frames.len * ContactFrame::size + state.candidates.len * ClothCandidate::size + state.contacts.len * ClothContact::size;
            scratch_bytes += Vec3::size * (state.staged_positions.len + state.staged_velocities.len + state.staged_published.len
              + state.staged_pin_anchors.len + state.staged_shape_starts.len + state.staged_shape_ends.len + state.local_output.len
              + state.local_normals.len + state.publication_roundtrip.len + state.staged_predicted.len + state.staged_accelerations.len
              + state.staged_pin_targets.len);
        };
    };
    assert(state_bytes > scratch_bytes);
    double solve_seconds, publish_seconds, maximum_residual;
    ulong candidate_total, contact_total;
    uint peak_candidates, peak_contacts, failed;
    uint[6] contacts;
    for (uint update = 0; update < DRAPE_STEPS; update++) {
        fixture.physics.update(physics::DEFAULT_FIXED_DT);
        fixture.scene.update_world();
        sz allocation_count = tracker.total_allocation_count();
        fixture.physics.update_cloths();
        assert(tracker.total_allocation_count() == allocation_count);
        ClothStats stats = fixture.physics.cloth_stats;
        solve_seconds += stats.solve_seconds;
        publish_seconds += stats.publish_seconds;
        candidate_total += stats.candidates;
        contact_total += stats.contacts;
        failed += stats.failed;
        maximum_residual = math::max(maximum_residual, stats.max_residual);
        fixture.scene.@each(Cloth; entity, component) {
            peak_candidates = math::max(peak_candidates, component.state.contact_result.peak_candidates);
            peak_contacts = math::max(peak_contacts, component.state.contact_result.peak_contacts);
        };
        check_drape_particles(&fixture, sections[..]);
        foreach (index, section : sections) contacts[index] += state_of(&fixture, section).contact_result.contacts;
        foreach (index, probe : contact_probes) {
            ClothState* state = state_of(&fixture, probe);
            assert(!state.contact_result.failure);
            foreach (point : (Vec3[2]){ state.positions[0], published_world(&fixture, probe, 0) }) {
                assert(finite(point));
                switch (index) {
                    case 0:
                        Vec3 relative = point - (Vec3){ -11.8f, 0.3f, 0 };
                        assert(drape_box_distance(relative, { 0.5f, 0.75f, 0.6f }) >= DRAPE_SEPARATION);
                    case 1:
                        assert(drape_wedge_distance(point) >= DRAPE_SEPARATION);
                    case 2:
                        assert(drape_mesh_distance(point) >= DRAPE_SEPARATION);
                    case 3:
                        assert(drape_field_distance(point) >= DRAPE_SEPARATION);
                    case 4:
                    case 5:
                        Vec3 relative = point - (Vec3){ 13, 0.4f, 0 };
                        assert(drape_box_distance(relative, { 0.15f, 0.35f, 0.4f }) >= DRAPE_SEPARATION);
                        assert(drape_compound_mesh_distance(point) >= DRAPE_SEPARATION);
                    default:
                        unreachable();
                }
            }
        }
        ClothState* hole_state = state_of(&fixture, hole);
        assert(!hole_state.contact_result.failure && hole_state.contact_result.candidates == 0);
        if (update == 0) {
            Vec3 mesh_point = published_world(&fixture, mesh_below, 0);
            Vec3 field_point = published_world(&fixture, field_below, 0);
            Vec3 child_point = published_world(&fixture, child_below, 0);
            assert(mesh_point.y - 0.5f * mesh_point.x < 0);
            assert(field_point.y - 0.25f * (field_point.x - 6) < 0);
            assert(child_point.y - 0.5f + child_point.z < 0);
            assert(state_of(&fixture, mesh_below).contact_result.contacts > 0);
            assert(state_of(&fixture, field_below).contact_result.contacts > 0);
            assert(state_of(&fixture, child_below).contact_result.contacts > 0);
        }
        foreach (index, body : bodies) {
            b3::BodyId native = fixture.physics.body(body)!!;
            b3::WorldTransform pose = native.transform();
            assert(pose.p == native_poses[index].p && pose.q.v == native_poses[index].q.v);
            assert(native.linear_velocity() == (Vec3){} && native.angular_velocity() == (Vec3){});
        }
    }
    foreach (count : contacts) assert(count > 0);
    foreach (section : sections) {
        ClothState* state = state_of(&fixture, section);
        bool moved;
        foreach (index, position : state.positions) {
            if ((position - state.rest[index]).length() > 0.01f) moved = true;
        }
        assert(moved);
    }
    Vec3 fallen = published_world(&fixture, hole, 0);
    assert(fallen.y < 0.125f && math::abs(fallen.x - 7.5f) <= POSITION_TOLERANCE);
    assert(math::abs(fallen.z - 1.5f) <= POSITION_TOLERANCE);
    io::printfn("cloth_external_measurement,steps,%d,particles,%d,triangles,%d,bodies,5,distinct_leaves,6,captured_shapes,%d,state_bytes,%d,prepared_scratch_bytes,%d,solve_ms,%.9f,publish_ms,%.9f,candidates,%d,contacts,%d,peak_candidates,%d,peak_contacts,%d,ccd_iterations,0,failed,%d,max_residual,%.9f",
        DRAPE_STEPS, particles, triangles, captured_shapes, state_bytes, scratch_bytes, solve_seconds * 1000, publish_seconds * 1000,
        candidate_total, contact_total, peak_candidates, peak_contacts, failed, maximum_residual);
}
