module c3d_physics_collide_test;

import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::maths;
import c3d::physics @public;
import c3d::physics::cloth;
import c3d::scene;
import std::core::mem::allocators;
import std::io;
import b3;

struct CacheLifetimeFixture @private {
    AssetStore assets;
    CollisionCache cache;
    GeometryId geometry;
}

struct CacheAllocationFailure (Allocator) @private {
    Allocator backing;
    sz size;
    uint failures;
    bool enabled;
}

fn void*? CacheAllocationFailure.acquire(
    &self,
    sz size,
    AllocInitType init_type,
    sz alignment,
) @dynamic {
    if (self.enabled && size == self.size) {
        self.failures++;
        return mem::OUT_OF_MEMORY~;
    }
    return self.backing.acquire(size, init_type, alignment);
}

fn void*? CacheAllocationFailure.resize(
    &self,
    void* pointer,
    sz size,
    sz alignment,
) @dynamic {
    return self.backing.resize(pointer, size, alignment);
}

fn void CacheAllocationFailure.release(&self, void* pointer, bool aligned) @dynamic {
    self.backing.release(pointer, aligned);
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
        assert(body.colliders[0].shape.hull()!! != first_query.state.shape.hull);
        assert(@catch(physics::destroy_collision_cache(&fixture.cache)) == c3d::RESOURCE_IN_USE);
        assert(fixture.cache.state == table && table.borrowers == 4 && table.slots[held.index].holders == 3);

        if (world_first) {
            physics::destroy_physics_world(&first);
            physics::destroy_physics_world(&second);
            collide::Distance distance = first_query.view().distance(
                pose_a: maths::TRANSFORM_IDENTITY,
                other: second_query.view(),
                pose_b: posed({ 3, 0, 0 }),
            )!!;
            assert(near(distance.distance, 2));
            assert(table.slots[held.index].holders == 2);
            physics::destroy_collision_shape(&first_query);
            assert(second_query.state.shape.hull == table.slots[held.index].hull);
            physics::destroy_collision_shape(&second_query);
        } else {
            physics::destroy_collision_shape(&first_query);
            physics::destroy_collision_shape(&second_query);
            assert(body.body.is_valid() && table.slots[held.index].holders == 1);
            physics::destroy_physics_world(&first);
            assert(@catch(physics::destroy_collision_cache(&fixture.cache)) == c3d::RESOURCE_IN_USE);
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

fn void test_collision_cache_zero_capacity_and_store_mismatch_preserve_lifetime() @test {
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
    assert(fixture.cache.state.borrowers == 1);
    AssetStore other = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&other);
    Scene scene = scene::create_scene(mem, { .max_nodes = 1 });
    defer scene::destroy_scene(&scene);
    physics::register_physics(&scene)!!;
    int native_bytes = b3::byte_count();
    assert(@catch(physics::create_physics_world(
        allocator: mem,
        assets: &other,
        scene: &scene,
        desc: physics::default_physics_desc(),
        cache: &fixture.cache,
    )) == c3d::INVALID_ARGUMENT);
    assert(fixture.cache.state.borrowers == 1 && b3::byte_count() == native_bytes);
    physics::destroy_collision_shape(&shape);
    physics::destroy_collision_cache(&fixture.cache)!!;
    assert(fixture.cache.state == null);
}

fn void test_collision_cache_private_world_defaults_remain_independent() @test {
    CacheLifetimeFixture fixture;
    setup_cache_lifetime(&fixture);
    defer teardown_cache_lifetime(&fixture);
    Scene scene = scene::create_scene(mem, { .max_nodes = 2 });
    defer scene::destroy_scene(&scene);
    physics::register_physics(&scene)!!;
    PhysicsDesc desc = physics::default_physics_desc();
    desc.snapshot_capacity = 1;
    PhysicsWorld world = physics::create_physics_world(
        allocator: mem,
        assets: &fixture.assets,
        scene: &scene,
        desc: desc,
    )!!;
    defer physics::destroy_physics_world(&world);
    assert(world.owns_snapshots && world.snapshots != fixture.cache.state && world.snapshots.slots.len == 1);
    assert(world.snapshots.cache_wireframes && fixture.cache.state.borrowers == 0);
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
    assert(!cloth_state.contact_result.failure && cloth_state.shapes.len == 1);
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
    assert(current.index != previous.index);
    assert(!cloth_state.contact_result.failure && cloth_state.shapes.len == 1);
    assert(cloth_state.shapes[0].snapshot.index == current.index
        && cloth_state.shapes[0].snapshot.generation == current.generation);
    assert(fixture.cache.state.slots[current.index].holders == 1);
    assert(fixture.cache.state.slots[previous.index].holders == 1 && near(query.state.bounds.max.y, 0.5f));
}

fn void test_collision_cache_allocation_failures_release_partial_hull_cooking() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        CacheLifetimeFixture fixture;
        setup_cache_lifetime(&fixture);
        defer teardown_cache_lifetime(&fixture);
        physics::destroy_collision_cache(&fixture.cache)!!;
        CacheAllocationFailure rejector = { .backing = &tracker };
        CollisionCacheDesc desc = { .snapshot_capacity = 2, .cache_wireframes = true };
        rejector.size = (sz)(2 * CollisionSnapshot::size);
        rejector.enabled = true;
        assert(@catch(physics::create_collision_cache(&rejector, &fixture.assets, desc)) == c3d::CAPACITY_EXCEEDED);
        assert(tracker.allocation_count() == 0 && rejector.failures == 1);
        rejector.enabled = false;
        fixture.cache = physics::create_collision_cache(&rejector, &fixture.assets, desc)!!;
        sz baseline = tracker.allocation_count();
        int native_bytes = b3::byte_count();
        foreach (size : (sz[2]){ (sz)SnapshotSource::size, (sz)(24 * Vec3::size) }) {
            rejector.size = size;
            rejector.enabled = true;
            assert(@catch(physics::create_collision_shape(mem, &fixture.cache, cache_hull_desc(fixture.geometry)))
                == c3d::CAPACITY_EXCEEDED);
            rejector.enabled = false;
            assert(fixture.cache.state.borrowers == 0 && tracker.allocation_count() == baseline);
            assert(b3::byte_count() == native_bytes);
        }
        NullAllocator exhausted;
        assert(@catch(physics::create_collision_shape(&exhausted, &fixture.cache, cache_hull_desc(fixture.geometry)))
            == c3d::CAPACITY_EXCEEDED);
        assert(fixture.cache.state.borrowers == 0);
        foreach (slot : fixture.cache.state.slots) assert(slot.holders == 0);
        CollisionShape shape = physics::create_collision_shape(
            allocator: mem,
            cache: &fixture.cache,
            desc: cache_hull_desc(fixture.geometry),
        )!!;
        defer physics::destroy_collision_shape(&shape);
        assert(fixture.cache.state.slots[shape.state.snapshot.index].wire.len == 24);
    }
    assert(!tracker.has_leaks());
}

