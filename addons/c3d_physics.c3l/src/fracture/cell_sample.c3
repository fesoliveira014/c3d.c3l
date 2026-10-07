module c3d::physics::fracture;

import std::time;

alias HomogeneousPoint @private = WideInteger*[HOMOGENEOUS_COMPONENTS];

fn void? mean_cell_vertices(
    ExactScratch* scratch,
    HomogeneousPoint output,
    PlaneTriple[HOMOGENEOUS_COMPONENTS] vertices,
) @private {
    std::time::Clock started = begin_exact_measurement(scratch);
    defer finish_exact_measurement(scratch, started);
    uint saved = scratch.count;
    defer scratch.count = saved;
    HomogeneousPoint[HOMOGENEOUS_COMPONENTS] points;
    foreach (uint index, &point : points) {
        foreach (&coordinate : *point) *coordinate = scratch.take()!;
        construct_point(scratch, *point, vertices[index])!;
    }
    WideInteger* product = scratch.take()!;
    WideInteger* temporary = scratch.take()!;
    set_integer(output[SPACE_AXES], HOMOGENEOUS_COMPONENTS);
    foreach (point : points) {
        multiply_integer(product, output[SPACE_AXES].view(), point[SPACE_AXES].view())!;
        copy_integer(output[SPACE_AXES], product.view());
    }
    for (uint axis = 0; axis < SPACE_AXES; axis++) {
        set_integer(output[axis], 0);
        foreach (uint index, point : points) {
            copy_integer(product, point[axis].view());
            foreach (uint other, factor : points) {
                if (other == index) continue;
                multiply_integer(temporary, product.view(), factor[SPACE_AXES].view())!;
                copy_integer(product, temporary.view());
            }
            add_integer(temporary, output[axis].view(), product.view())!;
            copy_integer(output[axis], temporary.view());
        }
    }
    return;
}

fn HomogeneousPoint? sample_cell_interior(ExactScratch* scratch, ConvexCell* cell) @private {
    uint saved = scratch.count;
    defer catch scratch.count = saved;
    CellFace face = cell.faces[0];
    PlaneTriple[HOMOGENEOUS_COMPONENTS] vertices = {
        cell.vertices[cell.corners[face.first].vertex],
        cell.vertices[cell.corners[face.first + 1].vertex],
        {}, {},
    };
    foreach (point : cell.vertices) {
        if (plane_side(scratch, face.plane, point)!) {
            vertices[SPACE_AXES] = point;
            break;
        }
    }
    for (uint corner = 2; corner < face.count; corner++) {
        vertices[2] = cell.vertices[cell.corners[face.first + corner].vertex];
        if (exact_vertex_orientation(scratch, vertices)!) break;
    }
    HomogeneousPoint sample;
    foreach (&coordinate : sample) *coordinate = scratch.take()!;
    mean_cell_vertices(scratch, sample, vertices)!;
    return sample;
}

fn int? homogeneous_plane_side(ExactScratch* scratch, ExactPlane* plane, HomogeneousPoint point) @private {
    std::time::Clock started = begin_exact_measurement(scratch);
    defer finish_exact_measurement(scratch, started);
    uint saved = scratch.count;
    defer scratch.count = saved;
    WideInteger* result = scratch.take()!;
    WideInteger* product = scratch.take()!;
    WideInteger* sum = scratch.take()!;
    for (uint axis = 0; axis < HOMOGENEOUS_COMPONENTS; axis++) {
        multiply_integer(product, plane.coefficients[axis].view(), point[axis].view())!;
        add_integer(sum, result.view(), product.view())!;
        copy_integer(result, sum.view());
    }
    return integer_sign(result.view());
}
