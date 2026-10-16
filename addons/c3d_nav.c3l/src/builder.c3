module c3d::nav;

import std::math;
import c3d;
import c3d::asset;
import c3d::ecs;
import c3d::geometry;
import c3d::maths;
import c3d::scene;

<* Vertices a convex volume may have. *>
const uint MAX_VOLUME_VERTS = 12; // 144 bytes per volume record; a bevelled hexagon after offset_poly

<* Nav mirror removals of each kind held between two syncs before every tile goes dirty or relinks. *>
const uint REMOVAL_QUEUE_CAPACITY = 64; // about 5 KiB; a bulk unload past it costs one full rebuild, relayer or relink

const uint DEFAULT_SLOTS @local = 2; // one slot rasterizing while another builds on a worker
const usz  DEFAULT_SLOT_SCRATCH_BYTES @local = 2 * 1024 * 1024; // per slot, once; a default tile with stair and ramp peaks at 47 KiB, 23 KiB as layers
const uint DEFAULT_VOLUMES_PER_TILE @local = 16; // about 3 KiB of volume records per slot
const uint DEFAULT_MAX_OBSTACLES @local = 128; // mirrors RecastDemo's maxObstacles; 144 bytes per obstacle slot
const usz  DEFAULT_CACHE_SCRATCH_BYTES @local = 64 * 1024; // once per cache; a default tile with stair, ramp and obstacle peaks at 4 KiB
const usz DEFAULT_DETAIL_CACHE_SCRATCH_BYTES @local = 2 * 1024 * 1024; // fixed workspace for reference reconstruction and bounded detail
const uint DEFAULT_LAYERS_PER_TILE @local = 4; // mirrors RecastDemo's EXPECTED_LAYERS_PER_TILE; sizes the cache and the mesh
const usz  LAYER_LENGTH_BYTES @local = 8; // length and padding before an aligned layer payload
const usz  LAYER_BLOB_ALIGNMENT @local = 8;
const uint MAX_CACHED_TILE_CELLS @local = 255; // a layer header stores its width and height in bytes

<* Where a slot is in the rasterize, build, commit cycle. *>
enum JobState {
    FREE,
    RASTERIZING,    // rasterize_next has more triangles to add
    READY,          // rasterized; build_tile may run on any thread
    BUILT,          // output valid; commit reads it
    FAILED,         // build_tile faulted; commit records it and frees the slot
}

<* Stage of a tile build, named in a failure. *>
enum BuildStage {
    COMPACT,
    AREAS,          // erosion and volume marking
    LAYERS,         // heightfield layers and their blobs, with cache_layers
    REGIONS,
    CONTOURS,
    POLY_MESH,
    DETAIL,
    PACK,
    INSTALL,        // create_tile_data and add_tile in nav_sync, or a cached layer rebuild
}

<* Shape of a NavVolume. *>
enum VolumeKind {
    BOX,
    CONVEX,
    CYLINDER,
}

<* A volume in world space, copied into a slot at rasterization. *>
struct VolumeRecord {
    VolumeKind             kind;
    char                   area;
    Aabb                   box;       // BOX
    Vec3[MAX_VOLUME_VERTS] verts;     // CONVEX
    uint                   vert_count;
    float                  min_y;     // CONVEX
    float                  max_y;
    Vec3                   base;      // CYLINDER
    float                  radius;
    float                  height;
}

<* One build in flight; a self-contained value with no pointer into the scene or the store. *>
struct TileJob {
    JobState       state;
    int            tile_x;
    int            tile_z;
    uint           request;           // the tile's request count this build answers
    uint           source_epoch;      // builder epoch when rasterization began
    TileConfig     config;
    Vec3           detail_origin;
    double[2]      detail_origin_correction;
    double[2]      detail_basis;
    Heightfield    heightfield;
    char[]         scratch;           // slot_scratch_bytes, backs arena
    ArenaAllocator arena;
    VolumeRecord[] volumes;           // max_volumes_per_tile
    uint           volume_count;
    bool           volumes_overflowed;
    uint           source_cursor;     // rasterization progress across calls
    uint           triangle_cursor;
    bool           cache_layers;      // build layer blobs; volumes wait for the cache rebuild
    char[]         output;            // after a BUILT build, in the arena; empty when nothing is walkable
    fault          failure;
    BuildStage     failed_stage;
}

<* Built mesh and build state of one tile coordinate. *>
struct TileRecord {
    char[]                     mesh;           // TileMesh blob from the builder allocator; empty when never built or nothing walkable
    uint                       revision;       // advances on every published source replacement
    uint                       requests;       // advances every time a slot takes the tile
    bool                       dirty;
    bool                       relink;         // the NavMesh tile is stale; nav_sync reinstalls it
    TileRef                    ref;            // of the installed NavMesh tile; 0 when none
    bool                       relayer;        // with cache_layers: the next sync rebuilds its mesh tiles from the cache
    CachedLayerRef[MAX_LAYERS] layers;         // with cache_layers
    uint                       layer_count;
    LayerReplacement*          pending_layers; // unpublished complete cached XZ replacement
}

struct LayerReplacement @private {
    char[][MAX_LAYERS] blobs;
    uint count;
    uint request;
}

<* The last build that faulted. *>
struct TileFailure {
    int        tile_x;
    int        tile_z;
    fault      reason;
    BuildStage stage;
}

<* Nav mirrors removed since the last sync_sources; the remove hooks' context. *>
struct RemovalQueue {
    Aabb[REMOVAL_QUEUE_CAPACITY]           bounds;              // of sources
    uint                                   count;
    bool                                   overflowed;          // every tile goes dirty at the next sync
    Aabb[REMOVAL_QUEUE_CAPACITY]           volume_bounds;
    uint                                   volume_count;
    bool                                   volumes_overflowed;  // every tile goes dirty, or relayers, at the next sync
    NavLinkRuntime[REMOVAL_QUEUE_CAPACITY] links;
    uint                                   link_count;
    bool                                   links_overflowed;    // every tile relinks at the next sync
    ObstacleRef[]                          obstacles;           // max_obstacles with cache_layers; one mirror holds each
    uint                                   obstacle_count;
}

