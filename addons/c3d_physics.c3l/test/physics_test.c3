module c3d_physics_test;

import std::math;
import std::math::quaternion;
import c3d;
import c3d::asset;
import c3d::ecs;
import c3d::geometry;
import c3d::maths;
import c3d::physics;
import c3d::scene;
import b3;

alias Quat @private = Quaternionf;

const float TOLERANCE @private = 0.0001f;
const uint  SETTLE_UPDATES @private = 120;

struct Fixture @private {
    AssetStore   assets;
    Scene        scene;
    PhysicsWorld physics;
    GeometryId   unit_box;
}

fn void setup(Fixture* fixture, PhysicsDesc desc = physics::default_physics_desc()) @private {
    fixture.assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    fixture.scene = scene::create_scene(mem, scene::default_scene_desc());
    fixture.physics = physics::create_physics_world(
        allocator: mem,
        assets:    &fixture.assets,
        scene:     &fixture.scene,
        desc:      desc,
    )!!;
    @pool() {
        Geometry box = geometry::box(tmem, 1, 1, 1);
        fixture.unit_box = fixture.assets.add_geometry(&box, "unit_box")!!;
    };
}

fn void teardown(Fixture* fixture) @private {
    if (fixture.physics.scene) physics::destroy_physics_world(&fixture.physics);
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
}

fn bool close(float first, float second) @private => math::abs(first - second) <= TOLERANCE;

fn bool close_vec(Vec3 first, Vec3 second, float tolerance = TOLERANCE) @private {
    return math::abs(first.x - second.x) <= tolerance
        && math::abs(first.y - second.y) <= tolerance
        && math::abs(first.z - second.z) <= tolerance;
}

fn ColliderDesc box_collider(Vec3 half_extents, bool events = false) @private {
    ColliderDesc collider = physics::default_collider_desc(BOX);
    collider.half_extents = half_extents;
    collider.contact_events = events;
    collider.hit_events = events;
    return collider;
}

fn Node* add_ground(Fixture* fixture) @private {
    Node* ground = fixture.scene.add_node(name: "ground")!!;
    ground.local.position = { 0, -0.5f, 0 };
    fixture.scene.update_world();
    ColliderDesc collider = box_collider({ 10, 0.5f, 10 }, true);
    fixture.physics.add_body(ground, physics::default_body_desc(STATIC), (&collider)[:1])!!;
    return ground;
}

fn Node* add_box(
    Fixture* fixture,
    Vec3 position,
    BodyKind kind = DYNAMIC,
    bool events = true,
) @private {
    Node* node = fixture.scene.add_node(name: "box")!!;
    node.local.position = position;
    fixture.scene.update_world();
    ColliderDesc collider = box_collider({ 0.5f, 0.5f, 0.5f }, events);
    fixture.physics.add_body(node, physics::default_body_desc(kind), (&collider)[:1])!!;
    return node;
}

fn Node* add_geometry_body(Fixture* fixture, ColliderKind kind, BodyKind body_kind) @private {
    Node* node = fixture.scene.add_node(name: "geometry")!!;
    fixture.scene.update_world();
    ColliderDesc collider = physics::default_collider_desc(kind);
    collider.geometry = fixture.unit_box;
    fixture.physics.add_body(node, physics::default_body_desc(body_kind), (&collider)[:1])!!;
    return node;
}

fn void test_accumulator_steps_and_clamps() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    float fixed_dt = fixture.physics.desc.fixed_dt;

    fixture.physics.update(0.06f);
    assert(fixture.physics.steps_last_update == 3);
    assert(close(fixture.physics.accumulator, 0.06f - 3 * fixed_dt));

    fixture.physics.update(1);
    assert(fixture.physics.steps_last_update == 4);
    assert(fixture.physics.accumulator < fixed_dt);
    assert(fixture.physics.alpha >= 0 && fixture.physics.alpha < 1);
}

fn void test_interpolate_pose_endpoints() @test {
    maths::Transform start = { .position = { 0, 0, 0 }, .rotation = quaternion::IDENTITY, .scale = { 1, 1, 1 } };
    maths::Transform end = {
        .position = { 2, 4, 6 },
        .rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, (float)(math::PI / 2)),
        .scale    = { 1, 1, 1 },
    };

    maths::Transform at_start = physics::interpolate_pose(start, end, 0);
    maths::Transform at_end = physics::interpolate_pose(start, end, 1);
    maths::Transform middle = physics::interpolate_pose(start, end, 0.5f);
    assert(close_vec(at_start.position, start.position));
    assert(close_vec(at_end.position, end.position));
    assert(close_vec(middle.position, { 1, 2, 3 }));
    assert(close(at_start.rotation.l, 1));
    assert(close(at_end.rotation.j, end.rotation.j) && close(at_end.rotation.l, end.rotation.l));
}

