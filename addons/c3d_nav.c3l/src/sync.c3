module c3d::nav;

import std::math;
import c3d;
import c3d::asset;
import c3d::ecs;
import c3d::maths;
import c3d::scene;

<*
 Apply NavSource, NavVolume, NavLink and NavObstacle additions, changes and removals to the tile grid.
 Call before rasterize_next when driving the builder by hand; nav_sync calls it.
 @param [&in] scene : "World matrices as left by the last update_world."
 @param [&in] assets : "Resolves source geometry bounds."
*>
fn void NavBuilder.sync_sources(&self, Scene* scene, AssetStore* assets) {
    remove_orphan_mirrors(self, scene);
    bool changed;

    // A source without live geometry keeps no mirror, so it is counted again on every sync until fixed.
    scene.@each(NavSource; entity, source) {
        Node* node = scene.node(entity);
        bool mirrored = scene.has(node, NavSourceRuntime);
        if (!mirrored || source.changed) {
            source.changed = false;
            if (mirrored) self.mark_dirty(scene.get(node, NavSourceRuntime).bounds);
            if (try asset = source_geometry(scene, assets, node)) {
                Aabb bounds = maths::aabb_transform(asset.data.bounds, node.world);
                self.mark_dirty(bounds);
                if (mirrored) {
                    scene.get(node, NavSourceRuntime).bounds = bounds;
                } else {
                    scene.add(node, (NavSourceRuntime){ .bounds = bounds });
                }
                changed = true;
            } else {
                self.skipped_sources++;
                if (mirrored) {
                    scene.remove_component(node, NavSourceRuntime);
                    changed = true;
                }
            }
        }
    };

    // With cached layers a volume is marked at the layer rebuild, so rasterization never restarts for one.
    scene.@each(NavVolume; entity, volume) {
        Node* node = scene.node(entity);
        bool added = !scene.has(node, NavVolumeRuntime);
        if (added || volume.changed) {
            volume.changed = false;
            if (!self.cache_layers) changed = true;
            NavVolumeRuntime runtime = world_volume(volume, node.world);
            mark_volume_tiles(self, runtime.bounds);
            if (added) {
                scene.add(node, runtime);
            } else {
                NavVolumeRuntime* mirror = scene.get(node, NavVolumeRuntime);
                mark_volume_tiles(self, mirror.bounds);
                *mirror = runtime;
            }
        }
    };

    // A link changes no rasterization input, so its tiles relink without a rebuild.
    scene.@each(NavLink; entity, link) {
        Node* node = scene.node(entity);
        bool added = !scene.has(node, NavLinkRuntime);
        if (added || link.changed) {
            link.changed = false;
            NavLinkRuntime runtime = {
                .start = maths::transform_point(node.world, link.start),
                .end   = maths::transform_point(node.world, link.end),
            };
            relink_link_tiles(self, runtime);
            if (added) {
                scene.add(node, runtime);
            } else {
                NavLinkRuntime* mirror = scene.get(node, NavLinkRuntime);
                relink_link_tiles(self, *mirror);
                *mirror = runtime;
            }
        }
    };

    scene.@each(NavObstacle; entity, obstacle) {
        if (self.cache_layers) {
            sync_obstacle(self, scene, scene.node(entity), obstacle);
        } else {
            self.skipped_sources++;
        }
    };

    if (drain_removals(self)) changed = true;
    if (drain_volume_removals(self) && !self.cache_layers) changed = true;
    drain_link_removals(self);
    if (self.cache_layers) drain_obstacle_removals(self);
    if (changed) self.source_epoch++;
}

<*
 Apply scene changes, build up to budget tiles, then install every tile marked for relink into the mesh.
 With cache_layers, rebuilds up to budget queued layers from the cache instead of installing.
 Invalidates every PolyRef into a reinstalled tile.
 @param [&inout] builder : "Owns the TileMesh blobs or the layer cache."
 @param [&inout] mesh : "The builder's one mesh, from create_nav_mesh_for; owns the installed blobs."
 @param [&in] scene : "World matrices as left by the last update_world."
 @param [&in] assets : "Geometry arrays are read, never kept."
 @param budget : "Tiles rasterized and committed, and cached layers rebuilt, this call; installs are unbudgeted."
