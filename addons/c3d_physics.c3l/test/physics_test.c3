module c3d_physics_test;

import std::math;
import std::math::quaternion;
import c3d;
import c3d::asset;
import c3d::debug;
import c3d::ecs;
import c3d::geometry;
import c3d::maths;
import c3d::material;
import c3d::physics;
import c3d::scene;
import b3;
import std::io;

alias Quat @private = Quaternionf;

const float TOLERANCE @private = 0.0001f;
const usz   RGBA_CHANNELS @private = 4;
const uint  SETTLE_UPDATES @private = 120;
const float CONTACT_SLOP @private = 0.01f; // box3d's speculative margin; resting points sit within it
const SurfaceMaterialId ROCK_SURFACE @private = (SurfaceMaterialId)7;
const SurfaceMaterialId ICE_SURFACE @private = (SurfaceMaterialId)9;
const SurfaceMaterialId GROUND_SURFACE @private = (SurfaceMaterialId)3;
const SurfaceMaterialId CRATE_SURFACE @private = (SurfaceMaterialId)4;

struct Fixture @private {
    AssetStore   assets;
    Scene        scene;
    PhysicsWorld physics;
    GeometryId   unit_box;
}

fn void setup(Fixture* fixture, PhysicsDesc desc = physics::default_physics_desc()) @private {
    fixture.assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    fixture.scene = scene::create_scene(mem, scene::default_scene_desc());
    physics::register_physics(&fixture.scene)!!;
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

fn uint occupied_snapshots(PhysicsWorld* world) @private {
    uint count;
    foreach (&slot : world.snapshots.slots) {
        if (slot.generation % 2 == 1) count++;
    }
    return count;
}

fn void assert_holders_match(Fixture* fixture) @private {
    foreach (usz index, &slot : fixture.physics.snapshots.slots) {
        uint holders;
        fixture.scene.@each(RigidBody; entity, body) {
            foreach (&collider : body.colliders) {
                if (collider.snapshot.generation && collider.snapshot.index == index) {
                    assert(collider.snapshot.generation == slot.generation);
                    holders++;
                }
            }
        };
        assert(holders == slot.holders);
    }
}

fn Node* add_component_box(Fixture* fixture, Vec3 position, BodyKind kind = DYNAMIC) @private {
    Node* node = fixture.scene.add_node(name: "box")!!;
    node.local.position = position;
    fixture.scene.update_world();
    ColliderDesc collider = box_collider({ 0.5f, 0.5f, 0.5f }, true);
    fixture.scene.add_physics_body(node, physics::default_body_desc(kind), (&collider)[:1])!!;
    return node;
}

fn Node* add_static_node(Fixture* fixture, Vec3 position = {}) @private {
    Node* node = fixture.scene.add_node(name: "static")!!;
    node.local.position = position;
    fixture.scene.update_world();
    return node;
}

fn ColliderDesc height_field_collider(
    float[] heights,
    char[] indices = {},
    SurfaceMaterialDesc[] materials = {},
) @private {
    ColliderDesc collider = physics::default_collider_desc(HEIGHT_FIELD);
    collider.height_field = { .heights = heights, .count_x = 3, .count_z = 3 };
    collider.material_indices = indices;
    collider.face_materials = materials;
    return collider;
}

fn ColliderDesc[3] crate_colliders(Fixture* fixture) @private {
    ColliderDesc[3] colliders;
    colliders[0] = physics::default_collider_desc(HULL);
    colliders[0].geometry = fixture.unit_box;
    colliders[1] = physics::default_collider_desc(SPHERE);
    colliders[1].radius = 0.2f;
    colliders[1].local.position = { -0.4f, -0.5f, 0 };
    colliders[2] = colliders[1];
    colliders[2].local.position = { 0.4f, -0.5f, 0 };
    return colliders;
}

fn CompoundChild[3] bridge_children(float sphere_height = 1) @private {
    CompoundChild[3] children;
    children[0] = physics::default_compound_child(BOX);
    children[0].half_extents = { 1, 0.1f, 0.5f };
    children[0].local.position = { -1, 0, 0 };
    children[1] = children[0];
    children[1].local.position = { 1, 0, 0 };
    children[2] = physics::default_compound_child(SPHERE);
    children[2].radius = 0.3f;
    children[2].local.position = { 0, sphere_height, 0 };
    return children;
}

fn ColliderDesc compound_collider(CompoundChild[] children) @private {
    ColliderDesc collider = physics::default_collider_desc(COMPOUND);
    collider.children = children;
    return collider;
}

fn void restore_unit_box(Fixture* fixture, float size) @private {
    fixture.assets.release_geometry_cpu(fixture.unit_box);
    fixture.assets.geometry(fixture.unit_box).data = geometry::box(
        allocator: fixture.assets.allocator,
        width:     size,
        height:    size,
        depth:     size,
    );
    fixture.assets.mark_geometry_dirty(fixture.unit_box);
}

fn fault add_body_fault(Fixture* fixture, BodyKind kind, ColliderDesc[] colliders) @private {
    Node* node = add_static_node(fixture);
    if (catch excuse = fixture.physics.add_body(node, physics::default_body_desc(kind), colliders)) {
        assert(!fixture.scene.has(node, PhysicsBody));
        assert(!fixture.scene.has(node, RigidBody));
        return excuse;
    }
    return {};
}

SurfaceMaterialId[2] mixed_surfaces @private;

fn float record_mixed_surfaces(
    float friction_a,
    SurfaceMaterialId surface_a,
    float friction_b,
    SurfaceMaterialId surface_b,
) @private {
    mixed_surfaces = { surface_a, surface_b };
    return 0.5f;
}

fn bool ray_hits_below(Fixture* fixture, Vec3 origin) @private {
    if (catch excuse = fixture.physics.raycast(origin, { 0, -1, 0 }, 10)) {
        assert(excuse == b3::NO_HIT);
        return false;
    }
    return true;
}

fn usz overlap_count(Fixture* fixture, Vec3 center) @private {
    Node*[] nodes = fixture.physics.overlap_sphere(mem, center, 1);
    defer free(nodes.ptr);
    return nodes.len;
}

fn void run_updates(Fixture* fixture, uint count) @private {
    for (uint update = 0; update < count; update++) fixture.physics.update(physics::DEFAULT_FIXED_DT);
    fixture.scene.update_world();
}

fn TextureId add_height_texture(
    Fixture* fixture,
    PixelFormat format,
    uint width,
    uint height,
    float[] heights,
) @private {
    usz channel_bytes = char::size;
    if (format == RGBA16_FLOAT) channel_bytes = float16::size;
    if (format == RGBA32_FLOAT) channel_bytes = float::size;
    usz texel_bytes = format == R16_UINT ? ushort::size : RGBA_CHANNELS * channel_bytes;
    material::TextureDesc desc = material::texture_2d_desc(width, height, format);
    desc.generate_mips = false;
    TextureId texture;
    @pool() {
        char[] pixels = alloc::new_array(tmem, char, (sz)(texel_bytes * width * height));
        foreach (usz index, value : heights) {
            if (format == RGBA32_FLOAT) {
                ((float*)pixels.ptr)[index * RGBA_CHANNELS] = value;
            } else if (format == R16_UINT) {
                ((ushort*)pixels.ptr)[index] = (ushort)math::round(value * 65535);
            } else {
                pixels[index * texel_bytes] = (char)math::round(value * 255);
            }
        }
        texture = fixture.assets.add_texture(desc, pixels)!!;
    };
    return texture;
}

fn ColliderDesc height_map_collider(TextureId texture, Vec3 scale = { 1, 1, 1 }) @private {
    ColliderDesc collider = physics::default_collider_desc(HEIGHT_FIELD);
    collider.height_field = { .source = TEXTURE, .texture = texture };
    collider.local.scale = scale;
    return collider;
}

fn Node* add_static_body(Fixture* fixture, ColliderDesc collider, Vec3 position = {}) @private {
    Node* node = add_static_node(fixture, position);
    fixture.physics.add_body(node, physics::default_body_desc(STATIC), (&collider)[:1])!!;
    return node;
}

fn float ground_height(Fixture* fixture, float x, float z) @private {
    return fixture.physics.raycast({ x, 5, z }, { 0, -1, 0 }, 10)!!.point.y;
}

fn void test_accumulator_steps_and_clamps() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    float fixed_dt = fixture.physics.desc.tuning.fixed_dt;

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
    fixture.physics.update(fixture.physics.desc.tuning.fixed_dt);

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
    assert(occupied_snapshots(&fixture.physics) == 1);
    assert(body.colliders[0].wire.len == 24);
}

