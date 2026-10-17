module c3d_physics_cloth_test;

import std::math;
import std::core::mem::allocators;
import c3d;
import c3d::asset;
import c3d::ecs;
import c3d::geometry;
import c3d::maths;
import c3d::physics @public;
import c3d::physics::cloth @public;
import c3d::scene;

fn Node* add_external_probe(Fixture* fixture, Vec3 point, Entity owner) @local {
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

fn void test_cloth_drapes_over_all_external_collider_kinds() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    Fixture fixture;
    setup(fixture: &fixture, allocator: &tracker, max_geometries: 16);
    defer {
        teardown(&fixture);
        assert(!tracker.has_leaks());
    }

    GeometryId box_geom;
    GeometryId plane_geom;
    @pool() {
        Geometry cube = geometry::box(allocator: tmem, width: 1, height: 1, depth: 1);
        box_geom = fixture.assets.add_geometry(&cube)!!;
        Geometry flat = geometry::plane(tmem, 3, 3);
        plane_geom = fixture.assets.add_geometry(&flat)!!;
    };

    ColliderDesc box = physics::default_collider_desc(BOX);
    box.half_extents = { 0.5f, 0.5f, 0.5f };

    ColliderDesc hull = physics::default_collider_desc(HULL);
    hull.geometry = box_geom;

    ColliderDesc mesh = physics::default_collider_desc(MESH);
    mesh.geometry = plane_geom;

    float[16] heights;
    char[9] materials = { 0, 0, 0, 0, physics::HEIGHT_FIELD_HOLE, 0, 0, 0, 0 };
    ColliderDesc field = physics::default_collider_desc(HEIGHT_FIELD);
    field.height_field = { .heights = heights[..], .count_x = 4, .count_z = 4 };
    field.material_indices = materials[..];
    field.face_materials = (&field.material)[:1];

    CompoundChild[2] children;
    children[0] = physics::default_compound_child(BOX);
    children[0].half_extents = { 0.5f, 0.5f, 0.5f };
    children[1] = physics::default_compound_child(MESH);
    children[1].geometry = plane_geom;
    children[1].local.position = { 2, 0, 0 };
    ColliderDesc compound = physics::default_collider_desc(COMPOUND);
    compound.children = children[..];

    Node*[5] bodies = {
        add_body_node(&fixture, (&box)[:1], { -12, 0, 0 }, STATIC),
        add_body_node(&fixture, (&hull)[:1], { -6, 0, 0 }, STATIC),
        add_body_node(&fixture, (&mesh)[:1], {}, STATIC),
        add_body_node(&fixture, (&field)[:1], { 6, 0, 0 }, STATIC),
        add_body_node(&fixture, (&compound)[:1], { 14, 0, 0 }, STATIC),
    };

    Node* box_probe = add_external_probe(&fixture, { -12, 0.3f, 0 }, bodies[0].id);
    Node* hull_probe = add_external_probe(&fixture, { -6, 0.3f, 0 }, bodies[1].id);
    Node* mesh_probe = add_external_probe(&fixture, { 0, -0.005f, 0 }, bodies[2].id);
    Node* field_probe = add_external_probe(&fixture, { 6.5f, -0.005f, 0.5f }, bodies[3].id);
    Node* hole_probe = add_external_probe(&fixture, { 7.5f, 0.1f, 1.5f }, bodies[3].id);
    Node* compound_box = add_external_probe(&fixture, { 14, 0.3f, 0 }, bodies[4].id);
    Node* compound_mesh = add_external_probe(&fixture, { 16, -0.005f, 0 }, bodies[4].id);
    Node*[6] contact_probes = { box_probe, hull_probe, mesh_probe, field_probe, compound_box, compound_mesh };

    publish(&fixture);
    foreach (probe : contact_probes) {
        ClothState* state = state_of(&fixture, probe);
        assert(!state.contact_result.failure && state.contact_result.contacts > 0);
        assert(published_world(&fixture, probe, 0).y >= -CONTACT_TOLERANCE);
    }
    assert(math::abs(published_world(&fixture, box_probe, 0).y - 0.51f) <= CONTACT_TOLERANCE);
    assert(math::abs(published_world(&fixture, hull_probe, 0).y - 0.51f) <= CONTACT_TOLERANCE);
    assert(math::abs(published_world(&fixture, compound_box, 0).y - 0.51f) <= CONTACT_TOLERANCE);
    assert(state_of(&fixture, hole_probe).contact_result.candidates == 0);

    for (uint update = 0; update < 10; update++) {
        fixture.physics.update(physics::DEFAULT_FIXED_DT);
        fixture.scene.update_world();
        sz allocation_count = tracker.total_allocation_count();
        fixture.physics.update_cloths();
        assert(tracker.total_allocation_count() == allocation_count);
        assert(!fixture.physics.cloth_stats.failed);
    }

    assert(published_world(&fixture, hole_probe, 0).y < 0);
}
