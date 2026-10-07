module c3d::physics::fracture;

import c3d;
import std::math;

struct MaterialFace @local {
    BoundaryCellFace source;
    BoundaryPointBounds bounds;
}

struct MaterialFaceIndex @local {
    BoundaryPoint[] points;
    MaterialFace[] faces;
    uint[] order;
    BoundaryPointNode[] nodes;
    uint dropped_axis;
}

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

fn int? compare_material_faces(
    ExactScratch* scratch,
    MaterialFaceIndex* index,
    uint first,
    uint second,
) @local {
    for (uint offset = 1; offset < SPACE_AXES; offset++) {
        uint axis = (index.dropped_axis + offset) % SPACE_AXES;
        int order = compare_boundary_coordinate(
            scratch: scratch,
            first: &index.points[index.faces[first].bounds.lower[axis]],
            second: &index.points[index.faces[second].bounds.lower[axis]],
            axis: axis,
        )!;
        if (order) return order;
    }
    return 0;
}

fn void? sort_material_faces(SolidScratch* scratch, MaterialFaceIndex* index) @local {
    usz saved = scratch.used;
    defer scratch.used = saved;
    uint[] temporary = reserve_elements(scratch, uint, index.order.len)!;
    uint[] input = index.order;
    uint[] output = temporary;
    for (usz width = 1; width < input.len; width *= 2) {
        for (usz start = 0; start < input.len; start += 2 * width) {
            usz middle = math::min(start + width, (usz)input.len);
            usz end = math::min(start + 2 * width, (usz)input.len);
            usz left = start;
            usz right = middle;
            for (usz written = start; written < end; written++) {
                bool take_left = right == end;
                if (left < middle && right < end) take_left = compare_material_faces(
                    scratch: scratch.exact,
                    index: index,
                    first: input[left],
                    second: input[right],
                )! <= 0;
                output[written] = take_left ? input[left++] : input[right++];
            }
        }
        uint[] swap = input;
        input = output;
        output = swap;
    }
    if (input.ptr != index.order.ptr) index.order[..] = input[..];
    return;
}

fn MaterialFaceIndex? index_material_faces(
    SolidScratch* scratch,
    BoundaryCellFace[] faces,
    usz forward_count,
) @local {
    usz point_count;
    foreach (face : faces) point_count += face.cell.faces[face.face].count;
    if (point_count > uint::max || forward_count > uint::max / 2) return c3d::CAPACITY_EXCEEDED~;
    MaterialFaceIndex index = {
        .points = reserve_elements(scratch, BoundaryPoint, point_count)!,
        .faces = reserve_elements(scratch, MaterialFace, faces.len)!,
        .order = reserve_elements(scratch, uint, forward_count)!,
        .dropped_axis = patch_projection(faces[0].plane),
    };
    uint forward;
    uint reversed = (uint)forward_count;
    uint written;
    foreach (entry : faces) {
        CellFace face = entry.cell.faces[entry.face];
        uint first = written;
        for (uint corner = face.first; corner < face.first + face.count; corner++) {
            index.points[written++] = cache_boundary_point(
                scratch, entry.cell.vertices[entry.cell.corners[corner].vertex],
            )!;
        }
        MaterialFace cached = {
            .source = entry,
            .bounds = boundary_point_bounds(
                scratch: scratch.exact,
                points: index.points,
                first: first,
                count: face.count,
            )!,
        };
        index.faces[face.reversed ? reversed++ : forward++] = cached;
    }
    foreach (uint face, &ordered : index.order) *ordered = face;
    sort_material_faces(scratch, &index)!;
    index.nodes = reserve_elements(scratch, BoundaryPointNode, (usz)forward_count * 2 - 1)!;
    index.nodes[0] = { .count = (uint)forward_count, .escape = NO_SOLID_INDEX };
    written = 1;
    for (uint node_index = 0; node_index < written; node_index++) {
        BoundaryPointNode* node = &index.nodes[node_index];
        if (node.count == 1) {
            node.bounds = index.faces[index.order[node.first]].bounds;
            continue;
        }
        uint left = node.count / 2;
        node.child = written;
        index.nodes[written] = { .first = node.first, .count = left, .escape = written + 1 };
        index.nodes[written + 1] = { .first = node.first + left, .count = node.count - left, .escape = node.escape };
        written += 2;
    }
    for (uint node_index = written; node_index > 0; node_index--) {
        BoundaryPointNode* node = &index.nodes[node_index - 1];
        if (node.count == 1) continue;
        node.bounds = join_boundary_point_bounds(
            scratch: scratch.exact,
            points: index.points,
            first: index.nodes[node.child].bounds,
            second: index.nodes[node.child + 1].bounds,
        )!;
    }
    return index;
}

fn bool? material_bounds_overlap(
    ExactScratch* scratch,
    MaterialFaceIndex* index,
    BoundaryPointBounds first,
    BoundaryPointBounds second,
) @local {
    for (uint offset = 1; offset < SPACE_AXES; offset++) {
        uint axis = (index.dropped_axis + offset) % SPACE_AXES;
        if (compare_boundary_coordinate(
            scratch: scratch,
            first: &index.points[first.upper[axis]],
            second: &index.points[second.lower[axis]],
            axis: axis,
        )! <= 0) return false;
        if (compare_boundary_coordinate(
            scratch: scratch,
            first: &index.points[second.upper[axis]],
            second: &index.points[first.lower[axis]],
            axis: axis,
        )! <= 0) return false;
    }
    return true;
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

fn SolidPartition[]? partition_material_components(
    SolidScratch* scratch,
    SolidPartition* partition,
    ulong* clip_count = null,
) @private {
    if (clip_count) *clip_count = 0;
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
        usz forward_count;
        for (usz face = begin; face < end; face++) {
            forward_count += faces[face].cell.faces[faces[face].face].reversed ? 0 : 1;
        }
        if (forward_count && forward_count < end - begin) {
            usz saved_plane = scratch.used;
            defer scratch.used = saved_plane;
            MaterialFaceIndex index = index_material_faces(scratch, faces[begin:end - begin], forward_count)!;
            foreach (second : index.faces[forward_count:(usz)index.faces.len - forward_count]) {
                uint current = 0;
                while (current != NO_SOLID_INDEX) {
                    BoundaryPointNode* node = &index.nodes[current];
                    if (!material_bounds_overlap(
                        scratch: scratch.exact,
                        index: &index,
                        first: second.bounds,
                        second: node.bounds,
                    )!) {
                        current = node.escape;
                    } else if (node.count != 1) {
                        current = node.child;
                    } else {
                        BoundaryCellFace first = index.faces[index.order[node.first]].source;
                        uint first_root = material_component_root(parents, material_cell_index(cells, first.cell));
                        uint second_root = material_component_root(
                            parents, material_cell_index(cells, second.source.cell),
                        );
                        if (first_root != second_root) {
                            if (clip_count) (*clip_count)++;
                            if (material_faces_overlap(scratch, first, second.source)!) {
                                if (first_root < second_root) {
                                    parents[second_root] = first_root;
                                } else {
                                    parents[first_root] = second_root;
                                }
                            }
                        }
                        current = node.escape;
                    }
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
