module c3d::nav;

import std::math;
import c3d;

<* Flag the build gives every polygon; the default query filter includes it. *>
const ushort POLY_FLAG_WALK = 1;

const usz       TILE_DATA_ALIGNMENT @local = 8; // dtAlign4 widened: Link holds a 64-bit ref
const char      INSIDE_TILE @local = 0xff; // classify_off_mesh_point of a point inside the tile's XZ
const ushort    PORTAL_SIDE_MASK @local = 0xf;
const ushort    NO_PORTAL_SIDE @local = 0xf; // a Recast neighbour word with PORTAL_EDGE and this side is a plain border
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
    usz polys;
    usz links;
    usz bv_tree;
    usz off_mesh;
    usz size;
}

struct TileDataCounts @local {
    uint stored;             // connections whose start lies in the tile
    uint off_mesh_links;     // connection endpoints inside the tile
    uint edges;
    uint portals;
}

<*
 Bytes the TileData blob of the mesh and connections needs.
 @param params : "Its walkable_climb bounds the connections kept; build_bv_tree sizes the tree."
*>
fn usz tile_data_size(TileMeshView mesh, OffMeshConnectionDesc[] connections, TileDataParams params) {
    TileHeader header = tile_header(mesh, count_tile_data(mesh, connections, params.walkable_climb), params);
    return tile_data_layout(&header).size;
}

<*
 Detour tile data from a TileMesh and the off-mesh connections it should carry; mirrors dtCreateNavMeshData.
 Connections whose start lies outside the mesh bounds are dropped; the header counts what was stored.
 @param [out] blob : "tile_data_size bytes, 8-byte aligned."
 @return? c3d::INVALID_ARGUMENT
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
    uint stride = source.verts_per_poly;
    if (stride > MAX_VERTS_PER_POLY) return c3d::INVALID_ARGUMENT~;
    TileDataCounts counts = count_tile_data(mesh, connections, params.walkable_climb);
    if ((usz)source.vert_count + (usz)counts.stored * 2 >= MESH_NULL_INDEX) return c3d::INVALID_ARGUMENT~;
    for (uint index = 0; index < source.poly_count; index++) {
        foreach (vertex : mesh.polys[(usz)index * stride * 2:stride]) {
            if (vertex == MESH_NULL_INDEX) break;
            if (vertex >= source.vert_count) return c3d::INVALID_ARGUMENT~;
        }
    }

    blob[..] = 0;
    *(TileHeader*)blob.ptr = tile_header(mesh, counts, params);
    MeshTile tile;
    carve_tile_data(&tile, blob);

    Vec3 scale = { source.cell_size, source.cell_height, source.cell_size };
    for (uint vertex = 0; vertex < source.vert_count; vertex++) {
        ushort* voxel = &mesh.verts[vertex * 3];
        tile.verts[vertex] = source.bounds.min + (Vec3){ (float)voxel[0], (float)voxel[1], (float)voxel[2] } * scale;
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
    // The link area stays unused until add_tile and holds at least three 16-byte links per polygon, so it fits
    // the one 16-byte leaf item per polygon the tree build sorts.
    BvNode[] items = ((BvNode*)tile.links.ptr)[:source.poly_count];
    foreach (index, &item : items) *item = poly_leaf(mesh, (uint)index);
    usz cursor;
    subdivide(
        items:  items,
        first:  0,
        last:   items.len,
        cursor: &cursor,
        nodes:  tile.bv_tree,
    );
    ((char*)items.ptr)[:items.len * BvNode::size] = 0;
}

fn TileDataLayout tile_data_layout(TileHeader* header) @private {
    TileDataLayout layout;
    usz offset = aligned_size(TileHeader::size);
    layout.verts = offset;
    offset += aligned_size(Vec3::size * header.vert_count);
    layout.polys = offset;
    offset += aligned_size(Poly::size * header.poly_count);
    layout.links = offset;
    offset += aligned_size(Link::size * header.max_link_count);
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
    tile.links = ((Link*)(data.ptr + layout.links))[:header.max_link_count];
    tile.bv_tree = ((BvNode*)(data.ptr + layout.bv_tree))[:header.bv_node_count];
    tile.off_mesh = ((OffMeshConnection*)(data.ptr + layout.off_mesh))[:header.off_mesh_count];
    tile.data = data;
}

fn usz aligned_size(usz bytes) @local => (bytes + TILE_DATA_ALIGNMENT - 1) / TILE_DATA_ALIGNMENT * TILE_DATA_ALIGNMENT;

fn TileHeader tile_header(TileMeshView mesh, TileDataCounts counts, TileDataParams params) @local {
    TileMeshHeader* source = mesh.header;
    return {
        .magic           = TILE_MAGIC,
        .version         = TILE_VERSION,
        .x               = params.tile_x,
        .z               = params.tile_z,
        .layer           = params.tile_layer,
        .user_id         = params.user_id,
        .poly_count      = source.poly_count + counts.stored,
        .vert_count      = source.vert_count + counts.stored * 2,
        .max_link_count  = counts.edges + counts.portals * 2 + counts.off_mesh_links * 2,
        .bv_node_count   = params.build_bv_tree ? source.poly_count * 2 - 1 : 0, // a full binary tree over the polygons
        .off_mesh_count  = counts.stored,
        .off_mesh_base   = source.poly_count,
        .walkable_height = params.walkable_height,
        .walkable_radius = params.walkable_radius,
        .walkable_climb  = params.walkable_climb,
        .bounds          = source.bounds,
        .bv_quant_factor = 1.0f / source.cell_size,
    };
}

fn TileDataCounts count_tile_data(TileMeshView mesh, OffMeshConnectionDesc[] connections, float walkable_climb) @local {
    TileDataCounts counts;
    uint stride = mesh.header.verts_per_poly;
    for (uint index = 0; index < mesh.header.poly_count; index++) {
        ushort[] indices = mesh.polys[(usz)index * stride * 2:stride];
        ushort[] neighbours = mesh.polys[(usz)index * stride * 2 + stride:stride];
        for (uint slot = 0; slot < stride; slot++) {
            if (indices[slot] == MESH_NULL_INDEX) break;
            counts.edges++;
            ushort neighbour = neighbours[slot];
            if ((neighbour & PORTAL_EDGE) != 0 && (neighbour & PORTAL_SIDE_MASK) != NO_PORTAL_SIDE) counts.portals++;
        }
    }

    if (!connections.len) return counts;
    Aabb bounds = connection_bounds(mesh, walkable_climb);
    foreach (connection : connections) {
        bool start_inside = classify_start(connection.start, bounds) == INSIDE_TILE;
        // An end inside the tile reserves link space even when its start lies elsewhere, as upstream counts it.
        if (start_inside) counts.off_mesh_links++;
        if (classify_off_mesh_point(connection.end, bounds) == INSIDE_TILE) counts.off_mesh_links++;
        if (start_inside) counts.stored++;
    }
    return counts;
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

// Quantized bounds of a polygon from its voxel vertices; heights rescale from cell height to cell size.
fn BvNode poly_leaf(TileMeshView mesh, uint index) @local {
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
