module c3d::nav;

import std::math;
import c3d;

<* Handle to a polygon: salt, tile index, polygon index; zero is never valid. *>
typedef PolyRef = ulong;

<* Handle to a tile: salt and tile index; zero is never valid. *>
typedef TileRef = ulong;

<* Bits of PolyRef given to the salt. *>
const uint SALT_BITS = 16;

<* Bits of PolyRef given to the tile index. *>
const uint TILE_BITS = 28;

<* Bits of PolyRef given to the polygon index. *>
const uint POLY_BITS = 20;

<* Neighbour word flag marking a portal edge to another tile; mirrors DT_EXT_LINK. *>
const ushort EXTERNAL_LINK = 0x8000;

<* Link index meaning no link; mirrors DT_NULL_LINK. *>
const uint NULL_LINK = uint::max;

<* Magic of a TileData blob; mirrors DT_NAVMESH_MAGIC. *>
const int TILE_MAGIC = 'D' << 24 | 'N' << 16 | 'A' << 8 | 'V';

<* Version of a TileData blob; 7 upstream, 100 here because refs are 64-bit and detail arrays are absent. *>
const int TILE_VERSION = 100;

<* Off-mesh connection flag for two-way travel; mirrors DT_OFFMESH_CON_BIDIR. *>
const char BIDIRECTIONAL = 1;

const char NO_SIDE @private = 0xff; // link side of a link inside one tile; mirrors upstream's 0xff
const char LANDING_EDGE @private = 0xff; // link edge of a landing polygon's link back to its off-mesh connection
const int  ANY_SIDE @private = -1; // connects every portal side, for tiles stacked at one coordinate
const uint MAX_TILES_AT @private = 32; // mirrors MAX_NEIS: layers read at one tile coordinate
const uint MAX_CONNECTING_POLYS @local = 4; // mirrors connectExtLinks' candidate array
const uint MAX_NEAREST_CANDIDATES @local = 128; // mirrors findNearestPolyInTile's candidate array
const uint TILE_HASH_X @local = 0x8da6b343; // upstream's arbitrarily chosen large primes
const uint TILE_HASH_Z @local = 0xd8163841;
const float SLAB_TOLERANCE @local = 0.01f; // metres; mirrors findConnectingPolys' shrink and distance
const float PORTAL_LIMIT_SCALE @local = 255.0f; // a link's portal sub-range is stored in a byte
const int[<2>][8] SIDE_OFFSETS @local = { // tile step of each side; mirrors getNeighbourTilesAt
    { 1, 0 },
    { 1, 1 },
    { 0, 1 },
    { -1, 1 },
    { -1, 0 },
    { -1, -1 },
    { 0, -1 },
    { 1, -1 },
};

<* What a polygon is; mirrors dtPolyTypes. *>
enum PolyType : char {
    GROUND,
    OFF_MESH_CONNECTION,
}

<* Polygon area id and type; mirrors dtPoly::areaAndtype. *>
bitstruct PolyAreaType : char {
    char     area : 0..5;
    PolyType type : 6..7;
}

<* Ownership flags of a tile; mirrors dtTileFlags. *>
bitstruct TileFlags : uint {
    bool free_data : 0;    // the mesh frees the blob on remove_tile and destroy
}

<* Convex polygon of a tile; mirrors dtPoly. *>
struct Poly {
    uint                       first_link;    // NULL_LINK when none
    ushort[MAX_VERTS_PER_POLY] verts;         // into MeshTile.verts
    ushort[MAX_VERTS_PER_POLY] neighbours;    // 0 none, index + 1 in-tile, EXTERNAL_LINK | side for portals
    ushort                     flags;
    char                       vert_count;
    PolyAreaType               area_type;
}

$assert Poly::size == 32;

<* Traversal link between polygons; mirrors dtLink with a 64-bit ref. *>
struct Link {
    PolyRef ref;
    uint    next;
    char    edge;
    char    side;    // NO_SIDE inside the tile
    char    min;     // portal sub-range on the edge, 0..255
    char    max;
}

$assert Link::size == 16;

<* Bounding volume node in quantized tile space; mirrors dtBVNode. *>
struct BvNode {
    ushort[3] min;
    ushort[3] max;
    int       index;    // polygon index of a leaf, or minus the nodes to skip
}

$assert BvNode::size == 16;

<* User-defined point-to-point traversal; mirrors dtOffMeshConnection. *>
struct OffMeshConnection {
    Vec3   start;
    Vec3   end;
    float  radius;
    ushort poly;
    char   flags;      // BIDIRECTIONAL
    char   side;       // tile side holding the end; 0xff inside the tile
    uint   user_id;
}

$assert OffMeshConnection::size == 36;

