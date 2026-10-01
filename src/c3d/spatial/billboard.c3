module c3d::spatial;

import c3d::asset;
import c3d::material;
import c3d::maths;
import c3d::scene;
import std::math;

<*
 Whether a billboard batch has a supported live material.
 @param [&in] assets : "Store the material was issued by."
 @param [&in] batch : "Any billboard batch."
*>
fn bool billboard_batch_is_live(AssetStore* assets, BillboardBatch* batch) {
    if (!assets.materials.is_live(batch.material)) return false;
    Material* material = &assets.material(batch.material).data;
    if (material.common.alpha_mode != AlphaMode.BLEND) return false;
    if (material.kind == MaterialKind.PHYSICAL && material.physical.transmission > 0) return false;
    if (material.kind != MaterialKind.CUSTOM) return true;
    if (!assets.shaders.is_live(material.custom.shader)) return false;
    return !assets.shader(material.custom.shader).desc.vertex.shaded.len;
}

<*
 Conservative world bounds of one billboard in any view.
 @param world : "Published affine node transform."
 @pure
*>
fn Aabb billboard_bounds(Mat4 world, Billboard billboard) {
    Billboard placed = scene::world_billboard(world, billboard);
    float radius = 0.5f * placed.size.length();
    Vec3 extent = { radius, radius, radius };
    return { .min = placed.position - extent, .max = placed.position + extent };
}

<*
 Conservative world bounds of a nonempty billboard batch.
 @param [&in] node : "Published node transform."
 @param [&inout] batch : "Valid records; cached bounds may be refreshed."
 @require batch.count > 0
*>
fn Aabb billboard_world_bounds(Node* node, BillboardBatch* batch) {
    BillboardAggregate* aggregate = &batch.aggregate;
    if (aggregate.revision == batch.revision && aggregate.world == node.world) return aggregate.bounds;
    Aabb bounds = billboard_bounds(node.world, batch.billboards[0]);
    foreach (billboard : batch.billboards[1:batch.count - 1]) {
        bounds = maths::aabb_merge(bounds, billboard_bounds(node.world, billboard));
    }
    *aggregate = { .world = node.world, .bounds = bounds, .revision = batch.revision };
    return bounds;
}
