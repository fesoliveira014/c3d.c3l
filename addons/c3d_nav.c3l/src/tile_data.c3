module c3d::nav;

import std::math;
import c3d;

<* Flag the build gives every polygon; the default query filter includes it. *>
const ushort POLY_FLAG_WALK = 1;

const usz       TILE_DATA_ALIGNMENT @local = 8;
const float     MAX_BV_COORDINATE @local = 65534;
const char      INSIDE_TILE @local = 0xff; // classify_off_mesh_point of a point inside the tile's XZ
const ushort    PORTAL_SIDE_MASK @local = 0xf;
const ushort[4] DETOUR_PORTAL_SIDE @local = { 4, 2, 0, 6 }; // by Recast side: x-, z+, x+, z-
const char      OUTSIDE_POSITIVE_X @local = 1 << 0;
const char      OUTSIDE_POSITIVE_Z @local = 1 << 1;
const char      OUTSIDE_NEGATIVE_X @local = 1 << 2;
const char      OUTSIDE_NEGATIVE_Z @local = 1 << 3;

<* Off-mesh connection input to create_tile_data. *>
struct OffMeshConnectionDesc {
    Vec3   start;
    Vec3   end;
    float  radius;
    ushort flags;
    char   area;
    bool   bidirectional;
    uint   user_id;
}

<* Agent parameters and tile placement stored into a tile; mirrors the tail of dtNavMeshCreateParams. *>
struct TileDataParams {
    int   tile_x;
    int   tile_z;
    int   tile_layer;
    uint  user_id;
    float walkable_height;     // metres
    float walkable_radius;
    float walkable_climb;
    bool  build_bv_tree;
}

// Byte offsets of the arrays in a TileData blob.
struct TileDataLayout @private {
    usz verts;
    usz detail_corners;
    usz polys;
    usz details;
    usz detail_vertices;
    usz detail_triangles;
    usz detail_portals;
    usz bv_tree;
    usz off_mesh;
    usz size;
}

<*
 Bytes the TileData blob of the mesh and connections needs.
 @param params : "Its walkable_climb bounds the connections kept; build_bv_tree sizes the tree."
*>
fn usz tile_data_size(TileMeshView mesh, OffMeshConnectionDesc[] connections, TileDataParams params) {
    TileHeader header = tile_header(mesh, count_stored_connections(mesh, connections, params.walkable_climb), params);
    return tile_data_layout(&header).size;
}

<*
 Detour tile data from a TileMesh and the off-mesh connections it should carry; mirrors dtCreateNavMeshData.
 Connections whose start lies outside the mesh bounds are dropped; the header counts what was stored.
 @param [out] blob : "tile_data_size bytes, 8-byte aligned."
 @return? c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
 @require mesh.header.poly_count > 0
 @require blob.len == tile_data_size(mesh, connections, params)
