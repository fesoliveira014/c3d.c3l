module c3d_physics_collide_test;

import c3d;
import std::core::mem::allocators;
import std::math;
import std::math::quaternion;
import b3;

struct PreparedQueryFixture @private {
    AssetStore assets;
    CollisionCache cache;
    CollisionShape[4] owners;
    collide::Shape[4] shapes;
    collide::Hull hull;
}

fn void setup_prepared_queries(PreparedQueryFixture* fixture, Allocator allocator = mem) @private {
    fixture.assets = asset::create_asset_store(allocator, asset::default_asset_store_desc());
    fixture.cache = physics::create_collision_cache(
        allocator: allocator,
        assets: &fixture.assets,
        desc: physics::default_collision_cache_desc(),
    )!!;

    @pool() {
        Geometry box = geometry::box(
            allocator: tmem,
            width: 2,
            height: 2,
            depth: 2,
        );
        GeometryId geometry = fixture.assets.add_geometry(&box)!!;
        fixture.hull = collide::create_hull(box.positions)!!;
        ColliderKind[4] kinds = { SPHERE, CAPSULE, BOX, HULL };

        foreach (index, kind : kinds) {
            CollisionShapeDesc desc = physics::default_collision_shape_desc(kind);
            desc.radius = 0.5f;
            desc.half_height = 0.75f;
            desc.half_extents = { 1, 1, 1 };
            desc.geometry = geometry;
            fixture.owners[index] = physics::create_collision_shape(allocator, &fixture.cache, desc)!!;
        }
    };

    fixture.shapes = {
        collide::sphere_shape(0.5f),
        collide::capsule_shape(0.75f, 0.5f),
        collide::box_shape({ 1, 1, 1 }),
        collide::hull_shape(&fixture.hull),
    };
}

fn void teardown_prepared_queries(PreparedQueryFixture* fixture) @private {
    foreach (&owner : fixture.owners) physics::destroy_collision_shape(owner);
    physics::destroy_collision_cache(&fixture.cache)!!;
    collide::destroy_hull(&fixture.hull);
    asset::destroy_asset_store(&fixture.assets);
}

fn void assert_prepared_impact(collide::Impact actual, collide::Impact expected) @private {
    assert(near(actual.time, expected.time, LOOSE));
    assert(near_vector(actual.point, expected.point, LOOSE));
    assert(near_vector(actual.normal, expected.normal, LOOSE));
}

fn void test_prepared_query_convex_pairs_preserve_manifolds_and_distance() @test {
    PreparedQueryFixture fixture;
    setup_prepared_queries(&fixture);
    defer teardown_prepared_queries(&fixture);

    maths::Transform pose_a = posed({ 3, -2, 4 }, rotated());
    foreach (first, &owner_a : fixture.owners) {
        CollisionShapeView view_a = owner_a.view();
        foreach (second, &owner_b : fixture.owners) {
            CollisionShapeView view_b = owner_b.view();
            float extent_a = first < 2 ? 0.5f : 1;
            float extent_b = second < 2 ? 0.5f : 1;

            foreach (gap : (float[4]){ 2, 0, 0.01f, -0.1f }) {
                maths::Transform pose_b = pose_a;
                pose_b.position += pose_a.rotation.rotate_vec3({ extent_a + extent_b + gap, 0, 0 });

                collide::Manifold expected = collide::manifold(
                    a: fixture.shapes[first],
                    pose_a: pose_a,
                    b: fixture.shapes[second],
                    pose_b: pose_b,
                );
                CollisionContact[4] contacts;
                usz count = view_a.contacts(
                    pose_a: pose_a,
                    other: view_b,
                    pose_b: pose_b,
                    output: &contacts,
                )!!;
                assert(count == expected.count);
                foreach (index, point : contacts[:count]) {
                    assert(near_vector(point.point, expected.points[index].point, LOOSE));
                    assert(near_vector(point.normal, expected.normal, LOOSE));
                    assert(near(point.separation, expected.points[index].separation, LOOSE));
                    assert(point.triangle_index == physics::NO_COLLISION_TRIANGLE);
                }

                collide::Distance reference = collide::distance(
                    a: fixture.shapes[first],
                    pose_a: pose_a,
                    b: fixture.shapes[second],
                    pose_b: pose_b,
                );
                collide::Distance distance = view_a.distance(pose_a, view_b, pose_b)!!;
                assert(near(distance.distance, reference.distance, LOOSE));
                assert(near_vector(distance.point_a, reference.point_a, LOOSE));
                assert(near_vector(distance.point_b, reference.point_b, LOOSE));
                assert(near_vector(distance.normal, reference.normal, LOOSE));
            }
        }
    }
}

