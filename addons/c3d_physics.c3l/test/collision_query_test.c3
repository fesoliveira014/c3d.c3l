module c3d_physics_collide_test;

import c3d;
import std::core::mem::allocators;
import std::io;
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

fn void test_native_query_hull_admission_preserves_native_body_geometry() @test {
    @pool() {
        int initial_bytes = b3::byte_count();
        {
            b3::WorldDef world_desc = b3::default_world_def();
            b3::WorldId world = b3::create_world(&world_desc)!!;
            defer b3::destroy_world(world);
            foreach (sides : (uint[2]){ 32, 33 }) {
                b3::HullData* hull = b3::create_hull(query_prism_points(sides), b3::MAX_HULL_VERTICES)!!;
                defer b3::destroy_hull(hull);
                uint face_vertices = query_max_face_vertices(hull);
                assert(face_vertices == sides && (uint)hull.vertex_count == 2 * sides);
                fault result = @catch(query_hull_admission(hull));
                assert(result == (sides == QUERY_FACE_VERTICES ? (fault){} : c3d::CAPACITY_EXCEEDED));
                b3::BodyDef body_desc = b3::default_body_def();
                b3::BodyId body = b3::create_body(world, &body_desc)!!;
                defer b3::destroy_body(body);
                b3::ShapeDef shape_desc = b3::default_shape_def();
                b3::ShapeId shape = b3::create_hull_shape(body, &shape_desc, hull)!!;
                assert(shape.is_valid() && shape.hull()!! != hull);
                assert(query_max_face_vertices(shape.hull()!!) == sides);
                io::printfn(
                    "hull,vertices=%d,max_face=%d,admitted=%s",
                    hull.vertex_count,
                    face_vertices,
                    !result,
                );
            }
        }
        assert(b3::byte_count() == initial_bytes);
    };
}

fn void test_native_query_triangle_contacts_exceed_four_without_overwriting_scratch() @test {
    @pool() {
        b3::HullData* hull = b3::create_hull(query_prism_points(8), b3::MAX_HULL_VERTICES)!!;
        defer b3::destroy_hull(hull);
        query_hull_admission(hull)!!;
        b3::Triangle triangle = { { -2, 0, -2 }, { 0, 0, 2 }, { 2, 0, -2 } };
        QueryContactScratch full = {
            .before = { QUERY_CANARY, QUERY_CANARY },
            .after = { QUERY_CANARY, QUERY_CANARY },
        };
        QueryShortScratch short_buffer = {
            .before = { QUERY_CANARY, QUERY_CANARY },
            .after = { QUERY_CANARY, QUERY_CANARY },
        };
        b3::CollisionManifoldView complete = b3::collide_triangle_and_hull(
            triangle: &triangle,
            hull: hull,
            enable_speculative: true,
            buffer: full.points[..],
        )!!;
        b3::CollisionManifoldView truncated = b3::collide_triangle_and_hull(
            triangle: &triangle,
            hull: hull,
            enable_speculative: true,
            buffer: short_buffer.points[..],
        )!!;
        assert(complete.points.len > 4 && complete.points.len <= (sz)(query_max_face_vertices(hull) + 3));
        assert(truncated.points.len == 4 && near_vector(complete.normal, truncated.normal));
        foreach (index, point : truncated.points) {
            assert(near_vector(point.point, complete.points[index].point));
            assert(near(point.separation, complete.points[index].separation));
        }
        foreach (value : full.before) assert(value == QUERY_CANARY);
        foreach (value : full.after) assert(value == QUERY_CANARY);
        foreach (value : short_buffer.before) assert(value == QUERY_CANARY);
        foreach (value : short_buffer.after) assert(value == QUERY_CANARY);
        io::printfn(
            "triangle_contacts,complete=%d,four_slot=%d,normal=%s",
            complete.points.len,
            truncated.points.len,
            complete.normal,
        );
    };
}

