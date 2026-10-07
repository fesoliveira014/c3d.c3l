module c3d::physics::fracture;

import c3d;

<* Select a regularized operation on two solid volumes. *>
enum BooleanOperation {
    UNION,
    INTERSECTION,
    DIFFERENCE,
}

fn void? insert_boolean_faces(
    SolidScratch* scratch,
    SolidPartition* partition,
    SolidSurface* surface,
    SourceConstructions* source,
) @local {
    foreach (uint face, &plane : source.faces) {
        PartitionCell* current = partition.first;
        while (current) {
            PartitionCell* next = current.next;
            partition.face_tests++;
            if (source_face_crosses_cell(
                scratch: scratch,
                surface: surface,
                source: source,
                face: face,
                cell: &current.cell,
            )!) {
                if (partition.cell_count == uint::max) return c3d::CAPACITY_EXCEEDED~;
                CellSplit split = split_convex_cell(scratch, &current.cell, plane)!;
                PartitionCell* positive = &reserve_elements(scratch, PartitionCell, 1)![0];
                *positive = { .cell = split.positive, .next = next };
                *current = { .cell = split.negative, .next = positive };
                partition.cell_count++;
            }
            current = next;
        }
    }
    return;
}

fn SolidPartition? partition_boolean_cells(
    SolidScratch* scratch,
    SolidSurface* first,
    SourceConstructions* first_source,
    SolidSurface* second,
    SourceConstructions* second_source,
    BooleanOperation operation,
) @private {
    usz saved = scratch.used;
    defer catch scratch.used = saved;
    SolidBounds bounds = joined_solid_bounds(first.nodes[0].bounds, second.nodes[0].bounds);
    PartitionCell* root = &reserve_elements(scratch, PartitionCell, 1)![0];
    *root = { .cell = create_bounds_cell(scratch, first, &bounds)! };
    SolidPartition result = { .first = root, .cell_count = 1 };
    insert_boolean_faces(
        scratch: scratch,
        partition: &result,
        surface: first,
        source: first_source,
    )!;
    insert_boolean_faces(
        scratch: scratch,
        partition: &result,
        surface: second,
        source: second_source,
    )!;
    for (PartitionCell* cell = root; cell; cell = cell.next) {
        bool first_inside = cell_is_occupied(
            surface: first,
            source: first_source,
            cell: &cell.cell,
            candidate_faces: &result.ray_faces,
        )!;
        bool second_inside = cell_is_occupied(
            surface: second,
            source: second_source,
            cell: &cell.cell,
            candidate_faces: &result.ray_faces,
        )!;
        switch (operation) {
            case BooleanOperation.UNION: cell.occupied = first_inside || second_inside;
            case BooleanOperation.INTERSECTION: cell.occupied = first_inside && second_inside;
            case BooleanOperation.DIFFERENCE: cell.occupied = first_inside && !second_inside;
        }
        result.occupied_count += cell.occupied ? 1 : 0;
    }
    return result;
}