*>
fn NavSyncResult nav_sync(
    NavBuilder* builder,
    NavMesh* mesh,
    Scene* scene,
    AssetStore* assets,
    uint budget,
) {
    builder.sync_sources(scene, assets);
    NavSyncResult result;
    for (uint round = 0; round < budget; round++) {
        TileJob*? taken = builder.rasterize_next(scene, assets);
        if (catch excuse = taken) {
            if (excuse != NO_DIRTY_TILES && excuse != NO_FREE_SLOT) result.failed++;
            break;
        }
        TileJob* job = taken;
        if (job.state == RASTERIZING) break;

        (void)build_tile(job);
        bool failed = job.state == FAILED;
        if (catch builder.commit(job)) {
            result.failed++;
            break;
        }
        if (failed) {
            result.failed++;
        } else {
            result.built++;
        }
    }

    if (builder.cache_layers) {
        rebuild_cached_layers(builder, mesh, budget, &result);
        result.pending = builder.dirty_count;
        result.skipped = builder.skipped_sources;
        builder.skipped_sources = 0;
        return result;
    }
    foreach (index, &record : builder.tiles) {
        if (!record.relink) continue;
        if (catch excuse = install_tile(builder, mesh, scene, (uint)index)) {
            builder.last_failure = {
                .tile_x = (int)(index % builder.tiles_x),
                .tile_z = (int)(index / builder.tiles_x),
                .reason = excuse,
                .stage  = INSTALL,
            };
            result.failed++;
            continue;
        }
        if (record.ref) result.installed++;
    }

    result.pending = builder.dirty_count;
    result.skipped = builder.skipped_sources;
    builder.skipped_sources = 0;
    return result;
}

<*
 Mesh whose tile grid matches the builder's, one slot per tile or expected_layers_per_tile with cache_layers.
 @param [&in] builder : "Fixes the origin, tile size and tile count."
 @return? c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn NavMesh? create_nav_mesh_for(Allocator allocator, NavBuilder* builder) {
    uint layers = builder.cache_layers ? builder.expected_layers_per_tile : 1;
    return create_nav_mesh(allocator, {
        .origin      = builder.bounds.min,
        .tile_width  = builder.tile_world_size,
        .tile_height = builder.tile_world_size,
        .max_tiles   = builder.tiles_x * builder.tiles_z * layers,
    });
}

fn VolumeRecord[]? cache_volume_source(void* context, Aabb bounds) @private {
    CacheSources* sources = context;
    usz count;
    bool overflowed;
    sources.scene.@each(NavVolumeRuntime; entity, runtime) {
        if (overlaps_xz(runtime.bounds, bounds)) {
            if (count == sources.volumes.len) {
                overflowed = true;
            } else {
                sources.volumes[count++] = runtime.record;
            }
        }
    };
    if (overflowed) return c3d::CAPACITY_EXCEEDED~;
    return sources.volumes[:count];
}

fn OffMeshConnectionDesc[] cache_link_source(void* context, Aabb bounds) @private {
    CacheSources* sources = context;
    Scene* scene = sources.scene;
    usz count;
    scene.@each(NavLinkRuntime; entity, runtime) {
        if (starts_in_tile(runtime.start, bounds)) {
            sources.links[count++] = link_connection(runtime, scene.world.get(entity, NavLink));
        }
    };
    return sources.links[:count];
}

