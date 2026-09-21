module c3d::asset;

import c3d;
import c3d::geometry;
import c3d::pool;
import std::math;

<*
 Geometry record; counts survive a source release.
*>
struct GeometryAsset {
    AssetHeader header;
    Geometry    data;
    SkinBounds  skin_bounds;
    uint        vertex_count;
    uint        index_count;
    uint        target_count;
}

<*
 Pool of geometry records addressed by GeometryId.
*>
alias GeometryPool = Pool{GeometryAsset, GeometryId};

<*
 Add a geometry, copying every array into the store.
 @param [&in] geometry : "Arrays may live in temporary memory."
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
*>
fn GeometryId? AssetStore.add_geometry(&self, Geometry* geometry, String key = "") {
    check_key(self, key)!;
    check_influences(geometry)!;
    GeometryId id = self.geometries.add({})!;
    *self.geometries.get(id) = {
        .header       = { .key = copy_string(self.allocator, key), .revision = 1 },
        .data         = copy_geometry(self.allocator, geometry),
        .skin_bounds  = geometry::build_skin_bounds(self.allocator, geometry),
        .vertex_count = (uint)geometry.positions.len,
        .index_count  = (uint)geometry.indices.len,
        .target_count = (uint)geometry.targets.len,
    };
    register_key(self, key, typed_ref(AssetKind.GEOMETRY, id));
    return id;
}

<*
 Add a geometry whose arrays the store takes over on success.
 @param [&in] geometry : "Arrays and target names were allocated with the store allocator."
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
*>
fn GeometryId? AssetStore.add_geometry_owned(&self, Geometry* geometry, String key = "") {
    check_key(self, key)!;
    check_influences(geometry)!;
    GeometryId id = self.geometries.add({})!;
    *self.geometries.get(id) = {
        .header       = { .key = copy_string(self.allocator, key), .revision = 1 },
        .data         = *geometry,
        .skin_bounds  = geometry::build_skin_bounds(self.allocator, geometry),
        .vertex_count = (uint)geometry.positions.len,
        .index_count  = (uint)geometry.indices.len,
        .target_count = (uint)geometry.targets.len,
    };
    register_key(self, key, typed_ref(AssetKind.GEOMETRY, id));
    return id;
}

<*
 Record of the geometry; a borrow into the pool.
 @require self.geometries.is_live(geometry)
*>
fn GeometryAsset* AssetStore.geometry(&self, GeometryId geometry) {
    return self.geometries.get(geometry);
}

<*
 Advance the content revision after an edit; rebuilds the retained skin bounds while the streams are present.
 @require self.geometries.is_live(geometry)
*>
fn void AssetStore.mark_geometry_dirty(&self, GeometryId geometry) {
    GeometryAsset* record = self.geometries.get(geometry);
    record.header.revision++;
    if (!record.data.positions.len) return;
    geometry::free_skin_bounds(self.allocator, &record.skin_bounds);
    record.skin_bounds = geometry::build_skin_bounds(self.allocator, &record.data);
}

<*
 Free the arrays; keep counts, bounds, channels, id, and revision.
 @require self.geometries.is_live(geometry)
*>
fn void AssetStore.release_geometry_cpu(&self, GeometryId geometry) {
    free_geometry_streams(self.allocator, &self.geometries.get(geometry).data);
}

<*
 Free the record and make its id stale.
 @require self.geometries.is_live(geometry)
*>
fn void AssetStore.remove_geometry(&self, GeometryId geometry) {
    GeometryAsset* record = self.geometries.get(geometry);
    forget_key(self, record.header.key);
    free_string(self.allocator, record.header.key);
    free_geometry(self.allocator, &record.data);
    geometry::free_skin_bounds(self.allocator, &record.skin_bounds);
    *record = {};
    self.geometries.remove(geometry);
}

fn void? check_influences(Geometry* geometry) @local {
    if (!geometry.joints.len && !geometry.weights.len) return;
    if (geometry.joints.len != geometry.positions.len || geometry.weights.len != geometry.positions.len) {
        return c3d::INVALID_ARGUMENT~;
    }
    foreach (weight : geometry.weights) {
        for (usz slot = 0; slot < 4; slot++) {
            if (!math::is_finite(weight[slot]) || weight[slot] < 0) return c3d::INVALID_ARGUMENT~;
        }
    }
    return;
}

fn Geometry copy_geometry(Allocator allocator, Geometry* source) @local {
    MorphTarget[] targets = alloc::new_array(allocator, MorphTarget, source.targets.len);
    foreach (index, &target : source.targets) {
        targets[index] = {
            .position_deltas = copy_slice(allocator, target.position_deltas),
            .normal_deltas   = copy_slice(allocator, target.normal_deltas),
            .name            = copy_string(allocator, target.name),
        };
    }
    MorphChannel[] channels = alloc::new_array(allocator, MorphChannel, source.channels.len);
    foreach (index, &channel : source.channels) {
        channels[index] = {
            .name         = copy_string(allocator, channel.name),
            .first_target = channel.first_target,
            .full_weights = copy_slice(allocator, channel.full_weights),
        };
    }
    return {
        .topology      = source.topology,
        .positions     = copy_slice(allocator, source.positions),
        .normals       = copy_slice(allocator, source.normals),
        .tangents      = copy_slice(allocator, source.tangents),
        .uv0           = copy_slice(allocator, source.uv0),
        .uv1           = copy_slice(allocator, source.uv1),
        .colors        = copy_slice(allocator, source.colors),
        .joints        = copy_slice(allocator, source.joints),
        .weights       = copy_slice(allocator, source.weights),
        .indices       = copy_slice(allocator, source.indices),
        .targets       = targets,
        .channels      = channels,
        .custom_data   = copy_slice(allocator, source.custom_data),
        .custom_stride = source.custom_stride,
        .bounds        = source.bounds,
    };
}

<*
 Free every array, target name and channel allocated with the allocator.
 Keeps topology, custom stride and bounds.
 @param [&inout] geometry : "Arrays left empty."
*>
fn void free_geometry(Allocator allocator, Geometry* geometry) {
    free_geometry_streams(allocator, geometry);
    foreach (&channel : geometry.channels) {
        alloc::free(allocator, channel.name.ptr);
        alloc::free(allocator, channel.full_weights.ptr);
    }
    alloc::free(allocator, geometry.channels.ptr);
    geometry.channels = {};
}

fn void free_geometry_streams(Allocator allocator, Geometry* geometry) @local {
    foreach (&target : geometry.targets) {
        alloc::free(allocator, target.position_deltas.ptr);
        alloc::free(allocator, target.normal_deltas.ptr);
        alloc::free(allocator, target.name.ptr);
    }
    alloc::free(allocator, geometry.targets.ptr);
    alloc::free(allocator, geometry.positions.ptr);
    alloc::free(allocator, geometry.normals.ptr);
    alloc::free(allocator, geometry.tangents.ptr);
    alloc::free(allocator, geometry.uv0.ptr);
    alloc::free(allocator, geometry.uv1.ptr);
    alloc::free(allocator, geometry.colors.ptr);
    alloc::free(allocator, geometry.joints.ptr);
    alloc::free(allocator, geometry.weights.ptr);
    alloc::free(allocator, geometry.indices.ptr);
    alloc::free(allocator, geometry.custom_data.ptr);
    *geometry = {
        .topology      = geometry.topology,
        .channels      = geometry.channels,
        .custom_stride = geometry.custom_stride,
        .bounds        = geometry.bounds,
    };
}