<* Header of a TileData blob; arrays follow it in declaration order, each 8-byte aligned. *>
struct TileHeader {
    int   magic;
    int   version;
    int   x;
    int   z;
    int   layer;
    uint  user_id;
    uint  poly_count;
    uint  vert_count;
    uint  max_link_count;
    uint  bv_node_count;       // 0 when the tree was not built
    uint  off_mesh_count;
    uint  off_mesh_base;       // first off-mesh polygon
    float walkable_height;
    float walkable_radius;
    float walkable_climb;
    Aabb  bounds;
    float bv_quant_factor;
}

$assert TileHeader::size == 88;

<* One resident tile; the arrays borrow into data. *>
struct MeshTile {
    uint                salt;
    uint                links_free;
    TileHeader*         header;        // null while the slot is free
    Poly[]              polys;
    Vec3[]              verts;
    Link[]              links;
    BvNode[]            bv_tree;
    OffMeshConnection[] off_mesh;
    char[]              data;
    TileFlags           flags;
    MeshTile*           next;
}

<* Tile grid and capacity of a mesh; mirrors dtNavMeshParams without max_polys. *>
struct NavMeshDesc {
    Vec3  origin;
    float tile_width;     // metres along X
    float tile_height;    // metres along Z
    uint  max_tiles;
}

<* Tiles of convex polygons with links across tile borders; mirrors dtNavMesh. *>
struct NavMesh {
    Allocator   allocator;
    NavMeshDesc desc;
    uint        lookup_size;    // next power of two of max_tiles / 4
    uint        lookup_mask;
    MeshTile*[] lookup;         // by tile position hash
    MeshTile*   next_free;
    MeshTile[]  tiles;          // max_tiles
}

<* A tile and one of its polygons, resolved from a ref. *>
struct TileAndPoly {
    MeshTile* tile;
    Poly*     poly;
}

<* Closest point on a polygon. *>
struct ClosestPoint {
    Vec3 point;
    bool over_poly;    // the position's XZ lies inside the polygon
}

<* Nearest polygon to a point. *>
struct NearestPoly {
    PolyRef ref;
    Vec3    point;
    bool    over_poly;    // the point's XZ lies inside the polygon
}

struct Slab @local {
    float[<2>] min;    // position along the edge, height
    float[<2>] max;
}

struct ConnectingPolys @local {
    PolyRef[MAX_CONNECTING_POLYS]    refs;
    float[<2>][MAX_CONNECTING_POLYS] ranges;    // overlap along the edge
    usz                              count;
}

<*
 Add a tile blob, link it to its neighbours and its own off-mesh connections; mirrors dtNavMesh::addTile.
 @param data : "A TileData blob, 8-byte aligned; borrowed unless flags.free_data."
 @param last_ref : "Ref to restore when reloading; 0 takes any free slot."
 @return? c3d::INVALID_ARGUMENT, TILE_OCCUPIED, c3d::CAPACITY_EXCEEDED
*>
fn TileRef? NavMesh.add_tile(
    &self,
    char[] data,
    TileFlags flags,
    TileRef last_ref = (TileRef)0,
) {
    if (data.len < TileHeader::size) return c3d::INVALID_ARGUMENT~;
    TileHeader* header = (TileHeader*)data.ptr;
    if (header.magic != TILE_MAGIC || header.version != TILE_VERSION) return c3d::INVALID_ARGUMENT~;
    if (data.len < tile_data_layout(header).size) return c3d::INVALID_ARGUMENT~;
    if (self.tile_at(header.x, header.z, header.layer)) return TILE_OCCUPIED~;

    MeshTile* tile = take_free_tile(self, last_ref)!;
    uint hash = tile_hash(header.x, header.z, self.lookup_mask);
    tile.next = self.lookup[hash];
    self.lookup[hash] = tile;

    carve_tile_data(tile, data);
    tile.flags = flags;
    tile.links_free = tile.links.len ? 0 : NULL_LINK;
    foreach (index, &link : tile.links) link.next = index + 1 < tile.links.len ? (uint)index + 1 : NULL_LINK;

    connect_internal_links(self, tile);
    base_off_mesh_links(self, tile);
    connect_external_off_mesh_links(self, tile, tile, ANY_SIDE);

    MeshTile*[MAX_TILES_AT] neighbours;
    usz layers = self.tiles_at(header.x, header.z, neighbours[..]);
    foreach (neighbour : neighbours[:layers]) {
        if (neighbour == tile) continue;
        connect_external_links(self, tile, neighbour, ANY_SIDE);
        connect_external_links(self, neighbour, tile, ANY_SIDE);
        connect_external_off_mesh_links(self, tile, neighbour, ANY_SIDE);
        connect_external_off_mesh_links(self, neighbour, tile, ANY_SIDE);
    }
    for (int side = 0; side < 8; side++) {
        usz count = neighbour_tiles_at(self, header.x, header.z, side, neighbours[..]);
        foreach (neighbour : neighbours[:count]) {
            connect_external_links(self, tile, neighbour, side);
            connect_external_links(self, neighbour, tile, opposite_tile(side));
            connect_external_off_mesh_links(self, tile, neighbour, side);
            connect_external_off_mesh_links(self, neighbour, tile, opposite_tile(side));
        }
    }
    return self.tile_ref(tile);
}

