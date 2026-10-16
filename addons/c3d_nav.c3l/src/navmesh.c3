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

<* Version of the runtime tile and its retained surface arrays. *>
const int TILE_VERSION = 102;

<* Links a mesh reserves per tile slot when NavMeshDesc.max_links is 0. *>
const uint DEFAULT_LINKS_PER_TILE = 4096; // 96 KiB per slot; about 1000 quads at four links each

<* Off-mesh connection flag for two-way travel; mirrors DT_OFFMESH_CON_BIDIR. *>
const char BIDIRECTIONAL = 1;

const char NO_SIDE @private = 0xff; // link side of a link inside one tile; mirrors upstream's 0xff
const char LANDING_EDGE @private = 0xff; // link edge of a landing polygon's link back to its off-mesh connection
const int  ANY_SIDE @private = -1; // connects every portal side, for tiles stacked at one coordinate
const uint START_LANDED @local = 0; // any link index but NULL_LINK; marks an off-mesh polygon whose start landed
const uint MAX_TILES_AT @private = 32; // mirrors MAX_NEIS: layers read at one tile coordinate
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

<* Traversal link with normalized portal limits and a 64-bit ref. *>
struct Link {
    PolyRef ref;
    uint    next;
    char    edge;
    char    side;    // NO_SIDE inside the tile
    float   min;
    float   max;
}

$assert Link::size == 24;

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

<* Runtime tile counts and coordinate basis; arrays are 8-byte aligned. *>
struct TileHeader {
    int   magic;
    int   version;
    int   x;
    int   z;
    int   layer;
    uint  user_id;
    uint  poly_count;
    uint  vert_count;
    uint  bv_node_count;       // 0 when the tree was not built
    uint  off_mesh_count;
    uint  off_mesh_base;       // first off-mesh polygon
    float walkable_height;
    float walkable_radius;
    float walkable_climb;
    Aabb  bounds;
    float bv_quant_factor;
    DetailMode detail_mode;
    uint detail_vertex_count;
    uint detail_triangle_count;
    uint detail_portal_count;
    float cell_size;
    Vec3 detail_origin;
    double[2] detail_origin_correction;
}

$assert TileHeader::size == 136;

<* One resident tile; the arrays borrow into data. *>
struct MeshTile {
    uint                salt;
    TileHeader*         header;        // null while the slot is free
    Poly[]              polys;
    Vec3[]              verts;
    Vec3[]              detail_corners;
    BvNode[]            bv_tree;
    OffMeshConnection[] off_mesh;
    PolyDetail[]        details;
    Vec3[]              detail_vertices;
    DetailTriangle[]    detail_triangles;
    DetailPortal[]      detail_portals;
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
    uint  max_links;      // 0 takes max_tiles * DEFAULT_LINKS_PER_TILE; the mesh holds the resolved count
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
    Link[]      links;          // max_links, shared by every tile; Poly.first_link and Link.next index it
    uint        links_free;     // head of the free list; NULL_LINK when the pool is spent
    uint        free_link_count;
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

// An off-mesh connection point that lands on a polygon, and the links that join them.
struct OffMeshLanding @local {
    MeshTile* connection_tile;
    uint      connection_poly;    // the off-mesh polygon
    uint      vertex;             // of that polygon the point moves onto the landing
    char      edge;               // of that polygon the link leaves
    char      side;               // of that link
    MeshTile* landing_tile;
    uint      landing_poly;
    char      landing_side;       // of the link back from the landing polygon
    Vec3      point;
    bool      back_link;          // the landing polygon links back to the connection
}

struct LandingPoly @local {
    uint index;
    Vec3 point;
}

struct DetailProjection @local {
    Vec3 point;
    float local_height;
    double distance_sqr;
    uint triangle;
}

struct PortalRange @local {
    float min;
    float max;
}

<*
 Add a tile blob, link it to its neighbours and its own off-mesh connections; mirrors dtNavMesh::addTile.
 Changes nothing when it faults.
 @param data : "A TileData blob, 8-byte aligned; borrowed unless flags.free_data."
 @param last_ref : "Ref to restore when reloading; 0 takes any free slot."
 @return? c3d::INVALID_ARGUMENT, TILE_OCCUPIED, c3d::CAPACITY_EXCEEDED, NO_FREE_LINKS
*>
fn TileRef? NavMesh.add_tile(
    &self,
    char[] data,
    TileFlags flags,
    TileRef last_ref = (TileRef)0,
) {
    validate_tile_data(data)!;
    TileHeader* header = (TileHeader*)data.ptr;
    if (self.tile_at(header.x, header.z, header.layer)) return TILE_OCCUPIED~;

    MeshTile* slot = find_free_tile(self, last_ref)!;
    require_free_links(
        mesh:     self,
        data:     data,
        resident: null,
        credit:   0,
    )!;
    return commit_tile(
        mesh:     self,
        slot:     slot,
        data:     data,
        flags:    flags,
        last_ref: last_ref,
    );
}

<*
 Unlink and remove the tile; advances its salt so every ref into it fails.
 Returns every link the tile or its neighbours held for it to the pool.
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

