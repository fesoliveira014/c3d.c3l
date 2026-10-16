module c3d_physics_collide_test;

import c3d;
import std::io;
import std::math;
import std::math::quaternion;
import b3;

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