fn void test_physics_mesh_is_shared_until_revision_moves() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    add_geometry_body(&fixture, MESH, STATIC);
    add_geometry_body(&fixture, MESH, STATIC);
    assert(occupied_snapshots(&fixture.physics) == 1);

    fixture.assets.mark_geometry_dirty(fixture.unit_box);
    add_geometry_body(&fixture, MESH, STATIC);
    assert(occupied_snapshots(&fixture.physics) == 2);
}

fn void test_add_body_fault_leaves_no_components() @test {
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
    assert(!fixture.scene.has(node, PhysicsBody));
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
        fixture.physics.update(fixture.physics.desc.tuning.fixed_dt);
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
    assert(fixture.scene.count(PhysicsBody) == 2);
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
    fixture.physics.update(fixture.physics.desc.tuning.fixed_dt);

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

fn void test_component_builds_body_on_next_update() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Node* box = add_component_box(&fixture, { 0, 2, 0 });
    assert(!fixture.scene.has(box, RigidBody));
    fixture.physics.update(0);
    assert(fixture.scene.has(box, RigidBody));
    assert(fixture.scene.get(box, PhysicsBody).status == LIVE);
}

fn void test_scene_from_components_settles_without_add_body() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Node* ground = add_static_node(&fixture, { 0, -0.5f, 0 });
    ColliderDesc floor = box_collider({ 10, 0.5f, 10 });
    fixture.scene.add_physics_body(ground, physics::default_body_desc(STATIC), (&floor)[:1])!!;
    Node* box = add_component_box(&fixture, { 0, 2, 0 });
    for (uint update = 0; update < SETTLE_UPDATES; update++) {
        fixture.physics.update(fixture.physics.desc.tuning.fixed_dt);
        fixture.scene.update_world();
    }
    assert(math::abs(box.world_position().y - 0.5f) < 0.01f);
}

fn void test_removed_component_removes_body_on_next_update() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Node* box = add_component_box(&fixture, { 0, 2, 0 });
    fixture.physics.update(0);
    b3::BodyId id = fixture.physics.body(box)!!;
    fixture.scene.remove_component(box, PhysicsBody);
    assert(fixture.scene.has(box, RigidBody));
    fixture.physics.update(0);
    assert(!fixture.scene.has(box, RigidBody));
    assert(!id.is_valid());
}

fn void test_mark_changed_rebuilds_from_desc() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Node* box = add_component_box(&fixture, { 0, 2, 0 });
    fixture.physics.update(0);
    b3::BodyId first = fixture.physics.body(box)!!;
    PhysicsBody* physics_body = fixture.scene.get(box, PhysicsBody);
    physics_body.colliders[0].half_extents = { 1, 1, 1 };
    physics_body.mark_changed();
    fixture.physics.update(0);

    b3::BodyId second = fixture.physics.body(box)!!;
    assert(!first.is_valid());
    assert(second.is_valid());
    assert(close_vec(fixture.scene.get(box, RigidBody).colliders[0].half_extents, { 1, 1, 1 }));
}

fn void test_failed_body_waits_for_mark_changed() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Node* node = add_static_node(&fixture);
    ColliderDesc collider = physics::default_collider_desc(MESH);
    collider.geometry = fixture.unit_box;
    fixture.scene.add_physics_body(node, physics::default_body_desc(DYNAMIC), (&collider)[:1])!!;
    fixture.physics.update(0);
    PhysicsBody* physics_body = fixture.scene.get(node, PhysicsBody);
    assert(physics_body.status == FAILED);
    assert(physics_body.failure == physics::STATIC_ONLY);
    assert(fixture.physics.build_failures().len == 1);
    assert(fixture.physics.build_failures()[0].node == node);

    fixture.physics.update(0);
    assert(fixture.physics.build_failures().len == 0);
    assert(physics_body.status == FAILED);

    physics_body.body.kind = STATIC;
    physics_body.mark_changed();
    fixture.physics.update(0);
    assert(physics_body.status == LIVE);
}

fn void test_source_unavailable_retries_after_revision_moves() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    fixture.assets.release_geometry_cpu(fixture.unit_box);
    Node* node = add_static_node(&fixture);
    ColliderDesc collider = physics::default_collider_desc(HULL);
    collider.geometry = fixture.unit_box;
    fixture.scene.add_physics_body(node, physics::default_body_desc(DYNAMIC), (&collider)[:1])!!;
    fixture.physics.update(0);
    PhysicsBody* physics_body = fixture.scene.get(node, PhysicsBody);
    assert(physics_body.status == FAILED);
    assert(physics_body.failure == physics::SOURCE_UNAVAILABLE);

    fixture.physics.update(0);
    assert(fixture.physics.build_failures().len == 0);
    restore_unit_box(&fixture, 1);
    fixture.physics.update(0);
    assert(physics_body.status == LIVE);
}

fn void test_capacity_failure_waits_for_mark_changed() @test {
    PhysicsDesc desc = physics::default_physics_desc();
    desc.snapshot_capacity = 1;
    Fixture fixture;
    setup(&fixture, desc);
    defer teardown(&fixture);

    float[9] heights;
    ColliderDesc collider = height_field_collider(heights[..]);
    Node* first = add_static_node(&fixture);
    fixture.physics.add_body(first, physics::default_body_desc(STATIC), (&collider)[:1])!!;
    Node* second = add_static_node(&fixture, { 5, 0, 0 });
    fixture.scene.add_physics_body(second, physics::default_body_desc(STATIC), (&collider)[:1])!!;
    fixture.physics.update(0);
    PhysicsBody* physics_body = fixture.scene.get(second, PhysicsBody);
    assert(physics_body.status == FAILED);
    assert(physics_body.failure == c3d::CAPACITY_EXCEEDED);

    fixture.scene.remove(first);
    fixture.physics.update(0);
    physics_body = fixture.scene.get(second, PhysicsBody);
    assert(physics_body.status == FAILED);
    physics_body.mark_changed();
    fixture.physics.update(0);
    assert(physics_body.status == LIVE);
}

