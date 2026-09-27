module c3d::nav;

import std::math;
import c3d;
import c3d::maths;

<* Vertices one navmesh polygon may have; mirrors DT_VERTS_PER_POLYGON. *>
const uint MAX_VERTS_PER_POLY = 6; // 24 bytes of indices and neighbours per polygon; the A* neighbour fan-out

<* Polygon index meaning no vertex or no neighbour; mirrors RC_MESH_NULL_IDX. *>
const ushort MESH_NULL_INDEX = 0xffff;

<* Neighbour flag of a tile-border portal edge; the low bits name the side; mirrors rcBuildPolyMesh's 0x8000. *>
const ushort PORTAL_EDGE = 0x8000;

const int    VERTEX_BUCKET_COUNT @local = 1 << 12; // 16 KiB of bucket heads per build; the vertex weld's hash width
const uint   VERTEX_HASH_X @local = 0x8da6b343; // upstream's arbitrarily chosen large primes
const uint   VERTEX_HASH_Y @local = 0xd8163841;
const uint   VERTEX_HASH_Z @local = 0xcb1ab31f;
const int    WELD_HEIGHT @local = 2; // voxels; mirrors addVertex, which welds vertices this close in Y at one XZ
const int    REMOVABLE_VERTEX @local = (int)0x80000000; // triangulation flag: the ear at this vertex is a diagonal
const int    VERTEX_INDEX_MASK @local = 0x0fffffff;
const int    MAX_MESH_VERTICES @local = 0xfffe; // mirrors rcBuildPolyMesh; ushort indices keep MESH_NULL_INDEX free
const ushort MULTIPLE_REGIONS @local = 0; // mirrors RC_MULTIPLE_REGS: a polygon rebuilt from two regions
const ushort SIDE_NEGATIVE_X @local = 0;
const ushort SIDE_POSITIVE_Z @local = 1;
const ushort SIDE_POSITIVE_X @local = 2;
const ushort SIDE_NEGATIVE_Z @local = 3;
const usz    BLOB_ALIGNMENT @local = 4;

<* Convex polygons of one tile in voxel coordinates; arrays come from the output allocator. *>
struct PolyMesh {
    ushort[] verts;           // 3 per vertex
    ushort[] polys;           // 2 * verts_per_poly per polygon: indices, then neighbours
    ushort[] regions;
    ushort[] flags;           // zero from the build
    char[]   areas;
    uint     vert_count;
    uint     poly_count;
    uint     verts_per_poly;
    Aabb     bounds;          // without the border
    float    cell_size;
    float    cell_height;
    uint     border_size;
    float    max_edge_error;
}

<* Header of a flat TileMesh blob; the arrays follow in PolyMesh order, each 4-byte aligned. *>
struct TileMeshHeader {
    int   tile_x;
    int   tile_z;
    uint  vert_count;
    uint  poly_count;
    uint  verts_per_poly;
    uint  _pad0;
    Aabb  bounds;
    float cell_size;
    float cell_height;
    uint  border_size;
    float max_edge_error;
}

$assert TileMeshHeader::size == 64;

<* Borrowed view over a TileMesh blob. *>
struct TileMeshView {
    TileMeshHeader* header;
    ushort[]        verts;
    ushort[]        polys;
    ushort[]        regions;
    ushort[]        flags;
    char[]          areas;
}

struct MeshEdge @local {
    ushort[2] vertices;
    ushort[2] poly_edges;
    ushort[2] polys;
}

struct VertexWeld @local {
    ushort[] verts;
    int[]    first;    // VERTEX_BUCKET_COUNT bucket heads, -1 when empty
    int[]    next;
    int      count;
}

struct IndexedPolygon @local {
    int[] verts;      // four ints per vertex
    int[] indices;    // positions into verts, flagged with REMOVABLE_VERTEX
    int   count;
}

struct PolygonBuffer @local {
    ushort[] polys;      // stride per polygon, MESH_NULL_INDEX padded
    ushort[] regions;    // one per polygon; empty when every polygon shares one region
    char[]   areas;
    ushort[] merged;     // one polygon of merge scratch
    int      count;
    int      stride;
}

struct PolyMerge @local {
    int value;           // squared length of the shared edge; not positive when the merge is refused
    int first_edge;
    int second_edge;
}

struct HoleBoundary @local {
    int[] vertices;
    int[] regions;
    int[] areas;
    int   count;
}

struct BlobCursor @local {
    char* base;
    usz   offset;
}

<*
 Triangulate every contour and merge the triangles into convex polygons; mirrors rcBuildPolyMesh.
 @param allocator : "Receives the mesh arrays; never freed by the result."
 @param scratch : "Holds the vertex hash, triangulation and merge buffers for the call."
 @param [&in] contours : "Holes merged."
 @return? c3d::CAPACITY_EXCEEDED
 @require verts_per_poly >= 3, verts_per_poly <= MAX_VERTS_PER_POLY
