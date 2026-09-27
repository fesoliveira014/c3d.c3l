module c3d::nav;

import std::math;
import c3d;
import c3d::asset;
import c3d::ecs;
import c3d::maths;
import c3d::scene;

<*
 Apply NavSource and NavVolume additions, changes and removals to the tile grid.
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

    if (drain_removals(self)) changed = true;
    if (changed) self.source_epoch++;
}

<*
 Apply source changes, then rasterize, build and commit up to budget tiles on the calling thread.
 @param [&inout] builder : "Owns the TileMesh blobs."
 @param [&in] scene : "World matrices as left by the last update_world."
 @param [&in] assets : "Geometry arrays are read, never kept."
 @param budget : "Tiles taken from rasterization to commit this call; a slot left RASTERIZING counts."
*>
fn NavSyncResult nav_sync(
    NavBuilder* builder,
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
    result.pending = builder.dirty_count;
    result.skipped = builder.skipped_sources;
    builder.skipped_sources = 0;
    return result;
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