*>
fn void? create_tile_data(
    TileMeshView mesh,
    OffMeshConnectionDesc[] connections,
    TileDataParams params,
    char[] blob,
) {
    TileMeshHeader* source = mesh.header;
    validate_tile_parameters(connections, params)!;
    uint stride = source.verts_per_poly;
    if (stride > MAX_VERTS_PER_POLY) return c3d::INVALID_ARGUMENT~;
    uint stored_count = count_stored_connections(mesh, connections, params.walkable_climb);
    if ((usz)source.vert_count + (usz)stored_count * 2 >= MESH_NULL_INDEX) return c3d::INVALID_ARGUMENT~;
    for (uint index = 0; index < source.poly_count; index++) {
        foreach (vertex : mesh.polys[(usz)index * stride * 2:stride]) {
            if (vertex == MESH_NULL_INDEX) break;
            if (vertex >= source.vert_count) return c3d::INVALID_ARGUMENT~;
        }
    }

    blob[..] = 0;
    *(TileHeader*)blob.ptr = tile_header(mesh, stored_count, params);
    MeshTile tile;
    carve_tile_data(&tile, blob);
    tile.details[..] = mesh.details[..];
    tile.detail_vertices[..] = mesh.detail_vertices[..];
    tile.detail_triangles[..] = mesh.detail_triangles[..];
    tile.detail_portals[..] = mesh.detail_portals[..];

    Vec3 scale = { source.cell_size, source.cell_height, source.cell_size };
    for (uint vertex = 0; vertex < source.vert_count; vertex++) {
        ushort* voxel = &mesh.verts[vertex * 3];
        tile.verts[vertex] = source.bounds.min + (Vec3){ (float)voxel[0], (float)voxel[1], (float)voxel[2] } * scale;
        if (source.detail_mode == DetailMode.BOUNDED) {
            tile.detail_corners[vertex] = detail_corner_position(
                bounds: source.bounds,
                origin: source.detail_origin,
                voxel: voxel,
                cell_size: source.cell_size,
                cell_height: source.cell_height,
            );
        }
    }

    for (uint index = 0; index < source.poly_count; index++) {
        ushort[] indices = mesh.polys[(usz)index * stride * 2:stride];
        ushort[] neighbours = mesh.polys[(usz)index * stride * 2 + stride:stride];
        Poly* poly = &tile.polys[index];
        poly.flags = mesh.flags[index] != 0 ? mesh.flags[index] : POLY_FLAG_WALK;
        poly.area_type = { .area = mesh.areas[index], .type = GROUND };
        for (uint slot = 0; slot < stride; slot++) {
            if (indices[slot] == MESH_NULL_INDEX) break;
            poly.verts[slot] = indices[slot];
            poly.neighbours[slot] = detour_neighbour(neighbours[slot]);
            poly.vert_count++;
        }
    }

    if (connections.len) {
        Aabb bounds = connection_bounds(mesh, params.walkable_climb);
        uint stored;
        foreach (connection : connections) {
            if (classify_start(connection.start, bounds) != INSIDE_TILE) continue;
            uint vertex = source.vert_count + stored * 2;
            uint poly = source.poly_count + stored;
            tile.verts[vertex] = connection.start;
            tile.verts[vertex + 1] = connection.end;
            tile.polys[poly] = {
                .verts      = { [0] = (ushort)vertex, [1] = (ushort)(vertex + 1) },
                .flags      = connection.flags,
                .vert_count = 2,
                .area_type  = { .area = connection.area, .type = OFF_MESH_CONNECTION },
            };
            tile.off_mesh[stored] = {
                .start   = connection.start,
                .end     = connection.end,
                .radius  = connection.radius,
                .poly    = (ushort)poly,
                .flags   = connection.bidirectional ? BIDIRECTIONAL : 0,
                .side    = classify_off_mesh_point(connection.end, bounds),
                .user_id = connection.user_id,
            };
            stored++;
        }
    }

    if (!params.build_bv_tree) return;
    @pool() {
        BvNode[]? allocated = alloc::new_array_try(tmem, BvNode, source.poly_count);
        if (catch allocated) return c3d::CAPACITY_EXCEEDED~;
        BvNode[] items = allocated;
        foreach (index, &item : items) *item = poly_leaf(mesh, &tile, (uint)index);
        usz cursor;
        subdivide(
            items:  items,
            first:  0,
            last:   items.len,
            cursor: &cursor,
            nodes:  tile.bv_tree,
        );
    };
}

fn TileDataLayout tile_data_layout(TileHeader* header) @private {
    TileDataLayout layout;
    usz offset = aligned_size(TileHeader::size);
    layout.verts = offset;
    offset += aligned_size(Vec3::size * header.vert_count);
    layout.polys = offset;
    offset += aligned_size(Poly::size * header.poly_count);
    layout.detail_corners = offset;
    offset += aligned_size(Vec3::size * (usz)(header.detail_mode == DetailMode.BOUNDED ? header.vert_count - header.off_mesh_count * 2 : 0));
    layout.details = offset;
    offset += aligned_size(PolyDetail::size * (header.detail_mode == DetailMode.BOUNDED ? header.off_mesh_base : 0));
    layout.detail_vertices = offset;
    offset += aligned_size(Vec3::size * header.detail_vertex_count);
    layout.detail_triangles = offset;
    offset += aligned_size(DetailTriangle::size * header.detail_triangle_count);
    layout.detail_portals = offset;
    offset += aligned_size(DetailPortal::size * header.detail_portal_count);
    layout.bv_tree = offset;
    offset += aligned_size(BvNode::size * header.bv_node_count);
    layout.off_mesh = offset;
    offset += aligned_size(OffMeshConnection::size * header.off_mesh_count);
    layout.size = offset;
    return layout;
}