fn void test_partial_build_failure_releases_snapshots() @test {
    PhysicsDesc desc = physics::default_physics_desc();
    desc.snapshot_capacity = 1;
    Fixture fixture;
    setup(&fixture, desc);
    defer teardown(&fixture);

    float[9] heights;
    ColliderDesc[2] colliders = { height_field_collider(heights[..]), height_field_collider(heights[..]) };
    assert(add_body_fault(&fixture, STATIC, colliders[..]) == c3d::CAPACITY_EXCEEDED);
    assert(occupied_snapshots(&fixture.physics) == 0);
}

fn void test_add_physics_body_twice_faults() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Node* box = add_component_box(&fixture, { 0, 2, 0 });
    ColliderDesc collider = box_collider({ 2, 2, 2 });
    bool faulted;
    if (catch excuse = fixture.scene.add_physics_body(box, physics::default_body_desc(DYNAMIC), (&collider)[:1])) {
        assert(excuse == physics::BODY_EXISTS);
        faulted = true;
    }
    assert(faulted);
    assert(close_vec(fixture.scene.get(box, PhysicsBody).colliders[0].half_extents, { 0.5f, 0.5f, 0.5f }));
}

fn void test_snapshot_holders_match_after_churn() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    ColliderDesc[3] crate = crate_colliders(&fixture);
    Node*[3] crates;
    foreach (index, &node : crates) {
        *node = add_static_node(&fixture, { index * 3.0f, 3, 0 });
        fixture.scene.add_physics_body(*node, physics::default_body_desc(DYNAMIC), crate[..])!!;
    }
    float[9] heights;
    ColliderDesc terrain = height_field_collider(heights[..]);
    for (uint index = 0; index < 2; index++) {
        Node* node = add_static_node(&fixture, { index * 5.0f, -2, 0 });
        fixture.scene.add_physics_body(node, physics::default_body_desc(STATIC), (&terrain)[:1])!!;
    }
    fixture.physics.update(0);
    assert_holders_match(&fixture);
    SnapshotHandle hull = fixture.scene.get(crates[0], RigidBody).colliders[0].snapshot;
    assert(fixture.physics.snapshots.slots[hull.index].holders == 3);
    assert(occupied_snapshots(&fixture.physics) == 3);

    fixture.scene.remove(crates[0]);
    assert_holders_match(&fixture);
    fixture.scene.get(crates[1], PhysicsBody).mark_changed();
    fixture.physics.update(0);
    assert_holders_match(&fixture);
    fixture.scene.remove_later(crates[2]);
    fixture.scene.flush_removals();
    fixture.physics.update(0);
    assert_holders_match(&fixture);
    fixture.scene.remove(crates[1]);
    assert_holders_match(&fixture);
    assert(fixture.physics.snapshots.slots[hull.index].holders == 0);
    assert(occupied_snapshots(&fixture.physics) == 3);
}

fn void test_compound_is_one_shape_shared_by_content() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    CompoundChild[3] children = bridge_children();
    ColliderDesc bridge = compound_collider(children[..]);
    Node* first = add_static_node(&fixture);
    fixture.physics.add_body(first, physics::default_body_desc(STATIC), (&bridge)[:1])!!;
    Node* second = add_static_node(&fixture, { 0, 0, 5 });
    fixture.physics.add_body(second, physics::default_body_desc(STATIC), (&bridge)[:1])!!;

    RigidBody* first_body = fixture.scene.get(first, RigidBody);
    RigidBody* second_body = fixture.scene.get(second, RigidBody);
    assert(first_body.colliders.len == 1);
    assert(first_body.body.shape_count() == 1);
    assert(second_body.body.shape_count() == 1);
    SnapshotHandle handle = first_body.colliders[0].snapshot;
    assert(second_body.colliders[0].snapshot.index == handle.index);
    assert(fixture.physics.snapshots.slots[handle.index].holders == 2);

    CompoundChild[3] moved = bridge_children(2);
    ColliderDesc other = compound_collider(moved[..]);
    Node* third = add_static_node(&fixture, { 0, 0, 10 });
    fixture.physics.add_body(third, physics::default_body_desc(STATIC), (&other)[:1])!!;
    assert(fixture.scene.get(third, RigidBody).colliders[0].snapshot.index != handle.index);
    assert(occupied_snapshots(&fixture.physics) == 2);
}

fn void test_compound_requires_static_body() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    CompoundChild[3] children = bridge_children();
    ColliderDesc bridge = compound_collider(children[..]);
    assert(add_body_fault(&fixture, DYNAMIC, (&bridge)[:1]) == physics::STATIC_ONLY);
    assert(occupied_snapshots(&fixture.physics) == 0);
}

fn void test_compound_sensor_faults() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    CompoundChild[3] children = bridge_children();
    ColliderDesc bridge = compound_collider(children[..]);
    bridge.sensor = true;
    assert(add_body_fault(&fixture, STATIC, (&bridge)[:1]) == c3d::INVALID_ARGUMENT);
}

fn void test_compound_mesh_child_material_count_must_match() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    char[12] indices;
    SurfaceMaterialDesc[2] materials = { physics::default_surface_material(), physics::default_surface_material() };
    CompoundChild child = physics::default_compound_child(MESH);
    child.geometry = fixture.unit_box;
    child.material_indices = indices[..];
    child.face_materials = materials[..];
    ColliderDesc collider = compound_collider((&child)[:1]);
    assert(add_body_fault(&fixture, STATIC, (&collider)[:1]) == c3d::INVALID_ARGUMENT);

    child.face_materials = materials[:1];
    collider = compound_collider((&child)[:1]);
    fixture.physics.add_body(add_static_node(&fixture), physics::default_body_desc(STATIC), (&collider)[:1])!!;

    child.material_indices = {};
    child.face_materials = {};
    collider = compound_collider((&child)[:1]);
    fixture.physics.add_body(add_static_node(&fixture), physics::default_body_desc(STATIC), (&collider)[:1])!!;
}

fn void test_compound_box_children_keep_their_own_extents() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    CompoundChild[2] children;
    children[0] = physics::default_compound_child(BOX);
    children[0].half_extents = { 0.5f, 0.1f, 0.5f };
    children[0].local.position = { -2, 0, 0 };
    children[1] = physics::default_compound_child(BOX);
    children[1].half_extents = { 0.5f, 0.3f, 0.5f };
    children[1].local.position = { 2, 0, 0 };
    ColliderDesc collider = compound_collider(children[..]);
    fixture.physics.add_body(add_static_node(&fixture), physics::default_body_desc(STATIC), (&collider)[:1])!!;

    assert(close(fixture.physics.raycast({ -2, 5, 0 }, { 0, -1, 0 }, 10)!!.point.y, 0.1f));
    assert(close(fixture.physics.raycast({ 2, 5, 0 }, { 0, -1, 0 }, 10)!!.point.y, 0.3f));
}

