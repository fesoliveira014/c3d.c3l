module c3d::physics::fracture;

import std::math;

const uint FILTER_SWEEP_COUNT @local = 256;
const uint VERTEX_FILTER_SWEEP_COUNT @local = 16;

fn void test_exact_float_orientation_at_normal_and_extreme_scales() @test {
    FractureWorkspace workspace = predicate_workspace();
    defer destroy_fracture_workspace(&workspace);
    ExactScratch* scratch = (ExactScratch*)workspace.storage.ptr;
    foreach (float scale : { 1.0f, float::max, bitcast((uint)1, float) }) {
        Vec3[4] points = {
            { 0, 0, 0 }, { scale, 0, 0 }, { 0, scale, 0 }, { 0, 0, scale },
        };
        assert(exact_float_orientation(scratch, points)!! == 1);
        assert(float_orientation(scratch, points)!! == 1);
        points[1] = { 0, scale, 0 };
        points[2] = { scale, 0, 0 };
        assert(exact_float_orientation(scratch, points)!! == -1);
        assert(float_orientation(scratch, points)!! == -1);
        points[3] = { scale, scale, 0 };
        assert(exact_float_orientation(scratch, points)!! == 0);
        assert(float_orientation(scratch, points)!! == 0);
        points[0] = { -scale, 0, 0 };
        points[1] = { 0, 0, 0 };
        points[2] = { scale, 0, 0 };
        points[3] = { 0, 0, scale };
        assert(exact_float_orientation(scratch, points)!! == 0);
        assert(scratch.count == 0);
    }
    assert(scratch.peak == 17);
}

fn void test_exact_planes_preserve_winding_and_wide_float_coefficients() @test {
    FractureWorkspace workspace = predicate_workspace();
    defer destroy_fracture_workspace(&workspace);
    ExactScratch* scratch = (ExactScratch*)workspace.storage.ptr;
    ExactPlane first;
    ExactPlane second;
    assert(!plane_from_integers(scratch, &first, { 2, -4, 6, -8 })!!);
    assert(plane_from_integers(scratch, &second, { -2, 4, -6, 8 })!!);
    foreach (index, &coefficient : first.coefficients) {
        assert(coefficient.negative == second.coefficients[index].negative);
        assert(compare_magnitude(coefficient.view(), second.coefficients[index].view()) == 0);
    }
    float tiny = bitcast((uint)1, float);
    Vec3[4] points = {
        { float::max, tiny, 0 },
        { 0, -float::max, tiny },
        { -float::max / 2, 0, float::max },
        { tiny, float::max / 2, -float::max },
    };
    ExactPlane[4] faces;
    ExactPlane*[3][4] vertices;
    for (uint face = 0; face < 4; face++) {
        Vec3[3] triangle;
        uint next;
        for (uint vertex = 0; vertex < 4; vertex++) if (vertex != face) triangle[next++] = points[vertex];
        plane_from_float(scratch, &faces[face], triangle)!!;
        next = 0;
        for (uint other = 0; other < 4; other++) if (other != face) vertices[face][next++] = &faces[other];
    }
    assert(integer_bits(faces[3].coefficients[0].view()) > 500);
    assert(integer_bits(faces[3].coefficients[3].view()) > 800);
    int expected = exact_float_orientation(scratch, points)!!;
    assert(expected != 0 && exact_vertex_orientation(scratch, vertices)!! == expected);
    assert(vertex_orientation(scratch, vertices)!! == expected);
    assert(scratch.count == 0 && scratch.peak == 21);
    Vec3[3] collinear = { {}, { tiny, 0, 0 }, { -tiny, 0, 0 } };
    assert(@catch(plane_from_float(scratch, &second, collinear)) == NUMERICAL_FAILURE);
    assert(scratch.count == 0);
}

fn void test_exact_vertex_identity_compares_distinct_plane_triples_geometrically() @test {
    FractureWorkspace workspace = predicate_workspace();
    defer destroy_fracture_workspace(&workspace);
    ExactScratch* scratch = (ExactScratch*)workspace.storage.ptr;
    ExactPlane[5] planes;
    int128[4][5] coefficients = {
        { 2, 0, 0, -1 },
        { 0, 3, 0, -1 },
        { 0, 0, 5, -1 },
        { 6, 3, 0, -4 },
        { 2, 0, 0, -3 },
    };
    foreach (index, values : coefficients) plane_from_integers(scratch, &planes[index], values)!!;
    scratch.peak = 0;
    ExactPlane*[3] first_vertex = { &planes[0], &planes[1], &planes[2] };
    ExactPlane*[3] same_position = { &planes[3], &planes[1], &planes[2] };
    ExactPlane*[3] different_position = { &planes[4], &planes[1], &planes[2] };
    assert(exact_same_vertex(scratch, first_vertex, same_position)!!);
    assert(!exact_same_vertex(scratch, first_vertex, different_position)!!);
    assert(same_vertex(scratch, first_vertex, same_position)!!);
    assert(!same_vertex(scratch, first_vertex, different_position)!!);
    assert(scratch.count == 0 && scratch.peak == 11);
}

