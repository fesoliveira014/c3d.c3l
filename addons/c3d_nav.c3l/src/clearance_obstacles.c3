module c3d::nav;

import std::math;
import c3d;

const uint MAX_CLEARANCE_BLOCK_VERTICES @local = MAX_VOLUME_VERTS + 8;

struct ClearanceBlockVertex @local {
    ClearancePoint point;
    PrecisionInterval height;
    PrecisionInterval headroom;
}

struct ClearanceBlockPolygon @local {
    ClearanceBlockVertex[MAX_CLEARANCE_BLOCK_VERTICES] vertices;
    uint count;
}

struct ClearanceBlockPlane @local {
    PrecisionInterval x;
    PrecisionInterval z;
    PrecisionInterval height;
    PrecisionInterval headroom;
    PrecisionInterval offset;
}

struct ClearanceBlockDistance @local {
    PrecisionInterval bounds;
    bool present;
}

fn bool? clearance_obstacle_meets(
    ClearanceSource* source,
    uint surface_index,
    uint fan,
    TileConfig* config,
    ClearanceRectangle square,
    PrecisionInterval radius,
    double interval_limit,
    Obstacle[] obstacles,
    VolumeRecord[] volumes,
) @private {
    ClearanceBlockPolygon base = clearance_block_fan(
        source: source,
        surface_index: surface_index,
        fan: fan,
        config: config,
    )!;
    clearance_block_clip(&base, { .headroom = precision_point(1)! })!;
    if (!base.count) return false;

    foreach (&obstacle : obstacles) {
        if (obstacle.state == EMPTY || obstacle.state == REMOVING) continue;
        ClearanceBlockPolygon polygon = base;
        PrecisionInterval low;
        PrecisionInterval high;
        switch (obstacle.kind) {
            case BOX:
                low = precision_point(obstacle.box.min.y)!;
                high = precision_point(obstacle.box.max.y)!;
            case ORIENTED_BOX:
                low = precision_subtract(precision_point(obstacle.position.y)!, precision_point(obstacle.half_extents.y)!)!;
                high = precision_add(precision_point(obstacle.position.y)!, precision_point(obstacle.half_extents.y)!)!;
            case CYLINDER:
                low = precision_point(obstacle.position.y)!;
                high = precision_add(low, precision_point(obstacle.height)!)!;
        }
        low = precision_subtract(low, precision_point(config.agent_height)!)!;
        clearance_block_height(
            polygon: &polygon,
            origin_y: source.origin.y,
            low: low,
            high: high,
        )!;
        if (!polygon.count) continue;
        ClearanceBlockDistance distance;
        switch (obstacle.kind) {
            case BOX:
                clearance_block_box(&polygon, source.origin, obstacle.box)!;
                distance = clearance_block_distance(&polygon, square)!;
            case ORIENTED_BOX:
                clearance_block_oriented_box(&polygon, source.origin, obstacle)!;
                distance = clearance_block_distance(&polygon, square)!;
            case CYLINDER:
                distance = clearance_block_disk_distance(
                    polygon: &polygon,
                    square: square,
                    centre: clearance_block_world_point(source.origin, obstacle.position)!,
                    disk_radius: precision_point(obstacle.radius)!,
                )!;
        }
        if (clearance_block_meets(distance, radius, interval_limit)!) return true;
    }

    foreach (&volume : volumes) {
        if (volume.area != NULL_AREA) continue;
        ClearanceBlockPolygon polygon = base;
        PrecisionInterval low;
        PrecisionInterval high;
        switch (volume.kind) {
            case BOX:
                low = precision_point(volume.box.min.y)!;
                high = precision_point(volume.box.max.y)!;
            case CONVEX:
                low = precision_point(volume.min_y)!;
                high = precision_point(volume.max_y)!;
            case CYLINDER:
                low = precision_point(volume.base.y)!;
                high = precision_add(low, precision_point(volume.height)!)!;
        }
        clearance_block_height(
            polygon: &polygon,
            origin_y: source.origin.y,
            low: low,
            high: high,
        )!;
        if (!polygon.count) continue;
        ClearanceBlockDistance distance;
        switch (volume.kind) {
            case BOX:
                clearance_block_box(&polygon, source.origin, volume.box)!;
                distance = clearance_block_distance(&polygon, square)!;
            case CONVEX:
                clearance_block_convex(&polygon, source.origin, volume)!;
                distance = clearance_block_distance(&polygon, square)!;
            case CYLINDER:
                distance = clearance_block_disk_distance(
                    polygon: &polygon,
                    square: square,
                    centre: clearance_block_world_point(source.origin, volume.base)!,
                    disk_radius: precision_point(volume.radius)!,
                )!;
        }
        if (clearance_block_meets(distance, radius, interval_limit)!) return true;
    }
    return false;
}

