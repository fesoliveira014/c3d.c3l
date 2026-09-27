module c3d::nav;

import std::math;
import c3d;

<* Magic of a layer blob; mirrors DT_TILECACHE_MAGIC. *>
const int LAYER_MAGIC = 'D' << 24 | 'T' << 16 | 'L' << 8 | 'R';

<* Version of a layer blob; 1 upstream, 100 here because the arrays are stored uncompressed. *>
const int LAYER_VERSION = 100;

const char   NO_LAYER_CELL @local = 0xff; // an empty height, an unassigned region or no sweep neighbour
const char   PORTAL_BASE @local = 0xf8; // a traced neighbour of 0xf8 + direction is a portal that way
const char   NO_PORTAL @local = 0x0f; // a contour vertex whose edge is no portal
const char   REMOVE_VERTEX @local = 0x80; // a contour vertex the polygon mesh removes
const char   PORTAL_DIRECTION_MASK @local = 0x0f;
const int    MAX_REGION_NEIGHBOURS @local = 16; // mirrors DT_LAYER_MAX_NEIS
const int    CONTOUR_TRACE_LAPS @local = 2; // mirrors maxTempVerts: the trace buffer holds two laps around the layer
const int    LAYER_POLY_STRIDE @local = (int)MAX_VERTS_PER_POLY; // layer polygons always use the full stride
const int    MAX_REMOVED_EDGES @local = 48; // mirrors MAX_REM_EDGES: the hole a removed vertex leaves
const int    LAYER_VERTEX_BUCKETS @local = 1 << 8; // mirrors VERTEX_BUCKET_COUNT2
const uint   LAYER_HASH_X @local = 0x8da6b343; // upstream's arbitrarily chosen large primes
const uint   LAYER_HASH_Y @local = 0xd8163841;
const uint   LAYER_HASH_Z @local = 0xcb1ab31f;
const int    LAYER_WELD_HEIGHT @local = 2; // cells; mirrors addVertex, which welds vertices this close in Y
const ushort EAR_VERTEX @local = 0x8000; // triangulation flag: the ear at this vertex is a diagonal
const ushort EAR_INDEX_MASK @local = 0x7fff;
const ushort NO_POLY_EDGE @local = 0xff; // an open edge with no portal direction; mirrors buildMeshAdjacency's 0xff
const float  OBSTACLE_BOX_REACH @private = 1.41f; // mirrors upstream's bound on a yawed box's footprint radius

<* Header of a layer blob; heights, areas and connections follow, width * height bytes each. *>
struct LayerHeader {
    int     magic;
    int     version;
    int     tile_x;
    int     tile_z;
    int     tile_layer;
    Aabb    bounds;
    ushort  hmin;
    ushort  hmax;
    char    width;
    char    height;
    char    min_x;
    char    max_x;
    char    min_z;
    char    max_z;
    char[2] _pad0;
}

$assert LayerHeader::size == 56;

<* A layer read into scratch with its region ids; mirrors dtTileCacheLayer. *>
struct TileCacheLayer {
    LayerHeader* header;          // borrows the blob
    char         region_count;
    char[]       heights;         // the arrays borrow the scratch
    char[]       areas;
    char[]       connections;
    char[]       regions;
}

<* Outline of one layer region in cells; mirrors dtTileCacheContour. *>
struct LayerContour {
    char[] verts;    // four per vertex: x, height, z, then the portal direction with REMOVE_VERTEX
    char   region;
    char   area;
}

<* Outlines of every region of a layer; mirrors dtTileCacheContourSet. *>
struct LayerContourSet {
    LayerContour[] contours;    // one per region
}

<* Polygon mesh of a layer in cells; mirrors dtTileCachePolyMesh. *>
struct LayerPolyMesh {
    uint     verts_per_poly;
    uint     vert_count;
    uint     poly_count;
    ushort[] verts;       // 3 per vertex
    ushort[] polys;       // 2 * verts_per_poly per polygon: indices, then neighbours
    ushort[] flags;       // zero from the build
    char[]   areas;
}

struct MonotoneSweep @local {
    ushort sample_count;
    char   id;
    char   neighbour;
}

struct MonotoneRegion @local {
    int                          area;
    char[MAX_REGION_NEIGHBOURS] neighbours;
    char                         neighbour_count;
    char                         id;
    char                         area_id;
}

struct TraceContour @local {
    char[]   verts;       // four per vertex; capacity verts.len / 4
    int      vert_count;
    ushort[] poly;        // simplified vertex positions into verts
    int      poly_count;
}

struct LayerCorner @local {
    char height;
    bool remove;
}

struct LayerPolygon @local {
    char[]   verts;       // four per vertex
    ushort[] indices;     // positions into verts, flagged with EAR_VERTEX
    int      count;
}

struct LayerVertexWeld @local {
    ushort[] verts;
    ushort[] first;       // LAYER_VERTEX_BUCKETS heads, MESH_NULL_INDEX when empty
    ushort[] next;
    int      count;
}

struct LayerPolyMerge @local {
    int value;            // squared length of the shared edge; not positive when the merge is refused
    int first_edge;
    int second_edge;
}

struct LayerEdge @local {
    ushort[2] vertices;
    ushort[2] poly_edges;
    ushort[2] polys;
}

struct LayerCellRange @local {
    int min_x;
    int max_x;
    int min_y;              // relative to hmin
    int max_y;
    int min_z;
    int max_z;
}

<*
 Set the area of every walkable cell inside the upright cylinder; mirrors dtMarkCylinderArea.
 @param origin : "Minimum corner of the layer."
 @param base : "Centre of the bottom disc."
*>
fn void TileCacheLayer.mark_cylinder_area(
    &self,
    Vec3 origin,
    float cell_size,
    float cell_height,
    Vec3 base,
    float radius,
    float height,
    char area,
) {
    float inverse_size = 1.0f / cell_size;
    float inverse_height = 1.0f / cell_height;
    float radius_cells = radius * inverse_size + 0.5f;
    float centre_x = (base.x - origin.x) * inverse_size;
    float centre_z = (base.z - origin.z) * inverse_size;
    LayerCellRange range = {
        .min_x = (int)math::floor((base.x - radius - origin.x) * inverse_size),
        .min_y = (int)math::floor((base.y - origin.y) * inverse_height),
        .min_z = (int)math::floor((base.z - radius - origin.z) * inverse_size),
        .max_x = (int)math::floor((base.x + radius - origin.x) * inverse_size),
        .max_y = (int)math::floor((base.y + height - origin.y) * inverse_height),
        .max_z = (int)math::floor((base.z + radius - origin.z) * inverse_size),
    };
    if (!clamp_layer_range(self, &range)) return;

    int width = self.header.width;
    for (int z = range.min_z; z <= range.max_z; z++) {
        for (int x = range.min_x; x <= range.max_x; x++) {
            float delta_x = (float)x + 0.5f - centre_x;
            float delta_z = (float)z + 0.5f - centre_z;
            if (delta_x * delta_x + delta_z * delta_z > radius_cells * radius_cells) continue;
            mark_layer_cell(self, &range, (usz)(x + z * width), area);
        }
    }
}

<*
 Set the area of every walkable cell inside the box; mirrors dtMarkBoxArea.
 @param origin : "Minimum corner of the layer."
 @param box : "World space."
*>
fn void TileCacheLayer.mark_box_area(
    &self,
    Vec3 origin,
    float cell_size,
    float cell_height,
    Aabb box,
    char area,
) {
    float inverse_size = 1.0f / cell_size;
    float inverse_height = 1.0f / cell_height;
    LayerCellRange range = {
        .min_x = (int)math::floor((box.min.x - origin.x) * inverse_size),
        .min_y = (int)math::floor((box.min.y - origin.y) * inverse_height),
        .min_z = (int)math::floor((box.min.z - origin.z) * inverse_size),
        .max_x = (int)math::floor((box.max.x - origin.x) * inverse_size),
        .max_y = (int)math::floor((box.max.y - origin.y) * inverse_height),
        .max_z = (int)math::floor((box.max.z - origin.z) * inverse_size),
    };
    if (!clamp_layer_range(self, &range)) return;

    int width = self.header.width;
    for (int z = range.min_z; z <= range.max_z; z++) {
        for (int x = range.min_x; x <= range.max_x; x++) mark_layer_cell(self, &range, (usz)(x + z * width), area);
    }
}