// Points the tile's arrays into the blob, whose header is written.
fn void carve_tile_data(MeshTile* tile, char[] data) @private {
    TileHeader* header = (TileHeader*)data.ptr;
    TileDataLayout layout = tile_data_layout(header);
    tile.header = header;
    tile.verts = ((Vec3*)(data.ptr + layout.verts))[:header.vert_count];
    tile.polys = ((Poly*)(data.ptr + layout.polys))[:header.poly_count];
    tile.detail_corners = ((Vec3*)(data.ptr + layout.detail_corners))[:header.detail_mode == DetailMode.BOUNDED ? header.vert_count - header.off_mesh_count * 2 : 0];
    tile.details = ((PolyDetail*)(data.ptr + layout.details))[:header.detail_mode == DetailMode.BOUNDED ? header.off_mesh_base : 0];
    tile.detail_vertices = ((Vec3*)(data.ptr + layout.detail_vertices))[:header.detail_vertex_count];
    tile.detail_triangles = ((DetailTriangle*)(data.ptr + layout.detail_triangles))[:header.detail_triangle_count];
    tile.detail_portals = ((DetailPortal*)(data.ptr + layout.detail_portals))[:header.detail_portal_count];
    tile.bv_tree = ((BvNode*)(data.ptr + layout.bv_tree))[:header.bv_node_count];
    tile.off_mesh = ((OffMeshConnection*)(data.ptr + layout.off_mesh))[:header.off_mesh_count];
    tile.data = data;
}