*>
fn PolyMesh? build_poly_mesh(
    Allocator allocator,
    Allocator scratch,
    ContourSet* contours,
    uint verts_per_poly,
) {
    int stride = (int)verts_per_poly;
    int vertex_capacity;
    int triangle_capacity;
    int largest_contour;
    foreach (contour : contours.contours) {
        int vertex_count = (int)(contour.verts.len / 4);
        if (vertex_count < 3) continue;
        vertex_capacity += vertex_count;
        triangle_capacity += vertex_count - 2;
        largest_contour = math::max(largest_contour, vertex_count);
    }
    if (vertex_capacity >= MAX_MESH_VERTICES) return c3d::CAPACITY_EXCEEDED~;

    ushort[]? verts = alloc::new_array_try(allocator, ushort, (sz)vertex_capacity * 3);
    if (catch verts) return c3d::CAPACITY_EXCEEDED~;
    ushort[]? polys = alloc::alloc_array_try(allocator, ushort, (sz)triangle_capacity * stride * 2);
    if (catch polys) return c3d::CAPACITY_EXCEEDED~;
    ushort[]? regions = alloc::new_array_try(allocator, ushort, triangle_capacity);
    if (catch regions) return c3d::CAPACITY_EXCEEDED~;
    ushort[]? flags = alloc::new_array_try(allocator, ushort, triangle_capacity);
    if (catch flags) return c3d::CAPACITY_EXCEEDED~;
    char[]? areas = alloc::new_array_try(allocator, char, triangle_capacity);
    if (catch areas) return c3d::CAPACITY_EXCEEDED~;
    polys[..] = MESH_NULL_INDEX;

    PolyMesh mesh = {
        .verts          = verts,
        .polys          = polys,
        .regions        = regions,
        .flags          = flags,
        .areas          = areas,
        .verts_per_poly = verts_per_poly,
        .bounds         = contours.bounds,
        .cell_size      = contours.cell_size,
        .cell_height    = contours.cell_height,
        .border_size    = contours.border_size,
        .max_edge_error = contours.max_error,
    };

    bool[]? vertex_flags = alloc::new_array_try(scratch, bool, vertex_capacity);
    if (catch vertex_flags) return c3d::CAPACITY_EXCEEDED~;
    defer alloc::free(scratch, vertex_flags.ptr);
    int[]? next_vertex = alloc::new_array_try(scratch, int, vertex_capacity);
    if (catch next_vertex) return c3d::CAPACITY_EXCEEDED~;
    defer alloc::free(scratch, next_vertex.ptr);
    int[]? first_vertex = alloc::alloc_array_try(scratch, int, VERTEX_BUCKET_COUNT);
    if (catch first_vertex) return c3d::CAPACITY_EXCEEDED~;
    defer alloc::free(scratch, first_vertex.ptr);
    int[]? indices = alloc::alloc_array_try(scratch, int, largest_contour);
    if (catch indices) return c3d::CAPACITY_EXCEEDED~;
    defer alloc::free(scratch, indices.ptr);
    int[]? triangles = alloc::alloc_array_try(scratch, int, (sz)largest_contour * 3);
    if (catch triangles) return c3d::CAPACITY_EXCEEDED~;
    defer alloc::free(scratch, triangles.ptr);
    ushort[]? buffer_polys = alloc::alloc_array_try(scratch, ushort, ((sz)largest_contour + 1) * stride);
    if (catch buffer_polys) return c3d::CAPACITY_EXCEEDED~;
    defer alloc::free(scratch, buffer_polys.ptr);

    first_vertex[..] = -1;
    VertexWeld weld = { .verts = verts, .first = first_vertex, .next = next_vertex };
    PolygonBuffer buffer = {
        .polys  = buffer_polys[:(sz)largest_contour * stride],
        .merged = buffer_polys[(sz)largest_contour * stride:stride],
        .stride = stride,
    };

    foreach (&contour : contours.contours) {
        int vertex_count = (int)(contour.verts.len / 4);
        if (vertex_count < 3) continue;

        for (int vertex = 0; vertex < vertex_count; vertex++) indices[vertex] = vertex;
        int triangle_count = triangulate(
            count:     vertex_count,
            verts:     contour.verts,
            indices:   indices,
            triangles: triangles,
        );
        // A contour simplified too aggressively still yields the triangles found before the failure.
        if (triangle_count <= 0) triangle_count = -triangle_count;

        for (int vertex = 0; vertex < vertex_count; vertex++) {
            int* point = &contour.verts[vertex * 4];
            indices[vertex] = add_vertex(&weld, point);
            if ((point[3] & BORDER_VERTEX) != 0) vertex_flags[indices[vertex]] = true;
        }

        buffer.polys[..] = MESH_NULL_INDEX;
        buffer.count = 0;
        for (int triangle = 0; triangle < triangle_count; triangle++) {
            int* corners = &triangles[triangle * 3];
            if (corners[0] == corners[1] || corners[0] == corners[2] || corners[1] == corners[2]) continue;
            ushort[] poly = buffer_polygon(&buffer, buffer.count);
            poly[0] = (ushort)indices[corners[0]];
            poly[1] = (ushort)indices[corners[1]];
            poly[2] = (ushort)indices[corners[2]];
            buffer.count++;
        }
        if (buffer.count == 0) continue;
        if (stride > 3) merge_polygons(&buffer, verts);

        for (int poly = 0; poly < buffer.count; poly++) {
            if ((int)mesh.poly_count == triangle_capacity) return c3d::CAPACITY_EXCEEDED~;
            mesh.polys[(sz)mesh.poly_count * stride * 2:stride] = buffer_polygon(&buffer, poly)[..];
            mesh.regions[mesh.poly_count] = contour.region;
            mesh.areas[mesh.poly_count] = contour.area;
            mesh.poly_count++;
        }
    }
    mesh.vert_count = (uint)weld.count;

    for (int vertex = 0; vertex < (int)mesh.vert_count; vertex++) {
        if (!vertex_flags[vertex]) continue;
        if (!can_remove_vertex(scratch, &mesh, (ushort)vertex)!) continue;
        remove_vertex(
            scratch:   scratch,
            mesh:      &mesh,
            removed:   (ushort)vertex,
            max_polys: triangle_capacity,
        )!;
        for (int shifted = vertex; shifted < (int)mesh.vert_count; shifted++) {
            vertex_flags[shifted] = vertex_flags[shifted + 1];
        }
        vertex--;
    }

    build_mesh_adjacency(scratch, &mesh)!;
    if (mesh.border_size > 0) mark_portal_edges(&mesh, (int)contours.width, (int)contours.height);

    mesh.verts = verts[:(sz)mesh.vert_count * 3];
    mesh.polys = polys[:(sz)mesh.poly_count * stride * 2];
    mesh.regions = regions[:mesh.poly_count];
    mesh.flags = flags[:mesh.poly_count];
    mesh.areas = areas[:mesh.poly_count];
    return mesh;
}