<*
 Set the area of every walkable cell inside the box turned about Y; mirrors the oriented dtMarkBoxArea.
 @param origin : "Minimum corner of the layer."
 @param rotation : "Half-yaw terms from yaw_rotation, as upstream's rotAux."
*>
fn void TileCacheLayer.mark_oriented_box_area(
    &self,
    Vec3 origin,
    float cell_size,
    float cell_height,
    Vec3 centre,
    Vec3 half_extents,
    float[2] rotation,
    char area,
) {
    float inverse_size = 1.0f / cell_size;
    float inverse_height = 1.0f / cell_height;
    float centre_x = (centre.x - origin.x) * inverse_size;
    float centre_z = (centre.z - origin.z) * inverse_size;
    float reach = OBSTACLE_BOX_REACH * math::max(half_extents.x, half_extents.z) * inverse_size;
    LayerCellRange range = {
        .min_x = (int)math::floor(centre_x - reach),
        .min_y = (int)math::floor((centre.y - half_extents.y - origin.y) * inverse_height),
        .min_z = (int)math::floor(centre_z - reach),
        .max_x = (int)math::floor(centre_x + reach),
        .max_y = (int)math::floor((centre.y + half_extents.y - origin.y) * inverse_height),
        .max_z = (int)math::floor(centre_z + reach),
    };
    if (!clamp_layer_range(self, &range)) return;

    float half_x = half_extents.x * inverse_size + 0.5f;
    float half_z = half_extents.z * inverse_size + 0.5f;
    int width = self.header.width;
    for (int z = range.min_z; z <= range.max_z; z++) {
        for (int x = range.min_x; x <= range.max_x; x++) {
            float offset_x = 2.0f * ((float)x - centre_x);
            float offset_z = 2.0f * ((float)z - centre_z);
            float along_x = rotation[1] * offset_x + rotation[0] * offset_z;
            if (along_x > half_x || along_x < -half_x) continue;
            float along_z = rotation[1] * offset_z - rotation[0] * offset_x;
            if (along_z > half_z || along_z < -half_z) continue;
            mark_layer_cell(self, &range, (usz)(x + z * width), area);
        }
    }
}

<*
 Set the area of every walkable cell inside the polygon extruded between the heights.
 The layer twin of CompactHeightfield.mark_convex_poly_area.
 @param origin : "Minimum corner of the layer."
 @param vertices : "World space; Y is ignored."
 @require vertices.len >= 3
*>
fn void TileCacheLayer.mark_convex_poly_area(
    &self,
    Vec3 origin,
    float cell_size,
    float cell_height,
    Vec3[] vertices,
    float min_y,
    float max_y,
    char area,
) {
    Aabb bounds = { .min = vertices[0], .max = vertices[0] };
    foreach (vertex : vertices[1..]) {
        bounds.min = math::min(bounds.min, vertex);
        bounds.max = math::max(bounds.max, vertex);
    }
    // Truncating casts, as the compact heightfield's marking has them.
    LayerCellRange range = {
        .min_x = (int)((bounds.min.x - origin.x) / cell_size),
        .min_y = (int)((min_y - origin.y) / cell_height),
        .min_z = (int)((bounds.min.z - origin.z) / cell_size),
        .max_x = (int)((bounds.max.x - origin.x) / cell_size),
        .max_y = (int)((max_y - origin.y) / cell_height),
        .max_z = (int)((bounds.max.z - origin.z) / cell_size),
    };
    if (!clamp_layer_range(self, &range)) return;

    int width = self.header.width;
    for (int z = range.min_z; z <= range.max_z; z++) {
        for (int x = range.min_x; x <= range.max_x; x++) {
            Vec3 centre = { origin.x + ((float)x + 0.5f) * cell_size, 0, origin.z + ((float)z + 0.5f) * cell_size };
            if (point_in_polygon(centre, vertices)) mark_layer_cell(self, &range, (usz)(x + z * width), area);
        }
    }
}

<*
 Partition the layer into monotone regions; mirrors dtBuildTileCacheRegions.
 Writes regions and region_count.
 @param scratch : "Holds the sweeps and region records for the call."
 @param walkable_climb : "Voxels."
 @return? c3d::CAPACITY_EXCEEDED
*>
fn void? TileCacheLayer.build_regions(&self, Allocator scratch, uint walkable_climb) {
    int width = self.header.width;
    int height = self.header.height;
    int climb = (int)walkable_climb;
    self.regions[..] = NO_LAYER_CELL;

    MonotoneSweep[]? sweeps = alloc::new_array_try(scratch, MonotoneSweep, width);
    if (catch sweeps) return c3d::CAPACITY_EXCEEDED~;
    defer alloc::free(scratch, sweeps.ptr);

    int[256] row_samples;
    char next_region;
    for (int z = 0; z < height; z++) {
        row_samples[:next_region] = 0;
        char next_sweep;
        for (int x = 0; x < width; x++) {
            usz cell = (usz)(x + z * width);
            if (self.areas[cell] == NULL_AREA) continue;

            char sweep = NO_LAYER_CELL;
            if (x > 0 && layer_cells_connected(self, cell, cell - 1, climb)) sweep = self.regions[cell - 1];
            if (sweep == NO_LAYER_CELL) {
                sweep = next_sweep++;
                sweeps[sweep].neighbour = NO_LAYER_CELL;
                sweeps[sweep].sample_count = 0;
            }
            if (z > 0 && layer_cells_connected(self, cell, cell - (usz)width, climb)) {
                char neighbour = self.regions[cell - (usz)width];
                if (neighbour != NO_LAYER_CELL) {
                    if (sweeps[sweep].sample_count == 0) sweeps[sweep].neighbour = neighbour;
                    if (sweeps[sweep].neighbour == neighbour) {
                        sweeps[sweep].sample_count++;
                        row_samples[neighbour]++;
                    } else {
                        // A second region below invalidates the merge.
                        sweeps[sweep].neighbour = NO_LAYER_CELL;
                    }
                }
            }
            self.regions[cell] = sweep;
        }

        foreach (&sweep : sweeps[:next_sweep]) {
            if (sweep.neighbour != NO_LAYER_CELL && row_samples[sweep.neighbour] == sweep.sample_count) {
                sweep.id = sweep.neighbour;
                continue;
            }
            if (next_region == NO_LAYER_CELL) return c3d::CAPACITY_EXCEEDED~;
            sweep.id = next_region++;
        }
        foreach (&region : self.regions[(usz)(z * width):width]) {
            if (*region != NO_LAYER_CELL) *region = sweeps[*region].id;
        }
    }

    MonotoneRegion[]? records = alloc::new_array_try(scratch, MonotoneRegion, next_region);
    if (catch records) return c3d::CAPACITY_EXCEEDED~;
    defer alloc::free(scratch, records.ptr);
    foreach (&record : records) record.id = NO_LAYER_CELL;

    for (int z = 0; z < height; z++) {
        for (int x = 0; x < width; x++) {
            usz cell = (usz)(x + z * width);
            char region = self.regions[cell];
            if (region == NO_LAYER_CELL) continue;
            records[region].area++;
            records[region].area_id = self.areas[cell];
            if (z == 0 || !layer_cells_connected(self, cell, cell - (usz)width, climb)) continue;
            char below = self.regions[cell - (usz)width];
            if (below == NO_LAYER_CELL || below == region) continue;
            add_region_neighbour(&records[region], below)!;
            add_region_neighbour(&records[below], region)!;
        }
    }

    foreach (index, &record : records) record.id = (char)index;
    foreach (&record : records) {
        int merge = -1;
        int merge_area;
        foreach (neighbour_id : record.neighbours[:record.neighbour_count]) {
            MonotoneRegion* neighbour = &records[neighbour_id];
            if (record.id == neighbour.id || record.area_id != neighbour.area_id) continue;
            if (neighbour.area <= merge_area || !can_merge_regions(record.id, neighbour.id, records)) continue;
            merge_area = neighbour.area;
            merge = neighbour_id;
        }
        if (merge == -1) continue;
        char old_id = record.id;
        char new_id = records[merge].id;
        foreach (&renamed : records) {
            if (renamed.id == old_id) renamed.id = new_id;
        }
    }

    char[256] remap;
    foreach (&record : records) remap[record.id] = 1;
    char region_count;
    foreach (&id : remap) {
        if (*id) *id = region_count++;
    }
    foreach (&record : records) record.id = remap[record.id];
    self.region_count = region_count;
    foreach (&region : self.regions) {
        if (*region != NO_LAYER_CELL) *region = records[*region].id;
    }
}

