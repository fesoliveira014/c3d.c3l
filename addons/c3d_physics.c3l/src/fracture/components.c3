module c3d::physics::fracture;

fn uint material_component_root(uint[] parents, uint index) @local {
    while (parents[index] != index) {
        parents[index] = parents[parents[index]];
        index = parents[index];
    }
    return index;
}

fn uint material_cell_index(PartitionCell[] cells, ConvexCell* cell) @local {
    return (uint)(((uptr)cell - (uptr)&cells[0].cell) / PartitionCell::size);
}

fn bool? material_faces_overlap(
    SolidScratch* scratch,
    BoundaryCellFace first,
    BoundaryCellFace second,
) @local {
    usz saved = scratch.used;
    defer scratch.used = saved;
    ConvexCell* cell = first.cell;
    CellFace face = cell.faces[first.face];
    usz capacity = (usz)face.count + second.cell.faces.len;
    FaceClipVertex[] input = reserve_elements(scratch, FaceClipVertex, capacity)!;
    FaceClipVertex[] output = reserve_elements(scratch, FaceClipVertex, capacity)!;
    for (uint offset = 0; offset < face.count; offset++) {
        uint corner = face.first + offset;
        uint previous = offset ? corner - 1 : face.first + face.count - 1;
        uint adjacent = cell.corners[cell.corners[previous].twin].face;
        input[offset] = {
            .point = cell.vertices[cell.corners[corner].vertex],
            .incoming = { face.plane, cell.faces[adjacent].plane },
        };
    }
    usz count = face.count;
    foreach (uint index, boundary : second.cell.faces) {
        if (index == second.face) continue;
        count = clip_face_polygon(
            scratch: scratch.exact,
            input: input[:count],
            output: output,
            source: face.plane,
            boundary: boundary,
        )!;
        if (count < TRIANGLE_CORNERS) return false;
        FaceClipVertex[] swap = input;
        input = output;
        output = swap;
    }
    for (usz index = 2; index < count; index++) {
        if (planar_orientation(
            scratch: scratch.exact,
            vertices: { input[0].point, input[index - 1].point, input[index].point },
            dropped_axis: patch_projection(face.plane),
        )!) return true;
    }
    return false;
}

fn SolidPartition[]? partition_material_components(SolidScratch* scratch, SolidPartition* partition) @private {
    if (!partition.occupied_count) return {};
    usz saved = scratch.used;
    defer catch scratch.used = saved;
    SolidPartition[] components = reserve_elements(scratch, SolidPartition, partition.occupied_count)!;
    PartitionCell[] cells = reserve_elements(scratch, PartitionCell, partition.occupied_count)!;
    foreach (&component : components) *component = {};
    uint count;
    for (PartitionCell* cell = partition.first; cell; cell = cell.next) {
        if (!cell.occupied) continue;
        cells[count] = { .cell = cell.cell, .occupied = true };
        if (count) cells[count - 1].next = &cells[count];
        count++;
    }
    usz retained = scratch.used;
    defer scratch.used = retained;
    uint[] parents = reserve_elements(scratch, uint, count)!;
    PartitionCell*[] tails = reserve_elements(scratch, PartitionCell*, count)!;
    foreach (uint index, &parent : parents) *parent = index;
    SolidPartition copied = { .first = &cells[0], .cell_count = count, .occupied_count = count };
    BoundaryCellFace[] faces = index_boundary_cell_faces(scratch, &copied)!;
    for (usz begin = 0; begin < faces.len;) {
        usz end = begin + 1;
        while (end < faces.len && !compare_exact_planes(faces[begin].plane, faces[end].plane)) end++;
        for (usz left = begin; left < end; left++) {
            BoundaryCellFace first = faces[left];
            for (usz right = left + 1; right < end; right++) {
                BoundaryCellFace second = faces[right];
                if (first.cell.faces[first.face].reversed == second.cell.faces[second.face].reversed) continue;
                uint first_root = material_component_root(parents, material_cell_index(cells, first.cell));
                uint second_root = material_component_root(parents, material_cell_index(cells, second.cell));
                if (first_root == second_root || !material_faces_overlap(scratch, first, second)!) continue;
                if (first_root < second_root) {
                    parents[second_root] = first_root;
                } else {
                    parents[first_root] = second_root;
                }
            }
        }
        begin = end;
    }
    foreach (uint index, &cell : cells) {
        uint root = material_component_root(parents, index);
        SolidPartition* component = &components[root];
        cell.next = null;
        if (component.first) {
            tails[root].next = cell;
        } else {
            component.first = cell;
        }
        tails[root] = cell;
        component.cell_count++;
        component.occupied_count++;
    }
    count = 0;
    foreach (component : components) if (component.first) components[count++] = component;
    return components[:count];
}
