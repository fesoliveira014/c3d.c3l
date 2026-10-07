module c3d::physics::fracture;

import c3d::geometry;
import std::math;

const uint SURFACE_ATTRIBUTE_BITS @private = 2512;
const uint SURFACE_ATTRIBUTE_TEMPORARIES @private = 18;

$assert SURFACE_ATTRIBUTE_BITS <= EXACT_LIMBS * INTEGER_LIMB_BITS;
$assert SURFACE_ATTRIBUTE_TEMPORARIES <= EXACT_TEMPORARIES;

struct SurfaceAttributes @private {
    Vec3 normal;
    Vec2 uv0;
    Vec2 uv1;
    Vec4 color;
    uint corner;
    uint[2] edge;
}

fn void? source_attribute_weights(
    SolidSurface* surface,
    uint face,
    PlaneTriple vertex,
    WideInteger*[TRIANGLE_CORNERS] weights,
    WideInteger* denominator,
) @local {
    ExactScratch* scratch = surface.exact;
    uint saved = scratch.count;
    defer scratch.count = saved;
    HomogeneousPoint point;
    foreach (&coordinate : point) *coordinate = scratch.take()!;
    construct_point(scratch, point, vertex)!;
    uint projection = surface.projections[face];
    uint[TRIANGLE_CORNERS] triangle = surface_triangle(surface, face);
    WideInteger*[2][TRIANGLE_CORNERS] projected;
    foreach (uint corner, identity : triangle) {
        for (uint axis = 0; axis < 2; axis++) {
            uint component = (projection + axis + 1) % SPACE_AXES;
            projected[corner][axis] = scratch.take()!;
            if (surface.grid.len) {
                set_integer(projected[corner][axis], surface.grid[identity][component]);
            } else {
                integer_from_float(projected[corner][axis], surface_position(surface, identity)[component]);
            }
        }
    }
    WideInteger* one = scratch.take()!;
    set_integer(one, 1);
    for (uint weight = 0; weight < TRIANGLE_CORNERS; weight++) {
        IntegerView[TRIANGLE_CORNERS * TRIANGLE_CORNERS] matrix;
        for (uint row = 0; row < TRIANGLE_CORNERS; row++) {
            for (uint axis = 0; axis < 2; axis++) {
                matrix[row * TRIANGLE_CORNERS + axis] = row == weight
                  ? point[(projection + axis + 1) % SPACE_AXES].view() : projected[row][axis].view();
            }
            matrix[row * TRIANGLE_CORNERS + 2] = row == weight ? point[SPACE_AXES].view() : one.view();
        }
        determinant(
            scratch: scratch,
            output: weights[weight],
            matrix: matrix[..],
            order: TRIANGLE_CORNERS,
        )!;
        add_integer(denominator, denominator.view(), weights[weight].view())!;
    }
    if (denominator.negative) {
        denominator.negative = false;
        foreach (weight : weights) if (weight.used) weight.negative = !weight.negative;
    }
    return;
}

fn float? interpolate_surface_attribute(
    ExactScratch* scratch,
    WideInteger*[TRIANGLE_CORNERS] weights,
    IntegerView denominator,
    float[TRIANGLE_CORNERS] values,
) @local {
    uint saved = scratch.count;
    defer scratch.count = saved;
    WideInteger* sum = scratch.take()!;
    WideInteger* value = scratch.take()!;
    WideInteger* product = scratch.take()!;
    foreach (uint corner, attribute : values) {
        integer_from_float(value, attribute);
        multiply_integer(product, weights[corner].view(), value.view())!;
        add_integer(sum, sum.view(), product.view())!;
    }
    return round_float_ratio(
        scratch: scratch,
        numerator: sum.view(),
        denominator: denominator,
        unit_exponent: FLOAT_UNIT_EXPONENT,
    );
}