<*
 Trace and simplify the outline of every layer region; mirrors dtBuildTileCacheContours.
 @param allocator : "Receives the contour set; never freed by the result."
 @param scratch : "Holds the trace buffers for the call."
 @param [&in] layer : "Regions built."
 @param walkable_climb : "Voxels."
 @param max_error : "Cells a simplified edge may leave the traced outline."
 @return? c3d::CAPACITY_EXCEEDED
*>
fn LayerContourSet? build_tile_cache_contours(
    Allocator allocator,
    Allocator scratch,
    TileCacheLayer* layer,
    uint walkable_climb,
    float max_error,
) {
    int width = layer.header.width;
    int height = layer.header.height;
    LayerContour[]? contours = alloc::new_array_try(allocator, LayerContour, layer.region_count);
    if (catch contours) return c3d::CAPACITY_EXCEEDED~;

    sz trace_capacity = (sz)(width + height) * 2 * CONTOUR_TRACE_LAPS;
    char[]? trace_verts = alloc::alloc_array_try(scratch, char, trace_capacity * 4);
    if (catch trace_verts) return c3d::CAPACITY_EXCEEDED~;
    defer alloc::free(scratch, trace_verts.ptr);
    ushort[]? trace_poly = alloc::alloc_array_try(scratch, ushort, trace_capacity);
    if (catch trace_poly) return c3d::CAPACITY_EXCEEDED~;
    defer alloc::free(scratch, trace_poly.ptr);
    TraceContour trace = { .verts = trace_verts, .poly = trace_poly };

    for (int z = 0; z < height; z++) {
        for (int x = 0; x < width; x++) {
            usz cell = (usz)(x + z * width);
            char region = layer.regions[cell];
            if (region == NO_LAYER_CELL) continue;
            LayerContour* contour = &contours[region];
            if (contour.verts.len > 0) continue;
            contour.region = region;
            contour.area = layer.areas[cell];

            if (!walk_layer_contour(layer, x, z, &trace)) return c3d::CAPACITY_EXCEEDED~;
            simplify_layer_contour(&trace, max_error);
            if (trace.vert_count == 0) continue;

            char[]? verts = alloc::alloc_array_try(allocator, char, (sz)trace.vert_count * 4);
            if (catch verts) return c3d::CAPACITY_EXCEEDED~;
            int previous = trace.vert_count - 1;
            for (int current = 0; current < trace.vert_count; previous = current++) {
                char* source = &trace.verts[previous * 4];
                // The neighbour of a segment is stored at its end vertex.
                char neighbour = trace.verts[current * 4 + 3];
                LayerCorner corner = layer_corner_height(
                    layer:          layer,
                    x:              source[0],
                    y:              source[1],
                    z:              source[2],
                    walkable_climb: (int)walkable_climb,
                );
                char* target = &verts[previous * 4];
                target[0] = source[0];
                target[1] = corner.height;
                target[2] = source[2];
                target[3] = neighbour != NO_LAYER_CELL && neighbour >= PORTAL_BASE ? (char)(neighbour - PORTAL_BASE) : NO_PORTAL;
                if (corner.remove) target[3] |= REMOVE_VERTEX;
            }
            contour.verts = verts;
        }
    }
    return { .contours = contours };
}

<*
 Triangulate every layer contour and merge the triangles into convex polygons; mirrors dtBuildTileCachePolyMesh.
 @param allocator : "Receives the mesh arrays; never freed by the result."
 @param scratch : "Holds the vertex hash, triangulation and merge buffers for the call."
 @param [&in] contours : "Built by build_tile_cache_contours."
 @return? c3d::CAPACITY_EXCEEDED
*>
fn LayerPolyMesh? build_tile_cache_poly_mesh(Allocator allocator, Allocator scratch, LayerContourSet* contours) {
    int max_vertices;
    int max_triangles;
    int largest_contour;
    foreach (&contour : contours.contours) {
        int count = (int)(contour.verts.len / 4);
        if (count < 3) continue;
        max_vertices += count;
        max_triangles += count - 2;
        largest_contour = math::max(largest_contour, count);
    }
    if (max_vertices >= MESH_NULL_INDEX) return c3d::CAPACITY_EXCEEDED~;

    ushort[]? verts = alloc::new_array_try(allocator, ushort, (sz)max_vertices * 3);
    if (catch verts) return c3d::CAPACITY_EXCEEDED~;
    ushort[]? polys = alloc::alloc_array_try(allocator, ushort, (sz)max_triangles * LAYER_POLY_STRIDE * 2);
    if (catch polys) return c3d::CAPACITY_EXCEEDED~;
    ushort[]? flags = alloc::new_array_try(allocator, ushort, max_triangles);
    if (catch flags) return c3d::CAPACITY_EXCEEDED~;
    char[]? areas = alloc::new_array_try(allocator, char, max_triangles);
    if (catch areas) return c3d::CAPACITY_EXCEEDED~;
    polys[..] = MESH_NULL_INDEX;
    LayerPolyMesh mesh = {
        .verts_per_poly = MAX_VERTS_PER_POLY,
        .verts          = verts,
        .polys          = polys,
        .flags          = flags,
        .areas          = areas,
    };

    bool[]? vertex_flags = alloc::new_array_try(scratch, bool, max_vertices);
    if (catch vertex_flags) return c3d::CAPACITY_EXCEEDED~;
    defer alloc::free(scratch, vertex_flags.ptr);
    ushort[]? next_vertex = alloc::new_array_try(scratch, ushort, max_vertices);
    if (catch next_vertex) return c3d::CAPACITY_EXCEEDED~;
    defer alloc::free(scratch, next_vertex.ptr);
    ushort[]? indices = alloc::alloc_array_try(scratch, ushort, largest_contour);
    if (catch indices) return c3d::CAPACITY_EXCEEDED~;
    defer alloc::free(scratch, indices.ptr);
    ushort[]? triangles = alloc::alloc_array_try(scratch, ushort, (sz)largest_contour * 3);
    if (catch triangles) return c3d::CAPACITY_EXCEEDED~;
    defer alloc::free(scratch, triangles.ptr);
    ushort[]? buffer = alloc::alloc_array_try(scratch, ushort, (sz)largest_contour * LAYER_POLY_STRIDE);
    if (catch buffer) return c3d::CAPACITY_EXCEEDED~;
    defer alloc::free(scratch, buffer.ptr);

    ushort[LAYER_VERTEX_BUCKETS] first_vertex;
    first_vertex[..] = MESH_NULL_INDEX;
    LayerVertexWeld weld = { .verts = verts, .first = first_vertex[..], .next = next_vertex };

    foreach (&contour : contours.contours) {
        int count = (int)(contour.verts.len / 4);
        if (count < 3) continue;

        for (int vertex = 0; vertex < count; vertex++) indices[vertex] = (ushort)vertex;
        int triangle_count = triangulate_layer(
            count:     count,
            verts:     contour.verts,
            indices:   indices,
            triangles: triangles,
        );
        // A contour simplified too aggressively still yields the triangles found before the failure.
        if (triangle_count <= 0) triangle_count = -triangle_count;

        for (int vertex = 0; vertex < count; vertex++) {
            char* point = &contour.verts[vertex * 4];
            indices[vertex] = add_layer_vertex(&weld, point[0], point[1], point[2]);
            if ((point[3] & REMOVE_VERTEX) != 0) vertex_flags[indices[vertex]] = true;
        }

        buffer[..] = MESH_NULL_INDEX;
        int poly_count;
        for (int triangle = 0; triangle < triangle_count; triangle++) {
            ushort* corners = &triangles[triangle * 3];
            if (corners[0] == corners[1] || corners[0] == corners[2] || corners[1] == corners[2]) continue;
            ushort[] poly = buffer[(sz)poly_count * LAYER_POLY_STRIDE:LAYER_POLY_STRIDE];
            poly[0] = indices[corners[0]];
            poly[1] = indices[corners[1]];
            poly[2] = indices[corners[2]];
            poly_count++;
        }
        if (poly_count == 0) continue;
        poly_count = merge_layer_polygons(
            polys: buffer,
            areas: {},
            count: poly_count,
            verts: verts,
        );

        for (int poly = 0; poly < poly_count; poly++) {
            if ((int)mesh.poly_count >= max_triangles) return c3d::CAPACITY_EXCEEDED~;
            layer_mesh_polygon(&mesh, (int)mesh.poly_count)[..] = buffer[(sz)poly * LAYER_POLY_STRIDE:LAYER_POLY_STRIDE];
            mesh.areas[mesh.poly_count] = contour.area;
            mesh.poly_count++;
        }
    }
    mesh.vert_count = (uint)weld.count;

    for (int vertex = 0; vertex < (int)mesh.vert_count; vertex++) {
        if (!vertex_flags[vertex]) continue;
        if (!can_remove_layer_vertex(&mesh, (ushort)vertex)) continue;
        remove_layer_vertex(&mesh, (ushort)vertex, max_triangles)!;
        for (int shifted = vertex; shifted < (int)mesh.vert_count; shifted++) {
            vertex_flags[shifted] = vertex_flags[shifted + 1];
        }
        vertex--;
    }

    build_layer_mesh_adjacency(scratch, &mesh, contours)!;
    mesh.verts = verts[:(sz)mesh.vert_count * 3];
    mesh.polys = polys[:(sz)mesh.poly_count * LAYER_POLY_STRIDE * 2];
    mesh.flags = flags[:mesh.poly_count];
    mesh.areas = areas[:mesh.poly_count];
    return mesh;
}