<*
 Unlink and remove the tile; advances its salt so every ref into it fails.
 @return "The blob, for a caller that owns it; empty when the mesh freed it."
 @return? INVALID_REF
*>
fn char[]? NavMesh.remove_tile(&self, TileRef ref) {
    MeshTile* tile = self.tile_by_ref(ref)!;
    TileHeader* header = tile.header;
    uint hash = tile_hash(header.x, header.z, self.lookup_mask);
    MeshTile* previous;
    for (MeshTile* current = self.lookup[hash]; current; current = current.next) {
        if (current != tile) {
            previous = current;
            continue;
        }
        if (previous) {
            previous.next = current.next;
        } else {
            self.lookup[hash] = current.next;
        }
        break;
    }

    MeshTile*[MAX_TILES_AT] neighbours;
    usz layers = self.tiles_at(header.x, header.z, neighbours[..]);
    foreach (neighbour : neighbours[:layers]) {
        if (neighbour != tile) unconnect_links(self, neighbour, tile);
    }
    for (int side = 0; side < 8; side++) {
        usz count = neighbour_tiles_at(self, header.x, header.z, side, neighbours[..]);
        foreach (neighbour : neighbours[:count]) unconnect_links(self, neighbour, tile);
    }

    char[] data = tile.data;
    if (tile.flags.free_data) {
        alloc::free(self.allocator, data.ptr);
        data = {};
    }
    uint salt = (tile.salt + 1) & ((1u << SALT_BITS) - 1);
    *tile = {
        .salt = salt == 0 ? 1 : salt,
        .next = self.next_free,
    };
    self.next_free = tile;
    return data;
}

<* Tile grid coordinate of a world position; mirrors calcTileLoc. *>
fn int[<2>] NavMesh.tile_location(&self, Vec3 position) {
    return {
        (int)math::floor((position.x - self.desc.origin.x) / self.desc.tile_width),
        (int)math::floor((position.z - self.desc.origin.z) / self.desc.tile_height),
    };
}

<* Tile at the grid coordinate and layer, or null; mirrors getTileAt. *>
fn MeshTile* NavMesh.tile_at(
    &self,
    int x,
    int z,
    int layer,
) {
    for (MeshTile* tile = self.lookup[tile_hash(x, z, self.lookup_mask)]; tile; tile = tile.next) {
        if (tile.header && tile.header.x == x && tile.header.z == z && tile.header.layer == layer) return tile;
    }
    return null;
}

<*
 Every tile at the grid coordinate, all layers.
 @param [out] out_tiles : "Filled up to its length."
 @return "How many were written."
*>
fn usz NavMesh.tiles_at(
    &self,
    int x,
    int z,
    MeshTile*[] out_tiles,
) {
    usz count;
    for (MeshTile* tile = self.lookup[tile_hash(x, z, self.lookup_mask)]; tile; tile = tile.next) {
        if (!tile.header || tile.header.x != x || tile.header.z != z) continue;
        if (count < out_tiles.len) out_tiles[count++] = tile;
    }
    return count;
}

<* Ref of the tile at the grid coordinate and layer, or 0. *>
fn TileRef NavMesh.tile_ref_at(
    &self,
    int x,
    int z,
    int layer,
) {
    MeshTile* tile = self.tile_at(x, z, layer);
    return tile ? self.tile_ref(tile) : (TileRef)0;
}

<*
 Ref of a tile slot.
 @param [&in] tile : "One of self.tiles."
*>
fn TileRef NavMesh.tile_ref(&self, MeshTile* tile) {
    return (TileRef)encode_poly_ref(tile.salt, tile_index(self, tile), 0);
}

<*
 Resident tile of a ref.
 @return? INVALID_REF
*>
fn MeshTile*? NavMesh.tile_by_ref(&self, TileRef ref) {
    if (!ref) return INVALID_REF~;
    uint index = decode_tile((PolyRef)ref);
    if (index >= self.tiles.len) return INVALID_REF~;
    MeshTile* tile = &self.tiles[index];
    if (tile.salt != decode_salt((PolyRef)ref) || !tile.header) return INVALID_REF~;
    return tile;
}

<*
 Tile and polygon of a ref.
 @return? INVALID_REF
*>
fn TileAndPoly? NavMesh.tile_and_poly(&self, PolyRef ref) {
    if (!self.is_valid_ref(ref)) return INVALID_REF~;
    return self.tile_and_poly_unchecked(ref);
}

<*
 Tile and polygon of a ref known to be valid; mirrors getTileAndPolyByRefUnsafe.
 @require self.is_valid_ref(ref)
*>
fn TileAndPoly NavMesh.tile_and_poly_unchecked(&self, PolyRef ref) {
    MeshTile* tile = &self.tiles[decode_tile(ref)];
    return { .tile = tile, .poly = &tile.polys[decode_poly(ref)] };
}