<* Bytes the TileMesh blob of the mesh needs. *>
fn usz tile_mesh_size(PolyMesh* mesh) {
    BlobCursor cursor = { .offset = TileMeshHeader::size };
    carve_blob(&cursor, ushort, (usz)mesh.vert_count * 3);
    carve_blob(&cursor, ushort, (usz)mesh.poly_count * mesh.verts_per_poly * 2);
    carve_blob(&cursor, ushort, mesh.poly_count);
    carve_blob(&cursor, ushort, mesh.poly_count);
    carve_blob(&cursor, char, mesh.poly_count);
    return cursor.offset;
}

<*
 Pack the poly mesh into a flat blob.
 @param [&in] mesh : "Built."
 @param [out] blob : "tile_mesh_size(mesh) bytes, 4-byte aligned."
*>
fn void pack_tile_mesh(
    PolyMesh* mesh,
    int tile_x,
    int tile_z,
    char[] blob,
) {
    blob[..] = 0;
    *(TileMeshHeader*)blob.ptr = {
        .tile_x         = tile_x,
        .tile_z         = tile_z,
        .vert_count     = mesh.vert_count,
        .poly_count     = mesh.poly_count,
        .verts_per_poly = mesh.verts_per_poly,
        .bounds         = mesh.bounds,
        .cell_size      = mesh.cell_size,
        .cell_height    = mesh.cell_height,
        .border_size    = mesh.border_size,
        .max_edge_error = mesh.max_edge_error,
    };
    TileMeshView view = tile_mesh_view(blob);
    view.verts[..] = mesh.verts[..];
    view.polys[..] = mesh.polys[..];
    view.regions[..] = mesh.regions[..];
    view.flags[..] = mesh.flags[..];
    view.areas[..] = mesh.areas[..];
}

<*
 Borrow the arrays of a packed blob.
 @param blob : "Written by pack_tile_mesh."
*>
fn TileMeshView tile_mesh_view(char[] blob) {
    TileMeshHeader* header = (TileMeshHeader*)blob.ptr;
    BlobCursor cursor = { .base = blob.ptr, .offset = TileMeshHeader::size };
    return {
        .header  = header,
        .verts   = carve_blob(&cursor, ushort, (usz)header.vert_count * 3),
        .polys   = carve_blob(&cursor, ushort, (usz)header.poly_count * header.verts_per_poly * 2),
        .regions = carve_blob(&cursor, ushort, header.poly_count),
        .flags   = carve_blob(&cursor, ushort, header.poly_count),
        .areas   = carve_blob(&cursor, char, header.poly_count),
    };
}

// With a null base the cursor only measures.
macro carve_blob(BlobCursor* cursor, $Type, usz count) @local {
    $Type[] slice;
    if (cursor.base) slice = (($Type*)(cursor.base + cursor.offset))[:count];
    cursor.offset += ($Type::size * count + BLOB_ALIGNMENT - 1) / BLOB_ALIGNMENT * BLOB_ALIGNMENT;
    return slice;
}

fn ushort[] buffer_polygon(PolygonBuffer* buffer, int index) @local {
    return buffer.polys[(sz)index * buffer.stride:buffer.stride];
}

fn ushort[] mesh_polygon(PolyMesh* mesh, int index) @local {
    return mesh.polys[(sz)index * mesh.verts_per_poly * 2:mesh.verts_per_poly];
}

fn int vertex_hash(int x, int y, int z) @local {
    uint hash = VERTEX_HASH_X * (uint)x + VERTEX_HASH_Y * (uint)y + VERTEX_HASH_Z * (uint)z;
    return (int)(hash & (VERTEX_BUCKET_COUNT - 1));
}

fn ushort add_vertex(VertexWeld* weld, int* point) @local {
    ushort x = (ushort)point[0];
    ushort y = (ushort)point[1];
    ushort z = (ushort)point[2];
    int bucket = vertex_hash(x, 0, z);
    for (int index = weld.first[bucket]; index != -1; index = weld.next[index]) {
        ushort* existing = &weld.verts[index * 3];
        bool same_column = existing[0] == x && existing[2] == z;
        if (same_column && math::abs((int)existing[1] - (int)y) <= WELD_HEIGHT) return (ushort)index;
    }

    int index = weld.count++;
    weld.verts[index * 3] = x;
    weld.verts[index * 3 + 1] = y;
    weld.verts[index * 3 + 2] = z;
    weld.next[index] = weld.first[bucket];
    weld.first[bucket] = index;
    return (ushort)index;
}

