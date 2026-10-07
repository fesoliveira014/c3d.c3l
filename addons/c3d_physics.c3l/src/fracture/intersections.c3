module c3d::physics::fracture;

import std::math;

fn Vec3 surface_position(SolidSurface* surface, uint identity) @private {
    return surface.source.geometry.positions[surface.topology.vertices[identity].representative];
}

fn uint[TRIANGLE_CORNERS] surface_triangle(SolidSurface* surface, uint face) @private {
    uint[TRIANGLE_CORNERS] identities;
    for (uint corner = 0; corner < TRIANGLE_CORNERS; corner++) {
        identities[corner] = surface.source.topology_vertices[surface.source.geometry.indices[(usz)face * TRIANGLE_CORNERS + corner]];
    }
    return identities;
}

fn int? surface_orientation(SolidSurface* surface, uint[HOMOGENEOUS_COMPONENTS] identities) @private {
    if (surface.grid.len) {
        GridPoint[HOMOGENEOUS_COMPONENTS] points;
        foreach (index, identity : identities) points[index] = surface.grid[identity];
        return grid_orientation(surface.exact, points);
    }
    Vec3[HOMOGENEOUS_COMPONENTS] points;
    foreach (index, identity : identities) points[index] = surface_position(surface, identity);
    return float_orientation(surface.exact, points);
}

fn int? surface_projection(SolidSurface* surface, uint[TRIANGLE_CORNERS] identities, uint dropped_axis) @private {
    if (surface.grid.len) {
        GridPoint[TRIANGLE_CORNERS] points;
        foreach (index, identity : identities) points[index] = surface.grid[identity];
        return projected_grid_orientation(surface.exact, points, dropped_axis);
    }
    Vec3[TRIANGLE_CORNERS] points;
    foreach (index, identity : identities) points[index] = surface_position(surface, identity);
    return projected_orientation(surface.exact, points, dropped_axis);
}

fn bool same_side(int[TRIANGLE_CORNERS] signs) @private {
    return (signs[0] > 0 && signs[1] > 0 && signs[2] > 0) || (signs[0] < 0 && signs[1] < 0 && signs[2] < 0);
}

fn bool same_side_or_boundary(int[TRIANGLE_CORNERS] signs) @private {
    return (signs[0] >= 0 && signs[1] >= 0 && signs[2] >= 0) || (signs[0] <= 0 && signs[1] <= 0 && signs[2] <= 0);
}

fn bool? projected_inside(
    SolidSurface* surface,
    uint identity,
    uint[TRIANGLE_CORNERS] triangle,
    uint dropped_axis,
) @private {
    int[TRIANGLE_CORNERS] signs;
    for (uint side = 0; side < TRIANGLE_CORNERS; side++) {
        signs[side] = surface_projection(surface, { triangle[side], triangle[(side + 1) % TRIANGLE_CORNERS], identity }, dropped_axis)!;
    }
    return same_side_or_boundary(signs);
}

fn bool? segment_conflict(
    SolidSurface* surface,
    uint[2] segment,
    int[2] sides,
    uint[TRIANGLE_CORNERS] triangle,
    uint dropped_axis,
) @private {
    foreach (index, identity : segment) {
        if (sides[index] != 0) continue;
        bool shared;
        foreach (corner : triangle) shared |= identity == corner;
        if (!shared && projected_inside(
            surface: surface,
            identity: identity,
            triangle: triangle,
            dropped_axis: dropped_axis,
        )!) return true;
    }
    if (sides[0] == 0 && sides[1] == 0) {
        for (uint side = 0; side < TRIANGLE_CORNERS; side++) {
            uint first = triangle[side];
            uint second = triangle[(side + 1) % TRIANGLE_CORNERS];
            int first_side = surface_projection(surface, { segment[0], segment[1], first }, dropped_axis)!;
            int second_side = surface_projection(surface, { segment[0], segment[1], second }, dropped_axis)!;
            if (first_side * second_side >= 0) continue;
            first_side = surface_projection(surface, { first, second, segment[0] }, dropped_axis)!;
            second_side = surface_projection(surface, { first, second, segment[1] }, dropped_axis)!;
            if (first_side * second_side < 0) return true;
        }
    } else if (sides[0] * sides[1] < 0) {
        int[TRIANGLE_CORNERS] edge_signs;
        for (uint side = 0; side < TRIANGLE_CORNERS; side++) {
            edge_signs[side] = surface_orientation(surface, { segment[0], segment[1], triangle[side], triangle[(side + 1) % TRIANGLE_CORNERS] })!;
        }
        if (same_side_or_boundary(edge_signs)) return true;
    }
    return false;
}

fn bool? triangles_conflict(SolidSurface* surface, uint first_face, uint second_face) @private {
    uint[TRIANGLE_CORNERS] first = surface_triangle(surface, first_face);
    uint[TRIANGLE_CORNERS] second = surface_triangle(surface, second_face);
    uint shared;
    foreach (left : first) foreach (right : second) shared += left == right ? 1 : 0;
    if (shared == TRIANGLE_CORNERS) return true;
    int[TRIANGLE_CORNERS] first_sides;
    int[TRIANGLE_CORNERS] second_sides;
    for (uint corner = 0; corner < TRIANGLE_CORNERS; corner++) {
        first_sides[corner] = surface_orientation(surface, { second[0], second[1], second[2], first[corner] })!;
        second_sides[corner] = surface_orientation(surface, { first[0], first[1], first[2], second[corner] })!;
    }
    if (same_side(first_sides) || same_side(second_sides)) return false;
    for (uint side = 0; side < TRIANGLE_CORNERS; side++) {
        uint next = (side + 1) % TRIANGLE_CORNERS;
        if (segment_conflict(
            surface: surface,
            segment: { first[side], first[next] },
            sides: { first_sides[side], first_sides[next] },
            triangle: second,
            dropped_axis: surface.projections[second_face],
        )!) return true;
        if (segment_conflict(
            surface: surface,
            segment: { second[side], second[next] },
            sides: { second_sides[side], second_sides[next] },
            triangle: first,
            dropped_axis: surface.projections[first_face],
        )!) return true;
    }
    return false;
}