<* Whether the ref names a resident polygon at the current salt. *>
fn bool NavMesh.is_valid_ref(&self, PolyRef ref) {
    if (!ref) return false;
    uint index = decode_tile(ref);
    if (index >= self.tiles.len) return false;
    MeshTile* tile = &self.tiles[index];
    if (tile.salt != decode_salt(ref) || !tile.header) return false;
    return decode_poly(ref) < tile.header.poly_count;
}

<*
 Ref of polygon 0 of the tile; mirrors getPolyRefBase.
 @param [&in] tile : "One of self.tiles."
*>
fn PolyRef NavMesh.poly_ref_base(&self, MeshTile* tile) {
    return encode_poly_ref(tile.salt, tile_index(self, tile), 0);
}

<*
 Endpoints of an off-mesh connection in travel order given the polygon before it.
 @return? INVALID_REF
*>
fn Vec3[2]? NavMesh.off_mesh_end_points(&self, PolyRef previous_ref, PolyRef poly_ref) {
    TileAndPoly found = self.tile_and_poly(poly_ref)!;
    MeshTile* tile = found.tile;
    Poly* poly = found.poly;
    if (poly.area_type.type != OFF_MESH_CONNECTION) return INVALID_REF~;

    usz first = 0;
    for (uint link = poly.first_link; link != NULL_LINK; link = tile.links[link].next) {
        if (tile.links[link].edge != 0) continue;
        if (tile.links[link].ref != previous_ref) first = 1;
        break;
    }
    return { tile.verts[poly.verts[first]], tile.verts[poly.verts[1 - first]] };
}

<*
 Off-mesh connection of the ref.
 @return? INVALID_REF
*>
fn OffMeshConnection*? NavMesh.off_mesh_by_ref(&self, PolyRef ref) {
    TileAndPoly found = self.tile_and_poly(ref)!;
    if (found.poly.area_type.type != OFF_MESH_CONNECTION) return INVALID_REF~;
    return &found.tile.off_mesh[decode_poly(ref) - found.tile.header.off_mesh_base];
}

<*
 Set the user flags of a polygon; refs are unchanged.
 @return? INVALID_REF
*>
fn void? NavMesh.set_poly_flags(&self, PolyRef ref, ushort flags) {
    self.tile_and_poly(ref)!.poly.flags = flags;
}

<*
 User flags of a polygon.
 @return? INVALID_REF
*>
fn ushort? NavMesh.poly_flags(&self, PolyRef ref) {
    return self.tile_and_poly(ref)!.poly.flags;
}

<*
 Set the area of a polygon; refs are unchanged.
 @return? INVALID_REF
 @require area < MAX_AREAS
*>
fn void? NavMesh.set_poly_area(&self, PolyRef ref, char area) {
    self.tile_and_poly(ref)!.poly.area_type.area = area;
}

<*
 Area of a polygon.
 @return? INVALID_REF
*>
fn char? NavMesh.poly_area(&self, PolyRef ref) {
    return self.tile_and_poly(ref)!.poly.area_type.area;
}

<*
 Empty mesh with max_tiles free slots; mirrors dtNavMesh::init.
 @return? c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn NavMesh? create_nav_mesh(Allocator allocator, NavMeshDesc desc) {
    if (desc.max_tiles == 0 || desc.max_tiles > 1u << TILE_BITS) return c3d::INVALID_ARGUMENT~;
    if (desc.tile_width <= 0 || desc.tile_height <= 0) return c3d::INVALID_ARGUMENT~;
    uint lookup_size = math::max(next_pow2(desc.max_tiles / 4), 1u);
    NavMesh mesh = {
        .allocator   = allocator,
        .desc        = desc,
        .lookup_size = lookup_size,
        .lookup_mask = lookup_size - 1,
    };
    defer catch destroy_nav_mesh(&mesh);

    MeshTile[]? tiles = alloc::new_array_try(allocator, MeshTile, desc.max_tiles);
    if (catch tiles) return c3d::CAPACITY_EXCEEDED~;
    mesh.tiles = tiles;
    MeshTile*[]? lookup = alloc::new_array_try(allocator, MeshTile*, lookup_size);
    if (catch lookup) return c3d::CAPACITY_EXCEEDED~;
    mesh.lookup = lookup;

    // Pushed in reverse so the first free slot is tile 0.
    for (usz index = tiles.len; index > 0; index--) {
        MeshTile* tile = &tiles[index - 1];
        tile.salt = 1;
        tile.next = mesh.next_free;
        mesh.next_free = tile;
    }
    return mesh;
}

<*
 Free every tile that carries free_data, then the tables.
 @param [&inout] mesh : "Left zeroed."
