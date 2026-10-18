module c3d_physics_collide_test;

import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::maths;
import c3d::physics @public;
import c3d::physics::cloth;
import c3d::scene;
import std::math;
import b3;

struct CacheLifetimeFixture @private {
    AssetStore assets;
    CollisionCache cache;
    GeometryId geometry;
}

fn Vec3[] query_prism_points(uint sides, float center_y = 0.49f) @private {
    Vec3[] points = alloc::new_array(tmem, Vec3, (sz)(2 * sides));
    for (uint index = 0; index < sides; index++) {
        float angle = 2 * (float)math::PI * (float)index / (float)sides;
        points[index] = { math::cos(angle), center_y - 0.5f, math::sin(angle) };
        points[index + sides] = { math::cos(angle), center_y + 0.5f, math::sin(angle) };
    }
    return points;
}

fn void setup_cache_lifetime(CacheLifetimeFixture* fixture, uint capacity = 3) @private {
    fixture.assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    fixture.cache = physics::create_collision_cache(mem, &fixture.assets, {
        .snapshot_capacity = capacity,
        .cache_wireframes = false,
    })!!;

    @pool() {
        Geometry box = geometry::box(
            allocator: tmem,
            width: 1,
            height: 1,
            depth: 1,
        );
        fixture.geometry = fixture.assets.add_geometry(&box)!!;
    };
}

fn void teardown_cache_lifetime(CacheLifetimeFixture* fixture) @private {
    physics::destroy_collision_cache(&fixture.cache)!!;
    asset::destroy_asset_store(&fixture.assets);
}

fn CollisionShapeDesc cache_hull_desc(GeometryId geometry) @private {
    CollisionShapeDesc desc = physics::default_collision_shape_desc(physics::ColliderKind.HULL);
    desc.geometry = geometry;
    return desc;
}

fn void test_collision_cache_worlds_and_query_owners_release_in_either_order() @test {
    foreach (world_first : (bool[2]){ false, true }) {
        CacheLifetimeFixture fixture;
        setup_cache_lifetime(&fixture);
        defer teardown_cache_lifetime(&fixture);

        Scene first_scene = scene::create_scene(mem, { .max_nodes = 4 });
        defer scene::destroy_scene(&first_scene);
        Scene second_scene = scene::create_scene(mem, { .max_nodes = 4 });
        defer scene::destroy_scene(&second_scene);
        physics::register_physics(&first_scene)!!;
        physics::register_physics(&second_scene)!!;

        PhysicsDesc desc = physics::default_physics_desc();
        desc.snapshot_capacity = 0;
        desc.cache_wireframes = true;
        PhysicsWorld first = physics::create_physics_world(
            allocator: mem,
            assets: &fixture.assets,
            scene: &first_scene,
            desc: desc,
            cache: &fixture.cache,
        )!!;
        defer if (first.scene) physics::destroy_physics_world(&first);
        PhysicsWorld second = physics::create_physics_world(
            allocator: mem,
            assets: &fixture.assets,
            scene: &second_scene,
            desc: desc,
            cache: &fixture.cache,
        )!!;
        defer if (second.scene) physics::destroy_physics_world(&second);

        CollisionShape first_query = physics::create_collision_shape(
            allocator: mem,
            cache: &fixture.cache,
            desc: cache_hull_desc(fixture.geometry),
        )!!;
        defer physics::destroy_collision_shape(&first_query);
        CollisionShape second_query = physics::create_collision_shape(
            allocator: mem,
            cache: &fixture.cache,
            desc: cache_hull_desc(fixture.geometry),
        )!!;
        defer physics::destroy_collision_shape(&second_query);

        Node* node = first_scene.add_node(name: "cached_hull")!!;
        first_scene.update_world();
        ColliderDesc collider = physics::default_collider_desc(physics::ColliderKind.HULL);
        collider.geometry = fixture.geometry;
        first.add_body(node, physics::default_body_desc(STATIC), (&collider)[:1])!!;

        RigidBody* body = first_scene.get(node, RigidBody);
        SnapshotTable* table = fixture.cache.state;
        SnapshotHandle held = first_query.state.snapshot;
        assert(first.snapshots == table && second.snapshots == table && table.slots.len == 3);
        assert(!table.cache_wireframes && table.slots[held.index].wire.len == 0);
        assert(table.slots[held.index].holders == 3 && table.borrowers == 4);
        assert(second_query.state.shape.hull == first_query.state.shape.hull);
        assert(body.colliders[0].snapshot.index == held.index
            && body.colliders[0].snapshot.generation == held.generation);
        assert(@catch(physics::destroy_collision_cache(&fixture.cache)) == c3d::RESOURCE_IN_USE);

        if (world_first) {
            physics::destroy_physics_world(&first);
            physics::destroy_physics_world(&second);
            collide::Distance distance = first_query.view().distance(
                pose_a: maths::TRANSFORM_IDENTITY,
                other: second_query.view(),
                pose_b: posed({ 3, 0, 0 }),
            )!!;
            assert(near(distance.distance, 2));
            physics::destroy_collision_shape(&first_query);
            physics::destroy_collision_shape(&second_query);
        } else {
            physics::destroy_collision_shape(&first_query);
            physics::destroy_collision_shape(&second_query);
            assert(body.body.is_valid() && table.slots[held.index].holders == 1);
            physics::destroy_physics_world(&first);
            physics::destroy_physics_world(&second);
        }
        assert(table.borrowers == 0 && table.slots[held.index].holders == 0);
    }
}