// What the cache's volume and link hooks read; on the heap so the builder value can move.
struct CacheSources @private {
    Scene*                  scene;
    VolumeRecord[]          volumes;    // max_volumes_per_tile
    OffMeshConnectionDesc[] links;      // scene node capacity; a node carries at most one link
}

<* Capacities and configuration of a builder. *>
struct NavBuilderDesc {
    NavBuildConfig config;
    Aabb           bounds;                 // world; tiles cover it
    uint           slots;                  // builds in flight at once
    usz            slot_scratch_bytes;
    uint           initial_spans;          // per slot pool
    uint           max_volumes_per_tile;
    uint           rasterize_budget;       // triangles per rasterize_next call; 0 is unlimited
    bool           cache_layers;           // build layers into a TileCache instead of TileMesh blobs
    uint           max_obstacles;          // TileCache capacity with cache_layers
    usz            cache_scratch_bytes;    // the arena of one cached layer rebuild
    uint           expected_layers_per_tile; // cache pool; more layers fault in commit, the tile retries
}

<* Tile grid, slots and build state of one scene's navmesh sources. *>
struct NavBuilder {
    Allocator      allocator;
    Scene*         scene;                  // carries the mirror remove hooks
    RemovalQueue*  removals;
    NavBuildConfig config;
    TileConfig     tile_config;
    Aabb           bounds;
    double[2]      origin_correction;
    float          tile_world_size;        // tile_size * cell_size
    uint           tiles_x;
    uint           tiles_z;
    TileRecord[]   tiles;                  // tiles_x * tiles_z
    TileJob[]      jobs;
    uint           rasterize_budget;
    uint           dirty_count;
    uint           source_epoch;           // advances when sync_sources changes a source or a volume
    uint           skipped_sources;        // released or non-triangle geometries and ignored obstacles since the last nav_sync
    TileFailure    last_failure;
    Entity[]       orphan_scratch;         // scene node capacity
    bool           cache_layers;
    uint           expected_layers_per_tile;
    TileCache      cache;                  // valid with cache_layers
    CacheSources*  cache_sources;
}

<* Outcome of one nav_sync call. *>
struct NavSyncResult {
    uint built;
    uint installed;  // tiles added to the mesh, relinks included
    uint pending;    // dirty tiles and unpublished cached source products
    uint skipped;    // sources with released or non-triangle geometry, obstacles on a builder without cache_layers
    uint failed;     // tile builds, installs, rebuilds or rasterizations that faulted; last_failure names the last tile
    uint relayered;  // cached layers rebuilt into the mesh
}

<*
 Move the build bounds, tile records, cached layers, obstacles, queued removals and pending jobs by the negated offset.
 @param [&inout] self : "No slot is building on another thread; join tile builds first."
 @require offset.y == 0
*>
fn void NavBuilder.shift_origin(&self, Vec3 offset) {
    shift_detail_origin(&self.bounds.min, &self.origin_correction, offset);
    self.bounds.max -= offset;
    foreach (&record : self.tiles) {
        if (record.mesh.len) {
            TileMeshHeader* header = (TileMeshHeader*)record.mesh.ptr;
            shift_bounds(&header.bounds, offset);
            if (header.detail_mode == DetailMode.BOUNDED) shift_detail_origin(&header.detail_origin, &header.detail_origin_correction, offset);
        }
        if (record.pending_layers) {
            foreach (blob : record.pending_layers.blobs[:record.pending_layers.count]) {
                LayerHeader* header = (LayerHeader*)blob.ptr;
                shift_bounds(&header.bounds, offset);
                if (header.detail_mode == DetailMode.BOUNDED) shift_cached_detail_reference(blob, offset);
            }
        }
    }
    foreach (&job : self.jobs) {
        if (job.state == FREE) continue;
        shift_bounds(&job.heightfield.bounds, offset);
        shift_detail_origin(&job.detail_origin, &job.detail_origin_correction, offset);
        job.detail_basis[0] -= offset.x;
        job.detail_basis[1] -= offset.z;
        foreach (&volume : job.volumes[:job.volume_count]) shift_volume(volume, offset);
        if (job.state == BUILT) shift_job_output(job, offset);
    }

    RemovalQueue* removals = self.removals;
    foreach (&bounds : removals.bounds[:removals.count]) shift_bounds(bounds, offset);
    foreach (&bounds : removals.volume_bounds[:removals.volume_count]) shift_bounds(bounds, offset);
    foreach (&link : removals.links[:removals.link_count]) {
        link.start -= offset;
        link.end -= offset;
    }

    if (self.cache_layers) shift_tile_cache(&self.cache, offset);
}

<*
 Mark every tile overlapping the box dirty.
 @param box : "World space."
*>
fn void NavBuilder.mark_dirty(&self, Aabb box) {
    @each_tile_overlapping(self, box; TileRecord* record) {
        redirty(self, record);
    };
}

<*
 World bounds of a tile, border included.
 @require tile_x < self.tiles_x, tile_z < self.tiles_z
*>
fn Aabb NavBuilder.tile_bounds(&self, uint tile_x, uint tile_z) {
    float border = self.tile_config.border_size * self.config.cell_size;
    Aabb bounds = {
        .min = {
            self.bounds.min.x + (float)tile_x * self.tile_world_size,
            self.bounds.min.y,
            self.bounds.min.z + (float)tile_z * self.tile_world_size,
        },
        .max = {
            self.bounds.min.x + (float)(tile_x + 1) * self.tile_world_size,
            self.bounds.max.y,
            self.bounds.min.z + (float)(tile_z + 1) * self.tile_world_size,
        },
    };
    bounds.min.x -= border;
    bounds.min.z -= border;
    bounds.max.x += border;
    bounds.max.z += border;
    return bounds;
}