<*
 Bytes the header and arrays of the layer's blob take.
 @param [&in] layer : "Built by build_heightfield_layers."
*>
fn usz layer_blob_size(HeightfieldLayer* layer) => LayerHeader::size + (usz)layer.width * layer.height * 3;

<*
 Pack a layer into a blob; mirrors dtBuildTileCacheLayer without the compressor.
 @param [&in] layer : "Built by build_heightfield_layers."
 @param [out] blob : "layer_blob_size bytes, 4-byte aligned."
 @require layer.width <= 255 && layer.height <= 255
 @require blob.len == layer_blob_size(layer)
*>
fn void build_tile_cache_layer(
    HeightfieldLayer* layer,
    int tile_x,
    int tile_z,
    int tile_layer,
    char[] blob,
) {
    *(LayerHeader*)blob.ptr = {
        .magic      = LAYER_MAGIC,
        .version    = LAYER_VERSION,
        .tile_x     = tile_x,
        .tile_z     = tile_z,
        .tile_layer = tile_layer,
        .bounds     = layer.bounds,
        .hmin       = (ushort)layer.hmin,
        .hmax       = (ushort)layer.hmax,
        .width      = (char)layer.width,
        .height     = (char)layer.height,
        .min_x      = (char)layer.min_x,
        .max_x      = (char)layer.max_x,
        .min_z      = (char)layer.min_z,
        .max_z      = (char)layer.max_z,
    };
    usz cells = (usz)layer.width * layer.height;
    char[] arrays = blob[LayerHeader::size..];
    arrays[:cells] = layer.heights[..];
    arrays[cells:cells] = layer.areas[..];
    arrays[cells * 2:cells] = layer.connections[..];
}

<*
 Copy a blob's arrays into the scratch, where marking and region building write; mirrors dtDecompressTileCacheLayer.
 @param blob : "4-byte aligned; the header stays borrowed."
 @param scratch : "At least four bytes per cell of the blob's layer."
 @return? LAYER_CORRUPTED
*>
fn TileCacheLayer? read_tile_cache_layer(char[] blob, char[] scratch) {
    if (blob.len < LayerHeader::size) return LAYER_CORRUPTED~;
    LayerHeader* header = (LayerHeader*)blob.ptr;
    if (header.magic != LAYER_MAGIC || header.version != LAYER_VERSION) return LAYER_CORRUPTED~;
    usz cells = (usz)header.width * header.height;
    if (blob.len != LayerHeader::size + cells * 3) return LAYER_CORRUPTED~;

    scratch[:cells * 3] = blob[LayerHeader::size:cells * 3];
    return {
        .header      = header,
        .heights     = scratch[:cells],
        .areas       = scratch[cells:cells],
        .connections = scratch[cells * 2:cells],
        .regions     = scratch[cells * 3:cells],
    };
}

<*
 Bytes the TileMesh blob of a layer mesh needs.
 @param [&in] mesh : "Built by build_tile_cache_poly_mesh."
*>
fn usz layer_tile_mesh_size(LayerPolyMesh* mesh) {
    PolyMesh counts = {
        .vert_count     = mesh.vert_count,
        .poly_count     = mesh.poly_count,
        .verts_per_poly = mesh.verts_per_poly,
    };
    return tile_mesh_size(&counts);
}

<*
 Pack a layer mesh as a TileMesh blob at the layer's tile and bounds, so create_tile_data reads it.
 @param [&in] mesh : "Built by build_tile_cache_poly_mesh."
 @param [&in] header : "Of the layer the mesh was built from."
 @param [out] blob : "layer_tile_mesh_size(mesh) bytes, 4-byte aligned."
*>
fn void pack_layer_tile_mesh(
    LayerPolyMesh* mesh,
    LayerHeader* header,
    float cell_size,
    float cell_height,
    char[] blob,
) {
    blob[..] = 0;
    *(TileMeshHeader*)blob.ptr = {
        .tile_x         = header.tile_x,
        .tile_z         = header.tile_z,
        .vert_count     = mesh.vert_count,
        .poly_count     = mesh.poly_count,
        .verts_per_poly = mesh.verts_per_poly,
        .bounds         = header.bounds,
        .cell_size      = cell_size,
        .cell_height    = cell_height,
    };
    TileMeshView view = tile_mesh_view(blob);
    view.verts[..] = mesh.verts[..];
    view.polys[..] = mesh.polys[..];
    view.flags[..] = mesh.flags[..];
    view.areas[..] = mesh.areas[..];
}

// Upstream's rotAux for a yaw about +Y: the half-angle terms mark_oriented_box_area reads.
fn float[2] yaw_rotation(float yaw_radians) @private {
    float cos_half = math::cos(0.5f * yaw_radians);
    float sin_half = math::sin(-0.5f * yaw_radians);
    return { cos_half * sin_half, cos_half * cos_half - 0.5f };
}

// False when the range misses the layer; X and Z are clamped, Y is not, as upstream.
fn bool clamp_layer_range(TileCacheLayer* layer, LayerCellRange* range) @local {
    int width = layer.header.width;
    int height = layer.header.height;
    if (range.max_x < 0 || range.min_x >= width || range.max_z < 0 || range.min_z >= height) return false;
    range.min_x = math::max(range.min_x, 0);
    range.max_x = math::min(range.max_x, width - 1);
    range.min_z = math::max(range.min_z, 0);
    range.max_z = math::min(range.max_z, height - 1);
    return true;
}

// Empty and eroded cells keep NULL_AREA, so a volume marking a walkable area never revives them.
fn void mark_layer_cell(
    TileCacheLayer* layer,
    LayerCellRange* range,
    usz cell,
    char area,
) @local {
    int floor = layer.heights[cell];
    if (floor < range.min_y || floor > range.max_y || layer.areas[cell] == NULL_AREA) return;
    layer.areas[cell] = area;
}

fn bool layer_cells_connected(
    TileCacheLayer* layer,
    usz first,
    usz second,
    int walkable_climb,
) @local {
    if (layer.areas[first] != layer.areas[second]) return false;
    return math::abs((int)layer.heights[first] - (int)layer.heights[second]) <= walkable_climb;
}

fn void? add_region_neighbour(MonotoneRegion* region, char neighbour) @local {
    if (region.neighbour_count > 0 && region.neighbours[region.neighbour_count - 1] == neighbour) return;
    // Upstream writes past the list; a dropped neighbour could merge regions that meet twice.
    if (region.neighbour_count == MAX_REGION_NEIGHBOURS) return c3d::CAPACITY_EXCEEDED~;
    region.neighbours[region.neighbour_count++] = neighbour;
}