fn void test_prepared_query_capacity_refusal_keeps_output_and_canaries() @test {
    PreparedQueryFixture fixture;
    setup_prepared_queries(&fixture);
    defer teardown_prepared_queries(&fixture);

    CollisionShapeView first = fixture.owners[2].view();
    CollisionShapeView second = fixture.owners[3].view();
    maths::Transform pose_a = posed({});
    maths::Transform pose_b = posed({ 0, 1.99f, 0 });
    CollisionContact sentinel = {
        .point = { 31, 32, 33 },
        .normal = { 41, 42, 43 },
        .separation = 51,
        .triangle_index = 61,
    };
    CollisionContact[6] storage;
    foreach (&contact : storage) *contact = sentinel;

    usz count = first.contacts(
        pose_a: pose_a,
        other: second,
        pose_b: pose_b,
        output: storage[1:4],
    )!!;
    assert(count > 1 && count <= 4);

    foreach (capacity : (usz[2]){ 0, count - 1 }) {
        foreach (&contact : storage) *contact = sentinel;
        fault excuse = @catch(first.contacts(
            pose_a: pose_a,
            other: second,
            pose_b: pose_b,
            output: storage[1:capacity],
        ));
        assert(excuse == c3d::CAPACITY_EXCEEDED);
        foreach (contact : storage) {
            assert(contact.point == sentinel.point && contact.normal == sentinel.normal);
            assert(contact.separation == sentinel.separation && contact.triangle_index == sentinel.triangle_index);
        }
    }

    assert(first.contacts(
        pose_a: pose_a,
        other: second,
        pose_b: pose_b,
        output: storage[1:count],
    )!! == count);
    assert(storage[0].point == sentinel.point && storage[5].point == sentinel.point);
    assert(first.contacts(
        pose_a: pose_a,
        other: second,
        pose_b: posed({ 0, 5, 0 }),
        output: {},
    )!! == 0);
}

fn void test_prepared_query_casts_reconstruct_both_moving_witnesses() @test {
    PreparedQueryFixture fixture;
    setup_prepared_queries(&fixture);
    defer teardown_prepared_queries(&fixture);

    maths::Transform pose_a = posed({ 3, -2, 4 }, rotated());
    maths::Transform pose_b = pose_a;
    pose_b.position += pose_a.rotation.rotate_vec3({ 5, 0, 0 });
    Vec3 relative = pose_a.rotation.rotate_vec3({ -6, 0, 0 });

    foreach (first, &owner_a : fixture.owners) {
        CollisionShapeView view_a = owner_a.view();
        foreach (second, &owner_b : fixture.owners) {
            CollisionShapeView view_b = owner_b.view();
            collide::Impact reference = collide::cast(
                a: fixture.shapes[first],
                pose_a: pose_a,
                b: fixture.shapes[second],
                pose_b: pose_b,
                translation: relative,
            )!!;

            foreach (move_a : (Vec3[3]){ {}, -relative, { 0.5f, -0.25f, 0.75f } }) {
                Vec3 move_b = move_a + relative;
                collide::Impact found = view_a.cast(
                    pose_a: pose_a,
                    other: view_b,
                    pose_b: pose_b,
                    translation_a: move_a,
                    translation_b: move_b,
                )!!;
                collide::Impact expected = reference;
                expected.point += move_a * expected.time;
                assert_prepared_impact(found, expected);
            }

            assert(@catch(view_a.cast(
                pose_a: pose_a,
                other: view_b,
                pose_b: pose_b,
                translation_a: { 1, 0, 0 },
                translation_b: { 1, 0, 0 },
            )) == b3::NO_HIT);
        }
    }

    CollisionShapeView sphere = fixture.owners[0].view();
    maths::Transform band_pose = posed({ 0.995f, 0, 0 });
    collide::Impact band = sphere.cast(
        pose_a: posed({}),
        other: sphere,
        pose_b: band_pose,
        translation_a: { 1, 2, 3 },
        translation_b: { 1, 2, 3 },
    )!!;
    assert(band.time == 0 && band.normal == (Vec3){});
}

