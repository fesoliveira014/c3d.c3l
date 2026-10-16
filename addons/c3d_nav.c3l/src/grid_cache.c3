module c3d::nav;

import c3d;
import std::math;

<* Identify application-owned grid source contents. *>
typedef GridSourceId = ulong;

const usz GRID_CACHE_SCRATCH_BYTES @local = 4 * 1024 * 1024; // per slot or cache; captured floors and bounded reconstruction
const uint GRID_CACHE_DEFAULT_SLOTS @local = 2;
const uint GRID_CACHE_DEFAULT_LAYERS @local = 4;
const uint GRID_CACHE_DEFAULT_OBSTACLES @local = 128;
const uint GRID_CACHE_MAX_SIDE @local = 255;

<* Distinguish staged output from a superseded completed build. *>
enum GridCommitResult {
    STAGED,
    STALE,
}

<* Bound one cached grid's storage and construction. *>
struct GridCacheDesc {
    GridRange tiles;
    NavBuildConfig config;
    uint max_cached_layers;
    uint max_obstacles;
    uint build_slots;
    usz slot_scratch_bytes;
    usz cache_scratch_bytes;
}

struct GridLayerReplacement @private {
    char[][MAX_GRID_FLOORS] blobs;
    uint count;
    GridSourceId source_id;
    ulong source_revision;
    ulong request;
}

<* Retain the installed and requested state of one coordinate. *>
struct GridCacheTile {
    CachedLayerRef[MAX_GRID_FLOORS] layers;
    uint layer_count;
    GridSourceId installed_source;
    ulong installed_revision;
    ulong request;
    bool dirty;
    GridLayerReplacement* pending;
}

<* Own one detached grid capture and exclusive build workspace. *>
struct GridCacheJob {
    JobState state;
    uint coordinate;
    int tile_x;
    int tile_z;
    GridSourceId source_id;
    ulong source_revision;
    ulong request;
    GridTileBuilder builder;
    GridReference reference;
    char[][MAX_GRID_FLOORS] blobs;
    uint layer_count;
    fault failure;
}

<* Report bounded source and obstacle progress. *>
struct GridUpdateResult {
    uint attempted;
    uint built;
    uint installed;
    uint rebuilt;
    uint stale;
    uint failed;
    uint pending;
}

<* Own cached grid sources, detached jobs and obstacle state. *>
struct GridCache {
    Allocator allocator;
    GridCacheDesc desc;
    GridSourceDesc source;
    GridSourceId source_id;
    ulong source_revision;
    GridCacheTile[] tiles;
    GridCacheJob[] jobs;
    TileCache cache;
    TileFailure last_failure;
}

<*
 Select a matching runtime grid and layer capacity.
*>
fn NavMeshDesc GridCache.mesh_desc(&self) {
    float size = self.desc.config.tile_size * self.desc.config.cell_size;
    return {
        .origin = { self.source.origin.x, self.source.min_height, self.source.origin.z },
        .tile_width = size,
        .tile_height = size,
        .max_tiles = self.desc.max_cached_layers,
    };
}

<*
 Request every tile whose captured cells intersect the edit.
 @param cells : "Half-open source-cell range."
 @param revision : "Current source revision; never decreases."
 @return? c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn void? GridCache.mark_dirty(&self, GridRange cells, ulong revision) {
    if (revision < self.source_revision) return c3d::INVALID_ARGUMENT~;
    TileConfig config = tile_config(self.desc.config)!;
    GridRange affected = grid_dirty_tiles(
        cells: cells,
        tile_size: self.desc.config.tile_size,
        border_size: config.border_size,
        extent: self.desc.tiles,
    )!;
    if (revision != self.source_revision) {
        self.source_revision = revision;
        supersede_grid_jobs(self);
    }
    for (int z = affected.min_z; z < affected.max_z; z++) {
        for (int x = affected.min_x; x < affected.max_x; x++) request_grid_coordinate(self, grid_coordinate(self, x, z));
    }
}