fn int* polygon_vertex(IndexedPolygon* polygon, int position) @local {
    return &polygon.verts[(polygon.indices[position] & VERTEX_INDEX_MASK) * 4];
}

fn bool polygon_diagonalie(IndexedPolygon* polygon, int first, int second) @local {
    int* diagonal_start = polygon_vertex(polygon, first);
    int* diagonal_end = polygon_vertex(polygon, second);
    for (int edge = 0; edge < polygon.count; edge++) {
        int edge_next = next_index(edge, polygon.count);
        if (edge == first || edge_next == first || edge == second || edge_next == second) continue;
        int* edge_start = polygon_vertex(polygon, edge);
        int* edge_end = polygon_vertex(polygon, edge_next);
        if (equal_xz(diagonal_start, edge_start) || equal_xz(diagonal_end, edge_start)) continue;
        if (equal_xz(diagonal_start, edge_end) || equal_xz(diagonal_end, edge_end)) continue;
        if (intersect(a: diagonal_start, b: diagonal_end, c: edge_start, d: edge_end)) return false;
    }
    return true;
}

fn bool polygon_diagonalie_loose(IndexedPolygon* polygon, int first, int second) @local {
    int* diagonal_start = polygon_vertex(polygon, first);
    int* diagonal_end = polygon_vertex(polygon, second);
    for (int edge = 0; edge < polygon.count; edge++) {
        int edge_next = next_index(edge, polygon.count);
        if (edge == first || edge_next == first || edge == second || edge_next == second) continue;
        int* edge_start = polygon_vertex(polygon, edge);
        int* edge_end = polygon_vertex(polygon, edge_next);
        if (equal_xz(diagonal_start, edge_start) || equal_xz(diagonal_end, edge_start)) continue;
        if (equal_xz(diagonal_start, edge_end) || equal_xz(diagonal_end, edge_end)) continue;
        if (intersect_prop(a: diagonal_start, b: diagonal_end, c: edge_start, d: edge_end)) return false;
    }
    return true;
}

fn bool polygon_in_cone(IndexedPolygon* polygon, int first, int second) @local {
    int* corner = polygon_vertex(polygon, first);
    int* target = polygon_vertex(polygon, second);
    int* next = polygon_vertex(polygon, next_index(first, polygon.count));
    int* previous = polygon_vertex(polygon, previous_index(first, polygon.count));
    if (left_on(previous, corner, next)) return left(corner, target, previous) && left(target, corner, next);
    return !(left_on(corner, target, next) && left_on(target, corner, previous));
}

fn bool polygon_in_cone_loose(IndexedPolygon* polygon, int first, int second) @local {
    int* corner = polygon_vertex(polygon, first);
    int* target = polygon_vertex(polygon, second);
    int* next = polygon_vertex(polygon, next_index(first, polygon.count));
    int* previous = polygon_vertex(polygon, previous_index(first, polygon.count));
    if (left_on(previous, corner, next)) return left_on(corner, target, previous) && left_on(target, corner, next);
    return !(left_on(corner, target, next) && left_on(target, corner, previous));
}

fn bool polygon_diagonal(IndexedPolygon* polygon, int first, int second) @local {
    return polygon_in_cone(polygon, first, second) && polygon_diagonalie(polygon, first, second);
}

fn bool polygon_diagonal_loose(IndexedPolygon* polygon, int first, int second) @local {
    return polygon_in_cone_loose(polygon, first, second) && polygon_diagonalie_loose(polygon, first, second);
}

fn int ear_length(IndexedPolygon* polygon, int start, int end) @local {
    int* start_point = polygon_vertex(polygon, start);
    int* end_point = polygon_vertex(polygon, end);
    int delta_x = end_point[0] - start_point[0];
    int delta_z = end_point[2] - start_point[2];
    return delta_x * delta_x + delta_z * delta_z;
}