fn void test_prepared_query_sweeps_and_rays_preserve_convex_results() @test {
    PreparedQueryFixture fixture;
    setup_prepared_queries(&fixture);
    defer teardown_prepared_queries(&fixture);

    maths::Transform pose = posed({ 3, -2, 4 }, rotated());
    foreach (index, &owner : fixture.owners) {
        CollisionShapeView view = owner.view();
        CollisionShapeView sphere = fixture.owners[0].view();
        collide::Sweep sweep_a = { .start = pose, .end = posed({ 3.25f, -2, 4 }) };
        collide::Sweep sweep_b = {
            .start = posed({ 3, 3, 4 }),
            .end = posed({ 3, -2, 4 }),
        };
        collide::Impact reference = collide::time_of_impact(
            a: fixture.shapes[index],
            sweep_a: sweep_a,
            b: fixture.shapes[0],
            sweep_b: sweep_b,
        )!!;
        assert_prepared_impact(view.time_of_impact(sweep_a, sphere, sweep_b)!!, reference);

        Vec3 origin = pose.position + pose.rotation.rotate_vec3({ 5, 0, 0 });
        Vec3 direction = pose.rotation.rotate_vec3({ -1, 0, 0 });
        collide::ShapeRayHit expected = collide::ray_cast(
            shape: fixture.shapes[index],
            pose: pose,
            origin: origin,
            direction: direction,
            max_distance: 10,
        )!!;
        collide::ShapeRayHit found = view.ray_cast(
            pose: pose,
            origin: origin,
            direction: direction,
            max_distance: 10,
        )!!;
        assert(near(found.fraction, expected.fraction, LOOSE));
        assert(near_vector(found.point, expected.point, LOOSE));
        assert(near_vector(found.normal, expected.normal, LOOSE));

        collide::ShapeRayHit inside = view.ray_cast(
            pose: pose,
            origin: pose.position,
            direction: direction,
            max_distance: 10,
        )!!;
        assert(inside.fraction == 0 && inside.normal == (Vec3){});
        assert(@catch(view.ray_cast(
            pose: pose,
            origin: origin,
            direction: -direction,
            max_distance: 10,
        )) == b3::NO_HIT);
    }
}

fn void test_prepared_query_invalid_and_unrepresentable_inputs_are_refused() @test {
    PreparedQueryFixture fixture;
    setup_prepared_queries(&fixture);
    defer teardown_prepared_queries(&fixture);

    CollisionShapeView view = fixture.owners[0].view();
    maths::Transform identity = posed({});
    maths::Transform invalid = identity;
    invalid.position.x = float::nan;
    assert(@catch(view.distance(invalid, view, identity)) == c3d::INVALID_ARGUMENT);

    invalid = identity;
    invalid.rotation.v.w = 2;
    assert(@catch(view.distance(invalid, view, identity)) == c3d::INVALID_ARGUMENT);

    invalid = identity;
    invalid.scale = { 1, 2, 1 };
    assert(@catch(view.distance(invalid, view, identity)) == c3d::UNSUPPORTED);
    assert(@catch(view.distance(posed({ float::max, 0, 0 }), view, posed({ -float::max, 0, 0 })))
      == c3d::UNSUPPORTED);
    assert(@catch(view.distance(identity, view, posed({ 1e30f, 0, 0 }))) == c3d::UNSUPPORTED);
    assert(view.distance(posed({ 1e30f, 0, 0 }), view, posed({ 1e30f, 0, 0 }))!!.distance == 0);

    Quat diagonal = quaternion::from_axis_angle((Vec3){ 0, 0, 1 }, (float)math::PI / 4);
    assert(@catch(view.distance(posed({}, diagonal), view, posed({ 3e38f, 3e38f, 0 }))) == c3d::UNSUPPORTED);
    assert(@catch(view.cast(
        pose_a: identity,
        other: view,
        pose_b: identity,
        translation_a: { -float::max, 0, 0 },
        translation_b: { float::max, 0, 0 },
    )) == c3d::UNSUPPORTED);
    assert(@catch(view.cast(
        pose_a: posed({ 2e38f, 0, 0 }),
        other: view,
        pose_b: posed({ 2e38f, 0, 0 }),
        translation_a: { 2e38f, 0, 0 },
        translation_b: { 2e38f, 0, 0 },
    )) == c3d::UNSUPPORTED);
    assert(@catch(view.cast(
        pose_a: identity,
        other: view,
        pose_b: identity,
        translation_a: {},
        translation_b: { float::nan, 0, 0 },
    )) == c3d::INVALID_ARGUMENT);
    assert(@catch(view.time_of_impact(
        sweep_a: { .start = posed({ -float::max, 0, 0 }), .end = posed({ float::max, 0, 0 }) },
        other: view,
        sweep_b: { .start = posed({ -float::max, 0, 0 }), .end = posed({ float::max, 0, 0 }) },
    )) == c3d::UNSUPPORTED);

    foreach (direction : (Vec3[3]){ {}, { 2, 0, 0 }, { float::nan, 0, 0 } }) {
        assert(@catch(view.ray_cast(
            pose: identity,
            origin: { 2, 0, 0 },
            direction: direction,
            max_distance: 10,
        )) == c3d::INVALID_ARGUMENT);
    }
    assert(@catch(view.ray_cast(
        pose: identity,
        origin: { 2, 0, 0 },
        direction: { -1, 0, 0 },
        max_distance: float::max,
    )) == c3d::UNSUPPORTED);
    assert(@catch(view.ray_cast(
        pose: identity,
        origin: { 2, 0, 0 },
        direction: { -1, 0, 0 },
        max_distance: 0,
    )) == c3d::INVALID_ARGUMENT);
}