fn ClearanceBlockPolygon? clearance_block_fan(
    ClearanceSource* source,
    uint surface_index,
    uint fan,
    TileConfig* config,
) @local {
    if (surface_index >= source.surfaces.len || fan >= 4) return c3d::CAPACITY_EXCEEDED~;
    ClearanceSurface* surface = &source.surfaces[surface_index];
    uint[3] indices = { 4, fan, (fan + 1) & 3 };
    ClearanceBlockPolygon polygon = { .count = 3 };
    foreach (point, index : indices) {
        polygon.vertices[point] = {
            .point = clearance_source_point(
                source: source,
                column: surface.column,
                cell_x: index == 4 ? 0.5 : (double)DETAIL_CORNER_X[index],
                cell_z: index == 4 ? 0.5 : (double)DETAIL_CORNER_Z[index],
            )!,
            .height = precision_point(surface.heights[index])!,
            .headroom = surface.ceiling_open ? precision_point(1)! : precision_subtract(precision_subtract(
                precision_point(surface.ceilings[index])!, precision_point(surface.heights[index])!,
            )!, precision_point(config.agent_height)!)!,
        };
    }
    return polygon;
}

fn int? clearance_block_sign(PrecisionInterval value) @local {
    if (value.min > 0) return 1;
    if (value.max < 0) return -1;
    if (value.min == 0 && value.max == 0) return 0;
    return c3d::CAPACITY_EXCEEDED~;
}

fn PrecisionInterval? clearance_block_plane_value(ClearanceBlockPlane plane, ClearanceBlockVertex vertex) @local {
    PrecisionInterval value = precision_add(
        precision_multiply(plane.x, vertex.point.x)!, precision_multiply(plane.z, vertex.point.z)!,
    )!;
    value = precision_add(value, precision_multiply(plane.height, vertex.height)!)!;
    value = precision_add(value, precision_multiply(plane.headroom, vertex.headroom)!)!;
    return precision_add(value, plane.offset);
}

fn PrecisionInterval? clearance_block_lerp(PrecisionInterval first, PrecisionInterval last, PrecisionInterval fraction) @local {
    return precision_add(first, precision_multiply(precision_subtract(last, first)!, fraction)!);
}

fn ClearanceBlockVertex? clearance_block_vertex(
    ClearanceBlockVertex first,
    ClearanceBlockVertex last,
    PrecisionInterval fraction,
) @local {
    return {
        .point = {
            .x = clearance_block_lerp(first.point.x, last.point.x, fraction)!,
            .z = clearance_block_lerp(first.point.z, last.point.z, fraction)!,
        },
        .height = clearance_block_lerp(first.height, last.height, fraction)!,
        .headroom = clearance_block_lerp(first.headroom, last.headroom, fraction)!,
    };
}

fn void? clearance_block_append(ClearanceBlockPolygon* polygon, ClearanceBlockVertex vertex) @local {
    if (polygon.count == MAX_CLEARANCE_BLOCK_VERTICES) return c3d::CAPACITY_EXCEEDED~;
    polygon.vertices[polygon.count++] = vertex;
}

fn void? clearance_block_clip(ClearanceBlockPolygon* polygon, ClearanceBlockPlane plane) @local {
    if (!polygon.count) return;
    ClearanceBlockPolygon clipped;
    ClearanceBlockVertex previous = polygon.vertices[polygon.count - 1];
    PrecisionInterval previous_value = clearance_block_plane_value(plane, previous)!;
    int previous_sign = clearance_block_sign(previous_value)!;
    for (uint index = 0; index < polygon.count; index++) {
        ClearanceBlockVertex current = polygon.vertices[index];
        PrecisionInterval current_value = clearance_block_plane_value(plane, current)!;
        int current_sign = clearance_block_sign(current_value)!;
        if (previous_sign * current_sign < 0) {
            PrecisionInterval fraction = precision_divide(
                previous_value, precision_subtract(previous_value, current_value)!,
            )!;
            clearance_block_append(&clipped, clearance_block_vertex(previous, current, fraction)!)!;
        }
        if (current_sign >= 0) clearance_block_append(&clipped, current)!;
        previous = current;
        previous_value = current_value;
        previous_sign = current_sign;
    }
    *polygon = clipped;
}

