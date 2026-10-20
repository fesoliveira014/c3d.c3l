module c3d::scene;

import c3d;
import c3d::ecs;
import c3d::maths;
import std::math;

<*
 RibbonPoint flag that starts a new strip at that point.
*>
const uint RIBBON_BREAK = 1; // mirrored as RIBBON_POINT_BREAK in abi/c3d.abi

<*
 Unit white point at the origin.
*>
const RibbonPoint RIBBON_POINT_DEFAULT = {
    .width = 1,
    .color = { 1, 1, 1, 1 },
};

<*
 Where a ribbon batch's strip points live.
*>
enum RibbonSource {
    POINTS, // RibbonPoint values that core packs once per revision
    DEVICE, // frame-origin records and a live count that compute writes
}

<*
 One point of a camera-facing strip.
*>
struct RibbonPoint {
    Vec3 position;
    float width; // metres across the strip, before node scale
    Vec4 color;
    float v; // texture coordinate along the strip; u runs 0 to 1 across it
    uint flags;
}

<*
 Library-owned world bounds of a ribbon batch.
*>
struct RibbonAggregate {
    Mat4 world;
    Aabb bounds;
    uint revision;
}

<*
 Renderer buffer holding a DEVICE batch's records and live count.
*>
struct RibbonDevice {
    BufferId buffer;
    usz records_offset; // capacity + 1 RibbonPointGpu records, 16-byte aligned
    usz count_offset; // one uint, 4-byte aligned, at most capacity
    uint capacity;
}

<*
 Fixed array of strip points sharing one material, drawn from one source.
*>
struct RibbonBatch {
    MaterialId material;
    RibbonPoint[] points; // POINTS only
    uint count;
    uint revision;
    RibbonAggregate aggregate;
    RibbonSource source;
    RibbonDevice device; // DEVICE only; a zero buffer draws nothing, and count stays zero
    bool has_bounds_override;
    Aabb local_bounds; // node-local; read when has_bounds_override is set
}

<*
 Add a node carrying a scene-owned ribbon batch.
 @param points : "Copied; determines the live count; empty unless POINTS."
 @param [in] parent : "Null selects the root."
 @param name : "Copied into the scene allocator."
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
 @require capacity > 0
*>
fn Node*? Scene.add_ribbons(
    &self,
    MaterialId material,
    uint capacity,
    RibbonPoint[] points = {},
    Node* parent = null,
    String name = "",
    RibbonSource source = RibbonSource.POINTS,
) {
    if (source != RibbonSource.POINTS && points.len) return c3d::INVALID_ARGUMENT~;
    if (points.len > capacity) return c3d::CAPACITY_EXCEEDED~;
    check_ribbon_points(points)!;
    Node* node = self.add_node(parent, name)!;
    RibbonBatch batch = {
        .material = material,
        .count = (uint)points.len,
        .revision = 1,
        .source = source,
    };
    switch (source) {
        case POINTS:
            batch.points = alloc::new_array(self.allocator, RibbonPoint, (sz)capacity);
            batch.points[:points.len] = points[..];
        case DEVICE:
            batch.device.capacity = capacity;
    }
    self.world.add(node.id, batch);
    return node;
}

<*
 Attach the buffer a DEVICE batch draws from, with its conservative bound.
 @param [&in] node : "Carries a DEVICE RibbonBatch."
 @param local_bounds : "Node-local bound of every strip the buffer can hold, widths included."
 @require self.has(node, RibbonBatch)
 @require self.get(node, RibbonBatch).source == RibbonSource.DEVICE
 @require device.capacity == self.get(node, RibbonBatch).capacity()
 @require device.records_offset % 16 == 0 && device.count_offset % 4 == 0
*>
fn void Scene.set_ribbon_device(
    &self,
    Node* node,
    RibbonDevice device,
    Aabb local_bounds,
) {
    RibbonBatch* batch = self.get(node, RibbonBatch);
    batch.device = device;
    batch.has_bounds_override = true;
    batch.local_bounds = local_bounds;
}

