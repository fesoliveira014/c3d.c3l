module c3d::nav;

import std::math;
import c3d;
import c3d::asset;
import c3d::ecs;
import c3d::maths;
import c3d::scene;

<*
 Apply NavSource, NavVolume and NavLink additions, changes and removals to the tile grid.
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

    scene.@each(NavVolume; entity, volume) {
        Node* node = scene.node(entity);
        bool added = !scene.has(node, NavVolumeRuntime);
        if (added || volume.changed) {
            volume.changed = false;
            changed = true;
            NavVolumeRuntime runtime = world_volume(volume, node.world);
            self.mark_dirty(runtime.bounds);
            if (added) {
                scene.add(node, runtime);
            } else {
                NavVolumeRuntime* mirror = scene.get(node, NavVolumeRuntime);
                self.mark_dirty(mirror.bounds);
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

    if (drain_removals(self)) changed = true;
    drain_link_removals(self);
    if (changed) self.source_epoch++;
}

<*
 Apply scene changes, build up to budget tiles, then install every tile marked for relink into the mesh.
 Invalidates every PolyRef into a reinstalled tile.
 @param [&inout] builder : "Owns the TileMesh blobs."
 @param [&inout] mesh : "The builder's one mesh, from create_nav_mesh_for; owns the installed blobs."
 @param [&in] scene : "World matrices as left by the last update_world."
 @param [&in] assets : "Geometry arrays are read, never kept."
 @param budget : "Tiles rasterized and committed this call; a slot left RASTERIZING counts; installs are unbudgeted."
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
 Mesh whose tile grid matches the builder's, one slot per tile.
 @param [&in] builder : "Fixes the origin, tile size and tile count."
 @return? c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn NavMesh? create_nav_mesh_for(Allocator allocator, NavBuilder* builder) {
    return create_nav_mesh(allocator, {
        .origin      = builder.bounds.min,
        .tile_width  = builder.tile_world_size,
        .tile_height = builder.tile_world_size,
        .max_tiles   = builder.tiles_x * builder.tiles_z,
    });
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

// Removes the resident tile first, so a failure leaves the coordinate empty until the next change.
fn void? install_tile(
    NavBuilder* builder,
    NavMesh* mesh,
    Scene* scene,
    uint index,
) @local {
    TileRecord* record = &builder.tiles[index];
    record.relink = false;
    if (record.ref) {
        (void)mesh.remove_tile(record.ref);
        record.ref = (TileRef)0;
    }
    if (!record.mesh.len) return;

    TileMeshView view = tile_mesh_view(record.mesh);
    TileDataParams params = {
        .tile_x          = view.header.tile_x,
        .tile_z          = view.header.tile_z,
        .walkable_height = builder.config.agent_height,
        .walkable_radius = builder.config.agent_radius,
        .walkable_climb  = builder.config.agent_max_climb,
        .build_bv_tree   = true,
    };
    @pool() {
        OffMeshConnectionDesc[] connections = tile_connections(scene, view.header.bounds);
        // The mesh frees the blob with its own allocator when the tile leaves.
        char[]? blob = alloc::alloc_array_try(mesh.allocator, char, (sz)tile_data_size(view, connections, params));
        if (catch blob) return c3d::CAPACITY_EXCEEDED~;
        if (catch excuse = create_tile_data(view, connections, params, blob)) {
            alloc::free(mesh.allocator, blob.ptr);
            return excuse~;
        }
        TileRef? ref = mesh.add_tile(blob, { .free_data = true });
        if (catch excuse = ref) {
            alloc::free(mesh.allocator, blob.ptr);
            return excuse~;
        }
        record.ref = ref;
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
            NavLink* link = scene.world.get(entity, NavLink);
            connections[written++] = {
                .start         = runtime.start,
                .end           = runtime.end,
                .radius        = link.radius,
                .flags         = link.flags,
                .area          = link.area,
                .bidirectional = link.bidirectional,
                .user_id       = link.user_id,
            };
        }
    };
    return connections;
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