fn void? clearance_block_height(
    ClearanceBlockPolygon* polygon,
    double origin_y,
    PrecisionInterval low,
    PrecisionInterval high,
) @local {
    clearance_block_clip(polygon, {
        .height = precision_point(1)!,
        .offset = precision_subtract(precision_point(origin_y)!, low)!,
    })!;
    clearance_block_clip(polygon, {
        .height = precision_point(-1)!,
        .offset = precision_subtract(high, precision_point(origin_y)!)!,
    })!;
}

fn ClearancePoint? clearance_block_world_point(Vec3 origin, Vec3 world) @local {
    return {
        .x = precision_subtract(precision_point(world.x)!, precision_point(origin.x)!)!,
        .z = precision_subtract(precision_point(world.z)!, precision_point(origin.z)!)!,
    };
}

fn void? clearance_block_box(ClearanceBlockPolygon* polygon, Vec3 origin, Aabb box) @local {
    ClearancePoint low = clearance_block_world_point(origin, box.min)!;
    ClearancePoint high = clearance_block_world_point(origin, box.max)!;
    clearance_block_clip(polygon, { .x = precision_point(1)!, .offset = precision_subtract(precision_point(0)!, low.x)! })!;
    clearance_block_clip(polygon, { .x = precision_point(-1)!, .offset = high.x })!;
    clearance_block_clip(polygon, { .z = precision_point(1)!, .offset = precision_subtract(precision_point(0)!, low.z)! })!;
    clearance_block_clip(polygon, { .z = precision_point(-1)!, .offset = high.z })!;
}

fn void? clearance_block_oriented_box(ClearanceBlockPolygon* polygon, Vec3 origin, Obstacle* obstacle) @local {
    ClearancePoint centre = clearance_block_world_point(origin, obstacle.position)!;
    PrecisionInterval cosine = precision_point(2.0 * obstacle.rotation[1])!;
    PrecisionInterval sine = precision_point(2.0 * obstacle.rotation[0])!;
    for (uint axis = 0; axis < 2; axis++) {
        PrecisionInterval x = axis ? precision_subtract(precision_point(0)!, sine)! : cosine;
        PrecisionInterval z = axis ? cosine : sine;
        PrecisionInterval along = precision_add(precision_multiply(x, centre.x)!, precision_multiply(z, centre.z)!)!;
        PrecisionInterval extent = precision_point(axis ? obstacle.half_extents.z : obstacle.half_extents.x)!;
        clearance_block_clip(polygon, { .x = x, .z = z, .offset = precision_subtract(extent, along)! })!;
        clearance_block_clip(polygon, {
            .x = precision_subtract(precision_point(0)!, x)!,
            .z = precision_subtract(precision_point(0)!, z)!,
            .offset = precision_add(extent, along)!,
        })!;
    }
}

fn ClearanceBlockPlane? clearance_block_edge_plane(ClearancePoint first, ClearancePoint last) @local {
    PrecisionInterval x = precision_subtract(first.z, last.z)!;
    PrecisionInterval z = precision_subtract(last.x, first.x)!;
    return {
        .x = x, .z = z,
        .offset = precision_subtract(precision_point(0)!, precision_add(
            precision_multiply(x, first.x)!, precision_multiply(z, first.z)!,
        )!)!,
    };
}

fn int? clearance_block_side(ClearancePoint first, ClearancePoint last, ClearancePoint point) @local {
    return precision_compare_products(
        first: precision_subtract(last.x, first.x)!,
        second: precision_subtract(point.z, first.z)!,
        third: precision_subtract(last.z, first.z)!,
        fourth: precision_subtract(point.x, first.x)!,
    );
}