<*
 Built mesh of a tile; empty when never built or nothing is walkable.
 @require tile_x < self.tiles_x, tile_z < self.tiles_z
*>
fn char[] NavBuilder.tile_mesh(&self, uint tile_x, uint tile_z) => self.tiles[tile_x + tile_z * self.tiles_x].mesh;

<*
 Rasterize the next dirty tile into a free slot on the calling thread; a slot left RASTERIZING continues first.
 Reads the scene and the store; returns the slot READY, or RASTERIZING when the triangle budget ran out.
 @param [&in] scene : "World matrices as left by the last update_world; sync_sources ran since the last change."
 @param [&in] assets : "Geometry arrays are read, never kept."
 @return? NO_DIRTY_TILES, NO_FREE_SLOT, c3d::CAPACITY_EXCEEDED
*>
fn TileJob*? NavBuilder.rasterize_next(&self, Scene* scene, AssetStore* assets) {
    foreach (&job : self.jobs) {
        if (job.state != RASTERIZING) continue;
        if (job.source_epoch != self.source_epoch) {
            if (tile_record(self, job).dirty) take_tile(self, job);
            begin_rasterization(self, job, scene);
        }
        continue_rasterization(
            builder: self,
            job:     job,
            scene:   scene,
            assets:  assets,
        )!;
        return job;
    }
    if (self.dirty_count == 0) return NO_DIRTY_TILES~;

    foreach (&job : self.jobs) {
        if (job.state != FREE) continue;
        foreach (index, record : self.tiles) {
            if (!record.dirty) continue;
            job.tile_x = (int)(index % self.tiles_x);
            job.tile_z = (int)(index / self.tiles_x);
            break;
        }
        take_tile(self, job);
        begin_rasterization(self, job, scene);
        continue_rasterization(
            builder: self,
            job:     job,
            scene:   scene,
            assets:  assets,
        )!;
        return job;
    }
    return NO_FREE_SLOT~;
}

<*
 Copy a built mesh, or stage a complete cached layer set, and free the slot.
 Cached layers and their revision publish together with the runtime set in nav_sync.
 A stale or failed build keeps the record.
 @param [&inout] job : "BUILT or FAILED; FREE afterwards."
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT, TILE_OCCUPIED
 @require job.state == JobState.BUILT || job.state == JobState.FAILED
*>
fn void? NavBuilder.commit(&self, TileJob* job) {
    TileRecord* record = tile_record(self, job);
    bool latest = job.request == record.requests && !record.dirty;
    JobState state = job.state;
    job.state = FREE;
    if (state == FAILED) {
        self.last_failure = {
            .tile_x = job.tile_x,
            .tile_z = job.tile_z,
            .reason = job.failure,
            .stage  = job.failed_stage,
        };
        if (latest) redirty(self, record);
        return;
    }
    if (!latest) return;
    if (self.cache_layers) return commit_layers(self, record, job);

    char[] mesh;
    if (job.output.len) {
        char[]? copy = alloc::alloc_array_try(self.allocator, char, job.output.len);
        if (catch copy) {
            redirty(self, record);
            return c3d::CAPACITY_EXCEEDED~;
        }
        copy[..] = job.output[..];
        mesh = copy;
    }
    alloc::free(self.allocator, record.mesh.ptr);
    record.mesh = mesh;
    record.revision++;
    record.relink = true;
}

<*
 Two slots of 2 MiB, 2048 initial spans, 16 volumes per tile, unlimited rasterization, no layer cache.
 Setting cache_layers uses 128 obstacles, 64 KiB of rebuild scratch and 4 layers per tile.
*>
fn NavBuilderDesc default_nav_builder_desc(Aabb bounds, NavBuildConfig config = default_nav_build_config()) {
    return {
        .config                   = config,
        .bounds                   = bounds,
        .slots                    = DEFAULT_SLOTS,
        .slot_scratch_bytes       = DEFAULT_SLOT_SCRATCH_BYTES,
        .initial_spans            = SPAN_POOL_GROWTH,
        .max_volumes_per_tile     = DEFAULT_VOLUMES_PER_TILE,
        .max_obstacles            = DEFAULT_MAX_OBSTACLES,
        .cache_scratch_bytes      = config.detail_mode == DetailMode.BOUNDED ? DEFAULT_DETAIL_CACHE_SCRATCH_BYTES : DEFAULT_CACHE_SCRATCH_BYTES,
        .expected_layers_per_tile = DEFAULT_LAYERS_PER_TILE,
    };
}

<*
 Builder with every tile dirty and every slot free; allocates tiles, slots, pools and arenas once.
 One builder per scene: it owns the remove hooks of the nav mirrors.
 @param [&inout] scene : "Gains the mirror remove hooks; outlives the builder."
 @return? c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
 @require desc.slots > 0, scene.world.is_registered(NavSourceRuntime), scene.world.is_registered(NavVolumeRuntime)
 @require scene.world.is_registered(NavLinkRuntime), scene.world.is_registered(NavObstacleRuntime)
 @require !desc.cache_layers || desc.expected_layers_per_tile > 0