fn void test_native_query_scale_clamp_and_reflected_winding() @test {
    assert(b3::length_units_per_meter() == 1);
    float below = bitcast(bitcast(QUERY_MIN_SCALE, uint) - 1, float);
    assert(@ok(query_scale_admission({ QUERY_MIN_SCALE, 1, -2 })));
    assert(@catch(query_scale_admission({ below, 1, -2 })) == c3d::UNSUPPORTED);
    assert(@catch(query_scale_admission({ 0, 1, 1 })) == c3d::INVALID_ARGUMENT);
    assert(@catch(query_scale_admission({ float::nan, 1, 1 })) == c3d::INVALID_ARGUMENT);
    b3::BoxHull base = b3::make_cube_hull(1);
    foreach (requested : (float[2]){ QUERY_MIN_SCALE, below }) {
        b3::HullData* transformed = b3::clone_and_transform_hull(
            hull: &base.base,
            transform: QUERY_IDENTITY,
            scale: { requested, 0.5f, -2 },
        )!!;
        defer b3::destroy_hull(transformed);
        assert(near(transformed.aabb.upper_bound.x, QUERY_MIN_SCALE, 1e-7f));
        assert(near(transformed.aabb.lower_bound.x, -QUERY_MIN_SCALE, 1e-7f));
        assert(near(transformed.volume, 0.08f) && transformed.volume > 0);
        b3::RayCastInput ray = { .origin = { 0, 0, 3 }, .translation = { 0, 0, -6 }, .max_fraction = 1 };
        b3::CastOutput ray_hit = b3::ray_cast_hull(transformed, ray)!!;
        assert(near(ray_hit.fraction, 1.0f / 6) && near_vector(ray_hit.normal, { 0, 0, 1 }));
    }

    QuerySurfaceFixture fixture = query_surface_fixture(4);
    b3::MeshData* data = query_surface_mesh(&fixture);
    defer b3::destroy_mesh(data);
    b3::Mesh mesh = { .data = data, .scale = { -1, 1, 2 } };
    QueryTriangleObservation observation;
    b3::query_mesh(
        mesh: &mesh,
        bounds: data.compute_aabb(QUERY_IDENTITY, mesh.scale),
        fcn: &query_observe_triangle,
        context: &observation,
    );
    assert(observation.count == fixture.triangle_count);
    b3::RayCastInput ray = { .origin = { -1.25f, 2, 2.5f }, .translation = { 0, -4, 0 }, .max_fraction = 1 };
    b3::CastOutput hit = b3::ray_cast_mesh(&mesh, ray)!!;
    assert(near(hit.fraction, 0.5f) && near_vector(hit.normal, { 0, 1, 0 }));
    b3::WorldDef world_desc = b3::default_world_def();
    b3::WorldId world = b3::create_world(&world_desc)!!;
    defer b3::destroy_world(world);
    b3::BodyDef body_desc = b3::default_body_def();
    b3::BodyId body = b3::create_body(world, &body_desc)!!;
    b3::ShapeDef shape_desc = b3::default_shape_def();
    b3::ShapeId shape = b3::create_mesh_shape(
        body: body,
        def: &shape_desc,
        mesh: data,
        scale: { below, 1, 1 },
    )!!;
    assert(shape.mesh()!!.scale.x == QUERY_MIN_SCALE);
    io::printfn(
        "scale,boundary=%.9g,below=%.9g,reflected_triangles=%d",
        QUERY_MIN_SCALE,
        below,
        observation.count,
    );
}