fn void test_prepared_query_repetition_does_not_allocate() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    int initial_native = b3::byte_count();

    {
        PreparedQueryFixture fixture;
        setup_prepared_queries(&fixture, &tracker);
        defer teardown_prepared_queries(&fixture);
        sz allocations = tracker.total_allocation_count();
        sz bytes = tracker.allocated();
        int native_bytes = b3::byte_count();

        CollisionShapeView view = fixture.owners[3].view();
        CollisionContact[4] contacts;
        for (uint iteration = 0; iteration < 16; iteration++) {
            assert(view.contacts(
                pose_a: posed({}),
                other: view,
                pose_b: posed({ 1.99f, 0, 0 }),
                output: &contacts,
            )!! > 0);
            view.distance(posed({}), view, posed({ 3, 0, 0 }))!!;
            view.cast(
                pose_a: posed({}),
                other: view,
                pose_b: posed({ 3, 0, 0 }),
                translation_a: {},
                translation_b: { -2, 0, 0 },
            )!!;
            view.time_of_impact(
                sweep_a: { .start = posed({}), .end = posed({}) },
                other: view,
                sweep_b: { .start = posed({ 3, 0, 0 }), .end = posed({ 1, 0, 0 }) },
            )!!;
            view.ray_cast(
                pose: posed({}),
                origin: { 3, 0, 0 },
                direction: { -1, 0, 0 },
                max_distance: 5,
            )!!;
            assert(@catch(view.contacts(
                pose_a: posed({}),
                other: view,
                pose_b: posed({}),
                output: {},
            )) == c3d::CAPACITY_EXCEEDED);
            assert(@catch(view.distance(posed({}), view, posed({ float::max, 0, 0 }))) == c3d::UNSUPPORTED);
        }

        assert(tracker.total_allocation_count() == allocations && tracker.allocated() == bytes);
        assert(b3::byte_count() == native_bytes);
    }

    assert(!tracker.has_leaks() && b3::byte_count() == initial_native);
}