// Negative when the polygon could not be finished; the magnitude counts the triangles written.
fn int triangulate(
    int count,
    int[] verts,
    int[] indices,
    int[] triangles,
) @local {
    IndexedPolygon polygon = { .verts = verts, .indices = indices, .count = count };
    int triangle_count;
    int written;

    for (int vertex = 0; vertex < count; vertex++) {
        int ear = next_index(vertex, count);
        if (polygon_diagonal(&polygon, vertex, next_index(ear, count))) indices[ear] |= REMOVABLE_VERTEX;
    }

    while (polygon.count > 3) {
        int min_length = -1;
        int best = -1;
        for (int vertex = 0; vertex < polygon.count; vertex++) {
            int ear = next_index(vertex, polygon.count);
            if ((indices[ear] & REMOVABLE_VERTEX) == 0) continue;
            int length = ear_length(&polygon, vertex, next_index(ear, polygon.count));
            if (min_length < 0 || length < min_length) {
                min_length = length;
                best = vertex;
            }
        }

        if (best == -1) {
            // Overlapping contour segments leave no strict ear; the loose cone test can still find one.
            for (int vertex = 0; vertex < polygon.count; vertex++) {
                int ear = next_index(vertex, polygon.count);
                int far = next_index(ear, polygon.count);
                if (!polygon_diagonal_loose(&polygon, vertex, far)) continue;
                // Upstream measures to the vertex after the far one here.
                int length = ear_length(&polygon, vertex, next_index(far, polygon.count));
                if (min_length < 0 || length < min_length) {
                    min_length = length;
                    best = vertex;
                }
            }
            if (best == -1) return -triangle_count;
        }

        int vertex = best;
        int ear = next_index(vertex, polygon.count);
        int far = next_index(ear, polygon.count);
        triangles[written++] = indices[vertex] & VERTEX_INDEX_MASK;
        triangles[written++] = indices[ear] & VERTEX_INDEX_MASK;
        triangles[written++] = indices[far] & VERTEX_INDEX_MASK;
        triangle_count++;

        polygon.count--;
        for (int shifted = ear; shifted < polygon.count; shifted++) indices[shifted] = indices[shifted + 1];
        if (ear >= polygon.count) ear = 0;
        vertex = previous_index(ear, polygon.count);
        if (polygon_diagonal(&polygon, previous_index(vertex, polygon.count), ear)) {
            indices[vertex] |= REMOVABLE_VERTEX;
        } else {
            indices[vertex] &= VERTEX_INDEX_MASK;
        }
        if (polygon_diagonal(&polygon, vertex, next_index(ear, polygon.count))) {
            indices[ear] |= REMOVABLE_VERTEX;
        } else {
            indices[ear] &= VERTEX_INDEX_MASK;
        }
    }

    triangles[written++] = indices[0] & VERTEX_INDEX_MASK;
    triangles[written++] = indices[1] & VERTEX_INDEX_MASK;
    triangles[written++] = indices[2] & VERTEX_INDEX_MASK;
    return triangle_count + 1;
}

fn int count_poly_verts(ushort[] poly) @private {
    foreach (index, vertex : poly) {
        if (vertex == MESH_NULL_INDEX) return (int)index;
    }
    return (int)poly.len;
}

fn bool uleft(ushort* a, ushort* b, ushort* c) @local {
    return ((int)b[0] - (int)a[0]) * ((int)c[2] - (int)a[2]) - ((int)c[0] - (int)a[0]) * ((int)b[2] - (int)a[2]) < 0;
}

fn PolyMerge poly_merge_value(ushort[] first, ushort[] second, ushort[] verts) @local {
    int first_count = count_poly_verts(first);
    int second_count = count_poly_verts(second);
    PolyMerge merge = { .value = -1, .first_edge = -1, .second_edge = -1 };
    if (first_count + second_count - 2 > (int)first.len) return merge;

    // The last shared edge found wins, as upstream's inner break leaves the outer loop running.
    for (int edge = 0; edge < first_count; edge++) {
        ushort first_start = first[edge];
        ushort first_end = first[(edge + 1) % first_count];
        if (first_start > first_end) @swap(first_start, first_end);
        for (int other = 0; other < second_count; other++) {
            ushort second_start = second[other];
            ushort second_end = second[(other + 1) % second_count];
            if (second_start > second_end) @swap(second_start, second_end);
            if (first_start != second_start || first_end != second_end) continue;
            merge.first_edge = edge;
            merge.second_edge = other;
            break;
        }
    }
    if (merge.first_edge == -1 || merge.second_edge == -1) return merge;

    int edge = merge.first_edge;
    int other = merge.second_edge;
    ushort* before_first = &verts[first[(edge + first_count - 1) % first_count] * 3];
    ushort* first_corner = &verts[first[edge] * 3];
    ushort* after_second = &verts[second[(other + 2) % second_count] * 3];
    if (!uleft(before_first, first_corner, after_second)) return merge;
    ushort* before_second = &verts[second[(other + second_count - 1) % second_count] * 3];
    ushort* second_corner = &verts[second[other] * 3];
    ushort* after_first = &verts[first[(edge + 2) % first_count] * 3];
    if (!uleft(before_second, second_corner, after_first)) return merge;

    ushort* edge_end = &verts[first[(edge + 1) % first_count] * 3];
    int delta_x = (int)first_corner[0] - (int)edge_end[0];
    int delta_z = (int)first_corner[2] - (int)edge_end[2];
    merge.value = delta_x * delta_x + delta_z * delta_z;
    return merge;
}

fn void merge_poly_verts(
    ushort[] first,
    ushort[] second,
    PolyMerge merge,
    ushort[] merged,
) @local {
    int first_count = count_poly_verts(first);
    int second_count = count_poly_verts(second);
    merged[..] = MESH_NULL_INDEX;
    int written;
    for (int offset = 0; offset < first_count - 1; offset++) {
        merged[written++] = first[(merge.first_edge + 1 + offset) % first_count];
    }
    for (int offset = 0; offset < second_count - 1; offset++) {
        merged[written++] = second[(merge.second_edge + 1 + offset) % second_count];
    }
    first[..] = merged[..];
}