fn void test_dynamic_write_back_through_static_parent() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Node* parent = fixture.scene.add_node(name: "parent")!!;
    parent.local.position = { 3, 0, 0 };
    parent.local.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, (float)(math::PI / 2));
    Node* child = fixture.scene.add_node(parent, "child")!!;
    fixture.scene.update_world();
    ColliderDesc collider = box_collider({ 0.5f, 0.5f, 0.5f });
    fixture.physics.add_body(child, physics::default_body_desc(DYNAMIC), (&collider)[:1])!!;

    RigidBody* body = fixture.scene.get(child, RigidBody);
    body.current = { .position = { 3, 2, 0 }, .rotation = quaternion::IDENTITY, .scale = { 1, 1, 1 } };
    body.previous = body.current;
    fixture.physics.update(0);
    fixture.scene.update_world();

    assert(close_vec(child.world_position(), { 3, 2, 0 }, 0.00001f));
    assert(close_vec(child.local.scale, { 1, 1, 1 }));
    assert(close_vec(maths::transform_from_mat4(child.world).rotation.rotate_vec3({ 1, 0, 0 }), { 1, 0, 0 }, 0.00001f));
}

fn void test_kinematic_body_follows_node() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Node* platform = add_box(&fixture, { 0, 0, 0 }, KINEMATIC, false);
    platform.local.position = { 0, 5, 0 };
    fixture.scene.update_world();
    fixture.physics.update(fixture.physics.desc.fixed_dt);

    Vec3 position = fixture.physics.body(platform)!!.position();
    assert(close_vec(position, { 0, 5, 0 }, 0.001f));
}

fn void test_hull_from_box_geometry_has_eight_vertices() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Node* node = add_geometry_body(&fixture, HULL, DYNAMIC);
    RigidBody* body = fixture.scene.get(node, RigidBody);
    assert(body.colliders[0].shape.hull()!!.vertex_count == 8);
    assert(fixture.physics.hull_count == 1);
    assert(body.colliders[0].wire.len == 24);
}

fn void test_cooked_mesh_is_shared_until_revision_moves() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    add_geometry_body(&fixture, MESH, STATIC);
    add_geometry_body(&fixture, MESH, STATIC);
    assert(fixture.physics.mesh_count == 1);

    fixture.assets.mark_geometry_dirty(fixture.unit_box);
    add_geometry_body(&fixture, MESH, STATIC);
    assert(fixture.physics.mesh_count == 2);
}

fn void test_mesh_collider_requires_static_body() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Node* node = fixture.scene.add_node(name: "mesh")!!;
    fixture.scene.update_world();
    ColliderDesc collider = physics::default_collider_desc(MESH);
    collider.geometry = fixture.unit_box;
    bool faulted;
    if (catch excuse = fixture.physics.add_body(node, physics::default_body_desc(DYNAMIC), (&collider)[:1])) {
        assert(excuse == physics::STATIC_ONLY);
        faulted = true;
    }
    assert(faulted);
    assert(!fixture.scene.has(node, RigidBody));
}

fn void test_released_geometry_faults_source_unavailable() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    fixture.assets.release_geometry_cpu(fixture.unit_box);
    Node* node = fixture.scene.add_node(name: "hull")!!;
    fixture.scene.update_world();
    ColliderDesc collider = physics::default_collider_desc(HULL);
    collider.geometry = fixture.unit_box;
    bool faulted;
    if (catch excuse = fixture.physics.add_body(node, physics::default_body_desc(DYNAMIC), (&collider)[:1])) {
        assert(excuse == physics::SOURCE_UNAVAILABLE);
        faulted = true;
    }
    assert(faulted);
}

fn void test_height_field_cooks_and_is_hit() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    float[9] heights;
    Node* terrain = fixture.scene.add_node(name: "terrain")!!;
    fixture.scene.update_world();
    ColliderDesc collider = physics::default_collider_desc(HEIGHT_FIELD);
    collider.height_field = { .heights = heights[..], .count_x = 3, .count_z = 3 };
    fixture.physics.add_body(terrain, physics::default_body_desc(STATIC), (&collider)[:1])!!;

    RayHit hit = fixture.physics.raycast({ 1, 5, 1 }, { 0, -1, 0 }, 10)!!;
    assert(hit.node == terrain);
    assert(close(hit.point.y, 0));
    assert(fixture.scene.get(terrain, RigidBody).colliders[0].wire.len == 24);
}