// Regions meeting exactly once keep the merged region monotone.
fn bool can_merge_regions(char old_id, char new_id, MonotoneRegion[] records) @local {
    int count;
    foreach (&record : records) {
        if (record.id != old_id) continue;
        foreach (neighbour : record.neighbours[:record.neighbour_count]) {
            if (records[neighbour].id == new_id) count++;
        }
    }
    return count == 1;
}

// Region across the edge in the direction; PORTAL_BASE + direction for a portal, NO_LAYER_CELL for a wall.
fn char layer_neighbour_region(
    TileCacheLayer* layer,
    int x,
    int z,
    int direction,
) @local {
    int width = layer.header.width;
    char connections = layer.connections[(usz)(x + z * width)];
    char mask = (char)(1 << direction);
    if ((connections & mask) == 0) return ((connections >> 4) & mask) != 0 ? (char)(PORTAL_BASE + direction) : NO_LAYER_CELL;
    return layer.regions[(usz)(x + dir_offset_x((uint)direction) + (z + dir_offset_z((uint)direction)) * width)];
}

// False when the outline outgrows the trace buffer.
fn bool walk_layer_contour(
    TileCacheLayer* layer,
    int x,
    int z,
    TraceContour* trace,
) @local {
    int width = layer.header.width;
    trace.vert_count = 0;
    char region = layer.regions[(usz)(x + z * width)];

    int start_x = x;
    int start_z = z;
    int start_direction = -1;
    for (int turn = 0; turn < 4; turn++) {
        int direction = (turn + 3) & 3;
        if (layer_neighbour_region(layer, x, z, direction) != region) {
            start_direction = direction;
            break;
        }
    }
    if (start_direction == -1) return true;

    int direction = start_direction;
    int max_iterations = width * layer.header.height;
    for (int iteration = 0; iteration < max_iterations; iteration++) {
        char neighbour = layer_neighbour_region(layer, x, z, direction);
        int next_x = x;
        int next_z = z;
        int next_direction;
        if (neighbour != layer.regions[(usz)(x + z * width)]) {
            int corner_x = x;
            int corner_z = z;
            switch (direction) {
                case 0:
                    corner_z++;
                case 1:
                    corner_x++;
                    corner_z++;
                case 2:
                    corner_x++;
            }
            if (!append_layer_vertex(
                trace:  trace,
                x:      corner_x,
                y:      layer.heights[(usz)(x + z * width)],
                z:      corner_z,
                region: neighbour,
            )) {
                return false;
            }
            next_direction = (direction + 1) & 3;
        } else {
            next_x = x + dir_offset_x((uint)direction);
            next_z = z + dir_offset_z((uint)direction);
            next_direction = (direction + 3) & 3;
        }
        if (iteration > 0 && x == start_x && z == start_z && direction == start_direction) break;
        x = next_x;
        z = next_z;
        direction = next_direction;
    }

    char* last = &trace.verts[(trace.vert_count - 1) * 4];
    char* first = &trace.verts[0];
    if (last[0] == first[0] && last[2] == first[2]) trace.vert_count--;
    return true;
}

// Extends the last segment instead when the new vertex continues it along X or Z.
fn bool append_layer_vertex(
    TraceContour* trace,
    int x,
    int y,
    int z,
    char region,
) @local {
    if (trace.vert_count > 1) {
        char* previous = &trace.verts[(trace.vert_count - 2) * 4];
        char* last = &trace.verts[(trace.vert_count - 1) * 4];
        if (last[3] == region) {
            if (previous[0] == last[0] && (int)last[0] == x) {
                last[1] = (char)y;
                last[2] = (char)z;
                return true;
            }
            if (previous[2] == last[2] && (int)last[2] == z) {
                last[0] = (char)x;
                last[1] = (char)y;
                return true;
            }
        }
    }
    if ((usz)(trace.vert_count + 1) * 4 > trace.verts.len) return false;
    char* vertex = &trace.verts[trace.vert_count * 4];
    vertex[0] = (char)x;
    vertex[1] = (char)y;
    vertex[2] = (char)z;
    vertex[3] = region;
    trace.vert_count++;
    return true;
}

fn float cell_distance_pt_seg(
    int x,
    int z,
    int start_x,
    int start_z,
    int end_x,
    int end_z,
) @local {
    float segment_x = (float)(end_x - start_x);
    float segment_z = (float)(end_z - start_z);
    float delta_x = (float)(x - start_x);
    float delta_z = (float)(z - start_z);
    float length_sq = segment_x * segment_x + segment_z * segment_z;
    float t = segment_x * delta_x + segment_z * delta_z;
    if (length_sq > 0) t /= length_sq;
    t = math::clamp(t, 0.0f, 1.0f);
    delta_x = start_x + t * segment_x - x;
    delta_z = start_z + t * segment_z - z;
    return delta_x * delta_x + delta_z * delta_z;
}

// Keeps region transitions, then adds the farthest traced vertex until every one lies within max_error.
fn void simplify_layer_contour(TraceContour* trace, float max_error) @local {
    int count = trace.vert_count;
    trace.poly_count = 0;
    for (int vertex = 0; vertex < count; vertex++) {
        int next = (vertex + 1) % count;
        if (trace.verts[next * 4 + 3] != trace.verts[vertex * 4 + 3]) trace.poly[trace.poly_count++] = (ushort)vertex;
    }
    if (trace.poly_count < 2) {
        // Without transitions the lower-left and upper-right vertices seed the outline.
        int lower_left;
        int upper_right;
        for (int vertex = 1; vertex < count; vertex++) {
            char* point = &trace.verts[vertex * 4];
            char* low = &trace.verts[lower_left * 4];
            char* high = &trace.verts[upper_right * 4];
            if (point[0] < low[0] || (point[0] == low[0] && point[2] < low[2])) lower_left = vertex;
            if (point[0] > high[0] || (point[0] == high[0] && point[2] > high[2])) upper_right = vertex;
        }
        trace.poly[0] = (ushort)lower_left;
        trace.poly[1] = (ushort)upper_right;
        trace.poly_count = 2;
    }

    int segment = 0;
    while (segment < trace.poly_count) {
        int next = (segment + 1) % trace.poly_count;
        int start = trace.poly[segment];
        int end = trace.poly[next];
        int start_x = trace.verts[start * 4];
        int start_z = trace.verts[start * 4 + 2];
        int end_x = trace.verts[end * 4];
        int end_z = trace.verts[end * 4 + 2];

        // Walked in lexicographic order so opposite segments measure the same deviation.
        int cursor;
        int step;
        int stop;
        if (end_x > start_x || (end_x == start_x && end_z > start_z)) {
            step = 1;
            cursor = (start + step) % count;
            stop = end;
        } else {
            step = count - 1;
            cursor = (end + step) % count;
            stop = start;
        }
        float max_distance = 0;
        int farthest = -1;
        while (cursor != stop) {
            float distance = cell_distance_pt_seg(
                x:       trace.verts[cursor * 4],
                z:       trace.verts[cursor * 4 + 2],
                start_x: start_x,
                start_z: start_z,
                end_x:   end_x,
                end_z:   end_z,
            );
            if (distance > max_distance) {
                max_distance = distance;
                farthest = cursor;
            }
            cursor = (cursor + step) % count;
        }

        if (farthest != -1 && max_distance > max_error * max_error) {
            trace.poly_count++;
            for (int shifted = trace.poly_count - 1; shifted > segment; shifted--) trace.poly[shifted] = trace.poly[shifted - 1];
            trace.poly[segment + 1] = (ushort)farthest;
        } else {
            segment++;
        }
    }

    int first = 0;
    for (int position = 1; position < trace.poly_count; position++) {
        if (trace.poly[position] < trace.poly[first]) first = position;
    }
    trace.vert_count = 0;
    for (int position = 0; position < trace.poly_count; position++) {
        int source = trace.poly[(first + position) % trace.poly_count];
        trace.verts[trace.vert_count * 4:4] = trace.verts[source * 4:4];
        trace.vert_count++;
    }
}