fn void merge_polygons(PolygonBuffer* buffer, ushort[] verts) @local {
    while (true) {
        PolyMerge best;
        int best_first;
        int best_second;
        for (int first = 0; first < buffer.count - 1; first++) {
            for (int second = first + 1; second < buffer.count; second++) {
                ushort[] candidate = buffer_polygon(buffer, second);
                PolyMerge merge = poly_merge_value(buffer_polygon(buffer, first), candidate, verts);
                if (merge.value <= best.value) continue;
                best = merge;
                best_first = first;
                best_second = second;
            }
        }
        if (best.value <= 0) return;

        ushort[] target = buffer_polygon(buffer, best_first);
        ushort[] source = buffer_polygon(buffer, best_second);
        merge_poly_verts(
            first:  target,
            second: source,
            merge:  best,
            merged: buffer.merged,
        );
        int last = buffer.count - 1;
        if (best_second != last) source[..] = buffer_polygon(buffer, last)[..];
        if (buffer.regions.len) {
            if (buffer.regions[best_first] != buffer.regions[best_second]) {
                buffer.regions[best_first] = MULTIPLE_REGIONS;
            }
            buffer.regions[best_second] = buffer.regions[last];
            buffer.areas[best_second] = buffer.areas[last];
        }
        buffer.count--;
    }
}

fn void push_hole_front(HoleBoundary* hole, int vertex, int[4] edge) @local {
    hole.count++;
    for (int shifted = hole.count - 1; shifted > 0; shifted--) {
        hole.vertices[shifted] = hole.vertices[shifted - 1];
        hole.regions[shifted] = hole.regions[shifted - 1];
        hole.areas[shifted] = hole.areas[shifted - 1];
    }
    hole.vertices[0] = vertex;
    hole.regions[0] = edge[2];
    hole.areas[0] = edge[3];
}

fn void push_hole_back(HoleBoundary* hole, int vertex, int[4] edge) @local {
    hole.vertices[hole.count] = vertex;
    hole.regions[hole.count] = edge[2];
    hole.areas[hole.count] = edge[3];
    hole.count++;
}

fn bool? can_remove_vertex(Allocator scratch, PolyMesh* mesh, ushort removed) @local {
    int touched_vertices;
    int remaining_edges;
    for (int poly = 0; poly < (int)mesh.poly_count; poly++) {
        ushort[] entry = mesh_polygon(mesh, poly);
        int count = count_poly_verts(entry);
        int removed_count;
        foreach (vertex : entry[:count]) {
            if (vertex == removed) removed_count++;
        }
        touched_vertices += removed_count;
        if (removed_count) remaining_edges += count - (removed_count + 1);
    }
    // A triangle tip no other polygon shares would leave too few edges for a polygon.
    if (remaining_edges <= 2) return false;

    int[3][]? allocated = alloc::alloc_array_try(scratch, int[3], (sz)touched_vertices * 2);
    if (catch allocated) return c3d::CAPACITY_EXCEEDED~;
    int[3][] edges = allocated;
    defer alloc::free(scratch, edges.ptr);
    int edge_count;
    for (int poly = 0; poly < (int)mesh.poly_count; poly++) {
        ushort[] entry = mesh_polygon(mesh, poly);
        int count = count_poly_verts(entry);
        int previous = count - 1;
        for (int current = 0; current < count; previous = current++) {
            if (entry[current] != removed && entry[previous] != removed) continue;
            int other = entry[previous] == removed ? entry[current] : entry[previous];
            bool exists;
            for (int edge = 0; edge < edge_count; edge++) {
                if (edges[edge][1] != other) continue;
                edges[edge][2]++;
                exists = true;
            }
            if (!exists) edges[edge_count++] = { removed, other, 1 };
        }
    }

    // More than two open edges means two polygons share the vertex without sharing an edge.
    int open_edges;
    foreach (edge : edges[:edge_count]) {
        if (edge[2] < 2) open_edges++;
    }
    return open_edges <= 2;
}

