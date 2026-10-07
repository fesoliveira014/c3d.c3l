module c3d::physics::fracture;

import c3d;
import c3d::geometry;
import std::math;
import std::sort;

const uint NO_SOLID_INDEX @private = uint::max;
const uint TRIANGLE_CORNERS @private = 3;

<* Borrowed surface arrays with explicit topological vertex identities. *>
struct SolidMeshView {
    Geometry geometry;
    uint[] topology_vertices;
    uint[] triangle_materials;
}

struct SolidVertex @private {
    uint representative;
    uint corner;
    uint degree;
}

struct SolidEdge @private {
    uint low;
    uint high;
    uint corner;
    bool reversed;
}

struct SolidTopology @private {
    SolidVertex[] vertices;
    uint[] twins;
    uint[] shell_roots;
    uint shell_count;
}

struct SolidScratch @private {
    char[] storage;
    usz used;
    usz peak;
    ExactScratch* exact;
}

fn void*? SolidScratch.reserve(
    &self,
    usz count,
    usz stride,
    usz alignment,
) {
    usz address = (uptr)(self.storage.ptr + self.used);
    usz padding = (alignment - address % alignment) % alignment;
    usz remaining = self.storage.len - self.used;
    if (padding > remaining || count > (remaining - padding) / stride) return c3d::CAPACITY_EXCEEDED~;
    usz start = self.used + padding;
    self.used = start + count * stride;
    self.peak = math::max(self.peak, self.used);
    self.exact.statistics.scratch_peak = math::max(self.exact.statistics.scratch_peak, self.used);
    return self.storage.ptr + start;
}

macro reserve_elements(SolidScratch* scratch, $Type, usz count) @private {
    return (($Type*)scratch.reserve(count, $Type::size, $Type::alignment))[:count];
}

fn SolidScratch begin_solid_scratch(FractureWorkspace* workspace) @private {
    ExactScratch* exact = (ExactScratch*)workspace.storage.ptr;
    exact.count = 0;
    exact.peak = 0;
    exact.predicate_count = 0;
    exact.filtered_count = 0;
    exact.exact_nanoseconds = 0;
    exact.measurement_depth = 0;
    exact.statistics = { .scratch_peak = MIN_FRACTURE_SCRATCH_BYTES };
    return {
        .storage = workspace.storage,
        .used = MIN_FRACTURE_SCRATCH_BYTES,
        .peak = MIN_FRACTURE_SCRATCH_BYTES,
        .exact = exact,
    };
}

fn bool finite_position(Vec3 value) @private {
    return math::is_finite(value.x) && math::is_finite(value.y) && math::is_finite(value.z);
}

fn bool finite_attribute(Vec4 value) @private {
    return math::is_finite(value.x) && math::is_finite(value.y) && math::is_finite(value.z) && math::is_finite(value.w);
}

fn bool same_position(Vec3 first, Vec3 second) @private {
    for (uint axis = 0; axis < SPACE_AXES; axis++) {
        uint left = bitcast(first[axis], uint);
        uint right = bitcast(second[axis], uint);
        if (left != right && ((left << 1) != 0 || (right << 1) != 0)) return false;
    }
    return true;
}

fn void? check_solid_streams(SolidMeshView mesh) @private {
    Geometry* geometry = &mesh.geometry;
    if (geometry.topology != Topology.TRIANGLES || geometry.joints.len || geometry.weights.len
        || geometry.targets.len || geometry.channels.len || geometry.custom_data.len || geometry.custom_stride) {
        return c3d::UNSUPPORTED~;
    }
    usz vertices = geometry.positions.len;
    usz corners = geometry.indices.len;
    if (!vertices || !corners || corners % TRIANGLE_CORNERS || mesh.topology_vertices.len != vertices
        || mesh.triangle_materials.len != corners / TRIANGLE_CORNERS) return c3d::INVALID_ARGUMENT~;
    if (vertices > uint::max || corners > uint::max) return c3d::CAPACITY_EXCEEDED~;
    usz[5] lengths = {
        geometry.normals.len, geometry.tangents.len, geometry.uv0.len, geometry.uv1.len, geometry.colors.len,
    };
    foreach (length : lengths) if (length && length != vertices) return c3d::INVALID_ARGUMENT~;
    foreach (index : geometry.indices) if (index >= vertices) return c3d::INVALID_ARGUMENT~;
    foreach (index : mesh.topology_vertices) if (index >= vertices) return c3d::INVALID_ARGUMENT~;
    foreach (value : geometry.positions) if (!finite_position(value)) return c3d::INVALID_ARGUMENT~;
    foreach (value : geometry.normals) if (!finite_position(value)) return c3d::INVALID_ARGUMENT~;
    foreach (value : geometry.tangents) if (!finite_attribute(value)) return c3d::INVALID_ARGUMENT~;
    foreach (value : geometry.colors) if (!finite_attribute(value)) return c3d::INVALID_ARGUMENT~;
    foreach (value : geometry.uv0) if (!math::is_finite(value.x) || !math::is_finite(value.y)) return c3d::INVALID_ARGUMENT~;
    foreach (value : geometry.uv1) if (!math::is_finite(value.x) || !math::is_finite(value.y)) return c3d::INVALID_ARGUMENT~;
    return;
}