fn void? validate_tile_data(char[] data) @private {
    if (data.len < TileHeader::size || (uptr)data.ptr % TILE_DATA_ALIGNMENT != 0) return c3d::INVALID_ARGUMENT~;
    TileHeader* header = (TileHeader*)data.ptr;
    if (header.magic != TILE_MAGIC || header.version != TILE_VERSION
        || !header.poly_count || header.poly_count >= (1u << POLY_BITS)
        || !header.vert_count || header.vert_count >= MESH_NULL_INDEX
        || !header.off_mesh_base || header.off_mesh_base > header.poly_count
        || header.off_mesh_count != header.poly_count - header.off_mesh_base
        || header.off_mesh_count > header.vert_count / 2
        || (uint)header.detail_mode > (uint)DetailMode.BOUNDED
        || !finite_point(header.bounds.min) || !finite_point(header.bounds.max)
        || header.bounds.min.x > header.bounds.max.x || header.bounds.min.y > header.bounds.max.y
        || header.bounds.min.z > header.bounds.max.z
        || !math::is_finite(header.walkable_height) || header.walkable_height < 0
        || !math::is_finite(header.walkable_radius) || header.walkable_radius < 0
        || !math::is_finite(header.walkable_climb) || header.walkable_climb < 0
        || !math::is_finite(header.bv_quant_factor) || header.bv_quant_factor <= 0
        || !math::is_finite(header.cell_size) || header.cell_size <= 0) return c3d::INVALID_ARGUMENT~;
    if (header.bv_node_count && header.bv_node_count != header.off_mesh_base * 2 - 1) return c3d::INVALID_ARGUMENT~;
    if (header.detail_mode == DetailMode.COARSE
        && (header.detail_vertex_count || header.detail_triangle_count || header.detail_portal_count)) {
        return c3d::INVALID_ARGUMENT~;
    }
    if (header.detail_mode == DetailMode.BOUNDED && !finite_point(header.detail_origin)) return c3d::INVALID_ARGUMENT~;
    if (header.detail_mode == DetailMode.BOUNDED) {
        foreach (value : header.detail_origin_correction) {
            if (!math::is_finite(value)) return c3d::INVALID_ARGUMENT~;
        }
    }
    if (tile_data_layout(header).size > data.len) return c3d::INVALID_ARGUMENT~;

    MeshTile tile;
    carve_tile_data(&tile, data);
    foreach (vertex : tile.verts) {
        if (!finite_point(vertex)) return c3d::INVALID_ARGUMENT~;
    }
    foreach (vertex : tile.detail_vertices) {
        if (!finite_point(vertex) || !finite_point(vertex + header.detail_origin)) return c3d::INVALID_ARGUMENT~;
    }
    foreach (index, vertex : tile.detail_corners) {
        if (!finite_point(vertex) || !finite_point(vertex + header.detail_origin)) return c3d::INVALID_ARGUMENT~;
        Vec3 world = vertex + header.detail_origin;
        double allowance = detail_world_allowance(header.bounds);
        if (math::abs((double)world.x - tile.verts[index].x) > allowance
            || math::abs((double)world.z - tile.verts[index].z) > allowance
            || math::abs((double)world.y - tile.verts[index].y) > detail_numerical_allowance(header.bounds.max.y - header.bounds.min.y)) return c3d::INVALID_ARGUMENT~;
    }
    foreach (index, &poly : tile.polys) {
        bool ground = index < header.off_mesh_base;
        if ((ground && (poly.area_type.type != GROUND || poly.vert_count < 3 || poly.vert_count > MAX_VERTS_PER_POLY))
            || (!ground && (poly.area_type.type != OFF_MESH_CONNECTION || poly.vert_count != 2))) {
            return c3d::INVALID_ARGUMENT~;
        }
        for (usz edge = 0; edge < poly.vert_count; edge++) {
            if (poly.verts[edge] >= tile.verts.len) return c3d::INVALID_ARGUMENT~;
            if (ground && header.detail_mode == DetailMode.BOUNDED) {
                if (poly.verts[edge] >= tile.detail_corners.len) return c3d::INVALID_ARGUMENT~;
                for (usz previous = 0; previous < edge; previous++) {
                    if (poly.verts[previous] == poly.verts[edge]) return c3d::INVALID_ARGUMENT~;
                }
                Vec3 first = tile.verts[poly.verts[edge]];
                uint next = poly.verts[(edge + 1) % poly.vert_count];
                if (next >= tile.verts.len) return c3d::INVALID_ARGUMENT~;
                Vec3 last = tile.verts[next];
                if (first.x == last.x && first.z == last.z) return c3d::INVALID_ARGUMENT~;
            }
            ushort neighbour = poly.neighbours[edge];
            if (!ground || !neighbour) continue;
            if ((neighbour & EXTERNAL_LINK) == 0) {
                if (neighbour > header.off_mesh_base) return c3d::INVALID_ARGUMENT~;
            } else {
                ushort side = neighbour & (ushort)~EXTERNAL_LINK;
                if (side != 0 && side != 2 && side != 4 && side != 6) return c3d::INVALID_ARGUMENT~;
            }
        }
    }
    foreach (index, node : tile.bv_tree) {
        for (usz axis = 0; axis < 3; axis++) {
            if (node.min[axis] > node.max[axis]) return c3d::INVALID_ARGUMENT~;
        }
        if (node.index >= 0) {
            if ((uint)node.index >= header.off_mesh_base) return c3d::INVALID_ARGUMENT~;
        } else if (-(long)node.index > (long)(tile.bv_tree.len - index)) {
            return c3d::INVALID_ARGUMENT~;
        }
    }
    foreach (index, connection : tile.off_mesh) {
        if (connection.poly != header.off_mesh_base + index || !finite_point(connection.start)
            || !finite_point(connection.end) || !math::is_finite(connection.radius) || connection.radius < 0
            || (connection.flags & ~BIDIRECTIONAL) != 0
            || (connection.side > 7 && connection.side != INSIDE_TILE)) return c3d::INVALID_ARGUMENT~;
    }
    foreach (portal : tile.detail_portals) {
        if (portal.polygon >= header.off_mesh_base || portal.edge >= tile.polys[portal.polygon].vert_count
            || (tile.polys[portal.polygon].neighbours[portal.edge] & EXTERNAL_LINK) == 0
            || !math::is_finite(portal.min) || !math::is_finite(portal.max)
            || portal.min < 0 || portal.max > 1 || portal.min >= portal.max
            || !math::is_finite(portal.source_height) || !math::is_finite(portal.target_height)) {
            return c3d::INVALID_ARGUMENT~;
        }
        double source_height = (double)header.detail_origin.y + portal.source_height;
        double target_height = (double)header.detail_origin.y + portal.target_height;
        if (source_height - header.detail_origin.y != (double)portal.source_height
            || target_height - header.detail_origin.y != (double)portal.target_height) return c3d::INVALID_ARGUMENT~;
    }
    if (header.detail_mode == DetailMode.BOUNDED) {
        @pool() {
            foreach (index, detail : tile.details) {
                if (detail.vertex_base > tile.detail_vertices.len
                    || detail.vertex_count > tile.detail_vertices.len - detail.vertex_base
                    || detail.triangle_base > tile.detail_triangles.len
                    || detail.triangle_count > tile.detail_triangles.len - detail.triangle_base) {
                    return c3d::INVALID_ARGUMENT~;
                }
                Vec3[MAX_VERTS_PER_POLY] corners = polygon_vertices(&tile, &tile.polys[index]);
                for (usz vertex = 0; vertex < tile.polys[index].vert_count; vertex++) corners[vertex] = tile.detail_corners[tile.polys[index].verts[vertex]];
                validate_detail_polygon(
                    corners: corners[:tile.polys[index].vert_count],
                    range: detail,
                    local_vertices: tile.detail_vertices,
                    triangles: tile.detail_triangles,
                    scratch: tmem,
                )!;
            }
        };
    }
}

