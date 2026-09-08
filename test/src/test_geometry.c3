module c3d::test::geometry;

import c3d::geometry;
import c3d::maths;
import cg;
import std::math;

const float TOLERANCE @local = 0.0005f;

fn bool close(float first, float second) @local {
    return math::abs(first - second) <= TOLERANCE;
}

fn bool close_vec3(Vec3 first, Vec3 second) @local {
    return close(first.x, second.x) && close(first.y, second.y) && close(first.z, second.z);
}

fn void free_geometry(Geometry* geometry) @local {
    free(geometry.positions.ptr);
    free(geometry.normals.ptr);
    free(geometry.tangents.ptr);
    free(geometry.uv0.ptr);
    free(geometry.indices.ptr);
    *geometry = {};
}

fn Geometry make_quad(Allocator allocator) @local {
    Vec3[] positions = alloc::new_array(allocator, Vec3, 4);
    positions[0] = { 0, 0, 0 };
    positions[1] = { 1, 0, 0 };
    positions[2] = { 1, 1, 0 };
    positions[3] = { 0, 1, 0 };
    Vec2[] uv0 = alloc::new_array(allocator, Vec2, 4);
    foreach (index, position : positions) uv0[index] = { position.x, position.y };
    uint[] indices = alloc::new_array(allocator, uint, 6);
    indices[..] = (uint[6]){ 0, 1, 2, 0, 2, 3 }[..];
    return { .topology = Topology.TRIANGLES, .positions = positions, .uv0 = uv0, .indices = indices };
}

fn Vec3 triangle_normal(Geometry* geometry, usz triangle) @local {
    Vec3 a = geometry.positions[geometry.indices[triangle * 3]];
    Vec3 b = geometry.positions[geometry.indices[triangle * 3 + 1]];
    Vec3 c = geometry.positions[geometry.indices[triangle * 3 + 2]];
    return (b - a).cross(c - a).normalize();
}

fn void test_box_counts_bounds_and_outward_normals() @test {
    Geometry box = geometry::box(mem, 2, 4, 6);
    defer free_geometry(&box);

    assert(box.positions.len == 24 && box.indices.len == 36);
    assert(close_vec3(box.bounds.min, { -1, -2, -3 }) && close_vec3(box.bounds.max, { 1, 2, 3 }));
    foreach (index, normal : box.normals) {
        assert(close(normal.length(), 1));
        assert(normal.dot(box.positions[index]) > 0);
    }
    for (usz triangle = 0; triangle < 12; triangle++) {
        Vec3 face = triangle_normal(&box, triangle);
        assert(close_vec3(face, box.normals[box.indices[triangle * 3]]), "a box face winds inward");
    }
}

fn void test_plane_faces_up() @test {
    Geometry ground = geometry::plane(
        allocator:  mem,
        width:      2,
        depth:      2,
        segments_x: 2,
        segments_z: 2,
    );
    defer free_geometry(&ground);

    assert(ground.positions.len == 9 && ground.indices.len == 24);
    foreach (normal : ground.normals) assert(close_vec3(normal, { 0, 1, 0 }));
    assert(close_vec3(ground.bounds.min, { -1, 0, -1 }) && close_vec3(ground.bounds.max, { 1, 0, 1 }));
    assert(close_vec3(triangle_normal(&ground, 0), { 0, 1, 0 }), "the plane winds clockwise from above");
}

fn void test_sphere_points_lie_on_the_radius() @test {
    Geometry ball = geometry::sphere(mem, 3, 8, 4);
    defer free_geometry(&ball);

    assert(ball.positions.len == 45 && ball.indices.len == 192);
    foreach (index, position : ball.positions) {
        assert(close(position.length(), 3));
        assert(close_vec3(position, ball.normals[index] * 3));
    }
}

fn void test_cylinder_cone_torus_capsule_counts() @test {
    Geometry tube = geometry::cylinder(
        allocator:     mem,
        radius_top:    1,
        radius_bottom: 1,
        height:        2,
        slices:        8,
    );
    defer free_geometry(&tube);
    Geometry spike = geometry::cone(mem, 1, 2, 8);
    defer free_geometry(&spike);
    Geometry ring = geometry::torus(
        allocator: mem,
        radius:    2,
        tube:      0.5f,
        radial:    8,
        tubular:   4,
    );
    defer free_geometry(&ring);
    Geometry pill = geometry::capsule(
        allocator: mem,
        radius:    1,
        height:    2,
        slices:    8,
        stacks:    4,
    );
    defer free_geometry(&pill);

    assert(tube.positions.len == 2 * 9 + 2 * 10 && tube.indices.len == 6 * 8 + 2 * 3 * 8);
    assert(spike.positions.len == 2 * 9 + 10 && spike.indices.len == 6 * 8 + 3 * 8);
    assert(ring.positions.len == 9 * 5 && ring.indices.len == 6 * 8 * 4);
    assert(pill.positions.len == 9 * 6 && pill.indices.len == 6 * 8 * 5);
    assert(close_vec3(pill.bounds.min, { -1, -2, -1 }) && close_vec3(pill.bounds.max, { 1, 2, 1 }));
    for (usz triangle = 0; triangle < tube.indices.len / 3; triangle++) {
        Vec3 face = triangle_normal(&tube, triangle);
        Vec3 vertex_normal = tube.normals[tube.indices[triangle * 3]];
        assert(face.dot(vertex_normal) > 0, "a cylinder face winds inward");
    }
}