fn PrecisionInterval? clearance_block_orientation(ClearancePoint[] points) @local {
    PrecisionInterval area = precision_point(0)!;
    for (usz index = 1; index + 1 < points.len; index++) {
        PrecisionInterval first_x = precision_subtract(points[index].x, points[0].x)!;
        PrecisionInterval first_z = precision_subtract(points[index].z, points[0].z)!;
        PrecisionInterval last_x = precision_subtract(points[index + 1].x, points[0].x)!;
        PrecisionInterval last_z = precision_subtract(points[index + 1].z, points[0].z)!;
        area = precision_add(area, precision_subtract(
            precision_multiply(first_x, last_z)!, precision_multiply(first_z, last_x)!,
        )!)!;
    }
    return area;
}

fn void? clearance_block_convex(ClearanceBlockPolygon* polygon, Vec3 origin, VolumeRecord* volume) @local {
    if (volume.vert_count < 3 || volume.vert_count > MAX_VOLUME_VERTS) return c3d::CAPACITY_EXCEEDED~;
    ClearancePoint[MAX_VOLUME_VERTS] points;
    for (uint index = 0; index < volume.vert_count; index++) {
        points[index] = clearance_block_world_point(origin, volume.verts[index])!;
    }
    int orientation = clearance_block_sign(clearance_block_orientation(points[:volume.vert_count])!)!;
    if (!orientation) return c3d::CAPACITY_EXCEEDED~;
    for (uint index = 0; index < volume.vert_count; index++) {
        uint next = (index + 1) % volume.vert_count;
        ClearanceBlockPlane plane = orientation > 0
            ? clearance_block_edge_plane(points[index], points[next])!
            : clearance_block_edge_plane(points[next], points[index])!;
        foreach (point : points[:volume.vert_count]) {
            if (clearance_block_side(points[index], points[next], point)! * orientation < 0) {
                return c3d::CAPACITY_EXCEEDED~;
            }
        }
        clearance_block_clip(polygon, plane)!;
    }
}

fn bool? clearance_block_contains(ClearanceBlockPolygon* polygon, ClearancePoint point) @local {
    if (polygon.count < 3) return false;
    ClearancePoint[MAX_CLEARANCE_BLOCK_VERTICES] points;
    for (uint index = 0; index < polygon.count; index++) points[index] = polygon.vertices[index].point;
    int orientation = clearance_block_sign(clearance_block_orientation(points[:polygon.count])!)!;
    if (!orientation) return false;
    bool uncertain;
    for (uint index = 0; index < polygon.count; index++) {
        int? side = clearance_block_side(points[index], points[(index + 1) % polygon.count], point);
        if (catch side) {
            uncertain = true;
            continue;
        }
        if (side * orientation < 0) return false;
    }
    if (uncertain) return c3d::CAPACITY_EXCEEDED~;
    return true;
}

fn PrecisionInterval? clearance_block_cross(
    PrecisionInterval first_x,
    PrecisionInterval first_z,
    PrecisionInterval last_x,
    PrecisionInterval last_z,
) @local {
    PrecisionInterval value = precision_subtract(
        precision_multiply(first_x, last_z)!, precision_multiply(first_z, last_x)!,
    )!;
    if (value.min <= 0 && value.max >= 0) {
        int? sign = precision_compare_products(
            first: first_x,
            second: last_z,
            third: first_z,
            fourth: last_x,
        );
        if (catch sign) return value;
        if (sign == 0) return precision_point(0);
    }
    return value;
}

fn bool? clearance_block_contains_radial(
    ClearanceBlockPolygon* polygon,
    ClearancePoint centre,
    ClearancePoint corner,
    PrecisionInterval scale,
) @local {
    if (polygon.count < 3) return false;
    ClearancePoint[MAX_CLEARANCE_BLOCK_VERTICES] points;
    for (uint index = 0; index < polygon.count; index++) points[index] = polygon.vertices[index].point;
    int orientation = clearance_block_sign(clearance_block_orientation(points[:polygon.count])!)!;
    if (!orientation) return false;
    PrecisionInterval radial_x = precision_subtract(corner.x, centre.x)!;
    PrecisionInterval radial_z = precision_subtract(corner.z, centre.z)!;
    bool uncertain;
    for (uint index = 0; index < polygon.count; index++) {
        ClearancePoint first = points[index];
        ClearancePoint last = points[(index + 1) % polygon.count];
        PrecisionInterval edge_x = precision_subtract(last.x, first.x)!;
        PrecisionInterval edge_z = precision_subtract(last.z, first.z)!;
        PrecisionInterval offset = clearance_block_cross(
            first_x: edge_x,
            first_z: edge_z,
            last_x: precision_subtract(centre.x, first.x)!,
            last_z: precision_subtract(centre.z, first.z)!,
        )!;
        PrecisionInterval radial = clearance_block_cross(
            first_x: edge_x,
            first_z: edge_z,
            last_x: radial_x,
            last_z: radial_z,
        )!;
        int? side = clearance_block_sign(precision_add(offset, precision_multiply(scale, radial)!)!);
        if (catch side) {
            uncertain = true;
            continue;
        }
        if (side * orientation < 0) return false;
    }
    if (uncertain) return c3d::CAPACITY_EXCEEDED~;
    return true;
}