// Highest floor among the four cells at the corner; remove when they share one region and one portal.
fn LayerCorner layer_corner_height(
    TileCacheLayer* layer,
    int x,
    int y,
    int z,
    int walkable_climb,
) @local {
    int width = layer.header.width;
    int height = layer.header.height;
    int count;
    char portals = 0x0f;
    char corner_height;
    char previous_region = NO_LAYER_CELL;
    bool same_region = true;
    for (int offset_z = -1; offset_z <= 0; offset_z++) {
        for (int offset_x = -1; offset_x <= 0; offset_x++) {
            int cell_x = x + offset_x;
            int cell_z = z + offset_z;
            if (cell_x < 0 || cell_z < 0 || cell_x >= width || cell_z >= height) continue;
            usz cell = (usz)(cell_x + cell_z * width);
            int floor = layer.heights[cell];
            if (math::abs(floor - y) > walkable_climb || layer.areas[cell] == NULL_AREA) continue;
            corner_height = math::max(corner_height, (char)floor);
            portals &= layer.connections[cell] >> 4;
            if (previous_region != NO_LAYER_CELL && previous_region != layer.regions[cell]) same_region = false;
            previous_region = layer.regions[cell];
            count++;
        }
    }

    int portal_count;
    for (int direction = 0; direction < 4; direction++) {
        if ((portals & (1 << direction)) != 0) portal_count++;
    }
    return { .height = corner_height, .remove = count > 1 && portal_count == 1 && same_region };
}

fn int byte_area2(char* a, char* b, char* c) @local {
    return ((int)b[0] - (int)a[0]) * ((int)c[2] - (int)a[2]) - ((int)c[0] - (int)a[0]) * ((int)b[2] - (int)a[2]);
}

fn bool byte_left(char* a, char* b, char* c) @local => byte_area2(a, b, c) < 0;

fn bool byte_left_on(char* a, char* b, char* c) @local => byte_area2(a, b, c) <= 0;

fn bool byte_collinear(char* a, char* b, char* c) @local => byte_area2(a, b, c) == 0;

fn bool byte_intersect_prop(
    char* a,
    char* b,
    char* c,
    char* d,
) @local {
    if (byte_collinear(a, b, c) || byte_collinear(a, b, d) || byte_collinear(c, d, a) || byte_collinear(c, d, b)) {
        return false;
    }
    return (byte_left(a, b, c) ^ byte_left(a, b, d)) && (byte_left(c, d, a) ^ byte_left(c, d, b));
}

fn bool byte_between(char* a, char* b, char* c) @local {
    if (!byte_collinear(a, b, c)) return false;
    if (a[0] != b[0]) return (a[0] <= c[0] && c[0] <= b[0]) || (a[0] >= c[0] && c[0] >= b[0]);
    return (a[2] <= c[2] && c[2] <= b[2]) || (a[2] >= c[2] && c[2] >= b[2]);
}

fn bool byte_intersect(
    char* a,
    char* b,
    char* c,
    char* d,
) @local {
    if (byte_intersect_prop(a: a, b: b, c: c, d: d)) return true;
    return byte_between(a, b, c) || byte_between(a, b, d) || byte_between(c, d, a) || byte_between(c, d, b);
}

fn bool byte_equal_xz(char* a, char* b) @local => a[0] == b[0] && a[2] == b[2];

fn char* layer_polygon_vertex(LayerPolygon* polygon, int position) @local {
    return &polygon.verts[(usz)(polygon.indices[position] & EAR_INDEX_MASK) * 4];
}

fn bool layer_diagonalie(LayerPolygon* polygon, int first, int second) @local {
    char* diagonal_start = layer_polygon_vertex(polygon, first);
    char* diagonal_end = layer_polygon_vertex(polygon, second);
    for (int edge = 0; edge < polygon.count; edge++) {
        int edge_next = next_index(edge, polygon.count);
        if (edge == first || edge_next == first || edge == second || edge_next == second) continue;
        char* edge_start = layer_polygon_vertex(polygon, edge);
        char* edge_end = layer_polygon_vertex(polygon, edge_next);
        if (byte_equal_xz(diagonal_start, edge_start) || byte_equal_xz(diagonal_end, edge_start)) continue;
        if (byte_equal_xz(diagonal_start, edge_end) || byte_equal_xz(diagonal_end, edge_end)) continue;
        if (byte_intersect(a: diagonal_start, b: diagonal_end, c: edge_start, d: edge_end)) return false;
    }
    return true;
}

fn bool layer_in_cone(LayerPolygon* polygon, int first, int second) @local {
    char* corner = layer_polygon_vertex(polygon, first);
    char* target = layer_polygon_vertex(polygon, second);
    char* next = layer_polygon_vertex(polygon, next_index(first, polygon.count));
    char* previous = layer_polygon_vertex(polygon, previous_index(first, polygon.count));
    if (byte_left_on(previous, corner, next)) return byte_left(corner, target, previous) && byte_left(target, corner, next);
    return !(byte_left_on(corner, target, next) && byte_left_on(target, corner, previous));
}

fn bool layer_diagonal(LayerPolygon* polygon, int first, int second) @local {
    return layer_in_cone(polygon, first, second) && layer_diagonalie(polygon, first, second);
}

// Negative when the polygon could not be finished; the magnitude counts the triangles written.
fn int triangulate_layer(
    int count,
    char[] verts,
    ushort[] indices,
    ushort[] triangles,
) @local {
    LayerPolygon polygon = { .verts = verts, .indices = indices, .count = count };
    int triangle_count;
    int written;

    for (int vertex = 0; vertex < count; vertex++) {
        int ear = next_index(vertex, count);
        if (layer_diagonal(&polygon, vertex, next_index(ear, count))) indices[ear] |= EAR_VERTEX;
    }

    while (polygon.count > 3) {
        int min_length = -1;
        int best = -1;
        for (int vertex = 0; vertex < polygon.count; vertex++) {
            int ear = next_index(vertex, polygon.count);
            if ((indices[ear] & EAR_VERTEX) == 0) continue;
            char* start = layer_polygon_vertex(&polygon, vertex);
            char* end = layer_polygon_vertex(&polygon, next_index(ear, polygon.count));
            int delta_x = (int)end[0] - (int)start[0];
            int delta_z = (int)end[2] - (int)start[2];
            int length = delta_x * delta_x + delta_z * delta_z;
            if (min_length < 0 || length < min_length) {
                min_length = length;
                best = vertex;
            }
        }
        if (best == -1) return -triangle_count;

        int vertex = best;
        int ear = next_index(vertex, polygon.count);
        int far = next_index(ear, polygon.count);
        triangles[written++] = indices[vertex] & EAR_INDEX_MASK;
        triangles[written++] = indices[ear] & EAR_INDEX_MASK;
        triangles[written++] = indices[far] & EAR_INDEX_MASK;
        triangle_count++;

        polygon.count--;
        for (int shifted = ear; shifted < polygon.count; shifted++) indices[shifted] = indices[shifted + 1];
        if (ear >= polygon.count) ear = 0;
        vertex = previous_index(ear, polygon.count);
        if (layer_diagonal(&polygon, previous_index(vertex, polygon.count), ear)) {
            indices[vertex] |= EAR_VERTEX;
        } else {
            indices[vertex] &= EAR_INDEX_MASK;
        }
        if (layer_diagonal(&polygon, vertex, next_index(ear, polygon.count))) {
            indices[ear] |= EAR_VERTEX;
        } else {
            indices[ear] &= EAR_INDEX_MASK;
        }
    }

    triangles[written++] = indices[0] & EAR_INDEX_MASK;
    triangles[written++] = indices[1] & EAR_INDEX_MASK;
    triangles[written++] = indices[2] & EAR_INDEX_MASK;
    return triangle_count + 1;
}

fn int layer_vertex_hash(int x, int y, int z) @local {
    uint hash = LAYER_HASH_X * (uint)x + LAYER_HASH_Y * (uint)y + LAYER_HASH_Z * (uint)z;
    return (int)(hash & (LAYER_VERTEX_BUCKETS - 1));
}

