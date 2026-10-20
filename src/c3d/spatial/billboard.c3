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
    return blended_batch_material_is_live(assets, batch.material);
}

fn bool blended_batch_material_is_live(AssetStore* assets, MaterialId material_id) @private {
    if (!assets.materials.is_live(material_id)) return false;
    Material* material = &assets.material(material_id).data;
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
 Conservative relative bounds of a nonempty billboard batch.
 @param [&in] node : "Published node transform."
 @param [&inout] batch : "Valid records; cached bounds may be refreshed."
 @param origin : "Absolute origin of the returned bounds; zero preserves world."
 @require batch.draw_count() > 0
 @require batch.has_bounds_override || batch.source != BillboardSource.DEVICE
*>
fn Aabb billboard_world_bounds(Node* node, BillboardBatch* batch, Vec3 origin = {}) {
    Mat4 world = maths::rebase(node.world, origin);
    if (batch.has_bounds_override) return maths::aabb_transform(batch.local_bounds, world);

    BillboardAggregate* aggregate = &batch.aggregate;
    if (aggregate.revision == batch.revision && aggregate.world == world) return aggregate.bounds;

    Aabb bounds = batch.source == BillboardSource.RECORDS
      ? records_bounds(world, batch.records[:batch.count]) : billboards_bounds(world, batch.billboards[:batch.count]);
    *aggregate = { .world = world, .bounds = bounds, .revision = batch.revision };
    return bounds;
}

fn Aabb billboards_bounds(Mat4 world, Billboard[] billboards) @local {
    Aabb bounds = billboard_bounds(world, billboards[0]);
    foreach (billboard : billboards[1..]) {
        bounds = maths::aabb_merge(bounds, billboard_bounds(world, billboard));
    }
    return bounds;
}

// Mirrors billboard_bounds without building a Billboard: the direction does not enter the bound.
fn Aabb records_bounds(Mat4 world, BillboardRecord[] records) @local {
    Vec2 axis_scale = {
        maths::transform_dir(world, { 1, 0, 0 }).length(),
        maths::transform_dir(world, { 0, 1, 0 }).length(),
    };
    Aabb bounds = record_bounds(world, axis_scale, &records[0]);
    foreach (&record : records[1..]) {
        bounds = maths::aabb_merge(bounds, record_bounds(world, axis_scale, record));
    }
    return bounds;
}

fn Aabb record_bounds(Mat4 world, Vec2 axis_scale, BillboardRecord* record) @local {
    Vec3 center = maths::transform_point(world, record.position_width.xyz);
    Vec2 size = (Vec2){ record.position_width.w, record.direction_height.w } * axis_scale;
    float radius = 0.5f * size.length();
    Vec3 extent = { radius, radius, radius };
    return { .min = center - extent, .max = center + extent };
}