<*
 Replace source identity and request the entire fixed grid.
 @param source : "Borrowed only during owner-thread capture."
 @return? c3d::INVALID_ARGUMENT
*>
fn void? GridCache.set_source(
    &self,
    GridSourceDesc source,
    GridSourceId identity,
    ulong revision,
) {
    if (!identity || (identity == self.source_id && revision <= self.source_revision)) return c3d::INVALID_ARGUMENT~;
    validate_grid_cache_source(source, self.desc.config)!;
    if (source.origin.x != self.source.origin.x || source.origin.z != self.source.origin.z
        || source.min_height != self.source.min_height || source.max_height != self.source.max_height) {
        return c3d::INVALID_ARGUMENT~;
    }

    self.source = source;
    self.source_id = identity;
    self.source_revision = revision;
    for (uint index = 0; index < self.tiles.len; index++) request_grid_coordinate(self, index);
}

<*
 Copy the next dirty source window into an exclusive slot.
 @return? NO_DIRTY_TILES, NO_FREE_SLOT, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn GridCacheJob*? GridCache.capture_next(&self) {
    uint coordinate = uint::max;
    foreach (index, record : self.tiles) {
        if (record.dirty) {
            coordinate = (uint)index;
            break;
        }
    }
    if (coordinate == uint::max) return NO_DIRTY_TILES~;
    GridCacheJob* job;
    foreach (&candidate : self.jobs) {
        if (candidate.state == JobState.FREE) {
            job = candidate;
            break;
        }
    }
    if (!job) return NO_FREE_SLOT~;

    uint width = (uint)((long)self.desc.tiles.max_x - self.desc.tiles.min_x);
    job.coordinate = coordinate;
    job.tile_x = (int)((long)self.desc.tiles.min_x + coordinate % width);
    job.tile_z = (int)((long)self.desc.tiles.min_z + coordinate / width);
    job.source_id = self.source_id;
    job.source_revision = self.source_revision;
    job.request = self.tiles[coordinate].request;
    job.builder.source = self.source;
    job.builder.arena.clear();
    job.layer_count = 0;
    GridReference? captured = capture_grid_reference(&job.builder, job.tile_x, job.tile_z);
    if (catch excuse = captured) {
        self.last_failure = {
            .tile_x = job.tile_x,
            .tile_z = job.tile_z,
            .reason = excuse,
            .stage = BuildStage.LAYERS,
        };
        return excuse~;
    }
    job.reference = captured;

    // Detached construction cannot call back into mutable application storage.
    job.builder.source.floors = null;
    job.builder.source.capture = null;
    job.builder.source.context = null;
    self.tiles[coordinate].dirty = false;
    job.state = JobState.READY;
    return job;
}

<*
 Stage completed source layers without changing the live mesh.
 @param [&inout] job : "Completed slot owned by this coordinator."
 @return? c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
 @require job.state == JobState.BUILT || job.state == JobState.FAILED
*>
fn GridCommitResult? GridCache.commit(&self, GridCacheJob* job) {
    GridCacheTile* record = &self.tiles[job.coordinate];
    defer job.state = JobState.FREE;
    if (job.source_id != self.source_id || job.source_revision != self.source_revision || job.request != record.request) {
        if (!record.pending && record.installed_revision != self.source_revision) record.dirty = true;
        return GridCommitResult.STALE;
    }
    if (job.state == JobState.FAILED) {
        record.dirty = true;
        self.last_failure = { .tile_x = job.tile_x, .tile_z = job.tile_z, .reason = job.failure, .stage = BuildStage.LAYERS };
        return job.failure~;
    }

    GridLayerReplacement*? pending = alloc::new_try(self.allocator, GridLayerReplacement);
    if (catch pending) {
        record.dirty = true;
        return c3d::CAPACITY_EXCEEDED~;
    }
    *pending = { .source_id = job.source_id, .source_revision = job.source_revision, .request = job.request };
    defer catch {
        free_grid_replacement(self.allocator, pending);
        record.dirty = true;
    }
    foreach (blob : job.blobs[:job.layer_count]) {
        char[]? copy = alloc::alloc_array_try(self.allocator, char, (sz)blob.len);
        if (catch copy) return c3d::CAPACITY_EXCEEDED~;
        pending.blobs[pending.count++] = copy;
        copy[..] = blob[..];
    }
    free_grid_replacement(self.allocator, record.pending);
    record.pending = pending;
    return GridCommitResult.STAGED;
}