fn ClearancePoint[4] clearance_block_square_corners(ClearanceRectangle square) @local {
    return {
        { .x = square.min_x, .z = square.min_z },
        { .x = square.max_x, .z = square.min_z },
        { .x = square.max_x, .z = square.max_z },
        { .x = square.min_x, .z = square.max_z },
    };
}

fn void clearance_block_minimum(ClearanceBlockDistance* result, PrecisionInterval candidate) @local {
    if (!result.present) {
        result.bounds = candidate;
        result.present = true;
        return;
    }
    result.bounds.min = math::min(result.bounds.min, candidate.min);
    result.bounds.max = math::min(result.bounds.max, candidate.max);
}

fn ClearanceBlockDistance? clearance_block_distance(ClearanceBlockPolygon* polygon, ClearanceRectangle square) @local {
    ClearanceBlockDistance result;
    if (!polygon.count) return result;
    foreach (corner : clearance_block_square_corners(square)) {
        if (clearance_block_contains(polygon, corner)!) return { .bounds = precision_point(0)!, .present = true };
    }
    for (uint index = 0; index < polygon.count; index++) {
        clearance_block_minimum(&result, clearance_segment_rectangle_distance(
            polygon.vertices[index].point, polygon.vertices[(index + 1) % polygon.count].point, square,
        )!);
    }
    return result;
}

fn PrecisionInterval? clearance_block_disk_value(ClearancePoint point, ClearancePoint centre, PrecisionInterval radius) @local {
    return precision_subtract(precision_add(
        precision_square(precision_subtract(point.x, centre.x)!)!,
        precision_square(precision_subtract(point.z, centre.z)!)!,
    )!, precision_square(radius)!);
}

fn void? clearance_block_disk_segment(
    ClearanceBlockDistance* result,
    ClearancePoint first,
    ClearancePoint last,
    ClearancePoint centre,
    PrecisionInterval disk_radius,
    ClearanceRectangle square,
) @local {
    PrecisionInterval x = precision_subtract(last.x, first.x)!;
    PrecisionInterval z = precision_subtract(last.z, first.z)!;
    PrecisionInterval length_squared = precision_add(precision_square(x)!, precision_square(z)!)!;
    if (length_squared.max == 0) {
        if (clearance_block_sign(clearance_block_disk_value(first, centre, disk_radius)!)! <= 0) {
            clearance_block_minimum(result, clearance_point_rectangle_distance(first, square)!);
        }
        return;
    }
    if (length_squared.min <= 0) return c3d::CAPACITY_EXCEEDED~;
    PrecisionInterval offset_x = precision_subtract(first.x, centre.x)!;
    PrecisionInterval offset_z = precision_subtract(first.z, centre.z)!;
    PrecisionInterval dot = precision_add(precision_multiply(offset_x, x)!, precision_multiply(offset_z, z)!)!;
    PrecisionInterval constant = clearance_block_disk_value(first, centre, disk_radius)!;
    PrecisionInterval discriminant = precision_subtract(precision_square(dot)!, precision_multiply(length_squared, constant)!)!;
    int discriminant_sign = clearance_block_sign(discriminant)!;
    if (discriminant_sign < 0) return;
    PrecisionInterval root = precision_sqrt(discriminant)!;
    PrecisionInterval negative_dot = precision_subtract(precision_point(0)!, dot)!;
    PrecisionInterval enter = precision_divide(precision_subtract(negative_dot, root)!, length_squared)!;
    PrecisionInterval leave = precision_divide(precision_add(negative_dot, root)!, length_squared)!;
    if (leave.max < 0 || enter.min > 1) return;
    if ((leave.min < 0 && leave.max >= 0) || (enter.min <= 1 && enter.max > 1)) return c3d::CAPACITY_EXCEEDED~;
    enter = precision_clamp(enter, 0, 1)!;
    leave = precision_clamp(leave, 0, 1)!;
    if (enter.min > leave.max) return;
    if (enter.max > leave.min && discriminant_sign != 0) return c3d::CAPACITY_EXCEEDED~;
    ClearancePoint clipped_first = {
        .x = clearance_block_lerp(first.x, last.x, enter)!,
        .z = clearance_block_lerp(first.z, last.z, enter)!,
    };
    ClearancePoint clipped_last = {
        .x = clearance_block_lerp(first.x, last.x, leave)!,
        .z = clearance_block_lerp(first.z, last.z, leave)!,
    };
    clearance_block_minimum(result, discriminant_sign == 0
        ? clearance_point_rectangle_distance(clipped_first, square)!
        : clearance_segment_rectangle_distance(clipped_first, clipped_last, square)!);
}