fn void? remove_vertex(
    Allocator scratch,
    PolyMesh* mesh,
    ushort removed,
    int max_polys,
) @local {
    int stride = (int)mesh.verts_per_poly;
    int removed_count;
    for (int poly = 0; poly < (int)mesh.poly_count; poly++) {
        ushort[] entry = mesh_polygon(mesh, poly);
        foreach (vertex : entry[:count_poly_verts(entry)]) {
            if (vertex == removed) removed_count++;
        }
    }

    sz boundary_capacity = (sz)removed_count * stride;
    int[4][]? allocated_edges = alloc::alloc_array_try(scratch, int[4], boundary_capacity);
    if (catch allocated_edges) return c3d::CAPACITY_EXCEEDED~;
    int[4][] edges = allocated_edges;
    defer alloc::free(scratch, edges.ptr);
    int[]? hole_vertices = alloc::alloc_array_try(scratch, int, boundary_capacity);
    if (catch hole_vertices) return c3d::CAPACITY_EXCEEDED~;
    defer alloc::free(scratch, hole_vertices.ptr);
    int[]? hole_regions = alloc::alloc_array_try(scratch, int, boundary_capacity);
    if (catch hole_regions) return c3d::CAPACITY_EXCEEDED~;
    defer alloc::free(scratch, hole_regions.ptr);
    int[]? hole_areas = alloc::alloc_array_try(scratch, int, boundary_capacity);
    if (catch hole_areas) return c3d::CAPACITY_EXCEEDED~;
    defer alloc::free(scratch, hole_areas.ptr);

    int edge_count;
    for (int poly = 0; poly < (int)mesh.poly_count; poly++) {
        ushort[] entry = mesh_polygon(mesh, poly);
        int count = count_poly_verts(entry);
        bool has_removed;
        foreach (vertex : entry[:count]) {
            if (vertex == removed) has_removed = true;
        }
        if (!has_removed) continue;

        int previous = count - 1;
        for (int current = 0; current < count; previous = current++) {
            if (entry[current] == removed || entry[previous] == removed) continue;
            edges[edge_count++] = { entry[previous], entry[current], mesh.regions[poly], mesh.areas[poly] };
        }
        int last = (int)mesh.poly_count - 1;
        if (poly != last) entry[..] = mesh_polygon(mesh, last)[..];
        mesh.polys[(sz)poly * stride * 2 + stride:stride] = MESH_NULL_INDEX;
        mesh.regions[poly] = mesh.regions[last];
        mesh.areas[poly] = mesh.areas[last];
        mesh.poly_count--;
        poly--;
    }

    for (int vertex = removed; vertex < (int)mesh.vert_count - 1; vertex++) {
        mesh.verts[vertex * 3] = mesh.verts[(vertex + 1) * 3];
        mesh.verts[vertex * 3 + 1] = mesh.verts[(vertex + 1) * 3 + 1];
        mesh.verts[vertex * 3 + 2] = mesh.verts[(vertex + 1) * 3 + 2];
    }
    mesh.vert_count--;

    for (int poly = 0; poly < (int)mesh.poly_count; poly++) {
        ushort[] entry = mesh_polygon(mesh, poly);
        foreach (&vertex : entry[:count_poly_verts(entry)]) {
            if (*vertex > removed) (*vertex)--;
        }
    }
    for (int edge = 0; edge < edge_count; edge++) {
        if (edges[edge][0] > removed) edges[edge][0]--;
        if (edges[edge][1] > removed) edges[edge][1]--;
    }
    if (edge_count == 0) return;

    HoleBoundary hole = { .vertices = hole_vertices, .regions = hole_regions, .areas = hole_areas };
    push_hole_back(&hole, edges[0][0], edges[0]);
    while (edge_count > 0) {
        bool matched;
        for (int edge = 0; edge < edge_count; edge++) {
            int[4] current = edges[edge];
            if (hole.vertices[0] == current[1]) {
                push_hole_front(&hole, current[0], current);
            } else if (hole.vertices[hole.count - 1] == current[0]) {
                push_hole_back(&hole, current[1], current);
            } else {
                continue;
            }
            edges[edge] = edges[edge_count - 1];
            edge_count--;
            matched = true;
            edge--;
        }
        if (!matched) break;
    }

    int[]? triangles = alloc::alloc_array_try(scratch, int, (sz)hole.count * 3);
    if (catch triangles) return c3d::CAPACITY_EXCEEDED~;
    defer alloc::free(scratch, triangles.ptr);
    int[]? hole_points = alloc::alloc_array_try(scratch, int, (sz)hole.count * 4);
    if (catch hole_points) return c3d::CAPACITY_EXCEEDED~;
    defer alloc::free(scratch, hole_points.ptr);
    int[]? hole_indices = alloc::alloc_array_try(scratch, int, hole.count);
    if (catch hole_indices) return c3d::CAPACITY_EXCEEDED~;
    defer alloc::free(scratch, hole_indices.ptr);

    for (int vertex = 0; vertex < hole.count; vertex++) {
        int source = hole.vertices[vertex];
        hole_points[vertex * 4] = mesh.verts[source * 3];
        hole_points[vertex * 4 + 1] = mesh.verts[source * 3 + 1];
        hole_points[vertex * 4 + 2] = mesh.verts[source * 3 + 2];
        hole_points[vertex * 4 + 3] = 0;
        hole_indices[vertex] = vertex;
    }
    int triangle_count = triangulate(
        count:     hole.count,
        verts:     hole_points,
        indices:   hole_indices,
        triangles: triangles,
    );
    if (triangle_count < 0) triangle_count = -triangle_count;

    ushort[]? buffer_polys = alloc::alloc_array_try(scratch, ushort, ((sz)triangle_count + 1) * stride);
    if (catch buffer_polys) return c3d::CAPACITY_EXCEEDED~;
    defer alloc::free(scratch, buffer_polys.ptr);
    ushort[]? buffer_regions = alloc::alloc_array_try(scratch, ushort, triangle_count);
    if (catch buffer_regions) return c3d::CAPACITY_EXCEEDED~;
    defer alloc::free(scratch, buffer_regions.ptr);
    char[]? buffer_areas = alloc::alloc_array_try(scratch, char, triangle_count);
    if (catch buffer_areas) return c3d::CAPACITY_EXCEEDED~;
    defer alloc::free(scratch, buffer_areas.ptr);

    PolygonBuffer buffer = {
        .polys   = buffer_polys[:(sz)triangle_count * stride],
        .regions = buffer_regions,
        .areas   = buffer_areas,
        .merged  = buffer_polys[(sz)triangle_count * stride:stride],
        .stride  = stride,
    };
    buffer.polys[..] = MESH_NULL_INDEX;
    for (int triangle = 0; triangle < triangle_count; triangle++) {
        int* corners = &triangles[triangle * 3];
        if (corners[0] == corners[1] || corners[0] == corners[2] || corners[1] == corners[2]) continue;
        ushort[] poly = buffer_polygon(&buffer, buffer.count);
        poly[0] = (ushort)hole.vertices[corners[0]];
        poly[1] = (ushort)hole.vertices[corners[1]];
        poly[2] = (ushort)hole.vertices[corners[2]];
        bool same_region = hole.regions[corners[0]] == hole.regions[corners[1]]
            && hole.regions[corners[1]] == hole.regions[corners[2]];
        buffer.regions[buffer.count] = same_region ? (ushort)hole.regions[corners[0]] : MULTIPLE_REGIONS;
        buffer.areas[buffer.count] = (char)hole.areas[corners[0]];
        buffer.count++;
    }
    if (buffer.count == 0) return;
    if (stride > 3) merge_polygons(&buffer, mesh.verts);

    for (int poly = 0; poly < buffer.count; poly++) {
        if ((int)mesh.poly_count >= max_polys) break;
        ushort[] target = mesh.polys[(sz)mesh.poly_count * stride * 2:stride * 2];
        target[..] = MESH_NULL_INDEX;
        target[:stride] = buffer_polygon(&buffer, poly)[..];
        mesh.regions[mesh.poly_count] = buffer.regions[poly];
        mesh.areas[mesh.poly_count] = buffer.areas[poly];
        mesh.poly_count++;
    }
}

