module c3d::physics::fracture;

import std::time;

const uint ROUNDING_VOLUME_BITS @private = 872;
const uint ROUNDING_VOLUME_TEMPORARIES @private = 2 + 2 * SPACE_AXES + 2;
$assert ROUNDING_VOLUME_BITS <= PLANE_LIMBS * INTEGER_LIMB_BITS;
$assert ROUNDING_VOLUME_TEMPORARIES <= EXACT_TEMPORARIES;

<* @require surface.validated && !surface.grid.len *>
fn PlaneInteger? float_rounding_volume_bound(SolidSurface* surface, float resolution) @private {
    std::time::Clock started = begin_exact_measurement(surface.exact);
    defer finish_exact_measurement(surface.exact, started);
    ExactScratch* scratch = surface.exact;
    uint saved = scratch.count;
    defer scratch.count = saved;
    WideInteger* cross_sum = scratch.take()!;
    WideInteger* edge_sum = scratch.take()!;
    WideInteger*[SPACE_AXES] first_edge;
    WideInteger*[SPACE_AXES] second_edge;
    foreach (&coordinate : first_edge) *coordinate = scratch.take()!;
    foreach (&coordinate : second_edge) *coordinate = scratch.take()!;
    WideInteger* first = scratch.take()!;
    WideInteger* second = scratch.take()!;
    foreach (uint face, root : surface.topology.shell_roots) {
        uint[TRIANGLE_CORNERS] triangle = surface_triangle(surface, face);
        for (uint axis = 0; axis < SPACE_AXES; axis++) {
            integer_from_float(first, surface_position(surface, triangle[0])[axis]);
            integer_from_float(second, surface_position(surface, triangle[1])[axis]);
            add_integer(first_edge[axis], second.view(), negate_integer(first.view()))!;
            integer_from_float(second, surface_position(surface, triangle[2])[axis]);
            add_integer(second_edge[axis], second.view(), negate_integer(first.view()))!;
            IntegerView edge = first_edge[axis].view();
            edge.negative = false;
            add_integer(edge_sum, edge_sum.view(), edge)!;
            edge = second_edge[axis].view();
            edge.negative = false;
            add_integer(edge_sum, edge_sum.view(), edge)!;
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
    multiply_integer(second, first.view(), edge_sum.view())!;
    multiply_integer(first, second.view(), scale.view())!;
    add_integer(bound, bound.view(), first.view())!;
    multiply_integer(first, epsilon.view(), epsilon.view())!;
    multiply_integer(second, first.view(), epsilon.view())!;
    set_integer(scale, 4 * (int128)surface.topology.shell_roots.len);
    multiply_integer(first, second.view(), scale.view())!;
    add_integer(bound, bound.view(), first.view())!;
    PlaneInteger result = { .used = bound.used };
    result.limbs[:bound.used] = bound.limbs[:bound.used];
    return result;
}