fn void test_contact_begin_maps_to_nodes() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Node* ground = add_ground(&fixture);
    Node* box = add_box(&fixture, { 0, 1, 0 });
    for (uint update = 0; update < SETTLE_UPDATES && fixture.physics.contacts_begin().len == 0; update++) {
        fixture.physics.update(fixture.physics.desc.fixed_dt);
    }

    ContactEvent[] contacts = fixture.physics.contacts_begin();
    assert(contacts.len == 1);
    bool ground_box = contacts[0].a == ground && contacts[0].b == box;
    bool box_ground = contacts[0].a == box && contacts[0].b == ground;
    assert(ground_box || box_ground);
}

fn void test_removal_hook_destroys_body() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Node* box = add_box(&fixture, { 0, 2, 0 });
    b3::BodyId id = fixture.physics.body(box)!!;
    assert(id.is_valid());

    fixture.scene.remove(box);
    assert(!id.is_valid());
    assert(fixture.scene.count(RigidBody) == 0);
}

fn void test_teardown_keeps_nodes_and_clears_components() @test {
    int worlds_before = b3::world_count();
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Node* first = add_box(&fixture, { 0, 2, 0 });
    Node* second = add_box(&fixture, { 2, 2, 0 });
    physics::destroy_physics_world(&fixture.physics);

    assert(fixture.scene.world.is_alive(first.id));
    assert(fixture.scene.world.is_alive(second.id));
    assert(fixture.scene.count(RigidBody) == 0);
    assert(b3::world_count() == worlds_before);
}

fn void test_raycast_returns_node_and_point() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Node* box = add_box(&fixture, { 0, 0, 0 }, STATIC, false);
    RayHit hit = fixture.physics.raycast({ 0, 5, 0 }, { 0, -1, 0 }, 10)!!;
    assert(hit.node == box);
    assert(close(hit.point.y, 0.5f));
    assert(close(hit.fraction, 0.45f));

    bool missed;
    if (catch excuse = fixture.physics.raycast({ 0, 5, 0 }, { 0, 1, 0 }, 10)) {
        assert(excuse == b3::NO_HIT);
        missed = true;
    }
    assert(missed);
}

fn void test_overlap_sphere_dedupes_bodies() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Node* twin = fixture.scene.add_node(name: "twin")!!;
    fixture.scene.update_world();
    ColliderDesc[2] spheres;
    spheres[0] = physics::default_collider_desc(SPHERE);
    spheres[0].radius = 0.2f;
    spheres[0].local.position = { -0.2f, 0, 0 };
    spheres[1] = spheres[0];
    spheres[1].local.position = { 0.2f, 0, 0 };
    fixture.physics.add_body(twin, physics::default_body_desc(STATIC), spheres[..])!!;
    add_box(&fixture, { 20, 0, 0 }, STATIC, false);

    Node*[] nodes = fixture.physics.overlap_sphere(mem, { 0, 0, 0 }, 1);
    defer free(nodes.ptr);
    assert(nodes.len == 1);
    assert(nodes[0] == twin);
}

fn void test_event_overflow_is_counted() @test {
    PhysicsDesc desc = physics::default_physics_desc();
    desc.event_capacity = 1;
    Fixture fixture;
    setup(&fixture, desc);
    defer teardown(&fixture);

    add_ground(&fixture);
    add_box(&fixture, { 0, 0.5f, 0 });
    add_box(&fixture, { 0, 1.5f, 0 });
    add_box(&fixture, { 0, 2.5f, 0 });
    fixture.physics.update(fixture.physics.desc.fixed_dt);

    assert(fixture.physics.contacts_begin().len == 1);
    assert(fixture.physics.dropped_events > 0);
}

fn void test_body_exists_fault() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Node* box = add_box(&fixture, { 0, 2, 0 });
    b3::BodyId first = fixture.physics.body(box)!!;
    ColliderDesc collider = box_collider({ 0.5f, 0.5f, 0.5f });
    bool faulted;
    if (catch excuse = fixture.physics.add_body(box, physics::default_body_desc(DYNAMIC), (&collider)[:1])) {
        assert(excuse == physics::BODY_EXISTS);
        faulted = true;
    }
    assert(faulted);
    assert(first.is_valid());
}