fn void test_edited_compound_frees_its_old_snapshot() @test {
    PhysicsDesc desc = physics::default_physics_desc();
    desc.snapshot_capacity = 2;
    Fixture fixture;
    setup(&fixture, desc);
    defer teardown(&fixture);

    CompoundChild child = physics::default_compound_child(HULL);
    child.geometry = fixture.unit_box;
    ColliderDesc collider = compound_collider((&child)[:1]);
    Node* node = add_static_node(&fixture);
    fixture.scene.add_physics_body(node, physics::default_body_desc(STATIC), (&collider)[:1])!!;
    fixture.physics.update(0);
    PhysicsBody* physics_body = fixture.scene.get(node, PhysicsBody);
    for (uint edit = 1; edit <= 3; edit++) {
        physics_body.colliders[0].children[0].local.position = { 0, edit, 0 };
        physics_body.mark_changed();
        fixture.physics.update(0);
        assert(physics_body.status == LIVE);
    }
    assert(occupied_snapshots(&fixture.physics) == 2);
    assert_holders_match(&fixture);
}

fn void test_physics_body_owns_its_desc_copy() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    char[12] indices;
    SurfaceMaterialDesc[1] faces = { physics::default_surface_material() };
    faces[0].id = ROCK_SURFACE;
    CompoundChild child = physics::default_compound_child(MESH);
    child.geometry = fixture.unit_box;
    child.material_indices = indices[..];
    child.face_materials = faces[..];
    float[9] heights = { 0, 1, 0, 1, 2, 1, 0, 1, 0 };
    ColliderDesc[2] colliders = { compound_collider((&child)[:1]), height_field_collider(heights[..]) };
    char[5] name = "rocks";
    BodyDesc body = physics::default_body_desc(STATIC);
    body.name = (String)name[..];

    Node* first = add_static_node(&fixture);
    fixture.scene.add_physics_body(first, body, colliders[..])!!;
    Node* second = add_static_node(&fixture, { 0, 0, 10 });
    fixture.scene.add_physics_body(second, body, colliders[..])!!;
    child.geometry = {};
    indices[0] = 1;
    faces[0].id = ICE_SURFACE;
    heights[4] = 9;
    name[0] = 'X';
    fixture.scene.remove_component(first, PhysicsBody);
    fixture.physics.update(0);

    PhysicsBody* copy = fixture.scene.get(second, PhysicsBody);
    assert(copy.status == LIVE);
    assert(copy.body.name == "rocks");
    CompoundChild* copied_child = &copy.colliders[0].children[0];
    assert(copied_child.geometry.index == fixture.unit_box.index);
    assert(copied_child.material_indices[0] == 0);
    assert(copied_child.face_materials[0].id == ROCK_SURFACE);
    assert(copy.colliders[1].height_field.heights[4] == 2);
}

fn void test_asset_snapshot_survives_zero_holders() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Node* node = add_geometry_body(&fixture, HULL, DYNAMIC);
    fixture.scene.remove(node);
    fixture.physics.update(0);
    assert(occupied_snapshots(&fixture.physics) == 1);
    fixture.assets.release_geometry_cpu(fixture.unit_box);
    add_geometry_body(&fixture, HULL, DYNAMIC);
}

fn void test_component_snapshot_freed_at_zero_holders() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    float[9] heights;
    ColliderDesc collider = height_field_collider(heights[..]);
    Node* node = add_static_node(&fixture);
    fixture.physics.add_body(node, physics::default_body_desc(STATIC), (&collider)[:1])!!;
    assert(occupied_snapshots(&fixture.physics) == 1);
    fixture.scene.remove(node);
    assert(occupied_snapshots(&fixture.physics) == 0);
}

fn void test_full_table_reclaims_stale_unheld_snapshot() @test {
    PhysicsDesc desc = physics::default_physics_desc();
    desc.snapshot_capacity = 1;
    Fixture fixture;
    setup(&fixture, desc);
    defer teardown(&fixture);

    Node* node = add_geometry_body(&fixture, HULL, DYNAMIC);
    fixture.scene.remove(node);
    restore_unit_box(&fixture, 1);
    add_geometry_body(&fixture, HULL, DYNAMIC);
    assert(occupied_snapshots(&fixture.physics) == 1);
    assert_holders_match(&fixture);
}

fn void test_revision_change_keeps_live_shape_until_mark_changed() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Node* node = add_geometry_body(&fixture, HULL, DYNAMIC);
    RigidBody* body = fixture.scene.get(node, RigidBody);
    b3::ShapeId shape = body.colliders[0].shape;
    assert(math::abs(body.body.mass() - 1000) < 1);

    restore_unit_box(&fixture, 2);
    fixture.physics.update(0);
    body = fixture.scene.get(node, RigidBody);
    assert(body.colliders[0].shape.index1 == shape.index1 && body.colliders[0].shape.generation == shape.generation);
    assert(math::abs(body.body.mass() - 1000) < 1);
    assert(occupied_snapshots(&fixture.physics) == 1);

    fixture.scene.get(node, PhysicsBody).mark_changed();
    fixture.physics.update(0);
    body = fixture.scene.get(node, RigidBody);
    assert(math::abs(body.body.mass() - 8000) < 1);
    assert(occupied_snapshots(&fixture.physics) == 2);
    assert_holders_match(&fixture);
}

fn void test_face_material_reaches_ray_and_hit() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    float[9] heights;
    char[4] indices = { 0, 1, 1, 0 };
    SurfaceMaterialDesc[2] materials = { physics::default_surface_material(), physics::default_surface_material() };
    materials[0].id = ROCK_SURFACE;
    materials[1].id = ICE_SURFACE;
    ColliderDesc terrain = height_field_collider(heights[..], indices[..], materials[..]);
    terrain.hit_events = true;
    fixture.physics.add_body(add_static_node(&fixture), physics::default_body_desc(STATIC), (&terrain)[:1])!!;

    assert(fixture.physics.raycast({ 1.5f, 5, 0.5f }, { 0, -1, 0 }, 10)!!.surface == ICE_SURFACE);
    assert(fixture.physics.raycast({ 0.5f, 5, 0.5f }, { 0, -1, 0 }, 10)!!.surface == ROCK_SURFACE);

    Node* box = add_static_node(&fixture, { 1.5f, 2, 0.5f });
    ColliderDesc falling = box_collider({ 0.2f, 0.2f, 0.2f }, true);
    fixture.physics.add_body(box, physics::default_body_desc(DYNAMIC), (&falling)[:1])!!;
    bool reached;
    for (uint update = 0; update < SETTLE_UPDATES && !reached; update++) {
        fixture.physics.update(fixture.physics.desc.tuning.fixed_dt);
        foreach (hit : fixture.physics.hits()) {
            if (hit.surface_a == ICE_SURFACE || hit.surface_b == ICE_SURFACE) reached = true;
        }
    }
    assert(reached);
}