fn void test_native_query_tree_height_and_surface_ray_boundaries() @test {
    foreach (side : (uint[2]){ 2, QUERY_GRID_SIDE }) {
        QuerySurfaceFixture fixture = query_surface_fixture(side);
        b3::MeshData* mesh = query_surface_mesh(&fixture);
        defer b3::destroy_mesh(mesh);
        int height = mesh.tree_height();
        assert(side == 2 ? height == 0 : height > 0);
        query_depth_admission(height)!!;
        io::printfn(
            "mesh_depth,side=%d,triangles=%d,height=%d",
            side,
            fixture.triangle_count,
            height,
        );
    }
    query_depth_admission(256)!!;
    assert(@catch(query_depth_admission(257)) == c3d::CAPACITY_EXCEEDED);
    QuerySurfaceFixture fixture = query_surface_fixture(4);
    b3::MeshData* data = query_surface_mesh(&fixture);
    defer b3::destroy_mesh(data);
    Vec3 scale = { 2, 3, 4 };
    b3::Mesh mesh = { .data = data, .scale = scale };
    b3::HeightFieldData* field = query_surface_field(&fixture, scale);
    defer b3::destroy_height_field(field);
    b3::Aabb bounds = field.compute_aabb(QUERY_IDENTITY);
    assert(bounds.upper_bound == (Vec3){ 6, 0, 12 });
    b3::RayCastInput[5] rays = {
        { .origin = { 1.25f, 2, 1.5f }, .translation = { 0, -4, 0 }, .max_fraction = 1 },
        { .origin = { 1.25f, -2, 1.5f }, .translation = { 0, 4, 0 }, .max_fraction = 1 },
        { .origin = { 1.25f, 0, 1.5f }, .translation = { 0, -4, 0 }, .max_fraction = 1 },
        { .origin = { 1.25f, 2, 1.5f }, .translation = { 0, -2, 0 }, .max_fraction = 1 },
        { .origin = { 1.25f, 0, 1.5f }, .translation = { 1, 0, 0 }, .max_fraction = 1 },
    };
    foreach (index, ray : rays) {
        if (index == 0) {
            b3::CastOutput mesh_hit = b3::ray_cast_mesh(&mesh, ray)!!;
            b3::CastOutput field_hit = b3::ray_cast_height_field(field, ray)!!;
            assert(near(mesh_hit.fraction, 0.5f) && near(field_hit.fraction, 0.5f));
            assert(near_vector(mesh_hit.normal, { 0, 1, 0 }) && near_vector(field_hit.normal, { 0, 1, 0 }));
        } else {
            assert(@catch(b3::ray_cast_mesh(&mesh, ray)) == b3::NO_HIT);
            assert(@catch(b3::ray_cast_height_field(field, ray)) == b3::NO_HIT);
        }
    }
    io::printn("surface_rays,front=hit,back=miss,start_on=miss,exact_end=miss,coplanar=miss");
}

