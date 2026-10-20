module c3d::asset;

import c3d;
import c3d::geometry;
import std::math;

<*
 Vertex streams of a geometry whose edits are tracked separately.
*>
enum GeometryStream : char {
    POSITIONS,
    NORMALS,
    TANGENTS,
    UV0,
    UV1,
    COLORS,
    JOINTS,
    WEIGHTS,
    CUSTOM,
}

<*
 Streams one mark covers.
*>
bitstruct GeometryStreams : uint {
    bool positions : 0;
    bool normals   : 1;
    bool tangents  : 2;
    bool uv0       : 3;
    bool uv1       : 4;
    bool colors    : 5;
    bool joints    : 6;
    bool weights   : 7;
    bool custom    : 8;
}

<*
 Half-open vertex interval; empty when first equals end.
*>
struct VertexRange {
    uint first;
    uint end;
}

<*
 Edits since a renderer last held the geometry, as one vertex range per stream.
 The ranges describe the changes after base_revision; whole marks a change they cannot describe.
*>
struct GeometryDirty {
    uint                             base_revision;
    bool                             whole;
    VertexRange[GeometryStream::len] ranges;
}

<*
 Whether the interval holds no vertex.
*>
fn bool VertexRange.is_empty(&self) => self.first == self.end;

<*
 Mark whole streams edited; the renderer copies only those streams.
 @require self.geometries.is_live(geometry)
 @require geometry_has_streams(self.geometries.get(geometry), streams)
*>
fn void AssetStore.mark_geometry_streams_dirty(&self, GeometryId geometry, GeometryStreams streams) {
    GeometryAsset* record = self.geometries.get(geometry);
    mark_streams(
        allocator: self.allocator,
        record:    record,
        streams:   streams,
        range:     { .first = 0, .end = record.vertex_count },
    );
}

<*
 Mark a vertex range of streams edited; the renderer copies only that range.
 @require self.geometries.is_live(geometry)
 @require geometry_has_streams(self.geometries.get(geometry), streams)
 @require vertex_count > 0
 @require (usz)first_vertex + vertex_count <= self.geometries.get(geometry).vertex_count
*>
fn void AssetStore.mark_geometry_range_dirty(
    &self,
    GeometryId geometry,
    GeometryStreams streams,
    uint first_vertex,
    uint vertex_count,
) {
    GeometryAsset* record = self.geometries.get(geometry);
    mark_streams(
        allocator: self.allocator,
        record:    record,
        streams:   streams,
        range:     { .first = first_vertex, .end = first_vertex + vertex_count },
    );
}

<*
 Record that a renderer holds the current revision; empties the dirty ranges.
 @require self.geometries.is_live(geometry)
*>
fn void AssetStore.clear_geometry_dirty(&self, GeometryId geometry) {
    GeometryAsset* record = self.geometries.get(geometry);
    record.dirty = { .base_revision = record.header.revision };
}

fn void mark_streams(
    Allocator allocator,
    GeometryAsset* record,
    GeometryStreams streams,
    VertexRange range,
) @private {
    record.header.revision++;
    restore_source_bounds(record);
    foreach (stream : GeometryStream::values) {
        if (stream_marked(streams, stream)) extend_range(&record.dirty.ranges[stream.ordinal], range);
    }
    refresh_derived_geometry(allocator, record, streams);
}

fn void extend_range(VertexRange* range, VertexRange added) @local {
    if (range.is_empty()) {
        *range = added;
        return;
    }
    range.first = math::min(range.first, added.first);
    range.end = math::max(range.end, added.end);
}

fn bool stream_marked(GeometryStreams streams, GeometryStream stream) @local {
    switch (stream) {
        case POSITIONS: return streams.positions;
        case NORMALS: return streams.normals;
        case TANGENTS: return streams.tangents;
        case UV0: return streams.uv0;
        case UV1: return streams.uv1;
        case COLORS: return streams.colors;
        case JOINTS: return streams.joints;
        case WEIGHTS: return streams.weights;
        case CUSTOM: return streams.custom;
    }
}

fn void refresh_derived_geometry(Allocator allocator, GeometryAsset* record, GeometryStreams changed) @private {
    if (!record.data.positions.len) return;
    if (changed.joints) record.joints_u16 = record.data.joints_exceed_byte();
    if (!changed.positions && !changed.joints && !changed.weights) return;
    geometry::free_skin_bounds(allocator, &record.skin_bounds);
    record.skin_bounds = geometry::build_skin_bounds(allocator, &record.data);
    geometry::free_morph_bounds(allocator, &record.morph_bounds);
    record.morph_bounds = geometry::build_morph_bounds(allocator, &record.data);
}

fn bool geometry_has_streams(GeometryAsset* record, GeometryStreams streams) @private {
    Geometry* data = &record.data;
    return (!streams.positions || data.positions.len > 0)
        && (!streams.normals || data.normals.len > 0)
        && (!streams.tangents || data.tangents.len > 0)
        && (!streams.uv0 || data.uv0.len > 0)
        && (!streams.uv1 || data.uv1.len > 0)
        && (!streams.colors || data.colors.len > 0)
        && (!streams.joints || data.joints.len > 0)
        && (!streams.weights || data.weights.len > 0)
        && (!streams.custom || data.custom_data.len > 0);
}
