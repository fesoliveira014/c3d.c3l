module c3d::spatial;

import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::maths;
import c3d::scene;
import c3d::spatial::bvh;
import std::math;
import std::sort;

<*
 What one entry is and which queries accept it.
*>
bitstruct SceneEntryFlags : uint {
    bool instanced        : 0;   // instance_index names the batch instance
    bool static_triangles : 1;   // triangle precision may apply
    bool skinned          : 2;
    bool billboard        : 3;
}

<*
 One mesh or one batch instance of the scene as of the last refresh.
*>
struct SceneEntry {
    Node*           node;
    uint            instance_index;
    SceneEntryFlags flags;
    Aabb            bounds;         // world
}
// Refresh compares entries bytewise, so the entry holds no padding.
$assert SceneEntry::size == 40;

struct BatchKey @private {
    Mat4            world;
    Entity          entity;
    GeometryId      geometry;
    uint            geometry_revision;
    uint            batch_revision;
    uint            count;
    SceneEntryFlags flags;
    uint            refresh;            // refresh that last wrote or kept the batch's entries
}
// Refresh compares keys bytewise, so the key holds no padding.
$assert BatchKey::size == 100;

<*
 Entries of one scene with a tree over their bounds.
*>
struct SceneIndex {
    Allocator    allocator;
    Scene*       scene;             // set by refresh
    SceneEntry[] entries;           // capacity-sized; live in [0, count)
    uint         count;
    uint         revision;          // advances when refresh finds a difference; 0 before the first refresh
    Bvh          tree;              // over entries[0 .. count); storage sized at creation
    uint         tree_revision;     // revision the tree was built for; 0 when never built
    uint         dangling;          // meshes and batches the last refresh skipped for dead ids
    BatchKey[]   batch_keys;        // capacity-sized; valid at the first entry of a batch
    uint         refreshes;         // refreshes run; stamps batch keys
    ulong        scene_identity;    // Scene.identity of the last refresh
}

<*
 Index sized for the entry count; refresh faults past it.
 @param capacity : "Meshes plus batch instances the scene may hold at once."
 @require capacity > 0
*>
fn SceneIndex create_scene_index(Allocator allocator, uint capacity) {
    return {
        .allocator  = allocator,
        .entries    = alloc::new_array(allocator, SceneEntry, (sz)capacity),
        .batch_keys = alloc::new_array(allocator, BatchKey, (sz)capacity),
        .tree       = {
            .nodes      = alloc::new_array(allocator, BvhNode, (sz)tree_node_capacity(capacity)),
            .primitives = alloc::new_array(allocator, uint, (sz)capacity),
        },
    };
}

<*
 Free the entries and the tree storage.
 @param [&inout] index : "Left zeroed."
*>
fn void destroy_scene_index(SceneIndex* index) {
    alloc::free(index.allocator, index.entries.ptr);
    alloc::free(index.allocator, index.batch_keys.ptr);
    alloc::free(index.allocator, index.tree.nodes.ptr);
    alloc::free(index.allocator, index.tree.primitives.ptr);
    *index = {};
}

<*
 Rebuild the entries from the scene as left by the last update_world.
 @param [&in] assets : "Resolves geometry, material and skeleton records."
 @param [&in] scene : "Pose and visibility as left by the last update_world; kept for pick."
 @return? c3d::CAPACITY_EXCEEDED
*>
fn void? SceneIndex.refresh(&self, AssetStore* assets, Scene* scene) {
    self.scene = scene;
    self.refreshes++;
    // Another scene may rebuild equal batches at the same slots, and their kept entries would name its nodes.
    if (scene.identity != self.scene_identity) self.refreshes++;
    self.scene_identity = scene.identity;
    usz needed;
    uint dangling;
    bool changed;
    scene.@each(Mesh; Entity entity, Mesh* mesh) {
        Node* node = scene.node(entity);
        if (node.visible_effective) {
            SkinBinding* skin = scene.get(node, SkinBinding);
            if (mesh_is_live(assets, mesh, skin)) {
                if (needed < self.entries.len) {
                    SceneEntry entry = mesh_entry(
                        assets: assets,
                        node:   node,
                        mesh:   mesh,
                        skin:   skin,
                    );
                    changed |= store_entry(&self.entries[needed], entry);
                }
                needed++;
            } else {
                dangling++;
            }
        }
    };
    scene.@each(InstancedMesh; Entity entity, InstancedMesh* batch) {
        Node* node = scene.node(entity);
        if (node.visible_effective && batch.count) {
            if (instanced_mesh_is_live(assets, batch)) {
                changed |= store_batch(
                    index:  self,
                    assets: assets,
                    node:   node,
                    batch:  batch,
                    first:  needed,
                );
                needed += batch.count;
            } else {
                dangling++;
            }
        }
    };
    scene.@each(BillboardBatch; Entity entity, BillboardBatch* batch) {
        Node* node = scene.node(entity);
        if (node.visible_effective && batch.count) {
            if (billboard_batch_is_live(assets, batch)) {
                changed |= store_billboard_batch(
                    index: self,
                    node: node,
                    batch: batch,
                    first: needed,
                );
                needed += batch.count;
            } else {
                dangling++;
            }
        }
    };
    self.dangling = dangling;
    if (needed > self.entries.len) {
        self.count = 0;
        self.revision++;
        return c3d::CAPACITY_EXCEEDED~;
    }
    if (changed || needed != self.count || !self.revision) self.revision++;
    self.count = (uint)needed;
}