fn SurfaceAttributes? source_surface_attributes(
    SolidSurface* surface,
    uint face,
    PlaneTriple vertex,
    ExactPlane* plane,
    bool reversed,
) @private {
    ExactScratch* scratch = surface.exact;
    uint saved = scratch.count;
    defer scratch.count = saved;
    WideInteger*[TRIANGLE_CORNERS] weights;
    foreach (&weight : weights) *weight = scratch.take()!;
    WideInteger* denominator = scratch.take()!;
    source_attribute_weights(
        surface: surface,
        face: face,
        vertex: vertex,
        weights: weights,
        denominator: denominator,
    )!;
    Geometry* geometry = &surface.source.geometry;
    uint[TRIANGLE_CORNERS] vertices;
    vertices[..] = geometry.indices[(usz)face * TRIANGLE_CORNERS:TRIANGLE_CORNERS];
    SurfaceAttributes result = { .color = { 1, 1, 1, 1 }, .corner = NO_SOLID_INDEX, .edge = { NO_SOLID_INDEX, NO_SOLID_INDEX } };
    uint nonzero;
    uint last;
    foreach (uint corner, weight : weights) {
        if (weight.used) {
            nonzero++;
            last = corner;
        } else {
            uint first = vertices[(corner + 1) % TRIANGLE_CORNERS];
            uint second = vertices[(corner + 2) % TRIANGLE_CORNERS];
            result.edge = { math::min(first, second), math::max(first, second) };
        }
    }
    if (!geometry.normals.len) {
        result.normal = rounded_surface_direction(scratch, canonical_surface_normal(plane))!;
        if (reversed) result.normal = -result.normal;
    }
    if (nonzero == 1) {
        result.corner = vertices[last];
        result.edge = { NO_SOLID_INDEX, NO_SOLID_INDEX };
        if (geometry.normals.len) result.normal = geometry.normals[result.corner];
        if (geometry.uv0.len) result.uv0 = geometry.uv0[result.corner];
        if (geometry.uv1.len) result.uv1 = geometry.uv1[result.corner];
        if (geometry.colors.len) result.color = geometry.colors[result.corner];
        return result;
    }
    if (geometry.normals.len) {
        for (uint axis = 0; axis < SPACE_AXES; axis++) {
            float[TRIANGLE_CORNERS] values;
            foreach (uint corner, index : vertices) values[corner] = geometry.normals[index][axis];
            result.normal[axis] = interpolate_surface_attribute(
                scratch: scratch,
                weights: weights,
                denominator: denominator.view(),
                values: values,
            )!;
        }
    }
    for (uint channel = 0; channel < 2; channel++) {
        Vec2[] coordinates = channel ? geometry.uv1 : geometry.uv0;
        if (!coordinates.len) continue;
        Vec2 interpolated;
        for (uint axis = 0; axis < 2; axis++) {
            float[TRIANGLE_CORNERS] values;
            foreach (uint corner, index : vertices) values[corner] = coordinates[index][axis];
            interpolated[axis] = interpolate_surface_attribute(
                scratch: scratch,
                weights: weights,
                denominator: denominator.view(),
                values: values,
            )!;
        }
        if (channel) {
            result.uv1 = interpolated;
        } else {
            result.uv0 = interpolated;
        }
    }
    if (geometry.colors.len) {
        for (uint axis = 0; axis < HOMOGENEOUS_COMPONENTS; axis++) {
            float[TRIANGLE_CORNERS] values;
            foreach (uint corner, index : vertices) values[corner] = geometry.colors[index][axis];
            result.color[axis] = interpolate_surface_attribute(
                scratch: scratch,
                weights: weights,
                denominator: denominator.view(),
                values: values,
            )!;
        }
    }
    return result;
}

fn SurfaceAttributes? cut_surface_attributes(
    ExactScratch* scratch,
    ExactPlane* plane,
    bool reversed,
    Vec3 position,
    float uv_density,
) @private {
    double[<3>] normal = canonical_surface_normal(plane);
    uint least;
    for (uint axis = 1; axis < SPACE_AXES; axis++) {
        if (compare_magnitude(plane.coefficients[axis].view(), plane.coefficients[least].view()) < 0) least = axis;
    }
    double[<3>] reference;
    reference[least] = 1;
    double[<3>] tangent = normalized_surface_vector(reference.cross(normal));
    double[<3>] bitangent = normal.cross(tangent);
    double[<3>] point = decoded_surface_vector(position);
    double density = decoded_surface_float(uv_density);
    SurfaceAttributes result = {
        .normal = rounded_surface_direction(scratch, normal)!,
        .uv0 = { rounded_surface_float(scratch, point.dot(tangent) * density)!, rounded_surface_float(scratch, point.dot(bitangent) * density)! },
        .color = { 1, 1, 1, 1 },
        .corner = NO_SOLID_INDEX,
        .edge = { NO_SOLID_INDEX, NO_SOLID_INDEX },
    };
    result.uv1 = result.uv0;
    if (reversed) result.normal = -result.normal;
    return result;
}
