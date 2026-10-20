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
 Fixed scene-owned array of strip points sharing one material.
*>
struct RibbonBatch {
    MaterialId material;
    RibbonPoint[] points;
    uint count;
    uint revision;
    RibbonAggregate aggregate;
}

<*
 Add a node carrying a scene-owned ribbon batch.
 @param points : "Copied; determines the live count."
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
) {
    if (points.len > capacity) return c3d::CAPACITY_EXCEEDED~;
    check_ribbon_points(points)!;
    Node* node = self.add_node(parent, name)!;
    RibbonBatch batch = {
        .material = material,
        .points = alloc::new_array(self.allocator, RibbonPoint, (sz)capacity),
        .count = (uint)points.len,
        .revision = 1,
    };
    batch.points[:points.len] = points[..];
    self.world.add(node.id, batch);
    return node;
}

<*
 Replace the live ribbon points within capacity.
 @param [&in] node : "Carries RibbonBatch."
 @param points : "Copied into scene-owned storage."
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
 @require self.has(node, RibbonBatch)
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
 Mean scale of a node world, the factor strip widths take.
 @param world : "Published affine node transform."
 @pure
*>
fn float ribbon_width_scale(Mat4 world) {
    float volume = math::abs(world.determinant() @pure) @pure;
    return math::pow(volume, 1.0f / 3.0f) @pure;
}

<*
 Transform a ribbon point's position into world space and scale its width.
 @param world : "Published affine node transform."
 @pure
*>
fn RibbonPoint world_ribbon_point(Mat4 world, RibbonPoint point) {
    point.position = maths::transform_point(world, point.position) @pure;
    point.width *= ribbon_width_scale(world);
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
    alloc::free(*(Allocator*)user, batch.points.ptr);
}