<*
 Meshes the ray meets, nearest first; the hits and order of spatial::pick for the scene of the last refresh.
 Builds the tree when the last refresh changed the entries; a Scene.remove since then needs a refresh first.
 @param allocator : "Owns the returned array."
 @param [&inout] assets : "The store the last refresh read; triangle trees may be built."
 @param ray : "World space; direction normalized."
 @require self.revision > 0
*>
fn PickHit[] SceneIndex.pick(
    &self,
    Allocator allocator,
    AssetStore* assets,
    Ray ray,
    PickOptions options = PICK_OPTIONS_DEFAULT,
) {
    if (!self.count) return {};
    if (self.tree_revision != self.revision) build_tree(self);
    PickHit[] hits = alloc::new_array(allocator, PickHit, (sz)self.count);
    usz count;
    self.tree.@each_ray_hit(ray, math::FLOAT_MAX; uint primitive) {
        SceneEntry* entry = &self.entries[primitive];
        if ((options.layers & entry.node.layers) != 0) {
            bool hit = hit_entry(
                assets:  assets,
                scene:   self.scene,
                entry:   entry,
                ray:     ray,
                options: options,
                hit:     &hits[count],
            );
            if (hit) count++;
        }
    };
    sort::quicksort(hits[:count], &by_distance);
    return hits[:count];
}

<*
 Build the triangle tree of every static-triangle geometry the scene draws, once per geometry, for load time.
 @param [&inout] assets : "Keeps the trees."
 @param [&in] scene : "Every mesh and batch, hidden or on any layer."
*>
fn void prepare_triangle_picks(AssetStore* assets, Scene* scene) {
    scene.@each(Mesh; Entity entity, Mesh* mesh) {
        SkinBinding* skin = scene.get(scene.node(entity), SkinBinding);
        if (mesh_is_live(assets, mesh, skin)) {
            GeometryAsset* record = assets.geometry(mesh.geometry);
            if (triangles_are_static(record, skin != null, mesh.has_bounds_override)) {
                prepare_triangle_tree(assets, mesh.geometry);
            }
        }
    };
    scene.@each(InstancedMesh; Entity entity, InstancedMesh* batch) {
        if (instanced_mesh_is_live(assets, batch)
            && batch_triangles_static(assets.geometry(batch.geometry), batch.has_bounds_override)) {
            prepare_triangle_tree(assets, batch.geometry);
        }
    };
}

fn usz tree_node_capacity(uint capacity) @local {
    return 2 * (usz)capacity - 1;
}

fn bool store_entry(SceneEntry* slot, SceneEntry entry) @local {
    if (mem::equals(slot, &entry, (sz)SceneEntry::size)) return false;
    *slot = entry;
    return true;
}

// A batch whose key matches the one the previous refresh stamped at the same first entry keeps its entries:
// that refresh wrote or kept them there, and later batches write only past them.
fn bool store_batch(
    SceneIndex* index,
    AssetStore* assets,
    Node* node,
    InstancedMesh* batch,
    usz first,
) @local {
    SceneEntryFlags flags = batch_flags(
        assets: assets,
        scene:  index.scene,
        node:   node,
        batch:  batch,
    );
    GeometryAsset* record = assets.geometry(batch.geometry);
    bool fits = first + batch.count <= index.entries.len;
    BatchKey key = {
        .world             = node.world,
        .entity            = node.id,
        .geometry          = batch.geometry,
        .geometry_revision = record.header.revision,
        .batch_revision    = batch.revision,
        .count             = batch.count,
        .flags             = flags,
        .refresh           = index.refreshes - 1,
    };
    if (fits && mem::equals(&index.batch_keys[first], &key, (sz)BatchKey::size)) {
        index.batch_keys[first].refresh = index.refreshes;
        return false;
    }
    if (fits) {
        key.refresh = index.refreshes;
        index.batch_keys[first] = key;
    }
    bool changed;
    usz slot = first;
    foreach (uint instance, transform : batch.transforms[:batch.count]) {
        if (slot == index.entries.len) break;
        SceneEntry entry = instance_entry(
            node:      node,
            index:     instance,
            flags:     flags,
            local:     record.data.bounds,
            transform: transform,
        );
        changed |= store_entry(&index.entries[slot], entry);
        slot++;
    }
    return changed;
}