// Removing a mirror fires its remove hook, which queues the bounds; removal waits for the walk to end.
fn void remove_orphan_mirrors(NavBuilder* builder, Scene* scene) @local {
    usz source_orphans;
    scene.@each(NavSourceRuntime; entity, runtime) {
        if (!scene.world.has(entity, NavSource)) builder.orphan_scratch[source_orphans++] = entity;
    };
    foreach (entity : builder.orphan_scratch[:source_orphans]) {
        scene.remove_component(scene.node(entity), NavSourceRuntime);
    }

    usz volume_orphans;
    scene.@each(NavVolumeRuntime; entity, runtime) {
        if (!scene.world.has(entity, NavVolume)) builder.orphan_scratch[volume_orphans++] = entity;
    };
    foreach (entity : builder.orphan_scratch[:volume_orphans]) {
        scene.remove_component(scene.node(entity), NavVolumeRuntime);
    }

    usz link_orphans;
    scene.@each(NavLinkRuntime; entity, runtime) {
        if (!scene.world.has(entity, NavLink)) builder.orphan_scratch[link_orphans++] = entity;
    };
    foreach (entity : builder.orphan_scratch[:link_orphans]) {
        scene.remove_component(scene.node(entity), NavLinkRuntime);
    }

    usz obstacle_orphans;
    scene.@each(NavObstacleRuntime; entity, runtime) {
        if (!scene.world.has(entity, NavObstacle)) builder.orphan_scratch[obstacle_orphans++] = entity;
    };
    foreach (entity : builder.orphan_scratch[:obstacle_orphans]) {
        scene.remove_component(scene.node(entity), NavObstacleRuntime);
    }
}

// An overflowed queue lost bounds, so every tile is rebuilt, or relayered with cached layers.
fn bool drain_volume_removals(NavBuilder* builder) @local {
    RemovalQueue* removals = builder.removals;
    bool removed = removals.volume_count > 0 || removals.volumes_overflowed;
    if (removals.volumes_overflowed) {
        foreach (&record : builder.tiles) {
            if (builder.cache_layers) {
                record.relayer = true;
            } else {
                redirty(builder, record);
            }
        }
    } else {
        foreach (bounds : removals.volume_bounds[:removals.volume_count]) mark_volume_tiles(builder, bounds);
    }
    removals.volume_count = 0;
    removals.volumes_overflowed = false;
    return removed;
}

// A ref the full request queue refuses waits for the next sync; a lost one would block its cells for good.
fn void drain_obstacle_removals(NavBuilder* builder) @local {
    RemovalQueue* removals = builder.removals;
    uint kept;
    foreach (ref : removals.obstacles[:removals.obstacle_count]) {
        if (@catch(builder.cache.remove_obstacle(ref)) == c3d::CAPACITY_EXCEEDED) removals.obstacles[kept++] = ref;
    }
    removals.obstacle_count = kept;
}

fn void mark_volume_tiles(NavBuilder* builder, Aabb bounds) @local {
    if (builder.cache_layers) {
        relayer_tiles(builder, bounds);
    } else {
        builder.mark_dirty(bounds);
    }
}

// A full request queue or no free obstacle slot leaves the obstacle changed, so the next sync retries it.
fn void sync_obstacle(
    NavBuilder* builder,
    Scene* scene,
    Node* node,
    NavObstacle* obstacle,
) @local {
    if (!scene.has(node, NavObstacleRuntime)) {
        scene.add(node, (NavObstacleRuntime){});
        obstacle.changed = true;
    }
    if (!obstacle.changed) return;
    NavObstacleRuntime* runtime = scene.get(node, NavObstacleRuntime);
    if (runtime.ref) {
        if (@catch(builder.cache.remove_obstacle(runtime.ref)) == c3d::CAPACITY_EXCEEDED) return;
        runtime.ref = (ObstacleRef)0;
    }
    ObstacleRef? ref = add_world_obstacle(&builder.cache, obstacle, node.world);
    if (catch ref) return;
    runtime.ref = ref;
    obstacle.changed = false;
}

