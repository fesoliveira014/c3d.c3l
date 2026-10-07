module c3d::physics::fracture;

import std::math;
import std::time;

const uint WITNESS_FLOAT_BITS @local = 277;
const uint WITNESS_NUMERATOR_BITS @local = 1953;
const uint WITNESS_DENOMINATOR_BITS @local = 1674;
const uint WITNESS_DELTA_BITS @local = WITNESS_NUMERATOR_BITS + 1;
const uint WITNESS_EDGE_BITS @local = WITNESS_FLOAT_BITS + 1;
const uint WITNESS_NORMAL_BITS @local = 2 * WITNESS_EDGE_BITS + 1;
const uint WITNESS_SEGMENT_BITS @local = 2 * WITNESS_DELTA_BITS + 2 * WITNESS_EDGE_BITS + 5;
const uint WITNESS_BARYCENTRIC_BITS @local = WITNESS_DELTA_BITS + WITNESS_EDGE_BITS + WITNESS_NORMAL_BITS + 4;
const uint WITNESS_RADIUS_BITS @local = 2 * (WITNESS_FLOAT_BITS + WITNESS_DENOMINATOR_BITS);
const uint COLLISION_WITNESS_BITS @private = 2 * (WITNESS_DELTA_BITS + WITNESS_NORMAL_BITS + 2);
const uint COLLISION_WITNESS_TEMPORARIES @private = 5 + 9 + 3 + 2 + 2 + 3;

$assert WITNESS_NUMERATOR_BITS >= WITNESS_FLOAT_BITS + WITNESS_DENOMINATOR_BITS;
$assert 2 * WITNESS_NUMERATOR_BITS + WITNESS_DENOMINATOR_BITS + 3 == PROJECTED_ORIENTATION_BITS;
$assert WITNESS_SEGMENT_BITS <= COLLISION_WITNESS_BITS && WITNESS_BARYCENTRIC_BITS <= COLLISION_WITNESS_BITS;
$assert WITNESS_RADIUS_BITS + 2 * WITNESS_NORMAL_BITS + 2 <= COLLISION_WITNESS_BITS;
$assert COLLISION_WITNESS_BITS == 5026 && COLLISION_WITNESS_BITS <= EXACT_LIMBS * INTEGER_LIMB_BITS;
$assert COLLISION_WITNESS_TEMPORARIES == 24 && COLLISION_WITNESS_TEMPORARIES <= EXACT_TEMPORARIES;

struct CollisionWitnessQuery @local {
    HomogeneousPoint point;
    WideInteger* radius_squared;
}

<*
 @require hull.points.len >= COLLISION_TETRAHEDRON_VERTICES
 @require hull.indices.len >= 12 && hull.indices.len % TRIANGLE_CORNERS == 0
*>
fn bool? collision_vertex_has_witness(
    ExactScratch* scratch,
    PlaneTriple vertex,
    CollisionHullSurface* hull,
    float resolution,
) @private {
    uint saved = scratch.count;
    defer scratch.count = saved;
    CollisionWitnessQuery query = create_collision_witness_query(scratch, vertex, resolution)!;

    foreach (point : hull.points) {
        if (collision_point_witness(scratch, query, point)!) return true;
    }

    for (usz face = 0; face < hull.indices.len; face += TRIANGLE_CORNERS) {
        uint[] triangle = hull.indices[face:TRIANGLE_CORNERS];
        for (uint corner = 0; corner < TRIANGLE_CORNERS; corner++) {
            uint first = triangle[corner];
            uint second = triangle[(corner + 1) % TRIANGLE_CORNERS];
            if (first >= second) continue;

            if (collision_segment_witness(
                scratch: scratch,
                query: query,
                first: hull.points[first],
                second: hull.points[second],
            )!) return true;
        }
    }

    bool inside = true;
    for (usz face = 0; face < hull.indices.len; face += TRIANGLE_CORNERS) {
        uint[] triangle = hull.indices[face:TRIANGLE_CORNERS];
        int side;
        if (collision_triangle_witness(
            scratch: scratch,
            query: query,
            triangle: { hull.points[triangle[0]], hull.points[triangle[1]], hull.points[triangle[2]] },
            side: &side,
        )!) return true;
        inside &= side <= 0;
    }
    return inside;
}