fn void test_collision_cache_keeps_immutable_revisions_after_cpu_source_release() @test {
    CacheLifetimeFixture fixture;
    setup_cache_lifetime(&fixture, 2);
    defer teardown_cache_lifetime(&fixture);

    CollisionShapeDesc desc = cache_hull_desc(fixture.geometry);
    CollisionShape old = physics::create_collision_shape(mem, &fixture.cache, desc)!!;
    defer physics::destroy_collision_shape(&old);
    b3::HullData* old_hull = old.state.shape.hull;

    foreach (&point : fixture.assets.geometry(fixture.geometry).data.positions) *point *= 2;
    fixture.assets.mark_geometry_dirty(fixture.geometry);
    CollisionShape revised = physics::create_collision_shape(mem, &fixture.cache, desc)!!;
    defer physics::destroy_collision_shape(&revised);
    assert(old.state.shape.hull == old_hull && revised.state.shape.hull != old_hull);
    assert(near(old.state.bounds.max.x, 0.5f) && near(revised.state.bounds.max.x, 1));

    fixture.assets.release_geometry_cpu(fixture.geometry);
    CollisionShape shared = physics::create_collision_shape(mem, &fixture.cache, desc)!!;
    defer physics::destroy_collision_shape(&shared);
    assert(shared.state.shape.hull == revised.state.shape.hull);

    fixture.assets.mark_geometry_dirty(fixture.geometry);
    assert(@catch(physics::create_collision_shape(mem, &fixture.cache, desc)) == physics::SOURCE_UNAVAILABLE);
    assert(@ok(old.view().distance(maths::TRANSFORM_IDENTITY, revised.view(), posed({ 4, 0, 0 }))));

    physics::destroy_collision_shape(&old);
    physics::destroy_collision_shape(&shared);
    physics::destroy_collision_shape(&revised);

    fixture.assets.geometry(fixture.geometry).data = geometry::box(
        allocator: fixture.assets.allocator,
        width: 3,
        height: 1,
        depth: 1,
    );
    fixture.assets.mark_geometry_dirty(fixture.geometry);
    CollisionShape latest = physics::create_collision_shape(mem, &fixture.cache, desc)!!;
    defer physics::destroy_collision_shape(&latest);
    assert(near(latest.state.bounds.max.x, 1.5f));
    assert(latest.state.snapshot.generation != 1);
}