fn ushort add_layer_vertex(
    LayerVertexWeld* weld,
    ushort x,
    ushort y,
    ushort z,
) @local {
    int bucket = layer_vertex_hash(x, 0, z);
    for (ushort index = weld.first[bucket]; index != MESH_NULL_INDEX; index = weld.next[index]) {
        ushort* existing = &weld.verts[index * 3];
        bool same_column = existing[0] == x && existing[2] == z;
        if (same_column && math::abs((int)existing[1] - (int)y) <= LAYER_WELD_HEIGHT) return index;
    }

    ushort index = (ushort)weld.count++;
    weld.verts[index * 3] = x;
    weld.verts[index * 3 + 1] = y;
    weld.verts[index * 3 + 2] = z;
    weld.next[index] = weld.first[bucket];
    weld.first[bucket] = index;
    return index;
}

fn ushort[] layer_mesh_polygon(LayerPolyMesh* mesh, int index) @local {
    return mesh.polys[(sz)index * LAYER_POLY_STRIDE * 2:LAYER_POLY_STRIDE];
}

fn bool layer_uleft(ushort* a, ushort* b, ushort* c) @local {
    return ((int)b[0] - (int)a[0]) * ((int)c[2] - (int)a[2]) - ((int)c[0] - (int)a[0]) * ((int)b[2] - (int)a[2]) < 0;
}

fn LayerPolyMerge layer_poly_merge_value(ushort[] first, ushort[] second, ushort[] verts) @local {
    int first_count = count_poly_verts(first);
    int second_count = count_poly_verts(second);
    LayerPolyMerge merge = { .value = -1, .first_edge = -1, .second_edge = -1 };
    if (first_count + second_count - 2 > LAYER_POLY_STRIDE) return merge;

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
    if (!layer_uleft(before_first, first_corner, after_second)) return merge;
    ushort* before_second = &verts[second[(other + second_count - 1) % second_count] * 3];
    ushort* second_corner = &verts[second[other] * 3];
    ushort* after_first = &verts[first[(edge + 2) % first_count] * 3];
    if (!layer_uleft(before_second, second_corner, after_first)) return merge;

    ushort* edge_end = &verts[first[(edge + 1) % first_count] * 3];
    int delta_x = (int)first_corner[0] - (int)edge_end[0];
    int delta_z = (int)first_corner[2] - (int)edge_end[2];
    merge.value = delta_x * delta_x + delta_z * delta_z;
    return merge;
}

// Merges the best pair until none is convex; areas, when given, follow their polygons. The polygons left.
fn int merge_layer_polygons(
    ushort[] polys,
    char[] areas,
    int count,
    ushort[] verts,
) @local {
    while (true) {
        LayerPolyMerge best;
        int best_first;
        int best_second;
        for (int first = 0; first < count - 1; first++) {
            for (int second = first + 1; second < count; second++) {
                LayerPolyMerge merge = layer_poly_merge_value(
                    first:  polys[(sz)first * LAYER_POLY_STRIDE:LAYER_POLY_STRIDE],
                    second: polys[(sz)second * LAYER_POLY_STRIDE:LAYER_POLY_STRIDE],
                    verts:  verts,
                );
                if (merge.value <= best.value) continue;
                best = merge;
                best_first = first;
                best_second = second;
            }
        }
        if (best.value <= 0) return count;

        ushort[] target = polys[(sz)best_first * LAYER_POLY_STRIDE:LAYER_POLY_STRIDE];
        ushort[] source = polys[(sz)best_second * LAYER_POLY_STRIDE:LAYER_POLY_STRIDE];
        ushort[LAYER_POLY_STRIDE * 2] merged;
        merged[..] = MESH_NULL_INDEX;
        int target_count = count_poly_verts(target);
        int source_count = count_poly_verts(source);
        int written;
        for (int offset = 0; offset < target_count - 1; offset++) {
            merged[written++] = target[(best.first_edge + 1 + offset) % target_count];
        }
        for (int offset = 0; offset < source_count - 1; offset++) {
            merged[written++] = source[(best.second_edge + 1 + offset) % source_count];
        }
        target[..] = merged[:LAYER_POLY_STRIDE];
        source[..] = polys[(sz)(count - 1) * LAYER_POLY_STRIDE:LAYER_POLY_STRIDE];
        if (areas.len) areas[best_second] = areas[count - 1];
        count--;
    }
}