fn usz aligned_size(usz bytes) @local => (bytes + TILE_DATA_ALIGNMENT - 1) / TILE_DATA_ALIGNMENT * TILE_DATA_ALIGNMENT;

fn TileHeader tile_header(TileMeshView mesh, uint stored, TileDataParams params) @local {
    TileMeshHeader* source = mesh.header;
    Aabb bounds = source.bounds;
    if (source.detail_mode == DetailMode.BOUNDED) {
        Vec3 scale = { source.cell_size, source.cell_height, source.cell_size };
        for (uint index = 0; index < source.vert_count; index++) {
            ushort* voxel = &mesh.verts[index * 3];
            Vec3 vertex = source.bounds.min + (Vec3){ (float)voxel[0], (float)voxel[1], (float)voxel[2] } * scale;
            bounds.min = math::min(bounds.min, vertex);
            bounds.max = math::max(bounds.max, vertex);
        }
        foreach (vertex : mesh.detail_vertices) {
            Vec3 world = source.detail_origin + vertex;
            bounds.min = math::min(bounds.min, world);
            bounds.max = math::max(bounds.max, world);
        }
    }
    float quant_factor = 1.0f / source.cell_size;
    if (source.detail_mode == DetailMode.BOUNDED) {
        Vec3 extent = bounds.max - bounds.min;
        float longest = math::max(math::max(extent.x, extent.y), extent.z);
        if (longest > 0) quant_factor = math::min(quant_factor, MAX_BV_COORDINATE / longest);
    }
    return {
        .magic           = TILE_MAGIC,
        .version         = TILE_VERSION,
        .x               = params.tile_x,
        .z               = params.tile_z,
        .layer           = params.tile_layer,
        .user_id         = params.user_id,
        .poly_count      = source.poly_count + stored,
        .vert_count      = source.vert_count + stored * 2,
        .bv_node_count   = params.build_bv_tree ? source.poly_count * 2 - 1 : 0, // a full binary tree over the polygons
        .off_mesh_count  = stored,
        .off_mesh_base   = source.poly_count,
        .walkable_height = params.walkable_height,
        .walkable_radius = params.walkable_radius,
        .walkable_climb  = params.walkable_climb,
        .bounds          = bounds,
        .bv_quant_factor = quant_factor,
        .detail_mode = source.detail_mode,
        .detail_vertex_count = source.detail_vertex_count,
        .detail_triangle_count = source.detail_triangle_count,
        .detail_portal_count = source.detail_portal_count,
        .cell_size = source.cell_size,
        .detail_origin = source.detail_origin,
        .detail_origin_correction = source.detail_origin_correction,
    };
}