fn void test_collision_cache_capacity_and_world_isolation() @test {
    CacheLifetimeFixture fixture;
    setup_cache_lifetime(&fixture, 0);
    defer teardown_cache_lifetime(&fixture);

    CollisionShapeDesc sphere = physics::default_collision_shape_desc(physics::ColliderKind.SPHERE);
    sphere.radius = 0.5f;
    CollisionShape shape = physics::create_collision_shape(mem, &fixture.cache, sphere)!!;
    defer physics::destroy_collision_shape(&shape);

    assert(@catch(physics::destroy_collision_cache(&fixture.cache)) == c3d::RESOURCE_IN_USE);
    assert(@catch(physics::create_collision_shape(mem, &fixture.cache, cache_hull_desc(fixture.geometry)))
        == c3d::CAPACITY_EXCEEDED);

    AssetStore other = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&other);
    Scene scene = scene::create_scene(mem, { .max_nodes = 2 });
    defer scene::destroy_scene(&scene);
    physics::register_physics(&scene)!!;

    assert(@catch(physics::create_physics_world(
        allocator: mem,
        assets: &other,
        scene: &scene,
        desc: physics::default_physics_desc(),
        cache: &fixture.cache,
    )) == c3d::INVALID_ARGUMENT);

    PhysicsDesc desc = physics::default_physics_desc();
    desc.snapshot_capacity = 1;
    PhysicsWorld world = physics::create_physics_world(
        allocator: mem,
        assets: &fixture.assets,
        scene: &scene,
        desc: desc,
    )!!;
    defer physics::destroy_physics_world(&world);
    assert(world.owns_snapshots && world.snapshots != fixture.cache.state && fixture.cache.state.borrowers == 1);

    physics::destroy_collision_shape(&shape);
    physics::destroy_collision_cache(&fixture.cache)!!;
    assert(fixture.cache.state == null);
}

fn void test_collision_cache_cloth_refreshes_after_shared_hull_body_rebuild() @test {
    CacheLifetimeFixture fixture;
    setup_cache_lifetime(&fixture);
    defer teardown_cache_lifetime(&fixture);

    Scene scene = scene::create_scene(mem, { .max_nodes = 4 });
    defer scene::destroy_scene(&scene);
    physics::register_physics(&scene)!!;
    PhysicsWorld world = physics::create_physics_world(
        allocator: mem,
        assets: &fixture.assets,
        scene: &scene,
        desc: physics::default_physics_desc(),
        cache: &fixture.cache,
    )!!;
    defer physics::destroy_physics_world(&world);

    CollisionShape query = physics::create_collision_shape(mem, &fixture.cache, cache_hull_desc(fixture.geometry))!!;
    defer physics::destroy_collision_shape(&query);

    Node* obstacle = scene.add_node(name: "shared_hull")!!;
    scene.update_world();
    ColliderDesc collider = physics::default_collider_desc(physics::ColliderKind.HULL);
    collider.geometry = fixture.geometry;
    world.add_body(obstacle, physics::default_body_desc(STATIC), (&collider)[:1])!!;

    GeometryId cloth_geometry;
    @pool() {
        Geometry triangle = {
            .positions = alloc::new_array(tmem, Vec3, 3),
            .indices = alloc::new_array(tmem, uint, 3),
        };
        triangle.positions[..] = { { 0, 2, 0 }, { 1, 2, 0 }, { 0, 2, 1 } }[..];
        triangle.indices[..] = { 0, 2, 1 }[..];
        triangle.finalize();
        cloth_geometry = fixture.assets.add_geometry(&triangle)!!;
    };

    Node* fabric = scene.add_mesh(cloth_geometry, {})!!;
    scene.update_world();
    uint[3] pins = { 0, 1, 2 };
    Entity[1] colliders = { obstacle.id };
    cloth::ClothDesc cloth_desc = cloth::default_cloth_desc();
    cloth_desc.pins = pins[..];
    cloth_desc.colliders = colliders[..];
    scene.add_cloth(&fixture.assets, fabric, cloth_desc)!!;

    world.update(0);
    world.update_cloths();
    cloth::ClothState* cloth_state = scene.get(fabric, cloth::Cloth).state;
    SnapshotHandle previous = query.state.snapshot;
    assert(cloth_state.shapes[0].snapshot.index == previous.index);
    assert(fixture.cache.state.slots[previous.index].holders == 2);

    foreach (&point : fixture.assets.geometry(fixture.geometry).data.positions) *point *= 2;
    fixture.assets.mark_geometry_dirty(fixture.geometry);
    scene.get(obstacle, PhysicsBody).mark_changed();
    world.update(0);
    world.update_cloths();

    RigidBody* rebuilt = scene.get(obstacle, RigidBody);
    SnapshotHandle current = rebuilt.colliders[0].snapshot;
    assert(current.index != previous.index && cloth_state.shapes[0].snapshot.index == current.index);
    assert(fixture.cache.state.slots[current.index].holders == 1);
    assert(fixture.cache.state.slots[previous.index].holders == 1);
}