fn uint next_solid_corner(uint corner) @private {
    return corner - corner % TRIANGLE_CORNERS + (corner + 1) % TRIANGLE_CORNERS;
}

fn uint solid_shell_root(uint[] parents, uint face) @private {
    uint root = face;
    while (parents[root] != root) root = parents[root];
    while (face != root) {
        uint next = parents[face];
        parents[face] = root;
        face = next;
    }
    return root;
}

fn int compare_solid_edges(SolidEdge first, SolidEdge second) @private {
    if (first.low != second.low) return first.low < second.low ? -1 : 1;
    if (first.high != second.high) return first.high < second.high ? -1 : 1;
    return first.corner < second.corner ? -1 : first.corner > second.corner ? 1 : 0;
}

fn SolidTopology? build_solid_topology(SolidScratch* scratch, SolidMeshView mesh) @private {
    check_solid_streams(mesh)!;
    usz saved = scratch.used;
    defer catch scratch.used = saved;
    SolidTopology topology = {
        .vertices = reserve_elements(scratch, SolidVertex, mesh.geometry.positions.len)!,
        .twins = reserve_elements(scratch, uint, mesh.geometry.indices.len)!,
        .shell_roots = reserve_elements(scratch, uint, mesh.triangle_materials.len)!,
    };
    topology.vertices[..] = { .representative = NO_SOLID_INDEX, .corner = NO_SOLID_INDEX };
    uint vertex_count;
    foreach (uint render_vertex, identity : mesh.topology_vertices) {
        SolidVertex* vertex = &topology.vertices[identity];
        if (vertex.representative == NO_SOLID_INDEX) {
            vertex.representative = render_vertex;
        } else if (!same_position(mesh.geometry.positions[render_vertex], mesh.geometry.positions[vertex.representative])) {
            return c3d::INVALID_ARGUMENT~;
        }
        vertex_count = math::max(vertex_count, identity + 1);
    }
    topology.vertices = topology.vertices[:vertex_count];
    foreach (vertex : topology.vertices) if (vertex.representative == NO_SOLID_INDEX) return c3d::INVALID_ARGUMENT~;
    foreach (uint face, &parent : topology.shell_roots) *parent = face;
    usz retained = scratch.used;
    defer scratch.used = retained;
    SolidEdge[] edges = reserve_elements(scratch, SolidEdge, mesh.geometry.indices.len)!;
    foreach (uint corner, render_vertex : mesh.geometry.indices) {
        uint first = mesh.topology_vertices[render_vertex];
        uint second = mesh.topology_vertices[mesh.geometry.indices[next_solid_corner(corner)]];
        if (first == second) return INVALID_SOLID~;
        edges[corner] = {
            .low = math::min(first, second),
            .high = math::max(first, second),
            .corner = corner,
            .reversed = first > second,
        };
        topology.vertices[first].corner = corner;
        topology.vertices[first].degree++;
    }
    sort::quicksort(edges, &compare_solid_edges);
    for (usz start = 0; start < edges.len;) {
        usz end = start + 1;
        while (end < edges.len && edges[end].low == edges[start].low && edges[end].high == edges[start].high) end++;
        if (end - start != 2 || edges[start].reversed == edges[start + 1].reversed) return INVALID_SOLID~;
        uint first = edges[start].corner;
        uint second = edges[start + 1].corner;
        topology.twins[first] = second;
        topology.twins[second] = first;
        uint first_shell = solid_shell_root(topology.shell_roots, first / TRIANGLE_CORNERS);
        uint second_shell = solid_shell_root(topology.shell_roots, second / TRIANGLE_CORNERS);
        topology.shell_roots[math::max(first_shell, second_shell)] = math::min(first_shell, second_shell);
        start = end;
    }
    foreach (vertex : topology.vertices) {
        if (!vertex.degree) continue;
        uint corner = vertex.corner;
        uint visited;
        do {
            visited++;
            corner = next_solid_corner(topology.twins[corner]);
        } while (corner != vertex.corner && visited < vertex.degree);
        if (visited != vertex.degree || corner != vertex.corner) return INVALID_SOLID~;
    }
    foreach (uint face, &parent : topology.shell_roots) {
        *parent = solid_shell_root(topology.shell_roots, face);
        if (*parent == face) topology.shell_count++;
    }
    return topology;
}