<*
 Replace the live ribbon points within capacity.
 @param [&in] node : "Carries RibbonBatch."
 @param points : "Copied into scene-owned storage."
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
 @require self.has(node, RibbonBatch)
 @require self.get(node, RibbonBatch).source == RibbonSource.POINTS
*>
fn void? Scene.set_ribbons(&self, Node* node, RibbonPoint[] points) {
    RibbonBatch* batch = self.get(node, RibbonBatch);
    if (points.len > batch.points.len) return c3d::CAPACITY_EXCEEDED~;
    check_ribbon_points(points)!;
    batch.points[:points.len] = points[..];
    batch.count = (uint)points.len;
    self.mark_ribbons_dirty(node);
}

<*
 Change live count, initializing newly exposed points.
 @param [&in] node : "Carries RibbonBatch."
 @return? c3d::CAPACITY_EXCEEDED
 @require self.has(node, RibbonBatch)
 @require self.get(node, RibbonBatch).source == RibbonSource.POINTS
*>
fn void? Scene.resize_ribbons(&self, Node* node, uint count) {
    RibbonBatch* batch = self.get(node, RibbonBatch);
    if (count > batch.points.len) return c3d::CAPACITY_EXCEEDED~;
    if (count > batch.count) batch.points[batch.count:count - batch.count] = RIBBON_POINT_DEFAULT;
    batch.count = count;
    self.mark_ribbons_dirty(node);
}

<*
 Publish in-place changes to the batch's render data.
 @param [&in] node : "Carries valid RibbonBatch data."
 @require self.has(node, RibbonBatch)
*>
fn void Scene.mark_ribbons_dirty(&self, Node* node) {
    RibbonBatch* batch = self.get(node, RibbonBatch);
    batch.revision = batch.revision == uint::max ? 1 : batch.revision + 1;
}

<*
 Points the batch can hold.
*>
fn uint RibbonBatch.capacity(&self) {
    switch (self.source) {
        case POINTS: return (uint)self.points.len;
        case DEVICE: return self.device.capacity;
    }
}

<*
 Points the renderer draws from; a DEVICE batch's capacity once attached.
*>
fn uint RibbonBatch.draw_count(&self) {
    if (self.source != RibbonSource.DEVICE) return self.count;

    return self.device.buffer.generation ? self.device.capacity : 0;
}

<*
 Mean scale of a node world, the factor strip widths take.
 @param world : "Published affine node transform."
 @pure
*>
fn float ribbon_width_scale(Mat4 world) {
    float volume = math::abs(world.determinant() @pure) @pure;
    return math::pow(volume, 1.0f / 3.0f) @pure;
}

<*
 Transform a ribbon point into world space with a precomputed width scale.
 @param world : "Published affine node transform."
 @param width_scale : "Mean scale of world, from ribbon_width_scale."
 @pure
*>
fn RibbonPoint place_ribbon_point(Mat4 world, float width_scale, RibbonPoint point) {
    point.position = maths::transform_point(world, point.position) @pure;
    point.width *= width_scale;
    return point;
}

<*
 Whether ribbon points satisfy the scene placement domain.
 @pure
*>
fn bool ribbon_points_valid(RibbonPoint[] points) {
    foreach (point : points) {
        for (usz axis = 0; axis < 3; axis++) {
            if (!math::is_finite(point.position[axis])) return false;
        }
        for (usz channel = 0; channel < 4; channel++) {
            if (!math::is_finite(point.color[channel])) return false;
        }
        if (!math::is_finite(point.width) || point.width < 0 || !math::is_finite(point.v)) return false;
        if (point.flags & ~RIBBON_BREAK) return false;
    }
    return true;
}

fn void? check_ribbon_points(RibbonPoint[] points) @local {
    if (!ribbon_points_valid(points)) return c3d::INVALID_ARGUMENT~;
}

fn void free_ribbons(Entity entity, void* component, void* user) @private {
    RibbonBatch* batch = (RibbonBatch*)component;
    if (batch.source == RibbonSource.POINTS) alloc::free(*(Allocator*)user, batch.points.ptr);
}