    @each_adjacent_tile(self, header, tile; neighbour, side, opposite_side) {
        unconnect_links(self, neighbour, tile);
    };
    release_own_links(self, tile);

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

<*
 Add the tile built from a TileMesh blob; the mesh owns the TileData it allocates.
 Changes nothing when it faults.
 @param [in] connections : "Off-mesh connections whose start lies in the tile."
 @return? c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED, TILE_OCCUPIED, NO_FREE_LINKS
 @require tile_mesh.len > 0
*>
fn TileRef? NavMesh.add_tile_mesh(
    &self,
    char[] tile_mesh,
    OffMeshConnectionDesc[] connections,
    TileDataParams params,
) {
    char[] blob = create_tile_blob(self, tile_mesh, connections, params)!;
    defer catch alloc::free(self.allocator, blob.ptr);
    return self.add_tile(blob, { .free_data = true });
}

<*
 Replace the tile at params.tile_x, params.tile_z and params.tile_layer; an empty blob only removes it.
 Invalidates every PolyRef into the replaced tile; the resident tile must own its data, which is freed.
 The resident tile stays installed when it faults.
 @param [in] connections : "Off-mesh connections whose start lies in the tile."
 @return "The new tile, or 0 when the blob was empty."
 @return? c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED, NO_FREE_LINKS
*>
fn TileRef? NavMesh.install_tile_mesh(
    &self,
    char[] tile_mesh,
    OffMeshConnectionDesc[] connections,
    TileDataParams params,
) {
    MeshTile* resident = self.tile_at(params.tile_x, params.tile_z, params.tile_layer);
    if (!tile_mesh.len) {
        if (resident) (void)self.remove_tile(self.tile_ref(resident));
        return (TileRef)0;
    }
    if (!resident) return self.add_tile_mesh(tile_mesh, connections, params);

    char[] blob = create_tile_blob(self, tile_mesh, connections, params)!;
    defer catch alloc::free(self.allocator, blob.ptr);
    require_free_links(
        mesh:     self,
        data:     blob,
        resident: resident,
        credit:   held_link_count(self, resident),
    )!;

    // The removal frees the slot the new tile takes.
    (void)self.remove_tile(self.tile_ref(resident));
    return commit_tile(
        mesh:     self,
        slot:     self.next_free,
        data:     blob,
        flags:    { .free_data = true },
        last_ref: (TileRef)0,
    );
}

fn void? replace_tile_data_at(
    NavMesh* mesh,
    int tile_x,
    int tile_z,
    char[][] owned_data,
) @private {
    if (owned_data.len > MAX_TILES_AT) return c3d::CAPACITY_EXCEEDED~;
    char[][MAX_TILES_AT] buffers;
    buffers[:owned_data.len] = owned_data[..];
    foreach (index, data : buffers[:owned_data.len]) {
        foreach (previous : buffers[:index]) {
            if (tile_data_overlaps(data, previous)) return c3d::INVALID_ARGUMENT~;
        }
        foreach (&tile : mesh.tiles) {
            if (tile.header && tile_data_overlaps(data, tile.data)) return c3d::INVALID_ARGUMENT~;
        }
    }

    MeshTile[MAX_TILES_AT] staged;
    foreach (index, data : buffers[:owned_data.len]) {
        validate_tile_data(data)!;
        carve_tile_data(&staged[index], data);
        TileHeader* header = staged[index].header;
        if (header.x != tile_x || header.z != tile_z) return c3d::INVALID_ARGUMENT~;
        foreach (&previous : staged[:index]) {
            if (previous.header.layer == header.layer) return c3d::INVALID_ARGUMENT~;
        }
    }
    MeshTile[] candidates = staged[:owned_data.len];
    for (usz index = 1; index < candidates.len; index++) {
        MeshTile candidate = candidates[index];
        usz position = index;
        while (position && candidates[position - 1].header.layer > candidate.header.layer) {
            candidates[position] = candidates[position - 1];
            position--;
        }
        candidates[position] = candidate;
    }

    usz available_slots;
    foreach (&tile : mesh.tiles) {
        if (!tile.header || tile_at_coordinates(tile, tile_x, tile_z)) available_slots++;
    }
    if (candidates.len > available_slots) return c3d::CAPACITY_EXCEEDED~;
    ulong available_links = mesh.free_link_count;
    foreach (&tile : mesh.tiles) {
        if (!tile.header) continue;
        bool removed = tile_at_coordinates(tile, tile_x, tile_z);
        foreach (&poly : tile.polys) {
            for (uint link = poly.first_link; link != NULL_LINK; link = mesh.links[link].next) {
                if (removed || tile_at_coordinates(&mesh.tiles[decode_tile(mesh.links[link].ref)], tile_x, tile_z)) {
                    available_links++;
                }
            }
        }
    }
    foreach (index, &candidate : candidates) {
        @each_adjacent_tile(mesh, candidate.header, null; neighbour, side, opposite_side) {
            if (!tile_at_coordinates(neighbour, tile_x, tile_z)) {
                validate_portal_compatibility(candidate, neighbour, side)!;
            }
        };
        foreach (&previous : candidates[:index]) validate_portal_compatibility(candidate, previous, ANY_SIDE)!;
    }
    if (replacement_link_demand(
        mesh: mesh,
        candidates: candidates,
        tile_x: tile_x,
        tile_z: tile_z,
        limit: available_links,
    ) > available_links) return NO_FREE_LINKS~;

    unlink_replaced_set_incoming(mesh, tile_x, tile_z);
    foreach (&tile : mesh.tiles) {
        if (tile_at_coordinates(tile, tile_x, tile_z)) (void)mesh.remove_tile(mesh.tile_ref(tile));
    }
    foreach (&candidate : candidates) {
        (void)commit_tile(
            mesh: mesh,
            slot: mesh.next_free,
            data: candidate.data,
            flags: { .free_data = true },
            last_ref: (TileRef)0,
        );
    }
}

<*
 Move the tile grid and every resident tile by the negated offset; refs stay valid.
 @require offset.y == 0
*>
fn void NavMesh.shift_origin(&self, Vec3 offset) {
    self.desc.origin -= offset;
    foreach (&tile : self.tiles) {
        if (!tile.header) continue;
        shift_bounds(&tile.header.bounds, offset);
        shift_detail_origin(&tile.header.detail_origin, &tile.header.detail_origin_correction, offset);
        foreach (&vertex : tile.verts) *vertex -= offset;
        foreach (&connection : tile.off_mesh) {
            connection.start -= offset;
            connection.end -= offset;
        }
    }
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

<* Links left in the pool. *>
fn uint NavMesh.free_links(&self) => self.free_link_count;

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
    for (uint link = poly.first_link; link != NULL_LINK; link = self.links[link].next) {
        if (self.links[link].edge != 0) continue;
        if (self.links[link].ref != previous_ref) first = 1;
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
 Empty mesh with max_tiles free slots and a pool of desc.max_links links; mirrors dtNavMesh::init.
 @param desc : "Zero max_links reserves DEFAULT_LINKS_PER_TILE 24-byte links per slot."
 @return? c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn NavMesh? create_nav_mesh(Allocator allocator, NavMeshDesc desc) {
    if (desc.max_tiles == 0 || desc.max_tiles > 1u << TILE_BITS) return c3d::INVALID_ARGUMENT~;
    if (desc.tile_width <= 0 || desc.tile_height <= 0) return c3d::INVALID_ARGUMENT~;
    ulong link_count = desc.max_links ? desc.max_links : (ulong)desc.max_tiles * DEFAULT_LINKS_PER_TILE;
    if (link_count >= NULL_LINK) return c3d::INVALID_ARGUMENT~;

    desc.max_links = (uint)link_count;
    uint lookup_size = math::max(next_pow2(desc.max_tiles / 4), 1u);
    NavMesh mesh = {
        .allocator       = allocator,
        .desc            = desc,
        .lookup_size     = lookup_size,
        .lookup_mask     = lookup_size - 1,
        .links_free      = 0,
        .free_link_count = desc.max_links,
    };
    defer catch destroy_nav_mesh(&mesh);

    MeshTile[]? tiles = alloc::new_array_try(allocator, MeshTile, desc.max_tiles);
    if (catch tiles) return c3d::CAPACITY_EXCEEDED~;
    mesh.tiles = tiles;
    MeshTile*[]? lookup = alloc::new_array_try(allocator, MeshTile*, lookup_size);
    if (catch lookup) return c3d::CAPACITY_EXCEEDED~;
    mesh.lookup = lookup;
    Link[]? links = alloc::new_array_try(allocator, Link, desc.max_links);
    if (catch links) return c3d::CAPACITY_EXCEEDED~;
    mesh.links = links;

    // Pushed in reverse so the first free slot is tile 0.
    for (usz index = tiles.len; index > 0; index--) {
        MeshTile* tile = &tiles[index - 1];
        tile.salt = 1;
        tile.next = mesh.next_free;
        mesh.next_free = tile;
    }
    foreach (index, &link : links) link.next = index + 1 < links.len ? (uint)index + 1 : NULL_LINK;
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
    alloc::free(mesh.allocator, mesh.links.ptr);
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

fn MeshTile*? find_free_tile(NavMesh* mesh, TileRef last_ref) @local {
    if (!last_ref) {
        if (!mesh.next_free) return c3d::CAPACITY_EXCEEDED~;
        return mesh.next_free;
    }

    uint index = decode_tile((PolyRef)last_ref);
    if (index >= mesh.tiles.len) return c3d::CAPACITY_EXCEEDED~;
    MeshTile* target = &mesh.tiles[index];
    for (MeshTile* tile = mesh.next_free; tile; tile = tile.next) {
        if (tile == target) return target;
    }
    return c3d::CAPACITY_EXCEEDED~;
}

fn void claim_free_tile(NavMesh* mesh, MeshTile* tile, TileRef last_ref) @local {
    MeshTile* previous;
    MeshTile* current = mesh.next_free;
    while (current != tile) {
        previous = current;
        current = current.next;
    }
    if (previous) {
        previous.next = tile.next;
    } else {
        mesh.next_free = tile.next;
    }
    tile.next = null;
    if (last_ref) tile.salt = decode_salt((PolyRef)last_ref);
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

fn uint allocate_link(NavMesh* mesh) @local {
    uint link = mesh.links_free;
    mesh.links_free = mesh.links[link].next;
    mesh.free_link_count--;
    return link;
}

fn void free_link(NavMesh* mesh, uint link) @local {
    mesh.links[link].next = mesh.links_free;
    mesh.links_free = link;
    mesh.free_link_count++;
}

// Callers hold a count that proves the pool has a free link.
fn uint push_link(NavMesh* mesh, Poly* poly, Link link) @local {
    uint index = allocate_link(mesh);
    link.next = poly.first_link;
    mesh.links[index] = link;
    poly.first_link = index;
    return index;
}

fn uint insert_link_after(NavMesh* mesh, uint previous, Link link) @local {
    uint index = allocate_link(mesh);
    link.next = mesh.links[previous].next;
    mesh.links[index] = link;
    mesh.links[previous].next = index;
    return index;
}

fn char[]? create_tile_blob(
    NavMesh* mesh,
    char[] tile_mesh,
    OffMeshConnectionDesc[] connections,
    TileDataParams params,
) @private {
    TileMeshView view = validate_tile_mesh(tile_mesh)!;
    validate_tile_parameters(connections, params)!;
    char[]? blob = alloc::alloc_array_try(mesh.allocator, char, (sz)tile_data_size(view, connections, params));
    if (catch blob) return c3d::CAPACITY_EXCEEDED~;
    defer catch alloc::free(mesh.allocator, blob.ptr);

    create_tile_data(
        mesh:        view,
        connections: connections,
        params:      params,
        blob:        blob,
    )!;
    validate_tile_data(blob)!;
    return blob;
}

// Faults unless the blob's links fit the free links plus the credit; resident is the tile the blob replaces.
fn void? require_free_links(
    NavMesh* mesh,
    char[] data,
    MeshTile* resident,
    uint credit,
) @local {
    MeshTile probe;
    carve_tile_data(&probe, data);
    @each_adjacent_tile(mesh, probe.header, resident; neighbour, side, opposite_side) {
        validate_portal_compatibility(&probe, neighbour, side)!;
    };
    ulong available = (ulong)mesh.free_link_count + credit;
    if (count_tile_links(
        mesh: mesh,
        tile: &probe,
        resident: resident,
        limit: available,
    ) > available) return NO_FREE_LINKS~;
}

// Takes the slot and links the tile; require_free_links has proved the pool holds every link.
fn TileRef commit_tile(
    NavMesh* mesh,
    MeshTile* slot,
    char[] data,
    TileFlags flags,
    TileRef last_ref,
) @local {
    claim_free_tile(mesh, slot, last_ref);
    TileHeader* header = (TileHeader*)data.ptr;
    uint hash = tile_hash(header.x, header.z, mesh.lookup_mask);
    slot.next = mesh.lookup[hash];
    mesh.lookup[hash] = slot;

    carve_tile_data(slot, data);
    slot.flags = flags;
    link_tile(mesh, slot);
    return mesh.tile_ref(slot);
}

// Every tile joined to the tile by a shared coordinate or a shared border, except the one skipped.
macro void @each_adjacent_tile(
    NavMesh* mesh,
    TileHeader* header,
    MeshTile* skip;
    @body(MeshTile* neighbour, int side, int opposite_side)
) @local {
    MeshTile*[MAX_TILES_AT] adjacent;
    usz layers = mesh.tiles_at(header.x, header.z, adjacent[..]);
    foreach (neighbour : adjacent[:layers]) {
        if (neighbour != skip) @body(neighbour, ANY_SIDE, ANY_SIDE);
    }
    for (int side = 0; side < 8; side++) {
        usz count = neighbour_tiles_at(mesh, header.x, header.z, side, adjacent[..]);
        foreach (neighbour : adjacent[:count]) @body(neighbour, side, opposite_tile(side));
    }
}

// The links between polygons of the tile; mirrors the internal pass of connectIntLinks.
macro void @each_internal_link(MeshTile* tile, PolyRef base; @body(Poly* poly, Link link)) @local {
    foreach (&poly : tile.polys) {
        if (poly.area_type.type == OFF_MESH_CONNECTION) continue;
        // Visited backwards so the pushed list runs from the lowest edge to the highest.
        for (int edge = poly.vert_count - 1; edge >= 0; edge--) {
            ushort neighbour = poly.neighbours[edge];
            if (neighbour == 0 || (neighbour & EXTERNAL_LINK) != 0) continue;
            Link link = { .ref = base | (PolyRef)(neighbour - 1), .edge = (char)edge, .side = NO_SIDE };
            @body(poly, link);
        }
    }
}

// The start of each connection of the tile that lands on a polygon of the tile.
macro void @each_start_landing(MeshTile* tile; @body(OffMeshLanding landing)) @local {
    foreach (&connection : tile.off_mesh) {
        Vec3 half_extents = { connection.radius, tile.header.walkable_climb, connection.radius };
        LandingPoly? nearest = nearest_poly_in_tile(tile, connection.start, half_extents);
        if (catch nearest) continue;
        // The nearest polygon may lie beyond the radius along XZ.
        if (distance_sqr_2d(nearest.point, connection.start) > connection.radius * connection.radius) continue;

        OffMeshLanding landing = {
            .connection_tile = tile,
            .connection_poly = connection.poly,
            .vertex          = 0,
            .edge            = 0,
            .side            = NO_SIDE,
            .landing_tile    = tile,
            .landing_poly    = nearest.index,
            .landing_side    = NO_SIDE,
            .point           = nearest.point,
            .back_link       = true,
        };
        @body(landing);
    }
}

// The connections of target whose end lands on a polygon of tile; mirrors connectExtOffMeshLinks.
macro void @each_end_landing(
    MeshTile* tile,
    MeshTile* target,
    int side;
    @body(OffMeshLanding landing)
) @local {
    char opposite_side = side == ANY_SIDE ? NO_SIDE : (char)opposite_tile(side);
    foreach (&connection : target.off_mesh) {
        if (connection.side != opposite_side) continue;
        // A start that could not land leaves the connection nothing to link from.
        if (target.polys[connection.poly].first_link == NULL_LINK) continue;

        Vec3 half_extents = { connection.radius, target.header.walkable_climb, connection.radius };
        LandingPoly? nearest = nearest_poly_in_tile(tile, connection.end, half_extents);
        if (catch nearest) continue;
        if (distance_sqr_2d(nearest.point, connection.end) > connection.radius * connection.radius) continue;

        OffMeshLanding landing = {
            .connection_tile = target,
            .connection_poly = connection.poly,
            .vertex          = 1,
            .edge            = 1,
            .side            = opposite_side,
            .landing_tile    = tile,
            .landing_poly    = nearest.index,
            .landing_side    = side == ANY_SIDE ? NO_SIDE : (char)side,
            .point           = nearest.point,
            .back_link       = (connection.flags & BIDIRECTIONAL) != 0,
        };
        @body(landing);
    }
}

// The links from polygons of tile across their portal edges to polygons of target, one per target polygon and edge.
// The body gets first set for the first link of each source edge. Mirrors connectExtLinks and findConnectingPolys.
macro void @each_portal_link(
    MeshTile* tile,
    MeshTile* target,
    PolyRef target_base,
    int side;
    @body(Poly* poly, Link link, bool first)
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
            int target_side = opposite_tile(direction);
            Slab edge_slab = slab_end_points(start, end, target_side);
            float edge_position = slab_coord(start, target_side);
            ushort portal = EXTERNAL_LINK | (ushort)target_side;
            bool along_z = direction == 0 || direction == 4;
            float edge_start = along_z ? start.z : start.x;
            float edge_length = along_z ? end.z - start.z : end.x - start.x;

            bool first = true;
            foreach (index, &other : target.polys) {
                int other_count = other.vert_count;
                for (int other_edge = 0; other_edge < other_count; other_edge++) {
                    if (other.neighbours[other_edge] != portal) continue;
                    Vec3 other_start = target.verts[other.verts[other_edge]];
                    Vec3 other_end = target.verts[other.verts[(other_edge + 1) % other_count]];
                    if (tile.header.detail_mode != target.header.detail_mode) continue;
                    if (tile.header.detail_mode == DetailMode.BOUNDED && target.header.detail_mode == DetailMode.BOUNDED) {
                        foreach (source_portal : tile.detail_portals) {
                            if (source_portal.polygon != (uint)(poly - tile.polys.ptr) || source_portal.edge != (uint)edge) continue;
                            foreach (target_portal : target.detail_portals) {
                                if (target_portal.polygon != index || target_portal.edge != (uint)other_edge) continue;
                                if (try range = precision_portal_range(
                                    tile: tile,
                                    poly: poly,
                                    source: source_portal,
                                    target: target,
                                    other: other,
                                    destination: target_portal,
                                )) {
                                    Link link = {
                                        .ref = target_base | (PolyRef)index,
                                        .edge = (char)edge,
                                        .side = (char)direction,
                                        .min = range.min,
                                        .max = range.max,
                                    };
                                    @body(poly, link, first);
                                    first = false;
                                }
                            }
                        }
                        break;
                    }
                    if (math::abs(edge_position - slab_coord(other_start, target_side)) > SLAB_TOLERANCE) continue;
                    Slab other_slab = slab_end_points(other_start, other_end, target_side);
                    if (!overlap_slabs(edge_slab, other_slab, SLAB_TOLERANCE, target.header.walkable_climb)) continue;

                    float t_min = (math::max(edge_slab.min[0], other_slab.min[0]) - edge_start) / edge_length;
                    float t_max = (math::min(edge_slab.max[0], other_slab.max[0]) - edge_start) / edge_length;
                    if (t_min > t_max) @swap(t_min, t_max);
                    Link link = {
                        .ref  = target_base | (PolyRef)index,
                        .edge = (char)edge,
                        .side = (char)direction,
                        .min  = math::round(math::clamp(t_min, 0.0f, 1.0f) * PORTAL_LIMIT_SCALE) * (1.0f / PORTAL_LIMIT_SCALE),
                        .max  = math::round(math::clamp(t_max, 0.0f, 1.0f) * PORTAL_LIMIT_SCALE) * (1.0f / PORTAL_LIMIT_SCALE),
                    };
                    @body(poly, link, first);
                    first = false;
                    break;
                }
            }
        }
    }
}

// How many links link_tile pushes for the tile, against the mesh as it would be without the resident tile.
// Marks the polygons of connections whose start lands, which the end landings read.
fn ulong count_tile_links(
    NavMesh* mesh,
    MeshTile* tile,
    MeshTile* resident,
    ulong limit,
) @local {
    foreach (&poly : tile.polys) poly.first_link = NULL_LINK;

    ulong needed;
    @each_internal_link(tile, (PolyRef)0; poly, link) {
        needed++;
        if (needed > limit) return needed;
    };
    @each_start_landing(tile; landing) {
        needed += 2;
        if (needed > limit) return needed;
        tile.polys[landing.connection_poly].first_link = START_LANDED;
    };
    needed += count_landing_links(tile, tile, ANY_SIDE);
    if (needed > limit) return needed;
    @each_adjacent_tile(mesh, tile.header, resident; neighbour, side, opposite_side) {
        needed += count_portal_links(
            tile: tile,
            target: neighbour,
            side: side,
            limit: limit - needed,
        );
        if (needed > limit) return needed;
        needed += count_portal_links(
            tile: neighbour,
            target: tile,
            side: opposite_side,
            limit: limit - needed,
        );
        if (needed > limit) return needed;
        needed += count_landing_links(tile, neighbour, side);
        needed += count_landing_links(neighbour, tile, opposite_side);
        if (needed > limit) return needed;
    };
    return needed;
}

fn bool tile_at_coordinates(MeshTile* tile, int x, int z) @local {
    return tile.header && tile.header.x == x && tile.header.z == z;
}

fn bool tile_data_overlaps(char[] first, char[] second) @local {
    if (!first.len || !second.len) return false;
    uptr first_address = (uptr)first.ptr;
    uptr second_address = (uptr)second.ptr;
    return first_address <= second_address
        ? second_address - first_address < first.len
        : first_address - second_address < second.len;
}

fn ulong replacement_link_demand(
    NavMesh* mesh,
    MeshTile[] candidates,
    int tile_x,
    int tile_z,
    ulong limit,
) @local {
    ulong needed;
    foreach (&candidate : candidates) {
        foreach (&poly : candidate.polys) poly.first_link = NULL_LINK;
        @each_internal_link(candidate, (PolyRef)0; poly, link) {
            needed++;
        };
        @each_start_landing(candidate; landing) {
            candidate.polys[landing.connection_poly].first_link = START_LANDED;
            needed += 2;
        };
        if (needed > limit) return needed;
    }
    foreach (index, &candidate : candidates) {
        needed += count_landing_links(candidate, candidate, ANY_SIDE);
        if (needed > limit) return needed;
        @each_adjacent_tile(mesh, candidate.header, null; neighbour, side, opposite_side) {
            if (!tile_at_coordinates(neighbour, tile_x, tile_z)) {
                needed += replacement_pair_links(
                    first: candidate,
                    second: neighbour,
                    side: side,
                    opposite_side: opposite_side,
                    limit: limit - needed,
                );
                if (needed > limit) return needed;
            }
        };
        foreach (&previous : candidates[:index]) {
            needed += replacement_pair_links(
                first: candidate,
                second: previous,
                side: ANY_SIDE,
                opposite_side: ANY_SIDE,
                limit: limit - needed,
            );
            if (needed > limit) return needed;
        }
    }
    return needed;
}

fn ulong replacement_pair_links(
    MeshTile* first,
    MeshTile* second,
    int side,
    int opposite_side,
    ulong limit,
) @local {
    ulong needed = count_portal_links(
        tile: first,
        target: second,
        side: side,
        limit: limit,
    );
    if (needed > limit) return needed;
    needed += count_portal_links(
        tile: second,
        target: first,
        side: opposite_side,
        limit: limit - needed,
    );
    if (needed > limit) return needed;
    needed += count_landing_links(first, second, side);
    needed += count_landing_links(second, first, opposite_side);
    return needed;
}

fn void unlink_replaced_set_incoming(NavMesh* mesh, int tile_x, int tile_z) @local {
    foreach (&tile : mesh.tiles) {
        if (!tile.header || tile_at_coordinates(tile, tile_x, tile_z)) continue;
        foreach (&poly : tile.polys) {
            uint previous = NULL_LINK;
            uint link = poly.first_link;
            while (link != NULL_LINK) {
                uint next = mesh.links[link].next;
                if (tile_at_coordinates(&mesh.tiles[decode_tile(mesh.links[link].ref)], tile_x, tile_z)) {
                    if (previous == NULL_LINK) {
                        poly.first_link = next;
                    } else {
                        mesh.links[previous].next = next;
                    }
                    free_link(mesh, link);
                } else {
                    previous = link;
                }
                link = next;
            }
        }
    }
}

fn ulong count_portal_links(
    MeshTile* tile,
    MeshTile* target,
    int side,
    ulong limit,
) @local {
    ulong count;
    @each_portal_link(tile, target, (PolyRef)0, side; poly, link, first) {
        count++;
        if (count > limit) return count;
    };
    return count;
}

fn uint count_landing_links(MeshTile* tile, MeshTile* target, int side) @local {
    uint count;
    @each_end_landing(tile, target, side; landing) {
        count += landing.back_link ? 2 : 1;
    };
    return count;
}

// Mirrors the order of dtNavMesh::addTile's connect calls.
fn void link_tile(NavMesh* mesh, MeshTile* tile) @local {
    foreach (&poly : tile.polys) poly.first_link = NULL_LINK;

    @each_internal_link(tile, mesh.poly_ref_base(tile); poly, link) {
        push_link(mesh, poly, link);
    };
    @each_start_landing(tile; landing) {
        link_off_mesh_landing(mesh, &landing);
    };
    push_landing_links(mesh, tile, tile, ANY_SIDE);
    @each_adjacent_tile(mesh, tile.header, tile; neighbour, side, opposite_side) {
        push_portal_links(mesh, tile, neighbour, side);
        push_portal_links(mesh, neighbour, tile, opposite_side);
        push_landing_links(mesh, tile, neighbour, side);
        push_landing_links(mesh, neighbour, tile, opposite_side);
    };
}

// Within one source edge the links keep ascending target order: the first goes to the head, the rest follow it.
fn void push_portal_links(NavMesh* mesh, MeshTile* tile, MeshTile* target, int side) @local {
    uint batch_tail;
    @each_portal_link(tile, target, mesh.poly_ref_base(target), side; poly, link, first) {
        batch_tail = first ? push_link(mesh, poly, link) : insert_link_after(mesh, batch_tail, link);
    };
}

fn void push_landing_links(NavMesh* mesh, MeshTile* tile, MeshTile* target, int side) @local {
    @each_end_landing(tile, target, side; landing) {
        link_off_mesh_landing(mesh, &landing);
    };
}

// The connection's point moves onto the polygon it lands on.
fn void link_off_mesh_landing(NavMesh* mesh, OffMeshLanding* landing) @local {
    MeshTile* connection_tile = landing.connection_tile;
    Poly* connection_poly = &connection_tile.polys[landing.connection_poly];
    connection_tile.verts[connection_poly.verts[landing.vertex]] = landing.point;

    push_link(mesh, connection_poly, {
        .ref  = mesh.poly_ref_base(landing.landing_tile) | (PolyRef)landing.landing_poly,
        .edge = landing.edge,
        .side = landing.side,
    });
    if (!landing.back_link) return;
    push_link(mesh, &landing.landing_tile.polys[landing.landing_poly], {
        .ref  = mesh.poly_ref_base(connection_tile) | (PolyRef)landing.connection_poly,
        .edge = LANDING_EDGE,
        .side = landing.landing_side,
    });
}

// Links that disappear with the tile: its own, and those its neighbours hold into it.
fn uint held_link_count(NavMesh* mesh, MeshTile* tile) @local {
    uint held;
    foreach (&poly : tile.polys) {
        for (uint link = poly.first_link; link != NULL_LINK; link = mesh.links[link].next) held++;
    }
    uint index = tile_index(mesh, tile);
    @each_adjacent_tile(mesh, tile.header, tile; neighbour, side, opposite_side) {
        foreach (&poly : neighbour.polys) {
            for (uint link = poly.first_link; link != NULL_LINK; link = mesh.links[link].next) {
                if (decode_tile(mesh.links[link].ref) == index) held++;
            }
        }
    };
    return held;
}

fn void release_own_links(NavMesh* mesh, MeshTile* tile) @local {
    foreach (&poly : tile.polys) {
        uint link = poly.first_link;
        while (link != NULL_LINK) {
            uint next = mesh.links[link].next;
            free_link(mesh, link);
            link = next;
        }
    }
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
            uint next = mesh.links[link].next;
            if (decode_tile(mesh.links[link].ref) != target_index) {
                previous = link;
                link = next;
                continue;
            }
            if (previous == NULL_LINK) {
                poly.first_link = next;
            } else {
                mesh.links[previous].next = next;
            }
            free_link(mesh, link);
            link = next;
        }
    }
}

// Polygons whose bounds overlap the box, through the BV tree when the tile has one; mirrors queryPolygonsInTile.
macro void @each_poly_overlapping(MeshTile* tile, Aabb box; @body(uint index, Poly* poly)) @private {
    if (!tile.bv_tree.len) {
        foreach (index, &poly : tile.polys) {
            if (poly.area_type.type == OFF_MESH_CONNECTION) continue;
            if (overlap_bounds(box, polygon_bounds(tile, poly))) @body((uint)index, poly);
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
        if (leaf && overlap) {
            Poly* poly = &tile.polys[current.index];
            if (tile.header.detail_mode == DetailMode.COARSE || overlap_bounds(box, polygon_bounds(tile, poly))) {
                @body((uint)current.index, poly);
            }
        }
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
    if (poly.area_type.type == GROUND && tile.header.detail_mode == DetailMode.BOUNDED) {
        PolyDetail detail = tile.details[(usz)(poly - tile.polys.ptr)];
        foreach (vertex : tile.detail_vertices[detail.vertex_base:detail.vertex_count]) {
            Vec3 world = tile.header.detail_origin + vertex;
            bounds.min = math::min(bounds.min, world);
            bounds.max = math::max(bounds.max, world);
        }
    }
    return bounds;
}

// NO_POLY when no polygon overlaps the box; mirrors findNearestPolyInTile.
fn LandingPoly? nearest_poly_in_tile(
    MeshTile* tile,
    Vec3 center,
    Vec3 half_extents,
) @local {
    Aabb box = { .min = center - half_extents, .max = center + half_extents };
    LandingPoly nearest;
    bool found;
    float nearest_distance = float::max;
    @each_poly_overlapping(tile, box; index, poly) {
        ClosestPoint closest = closest_point_on_poly_in_tile(tile, poly, center);
        float distance = nearness(center, closest, tile.header.walkable_climb);
        if (distance < nearest_distance || (distance == nearest_distance && (!found || index < nearest.index))) {
            nearest = { .index = index, .point = closest.point };
            nearest_distance = distance;
            found = true;
        }
    };
    if (!found) return NO_POLY~;
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
    if (tile.header.detail_mode == DetailMode.BOUNDED) {
        SurfacePoint surface = polygon_surface(tile, poly, position)!;
        return surface.height;
    }
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
    return closest_point_on_poly_in_tile(found.tile, found.poly, position);
}

fn ClosestPoint closest_point_on_poly_in_tile(MeshTile* tile, Poly* poly, Vec3 position) @private {
    if (try height = polygon_height(tile, poly, position)) {
        return { .point = { position.x, height, position.z }, .over_poly = true };
    }
    if (poly.area_type.type == OFF_MESH_CONNECTION) {
        Vec3 start = tile.verts[poly.verts[0]];
        Vec3 end = tile.verts[poly.verts[1]];
        return { .point = lerp_point(start, end, distance_pt_seg_sqr_2d(position, start, end).t) };
    }
    if (tile.header.detail_mode == DetailMode.BOUNDED
        && tile.details[(usz)(poly - tile.polys.ptr)].triangle_count) {
        DetailProjection projection = closest_detail_projection(
            tile: tile,
            poly: poly,
            position: position,
            only_boundary: true,
        );
        return { .point = projection.point };
    }
    Vec3[MAX_VERTS_PER_POLY] verts = polygon_vertices(tile, poly);
    return { .point = closest_point_on_fan_edges(verts[:poly.vert_count], position, true) };
}

fn SurfacePoint? polygon_surface(MeshTile* tile, Poly* poly, Vec3 position) @private {
    SurfacePoint surface = polygon_surface_local(tile, poly, position)!;
    if (tile.header.detail_mode == DetailMode.COARSE) {
        surface.height = polygon_height(tile, poly, position)!;
    } else {
        surface.height += tile.header.detail_origin.y;
    }
    return surface;
}

fn SurfacePoint? polygon_surface_local(MeshTile* tile, Poly* poly, Vec3 position) @local {
    return polygon_surface_at_local(
        tile: tile,
        poly: poly,
        local_position: position - tile.header.detail_origin,
        world_boundary: true,
    );
}

fn SurfacePoint? polygon_surface_at_local(
    MeshTile* tile,
    Poly* poly,
    Vec3 local_position,
    bool world_boundary = false,
) @local {
    if (poly.area_type.type != GROUND) return c3d::INVALID_ARGUMENT~;
    Vec3 origin = tile.header.detail_origin;
    if (tile.header.detail_mode == DetailMode.BOUNDED) {
        PolyDetail detail = tile.details[(usz)(poly - tile.polys.ptr)];
        if (detail.triangle_count) {
            Vec3[] vertices = tile.detail_vertices[detail.vertex_base:detail.vertex_count];
            Vec3 world_position = origin + local_position;
            bool on_boundary;
            for (usz edge = 0; world_boundary && edge < poly.vert_count; edge++) {
                Vec3 first = tile.verts[poly.verts[edge]];
                Vec3 last = tile.verts[poly.verts[(edge + 1) % poly.vert_count]];
                if (detail_triangle_area(first, last, world_position) == 0
                    && world_position.x >= math::min(first.x, last.x) && world_position.x <= math::max(first.x, last.x)
                    && world_position.z >= math::min(first.z, last.z) && world_position.z <= math::max(first.z, last.z)) {
                    on_boundary = true;
                    break;
                }
            }
            if (on_boundary) {
                DetailProjection projection = closest_detail_projection_local(
                    tile: tile,
                    poly: poly,
                    local_position: local_position,
                    only_boundary: true,
                );
                double allowance = detail_numerical_allowance(tile.header.cell_size) + detail_world_allowance(tile.header.bounds);
                if (projection.distance_sqr <= allowance * allowance) {
                    DetailTriangle triangle = tile.detail_triangles[projection.triangle];
                    SurfacePoint surface = detail_triangle_surface(
                        first: vertices[triangle.vertices[0]],
                        second: vertices[triangle.vertices[1]],
                        third: vertices[triangle.vertices[2]],
                        position: vertices[triangle.vertices[0]],
                    )!;
                    surface.height = projection.local_height;
                    return surface;
                }
            }
            foreach (triangle : tile.detail_triangles[detail.triangle_base:detail.triangle_count]) {
                if (try surface = detail_triangle_surface(
                    first: vertices[triangle.vertices[0]],
                    second: vertices[triangle.vertices[1]],
                    third: vertices[triangle.vertices[2]],
                    position: local_position,
                )) {
                    return surface;
                }
            }
            DetailProjection projection = closest_detail_projection_local(
                tile: tile,
                poly: poly,
                local_position: local_position,
                only_boundary: false,
            );
            Vec3 extent = tile.header.bounds.max - tile.header.bounds.min;
            double allowance = detail_numerical_allowance(math::max(extent.x, extent.z)) + detail_world_allowance(tile.header.bounds);
            if (projection.distance_sqr > allowance * allowance) return c3d::INVALID_ARGUMENT~;
            DetailTriangle triangle = tile.detail_triangles[projection.triangle];
            SurfacePoint surface = detail_triangle_surface(
                first: vertices[triangle.vertices[0]],
                second: vertices[triangle.vertices[1]],
                third: vertices[triangle.vertices[2]],
                position: vertices[triangle.vertices[0]],
            )!;
            surface.height = projection.local_height;
            return surface;
        }
    }

    Vec3[MAX_VERTS_PER_POLY] vertices = polygon_vertices(tile, poly);
    for (usz vertex = 0; vertex < poly.vert_count; vertex++) {
        vertices[vertex] = tile.header.detail_mode == DetailMode.BOUNDED
            ? tile.detail_corners[poly.verts[vertex]] : vertices[vertex] - origin;
    }
    for (usz third = 2; third < poly.vert_count; third++) {
        if (try surface = detail_triangle_surface(
            first: vertices[0],
            second: vertices[third - 1],
            third: vertices[third],
            position: local_position,
        )) {
            return surface;
        }
    }
    if (tile.header.detail_mode == DetailMode.BOUNDED) {
        Vec3 extent = tile.header.bounds.max - tile.header.bounds.min;
        double allowance = detail_numerical_allowance(math::max(extent.x, extent.z)) + detail_world_allowance(tile.header.bounds);
        float nearest = float::max;
        SurfacePoint selected;
        for (usz third = 2; third < poly.vert_count; third++) {
            Vec3[3] triangle = { vertices[0], vertices[third - 1], vertices[third] };
            if (!detail_triangle_valid(triangle[0], triangle[1], triangle[2])) continue;
            for (usz edge = 0; edge < 3; edge++) {
                Vec3 first = triangle[edge];
                Vec3 last = triangle[(edge + 1) % 3];
                SegmentProjection projection = distance_pt_seg_sqr_2d(local_position, first, last);
                if (projection.distance_sqr >= nearest) continue;
                nearest = projection.distance_sqr;
                selected = detail_triangle_surface(
                    first: triangle[0],
                    second: triangle[1],
                    third: triangle[2],
                    position: triangle[0],
                )!;
                selected.height = lerp_point(first, last, projection.t).y;
            }
        }
        if (nearest <= allowance * allowance) return selected;
    }
    return c3d::INVALID_ARGUMENT~;
}

fn DetailProjection closest_detail_projection(
    MeshTile* tile,
    Poly* poly,
    Vec3 position,
    bool only_boundary,
) @local {
    return closest_detail_projection_local(
        tile: tile,
        poly: poly,
        local_position: position - tile.header.detail_origin,
        only_boundary: only_boundary,
    );
}

fn DetailProjection closest_detail_projection_local(
    MeshTile* tile,
    Poly* poly,
    Vec3 local_position,
    bool only_boundary,
) @local {
    PolyDetail detail = tile.details[(usz)(poly - tile.polys.ptr)];
    Vec3[] vertices = tile.detail_vertices[detail.vertex_base:detail.vertex_count];
    DetailProjection result = { .distance_sqr = double::max };
    foreach (index, triangle : tile.detail_triangles[detail.triangle_base:detail.triangle_count]) {
        for (usz edge = 0; edge < 3; edge++) {
            if (only_boundary && (triangle.boundary_edges & (1u << edge)) == 0) continue;
            Vec3 start = vertices[triangle.vertices[edge]];
            Vec3 end = vertices[triangle.vertices[(edge + 1) % 3]];
            double delta_x = (double)end.x - start.x;
            double delta_z = (double)end.z - start.z;
            double offset_x = (double)local_position.x - start.x;
            double offset_z = (double)local_position.z - start.z;
            double along = math::clamp((offset_x * delta_x + offset_z * delta_z)
                / (delta_x * delta_x + delta_z * delta_z), 0.0, 1.0);
            double distance_x = offset_x - along * delta_x;
            double distance_z = offset_z - along * delta_z;
            double distance_sqr = distance_x * distance_x + distance_z * distance_z;
            if (distance_sqr >= result.distance_sqr) continue;
            result.distance_sqr = distance_sqr;
            result.triangle = detail.triangle_base + (uint)index;
            result.local_height = (float)(start.y + along * ((double)end.y - start.y));
            result.point = tile.header.detail_origin + (Vec3){
                (float)(start.x + along * delta_x),
                result.local_height,
                (float)(start.z + along * delta_z),
            };
        }
    }
    return result;
}

fn bool spatial_ref_precedes(NavMesh* mesh, PolyRef candidate, PolyRef current) @private {
    if (!current) return true;
    TileHeader* first = mesh.tiles[decode_tile(candidate)].header;
    TileHeader* second = mesh.tiles[decode_tile(current)].header;
    if (first.x != second.x) return first.x < second.x;
    if (first.z != second.z) return first.z < second.z;
    if (first.layer != second.layer) return first.layer < second.layer;
    return decode_poly(candidate) < decode_poly(current);
}

fn void? validate_portal_compatibility(MeshTile* tile, MeshTile* target, int side) @local {
    if (tile.header.detail_mode == DetailMode.COARSE && target.header.detail_mode == DetailMode.COARSE) return;
    foreach (&poly : tile.polys) {
        for (usz edge = 0; edge < poly.vert_count; edge++) {
            ushort neighbour = poly.neighbours[edge];
            if ((neighbour & EXTERNAL_LINK) == 0) continue;
            int direction = neighbour & 0xff;
            if (side != ANY_SIDE && direction != side) continue;
            Vec3 first = tile.verts[poly.verts[edge]];
            Vec3 second = tile.verts[poly.verts[(edge + 1) % poly.vert_count]];
            Slab source = slab_end_points(first, second, direction);
            double allowance = detail_numerical_allowance(tile.header.cell_size)
                + math::max(detail_world_allowance(tile.header.bounds), detail_world_allowance(target.header.bounds));
            foreach (&other : target.polys) {
                for (usz other_edge = 0; other_edge < other.vert_count; other_edge++) {
                    if (other.neighbours[other_edge] != (EXTERNAL_LINK | (ushort)opposite_tile(direction))) continue;
                    Vec3 other_first = target.verts[other.verts[other_edge]];
                    Vec3 other_second = target.verts[other.verts[(other_edge + 1) % other.vert_count]];
                    if (math::abs((double)slab_coord(first, direction) - slab_coord(other_first, direction)) > allowance) continue;
                    Slab destination = slab_end_points(other_first, other_second, direction);
                    if (math::max(source.min[0], destination.min[0]) >= math::min(source.max[0], destination.max[0])) continue;
                    if (tile.header.detail_mode != target.header.detail_mode
                        || tile.header.cell_size != target.header.cell_size
                        || tile.header.walkable_height != target.header.walkable_height
                        || tile.header.walkable_radius != target.header.walkable_radius
                        || tile.header.walkable_climb != target.header.walkable_climb) return c3d::INVALID_ARGUMENT~;
                    Vec3 origin = tile.header.detail_origin;
                    Vec3 other_origin = target.header.detail_origin;
                    double pitch = tile.header.cell_size;
                    double delta_x = (double)origin.x + tile.header.detail_origin_correction[0]
                        - other_origin.x - target.header.detail_origin_correction[0];
                    double delta_z = (double)origin.z + tile.header.detail_origin_correction[1]
                        - other_origin.z - target.header.detail_origin_correction[1];
                    double lattice_allowance = detail_numerical_allowance(tile.header.cell_size);
                    if (math::abs(delta_x - math::round(delta_x / pitch) * pitch) > lattice_allowance
                        || math::abs(delta_z - math::round(delta_z / pitch) * pitch) > lattice_allowance) return c3d::INVALID_ARGUMENT~;
                }
            }
        }
    }
}

fn PortalRange? precision_portal_range(
    MeshTile* tile,
    Poly* poly,
    DetailPortal source,
    MeshTile* target,
    Poly* other,
    DetailPortal destination,
) @local {
    double source_height = (double)tile.header.detail_origin.y + source.source_height;
    double source_target = (double)tile.header.detail_origin.y + source.target_height;
    double target_height = (double)target.header.detail_origin.y + destination.source_height;
    double target_source = (double)target.header.detail_origin.y + destination.target_height;
    if (source_height != target_source || source_target != target_height) return NOT_FOUND~;
    int side = poly.neighbours[source.edge] & 0xff;
    bool along_z = side == 0 || side == 4;
    Vec3 basis_offset = detail_basis_offset(tile, target);
    Vec3 first = tile.detail_corners[poly.verts[source.edge]];
    Vec3 second = tile.detail_corners[poly.verts[(source.edge + 1) % poly.vert_count]];
    Vec3 other_first = target.detail_corners[other.verts[destination.edge]] + basis_offset;
    Vec3 other_second = target.detail_corners[other.verts[(destination.edge + 1) % other.vert_count]] + basis_offset;
    if (math::abs((double)slab_coord(first, side) - slab_coord(other_first, side))
        > detail_numerical_allowance(tile.header.cell_size)) return NOT_FOUND~;
    double start = along_z ? first.z : first.x;
    double length = (along_z ? (double)second.z : (double)second.x) - start;
    double other_start = along_z ? other_first.z : other_first.x;
    double other_length = (along_z ? (double)other_second.z : (double)other_second.x) - other_start;
    if (length == 0 || other_length == 0) return NOT_FOUND~;
    double low = start + length * source.min;
    double high = start + length * source.max;
    if (low > high) @swap(low, high);
    double other_low = other_start + other_length * destination.min;
    double other_high = other_start + other_length * destination.max;
    if (other_low > other_high) @swap(other_low, other_high);
    low = math::max(low, other_low);
    high = math::min(high, other_high);
    if (low >= high) return NOT_FOUND~;
    PortalRange result = inward_portal_range(
        start: start,
        length: length,
        low: low,
        high: high,
    )!;
    (void)inward_portal_range(
        start: other_start,
        length: other_length,
        low: low,
        high: high,
    )!;
    if (!matching_detail_profiles(
        tile: tile,
        poly: poly,
        target: target,
        other: other,
        anchor: first,
        along_z: along_z,
        low: low,
        high: high,
    )) return NOT_FOUND~;
    return result;
}

fn PortalRange? inward_portal_range(
    double start,
    double length,
    double low,
    double high,
) @local {
    double first = math::clamp((low - start) / length, 0.0, 1.0);
    double last = math::clamp((high - start) / length, 0.0, 1.0);
    if (first > last) @swap(first, last);
    float minimum = (float)first;
    float maximum = (float)last;
    if ((double)minimum < first) minimum = minimum.nexthigher();
    if ((double)maximum > last) maximum = bitcast(bitcast(maximum, uint) - 1, float);
    if (minimum >= maximum) return NOT_FOUND~;
    return { .min = minimum, .max = maximum };
}

fn bool matching_detail_profiles(
    MeshTile* tile,
    Poly* poly,
    MeshTile* target,
    Poly* other,
    Vec3 anchor,
    bool along_z,
    double low,
    double high,
) @local {
    Vec3 first = anchor;
    Vec3 last = anchor;
    if (along_z) {
        first.z = (float)low;
        last.z = (float)high;
    } else {
        first.x = (float)low;
        last.x = (float)high;
    }
    if (!matching_detail_height(
        tile: tile,
        poly: poly,
        target: target,
        other: other,
        position: first,
    ) || !matching_detail_height(
        tile: tile,
        poly: poly,
        target: target,
        other: other,
        position: last,
    )) return false;
    for (uint pass = 0; pass < 2; pass++) {
        MeshTile* source = pass ? target : tile;
        Poly* source_poly = pass ? other : poly;
        PolyDetail detail = source.details[(usz)(source_poly - source.polys.ptr)];
        double allowance = detail_numerical_allowance(source.header.cell_size);
        foreach (vertex : source.detail_vertices[detail.vertex_base:detail.vertex_count]) {
            Vec3 basis_offset = pass ? detail_basis_offset(tile, target) : (Vec3){};
            double position = along_z ? (double)basis_offset.z + vertex.z : (double)basis_offset.x + vertex.x;
            double edge_position = along_z ? (double)basis_offset.x + vertex.x : (double)basis_offset.z + vertex.z;
            if (position <= low || position >= high
                || math::abs(edge_position - (along_z ? (double)anchor.x : (double)anchor.z)) > allowance) continue;
            Vec3 point = anchor;
            if (along_z) {
                point.z = (float)position;
            } else {
                point.x = (float)position;
            }
            if (!matching_detail_height(
                tile: tile,
                poly: poly,
                target: target,
                other: other,
                position: point,
            )) return false;
        }
    }
    return true;
}

fn bool matching_detail_height(
    MeshTile* tile,
    Poly* poly,
    MeshTile* target,
    Poly* other,
    Vec3 position,
) @local {
    SurfacePoint? source = polygon_surface_at_local(tile, poly, position);
    SurfacePoint? destination = polygon_surface_at_local(target, other, position - detail_basis_offset(tile, target));
    if (catch source) return false;
    if (catch destination) return false;
    double height = (double)tile.header.detail_origin.y + source.height;
    double other_height = (double)target.header.detail_origin.y + destination.height;
    double allowance = math::max(
        detail_numerical_allowance(tile.header.bounds.max.y - tile.header.bounds.min.y),
        detail_numerical_allowance(target.header.bounds.max.y - target.header.bounds.min.y),
    );
    return math::abs(height - other_height) <= allowance;
}

fn Vec3 detail_basis_offset(MeshTile* tile, MeshTile* target) @local {
    double pitch = tile.header.cell_size;
    return {
        (float)(math::round(((double)target.header.detail_origin.x + target.header.detail_origin_correction[0]
            - tile.header.detail_origin.x - tile.header.detail_origin_correction[0]) / pitch) * pitch),
        0,
        (float)(math::round(((double)target.header.detail_origin.z + target.header.detail_origin_correction[1]
            - tile.header.detail_origin.z - tile.header.detail_origin_correction[1]) / pitch) * pitch),
    };
}