fn void test_collision_shape_preparation_refuses_unsupported_and_degenerate_inputs() @test {
    CacheLifetimeFixture fixture;
    setup_cache_lifetime(&fixture);
    defer teardown_cache_lifetime(&fixture);
    CollisionShapeDesc desc = physics::default_collision_shape_desc(physics::ColliderKind.SPHERE);
    desc.radius = 0.5f;
    desc.scale.x = 2;
    assert(@catch(physics::create_collision_shape(mem, &fixture.cache, desc)) == c3d::UNSUPPORTED);
    desc.scale = { 1, 1, 1 };
    desc.radius = float::nan;
    assert(@catch(physics::create_collision_shape(mem, &fixture.cache, desc)) == c3d::INVALID_ARGUMENT);
    NullAllocator exhausted;
    assert(@catch(physics::create_collision_shape(&exhausted, &fixture.cache, desc)) == c3d::INVALID_ARGUMENT);
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
    b3::BoxHull native_box = b3::make_box_hull(desc.half_extents.x, desc.half_extents.y, desc.half_extents.z);
    assert(native_box.base.aabb.upper_bound.x > desc.half_extents.x);
    io::printfn(
        "box_minimum,authored=%.9g,native=%.9g,units=%.9g",
        desc.half_extents.x,
        native_box.base.aabb.upper_bound.x,
        b3::length_units_per_meter(),
    );
    assert(@catch(physics::create_collision_shape(mem, &fixture.cache, desc)) == c3d::UNSUPPORTED);
    float minimum = 0.2f * (LINEAR_SLOP * b3::length_units_per_meter());
    desc.half_extents.x = bitcast(bitcast(minimum, uint) - 1, float);
    assert(@catch(physics::create_collision_shape(mem, &fixture.cache, desc)) == c3d::UNSUPPORTED);
    desc.half_extents.x = minimum;
    CollisionShape boundary_box = physics::create_collision_shape(mem, &fixture.cache, desc)!!;
    physics::destroy_collision_shape(&boundary_box);
    Vec3[] source = fixture.assets.geometry(fixture.geometry).data.positions;
    source[0].x = -float::max;
    source[1].x = float::max;
    fixture.assets.mark_geometry_dirty(fixture.geometry);
    int native_bytes = b3::byte_count();
    assert(@catch(physics::create_collision_shape(mem, &fixture.cache, cache_hull_desc(fixture.geometry)))
        == b3::DEGENERATE_GEOMETRY);
    assert(fixture.cache.state.borrowers == 0 && b3::byte_count() == native_bytes);
    foreach (size : (float[2]){ 1e12f, 1e-30f }) {
        foreach (index, &point : source) {
            *point = { index & 1 ? size : -size, index & 2 ? size : -size, index & 4 ? size : -size };
        }
        fixture.assets.mark_geometry_dirty(fixture.geometry);
        assert(@catch(physics::create_collision_shape(mem, &fixture.cache, cache_hull_desc(fixture.geometry)))
            == b3::DEGENERATE_GEOMETRY);
        assert(fixture.cache.state.borrowers == 0 && b3::byte_count() == native_bytes);
    }
    @pool() {
        foreach (sides : (uint[2]){ 32, 33 }) {
            Geometry geometry = { .positions = query_prism_points(sides) };
            geometry.finalize();
            GeometryId id = fixture.assets.add_geometry(&geometry)!!;
            desc = cache_hull_desc(id);
            if (sides == 32) {
                CollisionShape shape = physics::create_collision_shape(mem, &fixture.cache, desc)!!;
                physics::destroy_collision_shape(&shape);
            } else {
                assert(@catch(physics::create_collision_shape(mem, &fixture.cache, desc)) == c3d::CAPACITY_EXCEEDED);
                Scene scene = scene::create_scene(mem, { .max_nodes = 1 });
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
                Node* node = scene.add_node(name: "body_domain")!!;
                scene.update_world();
                ColliderDesc collider = physics::default_collider_desc(physics::ColliderKind.HULL);
                collider.geometry = id;
                world.add_body(node, physics::default_body_desc(STATIC), (&collider)[:1])!!;
                assert(scene.get(node, RigidBody).body.is_valid());
            }
        }
    };
    assert(fixture.cache.state.borrowers == 0);
}