*>
fn void destroy_nav_mesh(NavMesh* mesh) {
    foreach (&tile : mesh.tiles) {
        if (tile.header && tile.flags.free_data) alloc::free(mesh.allocator, tile.data.ptr);
    }
    alloc::free(mesh.allocator, mesh.tiles.ptr);
    alloc::free(mesh.allocator, mesh.lookup.ptr);
    *mesh = {};
}

<* Encode a ref; mirrors encodePolyId. *>
fn PolyRef encode_poly_ref(uint salt, uint tile, uint poly) {
    return (PolyRef)((ulong)salt << (POLY_BITS + TILE_BITS) | (ulong)tile << POLY_BITS | (ulong)poly);
}

<* Salt of a ref. *>
fn uint decode_salt(PolyRef ref) => (uint)(((ulong)ref >> (POLY_BITS + TILE_BITS)) & ((1ul << SALT_BITS) - 1));

<* Tile index of a ref. *>
fn uint decode_tile(PolyRef ref) => (uint)(((ulong)ref >> POLY_BITS) & ((1ul << TILE_BITS) - 1));

<* Polygon index of a ref. *>
fn uint decode_poly(PolyRef ref) => (uint)((ulong)ref & ((1ul << POLY_BITS) - 1));

fn uint tile_index(NavMesh* mesh, MeshTile* tile) @local => (uint)(tile - mesh.tiles.ptr);

fn uint tile_hash(int x, int z, uint mask) @local => (TILE_HASH_X * (uint)x + TILE_HASH_Z * (uint)z) & mask;

fn MeshTile*? take_free_tile(NavMesh* mesh, TileRef last_ref) @local {
    if (!last_ref) {
        MeshTile* tile = mesh.next_free;
        if (!tile) return c3d::CAPACITY_EXCEEDED~;
        mesh.next_free = tile.next;
        tile.next = null;
        return tile;
    }

    uint index = decode_tile((PolyRef)last_ref);
    if (index >= mesh.tiles.len) return c3d::CAPACITY_EXCEEDED~;
    MeshTile* target = &mesh.tiles[index];
    MeshTile* previous;
    MeshTile* tile = mesh.next_free;
    while (tile && tile != target) {
        previous = tile;
        tile = tile.next;
    }
    if (tile != target) return c3d::CAPACITY_EXCEEDED~;
    if (previous) {
        previous.next = tile.next;
    } else {
        mesh.next_free = tile.next;
    }
    tile.salt = decode_salt((PolyRef)last_ref);
    return tile;
}

fn usz neighbour_tiles_at(
    NavMesh* mesh,
    int x,
    int z,
    int side,
    MeshTile*[] out_tiles,
) @private {
    return mesh.tiles_at(x + SIDE_OFFSETS[side].x, z + SIDE_OFFSETS[side].y, out_tiles);
}

fn uint allocate_link(MeshTile* tile) @local {
    uint link = tile.links_free;
    if (link != NULL_LINK) tile.links_free = tile.links[link].next;
    return link;
}

fn void free_link(MeshTile* tile, uint link) @local {
    tile.links[link].next = tile.links_free;
    tile.links_free = link;
}

fn void push_link(MeshTile* tile, Poly* poly, Link link) @local {
    uint index = allocate_link(tile);
    if (index == NULL_LINK) return;
    link.next = poly.first_link;
    tile.links[index] = link;
    poly.first_link = index;
}

fn void connect_internal_links(NavMesh* mesh, MeshTile* tile) @local {
    PolyRef base = mesh.poly_ref_base(tile);
    foreach (&poly : tile.polys) {
        poly.first_link = NULL_LINK;
        if (poly.area_type.type == OFF_MESH_CONNECTION) continue;
        // Built backwards so the list runs from the lowest edge to the highest.
        for (int edge = poly.vert_count - 1; edge >= 0; edge--) {
            ushort neighbour = poly.neighbours[edge];
            if (neighbour == 0 || (neighbour & EXTERNAL_LINK) != 0) continue;
            push_link(tile, poly, { .ref = base | (PolyRef)(neighbour - 1), .edge = (char)edge, .side = NO_SIDE });
        }
    }
}

// The start of each connection moves onto the polygon it lands on.
fn void base_off_mesh_links(NavMesh* mesh, MeshTile* tile) @local {
    PolyRef base = mesh.poly_ref_base(tile);
    foreach (&connection : tile.off_mesh) {
        Poly* poly = &tile.polys[connection.poly];
        Vec3 half_extents = { connection.radius, tile.header.walkable_climb, connection.radius };
        NearestPoly? nearest = nearest_poly_in_tile(mesh, tile, connection.start, half_extents);
        if (catch nearest) continue;
        // The nearest polygon may lie beyond the radius along XZ.
        if (distance_sqr_2d(nearest.point, connection.start) > connection.radius * connection.radius) continue;
        tile.verts[poly.verts[0]] = nearest.point;

        push_link(tile, poly, { .ref = nearest.ref, .edge = 0, .side = NO_SIDE });
        Poly* landing = &tile.polys[decode_poly(nearest.ref)];
        push_link(tile, landing, { .ref = base | (PolyRef)connection.poly, .edge = LANDING_EDGE, .side = NO_SIDE });
    }
}

