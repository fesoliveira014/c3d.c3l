module c3d::physics::fracture;

import c3d;

struct PartitionCell @private {
    ConvexCell cell;
    PartitionCell* next;
    bool occupied;
}

struct SolidPartition @private {
    PartitionCell* first;
    uint cell_count;
    uint occupied_count;
    ulong face_tests;
    ulong ray_faces;
}

fn SolidPartition? partition_solid(
    SolidScratch* scratch,
    SolidSurface* surface,
    SourceConstructions* source,
) @private {
    usz saved = scratch.used;
    defer catch scratch.used = saved;
    PartitionCell* first = &reserve_elements(scratch, PartitionCell, 1)![0];
    *first = { .cell = create_bounds_cell(scratch, surface)! };
    SolidPartition result = { .first = first, .cell_count = 1 };
    foreach (uint face, &plane : source.faces) {
        PartitionCell* current = first;
        while (current) {
            PartitionCell* next = current.next;
            result.face_tests++;
            if (source_face_crosses_cell(
                scratch: scratch, surface: surface, source: source, face: face, cell: &current.cell,
            )!) {
                if (result.cell_count == uint::max) return c3d::CAPACITY_EXCEEDED~;
                CellSplit split = split_convex_cell(scratch, &current.cell, plane)!;
                PartitionCell* positive = &reserve_elements(scratch, PartitionCell, 1)![0];
                *positive = { .cell = split.positive, .next = next };
                *current = { .cell = split.negative, .next = positive };
                result.cell_count++;
            }
            current = next;
        }
    }
    for (PartitionCell* current = first; current; current = current.next) {
        current.occupied = cell_is_occupied(
            surface: surface, source: source, cell: &current.cell, candidate_faces: &result.ray_faces,
        )!;
        result.occupied_count += current.occupied ? 1 : 0;
    }
    return result;
}