fn void test_height_field_hole_lets_ray_through() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    float[9] heights;
    char[4] indices = { physics::HEIGHT_FIELD_HOLE, 0, 0, 0 };
    SurfaceMaterialDesc material = physics::default_surface_material();
    ColliderDesc terrain = height_field_collider(heights[..], indices[..], (&material)[:1]);
    fixture.physics.add_body(add_static_node(&fixture), physics::default_body_desc(STATIC), (&terrain)[:1])!!;

    bool missed;
    if (catch excuse = fixture.physics.raycast({ 0.5f, 5, 0.5f }, { 0, -1, 0 }, 10)) {
        assert(excuse == b3::NO_HIT);
        missed = true;
    }
    assert(missed);
}

fn void test_height_map_reads_red_channel_row_major() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    float[12] heights;
    foreach (index : (usz[]){ 6, 7, 10, 11 }) heights[index] = 1;
    TextureId texture = add_height_texture(&fixture, RGBA8_UNORM, 4, 3, heights[..]);
    ColliderDesc collider = height_map_collider(texture, { 1, 2, 1 });
    add_static_body(&fixture, collider);

    assert(close(ground_height(&fixture, 2.5f, 1.5f), 2));
    assert(close(ground_height(&fixture, 0.5f, 0.5f), 0));
}

fn void test_float_height_map_matches_height_array() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    float[12] heights = { 0, 0.5f, 1, 0.25f, 0.75f, 1.5f, 0.2f, 0.4f, 1, 0, 0.3f, 0.6f };
    TextureId texture = add_height_texture(&fixture, RGBA32_FLOAT, 4, 3, heights[..]);
    ColliderDesc from_texture = height_map_collider(texture);
    add_static_body(&fixture, from_texture);
    ColliderDesc from_array = physics::default_collider_desc(HEIGHT_FIELD);
    from_array.height_field = { .heights = heights[..], .count_x = 4, .count_z = 3 };
    add_static_body(&fixture, from_array, { 10, 0, 0 });

    foreach (cell : (Vec2[]){ { 0.5f, 0.5f }, { 1.5f, 0.5f }, { 2.5f, 1.5f } }) {
        assert(close(ground_height(&fixture, cell.x, cell.y), ground_height(&fixture, cell.x + 10, cell.y)));
    }
}

fn void test_r16_height_map_matches_height_array() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    float[12] heights = { 0, 0.5f, 1, 0.25f, 0.75f, 0.125f, 0.2f, 0.4f, 1, 0, 0.3f, 0.6f };
    TextureId texture = add_height_texture(&fixture, R16_UINT, 4, 3, heights[..]);
    add_static_body(&fixture, height_map_collider(texture, { 1, 2, 1 }));
    float[12] quantized;
    foreach (index, value : heights) quantized[index] = math::round(value * 65535) / 65535;
    ColliderDesc from_array = physics::default_collider_desc(HEIGHT_FIELD);
    from_array.height_field = { .heights = quantized[..], .count_x = 4, .count_z = 3 };
    from_array.local.scale = { 1, 2, 1 };
    add_static_body(&fixture, from_array, { 10, 0, 0 });

    foreach (point : (Vec2[]){ { 0.5f, 0.5f }, { 1.5f, 0.5f }, { 2.5f, 1.5f }, { 1.25f, 1.75f } }) {
        assert(close(ground_height(&fixture, point.x, point.y), ground_height(&fixture, point.x + 10, point.y)));
    }
}

fn void test_height_map_snapshot_shared_by_texture_scale_and_revision() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    float[9] heights;
    TextureId texture = add_height_texture(&fixture, RGBA8_UNORM, 3, 3, heights[..]);
    ColliderDesc collider = height_map_collider(texture);
    add_static_body(&fixture, collider);
    add_static_body(&fixture, collider, { 5, 0, 0 });
    assert(occupied_snapshots(&fixture.physics) == 1);

    ColliderDesc stretched = height_map_collider(texture, { 2, 1, 1 });
    add_static_body(&fixture, stretched, { 10, 0, 0 });
    assert(occupied_snapshots(&fixture.physics) == 2);

    fixture.assets.mark_texture_dirty(texture);
    add_static_body(&fixture, collider, { 15, 0, 0 });
    assert(occupied_snapshots(&fixture.physics) == 3);
    assert_holders_match(&fixture);
}

fn void test_released_height_map_rebuilds_from_its_snapshot() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    float[9] heights;
    TextureId texture = add_height_texture(&fixture, RGBA8_UNORM, 3, 3, heights[..]);
    ColliderDesc collider = height_map_collider(texture);
    Node* terrain = add_static_node(&fixture);
    fixture.physics.add_body(terrain, physics::default_body_desc(STATIC), (&collider)[:1])!!;
    fixture.assets.release_texture_cpu(texture);
    fixture.physics.remove_body(terrain);

    fixture.physics.add_body(terrain, physics::default_body_desc(STATIC), (&collider)[:1])!!;
    ColliderDesc stretched = height_map_collider(texture, { 2, 1, 1 });
    assert(add_body_fault(&fixture, STATIC, (&stretched)[:1]) == physics::SOURCE_UNAVAILABLE);
}

fn void test_height_map_retries_after_revision_moves() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    float[9] heights;
    TextureId texture = add_height_texture(&fixture, RGBA8_UNORM, 3, 3, heights[..]);
    fixture.assets.release_texture_cpu(texture);
    ColliderDesc collider = height_map_collider(texture);
    Node* terrain = add_static_node(&fixture);
    fixture.scene.add_physics_body(terrain, physics::default_body_desc(STATIC), (&collider)[:1])!!;
    fixture.physics.update(0);
    PhysicsBody* physics_body = fixture.scene.get(terrain, PhysicsBody);
    assert(physics_body.status == FAILED);
    assert(physics_body.failure == physics::SOURCE_UNAVAILABLE);

    fixture.assets.texture(texture).pixels = alloc::new_array(fixture.assets.allocator, char, 9 * 4);
    fixture.assets.mark_texture_dirty(texture);
    fixture.physics.update(0);
    assert(fixture.scene.get(terrain, PhysicsBody).status == LIVE);
}