// Links the connections of target whose end lands in tile; the end moves onto the polygon it lands on.
fn void connect_external_off_mesh_links(
    NavMesh* mesh,
    MeshTile* tile,
    MeshTile* target,
    int side,
) @local {
    char opposite_side = side == ANY_SIDE ? NO_SIDE : (char)opposite_tile(side);
    foreach (&connection : target.off_mesh) {
        if (connection.side != opposite_side) continue;
        Poly* target_poly = &target.polys[connection.poly];
        if (target_poly.first_link == NULL_LINK) continue;

        Vec3 half_extents = { connection.radius, target.header.walkable_climb, connection.radius };
        NearestPoly? nearest = nearest_poly_in_tile(mesh, tile, connection.end, half_extents);
        if (catch nearest) continue;
        if (distance_sqr_2d(nearest.point, connection.end) > connection.radius * connection.radius) continue;
        target.verts[target_poly.verts[1]] = nearest.point;

        push_link(target, target_poly, { .ref = nearest.ref, .edge = 1, .side = opposite_side });
        if ((connection.flags & BIDIRECTIONAL) == 0) continue;
        Poly* landing = &tile.polys[decode_poly(nearest.ref)];
        push_link(tile, landing, {
            .ref  = mesh.poly_ref_base(target) | (PolyRef)connection.poly,
            .edge = LANDING_EDGE,
            .side = side == ANY_SIDE ? NO_SIDE : (char)side,
        });
    }
}

fn void connect_external_links(
    NavMesh* mesh,
    MeshTile* tile,
    MeshTile* target,
    int side,
) @local {
    foreach (&poly : tile.polys) {
        int count = poly.vert_count;
        for (int edge = 0; edge < count; edge++) {
            ushort neighbour = poly.neighbours[edge];
            if ((neighbour & EXTERNAL_LINK) == 0) continue;
            int direction = neighbour & 0xff;
            if (side != ANY_SIDE && direction != side) continue;

            Vec3 start = tile.verts[poly.verts[edge]];
            Vec3 end = tile.verts[poly.verts[(edge + 1) % count]];
            ConnectingPolys found = find_connecting_polys(
                mesh:   mesh,
                start:  start,
                end:    end,
                tile:   target,
                side:   opposite_tile(direction),
            );
            bool along_z = direction == 0 || direction == 4;
            float edge_start = along_z ? start.z : start.x;
            float edge_length = along_z ? end.z - start.z : end.x - start.x;
            for (usz candidate = 0; candidate < found.count; candidate++) {
                float t_min = (found.ranges[candidate][0] - edge_start) / edge_length;
                float t_max = (found.ranges[candidate][1] - edge_start) / edge_length;
                if (t_min > t_max) @swap(t_min, t_max);
                push_link(tile, poly, {
                    .ref  = found.refs[candidate],
                    .edge = (char)edge,
                    .side = (char)direction,
                    .min  = (char)math::round(math::clamp(t_min, 0.0f, 1.0f) * PORTAL_LIMIT_SCALE),
                    .max  = (char)math::round(math::clamp(t_max, 0.0f, 1.0f) * PORTAL_LIMIT_SCALE),
                });
            }
        }
    }
}

fn ConnectingPolys find_connecting_polys(
    NavMesh* mesh,
    Vec3 start,
    Vec3 end,
    MeshTile* tile,
    int side,
) @local {
    ConnectingPolys found;
    Slab edge_slab = slab_end_points(start, end, side);
    float edge_position = slab_coord(start, side);
    ushort portal = EXTERNAL_LINK | (ushort)side;
    PolyRef base = mesh.poly_ref_base(tile);
    foreach (index, &poly : tile.polys) {
        int count = poly.vert_count;
        for (int edge = 0; edge < count; edge++) {
            if (poly.neighbours[edge] != portal) continue;
            Vec3 other_start = tile.verts[poly.verts[edge]];
            Vec3 other_end = tile.verts[poly.verts[(edge + 1) % count]];
            if (math::abs(edge_position - slab_coord(other_start, side)) > SLAB_TOLERANCE) continue;
            Slab other_slab = slab_end_points(other_start, other_end, side);
            if (!overlap_slabs(edge_slab, other_slab, SLAB_TOLERANCE, tile.header.walkable_climb)) continue;

            if (found.count < MAX_CONNECTING_POLYS) {
                found.ranges[found.count] = {
                    math::max(edge_slab.min[0], other_slab.min[0]),
                    math::min(edge_slab.max[0], other_slab.max[0]),
                };
                found.refs[found.count] = base | (PolyRef)index;
                found.count++;
            }
            break;
        }
    }
    return found;
}

fn float slab_coord(Vec3 vertex, int side) @local {
    if (side == 0 || side == 4) return vertex.x;
    if (side == 2 || side == 6) return vertex.z;
    return 0;
}