<*
 Build and publish a bounded number of complete coordinates.
 @param [&inout] mesh : "Matching runtime mesh; owner-thread access only."
 @param budget : "Combined source and obstacle coordinate attempts."
*>
fn GridUpdateResult GridCache.update(&self, NavMesh* mesh, uint budget = 1) {
    GridUpdateResult result;
    for (uint step = 0; step < budget; step++) {
        if (catch excuse = self.cache.update(mesh, 0)) {
            self.last_failure.reason = excuse;
            result.failed++;
            break;
        }
        uint coordinate = uint::max;
        foreach (index, record : self.tiles) {
            if (record.pending) {
                coordinate = (uint)index;
                break;
            }
        }
        if (coordinate == uint::max) {
            GridCacheJob*? captured = self.capture_next();
            if (catch excuse = captured) {
                if (excuse != NO_DIRTY_TILES && excuse != NO_FREE_SLOT) {
                    self.last_failure.reason = excuse;
                    result.attempted++;
                    result.failed++;
                    break;
                }
            } else {
                result.attempted++;
                GridCacheJob* job = captured;
                coordinate = job.coordinate;
                (void)build_grid_cache_job(job);
                GridCommitResult? committed = self.commit(job);
                if (catch commit_failure = committed) {
                    self.last_failure.reason = commit_failure;
                    result.failed++;
                    break;
                }
                if (committed == GridCommitResult.STALE) {
                    result.stale++;
                    continue;
                }
                result.built++;
            }
        } else {
            result.attempted++;
        }

        if (coordinate != uint::max) {
            if (catch excuse = publish_grid_coordinate(self, mesh, coordinate)) {
                self.last_failure.reason = excuse;
                self.last_failure.stage = BuildStage.INSTALL;
                result.failed++;
                break;
            }
            result.installed++;
            continue;
        }
        if (!self.cache.update_count && !self.cache.request_count) break;
        result.attempted++;
        if (catch excuse = self.cache.update(mesh, 1)) {
            self.last_failure.reason = excuse;
            self.last_failure.stage = BuildStage.INSTALL;
            result.failed++;
            break;
        }
        result.rebuilt++;
    }
    foreach (record : self.tiles) {
        if (record.dirty || record.pending) result.pending++;
    }
    foreach (job : self.jobs) {
        if (job.state != JobState.FREE && !self.tiles[job.coordinate].dirty) result.pending++;
    }
    result.pending += self.cache.update_count + self.cache.request_count;
    return result;
}

<*
 Configure fixed cached-grid storage over a tile extent.
 @param tiles : "Half-open tile-coordinate range."
*>
fn GridCacheDesc default_grid_cache_desc(GridRange tiles, NavBuildConfig config) {
    ulong count = (ulong)((long)tiles.max_x - tiles.min_x) * (ulong)((long)tiles.max_z - tiles.min_z);
    return {
        .tiles = tiles,
        .config = config,
        .max_cached_layers = count > uint::max / GRID_CACHE_DEFAULT_LAYERS ? uint::max : (uint)count * GRID_CACHE_DEFAULT_LAYERS,
        .max_obstacles = GRID_CACHE_DEFAULT_OBSTACLES,
        .build_slots = GRID_CACHE_DEFAULT_SLOTS,
        .slot_scratch_bytes = GRID_CACHE_SCRATCH_BYTES,
        .cache_scratch_bytes = GRID_CACHE_SCRATCH_BYTES,
    };
}

