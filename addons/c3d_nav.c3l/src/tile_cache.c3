module c3d::nav;

import std::math;
import c3d;

<* Handle to a cached layer: salt and slot index; zero is never valid. *>
typedef CachedLayerRef = uint;

<* Handle to an obstacle: 16 bits of salt over a 16-bit slot index; zero is never valid. *>
typedef ObstacleRef = uint;

<* Per-polygon area and flag hook run before tile data is created; null means POLY_FLAG_WALK on every polygon. *>
alias MeshProcessFn = fn void (void* context, TileMeshView mesh, char[] areas, ushort[] flags);

<* Volumes overlapping the bounds for a layer rebuild to mark; the slice stays valid until the next call. *>
alias VolumeSourceFn = fn VolumeRecord[]? (void* context, Aabb bounds);

<* Off-mesh connections starting in the bounds for a rebuilt tile; the slice stays valid until the next call. *>
alias LinkSourceFn = fn OffMeshConnectionDesc[] (void* context, Aabb bounds);

<* Cached layers one obstacle may touch; mirrors DT_MAX_TOUCHED_TILES. *>
const uint MAX_TOUCHED_TILES = 8; // 64 bytes of refs per obstacle; a wider obstacle marks only the first eight

<* Obstacle requests queued between updates; mirrors MAX_REQUESTS. *>
const uint MAX_OBSTACLE_REQUESTS = 64; // 8 bytes each; the burst of door toggles one frame absorbs

<* Cached layers queued for rebuild; mirrors MAX_UPDATE. *>
const uint MAX_UPDATE_TILES = 64; // 256 bytes; obstacle requests wait while any rebuild is queued

const uint OBSTACLE_SALT_BITS @local = 16;
const uint OBSTACLE_INDEX_MASK @local = 0xffff;
const uint MIN_LAYER_SALT_BITS @local = 10; // mirrors dtTileCache::init's lower bound
const uint MAX_LAYER_SALT_BITS @local = 31; // mirrors init: the salt mask is computed in 32 bits
const uint MAX_LAYERS_AT @local = 32; // mirrors MAX_TILES of queryTiles and buildNavMeshTilesAt
const uint CACHE_HASH_X @local = 0x8da6b343; // upstream's arbitrarily chosen large primes
const uint CACHE_HASH_Z @local = 0xd8163841;

<* Shape of an obstacle; mirrors ObstacleType. *>
enum ObstacleKind : char {
    CYLINDER,
    BOX,
    ORIENTED_BOX,
}

<* Lifecycle of an obstacle; mirrors ObstacleState. *>
enum ObstacleState : char {
    EMPTY,
    PROCESSING,     // queued, or its touched layers are being rebuilt with it
    PROCESSED,
    REMOVING,       // its touched layers are being rebuilt without it
}

<* What an obstacle request does; mirrors ObstacleRequestAction. *>
enum ObstacleRequestAction : char {
    ADD,
    REMOVE,
}

<* An obstacle and the cached layers it marks; mirrors dtTileCacheObstacle. *>
struct Obstacle {
    ObstacleKind                      kind;
    ObstacleState                     state;
    char                              touched_count;
    char                              pending_count;
    ushort                            salt;
    Vec3                              position;       // CYLINDER base; ORIENTED_BOX centre
    float                             radius;         // CYLINDER
    float                             height;
    Aabb                              box;            // BOX
    Vec3                              half_extents;   // ORIENTED_BOX
    float[2]                          rotation;       // ORIENTED_BOX, from yaw_rotation
    CachedLayerRef[MAX_TOUCHED_TILES] touched;
    CachedLayerRef[MAX_TOUCHED_TILES] pending;        // touched layers whose queued rebuild has not run
    Obstacle*                         next;           // free list
}

<* One cached layer blob; mirrors dtCompressedTile. *>
struct CachedLayer {
    uint         salt;
    LayerHeader* header;      // null while the slot is free
    char[]       arrays;      // heights, areas and connections after the header
    char[]       data;        // the whole blob
    TileFlags    flags;
    CachedLayer* next;        // position chain or free list
}

<* A queued obstacle addition or removal; mirrors dtTileCache::ObstacleRequest. *>
struct ObstacleRequest {
    ObstacleRequestAction action;
    ObstacleRef           ref;
}

<* Grid, capacities and hooks of a cache; mirrors dtTileCacheParams. *>
struct TileCacheDesc {
    Vec3           origin;
    float          cell_size;
    float          cell_height;
    uint           width;                      // cells per tile side, without the border
    uint           height;
    float          walkable_height;            // metres
    float          walkable_radius;
    float          walkable_climb;
    float          max_simplification_error;   // cells
    uint           max_tiles;                  // cached layers
    uint           max_obstacles;
    MeshProcessFn  mesh_process;
    void*          mesh_process_context;
    VolumeSourceFn volume_source;              // null marks no volumes
    void*          volume_source_context;
    LinkSourceFn   link_source;                // null adds no off-mesh connections
    void*          link_source_context;
    DetailMode detail_mode;
    ClearanceMode clearance_mode;
    float clearance_max_error;
    float detail_max_error;
    uint max_detail_vertices;
    uint max_detail_triangles;
    float agent_max_slope_degrees;
}

