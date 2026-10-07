module c3d::physics::fracture;

const uint CONTAINMENT_RAY_AXIS @local = 2;
const uint CONTAINMENT_FIRST_AXIS @local = 0;
const uint CONTAINMENT_SECOND_AXIS @local = 1;

<*
 @require surface.validated
 @require source_root != target_root
 @require source_root < surface.topology.shell_roots.len && target_root < surface.topology.shell_roots.len
 @require surface.topology.shell_roots[source_root] == source_root && surface.topology.shell_roots[target_root] == target_root
*>
fn bool? shell_contains(
    SolidSurface* surface,
    uint source_root,
    uint target_root,
    ulong* candidate_faces,
) @private {
    uint query = surface_triangle(surface, source_root)[0];
    long[SPACE_AXES] position;
    for (uint axis = 0; axis < SPACE_AXES; axis++) position[axis] = surface_coordinate_key(surface, query, axis);
    bool inside;
    uint current;
    while (current != NO_SOLID_INDEX) {
        SolidBvhNode* node = &surface.nodes[current];
        if (!containment_ray_overlaps(&node.bounds, position)) {
            current = node.escape;
        } else if (node.count != 1) {
            current = node.child;
        } else {
            uint face = surface.order[node.first];
            if (surface.topology.shell_roots[face] == target_root) {
                (*candidate_faces)++;
                if (symbolic_ray_crosses(surface, surface_triangle(surface, face), query)!) inside = !inside;
            }
            current = node.escape;
        }
    }
    return inside;
}

fn bool containment_ray_overlaps(SolidBounds* bounds, long[SPACE_AXES] position) @local {
    for (uint axis = 0; axis < CONTAINMENT_RAY_AXIS; axis++) {
        if (position[axis] < bounds.lower[axis] || position[axis] > bounds.upper[axis]) return false;
    }
    return position[CONTAINMENT_RAY_AXIS] <= bounds.upper[CONTAINMENT_RAY_AXIS];
}

fn bool? symbolic_ray_crosses(SolidSurface* surface, uint[TRIANGLE_CORNERS] triangle, uint query) @local {
    int orientation = surface_projection(surface, triangle, CONTAINMENT_RAY_AXIS)!;
    if (!orientation) return false;
    for (uint side = 0; side < TRIANGLE_CORNERS; side++) {
        int sign = symbolic_projected_side(
            surface: surface,
            first: triangle[side],
            second: triangle[(side + 1) % TRIANGLE_CORNERS],
            query: query,
        )!;
        if (sign != orientation) return false;
    }
    int forward = surface_orientation(surface, { triangle[0], triangle[1], triangle[2], query })!;
    return forward * orientation < 0;
}

fn int? symbolic_projected_side(
    SolidSurface* surface,
    uint first,
    uint second,
    uint query,
) @local {
    int constant = surface_projection(surface, { first, second, query }, CONTAINMENT_RAY_AXIS)!;
    if (constant) return constant;
    long first_key = surface_coordinate_key(surface, first, CONTAINMENT_SECOND_AXIS);
    long second_key = surface_coordinate_key(surface, second, CONTAINMENT_SECOND_AXIS);
    if (first_key != second_key) return first_key < second_key ? -1 : 1;
    first_key = surface_coordinate_key(surface, first, CONTAINMENT_FIRST_AXIS);
    second_key = surface_coordinate_key(surface, second, CONTAINMENT_FIRST_AXIS);
    return first_key < second_key ? 1 : first_key > second_key ? -1 : 0;
}
