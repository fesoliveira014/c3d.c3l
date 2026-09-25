module c3d::render;

import c3d;
import c3d::camera;
import c3d::light;
import c3d::shader;
import std::math;

const ClusterDesc CLUSTER_DESC_DEFAULT @local = {
    .tiles_x = 16,
    .tiles_y = 9,
    .depth_slices = 24,
    .lights_per_cluster = 64,
    .far_distance = 100,
}; // Starting coverage: 3456 cells cost 912384 bytes, plus lights and a 16-byte counter.

<* Opaque shading route selected by a view. *>
enum ShadingPath : uint {
    FORWARD,
    DEFERRED,
    PATH_TRACED,
}
$assert ShadingPath.FORWARD.ordinal == 0;

<* Candidate light selection selected by a view. *>
enum LightSelection : uint {
    FLAT,
    CLUSTERED,
}
$assert LightSelection.FLAT.ordinal == 0;

<* Fixed cluster dimensions, capacity and camera-depth coverage. *>
struct ClusterDesc {
    uint tiles_x;
    uint tiles_y;
    uint depth_slices;
    uint lights_per_cluster;
    float far_distance;
}

<* Aligned regions within one view's cluster allocation. *>
struct ClusterLayout {
    usz ranges_offset;
    usz indices_offset;
    usz counter_offset;
    usz size;
    uint cluster_count;
    uint index_count;
}

<* Camera-depth interval and mapping; near >= far disables clustering. *>
struct ClusterDepth {
    float near;
    float far;
    float scale;
    float bias;
    camera::Projection projection;
    uint slices;
}

<* Cluster cell of a shaded point; clustered is false where the flat list applies. *>
struct ClusterCell {
    uint[<3>] cell;
    bool      clustered;
}

<*
 Starting grid configuration; storage is allocated only when enabled.
 @pure
*>
fn ClusterDesc default_cluster_desc() => CLUSTER_DESC_DEFAULT;

<*
 Validate and size a cluster allocation for dispatch limits.
 @param max_groups : "Maximum workgroup counts in each dimension."
 @return? c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED
 @require max_lights > 0
 @pure
*>
fn ClusterLayout? cluster_layout(ClusterDesc desc, uint max_lights, uint[<3>] max_groups) {
    if (!desc.tiles_x || !desc.tiles_y || !desc.depth_slices || !desc.lights_per_cluster
      || !math::is_finite(desc.far_distance) || desc.far_distance <= 0) {
        return c3d::INVALID_ARGUMENT~;
    }
    if (desc.tiles_x > uint::max / desc.tiles_y) return c3d::INVALID_ARGUMENT~;
    uint cluster_count = desc.tiles_x * desc.tiles_y;
    if (cluster_count > uint::max / desc.depth_slices) return c3d::INVALID_ARGUMENT~;
    cluster_count *= desc.depth_slices;
    if (cluster_count > uint::max / desc.lights_per_cluster) return c3d::INVALID_ARGUMENT~;
    uint index_count = cluster_count * desc.lights_per_cluster;

    usz ranges_offset = cluster_region_end(0, max_lights, LightGpu::size)!;
    usz indices_offset = cluster_region_end(ranges_offset, cluster_count, ClusterRange::size)!;
    usz counter_offset = cluster_region_end(indices_offset, index_count, uint::size)!;
    usz size = cluster_region_end(counter_offset, 1, ClusterCounterGpu::size)!;
    if (desc.tiles_x > max_groups.x || desc.tiles_y > max_groups.y || desc.depth_slices > max_groups.z) {
        return c3d::UNSUPPORTED~;
    }
    return {
        .ranges_offset = ranges_offset,
        .indices_offset = indices_offset,
        .counter_offset = counter_offset,
        .size = size,
        .cluster_count = cluster_count,
        .index_count = index_count,
    };
}

<*
 Derive finite cluster coverage from the camera lens.
 @param [&in] camera : "Valid lens; perspective far zero means infinity."
 @require desc.depth_slices > 0
 @require desc.far_distance > 0 && math::is_finite(desc.far_distance)
 @pure