fn ObstacleRef? add_world_obstacle(TileCache* cache, NavObstacle* obstacle, Mat4 world) @local {
    switch (obstacle.kind) {
        case CYLINDER:
            return cache.add_obstacle(maths::transform_point(world, obstacle.position), obstacle.radius, obstacle.height);
        case BOX:
            return cache.add_box_obstacle(maths::aabb_transform(obstacle.box, world));
        case ORIENTED_BOX:
            Vec3 axis_x = maths::transform_dir(world, { 1, 0, 0 });
            float yaw = math::atan2(-axis_x.z, axis_x.x);
            return cache.add_oriented_box_obstacle(maths::transform_point(world, obstacle.position), obstacle.half_extents, yaw);
    }
}

// Obstacle requests wait for an empty rebuild queue, so they are applied before relayer and relink tiles join it.
// A tile the full queue cannot take keeps its flags for the next sync.
fn void rebuild_cached_layers(
    NavBuilder* builder,
    NavMesh* mesh,
    uint budget,
    NavSyncResult* result,
) @local {
    TileCache* cache = &builder.cache;
    if (cache.update_count == 0) apply_obstacle_requests(cache);
    foreach (index, &record : builder.tiles) {
        if (!record.relayer && !record.relink) continue;
        remove_surplus_layers(
            mesh:        mesh,
            tile_x:      (int)(index % builder.tiles_x),
            tile_z:      (int)(index / builder.tiles_x),
            layer_count: record.layer_count,
        );
        bool queued = true;
        foreach (ref : record.layers[:record.layer_count]) {
            if (catch queue_rebuild(cache, ref)) queued = false;
        }
        if (!queued) continue;
        record.relayer = false;
        record.relink = false;
    }

    for (uint round = 0; round < budget && cache.update_count > 0; round++) {
        CachedLayer*? queued = cache.tile_by_ref(cache.update_queue[0]);
        fault failure = @catch(cache.update(mesh, 1));
        // A layer replaced since it was queued is skipped.
        if (catch queued) continue;
        LayerHeader* header = queued.header;
        if (failure) {
            builder.last_failure = {
                .tile_x = header.tile_x,
                .tile_z = header.tile_z,
                .reason = failure,
                .stage  = INSTALL,
            };
            result.failed++;
            continue;
        }
        result.relayered++;
        if (mesh.tile_ref_at(header.tile_x, header.tile_z, header.tile_layer)) result.installed++;
    }
}

// A tile rebuilt with fewer layers leaves its higher ones in the mesh.
fn void remove_surplus_layers(
    NavMesh* mesh,
    int tile_x,
    int tile_z,
    uint layer_count,
) @local {
    MeshTile*[MAX_TILES_AT] resident;
    usz count = mesh.tiles_at(tile_x, tile_z, resident[..]);
    foreach (tile : resident[:count]) {
        if (tile.header.layer >= (int)layer_count) (void)mesh.remove_tile(mesh.tile_ref(tile));
    }
}

// An overflowed queue lost bounds, so every tile is rebuilt.
fn bool drain_removals(NavBuilder* builder) @local {
    RemovalQueue* removals = builder.removals;
    bool removed = removals.count > 0 || removals.overflowed;
    if (removals.overflowed) {
        foreach (&record : builder.tiles) redirty(builder, record);
    } else {
        foreach (bounds : removals.bounds[:removals.count]) builder.mark_dirty(bounds);
    }
    removals.count = 0;
    removals.overflowed = false;
    return removed;
}

// An overflowed queue lost endpoints, so every tile relinks.
fn void drain_link_removals(NavBuilder* builder) @local {
    RemovalQueue* removals = builder.removals;
    if (removals.links_overflowed) {
        foreach (&record : builder.tiles) record.relink = true;
    } else {
        foreach (link : removals.links[:removals.link_count]) relink_link_tiles(builder, link);
    }
    removals.link_count = 0;
    removals.links_overflowed = false;
}

fn void relink_link_tiles(NavBuilder* builder, NavLinkRuntime link) @local {
    relink_tile_at(builder, link.start);
    relink_tile_at(builder, link.end);
}

