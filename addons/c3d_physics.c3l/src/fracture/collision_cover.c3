module c3d::physics::fracture;

import c3d;
import std::math;
import std::time;

const uint COLLISION_COVERAGE_BITS @private = 874;
$assert COLLISION_COVERAGE_BITS <= PLANE_LIMBS * INTEGER_LIMB_BITS;

fn PlaneInteger? collision_point_coverage_bound(
    ExactScratch* scratch,
    Vec3[] positions,
    uint[] indices,
    float resolution,
) @private {
    std::time::Clock started = begin_exact_measurement(scratch);
    defer finish_exact_measurement(scratch, started);
    uint saved = scratch.count;
    defer scratch.count = saved;

    WideInteger* cross_sum = scratch.take()!;
    WideInteger* widths = scratch.take()!;
    WideInteger*[SPACE_AXES] first_edge;
    WideInteger*[SPACE_AXES] second_edge;
    foreach (&coordinate : first_edge) *coordinate = scratch.take()!;
    foreach (&coordinate : second_edge) *coordinate = scratch.take()!;
    WideInteger* first = scratch.take()!;
    WideInteger* second = scratch.take()!;

    for (uint axis = 0; axis < SPACE_AXES; axis++) {
        uint low;
        uint high;
        foreach (uint vertex, point : positions) {
            if (compare_collision_positions((Vec3){ point[axis], 0, 0 }, { positions[low][axis], 0, 0 }) < 0) low = vertex;
            if (compare_collision_positions((Vec3){ point[axis], 0, 0 }, { positions[high][axis], 0, 0 }) > 0) high = vertex;
        }

        integer_from_float(first, positions[high][axis]);
        integer_from_float(second, positions[low][axis]);
        add_integer(first_edge[0], first.view(), negate_integer(second.view()))!;
        add_integer(widths, widths.view(), first_edge[0].view())!;
    }

    for (usz corner = 0; corner < indices.len; corner += TRIANGLE_CORNERS) {
        for (uint axis = 0; axis < SPACE_AXES; axis++) {
            integer_from_float(first, positions[indices[corner]][axis]);
            integer_from_float(second, positions[indices[corner + 1]][axis]);
            add_integer(first_edge[axis], second.view(), negate_integer(first.view()))!;
            integer_from_float(second, positions[indices[corner + 2]][axis]);
            add_integer(second_edge[axis], second.view(), negate_integer(first.view()))!;
        }

        for (uint axis = 0; axis < SPACE_AXES; axis++) {
            uint next = (axis + 1) % SPACE_AXES;
            uint last = (axis + 2) % SPACE_AXES;
            multiply_integer(first, first_edge[next].view(), second_edge[last].view())!;
            multiply_integer(second, first_edge[last].view(), second_edge[next].view())!;
            add_integer(first, first.view(), negate_integer(second.view()))!;
            first.negative = false;
            add_integer(cross_sum, cross_sum.view(), first.view())!;
        }
    }

    scratch.count = saved + 2;
    WideInteger* epsilon = scratch.take()!;
    WideInteger* scale = scratch.take()!;
    first = scratch.take()!;
    second = scratch.take()!;
    WideInteger* bound = scratch.take()!;
    integer_from_float(epsilon, resolution);

    set_integer(scale, 3);
    multiply_integer(first, cross_sum.view(), epsilon.view())!;
    multiply_integer(bound, first.view(), scale.view())!;

    multiply_integer(first, epsilon.view(), epsilon.view())!;
    multiply_integer(second, first.view(), widths.view())!;
    set_integer(scale, 24);
    multiply_integer(first, second.view(), scale.view())!;
    add_integer(bound, bound.view(), first.view())!;

    multiply_integer(first, epsilon.view(), epsilon.view())!;
    multiply_integer(second, first.view(), epsilon.view())!;
    set_integer(scale, 48);
    multiply_integer(first, second.view(), scale.view())!;
    add_integer(bound, bound.view(), first.view())!;
    if (bound.used > PLANE_LIMBS) return NUMERICAL_FAILURE~;

    PlaneInteger result = { .used = bound.used };
    result.limbs[:bound.used] = bound.limbs[:bound.used];
    return result;
}