*>
fn NavBuilder? create_nav_builder(Allocator allocator, Scene* scene, NavBuilderDesc desc) {
    TileConfig tile = tile_config(desc.config)!;
    if (!detail_finite_vertex(desc.bounds.min) || !detail_finite_vertex(desc.bounds.max)) return c3d::INVALID_ARGUMENT~;
    Vec3 extent = desc.bounds.max - desc.bounds.min;
    if (!detail_finite_vertex(extent) || extent.x <= 0 || extent.y < 0 || extent.z <= 0) return c3d::INVALID_ARGUMENT~;
    if (desc.cache_layers && tile.width > MAX_CACHED_TILE_CELLS) return c3d::INVALID_ARGUMENT~;
    float tile_world_size = desc.config.tile_size * desc.config.cell_size;
    if (!math::is_finite(tile_world_size) || tile_world_size <= 0
        || (double)extent.x / tile_world_size > uint::max || (double)extent.z / tile_world_size > uint::max) return c3d::INVALID_ARGUMENT~;
    uint tiles_x = (uint)math::ceil(extent.x / tile_world_size);
    uint tiles_z = (uint)math::ceil(extent.z / tile_world_size);
    if ((ulong)tiles_x * tiles_z > uint::max) return c3d::INVALID_ARGUMENT~;

    NavBuilder builder = {
        .allocator        = allocator,
        .scene            = scene,
        .config           = desc.config,
        .tile_config      = tile,
        .bounds           = desc.bounds,
        .tile_world_size  = tile_world_size,
        .tiles_x          = tiles_x,
        .tiles_z          = tiles_z,
        .rasterize_budget = desc.rasterize_budget,
        .dirty_count      = tiles_x * tiles_z,
        .cache_layers     = desc.cache_layers,
    };
    defer catch destroy_nav_builder(&builder);

    TileRecord[]? tiles = alloc::new_array_try(allocator, TileRecord, (sz)tiles_x * tiles_z);
    if (catch tiles) return c3d::CAPACITY_EXCEEDED~;
    builder.tiles = tiles;
    foreach (&record : tiles) record.dirty = true;
    TileJob[]? jobs = alloc::new_array_try(allocator, TileJob, desc.slots);
    if (catch jobs) return c3d::CAPACITY_EXCEEDED~;
    builder.jobs = jobs;
    Entity[]? orphans = alloc::new_array_try(allocator, Entity, scene.nodes.len);
    if (catch orphans) return c3d::CAPACITY_EXCEEDED~;
    builder.orphan_scratch = orphans;
    RemovalQueue*? removals = alloc::new_try(allocator, RemovalQueue);
    if (catch removals) return c3d::CAPACITY_EXCEEDED~;
    builder.removals = removals;
    if (desc.cache_layers) create_layer_cache(&builder, scene, desc)!;

    foreach (&job : jobs) {
        job.config = tile;
        job.heightfield = create_heightfield(
            allocator:     allocator,
            width:         tile.width,
            height:        tile.height,
            bounds:        builder.tile_bounds(0, 0),
            cell_size:     tile.cell_size,
            cell_height:   tile.cell_height,
            initial_spans: desc.initial_spans,
        )!;
        char[]? scratch = alloc::alloc_array_try(allocator, char, (sz)desc.slot_scratch_bytes);
        if (catch scratch) return c3d::CAPACITY_EXCEEDED~;
        job.scratch = scratch;
        job.arena.init(scratch);
        VolumeRecord[]? volumes = alloc::new_array_try(allocator, VolumeRecord, desc.max_volumes_per_tile);
        if (catch volumes) return c3d::CAPACITY_EXCEEDED~;
        job.volumes = volumes;
        job.cache_layers = desc.cache_layers;
    }
    scene.set_remove_hook(NavSourceRuntime, &queue_removed_source, removals);
    scene.set_remove_hook(NavVolumeRuntime, &queue_removed_volume, removals);
    scene.set_remove_hook(NavLinkRuntime, &queue_removed_link, removals);
    scene.set_remove_hook(NavObstacleRuntime, &queue_removed_obstacle, removals);
    return builder;
}

<*
 Clear the mirror remove hooks, then free tiles, slots, the layer cache and every built mesh.
 @param [&inout] builder : "Left zeroed."
*>
fn void destroy_nav_builder(NavBuilder* builder) {
    Allocator allocator = builder.allocator;
    builder.scene.set_remove_hook(NavSourceRuntime, null, null);
    builder.scene.set_remove_hook(NavVolumeRuntime, null, null);
    builder.scene.set_remove_hook(NavLinkRuntime, null, null);
    builder.scene.set_remove_hook(NavObstacleRuntime, null, null);
    if (builder.cache_layers) {
        foreach (&record : builder.tiles) discard_pending_layers(builder, record);
        destroy_tile_cache(&builder.cache);
    }
    if (builder.cache_sources) {
        alloc::free(allocator, builder.cache_sources.volumes.ptr);
        alloc::free(allocator, builder.cache_sources.links.ptr);
        alloc::free(allocator, builder.cache_sources);
    }
    if (builder.removals) alloc::free(allocator, builder.removals.obstacles.ptr);
    foreach (&record : builder.tiles) alloc::free(allocator, record.mesh.ptr);
    foreach (&job : builder.jobs) {
        destroy_heightfield(&job.heightfield);
        alloc::free(allocator, job.scratch.ptr);
        alloc::free(allocator, job.volumes.ptr);
    }
    alloc::free(allocator, builder.jobs.ptr);
    alloc::free(allocator, builder.tiles.ptr);
    alloc::free(allocator, builder.orphan_scratch.ptr);
    alloc::free(allocator, builder.removals);
    *builder = {};
}

<*
 Build the polygon mesh of a rasterized slot; touches only the slot, on any thread.
 Leaves the slot BUILT or FAILED.
 @param [&inout] job : "READY."
 @return? c3d::CAPACITY_EXCEEDED
 @require job.state == JobState.READY
*>
fn void? build_tile(TileJob* job) {
    job.arena.clear();
    job.output = {};
    BuildStage stage;
    if (catch excuse = build_stages(job, &stage)) {
        job.state = FAILED;
        job.failure = excuse;
        job.failed_stage = stage;
        return excuse~;
    }
    job.state = BUILT;
}