fn bool can_remove_layer_vertex(LayerPolyMesh* mesh, ushort removed) @local {
    int touched_vertices;
    int remaining_edges;
    for (int poly = 0; poly < (int)mesh.poly_count; poly++) {
        ushort[] entry = layer_mesh_polygon(mesh, poly);
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
    if (touched_vertices * 2 > MAX_REMOVED_EDGES) return false;

    ushort[3][MAX_REMOVED_EDGES] edges;
    int edge_count;
    for (int poly = 0; poly < (int)mesh.poly_count; poly++) {
        ushort[] entry = layer_mesh_polygon(mesh, poly);
        int count = count_poly_verts(entry);
        int previous = count - 1;
        for (int current = 0; current < count; previous = current++) {
            if (entry[current] != removed && entry[previous] != removed) continue;
            ushort other = entry[previous] == removed ? entry[current] : entry[previous];
            bool exists;
            foreach (&edge : edges[:edge_count]) {
                if ((*edge)[1] != other) continue;
                (*edge)[2]++;
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

fn void? remove_layer_vertex(LayerPolyMesh* mesh, ushort removed, int max_triangles) @local {
    ushort[3][MAX_REMOVED_EDGES] edges;
    int edge_count;
    for (int poly = 0; poly < (int)mesh.poly_count; poly++) {
        ushort[] entry = layer_mesh_polygon(mesh, poly);
        int count = count_poly_verts(entry);
        bool has_removed;
        foreach (vertex : entry[:count]) {
            if (vertex == removed) has_removed = true;
        }
        if (!has_removed) continue;

        int previous = count - 1;
        for (int current = 0; current < count; previous = current++) {
            if (entry[current] == removed || entry[previous] == removed) continue;
            if (edge_count >= MAX_REMOVED_EDGES) return c3d::CAPACITY_EXCEEDED~;
            edges[edge_count++] = { entry[previous], entry[current], mesh.areas[poly] };
        }
        int last = (int)mesh.poly_count - 1;
        entry[..] = layer_mesh_polygon(mesh, last)[..];
        mesh.polys[(sz)poly * LAYER_POLY_STRIDE * 2 + LAYER_POLY_STRIDE:LAYER_POLY_STRIDE] = MESH_NULL_INDEX;
        mesh.areas[poly] = mesh.areas[last];
        mesh.poly_count--;
        poly--;
    }

    for (int vertex = removed; vertex < (int)mesh.vert_count - 1; vertex++) {
        mesh.verts[vertex * 3:3] = mesh.verts[(vertex + 1) * 3:3];
    }
    mesh.vert_count--;
    for (int poly = 0; poly < (int)mesh.poly_count; poly++) {
        ushort[] entry = layer_mesh_polygon(mesh, poly);
        foreach (&vertex : entry[:count_poly_verts(entry)]) {
            if (*vertex > removed) (*vertex)--;
        }
    }
    foreach (&edge : edges[:edge_count]) {
        if ((*edge)[0] > removed) (*edge)[0]--;
        if ((*edge)[1] > removed) (*edge)[1]--;
    }
    if (edge_count == 0) return;

    ushort[MAX_REMOVED_EDGES] hole;
    ushort[MAX_REMOVED_EDGES] hole_areas;
    int hole_count = 1;
    hole[0] = edges[0][0];
    hole_areas[0] = edges[0][2];
    while (edge_count > 0) {
        bool matched;
        for (int edge = 0; edge < edge_count; edge++) {
            ushort[3] current = edges[edge];
            bool at_front = hole[0] == current[1];
            if (!at_front && hole[hole_count - 1] != current[0]) continue;
            if (hole_count >= MAX_REMOVED_EDGES) return c3d::CAPACITY_EXCEEDED~;
            if (at_front) {
                for (int shifted = hole_count; shifted > 0; shifted--) {
                    hole[shifted] = hole[shifted - 1];
                    hole_areas[shifted] = hole_areas[shifted - 1];
                }
                hole[0] = current[0];
                hole_areas[0] = current[2];
            } else {
                hole[hole_count] = current[1];
                hole_areas[hole_count] = current[2];
            }
            hole_count++;
            edges[edge] = edges[edge_count - 1];
            edge_count--;
            matched = true;
            edge--;
        }
        if (!matched) break;
    }

    // Upstream sizes the hole vertices three bytes per vertex and writes four.
    char[MAX_REMOVED_EDGES * 4] hole_verts;
    ushort[MAX_REMOVED_EDGES] hole_indices;
    ushort[MAX_REMOVED_EDGES * 3] triangles;
    for (int vertex = 0; vertex < hole_count; vertex++) {
        ushort* source = &mesh.verts[hole[vertex] * 3];
        hole_verts[vertex * 4] = (char)source[0];
        hole_verts[vertex * 4 + 1] = (char)source[1];
        hole_verts[vertex * 4 + 2] = (char)source[2];
        hole_indices[vertex] = (ushort)vertex;
    }
    int triangle_count = triangulate_layer(
        count:     hole_count,
        verts:     hole_verts[..],
        indices:   hole_indices[..],
        triangles: triangles[..],
    );
    if (triangle_count < 0) triangle_count = -triangle_count;
    if (triangle_count > MAX_REMOVED_EDGES) return c3d::CAPACITY_EXCEEDED~;

    ushort[MAX_REMOVED_EDGES * LAYER_POLY_STRIDE] polys;
    char[MAX_REMOVED_EDGES] poly_areas;
    polys[..] = MESH_NULL_INDEX;
    int poly_count;
    for (int triangle = 0; triangle < triangle_count; triangle++) {
        ushort* corners = &triangles[triangle * 3];
        if (corners[0] == corners[1] || corners[0] == corners[2] || corners[1] == corners[2]) continue;
        ushort[] poly = polys[(sz)poly_count * LAYER_POLY_STRIDE:LAYER_POLY_STRIDE];
        poly[0] = hole[corners[0]];
        poly[1] = hole[corners[1]];
        poly[2] = hole[corners[2]];
        poly_areas[poly_count] = (char)hole_areas[corners[0]];
        poly_count++;
    }
    if (poly_count == 0) return;
    poly_count = merge_layer_polygons(
        polys: polys[..],
        areas: poly_areas[..],
        count: poly_count,
        verts: mesh.verts,
    );

    for (int poly = 0; poly < poly_count; poly++) {
        if ((int)mesh.poly_count >= max_triangles) break;
        ushort[] target = mesh.polys[(sz)mesh.poly_count * LAYER_POLY_STRIDE * 2:LAYER_POLY_STRIDE * 2];
        target[..] = MESH_NULL_INDEX;
        target[:LAYER_POLY_STRIDE] = polys[(sz)poly * LAYER_POLY_STRIDE:LAYER_POLY_STRIDE];
        mesh.areas[mesh.poly_count] = poly_areas[poly];
        mesh.poly_count++;
    }
}

fn bool overlap_range_exclusive(
    ushort first_min,
    ushort first_max,
    ushort second_min,
    ushort second_max,
) @local {
    return !(first_min >= second_max || first_max <= second_min);
}

// Links polygons sharing an edge; open edges on a contour portal take PORTAL_EDGE and its direction.
fn void? build_layer_mesh_adjacency(Allocator scratch, LayerPolyMesh* mesh, LayerContourSet* contours) @local {
    sz max_edges = (sz)mesh.poly_count * LAYER_POLY_STRIDE;
    ushort[]? heads = alloc::alloc_array_try(scratch, ushort, mesh.vert_count + max_edges);
    if (catch heads) return c3d::CAPACITY_EXCEEDED~;
    defer alloc::free(scratch, heads.ptr);
    LayerEdge[]? edges = alloc::alloc_array_try(scratch, LayerEdge, max_edges);
    if (catch edges) return c3d::CAPACITY_EXCEEDED~;
    defer alloc::free(scratch, edges.ptr);

    ushort[] first_edge = heads[:mesh.vert_count];
    ushort[] next_edge = heads[mesh.vert_count:max_edges];
    first_edge[..] = MESH_NULL_INDEX;
    int edge_count;
    for (int poly = 0; poly < (int)mesh.poly_count; poly++) {
        ushort[] entry = layer_mesh_polygon(mesh, poly);
        for (int slot = 0; slot < LAYER_POLY_STRIDE; slot++) {
            if (entry[slot] == MESH_NULL_INDEX) break;
            ushort start = entry[slot];
            ushort end = slot + 1 >= LAYER_POLY_STRIDE || entry[slot + 1] == MESH_NULL_INDEX ? entry[0] : entry[slot + 1];
            if (start >= end) continue;
            edges[edge_count] = {
                .vertices   = { start, end },
                .poly_edges = { (ushort)slot, NO_POLY_EDGE },
                .polys      = { (ushort)poly, (ushort)poly },
            };
            next_edge[edge_count] = first_edge[start];
            first_edge[start] = (ushort)edge_count;
            edge_count++;
        }
    }

    for (int poly = 0; poly < (int)mesh.poly_count; poly++) {
        ushort[] entry = layer_mesh_polygon(mesh, poly);
        for (int slot = 0; slot < LAYER_POLY_STRIDE; slot++) {
            if (entry[slot] == MESH_NULL_INDEX) break;
            ushort start = entry[slot];
            ushort end = slot + 1 >= LAYER_POLY_STRIDE || entry[slot + 1] == MESH_NULL_INDEX ? entry[0] : entry[slot + 1];
            if (start <= end) continue;
            bool found;
            for (ushort edge = first_edge[end]; edge != MESH_NULL_INDEX; edge = next_edge[edge]) {
                if (edges[edge].vertices[1] != start || edges[edge].polys[0] != edges[edge].polys[1]) continue;
                edges[edge].polys[1] = (ushort)poly;
                edges[edge].poly_edges[1] = (ushort)slot;
                found = true;
                break;
            }
            if (found) continue;
            // An unmatched reversed edge is open; upstream keeps it for the portal pass.
            edges[edge_count] = {
                .vertices   = { end, start },
                .poly_edges = { (ushort)slot, NO_POLY_EDGE },
                .polys      = { (ushort)poly, (ushort)poly },
            };
            next_edge[edge_count] = first_edge[end];
            first_edge[end] = (ushort)edge_count;
            edge_count++;
        }
    }

    foreach (&contour : contours.contours) {
        int count = (int)(contour.verts.len / 4);
        if (count < 3) continue;
        int previous = count - 1;
        for (int current = 0; current < count; previous = current++) {
            char* start = &contour.verts[previous * 4];
            char* end = &contour.verts[current * 4];
            char direction = start[3] & PORTAL_DIRECTION_MASK;
            if (direction == NO_PORTAL) continue;
            // Portals along X lie on a column line; the rest on a row line.
            usz axis = direction == 0 || direction == 2 ? 0 : 2;
            usz across = 2 - axis;
            ushort line = start[axis];
            ushort low = start[across];
            ushort high = end[across];
            if (low > high) @swap(low, high);
            foreach (&edge : edges[:edge_count]) {
                if (edge.polys[0] != edge.polys[1]) continue;
                ushort* edge_start = &mesh.verts[edge.vertices[0] * 3];
                ushort* edge_end = &mesh.verts[edge.vertices[1] * 3];
                if (edge_start[axis] != line || edge_end[axis] != line) continue;
                ushort edge_low = edge_start[across];
                ushort edge_high = edge_end[across];
                if (edge_low > edge_high) @swap(edge_low, edge_high);
                if (overlap_range_exclusive(low, high, edge_low, edge_high)) edge.poly_edges[1] = direction;
            }
        }
    }

    foreach (edge : edges[:edge_count]) {
        if (edge.polys[0] != edge.polys[1]) {
            mesh.polys[(sz)edge.polys[0] * LAYER_POLY_STRIDE * 2 + LAYER_POLY_STRIDE + edge.poly_edges[0]] = edge.polys[1];
            mesh.polys[(sz)edge.polys[1] * LAYER_POLY_STRIDE * 2 + LAYER_POLY_STRIDE + edge.poly_edges[1]] = edge.polys[0];
        } else if (edge.poly_edges[1] != NO_POLY_EDGE) {
            mesh.polys[(sz)edge.polys[0] * LAYER_POLY_STRIDE * 2 + LAYER_POLY_STRIDE + edge.poly_edges[0]] = (ushort)(PORTAL_EDGE | edge.poly_edges[1]);
        }
    }
}
