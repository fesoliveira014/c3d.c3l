module c3d::physics::fracture;

import c3d;

struct CellBuilder @private {
    ConvexCell cell;
    uint[] local_vertices;
    uint[] working_vertices;
    uint vertex_count;
    uint face_count;
    uint corner_count;
}

fn void CellBuilder.append(&self, uint working, PlaneTriple[] points) {
    if (self.local_vertices[working] == NO_SOLID_INDEX) {
        self.local_vertices[working] = self.vertex_count;
        self.working_vertices[self.vertex_count] = working;
        self.cell.vertices[self.vertex_count++] = points[working];
    }
    self.cell.corners[self.corner_count++] = { .vertex = self.local_vertices[working], .face = self.face_count };
}

fn void CellBuilder.finish_face(&self, CellFace face, uint start) {
    uint count = self.corner_count - start;
    if (count < TRIANGLE_CORNERS) {
        self.corner_count = start;
        return;
    }
    face.first = start;
    face.count = count;
    self.cell.faces[self.face_count++] = face;
}

fn void CellBuilder.trim(&self) {
    self.cell.vertices = self.cell.vertices[:self.vertex_count];
    self.cell.faces = self.cell.faces[:self.face_count];
    self.cell.corners = self.cell.corners[:self.corner_count];
}

fn CellBuilder? create_cell_builder(SolidScratch* scratch, ConvexCell* parent, usz vertices) @private {
    usz faces = parent.faces.len + 1;
    usz corners = parent.corners.len + parent.faces.len + vertices;
    if (vertices > uint::max || faces > uint::max || corners > uint::max) return c3d::CAPACITY_EXCEEDED~;
    CellBuilder builder = {
        .cell = {
            .vertices = reserve_elements(scratch, PlaneTriple, vertices)!,
            .faces = reserve_elements(scratch, CellFace, faces)!,
            .corners = reserve_elements(scratch, CellCorner, corners)!,
        },
        .local_vertices = reserve_elements(scratch, uint, vertices)!,
        .working_vertices = reserve_elements(scratch, uint, vertices)!,
    };
    builder.local_vertices[..] = NO_SOLID_INDEX;
    return builder;
}

fn void clip_cell_faces(
    CellBuilder* builder,
    ConvexCell* parent,
    PlaneTriple[] points,
    int[] sides,
    uint[] crossings,
    bool positive,
) @private {
    foreach (face : parent.faces) {
        uint count;
        for (uint index = face.first; index < face.first + face.count; index++) {
            int side = sides[parent.corners[index].vertex];
            if (positive ? side >= 0 : side <= 0) count++;
            if (crossings[index] != NO_SOLID_INDEX) count++;
        }
        if (count < TRIANGLE_CORNERS) continue;
        uint start = builder.corner_count;
        for (uint index = face.first; index < face.first + face.count; index++) {
            uint vertex = parent.corners[index].vertex;
            if (positive ? sides[vertex] >= 0 : sides[vertex] <= 0) builder.append(vertex, points);
            if (crossings[index] != NO_SOLID_INDEX) builder.append(crossings[index], points);
        }
        builder.finish_face(face, start);
    }
}

fn void? cap_cell_pair(
    SolidScratch* scratch,
    CellBuilder* negative,
    CellBuilder* positive,
    PlaneTriple[] points,
    int[] sides,
    ExactPlane* cut,
) @private {
    usz saved = scratch.used;
    defer scratch.used = saved;
    uint[] successor = reserve_elements(scratch, uint, negative.vertex_count)!;
    successor[..] = NO_SOLID_INDEX;
    uint first = NO_SOLID_INDEX;
    foreach (face : negative.cell.faces[:negative.face_count]) {
        for (uint index = face.first; index < face.first + face.count; index++) {
            uint start = negative.cell.corners[index].vertex;
            uint end = negative.cell.corners[index + 1 == face.first + face.count ? face.first : index + 1].vertex;
            if (sides[negative.working_vertices[start]] || sides[negative.working_vertices[end]]) continue;
            successor[end] = start;
            if (first == NO_SOLID_INDEX || end < first) first = end;
        }
    }
    uint negative_start = negative.corner_count;
    uint vertex = first;
    do {
        negative.append(negative.working_vertices[vertex], points);
        vertex = successor[vertex];
    } while (vertex != first);
    negative.finish_face({ .plane = cut }, negative_start);
    uint positive_start = positive.corner_count;
    for (uint index = negative.corner_count; index > negative_start; index--) {
        uint local = negative.cell.corners[index - 1].vertex;
        positive.append(negative.working_vertices[local], points);
    }
    positive.finish_face({ .plane = cut, .reversed = true }, positive_start);
    return;
}

fn CellSplit? split_convex_cell(SolidScratch* scratch, ConvexCell* parent, ExactPlane* cut) @private {
    usz saved = scratch.used;
    defer catch scratch.used = saved;
    int[] original_sides = reserve_elements(scratch, int, parent.vertices.len)!;
    bool has_negative;
    bool has_positive;
    foreach (index, point : parent.vertices) {
        int side = plane_side(scratch.exact, cut, point)!;
        original_sides[index] = side;
        has_negative |= side < 0;
        has_positive |= side > 0;
    }
    if (!has_negative || !has_positive) {
        scratch.used = saved;
        if (has_positive) return { .positive = *parent };
        return { .negative = *parent };
    }
    usz crossing_count;
    foreach (uint index, corner : parent.corners) {
        if (index > corner.twin) continue;
        uint end = parent.corners[next_cell_corner(parent, index)].vertex;
        if (original_sides[corner.vertex] * original_sides[end] < 0) crossing_count++;
    }
    usz point_count = parent.vertices.len + crossing_count;
    if (point_count > uint::max) return c3d::CAPACITY_EXCEEDED~;
    PlaneTriple[] points = reserve_elements(scratch, PlaneTriple, point_count)!;
    points[:parent.vertices.len] = parent.vertices[..];
    int[] sides = reserve_elements(scratch, int, point_count)!;
    sides[:parent.vertices.len] = original_sides[..];
    sides[parent.vertices.len:crossing_count] = 0;
    uint[] crossings = reserve_elements(scratch, uint, parent.corners.len)!;
    crossings[..] = NO_SOLID_INDEX;
    uint point_index = (uint)parent.vertices.len;
    foreach (uint index, corner : parent.corners) {
        if (index > corner.twin) continue;
        uint end = parent.corners[next_cell_corner(parent, index)].vertex;
        if (original_sides[corner.vertex] * original_sides[end] >= 0) continue;
        points[point_index] = {
            parent.faces[corner.face].plane, parent.faces[parent.corners[corner.twin].face].plane, cut,
        };
        crossings[index] = point_index;
        crossings[corner.twin] = point_index++;
    }
    CellBuilder negative = create_cell_builder(scratch, parent, point_count)!;
    CellBuilder positive = create_cell_builder(scratch, parent, point_count)!;
    clip_cell_faces(builder: &negative, parent: parent, points: points, sides: sides, crossings: crossings, positive: false);
    clip_cell_faces(builder: &positive, parent: parent, points: points, sides: sides, crossings: crossings, positive: true);
    cap_cell_pair(scratch: scratch, negative: &negative, positive: &positive, points: points, sides: sides, cut: cut)!;
    negative.trim();
    positive.trim();
    pair_cell_corners(scratch, &negative.cell)!;
    pair_cell_corners(scratch, &positive.cell)!;
    return { .negative = negative.cell, .positive = positive.cell };
}
