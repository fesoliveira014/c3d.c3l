module c3d::physics::fracture;

import std::math;
import std::sort;

const uint BOX_PLANES @private = 6;
const uint BOX_VERTICES @private = 8;
const uint BOX_FACE_CORNERS @private = 4;

struct CellFace @private {
    ExactPlane* plane;
    uint first;
    uint count;
    bool reversed;
}

struct CellCorner @private {
    uint vertex;
    uint twin;
    uint face;
}

struct ConvexCell @private {
    PlaneTriple[] vertices;
    CellFace[] faces;
    CellCorner[] corners;
}

struct CellSplit @private {
    ConvexCell negative;
    ConvexCell positive;
}

fn uint next_cell_corner(ConvexCell* cell, uint corner) @private {
    CellFace* face = &cell.faces[cell.corners[corner].face];
    return corner + 1 == face.first + face.count ? face.first : corner + 1;
}

fn void? pair_cell_corners(SolidScratch* scratch, ConvexCell* cell) @private {
    usz saved = scratch.used;
    defer scratch.used = saved;
    SolidEdge[] edges = reserve_elements(scratch, SolidEdge, cell.corners.len)!;
    foreach (uint index, corner : cell.corners) {
        uint second = cell.corners[next_cell_corner(cell, index)].vertex;
        edges[index] = {
            .low = math::min(corner.vertex, second),
            .high = math::max(corner.vertex, second),
            .corner = index,
        };
    }
    sort::quicksort(edges, &compare_solid_edges);
    for (usz index = 0; index < edges.len; index += 2) {
        cell.corners[edges[index].corner].twin = edges[index + 1].corner;
        cell.corners[edges[index + 1].corner].twin = edges[index].corner;
    }
    return;
}

fn void? bounds_axis_plane(
    ExactScratch* scratch,
    ExactPlane* plane,
    uint axis,
    long bound,
    bool quantized,
) @private {
    uint saved = scratch.count;
    defer scratch.count = saved;
    WideInteger*[HOMOGENEOUS_COMPONENTS] coefficients;
    foreach (&coefficient : coefficients) *coefficient = scratch.take()!;
    set_integer(coefficients[axis], 1);
    if (quantized) {
        set_integer(coefficients[SPACE_AXES], -(int128)bound);
    } else {
        uint bits = (uint)(bound < 0 ? -bound : bound);
        if (bound > 0) bits |= (uint)1 << FLOAT_SIGN_BIT;
        integer_from_float(coefficients[SPACE_AXES], bitcast(bits, float));
    }
    (void)normalize_plane(scratch, plane, coefficients)!;
    return;
}

fn ConvexCell? create_bounds_cell(SolidScratch* scratch, SolidSurface* surface) @private {
    usz saved = scratch.used;
    defer catch scratch.used = saved;
    ExactPlane[] planes = reserve_elements(scratch, ExactPlane, BOX_PLANES)!;
    SolidBounds bounds = surface.nodes[0].bounds;
    for (uint axis = 0; axis < SPACE_AXES; axis++) {
        for (uint end = 0; end < 2; end++) {
            bounds_axis_plane(
                scratch: scratch.exact,
                plane: &planes[axis * 2 + end],
                axis: axis,
                bound: end ? bounds.upper[axis] : bounds.lower[axis],
                quantized: surface.grid.len != 0,
            )!;
        }
    }
    ConvexCell cell = {
        .vertices = reserve_elements(scratch, PlaneTriple, BOX_VERTICES)!,
        .faces = reserve_elements(scratch, CellFace, BOX_PLANES)!,
        .corners = reserve_elements(scratch, CellCorner, BOX_PLANES * BOX_FACE_CORNERS)!,
    };
    foreach (uint vertex, &point : cell.vertices) {
        for (uint axis = 0; axis < SPACE_AXES; axis++) (*point)[axis] = &planes[axis * 2 + ((vertex >> axis) & 1)];
    }
    uint[BOX_FACE_CORNERS][BOX_PLANES] polygons = {
        { 0, 4, 6, 2 }, { 1, 3, 7, 5 }, { 0, 1, 5, 4 },
        { 2, 6, 7, 3 }, { 0, 2, 3, 1 }, { 4, 5, 7, 6 },
    };
    foreach (uint face, polygon : polygons) {
        cell.faces[face] = {
            .plane = &planes[face], .first = face * BOX_FACE_CORNERS,
            .count = BOX_FACE_CORNERS, .reversed = !(face & 1),
        };
        foreach (uint index, vertex : polygon) {
            cell.corners[face * BOX_FACE_CORNERS + index] = { .vertex = vertex, .face = face };
        }
    }
    pair_cell_corners(scratch, &cell)!;
    return cell;
}