fn void? build_mesh_adjacency(Allocator scratch, PolyMesh* mesh) @local {
    int stride = (int)mesh.verts_per_poly;
    sz max_edges = (sz)mesh.poly_count * stride;
    ushort[]? heads = alloc::alloc_array_try(scratch, ushort, mesh.vert_count + max_edges);
    if (catch heads) return c3d::CAPACITY_EXCEEDED~;
    defer alloc::free(scratch, heads.ptr);
    MeshEdge[]? allocated = alloc::alloc_array_try(scratch, MeshEdge, max_edges);
    if (catch allocated) return c3d::CAPACITY_EXCEEDED~;
    MeshEdge[] edges = allocated;
    defer alloc::free(scratch, edges.ptr);

    ushort[] first_edge = heads[:mesh.vert_count];
    ushort[] next_edge = heads[mesh.vert_count:max_edges];
    first_edge[..] = MESH_NULL_INDEX;
    int edge_count;
    for (int poly = 0; poly < (int)mesh.poly_count; poly++) {
        ushort[] entry = mesh_polygon(mesh, poly);
        for (int slot = 0; slot < stride; slot++) {
            if (entry[slot] == MESH_NULL_INDEX) break;
            ushort start = entry[slot];
            ushort end = slot + 1 >= stride || entry[slot + 1] == MESH_NULL_INDEX ? entry[0] : entry[slot + 1];
            if (start >= end) continue;
            edges[edge_count] = {
                .vertices   = { start, end },
                .poly_edges = { (ushort)slot, 0 },
                .polys      = { (ushort)poly, (ushort)poly },
            };
            next_edge[edge_count] = first_edge[start];
            first_edge[start] = (ushort)edge_count;
            edge_count++;
        }
    }

    for (int poly = 0; poly < (int)mesh.poly_count; poly++) {
        ushort[] entry = mesh_polygon(mesh, poly);
        for (int slot = 0; slot < stride; slot++) {
            if (entry[slot] == MESH_NULL_INDEX) break;
            ushort start = entry[slot];
            ushort end = slot + 1 >= stride || entry[slot + 1] == MESH_NULL_INDEX ? entry[0] : entry[slot + 1];
            if (start <= end) continue;
            for (ushort edge = first_edge[end]; edge != MESH_NULL_INDEX; edge = next_edge[edge]) {
                if (edges[edge].vertices[1] != start || edges[edge].polys[0] != edges[edge].polys[1]) continue;
                edges[edge].polys[1] = (ushort)poly;
                edges[edge].poly_edges[1] = (ushort)slot;
                break;
            }
        }
    }

    foreach (edge : edges[:edge_count]) {
        if (edge.polys[0] == edge.polys[1]) continue;
        mesh.polys[(sz)edge.polys[0] * stride * 2 + stride + edge.poly_edges[0]] = edge.polys[1];
        mesh.polys[(sz)edge.polys[1] * stride * 2 + stride + edge.poly_edges[1]] = edge.polys[0];
    }
}

fn void mark_portal_edges(PolyMesh* mesh, int width, int height) @local {
    int stride = (int)mesh.verts_per_poly;
    for (int poly = 0; poly < (int)mesh.poly_count; poly++) {
        ushort[] entry = mesh.polys[(sz)poly * stride * 2:stride * 2];
        for (int slot = 0; slot < stride; slot++) {
            if (entry[slot] == MESH_NULL_INDEX) break;
            if (entry[stride + slot] != MESH_NULL_INDEX) continue;
            int next = slot + 1;
            if (next >= stride || entry[next] == MESH_NULL_INDEX) next = 0;
            ushort* start = &mesh.verts[entry[slot] * 3];
            ushort* end = &mesh.verts[entry[next] * 3];
            if (start[0] == 0 && end[0] == 0) {
                entry[stride + slot] = PORTAL_EDGE | SIDE_NEGATIVE_X;
            } else if ((int)start[2] == height && (int)end[2] == height) {
                entry[stride + slot] = PORTAL_EDGE | SIDE_POSITIVE_Z;
            } else if ((int)start[0] == width && (int)end[0] == width) {
                entry[stride + slot] = PORTAL_EDGE | SIDE_POSITIVE_X;
            } else if (start[2] == 0 && end[2] == 0) {
                entry[stride + slot] = PORTAL_EDGE | SIDE_NEGATIVE_Z;
            }
        }
    }
}