fn bool store_billboard_batch(
    SceneIndex* index,
    Node* node,
    BillboardBatch* batch,
    usz first,
) @local {
    bool fits = first + batch.count <= index.entries.len;
    BatchKey key = {
        .world = node.world,
        .entity = node.id,
        .batch_revision = batch.revision,
        .count = batch.count,
        .flags = { .instanced, .billboard },
        .refresh = index.refreshes - 1,
    };
    if (fits && mem::equals(&index.batch_keys[first], &key, (sz)BatchKey::size)) {
        index.batch_keys[first].refresh = index.refreshes;
        return false;
    }
    if (fits) {
        key.refresh = index.refreshes;
        index.batch_keys[first] = key;
    }
    bool changed;
    foreach (uint instance, billboard : batch.billboards[:batch.count]) {
        usz slot = first + instance;
        if (slot >= index.entries.len) break;
        changed |= store_entry(&index.entries[slot], billboard_entry(node, instance, billboard));
    }
    return changed;
}

fn SceneEntry billboard_entry(Node* node, uint index, Billboard billboard) @private {
    return {
        .node = node,
        .instance_index = index,
        .flags = { .instanced, .billboard },
        .bounds = billboard_bounds(node.world, billboard),
    };
}

fn void build_tree(SceneIndex* index) @local {
    uint capacity = (uint)index.entries.len;
    index.tree.nodes = index.tree.nodes.ptr[:tree_node_capacity(capacity)];
    index.tree.primitives = index.tree.primitives.ptr[:capacity];
    @pool() {
        Aabb[] boxes = alloc::new_array(tmem, Aabb, (sz)index.count);
        foreach (slot, &entry : index.entries[:index.count]) boxes[slot] = entry.bounds;
        // A refresh with entries leaves at least one box, the build's only fault.
        bvh::build_box_bvh_into(&index.tree, boxes)!!;
    };
    index.tree_revision = index.revision;
}

fn void prepare_triangle_tree(AssetStore* assets, GeometryId geometry) @local {
    if (!assets.geometry(geometry).data.positions.len) return;
    // A malformed list is recorded by the store and picks at bounds.
    (void)assets.triangle_bvh(geometry);
}

fn SceneEntry mesh_entry(
    AssetStore* assets,
    Node* node,
    Mesh* mesh,
    SkinBinding* skin,
) @private {
    GeometryAsset* record = assets.geometry(mesh.geometry);
    return {
        .node   = node,
        .flags  = {
            .static_triangles = triangles_are_static(record, skin != null, mesh.has_bounds_override)
              && record.data.positions.len > 0,
            .skinned          = skin != null,
        },
        .bounds = mesh_world_bounds(
            assets: assets,
            node:   node,
            mesh:   mesh,
            skin:   skin,
        ),
    };
}

fn SceneEntryFlags batch_flags(
    AssetStore* assets,
    Scene* scene,
    Node* node,
    InstancedMesh* batch,
) @private {
    GeometryAsset* record = assets.geometry(batch.geometry);
    return {
        .instanced        = true,
        .static_triangles = batch_triangles_static(record, batch.has_bounds_override)
          && record.data.positions.len > 0,
        .skinned          = scene.has(node.parent, AnimatedCrowd),
    };
}

fn SceneEntry instance_entry(
    Node* node,
    uint index,
    SceneEntryFlags flags,
    Aabb local,
    Transform transform,
) @private {
    return {
        .node           = node,
        .instance_index = index,
        .flags          = flags,
        .bounds         = maths::aabb_transform(local, node.world.mul(transform.to_mat4())),
    };
}

// A batch has no per-instance morph weights, so its rest triangles are what it draws.
fn bool batch_triangles_static(GeometryAsset* record, bool has_bounds_override) @local {
    return !has_bounds_override && record.data.topology == Topology.TRIANGLES;
}