<* Cached layers, obstacles and the rebuild queue; mirrors dtTileCache. *>
struct TileCache {
    Allocator                              allocator;
    TileCacheDesc                          desc;
    uint                                   lookup_mask;         // lookup.len - 1
    CachedLayer*[]                         lookup;              // by tile position hash
    CachedLayer*                           next_free_tile;
    CachedLayer[]                          tiles;               // max_tiles
    uint                                   tile_bits;           // of a CachedLayerRef, below the salt
    uint                                   salt_bits;
    Obstacle[]                             obstacles;           // max_obstacles
    Obstacle*                              next_free_obstacle;
    ObstacleRequest[MAX_OBSTACLE_REQUESTS] requests;
    uint                                   request_count;
    CachedLayerRef[MAX_UPDATE_TILES]       update_queue;
    uint                                   update_count;
    char[]                                 scratch;             // four bytes per cell of one layer
    char[]                                 build_scratch;       // backs arena
    ArenaAllocator                         arena;               // cleared per rebuild
}

<* World bounds of the obstacle's footprint; mirrors getObstacleBounds. *>
fn Aabb Obstacle.bounds(&self) {
    switch (self.kind) {
        case CYLINDER:
            return {
                .min = { self.position.x - self.radius, self.position.y, self.position.z - self.radius },
                .max = { self.position.x + self.radius, self.position.y + self.height, self.position.z + self.radius },
            };
        case BOX:
            return self.box;
        case ORIENTED_BOX:
            float reach = OBSTACLE_BOX_REACH * math::max(self.half_extents.x, self.half_extents.z);
            Vec3 extent = { reach, self.half_extents.y, reach };
            return { .min = self.position - extent, .max = self.position + extent };
    }
}

<*
 Cache a layer blob at its header's coordinate; mirrors dtTileCache::addTile.
 @param data : "Borrowed unless flags.free_data; bounded blobs require eight-byte alignment."
 @return? c3d::INVALID_ARGUMENT, TILE_OCCUPIED, c3d::CAPACITY_EXCEEDED
*>
fn CachedLayerRef? TileCache.add_tile(&self, char[] data, TileFlags flags) {
    validate_cached_layer_blob(self, data)!;
    LayerHeader* header = (LayerHeader*)data.ptr;
    if (cached_layer_at(self, header.tile_x, header.tile_z, header.tile_layer)) return TILE_OCCUPIED~;
    if (!self.next_free_tile) return c3d::CAPACITY_EXCEEDED~;
    char[][1] candidate = { data };
    validate_precision_cache_replacement(self, {}, candidate[..])!;
    return insert_cached_layer(self, data, flags);
}

<*
 Drop a cached layer; advances its salt so every ref to it fails; mirrors dtTileCache::removeTile.
 @return "The blob, for a caller that owns it; empty when the cache freed it."
 @return? INVALID_REF
*>
fn char[]? TileCache.remove_tile(&self, CachedLayerRef ref) {
    return remove_cached_layer(self, self.tile_by_ref(ref)!);
}

fn char[] remove_cached_layer(TileCache* cache, CachedLayer* tile) @private {
    uint hash = cache_hash(tile.header.tile_x, tile.header.tile_z, cache.lookup_mask);
    CachedLayer* previous;
    for (CachedLayer* current = cache.lookup[hash]; current; current = current.next) {
        if (current != tile) {
            previous = current;
            continue;
        }
        if (previous) {
            previous.next = current.next;
        } else {
            cache.lookup[hash] = current.next;
        }
        break;
    }

    char[] data = tile.data;
    if (tile.flags.free_data) {
        alloc::free(cache.allocator, data.ptr);
        data = {};
    }
    uint salt = (tile.salt + 1) & ((1u << cache.salt_bits) - 1);
    *tile = {
        .salt = salt == 0 ? 1 : salt,
        .next = cache.next_free_tile,
    };
    cache.next_free_tile = tile;
    return data;
}

<*
 Every cached layer at the grid coordinate; mirrors getTilesAt.
 @param [out] out_refs : "Filled up to its length."
 @return "How many were written."
*>
fn usz TileCache.tiles_at(
    &self,
    int x,
    int z,
    CachedLayerRef[] out_refs,
) {
    usz count;
    for (CachedLayer* tile = self.lookup[cache_hash(x, z, self.lookup_mask)]; tile; tile = tile.next) {
        if (tile.header.tile_x != x || tile.header.tile_z != z) continue;
        if (count < out_refs.len) out_refs[count++] = cached_layer_ref(self, tile);
    }
    return count;
}

<*
 Cached layer of a ref; mirrors getTileByRef.
 @return? INVALID_REF
*>
fn CachedLayer*? TileCache.tile_by_ref(&self, CachedLayerRef ref) {
    if (!ref) return INVALID_REF~;
    uint index = (uint)ref & ((1u << self.tile_bits) - 1);
    if (index >= self.tiles.len) return INVALID_REF~;
    CachedLayer* tile = &self.tiles[index];
    if (tile.salt != (uint)ref >> self.tile_bits || !tile.header) return INVALID_REF~;
    return tile;
}