fn PlaneInteger? collision_coverage_bound(SolidSurface* surface, float resolution) @private {
    return collision_point_coverage_bound(
        scratch: surface.exact,
        positions: surface.source.geometry.positions,
        indices: surface.source.geometry.indices,
        resolution: resolution,
    );
}

fn PlaneInteger? collision_tetrahedron_volume(
    ExactScratch* scratch,
    Vec3[HOMOGENEOUS_COMPONENTS] points,
) @private {
    std::time::Clock started = begin_exact_measurement(scratch);
    defer finish_exact_measurement(scratch, started);
    uint saved = scratch.count;
    defer scratch.count = saved;

    WideInteger*[SPACE_AXES * SPACE_AXES] edges;
    foreach (&edge : edges) *edge = scratch.take()!;
    WideInteger* first = scratch.take()!;
    WideInteger* second = scratch.take()!;
    IntegerView[SPACE_AXES * SPACE_AXES] matrix;

    for (uint row = 0; row < SPACE_AXES; row++) {
        for (uint axis = 0; axis < SPACE_AXES; axis++) {
            uint index = row * SPACE_AXES + axis;
            integer_from_float(first, points[row + 1][axis]);
            integer_from_float(second, points[0][axis]);
            add_integer(edges[index], first.view(), negate_integer(second.view()))!;
            matrix[index] = edges[index].view();
        }
    }

    WideInteger* volume = scratch.take()!;
    determinant(scratch: scratch, output: volume, matrix: matrix[..], order: SPACE_AXES)!;
    if (!volume.used || volume.negative || volume.used > PLANE_LIMBS) return NUMERICAL_FAILURE~;

    PlaneInteger result = { .used = volume.used };
    result.limbs[:volume.used] = volume.limbs[:volume.used];
    return result;
}

fn void? add_collision_volume(ExactScratch* scratch, PlaneInteger* total, PlaneInteger value) @private {
    uint saved = scratch.count;
    defer scratch.count = saved;

    WideInteger* sum = scratch.take()!;
    add_integer(sum, total.view(), value.view())!;
    if (sum.used > PLANE_LIMBS) return NUMERICAL_FAILURE~;

    *total = { .used = sum.used, .negative = sum.negative };
    total.limbs[:sum.used] = sum.limbs[:sum.used];
    return;
}

fn void? check_collision_cover(
    ExactScratch* scratch,
    PlaneInteger hull_volume,
    PlaneInteger source_volume,
    PlaneInteger missing_bound,
    PlaneInteger excess_bound,
) @private {
    uint saved = scratch.count;
    defer scratch.count = saved;

    WideInteger* difference = scratch.take()!;
    add_integer(difference, hull_volume.view(), negate_integer(source_volume.view()))!;
    IntegerView limit = difference.negative ? missing_bound.view() : excess_bound.view();
    if (compare_magnitude(difference.view(), limit) > 0) return NUMERICAL_FAILURE~;
    return;
}

fn void? validate_collision_hull(SolidSurface* surface) @private {
    foreach (uint face, unused : surface.topology.shell_roots) {
        uint[TRIANGLE_CORNERS] triangle = surface_triangle(surface, face);
        Vec3[HOMOGENEOUS_COMPONENTS] points;
        foreach (corner, vertex : triangle) points[corner] = surface_position(surface, vertex);

        foreach (uint vertex, unused_vertex : surface.topology.vertices) {
            points[TRIANGLE_CORNERS] = surface_position(surface, vertex);
            if (float_orientation(surface.exact, points)! > 0) return NUMERICAL_FAILURE~;
        }
    }

    return;
}
