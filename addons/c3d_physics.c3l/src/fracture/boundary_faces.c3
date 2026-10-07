module c3d::physics::fracture;

import std::sort;

struct BoundaryCellFace @private {
    ExactPlane* plane;
    ConvexCell* cell;
    uint face;
}

fn int compare_boundary_cell_faces(BoundaryCellFace first, BoundaryCellFace second) @local {
    return compare_exact_planes(first.plane, second.plane);
}

fn BoundaryCellFace[]? index_boundary_cell_faces(SolidScratch* scratch, SolidPartition* partition) @private {
    usz count;
    for (PartitionCell* cell = partition.first; cell; cell = cell.next) if (cell.occupied) count += cell.cell.faces.len;
    BoundaryCellFace[] faces = reserve_elements(scratch, BoundaryCellFace, count)!;
    count = 0;
    for (PartitionCell* cell = partition.first; cell; cell = cell.next) {
        if (!cell.occupied) continue;
        foreach (uint index, face : cell.cell.faces) faces[count++] = { .plane = face.plane, .cell = &cell.cell, .face = index };
    }
    sort::quicksort(faces, &compare_boundary_cell_faces);
    return faces;
}

fn BoundaryCellFace[] boundary_plane_faces(BoundaryCellFace[] faces, ExactPlane* plane) @private {
    usz first;
    usz end = faces.len;
    while (first < end) {
        usz middle = first + (end - first) / 2;
        if (compare_exact_planes(faces[middle].plane, plane) < 0) {
            first = middle + 1;
        } else {
            end = middle;
        }
    }
    end = first;
    while (end < faces.len && !compare_exact_planes(faces[end].plane, plane)) end++;
    return faces[first:end - first];
}