<*
 Cached layers whose walkable cells overlap the box; mirrors queryTiles.
 @param [out] out_refs : "Filled up to its length."
*>
fn QueryResult TileCache.query_tiles(&self, Aabb box, CachedLayerRef[] out_refs) {
    float tile_width = self.desc.width * self.desc.cell_size;
    float tile_depth = self.desc.height * self.desc.cell_size;
    int first_x = (int)math::floor((box.min.x - self.desc.origin.x) / tile_width);
    int last_x = (int)math::floor((box.max.x - self.desc.origin.x) / tile_width);
    int first_z = (int)math::floor((box.min.z - self.desc.origin.z) / tile_depth);
    int last_z = (int)math::floor((box.max.z - self.desc.origin.z) / tile_depth);

    QueryResult result;
    for (int z = first_z; z <= last_z; z++) {
        for (int x = first_x; x <= last_x; x++) {
            for (CachedLayer* tile = self.lookup[cache_hash(x, z, self.lookup_mask)]; tile; tile = tile.next) {
                if (tile.header.tile_x != x || tile.header.tile_z != z) continue;
                if (!overlap_bounds(box, self.tight_tile_bounds(tile.header))) continue;
                if (result.count == out_refs.len) {
                    result.truncated = true;
                    continue;
                }
                out_refs[result.count++] = cached_layer_ref(self, tile);
            }
        }
    }
    return result;
}

<*
 Queue an upright cylinder obstacle; update marks it; mirrors addObstacle.
 @param base : "Centre of the bottom disc."
 @return? c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn ObstacleRef? TileCache.add_obstacle(
    &self,
    Vec3 base,
    float radius,
    float height,
) {
    if (!detail_finite_vertex(base) || !math::is_finite(radius) || !math::is_finite(height) || radius <= 0 || height <= 0) return c3d::INVALID_ARGUMENT~;
    Obstacle candidate = { .kind = CYLINDER, .position = base, .radius = radius, .height = height };
    validate_precision_obstacle(self, &candidate)!;
    Obstacle* obstacle = take_obstacle(self, CYLINDER)!;
    obstacle.position = base;
    obstacle.radius = radius;
    obstacle.height = height;
    return obstacle_ref(self, obstacle);
}

<*
 Queue an axis-aligned box obstacle; mirrors the box addBoxObstacle.
 @param box : "World space."
 @return? c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn ObstacleRef? TileCache.add_box_obstacle(&self, Aabb box) {
    if (!detail_finite_vertex(box.min) || !detail_finite_vertex(box.max)
        || box.min.x > box.max.x || box.min.y > box.max.y || box.min.z > box.max.z) return c3d::INVALID_ARGUMENT~;
    Obstacle candidate = { .kind = BOX, .box = box };
    validate_precision_obstacle(self, &candidate)!;
    Obstacle* obstacle = take_obstacle(self, BOX)!;
    obstacle.box = box;
    return obstacle_ref(self, obstacle);
}

<*
 Queue a box obstacle turned about +Y; mirrors the oriented addBoxObstacle.
 @return? c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn ObstacleRef? TileCache.add_oriented_box_obstacle(
    &self,
    Vec3 centre,
    Vec3 half_extents,
    float yaw_radians,
) {
    if (!detail_finite_vertex(centre) || !detail_finite_vertex(half_extents) || !math::is_finite(yaw_radians)
        || half_extents.x < 0 || half_extents.y < 0 || half_extents.z < 0) return c3d::INVALID_ARGUMENT~;
    Obstacle candidate = { .kind = ORIENTED_BOX, .position = centre, .half_extents = half_extents, .rotation = yaw_rotation(yaw_radians) };
    validate_precision_obstacle(self, &candidate)!;
    Obstacle* obstacle = take_obstacle(self, ORIENTED_BOX)!;
    obstacle.position = centre;
    obstacle.half_extents = half_extents;
    obstacle.rotation = yaw_rotation(yaw_radians);
    return obstacle_ref(self, obstacle);
}

<*
 Queue the removal of an obstacle; mirrors removeObstacle.
 @return? INVALID_REF, c3d::CAPACITY_EXCEEDED
*>
fn void? TileCache.remove_obstacle(&self, ObstacleRef ref) {
    self.obstacle_by_ref(ref)!;
    if (self.request_count == MAX_OBSTACLE_REQUESTS) return c3d::CAPACITY_EXCEEDED~;
    self.requests[self.request_count++] = { .action = REMOVE, .ref = ref };
}

<*
 Live obstacle of a ref; mirrors getObstacleByRef.
 @return? INVALID_REF
*>
fn Obstacle*? TileCache.obstacle_by_ref(&self, ObstacleRef ref) {
    Obstacle* obstacle = obstacle_slot(self, ref)!;
    if (obstacle.state == EMPTY) return INVALID_REF~;
    return obstacle;
}

