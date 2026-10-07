module c3d::physics::fracture;

import c3d;

struct CollisionCell @private {
    ConvexCell cell;
    PlaneTriple[] key;
}

struct CollisionCellMerge @private {
    bool joined;
    ConvexCell cell;
}

fn int? compare_collision_vertices(ExactScratch* scratch, PlaneTriple first, PlaneTriple second) @private {
    int order = compare_planar_points(
        scratch: scratch, first: first, second: second, dropped_axis: 2,
    )!;
    if (order) return order;
    return compare_planar_points(
        scratch: scratch, first: first, second: second, dropped_axis: 0,
    );
}

fn PlaneTriple[]? collision_cell_key(SolidScratch* scratch, ConvexCell* cell) @private {
    PlaneTriple[] key = reserve_elements(scratch, PlaneTriple, cell.vertices.len)!;
    key[..] = cell.vertices[..];
    for (usz index = 1; index < key.len; index++) {
        PlaneTriple value = key[index];
        usz position = index;
        while (position && compare_collision_vertices(scratch.exact, key[position - 1], value)! > 0) {
            key[position] = key[position - 1];
            position--;
        }
        key[position] = value;
    }
    return key;
}

fn int? compare_collision_cells(ExactScratch* scratch, CollisionCell first, CollisionCell second) @private {
    usz count = first.key.len < second.key.len ? first.key.len : second.key.len;
    for (usz index = 0; index < count; index++) {
        int order = compare_collision_vertices(scratch, first.key[index], second.key[index])!;
        if (order) return order;
    }
    return first.key.len < second.key.len ? -1 : first.key.len > second.key.len ? 1 : 0;
}

fn void? sort_collision_cells(ExactScratch* scratch, CollisionCell[] cells) @private {
    for (usz index = 1; index < cells.len; index++) {
        CollisionCell value = cells[index];
        usz position = index;
        while (position && compare_collision_cells(scratch, cells[position - 1], value)! > 0) {
            cells[position] = cells[position - 1];
            position--;
        }
        cells[position] = value;
    }
    return;
}

fn bool? collision_constraints_contain(
    ExactScratch* scratch,
    ConvexCell* first,
    ConvexCell* second,
    ExactPlane* shared,
) @private {
    foreach (face : first.faces) {
        if (!compare_exact_planes(face.plane, shared)) continue;
        foreach (point : second.vertices) {
            int side = plane_side(scratch, face.plane, point)!;
            if (side && (side > 0) != face.reversed) return false;
        }
    }
    return true;
}

fn ConvexCell? collision_pair_boundary(
    SolidScratch* scratch,
    ConvexCell* first,
    ConvexCell* second,
    ExactPlane* shared,
) @private {
    PartitionCell[2] parts = {
        { .cell = *first, .occupied = true },
        { .cell = *second, .occupied = true },
    };
    parts[0].next = &parts[1];
    SolidPartition partition = { .first = &parts[0], .cell_count = 2, .occupied_count = 2 };
    BoundaryCellFace[] faces = index_boundary_cell_faces(scratch, &partition)!;
    ConvexCell result = {
        .vertices = reserve_elements(scratch, PlaneTriple, first.vertices.len + second.vertices.len)!,
        .faces = reserve_elements(scratch, CellFace, first.faces.len + second.faces.len)!,
        .corners = reserve_elements(scratch, CellCorner, first.corners.len + second.corners.len)!,
    };
    uint vertex_count;
    uint face_count;
    uint corner_count;
    foreach (usz index, entry : faces) {
        if (!compare_exact_planes(entry.plane, shared)) continue;
        if (index && !compare_exact_planes(faces[index - 1].plane, entry.plane)) continue;
        usz saved = scratch.used;
        defer scratch.used = saved;
        PlanarSegment[] segments = collect_boundary_segments(
            scratch: scratch, partition: &partition, plane: entry.plane, faces: faces,
        )!;
        BoundaryPatch patch = create_boundary_patch(
            scratch: scratch, plane: entry.plane, segments: segments,
            reversed: entry.cell.faces[entry.face].reversed,
        )!;
        if (patch.contours.len != 1 || patch.contours[0].hole) return NUMERICAL_FAILURE~;
        result.faces[face_count] = {
            .plane = entry.plane, .first = corner_count,
            .count = (uint)patch.corners.len, .reversed = patch.reversed,
        };
        foreach (corner : patch.corners) {
            PlaneTriple point = patch.boundary.vertices[corner];
            uint vertex;
            while (vertex < vertex_count && !same_vertex(scratch.exact, result.vertices[vertex], point)!) vertex++;
            if (vertex == vertex_count) result.vertices[vertex_count++] = point;
            result.corners[corner_count++] = { .vertex = vertex, .face = face_count };
        }
        face_count++;
    }
    result.vertices = result.vertices[:vertex_count];
    result.faces = result.faces[:face_count];
    result.corners = result.corners[:corner_count];
    pair_cell_corners(scratch, &result)!;
    return result;
}

fn CollisionCellMerge? merge_collision_pair(
    SolidScratch* scratch,
    ConvexCell* first,
    ConvexCell* second,
    uint max_vertices,
) @private {
    usz saved = scratch.used;
    defer catch scratch.used = saved;
    foreach (first_face : first.faces) {
        foreach (second_face : second.faces) {
            if (first_face.reversed == second_face.reversed
                || compare_exact_planes(first_face.plane, second_face.plane)) continue;
            if (!collision_constraints_contain(
                scratch: scratch.exact, first: first, second: second, shared: first_face.plane,
            )! || !collision_constraints_contain(
                scratch: scratch.exact, first: second, second: first, shared: first_face.plane,
            )!) continue;
            ConvexCell cell = collision_pair_boundary(
                scratch: scratch, first: first, second: second, shared: first_face.plane,
            )!;
            if (cell.vertices.len > max_vertices) {
                scratch.used = saved;
                return {};
            }
            return { .joined = true, .cell = cell };
        }
    }
    return {};
}

fn CollisionCell[]? merge_collision_cells(
    SolidScratch* scratch,
    SolidPartition* partition,
    uint max_vertices,
) @private {
    usz saved = scratch.used;
    defer catch scratch.used = saved;
    CollisionCell[] cells = reserve_elements(scratch, CollisionCell, partition.occupied_count)!;
    uint count;
    for (PartitionCell* entry = partition.first; entry; entry = entry.next) {
        if (!entry.occupied) continue;
        cells[count++] = { .cell = entry.cell, .key = collision_cell_key(scratch, &entry.cell)! };
    }
    bool joined = true;
    while (joined) {
        joined = false;
        sort_collision_cells(scratch.exact, cells)!;
        for (uint first = 0; first < cells.len && !joined; first++) {
            for (uint second = first + 1; second < cells.len; second++) {
                CollisionCellMerge merged = merge_collision_pair(
                    scratch: scratch, first: &cells[first].cell,
                    second: &cells[second].cell, max_vertices: max_vertices,
                )!;
                if (!merged.joined) continue;
                cells[first] = { .cell = merged.cell, .key = collision_cell_key(scratch, &merged.cell)! };
                for (uint index = second + 1; index < cells.len; index++) cells[index - 1] = cells[index];
                cells = cells[:cells.len - 1];
                joined = true;
                break;
            }
        }
    }
    return cells;
}