fn void test_compute_normals_smooth_averages_faces() @test {
    Vec3[] positions = mem::new_array(Vec3, 4);
    positions[0] = { 0, 0, 0 };
    positions[1] = { 1, 0, 0 };
    positions[2] = { 0, 1, 0 };
    positions[3] = { 0, 0, 1 };
    uint[] indices = mem::new_array(uint, 6);
    indices[..] = (uint[6]){ 0, 1, 2, 0, 2, 3 }[..];
    Geometry book = { .topology = Topology.TRIANGLES, .positions = positions, .indices = indices };
    defer free_geometry(&book);

    book.compute_normals(mem);

    Vec3 shared = ((Vec3){ 1, 0, 1 }).normalize();
    assert(close_vec3(book.normals[0], shared) && close_vec3(book.normals[2], shared));
    assert(close_vec3(book.normals[1], { 0, 0, 1 }));
    assert(close_vec3(book.normals[3], { 1, 0, 0 }));
}

fn void test_compute_normals_flat_needs_unindexed() @test {
    Geometry quad = make_quad(mem);
    Geometry indexed = quad;
    defer free_geometry(&indexed);

    quad.unindex(mem);
    defer free_geometry(&quad);
    quad.compute_normals(mem, false);

    assert(quad.positions.len == 6 && quad.indices.len == 0 && quad.uv0.len == 6);
    foreach (normal : quad.normals) assert(close_vec3(normal, { 0, 0, 1 }));
    foreach (slot, index : indexed.indices) {
        assert(close_vec3(quad.positions[slot], indexed.positions[index]));
    }
}

fn void test_compute_tangents_follow_u() @test {
    Geometry quad = make_quad(mem);
    defer free_geometry(&quad);
    quad.compute_normals(mem);
    quad.compute_tangents(mem);

    foreach (tangent : quad.tangents) {
        assert(close_vec3(tangent.xyz, { 1, 0, 0 }));
        assert(tangent.w == 1);
    }
}

fn void test_transform_moves_bounds_and_rotates_normals() @test {
    Geometry box = geometry::box(mem, 2, 2, 2);
    defer free_geometry(&box);
    box.compute_tangents(mem);
    Transform transform = {
        .position = { 1, 2, 3 },
        .rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, (float)math::PI / 2),
        .scale    = { 1, 1, 1 },
    };

    box.transform(transform.to_mat4());

    assert(close_vec3(box.bounds.min, { 0, 1, 2 }) && close_vec3(box.bounds.max, { 2, 3, 4 }));
    // The +X face is emitted first; a quarter turn about Y sends +X to -Z.
    assert(close_vec3(box.normals[0], { 0, 0, -1 }));
    assert(close_vec3(box.tangents[0].xyz, { -1, 0, 0 }));
}

fn void test_flip_winding_reverses_triangles() @test {
    Geometry quad = make_quad(mem);
    defer free_geometry(&quad);
    quad.flip_winding();
    assert(quad.indices[0] == 0 && quad.indices[1] == 2 && quad.indices[2] == 1);
    assert(quad.indices[3] == 0 && quad.indices[4] == 3 && quad.indices[5] == 2);

    Geometry soup = make_quad(mem);
    Geometry soup_indexed = soup;
    defer free_geometry(&soup_indexed);
    soup.unindex(mem);
    defer free_geometry(&soup);
    Vec3 second = soup.positions[1];
    Vec3 third = soup.positions[2];
    soup.flip_winding();
    assert(close_vec3(soup.positions[1], third) && close_vec3(soup.positions[2], second));
}

fn void test_merge_rebases_indices_and_drops_partial_streams() @test {
    Geometry box = geometry::box(mem, 1, 1, 1);
    defer free_geometry(&box);
    Geometry ground = geometry::plane(mem, 1, 1);
    defer free_geometry(&ground);
    free(ground.uv0.ptr);
    ground.uv0 = {};
    Geometry soup = make_quad(mem);
    Geometry soup_indexed = soup;
    defer free_geometry(&soup_indexed);
    soup.unindex(mem);
    defer free_geometry(&soup);
    soup.compute_normals(mem, false);

    Geometry[3] parts = { box, ground, soup };
    Geometry merged = geometry::merge(mem, parts[..]);
    defer free_geometry(&merged);

    assert(merged.positions.len == 24 + 4 + 6);
    assert(merged.indices.len == 36 + 6 + 6);
    assert(merged.normals.len == merged.positions.len);
    assert(merged.uv0.len == 0);
    assert(merged.indices[36] == 24 + ground.indices[0]);
    assert(merged.indices[42] == 28 && merged.indices[47] == 33);
    assert(close_vec3(merged.positions[24], ground.positions[0]));
}

fn void test_icosphere_counts_and_normals() @test {
    Geometry rock = geometry::icosphere(mem, 2, 1)!!;
    defer free_geometry(&rock);

    assert(rock.positions.len == 42 && rock.indices.len == 240);
    foreach (index, position : rock.positions) {
        assert(close(position.length(), 2));
        assert(close_vec3(rock.normals[index], position / 2));
    }
}

fn void test_half_edge_round_trip() @test {
    Geometry box = geometry::box(mem, 1, 1, 1);
    defer free_geometry(&box);
    cg::HalfEdgeMesh mesh = geometry::to_half_edge(mem, &box)!!;
    defer mesh.destroy();
    assert(mesh.faces.len == 12);

    Vec3 first_position;
    usz smooth_vertices;
    usz flat_vertices;
    @pool() {
        Geometry smooth = geometry::from_half_edge(tmem, &mesh)!!;
        Geometry flat = geometry::from_half_edge(tmem, &mesh, smooth_normals: false)!!;
        smooth_vertices = smooth.positions.len;
        flat_vertices = flat.positions.len;
        first_position = smooth.positions[0];
        assert(smooth.indices.len == 36);
        foreach (index, position : smooth.positions) assert(close_vec3(position, box.positions[index]));
    };
    assert(smooth_vertices == 24 && flat_vertices == 36);
    assert(close_vec3(first_position, box.positions[0]));
}