fn void test_height_map_rejects_unreadable_textures() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    float[9] heights;
    ColliderDesc srgb = height_map_collider(add_height_texture(&fixture, RGBA8_SRGB, 3, 3, heights[..]));
    assert(add_body_fault(&fixture, STATIC, (&srgb)[:1]) == c3d::UNSUPPORTED);
    ColliderDesc half = height_map_collider(add_height_texture(&fixture, RGBA16_FLOAT, 3, 3, heights[..]));
    assert(add_body_fault(&fixture, STATIC, (&half)[:1]) == c3d::UNSUPPORTED);
    ColliderDesc narrow = height_map_collider(add_height_texture(&fixture, RGBA8_UNORM, 1, 4, heights[:4]));
    assert(add_body_fault(&fixture, STATIC, (&narrow)[:1]) == c3d::INVALID_ARGUMENT);

    TextureId removed = add_height_texture(&fixture, RGBA8_UNORM, 3, 3, heights[..]);
    fixture.assets.remove_texture(removed);
    ColliderDesc dead = height_map_collider(removed);
    assert(add_body_fault(&fixture, STATIC, (&dead)[:1]) == c3d::INVALID_ID);

    char[3] indices;
    SurfaceMaterialDesc material = physics::default_surface_material();
    ColliderDesc short_indices = height_map_collider(add_height_texture(&fixture, RGBA8_UNORM, 3, 3, heights[..]));
    short_indices.material_indices = indices[..];
    short_indices.face_materials = (&material)[:1];
    assert(add_body_fault(&fixture, STATIC, (&short_indices)[:1]) == c3d::INVALID_ARGUMENT);
}

fn void test_material_index_out_of_range_faults() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    float[9] heights;
    char[4] indices = { 0, 1, 2, 0 };
    SurfaceMaterialDesc[2] materials = { physics::default_surface_material(), physics::default_surface_material() };
    ColliderDesc terrain = height_field_collider(heights[..], indices[..], materials[..]);
    assert(add_body_fault(&fixture, STATIC, (&terrain)[:1]) == c3d::INVALID_ARGUMENT);
}

fn void test_explosion_moves_resting_box_and_respects_scale() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    add_ground(&fixture);
    Node* pushed = add_box(&fixture, { -1, 0.5f, 0 });
    Node* anchored = add_static_node(&fixture, { 1, 0.5f, 0 });
    ColliderDesc heavy = box_collider({ 0.5f, 0.5f, 0.5f });
    heavy.explosion_scale = 0;
    fixture.physics.add_body(anchored, physics::default_body_desc(DYNAMIC), (&heavy)[:1])!!;
    for (uint update = 0; update < SETTLE_UPDATES; update++) fixture.physics.update(fixture.physics.desc.tuning.fixed_dt);

    ExplosionDesc explosion = physics::default_explosion_desc();
    explosion.position = { 0, 0.5f, 0 };
    explosion.radius = 3;
    explosion.impulse_per_area = 50;
    fixture.physics.explode(explosion)!!;
    assert(fixture.physics.body(pushed)!!.linear_velocity().length() > 0.01f);
    assert(fixture.physics.body(anchored)!!.linear_velocity().length() < 0.0001f);
}

fn void test_force_applies_once_per_step() @test {
    PhysicsDesc desc = physics::default_physics_desc();
    desc.tuning.gravity = {};
    Fixture fixture;
    setup(&fixture, desc);
    defer teardown(&fixture);

    Node* node = add_static_node(&fixture, { 0, 5, 0 });
    ColliderDesc light = box_collider({ 0.5f, 0.5f, 0.5f });
    light.density = 1;
    fixture.physics.add_body(node, physics::default_body_desc(DYNAMIC), (&light)[:1])!!;
    fixture.scene.add(node, (Force){ .force = { 1, 0, 0 } });
    float fixed_dt = fixture.physics.desc.tuning.fixed_dt;
    b3::BodyId body = fixture.physics.body(node)!!;

    fixture.physics.update(0);
    assert(fixture.physics.steps_last_update == 0);
    fixture.physics.update(2 * fixed_dt);
    assert(fixture.physics.steps_last_update == 2);
    Vec3 skipped = body.linear_velocity();

    fixture.physics.set_velocity(node, {}, {});
    fixture.physics.update(fixed_dt);
    fixture.physics.update(fixed_dt);
    Vec3 stepped = body.linear_velocity();
    assert(close_vec(skipped, stepped));
    assert(close(stepped.x, 2 * fixed_dt / body.mass()));
}

fn void test_wind_applies_once_per_step() @test {
    PhysicsDesc desc = physics::default_physics_desc();
    desc.tuning.gravity = {};
    Fixture fixture;
    setup(&fixture, desc);
    defer teardown(&fixture);

    Node* node = add_static_node(&fixture, { 0, 5, 0 });
    ColliderDesc light = box_collider({ 0.5f, 0.5f, 0.5f });
    light.density = 1;
    fixture.physics.add_body(node, physics::default_body_desc(DYNAMIC), (&light)[:1])!!;
    fixture.scene.add(node, (Wind){ .velocity = { 5, 0, 0 }, .drag = 1, .max_speed = 10 });
    float fixed_dt = fixture.physics.desc.tuning.fixed_dt;
    b3::BodyId body = fixture.physics.body(node)!!;

    fixture.physics.update(0);
    fixture.physics.update(2 * fixed_dt);
    Vec3 skipped = body.linear_velocity();

    fixture.physics.set_velocity(node, {}, {});
    fixture.physics.update(fixed_dt);
    fixture.physics.update(fixed_dt);
    Vec3 stepped = body.linear_velocity();
    assert(stepped.x > 0);
    assert(close_vec(skipped, stepped));
}

fn void test_set_tuning_applies_and_stores() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    PhysicsTuning tuning = fixture.physics.desc.tuning;
    tuning.gravity = { 0, -1, 0 };
    tuning.contact_hertz = 60;
    fixture.physics.set_tuning(tuning);
    assert(close_vec(fixture.physics.world.gravity(), { 0, -1, 0 }));
    assert(close(fixture.physics.desc.tuning.contact_hertz, 60));
}

fn void test_worker_count_reaches_world() @test {
    PhysicsDesc desc = physics::default_physics_desc();
    desc.worker_count = 2;
    Fixture fixture;
    setup(&fixture, desc);
    defer teardown(&fixture);

    assert(fixture.physics.worker_count() == 2);
    add_ground(&fixture);
    Node* box = add_box(&fixture, { 0, 5, 0 });
    run_updates(&fixture, 30);
    assert(fixture.scene.get(box, RigidBody).current.position.y < 5 - 0.01f);
}

fn void test_default_world_is_serial() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    assert(fixture.physics.worker_count() == 1);
}

fn void test_friction_mix_receives_surface_ids() @test {
    PhysicsDesc desc = physics::default_physics_desc();
    desc.tuning.friction_mix = &record_mixed_surfaces;
    Fixture fixture;
    setup(&fixture, desc);
    defer teardown(&fixture);

    mixed_surfaces = {};
    Node* ground = add_static_node(&fixture, { 0, -0.5f, 0 });
    ColliderDesc floor = box_collider({ 10, 0.5f, 10 });
    floor.material.id = GROUND_SURFACE;
    fixture.physics.add_body(ground, physics::default_body_desc(STATIC), (&floor)[:1])!!;
    Node* box = add_static_node(&fixture, { 0, 0.6f, 0 });
    ColliderDesc crate = box_collider({ 0.5f, 0.5f, 0.5f });
    crate.material.id = CRATE_SURFACE;
    fixture.physics.add_body(box, physics::default_body_desc(DYNAMIC), (&crate)[:1])!!;
    for (uint update = 0; update < 30; update++) fixture.physics.update(fixture.physics.desc.tuning.fixed_dt);

    bool ground_first = mixed_surfaces[0] == GROUND_SURFACE && mixed_surfaces[1] == CRATE_SURFACE;
    bool box_first = mixed_surfaces[0] == CRATE_SURFACE && mixed_surfaces[1] == GROUND_SURFACE;
    assert(ground_first || box_first);
}