*>
fn ClusterDepth cluster_depth(camera::Camera* camera, ClusterDesc desc) {
    ClusterDepth depth = {
        .near = camera.near,
        .far = desc.far_distance,
        .projection = camera.projection,
        .slices = desc.depth_slices,
    };
    switch (camera.projection) {
        case PERSPECTIVE:
            if (camera.far != 0) depth.far = math::min(depth.far, camera.far);
        case ORTHOGRAPHIC:
            depth.near = math::max(camera.near, 0.0f);
            depth.far = math::min(depth.far, camera.far);
    }
    if (depth.far <= depth.near) return depth;
    switch (camera.projection) {
        case PERSPECTIVE:
            float log_near = math::ln(depth.near);
            depth.scale = (float)depth.slices / (math::ln(depth.far) - log_near);
            depth.bias = -log_near * depth.scale;
        case ORTHOGRAPHIC:
            depth.scale = (float)depth.slices / (depth.far - depth.near);
            depth.bias = -depth.near * depth.scale;
    }
    return depth;
}

<*
 Camera-depth endpoints of one cluster slice.
 @require depth.near < depth.far, slice < depth.slices
 @pure
*>
fn Vec2 cluster_slice_bounds(ClusterDepth depth, uint slice) {
    Vec2 bounds;
    switch (depth.projection) {
        case PERSPECTIVE:
            float log_near = math::ln(depth.near);
            float log_step = (math::ln(depth.far) - log_near) / (float)depth.slices;
            bounds = {
                math::exp(log_near + log_step * (float)slice),
                math::exp(log_near + log_step * (float)(slice + 1)),
            };
        case ORTHOGRAPHIC:
            float step = (depth.far - depth.near) / (float)depth.slices;
            bounds = { depth.near + step * (float)slice, depth.near + step * (float)(slice + 1) };
    }
    if (slice == 0) bounds.x = depth.near;
    if (slice + 1 == depth.slices) bounds.y = depth.far;
    return bounds;
}

<*
 Flat index of a cluster cell; mirrored as cluster_index in clusters.glsl.
 @pure
*>
fn uint cluster_index(ClusterDesc desc, uint[<3>] cell) {
    return cell.x + desc.tiles_x * (cell.y + desc.tiles_y * cell.z);
}

<*
 Cluster cell the shaders select for a world position; mirrored as select_lights in lights.glsl.
 @param view_proj : "Cluster projection of the view."
 @param view_depth : "Forward camera distance of the position."
*>
fn ClusterCell cluster_cell(
    ClusterDesc desc,
    ClusterDepth depth,
    Mat4 view_proj,
    Vec3 world_position,
    float view_depth,
) {
    if (depth.near >= depth.far || view_depth < depth.near || view_depth >= depth.far) return {};
    Vec4 projected = view_proj.apply({ world_position.x, world_position.y, world_position.z, 1 });
    if (projected.w <= 0) return {};
    Vec2 uv = projected.xy / projected.w * (Vec2){ 0.5f, -0.5f } + 0.5f;
    if (uv.x < 0 || uv.y < 0 || uv.x >= 1 || uv.y >= 1) return {};

    bool orthographic = depth.projection == camera::Projection.ORTHOGRAPHIC;
    float slice = math::floor((orthographic ? view_depth : math::ln(view_depth)) * depth.scale + depth.bias);
    if (slice < 0 || slice >= (float)desc.depth_slices) return {};
    Vec2 tile = uv * (Vec2){ (float)desc.tiles_x, (float)desc.tiles_y };
    uint[<3>] cell = { (uint)tile.x, (uint)tile.y, (uint)slice };
    if (cell.x >= desc.tiles_x || cell.y >= desc.tiles_y) return {};
    return { .cell = cell, .clustered = true };
}

<*
 Write global-light indices without reordering the selected light records.
 @param indices : "Receives the valid prefix; remaining elements are untouched."
 @return "Number of global indices written."
 @require indices.len >= lights.len
*>
fn uint pack_global_light_indices(LightGpu[] lights, uint[] indices) {
    uint count;
    foreach (index, &light : lights) {
        if (light.kind == (uint)LightKind.DIRECTIONAL.ordinal || light.position_range.w == 0) {
            indices[count++] = (uint)index;
        }
    }
    return count;
}

<*
 @pure
*>
fn usz? cluster_region_end(usz offset, usz count, usz stride) @local {
    if (count > (usz::max - offset) / stride) return c3d::INVALID_ARGUMENT~;
    usz end = offset + count * stride;
    if (end > usz::max - (STREAM_ALIGNMENT - 1)) return c3d::INVALID_ARGUMENT~;
    return align_up(end, STREAM_ALIGNMENT);
}