<*
 Allocate a standalone cached grid with every coordinate dirty.
 @param source : "Borrowed only during owner-thread capture."
 @return? c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn GridCache? create_grid_cache(
    Allocator allocator,
    GridCacheDesc desc,
    GridSourceDesc source,
    GridSourceId identity,
    ulong revision = 0,
) {
    validate_grid_cache_source(source, desc.config)!;
    if (!identity || !desc.build_slots || !desc.max_cached_layers || desc.config.tile_size > GRID_CACHE_MAX_SIDE) {
        return c3d::INVALID_ARGUMENT~;
    }
    long width = (long)desc.tiles.max_x - desc.tiles.min_x;
    long height = (long)desc.tiles.max_z - desc.tiles.min_z;
    if (width <= 0 || height <= 0) return c3d::INVALID_ARGUMENT~;
    ulong count = (ulong)width * (ulong)height;
    if (count > uint::max || count > (ulong)sz::max / GridCacheTile::size) return c3d::CAPACITY_EXCEEDED~;

    GridCache grid = { .allocator = allocator, .desc = desc, .source = source, .source_id = identity, .source_revision = revision };
    defer catch destroy_grid_cache(&grid);
    GridCacheTile[]? tiles = alloc::new_array_try(allocator, GridCacheTile, (sz)count);
    if (catch tiles) return c3d::CAPACITY_EXCEEDED~;
    grid.tiles = tiles;
    foreach (&record : grid.tiles) {
        record.dirty = true;
        record.request = 1;
    }
    GridCacheJob[]? jobs = alloc::new_array_try(allocator, GridCacheJob, desc.build_slots);
    if (catch jobs) return c3d::CAPACITY_EXCEEDED~;
    grid.jobs = jobs;
    foreach (&job : grid.jobs) {
        job.builder = create_grid_tile_builder(
            allocator: allocator,
            config: desc.config,
            source: source,
            scratch_bytes: desc.slot_scratch_bytes,
        )!;
    }
    NavBuildConfig config = desc.config;
    grid.cache = create_tile_cache(
        allocator: allocator,
        desc: {
            .origin = { source.origin.x, source.min_height, source.origin.z },
            .cell_size = config.cell_size,
            .cell_height = config.cell_height,
            .width = config.tile_size,
            .height = config.tile_size,
            .walkable_height = config.agent_height,
            .walkable_radius = config.agent_radius,
            .walkable_climb = config.agent_max_climb,
            .max_simplification_error = config.edge_max_error,
            .max_tiles = desc.max_cached_layers,
            .max_obstacles = desc.max_obstacles,
            .detail_mode = config.detail_mode,
            .clearance_mode = config.clearance_mode,
            .clearance_max_error = config.clearance_max_error,
            .detail_max_error = config.detail_max_error,
            .max_detail_vertices = config.max_detail_vertices,
            .max_detail_triangles = config.max_detail_triangles,
            .agent_max_slope_degrees = config.agent_max_slope_degrees,
        },
        build_scratch_bytes: desc.cache_scratch_bytes,
    )!;
    return grid;
}

<*
 Release cached sources and build storage after joining jobs.
 @param [&inout] grid : "Left zeroed; installed runtime tiles remain mesh-owned."
*>
fn void destroy_grid_cache(GridCache* grid) {
    foreach (&record : grid.tiles) free_grid_replacement(grid.allocator, record.pending);
    foreach (&job : grid.jobs) destroy_grid_tile_builder(&job.builder);
    destroy_tile_cache(&grid.cache);
    alloc::free(grid.allocator, grid.jobs.ptr);
    alloc::free(grid.allocator, grid.tiles.ptr);
    *grid = {};
}

<*
 Construct retained grid layers using only a detached slot.
 @param [&inout] job : "Exclusive access until the worker completes."
 @return? c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
 @require job.state == JobState.READY
*>
fn void? build_grid_cache_job(GridCacheJob* job) {
    if (catch excuse = build_grid_cache_products(job)) {
        job.failure = excuse;
        job.state = JobState.FAILED;
        return excuse~;
    }
    job.state = JobState.BUILT;
}