fn void test_motion_locks_hold_linear_axis() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    add_ground(&fixture);
    Node* node = add_static_node(&fixture, { 0, 3, 0 });
    ColliderDesc collider = box_collider({ 0.5f, 0.5f, 0.5f });
    BodyDesc body = physics::default_body_desc(DYNAMIC);
    body.locks.linear_y = true;
    fixture.physics.add_body(node, body, (&collider)[:1])!!;
    for (uint update = 0; update < 30; update++) {
        fixture.physics.update(fixture.physics.desc.tuning.fixed_dt);
        fixture.scene.update_world();
    }
    assert(close(node.world_position().y, 3));
}

fn void test_destroy_world_keeps_components_and_rebuilds() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Node* first = add_component_box(&fixture, { 0, 2, 0 });
    Node* second = add_component_box(&fixture, { 3, 2, 0 });
    fixture.physics.update(0);
    physics::destroy_physics_world(&fixture.physics);
    assert(fixture.scene.count(PhysicsBody) == 2);
    assert(fixture.scene.count(RigidBody) == 0);
    assert(fixture.scene.get(first, PhysicsBody).status == PENDING);

    fixture.physics = physics::create_physics_world(
        allocator: mem,
        assets:    &fixture.assets,
        scene:     &fixture.scene,
        desc:      physics::default_physics_desc(),
    )!!;
    fixture.physics.update(0);
    assert(fixture.scene.get(first, PhysicsBody).status == LIVE);
    assert(fixture.scene.get(second, PhysicsBody).status == LIVE);
}

fn void test_static_mesh_bodies_author_components() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Node* floor = fixture.scene.add_mesh(fixture.unit_box, {}, name: "floor")!!;
    Node* authored = fixture.scene.add_mesh(fixture.unit_box, {}, name: "authored")!!;
    authored.local.position = { 0, 3, 0 };
    fixture.scene.update_world();
    ColliderDesc collider = box_collider({ 0.5f, 0.5f, 0.5f });
    fixture.scene.add_physics_body(authored, physics::default_body_desc(DYNAMIC), (&collider)[:1])!!;

    assert(fixture.scene.add_static_mesh_bodies(fixture.scene.root) == 1);
    fixture.physics.update(0);
    assert(fixture.scene.has(floor, RigidBody));
    assert(fixture.scene.has(authored, RigidBody));
}

fn void test_add_body_replaces_body_left_by_removed_component() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Node* box = add_component_box(&fixture, { 0, 2, 0 });
    fixture.physics.update(0);
    b3::BodyId first = fixture.physics.body(box)!!;
    fixture.scene.remove_component(box, PhysicsBody);
    ColliderDesc collider = box_collider({ 1, 1, 1 });
    fixture.physics.add_body(box, physics::default_body_desc(DYNAMIC), (&collider)[:1])!!;
    assert(!first.is_valid());
    assert(fixture.scene.count(RigidBody) == 1);
    assert(close_vec(fixture.scene.get(box, RigidBody).colliders[0].half_extents, { 1, 1, 1 }));
}

fn void test_disabled_body_does_not_step() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Node* box = add_box(&fixture, { 0, 5, 0 });
    fixture.physics.set_enabled(box, false);
    run_updates(&fixture, 30);
    assert(close_vec(box.world_position(), { 0, 5, 0 }));

    fixture.physics.set_enabled(box, true);
    run_updates(&fixture, 10);
    assert(box.world_position().y < 5 - 0.01f);
}

fn void test_disabled_body_excluded_from_queries() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Node* box = add_box(&fixture, { 0, 0, 0 }, STATIC, false);
    fixture.physics.set_enabled(box, false);
    assert(!ray_hits_below(&fixture, { 0, 5, 0 }));
    assert(overlap_count(&fixture, { 0, 0, 0 }) == 0);

    fixture.physics.set_enabled(box, true);
    assert(ray_hits_below(&fixture, { 0, 5, 0 }));
    assert(overlap_count(&fixture, { 0, 0, 0 }) == 1);
}

fn void test_set_enabled_is_idempotent() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Node* box = add_box(&fixture, { 0, 0, 0 }, STATIC, false);
    fixture.physics.set_enabled(box, false);
    assert(!fixture.physics.is_enabled(box));
    fixture.physics.set_enabled(box, false);
    assert(!fixture.physics.is_enabled(box));
    fixture.physics.set_enabled(box, true);
    assert(fixture.physics.is_enabled(box));
    fixture.physics.set_enabled(box, true);
    assert(fixture.physics.is_enabled(box));
    assert(ray_hits_below(&fixture, { 0, 5, 0 }));
}

fn void test_disabled_body_teleport_and_relaunch() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Node* box = add_box(&fixture, { 0, 5, 0 });
    fixture.physics.set_enabled(box, false);
    run_updates(&fixture, 1);
    fixture.physics.teleport(box, { 10, 5, 0 }, quaternion::IDENTITY);
    fixture.physics.set_enabled(box, true);
    fixture.physics.set_velocity(box, { 1, 0, 0 }, { 0, 0, 0 });
    run_updates(&fixture, 1);

    Vec3 position = fixture.scene.get(box, RigidBody).current.position;
    assert(position.x > 10);
    assert(close_vec(position, { 10, 5, 0 }, 0.05f));
}

fn void test_rebuild_keeps_disabled() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Node* box = add_box(&fixture, { 0, 0, 0 }, STATIC, false);
    b3::BodyId first = fixture.physics.body(box)!!;
    fixture.physics.set_enabled(box, false);
    fixture.scene.get(box, PhysicsBody).mark_changed();
    fixture.physics.update(0);

    assert(!first.is_valid());
    assert(fixture.physics.body(box)!!.is_valid());
    assert(!fixture.physics.is_enabled(box));
    assert(!ray_hits_below(&fixture, { 0, 5, 0 }));
}

fn void test_authored_disabled_builds_disabled() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Node* box = fixture.scene.add_node(name: "box")!!;
    fixture.scene.update_world();
    BodyDesc body = physics::default_body_desc(DYNAMIC);
    body.disabled = true;
    ColliderDesc collider = box_collider({ 0.5f, 0.5f, 0.5f });
    fixture.physics.add_body(box, body, (&collider)[:1])!!;

    assert(!fixture.physics.is_enabled(box));
    assert(!ray_hits_below(&fixture, { 0, 5, 0 }));
    run_updates(&fixture, 30);
    assert(close_vec(box.world_position(), { 0, 0, 0 }));
}