fn void? build_stages(TileJob* job, BuildStage* stage) @local {
    TileConfig* config = &job.config;
    Allocator arena = &job.arena;

    *stage = COMPACT;
    CompactHeightfield compact = build_compact_heightfield(
        allocator:       arena,
        heightfield:     &job.heightfield,
        walkable_height: config.walkable_height,
        walkable_climb:  config.walkable_climb,
    )!;
    if (compact.span_count == 0) return;

    *stage = AREAS;
    if (job.volumes_overflowed) return c3d::CAPACITY_EXCEEDED~;
    DetailReference reference;
    if (config.detail_mode == DetailMode.BOUNDED) {
        reference = build_detail_reference(arena, &compact, config.border_size)!;
        reference.origin = job.detail_origin;
        reference.origin_correction = job.detail_origin_correction;
        reference.basis = job.detail_basis;

        long first_x = (long)job.tile_x * (long)(config.width - 2 * config.border_size) - config.border_size;
        long first_z = (long)job.tile_z * (long)(config.height - 2 * config.border_size) - config.border_size;
        if (first_x < int::min || first_x > int::max) return c3d::CAPACITY_EXCEEDED~;
        if (first_z < int::min || first_z > int::max) return c3d::CAPACITY_EXCEEDED~;

        reference.first_x = (int)first_x;
        reference.first_z = (int)first_z;

        apply_detail_connections(&reference, &compact);
        if (config.clearance_mode == ClearanceMode.WHOLE_CELL) classify_detail_reference(&reference, &compact, config)!;
    } else if (config.walkable_radius > 0) {
        compact.erode_walkable_area(arena, config.walkable_radius)!;
    }
    if (job.cache_layers) {
        *stage = LAYERS;
        return build_layer_blobs(job, &compact, config.detail_mode == DetailMode.BOUNDED ? &reference : null);
    }

    if (config.clearance_mode == ClearanceMode.SUB_CELL) {
        *stage = DETAIL;
        ClearanceSource source = clearance_scene_source(arena, &reference, config)!;
        job.output = build_clearance_mesh(
            allocator: arena,
            source: &source,
            config: config,
            tile_x: job.tile_x,
            tile_z: job.tile_z,
            volumes: job.volumes[:job.volume_count],
        )!;

        return;
    }

    foreach (&volume : job.volumes[:job.volume_count]) apply_volume(&compact, volume);
    if (config.detail_mode == DetailMode.BOUNDED && config.walkable_radius > 0) compact.erode_walkable_area(arena, config.walkable_radius)!;

    *stage = REGIONS;
    compact.build_regions_monotone(
        scratch:           arena,
        border_size:       config.border_size,
        min_region_area:   config.min_region_area,
        merge_region_area: config.merge_region_area,
    )!;

    *stage = CONTOURS;
    ContourSet contours = build_contours(
        allocator:       arena,
        scratch:         arena,
        compact:         &compact,
        max_error:       config.max_simplification_error,
        max_edge_length: config.max_edge_length,
    )!;
    if (contours.contours.len == 0) return;

    *stage = POLY_MESH;
    PolyMesh mesh = build_poly_mesh(
        allocator:      arena,
        scratch:        arena,
        contours:       &contours,
        verts_per_poly: config.verts_per_poly,
        preserve_surface: config.detail_mode == DetailMode.BOUNDED,
    )!;
    if (mesh.poly_count == 0) return;

    if (config.detail_mode == DetailMode.BOUNDED) {
        *stage = DETAIL;
        ushort[]? regions = alloc::alloc_array_try(arena, ushort, compact.span_count);
        if (catch regions) return c3d::CAPACITY_EXCEEDED~;
        foreach (index, span : compact.spans) regions[index] = compact.areas[index] == NULL_AREA ? 0 : span.region;
        build_poly_details(
            allocator: arena,
            mesh: &mesh,
            reference: &reference,
            regions: regions,
            config: config,
        )!;
        build_detail_portals(
            allocator: arena,
            mesh: &mesh,
            reference: &reference,
            regions: regions,
            areas: compact.areas,
            capacity: config.max_detail_triangles,
        )!;
    }

    *stage = PACK;
    char[]? blob = alloc::alloc_array_try(arena, char, (sz)tile_mesh_size(&mesh));
    if (catch blob) return c3d::CAPACITY_EXCEEDED~;
    pack_tile_mesh(
        mesh:   &mesh,
        tile_x: job.tile_x,
        tile_z: job.tile_z,
        blob:   blob,
    );
    job.output = blob;
}

// Volumes wait for the cache rebuild, so changing one relayers the tile instead of rebuilding it.
fn void? build_layer_blobs(TileJob* job, CompactHeightfield* compact, DetailReference* reference = null) @local {
    Allocator arena = &job.arena;
    HeightfieldLayer[] layers = build_heightfield_layers(
        allocator:       arena,
        scratch:         arena,
        compact:         compact,
        border_size:     job.config.border_size,
        walkable_height: job.config.walkable_height,
        retain_sources: reference != null,
    )!;
    if (!layers.len) return;
    // A tile record holds MAX_LAYERS refs; islands in distinct height bands can split into more.
    if (layers.len > MAX_LAYERS) return c3d::CAPACITY_EXCEEDED~;

    usz size;
    foreach (&layer : layers) size += LAYER_LENGTH_BYTES + aligned_layer_blob_size(precision_layer_blob_size(layer, reference));
    char[]? output = alloc::alloc_array_try(arena, char, (sz)size);
    if (catch output) return c3d::CAPACITY_EXCEEDED~;
    output[..] = 0;
    usz offset;
    foreach (index, &layer : layers) {
        if (reference) {
            layer.bounds.min.x = reference.origin.x;
            layer.bounds.min.z = reference.origin.z;
            layer.bounds.max.x = (float)((double)reference.origin.x + (double)(reference.width - reference.border_size * 2) * reference.cell_size);
            layer.bounds.max.z = (float)((double)reference.origin.z + (double)(reference.height - reference.border_size * 2) * reference.cell_size);
        }
        usz blob_size = precision_layer_blob_size(layer, reference);
        *(uint*)(output.ptr + offset) = (uint)blob_size;
        pack_precision_layer(
            layer:      layer,
            tile_x:     job.tile_x,
            tile_z:     job.tile_z,
            tile_layer: (int)index,
            reference: reference,
            blob:       output[offset + LAYER_LENGTH_BYTES:blob_size],
        );
        offset += LAYER_LENGTH_BYTES + aligned_layer_blob_size(blob_size);
    }
    job.output = output;
}