<*
 Apply queued obstacle requests, then rebuild up to budget queued XZ sets into the mesh.
 Invalidates every PolyRef into a rebuilt tile; requests wait while a rebuild is queued.
 @param [&inout] mesh : "Receives one TileData blob per rebuilt layer."
 @param budget : "Complete XZ sets rebuilt this call; 0 only applies requests."
 @return "Whether no request and no rebuild is left."
 @return? LAYER_CORRUPTED, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn bool? TileCache.update(&self, NavMesh* mesh, uint budget = 1) {
    if (self.update_count == 0) apply_obstacle_requests(self);

    for (uint round = 0; round < budget && self.update_count > 0; round++) {
        update_cached_group(self, mesh, 0)!;
    }
    return self.update_count == 0 && self.request_count == 0;
}

<*
 Rebuild every cached layer at the grid coordinate into the mesh now; mirrors buildNavMeshTilesAt.
 @param [&inout] mesh : "Receives one TileData blob per layer."
 @return? LAYER_CORRUPTED, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn void? TileCache.build_tiles_at(
    &self,
    int x,
    int z,
    NavMesh* mesh,
) {
    char[][MAX_TILES_AT] blobs;
    usz count;
    foreach (&tile : self.tiles) {
        if (!tile.header || tile.header.tile_x != x || tile.header.tile_z != z) continue;
        if (count == blobs.len) return c3d::CAPACITY_EXCEEDED~;
        blobs[count++] = tile.data;
    }
    replace_cached_runtime(cache: self, mesh: mesh, x: x, z: z, blobs: blobs[:count])!;
}

<*
 Rebuild the complete XZ set containing the layer, marking volumes then obstacles.
 Every previous runtime layer remains valid on failure; success replaces the complete set.
 @param [&inout] mesh : "Receives the complete runtime layer set."
 @return? INVALID_REF, LAYER_CORRUPTED, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn void? TileCache.build_tile(&self, CachedLayerRef ref, NavMesh* mesh) {
    CachedLayer* tile = self.tile_by_ref(ref)!;
    self.build_tiles_at(x: tile.header.tile_x, z: tile.header.tile_z, mesh: mesh)!;
}

fn char[]? build_cached_runtime_blob(TileCache* cache, char[] blob, NavMesh* mesh) @private {
    CachedLayer layer_tile = { .header = (LayerHeader*)blob.ptr, .data = blob };
    CachedLayer* tile = &layer_tile;
    LayerHeader* header = tile.header;
    cache.arena.clear();
    Allocator arena = &cache.arena;
    TileCacheLayer layer = read_tile_cache_layer(tile.data, cache.scratch)!;
    if (header.detail_mode == DetailMode.BOUNDED) {
        return build_precision_cache_tile(cache: cache, tile: tile, layer: &layer, mesh: mesh);
    }

    float cell_size = cache.desc.cell_size;
    float cell_height = cache.desc.cell_height;
    if (cache.desc.volume_source) {
        VolumeRecord[] volumes = cache.desc.volume_source(cache.desc.volume_source_context, header.bounds)!;
        foreach (&volume : volumes) mark_layer_volume(&layer, cell_size, cell_height, volume);
    }
    foreach (&obstacle : cache.obstacles) {
        if (obstacle.state == EMPTY || obstacle.state == REMOVING) continue;
        if (!overlap_bounds(obstacle.bounds(), cache.tight_tile_bounds(header))) continue;
        mark_layer_obstacle(&layer, cell_size, cell_height, obstacle);
    }

    uint walkable_climb = (uint)(cache.desc.walkable_climb / cell_height);
    layer.build_regions(arena, walkable_climb)!;
    LayerContourSet contours = build_tile_cache_contours(
        allocator:      arena,
        scratch:        arena,
        layer:          &layer,
        walkable_climb: walkable_climb,
        max_error:      cache.desc.max_simplification_error,
    )!;
    LayerPolyMesh poly_mesh = build_tile_cache_poly_mesh(arena, arena, &contours)!;
    TileDataParams params = {
        .tile_x          = header.tile_x,
        .tile_z          = header.tile_z,
        .tile_layer      = header.tile_layer,
        .walkable_height = cache.desc.walkable_height,
        .walkable_radius = cache.desc.walkable_radius,
        .walkable_climb  = cache.desc.walkable_climb,
    };
    if (poly_mesh.poly_count == 0) {
        return {};
    }

    char[]? packed = alloc::alloc_array_try(arena, char, (sz)layer_tile_mesh_size(&poly_mesh));
    if (catch packed) return c3d::CAPACITY_EXCEEDED~;
    pack_layer_tile_mesh(
        mesh:        &poly_mesh,
        header:      header,
        cell_size:   cell_size,
        cell_height: cell_height,
        blob:        packed,
    );
    TileMeshView view = tile_mesh_view(packed);
    if (cache.desc.mesh_process) cache.desc.mesh_process(cache.desc.mesh_process_context, view, view.areas, view.flags);
    OffMeshConnectionDesc[] connections;
    if (cache.desc.link_source) connections = cache.desc.link_source(cache.desc.link_source_context, header.bounds);
    return create_tile_blob(mesh: mesh, tile_mesh: packed, connections: connections, params: params);
}