fn ClearanceBlockDistance? clearance_block_disk_distance(
    ClearanceBlockPolygon* polygon,
    ClearanceRectangle square,
    ClearancePoint centre,
    PrecisionInterval disk_radius,
) @local {
    ClearanceBlockDistance result;
    if (!polygon.count) return result;
    if (disk_radius.min <= 0) return c3d::CAPACITY_EXCEEDED~;
    ClearancePoint[4] corners = clearance_block_square_corners(square);
    foreach (corner : corners) {
        if (clearance_block_sign(clearance_block_disk_value(corner, centre, disk_radius)!)! <= 0
            && clearance_block_contains(polygon, corner)!) return { .bounds = precision_point(0)!, .present = true };
    }
    for (uint index = 0; index < polygon.count; index++) {
        clearance_block_disk_segment(
            result: &result,
            first: polygon.vertices[index].point,
            last: polygon.vertices[(index + 1) % polygon.count].point,
            centre: centre,
            disk_radius: disk_radius,
            square: square,
        )!;
    }
    // Arc minima occur at an axis extremum, toward a rectangle corner, or at a clipped edge endpoint.
    for (uint axis = 0; axis < 2; axis++) {
        for (uint direction = 0; direction < 2; direction++) {
            PrecisionInterval offset = direction ? disk_radius : precision_subtract(precision_point(0)!, disk_radius)!;
            ClearancePoint point = centre;
            if (axis) {
                point.z = precision_add(point.z, offset)!;
            } else {
                point.x = precision_add(point.x, offset)!;
            }
            if (clearance_block_contains(polygon, point)!) {
                clearance_block_minimum(&result, clearance_point_rectangle_distance(point, square)!);
            }
        }
    }
    foreach (corner : corners) {
        PrecisionInterval x = precision_subtract(corner.x, centre.x)!;
        PrecisionInterval z = precision_subtract(corner.z, centre.z)!;
        PrecisionInterval length = precision_sqrt(precision_add(precision_square(x)!, precision_square(z)!)!)!;
        if (length.max == 0) continue;
        if (length.min <= 0) return c3d::CAPACITY_EXCEEDED~;
        PrecisionInterval scale = precision_divide(disk_radius, length)!;
        ClearancePoint point = {
            .x = precision_add(centre.x, precision_multiply(x, scale)!)!,
            .z = precision_add(centre.z, precision_multiply(z, scale)!)!,
        };
        if (clearance_block_contains_radial(
            polygon: polygon,
            centre: centre,
            corner: corner,
            scale: scale,
        )!) {
            clearance_block_minimum(&result, clearance_point_rectangle_distance(point, square)!);
        }
    }
    return result;
}

fn bool? clearance_block_meets(ClearanceBlockDistance distance, PrecisionInterval radius, double interval_limit) @local {
    if (!distance.present) return false;
    PrecisionInterval signed_distance = precision_subtract(distance.bounds, radius)!;
    PrecisionInterval width = precision_subtract(precision_point(signed_distance.max)!, precision_point(signed_distance.min)!)!;
    if (width.max > interval_limit) return c3d::CAPACITY_EXCEEDED~;
    return signed_distance.min <= 0;
}