fn usz aligned_layer_blob_size(usz size) @local => (size + LAYER_BLOB_ALIGNMENT - 1) / LAYER_BLOB_ALIGNMENT * LAYER_BLOB_ALIGNMENT;

// Retains the published cache until the complete replacement runtime set succeeds.
fn void? commit_layers(NavBuilder* builder, TileRecord* record, TileJob* job) @local {
    TileCache* cache = &builder.cache;
    CachedLayer*[MAX_LAYERS] resident;
    char[][MAX_LAYERS] copies;
    uint count;
    defer catch {
        foreach (copy : copies[:count]) alloc::free(cache.allocator, copy.ptr);
        redirty(builder, record);
    }
    for (uint index = 0; index < record.layer_count; index++) resident[index] = cache.tile_by_ref(record.layers[index])!;
    uint free_slots;
    for (CachedLayer* tile = cache.next_free_tile; tile; tile = tile.next) free_slots++;

    usz offset;
    while (offset < job.output.len) {
        if (job.output.len - offset < LAYER_LENGTH_BYTES) return c3d::INVALID_ARGUMENT~;
        usz size = *(uint*)(job.output.ptr + offset);
        offset += LAYER_LENGTH_BYTES;
        if (size > job.output.len - offset || aligned_layer_blob_size(size) > job.output.len - offset) return c3d::INVALID_ARGUMENT~;
        if (count == MAX_LAYERS || count == free_slots + record.layer_count) return c3d::CAPACITY_EXCEEDED~;
        char[] blob = job.output[offset:size];
        offset += aligned_layer_blob_size(size);
        validate_cached_layer_blob(cache, blob)!;
        LayerHeader* header = (LayerHeader*)blob.ptr;
        if (header.tile_x != job.tile_x || header.tile_z != job.tile_z) return c3d::INVALID_ARGUMENT~;
        foreach (copy : copies[:count]) {
            if (((LayerHeader*)copy.ptr).tile_layer == header.tile_layer) return c3d::INVALID_ARGUMENT~;
        }
        foreach (&tile : cache.tiles) {
            if (!tile.header || tile.header.tile_x != header.tile_x || tile.header.tile_z != header.tile_z
                || tile.header.tile_layer != header.tile_layer) continue;
            bool owned;
            foreach (previous : resident[:record.layer_count]) {
                if (previous == tile) owned = true;
            }
            if (!owned) return TILE_OCCUPIED~;
        }
        char[]? copy = alloc::alloc_array_try(cache.allocator, char, (sz)size);
        if (catch copy) return c3d::CAPACITY_EXCEEDED~;
        copies[count++] = copy;
        copy[..] = blob[..];
    }
    validate_precision_cache_replacement(cache, record.layers[:record.layer_count], copies[:count])!;
    LayerReplacement*? pending = alloc::new_try(cache.allocator, LayerReplacement);
    if (catch pending) return c3d::CAPACITY_EXCEEDED~;
    pending.count = count;
    pending.request = job.request;
    pending.blobs[..] = copies[..];
    discard_pending_layers(builder, record);
    record.pending_layers = pending;
}

fn void discard_pending_layers(NavBuilder* builder, TileRecord* record) @private {
    LayerReplacement* pending = record.pending_layers;
    if (!pending) return;
    foreach (blob : pending.blobs[:pending.count]) alloc::free(builder.cache.allocator, blob.ptr);
    alloc::free(builder.cache.allocator, pending);
    record.pending_layers = null;
}

fn void? create_layer_cache(NavBuilder* builder, Scene* scene, NavBuilderDesc desc) @local {
    Allocator allocator = builder.allocator;
    builder.expected_layers_per_tile = desc.expected_layers_per_tile;
    ObstacleRef[]? obstacles = alloc::new_array_try(allocator, ObstacleRef, desc.max_obstacles);
    if (catch obstacles) return c3d::CAPACITY_EXCEEDED~;
    builder.removals.obstacles = obstacles;
    CacheSources*? sources = alloc::new_try(allocator, CacheSources);
    if (catch sources) return c3d::CAPACITY_EXCEEDED~;
    builder.cache_sources = sources;
    sources.scene = scene;
    VolumeRecord[]? volumes = alloc::new_array_try(allocator, VolumeRecord, desc.max_volumes_per_tile);
    if (catch volumes) return c3d::CAPACITY_EXCEEDED~;
    sources.volumes = volumes;
    OffMeshConnectionDesc[]? links = alloc::new_array_try(allocator, OffMeshConnectionDesc, scene.nodes.len);
    if (catch links) return c3d::CAPACITY_EXCEEDED~;
    sources.links = links;

    NavBuildConfig config = desc.config;
    builder.cache = create_tile_cache(
        allocator:           allocator,
        desc:                {
            .origin                   = desc.bounds.min,
            .cell_size                = config.cell_size,
            .cell_height              = config.cell_height,
            .width                    = config.tile_size,
            .height                   = config.tile_size,
            .walkable_height          = config.agent_height,
            .walkable_radius          = config.agent_radius,
            .walkable_climb           = config.agent_max_climb,
            .max_simplification_error = config.edge_max_error,
            .max_tiles                = builder.tiles_x * builder.tiles_z * desc.expected_layers_per_tile,
            .max_obstacles            = desc.max_obstacles,
            .volume_source            = &cache_volume_source,
            .volume_source_context    = sources,
            .link_source              = &cache_link_source,
            .link_source_context      = sources,
            .detail_mode              = config.detail_mode,
            .detail_max_error         = config.detail_max_error,
            .clearance_mode           = config.clearance_mode,
            .clearance_max_error      = config.clearance_max_error,
            .max_detail_vertices      = config.max_detail_vertices,
            .max_detail_triangles     = config.max_detail_triangles,
            .agent_max_slope_degrees  = config.agent_max_slope_degrees,
        },
        build_scratch_bytes: desc.cache_scratch_bytes,
    )!;
}