fn void? replace_cached_runtime(
    TileCache* cache,
    NavMesh* mesh,
    int x,
    int z,
    char[][] blobs,
) @private {
    if (blobs.len > MAX_TILES_AT) return c3d::CAPACITY_EXCEEDED~;
    char[][MAX_TILES_AT] runtime;
    uint count;
    defer catch {
        foreach (blob : runtime[:count]) alloc::free(mesh.allocator, blob.ptr);
    }
    foreach (blob : blobs) {
        char[] data = build_cached_runtime_blob(cache, blob, mesh)!;
        if (data.len) runtime[count++] = data;
    }
    replace_tile_data_at(mesh: mesh, tile_x: x, tile_z: z, owned_data: runtime[:count])!;
}

fn uint? update_cached_group(TileCache* cache, NavMesh* mesh, uint queue_index) @private {
    CachedLayerRef ref = cache.update_queue[queue_index];
    CachedLayer*? found = cache.tile_by_ref(ref);
    if (catch found) {
        CachedLayerRef[1] stale = { ref };
        finish_cached_rebuild(cache, stale[..]);
        return 0;
    }
    int x = found.header.tile_x;
    int z = found.header.tile_z;
    CachedLayerRef[MAX_LAYERS_AT] refs;
    usz count = cache.tiles_at(x, z, refs[..]);
    cache.build_tiles_at(x: x, z: z, mesh: mesh)!;
    finish_cached_rebuild(cache, refs[:count]);
    return (uint)count;
}

fn void finish_cached_rebuild(TileCache* cache, CachedLayerRef[] refs) @private {
    uint kept;
    foreach (ref : cache.update_queue[:cache.update_count]) {
        if (!contains_layer_ref(refs, ref)) cache.update_queue[kept++] = ref;
    }
    cache.update_count = kept;
    foreach (ref : refs) settle_obstacles(cache, ref);
}

<*
 World bounds of the walkable cells of a layer; mirrors calcTightTileBounds.
 @param [&in] header : "Of a layer in this cache."
*>
fn Aabb TileCache.tight_tile_bounds(&self, LayerHeader* header) {
    float cell_size = self.desc.cell_size;
    Aabb bounds = header.bounds;
    return {
        .min = {
            bounds.min.x + (float)header.min_x * cell_size,
            bounds.min.y,
            bounds.min.z + (float)header.min_z * cell_size,
        },
        .max = {
            bounds.min.x + (float)(header.max_x + 1) * cell_size,
            bounds.max.y,
            bounds.min.z + (float)(header.max_z + 1) * cell_size,
        },
    };
}

<*
 Empty cache with max_tiles layer slots, max_obstacles obstacles and scratch for one rebuild; mirrors dtTileCache::init.
 @param build_scratch_bytes : "The arena one layer rebuild runs in."
 @return? c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
 @require desc.max_tiles > 0, desc.width <= 255 && desc.height <= 255
*>
fn TileCache? create_tile_cache(Allocator allocator, TileCacheDesc desc, usz build_scratch_bytes) {
    if ((uint)desc.detail_mode > (uint)DetailMode.BOUNDED) return c3d::INVALID_ARGUMENT~;
    if ((uint)desc.clearance_mode > (uint)ClearanceMode.SUB_CELL
        || (desc.clearance_mode == ClearanceMode.SUB_CELL && desc.detail_mode != DetailMode.BOUNDED)) {
        return c3d::INVALID_ARGUMENT~;
    }
    if (desc.detail_mode == DetailMode.BOUNDED) (void)detail_cache_config(desc)!;
    uint tile_bits = (uint)next_pow2(desc.max_tiles).ctz();
    uint salt_bits = math::min(MAX_LAYER_SALT_BITS, 32 - tile_bits);
    if (salt_bits < MIN_LAYER_SALT_BITS) return c3d::INVALID_ARGUMENT~;
    if (desc.max_obstacles > OBSTACLE_INDEX_MASK + 1) return c3d::INVALID_ARGUMENT~;
    uint lookup_size = math::max(next_pow2(desc.max_tiles / 4), 1u);
    TileCache cache = {
        .allocator   = allocator,
        .desc        = desc,
        .lookup_mask = lookup_size - 1,
        .tile_bits   = tile_bits,
        .salt_bits   = salt_bits,
    };
    defer catch destroy_tile_cache(&cache);

    Obstacle[]? obstacles = alloc::new_array_try(allocator, Obstacle, desc.max_obstacles);
    if (catch obstacles) return c3d::CAPACITY_EXCEEDED~;
    cache.obstacles = obstacles;
    CachedLayer[]? tiles = alloc::new_array_try(allocator, CachedLayer, desc.max_tiles);
    if (catch tiles) return c3d::CAPACITY_EXCEEDED~;
    cache.tiles = tiles;
    CachedLayer*[]? lookup = alloc::new_array_try(allocator, CachedLayer*, lookup_size);
    if (catch lookup) return c3d::CAPACITY_EXCEEDED~;
    cache.lookup = lookup;
    char[]? scratch = alloc::alloc_array_try(allocator, char, (sz)desc.width * desc.height * 4);
    if (catch scratch) return c3d::CAPACITY_EXCEEDED~;
    cache.scratch = scratch;
    char[]? build_scratch = alloc::alloc_array_try(allocator, char, (sz)build_scratch_bytes);
    if (catch build_scratch) return c3d::CAPACITY_EXCEEDED~;
    cache.build_scratch = build_scratch;
    cache.arena.init(build_scratch);

    // Pushed in reverse so the first free slots are the lowest.
    for (usz index = obstacles.len; index > 0; index--) {
        Obstacle* obstacle = &obstacles[index - 1];
        obstacle.salt = 1;
        obstacle.next = cache.next_free_obstacle;
        cache.next_free_obstacle = obstacle;
    }
    for (usz index = tiles.len; index > 0; index--) {
        CachedLayer* tile = &tiles[index - 1];
        tile.salt = 1;
        tile.next = cache.next_free_tile;
        cache.next_free_tile = tile;
    }
    return cache;
}

