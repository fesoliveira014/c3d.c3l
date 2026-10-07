module c3d::physics::fracture;

import std::math;

<*
 @require hull.validated && !hull.grid.len
 @require original.validated && !original.grid.len
 @require hull.exact == original.exact
*>
fn Vec3? collision_hull_anchor(
    SolidSurface* hull,
    SolidSurface* original,
    SourceConstructions* source,
    float resolution,
) @private {
    Vec3 anchor = rounded_surface_centroid(hull, resolution)!;

    foreach (uint face, unused : hull.topology.shell_roots) {
        uint[TRIANGLE_CORNERS] triangle = surface_triangle(hull, face);
        if (float_orientation(hull.exact, {
            surface_position(hull, triangle[0]), surface_position(hull, triangle[1]),
            surface_position(hull, triangle[2]), anchor,
        })! >= 0) return NUMERICAL_FAILURE~;
    }

    if (!raw_point_is_occupied(original, source, anchor)!) return NUMERICAL_FAILURE~;

    return anchor;
}
