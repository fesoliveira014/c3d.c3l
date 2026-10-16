module c3d::nav;

import std::math;
import c3d;

enum ClearanceIntersection @local {
    NONE,
    PRESENT,
    UNCERTAIN,
}

struct ClearancePoint @private {
    PrecisionInterval x;
    PrecisionInterval z;
}

struct ClearanceRectangle @private {
    PrecisionInterval min_x;
    PrecisionInterval min_z;
    PrecisionInterval max_x;
    PrecisionInterval max_z;
}

fn ClearancePoint? clearance_point(double x, double z) @private {
    return { .x = precision_point(x)!, .z = precision_point(z)! };
}

fn PrecisionInterval? clearance_point_distance(ClearancePoint first, ClearancePoint second) @private {
    PrecisionInterval x = precision_subtract(first.x, second.x)!;
    PrecisionInterval z = precision_subtract(first.z, second.z)!;

    return precision_sqrt(precision_add(precision_square(x)!, precision_square(z)!)!);
}

fn PrecisionInterval? clearance_point_rectangle_distance(ClearancePoint point, ClearanceRectangle rectangle) @private {
    PrecisionInterval left = precision_subtract(rectangle.min_x, point.x)!;
    PrecisionInterval right = precision_subtract(point.x, rectangle.max_x)!;
    PrecisionInterval bottom = precision_subtract(rectangle.min_z, point.z)!;
    PrecisionInterval top = precision_subtract(point.z, rectangle.max_z)!;

    PrecisionInterval x = {
        .min = math::max(0.0, math::max(left.min, right.min)),
        .max = math::max(0.0, math::max(left.max, right.max)),
    };
    PrecisionInterval z = {
        .min = math::max(0.0, math::max(bottom.min, top.min)),
        .max = math::max(0.0, math::max(bottom.max, top.max)),
    };

    return precision_sqrt(precision_add(precision_square(x)!, precision_square(z)!)!);
}

fn PrecisionInterval? clearance_point_segment_distance(
    ClearancePoint point,
    ClearancePoint first,
    ClearancePoint last,
) @private {
    PrecisionInterval x = precision_subtract(last.x, first.x)!;
    PrecisionInterval z = precision_subtract(last.z, first.z)!;
    PrecisionInterval length_squared = precision_add(precision_square(x)!, precision_square(z)!)!;
    if (length_squared.max == 0) return clearance_point_distance(point, first);
    if (length_squared.min <= 0) return c3d::CAPACITY_EXCEEDED~;

    PrecisionInterval offset_x = precision_subtract(point.x, first.x)!;
    PrecisionInterval offset_z = precision_subtract(point.z, first.z)!;
    PrecisionInterval dot = precision_add(precision_multiply(offset_x, x)!, precision_multiply(offset_z, z)!)!;
    PrecisionInterval fraction = precision_clamp(precision_divide(dot, length_squared)!, 0, 1)!;
    ClearancePoint closest = {
        .x = precision_add(first.x, precision_multiply(fraction, x)!)!,
        .z = precision_add(first.z, precision_multiply(fraction, z)!)!,
    };

    return clearance_point_distance(point, closest);
}

fn PrecisionInterval? clearance_segment_rectangle_distance(
    ClearancePoint first,
    ClearancePoint last,
    ClearanceRectangle rectangle,
) @private {
    ClearanceIntersection intersection = clearance_segment_intersection(first, last, rectangle)!;
    if (intersection == ClearanceIntersection.PRESENT) return precision_point(0);

    PrecisionInterval result = clearance_point_rectangle_distance(first, rectangle)!;
    PrecisionInterval candidate = clearance_point_rectangle_distance(last, rectangle)!;
    result.min = math::min(result.min, candidate.min);
    result.max = math::min(result.max, candidate.max);

    ClearancePoint[4] corners = {
        { .x = rectangle.min_x, .z = rectangle.min_z },
        { .x = rectangle.max_x, .z = rectangle.min_z },
        { .x = rectangle.max_x, .z = rectangle.max_z },
        { .x = rectangle.min_x, .z = rectangle.max_z },
    };
    foreach (corner : corners) {
        candidate = clearance_point_segment_distance(corner, first, last)!;
        result.min = math::min(result.min, candidate.min);
        result.max = math::min(result.max, candidate.max);
    }

    // An unresolved intersection can still make the true distance zero.
    if (intersection == ClearanceIntersection.UNCERTAIN) result.min = 0;

    return result;
}

fn bool? clearance_neighborhood_meets(
    ClearancePoint first,
    ClearancePoint last,
    ClearanceRectangle rectangle,
    PrecisionInterval radius,
    double interval_limit,
) @private {
    PrecisionInterval distance = clearance_segment_rectangle_distance(first, last, rectangle)!;
    PrecisionInterval signed_distance = precision_subtract(distance, radius)!;
    PrecisionInterval width = precision_subtract(precision_point(signed_distance.max)!, precision_point(signed_distance.min)!)!;
    if (width.max > interval_limit) return c3d::CAPACITY_EXCEEDED~;

    return signed_distance.min <= 0;
}

fn ClearanceIntersection? clearance_segment_intersection(
    ClearancePoint first,
    ClearancePoint last,
    ClearanceRectangle rectangle,
) @local {
    PrecisionInterval[2] start = { first.x, first.z };
    PrecisionInterval[2] end = { last.x, last.z };
    PrecisionInterval[2] low = { rectangle.min_x, rectangle.min_z };
    PrecisionInterval[2] high = { rectangle.max_x, rectangle.max_z };
    PrecisionInterval enter = { .min = 0, .max = 0 };
    PrecisionInterval leave = { .min = 1, .max = 1 };
    bool uncertain;

    for (uint axis = 0; axis < 2; axis++) {
        double segment_min = math::min(start[axis].min, end[axis].min);
        double segment_max = math::max(start[axis].max, end[axis].max);
        if (segment_max < low[axis].min || segment_min > high[axis].max) return ClearanceIntersection.NONE;
        if (segment_min >= low[axis].max && segment_max <= high[axis].min) continue;

        PrecisionInterval delta = precision_subtract(end[axis], start[axis])!;
        if (delta.min <= 0 && delta.max >= 0) {
            uncertain = true;
            continue;
        }

        PrecisionInterval first_cut = precision_divide(precision_subtract(low[axis], start[axis])!, delta)!;
        PrecisionInterval last_cut = precision_divide(precision_subtract(high[axis], start[axis])!, delta)!;
        if (delta.max < 0) @swap(first_cut, last_cut);

        enter.min = math::max(enter.min, first_cut.min);
        enter.max = math::max(enter.max, first_cut.max);
        leave.min = math::min(leave.min, last_cut.min);
        leave.max = math::min(leave.max, last_cut.max);
        if (enter.min > leave.max) return ClearanceIntersection.NONE;
    }

    return !uncertain && enter.max <= leave.min ? ClearanceIntersection.PRESENT : ClearanceIntersection.UNCERTAIN;
}
