module c3d::spatial;

import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::maths;
import c3d::scene;
import std::math;

<*
 Whether the mesh's geometry, material and skeleton ids resolve.
 @param [&in] assets : "Store the ids were issued by."
 @param [&in] mesh : "Any mesh component."
 @param [in] skin : "Null for an unskinned mesh."
*>
fn bool mesh_is_live(AssetStore* assets, Mesh* mesh, SkinBinding* skin) {
    return assets.geometries.is_live(mesh.geometry) && assets.materials.is_live(mesh.material)
        && (!skin || assets.skeletons.is_live(skin.skeleton));
}

<*
 World bound of the mesh from its override, its geometry or its joints.
 @param [&in] assets : "Resolves the live geometry record."
 @param [&in] node : "World matrix as left by the last update_world."
 @param [&in] mesh : "Live geometry id."
 @param [in] skin : "Null for an unskinned mesh; joints with current world matrices otherwise."
*>
fn Aabb mesh_world_bounds(
    AssetStore* assets,
    Node* node,
    Mesh* mesh,
    SkinBinding* skin,
) {
    if (mesh.has_bounds_override) return maths::aabb_transform(mesh.local_bounds, node.world);
    GeometryAsset* record = assets.geometry(mesh.geometry);
    Aabb rest = maths::aabb_transform(record.data.bounds, node.world);
    if (!skin || !record.skin_bounds.joints.len) return rest;
    MorphSelection selection = geometry::select_morph_targets(record.data.channels, mesh.morph_weights);
    return skinned_world_bounds(
        bounds:       &record.skin_bounds,
        binding:      skin,
        inverse_bind: assets.skeleton(skin.skeleton).data.inverse_bind,
        selection:    &selection,
        rest:         rest,
    );
}

<*
 Whether the batch's geometry and material ids resolve.
 @param [&in] assets : "Store the ids were issued by."
 @param [&in] batch : "Any batch component."
*>
fn bool instanced_mesh_is_live(AssetStore* assets, InstancedMesh* batch) {
    return assets.geometries.is_live(batch.geometry) && assets.materials.is_live(batch.material);
}

<*
 World bound of the live instances: override, else geometry bound under each instance, merged.
 @param [&in] assets : "Resolves the live geometry record."
 @param [&in] node : "World matrix as left by the last update_world."
 @param [&in] batch : "Live geometry id and live count above zero."
*>
fn Aabb instanced_world_bounds(AssetStore* assets, Node* node, InstancedMesh* batch) {
    if (batch.has_bounds_override) return maths::aabb_transform(batch.local_bounds, node.world);
    Aabb local = assets.geometry(batch.geometry).data.bounds;
    Aabb result = instance_world_bounds(local, node.world, batch.transforms[0]);
    foreach (transform : batch.transforms[1:batch.count - 1]) {
        result = maths::aabb_merge(result, instance_world_bounds(local, node.world, transform));
    }
    return result;
}

fn Aabb instance_world_bounds(Aabb local, Mat4 node_world, Transform transform) @private {
    return maths::aabb_transform(local, node_world.mul(transform.to_mat4()));
}

<*
 World bound of the skinned vertices: each joint's retained bound under its current pose, merged.
 @param [&in] bounds : "Retained per-joint bounds of the geometry."
 @param [&in] binding : "Joints with current world matrices."
 @param inverse_bind : "One matrix per skeleton joint."
 @param [&in] selection : "Active morph targets of the mesh."
 @param rest : "Returned when no bound joint is addressed by the binding."
*>
fn Aabb skinned_world_bounds(
    SkinBounds* bounds,
    SkinBinding* binding,
    Mat4[] inverse_bind,
    MorphSelection* selection,
    Aabb rest,
) {
    usz joint_count = math::min((usz)bounds.joints.len, math::min((usz)binding.joints.len, (usz)inverse_bind.len));
    Aabb result;
    bool first = true;
    for (uint joint = 0; joint < joint_count; joint++) {
        if (!bounds.used[joint]) continue;
        Aabb local = geometry::joint_morph_bounds(bounds, joint, selection);
        Mat4 transform = binding.joints[joint].world.mul(inverse_bind[joint]);
        Aabb world = maths::aabb_transform(local, transform);
        result = first ? world : maths::aabb_merge(result, world);
        first = false;
    }
    return first ? rest : result;
}