fn void test_native_query_relative_cast_witness_and_closing_band() @test {
    QuerySurfaceFixture fixture = query_surface_fixture(4);
    b3::MeshData* data = query_surface_mesh(&fixture);
    defer b3::destroy_mesh(data);
    b3::Mesh mesh = { .data = data, .scale = { 1, 1, 1 } };
    b3::HeightFieldData* field = query_surface_field(&fixture);
    defer b3::destroy_height_field(field);
    Quat rotation = quaternion::from_axis_angle((Vec3){ 0, 0, 1 }, (float)math::PI / 2);
    Vec3 position = { 5, 2, -3 };
    Vec3 start = { 1.25f, 1, 1.5f };
    Vec3 relative = { 0, -2, 0 };
    float radius = 0.25f;
    float target = radius - LINEAR_SLOP;
    float expected_fraction = (start.y - target) / -relative.y;
    Vec3 normal = rotation.rotate_vec3({ 0, 1, 0 });
    Vec3[3] surface_moves = { {}, -relative, { 0.5f, 0.25f, -0.75f } };
    foreach (use_field : (bool[2]){ false, true }) {
        foreach (surface_move : surface_moves) {
            Vec3 translation_a = rotation.rotate_vec3(surface_move);
            Vec3 translation_b = rotation.rotate_vec3(surface_move + relative);
            b3::ShapeCastInput input = {
                .proxy = { .points = &start, .count = 1, .radius = radius },
                .translation = rotation.conjugate().rotate_vec3(translation_b - translation_a),
                .max_fraction = 1,
            };
            b3::CastOutput hit = use_field
              ? b3::shape_cast_height_field(field, input)!! : b3::shape_cast_mesh(&mesh, input)!!;
            assert(near(hit.fraction, expected_fraction, LOOSE));
            Vec3 world_point = position + rotation.rotate_vec3(hit.point) + translation_a * hit.fraction;
            Vec3 plane_at_hit = position + translation_a * hit.fraction;
            Vec3 center_at_hit = position + rotation.rotate_vec3(start) + translation_b * hit.fraction;
            assert(near((world_point - plane_at_hit).dot(normal), 0));
            assert(near((center_at_hit - plane_at_hit).dot(normal), target, LOOSE));
            assert(near_vector(rotation.rotate_vec3(hit.normal), normal));
            io::printfn(
                "relative_cast,field=%s,time=%.6f,surface_move=%s,witness=%s",
                use_field,
                hit.fraction,
                surface_move,
                world_point,
            );
        }
        Vec3 touching = { 1.25f, radius, 1.5f };
        b3::ShapeCastInput input = {
            .proxy = { .points = &touching, .count = 1, .radius = radius },
            .translation = relative,
            .max_fraction = 1,
        };
        b3::CastOutput touch = use_field
          ? b3::shape_cast_height_field(field, input)!! : b3::shape_cast_mesh(&mesh, input)!!;
        assert(touch.fraction > 0 && near(touch.fraction, LINEAR_SLOP / -relative.y, LOOSE));
        touching.y = target;
        b3::CastOutput initial = use_field
          ? b3::shape_cast_height_field(field, input)!! : b3::shape_cast_mesh(&mesh, input)!!;
        assert(initial.fraction == 0 && initial.normal == (Vec3){});
        io::printfn(
            "closing_band,field=%s,touch_time=%.6f,initial_time=%.6f",
            use_field,
            touch.fraction,
            initial.fraction,
        );
    }
}

fn void test_native_query_numeric_admission_precedes_unsafe_native_inputs() @test {
    float largest_cell = 2147483520;
    float outside_cell = 2147483648;
    query_cell_admission(largest_cell, 1)!!;
    query_cell_admission((float)int::min, 1)!!;
    assert(@catch(query_cell_admission(outside_cell, 1)) == c3d::UNSUPPORTED);
    float below_minimum = bitcast(bitcast((float)int::min, uint) + 1, float);
    assert(@catch(query_cell_admission(below_minimum, 1)) == c3d::UNSUPPORTED);
    assert(@catch(query_cell_admission(float::max, QUERY_MIN_SCALE)) == c3d::UNSUPPORTED);
    assert(@catch(query_positive_quantity((double)float::max * 2)) == b3::DEGENERATE_GEOMETRY);
    float smallest = bitcast(1u, float);
    assert(@catch(query_positive_quantity((double)smallest * 0.5)) == b3::DEGENERATE_GEOMETRY);
    assert(query_positive_quantity((double)QUERY_MIN_SCALE * QUERY_MIN_SCALE)!! > 0);

    float extent = 0.25f;
    float lower = -2 * extent - QUERY_AABB_MARGIN;
    float upper = 3 + 2 * extent + QUERY_AABB_MARGIN;
    query_cell_admission(lower, 1)!!;
    query_cell_admission(upper, 1)!!;
    assert(@catch(query_cell_admission(upper, 1e-20f)) == c3d::UNSUPPORTED);
    assert(@catch(query_relative_component(float::max, -float::max)) == c3d::UNSUPPORTED);
    assert(query_relative_component(9, 4)!! == 5);
    io::printfn(
        "numeric_domain,last_positive_cell=%.0f,first_invalid_cell=%.0f,cast_range=[%.2f,%.2f]",
        largest_cell,
        outside_cell,
        lower,
        upper,
    );
}

fn void setup_prepared_queries(PreparedQueryFixture* fixture, Allocator allocator = mem) @private {
    fixture.assets = asset::create_asset_store(allocator, asset::default_asset_store_desc());
    fixture.cache = physics::create_collision_cache(allocator, &fixture.assets, physics::default_collision_cache_desc())!!;
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
