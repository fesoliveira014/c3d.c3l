module c3d::physics::fracture;

import std::time;
import std::math;

const uint RAW_EDGE_NORMAL_BITS @private = 278;
const uint RAW_EDGE_OFFSET_BITS @private = 557;
const uint GRID_EDGE_NORMAL_BITS @private = 31;
const uint GRID_EDGE_OFFSET_BITS @private = 62;

$assert PLANE_LIMBS * INTEGER_LIMB_BITS >= RAW_EDGE_NORMAL_BITS;
$assert PLANE_LIMBS * INTEGER_LIMB_BITS >= RAW_EDGE_OFFSET_BITS;
$assert PLANE_LIMBS * INTEGER_LIMB_BITS >= GRID_EDGE_NORMAL_BITS;
$assert PLANE_LIMBS * INTEGER_LIMB_BITS >= GRID_EDGE_OFFSET_BITS;

struct SourceEdge @private {
    ExactPlane plane;
    uint owner_corner;
    uint[2] vertices;
}

struct SourceConstructions @private {
    ExactPlane[] faces;
    bool[] reversed;
    SourceEdge[] edges;
    uint[] corner_edges;
    PlaneTriple[] vertices;
}

fn void? edge_support_plane(
    SolidSurface* surface,
    ExactPlane* output,
    uint owner_corner,
    ExactPlane* owner_plane,
) @private {
    std::time::Clock started = begin_exact_measurement(surface.exact);
    defer finish_exact_measurement(surface.exact, started);
    uint saved = surface.exact.count;
    defer surface.exact.count = saved;
    WideInteger*[HOMOGENEOUS_COMPONENTS] coefficients;
    foreach (&coefficient : coefficients) *coefficient = surface.exact.take()!;
    uint dropped_axis;
    while (!owner_plane.coefficients[dropped_axis].used) dropped_axis++;
    uint first_axis = (dropped_axis + 1) % SPACE_AXES;
    uint second_axis = (dropped_axis + 2) % SPACE_AXES;
    uint[TRIANGLE_CORNERS] triangle = surface_triangle(surface, owner_corner / TRIANGLE_CORNERS);
    uint[2] vertices = { triangle[owner_corner % TRIANGLE_CORNERS], triangle[(owner_corner + 1) % TRIANGLE_CORNERS] };
    WideInteger*[2][2] points;
    foreach (uint endpoint, identity : vertices) {
        for (uint component = 0; component < 2; component++) {
            uint axis = component ? second_axis : first_axis;
            points[endpoint][component] = surface.exact.take()!;
            if (surface.grid.len) {
                set_integer(points[endpoint][component], surface.grid[identity][axis]);
            } else {
                integer_from_float(points[endpoint][component], surface_position(surface, identity)[axis]);
            }
        }
    }
    WideInteger* first_product = surface.exact.take()!;
    WideInteger* second_product = surface.exact.take()!;
    add_integer(coefficients[first_axis], points[0][1].view(), negate_integer(points[1][1].view()))!;
    add_integer(coefficients[second_axis], points[1][0].view(), negate_integer(points[0][0].view()))!;
    multiply_integer(first_product, points[0][0].view(), points[1][1].view())!;
    multiply_integer(second_product, points[0][1].view(), points[1][0].view())!;
    add_integer(coefficients[SPACE_AXES], first_product.view(), negate_integer(second_product.view()))!;
    surface.exact.count = saved + HOMOGENEOUS_COMPONENTS;
    (void)normalize_plane(surface.exact, output, coefficients)!;
    return;
}

fn SourceConstructions? build_source_constructions(SolidScratch* scratch, SolidSurface* surface) @private {
    usz saved = scratch.used;
    defer catch scratch.used = saved;
    SourceConstructions source = {
        .faces = reserve_elements(scratch, ExactPlane, surface.topology.shell_roots.len)!,
        .reversed = reserve_elements(scratch, bool, surface.topology.shell_roots.len)!,
        .edges = reserve_elements(scratch, SourceEdge, surface.topology.twins.len / 2)!,
        .corner_edges = reserve_elements(scratch, uint, surface.topology.twins.len)!,
        .vertices = reserve_elements(scratch, PlaneTriple, surface.topology.vertices.len)!,
    };
    foreach (uint face, &plane : source.faces) {
        uint[TRIANGLE_CORNERS] triangle = surface_triangle(surface, face);
        if (surface.grid.len) {
            GridPoint[TRIANGLE_CORNERS] points;
            foreach (index, identity : triangle) points[index] = surface.grid[identity];
            source.reversed[face] = plane_from_grid(scratch.exact, plane, points)!;
        } else {
            Vec3[TRIANGLE_CORNERS] points;
            foreach (index, identity : triangle) points[index] = surface_position(surface, identity);
            source.reversed[face] = plane_from_float(scratch.exact, plane, points)!;
        }
    }
    uint edge_index;
    foreach (uint corner, twin : surface.topology.twins) {
        if (corner > twin) continue;
        SourceEdge* edge = &source.edges[edge_index];
        edge.owner_corner = corner;
        uint[TRIANGLE_CORNERS] triangle = surface_triangle(surface, corner / TRIANGLE_CORNERS);
        edge.vertices = { triangle[corner % TRIANGLE_CORNERS], triangle[(corner + 1) % TRIANGLE_CORNERS] };
        source.corner_edges[corner] = edge_index;
        source.corner_edges[twin] = edge_index++;
        edge_support_plane(
            surface: surface,
            output: &edge.plane,
            owner_corner: corner,
            owner_plane: &source.faces[corner / TRIANGLE_CORNERS],
        )!;
    }
    source.vertices[..] = {};
    foreach (uint corner, render_vertex : surface.source.geometry.indices) {
        uint identity = surface.source.topology_vertices[render_vertex];
        if (source.vertices[identity][0]) continue;
        source.vertices[identity] = source_vertex_planes(
            scratch: scratch.exact,
            source: &source,
            surface: surface,
            corner: corner,
        )!;
    }
    return source;
}