fn void test_exact_constructed_orientation_and_singular_triple_recovery() @test {
    FractureWorkspace workspace = predicate_workspace();
    defer destroy_fracture_workspace(&workspace);
    ExactScratch* scratch = (ExactScratch*)workspace.storage.ptr;
    ExactPlane[6] planes;
    int128[4][6] coefficients = {
        { 1, 0, 0, 0 }, { 0, 1, 0, 0 }, { 0, 0, 1, 0 },
        { 1, 0, 0, -1 }, { 0, 1, 0, -1 }, { 0, 0, 1, -1 },
    };
    foreach (index, values : coefficients) plane_from_integers(scratch, &planes[index], values)!!;
    scratch.peak = 0;
    ExactPlane*[3][4] vertices = {
        { &planes[0], &planes[1], &planes[2] },
        { &planes[3], &planes[1], &planes[2] },
        { &planes[0], &planes[4], &planes[2] },
        { &planes[0], &planes[1], &planes[5] },
    };
    assert(exact_vertex_orientation(scratch, vertices)!! == 1);
    assert(vertex_orientation(scratch, vertices)!! == 1);
    vertices[1] = { &planes[1], &planes[3], &planes[2] };
    assert(exact_vertex_orientation(scratch, vertices)!! == 1);
    assert(vertex_orientation(scratch, vertices)!! == 1);
    vertices[3] = { &planes[3], &planes[4], &planes[2] };
    assert(exact_vertex_orientation(scratch, vertices)!! == 0);
    assert(vertex_orientation(scratch, vertices)!! == 0);
    assert(scratch.count == 0 && scratch.peak == 20);
    ExactPlane*[3] parallel_planes = { &planes[0], &planes[3], &planes[2] };
    assert(@catch(exact_same_vertex(scratch, vertices[0], parallel_planes)) == NUMERICAL_FAILURE);
    assert(scratch.count == 0);
    assert(exact_same_vertex(scratch, vertices[0], vertices[0])!!);
}

fn void test_filtered_orientations_agree_with_exact_near_degenerate_sweep() @test {
    FractureWorkspace workspace = predicate_workspace();
    defer destroy_fracture_workspace(&workspace);
    ExactScratch* scratch = (ExactScratch*)workspace.storage.ptr;
    ulong sequence = 0x8365adbc982309e1;
    uint uncertain;
    for (uint sample = 0; sample < FILTER_SWEEP_COUNT; sample++) {
        sequence ^= sequence << 13;
        sequence ^= sequence >> 7;
        sequence ^= sequence << 17;
        long magnitude = (long)((sequence & 0x3fffff) | 0x100000);
        int perturbation = (int)(sample % 3) - 1;
        Vec3[4] points = {
            {},
            { (float)magnitude, (float)(magnitude - 1), (float)(magnitude - 2) },
            { (float)(magnitude - 1), (float)(magnitude - 2), (float)(magnitude - 3) },
            { (float)(magnitude - 2), (float)(magnitude - 3), (float)(magnitude - 4 + perturbation) },
        };
        int expected = -perturbation;
        if (sample & 1) {
            foreach (&point : points) *point = -*point;
            expected = -expected;
        }
        int exact = exact_float_orientation(scratch, points)!!;
        assert(exact == expected);
        int filtered = filter_float_orientation(points);
        if (filtered == FILTER_UNCERTAIN) {
            uncertain++;
        } else {
            assert(filtered == exact);
        }
        assert(float_orientation(scratch, points)!! == exact);
        GridPoint[4] grid_points;
        foreach (uint row, point : points) {
            for (uint axis = 0; axis < SPACE_AXES; axis++) grid_points[row][axis] = (long)point[axis];
        }
        assert(exact_grid_orientation(grid_points) == expected);
        assert(grid_orientation(scratch, grid_points) == expected);
        if (sample < VERTEX_FILTER_SWEEP_COUNT) {
            ExactPlane[3][4] planes;
            ExactPlane*[3][4] vertices;
            foreach (uint row, position : points) {
                for (uint axis = 0; axis < SPACE_AXES; axis++) {
                    Vec3[3] triangle;
                    foreach (&vertex : triangle) (*vertex)[axis] = position[axis];
                    triangle[1][(axis + 1) % SPACE_AXES] = 1;
                    triangle[2][(axis + 2) % SPACE_AXES] = 1;
                    plane_from_float(scratch, &planes[row][axis], triangle)!!;
                    vertices[row][axis] = &planes[row][axis];
                }
            }
            int exact_vertex = exact_vertex_orientation(scratch, vertices)!!;
            assert(exact_vertex == expected);
            int vertex_filter = filter_vertex_orientation(vertices);
            if (vertex_filter != FILTER_UNCERTAIN) assert(vertex_filter == exact_vertex);
            assert(vertex_orientation(scratch, vertices)!! == exact_vertex);
        }
    }
    assert(float_orientation(scratch, { {}, { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } })!! == 1);
    assert(grid_orientation(scratch, { {}, { 1, 1, 1 }, { 2, 2, 2 }, { 3, 3, 3 } }) == 0);
    $if env::COMPILER_OPT_LEVEL == O3:
    assert(uncertain == FILTER_SWEEP_COUNT && scratch.filtered_count == 0);
    $else
    assert(uncertain > 0 && scratch.filtered_count > 0);
    $endif
    assert(scratch.predicate_count == 2 * FILTER_SWEEP_COUNT + VERTEX_FILTER_SWEEP_COUNT + 2);
    assert(scratch.filtered_count < scratch.predicate_count && scratch.exact_nanoseconds > 0);
    assert(scratch.count == 0 && scratch.peak <= EXACT_TEMPORARIES);
}

