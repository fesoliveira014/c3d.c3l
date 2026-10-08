module c3d::asset;

import c3d;
import c3d::geometry;
import c3d::pool;
import c3d::spatial::bvh;
import std::math;

<*
 Geometry record; counts survive a source release.
*>
struct GeometryAsset {
    AssetHeader header;
    Geometry    data;
    SkinBounds  skin_bounds;
    Aabb[]      morph_bounds;        // per target, over every vertex; kept through release_geometry_cpu
    uint        vertex_count;
    uint        index_count;
    uint        target_count;
    GeometryShape shape;             // structure live components were sized against; kept through release_geometry_cpu
    Bvh         triangles;           // over data.positions and data.indices at triangle_revision; empty when absent
    uint        triangle_revision;   // header.revision the tree matches; 0 when absent
    uint        validated_revision;  // header.revision whose arrays form a triangle list; 0 when unknown
    uint        rejected_revision;   // header.revision whose arrays form none, or whose topology is not TRIANGLES
}

struct GeometryShape @private {
    bool   has_joints;
    bool   has_weights;
    ushort joint_bound;     // largest positive-weight joint index at add; replacement never refreshes it
    char[] target_streams;  // per target: bit 0 position deltas, bit 1 normal deltas
}

const char TARGET_POSITIONS @private = 1;
const char TARGET_NORMALS @private   = 2;

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
        .morph_bounds = geometry::build_morph_bounds(self.allocator, geometry),
        .vertex_count = (uint)geometry.positions.len,
        .index_count  = (uint)geometry.indices.len,
        .target_count = (uint)geometry.targets.len,
        .shape        = build_geometry_shape(self.allocator, geometry),
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
        .morph_bounds = geometry::build_morph_bounds(self.allocator, geometry),
        .vertex_count = (uint)geometry.positions.len,
        .index_count  = (uint)geometry.indices.len,
        .target_count = (uint)geometry.targets.len,
        .shape        = build_geometry_shape(self.allocator, geometry),
    };
    register_key(self, key, typed_ref(AssetKind.GEOMETRY, id));
    return id;
}

<*
 Replace the geometry with a copy of the source.
 @param [&in] source : "Arrays may live in temporary memory."
 @return? c3d::INVALID_ARGUMENT, c3d::INCOMPATIBLE_STRUCTURE
 @require self.geometries.is_live(geometry)
*>
fn void? AssetStore.replace_geometry(&self, GeometryId geometry, Geometry* source) {
    GeometryAsset* record = self.geometries.get(geometry);
    check_influences(source)!;
    check_geometry_structure(record, source)!;
    apply_geometry(self.allocator, record, copy_geometry(self.allocator, source));
}

<*
 Replace the geometry, taking the source arrays on success.
 @param [&in] source : "Arrays and target names were allocated with the store allocator."
 @return? c3d::INVALID_ARGUMENT, c3d::INCOMPATIBLE_STRUCTURE
 @require self.geometries.is_live(geometry)
*>
fn void? AssetStore.replace_geometry_owned(&self, GeometryId geometry, Geometry* source) {
    GeometryAsset* record = self.geometries.get(geometry);
    check_influences(source)!;
    check_geometry_structure(record, source)!;
    apply_geometry(self.allocator, record, *source);
}

<*
 Record of the geometry; a borrow into the pool.
 @require self.geometries.is_live(geometry)
*>
fn GeometryAsset* AssetStore.geometry(&self, GeometryId geometry) {
    return self.geometries.get(geometry);
}

<*
 Advance the content revision after an edit; rebuilds the retained skin and morph bounds while the streams are present.
 @require self.geometries.is_live(geometry)
*>
fn void AssetStore.mark_geometry_dirty(&self, GeometryId geometry) {
    GeometryAsset* record = self.geometries.get(geometry);
    record.header.revision++;
    if (!record.data.positions.len) return;
    geometry::free_skin_bounds(self.allocator, &record.skin_bounds);
    record.skin_bounds = geometry::build_skin_bounds(self.allocator, &record.data);
    geometry::free_morph_bounds(self.allocator, &record.morph_bounds);
    record.morph_bounds = geometry::build_morph_bounds(self.allocator, &record.data);
}

<*
 Free the arrays and their triangle tree; keep counts, bounds, channels, id, revision and validity.
 @require self.geometries.is_live(geometry)
*>
fn void AssetStore.release_geometry_cpu(&self, GeometryId geometry) {
    GeometryAsset* record = self.geometries.get(geometry);
    free_geometry_streams(self.allocator, &record.data);
    free_triangle_tree(self.allocator, record);
}

<*
 Whether the arrays form a triangle list; remembers the answer of the current revision.
 @return? c3d::ASSET_DATA_UNAVAILABLE
 @require self.geometries.is_live(geometry)