fn CollisionWitnessQuery? create_collision_witness_query(
    ExactScratch* scratch,
    PlaneTriple vertex,
    float resolution,
) @local {
    std::time::Clock started = begin_exact_measurement(scratch);
    defer finish_exact_measurement(scratch, started);
    uint saved = scratch.count;
    defer catch scratch.count = saved;

    CollisionWitnessQuery query;
    foreach (&coordinate : query.point) *coordinate = scratch.take()!;
    construct_point(scratch, query.point, vertex)!;
    query.radius_squared = scratch.take()!;

    WideInteger* epsilon = scratch.take()!;
    WideInteger* radius = scratch.take()!;
    integer_from_float(epsilon, resolution);
    multiply_integer(radius, epsilon.view(), query.point[SPACE_AXES].view())!;
    multiply_integer(query.radius_squared, radius.view(), radius.view())!;
    scratch.count = saved + HOMOGENEOUS_COMPONENTS + 1;
    return query;
}

fn bool? collision_point_witness(ExactScratch* scratch, CollisionWitnessQuery query, Vec3 point) @local {
    std::time::Clock started = begin_exact_measurement(scratch);
    defer finish_exact_measurement(scratch, started);
    uint saved = scratch.count;
    defer scratch.count = saved;

    WideInteger* coordinate = scratch.take()!;
    WideInteger* difference = scratch.take()!;
    WideInteger* distance_squared = scratch.take()!;
    for (uint axis = 0; axis < SPACE_AXES; axis++) {
        integer_from_float(coordinate, point[axis]);
        multiply_integer(difference, coordinate.view(), query.point[SPACE_AXES].view())!;
        add_integer(difference, query.point[axis].view(), negate_integer(difference.view()))!;
        multiply_integer(coordinate, difference.view(), difference.view())!;
        add_integer(distance_squared, distance_squared.view(), coordinate.view())!;
    }
    return compare_magnitude(distance_squared.view(), query.radius_squared.view()) <= 0;
}

fn bool? collision_segment_witness(
    ExactScratch* scratch,
    CollisionWitnessQuery query,
    Vec3 first,
    Vec3 second,
) @local {
    std::time::Clock started = begin_exact_measurement(scratch);
    defer finish_exact_measurement(scratch, started);
    uint saved = scratch.count;
    defer scratch.count = saved;

    WideInteger*[SPACE_AXES] delta;
    WideInteger*[SPACE_AXES] edge;
    foreach (&coordinate : delta) *coordinate = scratch.take()!;
    foreach (&coordinate : edge) *coordinate = scratch.take()!;
    WideInteger* product = scratch.take()!;
    WideInteger* temporary = scratch.take()!;

    for (uint axis = 0; axis < SPACE_AXES; axis++) {
        integer_from_float(product, first[axis]);
        integer_from_float(temporary, second[axis]);
        add_integer(edge[axis], temporary.view(), negate_integer(product.view()))!;
        multiply_integer(temporary, product.view(), query.point[SPACE_AXES].view())!;
        add_integer(delta[axis], query.point[axis].view(), negate_integer(temporary.view()))!;
    }

    WideInteger* edge_squared = scratch.take()!;
    WideInteger* projection = scratch.take()!;
    WideInteger* delta_squared = scratch.take()!;
    witness_dot(
        output: edge_squared,
        first: edge,
        second: edge,
        product: product,
    )!;
    witness_dot(
        output: projection,
        first: delta,
        second: edge,
        product: product,
    )!;
    if (integer_sign(projection.view()) <= 0) return false;

    multiply_integer(product, query.point[SPACE_AXES].view(), edge_squared.view())!;
    if (compare_magnitude(projection.view(), product.view()) >= 0) return false;

    witness_dot(
        output: delta_squared,
        first: delta,
        second: delta,
        product: product,
    )!;
    multiply_integer(product, delta_squared.view(), edge_squared.view())!;
    multiply_integer(temporary, projection.view(), projection.view())!;
    add_integer(product, product.view(), negate_integer(temporary.view()))!;
    multiply_integer(temporary, query.radius_squared.view(), edge_squared.view())!;
    return compare_magnitude(product.view(), temporary.view()) <= 0;
}

