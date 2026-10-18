module c3d::physics;

import std::math;
import c3d::maths;
import b3;

const usz HEIGHT_FIELD_HEADER_BYTES @local = 96; // sizeof(b3HeightFieldData) in box3d's types.h
const usz HEIGHT_FIELD_ALIGNMENT @local = 8; // box3d aligns each array of the cooked blob to this
const usz HEIGHT_FIELD_SAMPLE_BYTES @local = 2; // one quantized 16-bit height per grid point
const float COLLISION_NATIVE_AABB_MARGIN @local = 0.05f; // native B3_MAX_AABB_MARGIN at one length unit per metre
const float COLLISION_CELL_ROUNDING_GROWTH @local = 1.0001f; // absorbs the binary32 rounding of the native clip
const double CELL_INDEX_MINIMUM @local = (double)int::min; // native cell indices are signed ints
const double CELL_INDEX_MAXIMUM @local = (double)int::max; // exact in binary64; as a float it would round up to 2^31

// Reflection is refused rather than converted to a mesh; the grid spacing must have a finite reciprocal.
fn void? check_collision_height_scale(Vec3 scale) @private {
    foreach (component : scale) {
        if (component < 0) return c3d::UNSUPPORTED~;
    }

    check_collision_quantity(1 / scale.x)!;
    check_collision_quantity(1 / scale.z)!;
}

// The native cook multiplies counts in signed ints and stores the blob size and array offsets in them.
fn void? check_collision_height_grid(
    uint count_x,
    uint count_z,
    usz sample_count,
    usz material_count,
) @private {
    if (count_x < 2 || count_z < 2) return c3d::INVALID_ARGUMENT~;

    usz points = (usz)count_x * count_z;
    usz cells = (usz)(count_x - 1) * (usz)(count_z - 1);
    usz triangles = 2 * cells;
    usz bytes = HEIGHT_FIELD_HEADER_BYTES
      + aligned_height_field_bytes(points * HEIGHT_FIELD_SAMPLE_BYTES)
      + aligned_height_field_bytes(cells)
      + aligned_height_field_bytes(triangles);
    if (points > int::max || triangles > int::max || bytes > int::max) return c3d::CAPACITY_EXCEEDED~;

    if (sample_count != points) return c3d::INVALID_ARGUMENT~;
    if (material_count && material_count != cells) return c3d::INVALID_ARGUMENT~;
}

fn void? check_collision_height_samples(
    float[] heights,
    Vec3 scale,
    uint count_x,
    uint count_z,
) @private {
    float minimum = heights[0];
    float maximum = heights[0];
    foreach (height : heights) {
        if (!math::is_finite(height)) return c3d::INVALID_ARGUMENT~;
        minimum = math::min(minimum, height);
        maximum = math::max(maximum, height);
    }
    if (!math::is_finite(maximum - minimum)) return b3::DEGENERATE_GEOMETRY~;

    Vec3 lower = { 0, scale.y * minimum, 0 };
    Vec3 upper = { scale.x * (float)(count_x - 1), scale.y * maximum, scale.z * (float)(count_z - 1) };
    if (!collision_vector_finite(lower) || !collision_vector_finite(upper)) return b3::DEGENERATE_GEOMETRY~;
}

fn void? check_collision_height_source(HeightField field, Vec3 scale, char[] material_indices) @private {
    if (!window_covers_map(field.window)) return c3d::INVALID_ARGUMENT~;

    check_collision_height_grid(
        count_x: field.count_x,
        count_z: field.count_z,
        sample_count: field.heights.len,
        material_count: material_indices.len,
    )!;
    check_collision_height_samples(
        heights: field.heights,
        scale: scale,
        count_x: field.count_x,
        count_z: field.count_z,
    )!;
}

// Reads the retained surface, so entries cooked by bodies are checked the same way; a field of only holes is valid.
fn maths::Aabb? check_collision_height_field(b3::HeightFieldData* field) @private {
    b3::Aabb native = field.compute_aabb(IDENTITY_FRAME);
    maths::Aabb bounds = { .min = native.lower_bound, .max = native.upper_bound };
    if (!collision_vector_finite(bounds.min) || !collision_vector_finite(bounds.max)) {
        return b3::DEGENERATE_GEOMETRY~;
    }

    CollisionTriangleAudit audit;
    query_height_field_cells(
        field: field,
        field_bounds: bounds,
        bounds: collision_surface_enumeration(bounds)!,
        callback: &audit_collision_triangle,
        context: &audit,
    );
    if (audit.failure) return audit.failure~;

    return bounds;
}

// The native loops visit every cell index in the box, so the box is cut to the grid before it reaches them.
fn void query_height_field_cells(
    b3::HeightFieldData* field,
    maths::Aabb field_bounds,
    b3::Aabb bounds,
    b3::MeshQueryFn callback,
    void* context,
) @private {
    b3::Aabb cells = {
        .lower_bound = {
            math::max(bounds.lower_bound.x, field_bounds.min.x),
            bounds.lower_bound.y,
            math::max(bounds.lower_bound.z, field_bounds.min.z),
        },
        .upper_bound = {
            math::min(bounds.upper_bound.x, field_bounds.max.x),
            bounds.upper_bound.y,
            math::min(bounds.upper_bound.z, field_bounds.max.z),
        },
    };
    if (cells.lower_bound.x > cells.upper_bound.x || cells.lower_bound.z > cells.upper_bound.z) return;

    b3::query_height_field(
        height_field: field,
        bounds: cells,
        fcn: callback,
        context: context,
    );
}

// Every cell index the native cast forms lies inside the field grown by twice the proxy extent and the margin, so
// one outward-rounded envelope per grid axis covers the clipped ends, the corners and the row and column crossings.
fn void? check_collision_cells(CollisionShapeState* surface, Vec3[] points, float radius) @private {
    float margin = collision_bound_product(COLLISION_NATIVE_AABB_MARGIN, b3::length_units_per_meter())!;
    foreach (axis : (usz[2]){ 0, 2 }) {
        float lowest = float::max;
        float highest = -float::max;
        foreach (point : points) {
            lowest = math::min(lowest, point[axis]);
            highest = math::max(highest, point[axis]);
        }

        float extent = collision_upper_bound(((double)highest - lowest) / 2 + radius)!;
        float reach = collision_bound_sum(collision_bound_sum(extent, extent)!, margin)!;
        float field_reach = math::max(math::abs(surface.bounds.min[axis]), math::abs(surface.bounds.max[axis]));
        float envelope = collision_bound_product(
            collision_bound_sum(field_reach, reach)!,
            COLLISION_CELL_ROUNDING_GROWTH,
        )!;

        float spacing = surface.field_scale[axis];
        if (!collision_cell_index_fits(envelope, spacing) || !collision_cell_index_fits(-envelope, spacing)) {
            return c3d::UNSUPPORTED~;
        }
    }
}

// Mirrors the native conversion: a binary32 division, then a floor compared against the exact int limits.
fn bool collision_cell_index_fits(float coordinate, float spacing) @local {
    float quotient = coordinate / spacing;
    if (!math::is_finite(quotient)) return false;

    double cell = math::floor((double)quotient);
    return cell >= CELL_INDEX_MINIMUM && cell <= CELL_INDEX_MAXIMUM;
}

fn usz aligned_height_field_bytes(usz bytes) @local {
    return (bytes + HEIGHT_FIELD_ALIGNMENT - 1) & ~(HEIGHT_FIELD_ALIGNMENT - 1);
}
