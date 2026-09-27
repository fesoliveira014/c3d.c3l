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

<* Nav mirror removals held between two syncs before every tile goes dirty. *>
const uint REMOVAL_QUEUE_CAPACITY = 64; // about 1.5 KiB; a bulk unload past it costs one full rebuild

const uint DEFAULT_SLOTS @local = 2; // one slot rasterizing while another builds on a worker
const usz  DEFAULT_SLOT_SCRATCH_BYTES @local = 2 * 1024 * 1024; // per slot, once; a default tile with stair and ramp peaks at 47 KiB
const uint DEFAULT_VOLUMES_PER_TILE @local = 16; // about 3 KiB of volume records per slot

<* Where a slot is in the rasterize, build, commit cycle. *>
enum JobState {
    FREE,
    RASTERIZING,    // rasterize_next has more triangles to add
    READY,          // rasterized; build_tile may run on any thread
    BUILT,          // output valid; commit reads it
    FAILED,         // build_tile faulted; commit records it and frees the slot
}

<* Stage of build_tile, named in a failure. *>
enum BuildStage {
    COMPACT,
    AREAS,          // erosion and volume marking
    REGIONS,
    CONTOURS,
    POLY_MESH,
    PACK,
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
    Heightfield    heightfield;
    char[]         scratch;           // slot_scratch_bytes, backs arena
    ArenaAllocator arena;
    VolumeRecord[] volumes;           // max_volumes_per_tile
    uint           volume_count;
    bool           volumes_overflowed;
    uint           source_cursor;     // rasterization progress across calls
    uint           triangle_cursor;
    char[]         output;            // TileMesh blob in the arena after a BUILT build; empty for no walkable span
    fault          failure;
    BuildStage     failed_stage;
}

<* Built mesh and build state of one tile coordinate. *>
struct TileRecord {
    char[] mesh;        // TileMesh blob from the builder allocator; empty when never built or nothing walkable
    uint   revision;    // advances on every accepted commit
    uint   requests;    // advances every time a slot takes the tile
    bool   dirty;
}

<* The last build that faulted. *>
struct TileFailure {
    int        tile_x;
    int        tile_z;
    fault      reason;
    BuildStage stage;
}

<* World bounds of nav mirrors removed since the last sync_sources; the remove hooks' context. *>
struct RemovalQueue {
    Aabb[REMOVAL_QUEUE_CAPACITY] bounds;
    uint                         count;
    bool                         overflowed;    // every tile goes dirty at the next sync
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
}

<* Tile grid, slots and build state of one scene's navmesh sources. *>
struct NavBuilder {
    Allocator      allocator;
    Scene*         scene;                  // carries the mirror remove hooks
    RemovalQueue*  removals;
    NavBuildConfig config;
    TileConfig     tile_config;
    Aabb           bounds;
    float          tile_world_size;        // tile_size * cell_size
    uint           tiles_x;
    uint           tiles_z;
    TileRecord[]   tiles;                  // tiles_x * tiles_z
    TileJob[]      jobs;
    uint           rasterize_budget;
    uint           dirty_count;
    uint           source_epoch;           // advances when sync_sources changes a source or a volume
    uint           skipped_sources;        // released or non-triangle geometries met since the last nav_sync
    TileFailure    last_failure;
    Entity[]       orphan_scratch;         // scene node capacity
}

<* Outcome of one nav_sync call. *>
struct NavSyncResult {
    uint built;
    uint pending;    // dirty tiles left
    uint skipped;    // sources with released or non-triangle geometry
    uint failed;     // tile builds or rasterizations that faulted; last_failure names the last build
}

<*
 Mark every tile overlapping the box dirty.
 @param box : "World space."
