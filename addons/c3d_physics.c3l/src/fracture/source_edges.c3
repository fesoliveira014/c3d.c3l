module c3d::physics::fracture;

import c3d;

enum SourceEdgeCutKind @private {
    NONE,
    VERTEX,
    CROSSING,
    COPLANAR,
}

struct SourceEdgeCut @private {
    SourceEdgeCutKind kind;
    PlaneTriple point;
    uint vertex;
}

<*
 Select independent planes at a validated triangle corner.
 @param [&inout] scratch : "Arithmetic temporaries restored before exit."
 @param [&in] source : "Completed face and edge construction records."
 @param [&in] surface : "Non-degenerate triangles with paired edges."
 @return? c3d::CAPACITY_EXCEEDED, NUMERICAL_FAILURE
 @require surface.validated
 @require corner < surface.topology.twins.len
 @require source.corner_edges.len == surface.topology.twins.len
 @require source.faces.len == surface.topology.shell_roots.len
*>
fn PlaneTriple? source_vertex_planes(
    ExactScratch* scratch,
    SourceConstructions* source,
    SolidSurface* surface,
    uint corner,
) @private {
    uint previous = corner - corner % TRIANGLE_CORNERS + (corner + TRIANGLE_CORNERS - 1) % TRIANGLE_CORNERS;
    SourceEdge* first = &source.edges[source.corner_edges[corner]];
    SourceEdge* second = &source.edges[source.corner_edges[previous]];
    PlaneTriple planes = {
        &source.faces[first.owner_corner / TRIANGLE_CORNERS],
        &first.plane,
        &source.faces[second.owner_corner / TRIANGLE_CORNERS],
    };
    if (!independent_plane_normals(scratch, planes)!) planes[2] = &second.plane;
    return planes;
}

fn SourceEdgeCut? intersect_source_edge(
    ExactScratch* scratch,
    SourceConstructions* source,
    uint edge_index,
    ExactPlane* cut,
) @private {
    SourceEdge* edge = &source.edges[edge_index];
    int first = plane_side(scratch, cut, source.vertices[edge.vertices[0]])!;
    int second = plane_side(scratch, cut, source.vertices[edge.vertices[1]])!;
    if (!first && !second) return { .kind = SourceEdgeCutKind.COPLANAR, .vertex = NO_SOLID_INDEX };
    if (!first || !second) {
        uint vertex = edge.vertices[first ? 1 : 0];
        return { .kind = SourceEdgeCutKind.VERTEX, .point = source.vertices[vertex], .vertex = vertex };
    }
    if (first == second) return { .vertex = NO_SOLID_INDEX };
    return {
        .kind = SourceEdgeCutKind.CROSSING,
        .point = { &source.faces[edge.owner_corner / TRIANGLE_CORNERS], &edge.plane, cut },
        .vertex = NO_SOLID_INDEX,
    };
}