fn void relink_tile_at(NavBuilder* builder, Vec3 point) @local {
    Vec3 offset = (point - builder.bounds.min) / builder.tile_world_size;
    int tile_x = (int)math::floor(offset.x);
    int tile_z = (int)math::floor(offset.z);
    if (tile_x < 0 || tile_z < 0 || tile_x >= (int)builder.tiles_x || tile_z >= (int)builder.tiles_z) return;
    builder.tiles[tile_x + tile_z * (int)builder.tiles_x].relink = true;
}

fn void? install_tile(
    NavBuilder* builder,
    NavMesh* mesh,
    Scene* scene,
    uint index,
) @local {
    TileRecord* record = &builder.tiles[index];
    record.relink = false;
    record.ref = (TileRef)0;
    TileDataParams params = {
        .tile_x          = (int)(index % builder.tiles_x),
        .tile_z          = (int)(index / builder.tiles_x),
        .walkable_height = builder.config.agent_height,
        .walkable_radius = builder.config.agent_radius,
        .walkable_climb  = builder.config.agent_max_climb,
        .build_bv_tree   = true,
    };
    @pool() {
        OffMeshConnectionDesc[] connections;
        if (record.mesh.len) connections = tile_connections(scene, tile_mesh_view(record.mesh).header.bounds);
        record.ref = mesh.install_tile_mesh(record.mesh, connections, params)!;
    };
}

// The links whose start lies in the tile's XZ bounds, in tmem.
fn OffMeshConnectionDesc[] tile_connections(Scene* scene, Aabb bounds) @local {
    usz count;
    scene.@each(NavLinkRuntime; entity, runtime) {
        if (starts_in_tile(runtime.start, bounds)) count++;
    };
    OffMeshConnectionDesc[] connections = alloc::new_array(tmem, OffMeshConnectionDesc, (sz)count);
    usz written;
    scene.@each(NavLinkRuntime; entity, runtime) {
        if (starts_in_tile(runtime.start, bounds)) {
            connections[written++] = link_connection(runtime, scene.world.get(entity, NavLink));
        }
    };
    return connections;
}

fn OffMeshConnectionDesc link_connection(NavLinkRuntime* runtime, NavLink* link) @local {
    return {
        .start         = runtime.start,
        .end           = runtime.end,
        .radius        = link.radius,
        .flags         = link.flags,
        .area          = link.area,
        .bidirectional = link.bidirectional,
        .user_id       = link.user_id,
    };
}

fn bool starts_in_tile(Vec3 start, Aabb bounds) @local {
    return start.x >= bounds.min.x && start.x < bounds.max.x && start.z >= bounds.min.z && start.z < bounds.max.z;
}

fn NavVolumeRuntime world_volume(NavVolume* volume, Mat4 world) @local {
    VolumeRecord record = { .kind = volume.kind, .area = volume.area };
    Aabb bounds;
    switch (volume.kind) {
        case BOX:
            record.box = maths::aabb_transform(volume.box, world);
            bounds = record.box;
        case CONVEX:
            // Heights follow the node's world height; the footprint follows its full matrix.
            float lift = maths::translation(world).y;
            record.vert_count = volume.vert_count;
            record.min_y = volume.min_y + lift;
            record.max_y = volume.max_y + lift;
            foreach (index, vertex : volume.verts[:volume.vert_count]) {
                Vec3 placed = maths::transform_point(world, vertex);
                record.verts[index] = placed;
                bounds.min = index == 0 ? placed : math::min(bounds.min, placed);
                bounds.max = index == 0 ? placed : math::max(bounds.max, placed);
            }
            bounds.min.y = record.min_y;
            bounds.max.y = record.max_y;
        case CYLINDER:
            record.base = maths::transform_point(world, volume.base);
            record.radius = volume.radius;
            record.height = volume.height;
            bounds = {
                .min = { record.base.x - record.radius, record.base.y, record.base.z - record.radius },
                .max = { record.base.x + record.radius, record.base.y + record.height, record.base.z + record.radius },
            };
    }
    return { .bounds = bounds, .record = record };
}
