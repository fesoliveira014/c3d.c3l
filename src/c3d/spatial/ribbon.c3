module c3d::spatial;

import c3d::asset;
import c3d::maths;
import c3d::scene;
import std::math;

<*
 Whether a ribbon batch has a supported live material.
 @param [&in] assets : "Store the material was issued by."
 @param [&in] batch : "Any ribbon batch."
*>
fn bool ribbon_batch_is_live(AssetStore* assets, RibbonBatch* batch) {
    return blended_batch_material_is_live(assets, batch.material);
}

<*
 Conservative world bounds of ribbon points in any view.
 @param world : "Published affine node transform."
 @param points : "At least one valid point."
 @pure
 @require points.len > 0
*>
fn Aabb ribbon_bounds(Mat4 world, RibbonPoint[] points) {
    float width_scale = scene::ribbon_width_scale(world) @pure;

    Aabb bounds;
    foreach (index, point : points) {
        RibbonPoint placed = scene::place_ribbon_point(world, width_scale, point) @pure;
        float radius = 0.5f * placed.width;
        Vec3 extent = { radius, radius, radius };
        Aabb box = { .min = placed.position - extent, .max = placed.position + extent };
        bounds = index ? maths::aabb_merge(bounds, box) @pure : box;
    }
    return bounds;
}

<*
 Conservative relative bounds of a nonempty ribbon batch.
 @param [&in] node : "Published node transform."
 @param [&inout] batch : "Valid points; cached bounds may be refreshed."
 @param origin : "Absolute origin of the returned bounds; zero preserves world."
 @require batch.draw_count() > 0
 @require batch.has_bounds_override || batch.source != RibbonSource.DEVICE
*>
fn Aabb ribbon_world_bounds(Node* node, RibbonBatch* batch, Vec3 origin = {}) {
    Mat4 world = maths::rebase(node.world, origin);
    if (batch.has_bounds_override) return maths::aabb_transform(batch.local_bounds, world);

    RibbonAggregate* aggregate = &batch.aggregate;
    if (aggregate.revision == batch.revision && aggregate.world == world) return aggregate.bounds;
    Aabb bounds = ribbon_bounds(world, batch.points[:batch.count]);
    *aggregate = { .world = world, .bounds = bounds, .revision = batch.revision };
    return bounds;
}
