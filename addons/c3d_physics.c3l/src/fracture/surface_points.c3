module c3d::physics::fracture;

import c3d;
import std::math;

struct SurfacePointMap @private {
    PlaneTriple[] exact;
    Vec3[] positions;
    uint[] vertices;
    uint[] patch_offsets;
}

fn SurfacePointMap? map_surface_points(
    SolidScratch* scratch,
    BoundaryPatch[] patches,
    QuantizationGrid* grid = null,
) @private {
    usz saved = scratch.used;
    defer catch scratch.used = saved;
    usz capacity;
    foreach (patch : patches) capacity += patch.boundary.vertices.len;
    if (!capacity) return {};
    if (capacity > uint::max / 2) return c3d::CAPACITY_EXCEEDED~;
    SurfacePointMap result = {
        .exact = reserve_elements(scratch, PlaneTriple, capacity)!,
        .positions = reserve_elements(scratch, Vec3, capacity)!,
        .vertices = reserve_elements(scratch, uint, capacity)!,
        .patch_offsets = reserve_elements(scratch, uint, patches.len + 1)!,
    };
    uint offset;
    foreach (uint patch, value : patches) {
        result.patch_offsets[patch] = offset;
        offset += (uint)value.boundary.vertices.len;
    }
    result.patch_offsets[^1] = offset;
    usz retained = scratch.used;
    defer scratch.used = retained;
    BoundaryPointIndex index = index_boundary_points(scratch, patches)!;
    uint previous = NO_SOLID_INDEX;
    uint count;
    foreach (point : index.order) {
        bool same = previous != NO_SOLID_INDEX;
        if (same) for (uint axis = 0; axis < SPACE_AXES; axis++) {
            if (compare_boundary_coordinate(
                scratch: scratch.exact,
                first: &index.points[previous],
                second: &index.points[point],
                axis: axis,
            )!) {
                same = false;
                break;
            }
        }
        if (!same) {
            result.exact[count] = index.points[point].vertex;
            result.positions[count] = rounded_source_position(scratch.exact, result.exact[count], grid)!;
            count++;
        }
        result.vertices[point] = count - 1;
        previous = point;
    }
    result.exact = result.exact[:count];
    result.positions = result.positions[:count];
    return result;
}