fn void test_counters_reflect_the_world() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    add_ground(&fixture);
    Node* first = add_box(&fixture, { 0, 2, 0 });
    Node* second = add_box(&fixture, { 2, 2, 0 });
    fixture.physics.add_joint(second, physics::default_joint_desc(REVOLUTE, first.id))!!;
    run_updates(&fixture, 1);

    PhysicsCounters counters = fixture.physics.counters();
    assert(counters.bodies == 3 && counters.shapes == 3 && counters.joints == 1);
    assert(counters.occupied_snapshots == 0);
    assert(counters.snapshot_capacity == fixture.physics.desc.snapshot_capacity);
    add_geometry_body(&fixture, HULL, DYNAMIC);
    run_updates(&fixture, 1);
    assert(fixture.physics.counters().occupied_snapshots == 1);
}

fn void test_body_state_reports_velocity_mass_and_centre() @test {
    PhysicsDesc desc = physics::default_physics_desc();
    desc.tuning.gravity = {};
    Fixture fixture;
    setup(&fixture, desc);
    defer teardown(&fixture);

    Node* node = add_static_node(&fixture, { 1, 2, 3 });
    ColliderDesc collider = box_collider({ 0.5f, 0.5f, 0.5f });
    collider.density = 1000;
    fixture.physics.add_body(node, physics::default_body_desc(DYNAMIC), (&collider)[:1])!!;
    run_updates(&fixture, 1);
    fixture.physics.set_velocity(node, { 1, 0, 0 }, { 0, 2, 0 });
    run_updates(&fixture, 1);

    BodyState state = fixture.physics.body_state(node);
    assert(close_vec(state.linear_velocity, { 1, 0, 0 }));
    assert(close_vec(state.angular_velocity, { 0, 2, 0 }));
    assert(math::abs(state.mass - 1000) <= 0.01f);
    Vec3 position = fixture.physics.body(node)!!.position();
    assert(close_vec(state.center_of_mass, position));
    assert(state.awake);
}

fn void test_overlap_aabb_reports_each_body_once() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Node* pair = add_static_node(&fixture);
    ColliderDesc[2] colliders = { box_collider({ 0.25f, 0.25f, 0.25f }), box_collider({ 0.25f, 0.25f, 0.25f }) };
    colliders[0].local.position = { -0.6f, 0, 0 };
    colliders[1].local.position = { 0.6f, 0, 0 };
    fixture.physics.add_body(pair, physics::default_body_desc(STATIC), colliders[..])!!;
    add_box(&fixture, { 10, 0, 0 }, STATIC);
    run_updates(&fixture, 1);

    Node*[] nodes = fixture.physics.overlap_aabb(tmem, { .min = { -2, -2, -2 }, .max = { 2, 2, 2 } });
    assert(nodes.len == 1 && nodes[0] == pair);
}

fn void test_cast_shape_reports_nearest_first() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Node* near = add_box(&fixture, { 2, 0, 0 }, STATIC);
    Node* far = add_box(&fixture, { 5, 0, 0 }, STATIC);
    run_updates(&fixture, 1);

    ColliderKind[3] kinds = { SPHERE, CAPSULE, BOX };
    foreach (kind : kinds) {
        ColliderDesc shape = physics::default_collider_desc(kind);
        shape.radius = 0.25f;
        shape.half_height = 0.25f;
        shape.half_extents = { 0.25f, 0.25f, 0.25f };
        ShapeCastHit[] hits = fixture.physics.cast_shape(tmem, shape, { 10, 0, 0 });
        assert(hits.len == 2);
        assert(hits[0].fraction <= hits[1].fraction);
        assert(hits[0].node == near && hits[1].node == far);
        assert(math::abs(hits[0].fraction - (2 - 0.5f - 0.25f) / 10) <= 0.01f);
    }
}

fn void test_contact_points_of_a_resting_box() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Node* ground = add_ground(&fixture);
    Node* box = add_box(&fixture, { 0, 1, 0 });
    run_updates(&fixture, SETTLE_UPDATES);

    ContactPoint[] points = fixture.physics.contact_points(tmem, box);
    assert(points.len >= 1);
    foreach (point : points) {
        assert(point.other == ground);
        assert(point.separation <= CONTACT_SLOP);
        assert(close_vec(point.normal, { 0, -1, 0 }, 1e-3f));
        assert(math::abs(point.point.y) <= CONTACT_SLOP);
    }
    ContactPoint[] ground_points = fixture.physics.contact_points(tmem, ground);
    assert(ground_points.len >= 1);
    foreach (point : ground_points) {
        assert(point.other == box);
        assert(close_vec(point.normal, { 0, 1, 0 }, 1e-3f));
    }
}

fn void test_widened_flags_add_segments() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    add_ground(&fixture);
    add_box(&fixture, { 0, 0.5f, 0 });
    Node* first = add_box(&fixture, { 4, 3, 0 }, STATIC);
    Node* second = add_box(&fixture, { 4, 1.5f, 0 });
    fixture.physics.add_joint(second, physics::default_joint_desc(REVOLUTE, first.id))!!;
    fixture.physics.desc.tuning.sleep = false;
    fixture.physics.set_tuning(fixture.physics.desc.tuning);
    run_updates(&fixture, SETTLE_UPDATES);

    debug::DebugDraw sink = debug::create_debug_draw(mem, 1 << 16);
    defer debug::destroy_debug_draw(&sink);
    PhysicsDebugOptions base = { .colliders = true, .contacts = true, .joints = true };
    fixture.physics.debug_draw(&sink, base);
    usz base_segments = (usz)sink.vertices.len() / 2;

    PhysicsDebugOptions[4] widened = { base, base, base, base };
    widened[0].mass = true;
    widened[1].contact_forces = true;
    widened[2].islands = true;
    widened[3].joint_extras = true;
    foreach (index, options : widened) {
        sink.clear();
        fixture.physics.debug_draw(&sink, options);
        io::eprintfn("flag %d: %d segments over %d", index, sink.vertices.len() / 2, base_segments);
        assert((usz)sink.vertices.len() / 2 > base_segments);
    }
}

fn void test_replace_geometry_keeps_live_body_snapshot() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    Node* live = add_geometry_body(&fixture, MESH, STATIC);
    Collider* live_collider = &fixture.scene.get(live, RigidBody).colliders[0];
    usz live_wire = live_collider.wire.len;
    SnapshotHandle live_handle = live_collider.snapshot;

    @pool() {
        Geometry grid = geometry::plane(tmem, 2, 2, 4, 4);
        fixture.assets.replace_geometry(fixture.unit_box, &grid)!!;
    };
    fixture.physics.update(physics::DEFAULT_FIXED_DT);

    CollisionSnapshot* kept = &fixture.physics.snapshots.slots[live_handle.index];
    assert(kept.sources[0].revision == 1);
    assert(live_collider.wire.len == live_wire);

    Node* added = add_geometry_body(&fixture, MESH, STATIC);
    Collider* added_collider = &fixture.scene.get(added, RigidBody).colliders[0];
    CollisionSnapshot* fresh = &fixture.physics.snapshots.slots[added_collider.snapshot.index];
    assert(fresh.sources[0].revision == 2);
    assert(added_collider.wire.len / 6 == 32);
    assert(occupied_snapshots(&fixture.physics) == 2);
}