fn void? build_grid_cache_products(GridCacheJob* job) @local {
    if (!job.reference.span_count) return;
    uint[MAX_GRID_FLOORS] masks;
    uint count = grid_cache_layer_masks(
        builder: &job.builder,
        reference: &job.reference,
        tile_x: job.tile_x,
        tile_z: job.tile_z,
        output: masks[..],
    )!;
    for (uint index = 0; index < count; index++) {
        job.blobs[index] = pack_grid_cache_layer(
            builder: &job.builder,
            reference: &job.reference,
            source_id: (ulong)job.source_id,
            source_revision: job.source_revision,
            tile_x: job.tile_x,
            tile_z: job.tile_z,
            layer: index,
            floor_mask: masks[index],
        )!;
    }
    job.layer_count = count;
}

fn void? publish_grid_coordinate(GridCache* grid, NavMesh* mesh, uint coordinate) @local {
    GridCacheTile* record = &grid.tiles[coordinate];
    GridLayerReplacement* pending = record.pending;
    uint width = (uint)((long)grid.desc.tiles.max_x - grid.desc.tiles.min_x);
    int x = (int)((long)grid.desc.tiles.min_x + coordinate % width);
    int z = (int)((long)grid.desc.tiles.min_z + coordinate / width);
    grid.last_failure.tile_x = x;
    grid.last_failure.tile_z = z;
    if (pending.source_id != grid.source_id || pending.source_revision != grid.source_revision || pending.request != record.request) {
        return c3d::INVALID_ARGUMENT~;
    }
    float size = grid.desc.config.tile_size * grid.desc.config.cell_size;
    Aabb bounds = {
        .min = { grid.source.origin.x + x * size, grid.source.min_height, grid.source.origin.z + z * size },
        .max = {
            (float)((double)grid.source.origin.x + ((double)x + 1) * size),
            grid.source.max_height,
            (float)((double)grid.source.origin.z + ((double)z + 1) * size),
        },
    };
    record.layer_count = publish_cached_layer_set(
        cache: &grid.cache,
        mesh: mesh,
        tile_x: x,
        tile_z: z,
        previous: record.layers[:record.layer_count],
        owned_blobs: pending.blobs[:pending.count],
        output: record.layers[..],
        bounds: bounds,
    )!;
    record.installed_source = pending.source_id;
    record.installed_revision = pending.source_revision;
    pending.count = 0;
    free_grid_replacement(grid.allocator, pending);
    record.pending = null;
}

fn void request_grid_coordinate(GridCache* grid, uint coordinate) @local {
    GridCacheTile* record = &grid.tiles[coordinate];
    free_grid_replacement(grid.allocator, record.pending);
    record.pending = null;
    record.request++;
    record.dirty = true;
}

fn void supersede_grid_jobs(GridCache* grid) @local {
    foreach (index, record : grid.tiles) {
        if (record.pending) request_grid_coordinate(grid, (uint)index);
    }
    foreach (job : grid.jobs) {
        if (job.state != JobState.FREE) request_grid_coordinate(grid, job.coordinate);
    }
}

fn void free_grid_replacement(Allocator allocator, GridLayerReplacement* pending) @local {
    if (!pending) return;
    foreach (blob : pending.blobs[:pending.count]) alloc::free(allocator, blob.ptr);
    alloc::free(allocator, pending);
}

fn uint grid_coordinate(GridCache* grid, int x, int z) @local {
    uint width = (uint)((long)grid.desc.tiles.max_x - grid.desc.tiles.min_x);
    return (uint)((long)x - grid.desc.tiles.min_x) + (uint)((long)z - grid.desc.tiles.min_z) * width;
}

fn void? validate_grid_cache_source(GridSourceDesc source, NavBuildConfig config) @local {
    if ((!source.floors && !source.capture) || (source.floors && source.capture)) return c3d::INVALID_ARGUMENT~;
    if (!detail_finite_vertex(source.origin) || !math::is_finite(source.min_height)
        || !math::is_finite(source.max_height) || source.min_height >= source.max_height) return c3d::INVALID_ARGUMENT~;
    if (source.cell_size != 0 && source.cell_size != config.cell_size) return c3d::INVALID_ARGUMENT~;
}
