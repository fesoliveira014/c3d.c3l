module c3d::physics::fracture;

import std::math;
import std::sort;

enum SolidFailure @private {
    NONE,
    DEGENERATE_TRIANGLE,
    TRIANGLE_INTERSECTION,
    DEGENERATE_SHELL,
    WRONG_ORIENTATION,
}

struct SolidDiagnostic @private {
    SolidFailure reason;
    uint first_face;
    uint second_face;
    uint shell_index;
}

struct SolidBounds @private {
    long[SPACE_AXES] lower;
    long[SPACE_AXES] upper;
}

struct SolidBvhNode @private {
    SolidBounds bounds;
    uint first;
    uint count;
    uint child;
    uint escape;
}

struct SolidSurface @private {
    SolidMeshView source;
    SolidTopology topology;
    GridPoint[] grid;
    ExactScratch* exact;
    uint[] projections;
    SolidBounds[] bounds;
    uint[] order;
    SolidBvhNode[] nodes;
    ulong candidate_pairs;
    bool validated;
}

struct SurfaceSortContext @private {
    SolidSurface* surface;
    uint axis;
}

fn long surface_coordinate_key(SolidSurface* surface, uint identity, uint axis) @private {
    if (surface.grid.len) return surface.grid[identity][axis];
    // Integer ordering preserves subnormal bounds under fast floating point.
    uint bits = bitcast(surface_position(surface, identity)[axis], uint);
    long magnitude = bits & ~((uint)1 << FLOAT_SIGN_BIT);
    return (bits >> FLOAT_SIGN_BIT) ? -magnitude : magnitude;
}

fn int compare_surface_faces(uint first, uint second, SurfaceSortContext* context) @private {
    SolidBounds* left = &context.surface.bounds[first];
    SolidBounds* right = &context.surface.bounds[second];
    long left_center = left.lower[context.axis] + left.upper[context.axis];
    long right_center = right.lower[context.axis] + right.upper[context.axis];
    if (left_center != right_center) return left_center < right_center ? -1 : 1;
    return first < second ? -1 : first > second ? 1 : 0;
}

fn SolidBounds joined_solid_bounds(SolidBounds first, SolidBounds second) @private {
    SolidBounds result;
    for (uint axis = 0; axis < SPACE_AXES; axis++) {
        result.lower[axis] = math::min(first.lower[axis], second.lower[axis]);
        result.upper[axis] = math::max(first.upper[axis], second.upper[axis]);
    }
    return result;
}

fn bool overlapping_solid_bounds(SolidBounds first, SolidBounds second) @private {
    for (uint axis = 0; axis < SPACE_AXES; axis++) {
        if (first.upper[axis] < second.lower[axis] || second.upper[axis] < first.lower[axis]) return false;
    }
    return true;
}

fn void build_surface_tree(SolidSurface* surface) @private {
    uint count = 1;
    surface.nodes[0] = { .count = (uint)surface.order.len, .escape = NO_SOLID_INDEX };
    for (uint index = 0; index < count; index++) {
        SolidBvhNode* node = &surface.nodes[index];
        node.bounds = surface.bounds[surface.order[node.first]];
        foreach (face : surface.order[node.first:node.count]) node.bounds = joined_solid_bounds(node.bounds, surface.bounds[face]);
        if (node.count == 1) continue;
        SurfaceSortContext context = { .surface = surface };
        for (uint axis = 1; axis < SPACE_AXES; axis++) {
            if (node.bounds.upper[axis] - node.bounds.lower[axis]
                > node.bounds.upper[context.axis] - node.bounds.lower[context.axis]) context.axis = axis;
        }
        sort::quicksort(surface.order[node.first:node.count], &compare_surface_faces, &context);
        uint left_count = node.count / 2;
        node.child = count;
        surface.nodes[count] = { .first = node.first, .count = left_count, .escape = count + 1 };
        surface.nodes[count + 1] = { .first = node.first + left_count, .count = node.count - left_count, .escape = node.escape };
        count += 2;
    }
}

fn void? check_surface_geometry(SolidSurface* surface, SolidDiagnostic* diagnostic) @private {
    *diagnostic = { .first_face = NO_SOLID_INDEX, .second_face = NO_SOLID_INDEX, .shell_index = NO_SOLID_INDEX };
    surface.validated = false;
    surface.candidate_pairs = 0;
    foreach (uint face, &bounds : surface.bounds) {
        uint[TRIANGLE_CORNERS] triangle = surface_triangle(surface, face);
        uint projection;
        while (projection < SPACE_AXES && surface_projection(surface, triangle, projection)! == 0) projection++;
        if (projection == SPACE_AXES) {
            *diagnostic = { .reason = SolidFailure.DEGENERATE_TRIANGLE, .first_face = face, .second_face = face, .shell_index = NO_SOLID_INDEX };
            return INVALID_SOLID~;
        }
        surface.projections[face] = projection;
        for (uint axis = 0; axis < SPACE_AXES; axis++) {
            long first = surface_coordinate_key(surface, triangle[0], axis);
            bounds.lower[axis] = first;
            bounds.upper[axis] = first;
            for (uint corner = 1; corner < TRIANGLE_CORNERS; corner++) {
                long value = surface_coordinate_key(surface, triangle[corner], axis);
                bounds.lower[axis] = math::min(bounds.lower[axis], value);
                bounds.upper[axis] = math::max(bounds.upper[axis], value);
            }
        }
        surface.order[face] = face;
    }
    build_surface_tree(surface);
    foreach (uint face, bounds : surface.bounds) {
        uint current;
        while (current != NO_SOLID_INDEX) {
            SolidBvhNode* node = &surface.nodes[current];
            if (!overlapping_solid_bounds(bounds, node.bounds)) {
                current = node.escape;
            } else if (node.count != 1) {
                current = node.child;
            } else {
                uint other = surface.order[node.first];
                if (other > face) {
                    surface.candidate_pairs++;
                    if (triangles_conflict(surface, face, other)!) {
                        *diagnostic = { .reason = SolidFailure.TRIANGLE_INTERSECTION, .first_face = face, .second_face = other, .shell_index = NO_SOLID_INDEX };
                        return INVALID_SOLID~;
                    }
                }
                current = node.escape;
            }
        }
    }
    surface.validated = true;
    return;
}

fn SolidSurface? build_solid_surface(
    SolidScratch* scratch,
    SolidMeshView source,
    SolidDiagnostic* diagnostic,
) @private {
    *diagnostic = { .first_face = NO_SOLID_INDEX, .second_face = NO_SOLID_INDEX, .shell_index = NO_SOLID_INDEX };
    usz saved = scratch.used;
    defer catch scratch.used = saved;
    SolidSurface surface = {
        .source = source,
        .topology = build_solid_topology(scratch, source)!,
        .exact = scratch.exact,
        .projections = reserve_elements(scratch, uint, source.triangle_materials.len)!,
        .bounds = reserve_elements(scratch, SolidBounds, source.triangle_materials.len)!,
        .order = reserve_elements(scratch, uint, source.triangle_materials.len)!,
        .nodes = reserve_elements(scratch, SolidBvhNode, 2 * source.triangle_materials.len - 1)!,
    };
    check_surface_geometry(&surface, diagnostic)!;
    return surface;
}
