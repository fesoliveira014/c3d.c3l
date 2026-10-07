module c3d::physics::fracture;

import std::math;
import std::time;

fn int? compare_sample_bound(
    ExactScratch* scratch,
    HomogeneousPoint sample,
    uint axis,
    long bound,
    bool quantized,
) @local {
    std::time::Clock started = begin_exact_measurement(scratch);
    defer finish_exact_measurement(scratch, started);
    uint saved = scratch.count;
    defer scratch.count = saved;
    WideInteger* coordinate = scratch.take()!;
    WideInteger* product = scratch.take()!;
    if (quantized) {
        set_integer(coordinate, bound);
    } else {
        uint bits = (uint)(bound < 0 ? -bound : bound);
        if (bound < 0) bits |= (uint)1 << FLOAT_SIGN_BIT;
        integer_from_float(coordinate, bitcast(bits, float));
    }
    multiply_integer(product, coordinate.view(), sample[SPACE_AXES].view())!;
    add_integer(coordinate, sample[axis].view(), negate_integer(product.view()))!;
    return integer_sign(coordinate.view());
}

fn bool? sample_ray_overlaps(SolidSurface* surface, SolidBounds* bounds, HomogeneousPoint sample) @local {
    for (uint axis = 0; axis < SPACE_AXES; axis++) {
        if (compare_sample_bound(
            scratch: surface.exact, sample: sample, axis: axis,
            bound: bounds.upper[axis], quantized: surface.grid.len != 0,
        )! > 0) return false;
        if (axis == SPACE_AXES - 1) continue;
        if (compare_sample_bound(
            scratch: surface.exact, sample: sample, axis: axis,
            bound: bounds.lower[axis], quantized: surface.grid.len != 0,
        )! < 0) return false;
    }
    return true;
}

fn int? sample_projected_side(
    SolidSurface* surface,
    uint first,
    uint second,
    HomogeneousPoint sample,
) @local {
    std::time::Clock started = begin_exact_measurement(surface.exact);
    defer finish_exact_measurement(surface.exact, started);
    ExactScratch* scratch = surface.exact;
    uint saved = scratch.count;
    defer scratch.count = saved;
    WideInteger*[2][2] points;
    for (uint vertex = 0; vertex < 2; vertex++) {
        for (uint axis = 0; axis < 2; axis++) {
            points[vertex][axis] = scratch.take()!;
            uint identity = vertex ? second : first;
            if (surface.grid.len) {
                set_integer(points[vertex][axis], surface.grid[identity][axis]);
            } else {
                integer_from_float(points[vertex][axis], surface_position(surface, identity)[axis]);
            }
        }
    }
    WideInteger* coefficient = scratch.take()!;
    WideInteger* product = scratch.take()!;
    WideInteger* result = scratch.take()!;
    WideInteger* temporary = scratch.take()!;
    add_integer(coefficient, points[0][1].view(), negate_integer(points[1][1].view()))!;
    multiply_integer(result, coefficient.view(), sample[0].view())!;
    add_integer(coefficient, points[1][0].view(), negate_integer(points[0][0].view()))!;
    multiply_integer(product, coefficient.view(), sample[1].view())!;
    add_integer(temporary, result.view(), product.view())!;
    copy_integer(result, temporary.view());
    multiply_integer(product, points[0][0].view(), points[1][1].view())!;
    multiply_integer(temporary, points[0][1].view(), points[1][0].view())!;
    add_integer(coefficient, product.view(), negate_integer(temporary.view()))!;
    multiply_integer(product, coefficient.view(), sample[SPACE_AXES].view())!;
    add_integer(temporary, result.view(), product.view())!;
    int sign = integer_sign(temporary.view());
    if (sign) return sign;
    long first_key = surface_coordinate_key(surface, first, 1);
    long second_key = surface_coordinate_key(surface, second, 1);
    if (first_key != second_key) return first_key < second_key ? -1 : 1;
    first_key = surface_coordinate_key(surface, first, 0);
    second_key = surface_coordinate_key(surface, second, 0);
    return first_key < second_key ? 1 : first_key > second_key ? -1 : 0;
}

fn bool? sample_ray_crosses(
    SolidSurface* surface,
    SourceConstructions* source,
    uint face,
    HomogeneousPoint sample,
) @local {
    uint[TRIANGLE_CORNERS] triangle = surface_triangle(surface, face);
    int orientation = surface_projection(surface, triangle, SPACE_AXES - 1)!;
    if (!orientation) return false;
    for (uint corner = 0; corner < TRIANGLE_CORNERS; corner++) {
        int sign = sample_projected_side(
            surface: surface, first: triangle[corner],
            second: triangle[(corner + 1) % TRIANGLE_CORNERS], sample: sample,
        )!;
        if (sign != orientation) return false;
    }
    int side = homogeneous_plane_side(surface.exact, &source.faces[face], sample)!;
    return side * (source.reversed[face] ? -1 : 1) * orientation < 0;
}

fn bool? cell_is_occupied(
    SolidSurface* surface,
    SourceConstructions* source,
    ConvexCell* cell,
    ulong* candidate_faces,
) @private {
    uint saved = surface.exact.count;
    defer surface.exact.count = saved;
    HomogeneousPoint sample = sample_cell_interior(surface.exact, cell)!;
    return sample_is_occupied(
        surface: surface,
        source: source,
        sample: sample,
        candidate_faces: candidate_faces,
    );
}

<* @require surface.validated && !surface.grid.len *>
fn bool? raw_point_is_occupied(SolidSurface* surface, SourceConstructions* source, Vec3 point) @private {
    uint saved = surface.exact.count;
    defer surface.exact.count = saved;

    HomogeneousPoint sample = raw_point_sample(surface.exact, point)!;
    ulong candidate_faces;
    return sample_is_occupied(
        surface: surface,
        source: source,
        sample: sample,
        candidate_faces: &candidate_faces,
    );
}

fn HomogeneousPoint? raw_point_sample(ExactScratch* scratch, Vec3 point) @local {
    std::time::Clock started = begin_exact_measurement(scratch);
    defer finish_exact_measurement(scratch, started);
    uint saved = scratch.count;
    defer catch scratch.count = saved;

    HomogeneousPoint sample;
    foreach (&coordinate : sample) *coordinate = scratch.take()!;
    for (uint axis = 0; axis < SPACE_AXES; axis++) integer_from_float(sample[axis], point[axis]);
    set_integer(sample[SPACE_AXES], 1);

    return sample;
}

fn bool? sample_is_occupied(
    SolidSurface* surface,
    SourceConstructions* source,
    HomogeneousPoint sample,
    ulong* candidate_faces,
) @local {
    bool inside;
    uint current;
    while (current != NO_SOLID_INDEX) {
        SolidBvhNode* node = &surface.nodes[current];
        if (!sample_ray_overlaps(surface, &node.bounds, sample)!) {
            current = node.escape;
        } else if (node.count != 1) {
            current = node.child;
        } else {
            (*candidate_faces)++;
            if (sample_ray_crosses(
                surface: surface, source: source, face: surface.order[node.first], sample: sample,
            )!) inside = !inside;
            current = node.escape;
        }
    }
    return inside;
}