fn void test_collision_shape_preparation_refuses_unsupported_and_degenerate_inputs() @test {
    CacheLifetimeFixture fixture;
    setup_cache_lifetime(&fixture);
    defer teardown_cache_lifetime(&fixture);

    CollisionShapeDesc desc = physics::default_collision_shape_desc(physics::ColliderKind.SPHERE);
    desc.radius = float::nan;
    assert(@catch(physics::create_collision_shape(mem, &fixture.cache, desc)) == c3d::INVALID_ARGUMENT);
    desc.radius = float::max;
    assert(@catch(physics::create_collision_shape(mem, &fixture.cache, desc)) == b3::DEGENERATE_GEOMETRY);

    foreach (kind : (ColliderKind[3]){ MESH, HEIGHT_FIELD, COMPOUND }) {
        desc = physics::default_collision_shape_desc(kind);
        assert(@catch(physics::create_collision_shape(mem, &fixture.cache, desc)) == c3d::UNSUPPORTED);
    }

    desc = physics::default_collision_shape_desc(physics::ColliderKind.CAPSULE);
    desc.radius = 0.5f;
    desc.half_height = 0.0001f;
    assert(@catch(physics::create_collision_shape(mem, &fixture.cache, desc)) == c3d::UNSUPPORTED);

    desc = physics::default_collision_shape_desc(physics::ColliderKind.BOX);
    desc.half_extents = { 0.0005f, 0.5f, 0.5f };
    assert(@catch(physics::create_collision_shape(mem, &fixture.cache, desc)) == c3d::UNSUPPORTED);

    Vec3[] source = fixture.assets.geometry(fixture.geometry).data.positions;
    source[0].x = -float::max;
    source[1].x = float::max;
    fixture.assets.mark_geometry_dirty(fixture.geometry);
    assert(@catch(physics::create_collision_shape(mem, &fixture.cache, cache_hull_desc(fixture.geometry)))
        == b3::DEGENERATE_GEOMETRY);

    @pool() {
        Geometry geometry = { .positions = query_prism_points(33) };
        geometry.finalize();
        GeometryId id = fixture.assets.add_geometry(&geometry)!!;
        assert(@catch(physics::create_collision_shape(mem, &fixture.cache, cache_hull_desc(id)))
            == c3d::CAPACITY_EXCEEDED);
    };
    assert(fixture.cache.state.borrowers == 0);
}