<*
 Free the layers that carry free_data, the tables and the scratch.
 @param [&inout] cache : "Left zeroed."
*>
fn void destroy_tile_cache(TileCache* cache) {
    foreach (&tile : cache.tiles) {
        if (tile.header && tile.flags.free_data) alloc::free(cache.allocator, tile.data.ptr);
    }
    alloc::free(cache.allocator, cache.obstacles.ptr);
    alloc::free(cache.allocator, cache.tiles.ptr);
    alloc::free(cache.allocator, cache.lookup.ptr);
    alloc::free(cache.allocator, cache.scratch.ptr);
    alloc::free(cache.allocator, cache.build_scratch.ptr);
    *cache = {};
}

// Obstacle footprints and layer bounds are world space; layer arrays are cell-relative.
fn void shift_tile_cache(TileCache* cache, Vec3 offset) @private {
    cache.desc.origin -= offset;
    foreach (&tile : cache.tiles) {
        if (tile.header) {
            shift_bounds(&tile.header.bounds, offset);
            if (tile.header.detail_mode == DetailMode.BOUNDED) shift_cached_detail_reference(tile.data, offset);
        }
    }
    foreach (&obstacle : cache.obstacles) {
        if (obstacle.state == EMPTY) continue;
        obstacle.position -= offset;
        shift_bounds(&obstacle.box, offset);
    }
}

// CAPACITY_EXCEEDED when the queue is full and lacks the layer.
fn void? queue_rebuild(TileCache* cache, CachedLayerRef ref) @private {
    if (contains_layer_ref(cache.update_queue[:cache.update_count], ref)) return;
    if (cache.update_count == MAX_UPDATE_TILES) return c3d::CAPACITY_EXCEEDED~;
    cache.update_queue[cache.update_count++] = ref;
}

// A replaced layer takes a new ref, so live obstacles over its tile look up the layers they touch again.
fn void retouch_obstacles(TileCache* cache, Aabb bounds) @private {
    foreach (&obstacle : cache.obstacles) {
        if (obstacle.state != PROCESSING && obstacle.state != PROCESSED) continue;
        Aabb footprint = precision_obstacle_bounds(cache, obstacle);
        if (footprint.max.x < bounds.min.x || footprint.min.x > bounds.max.x) continue;
        if (footprint.max.z < bounds.min.z || footprint.min.z > bounds.max.z) continue;
        obstacle.touched_count = (char)query_obstacle_tiles(cache, obstacle, obstacle.touched[..]).count;
    }
}

fn void? validate_cached_layer_blob(TileCache* cache, char[] data) @private {
    if (data.len < LayerHeader::size || (uptr)data.ptr % LayerHeader::alignment != 0) return c3d::INVALID_ARGUMENT~;
    LayerHeader* header = (LayerHeader*)data.ptr;
    if (header.magic != LAYER_MAGIC || header.version != LAYER_VERSION
        || header.width == 0 || header.height == 0 || header.width > cache.desc.width || header.height > cache.desc.height
        || header.detail_mode != cache.desc.detail_mode || !detail_finite_vertex(header.bounds.min)
        || !detail_finite_vertex(header.bounds.max) || header.hmin > header.hmax) return c3d::INVALID_ARGUMENT~;
    if (catch excuse = read_tile_cache_layer(data, cache.scratch)) return c3d::INVALID_ARGUMENT~;
    if (header.detail_mode == DetailMode.BOUNDED) {
        DetailReference? reference = cached_detail_reference(data);
        if (catch reference) return c3d::INVALID_ARGUMENT~;
        if (reference.cell_size != cache.desc.cell_size || reference.cell_height != cache.desc.cell_height
            || reference.width - reference.border_size * 2 != cache.desc.width
            || reference.height - reference.border_size * 2 != cache.desc.height) return c3d::INVALID_ARGUMENT~;
    }
}

fn CachedLayerRef insert_cached_layer(TileCache* cache, char[] data, TileFlags flags) @private {
    LayerHeader* header = (LayerHeader*)data.ptr;
    CachedLayer* tile = cache.next_free_tile;
    cache.next_free_tile = tile.next;
    uint hash = cache_hash(header.tile_x, header.tile_z, cache.lookup_mask);
    tile.next = cache.lookup[hash];
    cache.lookup[hash] = tile;
    tile.header = header;
    tile.data = data;
    tile.arrays = data[LayerHeader::size..];
    tile.flags = flags;
    return cached_layer_ref(cache, tile);
}