fn void apply_volume(CompactHeightfield* compact, VolumeRecord* volume) @private {
    switch (volume.kind) {
        case BOX:
            compact.mark_box_area(volume.box, volume.area);
        case CONVEX:
            compact.mark_convex_poly_area(
                vertices: volume.verts[:volume.vert_count],
                min_y:    volume.min_y,
                max_y:    volume.max_y,
                area:     volume.area,
            );
        case CYLINDER:
            compact.mark_cylinder_area(
                base:   volume.base,
                radius: volume.radius,
                height: volume.height,
                area:   volume.area,
            );
    }
}

// Heights are world Y and stay.
fn void shift_volume(VolumeRecord* volume, Vec3 offset) @private {
    switch (volume.kind) {
        case BOX:
            shift_bounds(&volume.box, offset);
        case CONVEX:
            foreach (&vertex : volume.verts[:volume.vert_count]) *vertex -= offset;
        case CYLINDER:
            volume.base -= offset;
    }
}

// A built output holds a TileMesh blob, or with cache_layers a run of length-prefixed layer blobs.
fn void shift_job_output(TileJob* job, Vec3 offset) @local {
    if (!job.output.len) return;
    if (!job.cache_layers) {
        TileMeshHeader* header = (TileMeshHeader*)job.output.ptr;
        shift_bounds(&header.bounds, offset);
        if (header.detail_mode == DetailMode.BOUNDED) shift_detail_origin(&header.detail_origin, &header.detail_origin_correction, offset);
        return;
    }
    usz position;
    while (position < job.output.len) {
        usz size = *(uint*)(job.output.ptr + position);
        char[] blob = job.output[position + LAYER_LENGTH_BYTES:size];
        LayerHeader* header = (LayerHeader*)blob.ptr;
        shift_bounds(&header.bounds, offset);
        if (header.detail_mode == DetailMode.BOUNDED) shift_cached_detail_reference(blob, offset);
        position += LAYER_LENGTH_BYTES + aligned_layer_blob_size(size);
    }
}

fn bool overlaps_xz(Aabb first, Aabb second) @private {
    return first.min.x <= second.max.x && first.max.x >= second.min.x
        && first.min.z <= second.max.z && first.max.z >= second.min.z;
}

fn TileRecord* tile_record(NavBuilder* builder, TileJob* job) @local {
    return &builder.tiles[job.tile_x + job.tile_z * (int)builder.tiles_x];
}

fn void queue_removed_source(Entity entity, void* component, void* user) @local {
    queue_removal(user, ((NavSourceRuntime*)component).bounds);
}

fn void queue_removed_volume(Entity entity, void* component, void* user) @local {
    RemovalQueue* removals = user;
    if (removals.volume_count == REMOVAL_QUEUE_CAPACITY) {
        removals.volumes_overflowed = true;
        return;
    }
    removals.volume_bounds[removals.volume_count++] = ((NavVolumeRuntime*)component).bounds;
}

fn void queue_removal(RemovalQueue* removals, Aabb bounds) @local {
    if (removals.count == REMOVAL_QUEUE_CAPACITY) {
        removals.overflowed = true;
        return;
    }
    removals.bounds[removals.count++] = bounds;
}

// One mirror holds each live obstacle, so max_obstacles entries never overflow.
fn void queue_removed_obstacle(Entity entity, void* component, void* user) @local {
    RemovalQueue* removals = user;
    ObstacleRef ref = ((NavObstacleRuntime*)component).ref;
    if (ref) removals.obstacles[removals.obstacle_count++] = ref;
}

fn void queue_removed_link(Entity entity, void* component, void* user) @local {
    RemovalQueue* removals = user;
    if (removals.link_count == REMOVAL_QUEUE_CAPACITY) {
        removals.links_overflowed = true;
        return;
    }
    removals.links[removals.link_count++] = *(NavLinkRuntime*)component;
}

// The records of the tiles whose bounds, border included, overlap the box in XZ.
macro void @each_tile_overlapping(NavBuilder* builder, Aabb box; @body(TileRecord* record)) @local {
    float border = builder.tile_config.border_size * builder.config.cell_size;
    Vec3 low = (box.min - builder.bounds.min - { border, 0, border }) / builder.tile_world_size;
    Vec3 high = (box.max - builder.bounds.min + { border, 0, border }) / builder.tile_world_size;
    // One tile of slack on the low side; the overlap test below is exact.
    int first_x = math::max((int)math::floor(low.x) - 1, 0);
    int first_z = math::max((int)math::floor(low.z) - 1, 0);
    int last_x = math::min((int)math::floor(high.x), (int)builder.tiles_x - 1);
    int last_z = math::min((int)math::floor(high.z), (int)builder.tiles_z - 1);
    for (int tile_z = first_z; tile_z <= last_z; tile_z++) {
        for (int tile_x = first_x; tile_x <= last_x; tile_x++) {
            if (!overlaps_xz(box, builder.tile_bounds((uint)tile_x, (uint)tile_z))) continue;
            @body(&builder.tiles[tile_x + tile_z * (int)builder.tiles_x]);
        }
    }
}

// With cache_layers a volume change rebuilds the mesh tiles from their cached layers.
fn void relayer_tiles(NavBuilder* builder, Aabb box) @private {
    @each_tile_overlapping(builder, box; TileRecord* record) {
        record.relayer = true;
    };
}

fn void redirty(NavBuilder* builder, TileRecord* record) @private {
    if (builder.cache_layers) discard_pending_layers(builder, record);
    if (record.dirty) return;
    record.dirty = true;
    builder.dirty_count++;
}

fn void take_tile(NavBuilder* builder, TileJob* job) @local {
    TileRecord* record = tile_record(builder, job);
    record.requests++;
    job.request = record.requests;
    if (!record.dirty) return;
    record.dirty = false;
    builder.dirty_count--;
}

