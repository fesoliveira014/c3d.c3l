module c3d::physics::fracture;

import std::time;
import std::math;

const uint RAW_CENTROID_MOMENT_BITS @private = 1145;
const uint CENTROID_TEMPORARIES @private = 4 + 3 + TRIANGLE_CORNERS * SPACE_AXES + SPACE_AXES;
const uint RAW_CENTROID_ERROR_BITS @private = 2 * (RAW_CENTROID_MOMENT_BITS + 1) + 2;

$assert EXACT_LIMBS * INTEGER_LIMB_BITS >= RAW_CENTROID_ERROR_BITS;
$assert CENTROID_TEMPORARIES <= EXACT_TEMPORARIES;

<* @require value.limbs.len > 0 && !value.negative *>
fn void require_centroid_volume(IntegerView value) @local {}

<* @require surface.validated && !surface.grid.len *>
fn Vec3? rounded_surface_centroid(SolidSurface* surface, float resolution) @private {
    std::time::Clock started = begin_exact_measurement(surface.exact);
    defer finish_exact_measurement(surface.exact, started);
    ExactScratch* scratch = surface.exact;
    uint saved = scratch.count;
    defer scratch.count = saved;
    WideInteger* denominator = scratch.take()!;
    WideInteger*[SPACE_AXES] moments;
    for (uint axis = 0; axis < SPACE_AXES; axis++) moments[axis] = scratch.take()!;
    uint accumulated = scratch.count;
    WideInteger* term = scratch.take()!;
    WideInteger* sum = scratch.take()!;
    WideInteger* product = scratch.take()!;
    foreach (uint face, unused : surface.topology.shell_roots) {
        triangle_volume(surface, term, face)!;
        add_integer(denominator, denominator.view(), term.view())!;
        uint[TRIANGLE_CORNERS] triangle = surface_triangle(surface, face);
        for (uint axis = 0; axis < SPACE_AXES; axis++) {
            set_integer(sum, 0);
            foreach (identity : triangle) {
                integer_from_float(product, surface_position(surface, identity)[axis]);
                add_integer(sum, sum.view(), product.view())!;
            }
            multiply_integer(product, term.view(), sum.view())!;
            add_integer(moments[axis], moments[axis].view(), product.view())!;
        }
    }
    require_centroid_volume(denominator.view());
    shift_integer(term, denominator.view(), 2)!;
    copy_integer(denominator, term.view());
    scratch.count = accumulated;
    Vec3 centroid;
    for (uint axis = 0; axis < SPACE_AXES; axis++) {
        centroid[axis] = round_float_ratio(
            scratch: scratch,
            numerator: moments[axis].view(),
            denominator: denominator.view(),
            unit_exponent: FLOAT_UNIT_EXPONENT,
        )!;
    }
    WideInteger* rounded = scratch.take()!;
    WideInteger* error = scratch.take()!;
    WideInteger* square = scratch.take()!;
    WideInteger* squared_error = scratch.take()!;
    for (uint axis = 0; axis < SPACE_AXES; axis++) {
        integer_from_float(rounded, centroid[axis]);
        multiply_integer(error, rounded.view(), denominator.view())!;
        add_integer(error, error.view(), negate_integer(moments[axis].view()))!;
        multiply_integer(square, error.view(), error.view())!;
        add_integer(squared_error, squared_error.view(), square.view())!;
    }
    integer_from_float(rounded, resolution);
    multiply_integer(error, rounded.view(), denominator.view())!;
    multiply_integer(square, error.view(), error.view())!;
    if (compare_magnitude(squared_error.view(), square.view()) > 0) return NUMERICAL_FAILURE~;
    return centroid;
}