fn uint count_stored_connections(TileMeshView mesh, OffMeshConnectionDesc[] connections, float walkable_climb) @local {
    if (!connections.len) return 0;
    Aabb bounds = connection_bounds(mesh, walkable_climb);
    uint stored;
    foreach (connection : connections) {
        if (classify_start(connection.start, bounds) == INSIDE_TILE) stored++;
    }
    return stored;
}

// The tile's XZ bounds with the height range of its vertices widened by the climb.
fn Aabb connection_bounds(TileMeshView mesh, float walkable_climb) @local {
    TileMeshHeader* source = mesh.header;
    float lowest = float::max;
    float highest = -float::max;
    for (uint vertex = 0; vertex < source.vert_count; vertex++) {
        float height = source.bounds.min.y + (float)mesh.verts[vertex * 3 + 1] * source.cell_height;
        lowest = math::min(lowest, height);
        highest = math::max(highest, height);
    }
    foreach (vertex : mesh.detail_vertices) {
        float height = source.detail_origin.y + vertex.y;
        lowest = math::min(lowest, height);
        highest = math::max(highest, height);
    }
    Aabb bounds = source.bounds;
    bounds.min.y = lowest - walkable_climb;
    bounds.max.y = highest + walkable_climb;
    return bounds;
}

fn char classify_start(Vec3 start, Aabb bounds) @local {
    char side = classify_off_mesh_point(start, bounds);
    if (side == INSIDE_TILE && (start.y < bounds.min.y || start.y > bounds.max.y)) return 0;
    return side;
}

// Tile side of a point outside the XZ bounds, INSIDE_TILE inside them; mirrors classifyOffMeshPoint.
fn char classify_off_mesh_point(Vec3 point, Aabb bounds) @local {
    char outcode;
    if (point.x >= bounds.max.x) outcode |= OUTSIDE_POSITIVE_X;
    if (point.z >= bounds.max.z) outcode |= OUTSIDE_POSITIVE_Z;
    if (point.x < bounds.min.x) outcode |= OUTSIDE_NEGATIVE_X;
    if (point.z < bounds.min.z) outcode |= OUTSIDE_NEGATIVE_Z;
    switch (outcode) {
        case OUTSIDE_POSITIVE_X: return 0;
        case OUTSIDE_POSITIVE_X | OUTSIDE_POSITIVE_Z: return 1;
        case OUTSIDE_POSITIVE_Z: return 2;
        case OUTSIDE_NEGATIVE_X | OUTSIDE_POSITIVE_Z: return 3;
        case OUTSIDE_NEGATIVE_X: return 4;
        case OUTSIDE_NEGATIVE_X | OUTSIDE_NEGATIVE_Z: return 5;
        case OUTSIDE_NEGATIVE_Z: return 6;
        case OUTSIDE_POSITIVE_X | OUTSIDE_NEGATIVE_Z: return 7;
        default: return INSIDE_TILE;
    }
}

fn ushort detour_neighbour(ushort neighbour) @local {
    if ((neighbour & PORTAL_EDGE) == 0) return (ushort)(neighbour + 1);
    ushort side = neighbour & PORTAL_SIDE_MASK;
    if (side >= DETOUR_PORTAL_SIDE.len) return 0;
    return EXTERNAL_LINK | DETOUR_PORTAL_SIDE[side];
}