*>
fn bool? AssetStore.triangles_valid(&self, GeometryId geometry) {
    GeometryAsset* record = self.geometries.get(geometry);
    uint revision = record.header.revision;
    if (record.validated_revision == revision) return true;
    if (record.rejected_revision == revision) return false;
    if (!record.data.positions.len) return c3d::ASSET_DATA_UNAVAILABLE~;
    bool valid = record.data.topology == Topology.TRIANGLES
        && bvh::triangle_list_valid(record.data.positions, record.data.indices);
    if (valid) {
        record.validated_revision = revision;
    } else {
        record.rejected_revision = revision;
    }
    return valid;
}

<*
 Triangle tree of the current revision, built on first use and kept until the revision moves or the arrays go.
 Scratch lives in the temp allocator.
 @return? c3d::INVALID_ARGUMENT, c3d::ASSET_DATA_UNAVAILABLE
 @require self.geometries.is_live(geometry)
*>
fn Bvh*? AssetStore.triangle_bvh(&self, GeometryId geometry) {
    if (!self.triangles_valid(geometry)!) return c3d::INVALID_ARGUMENT~;
    GeometryAsset* record = self.geometries.get(geometry);
    if (record.triangle_revision == record.header.revision) return &record.triangles;
    if (!record.data.positions.len) return c3d::ASSET_DATA_UNAVAILABLE~;
    free_triangle_tree(self.allocator, record);
    // The list was proven above, so the build cannot fault.
    record.triangles = bvh::build_triangle_bvh(self.allocator, record.data.positions, record.data.indices)!!;
    record.triangle_revision = record.header.revision;
    return &record.triangles;
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
    geometry::free_morph_bounds(self.allocator, &record.morph_bounds);
    free_triangle_tree(self.allocator, record);
    alloc::free(self.allocator, record.shape.target_streams.ptr);
    *record = {};
    self.geometries.remove(geometry);
}

fn GeometryShape build_geometry_shape(Allocator allocator, Geometry* geometry) @private {
    GeometryShape shape = {
        .has_joints     = geometry.joints.len > 0,
        .has_weights    = geometry.weights.len > 0,
        .target_streams = alloc::new_array(allocator, char, geometry.targets.len),
    };
    foreach (index, &target : geometry.targets) {
        shape.target_streams[index] = (target.position_deltas.len > 0 ? TARGET_POSITIONS : 0)
            | (target.normal_deltas.len > 0 ? TARGET_NORMALS : 0);
    }
    foreach (vertex, weight : geometry.weights) {
        for (usz slot = 0; slot < 4; slot++) {
            if (weight[slot] > 0) shape.joint_bound = math::max(shape.joint_bound, geometry.joints[vertex][slot]);
        }
    }
    return shape;
}

fn void? check_geometry_structure(GeometryAsset* current, Geometry* next) @private {
    GeometryShape* shape = &current.shape;
    if (current.data.topology != next.topology
        || shape.has_joints != (next.joints.len > 0)
        || shape.has_weights != (next.weights.len > 0)
        || current.target_count != next.targets.len
        || current.data.channels.len != next.channels.len) {
        return c3d::INCOMPATIBLE_STRUCTURE~;
    }
    foreach (index, &target : next.targets) {
        char streams = (target.position_deltas.len > 0 ? TARGET_POSITIONS : 0)
            | (target.normal_deltas.len > 0 ? TARGET_NORMALS : 0);
        if (shape.target_streams[index] != streams) return c3d::INCOMPATIBLE_STRUCTURE~;
    }
    foreach (index, &channel : next.channels) {
        MorphChannel* existing = &current.data.channels[index];
        if (existing.first_target != channel.first_target
            || existing.full_weights.len != channel.full_weights.len) {
            return c3d::INCOMPATIBLE_STRUCTURE~;
        }
    }
    foreach (vertex, weight : next.weights) {
        for (usz slot = 0; slot < 4; slot++) {
            if (weight[slot] > 0 && next.joints[vertex][slot] > shape.joint_bound) {
                return c3d::INCOMPATIBLE_STRUCTURE~;
            }
        }
    }
    return;
}

fn void apply_geometry(Allocator allocator, GeometryAsset* record, Geometry geometry) @private {
    free_geometry(allocator, &record.data);
    geometry::free_skin_bounds(allocator, &record.skin_bounds);
    geometry::free_morph_bounds(allocator, &record.morph_bounds);
    free_triangle_tree(allocator, record);
    record.data = geometry;
    record.skin_bounds = geometry::build_skin_bounds(allocator, &record.data);
    record.morph_bounds = geometry::build_morph_bounds(allocator, &record.data);
    record.vertex_count = (uint)geometry.positions.len;
    record.index_count = (uint)geometry.indices.len;
    record.target_count = (uint)geometry.targets.len;
    record.validated_revision = 0;
    record.rejected_revision = 0;
    mark_replaced(&record.header);
}

fn void free_triangle_tree(Allocator allocator, GeometryAsset* record) @private {
    if (record.triangles.nodes.len) bvh::free_bvh(allocator, &record.triangles);
    record.triangle_revision = 0;
}

fn void? check_influences(Geometry* geometry) @private {
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
