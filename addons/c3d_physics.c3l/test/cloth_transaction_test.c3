module c3d_physics_cloth_test;

import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::physics;
import c3d::physics::cloth;
import c3d::scene;
import std::math;
import std::math::quaternion;
import std::core::mem::allocators;

fn Node* bounded_probe(
    Fixture* fixture,
    Vec3 point,
    Entity[] colliders,
    ClothCollisionDesc collisions,
) @local {
    Node* node = add_cloth_node(fixture, add_triangle(fixture, point, PROBE_REACH));
    uint[2] pins = { 1, 2 };
    ClothDesc desc = pinned_desc(pins[..]);
    desc.stretch_stiffness = 0;
    desc.bend_stiffness = 0;
    desc.colliders = colliders;
    desc.collisions = collisions;
    fixture.scene.add_cloth(&fixture.assets, node, desc)!!;
    return node;
}

fn void test_cloth_contact_capacity_and_unresolved_rollback() @test {
    Fixture fixture;
    setup(&fixture, desc: weightless());
    defer teardown(&fixture);

    ColliderDesc[2] colliders = { sphere(0.5f), sphere(0.5f) };
    Node* body = add_body_node(&fixture, colliders[..], kind: STATIC);
    Entity[1] owners = { body.id };

    ClothCollisionDesc limits = cloth::default_cloth_collision_desc();
    limits.max_candidates = 1;
    Node* candidate_probe = bounded_probe(
        fixture: &fixture, point: { 0, 0.1f, 0 }, colliders: owners[..], collisions: limits,
    );
    ClothState* candidate_state = state_of(&fixture, candidate_probe);
    Vec3 initial = candidate_state.positions[0];
    publish(&fixture);
    assert(candidate_state.contact_result.failure == c3d::CAPACITY_EXCEEDED);
    assert(candidate_state.contact_result.stage == ClothContactStage.CANDIDATES);
    assert(candidate_state.positions[0] == initial);

    limits = cloth::default_cloth_collision_desc();
    limits.max_contacts = 1;
    Node* contact_probe = bounded_probe(
        fixture: &fixture, point: { 0, 0.1f, 0 }, colliders: owners[..], collisions: limits,
    );
    ClothState* contact_state = state_of(&fixture, contact_probe);
    publish(&fixture);
    assert(contact_state.contact_result.failure == c3d::CAPACITY_EXCEEDED);
    assert(contact_state.contact_result.stage == ClothContactStage.CONTACTS);

    ColliderDesc ceiling = physics::default_collider_desc(BOX);
    ceiling.half_extents = { 2, 1, 2 };
    Node* ceiling_body = add_body_node(&fixture, (&ceiling)[:1], { 0, 1.01f, 0 }, STATIC);
    Entity[1] ceiling_owners = { ceiling_body.id };
    Node* trapped = add_cloth_node(&fixture, add_triangle(&fixture, { 0, 0.005f, 0 }, 0.5f));
    uint[2] pins = { 1, 2 };
    ClothDesc desc = pinned_desc(pins[..]);
    desc.stretch_stiffness = 0;
    desc.bend_stiffness = 0;
    desc.colliders = ceiling_owners[..];
    desc.collide_ground = true;
    fixture.scene.add_cloth(&fixture.assets, trapped, desc)!!;

    ClothState* trapped_state = state_of(&fixture, trapped);
    publish(&fixture);
    assert(trapped_state.contact_result.failure == cloth::CONTACT_UNRESOLVED);
    assert(trapped_state.contact_result.stage == ClothContactStage.RESOLVE);
}

fn void test_cloth_rebuild_refreshes_cooked_and_compound_generations() @test {
    Fixture fixture;
    PhysicsDesc world_desc = weightless();
    world_desc.snapshot_capacity = 2;
    setup(&fixture, desc: world_desc);
    defer teardown(&fixture);

    GeometryId geometry;
    @pool() {
        Geometry box = geometry::box(allocator: tmem, width: 2, height: 1, depth: 2);
        geometry = fixture.assets.add_geometry(&box)!!;
    };
    ColliderDesc hull = physics::default_collider_desc(HULL);
    hull.geometry = geometry;
    Node* body = add_body_node(&fixture, (&hull)[:1], kind: STATIC);
    Entity owner = body.id;
    Entity[1] owners = { owner };
    ClothCollisionDesc limits = cloth::default_cloth_collision_desc();
    limits.max_shapes = 2;
    Node* probe = bounded_probe(
        fixture: &fixture, point: { 0, 0.4f, 0 }, colliders: owners[..], collisions: limits,
    );
    ClothState* state = state_of(&fixture, probe);
    publish(&fixture);
    assert(!state.contact_result.failure && state.contact_result.contacts > 0);
    assert(math::abs(published_world(&fixture, probe, 0).y - 0.51f) <= CONTACT_TOLERANCE);

    @pool() {
        Geometry taller = geometry::box(allocator: tmem, width: 2, height: 2, depth: 2);
        fixture.assets.replace_geometry(geometry, &taller)!!;
    };
    fixture.scene.get(body, PhysicsBody).mark_changed();
    publish(&fixture);
    assert(!state.contact_result.failure);
    assert(math::abs(published_world(&fixture, probe, 0).y - 1.01f) <= CONTACT_TOLERANCE);

    CompoundChild[3] children;
    children[0] = physics::default_compound_child(HULL);
    children[0].geometry = geometry;
    children[1] = physics::default_compound_child(SPHERE);
    children[1].radius = 0.25f;
    children[1].local.position = { 2, 0, 0 };
    children[2] = children[1];
    children[2].local.position = { -2, 0, 0 };
    ColliderDesc compound = physics::default_collider_desc(COMPOUND);
    compound.children = children[..];
    fixture.physics.remove_body(body);
    fixture.physics.add_body(body, physics::default_body_desc(STATIC), (&compound)[:1])!!;
    publish(&fixture);
    assert(state.contact_result.failure == c3d::CAPACITY_EXCEEDED && state.contact_result.stage == ClothContactStage.BINDINGS);

    fixture.physics.remove_body(body);
    compound.children = children[:2];
    fixture.physics.add_body(body, physics::default_body_desc(STATIC), (&compound)[:1])!!;
    publish(&fixture);
    assert(!state.contact_result.failure && state.shapes.len == 2);

    fixture.scene.remove(body);
    Node* replacement = add_body_node(&fixture, (&hull)[:1], kind: STATIC);
    assert(replacement.id.index == owner.index && replacement.id.generation != owner.generation);
    publish(&fixture);
    assert(!state.contact_result.failure && state.shapes.len == 0);
}

fn void test_cloth_contact_settings_reject_invalid_values_atomically() @test {
    Fixture fixture;
    setup(&fixture, weightless());
    defer teardown(&fixture);
    Node* node = add_cloth_node(&fixture, add_grid(&fixture, 1));
    for (uint setting = 0; setting < 7; setting++) {
        ClothDesc desc = cloth::default_cloth_desc();
        switch (setting) {
            case 0: desc.collisions.contact_tolerance = 0;
            case 1: desc.collisions.contact_tolerance = bitcast(0x7fc00000u, float);
            case 2: desc.collisions.contact_iterations = 0;
            case 3: desc.collisions.max_shapes = 0;
            case 4: desc.collisions.max_candidates = 0;
            case 5: desc.collisions.max_contacts = 0;
            case 6: desc.collisions.max_ccd_iterations = 0;
        }
        assert(rejected_atomically(&fixture, node, desc) == c3d::INVALID_ARGUMENT);
    }
}