fn BvNode poly_leaf(TileMeshView mesh, MeshTile* tile, uint index) @local {
    if (mesh.header.detail_mode == DetailMode.COARSE) {
        TileMeshHeader* source = mesh.header;
        uint stride = source.verts_per_poly;
        ushort[] indices = mesh.polys[(usz)index * stride * 2:stride];
        BvNode leaf = { .index = (int)index };
        for (uint slot = 0; slot < stride; slot++) {
            if (indices[slot] == MESH_NULL_INDEX) break;
            ushort* voxel = &mesh.verts[indices[slot] * 3];
            for (usz axis = 0; axis < 3; axis++) {
                leaf.min[axis] = slot == 0 ? voxel[axis] : math::min(leaf.min[axis], voxel[axis]);
                leaf.max[axis] = slot == 0 ? voxel[axis] : math::max(leaf.max[axis], voxel[axis]);
            }
        }
        leaf.min[1] = (ushort)math::floor((float)leaf.min[1] * source.cell_height / source.cell_size);
        leaf.max[1] = (ushort)math::ceil((float)leaf.max[1] * source.cell_height / source.cell_size);
        return leaf;
    }
    Aabb bounds = polygon_bounds(tile, &tile.polys[index]);
    Vec3 low = (bounds.min - tile.header.bounds.min) * tile.header.bv_quant_factor;
    Vec3 high = (bounds.max - tile.header.bounds.min) * tile.header.bv_quant_factor;
    BvNode leaf = { .index = (int)index };
    for (usz axis = 0; axis < 3; axis++) {
        leaf.min[axis] = (ushort)math::clamp(math::floor(low[axis]), 0.0f, MAX_BV_COORDINATE);
        leaf.max[axis] = (ushort)math::clamp(math::ceil(high[axis]), 0.0f, MAX_BV_COORDINATE);
    }
    return leaf;
}

fn void? validate_tile_parameters(OffMeshConnectionDesc[] connections, TileDataParams params) @private {
    if (!math::is_finite(params.walkable_height) || params.walkable_height < 0
        || !math::is_finite(params.walkable_radius) || params.walkable_radius < 0
        || !math::is_finite(params.walkable_climb) || params.walkable_climb < 0
        || connections.len >= MESH_NULL_INDEX) return c3d::INVALID_ARGUMENT~;
    foreach (connection : connections) {
        if (!finite_point(connection.start) || !finite_point(connection.end)
            || !math::is_finite(connection.radius) || connection.radius < 0
            || connection.area > WALKABLE_AREA) return c3d::INVALID_ARGUMENT~;
    }
}

// Mirrors createBVTree's subdivide; the node's index becomes minus the nodes its subtree spans.
fn void subdivide(
    BvNode[] items,
    usz first,
    usz last,
    usz* cursor,
    BvNode[] nodes,
) @local {
    usz start = *cursor;
    BvNode* node = &nodes[(*cursor)++];
    if (last - first == 1) {
        *node = items[first];
        return;
    }

    node.min = items[first].min;
    node.max = items[first].max;
    foreach (&item : items[first + 1..last - 1]) {
        for (usz axis = 0; axis < 3; axis++) {
            node.min[axis] = math::min(node.min[axis], item.min[axis]);
            node.max[axis] = math::max(node.max[axis], item.max[axis]);
        }
    }
    usz axis = longest_axis(
        (int)node.max[0] - (int)node.min[0],
        (int)node.max[1] - (int)node.min[1],
        (int)node.max[2] - (int)node.min[2],
    );
    sort_by_axis(items[first..last - 1], axis);

    usz split = first + (last - first) / 2;
    subdivide(
        items:  items,
        first:  first,
        last:   split,
        cursor: cursor,
        nodes:  nodes,
    );
    subdivide(
        items:  items,
        first:  split,
        last:   last,
        cursor: cursor,
        nodes:  nodes,
    );
    node.index = -(int)(*cursor - start);
}

fn usz longest_axis(int x, int y, int z) @local {
    usz axis = 0;
    int longest = x;
    if (y > longest) {
        axis = 1;
        longest = y;
    }
    if (z > longest) axis = 2;
    return axis;
}

// Stable, so equal keys keep their order on every platform; upstream's qsort leaves that to the C library.
fn void sort_by_axis(BvNode[] items, usz axis) @local {
    for (usz index = 1; index < items.len; index++) {
        BvNode item = items[index];
        usz slot = index;
        while (slot > 0 && items[slot - 1].min[axis] > item.min[axis]) {
            items[slot] = items[slot - 1];
            slot--;
        }
        items[slot] = item;
    }
}