fn void test_quantization_is_centered_nearest_even_and_bounded() @test {
    FractureWorkspace workspace = predicate_workspace();
    defer destroy_fracture_workspace(&workspace);
    ExactScratch* scratch = (ExactScratch*)workspace.storage.ptr;
    assert(grid_step_exponent(0.0001f) == -18 && grid_step_exponent(1.0f) == -4);
    assert(grid_step_exponent(float::max) == 123 && grid_step_exponent(bitcast((uint)1, float)) == -153);
    QuantizationGrid grid;
    GridPoint point = quantize_point(scratch, grid, { 0.5f, 1.5f, 2.5f })!!;
    assert(point[0] == 0 && point[1] == 2 && point[2] == 2);
    point = quantize_point(scratch, grid, { -0.5f, -1.5f, -2.5f })!!;
    assert(point[0] == 0 && point[1] == -2 && point[2] == -2);
    grid.center = { 1, 1, 1 };
    point = quantize_point(scratch, grid, { 2.5f, 3.5f, -0.5f })!!;
    assert(point[0] == 2 && point[1] == 2 && point[2] == -2);
    grid = { .step_exponent = -153 };
    float tiny = bitcast((uint)1, float);
    point = quantize_point(scratch, grid, { tiny, -tiny, 0 })!!;
    assert(point[0] == 16 && point[1] == -16 && point[2] == 0);
    grid = { .anchor = { 1, 1, 1 } };
    float boundary = (float)GRID_COORDINATE_LIMIT;
    point = quantize_point(scratch, grid, { boundary, boundary, boundary })!!;
    assert(point[0] == (long)(GRID_COORDINATE_LIMIT - 1));
    grid.anchor = { -1, -1, -1 };
    point = quantize_point(scratch, grid, { -boundary, -boundary, -boundary })!!;
    assert(point[0] == -(long)(GRID_COORDINATE_LIMIT - 1));
    grid.anchor = {};
    assert(@catch(quantize_point(scratch, grid, { boundary, 0, 0 })) == NUMERICAL_FAILURE);
    assert(@catch(quantize_point(scratch, grid, { -boundary, 0, 0 })) == NUMERICAL_FAILURE);
    grid = create_quantization_grid(
        scratch: scratch,
        lower: { -8, -8, -8 },
        upper: { 8, 8, 8 },
        resolution: 1,
    )!!;
    point = quantize_point(scratch, grid, {})!!;
    assert(point[0] == 0 && point[1] == 0 && point[2] == 0);
    assert(@catch(create_quantization_grid(
        scratch: scratch,
        lower: { -float::max, -float::max, -float::max },
        upper: { float::max, float::max, float::max },
        resolution: 0.0001f,
    )) == NUMERICAL_FAILURE);
    assert(scratch.count == 0 && scratch.peak == 9);
    ExactPlane plane;
    assert(!bisector_plane(
        scratch: scratch,
        output: &plane,
        first: {},
        second: { 1, 0, 0 },
    )!!);
    assert(plane.coefficients[0].limbs[0] == 2 && plane.coefficients[3].limbs[0] == 1);
    assert(plane.coefficients[3].negative);
    assert(bisector_plane(
        scratch: scratch,
        output: &plane,
        first: { 1, 0, 0 },
        second: {},
    )!!);
    assert(@catch(bisector_plane(
        scratch: scratch,
        output: &plane,
        first: {},
        second: {},
    )) == NUMERICAL_FAILURE);
    assert(!plane_from_grid(scratch, &plane, { {}, { 1, 0, 0 }, { 0, 1, 0 } })!!);
    assert(plane.coefficients[2].limbs[0] == 1 && plane.coefficients[3].used == 0);
}

fn FractureWorkspace predicate_workspace() @local {
    return create_fracture_workspace(mem, {
        .scratch_bytes = MIN_FRACTURE_SCRATCH_BYTES,
        .max_vertices = 64,
        .max_triangles = 64,
        .max_pieces = 8,
        .max_sites = 8,
        .max_hulls = 8,
        .resolution_m = 0.0001f,
    })!!;
}
