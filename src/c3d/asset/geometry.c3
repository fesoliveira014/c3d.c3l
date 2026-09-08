module c3d::asset;

import c3d;
import c3d::geometry;
import c3d::pool;

<*
 Geometry record; counts survive a source release.
*>
struct GeometryAsset {
    AssetHeader header;
    Geometry    data;
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
    GeometryId id = self.geometries.add({})!;
    *self.geometries.get(id) = {
        .header       = { .key = copy_string(self.allocator, key), .revision = 1 },
        .data         = copy_geometry(self.allocator, geometry),
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
    GeometryId id = self.geometries.add({})!;
    *self.geometries.get(id) = {
        .header       = { .key = copy_string(self.allocator, key), .revision = 1 },
        .data         = *geometry,
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
 Advance the content revision after an edit.
 @require self.geometries.is_live(geometry)
*>
fn void AssetStore.mark_geometry_dirty(&self, GeometryId geometry) {
    self.geometries.get(geometry).header.revision++;
}

<*
 Free the arrays; keep counts, bounds, id, and revision.
 @require self.geometries.is_live(geometry)
*>
fn void AssetStore.release_geometry_cpu(&self, GeometryId geometry) {
    free_geometry(self.allocator, &self.geometries.get(geometry).data);
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
    *record = {};
    self.geometries.remove(geometry);
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
        .custom_data   = copy_slice(allocator, source.custom_data),
        .custom_stride = source.custom_stride,
        .bounds        = source.bounds,
    };
}

fn void free_geometry(Allocator allocator, Geometry* geometry) @private {
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
        .custom_stride = geometry.custom_stride,
        .bounds        = geometry.bounds,
    };
}