fn void test_collision_shape_scale_domain_refuses_values_outside_each_kind() @test {
    CacheLifetimeFixture fixture;
    setup_cache_lifetime(&fixture);
    defer teardown_cache_lifetime(&fixture);

    CollisionShapeDesc hull = cache_hull_desc(fixture.geometry);
    float hull_minimum = 0.01f;
    float below_minimum = bitcast(bitcast(hull_minimum, uint) - 1, float);

    hull.scale = { 1, -hull_minimum, 1 };
    CollisionShape thin = physics::create_collision_shape(mem, &fixture.cache, hull)!!;
    physics::destroy_collision_shape(&thin);

    hull.scale = { 1, -below_minimum, 1 };
    assert(@catch(physics::create_collision_shape(mem, &fixture.cache, hull)) == c3d::UNSUPPORTED);

    foreach (invalid : (float[2]){ 0, float::nan }) {
        hull.scale = { 1, invalid, 1 };
        assert(@catch(physics::create_collision_shape(mem, &fixture.cache, hull)) == c3d::INVALID_ARGUMENT);
    }

    foreach (kind : (ColliderKind[2]){ SPHERE, CAPSULE }) {
        CollisionShapeDesc round = physics::default_collision_shape_desc(kind);
        round.radius = 0.5f;
        round.half_height = 0.75f;
        round.scale = { 1, 2, 1 };
        assert(@catch(physics::create_collision_shape(mem, &fixture.cache, round)) == c3d::UNSUPPORTED);
    }

    CollisionShapeDesc capsule = physics::default_collision_shape_desc(physics::ColliderKind.CAPSULE);
    capsule.radius = 0.5f;
    capsule.half_height = 0.75f;
    capsule.scale = { 0.003f, 0.003f, 0.003f };
    assert(@catch(physics::create_collision_shape(mem, &fixture.cache, capsule)) == c3d::UNSUPPORTED);

    CollisionShapeDesc box = physics::default_collision_shape_desc(physics::ColliderKind.BOX);
    box.half_extents = { 0.5f, 0.5f, 0.5f };
    box.scale = { 1, 0.0021f, 1 };
    CollisionShape flat = physics::create_collision_shape(mem, &fixture.cache, box)!!;
    physics::destroy_collision_shape(&flat);

    box.scale = { 1, 0.0019f, 1 };
    assert(@catch(physics::create_collision_shape(mem, &fixture.cache, box)) == c3d::UNSUPPORTED);

    assert(fixture.cache.state.borrowers == 0);
    foreach (slot : fixture.cache.state.slots) assert(slot.holders == 0);
}

fn void test_scaled_hull_variants_share_entries_and_leave_unit_bodies_usable() @test {
    CacheLifetimeFixture fixture;
    setup_cache_lifetime(&fixture);
    defer teardown_cache_lifetime(&fixture);

    Scene scene = scene::create_scene(mem, { .max_nodes = 2 });
    defer scene::destroy_scene(&scene);
    physics::register_physics(&scene)!!;

    PhysicsWorld world = physics::create_physics_world(
        allocator: mem,
        assets: &fixture.assets,
        scene: &scene,
        desc: physics::default_physics_desc(),
        cache: &fixture.cache,
    )!!;
    defer physics::destroy_physics_world(&world);

    Node* node = scene.add_node(name: "unit_hull")!!;
    scene.update_world();
    ColliderDesc collider = physics::default_collider_desc(physics::ColliderKind.HULL);
    collider.geometry = fixture.geometry;
    world.add_body(node, physics::default_body_desc(STATIC), (&collider)[:1])!!;

    SnapshotTable* table = fixture.cache.state;
    SnapshotHandle unit = scene.get(node, RigidBody).colliders[0].snapshot;
    b3::HullData* unit_hull = table.slots[unit.index].hull;

    CollisionShapeDesc desc = cache_hull_desc(fixture.geometry);
    desc.scale = { 2, 0.5f, -1 };

    CollisionShape first = physics::create_collision_shape(mem, &fixture.cache, desc)!!;
    defer physics::destroy_collision_shape(&first);

    CollisionShape second = physics::create_collision_shape(mem, &fixture.cache, desc)!!;
    defer physics::destroy_collision_shape(&second);

    assert(second.state.snapshot.index == first.state.snapshot.index);
    assert(second.state.shape.hull == first.state.shape.hull && first.state.shape.hull != unit_hull);
    assert(table.slots[first.state.snapshot.index].holders == 2 && table.slots[unit.index].holders == 1);
    assert(near_vector(first.state.bounds.max, { 1, 0.25f, 0.5f }) && near(unit_hull.aabb.upper_bound.x, 0.5f));

    desc.scale = { 2, 0.5f, 1 };
    CollisionShape other = physics::create_collision_shape(mem, &fixture.cache, desc)!!;
    defer physics::destroy_collision_shape(&other);

    assert(other.state.snapshot.index != first.state.snapshot.index);
    assert(other.state.shape.hull != first.state.shape.hull);

    desc.scale = { 3, 1, 1 };
    assert(@catch(physics::create_collision_shape(mem, &fixture.cache, desc)) == c3d::CAPACITY_EXCEEDED);
    assert(table.slots[unit.index].holders == 1 && table.borrowers == 4);

    world.update(0);
    assert(scene.get(node, RigidBody).body.is_valid() && table.slots[unit.index].hull == unit_hull);
}
