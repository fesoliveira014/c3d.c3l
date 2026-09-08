module geometry_example;

import std::io;
import std::math;
import c3d::geometry;
import c3d::maths;
import cg;

fn void print_geometry(String label, Geometry* geometry) @local {
    io::printfn("  %s: %d vertices, %d indices, bounds (%.2f, %.2f, %.2f) to (%.2f, %.2f, %.2f)",
        label, geometry.positions.len, geometry.indices.len,
        geometry.bounds.min.x, geometry.bounds.min.y, geometry.bounds.min.z,
        geometry.bounds.max.x, geometry.bounds.max.y, geometry.bounds.max.z);
}

fn void free_geometry(Geometry* geometry) @local {
    free(geometry.positions.ptr);
    free(geometry.normals.ptr);
    free(geometry.tangents.ptr);
    free(geometry.uv0.ptr);
    free(geometry.indices.ptr);
    *geometry = {};
}

fn int main() {
    io::printn("primitives");
    Geometry box = geometry::box(mem, 1, 1, 1);
    defer free_geometry(&box);
    Geometry ground = geometry::plane(
        allocator:  mem,
        width:      4,
        depth:      4,
        segments_x: 2,
        segments_z: 2,
    );
    defer free_geometry(&ground);
    Geometry ball = geometry::sphere(mem, 0.5f);
    defer free_geometry(&ball);
    Geometry rock = geometry::icosphere(mem, 1, 2)!!;
    defer free_geometry(&rock);
    print_geometry("box", &box);
    print_geometry("plane", &ground);
    print_geometry("sphere", &ball);
    print_geometry("icosphere", &rock);

    io::printn("tangents on the box");
    box.compute_tangents(mem);
    Vec4 tangent = box.tangents[0];
    io::printfn("  first tangent (%.1f, %.1f, %.1f) handedness %.0f", tangent.x, tangent.y, tangent.z, tangent.w);

    io::printn("merge of box and plane");
    Geometry[2] parts = { box, ground };
    Geometry merged = geometry::merge(mem, parts[..]);
    defer free_geometry(&merged);
    print_geometry("merged", &merged);

    io::printn("half-edge round trip");
    cg::HalfEdgeMesh mesh = geometry::to_half_edge(mem, &box)!!;
    defer mesh.destroy();
    io::printfn("  half-edge faces %d", mesh.faces.len);
    Geometry flat = geometry::from_half_edge(mem, &mesh, smooth_normals: false)!!;
    defer free_geometry(&flat);
    print_geometry("flat", &flat);
    return 0;
}