fn bool? collision_triangle_witness(
    ExactScratch* scratch,
    CollisionWitnessQuery query,
    Vec3[TRIANGLE_CORNERS] triangle,
    int* side,
) @local {
    std::time::Clock started = begin_exact_measurement(scratch);
    defer finish_exact_measurement(scratch, started);
    uint saved = scratch.count;
    defer scratch.count = saved;

    WideInteger*[SPACE_AXES] delta;
    WideInteger*[SPACE_AXES] first_edge;
    WideInteger*[SPACE_AXES] second_edge;
    foreach (&coordinate : delta) *coordinate = scratch.take()!;
    foreach (&coordinate : first_edge) *coordinate = scratch.take()!;
    foreach (&coordinate : second_edge) *coordinate = scratch.take()!;
    WideInteger* product = scratch.take()!;
    WideInteger* temporary = scratch.take()!;

    for (uint axis = 0; axis < SPACE_AXES; axis++) {
        integer_from_float(product, triangle[0][axis]);
        integer_from_float(temporary, triangle[1][axis]);
        add_integer(first_edge[axis], temporary.view(), negate_integer(product.view()))!;
        integer_from_float(temporary, triangle[2][axis]);
        add_integer(second_edge[axis], temporary.view(), negate_integer(product.view()))!;
        multiply_integer(temporary, product.view(), query.point[SPACE_AXES].view())!;
        add_integer(delta[axis], query.point[axis].view(), negate_integer(temporary.view()))!;
    }

    WideInteger*[SPACE_AXES] normal;
    foreach (&coordinate : normal) *coordinate = scratch.take()!;
    for (uint axis = 0; axis < SPACE_AXES; axis++) {
        uint next = (axis + 1) % SPACE_AXES;
        uint last = (axis + 2) % SPACE_AXES;
        multiply_integer(product, first_edge[next].view(), second_edge[last].view())!;
        multiply_integer(temporary, first_edge[last].view(), second_edge[next].view())!;
        add_integer(normal[axis], product.view(), negate_integer(temporary.view()))!;
    }

    WideInteger* normal_squared = scratch.take()!;
    WideInteger* plane_value = scratch.take()!;
    witness_dot(
        output: normal_squared,
        first: normal,
        second: normal,
        product: product,
    )!;
    witness_dot(
        output: plane_value,
        first: delta,
        second: normal,
        product: product,
    )!;
    *side = integer_sign(plane_value.view());

    multiply_integer(product, plane_value.view(), plane_value.view())!;
    multiply_integer(temporary, query.radius_squared.view(), normal_squared.view())!;
    if (compare_magnitude(product.view(), temporary.view()) > 0) return false;

    WideInteger* first_weight = scratch.take()!;
    for (uint axis = 0; axis < SPACE_AXES; axis++) {
        uint next = (axis + 1) % SPACE_AXES;
        uint last = (axis + 2) % SPACE_AXES;
        multiply_integer(product, delta[next].view(), second_edge[last].view())!;
        multiply_integer(temporary, delta[last].view(), second_edge[next].view())!;
        add_integer(product, product.view(), negate_integer(temporary.view()))!;
        multiply_integer(temporary, product.view(), normal[axis].view())!;
        add_integer(first_weight, first_weight.view(), temporary.view())!;
    }
    if (integer_sign(first_weight.view()) < 0) return false;

    WideInteger* second_weight = scratch.take()!;
    for (uint axis = 0; axis < SPACE_AXES; axis++) {
        uint next = (axis + 1) % SPACE_AXES;
        uint last = (axis + 2) % SPACE_AXES;
        multiply_integer(product, first_edge[next].view(), delta[last].view())!;
        multiply_integer(temporary, first_edge[last].view(), delta[next].view())!;
        add_integer(product, product.view(), negate_integer(temporary.view()))!;
        multiply_integer(temporary, product.view(), normal[axis].view())!;
        add_integer(second_weight, second_weight.view(), temporary.view())!;
    }
    if (integer_sign(second_weight.view()) < 0) return false;

    WideInteger* limit = scratch.take()!;
    multiply_integer(limit, query.point[SPACE_AXES].view(), normal_squared.view())!;
    add_integer(first_weight, first_weight.view(), second_weight.view())!;
    return compare_magnitude(first_weight.view(), limit.view()) <= 0;
}

fn void? witness_dot(
    WideInteger* output,
    WideInteger*[SPACE_AXES] first,
    WideInteger*[SPACE_AXES] second,
    WideInteger* product,
) @local {
    set_integer(output, 0);
    for (uint axis = 0; axis < SPACE_AXES; axis++) {
        multiply_integer(product, first[axis].view(), second[axis].view())!;
        add_integer(output, output.view(), product.view())!;
    }
    return;
}
