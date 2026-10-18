module c3d::physics;

import std::math;
import c3d::maths;
import b3;

const usz HEIGHT_FIELD_HEADER_BYTES @local = 96; // sizeof(b3HeightFieldData) in box3d's types.h
const usz HEIGHT_FIELD_ALIGNMENT @local = 8; // box3d aligns each array of the cooked blob to this
const usz HEIGHT_FIELD_SAMPLE_BYTES @local = 2; // one quantized 16-bit height per grid point

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

fn usz aligned_height_field_bytes(usz bytes) @local {
    return (bytes + HEIGHT_FIELD_ALIGNMENT - 1) & ~(HEIGHT_FIELD_ALIGNMENT - 1);
}