fn void test_prepared_query_higher_order_arithmetic_keeps_control_results() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    int initial_native = b3::byte_count();

    {
        AssetStore assets = asset::create_asset_store(&tracker, asset::default_asset_store_desc());
        defer asset::destroy_asset_store(&assets);
        CollisionCache cache = physics::create_collision_cache(&tracker, &assets, { .snapshot_capacity = 0 })!!;
        defer physics::destroy_collision_cache(&cache)!!;

        foreach (half_height : (float[2]){ 1, 1e12f }) {
            CollisionShapeDesc desc = physics::default_collision_shape_desc(physics::ColliderKind.CAPSULE);
            desc.radius = 0.5f;
            desc.half_height = half_height;
            CollisionShape first = physics::create_collision_shape(&tracker, &cache, desc)!!;
            defer physics::destroy_collision_shape(&first);
            CollisionShape second = physics::create_collision_shape(&tracker, &cache, desc)!!;
            defer physics::destroy_collision_shape(&second);
            sz allocations = tracker.total_allocation_count();
            sz bytes = tracker.allocated();
            int native_bytes = b3::byte_count();

            foreach (separation : (float[2]){ 0.9f, 2 }) {
                maths::Transform pose_a = maths::TRANSFORM_IDENTITY;
                maths::Transform pose_b = maths::TRANSFORM_IDENTITY;
                pose_b.position.z = separation;
                pose_b.rotation = quaternion::from_axis_angle{float}({ 0, 0, 1 }, (float)math::PI / 2);
                Vec3 translation_a = { 0.25f, 0, 0 };
                Vec3 translation_b = { 0.25f, 0, -3 };
                collide::Sweep sweep_a = { .start = pose_a, .end = pose_a };
                collide::Sweep sweep_b = { .start = pose_b, .end = pose_b };
                sweep_a.end.position += translation_a;
                sweep_b.end.position += translation_b;

                CollisionContact[4] contacts;
                usz? count = first.view().contacts(
                    pose_a: pose_a,
                    other: second.view(),
                    pose_b: pose_b,
                    output: contacts[..],
                );
                collide::Distance? distance = first.view().distance(pose_a, second.view(), pose_b);
                collide::Impact? cast = first.view().cast(
                    pose_a: pose_a,
                    other: second.view(),
                    pose_b: pose_b,
                    translation_a: translation_a,
                    translation_b: translation_b,
                );
                collide::Impact? impact = first.view().time_of_impact(sweep_a, second.view(), sweep_b);
                collide::ShapeRayHit? ray = first.view().ray_cast(
                    pose: pose_a,
                    origin: { 0, 0, 2 },
                    direction: { 0, 0, -1 },
                    max_distance: 4,
                );

                if (half_height > 1) {
                    assert(@catch(count) == c3d::UNSUPPORTED);
                    assert(@catch(distance) == c3d::UNSUPPORTED);
                    assert(@catch(cast) == c3d::UNSUPPORTED);
                    assert(@catch(impact) == c3d::UNSUPPORTED);
                    assert(@catch(ray) == c3d::UNSUPPORTED);
                } else {
                    bool overlapping = separation < 1;
                    assert(count!! == (usz)(overlapping ? 1 : 0));
                    assert(near(distance!!.distance, overlapping ? 0 : 1, LOOSE));
                    assert(near(cast!!.time, overlapping ? 0 : 0.335f, LOOSE));
                    assert(near(impact!!.time, overlapping ? 0 : 0.335f, LOOSE));
                    assert(near(ray!!.fraction, 0.375f, LOOSE));
                    if (overlapping) {
                        assert(near(contacts[0].separation, -0.1f, LOOSE));
                        assert(near_vector(contacts[0].normal, { 0, 0, 1 }, LOOSE));
                        assert(cast!!.normal == (Vec3){});
                        assert(near_vector(impact!!.normal, { 0, 0, 1 }, LOOSE));
                    } else {
                        assert(near_vector(distance!!.point_a, { 0, 0, 0.5f }, LOOSE));
                        assert(near_vector(distance!!.point_b, { 0, 0, 1.5f }, LOOSE));
                        assert(near_vector(cast!!.normal, { 0, 0, 1 }, LOOSE));
                        assert(near_vector(impact!!.normal, { 0, 0, 1 }, LOOSE));
                    }
                }

                assert(tracker.total_allocation_count() == allocations && tracker.allocated() == bytes);
                assert(b3::byte_count() == native_bytes);
            }
        }
    }

    assert(!tracker.has_leaks() && b3::byte_count() == initial_native);
}

fn void test_prepared_query_off_centre_hulls_use_local_support_spans() @test {
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    CollisionCache cache = physics::create_collision_cache(mem, &assets, physics::default_collision_cache_desc())!!;
    defer physics::destroy_collision_cache(&cache)!!;

    GeometryId geometry;
    @pool() {
        Geometry box = geometry::box(
            allocator: tmem,
            width: 2,
            height: 2,
            depth: 2,
        );
        foreach (&point : box.positions) point.x += 1024;
        box.finalize();
        geometry = assets.add_geometry(&box)!!;
    };

    CollisionShapeDesc desc = physics::default_collision_shape_desc(physics::ColliderKind.HULL);
    desc.geometry = geometry;
    CollisionShape hull = physics::create_collision_shape(mem, &cache, desc)!!;
    defer physics::destroy_collision_shape(&hull);

    maths::Transform first = posed({ -1024, 0, 0 });
    maths::Transform second = posed({ 0, -1024, 0 });
    second.rotation = quaternion::from_axis_angle{float}({ 0, 0, 1 }, (float)math::PI / 2);
    assert(hull.view().distance(first, hull.view(), second)!!.distance == 0);

    second.position.z = 3;
    collide::Distance distance = hull.view().distance(first, hull.view(), second)!!;
    assert(near(distance.distance, 1, LOOSE));
    assert(near_vector(distance.normal, { 0, 0, 1 }, LOOSE));
}