fn void? validate_precision_cache_replacement(
    TileCache* cache,
    CachedLayerRef[] old_refs,
    char[][] new_blobs,
) @private {
    if (cache.desc.detail_mode != DetailMode.BOUNDED) return;
    foreach (&obstacle : cache.obstacles) {
        if (obstacle.state == EMPTY || obstacle.state == REMOVING) continue;
        uint count;
        foreach (&tile : cache.tiles) {
            if (!tile.header || contains_layer_ref(old_refs, cached_layer_ref(cache, tile))) continue;
            if (precision_obstacle_affects(cache, obstacle, tile.header)) count++;
        }
        foreach (blob : new_blobs) {
            if (precision_obstacle_affects(cache, obstacle, (LayerHeader*)blob.ptr)) count++;
        }
        if (count > MAX_TOUCHED_TILES) return c3d::CAPACITY_EXCEEDED~;
    }
}

fn Aabb precision_obstacle_bounds(TileCache* cache, Obstacle* obstacle) @local {
    Aabb box = obstacle.bounds();
    if (cache.desc.detail_mode == DetailMode.BOUNDED) {
        float halo = ((float)math::ceil(cache.desc.walkable_radius / cache.desc.cell_size) + BORDER_PADDING) * cache.desc.cell_size;
        if (cache.desc.clearance_mode == ClearanceMode.SUB_CELL) {
            double radius = (double)cache.desc.walkable_radius + (double)cache.desc.clearance_max_error / 8;
            halo = (float)((math::ceil(radius / cache.desc.cell_size) + BORDER_PADDING) * cache.desc.cell_size);
        }
        box.min -= { halo, cache.desc.walkable_height, halo };
        box.max += { halo, 0, halo };
    }
    return box;
}

fn bool precision_obstacle_affects(TileCache* cache, Obstacle* obstacle, LayerHeader* header) @local {
    if (header.min_x > header.max_x || header.min_z > header.max_z) return false;
    return overlap_bounds(precision_obstacle_bounds(cache, obstacle), cache.tight_tile_bounds(header));
}

fn QueryResult query_obstacle_tiles(TileCache* cache, Obstacle* obstacle, CachedLayerRef[] output) @local {
    if (cache.desc.detail_mode != DetailMode.BOUNDED) return cache.query_tiles(obstacle.bounds(), output);
    QueryResult result;
    foreach (&tile : cache.tiles) {
        if (!tile.header || !precision_obstacle_affects(cache, obstacle, tile.header)) continue;
        if (result.count == output.len) {
            result.truncated = true;
            continue;
        }
        output[result.count++] = cached_layer_ref(cache, tile);
    }
    return result;
}

fn void? validate_precision_obstacle(TileCache* cache, Obstacle* obstacle) @local {
    Aabb box = obstacle.bounds();
    if (!detail_finite_vertex(box.min) || !detail_finite_vertex(box.max)) return c3d::INVALID_ARGUMENT~;
    if (cache.desc.detail_mode != DetailMode.BOUNDED) return;
    CachedLayerRef[MAX_TOUCHED_TILES] touched;
    if (query_obstacle_tiles(cache, obstacle, touched[..]).truncated) return c3d::CAPACITY_EXCEEDED~;
}

fn uint cache_hash(int x, int z, uint mask) @local => (CACHE_HASH_X * (uint)x + CACHE_HASH_Z * (uint)z) & mask;

fn CachedLayer* cached_layer_at(
    TileCache* cache,
    int x,
    int z,
    int layer,
) @local {
    for (CachedLayer* tile = cache.lookup[cache_hash(x, z, cache.lookup_mask)]; tile; tile = tile.next) {
        LayerHeader* header = tile.header;
        if (header.tile_x == x && header.tile_z == z && header.tile_layer == layer) return tile;
    }
    return null;
}

fn CachedLayerRef cached_layer_ref(TileCache* cache, CachedLayer* tile) @local {
    return (CachedLayerRef)(tile.salt << cache.tile_bits | (uint)(tile - cache.tiles.ptr));
}

fn ObstacleRef obstacle_ref(TileCache* cache, Obstacle* obstacle) @local {
    return (ObstacleRef)((uint)obstacle.salt << OBSTACLE_SALT_BITS | (uint)(obstacle - cache.obstacles.ptr));
}

// The slot at the ref's index when its salt matches, whatever its state.
fn Obstacle*? obstacle_slot(TileCache* cache, ObstacleRef ref) @local {
    uint index = (uint)ref & OBSTACLE_INDEX_MASK;
    if (!ref || index >= cache.obstacles.len) return INVALID_REF~;
    Obstacle* obstacle = &cache.obstacles[index];
    if (obstacle.salt != (uint)ref >> OBSTACLE_SALT_BITS) return INVALID_REF~;
    return obstacle;
}