*>
fn void NavBuilder.mark_dirty(&self, Aabb box) {
    float border = self.tile_config.border_size * self.config.cell_size;
    Vec3 low = (box.min - self.bounds.min - { border, 0, border }) / self.tile_world_size;
    Vec3 high = (box.max - self.bounds.min + { border, 0, border }) / self.tile_world_size;
    // One tile of slack on the low side; the overlap test below is exact.
    int first_x = math::max((int)math::floor(low.x) - 1, 0);
    int first_z = math::max((int)math::floor(low.z) - 1, 0);
    int last_x = math::min((int)math::floor(high.x), (int)self.tiles_x - 1);
    int last_z = math::min((int)math::floor(high.z), (int)self.tiles_z - 1);
    for (int tile_z = first_z; tile_z <= last_z; tile_z++) {
        for (int tile_x = first_x; tile_x <= last_x; tile_x++) {
            if (!overlaps_xz(box, self.tile_bounds((uint)tile_x, (uint)tile_z))) continue;
            TileRecord* record = &self.tiles[tile_x + tile_z * (int)self.tiles_x];
            if (record.dirty) continue;
            record.dirty = true;
            self.dirty_count++;
        }
    }
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
 Copy a built mesh into its tile record and free the slot; a stale or failed build keeps the record.
 @param [&inout] job : "BUILT or FAILED; FREE afterwards."
 @return? c3d::CAPACITY_EXCEEDED
 @require job.state == JobState.BUILT || job.state == JobState.FAILED
*>
fn void? NavBuilder.commit(&self, TileJob* job) {
    TileRecord* record = tile_record(self, job);
    bool latest = job.request == record.requests;
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
}

<*
 Two slots of 2 MiB, 2048 initial spans, 16 volumes per tile, unlimited rasterization.
*>
fn NavBuilderDesc default_nav_builder_desc(Aabb bounds, NavBuildConfig config = default_nav_build_config()) {
    return {
        .config               = config,
        .bounds               = bounds,
        .slots                = DEFAULT_SLOTS,
        .slot_scratch_bytes   = DEFAULT_SLOT_SCRATCH_BYTES,
        .initial_spans        = SPAN_POOL_GROWTH,
        .max_volumes_per_tile = DEFAULT_VOLUMES_PER_TILE,
    };
}

<*
 Builder with every tile dirty and every slot free; allocates tiles, slots, pools and arenas once.
 One builder per scene: it owns the remove hooks of the nav mirrors.
 @param [&inout] scene : "Gains the mirror remove hooks; outlives the builder."
 @return? c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
 @require desc.slots > 0, scene.world.is_registered(NavSourceRuntime), scene.world.is_registered(NavVolumeRuntime)
*>
fn NavBuilder? create_nav_builder(Allocator allocator, Scene* scene, NavBuilderDesc desc) {
    TileConfig tile = tile_config(desc.config)!;
    Vec3 extent = desc.bounds.max - desc.bounds.min;
    if (extent.x <= 0 || extent.y < 0 || extent.z <= 0) return c3d::INVALID_ARGUMENT~;
    float tile_world_size = desc.config.tile_size * desc.config.cell_size;
    uint tiles_x = (uint)math::ceil(extent.x / tile_world_size);
    uint tiles_z = (uint)math::ceil(extent.z / tile_world_size);

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
    }
    scene.set_remove_hook(NavSourceRuntime, &queue_removed_source, removals);
    scene.set_remove_hook(NavVolumeRuntime, &queue_removed_volume, removals);
    return builder;
}

<*
 Clear the mirror remove hooks, then free tiles, slots and every built mesh.
 @param [&inout] builder : "Left zeroed."
*>
fn void destroy_nav_builder(NavBuilder* builder) {
    Allocator allocator = builder.allocator;
    builder.scene.set_remove_hook(NavSourceRuntime, null, null);
    builder.scene.set_remove_hook(NavVolumeRuntime, null, null);
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
    if (config.walkable_radius > 0) compact.erode_walkable_area(arena, config.walkable_radius)!;
    foreach (&volume : job.volumes[:job.volume_count]) apply_volume(&compact, volume);

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
    )!;
    if (mesh.poly_count == 0) return;

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

fn void apply_volume(CompactHeightfield* compact, VolumeRecord* volume) @local {
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

fn bool overlaps_xz(Aabb first, Aabb second) @local {
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
    queue_removal(user, ((NavVolumeRuntime*)component).bounds);
}

fn void queue_removal(RemovalQueue* removals, Aabb bounds) @local {
    if (removals.count == REMOVAL_QUEUE_CAPACITY) {
        removals.overflowed = true;
        return;
    }
    removals.bounds[removals.count++] = bounds;
}

fn void redirty(NavBuilder* builder, TileRecord* record) @private {
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