fn Slab slab_end_points(Vec3 start, Vec3 end, int side) @local {
    bool along_z = side == 0 || side == 4;
    float[<2>] first = { along_z ? start.z : start.x, start.y };
    float[<2>] second = { along_z ? end.z : end.x, end.y };
    return first[0] < second[0] ? (Slab){ .min = first, .max = second } : (Slab){ .min = second, .max = first };
}

// The segments shrink by the tolerance so slabs that only touch at their ends do not connect.
fn bool overlap_slabs(
    Slab first,
    Slab second,
    float tolerance,
    float climb,
) @local {
    float min_x = math::max(first.min[0] + tolerance, second.min[0] + tolerance);
    float max_x = math::min(first.max[0] - tolerance, second.max[0] - tolerance);
    if (min_x > max_x) return false;

    float first_slope = (first.max[1] - first.min[1]) / (first.max[0] - first.min[0]);
    float first_offset = first.min[1] - first_slope * first.min[0];
    float second_slope = (second.max[1] - second.min[1]) / (second.max[0] - second.min[0]);
    float second_offset = second.min[1] - second_slope * second.min[0];
    float low_gap = (second_slope * min_x + second_offset) - (first_slope * min_x + first_offset);
    float high_gap = (second_slope * max_x + second_offset) - (first_slope * max_x + first_offset);
    if (low_gap * high_gap < 0) return true;
    float threshold = (climb * 2) * (climb * 2);
    return low_gap * low_gap <= threshold || high_gap * high_gap <= threshold;
}

fn void unconnect_links(NavMesh* mesh, MeshTile* tile, MeshTile* target) @local {
    uint target_index = tile_index(mesh, target);
    foreach (&poly : tile.polys) {
        uint previous = NULL_LINK;
        uint link = poly.first_link;
        while (link != NULL_LINK) {
            uint next = tile.links[link].next;
            if (decode_tile(tile.links[link].ref) != target_index) {
                previous = link;
                link = next;
                continue;
            }
            if (previous == NULL_LINK) {
                poly.first_link = next;
            } else {
                tile.links[previous].next = next;
            }
            free_link(tile, link);
            link = next;
        }
    }
}

// Polygons whose bounds overlap the box, through the BV tree when the tile has one; mirrors queryPolygonsInTile.
macro void @each_poly_overlapping(NavMesh* mesh, MeshTile* tile, Aabb box; @body(PolyRef ref, Poly* poly)) @private {
    PolyRef base = mesh.poly_ref_base(tile);
    if (!tile.bv_tree.len) {
        foreach (index, &poly : tile.polys) {
            if (poly.area_type.type == OFF_MESH_CONNECTION) continue;
            if (overlap_bounds(box, polygon_bounds(tile, poly))) @body(base | (PolyRef)index, poly);
        }
        return;
    }

    Aabb bounds = tile.header.bounds;
    float factor = tile.header.bv_quant_factor;
    Vec3 low = math::min(math::max(box.min, bounds.min), bounds.max) - bounds.min;
    Vec3 high = math::min(math::max(box.max, bounds.min), bounds.max) - bounds.min;
    // Rounded outward to even and odd cells, as the tree's leaves were.
    ushort[3] query_min = {
        (ushort)(factor * low.x) & 0xfffe,
        (ushort)(factor * low.y) & 0xfffe,
        (ushort)(factor * low.z) & 0xfffe,
    };
    ushort[3] query_max = {
        (ushort)(factor * high.x + 1) | 1,
        (ushort)(factor * high.y + 1) | 1,
        (ushort)(factor * high.z + 1) | 1,
    };
    usz node = 0;
    while (node < tile.bv_tree.len) {
        BvNode* current = &tile.bv_tree[node];
        bool overlap = overlap_quant_bounds(query_min, query_max, current.min, current.max);
        bool leaf = current.index >= 0;
        if (leaf && overlap) @body(base | (PolyRef)current.index, &tile.polys[current.index]);
        node += overlap || leaf ? 1 : (usz)-current.index;
    }
}

fn Aabb polygon_bounds(MeshTile* tile, Poly* poly) @private {
    Aabb bounds = { .min = tile.verts[poly.verts[0]], .max = tile.verts[poly.verts[0]] };
    for (usz slot = 1; slot < poly.vert_count; slot++) {
        Vec3 vertex = tile.verts[poly.verts[slot]];
        bounds.min = math::min(bounds.min, vertex);
        bounds.max = math::max(bounds.max, vertex);
    }
    return bounds;
}

fn usz polys_in_tile(
    NavMesh* mesh,
    MeshTile* tile,
    Aabb box,
    PolyRef[] out_refs,
) @local {
    usz count;
    @each_poly_overlapping(mesh, tile, box; ref, poly) {
        if (count < out_refs.len) out_refs[count++] = ref;
    };
    return count;
}