fn void begin_rasterization(NavBuilder* builder, TileJob* job, Scene* scene) @local {
    double tile_size = (double)builder.config.tile_size * builder.config.cell_size;
    double origin_x = (double)builder.bounds.min.x + builder.origin_correction[0] + job.tile_x * tile_size;
    double origin_z = (double)builder.bounds.min.z + builder.origin_correction[1] + job.tile_z * tile_size;
    job.detail_origin = { (float)origin_x, builder.bounds.min.y, (float)origin_z };
    job.detail_origin_correction = { origin_x - job.detail_origin.x, origin_z - job.detail_origin.z };
    job.detail_basis = {
        (double)builder.bounds.min.x + builder.origin_correction[0],
        (double)builder.bounds.min.z + builder.origin_correction[1],
    };

    job.state = RASTERIZING;
    job.source_epoch = builder.source_epoch;
    job.config = builder.tile_config;
    job.heightfield.bounds = builder.tile_bounds((uint)job.tile_x, (uint)job.tile_z);
    job.heightfield.reset();
    job.source_cursor = 0;
    job.triangle_cursor = 0;
    job.output = {};
    job.volume_count = 0;
    job.volumes_overflowed = false;
    if (builder.cache_layers) return;

    Aabb tile = job.heightfield.bounds;
    scene.@each(NavVolumeRuntime; entity, runtime) {
        if (overlaps_xz(runtime.bounds, tile)) {
            if (job.volume_count == job.volumes.len) {
                job.volumes_overflowed = true;
            } else {
                job.volumes[job.volume_count++] = runtime.record;
            }
        }
    };
}

fn void? continue_rasterization(
    NavBuilder* builder,
    TileJob* job,
    Scene* scene,
    AssetStore* assets,
) @local {
    defer catch {
        job.state = FREE;
        TileRecord* record = tile_record(builder, job);
        if (job.request == record.requests) redirty(builder, record);
    }
    bool finished = rasterize_sources(
        builder: builder,
        job:     job,
        scene:   scene,
        assets:  assets,
    )!;
    if (!finished) return;

    Heightfield* heightfield = &job.heightfield;
    heightfield.filter_low_hanging_walkable_obstacles(job.config.walkable_climb);
    heightfield.filter_ledge_spans(job.config.walkable_height, job.config.walkable_climb);
    heightfield.filter_walkable_low_height_spans(job.config.walkable_height);
    job.state = READY;
}

// False when the triangle budget ran out before the last overlapping source was done.
fn bool? rasterize_sources(
    NavBuilder* builder,
    TileJob* job,
    Scene* scene,
    AssetStore* assets,
) @local {
    uint budget = builder.rasterize_budget;
    uint added;
    uint position;
    Aabb tile = job.heightfield.bounds;
    scene.@each(NavSourceRuntime; entity, runtime) {
        uint current = position++;
        if (current >= job.source_cursor) {
            if (overlaps_xz(runtime.bounds, tile)) {
                if (budget != 0 && added == budget) return false;
                Node* node = scene.node(entity);
                NavSource* source = scene.get(node, NavSource);
                if (try asset = source_geometry(scene, assets, node)) {
                    if (asset.data.positions.len && asset.data.topology == TRIANGLES) {
                        added += rasterize_source(
                            job:       job,
                            geometry:  &asset.data,
                            world:     node.world,
                            source:    source,
                            allowance: budget == 0 ? uint::max : budget - added,
                        )!;
                        if (job.triangle_cursor != 0) return false;
                    } else {
                        builder.skipped_sources++;
                    }
                } else {
                    builder.skipped_sources++;
                }
                job.triangle_cursor = 0;
            }
            job.source_cursor = current + 1;
        }
    };
    return true;
}

fn uint? rasterize_source(
    TileJob* job,
    Geometry* geometry,
    Mat4 world,
    NavSource* source,
    uint allowance,
) @local {
    sz triangle_count = geometry.indices.len ? geometry.indices.len / 3 : geometry.positions.len / 3;
    sz first = job.triangle_cursor;
    sz last = math::min(triangle_count, first + allowance);

    @pool() {
        Vec3[] positions = alloc::new_array(tmem, Vec3, geometry.positions.len);
        foreach (index, position : geometry.positions) positions[index] = maths::transform_point(world, position);
        uint[] indices;
        if (geometry.indices.len) {
            indices = geometry.indices[first * 3:(last - first) * 3];
        } else {
            indices = alloc::new_array(tmem, uint, (last - first) * 3);
            foreach (index, &value : indices) *value = (uint)(first * 3 + index);
        }
        foreach (index : indices) {
            if (index >= positions.len || !detail_finite_vertex(positions[index])) return c3d::INVALID_ARGUMENT~;
        }
        char[] areas = alloc::new_array(tmem, char, last - first);
        if (source.walkable) {
            mark_walkable_triangles(
                slope_degrees: job.config.slope_degrees,
                positions:     positions,
                indices:       indices,
                areas:         areas,
            );
            foreach (&area : areas) {
                if (*area == WALKABLE_AREA) *area = source.area;
            }
        }
        job.heightfield.rasterize_triangles(
            positions:       positions,
            indices:         indices,
            areas:           areas,
            merge_threshold: job.config.walkable_climb,
        )!;
    };

    job.triangle_cursor = last == triangle_count ? 0 : (uint)last;
    return (uint)(last - first);
}

fn GeometryAsset*? source_geometry(Scene* scene, AssetStore* assets, Node* node) @private {
    GeometryId geometry = scene.get(node, NavSource).geometry;
    if (c3d::same_id(geometry, (GeometryId){})) {
        if (!scene.has(node, scene::Mesh)) return c3d::ASSET_DATA_UNAVAILABLE~;
        geometry = scene.get(node, scene::Mesh).geometry;
    }
    if (!assets.geometries.is_live(geometry)) return c3d::INVALID_ID~;
    return assets.geometry(geometry);
}
