module c3d::physics::fracture;

import std::time;
import std::math;

fn int? exact_projected_orientation(ExactScratch* scratch, Vec3[TRIANGLE_CORNERS] points, uint dropped_axis) @private {
    uint saved = scratch.count;
    defer scratch.count = saved;
    WideInteger* one = scratch.take()!;
    WideInteger* result = scratch.take()!;
    set_integer(one, 1);
    IntegerView[TRIANGLE_CORNERS * TRIANGLE_CORNERS] matrix;
    foreach (uint row, point : points) {
        matrix[row * TRIANGLE_CORNERS] = one.view();
        for (uint column = 1; column < TRIANGLE_CORNERS; column++) {
            WideInteger* value = scratch.take()!;
            integer_from_float(value, point[(dropped_axis + column) % SPACE_AXES]);
            matrix[row * TRIANGLE_CORNERS + column] = value.view();
        }
    }
    determinant(
        scratch: scratch,
        output: result,
        matrix: matrix[..],
        order: TRIANGLE_CORNERS,
    )!;
    return integer_sign(result.view());
}

fn int? projected_orientation(ExactScratch* scratch, Vec3[TRIANGLE_CORNERS] points, uint dropped_axis) @private {
    scratch.predicate_count++;
    $if env::COMPILER_OPT_LEVEL != O3:
    Interval[4] differences;
    for (uint vertex = 0; vertex < 2; vertex++) {
        for (uint component = 0; component < 2; component++) {
            uint axis = (dropped_axis + component + 1) % SPACE_AXES;
            double value = points[vertex + 1][axis];
            double origin = points[0][axis];
            differences[vertex * 2 + component] = add_interval(
                { .low = value, .high = value },
                { .low = -origin, .high = -origin },
            );
        }
    }
    int sign = interval_sign(add_interval(
        multiply_interval(differences[0], differences[3]),
        negate_interval(multiply_interval(differences[1], differences[2])),
    ));
    if (sign != FILTER_UNCERTAIN) {
        scratch.filtered_count++;
        return sign;
    }
    $endif
    Clock started = clock::now();
    defer scratch.exact_nanoseconds += (ulong)started.to_now();
    return exact_projected_orientation(scratch, points, dropped_axis);
}

fn int projected_grid_orientation(ExactScratch* scratch, GridPoint[TRIANGLE_CORNERS] points, uint dropped_axis) @private {
    scratch.predicate_count++;
    Clock started = clock::now();
    defer scratch.exact_nanoseconds += (ulong)started.to_now();
    uint first = (dropped_axis + 1) % SPACE_AXES;
    uint second = (dropped_axis + 2) % SPACE_AXES;
    int128 area = ((int128)points[1][first] - points[0][first]) * ((int128)points[2][second] - points[0][second])
        - ((int128)points[1][second] - points[0][second]) * ((int128)points[2][first] - points[0][first]);
    return area > 0 ? 1 : area < 0 ? -1 : 0;
}