// NO_POLY when no polygon overlaps the box; mirrors findNearestPolyInTile.
fn NearestPoly? nearest_poly_in_tile(
    NavMesh* mesh,
    MeshTile* tile,
    Vec3 center,
    Vec3 half_extents,
) @local {
    PolyRef[MAX_NEAREST_CANDIDATES] candidates;
    Aabb box = { .min = center - half_extents, .max = center + half_extents };
    usz count = polys_in_tile(mesh, tile, box, candidates[..]);

    NearestPoly nearest;
    float nearest_distance = float::max;
    foreach (ref : candidates[:count]) {
        ClosestPoint closest = closest_point_on_polygon(mesh, ref, center);
        float distance = nearness(center, closest, tile.header.walkable_climb);
        if (distance >= nearest_distance) continue;
        nearest = { .ref = ref, .point = closest.point, .over_poly = closest.over_poly };
        nearest_distance = distance;
    }
    if (!nearest.ref) return NO_POLY~;
    return nearest;
}

// A point directly over a polygon and within climb of it beats the straight-line nearest point.
fn float nearness(Vec3 center, ClosestPoint closest, float walkable_climb) @private {
    Vec3 offset = center - closest.point;
    if (!closest.over_poly) return offset.dot(offset);
    float above = math::abs(offset.y) - walkable_climb;
    return above > 0 ? above * above : 0;
}

fn Vec3[MAX_VERTS_PER_POLY] polygon_vertices(MeshTile* tile, Poly* poly) @private {
    Vec3[MAX_VERTS_PER_POLY] verts;
    for (usz slot = 0; slot < poly.vert_count; slot++) verts[slot] = tile.verts[poly.verts[slot]];
    return verts;
}

// Height from the fan of the polygon from vertex 0, the triangles of upstream's dummy detail mesh.
// c3d::INVALID_ARGUMENT for an off-mesh connection or a position outside the polygon's XZ.
fn float? polygon_height(MeshTile* tile, Poly* poly, Vec3 position) @private {
    if (poly.area_type.type == OFF_MESH_CONNECTION) return c3d::INVALID_ARGUMENT~;
    Vec3[MAX_VERTS_PER_POLY] verts = polygon_vertices(tile, poly);
    Vec3[] corners = verts[:poly.vert_count];
    if (!point_in_polygon(position, corners)) return c3d::INVALID_ARGUMENT~;

    for (usz third = 2; third < corners.len; third++) {
        if (try height = closest_height_point_triangle(position, corners[0], corners[third - 1], corners[third])) {
            return height;
        }
    }
    // Every triangle test failed, so the position lies on an edge.
    return closest_point_on_fan_edges(corners, position, false).y;
}

// Walks the fan triangles and their edges in upstream's detail order, so ties resolve as upstream does.
// Edge 0 to 1 of a fan triangle is on the boundary only for the first triangle, edge 2 to 0 only for the last.
fn Vec3 closest_point_on_fan_edges(Vec3[] corners, Vec3 position, bool only_boundary) @private {
    float best_distance = float::max;
    float best_t;
    Vec3 best_start;
    Vec3 best_end;
    usz last = corners.len - 1;
    for (usz third = 2; third < corners.len; third++) {
        Vec3[3] triangle = { corners[0], corners[third - 1], corners[third] };
        for (usz step = 0; step < 3; step++) {
            usz start = (step + 2) % 3;
            usz end = (start + 1) % 3;
            bool boundary = start == 1 || (start == 0 && third == 2) || (start == 2 && third == last);
            if (!boundary && (only_boundary || start == 0)) continue;
            SegmentProjection projection = distance_pt_seg_sqr_2d(position, triangle[start], triangle[end]);
            if (projection.distance_sqr >= best_distance) continue;
            best_distance = projection.distance_sqr;
            best_t = projection.t;
            best_start = triangle[start];
            best_end = triangle[end];
        }
    }
    return lerp_point(best_start, best_end, best_t);
}

// Mirrors dtNavMesh::closestPointOnPoly.
fn ClosestPoint closest_point_on_polygon(NavMesh* mesh, PolyRef ref, Vec3 position) @private {
    TileAndPoly found = mesh.tile_and_poly_unchecked(ref);
    MeshTile* tile = found.tile;
    Poly* poly = found.poly;
    if (try height = polygon_height(tile, poly, position)) {
        return { .point = { position.x, height, position.z }, .over_poly = true };
    }
    if (poly.area_type.type == OFF_MESH_CONNECTION) {
        Vec3 start = tile.verts[poly.verts[0]];
        Vec3 end = tile.verts[poly.verts[1]];
        return { .point = lerp_point(start, end, distance_pt_seg_sqr_2d(position, start, end).t) };
    }
    Vec3[MAX_VERTS_PER_POLY] verts = polygon_vertices(tile, poly);
    return { .point = closest_point_on_fan_edges(verts[:poly.vert_count], position, true) };
}