// The request is queued before the shape is written; update reads it later.
fn Obstacle*? take_obstacle(TileCache* cache, ObstacleKind kind) @local {
    if (cache.request_count == MAX_OBSTACLE_REQUESTS) return c3d::CAPACITY_EXCEEDED~;
    Obstacle* obstacle = cache.next_free_obstacle;
    if (!obstacle) return c3d::CAPACITY_EXCEEDED~;
    cache.next_free_obstacle = obstacle.next;
    ushort salt = obstacle.salt;
    *obstacle = { .kind = kind, .state = PROCESSING, .salt = salt };
    cache.requests[cache.request_count++] = { .action = ADD, .ref = obstacle_ref(cache, obstacle) };
    return obstacle;
}

// Upstream drops the tiles past a full update list; a request that may not fit waits for the next drain.
fn void apply_obstacle_requests(TileCache* cache) @private {
    uint applied;
    for (; applied < cache.request_count; applied++) {
        if (cache.update_count + MAX_TOUCHED_TILES > MAX_UPDATE_TILES) break;
        ObstacleRequest request = cache.requests[applied];
        Obstacle*? found = obstacle_slot(cache, request.ref);
        if (catch found) continue;
        Obstacle* obstacle = found;
        switch (request.action) {
            case ADD:
                QueryResult touched = query_obstacle_tiles(cache, obstacle, obstacle.touched[..]);
                obstacle.touched_count = (char)touched.count;
            case REMOVE:
                obstacle.state = REMOVING;
        }
        obstacle.pending_count = 0;
        foreach (ref : obstacle.touched[:obstacle.touched_count]) {
            (void)queue_rebuild(cache, ref);
            obstacle.pending[obstacle.pending_count++] = ref;
        }
        // Upstream settles an obstacle only as a rebuild completes, so one touching nothing never would.
        if (obstacle.pending_count == 0) finish_obstacle(cache, obstacle);
    }
    for (uint slot = applied; slot < cache.request_count; slot++) cache.requests[slot - applied] = cache.requests[slot];
    cache.request_count -= applied;
}

fn void settle_obstacles(TileCache* cache, CachedLayerRef ref) @local {
    foreach (&obstacle : cache.obstacles) {
        if (obstacle.state != PROCESSING && obstacle.state != REMOVING) continue;
        for (int slot = 0; slot < obstacle.pending_count; slot++) {
            if (obstacle.pending[slot] != ref) continue;
            obstacle.pending[slot] = obstacle.pending[obstacle.pending_count - 1];
            obstacle.pending_count--;
            if (obstacle.pending_count == 0) finish_obstacle(cache, obstacle);
            break;
        }
    }
}

fn void finish_obstacle(TileCache* cache, Obstacle* obstacle) @local {
    if (obstacle.state == PROCESSING) {
        obstacle.state = PROCESSED;
        return;
    }
    ushort salt = (ushort)((obstacle.salt + 1) & OBSTACLE_INDEX_MASK);
    *obstacle = {
        .state = EMPTY,
        .salt  = salt == 0 ? 1 : salt,
        .next  = cache.next_free_obstacle,
    };
    cache.next_free_obstacle = obstacle;
}

fn bool contains_layer_ref(CachedLayerRef[] refs, CachedLayerRef ref) @local {
    foreach (candidate : refs) {
        if (candidate == ref) return true;
    }
    return false;
}

fn void mark_layer_volume(
    TileCacheLayer* layer,
    float cell_size,
    float cell_height,
    VolumeRecord* volume,
) @local {
    Vec3 origin = layer.header.bounds.min;
    switch (volume.kind) {
        case BOX:
            layer.mark_box_area(
                origin:      origin,
                cell_size:   cell_size,
                cell_height: cell_height,
                box:         volume.box,
                area:        volume.area,
            );
        case CONVEX:
            layer.mark_convex_poly_area(
                origin:      origin,
                cell_size:   cell_size,
                cell_height: cell_height,
                vertices:    volume.verts[:volume.vert_count],
                min_y:       volume.min_y,
                max_y:       volume.max_y,
                area:        volume.area,
            );
        case CYLINDER:
            layer.mark_cylinder_area(
                origin:      origin,
                cell_size:   cell_size,
                cell_height: cell_height,
                base:        volume.base,
                radius:      volume.radius,
                height:      volume.height,
                area:        volume.area,
            );
    }
}

fn void mark_layer_obstacle(
    TileCacheLayer* layer,
    float cell_size,
    float cell_height,
    Obstacle* obstacle,
) @local {
    Vec3 origin = layer.header.bounds.min;
    switch (obstacle.kind) {
        case CYLINDER:
            layer.mark_cylinder_area(
                origin:      origin,
                cell_size:   cell_size,
                cell_height: cell_height,
                base:        obstacle.position,
                radius:      obstacle.radius,
                height:      obstacle.height,
                area:        NULL_AREA,
            );
        case BOX:
            layer.mark_box_area(
                origin:      origin,
                cell_size:   cell_size,
                cell_height: cell_height,
                box:         obstacle.box,
                area:        NULL_AREA,
            );
        case ORIENTED_BOX:
            layer.mark_oriented_box_area(
                origin:       origin,
                cell_size:    cell_size,
                cell_height:  cell_height,
                centre:       obstacle.position,
                half_extents: obstacle.half_extents,
                rotation:     obstacle.rotation,
                area:         NULL_AREA,
            );
    }
}
